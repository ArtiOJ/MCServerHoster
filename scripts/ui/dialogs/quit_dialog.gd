class_name QuitDialog
extends ConfirmationDialog
## Asked when closing the window while servers run: stop them all and quit, keep the
## app running minimized, quit and leave the servers running (re-attached on next
## launch), or cancel. While stopping it shows progress.

signal stop_and_quit_requested
signal minimize_requested
signal detach_requested

const ACTION_MINIMIZE := "minimize"
const ACTION_DETACH := "detach"

var _stopping := false
var _minimize_button: Button
var _detach_button: Button

@onready var _message: Label = %Message
@onready var _remember: CheckBox = %RememberCheck
@onready var _progress_timer: Timer = %ProgressTimer


func _ready() -> void:
	_minimize_button = add_button("Minimize", false, ACTION_MINIMIZE)
	_minimize_button.tooltip_text = "Keep Server Manager open in the background (minimized). Events, sleep handling and start-on-connect keep working."
	_detach_button = add_button("Quit, leave running", false, ACTION_DETACH)
	_detach_button.tooltip_text = "Close Server Manager but keep the servers running. They are re-attached the next time it opens; until then events, sleep handling and start-on-connect are paused."
	get_ok_button().theme_type_variation = &"AccentButton"
	confirmed.connect(_on_stop)
	custom_action.connect(_on_custom_action)
	_progress_timer.timeout.connect(_update_stopping_text)


func open() -> void:
	_stopping = false
	var running := ServerManager.running_count()
	_message.text = "%d server%s still running.\nStop %s gracefully (worlds are saved) and quit, minimize Server Manager, or quit and leave %s running?" % [
		running, " is" if running == 1 else "s are", "it" if running == 1 else "them", "it" if running == 1 else "them"]
	_remember.visible = true
	_remember.button_pressed = false
	get_ok_button().visible = true
	get_cancel_button().visible = true
	_minimize_button.visible = true
	_detach_button.visible = true
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
	_detach_button.visible = false
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
	if action != ACTION_MINIMIZE and action != ACTION_DETACH:
		return
	if _remember.button_pressed:
		AppSettings.exit_behavior = AppSettings.ExitBehavior.MINIMIZE if action == ACTION_MINIMIZE else AppSettings.ExitBehavior.DETACH
		AppSettings.save_settings()
	hide()
	if action == ACTION_MINIMIZE:
		minimize_requested.emit()
	else:
		detach_requested.emit()
