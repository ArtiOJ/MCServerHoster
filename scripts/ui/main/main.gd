extends Control
## Root of the application: wires the sidebar, content views, dialogs, tray
## icon and global shortcuts together, and handles quitting safely.

## Key of the server shown ("" = dashboard); see ServerHandle.key().
var _current_id := ""
var _quitting := false
## Servers whose temporary run ended while the decision dialog was already showing.
var _temp_queue: Array[ServerHandle] = []
## Whose servers the sidebar and dashboard show: this computer or a remote one.
var _source: ServerSource

@onready var _sidebar: Sidebar = %Sidebar
@onready var _dashboard: Dashboard = %Dashboard
@onready var _server_view: ServerView = %ServerView
@onready var _wizard: NewServerWizard = %NewServerWizard
@onready var _delete_dialog: DeleteServerDialog = %DeleteServerDialog
@onready var _update_dialog: UpdateDialog = %UpdateDialog
@onready var _settings_dialog: AppSettingsDialog = %AppSettingsDialog
@onready var _quit_dialog: QuitDialog = %QuitDialog
@onready var _duplicate_dialog: DuplicateServerDialog = %DuplicateServerDialog
@onready var _temp_dialog: TempRunDialog = %TempRunDialog
@onready var _import_server_dialog: ImportServerDialog = %ImportServerDialog
@onready var _import_world_dialog: ImportWorldDialog = %ImportWorldDialog
@onready var _remote_dialog: RemoteDialog = %RemoteDialog
@onready var _tray: StatusIndicator = %TrayIcon
@onready var _tray_menu: PopupMenu = %TrayMenu


func _ready() -> void:
	if AppSettings.other_instance_pid > 0:
		var message := "Server Manager is already running (PID %d). Switch to that window instead." % AppSettings.other_instance_pid
		printerr(message)
		if DisplayServer.get_name() != "headless":
			OS.alert(message, "Server Manager")
		get_tree().quit()
		return
	get_tree().auto_accept_quit = false
	get_window().min_size = Vector2i(1100, 680)
	# Interface size (Preferences); also sets the scaled minimum window size.
	UiScale.apply(get_window())
	PowerManager.shutting_down.connect(_on_system_shutdown)
	if AppSettings.launched_minimized():
		DisplayServer.window_set_mode.call_deferred(DisplayServer.WINDOW_MODE_MINIMIZED)
	get_window().files_dropped.connect(_on_files_dropped)

	_source = ServerManager
	_sidebar.dashboard_selected.connect(show_dashboard)
	_sidebar.server_selected.connect(show_server)
	_sidebar.source_selected.connect(_switch_source)
	_sidebar.new_server_requested.connect(_open_wizard)
	_sidebar.settings_requested.connect(func() -> void: _settings_dialog.open(_source))
	_sidebar.remote_requested.connect(func() -> void: _remote_dialog.open(RemoteDialog.TabIndex.SHARE, _source))
	_dashboard.server_open_requested.connect(show_server)
	_dashboard.new_server_requested.connect(_open_wizard)
	_sidebar.import_server_requested.connect(func() -> void: _import_server_dialog.open("", _source))
	_dashboard.import_server_requested.connect(func() -> void: _import_server_dialog.open("", _source))
	_import_server_dialog.imported.connect(func(h: ServerHandle) -> void: show_server(h.key()))
	_wizard.server_created.connect(func(h: ServerHandle) -> void: show_server(h.key()))
	_server_view.update_requested.connect(_update_dialog.open)
	_server_view.delete_requested.connect(_delete_dialog.open)
	_server_view.duplicate_requested.connect(_duplicate_dialog.open)
	_server_view.temp_decision_requested.connect(_temp_dialog.open)
	_server_view.import_world_requested.connect(func(h: ServerHandle) -> void: _import_world_dialog.open(h))
	_duplicate_dialog.duplicated.connect(func(h: ServerHandle) -> void:
		if h != null:
			show_server(h.key()))
	ServerManager.temporary_run_ended.connect(_on_temporary_run_ended)
	RemoteHosts.server_added.connect(func(server: RemoteServer) -> void:
		server.temporary_run_ended.connect(_on_temporary_run_ended.bind(server)))
	RemoteHosts.server_removed.connect(func(key: String) -> void:
		if key == _current_id:
			show_dashboard())
	_temp_dialog.visibility_changed.connect(_show_next_temp_decision)
	_quit_dialog.stop_and_quit_requested.connect(_stop_all_and_quit)
	_quit_dialog.minimize_requested.connect(_minimize)
	_quit_dialog.detach_requested.connect(_quit_leaving_servers)
	ServerManager.server_removed.connect(func(id: String) -> void:
		if id == _current_id:
			show_dashboard())
	_tray.pressed.connect(func(button: int, _pos: Vector2i) -> void:
		if button == MOUSE_BUTTON_LEFT:
			_restore_window())
	_tray_menu.id_pressed.connect(_on_tray_menu)

	var last := AppSettings.last_selected_server
	if last != "" and ServerManager.get_instance(last) != null:
		show_server(last)
	else:
		show_dashboard()


## Shows the servers of [param source] (this computer, or one you are system admin of).
func _switch_source(source: ServerSource) -> void:
	_source = source
	_sidebar.show_source(source)
	_dashboard.show_source(source)
	show_dashboard()


## The server with [param handle_key], on this computer or a connected one.
func _find(handle_key: String) -> ServerHandle:
	if handle_key == "":
		return null
	var local := ServerManager.get_instance(handle_key)
	return local if local != null else RemoteHosts.find_server(handle_key)


func _open_wizard() -> void:
	if _source.can_manage_servers():
		_wizard.open(_source)


func show_dashboard() -> void:
	_current_id = ""
	_dashboard.visible = true
	_server_view.visible = false
	_sidebar.select("")
	_remember_selection()


func show_server(handle_key: String) -> void:
	var inst := _find(handle_key)
	if inst == null:
		show_dashboard()
		return
	_current_id = handle_key
	_server_view.show_instance(inst)
	_server_view.visible = true
	_dashboard.visible = false
	_sidebar.select(handle_key)
	_remember_selection()


func _remember_selection() -> void:
	if AppSettings.last_selected_server != _current_id:
		AppSettings.last_selected_server = _current_id
		AppSettings.save_settings()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("server_new"):
		_open_wizard()
	elif event.is_action_pressed("server_next"):
		_select_relative(1)
	elif _current_id != "" and event.is_action_pressed("ui_console_focus"):
		_server_view.focus_console()
	elif _current_id != "" and event.is_action_pressed("server_start_stop"):
		var inst := _find(_current_id)
		if inst == null:
			return
		if inst.is_process_alive():
			inst.stop()
		else:
			inst.start()
	else:
		return
	get_viewport().set_input_as_handled()


func _select_relative(step: int) -> void:
	var all: Array[ServerHandle] = _source.get_handles()
	all.append_array(RemoteHosts.server_admin_servers())
	if all.is_empty():
		return
	var idx := -1
	for i in all.size():
		if all[i].key() == _current_id:
			idx = i
	show_server(all[posmod(idx + step, all.size())].key())


func _on_temporary_run_ended(inst: ServerHandle) -> void:
	if _quitting:
		return  # The copy stays pending and is offered again next session.
	if _temp_dialog.visible:
		if not _temp_queue.has(inst):
			_temp_queue.append(inst)
		return
	_restore_window()
	_temp_dialog.open(inst)


func _show_next_temp_decision() -> void:
	if _temp_dialog.visible or _quitting:
		return
	while not _temp_queue.is_empty():
		var inst: ServerHandle = _temp_queue.pop_front()
		if is_instance_valid(inst) and inst.is_temporary() and not inst.is_process_alive():
			_temp_dialog.open.call_deferred(inst)
			return


const IMAGE_EXTENSIONS: PackedStringArray = ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga", "gif", "avif", "heic", "heif", "ico", "tif", "tiff", "jxl", "psd"]


func _on_files_dropped(files: PackedStringArray) -> void:
	# The icon editor handles its own drops; an image dropped elsewhere opens it for the
	# current server instead of being treated as a plugin.
	if _current_id != "" and (_server_view.is_icon_editor_open()
			or Array(files).all(func(f: String) -> bool: return f.get_extension().to_lower() in IMAGE_EXTENSIONS)):
		if not _server_view.is_icon_editor_open():
			_server_view.open_icon_editor(files[0])
		return
	if _open_server_import_for(files):
		return
	if _open_world_import_for(files):
		return
	if _current_id == "":
		Notifier.warn("Open a server first, then drop plugin .jar files onto the window to install them.")
		return
	_server_view.handle_files_dropped(files)


## A dropped folder that looks like a server (server.properties or a jar, but not a bare
## world with level.dat at its top) opens the import dialog. Returns true if handled.
func _open_server_import_for(files: PackedStringArray) -> bool:
	for path in files:
		if not DirAccess.dir_exists_absolute(path) or FileAccess.file_exists(path.path_join("level.dat")):
			continue
		var has_jar := Array(DirAccess.get_files_at(path)).any(func(f: String) -> bool: return f.ends_with(".jar"))
		if FileAccess.file_exists(path.path_join("server.properties")) or has_jar:
			if _source.can_manage_servers():
				_import_server_dialog.open(path, _source)
			else:
				Notifier.warn("Your access to %s doesn't allow importing servers." % _source.source_name())
			return true
	return false


## A dropped .zip or world folder (level.dat at its top or one level down) opens the
## world import dialog for the current server. Returns true if handled.
func _open_world_import_for(files: PackedStringArray) -> bool:
	for path in files:
		var is_world := path.get_extension().to_lower() in ["zip", "mcworld"]
		if DirAccess.dir_exists_absolute(path):
			is_world = FileAccess.file_exists(path.path_join("level.dat")) or Array(DirAccess.get_directories_at(path)).any(
					func(d: String) -> bool: return FileAccess.file_exists(path.path_join(d).path_join("level.dat")))
		if not is_world:
			continue
		var inst := _find(_current_id)
		if inst == null:
			Notifier.warn("Open a server first, then drop the world onto the window (or use \"Start from an existing world\" when creating a server).")
		else:
			_import_world_dialog.open(inst, path)
		return true
	return false


# --- Quitting & tray ----------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()


func _on_close_requested() -> void:
	if _quitting:
		return
	if not ServerManager.any_running():
		get_tree().quit()
		return
	match AppSettings.exit_behavior:
		AppSettings.ExitBehavior.STOP_ALL:
			_stop_all_and_quit()
		AppSettings.ExitBehavior.MINIMIZE:
			_minimize()
		AppSettings.ExitBehavior.DETACH:
			_quit_leaving_servers()
		_:
			_quit_dialog.open()


## The computer is shutting down or rebooting: stop everything cleanly and exit.
func _on_system_shutdown() -> void:
	if not _quitting:
		_stop_all_and_quit()


func _stop_all_and_quit() -> void:
	_quitting = true
	_restore_window()
	_quit_dialog.show_stopping()
	await ServerManager.stop_all_and_wait()
	get_tree().quit()


## Quits without stopping servers; they are re-attached on the next launch.
func _quit_leaving_servers() -> void:
	_quitting = true
	NetworkService.keep_mappings_on_exit = true
	for inst in ServerManager.get_instances():
		if inst.is_process_alive():
			inst.log_system("Server Manager closed; the server keeps running and will be re-attached on next launch.")
	get_tree().quit()


func _minimize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	var where := "the tray icon" if DisplayServer.has_feature(DisplayServer.FEATURE_STATUS_INDICATOR) else "the taskbar"
	Notifier.info("Server Manager keeps running in the background. Use %s to return." % where)


func _restore_window() -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	get_window().grab_focus()
	DisplayServer.window_move_to_foreground()


func _on_tray_menu(id: int) -> void:
	match id:
		0:
			_restore_window()
		1:
			ServerManager.start_all()
		2:
			ServerManager.stop_all()
		3:
			_on_close_requested_from_tray()


func _on_close_requested_from_tray() -> void:
	_restore_window()
	if ServerManager.any_running():
		_quit_dialog.open()
	else:
		get_tree().quit()
