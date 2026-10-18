extends TestCase
## Detection tests for ServerImporter on fixture folders with fake jars that carry the
## same metadata real jars do (MANIFEST Main-Class, META-INF/versions.list, version.json).

var _root := ""


func _fixture(name: String) -> String:
	if _root == "":
		_root = ProjectSettings.globalize_path("user://test-import-%d" % Time.get_ticks_usec())
	var dir := _root.path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _jar(path: String, main_class: String, versions_list := "", version_id := "") -> void:
	var zip := ZIPPacker.new()
	zip.open(path)
	zip.start_file("META-INF/MANIFEST.MF")
	zip.write_file(("Manifest-Version: 1.0\nMain-Class: %s\n" % main_class).to_utf8_buffer())
	zip.close_file()
	if versions_list != "":
		zip.start_file("META-INF/versions.list")
		zip.write_file(versions_list.to_utf8_buffer())
		zip.close_file()
	if version_id != "":
		zip.start_file("version.json")
		zip.write_file(JSON.stringify({"id": version_id, "name": version_id}).to_utf8_buffer())
		zip.close_file()
	zip.close()


func _cleanup() -> void:
	if _root != "":
		FileOps.remove_tree(_root)


func test_paper_with_build_in_jar_name() -> void:
	var d := _fixture("paper")
	_jar(d.path_join("paper-1.21.11-132.jar"), "io.papermc.paperclip.Main", "abc\t1.21.11\t1.21.11/paper-1.21.11.jar\n", "1.21.11")
	_write(d.path_join("start.sh"), "#!/bin/sh\njava -Xms1G -Xmx2G -XX:+UseG1GC -Daikars.new.flags=true -Dfile.encoding=UTF-8 -jar paper-1.21.11-132.jar --nogui\n")
	_write(d.path_join("server.properties"), "server-port=25599\nmotd=Old server\nlevel-name=world\n")
	_write(d.path_join("eula.txt"), "eula=TRUE\n")
	_write(d.path_join("world/level.dat"), "x")
	_write(d.path_join("plugins/Essentials.jar"), "x")
	# Paper unpacks some net/neoforged libraries; that must not look like NeoForge.
	_write(d.path_join("libraries/net/neoforged/srgutils/x.jar"), "x")
	var a := ServerImporter.analyze(d)
	check_eq(a.software, "paper", "software")
	check_eq(a.kind, ServerImporter.Kind.PAPER, "kind")
	check_eq(a.mc_version, "1.21.11", "version")
	check_eq(a.build, 132, "build from file name")
	check_eq(a.jar, "paper-1.21.11-132.jar", "jar")
	check_eq(a.port, 25599, "port")
	check_eq(a.ram_max_mb, 2048, "Xmx")
	check_eq(a.ram_min_mb, 1024, "Xms")
	check(a.aikar_flags, "aikar flags detected")
	check_eq(a.extra_jvm_args, "-Dfile.encoding=UTF-8", "custom -D flag kept, managed ones dropped")
	check(a.eula_accepted, "eula (case-insensitive)")
	check_eq(a.plugins, 1, "plugins")
	check_eq(a.worlds, PackedStringArray(["world"]), "worlds")
	check(a.can_import and not a.needs_paper_switch, "importable as is")
	_cleanup()


func test_paper_build_from_version_history() -> void:
	var d := _fixture("paper-history")
	_jar(d.path_join("server.jar"), "io.papermc.paperclip.Main", "abc\t1.21.11\t1.21.11/paper-1.21.11.jar\n", "1.21.11")
	_write(d.path_join("version_history.json"), "{\"currentVersion\":\"1.21.11-132-c5eb079 (MC: 1.21.11)\"}")
	var a := ServerImporter.analyze(d)
	check_eq(a.build, 132, "build from version_history.json")
	check(not a.eula_accepted and a.warnings.size() > 0, "missing EULA warned")
	_cleanup()


func test_forks_and_bukkit_and_vanilla() -> void:
	var p := _fixture("purpur")
	_jar(p.path_join("purpur.jar"), "io.papermc.paperclip.Main", "abc\t1.21.4\t1.21.4/purpur-1.21.4.jar\n", "1.21.4")
	var a := ServerImporter.analyze(p)
	check_eq(a.software, "purpur", "purpur via versions.list")
	check(a.can_import and a.warnings.size() > 0, "purpur importable with warning")
	var s := _fixture("spigot")
	_jar(s.path_join("spigot-1.20.4.jar"), "org.bukkit.craftbukkit.bootstrap.Main", "abc\t1.20.4\t1.20.4/spigot-1.20.4-R0.1-SNAPSHOT.jar\n")
	var b := ServerImporter.analyze(s)
	check_eq(b.software, "spigot", "spigot")
	check_eq(b.mc_version, "1.20.4", "spigot version from versions.list")
	check(b.can_import and b.needs_paper_switch, "spigot needs a Paper switch")
	var v := _fixture("vanilla")
	_jar(v.path_join("server.jar"), "net.minecraft.bundler.Main", "", "1.21.4")
	var c := ServerImporter.analyze(v)
	check_eq(c.software, "vanilla", "vanilla")
	check_eq(c.mc_version, "1.21.4", "vanilla version.json")
	check(c.needs_paper_switch, "vanilla needs a Paper switch")
	_cleanup()


func test_modded_and_proxies_are_refused() -> void:
	var f := _fixture("fabric")
	_jar(f.path_join("fabric-server-launch.jar"), "net.fabricmc.loader.impl.launch.server.FabricServerLauncher")
	var a := ServerImporter.analyze(f)
	check_eq(a.software, "fabric", "fabric")
	check(not a.can_import and a.error.contains("mods"), "fabric refused")
	var g := _fixture("forge")
	_write(g.path_join("run.sh"), "java @user_jvm_args.txt @libraries/net/minecraftforge/forge/1.20.1-47.2.0/unix_args.txt \"$@\"\n")
	_write(g.path_join("user_jvm_args.txt"), "-Xmx6G\n")
	var b := ServerImporter.analyze(g)
	check_eq(b.software, "forge", "forge from run.sh")
	check(not b.can_import, "forge refused")
	check_eq(b.ram_max_mb, 6144, "user_jvm_args.txt memory")
	var p := _fixture("velocity")
	_write(p.path_join("velocity.toml"), "bind = \"0.0.0.0:25577\"\n")
	_jar(p.path_join("velocity.jar"), "com.velocitypowered.proxy.Velocity")
	check(not ServerImporter.analyze(p).can_import, "proxy refused")
	var e := _fixture("empty")
	check(ServerImporter.analyze(e).error.contains("No Minecraft server jar"), "empty folder")
	_cleanup()


func test_memory_parsing() -> void:
	check_eq(ServerImporter.memory_mb("java -Xmx4096M -jar x.jar", "x"), 4096, "MB")
	check_eq(ServerImporter.memory_mb("java -Xmx2g", "x"), 2048, "lower-case g")
	check_eq(ServerImporter.memory_mb("java -Xms512m -Xmx3G", "s"), 512, "Xms")
	check_eq(ServerImporter.memory_mb("java -jar x.jar", "x"), 0, "absent")
