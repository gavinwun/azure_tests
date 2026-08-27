#####################################################################
# ACI backend - alternative to VMSS, gated by var.compute_backend == "aci"
#
# ACI has no autoscale primitive of its own and no scale-set concept -
# each container group is a single deployable unit. Scaling is handled
# entirely by reconcile-aci-runners.yml, which directly creates/deletes
# container groups to track queued job count (see that workflow for the
# actual scaling logic; this file only provisions the static infra it
# depends on).
#
# Unlike the VMSS backend, there's no bootstrap-script blob or SSH key
# here - the runner image (docker/Dockerfile) already has everything
# baked in, and the container's entrypoint does the GitHub registration
# at startup instead of a boot-time CustomScript extension.
#####################################################################

resource "azurerm_container_registry" "acr" {
  count = var.compute_backend == "aci" ? 1 : 0

  name                = local.acr_name
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  location            = data.azurerm_resource_group.mgmt_devops.location
  sku                 = "Standard"

  # Public network access enabled deliberately - the image-build workflow
  # runs on a GitHub-hosted runner with no path into the VNet, same
  # reasoning as the queue-poller storage account trade-off earlier.
  # Auth is AAD/RBAC only (admin_enabled = false) - no shared credential.
  public_network_access_enabled = true
  admin_enabled                 = false

  tags = local.tags
}

# -------------------------------------------------------------------
# Dedicated subnet for ACI, delegated to Microsoft.ContainerInstance.
# ACI-delegated subnets can only contain container groups - nothing
# else can share it (this is an Azure platform requirement, not a
# Terraform choice). Distinct from the VMSS's devopsagent subnet.
# -------------------------------------------------------------------
resource "azurerm_subnet" "aci" {
  count = var.compute_backend == "aci" ? 1 : 0

  name                 = "snet-ghrunner-aci"
  resource_group_name  = var.vnet_resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.aci_subnet_address_prefix]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# -------------------------------------------------------------------
# User-assigned identity for container groups. ACI does NOT support
# system-assigned identity for ACR image pulls - user-assigned is
# required regardless of OS. Also used to fetch the GitHub App token
# from Key Vault at container startup, same pattern as the VMSS
# managed identity.
# -------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aci_runner" {
  count = var.compute_backend == "aci" ? 1 : 0

  name                = "uai-ghrunner-aci-${local.name_suffix}"
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aci_acr_pull" {
  count = var.compute_backend == "aci" ? 1 : 0

  scope                = azurerm_container_registry.acr[0].id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.aci_runner[0].principal_id
}

resource "azurerm_role_assignment" "aci_kv_secrets_user" {
  count = var.compute_backend == "aci" ? 1 : 0

  scope                = data.azurerm_key_vault.mgmt_devops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aci_runner[0].principal_id
}
