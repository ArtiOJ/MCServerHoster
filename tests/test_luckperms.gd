extends TestCase

const FIX := "res://tests/fixtures/luckperms_export.json"
const NOTCH := "069a79f4-44e9-4726-a5be-fca90e38aaf5"
const JEB := "853c80ef-3c37-49fd-aa49-938b674adae6"


func _model() -> Dictionary:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIX))
	return LuckPerms.parse_export(data, {JEB: "jeb_"})


func test_parses_an_export() -> void:
	var m := _model()
	check_eq(m.groups.map(func(g: Dictionary) -> String: return g.name), ["admin", "builder", "default"], "groups by weight, then name")
	var builder: Dictionary = LuckPerms.find(m, "group", "builder")
	check_eq(builder.weight, 20, "weight")
	check_eq(builder.prefixes, [{"priority": 20, "text": "&a[B.] ", "context": "", "expiry": 0}], "prefix text keeps dots and spaces")
	check_eq(builder.parents.map(func(p: Dictionary) -> String: return p.group), ["default"], "parents")
	check_eq(builder.other.size(), 1, "other node types kept")
	var admin: Dictionary = LuckPerms.find(m, "group", "admin")
	var home: Dictionary = admin.permissions.filter(func(p: Dictionary) -> bool: return p.node == "essentials.home")[0]
	check_eq(home.context, "server=a server=b world=world", "contexts with several values, sorted")
	var fly: Dictionary = admin.permissions.filter(func(p: Dictionary) -> bool: return p.node == "fly.use")[0]
	check_eq(fly.expiry, 1792449127, "expiry")
	var notch: Dictionary = LuckPerms.find(m, "user", NOTCH)
	check(notch.name == "Notch" and notch.primary == "builder", "user name and primary group from the export")
	check_eq(LuckPerms.find(m, "user", JEB).name, "jeb_", "name from usercache otherwise")
	check(notch.permissions[0].node == "some.node" and not notch.permissions[0].value, "denied permission")
	check_eq(m.tracks, [{"name": "staff", "groups": ["builder", "admin"]}], "tracks")


func test_builds_commands() -> void:
	var cases := [
		[{"action": "group_create", "group": "mod"}, "lp creategroup mod"],
		[{"action": "weight_set", "group": "mod", "weight": 50}, "lp group mod setweight 50"],
		[{"action": "permission_set", "holder": "group", "name": "mod", "node": "kick.use", "value": false}, "lp group mod permission set kick.use false"],
		[{"action": "permission_set", "holder": "group", "name": "mod", "node": "fly.use", "value": true, "duration": "1d", "context": "world=world_nether"},
				"lp group mod permission settemp fly.use true 1d replace world=world_nether"],
		[{"action": "permission_unset", "holder": "user", "name": NOTCH, "node": "fly.use", "temporary": true}, "lp user %s permission unsettemp fly.use" % NOTCH],
		[{"action": "parent_add", "holder": "user", "name": NOTCH, "group": "mod"}, "lp user %s parent add mod" % NOTCH],
		[{"action": "prefix_set", "holder": "group", "name": "mod", "priority": 50, "text": "&c[Mod] "}, "lp group mod meta setprefix 50 \"&c[Mod] \""],
		[{"action": "track_insert", "track": "staff", "group": "mod", "position": 2}, "lp track staff insert mod 2"],
		[{"action": "promote", "name": NOTCH, "track": "staff"}, "lp user %s promote staff" % NOTCH],
	]
	for c in cases:
		var built := LuckPerms.commands_for(c[0])
		check(built.ok and built.commands == [c[1]], "%s -> %s (got %s %s)" % [c[0].action, c[1], built.get("commands"), built.get("error", "")])
	var move := LuckPerms.commands_for({"action": "track_move", "track": "staff", "group": "mod", "position": 1})
	check_eq(move.commands, ["lp track staff remove mod", "lp track staff insert mod 1"], "moving within a track")


func test_rejects_unsafe_input() -> void:
	var bad := [
		{"action": "group_create", "group": "Mod Team"},
		{"action": "group_delete", "group": "default"},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "bad node"},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "x\"y"},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "a.b", "context": "world"},
		{"action": "permission_set", "holder": "group", "name": "mod", "node": "a.b", "duration": "forever"},
		{"action": "permission_set", "holder": "user", "name": "Notch", "node": "a.b"},
		{"action": "parent_add", "holder": "group", "name": "mod", "group": "mod"},
		{"action": "prefix_set", "holder": "group", "name": "mod", "priority": 1, "text": "say \"hi\""},
		{"action": "nonsense"},
	]
	for change in bad:
		check(not LuckPerms.commands_for(change).ok, "rejected: %s" % change)
	check(LuckPerms.is_valid_duration("1d12h") and LuckPerms.is_valid_duration("2mo") and not LuckPerms.is_valid_duration("1x"), "durations")


func test_checks_what_took_effect() -> void:
	var m := _model()
	check(LuckPerms.applied({"action": "group_create", "group": "builder"}, m), "group exists")
	check(not LuckPerms.applied({"action": "group_create", "group": "mod"}, m), "group missing")
	check(LuckPerms.applied({"action": "weight_set", "group": "builder", "weight": 20}, m), "weight")
	check(LuckPerms.applied({"action": "permission_set", "holder": "group", "name": "admin", "node": "essentials.home", "value": true, "context": "world=world server=b server=a"}, m), "context order doesn't matter")
	check(not LuckPerms.applied({"action": "permission_set", "holder": "group", "name": "admin", "node": "essentials.home", "value": true}, m), "global differs from a context")
	check(not LuckPerms.applied({"action": "permission_set", "holder": "user", "name": NOTCH, "node": "some.node", "value": true}, m), "wrong value")
	check(LuckPerms.applied({"action": "permission_unset", "holder": "user", "name": NOTCH, "node": "other.node"}, m), "absent node counts as removed")
	check(LuckPerms.applied({"action": "parent_add", "holder": "user", "name": NOTCH, "group": "builder"}, m), "parent")
	check(LuckPerms.applied({"action": "prefix_set", "holder": "group", "name": "builder", "priority": 20, "text": "&a[B.] "}, m), "prefix")
	check(LuckPerms.applied({"action": "track_insert", "track": "staff", "group": "admin", "position": 2}, m), "track position")
	check(not LuckPerms.applied({"action": "track_insert", "track": "staff", "group": "admin", "position": 1}, m), "wrong track position")
	check(LuckPerms.applied({"action": "track_move", "track": "staff", "group": "builder", "position": 1}, m), "moved group checked by position")
	check(LuckPerms.applied({"action": "parent_remove", "holder": "user", "name": "00000000-0000-0000-0000-000000000000", "group": "x"}, m), "unknown user has no parents")


func test_reads_export_files() -> void:
	var path := ProjectSettings.globalize_path("user://test-lp-export.json.gz")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(FileAccess.get_file_as_bytes(FIX).compress(FileAccess.COMPRESSION_GZIP))
	f.close()
	check(LuckPerms.read_export_file(path).has("groups"), "gzip export read")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(FileAccess.get_file_as_bytes(FIX).slice(0, 100).compress(FileAccess.COMPRESSION_GZIP))
	f.close()
	check(LuckPerms.read_export_file(path).is_empty(), "half-written export ignored")
	DirAccess.remove_absolute(path)
	check(LuckPerms.read_export_file(path).is_empty(), "missing export")
