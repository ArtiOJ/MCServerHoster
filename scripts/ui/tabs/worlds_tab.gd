class_name WorldsTab
extends ServerTab
## Worlds stored in the server folder: switch the active one, export as a
## singleplayer-ready zip, reset, delete and import; plus the active world's datapacks.
## For a server on another computer, exports are downloaded and new worlds and packs uploaded.

enum WorldCol { NAME, STATUS, VERSION, SEED, MODE, SIZE, PLAYED }
enum PackCol { NAME, DESCRIPTION, FORMAT, STATUS }

var _worlds: Array[Dictionary] = []
var _packs: Array[Dictionary] = []
## Pack ids reported by the running server ({} when offline).
var _online_enabled := PackedStringArray()
var _online_available := PackedStringArray()
var _online := false
var _blocker := ""
var _folder := ""
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
	_import_button.pressed.connect(func() -> void: _import_dialog.open(handle))
	_import_dialog.imported.connect(func(_h: ServerHandle) -> void: refresh())
	_open_button.pressed.connect(func() -> void:
		if handle != null and not handle.is_remote():
			OS.shell_open(_folder))
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
		if is_visible_in_tree() and handle != null:
			refresh())


func _on_bound() -> void:
	_worlds.clear()
	_packs.clear()
	_world_tree.clear()
	_pack_tree.clear()
	_open_button.visible = handle.supports(ServerHandle.FEATURE_OPEN_FOLDER)
	watch(handle.state_changed, _on_state_changed)
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"worlds" and is_visible_in_tree() and not _busy:
			refresh())
	watch(handle.config_changed, func() -> void:
		if is_visible_in_tree():
			refresh())
	refresh()


func _on_state_changed(_state: ServerHandle.State) -> void:
	_update_buttons()
	if is_visible_in_tree() and handle.state != ServerHandle.State.INSTALLING:
		refresh()


## Rescans worlds (first quickly, then with folder sizes) and datapacks; a running server
## is asked which packs are enabled.
func refresh() -> void:
	if handle == null or not is_node_ready():
		return
	_serial += 1
	var serial := _serial
	var h := handle
	var quick: Dictionary = await h.call_op("worlds_list", {"sizes": false})
	if serial != _serial or h != handle:
		return
	_apply(quick)
	var sized: Dictionary = await h.call_op("worlds_list", {"sizes": true})
	if serial != _serial or h != handle:
		return
	_apply(sized)


func _apply(res: Dictionary) -> void:
	if not res.get("ok", false):
		_status.text = str(res.get("error", ""))
		return
	_worlds.clear()
	for w in res.worlds:
		_worlds.append(w)
	_packs.clear()
	for p in res.packs:
		_packs.append(p)
	_online = bool(res.online)
	_online_enabled = PackedStringArray(res.online_enabled)
	_online_available = PackedStringArray(res.online_available)
	_blocker = str(res.blocker)
	_folder = str(res.folder)
	_fill_worlds()
	_fill_packs()


func _fill_worlds() -> void:
	var selected := _selected_world()
	var keep: String = selected.get("folder", "")
	_world_tree.clear()
	var root := _world_tree.create_item()
	var total := 0.0
	for w in _worlds:
		var item := _world_tree.create_item(root)
		var label: String = w.name if w.name == w.folder else "%s  (%s)" % [w.name, w.folder]
		item.set_text(WorldCol.NAME, label)
		item.set_tooltip_text(WorldCol.NAME, "Folder: %s\nLayout: %s" % [", ".join(PackedStringArray(w.folders)), w.layout_name])
		if w.active:
			item.set_text(WorldCol.STATUS, "Active" if w.generated else "New")
			item.set_custom_color(WorldCol.STATUS, Color("3fb97f"))
			item.set_tooltip_text(WorldCol.STATUS, ("The server loads this world." + (" Version and seed appear after its first save." if w.get("unsaved", false) else "")) if w.generated else "Not generated yet; it is created on the next start.")
		item.set_text(WorldCol.VERSION, w.version if w.version != "" else "—")
		item.set_text(WorldCol.SEED, w.seed if w.seed != "" else "—")
		item.set_tooltip_text(WorldCol.SEED, "Seed %s" % w.seed if w.seed != "" else "")
		item.set_text(WorldCol.MODE, str(w.game_mode).capitalize() if w.game_mode != "" else "—")
		item.set_text(WorldCol.SIZE, Fmt.bytes(float(w.size_bytes)) if float(w.size_bytes) > 0 else ("—" if not w.generated else "…"))
		item.set_text(WorldCol.PLAYED, Fmt.datetime(int(w.last_played)) if float(w.last_played) > 0 else "—")
		item.set_metadata(0, w.folder)
		if w.folder == keep or (keep == "" and w.active):
			item.select(0)
		total += float(w.size_bytes)
	var count := _worlds.filter(func(w: Dictionary) -> bool: return w.generated).size()
	_worlds_summary.text = "%d world%s · %s" % [count, "" if count == 1 else "s", Fmt.bytes(total)] + \
			(" · the active world is generated on the next start" if _worlds.any(func(w: Dictionary) -> bool: return w.active and not w.generated) else "")
	var active := _active_world()
	_packs_title.text = "Datapacks · %s" % active.get("folder", "") if not active.is_empty() else "Datapacks"
	_update_buttons()


func _fill_packs() -> void:
	var selected := _selected_pack()
	var keep: String = selected.get("id", "")
	_pack_tree.clear()
	var root := _pack_tree.create_item()
	var active := _active_world()
	for p in _packs:
		var item := _pack_tree.create_item(root)
		item.set_text(PackCol.NAME, p.name)
		item.set_tooltip_text(PackCol.NAME, str(p.folder).path_join(p.name))
		if _is_internal(p):
			item.set_text(PackCol.NAME, "%s  (Paper)" % p.name)
			item.set_tooltip_text(PackCol.NAME, "Created by Paper for data that plugins provide. Leave it in place.")
		item.set_text(PackCol.DESCRIPTION, p.description if p.valid else "No pack.mcmeta — Minecraft ignores this pack")
		if not p.valid:
			item.set_custom_color(PackCol.DESCRIPTION, Color("e05555"))
		item.set_text(PackCol.FORMAT, p.format if p.format != "" else "—")
		var status := _pack_status(p, active, _online)
		item.set_text(PackCol.STATUS, status)
		item.set_custom_color(PackCol.STATUS, Color("3fb97f") if status == "Enabled" else (Color("e05555") if status.begins_with("Disabled") else Color("8b93a3")))
		item.set_metadata(0, p.id)
		if p.id == keep:
			item.select(0)
	if active.is_empty():
		_packs_hint.text = ""
	elif _online:
		_packs_hint.text = "Enable and disable apply immediately. New packs copied in now are found after /reload or the next start."
	else:
		_packs_hint.text = "The server is offline: new packs load on the next start; start it to enable or disable packs. Folder: %s" % active.get("packs_folder", "")
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
	if handle == null or not is_node_ready():
		return
	var blocker := _blocker
	if handle.is_temporary():
		blocker = "A temporary copy of this server is pending. Keep or discard it first."
	elif handle.is_process_alive() or handle.state == ServerHandle.State.INSTALLING:
		blocker = "Stop the server first."
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
	_export_button.tooltip_text = "Save the world as a singleplayer-ready zip" if not handle.is_remote() \
			else "Download the world from %s as a singleplayer-ready zip" % handle.host_name()
	var p := _selected_pack()
	var has_active := not _active_world().is_empty()
	var alive := handle.is_process_alive()
	_add_zip_button.disabled = _busy or not has_active
	_add_folder_button.disabled = _busy or not has_active
	_remove_pack_button.disabled = _busy or p.is_empty() or alive or _is_internal(p)
	if not p.is_empty() and _is_internal(p):
		_remove_pack_button.tooltip_text = "Paper manages this pack; it can't be removed."
	elif alive:
		_remove_pack_button.tooltip_text = "Stop the server before removing a pack."
	else:
		_remove_pack_button.tooltip_text = "Permanently delete the selected pack from the world's datapacks folder."
	var status := _pack_status(p, _active_world(), _online) if not p.is_empty() else ""
	_enable_button.disabled = _busy or p.is_empty() or not _online or status == "Enabled"
	_disable_button.disabled = _busy or p.is_empty() or not _online or status != "Enabled"


func _set_busy(busy: bool, text := "") -> void:
	_busy = busy
	_progress.visible = busy
	_progress.value = 0.0
	if text != "":
		_status.text = text
	_update_buttons()


## Progress of an operation started from this tab, shown while [param h] is still shown.
func _progress_for(h: ServerHandle) -> Callable:
	return func(text: String, fraction: float) -> void:
		if h != handle:
			return
		if text != "":
			_status.text = text
		if fraction >= 0.0:
			_progress.value = fraction * 100.0


# --- World actions ---------------------------------------------------------------

func _activate_selected() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	var h := handle
	var res: Dictionary = await h.call_op("world_activate", {"folder": w.folder})
	if not res.ok:
		Notifier.error(str(res.error))
		return
	Notifier.success("%s will load \"%s\" on the next start." % [h.config.display_name, w.name])
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
	var h := handle
	_set_busy(true, "Exporting %s…" % w.name)
	var res: Dictionary = await h.call_op("world_export", {"folder": w.folder, "dest": zip_path}, _progress_for(h))
	_set_busy(false, "")
	if not res.ok:
		_status.text = str(res.error)
		Notifier.error("Export failed: %s" % res.error)
		return
	_status.text = "Exported to %s" % zip_path
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
	var h := handle
	_set_busy(true, "Resetting %s…" % w.name)
	var res: Dictionary = await h.call_op("world_reset", {"folder": w.folder, "seed": _seed_edit.text, "keep_players": _keep_players_check.button_pressed})
	_set_busy(false, "" if res.ok else str(res.error))
	if not res.ok:
		Notifier.error(str(res.error))
	else:
		_status.text = "World reset. A new one is generated on the next start."
		Notifier.success("\"%s\" was reset; a new world is generated on the next start." % w.name)
	refresh()


func _confirm_delete() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	_delete_dialog.dialog_text = "Permanently delete \"%s\" (%s)? This cannot be undone." % [w.name, ", ".join(PackedStringArray(w.folders))]
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var w := _selected_world()
	if w.is_empty():
		return
	var res: Dictionary = await handle.call_op("world_delete", {"folder": w.folder})
	if not res.ok:
		Notifier.error(str(res.error))
	else:
		Notifier.success("Deleted world \"%s\"." % w.name)
	refresh()


# --- Datapack actions ---------------------------------------------------------------

func _add_pack(source: String) -> void:
	if _active_world().is_empty() or _busy:
		return
	var h := handle
	_set_busy(true, "Adding %s…" % source.get_file())
	var res: Dictionary = await h.call_op("datapack_add", {"files": [source]}, _progress_for(h))
	_set_busy(false, "")
	if not res.ok:
		Notifier.error(str(res.error))
		return
	var name := source.trim_suffix("/").get_file()
	if res.online:
		Notifier.success("Added %s. Run /reload (or restart) to load it." % name)
	else:
		Notifier.success("Added %s. It loads on the next start." % name)
	refresh()


func _toggle_pack(enable: bool) -> void:
	var p := _selected_pack()
	if p.is_empty() or not _online:
		return
	var h := handle
	var res: Dictionary = await h.call_op("datapack_toggle", {"id": p.id, "enable": enable})
	if not res.ok:
		Notifier.error(str(res.error))
	if h != handle:
		return
	var updated: Dictionary = await h.call_op("worlds_list", {"sizes": false})
	if h == handle and updated.get("ok", false):
		_online = bool(updated.online)
		_online_enabled = PackedStringArray(updated.online_enabled)
		_online_available = PackedStringArray(updated.online_available)
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
	var res: Dictionary = await handle.call_op("datapack_remove", {"id": p.id})
	if not res.ok:
		Notifier.error(str(res.error))
	else:
		Notifier.success("Removed %s." % p.name)
	refresh()
