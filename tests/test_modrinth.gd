extends TestCase


func test_search_url_filters_for_paper_and_the_version() -> void:
	var url := ModrinthApi.search_url("vein miner", "26.3", 40, "downloads")
	var facets: Variant = JSON.parse_string(url.get_slice("facets=", 1).get_slice("&", 0).uri_decode())
	check_eq(facets, [["project_type:plugin"], ["categories:paper", "categories:spigot", "categories:bukkit"], ["versions:26.3"]], "plugin type, Paper-compatible loaders, version")
	check(url.contains("query=vein%20miner") and url.contains("offset=40") and url.contains("index=downloads"), "query, page and sort: " + url)
	check(ModrinthApi.search_url("", "26.3", 0, "nonsense").contains("index=relevance"), "unknown sort falls back to relevance")


func test_picks_a_build() -> void:
	var jar := func(name: String, primary := true) -> Dictionary:
		return {"filename": name, "url": "https://cdn.modrinth.com/x/" + name, "size": 10, "primary": primary, "hashes": {"sha1": "ab", "sha512": "cd"}}
	var versions := [
		{"id": "beta2", "version_type": "beta", "version_number": "2.0-beta", "files": [jar.call("p-2.jar")], "dependencies": []},
		{"id": "rel1", "version_type": "release", "version_number": "1.9", "project_id": "P",
				"files": [jar.call("p-1.9-sources.jar", false), jar.call("p-1.9.jar")],
				"dependencies": [{"project_id": "DEP", "dependency_type": "required"}, {"project_id": "OPT", "dependency_type": "optional"}, {"project_id": null, "dependency_type": "required"}]},
	]
	var v := ModrinthApi.pick_version(versions)
	check_eq(v.id, "rel1", "newest release preferred over a newer beta")
	check_eq(v.file.filename, "p-1.9.jar", "primary jar chosen")
	check_eq(v.dependencies, ["DEP"], "only required dependencies with a project")
	check_eq(ModrinthApi.pick_version([versions[0]]).id, "beta2", "a beta when there is no release")
	check(ModrinthApi.pick_version([{"id": "z", "version_type": "release", "files": [{"filename": "readme.txt", "primary": true}]}]).is_empty(), "no jar, no build")
	check(ModrinthApi.pick_version([]).is_empty(), "none")


func test_hashes_files() -> void:
	var path := ProjectSettings.globalize_path("user://test-modrinth-hash.bin")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("abc")
	f.close()
	check_eq(ModrinthApi.file_hash(path), "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 of \"abc\"")
	DirAccess.remove_absolute(path)
	check_eq(ModrinthApi.file_hash(path), "", "missing file")
