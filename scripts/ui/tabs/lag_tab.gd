class_name LagTab
extends ServerTab
## Shows whether lag comes from the server, the server's network or one player's own
## connection, with the measurements behind each verdict (see LagMonitor), so complaints can
## be answered with facts. Everything is measured on the server's computer
## (ServerOps "lag_snapshot"), so it works for servers on other computers too.

const OK_COLOR := Color("3fb97f")
const WARN_COLOR := Color("f2b84b")
const BAD_COLOR := Color("e05555")
const MUTED_COLOR := Color("6b7280")
const VERDICT_COLORS := {
	LagAnalysis.VERDICT_SERVER: Color("e05555"),
	LagAnalysis.VERDICT_NETWORK: Color("f2b84b"),
	LagAnalysis.VERDICT_PLAYER: Color("5aa9f2"),
	LagAnalysis.VERDICT_UNCLEAR: Color("6b7280"),
}
const RANGES := [[600, "10 min"], [3600, "1 hour"], [86400, "24 hours"]]
const VERDICT_FILTERS := ["", LagAnalysis.VERDICT_SERVER, LagAnalysis.VERDICT_NETWORK, LagAnalysis.VERDICT_PLAYER, LagAnalysis.VERDICT_UNCLEAR]
## Incidents listed at most (the report includes all that match).
const MAX_ROWS := 100

var _snap := {}
var _loading := false
var _expanded := {}
var _incidents_key := ""
## Player name -> {row, dot, name, stats, graph}
var _player_rows := {}

@onready var _status_dot: StatusDot = %StatusDot
@onready var _status_label: Label = %StatusLabel
@onready var _range_option: OptionButton = %RangeOption
@onready var _copy_button: Button = %CopyReportButton
@onready var _support_notice: PanelContainer = %SupportNotice
@onready var _support_label: Label = %SupportLabel
@onready var _tick_card: StatCard = %TickCard
@onready var _router_card: StatCard = %RouterCard
@onready var _internet_card: StatCard = %InternetCard
@onready var _upload_card: StatCard = %UploadCard
@onready var _tick_graph: GraphCard = %TickGraph
@onready var _router_graph: GraphCard = %RouterGraph
@onready var _internet_graph: GraphCard = %InternetGraph
@onready var _upload_graph: GraphCard = %UploadGraph
@onready var _players_list: VBoxContainer = %PlayersList
@onready var _players_empty: Label = %PlayersEmpty
@onready var _verdict_filter: OptionButton = %VerdictFilter
@onready var _player_filter: LineEdit = %PlayerFilter
@onready var _incidents_list: VBoxContainer = %IncidentsList
@onready var _incidents_empty: Label = %IncidentsEmpty
@onready var _poll: Timer = %PollTimer


func _ready() -> void:
	for r in RANGES:
		_range_option.add_item(r[1])
	_range_option.item_selected.connect(func(_i: int) -> void: _load())
	_verdict_filter.add_item("All")
	for v in VERDICT_FILTERS.slice(1):
		_verdict_filter.add_item(LagAnalysis.VERDICT_TITLES[v])
	_verdict_filter.item_selected.connect(func(_i: int) -> void: _refresh_incidents(true))
	_player_filter.text_changed.connect(func(_t: String) -> void: _refresh_incidents(true))
	_copy_button.pressed.connect(_copy_report)
	_poll.timeout.connect(_load)
	visibility_changed.connect(_update_polling)
	_tick_graph.graph().threshold = LagAnalysis.TICK_LIMIT_MS


func _on_bound() -> void:
	_snap = {}
	_expanded.clear()
	_incidents_key = ""
	for name: String in _player_rows.keys():
		_player_rows[name].row.queue_free()
	_player_rows.clear()
	watch(handle.state_changed, func(_s: ServerHandle.State) -> void: _load())
	_update_polling()
	_load()


func _update_polling() -> void:
	if handle != null and is_visible_in_tree():
		_poll.start()
		_load()
	else:
		_poll.stop()


func _range_sec() -> int:
	return int(RANGES[maxi(_range_option.selected, 0)][0])


func _load() -> void:
	if handle == null or _loading or not is_visible_in_tree():
		return
	_loading = true
	var h := handle
	var res: Dictionary = await h.call_op("lag_snapshot", {"range": _range_sec()})
	_loading = false
	if h != handle:
		return
	if not res.get("ok", false):
		_status_dot.color = MUTED_COLOR
		_status_label.text = str(res.get("error", "Not available."))
		return
	_snap = res
	_refresh()


func _refresh() -> void:
	var status: Dictionary = _snap.get("status", {})
	var level := str(status.get("level", "off"))
	_status_dot.color = {"ok": OK_COLOR, "warn": WARN_COLOR, "bad": BAD_COLOR}.get(level, MUTED_COLOR)
	_status_label.text = str(status.get("text", ""))
	var supported: Dictionary = _snap.get("supported", {})
	_support_notice.visible = not supported.get("tcp", true)
	_support_label.text = "Per-player connection statistics need Linux (the ss tool). On %s only the server's ticks and pings are measured, so verdicts about single players are less certain." % (
			"this computer" if not handle.is_remote() else handle.host_name())
	_refresh_cards()
	_refresh_graphs()
	_refresh_players()
	_refresh_incidents(false)


func _refresh_cards() -> void:
	var now: Dictionary = _snap.get("now", {})
	var running := bool(_snap.get("running", false))
	if running and now.has("tick_avg"):
		var avg := float(now.tick_avg)
		var worst := float(now.get("tick_worst", 0.0))
		var color := BAD_COLOR if avg > LagAnalysis.TICK_LIMIT_MS or worst >= LagAnalysis.FREEZE_MS else (WARN_COLOR if worst >= LagAnalysis.HITCH_MS else OK_COLOR)
		_tick_card.set_value("%.1f ms" % avg, color)
		_tick_card.set_sub("worst %.0f ms" % worst)
	else:
		_tick_card.set_value("—")
		_tick_card.set_sub("needs RCON" if running else "")
	_ping_card(_router_card, now, "gw", LagAnalysis.ROUTER_SLOW_MS, running)
	_ping_card(_internet_card, now, "net", LagAnalysis.INTERNET_SLOW_MS, running)
	var wifi := int(now.get("wifi", 0))
	var link := ("Wi-Fi %d dBm" % wifi) if wifi != 0 else "wired"
	if running and now.has("gw"):
		_router_card.set_sub("%.0f%% lost · %s" % [float(now.get("gw_loss", 0.0)), link])
	_router_card.tooltip_text = "Ping from this computer to its router%s over the last minute. Trouble here means the server's own local network%s." % [
			" (%s on %s)" % [now.route, now.iface] if str(now.get("route", "")) != "" else "",
			", here Wi-Fi: a cable is more reliable" if wifi != 0 else ""]
	if running and now.has("up"):
		_upload_card.set_value(LagAnalysis.mbit(float(now.up)))
		_upload_card.set_sub("server %s · peak %s" % [LagAnalysis.mbit(float(now.get("srv", 0))), LagAnalysis.mbit(float(now.get("up_peak", 0)))])
	else:
		_upload_card.set_value("—")
		_upload_card.set_sub("")


func _ping_card(card: StatCard, now: Dictionary, key: String, slow: float, running: bool) -> void:
	if not running or not now.has(key):
		card.set_value("—")
		card.set_sub("no ping replies yet" if running else "")
		return
	var ms := float(now[key])
	var loss := float(now.get(key + "_loss", 0.0))
	var color := BAD_COLOR if ms < 0.0 or loss >= 34.0 or ms >= slow else (WARN_COLOR if loss > 0.0 or ms >= slow * 0.5 else OK_COLOR)
	card.set_value("lost" if ms < 0.0 else "%.0f ms" % ms, color)
	card.set_sub("%.0f%% lost" % loss)


func _refresh_graphs() -> void:
	var g: Dictionary = _snap.get("graph", {})
	var times: Array = g.get("times", [])
	var tick := _series(g.get("tick", []))
	_set_graph(_tick_graph, tick.values, times, "%.0f ms", PackedInt32Array(), LagAnalysis.TICK_LIMIT_MS * 1.3)
	var router := _series(g.get("gw", []))
	_set_graph(_router_graph, router.values, times, "%.0f ms", router.marks, 20.0)
	var internet := _series(g.get("net", []))
	_set_graph(_internet_graph, internet.values, times, "%.0f ms", internet.marks, 60.0)
	var up := PackedFloat32Array()
	for v in g.get("up", []):
		up.append(float(v) * 8.0 / 1_000_000.0)
	_set_graph(_upload_graph, up, times, "%.1f Mbit/s", PackedInt32Array(), 1.0)


## Raw series -> {values, marks}: gaps (null) repeat the last value, lost pings (-1) also
## become red marks.
func _series(raw: Array) -> Dictionary:
	var values := PackedFloat32Array()
	var marks := PackedInt32Array()
	var last := 0.0
	for i in raw.size():
		var v = raw[i]
		if v != null and float(v) >= 0.0:
			last = float(v)
		elif v != null:
			marks.append(i)
		values.append(last)
	return {"values": values, "marks": marks}


## [param floor_value]: the graph's top is at least this, so small wobbles stay small.
func _set_graph(card: GraphCard, values: PackedFloat32Array, times: Array, fmt: String, marks: PackedInt32Array, floor_value: float) -> void:
	var graph := card.graph()
	graph.capacity = maxi(values.size(), 2)
	graph.mouse_filter = Control.MOUSE_FILTER_PASS
	graph.set_marks(marks)
	graph.hover_text = func(i: int) -> String:
		if i < 0 or i >= times.size():
			return ""
		return "%s  %s" % [LagAnalysis.clock(float(times[i])), "lost" if marks.has(i) else fmt % values[i]]
	var current := ""
	if not values.is_empty() and bool(_snap.get("running", false)):
		current = "lost" if marks.has(values.size() - 1) else fmt % values[-1]
	var top := floor_value
	for v in values:
		top = maxf(top, v * 1.15)
	card.set_data(values, current if current != "" else "—", top)


# --- Players ----------------------------------------------------------------------------

func _refresh_players() -> void:
	var seen := {}
	for p: Dictionary in _snap.get("players", []):
		var name := str(p.name)
		seen[name] = true
		var row: Dictionary = _player_rows.get(name, {})
		if row.is_empty():
			row = _make_player_row(name)
			_player_rows[name] = row
		var trouble := str(p.get("trouble", ""))
		row.dot.color = OK_COLOR if trouble == "" else (BAD_COLOR if trouble == "quiet" else WARN_COLOR)
		row.dot.tooltip_text = {"": "Connection fine.", "quiet": "Nothing has arrived from this player's game for a while.",
				"loss": "Data to this player keeps getting lost and resent.", "spike": "Ping far above this player's usual."}.get(trouble, "")
		row.stats.text = "Ping %.0f ms (best %.0f)  ·  Jitter %.0f ms  ·  Quiet %.1f s  ·  Resent %.1f%%  ·  Queued %s" % [
				float(p.rtt), float(p.get("min", p.rtt)), float(p.get("var", 0.0)), int(p.get("quiet", 0)) / 1000.0,
				float(p.get("loss", 0.0)), Fmt.bytes(float(p.get("q", 0)))]
		var hist := PackedFloat32Array()
		for v in p.get("hist", []):
			hist.append(float(v))
		row.graph.capacity = maxi(hist.size(), 2)
		row.graph.set_values(hist)
	for name: String in _player_rows.keys():
		if not seen.has(name):
			_player_rows[name].row.queue_free()
			_player_rows.erase(name)
	_players_empty.visible = _player_rows.is_empty()
	_players_empty.text = "Nobody is online." if bool(_snap.get("running", false)) else "The server is not running."


func _make_player_row(name: String) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var dot: StatusDot = preload("res://scenes/components/status_dot.tscn").instantiate()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(dot)
	var label := Label.new()
	label.text = name
	label.custom_minimum_size.x = 150
	row.add_child(label)
	var stats := Label.new()
	stats.theme_type_variation = &"MutedLabel"
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(stats)
	var graph: LineGraph = preload("res://scenes/components/line_graph.tscn").instantiate()
	graph.custom_minimum_size = Vector2(160, 28)
	graph.size_flags_horizontal = Control.SIZE_SHRINK_END
	graph.max_value = 0.0
	graph.line_color = Color("5aa9f2")
	graph.grid_lines = 1
	graph.tooltip_text = "Ping over the last 10 minutes."
	graph.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(graph)
	_players_list.add_child(row)
	return {"row": row, "dot": dot, "stats": stats, "graph": graph}


# --- Incidents --------------------------------------------------------------------------

func _filtered_incidents() -> Array:
	var verdict: String = VERDICT_FILTERS[maxi(_verdict_filter.selected, 0)]
	var who := _player_filter.text.strip_edges().to_lower()
	var out: Array = []
	for inc: Dictionary in _snap.get("incidents", []):
		if verdict != "" and str(inc.get("verdict", "")) != verdict:
			continue
		if who != "" and str(inc.get("player", "")) != "" and not str(inc.player).to_lower().contains(who):
			continue
		out.append(inc)
	return out


func _refresh_incidents(force: bool) -> void:
	var shown := _filtered_incidents()
	var ids := PackedStringArray()
	for inc: Dictionary in shown.slice(0, MAX_ROWS):
		ids.append(str(inc.get("id", "")))
	var key := ",".join(ids)
	if key == _incidents_key and not force:
		return
	_incidents_key = key
	for child in _incidents_list.get_children():
		child.queue_free()
	for inc: Dictionary in shown.slice(0, MAX_ROWS):
		_incidents_list.add_child(_make_incident_row(inc))
	if shown.size() > MAX_ROWS:
		var more := Label.new()
		more.theme_type_variation = &"MutedLabel"
		more.text = "%d older incidents not listed (included in the report)." % (shown.size() - MAX_ROWS)
		_incidents_list.add_child(more)
	_incidents_empty.visible = shown.is_empty()
	_incidents_empty.text = "No incidents recorded." if _snap.get("incidents", []).is_empty() else "No incidents match the filter."


func _make_incident_row(inc: Dictionary) -> Control:
	var id := str(inc.get("id", ""))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var time := Label.new()
	time.theme_type_variation = &"MutedLabel"
	time.text = LagAnalysis.stamp(float(inc.t)).substr(5, 11)
	time.tooltip_text = LagAnalysis.stamp(float(inc.t))
	time.mouse_filter = Control.MOUSE_FILTER_PASS
	time.custom_minimum_size.x = 96
	row.add_child(time)
	var title := Button.new()
	title.flat = true
	title.text = str(inc.get("title", ""))
	title.alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.tooltip_text = "%s\nClick for the evidence." % str(inc.get("summary", ""))
	row.add_child(title)
	var verdict := str(inc.get("verdict", LagAnalysis.VERDICT_UNCLEAR))
	var badge := Label.new()
	badge.text = LagAnalysis.VERDICT_TITLES.get(verdict, "?")
	badge.add_theme_color_override("font_color", VERDICT_COLORS.get(verdict, MUTED_COLOR))
	badge.tooltip_text = str(inc.get("summary", ""))
	badge.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(badge)
	var copy := Button.new()
	copy.flat = true
	copy.icon = preload("res://assets/icons/copy.svg")
	copy.tooltip_text = "Copy this incident with its evidence."
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(LagAnalysis.incident_text(inc))
		Notifier.info("Copied the incident to the clipboard."))
	row.add_child(copy)
	var details := Label.new()
	details.theme_type_variation = &"MutedLabel"
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var lines := PackedStringArray([str(inc.get("summary", ""))])
	if str(inc.get("reason", "")) != "":
		lines.append("Server log: \"%s\"" % inc.reason)
	for e in inc.get("evidence", []):
		lines.append("•  " + str(e))
	details.text = "\n".join(lines)
	details.visible = _expanded.has(id)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 106)
	margin.add_child(details)
	margin.visible = details.visible
	box.add_child(margin)
	title.pressed.connect(func() -> void:
		if _expanded.has(id):
			_expanded.erase(id)
		else:
			_expanded[id] = true
		details.visible = _expanded.has(id)
		margin.visible = details.visible)
	return box


func _copy_report() -> void:
	if _snap.is_empty():
		return
	var shown := _filtered_incidents()
	var oldest := float(Time.get_unix_time_from_system())
	for inc: Dictionary in shown:
		oldest = minf(oldest, float(inc.t))
	var now_unix := Time.get_unix_time_from_system()
	var text := LagAnalysis.report(handle.config.display_name, shown, maxi(int(now_unix - oldest) + 60, 3600), now_unix)
	var lines := PackedStringArray(text.split("\n"))
	lines.insert(1, "Right now: %s" % str(_snap.get("status", {}).get("text", "")))
	DisplayServer.clipboard_set("\n".join(lines))
	Notifier.info("Copied the lag report (%d incident%s) to the clipboard." % [shown.size(), "" if shown.size() == 1 else "s"])
