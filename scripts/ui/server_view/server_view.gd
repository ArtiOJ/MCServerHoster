class_name ServerView
extends VBoxContainer
## Detail view for one server: header with controls plus tabbed panels.
## Switching servers re-binds every tab; for a server on another computer, tabs that
## cannot show it yet are hidden.

signal update_requested(handle: ServerHandle)
signal delete_requested(handle: ServerHandle)
signal duplicate_requested(handle: ServerHandle)
signal temp_decision_requested(handle: ServerHandle)
signal import_world_requested(handle: ServerHandle)

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

var instance: ServerHandle
var _fitting := false
## Phone layout: the tabs are picked from a strip of buttons that scrolls sideways.
var _strip: HBoxContainer
var _strip_group := ButtonGroup.new()

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


## Phone layout: the header buttons get their own row, and the tab bar becomes a strip
## of buttons that scrolls sideways (titles always shown, since a touch screen has no
## hover to reveal them).
func use_phone_layout() -> void:
	if _strip != null:
		return
	_header.use_two_rows()
	_tabs.tabs_visible = false
	_tabs.resized.disconnect(_fit_tabs)
	var scroll := ScrollContainer.new()
	scroll.name = "TabStrip"
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_strip = HBoxContainer.new()
	_strip.add_theme_constant_override("separation", 4)
	scroll.add_child(_strip)
	add_child(scroll)
	move_child(scroll, _tabs.get_index())
	for tab in _tabs.get_children():
		var button := Button.new()
		button.toggle_mode = true
		button.button_group = _strip_group
		button.theme_type_variation = &"SidebarItem"
		button.text = str(tab.name)
		button.icon = TAB_ICONS.get(str(tab.name))
		button.custom_minimum_size.y = 40
		button.focus_mode = Control.FOCUS_NONE
		var index: int = tab.get_index()
		button.pressed.connect(func() -> void: _tabs.current_tab = index)
		_strip.add_child(button)
	_tabs.tab_changed.connect(_sync_strip.unbind(1))
	_sync_strip()


func _sync_strip() -> void:
	if _strip == null:
		return
	for i in _strip.get_child_count():
		var button := _strip.get_child(i) as Button
		button.visible = not _tabs.is_tab_hidden(i)
		button.set_pressed_no_signal(i == _tabs.current_tab)
	_scroll_strip_to_current()


## Scrolls the strip so the current tab's button shows (once the buttons have their sizes).
func _scroll_strip_to_current() -> void:
	var tree := get_tree()
	await tree.process_frame
	await tree.process_frame
	if not is_inside_tree():
		return
	var current := _strip.get_child(_tabs.current_tab) as Control
	if current != null and current.is_visible_in_tree():
		(_strip.get_parent() as ScrollContainer).ensure_control_visible(current)


## Shows tab titles when they fit, otherwise icons only (names stay in the tooltips), so
## no tab ends up hidden behind the scroll arrows in narrow windows. Tries titles first and
## falls back once the tab bar reports that it needs its scroll arrows.
func _fit_tabs() -> void:
	if _fitting or _strip != null or not is_inside_tree():
		return
	_fitting = true
	_set_tab_titles(true)
	var tree := get_tree()
	await tree.process_frame
	await tree.process_frame
	if is_inside_tree() and _tabs.get_tab_bar().get_offset_buttons_visible():
		_set_tab_titles(false)
	_fitting = false


func _set_tab_titles(show: bool) -> void:
	for i in _tabs.get_tab_count():
		_tabs.set_tab_title(i, str(_tabs.get_child(i).name) if show else "")


func show_instance(inst: ServerHandle) -> void:
	instance = inst
	_header.bind(inst)
	for tab in _tabs.get_children():
		if tab is ServerTab:
			var shown: bool = tab.bind(inst)
			_tabs.set_tab_hidden(tab.get_index(), not shown)
	if _tabs.is_tab_hidden(_tabs.current_tab):
		_tabs.current_tab = 0
	_fit_tabs.call_deferred()
	_sync_strip()




## The tab container (the phone app opens tabs by name).
func tabs() -> TabContainer:
	return _tabs


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
