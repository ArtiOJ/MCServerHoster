class_name ResourcesTab
extends ServerTab
## Memory, CPU, Java and network settings of one server. Edits go to a draft
## copy of the config and are copied into the live config on save.

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
var _affinity_re := RegEx.create_from_string("^\\s*\\d+(\\s*-\\s*\\d+)?(\\s*,\\s*\\d+(\\s*-\\s*\\d+)?)*\\s*$")
var _host_mb := 0

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
	var backend := PlatformBackend.get_current()
	_host_mb = backend.host_memory_bytes() / 1048576
	var cores := OS.get_processor_count()
	_max_ram.max_value = maxi(1024, (_host_mb / 256) * 256)
	_cores_field.max_value = cores
	_quota_field.max_value = cores * 100

	var unsupported := PackedStringArray()
	if not backend.supports_cpu_quota():
		_quota_field.set_editable(false)
		unsupported.append("CPU quota (needs systemd-run and cgroups v2)")
	if not backend.supports_memory_cap():
		_hard_cap_check.disabled = true
		unsupported.append("hard memory limit (needs systemd-run and cgroups v2)")
	if not backend.supports_affinity():
		_affinity_edit.editable = false
		unsupported.append("core pinning (needs taskset)")
	if not backend.supports_priority():
		_nice_field.set_editable(false)
		unsupported.append("process priority (needs nice)")
	_support_label.text = "Not available on this system: " + ", ".join(unsupported) + "."
	_support_label.visible = not unsupported.is_empty()

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
	JavaRuntimes.runtimes_changed.connect(_on_runtimes_changed)
	_revert_button.pressed.connect(_load_draft)
	_save_button.pressed.connect(_save)


func _on_bound() -> void:
	watch(instance.config_changed, _on_config_changed)
	watch(instance.state_changed, _on_state_changed)
	_load_draft()


func _on_config_changed() -> void:
	if _draft == null or not _is_dirty():
		_load_draft()


func _on_state_changed(_state: ServerInstance.State) -> void:
	if _draft != null:
		_refresh()


func _on_runtimes_changed() -> void:
	if _draft != null:
		_fill_java_options()
		_refresh()


func _load_draft() -> void:
	if instance == null:
		return
	_draft = ServerConfig.from_dict(instance.config.to_dict(), instance.config.directory)
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
	_java_option.clear()
	var auto := JavaRuntimes.best_for(_draft.java_min_version)
	_java_option.add_item("Automatic (%s)" % (("Java %d" % auto.major) if auto != null else "no compatible Java found"))
	_java_option.set_item_metadata(0, "")
	var selected := 0
	for rt in JavaRuntimes.runtimes:
		_java_option.add_item(rt.display_name())
		var idx := _java_option.item_count - 1
		_java_option.set_item_metadata(idx, rt.executable)
		_java_option.set_item_tooltip(idx, rt.executable)
		if rt.executable == _draft.java_path:
			selected = idx
	if _draft.java_path != "" and selected == 0:
		_java_option.add_item("Custom: " + _draft.java_path)
		selected = _java_option.item_count - 1
		_java_option.set_item_metadata(selected, _draft.java_path)
	_java_option.add_separator()
	_java_option.add_item("Rescan for Java installations")
	_java_option.set_item_metadata(_java_option.item_count - 1, RESCAN_META)
	_java_option.select(selected)


func _on_java_selected(index: int) -> void:
	if str(_java_option.get_item_metadata(index)) == RESCAN_META:
		JavaRuntimes.rescan()
		_fill_java_options()
		Notifier.info("Found %d Java runtime(s)." % JavaRuntimes.runtimes.size())
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
	_running_notice.visible = instance.is_process_alive()
	_refresh_memory()
	_refresh_java()
	_refresh_network()
	var errors := _validation_errors()
	var dirty := _is_dirty()
	_save_button.disabled = not dirty or not errors.is_empty()
	_revert_button.disabled = not dirty
	if not errors.is_empty() and dirty:
		_dirty_label.text = "Cannot save: " + errors[0]
		_dirty_label.add_theme_color_override("font_color", ERROR_COLOR)
	else:
		_dirty_label.text = "Unsaved changes" if dirty else ""
		_dirty_label.remove_theme_color_override("font_color")


func _refresh_memory() -> void:
	_hard_cap_check.text = "Hard memory limit"
	_hard_cap_check.tooltip_text = "Kill the server if it uses more than %s (heap + JVM overhead), enforced by the kernel." % Fmt.megabytes(_draft.hard_cap_mb())
	var total_all := _draft.ram_max_mb
	for inst in ServerManager.get_instances():
		if inst != instance:
			total_all += inst.config.ram_max_mb
	_host_ram_label.text = "This computer has %s of RAM. All servers together are allocated %s (%s while running now)." % [
		Fmt.megabytes(_host_mb), Fmt.megabytes(total_all), Fmt.megabytes(ServerManager.allocated_ram_mb())]
	var warning := ""
	if _draft.ram_max_mb > _host_mb * 0.85:
		warning = "This heap leaves almost no memory for the operating system and other programs."
	elif total_all > _host_mb:
		warning = "Running every server at once would need %s, more than the %s installed." % [Fmt.megabytes(total_all), Fmt.megabytes(_host_mb)]
	_ram_warning.text = warning
	_ram_warning.visible = warning != ""

	var affinity_error := _affinity_error()
	if affinity_error != "":
		_affinity_status.text = affinity_error
		_affinity_status.add_theme_color_override("font_color", ERROR_COLOR)
	else:
		_affinity_status.text = "Runs on any core." if _draft.cpu_affinity == "" else "Pinned to CPU(s) %s." % _draft.cpu_affinity
		_affinity_status.remove_theme_color_override("font_color")


func _refresh_java() -> void:
	_java_info.text = "Minecraft %s requires Java %d or newer." % [_draft.mc_version, _draft.java_min_version]
	var rt := JavaRuntimes.resolve_for(_draft)
	var warning := ""
	if rt == null:
		warning = "No suitable Java runtime found. Install Java %d+ or pick an executable in Settings." % _draft.java_min_version
	elif rt.major < _draft.java_min_version:
		warning = "Java %d is too old for this server; it needs Java %d or newer." % [rt.major, _draft.java_min_version]
	_java_warning.text = warning
	_java_warning.visible = warning != ""

	var exe := rt.executable if rt != null else "java"
	var cmd := PlatformBackend.get_current().build_launch_command(_draft, exe)
	var parts := PackedStringArray([Fmt.shell_quote(str(cmd.path))])
	for arg in cmd.args:
		parts.append(Fmt.shell_quote(arg))
	_command_preview.text = " ".join(parts)


func _refresh_network() -> void:
	var port := _draft.port
	var color := OK_COLOR
	var text := "Port %d is available." % port
	if not _port_spin.is_valid():
		_port_status.text = _port_spin.error_text()
		_port_status.add_theme_color_override("font_color", ERROR_COLOR)
		return
	var owner := ServerManager.port_owner(port, instance.config.id)
	if owner != null:
		color = ERROR_COLOR
		text = "Port %d is already assigned to \"%s\"." % [port, owner.config.display_name]
	elif port == instance.config.rcon_port:
		color = ERROR_COLOR
		text = "Port %d is this server's RCON port." % port
	elif instance.is_process_alive() and port == instance.config.port:
		text = "Port %d is in use by this server." % port
	elif not PlatformBackend.is_port_free(port):
		color = WARNING_COLOR
		text = "Another program is listening on port %d right now; the server will fail to start while it is." % port
	_port_status.text = text
	_port_status.add_theme_color_override("font_color", color)
	if instance.config.rcon_port > 0:
		_rcon_label.text = "RCON port %d with a random password; used only by the manager on this computer for status queries." % instance.config.rcon_port
	else:
		_rcon_label.text = "An RCON port with a random password is assigned on first start; the manager uses it for status queries."


func _affinity_error() -> String:
	var text := _draft.cpu_affinity
	if text == "":
		return ""
	if _affinity_re.search(text) == null:
		return "Use a CPU list like \"0-3\" or \"0,2,4\"."
	var cores := OS.get_processor_count()
	for part in text.replace(" ", "").split(","):
		var bounds := part.split("-")
		for b in bounds:
			if b.to_int() >= cores:
				return "CPU %d does not exist (this computer has CPUs 0-%d)." % [b.to_int(), cores - 1]
		if bounds.size() == 2 and bounds[0].to_int() > bounds[1].to_int():
			return "Range \"%s\" is reversed." % part
	return ""


func _validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var affinity := _affinity_error()
	if affinity != "":
		errors.append(affinity)
	if not _port_spin.is_valid():
		errors.append(_port_spin.error_text().to_lower())
	elif ServerManager.port_owner(_draft.port, instance.config.id) != null or _draft.port == instance.config.rcon_port:
		errors.append("the port conflicts with another server.")
	return errors


func _edited_values(cfg: ServerConfig) -> Dictionary:
	var d := cfg.to_dict()
	var out := {}
	for key in EDITED_FIELDS:
		out[key] = d.get(key)
	return out


func _is_dirty() -> bool:
	return _draft != null and instance != null and _edited_values(_draft) != _edited_values(instance.config)


func _save() -> void:
	if instance == null or not _validation_errors().is_empty():
		return
	var c := instance.config
	c.ram_max_mb = _draft.ram_max_mb
	c.ram_min_mb = _draft.ram_min_mb
	c.memory_hard_cap = _draft.memory_hard_cap
	c.cpu_cores = _draft.cpu_cores
	c.cpu_quota_pct = _draft.cpu_quota_pct
	c.cpu_affinity = _draft.cpu_affinity
	c.nice_level = _draft.nice_level
	c.java_path = _draft.java_path
	c.jvm_preset = _draft.jvm_preset
	c.extra_jvm_args = _draft.extra_jvm_args
	c.extra_server_args = _draft.extra_server_args
	instance.save_config()
	# Through set_port so server.properties and start-on-connect follow the new port.
	var port_error := instance.set_port(_draft.port)
	if port_error != "":
		Notifier.error(port_error)
	var suffix := " Restart the server to apply." if instance.is_process_alive() else ""
	Notifier.success("Saved resource settings for %s.%s" % [c.display_name, suffix])
	_load_draft()
