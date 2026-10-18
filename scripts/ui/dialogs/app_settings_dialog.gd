class_name AppSettingsDialog
extends ConfirmationDialog
## Application preferences: servers folder, defaults, exit behaviour and Java runtimes.

@onready var _root_edit: LineEdit = %RootEdit
@onready var _browse_button: Button = %BrowseButton
@onready var _default_ram_spin: SpinBox = %DefaultRamSpin
@onready var _console_lines_spin: SpinBox = %ConsoleLinesSpin
@onready var _exit_option: OptionButton = %ExitOption
@onready var _updates_check: CheckButton = %UpdatesCheck
@onready var _unstable_check: CheckButton = %UnstableCheck
@onready var _java_list: ItemList = %JavaList
@onready var _rescan_button: Button = %RescanButton
@onready var _add_java_button: Button = %AddJavaButton
@onready var _dir_dialog: FileDialog = %DirDialog
@onready var _java_dialog: FileDialog = %JavaDialog


func _ready() -> void:
	confirmed.connect(_apply)
	_browse_button.pressed.connect(_browse_root)
	_dir_dialog.dir_selected.connect(func(dir: String) -> void: _root_edit.text = dir)
	_rescan_button.pressed.connect(JavaRuntimes.rescan)
	_add_java_button.pressed.connect(func() -> void: _java_dialog.popup_centered())
	_java_dialog.file_selected.connect(_add_java)
	JavaRuntimes.runtimes_changed.connect(_fill_java_list)


## Loads the current settings into the form and shows the dialog.
func open() -> void:
	_root_edit.text = AppSettings.servers_root
	_default_ram_spin.value = AppSettings.default_ram_mb
	_console_lines_spin.value = AppSettings.console_max_lines
	_exit_option.select(AppSettings.exit_behavior)
	_updates_check.button_pressed = AppSettings.check_updates_on_launch
	_unstable_check.button_pressed = AppSettings.show_unstable_versions
	_fill_java_list()
	popup_centered()


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
	AppSettings.save_settings()
	Notifier.success("Settings saved.")
