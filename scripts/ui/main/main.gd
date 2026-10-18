extends Control
## Root of the application: wires the sidebar, content views, dialogs, tray
## icon and global shortcuts together, and handles quitting safely.

var _current_id := ""
var _quitting := false
## Servers whose temporary run ended while the decision dialog was already showing.
var _temp_queue: Array[ServerInstance] = []

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
@onready var _tray: StatusIndicator = %TrayIcon
@onready var _tray_menu: PopupMenu = %TrayMenu


func _ready() -> void:
	get_tree().auto_accept_quit = false
	get_window().min_size = Vector2i(1100, 680)
	get_window().files_dropped.connect(_on_files_dropped)

	_sidebar.dashboard_selected.connect(show_dashboard)
	_sidebar.server_selected.connect(show_server)
	_sidebar.new_server_requested.connect(_wizard.open)
	_sidebar.settings_requested.connect(_settings_dialog.open)
	_dashboard.server_open_requested.connect(show_server)
	_dashboard.new_server_requested.connect(_wizard.open)
	_wizard.server_created.connect(func(inst: ServerInstance) -> void: show_server(inst.config.id))
	_server_view.update_requested.connect(_update_dialog.open)
	_server_view.delete_requested.connect(_delete_dialog.open)
	_server_view.duplicate_requested.connect(_duplicate_dialog.open)
	_server_view.temp_decision_requested.connect(_temp_dialog.open)
	_duplicate_dialog.duplicated.connect(func(inst: ServerInstance) -> void: show_server(inst.config.id))
	ServerManager.temporary_run_ended.connect(_on_temporary_run_ended)
	_temp_dialog.visibility_changed.connect(_show_next_temp_decision)
	_quit_dialog.stop_and_quit_requested.connect(_stop_all_and_quit)
	_quit_dialog.minimize_requested.connect(_minimize)
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


func show_dashboard() -> void:
	_current_id = ""
	_dashboard.visible = true
	_server_view.visible = false
	_sidebar.select("")
	_remember_selection()


func show_server(server_id: String) -> void:
	var inst := ServerManager.get_instance(server_id)
	if inst == null:
		show_dashboard()
		return
	_current_id = server_id
	_server_view.show_instance(inst)
	_server_view.visible = true
	_dashboard.visible = false
	_sidebar.select(server_id)
	_remember_selection()


func _remember_selection() -> void:
	if AppSettings.last_selected_server != _current_id:
		AppSettings.last_selected_server = _current_id
		AppSettings.save_settings()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("server_new"):
		_wizard.open()
	elif event.is_action_pressed("server_next"):
		_select_relative(1)
	elif _current_id != "" and event.is_action_pressed("ui_console_focus"):
		_server_view.focus_console()
	elif _current_id != "" and event.is_action_pressed("server_start_stop"):
		var inst := ServerManager.get_instance(_current_id)
		if inst.is_process_alive():
			inst.stop()
		else:
			inst.start()
	else:
		return
	get_viewport().set_input_as_handled()


func _select_relative(step: int) -> void:
	var all := ServerManager.get_instances()
	if all.is_empty():
		return
	var idx := -1
	for i in all.size():
		if all[i].config.id == _current_id:
			idx = i
	show_server(all[posmod(idx + step, all.size())].config.id)


func _on_temporary_run_ended(inst: ServerInstance) -> void:
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
		var inst: ServerInstance = _temp_queue.pop_front()
		if is_instance_valid(inst) and inst.is_temporary() and not inst.is_process_alive():
			_temp_dialog.open.call_deferred(inst)
			return


func _on_files_dropped(files: PackedStringArray) -> void:
	if _current_id == "":
		Notifier.warn("Open a server first, then drop plugin .jar files onto the window to install them.")
		return
	_server_view.handle_files_dropped(files)


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
		_:
			_quit_dialog.open()


func _stop_all_and_quit() -> void:
	_quitting = true
	_restore_window()
	_quit_dialog.show_stopping()
	await ServerManager.stop_all_and_wait()
	get_tree().quit()


func _minimize() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	Notifier.info("Server Manager keeps running in the background. Use the tray icon to return.")


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
