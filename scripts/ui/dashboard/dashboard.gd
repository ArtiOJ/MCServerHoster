class_name Dashboard
extends MarginContainer
## Overview of one computer and its servers: this one, or another computer someone is
## connected to as its system admin.

signal server_open_requested(handle_key: String)
signal new_server_requested
signal import_server_requested

const CARD_SCENE := preload("res://scenes/dashboard/server_card.tscn")

var _cpu_history := PackedFloat32Array()
var _ram_history := PackedFloat32Array()
var _last_busy := -1
var _last_total := -1
var _cpu_text := "—"
var _source: ServerSource

@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _running_card: StatCard = %RunningCard
@onready var _cpu_card: StatCard = %HostCpuCard
@onready var _ram_card: StatCard = %HostRamCard
@onready var _alloc_card: StatCard = %AllocatedCard
@onready var _cpu_graph: GraphCard = %HostCpuGraph
@onready var _ram_graph: GraphCard = %HostRamGraph
@onready var _cards: HFlowContainer = %Cards
@onready var _empty: PanelContainer = %EmptyState
@onready var _create_button: Button = %CreateButton
@onready var _import_button: Button = %ImportButton
@onready var _start_all: Button = %StartAllButton
@onready var _stop_all: Button = %StopAllButton
@onready var _host_timer: Timer = %HostTimer


func _ready() -> void:
	_create_button.pressed.connect(func() -> void: new_server_requested.emit())
	_import_button.pressed.connect(func() -> void: import_server_requested.emit())
	_start_all.pressed.connect(func() -> void: _source.start_all())
	_stop_all.pressed.connect(func() -> void: _source.stop_all())
	# Other computers report their load themselves (host_stats_changed).
	_host_timer.timeout.connect(func() -> void:
		if not _source.is_remote_source():
			_sample_host())
	show_source(ServerManager)


## Shows the servers and load of [param source].
func show_source(source: ServerSource) -> void:
	if _source != null:
		_source.server_added.disconnect(_add_card)
		_source.server_removed.disconnect(_on_removed)
		_source.server_state_changed.disconnect(_on_state_changed)
		_source.host_stats_changed.disconnect(_sample_host)
	_source = source
	_source.server_added.connect(_add_card)
	_source.server_removed.connect(_on_removed)
	_source.server_state_changed.connect(_on_state_changed)
	_source.host_stats_changed.connect(_sample_host)
	for card in _cards.get_children():
		_cards.remove_child(card)
		card.queue_free()
	_cpu_history.clear()
	_ram_history.clear()
	_last_busy = -1
	_last_total = -1
	_cpu_text = "—"
	var remote := source.is_remote_source()
	_title.text = "Dashboard" if not remote else source.source_name()
	_subtitle.text = "All Minecraft servers hosted on this machine" if not remote \
			else "Servers on %s, managed remotely as its system admin" % source.source_name()
	_import_button.visible = not remote
	_create_button.disabled = not source.can_manage_servers()
	for h in source.get_handles():
		_add_card(h)
	_update_counts()
	_sample_host()


func _on_state_changed(_handle: ServerHandle) -> void:
	_update_counts()


func _add_card(inst: ServerHandle) -> void:
	var card: ServerCard = CARD_SCENE.instantiate()
	_cards.add_child(card)
	card.bind(inst)
	card.open_requested.connect(func(key: String) -> void: server_open_requested.emit(key))
	_update_counts()


func _on_removed(handle_key: String) -> void:
	for card: ServerCard in _cards.get_children():
		if not is_instance_valid(card.instance) or card.instance.key() == handle_key:
			card.queue_free()
	_update_counts.call_deferred()


func _update_counts() -> void:
	var total := _source.get_handles().size()
	var running := _source.running_count()
	_empty.visible = total == 0
	_cards.visible = total > 0
	_running_card.set_value("%d / %d" % [running, total])
	_running_card.set_sub("servers running")
	var reachable := not _source.is_remote_source() or (_source as RemoteLink).is_online()
	_start_all.disabled = total == 0 or running == total or not reachable
	_stop_all.disabled = running == 0 or not reachable
	var stats := _source.host_stats()
	var host_mb := int(stats.get("mem_total", 0)) / 1048576 if _source.is_remote_source() else PlatformBackend.get_current().host_memory_bytes() / 1048576
	var alloc := _source.allocated_ram_mb()
	_alloc_card.set_value(Fmt.megabytes(alloc), Color("f2b84b") if alloc > host_mb * 0.85 else Color(0, 0, 0, 0))
	_alloc_card.set_sub("heap reserved by running servers")


func _sample_host() -> void:
	if _source.is_remote_source():
		_show_remote_host(_source.host_stats())
		return
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


## Load of another computer, as reported by it every few seconds.
func _show_remote_host(stats: Dictionary) -> void:
	if stats.is_empty():
		for card: StatCard in [_cpu_card, _ram_card]:
			card.set_value("—")
			card.set_sub("not connected")
		_update_counts()
		return
	_cpu_text = "%.0f%%" % float(stats.cpu)
	_push(_cpu_history, float(stats.cpu))
	_cpu_card.set_value(_cpu_text)
	_cpu_card.set_sub("%d logical cores" % int(stats.cores))
	var total := float(stats.mem_total)
	var used := float(stats.mem_used)
	if total > 0.0:
		_push(_ram_history, used / 1073741824.0)
		_ram_card.set_value(Fmt.bytes(used))
		_ram_card.set_sub("of %s in use" % Fmt.bytes(total))
		_ram_graph.set_data(_ram_history, "%.0f%%" % (100.0 * used / total), total / 1073741824.0)
	_cpu_graph.set_data(_cpu_history, _cpu_text, 100.0)
	_update_counts()


static func _push(arr: PackedFloat32Array, v: float) -> void:
	arr.append(v)
	if arr.size() > 120:
		arr.remove_at(0)
