#####################################################################
# Queue-depth metric Function App - vmss backend, opt-in.
#
# Replaces / backs up poll-queue-depth.yml. A Flex Consumption Function
# (scale-to-zero, pay-per-use) that:
#   * on a GitHub `workflow_job` webhook for a matching job, and
#   * on a 3-minute timer (heartbeat / self-heal),
# counts QUEUED jobs whose runs-on labels match runner_match_labels and
# POSTs the count as the QueuedJobs custom metric on the VMSS - the same
# signal custom-metric-autoscale.tf reads.
#
# Flex Consumption (not Linux Consumption, retiring 2028) + Node 22.
# Code lives in ../queue-metric-function; deploy it with
# .github/workflows/deploy-queue-metric-function.yml after `terraform apply`.
#####################################################################

locals {
  queue_fn_enabled = var.compute_backend == "vmss" && var.enable_queue_metric_function

  queue_fn_name         = "func-ghrunner-queue-${local.name_suffix}"
  queue_fn_plan_name    = "plan-ghrunner-queue-${local.name_suffix}"
  queue_fn_storage_name = substr(lower(replace("stqfn${random_string.suffix.result}", "-", "")), 0, 24)

  # Application Insights for the Function's invocation logs / traces. Reuse
  # the monitoring workspace when enable_vmss_monitoring created / referenced
  # one; otherwise stand up a small dedicated workspace.
  queue_fn_own_workspace = local.queue_fn_enabled && local.effective_log_analytics_workspace_id == null
  queue_fn_workspace_id = (
    local.effective_log_analytics_workspace_id != null
    ? local.effective_log_analytics_workspace_id
    : one(azurerm_log_analytics_workspace.queue_fn[*].id)
  )
}

resource "azurerm_log_analytics_workspace" "queue_fn" {
  count = local.queue_fn_own_workspace ? 1 : 0

  name                = "log-ghrunner-queue-${local.name_suffix}"
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "queue_fn" {
  count = local.queue_fn_enabled ? 1 : 0

  name                = "appi-ghrunner-queue-${local.name_suffix}"
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  workspace_id        = local.queue_fn_workspace_id
  application_type    = "Node.JS"
  tags                = local.tags
}

resource "azurerm_service_plan" "queue_fn" {
  count = local.queue_fn_enabled ? 1 : 0

  name                = local.queue_fn_plan_name
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = local.tags
}

resource "azurerm_storage_account" "queue_fn" {
  count = local.queue_fn_enabled ? 1 : 0

  name                            = local.queue_fn_storage_name
  resource_group_name             = data.azurerm_resource_group.mgmt_devops.name
  location                        = data.azurerm_resource_group.mgmt_devops.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

# Flex Consumption deploys the app package into a blob container rather
# than the RUN_FROM_PACKAGE app setting used on the old plan.
resource "azurerm_storage_container" "queue_fn_deploy" {
  count = local.queue_fn_enabled ? 1 : 0

  name                  = "deployments"
  storage_account_id    = azurerm_storage_account.queue_fn[0].id
  container_access_type = "private"
}

resource "azurerm_function_app_flex_consumption" "queue_fn" {
  count = local.queue_fn_enabled ? 1 : 0

  name                = local.queue_fn_name
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  service_plan_id     = azurerm_service_plan.queue_fn[0].id
  tags                = local.tags

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.queue_fn[0].primary_blob_endpoint}${azurerm_storage_container.queue_fn_deploy[0].name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.queue_fn[0].primary_access_key

  runtime_name    = "node"
  runtime_version = "22"

  # Smallest footprint - this is a webhook + a 3-min timer. No always-ready
  # instances => scales to zero when idle.
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048

  identity {
    type = "SystemAssigned"
  }

  site_config {
    # Wires up APPLICATIONINSIGHTS_CONNECTION_STRING so the Functions host
    # ships invocation logs / traces to App Insights (and the workspace).
    application_insights_connection_string = azurerm_application_insights.queue_fn[0].connection_string
  }

  app_settings = {
    GITHUB_APP_ID              = var.github_app_id
    KEY_VAULT_URI              = data.azurerm_key_vault.mgmt_devops.vault_uri
    GITHUB_APP_KEY_SECRET_NAME = "github-app-private-key"

    RUNNER_SCOPE        = var.github_runner_scope
    GITHUB_OWNER        = var.github_org
    GITHUB_REPO         = var.github_repo
    RUNNER_MATCH_LABELS = var.runner_match_labels

    VMSS_RESOURCE_ID = azurerm_linux_virtual_machine_scale_set.vmss[0].id
    VMSS_REGION      = data.azurerm_resource_group.mgmt_devops.location
    METRIC_NAMESPACE = var.custom_metric_namespace
    METRIC_NAME      = var.custom_metric_name

    # Empty => webhook endpoint refuses calls, timer still publishes.
    # Set it here (or in the portal) to the same value as the GitHub webhook.
    GITHUB_WEBHOOK_SECRET = var.github_webhook_secret
  }
}

# --- Function identity: publish the metric, read the App private key ---
resource "azurerm_role_assignment" "queue_fn_metrics_publisher" {
  count = local.queue_fn_enabled ? 1 : 0

  scope                = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_function_app_flex_consumption.queue_fn[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "queue_fn_kv_secrets_user" {
  count = local.queue_fn_enabled ? 1 : 0

  scope                = data.azurerm_key_vault.mgmt_devops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_function_app_flex_consumption.queue_fn[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Reader on the VMSS so the hourly cleanup timer can list live instances and
# tell an orphaned offline runner from one that's merely rebooting.
resource "azurerm_role_assignment" "queue_fn_vmss_reader" {
  count = local.queue_fn_enabled ? 1 : 0

  scope                = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  role_definition_name = "Reader"
  principal_id         = azurerm_function_app_flex_consumption.queue_fn[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
