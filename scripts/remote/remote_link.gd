class_name RemoteLink
extends ServerSource
## The connection to another computer's Server Manager: fetches and pins its certificate,
## signs in with the access key, keeps [RemoteServer] mirrors of what the key opens, and
## carries requests. Reconnects by itself after network trouble.

signal status_changed

enum Status { OFFLINE, CONNECTING, ONLINE, DENIED }
enum Phase { IDLE, BOOTSTRAP, TLS, AUTH, READY }

const STATUS_NAMES: PackedStringArray = ["Offline", "Connecting…", "Connected", "Access denied"]
const CONNECT_TIMEOUT_MSEC := 10000
const PING_INTERVAL_MSEC := 15000
const SILENCE_TIMEOUT_MSEC := 45000
const RETRY_DELAYS: Array[int] = [3, 10, 30, 60]


## A request waiting for its reply.
class Pending:
	extends RefCounted
	signal done(result: Dictionary)
	var on_progress := Callable()


## Local id of this saved computer.
var link_id := ""
## Name of the computer (from its owner; editable here).
var label := ""
var addresses := PackedStringArray()
var port := RemoteProtocol.DEFAULT_PORT
var key_id := ""
var secret := ""
## The host's certificate, pinned after the first verified bootstrap.
var cert_pem := ""
var status := Status.OFFLINE
## Why the link is not connected ("" when fine).
var error := ""
var role := -1
## Name the host gave this key (usually the person's name).
var grant_name := ""
var connected_address := ""

var _channel: RemoteChannel
var _phase := Phase.IDLE
var _address_index := 0
var _client_nonce := ""
var _host_nonce := ""
## The TCP connection is up and the mode byte went out.
var _mode_sent := false
var _phase_deadline := 0
var _bootstrapped := false
var _next_id := 1
var _pending := {}
var _servers := {}
var _host_stats := {}
var _retry_count := 0
var _last_heard_msec := 0
var _last_ping_msec := 0
var _round_errors := PackedStringArray()

@onready var _retry_timer := Timer.new()


func _ready() -> void:
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(connect_now)
	add_child(_retry_timer)


func to_dict() -> Dictionary:
	return {
		"id": link_id, "label": label, "addresses": Array(addresses), "port": port,
		"key": key_id, "secret": secret, "cert": cert_pem,
	}


static func from_dict(d: Dictionary) -> RemoteLink:
	var link := RemoteLink.new()
	link.link_id = str(d.get("id", Fmt.random_token(8)))
	link.label = str(d.get("label", "Remote computer"))
	link.addresses = PackedStringArray(d.get("addresses", []))
	link.port = clampi(int(d.get("port", RemoteProtocol.DEFAULT_PORT)), 1, 65535)
	link.key_id = str(d.get("key", ""))
	link.secret = str(d.get("secret", ""))
	link.cert_pem = str(d.get("cert", ""))
	link.name = ("Link_" + link.link_id).validate_node_name()
	return link


func is_online() -> bool:
	return status == Status.ONLINE


func is_system_admin() -> bool:
	return is_online() and role == RemoteProtocol.Role.SYSTEM_ADMIN


func status_text() -> String:
	var text := STATUS_NAMES[status]
	if status == Status.ONLINE and role >= 0:
		text += " as %s" % RemoteProtocol.ROLE_NAMES[role].to_lower()
	return text


func remote_servers() -> Array[RemoteServer]:
	var out: Array[RemoteServer] = []
	for s in _servers.values():
		out.append(s)
	return out


# --- ServerSource ----------------------------------------------------------------

func source_name() -> String:
	return label


func is_remote_source() -> bool:
	return true


func get_handles() -> Array[ServerHandle]:
	var out: Array[ServerHandle] = []
	for s in _servers.values():
		out.append(s)
	return out


func can_manage_servers() -> bool:
	return is_system_admin()


func host_stats() -> Dictionary:
	return _host_stats


func allocated_ram_mb() -> int:
	return int(_host_stats.get("allocated_mb", super()))


func start_all() -> void:
	_report(await request("start_all"))


func stop_all() -> void:
	_report(await request("stop_all"))


func create_server_remote(spec: Dictionary, on_progress := Callable()) -> Dictionary:
	var res := await request("create_server", "", {"spec": spec}, on_progress)
	if res.ok:
		var handle := _servers.get(str(res.get("server", "")), null) as RemoteServer
		res["instance"] = handle
	return res


func delete_handle(handle: ServerHandle, delete_files := true, delete_backups := false) -> Dictionary:
	return await request("delete", (handle as RemoteServer).remote_id, {"files": delete_files, "backups": delete_backups})


func duplicate_handle(handle: ServerHandle, display_name: String, copy_worlds := true, copy_plugins := true, on_status := Callable()) -> Dictionary:
	var res := await request("duplicate", (handle as RemoteServer).remote_id, {"name": display_name, "worlds": copy_worlds, "plugins": copy_plugins},
			func(text: String, _fraction: float) -> void:
				if on_status.is_valid():
					on_status.call(text))
	if res.ok:
		res["instance"] = _servers.get(str(res.get("server", "")), null)
	return res


# --- Requests --------------------------------------------------------------------------

## Sends a request and waits for the reply: {ok, error?, ...}. [param on_progress]
## receives (text, fraction) for long operations.
func request(op: String, server_id := "", args := {}, on_progress := Callable()) -> Dictionary:
	if status != Status.ONLINE:
		return {"ok": false, "error": "%s is not connected." % label}
	var id := _next_id
	_next_id += 1
	var pending := Pending.new()
	pending.on_progress = on_progress
	_pending[id] = pending
	var msg := {"id": id, "op": op, "args": args}
	if server_id != "":
		msg["server"] = server_id
	_channel.send(msg)
	var result: Dictionary = await pending.done
	return result


func _report(res: Dictionary) -> void:
	if not res.ok:
		Notifier.error("%s: %s" % [label, res.get("error", "failed")])


# --- Connection ---------------------------------------------------------------------

## Connects (or reconnects) now, trying each address in turn.
func connect_now() -> void:
	_retry_timer.stop()
	_drop_channel()
	if addresses.is_empty():
		_give_up("No address to connect to. Edit the computer's address.")
		return
	_address_index = 0
	_bootstrapped = false
	_round_errors.clear()
	_set_status(Status.CONNECTING)
	_open_current()


## Disconnects and stays offline until [method connect_now].
func disconnect_now() -> void:
	_retry_timer.stop()
	_drop_channel()
	_fail_pending("Disconnected.")
	error = ""
	_set_status(Status.OFFLINE)


func _open_current() -> void:
	var target := RemoteProtocol.split_address(addresses[_address_index], port)
	_channel = RemoteChannel.open(str(target.host), int(target.port))
	_phase = Phase.BOOTSTRAP if cert_pem == "" else Phase.TLS
	_phase_deadline = Time.get_ticks_msec() + CONNECT_TIMEOUT_MSEC
	_mode_sent = false


func _process(_delta: float) -> void:
	if _channel == null:
		return
	var messages := _channel.poll()
	if _channel.status == RemoteChannel.Status.OPEN and not _mode_sent:
		_mode_sent = true
		if _phase == Phase.BOOTSTRAP:
			_client_nonce = RemoteProtocol.nonce()
			_channel.send_bytes(PackedByteArray([RemoteProtocol.MODE_BOOTSTRAP]))
			_channel.send({"t": "cert", "key": key_id, "nonce": _client_nonce})
		else:
			_channel.send_bytes(PackedByteArray([RemoteProtocol.MODE_TLS]))
			# The mode byte must leave before the TLS handshake starts writing.
			if not _channel.flush():
				_retry_address("Could not send to %s." % _channel.remote_address)
				return
			var cert := X509Certificate.new()
			if cert.load_from_string(cert_pem) != OK:
				cert_pem = ""
				_retry_address("The saved certificate is unreadable.")
				return
			_channel.start_tls_client(cert)
			# The pinned certificate already proves who answers, and the welcome carries the
			# server list with console history, so full-size messages are fine from here on.
			_channel.reader.max_frame = RemoteProtocol.MAX_FRAME
			_phase = Phase.AUTH
	if not messages.is_empty():
		_last_heard_msec = Time.get_ticks_msec()
	for msg in messages:
		_on_message(msg)
		if _channel == null:
			return
	if _channel.is_closed():
		_on_channel_closed()
		return
	var now := Time.get_ticks_msec()
	if _phase != Phase.READY:
		if now > _phase_deadline:
			_retry_address("No answer from %s." % _channel.remote_address)
	else:
		if now - _last_ping_msec > PING_INTERVAL_MSEC:
			_last_ping_msec = now
			_channel.send({"t": "ping"})
		if now - _last_heard_msec > SILENCE_TIMEOUT_MSEC:
			_channel.close("The connection stopped responding.")


func _on_message(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if t == "denied":
		_deny(str(msg.get("reason", "Access denied.")))
		return
	if t == "bye":
		var reason := str(msg.get("reason", "The other computer closed the connection."))
		if bool(msg.get("retry", true)):
			_lost(reason, RETRY_DELAYS[-1])
		else:
			_deny(reason)
		return
	match _phase:
		Phase.BOOTSTRAP:
			_on_certificate(msg)
		Phase.AUTH:
			if t == "hello":
				_on_hello(msg)
			elif t == "welcome":
				_on_welcome(msg)
		Phase.READY:
			if msg.has("re"):
				_on_reply(msg)
			elif msg.has("ev"):
				_on_event(msg)


## Verifies that the certificate really comes from the holder of our key, then pins it.
func _on_certificate(msg: Dictionary) -> void:
	var pem := str(msg.get("pem", ""))
	if str(msg.get("t", "")) != "cert" or pem == "" \
			or not RemoteProtocol.proofs_equal(RemoteProtocol.proof(secret, "cert", [_client_nonce, pem]), str(msg.get("proof", ""))):
		_deny("The other computer could not prove it holds this access key. The invite code may be wrong or out of date.")
		return
	cert_pem = pem
	if label == "" and str(msg.get("name", "")) != "":
		label = str(msg.name)
	_bootstrapped = true
	RemoteHosts.save()
	_drop_channel()
	_open_current()


func _on_hello(msg: Dictionary) -> void:
	if int(msg.get("v", 0)) != RemoteProtocol.VERSION:
		_deny("%s runs a different version of Server Manager (protocol %d, this one %d). Update both to the same version." % [label, int(msg.get("v", 0)), RemoteProtocol.VERSION])
		return
	var host_nonce := str(msg.get("nonce", ""))
	_client_nonce = RemoteProtocol.nonce()
	_channel.send({
		"t": "auth", "v": RemoteProtocol.VERSION, "key": key_id, "nonce": _client_nonce,
		"proof": RemoteProtocol.proof(secret, "client", [host_nonce, _client_nonce, key_id]),
	})
	_host_nonce = host_nonce


func _on_welcome(msg: Dictionary) -> void:
	if not RemoteProtocol.proofs_equal(RemoteProtocol.proof(secret, "host", [_client_nonce, _host_nonce]), str(msg.get("proof", ""))):
		_deny("The other computer could not prove it holds this access key.")
		return
	_phase = Phase.READY
	_last_heard_msec = Time.get_ticks_msec()
	_last_ping_msec = _last_heard_msec
	role = clampi(int(msg.get("role", RemoteProtocol.Role.SERVER_ADMIN)), 0, RemoteProtocol.Role.size() - 1)
	grant_name = str(msg.get("grant_name", ""))
	if str(msg.get("name", "")) != "":
		label = str(msg.name)
	RemoteHosts.save()
	connected_address = addresses[_address_index]
	_retry_count = 0
	error = ""
	_host_stats = msg.get("host", {}) if msg.get("host", {}) is Dictionary else {}
	# Servers from an earlier connection are updated in place, so open views stay bound.
	var seen := {}
	for data in msg.get("servers", []):
		if data is Dictionary:
			seen[str(data.get("id", ""))] = true
			_add_or_update(data)
	for id in _servers.keys():
		if not seen.has(id):
			_remove_server(id)
	_set_status(Status.ONLINE)
	for s in _servers.values():
		s.notify_link_changed()


func _on_reply(msg: Dictionary) -> void:
	var pending: Pending = _pending.get(int(msg.re), null)
	if pending == null:
		return
	_pending.erase(int(msg.re))
	msg.erase("re")
	if not msg.has("ok"):
		msg["ok"] = false
	if not msg.ok and not msg.has("error"):
		msg["error"] = "The request failed."
	pending.done.emit(msg)


func _on_event(msg: Dictionary) -> void:
	var server: RemoteServer = _servers.get(str(msg.get("server", "")), null)
	match str(msg.ev):
		"console":
			if server != null:
				server.add_console(msg.get("lines", []))
		"stats":
			if server != null and msg.get("data") is Dictionary:
				server.apply_stats(msg.data)
		"server":
			if server != null and msg.get("data") is Dictionary:
				server.apply_snapshot(msg.data)
				server_state_changed.emit(server)
		"added":
			if msg.get("data") is Dictionary:
				_add_or_update(msg.data)
		"removed":
			_remove_server(str(msg.get("server", "")))
		"temp_ended":
			if server != null:
				server.temporary_run_ended.emit()
		"progress":
			var pending: Pending = _pending.get(int(msg.get("re", 0)), null)
			if pending != null and pending.on_progress.is_valid():
				pending.on_progress.call(str(msg.get("text", "")), float(msg.get("fraction", -1.0)))
		"host":
			if msg.get("data") is Dictionary:
				_host_stats = msg.data
				host_stats_changed.emit()


func _add_or_update(data: Dictionary) -> void:
	var id := str(data.get("id", ""))
	if id == "":
		return
	var existing: RemoteServer = _servers.get(id, null)
	if existing != null:
		if data.has("console"):
			existing.console_lines.clear()
			existing.add_console(data.console)
			existing.console_cleared.emit()
		existing.apply_snapshot(data)
		return
	var server := RemoteServer.new()
	server.setup(self, data)
	_servers[id] = server
	add_child(server)
	server.state_changed.connect(func(_s: ServerHandle.State) -> void: server_state_changed.emit(server))
	server_added.emit(server)


func _remove_server(id: String) -> void:
	var server: RemoteServer = _servers.get(id, null)
	if server == null:
		return
	var handle_key := server.key()
	_servers.erase(id)
	server_removed.emit(handle_key)
	server.queue_free()


func _on_channel_closed() -> void:
	var reason := _channel.error if _channel.error != "" else "Connection closed."
	match _phase:
		Phase.READY:
			_lost(reason, RETRY_DELAYS[0])
		Phase.AUTH, Phase.TLS:
			# A failed handshake with a pinned certificate can mean the other computer has a
			# new one: fetch it again (verified with the key) once per attempt.
			if cert_pem != "" and not _bootstrapped and _mode_sent:
				cert_pem = ""
				_drop_channel()
				_open_current()
			else:
				_retry_address(reason)
		_:
			_retry_address(reason)


## Tries the next address, or schedules another round after a pause.
func _retry_address(reason: String) -> void:
	_round_errors.append("%s: %s" % [addresses[_address_index], reason])
	_drop_channel()
	_address_index += 1
	if _address_index < addresses.size():
		_bootstrapped = false
		_open_current()
		return
	error = "\n".join(_round_errors) if addresses.size() > 1 else reason
	_schedule_retry()


func _lost(reason: String, delay: int) -> void:
	_drop_channel()
	_fail_pending("Connection to %s lost." % label)
	error = reason
	_set_status(Status.OFFLINE)
	for s in _servers.values():
		s.notify_link_changed()
	_retry_timer.start(delay)


func _schedule_retry() -> void:
	var delay := RETRY_DELAYS[mini(_retry_count, RETRY_DELAYS.size() - 1)]
	_retry_count += 1
	_set_status(Status.OFFLINE)
	_retry_timer.start(delay)


func _deny(reason: String) -> void:
	_drop_channel()
	_fail_pending(reason)
	error = reason
	_set_status(Status.DENIED)
	for s in _servers.values():
		s.notify_link_changed()


func _give_up(reason: String) -> void:
	error = reason
	_set_status(Status.OFFLINE)


func _drop_channel() -> void:
	if _channel != null:
		_channel.close()
		_channel = null
	_phase = Phase.IDLE


func _fail_pending(reason: String) -> void:
	var pending := _pending
	_pending = {}
	for p: Pending in pending.values():
		p.done.emit({"ok": false, "error": reason})


func _set_status(new_status: Status) -> void:
	status = new_status
	status_changed.emit()
