// Heartbeat: every 3 minutes, do an authoritative recount and publish.
// This alone keeps autoscale fed even with no webhook configured; the
// webhook just makes the reaction near-instant.

import { app } from "@azure/functions";
import { recountAndPublish } from "../lib/recount.js";

app.timer("queueMetricTimer", {
  schedule: "0 */3 * * * *", // 6-field NCRONTAB: every 3 min
  handler: async (myTimer, context) => {
    const log = (m) => context.log(m);
    try {
      const count = await recountAndPublish("timer", log);
      context.log(`timer: published QueuedJobs=${count}`);
    } catch (err) {
      context.error(`timer recount failed: ${err.message}`);
      throw err; // surface as a failed invocation
    }
  },
});
