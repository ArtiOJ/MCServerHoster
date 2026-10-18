class_name Sidebar
extends PanelContainer
## Navigation: dashboard entry, list of servers and global actions.

signal dashboard_selected
signal server_selected(server_id: String)
signal new_server_requested
signal settings_requested

const ITEM_SCENE := preload("res://scenes/sidebar/server_list_item.tscn")

var _group := ButtonGroup.new()

@onready var _dashboard_button: Button = %DashboardButton
@onready var _list: VBoxContainer = %ServerList
@onready var _empty_label: Label = %EmptyLabel
@onready var _new_button: Button = %NewServerButton
@onready var _settings_button: Button = %SettingsButton
@onready var _summary_label: Label = %SummaryLabel


func _ready() -> void:
	_dashboard_button.button_group = _group
	_dashboard_button.pressed.connect(func() -> void: dashboard_selected.emit())
	_new_button.pressed.connect(func() -> void: new_server_requested.emit())
	_settings_button.pressed.connect(func() -> void: settings_requested.emit())
	ServerManager.server_added.connect(_add_item)
	ServerManager.server_removed.connect(_remove_item)
	ServerManager.server_state_changed.connect(_update_summary.unbind(1))
	for inst in ServerManager.get_instances():
		_add_item(inst)
	_update_summary()


## Highlights the entry for [param server_id] ("" for the dashboard) without emitting signals.
func select(server_id: String) -> void:
	if server_id == "":
		_dashboard_button.set_pressed_no_signal(true)
		return
	for item: ServerListItem in _list.get_children():
		if item.instance.config.id == server_id:
			item.set_pressed_no_signal(true)


func _add_item(inst: ServerInstance) -> void:
	var item: ServerListItem = ITEM_SCENE.instantiate()
	item.button_group = _group
	_list.add_child(item)
	item.bind(inst)
	item.pressed.connect(func() -> void: server_selected.emit(inst.config.id))
	_update_summary()


func _remove_item(server_id: String) -> void:
	for item: ServerListItem in _list.get_children():
		if item.instance == null or not is_instance_valid(item.instance) or item.instance.config.id == server_id:
			item.queue_free()
	_update_summary.call_deferred()


func _update_summary() -> void:
	var total := ServerManager.get_instances().size()
	_empty_label.visible = total == 0
	_summary_label.text = "%d of %d running" % [ServerManager.running_count(), total]
