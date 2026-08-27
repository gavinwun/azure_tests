#####################################################################
# RBAC for the hub-network resource group
#####################################################################
# Only relevant when var.manage_network is false (the default) - i.e.
# you're pointing at a hub network that already exists, usually in a
# separate resource group (rg-network-hub in terraform.tfvars) from the
# one this module deploys into (var.resource_group_name). The identity
# running Terraform needs its own access there - it's not covered by
# the Contributor / RBAC Administrator grants scoped to
# var.resource_group_name (see README step 7.3).
#
# When var.manage_network is true, none of this is needed: network.tf
# creates the hub resource group itself, which already requires the
# deploy identity to have Contributor scoped there (see README's
# manage_network note) - a superset of everything these three roles
# exist to grant.
#
# IMPORTANT - bootstrap chicken-and-egg: the very first `terraform plan`
# on a fresh deploy identity still needs a ONE-TIME MANUAL grant of at
# least "Reader" on the hub resource group before it can even read the
# data sources in data.tf, since Terraform evaluates data sources before
# any resource in this file exists to grant that access. See README step
# 7.3 for that one-off `az role assignment create` command. Once that
# exists, the resources below take over - if the deploy identity is ever
# recreated (not just re-authenticated), the manual step must be
# repeated once for the new identity, same category as the tfstate
# storage account bootstrap in step 7.1.

data "azurerm_resource_group" "network_hub" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  name = var.vnet_resource_group_name
}

# Covers the data "azurerm_subnet" x2 and general read access data.tf
# needs against the hub resource group.
resource "azurerm_role_assignment" "pipeline_network_hub_reader" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  scope                = data.azurerm_resource_group.network_hub[0].id
  role_definition_name = "Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Needed for the private endpoint's subnet attach
# (Microsoft.Network/virtualNetworks/subnets/join/action) - used both by
# azurerm_private_endpoint.bootstrap_blob (attaches into the pep subnet)
# and azurerm_linux_virtual_machine_scale_set.vmss (attaches into the
# devopsagent subnet), both in main.tf.
resource "azurerm_role_assignment" "pipeline_network_hub_contributor" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  scope                = data.azurerm_resource_group.network_hub[0].id
  role_definition_name = "Network Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Needed for the private endpoint's DNS zone group
# (Microsoft.Network/privateDnsZones/join/action) - "Network Contributor"
# above does NOT cover this; it's a distinct built-in role scoped here to
# just the DNS zone itself rather than the whole resource group, since
# that's the narrowest scope that covers what main.tf actually needs.
resource "azurerm_role_assignment" "pipeline_private_dns_zone_contributor" {
  count = var.compute_backend == "vmss" && !var.manage_network ? 1 : 0

  scope                = data.azurerm_private_dns_zone.blob[0].id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
