class_name FileOps
extends RefCounted
## Filesystem helpers: recursive copy/delete, and running blocking work on a
## worker thread without freezing the UI.


## Runs [param work] on a worker thread and returns its result once finished.
## [param owner] must be inside the scene tree (used for timers while waiting).
static func run_async(owner: Node, work: Callable) -> Variant:
	var thread := Thread.new()
	thread.start(work)
	while thread.is_alive():
		await owner.get_tree().create_timer(0.1).timeout
	return thread.wait_to_finish()


## Copies [param src] to [param dst] (which must not exist yet), using the fastest method
## the platform offers. Thread-safe.
static func copy_tree(src: String, dst: String) -> Error:
	return PlatformBackend.get_current().copy_tree(src, dst)


## Portable recursive copy used when no faster platform tool is available. Thread-safe.
static func copy_tree_portable(src: String, dst: String) -> Error:
	var dir := DirAccess.open(src)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	var err := DirAccess.make_dir_recursive_absolute(dst)
	if err != OK:
		return err
	for f in dir.get_files():
		err = DirAccess.copy_absolute(src.path_join(f), dst.path_join(f))
		if err != OK:
			return err
	for d in dir.get_directories():
		if dir.is_link(d):
			continue
		err = copy_tree_portable(src.path_join(d), dst.path_join(d))
		if err != OK:
			return err
	return OK


## Permanently deletes a directory tree without following symlinks. Thread-safe.
static func remove_tree(path: String) -> Error:
	var dir := DirAccess.open(path)
	if dir == null:
		return DirAccess.get_open_error()
	dir.include_hidden = true
	for f in dir.get_files():
		dir.remove(f)
	for d in dir.get_directories():
		if dir.is_link(d):
			dir.remove(d)
		else:
			remove_tree(path.path_join(d))
	return DirAccess.remove_absolute(path)


## Removes a file or directory if it exists. Thread-safe.
static func remove_path(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		remove_tree(path)
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Zips [param src] into [param zip_path]: its contents at the top of the zip, or with
## [param keep_root] inside a folder named like [param src]. Returns "" or an error message.
## Thread-safe.
static func zip_folder(src: String, zip_path: String, keep_root := false) -> String:
	var zip := ZIPPacker.new()
	var err := zip.open(zip_path)
	if err != OK:
		return "Cannot create %s (%s)." % [zip_path.get_file(), error_string(err)]
	var result := _zip_dir(zip, src, src.trim_suffix("/").get_file() if keep_root else "")
	zip.close()
	return result


static func _zip_dir(zip: ZIPPacker, dir_path: String, prefix: String) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return "Cannot read %s." % dir_path
	dir.include_hidden = true
	for f in dir.get_files():
		var file := FileAccess.open(dir_path.path_join(f), FileAccess.READ)
		if file == null:
			continue
		zip.start_file(prefix.path_join(f) if prefix != "" else f)
		while file.get_position() < file.get_length():
			zip.write_file(file.get_buffer(1048576))
		zip.close_file()
	for d in dir.get_directories():
		if dir.is_link(d):
			continue
		var err := _zip_dir(zip, dir_path.path_join(d), prefix.path_join(d) if prefix != "" else d)
		if err != "":
			return err
	return ""
