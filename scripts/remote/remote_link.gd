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
## Folders are zipped here before an upload.
const TEMP_DIR := "user://remote-temp"
## How long to keep knocking after a wake-up was sent (a computer takes a while to resume).
const WAKE_WINDOW_MSEC := 120000
const WAKE_RETRY_SEC := 3


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
## MAC address of the computer's Wi-Fi when it can be woken by a connection ("" if not).
var wake_mac := ""

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
## Until when a wake-up is in progress (ticks msec; 0 = none).
var _wake_until_msec := 0

@onready var _retry_timer := Timer.new()


func _ready() -> void:
	_retry_timer.one_shot = true
	_retry_timer.timeout.connect(connect_now)
	add_child(_retry_timer)


func to_dict() -> Dictionary:
	return {
		"id": link_id, "label": label, "addresses": Array(addresses), "port": port,
		"key": key_id, "secret": secret, "cert": cert_pem, "wake_mac": wake_mac,
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
	link.wake_mac = str(d.get("wake_mac", ""))
	link.name = ("Link_" + link.link_id).validate_node_name()
	return link


func is_online() -> bool:
	return status == Status.ONLINE


func is_system_admin() -> bool:
	return is_online() and role == RemoteProtocol.Role.SYSTEM_ADMIN


## True when the computer said it can be woken by a connection and isn't connected now.
func can_wake() -> bool:
	return wake_mac != "" and status != Status.ONLINE and status != Status.DENIED


func is_waking() -> bool:
	return Time.get_ticks_msec() < _wake_until_msec


## Wakes the computer from sleep: sends Wake-on-LAN magic packets (broadcast on this network
## and to its addresses) and keeps connecting, which the computer's Wi-Fi card also watches
## for. Retries quickly for a while; see [method wake_and_wait].
func wake() -> void:
	if wake_mac == "":
		return
	_wake_until_msec = Time.get_ticks_msec() + WAKE_WINDOW_MSEC
	_send_magic_packets()
	connect_now()


## Wakes the computer and waits until it is connected (or the wake window passes).
## Returns true when connected.
func wake_and_wait() -> bool:
	wake()
	while not is_online() and is_waking() and status != Status.DENIED:
		await get_tree().create_timer(0.5).timeout
	return is_online()


## Magic packet: 6 × FF, then the MAC 16 times, to UDP port 9.
func _send_magic_packets() -> void:
	var mac := wake_mac.replace(":", "").replace("-", "").hex_decode()
	if mac.size() != 6:
		return
	var packet := PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
	for i in 16:
		packet.append_array(mac)
	var targets := PackedStringArray(["255.255.255.255"])
	for a in addresses:
		var host := str(RemoteProtocol.split_address(a, port).host)
		if host.is_valid_ip_address() and not targets.has(host):
			targets.append(host)
	var udp := PacketPeerUDP.new()
	udp.set_broadcast_enabled(true)
	for target in targets:
		if udp.set_dest_address(target, 9) == OK:
			udp.put_packet(packet)
	udp.close()


func status_text() -> String:
	if is_waking() and status != Status.ONLINE:
		return "Waking up…"
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
	# The channel is gone a moment before the status changes (while pending requests fail).
	if status != Status.ONLINE or _channel == null:
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


## Like [method request], but files on this computer travel along: paths in args.files are
## uploaded first (folders as zips) and sent as upload ids; a file the host offers for
## download is saved to args.dest. Progress covers both transfers.
func request_with_files(op: String, server_id: String, args: Dictionary, on_progress := Callable()) -> Dictionary:
	var a := args.duplicate()
	var dest := str(a.get("dest", ""))
	a.erase("dest")
	if a.has("files"):
		var ids: Array = []
		# Worlds and servers keep their folder name; datapacks need their files at the top.
		var keep_root := op.ends_with("import_analyze")
		for path in a.files:
			var up := await upload(str(path), on_progress, keep_root)
			if not up.ok:
				return up
			ids.append(up.id)
		a.erase("files")
		a["uploads"] = ids
	var res := await request(op, server_id, a, on_progress)
	if res.ok and res.has("download"):
		if dest == "":
			request("download_close", "", {"id": res.download})
		else:
			var got := await download(str(res.download), int(res.get("size", 0)), dest, on_progress)
			if not got.ok:
				return got
			res["path"] = dest
	return res


func call_host_op(op: String, args := {}, on_progress := Callable()) -> Dictionary:
	return await request_with_files(op, "", args, on_progress)


## Sends a file (or a folder, zipped) to the host. Returns {ok, id} or {ok: false, error}.
func upload(path: String, on_progress := Callable(), keep_root := false) -> Dictionary:
	var source := path
	var temp_zip := ""
	if DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(TEMP_DIR)
		temp_zip = TEMP_DIR.path_join("%s-%s.zip" % [path.trim_suffix("/").get_file(), Fmt.random_token(6).to_lower()])
		if on_progress.is_valid():
			on_progress.call("Packing %s…" % path.get_file(), -1.0)
		var err: String = await FileOps.run_async(self, func() -> String: return FileOps.zip_folder(path, temp_zip, keep_root))
		if err != "":
			DirAccess.remove_absolute(temp_zip)
			return {"ok": false, "error": err}
		source = temp_zip
	var res := await _upload_file(source, path.trim_suffix("/").get_file() + (".zip" if temp_zip != "" else ""), on_progress)
	if temp_zip != "":
		DirAccess.remove_absolute(temp_zip)
	return res


func _upload_file(path: String, upload_name: String, on_progress: Callable) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Could not read %s (%s)." % [path.get_file(), error_string(FileAccess.get_open_error())]}
	var size := f.get_length()
	var begin := await request("upload_begin", "", {"name": upload_name, "size": size})
	if not begin.ok:
		return begin
	var id := str(begin.id)
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	var sent := 0
	while sent < size:
		var chunk := f.get_buffer(RemoteProtocol.CHUNK_BYTES)
		if chunk.is_empty():
			return {"ok": false, "error": "Reading %s failed." % upload_name}
		hash.update(chunk)
		var res := await request("upload_chunk", "", {"id": id, "offset": sent, "data": Marshalls.raw_to_base64(chunk)})
		if not res.ok:
			return res
		sent += chunk.size()
		if on_progress.is_valid():
			on_progress.call("Uploading %s… %s of %s" % [upload_name, Fmt.bytes(sent), Fmt.bytes(size)], float(sent) / maxf(size, 1.0))
	return await request("upload_end", "", {"id": id, "sha256": hash.finish().hex_encode()})


## Fetches a file the host offered ([param id]) into [param dest].
func download(id: String, size: int, dest: String, on_progress := Callable()) -> Dictionary:
	var part := dest + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		request("download_close", "", {"id": id})
		return {"ok": false, "error": "Could not write %s (%s)." % [dest.get_file(), error_string(FileAccess.get_open_error())]}
	var got := 0
	while true:
		var res := await request("download_chunk", "", {"id": id, "offset": got, "length": RemoteProtocol.CHUNK_BYTES})
		if not res.ok:
			f.close()
			DirAccess.remove_absolute(part)
			return res
		var data := Marshalls.base64_to_raw(str(res.get("data", "")))
		f.store_buffer(data)
		got += data.size()
		if on_progress.is_valid():
			on_progress.call("Downloading %s… %s of %s" % [dest.get_file(), Fmt.bytes(got), Fmt.bytes(size)], float(got) / maxf(size, 1.0))
		if bool(res.get("eof", true)) or data.is_empty():
			break
	f.close()
	request("download_close", "", {"id": id})
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		return {"ok": false, "error": "Could not save %s." % dest}
	return {"ok": true, "path": dest}


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
			# Progress events carry the request id too, so events are told apart first.
			if msg.has("ev"):
				_on_event(msg)
			elif msg.has("re"):
				_on_reply(msg)


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
	var wake_info: Dictionary = msg.get("wake", {}) if msg.get("wake") is Dictionary else {}
	var mac := str(wake_info.get("mac", "")) if wake_info.get("ready", false) else ""
	if mac != wake_mac:
		wake_mac = mac
		RemoteHosts.save()
	_wake_until_msec = 0
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
		"data":
			if server != null:
				server.data_changed.emit(StringName(str(msg.get("area", ""))))
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
	if is_waking():
		# Still waking: knock again soon (packets sent while it was falling asleep get lost).
		delay = WAKE_RETRY_SEC
		_send_magic_packets()
	_set_status(Status.OFFLINE)
	_retry_timer.start(delay)


func _deny(reason: String) -> void:
	_drop_channel()
	_fail_pending(reason)
	error = reason
	# Without access (e.g. a revoked key) the servers are of no use; they come back with access.
	for id in _servers.keys():
		_remove_server(id)
	_set_status(Status.DENIED)


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
