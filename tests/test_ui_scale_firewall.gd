extends TestCase

## Shaped like a real /etc/ufw/user.rules (+ user6.rules): KDE Connect app rules, a rule
## this app created (hex comment), a hand-made Minecraft rule, an unrelated rule and an IPv6 copy.
const RULES := "### tuple ### allow udp 1714:1764 0.0.0.0/0 any 0.0.0.0/0 KDE%20Connect - in\n" \
	+ "### tuple ### allow tcp 1714:1764 0.0.0.0/0 any 0.0.0.0/0 KDE%20Connect - in\n" \
	+ "### tuple ### allow tcp 2314 0.0.0.0/0 any 0.0.0.0/0 in comment=4d696e656372616674207365727665722028536572766572204d616e6167657229\n" \
	+ "### tuple ### allow tcp 25570 0.0.0.0/0 any 0.0.0.0/0 in\n" \
	+ "### tuple ### allow tcp 25580 0.0.0.0/0 any 0.0.0.0/0 in comment=4d696e6563726166742073657276657220\n" \
	+ "### tuple ### allow tcp 8080 0.0.0.0/0 any 0.0.0.0/0 in\n" \
	+ "### tuple ### allow tcp 25565 0.0.0.0/0 any 0.0.0.0/0 in comment=4d696e656372616674207365727665722028536572766572204d616e6167657229\n" \
	+ "### tuple ### allow tcp 2314 ::/0 any ::/0 in comment=4d696e656372616674207365727665722028536572766572204d616e6167657229\n"


func test_decode_ufw_comment() -> void:
	check_eq(NetworkService.decode_ufw_comment("comment=4d696e656372616674207365727665722028536572766572204d616e6167657229"), "Minecraft server (Server Manager)", "app comment")
	check_eq(NetworkService.decode_ufw_comment("4869"), "Hi", "bare hex")
	check_eq(NetworkService.decode_ufw_comment("comment=abc"), "", "odd-length hex rejected")


func test_parse_ufw_rules() -> void:
	var rules := NetworkService.parse_ufw_rules(RULES)
	check_eq(rules.size(), 8, "all tuples parsed")
	check_eq(rules[0].app, "KDE Connect", "application profile name decoded")
	check_eq(rules[0].port, 0, "port range is not a single port")
	check_eq(rules[2].port, 2314, "single port")
	check_eq(rules[2].comment, NetworkService.APP_RULE_COMMENT, "comment decoded")
	check_eq(rules[2].direction, "in", "direction found before the comment")
	check_eq(rules[3].comment, "", "uncommented rule")


func test_stale_rule_detection() -> void:
	var rules := NetworkService.parse_ufw_rules(RULES)
	# The user's real situation: the server uses 25565; 2314 was opened by the app earlier.
	var stale := NetworkService.cleanup_candidates(rules, [25565], [], [25570])
	var ports := stale.map(func(r: Dictionary) -> int: return r.port)
	check_eq(ports, [2314, 25570, 25580], "stale Minecraft rules only")
	check_eq(stale[0].origin, "app", "app-created rule")
	check_eq(stale[1].origin, "yours", "hand-made rule for a port a server used before")
	check_eq(stale[2].origin, "yours", "hand-made rule commented as Minecraft")
	check(not ports.has(8080), "unrelated rule never listed")
	check(not ports.has(25565), "port in use is not stale")
	check_eq(ports.count(2314), 1, "IPv4 and IPv6 copies count once")
	var tracked := NetworkService.cleanup_candidates(NetworkService.parse_ufw_rules("### tuple ### allow tcp 30000 0.0.0.0/0 any 0.0.0.0/0 in\n"), [], [30000], [])
	check_eq(tracked.size() == 1 and tracked[0].origin == "app", true, "ports recorded as opened by the app count as app rules (firewalld has no comments)")


func test_ufw_delete_args() -> void:
	var rules := NetworkService.parse_ufw_rules(RULES)
	check_eq(NetworkService.ufw_delete_args(rules[2]), PackedStringArray(["ufw", "delete", "allow", "2314/tcp"]), "tcp from anywhere")
	var any_proto := NetworkService.parse_ufw_rules("### tuple ### allow any 25565 0.0.0.0/0 any 0.0.0.0/0 in\n")[0]
	check_eq(NetworkService.ufw_delete_args(any_proto), PackedStringArray(["ufw", "delete", "allow", "25565"]), "any protocol")
	var lan := NetworkService.parse_ufw_rules("### tuple ### allow tcp 25565 0.0.0.0/0 any 192.168.4.0/22 in\n")[0]
	check_eq(NetworkService.ufw_delete_args(lan), PackedStringArray(["ufw", "delete", "allow", "from", "192.168.4.0/22", "to", "any", "port", "25565", "proto", "tcp"]), "limited source")
	check_eq(NetworkService.firewall_command("ufw", 2314), "sudo ufw allow 2314/tcp comment 'Minecraft server'", "manual allow command")


func test_ui_scale() -> void:
	check_eq(UiScale.automatic_factor(1.0, 108), 1.0, "this machine: 108 dpi, no desktop scale")
	check_eq(UiScale.automatic_factor(1.0, 144), 1.5, "144 dpi")
	check_eq(UiScale.automatic_factor(1.0, 125), 1.25, "125 dpi")
	check_eq(UiScale.automatic_factor(1.0, 220), 2.0, "high dpi")
	check_eq(UiScale.automatic_factor(1.5, 96), 1.5, "desktop scale wins")
	check_eq(UiScale.effective(1.75, 1.0, 108, Vector2i(5120, 1410)), 1.75, "fits on a 1440p screen")
	check_eq(UiScale.effective(2.0, 1.0, 108, Vector2i(5120, 1410)), 1.95, "200 % needs 1440 px of height; capped on a 1410 px usable screen")
	check_eq(UiScale.effective(2.0, 1.0, 108, Vector2i(1366, 728)), 1.0, "capped so the window fits a small screen")
	check_eq(UiScale.effective(2.0, 1.0, 108, Vector2i(1920, 1050)), 1.45, "capped on a 1080p screen")
	check_eq(UiScale.effective(0.0, 1.0, 108, Vector2i(1920, 1050)), 1.0, "automatic")
	check_eq(UiScale.effective(0.75, 1.0, 108, Vector2i(1920, 1050)), 0.75, "smaller than default")
	check_eq(UiScale.option_label(0.0, 1.25), "Automatic (125 %)", "automatic label")
	check_eq(UiScale.option_label(1.5, 1.0), "150 %", "fixed label")
