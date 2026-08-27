#####################################################################
# RBAC for the deploy pipeline's own Key Vault access
#####################################################################
# main.tf's azurerm_role_assignment.vmss_kv_secrets_user grants the
# VMSS's managed identity access to the Key Vault at runtime - but the
# deploy pipeline identity (running terraform plan/apply) is a
# different principal, and data.tf's data "azurerm_key_vault_secret"
# "vmss_ssh_public_key" reads the SSH public key secret during plan,
# before the VMSS or its identity exist. Without this, plan fails with
# a 403 on Microsoft.KeyVault/vaults/secrets/getSecret/action.
#
# Same bootstrap chicken-and-egg as network-rbac.tf: the very first
# `terraform plan` on a fresh deploy identity still needs a ONE-TIME
# MANUAL grant of "Key Vault Secrets User" before it can read this
# secret - see README step 7.3. Once that exists, this resource takes
# over going forward (e.g. if the deploy identity is ever recreated).

resource "azurerm_role_assignment" "pipeline_kv_secrets_user" {
  count = var.compute_backend == "vmss" ? 1 : 0

  scope                = data.azurerm_key_vault.mgmt_devops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_client_config.current.object_id
}
