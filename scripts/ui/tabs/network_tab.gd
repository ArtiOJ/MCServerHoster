class_name NetworkTab
extends ServerTab
## Addresses, UPnP forwarding, the "test from the internet" check and NAT/firewall/RCON
## guidance for one server. Everything is reported by the server's own computer
## (ServerOps.network_info). Third-party lookups only run when this tab is shown or a
## button is pressed (see NetworkService). Router and firewall changes reach beyond the
## server, so for a remote server only its system admins can make them.

const RULE_ROW_SCENE := preload("res://scenes/components/firewall_rule_row.tscn")

var _testing := false
var _removing := false
var _allowing := false
## The last network_info result.
var _info := {}
var _serial := 0
## Rule waiting for confirmation in the remove dialog.
var _pending_rule := {}
## Signature of the rows currently in the old-rules list (avoids rebuilding on every refresh).
var _rules_key := ""
## Tooltips from the scene, restored when a server with full access is shown.
var _default_tips := {}

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
@onready var _dhcp_reserved_button: Button = %DhcpReservedButton
@onready var _port_move_notice: PanelContainer = %PortMoveNotice
@onready var _port_move_label: Label = %PortMoveLabel
@onready var _allow_new_port_button: Button = %AllowNewPortButton
@onready var _remove_old_rule_button: Button = %RemoveOldRuleButton
@onready var _old_rules_box: VBoxContainer = %OldRulesBox
@onready var _old_rules_list: VBoxContainer = %OldRulesList
@onready var _remove_rule_confirm: ConfirmationDialog = %RemoveRuleConfirm
@onready var _rcon_label: Label = %RconLabel
@onready var _rcon_warning: PanelContainer = %RconWarning
@onready var _rcon_warning_label: Label = %RconWarningLabel


func _ready() -> void:
	_dhcp_reserved_button.pressed.connect(func() -> void:
		await handle.source().call_host_op("dhcp_reserved")
		_reload())
	_port_spin.port_changed.connect(func(_p: int, _ok: bool) -> void: _update_port_status())
	_apply_port_button.pressed.connect(_apply_port)
	_allow_top_button.pressed.connect(_allow_firewall)
	_allow_button.pressed.connect(_allow_firewall)
	_allow_new_port_button.pressed.connect(_allow_firewall)
	_remove_old_rule_button.pressed.connect(func() -> void:
		var rule: Dictionary = _info.get("moved_rule", {})
		if not rule.is_empty():
			_request_remove(rule))
	_remove_rule_confirm.confirmed.connect(func() -> void: _remove_rule(_pending_rule))
	_open_router_button.pressed.connect(func() -> void:
		var gw := str(_info.get("gateway", ""))
		if gw != "" and handle != null and not handle.is_remote():
			OS.shell_open("http://%s/" % gw))
	_refresh_button.pressed.connect(func() -> void:
		await handle.call_op("network_refresh")
		_reload())
	_copy_lan_button.pressed.connect(func() -> void: _copy(str(_info.get("lan_address", ""))))
	_copy_public_button.pressed.connect(func() -> void: _copy(str(_info.get("public_address", ""))))
	_copy_firewall_button.pressed.connect(func() -> void: _copy(_firewall_command.text))
	_upnp_check.toggled.connect(_on_upnp_toggled)
	_retry_upnp_button.pressed.connect(func() -> void:
		await handle.call_op("upnp_retry")
		_reload())
	_test_button.pressed.connect(_run_test)
	visibility_changed.connect(_on_visibility_changed)
	NetworkService.status_changed.connect(func() -> void:
		if handle != null and not handle.is_remote():
			_reload())


func _on_bound() -> void:
	_info = {}
	_rules_key = ""
	watch(handle.state_changed, _reload.unbind(1))
	watch(handle.config_changed, _reload)
	watch(handle.data_changed, func(area: StringName) -> void:
		if area == &"network":
			_reload())
	_test_status.text = ""
	_test_reasons.visible = false
	_open_router_button.visible = not handle.is_remote()
	var why := "" if handle.can_manage_host() else "Only a system admin of %s can change its router or firewall." % handle.host_name()
	for c: Control in [_upnp_check, _retry_upnp_button, _allow_top_button, _allow_button, _allow_new_port_button, _remove_old_rule_button, _dhcp_reserved_button]:
		if not _default_tips.has(c):
			_default_tips[c] = c.tooltip_text
		c.tooltip_text = why if why != "" else _default_tips[c]
	_reload()
	_on_visibility_changed()


## The tab only triggers router discovery and public-IP lookups while the user looks at it.
func _on_visibility_changed() -> void:
	if not is_visible_in_tree() or handle == null:
		return
	await handle.call_op("network_refresh")
	_reload()


## Fetches the network picture from the server's computer and shows it.
func _reload() -> void:
	if handle == null or not is_node_ready():
		return
	_serial += 1
	var serial := _serial
	var h := handle
	var res: Dictionary = await h.call_op("network_info")
	if serial != _serial or h != handle or not res.ok:
		return
	_info = res
	_refresh()


func _refresh() -> void:
	if handle == null or _info.is_empty():
		return
	var i := _info
	var admin := handle.can_manage_host()
	var host := "this computer" if not handle.is_remote() else handle.host_name()
	var port := int(i.port)
	_lan_value.text = str(i.lan_address)
	var public := str(i.public_address)
	if i.looking_up:
		_public_value.text = "Looking up…"
	elif public != "":
		_public_value.text = public
	else:
		_public_value.text = "Unknown" + (" — " + str(i.public_ip_error) if str(i.public_ip_error) != "" else "")
	_copy_public_button.disabled = public == ""
	var hints := PackedStringArray()
	hints.append("Friends on the same Wi-Fi use the home network address; everyone else uses the internet address, which only works once the router forwards the port (below).")
	if port == 25565:
		hints.append("Port 25565 is Minecraft's default, so players can leave it out.")
	else:
		hints.append("Players must include the port (:%d)." % port)
	if str(i.public_ip_source) != "":
		hints.append("Public address from %s." % i.public_ip_source)
	_address_hint.text = " ".join(hints)

	_upnp_check.set_pressed_no_signal(bool(i.upnp_enabled))
	_upnp_check.disabled = not admin
	_upnp_status.text = str(i.upnp_text)
	_retry_upnp_button.visible = bool(i.upnp_retry) and admin
	_wake_ping_notice.visible = bool(i.wake_ping)
	_test_button.disabled = _testing

	_refresh_forwarding(i, port, admin)
	if not _port_spin.has_focus():
		_port_spin.set_port(port)
	_update_port_status()

	_nat_label.text = str(i.nat)
	var fw: Dictionary = i.firewall
	_firewall_label.remove_theme_color_override("font_color")
	if not fw.active:
		_firewall_label.text = "No active firewall (ufw or firewalld) was detected on %s." % host
	elif fw.allowed == "yes":
		_firewall_label.text = "✓ " + (str(fw.detail) if str(fw.detail) != "" else "%s allows port %d." % [fw.name, port])
		_firewall_label.add_theme_color_override("font_color", Color("3fb97f"))
	elif fw.allowed == "unknown":
		_firewall_label.text = "%s is active; whether it allows port %d couldn't be checked. If players can't connect, allow it:" % [fw.name, port]
	else:
		var extra := " Players on the internet are blocked too." if fw.allowed == "lan" else ""
		var how := "in PowerShell as administrator" if fw.name == NetworkService.WINDOWS_FIREWALL else "in a terminal (needs the password)"
		_firewall_label.text = "✕ " + str(fw.detail) + extra + " Or run this once on %s %s:" % [host, how]
		_firewall_label.add_theme_color_override("font_color", Color("f2b84b") if fw.allowed == "lan" else Color("e05555"))
	_firewall_command.text = str(i.firewall_command)
	_firewall_row.visible = fw.active and fw.allowed != "yes"
	var blocked: bool = fw.active and fw.allowed != "yes"
	var show_move := _refresh_port_move(i, port, blocked, admin)
	_firewall_notice.visible = blocked and not show_move
	_refresh_old_rules(i.stale_rules if fw.active else [])
	_firewall_notice_label.text = "The %s firewall on %s blocks port %d, so nobody else can join%s." % [
		fw.name, host, port, " from the internet" if fw.allowed == "lan" else ", not even on the same Wi-Fi"]
	for b: Button in [_allow_top_button, _allow_button]:
		b.disabled = _allowing or not admin
		b.text = ("Waiting for password…" if not handle.is_remote() else "Waiting for the password on %s…" % host) if _allowing else "Allow in firewall"
	_allow_new_port_button.disabled = _allowing or _removing or not admin
	_remove_old_rule_button.disabled = _allowing or _removing or not admin

	var rcon_port := int(i.rcon_port)
	var bind := str(i.server_ip)
	_rcon_label.text = ("RCON (port %d) lets Server Manager send commands without cluttering the console. %s It is protected by a random password. Never forward the RCON port on the router — only the game port (%d) needs to be reachable." % [
		rcon_port,
		"It listens on all network interfaces because server-ip is empty, so devices on the same network can reach it." if bind == "" else "It listens on %s." % bind,
		port])
	_rcon_warning.visible = bool(i.rcon_forwarded)
	_rcon_warning_label.text = "Port %d (RCON) is currently forwarded on the router. Remove that forward." % rcon_port


## Shows what the firewall still needs after a port change. Returns whether the notice is shown.
func _refresh_port_move(i: Dictionary, port: int, new_blocked: bool, admin: bool) -> bool:
	var moved := int(i.moved_from)
	var old_rule: Dictionary = i.moved_rule
	if moved <= 0 or moved == port or (old_rule.is_empty() and not new_blocked):
		_port_move_notice.visible = false
		return false
	var parts := PackedStringArray(["Port changed from %d to %d." % [moved, port]])
	if new_blocked:
		parts.append("The firewall blocks the new port.")
	if not old_rule.is_empty():
		parts.append("The old port is still open in the firewall.")
	_port_move_label.text = " ".join(parts)
	_allow_new_port_button.visible = new_blocked and admin
	_remove_old_rule_button.visible = not old_rule.is_empty() and admin
	_port_move_notice.visible = true
	return true


func _refresh_old_rules(stale: Array) -> void:
	var key := "%s|%s" % [_removing or _allowing, ",".join(stale.map(func(r: Dictionary) -> String: return "%d/%s/%s" % [int(r.port), r.origin, r.source]))]
	if key == _rules_key:
		return
	_rules_key = key
	for child in _old_rules_list.get_children():
		child.queue_free()
	for r: Dictionary in stale:
		r.port = int(r.port)
		var row: FirewallRuleRow = RULE_ROW_SCENE.instantiate()
		_old_rules_list.add_child(row)
		row.setup(r, _removing or _allowing)
		row.remove_requested.connect(_request_remove)
	_old_rules_box.visible = not stale.is_empty()


func _request_remove(rule: Dictionary) -> void:
	if rule.origin == "app":
		_remove_rule(rule)
		return
	_pending_rule = rule
	_remove_rule_confirm.dialog_text = ("Server Manager didn't create the firewall rule for port %d; someone or another program added it. "
		+ "No server uses that port now. Remove it anyway? If something else on the computer needs port %d, it will be blocked.") % [int(rule.port), int(rule.port)]
	_remove_rule_confirm.popup_centered()


func _remove_rule(rule: Dictionary) -> void:
	if _removing or rule.is_empty():
		return
	_removing = true
	_rules_key = ""
	_refresh()
	var result: Dictionary = await handle.source().call_host_op("firewall_remove", {"rule": rule})
	_removing = false
	if result.ok:
		Notifier.success(str(result.message))
	else:
		Notifier.error(str(result.error))
	_rules_key = ""
	_reload()


func _update_port_status() -> void:
	if handle == null or _info.is_empty():
		return
	var port := _port_spin.port
	if not _port_spin.is_valid():
		_port_status.text = "✕ " + _port_spin.error_text()
		_port_status.add_theme_color_override("font_color", Color("e05555"))
		_apply_port_button.disabled = true
		return
	_port_status.remove_theme_color_override("font_color")
	if port == int(_info.port):
		_port_status.text = "Players connect on this port." if not handle.is_process_alive() else "In use by the running server."
		_apply_port_button.disabled = true
		return
	_apply_port_button.disabled = true
	_port_status.text = "Checking…"
	var h := handle
	var res: Dictionary = await h.call_op("port_check", {"port": port})
	if h != handle or port != _port_spin.port:
		return
	if not res.ok or str(res.owner) != "" or res.rcon:
		_port_status.text = "✕ Used by %s" % res.owner if str(res.get("owner", "")) != "" else "✕ " + str(res.get("error", "This is the server's RCON port."))
		_port_status.add_theme_color_override("font_color", Color("e05555"))
		return
	if not res.free:
		_port_status.text = "⚠ Another program is listening on %d" % port
		_port_status.add_theme_color_override("font_color", Color("f2b84b"))
	else:
		_port_status.text = "Restart needed to apply." if handle.is_process_alive() else "Available."
	_apply_port_button.disabled = false


func _apply_port() -> void:
	var h := handle
	var res: Dictionary = await h.call_op("port_set", {"port": _port_spin.port})
	if not res.ok:
		Notifier.error(str(res.error))
		return
	Notifier.success("%s now uses port %d.%s" % [h.config.display_name, _port_spin.port,
			" Restart the server to apply it." if res.restart_needed else ""])
	_reload()


func _allow_firewall() -> void:
	if _allowing or handle == null:
		return
	_allowing = true
	_refresh()
	var result: Dictionary = await handle.call_op("firewall_allow")
	_allowing = false
	if result.ok:
		Notifier.success(str(result.message))
	else:
		Notifier.error(str(result.error))
	_reload()


func _refresh_forwarding(i: Dictionary, port: int, admin: bool) -> void:
	var gw := str(i.gateway)
	var lan := str(i.lan_ip)
	_router_value.text = gw if gw != "" else "Unknown"
	_open_router_button.disabled = gw == ""
	_external_value.text = str(port)
	_internal_ip_value.text = lan
	_internal_port_value.text = str(port)
	if i.forwarded:
		_forward_status.text = "UPnP has set this forward up automatically. You only need to do it by hand if UPnP is off or unsupported."
	elif i.upnp_unavailable:
		_forward_status.text = "The router doesn't support automatic forwarding (UPnP), so add this rule by hand in its admin page (usually under Port Forwarding, Virtual Server or NAT), then use “Test from the internet”."
	else:
		_forward_status.text = "Add this rule in the router's admin page (usually under Port Forwarding, Virtual Server or NAT), or turn on UPnP forwarding below if the router supports it."
	# A reserved address still arrives through DHCP, so the computer can't tell reserved from
	# dynamic; the user confirms it once, and we warn again only if the address changes.
	var reserved := str(i.reserved_lan_ip)
	_dhcp_notice.visible = bool(i.dhcp_dynamic) and reserved != lan
	_dhcp_reserved_button.disabled = not admin
	var who := "this computer" if not handle.is_remote() else handle.host_name()
	if reserved != "" and reserved != lan:
		_dhcp_label.text = "The address of %s changed from %s to %s. Update the port forward in the router to point to %s (and its reservation, if you use one)." % [who, reserved, lan, lan]
		_dhcp_reserved_button.text = "Updated"
	else:
		_dhcp_label.text = "The router assigns the address of %s (%s). Unless it is reserved in the router (DHCP reservation or static lease), it can change and break the forward." % [who, lan]
		_dhcp_reserved_button.text = "It's reserved"


func _on_upnp_toggled(on: bool) -> void:
	var res: Dictionary = await handle.call_op("upnp_set", {"on": on})
	if not res.ok:
		Notifier.error(str(res.error))
		_upnp_check.set_pressed_no_signal(not on)
	_reload()


func _run_test() -> void:
	if _testing:
		return
	_testing = true
	_test_status.text = "Testing from the internet…"
	_test_status.remove_theme_color_override("font_color")
	_test_reasons.visible = false
	_refresh()
	var h := handle
	var result: Dictionary = await h.call_op("network_test")
	_testing = false
	if h != handle:
		return
	if not result.ok:
		_test_status.text = "✕ " + str(result.error)
		_test_status.add_theme_color_override("font_color", Color("e05555"))
		_test_reasons.visible = false
	elif result.online:
		var details: String = result.version if str(result.version) != "" else "Minecraft server"
		_test_status.text = "✓ Reachable from the internet at %s (%s%s)." % [result.address, details, ", cached result" if result.cache_hit else ""]
		_test_status.add_theme_color_override("font_color", Color("3fb97f"))
		_test_reasons.visible = false
	else:
		_test_status.text = "✕ Not reachable from the internet at %s." % result.address
		_test_status.add_theme_color_override("font_color", Color("e05555"))
		var reasons := PackedStringArray(result.reasons)
		_test_reasons.text = "Likely causes:\n• " + "\n• ".join(reasons) if not reasons.is_empty() else ""
		_test_reasons.visible = not reasons.is_empty()
	_refresh()


func _copy(text: String) -> void:
	if text == "":
		return
	DisplayServer.clipboard_set(text)
	Notifier.info("Copied %s to the clipboard." % text)
