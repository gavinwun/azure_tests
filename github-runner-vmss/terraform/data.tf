data "azurerm_client_config" "current" {}

# Subscription is the scope Azure Marketplace agreements and the RBAC to
# accept them live at (marketplace-rbac.tf). This is the ONLY place this
# module reaches subscription scope, and it's only acted on when
# var.manage_marketplace_agreement is true.
data "azurerm_subscription" "current" {}

data "azurerm_resource_group" "mgmt_devops" {
  name = var.resource_group_name
}

# The hub-network resource group - referenced, never created, in BOTH
# manage_network modes: when false, network-rbac.tf scopes its grants
# here and data.tf's subnet/DNS lookups live in it; when true, network.tf
# creates the VNet/subnets/DNS zone inside it. Keeping the RG itself out
# of Terraform's state means the deploy identity only ever needs a role
# scoped to this one RG (never the subscription), and `terraform destroy`
# can't take a shared or client-owned network RG with it. Pre-create it
# and grant the deploy identity Contributor on it - see README step 7.3.
data "azurerm_resource_group" "network_hub" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name = var.vnet_resource_group_name
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
# Only used when var.manage_network is false (the default) - these
# look up an existing hub network. When manage_network = true,
# network.tf creates equivalent resources instead; see the
# local.devopsagent_subnet_id / local.pep_subnet_id /
# local.blob_private_dns_zone_id locals in network.tf, which main.tf
# and network-rbac.tf reference instead of these directly.

data "azurerm_subnet" "devopsagent" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  name                 = var.devopsagent_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

data "azurerm_subnet" "pep" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  name                 = var.pep_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_resource_group_name
}

data "azurerm_private_dns_zone" "blob" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

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
