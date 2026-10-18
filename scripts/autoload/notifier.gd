extends Node
## App-wide user notifications. UI listens to [signal notified] and shows toasts.

signal notified(message: String, level: Level)

enum Level { INFO, SUCCESS, WARNING, ERROR }


func info(message: String) -> void:
	notified.emit(message, Level.INFO)


func success(message: String) -> void:
	notified.emit(message, Level.SUCCESS)


func warn(message: String) -> void:
	push_warning(message)
	notified.emit(message, Level.WARNING)


func error(message: String) -> void:
	printerr(message)
	notified.emit(message, Level.ERROR)
