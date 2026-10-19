class_name ImportWorldDialog
extends ConfirmationDialog
## Imports a downloaded map, singleplayer save or another server's world into a
## server: analyses it, shows what was found, then formats and copies it in. A world for
## a server on another computer is uploaded there first (folders as a zip).

signal imported(handle: ServerHandle)

## Index of "Add as dimension of current world" in the mode list.
const MODE_DIMENSION := 2

var _instance: ServerHandle
## What the server reported about the chosen world (see ServerOps.world_import_analyze).
var _analysis := {}
var _busy := false
## Ignores results of an analysis that was superseded by a newer choice.
var _serial := 0

@onready var _zip_button: Button = %ChooseZipButton
@onready var _folder_button: Button = %ChooseFolderButton
@onready var _source_label: Label = %SourceLabel
@onready var _running_notice: PanelContainer = %RunningNotice
@onready var _stop_button: Button = %StopButton
@onready var _card: PanelContainer = %AnalysisCard
@onready var _world_name: Label = %WorldName
@onready var _version_value: Label = %VersionValue
@onready var _layout_value: Label = %LayoutValue
@onready var _dimensions_value: Label = %DimensionsValue
@onready var _settings_value: Label = %SettingsValue
@onready var _size_value: Label = %SizeValue
@onready var _warnings: PanelContainer = %Warnings
@onready var _warnings_label: Label = %WarningsLabel
@onready var _options: GridContainer = %Options
@onready var _mode_option: OptionButton = %ModeOption
@onready var _dimension_label: Label = %DimensionLabel
@onready var _dimension_option: OptionButton = %DimensionOption
@onready var _apply_check: CheckButton = %ApplyCheck
@onready var _progress: ProgressBar = %Progress
@onready var _status: Label = %StatusLabel
@onready var _zip_dialog: FileDialog = %ZipDialog
@onready var _folder_dialog: FileDialog = %FolderDialog


func _ready() -> void:
	get_ok_button().theme_type_variation = &"AccentButton"
	_zip_button.pressed.connect(func() -> void: _zip_dialog.popup_centered())
	_folder_button.pressed.connect(func() -> void: _folder_dialog.popup_centered())
	_zip_dialog.file_selected.connect(_analyze)
	_folder_dialog.dir_selected.connect(_analyze)
	_mode_option.item_selected.connect(_on_mode_selected)
	_stop_button.pressed.connect(func() -> void:
		if _instance != null:
			_instance.stop())
	confirmed.connect(_on_confirmed)
	canceled.connect(_discard)
	close_requested.connect(_discard)
	visibility_changed.connect(func() -> void:
		if not visible:
			_unwatch())


## Shows the dialog for [param inst]; [param source] (a .zip or folder) is analysed right away.
func open(inst: ServerHandle, source := "") -> void:
	_unwatch()
	_discard()
	_instance = inst
	_instance.state_changed.connect(_on_state_changed)
	title = "Import world into %s" % inst.config.display_name
	_busy = false
	_source_label.text = "No world chosen"
	_card.visible = false
	_warnings.visible = false
	_options.visible = false
	_progress.visible = false
	_status.text = ""
	_mode_option.select(0)
	_set_buttons_enabled(true)
	_update_ok()
	popup_centered()
	if source != "":
		_analyze(source)


func _analyze(path: String) -> void:
	_serial += 1
	var serial := _serial
	_discard_analysis()
	_source_label.text = path
	_source_label.tooltip_text = path
	_card.visible = false
	_warnings.visible = false
	_options.visible = false
	_progress.visible = true
	_progress.value = 0.0
	_status.text = "Reading the world…" if not _instance.is_remote() else "Sending the world to %s…" % _instance.host_name()
	_update_ok()
	var h := _instance
	var result: Dictionary = await h.call_op("world_import_analyze", {"files": [path]}, func(text: String, fraction: float) -> void:
		if serial == _serial:
			_status.text = text
			if fraction >= 0.0:
				_progress.value = fraction * 100.0)
	if serial != _serial or not visible or h != _instance:
		if result.has("token"):
			h.call_op("world_import_cancel", {"token": result.token})
		return
	_progress.visible = false
	if not result.ok:
		_status.text = str(result.error)
		return
	_analysis = result
	_show_analysis(result)


func _show_analysis(a: Dictionary) -> void:
	_status.text = ""
	_card.visible = a.found
	_world_name.text = a.display_name
	_version_value.text = ("Minecraft %s" % a.version) if a.version != "" else "Unknown"
	_layout_value.text = a.layout_name
	_dimensions_value.text = ", ".join(PackedStringArray(a.dimensions)) if not a.dimensions.is_empty() else "None generated yet"
	var settings := PackedStringArray()
	if a.game_mode != "":
		settings.append(a.game_mode.capitalize())
	if a.difficulty != "":
		settings.append(a.difficulty.capitalize())
	if a.hardcore:
		settings.append("Hardcore")
	_settings_value.text = ", ".join(settings) if not settings.is_empty() else "—"
	_size_value.text = Fmt.bytes(float(a.size_bytes))
	var notes := PackedStringArray()
	if a.error != "":
		notes.append("✕ " + a.error)
	for w in a.warnings:
		notes.append("• " + w)
	_warnings.visible = not notes.is_empty()
	_warnings_label.text = "\n".join(notes)
	_options.visible = a.valid
	var single: bool = a.get("single_dimension", false)
	var choices: Array = a.get("dimension_choices", [])
	_dimension_option.clear()
	for label in choices:
		_dimension_option.add_item(str(label))
	_mode_option.set_item_disabled(MODE_DIMENSION, choices.is_empty())
	_mode_option.select(MODE_DIMENSION if single and not choices.is_empty() else 0)
	_apply_check.button_pressed = not single and (a.game_mode in ["adventure", "creative"] or a.hardcore)
	_on_mode_selected(_mode_option.selected)
	_update_ok()


## Map settings belong to a whole world; an added dimension keeps the current world's.
func _on_mode_selected(index: int) -> void:
	_dimension_label.visible = index == MODE_DIMENSION
	_dimension_option.visible = index == MODE_DIMENSION
	_apply_check.disabled = _busy or index == MODE_DIMENSION
	if index == MODE_DIMENSION:
		_apply_check.button_pressed = false


func _on_confirmed() -> void:
	if _busy or not _analysis.get("valid", false) or _instance == null:
		return
	if _instance.is_process_alive():
		_status.text = "Stop the server first."
		return
	_busy = true
	_set_buttons_enabled(false)
	_progress.visible = true
	_progress.value = 0.0
	var mode: WorldImporter.Mode = [WorldImporter.Mode.REPLACE, WorldImporter.Mode.ADD, WorldImporter.Mode.DIMENSION][_mode_option.selected]
	var result: Dictionary = await _instance.call_op("world_import", {"token": _analysis.token, "mode": mode, "apply": _apply_check.button_pressed,
			"dimension": maxi(_dimension_option.selected, 0)},
			func(text: String, _f: float) -> void: _status.text = text)
	_busy = false
	_progress.visible = false
	_set_buttons_enabled(true)
	if result.ok and str(result.get("dimension", "")) != "":
		DisplayServer.clipboard_set(str(result.command).trim_prefix("/"))
		Notifier.success("Added dimension %s to %s. Teleport command copied: %s" % [result.dimension, _instance.config.display_name, result.command])
		_analysis = {}
		imported.emit(_instance)
		hide()
	elif result.ok:
		Notifier.success("Imported \"%s\" into %s." % [_analysis.display_name, _instance.config.display_name])
		_analysis = {}
		imported.emit(_instance)
		hide()
	else:
		_status.text = result.error
		_analysis["valid"] = false
		_update_ok()


func _discard() -> void:
	_serial += 1
	if not _busy:
		_discard_analysis()


## Lets the server delete what it unpacked for the analysis.
func _discard_analysis() -> void:
	if _analysis.has("token") and _instance != null and is_instance_valid(_instance):
		_instance.call_op("world_import_cancel", {"token": _analysis.token})
	_analysis = {}


func _on_state_changed(_state: ServerHandle.State) -> void:
	_update_ok()


func _unwatch() -> void:
	if _instance != null and is_instance_valid(_instance) and _instance.state_changed.is_connected(_on_state_changed):
		_instance.state_changed.disconnect(_on_state_changed)


func _update_ok() -> void:
	var running := _instance != null and (_instance.is_process_alive() or _instance.state == ServerHandle.State.INSTALLING)
	_running_notice.visible = running and not _busy
	get_ok_button().disabled = _busy or running or not _analysis.get("valid", false)


func _set_buttons_enabled(enabled: bool) -> void:
	_zip_button.disabled = not enabled
	_folder_button.disabled = not enabled
	_mode_option.disabled = not enabled
	_dimension_option.disabled = not enabled
	_apply_check.disabled = not enabled or _mode_option.selected == MODE_DIMENSION
	get_cancel_button().disabled = not enabled
	_update_ok()
