class_name ConsoleTab
extends ServerTab
## Live server console: coloured output with filtering, plus a command line with
## history (Up/Down) and Tab completion.

enum Filter { ALL, WARNINGS, ERRORS, MANAGER }

const LEVEL_COLORS := {
	LogParser.Level.WARN: "#e5c07b",
	LogParser.Level.ERROR: "#e06c75",
	LogParser.Level.COMMAND: "#7cc4ff",
	LogParser.Level.SYSTEM: "#52cc90",
}
const COMMANDS: PackedStringArray = [
	"advancement", "ban", "ban-ip", "banlist", "clear", "datapack", "defaultgamemode", "deop", "difficulty",
	"effect", "enchant", "execute", "experience", "fill", "gamemode", "gamerule", "give", "help", "kick", "kill",
	"list", "locate", "me", "msg", "mspt", "op", "pardon", "pardon-ip", "particle", "paper", "playsound", "plugins",
	"reload", "save-all", "save-off", "save-on", "say", "scoreboard", "seed", "setblock", "setworldspawn",
	"spawnpoint", "spark", "stop", "summon", "tell", "teleport", "time", "timings", "title", "tp", "tps", "version",
	"weather", "whitelist", "worldborder", "xp",
]

var _history_index := -1
var _draft := ""
var _completion_prefix := ""
var _completion_matches := PackedStringArray()
var _completion_index := 0
var _has_text := false

@onready var _output: RichTextLabel = %Output
@onready var _search: LineEdit = %SearchEdit
@onready var _filter: OptionButton = %FilterOption
@onready var _autoscroll: CheckButton = %AutoscrollCheck
@onready var _clear_button: Button = %ClearButton
@onready var _copy_button: Button = %CopyButton
@onready var _command_edit: LineEdit = %CommandEdit
@onready var _send_button: Button = %SendButton
@onready var _offline_hint: Label = %OfflineHint


func _ready() -> void:
	_search.text_changed.connect(_rebuild.unbind(1))
	_filter.item_selected.connect(_rebuild.unbind(1))
	_autoscroll.toggled.connect(func(on: bool) -> void:
		_output.scroll_following = on
		if on:
			_output.scroll_to_line(_output.get_line_count()))
	_clear_button.pressed.connect(func() -> void: instance.clear_console())
	_copy_button.pressed.connect(_copy_visible)
	_command_edit.text_submitted.connect(_submit)
	_command_edit.gui_input.connect(_on_command_input)
	_send_button.pressed.connect(func() -> void: _submit(_command_edit.text))


func _on_bound() -> void:
	watch(instance.console_line_added, _on_line_added)
	watch(instance.console_cleared, _rebuild)
	watch(instance.state_changed, _update_input_state.unbind(1))
	_history_index = -1
	_rebuild()
	_update_input_state()


func focus_input() -> void:
	if not _command_edit.editable:
		return
	_command_edit.grab_focus()


func _update_input_state() -> void:
	var alive := instance.can_send_commands()
	_command_edit.editable = alive
	_send_button.disabled = not alive
	_offline_hint.visible = not alive
	if instance.is_read_only():
		_offline_hint.text = "Re-attached without RCON: showing logs/latest.log read-only. Restart the server from here for full control."
	else:
		_offline_hint.text = "The server is offline. Start it to send commands."
	_command_edit.placeholder_text = "Type a command — Tab completes, ↑/↓ browse history" if alive else ("Read-only" if instance.is_read_only() else "Server is not running")


func _passes(entry: Dictionary) -> bool:
	var level: int = entry.level
	match _filter.selected:
		Filter.WARNINGS:
			if level != LogParser.Level.WARN and level != LogParser.Level.ERROR:
				return false
		Filter.ERRORS:
			if level != LogParser.Level.ERROR:
				return false
		Filter.MANAGER:
			if level != LogParser.Level.SYSTEM and level != LogParser.Level.COMMAND and not entry.get("system", false):
				return false
	var query := _search.text.strip_edges()
	return query == "" or (entry.plain as String).containsn(query)


func _format(entry: Dictionary) -> String:
	return Ansi.to_bbcode(entry.text, LEVEL_COLORS.get(entry.level, ""))


func _on_line_added(entry: Dictionary) -> void:
	if not _passes(entry):
		return
	_output.append_text(("\n" if _has_text else "") + _format(entry))
	_has_text = true
	var limit := AppSettings.console_max_lines
	if _output.get_paragraph_count() > limit + 200:
		for i in _output.get_paragraph_count() - limit:
			_output.remove_paragraph(0, true)
		_output.invalidate_paragraph(0)


func _rebuild() -> void:
	if instance == null:
		return
	_output.clear()
	var parts := PackedStringArray()
	for entry in instance.console_lines:
		if _passes(entry):
			parts.append(_format(entry))
	_has_text = not parts.is_empty()
	_output.append_text("\n".join(parts))
	if _autoscroll.button_pressed:
		_output.scroll_to_line(_output.get_line_count())


func _copy_visible() -> void:
	var lines := PackedStringArray()
	for entry in instance.console_lines:
		if _passes(entry):
			lines.append(entry.plain)
	DisplayServer.clipboard_set("\n".join(lines))
	Notifier.info("Copied %d console lines." % lines.size())


func _submit(text: String) -> void:
	if text.strip_edges() == "":
		return
	if instance.send_command(text):
		_command_edit.clear()
		_history_index = -1
		_draft = ""
	_command_edit.grab_focus.call_deferred()
	_completion_matches.clear()


func _on_command_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.keycode:
		KEY_UP:
			_browse_history(-1)
			_command_edit.accept_event()
		KEY_DOWN:
			_browse_history(1)
			_command_edit.accept_event()
		KEY_TAB:
			_complete()
			_command_edit.accept_event()
		_:
			if key.unicode != 0 or key.keycode == KEY_BACKSPACE:
				_completion_matches.clear()


func _browse_history(direction: int) -> void:
	var history := instance.command_history
	if history.is_empty():
		return
	if _history_index == -1:
		if direction > 0:
			return
		_draft = _command_edit.text
		_history_index = history.size() - 1
	else:
		_history_index += direction
	if _history_index >= history.size():
		_history_index = -1
		_command_edit.text = _draft
	else:
		_history_index = clampi(_history_index, 0, history.size() - 1)
		_command_edit.text = history[_history_index]
	_command_edit.caret_column = _command_edit.text.length()


## Completes the command name, or a player name for later words. Repeated Tab cycles matches.
func _complete() -> void:
	if _completion_matches.is_empty():
		var text := _command_edit.text
		var words := text.split(" ")
		var current := words[-1]
		var candidates := COMMANDS if words.size() == 1 else instance.players
		_completion_prefix = text.substr(0, text.length() - current.length())
		_completion_matches.clear()
		for c in candidates:
			if c.to_lower().begins_with(current.to_lower().trim_prefix("/")):
				_completion_matches.append(c)
		_completion_index = 0
		if _completion_matches.is_empty():
			return
	else:
		_completion_index = (_completion_index + 1) % _completion_matches.size()
	var chosen := _completion_matches[_completion_index]
	_command_edit.text = _completion_prefix + chosen + (" " if _completion_matches.size() == 1 else "")
	_command_edit.caret_column = _command_edit.text.length()
