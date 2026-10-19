class_name RemoteSession
extends Node
## One person connected to this computer: runs the handshake (certificate bootstrap or TLS
## plus key proof), then answers their requests, each checked against their access key,
## and receives server events from [code]RemoteAccess[/code] (its parent).

enum Phase { MODE, BOOTSTRAP, TLS, AUTH, READY, CLOSING }

const HANDSHAKE_TIMEOUT_MSEC := 10000
## A client pings every 15 s; silence for this long means the connection is dead.
const IDLE_TIMEOUT_MSEC := 60000
const MAX_COMMAND_LENGTH := 2000
const MAX_ICON_BYTES := 256 * 1024
const MAX_FILE_BYTES := 4 * 1024 * 1024

var grant: RemoteGrant
var address := ""
var connected_unix := 0

var _channel: RemoteChannel
var _phase := Phase.MODE
var _deadline_msec := 0
var _last_heard_msec := 0
var _host_nonce := ""
## Servers this session has been told about.
var _visible := {}
var _in_flight := 0


func setup(channel: RemoteChannel) -> void:
	_channel = channel
	_channel.framed = false
	address = channel.remote_address
	_deadline_msec = Time.get_ticks_msec() + HANDSHAKE_TIMEOUT_MSEC
	_last_heard_msec = Time.get_ticks_msec()


func is_ready_session() -> bool:
	return _phase == Phase.READY


## True when this session shows [param server_id].
func sees(server_id: String) -> bool:
	return _phase == Phase.READY and _visible.has(server_id)


func send(msg: Dictionary) -> void:
	_channel.send(msg)


func flush_now() -> void:
	_channel.poll()


## Tells the client why and disconnects it. Without [param retry] the client stops trying
## (e.g. its key was revoked).
func kick(reason: String, retry := true) -> void:
	if _phase == Phase.CLOSING:
		return
	_channel.send({"t": "bye", "reason": reason, "retry": retry})
	_channel.close_after_flush()
	_set_closing()


## Re-checks which servers the key opens and tells the client about changes.
func refresh_access() -> void:
	if _phase != Phase.READY:
		return
	var now := {}
	for inst in ServerManager.get_instances():
		if grant.can_access(inst.config.id):
			now[inst.config.id] = inst
	for id in _visible.keys():
		if not now.has(id):
			_visible.erase(id)
			send({"ev": "removed", "server": id})
	for id in now:
		if not _visible.has(id):
			_visible[id] = true
			send({"ev": "added", "data": _full_snapshot(now[id])})


func _process(_delta: float) -> void:
	var messages := _channel.poll()
	if _channel.is_closed():
		_finish()
		return
	if _phase == Phase.MODE:
		_read_mode()
	elif _phase == Phase.TLS and _channel.is_secure():
		_host_nonce = RemoteProtocol.nonce()
		_phase = Phase.AUTH
		send({"t": "hello", "v": RemoteProtocol.VERSION, "nonce": _host_nonce, "name": _host().computer_name})
	if not messages.is_empty():
		_last_heard_msec = Time.get_ticks_msec()
	for msg in messages:
		if _phase == Phase.CLOSING:
			break
		_on_message(msg)
	var now := Time.get_ticks_msec()
	if _phase != Phase.READY and _phase != Phase.CLOSING and now > _deadline_msec:
		_channel.close("Handshake timed out.")
	elif _phase == Phase.READY and now - _last_heard_msec > IDLE_TIMEOUT_MSEC:
		_channel.close("No response.")


func _host() -> Node:
	return get_parent()


func _read_mode() -> void:
	var mode := _channel.take_byte()
	if mode < 0:
		return
	_channel.framed = true
	if mode == RemoteProtocol.MODE_BOOTSTRAP:
		_phase = Phase.BOOTSTRAP
	elif mode == RemoteProtocol.MODE_TLS:
		var id: Dictionary = _host().identity()
		_channel.start_tls_server(id.key, id.cert)
		_phase = Phase.TLS
	else:
		_channel.close("Not a Server Manager connection.")


func _on_message(msg: Dictionary) -> void:
	match _phase:
		Phase.BOOTSTRAP:
			_on_bootstrap(msg)
		Phase.AUTH:
			_on_auth(msg)
		Phase.READY:
			if str(msg.get("t", "")) == "ping":
				send({"t": "pong"})
			elif msg.has("id") and msg.has("op"):
				_handle_request(msg)
		_:
			_channel.close("Unexpected message.")


## Hands out this computer's certificate, proved genuine with the access key so a
## man in the middle cannot substitute his own.
func _on_bootstrap(msg: Dictionary) -> void:
	var g: RemoteGrant = _host().find_grant(str(msg.get("key", "")))
	var client_nonce := str(msg.get("nonce", ""))
	if str(msg.get("t", "")) != "cert" or g == null or client_nonce.length() < 16:
		_host().record_failure(address)
		_deny("Unknown access key. It may have been revoked.")
		return
	var pem: String = _host().identity().pem
	send({"t": "cert", "pem": pem, "proof": RemoteProtocol.proof(g.secret, "cert", [client_nonce, pem]), "name": _host().computer_name})
	_channel.close_after_flush()
	_set_closing()


func _on_auth(msg: Dictionary) -> void:
	if str(msg.get("t", "")) != "auth":
		_deny("Unexpected message.")
		return
	if int(msg.get("v", 0)) != RemoteProtocol.VERSION:
		_deny("This computer runs a different version of Server Manager (protocol %d, yours %d). Update both to the same version." % [RemoteProtocol.VERSION, int(msg.get("v", 0))])
		return
	var g: RemoteGrant = _host().find_grant(str(msg.get("key", "")))
	var client_nonce := str(msg.get("nonce", ""))
	var expected := RemoteProtocol.proof(g.secret, "client", [_host_nonce, client_nonce, g.id]) if g != null else ""
	if g == null or client_nonce.length() < 16 or not RemoteProtocol.proofs_equal(expected, str(msg.get("proof", ""))):
		_host().record_failure(address)
		_deny("The access key was not accepted. It may have been revoked.")
		return
	grant = g
	connected_unix = int(Time.get_unix_time_from_system())
	_channel.reader.max_frame = RemoteProtocol.MAX_FRAME
	_phase = Phase.READY
	var servers: Array = []
	for inst in ServerManager.get_instances():
		if grant.can_access(inst.config.id):
			_visible[inst.config.id] = true
			servers.append(_full_snapshot(inst))
	send({
		"t": "welcome", "proof": RemoteProtocol.proof(g.secret, "host", [client_nonce, _host_nonce]),
		"name": _host().computer_name, "role": int(grant.role), "grant_name": grant.name,
		"servers": servers, "host": _host().host_stats() if grant.is_system_admin() else {},
	})
	_host().record_success(self)


func _deny(reason: String) -> void:
	send({"t": "denied", "reason": reason})
	_channel.close_after_flush()
	_set_closing()


func _set_closing() -> void:
	var was_ready := _phase == Phase.READY
	_phase = Phase.CLOSING
	if was_ready:
		_host().on_session_closed(self, true)


func _finish() -> void:
	if _phase == Phase.READY:
		_host().on_session_closed(self, true)
	_phase = Phase.CLOSING
	set_process(false)
	# Requests still running finish first; their replies go nowhere.
	while _in_flight > 0:
		await get_tree().create_timer(0.5).timeout
	queue_free()


func _full_snapshot(inst: ServerInstance) -> Dictionary:
	var data: Dictionary = _host().snapshot(inst)
	data["console"] = _host().console_snapshot(inst)
	data["cpu_history"] = Array(inst.cpu_history())
	data["ram_history"] = Array(inst.ram_history())
	return data


# --- Requests ------------------------------------------------------------------------

func _handle_request(msg: Dictionary) -> void:
	var req_id := int(msg.get("id", 0))
	var op := str(msg.get("op", ""))
	var server_id := str(msg.get("server", ""))
	var args: Dictionary = msg.get("args", {}) if msg.get("args", {}) is Dictionary else {}
	var reply := {}
	if not RemoteProtocol.OPS.has(op):
		reply = {"ok": false, "error": "Unknown request \"%s\"." % op}
	elif not RemoteProtocol.allows(grant.role, op):
		reply = {"ok": false, "error": "Your access key (%s) does not allow that." % grant.role_name().to_lower()}
	elif RemoteProtocol.HOST_OPS.has(op):
		_in_flight += 1
		reply = await _host_request(op, args, req_id)
		_in_flight -= 1
	else:
		var inst := ServerManager.get_instance(server_id)
		if inst == null or not grant.can_access(server_id):
			reply = {"ok": false, "error": "That server is not available to you."}
		else:
			_in_flight += 1
			reply = await _server_request(op, inst, args, req_id)
			_in_flight -= 1
	if _phase == Phase.READY:
		reply["re"] = req_id
		send(reply)


func _progress_sender(req_id: int) -> Callable:
	return func(text: String, fraction: float) -> void:
		if _phase == Phase.READY:
			send({"ev": "progress", "re": req_id, "text": text, "fraction": fraction})


## Logs a remote action in the server's console so the owner sees who did what.
func _audit(inst: ServerInstance, what: String) -> void:
	inst.log_system("%s (remote) %s" % [grant.name, what])


func _server_request(op: String, inst: ServerInstance, args: Dictionary, req_id: int) -> Dictionary:
	match op:
		"start":
			var temporary := bool(args.get("temporary", false))
			_audit(inst, "resumed the temporary copy." if temporary else "started the server.")
			return _start_result(inst, inst.start(temporary))
		"start_temporary":
			_audit(inst, "started a temporary copy.")
			return _start_result(inst, await inst.start_temporary())
		"finish_temporary":
			var keep := bool(args.get("keep", false))
			_audit(inst, "chose to %s the temporary run." % ("keep" if keep else "discard"))
			var err: Error = await inst.finish_temporary(keep)
			return {"ok": err == OK, "error": "" if err == OK else "Could not finish the temporary run (%s)." % error_string(err)}
		"stop":
			_audit(inst, "stopped the server.")
			inst.stop()
			return {"ok": true}
		"restart":
			_audit(inst, "restarted the server.")
			inst.restart()
			return {"ok": true}
		"kill":
			_audit(inst, "killed the server process.")
			inst.kill()
			return {"ok": true}
		"command":
			var text := str(args.get("text", "")).strip_edges()
			if text == "" or text.length() > MAX_COMMAND_LENGTH or text.contains("\n"):
				return {"ok": false, "error": "Invalid command."}
			if not inst.can_send_commands():
				return {"ok": false, "error": "The server is not accepting commands right now."}
			return {"ok": inst.send_remote_command(text, "%s, remote" % grant.name)}
		"stop_orphan":
			_audit(inst, "stopped the leftover server process.")
			await inst.stop_orphan()
			return {"ok": true}
		"update_paper":
			var version := str(args.get("version", ""))
			var build := int(args.get("build", 0))
			if version == "" or build <= 0:
				return {"ok": false, "error": "Invalid Paper version or build."}
			_audit(inst, "is installing Paper %s build #%d." % [version, build])
			return await inst.update_paper(version, build, bool(args.get("backup", true)), _progress_sender(req_id))
		"check_updates":
			await ServerManager.check_updates()
			return {"ok": true, "update_build": inst.update_available_build}
		"icon_get":
			var path := ServerIcon.icon_path(inst.config.directory)
			var bytes := FileAccess.get_file_as_bytes(path) if FileAccess.file_exists(path) else PackedByteArray()
			if bytes.size() > MAX_ICON_BYTES:
				bytes = PackedByteArray()
			return {"ok": true, "png": Marshalls.raw_to_base64(bytes) if not bytes.is_empty() else ""}
		"icon_set":
			var b64 := str(args.get("png", ""))
			if b64.length() > MAX_ICON_BYTES * 2:
				return {"ok": false, "error": "The icon is too large."}
			var png := Marshalls.base64_to_raw(b64) if b64 != "" else PackedByteArray()
			_audit(inst, "changed the server icon." if not png.is_empty() else "removed the server icon.")
			var err := inst.set_icon_png(png)
			return {"ok": err == OK, "error": "" if err == OK else "The icon must be a 64×64 PNG image."}
		"settings_get":
			return inst.settings_snapshot()
		"settings_save":
			var changes: Dictionary = args.get("changes", {}) if args.get("changes", {}) is Dictionary else {}
			if changes.is_empty():
				return {"ok": true, "rules_applied": false, "restart_needed": false}
			_audit(inst, "changed %d setting%s: %s." % [changes.size(), "" if changes.size() == 1 else "s", ", ".join(PackedStringArray(changes.keys()))])
			return inst.save_settings(changes)
		"file_read":
			return inst.read_config_file(str(args.get("file", "")))
		"file_write":
			var text := str(args.get("text", ""))
			if text.to_utf8_buffer().size() > MAX_FILE_BYTES:
				return {"ok": false, "error": "The file is too large."}
			var file := str(args.get("file", ""))
			_audit(inst, "edited %s." % file)
			return inst.write_config_file(file, text)
		"delete":
			_audit(inst, "is deleting the server.")
			var name := inst.config.display_name
			var err := ServerManager.delete_server(inst.config.id, bool(args.get("files", true)), bool(args.get("backups", false)))
			if err == OK:
				Notifier.info("%s (remote) deleted %s." % [grant.name, name], Notifier.Category.REMOTE)
			return {"ok": err == OK, "error": "" if err == OK else ("Stop the server before deleting it." if err == ERR_BUSY else "Could not delete the server (%s)." % error_string(err))}
		"duplicate":
			var copy_name := str(args.get("name", "")).strip_edges().left(64)
			if copy_name == "":
				return {"ok": false, "error": "The copy needs a name."}
			_audit(inst, "is duplicating the server as \"%s\"." % copy_name)
			var progress := _progress_sender(req_id)
			var res: Dictionary = await ServerManager.duplicate_server(inst, copy_name, bool(args.get("worlds", true)), bool(args.get("plugins", true)),
					func(text: String) -> void: progress.call(text, -1.0))
			return {"ok": res.ok, "error": res.get("error", ""), "server": res.instance.config.id if res.ok else ""}
	return {"ok": false, "error": "Unknown request."}


func _host_request(op: String, args: Dictionary, req_id: int) -> Dictionary:
	match op:
		"create_server":
			return await _create_server(args, req_id)
		"start_all":
			ServerManager.start_all()
			return {"ok": true}
		"stop_all":
			ServerManager.stop_all()
			return {"ok": true}
	return {"ok": false, "error": "Unknown request."}


func _start_result(inst: ServerInstance, err: Error) -> Dictionary:
	match err:
		OK:
			return {"ok": true}
		ERR_ALREADY_IN_USE:
			return {"ok": false, "error": "%s is already running." % inst.config.display_name}
		ERR_UNAVAILABLE:
			return {"ok": false, "error": "A temporary copy is waiting for a keep/discard decision."}
	var problem := inst.start_problem()
	return {"ok": false, "error": problem if problem != "" else "Could not start the server (%s)." % error_string(err)}


## Creates a server from the wizard's choices. The Paper build is looked up here, never
## taken from the client, so only genuine PaperMC downloads are installed.
func _create_server(args: Dictionary, req_id: int) -> Dictionary:
	var spec_in: Dictionary = args.get("spec", {}) if args.get("spec", {}) is Dictionary else {}
	var name := str(spec_in.get("name", "")).strip_edges().left(64)
	var version := str(spec_in.get("version", ""))
	var build_id := int(spec_in.get("build_id", 0))
	if name == "" or version == "" or build_id <= 0:
		return {"ok": false, "error": "Name, version and build are required."}
	var progress := _progress_sender(req_id)
	progress.call("Looking up Paper %s…" % version, 0.0)
	var info: Dictionary = await PaperApi.fetch_version_info(version)
	var found: Dictionary = await PaperApi.fetch_build(version, build_id)
	if not info.get("ok", false) or not found.get("ok", false):
		return {"ok": false, "error": "Could not load Paper %s build #%d: %s" % [version, build_id, found.get("error", info.get("error", ""))]}
	var spec := {
		"name": name, "version": version, "build": found.build, "version_info": info,
		"color": Color.from_string(str(spec_in.get("color", "3fb97f")), Color("3fb97f")),
		"ram_max_mb": clampi(int(spec_in.get("ram_max_mb", AppSettings.default_ram_mb)), 512, 1048576),
		"ram_min_mb": clampi(int(spec_in.get("ram_min_mb", 1024)), 256, 1048576),
		"cpu_cores": clampi(int(spec_in.get("cpu_cores", 0)), 0, 4096),
		"properties": _string_dict(spec_in.get("properties", {})),
		"settings": _string_dict(spec_in.get("settings", {})),
		"auto_start": bool(spec_in.get("auto_start", false)),
	}
	var wanted_port := int(spec_in.get("port", 0))
	if wanted_port > 0 and wanted_port <= 65535 and ServerManager.port_owner(wanted_port) == null:
		spec["port"] = wanted_port
	var res: Dictionary = await ServerManager.create_server(spec, progress)
	if not res.ok:
		return {"ok": false, "error": res.get("error", "Could not create the server.")}
	var inst: ServerInstance = res.instance
	inst.log_system("Created remotely by %s." % grant.name)
	Notifier.info("%s (remote) created %s." % [grant.name, inst.config.display_name], Notifier.Category.REMOTE)
	return {"ok": true, "server": inst.config.id}


static func _string_dict(value: Variant) -> Dictionary:
	var out := {}
	if value is Dictionary:
		for k in value:
			out[str(k)] = str(value[k])
	return out
