extends TestCase

## Verified against a real Paper 1.21.11 server in offline mode (whitelist add / ban via console).
const OFFLINE_VECTORS := {
	"Steve": "5627dd98-e6be-3c21-b8a8-e92344183641",
	"Alex_99": "46923504-0499-324d-9008-cba88f09aeae",
	"Herobrine": "25966168-dc9c-360c-8f32-ed022bfa1070",
}
## ops.json exactly as Paper 1.21.11 wrote it.
const PAPER_OPS_JSON := "[\n  {\n    \"uuid\": \"5627dd98-e6be-3c21-b8a8-e92344183641\",\n    \"name\": \"Steve\",\n    \"level\": 4,\n    \"bypassesPlayerLimit\": false\n  }\n]"


func _temp_dir() -> String:
	var dir := ProjectSettings.globalize_path("user://test-player-lists-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func test_offline_uuid_matches_paper() -> void:
	for player in OFFLINE_VECTORS:
		check_eq(PlayerLists.offline_uuid(player), OFFLINE_VECTORS[player], "offline UUID of " + player)
	check(PlayerLists.offline_uuid("steve") != OFFLINE_VECTORS.Steve, "offline UUIDs are case-sensitive")


func test_json_matches_minecraft_format() -> void:
	var parsed = JSON.parse_string(PAPER_OPS_JSON)
	var entries: Array[Dictionary] = []
	for e in parsed:
		entries.append(e)
	check_eq(PlayerLists.to_minecraft_json(entries), PAPER_OPS_JSON, "byte-identical to Paper's ops.json")
	check_eq(PlayerLists.to_minecraft_json([] as Array[Dictionary]), "[]", "empty list")


func test_round_trip_preserves_unknown_fields() -> void:
	var dir := _temp_dir()
	var f := FileAccess.open(dir.path_join("whitelist.json"), FileAccess.WRITE)
	f.store_string("[{\"uuid\":\"%s\",\"name\":\"Steve\",\"pluginNote\":\"keep me\",\"weight\":3}]" % OFFLINE_VECTORS.Steve)
	f.close()
	check_eq(PlayerLists.add_player(dir, PlayerLists.Kind.WHITELIST, {"uuid": OFFLINE_VECTORS.Alex_99, "name": "Alex_99"}), OK, "add")
	check_eq(PlayerLists.add_player(dir, PlayerLists.Kind.WHITELIST, {"uuid": OFFLINE_VECTORS.Steve, "name": "Steve"}), OK, "re-add existing")
	var entries := PlayerLists.read(dir, PlayerLists.Kind.WHITELIST)
	check_eq(entries.size(), 2, "no duplicate entry")
	check_eq(entries[0].get("pluginNote"), "keep me", "unknown field kept")
	var text := FileAccess.get_file_as_string(dir.path_join("whitelist.json"))
	check(text.contains("\"weight\": 3,") or text.contains("\"weight\": 3\n"), "integral numbers written without .0")
	check_eq(PlayerLists.remove(dir, PlayerLists.Kind.WHITELIST, "steve"), OK, "remove is case-insensitive")
	check_eq(PlayerLists.remove(dir, PlayerLists.Kind.WHITELIST, "Nobody"), ERR_DOES_NOT_EXIST, "remove missing")
	check_eq(PlayerLists.read(dir, PlayerLists.Kind.WHITELIST).size(), 1, "one left")
	FileOps.remove_tree(dir)


func test_ops_bans_and_ip_bans() -> void:
	var dir := _temp_dir()
	PlayerLists.add_player(dir, PlayerLists.Kind.OPS, {"uuid": OFFLINE_VECTORS.Steve, "name": "Steve"}, {"level": 2})
	var ops := PlayerLists.read(dir, PlayerLists.Kind.OPS)
	check_eq(int(ops[0].level), 2, "op level stored")
	check_eq(ops[0].bypassesPlayerLimit, false, "bypass flag present")
	check_eq(PlayerLists.set_op_level(dir, "STEVE", 3), OK, "change level")
	check_eq(int(PlayerLists.read(dir, PlayerLists.Kind.OPS)[0].level), 3, "level changed")
	PlayerLists.add_player(dir, PlayerLists.Kind.BANS, {"uuid": OFFLINE_VECTORS.Herobrine, "name": "Herobrine"}, {"reason": "Griefing"})
	var ban := PlayerLists.read(dir, PlayerLists.Kind.BANS)[0]
	check_eq(ban.reason, "Griefing", "ban reason")
	check_eq(ban.expires, "forever", "ban expiry")
	check_eq(ban.source, PlayerLists.SOURCE, "ban source")
	check(RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} [+-]\\d{4}$").search(ban.created) != null, "created format: " + str(ban.created))
	PlayerLists.add_player(dir, PlayerLists.Kind.BANS, {"uuid": OFFLINE_VECTORS.Steve, "name": "Steve"})
	check_eq(PlayerLists.find(PlayerLists.read(dir, PlayerLists.Kind.BANS), "Steve", PlayerLists.Kind.BANS) >= 0, true, "second ban")
	check_eq(str(PlayerLists.read(dir, PlayerLists.Kind.BANS)[1].reason), "Banned by an operator.", "default reason like vanilla")
	check_eq(PlayerLists.add_ip_ban(dir, "10.1.2.3", "Spam"), OK, "ip ban")
	check_eq(PlayerLists.read(dir, PlayerLists.Kind.IP_BANS)[0].ip, "10.1.2.3", "ip stored")
	check_eq(PlayerLists.remove(dir, PlayerLists.Kind.IP_BANS, "10.1.2.3"), OK, "ip pardon")
	FileOps.remove_tree(dir)


func test_validation_and_mojang_parsing() -> void:
	check(PlayerLists.is_valid_name("Alex_99"), "valid name")
	check(not PlayerLists.is_valid_name("ab"), "too short")
	check(not PlayerLists.is_valid_name("this_name_is_too_long"), "too long")
	check(not PlayerLists.is_valid_name("bad-name"), "bad char")
	check(PlayerLists.is_valid_ip("192.168.4.22") and PlayerLists.is_valid_ip("::1"), "valid IPs")
	check(not PlayerLists.is_valid_ip("300.1.1.1") and not PlayerLists.is_valid_ip("Steve"), "invalid IPs")
	var ok := PlayerLists.parse_mojang_response(200, "{\"id\":\"069a79f444e94726a5befca90e38aaf5\",\"name\":\"Notch\"}", "notch")
	check(ok.ok and ok.uuid == "069a79f4-44e9-4726-a5be-fca90e38aaf5" and ok.name == "Notch", "200 parsed with canonical name")
	check(not PlayerLists.parse_mojang_response(204, "", "Nobody").ok, "204 = no account")
	check(PlayerLists.parse_mojang_response(404, "{\"errorMessage\":\"Couldn't find any profile with name Nobody\"}", "Nobody").error.contains("no Minecraft account"), "404 message")
	check(PlayerLists.parse_mojang_response(429, "", "Steve").error.contains("rate"), "rate limit message")
	check_eq(PlayerLists.dash_uuid("069A79F444E94726A5BEFCA90E38AAF5"), "069a79f4-44e9-4726-a5be-fca90e38aaf5", "dash + lower")


func test_uuid_mode_detection() -> void:
	var dir := _temp_dir()
	var props := ServerProperties.new()
	props.set_value("online-mode", false)
	props.save_file(dir.path_join("server.properties"))
	check(not PlayerLists.uses_online_uuids(dir), "offline mode")
	var paper := YamlDoc.new()
	paper.set_value("proxies.velocity.enabled", "true")
	paper.set_value("proxies.velocity.online-mode", "true")
	paper.save_file(dir.path_join(SettingsCatalog.PAPER_GLOBAL))
	check(PlayerLists.uses_online_uuids(dir), "offline server behind online Velocity uses Mojang UUIDs")
	var cache := FileAccess.open(dir.path_join("usercache.json"), FileAccess.WRITE)
	cache.store_string("[{\"uuid\":\"%s\",\"name\":\"Steve\",\"expiresOn\":\"2026-11-18 20:38:29 -0500\"}]" % OFFLINE_VECTORS.Steve)
	cache.close()
	check_eq(PlayerLists.usercache_lookup(dir, "STEVE"), {"uuid": OFFLINE_VECTORS.Steve, "name": "Steve"}, "usercache lookup, canonical casing")
	check(PlayerLists.usercache_lookup(dir, "Nobody").is_empty(), "unknown name")
	FileOps.remove_tree(dir)
