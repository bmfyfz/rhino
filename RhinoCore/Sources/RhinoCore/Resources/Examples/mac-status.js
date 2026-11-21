// @name Mac status
// @description Free disk space, battery and uptime, read with shell commands

// shell() runs a command as you would type it in Terminal.
const version = (await shell("sw_vers -productVersion")).text;
const disk = (await shell("df -H / | tail -1")).text.split(/\s+/);
const uptime = (await shell("uptime")).text.replace(/^.*up\s+/, "").replace(/,\s+\d+ users?.*$/, "");
// A desktop Mac has no battery, so this one is allowed to fail.
const battery = await shell("pmset -g batt | grep -Eo '[0-9]+%'", { throwOnError: false });

const status = {
  macOS: version,
  diskSize: disk[1],
  diskFree: disk[3],
  diskUsed: disk[4],
  uptime,
  battery: battery.ok ? battery.text : "none",
};
output.table([
  { What: "macOS", Value: status.macOS },
  { What: "Disk free", Value: `${status.diskFree} of ${status.diskSize} (${status.diskUsed} used)` },
  { What: "Up for", Value: status.uptime },
  { What: "Battery", Value: status.battery },
]).name("This Mac");
output.json(status).name("Status");
