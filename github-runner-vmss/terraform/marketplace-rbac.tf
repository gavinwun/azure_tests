#####################################################################
# RBAC for accepting the CIS image's Azure Marketplace terms
#####################################################################
# azurerm_marketplace_agreement.cis_ubuntu_2404 (main.tf) accepts the
# paid-Marketplace terms for the CIS Hardened Ubuntu 24.04 image. That
# is a SUBSCRIPTION-level operation under the Microsoft.MarketplaceOrdering
# provider, and the deploy pipeline identity
# (data.azurerm_client_config.current) is otherwise scoped only to this
# module's resource groups - so without a grant it fails during apply:
#
#   Error: retrieving Plan (...): unexpected status 403 (403 Forbidden)
#   AuthorizationFailed: The client '...' with object id '...' does not
#   have authorization to perform action 'Microsoft.MarketplaceOrdering/
#   offerTypes/publishers/offers/plans/agreements/read' over scope
#   '/subscriptions/<sub>/providers/Microsoft.MarketplaceOrdering/...'
#
# There is no narrow built-in role for Microsoft.MarketplaceOrdering
# (only Contributor / Owner cover it, via wildcard), so this defines a
# minimal CUSTOM role - just the MarketplaceOrdering actions - and
# assigns it to the deploy identity at subscription scope.
#
# ---------------------------------------------------------------------
# BOOTSTRAP CHICKEN-AND-EGG (same category as network-rbac.tf /
# keyvault-rbac.tf): creating a custom role definition and a
# subscription-scoped role assignment itself needs the deploy identity
# to hold "Owner" or "User Access Administrator" at the SUBSCRIPTION for
# the apply that first creates them. Grant that once (README step 7.3);
# steady-state applies don't need it again unless the deploy identity is
# recreated.
#
# If you can't / won't give the pipeline identity subscription-scoped
# UAA, set var.manage_marketplace_agreement = false and accept the terms
# out-of-band once:
#   az vm image terms accept \
#     --urn center-for-internet-security-inc:cis-ubuntu:cis-ubuntulinux2404-l1-gen2:latest
# ---------------------------------------------------------------------

locals {
  # main.tf's azurerm_marketplace_agreement is gated on the same
  # expression - keep them in lockstep.
  manage_marketplace_rbac = var.compute_backend == "vmss" && var.manage_marketplace_agreement
}

resource "azurerm_role_definition" "marketplace_ordering" {
  count = local.manage_marketplace_rbac ? 1 : 0

  name        = "Marketplace Ordering Agreements (${var.resource_group_name})"
  scope       = data.azurerm_subscription.current.id
  description = "Read and accept Azure Marketplace purchase agreements. Managed by the github-runner-vmss module (${var.resource_group_name}) so its deploy identity can accept the CIS image terms."

  permissions {
    # Just the Microsoft.MarketplaceOrdering data-plane actions the
    # azurerm_marketplace_agreement resource exercises - new-style
    # (offerTypes/.../agreements) and legacy (agreements/...) shapes,
    # plus operations/read which the provider lists.
    actions = [
      "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements/read",
      "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements/write",
      "Microsoft.MarketplaceOrdering/agreements/read",
      "Microsoft.MarketplaceOrdering/agreements/offers/plans/read",
      "Microsoft.MarketplaceOrdering/agreements/offers/plans/sign/action",
      "Microsoft.MarketplaceOrdering/agreements/offers/plans/cancel/action",
      "Microsoft.MarketplaceOrdering/operations/read",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "pipeline_marketplace_ordering" {
  count = local.manage_marketplace_rbac ? 1 : 0

  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.marketplace_ordering[0].role_definition_resource_id
  principal_id       = data.azurerm_client_config.current.object_id
  description        = "Lets the deploy pipeline identity accept Marketplace terms for the CIS Hardened Ubuntu 24.04 image (azurerm_marketplace_agreement.cis_ubuntu_2404)."
}

# A fresh subscription-scoped role assignment (and the custom role behind
# it) takes a little while to replicate before Microsoft.MarketplaceOrdering
# will honour it - without this wait the very first apply races the grant
# above and azurerm_marketplace_agreement.cis_ubuntu_2404 still 403s.
# Mirrors time_sleep.blob_rbac_lag in main.tf; only re-runs when the
# assignment itself changes, so steady-state applies skip the delay.
resource "time_sleep" "marketplace_rbac_lag" {
  count = local.manage_marketplace_rbac ? 1 : 0

  depends_on      = [azurerm_role_assignment.pipeline_marketplace_ordering]
  create_duration = "120s"

  triggers = {
    role_assignment_id = azurerm_role_assignment.pipeline_marketplace_ordering[0].id
  }
}
