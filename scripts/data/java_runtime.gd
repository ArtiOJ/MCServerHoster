class_name JavaRuntime
extends RefCounted
## A detected Java installation.

var executable := ""
var home := ""
var major := 0
var version := ""
var vendor := ""


func display_name() -> String:
	var v := vendor if vendor != "" else "Java"
	return "Java %d  (%s %s)" % [major, v, version]


## Key that is equal for the same installation reached through different paths.
func identity() -> String:
	return "%s|%s|%s" % [major, version, vendor]


func _to_string() -> String:
	return "%s @ %s" % [display_name(), executable]
