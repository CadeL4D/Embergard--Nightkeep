extends Node
## Scripted mobile-input and safe-area regression at the four launch aspect ratios.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 507315

var _failures := PackedStringArray()


func _ready() -> void:
	RunSave.clear()
	_test_safe_areas()
	NewRunRequest.set_request(TEST_SEED, &"survival", false)
	var run := RUN_SCENE.instantiate()
	add_child(run)
	for _frame in 5:
		await get_tree().process_frame
	Sim.set_paused(true)
	_test_camera(run.get_node("CameraRig"))
	_test_drawer_exclusivity(run.get_node("Hud"))
	_test_bottom_menu(run.get_node("Hud"))
	_test_house_branches()
	_test_hand(run.get_node("GodHand"))
	_test_line_placement(run.get_node("PlacementController"))
	_test_accessibility()
	RunSave.clear()
	remove_child(run)
	run.free()
	for _frame in 3:
		await get_tree().process_frame
	print("\n=== mobile touch result ===")
	if _failures.is_empty():
		print("all mobile layout and gesture checks passed")
		get_tree().quit(0)
	else:
		for failure in _failures:
			print("FAIL: %s" % failure)
		get_tree().quit(1)


func _test_safe_areas() -> void:
	var devices := [
		[Vector2i(1280, 720), Rect2i(0, 0, 1280, 720), "16:9"],
		[Vector2i(1404, 720), Rect2i(44, 0, 1316, 704), "19.5:9 notch"],
		[Vector2i(1440, 720), Rect2i(48, 0, 1344, 704), "20:9 rounded"],
		[Vector2i(960, 720), Rect2i(0, 24, 960, 672), "4:3 tablet"],
	]
	for row in devices:
		var margins := SafeArea.calculate_margins(row[0], row[1], Vector2(800, 360), 8)
		_expect(margins.x >= 8 and margins.y >= 8 and margins.z >= 8 and margins.w >= 8,
			"%s safe margins remain positive" % row[2])
		if row[1].position.x > 0:
			_expect(margins.x > 8, "%s preserves its left sensor inset" % row[2])
		if row[1].end.y < row[0].y:
			_expect(margins.w > 8, "%s preserves its rounded bottom inset" % row[2])


func _test_camera(camera: Camera2D) -> void:
	var tapped := [false]
	camera.tapped.connect(func(_world: Vector2) -> void: tapped[0] = true)
	camera._handle_touch(_touch(0, Vector2(300, 180), true))
	camera._handle_touch(_touch(0, Vector2(300, 180), false))
	_expect(tapped[0], "a forgiving one-finger tap reaches world selection")
	var before := camera.position
	camera._handle_touch(_touch(0, Vector2(300, 180), true))
	camera._handle_drag(_drag(0, Vector2(336, 180), Vector2(36, 0)))
	camera._handle_touch(_touch(0, Vector2(336, 180), false))
	_expect(not camera.position.is_equal_approx(before), "one-finger drag pans the map")
	var zoom_before := camera.zoom.x
	camera._handle_touch(_touch(0, Vector2(280, 180), true))
	camera._handle_touch(_touch(1, Vector2(360, 180), true))
	camera._handle_drag(_drag(1, Vector2(400, 180), Vector2(40, 0)))
	camera._handle_touch(_touch(1, Vector2(400, 180), false))
	camera._handle_touch(_touch(0, Vector2(280, 180), false))
	_expect(not is_equal_approx(camera.zoom.x, zoom_before) \
		and camera.zoom.x >= camera.ZOOM_MIN and camera.zoom.x <= camera.ZOOM_MAX,
		"two-finger pinch changes zoom inside mobile limits")


func _test_drawer_exclusivity(hud: CanvasLayer) -> void:
	var jobs: Button = hud.get_node("SafeArea/Layout/BottomRow/ButtonsClip/Buttons/JobsButton")
	var build: Button = hud.get_node("SafeArea/Layout/BottomRow/ButtonsClip/Buttons/BuildButton")
	jobs.button_pressed = true
	build.button_pressed = true
	var job_panel: Control = hud.get_node("SafeArea/Layout/BottomRow/JobPanel")
	var build_panel: Control = hud.get_node("SafeArea/Layout/BottomRow/BuildPanel")
	_expect(build_panel.visible and not job_panel.visible,
		"opening one thumb drawer closes the previous drawer")
	build.button_pressed = false


func _test_bottom_menu(hud: CanvasLayer) -> void:
	hud._select_bottom_menu(0)
	var selected: Button = hud.get_node(
		"SafeArea/Layout/BottomRow/ButtonsClip/Buttons/BottomMenuButton")
	hud._on_menu_cycle_pressed()
	_expect(hud._bottom_menu_index == 1 \
		and not hud.get_node("SafeArea/Layout/BottomRow/JobPanel").visible \
		and selected.text == tr(hud.BOTTOM_MENU_LABELS[1]),
		"Cycle chooses Jobs and renames the selected menu action without opening it")
	hud._on_bottom_menu_pressed()
	_expect(hud.get_node("SafeArea/Layout/BottomRow/JobPanel").visible,
		"pressing the selected Jobs action opens job assignment")
	hud._select_bottom_menu(0)


func _test_house_branches() -> void:
	var options := Buildings.upgrades_for(&"hut")
	var longhouse := Buildings.get_building(&"longhouse")
	var warden := Buildings.get_building(&"warden_house")
	_expect(options.size() >= 2 and longhouse in options and warden in options,
		"a hut exposes both housing upgrade branches")
	_expect(longhouse.sleep_slots > warden.sleep_slots \
		and warden.sleep_recovery_multiplier > longhouse.sleep_recovery_multiplier,
		"housing branches trade more capacity for faster rest recovery")


func _test_hand(hand: Node) -> void:
	Divine.faith = 999.0
	hand.set_hand_mode(true)
	var villager: Villager = Colony.villagers[0]
	hand._handle_hand_tap(villager.position)
	_expect(hand.held == villager and villager.held_by_hand,
		"Hand mode lifts a light friendly target with one tap")
	var destination := World.nearest_walkable(villager.cell(), 4)
	if destination == villager.cell():
		for neighbor in World.grid.neighbours_8(destination):
			if World.is_walkable(neighbor):
				destination = neighbor
				break
	hand._handle_hand_tap(World.grid.to_world_index(destination))
	_expect(hand.held == null and not villager.held_by_hand,
		"Hand mode previews and drops the target with a second tap")
	hand.set_hand_mode(false)


func _test_line_placement(placement: Node) -> void:
	var wall := Buildings.get_building(&"palisade")
	placement.begin(wall)
	var start := World.grid.coord(World.keep_cell) + Vector2i(4, 0)
	var finish := start + Vector2i(0, 5)
	placement._set_pending_line(start, finish)
	_expect(placement.active and placement._pending_line.size() >= 2,
		"drag placement prepares a contiguous wall line before confirmation")
	placement.cancel()


func _test_accessibility() -> void:
	_expect(Accessibility.MIN_TOUCH_TARGET_PX >= 44.0,
		"world actions retain 44-pixel physical touch targets")
	_expect(Accessibility.HOLD_DURATIONS.size() >= 4,
		"hold duration is adjustable for motor accessibility")
	_expect(Accessibility.SCREEN_SHAKE_LEVELS[0] == 0.0,
		"screen shake can be disabled completely")


func _touch(index: int, position: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = position
	event.pressed = pressed
	return event


func _drag(index: int, position: Vector2, relative: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = position
	event.relative = relative
	event.velocity = relative * 30.0
	return event


func _expect(ok: bool, label: String) -> void:
	if ok:
		print("   ok   %s" % label)
	else:
		_failures.append(label)
		print("   FAIL %s" % label)
