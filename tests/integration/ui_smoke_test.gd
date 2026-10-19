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
	inst.config.events.append(EventRule.from_template(EventRule.templates()[2][1]))
	inst.config.events.append(EventRule.from_template(EventRule.templates()[3][1]))
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
	var sleeper: ServerInstance = created2.instance
	sleeper.config.wake_on_connect = true
	sleeper.config.events.append(EventRule.from_template({"trigger": EventRule.Trigger.TIME, "time_of_day": "18:00", "weekdays": (1 << 5) | (1 << 6) | 1, "action": EventRule.Action.START}))
	sleeper.save_config()
	main.show_server(sleeper.config.id)
	tabs.current_tab = _tab(tabs, "Automation")
	await _shot("10_automation_wake")
	main.show_dashboard()
	await _shot("11_dashboard_asleep")
	main.show_server(inst.config.id)
	tabs.current_tab = _tab(tabs, "Console")

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
	(wizard.find_child("MoreSettings", true, false) as FoldableContainer).folded = false
	await _shot("23b_wizard_more_settings")
	wizard.get_node("%NextButton").pressed.emit()
	await _shot("24_wizard_review")
	wizard.hide()

	main.get_node("%AppSettingsDialog").open()
	await _shot("30_settings")
	var prefs_scroll := main.get_node("%AppSettingsDialog").find_child("Scroll", true, false) as ScrollContainer
	prefs_scroll.scroll_vertical = 100000
	await _shot("30b_prefs_bottom")
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
	main.get_node("%DuplicateServerDialog").open(inst)
	await _shot("34_duplicate")
	main.get_node("%DuplicateServerDialog").hide()
	main.get_node("%ImportServerDialog").open()
	await _shot("35_import_server")
	main.get_node("%ImportServerDialog").hide()
	main.get_node("%ImportWorldDialog").open(created2.instance)
	await _shot("36_import_world")
	main.get_node("%ImportWorldDialog").hide()

	inst.stop()
	await _wait_for(func() -> bool: return not inst.is_process_alive(), 60.0)
	main.show_server(inst.config.id)
	tabs.current_tab = 0
	await _shot("40_overview_stopped")

	await inst.start_temporary()
	await _wait_for(func() -> bool: return inst.is_online(), 240.0)
	await _shot("41_temp_running")
	inst.stop()
	await _wait_for(func() -> bool: return main.get_node("%TempRunDialog").visible, 90.0)
	await _shot("42_temp_dialog")
	main.get_node("%TempRunDialog").hide()
	await inst.finish_temporary(false)
	for i in ServerManager.get_instances().duplicate():
		ServerManager.delete_server(i.config.id, true, true)
	print("UI smoke test finished")
	get_tree().quit()


func _tab(tabs: TabContainer, title: String) -> int:
	for i in tabs.get_tab_count():
		if tabs.get_tab_title(i) == title:
			return i
	return 0


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
