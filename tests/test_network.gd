extends TestCase

const MockBackend := preload("res://tests/mock_upnp_backend.gd")


func _wait(cond: Callable, seconds := 3.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.05).timeout


func test_ip_classification() -> void:
	var NS := NetworkService
	check_eq(NS.classify_ip("8.8.8.8"), "public", "public")
	check_eq(NS.classify_ip("192.168.4.22"), "private", "192.168/16")
	check_eq(NS.classify_ip("10.0.0.1"), "private", "10/8")
	check_eq(NS.classify_ip("172.16.5.4"), "private", "172.16/12 start")
	check_eq(NS.classify_ip("172.32.0.1"), "public", "just outside 172.16/12")
	check_eq(NS.classify_ip("100.64.0.1"), "cgnat", "CGNAT start")
	check_eq(NS.classify_ip("100.127.255.254"), "cgnat", "CGNAT end")
	check_eq(NS.classify_ip("100.128.0.1"), "public", "just outside CGNAT")
	check_eq(NS.classify_ip("127.0.0.1"), "loopback", "loopback")
	check_eq(NS.classify_ip("169.254.1.1"), "link-local", "link-local")
	check_eq(NS.classify_ip("2001:db8::1"), "ipv6", "ipv6")
	check_eq(NS.classify_ip("300.1.1.1"), "invalid", "out of range")
	check_eq(NS.classify_ip(""), "invalid", "empty")


func test_nat_diagnosis() -> void:
	var NS := NetworkService
	check_eq(NS.diagnose_nat(true, "100.70.1.2", "").kind, "cgnat", "router behind CGNAT")
	check_eq(NS.diagnose_nat(true, "192.168.0.5", "").kind, "double_nat", "router behind another router")
	check_eq(NS.diagnose_nat(true, "203.0.113.7", "198.51.100.9").kind, "double_nat", "router IP differs from observed IP")
	check_eq(NS.diagnose_nat(true, "203.0.113.7", "203.0.113.7").kind, "ok", "public router IP")
	check_eq(NS.diagnose_nat(false, "", "203.0.113.7").kind, "unknown", "no UPnP")


func test_mcsrvstat_parsing() -> void:
	var online := NetworkService.parse_mcsrvstat({
		"online": true, "ip": "203.0.113.7", "port": 25565, "version": "Paper 1.21.11",
		"motd": {"raw": ["§aHi"], "clean": ["Hi", "there"], "html": []},
		"players": {"online": 2, "max": 20},
		"debug": {"ping": true, "cachehit": true, "apiversion": 3},
	})
	check_eq(online.online, true, "online")
	check_eq(online.version, "Paper 1.21.11", "version")
	check_eq(online.motd, "Hi there", "motd joined")
	check_eq(online.players_online, 2, "players")
	check_eq(online.cache_hit, true, "cache hit")
	var offline := NetworkService.parse_mcsrvstat({
		"online": false, "ip": "203.0.113.7", "port": 25570,
		"debug": {"ping": false, "error": {"ping": "Failed to connect or create a socket: 111 (Connection refused)"}},
	})
	check_eq(offline.online, false, "offline")
	check(offline.error.contains("Connection refused"), "error text: " + offline.error)
	check_eq(NetworkService.parse_mcsrvstat({}).online, false, "empty payload is offline")


func test_mapping_wanted() -> void:
	var NS := NetworkService
	check(NS.mapping_wanted(true, true, false), "running")
	check(NS.mapping_wanted(true, false, true), "asleep (start on connect)")
	check(not NS.mapping_wanted(true, false, false), "stopped")
	check(not NS.mapping_wanted(false, true, false), "UPnP off")


func test_forwarding_reconciliation_with_mock_router() -> void:
	# Let NetworkService's own deferred startup sync (no servers here) run first.
	await (Engine.get_main_loop() as SceneTree).process_frame
	await (Engine.get_main_loop() as SceneTree).process_frame
	var mock := MockBackend.new()
	NetworkService.set_backend(mock)
	NetworkService.apply_desired({25565: {"server_id": "a", "desc": "Server Manager: A"}})
	await _wait(func() -> bool: return NetworkService.is_forwarded("a"))
	check_eq(NetworkService.upnp_state, NetworkService.UpnpState.AVAILABLE, "router discovered")
	check_eq(mock.forwards.get(25565, ""), "Server Manager: A", "port forwarded with description")
	check_eq(mock.lease_seen, NetworkService.LEASE_SEC, "lease used")
	check(NetworkService.is_forwarded("a"), "is_forwarded")
	check_eq(NetworkService.public_ip, "203.0.113.7", "public IP taken from the router")

	mock.refuse_ports[25566] = true
	NetworkService.apply_desired({25565: {"server_id": "a", "desc": "Server Manager: A"}, 25566: {"server_id": "b", "desc": "Server Manager: B"}})
	await _wait(func() -> bool: return NetworkService.mapping_errors.has("b"))
	check(NetworkService.mapping_errors.has("b"), "refused forward reported")
	check(not mock.forwards.has(25566), "refused port not forwarded")

	NetworkService.apply_desired({25566: {"server_id": "b", "desc": "Server Manager: B"}})
	await _wait(func() -> bool: return not NetworkService.is_forwarded("a"))
	check(not mock.forwards.has(25565), "forward removed when no longer wanted")
	check(not NetworkService.is_forwarded("a"), "mapping state updated")

	NetworkService.apply_desired({25565: {"server_id": "a", "desc": "Server Manager: Renamed"}})
	await _wait(func() -> bool: return mock.forwards.get(25565, "") == "Server Manager: Renamed" and NetworkService.is_forwarded("a"))
	check_eq(mock.forwards.get(25565, ""), "Server Manager: Renamed", "re-forwarded after rename")
	NetworkService.apply_desired({})
	await _wait(func() -> bool: return NetworkService.mappings.is_empty() and not NetworkService._working)
	check(mock.forwards.is_empty(), "all forwards removed")

	var none := MockBackend.new()
	none.has_gateway = false
	NetworkService.set_backend(none)
	NetworkService.apply_desired({25565: {"server_id": "a", "desc": "x"}})
	await _wait(func() -> bool: return NetworkService.upnp_state == NetworkService.UpnpState.UNAVAILABLE)
	check_eq(NetworkService.upnp_state, NetworkService.UpnpState.UNAVAILABLE, "no router → unavailable")
	check(NetworkService.upnp_error != "", "error explained")
	NetworkService.set_backend(MockBackend.new())
	NetworkService.public_ip = ""
	NetworkService.public_ip_source = ""


func test_firewall_commands() -> void:
	check_eq(NetworkService.firewall_command("ufw", 25570), "sudo ufw allow 25570/tcp comment 'Minecraft server'", "ufw")
	check(NetworkService.firewall_command("firewalld", 25570).contains("--add-port=25570/tcp"), "firewalld")
	check_eq(NetworkService.firewall_command("", 25570), "", "none")


func test_ufw_port_verdict() -> void:
	var kde := "### tuple ### allow udp 1714:1764 0.0.0.0/0 any 0.0.0.0/0 KDE%20Connect - in\n### tuple ### allow tcp 1714:1764 0.0.0.0/0 any 0.0.0.0/0 KDE%20Connect - in\n"
	check_eq(NetworkService.ufw_port_verdict(kde, "DROP", 25565).allowed, "no", "default drop, no rule")
	check_eq(NetworkService.ufw_port_verdict(kde, "DROP", 1720).allowed, "yes", "port inside an allowed range")
	var mc := kde + "### tuple ### allow tcp 25565 0.0.0.0/0 any 0.0.0.0/0 in\n"
	check_eq(NetworkService.ufw_port_verdict(mc, "DROP", 25565).allowed, "yes", "explicit allow")
	var lan := "### tuple ### allow tcp 25565 0.0.0.0/0 any 192.168.4.0/22 in\n"
	check_eq(NetworkService.ufw_port_verdict(lan, "DROP", 25565).allowed, "lan", "allowed from home network only")
	var deny_first := "### tuple ### deny tcp 25565 0.0.0.0/0 any 0.0.0.0/0 in\n### tuple ### allow tcp 25565 0.0.0.0/0 any 0.0.0.0/0 in\n"
	check_eq(NetworkService.ufw_port_verdict(deny_first, "DROP", 25565).allowed, "no", "first matching rule wins")
	check_eq(NetworkService.ufw_port_verdict("", "ACCEPT", 25565).allowed, "yes", "accept policy")
	var udp_only := "### tuple ### allow udp 25565 0.0.0.0/0 any 0.0.0.0/0 in\n"
	check_eq(NetworkService.ufw_port_verdict(udp_only, "DROP", 25565).allowed, "no", "udp rule does not open tcp")


func test_ufw_rule_with_comment() -> void:
	# Exactly what `ufw allow 2314/tcp comment '…'` writes (seen on a real system).
	var rules := "### tuple ### allow tcp 1714:1764 0.0.0.0/0 any 0.0.0.0/0 KDE%20Connect - in\n" \
		+ "### tuple ### allow tcp 2314 0.0.0.0/0 any 0.0.0.0/0 in comment=4d696e656372616674207365727665722028536572766572204d616e6167657229\n"
	check_eq(NetworkService.ufw_port_verdict(rules, "DROP", 2314).allowed, "yes", "commented rule is recognised")
	check_eq(NetworkService.ufw_port_verdict(rules, "DROP", 25565).allowed, "no", "other ports still blocked")
	var out_rule := "### tuple ### allow tcp 2314 0.0.0.0/0 any 0.0.0.0/0 out comment=6869\n"
	check_eq(NetworkService.ufw_port_verdict(out_rule, "DROP", 2314).allowed, "no", "outgoing rule does not count")
