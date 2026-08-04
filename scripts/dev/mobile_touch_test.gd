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
	var camera: Camera2D = run.get_node("CameraRig")
	_test_camera(camera)
	await _test_camera_input_route(camera)
	_test_drawer_exclusivity(run.get_node("Hud"))
	await _test_drawer_fits_on_screen(run.get_node("Hud"))
	_test_menu_dropdown(run.get_node("Hud"))
	_test_center_progression(run.get_node("Hud"))
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

	DefenseControl.select_gather_mode(&"woodcutting")
	var paint_start := camera.position
	camera._handle_paint_touch(_touch(2, Vector2(280, 170), true))
	camera._handle_paint_drag(_drag(2, Vector2(330, 170), Vector2(50, 0)))
	_expect(camera.position.is_equal_approx(paint_start),
		"one finger remains reserved for painting in harvest mode")
	camera._handle_paint_touch(_touch(3, Vector2(380, 170), true))
	camera._handle_paint_drag(_drag(2, Vector2(350, 190), Vector2(20, 20)))
	_expect(not camera.position.is_equal_approx(paint_start),
		"two fingers pan the map while harvest marking is active")
	camera._handle_paint_touch(_touch(3, Vector2(380, 170), false))
	camera._handle_paint_touch(_touch(2, Vector2(350, 190), false))
	DefenseControl.cancel_gather_paint()

	# Closing a brush can route the physical releases into the newly exposed UI.
	# The next ordinary gesture must not inherit those ghost fingers.
	DefenseControl.select_gather_mode(&"woodcutting")
	camera._handle_paint_touch(_touch(4, Vector2(280, 170), true))
	camera._handle_paint_touch(_touch(5, Vector2(380, 170), true))
	DefenseControl.cancel_gather_paint()
	_expect(camera._touches.is_empty() and camera._state == camera.State.NONE,
		"closing territory mode clears an interrupted two-finger gesture")
	var recovered_start := camera.position
	camera._handle_touch(_touch(6, Vector2(300, 180), true))
	camera._handle_drag(_drag(6, Vector2(350, 180), Vector2(50, 0)))
	camera._handle_touch(_touch(6, Vector2(350, 180), false))
	_expect(not camera.position.is_equal_approx(recovered_start),
		"ordinary map pan recovers immediately after territory mode closes")


## Exercise the Viewport route as well as the handler methods above. A Control or
## another world-input node can consume a real gesture before CameraRig sees it,
## which direct method calls cannot detect.
func _test_camera_input_route(camera: Camera2D) -> void:
	DefenseControl.cancel_gather_paint()
	DefenseControl.cancel_paint()
	camera._touches.clear()
	camera._state = camera.State.NONE
	camera.center_on_cell(World.keep_cell)
	var pan_before := camera.position
	Input.parse_input_event(_touch(10, Vector2(400, 180), true))
	Input.parse_input_event(_drag(10, Vector2(460, 180), Vector2(60, 0)))
	Input.parse_input_event(_touch(10, Vector2(460, 180), false))
	await get_tree().process_frame
	_expect(not camera.position.is_equal_approx(pan_before),
		"a real routed one-finger gesture reaches the camera")

	camera._touches.clear()
	camera._state = camera.State.NONE
	camera.zoom = Vector2.ONE
	var zoom_before := camera.zoom.x
	Input.parse_input_event(_touch(11, Vector2(340, 180), true))
	Input.parse_input_event(_touch(12, Vector2(460, 180), true))
	Input.parse_input_event(_drag(12, Vector2(520, 180), Vector2(60, 0)))
	Input.parse_input_event(_touch(12, Vector2(520, 180), false))
	Input.parse_input_event(_touch(11, Vector2(340, 180), false))
	await get_tree().process_frame
	_expect(not is_equal_approx(camera.zoom.x, zoom_before),
		"a real routed two-finger gesture reaches the camera")

	camera._touches.clear()
	camera._state = camera.State.NONE
	camera.center_on_cell(World.keep_cell)
	pan_before = camera.position
	Input.parse_input_event(_mouse_button(Vector2(400, 180), true))
	Input.parse_input_event(_mouse_motion(Vector2(460, 180), Vector2(60, 0)))
	Input.parse_input_event(_mouse_button(Vector2(460, 180), false))
	await get_tree().process_frame
	_expect(not camera.position.is_equal_approx(pan_before),
		"a real routed desktop drag pans the camera")

	# The brush owns the left button and erasing owns the right, so on a desktop this
	# is the ONLY way to move the map without first closing the tool. Routed through
	# the viewport rather than called directly, because the whole failure mode was the
	# paint surface swallowing the event before the camera ever saw it.
	DefenseControl.select_gather_mode(&"woodcutting")
	camera.center_on_cell(World.keep_cell)
	pan_before = camera.position
	Input.parse_input_event(_pan_button(Vector2(400, 180), true))
	Input.parse_input_event(_pan_motion(Vector2(460, 180), Vector2(60, 0)))
	Input.parse_input_event(_pan_button(Vector2(460, 180), false))
	await get_tree().process_frame
	_expect(not camera.position.is_equal_approx(pan_before),
		"middle-drag pans the map while a harvest brush is open")
	DefenseControl.cancel_gather_paint()


func _test_drawer_exclusivity(hud: CanvasLayer) -> void:
	var job_panel: Control = hud.get_node(
		"SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel")
	var build_panel: Control = hud.get_node(
		"SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/BuildPanel")
	hud._select_menu_tab(&"jobs")
	hud._select_menu_tab(&"build")
	_expect(build_panel.visible and not job_panel.visible,
		"one open tab means one open menu")
	hud._close_menus()


## Both ends of the column have to survive an open menu: the dropdown hangs from the top-left
## and the world-context cards sit at the bottom, so a menu body that is too tall pushes the
## cards off the screen. The original form of this bug took the ONLY way out of a drawer with it.
func _test_drawer_fits_on_screen(hud: CanvasLayer) -> void:
	var root := hud.get_tree().root
	var restore := root.size
	# Pin the shipping viewport for the duration. A headless run gets an 800x800 window
	# and everything fits there; the overflow only exists on the 360-tall layout the
	# game is actually authored for, so testing at whatever size the harness happens to
	# have would quietly assert nothing.
	root.size = Vector2i(800, 360)
	await hud.get_tree().process_frame

	var dock: Control = hud.get_node("SafeArea/Layout/MenuDock")
	for tab in [&"jobs", &"build", &"library", &"control"]:
		hud._select_menu_tab(tab)
		hud._fit_drawers()
		await hud.get_tree().process_frame
		_expect(dock.global_position.y + dock.size.y <= root.get_visible_rect().size.y,
			"the %s menu fits on screen with room below it" % tab)
	hud._close_menus()

	root.size = restore
	await hud.get_tree().process_frame


## The dropdown is the one way into every menu now, so its open/close contract is load-bearing:
## it must stay up while the player works, and close only on the button that opened it.
func _test_menu_dropdown(hud: CanvasLayer) -> void:
	var menus: Button = hud.get_node("SafeArea/Layout/MenuDock/MenusButton")
	var panel: Control = hud.get_node("SafeArea/Layout/MenuDock/MenuPanel")
	var tabs: HBoxContainer = hud.get_node(
		"SafeArea/Layout/MenuDock/MenuPanel/Layout/TabsClip/Tabs")
	hud._close_menus()
	_expect(not panel.visible, "the dropdown starts closed")
	menus.button_pressed = true
	_expect(panel.visible and tabs.get_child_count() == hud.MENU_IDS.size(),
		"Menus drops down one tab per menu (%d)" % tabs.get_child_count())

	for tab in [&"jobs", &"build", &"control", &"library", &"powers"]:
		hud._select_menu_tab(tab)
		_expect(panel.visible, "switching to %s leaves the dropdown open" % tab)

	# The Realm map is a whole screen, so it is the one tab that closes the dropdown behind it.
	var realm_map: CanvasLayer = hud.get_node("../RealmMap")
	hud._select_menu_tab(&"realm")
	_expect(not panel.visible and realm_map.visible,
		"the Realm tab hands over to the full-screen map instead of stacking under it")
	realm_map.visible = false

	menus.button_pressed = true
	_expect(panel.visible and hud._menu_tab == &"powers",
		"reopening returns to the last tab the player used, not the Realm")
	menus.button_pressed = false
	_expect(not panel.visible, "pressing Menus again is what closes it")


## With tier-locked cards hidden, the Village Center row is the only thing left telling the player
## that the rest of the game exists. If that row ever goes quiet, hiding the cards turns a
## progression system into a missing one.
func _test_center_progression(hud: CanvasLayer) -> void:
	var revealed := Buildings.revealed()
	var leaked := 0
	for def: BuildingDef in revealed:
		if def.tier > Colony.center_tier():
			leaked += 1
	_expect(leaked == 0 and revealed.size() < Buildings.in_menu().size(),
		"the build menu hides what the Village Center has not unlocked (%d of %d shown)"
			% [revealed.size(), Buildings.in_menu().size()])
	_expect(Buildings.revealed_by_next_center() > 0,
		"the next Village Center tier has buildings to promise (%d)"
			% Buildings.revealed_by_next_center())

	hud._refresh_center_row()
	_expect(hud._center_raise.visible and not hud._center_status.text.is_empty(),
		"the build menu advertises the next Village Center tier")

	# A tier whose own contents cannot pay for the next centre gates itself. Everything visible
	# at Centre 1, and the Great Hall that leaves it, must be payable in raw wood and stone —
	# boards and cut stone are what raising the centre BUYS.
	var raw: Array[StringName] = [&"wood", &"stone"]
	var processed := PackedStringArray()
	var checked := revealed.duplicate()
	checked.append(Buildings.get_building(&"great_hall"))
	for def: BuildingDef in checked:
		for kind: StringName in def.cost:
			if not kind in raw:
				processed.append("%s:%s" % [def.id, kind])
	_expect(processed.is_empty(),
		"the first tier and the Great Hall are payable by a colony that only gathers (%s)"
			% ", ".join(processed))


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


func _pan_button(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_MIDDLE
	event.position = position
	event.pressed = pressed
	return event


func _pan_motion(position: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.relative = relative
	event.velocity = relative * 30.0
	event.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	return event


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


func _mouse_button(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	return event


func _mouse_motion(position: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.relative = relative
	event.velocity = relative * 30.0
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	return event


func _expect(ok: bool, label: String) -> void:
	if ok:
		print("   ok   %s" % label)
	else:
		_failures.append(label)
		print("   FAIL %s" % label)
