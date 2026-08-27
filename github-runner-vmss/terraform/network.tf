#####################################################################
# Optional: let Terraform create the hub network itself
#####################################################################
# Everything below is gated by var.manage_network (default false, so
# existing deployments pointing at a real landing-zone VNet see no
# change in behaviour). Set manage_network = true in terraform.tfvars
# to have this module create rg-network-hub / vnet-hub / the two
# subnets / the private DNS zone itself instead of assuming they
# already exist - useful for a from-scratch environment, a demo, or a
# throwaway test deployment. On a real landing zone, leave this false
# and keep data.tf pointing at your platform team's actual network.
#
# The *_name variables (vnet_name, devopsagent_subnet_name, etc.) are
# reused either way - when manage_network = true they're the names
# Terraform assigns to what it creates, rather than names it looks up.

resource "azurerm_resource_group" "network_hub_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name     = var.vnet_resource_group_name
  location = data.azurerm_resource_group.mgmt_devops.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "hub_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name                = var.vnet_name
  resource_group_name = azurerm_resource_group.network_hub_managed[0].name
  location            = azurerm_resource_group.network_hub_managed[0].location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "devopsagent_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name                 = var.devopsagent_subnet_name
  resource_group_name  = azurerm_resource_group.network_hub_managed[0].name
  virtual_network_name = azurerm_virtual_network.hub_managed[0].name
  address_prefixes     = [var.devopsagent_subnet_address_prefix]
}

resource "azurerm_subnet" "pep_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name                 = var.pep_subnet_name
  resource_group_name  = azurerm_resource_group.network_hub_managed[0].name
  virtual_network_name = azurerm_virtual_network.hub_managed[0].name
  address_prefixes     = [var.pep_subnet_address_prefix]

  # Private endpoints need network policies disabled on their subnet -
  # Azure blocks them by default otherwise.
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_private_dns_zone" "blob_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name                = var.blob_private_dns_zone_name
  resource_group_name = azurerm_resource_group.network_hub_managed[0].name
  tags                = local.tags
}

# Without this link, the VMSS/private endpoint could still create the DNS
# record, but nothing in the VNet would actually resolve it - the zone
# has to be linked to the VNet for name resolution to work at all.
resource "azurerm_private_dns_zone_virtual_network_link" "blob_managed" {
  count = var.compute_backend == "vmss" && var.manage_network ? 1 : 0

  name                  = "${var.vnet_name}-blob-link"
  resource_group_name   = azurerm_resource_group.network_hub_managed[0].name
  private_dns_zone_name = azurerm_private_dns_zone.blob_managed[0].name
  virtual_network_id    = azurerm_virtual_network.hub_managed[0].id
  registration_enabled  = false
  tags                  = local.tags
}

#####################################################################
# Locals: one reference point regardless of which mode is active
#####################################################################
# main.tf and network-rbac.tf use these instead of reaching into
# azurerm_subnet.devopsagent_managed / data.azurerm_subnet.devopsagent
# directly, so nothing else in the module needs to know or care which
# mode created the network.

locals {
  devopsagent_subnet_id = var.compute_backend != "vmss" ? null : (
    var.manage_network ? azurerm_subnet.devopsagent_managed[0].id : data.azurerm_subnet.devopsagent[0].id
  )

  pep_subnet_id = var.compute_backend != "vmss" ? null : (
    var.manage_network ? azurerm_subnet.pep_managed[0].id : data.azurerm_subnet.pep[0].id
  )

  blob_private_dns_zone_id = var.compute_backend != "vmss" ? null : (
    var.manage_network ? azurerm_private_dns_zone.blob_managed[0].id : data.azurerm_private_dns_zone.blob[0].id
  )
}
