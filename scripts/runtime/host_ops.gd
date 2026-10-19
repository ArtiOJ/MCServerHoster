class_name HostOps
extends RefCounted
## Computer-wide operations: the host's preferences, Java runtimes, firewall rules and
## router notes, importing server folders, and the access keys of remote access.
## Called through [method ServerSource.call_host_op]: directly for this computer, by a
## system admin's session for another one. Arguments and results are plain JSON values.

## Preferences a system admin may change on another computer. Interface size and console
## length are per computer that shows the interface, so they are not here.
const PREF_KEYS: PackedStringArray = [
	"servers_root", "default_ram_mb", "exit_behavior", "check_updates_on_launch", "show_unstable_versions",
	"sleep_policy", "restart_after_wake", "wake_for_events", "wake_on_connection", "start_at_login",
	"start_minimized", "desktop_notifications", "notify_when", "notify_categories",
]
const IMPORT_TTL_MSEC := 3600 * 1000

## Analysed server imports: token -> {analysis, staging, msec}.
static var _imports := {}


static func run(op: String, args: Dictionary, ctx := ServerOps.LOCAL_CONTEXT) -> Dictionary:
	match op:
		"prefs_get": return prefs_get()
		"prefs_save": return prefs_save(_dict(args.get("changes")), ctx)
		"java_rescan": return java_rescan()
		"java_add": return java_add(str(args.get("exe", "")).strip_edges())
		"firewall_remove": return await firewall_remove(_dict(args.get("rule")), ctx)
		"dhcp_reserved": return dhcp_reserved()
		"server_import_analyze": return await server_import_analyze(args, ctx)
		"server_import": return await server_import(str(args.get("token", "")), _dict(args.get("options")), ctx)
		"server_import_cancel": return server_import_cancel(str(args.get("token", "")))
		"access_get": return access_get()
		"access_rename": return access_rename(str(args.get("name", "")))
		"grant_create": return grant_create(args, ctx)
		"grant_update": return grant_update(args)
		"grant_revoke": return grant_revoke(str(args.get("id", "")), ctx)
		"grant_invite": return grant_invite(str(args.get("id", "")))
	return {"ok": false, "error": "Unknown request \"%s\"." % op}


static func _dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}


static func _actor(ctx: Dictionary) -> String:
	return str(ctx.get("actor", ""))


# --- Preferences --------------------------------------------------------------------

## The host's preferences plus what the dialog shows about power, wake and Java.
static func prefs_get() -> Dictionary:
	var values := {}
	for key in PREF_KEYS:
		values[key] = AppSettings.get(key)
	var iface := WakeHelper.wake_interface()
	return {
		"ok": true, "values": values, "runtimes": _runtimes(),
		"power_supported": PowerManager.supported, "power_status": PowerManager.status_text(),
		"limit_notice": PowerManager.supported and PowerManager.max_delay_sec < 60.0,
		"wake_installed": WakeHelper.is_installed(), "wake_wireless": bool(iface.get("wireless", false)),
		"wake_available": PowerManager.supported and OS.get_name() == "Linux",
		"wake_status": PowerManager.describe_wake(), "notify_available": Notifier.is_desktop_available(),
	}


static func prefs_save(changes: Dictionary, ctx: Dictionary) -> Dictionary:
	for key in changes:
		if not PREF_KEYS.has(key):
			return {"ok": false, "error": "\"%s\" can't be changed here." % key}
	if changes.has("servers_root"):
		var root := str(changes.servers_root).strip_edges()
		if root != "" and root != AppSettings.servers_root:
			if not root.is_absolute_path():
				return {"ok": false, "error": "The servers folder must be a full path."}
			var err := DirAccess.make_dir_recursive_absolute(root)
			if err != OK:
				return {"ok": false, "error": "Cannot use %s as servers folder: %s" % [root, error_string(err)]}
			AppSettings.servers_root = root
	if changes.has("default_ram_mb"):
		AppSettings.default_ram_mb = clampi(int(changes.default_ram_mb), 512, 1048576)
	if changes.has("exit_behavior"):
		AppSettings.exit_behavior = clampi(int(changes.exit_behavior), 0, AppSettings.ExitBehavior.size() - 1) as AppSettings.ExitBehavior
	if changes.has("sleep_policy"):
		AppSettings.sleep_policy = clampi(int(changes.sleep_policy), 0, AppSettings.SleepPolicy.size() - 1) as AppSettings.SleepPolicy
	if changes.has("notify_when"):
		AppSettings.notify_when = clampi(int(changes.notify_when), 0, AppSettings.NotifyWhen.size() - 1) as AppSettings.NotifyWhen
	for key in ["check_updates_on_launch", "show_unstable_versions", "restart_after_wake", "start_minimized", "desktop_notifications"]:
		if changes.has(key):
			AppSettings.set(key, bool(changes[key]))
	# Waking needs the helper, which only the person at that computer can install.
	for key in ["wake_for_events", "wake_on_connection"]:
		if changes.has(key):
			AppSettings.set(key, bool(changes[key]) and WakeHelper.is_installed())
	if changes.get("notify_categories") is Dictionary:
		for key in changes.notify_categories:
			if AppSettings.DEFAULT_NOTIFY_CATEGORIES.has(key):
				AppSettings.notify_categories[key] = bool(changes.notify_categories[key])
	var error := ""
	if changes.has("start_at_login") and AppSettings.start_at_login != bool(changes.start_at_login):
		AppSettings.start_at_login = bool(changes.start_at_login)
		var err := AppSettings.apply_autostart()
		if err != OK:
			error = "Could not update the login autostart entry: %s" % error_string(err)
	AppSettings.save_settings()
	if _actor(ctx) != "":
		Notifier.info("%s (remote) changed the preferences." % _actor(ctx), Notifier.Category.REMOTE)
	return {"ok": error == "", "error": error}


static func _runtimes() -> Array:
	var out: Array = []
	for rt in JavaRuntimes.runtimes:
		out.append({"name": rt.display_name(), "exe": rt.executable, "home": rt.home, "major": rt.major})
	return out


static func java_rescan() -> Dictionary:
	JavaRuntimes.rescan()
	return {"ok": true, "runtimes": _runtimes()}


## Adds a Java executable that the scan doesn't find by itself.
static func java_add(exe: String) -> Dictionary:
	if exe == "" or not exe.is_absolute_path():
		return {"ok": false, "error": "Enter the full path of the java executable."}
	if not AppSettings.extra_java_paths.has(exe):
		AppSettings.extra_java_paths.append(exe)
		AppSettings.save_settings()
	JavaRuntimes.rescan()
	if JavaRuntimes.find_by_executable(exe) == null:
		return {"ok": false, "error": "No usable Java runtime was found at %s." % exe, "runtimes": _runtimes()}
	return {"ok": true, "runtimes": _runtimes()}


# --- Network (computer-wide) -----------------------------------------------------------

## Removes a firewall rule no server uses any more. Only rules this computer lists as
## stale can be removed, whatever the request says.
static func firewall_remove(rule: Dictionary, ctx: Dictionary) -> Dictionary:
	for r in NetworkService.stale_firewall_rules():
		if int(r.port) == int(rule.get("port", -1)) and str(r.origin) == str(rule.get("origin", "")) and str(r.source) == str(rule.get("source", "")):
			if _actor(ctx) != "":
				Notifier.info("%s (remote) is removing the firewall rule for port %d (password prompt here)." % [_actor(ctx), r.port], Notifier.Category.REMOTE)
			var result: Dictionary = await NetworkService.remove_firewall_rule(r)
			return {"ok": result.ok, "message": result.message, "error": "" if result.ok else result.message}
	return {"ok": false, "error": "That firewall rule is no longer listed."}


## The user confirmed that the router reserves this computer's address.
static func dhcp_reserved() -> Dictionary:
	AppSettings.reserved_lan_ip = ServerInstance._lan_ip()
	AppSettings.save_settings()
	NetworkService.status_changed.emit()
	return {"ok": true}


# --- Importing servers ----------------------------------------------------------------

## Inspects a server folder on this computer (args.path_on_host) or an uploaded one
## (args.files: a zip of it). Returns the analysis plus a token for [method server_import].
static func server_import_analyze(args: Dictionary, ctx: Dictionary) -> Dictionary:
	_expire_imports()
	var files: Array = args.get("files", []) if args.get("files") is Array or args.get("files") is PackedStringArray else []
	var dir := str(args.get("path_on_host", "")).strip_edges()
	var staging := ""
	if not files.is_empty():
		staging = AppSettings.servers_root.path_join("_temp").path_join("import-server-%s" % Fmt.random_token(8).to_lower())
		var zip := str(files[0])
		var cb: Callable = ctx.get("progress", Callable())
		if cb.is_valid():
			cb.call("Unpacking %s…" % zip.get_file(), -1.0)
		var err: String = await FileOps.run_async(ServerManager, func() -> String: return WorldImporter.extract_zip(zip, staging))
		if err != "":
			FileOps.remove_path(staging)
			return {"ok": false, "error": err}
		dir = _server_root(staging)
	elif dir == "" or not dir.is_absolute_path():
		return {"ok": false, "error": "Enter the full path of the server folder."}
	var a: Dictionary = await FileOps.run_async(ServerManager, func() -> Dictionary: return ServerImporter.analyze(dir))
	var token := Fmt.random_token(16)
	_imports[token] = {"analysis": a, "staging": staging, "msec": Time.get_ticks_msec()}
	var view := a.duplicate()
	view.erase("dir")
	var ports := {}
	for inst in ServerManager.get_instances():
		ports[str(inst.config.port)] = inst.config.display_name
	view.merge({
		"ok": true, "token": token, "uploaded": staging != "", "suggested_name": dir.get_file() if staging == "" else _upload_name(files[0]),
		"ports": ports, "free_port": ServerManager.allocate_game_port(), "port_free": PlatformBackend.is_port_free(int(a.port)),
		"servers_root": AppSettings.servers_root, "default_ram_mb": AppSettings.default_ram_mb, "folder": dir if staging == "" else "",
	}, true)
	return view


## The folder in an unpacked upload that holds the server (the top one, or the single
## folder inside it).
static func _server_root(staging: String) -> String:
	var dirs := DirAccess.get_directories_at(staging)
	if DirAccess.get_files_at(staging).is_empty() and dirs.size() == 1:
		return staging.path_join(dirs[0])
	return staging


static func _upload_name(path: String) -> String:
	return str(path).get_file().get_basename()


static func server_import(token: String, options: Dictionary, ctx: Dictionary) -> Dictionary:
	var pending: Dictionary = _imports.get(token, {})
	if pending.is_empty():
		return {"ok": false, "error": "Choose the server folder again; the earlier choice expired."}
	var a: Dictionary = pending.analysis
	var dir := str(a.dir)
	var opts := {
		"analysis": a, "display_name": str(options.get("display_name", "")).strip_edges().left(64),
		"mode": "copy" if str(options.get("mode", "")) == "copy" else "in_place",
		"port": clampi(int(options.get("port", a.port)), 1, 65535),
		"ram_max_mb": clampi(int(options.get("ram_max_mb", AppSettings.default_ram_mb)), 512, 1048576),
		"switch_to_paper": bool(options.get("switch_to_paper", false)), "accept_eula": bool(options.get("accept_eula", false)),
	}
	if ServerManager.port_owner(opts.port) != null and not a.managed:
		return {"ok": false, "error": "Port %d is used by %s." % [opts.port, ServerManager.port_owner(opts.port).config.display_name]}
	if pending.staging != "":
		# An uploaded server moves into the servers folder and is imported there.
		var name: String = opts.display_name if opts.display_name != "" else dir.get_file()
		var target := AppSettings.servers_root.path_join(ServerManager.unique_id(name))
		if DirAccess.rename_absolute(dir, target) != OK:
			return {"ok": false, "error": "Could not move the uploaded server into %s." % AppSettings.servers_root}
		dir = target
		a = await FileOps.run_async(ServerManager, func() -> Dictionary: return ServerImporter.analyze(target))
		opts.analysis = a
		opts.mode = "in_place"
	var res: Dictionary = await ServerManager.import_existing_server(dir, opts, ctx.get("progress", Callable()))
	if not res.ok:
		if pending.staging != "":
			FileOps.remove_path(dir)
		server_import_cancel(token)
		return {"ok": false, "error": res.error}
	server_import_cancel(token)
	var inst: ServerInstance = res.instance
	if _actor(ctx) != "":
		inst.log_system("Imported remotely by %s." % _actor(ctx))
		Notifier.info("%s (remote) imported %s." % [_actor(ctx), inst.config.display_name], Notifier.Category.REMOTE)
	return {"ok": true, "server": inst.config.id}


static func server_import_cancel(token: String) -> Dictionary:
	var pending: Dictionary = _imports.get(token, {})
	if not pending.is_empty():
		if pending.staging != "":
			FileOps.remove_path(pending.staging)
		_imports.erase(token)
	return {"ok": true}


static func _expire_imports() -> void:
	var now := Time.get_ticks_msec()
	for token in _imports.keys():
		if now - int(_imports[token].msec) > IMPORT_TTL_MSEC:
			server_import_cancel(token)


# --- Access keys ------------------------------------------------------------------------

## The remote-access settings and keys of this computer.
static func access_get() -> Dictionary:
	var grants: Array = []
	for g in RemoteAccess.grants:
		grants.append({
			"id": g.id, "name": g.name, "role": g.role, "servers": Array(g.server_ids),
			"created": g.created_unix, "last_used": g.last_used_unix,
			"connected_from": RemoteAccess.sessions_for(g).map(func(session: RemoteSession) -> String: return session.address),
		})
	var servers: Array = []
	for inst in ServerManager.get_instances():
		servers.append({"id": inst.config.id, "name": inst.config.display_name})
	return {
		"ok": true, "enabled": RemoteAccess.enabled, "port": RemoteAccess.port, "computer_name": RemoteAccess.computer_name,
		"listening": RemoteAccess.is_listening(), "listen_error": RemoteAccess.listen_error, "grants": grants, "servers": servers,
		"addresses": RemoteAccess.invite_addresses(),
	}


static func access_rename(name: String) -> Dictionary:
	name = name.strip_edges().left(64)
	if name == "":
		return {"ok": false, "error": "Enter a name for this computer."}
	RemoteAccess.set_computer_name(name)
	return {"ok": true}


static func _server_ids(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is Array:
		for v in value:
			if ServerManager.get_instance(str(v)) != null:
				out.append(str(v))
	return out


## Creates an access key. {grant id, invite}
static func grant_create(args: Dictionary, ctx: Dictionary) -> Dictionary:
	var person := str(args.get("name", "")).strip_edges().left(64)
	if person == "":
		return {"ok": false, "error": "Enter who the key is for."}
	var role := clampi(int(args.get("role", RemoteProtocol.Role.SERVER_ADMIN)), 0, RemoteProtocol.Role.size() - 1) as RemoteProtocol.Role
	var g: RemoteGrant = RemoteAccess.create_grant(person, role, _server_ids(args.get("servers", [])))
	if _actor(ctx) != "":
		Notifier.info("%s (remote) created an access key for %s." % [_actor(ctx), person], Notifier.Category.REMOTE)
	return {"ok": true, "id": g.id, "invite": RemoteAccess.invite_for(g)}


static func grant_update(args: Dictionary) -> Dictionary:
	var g: RemoteGrant = RemoteAccess.find_grant(str(args.get("id", "")))
	if g == null:
		return {"ok": false, "error": "That key no longer exists."}
	if args.has("role"):
		g.role = clampi(int(args.role), 0, RemoteProtocol.Role.size() - 1) as RemoteProtocol.Role
	if args.has("servers"):
		g.server_ids = _server_ids(args.servers)
	if args.has("name") and str(args.name).strip_edges() != "":
		g.name = str(args.name).strip_edges().left(64)
	RemoteAccess.update_grant(g)
	return {"ok": true}


static func grant_revoke(id: String, ctx: Dictionary) -> Dictionary:
	var g: RemoteGrant = RemoteAccess.find_grant(id)
	if g == null:
		return {"ok": false, "error": "That key no longer exists."}
	if _actor(ctx) != "":
		Notifier.info("%s (remote) revoked the access key of %s." % [_actor(ctx), g.name], Notifier.Category.REMOTE)
	RemoteAccess.revoke_grant(g)
	return {"ok": true}


static func grant_invite(id: String) -> Dictionary:
	var g: RemoteGrant = RemoteAccess.find_grant(id)
	if g == null:
		return {"ok": false, "error": "That key no longer exists."}
	return {"ok": true, "invite": RemoteAccess.invite_for(g)}
