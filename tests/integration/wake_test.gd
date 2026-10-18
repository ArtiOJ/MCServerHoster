extends Node
## End-to-end test for "Start on connect" with a real Paper server and a minimal
## Minecraft protocol client. The same client also pings the real Paper server, which
## validates the packet encoding against the real thing.
## Usage: godot --headless --path . res://tests/integration/wake_test.tscn -- --no-autostart --profile=wk --root=<dir>

var _failures := PackedStringArray()


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://wake-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
	AppSettings.servers_root = root
	AppSettings.server_dirs = PackedStringArray()
	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Wake Test", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 1536, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "motd": "Real Paper MOTD"},
	})
	_check(created.ok, "create server")
	if not created.ok:
		return _finish()
	var inst: ServerInstance = created.instance
	var port := inst.config.port

	inst.config.wake_on_connect = true
	inst.config.wake_motd = "Sleeping test server"
	inst.save_config()
	await _wait_for(func() -> bool: return inst.is_asleep(), 5.0)
	_check(inst.is_asleep() and inst.state_name() == "Asleep", "listening while stopped (state shows Asleep)")

	var status := await _status_ping(port)
	_check(status.get("description", {}).get("text", "") == "Sleeping test server", "server list shows the asleep MOTD")
	_check(str(status.get("version", {}).get("name", "")).begins_with("Asleep"), "version label says Asleep")
	_check(status.get("pong", false), "ping/pong answered")
	await get_tree().create_timer(1.0).timeout
	_check(inst.state == ServerInstance.State.STOPPED, "a server-list ping alone does not start it")

	var kick := await _login(port, "Steve")
	_check(kick.contains("starting"), "join attempt gets a 'starting' message: " + kick)
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "join attempt started the real server")
	_check(not inst.is_asleep(), "listener released the port")

	var real := await _status_ping(port)
	_check(str(real.get("version", {}).get("name", "")).contains("1.21.11") and real.has("description"), "client protocol also works against real Paper (%s)" % real.get("version", {}).get("name", "?"))
	_check(real.get("pong", false), "real Paper answered ping/pong")

	inst.config.events = [EventRule.from_template({"trigger": EventRule.Trigger.SERVER_EMPTY, "threshold": 0.1, "action": EventRule.Action.STOP})]
	inst.save_config()
	await _wait_for(func() -> bool: return inst.is_asleep(), 60.0)
	_check(inst.is_asleep(), "stop-when-empty put it back to sleep (listening again)")

	inst.config.events = []
	inst.config.wake_on_ping = true
	inst.save_config()
	await _status_ping(port)
	await _wait_for(func() -> bool: return inst.is_online(), 200.0)
	_check(inst.is_online(), "wake-on-ping starts the server from a server-list ping")
	inst.stop()
	await _wait_for(func() -> bool: return inst.is_asleep(), 60.0)
	_check(inst.is_asleep(), "asleep again after a manual stop")

	inst.config.wake_on_connect = false
	inst.save_config()
	await get_tree().create_timer(0.5).timeout
	_check(not inst.is_asleep() and PlatformBackend.is_port_free(port), "disabling releases the port")
	_check(inst.state_name() == "Stopped", "state shows Stopped again")

	ServerManager.delete_server(inst.config.id, true, true)
	_finish()


# --- Minimal Minecraft client ---------------------------------------------------

func _connect(port: int) -> StreamPeerTCP:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return peer
		await get_tree().process_frame
	return null


func _read_packet(peer: StreamPeerTCP, buffer: Array) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var pkt := McProtocol.take_packet(buffer[0])
		if not pkt.is_empty() and not pkt.has("error"):
			buffer[0] = (buffer[0] as PackedByteArray).slice(pkt.size)
			return pkt
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			var data: Array = peer.get_partial_data(n)
			var b: PackedByteArray = buffer[0]
			b.append_array(data[1])
			buffer[0] = b
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().process_frame
	return {}


func _status_ping(port: int) -> Dictionary:
	var peer: StreamPeerTCP = await _connect(port)
	if peer == null:
		return {}
	peer.put_data(McProtocol.handshake(774, "localhost", port, McProtocol.STATE_STATUS))
	peer.put_data(McProtocol.packet(0x00))
	var buffer := [PackedByteArray()]
	var resp: Dictionary = await _read_packet(peer, buffer)
	if resp.is_empty():
		return {}
	var parsed = JSON.parse_string(McProtocol.read_string(resp.payload, 0)[0])
	var result: Dictionary = parsed if parsed is Dictionary else {}
	var token := PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	peer.put_data(McProtocol.packet(0x01, token))
	var pong: Dictionary = await _read_packet(peer, buffer)
	result["pong"] = not pong.is_empty() and pong.id == 0x01 and pong.payload == token
	peer.disconnect_from_host()
	return result


func _login(port: int, player: String) -> String:
	var peer: StreamPeerTCP = await _connect(port)
	if peer == null:
		return ""
	peer.put_data(McProtocol.handshake(774, "localhost", port, McProtocol.STATE_LOGIN))
	var start := McProtocol.write_string(player)
	start.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	peer.put_data(McProtocol.packet(0x00, start))
	var resp: Dictionary = await _read_packet(peer, [PackedByteArray()])
	peer.disconnect_from_host()
	if resp.is_empty() or resp.id != 0x00:
		return ""
	return McProtocol.read_string(resp.payload, 0)[0]


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout


func _check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok:
		_failures.append(message)


func _finish() -> void:
	print("\nWake test: %s" % ("OK" if _failures.is_empty() else "%d failure(s)" % _failures.size()))
	get_tree().quit(0 if _failures.is_empty() else 1)
