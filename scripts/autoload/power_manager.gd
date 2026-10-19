extends Node
## Cooperates with systemd-logind so servers are stopped cleanly before the computer
## sleeps or shuts down, and (depending on [member AppSettings.sleep_policy]) blocks
## sleep while servers are in use. Blocking only affects sleep: the screen can still
## turn off and lock as usual.
##
## Mechanism: `gdbus monitor` reports logind's PrepareForSleep/PrepareForShutdown
## signals; `systemd-inhibit … cat` holds an inhibitor lock for as long as its stdin
## pipe stays open, so closing the pipe releases the lock instantly.

## The computer is about to sleep (servers are being handled per the policy).
signal sleeping
## The computer woke up again.
signal resumed
## The computer is shutting down or rebooting; the app should stop servers and quit.
signal shutting_down

const WHO := "Server Manager"
const LOGIN1_ARGS: PackedStringArray = ["monitor", "--system", "--dest", "org.freedesktop.login1", "--object-path", "/org/freedesktop/login1"]
## Command that raises logind's limit on how long apps may delay sleep/shutdown (needs root,
## takes effect after the next reboot).
const RAISE_LIMIT_COMMAND := "sudo mkdir -p /etc/systemd/logind.conf.d && printf '[Login]\\nInhibitDelayMaxSec=120\\n' | sudo tee /etc/systemd/logind.conf.d/50-server-manager.conf"

var supported := false
## How long logind lets us delay sleep/shutdown (InhibitDelayMaxSec).
var max_delay_sec := 5.0
## True between "about to sleep" and "woke up".
var asleep := false

var _gdbus := ""
var _inhibit := ""
var _monitor := {}
var _monitor_buf := PackedByteArray()
var _delay_lock := {}
var _block_lock := {}
## Keeps the computer from dozing off while someone manages it remotely.
var _idle_lock := {}
var _stopped_for_sleep := PackedStringArray()
var _handling := false
## What was armed for the current sleep: {alarm: unix time or -1, wowlan: pattern or "", phy}.
var wake_plan := {}
## Last problem arming a wake-up ("" when fine), shown in Preferences.
var wake_error := ""
## Test hook: when set, called instead of the real helper with (args: Array) -> Dictionary.
var wake_runner := Callable()
## Wi-Fi wake-on-WLAN currently armed: {phy, pattern} or empty. Kept armed while the feature is
## on (not only at sleep time) so NetworkManager sees it and keeps Wi-Fi connected during sleep.
var _armed_wowlan := {}
var _wowlan_busy := false
static var _re_signal := RegEx.create_from_string("PrepareFor(Sleep|Shutdown) \\((true|false)")

@onready var _poll_timer: Timer = $PollTimer
@onready var _policy_timer: Timer = $PolicyTimer


func _ready() -> void:
	_gdbus = PlatformBackend.find_in_path("gdbus")
	_inhibit = PlatformBackend.find_in_path("systemd-inhibit")
	supported = OS.get_name() == "Linux" and _gdbus != "" and _inhibit != ""
	if not supported:
		return
	max_delay_sec = _read_max_delay()
	_poll_timer.timeout.connect(_poll_monitor)
	_policy_timer.timeout.connect(update_locks)
	ServerManager.server_state_changed.connect(func(_i: ServerInstance) -> void: update_locks())
	AppSettings.changed.connect(update_locks)
	_start_monitor()
	update_locks()


func _exit_tree() -> void:
	if not _armed_wowlan.is_empty():
		# Nothing listens while the app is closed, so stop waking the computer for connections.
		_runner().call(["wowlan", _armed_wowlan.phy, "off"])
	_release(_delay_lock)
	_release(_block_lock)
	_release(_idle_lock)
	if _monitor.has("pid") and OS.is_process_running(_monitor.pid):
		OS.kill(_monitor.pid)


## Human-readable state for the Preferences dialog.
func status_text() -> String:
	if not supported:
		return "Sleep and shutdown handling needs systemd-logind (gdbus and systemd-inhibit were not found)."
	var parts := PackedStringArray()
	parts.append("Delaying sleep/shutdown to stop servers" if not _delay_lock.is_empty() else "No servers to protect right now")
	if not _block_lock.is_empty():
		parts.append("sleep is blocked")
	return "%s · logind allows %s to stop servers." % [", ".join(parts), Fmt.duration(int(max_delay_sec))]


## Re-evaluates which inhibitor locks are needed for the current servers and policy.
func update_locks() -> void:
	if not supported or _handling:
		return
	var alive := ServerManager.any_running()
	var policy := AppSettings.sleep_policy
	var delay_what := PackedStringArray()
	if alive:
		delay_what.append("shutdown")
		if policy != AppSettings.SleepPolicy.PAUSE:
			delay_what.append("sleep")
	if not delay_what.has("sleep") and _wake_wanted():
		# Hold sleep briefly even with no server running, to arm the wake-up first.
		delay_what.append("sleep")
	_set_lock(_delay_lock, ":".join(delay_what), "delay", "Stopping Minecraft servers cleanly")
	var block := false
	match policy:
		AppSettings.SleepPolicy.BLOCK_WHILE_PLAYERS:
			block = ServerManager.get_instances().any(func(i: ServerInstance) -> bool: return i.is_online() and not i.players.is_empty())
		AppSettings.SleepPolicy.BLOCK_WHILE_RUNNING:
			block = alive
	_set_lock(_block_lock, "sleep" if block else "", "block", "Minecraft servers are in use")
	# Someone woke the computer or is working on it from elsewhere: no idle sleep meanwhile.
	_set_lock(_idle_lock, "idle" if RemoteAccess.recently_active() else "", "block", "Servers are being managed remotely")
	refresh_wake()


## Parses a `gdbus monitor` line into ["Sleep"|"Shutdown", active: bool], or [] if irrelevant.
static func parse_signal(line: String) -> Array:
	var m := _re_signal.search(line)
	return [m.get_string(1), m.get_string(2) == "true"] if m != null else []


## Handles one line of `gdbus monitor` output.
func handle_monitor_line(line: String) -> void:
	var sig := parse_signal(line)
	if sig.is_empty():
		return
	var active: bool = sig[1]
	if sig[0] == "Sleep":
		if active:
			_before_sleep()
		else:
			_after_wake()
	elif active:
		_before_shutdown()


func _before_sleep() -> void:
	if asleep:
		return
	asleep = true
	_handling = true
	sleeping.emit()
	for inst in ServerManager.get_instances():
		inst.scheduler.fire(EventRule.Trigger.SYSTEM_SLEEP)
	if AppSettings.sleep_policy == AppSettings.SleepPolicy.PAUSE:
		await _arm_wake()
		_release(_delay_lock)
		return
	_stopped_for_sleep.clear()
	for inst in ServerManager.get_instances():
		if inst.is_process_alive():
			_stopped_for_sleep.append(inst.config.id)
			inst.log_system("The computer is going to sleep; stopping the server.")
			inst.stop()
	await _wait_until_stopped(max_delay_sec - 0.5)
	if ServerManager.any_running():
		# Shown after wake-up: the server finishes saving once the computer runs again.
		Notifier.warn("A server was still stopping when the computer went to sleep (logind allows %s). Consider raising the limit in Preferences → Power." % Fmt.duration(int(max_delay_sec)),
				Notifier.Category.POWER)
	await _arm_wake()
	_release(_delay_lock)


func _after_wake() -> void:
	if not asleep:
		return
	asleep = false
	_handling = false
	_disarm_wake()
	update_locks()
	if AppSettings.restart_after_wake:
		var restarted := PackedStringArray()
		for id in _stopped_for_sleep:
			var inst := ServerManager.get_instance(id)
			if inst != null and not inst.is_busy() and not inst.is_temporary():
				inst.log_system("The computer woke up; starting the server again.")
				inst.start()
				restarted.append(inst.config.display_name)
		if not restarted.is_empty():
			Notifier.info("The computer woke up; restarting %s." % ", ".join(restarted), Notifier.Category.POWER)
	_stopped_for_sleep.clear()
	resumed.emit()
	for inst in ServerManager.get_instances():
		inst.scheduler.fire(EventRule.Trigger.SYSTEM_WAKE)


# --- Waking from sleep -------------------------------------------------------------

## True when a wake-up would be armed before sleeping (used to hold the sleep delay lock).
func _wake_wanted() -> bool:
	if not _can_wake():
		return false
	var instances := ServerManager.get_instances()
	if AppSettings.wake_for_events and not WakeHelper.flagged_event_times(instances).is_empty():
		return true
	return AppSettings.wake_on_connection and WakeHelper.connect_port(instances, _remote_ports()) >= 0


## Works out the wake-up for this sleep: {alarm: unix time or -1, wowlan: pattern or "", phy}.
func plan_wake() -> Dictionary:
	var instances := ServerManager.get_instances()
	var plan := {"alarm": -1, "wowlan": "", "phy": ""}
	if AppSettings.wake_for_events:
		plan.alarm = WakeHelper.wake_time(WakeHelper.flagged_event_times(instances), int(Time.get_unix_time_from_system()))
	if AppSettings.wake_on_connection:
		var port := WakeHelper.connect_port(instances, _remote_ports())
		var iface := WakeHelper.wake_interface()
		if port >= 0 and iface.get("wireless", false):
			plan.phy = iface.phy
			plan.wowlan = WakeHelper.tcp_pattern(iface.mac, port)
	return plan


func _arm_wake() -> void:
	wake_plan = {}
	wake_error = ""
	if not _wake_wanted():
		return
	var plan := plan_wake()
	var errors := PackedStringArray()
	if plan.alarm > 0:
		var r: Dictionary = await FileOps.run_async(self, _runner().bind(["alarm", str(plan.alarm)]))
		if not r.ok:
			errors.append("wake alarm: " + str(r.message))
	if plan.wowlan != "" and (_armed_wowlan.get("pattern", "") != plan.wowlan or _armed_wowlan.get("phy", "") != plan.phy):
		# Normally already armed by refresh_wake(); this covers a change made right before sleep.
		var r: Dictionary = await FileOps.run_async(self, _runner().bind(["wowlan", plan.phy, "on", plan.wowlan]))
		if r.ok:
			_armed_wowlan = {"phy": plan.phy, "pattern": plan.wowlan}
		else:
			errors.append("Wi-Fi wake-up: " + str(r.message))
	wake_plan = plan
	wake_error = "; ".join(errors)
	if wake_error != "":
		Notifier.warn("Could not prepare waking up (%s)." % wake_error, Notifier.Category.POWER)


func _disarm_wake() -> void:
	var plan := wake_plan
	wake_plan = {}
	if int(plan.get("alarm", -1)) > 0:
		FileOps.run_async(self, _runner().bind(["alarm", "clear"]))
	# Wi-Fi wake stays armed: refresh_wake() manages it for as long as the feature is on.


## Arms or clears Wi-Fi wake-on-WLAN to match the settings and servers. Called on every policy
## tick; only runs the helper when something changed.
func refresh_wake() -> void:
	if _wowlan_busy or asleep or not _can_wake():
		return
	var plan := plan_wake()
	var want := {"phy": plan.phy, "pattern": plan.wowlan} if plan.wowlan != "" else {}
	if want == _armed_wowlan:
		return
	_wowlan_busy = true
	var args: Array = ["wowlan", _armed_wowlan.phy, "off"] if want.is_empty() else ["wowlan", want.phy, "on", want.pattern]
	var r: Dictionary = await FileOps.run_async(self, _runner().bind(args))
	_wowlan_busy = false
	if r.ok:
		_armed_wowlan = want
		wake_error = ""
	else:
		wake_error = "Wi-Fi wake-up: " + str(r.message)


## The helper call used for arming; tests replace it through [member wake_runner].
## True when wake-ups can be armed: through the installed helper in normal runs, or through
## [member wake_runner]. Test runs (`--no-autostart`) never reach the real helper, so they
## cannot change the computer's wake alarm or Wi-Fi settings.
func _can_wake() -> bool:
	return wake_runner.is_valid() or (WakeHelper.is_installed() and AppSettings.autostart_enabled)


func _runner() -> Callable:
	if wake_runner.is_valid():
		return wake_runner
	return func(args: Array) -> Dictionary:
		if str(args[0]) == "alarm":
			return WakeHelper.set_alarm(-1 if args[1] == "clear" else str(args[1]).to_int())
		return WakeHelper.set_wowlan(str(args[1]), str(args[3]) if args[2] == "on" else "")


## Remote access's port while it is on: people connecting from their own Server Manager
## can wake the computer like players connecting to a start-on-connect server.
func _remote_ports() -> Array:
	return [RemoteAccess.port] if RemoteAccess.enabled else []


## What clients need to wake this computer: {ready, mac}. Ready when connection wake-up is
## set up and on, over Wi-Fi (the only wake-up this computer can arm for connections).
func remote_wake_info() -> Dictionary:
	var iface := WakeHelper.wake_interface()
	var ready: bool = AppSettings.wake_on_connection and WakeHelper.is_installed() and iface.get("wireless", false) and RemoteAccess.enabled
	return {"ready": ready, "mac": str(iface.get("mac", "")) if ready else ""}


## What the current settings would arm, for the Preferences status line.
func describe_wake() -> String:
	if not WakeHelper.is_installed():
		return "Waking from sleep needs a one-time setup (one password prompt)."
	var plan := plan_wake()
	var parts := PackedStringArray()
	if plan.alarm > 0:
		parts.append("next wake-up %s" % Fmt.datetime(plan.alarm))
	elif AppSettings.wake_for_events:
		parts.append("no upcoming events ask to wake the computer")
	if plan.wowlan != "":
		var port := WakeHelper.connect_port(ServerManager.get_instances(), _remote_ports())
		parts.append("Wi-Fi watches for connections to %s" % ("any port" if port == 0 else "port %d" % port))
	elif AppSettings.wake_on_connection:
		var iface := WakeHelper.wake_interface()
		parts.append("connection wake-up needs a server with Start on connect or remote access turned on" if iface.get("wireless", false)
				else "connection wake-up currently works only over Wi-Fi")
	return "Ready · " + "; ".join(parts) if not parts.is_empty() else "Ready."


func _before_shutdown() -> void:
	_handling = true
	_release(_block_lock)
	shutting_down.emit()
	ServerManager.stop_all()
	await _wait_until_stopped(max_delay_sec - 0.5)
	_release(_delay_lock)


func _wait_until_stopped(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(maxf(seconds, 0.5) * 1000.0)
	while ServerManager.any_running() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.1).timeout


func _set_lock(lock: Dictionary, what: String, mode: String, why: String) -> void:
	if lock.get("what", "") == what:
		return
	_release(lock)
	if what == "":
		return
	var info := OS.execute_with_pipe(_inhibit, ["--what=" + what, "--mode=" + mode, "--who=" + WHO, "--why=" + why, "cat"], false)
	if info.is_empty():
		push_warning("Could not take a %s inhibitor lock" % mode)
		return
	lock.merge(info)
	lock["what"] = what


## Closing the inhibitor's stdin ends `cat`, which releases the lock.
func _release(lock: Dictionary) -> void:
	if lock.is_empty():
		return
	for key in ["stdio", "stderr"]:
		if lock.get(key) is FileAccess:
			(lock[key] as FileAccess).close()
	lock.clear()


func _start_monitor() -> void:
	_monitor = OS.execute_with_pipe(_gdbus, LOGIN1_ARGS, false)
	_monitor_buf.clear()
	if _monitor.is_empty():
		push_warning("Could not watch logind for sleep/shutdown events")
		return
	_poll_timer.start()


func _poll_monitor() -> void:
	if _monitor.is_empty():
		return
	var pipe: FileAccess = _monitor.stdio
	var chunk := pipe.get_buffer(16384)
	while not chunk.is_empty():
		_monitor_buf.append_array(chunk)
		chunk = pipe.get_buffer(16384)
	var nl := _monitor_buf.find(10)
	while nl != -1:
		handle_monitor_line(_monitor_buf.slice(0, nl).get_string_from_utf8())
		_monitor_buf = _monitor_buf.slice(nl + 1)
		nl = _monitor_buf.find(10)
	if not OS.is_process_running(_monitor.pid):
		# gdbus exited (e.g. the system bus restarted); reconnect shortly.
		_monitor = {}
		get_tree().create_timer(5.0).timeout.connect(_start_monitor)


func _read_max_delay() -> float:
	var output: Array = []
	if PlatformBackend.execute("busctl", ["get-property", "org.freedesktop.login1", "/org/freedesktop/login1",
			"org.freedesktop.login1.Manager", "InhibitDelayMaxUSec"], output) == 0 and not output.is_empty():
		var usec := str(output[0]).strip_edges().get_slice(" ", 1).to_int()
		if usec > 0:
			return usec / 1_000_000.0
	return 5.0
