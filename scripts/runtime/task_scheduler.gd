class_name TaskScheduler
extends Timer
## Runs a server's scheduled restarts, commands and backups, broadcasting
## countdown warnings in-game before scheduled restarts.

signal task_ran(entry: ScheduleEntry)

## Seconds before a restart at which players are warned.
const WARNING_OFFSETS: Array[int] = [600, 300, 60, 30, 10, 5]

var instance: ServerInstance

## ScheduleEntry -> next run (unix seconds)
var _next_runs := {}
## ScheduleEntry -> Array of offsets already announced for the current run
var _warned := {}
## Reference point for interval schedules (server start or app start).
var _interval_base := 0


func _ready() -> void:
	instance = get_parent() as ServerInstance
	_interval_base = int(Time.get_unix_time_from_system())
	timeout.connect(_tick)
	start()


## Recompute all run times, e.g. after the schedule list was edited.
func reset() -> void:
	_next_runs.clear()
	_warned.clear()


func on_server_started() -> void:
	_interval_base = int(Time.get_unix_time_from_system())
	reset()


func next_run_of(entry: ScheduleEntry) -> int:
	if not _next_runs.has(entry):
		_next_runs[entry] = entry.next_run_after(int(Time.get_unix_time_from_system()), _interval_base)
	return _next_runs[entry]


func _tick() -> void:
	if instance == null or instance.config == null:
		return
	var now := int(Time.get_unix_time_from_system())
	for entry in instance.config.schedules:
		if not entry.enabled:
			continue
		var due := next_run_of(entry)
		if entry.kind == ScheduleEntry.Kind.RESTART and entry.warn_players and instance.is_online():
			_announce(entry, due - now)
		if now >= due:
			_run(entry)
			_next_runs[entry] = entry.next_run_after(now, _interval_base)
			_warned.erase(entry)


func _announce(entry: ScheduleEntry, remaining: int) -> void:
	var done: Array = _warned.get(entry, [])
	for offset in WARNING_OFFSETS:
		if remaining <= offset and remaining > offset - 2 and not done.has(offset):
			done.append(offset)
			var when := ("%d minute%s" % [offset / 60, "s" if offset >= 120 else ""]) if offset >= 60 else ("%d seconds" % offset)
			instance.send_command("say Scheduled restart in %s." % when, false)
	_warned[entry] = done


func _run(entry: ScheduleEntry) -> void:
	match entry.kind:
		ScheduleEntry.Kind.RESTART:
			if instance.is_online():
				instance.log_system("Scheduled restart.")
				instance.restart()
		ScheduleEntry.Kind.COMMAND:
			if instance.is_online() and entry.command.strip_edges() != "":
				instance.log_system("Scheduled command: " + entry.command)
				instance.send_command(entry.command.strip_edges().trim_prefix("/"), false)
		ScheduleEntry.Kind.BACKUP:
			instance.log_system("Scheduled backup.")
			instance.backups.create_backup(instance.config.backup_full)
	task_ran.emit(entry)
