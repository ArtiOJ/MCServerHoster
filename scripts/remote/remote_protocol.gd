class_name RemoteProtocol
extends RefCounted
## Shared rules of the remote-access protocol (docs/PLAN.md §10): framing, proofs,
## invite codes and which role may use which operation.
##
## A connection starts with one mode byte: [constant MODE_BOOTSTRAP] fetches the host's
## certificate (proved genuine with the access key), [constant MODE_TLS] starts TLS with
## the pinned certificate. Then frames follow: a 4-byte little-endian length and UTF-8 JSON.

const VERSION := 1
const DEFAULT_PORT := 25590
## Common name of every host certificate; clients verify against the pinned certificate.
const CERT_CN := "server-manager"
const MODE_BOOTSTRAP := 0x42
const MODE_TLS := 0x54
const MAX_FRAME := 16 * 1024 * 1024
## Before authentication only tiny frames are accepted.
const MAX_FRAME_UNAUTHENTICATED := 4096
const INVITE_PREFIX := "smr1:"

enum Role { SYSTEM_ADMIN, SERVER_ADMIN }

const ROLE_NAMES: PackedStringArray = ["System admin", "Server admin"]
const ROLE_DESCRIPTIONS: PackedStringArray = [
	"Everything on this computer: all servers, creating and deleting servers, preferences, firewall and access keys.",
	"Only the chosen servers, and only what belongs to a server (start/stop, console, settings, plugins, worlds, backups, players). Not the computer's network, power or preferences.",
]

## Operation -> lowest role allowed to use it. Server admins get the server-level ones on
## the servers their key lists; everything else needs a system admin.
const OPS := {
	# Server-level (server admins on their servers)
	"start": Role.SERVER_ADMIN,
	"start_temporary": Role.SERVER_ADMIN,
	"finish_temporary": Role.SERVER_ADMIN,
	"stop": Role.SERVER_ADMIN,
	"restart": Role.SERVER_ADMIN,
	"kill": Role.SERVER_ADMIN,
	"command": Role.SERVER_ADMIN,
	"stop_orphan": Role.SERVER_ADMIN,
	"update_paper": Role.SERVER_ADMIN,
	"check_updates": Role.SERVER_ADMIN,
	"icon_get": Role.SERVER_ADMIN,
	"icon_set": Role.SERVER_ADMIN,
	"settings_get": Role.SERVER_ADMIN,
	"settings_save": Role.SERVER_ADMIN,
	"file_read": Role.SERVER_ADMIN,
	"file_write": Role.SERVER_ADMIN,
	"plugins_list": Role.SERVER_ADMIN,
	"plugin_install": Role.SERVER_ADMIN,
	"plugin_toggle": Role.SERVER_ADMIN,
	"plugin_delete": Role.SERVER_ADMIN,
	"plugin_install_modrinth": Role.SERVER_ADMIN,
	"backups_list": Role.SERVER_ADMIN,
	"backup_create": Role.SERVER_ADMIN,
	"backup_restore": Role.SERVER_ADMIN,
	"backup_delete": Role.SERVER_ADMIN,
	"backup_file": Role.SERVER_ADMIN,
	"logs_list": Role.SERVER_ADMIN,
	"log_read": Role.SERVER_ADMIN,
	"lists_get": Role.SERVER_ADMIN,
	"list_add": Role.SERVER_ADMIN,
	"list_remove": Role.SERVER_ADMIN,
	"op_level": Role.SERVER_ADMIN,
	"whitelist_set": Role.SERVER_ADMIN,
	"worlds_list": Role.SERVER_ADMIN,
	"world_activate": Role.SERVER_ADMIN,
	"world_reset": Role.SERVER_ADMIN,
	"world_delete": Role.SERVER_ADMIN,
	"world_export": Role.SERVER_ADMIN,
	"datapack_add": Role.SERVER_ADMIN,
	"datapack_toggle": Role.SERVER_ADMIN,
	"datapack_remove": Role.SERVER_ADMIN,
	"world_import_analyze": Role.SERVER_ADMIN,
	"world_import": Role.SERVER_ADMIN,
	"world_import_cancel": Role.SERVER_ADMIN,
	"resources_info": Role.SERVER_ADMIN,
	"port_check": Role.SERVER_ADMIN,
	"launch_preview": Role.SERVER_ADMIN,
	"config_save": Role.SERVER_ADMIN,
	"network_info": Role.SERVER_ADMIN,
	"network_refresh": Role.SERVER_ADMIN,
	"network_test": Role.SERVER_ADMIN,
	"port_set": Role.SERVER_ADMIN,
	"perms_get": Role.SERVER_ADMIN,
	"perms_apply": Role.SERVER_ADMIN,
	"perms_install": Role.SERVER_ADMIN,
	"perms_player": Role.SERVER_ADMIN,
	"perms_known": Role.SERVER_ADMIN,
	"chunky_status": Role.SERVER_ADMIN,
	"chunky_start": Role.SERVER_ADMIN,
	"chunky_control": Role.SERVER_ADMIN,
	"chunky_trim": Role.SERVER_ADMIN,
	# File transfers (any key; only usable by the operations above and below)
	"upload_begin": Role.SERVER_ADMIN,
	"upload_chunk": Role.SERVER_ADMIN,
	"upload_end": Role.SERVER_ADMIN,
	"download_chunk": Role.SERVER_ADMIN,
	"download_close": Role.SERVER_ADMIN,
	# Server-level but reaching the computer or the router (system admins only)
	"upnp_set": Role.SYSTEM_ADMIN,
	"upnp_retry": Role.SYSTEM_ADMIN,
	"firewall_allow": Role.SYSTEM_ADMIN,
	"delete": Role.SYSTEM_ADMIN,
	"duplicate": Role.SYSTEM_ADMIN,
	# Computer-level (system admins only)
	"create_server": Role.SYSTEM_ADMIN,
	"start_all": Role.SYSTEM_ADMIN,
	"stop_all": Role.SYSTEM_ADMIN,
	"prefs_get": Role.SYSTEM_ADMIN,
	"prefs_save": Role.SYSTEM_ADMIN,
	"java_rescan": Role.SYSTEM_ADMIN,
	"java_add": Role.SYSTEM_ADMIN,
	"firewall_remove": Role.SYSTEM_ADMIN,
	"dhcp_reserved": Role.SYSTEM_ADMIN,
	"server_import_analyze": Role.SYSTEM_ADMIN,
	"server_import": Role.SYSTEM_ADMIN,
	"server_import_cancel": Role.SYSTEM_ADMIN,
	"access_get": Role.SYSTEM_ADMIN,
	"access_rename": Role.SYSTEM_ADMIN,
	"grant_create": Role.SYSTEM_ADMIN,
	"grant_update": Role.SYSTEM_ADMIN,
	"grant_revoke": Role.SYSTEM_ADMIN,
	"grant_invite": Role.SYSTEM_ADMIN,
}
## Operations that act on the computer rather than on one server (no "server" field).
const HOST_OPS: PackedStringArray = [
	"create_server", "start_all", "stop_all", "prefs_get", "prefs_save", "java_rescan", "java_add",
	"firewall_remove", "dhcp_reserved", "server_import_analyze", "server_import", "server_import_cancel",
	"access_get", "access_rename", "grant_create", "grant_update", "grant_revoke", "grant_invite",
]
const TRANSFER_OPS: PackedStringArray = ["upload_begin", "upload_chunk", "upload_end", "download_chunk", "download_close"]
## Bytes per upload or download chunk.
const CHUNK_BYTES := 1024 * 1024
## Arguments naming files on the host; a client can never send them (see ServerOps).
const PATH_ARGS: PackedStringArray = ["files", "source", "dest", "path", "dir"]


static func allows(role: int, op: String) -> bool:
	if not OPS.has(op):
		return false
	return role == Role.SYSTEM_ADMIN or OPS[op] == Role.SERVER_ADMIN


# --- Framing -----------------------------------------------------------------------

static func encode(message: Dictionary) -> PackedByteArray:
	var body := JSON.stringify(message).to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, body.size())
	out.append_array(body)
	return out


## Collects bytes and splits them into messages. [member error] is set (and stays set)
## when a frame is too large or not a JSON object.
class FrameReader:
	extends RefCounted

	var max_frame := MAX_FRAME_UNAUTHENTICATED
	var error := ""
	var _buffer := PackedByteArray()

	func feed(bytes: PackedByteArray) -> void:
		_buffer.append_array(bytes)

	## The next complete message, or null.
	func next() -> Variant:
		if error != "" or _buffer.size() < 4:
			return null
		var size := _buffer.decode_u32(0)
		if size > max_frame:
			error = "Message too large (%d bytes)." % size
			return null
		if _buffer.size() < 4 + size:
			return null
		var body := _buffer.slice(4, 4 + size)
		_buffer = _buffer.slice(4 + size)
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if not parsed is Dictionary:
			error = "Malformed message."
			return null
		return parsed

	func buffered() -> int:
		return _buffer.size()


# --- Proofs ------------------------------------------------------------------------

static func nonce() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## A new 256-bit access key secret (URL-safe base64, no padding).
static func new_secret() -> String:
	return base64url(Crypto.new().generate_random_bytes(32))


## HMAC-SHA256 proof over [param label] and [param parts], keyed with [param secret].
static func proof(secret: String, label: String, parts: Array) -> String:
	var message := label
	for p in parts:
		message += "\n" + str(p)
	return Crypto.new().hmac_digest(HashingContext.HASH_SHA256, secret.to_utf8_buffer(), message.to_utf8_buffer()).hex_encode()


## Compares two proofs without leaking where they differ through timing.
static func proofs_equal(a: String, b: String) -> bool:
	if a.length() != b.length() or a.is_empty():
		return false
	var diff := 0
	for i in a.length():
		diff |= a.unicode_at(i) ^ b.unicode_at(i)
	return diff == 0


# --- Invite codes --------------------------------------------------------------------

## Everything a client needs to connect, as one string to paste:
## {name, addresses, port, key, secret}.
static func make_invite(info: Dictionary) -> String:
	var data := {
		"v": VERSION, "n": str(info.get("name", "")), "a": Array(info.get("addresses", [])),
		"p": int(info.get("port", DEFAULT_PORT)), "k": str(info.key), "s": str(info.secret),
	}
	return INVITE_PREFIX + base64url(JSON.stringify(data).to_utf8_buffer())


## Parses an invite code. Returns {ok, name, addresses, port, key, secret} or {ok: false, error}.
static func parse_invite(code: String) -> Dictionary:
	var text := code.strip_edges().replace(" ", "").replace("\n", "")
	if not text.begins_with(INVITE_PREFIX):
		return {"ok": false, "error": "This isn't a Server Manager invite code (it should start with %s)." % INVITE_PREFIX}
	var raw := base64url_decode(text.trim_prefix(INVITE_PREFIX))
	var data = JSON.parse_string(raw.get_string_from_utf8()) if not raw.is_empty() else null
	if not data is Dictionary or not data.has("k") or not data.has("s"):
		return {"ok": false, "error": "The invite code is incomplete or damaged. Copy it again."}
	var addresses := PackedStringArray()
	if data.get("a") is Array:
		for a in data.a:
			if str(a).strip_edges() != "":
				addresses.append(str(a).strip_edges())
	var port := int(data.get("p", DEFAULT_PORT))
	var key := str(data.k)
	var secret := str(data.s)
	if port < 1 or port > 65535 or key.length() < 4 or secret.length() < 32:
		return {"ok": false, "error": "The invite code is invalid."}
	return {"ok": true, "name": str(data.get("n", "")), "addresses": addresses, "port": port, "key": key, "secret": secret}


static func base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")


static func base64url_decode(text: String) -> PackedByteArray:
	var b64 := text.replace("-", "+").replace("_", "/")
	while b64.length() % 4 != 0:
		b64 += "="
	return Marshalls.base64_to_raw(b64)


## Splits "host:port" (or "[v6]:port"); a missing port gives [param default_port].
static func split_address(address: String, default_port: int) -> Dictionary:
	var a := address.strip_edges()
	if a.begins_with("["):
		var end := a.find("]")
		if end > 0:
			var rest := a.substr(end + 1)
			return {"host": a.substr(1, end - 1), "port": rest.trim_prefix(":").to_int() if rest.begins_with(":") else default_port}
	if a.count(":") == 1:
		var p := a.get_slice(":", 1).to_int()
		return {"host": a.get_slice(":", 0), "port": p if p > 0 and p <= 65535 else default_port}
	return {"host": a, "port": default_port}
