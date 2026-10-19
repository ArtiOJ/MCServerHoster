extends Node
## Lets people who have an access key control servers on this computer from their own
## Server Manager (docs/PLAN.md §10). Owns the keys, this computer's TLS certificate and
## the listener, and fans server events out to the connected sessions (RemoteSession children).

signal grants_changed
signal sessions_changed
signal status_changed

## At most this many connections may be mid-handshake at once.
const MAX_PENDING := 8
## Failed attempts from one address within [constant FAILURE_WINDOW_SEC] before it is blocked.
const FAILURE_LIMIT := 5
const FAILURE_WINDOW_SEC := 600
const BLOCK_SEC := 900
const STATS_INTERVAL_MSEC := 1000
const HOST_STATS_INTERVAL_MSEC := 2000
const CONSOLE_SNAPSHOT_LINES := 1000

var enabled := false
var port := RemoteProtocol.DEFAULT_PORT
## Name other people see for this computer.
var computer_name := ""
var grants: Array[RemoteGrant] = []
## Why the listener is not running ("" when it runs or is switched off).
var listen_error := ""

var _server: TCPServer
var _key: CryptoKey
var _cert: X509Certificate
var _cert_pem := ""
var _failures := {}
var _blocked := {}
var _dirty_snapshots := {}
var _dirty_stats := {}
var _console_batches := {}
var _last_stats_msec := 0
var _last_host_msec := 0
var _host_last_busy := -1
var _host_last_total := -1
var _host_cpu_pct := 0.0


func _ready() -> void:
	if AppSettings.other_instance_pid > 0:
		set_process(false)
		return
	computer_name = _default_computer_name()
	_load()
	ServerManager.server_added.connect(_watch)
	ServerManager.server_removed.connect(_on_server_removed)
	for inst in ServerManager.get_instances():
		_watch(inst)
	if enabled:
		_listen.call_deferred()


func _exit_tree() -> void:
	for session in sessions():
		session.kick("This computer's Server Manager is closing.")
		session.flush_now()
	if _server != null:
		_server.stop()


# --- Settings & keys ---------------------------------------------------------------

func is_listening() -> bool:
	return _server != null and _server.is_listening()


## Turns the listener on or off and remembers the choice.
func set_enabled(on: bool, new_port := -1) -> void:
	if new_port > 0:
		port = new_port
	enabled = on
	_save()
	if on:
		_listen()
		# Invites list the internet address too when it is known.
		if NetworkService.public_ip == "" and not NetworkService.looking_up_public_ip:
			NetworkService.refresh_public_ip()
	else:
		_stop_listening()
		for session in sessions():
			session.kick("Remote access to this computer was switched off.")


func set_computer_name(text: String) -> void:
	computer_name = text.strip_edges() if text.strip_edges() != "" else _default_computer_name()
	_save()


func find_grant(id: String) -> RemoteGrant:
	for g in grants:
		if g.id == id:
			return g
	return null


## Creates a key and returns it; [method invite_for] gives the code to hand over.
func create_grant(person: String, role: RemoteProtocol.Role, servers: PackedStringArray) -> RemoteGrant:
	var g := RemoteGrant.create(person, role, servers)
	grants.append(g)
	_save()
	grants_changed.emit()
	return g


## Saves changes to [param grant] and applies them to connected sessions right away.
func update_grant(grant: RemoteGrant) -> void:
	_save()
	for session in sessions():
		if session.grant == grant:
			session.refresh_access()
	grants_changed.emit()


## Deletes a key; anyone connected with it is disconnected.
func revoke_grant(grant: RemoteGrant) -> void:
	grants.erase(grant)
	_save()
	for session in sessions():
		if session.grant == grant:
			session.kick("Your access key was revoked.", false)
	grants_changed.emit()


func invite_for(grant: RemoteGrant) -> String:
	return RemoteProtocol.make_invite({
		"name": computer_name, "addresses": invite_addresses(), "port": port, "key": grant.id, "secret": grant.secret,
	})


## Addresses a client can try, nearest first: this computer's LAN address, then the
## public one (needs the port forwarded in the router).
func invite_addresses() -> PackedStringArray:
	var out := PackedStringArray()
	var route := PlatformBackend.get_current().default_route()
	if str(route.get("address", "")) != "":
		out.append(str(route.address))
	if NetworkService.public_ip != "" and not out.has(NetworkService.public_ip):
		out.append(NetworkService.public_ip)
	return out


func sessions() -> Array[RemoteSession]:
	var out: Array[RemoteSession] = []
	for child in get_children():
		if child is RemoteSession and child.is_ready_session():
			out.append(child)
	return out


func sessions_for(grant: RemoteGrant) -> Array[RemoteSession]:
	return sessions().filter(func(s: RemoteSession) -> bool: return s.grant == grant)


# --- Used by sessions -------------------------------------------------------------

## {key, cert, pem}; created on first use and kept in the profile folder (mode 600).
func identity() -> Dictionary:
	if _key == null:
		_load_or_create_identity()
	return {"key": _key, "cert": _cert, "pem": _cert_pem}


func is_blocked(address: String) -> bool:
	var until := int(_blocked.get(address, 0))
	if until > 0 and until > int(Time.get_unix_time_from_system()):
		return true
	_blocked.erase(address)
	return false


func record_failure(address: String) -> void:
	var now := int(Time.get_unix_time_from_system())
	var times: Array = _failures.get(address, [])
	times = times.filter(func(t: int) -> bool: return now - t < FAILURE_WINDOW_SEC)
	times.append(now)
	_failures[address] = times
	if times.size() >= FAILURE_LIMIT:
		_blocked[address] = now + BLOCK_SEC
		_failures.erase(address)
		Notifier.warn("Blocked %s for %d minutes after repeated failed remote sign-ins." % [address, BLOCK_SEC / 60], Notifier.Category.REMOTE)


func record_success(session: RemoteSession) -> void:
	_failures.erase(session.address)
	session.grant.last_used_unix = int(Time.get_unix_time_from_system())
	_save()
	sessions_changed.emit()
	Notifier.info("%s connected remotely (%s)." % [session.grant.name, session.grant.role_name().to_lower()], Notifier.Category.REMOTE)


func on_session_closed(session: RemoteSession, was_ready: bool) -> void:
	if was_ready:
		sessions_changed.emit()
		Notifier.info("%s disconnected." % session.grant.name, Notifier.Category.REMOTE)


## Everything a client shows about a server.
func snapshot(inst: ServerInstance) -> Dictionary:
	var cfg := inst.config.to_dict()
	cfg.erase("rcon_password")
	var icon := ServerIcon.icon_path(inst.config.directory)
	var info := inst.icon_info()
	var data := {
		"id": inst.config.id, "config": cfg, "folder": inst.config.directory,
		"icon_rev": FileAccess.get_modified_time(icon) if FileAccess.file_exists(icon) else 0,
		"icon_exists": info.exists, "icon_valid": info.valid, "icon_w": info.size.x, "icon_h": info.size.y,
		"update_build": inst.update_available_build, "orphan_pid": inst.orphan_pid,
		"last_exit_code": inst.last_exit_code, "startup_seconds": inst.startup_seconds,
		"address": inst.connect_address(), "public_address": inst.public_address(),
		"java": inst.java_description(), "cores": OS.get_processor_count(), "motd": inst.motd(),
		"problem": inst.start_problem() if not inst.is_busy() else "",
	}
	data.merge(live_state(inst))
	data.merge(stats(inst))
	return data


## The parts of a server's state that change while it runs.
func live_state(inst: ServerInstance) -> Dictionary:
	return {
		"state": inst.state, "alive": inst.is_process_alive(), "asleep": inst.is_asleep(),
		"read_only": inst.is_read_only(), "can_send": inst.can_send_commands(), "pid": inst.process_id(),
		"players": Array(inst.players), "max_players": inst.max_players,
	}


func stats(inst: ServerInstance) -> Dictionary:
	return {
		"cpu": inst.cpu_percent(), "cores_used": inst.cpu_cores_used(), "rss": inst.rss_bytes(),
		"tps": inst.tps, "uptime": inst.uptime_seconds(),
	}


func console_snapshot(inst: ServerInstance) -> Array:
	var lines := inst.console_lines.slice(maxi(inst.console_lines.size() - CONSOLE_SNAPSHOT_LINES, 0))
	return lines.map(_wire_line)


## This computer's load, for a system admin's dashboard.
func host_stats() -> Dictionary:
	var s := PlatformBackend.get_current().sample_host()
	if s.cpu_total > 0 and _host_last_total > 0 and s.cpu_total > _host_last_total:
		_host_cpu_pct = 100.0 * (s.cpu_busy - _host_last_busy) / float(s.cpu_total - _host_last_total)
	_host_last_busy = s.cpu_busy
	_host_last_total = s.cpu_total
	return {
		"cpu": _host_cpu_pct, "cores": OS.get_processor_count(), "mem_total": s.mem_total,
		"mem_used": s.mem_total - s.mem_available, "allocated_mb": ServerManager.allocated_ram_mb(),
	}


# --- Events ---------------------------------------------------------------------

func _process(_delta: float) -> void:
	_accept_connections()
	_flush_events()


func _watch(inst: ServerInstance) -> void:
	var id := inst.config.id
	var mark := func() -> void: _dirty_snapshots[id] = true
	inst.state_changed.connect(mark.unbind(1))
	inst.players_changed.connect(mark)
	inst.config_changed.connect(mark)
	inst.update_available_changed.connect(mark)
	inst.stats_updated.connect(func() -> void: _dirty_stats[id] = true)
	inst.console_line_added.connect(func(entry: Dictionary) -> void:
		if not _console_batches.has(id):
			_console_batches[id] = []
		_console_batches[id].append(_wire_line(entry)))
	inst.temporary_run_ended.connect(func() -> void: _broadcast(id, {"ev": "temp_ended", "server": id}))
	for session in sessions():
		session.refresh_access()


func _on_server_removed(server_id: String) -> void:
	# A deleted server's id must not open a future server that reuses the name.
	var changed := false
	for g in grants:
		if g.server_ids.has(server_id):
			g.server_ids.remove_at(g.server_ids.find(server_id))
			changed = true
	if changed:
		_save()
		grants_changed.emit()
	for session in sessions():
		session.refresh_access()


func _flush_events() -> void:
	if sessions().is_empty():
		# Nobody to tell: drop what piled up instead of building snapshots for no one.
		_console_batches.clear()
		_dirty_snapshots.clear()
		_dirty_stats.clear()
		return
	if not _console_batches.is_empty():
		var batches := _console_batches
		_console_batches = {}
		for id in batches:
			_broadcast(id, {"ev": "console", "server": id, "lines": batches[id]})
	if not _dirty_snapshots.is_empty():
		var ids := _dirty_snapshots.keys()
		_dirty_snapshots.clear()
		for id in ids:
			var inst := ServerManager.get_instance(id)
			if inst != null:
				_broadcast(id, {"ev": "server", "server": id, "data": snapshot(inst)})
				_dirty_stats.erase(id)
	var now := Time.get_ticks_msec()
	if not _dirty_stats.is_empty() and now - _last_stats_msec >= STATS_INTERVAL_MSEC:
		_last_stats_msec = now
		var ids := _dirty_stats.keys()
		_dirty_stats.clear()
		for id in ids:
			var inst := ServerManager.get_instance(id)
			if inst != null:
				var data := stats(inst)
				data.merge(live_state(inst))
				_broadcast(id, {"ev": "stats", "server": id, "data": data})
	if now - _last_host_msec >= HOST_STATS_INTERVAL_MSEC:
		_last_host_msec = now
		var admins := sessions().filter(func(s: RemoteSession) -> bool: return s.grant.is_system_admin())
		if not admins.is_empty():
			var msg := {"ev": "host", "data": host_stats()}
			for s: RemoteSession in admins:
				s.send(msg)


func _broadcast(server_id: String, msg: Dictionary) -> void:
	for session in sessions():
		if session.sees(server_id):
			session.send(msg)


static func _wire_line(entry: Dictionary) -> Dictionary:
	var out := {"t": entry.text, "l": entry.level}
	if entry.get("system", false):
		out["s"] = true
	return out


# --- Listener --------------------------------------------------------------------

func _listen() -> void:
	_stop_listening()
	identity()
	_server = TCPServer.new()
	var err := _server.listen(port, "*")
	if err != OK:
		listen_error = "Port %d could not be opened (%s). Another program may be using it." % [port, error_string(err)]
		_server = null
		Notifier.warn("Remote access is off: " + listen_error, Notifier.Category.REMOTE)
	else:
		listen_error = ""
	status_changed.emit()


func _stop_listening() -> void:
	if _server != null:
		_server.stop()
		_server = null
	listen_error = ""
	status_changed.emit()


func _accept_connections() -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		var address := tcp.get_connected_host()
		if is_blocked(address) or _pending_count() >= MAX_PENDING:
			tcp.disconnect_from_host()
			continue
		var session := RemoteSession.new()
		session.setup(RemoteChannel.accepted(tcp))
		add_child(session)


func _pending_count() -> int:
	var n := 0
	for child in get_children():
		if child is RemoteSession and not child.is_ready_session():
			n += 1
	return n


# --- Persistence -------------------------------------------------------------------

func _config_path() -> String:
	return AppSettings.profile_path("remote-access.json")


func _load() -> void:
	var path := _config_path()
	if not FileAccess.file_exists(path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		push_warning("Ignoring unreadable remote access settings")
		return
	enabled = bool(data.get("enabled", false))
	port = clampi(int(data.get("port", RemoteProtocol.DEFAULT_PORT)), 1, 65535)
	if str(data.get("name", "")).strip_edges() != "":
		computer_name = str(data.name)
	grants.clear()
	for d in data.get("grants", []):
		if d is Dictionary:
			var g := RemoteGrant.from_dict(d)
			if g.id != "" and g.secret.length() >= 32:
				grants.append(g)


func _save() -> void:
	var data := {
		"enabled": enabled, "port": port, "name": computer_name,
		"grants": grants.map(func(g: RemoteGrant) -> Dictionary: return g.to_dict()),
	}
	var err := AppSettings.write_private(_config_path(), JSON.stringify(data, "\t"))
	if err != OK:
		Notifier.error("Could not save remote access settings: %s" % error_string(err))


func _load_or_create_identity() -> void:
	var key_path := AppSettings.profile_path("remote-host.key")
	var cert_path := AppSettings.profile_path("remote-host.crt")
	var key := CryptoKey.new()
	var cert := X509Certificate.new()
	if FileAccess.file_exists(key_path) and FileAccess.file_exists(cert_path) \
			and key.load(key_path) == OK and cert.load(cert_path) == OK:
		_key = key
		_cert = cert
	else:
		var crypto := Crypto.new()
		_key = crypto.generate_rsa(2048)
		_cert = crypto.generate_self_signed_certificate(_key, "CN=%s,O=Server Manager,C=US" % RemoteProtocol.CERT_CN, "20200101000000", "21000101000000")
		AppSettings.write_private(key_path, _clean_pem(_key.save_to_string()))
		AppSettings.write_private(cert_path, _clean_pem(_cert.save_to_string()))
	_cert_pem = _clean_pem(_cert.save_to_string())


## Godot appends a NUL to saved PEM text; it must not end up in files, proofs or JSON.
static func _clean_pem(pem: String) -> String:
	var end := pem.rfind("-----")
	return (pem.substr(0, end + 5) if end >= 0 else pem.strip_edges()) + "\n"


static func _default_computer_name() -> String:
	var host := PlatformBackend.read_text("/etc/hostname").strip_edges()
	if host == "":
		host = OS.get_environment("HOSTNAME")
	var user := OS.get_environment("USER")
	if host == "":
		return "%s's computer" % user if user != "" else "Server Manager"
	return host
