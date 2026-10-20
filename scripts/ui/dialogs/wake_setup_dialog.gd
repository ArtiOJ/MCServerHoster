class_name WakeSetupDialog
extends ConfirmationDialog
## Explains and runs the one-time setup that lets Server Manager wake the computer from
## sleep. Shown from Preferences and whenever a wake option is switched on before setup.

signal decided(installed: bool)

const SCENE := "res://scenes/dialogs/wake_setup_dialog.tscn"

var _busy := false

@onready var _message: Label = %Message
@onready var _status: Label = %Status


## Shows the setup prompt (unless already set up) and returns true once the helper is installed.
static func prompt(context: Node) -> bool:
	if WakeHelper.is_current():
		return true
	var dialog: WakeSetupDialog = load(SCENE).instantiate()
	context.get_tree().root.add_child(dialog)
	dialog.popup_centered()
	var installed: bool = await dialog.decided
	dialog.queue_free()
	return installed


func _ready() -> void:
	_message.text = "Waking this computer from sleep needs its wake-up alarm, which only root can set. This installs:\n\n%s\n\nYour password is asked once now. Nothing else on the system changes; Preferences → Power → Remove uninstalls both files." % WakeHelper.install_summary()
	_status.text = ""
	confirmed.connect(_install)
	canceled.connect(func() -> void:
		if not _busy:
			decided.emit(false))
	close_requested.connect(func() -> void:
		if not _busy:
			decided.emit(false))


func _install() -> void:
	_busy = true
	get_ok_button().disabled = true
	get_cancel_button().disabled = true
	_status.text = "Waiting for your password…"
	var staging := ProjectSettings.globalize_path("user://wake-setup")
	var result: Dictionary = await FileOps.run_async(self, func() -> Dictionary: return WakeHelper.install(staging))
	_busy = false
	if result.ok:
		Notifier.success(result.message)
		PowerManager.refresh_wake()
		hide()
		decided.emit(true)
	else:
		Notifier.error(result.message)
		_status.text = result.message
		get_ok_button().disabled = false
		get_cancel_button().disabled = false
