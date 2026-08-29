# queue-metric-function

A Consumption-plan Azure Function that publishes the **`QueuedJobs`** custom
metric on the VMSS - the signal `custom-metric-autoscale.tf` scales on. It is
an alternative to the `poll-queue-depth.yml` scheduled workflow that does not
depend on GitHub's cron actually firing.

| Trigger | When | What it does |
|---|---|---|
| `workflowJobWebhook` (HTTP) | GitHub `workflow_job` event for a job whose `runs-on` labels match `RUNNER_MATCH_LABELS` | HMAC-verifies the payload, then does an authoritative recount + publish - autoscale reacts in seconds |
| `queueMetricTimer` (timer) | every 3 min | Same recount + publish - heartbeat / self-heal, and works with no webhook configured |

Both call the same path: mint a GitHub App installation token from the
private key in Key Vault (`github-app-private-key`, the same key the runners
use), count `status=queued` jobs whose labels are a **superset** of
`RUNNER_MATCH_LABELS`, and `POST` the count to
`https://<region>.monitoring.azure.com<vmss-id>/metrics` using the Function's
managed identity.

## Deploy

1. **Terraform** - set in `terraform.tfvars` and apply:
   ```hcl
   enable_queue_metric_function = true
   github_app_id                = "4736345"
   runner_match_labels          = "self-hosted,vmss"
   github_webhook_secret        = "<a long random string>"   # or leave "" for timer-only
   ```
   This creates the Function App, its plan + storage, and grants its identity
   `Monitoring Metrics Publisher` on the VMSS and `Key Vault Secrets User` on
   the vault.

2. **Repo variable** - point the deploy workflow at the app:
   ```bash
   gh variable set QUEUE_METRIC_FUNCTION_NAME --repo <owner>/<repo> \
     --body "$(terraform -chdir=github-runner-vmss/terraform output -raw queue_metric_function_name)"
   ```

3. **Commit `package-lock.json`** - the deploy workflow runs `npm ci`, which
   needs the lockfile checked in next to `package.json`. It already is; if you
   ever change `package.json`, regenerate and commit it:
   ```bash
   cd github-runner-vmss/queue-metric-function
   npm install --package-lock-only
   git add package.json package-lock.json
   ```

4. **Deploy the code** - push a change under `queue-metric-function/**`, or run
   the **Deploy Queue-Metric Function** workflow manually.

5. **Webhook** (optional but recommended) - on the GitHub **org** (or repo)
   -> Settings -> Webhooks -> Add webhook:
   - Payload URL: `terraform output -raw queue_metric_function_webhook_url` + `?code=<function key>`
     (`az functionapp function keys list -g <rg> -n <app> --function-name workflowJobWebhook`)
   - Content type: `application/json`
   - Secret: same value as `github_webhook_secret`
   - Events: **Workflow jobs** only

## Local run

```bash
cp local.settings.json.example local.settings.json   # fill in real values
npm install
npm start           # needs Azure Functions Core Tools v4 + `az login`
```

`DefaultAzureCredential` uses your `az login` for the Key Vault read and the
metric POST locally; in Azure it uses the Function's managed identity.

## App settings

| Setting | Notes |
|---|---|
| `GITHUB_APP_ID` | numeric App ID |
| `KEY_VAULT_URI` | e.g. `https://kv-ghrunner-25818.vault.azure.net/` |
| `GITHUB_APP_KEY_SECRET_NAME` | default `github-app-private-key` |
| `RUNNER_SCOPE` | `org` or `repo` |
| `GITHUB_OWNER` | org or user login |
| `GITHUB_REPO` | `owner/repo`, required when `RUNNER_SCOPE=repo` |
| `RUNNER_MATCH_LABELS` | e.g. `self-hosted,vmss` |
| `VMSS_RESOURCE_ID` / `VMSS_REGION` | the target scale set |
| `METRIC_NAMESPACE` / `METRIC_NAME` | must match `custom_metric_*` in `terraform.tfvars` |
| `GITHUB_WEBHOOK_SECRET` | empty => webhook disabled, timer still runs |

## Cost

Consumption (Y1): 1M executions + 400k GB-s free per month. A `workflow_job`
webhook plus a 3-min timer stays inside the free grant - effectively $0 plus
a few cents of storage.
