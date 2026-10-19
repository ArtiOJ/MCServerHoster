class_name PlayerLists
extends RefCounted
## Reads and edits the vanilla access-list files (whitelist.json, ops.json,
## banned-players.json, banned-ips.json) directly, so they can be changed while the
## server is stopped. Entries keep any fields this code does not know about, and files
## are written the way Minecraft writes them (pretty-printed, two-space indent).
##
## Player entries need a UUID. It comes from the server's usercache.json when the name
## is known there; otherwise from Mojang (online-mode servers, or offline servers behind a
## forwarding proxy) or computed the way offline-mode servers do it.

enum Kind { WHITELIST, OPS, BANS, IP_BANS }

const FILES: PackedStringArray = ["whitelist.json", "ops.json", "banned-players.json", "banned-ips.json"]
const SOURCE := "Server Manager"
const MOJANG_PROFILE_URL := "https://api.mojang.com/users/profiles/minecraft/%s"
const USER_AGENT := "GodotServerManager/0.1 (local Minecraft server manager)"

static var _re_name := RegEx.create_from_string("^[A-Za-z0-9_]{3,16}$")
static var _re_ipv4 := RegEx.create_from_string("^(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)(\\.(25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)){3}$")


static func is_valid_name(player_name: String) -> bool:
	return _re_name.search(player_name) != null


static func is_valid_ip(ip: String) -> bool:
	return _re_ipv4.search(ip) != null or (ip.contains(":") and ip.is_valid_ip_address())


static func file_path(dir: String, kind: Kind) -> String:
	return dir.path_join(FILES[kind])


## Entries of a list file (an empty array when the file is missing or unreadable).
static func read(dir: String, kind: Kind) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var path := file_path(dir, kind)
	if not FileAccess.file_exists(path):
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Array:
		for entry in data:
			if entry is Dictionary:
				out.append(entry)
	return out


static func write(dir: String, kind: Kind, entries: Array[Dictionary]) -> Error:
	var path := file_path(dir, kind)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(to_minecraft_json(entries))
	f.close()
	return DirAccess.rename_absolute(tmp, path)


## Index of the entry for [param key] (player name, case-insensitive, or IP), or -1.
static func find(entries: Array[Dictionary], key: String, kind: Kind) -> int:
	var field := "ip" if kind == Kind.IP_BANS else "name"
	for i in entries.size():
		if str(entries[i].get(field, "")).to_lower() == key.to_lower():
			return i
	return -1


## Adds (or replaces) a player entry. [param profile] is {uuid, name}; [param options] may
## hold "level" (ops) and "reason" (bans).
static func add_player(dir: String, kind: Kind, profile: Dictionary, options := {}) -> Error:
	var entries := read(dir, kind)
	var entry := {"uuid": str(profile.uuid), "name": str(profile.name)}
	match kind:
		Kind.OPS:
			entry["level"] = clampi(int(options.get("level", 4)), 1, 4)
			entry["bypassesPlayerLimit"] = bool(options.get("bypasses_player_limit", false))
		Kind.BANS:
			entry.merge(_ban_fields(str(options.get("reason", ""))))
	var idx := find(entries, entry.name, kind)
	if idx < 0:
		for i in entries.size():
			if str(entries[i].get("uuid", "")) == entry.uuid:
				idx = i
	if idx >= 0:
		# Keep fields we don't manage (and the original timestamps when only updating).
		var merged: Dictionary = entries[idx].duplicate()
		merged.merge(entry, true)
		entries[idx] = merged
	else:
		entries.append(entry)
	return write(dir, kind, entries)


static func add_ip_ban(dir: String, ip: String, reason := "") -> Error:
	var entries := read(dir, Kind.IP_BANS)
	var entry := {"ip": ip}
	entry.merge(_ban_fields(reason))
	var idx := find(entries, ip, Kind.IP_BANS)
	if idx >= 0:
		entries[idx] = entry
	else:
		entries.append(entry)
	return write(dir, Kind.IP_BANS, entries)


## Removes the entry for [param key]. Returns OK, or ERR_DOES_NOT_EXIST if it wasn't listed.
static func remove(dir: String, kind: Kind, key: String) -> Error:
	var entries := read(dir, kind)
	var idx := find(entries, key, kind)
	if idx < 0:
		return ERR_DOES_NOT_EXIST
	entries.remove_at(idx)
	return write(dir, kind, entries)


static func set_op_level(dir: String, player_name: String, level: int) -> Error:
	var entries := read(dir, Kind.OPS)
	var idx := find(entries, player_name, Kind.OPS)
	if idx < 0:
		return ERR_DOES_NOT_EXIST
	entries[idx]["level"] = clampi(level, 1, 4)
	return write(dir, Kind.OPS, entries)


## UUID an offline-mode server gives a player: name-based UUID v3 of "OfflinePlayer:<name>".
static func offline_uuid(player_name: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(("OfflinePlayer:" + player_name).to_utf8_buffer())
	var h := ctx.finish()
	h[6] = (h[6] & 0x0f) | 0x30  # version 3
	h[8] = (h[8] & 0x3f) | 0x80  # IETF variant
	return dash_uuid(h.hex_encode())


## "069a79f444e94726a5befca90e38aaf5" -> "069a79f4-44e9-4726-a5be-fca90e38aaf5".
static func dash_uuid(hex: String) -> String:
	hex = hex.replace("-", "").to_lower()
	if hex.length() != 32:
		return hex
	return "%s-%s-%s-%s-%s" % [hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20)]


## {uuid, name} for [param player_name] from the server's usercache.json, or {}.
static func usercache_lookup(dir: String, player_name: String) -> Dictionary:
	var path := dir.path_join("usercache.json")
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Array:
		for entry in data:
			if entry is Dictionary and str(entry.get("name", "")).to_lower() == player_name.to_lower() and str(entry.get("uuid", "")) != "":
				return {"uuid": str(entry.uuid), "name": str(entry.name)}
	return {}


## Whether players on this server have Mojang (online) UUIDs: online mode, or an
## offline server behind a proxy that forwards real profiles (Velocity, BungeeCord).
static func uses_online_uuids(dir: String) -> bool:
	var props := ServerProperties.load_file(dir.path_join("server.properties"))
	if props.get_bool("online-mode", true):
		return true
	var paper := YamlDoc.load_file(dir.path_join(SettingsCatalog.PAPER_GLOBAL))
	if paper.get_value("proxies.velocity.enabled", "false") == "true" and paper.get_value("proxies.velocity.online-mode", "true") == "true":
		return true
	return YamlDoc.load_file(dir.path_join(SettingsCatalog.SPIGOT)).get_value("settings.bungeecord", "false") == "true"


## Interprets a Mojang profile lookup. Returns {ok, uuid, name} or {ok: false, error}.
static func parse_mojang_response(code: int, body: String, player_name: String) -> Dictionary:
	match code:
		200:
			var data = JSON.parse_string(body)
			if data is Dictionary and str(data.get("id", "")).length() == 32:
				return {"ok": true, "uuid": dash_uuid(str(data.id)), "name": str(data.get("name", player_name))}
			return {"ok": false, "error": "Unexpected answer from Mojang."}
		204, 404:
			return {"ok": false, "error": "There is no Minecraft account named \"%s\"." % player_name}
		429:
			return {"ok": false, "error": "Mojang is rate-limiting lookups; try again in a minute."}
	return {"ok": false, "error": "Mojang lookup failed (HTTP %d)." % code}


## Resolves a player name to {ok, uuid, name, source} for list entries. [param owner] must be
## in the scene tree (it hosts the HTTP request when Mojang has to be asked).
static func resolve(owner: Node, dir: String, player_name: String) -> Dictionary:
	player_name = player_name.strip_edges()
	if not is_valid_name(player_name):
		return {"ok": false, "error": "Names are 3–16 letters, digits or underscores."}
	var cached := usercache_lookup(dir, player_name)
	if not cached.is_empty():
		cached.ok = true
		cached.source = "usercache"
		return cached
	if not uses_online_uuids(dir):
		return {"ok": true, "uuid": offline_uuid(player_name), "name": player_name, "source": "offline"}
	var http := HTTPRequest.new()
	http.timeout = 15
	owner.add_child(http)
	var err := http.request(MOJANG_PROFILE_URL % player_name.uri_encode(), PackedStringArray(["User-Agent: " + USER_AGENT]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Could not contact Mojang (%s)." % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "Could not reach Mojang to look up \"%s\" — are you online?" % player_name}
	var result := parse_mojang_response(response[1], (response[3] as PackedByteArray).get_string_from_utf8(), player_name)
	if result.ok:
		result.source = "mojang"
	return result


## Timestamp in Minecraft's ban-list format: "2026-10-18 20:38:29 -0400" (local time).
static func timestamp(unix := -1) -> String:
	if unix < 0:
		unix = int(Time.get_unix_time_from_system())
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))
	var d := Time.get_datetime_dict_from_unix_time(unix + bias * 60)
	var sgn := "+" if bias >= 0 else "-"
	return "%04d-%02d-%02d %02d:%02d:%02d %s%02d%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second,
			sgn, absi(bias) / 60, absi(bias) % 60]


## Serializes entries like Minecraft's Gson pretty printer: keys in their original order,
## two-space indent, integral numbers without a decimal point.
static func to_minecraft_json(entries: Array[Dictionary]) -> String:
	if entries.is_empty():
		return "[]"
	var parts := PackedStringArray()
	for entry in entries:
		var fields := PackedStringArray()
		for key in entry:
			fields.append("    %s: %s" % [JSON.stringify(str(key)), _json_value(entry[key])])
		parts.append("  {\n" + ",\n".join(fields) + "\n  }")
	return "[\n" + ",\n".join(parts) + "\n]"


static func _json_value(value: Variant) -> String:
	if value is float and is_equal_approx(value, roundf(value)) and absf(value) < 1e15:
		return str(int(value))
	return JSON.stringify(value, "", false)


static func _ban_fields(reason: String) -> Dictionary:
	return {
		"created": timestamp(),
		"source": SOURCE,
		"expires": "forever",
		"reason": reason.strip_edges() if reason.strip_edges() != "" else "Banned by an operator.",
	}
