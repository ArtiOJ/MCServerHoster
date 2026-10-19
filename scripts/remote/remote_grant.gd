class_name RemoteGrant
extends RefCounted
## One access key for this computer: who it is for, its secret, its role and (for server
## admins) which servers it opens. Stored by [code]RemoteAccess[/code].

var id := ""
## Who the key is for, shown in logs and session lists.
var name := ""
var secret := ""
var role: RemoteProtocol.Role = RemoteProtocol.Role.SERVER_ADMIN
## Servers a server admin may control (ignored for system admins).
var server_ids := PackedStringArray()
var created_unix := 0
var last_used_unix := 0


static func create(person: String, grant_role: RemoteProtocol.Role, servers: PackedStringArray) -> RemoteGrant:
	var g := RemoteGrant.new()
	g.id = Fmt.random_token(10)
	g.name = person.strip_edges() if person.strip_edges() != "" else "Remote user"
	g.secret = RemoteProtocol.new_secret()
	g.role = grant_role
	g.server_ids = servers
	g.created_unix = int(Time.get_unix_time_from_system())
	return g


func is_system_admin() -> bool:
	return role == RemoteProtocol.Role.SYSTEM_ADMIN


func can_access(server_id: String) -> bool:
	return is_system_admin() or server_ids.has(server_id)


func allows(op: String, server_id := "") -> bool:
	if not RemoteProtocol.allows(role, op):
		return false
	return server_id == "" or can_access(server_id)


func role_name() -> String:
	return RemoteProtocol.ROLE_NAMES[role]


func to_dict() -> Dictionary:
	return {
		"id": id, "name": name, "secret": secret, "role": int(role), "servers": Array(server_ids),
		"created": created_unix, "last_used": last_used_unix,
	}


static func from_dict(d: Dictionary) -> RemoteGrant:
	var g := RemoteGrant.new()
	g.id = str(d.get("id", ""))
	g.name = str(d.get("name", "Remote user"))
	g.secret = str(d.get("secret", ""))
	g.role = clampi(int(d.get("role", RemoteProtocol.Role.SERVER_ADMIN)), 0, RemoteProtocol.Role.size() - 1) as RemoteProtocol.Role
	g.server_ids = PackedStringArray(d.get("servers", []))
	g.created_unix = int(d.get("created", 0))
	g.last_used_unix = int(d.get("last_used", 0))
	return g
