#!/usr/bin/env bash
#
# bootstrap.sh - do every manual, one-off pre-Terraform step from ../README.md
# in a single idempotent pass.
#
# Covers (README "Setup order matters"):
#   0  management resource group + RBAC Key Vault + your Secrets Officer grant
#   5  VMSS SSH key pair -> Key Vault secrets
#   7.1  tfstate storage account + container + your Blob Data Contributor grant
#   7.3  network hub resource group (manage_network = true)
#   2  "gh-runner-token-refresh"        app + SP + federated creds + KV grant
#   7.2/7.3  "gh-runner-vmss-terraform-deploy" app + SP + federated creds + all grants
#   B  "gh-runner-queue-poller"         app + SP + federated cred        (--with-poller)
#   3/7.4  GitHub repo variables + secrets + "production" environment    (--set-github)
#   4  seed the github-app-token Key Vault secret                        (--seed-token)
#
# NOT covered (genuinely can't be scripted): creating the GitHub App itself
# (step 1) and adding org-installation permissions. Create it in the GitHub
# UI first, then pass --github-app-id / --github-app-private-key-file here.
#
# Requires: bash, az (logged in), and for --set-github/--seed-token: gh
# (logged in) / openssl / jq. Run from Git Bash, WSL, or Azure Cloud Shell.
#
# Everything is idempotent: re-running skips what already exists. What it
# creates is recorded in setup/state.env so teardown.sh can undo exactly it.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TFVARS_FILE="$HERE/../terraform/terraform.tfvars"
STATE_FILE="$HERE/state.env"

# ---------------------------------------------------------------------------
# Defaults (names come from terraform.tfvars; the rest from flags)
# ---------------------------------------------------------------------------
SUBSCRIPTION_ID=""
LOCATION="australiaeast"
GH_REPO=""                       # owner/repo - default derived from git remote
GITHUB_APP_ID=""
GITHUB_APP_KEY_FILE=""
SUBJECT_FORMAT="auto"            # auto|plain|immutable
TFSTATE_RG=""                    # default: management RG
TFSTATE_ACCOUNT=""               # default: from state.env, else generated
TFSTATE_CONTAINER="tfstate"
WITH_POLLER=0
SET_GITHUB=0
SEED_TOKEN=0
DRY_RUN=0
ASSUME_YES=0

APP_REFRESH="gh-runner-token-refresh"
APP_DEPLOY="gh-runner-vmss-terraform-deploy"
APP_POLLER="gh-runner-queue-poller"

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
  cat <<EOF

Usage: bootstrap.sh --subscription-id <id> [options]

Required:
  --subscription-id <guid>       Target Azure subscription.

Common options:
  --location <region>            Azure region for new resources (default: $LOCATION).
  --github-repo <owner/repo>     Default: parsed from 'git remote get-url origin'.
  --github-app-id <id>           GitHub App ID (step 1). Needed for --set-github/--seed-token.
  --github-app-private-key-file <path>   The App's .pem. Needed for --set-github/--seed-token.
  --subject-format auto|plain|immutable  Federated-credential subject style (default: auto = both).
  --tfstate-rg <name>            Resource group for the tfstate account (default: management RG).
  --tfstate-account <name>       tfstate storage account (default: reuse state.env or generate one).
  --tfstate-container <name>     tfstate blob container (default: $TFSTATE_CONTAINER).
  --with-poller                  Also create the queue-poller identity (README optional section B).
  --set-github                   Also set repo variables/secrets and create the 'production' env (needs gh).
  --seed-token                   Mint an installation token now and store it as the github-app-token secret.
  --dry-run                      Print what would run without changing anything.
  --yes                          Don't prompt for confirmation.
  -h, --help

Names read from $TFVARS_FILE:
  resource_group_name, key_vault_name, key_vault_resource_group_name,
  vnet_resource_group_name, manage_network, environment, github_org
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --github-repo) GH_REPO="$2"; shift 2 ;;
    --github-app-id) GITHUB_APP_ID="$2"; shift 2 ;;
    --github-app-private-key-file) GITHUB_APP_KEY_FILE="$2"; shift 2 ;;
    --subject-format) SUBJECT_FORMAT="$2"; shift 2 ;;
    --tfstate-rg) TFSTATE_RG="$2"; shift 2 ;;
    --tfstate-account) TFSTATE_ACCOUNT="$2"; shift 2 ;;
    --tfstate-container) TFSTATE_CONTAINER="$2"; shift 2 ;;
    --with-poller) WITH_POLLER=1; shift ;;
    --set-github) SET_GITHUB=1; shift ;;
    --seed-token) SEED_TOKEN=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

need az
[[ -n "$SUBSCRIPTION_ID" ]] || die "--subscription-id is required."
[[ "$SUBJECT_FORMAT" =~ ^(auto|plain|immutable)$ ]] || die "--subject-format must be auto|plain|immutable."

# ---------------------------------------------------------------------------
# Resolve configuration
# ---------------------------------------------------------------------------
step "Resolving configuration"

az account show >/dev/null 2>&1 || die "'az' is not logged in. Run: az login"
run az account set --subscription "$SUBSCRIPTION_ID"
TENANT_ID=$(az account show --query tenantId -o tsv)
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
[[ -n "$CURRENT_USER_OID" ]] || warn "Could not resolve signed-in user object id (service principal login?). Your personal Key Vault / Storage grants will be skipped."

MGMT_RG="$(tfvar resource_group_name rg-mgmt-devops)"
KV_NAME="$(tfvar key_vault_name)"
KV_RG="$(tfvar key_vault_resource_group_name "$MGMT_RG")"
HUB_RG="$(tfvar vnet_resource_group_name)"
MANAGE_NETWORK="$(tfvar manage_network false)"
ENVIRONMENT="$(tfvar environment production)"
GITHUB_ORG="$(tfvar github_org)"
[[ -n "$KV_NAME" ]] || die "key_vault_name not found in $TFVARS_FILE - set it (README step 0)."
[[ -n "$HUB_RG"  ]] || die "vnet_resource_group_name not found in $TFVARS_FILE."

if [[ -z "$GH_REPO" ]]; then
  origin="$(git -C "$HERE" remote get-url origin 2>/dev/null || true)"
  GH_REPO="$(printf '%s' "$origin" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
[[ "$GH_REPO" == */* ]] || die "Could not derive owner/repo - pass --github-repo <owner/repo>."
GH_OWNER="${GH_REPO%%/*}"
GH_REPO_NAME="${GH_REPO##*/}"
[[ -z "$GITHUB_ORG" ]] && GITHUB_ORG="$GH_OWNER"

TFSTATE_RG="${TFSTATE_RG:-$MGMT_RG}"
[[ -z "$TFSTATE_ACCOUNT" ]] && TFSTATE_ACCOUNT="$(state_get TFSTATE_ACCOUNT || true)"
if [[ -z "$TFSTATE_ACCOUNT" ]]; then
  TFSTATE_ACCOUNT="sttfstate$(( RANDOM % 90000 + 10000 ))"
  info "No tfstate account given - will use generated name: $TFSTATE_ACCOUNT"
fi

# Owner / repo numeric IDs (only needed for immutable subjects)
GH_OWNER_ID=""; GH_REPO_ID=""
if [[ "$SUBJECT_FORMAT" != "plain" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    GH_OWNER_ID=$(gh api "repos/$GH_REPO" --jq '.owner.id' 2>/dev/null || true)
    GH_REPO_ID=$(gh api "repos/$GH_REPO" --jq '.id' 2>/dev/null || true)
  else
    _j=$(curl -fsS -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$GH_REPO" 2>/dev/null | tr -d '\n ' || true)
    GH_REPO_ID=$(printf '%s' "$_j"  | sed -n -E 's/^\{"id":([0-9]+),.*/\1/p')
    GH_OWNER_ID=$(printf '%s' "$_j" | sed -n -E 's/.*"owner":\{"login":"[^"]*","id":([0-9]+).*/\1/p')
  fi
  if [[ -z "$GH_OWNER_ID" || -z "$GH_REPO_ID" ]]; then
    warn "Couldn't fetch numeric owner/repo IDs; falling back to --subject-format plain."
    SUBJECT_FORMAT="plain"
  fi
fi

cat <<EOF

  Subscription        : $SUBSCRIPTION_ID
  Tenant              : $TENANT_ID
  Location            : $LOCATION
  Management RG        : $MGMT_RG
  Key Vault           : $KV_NAME  (RG: $KV_RG)
  Hub network RG       : $HUB_RG  (manage_network=$MANAGE_NETWORK)
  tfstate             : $TFSTATE_ACCOUNT / $TFSTATE_CONTAINER  (RG: $TFSTATE_RG)
  GitHub repo         : $GH_REPO   org: $GITHUB_ORG
  Federated subjects  : $SUBJECT_FORMAT${GH_REPO_ID:+  (owner $GH_OWNER_ID / repo $GH_REPO_ID)}
  Deploy environment  : $ENVIRONMENT
  Extras              : with-poller=$WITH_POLLER  set-github=$SET_GITHUB  seed-token=$SEED_TOKEN  dry-run=$DRY_RUN
  State file          : $STATE_FILE
EOF

confirm "Proceed with bootstrap?" || die "Aborted."
state_set SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
state_set TFSTATE_ACCOUNT "$TFSTATE_ACCOUNT"
state_set TFSTATE_RG "$TFSTATE_RG"

# ---------------------------------------------------------------------------
# 0. Resource groups
# ---------------------------------------------------------------------------
step "Resource groups"
ensure_group "$MGMT_RG" "$LOCATION"
[[ "$KV_RG" != "$MGMT_RG" ]] && ensure_group "$KV_RG" "$LOCATION"
[[ "$TFSTATE_RG" != "$MGMT_RG" ]] && ensure_group "$TFSTATE_RG" "$LOCATION"
if [[ "$MANAGE_NETWORK" == "true" && "$HUB_RG" != "$MGMT_RG" ]]; then
  ensure_group "$HUB_RG" "$LOCATION"
  state_set CREATED_HUB_RG "$HUB_RG"
fi

# ---------------------------------------------------------------------------
# 0. Key Vault (RBAC-authorization model)
# ---------------------------------------------------------------------------
step "Key Vault: $KV_NAME"
if az keyvault show --name "$KV_NAME" >/dev/null 2>&1; then
  skip "vault exists"
  rbac=$(az keyvault show --name "$KV_NAME" --query "properties.enableRbacAuthorization" -o tsv)
  [[ "$rbac" == "true" ]] || warn "vault $KV_NAME is NOT using RBAC authorization - every role grant in this repo will silently no-op. See README step 0."
else
  run az keyvault create --name "$KV_NAME" --resource-group "$KV_RG" --location "$LOCATION" \
    --enable-rbac-authorization true -o none
  ok "created vault (RBAC authorization)"
  state_set CREATED_KEYVAULT "$KV_NAME"
  # A brand-new vault (especially in a brand-new subscription) can take a
  # short while before ARM will accept role assignments scoped to it.
  [[ "$DRY_RUN" == "1" ]] || sleep 10
fi
KV_ID=$(az keyvault show --name "$KV_NAME" --query id -o tsv 2>/dev/null || echo "")
if [[ -n "$CURRENT_USER_OID" && -n "$KV_ID" ]]; then
  ensure_role "$CURRENT_USER_OID" "Key Vault Secrets Officer" "$KV_ID" "Key Vault Secrets Officer -> you" User
fi

# ---------------------------------------------------------------------------
# 7.1 tfstate storage account
# ---------------------------------------------------------------------------
step "Terraform state storage: $TFSTATE_ACCOUNT"
if az storage account show --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" >/dev/null 2>&1; then
  skip "storage account exists"
else
  run az storage account create --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" \
    --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false -o none
  run az storage account blob-service-properties update --account-name "$TFSTATE_ACCOUNT" \
    --enable-versioning true -o none
  ok "created state storage account (versioning on)"
  state_set CREATED_TFSTATE_ACCOUNT "$TFSTATE_ACCOUNT"
fi
TFSTATE_ID=$(az storage account show --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" --query id -o tsv 2>/dev/null || echo "")
if [[ -n "$CURRENT_USER_OID" && -n "$TFSTATE_ID" ]]; then
  if az_role_has "$CURRENT_USER_OID" "Storage Blob Data Contributor" "$TFSTATE_ID"; then
    skip "you already have Storage Blob Data Contributor on the state account"
  else
    ensure_role "$CURRENT_USER_OID" "Storage Blob Data Contributor" "$TFSTATE_ID" "Storage Blob Data Contributor -> you" User
    info "waiting ~30s for the data-plane grant to propagate before creating the container..."
    [[ "$DRY_RUN" == "1" ]] || sleep 30
  fi
fi
if [[ "$DRY_RUN" == "1" ]]; then
  run az storage container create --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_ACCOUNT" --auth-mode login
elif az storage container show --name "$TFSTATE_CONTAINER" --account-name "$TFSTATE_ACCOUNT" --auth-mode login >/dev/null 2>&1; then
  skip "container '$TFSTATE_CONTAINER' exists"
elif retry 4 20 -- az storage container create --name "$TFSTATE_CONTAINER" \
       --account-name "$TFSTATE_ACCOUNT" --auth-mode login -o none; then
  ok "created container '$TFSTATE_CONTAINER'"
else
  ROLE_FAILURES=$((ROLE_FAILURES + 1))
  warn "could not create container '$TFSTATE_CONTAINER' (data-plane grant still propagating?). Re-run bootstrap.sh in a minute."
fi

# ---------------------------------------------------------------------------
# 5. VMSS SSH key pair -> Key Vault
# ---------------------------------------------------------------------------
step "VMSS SSH key pair -> Key Vault"
if [[ "$DRY_RUN" != "1" ]] && az keyvault secret show --vault-name "$KV_NAME" --name vmss-ssh-public-key >/dev/null 2>&1; then
  skip "secret vmss-ssh-public-key already present"
else
  need ssh-keygen
  tmpkey="$(mktemp -d)/ghrunner-vmss-key"
  run ssh-keygen -t ed25519 -f "$tmpkey" -N "" -q
  # Data-plane RBAC (your Secrets Officer grant just above) can take a
  # minute or two to be usable - retry rather than fail the whole run.
  if [[ "$DRY_RUN" == "1" ]] || \
     ( retry 6 20 -- az keyvault secret set --vault-name "$KV_NAME" --name vmss-ssh-public-key  --file "$tmpkey.pub" -o none && \
       retry 6 20 -- az keyvault secret set --vault-name "$KV_NAME" --name vmss-ssh-private-key --file "$tmpkey"     -o none ); then
    ok "stored vmss-ssh-public-key / vmss-ssh-private-key"
    state_set CREATED_SSH_SECRETS "1"
  else
    ROLE_FAILURES=$((ROLE_FAILURES + 1))
    warn "could not write the SSH secrets (Key Vault data-plane access not ready?). Re-run bootstrap.sh shortly."
  fi
  if [[ "$DRY_RUN" != "1" ]]; then
    command -v shred >/dev/null 2>&1 && shred -u "$tmpkey" "$tmpkey.pub" 2>/dev/null || rm -f "$tmpkey" "$tmpkey.pub"
    rmdir "$(dirname "$tmpkey")" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# App registration helper
# ---------------------------------------------------------------------------
ensure_app() {
  # ensure_app <display-name> -> echoes "<appId> <objectId>"; records in state.
  local name="$1" appId objId
  appId="$(az_app_id_by_name "$name")"
  if [[ -n "$appId" && "$appId" != "null" ]]; then
    objId="$(az_app_object_id_by_name "$name")"
    skip "app exists: $name ($appId)" >&2
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      printf '    %s[dry-run]%s az ad app create --display-name %s\n' "$_c_dim" "$_c_reset" "$name" >&2
      appId="00000000-0000-0000-0000-000000000000"; objId="$appId"
    else
      appId=$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)
      [[ -n "$appId" && "$appId" != "null" ]] || die "failed to create app '$name'"
      az ad sp create --id "$appId" -o none 2>/dev/null || true
      objId=$(az_app_object_id_by_name "$name")
      ok "created app + service principal: $name ($appId)" >&2
    fi
  fi
  state_set "APP_${name//[^A-Za-z0-9]/_}" "$appId"
  printf '%s %s\n' "$appId" "$objId"
}

ensure_fic() {
  # ensure_fic <app-object-id> <cred-name> <subject>
  local appObj="$1" cname="$2" subject="$3"
  if [[ "$DRY_RUN" != "1" ]] && \
     az ad app federated-credential list --id "$appObj" --query "[?subject=='$subject'] | [0].id" -o tsv 2>/dev/null | grep -q .; then
    skip "federated credential exists for subject: $subject"
    return 0
  fi
  run az ad app federated-credential create --id "$appObj" --parameters "{
    \"name\": \"$cname\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none && ok "federated credential: $subject"
}

add_fics() {
  # add_fics <app-object-id> <name-prefix> <claim-suffix>
  local appObj="$1" prefix="$2" suffix="$3" i=0
  while IFS= read -r subj; do
    [[ -z "$subj" ]] && continue
    i=$((i+1))
    ensure_fic "$appObj" "${prefix}-${i}" "$subj"
  done < <(subjects_for "$suffix")
}

sp_oid() { az ad sp show --id "$1" --query id -o tsv 2>/dev/null; }

# ---------------------------------------------------------------------------
# 2. gh-runner-token-refresh
# ---------------------------------------------------------------------------
step "App: $APP_REFRESH"
read -r REFRESH_APPID REFRESH_OBJID < <(ensure_app "$APP_REFRESH")
add_fics "$REFRESH_OBJID" "token-refresh" "ref:refs/heads/main"
if [[ "$DRY_RUN" != "1" && -n "$KV_ID" ]]; then
  ensure_role "$(sp_oid "$REFRESH_APPID")" "Key Vault Secrets Officer" "$KV_ID" "Key Vault Secrets Officer -> $APP_REFRESH"
fi

# ---------------------------------------------------------------------------
# 7. gh-runner-vmss-terraform-deploy
# ---------------------------------------------------------------------------
step "App: $APP_DEPLOY"
read -r DEPLOY_APPID DEPLOY_OBJID < <(ensure_app "$APP_DEPLOY")
add_fics "$DEPLOY_OBJID" "tf-deploy-pr"   "pull_request"
add_fics "$DEPLOY_OBJID" "tf-deploy-main" "ref:refs/heads/main"
add_fics "$DEPLOY_OBJID" "tf-deploy-env"  "environment:$ENVIRONMENT"

if [[ "$DRY_RUN" != "1" ]]; then
  DEPLOY_SP_OID="$(sp_oid "$DEPLOY_APPID")"
  MGMT_ID=$(az group show --name "$MGMT_RG" --query id -o tsv)
  ensure_role "$DEPLOY_SP_OID" "Contributor"                          "$MGMT_ID"    "Contributor -> $MGMT_RG"
  ensure_role "$DEPLOY_SP_OID" "Role Based Access Control Administrator" "$MGMT_ID"  "RBAC Administrator -> $MGMT_RG"
  [[ -n "$TFSTATE_ID" ]] && ensure_role "$DEPLOY_SP_OID" "Storage Blob Data Contributor" "$TFSTATE_ID" "Blob Data Contributor -> $TFSTATE_ACCOUNT"
  [[ -n "$KV_ID" ]]      && ensure_role "$DEPLOY_SP_OID" "Key Vault Secrets User"        "$KV_ID"      "KV Secrets User -> $KV_NAME (plan-time data.tf read)"

  HUB_ID=$(az group show --name "$HUB_RG" --query id -o tsv 2>/dev/null || echo "")
  if [[ -n "$HUB_ID" && "$HUB_RG" != "$MGMT_RG" ]]; then
    if [[ "$MANAGE_NETWORK" == "true" ]]; then
      ensure_role "$DEPLOY_SP_OID" "Contributor" "$HUB_ID" "Contributor -> $HUB_RG (manage_network=true)"
    else
      ensure_role "$DEPLOY_SP_OID" "Reader" "$HUB_ID" "Reader -> $HUB_RG (one-time; network-rbac.tf manages the rest)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# B. gh-runner-queue-poller (optional)
# ---------------------------------------------------------------------------
if [[ "$WITH_POLLER" == "1" ]]; then
  step "App: $APP_POLLER"
  read -r POLLER_APPID POLLER_OBJID < <(ensure_app "$APP_POLLER")
  add_fics "$POLLER_OBJID" "queue-poller" "ref:refs/heads/main"
  warn "Grant 'Monitoring Metrics Publisher' to $APP_POLLER on the VMSS AFTER the first terraform apply:"
  warn "  az role assignment create --assignee $POLLER_APPID --role 'Monitoring Metrics Publisher' \\"
  warn "    --scope \$(terraform -chdir=../terraform output -raw vmss_id)"
fi

# ---------------------------------------------------------------------------
# 3 / 7.4 GitHub repo variables + secrets + environment
# ---------------------------------------------------------------------------
if [[ "$SET_GITHUB" == "1" ]]; then
  step "GitHub repo config: $GH_REPO"
  need gh
  gh auth status >/dev/null 2>&1 || die "'gh' is not logged in. Run: gh auth login"

  gh_var()    { run gh variable set "$1" --repo "$GH_REPO" --body "$2" && ok "variable $1"; }
  gh_secret() { run gh secret   set "$1" --repo "$GH_REPO" --body "$2" && ok "secret   $1"; }

  gh_var AZURE_TENANT_ID        "$TENANT_ID"
  gh_var AZURE_SUBSCRIPTION_ID  "$SUBSCRIPTION_ID"
  gh_var KEYVAULT_NAME          "$KV_NAME"
  gh_var AZURE_CLIENT_ID        "$REFRESH_APPID"
  gh_var TF_DEPLOY_AZURE_CLIENT_ID "$DEPLOY_APPID"
  gh_var TFSTATE_RESOURCE_GROUP "$TFSTATE_RG"
  gh_var TFSTATE_STORAGE_ACCOUNT "$TFSTATE_ACCOUNT"
  gh_var TFSTATE_CONTAINER      "$TFSTATE_CONTAINER"
  [[ "$WITH_POLLER" == "1" ]] && gh_var QUEUE_POLLER_AZURE_CLIENT_ID "${POLLER_APPID:-}"

  if [[ -n "$GITHUB_APP_ID" ]]; then
    gh_var RUNNER_BOOTSTRAP_APP_ID "$GITHUB_APP_ID"
  else
    warn "no --github-app-id: skipped RUNNER_BOOTSTRAP_APP_ID (set it once the GitHub App exists)."
  fi
  if [[ -n "$GITHUB_APP_KEY_FILE" && -f "$GITHUB_APP_KEY_FILE" ]]; then
    run gh secret set RUNNER_BOOTSTRAP_APP_PRIVATE_KEY --repo "$GH_REPO" < "$GITHUB_APP_KEY_FILE" && ok "secret   RUNNER_BOOTSTRAP_APP_PRIVATE_KEY"
  else
    warn "no --github-app-private-key-file: skipped RUNNER_BOOTSTRAP_APP_PRIVATE_KEY."
  fi

  run gh api -X PUT "repos/$GH_REPO/environments/$ENVIRONMENT" -o none 2>/dev/null \
    && ok "environment '$ENVIRONMENT' exists (add required reviewers in the UI)" \
    || warn "could not create environment '$ENVIRONMENT' (needs admin on the repo)."
  state_set GITHUB_CONFIGURED "1"
fi

# ---------------------------------------------------------------------------
# 4. Seed github-app-token (optional)
# ---------------------------------------------------------------------------
if [[ "$SEED_TOKEN" == "1" ]]; then
  step "Seed Key Vault secret: github-app-token"
  need openssl; need jq; need curl
  [[ -n "$GITHUB_APP_ID" && -n "$GITHUB_APP_KEY_FILE" && -f "$GITHUB_APP_KEY_FILE" ]] \
    || die "--seed-token needs --github-app-id and --github-app-private-key-file."
  b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
  now=$(date +%s)
  jwt_h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  jwt_p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$GITHUB_APP_ID" | b64url)
  jwt_s=$(printf '%s.%s' "$jwt_h" "$jwt_p" | openssl dgst -sha256 -sign "$GITHUB_APP_KEY_FILE" -binary | b64url)
  JWT="$jwt_h.$jwt_p.$jwt_s"
  inst_id=$(curl -fsS -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/$GITHUB_ORG/installation" | jq -r '.id')
  [[ -n "$inst_id" && "$inst_id" != "null" ]] || die "could not find the App installation on org '$GITHUB_ORG'."
  tok=$(curl -fsS -X POST -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$inst_id/access_tokens" | jq -r '.token')
  [[ -n "$tok" && "$tok" != "null" ]] || die "failed to mint installation token."
  exp=$(date -u -d '+55 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+55M +%Y-%m-%dT%H:%M:%SZ)
  if [[ "$DRY_RUN" == "1" ]] || retry 6 20 -- az keyvault secret set --vault-name "$KV_NAME" \
       --name github-app-token --value "$tok" --expires "$exp" -o none; then
    ok "stored github-app-token (expires $exp; the refresh workflow keeps it fresh from here)"
  else
    ROLE_FAILURES=$((ROLE_FAILURES + 1))
    warn "could not write github-app-token to Key Vault - re-run with --seed-token once data-plane access is ready."
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
step "Done"
cat <<EOF
  $APP_REFRESH  client id : ${REFRESH_APPID:-<dry-run>}
  $APP_DEPLOY   client id : ${DEPLOY_APPID:-<dry-run>}
$( [[ "$WITH_POLLER" == "1" ]] && echo "  $APP_POLLER   client id : ${POLLER_APPID:-<dry-run>}" )

  tfstate backend-config:
    resource_group_name  = $TFSTATE_RG
    storage_account_name = $TFSTATE_ACCOUNT
    container_name        = $TFSTATE_CONTAINER
    key                   = github-runner-vmss.tfstate

Next:
$( [[ "$SET_GITHUB" == "1" ]] || echo "  - Set the repo variables/secrets from README step 3 & 7.4 (or re-run with --set-github)." )
$( [[ -n "$GITHUB_APP_ID" ]] || echo "  - Create the GitHub App (README step 1) and set RUNNER_BOOTSTRAP_APP_ID / _PRIVATE_KEY." )
$( [[ "$SEED_TOKEN" == "1" ]] || echo "  - Run the 'Refresh GitHub App Token in Key Vault' workflow once (seeds github-app-token)." )
  - Confirm bootstrap_agent.sh has GITHUB_ORG / KEYVAULT_NAME / RUNNER_VERSION set (README step 6).
  - Open a PR touching terraform/** to trigger plan, then merge to apply.

  State recorded in: $STATE_FILE  (teardown.sh reads this)
EOF

if [[ "${ROLE_FAILURES:-0}" -gt 0 ]]; then
  warn ""
  warn "$ROLE_FAILURES grant/step did not complete (see the 'could NOT grant' lines above)."
  warn "New subscriptions frequently reject the first few RBAC writes - just re-run:"
  warn "  ./bootstrap.sh --subscription-id $SUBSCRIPTION_ID${GITHUB_APP_ID:+ --github-app-id $GITHUB_APP_ID}${GITHUB_APP_KEY_FILE:+ --github-app-private-key-file $GITHUB_APP_KEY_FILE}$( [[ "$SET_GITHUB" == 1 ]] && echo ' --set-github')$( [[ "$SEED_TOKEN" == 1 ]] && echo ' --seed-token')$( [[ "$WITH_POLLER" == 1 ]] && echo ' --with-poller')"
  exit 1
fi
