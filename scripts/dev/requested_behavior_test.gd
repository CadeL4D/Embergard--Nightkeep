extends Node
## Focused regression coverage for the villager/HUD changes requested in August 2026.

const RUN_SCENE := preload("res://scenes/run/run.tscn")

var _failures := PackedStringArray()


func _ready() -> void:
	NewRunRequest.set_request(2024, &"harried", false)
	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	for _i in 8:
		await get_tree().process_frame

	_check_hud(run)
	_check_danger_reasons()
	_check_rest_and_night_recall()
	_check_two_day_cycles()

	Accessibility.set_compact_status_display(false)
	RunSave.clear()
	if _failures.is_empty():
		print("requested behavior test: all checks passed")
		get_tree().quit(0)
	else:
		for failure in _failures:
			printerr("FAIL: %s" % failure)
		get_tree().quit(1)


func _check_hud(run: Node2D) -> void:
	var hud: CanvasLayer = run.get_node("Hud")
	var cycle_button: Button = hud.get_node(
		"SafeArea/Layout/BottomRow/ButtonsClip/Buttons/MenuCycleButton")
	_expect(cycle_button != null,
		"Cycle has its own button")
	var menu_button: Button = hud.get_node(
		"SafeArea/Layout/BottomRow/ButtonsClip/Buttons/BottomMenuButton")
	_expect(menu_button != null,
		"the full bottom menu has its own button")
	var starting_menu: int = hud._bottom_menu_index
	var touch_down := InputEventScreenTouch.new()
	touch_down.index = 17
	touch_down.pressed = true
	touch_down.position = cycle_button.global_position + cycle_button.size * 0.5
	hud._on_menu_cycle_input(touch_down)
	var touch_up := InputEventScreenTouch.new()
	touch_up.index = touch_down.index
	touch_up.pressed = false
	touch_up.position = touch_down.position
	hud._input(touch_up)
	_expect(hud._bottom_menu_index == (starting_menu + 1) % hud.BOTTOM_MENU_IDS.size(),
		"tapping Cycle advances to the next menu")
	hud._on_bottom_menu_pressed()
	_expect(hud._jobs_button.visible and hud._realm_button.visible,
		"tapping Menu reveals the full menu list")
	hud._activate_bottom_menu(0)
	_expect(not hud._jobs_button.visible and not hud._realm_button.visible,
		"choosing a menu item collapses the full list")
	var readout: ResourceReadout = hud.get_node(
		"SafeArea/Layout/TopRow/ResourceColumn/ResourceBar/Resources")
	_expect(not readout._rows.is_empty(), "the material readout is populated with icon chips")
	Accessibility.set_compact_status_display(true)
	hud._refresh_phase()
	var phase_label: Label = hud.get_node("SafeArea/Layout/TopRow/PhaseBar/Row/Phase")
	_expect(not phase_label.text.contains("\n"), "compact day/weather mode uses one line")
	Accessibility.set_compact_status_display(false)
	hud._refresh_phase()


func _check_danger_reasons() -> void:
	if Colony.villagers.is_empty():
		_expect(false, "a villager exists for danger-reason checks")
		return
	var villager: Villager = Colony.villagers[0]
	var old_water := villager.water
	var old_food := villager.food
	villager.water = 0.0
	_expect(villager.danger_reason() == &"dehydration", "zero water identifies dehydration")
	villager.water = old_water
	villager.food = 0.0
	_expect(villager.danger_reason() == &"starvation", "zero food identifies starvation")
	villager.food = old_food
	villager.apply_status(&"burning", 5.0)
	_expect(villager.danger_reason() == &"burning", "burning identifies itself")
	villager.statuses.erase(&"burning")


func _check_rest_and_night_recall() -> void:
	if Colony.villagers.size() < 2:
		_expect(false, "enough villagers exist for night recall")
		return
	# One guard remains outside. Everyone else starts tired and away from the Hearth,
	# approximating gatherers returning from the edge of a work zone.
	Colony.villagers[0].set_job(&"warrior")
	var keep := World.grid.coord(World.keep_cell)
	var offsets := [Vector2i(24, 0), Vector2i(-24, 0), Vector2i(0, 24),
		Vector2i(0, -24), Vector2i(18, 18), Vector2i(-18, -18)]
	for index in range(1, Colony.villagers.size()):
		var villager: Villager = Colony.villagers[index]
		villager.set_job(&"")
		villager.rest = 5.0
		villager.food = 90.0
		villager.water = 90.0
		var wanted_v: Vector2i = keep + offsets[(index - 1) % offsets.size()]
		if World.grid.is_valid_v(wanted_v):
			var wanted := World.nearest_walkable(World.grid.index_v(wanted_v), 16)
			if wanted != -1 and not World.paths.solve(wanted, World.keep_cell).is_empty():
				villager.position = World.grid.to_world_index(wanted)
		villager.think_urgent = true

	Sim.time_scale = 1.0
	Sim.set_phase(Sim.Phase.DUSK)
	for _step in 1600: # eighty simulated seconds: dusk plus the start of night
		Sim._process(0.05)
		for villager: Villager in Colony.villagers:
			if is_instance_valid(villager):
				villager._process(0.05)

	var civilians := 0
	var sheltered := 0
	var working := 0
	var guards_active := 0
	for villager: Villager in Colony.villagers:
		var job_def := Jobs.get_job(villager.job)
		if job_def != null and job_def.defends:
			if villager.state == Villager.State.GUARDING:
				guards_active += 1
			continue
		civilians += 1
		if villager.is_sheltered():
			sheltered += 1
		if villager.state in [Villager.State.WORKING, Villager.State.BUILDING,
				Villager.State.FETCHING, Villager.State.DELIVERING, Villager.State.HAULING]:
			working += 1
	_expect(Sim.phase == Sim.Phase.NIGHT, "the focused run reached night")
	_expect(civilians > 0 and sheltered == civilians,
		"all tired civilians walked home and sheltered (%d/%d)" % [sheltered, civilians])
	_expect(working == 0, "no civilian job continues at night")
	_expect(guards_active > 0, "a guard remains active at night")


func _check_two_day_cycles() -> void:
	var start_day := Sim.day
	for _day in 2:
		for phase in [Sim.Phase.DAY, Sim.Phase.DUSK, Sim.Phase.NIGHT, Sim.Phase.DAWN]:
			Sim.set_phase(phase)
			Sim.phase_elapsed = Difficulties.phase_duration(phase)
			Sim._advance_phase(0.01)
	_expect(Sim.day == start_day + 2, "two complete day/night cycles advance the calendar")


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("ok: %s" % description)
	else:
		_failures.append(description)
