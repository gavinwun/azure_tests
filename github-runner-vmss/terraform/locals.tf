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

  # ---------------------------------------------------------------------
  # CustomScript preamble (vmss backend). Downloads bootstrap_agent.sh
  # from the private blob using the VM's managed identity, then runs it.
  #
  # This is authored as a real bash script and shipped base64-encoded,
  # NOT as an inline `bash -c "..."` string: the CustomScript handler
  # executes commandToExecute via `/bin/sh -c`, which would expand every
  # $VAR / $(...) itself before bash ever saw them. base64 has no shell
  # metacharacters, so `sh` passes it through untouched.
  # ---------------------------------------------------------------------
  bootstrap_agent_url = join("", [
    "https://",
    one(azurerm_storage_account.bootstrap[*].name),
    ".blob.core.windows.net/",
    one(azurerm_storage_container.scripts[*].name),
    "/",
    one(azurerm_storage_blob.bootstrap_script[*].name),
  ])

  bootstrap_preamble_script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p /var/log/bootstrap
    # tee (not plain redirect) so the CustomScript extension status still
    # captures this - visible in `az vmss get-instance-view`.
    exec > >(tee -a /var/log/bootstrap/bootstrap-download.log) 2>&1
    echo "=== CustomScript preamble $(date -u) ==="

    # Run-once guard. CustomScript re-executes on every instance model
    # update (VM resize, image bump, VMSS auto-repair). bootstrap_agent.sh
    # writes this sentinel as its final step, so a failed first boot still
    # retries; a completed one is skipped here before any download.
    if [ -f /var/lib/ghrunner/.bootstrapped ]; then
      echo "instance already bootstrapped - skipping"
      exit 0
    fi

    # CIS Hardened image (Ubuntu 24.04 L1): if the image boots with a
    # default-deny *outbound* host firewall, open just enough to reach
    # Azure IMDS and the in-VNet storage private endpoint so this
    # download can run. bootstrap_agent.sh re-asserts the full egress
    # allow-list (GitHub, apt mirrors, NTP, ...) once it's fetched.
    # Inbound stays denied - a persistent runner never listens.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
      echo "CIS-compat (preamble): ufw active - opening IMDS + in-VNet egress"
      ufw allow out to 169.254.169.254 >/dev/null 2>&1 || true
      ufw allow out to 168.63.129.16 >/dev/null 2>&1 || true
      ufw allow out 53 >/dev/null 2>&1 || true
      ufw allow out 443/tcp >/dev/null 2>&1 || true
      SUBNET_ADDR=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/subnet/0/address?api-version=2021-02-01&format=text" 2>/dev/null || true)
      SUBNET_PREFIX=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/subnet/0/prefix?api-version=2021-02-01&format=text" 2>/dev/null || true)
      [ -n "$${SUBNET_ADDR}" ] && [ -n "$${SUBNET_PREFIX}" ] && ufw allow out to "$${SUBNET_ADDR}/$${SUBNET_PREFIX}" >/dev/null 2>&1 || true
    elif command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null && nft list chain inet filter output >/dev/null 2>&1; then
      echo "CIS-compat (preamble): nftables output filter active - inserting IMDS allow"
      nft insert rule inet filter output ip daddr 168.63.129.16 accept >/dev/null 2>&1 || true
      nft insert rule inet filter output ip daddr 169.254.169.254 accept >/dev/null 2>&1 || true
      nft insert rule inet filter output ct state established,related accept >/dev/null 2>&1 || true
    fi

    SCRIPT_URL="${local.bootstrap_agent_url}"
    TOKEN_URI="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F"

    # jq isn't installed on the stock image yet (bootstrap_agent.sh installs
    # it) - parse the IMDS token response with grep/sed. Retry: IMDS can be
    # briefly unavailable very early in boot.
    TOKEN=$(curl -s --retry 5 --retry-delay 3 --retry-connrefused \
      -H "Metadata:true" "$TOKEN_URI" \
      | grep -o '"access_token":"[^"]*' | sed 's/"access_token":"//')
    if [ -z "$TOKEN" ]; then
      echo "could not obtain a managed-identity token from IMDS" >&2
      exit 1
    fi

    curl -sS --fail --retry 5 --retry-delay 5 --retry-connrefused \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-ms-version: 2020-10-02" \
      -H "x-ms-date: $(date -u '+%a, %d %b %Y %H:%M:%S GMT')" \
      -o /var/log/bootstrap/bootstrap_agent.sh \
      "$SCRIPT_URL"

    if [ ! -s /var/log/bootstrap/bootstrap_agent.sh ]; then
      echo "downloaded bootstrap_agent.sh is empty" >&2
      exit 1
    fi

    chmod +x /var/log/bootstrap/bootstrap_agent.sh

    # Run it. bootstrap_agent.sh fans its own output out to a detail log +
    # syslog + stdout, so this both lands in bootstrap.log and flows up to
    # the extension status. On failure, surface the tail so the error is
    # visible without a run-command round-trip.
    set +e
    /var/log/bootstrap/bootstrap_agent.sh 2>&1 | tee /var/log/bootstrap/bootstrap.log
    rc=$${PIPESTATUS[0]}
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "bootstrap_agent.sh exited $rc - last 60 lines:" >&2
      tail -n 60 /var/log/bootstrap/bootstrap_agent_detail.log 2>/dev/null >&2 || true
      exit "$rc"
    fi
  EOT

  bootstrap_command = "echo ${base64encode(local.bootstrap_preamble_script)} | base64 -d | bash"

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
