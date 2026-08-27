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

output "vmss_location" {
  value       = data.azurerm_resource_group.mgmt_devops.location
  description = "Feed into poll-queue-depth.yml's VMSS_REGION variable - custom metrics must be posted to this region's Azure Monitor endpoint."
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
