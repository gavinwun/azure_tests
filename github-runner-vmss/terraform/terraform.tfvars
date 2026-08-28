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

vm_size        = "Standard_D4s_v5"
instance_count = 2
admin_username = "azureuser"

github_org  = "gavinwun"
environment = "production"

# "vmss" (default) or "aci" - see README for the full switch-over
# procedure before changing this on a live deployment.
compute_backend = "vmss"

tags = {
  costCentre = "platform-engineering"
}
