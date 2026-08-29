#!/usr/bin/env bash
# entrypoint.sh - the container equivalent of bootstrap_agent.sh's
# registration section. Runs once per container group (restart_policy:
# Never in reconcile-aci-runners.yml), registers as an ephemeral runner,
# runs exactly one job, then exits - the container group goes to
# "Terminated" state and reconcile-aci-runners.yml deletes it on its
# next pass.
set -euo pipefail

: "${GITHUB_SCOPE:=org}"                    # "org" or "repo"
: "${KEYVAULT_NAME:?KEYVAULT_NAME env var required}"
# This container mints its own GitHub App installation token from the App
# private key in Key Vault (secret KEYVAULT_APP_KEY_SECRET_NAME) - no
# pre-stored short-lived token. reconcile-aci-runners.yml must pass
# GITHUB_APP_ID via --environment-variables.
: "${GITHUB_APP_ID:?GITHUB_APP_ID env var required (numeric GitHub App ID)}"
: "${KEYVAULT_APP_KEY_SECRET_NAME:=github-app-private-key}"

# Scope -> REST base + attach URL. "org" needs GITHUB_ORG; "repo" needs
# GITHUB_REPO ("owner/repo") - use "repo" for a personal account.
if [[ "${GITHUB_SCOPE}" == "repo" ]]; then
  : "${GITHUB_REPO:?GITHUB_REPO env var required when GITHUB_SCOPE=repo}"
  GH_API_BASE="https://api.github.com/repos/${GITHUB_REPO}"
  GH_RUNNER_URL="https://github.com/${GITHUB_REPO}"
else
  : "${GITHUB_ORG:?GITHUB_ORG env var required when GITHUB_SCOPE=org}"
  GH_API_BASE="https://api.github.com/orgs/${GITHUB_ORG}"
  GH_RUNNER_URL="https://github.com/${GITHUB_ORG}"
fi

RUNNER_LABELS="self-hosted,linux,x64,aci"
RUNNER_GROUP="default"

cd /opt/actions-runner

# --- Mint a GitHub App installation token on the box, from the App
#     private key in Key Vault, via this container's user-assigned managed
#     identity (--assign-identity in reconcile-aci-runners.yml). Same
#     approach as the VMSS side's mint-gh-token.sh. ---
fail() { echo "entrypoint: $*" >&2; exit 1; }

KV_TOKEN=$(curl -s --retry 5 --retry-delay 3 --retry-connrefused -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" \
  | jq -r '.access_token // empty')
[[ -n "${KV_TOKEN}" ]] || fail "no AAD token from IMDS - is a managed identity assigned to this container group?"

APP_PEM=$(curl -s --retry 5 --retry-delay 3 \
  -H "Authorization: Bearer ${KV_TOKEN}" \
  "https://${KEYVAULT_NAME}.vault.azure.net/secrets/${KEYVAULT_APP_KEY_SECRET_NAME}?api-version=7.4" \
  | jq -r '.value // empty')
[[ -n "${APP_PEM}" ]] || fail "Key Vault secret '${KEYVAULT_APP_KEY_SECRET_NAME}' missing/empty in ${KEYVAULT_NAME}"

_kf=$(mktemp); chmod 600 "${_kf}"; printf '%s\n' "${APP_PEM}" > "${_kf}"; unset APP_PEM
_b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
_now=$(date -u +%s)
_hdr=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64u)
_pl=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((_now-60))" "$((_now+540))" "${GITHUB_APP_ID}" | _b64u)
_sig=$(printf '%s.%s' "${_hdr}" "${_pl}" | openssl dgst -sha256 -sign "${_kf}" -binary 2>/dev/null | _b64u)
shred -u "${_kf}" 2>/dev/null || rm -f "${_kf}"
[[ -n "${_sig}" ]] || fail "could not sign App JWT - '${KEYVAULT_APP_KEY_SECRET_NAME}' is not a valid RSA private key PEM"
APP_JWT="${_hdr}.${_pl}.${_sig}"

INSTALL_ID=$(curl -s -H "Authorization: Bearer ${APP_JWT}" -H "Accept: application/vnd.github+json" \
  "${GH_API_BASE}/installation" | jq -r '.id // empty')
[[ -n "${INSTALL_ID}" ]] || fail "no installation for ${GH_API_BASE} (App not installed, wrong GITHUB_APP_ID=${GITHUB_APP_ID}, or stale key)"

GITHUB_TOKEN=$(curl -s -X POST -H "Authorization: Bearer ${APP_JWT}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" | jq -r '.token // empty')
unset APP_JWT
[[ -n "${GITHUB_TOKEN}" ]] || fail "installation token exchange failed for installation ${INSTALL_ID}"

# --- Exchange for a short-lived runner REGISTRATION token ---
REG_TOKEN=$(curl -s -X POST \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GH_API_BASE}/actions/runners/registration-token" \
  | jq -r '.token')

if [[ -z "${REG_TOKEN}" || "${REG_TOKEN}" == "null" ]]; then
  echo "Failed to obtain GitHub runner registration token" >&2
  exit 1
fi

INSTANCE_NAME="aci-runner-$(hostname)"

sudo -u actions-runner ./config.sh \
  --url "${GH_RUNNER_URL}" \
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
