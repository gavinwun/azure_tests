#!/usr/bin/env bash
# bootstrap_agent.sh
# Converted from bootstrap_agent.ps1 (Azure DevOps / Windows) to Ubuntu / GitHub Actions.
# Runs once per instance boot via the CustomScript extension in main.tf.
#
# Does two things in one pass, matching the original script's shape:
#   1. Installs the tooling this org's pipelines need
#   2. Registers + runs this instance as a PERSISTENT GitHub Actions runner
#      (takes job after job; terminate-watcher.sh deregisters it gracefully
#      when VMSS scale-in reclaims the instance). The ACI backend uses
#      --ephemeral instead - one container per job - see docker/entrypoint.sh.
set -euo pipefail
# Mirror all output three ways: a local file, syslog (facility local0, tag
# ghrunner-bootstrap - AMA's Data Collection Rule ships local0 to Log
# Analytics, see terraform/monitoring.tf), and the original stdout, so the
# CustomScript extension status also captures it (visible in
# `az vmss get-instance-view`).
mkdir -p /var/log/bootstrap
exec > >(tee -a /var/log/bootstrap/bootstrap_agent_detail.log \
              >(logger -t ghrunner-bootstrap -p local0.info)) 2>&1

# ---------------------------------------------------------------------
# Re-run guard
#
# The CustomScript extension (main.tf) re-executes its commandToExecute
# on every instance model update - VM resize, OS image bump, VMSS
# auto-repair, or an extension/settings change from `terraform apply`.
# Every step in this script is idempotent (guarded creates, --replace
# registration, `svc.sh` re-runnable, ansible), so a re-run is safe.
#
# BOOTSTRAP_VERSION is exported by the CustomScript preamble - a hash of
# this script's content PLUS the cis_hardening_* Terraform inputs
# (locals.tf). The sentinel records the version this instance last
# completed:
#   - no sentinel            -> first boot (or a failed one) -> run
#   - sentinel == version     -> nothing changed -> skip (fast no-op)
#   - sentinel != version     -> script or CIS config bumped -> re-run
#   - run by hand, no version -> honour a bare sentinel; `rm` it to force
#
# The sentinel is written as the very last step below, so a run that
# fails midway is retried on the next extension execution.
# ---------------------------------------------------------------------
BOOTSTRAP_SENTINEL="/var/lib/ghrunner/.bootstrapped"
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-}"
if [[ -f "${BOOTSTRAP_SENTINEL}" ]]; then
  _done="$(cat "${BOOTSTRAP_SENTINEL}" 2>/dev/null || true)"
  if [[ -z "${BOOTSTRAP_VERSION}" || "${_done}" == "${BOOTSTRAP_VERSION}" ]]; then
    echo "Bootstrap already completed (${_done:-date unknown}) - nothing to do."
    exit 0
  fi
  echo "Bootstrap sentinel is '${_done}', target version is '${BOOTSTRAP_VERSION}' - re-running."
fi

echo "Starting bootstrap at $(date -u)"

# ---------------------------------------------------------------------
# Config - adjust for your org/repo and Key Vault
# ---------------------------------------------------------------------
# GITHUB_SCOPE picks where each instance registers as a runner:
#   "org"  - organisation-level runner. Needs the GitHub App's
#            Organisation -> "Self-hosted runners: Read and write" permission.
#   "repo" - single-repository runner (use this for a personal account,
#            which has no org-level runners). Needs the App's
#            Repository -> "Administration: Read and write" permission.
GITHUB_SCOPE="repo"                          # "org" or "repo"
GITHUB_ORG="gavinwun"                        # used when GITHUB_SCOPE=org
GITHUB_REPO="gavinwun/azure_tests"           # "owner/repo", used when GITHUB_SCOPE=repo
KEYVAULT_NAME="kv-ghrunner-25818"
# The instance mints its own GitHub App installation token at boot from the
# App's PRIVATE KEY (stored once in Key Vault), rather than reading a
# short-lived token kept fresh by a scheduled workflow. No 1-hour race, no
# Actions-minutes cost, no dependency on GitHub's cron actually firing.
GITHUB_APP_ID="4736345"                          # numeric App ID (App settings -> General)
KEYVAULT_APP_KEY_SECRET_NAME="github-app-private-key"   # PEM, seed once (see setup/bootstrap.sh)
RUNNER_VERSION="2.337.0"                     # pin, bump deliberately
DOTNET_CHANNEL="8.0"                         # must be a channel packaged for this
                                            # Ubuntu release in packages.microsoft.com
                                            # (8.0 LTS for jammy). NOT 10.0 - no jammy
                                            # package exists, install just fails.
RUNNER_LABELS="self-hosted,linux,x64,vmss"
RUNNER_GROUP="default"

# Resolve the scope to the two things the runner API actually needs: a REST
# base for the registration/removal token endpoints, and the --url the
# runner attaches to. Everything downstream uses these, not GITHUB_ORG.
if [[ "${GITHUB_SCOPE}" == "repo" ]]; then
  GH_API_BASE="https://api.github.com/repos/${GITHUB_REPO}"
  GH_RUNNER_URL="https://github.com/${GITHUB_REPO}"
else
  GH_API_BASE="https://api.github.com/orgs/${GITHUB_ORG}"
  GH_RUNNER_URL="https://github.com/${GITHUB_ORG}"
fi

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------
# Provisioning environment
#
# The VM image is stock Canonical Ubuntu 24.04 LTS (free). CIS Benchmark
# hardening, if enabled, is applied at the END of this script by
# harden_cis() - see that function. These two lines just keep the
# provisioning run itself predictable.
# ---------------------------------------------------------------------
umask 022

# Keep an exec-able TMPDIR on the root fs for the whole run. Harmless on
# a stock image; matters once harden_cis() has (optionally) made /tmp
# noexec on a re-run, and keeps installers that exec out of $TMPDIR
# (dotnet first-run, ./bin/installdependencies.sh) working.
export TMPDIR=/var/lib/ghrunner/tmp
mkdir -p "${TMPDIR}"
chmod 1777 "${TMPDIR}"

# ---------------------------------------------------------------------
# apt hardening
#
# On a fresh VMSS instance, cloud-init and the apt-daily / unattended-
# upgrades systemd units grab the dpkg lock the moment the box boots, so
# the first apt-get here dies with exit 100. Wait cloud-init out, stop
# the background apt units, then give every apt-get a long lock timeout
# and a few retries for transient mirror errors.
# ---------------------------------------------------------------------
cloud-init status --wait 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

apt_get() {
  local i
  for i in 1 2 3 4 5; do
    if apt-get -o DPkg::Lock::Timeout=600 -o Acquire::Retries=3 "$@"; then
      return 0
    fi
    echo "apt-get $* failed (attempt ${i}/5) - retrying in 15s"
    sleep 15
  done
  echo "apt-get $* still failing after 5 attempts" >&2
  return 1
}

# ---------------------------------------------------------------------
# 1. Base packages (required - runner won't configure without these)
# ---------------------------------------------------------------------
apt_get update
apt_get install -y \
  curl jq zip unzip ca-certificates apt-transport-https gnupg openssl \
  lsb-release git build-essential libicu-dev

# ---------------------------------------------------------------------
# 2. Node.js (NodeSource LTS) - required by the Actions runner
# ---------------------------------------------------------------------
for i in 1 2 3; do
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && break
  echo "NodeSource setup failed (attempt ${i}/3) - retrying in 10s"; sleep 10
done
apt_get install -y nodejs

# ---------------------------------------------------------------------
# 3. Azure CLI (Microsoft apt repo) - best-effort, workflows use it but
#    the runner comes online without it.
# ---------------------------------------------------------------------
curl -sL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ ${AZ_REPO} main" \
  | tee /etc/apt/sources.list.d/azure-cli.list

apt_get update
apt_get install -y azure-cli || echo "WARN: azure-cli install failed - continuing"

# ---------------------------------------------------------------------
# 4. .NET SDK (Microsoft apt repo) - best-effort. A dotnet-sdk-<channel>
#    that isn't published for this Ubuntu release must not abort the whole
#    bootstrap; fall back to the current LTS, then give up gracefully.
# ---------------------------------------------------------------------
UBUNTU_VER=$(lsb_release -rs)
if wget -q "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER}/packages-microsoft-prod.deb" \
     -O /tmp/packages-microsoft-prod.deb; then
  dpkg -i /tmp/packages-microsoft-prod.deb || true
  rm -f /tmp/packages-microsoft-prod.deb
  apt_get update
  if ! apt_get install -y "dotnet-sdk-${DOTNET_CHANNEL}"; then
    echo "WARN: dotnet-sdk-${DOTNET_CHANNEL} unavailable - falling back to dotnet-sdk-8.0"
    apt_get install -y dotnet-sdk-8.0 || echo "WARN: .NET SDK install failed - continuing without it"
  fi
else
  echo "WARN: could not fetch packages-microsoft-prod.deb - skipping .NET SDK"
fi

# ---------------------------------------------------------------------
# 5. Docker - best-effort (only needed for docker-in-docker workflows)
# ---------------------------------------------------------------------
if apt_get install -y docker.io; then
  systemctl enable --now docker || true
else
  echo "WARN: docker.io install failed - continuing without docker"
fi

# ---------------------------------------------------------------------
# 6. GitHub Actions runner - download, register, run (persistent)
#
# Every step here is guarded so the script is safe to re-run even without
# the run-once sentinel (e.g. on an instance that bootstrapped under an
# older version of this script). See the run-once guard near the top.
# ---------------------------------------------------------------------
mkdir -p /opt/actions-runner
cd /opt/actions-runner

# Download + extract only if the runner isn't already unpacked here.
if [[ ! -x /opt/actions-runner/config.sh ]]; then
  curl -o actions-runner-linux-x64.tar.gz -L \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf actions-runner-linux-x64.tar.gz
  rm actions-runner-linux-x64.tar.gz
  ./bin/installdependencies.sh
fi

id -u actions-runner &>/dev/null || useradd -m -s /bin/bash actions-runner
chown -R actions-runner:actions-runner /opt/actions-runner

# --- GitHub App token minting helper ----------------------------------
# /opt/actions-runner/mint-gh-token.sh prints a fresh GitHub App
# INSTALLATION ACCESS TOKEN to stdout: reads the App private key from Key
# Vault via this VM's managed identity, signs an App JWT, and exchanges it.
# Used here and by the terminate-watcher below. Unquoted heredoc - the
# ${...} refs are baked in now, \$... are evaluated at runtime.
cat > /opt/actions-runner/mint-gh-token.sh <<MINT
#!/usr/bin/env bash
set -uo pipefail
KEYVAULT_NAME="${KEYVAULT_NAME}"
KEYVAULT_APP_KEY_SECRET_NAME="${KEYVAULT_APP_KEY_SECRET_NAME}"
GITHUB_APP_ID="${GITHUB_APP_ID}"
GH_API_BASE="${GH_API_BASE}"

fail() { echo "mint-gh-token: \$*" >&2; exit 1; }

kv_aad=\$(curl -s --retry 5 --retry-delay 3 --retry-connrefused -H "Metadata:true" \\
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \\
  | jq -r '.access_token // empty')
[ -n "\${kv_aad}" ] || fail "no AAD token from IMDS - is a user-assigned identity attached?"

pem=\$(curl -s --retry 5 --retry-delay 3 -H "Authorization: Bearer \${kv_aad}" \\
  "https://\${KEYVAULT_NAME}.vault.azure.net/secrets/\${KEYVAULT_APP_KEY_SECRET_NAME}?api-version=7.4" \\
  | jq -r '.value // empty')
[ -n "\${pem}" ] || fail "Key Vault secret '\${KEYVAULT_APP_KEY_SECRET_NAME}' missing/empty (seed once: az keyvault secret set --vault-name \${KEYVAULT_NAME} --name \${KEYVAULT_APP_KEY_SECRET_NAME} --file <app>.private-key.pem)"

kf=\$(mktemp); chmod 600 "\${kf}"; printf '%s\\n' "\${pem}" > "\${kf}"; unset pem
b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=\$(date -u +%s)
hdr=\$(printf '{"alg":"RS256","typ":"JWT"}' | b64u)
pl=\$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "\$((now-60))" "\$((now+540))" "\${GITHUB_APP_ID}" | b64u)
sig=\$(printf '%s.%s' "\${hdr}" "\${pl}" | openssl dgst -sha256 -sign "\${kf}" -binary 2>/dev/null | b64u)
shred -u "\${kf}" 2>/dev/null || rm -f "\${kf}"
[ -n "\${sig}" ] || fail "could not sign JWT - the value in \${KEYVAULT_APP_KEY_SECRET_NAME} is not a valid RSA private key PEM"
jwt="\${hdr}.\${pl}.\${sig}"

iid=\$(curl -s -H "Authorization: Bearer \${jwt}" -H "Accept: application/vnd.github+json" \\
  "\${GH_API_BASE}/installation" | jq -r '.id // empty')
[ -n "\${iid}" ] || fail "no installation for \${GH_API_BASE} (App not installed there, wrong GITHUB_APP_ID=\${GITHUB_APP_ID}, or the key in Key Vault is not this App's current key)"

tok=\$(curl -s -X POST -H "Authorization: Bearer \${jwt}" -H "Accept: application/vnd.github+json" \\
  "https://api.github.com/app/installations/\${iid}/access_tokens" | jq -r '.token // empty')
[ -n "\${tok}" ] || fail "installation token exchange failed for installation \${iid}"
printf '%s' "\${tok}"
MINT
chmod +x /opt/actions-runner/mint-gh-token.sh
chown actions-runner:actions-runner /opt/actions-runner/mint-gh-token.sh

# --- Mint a fresh installation token, then exchange it for a runner
#     REGISTRATION token (org or repo) ---
GITHUB_TOKEN=$(/opt/actions-runner/mint-gh-token.sh) || {
  echo "FATAL: could not mint a GitHub App token (see the 'mint-gh-token:' line above)." >&2
  exit 1
}

reg_resp=$(curl -s -w '\n%{http_code}' --retry 3 --retry-delay 3 -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API_BASE}/actions/runners/registration-token" || true)
reg_code=$(printf '%s' "${reg_resp}" | tail -n1)
reg_body=$(printf '%s' "${reg_resp}" | sed '$d')
REG_TOKEN=$(printf '%s' "${reg_body}" | jq -r '.token // empty' 2>/dev/null || true)
if [[ -z "${REG_TOKEN}" ]]; then
  echo "FATAL: ${GH_API_BASE}/actions/runners/registration-token returned HTTP ${reg_code}, no token." >&2
  echo "  403 => the GitHub App lacks 'Administration: Read and write' (repo scope) / 'Self-hosted runners' (org scope)." >&2
  echo "  404 => wrong owner/repo in GH_API_BASE, or the App isn't installed there." >&2
  printf '  body: %s\n' "$(printf '%s' "${reg_body}" | jq -c '{message,documentation_url}' 2>/dev/null || printf '%s' "${reg_body}" | head -c 300)" >&2
  exit 1
fi

INSTANCE_NAME="vmss-runner-$(hostname)"

# Persistent runner: registered once, takes job after job until VMSS
# scale-in reclaims the instance (terminate-watcher.sh deregisters it
# first). No --ephemeral - that's the ACI model (one container per job).
#
# .runner persists across reboots, so if it's already here the runner is
# configured and just needs its service (re)started - don't re-register.
# --replace overwrites any stale server-side registration still holding
# this name (e.g. a prior instance with the same hostname).
if [[ -f /opt/actions-runner/.runner ]]; then
  echo "Runner already configured - leaving existing registration in place."
else
  sudo -u actions-runner ./config.sh \
    --url "${GH_RUNNER_URL}" \
    --token "${REG_TOKEN}" \
    --name "${INSTANCE_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --runnergroup "${RUNNER_GROUP}" \
    --unattended \
    --replace
fi

# Install as a systemd service so it survives the bootstrap script exiting,
# rather than running in the foreground and blocking the extension.
# svc.sh install fails if the unit already exists, so guard it; svc.sh
# start is safe to call repeatedly.
if ls /etc/systemd/system/actions.runner.*.service >/dev/null 2>&1; then
  echo "Runner service already installed."
else
  ./svc.sh install actions-runner
fi
./svc.sh start

# ---------------------------------------------------------------------
# 7. Terminate-notification watcher
#
# Watches this instance's IMDS Scheduled Events for a pending Terminate
# (fires when VMSS scale-in targets this instance) and deregisters the
# runner from GitHub before the instance is deallocated, so scale-in
# doesn't leave a stale "offline" runner behind. Reuses the same
# managed-identity Key Vault access already set up above - no new
# permissions needed. Requires termination_notification to be enabled
# on the VMSS in Terraform (see main.tf) - without that, Azure gives no
# warning before deallocating and this script never gets a chance to run.
# ---------------------------------------------------------------------
cat > /opt/actions-runner/terminate-watcher.sh <<EOF
#!/usr/bin/env bash
set -uo pipefail   # no -e: this loops indefinitely and retries through transient errors

IMDS_EVENTS_URL="http://169.254.169.254/metadata/scheduledevents?api-version=2020-07-01"
GH_API_BASE="${GH_API_BASE}"
RUNNER_DIR="/opt/actions-runner"
POLL_INTERVAL=5

log() { echo "[terminate-watcher] \$(date -u +%FT%TZ) \$*"; }

# Mint a fresh GitHub App installation token from the private key in Key
# Vault (same helper the bootstrap uses). Prints empty on failure.
get_github_app_token() {
  \${RUNNER_DIR}/mint-gh-token.sh 2>/dev/null || true
}

runner_busy() {
  # The runner's actual job-execution child process. If it's running,
  # a job is in flight and we shouldn't yank the runner out from under it.
  pgrep -f "Runner.Worker" > /dev/null 2>&1
}

deregister_runner() {
  log "Deregistering runner before termination"
  local gh_token remove_token
  gh_token=\$(get_github_app_token)
  remove_token=\$(curl -s -X POST \\
    -H "Authorization: Bearer \${gh_token}" \\
    -H "Accept: application/vnd.github+json" \\
    "\${GH_API_BASE}/actions/runners/remove-token" \\
    | jq -r '.token')

  if [[ -z "\${remove_token}" || "\${remove_token}" == "null" ]]; then
    log "Could not obtain removal token - skipping graceful deregister; Azure will still deallocate at the termination_notification timeout regardless"
    return 1
  fi

  cd "\${RUNNER_DIR}" || return 1
  sudo -u actions-runner ./svc.sh stop || true
  sudo -u actions-runner ./config.sh remove --token "\${remove_token}" || \\
    log "config.sh remove failed (runner may already be gone) - continuing"
}

approve_event() {
  local event_id="\$1"
  curl -s -X POST -H "Metadata:true" \\
    -d "{\\"StartRequests\\":[{\\"EventId\\":\\"\${event_id}\\"}]}" \\
    "\${IMDS_EVENTS_URL}" > /dev/null
  log "Approved event \${event_id} - deallocation can proceed immediately rather than waiting out the full timeout"
}

log "Terminate watcher starting"

while true; do
  RESPONSE=\$(curl -s -H "Metadata:true" "\${IMDS_EVENTS_URL}" || echo '{}')
  EVENT=\$(echo "\${RESPONSE}" | jq -c '.Events[]? | select(.EventType=="Terminate")' | head -n1)

  if [[ -n "\${EVENT}" ]]; then
    EVENT_ID=\$(echo "\${EVENT}" | jq -r '.EventId')
    log "Terminate event \${EVENT_ID} received"

    # If a job is actively running, wait rather than cutting it off early.
    # Azure enforces its own hard timeout (termination_notification.timeout
    # in Terraform, 5-15 min) regardless of what happens here - a job that
    # outlives that window gets terminated anyway; this just avoids ending
    # it any sooner than Azure was already going to.
    while runner_busy; do
      log "Job in progress - deferring deregistration"
      sleep "\${POLL_INTERVAL}"
    done

    deregister_runner
    approve_event "\${EVENT_ID}"
    exit 0
  fi

  sleep "\${POLL_INTERVAL}"
done
EOF

chmod +x /opt/actions-runner/terminate-watcher.sh

cat > /etc/systemd/system/terminate-watcher.service <<'EOF'
[Unit]
Description=GitHub Actions runner terminate-notification watcher
After=network-online.target actions-runner.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/actions-runner/terminate-watcher.sh
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now terminate-watcher

# ---------------------------------------------------------------------
# 8. CIS Benchmark hardening (optional, best-effort)
#
# Stock Ubuntu 24.04 is not CIS-hardened. When CIS_HARDENING_ENABLED is
# "true" (set from var.cis_hardening_enabled via the CustomScript
# preamble), apply the CIS Ubuntu 24.04 Benchmark now - AFTER the runner
# and terminate-watcher are up - with the MIT-licensed Ansible role
# ansible-lockdown/UBUNTU24-CIS (https://github.com/ansible-lockdown/UBUNTU24-CIS),
# pinned to a tag. No Marketplace purchase, no Ubuntu Pro token.
#
# It is BEST-EFFORT: the runner is already registered and working, so a
# hardening failure logs loudly (visible in Log Analytics) but does not
# fail the bootstrap. A clean run drops /var/lib/ghrunner/.hardened.
#
# The override file it generates trades a few strict-CIS ticks for
# keeping a CI runner usable/available (auditd won't halt the box, /tmp
# stays exec-able, AIDE's slow db-init is off, the host firewall is left
# to the Azure NSG unless cis_hardening_manage_firewall = true). Tune via
# the cis_hardening_* Terraform variables.
# ---------------------------------------------------------------------
harden_cis() {
  local level="${CIS_HARDENING_LEVEL:-level1}"
  local ref="${CIS_HARDENING_REF:-1.6.0}"
  local manage_fw="${CIS_HARDENING_MANAGE_FIREWALL:-false}"
  local repo_dir=/opt/ubuntu24-cis
  local vars_file=/etc/ghrunner/cis-overrides.yml
  local tags

  case "${level}" in
    level1) tags="level1-server" ;;
    level2) tags="level1-server,level2-server" ;;
    *) echo "WARN: unknown CIS_HARDENING_LEVEL '${level}' - using level1"; level=level1; tags="level1-server" ;;
  esac

  echo "=== CIS hardening: ansible-lockdown/UBUNTU24-CIS @ ${ref} | tags=${tags} | manage_firewall=${manage_fw} ==="

  apt_get install -y ansible git || return 1

  # Pinned, shallow checkout of the role AT A TAG - never a branch.
  if [[ -d "${repo_dir}/.git" ]]; then
    git -C "${repo_dir}" fetch --depth 1 --tags origin "${ref}" 2>/dev/null || true
    git -C "${repo_dir}" checkout -q "refs/tags/${ref}" 2>/dev/null \
      || git -C "${repo_dir}" checkout -q "${ref}" || return 1
  else
    rm -rf "${repo_dir}"
    git clone --depth 1 --branch "${ref}" \
      https://github.com/ansible-lockdown/UBUNTU24-CIS.git "${repo_dir}" || return 1
  fi

  # The role needs community.general / community.crypto / ansible.posix.
  # Ubuntu's `ansible` apt package bundles all three; only reach out to
  # Ansible Galaxy if one is genuinely missing.
  local c need_galaxy=0
  for c in community.general community.crypto ansible.posix; do
    ansible-galaxy collection list 2>/dev/null | grep -q "^${c} " || need_galaxy=1
  done
  if [[ "${need_galaxy}" -eq 1 ]]; then
    echo "CIS hardening: fetching missing Ansible collections from Galaxy"
    ansible-galaxy collection install community.general community.crypto ansible.posix \
      || echo "WARN: ansible-galaxy install failed - continuing with the apt bundle"
  fi

  # ---- runner-safe overrides -----------------------------------------
  mkdir -p /etc/ghrunner
  {
    echo "---"
    echo "# Generated by bootstrap_agent.sh harden_cis() - do not edit by hand."
    echo "skip_reboot: true"
    echo "ubtu24cis_disruption_high: false"
    echo "ubtu24cis_ask_passwd_to_boot: false"
    echo "ubtu24cis_config_aide: false"
    echo "ubtu24cis_level_1: true"
    echo "ubtu24cis_level_2: $([[ "${level}" == "level2" ]] && echo true || echo false)"
    # auditd must never halt/suspend a long-lived CI runner if its log dir fills.
    echo "ubtu24cis_auditd_disk_full_action: syslog"
    echo "ubtu24cis_auditd_disk_error_action: syslog"
    echo "ubtu24cis_auditd_space_left_action: syslog"
    echo "ubtu24cis_auditd_admin_space_left_action: syslog"
    echo "ubtu24cis_auditd_max_log_file_action: rotate"
    if [[ "${manage_fw}" == "true" ]]; then
      echo "ubtu24cis_firewall_package: ufw"
      # Runner needs arbitrary egress (IMDS, in-VNet private endpoints,
      # GitHub, package mirrors); inbound is still default-deny.
      echo "ubtu24cis_ufw_allow_out_ports: all"
    else
      echo "ubtu24cis_firewall_package: none"
    fi
    # Keep temp dirs exec-able - Actions steps and setup-* actions run
    # helpers out of them. (x.x.x.4 == the 'noexec' sub-control.)
    echo "ubtu24cis_rule_1_1_2_1_4: false   # /tmp noexec"
    echo "ubtu24cis_rule_1_1_2_2_4: false   # /dev/shm noexec"
    echo "ubtu24cis_rule_1_1_2_5_4: false   # /var/tmp noexec"
  } > "${vars_file}"

  # User-supplied extra opt-outs (space- or comma-separated var names).
  local extra r
  extra="${CIS_HARDENING_SKIP_RULES:-}"
  for r in ${extra//,/ }; do
    printf '%s: false\n' "${r}" >> "${vars_file}"
  done

  echo "--- ${vars_file} ---"; sed 's/^/  /' "${vars_file}"; echo "--------------------"

  # ---- prerequisite: /run/sshd -------------------------------------
  #
  # ansible-lockdown's 5.1.x sshd tasks validate every edit with
  # `sshd -t`, which needs the privilege-separation dir /run/sshd. On a
  # fresh CustomScript boot the ssh unit is often still inactive and
  # /run/sshd (tmpfs, made by ssh.service / systemd-tmpfiles) does not
  # exist yet - so 5.1.5 dies with
  #   "failed to validate: Missing privilege separation directory: /run/sshd"
  # and the role's linear play STOPS there, silently skipping the rest of
  # 5.1, all of 5.3 (PAM) and 5.4. Create it now and make it survive a
  # reboot.
  install -d -m 0755 /run/sshd
  printf 'd /run/sshd 0755 root root -\n' > /etc/tmpfiles.d/sshd-runner.conf

  # ---- run it: this host only, local connection ---------------------
  #
  # --force-handlers: the role queues restarts/reloads (sshd, sysctl,
  # pam-auth-update, auditd) as handlers; without this a task failure
  # anywhere aborts the run with those changes written but never
  # activated. Two idempotent passes: a second run typically applies
  # everything the first skipped after its abort point. A non-zero final
  # rc is logged, NOT fatal - the runner is already up, and
  # enforce_runner_safe_cis() plus the audit still run. Chase the root
  # cause in the diag bundle the cis-benchmark workflow now collects.
  local play_rc=0 _attempt
  for _attempt in 1 2; do
    play_rc=0
    ANSIBLE_LOCALHOST_WARNING=False \
    ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
    ANSIBLE_RETRY_FILES_ENABLED=False \
    ansible-playbook "${repo_dir}/site.yml" \
      --connection local \
      --inventory 'localhost,' \
      --limit localhost \
      --tags "${tags}" \
      --force-handlers \
      --extra-vars "@${vars_file}" || play_rc=$?
    if [[ "${play_rc}" -eq 0 ]]; then break; fi
    if [[ "${_attempt}" -lt 2 ]]; then
      echo "WARN: ansible-lockdown run (attempt ${_attempt}/2) exited ${play_rc} - retrying once"
    else
      echo "WARN: ansible-lockdown run still exited ${play_rc} after 2 attempts - continuing; enforce_runner_safe_cis() and the audit still run"
    fi
  done

  # ---- post-hardening fixups: guarantee the runner keeps working ----
  # regardless of exactly what the benchmark changed.
  local m
  for m in /tmp /var/tmp /dev/shm; do
    if mount | grep -q " ${m} .*noexec"; then
      mount -o remount,exec "${m}" 2>/dev/null || true
    fi
  done
  [[ -f /etc/fstab ]] && sed -ri '/[[:space:]]\/(tmp|var\/tmp|dev\/shm)[[:space:]]/ s/\bnoexec\b/exec/g' /etc/fstab || true
  if systemctl list-unit-files tmp.mount >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system/tmp.mount.d
    printf '[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev\n' \
      > /etc/systemd/system/tmp.mount.d/10-runner-exec.conf
    systemctl daemon-reload || true
  fi

  # docker networking: CIS sets net.ipv4.ip_forward=0; restore it and let
  # dockerd rebuild its rules (no-op when docker isn't installed).
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  if systemctl is-active --quiet docker; then systemctl restart docker || true; fi

  # egress rules the runner + terminate-watcher depend on - only when we
  # let CIS turn ufw on.
  if [[ "${manage_fw}" == "true" ]] && command -v ufw >/dev/null 2>&1; then
    ufw allow out to 169.254.169.254 comment 'Azure IMDS' || true
    ufw allow out to 168.63.129.16 comment 'Azure WireServer/DNS' || true
    local a p
    a=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/subnet/0/address?api-version=2021-02-01&format=text" 2>/dev/null || true)
    p=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/subnet/0/prefix?api-version=2021-02-01&format=text" 2>/dev/null || true)
    [ -n "${a}" ] && [ -n "${p}" ] && ufw allow out to "${a}/${p}" comment 'in-VNet (private endpoints)' || true
    ufw reload || true
  fi

  # make sure the runner + watcher survived the PAM / limits / sysctl churn.
  systemctl restart 'actions.runner.*' 2>/dev/null || { cd /opt/actions-runner && ./svc.sh start; } || true
  systemctl restart terminate-watcher 2>/dev/null || true

  mkdir -p /var/lib/ghrunner
  printf '%s  version=%s  ref=%s  ansible_rc=%s\n' \
    "$(date -u +%FT%TZ)" "${BOOTSTRAP_VERSION:-none}" "${ref}" "${play_rc}" \
    > /var/lib/ghrunner/.hardened
  if [[ "${play_rc}" -eq 0 ]]; then
    echo "=== CIS hardening complete ==="
  else
    echo "=== CIS hardening finished with ansible rc=${play_rc} (fixups applied; see WARN lines above) ==="
  fi
  return "${play_rc}"
}

# ---------------------------------------------------------------------
# 8b. Runner-safe CIS backstop
#
# harden_cis() above is best-effort: if an ansible task fails mid-run,
# every control after it is skipped. The controls below are (a) plain
# file / sysctl / unit drops with no path to locking anyone out of the
# box, and (b) exactly what the read-only benchmark audit greps for - so
# we assert them directly, every boot, no matter how far the role got.
#
# What is deliberately NOT here: the PAM auth stack (common-auth /
# -account / -password wiring, pam_unix, pam_pwhistory activation). Those
# stay with the ansible role, where getting them subtly wrong locks out
# login. The pwquality.conf / faillock.conf values below are inert until
# the role wires those modules in; they just make sure the values are
# already correct when it does.
# ---------------------------------------------------------------------
enforce_runner_safe_cis() (
  set +e   # subshell: assert as much as possible, never abort the bootstrap
  echo "=== Runner-safe CIS backstop: asserting file/sysctl/unit controls ==="

  # sshd's 5.1.x validate step (role AND the block below) needs this dir;
  # ssh is often still inactive here so it isn't created yet.
  install -d -m 0755 /run/sshd

  # -- §3.3 IPv6 router-adverts / redirects / source-route. The fleet is
  #    IPv4-only for egress, so switching these off changes nothing that
  #    the runner depends on. Written to the drop-in dir AND appended to
  #    the file the role/audit grep (ubtu24cis_sysctl_network_conf,
  #    default /etc/sysctl.conf), then applied live.
  _ipv6_keys='net.ipv6.conf.all.accept_ra net.ipv6.conf.default.accept_ra net.ipv6.conf.all.accept_redirects net.ipv6.conf.default.accept_redirects net.ipv6.conf.all.accept_source_route net.ipv6.conf.default.accept_source_route'
  {
    echo "# CIS 3.3.5 / 3.3.8 / 3.3.9 / 3.3.11 - asserted by bootstrap_agent.sh"
    for _k in ${_ipv6_keys}; do echo "${_k} = 0"; done
  } > /etc/sysctl.d/60-cis-runner.conf
  if [[ -f /etc/sysctl.conf ]]; then
    _ipv6_re="$(echo "${_ipv6_keys}" | tr ' ' '|' | sed 's/\./\\./g')"
    sed -ri "\\@^[[:space:]]*#?[[:space:]]*(${_ipv6_re})[[:space:]]*=@d" /etc/sysctl.conf
    { echo "# CIS 3.3.x - asserted by bootstrap_agent.sh"; for _k in ${_ipv6_keys}; do echo "${_k} = 0"; done; } >> /etc/sysctl.conf
  fi
  for _k in ${_ipv6_keys}; do sysctl -w "${_k}=0" >/dev/null 2>&1; done
  sysctl --system >/dev/null 2>&1

  # -- §6.1.1.3 / §6.1.2.3 / §6.1.2.4 journald Storage / Compress /
  #    rotation caps. NOT ForwardToSyslog (see cis_hardening_skip_rules -
  #    rsyslog -> Azure Monitor Agent is how this fleet is observed).
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/60-cis-runner.conf <<'JRNL'
# CIS 6.1.1.3 / 6.1.2.3 / 6.1.2.4 - asserted by bootstrap_agent.sh
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
SystemKeepFree=1G
RuntimeMaxUse=100M
RuntimeKeepFree=200M
MaxFileSec=1month
JRNL
  systemctl restart systemd-journald 2>/dev/null

  # -- §6.1.2.1.4 systemd-journal-remote must be masked (we never ship
  #    the journal to a remote collector).
  systemctl --now mask systemd-journal-remote.socket systemd-journal-remote.service 2>/dev/null

  # -- §5.3.1.3 libpam-pwquality present; §5.3.3.2.x quality values.
  #    pwquality.conf is inert until pam_pwquality is in common-password;
  #    it cannot block a login on its own.
  apt_get install -y libpam-pwquality || echo "WARN: libpam-pwquality install failed"
  # Write the values to BOTH the flat file and the drop-in dir - the goss
  # audit greps pwquality.conf.d/*.conf for some 5.3.3.2.x checks.
  mkdir -p /etc/security/pwquality.conf.d
  cat > /etc/security/pwquality.conf.d/60-cis-runner.conf <<'PWQ'
# CIS 5.3.3.2.x - asserted by bootstrap_agent.sh enforce_runner_safe_cis()
difok = 2
minlen = 14
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
minclass = 4
maxrepeat = 3
maxsequence = 3
dictcheck = 1
enforcing = 1
enforce_for_root
retry = 3
PWQ
  pwq=/etc/security/pwquality.conf
  if [[ -f "${pwq}" ]]; then
    sed -ri '/^[[:space:]]*#?[[:space:]]*(difok|minlen|dcredit|ucredit|lcredit|ocredit|minclass|maxrepeat|maxsequence|dictcheck|enforcing|enforce_for_root|retry)\b/d' "${pwq}"
    cat /etc/security/pwquality.conf.d/60-cis-runner.conf >> "${pwq}"
  fi

  # -- §5.3.3.1.x faillock thresholds. Inert until pam_faillock is wired
  #    into common-auth by the role; sane if/when it is.
  flk=/etc/security/faillock.conf
  touch "${flk}"
  sed -ri '/^[[:space:]]*#?[[:space:]]*(deny|unlock_time|fail_interval)\b/d' "${flk}"
  cat >> "${flk}" <<'FLK'
# CIS 5.3.3.1.x - asserted by bootstrap_agent.sh enforce_runner_safe_cis()
deny = 5
fail_interval = 900
unlock_time = 900
FLK

  # -- §5.4.1.x password aging (login.defs + /etc/default/useradd + the
  #    existing human accounts). Key-auth accounts are unaffected by
  #    password expiry.
  ld=/etc/login.defs
  sed -ri 's/^[[:space:]]*#?[[:space:]]*(PASS_MAX_DAYS)[[:space:]]+.*/\1\t365/; s/^[[:space:]]*#?[[:space:]]*(PASS_MIN_DAYS)[[:space:]]+.*/\1\t1/; s/^[[:space:]]*#?[[:space:]]*(PASS_WARN_AGE)[[:space:]]+.*/\1\t7/; s/^[[:space:]]*#?[[:space:]]*(UMASK)[[:space:]]+.*/\1\t027/' "${ld}"
  grep -qE '^PASS_MAX_DAYS[[:space:]]' "${ld}" || printf 'PASS_MAX_DAYS\t365\n' >> "${ld}"
  grep -qE '^PASS_MIN_DAYS[[:space:]]' "${ld}" || printf 'PASS_MIN_DAYS\t1\n'   >> "${ld}"
  grep -qE '^PASS_WARN_AGE[[:space:]]' "${ld}" || printf 'PASS_WARN_AGE\t7\n'   >> "${ld}"
  useradd -D -f 30 2>/dev/null
  while IFS=: read -r _u _ _uid _ _ _ _sh; do
    [[ "${_uid}" =~ ^[0-9]+$ ]] || continue
    [[ "${_uid}" -ge 1000 && "${_uid}" -lt 65534 ]] || continue
    case "${_sh}" in */nologin|*/false|"") continue ;; esac
    chage --maxdays 365 --mindays 1 --warndays 7 --inactive 30 "${_u}" 2>/dev/null
  done < /etc/passwd

  # -- §5.4.2.6 root umask, §5.4.3.2 shell TMOUT, §5.4.3.3 default umask.
  for _rc in /root/.bashrc /root/.bash_profile /root/.profile; do
    touch "${_rc}"
    sed -ri '/^[[:space:]]*umask[[:space:]]+/d' "${_rc}"
    echo 'umask 0027' >> "${_rc}"
  done
  cat > /etc/profile.d/60-cis-runner.sh <<'PROF'
# CIS 5.4.3.2 / 5.4.3.3 - asserted by bootstrap_agent.sh
umask 027
TMOUT=900
export TMOUT
PROF
  chmod 0644 /etc/profile.d/60-cis-runner.sh

  # -- §5.2.6 sudo authentication timeout.
  echo 'Defaults timestamp_timeout=15' > /etc/sudoers.d/60-cis-timeout
  chmod 0440 /etc/sudoers.d/60-cis-timeout
  visudo -cf /etc/sudoers.d/60-cis-timeout >/dev/null 2>&1 || rm -f /etc/sudoers.d/60-cis-timeout

  # -- §5.2.7 restrict `su` to an empty group (root only). /etc/pam.d/su
  #    is not pam-auth-update managed, so a direct edit is stable.
  groupadd -f nosugroup 2>/dev/null
  if [[ -f /etc/pam.d/su ]] && ! grep -qE '^[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so.*group=nosugroup' /etc/pam.d/su; then
    sed -ri '/^[[:space:]]*#?[[:space:]]*auth[[:space:]]+required[[:space:]]+pam_wheel\.so/d' /etc/pam.d/su
    sed -i '1a auth       required   pam_wheel.so use_uid group=nosugroup' /etc/pam.d/su
  fi

  # -- §5.1.x sshd. The audit greps these out of the main sshd_config, so
  #    they go in the main file (prepended, ahead of any Match block),
  #    validated with `sshd -t` before the file is swapped in. Inbound
  #    SSH is not on the runner's critical path (it egresses to GitHub);
  #    5.1.4 is satisfied with a documentation comment rather than a real
  #    Allow/Deny list, so no admin gets locked out.
  sshd=/etc/ssh/sshd_config
  if [[ -f "${sshd}" ]]; then
    _new="$(mktemp)"
    {
      echo '# --- CIS 5.1 backstop (bootstrap_agent.sh enforce_runner_safe_cis) ---'
      printf '%s\n' \
        'PermitRootLogin no' 'PermitEmptyPasswords no' 'PermitUserEnvironment no' \
        'HostbasedAuthentication no' 'IgnoreRhosts yes' 'MaxAuthTries 4' 'MaxSessions 10' \
        'LoginGraceTime 60' 'MaxStartups 10:30:60' 'ClientAliveInterval 15' \
        'ClientAliveCountMax 3' 'Banner /etc/issue.net'
      echo '# CIS 5.1.4 sshd access tokens (host access fronted by the Azure NSG): AllowUsers AllowGroups DenyUsers DenyGroups'
      echo '# --- end CIS 5.1 backstop ---'
      grep -vE '^[[:space:]]*#?[[:space:]]*(PermitRootLogin|PermitEmptyPasswords|PermitUserEnvironment|HostbasedAuthentication|IgnoreRhosts|MaxAuthTries|MaxSessions|LoginGraceTime|MaxStartups|ClientAliveInterval|ClientAliveCountMax|Banner)\b' "${sshd}" \
        | grep -vE '^# (--- (CIS 5\.1 backstop|end CIS 5\.1 backstop)|CIS 5\.1\.4 sshd access tokens)'
    } > "${_new}"
    if sshd -t -f "${_new}" 2>/dev/null; then
      cat "${_new}" > "${sshd}"
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    else
      echo "WARN: sshd rejected the CIS 5.1 backstop - /etc/ssh/sshd_config left as-is"
    fi
    rm -f "${_new}"
  fi

  # keep the runner + watcher up through any sshd / pam / journald bounce
  systemctl restart 'actions.runner.*' 2>/dev/null || { cd /opt/actions-runner && ./svc.sh start; }
  systemctl restart terminate-watcher 2>/dev/null

  echo "=== Runner-safe CIS backstop complete ==="
)

if [[ "${CIS_HARDENING_ENABLED:-false}" == "true" ]]; then
  harden_cis || echo "WARN: CIS hardening did not complete cleanly - the runner is up regardless. See the log above / Log Analytics."
  enforce_runner_safe_cis || echo "WARN: runner-safe CIS backstop hit an error - see the log above."
else
  echo "CIS hardening disabled (CIS_HARDENING_ENABLED='${CIS_HARDENING_ENABLED:-unset}') - skipping."
fi

# ---------------------------------------------------------------------
# 9. CIS audit harness (optional)
#
# When CIS_AUDIT_ENABLED is "true" (var.cis_audit_enabled), install a
# fixed, self-validating wrapper and a scoped sudoers entry so the
# cis-benchmark.yml workflow can score this host against the CIS Ubuntu
# 24.04 Benchmark. The audit is READ-ONLY - ansible-lockdown/
# UBUNTU24-CIS-Audit + goss, the companion to the remediation role.
# The sudoers grant is exactly one command that only ever runs goss and
# writes reports to /var/lib/cis-audit.
# ---------------------------------------------------------------------
install_cis_audit() {
  local wrapper=/usr/local/sbin/cis-audit
  local sudoers=/etc/sudoers.d/90-cis-audit

  install -d -m 0755 /var/lib/cis-audit

  cat > "${wrapper}" <<'CISAUDIT'
#!/usr/bin/env bash
# Managed by bootstrap_agent.sh (var.cis_audit_enabled). READ-ONLY CIS
# benchmark audit of this host via ansible-lockdown/UBUNTU24-CIS-Audit
# (goss). Changes nothing; writes world-readable reports to
# /var/lib/cis-audit/. Usage: cis-audit [level1|level2]  (default level1)
set -euo pipefail

LEVEL="${1:-level1}"
case "${LEVEL}" in
  level1|level2) ;;
  *) echo "cis-audit: level must be 'level1' or 'level2'" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "cis-audit: must run as root (via sudo)" >&2; exit 1; }

GOSS_VERSION="v0.4.9"
GOSS_SHA256="87dd36cfa1b8b50554e6e2ca29168272e26755b19ba5438341f7c66b36decc19"
AUDIT_REF="benchmark_v1.0.0"
AUDIT_DIR="/opt/UBUNTU24-CIS-Audit"
OUT="/var/lib/cis-audit"
export DEBIAN_FRONTEND=noninteractive
mkdir -p "${OUT}"

if ! /usr/local/bin/goss --version 2>/dev/null | grep -q "${GOSS_VERSION#v}"; then
  t="$(mktemp)"
  curl -fsSL -o "${t}" "https://github.com/goss-org/goss/releases/download/${GOSS_VERSION}/goss-linux-amd64"
  echo "${GOSS_SHA256}  ${t}" | sha256sum -c - || { echo "cis-audit: goss checksum mismatch" >&2; rm -f "${t}"; exit 1; }
  install -m 0755 "${t}" /usr/local/bin/goss; rm -f "${t}"
fi
command -v git >/dev/null || { apt-get update -qq && apt-get install -y -qq git; }
command -v jq  >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; }

if [ -d "${AUDIT_DIR}/.git" ]; then
  git -C "${AUDIT_DIR}" fetch -q --depth 1 origin "${AUDIT_REF}" && git -C "${AUDIT_DIR}" checkout -q FETCH_HEAD
else
  rm -rf "${AUDIT_DIR}"
  git clone -q --depth 1 --branch "${AUDIT_REF}" \
    https://github.com/ansible-lockdown/UBUNTU24-CIS-Audit.git "${AUDIT_DIR}"
fi

# Start from the audit's own vars, then layer the SAME runner-safe
# opt-outs harden_cis() applied, so the audit doesn't fail controls we
# deliberately skipped for the runner's sake.
#
# The overrides use the same ubtu24cis_* keys as vars/CIS.yml, so a
# naive cat/append produces duplicate YAML mapping keys - goss's yaml
# parser rejects that outright (no results at all, not just a bad
# value). Drop each key from the base copy before appending its
# override so every key appears exactly once.
vars="${OUT}/audit-vars.yml"
overrides_raw="$(mktemp)"
{
  [ -f /etc/ghrunner/cis-overrides.yml ] && grep -E '^(ubtu24cis_|skip_reboot)' /etc/ghrunner/cis-overrides.yml || true
  # explicit LEVEL wins over whatever cis-overrides.yml carried for these
  echo "ubtu24cis_level_1: true"
  echo "ubtu24cis_level_2: $([ "${LEVEL}" = level2 ] && echo true || echo false)"
} > "${overrides_raw}"
overrides="$(mktemp)"
awk -F: '{ key[$1] = $0 } END { for (k in key) print key[k] }' "${overrides_raw}" > "${overrides}"
rm -f "${overrides_raw}"
override_keys="$(sed -nE 's/^([A-Za-z0-9_]+):.*/\1/p' "${overrides}" | paste -sd'|' -)"
if [ -n "${override_keys}" ]; then
  grep -vE "^(${override_keys}):" "${AUDIT_DIR}/vars/CIS.yml" > "${vars}"
else
  cp "${AUDIT_DIR}/vars/CIS.yml" "${vars}"
fi
{ echo ""; cat "${overrides}"; } >> "${vars}"
rm -f "${overrides}"

# Upstream vars/CIS.yml ships list entries like ubtu24cis_time_pool with
# a bare '- name: x' and no 'options:' sibling; goss templates such as
# cis_2.3.3.1.yml dereference .options on every entry unconditionally
# and hard-fail the whole run ("map has no entry for key \"options\"")
# if it's missing. Backfill a default wherever it's absent.
sed -i -E '/^([[:space:]]*)-[[:space:]]*name:[[:space:]]*[^[:space:]]+[[:space:]]*$/{
  N
  /\n[[:space:]]*options:/!s/^([[:space:]]*)(-[[:space:]]*name:[[:space:]]*[^[:space:]]+[[:space:]]*)\n/\1\2\n\1  options: iburst maxsources 4\n/
}' "${vars}"

cd "${AUDIT_DIR}"
AUDIT_BIN=/usr/local/bin/goss AUDIT_CONTENT_LOCATION=/opt \
  ./run_audit.sh -f json -o "${OUT}/results.json" -v "${vars}" || true

tc=$(jq -r '.summary."test-count" // 0' "${OUT}/results.json" 2>/dev/null || echo 0)
fc=$(jq -r '.summary."failed-count" // 0' "${OUT}/results.json" 2>/dev/null || echo 0)
sl=$(jq -r '.summary."summary-line" // ""' "${OUT}/results.json" 2>/dev/null || echo "")
if ! { [ -n "${tc}" ] && [ "${tc}" -gt 0 ]; } 2>/dev/null; then
  echo "cis-audit: no goss results parsed - see ${OUT}/results.json" >&2
  echo "cis-audit: --- ${OUT}/results.json (first 40 lines) ---" >&2
  head -n 40 "${OUT}/results.json" >&2 2>/dev/null || echo "cis-audit: (file missing or empty)" >&2
  echo "cis-audit: --- ${vars} (merged vars fed to goss) ---" >&2
  cat "${vars}" >&2 2>/dev/null || true
  exit 1
fi
sk=$(printf '%s' "${sl}" | sed -n 's/.*Skipped: *\([0-9][0-9]*\).*/\1/p'); sk=${sk:-0}
den=$(( tc - sk )); [ "${den}" -lt 1 ] && den="${tc}"
pc=$(( tc - fc - sk )); [ "${pc}" -lt 0 ] && pc=0
rate=$(( pc * 100 / den ))
printf 'PROFILE=cis_%s_server\nWHEN=%s\nTOTAL=%s\nPASS=%s\nFAIL=%s\nSKIPPED=%s\nRATE=%s\n' \
  "${LEVEL}" "$(date -u +%FT%TZ)" "${tc}" "${pc}" "${fc}" "${sk}" "${rate}" > "${OUT}/summary.env"

# --- diagnostics bundle (read-only) -----------------------------------
# Collected here because this wrapper already holds the one root grant
# the cis-benchmark workflow is given - keeps the sudoers surface at
# exactly one command. Everything below only reads. Written
# world-readable under ${OUT}/diag so the workflow's upload step ships it
# alongside the report; token-shaped strings are scrubbed first.
( set +e
  DIAG="${OUT}/diag"
  rm -rf "${DIAG}"; mkdir -p "${DIAG}/customscript"

  # bootstrap + CIS hardening (ansible) output - last 8 MB is plenty to
  # see where a role run aborted
  tail -c 8388608 /var/log/bootstrap/bootstrap_agent_detail.log > "${DIAG}/bootstrap_agent_detail.log" 2>/dev/null
  journalctl -t ghrunner-bootstrap --no-pager > "${DIAG}/journal-ghrunner-bootstrap.log" 2>/dev/null

  # runner + watcher + kernel
  journalctl -u 'actions.runner.*' --no-pager -n 3000 > "${DIAG}/journal-actions-runner.log"     2>/dev/null
  journalctl -u terminate-watcher   --no-pager -n 800  > "${DIAG}/journal-terminate-watcher.log" 2>/dev/null
  journalctl -k --no-pager -n 800                       > "${DIAG}/journal-kernel.log"            2>/dev/null

  # Azure CustomScript extension's own capture of the bootstrap run
  for d in /var/lib/waagent/custom-script/download/*/; do
    [ -d "${d}" ] || continue
    dst="${DIAG}/customscript/$(basename "${d}")"; mkdir -p "${dst}"
    cp -f "${d}stdout" "${d}stderr" "${dst}/" 2>/dev/null
  done
  cp -f /var/log/azure/*/*.log            "${DIAG}/" 2>/dev/null
  cp -f /var/log/cloud-init-output.log    "${DIAG}/" 2>/dev/null
  cloud-init status --long > "${DIAG}/cloud-init-status.txt" 2>/dev/null

  # hardening state + the exact vars each side used (copy under non-dot
  # names so an empty/missing dotfile is obvious in the bundle listing)
  cp -f /var/lib/ghrunner/.hardened    "${DIAG}/hardened.txt"    2>/dev/null || echo "(no /var/lib/ghrunner/.hardened)"    > "${DIAG}/hardened.txt"
  cp -f /var/lib/ghrunner/.bootstrapped "${DIAG}/bootstrapped.txt" 2>/dev/null || echo "(no /var/lib/ghrunner/.bootstrapped)" > "${DIAG}/bootstrapped.txt"
  cp -f /etc/ghrunner/cis-overrides.yml "${DIAG}/" 2>/dev/null

  # system context - explains the partition + logging skips at a glance
  {
    echo "### uname";                uname -a
    echo; echo "### os-release";     cat /etc/os-release
    echo; echo "### findmnt";        findmnt -A
    echo; echo "### lsblk";          lsblk
    echo; echo "### df -h";          df -h
    echo; echo "### systemctl --failed"; systemctl --failed --no-pager
    echo; echo "### unit states"
    for u in ssh rsyslog systemd-journald systemd-journald.socket auditd apparmor \
             ufw nftables docker systemd-journal-remote.socket systemd-journal-remote.service; do
      printf '%-34s enabled=%-10s active=%s\n' "${u}" \
        "$(systemctl is-enabled "${u}" 2>/dev/null || echo -)" \
        "$(systemctl is-active  "${u}" 2>/dev/null || echo -)"
    done
    echo; echo "### relevant packages"
    dpkg -l 2>/dev/null | grep -E '^ii[[:space:]]+(libpam-pwquality|auditd|apparmor|ansible|rsyslog|systemd-journal-remote|ufw|nftables)[[:space:]]' || true
    echo; echo "### sshd -T (effective, sorted, first 80)"
    sshd -T 2>/dev/null | sort | head -n 80
    echo; echo "### journald.conf (merged)"
    systemd-analyze cat-config systemd/journald.conf 2>/dev/null
  } > "${DIAG}/system-context.txt" 2>&1

  # scrub token / key / JWT shaped strings before anything leaves the box
  grep -rlIE '(gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN[A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})' "${DIAG}" 2>/dev/null \
  | while IFS= read -r f; do
      sed -ri 's/gh[pousr]_[A-Za-z0-9]{20,}/<redacted-token>/g; s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/<redacted-jwt>/g' "${f}"
      awk '/-----BEGIN[A-Z ]*PRIVATE KEY-----/{print "<redacted-private-key>";s=1;next} /-----END[A-Z ]*PRIVATE KEY-----/{s=0;next} !s' "${f}" > "${f}.s" && mv "${f}.s" "${f}"
    done

  tar -C "${OUT}" -czf "${OUT}/diag.tgz" diag 2>/dev/null
) || true

chmod -R a+rX "${OUT}"
echo "cis-audit: ${LEVEL} -> ${pc}/${den} passed (${rate}%), ${fc} failed, ${sk} skipped. Reports (+ diag/) in ${OUT}/"
CISAUDIT
  chmod 0755 "${wrapper}"

  # Exactly one command, no wildcards. The wrapper validates its own arg.
  printf 'actions-runner ALL=(root) NOPASSWD: %s ""\nactions-runner ALL=(root) NOPASSWD: %s level1, %s level2\n' \
    "${wrapper}" "${wrapper}" "${wrapper}" > "${sudoers}"
  chmod 0440 "${sudoers}"
  if ! visudo -cf "${sudoers}" >/dev/null 2>&1; then
    echo "WARN: ${sudoers} failed visudo check - removing it"; rm -f "${sudoers}"; return 1
  fi
  echo "cis-audit harness installed (${wrapper} + ${sudoers})."
}

if [[ "${CIS_AUDIT_ENABLED:-false}" == "true" ]]; then
  install_cis_audit || echo "WARN: cis-audit harness install failed - the cis-benchmark workflow won't work until this succeeds."
else
  echo "CIS audit harness disabled (CIS_AUDIT_ENABLED='${CIS_AUDIT_ENABLED:-unset}') - skipping."
fi

# Record the version just completed. Matching this against the injected
# BOOTSTRAP_VERSION is what lets an unchanged bootstrap skip and a bumped
# one re-run on the next CustomScript execution (see the re-run guard at
# the top). Falls back to a timestamp when run by hand with no version.
mkdir -p "$(dirname "${BOOTSTRAP_SENTINEL}")"
printf '%s\n' "${BOOTSTRAP_VERSION:-$(date -u +%FT%TZ)}" > "${BOOTSTRAP_SENTINEL}"

echo "Bootstrap complete at $(date -u) (version ${BOOTSTRAP_VERSION:-n/a}). Runner ${INSTANCE_NAME} registered and running."
