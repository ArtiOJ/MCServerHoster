class_name GrantRow
extends PanelContainer
## One access key in the Remote access dialog: who it is for, what it opens, whether they
## are connected right now, and its actions.

signal copy_requested(grant: RemoteGrant)
signal servers_requested(grant: RemoteGrant)
signal revoke_requested(grant: RemoteGrant)

const CONNECTED_COLOR := Color("3fb97f")
const IDLE_COLOR := Color("6b7280")

var grant: RemoteGrant

@onready var _dot: StatusDot = %Dot
@onready var _name_label: Label = %NameLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _copy_button: Button = %CopyButton
@onready var _servers_button: Button = %ServersButton
@onready var _revoke_button: Button = %RevokeButton


func _ready() -> void:
	_copy_button.pressed.connect(func() -> void: copy_requested.emit(grant))
	_servers_button.pressed.connect(func() -> void: servers_requested.emit(grant))
	_revoke_button.pressed.connect(func() -> void: revoke_requested.emit(grant))


func setup(g: RemoteGrant) -> void:
	grant = g
	refresh()


func refresh() -> void:
	if grant == null or not is_node_ready():
		return
	var sessions := RemoteAccess.sessions_for(grant)
	_dot.color = CONNECTED_COLOR if not sessions.is_empty() else IDLE_COLOR
	_name_label.text = grant.name
	var parts := PackedStringArray([grant.role_name()])
	if not grant.is_system_admin():
		parts.append(_server_names())
	if not sessions.is_empty():
		parts.append("connected from %s" % ", ".join(sessions.map(func(s: RemoteSession) -> String: return s.address)))
	elif grant.last_used_unix > 0:
		parts.append("last connected %s" % Fmt.datetime(grant.last_used_unix))
	else:
		parts.append("not used yet")
	_detail_label.text = " · ".join(parts)
	_servers_button.visible = not grant.is_system_admin()


func _server_names() -> String:
	var names := PackedStringArray()
	for id in grant.server_ids:
		var inst := ServerManager.get_instance(id)
		names.append(inst.config.display_name if inst != null else id)
	return ", ".join(names) if not names.is_empty() else "no servers"
