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

# CIS hardening. The vmss backend runs stock (free) Canonical Ubuntu
# 24.04 and, when cis_hardening_enabled = true (default), applies the CIS
# Ubuntu 24.04 Benchmark at first boot via the MIT-licensed
# ansible-lockdown/UBUNTU24-CIS role - no Marketplace purchase, no Ubuntu
# Pro token. Adds ~1-3 min to first boot.
cis_hardening_enabled         = true
cis_hardening_level           = "level1" # or "level2"
cis_hardening_manage_firewall = false    # true = CIS configures ufw; bootstrap re-adds the runner's egress rules
cis_hardening_ref             = "1.6.0"  # pinned ansible-lockdown/UBUNTU24-CIS tag
cis_audit_enabled             = true     # install /usr/local/sbin/cis-audit + scoped sudoers for the cis-benchmark.yml workflow

# Controls forced off in BOTH the hardening role and the read-only audit
# (bootstrap_agent.sh writes each as `ubtu24cis_rule_*: false` into
# /etc/ghrunner/cis-overrides.yml, which install_cis_audit() also feeds to
# goss). Every entry here is a control that either cannot hold on a
# single-disk ephemeral VMSS instance, or that would blind the fleet -
# not strict-CIS ticks we're giving up for convenience.
cis_hardening_skip_rules = [
  # -- §1.1.2 separate-partition isolation (nodev/nosuid/noexec on their
  #    own filesystems). The instance has one OS disk and no data disks;
  #    carving /var, /var/log, /var/log/audit etc. off risks a full
  #    /var/log wedging the box or a size-capped /tmp breaking large
  #    checkouts. /tmp + /dev/shm still get nodev/nosuid via the existing
  #    tmp.mount drop-in; only the "must be its own partition" variants
  #    are dropped here.
  "ubtu24cis_rule_1_1_2_1_1", "ubtu24cis_rule_1_1_2_1_2", "ubtu24cis_rule_1_1_2_1_3",
  "ubtu24cis_rule_1_1_2_2_2", "ubtu24cis_rule_1_1_2_2_3",
  "ubtu24cis_rule_1_1_2_3_2", "ubtu24cis_rule_1_1_2_3_3",
  "ubtu24cis_rule_1_1_2_4_2", "ubtu24cis_rule_1_1_2_4_3",
  "ubtu24cis_rule_1_1_2_5_2", "ubtu24cis_rule_1_1_2_5_3",
  "ubtu24cis_rule_1_1_2_6_2", "ubtu24cis_rule_1_1_2_6_3", "ubtu24cis_rule_1_1_2_6_4",
  "ubtu24cis_rule_1_1_2_7_2", "ubtu24cis_rule_1_1_2_7_3", "ubtu24cis_rule_1_1_2_7_4",

  # -- §1.4.1 GRUB bootloader password. No serial/console to a VMSS
  #    instance and the OS is rebuilt from the image on every scale
  #    event; a GRUB password guards nothing here and a bad hash bricks
  #    the boot.
  "ubtu24cis_rule_1_4_1",

  # -- §5.4.2.4 "root account access is controlled" - the audit's check
  #    wants a *set* root password. Azure VMSS locks the root password
  #    (key-only admin user); a locked root is the controlled state.
  "ubtu24cis_rule_5_4_2_4",

  # -- §6.1.1.4 / §6.1.2.2 - "only journald OR rsyslog, not both" and
  #    journald ForwardToSyslog=no. This fleet is observed without SSH by
  #    shipping bootstrap + OS syslog through rsyslog -> Azure Monitor
  #    Agent -> Log Analytics (see terraform/monitoring.tf). Stopping
  #    rsyslog or cutting the journald->syslog forward blinds that path.
  "ubtu24cis_rule_6_1_1_4", "ubtu24cis_rule_6_1_2_2",

  # -- §6.1.2.1.1 / §6.1.2.1.2 / §6.1.2.1.3 - systemd-journal-remote/-upload
  #    as a log *shipping client*. We don't push the journal to a remote
  #    collector; the remote units are masked instead (§6.1.2.1.4, which
  #    the backstop in bootstrap_agent.sh enforces). 6.1.2.1.2's PATCH
  #    task also HARD-FAILS the ansible run ("Destination
  #    /etc/systemd/journal-upload.conf does not exist") because the
  #    package isn't installed - this is the last `failed=1` in the role.
  "ubtu24cis_rule_6_1_2_1_1", "ubtu24cis_rule_6_1_2_1_2", "ubtu24cis_rule_6_1_2_1_3",

  # -- §5.1.17 sshd MaxSessions. The system is compliant (MaxSessions 10,
  #    the CIS recommendation) but the audit's goss check has an
  #    unanchored negative regex - `!/^MaxSessions (1|1[1-9]|...)/` also
  #    matches the leading "1" of "10", so the correct value can never
  #    pass. Scoped out as an audit-tool bug, not a real gap.
  "ubtu24cis_rule_5_1_17",
]


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
