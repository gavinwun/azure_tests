# shellcheck shell=bash
# Shared helpers for bootstrap.sh / teardown.sh - not executable on its own.
#
# Everything here is deliberately dependency-light: az, gh (optional), plus
# coreutils. No jq requirement unless --seed-token is used.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _c_reset=$'\033[0m'; _c_bold=$'\033[1m'; _c_dim=$'\033[2m'
  _c_red=$'\033[31m'; _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[36m'
else
  _c_reset=; _c_bold=; _c_dim=; _c_red=; _c_grn=; _c_ylw=; _c_blu=
fi

step()  { printf '\n%s==>%s %s%s\n' "$_c_blu$_c_bold" "$_c_reset$_c_bold" "$*" "$_c_reset"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s✔%s %s\n' "$_c_grn" "$_c_reset" "$*"; }
skip()  { printf '    %s•%s %s%s%s\n' "$_c_dim" "$_c_reset" "$_c_dim" "$*" "$_c_reset"; }
warn()  { printf '    %s!%s %s\n' "$_c_ylw" "$_c_reset" "$*" >&2; }
die()   { printf '\n%sERROR:%s %s\n' "$_c_red$_c_bold" "$_c_reset" "$*" >&2; exit 1; }

# DRY_RUN is set by the calling script from --dry-run.
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '    %s[dry-run]%s %s\n' "$_c_dim" "$_c_reset" "$*"
    return 0
  fi
  "$@"
}

confirm() {
  # confirm "question" -> honours --yes (ASSUME_YES=1)
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  local reply
  printf '%s%s%s [y/N] ' "$_c_bold" "$1" "$_c_reset"
  read -r reply || true
  [[ "$reply" =~ ^[Yy]$ ]]
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not on PATH."; }

# ---------------------------------------------------------------------------
# terraform.tfvars parsing (names only - nothing sensitive lives there)
# ---------------------------------------------------------------------------
TFVARS_FILE="${TFVARS_FILE:-}"

tfvar() {
  # tfvar <key> [default] - reads a "key = "value"" or "key = true" line.
  local key="$1" default="${2:-}"
  local val=""
  if [[ -n "$TFVARS_FILE" && -f "$TFVARS_FILE" ]]; then
    val=$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]+)\"?.*/\1/p" "$TFVARS_FILE" | head -n1)
    val="${val%"${val##*[![:space:]]}"}" # rtrim
  fi
  printf '%s' "${val:-$default}"
}

# ---------------------------------------------------------------------------
# State file - records what bootstrap created so re-runs are idempotent and
# teardown knows exactly what to remove. Plain "KEY=value" lines.
# ---------------------------------------------------------------------------
STATE_FILE="${STATE_FILE:-}"

state_get() {
  [[ -f "$STATE_FILE" ]] || return 0
  sed -n -E "s/^$1=(.*)/\1/p" "$STATE_FILE" | tail -n1
}

state_set() {
  # state_set KEY value  (last-write-wins; never writes secrets)
  local key="$1" value="$2"
  [[ "${DRY_RUN:-0}" == "1" ]] && { printf '    %s[dry-run]%s state %s=%s\n' "$_c_dim" "$_c_reset" "$key" "$value" >&2; return 0; }
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  local tmp; tmp=$(mktemp)
  grep -v -E "^$key=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Azure helpers
# ---------------------------------------------------------------------------
az_app_id_by_name() {
  az ad app list --display-name "$1" --query "[0].appId" -o tsv 2>/dev/null
}

az_app_object_id_by_name() {
  az ad app list --display-name "$1" --query "[0].id" -o tsv 2>/dev/null
}

az_role_has() {
  # az_role_has <assignee-object-id> <role> <scope>
  local n
  n=$(az role assignment list --assignee "$1" --role "$2" --scope "$3" \
        --query "length(@)" -o tsv 2>/dev/null || echo 0)
  [[ "${n:-0}" != "0" ]]
}

ensure_role() {
  # ensure_role <assignee-object-id> <role> <scope> [label]
  local assignee="$1" role="$2" scope="$3" label="${4:-$role}"
  if az_role_has "$assignee" "$role" "$scope"; then
    skip "role already assigned: $label"
  else
    run az role assignment create --assignee-object-id "$assignee" \
      --assignee-principal-type ServicePrincipal --role "$role" --scope "$scope" -o none
    ok "granted $label"
  fi
}

ensure_group() {
  # ensure_group <name> <location>
  if [[ "$(az group exists --name "$1" 2>/dev/null)" == "true" ]]; then
    skip "resource group exists: $1"
  else
    run az group create --name "$1" --location "$2" -o none
    ok "created resource group: $1"
  fi
}

# ---------------------------------------------------------------------------
# GitHub OIDC subject strings
# ---------------------------------------------------------------------------
# SUBJECT_FORMAT: auto|plain|immutable   GH_OWNER_ID / GH_REPO_ID filled when needed.
subjects_for() {
  # subjects_for <claim-suffix>  e.g. "ref:refs/heads/main" / "pull_request" / "environment:production"
  # echoes one subject per line according to SUBJECT_FORMAT.
  local suffix="$1"
  case "${SUBJECT_FORMAT:-auto}" in
    plain)     printf 'repo:%s:%s\n' "$GH_REPO" "$suffix" ;;
    immutable) printf 'repo:%s@%s/%s@%s:%s\n' "$GH_OWNER" "$GH_OWNER_ID" "$GH_REPO_NAME" "$GH_REPO_ID" "$suffix" ;;
    *)         printf 'repo:%s:%s\n' "$GH_REPO" "$suffix"
               printf 'repo:%s@%s/%s@%s:%s\n' "$GH_OWNER" "$GH_OWNER_ID" "$GH_REPO_NAME" "$GH_REPO_ID" "$suffix" ;;
  esac
}
