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
@onready var _port_spin: PortField = %PortSpin
@onready var _apply_port_button: Button = %ApplyPortButton
@onready var _port_status: Label = %PortStatus
@onready var _firewall_notice: PanelContainer = %FirewallNotice
@onready var _firewall_notice_label: Label = %FirewallNoticeLabel
@onready var _allow_top_button: Button = %AllowFirewallTopButton
@onready var _allow_button: Button = %AllowFirewallButton
@onready var _open_router_button: Button = %OpenRouterButton
@onready var _router_value: Label = %RouterValue
@onready var _external_value: Label = %ExternalValue
@onready var _internal_ip_value: Label = %InternalIpValue
@onready var _internal_port_value: Label = %InternalPortValue
@onready var _forward_status: Label = %ForwardStatus
@onready var _dhcp_notice: PanelContainer = %DhcpNotice
@onready var _dhcp_label: Label = %DhcpLabel
@onready var _rcon_label: Label = %RconLabel
@onready var _rcon_warning: PanelContainer = %RconWarning
@onready var _rcon_warning_label: Label = %RconWarningLabel


var _allowing := false


func _ready() -> void:
	_port_spin.port_changed.connect(func(_p: int, _ok: bool) -> void: _update_port_status())
	_apply_port_button.pressed.connect(_apply_port)
	_allow_top_button.pressed.connect(_allow_firewall)
	_allow_button.pressed.connect(_allow_firewall)
	_open_router_button.pressed.connect(func() -> void:
		var gw := str(PlatformBackend.get_current().default_route().get("gateway", ""))
		if gw != "":
			OS.shell_open("http://%s/" % gw))
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
	hints.append("Friends on your Wi-Fi use the home network address; everyone else uses the internet address, which only works once your router forwards the port (below).")
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

	_refresh_forwarding(cfg)
	if not _port_spin.has_focus():
		_port_spin.set_port(cfg.port)
	_update_port_status()

	var nat := NetworkService.nat_diagnosis()
	_nat_label.text = nat.text
	var fw := NetworkService.firewall_port_status(cfg.port)
	_firewall_label.remove_theme_color_override("font_color")
	if not fw.active:
		_firewall_label.text = "No active firewall (ufw or firewalld) was detected on this computer."
	elif fw.allowed == "yes":
		_firewall_label.text = "✓ " + (fw.detail if fw.detail != "" else "%s allows port %d." % [fw.name, cfg.port])
		_firewall_label.add_theme_color_override("font_color", Color("3fb97f"))
	elif fw.allowed == "unknown":
		_firewall_label.text = "%s is active; whether it allows port %d couldn't be checked. If players can't connect, allow it:" % [fw.name, cfg.port]
	else:
		var extra := " Players on the internet are blocked too." if fw.allowed == "lan" else ""
		_firewall_label.text = "✕ " + fw.detail + extra + " Run this once in a terminal (needs your password):"
		_firewall_label.add_theme_color_override("font_color", Color("f2b84b") if fw.allowed == "lan" else Color("e05555"))
	_firewall_command.text = NetworkService.firewall_command(fw.name, cfg.port)
	_firewall_row.visible = fw.active and fw.allowed != "yes"
	_firewall_notice.visible = fw.active and fw.allowed != "yes"
	_firewall_notice_label.text = "The %s firewall on this computer blocks port %d, so nobody else can join%s." % [
		fw.name, cfg.port, " from the internet" if fw.allowed == "lan" else ", not even on your Wi-Fi"]
	for b: Button in [_allow_top_button, _allow_button]:
		b.disabled = _allowing
		b.text = "Waiting for password…" if _allowing else "Allow in firewall"

	var rcon_port := instance.get_properties().get_int("rcon.port", cfg.rcon_port)
	var bind := instance.get_properties().get_value("server-ip", "")
	_rcon_label.text = ("RCON (port %d) lets Server Manager send commands without cluttering the console. %s It is protected by a random password. Never forward the RCON port on your router — only the game port (%d) needs to be reachable." % [
		rcon_port,
		"It listens on all network interfaces because server-ip is empty, so devices on your home network can reach it." if bind == "" else "It listens on %s." % bind,
		cfg.port])
	var forwarded_rcon := NetworkService.mappings.has(rcon_port)
	_rcon_warning.visible = forwarded_rcon
	_rcon_warning_label.text = "Port %d (RCON) is currently forwarded on your router. Remove that forward." % rcon_port


func _update_port_status() -> void:
	if instance == null:
		return
	var port := _port_spin.port
	if not _port_spin.is_valid():
		_port_status.text = "✕ " + _port_spin.error_text()
		_port_status.add_theme_color_override("font_color", Color("e05555"))
		_apply_port_button.disabled = true
		return
	var changed := port != instance.config.port
	var clash := ServerManager.port_owner(port, instance.config.id)
	_port_status.remove_theme_color_override("font_color")
	if not changed:
		_port_status.text = "Players connect on this port." if not instance.is_process_alive() else "In use by the running server."
		_apply_port_button.disabled = true
		return
	if clash != null:
		_port_status.text = "✕ Used by %s" % clash.config.display_name
		_port_status.add_theme_color_override("font_color", Color("e05555"))
		_apply_port_button.disabled = true
		return
	if not PlatformBackend.is_port_free(port):
		_port_status.text = "⚠ Another program is listening on %d" % port
		_port_status.add_theme_color_override("font_color", Color("f2b84b"))
	else:
		_port_status.text = "Restart needed to apply." if instance.is_process_alive() else "Available."
	_apply_port_button.disabled = false


func _apply_port() -> void:
	var err := instance.set_port(_port_spin.port)
	if err != "":
		Notifier.error(err)
		return
	Notifier.success("%s now uses port %d.%s" % [instance.config.display_name, instance.config.port,
			" Restart the server to apply it." if instance.is_process_alive() else ""])
	_refresh()


func _allow_firewall() -> void:
	if _allowing or instance == null:
		return
	_allowing = true
	_refresh()
	var result: Dictionary = await NetworkService.allow_in_firewall(instance.config.port)
	_allowing = false
	if result.ok:
		Notifier.success(result.message)
	else:
		Notifier.error(result.message)
	_refresh()


func _refresh_forwarding(cfg: ServerConfig) -> void:
	var route := PlatformBackend.get_current().default_route()
	var gw := str(route.get("gateway", ""))
	var lan := ServerInstance._lan_ip()
	_router_value.text = gw if gw != "" else "Unknown"
	_open_router_button.disabled = gw == ""
	_external_value.text = str(cfg.port)
	_internal_ip_value.text = lan
	_internal_port_value.text = str(cfg.port)
	if cfg.upnp_enabled and NetworkService.is_forwarded(cfg.id):
		_forward_status.text = "UPnP has set this forward up automatically. You only need to do it by hand if UPnP is off or unsupported."
	elif NetworkService.upnp_state == NetworkService.UpnpState.UNAVAILABLE:
		_forward_status.text = "Your router doesn't support automatic forwarding (UPnP), so add this rule by hand in its admin page (usually under Port Forwarding, Virtual Server or NAT), then use “Test from the internet”."
	else:
		_forward_status.text = "Add this rule in your router's admin page (usually under Port Forwarding, Virtual Server or NAT), or turn on UPnP forwarding below if your router supports it."
	_dhcp_notice.visible = bool(route.get("dynamic", false))
	_dhcp_label.text = "This computer's address (%s) was assigned automatically by your router (DHCP) and can change, which would break the forward. In the router, reserve this address for this computer (often called DHCP reservation or static lease)." % lan


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
