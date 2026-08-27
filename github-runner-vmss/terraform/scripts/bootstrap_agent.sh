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
exec > >(tee -a /var/log/bootstrap/bootstrap_agent_detail.log) 2>&1

echo "Starting bootstrap at $(date -u)"

# ---------------------------------------------------------------------
# Config - adjust for your org/repo and Key Vault
# ---------------------------------------------------------------------
GITHUB_ORG="gavinwun"
KEYVAULT_NAME="kv-ghrunner-25818"
KEYVAULT_SECRET_NAME="github-app-token"     # short-lived GitHub App installation token
RUNNER_VERSION="2.337.0"                     # pin, bump deliberately
DOTNET_CHANNEL="10.0"
RUNNER_LABELS="self-hosted,linux,x64,vmss"
RUNNER_GROUP="default"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------
# 1. Base packages
# ---------------------------------------------------------------------
apt-get update
apt-get install -y \
  curl jq zip unzip ca-certificates apt-transport-https gnupg \
  lsb-release git build-essential libicu-dev

# ---------------------------------------------------------------------
# 2. Node.js (NodeSource LTS)
# ---------------------------------------------------------------------
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y nodejs

# ---------------------------------------------------------------------
# 3. Azure CLI (Microsoft apt repo)
# ---------------------------------------------------------------------
curl -sL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ ${AZ_REPO} main" \
  | tee /etc/apt/sources.list.d/azure-cli.list

apt-get update
apt-get install -y azure-cli

# ---------------------------------------------------------------------
# 4. .NET SDK (Microsoft apt repo)
# ---------------------------------------------------------------------
UBUNTU_VER=$(lsb_release -rs)
wget "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VER}/packages-microsoft-prod.deb" \
  -O /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
rm /tmp/packages-microsoft-prod.deb

apt-get update
apt-get install -y "dotnet-sdk-${DOTNET_CHANNEL}"

# ---------------------------------------------------------------------
# 5. Docker (skip if workflows don't need docker-in-docker on the runner)
# ---------------------------------------------------------------------
apt-get install -y docker.io
systemctl enable --now docker

# ---------------------------------------------------------------------
# 6. GitHub Actions runner - download, register, run (ephemeral)
# ---------------------------------------------------------------------
mkdir -p /opt/actions-runner
cd /opt/actions-runner

curl -o actions-runner-linux-x64.tar.gz -L \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf actions-runner-linux-x64.tar.gz
rm actions-runner-linux-x64.tar.gz

./bin/installdependencies.sh

id -u actions-runner &>/dev/null || useradd -m -s /bin/bash actions-runner
chown -R actions-runner:actions-runner /opt/actions-runner

# --- Fetch GitHub App/PAT token from Key Vault via this VM's managed identity ---
KV_TOKEN=$(curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token')

GITHUB_TOKEN=$(curl -s \
  -H "Authorization: Bearer ${KV_TOKEN}" \
  "https://${KEYVAULT_NAME}.vault.azure.net/secrets/${KEYVAULT_SECRET_NAME}?api-version=7.4" \
  | jq -r '.value')

# --- Exchange for a short-lived runner REGISTRATION token (org-level) ---
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
  | jq -r '.token')

if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Failed to obtain GitHub runner registration token" >&2
  exit 1
fi

INSTANCE_NAME="vmss-runner-$(hostname)"

sudo -u actions-runner ./config.sh \
  --url "https://github.com/${GITHUB_ORG}" \
  --token "${REG_TOKEN}" \
  --name "${INSTANCE_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --runnergroup "${RUNNER_GROUP}" \
  --ephemeral \
  --unattended

# Install as a systemd service so it survives the bootstrap script exiting,
# rather than running in the foreground and blocking the extension.
./svc.sh install actions-runner
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
GITHUB_ORG="${GITHUB_ORG}"
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
    "https://api.github.com/orgs/\${GITHUB_ORG}/actions/runners/remove-token" \\
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

echo "Bootstrap complete at $(date -u). Runner ${INSTANCE_NAME} registered and running."
