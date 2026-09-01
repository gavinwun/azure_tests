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

  # Re-run detector for the CustomScript guard. Any edit to
  # bootstrap_agent.sh OR any change to a cis_hardening_* input changes
  # this string, so an instance that picks up the new VMSS model re-runs
  # the WHOLE bootstrap instead of short-circuiting on its sentinel; an
  # unchanged version still skips instantly. bootstrap_agent.sh's steps
  # are all idempotent, so a re-run is safe.
  #
  # NOTE: upgrade_mode is "Manual" (main.tf), so LIVE instances only pick
  # up a bumped version on reimage / rolling upgrade / `az vmss
  # update-instances`. Newly scaled-out instances always get the latest.
  bootstrap_version = substr(sha256(join("\n", [
    filesha256("${path.module}/scripts/bootstrap_agent.sh"),
    tostring(var.cis_hardening_enabled),
    var.cis_hardening_level,
    tostring(var.cis_hardening_manage_firewall),
    var.cis_hardening_ref,
    join(",", var.cis_hardening_skip_rules),
  ])), 0, 16)

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

    # Re-run guard. CustomScript re-executes on every instance model
    # update (VM resize, image bump, VMSS auto-repair, extension change).
    # bootstrap_agent.sh writes the version it completed into this
    # sentinel as its final step, so:
    #   - a failed first boot still retries (no sentinel yet)
    #   - an unchanged version is skipped here before any download
    #   - a bumped version (script edit or cis_hardening_* change) falls
    #     through and re-runs the whole thing (all steps are idempotent)
    if [ -f /var/lib/ghrunner/.bootstrapped ] && \
       [ "$(cat /var/lib/ghrunner/.bootstrapped 2>/dev/null)" = "${local.bootstrap_version}" ]; then
      echo "instance already bootstrapped at version ${local.bootstrap_version} - skipping"
      exit 0
    fi
    echo "bootstrapping to version ${local.bootstrap_version}"

    # CIS Benchmark hardening knobs, passed through to bootstrap_agent.sh
    # (harden_cis()). The script is a static blob - it can't see Terraform
    # vars - so the preamble, which IS rendered by Terraform, exports them
    # and the child process inherits them. Defaults live in the script.
    export BOOTSTRAP_VERSION="${local.bootstrap_version}"
    export CIS_HARDENING_ENABLED="${var.cis_hardening_enabled}"
    export CIS_HARDENING_LEVEL="${var.cis_hardening_level}"
    export CIS_HARDENING_MANAGE_FIREWALL="${var.cis_hardening_manage_firewall}"
    export CIS_HARDENING_REF="${var.cis_hardening_ref}"
    export CIS_HARDENING_SKIP_RULES="${join(" ", var.cis_hardening_skip_rules)}"

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
