class_name LagMonitor
extends Timer
## Watches one running server for lag and works out whose fault it is. Every
## [constant SAMPLE_SEC] a worker thread reads the kernel's TCP statistics for each player's
## connection (round trip, resent data, how long since the player last sent anything), pings
## the router and the internet from this computer and reads the network interface counters;
## the server instance adds Paper's tick times and console events. Trouble that lasts becomes
## an incident with a verdict (LagAnalysis), saved with its evidence in the server's metadata
## folder so it can be shown to players later. Per-minute summaries are kept for the graphs.

signal updated

const SAMPLE_SEC := 2.0
## Raw samples kept in memory (the 10-minute and 1-hour views).
const HISTORY_SEC := 3600
## Minute summaries kept in memory (the 24-hour view); files keep [constant KEEP_DAYS].
const MINUTES_KEPT := 1440
const KEEP_DAYS := 14
const MAX_INCIDENTS := 500
## Pinged to tell this computer's internet connection apart from its local network.
const INTERNET_TARGET := "1.1.1.1"
## An episode ends after this long without trouble (ticks report every 5 s, so longer).
const CLOSE_SEC := 6.0
const TICK_CLOSE_SEC := 12.0
## How far before trouble the evidence reaches.
const LEAD_SEC := 10.0
## How far before a disconnect the evidence reaches (keepalive allows ~30 s of silence).
const DISCONNECT_LEAD_SEC := 45.0
const ROUTE_TTL_MSEC := 60_000
## Points a graph series is reduced to.
const GRAPH_POINTS := 240
const RANGES := [600, 3600, 86400]

var samples: Array[Dictionary] = []
var ticks: Array[Dictionary] = []
var incidents: Array[Dictionary] = []

var _dir := ""
var _port := 0
## Player connections by remote port: port -> {name, host} (from "logged in" lines).
var _peers := {}
var _route := {}
var _route_msec := -ROUTE_TTL_MSEC
var _task := -1
var _prev := {}
## Whether the router / internet ever answered: until they do, lost pings mean "blocked".
var _answers := {"gw": false, "net": false}
## Ongoing trouble: key ("player:<name>", "router", "internet", "tick") -> {start, last_bad, kinds, count}.
var _episodes := {}
var _minutes: Array[Dictionary] = []
var _minute := {}
var _last_tick := {}
## Player -> unix time of their last recorded disconnect (a keepalive kick is followed by
## "lost connection: Timed out" half a minute later).
var _last_disconnect := {}


func _ready() -> void:
	wait_time = SAMPLE_SEC
	timeout.connect(_sample)


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Loads saved incidents and minute summaries from [param meta_dir].
func setup(meta_dir: String) -> void:
	_dir = meta_dir.path_join("lag")
	incidents.clear()
	_minutes.clear()
	var oldest := Time.get_unix_time_from_system() - KEEP_DAYS * 86400
	var text := FileAccess.get_file_as_string(_dir.path_join("incidents.jsonl"))
	var kept := 0
	var total := 0
	for line in text.split("\n", false):
		total += 1
		var inc = JSON.parse_string(line)
		if inc is Dictionary and float(inc.get("t", 0.0)) >= oldest:
			incidents.append(inc)
			kept += 1
	if incidents.size() > MAX_INCIDENTS:
		incidents = incidents.slice(incidents.size() - MAX_INCIDENTS)
	if kept != total:
		_rewrite_incidents()
	var now := Time.get_unix_time_from_system()
	for day in [now - 86400, now]:
		for line in FileAccess.get_file_as_string(_minute_file(day)).split("\n", false):
			var m = JSON.parse_string(line)
			if m is Dictionary and now - float(m.get("t", 0.0)) <= MINUTES_KEPT * 60:
				_minutes.append(m)
	_prune_files()


## Starts watching the server on [param port]; [param log_path] (logs/latest.log) tells
## which connection belongs to which player for players who joined before now.
func track(port: int, log_path: String) -> void:
	_port = port
	_peers.clear()
	_prev.clear()
	_episodes.clear()
	_last_tick = {}
	_answers = {"gw": false, "net": false}
	for line in FileAccess.get_file_as_string(log_path).split("\n", false):
		_note_login(Ansi.strip(line))
	samples.clear()
	ticks.clear()
	start()
	_sample()


func untrack() -> void:
	stop()
	for key: String in _episodes.keys():
		_close_episode(key)
	_flush_minute()
	_port = 0
	_peers.clear()
	updated.emit()


func is_tracking() -> bool:
	return _port > 0


## Console lines: logins map connections to names; disconnects and "Can't keep up!" are
## judged when [param live] (not replayed from before the manager attached).
func on_line(plain: String, live: bool) -> void:
	if _note_login(plain) or not live or _port <= 0:
		return
	var behind := LagAnalysis.parse_behind(plain)
	if behind >= 0:
		add_tick({}, 0, behind)
		return
	var d := LagAnalysis.parse_disconnect(plain)
	if not d.is_empty():
		_on_disconnect(d)


## Paper's tick times from `mspt` ([param mspt], see LagAnalysis.parse_mspt) and how long
## RCON took to answer ([param rcon_ms], -1 for no answer at all).
func add_tick(mspt: Dictionary, rcon_ms: int, behind := 0) -> void:
	if _port <= 0:
		return
	var t := {"t": Time.get_unix_time_from_system(), "rcon": rcon_ms}
	if not mspt.is_empty():
		t.avg = snappedf(float(mspt.avg), 0.1)
		t.max = snappedf(float(mspt.max), 0.1)
		_last_tick = t
	elif rcon_ms >= 0 and behind <= 0:
		return  # Answered, but not with tick times (not Paper?): nothing to record.
	if behind > 0:
		t.behind = behind
	ticks.append(t)
	_trim(ticks, HISTORY_SEC)
	var trouble := LagAnalysis.tick_trouble(t)
	if trouble != "":
		_mark("tick", trouble, t.t)


# --- Snapshot for the Lag tab ----------------------------------------------------------

## Everything the Lag tab shows, as JSON values: {running, supported, status, now (cards),
## graph: {times, tick, gw, net, up}, players: [...], incidents (newest first)}.
func snapshot(range_sec: int) -> Dictionary:
	var backend := PlatformBackend.get_current()
	var now := Time.get_unix_time_from_system()
	var recent := _since(samples, now - 60.0)
	var recent_ticks := _since(ticks, now - 60.0)
	var out := {
		"running": _port > 0,
		"supported": {"tcp": backend.supports_tcp_stats()},
		"range": range_sec,
		"now": _cards(recent, recent_ticks),
		"status": _status(recent, recent_ticks),
		"graph": _graph(range_sec, now),
		"players": _players(now),
		"incidents": [],
	}
	# Episodes are recorded when they end, so order by when they started.
	var listed := incidents.duplicate()
	listed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.t) > float(b.t))
	out.incidents = listed
	return out


func _cards(recent: Array, recent_ticks: Array) -> Dictionary:
	var out := {}
	if not _last_tick.is_empty():
		out.tick_avg = _last_tick.avg
		var worst := 0.0
		for t: Dictionary in recent_ticks:
			worst = maxf(worst, float(t.get("max", 0.0)))
		out.tick_worst = worst
	for key: String in ["gw", "net"]:
		var vals := PackedFloat32Array()
		var lost := 0
		for s: Dictionary in recent:
			if s.has(key):
				if float(s[key]) < 0.0:
					lost += 1
				else:
					vals.append(float(s[key]))
		if vals.size() + lost > 0:
			var total := 0.0
			for v in vals:
				total += v
			out[key] = total / vals.size() if not vals.is_empty() else -1.0
			out[key + "_loss"] = 100.0 * lost / (vals.size() + lost)
	if not recent.is_empty():
		var last: Dictionary = recent[-1]
		out.up = last.get("up", 0)
		out.srv = last.get("srv", 0)
		out.wifi = last.get("wifi", 0)
		var peak := 0.0
		for s: Dictionary in recent:
			peak = maxf(peak, float(s.get("up", 0)))
		out.up_peak = peak
	out.route = _route.get("gateway", "")
	out.iface = _route.get("interface", "")
	return out


## {level: "ok" / "warn" / "bad" / "off", text} for the last minute.
func _status(recent: Array, recent_ticks: Array) -> Dictionary:
	if _port <= 0:
		return {"level": "off", "text": "The server is not running."}
	if recent.is_empty():
		return {"level": "off", "text": "Measuring…"}
	var tick := LagAnalysis.tick_summary(recent_ticks)
	var host := LagAnalysis.host_summary(recent)
	if tick.freeze:
		return {"level": "bad", "text": "The server is freezing (worst tick %.0f ms)." % tick.worst}
	if tick.slow:
		return {"level": "bad", "text": "The server is lagging: ticks take %.0f ms on average (limit 50 ms)." % tick.peak_avg}
	if host.bad:
		return {"level": "bad", "text": "This computer's connection has trouble: %s." % host.why}
	var troubled := PackedStringArray()
	var last: Dictionary = recent[-1].get("p", {})
	for name: String in last:
		if LagAnalysis.player_trouble(last[name]) != "":
			troubled.append(name)
	if not troubled.is_empty() and troubled.size() == last.size() and last.size() >= 2:
		return {"level": "bad", "text": "Every player's connection has trouble at once, so look at this computer's network."}
	if not troubled.is_empty():
		return {"level": "warn", "text": "The server is fine. Trouble on %s's connection only." % ", ".join(troubled)}
	if float(tick.worst) >= LagAnalysis.HITCH_MS:
		return {"level": "warn", "text": "Mostly fine, but one tick took %.0f ms in the last minute (a short stutter)." % tick.worst}
	return {"level": "ok", "text": "No problems on the server side in the last minute."}


## Graph series for the last [param range_sec], at most [constant GRAPH_POINTS] points each.
## Lost pings show as -1.
func _graph(range_sec: int, now: float) -> Dictionary:
	var points: Array = []
	if range_sec <= HISTORY_SEC:
		for s in _since(samples, now - range_sec):
			points.append({"t": s.t, "tick": s.get("tick", -1.0), "gw": s.get("gw", null), "net": s.get("net", null), "up": s.get("up", 0)})
	else:
		var since := now - range_sec
		for m in _minutes:
			if float(m.t) >= since:
				points.append(m)
		var pending := _minute_record()
		if not pending.is_empty():
			points.append(pending)
	var n := points.size()
	var out := {"times": [], "tick": [], "gw": [], "net": [], "up": []}
	if n == 0:
		return out
	var per := ceili(n / float(GRAPH_POINTS))
	var i := 0
	while i < n:
		var bucket := points.slice(i, mini(i + per, n))
		out.times.append(bucket[0].t)
		var tick := -1.0
		var up := 0.0
		for p: Dictionary in bucket:
			tick = maxf(tick, float(p.get("tick", -1.0)))
			up = maxf(up, float(p.get("up", 0)))
		out.tick.append(tick)
		out.up.append(up)
		for key: String in ["gw", "net"]:
			var total := 0.0
			var got := 0
			var lost := 0
			for p: Dictionary in bucket:
				lost += int(p.get(key + "_lost", 0))
				var v = p.get(key)
				if v == null:
					continue
				if float(v) < 0.0:
					lost += 1
				else:
					total += float(v)
					got += 1
			# A bucket where most pings went unanswered shows as lost.
			out[key].append(-1.0 if lost > got else (total / got if got > 0 else null))
		i += per
	return out


## The players connected now, with a ping history for the last 10 minutes.
func _players(now: float) -> Array:
	if samples.is_empty() or now - float(samples[-1].t) > SAMPLE_SEC * 3:
		return []
	var out: Array = []
	var current: Dictionary = samples[-1].get("p", {})
	var window := _since(samples, now - 600.0)
	for name: String in current:
		var p: Dictionary = current[name].duplicate()
		p.name = name
		p.trouble = LagAnalysis.player_trouble(current[name])
		var hist: Array = []
		for s: Dictionary in window:
			var q: Dictionary = s.get("p", {}).get(name, {})
			if not q.is_empty():
				hist.append(q.rtt)
		p.hist = hist
		out.append(p)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name).naturalnocasecmp_to(str(b.name)) < 0)
	return out


# --- Sampling --------------------------------------------------------------------------

func _sample() -> void:
	if _port <= 0 or _task >= 0:
		return
	if Time.get_ticks_msec() - _route_msec >= ROUTE_TTL_MSEC:
		_route = PlatformBackend.get_current().default_route()
		_route_msec = Time.get_ticks_msec()
	var port := _port
	var iface := str(_route.get("interface", ""))
	var gateway := str(_route.get("gateway", ""))
	_task = WorkerThreadPool.add_task(func() -> void:
		var r := LagMonitor.probe(port, iface, gateway)
		_on_probe.call_deferred(r), false, "Lag probe")


## Runs on a worker thread: everything that may block (ss, two pings, /proc reads).
static func probe(port: int, iface: String, gateway: String) -> Dictionary:
	var backend := PlatformBackend.get_current()
	return {
		"conns": backend.tcp_connections(port),
		"gw": backend.ping_ms(gateway) if gateway != "" else -2.0,
		"net": backend.ping_ms(INTERNET_TARGET),
		"iface": backend.interface_counters(iface),
		"wifi": backend.wifi_signal(iface),
		"msec": Time.get_ticks_msec(),
	}


func _on_probe(r: Dictionary) -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _port <= 0:
		return
	var now := Time.get_unix_time_from_system()
	var dt := (int(r.msec) - int(_prev.get("msec", 0))) / 1000.0 if _prev.has("msec") else 0.0
	var s := {"t": now}
	for key: String in ["gw", "net"]:
		var ms := float(r[key])
		if ms >= 0.0:
			_answers[key] = true
			s[key] = snappedf(ms, 0.1)
		elif ms == -1.0 and _answers[key]:
			s[key] = -1.0
	var iface: Dictionary = r.iface
	var prev_iface: Dictionary = _prev.get("iface", {})
	if dt > 0.0 and not iface.is_empty() and not prev_iface.is_empty():
		s.up = maxi(int((int(iface.tx) - int(prev_iface.tx)) / dt), 0)
		s.down = maxi(int((int(iface.rx) - int(prev_iface.rx)) / dt), 0)
		s.drops = maxi(int(iface.rx_drop) - int(prev_iface.rx_drop), 0)
	if int(r.wifi) != 0:
		s.wifi = int(r.wifi)
	if not _last_tick.is_empty() and now - float(_last_tick.t) <= 7.0:
		s.tick = _last_tick.max
		s.tick_avg = _last_tick.avg

	var players := {}
	var conns := {}
	var srv := 0
	var prev_conns: Dictionary = _prev.get("conns", {})
	for c: Dictionary in r.conns:
		var key := "%s:%d" % [c.host, c.port]
		conns[key] = c
		var peer: Dictionary = _peers.get(int(c.port), {})
		if peer.is_empty():
			continue  # A server-list ping or a login still in progress.
		var before: Dictionary = prev_conns.get(key, {})
		var p := {
			"rtt": snappedf(float(c.get("rtt", 0.0)), 0.1), "min": snappedf(float(c.get("minrtt", c.get("rtt", 0.0))), 0.1),
			"var": snappedf(float(c.get("rtt_var", 0.0)), 0.1), "quiet": int(c.get("lastrcv", 0)),
			"q": int(c.q), "loss": 0.0, "rate": 0,
		}
		if not before.is_empty() and dt > 0.0:
			var segs := float(c.get("segs_out", 0)) - float(before.get("segs_out", 0))
			var resent := float(c.get("retrans_total", 0)) - float(before.get("retrans_total", 0))
			if segs >= 20.0:
				p.loss = snappedf(clampf(resent * 100.0 / segs, 0.0, 100.0), 0.1)
			p.rate = maxi(int((float(c.get("bytes_acked", 0)) - float(before.get("bytes_acked", 0))) / dt), 0)
			srv += p.rate
		var name := str(peer.name)
		# Two connections under one name (a rejoin while the old one closes): the active one counts.
		if not players.has(name) or p.quiet < int(players[name].quiet):
			players[name] = p
	s.p = players
	if dt > 0.0:
		s.srv = srv
	_prev = {"msec": r.msec, "iface": iface, "conns": conns}

	samples.append(s)
	_trim(samples, HISTORY_SEC)
	_evaluate(s)
	_add_to_minute(s)
	updated.emit()


func _evaluate(s: Dictionary) -> void:
	var now: float = s.t
	for name: String in s.p:
		var trouble := LagAnalysis.player_trouble(s.p[name])
		if trouble != "":
			_mark("player:" + name, trouble, now)
	var host := LagAnalysis.host_trouble(s)
	for key: String in host:
		_mark(key, host[key], now)
	for key: String in _episodes.keys():
		var ep: Dictionary = _episodes[key]
		var close_after := TICK_CLOSE_SEC if key == "tick" else CLOSE_SEC
		if now - float(ep.last_bad) >= close_after:
			_close_episode(key)
		elif key.begins_with("player:") and not s.p.has(key.substr(7)):
			_close_episode(key)  # Left without a recognised disconnect line.


func _mark(key: String, kind: String, now: float) -> void:
	if _episodes.has(key):
		var ep: Dictionary = _episodes[key]
		ep.last_bad = now
		ep.count += 1
		ep.kinds[kind] = true
	else:
		_episodes[key] = {"start": now, "last_bad": now, "count": 1, "kinds": {kind: true}}


func _close_episode(key: String) -> void:
	var ep: Dictionary = _episodes.get(key, {})
	_episodes.erase(key)
	if ep.is_empty():
		return
	var kinds: Dictionary = ep.kinds
	# A single slow sample is noise, except silence (already 5 s long) and tick trouble.
	if int(ep.count) < 2 and not kinds.has("quiet") and key != "tick":
		return
	var from := float(ep.start) - LEAD_SEC
	var to := float(ep.last_bad) + SAMPLE_SEC
	var win := _between(samples, from, to)
	var win_ticks := _between(ticks, from, to)
	var inc := {"t": float(ep.start), "end": float(ep.last_bad), "kind": "lag"}
	var judged := {}
	if key.begins_with("player:"):
		var name := key.substr(7)
		inc.player = name
		inc.title = _player_lag_title(name, kinds, win)
		judged = LagAnalysis.judge_player(name, "lag", win, win_ticks)
	else:
		inc.player = ""
		inc.kind = key
		judged = LagAnalysis.judge_server(key, win, win_ticks)
		var tick := LagAnalysis.tick_summary(win_ticks)
		match key:
			"tick": inc.title = "Server froze" if kinds.has("freeze") else ("Server lagged" if kinds.has("slow") else "Server stutter (%.0f ms tick)" % tick.worst)
			"router": inc.title = "Router unreachable" if kinds.has("lost") else "Router slow"
			_: inc.title = "Internet unreachable" if kinds.has("lost") else "Internet slow"
	inc.merge(judged)
	_add_incident(inc)


func _player_lag_title(name: String, kinds: Dictionary, win: Array) -> String:
	var own := LagAnalysis.player_summary(name, win)
	if kinds.has("quiet"):
		return "%s stopped sending" % name
	if kinds.has("loss"):
		return "%s had packet loss" % name
	return "%s ping spiked (%s)" % [name, own.ping_text]


func _on_disconnect(d: Dictionary) -> void:
	var name: String = d.name
	var now := Time.get_unix_time_from_system()
	var key := "player:" + name
	var ep: Dictionary = _episodes.get(key, {})
	_episodes.erase(key)
	if d.kind == "quit" or d.kind == "kick":
		# Leaving normally is only worth noting right after trouble ("I left, it lagged").
		if ep.is_empty() or now - float(ep.last_bad) > 30.0:
			return
	if now - float(_last_disconnect.get(name, 0.0)) < 90.0:
		return
	_last_disconnect[name] = now
	var from := now - DISCONNECT_LEAD_SEC
	if not ep.is_empty():
		from = minf(from, float(ep.start) - LEAD_SEC)
	var win := _between(samples, from, now + 1.0)
	var judged := LagAnalysis.judge_player(name, d.kind, win, _between(ticks, from, now + 1.0))
	var titles := {"timeout": "%s timed out", "reset": "%s's connection broke", "quit": "%s left after lag", "kick": "%s was disconnected after lag"}
	var inc := {"t": now, "end": now, "kind": d.kind, "player": name, "title": titles[d.kind] % name, "reason": d.reason}
	inc.merge(judged)
	_add_incident(inc)


func _add_incident(inc: Dictionary) -> void:
	inc.id = "%d-%d" % [int(float(inc.t) * 1000.0), incidents.size()]
	incidents.append(inc)
	if incidents.size() > MAX_INCIDENTS:
		incidents = incidents.slice(incidents.size() - MAX_INCIDENTS)
	if _dir != "":
		DirAccess.make_dir_recursive_absolute(_dir)
		var path := _dir.path_join("incidents.jsonl")
		var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
		if f != null:
			f.seek_end()
			f.store_line(JSON.stringify(inc))


func _note_login(plain: String) -> bool:
	var login := LagAnalysis.parse_login(plain)
	if login.is_empty():
		return false
	_peers[int(login.port)] = {"name": login.name, "host": login.host}
	return true


# --- Minute summaries ---------------------------------------------------------------------

func _add_to_minute(s: Dictionary) -> void:
	var minute := floorf(float(s.t) / 60.0) * 60.0
	if not _minute.is_empty() and float(_minute.t) != minute:
		_flush_minute()
	if _minute.is_empty():
		_minute = {"t": minute, "n": 0, "tick": -1.0, "up": 0, "gw_sum": 0.0, "gw_n": 0, "gw_lost": 0,
				"net_sum": 0.0, "net_n": 0, "net_lost": 0, "p": {}}
	_minute.n += 1
	_minute.tick = maxf(float(_minute.tick), float(s.get("tick", -1.0)))
	_minute.up = maxi(int(_minute.up), int(s.get("up", 0)))
	for key: String in ["gw", "net"]:
		if s.has(key):
			if float(s[key]) < 0.0:
				_minute[key + "_lost"] += 1
			else:
				_minute[key + "_sum"] += float(s[key])
				_minute[key + "_n"] += 1
	for name: String in s.get("p", {}):
		var p: Dictionary = s.p[name]
		var m: Dictionary = _minute.p.get(name, {"rtt": 0.0, "quiet": 0, "loss": 0.0})
		m.rtt = maxf(float(m.rtt), float(p.rtt))
		m.quiet = maxi(int(m.quiet), int(p.quiet))
		m.loss = maxf(float(m.loss), float(p.loss))
		_minute.p[name] = m


## The minute being collected, in the saved form ({} when empty).
func _minute_record() -> Dictionary:
	if _minute.is_empty() or int(_minute.n) == 0:
		return {}
	var out := {"t": _minute.t, "tick": _minute.tick, "up": _minute.up, "p": _minute.p}
	for key: String in ["gw", "net"]:
		if int(_minute[key + "_n"]) > 0:
			out[key] = snappedf(float(_minute[key + "_sum"]) / int(_minute[key + "_n"]), 0.1)
		if int(_minute[key + "_lost"]) > 0:
			out[key + "_lost"] = _minute[key + "_lost"]
	return out


func _flush_minute() -> void:
	var rec := _minute_record()
	_minute = {}
	if rec.is_empty():
		return
	_minutes.append(rec)
	if _minutes.size() > MINUTES_KEPT:
		_minutes = _minutes.slice(_minutes.size() - MINUTES_KEPT)
	if _dir == "":
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var path := _minute_file(float(rec.t))
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(JSON.stringify(rec))


func _minute_file(unix: float) -> String:
	return _dir.path_join("%s.jsonl" % LagAnalysis.stamp(unix).get_slice(" ", 0))


func _prune_files() -> void:
	if not DirAccess.dir_exists_absolute(_dir):
		return
	var oldest := LagAnalysis.stamp(Time.get_unix_time_from_system() - KEEP_DAYS * 86400).get_slice(" ", 0)
	for f in DirAccess.get_files_at(_dir):
		# Day files are named YYYY-MM-DD.jsonl, which sort by date.
		if f.length() == 16 and f.ends_with(".jsonl") and f.substr(0, 10) < oldest:
			DirAccess.remove_absolute(_dir.path_join(f))


func _rewrite_incidents() -> void:
	DirAccess.make_dir_recursive_absolute(_dir)
	var f := FileAccess.open(_dir.path_join("incidents.jsonl"), FileAccess.WRITE)
	if f == null:
		return
	for inc in incidents:
		f.store_line(JSON.stringify(inc))


# --- Helpers ------------------------------------------------------------------------------

static func _trim(arr: Array[Dictionary], keep_sec: float) -> void:
	var cutoff := Time.get_unix_time_from_system() - keep_sec
	var drop := 0
	while drop < arr.size() and float(arr[drop].t) < cutoff:
		drop += 1
	if drop > 0:
		var rest := arr.slice(drop)
		arr.clear()
		arr.append_array(rest)


static func _since(arr: Array[Dictionary], from: float) -> Array:
	return _between(arr, from, INF)


static func _between(arr: Array[Dictionary], from: float, to: float) -> Array:
	var out: Array = []
	for i in range(arr.size() - 1, -1, -1):
		var t := float(arr[i].t)
		if t < from:
			break
		if t <= to:
			out.append(arr[i])
	out.reverse()
	return out
