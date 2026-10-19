class_name RemoteLinkRow
extends PanelContainer
## One computer this app connects to, in the Remote access dialog: its status, role and
## actions.

signal connect_requested(link: RemoteLink)
signal disconnect_requested(link: RemoteLink)
signal address_requested(link: RemoteLink)
signal remove_requested(link: RemoteLink)

const STATUS_COLORS: Array[Color] = [Color("6b7280"), Color("f2b84b"), Color("3fb97f"), Color("e05555")]

var link: RemoteLink

@onready var _dot: StatusDot = %Dot
@onready var _name_label: Label = %NameLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _wake_button: Button = %WakeButton
@onready var _connect_button: Button = %ConnectButton
@onready var _address_button: Button = %AddressButton
@onready var _remove_button: Button = %RemoveButton


func _ready() -> void:
	_connect_button.pressed.connect(func() -> void:
		if link.status == RemoteLink.Status.ONLINE or link.status == RemoteLink.Status.CONNECTING:
			disconnect_requested.emit(link)
		else:
			connect_requested.emit(link))
	_wake_button.pressed.connect(func() -> void: link.wake())
	_address_button.pressed.connect(func() -> void: address_requested.emit(link))
	_remove_button.pressed.connect(func() -> void: remove_requested.emit(link))


func setup(l: RemoteLink) -> void:
	link = l
	refresh()


func refresh() -> void:
	if link == null or not is_node_ready():
		return
	_dot.color = STATUS_COLORS[link.status]
	_dot.pulsing = link.status == RemoteLink.Status.CONNECTING
	_name_label.text = link.source_name()
	var where := ", ".join(link.addresses) + (":%d" % link.port if link.port != RemoteProtocol.DEFAULT_PORT else "")
	match link.status:
		RemoteLink.Status.ONLINE:
			var count := link.remote_servers().size()
			_detail_label.text = "%s · %d server%s · %s" % [link.status_text(), count, "" if count == 1 else "s", link.connected_address]
		RemoteLink.Status.CONNECTING:
			_detail_label.text = ("Waking up and connecting to %s…" if link.is_waking() else "Connecting to %s…") % where
		RemoteLink.Status.DENIED:
			_detail_label.text = "Access denied: %s" % link.error
		_:
			_detail_label.text = ("Offline: %s" % link.error if link.error != "" else "Offline") + " · " + where
	var active := link.status == RemoteLink.Status.ONLINE or link.status == RemoteLink.Status.CONNECTING
	_wake_button.visible = link.can_wake()
	_wake_button.disabled = link.is_waking()
	_connect_button.text = "Disconnect" if active else "Reconnect"
	_connect_button.tooltip_text = "Stop connecting until you reconnect" if active else "Try to connect now"
