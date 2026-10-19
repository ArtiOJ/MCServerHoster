class_name ResourcesTab
extends ServerTab
## Memory, CPU, Java and network settings of one server. Edits go to a draft
## copy of the config and are saved through ServerOps. Limits, Java runtimes and port
## checks come from the computer the server runs on (see ServerOps.resources_info).
## Server admins of a remote server can't change the Java executable or arguments.

const RESCAN_META := "__rescan__"
const OK_COLOR := Color("3fb97f")
const WARNING_COLOR := Color("f2b84b")
const ERROR_COLOR := Color("e05555")
## Config fields this tab edits (used for dirty tracking and saving).
const EDITED_FIELDS: PackedStringArray = [
	"ram_max_mb", "ram_min_mb", "memory_hard_cap", "cpu_cores", "cpu_quota_pct", "cpu_affinity",
	"nice_level", "java_path", "jvm_preset", "extra_jvm_args", "extra_server_args", "port",
]

var _draft: ServerConfig
var _loading := false
var _saving := false
## Facts about the server's computer (ServerOps.resources_info).
var _info := {}
## Result of the last port check for [member _checked_port].
var _port_check := {}
var _checked_port := 0
var _port_serial := 0
var _preview_serial := 0

@onready var _running_notice: PanelContainer = %RunningNotice
@onready var _max_ram: SliderField = %MaxRamField
@onready var _min_ram: SliderField = %MinRamField
@onready var _hard_cap_check: CheckButton = %HardCapCheck
@onready var _host_ram_label: Label = %HostRamLabel
@onready var _ram_warning: Label = %RamWarning
@onready var _cores_field: SliderField = %CoresField
@onready var _quota_field: SliderField = %QuotaField
@onready var _affinity_edit: LineEdit = %AffinityEdit
@onready var _affinity_status: Label = %AffinityStatus
@onready var _nice_field: SliderField = %NiceField
@onready var _support_label: Label = %SupportLabel
@onready var _java_option: OptionButton = %JavaOption
@onready var _preset_option: OptionButton = %PresetOption
@onready var _extra_args_edit: LineEdit = %ExtraArgsEdit
@onready var _server_args_edit: LineEdit = %ServerArgsEdit
@onready var _java_info: Label = %JavaInfo
@onready var _java_warning: Label = %JavaWarning
@onready var _command_preview: CodeEdit = %CommandPreview
@onready var _port_spin: PortField = %PortSpin
@onready var _port_status: Label = %PortStatus
@onready var _rcon_label: Label = %RconLabel
@onready var _dirty_label: Label = %DirtyLabel
@onready var _revert_button: Button = %RevertButton
@onready var _save_button: Button = %SaveButton


func _ready() -> void:
	for preset_name in ServerConfig.JVM_PRESET_NAMES:
		_preset_option.add_item(preset_name)
	for field: SliderField in [_max_ram, _min_ram, _cores_field, _quota_field, _nice_field]:
		field.value_changed.connect(_on_input_changed.unbind(1))
	_hard_cap_check.toggled.connect(_on_input_changed.unbind(1))
	_affinity_edit.text_changed.connect(_on_input_changed.unbind(1))
	_preset_option.item_selected.connect(_on_input_changed.unbind(1))
	_extra_args_edit.text_changed.connect(_on_input_changed.unbind(1))
	_server_args_edit.text_changed.connect(_on_input_changed.unbind(1))
	_port_spin.port_changed.connect(_on_input_changed.unbind(2))
	_java_option.item_selected.connect(_on_java_selected)
	JavaRuntimes.runtimes_changed.connect(func() -> void:
		if handle != null and not handle.is_remote():
			_load_info(false))
	_revert_button.pressed.connect(_load_draft)
	_save_button.pressed.connect(_save)


func _on_bound() -> void:
	_draft = null
	_info = {}
	_port_check = {}
	_checked_port = 0
	watch(handle.config_changed, _on_config_changed)
	watch(handle.state_changed, _on_state_changed)
	_load_info(true)


## Fetches the computer's limits and Java runtimes; [param reload] also resets the draft.
func _load_info(reload: bool) -> void:
	var h := handle
	var res: Dictionary = await h.call_op("resources_info")
	if h != handle:
		return
	_info = res if res.ok else {}
	_apply_host_limits()
	if reload or _draft == null:
		_load_draft()
	else:
		_fill_java_options()
		_refresh()


func _apply_host_limits() -> void:
	var host_mb := _host_mb()
	var cores := _cores()
	_max_ram.max_value = maxi(1024, (host_mb / 256) * 256)
	_cores_field.max_value = cores
	_quota_field.max_value = cores * 100
	var host := "this computer" if not handle.is_remote() else handle.host_name()
	var unsupported := PackedStringArray()
	# Windows simply has no equivalent; on Linux the missing tool is named.
	var windows := str(_info.get("os", "")) == "Windows"
	_quota_field.set_editable(bool(_info.get("quota", false)))
	if not _info.get("quota", false):
		unsupported.append("CPU quota" if windows else "CPU quota (needs systemd-run and cgroups v2)")
	_hard_cap_check.disabled = not _info.get("memory_cap", false)
	if not _info.get("memory_cap", false):
		unsupported.append("hard memory limit" if windows else "hard memory limit (needs systemd-run and cgroups v2)")
	_affinity_edit.editable = bool(_info.get("affinity", false))
	if not _info.get("affinity", false):
		unsupported.append("core pinning (needs taskset)")
	_nice_field.set_editable(bool(_info.get("priority", false)))
	if not _info.get("priority", false):
		unsupported.append("process priority (needs nice)")
	_support_label.text = "Not available on %s: %s." % [host, ", ".join(unsupported)]
	_support_label.visible = not unsupported.is_empty() and not _info.is_empty()
	# Choosing what runs on the computer is for its system admins only.
	var host_admin := handle.can_manage_host()
	var why := "" if host_admin else "Only a system admin of %s can change the Java executable and its arguments." % host
	_java_option.disabled = not host_admin
	_extra_args_edit.editable = host_admin
	_server_args_edit.editable = host_admin
	for c: Control in [_java_option, _extra_args_edit, _server_args_edit]:
		c.tooltip_text = why


func _host_mb() -> int:
	return int(_info.get("host_mb", PlatformBackend.get_current().host_memory_bytes() / 1048576 if not handle.is_remote() else 4096))


func _cores() -> int:
	return maxi(int(_info.get("cores", handle.host_cores())), 1)


func _on_config_changed() -> void:
	if _draft == null or not _is_dirty():
		_load_draft()


func _on_state_changed(_state: ServerHandle.State) -> void:
	if _draft != null:
		_refresh()


func _load_draft() -> void:
	if handle == null:
		return
	_draft = ServerConfig.from_dict(handle.config.to_dict(), handle.config.directory)
	_loading = true
	_max_ram.value = _draft.ram_max_mb
	_min_ram.max_value = _draft.ram_max_mb
	_min_ram.value = _draft.ram_min_mb
	_hard_cap_check.button_pressed = _draft.memory_hard_cap
	_cores_field.value = _draft.cpu_cores
	_quota_field.value = _draft.cpu_quota_pct
	_affinity_edit.text = _draft.cpu_affinity
	_nice_field.value = _draft.nice_level
	_preset_option.select(_draft.jvm_preset)
	_extra_args_edit.text = _draft.extra_jvm_args
	_server_args_edit.text = _draft.extra_server_args
	_port_spin.port = _draft.port
	_fill_java_options()
	_loading = false
	_refresh()


func _fill_java_options() -> void:
	if _draft == null:
		return
	_java_option.clear()
	var auto := int(_info.get("auto_java", 0))
	_java_option.add_item("Automatic (%s)" % (("Java %d" % auto) if auto > 0 else "no compatible Java found"))
	_java_option.set_item_metadata(0, "")
	var selected := 0
	for rt: Dictionary in _info.get("runtimes", []):
		_java_option.add_item(str(rt.name))
		var idx := _java_option.item_count - 1
		_java_option.set_item_metadata(idx, str(rt.exe))
		_java_option.set_item_tooltip(idx, str(rt.exe))
		if str(rt.exe) == _draft.java_path:
			selected = idx
	if _draft.java_path != "" and selected == 0:
		_java_option.add_item("Custom: " + _draft.java_path)
		selected = _java_option.item_count - 1
		_java_option.set_item_metadata(selected, _draft.java_path)
	if handle.can_manage_host():
		_java_option.add_separator()
		_java_option.add_item("Rescan for Java installations")
		_java_option.set_item_metadata(_java_option.item_count - 1, RESCAN_META)
	_java_option.select(selected)


func _on_java_selected(index: int) -> void:
	if str(_java_option.get_item_metadata(index)) == RESCAN_META:
		var h := handle
		var res: Dictionary = await h.source().call_host_op("java_rescan")
		if h != handle:
			return
		await _load_info(false)
		Notifier.info("Found %d Java runtime(s)." % res.get("runtimes", []).size())
		return
	_on_input_changed()


func _on_input_changed() -> void:
	if _loading or _draft == null:
		return
	_draft.ram_max_mb = int(_max_ram.value)
	_min_ram.max_value = _draft.ram_max_mb
	_draft.ram_min_mb = clampi(int(_min_ram.value), 256, _draft.ram_max_mb)
	_draft.memory_hard_cap = _hard_cap_check.button_pressed
	_draft.cpu_cores = int(_cores_field.value)
	_draft.cpu_quota_pct = int(_quota_field.value)
	_draft.cpu_affinity = _affinity_edit.text.strip_edges()
	_draft.nice_level = int(_nice_field.value)
	var meta = _java_option.get_item_metadata(_java_option.selected) if _java_option.selected >= 0 else ""
	_draft.java_path = "" if meta == null or str(meta) == RESCAN_META else str(meta)
	_draft.jvm_preset = clampi(_preset_option.selected, 0, ServerConfig.JvmPreset.size() - 1) as ServerConfig.JvmPreset
	_draft.extra_jvm_args = _extra_args_edit.text
	_draft.extra_server_args = _server_args_edit.text
	_draft.port = _port_spin.port
	_refresh()


func _refresh() -> void:
	if _draft == null:
		return
	_running_notice.visible = handle.is_process_alive()
	_refresh_memory()
	_refresh_java()
	_refresh_network()
	_refresh_save_state()


func _refresh_save_state() -> void:
	var errors := _validation_errors()
	var dirty := _is_dirty()
	_save_button.disabled = not dirty or not errors.is_empty() or _saving
	_revert_button.disabled = not dirty or _saving
	if not errors.is_empty() and dirty:
		_dirty_label.text = "Cannot save: " + errors[0]
		_dirty_label.add_theme_color_override("font_color", ERROR_COLOR)
	else:
		_dirty_label.text = "Unsaved changes" if dirty else ""
		_dirty_label.remove_theme_color_override("font_color")


func _refresh_memory() -> void:
	var host_mb := _host_mb()
	_hard_cap_check.text = "Hard memory limit"
	_hard_cap_check.tooltip_text = "Kill the server if it uses more than %s (heap + JVM overhead), enforced by the kernel." % Fmt.megabytes(_draft.hard_cap_mb())
	var total_all := _draft.ram_max_mb + int(_info.get("others_mb", 0))
	var host := "This computer" if not handle.is_remote() else handle.host_name()
	_host_ram_label.text = "%s has %s of RAM. All servers together are allocated %s (%s while running now)." % [
		host, Fmt.megabytes(host_mb), Fmt.megabytes(total_all), Fmt.megabytes(int(_info.get("running_mb", 0)))]
	var warning := ""
	if _draft.ram_max_mb > host_mb * 0.85:
		warning = "This heap leaves almost no memory for the operating system and other programs."
	elif total_all > host_mb:
		warning = "Running every server at once would need %s, more than the %s installed." % [Fmt.megabytes(total_all), Fmt.megabytes(host_mb)]
	_ram_warning.text = warning
	_ram_warning.visible = warning != ""

	var affinity_error := _affinity_error()
	if affinity_error != "":
		_affinity_status.text = affinity_error
		_affinity_status.add_theme_color_override("font_color", ERROR_COLOR)
	else:
		_affinity_status.text = "Runs on any core." if _draft.cpu_affinity == "" else "Pinned to CPU(s) %s." % _draft.cpu_affinity
		_affinity_status.remove_theme_color_override("font_color")


## The command line and Java check come from the server's computer.
func _refresh_java() -> void:
	_java_info.text = "Minecraft %s requires Java %d or newer." % [_draft.mc_version, _draft.java_min_version]
	_preview_serial += 1
	var serial := _preview_serial
	var h := handle
	var res: Dictionary = await h.call_op("launch_preview", {"config": _edited_values(_draft)})
	if serial != _preview_serial or h != handle or not res.ok:
		return
	_java_warning.text = str(res.java_warning)
	_java_warning.visible = _java_warning.text != ""
	_command_preview.text = str(res.command)


func _refresh_network() -> void:
	var port := _draft.port
	if not _port_spin.is_valid():
		_port_status.text = _port_spin.error_text()
		_port_status.add_theme_color_override("font_color", ERROR_COLOR)
		return
	var rcon_port := int(_info.get("rcon_port", handle.config.rcon_port))
	if rcon_port > 0:
		_rcon_label.text = "RCON port %d with a random password; used only by the manager on its own computer for status queries." % rcon_port
	else:
		_rcon_label.text = "An RCON port with a random password is assigned on first start; the manager uses it for status queries."
	if port != _checked_port:
		_check_port(port)
		return
	_show_port_status()


func _check_port(port: int) -> void:
	_port_serial += 1
	var serial := _port_serial
	var h := handle
	_port_status.text = "Checking port %d…" % port
	_port_status.remove_theme_color_override("font_color")
	var res: Dictionary = await h.call_op("port_check", {"port": port})
	if serial != _port_serial or h != handle:
		return
	_checked_port = port
	_port_check = res
	_show_port_status()
	_refresh_save_state()


func _show_port_status() -> void:
	var port := _checked_port
	var c := _port_check
	var color := OK_COLOR
	var text := "Port %d is available." % port
	if not c.get("ok", false):
		color = ERROR_COLOR
		text = str(c.get("error", "Port check failed."))
	elif str(c.owner) != "":
		color = ERROR_COLOR
		text = "Port %d is already assigned to \"%s\"." % [port, c.owner]
	elif c.rcon:
		color = ERROR_COLOR
		text = "Port %d is this server's RCON port." % port
	elif c.own:
		text = "Port %d is in use by this server." % port
	elif not c.free:
		color = WARNING_COLOR
		text = "Another program is listening on port %d right now; the server will fail to start while it is." % port
	_port_status.text = text
	_port_status.add_theme_color_override("font_color", color)


func _affinity_error() -> String:
	var text := _draft.cpu_affinity
	return "" if text == "" else ServerOps.affinity_error(text, _cores())


func _validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var affinity := _affinity_error()
	if affinity != "":
		errors.append(affinity)
	if not _port_spin.is_valid():
		errors.append(_port_spin.error_text().to_lower())
	elif _checked_port == _draft.port and _port_check.get("ok", false) and (str(_port_check.owner) != "" or _port_check.rcon):
		errors.append("the port conflicts with another server.")
	return errors


func _edited_values(cfg: ServerConfig) -> Dictionary:
	var d := cfg.to_dict()
	var out := {}
	for key in EDITED_FIELDS:
		out[key] = d.get(key)
	return out


func _is_dirty() -> bool:
	return _draft != null and handle != null and _edited_values(_draft) != _edited_values(handle.config)


func _save() -> void:
	if handle == null or _saving or not _validation_errors().is_empty():
		return
	var h := handle
	var changes := _edited_values(_draft)
	if not h.can_manage_host():
		for key in ServerOps.SYSTEM_FIELDS:
			changes.erase(key)
	_saving = true
	_refresh_save_state()
	var res: Dictionary = await h.call_op("config_save", {"changes": changes})
	_saving = false
	if h != handle:
		return
	if not res.ok:
		Notifier.error(str(res.error))
		_refresh_save_state()
		return
	var suffix := " Restart the server to apply." if h.is_process_alive() else ""
	Notifier.success("Saved resource settings for %s.%s" % [h.config.display_name, suffix])
	_load_draft()
