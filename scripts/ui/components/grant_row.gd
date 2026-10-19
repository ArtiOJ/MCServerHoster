class_name GrantRow
extends PanelContainer
## One access key in the Remote access dialog: who it is for, what it opens, whether they
## are connected right now, and its actions. Shows a key as HostOps.access_get lists it,
## for this computer or one you are system admin of.

signal copy_requested(grant: Dictionary)
signal servers_requested(grant: Dictionary)
signal revoke_requested(grant: Dictionary)

const CONNECTED_COLOR := Color("3fb97f")
const IDLE_COLOR := Color("6b7280")

## {id, name, role, servers, created, last_used, connected_from}
var grant := {}
## Server id -> name on the key's computer.
var _server_names := {}

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


func setup(g: Dictionary, server_names: Dictionary) -> void:
	grant = g
	_server_names = server_names
	refresh()


func refresh() -> void:
	if grant.is_empty() or not is_node_ready():
		return
	var role := int(grant.role)
	var connected := PackedStringArray(grant.get("connected_from", []))
	_dot.color = CONNECTED_COLOR if not connected.is_empty() else IDLE_COLOR
	_name_label.text = str(grant.name)
	var parts := PackedStringArray([RemoteProtocol.ROLE_NAMES[role]])
	if role != RemoteProtocol.Role.SYSTEM_ADMIN:
		parts.append(_names())
	if not connected.is_empty():
		parts.append("connected from %s" % ", ".join(connected))
	elif int(grant.last_used) > 0:
		parts.append("last connected %s" % Fmt.datetime(int(grant.last_used)))
	else:
		parts.append("not used yet")
	_detail_label.text = " · ".join(parts)
	_servers_button.visible = role != RemoteProtocol.Role.SYSTEM_ADMIN


func _names() -> String:
	var names := PackedStringArray()
	for id in grant.get("servers", []):
		names.append(str(_server_names.get(str(id), id)))
	return ", ".join(names) if not names.is_empty() else "no servers"
