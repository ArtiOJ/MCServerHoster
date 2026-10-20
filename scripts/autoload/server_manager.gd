extends ServerSource
## Registry of all servers on this computer. Creates, loads and deletes servers and
## coordinates app-wide actions (auto-start, update checks, stop-all on exit).
## Each server is a ServerInstance scene added as a child of this node.

## Relayed from instances: a temporary run stopped and needs a keep/discard decision.
signal temporary_run_ended(instance: ServerInstance)

const INSTANCE_SCENE := preload("res://scenes/runtime/server_instance.tscn")
const FIRST_GAME_PORT := 25565
const FIRST_RCON_PORT := 25575

var _instances: Array[ServerInstance] = []


func _ready() -> void:
	if AppSettings.other_instance_pid > 0 or AppSettings.phone:
		return  # Another Server Manager owns these servers, or this is the phone app.
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


func get_handles() -> Array[ServerHandle]:
	var out: Array[ServerHandle] = []
	out.assign(_instances)
	return out


func find_handle(handle_key: String) -> ServerHandle:
	return get_instance(handle_key)


func delete_handle(handle: ServerHandle, delete_files := true, delete_backups := false) -> Dictionary:
	var err := delete_server(handle.config.id, delete_files, delete_backups)
	if err == ERR_BUSY:
		return {"ok": false, "error": "Stop %s before deleting it." % handle.config.display_name}
	return {"ok": err == OK, "error": "" if err == OK else "Could not delete %s: %s" % [handle.config.display_name, error_string(err)]}


func duplicate_handle(handle: ServerHandle, display_name: String, copy_worlds := true, copy_plugins := true, on_status := Callable()) -> Dictionary:
	return await duplicate_server(handle as ServerInstance, display_name, copy_worlds, copy_plugins, on_status)


func call_host_op(op: String, args := {}, on_progress := Callable()) -> Dictionary:
	var ctx := ServerOps.LOCAL_CONTEXT.duplicate()
	ctx["progress"] = on_progress
	var result: Dictionary = await HostOps.run(op, args, ctx)
	return JSON.parse_string(JSON.stringify(result))


func get_instance(server_id: String) -> ServerInstance:
	for inst in _instances:
		if inst.config.id == server_id:
			return inst
	return null


func any_running() -> bool:
	return running_count() > 0


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

	var id := unique_id(spec.name)
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
	cfg.auto_start = bool(spec.get("auto_start", false))
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
	props.save_file(cfg.properties_path())
	# Remaining catalog settings (Paper/Spigot/Bukkit YAML, game rules) from the wizard.
	var settings := ServerSettings.open(cfg)
	var extra: Dictionary = spec.get("settings", {})
	for setting_id in extra:
		settings.set_by_id(setting_id, str(extra[setting_id]))
	settings.save()
	cfg.write_managed_properties()
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


## Folder-safe id derived from [param display_name] that no server or folder uses yet.
func unique_id(display_name: String) -> String:
	var base_id := Fmt.slugify(display_name)
	var id := base_id
	var n := 2
	while get_instance(id) != null or DirAccess.dir_exists_absolute(AppSettings.servers_root.path_join(id)):
		id = "%s-%d" % [base_id, n]
		n += 1
	return id


## Copies an existing server into a new, independent server with its own ports.
## Worlds are flushed first when the source is running. [param on_status] receives (text).
func duplicate_server(source: ServerInstance, display_name: String, copy_worlds := true, copy_plugins := true, on_status := Callable()) -> Dictionary:
	var report := func(text: String) -> void:
		if on_status.is_valid():
			on_status.call(text)
	if source.state == ServerInstance.State.INSTALLING:
		return {"ok": false, "error": "%s is busy." % source.config.display_name}
	var id := unique_id(display_name)
	var dir := AppSettings.servers_root.path_join(id)
	var src := source.working_directory()
	report.call("Copying files…")
	var was_online: bool = await source.backups.pause_saving()
	var err: Error = await FileOps.run_async(self, func() -> Error: return FileOps.copy_tree(src, dir))
	if was_online:
		source.backups.resume_saving()
	if err != OK:
		FileOps.remove_path(dir)
		return {"ok": false, "error": "Copy failed: %s" % error_string(err)}

	report.call("Configuring the copy…")
	for leftover in [ServerConfig.META_DIR.path_join("server.pid"), ServerConfig.META_DIR.path_join("jars"), "logs"]:
		FileOps.remove_path(dir.path_join(leftover))
	if not copy_worlds:
		for world in source.backups.world_dirs():
			FileOps.remove_path(dir.path_join(world))
	if not copy_plugins:
		FileOps.remove_path(dir.path_join("plugins"))
	var cfg := ServerConfig.from_dict(source.config.to_dict(), dir)
	cfg.id = id
	cfg.display_name = display_name
	cfg.color = Color.from_hsv(fmod(source.config.color.h + 0.12, 1.0), source.config.color.s, source.config.color.v)
	cfg.created_unix = int(Time.get_unix_time_from_system())
	cfg.auto_start = false
	cfg.temp_run_dir = ""
	cfg.port = allocate_game_port()
	cfg.rcon_port = allocate_rcon_port()
	cfg.rcon_password = Fmt.random_token(24)
	if not copy_worlds:
		cfg.known_gamerules.clear()
	cfg.write_managed_properties()
	err = cfg.save()
	if err != OK:
		FileOps.remove_path(dir)
		return {"ok": false, "error": "Cannot save the copy's config: %s" % error_string(err)}
	AppSettings.register_server_dir(dir)
	var inst := _register(cfg)
	inst.log_system("Duplicated from %s (%s, %s)." % [source.config.display_name,
			"with worlds" if copy_worlds else "without worlds", "with plugins" if copy_plugins else "without plugins"])
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


## Imports a server folder that was not created by the manager (see ServerImporter).
## [param options]: analysis (from ServerImporter.analyze), display_name, mode
## ("in_place" adds only .manager/ to the folder; "copy" copies it into the servers
## folder first), port, ram_max_mb, switch_to_paper, accept_eula.
## [param on_status] receives (text, fraction).
func import_existing_server(dir: String, options: Dictionary, on_status := Callable()) -> Dictionary:
	var report := func(text: String, fraction: float) -> void:
		if on_status.is_valid():
			on_status.call(text, fraction)
	var a: Dictionary = options.get("analysis", ServerImporter.analyze(dir))
	if a.managed:
		return import_server(dir)
	if not a.can_import:
		return {"ok": false, "error": a.error if a.error != "" else "This folder cannot be imported."}
	for inst in _instances:
		if inst.config.directory == dir:
			return {"ok": false, "error": "That server is already managed."}
	var display_name := str(options.get("display_name", dir.get_file())).strip_edges()
	if display_name == "":
		display_name = dir.get_file()
	var id := unique_id(display_name)
	var target := dir
	if options.get("mode", "in_place") == "copy":
		if PlatformBackend.get_current().find_java_in_dir(dir) > 0:
			return {"ok": false, "error": "Stop the server before copying it (it is running)."}
		target = AppSettings.servers_root.path_join(id)
		report.call("Copying the server folder…", 0.05)
		var err: Error = await FileOps.run_async(self, func() -> Error: return FileOps.copy_tree(dir, target))
		if err != OK:
			FileOps.remove_path(target)
			return {"ok": false, "error": "Copy failed: %s" % error_string(err)}

	var cfg := ServerConfig.new()
	cfg.id = id
	cfg.directory = target
	cfg.display_name = display_name
	cfg.created_unix = int(Time.get_unix_time_from_system())
	cfg.mc_version = a.mc_version
	cfg.paper_build = int(a.build)
	cfg.jar_file = a.jar
	cfg.eula_accepted = bool(a.eula_accepted) or bool(options.get("accept_eula", false))
	cfg.ram_max_mb = maxi(int(options.get("ram_max_mb", a.ram_max_mb if a.ram_max_mb > 0 else AppSettings.default_ram_mb)), 512)
	cfg.ram_min_mb = clampi(int(a.ram_min_mb) if a.ram_min_mb > 0 else cfg.ram_max_mb / 4, 256, cfg.ram_max_mb)
	cfg.jvm_preset = ServerConfig.JvmPreset.AIKAR if a.aikar_flags else ServerConfig.JvmPreset.PAPER_RECOMMENDED
	cfg.extra_jvm_args = a.extra_jvm_args
	cfg.port = int(options.get("port", a.port))
	cfg.rcon_port = allocate_rcon_port()
	cfg.rcon_password = Fmt.random_token(24)
	report.call("Looking up Paper %s…" % cfg.mc_version, 0.3)
	var vinfo: Dictionary = await PaperApi.fetch_version_info(cfg.mc_version)
	if vinfo.get("ok", false):
		cfg.java_min_version = int(vinfo.java_min)
		cfg.recommended_flags = vinfo.flags

	if options.get("switch_to_paper", false):
		var latest: Dictionary = await PaperApi.fetch_latest_build(cfg.mc_version, true)
		if not latest.ok:
			return {"ok": false, "error": "No Paper build for %s: %s" % [cfg.mc_version, latest.error]}
		var tmp_jar := target.path_join("paper.jar.download")
		var dl: Dictionary = await PaperApi.download_build(latest.build, tmp_jar, func(done: int, total: int) -> void:
			report.call("Downloading Paper %s… %s / %s" % [cfg.mc_version, Fmt.bytes(done), Fmt.bytes(total)], 0.35 + 0.55 * float(done) / maxf(total, 1.0)))
		if not dl.ok:
			DirAccess.remove_absolute(tmp_jar)
			return dl
		# Keep the previous jar for rollback, out of the way of the server folder.
		var archive := cfg.meta_dir().path_join("jars")
		DirAccess.make_dir_recursive_absolute(archive)
		if a.jar != "" and FileAccess.file_exists(target.path_join(a.jar)):
			DirAccess.rename_absolute(target.path_join(a.jar), archive.path_join(a.jar))
		DirAccess.rename_absolute(tmp_jar, target.path_join("paper.jar"))
		cfg.jar_file = "paper.jar"
		cfg.paper_build = int(latest.build.id)
		cfg.build_channel = str(latest.build.channel)

	report.call("Saving configuration…", 0.95)
	var save_err := cfg.save()
	if save_err != OK:
		return {"ok": false, "error": "Cannot save the server config: %s" % error_string(save_err)}
	AppSettings.register_server_dir(target)
	var inst := _register(cfg)
	inst.log_system("Imported from %s (%s %s%s)." % [dir, a.software_name, a.mc_version,
			", switched to Paper" if options.get("switch_to_paper", false) else ""])
	report.call("Done", 1.0)
	return {"ok": true, "instance": inst}


## Removes a server. With [param delete_files] its folder is deleted permanently
## (nothing goes to the system trash).
func delete_server(server_id: String, delete_files := true, delete_backups := false) -> Error:
	var inst := get_instance(server_id)
	if inst == null:
		return ERR_DOES_NOT_EXIST
	if inst.is_process_alive() or inst.state == ServerInstance.State.INSTALLING:
		return ERR_BUSY
	var dir := inst.config.directory
	var backup_dir := inst.backups.backup_dir()
	if inst.is_temporary():
		FileOps.remove_path(inst.config.temp_run_dir)
	if delete_files and DirAccess.dir_exists_absolute(dir):
		var err := _remove_dir_recursive(dir)
		if err != OK:
			return err
	if delete_backups and DirAccess.dir_exists_absolute(backup_dir):
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
				_notify_update(inst)


## Notifies about a newer Paper build once per build (remembered across launches).
func _notify_update(inst: ServerInstance) -> void:
	var build := inst.update_available_build
	if build <= 0 or int(AppSettings.notified_update_builds.get(inst.config.id, 0)) >= build:
		return
	AppSettings.notified_update_builds[inst.config.id] = build
	AppSettings.save_settings()
	Notifier.info("Paper build #%d is available for %s (Minecraft %s)." % [build, inst.config.display_name, inst.config.mc_version],
			Notifier.Category.UPDATE, inst.config.display_name)


func _register(cfg: ServerConfig) -> ServerInstance:
	var inst: ServerInstance = INSTANCE_SCENE.instantiate()
	inst.setup(cfg)
	add_child(inst)
	inst.state_changed.connect(func(_s: ServerInstance.State) -> void: server_state_changed.emit(inst))
	inst.temporary_run_ended.connect(func() -> void: temporary_run_ended.emit(inst))
	_instances.append(inst)
	server_added.emit(inst)
	return inst


func _auto_start() -> void:
	if not AppSettings.autostart_enabled:
		return
	for inst in _instances:
		if inst.config.auto_start and inst.orphan_pid <= 0 and not inst.is_temporary():
			inst.start()
	for inst in _instances:
		inst.scheduler.catch_up_wake_on_join()
		inst.scheduler.fire(EventRule.Trigger.APP_STARTED)


static func _remove_dir_recursive(path: String) -> Error:
	return FileOps.remove_tree(path)
