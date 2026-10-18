class_name PluginsTab
extends ServerTab
## Lists the server's plugin jars and installs, enables, disables or removes them.

const DISABLED_SUFFIX := ".disabled"

enum Column { NAME, VERSION, FILE, SIZE, STATUS }

## True after a change was made while the server process was running.
var _changed_while_running := false

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
		if is_visible_in_tree() and instance != null:
			refresh())


func _on_bound() -> void:
	_changed_while_running = false
	watch(instance.state_changed, _on_state_changed)
	refresh()


func plugins_dir() -> String:
	return instance.config.directory.path_join("plugins")


## Copies plugin jars into the plugins folder (used by the Install dialog and window drag-and-drop).
func install_files(paths: PackedStringArray) -> void:
	if instance == null:
		return
	DirAccess.make_dir_recursive_absolute(plugins_dir())
	var installed := PackedStringArray()
	for path in paths:
		if not path.to_lower().ends_with(".jar"):
			Notifier.warn("Skipped %s: only .jar plugin files can be installed." % path.get_file())
			continue
		var target := plugins_dir().path_join(path.get_file())
		var err := DirAccess.copy_absolute(path, target)
		if err != OK:
			Notifier.error("Could not install %s: %s" % [path.get_file(), error_string(err)])
			continue
		# A fresh copy supersedes a previously disabled version of the same file.
		if FileAccess.file_exists(target + DISABLED_SUFFIX):
			DirAccess.remove_absolute(target + DISABLED_SUFFIX)
		installed.append(path.get_file())
	if installed.is_empty():
		return
	_mark_changed()
	refresh()
	instance.log_system("Installed plugin%s: %s" % ["s" if installed.size() > 1 else "", ", ".join(installed)])
	Notifier.success("Installed %d plugin%s on %s." % [installed.size(), "s" if installed.size() > 1 else "", instance.config.display_name])


func refresh() -> void:
	if instance == null:
		return
	var selected_file := _selected_file()
	_tree.clear()
	var root := _tree.create_item()
	var count := 0
	var enabled := 0
	var dir := DirAccess.open(plugins_dir())
	if dir != null:
		var files := Array(dir.get_files())
		files.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
		for f: String in files:
			var is_enabled := f.ends_with(".jar")
			if not is_enabled and not f.ends_with(".jar" + DISABLED_SUFFIX):
				continue
			var path := plugins_dir().path_join(f)
			var meta := read_plugin_meta(path)
			var item := _tree.create_item(root)
			item.set_text(Column.NAME, meta.get("name", f.trim_suffix(DISABLED_SUFFIX).trim_suffix(".jar")))
			item.set_text(Column.VERSION, meta.get("version", "—"))
			item.set_text(Column.FILE, f)
			var file := FileAccess.open(path, FileAccess.READ)
			item.set_text(Column.SIZE, Fmt.bytes(file.get_length()) if file != null else "—")
			item.set_text(Column.STATUS, "Enabled" if is_enabled else "Disabled")
			item.set_custom_color(Column.STATUS, Color("3fb97f") if is_enabled else Color("8b93a3"))
			if not is_enabled:
				item.set_custom_color(Column.NAME, Color("8b93a3"))
			item.set_tooltip_text(Column.NAME, meta.get("description", ""))
			item.set_metadata(0, path)
			if f == selected_file:
				item.select(0)
			count += 1
			if is_enabled:
				enabled += 1
	_summary_label.text = "%d plugin%s · %d enabled · %s" % [count, "" if count == 1 else "s", enabled, plugins_dir()] if count > 0 \
		else "No plugins installed. Paper plugins are .jar files in %s" % plugins_dir()
	_restart_notice.visible = _changed_while_running and instance.is_process_alive()
	_update_buttons()


## Reads name/version/description from plugin.yml or paper-plugin.yml inside a jar.
static func read_plugin_meta(jar_path: String) -> Dictionary:
	var meta := {}
	var reader := ZIPReader.new()
	if reader.open(jar_path) != OK:
		return meta
	var files := reader.get_files()
	for descriptor in ["paper-plugin.yml", "plugin.yml"]:
		if not files.has(descriptor):
			continue
		var text := reader.read_file(descriptor).get_string_from_utf8()
		for line in text.split("\n"):
			# Only top-level keys (no indentation).
			if line.begins_with(" ") or line.begins_with("\t"):
				continue
			for key in ["name", "version", "description"]:
				if line.begins_with(key + ":") and not meta.has(key):
					var value := line.substr(key.length() + 1).strip_edges()
					meta[key] = value.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'")
		break
	reader.close()
	return meta


func _selected_file() -> String:
	var item := _tree.get_selected()
	return item.get_text(Column.FILE) if item != null else ""


func _selected_path() -> String:
	var item := _tree.get_selected()
	return str(item.get_metadata(0)) if item != null else ""


func _update_buttons() -> void:
	var path := _selected_path()
	_toggle_button.disabled = path == ""
	_delete_button.disabled = path == ""
	_toggle_button.text = "Enable" if path.ends_with(DISABLED_SUFFIX) else "Disable"


func _toggle_selected() -> void:
	var path := _selected_path()
	if path == "":
		return
	var target := path.trim_suffix(DISABLED_SUFFIX) if path.ends_with(DISABLED_SUFFIX) else path + DISABLED_SUFFIX
	if FileAccess.file_exists(target):
		Notifier.error("Cannot rename: %s already exists." % target.get_file())
		return
	var err := DirAccess.rename_absolute(path, target)
	if err != OK:
		Notifier.error("Could not rename %s: %s" % [path.get_file(), error_string(err)])
		return
	_select_after_refresh(target.get_file())


func _confirm_delete() -> void:
	var file := _selected_file()
	if file == "":
		return
	_delete_dialog.dialog_text = "Permanently delete \"%s\"?\nIts configuration folder (if any) is kept." % file
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var path := _selected_path()
	if path == "":
		return
	var err := DirAccess.remove_absolute(path)
	if err != OK:
		Notifier.error("Could not delete %s: %s" % [path.get_file(), error_string(err)])
		return
	instance.log_system("Removed plugin " + path.get_file())
	_mark_changed()
	refresh()


func _select_after_refresh(file: String) -> void:
	_mark_changed()
	refresh()
	var root := _tree.get_root()
	if root == null:
		return
	for item in root.get_children():
		if item.get_text(Column.FILE) == file:
			item.select(0)
			break
	_update_buttons()


func _mark_changed() -> void:
	if instance.is_process_alive():
		_changed_while_running = true


func _open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(plugins_dir())
	OS.shell_open(plugins_dir())


func _on_state_changed(_state: ServerInstance.State) -> void:
	if not instance.is_process_alive():
		_changed_while_running = false
	_restart_notice.visible = _changed_while_running and instance.is_process_alive()
