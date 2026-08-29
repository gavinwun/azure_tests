// The one operation both triggers perform: mint a token, count matching
// queued jobs, publish the metric. Serialised so a webhook burst and the
// timer don't stampede the GitHub API at once.

import { loadConfig } from "./config.js";
import { getInstallationToken, countQueuedJobs } from "./github.js";
import { publishMetric } from "./metric.js";

let inFlight = null;

export async function recountAndPublish(reason, log) {
  if (inFlight) {
    log?.(`recount already running (${reason}) - awaiting the in-flight one`);
    return inFlight;
  }
  inFlight = (async () => {
    const cfg = loadConfig();
    const token = await getInstallationToken(cfg);
    const count = await countQueuedJobs(cfg, token, log);
    await publishMetric(cfg, count, log);
    return count;
  })();
  try {
    return await inFlight;
  } finally {
    inFlight = null;
  }
}
