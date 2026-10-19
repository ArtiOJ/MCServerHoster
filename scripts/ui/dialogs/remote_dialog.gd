class_name RemoteDialog
extends AcceptDialog
## Remote access (docs/PLAN.md §10): share this computer through access keys, and connect
## to other computers with the invite codes their owners give you.

enum TabIndex { SHARE, CONNECT }

const GRANT_ROW := preload("res://scenes/components/grant_row.tscn")
const LINK_ROW := preload("res://scenes/components/remote_link_row.tscn")
const ROLE_WARNINGS: PackedStringArray = [
	"A system admin can do everything with your servers, including creating and deleting them.",
	"A server admin fully controls the chosen servers: starting and stopping, the console, settings and Paper updates.",
]

## Key being edited in the key dialog (null while creating a new one).
var _editing: RemoteGrant
var _revoking: RemoteGrant
var _link_target: RemoteLink
var _firewall_busy := false

@onready var _tabs: TabContainer = %Tabs
@onready var _enable_check: CheckButton = %EnableCheck
@onready var _listen_status: Label = %ListenStatus
@onready var _port_field: PortField = %PortField
@onready var _port_hint: Label = %PortHint
@onready var _name_edit: LineEdit = %NameEdit
@onready var _reach_notice: PanelContainer = %ReachNotice
@onready var _reach_label: Label = %ReachLabel
@onready var _firewall_button: Button = %FirewallButton
@onready var _new_key_button: Button = %NewKeyButton
@onready var _grant_list: VBoxContainer = %GrantList
@onready var _no_keys_label: Label = %NoKeysLabel
@onready var _add_link_button: Button = %AddLinkButton
@onready var _link_list: VBoxContainer = %LinkList
@onready var _no_links_label: Label = %NoLinksLabel
@onready var _key_dialog: ConfirmationDialog = %KeyDialog
@onready var _person_edit: LineEdit = %PersonEdit
@onready var _role_option: OptionButton = %RoleOption
@onready var _role_hint: Label = %RoleHint
@onready var _servers_label: Label = %ServersLabel
@onready var _servers_scroll: ScrollContainer = %ServersScroll
@onready var _server_checks: VBoxContainer = %ServerChecks
@onready var _key_warning: Label = %KeyWarning
@onready var _invite_dialog: AcceptDialog = %InviteDialog
@onready var _invite_intro: Label = %InviteIntro
@onready var _invite_text: TextEdit = %InviteText
@onready var _copy_invite_button: Button = %CopyInviteButton
@onready var _invite_hint: Label = %InviteHint
@onready var _revoke_dialog: ConfirmationDialog = %RevokeDialog
@onready var _add_link_dialog: ConfirmationDialog = %AddLinkDialog
@onready var _code_edit: TextEdit = %CodeEdit
@onready var _address_edit: LineEdit = %AddressEdit
@onready var _add_error: Label = %AddError
@onready var _address_dialog: ConfirmationDialog = %AddressDialog
@onready var _link_address_edit: LineEdit = %LinkAddressEdit
@onready var _remove_link_dialog: ConfirmationDialog = %RemoveLinkDialog


func _ready() -> void:
	_tabs.set_tab_title(TabIndex.SHARE, "Share this computer")
	_tabs.set_tab_title(TabIndex.CONNECT, "Connect to others")
	_enable_check.toggled.connect(func(on: bool) -> void: _apply_listener(on))
	_port_field.text_submitted.connect(func(_t: String) -> void: _apply_listener(_enable_check.button_pressed))
	_port_field.focus_exited.connect(func() -> void:
		if _port_field.is_valid() and _port_field.port != RemoteAccess.port:
			_apply_listener(_enable_check.button_pressed))
	_name_edit.text_submitted.connect(func(_t: String) -> void: _save_name())
	_name_edit.focus_exited.connect(_save_name)
	_firewall_button.pressed.connect(_allow_in_firewall)
	_new_key_button.pressed.connect(func() -> void: _open_key_dialog(null))
	_role_option.item_selected.connect(func(_i: int) -> void: _update_key_dialog())
	_person_edit.text_changed.connect(func(_t: String) -> void: _update_key_dialog())
	_key_dialog.confirmed.connect(_save_key)
	_copy_invite_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_invite_text.text)
		Notifier.info("Invite code copied. Send it privately."))
	_revoke_dialog.confirmed.connect(func() -> void:
		if _revoking != null:
			RemoteAccess.revoke_grant(_revoking)
			Notifier.info("Revoked the key for %s." % _revoking.name)
			_revoking = null)
	_add_link_button.pressed.connect(_open_add_link)
	_add_link_dialog.confirmed.connect(_add_link)
	_address_dialog.confirmed.connect(_save_address)
	_remove_link_dialog.confirmed.connect(func() -> void:
		if _link_target != null:
			RemoteHosts.remove(_link_target)
			_link_target = null)
	RemoteAccess.grants_changed.connect(_refresh_grants)
	RemoteAccess.sessions_changed.connect(_refresh_grants)
	RemoteAccess.status_changed.connect(_refresh_share)
	RemoteHosts.links_changed.connect(_refresh_links)
	RemoteHosts.link_status_changed.connect(func(_l: RemoteLink) -> void: _refresh_link_rows())
	NetworkService.status_changed.connect(func() -> void:
		if visible:
			_refresh_reach())


## Shows the dialog on [param tab] (see [enum TabIndex]).
func open(tab := TabIndex.SHARE) -> void:
	_tabs.current_tab = tab
	_refresh_share()
	_refresh_grants()
	_refresh_links()
	popup_centered()


# --- Share this computer --------------------------------------------------------

func _refresh_share() -> void:
	_enable_check.set_pressed_no_signal(RemoteAccess.enabled)
	_port_field.set_port(RemoteAccess.port)
	if not _name_edit.has_focus():
		_name_edit.text = RemoteAccess.computer_name
	if not RemoteAccess.enabled:
		_listen_status.text = "Off — nobody can connect."
	elif RemoteAccess.is_listening():
		_listen_status.text = "On — listening on port %d." % RemoteAccess.port
	else:
		_listen_status.text = RemoteAccess.listen_error
	_port_hint.text = "default %d" % RemoteProtocol.DEFAULT_PORT if RemoteAccess.port != RemoteProtocol.DEFAULT_PORT else ""
	_refresh_reach()


## Explains who can reach the port: the firewall first (it blocks even the home network),
## then the router for people elsewhere.
func _refresh_reach() -> void:
	if not RemoteAccess.enabled or not RemoteAccess.is_listening():
		_reach_notice.visible = false
		return
	var port := RemoteAccess.port
	var fw := NetworkService.firewall_port_status(port)
	var lan := str(PlatformBackend.get_current().default_route().get("address", ""))
	var lines := PackedStringArray()
	var blocked: bool = fw.active and fw.allowed != "yes"
	if blocked:
		lines.append("Your firewall (%s) blocks port %d, so nobody can connect yet, not even on your home network." % [fw.name, port])
	if lan != "":
		lines.append("On your network, others reach this computer at %s. From the internet, TCP port %d must be forwarded to %s in your router." % [lan, port, lan])
	_reach_label.text = "\n".join(lines)
	_reach_notice.visible = not lines.is_empty()
	_firewall_button.visible = blocked
	_firewall_button.disabled = _firewall_busy


func _apply_listener(on: bool) -> void:
	if not _port_field.is_valid():
		Notifier.warn(_port_field.error_text())
		_port_field.set_port(RemoteAccess.port)
		return
	var clash := ServerManager.port_owner(_port_field.port)
	if clash != null:
		Notifier.warn("Port %d is used by %s. Pick another port." % [_port_field.port, clash.config.display_name])
		_port_field.set_port(RemoteAccess.port)
		return
	RemoteAccess.set_enabled(on, _port_field.port)
	_refresh_share()


func _save_name() -> void:
	if _name_edit.text.strip_edges() != RemoteAccess.computer_name:
		RemoteAccess.set_computer_name(_name_edit.text)
		_name_edit.text = RemoteAccess.computer_name


func _allow_in_firewall() -> void:
	_firewall_busy = true
	_refresh_reach()
	var res: Dictionary = await NetworkService.allow_in_firewall(RemoteAccess.port, "Remote access (Server Manager)")
	_firewall_busy = false
	if res.ok:
		Notifier.success(res.message)
	else:
		Notifier.error(res.message)
	_refresh_reach()


func _refresh_grants() -> void:
	for child in _grant_list.get_children():
		if child is GrantRow:
			_grant_list.remove_child(child)
			child.queue_free()
	for g in RemoteAccess.grants:
		var row: GrantRow = GRANT_ROW.instantiate()
		_grant_list.add_child(row)
		row.setup(g)
		row.copy_requested.connect(func(grant: RemoteGrant) -> void:
			DisplayServer.clipboard_set(RemoteAccess.invite_for(grant))
			Notifier.info("Invite code for %s copied. Send it privately." % grant.name))
		row.servers_requested.connect(_open_key_dialog)
		row.revoke_requested.connect(_confirm_revoke)
	_no_keys_label.visible = RemoteAccess.grants.is_empty()


func _confirm_revoke(grant: RemoteGrant) -> void:
	_revoking = grant
	var connected := RemoteAccess.sessions_for(grant).size()
	_revoke_dialog.dialog_text = "Revoke the key for %s? %sTheir invite code stops working for good; give them a new key to let them back in." % [
			grant.name, "They are connected now and will be disconnected. " if connected > 0 else ""]
	_revoke_dialog.popup_centered(Vector2i(480, 0))


## Creates a key ([param grant] null) or edits the name and servers of [param grant].
func _open_key_dialog(grant: RemoteGrant) -> void:
	_editing = grant
	_key_dialog.title = "New access key" if grant == null else "Access for %s" % grant.name
	_key_dialog.ok_button_text = "Create key" if grant == null else "Save"
	_person_edit.text = grant.name if grant != null else ""
	_role_option.select(grant.role if grant != null else RemoteProtocol.Role.SERVER_ADMIN)
	_role_option.disabled = grant != null
	for child in _server_checks.get_children():
		_server_checks.remove_child(child)
		child.queue_free()
	for inst in ServerManager.get_instances():
		var check := CheckBox.new()
		check.text = inst.config.display_name
		check.tooltip_text = inst.config.directory
		check.set_meta("server_id", inst.config.id)
		check.button_pressed = grant != null and grant.server_ids.has(inst.config.id)
		check.toggled.connect(func(_on: bool) -> void: _update_key_dialog())
		_server_checks.add_child(check)
	if ServerManager.get_instances().is_empty():
		var none := Label.new()
		none.text = "There are no servers on this computer yet."
		none.theme_type_variation = &"MutedLabel"
		_server_checks.add_child(none)
	_update_key_dialog()
	_key_dialog.popup_centered()
	_person_edit.grab_focus.call_deferred()


func _update_key_dialog() -> void:
	var role := _role_option.selected
	_role_hint.text = RemoteProtocol.ROLE_DESCRIPTIONS[role]
	_key_warning.text = ROLE_WARNINGS[role]
	var server_admin := role == RemoteProtocol.Role.SERVER_ADMIN
	_servers_label.visible = server_admin
	_servers_scroll.visible = server_admin
	var ok := _person_edit.text.strip_edges() != "" and (not server_admin or not _chosen_servers().is_empty())
	_key_dialog.get_ok_button().disabled = not ok


func _chosen_servers() -> PackedStringArray:
	var out := PackedStringArray()
	for child in _server_checks.get_children():
		if child is CheckBox and child.button_pressed:
			out.append(str(child.get_meta("server_id")))
	return out


func _save_key() -> void:
	var role := _role_option.selected as RemoteProtocol.Role
	var servers := _chosen_servers() if role == RemoteProtocol.Role.SERVER_ADMIN else PackedStringArray()
	if _editing != null:
		_editing.name = _person_edit.text.strip_edges()
		_editing.server_ids = servers
		RemoteAccess.update_grant(_editing)
		Notifier.success("Updated the access for %s." % _editing.name)
		return
	var grant := RemoteAccess.create_grant(_person_edit.text, role, servers)
	_show_invite(grant)


func _show_invite(grant: RemoteGrant) -> void:
	_invite_dialog.title = "Invite code for %s" % grant.name
	_invite_intro.text = "Send this code to %s privately, e.g. in a direct message. They paste it in Remote access → Connect to others. Anyone who has it can connect as %s." % [grant.name, grant.role_name().to_lower()]
	_invite_text.text = RemoteAccess.invite_for(grant)
	var hints := PackedStringArray()
	var addresses := RemoteAccess.invite_addresses()
	if not addresses.is_empty():
		hints.append("It lists %s, port %d." % [" and ".join(addresses), RemoteAccess.port])
	if not RemoteAccess.enabled:
		hints.append("Remote access is switched off: turn on \"Allow connections\" so they can connect.")
	hints.append("You can copy it again later from the list of keys.")
	_invite_hint.text = " ".join(hints)
	_invite_dialog.popup_centered()


# --- Connect to others -----------------------------------------------------------

func _refresh_links() -> void:
	for child in _link_list.get_children():
		if child is RemoteLinkRow:
			_link_list.remove_child(child)
			child.queue_free()
	for link in RemoteHosts.links():
		var row: RemoteLinkRow = LINK_ROW.instantiate()
		_link_list.add_child(row)
		row.setup(link)
		row.connect_requested.connect(func(l: RemoteLink) -> void: l.connect_now())
		row.disconnect_requested.connect(func(l: RemoteLink) -> void: l.disconnect_now())
		row.address_requested.connect(_open_address)
		row.remove_requested.connect(_confirm_remove_link)
	_no_links_label.visible = RemoteHosts.links().is_empty()


func _refresh_link_rows() -> void:
	for child in _link_list.get_children():
		if child is RemoteLinkRow:
			child.refresh()


func _open_add_link() -> void:
	_code_edit.text = ""
	_address_edit.text = ""
	_add_error.text = ""
	_add_link_dialog.popup_centered()
	_code_edit.grab_focus.call_deferred()


func _add_link() -> void:
	var res := RemoteHosts.add_from_invite(_code_edit.text, _address_edit.text)
	if not res.ok:
		_add_error.text = res.error
		return
	_add_link_dialog.hide()
	Notifier.info("Connecting to %s…" % (res.link as RemoteLink).source_name())


func _open_address(link: RemoteLink) -> void:
	_link_target = link
	_link_address_edit.text = ", ".join(link.addresses)
	_address_dialog.popup_centered()


func _save_address() -> void:
	if _link_target == null:
		return
	var addresses := PackedStringArray()
	for part in _link_address_edit.text.split(",", false):
		if part.strip_edges() != "":
			addresses.append(part.strip_edges())
	if addresses.is_empty():
		Notifier.warn("Enter at least one address.")
		return
	RemoteHosts.set_addresses(_link_target, addresses, _link_target.port)
	_refresh_link_rows()


func _confirm_remove_link(link: RemoteLink) -> void:
	_link_target = link
	_remove_link_dialog.dialog_text = "Remove %s from this list? You can add it again with its invite code. The key stays valid on that computer until its owner revokes it." % link.source_name()
	_remove_link_dialog.popup_centered(Vector2i(480, 0))
