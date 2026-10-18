class_name ServerTab
extends MarginContainer
## Base class for the tabs inside the server view. [method bind] switches which
## server the tab shows; signal connections made through [method watch] are
## dropped automatically when the bound server changes.

var instance: ServerInstance

var _connections: Array[Array] = []


func bind(inst: ServerInstance) -> void:
	for pair in _connections:
		var sig: Signal = pair[0]
		if not sig.is_null() and sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	_connections.clear()
	instance = inst
	if instance != null:
		_on_bound()


## Connects [param callable] to [param sig] for as long as the current server is bound.
func watch(sig: Signal, callable: Callable) -> void:
	sig.connect(callable)
	_connections.append([sig, callable])


## Override: connect signals with watch() and refresh the UI for [member instance].
func _on_bound() -> void:
	pass
