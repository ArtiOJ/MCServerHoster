class_name PlayersTab
extends ServerTab
## Online players with moderation actions, plus whitelist / operator / ban / IP-ban lists.
## The lists are editable whether or not the server runs: a running server gets console
## commands (so it stays in sync and resolves UUIDs itself); a stopped server's list files
## are edited directly (see ServerOps), which resolves UUIDs from usercache.json, Mojang,
## or the offline-mode algorithm. Works the same for servers on other computers.

const KIND_NAMES := ServerOps.LIST_KINDS
## Delay before re-reading the lists after a command changed them.
const RELOAD_DELAY_SEC := 1.5

## The last list snapshot: {mode, online_uuids, whitelist_on, default_level, lists}.
var _state := {}
var _serial := 0

@onready var _online_list: ItemList = %OnlineList
@onready var _count_label: Label = %CountLabel
@onready var _offline_label: Label = %OfflineLabel
@onready var _message_edit: LineEdit = %MessageEdit
@onready var _op_button: Button = %OpButton
@onready var _deop_button: Button = %DeopButton
@onready var _kick_button: Button = %KickButton
@onready var _ban_button: Button = %BanButton
@onready var _message_button: Button = %MessageButton
@onready var _whitelist_toggle: CheckButton = %WhitelistToggle
@onready var _whitelist_panel: PlayerListPanel = %WhitelistPanel
@onready var _ops_panel: PlayerListPanel = %OpsPanel
@onready var _bans_panel: PlayerListPanel = %BansPanel
@onready var _ip_bans_panel: PlayerListPanel = %IpBansPanel
@onready var _lists_hint: Label = %ListsHint
@onready var _reload_timer: Timer = %ReloadTimer


func _ready() -> void:
	_online_list.item_selected.connect(_update_actions.unbind(1))
	_online_list.empty_clicked.connect(func(_p: Vector2, _b: int) -> void:
		_online_list.deselect_all()
		_update_actions())
	_op_button.pressed.connect(_player_command.bind("op %s"))
	_deop_button.pressed.connect(_player_command.bind("deop %s"))
	_ban_button.pressed.connect(_on_ban)
	_kick_button.pressed.connect(_on_kick)
	_message_button.pressed.connect(_on_message)
	_message_edit.text_changed.connect(_update_actions.unbind(1))
	_whitelist_toggle.toggled.connect(_on_whitelist_toggled)
	for pair in [[_whitelist_panel, PlayerLists.Kind.WHITELIST], [_ops_panel, PlayerLists.Kind.OPS], [_bans_panel, PlayerLists.Kind.BANS], [_ip_bans_panel, PlayerLists.Kind.IP_BANS]]:
		var panel: PlayerListPanel = pair[0]
		var kind: PlayerLists.Kind = pair[1]
		panel.add_requested.connect(func(value: String, options: Dictionary) -> void: _on_panel_add(panel, kind, value, options))
		panel.remove_requested.connect(func(value: String) -> void: _on_panel_remove(panel, kind, value))
	_ops_panel.level_change_requested.connect(func(player: String, level: int) -> void:
		var result: Dictionary = await change_op_level(player, level)
		_ops_panel.set_status("" if result.ok else result.message, not result.ok))
	_reload_timer.timeout.connect(_refresh_lists)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and handle != null:
			_refresh_all())


func _on_bound() -> void:
	_state = {}
	watch(handle.players_changed, _refresh_online)
	watch(handle.state_changed, _refresh_all.unbind(1))
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"lists":
			_refresh_lists())
	_refresh_all()


func _refresh_all() -> void:
	_refresh_online()
	_refresh_lists()


func _refresh_online() -> void:
	if handle == null:
		return
	var online := handle.is_online()
	var selected := _selected_player()
	_online_list.clear()
	for p in handle.players:
		var idx := _online_list.add_item(p)
		if p == selected:
			_online_list.select(idx)
	_count_label.text = "%d / %d" % [handle.players.size(), handle.max_players] if online else "offline"
	_offline_label.visible = not online or handle.players.is_empty()
	_offline_label.text = "No players online." if online else "The server is not running."
	_update_actions()


func _refresh_lists() -> void:
	if handle == null:
		return
	_serial += 1
	var serial := _serial
	var res: Dictionary = await handle.call_op("lists_get")
	if serial != _serial or handle == null:
		return
	if not res.ok:
		_lists_hint.text = str(res.error)
		return
	_state = res
	var lists: Dictionary = res.lists
	_whitelist_panel.set_entries(_rows(lists.get("whitelist", [])))
	_ops_panel.set_entries(_rows(lists.get("ops", [])))
	_bans_panel.set_entries(_rows(lists.get("bans", [])))
	_ip_bans_panel.set_entries(_rows(lists.get("ip_bans", [])))
	_ops_panel.set_default_level(int(res.default_level))
	var mode := _edit_mode()
	var hint := ""
	match mode:
		"files":
			hint = "The server is stopped: changes are saved to the list files and apply when it starts."
			if not res.online_uuids:
				hint += " This is an offline-mode server, so player UUIDs are derived from their names (names are case-sensitive)."
		"commands":
			hint = "Changes are sent to the running server as commands."
		_:
			if handle.is_read_only():
				hint = "Re-attached without RCON, so commands can't be sent. Restart the server from Server Manager to edit these lists."
			else:
				hint = "Wait until the server has finished starting or stopping."
	_lists_hint.text = hint
	for panel: PlayerListPanel in [_whitelist_panel, _ops_panel, _bans_panel, _ip_bans_panel]:
		panel.set_editable(mode != "", "", mode == "files")
	_whitelist_toggle.set_pressed_no_signal(bool(res.whitelist_on))
	_whitelist_toggle.disabled = handle.state in [ServerHandle.State.STARTING, ServerHandle.State.STOPPING, ServerHandle.State.INSTALLING]


## Rows for a PlayerListPanel (levels arrive as JSON numbers).
static func _rows(entries: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in entries:
		var row: Dictionary = e
		if row.has("level"):
			row["level"] = int(row.level)
		out.append(row)
	return out


## How list edits are applied right now: "files" (server stopped), "commands" (running), or "" (not possible).
func _edit_mode() -> String:
	if handle == null or handle.state in [ServerHandle.State.STARTING, ServerHandle.State.STOPPING, ServerHandle.State.INSTALLING]:
		return ""
	if handle.is_process_alive():
		return "commands" if handle.can_send_commands() and handle.is_online() else ""
	return "files"


## Adds [param value] (player name, or IP for IP bans) to a list. Returns {ok, message}.
func add_entry(kind: PlayerLists.Kind, value: String, options := {}) -> Dictionary:
	var res: Dictionary = await handle.call_op("list_add", {"kind": KIND_NAMES[kind], "value": value, "options": options})
	_after_change(res)
	return {"ok": res.ok, "message": str(res.get("error", ""))}


func remove_entry(kind: PlayerLists.Kind, value: String) -> Dictionary:
	var res: Dictionary = await handle.call_op("list_remove", {"kind": KIND_NAMES[kind], "value": value})
	_after_change(res)
	return {"ok": res.ok, "message": str(res.get("error", ""))}


## Changes an operator's permission level (only while the server is stopped).
func change_op_level(player: String, level: int) -> Dictionary:
	var res: Dictionary = await handle.call_op("op_level", {"player": player, "level": level})
	_after_change(res)
	return {"ok": res.ok, "message": str(res.get("error", ""))}


## The running server rewrites its list files shortly after a command.
func _after_change(res: Dictionary) -> void:
	if res.get("via_command", false):
		_reload_timer.start(RELOAD_DELAY_SEC)
	else:
		_refresh_lists()


func _on_panel_add(panel: PlayerListPanel, kind: PlayerLists.Kind, value: String, options: Dictionary) -> void:
	if _edit_mode() == "files" and kind != PlayerLists.Kind.IP_BANS:
		panel.set_status("Adding %s…" % value)
	var result: Dictionary = await add_entry(kind, value, options)
	panel.set_status("" if result.ok else result.message, not result.ok)


func _on_panel_remove(panel: PlayerListPanel, kind: PlayerLists.Kind, value: String) -> void:
	var result: Dictionary = await remove_entry(kind, value)
	panel.set_status("" if result.ok else result.message, not result.ok)


func _selected_player() -> String:
	var sel := _online_list.get_selected_items()
	return _online_list.get_item_text(sel[0]) if not sel.is_empty() else ""


func _update_actions() -> void:
	var can_act := handle != null and handle.is_online() and handle.can_send_commands() and _selected_player() != ""
	for b in [_op_button, _deop_button, _kick_button, _ban_button]:
		b.disabled = not can_act
	_message_button.disabled = not can_act or _message_edit.text.strip_edges() == ""


func _player_command(template: String) -> void:
	var player := _selected_player()
	if player == "" or not handle.is_online():
		return
	handle.send_command(template % player)
	_reload_timer.start(RELOAD_DELAY_SEC)


func _with_reason(command: String) -> String:
	var reason := _message_edit.text.strip_edges()
	return command if reason == "" else "%s %s" % [command, reason]


func _on_kick() -> void:
	var player := _selected_player()
	if player != "" and handle.is_online():
		handle.send_command(_with_reason("kick " + player))
		_message_edit.clear()
		_update_actions()


func _on_ban() -> void:
	var player := _selected_player()
	if player != "" and handle.is_online():
		handle.send_command(_with_reason("ban " + player))
		_message_edit.clear()
		_reload_timer.start(RELOAD_DELAY_SEC)
		_update_actions()


func _on_message() -> void:
	var player := _selected_player()
	var text := _message_edit.text.strip_edges()
	if player != "" and text != "" and handle.is_online():
		handle.send_command("tell %s %s" % [player, text])
		_message_edit.clear()
		_update_actions()


func _on_whitelist_toggled(enabled: bool) -> void:
	if handle == null:
		return
	var h := handle
	var res: Dictionary = await h.call_op("whitelist_set", {"enabled": enabled})
	if not res.ok:
		Notifier.error(str(res.error))
		if h == handle:
			_whitelist_toggle.set_pressed_no_signal(not enabled)
		return
	if not res.get("via_command", false):
		Notifier.info("Whitelist %s for %s." % ["enabled" if enabled else "disabled", h.config.display_name])
	_after_change(res)
