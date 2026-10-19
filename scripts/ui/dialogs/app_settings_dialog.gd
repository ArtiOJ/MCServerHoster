class_name AppSettingsDialog
extends ConfirmationDialog
## Application preferences: servers folder, defaults, power & background behaviour and Java runtimes.

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
@onready var _setup_wake_button: Button = %SetupWakeButton
@onready var _remove_wake_button: Button = %RemoveWakeButton
@onready var _wake_setup_dialog: ConfirmationDialog = %WakeSetupDialog
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
	"power": %NotifyPowerCheck, "event": %NotifyEventCheck,
}
@onready var _dir_dialog: FileDialog = %DirDialog
@onready var _java_dialog: FileDialog = %JavaDialog


func _ready() -> void:
	_setup_wake_button.pressed.connect(_start_wake_setup)
	_remove_wake_button.pressed.connect(_remove_wake)
	_wake_setup_dialog.confirmed.connect(_install_wake)
	for c: CheckButton in [_wake_events_check, _wake_connect_check]:
		c.toggled.connect(func(_on: bool) -> void:
			AppSettings.wake_for_events = _wake_events_check.button_pressed
			AppSettings.wake_on_connection = _wake_connect_check.button_pressed
			_refresh_wake())
	confirmed.connect(_apply)
	# Interface size previews live; Cancel puts the saved size back.
	_ui_scale_option.item_selected.connect(func(index: int) -> void: _preview_scale(UiScale.OPTIONS[index]))
	canceled.connect(func() -> void:
		_preview_scale(AppSettings.ui_scale)
		AppSettings.wake_for_events = _saved_wake[0]
		AppSettings.wake_on_connection = _saved_wake[1])
	_browse_button.pressed.connect(_browse_root)
	_dir_dialog.dir_selected.connect(func(dir: String) -> void: _root_edit.text = dir)
	_rescan_button.pressed.connect(JavaRuntimes.rescan)
	_add_java_button.pressed.connect(func() -> void: _java_dialog.popup_centered())
	_java_dialog.file_selected.connect(_add_java)
	JavaRuntimes.runtimes_changed.connect(_fill_java_list)
	_desktop_notify_check.toggled.connect(func(_on: bool) -> void: _update_notify_controls())
	_notify_when_option.item_selected.connect(func(_i: int) -> void: _update_notify_controls())
	_test_notify_button.pressed.connect(func() -> void:
		if not Notifier.send_test():
			Notifier.warn("Could not show a desktop notification (notify-send is missing)."))
	_copy_limit_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(PowerManager.RAISE_LIMIT_COMMAND)
		Notifier.info("Command copied. Paste it into a terminal, then reboot."))


## Loads the current settings into the form and shows the dialog.
func open() -> void:
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
	_minimized_check.button_pressed = AppSettings.start_minimized
	_sleep_option.disabled = not PowerManager.supported
	_wake_check.disabled = not PowerManager.supported
	_power_status.text = PowerManager.status_text()
	_saved_wake = [AppSettings.wake_for_events, AppSettings.wake_on_connection]
	_wake_events_check.button_pressed = AppSettings.wake_for_events
	_wake_connect_check.button_pressed = AppSettings.wake_on_connection
	_refresh_wake()
	_limit_notice.visible = PowerManager.supported and PowerManager.max_delay_sec < 60.0
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
	var available := Notifier.is_desktop_available()
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
var _saved_wake := [true, false]


func _refresh_wake() -> void:
	var installed := WakeHelper.is_installed()
	var available := PowerManager.supported and OS.get_name() == "Linux"
	_setup_wake_button.visible = not installed
	_remove_wake_button.visible = installed
	for c: Control in [_setup_wake_button, _remove_wake_button]:
		(c as Button).disabled = _wake_busy or not available
	_wake_events_check.disabled = not available
	_wake_connect_check.disabled = not available or not WakeHelper.wake_interface().get("wireless", false)
	_wake_status.text = "Waiting for your password…" if _wake_busy else PowerManager.describe_wake()


func _start_wake_setup() -> void:
	_wake_setup_dialog.dialog_text = "To wake this computer from sleep, Server Manager needs to set its wake-up alarm, which only root can do. This installs:\n\n%s\n\nYour password is asked once now. Nothing else on the system is changed, and “Remove” uninstalls both files." % WakeHelper.install_summary()
	_wake_setup_dialog.popup_centered()


func _install_wake() -> void:
	_wake_busy = true
	_refresh_wake()
	var staging := ProjectSettings.globalize_path("user://wake-setup")
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary: return WakeHelper.install(staging))
	_wake_busy = false
	_refresh_wake()
	if result.ok:
		Notifier.success(result.message)
		PowerManager.update_locks()
	else:
		Notifier.error(result.message)


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
