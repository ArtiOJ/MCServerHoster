extends TestCase

const N := preload("res://scripts/autoload/notifier.gd")
const ALL_ON := {"crash": true, "server_state": true, "players": true, "wake": true, "backup": true, "update": true, "power": true, "event": true}


func test_master_switch_and_when() -> void:
	var cats := ALL_ON.duplicate()
	check(not N.should_deliver(false, AppSettings.NotifyWhen.ALWAYS, cats, N.Category.CRASH, N.Level.ERROR, false), "master switch off")
	check(not N.should_deliver(true, AppSettings.NotifyWhen.NEVER, cats, N.Category.CRASH, N.Level.ERROR, false), "never")
	check(N.should_deliver(true, AppSettings.NotifyWhen.ALWAYS, cats, N.Category.CRASH, N.Level.ERROR, true), "always, even focused")
	check(not N.should_deliver(true, AppSettings.NotifyWhen.UNFOCUSED, cats, N.Category.CRASH, N.Level.ERROR, true), "unfocused mode, window focused")
	check(N.should_deliver(true, AppSettings.NotifyWhen.UNFOCUSED, cats, N.Category.CRASH, N.Level.ERROR, false), "unfocused mode, window in background")


func test_category_filtering() -> void:
	var cats := AppSettings.DEFAULT_NOTIFY_CATEGORIES.duplicate()
	var w := AppSettings.NotifyWhen.ALWAYS
	check(N.should_deliver(true, w, cats, N.Category.CRASH, N.Level.ERROR, false), "crashes on by default")
	check(not N.should_deliver(true, w, cats, N.Category.PLAYERS, N.Level.INFO, false), "players off by default")
	check(not N.should_deliver(true, w, cats, N.Category.SERVER_STATE, N.Level.SUCCESS, false), "server state off by default")
	cats.backup = false
	check(not N.should_deliver(true, w, cats, N.Category.BACKUP, N.Level.SUCCESS, false), "backup success follows its toggle")
	check(N.should_deliver(true, w, cats, N.Category.BACKUP, N.Level.ERROR, false), "backup failure always shown")
	check(not N.should_deliver(true, w, cats, N.Category.GENERAL, N.Level.SUCCESS, false), "general UI feedback stays in-app")
	check(N.should_deliver(true, w, cats, N.Category.GENERAL, N.Level.ERROR, false), "general errors reach the desktop")


func test_rate_limit() -> void:
	var n: Node = N.new()
	check(not n.is_rate_limited("a", 1000), "first delivery")
	check(n.is_rate_limited("a", 5000), "repeat within 10 s suppressed")
	check(not n.is_rate_limited("b", 5000), "different message not suppressed")
	check(not n.is_rate_limited("a", 1000 + N.RATE_LIMIT_MS), "allowed again after the window")
	n.free()


func test_command_building() -> void:
	var crash := N.build_command("Survival", "Survival crashed (exit code 1).", N.Level.ERROR, N.Category.CRASH, "/x/icon.svg")
	check_eq(crash, PackedStringArray(["--app-name=Server Manager", "--urgency=critical", "--icon=/x/icon.svg", "--", "Survival", "Survival crashed (exit code 1)."]), "crash command")
	var joined := N.build_command("Survival", "-Steve joined", N.Level.INFO, N.Category.PLAYERS)
	check_eq(joined[1], "--urgency=low", "players are low urgency")
	check_eq(joined[-2], "Survival", "title after --")
	check_eq(joined[-1], "-Steve joined", "body starting with - is not taken as an option")
	check_eq(N.build_command("t", "b", N.Level.ERROR, N.Category.BACKUP)[1], "--urgency=normal", "non-crash errors are normal urgency")


func test_notify_event_action() -> void:
	var r := EventRule.from_template({"trigger": EventRule.Trigger.PLAYER_JOINED, "action": EventRule.Action.NOTIFY, "text": "Hi"})
	check_eq(r.describe(), "A player joins → notify \"Hi\"", "describe")
	check_eq(EventRule.ACTION_NAMES.size(), EventRule.Action.size(), "a name per action")
	check_eq(EventRule.from_dict(r.to_dict()).action, EventRule.Action.NOTIFY, "round trip")
	check(EventRule.templates().any(func(t: Array) -> bool: return t[1].get("action", -1) == EventRule.Action.NOTIFY), "template offered")
