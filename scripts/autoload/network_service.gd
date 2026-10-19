extends Node
## Internet-facing networking for all servers: UPnP port forwarding, the public IP
## address, NAT/firewall diagnosis and an on-demand reachability test.
##
## UPnP talks to the router with blocking calls, so every router operation runs on a
## worker thread, one at a time. Forwarding is reconciled declaratively: the wanted
## set (servers with UPnP enabled that are running or asleep) is compared with the
## active mappings and the difference is applied. The RCON port is never forwarded.
## Third-party lookups (api.ipify.org, api.mcsrvstat.us) only happen when the user
## asks for them (opening the Network tab, Refresh, Test from the internet).

signal status_changed
signal reachability_finished(server_id: String, result: Dictionary)
## A server's game port changed (from the Network or Resources tab, or a hand edit).
signal port_moved(server_id: String, old_port: int, new_port: int)

enum UpnpState { UNKNOWN, DISCOVERING, AVAILABLE, UNAVAILABLE }

## Router lease for a forward; renewed well before it expires.
const LEASE_SEC := 86400
const USER_AGENT := "GodotServerManager/0.1 (local Minecraft server manager)"
const IPIFY_URL := "https://api.ipify.org/?format=json"
const MCSRVSTAT_URL := "https://api.mcsrvstat.us/3/%s:%d"
## Comment on firewall rules this app creates; identifies them for later cleanup.
const APP_RULE_COMMENT := "Minecraft server (Server Manager)"
## How many old game ports are remembered for recognising stale rules.
const MAX_PREVIOUS_PORTS := 50
## Minimum time between automatic retries of a failed router discovery.
const REDISCOVER_MS := 60000

var upnp_state: UpnpState = UpnpState.UNKNOWN
var upnp_error := ""
## The router's own internet address as reported over UPnP ("" if unknown).
var upnp_external_ip := ""
var public_ip := ""
## Where [member public_ip] came from: "router (UPnP)" or "api.ipify.org".
var public_ip_source := ""
var public_ip_error := ""
var looking_up_public_ip := false
## Set by the app right before "Quit, leave servers running" so forwards of running servers survive.
var keep_mappings_on_exit := false
## Active forwards: port -> {"server_id": String, "desc": String}
var mappings := {}
## Last forwarding problem per server id.
var mapping_errors := {}

var _backend := UpnpBackend.new()
var _desired := {}
var _failed_ports := {}
var _renew_ports := {}
var _working := false
var _last_discover_msec := -REDISCOVER_MS
var _firewall := {}
## Server id -> last known game port, to notice port changes and deletions.
var _known_ports := {}
## Tests/screenshots: pretend this firewall is active ("ufw"/"firewalld") with these ufw rules.
var firewall_name_override := ""
var ufw_rules_override := ""

@onready var _renew_timer: Timer = %RenewTimer


func _ready() -> void:
	_renew_timer.timeout.connect(_renew)
	ServerManager.server_added.connect(_watch_instance)
	ServerManager.server_removed.connect(func(id: String) -> void:
		if _known_ports.has(id):
			remember_old_port(int(_known_ports[id]))
			_known_ports.erase(id)
		sync())
	ServerManager.server_state_changed.connect(func(_i: ServerInstance) -> void: sync())
	for inst in ServerManager.get_instances():
		_watch_instance(inst)
	sync.call_deferred()


func _exit_tree() -> void:
	# Remove forwards on exit, except for servers deliberately left running. Skipped while a
	# worker thread is using the router (it would race); leases expire on their own.
	if _working or upnp_state != UpnpState.AVAILABLE:
		return
	for port in mappings.keys():
		var inst := ServerManager.get_instance(str(mappings[port].server_id))
		if keep_mappings_on_exit and inst != null and inst.is_process_alive():
			continue
		_backend.delete_mapping(port)


## Replaces the router backend (tests use a mock).
func set_backend(backend: UpnpBackend) -> void:
	_backend = backend
	upnp_state = UpnpState.UNKNOWN
	upnp_external_ip = ""
	mappings.clear()
	mapping_errors.clear()
	_failed_ports.clear()
	_last_discover_msec = -REDISCOVER_MS


# --- Forwarding ---------------------------------------------------------------

## A server's port should be forwarded while it is reachable: running, or asleep with
## start-on-connect listening for players.
static func mapping_wanted(enabled: bool, alive: bool, asleep: bool) -> bool:
	return enabled and (alive or asleep)


## port -> {"server_id", "desc"} for every server that should be forwarded right now.
func desired_mappings() -> Dictionary:
	var out := {}
	for inst in ServerManager.get_instances():
		if mapping_wanted(inst.config.upnp_enabled, inst.is_process_alive(), inst.is_asleep()):
			out[inst.config.port] = {"server_id": inst.config.id, "desc": "Server Manager: " + inst.config.display_name}
	return out


## Re-evaluates forwarding. Discovers the router the first time it is needed.
func sync() -> void:
	apply_desired(desired_mappings())


## Reconciles active forwards with [param desired] (port -> {server_id, desc}).
func apply_desired(desired: Dictionary) -> void:
	_desired = desired
	if _desired.is_empty() and mappings.is_empty():
		return
	if upnp_state == UpnpState.UNKNOWN:
		discover()
		return
	if upnp_state == UpnpState.AVAILABLE:
		_work()


## Looks for the router (on a worker thread). Safe to call repeatedly.
func discover() -> void:
	if upnp_state == UpnpState.DISCOVERING or _working:
		return
	upnp_state = UpnpState.DISCOVERING
	_last_discover_msec = Time.get_ticks_msec()
	status_changed.emit()
	var backend := _backend
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary: return backend.discover())
	if result.ok:
		upnp_state = UpnpState.AVAILABLE
		upnp_error = ""
		upnp_external_ip = str(result.external_ip)
		_renew_timer.start(LEASE_SEC / 4.0)
		if classify_ip(upnp_external_ip) == "public" and (public_ip == "" or public_ip_source == "router (UPnP)"):
			public_ip = upnp_external_ip
			public_ip_source = "router (UPnP)"
	else:
		upnp_state = UpnpState.UNAVAILABLE
		upnp_error = str(result.error)
	status_changed.emit()
	if upnp_state == UpnpState.AVAILABLE:
		_work()


## Called when the Network tab is shown: discover if never tried, or retry a failed attempt.
func ensure_discovered() -> void:
	if upnp_state == UpnpState.UNKNOWN or (upnp_state == UpnpState.UNAVAILABLE and Time.get_ticks_msec() - _last_discover_msec > REDISCOVER_MS):
		discover()


## Forgets failed forwards for [param server_id] so the next sync tries again.
func retry(server_id: String) -> void:
	mapping_errors.erase(server_id)
	for port in _failed_ports.keys():
		if _failed_ports[port] == server_id:
			_failed_ports.erase(port)
	if upnp_state == UpnpState.UNAVAILABLE:
		upnp_state = UpnpState.UNKNOWN
	sync()


func is_forwarded(server_id: String) -> bool:
	for port in mappings:
		if mappings[port].server_id == server_id:
			return true
	return false


## Next router operation needed to match the wanted state, or {}.
func _next_action() -> Dictionary:
	for port in mappings:
		if not _desired.has(port) or _desired[port].desc != mappings[port].desc:
			return {"op": "delete", "port": port}
	for port in _desired:
		if _failed_ports.has(port):
			continue
		if not mappings.has(port) or _renew_ports.has(port):
			return {"op": "add", "port": port, "desc": _desired[port].desc, "server_id": _desired[port].server_id}
	return {}


func _work() -> void:
	if _working:
		return
	_working = true
	while upnp_state == UpnpState.AVAILABLE:
		var action := _next_action()
		if action.is_empty():
			break
		var backend := _backend
		var port: int = action.port
		if action.op == "add":
			var desc: String = action.desc
			var code: int = await FileOps.run_async(self, func() -> int: return backend.add_mapping(port, desc, LEASE_SEC))
			_renew_ports.erase(port)
			if code == UPNP.UPNP_RESULT_SUCCESS:
				mappings[port] = {"server_id": action.server_id, "desc": desc}
				mapping_errors.erase(action.server_id)
			else:
				_failed_ports[port] = action.server_id
				mapping_errors[action.server_id] = "The router did not forward port %d: %s." % [port, UpnpBackend.result_text(code)]
		else:
			await FileOps.run_async(self, func() -> int: return backend.delete_mapping(port))
			mappings.erase(port)
		status_changed.emit()
	_working = false


func _renew() -> void:
	for port in mappings:
		_renew_ports[port] = true
	_failed_ports.clear()
	sync()


func _watch_instance(inst: ServerInstance) -> void:
	inst.config_changed.connect(sync)
	_known_ports[inst.config.id] = inst.config.port
	inst.config_changed.connect(func() -> void: _check_port_change(inst))


func _check_port_change(inst: ServerInstance) -> void:
	if not is_instance_valid(inst):
		return
	var id := inst.config.id
	var old := int(_known_ports.get(id, inst.config.port))
	_known_ports[id] = inst.config.port
	if old != inst.config.port:
		remember_old_port(old)
		port_moved.emit(id, old, inst.config.port)


## Records a game port no managed server uses any more, so a rule left for it is recognised.
func remember_old_port(port: int) -> void:
	if port <= 0 or AppSettings.previous_game_ports.has(port):
		return
	AppSettings.previous_game_ports.append(port)
	while AppSettings.previous_game_ports.size() > MAX_PREVIOUS_PORTS:
		AppSettings.previous_game_ports.remove_at(0)
	AppSettings.save_settings()


# --- Public address ---------------------------------------------------------------

## Looks up the public IP (router first, then api.ipify.org). Only call on user request.
func refresh_public_ip() -> void:
	if looking_up_public_ip:
		# Another caller started a lookup; wait for its result instead of returning empty-handed.
		while looking_up_public_ip:
			await get_tree().process_frame
		return
	if classify_ip(upnp_external_ip) == "public":
		public_ip = upnp_external_ip
		public_ip_source = "router (UPnP)"
		public_ip_error = ""
		status_changed.emit()
		return
	looking_up_public_ip = true
	status_changed.emit()
	var res := await _get_json(IPIFY_URL)
	looking_up_public_ip = false
	if res.ok and res.data is Dictionary and str(res.data.get("ip", "")) != "":
		public_ip = str(res.data.ip)
		public_ip_source = "api.ipify.org"
		public_ip_error = ""
	else:
		public_ip_error = str(res.get("error", "Unexpected answer from api.ipify.org."))
	status_changed.emit()


## "ip:port" as players outside your network would type it ("" if the public IP is unknown).
func public_address(port: int) -> String:
	if public_ip == "":
		return ""
	return public_ip if port == 25565 else "%s:%d" % [public_ip, port]


## Classifies an IPv4 address: "public", "private", "cgnat", "loopback", "link-local", "ipv6" or "invalid".
static func classify_ip(ip: String) -> String:
	ip = ip.strip_edges()
	if ip.contains(":"):
		return "ipv6"
	var parts := ip.split(".")
	if parts.size() != 4:
		return "invalid"
	var o: Array[int] = []
	for p in parts:
		if not p.is_valid_int() or p.to_int() < 0 or p.to_int() > 255:
			return "invalid"
		o.append(p.to_int())
	if o[0] == 10 or (o[0] == 172 and o[1] >= 16 and o[1] <= 31) or (o[0] == 192 and o[1] == 168):
		return "private"
	if o[0] == 100 and o[1] >= 64 and o[1] <= 127:
		return "cgnat"
	if o[0] == 127:
		return "loopback"
	if o[0] == 169 and o[1] == 254:
		return "link-local"
	if o[0] == 0 or o[0] >= 224:
		return "invalid"
	return "public"


# --- Diagnosis ---------------------------------------------------------------------

## {"kind": "ok" | "cgnat" | "double_nat" | "unknown", "text": String}
func nat_diagnosis() -> Dictionary:
	return diagnose_nat(upnp_state == UpnpState.AVAILABLE, upnp_external_ip, public_ip)


## Pure NAT diagnosis (unit-tested).
static func diagnose_nat(upnp_available: bool, router_ip: String, observed_public_ip: String) -> Dictionary:
	if upnp_available and router_ip != "":
		match classify_ip(router_ip):
			"cgnat":
				return {"kind": "cgnat", "text": "Your router's internet address (%s) is a carrier-grade NAT address: your provider shares one public IP between many customers. Port forwarding on your router cannot make the server reachable. Ask your ISP for a public IPv4 address, or use a tunnel/proxy service." % router_ip}
			"private":
				return {"kind": "double_nat", "text": "Your router's internet address (%s) is private, so another router or modem sits in front of it (double NAT). Forward the port on that outer device too, or switch it to bridge mode." % router_ip}
		if observed_public_ip != "" and observed_public_ip != router_ip:
			return {"kind": "double_nat", "text": "Your router reports %s, but the internet sees you as %s. Something in between (a second router or your provider's CGNAT) also translates addresses, so forwarding on your router alone may not be enough." % [router_ip, observed_public_ip]}
		return {"kind": "ok", "text": "Your router has a public internet address (%s). Forwarding the port on it is enough." % router_ip}
	return {"kind": "unknown", "text": "Your router does not offer UPnP, so NAT can't be checked automatically. Forward the port manually, then use “Test from the internet”."}


## {"name": "ufw" | "firewalld" | "", "active": bool, "command": String}
func firewall_info(port: int) -> Dictionary:
	if firewall_name_override != "":
		return {"name": firewall_name_override, "active": true, "command": firewall_command(firewall_name_override, port)}
	if _firewall.is_empty():
		_firewall = _detect_firewall()
	var info := _firewall.duplicate()
	info.command = firewall_command(info.name, port)
	return info


## Whether this computer's firewall lets other machines reach [param port] (TCP).
## {name, active, allowed: "yes"|"no"|"lan"|"unknown", detail: String, source: String}.
## ufw is read from its rule files (world-readable, no root needed); firewalld is queried.
func firewall_port_status(port: int) -> Dictionary:
	var info := firewall_info(port)
	var result := {"name": info.name, "active": info.active, "allowed": "yes", "detail": "", "source": ""}
	if not info.active:
		return result
	match info.name:
		"ufw":
			var rules := _ufw_rules_text()
			var policy := "DROP" if ufw_rules_override != "" else ""
			for line in PlatformBackend.read_text("/etc/default/ufw").split("\n"):
				if line.begins_with("DEFAULT_INPUT_POLICY=") and ufw_rules_override == "":
					policy = line.get_slice("=", 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
			var verdict := ufw_port_verdict(rules, policy, port)
			result.merge(verdict, true)
		"firewalld":
			var code := PlatformBackend.execute("firewall-cmd", ["--query-port=%d/tcp" % port])
			result.allowed = "yes" if code == 0 else ("no" if code == 1 else "unknown")
	return result


## Evaluates ufw rule tuples (from /etc/ufw/user.rules) for incoming TCP to [param port].
## First matching rule wins, as in ufw; otherwise the default input policy applies.
static func ufw_port_verdict(rules_text: String, default_policy: String, port: int) -> Dictionary:
	for line in rules_text.split("\n"):
		if not line.begins_with("### tuple ###"):
			continue
		# action proto dport dst sport src [app fields] direction [comment=<hex>]
		var f := line.trim_prefix("### tuple ###").strip_edges().split(" ", false)
		while not f.is_empty() and f[-1].begins_with("comment="):
			f.remove_at(f.size() - 1)
		if f.size() < 6 or f[-1] != "in":
			continue
		var action := f[0]
		var proto := f[1]
		if proto != "tcp" and proto != "any":
			continue
		if not _ufw_port_matches(f[2], port):
			continue
		var src := f[5]
		var anywhere := src == "0.0.0.0/0" or src == "any"
		if action == "allow" or action.begins_with("limit"):
			if anywhere:
				return {"allowed": "yes", "detail": "ufw allows port %d from anywhere." % port, "source": src}
			var lan: bool = classify_ip(src.get_slice("/", 0)) == "private"
			return {"allowed": "lan" if lan else "no", "source": src,
					"detail": "ufw only allows port %d from %s%s." % [port, src, " (your home network)" if lan else ""]}
		return {"allowed": "no", "source": src, "detail": "A ufw rule %ss port %d." % [action, port]}
	if default_policy.to_upper() == "ACCEPT":
		return {"allowed": "yes", "detail": "ufw accepts incoming connections by default.", "source": ""}
	return {"allowed": "no", "source": "",
			"detail": "ufw blocks incoming connections by default and has no rule for port %d, so nobody else can connect, not even on your home network." % port}


static func _ufw_port_matches(spec: String, port: int) -> bool:
	if spec == "any":
		return true
	for part in spec.split(","):
		if part.contains(":"):
			if port >= part.get_slice(":", 0).to_int() and port <= part.get_slice(":", 1).to_int():
				return true
		elif part.is_valid_int() and part.to_int() == port:
			return true
	return false


## Opens [param port] (TCP) in the active firewall. ufw goes through pkexec, which shows
## the desktop's normal password prompt; firewalld asks polkit itself. Returns
## {ok: bool, message: String}. The rule set is re-read afterwards.
func allow_in_firewall(port: int, comment := "Minecraft server (Server Manager)") -> Dictionary:
	var fw := firewall_port_status(port)
	if not fw.active or fw.allowed == "yes":
		return {"ok": true, "message": "Port %d is already allowed." % port}
	var code := -1
	match fw.name:
		"ufw":
			var pkexec := PlatformBackend.find_in_path("pkexec")
			if pkexec == "":
				return {"ok": false, "message": "pkexec is not installed; run the command in a terminal instead."}
			var args := PackedStringArray(["ufw", "allow", "%d/tcp" % port, "comment", comment])
			code = await FileOps.run_async(self, func() -> int: return PlatformBackend.execute(pkexec, args))
		"firewalld":
			code = await FileOps.run_async(self, func() -> int:
				var c := PlatformBackend.execute("firewall-cmd", ["--permanent", "--add-port=%d/tcp" % port])
				return PlatformBackend.execute("firewall-cmd", ["--reload"]) if c == 0 else c)
		_:
			return {"ok": false, "message": "Unsupported firewall."}
	var after := firewall_port_status(port)
	if after.allowed == "yes":
		if not AppSettings.firewall_app_ports.has(port):
			AppSettings.firewall_app_ports.append(port)
			AppSettings.save_settings()
		status_changed.emit()
		return {"ok": true, "message": "Port %d is now allowed through %s." % [port, fw.name]}
	if code == 126 or code == 127:
		return {"ok": false, "message": "The password prompt was cancelled or the password was not accepted."}
	if code == 0:
		return {"ok": false, "message": "%s reported success, but the new rule for port %d could not be confirmed (%s). Check with: sudo ufw status" % [fw.name, port, after.detail]}
	return {"ok": false, "message": "%s did not open the port (exit code %d)." % [fw.name, code]}


# --- Firewall cleanup ---------------------------------------------------------------

func _ufw_rules_text() -> String:
	if ufw_rules_override != "":
		return ufw_rules_override
	return PlatformBackend.read_text("/etc/ufw/user.rules")


## Decodes ufw's hex-encoded rule comment ("comment=4d69…" or just the hex).
static func decode_ufw_comment(token: String) -> String:
	var hex := token.trim_prefix("comment=")
	if hex == "" or hex.length() % 2 != 0:
		return ""
	return hex.hex_decode().get_string_from_utf8()


## Parses the rule tuples in a ufw rules file. Each rule:
## {action, proto, port_spec, port (0 unless a single port), source, app, comment, direction}.
static func parse_ufw_rules(rules_text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for line in rules_text.split("\n"):
		if not line.begins_with("### tuple ###"):
			continue
		var f := line.trim_prefix("### tuple ###").strip_edges().split(" ", false)
		var comment := ""
		while not f.is_empty() and f[-1].begins_with("comment="):
			comment = decode_ufw_comment(f[-1])
			f.remove_at(f.size() - 1)
		# Plain rules have 7 fields; application-profile rules (e.g. KDE Connect) add dapp/sapp.
		if f.size() < 7:
			continue
		var app := f[6].uri_decode() if f.size() >= 9 and f[6] != "-" else ""
		out.append({
			"action": f[0], "proto": f[1], "port_spec": f[2],
			"port": f[2].to_int() if f[2].is_valid_int() else 0,
			"source": f[5], "app": app, "comment": comment, "direction": f[-1],
		})
	return out


## Rules that open a port no managed server uses any more and that belong to Minecraft:
## created by this app ("app"), or a rule the user added for a port a server used before
## or commented as Minecraft ("yours"). Unrelated rules (KDE Connect, other services) are
## never listed. [param rules] come from [method parse_ufw_rules] (or firewalld's port list).
static func cleanup_candidates(rules: Array[Dictionary], used_ports: Array, app_ports: Array, previous_ports: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for r in rules:
		var port: int = r.port
		if port <= 0 or r.app != "" or r.direction != "in" or used_ports.has(port):
			continue
		if not (r.action == "allow" or str(r.action).begins_with("limit")):
			continue
		if r.proto != "tcp" and r.proto != "any":
			continue
		var origin := ""
		if r.comment == APP_RULE_COMMENT or app_ports.has(port):
			origin = "app"
		elif previous_ports.has(port) or str(r.comment).containsn("minecraft"):
			origin = "yours"
		else:
			continue
		var key := "%d/%s/%s" % [port, r.proto, _source_key(r.source)]
		if seen.has(key):
			continue  # ufw keeps separate IPv4 and IPv6 copies of the same rule.
		seen[key] = true
		var rule := r.duplicate()
		rule.origin = origin
		out.append(rule)
	return out


## Firewall rules on this computer, in [method parse_ufw_rules] form. firewalld rules are
## read from `firewall-cmd --list-ports` (no comments, so only tracked ports count as "app").
func firewall_rules() -> Array[Dictionary]:
	var info := firewall_info(0)
	if not info.active:
		return []
	match info.name:
		"ufw":
			var text := _ufw_rules_text()
			if ufw_rules_override == "":
				text += "\n" + PlatformBackend.read_text("/etc/ufw/user6.rules")
			return parse_ufw_rules(text)
		"firewalld":
			var out: Array = []
			var rules: Array[Dictionary] = []
			if PlatformBackend.execute("firewall-cmd", ["--list-ports"], out) != 0 or out.is_empty():
				return rules
			for token in str(out[0]).strip_edges().split(" ", false):
				var spec := token.get_slice("/", 0)
				rules.append({"action": "allow", "proto": token.get_slice("/", 1), "port_spec": spec,
						"port": spec.to_int() if spec.is_valid_int() else 0, "source": "0.0.0.0/0",
						"app": "", "comment": "", "direction": "in"})
			return rules
	return []


## Minecraft firewall rules for ports no managed server uses any more (see [method cleanup_candidates]).
func stale_firewall_rules() -> Array[Dictionary]:
	var used: Array = []
	for inst in ServerManager.get_instances():
		used.append(inst.config.port)
	if RemoteAccess.enabled:
		used.append(RemoteAccess.port)
	return cleanup_candidates(firewall_rules(), used, Array(AppSettings.firewall_app_ports), Array(AppSettings.previous_game_ports))


## The rule (if any) this app opened for [param port], whether or not it is still in use.
func app_rule_for(port: int) -> Dictionary:
	for r in cleanup_candidates(firewall_rules(), [], Array(AppSettings.firewall_app_ports), Array(AppSettings.previous_game_ports)):
		if r.port == port and r.origin == "app":
			return r
	return {}


## "anywhere" for the IPv4/IPv6 any-address forms, otherwise the source itself.
static func _source_key(source: String) -> String:
	return "anywhere" if source in ["0.0.0.0/0", "::/0", "any"] else source


## Arguments (after pkexec) that delete [param rule] with ufw.
static func ufw_delete_args(rule: Dictionary) -> PackedStringArray:
	var port: int = rule.port
	var action: String = "limit" if str(rule.action).begins_with("limit") else "allow"
	var src: String = rule.get("source", "0.0.0.0/0")
	if _source_key(src) == "anywhere":
		return PackedStringArray(["ufw", "delete", action, "%d/tcp" % port if rule.proto == "tcp" else str(port)])
	var args := PackedStringArray(["ufw", "delete", action, "from", src, "to", "any", "port", str(port)])
	if rule.proto == "tcp":
		args.append_array(["proto", "tcp"])
	return args


## Deletes a firewall rule (normally a stale one). ufw goes through pkexec (the desktop's
## password prompt); firewalld asks polkit itself. The rules are re-read afterwards.
## Returns {ok: bool, message: String}.
func remove_firewall_rule(rule: Dictionary) -> Dictionary:
	var info := firewall_info(0)
	var port: int = rule.port
	var code := -1
	match info.name:
		"ufw":
			var pkexec := PlatformBackend.find_in_path("pkexec")
			if pkexec == "":
				return {"ok": false, "message": "pkexec is not installed; run “sudo %s” in a terminal instead." % " ".join(ufw_delete_args(rule))}
			var args := ufw_delete_args(rule)
			code = await FileOps.run_async(self, func() -> int: return PlatformBackend.execute(pkexec, args))
		"firewalld":
			code = await FileOps.run_async(self, func() -> int:
				var c := PlatformBackend.execute("firewall-cmd", ["--permanent", "--remove-port=%d/%s" % [port, "udp" if rule.proto == "udp" else "tcp"]])
				return PlatformBackend.execute("firewall-cmd", ["--reload"]) if c == 0 else c)
		_:
			return {"ok": false, "message": "No supported firewall is active."}
	var still := firewall_rules().any(func(r: Dictionary) -> bool:
		return r.port == port and r.proto == rule.proto and _source_key(r.source) == _source_key(rule.source) and r.direction == "in")
	status_changed.emit()
	if not still:
		var idx := AppSettings.firewall_app_ports.find(port)
		if idx >= 0:
			AppSettings.firewall_app_ports.remove_at(idx)
			AppSettings.save_settings()
		return {"ok": true, "message": "Removed the %s rule for port %d." % [info.name, port]}
	if code == 126 or code == 127:
		return {"ok": false, "message": "The password prompt was cancelled or the password was not accepted."}
	if code == 0:
		return {"ok": false, "message": "%s reported success, but the rule for port %d is still there. Check with: sudo ufw status numbered" % [info.name, port]}
	return {"ok": false, "message": "%s could not remove the rule for port %d (exit code %d)." % [info.name, port, code]}


static func firewall_command(name: String, port: int) -> String:
	match name:
		"ufw":
			return "sudo ufw allow %d/tcp comment 'Minecraft server'" % port
		"firewalld":
			return "sudo firewall-cmd --permanent --add-port=%d/tcp && sudo firewall-cmd --reload" % port
	return ""


func _detect_firewall() -> Dictionary:
	if OS.get_name() != "Linux":
		return {"name": "", "active": false}
	var out: Array = []
	if PlatformBackend.find_in_path("firewall-cmd") != "":
		PlatformBackend.execute("firewall-cmd", ["--state"], out, true)
		if not out.is_empty() and str(out[0]).strip_edges() == "running":
			return {"name": "firewalld", "active": true}
	out.clear()
	if PlatformBackend.find_in_path("systemctl") != "":
		PlatformBackend.execute("systemctl", ["is-active", "ufw"], out)
		if not out.is_empty() and str(out[0]).strip_edges() == "active":
			return {"name": "ufw", "active": true}
	return {"name": "", "active": false}


# --- Reachability ------------------------------------------------------------------

## Asks api.mcsrvstat.us whether the server answers from the internet. On demand only.
func test_reachability(inst: ServerInstance) -> Dictionary:
	if public_ip == "":
		await refresh_public_ip()
	var result: Dictionary
	if public_ip == "":
		result = {"ok": false, "online": false, "error": "Your public IP address could not be determined (%s)." % public_ip_error}
	else:
		var res := await _get_json(MCSRVSTAT_URL % [public_ip, inst.config.port])
		if res.ok and res.data is Dictionary:
			result = parse_mcsrvstat(res.data)
			result.ok = true
		else:
			result = {"ok": false, "online": false, "error": str(res.get("error", "Unexpected answer from api.mcsrvstat.us."))}
	reachability_finished.emit(inst.config.id, result)
	return result


## Normalises an api.mcsrvstat.us v3 answer:
## {online, version, motd, players_online, players_max, error, cache_hit}.
static func parse_mcsrvstat(data: Dictionary) -> Dictionary:
	var debug: Dictionary = data.get("debug", {}) if data.get("debug") is Dictionary else {}
	var errors := PackedStringArray()
	var err_value = debug.get("error", {})
	if err_value is Dictionary:
		for key in err_value:
			errors.append(str(err_value[key]))
	elif err_value is String and err_value != "":
		errors.append(err_value)
	var motd := ""
	var motd_value = data.get("motd", {})
	if motd_value is Dictionary and motd_value.get("clean") is Array:
		motd = " ".join(PackedStringArray(motd_value.clean)).strip_edges()
	var players: Dictionary = data.get("players", {}) if data.get("players") is Dictionary else {}
	return {
		"online": bool(data.get("online", false)),
		"version": str(data.get("version", "")),
		"motd": motd,
		"players_online": int(players.get("online", 0)),
		"players_max": int(players.get("max", 0)),
		"error": "; ".join(errors),
		"cache_hit": bool(debug.get("cachehit", false)),
	}


## Likely reasons a reachability test failed, most specific first.
func explain_failure(inst: ServerInstance, result: Dictionary) -> PackedStringArray:
	var reasons := PackedStringArray()
	if not inst.is_process_alive() and not inst.is_asleep():
		reasons.append("The server is stopped and “Start on connect” is off, so nothing answers on port %d. Start it (or enable Start on connect) and test again." % inst.config.port)
		return reasons
	var nat := nat_diagnosis()
	if nat.kind == "cgnat" or nat.kind == "double_nat":
		reasons.append(nat.text)
	if inst.config.upnp_enabled:
		if upnp_state != UpnpState.AVAILABLE:
			reasons.append("UPnP forwarding is on, but no UPnP router was found (%s). Forward TCP port %d to %s manually in your router." % [upnp_error, inst.config.port, ServerInstance._lan_ip()])
		elif mapping_errors.has(inst.config.id):
			reasons.append(mapping_errors[inst.config.id])
	else:
		reasons.append("Make sure your router forwards TCP port %d to this computer (%s), or turn on UPnP forwarding above." % [inst.config.port, ServerInstance._lan_ip()])
	var fw := firewall_port_status(inst.config.port)
	if fw.active and fw.allowed != "yes":
		reasons.append("%s Allow it with: %s" % [fw.detail if fw.detail != "" else "%s may block the port." % fw.name,
				firewall_command(fw.name, inst.config.port)])
	if str(result.get("error", "")) != "":
		reasons.append("mcsrvstat.us reported: %s" % result.error)
	return reasons


func _get_json(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 20
	add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: application/json"]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Request failed: %s" % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "Network error (%d) — are you online?" % response[0]}
	if response[1] != 200:
		return {"ok": false, "error": "HTTP %d" % response[1]}
	var data = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if data == null:
		return {"ok": false, "error": "Invalid response"}
	return {"ok": true, "data": data}
