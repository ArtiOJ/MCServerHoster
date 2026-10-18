class_name UpdateDialog
extends ConfirmationDialog
## Updates a server to the newest Paper build, or moves it to another Minecraft
## version, optionally backing up the world first.

var _instance: ServerInstance
var _build := {}
var _info := {}
var _serial := 0
var _busy := false

@onready var _current_label: Label = %CurrentLabel
@onready var _version_option: OptionButton = %VersionOption
@onready var _show_pre: CheckBox = %ShowPreCheck
@onready var _build_label: Label = %BuildLabel
@onready var _warning: PanelContainer = %Warning
@onready var _warning_label: Label = %WarningLabel
@onready var _backup_check: CheckBox = %BackupCheck
@onready var _progress: ProgressBar = %Progress
@onready var _status: Label = %StatusLabel


func _ready() -> void:
	get_ok_button().theme_type_variation = &"AccentButton"
	_version_option.item_selected.connect(func(_i: int) -> void: _on_version_selected())
	_show_pre.toggled.connect(func(_on: bool) -> void: _populate())
	confirmed.connect(_on_confirmed)
	canceled.connect(func() -> void: _serial += 1)


func open(inst: ServerInstance) -> void:
	_instance = inst
	_busy = false
	_build = {}
	title = "Update %s" % inst.config.display_name
	_current_label.text = "Installed: Paper %s, build #%d" % [inst.config.mc_version, inst.config.paper_build]
	_progress.visible = false
	_status.text = ""
	_backup_check.button_pressed = true
	_set_controls_enabled(true)
	get_ok_button().disabled = true
	popup_centered()
	_populate()


func _populate() -> void:
	_version_option.clear()
	_version_option.add_item("Loading…")
	var res: Dictionary = await PaperApi.fetch_versions()
	_version_option.clear()
	if not res.ok:
		_build_label.text = "Could not load versions: %s" % res.error
		return
	var current := _instance.config.mc_version
	for v in res.versions:
		if v.prerelease and not _show_pre.button_pressed and v.id != current:
			continue
		_version_option.add_item(v.id + ("  (installed)" if v.id == current else ""))
		_version_option.set_item_metadata(_version_option.item_count - 1, v.id)
		if v.id == current:
			_version_option.select(_version_option.item_count - 1)
	_on_version_selected()


func _selected_version() -> String:
	return str(_version_option.get_selected_metadata()) if _version_option.selected >= 0 else ""


func _on_version_selected() -> void:
	var version := _selected_version()
	if version == "":
		return
	_serial += 1
	var serial := _serial
	_build = {}
	get_ok_button().disabled = true
	_build_label.text = "Checking Paper %s…" % version
	var info: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version, true)
	if serial != _serial:
		return
	if not info.ok or not latest.ok:
		_build_label.text = "Could not load %s: %s" % [version, info.get("error", latest.get("error", "unknown error"))]
		return
	_info = info
	_build = latest.build
	var same_version := version == _instance.config.mc_version
	var up_to_date := same_version and int(_build.id) <= _instance.config.paper_build
	_build_label.text = "Latest: build #%d (%s), requires Java %d+" % [_build.id, str(_build.channel).to_lower(), info.java_min]
	if up_to_date:
		_build_label.text += " — already installed."
	var warnings := PackedStringArray()
	if not same_version:
		var cmp := compare_versions(version, _instance.config.mc_version)
		if cmp < 0:
			warnings.append("Downgrading Minecraft is not supported and can corrupt worlds. Only continue if you will restore an older backup.")
		else:
			warnings.append("Worlds are upgraded on first start and cannot be opened by %s afterwards. Plugins may need updates." % _instance.config.mc_version)
	if JavaRuntimes.best_for(info.java_min) == null:
		warnings.append("Java %d+ is required but not installed." % info.java_min)
	if _build.channel != "STABLE":
		warnings.append("This is an experimental build.")
	_warning.visible = not warnings.is_empty()
	_warning_label.text = "\n".join(warnings)
	ok_button_text = "Install build #%d" % _build.id if same_version else "Switch to %s" % version
	get_ok_button().disabled = up_to_date


func _on_confirmed() -> void:
	if _busy or _build.is_empty() or _instance == null:
		return
	if _instance.is_busy():
		_status.text = "Stop the server first."
		return
	_busy = true
	_set_controls_enabled(false)
	_progress.visible = true
	_progress.value = 0
	var inst := _instance
	if _backup_check.button_pressed and not inst.backups.world_dirs().is_empty():
		_status.text = "Backing up worlds…"
		var path: String = await inst.backups.create_backup(false)
		if path == "":
			_status.text = "Backup failed; update cancelled."
			_busy = false
			_set_controls_enabled(true)
			return
	_status.text = "Downloading…"
	var res: Dictionary = await inst.install_build(_selected_version(), _build, _info, func(done: int, total: int) -> void:
		_progress.value = 100.0 * done / maxf(total, 1.0)
		_status.text = "Downloading… %s / %s" % [Fmt.bytes(done), Fmt.bytes(total)])
	_busy = false
	_set_controls_enabled(true)
	if res.ok:
		Notifier.success("%s now runs Paper %s build #%d." % [inst.config.display_name, inst.config.mc_version, inst.config.paper_build])
		hide()
	else:
		_status.text = res.error


func _set_controls_enabled(enabled: bool) -> void:
	_version_option.disabled = not enabled
	_show_pre.disabled = not enabled
	_backup_check.disabled = not enabled
	get_ok_button().disabled = not enabled
	get_cancel_button().disabled = not enabled


static func compare_versions(a: String, b: String) -> int:
	return Fmt.compare_versions(a, b)
