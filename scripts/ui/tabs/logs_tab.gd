class_name LogsTab
extends ServerTab
## Browses a server's log history (current session, rotated archives) and crash
## reports. Files are read and filtered on a worker thread so large logs never
## freeze the window; crash reports get a short plain-language summary.

## Most lines shown at once; older matching lines are left out (noted in the status line).
const MAX_DISPLAY_LINES := 20000
const LEVEL_COLORS := {
	LogParser.Level.WARN: "#e5c07b",
	LogParser.Level.ERROR: "#e06c75",
}
const CRASH_COLOR := Color("e06c75")
const CURRENT_COLOR := Color("52cc90")

var _entries: Array[Dictionary] = []
var _selected_path := ""
var _text := ""
var _visible_lines := PackedStringArray()
var _load_serial := 0

@onready var _file_list: ItemList = %FileList
@onready var _empty_label: Label = %EmptyLabel
@onready var _refresh_button: Button = %RefreshButton
@onready var _search: LineEdit = %SearchEdit
@onready var _filter: OptionButton = %FilterOption
@onready var _copy_button: Button = %CopyButton
@onready var _save_button: Button = %SaveButton
@onready var _open_folder_button: Button = %OpenFolderButton
@onready var _crash_card: PanelContainer = %CrashCard
@onready var _crash_title: Label = %CrashTitle
@onready var _crash_reason: Label = %CrashReason
@onready var _crash_exception: Label = %CrashException
@onready var _crash_meta: Label = %CrashMeta
@onready var _viewer: RichTextLabel = %Viewer
@onready var _status: Label = %StatusLabel
@onready var _save_dialog: FileDialog = %SaveDialog


func _ready() -> void:
	_file_list.item_selected.connect(func(i: int) -> void: _open(_entries[i]))
	_refresh_button.pressed.connect(refresh)
	_search.text_changed.connect(func(_t: String) -> void: _apply_filter())
	_filter.item_selected.connect(func(_i: int) -> void: _apply_filter())
	_copy_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set("\n".join(_visible_lines))
		Notifier.info("Copied %d log lines." % _visible_lines.size()))
	_save_button.pressed.connect(func() -> void:
		_save_dialog.current_file = _selected_path.get_file().trim_suffix(".gz")
		_save_dialog.popup_centered())
	_save_dialog.file_selected.connect(_save_to)
	_open_folder_button.pressed.connect(func() -> void:
		if _selected_path != "":
			OS.shell_open(_selected_path.get_base_dir()))
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and instance != null:
			refresh())
	_set_file_actions_enabled(false)


func _on_bound() -> void:
	_selected_path = ""
	_text = ""
	_viewer.clear()
	_crash_card.visible = false
	_status.text = ""
	if is_visible_in_tree():
		refresh()


## Re-scans the log folders and reloads the selected file (or the newest one).
func refresh() -> void:
	if instance == null:
		return
	_entries = LogArchive.list_entries(instance.working_directory())
	_file_list.clear()
	var select := -1
	for i in _entries.size():
		var e := _entries[i]
		var idx := _file_list.add_item(e.label)
		_file_list.set_item_tooltip(idx, "%s\n%s · %s" % [e.path, Fmt.bytes(e.size), Fmt.datetime(e.time)])
		if e.kind == LogArchive.Kind.CRASH:
			_file_list.set_item_custom_fg_color(idx, CRASH_COLOR)
		elif e.kind == LogArchive.Kind.CURRENT:
			_file_list.set_item_custom_fg_color(idx, CURRENT_COLOR)
		if e.path == _selected_path:
			select = i
	_empty_label.visible = _entries.is_empty()
	if _entries.is_empty():
		_selected_path = ""
		_viewer.clear()
		_crash_card.visible = false
		_status.text = ""
		_set_file_actions_enabled(false)
		return
	if select < 0:
		select = 0
	_file_list.select(select)
	_open(_entries[select])


func _open(entry: Dictionary) -> void:
	_selected_path = entry.path
	_load_serial += 1
	var serial := _load_serial
	_status.text = "Loading %s…" % entry.name
	_set_file_actions_enabled(false)
	var path: String = entry.path
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary: return LogArchive.read_text(path))
	if serial != _load_serial:
		return  # Another file was selected meanwhile.
	if not result.ok:
		_text = ""
		_viewer.clear()
		_crash_card.visible = false
		_status.text = result.error
		return
	_text = result.text
	_show_crash_summary(entry)
	_set_file_actions_enabled(true)
	await _apply_filter(result.truncated)


func _show_crash_summary(entry: Dictionary) -> void:
	_crash_card.visible = entry.kind == LogArchive.Kind.CRASH
	if not _crash_card.visible:
		return
	var s := LogArchive.summarize_crash(_text)
	_crash_title.text = s.description if s.description != "" else "Crash report"
	_crash_reason.text = s.hint
	_crash_reason.visible = s.hint != ""
	var details := PackedStringArray()
	if s.exception != "":
		details.append(s.exception)
	if s.cause != "":
		details.append("Caused by: " + s.cause)
	_crash_exception.text = "\n".join(details)
	_crash_exception.visible = not details.is_empty()
	var meta := PackedStringArray()
	if s.time != "":
		meta.append(s.time)
	if s.server != "":
		meta.append(s.server)
	elif s.minecraft != "":
		meta.append("Minecraft " + s.minecraft)
	_crash_meta.text = " · ".join(meta)


func _apply_filter(source_truncated := false) -> void:
	if _selected_path == "":
		return
	_load_serial += 1
	var serial := _load_serial
	var text := _text
	var query := _search.text
	var level := _filter.selected
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary:
		var r := LogArchive.filter_lines(text, query, level, MAX_DISPLAY_LINES)
		r.bbcode = _to_bbcode(r.lines)
		return r)
	if serial != _load_serial:
		return
	_visible_lines = result.lines
	_viewer.clear()
	_viewer.append_text(result.bbcode)
	# Logs are read from the end (newest lines); crash reports from the top, where the error is.
	_viewer.scroll_to_line(0 if _crash_card.visible else _viewer.get_line_count())
	var parts := PackedStringArray()
	if query.strip_edges() != "" or level != 0:
		parts.append("%d of %d lines match" % [result.matched, result.total])
	else:
		parts.append("%d lines" % result.total)
	if result.truncated:
		parts.append("showing the last %d" % MAX_DISPLAY_LINES)
	if source_truncated:
		parts.append("only the last %s of the file was read" % Fmt.bytes(LogArchive.MAX_BYTES))
	parts.append(_selected_path.get_file())
	_status.text = " · ".join(parts)


## Runs on the worker thread: colours lines by level (stack traces follow their message).
static func _to_bbcode(lines: PackedStringArray) -> String:
	var out := PackedStringArray()
	var current := LogParser.Level.INFO
	for line in lines:
		var level := LogParser.level_of(Ansi.strip(line))
		if level == LogParser.Level.OTHER:
			level = current
		else:
			current = level
		out.append(Ansi.to_bbcode(line, LEVEL_COLORS.get(level, "")))
	return "\n".join(out)


func _save_to(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		Notifier.error("Could not save the log: %s" % error_string(FileAccess.get_open_error()))
		return
	f.store_string(_text)
	f.close()
	Notifier.success("Saved %s." % path.get_file())


func _set_file_actions_enabled(enabled: bool) -> void:
	for b: Button in [_copy_button, _save_button, _open_folder_button]:
		b.disabled = not enabled
