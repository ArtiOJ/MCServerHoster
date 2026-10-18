class_name Dashboard
extends MarginContainer
## Overview of the host machine and every managed server.

signal server_open_requested(server_id: String)
signal new_server_requested

const CARD_SCENE := preload("res://scenes/dashboard/server_card.tscn")

var _cpu_history := PackedFloat32Array()
var _ram_history := PackedFloat32Array()
var _last_busy := -1
var _last_total := -1
var _cpu_text := "—"

@onready var _running_card: StatCard = %RunningCard
@onready var _cpu_card: StatCard = %HostCpuCard
@onready var _ram_card: StatCard = %HostRamCard
@onready var _alloc_card: StatCard = %AllocatedCard
@onready var _cpu_graph: GraphCard = %HostCpuGraph
@onready var _ram_graph: GraphCard = %HostRamGraph
@onready var _cards: HFlowContainer = %Cards
@onready var _empty: PanelContainer = %EmptyState
@onready var _create_button: Button = %CreateButton
@onready var _start_all: Button = %StartAllButton
@onready var _stop_all: Button = %StopAllButton
@onready var _host_timer: Timer = %HostTimer


func _ready() -> void:
	_create_button.pressed.connect(func() -> void: new_server_requested.emit())
	_start_all.pressed.connect(ServerManager.start_all)
	_stop_all.pressed.connect(ServerManager.stop_all)
	_host_timer.timeout.connect(_sample_host)
	ServerManager.server_added.connect(_add_card)
	ServerManager.server_removed.connect(_on_removed)
	ServerManager.server_state_changed.connect(_update_counts.unbind(1))
	for inst in ServerManager.get_instances():
		_add_card(inst)
	_update_counts()
	_sample_host()


func _add_card(inst: ServerInstance) -> void:
	var card: ServerCard = CARD_SCENE.instantiate()
	_cards.add_child(card)
	card.bind(inst)
	card.open_requested.connect(func(id: String) -> void: server_open_requested.emit(id))
	_update_counts()


func _on_removed(server_id: String) -> void:
	for card: ServerCard in _cards.get_children():
		if not is_instance_valid(card.instance) or card.instance.config.id == server_id:
			card.queue_free()
	_update_counts.call_deferred()


func _update_counts() -> void:
	var total := ServerManager.get_instances().size()
	var running := ServerManager.running_count()
	_empty.visible = total == 0
	_cards.visible = total > 0
	_running_card.set_value("%d / %d" % [running, total])
	_running_card.set_sub("servers running")
	_start_all.disabled = total == 0 or running == total
	_stop_all.disabled = running == 0
	var host_mb := PlatformBackend.get_current().host_memory_bytes() / 1048576
	var alloc := ServerManager.allocated_ram_mb()
	_alloc_card.set_value(Fmt.megabytes(alloc), Color("f2b84b") if alloc > host_mb * 0.85 else Color(0, 0, 0, 0))
	_alloc_card.set_sub("heap reserved by running servers")


func _sample_host() -> void:
	var s := PlatformBackend.get_current().sample_host()
	if s.cpu_total > 0 and _last_total > 0 and s.cpu_total > _last_total:
		var pct: float = 100.0 * (s.cpu_busy - _last_busy) / float(s.cpu_total - _last_total)
		_push(_cpu_history, pct)
		_cpu_text = "%.0f%%" % pct
		_cpu_card.set_value(_cpu_text)
	_last_busy = s.cpu_busy
	_last_total = s.cpu_total
	_cpu_card.set_sub("%d logical cores" % OS.get_processor_count())
	if s.mem_total > 0:
		var used: int = s.mem_total - s.mem_available
		_push(_ram_history, used / 1073741824.0)
		_ram_card.set_value(Fmt.bytes(used))
		_ram_card.set_sub("of %s in use" % Fmt.bytes(s.mem_total))
		_ram_graph.set_data(_ram_history, "%.0f%%" % (100.0 * used / s.mem_total), s.mem_total / 1073741824.0)
	_cpu_graph.set_data(_cpu_history, _cpu_text, 100.0)
	_update_counts()


static func _push(arr: PackedFloat32Array, v: float) -> void:
	arr.append(v)
	if arr.size() > 120:
		arr.remove_at(0)
