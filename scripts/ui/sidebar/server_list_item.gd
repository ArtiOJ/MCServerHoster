class_name ServerListItem
extends Button
## One row in the sidebar's server list. Reflects the bound server's live state.

var instance: ServerInstance

@onready var _dot: StatusDot = %StatusDot
@onready var _name_label: Label = %NameLabel
@onready var _sub_label: Label = %SubLabel
@onready var _players_label: Label = %PlayersLabel
@onready var _color_bar: ColorRect = %ColorBar
@onready var _icon_view: ServerIconView = %IconView


func bind(inst: ServerInstance) -> void:
	instance = inst
	inst.state_changed.connect(_refresh.unbind(1))
	inst.players_changed.connect(_refresh)
	inst.config_changed.connect(_refresh)
	inst.update_available_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	if not is_node_ready() or instance == null:
		return
	_dot.show_state(instance)
	_color_bar.color = instance.config.color
	_icon_view.show_instance(instance)
	_name_label.text = instance.config.display_name
	var sub := "%s · %s" % [instance.state_name(), instance.config.mc_version]
	if instance.is_temporary():
		sub += " · temp copy"
	if instance.update_available_build > 0:
		sub += " · update"
	_sub_label.text = sub
	_players_label.visible = instance.is_online()
	_players_label.text = "%d/%d" % [instance.players.size(), instance.max_players]
	tooltip_text = "%s\n%s\nPort %d" % [instance.config.display_name, instance.config.directory, instance.config.port]
