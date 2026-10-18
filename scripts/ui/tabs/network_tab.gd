class_name NetworkTab
extends ServerTab
## Addresses, UPnP forwarding, the "test from the internet" check and NAT/firewall/RCON
## guidance for one server. Third-party lookups only run when this tab is shown or a
## button is pressed (see NetworkService).

var _testing := false
var _last_result := {}

@onready var _refresh_button: Button = %RefreshButton
@onready var _lan_value: Label = %LanValue
@onready var _copy_lan_button: Button = %CopyLanButton
@onready var _public_value: Label = %PublicValue
@onready var _copy_public_button: Button = %CopyPublicButton
@onready var _address_hint: Label = %AddressHint
@onready var _upnp_check: CheckButton = %UpnpCheck
@onready var _retry_upnp_button: Button = %RetryUpnpButton
@onready var _upnp_status: Label = %UpnpStatus
@onready var _test_button: Button = %TestButton
@onready var _test_status: Label = %TestStatus
@onready var _test_reasons: Label = %TestReasons
@onready var _wake_ping_notice: PanelContainer = %WakePingNotice
@onready var _nat_label: Label = %NatLabel
@onready var _firewall_label: Label = %FirewallLabel
@onready var _firewall_row: HBoxContainer = %FirewallRow
@onready var _firewall_command: LineEdit = %FirewallCommand
@onready var _copy_firewall_button: Button = %CopyFirewallButton
@onready var _rcon_label: Label = %RconLabel
@onready var _rcon_warning: PanelContainer = %RconWarning
@onready var _rcon_warning_label: Label = %RconWarningLabel


func _ready() -> void:
	_refresh_button.pressed.connect(NetworkService.refresh_public_ip)
	_copy_lan_button.pressed.connect(func() -> void: _copy(instance.connect_address()))
	_copy_public_button.pressed.connect(func() -> void: _copy(NetworkService.public_address(instance.config.port)))
	_copy_firewall_button.pressed.connect(func() -> void: _copy(_firewall_command.text))
	_upnp_check.toggled.connect(_on_upnp_toggled)
	_retry_upnp_button.pressed.connect(func() -> void: NetworkService.retry(instance.config.id))
	_test_button.pressed.connect(_run_test)
	visibility_changed.connect(_on_visibility_changed)


func _on_bound() -> void:
	watch(instance.state_changed, _refresh.unbind(1))
	watch(instance.config_changed, _refresh)
	watch(NetworkService.status_changed, _refresh)
	_last_result = {}
	_test_status.text = ""
	_test_reasons.visible = false
	_refresh()
	_on_visibility_changed()


## The tab only triggers router discovery and public-IP lookups while the user looks at it.
func _on_visibility_changed() -> void:
	if not is_visible_in_tree() or instance == null:
		return
	NetworkService.ensure_discovered()
	if NetworkService.public_ip == "" and NetworkService.public_ip_error == "":
		NetworkService.refresh_public_ip()


func _refresh() -> void:
	if instance == null or not is_node_ready():
		return
	var cfg := instance.config
	_lan_value.text = instance.connect_address()
	var public := NetworkService.public_address(cfg.port)
	if NetworkService.looking_up_public_ip:
		_public_value.text = "Looking up…"
	elif public != "":
		_public_value.text = public
	else:
		_public_value.text = "Unknown" + (" — " + NetworkService.public_ip_error if NetworkService.public_ip_error != "" else "")
	_copy_public_button.disabled = public == ""
	var hints := PackedStringArray()
	if cfg.port == 25565:
		hints.append("Port 25565 is Minecraft's default, so players can leave it out.")
	else:
		hints.append("Players must include the port (:%d)." % cfg.port)
	if NetworkService.public_ip_source != "":
		hints.append("Public address from %s." % NetworkService.public_ip_source)
	_address_hint.text = " ".join(hints)

	_upnp_check.set_pressed_no_signal(cfg.upnp_enabled)
	_upnp_status.text = _upnp_text()
	_retry_upnp_button.visible = cfg.upnp_enabled and (NetworkService.upnp_state == NetworkService.UpnpState.UNAVAILABLE or NetworkService.mapping_errors.has(cfg.id))
	_wake_ping_notice.visible = cfg.wake_on_connect and cfg.wake_on_ping
	_test_button.disabled = _testing

	var nat := NetworkService.nat_diagnosis()
	_nat_label.text = nat.text
	var fw := NetworkService.firewall_info(cfg.port)
	if fw.active:
		_firewall_label.text = "%s is active on this computer. If players can't connect, allow the port:" % fw.name
		_firewall_command.text = fw.command
	else:
		_firewall_label.text = "No active firewall (ufw or firewalld) was detected on this computer."
	_firewall_row.visible = fw.active

	var rcon_port := instance.get_properties().get_int("rcon.port", cfg.rcon_port)
	var bind := instance.get_properties().get_value("server-ip", "")
	_rcon_label.text = ("RCON (port %d) lets Server Manager send commands without cluttering the console. %s It is protected by a random password. Never forward the RCON port on your router — only the game port (%d) needs to be reachable." % [
		rcon_port,
		"It listens on all network interfaces because server-ip is empty, so devices on your home network can reach it." if bind == "" else "It listens on %s." % bind,
		cfg.port])
	var forwarded_rcon := NetworkService.mappings.has(rcon_port)
	_rcon_warning.visible = forwarded_rcon
	_rcon_warning_label.text = "Port %d (RCON) is currently forwarded on your router. Remove that forward." % rcon_port


func _upnp_text() -> String:
	var cfg := instance.config
	match NetworkService.upnp_state:
		NetworkService.UpnpState.DISCOVERING:
			return "Looking for a UPnP router…"
		NetworkService.UpnpState.UNAVAILABLE:
			return NetworkService.upnp_error + (" Forward TCP port %d to %s manually in your router's settings." % [cfg.port, ServerInstance._lan_ip()])
		NetworkService.UpnpState.UNKNOWN:
			return "Your router has not been checked yet." if not cfg.upnp_enabled else "Waiting for the router check…"
	var router := "Router found (internet address %s). " % NetworkService.upnp_external_ip if NetworkService.upnp_external_ip != "" else "Router found. "
	if not cfg.upnp_enabled:
		return router + "Turn this on to forward port %d automatically." % cfg.port
	if NetworkService.mapping_errors.has(cfg.id):
		return router + NetworkService.mapping_errors[cfg.id]
	if NetworkService.is_forwarded(cfg.id):
		return router + "Port %d is forwarded to this computer." % cfg.port
	return router + "Port %d will be forwarded while the server is running or asleep." % cfg.port


func _on_upnp_toggled(on: bool) -> void:
	instance.config.upnp_enabled = on
	if on:
		NetworkService.retry(instance.config.id)
	instance.save_config()


func _run_test() -> void:
	if _testing:
		return
	_testing = true
	_test_status.text = "Testing from the internet…"
	_test_reasons.visible = false
	_refresh()
	var inst := instance
	var result: Dictionary = await NetworkService.test_reachability(inst)
	_testing = false
	if inst != instance:
		return
	_last_result = result
	if not result.get("ok", false):
		_test_status.text = "✕ The test could not run: %s" % result.get("error", "unknown error")
		_test_status.add_theme_color_override("font_color", Color("e05555"))
		_test_reasons.visible = false
	elif result.online:
		var details: String = result.version if result.version != "" else "Minecraft server"
		_test_status.text = "✓ Reachable from the internet at %s (%s%s)." % [NetworkService.public_address(inst.config.port), details,
				", cached result" if result.cache_hit else ""]
		_test_status.add_theme_color_override("font_color", Color("3fb97f"))
		_test_reasons.visible = false
	else:
		_test_status.text = "✕ Not reachable from the internet at %s." % NetworkService.public_address(inst.config.port)
		_test_status.add_theme_color_override("font_color", Color("e05555"))
		var reasons := NetworkService.explain_failure(inst, result)
		_test_reasons.text = "Likely causes:\n• " + "\n• ".join(reasons) if not reasons.is_empty() else ""
		_test_reasons.visible = not reasons.is_empty()
	_refresh()


func _copy(text: String) -> void:
	if text == "":
		return
	DisplayServer.clipboard_set(text)
	Notifier.info("Copied %s to the clipboard." % text)
