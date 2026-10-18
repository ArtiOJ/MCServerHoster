class_name PlayersTab
extends ServerTab
## Online players with moderation actions, plus whitelist / operator / ban lists.
## List edits go through console commands so the server resolves UUIDs itself.

const OFFLINE_HINT := "Start the server to modify these lists."
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
	_whitelist_panel.add_requested.connect(_list_command.bind("whitelist add %s"))
	_whitelist_panel.remove_requested.connect(_list_command.bind("whitelist remove %s"))
	_ops_panel.add_requested.connect(_list_command.bind("op %s"))
	_ops_panel.remove_requested.connect(_list_command.bind("deop %s"))
	_bans_panel.add_requested.connect(_list_command.bind("ban %s"))
	_bans_panel.remove_requested.connect(_list_command.bind("pardon %s"))
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
	var dir := instance.config.directory
	_whitelist_panel.set_names(_read_names(dir.path_join("whitelist.json")))
	_ops_panel.set_names(_read_names(dir.path_join("ops.json")))
	_bans_panel.set_names(_read_names(dir.path_join("banned-players.json")))
	var online := instance.is_online()
	var hint := "" if online else OFFLINE_HINT
	for panel in [_whitelist_panel, _ops_panel, _bans_panel]:
		panel.set_editable(online, hint)
	_whitelist_toggle.set_pressed_no_signal(instance.get_properties().get_bool("white-list", false))
	_whitelist_toggle.disabled = instance.state in [ServerInstance.State.STARTING, ServerInstance.State.STOPPING, ServerInstance.State.INSTALLING]


## Names from a vanilla player list file (array of objects with a "name" field).
static func _read_names(path: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not FileAccess.file_exists(path):
		return out
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Array:
		for entry in data:
			if entry is Dictionary and entry.has("name"):
				out.append(str(entry.name))
	return out


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


func _list_command(player_name: String, template: String) -> void:
	if instance == null or not instance.is_online():
		Notifier.warn(OFFLINE_HINT)
		return
	instance.send_command(template % player_name)
	_reload_timer.start(RELOAD_DELAY_SEC)


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
