extends TestCase

const PAPER_SAMPLE := "# Paper world defaults\n_version: 31\nanticheat:\n  anti-xray:\n    enabled: false\n    engine-mode: 1\n    hidden-blocks:\n    - copper_ore\n    - '#minecraft:ores'\nmisc:\n  redstone-implementation: VANILLA\n  max-leash-distance: default\nmessages:\n  no-permission: '<red>I''m sorry: no'\n"


func test_yaml_get_and_replace() -> void:
	var y := YamlDoc.new()
	y.parse(PAPER_SAMPLE)
	check_eq(y.get_value("anticheat.anti-xray.enabled"), "false", "nested get")
	check_eq(y.get_value("messages.no-permission"), "<red>I'm sorry: no", "quoted with colon")
	check_eq(y.get_value("missing.key", "d"), "d", "default")
	check_eq(y.get_value("anticheat.anti-xray", "block"), "block", "mapping is not a scalar")
	y.set_value("anticheat.anti-xray.enabled", "true")
	y.set_value("misc.redstone-implementation", "ALTERNATE_CURRENT")
	var out := y.to_text()
	check(out.contains("    enabled: true\n    engine-mode: 1\n    hidden-blocks:\n    - copper_ore\n"), "replaced in place, list kept")
	check(out.contains("  redstone-implementation: ALTERNATE_CURRENT\n  max-leash-distance: default\n"), "replace keeps order")
	check(out.begins_with("# Paper world defaults\n_version: 31\n"), "comments kept")


func test_yaml_insert_missing_paths() -> void:
	var y := YamlDoc.new()
	y.parse(PAPER_SAMPLE)
	y.set_value("anticheat.anti-xray.lava-obscures", "true")
	y.set_value("misc.disable-end-credits", "true")
	y.set_value("environment.treasure-maps.enabled", "false")
	var again := YamlDoc.new()
	again.parse(y.to_text())
	check_eq(again.get_value("anticheat.anti-xray.lava-obscures"), "true", "inserted under existing mapping after list")
	check_eq(again.get_value("anticheat.anti-xray.engine-mode"), "1", "sibling intact")
	check_eq(again.get_value("misc.disable-end-credits"), "true", "inserted sibling")
	check_eq(again.get_value("environment.treasure-maps.enabled"), "false", "new root mapping")
	check_eq(again.get_value("messages.no-permission"), "<red>I'm sorry: no", "later section intact")
	var empty := YamlDoc.new()
	empty.set_value("settings.allow-end", "false")
	empty.set_value("settings.connection-throttle", "1000")
	check_eq(empty.to_text(), "settings:\n  allow-end: false\n  connection-throttle: 1000\n", "build from empty")


func test_yaml_format_scalar() -> void:
	check_eq(YamlDoc.format_scalar("Server closed", true), "Server closed", "plain string")
	check_eq(YamlDoc.format_scalar("", true), "''", "empty string")
	check_eq(YamlDoc.format_scalar("yes", true), "'yes'", "reserved word quoted")
	check_eq(YamlDoc.format_scalar("a: b", true), "'a: b'", "colon quoted")
	check_eq(YamlDoc.format_scalar("it's", true), "it's", "inner apostrophe is plain")
	check_eq(YamlDoc.format_scalar("'q", true), "'''q'", "leading quote escaped")
	check_eq(YamlDoc.format_scalar("12", false), "12", "number bare")


func test_catalog_version_gating() -> void:
	var old_ids := SettingsCatalog.for_version("1.20.4").map(func(e: Dictionary) -> String: return e.id)
	var new_ids := SettingsCatalog.for_version("26.3").map(func(e: Dictionary) -> String: return e.id)
	check(old_ids.has("pvp") and not old_ids.has("gamerule.pvp"), "1.20.4 uses the pvp property")
	check(new_ids.has("gamerule.pvp") and not new_ids.has("pvp"), "26.3 uses the pvp game rule")
	check(not SettingsCatalog.for_version("1.18.2").map(func(e: Dictionary) -> String: return e.id).has("gamerule.locator_bar"), "locator bar gated")
	check(not SettingsCatalog.for_version("1.16.5").any(func(e: Dictionary) -> bool: return e.get("file", "") == SettingsCatalog.PAPER_WORLD), "paper config gated before 1.19")
	var keep := SettingsCatalog.get_entry("gamerule.keep_inventory")
	check_eq(SettingsCatalog.rule_name(keep, "1.21.4"), "keepInventory", "legacy rule name")
	check_eq(SettingsCatalog.rule_name(keep, "1.21.11"), "keep_inventory", "snake rule name")
	check_eq(SettingsCatalog.rule_commands(keep, "true", "1.12.2"), PackedStringArray(["gamerule keepInventory true"]), "pre-1.13 command")
	check_eq(SettingsCatalog.rule_commands(keep, "true", "26.3").size(), 3, "one command per dimension")
	check_eq(Fmt.compare_versions("26.1", "1.21.11"), 1, "new version scheme compares higher")
	check_eq(LogParser.parse_gamerule("Gamerule pvp is currently set to: true"), "true", "1.21 reply")
	check_eq(LogParser.parse_gamerule("Game rule pvp is currently set to false"), "false", "26.x reply")
	check_eq(LogParser.joined_player("[12:00:00 INFO]: System chat: Steve joined the game"), "Steve", "26.x join line")


func test_server_settings_round_trip() -> void:
	var dir := ProjectSettings.globalize_path("user://test-settings-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	var cfg := ServerConfig.new()
	cfg.directory = dir
	cfg.mc_version = "26.3"
	var s := ServerSettings.open(cfg)
	s.set_by_id("motd", "Hello")
	s.set_by_id("bukkit.yml::settings.allow-end", "false")
	s.set_by_id("config/paper-world-defaults.yml::misc.redstone-implementation", "ALTERNATE_CURRENT")
	s.set_by_id("bukkit.yml::settings.shutdown-message", "Bye: see you")
	s.set_by_id("gamerule.keep_inventory", "true")
	check_eq(s.save(), OK, "save")
	check_eq(cfg.pending_gamerules.get("gamerule.keep_inventory"), "true", "game rule queued")
	var r := ServerSettings.open(cfg)
	check_eq(r.get_value(SettingsCatalog.get_entry("motd")), "Hello", "property")
	check_eq(r.get_value(SettingsCatalog.get_entry("bukkit.yml::settings.allow-end")), "false", "bukkit yaml")
	check_eq(r.get_value(SettingsCatalog.get_entry("bukkit.yml::settings.shutdown-message")), "Bye: see you", "quoted yaml string")
	check_eq(r.get_value(SettingsCatalog.get_entry("config/paper-world-defaults.yml::misc.redstone-implementation")), "ALTERNATE_CURRENT", "paper yaml in config/")
	check_eq(r.get_value(SettingsCatalog.get_entry("gamerule.keep_inventory")), "true", "pending rule visible")
	check_eq(r.get_value(SettingsCatalog.get_entry("view-distance")), "10", "default when unset")
	check(FileAccess.file_exists(dir.path_join("config/paper-world-defaults.yml")), "config dir created")
	FileOps.remove_tree(dir)


func test_port_field_never_rewrites_typing() -> void:
	var field: PortField = load("res://scenes/components/port_field.tscn").instantiate()
	field.set_port(25565)
	check(field.is_valid(), "25565 valid")
	# Backspacing down to "255" must leave "255" in the box (a SpinBox snapped it to 1024).
	for t in ["2556", "255", "25", "2", ""]:
		field.text = t
		field._on_text_changed(t)
		check_eq(field.text, t, "text kept while typing '%s'" % t)
	check(not field.is_valid(), "empty is invalid")
	field.text = "2314"
	field._on_text_changed("2314")
	check(field.is_valid() and field.port == 2314, "new port accepted")
	field.text = "23a14"
	field._on_text_changed("23a14")
	check_eq(field.text, "2314", "non-digits dropped")
	field.text = "80"
	field._on_text_changed("80")
	check(not field.is_valid() and field.error_text().contains("administrator"), "privileged port explained")
	field.free()
