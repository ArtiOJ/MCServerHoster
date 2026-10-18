class_name DeleteServerDialog
extends ConfirmationDialog
## Confirms deleting a server; the user must type the server's name.

var _instance: ServerInstance

@onready var _message: Label = %Message
@onready var _name_edit: LineEdit = %NameEdit
@onready var _delete_files: CheckBox = %DeleteFilesCheck
@onready var _delete_backups: CheckBox = %DeleteBackupsCheck


func _ready() -> void:
	get_ok_button().theme_type_variation = &"DangerButton"
	_name_edit.text_changed.connect(func(_t: String) -> void: _validate())
	_name_edit.text_submitted.connect(func(_t: String) -> void:
		if not get_ok_button().disabled:
			_on_confirmed()
			hide())
	confirmed.connect(_on_confirmed)


func open(inst: ServerInstance) -> void:
	_instance = inst
	title = "Delete %s?" % inst.config.display_name
	_message.text = "This permanently deletes \"%s\". It cannot be undone.\nFolder: %s\n\nType the server name to confirm." % [inst.config.display_name, inst.config.directory]
	_name_edit.text = ""
	_name_edit.placeholder_text = inst.config.display_name
	_delete_files.button_pressed = true
	_delete_backups.button_pressed = false
	_validate()
	popup_centered()
	_name_edit.grab_focus.call_deferred()


func _validate() -> void:
	get_ok_button().disabled = _instance == null or _name_edit.text.strip_edges() != _instance.config.display_name


func _on_confirmed() -> void:
	if _instance == null:
		return
	var display := _instance.config.display_name
	var err := ServerManager.delete_server(_instance.config.id, _delete_files.button_pressed, _delete_backups.button_pressed)
	_instance = null
	if err == OK:
		Notifier.success("Deleted %s." % display)
	elif err == ERR_BUSY:
		Notifier.error("Stop %s before deleting it." % display)
	else:
		Notifier.error("Could not delete %s: %s" % [display, error_string(err)])
