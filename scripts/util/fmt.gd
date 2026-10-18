class_name Fmt
extends RefCounted
## Small formatting helpers shared by the UI.


static func bytes(value: float) -> String:
	var units := ["B", "KB", "MB", "GB", "TB"]
	var i := 0
	while value >= 1024.0 and i < units.size() - 1:
		value /= 1024.0
		i += 1
	if i == 0:
		return "%d %s" % [int(value), units[i]]
	return "%.1f %s" % [value, units[i]]


static func megabytes(mb: int) -> String:
	if mb >= 1024:
		var gb := mb / 1024.0
		return ("%d GB" % int(gb)) if is_equal_approx(gb, roundf(gb)) else ("%.1f GB" % gb)
	return "%d MB" % mb


static func duration(seconds: int) -> String:
	seconds = maxi(seconds, 0)
	var d := seconds / 86400
	var h := (seconds % 86400) / 3600
	var m := (seconds % 3600) / 60
	var s := seconds % 60
	if d > 0:
		return "%dd %dh" % [d, h]
	if h > 0:
		return "%dh %dm" % [h, m]
	if m > 0:
		return "%dm %ds" % [m, s]
	return "%ds" % s


static func datetime(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	return "%04d-%02d-%02d %02d:%02d" % [d.year, d.month, d.day, d.hour, d.minute]


static func file_stamp(unix: int) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	var d := Time.get_datetime_dict_from_unix_time(unix + bias)
	return "%04d-%02d-%02d_%02d-%02d-%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]


## Lower-case, filesystem- and node-name-safe identifier.
static func slugify(text: String) -> String:
	var out := ""
	for c in text.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif not out.ends_with("-"):
			out += "-"
	out = out.trim_prefix("-").trim_suffix("-")
	return out if not out.is_empty() else "server"


static func random_token(length: int) -> String:
	const CHARS := "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	var crypto := Crypto.new()
	var raw := crypto.generate_random_bytes(length)
	var out := ""
	for b in raw:
		out += CHARS[b % CHARS.length()]
	return out


## Splits a command-line string on whitespace, honouring single/double quotes.
static func split_args(text: String) -> PackedStringArray:
	var args := PackedStringArray()
	var current := ""
	var quote := ""
	var has_token := false
	for c in text:
		if quote != "":
			if c == quote:
				quote = ""
			else:
				current += c
		elif c == "\"" or c == "'":
			quote = c
			has_token = true
		elif c == " " or c == "\t" or c == "\n":
			if has_token:
				args.append(current)
				current = ""
				has_token = false
		else:
			current += c
			has_token = true
	if has_token:
		args.append(current)
	return args


## Quotes an argument for display in a shell-like command preview.
static func shell_quote(arg: String) -> String:
	if arg.is_empty():
		return "''"
	for c in " \t\"'$&|;<>()*?!`\\":
		if arg.contains(c):
			return "'" + arg.replace("'", "'\\''") + "'"
	return arg


## Compares dotted Minecraft versions numerically ("1.21.10" > "1.21.9", "26.1" > "1.21.11").
## Pre-release suffixes ("-rc1") are ignored. Returns -1, 0 or 1.
static func compare_versions(a: String, b: String) -> int:
	var pa := a.get_slice("-", 0).split(".")
	var pb := b.get_slice("-", 0).split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := pa[i].to_int() if i < pa.size() else 0
		var y := pb[i].to_int() if i < pb.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0
