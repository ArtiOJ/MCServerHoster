class_name WorldsTab
extends ServerTab
## Worlds stored in the server folder: switch the active one, export as a
## singleplayer-ready zip, reset, delete and import; plus the active world's datapacks.

enum WorldCol { NAME, STATUS, VERSION, SEED, MODE, SIZE, PLAYED }
enum PackCol { NAME, DESCRIPTION, FORMAT, STATUS }

var _worlds: Array[Dictionary] = []
var _packs: Array[Dictionary] = []
## Pack ids reported by the running server ({} when offline).
var _online_enabled := PackedStringArray()
var _online_available := PackedStringArray()
var _busy := false
var _serial := 0

@onready var _import_button: Button = %ImportButton
@onready var _open_button: Button = %OpenFolderButton
@onready var _refresh_button: Button = %RefreshButton
@onready var _progress: ProgressBar = %WorkProgress
@onready var _status: Label = %StatusLabel
@onready var _blocked_notice: PanelContainer = %BlockedNotice
@onready var _blocked_label: Label = %BlockedLabel
@onready var _activate_button: Button = %ActivateButton
@onready var _export_button: Button = %ExportButton
@onready var _reset_button: Button = %ResetButton
@onready var _delete_button: Button = %DeleteButton
@onready var _world_tree: Tree = %WorldTree
@onready var _worlds_summary: Label = %WorldsSummary
@onready var _packs_title: Label = %PacksTitle
@onready var _add_zip_button: Button = %AddZipButton
@onready var _add_folder_button: Button = %AddFolderButton
@onready var _enable_button: Button = %EnableButton
@onready var _disable_button: Button = %DisableButton
@onready var _remove_pack_button: Button = %RemovePackButton
@onready var _pack_tree: Tree = %PackTree
@onready var _packs_hint: Label = %PacksHint
@onready var _export_dialog: FileDialog = %ExportDialog
@onready var _pack_zip_dialog: FileDialog = %PackZipDialog
@onready var _pack_folder_dialog: FileDialog = %PackFolderDialog
@onready var _reset_dialog: ConfirmationDialog = %ResetDialog
@onready var _reset_message: Label = %ResetMessage
@onready var _seed_edit: LineEdit = %SeedEdit
@onready var _keep_players_check: CheckButton = %KeepPlayersCheck
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog
@onready var _remove_pack_dialog: ConfirmationDialog = %RemovePackDialog
@onready var _import_dialog: ImportWorldDialog = %ImportWorldDialog


func _ready() -> void:
	var titles := ["Name", "Status", "Version", "Seed", "Mode", "Size", "Last played"]
	for i in titles.size():
		_world_tree.set_column_title(i, titles[i])
		_world_tree.set_column_expand(i, i == WorldCol.NAME or i == WorldCol.SEED)
		if i != WorldCol.NAME and i != WorldCol.SEED:
			_world_tree.set_column_custom_minimum_width(i, 130 if i == WorldCol.PLAYED else 90)
	var pack_titles := ["Pack", "Description", "Format", "Status"]
	for i in pack_titles.size():
		_pack_tree.set_column_title(i, pack_titles[i])
		_pack_tree.set_column_expand(i, i == PackCol.NAME or i == PackCol.DESCRIPTION)
		if i == PackCol.FORMAT or i == PackCol.STATUS:
			_pack_tree.set_column_custom_minimum_width(i, 70 if i == PackCol.FORMAT else 150)
	_import_button.pressed.connect(func() -> void: _import_dialog.open(instance))
	_import_dialog.imported.connect(func(_i: ServerInstance) -> void: refresh())
	_open_button.pressed.connect(func() -> void: OS.shell_open(instance.config.directory))
	_refresh_button.pressed.connect(refresh)
	_activate_button.pressed.connect(_activate_selected)
	_export_button.pressed.connect(_choose_export)
	_export_dialog.file_selected.connect(_export_to)
	_reset_button.pressed.connect(_confirm_reset)
	_reset_dialog.confirmed.connect(_reset_selected)
	_delete_button.pressed.connect(_confirm_delete)
	_delete_dialog.confirmed.connect(_delete_selected)
	_add_zip_button.pressed.connect(func() -> void: _pack_zip_dialog.popup_centered())
	_add_folder_button.pressed.connect(func() -> void: _pack_folder_dialog.popup_centered())
	_pack_zip_dialog.file_selected.connect(_add_pack)
	_pack_folder_dialog.dir_selected.connect(_add_pack)
	_enable_button.pressed.connect(_toggle_pack.bind(true))
	_disable_button.pressed.connect(_toggle_pack.bind(false))
	_remove_pack_button.pressed.connect(_confirm_remove_pack)
	_remove_pack_dialog.confirmed.connect(_remove_selected_pack)
	_world_tree.item_selected.connect(_update_buttons)
	_pack_tree.item_selected.connect(_update_buttons)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and instance != null:
			refresh())


func _on_bound() -> void:
	watch(instance.state_changed, _on_state_changed)
	watch(instance.config_changed, func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func _on_state_changed(_state: ServerInstance.State) -> void:
	_update_buttons()
	if is_visible_in_tree() and instance.state != ServerInstance.State.INSTALLING:
		refresh()


## Rescans worlds (sizes on a worker thread) and datapacks, and asks a running server
## which packs are enabled.
func refresh() -> void:
	if instance == null or not is_node_ready():
		return
	_serial += 1
	var serial := _serial
	var inst := instance
	var dir := inst.config.directory
	var level := inst.get_properties().get_value("level-name", "world")
	# Quick pass without sizes so the list appears immediately, then fill in sizes.
	_worlds = WorldManager.list_worlds(dir, level, false)
	_fill_worlds()
	_refresh_packs()
	var sized: Array[Dictionary] = await FileOps.run_async(self, func() -> Array[Dictionary]: return WorldManager.list_worlds(dir, level, true))
	if serial != _serial or inst != instance:
		return
	_worlds = sized
	_fill_worlds()
	await _query_online_packs()
	if serial == _serial and inst == instance:
		_fill_packs()


func _fill_worlds() -> void:
	var selected := _selected_world()
	var keep: String = selected.get("folder", "")
	_world_tree.clear()
	var root := _world_tree.create_item()
	var total := 0
	for w in _worlds:
		var item := _world_tree.create_item(root)
		var label: String = w.name if w.name == w.folder else "%s  (%s)" % [w.name, w.folder]
		item.set_text(WorldCol.NAME, label)
		item.set_tooltip_text(WorldCol.NAME, "Folder: %s\nLayout: %s" % [", ".join(w.folders), WorldImporter.LAYOUT_NAMES[w.layout]])
		if w.active:
			item.set_text(WorldCol.STATUS, "Active" if w.generated else "New")
			item.set_custom_color(WorldCol.STATUS, Color("3fb97f"))
			item.set_tooltip_text(WorldCol.STATUS, ("The server loads this world." + (" Version and seed appear after its first save." if w.get("unsaved", false) else "")) if w.generated else "Not generated yet; it is created on the next start.")
		item.set_text(WorldCol.VERSION, w.version if w.version != "" else "—")
		item.set_text(WorldCol.SEED, w.seed if w.seed != "" else "—")
		item.set_tooltip_text(WorldCol.SEED, "Seed %s" % w.seed if w.seed != "" else "")
		item.set_text(WorldCol.MODE, str(w.game_mode).capitalize() if w.game_mode != "" else "—")
		item.set_text(WorldCol.SIZE, Fmt.bytes(w.size_bytes) if w.size_bytes > 0 else ("—" if not w.generated else "…"))
		item.set_text(WorldCol.PLAYED, Fmt.datetime(w.last_played) if w.last_played > 0 else "—")
		item.set_metadata(0, w.folder)
		if w.folder == keep or (keep == "" and w.active):
			item.select(0)
		total += int(w.size_bytes)
	var count := _worlds.filter(func(w: Dictionary) -> bool: return w.generated).size()
	_worlds_summary.text = "%d world%s · %s" % [count, "" if count == 1 else "s", Fmt.bytes(total)] + \
			(" · the active world is generated on the next start" if _worlds.any(func(w: Dictionary) -> bool: return w.active and not w.generated) else "")
	_update_buttons()


func _refresh_packs() -> void:
	var active := _active_world()
	_packs = WorldManager.list_datapacks(active.get("datapacks_dir", "")) if not active.is_empty() else []
	_packs_title.text = "Datapacks · %s" % active.get("folder", "") if not active.is_empty() else "Datapacks"
	_fill_packs()


func _query_online_packs() -> void:
	if instance == null or not instance.is_online() or not instance.rcon.is_ready():
		_online_enabled = PackedStringArray()
		_online_available = PackedStringArray()
		return
	# Swap both lists in at once, so a refresh running in parallel never sees half an answer.
	var inst := instance
	var enabled := WorldManager.parse_datapack_list(await inst.rcon.execute("datapack list enabled"))
	var available := WorldManager.parse_datapack_list(await inst.rcon.execute("datapack list available"))
	if inst == instance:
		_online_enabled = enabled
		_online_available = available


func _fill_packs() -> void:
	var selected := _selected_pack()
	var keep: String = selected.get("id", "")
	_pack_tree.clear()
	var root := _pack_tree.create_item()
	var active := _active_world()
	var online := instance != null and instance.is_online() and instance.rcon.is_ready()
	for p in _packs:
		var item := _pack_tree.create_item(root)
		item.set_text(PackCol.NAME, p.name)
		item.set_tooltip_text(PackCol.NAME, p.path)
		if _is_internal(p):
			item.set_text(PackCol.NAME, "%s  (Paper)" % p.name)
			item.set_tooltip_text(PackCol.NAME, "Created by Paper for data that plugins provide. Leave it in place.")
		item.set_text(PackCol.DESCRIPTION, p.description if p.valid else "No pack.mcmeta — Minecraft ignores this pack")
		if not p.valid:
			item.set_custom_color(PackCol.DESCRIPTION, Color("e05555"))
		item.set_text(PackCol.FORMAT, p.format if p.format != "" else "—")
		var status := _pack_status(p, active, online)
		item.set_text(PackCol.STATUS, status)
		item.set_custom_color(PackCol.STATUS, Color("3fb97f") if status == "Enabled" else (Color("e05555") if status.begins_with("Disabled") else Color("8b93a3")))
		item.set_metadata(0, p.id)
		if p.id == keep:
			item.select(0)
	if active.is_empty():
		_packs_hint.text = ""
	elif online:
		_packs_hint.text = "Enable and disable apply immediately. New packs copied in now are found after /reload or the next start."
	else:
		_packs_hint.text = "The server is offline: new packs load on the next start; start it to enable or disable packs. Folder: %s" % active.datapacks_dir
	_update_buttons()


func _pack_status(p: Dictionary, active: Dictionary, online: bool) -> String:
	if online:
		if _online_enabled.has(p.id):
			return "Enabled"
		if _online_available.has(p.id):
			return "Disabled"
		return "Not loaded yet"
	if PackedStringArray(active.get("disabled_packs", [])).has(p.id):
		return "Disabled"
	if PackedStringArray(active.get("enabled_packs", [])).has(p.id):
		return "Enabled"
	return "Loads on next start"


## Paper creates world/datapacks/bukkit for plugin-provided data; it must stay.
static func _is_internal(p: Dictionary) -> bool:
	return p.get("name", "") == "bukkit" and not p.get("is_zip", false)


func _selected_world() -> Dictionary:
	var item := _world_tree.get_selected()
	if item == null:
		return {}
	var folder := str(item.get_metadata(0))
	for w in _worlds:
		if w.folder == folder:
			return w
	return {}


func _active_world() -> Dictionary:
	for w in _worlds:
		if w.active:
			return w
	return {}


func _selected_pack() -> Dictionary:
	var item := _pack_tree.get_selected()
	if item == null:
		return {}
	var id := str(item.get_metadata(0))
	for p in _packs:
		if p.id == id:
			return p
	return {}


func _update_buttons() -> void:
	if instance == null or not is_node_ready():
		return
	var blocker := WorldManager.change_blocker(instance)
	var w := _selected_world()
	var has_world := not w.is_empty()
	_blocked_notice.visible = blocker != ""
	_blocked_label.text = blocker.trim_suffix(".") + " to switch, reset, delete or import worlds." if blocker == "Stop the server first." else blocker
	_import_button.disabled = _busy or blocker != ""
	_activate_button.disabled = _busy or blocker != "" or not has_world or w.active
	_export_button.disabled = _busy or not has_world or not w.generated
	_reset_button.disabled = _busy or blocker != "" or not has_world or not w.active or not w.generated
	_delete_button.disabled = _busy or blocker != "" or not has_world or w.active
	_reset_button.tooltip_text = "Delete the active world so a fresh one is generated on the next start. A safety backup is saved first." \
			if not has_world or w.active else "Only the active world can be reset. Make this world active first, or delete it."
	var online := instance.is_online() and instance.rcon.is_ready()
	var p := _selected_pack()
	var has_active := not _active_world().is_empty()
	_add_zip_button.disabled = _busy or not has_active
	_add_folder_button.disabled = _busy or not has_active
	_remove_pack_button.disabled = _busy or p.is_empty() or instance.is_process_alive() or _is_internal(p)
	if not p.is_empty() and _is_internal(p):
		_remove_pack_button.tooltip_text = "Paper manages this pack; it can't be removed."
	elif instance.is_process_alive():
		_remove_pack_button.tooltip_text = "Stop the server before removing a pack."
	else:
		_remove_pack_button.tooltip_text = "Permanently delete the selected pack from the world's datapacks folder."
	var status := _pack_status(p, _active_world(), online) if not p.is_empty() else ""
	_enable_button.disabled = _busy or p.is_empty() or not online or status == "Enabled"
	_disable_button.disabled = _busy or p.is_empty() or not online or status != "Enabled"


func _set_busy(busy: bool, text := "") -> void:
	_busy = busy
	_progress.visible = busy
	_progress.value = 0.0
	if text != "":
		_status.text = text
	_update_buttons()


# --- World actions ---------------------------------------------------------------

func _activate_selected() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	var err := WorldManager.set_active(instance, w.folder)
	if err != "":
		Notifier.error(err)
		return
	Notifier.success("%s will load \"%s\" on the next start." % [instance.config.display_name, w.name])
	refresh()


func _choose_export() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	_export_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)
	_export_dialog.current_file = "%s.zip" % WorldImporter.unique_level_name("/nonexistent", w.name)
	_export_dialog.popup_centered()


func _export_to(zip_path: String) -> void:
	var w := _selected_world()
	if w.is_empty() or _busy:
		return
	if zip_path.get_extension().to_lower() != "zip":
		zip_path += ".zip"
	var inst := instance
	_set_busy(true, "Exporting %s…" % w.name)
	# A running server keeps writing to its active world; flush and pause saving while zipping.
	var paused: bool = await inst.backups.pause_saving() if w.active else false
	var job := {"mutex": Mutex.new(), "progress": 0.0}
	var dir := inst.config.directory
	var thread := Thread.new()
	thread.start(func() -> String: return WorldManager.export_zip(dir, w, zip_path, job))
	while thread.is_alive():
		await get_tree().create_timer(0.15).timeout
		(job.mutex as Mutex).lock()
		_progress.value = job.progress
		(job.mutex as Mutex).unlock()
	var err: String = thread.wait_to_finish()
	if paused:
		inst.backups.resume_saving()
	_set_busy(false, "")
	if err != "":
		_status.text = err
		Notifier.error("Export failed: %s" % err)
		return
	_status.text = "Exported to %s" % zip_path
	inst.log_system("Exported world \"%s\" to %s." % [w.name, zip_path])
	Notifier.success("Exported \"%s\" as a singleplayer world: %s" % [w.name, zip_path.get_file()])


func _confirm_reset() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	_reset_message.text = "Delete \"%s\" and generate a new world on the next start? A safety backup of the current world is saved to Backups first." % w.name
	_seed_edit.text = ""
	_keep_players_check.button_pressed = false
	_reset_dialog.popup_centered()


func _reset_selected() -> void:
	var w := _selected_world()
	if w.is_empty() or _busy:
		return
	_set_busy(true, "Resetting %s…" % w.name)
	var err: String = await WorldManager.reset_world(instance, w, _seed_edit.text, _keep_players_check.button_pressed)
	_set_busy(false, "" if err == "" else err)
	if err != "":
		Notifier.error(err)
	else:
		_status.text = "World reset. A new one is generated on the next start."
		Notifier.success("\"%s\" was reset; a new world is generated on the next start." % w.name)
	refresh()


func _confirm_delete() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	_delete_dialog.dialog_text = "Permanently delete \"%s\" (%s)? This cannot be undone." % [w.name, ", ".join(w.folders)]
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	var err := WorldManager.delete_world(instance, w)
	if err != "":
		Notifier.error(err)
	else:
		Notifier.success("Deleted world \"%s\"." % w.name)
	refresh()


# --- Datapack actions ---------------------------------------------------------------

func _add_pack(source: String) -> void:
	var active := _active_world()
	if active.is_empty():
		return
	var err := WorldManager.add_datapack(active.datapacks_dir, source)
	if err != "":
		Notifier.error(err)
		return
	var name := source.get_file()
	instance.log_system("Added datapack %s." % name)
	if instance.is_online():
		Notifier.success("Added %s. Run /reload (or restart) to load it." % name)
	else:
		Notifier.success("Added %s. It loads on the next start." % name)
	refresh()


func _toggle_pack(enable: bool) -> void:
	var p := _selected_pack()
	if p.is_empty() or not instance.is_online():
		return
	instance.send_command(WorldManager.datapack_command(p.id, enable))
	await get_tree().create_timer(1.0).timeout
	await _query_online_packs()
	_fill_packs()


func _confirm_remove_pack() -> void:
	var p := _selected_pack()
	if p.is_empty():
		return
	_remove_pack_dialog.dialog_text = "Permanently delete the datapack \"%s\"?" % p.name
	_remove_pack_dialog.popup_centered()


func _remove_selected_pack() -> void:
	var p := _selected_pack()
	if p.is_empty():
		return
	var err := WorldManager.remove_datapack(p)
	if err != "":
		Notifier.error(err)
	else:
		instance.log_system("Removed datapack %s." % p.name)
		Notifier.success("Removed %s." % p.name)
	refresh()
