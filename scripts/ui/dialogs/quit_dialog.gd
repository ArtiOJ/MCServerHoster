class_name QuitDialog
extends ConfirmationDialog
## Asked when closing the window while servers run: stop them all and quit,
## keep them running in the background, or cancel. While stopping it shows progress.

signal stop_and_quit_requested
signal minimize_requested

const ACTION_MINIMIZE := "minimize"

var _stopping := false
var _minimize_button: Button

@onready var _message: Label = %Message
@onready var _remember: CheckBox = %RememberCheck
@onready var _progress_timer: Timer = %ProgressTimer


func _ready() -> void:
	_minimize_button = add_button("Keep running in background", false, ACTION_MINIMIZE)
	get_ok_button().theme_type_variation = &"AccentButton"
	confirmed.connect(_on_stop)
	custom_action.connect(_on_custom_action)
	_progress_timer.timeout.connect(_update_stopping_text)


func open() -> void:
	_stopping = false
	var running := ServerManager.running_count()
	_message.text = "%d server%s still running.\nStop %s gracefully (worlds are saved) and quit, or keep %s running in the background?" % [
		running, " is" if running == 1 else "s are", "it" if running == 1 else "them", "it" if running == 1 else "them"]
	_remember.visible = true
	_remember.button_pressed = false
	get_ok_button().visible = true
	get_cancel_button().visible = true
	_minimize_button.visible = true
	dialog_hide_on_ok = false
	popup_centered()


## Shows the "stopping…" state; used both from the dialog and when quitting without asking.
func show_stopping() -> void:
	_stopping = true
	title = "Stopping servers"
	_remember.visible = false
	get_ok_button().visible = false
	get_cancel_button().visible = false
	_minimize_button.visible = false
	_update_stopping_text()
	_progress_timer.start()
	if not visible:
		popup_centered()


func _update_stopping_text() -> void:
	var names := PackedStringArray()
	for inst in ServerManager.get_instances():
		if inst.is_process_alive():
			names.append(inst.config.display_name)
	_message.text = "Saving worlds and stopping: %s…" % ", ".join(names) if not names.is_empty() else "All servers stopped."


func _on_stop() -> void:
	if _stopping:
		return
	if _remember.button_pressed:
		AppSettings.exit_behavior = AppSettings.ExitBehavior.STOP_ALL
		AppSettings.save_settings()
	stop_and_quit_requested.emit()


func _on_custom_action(action: StringName) -> void:
	if action != ACTION_MINIMIZE:
		return
	if _remember.button_pressed:
		AppSettings.exit_behavior = AppSettings.ExitBehavior.MINIMIZE
		AppSettings.save_settings()
	hide()
	minimize_requested.emit()
