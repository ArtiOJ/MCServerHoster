class_name DuplicateServerDialog
extends ConfirmationDialog
## Copies a server into a new, independent server with its own ports.

signal duplicated(instance: ServerInstance)

var _instance: ServerInstance
var _busy := false

@onready var _name_edit: LineEdit = %NameEdit
@onready var _worlds_check: CheckButton = %WorldsCheck
@onready var _plugins_check: CheckButton = %PluginsCheck
@onready var _info_label: Label = %InfoLabel
@onready var _progress: ProgressBar = %Progress
@onready var _status: Label = %StatusLabel


func _ready() -> void:
	get_ok_button().theme_type_variation = &"AccentButton"
	_name_edit.text_changed.connect(func(_t: String) -> void: _refresh())
	_name_edit.text_submitted.connect(func(_t: String) -> void: _on_confirmed())
	confirmed.connect(_on_confirmed)
	close_requested.connect(_on_close_requested)


func open(inst: ServerInstance) -> void:
	_instance = inst
	_busy = false
	title = "Duplicate %s" % inst.config.display_name
	_name_edit.text = "%s copy" % inst.config.display_name
	_worlds_check.button_pressed = true
	_plugins_check.button_pressed = true
	_progress.visible = false
	_status.text = ""
	_set_enabled(true)
	_refresh()
	popup_centered()
	_name_edit.grab_focus.call_deferred()
	_name_edit.select_all.call_deferred()


func _refresh() -> void:
	if _instance == null:
		return
	var folder := AppSettings.servers_root.path_join(ServerManager.unique_id(_name_edit.text.strip_edges()))
	var lines := PackedStringArray(["Folder: " + folder, "New game and RCON ports are assigned automatically."])
	if _instance.is_online():
		lines.append("The server is running: its worlds are flushed to disk before copying.")
	_info_label.text = "\n".join(lines)
	get_ok_button().disabled = _busy or _name_edit.text.strip_edges().is_empty()


func _on_confirmed() -> void:
	if _busy or _instance == null or _name_edit.text.strip_edges().is_empty():
		return
	_busy = true
	_set_enabled(false)
	_progress.visible = true
	var source := _instance
	var display_name := _name_edit.text.strip_edges()
	var res: Dictionary = await ServerManager.duplicate_server(source, display_name,
			_worlds_check.button_pressed, _plugins_check.button_pressed,
			func(text: String) -> void: _status.text = text)
	_busy = false
	_progress.visible = false
	_set_enabled(true)
	if res.ok:
		Notifier.success("Created %s from %s." % [display_name, source.config.display_name])
		hide()
		duplicated.emit(res.instance)
	else:
		_status.text = res.error
		Notifier.error("Could not duplicate %s: %s" % [source.config.display_name, res.error])


func _on_close_requested() -> void:
	# Closing mid-copy would leave the user without feedback; the copy finishes regardless.
	if _busy:
		show.call_deferred()


func _set_enabled(enabled: bool) -> void:
	_name_edit.editable = enabled
	_worlds_check.disabled = not enabled
	_plugins_check.disabled = not enabled
	get_ok_button().disabled = not enabled
	get_cancel_button().disabled = not enabled
