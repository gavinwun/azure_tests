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

  # ---- run it: this host only, local connection ---------------------
  ANSIBLE_LOCALHOST_WARNING=False \
  ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
  ANSIBLE_RETRY_FILES_ENABLED=False \
  ansible-playbook "${repo_dir}/site.yml" \
    --connection local \
    --inventory 'localhost,' \
    --limit localhost \
    --tags "${tags}" \
    --extra-vars "@${vars_file}" || return 1

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
  printf '%s  version=%s  ref=%s\n' "$(date -u +%FT%TZ)" "${BOOTSTRAP_VERSION:-none}" "${ref}" \
    > /var/lib/ghrunner/.hardened
  echo "=== CIS hardening complete ==="
}

if [[ "${CIS_HARDENING_ENABLED:-false}" == "true" ]]; then
  harden_cis || echo "WARN: CIS hardening did not complete cleanly - the runner is up regardless. See the log above / Log Analytics."
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
chmod -R a+rX "${OUT}"
echo "cis-audit: ${LEVEL} -> ${pc}/${den} passed (${rate}%), ${fc} failed, ${sk} skipped. Reports in ${OUT}/"
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
