extends Node
## Loads every script so parse and type errors show up without running the app:
## godot --headless --path . res://tests/check_scripts.tscn -- --no-autostart --profile=check


func _ready() -> void:
	var broken := 0
	for path in _scripts("res://scripts") + _scripts("res://tests"):
		var script := load(path) as Script
		if script == null or not script.can_instantiate():
			print("BROKEN ", path)
			broken += 1
	print("checked, broken=%d" % broken)
	get_tree().quit(1 if broken > 0 else 0)


func _scripts(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir.path_join(d)))
	return out
