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
  data.tf                      References to your existing RG/VNet/subnets/DNS/Key Vault
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
lookups.

---

## Setup order matters

Do these in order. Specifically: **the Key Vault secret must exist before
any VMSS instance boots**, or the bootstrap script has nothing to
authenticate with on first boot.

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

### 2. Set up Azure OIDC for the refresh workflow

1. Create (or reuse) an Azure AD App registration for this workflow:
   ```bash
   az ad app create --display-name "gh-runner-token-refresh"
   az ad sp create --id <appId-from-above>
   ```
2. Add a federated credential scoped to this exact repo + workflow:
   ```bash
   az ad app federated-credential create \
     --id <appId> \
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
     --assignee <appId> \
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

### 5. Store the VMSS SSH public key in Key Vault

Terraform reads this via `data.azurerm_key_vault_secret.vmss_ssh_public_key`
(see `data.tf`) rather than generating a key itself:

```bash
ssh-keygen -t ed25519 -f ./ghrunner-vmss-key -N ""
az keyvault secret set \
  --vault-name <key-vault-name> \
  --name vmss-ssh-public-key \
  --value "$(cat ./ghrunner-vmss-key.pub)"
# keep ./ghrunner-vmss-key (the private half) somewhere safe if you need
# to SSH into an instance for debugging
```

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
   your subscription works fine.
2. **A second App registration + federated credential**, this time with
   two subjects - one for pull requests (plan) and one for the main branch
   (apply):
   ```bash
   az ad app create --display-name "gh-runner-vmss-terraform-deploy"
   az ad sp create --id <appId>

   # Federated credential for PR-triggered plans
   az ad app federated-credential create --id <appId> --parameters '{
     "name": "tf-deploy-pr",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<your-org>/<this-repo>:pull_request",
     "audiences": ["api://AzureADTokenExchange"]
   }'

   # Federated credential for main-branch applies
   az ad app federated-credential create --id <appId> --parameters '{
     "name": "tf-deploy-main",
     "issuer": "https://token.actions.githubusercontent.com",
     "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```
3. **Grant it the roles `main.tf` needs to actually create things** -
   scope these to the target resource group, not the whole subscription:
   - `Contributor` (VMSS, NIC, storage account, private endpoint)
   - `User Access Administrator` or `Role Based Access Control Administrator`
     (main.tf creates role assignments for the VMSS's managed identity -
     you can't grant a role you don't have permission to grant)
   ```bash
   for role in Contributor "Role Based Access Control Administrator"; do
     az role assignment create \
       --assignee <appId> \
       --role "$role" \
       --scope $(az group show --name <resource-group-name> --query id -o tsv)
   done
   ```
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
   later if you want fully automatic applies.

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
metric against one resource, nothing else):

```bash
az ad app create --display-name "gh-runner-queue-poller"
az ad sp create --id <appId>

az ad app federated-credential create --id <appId> --parameters '{
  "name": "queue-poller",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<your-org>/<this-repo>:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'

az role assignment create \
  --assignee <appId> \
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
"manage the runner compute" concerns:

```bash
az ad app create --display-name "gh-runner-aci-orchestrator"
az ad sp create --id <appId>

az ad app federated-credential create --id <appId> --parameters '{
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
  --assignee <appId> \
  --role "AcrPush" \
  --scope $(terraform -chdir=terraform output -raw acr_login_server | \
             xargs -I{} az acr show --name $(terraform -chdir=terraform output -raw acr_name) --query id -o tsv)

# Create/delete/list container groups (reconcile-aci-runners.yml)
az role assignment create \
  --assignee <appId> \
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
