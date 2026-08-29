#!/usr/bin/env bash
# bootstrap_agent.sh
# Converted from bootstrap_agent.ps1 (Azure DevOps / Windows) to Ubuntu / GitHub Actions.
# Runs once per instance boot via the CustomScript extension in main.tf.
#
# Does two things in one pass, matching the original script's shape:
#   1. Installs the tooling this org's pipelines need
#   2. Registers + runs this instance as an EPHEMERAL GitHub Actions runner
#      (auto-deregisters after one job - VMSS scale-in reclaims the instance)
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
# Run-once guard
#
# The CustomScript extension (main.tf) re-executes its commandToExecute
# on every instance model update - a VM resize, an OS image bump, VMSS
# auto-repair. This script is a first-boot provisioner and is NOT
# idempotent: it registers an EPHEMERAL runner, useradds actions-runner,
# installs systemd units, and adds apt repos. Re-running it on an
# already-configured instance fails partway and flips the whole
# extension to "provisioning failed".
#
# The sentinel is written as the very last step below, so a first boot
# that fails midway is still retried on the next extension run.
# commandToExecute checks for the same file and skips the download too.
# ---------------------------------------------------------------------
BOOTSTRAP_SENTINEL="/var/lib/ghrunner/.bootstrapped"
if [[ -f "${BOOTSTRAP_SENTINEL}" ]]; then
  echo "Bootstrap already completed ($(cat "${BOOTSTRAP_SENTINEL}" 2>/dev/null || echo 'date unknown')) - nothing to do."
  exit 0
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
KEYVAULT_SECRET_NAME="github-app-token"     # short-lived GitHub App installation token
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
  curl jq zip unzip ca-certificates apt-transport-https gnupg \
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
# 6. GitHub Actions runner - download, register, run (ephemeral)
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

# --- Fetch GitHub App/PAT token from Key Vault via this VM's managed identity ---
# Each hop is checked and logged separately (HTTP status only, never the
# token value) so a failure here says WHICH hop broke instead of a generic
# "failed to obtain token".

# 1. IMDS -> AAD token for Key Vault
imds_resp=$(curl -s -w '\n%{http_code}' -H "Metadata:true" --retry 5 --retry-delay 3 --retry-connrefused \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" || true)
imds_code=$(printf '%s' "${imds_resp}" | tail -n1)
KV_TOKEN=$(printf '%s' "${imds_resp}" | sed '$d' | jq -r '.access_token // empty' 2>/dev/null || true)
if [[ -z "${KV_TOKEN}" ]]; then
  echo "FATAL: IMDS did not return an AAD token (HTTP ${imds_code}). Is a user-assigned identity attached to the VMSS?" >&2
  printf '%s\n' "${imds_resp}" | sed '$d' | head -c 400 >&2; echo >&2
  exit 1
fi

# 2. Key Vault -> the GitHub App installation token secret
kv_resp=$(curl -s -w '\n%{http_code}' --retry 5 --retry-delay 3 \
  -H "Authorization: Bearer ${KV_TOKEN}" \
  "https://${KEYVAULT_NAME}.vault.azure.net/secrets/${KEYVAULT_SECRET_NAME}?api-version=7.4" || true)
kv_code=$(printf '%s' "${kv_resp}" | tail -n1)
GITHUB_TOKEN=$(printf '%s' "${kv_resp}" | sed '$d' | jq -r '.value // empty' 2>/dev/null || true)
if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "FATAL: Key Vault ${KEYVAULT_NAME} did not return secret '${KEYVAULT_SECRET_NAME}' (HTTP ${kv_code})." >&2
  echo "  403 => the VMSS identity lacks 'Key Vault Secrets User'. 404 => the secret doesn't exist / never seeded." >&2
  exit 1
fi

# 3. GitHub -> a short-lived runner REGISTRATION token (org or repo)
reg_resp=$(curl -s -w '\n%{http_code}' --retry 3 --retry-delay 3 -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API_BASE}/actions/runners/registration-token" || true)
reg_code=$(printf '%s' "${reg_resp}" | tail -n1)
reg_body=$(printf '%s' "${reg_resp}" | sed '$d')
REG_TOKEN=$(printf '%s' "${reg_body}" | jq -r '.token // empty' 2>/dev/null || true)
if [[ -z "${REG_TOKEN}" ]]; then
  echo "FATAL: ${GH_API_BASE}/actions/runners/registration-token returned HTTP ${reg_code}, no token." >&2
  echo "  401 => the github-app-token secret in Key Vault is expired (App tokens last ~1h - is refresh-github-app-token.yml running?)." >&2
  echo "  403 => the GitHub App lacks 'Administration: Read and write' on ${GH_API_BASE##*/repos/} (repo scope) or 'Self-hosted runners' (org scope)." >&2
  echo "  404 => wrong owner/repo in GH_API_BASE, or the App isn't installed there." >&2
  printf '  body: %s\n' "$(printf '%s' "${reg_body}" | jq -c '{message,documentation_url}' 2>/dev/null || printf '%s' "${reg_body}" | head -c 300)" >&2
  exit 1
fi

INSTANCE_NAME="vmss-runner-$(hostname)"

# Skip re-registration if this instance already has a configured runner
# (idle, waiting for a job). Ephemeral runners delete .runner themselves
# after their one job, so a missing .runner here just means "register
# fresh". --replace overwrites any stale server-side registration that
# still holds this name (e.g. a prior instance with the same hostname).
if [[ -f /opt/actions-runner/.runner ]]; then
  echo "Runner already configured - leaving existing registration in place."
else
  sudo -u actions-runner ./config.sh \
    --url "${GH_RUNNER_URL}" \
    --token "${REG_TOKEN}" \
    --name "${INSTANCE_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --runnergroup "${RUNNER_GROUP}" \
    --ephemeral \
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
KEYVAULT_NAME="${KEYVAULT_NAME}"
KEYVAULT_SECRET_NAME="${KEYVAULT_SECRET_NAME}"
RUNNER_DIR="/opt/actions-runner"
POLL_INTERVAL=5

log() { echo "[terminate-watcher] \$(date -u +%FT%TZ) \$*"; }

get_github_app_token() {
  local kv_token gh_token
  kv_token=\$(curl -s -H "Metadata:true" \\
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \\
    | jq -r '.access_token')
  gh_token=\$(curl -s -H "Authorization: Bearer \${kv_token}" \\
    "https://\${KEYVAULT_NAME}.vault.azure.net/secrets/\${KEYVAULT_SECRET_NAME}?api-version=7.4" \\
    | jq -r '.value')
  echo "\${gh_token}"
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
    log "config.sh remove failed (runner may already be deregistered, e.g. it just finished an ephemeral job) - continuing"
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

# Mark this instance done so the CustomScript extension doesn't re-run
# bootstrap on the next model update (resize / image bump / auto-repair).
mkdir -p "$(dirname "${BOOTSTRAP_SENTINEL}")"
date -u +%FT%TZ > "${BOOTSTRAP_SENTINEL}"

echo "Bootstrap complete at $(date -u). Runner ${INSTANCE_NAME} registered and running."
