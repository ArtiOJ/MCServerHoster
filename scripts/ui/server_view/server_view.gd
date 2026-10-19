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
var _fitting := false

@onready var _header: ServerHeader = %Header
@onready var _tabs: TabContainer = %Tabs
@onready var _console: ConsoleTab = %Console
@onready var _plugins: PluginsTab = %Plugins


func _ready() -> void:
	for tab in _tabs.get_children():
		if TAB_ICONS.has(str(tab.name)):
			_tabs.set_tab_icon(tab.get_index(), TAB_ICONS[str(tab.name)])
		_tabs.set_tab_tooltip(tab.get_index(), str(tab.name))
	_tabs.resized.connect(_fit_tabs)
	_fit_tabs.call_deferred()
	_header.update_requested.connect(func() -> void: update_requested.emit(instance))
	_header.delete_requested.connect(func() -> void: delete_requested.emit(instance))
	_header.duplicate_requested.connect(func() -> void: duplicate_requested.emit(instance))
	_header.temp_decision_requested.connect(func() -> void: temp_decision_requested.emit(instance))
	_header.import_world_requested.connect(func() -> void: import_world_requested.emit(instance))


## Shows tab titles when they fit, otherwise icons only (names stay in the tooltips), so
## no tab ends up hidden behind the scroll arrows in narrow windows. Tries titles first and
## falls back once the tab bar reports that it needs its scroll arrows.
func _fit_tabs() -> void:
	if _fitting:
		return
	_fitting = true
	_set_tab_titles(true)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_tabs) and _tabs.get_tab_bar().get_offset_buttons_visible():
		_set_tab_titles(false)
	_fitting = false


func _set_tab_titles(show: bool) -> void:
	for i in _tabs.get_tab_count():
		_tabs.set_tab_title(i, str(_tabs.get_child(i).name) if show else "")


func show_instance(inst: ServerInstance) -> void:
	instance = inst
	_header.bind(inst)
	for tab in _tabs.get_children():
		if tab is ServerTab:
			tab.bind(inst)


func focus_console() -> void:
	_tabs.current_tab = _console.get_index()
	_console.focus_input.call_deferred()


func open_icon_editor(path := "") -> void:
	_header.open_icon_editor(path)


func is_icon_editor_open() -> bool:
	return _header.is_icon_editor_open()


func handle_files_dropped(files: PackedStringArray) -> void:
	_tabs.current_tab = _plugins.get_index()
	_plugins.install_files(files)
