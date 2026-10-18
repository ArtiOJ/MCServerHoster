class_name ImportServerDialog
extends ConfirmationDialog
## Imports a server folder that wasn't created by the manager: pick the folder, review
## what was detected (software, version, port, memory, worlds, running state), choose
## how to import it, then hand it to ServerManager.import_existing_server.

signal imported(instance: ServerInstance)

enum Mode { IN_PLACE, COPY }

var _analysis := {}
var _busy := false
var _serial := 0

@onready var _folder_edit: LineEdit = %FolderEdit
@onready var _browse_button: Button = %BrowseButton
@onready var _software_label: Label = %SoftwareLabel
@onready var _details: GridContainer = %Details
@onready var _version_value: Label = %VersionValue
@onready var _jar_value: Label = %JarValue
@onready var _worlds_value: Label = %WorldsValue
@onready var _plugins_value: Label = %PluginsValue
@onready var _status_value: Label = %StatusValue
@onready var _notice: PanelContainer = %Notice
@onready var _notice_label: Label = %NoticeLabel
@onready var _options: GridContainer = %Options
@onready var _name_edit: LineEdit = %NameEdit
@onready var _mode_option: OptionButton = %ModeOption
@onready var _port_spin: SpinBox = %PortSpin
@onready var _port_status: Label = %PortStatus
@onready var _ram_spin: SpinBox = %RamSpin
@onready var _paper_label: Label = %PaperLabel
@onready var _paper_check: CheckButton = %PaperCheck
@onready var _eula_label: Label = %EulaLabel
@onready var _eula_row: HBoxContainer = %EulaRow
@onready var _eula_check: CheckBox = %EulaCheck
@onready var _mode_hint: Label = %ModeHint
@onready var _progress: ProgressBar = %Progress
@onready var _status: Label = %StatusLabel
@onready var _folder_dialog: FileDialog = %FolderDialog


func _ready() -> void:
	get_ok_button().theme_type_variation = &"AccentButton"
	confirmed.connect(_import)
	_browse_button.pressed.connect(_browse)
	_folder_dialog.dir_selected.connect(func(dir: String) -> void:
		_folder_edit.text = dir
		_analyze(dir))
	_folder_edit.text_submitted.connect(_analyze)
	for sig: Signal in [_name_edit.text_changed, _eula_check.toggled, _paper_check.toggled, _mode_option.item_selected]:
		sig.connect(func(_v: Variant) -> void: _validate())
	_port_spin.value_changed.connect(func(_v: float) -> void: _validate())


## Shows the dialog; with [param dir] the folder is analysed right away.
func open(dir := "") -> void:
	_busy = false
	_analysis = {}
	_folder_edit.text = dir
	_progress.visible = false
	_status.text = ""
	_show_analysis()
	popup_centered()
	if dir != "":
		_analyze(dir)
	else:
		_browse.call_deferred()


func _browse() -> void:
	var current := _folder_edit.text.strip_edges()
	_folder_dialog.current_dir = current if DirAccess.dir_exists_absolute(current) else OS.get_environment("HOME")
	_folder_dialog.popup_centered()


func _analyze(dir: String) -> void:
	dir = dir.strip_edges()
	if dir == "" or _busy:
		return
	_serial += 1
	var serial := _serial
	_analysis = {}
	_software_label.text = "Inspecting %s…" % dir.get_file()
	_show_analysis()
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary: return ServerImporter.analyze(dir))
	if serial != _serial:
		return
	_analysis = result
	_name_edit.text = dir.get_file()
	_port_spin.value = result.port
	_ram_spin.value = result.ram_max_mb if result.ram_max_mb > 0 else AppSettings.default_ram_mb
	_paper_check.button_pressed = true
	_eula_check.button_pressed = false
	_mode_option.select(Mode.IN_PLACE)
	_show_analysis()


func _show_analysis() -> void:
	var a := _analysis
	var ready := not a.is_empty()
	_details.visible = ready and (a.error == "" or a.jar != "")
	_options.visible = ready and a.can_import and not a.managed
	if not ready:
		if _folder_edit.text == "":
			_software_label.text = "No folder selected"
		_notice.visible = false
		_mode_hint.text = ""
		_validate()
		return
	_software_label.text = a.software_name + (" %s" % a.mc_version if a.mc_version != "" else "")
	_version_value.text = "Minecraft %s%s" % [a.mc_version if a.mc_version != "" else "unknown", (", build #%d" % a.build) if a.build > 0 else ""]
	_jar_value.text = a.jar if a.jar != "" else "—"
	_worlds_value.text = ("%s  (%s)" % [", ".join(a.worlds), Fmt.bytes(a.world_bytes)]) if not a.worlds.is_empty() else "none yet"
	_plugins_value.text = str(a.plugins)
	_status_value.text = ("Running (PID %d)" % a.running_pid) if a.running_pid > 0 else "Stopped"
	var lines := PackedStringArray()
	if a.error != "":
		lines.append(a.error)
	if a.managed:
		lines.append("This folder was created by Server Manager; it will simply be added back to the list.")
	lines.append_array(a.warnings)
	_notice.visible = not lines.is_empty()
	_notice_label.text = "\n".join(lines)
	_paper_label.visible = a.needs_paper_switch
	_paper_check.visible = a.needs_paper_switch
	_eula_label.visible = not a.eula_accepted
	_eula_row.visible = not a.eula_accepted
	_mode_option.set_item_disabled(Mode.COPY, a.running_pid > 0)
	_port_spin.editable = a.running_pid <= 0
	_validate()


func _validate() -> void:
	var a := _analysis
	var ok: bool = not a.is_empty() and a.can_import and not _busy
	if ok and not a.managed:
		ok = _name_edit.text.strip_edges() != "" and (a.eula_accepted or _eula_check.button_pressed)
		var port := int(_port_spin.value)
		var clash := ServerManager.port_owner(port)
		if clash != null:
			ok = false
			_port_status.text = "Used by %s — free port: %d" % [clash.config.display_name, ServerManager.allocate_game_port()]
		elif a.running_pid > 0:
			_port_status.text = "In use by this running server"
		else:
			_port_status.text = "" if PlatformBackend.is_port_free(port) else "Another program is listening on this port"
		var copy := _mode_option.selected == Mode.COPY
		_mode_hint.text = ("The folder is copied to %s; the original stays untouched." % AppSettings.servers_root.path_join(Fmt.slugify(_name_edit.text))) if copy \
				else "The server stays where it is. Only a .manager folder is added now; ports and RCON are written to server.properties when Server Manager starts it."
		if a.needs_paper_switch:
			_mode_hint.text += (" Paper %s will be downloaded and used instead of %s." % [a.mc_version, a.jar]) if _paper_check.button_pressed \
					else (" The %s jar is kept; Paper-specific features (updates, Paper settings) may not apply." % a.software_name)
	else:
		_mode_hint.text = ""
	get_ok_button().disabled = not ok
	ok_button_text = "Add" if not a.is_empty() and a.get("managed", false) else "Import"


func _import() -> void:
	if get_ok_button().disabled or _busy:
		return
	var a := _analysis
	_busy = true
	_validate()
	get_cancel_button().disabled = true
	_progress.visible = true
	_progress.value = 0
	var res: Dictionary = await ServerManager.import_existing_server(a.dir, {
		"analysis": a,
		"display_name": _name_edit.text.strip_edges(),
		"mode": "copy" if _mode_option.selected == Mode.COPY else "in_place",
		"port": int(_port_spin.value),
		"ram_max_mb": int(_ram_spin.value),
		"switch_to_paper": a.needs_paper_switch and _paper_check.button_pressed,
		"accept_eula": _eula_check.button_pressed,
	}, func(text: String, fraction: float) -> void:
		_status.text = text
		_progress.value = fraction * 100.0)
	_busy = false
	get_cancel_button().disabled = false
	_progress.visible = false
	if not res.ok:
		_status.text = res.error
		_validate()
		return
	var inst: ServerInstance = res.instance
	Notifier.success("Imported %s." % inst.config.display_name)
	hide()
	imported.emit(inst)
