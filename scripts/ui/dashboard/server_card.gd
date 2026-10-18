class_name ServerCard
extends PanelContainer
## Compact summary of one server on the dashboard, with a quick start/stop toggle.

signal open_requested(server_id: String)

const PLAY_ICON := preload("res://assets/icons/play.svg")
const STOP_ICON := preload("res://assets/icons/stop.svg")

var instance: ServerInstance

@onready var _color_bar: ColorRect = %ColorBar
@onready var _name_label: Label = %NameLabel
@onready var _dot: StatusDot = %StatusDot
@onready var _state_label: Label = %StateLabel
@onready var _info_label: Label = %InfoLabel
@onready var _stats_label: Label = %StatsLabel
@onready var _toggle_button: Button = %ToggleButton
@onready var _open_button: Button = %OpenButton


func _ready() -> void:
	_open_button.pressed.connect(func() -> void: open_requested.emit(instance.config.id))
	_toggle_button.pressed.connect(func() -> void:
		if instance.is_process_alive():
			instance.stop()
		else:
			instance.start())


func bind(inst: ServerInstance) -> void:
	instance = inst
	inst.state_changed.connect(_refresh.unbind(1))
	inst.stats_updated.connect(_refresh)
	inst.players_changed.connect(_refresh)
	inst.config_changed.connect(_refresh)
	_refresh()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
		open_requested.emit(instance.config.id)


func _refresh() -> void:
	if instance == null or not is_node_ready():
		return
	var cfg := instance.config
	_color_bar.color = cfg.color
	_name_label.text = cfg.display_name
	_dot.show_state(instance)
	_state_label.text = instance.state_name()
	_state_label.add_theme_color_override("font_color", instance.state_color())
	_info_label.text = "Paper %s · port %d · %s heap" % [cfg.mc_version, cfg.port, Fmt.megabytes(cfg.ram_max_mb)]
	if instance.is_process_alive():
		var players := "%d/%d players" % [instance.players.size(), instance.max_players] if instance.is_online() else "starting"
		_stats_label.text = "%s · CPU %.0f%% · RAM %s" % [players, instance.monitor.cpu_percent, Fmt.bytes(instance.monitor.rss_bytes)]
	else:
		_stats_label.text = "Starts when a player joins" if instance.is_asleep() else "Offline"
	if instance.is_temporary():
		_stats_label.text += " · temp copy"
	var alive := instance.is_process_alive()
	_toggle_button.text = "Stop" if alive else "Start"
	_toggle_button.icon = STOP_ICON if alive else PLAY_ICON
	_toggle_button.theme_type_variation = &"" if alive else &"AccentButton"
	_toggle_button.disabled = instance.state in [ServerInstance.State.STOPPING, ServerInstance.State.INSTALLING]
