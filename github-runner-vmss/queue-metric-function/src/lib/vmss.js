// Which VMSS instances currently exist, by OS computer name - so cleanup
// only removes GitHub runner registrations with no matching live instance.

import { DefaultAzureCredential } from "@azure/identity";

const credential = new DefaultAzureCredential();
const ARM = "https://management.azure.com";

export async function liveInstanceHostnames(vmssResourceId) {
  const token = await credential.getToken(`${ARM}/.default`);
  if (!token?.token) throw new Error("could not get a managed-identity token for management.azure.com");

  const names = new Set();
  let next = `${ARM}${vmssResourceId}/virtualMachines?api-version=2024-07-01`;
  while (next) {
    const res = await fetch(next, { headers: { Authorization: `Bearer ${token.token}` } });
    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new Error(`ARM GET virtualMachines -> ${res.status} ${body.slice(0, 300)}`);
    }
    const j = await res.json();
    for (const vm of j.value || []) {
      const cn = vm.properties?.osProfile?.computerName;
      if (cn) names.add(cn.toLowerCase());
    }
    next = j.nextLink || null;
  }
  return names;
}
