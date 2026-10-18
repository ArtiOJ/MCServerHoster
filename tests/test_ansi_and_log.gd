extends TestCase


func test_strip() -> void:
	check_eq(Ansi.strip("\u001b[32mHello\u001b[0m §aworld"), "Hello world", "strip ansi and section codes")


func test_to_bbcode_colors_and_escapes() -> void:
	var bb := Ansi.to_bbcode("\u001b[31m[ERR]\u001b[0m ok")
	check_eq(bb, "[color=#e06c75][lb]ERR][/color] ok", "ansi red + bracket escape")
	check_eq(Ansi.to_bbcode("plain", "#aaaaaa"), "[color=#aaaaaa]plain[/color]", "default colour")
	check_eq(Ansi.to_bbcode("§cRed§r x"), "[color=#ff6b6b]Red[/color] x", "section codes")
	check_eq(Ansi.to_bbcode("\u001b[38;2;255;0;0mX"), "[color=#ff0000]X[/color]", "truecolor")


func test_log_levels() -> void:
	check_eq(LogParser.level_of("[12:00:01 INFO]: hi"), LogParser.Level.INFO, "info")
	check_eq(LogParser.level_of("[12:00:01 WARN]: hi"), LogParser.Level.WARN, "warn")
	check_eq(LogParser.level_of("[12:00:01 ERROR]: hi"), LogParser.Level.ERROR, "error")
	check_eq(LogParser.level_of("\tat java.base/Thread.run"), LogParser.Level.OTHER, "other")


func test_events() -> void:
	check_eq(LogParser.startup_seconds("[12:00:01 INFO]: Done (4.512s)! For help, type \"help\""), 4.512, "done")
	check_eq(LogParser.startup_seconds("[12:00:01 INFO]: Preparing"), -1.0, "not done")
	check_eq(LogParser.joined_player("[12:00:01 INFO]: Steve_01 joined the game"), "Steve_01", "join")
	check_eq(LogParser.left_player("[12:00:01 INFO]: Alex left the game"), "Alex", "leave")
	check(LogParser.is_stopping("[12:00:01 INFO]: Stopping the server"), "stopping")


func test_list_and_tps() -> void:
	var l := LogParser.parse_list("There are 2 of a max of 20 players online: Steve, Alex")
	check_eq(l.online, 2, "online")
	check_eq(l.max, 20, "max")
	check_eq(l.names, PackedStringArray(["Steve", "Alex"]), "names")
	var empty := LogParser.parse_list("There are 0 of a max of 10 players online: ")
	check_eq(empty.names.size(), 0, "no names")
	check_eq(LogParser.parse_tps("§6TPS from last 1m, 5m, 15m: §a*20.0, §a19.98, §a19.9"), 20.0, "tps")
