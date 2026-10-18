class_name OverviewTab
extends ServerTab
## At-a-glance status of one server: state, players, TPS, uptime, resource graphs
## and connection details.

@onready var _status_card: StatCard = %StatusCard
@onready var _players_card: StatCard = %PlayersCard
@onready var _tps_card: StatCard = %TpsCard
@onready var _uptime_card: StatCard = %UptimeCard
@onready var _cpu_graph: GraphCard = %CpuGraph
@onready var _ram_graph: GraphCard = %RamGraph
@onready var _address_value: Label = %AddressValue
@onready var _version_value: Label = %VersionValue
@onready var _java_value: Label = %JavaValue
@onready var _memory_value: Label = %MemoryValue
@onready var _cpu_value: Label = %CpuValue
@onready var _folder_value: Label = %FolderValue
@onready var _created_value: Label = %CreatedValue
@onready var _online_list: ItemList = %OnlineList
@onready var _online_empty: Label = %OnlineEmpty
@onready var _notice: PanelContainer = %Notice
@onready var _notice_label: Label = %NoticeLabel
@onready var _copy_button: Button = %CopyAddressButton
@onready var _folder_button: Button = %OpenFolderButton
@onready var _tick: Timer = %TickTimer


func _ready() -> void:
	_tick.timeout.connect(_refresh_live)
	_copy_button.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(instance.connect_address())
		Notifier.info("Copied %s to the clipboard." % instance.connect_address()))
	_folder_button.pressed.connect(func() -> void: OS.shell_open(instance.config.directory))


func _on_bound() -> void:
	watch(instance.state_changed, _refresh_all.unbind(1))
	watch(instance.stats_updated, _refresh_live)
	watch(instance.players_changed, _refresh_players)
	watch(instance.config_changed, _refresh_all)
	watch(instance.update_available_changed, _refresh_all)
	_refresh_all()


func _refresh_all() -> void:
	var cfg := instance.config
	_address_value.text = instance.connect_address()
	_version_value.text = "Paper %s, build #%d (%s)" % [cfg.mc_version, cfg.paper_build, cfg.build_channel.to_lower()]
	var java := JavaRuntimes.resolve_for(cfg)
	_java_value.text = java.display_name() if java != null else "Not found — Java %d+ required" % cfg.java_min_version
	_memory_value.text = "%s – %s heap%s" % [Fmt.megabytes(cfg.ram_min_mb), Fmt.megabytes(cfg.ram_max_mb),
			", hard cap %s" % Fmt.megabytes(cfg.hard_cap_mb()) if cfg.memory_hard_cap else ""]
	var cpu := PackedStringArray()
	cpu.append("all cores" if cfg.cpu_cores <= 0 else "%d cores" % cfg.cpu_cores)
	if cfg.cpu_quota_pct > 0:
		cpu.append("quota %d%%" % cfg.cpu_quota_pct)
	if cfg.cpu_affinity != "":
		cpu.append("pinned to %s" % cfg.cpu_affinity)
	if cfg.nice_level > 0:
		cpu.append("nice %d" % cfg.nice_level)
	_cpu_value.text = ", ".join(cpu)
	_folder_value.text = cfg.directory
	_created_value.text = Fmt.datetime(cfg.created_unix) if cfg.created_unix > 0 else "—"

	var notices := PackedStringArray()
	if instance.orphan_pid > 0:
		notices.append("A server process from a previous session is still running (PID %d). Use “Stop leftover process” in the ⋮ menu." % instance.orphan_pid)
	if instance.state == ServerInstance.State.CRASHED:
		notices.append("The server crashed (exit code %d). Check the Console tab for the error." % instance.last_exit_code)
	if instance.is_temporary():
		if instance.is_process_alive():
			notices.append("Running a temporary copy — changes will be discarded or kept when it stops.")
		else:
			notices.append("A temporary copy is waiting for a keep/discard decision (⋮ menu).")
	if instance.update_available_build > 0:
		notices.append("Paper build #%d is available (installed: #%d)." % [instance.update_available_build, cfg.paper_build])
	var problem := instance.start_problem() if not instance.is_busy() and instance.orphan_pid <= 0 and not instance.is_temporary() else ""
	if problem != "":
		notices.append(problem)
	_notice.visible = not notices.is_empty()
	_notice_label.text = "\n".join(notices)

	if instance.is_process_alive():
		_tick.start()
	else:
		_tick.stop()
	_refresh_live()
	_refresh_players()


func _refresh_live() -> void:
	if instance == null:
		return
	_status_card.set_value(instance.state_name(), instance.state_color())
	_status_card.set_sub("PID %d" % instance.process.pid if instance.is_process_alive() else ("exit code %d" % instance.last_exit_code if instance.state == ServerInstance.State.CRASHED else ""))
	_players_card.set_value("%d / %d" % [instance.players.size(), instance.max_players] if instance.is_online() else "—")
	_players_card.set_sub("online" if instance.is_online() else "")
	if instance.is_online() and instance.tps >= 0.0:
		var t := instance.tps
		var color := Color("3fb97f") if t >= 18.0 else (Color("f2b84b") if t >= 15.0 else Color("e05555"))
		_tps_card.set_value("%.1f" % minf(t, 20.0), color)
		_tps_card.set_sub("ticks per second (target 20)")
	else:
		_tps_card.set_value("—")
		_tps_card.set_sub("")
	_uptime_card.set_value(Fmt.duration(instance.uptime_seconds()) if instance.is_online() else "—")
	_uptime_card.set_sub("started in %.1f s" % instance.startup_seconds if instance.startup_seconds >= 0.0 and instance.is_online() else "")

	var mon := instance.monitor
	var cores := OS.get_processor_count()
	var cpu_cap := 100.0
	if instance.config.cpu_quota_pct > 0:
		cpu_cap = minf(100.0, instance.config.cpu_quota_pct / float(cores))
	_cpu_graph.set_data(mon.cpu_history, "%.1f%%  ·  %.2f cores" % [mon.cpu_percent, mon.cpu_cores_used] if instance.is_process_alive() else "—", maxf(cpu_cap * 1.1, 5.0) if cpu_cap < 100.0 else 100.0)
	var ram_max := float(instance.config.hard_cap_mb() if instance.config.memory_hard_cap else instance.config.ram_max_mb + 1024)
	_ram_graph.set_data(mon.ram_history, "%s / %s heap" % [Fmt.bytes(mon.rss_bytes), Fmt.megabytes(instance.config.ram_max_mb)] if instance.is_process_alive() else "—", ram_max)


func _refresh_players() -> void:
	_online_list.clear()
	for p in instance.players:
		_online_list.add_item(p)
	_online_empty.visible = instance.players.is_empty()
	_online_empty.text = "Nobody is online." if instance.is_online() else "Server is offline."
	_refresh_live()
