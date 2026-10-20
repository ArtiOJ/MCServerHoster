class_name ModrinthApi
extends RefCounted
## Modrinth (modrinth.com) for the plugin browser: search, finding a build that runs on a
## given Paper server, recognising installed jars by hash and verified downloads.
## Search filters apply to a project as a whole (a project with a Paper build for 1.21 and a
## Fabric build for 26.3 matches "Paper" + "26.3"), so a project counts as compatible only
## when one of its versions is for a Paper-compatible loader and lists the server's version.
## API: https://docs.modrinth.com/api/ (no key needed; a descriptive User-Agent is required).

const BASE := "https://api.modrinth.com/v2"
const SITE := "https://modrinth.com/plugin/"
const USER_AGENT := "ArtiOJ/MCServerHoster/0.1.0 (Server Manager)"
## Loaders whose plugins Paper runs.
const LOADERS: PackedStringArray = ["paper", "spigot", "bukkit"]
const PAGE_SIZE := 20
## Sort orders the search supports, with their labels.
const SORTS: PackedStringArray = ["relevance", "downloads", "updated", "newest"]
const SORT_NAMES: PackedStringArray = ["Relevance", "Downloads", "Recently updated", "Newest"]
## Plugins Server Manager has its own support for; listed first. install_op installs them
## from their official source instead of Modrinth (which may lag behind).
## plugin_name is its plugin.yml name, to recognise it however it was installed.
const INTEGRATIONS := [
	{"slug": "luckperms", "plugin_name": "LuckPerms", "feature": "Permissions tab", "install_op": "perms_install"},
	{"slug": "chunky", "plugin_name": "Chunky", "feature": "Chunky tab"},
	{"slug": "bluemap", "plugin_name": "BlueMap", "feature": "BlueMap tab"},
]
const TIMEOUT_SEC := 20
const DOWNLOAD_TIMEOUT_SEC := 300

static var _icons := {}


# --- Queries --------------------------------------------------------------------------

## The search URL for plugins Paper can run on [param mc_version].
static func search_url(query: String, mc_version: String, offset := 0, sort := "relevance") -> String:
	var loaders := Array(LOADERS).map(func(l: String) -> String: return "categories:" + l)
	var facets := [["project_type:plugin"], loaders]
	if mc_version != "":
		facets.append(["versions:" + mc_version])
	return "%s/search?query=%s&facets=%s&index=%s&offset=%d&limit=%d" % [
		BASE, query.strip_edges().uri_encode(), JSON.stringify(facets).uri_encode(),
		sort if SORTS.has(sort) else "relevance", maxi(offset, 0), PAGE_SIZE]


## Searches plugins. Returns {ok, hits: [{project_id, slug, title, author, description,
## downloads, icon_url, date_modified}], total} or {ok: false, error}.
static func search(owner: Node, query: String, mc_version: String, offset := 0, sort := "relevance") -> Dictionary:
	var res := await _request(owner, search_url(query, mc_version, offset, sort))
	if not res.ok:
		return res
	var hits := []
	for h in res.data.get("hits", []):
		hits.append(_hit(h))
	return {"ok": true, "hits": hits, "total": int(res.data.get("total_hits", 0))}


static func _hit(h: Dictionary) -> Dictionary:
	return {
		"project_id": str(h.get("project_id", h.get("id", ""))), "slug": str(h.get("slug", "")),
		"title": str(h.get("title", "")), "author": str(h.get("author", "")),
		"description": str(h.get("description", "")), "downloads": int(h.get("downloads", 0)),
		"icon_url": str(h.get("icon_url", "")) if h.get("icon_url") != null else "",
		"date_modified": str(h.get("date_modified", h.get("updated", ""))),
	}


## One project by slug or ID, in the same shape as a search hit (plus game_versions, loaders).
static func project(owner: Node, slug_or_id: String) -> Dictionary:
	var res := await _request(owner, "%s/project/%s" % [BASE, slug_or_id.uri_encode()])
	if not res.ok:
		return res
	var hit := _hit(res.data)
	hit.game_versions = res.data.get("game_versions", [])
	hit.loaders = res.data.get("loaders", [])
	return {"ok": true, "project": hit}


## The newest build of [param project_id] that Paper can run on [param mc_version] (releases
## before betas). {ok, version} where version is {} when there is none, else
## {id, project_id, name, version_number, file: {url, filename, size, sha1},
## dependencies: [project ids of required plugins]}.
static func compatible_version(owner: Node, project_id: String, mc_version: String) -> Dictionary:
	var url := "%s/project/%s/version?loaders=%s&game_versions=%s" % [BASE, project_id.uri_encode(),
			JSON.stringify(Array(LOADERS)).uri_encode(), JSON.stringify([mc_version]).uri_encode()]
	var res := await _request(owner, url)
	if not res.ok:
		return res
	return {"ok": true, "version": pick_version(res.data if res.data is Array else [])}


## The best of [param versions] (Modrinth's list, newest first): releases before betas and
## alphas, and within those a Paper build before Spigot or Bukkit ones (projects such as
## BlueMap publish both, and the Spigot one runs worse on Paper); {} when none has a usable file.
static func pick_version(versions: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_rank := 99
	for v in versions:
		if not v is Dictionary:
			continue
		var parsed := _version(v)
		if parsed.is_empty():
			continue
		var loaders: Array = v.get("loaders", [])
		var rank := (0 if str(v.get("version_type", "")) == "release" else 2) + (0 if loaders.has("paper") else 1)
		if rank < best_rank:
			best = parsed
			best_rank = rank
	return best


static func _version(v: Dictionary) -> Dictionary:
	var files: Array = v.get("files", [])
	var file: Dictionary = {}
	for f in files:
		if f is Dictionary and (bool(f.get("primary", false)) or file.is_empty()) and str(f.get("filename", "")).ends_with(".jar"):
			file = f
	if file.is_empty():
		return {}
	var deps := []
	for d in v.get("dependencies", []):
		if d is Dictionary and str(d.get("dependency_type", "")) == "required" and d.get("project_id") != null:
			deps.append(str(d.project_id))
	var hashes: Dictionary = file.get("hashes", {})
	return {
		"id": str(v.get("id", "")), "project_id": str(v.get("project_id", "")), "name": str(v.get("name", "")),
		"version_number": str(v.get("version_number", "")), "dependencies": deps,
		"file": {"url": str(file.get("url", "")), "filename": str(file.get("filename", "")), "size": int(file.get("size", 0)),
				"sha1": str(hashes.get("sha1", ""))},
	}


## Which of [param sha1s] (installed jars) are Modrinth files: {ok, found: {sha1: {project_id, version_id}}}.
static func lookup_sha1(owner: Node, sha1s: Array) -> Dictionary:
	if sha1s.is_empty():
		return {"ok": true, "found": {}}
	var res := await _request(owner, BASE + "/version_files", HTTPClient.METHOD_POST,
			JSON.stringify({"hashes": sha1s, "algorithm": "sha1"}))
	if not res.ok:
		return res
	var found := {}
	if res.data is Dictionary:
		for sha in res.data:
			var v: Variant = res.data[sha]
			if v is Dictionary:
				found[str(sha)] = {"project_id": str(v.get("project_id", "")), "version_id": str(v.get("id", ""))}
	return {"ok": true, "found": found}


# --- Downloads ---------------------------------------------------------------------------

## Downloads [param url] to [param dest] (via a .part file) and checks its SHA-1 (Godot has
## no SHA-512; over HTTPS from Modrinth's CDN this guards against damaged downloads).
## Only files from Modrinth's CDN are accepted. Returns {ok} or {ok: false, error}.
static func download(owner: Node, url: String, dest: String, sha1: String) -> Dictionary:
	if not url.begins_with("https://cdn.modrinth.com/"):
		return {"ok": false, "error": "Not a Modrinth download."}
	var part := dest + ".part"
	var http := HTTPRequest.new()
	http.timeout = DOWNLOAD_TIMEOUT_SEC
	http.download_file = part
	owner.add_child(http)
	var err := http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT]))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS or response[1] != 200:
		DirAccess.remove_absolute(part)
		return {"ok": false, "error": "download failed (%s)" % ("HTTP %d" % response[1] if response[0] == HTTPRequest.RESULT_SUCCESS else "are you online?")}
	if sha1 == "" or file_hash(part) != sha1.to_lower():
		DirAccess.remove_absolute(part)
		return {"ok": false, "error": "the download is damaged (checksum mismatch)"}
	if FileAccess.file_exists(dest):
		DirAccess.remove_absolute(dest)
	err = DirAccess.rename_absolute(part, dest)
	return {"ok": err == OK, "error": "" if err == OK else error_string(err)}


## SHA-1 of a file as lowercase hex ("" if unreadable).
static func file_hash(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1 << 20))
	return ctx.finish().hex_encode()


## A project's icon as a texture (cached), or null.
static func icon(owner: Node, url: String) -> Texture2D:
	if url == "":
		return null
	if _icons.has(url):
		return _icons[url]
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	owner.add_child(http)
	if http.request(url, PackedStringArray(["User-Agent: " + USER_AGENT])) != OK:
		http.queue_free()
		return null
	var response: Array = await http.request_completed
	http.queue_free()
	var tex: Texture2D = null
	if response[0] == HTTPRequest.RESULT_SUCCESS and response[1] == 200:
		var body: PackedByteArray = response[3]
		var img := Image.new()
		var loaded := ERR_FILE_UNRECOGNIZED
		for loader in [img.load_png_from_buffer, img.load_webp_from_buffer, img.load_jpg_from_buffer]:
			loaded = loader.call(body)
			if loaded == OK:
				break
		if loaded == OK:
			img.resize(48, 48, Image.INTERPOLATE_LANCZOS)
			tex = ImageTexture.create_from_image(img)
	_icons[url] = tex
	return tex


# --- Plumbing ----------------------------------------------------------------------------

static func _request(owner: Node, url: String, method := HTTPClient.METHOD_GET, body := "") -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SEC
	owner.add_child(http)
	var headers := PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: application/json"])
	if body != "":
		headers.append("Content-Type: application/json")
	var err := http.request(url, headers, method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Could not contact Modrinth (%s)." % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	if response[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "Could not reach Modrinth. Are you online?"}
	if response[1] == 429:
		return {"ok": false, "error": "Modrinth is busy (too many requests); try again in a minute."}
	if response[1] == 404:
		return {"ok": false, "error": "Not found on Modrinth."}
	if response[1] != 200:
		return {"ok": false, "error": "Modrinth answered HTTP %d." % response[1]}
	var data: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if data == null:
		return {"ok": false, "error": "Unexpected answer from Modrinth."}
	return {"ok": true, "data": data}
