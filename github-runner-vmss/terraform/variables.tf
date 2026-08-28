variable "compute_backend" {
  description = "Which compute backend to deploy: \"vmss\" (Azure VMSS, boot-time bootstrap script) or \"aci\" (Azure Container Instances, prebuilt Docker image). Only one is ever deployed at a time - switching requires apply + a corresponding change to which poller workflow is active."
  type        = string
  default     = "vmss"

  validation {
    condition     = contains(["vmss", "aci"], var.compute_backend)
    error_message = "compute_backend must be either \"vmss\" or \"aci\"."
  }
}

variable "resource_group_name" {
  description = "Existing resource group that will hold the VMSS, storage account, and managed identity."
  type        = string
}

variable "vnet_resource_group_name" {
  description = "Resource group containing the VNet - either an existing one to look up (manage_network = false, the default) or one this module creates (manage_network = true)."
  type        = string
}

variable "manage_network" {
  description = "If true, Terraform creates the VNet, subnets, and private DNS zone inside the (already-existing) vnet_resource_group_name - see network.tf. Useful for a from-scratch or throwaway environment where only the resource group is provisioned ahead of time. Leave false (default) if vnet_name/the subnets/the DNS zone already exist too - that's the original, still-supported behaviour. Either way the resource group named by vnet_resource_group_name must already exist; Terraform never manages it (data.azurerm_resource_group.network_hub)."
  type        = bool
  default     = false
}

variable "vnet_address_space" {
  description = "Address space for the VNet Terraform creates. Only used when manage_network = true."
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "devopsagent_subnet_address_prefix" {
  description = "Address prefix for the devopsagent subnet Terraform creates. Only used when manage_network = true - must fit within vnet_address_space and not overlap pep_subnet_address_prefix or aci_subnet_address_prefix."
  type        = string
  default     = "10.0.1.0/24"
}

variable "pep_subnet_address_prefix" {
  description = "Address prefix for the private-endpoint subnet Terraform creates. Only used when manage_network = true - must fit within vnet_address_space and not overlap devopsagent_subnet_address_prefix or aci_subnet_address_prefix."
  type        = string
  default     = "10.0.2.0/24"
}

variable "vnet_name" {
  description = "Existing VNet name."
  type        = string
}

variable "devopsagent_subnet_name" {
  description = "Existing subnet the VMSS instances' NICs attach to."
  type        = string
}

variable "pep_subnet_name" {
  description = "Existing subnet used for the storage account's private endpoint."
  type        = string
}

variable "blob_private_dns_zone_name" {
  description = "Existing private DNS zone for blob storage, e.g. privatelink.blob.core.windows.net"
  type        = string
  default     = "privatelink.blob.core.windows.net"
}

variable "blob_private_dns_zone_resource_group_name" {
  description = "Resource group containing the blob private DNS zone."
  type        = string
}

#########################################################################
# Bootstrap script storage - public network access window
#########################################################################
# bootstrap_agent.sh is uploaded by whatever identity runs `terraform
# apply`. On the first deploy - and any later apply that runs from
# outside the hub VNet, e.g. a GitHub-hosted runner - that identity has
# to reach the storage account over its PUBLIC endpoint, since the
# private endpoint is only reachable from inside the VNet. Once the
# self-hosted runners exist and applies run from in-network, the public
# endpoint can stay shut and the runners keep pulling the script via the
# private endpoint regardless.
#
# terraform-deploy.yml's apply job drives these: one apply with public
# access on and the runner's egress IP allowed, then a second apply with
# both back at their defaults to re-lock the account.

variable "bootstrap_storage_public_network_access_enabled" {
  description = "Whether the bootstrap script storage account accepts traffic on its public endpoint. Set true only for the apply that uploads bootstrap_agent.sh from outside the hub VNet; leave false otherwise. Private endpoint access is unaffected either way."
  type        = bool
  default     = false
}

variable "bootstrap_storage_allowed_ips" {
  description = "Source IPs/CIDRs allowed through the storage firewall while bootstrap_storage_public_network_access_enabled = true (e.g. the pipeline runner's egress IP). The account denies by default, so this must be non-empty for a public-endpoint upload to succeed. Ignored when public access is false."
  type        = list(string)
  default     = []
}

variable "key_vault_name" {
  description = "Existing Key Vault holding the VMSS SSH public key secret and the github-app-token secret."
  type        = string
}

variable "key_vault_resource_group_name" {
  description = "Resource group containing the Key Vault."
  type        = string
}

variable "vm_size" {
  description = "VMSS instance SKU."
  type        = string
  default     = "Standard_B2als_v2"
}

variable "instance_count" {
  description = "Number of VMSS instances (fixed count - wire up autoscale separately if needed)."
  type        = number
  default     = 2
}

variable "admin_username" {
  description = "Linux admin username for VMSS instances."
  type        = string
  default     = "azureuser"
}

variable "github_org" {
  description = "GitHub organisation the runners register against when github_runner_scope = \"org\". Must match bootstrap_agent.sh's GITHUB_ORG."
  type        = string
}

# Neither of the next two is consumed by Terraform (nothing here templates
# bootstrap_agent.sh - it's hand-edited, README step 6). They live here so
# terraform.tfvars documents the values that bootstrap_agent.sh /
# entrypoint.sh and the RUNNER_SCOPE repo variable must agree on.
variable "github_runner_scope" {
  description = "Where instances register as runners: \"org\" (organisation-level; GitHub App needs Organization -> Self-hosted runners: Read and write) or \"repo\" (single repository - required for a personal account, which has no org runners; App needs Repository -> Administration: Read and write). Must match GITHUB_SCOPE in bootstrap_agent.sh / entrypoint.sh and the RUNNER_SCOPE repo variable."
  type        = string
  default     = "org"

  validation {
    condition     = contains(["org", "repo"], var.github_runner_scope)
    error_message = "github_runner_scope must be \"org\" or \"repo\"."
  }
}

variable "github_repo" {
  description = "\"owner/repo\" the runners attach to when github_runner_scope = \"repo\". Ignored for \"org\". Must match bootstrap_agent.sh's GITHUB_REPO."
  type        = string
  default     = ""
}

variable "environment" {
  description = "Short environment tag used in resource naming, e.g. dev, prod."
  type        = string
  default     = "dev"
}

variable "queue_autoscale_min_instances" {
  description = "Floor for VMSS instance count. Autoscale never scales below this even at zero queue depth."
  type        = number
  default     = 1
}

variable "queue_autoscale_max_instances" {
  description = "Ceiling for VMSS instance count regardless of queue depth."
  type        = number
  default     = 10
}

variable "queue_autoscale_default_instances" {
  description = "Initial instance count on first create. Terraform ignores drift from this afterwards (see lifecycle block in main.tf) - Azure Monitor owns the live count."
  type        = number
  default     = 1
}

variable "custom_metric_namespace" {
  description = "Namespace the poller workflow publishes the custom metric under (vmss backend only). Must match exactly between Terraform and poll-queue-depth.yml."
  type        = string
  default     = "GitHubActionsQueue"
}

variable "custom_metric_name" {
  description = "Metric name the poller workflow publishes (vmss backend only). Must match exactly between Terraform and poll-queue-depth.yml."
  type        = string
  default     = "QueuedJobs"
}

variable "queue_messages_per_instance" {
  description = "Scaling threshold: queued jobs per running instance (vmss backend only). E.g. 1 means each instance is expected to handle one queued job before another instance is added."
  type        = number
  default     = 1
}

#########################
# ACI backend
#########################

variable "aci_subnet_address_prefix" {
  description = "Address prefix for the dedicated, ACI-delegated subnet. Must not overlap any existing subnet in the VNet."
  type        = string
  default     = "10.0.100.0/24"
}

variable "aci_min_instances" {
  description = "Floor for concurrently running ACI container groups. 0 is a reasonable default - ACI scales to zero naturally, unlike VMSS."
  type        = number
  default     = 0
}

variable "aci_max_instances" {
  description = "Ceiling for concurrently running ACI container groups regardless of queue depth."
  type        = number
  default     = 10
}

variable "aci_container_cpu" {
  description = "vCPU allocated per runner container group."
  type        = number
  default     = 2
}

variable "aci_container_memory_gb" {
  description = "Memory (GB) allocated per runner container group."
  type        = number
  default     = 4
}

variable "aci_image_tag" {
  description = "Tag of the runner image in ACR that reconcile-aci-runners.yml deploys. build-and-push-runner-image.yml publishes this tag."
  type        = string
  default     = "latest"
}

variable "queue_scale_out_cooldown_minutes" {
  description = "Minutes to wait after a scale-out action before considering another."
  type        = number
  default     = 2
}

variable "queue_scale_in_cooldown_minutes" {
  description = "Minutes to wait after a scale-in action before considering another. Kept higher than scale-out to avoid flapping."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Common resource tags."
  type        = map(string)
  default     = {}
}
