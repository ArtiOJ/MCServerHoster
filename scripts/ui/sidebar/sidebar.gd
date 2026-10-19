class_name Sidebar
extends PanelContainer
## Navigation: which computer is shown (this one, or one you are system admin of), its
## servers, servers on other computers you were given access to, and global actions.

signal dashboard_selected
signal server_selected(handle_key: String)
signal source_selected(source: ServerSource)
signal new_server_requested
signal import_server_requested
signal settings_requested
signal remote_requested

const ITEM_SCENE := preload("res://scenes/sidebar/server_list_item.tscn")

var _group := ButtonGroup.new()
var _source: ServerSource

@onready var _host_option: OptionButton = %HostOption
@onready var _dashboard_button: Button = %DashboardButton
@onready var _caption: Label = %Caption
@onready var _list: VBoxContainer = %ServerList
@onready var _remote_caption: Label = %RemoteCaption
@onready var _remote_list: VBoxContainer = %RemoteList
@onready var _empty_label: Label = %EmptyLabel
@onready var _new_button: Button = %NewServerButton
@onready var _import_button: Button = %ImportServerButton
@onready var _remote_button: Button = %RemoteButton
@onready var _settings_button: Button = %SettingsButton
@onready var _summary_label: Label = %SummaryLabel


func _ready() -> void:
	_dashboard_button.button_group = _group
	_dashboard_button.pressed.connect(func() -> void: dashboard_selected.emit())
	_new_button.pressed.connect(func() -> void: new_server_requested.emit())
	_import_button.pressed.connect(func() -> void: import_server_requested.emit())
	_remote_button.pressed.connect(func() -> void: remote_requested.emit())
	_settings_button.pressed.connect(func() -> void: settings_requested.emit())
	_host_option.item_selected.connect(_on_host_selected)
	RemoteHosts.links_changed.connect(_refresh_hosts)
	RemoteHosts.link_status_changed.connect(func(_l: RemoteLink) -> void:
		_refresh_hosts()
		_refresh_remote_section())
	RemoteHosts.server_added.connect(_on_remote_server_added)
	RemoteHosts.server_removed.connect(_remove_item)
	for server in RemoteHosts.server_admin_servers():
		_on_remote_server_added(server)
	show_source(ServerManager)
	_refresh_hosts()


## Lists the servers of [param source] in the main section.
func show_source(source: ServerSource) -> void:
	if _source != null:
		_source.server_added.disconnect(_add_item)
		_source.server_removed.disconnect(_remove_item)
		_source.server_state_changed.disconnect(_on_state_changed)
	_source = source
	_source.server_added.connect(_add_item)
	_source.server_removed.connect(_remove_item)
	_source.server_state_changed.connect(_on_state_changed)
	for item in _list.get_children():
		_list.remove_child(item)
		item.queue_free()
	for h in source.get_handles():
		_add_item(h)
	var remote := source.is_remote_source()
	_caption.text = "SERVERS ON %s" % source.source_name().to_upper() if remote else "SERVERS"
	_import_button.visible = not remote
	_update_actions()
	_select_host_item()
	_update_summary()


## Highlights the entry for [param handle_key] ("" for the dashboard) without emitting signals.
func select(handle_key: String) -> void:
	if handle_key == "":
		_dashboard_button.set_pressed_no_signal(true)
		return
	for list in [_list, _remote_list]:
		for item: ServerListItem in list.get_children():
			if is_instance_valid(item.instance) and item.instance.key() == handle_key:
				item.set_pressed_no_signal(true)


func _add_item(handle: ServerHandle, list: VBoxContainer = null) -> void:
	var target := list if list != null else _list
	var item: ServerListItem = ITEM_SCENE.instantiate()
	item.button_group = _group
	item.show_host = target == _remote_list
	target.add_child(item)
	item.bind(handle)
	var item_key := handle.key()
	item.pressed.connect(func() -> void: server_selected.emit(item_key))
	_update_summary()


func _remove_item(handle_key: String) -> void:
	for list in [_list, _remote_list]:
		for item: ServerListItem in list.get_children():
			if item.instance == null or not is_instance_valid(item.instance) or item.instance.key() == handle_key:
				list.remove_child(item)
				item.queue_free()
	_refresh_remote_section()
	_update_summary.call_deferred()


func _on_state_changed(_handle: ServerHandle) -> void:
	_update_summary()


func _update_summary() -> void:
	var total := _source.get_handles().size()
	_empty_label.visible = total == 0
	_empty_label.text = "No servers yet." if not _source.is_remote_source() else "No servers on %s." % _source.source_name()
	_summary_label.text = "%d of %d running" % [_source.running_count(), total]


func _update_actions() -> void:
	_new_button.disabled = not _source.can_manage_servers()
	_new_button.tooltip_text = "Create a new Paper server (Ctrl+N)" if not _source.is_remote_source() \
			else "Create a new Paper server on %s" % _source.source_name()


# --- Servers on other computers --------------------------------------------------

## Servers opened by server-admin keys go to the "Remote servers" section; computers you
## are system admin of are reached through the computer switcher instead.
func _on_remote_server_added(server: RemoteServer) -> void:
	if server.link.role == RemoteProtocol.Role.SYSTEM_ADMIN:
		return
	for item: ServerListItem in _remote_list.get_children():
		if item.instance == server:
			return
	_add_item(server, _remote_list)
	_refresh_remote_section()


func _refresh_remote_section() -> void:
	_remote_caption.visible = _remote_list.get_child_count() > 0
	_update_actions()


# --- Computer switcher -------------------------------------------------------------

func _refresh_hosts() -> void:
	var links := RemoteHosts.system_admin_links()
	_host_option.clear()
	_host_option.add_item("This computer")
	_host_option.set_item_metadata(0, "")
	for link in links:
		var label := link.source_name() + ("" if link.is_online() else "  (offline)")
		_host_option.add_item(label)
		_host_option.set_item_metadata(_host_option.item_count - 1, link.link_id)
	_host_option.visible = not links.is_empty() or _source.is_remote_source()
	_select_host_item()
	# The computer being shown was removed from the list: go back to this one.
	if _source != ServerManager and not RemoteHosts.links().has(_source):
		source_selected.emit(ServerManager)
	_update_actions()


func _select_host_item() -> void:
	var wanted := (_source as RemoteLink).link_id if _source is RemoteLink else ""
	for i in _host_option.item_count:
		if str(_host_option.get_item_metadata(i)) == wanted:
			_host_option.select(i)


func _on_host_selected(index: int) -> void:
	var link_id := str(_host_option.get_item_metadata(index))
	var source: ServerSource = ServerManager if link_id == "" else RemoteHosts.find_link(link_id)
	if source != null and source != _source:
		source_selected.emit(source)
