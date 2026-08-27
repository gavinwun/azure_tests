data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "mgmt_devops" {
  name = var.resource_group_name
}

# Shared by both backends - VMSS's script/SSH-key fetch and ACI's
# managed-identity Key Vault fetch both use this vault.
data "azurerm_key_vault" "mgmt_devops" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group_name
}

#########################
# VMSS-only data sources
#########################

data "azurerm_subnet" "devopsagent" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                 = var.devopsagent_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

data "azurerm_subnet" "pep" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                 = var.pep_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

data "azurerm_private_dns_zone" "blob" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                = var.blob_private_dns_zone_name
  resource_group_name = var.blob_private_dns_zone_resource_group_name
}

# The VMSS admin SSH public key - store this secret in Key Vault yourself
# before running terraform apply (see README). Terraform only reads the
# public key; it never touches the private key. Not used by the ACI
# backend, which has no SSH access at all.
data "azurerm_key_vault_secret" "vmss_ssh_public_key" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name         = "vmss-ssh-public-key"
  key_vault_id = data.azurerm_key_vault.mgmt_devops.id
}
