class_name WakeHelper
extends RefCounted
## Waking the computer from sleep. Writing the RTC wake alarm, configuring Wi-Fi
## wake-on-WLAN and restarting a Wi-Fi card that came back from sleep stuck need root, so a
## one-time setup installs a tiny root-owned helper that can only do those things, plus a
## polkit action that lets the active desktop user run it without a password. Everything
## else here is unprivileged and unit-tested. Older helpers keep working for what they can
## do; Preferences offers to update them.

const HELPER_PATH := "/usr/local/libexec/server-manager-wake"
const POLICY_PATH := "/usr/share/polkit-1/actions/io.github.servermanager.wake.policy"
## Wake this long before a scheduled event so the computer and the app are ready in time.
const LEAD_SEC := 90
## The kernel's RTC alarm is limited; Minecraft schedules beyond a month are not worth it.
const MAX_AHEAD_SEC := 30 * 86400

## First lines of every version of the helper.
const HELPER_HEADER := "#!/bin/sh\n# Server Manager wake helper"
const HELPER_SCRIPT := """#!/bin/sh
# Server Manager wake helper (installed once, run through pkexec).
# Only sets or clears the RTC wake alarm and Wi-Fi wake-on-WLAN, and restarts a Wi-Fi card
# (a PCI device of the wireless network class); validates every argument.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
ALARM=/sys/class/rtc/rtc0/wakealarm
case "${1:-}" in
  alarm)
    arg="${2:-}"
    case "$arg" in
      clear) echo 0 > "$ALARM" ;;
      ''|*[!0-9]*) echo "invalid time" >&2; exit 2 ;;
      *)
        now=$(date +%s)
        if [ "$arg" -le "$now" ] || [ "$arg" -gt $((now + 2678400)) ]; then echo "time out of range" >&2; exit 2; fi
        echo 0 > "$ALARM"
        echo "$arg" > "$ALARM" ;;
    esac ;;
  wowlan)
    phy="${2:-}"
    case "$phy" in phy[0-9]|phy[0-9][0-9]) ;; *) echo "invalid phy" >&2; exit 2 ;; esac
    case "${3:-}" in
      off) iw phy "$phy" wowlan disable ;;
      on)
        pattern="${4:-}"
        case "$pattern" in ''|*[!0-9a-f:-]*) echo "invalid pattern" >&2; exit 2 ;; esac
        iw phy "$phy" wowlan enable magic-packet patterns "$pattern" ;;
      *) echo "usage: wowlan <phy> on <pattern>|off" >&2; exit 2 ;;
    esac ;;
  wifi-reset)
    dev="${2:-}"
    case "$dev" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f].[0-7]) ;; *) echo "invalid device" >&2; exit 2 ;; esac
    sys="/sys/bus/pci/devices/$dev"
    if [ ! -e "$sys/class" ]; then echo "no such device" >&2; exit 2; fi
    case "$(cat "$sys/class")" in 0x0280*) ;; *) echo "not a wireless network card" >&2; exit 2 ;; esac
    # Reload the driver first; a card whose firmware stays stuck is removed and found again.
    drv=""
    if [ -L "$sys/driver" ]; then drv=$(basename "$(readlink "$sys/driver")"); fi
    case "$drv" in ''|*[!a-z0-9_]*) drv="" ;; esac
    if [ -n "$drv" ] && modprobe -r "$drv" 2>/dev/null; then
      sleep 2
      modprobe "$drv" || true
      i=0
      while [ "$i" -lt 15 ]; do
        if [ -n "$(ls "$sys/net" 2>/dev/null || true)" ]; then exit 0; fi
        sleep 1
        i=$((i + 1))
      done
    fi
    if [ -e "$sys/remove" ]; then echo 1 > "$sys/remove"; fi
    sleep 2
    echo 1 > /sys/bus/pci/rescan ;;
  *) echo "usage: alarm <epoch>|clear | wowlan <phy> on <pattern>|off | wifi-reset <pci address>" >&2; exit 2 ;;
esac
"""

const POLICY_XML := """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>Server Manager</vendor>
  <action id="io.github.servermanager.wake">
    <description>Set when this computer wakes from sleep for Minecraft servers</description>
    <message>Server Manager wants to set when this computer wakes from sleep</message>
    <defaults>
      <allow_any>no</allow_any>
      <allow_inactive>no</allow_inactive>
      <allow_active>yes</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/libexec/server-manager-wake</annotate>
  </action>
</policyconfig>
"""


## Task Scheduler entry that wakes Windows for the next flagged event.
const WINDOWS_TASK := "Server Manager wake-up"


## True when the helper and its polkit action are installed and up to date. Windows needs
## no setup: wake-ups are scheduled tasks of the user.
## True when some version of the helper is installed (enough for alarms and Wi-Fi wake-up).
static func is_installed() -> bool:
	if OS.get_name() == "Windows":
		return true
	return FileAccess.file_exists(HELPER_PATH) and FileAccess.file_exists(POLICY_PATH) \
			and FileAccess.get_file_as_string(HELPER_PATH).begins_with(HELPER_HEADER)


## True when the installed helper is this version (it can also restart the Wi-Fi card).
static func is_current() -> bool:
	if OS.get_name() == "Windows":
		return true
	return is_installed() and FileAccess.get_file_as_string(HELPER_PATH) == HELPER_SCRIPT


## Restarts the Wi-Fi card at PCI address [param pci] (reload its driver, else remove and
## rescan it). Blocking: run on a worker thread. Returns {ok, message}.
static func reset_wifi(pci: String) -> Dictionary:
	if not is_current():
		return {"ok": false, "message": "The wake-up helper needs an update to restart the Wi-Fi card."}
	return _run(["wifi-reset", pci])


## The PCI address of network interface [param iface] ("0000:0d:00.0"), or "".
static func pci_address(iface: String) -> String:
	var dir := DirAccess.open("/sys/class/net/%s" % iface)
	if dir == null:
		return ""
	var target := dir.read_link("/sys/class/net/%s/device" % iface)
	var address := target.get_file()
	return address if RegEx.create_from_string("^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\\.[0-7]$").search(address) != null else ""


## Human-readable list of what [method install] puts on the system.
static func install_summary() -> String:
	return "• %s — a short root script that can only set or clear the wake alarm and Wi-Fi wake-up, and restart a Wi-Fi card that came back from sleep stuck.\n• %s — lets you run that script without a password while you are logged in at this computer." % [HELPER_PATH, POLICY_PATH]


## Installs the helper and polkit action (one password prompt). Blocking: run on a worker thread.
## Returns {ok, message}.
static func install(staging_dir: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(staging_dir)
	var script_src := staging_dir.path_join("server-manager-wake")
	var policy_src := staging_dir.path_join("io.github.servermanager.wake.policy")
	for pair in [[script_src, HELPER_SCRIPT], [policy_src, POLICY_XML]]:
		var f := FileAccess.open(pair[0], FileAccess.WRITE)
		if f == null:
			return {"ok": false, "message": "Could not prepare the files (%s)." % error_string(FileAccess.get_open_error())}
		f.store_string(pair[1])
		f.close()
	var cmd := 'install -D -o root -g root -m 0755 "$1" %s && install -D -o root -g root -m 0644 "$2" %s' % [HELPER_PATH, POLICY_PATH]
	var code := PlatformBackend.execute("pkexec", ["/bin/sh", "-c", cmd, "sh", script_src, policy_src])
	DirAccess.remove_absolute(script_src)
	DirAccess.remove_absolute(policy_src)
	return _result(code, "Wake-up helper installed.", is_installed())


## Removes the helper and polkit action (one password prompt). Blocking.
static func uninstall() -> Dictionary:
	var code := PlatformBackend.execute("pkexec", ["/bin/rm", "-f", HELPER_PATH, POLICY_PATH])
	return _result(code, "Wake-up helper removed.", not FileAccess.file_exists(HELPER_PATH))


## Sets the RTC wake alarm ([param epoch] = unix time) or clears it (-1). Blocking but quick.
static func set_alarm(epoch: int) -> Dictionary:
	if OS.get_name() == "Windows":
		return _windows_alarm(epoch)
	var arg := "clear" if epoch < 0 else str(epoch)
	return _run(["alarm", arg])


## A one-off scheduled task with "wake the computer to run this task" (needs wake timers
## allowed in the power plan, which they are on mains power by default).
static func _windows_alarm(epoch: int) -> Dictionary:
	var script := "Unregister-ScheduledTask -TaskName '%s' -Confirm:$false -ErrorAction SilentlyContinue\n" % WINDOWS_TASK
	if epoch > 0:
		script += ("$t = New-ScheduledTaskTrigger -Once -At ([DateTimeOffset]::FromUnixTimeSeconds(%d).LocalDateTime)\n" % epoch
			+ "$s = New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries\n"
			+ "$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c exit'\n"
			+ "Register-ScheduledTask -TaskName '%s' -Trigger $t -Settings $s -Action $a -Force | Out-Null\n" % WINDOWS_TASK
			+ "if ($?) { 'ok' } else { 'failed' }")
	else:
		script += "'ok'"
	var out := WindowsBackend.run_powershell(script)
	return {"ok": out.ends_with("ok"), "message": "ok" if out.ends_with("ok") else "Task Scheduler refused the wake-up task (%s)." % out}


## Enables wake-on-WLAN with [param pattern] (and magic packets) on [param phy], or disables it ("").
static func set_wowlan(phy: String, pattern: String) -> Dictionary:
	return _run(["wowlan", phy, "on", pattern] if pattern != "" else ["wowlan", phy, "off"])


static func _run(args: Array) -> Dictionary:
	if not is_installed():
		return {"ok": false, "message": "The wake-up helper is not installed."}
	var output: Array = []
	var code := PlatformBackend.execute("pkexec", PackedStringArray([HELPER_PATH] + args), output, true)
	var text := str(output[0]).strip_edges() if not output.is_empty() else ""
	return {"ok": code == 0, "message": text if code != 0 else "ok", "code": code}


static func _result(code: int, success: String, confirmed: bool) -> Dictionary:
	if code == 0 and confirmed:
		return {"ok": true, "message": success}
	if code == 126 or code == 127:
		return {"ok": false, "message": "The password prompt was cancelled or the password was not accepted."}
	return {"ok": false, "message": "The command failed (exit code %d)." % code}


# --- Pure logic (unit-tested) ---------------------------------------------------------

## When to wake for the next scheduled event that asks for it, as unix time, or -1.
## [param candidates] are unix times of upcoming flagged events.
static func wake_time(candidates: Array, now: int) -> int:
	var best := -1
	for t in candidates:
		var at := int(t)
		if at <= now or at - now > MAX_AHEAD_SEC:
			continue
		if best < 0 or at < best:
			best = at
	if best < 0:
		return -1
	# Wake a little early, but never in the past (the helper refuses that).
	return maxi(best - LEAD_SEC, now + 30)


## Wake-on-WLAN pattern for an incoming TCP packet to any of [param ports] for the interface
## with MAC [param mac], in iw syntax ("-" = don't care). nl80211 matches patterns against
## the 802.3 (Ethernet II) form of the frame from offset 0:
## [0-5] destination MAC, [12-13] 08:00 IPv4, [14] 45 (IPv4, no options), [23] 06 TCP,
## [36-37] destination port. Cards take one pattern of exact-or-any bytes, so several ports
## are matched by their shared high byte (see [method port_bytes]). TCP flags are left out on
## purpose: ECN-capable clients (e.g. macOS) send SYN with extra flag bits.
## A [param block] of 0–255 (see AppSettings.wake_port_block) watches that block of 256 ports
## whatever [param ports] are.
static func tcp_pattern(mac: String, ports: PackedInt32Array, block := -1) -> String:
	var parts := PackedStringArray()
	var mac_bytes := mac.to_lower().split(":")
	if mac_bytes.size() != 6:
		return ""
	parts.append_array(mac_bytes)
	for i in range(6, 12):
		parts.append("-")
	parts.append_array(["08", "00", "45"])
	for i in range(15, 23):
		parts.append("-")
	parts.append("06")
	for i in range(24, 36):
		parts.append("-")
	for b in ([block, -1] if block >= 0 else port_bytes(ports)):
		parts.append("%02x" % b if b >= 0 else "-")
	return ":".join(parts)


## The destination-port bytes a single pattern can match for [param ports] ([high, low], -1 =
## any): the port itself, the shared high byte (a block of 256 ports, e.g. 2304–2559), or any.
static func port_bytes(ports: PackedInt32Array) -> Array:
	if ports.size() == 1:
		return [(ports[0] >> 8) & 0xFF, ports[0] & 0xFF]
	var high := (ports[0] >> 8) & 0xFF if not ports.is_empty() else -1
	for p in ports:
		if (p >> 8) & 0xFF != high:
			return [-1, -1]
	return [high, -1]


## "port 2315", "ports 2304–2559" or "any port", for what [method tcp_pattern] watches.
static func watched_ports_text(ports: PackedInt32Array, block := -1) -> String:
	if block >= 0:
		return "ports %s" % block_range_text(block)
	var b := port_bytes(ports)
	if b[0] < 0:
		return "any port"
	if b[1] >= 0:
		return "port %d" % ports[0]
	return "ports %s" % block_range_text(b[0])


## "2304–2559" for block 9.
static func block_range_text(block: int) -> String:
	return "%d–%d" % [block << 8, (block << 8) + 255]


## Whether a connection to [param port] wakes the computer with [param block] chosen.
static func block_covers(block: int, port: int) -> bool:
	return block < 0 or (port >> 8) & 0xFF == block


## The network interface that leads to the router and whether it can wake the computer:
## {interface, wireless, phy, mac}. Empty when unknown.
static func wake_interface() -> Dictionary:
	var route := PlatformBackend.get_current().default_route()
	if OS.get_name() == "Windows":
		if route.is_empty():
			return {}
		return {"interface": str(route.get("interface", "")), "wireless": bool(route.get("wireless", false)), "phy": "", "mac": str(route.get("mac", ""))}
	var iface := str(route.get("interface", ""))
	if iface == "":
		return {}
	var base := "/sys/class/net/%s" % iface
	var phy := PlatformBackend.read_text(base.path_join("phy80211/name")).strip_edges()
	return {
		"interface": iface,
		"wireless": phy != "",
		"phy": phy,
		"mac": PlatformBackend.read_text(base.path_join("address")).strip_edges(),
	}


## Unix times of the next runs of timed events flagged "wake computer" across all servers.
static func flagged_event_times(instances: Array) -> Array:
	var out: Array = []
	for inst: ServerInstance in instances:
		for rule in inst.config.events:
			if rule.enabled and rule.wake_computer and rule.is_timed():
				var t := inst.scheduler.next_run_of(rule)
				if t > 0:
					out.append(t)
	return out


## Ports to watch for wake-on-connect: the start-on-connect servers' ports plus
## [param extra_ports] (e.g. remote access), sorted; empty when none.
static func connect_ports(instances: Array, extra_ports: Array = []) -> PackedInt32Array:
	var ports := {}
	for inst: ServerInstance in instances:
		if inst.config.wake_on_connect:
			ports[inst.config.port] = true
	for p in extra_ports:
		ports[int(p)] = true
	var out := PackedInt32Array(ports.keys())
	out.sort()
	return out
