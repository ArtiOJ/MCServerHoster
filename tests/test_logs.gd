extends TestCase

const CRASH_FIXTURE := "res://tests/fixtures/crash_bind_1_21_11.txt"


func _fixture_dir() -> String:
	var dir := ProjectSettings.globalize_path("user://test-logs-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir.path_join("logs"))
	DirAccess.make_dir_recursive_absolute(dir.path_join("crash-reports"))
	return dir


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


func _write_gz(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(text.to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP))


func test_discovery_and_order() -> void:
	var dir := _fixture_dir()
	_write_gz(dir.path_join("logs/2026-10-18-1.log.gz"), "[10:00:00] [Server thread/INFO]: one\n")
	_write_gz(dir.path_join("logs/2026-10-18-2.log.gz"), "[11:00:00] [Server thread/INFO]: two\n")
	_write(dir.path_join("logs/latest.log"), "[12:00:00] [Server thread/INFO]: now\n")
	_write(dir.path_join("crash-reports/crash-2026-10-18_11.30.00-server.txt"), "---- Minecraft Crash Report ----\n")
	_write(dir.path_join("crash-reports/notes.md"), "ignored")
	var entries := LogArchive.list_entries(dir)
	check_eq(entries.size(), 4, "latest, two archives, one crash (other files ignored)")
	check_eq(entries[0].kind, LogArchive.Kind.CURRENT, "current session first")
	check_eq(entries[0].label, "Current session", "current label")
	var kinds := entries.map(func(e: Dictionary) -> int: return e.kind)
	check(kinds.has(LogArchive.Kind.CRASH), "crash listed")
	var crash: Dictionary = entries.filter(func(e: Dictionary) -> bool: return e.kind == LogArchive.Kind.CRASH)[0]
	check_eq(crash.time, LogArchive.crash_time_from_name(crash.name), "crash time from file name")
	check(crash.label.begins_with("Crash · 2026-10-18 11:30"), "crash label: " + crash.label)
	var archives := entries.filter(func(e: Dictionary) -> bool: return e.kind == LogArchive.Kind.ARCHIVE)
	check_eq(archives[0].label, "2026-10-18 · session 2", "newest archive first (same mtime, higher session)")
	check_eq(archives[1].label, "2026-10-18 · session 1", "older archive second")
	check_eq(LogArchive.list_entries(dir.path_join("missing")).size(), 0, "missing folder gives no entries")
	FileOps.remove_tree(dir)


func test_gzip_and_plain_reading() -> void:
	var dir := _fixture_dir()
	var text := "[10:00:00] [Server thread/INFO]: hello\n[10:00:01] [Server thread/WARN]: careful\n"
	_write_gz(dir.path_join("logs/2026-10-18-1.log.gz"), text)
	var gz := LogArchive.read_text(dir.path_join("logs/2026-10-18-1.log.gz"))
	check(gz.ok, "gz read ok")
	check_eq(gz.text, text, "gz content round-trips")
	_write(dir.path_join("logs/broken.log.gz"), "this is not gzip")
	var broken := LogArchive.read_text(dir.path_join("logs/broken.log.gz"))
	check(not broken.ok and broken.error.contains("damaged"), "corrupt archive reported")
	_write(dir.path_join("logs/latest.log"), text)
	check_eq(LogArchive.read_text(dir.path_join("logs/latest.log")).text, text, "plain read")
	check(not LogArchive.read_text(dir.path_join("logs/gone.log")).ok, "missing file reported")
	FileOps.remove_tree(dir)


func test_filtering() -> void:
	var text := "\n".join([
		"[10:00:00] [Server thread/INFO]: Starting",
		"[10:00:01] [Server thread/WARN]: Can't keep up!",
		"[10:00:02] [Server thread/ERROR]: Encountered an unexpected exception",
		"java.lang.IllegalStateException: boom",
		"\tat net.minecraft.Foo.bar(Foo.java:1)",
		"[10:00:03] [Server thread/INFO]: Steve joined the game",
	])
	var all := LogArchive.filter_lines(text, "", 0, 100)
	check_eq(all.total, 6, "total lines")
	check_eq(all.lines.size(), 6, "all shown")
	var errors := LogArchive.filter_lines(text, "", 2, 100)
	check_eq(errors.lines.size(), 3, "error plus its stack trace lines")
	var warn := LogArchive.filter_lines(text, "", 1, 100)
	check_eq(warn.lines.size(), 4, "warnings and errors")
	var search := LogArchive.filter_lines(text, "STEVE", 0, 100)
	check_eq(search.lines, PackedStringArray(["[10:00:03] [Server thread/INFO]: Steve joined the game"]), "case-insensitive search")
	var capped := LogArchive.filter_lines(text, "", 0, 2)
	check(capped.truncated and capped.lines.size() == 2 and capped.lines[1].contains("Steve"), "keeps the last lines when capped")
	var long := LogArchive.filter_lines("x".repeat(LogArchive.MAX_LINE_CHARS + 50), "", 0, 10)
	check(long.lines[0].length() < LogArchive.MAX_LINE_CHARS + 10, "very long lines shortened")


func test_crash_summary_from_real_report() -> void:
	var text := FileAccess.get_file_as_string(CRASH_FIXTURE)
	check(text.length() > 1000, "fixture loaded")
	var s := LogArchive.summarize_crash(text)
	check_eq(s.time, "2026-10-18 20:37:50", "time")
	check_eq(s.description, "Exception in server tick loop", "description")
	check_eq(s.exception, "java.lang.IllegalStateException: Failed to bind to port", "first exception")
	check(s.cause.contains("Address already in use"), "cause: " + s.cause)
	check_eq(s.minecraft, "1.21.11", "minecraft version")
	check(s.server.begins_with("Paper version 1.21.11-132"), "paper version: " + s.server)
	check(s.hint.contains("already in use"), "plain-language hint: " + s.hint)
	check_eq(LogArchive.summarize_crash("nothing useful").hint, "", "no hint for unknown text")
