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
	_check_stored_water()
	_check_two_day_cycles()

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
	hud._on_menu_cycle_pressed()
	_expect(hud._bottom_menu_index == (starting_menu + 1) % hud.BOTTOM_MENU_IDS.size(),
		"tapping Cycle chooses the next menu")
	_expect(not hud._job_panel.visible,
		"cycling to Jobs does not open it before the selected menu button is pressed")
	_expect(menu_button.text == tr(hud.BOTTOM_MENU_LABELS[hud._bottom_menu_index]),
		"the selected menu button is renamed to the cycled choice")
	hud._on_bottom_menu_pressed()
	_expect(hud._job_panel.visible,
		"pressing the Jobs menu button opens the job assignment panel")
	hud._select_bottom_menu(0)
	var harvest: Button = hud.get_node(
		"SafeArea/Layout/BottomRow/JobPanel/Layout/Header/HarvestAreas")
	_expect(harvest != null and harvest.text == tr(&"GATHER_AREAS"),
		"the Job Board has one top-level harvest territory button")
	var per_row_areas_hidden := true
	for widgets: Dictionary in hud._row_widgets.values():
		if (widgets.get("area") as Button).visible:
			per_row_areas_hidden = false
	_expect(per_row_areas_hidden, "harvest territories are no longer split across job rows")

	# 3x advances to 0x (pause), then the same control resumes at 1x.
	Sim.set_paused(false)
	Sim.time_scale = 3.0
	Sim.cycle_speed()
	_expect(Sim.paused and hud._speed_button.text == "0x",
		"the speed control folds pause into 0x")
	Sim.cycle_speed()
	_expect(not Sim.paused and is_equal_approx(Sim.time_scale, 1.0),
		"tapping 0x resumes at 1x")

	# Hold opens every menu and releasing over one opens that choice.
	hud._menu_touch_index = 9
	hud._menu_touch_position = cycle_button.get_global_rect().get_center()
	hud._process(Accessibility.hold_duration + 0.01)
	_expect(hud._menu_switcher_open and hud._menu_switcher.visible,
		"holding Cycle opens the drag menu switcher")
	var build_index: int = hud.BOTTOM_MENU_IDS.find(&"build")
	hud._finish_menu_gesture(hud._menu_switcher._rects[build_index].get_center())
	_expect(hud._bottom_menu_index == build_index and hud._build_panel.visible,
		"releasing on a held menu opens that menu")
	hud._select_bottom_menu(0)
	var sample_power: PowerDef = Powers.all()[0]
	var sample_power_button := Button.new()
	hud.add_child(sample_power_button)
	hud._on_power_hold_started(sample_power, sample_power_button)
	hud._process(Accessibility.hold_duration + 0.01)
	_expect(hud._power_hold_shown and hud._power_hold_suppressed == sample_power_button,
		"holding a power displays its description and suppresses casting")
	hud._on_power_hold_released(sample_power_button)
	hud._on_power_pressed(sample_power, sample_power_button)
	_expect(hud._god_hand.armed != sample_power,
		"releasing a described power does not cast or arm it")
	sample_power_button.queue_free()
	var readout: ResourceReadout = hud.get_node(
		"SafeArea/Layout/TopRow/ResourceColumn/ResourceBar/Resources")
	_expect(not readout._rows.is_empty(), "the material readout is populated with icon chips")
	_expect(String(readout._rows[0].get("label", "")).is_empty(),
		"the material strip has no raw category heading")
	hud._refresh_phase()
	var phase_label: Label = hud.get_node("SafeArea/Layout/TopRow/PhaseBar/Row/Phase")
	_expect(phase_label.text.begins_with(Climate.name_of_season()) \
		and phase_label.text.contains("Day %d" % Sim.day) \
		and not phase_label.text.contains("s") and not phase_label.text.contains("\n"),
		"the status line contains only season then day")

	var upgrade := Buildings.get_building(&"great_hall")
	var unmet_requirements: String = hud._upgrade_requirements(upgrade)
	_expect(unmet_requirements.contains("#%s" % UiPalette.DANGER.to_html(false)),
		"unmet upgrade requirements are shown in red")
	var saved_upgrade_stock := {}
	for kind: StringName in upgrade.cost:
		saved_upgrade_stock[kind] = Colony.stock.get(kind, 0)
		Colony.stock[kind] = int(upgrade.cost[kind]) \
			+ int(Colony.reserved.get(kind, 0)) + int(Colony.buffered.get(kind, 0))
	var mixed_requirements: String = hud._upgrade_requirements(upgrade)
	_expect(mixed_requirements.contains("#%s" % UiPalette.OK.to_html(false)) \
		and mixed_requirements.contains("#%s" % UiPalette.DANGER.to_html(false)),
		"met materials turn green while an unmet population gate stays red")
	var center: Building = null
	for building: Building in Colony.buildings:
		if building.def.center_tier > 0:
			center = building
			break
	if center != null:
		hud._god_hand._select_building(center)
		hud._refresh_building_card()
	var upgrade_widgets: Dictionary = hud._upgrade_widgets.get(&"great_hall", {})
	_expect(not upgrade_widgets.is_empty() \
		and (upgrade_widgets.get("needs") as RichTextLabel).text == mixed_requirements,
		"the colored requirements render directly beside the upgrade button")
	hud._god_hand.clear_building_selection()
	for kind: StringName in saved_upgrade_stock:
		Colony.stock[kind] = int(saved_upgrade_stock[kind])

	Accessibility.set_pause_while_managing(true)
	hud._activate_bottom_menu(hud.BOTTOM_MENU_IDS.find(&"jobs"))
	_expect(Sim.paused, "the optional management pause still pauses once on open")
	Sim.set_paused(false)
	hud._sync_management_pause()
	_expect(not Sim.paused,
		"Resume from the pause menu cannot be overridden while the drawer remains open")
	hud._select_bottom_menu(0)
	hud._activate_bottom_menu(hud.BOTTOM_MENU_IDS.find(&"jobs"))
	hud._on_pause_toggled(false)
	hud._sync_management_pause()
	_expect(not Sim.paused, "the HUD Resume button cannot be overridden either")
	hud._select_bottom_menu(0)
	Accessibility.set_pause_while_managing(false)


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


func _check_stored_water() -> void:
	if Colony.villagers.is_empty():
		_expect(false, "a villager exists for stored-water checks")
		return
	var villager: Villager = Colony.villagers[0]
	villager._release_target()
	villager._release_bed()
	var before := Colony.item_count(&"waterskin")
	Colony.create_item(&"waterskin", World.keep_cell)
	var source := Colony.nearest_item_source(villager.cell(), &"waterskin")
	_expect(source != -1, "a filled waterskin is a reachable stored-water source")
	if source == -1:
		return
	villager.position = World.grid.to_world_index(source)
	villager.water = 0.0
	villager.health = villager.max_health
	villager.state = Villager.State.SLEEPING
	villager._shift_sleep = true
	villager._set_sheltered(true)
	villager.think(0.1)
	villager.think(0.1)
	_expect(villager.water > 0.0 and villager.visible and not villager._shift_sleep,
		"a thirsty sleeper wakes and drinks stored water without the Hand")
	_expect(Colony.item_count(&"waterskin") == before,
		"drinking consumes exactly one stocked waterskin")
	var bottling := Jobs.get_job(&"bottling")
	var bottler := Buildings.get_building(&"bottler")
	_expect(bottling.requires_water_access and bottler.is_stockpile \
		and &"consumable" in bottler.storage_tags and not bottler.provides_water,
		"Bottlers fill storage from reachable wells or rivers instead of acting as a free well")


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
