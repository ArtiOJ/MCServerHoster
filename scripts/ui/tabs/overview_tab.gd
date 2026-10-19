class_name OverviewTab
extends ServerTab
## At-a-glance status of one server: state, players, TPS, uptime, resource graphs
## and connection details. Works for servers on other computers too.

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
@onready var _icon_view: ServerIconView = %IconView
@onready var _icon_status: Label = %IconStatus
@onready var _change_icon_button: Button = %ChangeIconButton
@onready var _icon_editor: IconEditorDialog = %IconEditorDialog
@onready var _tick: Timer = %TickTimer


func _ready() -> void:
	_tick.timeout.connect(_refresh_live)
	_copy_button.pressed.connect(func() -> void:
		var address := _player_address()
		DisplayServer.clipboard_set(address)
		Notifier.info("Copied %s to the clipboard." % address))
	_folder_button.pressed.connect(func() -> void: OS.shell_open(handle.folder_path()))
	_icon_view.clicked.connect(func() -> void: _icon_editor.open(handle))
	_change_icon_button.pressed.connect(func() -> void: _icon_editor.open(handle))


func _on_bound() -> void:
	watch(handle.state_changed, _refresh_all.unbind(1))
	watch(handle.stats_updated, _refresh_live)
	watch(handle.players_changed, _refresh_players)
	watch(handle.config_changed, _refresh_all)
	watch(handle.update_available_changed, _refresh_all)
	watch(NetworkService.status_changed, _refresh_all)
	_refresh_all()


func _refresh_all() -> void:
	var cfg := handle.config
	_refresh_icon()
	var public := handle.public_address()
	_address_value.text = handle.connect_address() + ("   ·   from the internet: %s" % public if public != "" else "")
	_version_value.text = "Paper %s, build #%d (%s)" % [cfg.mc_version, cfg.paper_build, cfg.build_channel.to_lower()]
	_java_value.text = handle.java_description()
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
	_folder_value.text = handle.folder_path() + ("  (on %s)" % handle.host_name() if handle.is_remote() else "")
	_folder_button.visible = handle.supports(ServerHandle.FEATURE_OPEN_FOLDER)
	_created_value.text = Fmt.datetime(cfg.created_unix) if cfg.created_unix > 0 else "—"

	var notices := PackedStringArray()
	if handle is RemoteServer:
		notices.append_array(_remote_notices(handle as RemoteServer))
	if handle.orphan_pid > 0:
		notices.append("A server process from a previous session is still running (PID %d). Use “Stop leftover process” in the ⋮ menu." % handle.orphan_pid)
	if handle.state == ServerHandle.State.CRASHED:
		notices.append("The server crashed (exit code %d). Check the Console tab for the error." % handle.last_exit_code)
	if handle.is_temporary():
		if handle.is_process_alive():
			notices.append("Running a temporary copy — changes will be discarded or kept when it stops.")
		else:
			notices.append("A temporary copy is waiting for a keep/discard decision (⋮ menu).")
	if handle.update_available_build > 0:
		notices.append("Paper build #%d is available (installed: #%d)." % [handle.update_available_build, cfg.paper_build])
	var problem := handle.start_problem() if not handle.is_busy() and handle.orphan_pid <= 0 and not handle.is_temporary() else ""
	if problem != "":
		notices.append(problem)
	_notice.visible = not notices.is_empty()
	_notice_label.text = "\n".join(notices)

	if handle.is_process_alive():
		_tick.start()
	else:
		_tick.stop()
	_refresh_live()
	_refresh_players()


func _refresh_live() -> void:
	if handle == null:
		return
	_status_card.set_value(handle.state_name(), handle.state_color())
	_status_card.set_sub("PID %d" % handle.process_id() if handle.is_process_alive() else ("exit code %d" % handle.last_exit_code if handle.state == ServerHandle.State.CRASHED else ""))
	_players_card.set_value("%d / %d" % [handle.players.size(), handle.max_players] if handle.is_online() else "—")
	_players_card.set_sub("online" if handle.is_online() else "")
	if handle.is_online() and handle.tps >= 0.0:
		var t := handle.tps
		var color := Color("3fb97f") if t >= 18.0 else (Color("f2b84b") if t >= 15.0 else Color("e05555"))
		_tps_card.set_value("%.1f" % minf(t, 20.0), color)
		_tps_card.set_sub("ticks per second (target 20)")
	else:
		_tps_card.set_value("—")
		_tps_card.set_sub("")
	_uptime_card.set_value(Fmt.duration(handle.uptime_seconds()) if handle.is_online() else "—")
	_uptime_card.set_sub("started in %.1f s" % handle.startup_seconds if handle.startup_seconds >= 0.0 and handle.is_online() else "")

	var cores := handle.host_cores()
	var cpu_cap := 100.0
	if handle.config.cpu_quota_pct > 0:
		cpu_cap = minf(100.0, handle.config.cpu_quota_pct / float(cores))
	_cpu_graph.set_data(handle.cpu_history(), "%.1f%%  ·  %.2f cores" % [handle.cpu_percent(), handle.cpu_cores_used()] if handle.is_process_alive() else "—", maxf(cpu_cap * 1.1, 5.0) if cpu_cap < 100.0 else 100.0)
	var ram_max := float(handle.config.hard_cap_mb() if handle.config.memory_hard_cap else handle.config.ram_max_mb + 1024)
	_ram_graph.set_data(handle.ram_history(), "%s / %s heap" % [Fmt.bytes(handle.rss_bytes()), Fmt.megabytes(handle.config.ram_max_mb)] if handle.is_process_alive() else "—", ram_max)


func _refresh_players() -> void:
	_online_list.clear()
	for p in handle.players:
		_online_list.add_item(p)
	_online_empty.visible = handle.players.is_empty()
	_online_empty.text = "Nobody is online." if handle.is_online() else "Server is offline."
	_refresh_live()


func _refresh_icon() -> void:
	_icon_view.show_instance(handle)
	var info := handle.icon_info()
	_icon_status.remove_theme_color_override("font_color")
	if not info.exists:
		_icon_status.text = "No server icon. Players see Minecraft's default icon."
		_change_icon_button.text = "Add icon…"
	elif not info.valid:
		_icon_status.text = "server-icon.png is %d×%d; Minecraft only shows 64×64 icons, so it's ignored." % [info.size.x, info.size.y]
		_icon_status.add_theme_color_override("font_color", Color("f2b84b"))
		_change_icon_button.text = "Fix icon…"
	else:
		_icon_status.text = "64×64 icon shown in the server list."
		_change_icon_button.text = "Change icon…"


## The address to give players: for a server on another computer, its internet address
## (whoever looks at it is usually not on that network).
func _player_address() -> String:
	if handle.is_remote() and handle.public_address() != "":
		return handle.public_address()
	return handle.connect_address()


func _remote_notices(remote: RemoteServer) -> PackedStringArray:
	var out := PackedStringArray()
	if not remote.is_connected_to_host():
		out.append("Not connected to %s right now%s. Showing the last known state." % [remote.host_name(), (": " + remote.link.error) if remote.link.error != "" else ""])
	# Sibling tabs that only work for servers on this computer are hidden for this one.
	var hidden := PackedStringArray()
	for tab in get_parent().get_children():
		if tab is ServerTab and not tab.remote_ready:
			hidden.append(str(tab.name))
	if not hidden.is_empty():
		var listed := ", ".join(hidden.slice(0, -1)) + " and " + hidden[-1] if hidden.size() > 1 else hidden[0]
		out.append("This server runs on %s. %s can only be managed on that computer for now." % [remote.host_name(), listed])
	return out
