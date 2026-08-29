// Reads and validates the app settings this Function needs. Throws early
// with a clear message rather than failing deep in an API call.

function req(name) {
  const v = process.env[name];
  if (!v || !v.trim()) throw new Error(`missing required app setting: ${name}`);
  return v.trim();
}

export function loadConfig() {
  const scope = (process.env.RUNNER_SCOPE || "org").trim().toLowerCase();
  if (scope !== "org" && scope !== "repo") {
    throw new Error(`RUNNER_SCOPE must be "org" or "repo" (got "${scope}")`);
  }

  return {
    appId: req("GITHUB_APP_ID"),
    keyVaultUri: req("KEY_VAULT_URI"),
    appKeySecretName: process.env.GITHUB_APP_KEY_SECRET_NAME?.trim() || "github-app-private-key",

    scope,
    owner: req("GITHUB_OWNER"),
    // only needed when scope === "repo"
    repo: (process.env.GITHUB_REPO || "").trim(),

    // A queued job counts only if its runs-on labels are a SUPERSET of every
    // label here. "self-hosted,vmss" is VMSS-specific; "self-hosted" is broad.
    matchLabels: (process.env.RUNNER_MATCH_LABELS || "self-hosted")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),

    vmssResourceId: req("VMSS_RESOURCE_ID"),
    vmssRegion: req("VMSS_REGION"),
    metricNamespace: process.env.METRIC_NAMESPACE?.trim() || "GitHubActionsQueue",
    metricName: process.env.METRIC_NAME?.trim() || "QueuedJobs",

    // Empty => the webhook endpoint refuses every call (timer still works).
    webhookSecret: (process.env.GITHUB_WEBHOOK_SECRET || "").trim(),

    // Offline-runner cleanup only touches registrations whose name starts
    // with this (bootstrap_agent.sh names them "vmss-runner-<hostname>").
    runnerNamePrefix: (process.env.RUNNER_NAME_PREFIX || "vmss-runner-").trim(),
  };
}
