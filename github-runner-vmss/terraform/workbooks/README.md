# Runner fleet operations dashboard (Azure Monitor Workbook)

`runner-fleet-workbook.json` is a serialized Azure Monitor Workbook deployed
by `../monitoring-workbook.tf` as `azurerm_application_insights_workbook.runner_fleet`.
It is the single pane of glass for running the self-hosted GitHub Actions
runner fleet (VMSS backend).

## Where to find it

Azure portal → **Monitor** → **Workbooks** → *GitHub Actions runner fleet - &lt;env&gt;*,
or the fleet's **Log Analytics workspace** → **Workbooks**. The Terraform
output `monitoring_workbook_id` is the resource ID.

## Prerequisites

| Requirement | Set by |
|---|---|
| `compute_backend = "vmss"` | `terraform.tfvars` |
| `enable_vmss_monitoring = true` (Azure Monitor Agent + DCR + Log Analytics) | default |
| `enable_monitoring_workbook = true` | default |
| `enable_autoscale_diagnostics = true` (for the autoscale grids) | default |

No resource IDs are baked into the workbook. The **Workspace** and **Scale set**
parameters discover the fleet at open time via Azure Resource Graph on the
`workload = github-actions-self-hosted-runner` tag, so a scale-set replacement
(new random suffix) does not break the saved dashboard.

## Parameters

- **Time range** – applies to every chart (KPI tiles are fixed to 24 h / 3 d by design).
- **Log Analytics workspace** / **Scale set** – auto-selected from the tag; change only if you run more than one fleet.
- **Disk warn % / Disk critical % / CPU critical %** – colour thresholds in the grids; also the defaults the opt-in alert rules use.

## Tabs

| Tab | Data source | Key views |
|---|---|---|
| **Fleet overview** | `Heartbeat`, `Perf`, `Syslog` | KPI tiles (runners online, bootstrap failures 24 h, disk mounts over warn, OS errors 24 h); runner count over time; per-runner state grid with CPU / mem / disk and threshold colouring |
| **Compute health** | `Perf` (AMA, 60 s) | CPU %, memory used % and available MB, disk used % per mount, disk throughput, network throughput; **low-disk grid** listing every mount at/over the warn threshold with Warning/Critical severity |
| **Capacity & autoscale** | Scale set metrics + `AutoscaleScaleActionsLog` / `AutoscaleEvaluationsLog` | Queued-jobs autoscale metric, platform CPU, runner count over time, autoscale **scale actions** and **evaluations** (needs `enable_autoscale_diagnostics`) |
| **Provisioning & bootstrap** | `Syslog` facility `local0`, `Heartbeat`, `AzureActivity` | Bootstrap outcome per instance (Completed / Failed / In progress); instances **stuck in provisioning** (heartbeat but no `Bootstrap complete`); bootstrap error lines; full `local0` log; control-plane failures |
| **Logs & errors** | `Syslog` (OS facilities, Warning+) | Warning+ volume by facility, top error sources, **OOM-killer events**, authentication failures, raw syslog explorer |
| **Queue-metric function** | workspace-based App Insights (`AppRequests` / `AppExceptions` / `AppTraces`) | Invocation success vs failure, exceptions, metric-publish and cleanup traces. Empty unless `enable_queue_metric_function = true` |
| **Alerts** | Azure Resource Graph (`alertsmanagementresources`) | Alerts fired against the fleet in the last 24 h, plus a **recommended alert-rule** table |

## Filtered noise

The **Queue-metric function → Function exceptions** grid deliberately drops rows
where `ProblemId` has `ThrowIfExitError`, or `OuterMessage` has
`node exited with code 143` or `request stream was aborted`.

These are not application errors. On Flex Consumption the Functions host sends
the Node language worker `SIGTERM` (exit `143` = `128 + 15`) every time the
platform recycles or scales an idle instance to zero between the 3-minute timer
ticks - many times an hour, by design. The gRPC `request stream was aborted`
line is the same event seen from the host↔worker channel. A genuine code fault
exits `1` (unhandled rejection) or `137` (`SIGKILL` / OOM), and would also show
up as a failed invocation. Judge function health from the **invocation
success/failure** chart, not from these lifecycle exceptions.

## Editing

Edit the workbook in the portal, then **Advanced Editor → Template Type: Gallery
Template**, and paste the JSON back into `runner-fleet-workbook.json`. Keep the
`${...}` placeholders (`computer_prefix`, `disk_warn`, `disk_crit`, `cpu_crit`,
`mem_low_mb`, `custom_metric_namespace`, `custom_metric_name`,
`queue_fn_role_prefix`, `workload_tag`) intact – `templatefile()` substitutes
them at apply time.

## Alert rules

The **Alerts** tab documents seven recommended rules. Four are provisioned by
`../monitor-alerts.tf` when `enable_monitoring_alerts = true` and
`monitoring_alert_email` is set: low disk space, low memory, bootstrap failure,
high CPU – all wired to an email action group. The remaining three
(heartbeat-lost, autoscale-action-failed, provisioning-failed) are left as
copy-paste guidance.
