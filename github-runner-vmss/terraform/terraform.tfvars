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

# The vmss backend runs on the CIS Hardened Ubuntu 24.04 Marketplace
# image. true (default): Terraform accepts its Marketplace terms and
# manages the subscription-scoped Microsoft.MarketplaceOrdering RBAC the
# deploy identity needs (marketplace-rbac.tf) - requires a one-time
# subscription Owner / User Access Administrator grant on that identity
# (README step 7.3). false: you accepted the terms out-of-band with
# `az vm image terms accept` and Terraform stays out of subscription scope.
manage_marketplace_agreement = false

# Azure Monitor Agent on the VMSS instances. On by default; ships syslog +
# bootstrap output + perf counters to Log Analytics. Empty workspace ID =>
# Terraform creates a dedicated workspace; set it to an existing
# workspace's resource ID to reuse one.
enable_vmss_monitoring     = true
log_analytics_workspace_id = ""

# Object (principal) id of the gh-runner-queue-poller SP. When set,
# Terraform grants it 'Monitoring Metrics Publisher' on the VMSS so
# poll-queue-depth.yml can publish the autoscale metric - no manual
# post-apply az step. Get it: az ad sp show --id <poller-client-id> --query id -o tsv
queue_poller_principal_id = "b01481e4-2d39-4ffc-a7ff-6f17a82814bf"

# Which queued jobs count toward autoscale: a job counts only if its runs-on
# labels are a superset of these. "self-hosted,vmss" = VMSS-specific.
runner_match_labels = "self-hosted"

# Queue-metric Function App (queue-metric-function.tf) - an alternative to the
# poll-queue-depth.yml cron that doesn't depend on GitHub's scheduler. Off by
# default. When true, also set github_app_id, and github_webhook_secret if you
# want the workflow_job webhook (else it runs timer-only).
enable_queue_metric_function = true
github_app_id                = "4736345"
# github_webhook_secret       = ""   # sensitive - prefer setting in the portal / a *.local.tfvars

tags = {
  costCentre = "platform-engineering"
}
