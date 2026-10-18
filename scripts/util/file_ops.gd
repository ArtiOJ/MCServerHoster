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
