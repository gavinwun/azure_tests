output "compute_backend" {
  value = var.compute_backend
}

#########################
# VMSS backend outputs
#########################

output "vmss_id" {
  value = var.compute_backend == "vmss" ? azurerm_linux_virtual_machine_scale_set.vmss[0].id : null
}

output "vmss_managed_identity_client_id" {
  value       = var.compute_backend == "vmss" ? azurerm_user_assigned_identity.agent_id[0].client_id : null
  description = "Grant this identity access in Key Vault / Storage if extending permissions later."
}

output "vmss_managed_identity_principal_id" {
  value = var.compute_backend == "vmss" ? azurerm_user_assigned_identity.agent_id[0].principal_id : null
}

output "bootstrap_storage_account_name" {
  value = var.compute_backend == "vmss" ? azurerm_storage_account.bootstrap[0].name : null
}

output "bootstrap_storage_resource_group_name" {
  value       = var.compute_backend == "vmss" ? azurerm_storage_account.bootstrap[0].resource_group_name : null
  description = "Used by terraform-deploy.yml's safety-net step to re-lock the storage public endpoint if an apply fails partway."
}

output "vmss_location" {
  value       = data.azurerm_resource_group.mgmt_devops.location
  description = "Feed into poll-queue-depth.yml's VMSS_REGION variable - custom metrics must be posted to this region's Azure Monitor endpoint."
}

output "log_analytics_workspace_id" {
  value       = local.effective_log_analytics_workspace_id
  description = "Workspace AMA ships syslog/perf to - the one Terraform created, or the existing one passed via log_analytics_workspace_id. Null when enable_vmss_monitoring = false."
}

output "vmss_data_collection_rule_id" {
  value       = local.vmss_monitoring_enabled ? azurerm_monitor_data_collection_rule.vmss[0].id : null
  description = "The DCR bound to the scale set. Query bootstrap output in the workspace with: Syslog | where Facility == \"local0\""
}

output "queue_metric_function_name" {
  value       = local.queue_fn_enabled ? azurerm_function_app_flex_consumption.queue_fn[0].name : null
  description = "Deploy target for .github/workflows/deploy-queue-metric-function.yml."
}

output "queue_metric_function_webhook_url" {
  value       = local.queue_fn_enabled ? "https://${azurerm_function_app_flex_consumption.queue_fn[0].default_hostname}/api/workflow-job-webhook" : null
  description = "GitHub webhook Payload URL - append ?code=<function key> (Function App -> Functions -> workflowJobWebhook -> Function Keys, or `az functionapp function keys list`)."
}

#########################
# ACI backend outputs
#########################

output "acr_login_server" {
  value = var.compute_backend == "aci" ? azurerm_container_registry.acr[0].login_server : null
}

output "acr_name" {
  value = var.compute_backend == "aci" ? azurerm_container_registry.acr[0].name : null
}

output "aci_subnet_name" {
  value       = var.compute_backend == "aci" ? azurerm_subnet.aci[0].name : null
  description = "Pass to `az container create --subnet` in reconcile-aci-runners.yml."
}

output "aci_vnet_id" {
  value       = var.compute_backend == "aci" ? "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.vnet_resource_group_name}/providers/Microsoft.Network/virtualNetworks/${var.vnet_name}" : null
  description = "Pass to `az container create --vnet` in reconcile-aci-runners.yml."
}

output "aci_identity_id" {
  value       = var.compute_backend == "aci" ? azurerm_user_assigned_identity.aci_runner[0].id : null
  description = "Pass to `az container create --assign-identity --acr-identity` in reconcile-aci-runners.yml."
}
