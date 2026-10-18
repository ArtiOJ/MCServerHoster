extends TestCase

const DAY := 86400


## Unix time (UTC) of a local wall-clock moment, matching how EventRule interprets times.
func _local(year: int, month: int, day: int, hour: int, minute: int) -> int:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_unix_time_from_datetime_dict({"year": year, "month": month, "day": day, "hour": hour, "minute": minute, "second": 0}) - bias


func test_time_trigger_respects_weekdays() -> void:
	var r := EventRule.new()
	r.trigger = EventRule.Trigger.TIME
	r.time_of_day = "18:00"
	r.weekdays = (1 << 5) | (1 << 6)  # Friday, Saturday
	var wed_noon := _local(2026, 10, 14, 12, 0)  # 2026-10-14 is a Wednesday
	check_eq(r.next_run_after(wed_noon, wed_noon), _local(2026, 10, 16, 18, 0), "next Friday 18:00")
	var fri_after := _local(2026, 10, 16, 18, 30)
	check_eq(r.next_run_after(fri_after, fri_after), _local(2026, 10, 17, 18, 0), "then Saturday")
	var sat_after := _local(2026, 10, 17, 19, 0)
	check_eq(r.next_run_after(sat_after, sat_after), _local(2026, 10, 23, 18, 0), "then next Friday")
	r.weekdays = 0
	check_eq(r.next_run_after(wed_noon, wed_noon), -1, "no days = never")


func test_interval_trigger() -> void:
	var r := EventRule.new()
	r.trigger = EventRule.Trigger.INTERVAL
	r.interval_minutes = 90
	var base := _local(2026, 10, 14, 0, 0)
	check_eq(r.next_run_after(base, base), base + 5400, "first step")
	check_eq(r.next_run_after(base + 5400, base), base + 10800, "strictly after")


func test_window_and_day_conditions() -> void:
	var r := EventRule.new()
	r.trigger = EventRule.Trigger.PLAYER_JOINED
	r.window_enabled = true
	r.window_start = "22:00"
	r.window_end = "02:00"
	check(r.conditions_met(_local(2026, 10, 14, 23, 30)), "inside wrapped window (late)")
	check(r.conditions_met(_local(2026, 10, 15, 1, 0)), "inside wrapped window (early)")
	check(not r.conditions_met(_local(2026, 10, 14, 12, 0)), "outside window")
	r.window_enabled = false
	r.weekdays = 0b0111110
	check(r.conditions_met(_local(2026, 10, 14, 12, 0)), "Wednesday is a weekday")
	check(not r.conditions_met(_local(2026, 10, 18, 12, 0)), "Sunday is not")
	check_eq(r.days_text(), "Weekdays", "days text")


func test_describe_and_round_trip() -> void:
	var r := EventRule.from_template({"trigger": EventRule.Trigger.SERVER_EMPTY, "threshold": 15.0, "action": EventRule.Action.STOP})
	check_eq(r.describe(), "Empty for 15 min → stop server", "describe")
	r.weekdays = (1 << 6) | 1
	r.state_filter = EventRule.StateFilter.ONLINE
	var back := EventRule.from_dict(JSON.parse_string(JSON.stringify(r.to_dict())))
	check_eq(back.describe(), r.describe(), "round trip keeps meaning")
	check(back.describe().begins_with("Weekends"), "weekend prefix: " + back.describe())


func test_legacy_schedule_migration() -> void:
	var dir := ProjectSettings.globalize_path("user://test-migrate-%d" % Time.get_ticks_usec())
	var d := {
		"id": "old", "schedules": [
			{"kind": ScheduleEntry.Kind.RESTART, "mode": ScheduleEntry.Mode.DAILY, "time_of_day": "04:00", "enabled": true},
			{"kind": ScheduleEntry.Kind.COMMAND, "mode": ScheduleEntry.Mode.INTERVAL, "interval_minutes": 30, "command": "save-all"},
			{"kind": ScheduleEntry.Kind.BACKUP, "mode": ScheduleEntry.Mode.DAILY, "time_of_day": "05:00", "enabled": false},
		],
	}
	var c := ServerConfig.from_dict(d, dir)
	check_eq(c.events.size(), 3, "all schedules migrated")
	check_eq(c.events[0].action, EventRule.Action.RESTART, "restart action")
	check_eq(c.events[0].time_of_day, "04:00", "time kept")
	check_eq(c.events[1].trigger, EventRule.Trigger.INTERVAL, "interval trigger")
	check_eq(c.events[1].text, "save-all", "command kept")
	check_eq(c.events[2].enabled, false, "disabled kept")
	check(not c.to_dict().has("schedules"), "saved as events only")


func test_logind_signal_parsing() -> void:
	var PM := load("res://scripts/autoload/power_manager.gd")
	check_eq(PM.parse_signal("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)"), ["Sleep", true], "sleep start")
	check_eq(PM.parse_signal("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)"), ["Sleep", false], "wake")
	check_eq(PM.parse_signal("/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForShutdown (true,)"), ["Shutdown", true], "shutdown")
	check_eq(PM.parse_signal("/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', ...)"), [], "ignored")
