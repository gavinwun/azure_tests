locals {
  tags = merge(var.tags, {
    workload  = "github-actions-self-hosted-runner"
    managedBy = "terraform"
  })

  name_suffix = "${var.environment}-${random_string.suffix.result}"

  vmss_uai_name                = "uai-ghrunner-${local.name_suffix}"
  vmss_name                    = "vmss-ghrunner-${local.name_suffix}"
  vmss_nic_name                = "nic-ghrunner-${local.name_suffix}"
  vmss_computer_name_prefix    = "ghrunner"
  bootstrap_storage_pep_name   = "pep-ghrunner-boot-${local.name_suffix}"
  bootstrap_storage_psc_name   = "psc-ghrunner-boot-${local.name_suffix}"
  log_analytics_workspace_name = "log-ghrunner-${local.name_suffix}"
  vmss_dcr_name                = "dcr-ghrunner-${local.name_suffix}"

  # syslog facility the bootstrap script logs under (see bootstrap_agent.sh)
  # - kept separate from the OS facilities so it's trivially filterable:
  #   Syslog | where Facility == "local0"
  bootstrap_syslog_facility = "local0"

  # Storage account names: 3-24 chars, lowercase alphanumeric only, globally unique
  bootstrap_storage_account_name = substr(
    lower(replace("stghrunboot${random_string.suffix.result}", "-", "")),
    0, 24
  )

  # ACR names: 5-50 chars, alphanumeric only (no hyphens), globally unique
  acr_name = substr(
    lower(replace("acrghrunner${random_string.suffix.result}", "-", "")),
    0, 50
  )
}
