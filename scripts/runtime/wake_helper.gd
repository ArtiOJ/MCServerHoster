class_name WakeHelper
extends RefCounted
## Waking the computer from sleep. Writing the RTC wake alarm and configuring Wi-Fi
## wake-on-WLAN need root, so a one-time setup installs a tiny root-owned helper that
## can only do those two things, plus a polkit action that lets the active desktop user
## run it without a password. Everything else here is unprivileged and unit-tested.

const HELPER_PATH := "/usr/local/libexec/server-manager-wake"
const POLICY_PATH := "/usr/share/polkit-1/actions/io.github.servermanager.wake.policy"
## Wake this long before a scheduled event so the computer and the app are ready in time.
const LEAD_SEC := 90
## The kernel's RTC alarm is limited; Minecraft schedules beyond a month are not worth it.
const MAX_AHEAD_SEC := 30 * 86400

const HELPER_SCRIPT := """#!/bin/sh
# Server Manager wake helper (installed once, run through pkexec).
# Only sets or clears the RTC wake alarm and Wi-Fi wake-on-WLAN; validates every argument.
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
  *) echo "usage: alarm <epoch>|clear | wowlan <phy> on <pattern>|off" >&2; exit 2 ;;
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


## True when the helper and its polkit action are installed and up to date.
static func is_installed() -> bool:
	return FileAccess.file_exists(HELPER_PATH) and FileAccess.file_exists(POLICY_PATH) \
			and FileAccess.get_file_as_string(HELPER_PATH) == HELPER_SCRIPT


## Human-readable list of what [method install] puts on the system.
static func install_summary() -> String:
	return "• %s — a short root script that can only set or clear the wake alarm and Wi-Fi wake-up.\n• %s — lets you run that script without a password while you are logged in at this computer." % [HELPER_PATH, POLICY_PATH]


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
	var arg := "clear" if epoch < 0 else str(epoch)
	return _run(["alarm", arg])


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


## Wake-on-WLAN pattern for an incoming TCP packet to [param port] (0 = any TCP port) for the
## interface with MAC [param mac], in iw syntax ("-" = don't care). nl80211 matches patterns
## against the 802.3 (Ethernet II) form of the frame from offset 0:
## [0-5] destination MAC, [12-13] 08:00 IPv4, [14] 45 (IPv4, no options), [23] 06 TCP,
## [36-37] destination port. TCP flags are left out on purpose: ECN-capable clients send
## SYN with extra flag bits.
static func tcp_pattern(mac: String, port: int) -> String:
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
	if port > 0:
		parts.append("%02x" % ((port >> 8) & 0xFF))
		parts.append("%02x" % (port & 0xFF))
	else:
		parts.append_array(["-", "-"])
	return ":".join(parts)


## The network interface that leads to the router and whether it can wake the computer:
## {interface, wireless, phy, mac}. Empty when unknown.
static func wake_interface() -> Dictionary:
	var route := PlatformBackend.get_current().default_route()
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


## Port to watch for wake-on-connect: the single start-on-connect server's port, 0 when
## several servers use different ports (wake on any TCP connection), -1 when none.
static func connect_port(instances: Array) -> int:
	var ports := {}
	for inst: ServerInstance in instances:
		if inst.config.wake_on_connect:
			ports[inst.config.port] = true
	if ports.is_empty():
		return -1
	return ports.keys()[0] if ports.size() == 1 else 0
