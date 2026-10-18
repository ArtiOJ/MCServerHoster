class_name BackupsTab
extends ServerTab
## Lists a server's zip backups and creates, restores or deletes them.

enum Column { DATE, TYPE, SIZE, FILE }

@onready var _world_button: Button = %BackupWorldButton
@onready var _full_button: Button = %FullBackupButton
@onready var _open_button: Button = %OpenFolderButton
@onready var _progress: ProgressBar = %BackupProgress
@onready var _tree: Tree = %BackupTree
@onready var _restore_button: Button = %RestoreButton
@onready var _delete_button: Button = %DeleteButton
@onready var _summary_label: Label = %SummaryLabel
@onready var _restore_hint: Label = %RestoreHint
@onready var _restore_dialog: ConfirmationDialog = %RestoreDialog
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog


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
	_restore_button.pressed.connect(_confirm_restore)
	_delete_button.pressed.connect(_confirm_delete)
	_restore_dialog.confirmed.connect(_restore_selected)
	_delete_dialog.confirmed.connect(_delete_selected)
	_tree.item_selected.connect(_update_buttons)
	_tree.nothing_selected.connect(func() -> void:
		_tree.deselect_all()
		_update_buttons())
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and instance != null:
			refresh())


func _on_bound() -> void:
	var backups := instance.backups
	watch(backups.busy_changed, _on_busy_changed)
	watch(backups.progress_changed, func(f: float) -> void: _progress.value = f * 100.0)
	watch(backups.backups_changed, refresh)
	watch(instance.state_changed, _update_buttons.unbind(1))
	watch(instance.config_changed, refresh)
	_on_busy_changed(backups.busy)
	refresh()


func refresh() -> void:
	if instance == null:
		return
	var selected := _selected_path()
	_tree.clear()
	var root := _tree.create_item()
	var total := 0
	var list := instance.backups.list_backups()
	for b in list:
		var item := _tree.create_item(root)
		item.set_text(Column.DATE, Fmt.datetime(int(b.time)))
		item.set_text(Column.TYPE, "Full" if b.full else "World")
		item.set_custom_color(Column.TYPE, Color("5aa9f2") if b.full else Color("3fb97f"))
		item.set_text(Column.SIZE, Fmt.bytes(b.size))
		item.set_text(Column.FILE, b.name)
		item.set_tooltip_text(Column.FILE, b.path)
		item.set_metadata(0, b.path)
		if b.path == selected:
			item.select(0)
		total += int(b.size)
	var keep := instance.config.backup_retention
	var policy := "keeping all backups" if keep <= 0 else "keeping the newest %d" % keep
	if list.is_empty():
		_summary_label.text = "No backups yet · %s · %s" % [policy, instance.backups.backup_dir()]
	else:
		_summary_label.text = "%d backup%s · %s total · %s · %s" % [list.size(), "" if list.size() == 1 else "s", Fmt.bytes(total), policy, instance.backups.backup_dir()]
	_update_buttons()


func _selected_path() -> String:
	var item := _tree.get_selected()
	return str(item.get_metadata(0)) if item != null else ""


func _update_buttons() -> void:
	if instance == null:
		return
	var busy := instance.backups.busy
	var has_selection := _selected_path() != ""
	var alive := instance.is_process_alive()
	var installing := instance.state == ServerInstance.State.INSTALLING
	_world_button.disabled = busy or installing
	_full_button.disabled = busy or installing
	_restore_button.disabled = busy or not has_selection or alive or installing
	_delete_button.disabled = busy or not has_selection
	_restore_hint.visible = alive
	_restore_button.tooltip_text = "Stop the server before restoring a backup." if alive else "Restore the selected backup into the server folder"


func _on_busy_changed(busy: bool) -> void:
	_progress.visible = busy
	if busy:
		_progress.value = 0.0
	_update_buttons()


func _create(full: bool) -> void:
	if instance == null or instance.backups.busy:
		return
	await instance.backups.create_backup(full)
	refresh()


func _confirm_restore() -> void:
	var path := _selected_path()
	if path == "":
		return
	_restore_dialog.dialog_text = ("Restore \"%s\"?\n\nThe world folders contained in this backup will be replaced. " +
		"A safety backup of the current worlds is saved to this list first, then they are deleted.") % path.get_file()
	_restore_dialog.popup_centered()


func _restore_selected() -> void:
	var path := _selected_path()
	if path == "" or instance.is_process_alive():
		return
	var err: Error = await instance.backups.restore_backup(path)
	if err == OK:
		Notifier.success("Restored %s on %s." % [path.get_file(), instance.config.display_name])
	elif err == ERR_ALREADY_IN_USE:
		Notifier.warn("Stop the server before restoring a backup.")
	else:
		Notifier.error("Restoring %s failed: %s" % [path.get_file(), error_string(err)])
	refresh()


func _confirm_delete() -> void:
	var path := _selected_path()
	if path == "":
		return
	_delete_dialog.dialog_text = "Permanently delete the backup \"%s\"?" % path.get_file()
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var path := _selected_path()
	if path != "":
		instance.backups.delete_backup(path)
		refresh()


func _open_folder() -> void:
	var dir := instance.backups.backup_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_open(dir)
