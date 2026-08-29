// Hourly: remove GitHub runner registrations that are OFFLINE and have no
// matching live VMSS instance. terminate-watcher.sh handles the graceful
// case on scale-in; this mops up the rest (force-deallocation, manual
// `az vmss delete-instances`, failed boots) so the runners list stays
// clean instead of waiting out GitHub's 14-day offline auto-purge.
//
// A runner is only deleted when BOTH hold:
//   * status === "offline"
//   * name starts with RUNNER_NAME_PREFIX (default "vmss-runner-")
//   * "<name minus prefix>" is not a current instance computer name
// so a runner that is merely rebooting keeps its registration.

import { app } from "@azure/functions";
import { loadConfig } from "../lib/config.js";
import { getInstallationToken, listRunners, deleteRunner } from "../lib/github.js";
import { liveInstanceHostnames } from "../lib/vmss.js";

app.timer("cleanupOfflineRunners", {
  schedule: "0 7 * * * *", // 6-field NCRONTAB: every hour at HH:07:00
  handler: async (_timer, context) => {
    const log = (m) => context.log(m);
    const cfg = loadConfig();
    const token = await getInstallationToken(cfg);

    const runners = await listRunners(cfg, token);
    const offline = runners.filter(
      (r) => r.status === "offline" && (r.name || "").startsWith(cfg.runnerNamePrefix)
    );
    if (offline.length === 0) {
      log(`no offline runners named "${cfg.runnerNamePrefix}*"`);
      return;
    }

    const live = await liveInstanceHostnames(cfg.vmssResourceId);
    let removed = 0;
    for (const r of offline) {
      const host = r.name.slice(cfg.runnerNamePrefix.length).toLowerCase();
      if (live.has(host)) {
        log(`keep ${r.name} - instance "${host}" still exists (rebooting?)`);
        continue;
      }
      await deleteRunner(cfg, token, r.id);
      removed++;
      log(`removed orphaned runner ${r.name} (id ${r.id})`);
    }
    log(`cleanup: removed ${removed} of ${offline.length} offline "${cfg.runnerNamePrefix}*" runners`);
  },
});
