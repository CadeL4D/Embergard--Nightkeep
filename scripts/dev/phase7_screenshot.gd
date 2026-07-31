extends Node
## Real-renderer QA for the compact control drawer, painted overlays, and Realm/local continuity.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const OUT_DIR := "res://artifacts"

var _run: Node2D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var tutorials := Accessibility.tutorials_enabled
	Accessibility.tutorials_enabled = false
	NewRunRequest.set_request(7072026, &"harried", false)
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await _settle(24)
	_paint_example_zones()
	var controls: Button = _run.get_node(
		"Hud/SafeArea/Layout/BottomRow/ButtonsClip/Buttons/ControlButton")
	controls.button_pressed = true
	await _settle(12)
	_capture("phase7_colony_controls")

	controls.button_pressed = false
	DefenseControl.cancel_paint()
	var camera: Camera2D = _run.get_node("CameraRig")
	camera.zoom = Vector2.ONE
	camera.center_on_cell(World.keep_cell)
	var keep := World.grid.coord(World.keep_cell)

	# One frame captures the three distinct visual languages together.
	Events.power_cast.emit(&"emberfall",
		World.grid.to_world_index(World.grid.index_v(keep + Vector2i(-6, 2))))
	Events.power_cast.emit(&"ward",
		World.grid.to_world_index(World.grid.index_v(keep + Vector2i(0, -2))))
	Events.power_cast.emit(&"wrath",
		World.grid.to_world_index(World.grid.index_v(keep + Vector2i(6, 2))))
	await _settle(7)
	_capture("phase7_power_effects")
	var power_effects := _run.get_node("WorldView/PowerEffects")
	power_effects.effects.clear()
	power_effects.set_process(false)
	power_effects.queue_redraw()

	camera.zoom = Vector2(0.5, 0.5)
	await _settle(5)
	_capture("phase7_influence_overview")

	var pause_menu := _run.get_node("PauseMenu")
	pause_menu.open()
	await _settle(5)
	_capture("phase7_pause_menu")
	pause_menu._show_settings()
	await _settle(5)
	_capture("phase7_pause_settings")
	pause_menu.close()

	camera.zoom = Vector2.ONE
	camera.center_on_cell(World.keep_cell)
	var placement := _run.get_node("PlacementController")
	var path_def := Buildings.get_building(&"path")
	Colony.add(&"wood", 100)
	placement.begin(path_def)
	placement._set_pending_line(keep + Vector2i(-5, 5), keep + Vector2i(5, 5))
	await _settle(5)
	_capture("phase7_placement_preview")
	placement.cancel()

	var realm_map := _run.get_node("RealmMap")
	realm_map.open()
	await _settle(16)
	_capture("phase7_continuous_realm")
	var canvas: RealmMapCanvas = realm_map.get_node(
		"Backdrop/Safe/Panel/Layout/Main/MapFrame/Map")
	canvas.zoom_to(Realm.awake_id)
	await _settle(28)
	_capture("phase7_continuous_region")

	Accessibility.tutorials_enabled = tutorials
	Accessibility.save_settings()
	RunSave.clear()
	get_tree().quit(0)


func _paint_example_zones() -> void:
	var keep := World.grid.coord(World.keep_cell)
	DefenseControl.paint_mode = DefenseControl.PaintMode.WORK
	for y in range(keep.y - 5, keep.y + 2):
		for x in range(keep.x + 5, keep.x + 12):
			if World.grid.is_valid(x, y):
				DefenseControl.paint(World.grid.index(x, y))
	DefenseControl.paint_mode = DefenseControl.PaintMode.GUARD
	for x in range(keep.x - 10, keep.x - 3):
		for y in range(keep.y - 1, keep.y + 2):
			if World.grid.is_valid(x, y):
				DefenseControl.paint(World.grid.index(x, y))
	DefenseControl.paint_mode = DefenseControl.PaintMode.FORBIDDEN
	for y in range(keep.y + 7, keep.y + 10):
		for x in range(keep.x - 7, keep.x + 8):
			if World.grid.is_valid(x, y):
				DefenseControl.paint(World.grid.index(x, y))


func _settle(frames: int) -> void:
	for _i in frames:
		await get_tree().process_frame


func _capture(name: String) -> void:
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, name]
	var error := image.save_png(path)
	if error != OK:
		push_error("could not write %s: %s" % [path, error_string(error)])
	print("wrote %s" % ProjectSettings.globalize_path(path))
