class_name ServerHeader
extends PanelContainer
## Title bar of the server view: identity, live status and lifecycle controls.

signal update_requested
signal delete_requested
signal duplicate_requested
signal temp_decision_requested
signal import_world_requested

enum MenuItem { OPEN_FOLDER, COPY_ADDRESS, UPDATE, CHECK_UPDATES, STOP_ORPHAN, CLEAR_CONSOLE, DELETE, DUPLICATE, TEMP_DECISION, IMPORT_WORLD, CHANGE_ICON }
enum StartItem { START, START_TEMPORARY }

const TEMP_START_TOOLTIP := "Run a throwaway copy of this server for testing. It shows as this server while running; when it stops you choose whether to keep or discard what changed."

var instance: ServerHandle

@onready var _color_bar: ColorRect = %ColorBar
@onready var _name_label: Label = %NameLabel
@onready var _state_badge: Label = %StateBadge
@onready var _temp_badge: Label = %TempBadge
@onready var _start_menu: MenuButton = %StartMenuButton
@onready var _update_button: Button = %UpdateButton
@onready var _info_label: Label = %InfoLabel
@onready var _start_button: Button = %StartButton
@onready var _stop_button: Button = %StopButton
@onready var _restart_button: Button = %RestartButton
@onready var _kill_button: Button = %KillButton
@onready var _more_button: MenuButton = %MoreButton
@onready var _icon_view: ServerIconView = %IconView
@onready var _icon_editor: IconEditorDialog = %IconEditorDialog


func _ready() -> void:
	_start_button.pressed.connect(func() -> void: instance.start())
	_stop_button.pressed.connect(func() -> void: instance.stop())
	_restart_button.pressed.connect(func() -> void: instance.restart())
	_kill_button.pressed.connect(func() -> void: instance.kill())
	_update_button.pressed.connect(func() -> void: update_requested.emit())
	_more_button.get_popup().id_pressed.connect(_on_menu)
	_icon_view.clicked.connect(func() -> void: _icon_editor.open(instance))
	var start_popup := _start_menu.get_popup()
	start_popup.set_item_tooltip(start_popup.get_item_index(StartItem.START_TEMPORARY), TEMP_START_TOOLTIP)
	start_popup.id_pressed.connect(_on_start_menu)


func bind(inst: ServerHandle) -> void:
	if instance != null and is_instance_valid(instance):
		instance.state_changed.disconnect(_on_state_changed)
		instance.config_changed.disconnect(_refresh)
		instance.update_available_changed.disconnect(_refresh)
	instance = inst
	instance.state_changed.connect(_on_state_changed)
	instance.config_changed.connect(_refresh)
	instance.update_available_changed.connect(_refresh)
	_refresh()


func _on_state_changed(_state: ServerHandle.State) -> void:
	_refresh()


func _refresh() -> void:
	if instance == null:
		return
	var cfg := instance.config
	_color_bar.color = cfg.color
	_icon_view.show_instance(instance)
	_name_label.text = cfg.display_name
	_state_badge.text = instance.state_name().to_upper()
	_state_badge.add_theme_color_override("font_color", instance.state_color())
	var badge_style := (_state_badge.get_theme_stylebox("normal") as StyleBoxFlat).duplicate() as StyleBoxFlat
	badge_style.bg_color = Color(instance.state_color(), 0.16)
	_state_badge.add_theme_stylebox_override("normal", badge_style)
	_temp_badge.visible = instance.is_temporary()
	_update_button.visible = instance.update_available_build > 0
	_update_button.text = "Update to #%d" % instance.update_available_build
	_info_label.text = "Paper %s · build #%d · port %d · %s" % [cfg.mc_version, cfg.paper_build, cfg.port, instance.folder_path()]
	if instance.is_remote():
		_info_label.text = "On %s · %s" % [instance.host_name(), _info_label.text]

	var s := instance.state
	var alive := instance.is_process_alive()
	var installing := s == ServerHandle.State.INSTALLING
	# A server on another computer can only be controlled while connected to it.
	var reachable := not instance.is_remote() or (instance as RemoteServer).is_connected_to_host()
	_start_button.visible = not alive and s != ServerHandle.State.STOPPING
	_start_button.disabled = installing or instance.orphan_pid > 0 or not reachable
	_start_button.tooltip_text = "Keep or discard the temporary copy first (⋮ menu), or resume it from the Start options." \
			if instance.is_temporary() else "Start the server (Ctrl+Enter)"
	_start_menu.visible = _start_button.visible
	_start_menu.disabled = _start_button.disabled
	var start_popup := _start_menu.get_popup()
	var temp_idx := start_popup.get_item_index(StartItem.START_TEMPORARY)
	start_popup.set_item_text(temp_idx, "Resume temporary copy" if instance.is_temporary() else "Start temporary copy")
	start_popup.set_item_disabled(start_popup.get_item_index(StartItem.START), instance.is_temporary())
	_stop_button.visible = alive or s == ServerHandle.State.CRASHED
	_stop_button.disabled = s == ServerHandle.State.STOPPING or not reachable
	_stop_button.text = "Cancel restart" if s == ServerHandle.State.CRASHED else "Stop"
	_restart_button.disabled = installing or s == ServerHandle.State.STOPPING or instance.orphan_pid > 0 or not reachable
	_kill_button.visible = alive
	_kill_button.disabled = not alive or not reachable
	_update_button.disabled = not reachable

	var popup := _more_button.get_popup()
	_set_menu_item(popup, MenuItem.OPEN_FOLDER, instance.supports(ServerHandle.FEATURE_OPEN_FOLDER), "The folder is on " + instance.host_name())
	_set_menu_item(popup, MenuItem.UPDATE, reachable and not alive and not installing)
	_set_menu_item(popup, MenuItem.CHECK_UPDATES, reachable)
	_set_menu_item(popup, MenuItem.DELETE, instance.supports(ServerHandle.FEATURE_DELETE) and reachable and not alive and not installing,
			"Only a system admin of %s can delete servers." % instance.host_name() if not instance.supports(ServerHandle.FEATURE_DELETE) else "")
	_set_menu_item(popup, MenuItem.STOP_ORPHAN, reachable and instance.orphan_pid > 0)
	_set_menu_item(popup, MenuItem.DUPLICATE, instance.supports(ServerHandle.FEATURE_DUPLICATE) and reachable and not installing,
			"Only a system admin of %s can duplicate servers." % instance.host_name() if not instance.supports(ServerHandle.FEATURE_DUPLICATE) else "")
	_set_menu_item(popup, MenuItem.IMPORT_WORLD, instance.supports(ServerHandle.FEATURE_IMPORT_WORLD) and not installing,
			"Importing worlds onto another computer isn't available yet." if not instance.supports(ServerHandle.FEATURE_IMPORT_WORLD) else "")
	_set_menu_item(popup, MenuItem.TEMP_DECISION, reachable and instance.is_temporary() and not alive and not installing)
	_set_menu_item(popup, MenuItem.CHANGE_ICON, reachable)


static func _set_menu_item(popup: PopupMenu, id: int, enabled: bool, why_not := "") -> void:
	var idx := popup.get_item_index(id)
	popup.set_item_disabled(idx, not enabled)
	popup.set_item_tooltip(idx, why_not if not enabled else "")


func _on_start_menu(id: int) -> void:
	match id:
		StartItem.START:
			instance.start()
		StartItem.START_TEMPORARY:
			await instance.start_temporary()
			_refresh()


## Opens the icon editor, optionally with an image file already loaded (e.g. dropped on the window).
func open_icon_editor(path := "") -> void:
	if instance == null:
		return
	if not _icon_editor.visible:
		_icon_editor.open(instance)
	if path != "":
		_icon_editor.load_file(path)


func is_icon_editor_open() -> bool:
	return _icon_editor.visible


func _on_menu(id: int) -> void:
	match id:
		MenuItem.OPEN_FOLDER:
			OS.shell_open(instance.folder_path())
		MenuItem.COPY_ADDRESS:
			# Someone on another computer usually isn't on the server's network.
			var address := instance.public_address() if instance.is_remote() and instance.public_address() != "" else instance.connect_address()
			DisplayServer.clipboard_set(address)
			Notifier.info("Copied %s to the clipboard." % address)
		MenuItem.UPDATE:
			update_requested.emit()
		MenuItem.CHECK_UPDATES:
			Notifier.info("Checking PaperMC for updates…")
			if instance is RemoteServer:
				await (instance as RemoteServer).check_updates()
			else:
				await ServerManager.check_updates()
			if instance.update_available_build > 0:
				Notifier.success("Paper build #%d is available for %s." % [instance.update_available_build, instance.config.mc_version])
			else:
				Notifier.info("%s is on the latest Paper build." % instance.config.display_name)
		MenuItem.STOP_ORPHAN:
			await instance.stop_orphan()
			_refresh()
		MenuItem.CLEAR_CONSOLE:
			instance.clear_console()
		MenuItem.DELETE:
			delete_requested.emit()
		MenuItem.DUPLICATE:
			duplicate_requested.emit()
		MenuItem.TEMP_DECISION:
			temp_decision_requested.emit()
		MenuItem.IMPORT_WORLD:
			import_world_requested.emit()
		MenuItem.CHANGE_ICON:
			_icon_editor.open(instance)
