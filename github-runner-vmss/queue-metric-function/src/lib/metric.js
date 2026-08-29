// Azure side: POST the value as an Azure Monitor custom metric on the VMSS
// resource, authenticated with this Function's managed identity.

import { DefaultAzureCredential } from "@azure/identity";

const credential = new DefaultAzureCredential();
const SCOPE = "https://monitoring.azure.com/.default";

export async function publishMetric(cfg, value, log = () => {}) {
  const token = await credential.getToken(SCOPE);
  if (!token?.token) throw new Error("could not get a managed-identity token for monitoring.azure.com");

  const body = {
    time: new Date().toISOString(),
    data: {
      baseData: {
        metric: cfg.metricName,
        namespace: cfg.metricNamespace,
        dimNames: [],
        series: [{ dimValues: [], min: value, max: value, sum: value, count: 1 }],
      },
    },
  };

  const url = `https://${cfg.vmssRegion}.monitoring.azure.com${cfg.vmssResourceId}/metrics`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token.token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`metric POST -> ${res.status} ${text.slice(0, 300)}`);
  }
  log(`published ${cfg.metricNamespace}/${cfg.metricName} = ${value}`);
}
