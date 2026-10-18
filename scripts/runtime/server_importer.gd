class_name ServerImporter
extends RefCounted
## Inspects an existing Minecraft server folder (one not created by the manager) and
## describes what it is, so it can be imported. Detection sources, most reliable first:
## the jar's META-INF/MANIFEST.MF Main-Class, META-INF/versions.list (names the bundled
## server, e.g. "1.21.11/paper-1.21.11.jar"), version.json (Minecraft version), the jar
## file name, Paper's version_history.json and logs/latest.log (build number).
## [method analyze] only reads files and is safe to run on a worker thread.

enum Kind { PAPER, BUKKIT, VANILLA, MODDED, PROXY, UNKNOWN }

const SOFTWARE_NAMES := {
	"paper": "Paper", "purpur": "Purpur", "folia": "Folia", "pufferfish": "Pufferfish",
	"spigot": "Spigot", "craftbukkit": "CraftBukkit", "vanilla": "Vanilla",
	"fabric": "Fabric", "quilt": "Quilt", "forge": "Forge", "neoforge": "NeoForge",
	"velocity": "Velocity", "bungeecord": "BungeeCord", "waterfall": "Waterfall", "unknown": "Unknown",
}
const START_SCRIPTS: PackedStringArray = [
	"start.sh", "run.sh", "start.bat", "run.bat", "start.cmd", "run.cmd", "start.command",
	"launch.sh", "server.sh", "user_jvm_args.txt",
]
## Flags the manager adds itself; never copied into extra JVM args.
const MANAGED_FLAG_PREFIXES: PackedStringArray = ["-Xmx", "-Xms", "-XX:", "-Dterminal.", "-Dusing.aikars", "-Daikars", "-Dcom.mojang.eula.agree"]

static var _re_version := RegEx.create_from_string("(?<![\\d.])(\\d+\\.\\d+(?:\\.\\d+)?)(?![\\d.])")
static var _re_paper_name := RegEx.create_from_string("^(?:paper|purpur|folia|pufferfish)-(\\d+\\.\\d+(?:\\.\\d+)?(?:-(?:pre|rc)\\d+)?)-(\\d+)\\.jar$")
static var _re_build_text := RegEx.create_from_string("(\\d+\\.\\d+(?:\\.\\d+)?)-(\\d+)-")
static var _re_mem := RegEx.create_from_string("-Xm([xs])(\\d+)([GgMmKk]?)\\b")
static var _re_jar_arg := RegEx.create_from_string("-jar\\s+\"?([^\\s\"]+\\.jar)")


## Describes [param dir]. Keys: dir, exists, managed, software, software_name, kind,
## jar, mc_version, build, port, level_name, motd, rcon_enabled, eula_accepted,
## ram_max_mb, ram_min_mb, aikar_flags, extra_jvm_args, plugins, worlds, world_bytes,
## running_pid, can_import, needs_paper_switch, warnings, error.
static func analyze(dir: String) -> Dictionary:
	dir = dir.strip_edges().trim_suffix("/")
	var r := {
		"dir": dir, "exists": DirAccess.dir_exists_absolute(dir), "managed": false,
		"software": "unknown", "software_name": "Unknown", "kind": Kind.UNKNOWN, "jar": "",
		"mc_version": "", "build": 0, "port": 25565, "level_name": "world", "motd": "",
		"rcon_enabled": false, "eula_accepted": false, "ram_max_mb": 0, "ram_min_mb": 0,
		"aikar_flags": false, "extra_jvm_args": "", "plugins": 0, "worlds": PackedStringArray(),
		"world_bytes": 0, "running_pid": -1, "can_import": false, "needs_paper_switch": false,
		"warnings": PackedStringArray(), "error": "",
	}
	if not r.exists:
		r.error = "That folder does not exist."
		return r
	if FileAccess.file_exists(dir.path_join(ServerConfig.META_DIR).path_join(ServerConfig.META_FILE)):
		r.managed = true
		r.can_import = true
		var cfg := ServerConfig.load_from_dir(dir)
		if cfg != null:
			r.software = "paper"
			r.software_name = "Paper (managed by Server Manager)"
			r.kind = Kind.PAPER
			r.mc_version = cfg.mc_version
			r.build = cfg.paper_build
			r.port = cfg.port
			r.jar = cfg.jar_file
		return r

	var props := ServerProperties.load_file(dir.path_join("server.properties"))
	r.port = props.get_int("server-port", 25565)
	r.level_name = props.get_value("level-name", "world")
	r.motd = props.get_value("motd", "")
	r.rcon_enabled = props.get_bool("enable-rcon")
	r.eula_accepted = _eula_accepted(dir)
	var script_text := _start_scripts_text(dir)
	_parse_memory(script_text, r)
	if script_text.contains("-Dcom.mojang.eula.agree=true"):
		r.eula_accepted = true

	_detect_software(dir, script_text, r)
	if r.mc_version == "":
		r.mc_version = _version_from_files(dir)
	if r.software in ["paper", "purpur", "folia", "pufferfish"] and r.build == 0:
		r.build = _build_from_files(dir, r.mc_version)

	r.plugins = _count_jars(dir.path_join("plugins"))
	var worlds := PackedStringArray()
	for d in DirAccess.get_directories_at(dir):
		if FileAccess.file_exists(dir.path_join(d).path_join("level.dat")):
			worlds.append(d)
	r.worlds = worlds
	var bytes := 0
	for w in worlds:
		bytes += dir_size(dir.path_join(w))
	r.world_bytes = bytes
	r.running_pid = PlatformBackend.get_current().find_java_in_dir(dir)

	match int(r.kind):
		Kind.PAPER:
			r.can_import = r.mc_version != ""
			if r.software != "paper":
				r.warnings.append("%s builds on Paper. The manager updates servers with official Paper builds, so updating would switch it to Paper." % r.software_name)
		Kind.BUKKIT, Kind.VANILLA:
			r.can_import = r.mc_version != ""
			r.needs_paper_switch = true
		Kind.MODDED:
			r.error = "%s servers run mods, which Paper cannot load. Only Paper (and Bukkit/Spigot/vanilla servers, which can be switched to Paper) can be imported." % r.software_name
		Kind.PROXY:
			r.error = "%s is a proxy, not a game server. Proxies are not supported yet." % r.software_name
		_:
			r.error = "No Minecraft server jar was found in this folder." if r.jar == "" else "Could not tell which server software %s is." % r.jar
	if r.can_import and r.mc_version == "":
		r.can_import = false
		r.error = "Could not determine the Minecraft version."
	if r.can_import and not r.eula_accepted:
		r.warnings.append("The Minecraft EULA has not been accepted in this folder yet.")
	if r.running_pid > 0:
		r.warnings.append("This server is running (PID %d). After import the manager attaches to it%s." % [r.running_pid,
				"" if r.rcon_enabled else "; without RCON the console is read-only until you restart it from the manager"])
	return r


## Total size in bytes of a directory tree (symlinks are not followed).
static func dir_size(path: String) -> int:
	var d := DirAccess.open(path)
	if d == null:
		return 0
	d.include_hidden = true
	var total := 0
	for f in d.get_files():
		var file := FileAccess.open(path.path_join(f), FileAccess.READ)
		if file != null:
			total += file.get_length()
	for sub in d.get_directories():
		if not d.is_link(sub):
			total += dir_size(path.path_join(sub))
	return total


## Parses -Xmx/-Xms (e.g. "-Xmx2G", "-Xms512M") into MB; 0 when absent.
static func memory_mb(text: String, which: String) -> int:
	for m in _re_mem.search_all(text):
		if m.get_string(1) != which:
			continue
		var n := m.get_string(2).to_int()
		match m.get_string(3).to_upper():
			"G":
				return n * 1024
			"K":
				return maxi(n / 1024, 1)
			"M":
				return n
			_:
				return maxi(n / 1048576, 1)  # Plain bytes.
	return 0


static func _parse_memory(script_text: String, r: Dictionary) -> void:
	r.ram_max_mb = memory_mb(script_text, "x")
	r.ram_min_mb = memory_mb(script_text, "s")
	r.aikar_flags = script_text.contains("aikars") or script_text.contains("mcflags.emc.gs")
	var extra := PackedStringArray()
	for token in Fmt.split_args(script_text.replace("\n", " ")):
		if not token.begins_with("-D"):
			continue
		var managed := false
		for prefix in MANAGED_FLAG_PREFIXES:
			if token.begins_with(prefix):
				managed = true
		if not managed and not extra.has(token):
			extra.append(token)
	r.extra_jvm_args = " ".join(extra)


static func _start_scripts_text(dir: String) -> String:
	var text := ""
	for f in START_SCRIPTS:
		var path := dir.path_join(f)
		if FileAccess.file_exists(path):
			text += FileAccess.get_file_as_string(path) + "\n"
	return text


static func _eula_accepted(dir: String) -> bool:
	var path := dir.path_join("eula.txt")
	if not FileAccess.file_exists(path):
		return false
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.strip_edges().replace(" ", "").to_lower() == "eula=true":
			return true
	return false


static func _detect_software(dir: String, script_text: String, r: Dictionary) -> void:
	# Pick the jar: the one the start script launches, else the best classified one.
	var jars := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".jar"):
			jars.append(f)
	var scripted := _re_jar_arg.search(script_text)
	var preferred := scripted.get_string(1).get_file() if scripted != null else ""
	var best := {}
	for jar in jars:
		var info := inspect_jar(dir.path_join(jar))
		info.jar = jar
		var score: int = info.score + (100 if jar == preferred else 0)
		if best.is_empty() or score > int(best.score_total):
			info.score_total = score
			best = info
	if not best.is_empty():
		r.jar = best.jar
		_set_software(r, best.software, best.kind)
		r.mc_version = best.mc_version
		r.build = best.build
	# A Paper/Bukkit jar is conclusive (Paper itself unpacks some net/neoforged and md-5
	# libraries). Otherwise look for loader/proxy markers that don't depend on one jar.
	if r.kind == Kind.PAPER or r.kind == Kind.BUKKIT:
		return
	var marker := ""
	if FileAccess.file_exists(dir.path_join("velocity.toml")):
		marker = "velocity"
	elif script_text.contains("libraries/net/neoforged/neoforge") or DirAccess.dir_exists_absolute(dir.path_join("libraries/net/neoforged/neoforge")):
		marker = "neoforge"
	elif script_text.contains("libraries/net/minecraftforge/forge") or DirAccess.dir_exists_absolute(dir.path_join("libraries/net/minecraftforge/forge")):
		marker = "forge"
	elif FileAccess.file_exists(dir.path_join("fabric-server-launch.jar")) or DirAccess.dir_exists_absolute(dir.path_join(".fabric")) \
			or DirAccess.dir_exists_absolute(dir.path_join("libraries/net/fabricmc/fabric-loader")):
		marker = "fabric"
	elif DirAccess.dir_exists_absolute(dir.path_join(".quilt")) or DirAccess.dir_exists_absolute(dir.path_join("libraries/org/quiltmc/quilt-loader")):
		marker = "quilt"
	if marker != "":
		_set_software(r, marker, Kind.PROXY if marker == "velocity" else Kind.MODDED)


static func _set_software(r: Dictionary, software: String, kind: Kind) -> void:
	r.software = software
	r.software_name = SOFTWARE_NAMES.get(software, software.capitalize())
	r.kind = kind


## Reads a jar's manifest, versions.list and version.json.
## Returns {software, kind, mc_version, build, score}.
static func inspect_jar(path: String) -> Dictionary:
	var out := {"software": "unknown", "kind": Kind.UNKNOWN, "mc_version": "", "build": 0, "score": 0}
	var file := path.get_file().to_lower()
	var name_match := _re_paper_name.search(file)
	if name_match != null:
		out.mc_version = name_match.get_string(1)
		out.build = name_match.get_string(2).to_int()
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return out
	var files := zip.get_files()
	var main_class := ""
	if files.has("META-INF/MANIFEST.MF"):
		for line in zip.read_file("META-INF/MANIFEST.MF").get_string_from_utf8().split("\n"):
			if line.begins_with("Main-Class:"):
				main_class = line.get_slice(":", 1).strip_edges()
	var bundled := ""
	if files.has("META-INF/versions.list"):
		var first := zip.read_file("META-INF/versions.list").get_string_from_utf8().strip_edges().get_slice("\n", 0)
		var cols := first.split("\t")
		if cols.size() >= 3:
			bundled = cols[2].get_file().to_lower()
			if out.mc_version == "":
				out.mc_version = cols[1]
	if files.has("version.json") and out.mc_version == "":
		var data = JSON.parse_string(zip.read_file("version.json").get_string_from_utf8())
		if data is Dictionary:
			out.mc_version = str(data.get("id", data.get("name", "")))
	zip.close()

	var lower_main := main_class.to_lower()
	if lower_main.contains("velocity"):
		_classify(out, "velocity", Kind.PROXY, 50)
	elif lower_main.contains("net.md_5.bungee"):
		_classify(out, "waterfall" if file.contains("waterfall") else "bungeecord", Kind.PROXY, 50)
	elif lower_main.contains("fabricmc"):
		_classify(out, "fabric", Kind.MODDED, 50)
	elif lower_main.contains("quiltmc"):
		_classify(out, "quilt", Kind.MODDED, 50)
	elif lower_main.contains("minecraftforge") or lower_main.contains("neoforged"):
		_classify(out, "neoforge" if lower_main.contains("neoforged") else "forge", Kind.MODDED, 50)
	elif lower_main.contains("paperclip") or lower_main.contains("purpurclip"):
		var sw := "paper"
		for fork in ["purpur", "folia", "pufferfish"]:
			if bundled.begins_with(fork) or file.contains(fork) or lower_main.contains(fork):
				sw = fork
		_classify(out, sw, Kind.PAPER, 60)
	elif lower_main.contains("org.bukkit.craftbukkit"):
		_classify(out, "spigot" if bundled.begins_with("spigot") or file.contains("spigot") else "craftbukkit", Kind.BUKKIT, 55)
	elif lower_main.contains("net.minecraft"):
		_classify(out, "vanilla", Kind.VANILLA, 40)
	elif out.build > 0:
		_classify(out, file.get_slice("-", 0), Kind.PAPER, 30)
	if out.mc_version == "":
		var m := _re_version.search(file)
		if m != null:
			out.mc_version = m.get_string(1)
	return out


static func _classify(out: Dictionary, software: String, kind: Kind, score: int) -> void:
	out.software = software
	out.kind = kind
	out.score = score


static func _version_from_files(dir: String) -> String:
	var history := dir.path_join("version_history.json")
	if FileAccess.file_exists(history):
		var data = JSON.parse_string(FileAccess.get_file_as_string(history))
		if data is Dictionary:
			var current := str(data.get("currentVersion", ""))
			var mc := current.find("(MC: ")
			if mc >= 0:
				return current.substr(mc + 5).trim_suffix(")").strip_edges()
	var log_text := _latest_log(dir)
	for marker in ["for Minecraft ", "Starting minecraft server version "]:
		var i := log_text.find(marker)
		if i >= 0:
			return log_text.substr(i + marker.length()).get_slice("\n", 0).strip_edges().get_slice(" ", 0)
	return ""


static func _build_from_files(dir: String, mc_version: String) -> int:
	var sources := PackedStringArray()
	var history := dir.path_join("version_history.json")
	if FileAccess.file_exists(history):
		sources.append(FileAccess.get_file_as_string(history))
	sources.append(_latest_log(dir))
	for text in sources:
		for m in _re_build_text.search_all(text):
			if mc_version == "" or m.get_string(1) == mc_version:
				return m.get_string(2).to_int()
	return 0


static func _latest_log(dir: String) -> String:
	var path := dir.path_join("logs/latest.log")
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	# The version lines are near the top; don't read huge logs entirely.
	return Ansi.strip(f.get_buffer(mini(f.get_length(), 65536)).get_string_from_utf8())


static func _count_jars(path: String) -> int:
	var n := 0
	for f in DirAccess.get_files_at(path) if DirAccess.dir_exists_absolute(path) else PackedStringArray():
		if f.ends_with(".jar"):
			n += 1
	return n
