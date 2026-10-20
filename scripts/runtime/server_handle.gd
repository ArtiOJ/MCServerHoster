class_name ServerHandle
extends Node
## What the interface knows about one server and what it can ask of it, whether the server
## runs on this computer ([ServerInstance]) or on another one ([RemoteServer]).
## Operations that may have to travel over the network are coroutines on remote servers:
## callers always `await` them (awaiting a local, non-coroutine call returns immediately).

signal state_changed(state: State)
signal console_line_added(entry: Dictionary)
signal console_cleared
signal stats_updated
signal players_changed
signal config_changed
signal update_available_changed
## A temporary copy stopped for good; the UI asks whether to keep or discard its changes.
signal temporary_run_ended
## Something a tab lists changed: &"plugins", &"backups", &"worlds", &"lists", &"network",
## &"permissions", &"settings" (server.properties) or &"chunky" (a task started or stopped).
signal data_changed(area: StringName)
## A backup started, progressed or finished (see [member backup_busy]).
signal backup_status_changed

enum State { STOPPED, STARTING, RUNNING, STOPPING, CRASHED, INSTALLING }

const STATE_NAMES := ["Stopped", "Starting", "Running", "Stopping", "Crashed", "Installing"]
const STATE_COLORS: Array[Color] = [
	Color("6b7280"), Color("f2b84b"), Color("3fb97f"), Color("f2b84b"), Color("e05555"), Color("5aa9f2"),
]
## Stopped but listening for players (start on connect).
const ASLEEP_COLOR := Color("8b7cf6")

## Things a view may offer for a server (see [method supports]).
const FEATURE_DELETE := &"delete"
const FEATURE_DUPLICATE := &"duplicate"
const FEATURE_OPEN_FOLDER := &"open_folder"
const FEATURE_IMPORT_WORLD := &"import_world"
const FEATURE_UPDATE := &"update"
const FEATURE_ICON := &"icon"
const FEATURE_TEMPORARY := &"temporary"
const FEATURE_STOP_ORPHAN := &"stop_orphan"

var config: ServerConfig
var state: State = State.STOPPED
## Console history: {"text": raw line, "plain": stripped, "level": LogParser.Level}
var console_lines: Array[Dictionary] = []
var players := PackedStringArray()
var max_players := 0
var tps := -1.0
var startup_seconds := -1.0
var last_exit_code := 0
## Newest Paper build for this version when newer than the installed one, else 0.
var update_available_build := 0
var command_history := PackedStringArray()
## PID of a server left running by a previous session of the manager (-1 if none).
var orphan_pid := -1
var backup_busy := false
## 0..1 while [member backup_busy].
var backup_progress := 0.0


# --- Identity ----------------------------------------------------------------

func is_remote() -> bool:
	return false


## Unique among all servers the interface shows (local ids and remote ones can clash).
func key() -> String:
	return config.id


## Name of the computer the server runs on ("" for this computer).
func host_name() -> String:
	return ""


## The set of servers this one belongs to (its computer).
func source() -> ServerSource:
	return ServerManager


## True when whoever views the server may also change things outside it on its computer
## (Java executable and arguments, waking the computer, router and firewall). Always true
## here; for a server on another computer only for its system admins.
func can_manage_host() -> bool:
	return true


## True when the view may offer [param feature] (one of the FEATURE_* names).
func supports(_feature: StringName) -> bool:
	return true


# --- Queries -----------------------------------------------------------------

func is_online() -> bool:
	return state == State.RUNNING


func is_process_alive() -> bool:
	return false


## True when the server is doing something (not cleanly stopped / crashed).
func is_busy() -> bool:
	return state in [State.STARTING, State.RUNNING, State.STOPPING, State.INSTALLING]


func state_name() -> String:
	return "Asleep" if state == State.STOPPED and is_asleep() else STATE_NAMES[state]


func state_color() -> Color:
	return ASLEEP_COLOR if state == State.STOPPED and is_asleep() else STATE_COLORS[state]


## True while stopped but listening for players to wake the server (start on connect).
func is_asleep() -> bool:
	return false


## True while a temporary copy is running or waiting for a keep/discard decision.
func is_temporary() -> bool:
	return config.temp_run_dir != ""


## True for a re-attached server without RCON: the console is read-only.
func is_read_only() -> bool:
	return false


## True when commands can reach the server.
func can_send_commands() -> bool:
	return false


func uptime_seconds() -> int:
	return 0


func process_id() -> int:
	return -1


## CPU usage as a percentage of the whole host (all cores = 100 %).
func cpu_percent() -> float:
	return 0.0


## CPU usage in cores (1.0 = one full core).
func cpu_cores_used() -> float:
	return 0.0


func rss_bytes() -> int:
	return 0


func cpu_history() -> PackedFloat32Array:
	return PackedFloat32Array()


func ram_history() -> PackedFloat32Array:
	return PackedFloat32Array()


## Logical CPU cores of the computer the server runs on.
func host_cores() -> int:
	return OS.get_processor_count()


## Address players on the same network use.
func connect_address() -> String:
	return ""


## Address players on the internet use, or "" if unknown.
func public_address() -> String:
	return ""


## The message of the day shown in the server list.
func motd() -> String:
	return "A Minecraft Server"


## The Java runtime that will run the server, in words.
func java_description() -> String:
	return ""


## Server folder as shown to the user.
func folder_path() -> String:
	return config.directory


## Human-readable problem that prevents starting, or "" when the server can start.
func start_problem() -> String:
	return ""


## The server-list icon, or null for none.
func icon_texture() -> Texture2D:
	return null


## {exists, valid (64×64 PNG), size: Vector2i}
func icon_info() -> Dictionary:
	return {"exists": false, "valid": false, "size": Vector2i.ZERO}


## Why start-on-connect can't listen right now ("" when fine).
func wake_error() -> String:
	return ""


## The computer's wake-port block (see PowerManager.wake_block_for_servers).
func computer_wake_block() -> int:
	return -2


# --- Operations --------------------------------------------------------------

## Starts the server ([param temporary] resumes a pending temporary copy).
func start(_temporary := false) -> Error:
	return ERR_UNAVAILABLE


func stop() -> void:
	pass


func restart() -> void:
	pass


func kill() -> void:
	pass


## Copies the server and starts the copy (see ServerInstance.start_temporary).
func start_temporary() -> Error:
	return ERR_UNAVAILABLE


## Ends a pending temporary run, keeping or discarding what changed.
func finish_temporary(_keep: bool) -> Error:
	return ERR_UNAVAILABLE


## Sends a console command. [param echo] shows it in the console view.
func send_command(_command: String, _echo := true) -> bool:
	return false


func clear_console() -> void:
	console_lines.clear()
	console_cleared.emit()


## Gracefully stops a server process left over from an earlier session.
func stop_orphan() -> void:
	pass


## Installs Paper [param build_id] of [param version]; with [param backup] the worlds are
## backed up first. [param on_progress] receives (text, fraction). Returns {ok, error?}.
func update_paper(_version: String, _build_id: int, _backup: bool, _on_progress := Callable()) -> Dictionary:
	return {"ok": false, "error": "Not available."}


## Saves a 64×64 server icon (PNG bytes), or removes it with empty [param png].
func set_icon_png(_png: PackedByteArray) -> Error:
	return ERR_UNAVAILABLE


## Runs one of the tab operations ([ServerOps]) and returns its JSON-style result
## ({ok, error?, ...}). [param on_progress] receives (text, fraction) for long ones.
func call_op(_op: String, _args := {}, _on_progress := Callable()) -> Dictionary:
	return {"ok": false, "error": "Not available."}


# --- Settings (server.properties, Paper/Spigot/Bukkit YAML, game rules) ---------

## {ok, values: {entry id: value}, explicit: {entry id: true}, unknown: {key: value},
## properties_missing, raw_files: [names], pending_gamerules}
func settings_snapshot() -> Dictionary:
	return {"ok": false, "error": "Not available."}


## Saves catalog settings ({entry id: value}). Returns {ok, error?, rules_applied, restart_needed}.
func save_settings(_changes: Dictionary) -> Dictionary:
	return {"ok": false, "error": "Not available."}


## Text of a configuration file (server.properties or a catalog YAML file). Returns {ok, text|error}.
func read_config_file(_file: String) -> Dictionary:
	return {"ok": false, "error": "Not available."}


## Replaces a configuration file. Returns {ok, error?}.
func write_config_file(_file: String, _text: String) -> Dictionary:
	return {"ok": false, "error": "Not available."}


# --- Shared helpers ------------------------------------------------------------

func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)


func _append_console(entry: Dictionary) -> void:
	console_lines.append(entry)
	var limit := AppSettings.console_max_lines
	if console_lines.size() > limit + 250:
		console_lines = console_lines.slice(console_lines.size() - limit)
	console_line_added.emit(entry)
