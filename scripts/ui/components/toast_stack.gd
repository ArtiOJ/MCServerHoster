class_name ToastStack
extends VBoxContainer
## Shows Notifier messages as stacked toasts in the corner of the window.

const TOAST_SCENE := preload("res://scenes/components/toast.tscn")
const MAX_TOASTS := 5


func _ready() -> void:
	Notifier.notified.connect(_on_notified)


func _on_notified(message: String, level: int) -> void:
	var toast: Toast = TOAST_SCENE.instantiate()
	add_child(toast)
	toast.show_message(message, level)
	while get_child_count() > MAX_TOASTS:
		var oldest := get_child(0)
		remove_child(oldest)
		oldest.queue_free()
