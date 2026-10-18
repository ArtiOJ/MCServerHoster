class_name BackupService
extends Node
## Creates, lists, restores and prunes zip backups of a server. Zipping runs on a
## worker thread; while the server is online, autosaving is paused and the world
## flushed first so the archive is consistent.

signal busy_changed(busy: bool)
signal progress_changed(fraction: float)
signal backups_changed

const SAVE_TIMEOUT_MS := 60000
## Never included in any backup.
const EXCLUDED_DIRS: PackedStringArray = [".manager", "cache", "libraries", "versions", "logs", "crash-reports"]
const EXCLUDED_FILES: PackedStringArray = ["session.lock"]

var busy := false
var instance: ServerInstance

var _thread: Thread
var _mutex := Mutex.new()
var _progress := 0.0
var _world_saved := false


func _ready() -> void:
	instance = get_parent() as ServerInstance


func backup_dir() -> String:
	return AppSettings.backups_root().path_join(instance.config.id)


## Newest first: [{path, name, size, time, full}].
func list_backups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(backup_dir())
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".zip"):
			continue
		var path := backup_dir().path_join(f)
		var file := FileAccess.open(path, FileAccess.READ)
		out.append({
			"path": path,
			"name": f,
			"size": file.get_length() if file != null else 0,
			"time": FileAccess.get_modified_time(path),
			"full": f.ends_with("_full.zip"),
			"safety": f.ends_with("_pre-restore.zip") or f.ends_with("_pre-keep.zip"),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.time > b.time)
	return out


## Pauses autosave and flushes all worlds to disk so files can be copied consistently.
## Returns true when the server was online (call [method resume_saving] afterwards).
func pause_saving() -> bool:
	if not instance.is_online():
		return false
	instance.log_system("Pausing autosave and flushing the world to disk…")
	_world_saved = false
	instance.send_command("save-off", false)
	instance.send_command("save-all flush", false)
	var deadline := Time.get_ticks_msec() + SAVE_TIMEOUT_MS
	while not _world_saved and Time.get_ticks_msec() < deadline and instance.is_online():
		await get_tree().create_timer(0.2).timeout
	return true


func resume_saving() -> void:
	if instance.is_online():
		instance.send_command("save-on", false)


func on_console_line(plain: String) -> void:
	if LogParser.is_world_saved(plain):
		_world_saved = true


## Creates a backup of [param source_dir] (default: the folder the server runs in).
## [param tag] names automatic safety backups (e.g. "pre-restore"). Returns the archive
## path, or "" on failure.
func create_backup(full: bool, source_dir := "", tag := "") -> String:
	if busy:
		Notifier.warn("A backup of %s is already running." % instance.config.display_name)
		return ""
	_set_busy(true)
	var base := source_dir if source_dir != "" else instance.working_directory()
	var stamp := Fmt.file_stamp(int(Time.get_unix_time_from_system()))
	var kind := tag if tag != "" else ("full" if full else "world")
	var out_path := backup_dir().path_join("%s_%s.zip" % [stamp, kind])
	DirAccess.make_dir_recursive_absolute(backup_dir())

	var was_online := await pause_saving() if base == instance.working_directory() else false

	var roots := PackedStringArray([""]) if full else world_dirs(base)
	_progress = 0.0
	_thread = Thread.new()
	_thread.start(_zip_worker.bind(base, roots, out_path))
	while _thread.is_alive():
		await get_tree().create_timer(0.15).timeout
		_mutex.lock()
		var p := _progress
		_mutex.unlock()
		progress_changed.emit(p)
	var err: String = _thread.wait_to_finish()
	_thread = null

	if was_online:
		resume_saving()

	if err != "":
		DirAccess.remove_absolute(out_path)
		instance.log_system("Backup failed: " + err, LogParser.Level.ERROR)
		Notifier.error("Backup of %s failed: %s" % [instance.config.display_name, err])
		_set_busy(false)
		return ""

	_prune()
	instance.log_system("Backup created: " + out_path.get_file())
	Notifier.success("Backup of %s created." % instance.config.display_name)
	_set_busy(false)
	backups_changed.emit()
	return out_path


## Restores a backup into the server folder. The server must be stopped. A safety
## backup of the current worlds is saved first; then the world folders contained in
## the archive are deleted and replaced.
func restore_backup(path: String) -> Error:
	if busy:
		return ERR_BUSY
	if instance.is_process_alive():
		return ERR_ALREADY_IN_USE
	if not world_dirs().is_empty():
		instance.log_system("Saving a safety backup of the current worlds before restoring…")
		if await create_backup(false, "", "pre-restore") == "":
			return FAILED
	_set_busy(true)
	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		_set_busy(false)
		return err
	var top_dirs := {}
	for f in reader.get_files():
		var first := f.get_slice("/", 0)
		if f.contains("/") and not EXCLUDED_DIRS.has(first):
			top_dirs[first] = true
	reader.close()
	for d in top_dirs:
		var abs_dir := instance.working_directory().path_join(d)
		if DirAccess.dir_exists_absolute(abs_dir):
			await FileOps.run_async(self, func() -> Error: return FileOps.remove_tree(abs_dir))

	_progress = 0.0
	_thread = Thread.new()
	_thread.start(_unzip_worker.bind(path, instance.working_directory()))
	while _thread.is_alive():
		await get_tree().create_timer(0.15).timeout
		_mutex.lock()
		var p := _progress
		_mutex.unlock()
		progress_changed.emit(p)
	var result: String = _thread.wait_to_finish()
	_thread = null
	_set_busy(false)
	if result != "":
		instance.log_system("Restore failed: " + result, LogParser.Level.ERROR)
		return FAILED
	instance.log_system("Restored backup " + path.get_file())
	return OK


func delete_backup(path: String) -> void:
	if path.get_base_dir() == backup_dir():
		DirAccess.remove_absolute(path)
		backups_changed.emit()


func _prune() -> void:
	var keep := instance.config.backup_retention
	if keep <= 0:
		return
	var all := list_backups()
	for i in range(keep, all.size()):
		DirAccess.remove_absolute(all[i].path)


## World folders present in [param base] (default: the folder the server runs in).
func world_dirs(base := "") -> PackedStringArray:
	var dir := base if base != "" else instance.working_directory()
	var level := ServerProperties.load_file(dir.path_join("server.properties")).get_value("level-name", "world")
	var out := PackedStringArray()
	for d in [level, level + "_nether", level + "_the_end"]:
		if DirAccess.dir_exists_absolute(dir.path_join(d)):
			out.append(d)
	return out


func _set_busy(value: bool) -> void:
	busy = value
	busy_changed.emit(value)


func _set_progress(value: float) -> void:
	_mutex.lock()
	_progress = value
	_mutex.unlock()


# --- Worker-thread code: touches only the filesystem and the mutex-guarded progress. ---

func _zip_worker(base: String, roots: PackedStringArray, out_path: String) -> String:
	if roots.is_empty():
		return "There is no world to back up yet (start the server once first)."
	var files := PackedStringArray()
	var total_bytes := 0
	for r in roots:
		total_bytes += _collect(base, r, files)
	var zip := ZIPPacker.new()
	var err := zip.open(out_path)
	if err != OK:
		return "cannot create archive (%s)" % error_string(err)
	var done_bytes := 0
	for rel in files:
		var f := FileAccess.open(base.path_join(rel), FileAccess.READ)
		if f == null:
			continue  # File vanished or is unreadable; skip rather than fail the whole backup.
		zip.start_file(rel)
		while f.get_position() < f.get_length():
			var chunk := f.get_buffer(1048576)
			zip.write_file(chunk)
			done_bytes += chunk.size()
			_set_progress(float(done_bytes) / maxf(total_bytes, 1.0))
		zip.close_file()
	zip.close()
	return ""


func _collect(base: String, rel: String, files: PackedStringArray) -> int:
	var dir := DirAccess.open(base.path_join(rel))
	if dir == null:
		return 0
	dir.include_hidden = true
	var bytes := 0
	for f in dir.get_files():
		if EXCLUDED_FILES.has(f) or f.ends_with(".tmp"):
			continue
		var path := rel.path_join(f) if rel != "" else f
		var file := FileAccess.open(base.path_join(path), FileAccess.READ)
		if file != null:
			bytes += file.get_length()
			files.append(path)
	for d in dir.get_directories():
		if rel == "" and EXCLUDED_DIRS.has(d):
			continue
		bytes += _collect(base, rel.path_join(d) if rel != "" else d, files)
	return bytes


func _unzip_worker(zip_path: String, dest: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "cannot open archive"
	var names := reader.get_files()
	for i in names.size():
		var rel := names[i]
		if rel.contains("..") or rel.begins_with("/"):
			continue  # Never write outside the server folder.
		var target := dest.path_join(rel)
		if rel.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target)
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			reader.close()
			return "cannot write %s" % rel
		f.store_buffer(reader.read_file(rel))
		f.close()
		_set_progress(float(i + 1) / names.size())
	reader.close()
	return ""
