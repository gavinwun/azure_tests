#####################################################################
# Azure Monitor Agent (AMA) for the VMSS runner fleet - vmss backend only.
#
# Deliberately uses the modern data-collection stack:
#   * AzureMonitorLinuxAgent VM extension (NOT OmsAgentForLinux / the
#     "Log Analytics agent" / MMA, which Microsoft retired on 2024-08-31)
#   * a Data Collection Rule (DCR) + DCR association that declares what
#     each instance sends and where
#
# What's collected from every instance:
#   * Syslog  - OS facilities at Warning+, plus everything the bootstrap
#               script emits (it logs to facility local0 at Info+, so a
#               failed bootstrap is visible in Log Analytics without SSH)
#   * Perf    - CPU / memory / disk / network counters
#
# The ACI backend has no VM-extension surface, so none of this applies
# there - hence the `local.vmss_monitoring_enabled` gate on everything.
#####################################################################

locals {
  vmss_monitoring_enabled = var.compute_backend == "vmss" && var.enable_vmss_monitoring

  # Create a workspace only when the caller didn't hand us an existing one.
  create_log_analytics_workspace = local.vmss_monitoring_enabled && var.log_analytics_workspace_id == ""

  effective_log_analytics_workspace_id = (
    var.log_analytics_workspace_id != ""
    ? var.log_analytics_workspace_id
    : (local.create_log_analytics_workspace ? azurerm_log_analytics_workspace.runners[0].id : null)
  )

  # Linux perf counters AMA understands. Wildcards expand per-disk /
  # per-interface at ingestion time.
  vmss_perf_counters = [
    "\\Processor(_Total)\\% Processor Time",
    "\\Memory\\Available MBytes",
    "\\Memory\\% Used Memory",
    "\\Logical Disk(*)\\% Used Space",
    "\\Logical Disk(*)\\Disk Read Bytes/sec",
    "\\Logical Disk(*)\\Disk Write Bytes/sec",
    "\\Network(*)\\Total Bytes Received",
    "\\Network(*)\\Total Bytes Transmitted",
  ]
}

# --- Log Analytics workspace (only when no existing one is supplied) ---
resource "azurerm_log_analytics_workspace" "runners" {
  count = local.create_log_analytics_workspace ? 1 : 0

  name                = local.log_analytics_workspace_name
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_analytics_retention_days
  tags                = local.tags
}

# --- Data Collection Rule: what each instance sends, and where ---
resource "azurerm_monitor_data_collection_rule" "vmss" {
  count = local.vmss_monitoring_enabled ? 1 : 0

  name                = local.vmss_dcr_name
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "toLogAnalytics"
      workspace_resource_id = local.effective_log_analytics_workspace_id
    }
  }

  data_sources {
    # Bootstrap script output - facility local0, everything Info and up.
    syslog {
      name           = "bootstrap"
      streams        = ["Microsoft-Syslog"]
      facility_names = [local.bootstrap_syslog_facility]
      log_levels     = ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
    }

    # OS syslog - the usual facilities, Warning and up to keep volume sane.
    syslog {
      name           = "system"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["auth", "authpriv", "cron", "daemon", "kern", "syslog", "user"]
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]
    }

    performance_counter {
      name                          = "perf"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = var.vmss_perf_counter_sampling_seconds
      counter_specifiers            = local.vmss_perf_counters
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["toLogAnalytics"]
  }

  data_flow {
    streams      = ["Microsoft-Perf"]
    destinations = ["toLogAnalytics"]
  }
}

# --- Bind the DCR to the scale set ---
resource "azurerm_monitor_data_collection_rule_association" "vmss" {
  count = local.vmss_monitoring_enabled ? 1 : 0

  name                    = "dcra-${local.vmss_name}"
  target_resource_id      = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.vmss[0].id
}

# --- The agent itself ---
# Authenticates as the VMSS's existing user-assigned identity (the same
# one used for Key Vault / storage). No workspace key, no system-assigned
# identity. Ingestion auth for the built-in Syslog/Perf streams is granted
# by the DCR association above - no extra role assignment needed.
resource "azurerm_virtual_machine_scale_set_extension" "ama" {
  count = local.vmss_monitoring_enabled ? 1 : 0

  name                         = "AzureMonitorLinuxAgent"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  publisher                    = "Microsoft.Azure.Monitor"
  type                         = "AzureMonitorLinuxAgent"
  type_handler_version         = "1.33"
  auto_upgrade_minor_version   = true
  automatic_upgrade_enabled    = true

  # AMA has no predecessor - it goes first. Set explicitly to [] rather
  # than omitted: an earlier revision had this pointing at DevOpsBootstrap,
  # and just deleting the argument leaves that stale value on the Azure
  # model, which then forms a circular dependency once DevOpsBootstrap
  # gains provision_after_extensions = ["AzureMonitorLinuxAgent"]. An
  # explicit [] forces the provider to send an empty array and clear it.
  provision_after_extensions = []

  # AMA provisions FIRST - before DevOpsBootstrap, which carries
  # provision_after_extensions = ["AzureMonitorLinuxAgent"] (see main.tf).
  # Once AMA + the DCR are up, the runner bootstrap that runs next is
  # observable in Log Analytics (facility local0) while it happens.
  #
  # false = fail hard. This flag does NOT control ordering/waiting
  # (provision_after_extensions does) - it only decides whether a failure
  # is fatal. With false, an AMA failure fails the instance operation AND
  # blocks DevOpsBootstrap ("depends upon the VM Extension ... which has
  # failed"), so a broken monitoring setup means no runner - deliberate:
  # AMA rarely fails, and if it does we want to know, not ship blind.
  failure_suppression_enabled = false

  settings = jsonencode({
    authentication = {
      managedIdentity = {
        "identifier-name"  = "mi_res_id"
        "identifier-value" = azurerm_user_assigned_identity.agent_id[0].id
      }
    }
  })

  # DCR association carries the collection config AMA reads on start.
  depends_on = [
    azurerm_monitor_data_collection_rule_association.vmss,
  ]
}
