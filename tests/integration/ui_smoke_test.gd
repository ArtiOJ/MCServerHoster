extends Node
## Drives the real main scene with a live Paper server and saves screenshots of
## every view. Must run with a display (not --headless).
## Usage: godot --path . res://tests/integration/ui_smoke_test.tscn -- --no-autostart --profile=ui --root=<dir> --shots=<dir>

const MAIN_SCENE := preload("res://scenes/main/main.tscn")

var _shots := ""


func _ready() -> void:
	var root := ProjectSettings.globalize_path("user://ui-test-servers")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.get_slice("=", 1)
		elif arg.begins_with("--shots="):
			_shots = arg.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(_shots)
	# The app only redraws on change; screenshots need a frame every tick.
	OS.low_processor_usage_mode = false
	AppSettings.server_dirs = PackedStringArray()
	AppSettings.servers_root = root
	get_window().size = Vector2i(1440, 900)

	var version := "1.21.11"
	var vinfo: Dictionary = await PaperApi.fetch_version_info(version)
	var latest: Dictionary = await PaperApi.fetch_latest_build(version)
	var created: Dictionary = await ServerManager.create_server({
		"name": "Survival", "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 2048, "ram_min_mb": 512, "port": ServerManager.allocate_game_port(),
		"properties": {"online-mode": "false", "level-type": "minecraft:flat", "view-distance": "4", "motd": "§aWelcome to §lSurvival"},
	})
	var created2: Dictionary = await ServerManager.create_server({
		"name": "Creative Build", "color": Color("5aa9f2"), "version": version, "build": latest.build, "version_info": vinfo,
		"ram_max_mb": 3072, "port": ServerManager.allocate_game_port(), "properties": {"gamemode": "creative"},
	})
	var inst: ServerInstance = created.instance
	inst.config.cpu_quota_pct = 300
	var s := ScheduleEntry.new()
	inst.config.schedules.append(s)
	inst.save_config()

	var main: Control = MAIN_SCENE.instantiate()
	add_child(main)
	await _frames(10)
	inst.start()
	await _wait_for(func() -> bool: return inst.is_online(), 240.0)
	await _wait_for(func() -> bool: return inst.tps >= 0.0, 20.0)
	await get_tree().create_timer(4.0).timeout
	main.show_dashboard()
	await _shot("01_dashboard")

	main.show_server(inst.config.id)
	var tabs: TabContainer = main.get_node("%ServerView").get_node("%Tabs")
	for i in tabs.get_tab_count():
		tabs.current_tab = i
		await _shot("%02d_tab_%s" % [i + 2, tabs.get_tab_title(i).to_lower()])
	tabs.current_tab = 1

	var wizard: NewServerWizard = main.get_node("%NewServerWizard")
	wizard.open()
	await _shot("20_wizard_basics")
	wizard.get_node("%NextButton").pressed.emit()
	await get_tree().create_timer(3.0).timeout
	await _shot("21_wizard_version")
	wizard.get_node("%NextButton").pressed.emit()
	await _shot("22_wizard_resources")
	wizard.get_node("%NextButton").pressed.emit()
	await _shot("23_wizard_gameplay")
	wizard.get_node("%NextButton").pressed.emit()
	await _shot("24_wizard_review")
	wizard.hide()

	main.get_node("%AppSettingsDialog").open()
	await _shot("30_settings")
	main.get_node("%AppSettingsDialog").hide()
	main.get_node("%UpdateDialog").open(created2.instance)
	await get_tree().create_timer(2.0).timeout
	await _shot("31_update")
	main.get_node("%UpdateDialog").hide()
	main.get_node("%DeleteServerDialog").open(created2.instance)
	await _shot("32_delete")
	main.get_node("%DeleteServerDialog").hide()
	main.get_node("%QuitDialog").open()
	await _shot("33_quit")
	main.get_node("%QuitDialog").hide()

	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	main.show_server(inst.config.id)
	tabs.current_tab = 0
	await _shot("40_overview_stopped")
	for i in ServerManager.get_instances().duplicate():
		ServerManager.delete_server(i.config.id, true, false, true)
	print("UI smoke test finished")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(_shots.path_join(name + ".png"))


func _wait_for(cond: Callable, timeout_sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000)
	while not cond.call() and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.25).timeout
