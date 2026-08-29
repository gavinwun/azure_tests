#####################################################################
# Azure Monitor Workbook - the runner-fleet operations dashboard.
# vmss backend only, and only when monitoring (AMA + Log Analytics)
# is enabled - the workbook has nothing to query otherwise.
#
# The workbook body lives in workbooks/runner-fleet-workbook.json as a
# serialized "Notebook/1.0" document; templatefile() injects the few
# environment-specific literals (computer-name prefix, thresholds,
# custom-metric names). Resource IDs are NOT baked in - the workbook's
# Workspace / Scale set parameters discover them at open time via Azure
# Resource Graph on the `workload` tag, so a scale-set replacement (new
# random suffix) doesn't break the saved dashboard.
#####################################################################

locals {
  monitoring_workbook_enabled = local.vmss_monitoring_enabled && var.enable_monitoring_workbook

  # Drives the workbook's tag-based resource discovery. Must match the
  # `workload` tag applied in locals.tf (local.tags).
  workbook_workload_tag = "github-actions-self-hosted-runner"
}

resource "random_uuid" "monitoring_workbook" {
  count = local.monitoring_workbook_enabled ? 1 : 0
}

resource "azurerm_application_insights_workbook" "runner_fleet" {
  count = local.monitoring_workbook_enabled ? 1 : 0

  name                = random_uuid.monitoring_workbook[0].result
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  display_name        = "GitHub Actions runner fleet - ${var.environment}"
  category            = "workbook"

  # Lower-cased per the provider's constraint on source_id. Anchors the
  # workbook to the fleet's Log Analytics workspace, so it also shows up
  # under that workspace's Workbooks gallery in the portal.
  source_id = lower(local.effective_log_analytics_workspace_id)

  # jsonencode(jsondecode(...)) normalises to the provider's canonical
  # form so plan doesn't show a whitespace-only diff on every run.
  data_json = jsonencode(jsondecode(templatefile("${path.module}/workbooks/runner-fleet-workbook.json", {
    computer_prefix         = local.vmss_computer_name_prefix
    workload_tag            = local.workbook_workload_tag
    custom_metric_namespace = var.custom_metric_namespace
    custom_metric_name      = var.custom_metric_name
    queue_fn_role_prefix    = "func-ghrunner-queue"
    disk_warn               = tostring(var.workbook_disk_warn_percent)
    disk_crit               = tostring(var.workbook_disk_critical_percent)
    cpu_crit                = tostring(var.workbook_cpu_critical_percent)
    mem_low_mb              = tostring(var.workbook_memory_low_mb)
  })))

  tags = local.tags
}

#####################################################################
# Autoscale diagnostic logs -> the fleet workspace.
#
# Powers the workbook's "Capacity & autoscale" scale-action and
# evaluation grids. Without this, the autoscale engine's decisions are
# only visible in the portal's Run history blade, not queryable. Scoped
# to this deployment's own autoscale setting - cheap, low volume.
#####################################################################

resource "azurerm_monitor_diagnostic_setting" "autoscale" {
  count = local.monitoring_workbook_enabled && var.enable_autoscale_diagnostics ? 1 : 0

  name                       = "diag-autoscale-${local.vmss_name}"
  target_resource_id         = azurerm_monitor_autoscale_setting.vmss_queue_autoscale[0].id
  log_analytics_workspace_id = local.effective_log_analytics_workspace_id

  # Route to the resource-specific tables (AutoscaleEvaluationsLog /
  # AutoscaleScaleActionsLog) rather than the generic AzureDiagnostics
  # blob - typed columns, and what the workbook's Capacity tab queries.
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AutoscaleEvaluations"
  }

  enabled_log {
    category = "AutoscaleScaleActions"
  }
}
