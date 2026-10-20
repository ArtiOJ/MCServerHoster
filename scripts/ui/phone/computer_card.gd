class_name ComputerCard
extends PanelContainer
## Phone app: one computer you connect to, with its status, a wake button, a menu of what
## you may do there, and the servers it lets you see.

signal server_open_requested(handle_key: String)
signal action_requested(link: RemoteLink, id: int)

enum MenuItem { WAKE, RECONNECT, NEW_SERVER, IMPORT_SERVER, ACCESS_KEYS, PREFERENCES, ADDRESS, REMOVE }

const ITEM_SCENE := preload("res://scenes/sidebar/server_list_item.tscn")
const STATUS_COLORS: Array[Color] = [Color("6b7280"), Color("f2b84b"), Color("3fb97f"), Color("e05555")]

var link: RemoteLink

@onready var _dot: StatusDot = %Dot
@onready var _name_label: Label = %NameLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _wake_button: Button = %WakeButton
@onready var _menu_button: MenuButton = %MenuButton
@onready var _server_list: VBoxContainer = %ServerList
@onready var _empty_label: Label = %EmptyLabel


func _ready() -> void:
	_wake_button.pressed.connect(func() -> void: action_requested.emit(link, MenuItem.WAKE))
	_menu_button.about_to_popup.connect(_fill_menu)
	_menu_button.get_popup().id_pressed.connect(func(id: int) -> void: action_requested.emit(link, id))


func setup(l: RemoteLink) -> void:
	link = l
	link.status_changed.connect(refresh)
	link.server_added.connect(func(_h: ServerHandle) -> void: _fill_servers())
	link.server_removed.connect(func(_k: String) -> void: _fill_servers.call_deferred())
	_fill_servers()
	refresh()


func refresh() -> void:
	if link == null or not is_instance_valid(link) or not is_node_ready():
		return
	_dot.color = STATUS_COLORS[link.status]
	_dot.pulsing = link.status == RemoteLink.Status.CONNECTING or link.is_waking()
	_name_label.text = link.source_name()
	match link.status:
		RemoteLink.Status.ONLINE:
			_detail_label.text = link.status_text()
		RemoteLink.Status.CONNECTING:
			_detail_label.text = "Waking up…" if link.is_waking() else "Connecting…"
		RemoteLink.Status.DENIED:
			_detail_label.text = "Access denied: %s" % link.error
		_:
			_detail_label.text = "Offline" + (": %s" % link.error if link.error != "" else "")
	_wake_button.visible = link.can_wake()
	_wake_button.disabled = link.is_waking()
	_wake_button.text = "Waking…" if link.is_waking() else "Wake"
	_update_empty()


func _fill_servers() -> void:
	for item in _server_list.get_children():
		_server_list.remove_child(item)
		item.queue_free()
	var servers := link.remote_servers()
	servers.sort_custom(func(a: RemoteServer, b: RemoteServer) -> bool:
		return a.config.display_name.naturalnocasecmp_to(b.config.display_name) < 0)
	for server in servers:
		var item: ServerListItem = ITEM_SCENE.instantiate()
		item.toggle_mode = false
		_server_list.add_child(item)
		item.bind(server)
		var item_key := server.key()
		item.pressed.connect(func() -> void: server_open_requested.emit(item_key))
	_update_empty()


func _update_empty() -> void:
	var online := link.status == RemoteLink.Status.ONLINE
	_empty_label.visible = online and _server_list.get_child_count() == 0
	_empty_label.text = "No servers yet. Use the menu to create one." if link.can_manage_servers() \
			else "This key doesn't open any servers."


func _fill_menu() -> void:
	var menu := _menu_button.get_popup()
	menu.clear()
	var online := link.status == RemoteLink.Status.ONLINE
	var active := online or link.status == RemoteLink.Status.CONNECTING
	if link.can_wake():
		menu.add_item("Wake computer", MenuItem.WAKE)
	menu.add_item("Disconnect" if active else "Reconnect", MenuItem.RECONNECT)
	if link.can_manage_servers():
		menu.add_separator()
		menu.add_item("New server…", MenuItem.NEW_SERVER)
		menu.add_item("Import server…", MenuItem.IMPORT_SERVER)
		menu.add_item("Access keys…", MenuItem.ACCESS_KEYS)
		menu.add_item("Preferences…", MenuItem.PREFERENCES)
	menu.add_separator()
	menu.add_item("Change address…", MenuItem.ADDRESS)
	menu.add_item("Remove", MenuItem.REMOVE)
