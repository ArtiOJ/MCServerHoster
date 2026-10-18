extends Node
## Runs every tests/test_*.gd TestCase and exits with a non-zero code on failure.
## Usage: godot --headless --path . res://tests/test_runner.tscn -- --no-autostart

const TEST_DIR := "res://tests"


func _ready() -> void:
	var failed := 0
	var passed := 0
	var dir := DirAccess.open(TEST_DIR)
	for file in dir.get_files():
		if not (file.begins_with("test_") and file.ends_with(".gd")) or file in ["test_runner.gd", "test_case.gd"]:
			continue
		var script: GDScript = load(TEST_DIR.path_join(file))
		for method in script.get_script_method_list():
			if not str(method.name).begins_with("test_"):
				continue
			var test: TestCase = script.new()
			await test.call(method.name)
			if test.failures.is_empty():
				passed += 1
			else:
				failed += 1
				for f in test.failures:
					printerr("FAIL %s::%s  %s" % [file, method.name, f])
	print("\n%d passed, %d failed" % [passed, failed])
	get_tree().quit(1 if failed > 0 else 0)
