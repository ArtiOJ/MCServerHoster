class_name PluginsTab
extends ServerTab
## Lists the server's plugin jars and installs, enables, disables or removes them.
## Works the same for servers on other computers: chosen jars are uploaded there.

const DISABLED_SUFFIX := ServerOps.DISABLED_SUFFIX

enum Column { NAME, VERSION, FILE, SIZE, STATUS }

var _serial := 0
var _busy := false
var _folder := ""

@onready var _install_button: Button = %InstallButton
@onready var _open_button: Button = %OpenFolderButton
@onready var _refresh_button: Button = %RefreshButton
@onready var _tree: Tree = %PluginTree
@onready var _toggle_button: Button = %ToggleButton
@onready var _delete_button: Button = %DeleteButton
@onready var _summary_label: Label = %SummaryLabel
@onready var _restart_notice: PanelContainer = %RestartNotice
@onready var _file_dialog: FileDialog = %InstallDialog
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog


func _ready() -> void:
	_tree.set_column_title(Column.NAME, "Name")
	_tree.set_column_title(Column.VERSION, "Version")
	_tree.set_column_title(Column.FILE, "File")
	_tree.set_column_title(Column.SIZE, "Size")
	_tree.set_column_title(Column.STATUS, "Status")
	_tree.set_column_expand(Column.NAME, true)
	_tree.set_column_expand_ratio(Column.NAME, 2)
	_tree.set_column_expand(Column.FILE, true)
	_tree.set_column_expand_ratio(Column.FILE, 2)
	for col in [Column.VERSION, Column.SIZE, Column.STATUS]:
		_tree.set_column_expand(col, false)
		_tree.set_column_custom_minimum_width(col, 110)
	_install_button.pressed.connect(_file_dialog.popup_centered_ratio.bind(0.6))
	_open_button.pressed.connect(_open_folder)
	_refresh_button.pressed.connect(refresh)
	_toggle_button.pressed.connect(_toggle_selected)
	_delete_button.pressed.connect(_confirm_delete)
	_delete_dialog.confirmed.connect(_delete_selected)
	_file_dialog.files_selected.connect(install_files)
	_tree.item_selected.connect(_update_buttons)
	_tree.nothing_selected.connect(func() -> void:
		_tree.deselect_all()
		_update_buttons())
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and handle != null:
			refresh())


func _on_bound() -> void:
	_folder = ""
	_tree.clear()
	_open_button.visible = handle.supports(ServerHandle.FEATURE_OPEN_FOLDER)
	_install_button.tooltip_text = "Install plugin .jar files" if not handle.is_remote() \
			else "Upload plugin .jar files from this computer to %s" % handle.host_name()
	watch(handle.state_changed, func(_s: ServerHandle.State) -> void: refresh())
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"plugins" and is_visible_in_tree():
			refresh())
	refresh()


## Installs plugin jars (from the Install dialog or files dropped onto the window).
func install_files(paths: PackedStringArray) -> void:
	if handle == null or _busy:
		return
	var h := handle
	_set_busy(true, "Installing…")
	var res: Dictionary = await h.call_op("plugin_install", {"files": Array(paths)}, func(text: String, _f: float) -> void:
		if h == handle:
			_summary_label.text = text)
	_set_busy(false)
	for message in res.get("skipped", []):
		Notifier.warn(str(message))
	var installed: Array = res.get("installed", [])
	if not installed.is_empty():
		Notifier.success("Installed %d plugin%s on %s." % [installed.size(), "s" if installed.size() > 1 else "", h.config.display_name])
	elif not res.ok and res.get("skipped", []).is_empty():
		Notifier.error(str(res.get("error", "Installing failed.")))
	if h == handle:
		refresh()


func refresh() -> void:
	if handle == null or _busy:
		return
	_serial += 1
	var serial := _serial
	var res: Dictionary = await handle.call_op("plugins_list")
	if serial != _serial or handle == null:
		return
	if not res.ok:
		_tree.clear()
		_summary_label.text = str(res.error)
		_update_buttons()
		return
	_folder = str(res.folder)
	var selected_file := _selected_file()
	_tree.clear()
	var root := _tree.create_item()
	var enabled := 0
	for p: Dictionary in res.plugins:
		var item := _tree.create_item(root)
		var on := bool(p.enabled)
		item.set_text(Column.NAME, str(p.name))
		item.set_text(Column.VERSION, str(p.version) if str(p.version) != "" else "—")
		item.set_text(Column.FILE, str(p.file))
		item.set_text(Column.SIZE, Fmt.bytes(float(p.size)))
		item.set_text(Column.STATUS, "Enabled" if on else "Disabled")
		item.set_custom_color(Column.STATUS, Color("3fb97f") if on else Color("8b93a3"))
		if not on:
			item.set_custom_color(Column.NAME, Color("8b93a3"))
		item.set_tooltip_text(Column.NAME, str(p.description))
		item.set_metadata(0, str(p.file))
		if str(p.file) == selected_file:
			item.select(0)
		if on:
			enabled += 1
	var count: int = res.plugins.size()
	_summary_label.text = "%d plugin%s · %d enabled · %s" % [count, "" if count == 1 else "s", enabled, _folder] if count > 0 \
		else "No plugins installed. Paper plugins are .jar files in %s" % _folder
	_restart_notice.visible = bool(res.restart_needed)
	_update_buttons()


func _selected_file() -> String:
	var item := _tree.get_selected()
	return str(item.get_metadata(0)) if item != null else ""


func _update_buttons() -> void:
	var file := _selected_file()
	_install_button.disabled = _busy
	_toggle_button.disabled = file == "" or _busy
	_delete_button.disabled = file == "" or _busy
	_toggle_button.text = "Enable" if file.ends_with(DISABLED_SUFFIX) else "Disable"


func _set_busy(on: bool, text := "") -> void:
	_busy = on
	if text != "":
		_summary_label.text = text
	_update_buttons()


func _toggle_selected() -> void:
	var file := _selected_file()
	if file == "" or handle == null:
		return
	var res: Dictionary = await handle.call_op("plugin_toggle", {"file": file})
	if not res.ok:
		Notifier.error(str(res.error))
		return
	await refresh()
	_select(str(res.file))


func _confirm_delete() -> void:
	var file := _selected_file()
	if file == "":
		return
	_delete_dialog.dialog_text = "Permanently delete \"%s\"?\nIts configuration folder (if any) is kept." % file
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var file := _selected_file()
	if file == "" or handle == null:
		return
	var res: Dictionary = await handle.call_op("plugin_delete", {"file": file})
	if not res.ok:
		Notifier.error(str(res.error))
	refresh()


func _select(file: String) -> void:
	var root := _tree.get_root()
	if root == null:
		return
	for item in root.get_children():
		if str(item.get_metadata(0)) == file:
			item.select(0)
			break
	_update_buttons()


func _open_folder() -> void:
	if _folder == "" or handle == null or handle.is_remote():
		return
	DirAccess.make_dir_recursive_absolute(_folder)
	OS.shell_open(_folder)
