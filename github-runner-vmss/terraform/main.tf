# Adapted from https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/scale-set-agents?view=azure-devops
# Converted: Windows Server 2022 / Azure DevOps agent -> Ubuntu 22.04 LTS / GitHub Actions self-hosted runner
#
# Everything in this file is gated by var.compute_backend == "vmss" via
# `count`. Set compute_backend = "aci" in terraform.tfvars to deploy
# aci.tf instead - see README for the full switch-over procedure.

# Random string for unique suffix
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

#########################
# Managed Identity      #
#########################

resource "azurerm_user_assigned_identity" "agent_id" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                = local.vmss_uai_name
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  tags                = local.tags
}

#########################
# Storage for scripts   #
#########################

resource "azurerm_storage_account" "bootstrap" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                             = local.bootstrap_storage_account_name
  resource_group_name              = data.azurerm_resource_group.mgmt_devops.name
  location                         = data.azurerm_resource_group.mgmt_devops.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  public_network_access_enabled    = false
  allow_nested_items_to_be_public  = false
  shared_access_key_enabled        = false
}

resource "azurerm_storage_container" "scripts" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                  = "scripts"
  storage_account_id    = azurerm_storage_account.bootstrap[0].id
  container_access_type = "private"
}

# CHANGED: .ps1 -> .sh
resource "azurerm_storage_blob" "bootstrap_script" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                   = "bootstrap_agent.sh"
  storage_account_name   = azurerm_storage_account.bootstrap[0].name
  storage_container_name = azurerm_storage_container.scripts[0].name
  type                   = "Block"
  source                 = "${path.module}/scripts/bootstrap_agent.sh"
}

resource "azurerm_role_assignment" "vmss_blob_reader" {
  count = var.compute_backend == "vmss" ? 1 : 0

  scope                = azurerm_storage_account.bootstrap[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.agent_id[0].principal_id
}

resource "azurerm_role_assignment" "pipeline_blob_reader" {
  count = var.compute_backend == "vmss" ? 1 : 0

  scope                = azurerm_storage_account.bootstrap[0].id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "pipeline_blob_contributor" {
  count = var.compute_backend == "vmss" ? 1 : 0

  scope                = azurerm_storage_account.bootstrap[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

#########################################
# Key Vault access for GitHub token
#########################################
# Runner needs a short-lived GitHub App/PAT token at boot to mint its
# registration token. Terraform grants access only - the secret itself
# is fetched at runtime inside bootstrap_agent.sh, never read into state.

resource "azurerm_role_assignment" "vmss_kv_secrets_user" {
  count = var.compute_backend == "vmss" ? 1 : 0

  scope                = data.azurerm_key_vault.mgmt_devops.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agent_id[0].principal_id
}

#########################
# Private Endpoint      #
#########################

resource "azurerm_private_endpoint" "bootstrap_blob" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                = local.bootstrap_storage_pep_name
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  subnet_id           = local.pep_subnet_id

  private_service_connection {
    name                           = local.bootstrap_storage_psc_name
    private_connection_resource_id = azurerm_storage_account.bootstrap[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-zone-group"
    private_dns_zone_ids = [local.blob_private_dns_zone_id]
  }

  # RBAC propagation can lag a few seconds behind the role assignment
  # existing in state - wait on these explicitly rather than relying on
  # Terraform's implicit ordering, since the pep subnet attach and DNS
  # zone group write both depend on grants from network-rbac.tf.
  depends_on = [
    azurerm_role_assignment.pipeline_network_hub_contributor,
    azurerm_role_assignment.pipeline_private_dns_zone_contributor
  ]
}

#########################
# VM Scale Set (Linux)  #
#########################

# CHANGED: azurerm_windows_virtual_machine_scale_set -> azurerm_linux_virtual_machine_scale_set
resource "azurerm_linux_virtual_machine_scale_set" "vmss" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                = local.vmss_name
  location            = data.azurerm_resource_group.mgmt_devops.location
  resource_group_name = data.azurerm_resource_group.mgmt_devops.name
  tags                = local.tags

  sku                         = var.vm_size
  instances                   = var.queue_autoscale_default_instances # autoscale owns the live count after first apply - see lifecycle block below
  admin_username              = var.admin_username
  computer_name_prefix        = local.vmss_computer_name_prefix
  encryption_at_host_enabled  = true

  # -----------------------------------------------------------------
  # SSH key auth instead of a local admin password.
  # -----------------------------------------------------------------
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = data.azurerm_key_vault_secret.vmss_ssh_public_key[0].value
  }

  # -----------------------------------------------------------------
  # OS Image - Ubuntu 22.04 LTS (Gen2)
  # Bump offer/sku to "ubuntu-24_04-lts" / "server" for 24.04 if preferred.
  # -----------------------------------------------------------------
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # -----------------------------------------------------------------
  # Disk
  # -----------------------------------------------------------------
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 128
  }

  # -----------------------------------------------------------------
  # Network Interface (no LB, just subnet)
  # -----------------------------------------------------------------
  network_interface {
    name    = local.vmss_nic_name
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = local.devopsagent_subnet_id
    }
  }

  # -----------------------------------------------------------------
  # Identity - Key Vault (GitHub token) + Storage (script download)
  # -----------------------------------------------------------------
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.agent_id[0].id]
  }

  # -----------------------------------------------------------------
  # VMSS behaviour flags
  # -----------------------------------------------------------------
  overprovision               = false
  upgrade_mode                = "Manual"
  single_placement_group      = false
  platform_fault_domain_count = 1

  # -----------------------------------------------------------------
  # Gives each instance a warning window before scale-in actually
  # deallocates it, so terminate-watcher.sh (installed by
  # bootstrap_agent.sh) has time to deregister the runner from GitHub
  # first, rather than leaving a stale "offline" registration behind.
  # 5 min is the minimum Azure allows; raise toward 15 min if your jobs
  # commonly run long and you want more grace before a mid-job instance
  # gets cut off anyway (Azure force-terminates once this timeout
  # elapses regardless of job state).
  # -----------------------------------------------------------------
  termination_notification {
    enabled = true
    timeout = "PT5M"
  }

  # -----------------------------------------------------------------
  # Once queue-based autoscale (custom-metric-autoscale.tf) is attached,
  # Azure Monitor changes the live instance count out-of-band. Without
  # this, the next `terraform apply` sees a diff against `instances`
  # above and resets the count back down, fighting the autoscaler.
  # `instances` above still sets the count on first create.
  # -----------------------------------------------------------------
  lifecycle {
    ignore_changes = [instances]
  }

  # Same RBAC-propagation reasoning as the private endpoint above - the
  # devopsagent subnet attach needs pipeline_network_hub_contributor to
  # have actually taken effect first.
  depends_on = [
    azurerm_role_assignment.pipeline_network_hub_contributor
  ]
}

# CHANGED: Windows CustomScriptExtension -> Linux CustomScript (v2)
resource "azurerm_virtual_machine_scale_set_extension" "bootstrap_devops_agent" {
  count = var.compute_backend == "vmss" ? 1 : 0

  name                         = "DevOpsBootstrap"
  virtual_machine_scale_set_id = azurerm_linux_virtual_machine_scale_set.vmss[0].id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true

  settings = jsonencode({
    fileUris = []
  })

  # -----------------------------------------------------------------
  # Use the VM's managed identity to pull an OAuth token for
  # storage.azure.com, then use that to authenticate a plain HTTPS GET
  # against the private blob (no SAS token, no storage key - matches
  # shared_access_key_enabled = false on the storage account above).
  # -----------------------------------------------------------------
  protected_settings = jsonencode({
    commandToExecute = join(" ", [
      "bash -c \"",
      "set -euo pipefail;",
      "mkdir -p /var/log/bootstrap;",
      "LOG=/var/log/bootstrap/bootstrap-download.log;",

      "SCRIPT_URL='https://${azurerm_storage_account.bootstrap[0].name}.blob.core.windows.net/${azurerm_storage_container.scripts[0].name}/${azurerm_storage_blob.bootstrap_script[0].name}';",
      "TOKEN_URI='http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F';",
      # jq isn't installed on a vanilla Ubuntu image yet at this point
      # (bootstrap_agent.sh is what installs it) - parse with grep/sed instead.
      "TOKEN=$(curl -s -H Metadata:true \\\"$TOKEN_URI\\\" | grep -o '\\\"access_token\\\":\\\"[^\\\"]*' | sed 's/\\\"access_token\\\":\\\"//');",

      "curl -sS -H \\\"Authorization: Bearer $TOKEN\\\" -H 'x-ms-version: 2020-10-02' ",
      "-H \\\"x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')\\\" ",
      "-o /var/log/bootstrap/bootstrap_agent.sh \\\"$SCRIPT_URL\\\" 2>>\\\"$LOG\\\" ",
      "|| { cat \\\"$LOG\\\"; exit 1; };",

      "chmod +x /var/log/bootstrap/bootstrap_agent.sh;",
      "/var/log/bootstrap/bootstrap_agent.sh > /var/log/bootstrap/bootstrap.log 2>&1;",
      "\""
    ])
  })

  depends_on = [
    azurerm_linux_virtual_machine_scale_set.vmss,
    azurerm_private_endpoint.bootstrap_blob,
    azurerm_role_assignment.vmss_blob_reader,
    azurerm_role_assignment.pipeline_blob_reader,
    azurerm_role_assignment.vmss_kv_secrets_user
  ]
}
