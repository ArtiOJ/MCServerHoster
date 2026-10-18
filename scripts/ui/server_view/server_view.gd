class_name ServerView
extends VBoxContainer
## Detail view for one server: header with controls plus tabbed panels.
## Switching servers re-binds every tab to the new ServerInstance.

signal update_requested(instance: ServerInstance)
signal delete_requested(instance: ServerInstance)
signal duplicate_requested(instance: ServerInstance)
signal temp_decision_requested(instance: ServerInstance)
signal import_world_requested(instance: ServerInstance)

const TAB_ICONS: Array[Texture2D] = [
	preload("res://assets/icons/activity.svg"),
	preload("res://assets/icons/terminal.svg"),
	preload("res://assets/icons/settings.svg"),
	preload("res://assets/icons/sliders.svg"),
	preload("res://assets/icons/clock.svg"),
	preload("res://assets/icons/users.svg"),
	preload("res://assets/icons/puzzle.svg"),
	preload("res://assets/icons/archive.svg"),
	preload("res://assets/icons/globe.svg"),
]

var instance: ServerInstance

@onready var _header: ServerHeader = %Header
@onready var _tabs: TabContainer = %Tabs
@onready var _console: ConsoleTab = %Console
@onready var _plugins: PluginsTab = %Plugins


func _ready() -> void:
	for i in mini(TAB_ICONS.size(), _tabs.get_tab_count()):
		_tabs.set_tab_icon(i, TAB_ICONS[i])
	_header.update_requested.connect(func() -> void: update_requested.emit(instance))
	_header.delete_requested.connect(func() -> void: delete_requested.emit(instance))
	_header.duplicate_requested.connect(func() -> void: duplicate_requested.emit(instance))
	_header.temp_decision_requested.connect(func() -> void: temp_decision_requested.emit(instance))
	_header.import_world_requested.connect(func() -> void: import_world_requested.emit(instance))


func show_instance(inst: ServerInstance) -> void:
	instance = inst
	_header.bind(inst)
	for tab in _tabs.get_children():
		if tab is ServerTab:
			tab.bind(inst)


func focus_console() -> void:
	_tabs.current_tab = _console.get_index()
	_console.focus_input.call_deferred()


func handle_files_dropped(files: PackedStringArray) -> void:
	_tabs.current_tab = _plugins.get_index()
	_plugins.install_files(files)
