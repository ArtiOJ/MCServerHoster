extends Node
## Waking from sleep without sleeping: the root helper is replaced by a recorder and the
## computer's sleep is simulated by feeding PowerManager logind's PrepareForSleep lines.
## Checks the real inhibitor lock (held to arm the wake-up even with no server running),
## the RTC alarm time and the Wi-Fi wake pattern. No Java or network needed.
## Usage: godot --headless --path . res://tests/integration/wake_sleep_test.tscn -- --no-autostart --profile=ws --root=<dir>

var _failures := PackedStringArray()
var _calls: Array = []


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://wake-sleep-test")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	FileOps.remove_path(root)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.wake_for_events = true
	AppSettings.wake_on_connection = true
	var dir := root.path_join("wake")
	DirAccess.make_dir_recursive_absolute(dir)
	var cfg := ServerConfig.new()
	cfg.id = "wake"
	cfg.directory = dir
	cfg.display_name = "Wake"
	cfg.mc_version = "1.21.11"
	cfg.port = 25999
	cfg.wake_on_connect = true
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var local := int(Time.get_unix_time_from_system()) + bias + 20 * 60
	cfg.events = [EventRule.from_template({"trigger": EventRule.Trigger.TIME, "action": EventRule.Action.START,
			"time_of_day": "%02d:%02d" % [posmod(local, 86400) / 3600, posmod(local, 3600) / 60]})]
	cfg.save()
	var inst: ServerInstance = ServerManager.import_server(dir).instance
	await get_tree().process_frame

	PowerManager.wake_runner = func(args: Array) -> Dictionary:
		_calls.append(args)
		return {"ok": true, "message": "ok"}
	PowerManager.update_locks()
	await get_tree().create_timer(0.5).timeout
	_check(_inhibitors().contains("Stopping Minecraft servers cleanly") or _inhibitors().contains("Server Manager"), "sleep delay lock held although no server runs")
	var iface := WakeHelper.wake_interface()
	if iface.get("wireless", false):
		# Armed before any sleep, so NetworkManager sees it and keeps Wi-Fi connected while asleep.
		var early := _calls.filter(func(c: Array) -> bool: return c[0] == "wowlan" and c[2] == "on")
		_check(early.size() == 1 and early[0][3] == WakeHelper.tcp_pattern(iface.mac, PackedInt32Array([25999])), "Wi-Fi wake armed before sleeping, for port 25999 on %s" % iface.phy)
	_calls.clear()

	var due := inst.scheduler.next_run_of(inst.config.events[0])
	PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)")
	await _wait_for(func() -> bool: return _calls.size() >= 1, 5.0)
	await get_tree().create_timer(0.3).timeout
	var alarm := _calls.filter(func(c: Array) -> bool: return c[0] == "alarm")
	_check(alarm.size() == 1 and int(alarm[0][1]) == due - WakeHelper.LEAD_SEC, "RTC alarm set %d s before the start event" % WakeHelper.LEAD_SEC)
	_check(not _calls.any(func(c: Array) -> bool: return c[0] == "wowlan"), "Wi-Fi wake not re-armed at sleep (already armed)")
	await get_tree().create_timer(0.5).timeout
	_check(not _inhibitors().contains("Stopping Minecraft servers cleanly"), "delay lock released so the computer can sleep")

	_calls.clear()
	PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)")
	await _wait_for(func() -> bool: return _calls.size() >= 1, 5.0)
	await get_tree().create_timer(0.5).timeout
	_check(_calls.has(["alarm", "clear"]), "alarm cleared after waking")
	_check(not _calls.any(func(c: Array) -> bool: return c[0] == "wowlan"), "Wi-Fi wake stays armed after waking")
	_calls.clear()

	AppSettings.wake_for_events = false
	AppSettings.wake_on_connection = false
	PowerManager.update_locks()
	await get_tree().create_timer(0.5).timeout
	if iface.get("wireless", false):
		_check(_calls.any(func(c: Array) -> bool: return c[0] == "wowlan" and c[2] == "off"), "Wi-Fi wake cleared when the feature is switched off")
	_check(not _inhibitors().contains("Stopping Minecraft servers cleanly"), "no lock when waking is switched off and no server runs")
	PowerManager.wake_runner = Callable()

	# Wi-Fi recovery: the connection doesn't come back after waking, so the card is restarted
	# (stand-ins for the restart and the connection check; the real card is never touched).
	if iface.get("wireless", false):
		var resets := []
		var online := [false]
		PowerManager.wifi_check_delay_sec = 1.0
		PowerManager.wifi_recheck_sec = 1.0
		PowerManager.network_probe = func(_i: String) -> bool: return online[0]
		PowerManager.wifi_runner = func(pci: String) -> Dictionary:
			resets.append(pci)
			online[0] = true
			return {"ok": true, "message": "ok"}
		PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)")
		await get_tree().create_timer(0.5).timeout
		PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)")
		await _wait_for(func() -> bool: return not resets.is_empty(), 5.0)
		_check(resets.size() == 1 and WakeHelper.pci_address(iface.interface) == resets[0], "Wi-Fi card restarted when the connection didn't come back (%s)" % [resets])
		await get_tree().create_timer(1.5).timeout
		resets.clear()
		PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)")
		await get_tree().create_timer(0.5).timeout
		PowerManager.handle_monitor_line("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)")
		await get_tree().create_timer(2.0).timeout
		_check(resets.is_empty(), "left alone when the connection came back by itself")
		PowerManager.wifi_runner = Callable()
		PowerManager.network_probe = Callable()

	ServerManager.delete_server(inst.config.id, true, true)
	FileOps.remove_path(root)
	print("\nWake sleep test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)


## This test's own sleep locks (another Server Manager running on the computer has its own).
func _inhibitors() -> String:
	var out: Array = []
	OS.execute("systemd-inhibit", ["--list", "--no-pager", "--no-legend"], out)
	# Columns: who (may contain spaces), uid, user, pid (the systemd-inhibit process), …
	var row := RegEx.create_from_string("^(.*?)\\s+(\\d+)\\s+(\\S+)\\s+(\\d+)\\s")
	var mine := PackedStringArray()
	for line in (str(out[0]) if not out.is_empty() else "").split("\n", false):
		var m := row.search(line)
		if m != null and _parent_pid(m.get_string(4).to_int()) == OS.get_process_id():
			mine.append(line)
	return "\n".join(mine)


func _parent_pid(pid: int) -> int:
	var out: Array = []
	OS.execute("ps", ["-o", "ppid=", "-p", str(pid)], out)
	return str(out[0]).strip_edges().to_int() if not out.is_empty() and str(out[0]).strip_edges() != "" else -1


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)
