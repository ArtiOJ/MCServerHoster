class_name BackupsTab
extends ServerTab
## Lists a server's zip backups and creates, restores, deletes or saves copies of them.
## For a server on another computer, "Save copy" downloads the backup.

enum Column { DATE, TYPE, SIZE, FILE }

var _serial := 0
var _folder := ""
## A save, restore or delete is running from this tab.
var _working := false

@onready var _world_button: Button = %BackupWorldButton
@onready var _full_button: Button = %FullBackupButton
@onready var _open_button: Button = %OpenFolderButton
@onready var _progress: ProgressBar = %BackupProgress
@onready var _tree: Tree = %BackupTree
@onready var _save_copy_button: Button = %SaveCopyButton
@onready var _restore_button: Button = %RestoreButton
@onready var _delete_button: Button = %DeleteButton
@onready var _summary_label: Label = %SummaryLabel
@onready var _restore_hint: Label = %RestoreHint
@onready var _restore_dialog: ConfirmationDialog = %RestoreDialog
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog
@onready var _save_dialog: FileDialog = %SaveDialog


func _ready() -> void:
	_tree.set_column_title(Column.DATE, "Date")
	_tree.set_column_title(Column.TYPE, "Type")
	_tree.set_column_title(Column.SIZE, "Size")
	_tree.set_column_title(Column.FILE, "File")
	for col in [Column.DATE, Column.TYPE, Column.SIZE]:
		_tree.set_column_expand(col, false)
		_tree.set_column_custom_minimum_width(col, 150 if col == Column.DATE else 100)
	_tree.set_column_expand(Column.FILE, true)
	_world_button.pressed.connect(_create.bind(false))
	_full_button.pressed.connect(_create.bind(true))
	_open_button.pressed.connect(_open_folder)
	_save_copy_button.pressed.connect(_choose_save)
	_save_dialog.file_selected.connect(_save_copy)
	_restore_button.pressed.connect(_confirm_restore)
	_delete_button.pressed.connect(_confirm_delete)
	_restore_dialog.confirmed.connect(_restore_selected)
	_delete_dialog.confirmed.connect(_delete_selected)
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
	_save_copy_button.tooltip_text = "Save a copy of the selected backup on this computer" if not handle.is_remote() \
			else "Download the selected backup from %s" % handle.host_name()
	watch(handle.backup_status_changed, _on_backup_status)
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"backups":
			refresh())
	watch(handle.state_changed, _update_buttons.unbind(1))
	watch(handle.config_changed, refresh)
	_on_backup_status()
	refresh()


func refresh() -> void:
	if handle == null:
		return
	_serial += 1
	var serial := _serial
	var res: Dictionary = await handle.call_op("backups_list")
	if serial != _serial or handle == null:
		return
	if not res.ok:
		_summary_label.text = str(res.error)
		return
	_folder = str(res.folder)
	var selected := _selected_name()
	_tree.clear()
	var root := _tree.create_item()
	var total := 0.0
	for b: Dictionary in res.backups:
		var item := _tree.create_item(root)
		item.set_text(Column.DATE, Fmt.datetime(int(b.time)))
		item.set_text(Column.TYPE, "Full" if b.full else "World")
		item.set_custom_color(Column.TYPE, Color("5aa9f2") if b.full else Color("3fb97f"))
		item.set_text(Column.SIZE, Fmt.bytes(float(b.size)))
		item.set_text(Column.FILE, str(b.name))
		item.set_tooltip_text(Column.FILE, _folder.path_join(str(b.name)))
		item.set_metadata(0, str(b.name))
		if str(b.name) == selected:
			item.select(0)
		total += float(b.size)
	var keep := int(res.retention)
	var policy := "keeping all backups" if keep <= 0 else "keeping the newest %d" % keep
	var count: int = res.backups.size()
	if count == 0:
		_summary_label.text = "No backups yet · %s · %s" % [policy, _folder]
	else:
		_summary_label.text = "%d backup%s · %s total · %s · %s" % [count, "" if count == 1 else "s", Fmt.bytes(total), policy, _folder]
	_update_buttons()


func _selected_name() -> String:
	var item := _tree.get_selected()
	return str(item.get_metadata(0)) if item != null else ""


func _update_buttons() -> void:
	if handle == null:
		return
	var busy := handle.backup_busy or _working
	var has_selection := _selected_name() != ""
	var alive := handle.is_process_alive()
	var installing := handle.state == ServerHandle.State.INSTALLING
	_world_button.disabled = busy or installing
	_full_button.disabled = busy or installing
	_save_copy_button.disabled = _working or not has_selection
	_restore_button.disabled = busy or not has_selection or alive or installing
	_delete_button.disabled = busy or not has_selection
	_restore_hint.visible = alive
	_restore_button.tooltip_text = "Stop the server before restoring a backup." if alive else "Restore the selected backup into the server folder"


func _on_backup_status() -> void:
	_progress.visible = handle.backup_busy or _working
	if handle.backup_busy:
		_progress.value = handle.backup_progress * 100.0
	_update_buttons()


func _create(full: bool) -> void:
	if handle == null or handle.backup_busy:
		return
	var h := handle
	var res: Dictionary = await h.call_op("backup_create", {"full": full})
	if not res.ok and h.is_remote():
		Notifier.error("%s: %s" % [h.config.display_name, res.error])
	elif res.ok and h.is_remote():
		Notifier.success("Backup of %s created." % h.config.display_name)
	if h == handle:
		refresh()


func _choose_save() -> void:
	var name := _selected_name()
	if name == "":
		return
	_save_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	_save_dialog.current_file = "%s-%s" % [Fmt.slugify(handle.config.display_name), name]
	_save_dialog.popup_centered()


func _save_copy(dest: String) -> void:
	var name := _selected_name()
	if name == "" or _working:
		return
	if dest.get_extension().to_lower() != "zip":
		dest += ".zip"
	var h := handle
	_set_working(true)
	var res: Dictionary = await h.call_op("backup_file", {"name": name, "dest": dest}, func(_text: String, fraction: float) -> void:
		if h == handle and fraction >= 0.0:
			_progress.value = fraction * 100.0)
	_set_working(false)
	if res.ok:
		Notifier.success("Saved %s." % dest.get_file())
	else:
		Notifier.error("Could not save %s: %s" % [name, res.error])


func _set_working(on: bool) -> void:
	_working = on
	_progress.value = 0.0
	_on_backup_status()


func _confirm_restore() -> void:
	var name := _selected_name()
	if name == "":
		return
	_restore_dialog.dialog_text = ("Restore \"%s\"?\n\nThe world folders contained in this backup will be replaced. " +
		"A safety backup of the current worlds is saved to this list first, then they are deleted.") % name
	_restore_dialog.popup_centered()


func _restore_selected() -> void:
	var name := _selected_name()
	if name == "" or handle.is_process_alive():
		return
	var h := handle
	var res: Dictionary = await h.call_op("backup_restore", {"name": name})
	if res.ok:
		Notifier.success("Restored %s on %s." % [name, h.config.display_name])
	else:
		Notifier.error(str(res.error))
	if h == handle:
		refresh()


func _confirm_delete() -> void:
	var name := _selected_name()
	if name == "":
		return
	_delete_dialog.dialog_text = "Permanently delete the backup \"%s\"?" % name
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var name := _selected_name()
	if name == "":
		return
	var res: Dictionary = await handle.call_op("backup_delete", {"name": name})
	if not res.ok:
		Notifier.error(str(res.error))
	refresh()


func _open_folder() -> void:
	if _folder == "" or handle == null or handle.is_remote():
		return
	DirAccess.make_dir_recursive_absolute(_folder)
	OS.shell_open(_folder)
