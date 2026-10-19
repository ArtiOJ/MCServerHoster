extends Node
## Client for PaperMC's Fill v3 download API.
## Docs: https://docs.papermc.io/misc/downloads-service

const BASE_URL := "https://fill.papermc.io/v3/projects/paper"
const USER_AGENT := "GodotServerManager/0.1 (local Paper server manager)"
const CACHE_DIR := "user://cache/jars"

var _versions_cache: Array[Dictionary] = []
var _version_info_cache := {}


## Returns {ok, versions: Array[{id, family, prerelease}], error}. Newest first.
func fetch_versions(force := false) -> Dictionary:
	if not _versions_cache.is_empty() and not force:
		return {"ok": true, "versions": _versions_cache}
	var res := await _get_json(BASE_URL)
	if not res.ok:
		return res
	var families: Dictionary = res.data.get("versions", {})
	var out: Array[Dictionary] = []
	for family in families:
		for v in families[family]:
			var id := str(v)
			var pre := id.contains("-pre") or id.contains("-rc") or id.contains("snapshot") or id.contains("-beta")
			out.append({"id": id, "family": str(family), "prerelease": pre})
	_versions_cache = out
	return {"ok": true, "versions": out}


## Returns {ok, java_min, flags: PackedStringArray, support: String, error}.
func fetch_version_info(version: String) -> Dictionary:
	if _version_info_cache.has(version):
		return _version_info_cache[version]
	var res := await _get_json("%s/versions/%s" % [BASE_URL, version.uri_encode()])
	if not res.ok:
		return res
	var v: Dictionary = res.data.get("version", {})
	var java: Dictionary = v.get("java", {})
	var info := {
		"ok": true,
		"java_min": int(java.get("version", {}).get("minimum", 21)),
		"flags": PackedStringArray(java.get("flags", {}).get("recommended", [])),
		"support": str(v.get("support", {}).get("status", "UNKNOWN")),
		"build_count": (res.data.get("builds", []) as Array).size(),
	}
	_version_info_cache[version] = info
	return info


## Latest build for a version, preferring STABLE. Returns {ok, build, error} where build is
## {id, channel, url, sha256, name, size, time}.
func fetch_latest_build(version: String, allow_unstable := true) -> Dictionary:
	var url := "%s/versions/%s/builds" % [BASE_URL, version.uri_encode()]
	var res := await _get_json(url + "?channel=STABLE")
	if res.ok and res.data is Array and not (res.data as Array).is_empty():
		return {"ok": true, "build": _parse_build(res.data[0])}
	if not allow_unstable:
		return {"ok": false, "error": "No stable build is available for %s yet." % version}
	res = await _get_json(url)
	if res.ok and res.data is Array and not (res.data as Array).is_empty():
		return {"ok": true, "build": _parse_build(res.data[0])}
	return {"ok": false, "error": res.get("error", "No builds found for %s." % version)}


## One specific build. Returns {ok, build, error} (build as in [method fetch_latest_build]).
func fetch_build(version: String, build_id: int) -> Dictionary:
	var res := await _get_json("%s/versions/%s/builds/%d" % [BASE_URL, version.uri_encode(), build_id])
	if res.ok and res.data is Dictionary and (res.data as Dictionary).has("id"):
		return {"ok": true, "build": _parse_build(res.data)}
	return {"ok": false, "error": res.get("error", "Paper %s has no build #%d." % [version, build_id])}


## Downloads a build to [param dest_path], verifying its SHA-256 and using a shared cache.
## [param on_progress] is called with (downloaded_bytes, total_bytes).
func download_build(build: Dictionary, dest_path: String, on_progress := Callable()) -> Dictionary:
	var sha: String = build.sha256
	var cache_dir := ProjectSettings.globalize_path(CACHE_DIR)
	DirAccess.make_dir_recursive_absolute(cache_dir)
	var cached := cache_dir.path_join(sha + ".jar")

	if not (FileAccess.file_exists(cached) and sha256_file(cached) == sha):
		var part := cached + ".part"
		var http := HTTPRequest.new()
		http.download_file = part
		http.download_chunk_size = 262144
		http.timeout = 300
		add_child(http)
		var state := {"done": false, "result": 0, "code": 0}
		http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
			state.done = true
			state.result = result
			state.code = code)
		var err := http.request(build.url, _headers())
		if err != OK:
			http.queue_free()
			return {"ok": false, "error": "Could not start download: %s" % error_string(err)}
		while not state.done:
			if on_progress.is_valid():
				on_progress.call(http.get_downloaded_bytes(), maxi(http.get_body_size(), int(build.get("size", 0))))
			await get_tree().create_timer(0.1).timeout
		http.queue_free()
		if state.result != HTTPRequest.RESULT_SUCCESS or state.code != 200:
			DirAccess.remove_absolute(part)
			return {"ok": false, "error": "Download failed (%s, HTTP %d)." % [_result_text(state.result), state.code]}
		var actual := sha256_file(part)
		if actual != sha:
			DirAccess.remove_absolute(part)
			return {"ok": false, "error": "Checksum mismatch: the download is corrupt (expected %s…, got %s…)." % [sha.left(12), actual.left(12)]}
		DirAccess.rename_absolute(part, cached)
	if on_progress.is_valid():
		on_progress.call(int(build.get("size", 1)), int(build.get("size", 1)))

	var tmp := dest_path + ".new"
	var copy_err := DirAccess.copy_absolute(cached, tmp)
	if copy_err != OK:
		return {"ok": false, "error": "Could not copy jar: %s" % error_string(copy_err)}
	if FileAccess.file_exists(dest_path):
		DirAccess.remove_absolute(dest_path)
	DirAccess.rename_absolute(tmp, dest_path)
	return {"ok": true}


static func sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(1048576))
	return ctx.finish().hex_encode()


func _parse_build(b: Dictionary) -> Dictionary:
	var dl: Dictionary = b.get("downloads", {}).get("server:default", {})
	return {
		"id": int(b.get("id", 0)),
		"channel": str(b.get("channel", "STABLE")),
		"time": str(b.get("time", "")),
		"url": str(dl.get("url", "")),
		"sha256": str(dl.get("checksums", {}).get("sha256", "")),
		"name": str(dl.get("name", "")),
		"size": int(dl.get("size", 0)),
	}


func _headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: application/json"])


func _get_json(url: String) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 20
	add_child(http)
	var err := http.request(url, _headers())
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "Request failed: %s" % error_string(err)}
	var response: Array = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	var code: int = response[1]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "error": "Network error: %s" % _result_text(result)}
	if code != 200:
		return {"ok": false, "error": "PaperMC API returned HTTP %d." % code}
	var data = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	if data == null:
		return {"ok": false, "error": "Invalid response from PaperMC API."}
	return {"ok": true, "data": data}


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "cannot reach PaperMC (are you online?)"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
		HTTPRequest.RESULT_DOWNLOAD_FILE_WRITE_ERROR, HTTPRequest.RESULT_DOWNLOAD_FILE_CANT_OPEN:
			return "cannot write the downloaded file"
		_:
			return "error %d" % result
