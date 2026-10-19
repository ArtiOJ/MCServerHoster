extends Node
## Other computers this Server Manager connects to with an access key (docs/PLAN.md §10).
## Each is a [RemoteLink] child that stays connected in the background. Saved with their
## secrets in the profile folder, readable only by this user.

signal links_changed
signal link_status_changed(link: RemoteLink)
## A server became visible on some link (relayed from the links).
signal server_added(server: RemoteServer)
signal server_removed(key: String)

var _loading := false


func _ready() -> void:
	if AppSettings.other_instance_pid > 0:
		return
	_load()
	if AppSettings.autostart_enabled:
		for link in links():
			link.connect_now.call_deferred()


func links() -> Array[RemoteLink]:
	var out: Array[RemoteLink] = []
	for child in get_children():
		if child is RemoteLink and not child.is_queued_for_deletion():
			out.append(child)
	return out


func find_link(link_id: String) -> RemoteLink:
	for link in links():
		if link.link_id == link_id:
			return link
	return null


## The remote server with [param handle_key] ("<link id>/<server id>"), or null.
func find_server(handle_key: String) -> RemoteServer:
	var link := find_link(handle_key.get_slice("/", 0))
	return link.find_handle(handle_key) as RemoteServer if link != null else null


## Adds a computer from an invite code and connects to it. [param address] replaces the
## invite's addresses when given (e.g. a DNS name). Returns {ok, link} or {ok: false, error}.
func add_from_invite(code: String, address := "") -> Dictionary:
	var invite := RemoteProtocol.parse_invite(code)
	if not invite.ok:
		return invite
	for link in links():
		if link.key_id == invite.key:
			return {"ok": false, "error": "That access key is already added (%s)." % link.label}
	var addresses: PackedStringArray = invite.addresses
	if address.strip_edges() != "":
		addresses = PackedStringArray([address.strip_edges()])
	if addresses.is_empty():
		return {"ok": false, "error": "The invite has no address. Enter the other computer's address."}
	var link := RemoteLink.from_dict({
		"id": Fmt.random_token(8), "label": invite.name if invite.name != "" else "Remote computer",
		"addresses": Array(addresses), "port": invite.port, "key": invite.key, "secret": invite.secret,
	})
	_attach(link)
	save()
	links_changed.emit()
	link.connect_now()
	return {"ok": true, "link": link}


## Forgets a computer (its key stays valid on the other side until its owner revokes it).
func remove(link: RemoteLink) -> void:
	link.disconnect_now()
	for server in link.remote_servers():
		server_removed.emit(server.key())
	remove_child(link)
	link.queue_free()
	save()
	links_changed.emit()


## Changes where a computer is reached and reconnects.
func set_addresses(link: RemoteLink, addresses: PackedStringArray, port: int) -> void:
	link.addresses = addresses
	link.port = port
	save()
	link.connect_now()


## Servers opened by server-admin keys; they are listed under "Remote servers".
func server_admin_servers() -> Array[RemoteServer]:
	var out: Array[RemoteServer] = []
	for link in links():
		if link.role != RemoteProtocol.Role.SYSTEM_ADMIN:
			out.append_array(link.remote_servers())
	return out


func system_admin_links() -> Array[RemoteLink]:
	return links().filter(func(l: RemoteLink) -> bool: return l.role == RemoteProtocol.Role.SYSTEM_ADMIN)


func _attach(link: RemoteLink) -> void:
	add_child(link)
	link.status_changed.connect(func() -> void: link_status_changed.emit(link))
	link.server_added.connect(func(h: ServerHandle) -> void: server_added.emit(h as RemoteServer))
	link.server_removed.connect(func(k: String) -> void: server_removed.emit(k))


func _path() -> String:
	return AppSettings.profile_path("remote-hosts.json")


func _load() -> void:
	if not FileAccess.file_exists(_path()):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(_path()))
	if not data is Dictionary:
		push_warning("Ignoring unreadable remote computers file")
		return
	_loading = true
	for d in data.get("hosts", []):
		if d is Dictionary and str(d.get("key", "")) != "" and str(d.get("secret", "")) != "":
			var link := RemoteLink.from_dict(d)
			# The role is only known once connected; remember it so the list shows right away.
			link.role = int(d.get("role", -1))
			_attach(link)
	_loading = false


func save() -> void:
	if _loading:
		return
	var hosts: Array = []
	for link in links():
		var d := link.to_dict()
		d["role"] = link.role
		hosts.append(d)
	var err := AppSettings.write_private(_path(), JSON.stringify({"hosts": hosts}, "\t"))
	if err != OK:
		Notifier.error("Could not save the remote computers list: %s" % error_string(err))
