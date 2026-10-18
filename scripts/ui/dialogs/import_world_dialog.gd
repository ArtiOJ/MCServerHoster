class_name ImportWorldDialog
extends ConfirmationDialog
## Imports a downloaded map, singleplayer save or another server's world into a
## server: analyses it, shows what was found, then formats and copies it in.

signal imported(instance: ServerInstance)

var _instance: ServerInstance
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
func open(inst: ServerInstance, source := "") -> void:
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
	WorldImporter.cleanup(_analysis)
	_analysis = {}
	_source_label.text = path
	_source_label.tooltip_text = path
	_card.visible = false
	_warnings.visible = false
	_options.visible = false
	_progress.visible = true
	_status.text = "Reading the world…"
	_update_ok()
	var result: Dictionary = await WorldImporter.analyze(self, path, _instance.config.mc_version)
	if serial != _serial or not visible:
		WorldImporter.cleanup(result)
		return
	_analysis = result
	_progress.visible = false
	_show_analysis(result)


func _show_analysis(a: Dictionary) -> void:
	_status.text = ""
	_card.visible = a.world_dir != ""
	_world_name.text = WorldImporter.display_name(a)
	_version_value.text = ("Minecraft %s" % a.version) if a.version != "" else "Unknown"
	_layout_value.text = WorldImporter.LAYOUT_NAMES[a.layout]
	_dimensions_value.text = ", ".join(a.dimensions) if not a.dimensions.is_empty() else "None generated yet"
	var settings := PackedStringArray()
	if a.game_mode != "":
		settings.append(a.game_mode.capitalize())
	if a.difficulty != "":
		settings.append(a.difficulty.capitalize())
	if a.hardcore:
		settings.append("Hardcore")
	_settings_value.text = ", ".join(settings) if not settings.is_empty() else "—"
	_size_value.text = Fmt.bytes(a.size_bytes)
	var notes := PackedStringArray()
	if a.error != "":
		notes.append("✕ " + a.error)
	for w in a.warnings:
		notes.append("• " + w)
	_warnings.visible = not notes.is_empty()
	_warnings_label.text = "\n".join(notes)
	_options.visible = a.ok
	_apply_check.button_pressed = a.game_mode in ["adventure", "creative"] or a.hardcore
	_update_ok()


func _on_confirmed() -> void:
	if _busy or not _analysis.get("ok", false) or _instance == null:
		return
	if _instance.is_process_alive():
		_status.text = "Stop the server first."
		return
	_busy = true
	_set_buttons_enabled(false)
	_progress.visible = true
	var mode := WorldImporter.Mode.ADD if _mode_option.selected == 1 else WorldImporter.Mode.REPLACE
	var result: Dictionary = await WorldImporter.import_into(_instance, _analysis, mode, _apply_check.button_pressed,
			func(text: String) -> void: _status.text = text)
	WorldImporter.cleanup(_analysis)
	_busy = false
	_progress.visible = false
	_set_buttons_enabled(true)
	if result.ok:
		Notifier.success("Imported \"%s\" into %s." % [WorldImporter.display_name(_analysis), _instance.config.display_name])
		_analysis = {}
		imported.emit(_instance)
		hide()
	else:
		_status.text = result.error
		_analysis["ok"] = false
		_update_ok()


func _discard() -> void:
	_serial += 1
	if not _busy:
		WorldImporter.cleanup(_analysis)
		_analysis = {}


func _on_state_changed(_state: ServerInstance.State) -> void:
	_update_ok()


func _unwatch() -> void:
	if _instance != null and is_instance_valid(_instance) and _instance.state_changed.is_connected(_on_state_changed):
		_instance.state_changed.disconnect(_on_state_changed)


func _update_ok() -> void:
	var running := _instance != null and (_instance.is_process_alive() or _instance.state == ServerInstance.State.INSTALLING)
	_running_notice.visible = running and not _busy
	get_ok_button().disabled = _busy or running or not _analysis.get("ok", false)


func _set_buttons_enabled(enabled: bool) -> void:
	_zip_button.disabled = not enabled
	_folder_button.disabled = not enabled
	_mode_option.disabled = not enabled
	_apply_check.disabled = not enabled
	get_cancel_button().disabled = not enabled
	_update_ok()
