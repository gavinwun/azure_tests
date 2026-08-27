#!/usr/bin/env bash
# entrypoint.sh - the container equivalent of bootstrap_agent.sh's
# registration section. Runs once per container group (restart_policy:
# Never in reconcile-aci-runners.yml), registers as an ephemeral runner,
# runs exactly one job, then exits - the container group goes to
# "Terminated" state and reconcile-aci-runners.yml deletes it on its
# next pass.
set -euo pipefail

: "${GITHUB_ORG:?GITHUB_ORG env var required}"
: "${KEYVAULT_NAME:?KEYVAULT_NAME env var required}"
: "${KEYVAULT_SECRET_NAME:=github-app-token}"

RUNNER_LABELS="self-hosted,linux,x64,aci"
RUNNER_GROUP="default"

cd /opt/actions-runner

# --- Fetch GitHub App token from Key Vault via this container's
#     user-assigned managed identity (--assign-identity in
#     reconcile-aci-runners.yml). Same IMDS pattern as the VMSS side. ---
KV_TOKEN=$(curl -s -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token')

GITHUB_TOKEN=$(curl -s \
  -H "Authorization: Bearer ${KV_TOKEN}" \
  "https://${KEYVAULT_NAME}.vault.azure.net/secrets/${KEYVAULT_SECRET_NAME}?api-version=7.4" \
  | jq -r '.value')

if [[ -z "${GITHUB_TOKEN}" || "${GITHUB_TOKEN}" == "null" ]]; then
  echo "Failed to fetch GitHub App token from Key Vault" >&2
  exit 1
fi

# --- Exchange for a short-lived runner REGISTRATION token ---
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token" \
  | jq -r '.token')

if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Failed to obtain GitHub runner registration token" >&2
  exit 1
fi

INSTANCE_NAME="aci-runner-$(hostname)"

sudo -u actions-runner ./config.sh \
  --url "https://github.com/${GITHUB_ORG}" \
  --token "${REG_TOKEN}" \
  --name "${INSTANCE_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --runnergroup "${RUNNER_GROUP}" \
  --ephemeral \
  --unattended

echo "Runner ${INSTANCE_NAME} registered. Waiting for a job..."

# Foreground, not a systemd service - this container's lifetime IS the
# runner's lifetime. --ephemeral means run.sh exits on its own after
# exactly one job, at which point this entrypoint (and the container)
# exits too, and the container group goes to "Terminated".
sudo -u actions-runner ./run.sh

echo "Job complete, runner exiting."
