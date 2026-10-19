class_name ServerView
extends VBoxContainer
## Detail view for one server: header with controls plus tabbed panels.
## Switching servers re-binds every tab to the new ServerInstance.

signal update_requested(instance: ServerInstance)
signal delete_requested(instance: ServerInstance)
signal duplicate_requested(instance: ServerInstance)
signal temp_decision_requested(instance: ServerInstance)
signal import_world_requested(instance: ServerInstance)

## Tab node name -> icon (matched by name so tabs can be reordered or added freely).
const TAB_ICONS := {
	"Overview": preload("res://assets/icons/activity.svg"),
	"Console": preload("res://assets/icons/terminal.svg"),
	"Logs": preload("res://assets/icons/log.svg"),
	"Settings": preload("res://assets/icons/settings.svg"),
	"Resources": preload("res://assets/icons/sliders.svg"),
	"Automation": preload("res://assets/icons/clock.svg"),
	"Players": preload("res://assets/icons/users.svg"),
	"Plugins": preload("res://assets/icons/puzzle.svg"),
	"Worlds": preload("res://assets/icons/map.svg"),
	"Backups": preload("res://assets/icons/archive.svg"),
	"Network": preload("res://assets/icons/globe.svg"),
}

var instance: ServerInstance

@onready var _header: ServerHeader = %Header
@onready var _tabs: TabContainer = %Tabs
@onready var _console: ConsoleTab = %Console
@onready var _plugins: PluginsTab = %Plugins


func _ready() -> void:
	for tab in _tabs.get_children():
		if TAB_ICONS.has(str(tab.name)):
			_tabs.set_tab_icon(tab.get_index(), TAB_ICONS[str(tab.name)])
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
