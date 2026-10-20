extends TestCase


func test_wake_time_choice() -> void:
	var now := 1_000_000
	check_eq(WakeHelper.wake_time([], now), -1, "nothing to wake for")
	check_eq(WakeHelper.wake_time([now + 3600, now + 600], now), now + 600 - WakeHelper.LEAD_SEC, "earliest event, woken early")
	check_eq(WakeHelper.wake_time([now + 40], now), now + 30, "never in the past")
	check_eq(WakeHelper.wake_time([now - 5, now + 40 * 86400], now), -1, "past and too-far events ignored")


func test_tcp_pattern() -> void:
	var p := WakeHelper.tcp_pattern("D8:B3:2F:C3:06:33", PackedInt32Array([25565]))
	var b := p.split(":")
	check_eq(b.size(), 38, "38 bytes up to the destination port")
	check_eq(":".join(b.slice(0, 6)), "d8:b3:2f:c3:06:33", "destination MAC first")
	check_eq(b[12] + b[13], "0800", "IPv4 ethertype")
	check_eq(b[14], "45", "IPv4 without options")
	check_eq(b[23], "06", "TCP")
	check_eq(b[36] + b[37], "63dd", "port 25565 big-endian")
	check(Array(b.slice(6, 12)).all(func(x: String) -> bool: return x == "-"), "source MAC is a wildcard")
	var near := WakeHelper.tcp_pattern("d8:b3:2f:c3:06:33", PackedInt32Array([2315, 2316, 2324])).split(":")
	check_eq(near[36] + ":" + near[37], "09:-", "ports sharing their high byte: that byte, any low byte")
	var far := WakeHelper.tcp_pattern("d8:b3:2f:c3:06:33", PackedInt32Array([2316, 25565])).split(":")
	check_eq(far[36] + far[37], "--", "ports far apart: any port")
	check_eq(WakeHelper.tcp_pattern("bad", PackedInt32Array([25565])), "", "invalid MAC")


func test_watched_ports() -> void:
	check_eq(WakeHelper.connect_ports([]), PackedInt32Array(), "nothing to wake for")
	check_eq(WakeHelper.connect_ports([], [25590, 25565, 25590]), PackedInt32Array([25565, 25590]), "remote access included, sorted, once each")
	check_eq(WakeHelper.watched_ports_text(PackedInt32Array([2315])), "port 2315", "one port")
	check_eq(WakeHelper.watched_ports_text(PackedInt32Array([2315, 2316])), "ports 2304–2559", "a block of 256")
	check_eq(WakeHelper.watched_ports_text(PackedInt32Array([2316, 25565])), "any port", "far apart")


func test_chosen_wake_block() -> void:
	var p := WakeHelper.tcp_pattern("d8:b3:2f:c3:06:33", PackedInt32Array([25565]), 9).split(":")
	check_eq(p[36] + ":" + p[37], "09:-", "a chosen block wins over the ports in use")
	check_eq(WakeHelper.watched_ports_text(PackedInt32Array([25565]), 9), "ports 2304–2559", "chosen block described")
	check(WakeHelper.block_covers(9, 2314) and WakeHelper.block_covers(9, 2559) and not WakeHelper.block_covers(9, 2560), "block edges")
	check(WakeHelper.block_covers(-1, 25565), "automatic covers everything in use")


func test_helper_script_rejects_bad_arguments() -> void:
	# The root helper validates everything before touching the system; run it as a normal user.
	var path := ProjectSettings.globalize_path("user://wake-helper-test.sh")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(WakeHelper.HELPER_SCRIPT)
	f.close()
	var cases := [
		[["alarm", "abc"], 2], [["alarm", ""], 2], [["alarm", "1"], 2], [["alarm", "99999999999"], 2],
		[["wowlan", "eth0", "off"], 2], [["wowlan", "phy0", "on", "d8:zz"], 2], [["wowlan", "phy0", "on", "$(id)"], 2],
		[["wowlan", "phy0", "maybe"], 2], [["reboot"], 2], [[], 2],
	]
	for c in cases:
		var code := OS.execute("/bin/sh", PackedStringArray([path] + c[0]))
		check_eq(code, c[1], "helper %s" % str(c[0]))
	DirAccess.remove_absolute(path)


func test_policy_points_at_helper() -> void:
	check(WakeHelper.POLICY_XML.contains("<allow_active>yes</allow_active>"), "no password for the active user")
	check(WakeHelper.POLICY_XML.contains("<allow_any>no</allow_any>"), "remote/other sessions are not allowed")
	check(WakeHelper.POLICY_XML.contains('"org.freedesktop.policykit.exec.path">%s<' % WakeHelper.HELPER_PATH), "policy limited to the helper")
	var r := EventRule.from_template({"trigger": EventRule.Trigger.TIME, "action": EventRule.Action.START})
	check(r.wake_computer, "start events wake by default")
	var b := EventRule.from_template({"trigger": EventRule.Trigger.TIME, "action": EventRule.Action.BACKUP_WORLD})
	check(not b.wake_computer, "other events don't")
	check(EventRule.from_dict(r.to_dict()).wake_computer, "round trip")
