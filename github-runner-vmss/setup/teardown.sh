#!/usr/bin/env bash
#
# teardown.sh - undo bootstrap.sh: delete the three app registrations and
# their role assignments, the Key Vault secrets, and (opt-in) the tfstate
# account, the resource groups this repo created, and the GitHub repo
# config. Lets you start from a clean slate.
#
# By default it only removes things that are cheap to recreate and safe to
# lose: the app registrations (+ SPs + federated creds + role assignments)
# and the SSH / github-app-token Key Vault secrets. Everything destructive
# is behind an explicit flag:
#
#   --delete-state        delete the tfstate storage account  (DESTROYS Terraform state)
#   --delete-keyvault     delete AND purge the Key Vault
#   --delete-groups       delete resource groups this repo created (from state.env)
#   --reset-github        remove the repo variables/secrets and 'production' environment
#   --all                 all of the above
#
# It prefers setup/state.env (written by bootstrap.sh). Without it, pass
# --subscription-id and it falls back to the well-known display names /
# terraform.tfvars values.
#
# Run 'terraform destroy' FIRST if you have live infrastructure - this
# script does not touch anything Terraform manages (VMSS, storage for
# scripts, private endpoints, the network created by manage_network).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

TFVARS_FILE="$HERE/../terraform/terraform.tfvars"
STATE_FILE="$HERE/state.env"

SUBSCRIPTION_ID=""
DELETE_STATE=0
DELETE_KEYVAULT=0
DELETE_GROUPS=0
RESET_GITHUB=0
DRY_RUN=0
ASSUME_YES=0
GH_REPO=""

APP_NAMES=(gh-runner-token-refresh gh-runner-vmss-terraform-deploy gh-runner-queue-poller)

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; cat <<EOF

Usage: teardown.sh [--subscription-id <id>] [--delete-state] [--delete-keyvault]
                   [--delete-groups] [--reset-github] [--all] [--dry-run] [--yes]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUBSCRIPTION_ID="$2"; shift 2 ;;
    --github-repo) GH_REPO="$2"; shift 2 ;;
    --delete-state) DELETE_STATE=1; shift ;;
    --delete-keyvault) DELETE_KEYVAULT=1; shift ;;
    --delete-groups) DELETE_GROUPS=1; shift ;;
    --reset-github) RESET_GITHUB=1; shift ;;
    --all) DELETE_STATE=1; DELETE_KEYVAULT=1; DELETE_GROUPS=1; RESET_GITHUB=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

need az
az account show >/dev/null 2>&1 || die "'az' is not logged in. Run: az login"

[[ -z "$SUBSCRIPTION_ID" ]] && SUBSCRIPTION_ID="$(state_get SUBSCRIPTION_ID || true)"
[[ -n "$SUBSCRIPTION_ID" ]] || die "No subscription id (not in state.env) - pass --subscription-id."
run az account set --subscription "$SUBSCRIPTION_ID"

KV_NAME="$(tfvar key_vault_name)"
KV_RG="$(tfvar key_vault_resource_group_name "$(tfvar resource_group_name rg-mgmt-devops)")"
TFSTATE_ACCOUNT="$(state_get TFSTATE_ACCOUNT)"
TFSTATE_RG="$(state_get TFSTATE_RG)"; TFSTATE_RG="${TFSTATE_RG:-$(tfvar resource_group_name rg-mgmt-devops)}"
CREATED_HUB_RG="$(state_get CREATED_HUB_RG)"

if [[ -z "$GH_REPO" ]]; then
  origin="$(git -C "$HERE" remote get-url origin 2>/dev/null || true)"
  GH_REPO="$(printf '%s' "$origin" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi

cat <<EOF

  Subscription     : $SUBSCRIPTION_ID
  App registrations: ${APP_NAMES[*]}
  Key Vault secrets: github-app-token, vmss-ssh-public-key, vmss-ssh-private-key  (vault: $KV_NAME)
  --delete-state   : $DELETE_STATE   -> storage account ${TFSTATE_ACCOUNT:-'(not recorded)'} (RG $TFSTATE_RG)
  --delete-keyvault: $DELETE_KEYVAULT   -> delete + purge $KV_NAME
  --delete-groups  : $DELETE_GROUPS   -> ${CREATED_HUB_RG:-'(no bootstrap-created groups recorded)'}
  --reset-github   : $RESET_GITHUB   -> repo vars/secrets + '$(tfvar environment production)' env on ${GH_REPO:-'(repo unknown)'}
  dry-run          : $DRY_RUN
EOF

confirm "This deletes the resources above. Continue?" || die "Aborted."

# ---------------------------------------------------------------------------
# App registrations (removes SPs, federated creds, and role assignments)
# ---------------------------------------------------------------------------
step "App registrations"
for name in "${APP_NAMES[@]}"; do
  appId="$(az_app_id_by_name "$name")"
  if [[ -z "$appId" || "$appId" == "null" ]]; then skip "not found: $name"; continue; fi
  spOid="$(az ad sp show --id "$appId" --query id -o tsv 2>/dev/null || true)"
  if [[ -n "$spOid" ]]; then
    # Delete role assignments explicitly first - orphaned ones linger in
    # portal listings as "Identity not found" otherwise.
    while IFS= read -r ra; do
      [[ -z "$ra" ]] && continue
      run az role assignment delete --ids "$ra" -o none && info "removed role assignment $ra"
    done < <(az role assignment list --assignee "$spOid" --all --query "[].id" -o tsv 2>/dev/null || true)
  fi
  run az ad app delete --id "$appId" && ok "deleted app + SP: $name ($appId)"
done

# ---------------------------------------------------------------------------
# Key Vault secrets
# ---------------------------------------------------------------------------
step "Key Vault secrets"
if [[ -n "$KV_NAME" ]] && az keyvault show --name "$KV_NAME" >/dev/null 2>&1; then
  for s in github-app-token vmss-ssh-public-key vmss-ssh-private-key; do
    if az keyvault secret show --vault-name "$KV_NAME" --name "$s" >/dev/null 2>&1; then
      run az keyvault secret delete --vault-name "$KV_NAME" --name "$s" -o none && ok "deleted secret: $s"
    else
      skip "secret not present: $s"
    fi
  done
else
  skip "vault $KV_NAME not found"
fi

# ---------------------------------------------------------------------------
# Opt-in destructive steps
# ---------------------------------------------------------------------------
if [[ "$DELETE_STATE" == "1" ]]; then
  step "Terraform state storage"
  if [[ -n "$TFSTATE_ACCOUNT" ]] && az storage account show --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" >/dev/null 2>&1; then
    confirm "REALLY delete state account $TFSTATE_ACCOUNT? Terraform state will be lost." \
      && run az storage account delete --name "$TFSTATE_ACCOUNT" --resource-group "$TFSTATE_RG" --yes -o none \
      && ok "deleted $TFSTATE_ACCOUNT" || skip "kept $TFSTATE_ACCOUNT"
  else
    skip "state account not found / not recorded"
  fi
fi

if [[ "$DELETE_KEYVAULT" == "1" ]]; then
  step "Key Vault"
  if [[ -n "$KV_NAME" ]] && az keyvault show --name "$KV_NAME" >/dev/null 2>&1; then
    run az keyvault delete --name "$KV_NAME" -o none && ok "deleted vault $KV_NAME"
    run az keyvault purge --name "$KV_NAME" -o none 2>/dev/null && ok "purged vault $KV_NAME" || warn "purge skipped/failed (soft-delete retention or no purge rights)"
  else
    skip "vault $KV_NAME not found"
  fi
fi

if [[ "$DELETE_GROUPS" == "1" ]]; then
  step "Resource groups created by bootstrap"
  for rg in "$CREATED_HUB_RG"; do
    [[ -z "$rg" ]] && continue
    if [[ "$(az group exists --name "$rg")" == "true" ]]; then
      confirm "Delete resource group '$rg' and everything in it?" \
        && run az group delete --name "$rg" --yes --no-wait -o none && ok "delete started: $rg" || skip "kept $rg"
    else
      skip "group not found: $rg"
    fi
  done
  info "Management / Key Vault resource groups are never auto-deleted - remove them by hand if you must."
fi

if [[ "$RESET_GITHUB" == "1" ]]; then
  step "GitHub repo config"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [[ "$GH_REPO" == */* ]]; then
    for v in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID KEYVAULT_NAME AZURE_CLIENT_ID \
             TF_DEPLOY_AZURE_CLIENT_ID TFSTATE_RESOURCE_GROUP TFSTATE_STORAGE_ACCOUNT \
             TFSTATE_CONTAINER QUEUE_POLLER_AZURE_CLIENT_ID RUNNER_BOOTSTRAP_APP_ID; do
      run gh variable delete "$v" --repo "$GH_REPO" 2>/dev/null && ok "removed variable $v" || skip "no variable $v"
    done
    run gh secret delete RUNNER_BOOTSTRAP_APP_PRIVATE_KEY --repo "$GH_REPO" 2>/dev/null && ok "removed secret RUNNER_BOOTSTRAP_APP_PRIVATE_KEY" || skip "no RUNNER_BOOTSTRAP_APP_PRIVATE_KEY"
    env_name="$(tfvar environment production)"
    run gh api -X DELETE "repos/$GH_REPO/environments/$env_name" 2>/dev/null && ok "deleted environment '$env_name'" || skip "no environment '$env_name'"
  else
    warn "gh not available/authed or repo unknown - skipping GitHub reset."
  fi
fi

# ---------------------------------------------------------------------------
step "Done"
if [[ "$DRY_RUN" != "1" ]]; then
  : > "$STATE_FILE" 2>/dev/null || true
  info "cleared $STATE_FILE"
fi
info "If you deleted the state account, also run: rm -rf ../terraform/.terraform ../terraform/.terraform.lock.hcl"
