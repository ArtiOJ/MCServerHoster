class_name TempRunDialog
extends ConfirmationDialog
## Asks whether to keep or discard what changed during a temporary (test) run.

const ACTION_KEEP := "keep"

var _instance: ServerInstance
var _busy := false
var _keep_button: Button

@onready var _message: Label = %Message
@onready var _hint: Label = %HintLabel
@onready var _progress: ProgressBar = %Progress


func _ready() -> void:
	_keep_button = add_button("Keep changes", false, ACTION_KEEP)
	_keep_button.theme_type_variation = &"AccentButton"
	_keep_button.tooltip_text = "Make the copy permanent. A safety backup of the server's current worlds is saved to its Backups first."
	get_ok_button().theme_type_variation = &"DangerButton"
	get_ok_button().tooltip_text = "Delete the temporary copy. The server stays exactly as it was before the test run."
	get_cancel_button().tooltip_text = "Leave the copy as it is. Starting normally is blocked until you decide; resume it from the Start ▾ menu."
	confirmed.connect(func() -> void: _finish(false))
	custom_action.connect(func(action: StringName) -> void:
		if action == ACTION_KEEP:
			_finish(true))
	close_requested.connect(func() -> void:
		if _busy:
			show.call_deferred())


func is_busy() -> bool:
	return _busy


func open(inst: ServerInstance) -> void:
	_instance = inst
	_busy = false
	title = "Temporary run of %s" % inst.config.display_name
	_progress.visible = false
	var running := inst.is_process_alive() or inst.state == ServerInstance.State.INSTALLING
	if running:
		_message.text = "%s is running as a temporary copy. Stop it first, then choose whether to keep or discard what changed." % inst.config.display_name
	else:
		_message.text = "%s was running as a temporary copy. Discard everything that changed during the test run, or keep the changes and make them permanent?" % inst.config.display_name
	_hint.text = "Keeping replaces the server's files with the copy; a safety backup of the current worlds is saved to Backups first. Discarding deletes the copy permanently."
	_set_enabled(not running)
	popup_centered()


func _finish(keep: bool) -> void:
	if _busy or _instance == null or not _instance.is_temporary():
		hide()
		return
	_busy = true
	_set_enabled(false)
	get_cancel_button().disabled = true
	_progress.visible = true
	_message.text = "Keeping the changes…" if keep else "Discarding the temporary copy…"
	var inst := _instance
	var err: Error = await inst.finish_temporary(keep)
	_busy = false
	_progress.visible = false
	get_cancel_button().disabled = false
	if err == OK:
		if keep:
			Notifier.success("%s now uses the files from the temporary run." % inst.config.display_name)
		else:
			Notifier.success("Discarded the temporary copy of %s." % inst.config.display_name)
		hide()
	else:
		_set_enabled(true)
		_message.text = "Could not finish the temporary run: %s" % error_string(err)
		Notifier.error("%s: could not finish the temporary run (%s)." % [inst.config.display_name, error_string(err)])


func _set_enabled(enabled: bool) -> void:
	get_ok_button().disabled = not enabled
	_keep_button.disabled = not enabled
