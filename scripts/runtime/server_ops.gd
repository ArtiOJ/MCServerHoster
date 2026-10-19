class_name ServerOps
extends RefCounted
## The server-level operations behind the tabs (plugins, backups, logs, player lists,
## worlds, resources, automation, network). Both a local tab and a remote host call
## [method run], so a server on another computer behaves exactly like one on this one.
##
## Arguments and results are plain JSON values. Arguments that name files on this computer
## ("files", "source", "dest") come only from local callers; a remote session replaces
## them with its own staged uploads and download folder (see RemoteSession).

## Who asks and how: {actor: "" (this computer) or the remote key's name,
## role: RemoteProtocol.Role, progress: Callable(text, fraction)}.
const LOCAL_CONTEXT := {"actor": "", "role": RemoteProtocol.Role.SYSTEM_ADMIN}

const DISABLED_SUFFIX := ".disabled"
## Longest log text sent over the network (the newest part of a bigger file).
const REMOTE_LOG_BYTES := 6 * 1024 * 1024
const LIST_KINDS: PackedStringArray = ["whitelist", "ops", "bans", "ip_bans"]
## Config fields a Resources or Automation save may change.
const CONFIG_FIELDS: PackedStringArray = [
	"ram_max_mb", "ram_min_mb", "memory_hard_cap", "cpu_cores", "cpu_quota_pct", "cpu_affinity",
	"nice_level", "java_path", "jvm_preset", "extra_jvm_args", "extra_server_args", "port",
	"auto_start", "auto_restart", "max_restarts", "restart_window_sec", "stop_timeout_sec",
	"events", "backup_retention", "backup_full", "wake_on_connect", "wake_on_ping", "wake_motd",
]
## Fields that start programs or reach outside the server folder: system admins only.
const SYSTEM_FIELDS: PackedStringArray = ["java_path", "extra_jvm_args", "extra_server_args"]
## How long an analysed world import waits for the user's decision.
const IMPORT_TTL_MSEC := 3600 * 1000

## Analysed world imports waiting for confirmation: token -> {server, analysis, msec}.
static var _imports := {}


static func run(inst: ServerInstance, op: String, args: Dictionary, ctx := LOCAL_CONTEXT) -> Dictionary:
	match op:
		"plugins_list": return plugins_list(inst)
		"plugin_install": return plugin_install(inst, _paths(args.get("files")), ctx)
		"plugin_toggle": return plugin_toggle(inst, str(args.get("file", "")), ctx)
		"plugin_delete": return plugin_delete(inst, str(args.get("file", "")), ctx)
		"backups_list": return backups_list(inst)
		"backup_create": return await backup_create(inst, bool(args.get("full", false)), ctx)
		"backup_restore": return await backup_restore(inst, str(args.get("name", "")), ctx)
		"backup_delete": return backup_delete(inst, str(args.get("name", "")), ctx)
		"backup_file": return backup_file(inst, str(args.get("name", "")), str(args.get("dest", "")))
		"logs_list": return logs_list(inst)
		"log_read": return await log_read(inst, str(args.get("id", "")), ctx)
		"lists_get": return lists_get(inst)
		"list_add": return await list_add(inst, str(args.get("kind", "")), str(args.get("value", "")).strip_edges(), _dict(args.get("options")), ctx)
		"list_remove": return list_remove(inst, str(args.get("kind", "")), str(args.get("value", "")).strip_edges(), ctx)
		"op_level": return op_level(inst, str(args.get("player", "")), int(args.get("level", 4)), ctx)
		"whitelist_set": return whitelist_set(inst, bool(args.get("enabled", false)), ctx)
		"worlds_list": return await worlds_list(inst, bool(args.get("sizes", true)))
		"world_activate": return world_activate(inst, str(args.get("folder", "")), ctx)
		"world_reset": return await world_reset(inst, str(args.get("folder", "")), str(args.get("seed", "")), bool(args.get("keep_players", false)), ctx)
		"world_delete": return world_delete(inst, str(args.get("folder", "")), ctx)
		"world_export": return await world_export(inst, str(args.get("folder", "")), str(args.get("dest", "")), ctx)
		"datapack_add": return datapack_add(inst, _paths(args.get("files")), ctx)
		"datapack_toggle": return await datapack_toggle(inst, str(args.get("id", "")), bool(args.get("enable", true)), ctx)
		"datapack_remove": return datapack_remove(inst, str(args.get("id", "")), ctx)
		"world_import_analyze": return await world_import_analyze(inst, _paths(args.get("files")))
		"world_import": return await world_import(inst, str(args.get("token", "")), int(args.get("mode", 0)), bool(args.get("apply", false)), ctx, int(args.get("dimension", 0)))
		"world_import_cancel": return world_import_cancel(str(args.get("token", "")))
		"resources_info": return resources_info(inst)
		"port_check": return port_check(inst, int(args.get("port", 0)))
		"launch_preview": return launch_preview(inst, _dict(args.get("config")))
		"config_save": return config_save(inst, _dict(args.get("changes")), ctx)
		"network_info": return network_info(inst, ctx)
		"network_refresh": return network_refresh()
		"network_test": return await network_test(inst)
		"port_set": return port_set(inst, int(args.get("port", 0)), ctx)
		"upnp_set": return upnp_set(inst, bool(args.get("on", false)), ctx)
		"upnp_retry": return upnp_retry(inst)
		"firewall_allow": return await firewall_allow(inst, ctx)
	return {"ok": false, "error": "Unknown request \"%s\"." % op}


static func _ok(extra := {}) -> Dictionary:
	var out := {"ok": true}
	out.merge(extra)
	return out


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array or value is PackedStringArray:
		for v in value:
			out.append(str(v))
	return out


static func _is_remote(ctx: Dictionary) -> bool:
	return str(ctx.get("actor", "")) != ""


static func _is_system(ctx: Dictionary) -> bool:
	return int(ctx.get("role", RemoteProtocol.Role.SYSTEM_ADMIN)) == RemoteProtocol.Role.SYSTEM_ADMIN


## Writes a line to the server console; remote actions name who did them.
static func _log(inst: ServerInstance, ctx: Dictionary, what: String) -> void:
	if _is_remote(ctx):
		inst.log_system("%s (remote) %s" % [ctx.actor, what.left(1).to_lower() + what.substr(1)])
	else:
		inst.log_system(what)


static func _progress(ctx: Dictionary, text: String, fraction := -1.0) -> void:
	var cb: Callable = ctx.get("progress", Callable())
	if cb.is_valid():
		cb.call(text, fraction)


## A bare file name (no folders, no "..").
static func _is_plain_name(file: String) -> bool:
	return file != "" and file == file.get_file() and file != "." and file != ".." and not file.contains("\\")


static func _plural(n: int, word: String) -> String:
	return "%d %s%s" % [n, word, "" if n == 1 else "s"]


# --- Plugins -------------------------------------------------------------------------

static func plugins_dir(inst: ServerInstance) -> String:
	return inst.config.directory.path_join("plugins")


## {plugins: [{file, name, version, description, size, enabled}], folder, restart_needed}
static func plugins_list(inst: ServerInstance) -> Dictionary:
	var dir := plugins_dir(inst)
	var out: Array = []
	for f in DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray():
		var enabled := f.ends_with(".jar")
		if not enabled and not f.ends_with(".jar" + DISABLED_SUFFIX):
			continue
		var path := dir.path_join(f)
		var meta := read_plugin_meta(path)
		var file := FileAccess.open(path, FileAccess.READ)
		out.append({
			"file": f, "name": meta.get("name", f.trim_suffix(DISABLED_SUFFIX).trim_suffix(".jar")),
			"version": meta.get("version", ""), "description": meta.get("description", ""),
			"size": file.get_length() if file != null else 0, "enabled": enabled,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.file).naturalnocasecmp_to(str(b.file)) < 0)
	return _ok({"plugins": out, "folder": dir, "restart_needed": inst.plugins_changed_while_running and inst.is_process_alive()})


## Copies plugin jars into the plugins folder. {installed: [names], skipped: [messages]}
static func plugin_install(inst: ServerInstance, files: PackedStringArray, ctx: Dictionary) -> Dictionary:
	var dir := plugins_dir(inst)
	DirAccess.make_dir_recursive_absolute(dir)
	var installed := PackedStringArray()
	var skipped := PackedStringArray()
	for path in files:
		var name := path.get_file()
		if not name.to_lower().ends_with(".jar") or not _is_plain_name(name):
			skipped.append("%s: only .jar plugin files can be installed." % name)
			continue
		var reader := ZIPReader.new()
		if reader.open(path) != OK:
			skipped.append("%s is not a valid .jar file." % name)
			continue
		reader.close()
		var target := dir.path_join(name)
		var err := DirAccess.copy_absolute(path, target)
		if err != OK:
			skipped.append("Could not install %s: %s" % [name, error_string(err)])
			continue
		# A fresh copy supersedes a previously disabled version of the same file.
		if FileAccess.file_exists(target + DISABLED_SUFFIX):
			DirAccess.remove_absolute(target + DISABLED_SUFFIX)
		installed.append(name)
	if not installed.is_empty():
		_plugins_changed(inst)
		_log(inst, ctx, "Installed plugin%s: %s" % ["s" if installed.size() > 1 else "", ", ".join(installed)])
	return {"ok": not installed.is_empty() or files.is_empty(), "installed": installed, "skipped": skipped,
			"error": "\n".join(skipped)}


static func plugin_toggle(inst: ServerInstance, file: String, ctx: Dictionary) -> Dictionary:
	var dir := plugins_dir(inst)
	if not _is_plain_name(file) or not FileAccess.file_exists(dir.path_join(file)):
		return _fail("That plugin no longer exists.")
	var target := file.trim_suffix(DISABLED_SUFFIX) if file.ends_with(DISABLED_SUFFIX) else file + DISABLED_SUFFIX
	if FileAccess.file_exists(dir.path_join(target)):
		return _fail("Cannot rename: %s already exists." % target)
	var err := DirAccess.rename_absolute(dir.path_join(file), dir.path_join(target))
	if err != OK:
		return _fail("Could not rename %s: %s" % [file, error_string(err)])
	_plugins_changed(inst)
	_log(inst, ctx, "%s plugin %s." % ["Enabled" if file.ends_with(DISABLED_SUFFIX) else "Disabled", file.trim_suffix(DISABLED_SUFFIX)])
	return _ok({"file": target})


static func plugin_delete(inst: ServerInstance, file: String, ctx: Dictionary) -> Dictionary:
	var path := plugins_dir(inst).path_join(file)
	if not _is_plain_name(file) or not FileAccess.file_exists(path) or not (file.ends_with(".jar") or file.ends_with(".jar" + DISABLED_SUFFIX)):
		return _fail("That plugin no longer exists.")
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		return _fail("Could not delete %s: %s" % [file, error_string(err)])
	_plugins_changed(inst)
	_log(inst, ctx, "Removed plugin " + file)
	return _ok()


static func _plugins_changed(inst: ServerInstance) -> void:
	if inst.is_process_alive():
		inst.plugins_changed_while_running = true
	inst.data_changed.emit(&"plugins")


## Reads name/version/description from plugin.yml or paper-plugin.yml inside a jar.
static func read_plugin_meta(jar_path: String) -> Dictionary:
	var meta := {}
	var reader := ZIPReader.new()
	if reader.open(jar_path) != OK:
		return meta
	var files := reader.get_files()
	for descriptor in ["paper-plugin.yml", "plugin.yml"]:
		if not files.has(descriptor):
			continue
		var text := reader.read_file(descriptor).get_string_from_utf8()
		for line in text.split("\n"):
			# Only top-level keys (no indentation).
			if line.begins_with(" ") or line.begins_with("\t"):
				continue
			for key in ["name", "version", "description"]:
				if line.begins_with(key + ":") and not meta.has(key):
					var value := line.substr(key.length() + 1).strip_edges()
					meta[key] = value.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
		break
	reader.close()
	return meta


# --- Backups -------------------------------------------------------------------------

## {backups: [{name, size, time, full, safety}], folder, retention, busy}
static func backups_list(inst: ServerInstance) -> Dictionary:
	var list: Array = []
	for b in inst.backups.list_backups():
		list.append({"name": b.name, "size": b.size, "time": b.time, "full": b.full, "safety": b.safety})
	return _ok({"backups": list, "folder": inst.backups.backup_dir(), "retention": inst.config.backup_retention, "busy": inst.backups.busy})


static func backup_create(inst: ServerInstance, full: bool, ctx: Dictionary) -> Dictionary:
	if inst.backups.busy:
		return _fail("A backup of %s is already running." % inst.config.display_name)
	if inst.state == ServerHandle.State.INSTALLING:
		return _fail("Wait until the server has finished installing.")
	if _is_remote(ctx):
		_log(inst, ctx, "Started a %s backup." % ("full" if full else "world"))
	var path: String = await inst.backups.create_backup(full)
	return _ok({"name": path.get_file()}) if path != "" else _fail("The backup failed. See the console for details.")


static func _backup_path(inst: ServerInstance, name: String) -> String:
	if not _is_plain_name(name) or not name.ends_with(".zip"):
		return ""
	var path := inst.backups.backup_dir().path_join(name)
	return path if FileAccess.file_exists(path) else ""


static func backup_restore(inst: ServerInstance, name: String, ctx: Dictionary) -> Dictionary:
	var path := _backup_path(inst, name)
	if path == "":
		return _fail("That backup no longer exists.")
	if inst.is_process_alive():
		return _fail("Stop the server before restoring a backup.")
	if _is_remote(ctx):
		_log(inst, ctx, "Is restoring the backup %s." % name)
	var err: Error = await inst.backups.restore_backup(path)
	inst.data_changed.emit(&"backups")
	inst.data_changed.emit(&"worlds")
	match err:
		OK:
			return _ok()
		ERR_ALREADY_IN_USE:
			return _fail("Stop the server before restoring a backup.")
		ERR_BUSY:
			return _fail("Another backup task is running.")
	return _fail("Restoring %s failed: %s" % [name, error_string(err)])


static func backup_delete(inst: ServerInstance, name: String, ctx: Dictionary) -> Dictionary:
	var path := _backup_path(inst, name)
	if path == "":
		return _fail("That backup no longer exists.")
	inst.backups.delete_backup(path)
	if _is_remote(ctx):
		_log(inst, ctx, "Deleted the backup %s." % name)
	return _ok()


## Copies a backup to [param dest]; without one, returns where it is (a remote session
## turns that into a download).
static func backup_file(inst: ServerInstance, name: String, dest := "") -> Dictionary:
	var path := _backup_path(inst, name)
	if path == "":
		return _fail("That backup no longer exists.")
	if dest != "":
		var err := DirAccess.copy_absolute(path, dest)
		if err != OK:
			return _fail("Could not save %s: %s" % [dest.get_file(), error_string(err)])
		path = dest
	return _ok({"path": path, "name": name})


# --- Logs ------------------------------------------------------------------------------

## {entries: [{id, name, label, kind, size, time}]}; id is the path inside the server folder.
static func logs_list(inst: ServerInstance) -> Dictionary:
	var base := inst.working_directory()
	var out: Array = []
	for e in LogArchive.list_entries(base):
		out.append({"id": str(e.path).trim_prefix(base + "/"), "name": e.name, "label": e.label, "kind": e.kind,
				"size": e.size, "time": e.time, "folder": str(e.path).get_base_dir()})
	return _ok({"entries": out})


## {text, truncated} of one log from [method logs_list]. Remote callers get at most the
## newest [constant REMOTE_LOG_BYTES].
static func log_read(inst: ServerInstance, id: String, ctx: Dictionary) -> Dictionary:
	var base := inst.working_directory()
	var path := ""
	for e in LogArchive.list_entries(base):
		if str(e.path).trim_prefix(base + "/") == id:
			path = e.path
	if path == "":
		return _fail("That log file no longer exists.")
	var result: Dictionary = await FileOps.run_async(inst, func() -> Dictionary: return LogArchive.read_text(path))
	if not result.ok:
		return result
	if _is_remote(ctx) and result.text.length() > REMOTE_LOG_BYTES:
		var text: String = result.text
		var cut := text.length() - REMOTE_LOG_BYTES
		var newline := text.find("\n", cut)
		result.text = text.substr(newline + 1 if newline >= 0 else cut)
		result.truncated = true
		result["limit"] = REMOTE_LOG_BYTES
	return result


# --- Player lists ------------------------------------------------------------------------

static func _list_kind(kind: String) -> int:
	return LIST_KINDS.find(kind)


## How list edits apply right now: "files" (stopped), "commands" (running), or "".
static func list_mode(inst: ServerInstance) -> String:
	if inst.state in [ServerHandle.State.STARTING, ServerHandle.State.STOPPING, ServerHandle.State.INSTALLING]:
		return ""
	if inst.is_process_alive():
		return "commands" if inst.can_send_commands() and inst.is_online() else ""
	return "files"


## {mode, online_uuids, whitelist_on, default_level, lists: {kind: [{value, text, tooltip, level?}]}}
static func lists_get(inst: ServerInstance) -> Dictionary:
	var dir := inst.working_directory()
	var lists := {}
	for i in LIST_KINDS.size():
		lists[LIST_KINDS[i]] = panel_entries(dir, i as PlayerLists.Kind)
	var props := inst.get_properties()
	return _ok({
		"mode": list_mode(inst), "online_uuids": PlayerLists.uses_online_uuids(dir),
		"whitelist_on": props.get_bool("white-list", false), "default_level": props.get_int("op-permission-level", 4),
		"lists": lists,
	})


## ItemList rows for one list: {value, text, tooltip, [level]}.
static func panel_entries(dir: String, kind: PlayerLists.Kind) -> Array:
	var out: Array = []
	for e in PlayerLists.read(dir, kind):
		var value := str(e.get("ip" if kind == PlayerLists.Kind.IP_BANS else "name", ""))
		if value == "":
			continue
		var row := {"value": value, "text": value}
		var tip := PackedStringArray()
		if e.has("uuid"):
			tip.append("UUID " + str(e.uuid))
		match kind:
			PlayerLists.Kind.OPS:
				var level := int(e.get("level", 4))
				row["level"] = level
				row["text"] = "%s  ·  level %d" % [value, level]
				if bool(e.get("bypassesPlayerLimit", false)):
					tip.append("May join when the server is full")
			PlayerLists.Kind.BANS, PlayerLists.Kind.IP_BANS:
				tip.append("Reason: " + str(e.get("reason", "")))
				tip.append("Banned %s by %s" % [str(e.get("created", "?")), str(e.get("source", "?"))])
				tip.append("Expires: " + str(e.get("expires", "forever")))
		row["tooltip"] = "\n".join(tip)
		out.append(row)
	return out


## Adds a player name (or an IP for IP bans). Running servers get a command; stopped
## servers' files are edited directly. {ok, error?, via_command}
static func list_add(inst: ServerInstance, kind_name: String, value: String, options: Dictionary, ctx: Dictionary) -> Dictionary:
	var kind := _list_kind(kind_name)
	if kind < 0 or value == "" or value.contains(" ") or value.contains("\n") or value.length() > 64:
		return _fail("Enter a player name." if kind != PlayerLists.Kind.IP_BANS else "Enter an IP address.")
	var reason := str(options.get("reason", "")).strip_edges().replace("\n", " ").left(200)
	var mode := list_mode(inst)
	if mode == "commands":
		var commands := ["whitelist add %s" % value, "op %s" % value, ("ban %s %s" % [value, reason]).strip_edges(), ("ban-ip %s %s" % [value, reason]).strip_edges()]
		_send(inst, ctx, commands[kind])
		_lists_changed_later(inst)
		return _ok({"via_command": true})
	if mode != "files":
		return _fail("Lists can't be changed right now.")
	var dir := inst.working_directory()
	var err := OK
	if kind == PlayerLists.Kind.IP_BANS:
		if not PlayerLists.is_valid_ip(value):
			return _fail("\"%s\" is not an IP address." % value)
		err = PlayerLists.add_ip_ban(dir, value, reason)
	else:
		var profile: Dictionary = await PlayerLists.resolve(inst, dir, value)
		if not profile.ok:
			return _fail(profile.error)
		var opts := {"reason": reason, "level": clampi(int(options.get("level", 4)), 1, 4),
				"bypasses_player_limit": bool(options.get("bypasses_player_limit", false))}
		err = PlayerLists.add_player(dir, kind, profile, opts)
		value = profile.name
	if err != OK:
		return _fail("Could not save %s: %s" % [PlayerLists.FILES[kind], error_string(err)])
	if _is_remote(ctx):
		_log(inst, ctx, "Added %s to %s." % [value, PlayerLists.FILES[kind]])
	inst.data_changed.emit(&"lists")
	return _ok({"via_command": false})


static func list_remove(inst: ServerInstance, kind_name: String, value: String, ctx: Dictionary) -> Dictionary:
	var kind := _list_kind(kind_name)
	if kind < 0 or value == "" or value.contains(" ") or value.contains("\n"):
		return _fail("Nothing to remove.")
	var mode := list_mode(inst)
	if mode == "commands":
		var commands := ["whitelist remove %s", "deop %s", "pardon %s", "pardon-ip %s"]
		_send(inst, ctx, commands[kind] % value)
		_lists_changed_later(inst)
		return _ok({"via_command": true})
	if mode != "files":
		return _fail("Lists can't be changed right now.")
	var err := PlayerLists.remove(inst.working_directory(), kind, value)
	if err != OK and err != ERR_DOES_NOT_EXIST:
		return _fail("Could not save %s: %s" % [PlayerLists.FILES[kind], error_string(err)])
	if _is_remote(ctx):
		_log(inst, ctx, "Removed %s from %s." % [value, PlayerLists.FILES[kind]])
	inst.data_changed.emit(&"lists")
	return _ok({"via_command": false})


## Changes an operator's permission level (only while the server is stopped).
static func op_level(inst: ServerInstance, player: String, level: int, ctx: Dictionary) -> Dictionary:
	if list_mode(inst) != "files":
		return _fail("Stop the server to change operator levels.")
	var err := PlayerLists.set_op_level(inst.working_directory(), player, clampi(level, 1, 4))
	if err != OK:
		return _fail("Could not save ops.json: %s" % error_string(err))
	if _is_remote(ctx):
		_log(inst, ctx, "Set %s's operator level to %d." % [player, level])
	inst.data_changed.emit(&"lists")
	return _ok()


static func whitelist_set(inst: ServerInstance, enabled: bool, ctx: Dictionary) -> Dictionary:
	if inst.state in [ServerHandle.State.STARTING, ServerHandle.State.STOPPING, ServerHandle.State.INSTALLING]:
		return _fail("Wait until the server has finished starting or stopping.")
	if inst.is_online():
		_send(inst, ctx, "whitelist on" if enabled else "whitelist off")
		_lists_changed_later(inst)
		return _ok({"via_command": true})
	var props := inst.get_properties()
	props.set_value("white-list", enabled)
	var err := props.save_file(inst.config.properties_path())
	if err != OK:
		return _fail("Could not update server.properties: %s" % error_string(err))
	if _is_remote(ctx):
		_log(inst, ctx, "%s the whitelist." % ("Enabled" if enabled else "Disabled"))
	inst.data_changed.emit(&"lists")
	return _ok({"via_command": false})


static func _send(inst: ServerInstance, ctx: Dictionary, command: String) -> void:
	if _is_remote(ctx):
		inst.send_remote_command(command, "%s, remote" % ctx.actor)
	else:
		inst.send_command(command)


## The server rewrites its list files shortly after a command; views reload then.
static func _lists_changed_later(inst: ServerInstance) -> void:
	await inst.get_tree().create_timer(1.0).timeout
	if is_instance_valid(inst):
		inst.data_changed.emit(&"lists")


# --- Worlds --------------------------------------------------------------------------------

static func _active_level(inst: ServerInstance) -> String:
	return inst.get_properties().get_value("level-name", "world")


## A world of the server by folder name, read fresh from disk ({} if unknown).
static func _find_world(inst: ServerInstance, folder: String, with_size := false) -> Dictionary:
	for w in WorldManager.list_worlds(inst.config.directory, _active_level(inst), with_size):
		if w.folder == folder:
			return w
	return {}


## {worlds: [...], packs: [...], online, online_enabled, online_available, blocker}
static func worlds_list(inst: ServerInstance, with_sizes: bool) -> Dictionary:
	var dir := inst.config.directory
	var level := _active_level(inst)
	var worlds: Array[Dictionary]
	if with_sizes:
		worlds = await FileOps.run_async(inst, func() -> Array[Dictionary]: return WorldManager.list_worlds(dir, level, true))
	else:
		worlds = WorldManager.list_worlds(dir, level, false)
	var out_worlds: Array = []
	var active := {}
	for w in worlds:
		var item := w.duplicate()
		item.erase("datapacks_dir")
		item["layout_name"] = WorldImporter.LAYOUT_NAMES[w.layout]
		item["packs_folder"] = w.datapacks_dir
		out_worlds.append(item)
		if w.active:
			active = w
	var packs: Array = []
	if not active.is_empty():
		for p in WorldManager.list_datapacks(active.datapacks_dir):
			var item: Dictionary = p.duplicate()
			item["folder"] = str(p.path).get_base_dir()
			item.erase("path")
			packs.append(item)
	var online := inst.is_online() and inst.rcon.is_ready()
	var enabled := PackedStringArray()
	var available := PackedStringArray()
	if online:
		enabled = WorldManager.parse_datapack_list(await inst.rcon.execute("datapack list enabled"))
		available = WorldManager.parse_datapack_list(await inst.rcon.execute("datapack list available"))
	return _ok({"worlds": out_worlds, "packs": packs, "online": online, "online_enabled": enabled,
			"online_available": available, "blocker": WorldManager.change_blocker(inst), "folder": dir})


static func world_activate(inst: ServerInstance, folder: String, ctx: Dictionary) -> Dictionary:
	var w := _find_world(inst, folder)
	if w.is_empty():
		return _fail("That world no longer exists.")
	var err := WorldManager.set_active(inst, folder)
	if err != "":
		return _fail(err)
	if _is_remote(ctx):
		_log(inst, ctx, "Made \"%s\" the active world." % folder)
	inst.data_changed.emit(&"worlds")
	return _ok({"name": w.name})


static func world_reset(inst: ServerInstance, folder: String, seed: String, keep_players: bool, ctx: Dictionary) -> Dictionary:
	var w := _find_world(inst, folder)
	if w.is_empty():
		return _fail("That world no longer exists.")
	if _is_remote(ctx):
		_log(inst, ctx, "Is resetting the world \"%s\"." % folder)
	var err: String = await WorldManager.reset_world(inst, w, seed.strip_edges().left(64), keep_players)
	inst.data_changed.emit(&"worlds")
	return _fail(err) if err != "" else _ok()


static func world_delete(inst: ServerInstance, folder: String, ctx: Dictionary) -> Dictionary:
	var w := _find_world(inst, folder)
	if w.is_empty():
		return _fail("That world no longer exists.")
	var err := WorldManager.delete_world(inst, w)
	if err != "":
		return _fail(err)
	if _is_remote(ctx):
		_log(inst, ctx, "Deleted the world \"%s\"." % folder)
	inst.data_changed.emit(&"worlds")
	return _ok()


## Zips a world as a singleplayer save to [param dest]. {path, name}
static func world_export(inst: ServerInstance, folder: String, dest: String, ctx: Dictionary) -> Dictionary:
	var w := _find_world(inst, folder)
	if w.is_empty():
		return _fail("That world no longer exists.")
	if not w.generated:
		return _fail("The world has not been generated yet.")
	if dest == "":
		return _fail("No destination.")
	if dest.get_extension().to_lower() != "zip":
		dest += ".zip"
	# A running server keeps writing to its active world; flush and pause saving while zipping.
	var paused: bool = await inst.backups.pause_saving() if w.active else false
	var job := {"mutex": Mutex.new(), "progress": 0.0}
	var dir := inst.config.directory
	var thread := Thread.new()
	thread.start(func() -> String: return WorldManager.export_zip(dir, w, dest, job))
	while thread.is_alive():
		await inst.get_tree().create_timer(0.2).timeout
		(job.mutex as Mutex).lock()
		var p: float = job.progress
		(job.mutex as Mutex).unlock()
		_progress(ctx, "Zipping %s…" % w.name, p)
	var err: String = thread.wait_to_finish()
	if paused:
		inst.backups.resume_saving()
	if err != "":
		return _fail(err)
	_log(inst, ctx, "Exported world \"%s\"%s." % [w.name, "" if _is_remote(ctx) else " to " + dest])
	return _ok({"path": dest, "name": "%s.zip" % WorldImporter.unique_level_name("/nonexistent", w.name)})


static func _active_packs_dir(inst: ServerInstance) -> String:
	var w := _find_world(inst, _active_level(inst))
	if w.is_empty():
		return inst.config.directory.path_join(_active_level(inst)).path_join(WorldManager.DATAPACKS_DIR)
	return w.datapacks_dir


static func datapack_add(inst: ServerInstance, files: PackedStringArray, ctx: Dictionary) -> Dictionary:
	if files.is_empty():
		return _fail("Nothing to add.")
	var dir := _active_packs_dir(inst)
	var added := PackedStringArray()
	for source in files:
		var err := WorldManager.add_datapack(dir, source)
		if err != "":
			return _fail(err)
		added.append(source.get_file())
	_log(inst, ctx, "Added datapack %s." % ", ".join(added))
	inst.data_changed.emit(&"worlds")
	return _ok({"names": added, "online": inst.is_online()})


static func datapack_toggle(inst: ServerInstance, id: String, enable: bool, ctx: Dictionary) -> Dictionary:
	if not inst.is_online() or not inst.rcon.is_ready():
		return _fail("Start the server to enable or disable datapacks.")
	if not id.begins_with("file/") or id.contains("\n"):
		return _fail("Unknown datapack.")
	_send(inst, ctx, WorldManager.datapack_command(id, enable))
	await inst.get_tree().create_timer(1.0).timeout
	inst.data_changed.emit(&"worlds")
	return _ok()


static func datapack_remove(inst: ServerInstance, id: String, ctx: Dictionary) -> Dictionary:
	if inst.is_process_alive():
		return _fail("Stop the server before removing a pack.")
	for p in WorldManager.list_datapacks(_active_packs_dir(inst)):
		if p.id == id:
			if p.name == "bukkit" and not p.is_zip:
				return _fail("Paper manages this pack; it can't be removed.")
			var err := WorldManager.remove_datapack(p)
			if err != "":
				return _fail(err)
			_log(inst, ctx, "Removed datapack %s." % p.name)
			inst.data_changed.emit(&"worlds")
			return _ok({"name": p.name})
	return _fail("That datapack no longer exists.")


## Inspects a world (.zip or folder) for import. Returns what the import dialog shows plus
## a token for [method world_import].
static func world_import_analyze(inst: ServerInstance, files: PackedStringArray) -> Dictionary:
	_expire_imports()
	if files.is_empty():
		return _fail("Choose a .zip file or a world folder.")
	var analysis: Dictionary = await WorldImporter.analyze(inst, files[0], inst.config.mc_version)
	var token := Fmt.random_token(16)
	_imports[token] = {"server": inst.config.id, "analysis": analysis, "msec": Time.get_ticks_msec()}
	return {
		"ok": true, "token": token, "valid": analysis.ok, "error": analysis.error, "warnings": analysis.warnings,
		"display_name": WorldImporter.display_name(analysis), "version": analysis.version,
		"layout_name": WorldImporter.LAYOUT_NAMES[analysis.layout], "dimensions": analysis.dimensions,
		"game_mode": analysis.game_mode, "difficulty": analysis.difficulty, "hardcore": analysis.hardcore,
		"size_bytes": analysis.size_bytes, "found": analysis.world_dir != "",
		"single_dimension": analysis.layout == WorldImporter.Layout.DIMENSION,
		"dimension_choices": analysis.dimension_choices.map(func(c: Dictionary) -> String: return c.label),
	}


## [param dimension] is the index into the analysis' dimension_choices for mode DIMENSION.
static func world_import(inst: ServerInstance, token: String, mode: int, apply_settings: bool, ctx: Dictionary, dimension := 0) -> Dictionary:
	var pending: Dictionary = _imports.get(token, {})
	if pending.is_empty() or pending.server != inst.config.id:
		return _fail("Choose the world again; the earlier choice expired.")
	var analysis: Dictionary = pending.analysis
	if _is_remote(ctx):
		_log(inst, ctx, "Is importing the world \"%s\"." % WorldImporter.display_name(analysis))
	var import_mode: WorldImporter.Mode = mode if mode in WorldImporter.Mode.values() else WorldImporter.Mode.REPLACE
	var result: Dictionary = await WorldImporter.import_into(inst, analysis, import_mode,
			apply_settings, func(text: String) -> void: _progress(ctx, text), dimension)
	if result.ok:
		world_import_cancel(token)
		inst.data_changed.emit(&"worlds")
		return _ok({"name": WorldImporter.display_name(analysis), "level_name": result.level_name,
				"dimension": result.get("dimension", ""), "command": result.get("command", "")})
	return result


static func world_import_cancel(token: String) -> Dictionary:
	var pending: Dictionary = _imports.get(token, {})
	if not pending.is_empty():
		WorldImporter.cleanup(pending.analysis)
		_imports.erase(token)
	return _ok()


static func _expire_imports() -> void:
	var now := Time.get_ticks_msec()
	for token in _imports.keys():
		if now - int(_imports[token].msec) > IMPORT_TTL_MSEC:
			world_import_cancel(token)


# --- Resources & automation ------------------------------------------------------------------

## Facts about the computer the server runs on, for the Resources tab.
static func resources_info(inst: ServerInstance) -> Dictionary:
	var backend := PlatformBackend.get_current()
	var runtimes: Array = []
	for rt in JavaRuntimes.runtimes:
		runtimes.append({"name": rt.display_name(), "exe": rt.executable, "major": rt.major})
	var auto := JavaRuntimes.best_for(inst.config.java_min_version)
	var resolved := JavaRuntimes.resolve_for(inst.config)
	var others := 0
	var ports := {}
	for other in ServerManager.get_instances():
		if other != inst:
			others += other.config.ram_max_mb
			ports[str(other.config.port)] = other.config.display_name
	return _ok({
		"host_mb": backend.host_memory_bytes() / 1048576, "cores": OS.get_processor_count(),
		"quota": backend.supports_cpu_quota(), "memory_cap": backend.supports_memory_cap(),
		"affinity": backend.supports_affinity(), "priority": backend.supports_priority(),
		"runtimes": runtimes, "auto_java": auto.major if auto != null else 0,
		"resolved_java": {"major": resolved.major, "exe": resolved.executable} if resolved != null else {},
		"others_mb": others, "running_mb": ServerManager.allocated_ram_mb(), "ports": ports,
		"rcon_port": inst.config.rcon_port, "os": OS.get_name(),
	})


## {owner: name of the server using [param port] or "", free: nothing listens on it}
static func port_check(inst: ServerInstance, port: int) -> Dictionary:
	if port < 1 or port > 65535:
		return _fail("The port must be between 1 and 65535.")
	var owner := ServerManager.port_owner(port, inst.config.id)
	var own := port == inst.config.port and (inst.is_process_alive() or inst.wake_listener.holds_port(port))
	return _ok({"owner": owner.config.display_name if owner != null else "", "rcon": port == inst.config.rcon_port,
			"free": own or PlatformBackend.is_port_free(port), "own": own})


## The command line the server would start with under the edited [param draft] values.
static func launch_preview(inst: ServerInstance, draft: Dictionary) -> Dictionary:
	var cfg := ServerConfig.from_dict(inst.config.to_dict(), inst.config.directory)
	_apply_fields(cfg, draft)
	var rt := JavaRuntimes.resolve_for(cfg)
	var cmd := PlatformBackend.get_current().build_launch_command(cfg, rt.executable if rt != null else "java")
	var parts := PackedStringArray([Fmt.shell_quote(str(cmd.path))])
	for arg in cmd.args:
		parts.append(Fmt.shell_quote(arg))
	if cmd.has("script"):
		# Windows: the launcher file is what actually runs.
		parts = PackedStringArray([str(cmd.script).strip_edges().get_slice("\r\n", 3)])
	var warning := ""
	if rt == null:
		warning = "No suitable Java runtime found. Install Java %d+ or pick an executable in Settings." % cfg.java_min_version
	elif rt.major < cfg.java_min_version:
		warning = "Java %d is too old for this server; it needs Java %d or newer." % [rt.major, cfg.java_min_version]
	return _ok({"command": " ".join(parts), "java_warning": warning})


## Copies the known [constant CONFIG_FIELDS] from [param values] into [param cfg].
static func _apply_fields(cfg: ServerConfig, values: Dictionary) -> void:
	var d := cfg.to_dict()
	for key in values:
		if CONFIG_FIELDS.has(key) and key != "port":
			d[key] = values[key]
	var copy := ServerConfig.from_dict(d, cfg.directory)
	for key in CONFIG_FIELDS:
		if key != "port" and values.has(key):
			cfg.set(key, copy.get(key))


## Saves Resources/Automation fields. Server admins can't change the Java executable,
## JVM/server arguments or "wake the computer" on rules. {restart_needed}
static func config_save(inst: ServerInstance, changes: Dictionary, ctx: Dictionary) -> Dictionary:
	var system := _is_system(ctx)
	var values := {}
	for key in changes:
		if not CONFIG_FIELDS.has(key):
			return _fail("\"%s\" can't be changed here." % key)
		values[key] = changes[key]
	if not system:
		for key in SYSTEM_FIELDS:
			if values.has(key) and str(values[key]) != str(inst.config.get(key)):
				return _fail("Only a system admin can change the Java executable or its arguments.")
			values.erase(key)
		if values.has("events"):
			values.events = _keep_wake_flags(inst.config.events, values.events)
	if values.has("cpu_affinity") and str(values.cpu_affinity).strip_edges() != "":
		var err := affinity_error(str(values.cpu_affinity), OS.get_processor_count())
		if err != "":
			return _fail(err)
	if values.has("port"):
		var port := int(values.port)
		var owner := ServerManager.port_owner(port, inst.config.id)
		if port < 1 or port > 65535:
			return _fail("The port must be between 1 and 65535.")
		if owner != null:
			return _fail("Port %d is already used by %s." % [port, owner.config.display_name])
		if port == inst.config.rcon_port:
			return _fail("Port %d is this server's RCON port." % port)
	var before := inst.config.to_dict()
	_apply_fields(inst.config, values)
	inst.config.ram_min_mb = clampi(inst.config.ram_min_mb, 256, maxi(inst.config.ram_max_mb, 256))
	inst.save_config()
	var port_error := ""
	if values.has("port"):
		# Through set_port so server.properties and start-on-connect follow the new port.
		port_error = inst.set_port(int(values.port))
	var after := inst.config.to_dict()
	var changed := PackedStringArray()
	for key in CONFIG_FIELDS:
		if str(before.get(key)) != str(after.get(key)):
			changed.append(key)
	if _is_remote(ctx) and not changed.is_empty():
		_log(inst, ctx, "Changed %s." % ", ".join(changed))
	if port_error != "":
		return _fail(port_error)
	return _ok({"restart_needed": inst.is_process_alive() and not changed.is_empty(), "changed": changed})


## Rules from a server admin keep the saved "wake the computer" choice: an unchanged rule
## keeps it, every other rule gets it off.
static func _keep_wake_flags(saved: Array[EventRule], incoming: Variant) -> Array:
	var out: Array = []
	if not incoming is Array:
		return out
	var saved_dicts := saved.map(func(r: EventRule) -> Dictionary: return r.to_dict())
	for item in incoming:
		if not item is Dictionary:
			continue
		var rule: Dictionary = item.duplicate()
		var without := rule.duplicate()
		without.erase("wake_computer")
		var keep := false
		for s: Dictionary in saved_dicts:
			var other := s.duplicate()
			other.erase("wake_computer")
			if str(other) == str(without) and bool(s.get("wake_computer", false)):
				keep = true
				break
		rule["wake_computer"] = keep
		out.append(rule)
	return out


static func affinity_error(text: String, cores: int) -> String:
	if RegEx.create_from_string("^\\s*\\d+(\\s*-\\s*\\d+)?(\\s*,\\s*\\d+(\\s*-\\s*\\d+)?)*\\s*$").search(text) == null:
		return "Use a CPU list like \"0-3\" or \"0,2,4\"."
	for part in text.replace(" ", "").split(","):
		var bounds := part.split("-")
		for b in bounds:
			if b.to_int() >= cores:
				return "CPU %d does not exist (the computer has CPUs 0-%d)." % [b.to_int(), cores - 1]
		if bounds.size() == 2 and bounds[0].to_int() > bounds[1].to_int():
			return "Range \"%s\" is reversed." % part
	return ""


# --- Network ----------------------------------------------------------------------------------

## Everything the Network tab shows for [param inst].
static func network_info(inst: ServerInstance, ctx: Dictionary) -> Dictionary:
	var cfg := inst.config
	var route := PlatformBackend.get_current().default_route()
	var lan := ServerInstance._lan_ip()
	var fw: Dictionary = NetworkService.firewall_port_status(cfg.port)
	var props := inst.get_properties()
	var rcon_port := props.get_int("rcon.port", cfg.rcon_port)
	var stale: Array = []
	var moved_rule := {}
	if fw.active and _is_system(ctx):
		for r in NetworkService.stale_firewall_rules():
			stale.append(r)
			if r.port == inst.port_moved_from and r.origin == "app":
				moved_rule = r
	if inst.port_moved_from > 0 and (inst.port_moved_from == cfg.port or not fw.active or (moved_rule.is_empty() and fw.allowed == "yes")):
		inst.port_moved_from = 0
	var upnp_state: int = NetworkService.upnp_state
	return _ok({
		"lan_address": inst.connect_address(), "public_address": NetworkService.public_address(cfg.port),
		"looking_up": NetworkService.looking_up_public_ip, "public_ip_error": NetworkService.public_ip_error,
		"public_ip_source": NetworkService.public_ip_source, "port": cfg.port,
		"upnp_enabled": cfg.upnp_enabled, "upnp_text": _upnp_text(inst),
		"upnp_retry": cfg.upnp_enabled and (upnp_state == NetworkService.UpnpState.UNAVAILABLE or NetworkService.mapping_errors.has(cfg.id)),
		"forwarded": cfg.upnp_enabled and NetworkService.is_forwarded(cfg.id),
		"upnp_unavailable": upnp_state == NetworkService.UpnpState.UNAVAILABLE,
		"wake_ping": cfg.wake_on_connect and cfg.wake_on_ping,
		"nat": NetworkService.nat_diagnosis().text,
		"firewall": {"active": fw.active, "allowed": fw.allowed, "name": fw.name, "detail": fw.detail},
		"firewall_command": NetworkService.firewall_command(fw.name, cfg.port),
		"stale_rules": stale, "moved_from": inst.port_moved_from, "moved_rule": moved_rule,
		"gateway": str(route.get("gateway", "")), "lan_ip": lan,
		"dhcp_dynamic": bool(route.get("dynamic", false)), "reserved_lan_ip": AppSettings.reserved_lan_ip,
		"rcon_port": rcon_port, "server_ip": props.get_value("server-ip", ""),
		"rcon_forwarded": NetworkService.mappings.has(rcon_port),
	})


static func _upnp_text(inst: ServerInstance) -> String:
	var cfg := inst.config
	match NetworkService.upnp_state:
		NetworkService.UpnpState.DISCOVERING:
			return "Looking for a UPnP router…"
		NetworkService.UpnpState.UNAVAILABLE:
			return NetworkService.upnp_error + (" Forward TCP port %d to %s manually in your router's settings." % [cfg.port, ServerInstance._lan_ip()])
		NetworkService.UpnpState.UNKNOWN:
			return "The router has not been checked yet." if not cfg.upnp_enabled else "Waiting for the router check…"
	var router := "Router found (internet address %s). " % NetworkService.upnp_external_ip if NetworkService.upnp_external_ip != "" else "Router found. "
	if not cfg.upnp_enabled:
		return router + "Turn this on to forward port %d automatically." % cfg.port
	if NetworkService.mapping_errors.has(cfg.id):
		return router + NetworkService.mapping_errors[cfg.id]
	if NetworkService.is_forwarded(cfg.id):
		return router + "Port %d is forwarded to this computer." % cfg.port
	return router + "Port %d will be forwarded while the server is running or asleep." % cfg.port


## Looks up the router and public address (only when someone looks at the Network tab).
static func network_refresh() -> Dictionary:
	NetworkService.ensure_discovered()
	if not NetworkService.looking_up_public_ip:
		NetworkService.refresh_public_ip()
	return _ok()


## Asks an outside service whether the server answers from the internet.
static func network_test(inst: ServerInstance) -> Dictionary:
	var result: Dictionary = await NetworkService.test_reachability(inst)
	if not result.get("ok", false):
		return _fail("The test could not run: %s" % result.get("error", "unknown error"))
	var reasons: PackedStringArray = PackedStringArray() if result.online else NetworkService.explain_failure(inst, result)
	return _ok({"online": result.online, "version": result.get("version", ""), "cache_hit": result.get("cache_hit", false),
			"address": NetworkService.public_address(inst.config.port), "reasons": reasons})


static func port_set(inst: ServerInstance, port: int, ctx: Dictionary) -> Dictionary:
	var old := inst.config.port
	var err := inst.set_port(port)
	if err != "":
		return _fail(err)
	if _is_remote(ctx) and old != port:
		_log(inst, ctx, "Changed the port from %d to %d." % [old, port])
	return _ok({"restart_needed": inst.is_process_alive()})


static func upnp_set(inst: ServerInstance, on: bool, ctx: Dictionary) -> Dictionary:
	inst.config.upnp_enabled = on
	if on:
		NetworkService.retry(inst.config.id)
	inst.save_config()
	if _is_remote(ctx):
		_log(inst, ctx, "Turned UPnP forwarding %s." % ("on" if on else "off"))
	return _ok()


static func upnp_retry(inst: ServerInstance) -> Dictionary:
	NetworkService.retry(inst.config.id)
	return _ok()


## Opens the game port in the firewall (asks for the password on this computer's screen).
static func firewall_allow(inst: ServerInstance, ctx: Dictionary) -> Dictionary:
	if _is_remote(ctx):
		_log(inst, ctx, "Asked to allow port %d in the firewall (password prompt on this computer)." % inst.config.port)
	var result: Dictionary = await NetworkService.allow_in_firewall(inst.config.port)
	return _ok({"message": result.message}) if result.ok else _fail(result.message)
