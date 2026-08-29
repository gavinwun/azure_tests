#####################################################################
# Recommended SRE alert rules for the runner fleet - opt-in.
#
# Off by default (enable_monitoring_alerts = false) because a real alert
# rule needs somewhere to send: set enable_monitoring_alerts = true and
# monitoring_alert_email = "you@example.com" to provision an email
# action group plus the four rules below.
#
#   * low disk space     (scheduled query, per Computer)
#   * low memory         (scheduled query, per Computer)
#   * bootstrap failure  (scheduled query on syslog local0)
#   * high CPU           (metric alert on the scale set)
#
# The workbook's "Alerts" tab lists a couple more (heartbeat-lost,
# autoscale-action-failed, provisioning-failed) that are left as
# copy-paste guidance rather than provisioned here - heartbeat-lost is
# inherently noisy for a scale-to-zero fleet, and the other two want an
# Activity Log alert wired to your own action group.
#####################################################################

locals {
  monitoring_alerts_enabled = local.vmss_monitoring_enabled && var.enable_monitoring_alerts
}

resource "azurerm_monitor_action_group" "runner_ops" {
  count = local.monitoring_alerts_enabled ? 1 : 0

  name                = "ag-ghrunner-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  short_name          = "ghrunnerops"
  tags                = local.tags

  email_receiver {
    name          = "ops-email"
    email_address = var.monitoring_alert_email
  }

  lifecycle {
    precondition {
      condition     = var.monitoring_alert_email != ""
      error_message = "Set monitoring_alert_email when enable_monitoring_alerts = true."
    }
  }
}

# --- Low disk space -------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "low_disk" {
  count = local.monitoring_alerts_enabled ? 1 : 0

  name                = "alert-ghrunner-low-disk-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  description         = "A runner's disk is at or over ${var.workbook_disk_critical_percent}% used."
  severity            = 2

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  scopes               = [local.effective_log_analytics_workspace_id]

  criteria {
    query = <<-QUERY
      Perf
      | where ObjectName == "Logical Disk" and CounterName == "% Used Space"
      | where Computer startswith "${local.vmss_computer_name_prefix}"
      | where InstanceName !startswith "/snap" and InstanceName !in ("_Total", "/boot/efi")
      | summarize AggregatedValue = max(CounterValue) by Computer, bin(TimeGenerated, 5m)
    QUERY

    time_aggregation_method = "Maximum"
    metric_measure_column   = "AggregatedValue"
    operator                = "GreaterThanOrEqual"
    threshold               = var.workbook_disk_critical_percent

    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.runner_ops[0].id]
  }
  tags = local.tags
}

# --- Low memory ---------------------------------------------------------
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "low_memory" {
  count = local.monitoring_alerts_enabled ? 1 : 0

  name                = "alert-ghrunner-low-memory-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  description         = "A runner has less than ${var.workbook_memory_low_mb} MB memory available."
  severity            = 3

  evaluation_frequency = "PT5M"
  window_duration      = "PT15M"
  scopes               = [local.effective_log_analytics_workspace_id]

  criteria {
    query = <<-QUERY
      Perf
      | where ObjectName == "Memory" and CounterName == "Available MBytes"
      | where Computer startswith "${local.vmss_computer_name_prefix}"
      | summarize AggregatedValue = min(CounterValue) by Computer, bin(TimeGenerated, 5m)
    QUERY

    time_aggregation_method = "Minimum"
    metric_measure_column   = "AggregatedValue"
    operator                = "LessThan"
    threshold               = var.workbook_memory_low_mb

    dimension {
      name     = "Computer"
      operator = "Include"
      values   = ["*"]
    }

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.runner_ops[0].id]
  }
  tags = local.tags
}

# --- Bootstrap failure ------------------------------------------------------
# bootstrap_agent.sh logs to syslog facility local0 (tag ghrunner-bootstrap).
# An ERROR/FATAL line there means an instance failed to become a usable runner.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "bootstrap_failure" {
  count = local.monitoring_alerts_enabled ? 1 : 0

  name                = "alert-ghrunner-bootstrap-failure-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  description         = "A runner instance logged a bootstrap error (facility local0)."
  severity            = 1

  evaluation_frequency = "PT5M"
  window_duration      = "PT10M"
  scopes               = [local.effective_log_analytics_workspace_id]

  criteria {
    query = <<-QUERY
      Syslog
      | where Facility == "local0"
      | where Computer startswith "${local.vmss_computer_name_prefix}"
      | where SyslogMessage has_cs "ERROR" or SyslogMessage has_cs "FATAL" or SyslogMessage has "still failing after"
    QUERY

    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.runner_ops[0].id]
  }
  tags = local.tags
}

# --- High CPU (metric alert on the scale set) ----------------------------
resource "azurerm_monitor_metric_alert" "high_cpu" {
  count = local.monitoring_alerts_enabled ? 1 : 0

  name                = "alert-ghrunner-high-cpu-${local.name_suffix}"
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  scopes              = [azurerm_linux_virtual_machine_scale_set.vmss[0].id]
  description         = "Scale set average CPU above ${var.workbook_cpu_critical_percent}% for 15 minutes."
  severity            = 3

  frequency   = "PT5M"
  window_size = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = var.workbook_cpu_critical_percent
  }

  action {
    action_group_id = azurerm_monitor_action_group.runner_ops[0].id
  }
  tags = local.tags
}
