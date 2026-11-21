// @name Site check
// @description Checks that websites answer, and tells you when one goes down or comes back

// Change the list to your own sites. To have it check by
// itself, add a schedule to the header above, for example
// "@schedule every 15 minutes" on a comment line of its own.
const sites = ["https://www.apple.com", "https://github.com", "https://www.wikipedia.org"];

const before = await memory.get("status", {});
const now = {};
const rows = [];
for (const site of sites) {
  const started = Date.now();
  let up = false;
  let detail = "";
  try {
    const response = await get(site, { throwOnError: false, timeout: 10000 });
    up = response.status < 500;
    detail = `HTTP ${response.status}`;
  } catch (error) {
    detail = error.message;
  }
  now[site] = up;
  rows.push({ Site: site, Status: up ? "Up" : "Down", Detail: detail, "Time ms": Date.now() - started });

  // Only a change is news: nobody wants a notification every 15 minutes.
  if (before[site] !== undefined && before[site] !== up) {
    notify(up ? "Back up" : "Site down", site);
  }
}
await memory.set("status", now);

output.table(rows).name("Sites");
const down = rows.filter((row) => row.Status === "Down");
output.text(down.length === 0 ? `All **${rows.length}** sites are up.` : `**${down.length}** of ${rows.length} sites are down.`).name("Summary");
output.json(now).name("Status");
