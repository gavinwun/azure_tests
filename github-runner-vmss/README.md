# Self-hosted GitHub Actions runners on Azure (VMSS or ACI)

Two interchangeable compute backends, switched with one Terraform
variable (`compute_backend = "vmss"` or `"aci"`):

- **vmss** (default) - Ubuntu VMSS instances that boot, install tooling
  via a bootstrap script, register as ephemeral runners, run one job,
  and are scaled by a queue-depth-driven Azure Monitor autoscale rule.
- **aci** - Azure Container Instances running a prebuilt Docker image
  with the same tooling baked in. No autoscale primitive exists for
  ACI, so a GitHub Actions workflow directly creates/deletes container
  groups to track queued job count instead.

Only one backend is ever deployed at a time - the inactive one's
resources simply don't exist (`count = 0` in Terraform). Both are
documented in full below; read the "Setup order matters" section for
whichever backend you're using, then the corresponding "Optional"
section only if relevant.

## Repo layout

```
terraform/
  main.tf                      VMSS backend (compute_backend = "vmss")
  aci.tf                       ACI backend (compute_backend = "aci")
  custom-metric-autoscale.tf   VMSS-only autoscale rule
  variables.tf                 Input variables, including compute_backend
  locals.tf                    Naming
  data.tf                      References to your existing RG/VNet/subnets/DNS/Key Vault (manage_network = false)
  network.tf                   VMSS-only, optional: creates the VNet/subnets/DNS zone inside an existing hub RG (manage_network = true)
  network-rbac.tf              VMSS-only: grants the deploy identity access to an existing hub-network RG
  keyvault-rbac.tf             VMSS-only: grants the deploy identity secret-read access to the Key Vault
  versions.tf                  Provider constraints
  outputs.tf
  terraform.tfvars.example     Copy to terraform.tfvars and fill in
  scripts/
    bootstrap_agent.sh          VMSS only: runs on every instance boot
docker/
  Dockerfile                   ACI only: runner image, built by build-and-push-runner-image.yml
  entrypoint.sh                ACI only: container's registration + run logic
.github/workflows/
  refresh-github-app-token.yml       Keeps Key Vault secret fresh (both backends)
  terraform-deploy.yml               CI/CD: plans on PR, applies on merge to main (both backends)
  poll-queue-depth.yml               VMSS only: publishes custom metric for autoscale
  reconcile-aci-runners.yml          ACI only: creates/deletes container groups directly
  build-and-push-runner-image.yml    ACI only: builds and pushes the runner image
```

`terraform/data.tf` assumes a resource group, VNet, a Key Vault, and (for
the VMSS backend) two subnets and a blob private DNS zone **already
exist** in your environment. Adjust `data.tf` if your existing module
already has these as outputs/locals elsewhere rather than fresh data
lookups. If any of these live in a **different resource group** than the
one you're deploying into (e.g. a separate hub/landing-zone RG for
networking), see the role-assignment note in step 7.3 - the deploy
identity needs `Reader` (at minimum) on that resource group too, or every
plan/apply fails at the data-source lookup stage.

---

## Setup order matters

Do these in order. Specifically: **the Key Vault secret must exist before
any VMSS instance boots**, or the bootstrap script has nothing to
authenticate with on first boot.

### 0. Create the Key Vault (skip if you already have one)

Everything else in this README - the GitHub App token, the VMSS SSH
public key, all the OIDC role assignments - references an existing Key
Vault by name. If you don't already have one to point this at, create it
first. Paste this whole block into **Azure Portal → Cloud Shell** (Bash):

```bash
# --- Adjust these three to your environment ---
RESOURCE_GROUP_NAME="rg-mgmt-devops"
LOCATION="australiaeast"
KEY_VAULT_NAME="kv-ghrunner-$RANDOM"   # must be globally unique, 3-24 chars, letters/numbers/hyphens only

# Create the resource group if it doesn't already exist (no-ops safely if it does)
az group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION"

# Create the vault with RBAC authorization enabled - required, since every
# role assignment in this README (Key Vault Secrets User / Secrets
# Officer) is an Azure RBAC role. The older access-policy model doesn't
# recognise those and everything downstream would silently fail on
# permission errors.
az keyvault create \
  --name "$KEY_VAULT_NAME" \
  --resource-group "$RESOURCE_GROUP_NAME" \
  --location "$LOCATION" \
  --enable-rbac-authorization true

# RBAC vaults grant no data-plane access by default - not even to the
# account that just created it. Grant yourself rights to manage secrets
# so steps 4/5 below (seeding the GitHub token, storing the SSH key) work.
CURRENT_USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
az role assignment create \
  --assignee "$CURRENT_USER_OBJECT_ID" \
  --role "Key Vault Secrets Officer" \
  --scope $(az keyvault show --name "$KEY_VAULT_NAME" --query id -o tsv)

echo ""
echo "Key Vault created: $KEY_VAULT_NAME"
echo "Resource group:    $RESOURCE_GROUP_NAME"
echo ""
echo "Use these as key_vault_name / key_vault_resource_group_name in"
echo "terraform.tfvars, and in every az command in the rest of this README"
echo "that references a Key Vault."
```

Role assignment propagation can take a minute or two - if the very next
command (e.g. `az keyvault secret set`) fails with a permissions error
immediately after this runs, wait briefly and retry before assuming
something's wrong.

**Already have a vault that uses the older access-policy model instead of
RBAC?** Either migrate it (`az keyvault update --name <vault> --enable-rbac-authorization true`
- confirm this doesn't break anything else already relying on that vault's
access policies first) or create a fresh, dedicated vault via the block
above rather than fighting the two authorization models against each
other.

### 1. Create the GitHub App

This App's installation token is what lets the refresh workflow mint
runner-registration tokens - keep its permissions minimal.

1. Org Settings → Developer settings → GitHub Apps → New GitHub App
2. Homepage URL: anything (not used)
3. Webhook: uncheck "Active" (not needed)
4. Permissions → Organization permissions → **Self-hosted runners: Read and write**
   (no other permissions needed)
5. "Where can this GitHub App be installed?" → Only on this account
6. Create the App, then:
   - Note the **App ID** (top of the App's settings page)
   - Generate a **private key** (.pem) - downloads once, store it securely
7. Install the App on your org (App settings → Install App → select org →
   All repositories, or none, since it only needs org-level runner
   permissions, not repo access)

### 1a. Get your GitHub owner ID and repository ID

Every federated credential subject below needs your org/user name and repo
name. **If your repo uses GitHub's immutable OIDC subject format** (default
for all repos created after July 15, 2026, and any repo that's opted in),
the subject GitHub actually issues also embeds two numeric IDs -
`repo:<owner>@<ownerId>/<repo>@<repoId>:ref:...` - and the federated
credential's `subject` must match that exact string, numeric IDs included,
or login fails with `AADSTS700213: No matching federated identity record
found`.

Grab both IDs once, up front, so every step below can reuse them:

```bash
# Requires the GitHub CLI (gh) - or use the curl fallback below if you don't have it
ownerId=$(gh api users/<your-org-or-username> --jq .id)
repoId=$(gh api repos/<your-org>/<this-repo> --jq .id)
echo "Owner ID: $ownerId"
echo "Repo ID:  $repoId"
```

Without `gh`, plain REST works too (no auth needed for public repos):
```bash
ownerId=$(curl -s https://api.github.com/repos/<your-org>/<this-repo> | jq '.owner.id')
repoId=$(curl -s https://api.github.com/repos/<your-org>/<this-repo> | jq '.id')
```

To check whether immutable subjects are actually active for this repo (and
see the exact subject prefix GitHub will issue) rather than guessing:
```bash
gh api repos/<your-org>/<this-repo>/actions/oidc/customization/sub
```
or check repo Settings → Actions → General → OIDC section in the browser.

**Every federated credential `subject` in the steps below is shown in the
plain `<your-org>/<this-repo>` form.** If immutable subjects are active for
your repo, substitute `<your-org>@$ownerId/<this-repo>@$repoId` instead -
e.g. `"subject": "repo:gavinwun@$ownerId/azure_tests@$repoId:ref:refs/heads/main"`.
If you're not sure which format applies, the `oidc/customization/sub` call
above tells you definitively - don't assume based on when the repo was
created, since org-level opt-in can also enable it early.

### 2. Set up Azure OIDC for the refresh workflow

1. Create (or reuse) an Azure AD App registration for this workflow. The
   commands below capture the `appId` automatically with `--query`
   instead of you having to copy it out of the JSON output by hand, and
   fail fast (`set -euo pipefail` plus an explicit empty-value check) if
   the create step doesn't actually return one - e.g. an expired login or
   a permissions error that still exits 0:
   ```bash
   set -euo pipefail

   appId=$(az ad app create --display-name "gh-runner-token-refresh" --query appId -o tsv)
   if [[ -z "$appId" || "$appId" == "null" ]]; then
     echo "ERROR: Failed to create app registration or retrieve appId" >&2
     exit 1
   fi
   echo "App ID: $appId"

   if ! az ad sp create --id "$appId"; then
     echo "ERROR: Failed to create service principal for appId $appId" >&2
     exit 1
   fi
   echo "Service principal created successfully"
   ```
   Note this isn't idempotent - re-running it creates a duplicate app
   each time. If you need to re-run this block safely (e.g. in CI), look
   up the existing app by display name first:
   ```bash
   existing=$(az ad app list --display-name "gh-runner-token-refresh" --query "[0].appId" -o tsv)
   if [[ -n "$existing" && "$existing" != "null" ]]; then
     echo "App already exists with appId: $existing"
     appId="$existing"
   else
     appId=$(az ad app create --display-name "gh-runner-token-refresh" --query appId -o tsv)
     # ...same empty-value check as above
   fi
   ```
2. Add a federated credential scoped to this exact repo + workflow. Use the
   plain name-based subject shown here, **or** the immutable
   `<org>@$ownerId/<repo>@$repoId` form from step 1a if that's what your
   repo actually issues - check with `gh api repos/<org>/<repo>/actions/oidc/customization/sub`
   if unsure:
   ```bash
   az ad app federated-credential create \
     --id "$appId" \
     --parameters '{
       "name": "gh-runner-token-refresh",
       "issuer": "https://token.actions.githubusercontent.com",
       "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
       "audiences": ["api://AzureADTokenExchange"]
     }'
   ```
3. Grant it **Key Vault Secrets Officer** (or a narrower custom role
   limited to `set`) scoped to just the Key Vault:
   ```bash
   az role assignment create \
     --assignee "$appId" \
     --role "Key Vault Secrets Officer" \
     --scope $(az keyvault show --name <key-vault-name> --query id -o tsv)
   ```

### 3. Add GitHub repo secrets/variables (for the refresh workflow)

Repo → Settings → Secrets and variables → Actions:

| Name | Type | Value |
|---|---|---|
| `RUNNER_BOOTSTRAP_APP_ID` | Variable | App ID from step 1 |
| `RUNNER_BOOTSTRAP_APP_PRIVATE_KEY` | Secret | contents of the .pem from step 1 |
| `AZURE_CLIENT_ID` | Variable | App registration client ID from step 2 |
| `AZURE_TENANT_ID` | Variable | your Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Variable | subscription containing the Key Vault |
| `KEYVAULT_NAME` | Variable | the Key Vault name |

### 4. Seed the Key Vault secret (manual first run)

Push `.github/workflows/refresh-github-app-token.yml`, then trigger it
manually once before running Terraform:

Repo → Actions → "Refresh GitHub App Token in Key Vault" → Run workflow

Confirm the secret landed:
```bash
az keyvault secret show --vault-name <key-vault-name> --name github-app-token \
  --query "attributes.{updated:updated, expires:expires}"
```

The workflow re-runs itself every 30 minutes after this (`on: schedule`),
so it now stays fresh without further action.

### 5. Store the VMSS SSH key pair in Key Vault

Terraform reads the public key via
`data.azurerm_key_vault_secret.vmss_ssh_public_key` (see `data.tf`) rather
than generating a key itself. Store the private key alongside it too, so
you (or `az vmss run-command`) can always retrieve it for debugging
without depending on whoever generated it still having the local file:

```bash
ssh-keygen -t ed25519 -f ./ghrunner-vmss-key -N ""

az keyvault secret set \
  --vault-name <key-vault-name> \
  --name vmss-ssh-public-key \
  --value "$(cat ./ghrunner-vmss-key.pub)"

az keyvault secret set \
  --vault-name <key-vault-name> \
  --name vmss-ssh-private-key \
  --value "$(cat ./ghrunner-vmss-key)"

# Once both secrets are confirmed in Key Vault, remove the local private
# key file rather than leaving a second copy sitting on disk:
shred -u ./ghrunner-vmss-key   # or `rm -P` / `rm` if shred isn't available
```

Confirm both secrets landed:
```bash
az keyvault secret list --vault-name <key-vault-name> --query "[?contains(name, 'vmss-ssh')].name" -o tsv
```

To retrieve the private key later (e.g. to SSH into an instance for
debugging):
```bash
az keyvault secret show --vault-name <key-vault-name> --name vmss-ssh-private-key --query value -o tsv > ./ghrunner-vmss-key
chmod 600 ./ghrunner-vmss-key
```

**Note:** the private key is stored as a Key Vault *secret*, not backed by
an HSM-protected *key* object - anyone with `Key Vault Secrets User` (or
broader) on this vault can read it in plaintext. That's the same access
level already required elsewhere in this README (e.g. the bootstrap
script's managed identity), so it doesn't introduce a new trust boundary,
but don't grant `Secrets User` more broadly than you already do for the
GitHub App token.

**If `./ghrunner-vmss-key` (no `.pub` extension) is missing** when you get
to the `az keyvault secret set` command for the private key - e.g. you're
resuming this step in a new terminal session, or an earlier run already
`shred`-ed it - the public and private halves are always generated
together by `ssh-keygen`, so there's no way to recover just the private
key from the `.pub` file. Simply re-run the `ssh-keygen` command from the
top of this step to generate a fresh pair, then continue - just make sure
you re-run **both** `az keyvault secret set` commands afterward so the
public and private secrets in Key Vault stay matched to the same pair.

### 6. Configure and edit `bootstrap_agent.sh`

Open `terraform/scripts/bootstrap_agent.sh` and set:
- `GITHUB_ORG` - your org name
- `KEYVAULT_NAME` - same vault as above
- `RUNNER_VERSION` - check https://github.com/actions/runner/releases and pin explicitly

### 7. Set up remote state + a second OIDC identity for the deploy pipeline

`terraform-deploy.yml` runs `terraform init`/`plan`/`apply` from a
GitHub-hosted runner (chicken-and-egg reasons - same as the token refresh
workflow, it can't depend on the VMSS it's creating), authenticated via its
own OIDC identity, separate from the token-refresh identity in step 2. Keep
them separate: this one needs much broader Azure permissions (create VMSS,
storage accounts, role assignments), and you don't want the token-refresh
workflow carrying that blast radius.

1. **Remote state storage** (if you don't already have one): a storage
   account + container to hold the `.tfstate` file. Any existing one in
   your subscription works fine - skip to step 2 if so. Otherwise, paste
   this into Cloud Shell (Bash):
   ```bash
   set -euo pipefail

   # --- Adjust these to your environment ---
   TFSTATE_RESOURCE_GROUP="rg-mgmt-devops"
   LOCATION="australiaeast"
   TFSTATE_STORAGE_ACCOUNT="sttfstate$RANDOM"   # must be globally unique, 3-24 chars, lowercase letters/numbers only
   TFSTATE_CONTAINER="tfstate"

   # Create the resource group if it doesn't already exist (no-ops safely if it does)
   az group create --name "$TFSTATE_RESOURCE_GROUP" --location "$LOCATION"

   # Standard_LRS is fine for state - it's small and this isn't the kind of
   # data that needs geo-redundancy. Enable versioning so a bad `apply`
   # or corrupted state file can be rolled back instead of being a P1.
   az storage account create \
     --name "$TFSTATE_STORAGE_ACCOUNT" \
     --resource-group "$TFSTATE_RESOURCE_GROUP" \
     --location "$LOCATION" \
     --sku Standard_LRS \
     --kind StorageV2 \
     --min-tls-version TLS1_2 \
     --allow-blob-public-access false

   az storage account blob-service-properties update \
     --account-name "$TFSTATE_STORAGE_ACCOUNT" \
     --enable-versioning true

   # RBAC vaults grant no data-plane access by default; storage accounts
   # are the same - grant yourself Storage Blob Data Contributor so the
   # container-create command below (and any local `terraform init` you
   # run later) actually works.
   CURRENT_USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
   az role assignment create \
     --assignee "$CURRENT_USER_OBJECT_ID" \
     --role "Storage Blob Data Contributor" \
     --scope $(az storage account show --name "$TFSTATE_STORAGE_ACCOUNT" --resource-group "$TFSTATE_RESOURCE_GROUP" --query id -o tsv)

   # Role assignment propagation can take a minute or two - if the next
   # command fails with an auth error, wait briefly and retry.
   az storage container create \
     --name "$TFSTATE_CONTAINER" \
     --account-name "$TFSTATE_STORAGE_ACCOUNT" \
     --auth-mode login

   echo ""
   echo "TFSTATE_RESOURCE_GROUP:   $TFSTATE_RESOURCE_GROUP"
   echo "TFSTATE_STORAGE_ACCOUNT:  $TFSTATE_STORAGE_ACCOUNT"
   echo "TFSTATE_CONTAINER:        $TFSTATE_CONTAINER"
   echo ""
   echo "Use these as the repo variables in step 4 below, and as the"
   echo "-backend-config values in step 8 if you run Terraform locally."
   ```
   The identity that runs `terraform init`/`apply` (the App registration
   created in step 2 below) also needs data-plane access to this
   container - that's covered by the `Contributor` role granted to it in
   step 3, since `Contributor` includes storage data actions. If you
   later narrow that role down, make sure `Storage Blob Data Contributor`
   (or `Owner`) on this storage account specifically is kept.
2. **A second App registration + federated credential**, this time with
   two subjects - one for pull requests (plan) and one for the main branch
   (apply). Same auto-capture + error-check pattern as step 2 above, and
   same note as step 2 on the plain-vs-immutable subject format (see step 1a).

   **Important:** this reuses the `$appId` variable name from step 2 above -
   if you're pasting commands into the same terminal session, this
   overwrites that earlier value. Before running anything below, confirm
   you don't still need the old `$appId` for anything, and after this
   block completes, confirm it actually points at the new app before
   adding federated credentials to it:
   ```bash
   az ad app show --id "$appId" --query displayName -o tsv   # should print gh-runner-vmss-terraform-deploy
   ```
   If it prints `gh-runner-token-refresh` (or anything else) instead, the
   `az ad app create` below didn't run or its output wasn't captured -
   re-run the block rather than proceeding, since creating a federated
   credential against the wrong app's `$appId` will either land it on the
   wrong identity or fail with an "issuer and subject must be unique"
   error if that exact subject already exists there.
   ```bash
   set -euo pipefail

   appId=$(az ad app create --display-name "gh-runner-vmss-terraform-deploy" --query appId -o tsv)
   if [[ -z "$appId" || "$appId" == "null" ]]; then
     echo "ERROR: Failed to create app registration or retrieve appId" >&2
     exit 1
   fi
   echo "App ID: $appId"

   if ! az ad sp create --id "$appId"; then
     echo "ERROR: Failed to create service principal for appId $appId" >&2
     exit 1
   fi
   echo "Service principal created successfully"

   # Federated credential for PR-triggered plans
   az ad app federated-credential create --id "$appId" --parameters '{
     "name": "tf-deploy-pr",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<your-org>/<this-repo>:pull_request",
     "audiences": ["api://AzureADTokenExchange"]
   }'

   # Federated credential for main-branch applies
   az ad app federated-credential create --id "$appId" --parameters '{
     "name": "tf-deploy-main",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```
   **If you also set up the environment protection rule in step 5 below,**
   add a *third* federated credential now, or the `apply` job will fail at
   login with `AADSTS700213: No matching federated identity record found`
   even though `tf-deploy-main` above looks like it should match. Reason:
   a job that declares `environment: production` gets an OIDC subject in
   the form `repo:<org>/<repo>:environment:production` - not
   `ref:refs/heads/main` - regardless of which branch triggered it. This
   is easy to miss because it only surfaces once you actually reach an
   `apply` run with the environment gate active, not at credential-creation
   time:
   ```bash
   az ad app federated-credential create --id "$appId" --parameters '{
     "name": "tf-deploy-production-env",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<your-org>/<this-repo>:environment:production",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```
   Substitute the immutable `<org>@$ownerId/<repo>@$repoId` form here too
   if that's what your repo issues (see step 1a) - and if you rename the
   environment from `production` to something else in step 5, this
   subject's `environment:` suffix must match it exactly.
3. **Grant it the roles `main.tf` needs to actually create things** -
   scope these to the target resource group, not the whole subscription:
   - `Contributor` (VMSS, NIC, storage account, private endpoint)
   - `User Access Administrator` or `Role Based Access Control Administrator`
     (main.tf creates role assignments for the VMSS's managed identity -
     you can't grant a role you don't have permission to grant)
   ```bash
   for role in Contributor "Role Based Access Control Administrator"; do
     az role assignment create \
       --assignee "$appId" \
       --role "$role" \
       --scope $(az group show --name <resource-group-name> --query id -o tsv)
   done
   ```
   **Also grant data-plane access to the tfstate storage account specifically**
   - `Contributor` above only covers the storage account's management
   plane (create/configure/delete the account); it does **not** include
   blob data operations. Since the backend authenticates via Azure AD
   (`use_azuread_auth = true`, matching step 7.1's storage account setup)
   rather than a storage account key, `terraform init` needs an explicit
   data-plane role or it fails with `AuthorizationPermissionMismatch` on
   `ListBlobs` the moment it tries to read/lock state:
   ```bash
   az role assignment create \
     --assignee "$appId" \
     --role "Storage Blob Data Contributor" \
     --scope $(az storage account show --name <tfstate-storage-account> --resource-group <tfstate-resource-group> --query id -o tsv)
   ```
   Same minute-or-two propagation delay as other role assignments in this
   README applies here too.

   **Don't have an existing hub network to point at?** Set
   `manage_network = true` in `terraform.tfvars` and Terraform creates
   the VNet / subnets / private DNS zone (`network.tf`), instead of
   assuming they already exist. This skips the Reader / Network
   Contributor / Private DNS Zone Contributor grants below - all three
   are covered by a single `Contributor` grant on the hub resource
   group. Terraform does **not** create or own that resource group - it
   reads it via `data.azurerm_resource_group.network_hub`, the same way
   it reads the main one - so **pre-create it and grant `Contributor` on
   it**, same shape as the existing `resource_group_name` grant above but
   targeting `vnet_resource_group_name`:
   ```bash
   az group create --name <vnet-resource-group-name> --location <location>
   az role assignment create \
     --assignee "$appId" \
     --role "Contributor" \
     --scope $(az group show --name <vnet-resource-group-name> --query id -o tsv)
   ```
   Keeping the resource group out of Terraform's state means the deploy
   identity only ever needs a role scoped to that one RG - never the
   subscription - and `terraform destroy` can't take the network RG with
   it. (Same one-time-per-identity `Reader` bootstrap caveat as the
   `manage_network = false` case applies: the very first `plan` reads
   this RG via a data source before any grant in `network-rbac.tf` could
   exist - the `Contributor` grant above satisfies it.) If
   `vnet_resource_group_name` equals `resource_group_name`, the grant
   above already covers this - skip it. Leave `manage_network` at its
   default `false` if you're pointing at a real landing-zone network
   someone else manages; only flip it for a from-scratch environment, a
   demo, or a throwaway test deployment.

   **If your `data.tf` references resources outside the main resource
   group** - e.g. a separate hub/landing-zone resource group holding the
   VNet, subnets, or private DNS zones referenced by `data "azurerm_subnet"`
   / `data "azurerm_private_dns_zone"` blocks - the `Contributor` grant
   above doesn't cover it, since it's scoped only to `<resource-group-name>`.
   `network-rbac.tf` codifies the ongoing grants Terraform needs there
   (`Reader` for the data-source lookups, `Network Contributor` for the
   subnet attaches, `Private DNS Zone Contributor` for the private
   endpoint's DNS zone group - three distinct built-in roles, since
   `Network Contributor` does **not** cover private DNS zone actions).

   **But `network-rbac.tf`'s own role assignments can't bootstrap
   themselves** - Terraform evaluates `data.tf`'s data sources before
   any resource in the same run exists, including the role assignments
   that would grant access to read them. So on a fresh deploy identity,
   do this **one-time manual grant** first, or the very first
   `terraform plan` fails at the data-source stage with
   `AuthorizationFailed` before it ever reaches `network-rbac.tf`:
   ```bash
   az role assignment create \
     --assignee "$appId" \
     --role "Reader" \
     --scope $(az group show --name <hub-network-resource-group-name> --query id -o tsv)
   ```
   Once that's in place, `terraform apply` creates the `Network
   Contributor` and `Private DNS Zone Contributor` grants itself via
   `network-rbac.tf`, and keeps managing all three going forward -
   nothing further to do manually unless the deploy identity is ever
   recreated (not just re-authenticated), in which case this one Reader
   grant needs repeating once for the new identity - same category as
   the tfstate storage account bootstrap in step 7.1.

   **Same issue, separately, for the Key Vault.** `data.tf`'s SSH
   public-key secret lookup is also read during plan, by the deploy
   identity - not by the VMSS's own managed identity, which is what
   `main.tf` actually grants Key Vault access to. Without this, plan
   fails with a 403 on `getSecret/action` before it ever reaches
   `main.tf`. One-time manual grant, same reasoning as above:
   ```bash
   az role assignment create \
     --assignee "$appId" \
     --role "Key Vault Secrets User" \
     --scope $(az keyvault show --name <key-vault-name> --query id -o tsv)
   ```
   `keyvault-rbac.tf` takes over managing this grant going forward, same
   as `network-rbac.tf` does for the hub network access above.

   **Also double-check any resource names hardcoded in `data.tf`** (Key
   Vault name, VNet name, subnet names, DNS zone name) actually match what
   you created in step 0 and elsewhere - a name mismatch surfaces as
   `<resource> was not found` rather than a permissions error, and is easy
   to miss since it looks similar to the 403s above at a glance. In
   particular, the Key Vault name in `data.tf` must match the
   `KEYVAULT_NAME` you actually created (see step 0) - not a placeholder
   or example name left over from copying the template.
4. **Repo variables** (Settings → Secrets and variables → Actions → Variables):

   | Name | Value |
   |---|---|
   | `TF_DEPLOY_AZURE_CLIENT_ID` | App registration client ID from this step |
   | `TFSTATE_RESOURCE_GROUP` | resource group holding your state storage account |
   | `TFSTATE_STORAGE_ACCOUNT` | that storage account's name |
   | `TFSTATE_CONTAINER` | blob container name for state |

   (`AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` are already set from step 3.)

5. **Set up an environment protection rule**: repo Settings → Environments
   → New environment → `production` → require reviewers. This gates the
   `apply` job behind manual approval even after a PR merges - remove it
   later if you want fully automatic applies. **If you're adding this,**
   make sure you've also added the `tf-deploy-production-env` federated
   credential back in step 2 above, or the gated `apply` job will fail
   OIDC login once it actually runs.

   CLI equivalent (needs `gh` with admin on the repo):
   ```bash
   # bare environment (no gate)
   gh api --method PUT repos/<owner>/<repo>/environments/production
   # ...with yourself as a required reviewer
   gh api --method PUT repos/<owner>/<repo>/environments/production \
     --input - <<< "{\"reviewers\":[{\"type\":\"User\",\"id\":$(gh api user --jq .id)}]}"
   ```
   `setup/bootstrap.sh --set-github` creates the bare environment; add
   `--env-require-self-review` to include the reviewer rule.

6. `terraform.tfvars` is already committed in this bundle with placeholder
   values (nothing in it is sensitive - just resource/subnet/VNet names).
   Edit it with your real values before merging.

### 8. Push and merge

- Open a PR touching `terraform/**` → the `plan` job runs and comments the
  plan output on the PR.
- Merge to `main` → the `apply` job runs (pausing for approval if you set
  up the environment protection rule in step 7.5).
- Or trigger `workflow_dispatch` manually any time to re-apply without a
  code change.

You can still run Terraform locally instead if you'd rather not stand up
the pipeline yet:
```bash
cd terraform
terraform init \
  -backend-config="resource_group_name=<tfstate-rg>" \
  -backend-config="storage_account_name=<tfstate-sa>" \
  -backend-config="container_name=<tfstate-container>" \
  -backend-config="key=github-runner-vmss.tfstate"
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

**Bootstrap storage public-access window.** `bootstrap_agent.sh` is
uploaded to a storage account whose public endpoint is shut by default
(`main.tf`, `azurerm_storage_blob.bootstrap_script`). The identity
running `terraform apply` can only reach it over that public endpoint
unless it's already inside the hub VNet - so the first deploy, and any
later apply from a GitHub-hosted runner, has to open the firewall to
itself for the upload. Two variables control this:

| Variable | Default | Set during a bootstrap apply |
| --- | --- | --- |
| `bootstrap_storage_public_network_access_enabled` | `false` | `true` |
| `bootstrap_storage_allowed_ips` | `[]` | `["<your egress IP>"]` |

The account stays default-deny in both states; opening it just adds your
IP to the allowlist. The `apply` job in `terraform-deploy.yml` already
does this automatically - it detects the runner's egress IP, applies once
with the endpoint open, then applies again with the defaults to re-lock,
plus an `az storage account update` safety-net step in case the first
apply fails partway. Running locally, do the same by hand:
```bash
MYIP=$(curl -fsS https://api.ipify.org)
terraform apply -var-file="terraform.tfvars" \
  -var="bootstrap_storage_public_network_access_enabled=true" \
  -var="bootstrap_storage_allowed_ips=[\"$MYIP\"]"
terraform apply -var-file="terraform.tfvars"   # re-lock
```
Once the private endpoint and self-hosted runners exist, applies that run
*on* those runners reach the account privately and need neither `-var`.

### 9. Verify

- **Azure side**: `az vmss list-instances -g <rg> -n <vmss-name> -o table` -
  instances should reach `Succeeded` provisioning state within a few minutes.
- **Bootstrap logs** (if you need to debug, via `az vmss run-command` or SSH
  using the key from step 5):
  ```
  /var/log/bootstrap/bootstrap-download.log       # extension download step
  /var/log/bootstrap/bootstrap.log                # bootstrap_agent.sh output
  /var/log/bootstrap/bootstrap_agent_detail.log    # full tee'd output
  ```
- **GitHub side**: Org Settings → Actions → Runners - your VMSS instances
  should appear, named `vmss-runner-<hostname>`, with the labels set in
  `bootstrap_agent.sh` (`self-hosted, linux, x64, vmss`).

---

## Optional: Queue-based autoscaling (no KEDA, no storage account)

KEDA has no scale target for VMSS - it scales Kubernetes workloads or
Container Apps, not VM Scale Sets. Instead, `custom-metric-autoscale.tf`
uses VMSS's own autoscale engine against a **custom Azure Monitor
metric**: a scheduled workflow (`poll-queue-depth.yml`) polls GitHub for
queued job count and pushes it straight to Azure Monitor via the custom
metrics REST API, authenticated purely via AAD - no storage account, no
shared key, anywhere in this piece.

This is additive to everything above - do the base setup (steps 1-9)
first, then:

### A. Add "Actions: Read" to the GitHub App

The same App from step 1 now also needs **Organization permissions →
Actions: Read-only**, so the poller can list queued workflow runs. Edit
the App's permissions (App settings → Permissions & events) and re-accept
the updated permissions on the org installation.

### B. Create a third OIDC identity for the poller

Same reasoning as the deploy pipeline's separate identity - narrowest
possible permissions for what this workflow actually does (publish one
metric against one resource, nothing else). Same auto-capture +
error-check pattern as steps 2 and 7, and same plain-vs-immutable subject
note as step 1a.

**Same `$appId` reuse caveat as step 7** - this overwrites `$appId` from
whichever identity you created last. Verify after creation:
```bash
az ad app show --id "$appId" --query displayName -o tsv   # should print gh-runner-queue-poller
```

```bash
set -euo pipefail

appId=$(az ad app create --display-name "gh-runner-queue-poller" --query appId -o tsv)
if [[ -z "$appId" || "$appId" == "null" ]]; then
  echo "ERROR: Failed to create app registration or retrieve appId" >&2
  exit 1
fi
echo "App ID: $appId"

if ! az ad sp create --id "$appId"; then
  echo "ERROR: Failed to create service principal for appId $appId" >&2
  exit 1
fi
echo "Service principal created successfully"

az ad app federated-credential create --id "$appId" --parameters '{
  "name": "queue-poller",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

az role assignment create \
  --assignee "$appId" \
  --role "Monitoring Metrics Publisher" \
  --scope $(terraform -chdir=terraform output -raw vmss_id)
```

### C. Add repo variables

| Name | Value |
|---|---|
| `QUEUE_POLLER_AZURE_CLIENT_ID` | App registration client ID from step B |
| `VMSS_RESOURCE_ID` | output of `terraform output -raw vmss_id` |
| `VMSS_REGION` | output of `terraform output -raw vmss_location`, e.g. `australiaeast` |
| `GITHUB_ORG` | your org name (same value as `github_org` in tfvars) |

### D. Apply and verify

`custom-metric-autoscale.tf` is picked up automatically by the existing
`terraform-deploy.yml` pipeline (or `terraform apply` locally). After
applying and running the poller once (Actions → "Poll GitHub Queue Depth
for VMSS Autoscale" → Run workflow):

```bash
# Confirm the autoscale setting exists and targets the right VMSS
az monitor autoscale show \
  --resource-group <resource-group-name> \
  --name "autoscale-<vmss-name>"

# Confirm the custom metric is actually landing in Azure Monitor
az monitor metrics list \
  --resource $(terraform -chdir=terraform output -raw vmss_id) \
  --metric "QueuedJobs" \
  --namespace "GitHubActionsQueue"
```

### Tuning knobs (in `terraform.tfvars`)

| Variable | Effect |
|---|---|
| `queue_autoscale_min_instances` | floor - never scales below this even at 0 queue depth |
| `queue_autoscale_max_instances` | ceiling |
| `queue_messages_per_instance` | how many queued jobs justify one more instance (default 1:1) |
| `queue_scale_out_cooldown_minutes` | default 2 - how fast to react to a growing queue |
| `queue_scale_in_cooldown_minutes` | default 10 - kept higher than scale-out to avoid flapping |
| `custom_metric_namespace` / `custom_metric_name` | must match exactly what `poll-queue-depth.yml` publishes |

### Caveats specific to this approach

- **Queued *runs*, not queued *jobs*.** The poller counts queued
  workflow runs org-wide, not individual jobs filtered by runner label.
  If a lot of your queued runs target GitHub-hosted runners rather than
  this VMSS, or a single run fans out into many parallel jobs, the count
  won't be a precise 1:1 signal. Fine as a first pass; revisit with
  label-filtered job counting if it proves too coarse.
- **Custom metrics have ~1-2 minutes of ingestion latency** and are
  buffered/aggregated on a 60-second interval - don't expect the
  autoscaler to react within seconds of a job being queued.
- **The `metric` step's timestamp must be within the last 20 minutes**
  of when Azure Monitor receives it - if the poller workflow is delayed
  by GitHub's scheduler for longer than that, that publish is silently
  dropped rather than backfilled. Rare at a 5-minute cadence, but worth
  knowing if scaling seems to stall.
- **The orphaned-runner-on-scale-in gap is now handled** - see below,
  which now documents the terminate-notification hook rather than
  flagging it as open.

## Switching to the ACI backend

ACI has no scale-set concept and no autoscale primitive - each container
group is a standalone deployable unit. `reconcile-aci-runners.yml`
directly creates and deletes container groups to track queued job count,
replacing everything `custom-metric-autoscale.tf` and Azure Monitor do
for the VMSS backend. The bootstrap-script/SSH-key/private-endpoint
machinery from the VMSS setup doesn't apply here either - the runner
image has everything baked in via `docker/Dockerfile`, and registration
happens in `docker/entrypoint.sh` at container start instead of a
boot-time script.

This is a genuine backend switch, not an addition - do this instead of
the VMSS setup above, not alongside it (on a live environment, switching
means destroying the VMSS backend's resources and creating the ACI
backend's, since Terraform can't run both at once for the same
`compute_backend` value).

### A. Set the flag

In `terraform.tfvars`:
```hcl
compute_backend = "aci"
```

### B. Network prerequisite

`aci.tf` creates a new, dedicated subnet (delegated to
`Microsoft.ContainerInstance/containerGroups`) inside your existing VNet
- distinct from the VMSS backend's `devopsagent` subnet, since
ACI-delegated subnets can only contain container groups, nothing else.
Set `aci_subnet_address_prefix` in `terraform.tfvars` to a range that
doesn't overlap anything else in that VNet.

**Permissions note:** creating a subnet needs `Network Contributor` (or
`Contributor`) on the VNet's resource group. If `vnet_resource_group_name`
differs from your main `resource_group_name`, the deploy pipeline's
identity (from the base setup's step 7) needs this granted separately:
```bash
az role assignment create \
  --assignee <tf-deploy-appId> \
  --role "Network Contributor" \
  --scope $(az group show --name <vnet-resource-group-name> --query id -o tsv)
```

### C. Create a fourth OIDC identity - the ACI orchestrator

Used by both `build-and-push-runner-image.yml` and
`reconcile-aci-runners.yml`. Grouped together deliberately since both are
"manage the runner compute" concerns. Same auto-capture + error-check
pattern as the other identities above, and same plain-vs-immutable subject
note as step 1a.

**Same `$appId` reuse caveat as step 7** - verify after creation:
```bash
az ad app show --id "$appId" --query displayName -o tsv   # should print gh-runner-aci-orchestrator
```

```bash
set -euo pipefail

appId=$(az ad app create --display-name "gh-runner-aci-orchestrator" --query appId -o tsv)
if [[ -z "$appId" || "$appId" == "null" ]]; then
  echo "ERROR: Failed to create app registration or retrieve appId" >&2
  exit 1
fi
echo "App ID: $appId"

if ! az ad sp create --id "$appId"; then
  echo "ERROR: Failed to create service principal for appId $appId" >&2
  exit 1
fi
echo "Service principal created successfully"

az ad app federated-credential create --id "$appId" --parameters '{
  "name": "aci-orchestrator",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Grant it, after `terraform apply` has created the ACR:
```bash
# Push images (build-and-push-runner-image.yml)
az role assignment create \
  --assignee "$appId" \
  --role "AcrPush" \
  --scope $(terraform -chdir=terraform output -raw acr_login_server | \
             xargs -I{} az acr show --name $(terraform -chdir=terraform output -raw acr_name) --query id -o tsv)

# Create/delete/list container groups (reconcile-aci-runners.yml)
az role assignment create \
  --assignee "$appId" \
  --role "Azure Container Instances Contributor Role" \
  --scope $(az group show --name <resource-group-name> --query id -o tsv)
```

### D. Add "Actions: Read" to the GitHub App

Same as the queue-based autoscaling setup - `reconcile-aci-runners.yml`
needs it to count queued runs. Skip this if you already added it for the
VMSS backend's poller.

### E. Add repo variables

| Name | Value |
|---|---|
| `COMPUTE_BACKEND` | `aci` - this is the actual on/off switch for both new workflows |
| `ACI_ORCHESTRATOR_AZURE_CLIENT_ID` | App registration client ID from step C |
| `RESOURCE_GROUP_NAME` | your resource group name |
| `ACR_NAME` | `terraform output -raw acr_name` |
| `ACR_LOGIN_SERVER` | `terraform output -raw acr_login_server` |
| `ACI_SUBNET_NAME` | `terraform output -raw aci_subnet_name` |
| `ACI_VNET_ID` | `terraform output -raw aci_vnet_id` |
| `ACI_IDENTITY_ID` | `terraform output -raw aci_identity_id` |
| `VMSS_REGION` | deployment region, e.g. `australiaeast` (reused variable name - just means "region" here, not VMSS-specific) |
| `KEYVAULT_NAME` | same Key Vault as the base setup |
| `GITHUB_ORG` | same as the VMSS setup |
| `ACI_MIN_INSTANCES` / `ACI_MAX_INSTANCES` | optional, default 0 / 10 |
| `ACI_CONTAINER_CPU` / `ACI_CONTAINER_MEMORY_GB` | optional, default 2 / 4 |
| `ACI_IMAGE_TAG` | optional, default `latest` |

### F. Apply, build the image, and verify

```bash
cd terraform
terraform apply -var-file="terraform.tfvars"
```

Then trigger `build-and-push-runner-image.yml` manually once (Actions →
run workflow) to get an initial image into ACR before
`reconcile-aci-runners.yml` tries to pull one.

```bash
# Confirm the image landed
az acr repository show-tags --name <acr-name> --repository gh-runner

# After reconcile-aci-runners.yml has run at least once, check for
# active container groups
az container list --resource-group <resource-group-name> \
  --query "[?tags.\"managed-by\"=='gh-runner-poller'].{name:name, state:properties.instanceView.state}" \
  -o table
```

### Caveats specific to the ACI backend

- **No terminate-notification equivalent.** VMSS's graceful-deregister
  hook doesn't apply here - there's no "idle instance" state for ACI to
  worry about the way VMSS scale-in does, since containers are created
  roughly 1:1 with queued jobs and exit on their own once the job's
  done. The cleanup step in `reconcile-aci-runners.yml` deletes
  Terminated/Failed groups each pass, which is the ACI equivalent of
  the problem terminate-notification solves for VMSS.
- **`--no-wait` on container creation** means the workflow doesn't block
  waiting for each group to actually start - if `az container create`
  fails asynchronously (bad image tag, quota, subnet exhaustion), it
  won't surface as a workflow failure. Worth checking `az container
  list` periodically if jobs seem to be queuing without runners
  appearing.
- **Docker-in-Docker isn't set up.** The Dockerfile installs the Docker
  CLI, but running containers *inside* the ACI container group needs
  privileged mode, which isn't configured - add it deliberately if your
  workflows need it, understanding the security trade-off of privileged
  containers.
- **Counts queued *runs*, not label-filtered *jobs*** - same
  approximation as the VMSS poller, see its caveats above.

## Scale-in of idle instances - handled via terminate notification

**VMSS backend only** - the ACI backend has no equivalent idle-instance
concept; see its caveats above instead.


`--ephemeral` runners deregister themselves automatically **after
completing a job**. Without help, an instance that VMSS scale-in
deallocates while idle (never picked up a job) would leave its runner
registration "offline" in GitHub's list for up to 24 hours until GitHub's
own cleanup reaps it - correctness isn't affected (GitHub never dispatches
jobs to an offline runner), but it's dashboard clutter.

This is now closed by two pieces working together:

- **`termination_notification` on the VMSS** (`main.tf`) - gives Azure a
  5-minute warning window before it actually deallocates a targeted
  instance, instead of pulling the plug immediately.
- **`terminate-watcher.sh`** (installed by `bootstrap_agent.sh`, runs as
  a systemd service) - polls this instance's IMDS Scheduled Events every
  5 seconds. When it sees a pending Terminate event for itself, it:
  1. Waits if a job is actively running (`Runner.Worker` process present)
     rather than cutting it off mid-execution - though Azure's own
     timeout above is a hard ceiling regardless; a job that outlives the
     5-minute window gets terminated anyway.
  2. Once safe, mints a removal token via the same GitHub App / Key
     Vault path `bootstrap_agent.sh` already uses (no new permissions
     needed - it reuses the VMSS's existing managed identity), and runs
     `config.sh remove`.
  3. Approves the termination event early via IMDS, so deallocation
     proceeds immediately rather than waiting out the rest of the
     5-minute window.

**Nothing extra to configure** - this activates automatically once you
apply `main.tf` with `termination_notification` present. Worth knowing:

- If your jobs commonly run long, consider raising the Terraform timeout
  toward its 15-minute maximum (`termination_notification.timeout`) to
  give in-flight jobs more room before Azure force-terminates regardless
  of what the watcher is doing.
- If a job genuinely outlives the timeout, the instance is terminated
  mid-job either way - this hook reduces *unnecessary* stale
  registrations, it doesn't change Azure's hard deadline.

## Ongoing operations

- **Rotate the GitHub App private key** periodically via the App's
  settings page - update `RUNNER_BOOTSTRAP_APP_PRIVATE_KEY` in GitHub
  after rotating.
- **Bump `RUNNER_VERSION`** in `bootstrap_agent.sh` deliberately when
  GitHub ships new runner releases - it's pinned on purpose.
- **Ubuntu version**: `main.tf` uses 22.04 LTS
  (`0001-com-ubuntu-server-jammy` / `22_04-lts-gen2`). Swap to
  `ubuntu-24_04-lts` / `server` for 24.04 if preferred.
