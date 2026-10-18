class_name ServerInstance
extends Node
## One managed Minecraft server: its configuration, lifecycle state machine,
## console buffer and live statistics. Child nodes do the specialised work.

signal state_changed(state: State)
signal console_line_added(entry: Dictionary)
signal console_cleared
signal stats_updated
signal players_changed
signal config_changed
signal update_available_changed

enum State { STOPPED, STARTING, RUNNING, STOPPING, CRASHED, INSTALLING }

const STATE_NAMES := ["Stopped", "Starting", "Running", "Stopping", "Crashed", "Installing"]
const STATE_COLORS: Array[Color] = [
	Color("6b7280"), Color("f2b84b"), Color("3fb97f"), Color("f2b84b"), Color("e05555"), Color("5aa9f2"),
]
## Back-off between automatic restarts after consecutive crashes.
const RESTART_DELAYS: Array[int] = [5, 15, 60]
const QUERY_INTERVAL_SEC := 5.0

var config: ServerConfig
var state: State = State.STOPPED
## Console history: {"text": raw line, "plain": stripped, "level": LogParser.Level}
var console_lines: Array[Dictionary] = []
var players := PackedStringArray()
var max_players := 0
var tps := -1.0
var startup_seconds := -1.0
var start_time_msec := 0
var last_exit_code := 0
## Newest Paper build for this version when newer than the installed one, else 0.
var update_available_build := 0
var command_history := PackedStringArray()
## PID of a server left running by a previous session of the manager (-1 if none).
var orphan_pid := -1

var _stop_requested := false
var _restart_after_stop := false
var _crash_times: Array[int] = []

@onready var process: ServerProcess = %ServerProcess
@onready var monitor: ResourceMonitor = %ResourceMonitor
@onready var rcon: RconClient = %RconClient
@onready var scheduler: TaskScheduler = %TaskScheduler
@onready var backups: BackupService = %BackupService
@onready var _stop_timeout: Timer = %StopTimeoutTimer
@onready var _restart_delay: Timer = %RestartDelayTimer
@onready var _query_timer: Timer = %QueryTimer


## Must be called before the node enters the tree.
func setup(cfg: ServerConfig) -> void:
	config = cfg
	name = cfg.id.validate_node_name()


func _ready() -> void:
	process.line_received.connect(_on_line)
	process.exited.connect(_on_process_exited)
	monitor.sampled.connect(func(_c: float, _r: int) -> void: stats_updated.emit())
	rcon.authenticated.connect(_query_status)
	_stop_timeout.timeout.connect(_on_stop_timeout)
	_restart_delay.timeout.connect(_on_restart_delay_timeout)
	_query_timer.wait_time = QUERY_INTERVAL_SEC
	_query_timer.timeout.connect(_query_status)
	max_players = get_properties().get_int("max-players", 20)
	orphan_pid = find_orphan_pid()
	if orphan_pid > 0:
		log_system("This server is still running from a previous session (PID %d) but is not attached to the manager. Use \"Stop leftover process\" before starting it again." % orphan_pid, LogParser.Level.WARN)


# --- Queries -----------------------------------------------------------------

func is_online() -> bool:
	return state == State.RUNNING


func is_process_alive() -> bool:
	return process.is_running()


## True when the server is doing something (not cleanly stopped / crashed).
func is_busy() -> bool:
	return state in [State.STARTING, State.RUNNING, State.STOPPING, State.INSTALLING]


func state_name() -> String:
	return STATE_NAMES[state]


func state_color() -> Color:
	return STATE_COLORS[state]


func uptime_seconds() -> int:
	if state != State.RUNNING and state != State.STOPPING:
		return 0
	return (Time.get_ticks_msec() - start_time_msec) / 1000


func get_properties() -> ServerProperties:
	return ServerProperties.load_file(config.properties_path())


func connect_address() -> String:
	var ip := get_properties().get_value("server-ip", "")
	if ip == "":
		ip = _lan_ip()
	return ip if config.port == 25565 else "%s:%d" % [ip, config.port]


## Human-readable problems that prevent starting, or "" when the server can start.
func start_problem() -> String:
	if orphan_pid > 0:
		return "A leftover server process from a previous session is still running (PID %d). Stop it first." % orphan_pid
	if not FileAccess.file_exists(config.jar_path()):
		return "Server jar is missing (%s). Reinstall or update Paper for this server." % config.jar_file
	if not config.eula_accepted:
		return "The Minecraft EULA has not been accepted for this server."
	var java := JavaRuntimes.resolve_for(config)
	if java == null:
		return "No Java %d+ runtime found. Install one or pick a Java executable in Resources." % config.java_min_version
	if java.major < config.java_min_version:
		return "Minecraft %s needs Java %d or newer; the selected runtime is Java %d." % [config.mc_version, config.java_min_version, java.major]
	var clash := ServerManager.port_owner(config.port, config.id, true)
	if clash != null:
		return "Port %d is used by \"%s\", which is running." % [config.port, clash.config.display_name]
	if not PlatformBackend.is_port_free(config.port):
		return "Port %d is already in use by another program." % config.port
	return ""


# --- Lifecycle ---------------------------------------------------------------

func start() -> Error:
	if is_busy():
		return ERR_ALREADY_IN_USE
	_restart_delay.stop()
	var problem := start_problem()
	if problem != "":
		log_system(problem, LogParser.Level.ERROR)
		Notifier.error("%s: %s" % [config.display_name, problem])
		return FAILED
	_prepare_files()
	var java := JavaRuntimes.resolve_for(config)
	var cmd := PlatformBackend.get_current().build_launch_command(config, java.executable)
	log_system("Starting %s (Paper %s #%d, %s)…" % [config.display_name, config.mc_version, config.paper_build, java.display_name()])
	var err := process.launch(cmd.path, cmd.args)
	if err != OK:
		log_system("Failed to launch process: %s" % error_string(err), LogParser.Level.ERROR)
		return err
	_write_pid_file(process.pid)
	_stop_requested = false
	start_time_msec = Time.get_ticks_msec()
	startup_seconds = -1.0
	tps = -1.0
	players.clear()
	players_changed.emit()
	monitor.track(process.pid)
	scheduler.on_server_started()
	_set_state(State.STARTING)
	return OK


func stop() -> void:
	match state:
		State.RUNNING, State.STARTING:
			_stop_requested = true
			_set_state(State.STOPPING)
			log_system("Stopping server…")
			if not process.write_line("stop"):
				process.terminate()
			_stop_timeout.start(config.stop_timeout_sec)
		State.CRASHED:
			# Cancels a pending automatic restart.
			_restart_delay.stop()
			_crash_times.clear()
			_set_state(State.STOPPED)


func restart() -> void:
	match state:
		State.RUNNING, State.STARTING:
			_restart_after_stop = true
			stop()
		State.STOPPED, State.CRASHED:
			start()


func kill() -> void:
	if process.is_running():
		_stop_requested = true
		_restart_after_stop = false
		log_system("Killing server process (PID %d)." % process.pid, LogParser.Level.WARN)
		process.kill()


## Sends a console command. [param echo] shows it in the console view.
func send_command(command: String, echo := true) -> bool:
	command = command.strip_edges()
	if command.is_empty():
		return false
	if echo:
		_append_console({"text": "> " + command, "plain": "> " + command, "level": LogParser.Level.COMMAND})
		if command_history.is_empty() or command_history[-1] != command:
			command_history.append(command)
			if command_history.size() > 200:
				command_history.remove_at(0)
	var bare := command.trim_prefix("/")
	if bare == "stop" or bare == "end":
		_stop_requested = true
		_stop_timeout.start(config.stop_timeout_sec)
		if state == State.RUNNING or state == State.STARTING:
			_set_state(State.STOPPING)
	return process.write_line(bare)


func log_system(message: String, level := LogParser.Level.SYSTEM) -> void:
	var lvl := level if level != LogParser.Level.INFO else LogParser.Level.SYSTEM
	var stamp := Time.get_time_string_from_system()
	var text := "[%s Manager] %s" % [stamp, message]
	_append_console({"text": text, "plain": text, "level": lvl, "system": true})


func clear_console() -> void:
	console_lines.clear()
	console_cleared.emit()


func save_config() -> void:
	var err := config.save()
	if err != OK:
		Notifier.error("Could not save settings for %s: %s" % [config.display_name, error_string(err)])
	scheduler.reset()
	config_changed.emit()


func set_update_available(build_id: int) -> void:
	update_available_build = build_id if build_id > config.paper_build else 0
	update_available_changed.emit()


## Downloads and installs a Paper build (optionally for a different Minecraft version).
## The previous jar is kept in .manager/jars for rollback. Server must be stopped.
func install_build(version: String, build: Dictionary, version_info: Dictionary, on_progress := Callable()) -> Dictionary:
	if is_busy():
		return {"ok": false, "error": "Stop the server first."}
	var previous_state := state
	_set_state(State.INSTALLING)
	log_system("Downloading Paper %s build #%d…" % [version, build.id])
	var tmp_jar := config.directory.path_join(config.jar_file + ".download")
	var res: Dictionary = await PaperApi.download_build(build, tmp_jar, on_progress)
	if not res.ok:
		log_system("Update failed: " + res.error, LogParser.Level.ERROR)
		_set_state(previous_state if previous_state != State.INSTALLING else State.STOPPED)
		return res
	if FileAccess.file_exists(config.jar_path()):
		var archive := config.meta_dir().path_join("jars")
		DirAccess.make_dir_recursive_absolute(archive)
		DirAccess.rename_absolute(config.jar_path(), archive.path_join("paper-%s-%d.jar" % [config.mc_version, config.paper_build]))
	DirAccess.rename_absolute(tmp_jar, config.jar_path())
	config.mc_version = version
	config.paper_build = int(build.id)
	config.build_channel = str(build.channel)
	if version_info.get("ok", false):
		config.java_min_version = int(version_info.java_min)
		config.recommended_flags = version_info.flags
	save_config()
	set_update_available(0)
	log_system("Installed Paper %s build #%d." % [version, build.id])
	_set_state(State.STOPPED)
	return {"ok": true}


func mark_installing(on: bool) -> void:
	_set_state(State.INSTALLING if on else State.STOPPED)


# --- Internals ---------------------------------------------------------------

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


func _on_line(text: String, is_stderr: bool) -> void:
	var plain := Ansi.strip(text)
	var level := LogParser.level_of(plain)
	if is_stderr and level == LogParser.Level.OTHER:
		level = LogParser.Level.ERROR
	_append_console({"text": text, "plain": plain, "level": level})
	backups.on_console_line(plain)

	if state == State.STARTING:
		var secs := LogParser.startup_seconds(plain)
		if secs >= 0.0:
			startup_seconds = secs
			_on_started()
			return
	var joined := LogParser.joined_player(plain)
	if joined != "":
		if not players.has(joined):
			players.append(joined)
		players_changed.emit()
		return
	var left := LogParser.left_player(plain)
	if left != "":
		var idx := players.find(left)
		if idx >= 0:
			players.remove_at(idx)
		players_changed.emit()
		return
	if LogParser.is_stopping(plain):
		# Stopped from in-game or by a plugin: treat as an intentional shutdown.
		_stop_requested = true
		if state == State.RUNNING:
			_set_state(State.STOPPING)


func _on_started() -> void:
	_set_state(State.RUNNING)
	log_system("Server is online (started in %.1f s). Connect with %s" % [startup_seconds, connect_address()])
	Notifier.success("%s is online." % config.display_name)
	max_players = get_properties().get_int("max-players", max_players)
	if config.rcon_port > 0 and config.rcon_password != "":
		rcon.connect_to("127.0.0.1", config.rcon_port, config.rcon_password)
	_query_timer.start()


func _on_process_exited(code: int) -> void:
	_stop_timeout.stop()
	_query_timer.stop()
	monitor.untrack()
	rcon.close()
	_remove_pid_file()
	last_exit_code = code
	players.clear()
	tps = -1.0
	players_changed.emit()
	stats_updated.emit()
	if _stop_requested:
		log_system("Server stopped (exit code %d)." % code)
		_set_state(State.STOPPED)
		if _restart_after_stop:
			_restart_after_stop = false
			start()
		return
	log_system("Server process exited unexpectedly (exit code %d)." % code, LogParser.Level.ERROR)
	_set_state(State.CRASHED)
	Notifier.error("%s crashed (exit code %d)." % [config.display_name, code])
	_maybe_auto_restart()


func _maybe_auto_restart() -> void:
	if not config.auto_restart:
		return
	var now := int(Time.get_unix_time_from_system())
	_crash_times = _crash_times.filter(func(t: int) -> bool: return now - t < config.restart_window_sec)
	_crash_times.append(now)
	if _crash_times.size() > config.max_restarts:
		log_system("Crash loop detected (%d crashes in %s); automatic restart disabled until the next manual start." % [_crash_times.size(), Fmt.duration(config.restart_window_sec)], LogParser.Level.ERROR)
		Notifier.error("%s keeps crashing; auto-restart paused." % config.display_name)
		_crash_times.clear()
		return
	var delay := RESTART_DELAYS[mini(_crash_times.size() - 1, RESTART_DELAYS.size() - 1)]
	log_system("Restarting automatically in %d s (attempt %d of %d)…" % [delay, _crash_times.size(), config.max_restarts], LogParser.Level.WARN)
	_restart_delay.start(delay)


func _on_restart_delay_timeout() -> void:
	if state == State.CRASHED:
		start()


func _on_stop_timeout() -> void:
	if process.is_running():
		log_system("Server did not stop within %d s; terminating." % config.stop_timeout_sec, LogParser.Level.WARN)
		process.terminate()
		# Escalate to a hard kill if SIGTERM is ignored too.
		await get_tree().create_timer(10.0).timeout
		if process.is_running():
			kill()


func _query_status() -> void:
	if not rcon.is_ready() or state != State.RUNNING:
		return
	var tps_text := await rcon.execute("tps")
	var parsed_tps := LogParser.parse_tps(tps_text)
	if parsed_tps >= 0.0:
		tps = parsed_tps
	var list := LogParser.parse_list(await rcon.execute("list"))
	if not list.is_empty():
		max_players = list.max
		if list.names != players:
			players = list.names
			players_changed.emit()
	stats_updated.emit()


## Writes the settings the manager owns into server.properties and eula.txt.
func _prepare_files() -> void:
	if config.rcon_port <= 0 or ServerManager.port_owner(config.rcon_port, config.id) != null:
		config.rcon_port = ServerManager.allocate_rcon_port(config.id)
	if config.rcon_password.length() < 16:
		config.rcon_password = Fmt.random_token(24)
	var props := get_properties()
	props.set_value("server-port", config.port)
	props.set_value("query.port", config.port)
	props.set_value("enable-rcon", true)
	props.set_value("rcon.port", config.rcon_port)
	props.set_value("rcon.password", config.rcon_password)
	props.set_value("broadcast-rcon-to-ops", false)
	props.save_file(config.properties_path())
	if config.eula_accepted:
		var f := FileAccess.open(config.directory.path_join("eula.txt"), FileAccess.WRITE)
		if f != null:
			f.store_string("# Accepted in Server Manager (https://aka.ms/MinecraftEULA)\neula=true\n")
	config.save()


func _write_pid_file(pid: int) -> void:
	var f := FileAccess.open(config.meta_dir().path_join("server.pid"), FileAccess.WRITE)
	if f != null:
		f.store_string(str(pid))


func _remove_pid_file() -> void:
	DirAccess.remove_absolute(config.meta_dir().path_join("server.pid"))


## Gracefully stops a server left running by a previous session (SIGTERM runs
## Minecraft's shutdown hook, which saves all worlds).
func stop_orphan() -> void:
	if orphan_pid <= 0:
		return
	log_system("Stopping server left over from a previous session (PID %d)…" % orphan_pid)
	PlatformBackend.get_current().terminate(orphan_pid)
	var deadline := Time.get_ticks_msec() + config.stop_timeout_sec * 1000
	while PlatformBackend.get_current().process_cwd(orphan_pid) == config.directory and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
	if PlatformBackend.get_current().process_cwd(orphan_pid) == config.directory:
		OS.kill(orphan_pid)
	orphan_pid = -1
	_remove_pid_file()
	log_system("Leftover server stopped.")
	state_changed.emit(state)


## PID of a server process left running by a previous session of the manager, or -1.
func find_orphan_pid() -> int:
	var path := config.meta_dir().path_join("server.pid")
	if not FileAccess.file_exists(path):
		return -1
	var pid := FileAccess.get_file_as_string(path).strip_edges().to_int()
	if pid > 0 and PlatformBackend.get_current().process_cwd(pid) == config.directory:
		return pid
	_remove_pid_file()
	return -1


static func _lan_ip() -> String:
	for addr in IP.get_local_addresses():
		if addr.begins_with("192.168.") or addr.begins_with("10.") or (addr.begins_with("172.") and addr.get_slice(".", 1).to_int() in range(16, 32)):
			return addr
	return "localhost"
