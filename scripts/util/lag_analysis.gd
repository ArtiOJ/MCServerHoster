class_name LagAnalysis
extends RefCounted
## Reading and judgement behind the Lag tab: what Paper, the kernel and ping report, when a
## measurement counts as trouble, and whose fault an incident was (the server, the server's
## network or one player's connection). Pure functions over the plain dictionaries
## LagMonitor records, so they run the same on the host, in tests and in reports.
##
## A sample (every LagMonitor.SAMPLE_SEC): {t: unix seconds, gw / net: ping to the router /
## the internet in ms (-1 lost; missing when not measured), up / down: this computer's
## traffic in bytes/s, srv: bytes/s this server sent to players, wifi: signal in dBm (0 when
## wired), tick / tick_avg: Paper's worst / average tick of the last 5 s, p: {player name:
## {rtt, min, var: ms, quiet: ms since the player last sent anything, loss: % of segments
## resent, q: bytes waiting to reach the player, rate: bytes/s delivered}}}.
## A tick entry (every 5 s): {t, avg, max: ms over the last 5 s, rcon: reply time in ms
## (-1 no reply), behind: ms Paper reported falling behind (only on "Can't keep up!")}.

const VERDICT_SERVER := "server"
const VERDICT_NETWORK := "network"
const VERDICT_PLAYER := "player"
const VERDICT_UNCLEAR := "unclear"
const VERDICT_TITLES := {
	VERDICT_SERVER: "Server",
	VERDICT_NETWORK: "Server network",
	VERDICT_PLAYER: "Player's connection",
	VERDICT_UNCLEAR: "Unclear",
}

## One tick may take this long (20 TPS).
const TICK_LIMIT_MS := 50.0
## A single tick this long is a hitch players can see (blocks snap back, mobs freeze).
const HITCH_MS := 250.0
## A freeze this long can make players time out; shorter hitches cannot.
const FREEZE_MS := 5000.0
## Minecraft clients send something several times a second while connected; this much
## silence means the client froze or its packets stopped arriving.
const QUIET_MS := 5000
## Ping this far above the player's own best counts as a spike...
const SPIKE_MS := 150.0
## ...as long as it is at least this high overall.
const SPIKE_FLOOR_MS := 200.0
## Share of segments resent to a player that counts as packet loss.
const LOSS_PCT := 5.0
## Ping to the router (Wi-Fi or cable to it) this slow counts as trouble.
const ROUTER_SLOW_MS := 100.0
## Ping to the internet this slow counts as trouble.
const INTERNET_SLOW_MS := 250.0

static var _re_mspt := RegEx.create_from_string("([\\d.]+)/([\\d.]+)/([\\d.]+)")
static var _re_login := RegEx.create_from_string("\\]: ([A-Za-z0-9_.]{1,16})\\[/?([^\\]]*)\\] logged in with entity id")
static var _re_lost := RegEx.create_from_string("\\]: ([A-Za-z0-9_.]{1,16})(?: \\(/[^)]*\\))? lost connection: (.*)$")
static var _re_keepalive := RegEx.create_from_string("\\]: ([A-Za-z0-9_.]{1,16}) was kicked due to keepalive timeout")
static var _re_behind := RegEx.create_from_string("Can't keep up! .*Running (\\d+)ms or (\\d+) ticks behind")
static var _re_ss_field := RegEx.create_from_string("([a-z_]+):([\\d.]+)(?:/([\\d.]+))?")
static var _re_ping := RegEx.create_from_string("[=<]\\s*([\\d.,]+)\\s*ms")


# --- Parsing -------------------------------------------------------------------

## Paper's `mspt` reply ("Server tick times (avg/min/max) from last 5s, 10s, 1m: ◴ 4.4/1.8/33.3,
## …"). Returns {avg, min, max} for the last 5 s plus max_1m, or {} when not recognised.
static func parse_mspt(text: String) -> Dictionary:
	var plain := Ansi.strip(text)
	if not plain.contains("tick times"):
		return {}
	var found := _re_mspt.search_all(plain)
	if found.is_empty():
		return {}
	return {
		"avg": found[0].get_string(1).to_float(), "min": found[0].get_string(2).to_float(),
		"max": found[0].get_string(3).to_float(), "max_1m": found[-1].get_string(3).to_float(),
	}


## "Name[/1.2.3.4:5678] logged in with entity id …" -> {name, host, port}, or {}.
static func parse_login(plain: String) -> Dictionary:
	var m := _re_login.search(plain)
	if m == null:
		return {}
	var addr := split_address(m.get_string(2))
	return {"name": m.get_string(1), "host": addr[0], "port": addr[1]}


## A player's connection ending: {name, kind, reason}, or {}. Kinds: "timeout" (stopped
## answering), "reset" (the connection broke), "quit" (the game closed it normally),
## "kick" (anything else the server ended it for).
static func parse_disconnect(plain: String) -> Dictionary:
	var m := _re_keepalive.search(plain)
	if m != null:
		return {"name": m.get_string(1), "kind": "timeout", "reason": "keepalive timeout"}
	m = _re_lost.search(plain)
	if m == null:
		return {}
	var reason := m.get_string(2).strip_edges()
	var lower := reason.to_lower()
	var kind := "kick"
	if lower.contains("timed out") or lower.contains("keepalive"):
		kind = "timeout"
	elif lower.contains("connection reset") or lower.contains("broken pipe") or lower.contains("connection abort") or lower.contains("no route"):
		kind = "reset"
	elif lower == "disconnected" or lower == "disconnect":
		kind = "quit"
	return {"name": m.get_string(1), "kind": kind, "reason": reason}


## Milliseconds behind from Paper's "Can't keep up!" warning, or -1.
static func parse_behind(plain: String) -> int:
	var m := _re_behind.search(plain)
	return m.get_string(1).to_int() if m != null else -1


## Round trip in ms from one `ping` reply (Linux, macOS or Windows wording), or -1.
static func parse_ping(text: String) -> float:
	var m := _re_ping.search(text)
	return m.get_string(1).replace(",", ".").to_float() if m != null else -1.0


## "[::ffff:1.2.3.4]:5678", "1.2.3.4:5678" or "[2001:db8::1]:5678" -> [host, port].
static func split_address(addr: String) -> Array:
	var a := addr.strip_edges().trim_prefix("/")
	var colon := a.rfind(":")
	if colon < 0:
		return [a, 0]
	var host := a.substr(0, colon).trim_prefix("[").trim_suffix("]")
	if host.begins_with("::ffff:") and host.count(".") == 3:
		host = host.substr(7)
	return [host, a.substr(colon + 1).to_int()]


## Output of `ss -tinH state established …` -> one dictionary per connection: {rq, q (bytes
## waiting to be read / to reach the peer), host, port, rtt, rtt_var, minrtt, lastrcv, lastack,
## bytes_sent, bytes_acked, bytes_retrans, segs_out, retrans, retrans_total, …}.
static func parse_ss(text: String) -> Array:
	var out: Array = []
	var current := {}
	for line in text.split("\n", false):
		if line.begins_with("\t") or line.begins_with(" "):
			if current.is_empty():
				continue
			for m in _re_ss_field.search_all(line):
				var key := m.get_string(1)
				current[key] = m.get_string(2).to_float()
				if m.get_string(3) != "":
					current[key + ("_var" if key == "rtt" else "_total")] = m.get_string(3).to_float()
			continue
		var f := line.split(" ", false)
		if f.size() < 4 or not f[0].is_valid_int():
			current = {}
			continue
		var peer := split_address(f[3])
		current = {"rq": f[0].to_int(), "q": f[1].to_int(), "host": peer[0], "port": peer[1]}
		out.append(current)
	return out


# --- What counts as trouble -------------------------------------------------------

## Why one player sample is trouble: "quiet", "loss", "spike" or "" (fine).
static func player_trouble(p: Dictionary) -> String:
	if int(p.get("quiet", 0)) >= QUIET_MS:
		return "quiet"
	if float(p.get("loss", 0.0)) >= LOSS_PCT:
		return "loss"
	var rtt := float(p.get("rtt", 0.0))
	if rtt >= SPIKE_FLOOR_MS and rtt - float(p.get("min", rtt)) >= SPIKE_MS:
		return "spike"
	return ""


## Trouble on this computer's own connection in one sample: {"router": "lost"/"slow",
## "internet": "lost"/"slow"} (keys only when there is trouble).
static func host_trouble(s: Dictionary) -> Dictionary:
	var out := {}
	if s.has("gw"):
		var gw := float(s.gw)
		if gw < 0.0:
			out["router"] = "lost"
		elif gw >= ROUTER_SLOW_MS:
			out["router"] = "slow"
	if s.has("net"):
		var net := float(s.net)
		if net < 0.0:
			out["internet"] = "lost"
		elif net >= INTERNET_SLOW_MS:
			out["internet"] = "slow"
	return out


## Why one tick entry is trouble: "freeze" (players can time out), "slow" (TPS below 20),
## "hitch" (one visible stutter) or "".
static func tick_trouble(t: Dictionary) -> String:
	if float(t.get("max", 0.0)) >= FREEZE_MS or int(t.get("rcon", 0)) < 0 or int(t.get("behind", 0)) >= FREEZE_MS:
		return "freeze"
	if float(t.get("avg", 0.0)) > TICK_LIMIT_MS or int(t.get("behind", 0)) > 0:
		return "slow"
	if float(t.get("max", 0.0)) >= HITCH_MS:
		return "hitch"
	return ""


# --- Judging an incident -------------------------------------------------------------

## Works out whose fault trouble for [param player] was, from the [param samples] and
## [param ticks] around it. [param kind] is the disconnect kind or "lag". Returns
## {verdict, summary, evidence: Array[String]}.
static func judge_player(player: String, kind: String, samples: Array, ticks: Array) -> Dictionary:
	var tick := tick_summary(ticks)
	var host := host_summary(samples)
	var own := player_summary(player, samples)
	var others := {}
	for s: Dictionary in samples:
		for name: String in s.get("p", {}):
			if name == player:
				continue
			if not others.has(name):
				others[name] = false
			if player_trouble(s.p[name]) != "":
				others[name] = true
	var troubled := 0
	for name: String in others:
		if others[name]:
			troubled += 1
	var everyone := not others.is_empty() and troubled == others.size()
	var most := others.size() >= 3 and troubled * 2 >= others.size()

	var fine := "the server and its network" if others.is_empty() else "the server, its network and the other players"
	var verdict := VERDICT_UNCLEAR
	var summary := ""
	if tick.freeze:
		verdict = VERDICT_SERVER
		summary = "The server froze for %s, long enough to drop players." % _secs(tick.worst)
	elif host.bad:
		verdict = VERDICT_NETWORK
		summary = "The server's own connection had trouble (%s)." % host.why
	elif everyone or most:
		verdict = VERDICT_NETWORK
		summary = "%s at the same time, so the problem was on the server's side of the internet." % (
				"Every other player had trouble" if everyone else "Most players had trouble")
	elif kind == "timeout" and own.seen and int(own.quiet) < QUIET_MS:
		# The kernel kept receiving their game's packets, yet Paper timed them out: the
		# server stopped handling the connection (a client that froze sends nothing at all).
		verdict = VERDICT_SERVER
		summary = "Data from %s kept arriving until the timeout, so the server stopped handling their connection." % player
	elif own.seen and own.bad:
		verdict = VERDICT_PLAYER
		summary = "Only %s's connection had trouble; %s were fine." % [player, fine]
	elif own.seen and kind in ["timeout", "reset"]:
		verdict = VERDICT_PLAYER
		summary = "%s's connection ended while %s were fine." % [player, fine]
	else:
		summary = "Nothing went wrong on the server side%s." % (
				"" if own.seen else " (no connection statistics for %s on this computer)" % player)

	var evidence: Array[String] = []
	if own.seen:
		evidence.append_array(own.lines)
	evidence.append(tick.line)
	evidence.append_array(host.lines)
	if others.is_empty():
		evidence.append("Other players: nobody else was online to compare with.")
	else:
		var parts := PackedStringArray()
		for name: String in others:
			var o := player_summary(name, samples)
			parts.append("%s %s%s" % [name, o.ping_text, " (trouble)" if others[name] else " (fine)"])
		evidence.append("Other players at the same time: %s." % ", ".join(parts))
	return {"verdict": verdict, "summary": summary, "evidence": evidence}


## Judges trouble seen for everyone at once: [param key] is "tick", "router" or "internet".
static func judge_server(key: String, samples: Array, ticks: Array) -> Dictionary:
	var tick := tick_summary(ticks)
	var host := host_summary(samples)
	var evidence: Array[String] = [tick.line]
	evidence.append_array(host.lines)
	var names := {}
	for s: Dictionary in samples:
		for name: String in s.get("p", {}):
			names[name] = true
	if not names.is_empty():
		var parts := PackedStringArray()
		for name: String in names:
			parts.append("%s %s" % [name, player_summary(name, samples).ping_text])
		evidence.append("Players online: %s." % ", ".join(parts))
	var summary := ""
	if key == "tick":
		summary = "The server's ticks %s; every player sees this as lag." % (
				"stopped for %s" % _secs(tick.worst) if tick.freeze else
				("averaged %.0f ms (limit 50 ms)" % tick.peak_avg if tick.slow else "stuttered (one tick took %.0f ms)" % tick.worst))
		return {"verdict": VERDICT_SERVER, "summary": summary, "evidence": evidence}
	summary = "This computer's connection to the %s had trouble (%s); every player is affected." % [
			"router" if key == "router" else "internet", host.why if host.why != "" else "lost or slow pings"]
	return {"verdict": VERDICT_NETWORK, "summary": summary, "evidence": evidence}


## {line, worst, peak_avg, freeze, slow, seen}
static func tick_summary(ticks: Array) -> Dictionary:
	var worst := 0.0
	var peak_avg := 0.0
	var total := 0.0
	var n := 0
	var no_reply := 0
	var behind := 0
	for t: Dictionary in ticks:
		if int(t.get("rcon", 0)) < 0:
			no_reply += 1
		behind = maxi(behind, int(t.get("behind", 0)))
		if not t.has("avg"):
			continue
		worst = maxf(worst, float(t.max))
		peak_avg = maxf(peak_avg, float(t.avg))
		total += float(t.avg)
		n += 1
	var out := {"worst": maxf(worst, behind), "peak_avg": peak_avg, "seen": n > 0 or no_reply > 0}
	out.freeze = worst >= FREEZE_MS or no_reply > 0 or behind >= FREEZE_MS
	out.slow = peak_avg > TICK_LIMIT_MS or behind > 0
	if n == 0 and no_reply == 0:
		out.line = "Server tick: not measured (needs RCON)."
	elif no_reply > 0:
		out.line = "Server tick: the server did not answer for over 5 s (frozen)."
	else:
		var verdict := "frozen" if out.freeze else ("lagging" if out.slow else ("a short hitch, too short to drop anyone" if worst >= HITCH_MS else "normal"))
		out.line = "Server tick: %.1f ms on average, worst %.0f ms (limit 50 ms) — %s." % [total / n, worst, verdict]
		if behind > 0:
			out.line += " Paper reported falling %s behind." % _secs(behind)
	return out


## {lines, bad, why}: this computer's router and internet pings, Wi-Fi and upload.
static func host_summary(samples: Array) -> Dictionary:
	var lines: Array[String] = []
	var why := PackedStringArray()
	var bad := false
	for key: String in ["gw", "net"]:
		var vals := PackedFloat32Array()
		var lost := 0
		var slow := 0
		var limit := ROUTER_SLOW_MS if key == "gw" else INTERNET_SLOW_MS
		for s: Dictionary in samples:
			if not s.has(key):
				continue
			if float(s[key]) < 0.0:
				lost += 1
			else:
				vals.append(float(s[key]))
				if float(s[key]) >= limit:
					slow += 1
		var n := vals.size() + lost
		if n == 0:
			continue
		var label := "Server → router" if key == "gw" else "Server → internet"
		var text := "%s: %s, %d of %d pings lost" % [label, _ms_range(vals), lost, n]
		# One lost ping is noise; a third of them is a real problem.
		var trouble := (lost >= 2 and lost * 3 >= n) or (slow >= 2 and slow * 3 >= n)
		if trouble:
			bad = true
			why.append("%s %s" % ["router" if key == "gw" else "internet", "pings lost" if lost >= slow else "slow"])
		lines.append(text + (" — trouble." if trouble else " — normal."))
	var up := 0.0
	var wifi := 0
	for s: Dictionary in samples:
		up = maxf(up, float(s.get("up", 0)))
		if int(s.get("wifi", 0)) != 0:
			wifi = mini(wifi, int(s.wifi)) if wifi != 0 else int(s.wifi)
	if up > 0.0:
		lines.append("Server upload: peaked at %s." % mbit(up))
	if wifi != 0:
		lines.append("Server Wi-Fi signal: %d dBm at its weakest%s." % [wifi, " (weak)" if wifi <= -75 else ""])
	return {"lines": lines, "bad": bad, "why": ", ".join(why)}


## {seen, bad, lines, ping_text}: one player's connection over [param samples].
static func player_summary(player: String, samples: Array) -> Dictionary:
	var rtts := PackedFloat32Array()
	var best := INF
	var quiet := 0
	var loss := 0.0
	var backlog := 0
	var bad := false
	for s: Dictionary in samples:
		var p: Dictionary = s.get("p", {}).get(player, {})
		if p.is_empty():
			continue
		rtts.append(float(p.get("rtt", 0.0)))
		best = minf(best, float(p.get("min", p.get("rtt", 0.0))))
		quiet = maxi(quiet, int(p.get("quiet", 0)))
		loss = maxf(loss, float(p.get("loss", 0.0)))
		backlog = maxi(backlog, int(p.get("q", 0)))
		if player_trouble(p) != "":
			bad = true
	if rtts.is_empty():
		return {"seen": false, "bad": false, "quiet": 0, "lines": [], "ping_text": "(no data)"}
	var lines: Array[String] = []
	var ping := "%s: ping %s" % [player, _ms_range(rtts)]
	if best < INF:
		ping += " (their best %.0f ms)" % best
	lines.append(ping + ".")
	if quiet >= 1000:
		lines.append("%s: nothing arrived from their game for up to %s (normally several packets a second)." % [player, _secs(quiet)])
	if loss > 0.0:
		lines.append("%s: up to %.1f%% of data to them had to be resent%s." % [player, loss, " (packet loss)" if loss >= LOSS_PCT else ""])
	if backlog >= 65536:
		lines.append("%s: up to %s waited to reach them (their download could not keep up)." % [player, Fmt.bytes(backlog)])
	return {"seen": true, "bad": bad, "quiet": quiet, "lines": lines, "ping_text": _ms_range(rtts)}


# --- Text ---------------------------------------------------------------------------

## Plain-text write-up of [param incidents] (newest first) for sharing.
static func report(server_name: String, incidents: Array, window_sec: int, now: float) -> String:
	var lines := PackedStringArray()
	lines.append("Lag report for %s, %s" % [server_name, stamp(now)])
	var counts := {}
	var shown: Array = []
	for inc: Dictionary in incidents:
		if now - float(inc.get("t", 0.0)) <= window_sec:
			shown.append(inc)
			counts[inc.verdict] = int(counts.get(inc.verdict, 0)) + 1
	var span := Fmt.duration(window_sec)
	if shown.is_empty():
		lines.append("No incidents in the last %s." % span)
		return "\n".join(lines)
	var parts := PackedStringArray()
	for v: String in [VERDICT_SERVER, VERDICT_NETWORK, VERDICT_PLAYER, VERDICT_UNCLEAR]:
		if counts.has(v):
			parts.append("%d %s" % [counts[v], VERDICT_TITLES[v].to_lower()])
	lines.append("Last %s: %d incident%s (%s)." % [span, shown.size(), "" if shown.size() == 1 else "s", ", ".join(parts)])
	for inc: Dictionary in shown:
		lines.append("")
		lines.append(incident_text(inc))
	return "\n".join(lines)


static func incident_text(inc: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("%s  %s — %s" % [stamp(float(inc.t)), inc.title, VERDICT_TITLES.get(inc.verdict, "?")])
	lines.append("  " + str(inc.summary))
	for e in inc.get("evidence", []):
		lines.append("  • " + str(e))
	return "\n".join(lines)


static func mbit(bytes_per_sec: float) -> String:
	var mbps := bytes_per_sec * 8.0 / 1_000_000.0
	return "%.1f Mbit/s" % mbps if mbps < 100.0 else "%d Mbit/s" % int(mbps)


## Local date and time of a unix timestamp, to the second.
static func stamp(unix: float) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(int(unix) + bias, true)


## Local time of day of a unix timestamp.
static func clock(unix: float) -> String:
	return stamp(unix).get_slice(" ", 1)


static func _ms_range(vals: PackedFloat32Array) -> String:
	if vals.is_empty():
		return "no replies"
	var lo := INF
	var hi := 0.0
	var total := 0.0
	for v in vals:
		lo = minf(lo, v)
		hi = maxf(hi, v)
		total += v
	if hi - lo < 5.0:
		return "%.0f ms" % (total / vals.size())
	return "%.0f ms average, %.0f–%.0f ms" % [total / vals.size(), lo, hi]


static func _secs(ms: float) -> String:
	return "%.1f s" % (ms / 1000.0) if ms < 10000.0 else "%d s" % int(ms / 1000.0)
