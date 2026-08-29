// GitHub side: mint an App installation token from the private key in Key
// Vault (same key the runners use), then count QUEUED jobs whose runs-on
// labels match the configured set.

import crypto from "node:crypto";
import { DefaultAzureCredential } from "@azure/identity";
import { SecretClient } from "@azure/keyvault-secrets";

const API = "https://api.github.com";
const credential = new DefaultAzureCredential();

// --- installation token, cached in-process ---------------------------------
let cached = { token: null, expiresAt: 0 };

function b64url(buf) {
  return Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function readPrivateKey(cfg) {
  const client = new SecretClient(cfg.keyVaultUri, credential);
  const secret = await client.getSecret(cfg.appKeySecretName);
  if (!secret.value) throw new Error(`Key Vault secret '${cfg.appKeySecretName}' is empty`);
  return secret.value;
}

function appJwt(appId, pem) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: String(appId) }));
  const sig = b64url(crypto.createSign("RSA-SHA256").update(`${header}.${payload}`).sign(pem));
  return `${header}.${payload}.${sig}`;
}

async function gh(url, token, init = {}) {
  const res = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "queue-metric-function",
      ...(init.headers || {}),
    },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`GitHub ${init.method || "GET"} ${url} -> ${res.status} ${body.slice(0, 300)}`);
  }
  return res.json();
}

export async function getInstallationToken(cfg) {
  if (cached.token && Date.now() < cached.expiresAt - 120_000) return cached.token;

  const pem = await readPrivateKey(cfg);
  const jwt = appJwt(cfg.appId, pem);

  const instUrl =
    cfg.scope === "repo"
      ? `${API}/repos/${cfg.repo}/installation`
      : `${API}/orgs/${cfg.owner}/installation`;
  const inst = await gh(instUrl, jwt);

  const tok = await gh(`${API}/app/installations/${inst.id}/access_tokens`, jwt, { method: "POST" });
  cached = { token: tok.token, expiresAt: Date.parse(tok.expires_at) || Date.now() + 3_000_000 };
  return cached.token;
}

// --- queued-job count -----------------------------------------------------
function labelsMatch(jobLabels, want) {
  const have = new Set((jobLabels || []).map((l) => String(l).toLowerCase()));
  return want.every((w) => have.has(w.toLowerCase()));
}

async function listRepos(cfg, token) {
  if (cfg.scope === "repo") return [cfg.repo];
  const repos = [];
  for (let page = 1; page <= 10; page++) {
    const batch = await gh(
      `${API}/orgs/${cfg.owner}/repos?per_page=100&page=${page}&sort=pushed`,
      token
    );
    repos.push(...batch.map((r) => r.full_name));
    if (batch.length < 100) break;
  }
  return repos;
}

/**
 * Authoritative recount: for every run that could still have unstarted jobs
 * (queued, plus in_progress for matrix legs waiting on a runner), count the
 * jobs that are status=queued and carry all the wanted labels.
 */
export async function countQueuedJobs(cfg, token, log = () => {}) {
  const repos = await listRepos(cfg, token);
  let count = 0;

  for (const repo of repos) {
    const runIds = new Set();
    for (const status of ["queued", "in_progress"]) {
      const runs = await gh(
        `${API}/repos/${repo}/actions/runs?status=${status}&per_page=100`,
        token
      );
      for (const r of runs.workflow_runs || []) runIds.add(r.id);
    }

    for (const runId of runIds) {
      const jobsResp = await gh(
        `${API}/repos/${repo}/actions/runs/${runId}/jobs?per_page=100`,
        token
      );
      for (const job of jobsResp.jobs || []) {
        if (job.status === "queued" && labelsMatch(job.labels, cfg.matchLabels)) count++;
      }
    }
  }

  log(`queued jobs matching [${cfg.matchLabels.join(",")}] across ${repos.length} repo(s): ${count}`);
  return count;
}

// --- runner registrations ----------------------------------------------
function runnersBase(cfg) {
  return cfg.scope === "repo"
    ? `${API}/repos/${cfg.repo}/actions/runners`
    : `${API}/orgs/${cfg.owner}/actions/runners`;
}

export async function listRunners(cfg, token) {
  const base = runnersBase(cfg);
  const runners = [];
  for (let page = 1; page <= 20; page++) {
    const j = await gh(`${base}?per_page=100&page=${page}`, token);
    const batch = j.runners || [];
    runners.push(...batch);
    if (batch.length < 100) break;
  }
  return runners;
}

export async function deleteRunner(cfg, token, id) {
  const res = await fetch(`${runnersBase(cfg)}/${id}`, {
    method: "DELETE",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "queue-metric-function",
    },
  });
  if (!res.ok && res.status !== 404) {
    throw new Error(`DELETE runner ${id} -> ${res.status} ${(await res.text().catch(() => "")).slice(0, 200)}`);
  }
}

// --- webhook signature --------------------------------------------------
export function verifySignature(secret, rawBody, signatureHeader) {
  if (!secret) return false;
  if (!signatureHeader || !signatureHeader.startsWith("sha256=")) return false;
  const expected =
    "sha256=" + crypto.createHmac("sha256", secret).update(rawBody, "utf8").digest("hex");
  const a = Buffer.from(signatureHeader);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}
