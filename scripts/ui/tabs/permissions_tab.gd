class_name PermissionsTab
extends ServerTab
## LuckPerms groups, players and tracks (see LuckPerms and ServerOps.perms_*). Changes need
## the server running, since LuckPerms only takes them there; a stopped server shows what
## was read last, read-only. Works the same for servers on other computers.

enum Section { GROUPS, PLAYERS, TRACKS }
enum Column { NODE, VALUE, WHERE, EXPIRES }

const ALLOW_COLOR := Color("3fb97f")
const DENY_COLOR := Color("e5534b")
const MUTED_COLOR := Color("8b93a3")
const ADD_PLACEHOLDERS: PackedStringArray = ["New group", "Find player by name", "New track"]
const ADD_LABELS: PackedStringArray = ["Create", "Find", "Create"]

## The last perms_get / perms_apply result.
var _state := {}
## Players looked up by name that LuckPerms has no data for yet: [{uuid, name}].
var _found_players := []
## The selected group name, player UUID or track name.
var _selected := ""
var _serial := 0
var _busy := false

@onready var _refresh_button: Button = %RefreshButton
@onready var _status_label: Label = %StatusLabel
@onready var _install_button: Button = %InstallButton
@onready var _notice: PanelContainer = %Notice
@onready var _notice_label: Label = %NoticeLabel
@onready var _body: HSplitContainer = %Body
@onready var _section_bar: TabBar = %SectionBar
@onready var _filter_edit: LineEdit = %FilterEdit
@onready var _list: ItemList = %HolderList
@onready var _new_edit: LineEdit = %NewEdit
@onready var _add_button: Button = %AddButton
@onready var _delete_button: Button = %DeleteButton
@onready var _title_label: Label = %TitleLabel
@onready var _subtitle_label: Label = %SubtitleLabel
@onready var _empty_label: Label = %EmptyLabel
@onready var _group_settings: HBoxContainer = %GroupSettings
@onready var _weight_spin: SpinBox = %WeightSpin
@onready var _prefix_edit: LineEdit = %PrefixEdit
@onready var _save_group_button: Button = %SaveGroupButton
@onready var _parents_section: VBoxContainer = %ParentsSection
@onready var _parents_label: Label = %ParentsLabel
@onready var _parents_list: ItemList = %ParentsList
@onready var _parent_option: OptionButton = %ParentOption
@onready var _add_parent_button: Button = %AddParentButton
@onready var _remove_parent_button: Button = %RemoveParentButton
@onready var _track_row: HBoxContainer = %TrackRow
@onready var _track_option: OptionButton = %TrackOption
@onready var _promote_button: Button = %PromoteButton
@onready var _demote_button: Button = %DemoteButton
@onready var _perms_section: VBoxContainer = %PermsSection
@onready var _perm_tree: Tree = %PermTree
@onready var _node_edit: LineEdit = %NodeEdit
@onready var _value_option: OptionButton = %ValueOption
@onready var _where_edit: LineEdit = %WhereEdit
@onready var _duration_edit: LineEdit = %DurationEdit
@onready var _add_perm_button: Button = %AddPermButton
@onready var _toggle_button: Button = %ToggleButton
@onready var _remove_perm_button: Button = %RemovePermButton
@onready var _track_section: VBoxContainer = %TrackSection
@onready var _track_groups: ItemList = %TrackGroups
@onready var _track_group_option: OptionButton = %TrackGroupOption
@onready var _append_button: Button = %AppendButton
@onready var _up_button: Button = %UpButton
@onready var _down_button: Button = %DownButton
@onready var _remove_track_group_button: Button = %RemoveTrackGroupButton
@onready var _delete_dialog: ConfirmationDialog = %DeleteDialog


func _ready() -> void:
	_perm_tree.set_column_title(Column.NODE, "Permission")
	_perm_tree.set_column_title(Column.VALUE, "Value")
	_perm_tree.set_column_title(Column.WHERE, "Where")
	_perm_tree.set_column_title(Column.EXPIRES, "Expires")
	_perm_tree.set_column_expand(Column.NODE, true)
	_perm_tree.set_column_expand_ratio(Column.NODE, 3)
	_perm_tree.set_column_expand(Column.WHERE, true)
	for col in [Column.VALUE, Column.EXPIRES]:
		_perm_tree.set_column_expand(col, false)
		_perm_tree.set_column_custom_minimum_width(col, 130 if col == Column.EXPIRES else 80)
	_refresh_button.pressed.connect(refresh)
	_install_button.pressed.connect(_install)
	_section_bar.tab_changed.connect(func(_t: int) -> void:
		_selected = ""
		_filter_edit.text = ""
		_new_edit.text = ""
		_rebuild())
	_filter_edit.text_changed.connect(_rebuild_list.unbind(1))
	_list.item_selected.connect(func(index: int) -> void:
		_selected = str(_list.get_item_metadata(index))
		_rebuild_detail())
	_new_edit.text_submitted.connect(_add_holder.unbind(1))
	_new_edit.text_changed.connect(_update_controls.unbind(1))
	_add_button.pressed.connect(_add_holder)
	_delete_button.pressed.connect(_confirm_delete)
	_delete_dialog.confirmed.connect(_delete_selected)
	_save_group_button.pressed.connect(_save_group)
	_weight_spin.value_changed.connect(_update_controls.unbind(1))
	_prefix_edit.text_changed.connect(_update_controls.unbind(1))
	_parents_list.item_selected.connect(_update_controls.unbind(1))
	_add_parent_button.pressed.connect(_add_parent)
	_remove_parent_button.pressed.connect(_remove_parent)
	_promote_button.pressed.connect(_move_on_track.bind("promote"))
	_demote_button.pressed.connect(_move_on_track.bind("demote"))
	_perm_tree.item_selected.connect(_update_controls)
	_perm_tree.nothing_selected.connect(func() -> void:
		_perm_tree.deselect_all()
		_update_controls())
	_node_edit.text_changed.connect(_update_controls.unbind(1))
	_node_edit.text_submitted.connect(_add_permission.unbind(1))
	_add_perm_button.pressed.connect(_add_permission)
	_toggle_button.pressed.connect(_toggle_permission)
	_remove_perm_button.pressed.connect(_remove_permission)
	_track_groups.item_selected.connect(_update_controls.unbind(1))
	_append_button.pressed.connect(_append_to_track)
	_up_button.pressed.connect(_move_in_track.bind(-1))
	_down_button.pressed.connect(_move_in_track.bind(1))
	_remove_track_group_button.pressed.connect(_remove_from_track)
	visibility_changed.connect(func() -> void:
		if is_visible_in_tree() and handle != null:
			refresh())


func _on_bound() -> void:
	_state = {}
	_found_players = []
	_selected = ""
	_rebuild()
	watch(handle.state_changed, func(_s: ServerHandle.State) -> void:
		if is_visible_in_tree() and (handle.is_online() or not handle.is_process_alive()):
			refresh())
	watch(handle.data_changed, func(area: StringName) -> void:
		if area in [&"permissions", &"plugins"] and is_visible_in_tree():
			refresh())
	if is_visible_in_tree():
		refresh()


func refresh() -> void:
	if handle == null or _busy:
		return
	_serial += 1
	var serial := _serial
	var h := handle
	_status_label.text = "Reading permissions…"
	var res: Dictionary = await h.call_op("perms_get")
	if serial != _serial or h != handle:
		return
	if not res.ok:
		_status_label.text = str(res.error)
		return
	_state = res
	_rebuild()


# --- Showing ----------------------------------------------------------------------

func _section() -> Section:
	return _section_bar.current_tab as Section


func _editable() -> bool:
	return bool(_state.get("editable", false)) and not _busy


func _rebuild() -> void:
	var installed := bool(_state.get("installed", false))
	_install_button.visible = not _state.is_empty() and not installed
	var parts := PackedStringArray()
	if installed:
		parts.append("LuckPerms %s" % _state.version if str(_state.get("version", "")) != "" else "LuckPerms")
		parts.append(_count(_state.get("groups", []).size(), "group"))
		parts.append(_count(_state.get("players", []).size(), "player"))
		parts.append(_count(_state.get("tracks", []).size(), "track"))
	_status_label.text = " · ".join(parts)
	var note := str(_state.get("note", ""))
	if bool(_state.get("restart_needed", false)):
		note = "Restart the server to load LuckPerms."
	elif not _state.get("live", false) and int(_state.get("read_at", 0)) > 0:
		note += " Showing the permissions read %s." % Fmt.datetime(int(_state.read_at))
	if not installed and not _state.is_empty():
		note = "LuckPerms isn't installed on this server. Install it to manage groups, players and permissions here; it loads on the next start."
	_notice.visible = note.strip_edges() != ""
	_notice_label.text = note.strip_edges()
	_body.visible = installed or not _state.get("groups", []).is_empty()
	_new_edit.placeholder_text = ADD_PLACEHOLDERS[_section()]
	_add_button.text = ADD_LABELS[_section()]
	_delete_button.visible = _section() != Section.PLAYERS
	_rebuild_list()
	_rebuild_detail()


func _count(n: int, word: String) -> String:
	return "%d %s%s" % [n, word, "" if n == 1 else "s"]


func _rebuild_list() -> void:
	_list.clear()
	var filter := _filter_edit.text.strip_edges().to_lower()
	for entry in _entries():
		var label: String = entry[0]
		if filter != "" and not label.to_lower().contains(filter):
			continue
		var index := _list.add_item(label)
		_list.set_item_metadata(index, entry[1])
		_list.set_item_tooltip(index, entry[2])
		if entry[1] == _selected:
			_list.select(index)
	_update_controls()


## [label, key, tooltip] for each item of the current section.
func _entries() -> Array:
	var out := []
	match _section():
		Section.GROUPS:
			for g in _state.get("groups", []):
				var prefix := str(g.prefixes[0].text) if not g.prefixes.is_empty() else ""
				out.append([str(g.name), str(g.name), "Weight %d%s" % [int(g.weight), (" · prefix " + prefix) if prefix != "" else ""]])
		Section.PLAYERS:
			var seen := {}
			for p in _state.get("players", []) + _found_players:
				if seen.has(str(p.uuid)):
					continue
				seen[str(p.uuid)] = true
				out.append([_player_name(str(p.uuid)), str(p.uuid), str(p.uuid)])
		Section.TRACKS:
			for t in _state.get("tracks", []):
				out.append([str(t.name), str(t.name), " → ".join(PackedStringArray(t.groups))])
	return out


func _group(name: String) -> Variant:
	return LuckPerms.find(_state, "group", name)


func _user(uuid: String) -> Variant:
	return LuckPerms.find(_state, "user", uuid)


func _track(name: String) -> Variant:
	for t in _state.get("tracks", []):
		if str(t.name) == name:
			return t
	return null


## The player's name from any source that knows it (LuckPerms, usercache.json or a lookup).
func _player_name(uuid: String) -> String:
	for p in _state.get("players", []) + _found_players:
		if str(p.uuid) == uuid and str(p.name) != "":
			return str(p.name)
	return uuid


## The selected group or player as a LuckPerms holder ({} for a player without data yet).
func _holder() -> Variant:
	match _section():
		Section.GROUPS:
			return _group(_selected)
		Section.PLAYERS:
			if _selected == "":
				return null
			var user: Variant = _user(_selected)
			return user if user != null else {"uuid": _selected, "parents": [], "permissions": [], "other": [], "prefixes": [], "suffixes": []}
	return null


func _rebuild_detail() -> void:
	var holder: Variant = _holder()
	var track: Variant = _track(_selected) if _section() == Section.TRACKS else null
	var shown := holder != null or track != null
	_empty_label.visible = not shown
	_empty_label.text = "Choose a group, player or track." if not _state.get("groups", []).is_empty() or _state.get("live", false) else ""
	_group_settings.visible = holder != null and _section() == Section.GROUPS
	_parents_section.visible = holder != null
	_perms_section.visible = holder != null
	_track_section.visible = track != null
	_title_label.text = ""
	_subtitle_label.text = ""
	if holder != null:
		_show_holder(holder)
	elif track != null:
		_show_track(track)
	_update_controls()


func _show_holder(holder: Dictionary) -> void:
	var is_group := _section() == Section.GROUPS
	if is_group:
		_title_label.text = str(holder.name)
		_subtitle_label.text = "Group"
		_weight_spin.set_value_no_signal(int(holder.weight))
		_prefix_edit.text = str(holder.prefixes[0].text) if not holder.prefixes.is_empty() else ""
		_parents_label.text = "Inherits from"
		_parents_label.tooltip_text = "Members of this group also get these groups' permissions."
	else:
		_title_label.text = _player_name(str(holder.uuid))
		_subtitle_label.text = str(holder.uuid)
		_parents_label.text = "Groups"
		_parents_label.tooltip_text = "The player gets the permissions of these groups."
	_parents_list.clear()
	for p in holder.parents:
		var text := str(p.group)
		if str(p.context) != "":
			text += " (%s)" % p.context
		if int(p.expiry) > 0:
			text += " until %s" % Fmt.datetime(int(p.expiry))
		var index := _parents_list.add_item(text)
		_parents_list.set_item_metadata(index, p)
	var member_of: Array = holder.parents.map(func(p: Dictionary) -> String: return str(p.group))
	var choices := PackedStringArray()
	for g in _state.get("groups", []):
		if str(g.name) not in member_of and not (is_group and str(g.name) == str(holder.name)):
			choices.append(str(g.name))
	_fill_option(_parent_option, choices, "In every group" if not is_group else "No other groups")
	_track_row.visible = not is_group and not _state.get("tracks", []).is_empty()
	_track_option.clear()
	for t in _state.get("tracks", []):
		_track_option.add_item(str(t.name))
	_fill_permissions(holder)


func _fill_permissions(holder: Dictionary) -> void:
	var selected_key := ""
	var item := _perm_tree.get_selected()
	if item != null and item.get_metadata(0) is Dictionary:
		selected_key = _perm_key(item.get_metadata(0))
	_perm_tree.clear()
	var root := _perm_tree.create_item()
	for p in holder.permissions:
		var row := _perm_tree.create_item(root)
		row.set_text(Column.NODE, str(p.node))
		row.set_text(Column.VALUE, "Allow" if p.value else "Deny")
		row.set_custom_color(Column.VALUE, ALLOW_COLOR if p.value else DENY_COLOR)
		row.set_text(Column.WHERE, str(p.context) if str(p.context) != "" else "Everywhere")
		row.set_text(Column.EXPIRES, Fmt.datetime(int(p.expiry)) if int(p.expiry) > 0 else "Never")
		row.set_metadata(0, p)
		if _perm_key(p) == selected_key:
			row.select(0)
	# Other node types (meta values, chat prefixes on other priorities…) are shown, not edited here.
	for o in holder.other + holder.prefixes.slice(1 if _section() == Section.GROUPS else 0) + holder.suffixes:
		var row := _perm_tree.create_item(root)
		var label := str(o.get("node", "")) if o.has("node") else "%s (priority %d)" % [o.text, int(o.priority)]
		row.set_text(Column.NODE, label)
		row.set_text(Column.VALUE, str(o.get("type", "prefix/suffix")))
		row.set_text(Column.WHERE, str(o.context) if str(o.context) != "" else "Everywhere")
		row.set_text(Column.EXPIRES, Fmt.datetime(int(o.expiry)) if int(o.expiry) > 0 else "Never")
		for col in 4:
			row.set_custom_color(col, MUTED_COLOR)
		row.set_tooltip_text(Column.NODE, "Shown for reference; change it in game or with the LuckPerms web editor.")
		row.set_selectable(Column.NODE, false)
		for col in range(1, 4):
			row.set_selectable(col, false)


func _perm_key(p: Dictionary) -> String:
	return "%s|%s" % [p.get("node", ""), p.get("context", "")]


func _show_track(track: Dictionary) -> void:
	_title_label.text = str(track.name)
	_subtitle_label.text = "Track"
	var selected := _track_groups.get_selected_items()
	var keep := _track_groups.get_item_text(selected[0]) if not selected.is_empty() else ""
	_track_groups.clear()
	for g in track.groups:
		var index := _track_groups.add_item(str(g))
		if str(g) == keep:
			_track_groups.select(index)
	var choices := PackedStringArray()
	for g in _state.get("groups", []):
		if str(g.name) not in track.groups:
			choices.append(str(g.name))
	_fill_option(_track_group_option, choices, "Every group is on it")


## Fills [param option] with [param items], or one disabled [param empty_text] entry.
func _fill_option(option: OptionButton, items: PackedStringArray, empty_text: String) -> void:
	option.clear()
	for item in items:
		option.add_item(item)
	if items.is_empty():
		option.add_item(empty_text)
		option.set_item_disabled(0, true)


func _has_choice(option: OptionButton) -> bool:
	return option.item_count > 0 and option.selected >= 0 and not option.is_item_disabled(option.selected)


func _update_controls() -> void:
	var editable := _editable()
	_install_button.disabled = _busy
	_refresh_button.disabled = _busy
	var adding := _new_edit.text.strip_edges() != ""
	_new_edit.editable = editable or _section() == Section.PLAYERS
	_add_button.disabled = not adding or not (editable or _section() == Section.PLAYERS) or _busy
	_delete_button.disabled = not editable or _selected == "" or (_section() == Section.GROUPS and _selected == "default")
	var holder: Variant = _holder()
	if holder != null and _section() == Section.GROUPS:
		var current_prefix := str(holder.prefixes[0].text) if not holder.prefixes.is_empty() else ""
		_save_group_button.disabled = not editable or (int(_weight_spin.value) == int(holder.weight) and _prefix_edit.text == current_prefix)
	_weight_spin.editable = editable
	_prefix_edit.editable = editable
	_add_parent_button.disabled = not editable or not _has_choice(_parent_option)
	_parent_option.disabled = not editable or not _has_choice(_parent_option)
	_remove_parent_button.disabled = not editable or _parents_list.get_selected_items().is_empty()
	_promote_button.disabled = not editable or _track_option.item_count == 0
	_demote_button.disabled = _promote_button.disabled
	var perm := _selected_permission()
	_node_edit.editable = editable
	_where_edit.editable = editable
	_duration_edit.editable = editable
	_value_option.disabled = not editable
	_add_perm_button.disabled = not editable or _node_edit.text.strip_edges() == ""
	_remove_perm_button.disabled = not editable or perm.is_empty()
	_toggle_button.disabled = not editable or perm.is_empty() or int(perm.get("expiry", 0)) > 0
	_toggle_button.text = "Allow" if not perm.is_empty() and not perm.value else "Deny"
	var track_pick := _track_groups.get_selected_items()
	_append_button.disabled = not editable or not _has_choice(_track_group_option)
	_track_group_option.disabled = _append_button.disabled
	_up_button.disabled = not editable or track_pick.is_empty() or track_pick[0] == 0
	_down_button.disabled = not editable or track_pick.is_empty() or track_pick[0] == _track_groups.item_count - 1
	_remove_track_group_button.disabled = not editable or track_pick.is_empty()


func _selected_permission() -> Dictionary:
	var item := _perm_tree.get_selected()
	return item.get_metadata(0) if item != null and item.get_metadata(0) is Dictionary else {}


# --- Changing ---------------------------------------------------------------------

## Sends [param changes] (see LuckPerms.commands_for) and shows the result.
func _apply(changes: Array) -> bool:
	if handle == null or _busy or changes.is_empty():
		return false
	var h := handle
	_busy = true
	_update_controls()
	_status_label.text = "Saving…"
	var res: Dictionary = await h.call_op("perms_apply", {"changes": changes})
	_busy = false
	if h != handle:
		return false
	if not res.ok:
		Notifier.error(str(res.error))
		_rebuild()
		return false
	_state = res
	_rebuild()
	for text in res.get("failed", []):
		Notifier.warn("LuckPerms didn't %s." % text)
	return res.get("failed", []).is_empty()


func _holder_change(action: String, extra: Dictionary) -> Dictionary:
	var change := {"action": action, "holder": "group" if _section() == Section.GROUPS else "user", "name": _selected}
	change.merge(extra)
	return change


func _add_holder() -> void:
	var text := _new_edit.text.strip_edges()
	if text == "" or _busy:
		return
	match _section():
		Section.GROUPS, Section.TRACKS:
			var key := text.to_lower()
			if not LuckPerms.is_valid_name(key):
				Notifier.warn("Names are 1–36 lower-case letters, digits, _ or -.")
				return
			var action := "group_create" if _section() == Section.GROUPS else "track_create"
			if await _apply([{"action": action, "group" if _section() == Section.GROUPS else "track": key}]):
				_new_edit.text = ""
				_select(key)
		Section.PLAYERS:
			_busy = true
			_update_controls()
			var res: Dictionary = await handle.call_op("perms_player", {"name": text})
			_busy = false
			if not res.ok:
				Notifier.warn(str(res.error))
				_update_controls()
				return
			if not _found_players.any(func(p: Dictionary) -> bool: return p.uuid == res.uuid):
				_found_players.append({"uuid": str(res.uuid), "name": str(res.name)})
			_new_edit.text = ""
			_select(str(res.uuid))


func _select(key: String) -> void:
	_selected = key
	_filter_edit.text = ""
	_rebuild_list()
	_rebuild_detail()


func _confirm_delete() -> void:
	if _selected == "":
		return
	var what := "group" if _section() == Section.GROUPS else "track"
	_delete_dialog.title = "Delete %s" % what
	_delete_dialog.dialog_text = "Delete the %s \"%s\"? Players keep their other groups." % [what, _selected] if what == "group" \
			else "Delete the track \"%s\"? Its groups stay." % _selected
	_delete_dialog.popup_centered()


func _delete_selected() -> void:
	var change := {"action": "group_delete", "group": _selected} if _section() == Section.GROUPS else {"action": "track_delete", "track": _selected}
	if await _apply([change]):
		_select("")


func _save_group() -> void:
	var group: Variant = _group(_selected)
	if group == null:
		return
	var changes := []
	var weight := int(_weight_spin.value)
	if weight != int(group.weight):
		changes.append({"action": "weight_set", "group": _selected, "weight": weight})
	var text := _prefix_edit.text
	var current := str(group.prefixes[0].text) if not group.prefixes.is_empty() else ""
	if text != current:
		# One prefix per group here: replace the shown one (its priority follows the weight).
		if not group.prefixes.is_empty():
			var old: Dictionary = group.prefixes[0]
			changes.append(_holder_change("prefix_remove", {"priority": int(old.priority), "text": str(old.text), "context": str(old.context)}))
		if text != "":
			changes.append(_holder_change("prefix_set", {"priority": weight, "text": text}))
	await _apply(changes)


func _add_parent() -> void:
	if not _has_choice(_parent_option):
		return
	await _apply([_holder_change("parent_add", {"group": _parent_option.get_item_text(_parent_option.selected)})])


func _remove_parent() -> void:
	var picked := _parents_list.get_selected_items()
	if picked.is_empty():
		return
	var p: Dictionary = _parents_list.get_item_metadata(picked[0])
	await _apply([_holder_change("parent_remove", {"group": str(p.group), "context": str(p.context), "temporary": int(p.expiry) > 0})])


func _move_on_track(action: String) -> void:
	if _track_option.selected < 0:
		return
	await _apply([{"action": action, "name": _selected, "track": _track_option.get_item_text(_track_option.selected)}])


func _add_permission() -> void:
	var node := _node_edit.text.strip_edges()
	if node == "" or not _editable():
		return
	var change := _holder_change("permission_set", {"node": node, "value": _value_option.selected == 0,
			"context": _where_edit.text.strip_edges(), "duration": _duration_edit.text.strip_edges()})
	var built := LuckPerms.commands_for(change)
	if not built.ok:
		Notifier.warn(str(built.error))
		return
	if await _apply([change]):
		_node_edit.text = ""
		_duration_edit.text = ""


func _toggle_permission() -> void:
	var p := _selected_permission()
	if p.is_empty():
		return
	await _apply([_holder_change("permission_set", {"node": str(p.node), "value": not bool(p.value), "context": str(p.context)})])


func _remove_permission() -> void:
	var p := _selected_permission()
	if p.is_empty():
		return
	await _apply([_holder_change("permission_unset", {"node": str(p.node), "context": str(p.context), "temporary": int(p.expiry) > 0})])


func _append_to_track() -> void:
	if not _has_choice(_track_group_option):
		return
	await _apply([{"action": "track_append", "track": _selected, "group": _track_group_option.get_item_text(_track_group_option.selected)}])


func _move_in_track(step: int) -> void:
	var picked := _track_groups.get_selected_items()
	if picked.is_empty():
		return
	var group := _track_groups.get_item_text(picked[0])
	await _apply([{"action": "track_move", "track": _selected, "group": group, "position": picked[0] + step + 1}])


func _remove_from_track() -> void:
	var picked := _track_groups.get_selected_items()
	if picked.is_empty():
		return
	await _apply([{"action": "track_remove", "track": _selected, "group": _track_groups.get_item_text(picked[0])}])


func _install() -> void:
	if handle == null or _busy:
		return
	var h := handle
	_busy = true
	_update_controls()
	_status_label.text = "Downloading LuckPerms…"
	var res: Dictionary = await h.call_op("perms_install")
	_busy = false
	if not res.ok:
		Notifier.error(str(res.error))
	elif res.get("restart_needed", false):
		Notifier.success("Installed LuckPerms %s. Restart %s to load it." % [res.version, h.config.display_name])
	else:
		Notifier.success("Installed LuckPerms %s. It loads when %s starts." % [res.version, h.config.display_name])
	if h == handle:
		refresh()
