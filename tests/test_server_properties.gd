extends TestCase

const SAMPLE := "#Minecraft server properties\n#Sat Oct 18 15:00:00 CEST 2026\naccepts-transfers=false\nmotd=A \\u00A7aGreen\\u00A7r server\nserver-port=25565\nlevel-type=minecraft\\:normal\nmax-players=20\ncustom-plugin-key=hello world\n"


func test_parse_and_get() -> void:
	var p := ServerProperties.new()
	p.parse(SAMPLE)
	check_eq(p.get_value("motd"), "A §aGreen§r server", "unicode unescape")
	check_eq(p.get_int("max-players"), 20, "int")
	check_eq(p.get_value("level-type"), "minecraft:normal", "escaped colon")
	check_eq(p.get_bool("accepts-transfers", true), false, "bool")
	check_eq(p.get_value("missing", "dflt"), "dflt", "default")


func test_round_trip_preserves_comments_order_and_unknown_keys() -> void:
	var p := ServerProperties.new()
	p.parse(SAMPLE)
	p.set_value("max-players", 50)
	p.set_value("new-key", true)
	var out := p.to_text()
	check(out.begins_with("#Minecraft server properties\n#Sat Oct 18"), "comments kept at top")
	check(out.contains("max-players=50\n"), "updated value")
	check(out.contains("custom-plugin-key=hello world\n"), "unknown key kept")
	check(out.ends_with("new-key=true\n"), "new key appended")
	check(out.find("accepts-transfers") < out.find("server-port"), "order kept")
	var again := ServerProperties.new()
	again.parse(out)
	check_eq(again.get_value("motd"), "A §aGreen§r server", "unicode survives round trip")
	check_eq(again.keys(), p.keys(), "same keys after round trip")


func test_escape_non_ascii_and_emoji() -> void:
	var escaped := ServerProperties.escape("Héllo 😀", false)
	check_eq(escaped, "H\\u00e9llo \\ud83d\\ude00", "escape")
	check_eq(ServerProperties.unescape(escaped), "Héllo 😀", "unescape surrogate pair")
