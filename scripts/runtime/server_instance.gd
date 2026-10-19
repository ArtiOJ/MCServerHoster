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
## A temporary copy stopped for good; the UI asks whether to keep or discard its changes.
signal temporary_run_ended

enum State { STOPPED, STARTING, RUNNING, STOPPING, CRASHED, INSTALLING }

const STATE_NAMES := ["Stopped", "Starting", "Running", "Stopping", "Crashed", "Installing"]
const STATE_COLORS: Array[Color] = [
	Color("6b7280"), Color("f2b84b"), Color("3fb97f"), Color("f2b84b"), Color("e05555"), Color("5aa9f2"),
]
## Stopped but listening for players (start on connect).
const ASLEEP_COLOR := Color("8b7cf6")
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

## Log lines replayed right after attaching must not count as new joins/stops.
var _replay_until_msec := 0
## Plain-language reason for the last failure seen in the console ("" if none).
var _failure_hint := ""
## Paper wrote a crash report or hit a fatal exception during this run.
var _crash_detected := false
var _stop_requested := false
var _restart_after_stop := false
var _crash_times: Array[int] = []

@onready var process: ServerProcess = %ServerProcess
@onready var monitor: ResourceMonitor = %ResourceMonitor
@onready var rcon: RconClient = %RconClient
@onready var scheduler: TaskScheduler = %TaskScheduler
@onready var backups: BackupService = %BackupService
@onready var wake_listener: WakeListener = %WakeListener
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
	rcon.authenticated.connect(refresh_gamerules)
	# Re-attached servers can only take commands once RCON is up; let the UI know.
	rcon.authenticated.connect(func() -> void:
		if process.is_attached():
			state_changed.emit(state))
	_stop_timeout.timeout.connect(_on_stop_timeout)
	_restart_delay.timeout.connect(_on_restart_delay_timeout)
	_query_timer.wait_time = QUERY_INTERVAL_SEC
	_query_timer.timeout.connect(_query_status)
	state_changed.connect(func(_s: State) -> void: wake_listener.update())
	config_changed.connect(wake_listener.update)
	wake_listener.update.call_deferred()
	max_players = get_properties().get_int("max-players", 20)
	var running := find_running_pid()
	if running > 0:
		_attach_on_ready.call_deferred(running)


# --- Queries -----------------------------------------------------------------

func is_online() -> bool:
	return state == State.RUNNING


func is_process_alive() -> bool:
	return process.is_running()


## True when the server is doing something (not cleanly stopped / crashed).
func is_busy() -> bool:
	return state in [State.STARTING, State.RUNNING, State.STOPPING, State.INSTALLING]


func state_name() -> String:
	return "Asleep" if state == State.STOPPED and is_asleep() else STATE_NAMES[state]


func state_color() -> Color:
	return ASLEEP_COLOR if state == State.STOPPED and is_asleep() else STATE_COLORS[state]


func uptime_seconds() -> int:
	if state != State.RUNNING and state != State.STOPPING:
		return 0
	return (Time.get_ticks_msec() - start_time_msec) / 1000


func get_properties() -> ServerProperties:
	return ServerProperties.load_file(working_directory().path_join("server.properties"))


## True while stopped but listening for players to wake the server (start on connect).
func is_asleep() -> bool:
	return wake_listener.is_listening()


## True while a temporary copy is running or waiting for a keep/discard decision.
func is_temporary() -> bool:
	return config.temp_run_dir != ""


## Folder the server process runs in: the temporary copy during a test run, else the server folder.
func working_directory() -> String:
	return config.temp_run_dir if is_temporary() else config.directory


func connect_address() -> String:
	var ip := get_properties().get_value("server-ip", "")
	if ip == "":
		ip = _lan_ip()
	return ip if config.port == 25565 else "%s:%d" % [ip, config.port]


## Human-readable problems that prevent starting, or "" when the server can start.
func start_problem() -> String:
	if orphan_pid > 0:
		return "A leftover server process from a previous session is still running (PID %d). Stop it first." % orphan_pid
	if not FileAccess.file_exists(config.jar_path(working_directory())):
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

## Starts the server. With a temporary copy pending, [param temporary] must be true to
## resume it; a normal start is refused until the copy is kept or discarded.
func start(temporary := false) -> Error:
	if is_busy():
		return ERR_ALREADY_IN_USE
	if is_temporary() and not temporary:
		var msg := "A temporary copy of this server is waiting for a decision. Keep or discard it first (⋮ menu), or resume the temporary run."
		log_system(msg, LogParser.Level.WARN)
		Notifier.warn("%s: %s" % [config.display_name, msg])
		return ERR_UNAVAILABLE
	_restart_delay.stop()
	# The wake-on-connect listener holds the game port while stopped; release it first.
	wake_listener.close()
	var problem := start_problem()
	if problem != "":
		log_system(problem, LogParser.Level.ERROR)
		Notifier.error("%s: %s" % [config.display_name, problem])
		wake_listener.update.call_deferred()
		return FAILED
	_prepare_files()
	var java := JavaRuntimes.resolve_for(config)
	var cmd := PlatformBackend.get_current().build_launch_command(config, java.executable, working_directory())
	var label := " as a TEMPORARY COPY" if is_temporary() else ""
	log_system("Starting %s%s (Paper %s #%d, %s)…" % [config.display_name, label, config.mc_version, config.paper_build, java.display_name()])
	var err := process.launch(cmd.path, cmd.args)
	if err != OK:
		log_system("Failed to launch process: %s" % error_string(err), LogParser.Level.ERROR)
		wake_listener.update.call_deferred()
		return err
	_write_pid_file(process.pid)
	_failure_hint = ""
	_crash_detected = false
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
			if process.is_attached() and rcon.is_ready():
				rcon.execute("stop")
			elif not process.write_line("stop"):
				process.terminate()
			_stop_timeout.start(config.stop_timeout_sec)
		State.CRASHED:
			# Cancels a pending automatic restart.
			var was_pending := not _restart_delay.is_stopped()
			_restart_delay.stop()
			_crash_times.clear()
			_set_state(State.STOPPED)
			if was_pending and is_temporary():
				temporary_run_ended.emit()


func restart() -> void:
	match state:
		State.RUNNING, State.STARTING:
			_restart_after_stop = true
			stop()
		State.STOPPED, State.CRASHED:
			start(is_temporary())


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
	if process.is_attached():
		if not rcon.is_ready():
			log_system("Commands are unavailable: this re-attached server has no working RCON connection.", LogParser.Level.WARN)
			return false
		_send_via_rcon(bare)
		return true
	return process.write_line(bare)


## True when commands can reach the server (stdin pipe, or RCON for re-attached servers).
func can_send_commands() -> bool:
	if not process.is_running():
		return false
	return rcon.is_ready() if process.is_attached() else true


## Sends a command over RCON and shows its reply in the console (re-attached servers
## have no stdin, and RCON replies are not written to the server log).
func _send_via_rcon(command: String) -> void:
	var reply := await rcon.execute(command)
	for line in reply.split("\n", false):
		var plain := Ansi.strip(line)
		_append_console({"text": line, "plain": plain, "level": LogParser.Level.INFO})
		backups.on_console_line(plain)


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


# --- Temporary runs --------------------------------------------------------------

## Copies the server folder to a throwaway location and starts that copy. The server
## shows as running normally; when it stops, [signal temporary_run_ended] lets the UI ask
## whether to keep or discard what changed. Resumes an existing pending copy if there is one.
func start_temporary() -> Error:
	if is_busy():
		return ERR_ALREADY_IN_USE
	if not is_temporary():
		if orphan_pid > 0:
			return start()  # Reports the leftover process.
		var dir := AppSettings.servers_root.path_join("_temp").path_join("%s-%s" % [config.id, Fmt.file_stamp(int(Time.get_unix_time_from_system()))])
		_set_state(State.INSTALLING)
		log_system("Creating a temporary copy of the server for a test run…")
		var src := config.directory
		var err: Error = await FileOps.run_async(self, func() -> Error: return FileOps.copy_tree(src, dir))
		_set_state(State.STOPPED)
		if err != OK:
			FileOps.remove_path(dir)
			log_system("Could not create the temporary copy: %s" % error_string(err), LogParser.Level.ERROR)
			Notifier.error("%s: could not create a temporary copy (%s)." % [config.display_name, error_string(err)])
			return err
		# The copy only needs the game files; the manager's metadata stays with the real server.
		FileOps.remove_path(dir.path_join(ServerConfig.META_DIR))
		config.temp_run_dir = dir
		config.save()
		log_system("Temporary copy ready: %s" % dir)
		state_changed.emit(state)
	return start(true)


## Ends a pending temporary run. [param keep] replaces the server's files with the copy
## after saving a safety backup of the current worlds; otherwise the copy is deleted.
func finish_temporary(keep: bool) -> Error:
	if not is_temporary():
		return ERR_DOES_NOT_EXIST
	if process.is_running() or state == State.INSTALLING:
		return ERR_BUSY
	var temp := config.temp_run_dir
	var original := config.directory
	_set_state(State.INSTALLING)
	var err := OK
	if keep and DirAccess.dir_exists_absolute(temp):
		if not backups.world_dirs(original).is_empty():
			_set_state(State.STOPPED)
			log_system("Saving a safety backup of the server's current worlds…")
			if await backups.create_backup(false, original, "pre-keep") == "":
				log_system("Safety backup failed; the temporary copy was not applied.", LogParser.Level.ERROR)
				return FAILED
			_set_state(State.INSTALLING)
		log_system("Keeping the changes from the temporary run…")
		var aside := "%s.before-temp-%s" % [original, Fmt.file_stamp(int(Time.get_unix_time_from_system()))]
		err = DirAccess.rename_absolute(original, aside)
		if err == OK:
			err = DirAccess.rename_absolute(temp, original)
			if err != OK:
				# Different filesystems: fall back to copying.
				err = await FileOps.run_async(self, func() -> Error: return FileOps.copy_tree(temp, original))
				if err == OK:
					await FileOps.run_async(self, func() -> Error: return FileOps.remove_tree(temp))
			if err == OK:
				DirAccess.rename_absolute(aside.path_join(ServerConfig.META_DIR), original.path_join(ServerConfig.META_DIR))
				await FileOps.run_async(self, func() -> Error: return FileOps.remove_tree(aside))
			else:
				FileOps.remove_path(original)
				DirAccess.rename_absolute(aside, original)
	elif DirAccess.dir_exists_absolute(temp):
		log_system("Discarding the temporary copy…")
		err = await FileOps.run_async(self, func() -> Error: return FileOps.remove_tree(temp))
	if err != OK:
		_set_state(State.STOPPED)
		log_system("Could not finish the temporary run: %s" % error_string(err), LogParser.Level.ERROR)
		return err
	config.temp_run_dir = ""
	save_config()
	log_system("Temporary run %s." % ("kept — the server now has the copy's files" if keep else "discarded — the server is unchanged"))
	_set_state(State.STOPPED)
	max_players = get_properties().get_int("max-players", max_players)
	return OK


# --- Game rules ------------------------------------------------------------------

## Applies queued game rule changes. Online: immediately through the console; offline: on next start.
func apply_pending_gamerules() -> void:
	if not is_online() or config.pending_gamerules.is_empty():
		return
	for id in config.pending_gamerules:
		var entry := SettingsCatalog.get_entry(id)
		if entry.is_empty() or not SettingsCatalog.applies_to(entry, config.mc_version):
			continue
		var value: String = config.pending_gamerules[id]
		for cmd in SettingsCatalog.rule_commands(entry, value, config.mc_version):
			send_command(cmd, false)
		config.known_gamerules[id] = value
	log_system("Applied %d game rule change(s)." % config.pending_gamerules.size())
	config.pending_gamerules.clear()
	config.save()
	config_changed.emit()


## Reads the current value of every game rule over RCON into [member ServerConfig.known_gamerules].
func refresh_gamerules() -> void:
	if not rcon.is_ready():
		return
	var changed := false
	for entry in SettingsCatalog.for_version(config.mc_version):
		if entry.source != "gamerule" or config.pending_gamerules.has(entry.id):
			continue
		var value := LogParser.parse_gamerule(await rcon.execute("gamerule " + SettingsCatalog.rule_name(entry, config.mc_version)))
		if value != "" and config.known_gamerules.get(entry.id, "") != value:
			config.known_gamerules[entry.id] = value
			changed = true
		if not rcon.is_ready():
			break
	if changed:
		config.save()
		config_changed.emit()


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
	if Time.get_ticks_msec() < _replay_until_msec:
		return  # Backlog from before we attached: show it, but don't act on it.
	var joined := LogParser.joined_player(plain)
	if joined != "":
		if not players.has(joined):
			players.append(joined)
		players_changed.emit()
		Notifier.info("%s joined (%d online)." % [joined, players.size()], Notifier.Category.PLAYERS, config.display_name)
		scheduler.fire(EventRule.Trigger.PLAYER_JOINED)
		return
	var left := LogParser.left_player(plain)
	if left != "":
		var idx := players.find(left)
		if idx >= 0:
			players.remove_at(idx)
		players_changed.emit()
		Notifier.info("%s left (%d online)." % [left, players.size()], Notifier.Category.PLAYERS, config.display_name)
		scheduler.fire(EventRule.Trigger.PLAYER_LEFT)
		return
	if LogParser.is_crash_report(plain):
		_crash_detected = true
	var hint := LogParser.failure_hint(plain, config.port)
	if hint != "":
		_failure_hint = hint
	if LogParser.is_stopping(plain) and state == State.RUNNING:
		# Stopped from in-game or by a plugin: treat as an intentional shutdown. (While still
		# starting, "Stopping server" means the boot failed, which must not look like a stop.)
		_stop_requested = true
		_set_state(State.STOPPING)


func _on_started() -> void:
	_set_state(State.RUNNING)
	log_system("Server is online (started in %.1f s). Connect with %s" % [startup_seconds, connect_address()])
	Notifier.success("%s is online." % config.display_name, Notifier.Category.SERVER_STATE, config.display_name)
	max_players = get_properties().get_int("max-players", max_players)
	_connect_rcon()
	_query_timer.start()
	apply_pending_gamerules()
	scheduler.fire(EventRule.Trigger.SERVER_ONLINE)


## Connects RCON with the settings the running server actually loaded.
func _connect_rcon() -> void:
	var props := get_properties()
	var port := props.get_int("rcon.port", config.rcon_port)
	var password := props.get_value("rcon.password", config.rcon_password)
	if props.get_bool("enable-rcon") and port > 0 and password != "":
		rcon.connect_to("127.0.0.1", port, password)


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
	if _stop_requested and not _crash_detected:
		log_system("Server stopped (exit code %d)." % code)
		_set_state(State.STOPPED)
		if not _restart_after_stop:
			Notifier.info("%s stopped." % config.display_name, Notifier.Category.SERVER_STATE, config.display_name)
		if _restart_after_stop:
			_restart_after_stop = false
			start(is_temporary())
			return
		scheduler.fire(EventRule.Trigger.SERVER_STOPPED)
		if is_temporary():
			temporary_run_ended.emit()
		return
	var failed_start := state == State.STARTING
	var reason := _failure_hint if _failure_hint != "" else LogParser.exit_code_hint(code)
	var what := "failed to start" if failed_start else "crashed"
	log_system("Server %s (exit code %d).%s" % [what, code, (" " + reason) if reason != "" else ""], LogParser.Level.ERROR)
	_set_state(State.CRASHED)
	Notifier.error("%s %s: %s" % [config.display_name, what, reason if reason != "" else "exit code %d" % code], Notifier.Category.CRASH, config.display_name)
	_maybe_auto_restart()
	scheduler.fire(EventRule.Trigger.SERVER_CRASHED)
	if is_temporary() and _restart_delay.is_stopped():
		temporary_run_ended.emit()


func _maybe_auto_restart() -> void:
	if not config.auto_restart:
		return
	var now := int(Time.get_unix_time_from_system())
	_crash_times = _crash_times.filter(func(t: int) -> bool: return now - t < config.restart_window_sec)
	_crash_times.append(now)
	if _crash_times.size() > config.max_restarts:
		log_system("Crash loop detected (%d crashes in %s); automatic restart disabled until the next manual start." % [_crash_times.size(), Fmt.duration(config.restart_window_sec)], LogParser.Level.ERROR)
		Notifier.error("%s keeps crashing; auto-restart paused." % config.display_name, Notifier.Category.CRASH, config.display_name)
		_crash_times.clear()
		return
	var delay := RESTART_DELAYS[mini(_crash_times.size() - 1, RESTART_DELAYS.size() - 1)]
	log_system("Restarting automatically in %d s (attempt %d of %d)…" % [delay, _crash_times.size(), config.max_restarts], LogParser.Level.WARN)
	_restart_delay.start(delay)


func _on_restart_delay_timeout() -> void:
	if state == State.CRASHED:
		start(is_temporary())


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
	config.write_managed_properties(working_directory())
	if config.eula_accepted:
		var f := FileAccess.open(working_directory().path_join("eula.txt"), FileAccess.WRITE)
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
	while PlatformBackend.get_current().process_cwd(orphan_pid) == working_directory() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.5).timeout
	if PlatformBackend.get_current().process_cwd(orphan_pid) == working_directory():
		OS.kill(orphan_pid)
	orphan_pid = -1
	_remove_pid_file()
	log_system("Leftover server stopped.")
	state_changed.emit(state)


# --- Re-attaching ------------------------------------------------------------

## PID of this server's process if it is already running (started by an earlier
## session of the manager, or outside it), or -1.
func find_running_pid() -> int:
	var pid := find_orphan_pid()
	if pid <= 0:
		pid = PlatformBackend.get_current().find_java_in_dir(working_directory())
	return pid


## True for a re-attached server without RCON: the console is read-only.
func is_read_only() -> bool:
	return process.is_attached() and not rcon.is_ready()


func _attach_on_ready(pid: int) -> void:
	var err := attach_running(pid)
	if err != OK:
		orphan_pid = pid
		log_system("This server is running (PID %d) but could not be re-attached: %s. Use \"Stop leftover process\" before starting it again." % [pid, error_string(err)], LogParser.Level.WARN)
		state_changed.emit(state)


## Takes control of an already-running server: output from logs/latest.log, commands
## and stop through RCON, statistics from the PID.
func attach_running(pid: int) -> Error:
	if is_busy():
		return ERR_ALREADY_IN_USE
	var err := process.attach(pid, working_directory().path_join("logs/latest.log"))
	if err != OK:
		return err
	orphan_pid = -1
	wake_listener.close()
	_write_pid_file(pid)
	_stop_requested = false
	_restart_after_stop = false
	_replay_until_msec = Time.get_ticks_msec() + 1500
	var age := PlatformBackend.get_current().process_age_seconds(pid)
	start_time_msec = Time.get_ticks_msec() - maxi(age, 0) * 1000
	startup_seconds = -1.0
	tps = -1.0
	players.clear()
	monitor.track(pid)
	scheduler.on_server_started()
	log_system("Re-attached to the running server (PID %d, up %s). The console follows logs/latest.log; commands go through RCON." % [pid, Fmt.duration(maxi(age, 0))])
	# Still booting if the game port is not open yet; the "Done" line will flip it to running.
	if PlatformBackend.is_port_free(config.port):
		_set_state(State.STARTING)
	else:
		_set_state(State.RUNNING)
		max_players = get_properties().get_int("max-players", max_players)
		_connect_rcon()
		_query_timer.start()
	Notifier.info("Re-attached to %s, which was still running." % config.display_name, Notifier.Category.SERVER_STATE, config.display_name)
	return OK


## PID of a server process left running by a previous session of the manager, or -1.
func find_orphan_pid() -> int:
	var path := config.meta_dir().path_join("server.pid")
	if not FileAccess.file_exists(path):
		return -1
	var pid := FileAccess.get_file_as_string(path).strip_edges().to_int()
	if pid > 0 and PlatformBackend.get_current().process_cwd(pid) == working_directory():
		return pid
	_remove_pid_file()
	return -1


static func _lan_ip() -> String:
	# Prefer the address on the interface that leads to the router (others may be VPNs or VMs).
	var route := PlatformBackend.get_current().default_route()
	if str(route.get("address", "")) != "":
		return route.address
	for addr in IP.get_local_addresses():
		if addr.begins_with("192.168.") or addr.begins_with("10.") or (addr.begins_with("172.") and addr.get_slice(".", 1).to_int() in range(16, 32)):
			return addr
	return "localhost"
