extends TestCase


func test_frames_round_trip_and_split() -> void:
	var a := RemoteProtocol.encode({"t": "hello", "n": 1})
	var b := RemoteProtocol.encode({"text": "ünïcode ✓"})
	var reader := RemoteProtocol.FrameReader.new()
	reader.max_frame = 1024
	var both := a + b
	# Fed one byte at a time, messages appear only once complete.
	var got: Array = []
	for i in both.size():
		reader.feed(both.slice(i, i + 1))
		var msg = reader.next()
		if msg != null:
			got.append(msg)
	check_eq(got.size(), 2, "two messages")
	check_eq(str(got[0].t), "hello", "first message")
	check_eq(str(got[1].text), "ünïcode ✓", "UTF-8 survives")
	check_eq(reader.buffered(), 0, "nothing left over")


func test_frame_limits() -> void:
	var reader := RemoteProtocol.FrameReader.new()
	reader.max_frame = 16
	reader.feed(RemoteProtocol.encode({"long": "x".repeat(100)}))
	check(reader.next() == null and reader.error != "", "oversized frame rejected")
	var bad := RemoteProtocol.FrameReader.new()
	var body := "[1,2,3]".to_utf8_buffer()
	var frame := PackedByteArray([0, 0, 0, 0])
	frame.encode_u32(0, body.size())
	bad.feed(frame + body)
	check(bad.next() == null and bad.error != "", "non-object JSON rejected")


func test_proofs() -> void:
	var secret := RemoteProtocol.new_secret()
	check(secret.length() >= 43, "256-bit secret")
	check(secret != RemoteProtocol.new_secret(), "secrets are random")
	var p := RemoteProtocol.proof(secret, "client", ["a", "b", "k"])
	check_eq(p, RemoteProtocol.proof(secret, "client", ["a", "b", "k"]), "deterministic")
	check(p != RemoteProtocol.proof(secret, "host", ["a", "b", "k"]), "label matters (no reflection)")
	check(p != RemoteProtocol.proof(secret, "client", ["b", "a", "k"]), "order matters")
	check(p != RemoteProtocol.proof(RemoteProtocol.new_secret(), "client", ["a", "b", "k"]), "secret matters")
	check(RemoteProtocol.proofs_equal(p, p), "equal proofs")
	check(not RemoteProtocol.proofs_equal(p, p.left(-1) + ("0" if p[-1] != "0" else "1")), "one character off")
	check(not RemoteProtocol.proofs_equal("", ""), "empty never matches")


func test_invites() -> void:
	var code := RemoteProtocol.make_invite({"name": "Brian's PC", "addresses": ["192.168.4.22", "203.0.113.5"], "port": 25590, "key": "abcdefghij", "secret": RemoteProtocol.new_secret()})
	check(code.begins_with(RemoteProtocol.INVITE_PREFIX), "prefixed")
	var parsed := RemoteProtocol.parse_invite("  " + code.insert(20, "\n") + " ")
	check(parsed.ok, "parses with stray whitespace")
	check_eq(parsed.name, "Brian's PC", "name")
	check_eq(Array(parsed.addresses), ["192.168.4.22", "203.0.113.5"], "addresses")
	check_eq(parsed.port, 25590, "port")
	check_eq(parsed.key, "abcdefghij", "key id")
	check(not RemoteProtocol.parse_invite("hello").ok, "wrong prefix")
	check(not RemoteProtocol.parse_invite(code.left(30)).ok, "truncated")
	var weak := RemoteProtocol.make_invite({"key": "abcdefghij", "secret": "short"})
	check(not RemoteProtocol.parse_invite(weak).ok, "short secret refused")


func test_split_address() -> void:
	check_eq(RemoteProtocol.split_address("192.168.1.5", 25590), {"host": "192.168.1.5", "port": 25590}, "no port")
	check_eq(RemoteProtocol.split_address("mc.example.com:4000", 25590), {"host": "mc.example.com", "port": 4000}, "with port")
	check_eq(RemoteProtocol.split_address("[::1]:4000", 25590), {"host": "::1", "port": 4000}, "IPv6 with port")
	check_eq(RemoteProtocol.split_address("::1", 25590), {"host": "::1", "port": 25590}, "bare IPv6")


func test_grant_permissions() -> void:
	var admin := RemoteGrant.create("Alice", RemoteProtocol.Role.SERVER_ADMIN, PackedStringArray(["survival"]))
	check(admin.allows("start", "survival"), "server admin starts own server")
	check(admin.allows("settings_save", "survival"), "edits its settings")
	check(not admin.allows("start", "creative"), "not other servers")
	check(not admin.allows("delete", "survival"), "cannot delete")
	check(not admin.allows("duplicate", "survival"), "cannot duplicate")
	check(not admin.allows("create_server"), "cannot create servers")
	check(not admin.allows("stop_all"), "cannot stop everything")
	check(not admin.allows("made_up_op", "survival"), "unknown operations refused")
	var sys := RemoteGrant.create("Bob", RemoteProtocol.Role.SYSTEM_ADMIN, PackedStringArray())
	check(sys.allows("delete", "anything") and sys.allows("create_server"), "system admin can do everything")
	var back := RemoteGrant.from_dict(JSON.parse_string(JSON.stringify(admin.to_dict())))
	check_eq(back.id, admin.id, "id survives JSON")
	check_eq(back.secret, admin.secret, "secret survives JSON")
	check_eq(back.role, RemoteProtocol.Role.SERVER_ADMIN, "role survives JSON")
	check_eq(Array(back.server_ids), ["survival"], "servers survive JSON")


func test_every_operation_has_a_role() -> void:
	for op in RemoteProtocol.HOST_OPS:
		check(RemoteProtocol.OPS.has(op), "%s listed" % op)
		check_eq(RemoteProtocol.OPS[op], RemoteProtocol.Role.SYSTEM_ADMIN, "%s needs a system admin" % op)


func test_private_files() -> void:
	var path := "user://remote-private-test.json"
	check_eq(AppSettings.write_private(path, "{\"secret\": 1}"), OK, "written")
	var out: Array = []
	OS.execute("stat", ["-c", "%a", ProjectSettings.globalize_path(path)], out)
	check_eq(str(out[0]).strip_edges(), "600", "only the owner can read it")
	check_eq(FileAccess.get_file_as_string(path), "{\"secret\": 1}", "content")
	DirAccess.remove_absolute(path)


func test_profile_paths() -> void:
	var saved := AppSettings.settings_path
	AppSettings.settings_path = "user://settings.json"
	check_eq(AppSettings.profile_path("remote-access.json"), "user://remote-access.json", "default profile")
	AppSettings.settings_path = "user://settings-test.json"
	check_eq(AppSettings.profile_path("remote-access.json"), "user://remote-access-test.json", "named profile")
	check_eq(AppSettings.profile_path("remote-host.key"), "user://remote-host-test.key", "other extensions")
	AppSettings.settings_path = saved


func test_invites_lead_with_the_public_address() -> void:
	var saved := NetworkService.public_ip
	NetworkService.public_ip = "203.0.113.7"
	var addresses := RemoteAccess.invite_addresses()
	check_eq(addresses[0], "203.0.113.7", "public address first: %s" % addresses)
	var grant := RemoteGrant.new()
	grant.id = "testkey1"
	grant.secret = "s".repeat(40)
	var invite := RemoteProtocol.parse_invite(RemoteAccess.invite_for(grant))
	check(invite.ok and invite.addresses[0] == "203.0.113.7", "invite code carries it first")
	NetworkService.public_ip = ""
	check(not RemoteAccess.invite_addresses().has("203.0.113.7"), "unknown public address left out")
	NetworkService.public_ip = saved
