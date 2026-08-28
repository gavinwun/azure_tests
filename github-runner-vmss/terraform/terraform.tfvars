# NOTE: nothing in this file is sensitive (names only) - committed so the pipeline can use it directly.
# Fill in your real values before committing.
# Copy to terraform.tfvars and fill in your real values. Do not commit
# terraform.tfvars itself if it ever contains anything sensitive.

resource_group_name      = "rg-mgmt-devops"
vnet_resource_group_name = "rg-network-hub"
vnet_name                = "vnet-hub"
devopsagent_subnet_name  = "snet-devopsagent"
pep_subnet_name          = "snet-pep"

# false (default): the names above point at an existing landing-zone
# network - see README for the Reader/Network Contributor/Private DNS
# Zone Contributor role grants the deploy identity needs in that case.
# true: rg-network-hub must already exist with the deploy identity
# holding Contributor on it; Terraform then creates the VNet/subnets/
# DNS zone inside it using the names above. See README's manage_network
# note - Terraform never creates or owns the resource group itself.
manage_network = true
# vnet_address_space                = ["10.0.0.0/16"]
# devopsagent_subnet_address_prefix = "10.0.1.0/24"
# pep_subnet_address_prefix         = "10.0.2.0/24"

blob_private_dns_zone_name                = "privatelink.blob.core.windows.net"
blob_private_dns_zone_resource_group_name = "rg-network-hub"

key_vault_name                = "kv-ghrunner-25818"
key_vault_resource_group_name = "rg-mgmt-devops"

vm_size        = "Standard_B2als_v2"
instance_count = 2
admin_username = "azureuser"

github_org  = "gavinwun"
environment = "production"

# "org": runners register at the GitHub org level (App needs Organization
#   -> Self-hosted runners: Read and write).
# "repo": runners register on a single repo - use this for a PERSONAL
#   account (no org runners); App needs Repository -> Administration: R/W,
#   and github_repo below must be set. Keep in sync with GITHUB_SCOPE in
#   terraform/scripts/bootstrap_agent.sh and the RUNNER_SCOPE repo
#   variable.
github_runner_scope = "repo"
github_repo         = "gavinwun/azure_tests"

# "vmss" (default) or "aci" - see README for the full switch-over
# procedure before changing this on a live deployment.
compute_backend = "vmss"

# Azure Monitor Agent on the VMSS instances. On by default; ships syslog +
# bootstrap output + perf counters to Log Analytics. Empty workspace ID =>
# Terraform creates a dedicated workspace; set it to an existing
# workspace's resource ID to reuse one.
enable_vmss_monitoring     = true
log_analytics_workspace_id = ""

tags = {
  costCentre = "platform-engineering"
}
