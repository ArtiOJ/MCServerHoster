class_name RemoteServer
extends ServerHandle
## A server on another computer, seen through a [RemoteLink]. Mirrors what the host
## reports and forwards operations to it; nothing here touches local files.

## Remote folders must never be read or written on this computer. File access through
## this path always fails, so code that wrongly treats the server as local cannot do harm.
const NO_LOCAL_DIR := "/dev/null/remote-server"
const HISTORY_SIZE := 120

var link: RemoteLink
## The server's id on its own computer.
var remote_id := ""

var _data := {}
var _cpu_history := PackedFloat32Array()
var _ram_history := PackedFloat32Array()
var _uptime_base := 0
var _uptime_at_msec := 0
var _icon: Texture2D
var _icon_rev := -1


func setup(owner_link: RemoteLink, data: Dictionary) -> void:
	link = owner_link
	remote_id = str(data.get("id", ""))
	name = ("Remote_" + remote_id).validate_node_name()
	_cpu_history = PackedFloat32Array(data.get("cpu_history", []))
	_ram_history = PackedFloat32Array(data.get("ram_history", []))
	console_lines.clear()
	for line in data.get("console", []):
		console_lines.append(_entry_from_wire(line))
	apply_snapshot(data, true)


## Takes a snapshot from the host. Emits the signals for what changed.
func apply_snapshot(data: Dictionary, initial := false) -> void:
	var old_state := state
	var old_players := players
	var old_update := update_available_build
	var config_dict: Dictionary = data.get("config", {}) if data.get("config", {}) is Dictionary else {}
	var config_changed_now: bool = initial or config_dict != _data.get("config", {}) \
			or data.get("icon_rev") != _data.get("icon_rev") or data.get("problem") != _data.get("problem") \
			or data.get("public_address") != _data.get("public_address") or data.get("orphan_pid") != _data.get("orphan_pid")
	_data.merge(data, true)
	if config_changed_now:
		config = ServerConfig.from_dict(config_dict, NO_LOCAL_DIR)
	update_available_build = int(_data.get("update_build", 0))
	orphan_pid = int(_data.get("orphan_pid", -1))
	last_exit_code = int(_data.get("last_exit_code", 0))
	startup_seconds = float(_data.get("startup_seconds", -1.0))
	_apply_live(data)
	if int(_data.get("icon_rev", 0)) != _icon_rev:
		_icon_rev = int(_data.get("icon_rev", 0))
		_fetch_icon()
	if initial:
		return
	if config_changed_now:
		config_changed.emit()
	if update_available_build != old_update:
		update_available_changed.emit()
	if players != old_players:
		players_changed.emit()
	if state != old_state:
		state_changed.emit(state)
	stats_updated.emit()


## Takes a stats update from the host.
func apply_stats(data: Dictionary) -> void:
	var old_state := state
	var old_players := players
	_data.merge(data, true)
	_apply_live(data)
	if bool(_data.get("alive", false)):
		_push(_cpu_history, float(_data.get("cpu", 0.0)))
		_push(_ram_history, float(_data.get("rss", 0)) / 1048576.0)
	if players != old_players:
		players_changed.emit()
	if state != old_state:
		state_changed.emit(state)
	stats_updated.emit()


func add_console(lines: Array) -> void:
	for line in lines:
		if line is Dictionary:
			_append_console(_entry_from_wire(line))


## Called by the link when the connection drops or comes back.
func notify_link_changed() -> void:
	state_changed.emit(state)
	stats_updated.emit()


func _apply_live(data: Dictionary) -> void:
	if data.has("state"):
		state = clampi(int(data.state), 0, State.size() - 1) as State
	if data.has("players"):
		players = PackedStringArray(data.players)
	if data.has("max_players"):
		max_players = int(data.max_players)
	if data.has("tps"):
		tps = float(data.tps)
	if data.has("uptime"):
		_uptime_base = int(data.uptime)
		_uptime_at_msec = Time.get_ticks_msec()
	if data.has("backup_busy") or data.has("backup_progress"):
		var busy := bool(data.get("backup_busy", backup_busy))
		var progress := float(data.get("backup_progress", backup_progress))
		if busy != backup_busy or not is_equal_approx(progress, backup_progress):
			backup_busy = busy
			backup_progress = progress
			backup_status_changed.emit()


static func _entry_from_wire(line: Dictionary) -> Dictionary:
	var text := str(line.get("t", ""))
	var entry := {"text": text, "plain": Ansi.strip(text), "level": int(line.get("l", LogParser.Level.INFO))}
	if line.get("s", false):
		entry["system"] = true
	return entry


static func _push(arr: PackedFloat32Array, value: float) -> void:
	arr.append(value)
	if arr.size() > HISTORY_SIZE:
		arr.remove_at(0)


# --- Identity & queries ---------------------------------------------------------------

func is_remote() -> bool:
	return true


func key() -> String:
	return "%s/%s" % [link.link_id, remote_id]


func host_name() -> String:
	return link.source_name()


func supports(feature: StringName) -> bool:
	match feature:
		FEATURE_DELETE, FEATURE_DUPLICATE:
			return link.is_system_admin()
		FEATURE_OPEN_FOLDER:
			return false
	return true


func source() -> ServerSource:
	return link


func can_manage_host() -> bool:
	return link.is_system_admin()


func is_connected_to_host() -> bool:
	return link.is_online()


func state_name() -> String:
	if not link.is_online():
		return "Waking up" if link.is_waking() else "Disconnected"
	return super()


func state_color() -> Color:
	return STATE_COLORS[State.STOPPED] if not link.is_online() else super()


func is_process_alive() -> bool:
	return bool(_data.get("alive", false))


func is_asleep() -> bool:
	return bool(_data.get("asleep", false))


func is_read_only() -> bool:
	return bool(_data.get("read_only", false))


func can_send_commands() -> bool:
	return link.is_online() and bool(_data.get("can_send", false))


func uptime_seconds() -> int:
	if state != State.RUNNING and state != State.STOPPING:
		return 0
	return _uptime_base + (Time.get_ticks_msec() - _uptime_at_msec) / 1000


func process_id() -> int:
	return int(_data.get("pid", -1))


func cpu_percent() -> float:
	return float(_data.get("cpu", 0.0))


func cpu_cores_used() -> float:
	return float(_data.get("cores_used", 0.0))


func rss_bytes() -> int:
	return int(_data.get("rss", 0))


func cpu_history() -> PackedFloat32Array:
	return _cpu_history


func ram_history() -> PackedFloat32Array:
	return _ram_history


func host_cores() -> int:
	return maxi(int(_data.get("cores", 1)), 1)


func connect_address() -> String:
	return str(_data.get("address", ""))


func public_address() -> String:
	return str(_data.get("public_address", ""))


func motd() -> String:
	return str(_data.get("motd", "A Minecraft Server"))


func java_description() -> String:
	return str(_data.get("java", ""))


func folder_path() -> String:
	return str(_data.get("folder", ""))


func start_problem() -> String:
	return str(_data.get("problem", ""))


func icon_texture() -> Texture2D:
	return _icon


func wake_error() -> String:
	return str(_data.get("wake_error", ""))


func icon_info() -> Dictionary:
	return {
		"exists": bool(_data.get("icon_exists", false)), "valid": bool(_data.get("icon_valid", false)),
		"size": Vector2i(int(_data.get("icon_w", 0)), int(_data.get("icon_h", 0))),
	}


# --- Operations ----------------------------------------------------------------------

func start(temporary := false) -> Error:
	_send("start", {"temporary": temporary})
	return OK


func stop() -> void:
	_send("stop")


func restart() -> void:
	_send("restart")


func kill() -> void:
	_send("kill")


func start_temporary() -> Error:
	return OK if await _send("start_temporary") else FAILED


func finish_temporary(keep: bool) -> Error:
	return OK if await _send("finish_temporary", {"keep": keep}) else FAILED


func send_command(command: String, echo := true) -> bool:
	command = command.strip_edges()
	if command.is_empty() or not can_send_commands():
		return false
	if echo and (command_history.is_empty() or command_history[-1] != command):
		command_history.append(command)
		if command_history.size() > 200:
			command_history.remove_at(0)
	_send("command", {"text": command})
	return true


func stop_orphan() -> void:
	await _send("stop_orphan")


func update_paper(version: String, build_id: int, backup: bool, on_progress := Callable()) -> Dictionary:
	return await link.request("update_paper", remote_id, {"version": version, "build": build_id, "backup": backup}, on_progress)


func check_updates() -> void:
	await link.request("check_updates", remote_id)


func set_icon_png(png: PackedByteArray) -> Error:
	var res := await link.request("icon_set", remote_id, {"png": Marshalls.raw_to_base64(png) if not png.is_empty() else ""})
	if not res.ok:
		Notifier.error("%s: %s" % [config.display_name, res.error])
	return OK if res.ok else FAILED


func call_op(op: String, args := {}, on_progress := Callable()) -> Dictionary:
	return await link.request_with_files(op, remote_id, args, on_progress)


func settings_snapshot() -> Dictionary:
	return await link.request("settings_get", remote_id)


func save_settings(changes: Dictionary) -> Dictionary:
	return await link.request("settings_save", remote_id, {"changes": changes})


func read_config_file(file: String) -> Dictionary:
	return await link.request("file_read", remote_id, {"file": file})


func write_config_file(file: String, text: String) -> Dictionary:
	return await link.request("file_write", remote_id, {"file": file, "text": text})


## Sends [param op]; failures are shown as notifications. Returns true on success.
func _send(op: String, args := {}) -> bool:
	var res := await link.request(op, remote_id, args)
	if not res.ok:
		Notifier.error("%s: %s" % [config.display_name, res.get("error", "failed")])
	return bool(res.ok)


func _fetch_icon() -> void:
	if not bool(_data.get("icon_exists", false)):
		_icon = null
		return
	var rev := _icon_rev
	var res := await link.request("icon_get", remote_id)
	if rev != _icon_rev or not res.ok or str(res.get("png", "")) == "":
		return
	var img := Image.new()
	if img.load_png_from_buffer(Marshalls.base64_to_raw(res.png)) != OK:
		return
	img.generate_mipmaps()
	_icon = ImageTexture.create_from_image(img)
	config_changed.emit()
