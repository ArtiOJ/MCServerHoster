class_name TestCase
extends RefCounted
## Base class for headless unit tests. Methods named `test_*` are run by tests/test_runner.gd.

var failures := PackedStringArray()


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func check_eq(actual: Variant, expected: Variant, message := "") -> void:
	if typeof(actual) != typeof(expected) or actual != expected:
		failures.append("%s: expected <%s> but got <%s>" % [message, str(expected), str(actual)])
