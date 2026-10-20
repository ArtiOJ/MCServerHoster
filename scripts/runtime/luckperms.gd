class_name LuckPerms
extends RefCounted
## LuckPerms (the permissions plugin) for the Permissions menu (Plugins tab): reads its data with
## `/lp export` and changes it with `/lp` commands, both over RCON while the server runs.
## Verified with LuckPerms 5.5 on Paper 26.3:
## - RCON gets no replies from LuckPerms (they arrive after the response), so every batch
##   of changes is followed by an export, which shows what actually took effect.
## - An export reusing an existing file name silently does nothing: each one is unique.
## - Arguments are split on spaces, so names, permissions and contexts are validated here
##   (a permission with a space would turn into a different one with contexts).
## A stopped server keeps its data in LuckPerms' H2 database, which only LuckPerms reads;
## the last export is kept in the server's .manager folder and shown read-only.

const METADATA_URL := "https://metadata.luckperms.net/data/all"
const PLUGIN_NAME := "LuckPerms"
const DATA_DIR := "plugins/LuckPerms"
const CACHE_FILE := ".manager/luckperms.json"
const EXPORT_PREFIX := "server-manager-"
const EXPORT_TIMEOUT_MSEC := 20000
## How long a server that just came up gets to open RCON.
const RCON_WAIT_MSEC := 20000
const DOWNLOAD_TIMEOUT_SEC := 120
## Group and track names (LuckPerms stores them in lower case).
const NAME_RE := "^[a-z0-9_\\-]{1,36}$"
const NODE_RE := "^[^\\s\"]{1,256}$"
## One context, e.g. world=world_nether.
const CONTEXT_RE := "^[A-Za-z0-9_.:\\-]+=[A-Za-z0-9_.:\\-]+$"
## LuckPerms durations, e.g. 30m, 1d12h, 2mo.
const DURATION_RE := "^(\\d+(mo|[smhdwy]))+$"
const UUID_RE := "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
const MAX_PREFIX_LENGTH := 64
const HOLDERS: PackedStringArray = ["group", "user"]

static var _regexes := {}


# --- Installation -----------------------------------------------------------------

## {installed, enabled, file, version} for the LuckPerms jar in [param server_dir]'s plugins.
static func installed_info(server_dir: String) -> Dictionary:
	return ServerOps.installed_plugin(server_dir, PLUGIN_NAME)


## Downloads the latest LuckPerms for Paper/Bukkit into the server's plugins folder.
## Returns {ok, version} or {ok: false, error}.
static func install(inst: ServerInstance) -> Dictionary:
	var meta := await _http_get(inst, METADATA_URL)
	if not meta.ok:
		return {"ok": false, "error": "Could not reach luckperms.net (%s)." % meta.error}
	var data: Variant = JSON.parse_string(meta.body.get_string_from_utf8())
	var url := str(Nbt.dig(data, ["downloads", "bukkit"], "")) if data is Dictionary else ""
	if not url.begins_with("https://download.luckperms.net/"):
		return {"ok": false, "error": "luckperms.net didn't list a Paper download."}
	var dir := inst.config.directory.path_join("plugins")
	DirAccess.make_dir_recursive_absolute(dir)
	var dest := dir.path_join(url.get_file())
	var part := dest + ".part"
	var got := await _http_get(inst, url, part)
	if not got.ok:
		DirAccess.remove_absolute(part)
		return {"ok": false, "error": "Downloading LuckPerms failed (%s)." % got.error}
	# Only keep it if it really is the plugin.
	var plugin := ServerOps.read_plugin_meta(part)
	if str(plugin.get("name", "")) != PLUGIN_NAME:
		DirAccess.remove_absolute(part)
		return {"ok": false, "error": "The download from luckperms.net wasn't a LuckPerms plugin."}
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	var err := DirAccess.rename_absolute(part, dest)
	if err != OK:
		return {"ok": false, "error": "Could not save %s (%s)." % [dest.get_file(), error_string(err)]}
	return {"ok": true, "version": str(plugin.get("version", data.get("version", ""))), "file": dest.get_file()}


## GET [param url] with [param owner] hosting the request; into [param file] when given.
## Returns {ok, body} or {ok: false, error}.
static func _http_get(owner: Node, url: String, file := "") -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = DOWNLOAD_TIMEOUT_SEC
	if file != "":
		http.download_file = file
	owner.add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: " + PaperApi.USER_AGENT]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "are you online?"}
	if response[1] != 200:
		return {"ok": false, "error": "HTTP %d" % response[1]}
	return {"ok": true, "body": response[3]}


# --- Reading ------------------------------------------------------------------------

## Exports LuckPerms' data from the running server. Returns {ok, data} (the export's JSON)
## or {ok: false, error}.
static func export(inst: ServerInstance) -> Dictionary:
	# Right after startup the server is online a moment before RCON accepts commands.
	var rcon_deadline := Time.get_ticks_msec() + RCON_WAIT_MSEC
	while inst.is_online() and not inst.rcon.is_ready() and Time.get_ticks_msec() < rcon_deadline:
		await inst.get_tree().create_timer(0.25).timeout
	if not inst.is_online() or not inst.rcon.is_ready():
		return {"ok": false, "error": "Start the server to read its permissions."}
	var name := EXPORT_PREFIX + Fmt.random_token(10).to_lower()
	var path := inst.config.directory.path_join(DATA_DIR).path_join(name + ".json.gz")
	var reply := await inst.rcon.execute("lp export " + name)
	if reply.contains("Unknown or incomplete command"):
		return {"ok": false, "error": "LuckPerms isn't loaded on the running server. Restart the server to load it."}
	var deadline := Time.get_ticks_msec() + EXPORT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		await inst.get_tree().create_timer(0.1).timeout
		var data := read_export_file(path)
		if not data.is_empty():
			DirAccess.remove_absolute(path)
			return {"ok": true, "data": data}
	DirAccess.remove_absolute(path)
	return {"ok": false, "error": "LuckPerms didn't answer. Check the console for errors."}


## The export at [param path] once it is completely written, else {}.
static func read_export_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.size() < 20:
		return {}
	var text := raw.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var data: Variant = JSON.parse_string(text) if text != "" else null
	return data if data is Dictionary and (data as Dictionary).has("groups") else {}


## Turns an export into the tab's model: {groups, tracks, users}, where
## groups: [{name, weight, prefixes, suffixes, parents, permissions, other}],
## users: [{uuid, name, primary, prefixes, suffixes, parents, permissions, other}],
## tracks: [{name, groups}]. Nodes are {node, value, context (text), expiry (0 = never)};
## prefixes/suffixes {priority, text, context, expiry}; parents {group, context, expiry};
## other holds the remaining node types ({type, node, value, context, expiry}).
## [param names] maps UUIDs to player names (usercache.json).
static func parse_export(data: Dictionary, names := {}) -> Dictionary:
	var groups := []
	var raw_groups: Variant = data.get("groups", {})
	if raw_groups is Dictionary:
		for name in raw_groups:
			var holder := _holder(raw_groups[name])
			holder.name = str(name)
			groups.append(holder)
	groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.weight > b.weight if a.weight != b.weight else str(a.name) < str(b.name))
	var users := []
	var raw_users: Variant = data.get("users", {})
	if raw_users is Dictionary:
		for uuid in raw_users:
			var entry: Variant = raw_users[uuid]
			var holder := _holder(entry)
			holder.uuid = str(uuid)
			var known := str(entry.get("username", "")) if entry is Dictionary else ""
			holder.name = known if known != "" and known != "null" else str(names.get(str(uuid), ""))
			holder.primary = str(entry.get("primaryGroup", "default")) if entry is Dictionary else "default"
			holder.erase("weight")
			users.append(holder)
	users.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _player_key(a) < _player_key(b))
	var tracks := []
	var raw_tracks: Variant = data.get("tracks", {})
	if raw_tracks is Dictionary:
		for name in raw_tracks:
			var entry: Variant = raw_tracks[name]
			var members: Array = entry.get("groups", []) if entry is Dictionary else []
			tracks.append({"name": str(name), "groups": members.map(func(g: Variant) -> String: return str(g))})
	tracks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))
	return {"groups": groups, "users": users, "tracks": tracks}


static func _player_key(user: Dictionary) -> String:
	return (str(user.name) if str(user.name) != "" else "~" + str(user.uuid)).to_lower()


static func _holder(entry: Variant) -> Dictionary:
	var holder := {"weight": 0, "prefixes": [], "suffixes": [], "parents": [], "permissions": [], "other": []}
	var nodes: Variant = entry.get("nodes", []) if entry is Dictionary else []
	if not nodes is Array:
		return holder
	for raw in nodes:
		if not raw is Dictionary:
			continue
		var key := str(raw.get("key", ""))
		var value := bool(raw.get("value", true))
		var context := context_text(raw.get("context", {}))
		var expiry := int(raw.get("expiry", 0))
		match str(raw.get("type", "")):
			"permission":
				holder.permissions.append({"node": key, "value": value, "context": context, "expiry": expiry})
			"inheritance":
				holder.parents.append({"group": key.trim_prefix("group."), "context": context, "expiry": expiry})
			"weight":
				holder.weight = key.trim_prefix("weight.").to_int()
			"prefix", "suffix":
				# prefix.<priority>.<text>; the text may contain dots.
				var parts := key.split(".", true, 2)
				if parts.size() == 3:
					holder[parts[0] + "es"].append({"priority": parts[1].to_int(), "text": parts[2], "context": context, "expiry": expiry})
			var other:
				holder.other.append({"type": str(other), "node": key, "value": value, "context": context, "expiry": expiry})
	holder.permissions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.node) < str(b.node))
	return holder


## "world=world_nether server=lobby" from an export's context object ("" = everywhere).
## A key may hold several values (a list).
static func context_text(context: Variant) -> String:
	if not context is Dictionary:
		return ""
	var parts := PackedStringArray()
	var keys: Array = (context as Dictionary).keys()
	keys.sort()
	for key in keys:
		var values: Variant = context[key]
		for v in (values if values is Array else [values]):
			parts.append("%s=%s" % [key, v])
	return " ".join(parts)


## UUID -> name from the server's usercache.json.
static func usercache_names(server_dir: String) -> Dictionary:
	var names := {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(server_dir.path_join("usercache.json")))
	if data is Array:
		for entry in data:
			if entry is Dictionary and str(entry.get("uuid", "")) != "":
				names[str(entry.uuid)] = str(entry.get("name", ""))
	return names


# --- Known permissions ----------------------------------------------------------------

## Where the vanilla command list is remembered (per server, with its Minecraft version).
const VANILLA_CACHE := ".manager/vanilla-commands.json"
## Permissions no plugin.yml declares: Paper/Bukkit's own, and LuckPerms' main ones (it
## registers its permissions at runtime). [node, from, description].
const BUILT_IN_PERMISSIONS := [
	["bukkit.command.plugins", "Paper", "Use /plugins"], ["bukkit.command.version", "Paper", "Use /version"],
	["bukkit.command.help", "Paper", "Use /help"], ["bukkit.command.reload", "Paper", "Use /reload"],
	["bukkit.command.timings", "Paper", "Use /timings"], ["bukkit.broadcast.user", "Paper", "Receive user broadcasts"],
	["bukkit.broadcast.admin", "Paper", "Receive admin broadcasts"],
	["luckperms.*", "LuckPerms", "Every LuckPerms command"], ["luckperms.user.*", "LuckPerms", "Manage players' permissions"],
	["luckperms.group.*", "LuckPerms", "Manage groups"], ["luckperms.track.*", "LuckPerms", "Manage tracks"],
	["luckperms.editor", "LuckPerms", "Open the web editor"], ["luckperms.info", "LuckPerms", "Show LuckPerms information"],
]

static var _jar_cache := {}


## Permissions the server's enabled plugins declare: [{node, plugin, description, default}].
## Read from each jar's plugin.yml / paper-plugin.yml ("permissions", their "children", and the
## permission of each command); cached per jar until it changes. Plugins can also check
## permissions they never declare; those can't be listed.
static func plugin_permissions(server_dir: String) -> Array:
	var out := []
	var dir := server_dir.path_join("plugins")
	for file in DirAccess.get_files_at(dir):
		if not file.ends_with(".jar"):
			continue
		var path := dir.path_join(file)
		var stamp := "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_size(path) if FileAccess.file_exists(path) else 0]
		var cached: Dictionary = _jar_cache.get(path, {})
		if cached.get("stamp", "") != stamp:
			cached = {"stamp": stamp, "permissions": _jar_permissions(path)}
			_jar_cache[path] = cached
		out.append_array(cached.permissions)
	return out


static func _jar_permissions(jar: String) -> Array:
	var reader := ZIPReader.new()
	if reader.open(jar) != OK:
		return []
	var text := ""
	for descriptor in ["paper-plugin.yml", "plugin.yml"]:
		if reader.file_exists(descriptor):
			text = reader.read_file(descriptor).get_string_from_utf8()
			break
	reader.close()
	return parse_plugin_permissions(text) if text != "" else []


## The permissions declared in a plugin.yml's text (see [method plugin_permissions]).
static func parse_plugin_permissions(text: String) -> Array:
	var lines := text.replace("\r\n", "\n").replace("\t", "  ").split("\n")
	var plugin := ""
	var found := {}  # node -> {description, default, guessed}
	var order := []
	# [param guessed] descriptions ("Use /fly", from a command) give way to declared ones.
	var add := func(node: String, description := "", default := "", guessed := false) -> void:
		if node == "" or not is_valid_node(node):
			return
		if not found.has(node):
			found[node] = {"description": "", "default": "", "guessed": true}
			order.append(node)
		if description != "" and (found[node].description == "" or (found[node].guessed and not guessed)):
			found[node].description = description
			found[node].guessed = guessed
		if default != "":
			found[node].default = default
	# Stack of open keys: [indent, key]; the path tells which section a line belongs to.
	var stack := []
	var current := {}  # The open permission or command: {kind, name, indent}
	for raw in lines:
		var line := raw.split(" #")[0].rstrip(" ") if not raw.strip_edges().begins_with("#") else ""
		if line.strip_edges() == "" or line.strip_edges().begins_with("- "):
			continue
		var indent := line.length() - line.lstrip(" ").length()
		var colon := _key_colon(line)
		if colon < 0:
			continue
		var key := YamlDoc.unquote(line.substr(indent, colon - indent).strip_edges())
		var value := YamlDoc.unquote(line.substr(colon + 1).strip_edges())
		while not stack.is_empty() and stack[-1][0] >= indent:
			stack.pop_back()
		var path := stack.map(func(e: Array) -> String: return e[1])
		if path.is_empty() and key == "name":
			plugin = value
		elif path == ["permissions"]:
			add.call(key)
			current = {"kind": "permission", "name": key}
		elif path.size() == 2 and path[0] == "permissions":
			if key == "description":
				add.call(path[1], value)
			elif key == "default":
				add.call(path[1], "", value)
		elif path.size() == 3 and path[0] == "permissions" and path[2] == "children":
			add.call(key)
		elif path.size() == 2 and path[0] == "commands":
			if key == "permission":
				add.call(value, "Use /%s" % path[1], "", true)
		stack.append([indent, key])
	var out := []
	for node in order:
		out.append({"node": node, "plugin": plugin, "description": found[node].description, "default": found[node].default})
	return out


## Index of the colon ending a mapping key on [param line], or -1 (quotes respected).
static func _key_colon(line: String) -> int:
	var quote := ""
	for i in line.length():
		var c := line[i]
		if quote != "":
			if c == quote:
				quote = ""
		elif c == "'" or c == "\"":
			quote = c
		elif c == ":" and (i == line.length() - 1 or line[i + 1] == " "):
			return i
	return -1


## Vanilla command permissions (minecraft.command.<name>) from the running server's
## `minecraft:help`, remembered per Minecraft version for when it's stopped.
static func vanilla_permissions(inst: ServerInstance) -> Array:
	var path := inst.config.directory.path_join(VANILLA_CACHE)
	var cached: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	var names: Array = []
	if cached is Dictionary and str(cached.get("version", "")) == inst.config.mc_version:
		names = cached.get("commands", [])
	elif inst.is_online() and inst.rcon.is_ready():
		names = parse_help_commands(await inst.rcon.execute("minecraft:help"))
		if not names.is_empty():
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify({"version": inst.config.mc_version, "commands": names}))
	return names.map(func(n: String) -> Dictionary:
		return {"node": "minecraft.command." + n, "plugin": "Minecraft", "description": "Use /%s" % n, "default": "op"})


## Command names from `minecraft:help` output: "/name …" usages, one per line in the console
## but run together without line breaks over RCON, so every "/" starts one.
static func parse_help_commands(text: String) -> Array:
	var names := {}
	var head := RegEx.create_from_string("^([a-z0-9_\\-]+)")
	var pieces := text.split("/")
	for i in range(1, pieces.size()):
		var m := head.search(pieces[i])
		if m != null:
			names[m.get_string(1)] = true
	var out := names.keys()
	out.sort()
	return out


# --- Changing -----------------------------------------------------------------------

## The /lp commands for one change. Returns {ok, commands, text (what it does)} or
## {ok: false, error}. Changes (all names validated):
## group_create/group_delete {group}; weight_set {group, weight};
## permission_set {holder, name, node, value, context, duration}; permission_unset {holder,
## name, node, context, temporary}; parent_add/parent_remove {holder, name, group, context,
## temporary}; prefix_set/prefix_remove (and suffix_*) {holder, name, priority, text, context};
## track_create/track_delete {track}; track_append/track_remove {track, group};
## track_insert/track_move {track, group, position (1 = first)}; promote/demote {name (UUID), track}.
## holder is "group" or "user"; name is a group name or a player's UUID.
static func commands_for(change: Dictionary) -> Dictionary:
	var action := str(change.get("action", ""))
	match action:
		"group_create", "group_delete":
			var group := str(change.get("group", ""))
			if not is_valid_name(group):
				return _bad("Group names are 1–36 lower-case letters, digits, _ or -.")
			if action == "group_delete" and group == "default":
				return _bad("The default group can't be deleted.")
			var verb := "creategroup" if action == "group_create" else "deletegroup"
			return _good(["lp %s %s" % [verb, group]], "%s group %s" % ["create" if action == "group_create" else "delete", group])
		"weight_set":
			var group := str(change.get("group", ""))
			if not is_valid_name(group):
				return _bad("Unknown group.")
			var weight := int(change.get("weight", 0))
			return _good(["lp group %s setweight %d" % [group, weight]], "set %s's weight to %d" % [group, weight])
		"track_create", "track_delete":
			var track := str(change.get("track", ""))
			if not is_valid_name(track):
				return _bad("Track names are 1–36 lower-case letters, digits, _ or -.")
			var verb := "createtrack" if action == "track_create" else "deletetrack"
			return _good(["lp %s %s" % [verb, track]], "%s track %s" % ["create" if action == "track_create" else "delete", track])
		"track_append", "track_remove", "track_insert", "track_move":
			var track := str(change.get("track", ""))
			var group := str(change.get("group", ""))
			if not is_valid_name(track) or not is_valid_name(group):
				return _bad("Unknown track or group.")
			var position := maxi(int(change.get("position", 1)), 1)
			if action == "track_insert":
				return _good(["lp track %s insert %s %d" % [track, group, position]], "put %s at position %d of track %s" % [group, position, track])
			if action == "track_move":
				return _good(["lp track %s remove %s" % [track, group], "lp track %s insert %s %d" % [track, group, position]],
						"move %s to position %d of track %s" % [group, position, track])
			var verb := "append" if action == "track_append" else "remove"
			return _good(["lp track %s %s %s" % [track, verb, group]], "%s %s %s track %s" % [verb, group, "to" if verb == "append" else "from", track])
		"promote", "demote":
			var user := str(change.get("name", ""))
			var track := str(change.get("track", ""))
			if not is_uuid(user) or not is_valid_name(track):
				return _bad("Unknown player or track.")
			return _good(["lp user %s %s %s" % [user, action, track]], "%s the player on track %s" % [action, track])
	var target := _target(change)
	if target.has("error"):
		return _bad(target.error)
	var context := str(change.get("context", "")).strip_edges()
	if not is_valid_context(context):
		return _bad("\"Where\" takes key=value pairs separated by spaces, e.g. world=world_nether.")
	var where := (" " + context) if context != "" else ""
	var on := " in %s" % context if context != "" else ""
	match action:
		"permission_set":
			var node := str(change.get("node", "")).strip_edges()
			if not is_valid_node(node):
				return _bad("Permissions can't contain spaces or quotes.")
			var value := "true" if bool(change.get("value", true)) else "false"
			var duration := str(change.get("duration", "")).strip_edges().to_lower()
			if duration != "" and not is_valid_duration(duration):
				return _bad("Durations look like 30m, 12h, 7d or 1mo.")
			var verb := "%s %s %s" % [node, value, (duration + " replace") if duration != "" else ""]
			var command := "%s permission %s %s%s" % [target.prefix, "settemp" if duration != "" else "set", verb.strip_edges(), where]
			return _good([command], "%s %s for %s%s" % ["allow" if value == "true" else "deny", node, target.label, on])
		"permission_unset":
			var node := str(change.get("node", "")).strip_edges()
			if not is_valid_node(node):
				return _bad("Permissions can't contain spaces or quotes.")
			var verb := "unsettemp" if bool(change.get("temporary", false)) else "unset"
			return _good(["%s permission %s %s%s" % [target.prefix, verb, node, where]], "remove %s from %s%s" % [node, target.label, on])
		"parent_add", "parent_remove":
			var group := str(change.get("group", ""))
			if not is_valid_name(group):
				return _bad("Unknown group.")
			if target.holder == "group" and group == str(change.get("name", "")):
				return _bad("A group can't inherit from itself.")
			var verb := "add" if action == "parent_add" else ("removetemp" if bool(change.get("temporary", false)) else "remove")
			return _good(["%s parent %s %s%s" % [target.prefix, verb, group, where]], "%s %s %s %s%s" % ["add" if action == "parent_add" else "remove", target.label, "to" if action == "parent_add" else "from", group, on])
		"prefix_set", "prefix_remove", "suffix_set", "suffix_remove":
			var kind := action.get_slice("_", 0)
			var text := str(change.get("text", ""))
			if text.contains("\"") or text.contains("\n") or text.length() > MAX_PREFIX_LENGTH or (action.ends_with("_set") and text == ""):
				return _bad("A %s is up to %d characters, without quotes." % [kind, MAX_PREFIX_LENGTH])
			var priority := int(change.get("priority", 0))
			var verb := ("set" if action.ends_with("_set") else "remove") + kind
			return _good(["%s meta %s %d \"%s\"%s" % [target.prefix, verb, priority, text, where]], "%s %s's %s%s" % ["set" if action.ends_with("_set") else "remove", target.label, kind, on])
	return _bad("Unknown change \"%s\"." % action)


## {holder, prefix ("lp group <name>" / "lp user <uuid>"), label} or {error}.
static func _target(change: Dictionary) -> Dictionary:
	var holder := str(change.get("holder", ""))
	var name := str(change.get("name", ""))
	if holder == "group" and is_valid_name(name):
		return {"holder": holder, "prefix": "lp group " + name, "label": "group " + name}
	if holder == "user" and is_uuid(name):
		return {"holder": holder, "prefix": "lp user " + name, "label": str(change.get("label", "the player"))}
	return {"error": "Unknown group or player."}


static func _good(commands: Array, text: String) -> Dictionary:
	return {"ok": true, "commands": commands, "text": text}


static func _bad(message: String) -> Dictionary:
	return {"ok": false, "error": message}


## Whether [param model] (from [method parse_export]) shows [param change] took effect.
## Promotions and demotions depend on the track, so they always count as applied.
static func applied(change: Dictionary, model: Dictionary) -> bool:
	var action := str(change.get("action", ""))
	match action:
		"group_create", "group_delete":
			return (find(model, "group", str(change.group)) != null) == (action == "group_create")
		"weight_set":
			var g: Variant = find(model, "group", str(change.group))
			return g != null and int(g.weight) == int(change.weight)
		"track_create", "track_delete":
			return (_track(model, str(change.track)) != null) == (action == "track_create")
		"track_append", "track_insert", "track_move", "track_remove":
			var t: Variant = _track(model, str(change.track))
			var present: bool = t != null and (t.groups as Array).has(str(change.group))
			if action in ["track_insert", "track_move"] and present:
				return (t.groups as Array).find(str(change.group)) == maxi(int(change.get("position", 1)), 1) - 1
			return present == (action != "track_remove")
		"promote", "demote":
			return true
	var holder: Variant = find(model, str(change.get("holder", "")), str(change.get("name", "")))
	var context := str(change.get("context", "")).strip_edges()
	match action:
		"permission_set", "permission_unset":
			var node := str(change.get("node", "")).strip_edges()
			var match_value := bool(change.get("value", true))
			for p in (holder.permissions if holder != null else []):
				if str(p.node) == node and _same_context(str(p.context), context):
					return action == "permission_set" and bool(p.value) == match_value
			return action == "permission_unset"
		"parent_add", "parent_remove":
			for p in (holder.parents if holder != null else []):
				if str(p.group) == str(change.group) and _same_context(str(p.context), context):
					return action == "parent_add"
			return action == "parent_remove"
		"prefix_set", "prefix_remove", "suffix_set", "suffix_remove":
			var list: String = action.get_slice("_", 0) + "es"
			for p in (holder[list] if holder != null else []):
				if int(p.priority) == int(change.get("priority", 0)) and str(p.text) == str(change.get("text", "")) and _same_context(str(p.context), context):
					return action.ends_with("_set")
			return action.ends_with("_remove")
	return false


static func _same_context(a: String, b: String) -> bool:
	var pa := Array(a.split(" ", false))
	var pb := Array(b.split(" ", false))
	pa.sort()
	pb.sort()
	return pa == pb


## The group (by name) or user (by UUID) in [param model], or null.
static func find(model: Dictionary, holder: String, name: String) -> Variant:
	for h in model.get("groups" if holder == "group" else "users", []):
		if str(h.get("name" if holder == "group" else "uuid", "")) == name:
			return h
	return null


static func _track(model: Dictionary, name: String) -> Variant:
	for t in model.get("tracks", []):
		if str(t.name) == name:
			return t
	return null


# --- Validation -----------------------------------------------------------------------

static func is_valid_name(name: String) -> bool:
	return _re(NAME_RE).search(name) != null


static func is_valid_node(node: String) -> bool:
	return _re(NODE_RE).search(node) != null


## "" (everywhere) or space-separated key=value pairs.
static func is_valid_context(context: String) -> bool:
	for part in context.split(" ", false):
		if _re(CONTEXT_RE).search(part) == null:
			return false
	return true


static func is_valid_duration(duration: String) -> bool:
	return _re(DURATION_RE).search(duration) != null


static func is_uuid(text: String) -> bool:
	return _re(UUID_RE).search(text) != null


static func _re(pattern: String) -> RegEx:
	if not _regexes.has(pattern):
		_regexes[pattern] = RegEx.create_from_string(pattern)
	return _regexes[pattern]
