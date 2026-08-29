// GitHub `workflow_job` webhook. On a job event that could change the
// matching queue depth, kick an authoritative recount + publish so
// autoscale reacts in seconds instead of waiting for the timer.
//
// Configure the webhook on the org (or repo):
//   Payload URL: https://<app>.azurewebsites.net/api/workflow-job-webhook?code=<function key>
//   Content type: application/json
//   Secret: same value as the GITHUB_WEBHOOK_SECRET app setting
//   Events: "Workflow jobs" only

import { app } from "@azure/functions";
import { loadConfig } from "../lib/config.js";
import { verifySignature } from "../lib/github.js";
import { recountAndPublish } from "../lib/recount.js";

// job.labels superset check, local copy to avoid importing count internals
function labelsMatch(jobLabels, want) {
  const have = new Set((jobLabels || []).map((l) => String(l).toLowerCase()));
  return want.every((w) => have.has(w.toLowerCase()));
}

app.http("workflowJobWebhook", {
  methods: ["POST"],
  authLevel: "function", // ?code=<key> in addition to the HMAC check below
  route: "workflow-job-webhook",
  handler: async (request, context) => {
    const log = (m) => context.log(m);
    let cfg;
    try {
      cfg = loadConfig();
    } catch (err) {
      context.error(err.message);
      return { status: 500, body: `config error: ${err.message}` };
    }

    const event = request.headers.get("x-github-event") || "";
    const raw = await request.text();

    if (event === "ping") return { status: 200, body: "pong" };

    if (!cfg.webhookSecret) {
      context.warn("GITHUB_WEBHOOK_SECRET not set - webhook disabled (timer still runs)");
      return { status: 503, body: "webhook not configured" };
    }
    if (!verifySignature(cfg.webhookSecret, raw, request.headers.get("x-hub-signature-256"))) {
      return { status: 401, body: "bad signature" };
    }

    if (event !== "workflow_job") {
      return { status: 204 }; // not our event
    }

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return { status: 400, body: "invalid JSON" };
    }

    const action = payload.action; // queued | in_progress | completed | waiting
    const jobLabels = payload.workflow_job?.labels || [];

    // Only recount when a *matching* job's state changed in a way that moves
    // the queued count. Non-matching events (e.g. ubuntu-latest jobs) are
    // acknowledged and ignored - no API calls, no metric write.
    const relevant =
      ["queued", "in_progress", "completed"].includes(action) &&
      labelsMatch(jobLabels, cfg.matchLabels);

    if (!relevant) {
      return { status: 202, body: `ignored (action=${action}, labels=${jobLabels.join(",")})` };
    }

    try {
      const count = await recountAndPublish(`webhook:${action}`, log);
      return { status: 200, body: `recounted: QueuedJobs=${count}` };
    } catch (err) {
      context.error(`webhook recount failed: ${err.message}`);
      // 200 anyway: GitHub retries 5xx and a transient GitHub/Azure blip
      // shouldn't spam retries - the timer will catch up regardless.
      return { status: 200, body: `recount error (will retry on timer): ${err.message}` };
    }
  },
});
