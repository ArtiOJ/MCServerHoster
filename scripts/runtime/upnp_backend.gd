class_name UpnpBackend
extends RefCounted
## Thin wrapper around Godot's UPNP so NetworkService can be tested with a mock.
## Every method blocks (network round-trips to the router): call from a worker thread.

const DISCOVER_TIMEOUT_MS := 2000

var _upnp: UPNP
var _ready := false


## Finds the router. Returns {"ok": bool, "external_ip": String, "error": String}.
func discover() -> Dictionary:
	_upnp = UPNP.new()
	_ready = false
	var result := _upnp.discover(DISCOVER_TIMEOUT_MS, 2, "InternetGatewayDevice")
	if result != UPNP.UPNP_RESULT_SUCCESS or _upnp.get_device_count() == 0:
		return {"ok": false, "external_ip": "", "error": "No router with UPnP was found on this network (%s)." % result_text(result)}
	var gateway := _upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		return {"ok": false, "external_ip": "", "error": "A UPnP device answered, but it is not a usable internet gateway."}
	_ready = true
	return {"ok": true, "external_ip": _upnp.query_external_address(), "error": ""}


func is_ready() -> bool:
	return _ready


## Forwards TCP [param port] to this computer. Returns a UPNP result code (0 = success).
func add_mapping(port: int, description: String, lease_sec: int) -> int:
	if not _ready:
		return UPNP.UPNP_RESULT_NO_GATEWAY
	var result := _upnp.add_port_mapping(port, port, description, "TCP", lease_sec)
	if result == UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
		result = _upnp.add_port_mapping(port, port, description, "TCP", 0)
	return result


func delete_mapping(port: int) -> int:
	if not _ready:
		return UPNP.UPNP_RESULT_NO_GATEWAY
	return _upnp.delete_port_mapping(port, "TCP")


static func result_text(code: int) -> String:
	match code:
		UPNP.UPNP_RESULT_SUCCESS:
			return "success"
		UPNP.UPNP_RESULT_NOT_AUTHORIZED:
			return "the router refused (UPnP may be restricted in its settings)"
		UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MAPPING, UPNP.UPNP_RESULT_CONFLICT_WITH_OTHER_MECHANISM:
			return "the port is already forwarded to another device"
		UPNP.UPNP_RESULT_NO_DEVICES:
			return "no devices answered"
		UPNP.UPNP_RESULT_NO_GATEWAY:
			return "no gateway"
		UPNP.UPNP_RESULT_ACTION_FAILED:
			return "the router rejected the request"
		UPNP.UPNP_RESULT_ONLY_PERMANENT_LEASE_SUPPORTED:
			return "the router only supports permanent forwards"
	return "UPnP error %d" % code
