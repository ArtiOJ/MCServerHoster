class_name AppSettingsDialog
extends ConfirmationDialog
## Application preferences: servers folder, defaults, power & background behaviour and Java runtimes.
## For another computer (as its system admin) it shows and saves that computer's
## preferences (see HostOps); interface size and console length stay per computer.

@onready var _root_edit: LineEdit = %RootEdit
@onready var _browse_button: Button = %BrowseButton
@onready var _default_ram_spin: SpinBox = %DefaultRamSpin
@onready var _console_lines_spin: SpinBox = %ConsoleLinesSpin
@onready var _ui_scale_option: OptionButton = %UiScaleOption
@onready var _exit_option: OptionButton = %ExitOption
@onready var _updates_check: CheckButton = %UpdatesCheck
@onready var _unstable_check: CheckButton = %UnstableCheck
@onready var _java_list: ItemList = %JavaList
@onready var _rescan_button: Button = %RescanButton
@onready var _add_java_button: Button = %AddJavaButton
@onready var _sleep_option: OptionButton = %SleepOption
@onready var _wake_check: CheckButton = %WakeCheck
@onready var _login_check: CheckButton = %LoginCheck
@onready var _minimized_check: CheckButton = %MinimizedCheck
@onready var _power_status: Label = %PowerStatus
@onready var _wake_events_check: CheckButton = %WakeEventsCheck
@onready var _wake_connect_check: CheckButton = %WakeConnectCheck
@onready var _wake_status: Label = %WakeStatus
@onready var _wake_ports_option: OptionButton = %WakePortsOption
@onready var _wake_port_spin: SpinBox = %WakePortSpin
@onready var _wake_ports_range: Label = %WakePortsRange
@onready var _setup_wake_button: Button = %SetupWakeButton
@onready var _remove_wake_button: Button = %RemoveWakeButton
@onready var _limit_notice: PanelContainer = %LimitNotice
@onready var _copy_limit_button: Button = %CopyLimitButton
@onready var _desktop_notify_check: CheckButton = %DesktopNotifyCheck
@onready var _notify_when_option: OptionButton = %NotifyWhenOption
@onready var _notify_categories: GridContainer = %NotifyCategories
@onready var _notify_status: Label = %NotifyStatus
@onready var _test_notify_button: Button = %TestNotifyButton
## Category key -> its switch in the Notifications section.
@onready var _category_checks := {
	"crash": %NotifyCrashCheck, "server_state": %NotifyStateCheck, "players": %NotifyPlayersCheck,
	"wake": %NotifyWakeCheck, "backup": %NotifyBackupCheck, "update": %NotifyUpdateCheck,
	"power": %NotifyPowerCheck, "event": %NotifyEventCheck, "remote": %NotifyRemoteCheck,
}
@onready var _dir_dialog: FileDialog = %DirDialog
@onready var _java_dialog: FileDialog = %JavaDialog
@onready var _java_path_dialog: ConfirmationDialog = %JavaPathDialog
@onready var _java_path_edit: LineEdit = %JavaPathEdit
@onready var _console_lines_label: Label = %ConsoleLinesLabel
@onready var _ui_scale_label: Label = %UiScaleLabel

## The computer whose preferences are shown (null = this one).
var _remote: ServerSource = null
## Preferences of [member _remote] as loaded (see HostOps.prefs_get).
var _remote_prefs := {}


func _ready() -> void:
	_setup_wake_button.pressed.connect(_run_wake_setup)
	_remove_wake_button.pressed.connect(_remove_wake)
	for c: CheckButton in [_wake_events_check, _wake_connect_check]:
		c.toggled.connect(_on_wake_toggled.bind(c))
	_wake_ports_option.item_selected.connect(_on_wake_ports_changed.unbind(1))
	_wake_port_spin.value_changed.connect(_on_wake_ports_changed.unbind(1))
	confirmed.connect(func() -> void:
		if _remote != null:
			_apply_remote()
		else:
			_apply())
	# Interface size previews live; Cancel puts the saved size back.
	_ui_scale_option.item_selected.connect(func(index: int) -> void: _preview_scale(UiScale.OPTIONS[index]))
	canceled.connect(func() -> void:
		if _remote != null:
			return
		_preview_scale(AppSettings.ui_scale)
		AppSettings.wake_for_events = _saved_wake[0]
		AppSettings.wake_on_connection = _saved_wake[1]
		AppSettings.wake_port_block = _saved_wake[2])
	_browse_button.pressed.connect(_browse_root)
	_dir_dialog.dir_selected.connect(func(dir: String) -> void: _root_edit.text = dir)
	_rescan_button.pressed.connect(func() -> void:
		if _remote != null:
			_remote_java("java_rescan", {})
		else:
			JavaRuntimes.rescan())
	_add_java_button.pressed.connect(func() -> void:
		if _remote != null:
			_java_path_edit.text = ""
			_java_path_dialog.popup_centered()
		else:
			_java_dialog.popup_centered())
	_java_path_dialog.confirmed.connect(func() -> void: _remote_java("java_add", {"exe": _java_path_edit.text.strip_edges()}))
	_java_dialog.file_selected.connect(_add_java)
	JavaRuntimes.runtimes_changed.connect(func() -> void:
		if _remote == null:
			_fill_java_list())
	_desktop_notify_check.toggled.connect(func(_on: bool) -> void: _update_notify_controls())
	_notify_when_option.item_selected.connect(func(_i: int) -> void: _update_notify_controls())
	_test_notify_button.pressed.connect(func() -> void:
		if not Notifier.send_test():
			Notifier.warn("Could not show a desktop notification (notify-send is missing)."))
	_copy_limit_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(PowerManager.RAISE_LIMIT_COMMAND)
		Notifier.info("Command copied. Paste it into a terminal, then reboot."))


## Loads the settings of [param source] (default: this computer) and shows the dialog.
func open(source: ServerSource = null) -> void:
	_remote = source if source != null and source.is_remote_source() else null
	_set_remote_layout()
	if _remote != null:
		_open_remote()
		return
	get_ok_button().disabled = false
	_root_edit.text = AppSettings.servers_root
	_default_ram_spin.value = AppSettings.default_ram_mb
	_console_lines_spin.value = AppSettings.console_max_lines
	_fill_ui_scale_options()
	_exit_option.select(AppSettings.exit_behavior)
	_updates_check.button_pressed = AppSettings.check_updates_on_launch
	_unstable_check.button_pressed = AppSettings.show_unstable_versions
	_sleep_option.select(AppSettings.sleep_policy)
	_wake_check.button_pressed = AppSettings.restart_after_wake
	_login_check.button_pressed = AppSettings.start_at_login
	if AppSettings.test_copy:
		_login_check.disabled = true
		_login_check.tooltip_text = "Set this in the installed app; this copy runs from the Godot editor."
	_minimized_check.button_pressed = AppSettings.start_minimized
	_sleep_option.disabled = not PowerManager.supported
	_wake_check.disabled = not PowerManager.supported
	_power_status.text = PowerManager.status_text()
	_saved_wake = [AppSettings.wake_for_events, AppSettings.wake_on_connection, AppSettings.wake_port_block]
	_show_wake_ports(AppSettings.wake_port_block)
	# Shown as on only when they can work; switching one on before setup offers the setup.
	_wake_events_check.set_pressed_no_signal(AppSettings.wake_for_events and WakeHelper.is_installed())
	_wake_connect_check.set_pressed_no_signal(AppSettings.wake_on_connection and WakeHelper.is_installed())
	_refresh_wake()
	_limit_notice.visible = OS.get_name() == "Linux" and PowerManager.supported and PowerManager.max_delay_sec < 60.0
	_desktop_notify_check.button_pressed = AppSettings.desktop_notifications
	_notify_when_option.select(AppSettings.notify_when)
	for key in _category_checks:
		(_category_checks[key] as CheckButton).button_pressed = bool(AppSettings.notify_categories.get(key, true))
	_update_notify_controls()
	_fill_java_list()
	popup_centered()


func _fill_ui_scale_options() -> void:
	var automatic := UiScale.current_automatic(get_tree().root)
	_ui_scale_option.clear()
	var selected := 0
	for i in UiScale.OPTIONS.size():
		_ui_scale_option.add_item(UiScale.option_label(UiScale.OPTIONS[i], automatic), i)
		if is_equal_approx(UiScale.OPTIONS[i], AppSettings.ui_scale):
			selected = i
	_ui_scale_option.select(selected)


func _preview_scale(setting: float) -> void:
	var root := get_tree().root
	var wanted := UiScale.automatic_factor(DisplayServer.screen_get_scale(root.current_screen), DisplayServer.screen_get_dpi(root.current_screen)) if setting <= 0.0 else setting
	var used := UiScale.apply(root, setting)
	if used < wanted - 0.001:
		Notifier.info("Interface size limited to %d %% so the window fits on this screen." % roundi(used * 100.0))
	if visible:
		move_to_center()


func _update_notify_controls() -> void:
	var available: bool = Notifier.is_desktop_available() if _remote == null else bool(_remote_prefs.get("notify_available", false))
	var active := available and _desktop_notify_check.button_pressed and _notify_when_option.selected != AppSettings.NotifyWhen.NEVER
	_desktop_notify_check.disabled = not available
	_notify_when_option.disabled = not available or not _desktop_notify_check.button_pressed
	for check: CheckButton in _category_checks.values():
		check.disabled = not active
	_test_notify_button.disabled = not available
	if not available:
		_notify_status.text = "Desktop notifications need notify-send (package libnotify). In-app messages still work."
	elif not active:
		_notify_status.text = "Desktop notifications are off; in-app messages still appear."
	else:
		_notify_status.text = "Failed backups and errors always notify. Player joins also control the in-app toasts."


func _browse_root() -> void:
	var current := _root_edit.text.strip_edges()
	if DirAccess.dir_exists_absolute(current):
		_dir_dialog.current_dir = current
	_dir_dialog.popup_centered()


func _add_java(path: String) -> void:
	if not AppSettings.extra_java_paths.has(path):
		AppSettings.extra_java_paths.append(path)
		AppSettings.save_settings()
	var before := JavaRuntimes.runtimes.size()
	JavaRuntimes.rescan()
	if JavaRuntimes.find_by_executable(path) == null and JavaRuntimes.runtimes.size() <= before:
		Notifier.warn("No usable Java runtime was found at %s." % path)


func _fill_java_list() -> void:
	_java_list.clear()
	for rt in JavaRuntimes.runtimes:
		var idx := _java_list.add_item("%s   —   %s" % [rt.display_name(), rt.executable])
		_java_list.set_item_tooltip(idx, rt.home)
	if JavaRuntimes.runtimes.is_empty():
		var idx := _java_list.add_item("No Java runtimes found. Install a JDK (e.g. Java 21) or add one manually.")
		_java_list.set_item_disabled(idx, true)


var _wake_busy := false
## Wake settings when the dialog opened (toggles apply live for the status line; Cancel restores).
var _saved_wake := [true, false, -1]


func _refresh_wake() -> void:
	var installed := WakeHelper.is_installed()
	var windows := OS.get_name() == "Windows"
	var available := PowerManager.supported and (OS.get_name() == "Linux" or windows)
	# Windows needs no helper: wake-ups are the user's own scheduled tasks.
	_setup_wake_button.visible = not WakeHelper.is_current() and not windows
	_setup_wake_button.text = "Update helper…" if installed else "Set up waking…"
	_setup_wake_button.tooltip_text = "Update the wake-up helper so Server Manager can also restart a Wi-Fi card that comes back from sleep stuck (asks for your password once)." if installed \
			else "Install the small helper that lets Server Manager set the wake-up alarm (asks for your password once)."
	_remove_wake_button.visible = installed and not windows
	for c: Control in [_setup_wake_button, _remove_wake_button]:
		(c as Button).disabled = _wake_busy or not available
	_wake_events_check.disabled = not available
	_wake_connect_check.disabled = not available or not (windows or WakeHelper.wake_interface().get("wireless", false))
	_set_wake_ports_enabled(_wake_connect_check.button_pressed and not _wake_connect_check.disabled and not windows)
	_wake_status.text = "Waiting for your password…" if _wake_busy else PowerManager.describe_wake()


func _show_wake_ports(block: int) -> void:
	_wake_ports_option.select(0 if block < 0 else 1)
	if block >= 0 and (int(_wake_port_spin.value) >> 8) != block:
		_wake_port_spin.set_value_no_signal(block << 8)
	_wake_port_spin.visible = block >= 0
	_wake_ports_range.text = WakeHelper.block_range_text(block) if block >= 0 else ""


func _set_wake_ports_enabled(on: bool) -> void:
	_wake_ports_option.disabled = not on
	_wake_port_spin.editable = on


## -1 for Automatic, else the block of the entered port.
func _chosen_wake_block() -> int:
	return -1 if _wake_ports_option.selected == 0 else (int(_wake_port_spin.value) >> 8) & 0xFF


## Applies live for the status line, like the wake toggles (Cancel restores).
func _on_wake_ports_changed() -> void:
	var block := _chosen_wake_block()
	_show_wake_ports(block)
	if _remote == null:
		AppSettings.wake_port_block = block
		_refresh_wake()


func _run_wake_setup() -> void:
	_wake_busy = true
	_refresh_wake()
	await WakeSetupDialog.prompt(self)
	_wake_busy = false
	_refresh_wake()


## Switching a wake option on before the one-time setup offers the setup; declining turns it off.
func _on_wake_toggled(on: bool, check: CheckButton) -> void:
	if _remote != null:
		return  # Saved with the other preferences of that computer.
	if on and not WakeHelper.is_installed() and not _wake_busy:
		_wake_busy = true
		var installed := await WakeSetupDialog.prompt(self)
		_wake_busy = false
		if not installed:
			check.set_pressed_no_signal(false)
	AppSettings.wake_for_events = _wake_events_check.button_pressed
	AppSettings.wake_on_connection = _wake_connect_check.button_pressed
	_refresh_wake()


func _remove_wake() -> void:
	_wake_busy = true
	_refresh_wake()
	var result: Dictionary = await FileOps.run_async(self, WakeHelper.uninstall)
	_wake_busy = false
	_refresh_wake()
	if result.ok:
		Notifier.success(result.message)
	else:
		Notifier.error(result.message)


## Rows that only make sense for this computer are hidden for another one.
func _set_remote_layout() -> void:
	var local := _remote == null
	title = "Preferences" if local else "Preferences of %s" % _remote.source_name()
	for c: Control in [_console_lines_label, _console_lines_spin, _ui_scale_label, _ui_scale_option, _browse_button, _test_notify_button]:
		c.visible = local
	_root_edit.tooltip_text = "" if local else "A folder on %s" % _remote.source_name()


func _open_remote() -> void:
	var source := _remote
	get_ok_button().disabled = true
	_power_status.text = "Loading…"
	popup_centered()
	var res: Dictionary = await source.call_host_op("prefs_get")
	if source != _remote or not visible:
		return
	if not res.ok:
		_power_status.text = str(res.error)
		return
	_remote_prefs = res
	var v: Dictionary = res.values
	_root_edit.text = str(v.servers_root)
	_default_ram_spin.value = int(v.default_ram_mb)
	_exit_option.select(int(v.exit_behavior))
	_updates_check.button_pressed = bool(v.check_updates_on_launch)
	_unstable_check.button_pressed = bool(v.show_unstable_versions)
	_sleep_option.select(int(v.sleep_policy))
	_wake_check.button_pressed = bool(v.restart_after_wake)
	_login_check.button_pressed = bool(v.start_at_login)
	_minimized_check.button_pressed = bool(v.start_minimized)
	_sleep_option.disabled = not res.power_supported
	_wake_check.disabled = not res.power_supported
	_power_status.text = str(res.power_status)
	_wake_events_check.set_pressed_no_signal(bool(v.wake_for_events) and res.wake_installed)
	_wake_connect_check.set_pressed_no_signal(bool(v.wake_on_connection) and res.wake_installed)
	_show_wake_ports(int(v.get("wake_port_block", -1)))
	_set_wake_ports_enabled(_wake_connect_check.button_pressed and bool(res.wake_wireless))
	_wake_events_check.disabled = not res.wake_installed
	_wake_connect_check.disabled = not res.wake_installed or not res.wake_wireless
	_setup_wake_button.visible = false
	_remove_wake_button.visible = false
	_wake_status.text = str(res.wake_status) if res.wake_installed \
			else "Waking %s needs a one-time setup on that computer (it asks for its password there)." % source.source_name()
	_limit_notice.visible = bool(res.limit_notice)
	_desktop_notify_check.button_pressed = bool(v.desktop_notifications)
	_notify_when_option.select(int(v.notify_when))
	for key in _category_checks:
		(_category_checks[key] as CheckButton).button_pressed = bool(v.notify_categories.get(key, true))
	_update_notify_controls()
	_fill_remote_java(res.runtimes)
	get_ok_button().disabled = false


func _fill_remote_java(runtimes: Array) -> void:
	_java_list.clear()
	for rt: Dictionary in runtimes:
		var idx := _java_list.add_item("%s   —   %s" % [rt.name, rt.exe])
		_java_list.set_item_tooltip(idx, str(rt.home))
	if runtimes.is_empty():
		var idx := _java_list.add_item("No Java runtimes found on %s. Install a JDK there (e.g. Java 21) or add one by its path." % _remote.source_name())
		_java_list.set_item_disabled(idx, true)


func _remote_java(op: String, args: Dictionary) -> void:
	var source := _remote
	_rescan_button.disabled = true
	_add_java_button.disabled = true
	var res: Dictionary = await source.call_host_op(op, args)
	_rescan_button.disabled = false
	_add_java_button.disabled = false
	if source != _remote:
		return
	if res.has("runtimes"):
		_fill_remote_java(res.runtimes)
	if not res.ok:
		Notifier.warn(str(res.error))


func _apply_remote() -> void:
	var source := _remote
	var categories := {}
	for key in _category_checks:
		categories[key] = (_category_checks[key] as CheckButton).button_pressed
	var res: Dictionary = await source.call_host_op("prefs_save", {"changes": {
		"servers_root": _root_edit.text.strip_edges(),
		"default_ram_mb": int(_default_ram_spin.value),
		"exit_behavior": _exit_option.selected,
		"check_updates_on_launch": _updates_check.button_pressed,
		"show_unstable_versions": _unstable_check.button_pressed,
		"sleep_policy": _sleep_option.selected,
		"restart_after_wake": _wake_check.button_pressed,
		"wake_for_events": _wake_events_check.button_pressed,
		"wake_on_connection": _wake_connect_check.button_pressed,
		"wake_port_block": _chosen_wake_block(),
		"start_at_login": _login_check.button_pressed,
		"start_minimized": _minimized_check.button_pressed,
		"desktop_notifications": _desktop_notify_check.button_pressed,
		"notify_when": _notify_when_option.selected,
		"notify_categories": categories,
	}})
	if res.ok:
		Notifier.success("Saved the preferences of %s." % source.source_name())
	else:
		Notifier.error("%s: %s" % [source.source_name(), res.error])


func _apply() -> void:
	var root := _root_edit.text.strip_edges()
	if root != "" and root != AppSettings.servers_root:
		var err := DirAccess.make_dir_recursive_absolute(root)
		if err != OK:
			Notifier.error("Cannot use %s as servers folder: %s" % [root, error_string(err)])
		else:
			AppSettings.servers_root = root
	AppSettings.default_ram_mb = int(_default_ram_spin.value)
	AppSettings.console_max_lines = int(_console_lines_spin.value)
	AppSettings.exit_behavior = clampi(_exit_option.selected, 0, AppSettings.ExitBehavior.size() - 1) as AppSettings.ExitBehavior
	AppSettings.check_updates_on_launch = _updates_check.button_pressed
	AppSettings.show_unstable_versions = _unstable_check.button_pressed
	AppSettings.ui_scale = UiScale.OPTIONS[clampi(_ui_scale_option.selected, 0, UiScale.OPTIONS.size() - 1)]
	UiScale.apply(get_tree().root)
	AppSettings.sleep_policy = clampi(_sleep_option.selected, 0, AppSettings.SleepPolicy.size() - 1) as AppSettings.SleepPolicy
	AppSettings.restart_after_wake = _wake_check.button_pressed
	AppSettings.wake_for_events = _wake_events_check.button_pressed
	AppSettings.wake_on_connection = _wake_connect_check.button_pressed
	AppSettings.start_minimized = _minimized_check.button_pressed
	AppSettings.desktop_notifications = _desktop_notify_check.button_pressed
	AppSettings.notify_when = clampi(_notify_when_option.selected, 0, AppSettings.NotifyWhen.size() - 1) as AppSettings.NotifyWhen
	for key in _category_checks:
		AppSettings.notify_categories[key] = (_category_checks[key] as CheckButton).button_pressed
	if AppSettings.start_at_login != _login_check.button_pressed:
		AppSettings.start_at_login = _login_check.button_pressed
		var err := AppSettings.apply_autostart()
		if err != OK:
			Notifier.error("Could not update the login autostart entry: %s" % error_string(err))
	AppSettings.save_settings()
	Notifier.success("Settings saved.")
