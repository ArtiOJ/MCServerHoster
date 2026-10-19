class_name PlayersTab
extends ServerTab
## Online players with moderation actions, plus whitelist / operator / ban / IP-ban lists.
## The lists are editable whether or not the server runs: a running server gets console
## commands (so it stays in sync and resolves UUIDs itself); a stopped server's list files
## are edited directly through PlayerLists, which resolves UUIDs from usercache.json,
## Mojang, or the offline-mode algorithm.

## Delay before re-reading a list file after a command changed it.
const RELOAD_DELAY_SEC := 1.0
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
		var result := change_op_level(player, level)
		_ops_panel.set_status("" if result.ok else result.message, not result.ok))
	_reload_timer.timeout.connect(_refresh_lists)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and instance != null:
			_refresh_all())


func _on_bound() -> void:
	watch(instance.players_changed, _refresh_online)
	watch(instance.state_changed, _refresh_all.unbind(1))
	_refresh_all()


func _refresh_all() -> void:
	_refresh_online()
	_refresh_lists()


func _refresh_online() -> void:
	if instance == null:
		return
	var online := instance.is_online()
	var selected := _selected_player()
	_online_list.clear()
	for p in instance.players:
		var idx := _online_list.add_item(p)
		if p == selected:
			_online_list.select(idx)
	_count_label.text = "%d / %d" % [instance.players.size(), instance.max_players] if online else "offline"
	_offline_label.visible = not online or instance.players.is_empty()
	_offline_label.text = "No players online." if online else "The server is not running."
	_update_actions()


func _refresh_lists() -> void:
	if instance == null:
		return
	var dir := _dir()
	_whitelist_panel.set_entries(_panel_entries(dir, PlayerLists.Kind.WHITELIST))
	_ops_panel.set_entries(_panel_entries(dir, PlayerLists.Kind.OPS))
	_bans_panel.set_entries(_panel_entries(dir, PlayerLists.Kind.BANS))
	_ip_bans_panel.set_entries(_panel_entries(dir, PlayerLists.Kind.IP_BANS))
	_ops_panel.set_default_level(instance.get_properties().get_int("op-permission-level", 4))
	var mode := _edit_mode()
	var hint := ""
	match mode:
		"files":
			hint = "The server is stopped: changes are saved to the list files and apply when it starts."
			if not PlayerLists.uses_online_uuids(dir):
				hint += " This is an offline-mode server, so player UUIDs are derived from their names (names are case-sensitive)."
		"commands":
			hint = "Changes are sent to the running server as commands."
		_:
			if instance.is_read_only():
				hint = "Re-attached without RCON, so commands can't be sent. Restart the server from Server Manager to edit these lists."
			else:
				hint = "Wait until the server has finished starting or stopping."
	_lists_hint.text = hint
	for panel: PlayerListPanel in [_whitelist_panel, _ops_panel, _bans_panel, _ip_bans_panel]:
		panel.set_editable(mode != "", "", mode == "files")
	_whitelist_toggle.set_pressed_no_signal(instance.get_properties().get_bool("white-list", false))
	_whitelist_toggle.disabled = instance.state in [ServerInstance.State.STARTING, ServerInstance.State.STOPPING, ServerInstance.State.INSTALLING]


## How list edits are applied right now: "files" (server stopped), "commands" (running), or "" (not possible).
func _edit_mode() -> String:
	if instance == null or instance.state in [ServerInstance.State.STARTING, ServerInstance.State.STOPPING, ServerInstance.State.INSTALLING]:
		return ""
	if instance.is_process_alive():
		return "commands" if instance.can_send_commands() and instance.is_online() else ""
	return "files"


func _dir() -> String:
	return instance.working_directory()


## ItemList rows for one list: {value, text, tooltip, [level]}.
static func _panel_entries(dir: String, kind: PlayerLists.Kind) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in PlayerLists.read(dir, kind):
		var value := str(e.get("ip" if kind == PlayerLists.Kind.IP_BANS else "name", ""))
		if value == "":
			continue
		var row := {"value": value, "text": value}
		var tip := PackedStringArray()
		if e.has("uuid"):
			tip.append("UUID " + str(e.uuid))
		match kind:
			PlayerLists.Kind.OPS:
				var level := int(e.get("level", 4))
				row["level"] = level
				row["text"] = "%s  ·  level %d" % [value, level]
				if bool(e.get("bypassesPlayerLimit", false)):
					tip.append("May join when the server is full")
			PlayerLists.Kind.BANS, PlayerLists.Kind.IP_BANS:
				tip.append("Reason: " + str(e.get("reason", "")))
				tip.append("Banned %s by %s" % [str(e.get("created", "?")), str(e.get("source", "?"))])
				tip.append("Expires: " + str(e.get("expires", "forever")))
		row["tooltip"] = "\n".join(tip)
		out.append(row)
	return out


## Adds [param value] (player name, or IP for IP bans) to a list. Running servers get a
## command; stopped servers' files are edited directly. Returns {ok, message}.
func add_entry(kind: PlayerLists.Kind, value: String, options := {}) -> Dictionary:
	var mode := _edit_mode()
	var reason := str(options.get("reason", "")).strip_edges()
	if mode == "commands":
		match kind:
			PlayerLists.Kind.WHITELIST:
				instance.send_command("whitelist add " + value)
			PlayerLists.Kind.OPS:
				instance.send_command("op " + value)
			PlayerLists.Kind.BANS:
				instance.send_command(("ban %s %s" % [value, reason]).strip_edges())
			PlayerLists.Kind.IP_BANS:
				instance.send_command(("ban-ip %s %s" % [value, reason]).strip_edges())
		_reload_timer.start(RELOAD_DELAY_SEC)
		return {"ok": true, "message": ""}
	if mode != "files":
		return {"ok": false, "message": "Lists can't be changed right now."}
	var dir := _dir()
	var err := OK
	if kind == PlayerLists.Kind.IP_BANS:
		if not PlayerLists.is_valid_ip(value):
			return {"ok": false, "message": "\"%s\" is not an IP address." % value}
		err = PlayerLists.add_ip_ban(dir, value, reason)
	else:
		var profile: Dictionary = await PlayerLists.resolve(self, dir, value)
		if not profile.ok:
			return {"ok": false, "message": profile.error}
		err = PlayerLists.add_player(dir, kind, profile, options)
		value = profile.name
	_refresh_lists()
	if err != OK:
		return {"ok": false, "message": "Could not save %s: %s" % [PlayerLists.FILES[kind], error_string(err)]}
	return {"ok": true, "message": ""}


func remove_entry(kind: PlayerLists.Kind, value: String) -> Dictionary:
	var mode := _edit_mode()
	if mode == "commands":
		var commands := ["whitelist remove %s", "deop %s", "pardon %s", "pardon-ip %s"]
		instance.send_command(commands[kind] % value)
		_reload_timer.start(RELOAD_DELAY_SEC)
		return {"ok": true, "message": ""}
	if mode != "files":
		return {"ok": false, "message": "Lists can't be changed right now."}
	var err := PlayerLists.remove(_dir(), kind, value)
	_refresh_lists()
	if err != OK and err != ERR_DOES_NOT_EXIST:
		return {"ok": false, "message": "Could not save %s: %s" % [PlayerLists.FILES[kind], error_string(err)]}
	return {"ok": true, "message": ""}


## Changes an operator's permission level (only while the server is stopped).
func change_op_level(player: String, level: int) -> Dictionary:
	if _edit_mode() != "files":
		return {"ok": false, "message": "Stop the server to change operator levels."}
	var err := PlayerLists.set_op_level(_dir(), player, level)
	_refresh_lists()
	return {"ok": err == OK, "message": "" if err == OK else "Could not save ops.json: %s" % error_string(err)}


func _on_panel_add(panel: PlayerListPanel, kind: PlayerLists.Kind, value: String, options: Dictionary) -> void:
	if _edit_mode() == "files" and kind != PlayerLists.Kind.IP_BANS and PlayerLists.uses_online_uuids(_dir()) \
			and PlayerLists.usercache_lookup(_dir(), value).is_empty():
		panel.set_status("Looking up %s…" % value)
	var result: Dictionary = await add_entry(kind, value, options)
	panel.set_status("" if result.ok else result.message, not result.ok)


func _on_panel_remove(panel: PlayerListPanel, kind: PlayerLists.Kind, value: String) -> void:
	var result: Dictionary = await remove_entry(kind, value)
	panel.set_status("" if result.ok else result.message, not result.ok)


func _selected_player() -> String:
	var sel := _online_list.get_selected_items()
	return _online_list.get_item_text(sel[0]) if not sel.is_empty() else ""


func _update_actions() -> void:
	var can_act := instance != null and instance.is_online() and _selected_player() != ""
	for b in [_op_button, _deop_button, _kick_button, _ban_button]:
		b.disabled = not can_act
	_message_button.disabled = not can_act or _message_edit.text.strip_edges() == ""


func _player_command(template: String) -> void:
	var player := _selected_player()
	if player == "" or not instance.is_online():
		return
	instance.send_command(template % player)
	_reload_timer.start(RELOAD_DELAY_SEC)


func _with_reason(command: String) -> String:
	var reason := _message_edit.text.strip_edges()
	return command if reason == "" else "%s %s" % [command, reason]


func _on_kick() -> void:
	var player := _selected_player()
	if player != "" and instance.is_online():
		instance.send_command(_with_reason("kick " + player))
		_message_edit.clear()
		_update_actions()


func _on_ban() -> void:
	var player := _selected_player()
	if player != "" and instance.is_online():
		instance.send_command(_with_reason("ban " + player))
		_message_edit.clear()
		_reload_timer.start(RELOAD_DELAY_SEC)
		_update_actions()


func _on_message() -> void:
	var player := _selected_player()
	var text := _message_edit.text.strip_edges()
	if player != "" and text != "" and instance.is_online():
		instance.send_command("tell %s %s" % [player, text])
		_message_edit.clear()
		_update_actions()


func _on_whitelist_toggled(enabled: bool) -> void:
	if instance == null:
		return
	if instance.is_online():
		instance.send_command("whitelist on" if enabled else "whitelist off")
		_reload_timer.start(RELOAD_DELAY_SEC)
		return
	var props := instance.get_properties()
	props.set_value("white-list", enabled)
	var err := props.save_file(instance.config.properties_path())
	if err != OK:
		Notifier.error("Could not update server.properties: %s" % error_string(err))
		_whitelist_toggle.set_pressed_no_signal(not enabled)
		return
	Notifier.info("Whitelist %s for %s." % ["enabled" if enabled else "disabled", instance.config.display_name])
