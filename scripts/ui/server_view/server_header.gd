class_name ServerHeader
extends PanelContainer
## Title bar of the server view: identity, live status and lifecycle controls.

signal update_requested
signal delete_requested

enum MenuItem { OPEN_FOLDER, COPY_ADDRESS, UPDATE, CHECK_UPDATES, STOP_ORPHAN, CLEAR_CONSOLE, DELETE }

var instance: ServerInstance

@onready var _color_bar: ColorRect = %ColorBar
@onready var _name_label: Label = %NameLabel
@onready var _state_badge: Label = %StateBadge
@onready var _update_button: Button = %UpdateButton
@onready var _info_label: Label = %InfoLabel
@onready var _start_button: Button = %StartButton
@onready var _stop_button: Button = %StopButton
@onready var _restart_button: Button = %RestartButton
@onready var _kill_button: Button = %KillButton
@onready var _more_button: MenuButton = %MoreButton


func _ready() -> void:
	_start_button.pressed.connect(func() -> void: instance.start())
	_stop_button.pressed.connect(func() -> void: instance.stop())
	_restart_button.pressed.connect(func() -> void: instance.restart())
	_kill_button.pressed.connect(func() -> void: instance.kill())
	_update_button.pressed.connect(func() -> void: update_requested.emit())
	_more_button.get_popup().id_pressed.connect(_on_menu)


func bind(inst: ServerInstance) -> void:
	if instance != null and is_instance_valid(instance):
		instance.state_changed.disconnect(_on_state_changed)
		instance.config_changed.disconnect(_refresh)
		instance.update_available_changed.disconnect(_refresh)
	instance = inst
	instance.state_changed.connect(_on_state_changed)
	instance.config_changed.connect(_refresh)
	instance.update_available_changed.connect(_refresh)
	_refresh()


func _on_state_changed(_state: ServerInstance.State) -> void:
	_refresh()


func _refresh() -> void:
	if instance == null:
		return
	var cfg := instance.config
	_color_bar.color = cfg.color
	_name_label.text = cfg.display_name
	_state_badge.text = instance.state_name().to_upper()
	_state_badge.add_theme_color_override("font_color", instance.state_color())
	var badge_style := (_state_badge.get_theme_stylebox("normal") as StyleBoxFlat).duplicate() as StyleBoxFlat
	badge_style.bg_color = Color(instance.state_color(), 0.16)
	_state_badge.add_theme_stylebox_override("normal", badge_style)
	_update_button.visible = instance.update_available_build > 0
	_update_button.text = "Update to #%d" % instance.update_available_build
	_info_label.text = "Paper %s · build #%d · port %d · %s" % [cfg.mc_version, cfg.paper_build, cfg.port, cfg.directory]

	var s := instance.state
	var alive := instance.is_process_alive()
	var installing := s == ServerInstance.State.INSTALLING
	_start_button.visible = not alive and s != ServerInstance.State.STOPPING
	_start_button.disabled = installing or instance.orphan_pid > 0
	_stop_button.visible = alive or s == ServerInstance.State.CRASHED
	_stop_button.disabled = s == ServerInstance.State.STOPPING
	_stop_button.text = "Cancel restart" if s == ServerInstance.State.CRASHED else "Stop"
	_restart_button.disabled = installing or s == ServerInstance.State.STOPPING or instance.orphan_pid > 0
	_kill_button.visible = alive
	_kill_button.disabled = not alive

	var popup := _more_button.get_popup()
	popup.set_item_disabled(popup.get_item_index(MenuItem.UPDATE), alive or installing)
	popup.set_item_disabled(popup.get_item_index(MenuItem.DELETE), alive or installing)
	popup.set_item_disabled(popup.get_item_index(MenuItem.STOP_ORPHAN), instance.orphan_pid <= 0)


func _on_menu(id: int) -> void:
	match id:
		MenuItem.OPEN_FOLDER:
			OS.shell_open(instance.config.directory)
		MenuItem.COPY_ADDRESS:
			DisplayServer.clipboard_set(instance.connect_address())
			Notifier.info("Copied %s to the clipboard." % instance.connect_address())
		MenuItem.UPDATE:
			update_requested.emit()
		MenuItem.CHECK_UPDATES:
			Notifier.info("Checking PaperMC for updates…")
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
