extends Node
## Registry of all managed servers. Creates, loads and deletes servers and
## coordinates app-wide actions (auto-start, update checks, stop-all on exit).
## Each server is a ServerInstance scene added as a child of this node.

signal server_added(instance: ServerInstance)
signal server_removed(server_id: String)
signal server_state_changed(instance: ServerInstance)

const INSTANCE_SCENE := preload("res://scenes/runtime/server_instance.tscn")
const FIRST_GAME_PORT := 25565
const FIRST_RCON_PORT := 25575

var _instances: Array[ServerInstance] = []


func _ready() -> void:
	for dir in AppSettings.server_dirs:
		var cfg := ServerConfig.load_from_dir(dir)
		if cfg == null:
			push_warning("Skipping missing or unreadable server folder: " + dir)
			continue
		_register(cfg)
	_auto_start.call_deferred()
	if AppSettings.check_updates_on_launch:
		check_updates.call_deferred()


func get_instances() -> Array[ServerInstance]:
	return _instances


func get_instance(server_id: String) -> ServerInstance:
	for inst in _instances:
		if inst.config.id == server_id:
			return inst
	return null


func running_count() -> int:
	return _instances.filter(func(i: ServerInstance) -> bool: return i.is_process_alive()).size()


func any_running() -> bool:
	return running_count() > 0


## RAM (MB) reserved by servers whose process is alive.
func allocated_ram_mb() -> int:
	var total := 0
	for inst in _instances:
		if inst.is_process_alive():
			total += inst.config.ram_max_mb
	return total


## Server (other than [param except_id]) that uses [param port] as game or RCON port, or null.
func port_owner(port: int, except_id := "", running_only := false) -> ServerInstance:
	for inst in _instances:
		if inst.config.id == except_id:
			continue
		if running_only and not inst.is_process_alive():
			continue
		if inst.config.port == port or inst.config.rcon_port == port:
			return inst
	return null


func allocate_game_port(except_id := "") -> int:
	var port := FIRST_GAME_PORT
	while port_owner(port, except_id) != null or not PlatformBackend.is_port_free(port):
		port += 1
	return port


func allocate_rcon_port(except_id := "") -> int:
	var port := FIRST_RCON_PORT
	while port_owner(port, except_id) != null or not PlatformBackend.is_port_free(port):
		port += 1
	return port


## Creates and installs a new server.
## [param spec]: name, color, version, build (from PaperApi), version_info, ram_max_mb,
## ram_min_mb, cpu_cores, port, properties (Dictionary of server.properties overrides).
## [param on_progress] receives (stage: String, fraction: float).
func create_server(spec: Dictionary, on_progress := Callable()) -> Dictionary:
	var report := func(stage: String, fraction: float) -> void:
		if on_progress.is_valid():
			on_progress.call(stage, fraction)

	var base_id := Fmt.slugify(spec.name)
	var id := base_id
	var n := 2
	while get_instance(id) != null or DirAccess.dir_exists_absolute(AppSettings.servers_root.path_join(id)):
		id = "%s-%d" % [base_id, n]
		n += 1
	var dir := AppSettings.servers_root.path_join(id)
	report.call("Creating server folder…", 0.02)
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		return {"ok": false, "error": "Cannot create %s: %s" % [dir, error_string(err)]}

	var cfg := ServerConfig.new()
	cfg.id = id
	cfg.directory = dir
	cfg.display_name = spec.name
	cfg.color = spec.get("color", cfg.color)
	cfg.created_unix = int(Time.get_unix_time_from_system())
	cfg.mc_version = spec.version
	cfg.paper_build = int(spec.build.id)
	cfg.build_channel = str(spec.build.channel)
	cfg.eula_accepted = true
	cfg.ram_max_mb = int(spec.get("ram_max_mb", AppSettings.default_ram_mb))
	cfg.ram_min_mb = clampi(int(spec.get("ram_min_mb", cfg.ram_max_mb / 2)), 256, cfg.ram_max_mb)
	cfg.cpu_cores = int(spec.get("cpu_cores", 0))
	cfg.port = int(spec.get("port", allocate_game_port()))
	cfg.rcon_port = allocate_rcon_port()
	cfg.rcon_password = Fmt.random_token(24)
	var vinfo: Dictionary = spec.get("version_info", {})
	if vinfo.get("ok", false):
		cfg.java_min_version = int(vinfo.java_min)
		cfg.recommended_flags = vinfo.flags

	report.call("Downloading Paper %s build #%d…" % [cfg.mc_version, cfg.paper_build], 0.05)
	var dl: Dictionary = await PaperApi.download_build(spec.build, cfg.jar_path(), func(done: int, total: int) -> void:
		report.call("Downloading Paper %s build #%d… %s / %s" % [cfg.mc_version, cfg.paper_build, Fmt.bytes(done), Fmt.bytes(total)], 0.05 + 0.85 * float(done) / maxf(total, 1.0)))
	if not dl.ok:
		_remove_dir_recursive(dir)
		return dl

	report.call("Writing configuration…", 0.92)
	var props := ServerProperties.new()
	for key in PropertySchema.NEW_SERVER_DEFAULTS:
		props.set_value(key, PropertySchema.NEW_SERVER_DEFAULTS[key])
	var overrides: Dictionary = spec.get("properties", {})
	for key in overrides:
		props.set_value(key, overrides[key])
	props.set_value("server-port", cfg.port)
	props.set_value("query.port", cfg.port)
	props.set_value("enable-rcon", true)
	props.set_value("rcon.port", cfg.rcon_port)
	props.set_value("rcon.password", cfg.rcon_password)
	props.set_value("broadcast-rcon-to-ops", false)
	props.save_file(cfg.properties_path())
	var eula := FileAccess.open(dir.path_join("eula.txt"), FileAccess.WRITE)
	eula.store_string("# Accepted in Server Manager (https://aka.ms/MinecraftEULA)\neula=true\n")
	eula.close()
	err = cfg.save()
	if err != OK:
		_remove_dir_recursive(dir)
		return {"ok": false, "error": "Cannot save server config: %s" % error_string(err)}

	AppSettings.register_server_dir(dir)
	var inst := _register(cfg)
	inst.log_system("Server created: Paper %s build #%d in %s" % [cfg.mc_version, cfg.paper_build, dir])
	report.call("Done", 1.0)
	return {"ok": true, "instance": inst}


## Adds an existing server folder (one that already has a manager config) to the list.
func import_server(dir: String) -> Dictionary:
	for inst in _instances:
		if inst.config.directory == dir:
			return {"ok": false, "error": "That server is already managed."}
	var cfg := ServerConfig.load_from_dir(dir)
	if cfg == null:
		return {"ok": false, "error": "No Server Manager configuration found in that folder."}
	if get_instance(cfg.id) != null:
		cfg.id = "%s-%s" % [cfg.id, Fmt.random_token(4).to_lower()]
		cfg.save()
	AppSettings.register_server_dir(dir)
	return {"ok": true, "instance": _register(cfg)}


## Removes a server. With [param delete_files] its folder is moved to the system
## trash (or permanently deleted if [param use_trash] is false).
func delete_server(server_id: String, delete_files := true, use_trash := true, delete_backups := false) -> Error:
	var inst := get_instance(server_id)
	if inst == null:
		return ERR_DOES_NOT_EXIST
	if inst.is_process_alive() or inst.state == ServerInstance.State.INSTALLING:
		return ERR_BUSY
	var dir := inst.config.directory
	var backup_dir := inst.backups.backup_dir()
	if delete_files and DirAccess.dir_exists_absolute(dir):
		var err := OS.move_to_trash(dir) if use_trash else _remove_dir_recursive(dir)
		if err != OK:
			return err
	if delete_backups and DirAccess.dir_exists_absolute(backup_dir):
		if use_trash:
			OS.move_to_trash(backup_dir)
		else:
			_remove_dir_recursive(backup_dir)
	AppSettings.unregister_server_dir(dir)
	_instances.erase(inst)
	inst.queue_free()
	server_removed.emit(server_id)
	return OK


func start_all() -> void:
	for inst in _instances:
		if not inst.is_busy():
			inst.start()


func stop_all() -> void:
	for inst in _instances:
		inst.stop()


## Stops every server and waits (up to each server's own timeout) until all have exited.
func stop_all_and_wait() -> void:
	stop_all()
	while any_running():
		await get_tree().create_timer(0.25).timeout


## Checks PaperMC for newer builds of each server's Minecraft version.
func check_updates() -> void:
	var by_version := {}
	for inst in _instances:
		if inst.config.mc_version != "":
			by_version[inst.config.mc_version] = true
	for version in by_version:
		var res: Dictionary = await PaperApi.fetch_latest_build(version, true)
		if not res.ok:
			continue
		for inst in _instances:
			if is_instance_valid(inst) and inst.config.mc_version == version:
				inst.set_update_available(int(res.build.id))


func _register(cfg: ServerConfig) -> ServerInstance:
	var inst: ServerInstance = INSTANCE_SCENE.instantiate()
	inst.setup(cfg)
	add_child(inst)
	inst.state_changed.connect(func(_s: ServerInstance.State) -> void: server_state_changed.emit(inst))
	_instances.append(inst)
	server_added.emit(inst)
	return inst


func _auto_start() -> void:
	if not AppSettings.autostart_enabled:
		return
	for inst in _instances:
		if inst.config.auto_start and inst.orphan_pid <= 0:
			inst.start()


static func _remove_dir_recursive(path: String) -> Error:
	var dir := DirAccess.open(path)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		var sub := path.path_join(d)
		# Never follow symlinks out of the folder being deleted.
		if dir.is_link(d):
			dir.remove(d)
		else:
			_remove_dir_recursive(sub)
	return DirAccess.remove_absolute(path)
