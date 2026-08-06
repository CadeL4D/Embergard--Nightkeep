extends Node
## Focused regression coverage for the villager/HUD changes requested in August 2026.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")

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
	_check_hunger_never_freezes_a_villager()
	_check_full_workplace_releases_its_worker(run)
	await _check_walls_funnel_the_horde(run)
	await _check_physical_supply(run)
	_check_loose_drops_are_recovered()
	_check_essence_and_local_energy(run)
	_check_two_day_cycles()

	Colony.supply_requests.clear()
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
	var menus_button: Button = hud.get_node("SafeArea/Layout/MenuDock/MenusButton")
	var menu_panel: Control = hud.get_node("SafeArea/Layout/MenuDock/MenuPanel")
	_expect(menus_button != null and not menu_panel.visible,
		"the dropdown starts closed behind one Menus button")
	menus_button.button_pressed = true
	_expect(menu_panel.visible and hud._menu_tab_buttons.size() == hud.MENU_IDS.size(),
		"pressing Menus drops down a tab for every menu (%d)" % hud.MENU_IDS.size())
	hud._select_menu_tab(&"build")
	_expect(menu_panel.visible and hud._build_panel.visible and not hud._job_panel.visible,
		"a tab swaps the open menu without closing the dropdown")
	hud._select_menu_tab(&"jobs")
	_expect(menu_panel.visible and hud._job_panel.visible and not hud._build_panel.visible,
		"tabbing back is one press and leaves the dropdown up")
	menus_button.button_pressed = false
	_expect(not menu_panel.visible and not hud._job_panel.visible,
		"only pressing Menus again closes it")
	menus_button.button_pressed = true
	_expect(hud._menu_tab == &"jobs" and hud._job_panel.visible,
		"reopening returns to the tab the player was last working in")
	var harvest: Button = hud.get_node(
		"SafeArea/Layout/MenuDock/MenuPanel/Layout/Body/JobPanel/Layout/Header/HarvestAreas")
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

	hud._close_menus()
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
		and phase_label.text.contains("·") and not phase_label.tooltip_text.is_empty() \
		and not phase_label.text.contains("\n"),
		"the existing phase line carries a compact containment cause and full tooltip")
	var initial_outposts := 0
	for row: Dictionary in World.blight_structures.values():
		if bool(row.get("initial_outpost", false)):
			initial_outposts += 1
	_expect(World.nest_cells.size() == 1,
		"a campaign region contains one physical Blight Core")
	_expect(initial_outposts >= 2 and initial_outposts <= 4,
		"the Core begins with two to four physical Graveyard outposts")
	var containment := Threat.containment_target_for(0.02, initial_outposts, Sim.day)
	_expect(containment >= 0.0 and containment <= 1.0 \
			and Threat.pressure_breakdown().has("desired_coverage"),
		"local map containment is the authoritative bounded threat model")
	_expect(Realm.global_corruption >= 0.0 and Realm.global_corruption <= 1.0,
		"global corruption remains a normalized readout rather than combat pressure")

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
	hud._select_menu_tab(&"jobs")
	_expect(Sim.paused, "the optional management pause still pauses once on open")
	Sim.set_paused(false)
	hud._sync_management_pause()
	_expect(not Sim.paused,
		"Resume from the pause menu cannot be overridden while the drawer remains open")
	hud._close_menus()
	hud._select_menu_tab(&"jobs")
	hud._on_pause_toggled(false)
	hud._sync_management_pause()
	_expect(not Sim.paused, "the HUD Resume button cannot be overridden either")
	hud._close_menus()
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


## Hunger must never be able to stop a villager thinking.
##
## The reported symptom was a colony that froze in place: the clock ran, needs drained,
## and nobody moved until they died. The cause was that the hunger branch of think()
## returned unconditionally after ASKING to eat, while the two halves of "is there
## food" disagreed — Colony.has_food() counts stock inside farm and kitchen buffers,
## nearest_food_source() only finds shelves you can walk up to and take a meal from. A
## villager in that gap stopped drinking, sleeping and working too.
func _check_hunger_never_freezes_a_villager() -> void:
	if Colony.villagers.is_empty():
		_expect(false, "a villager exists for hunger checks")
		return
	Sim.set_phase(Sim.Phase.DAY)
	DefenseControl.shelter_active = false

	var villager: Villager = Colony.villagers[0]
	villager.set_job(&"")
	villager._release_target()
	villager._release_bed()
	villager._shift_sleep = false
	villager._set_sheltered(false)
	villager.stop()
	villager.state = Villager.State.IDLE
	villager.food = 0.0
	villager.water = 90.0
	villager.rest = 90.0
	villager.health = villager.max_health
	villager.carry_kind = &"food"
	villager.carry_amount = 8
	villager.think(0.1)
	_expect(villager.food > 0.0 and villager.carry_amount < 8,
		"a starving villager eats the load of food in their own arms")

	# Strip every shelf, then put the stock back as a bare number. That is exactly the
	# shape of food held inside a workshop's buffer.
	for raw_cell in Colony._storage_by_cell.keys():
		Colony.withdraw_at(int(raw_cell), &"food", 99999)
		Colony.withdraw_at(int(raw_cell), &"rations", 99999)
	Colony.overflow[&"food"] = 0
	Colony.overflow[&"rations"] = 0
	Colony.stock[&"food"] = 200
	_expect(Colony.has_food() and Colony.nearest_food_source(villager.cell()) == -1,
		"the colony can hold food that no villager has a shelf to eat from")

	villager.carry_kind = &""
	villager.carry_amount = 0
	villager.food = 0.0
	villager.water = 90.0
	villager.rest = 5.0                          # below REST_URGENT, so sleep is next
	villager.stop()
	villager.state = Villager.State.IDLE
	villager.think(0.1)
	_expect(villager.state != Villager.State.IDLE or villager.is_moving() \
		or villager._awaiting_path,
		"unreachable food does not stop a villager acting on their other needs")


## A workplace that has stopped producing must release its workers, not re-hire them.
##
## claim_workplace() used to ask production_is_available() with NO job, which only checks that the
## building is finished, unpaused and staffed. The worker's own tick asked the same function WITH
## the job, which additionally checks the output buffer and the maintain-target. When those
## disagreed the villager released the slot and immediately re-claimed it — standing on the spot
## at 10 Hz for the rest of the run, never moving and never looking for other work.
func _check_full_workplace_releases_its_worker(run: Node2D) -> void:
	var farm := _raise_farm(run)
	if farm == null:
		_expect(false, "a farm could be raised for the workplace-loop check")
		return
	var farming := Jobs.get_job(&"farming")

	# Maintain-target met is the cheapest way to make the job-aware check disagree with the
	# job-blind one, and it is a button the player can press on any workshop.
	farm.production_target = 1
	for kind: StringName in farming.cycle_yield:
		Colony.stock[kind] = 9999
	_expect(farm.production_is_available() and not farm.production_is_available(farming),
		"a workplace can be open in general and closed to this job in particular")
	_expect(Colony.nearest_workplace(&"farm", farm.anchor, farming) == null \
		and not Colony.claim_workplace(farm, self, farming),
		"a workplace closed to the job is neither offered nor claimable")

	var villager: Villager = Colony.villagers[0]
	villager._release_target()
	villager._release_workplace()
	villager.set_job(&"farming")
	villager.food = 80.0
	villager.water = 80.0
	villager.rest = 80.0
	villager.position = World.grid.to_world_index(farm.work_cell())
	villager.stop()
	villager.state = Villager.State.IDLE
	for _think in 6:
		villager.think(0.1)
	_expect(villager._workplace == null,
		"a farmer does not re-take a slot at a farm that has nothing to produce")

	farm.production_target = -1
	villager.set_job(&"")


## A finished farm near the keep. The starting colony does not come with one, and the loop under
## test only exists at a workplace, so the check has to raise its own.
func _raise_farm(run: Node2D) -> Building:
	for building: Building in Colony.buildings:
		if building.def.workplace_key() == &"farm" and not building.is_site():
			return building
	var def := Buildings.get_building(&"farm")
	var entities: Node = run.get_node("WorldView/Sorted/Entities")
	# Earlier checks in this file spend and strip the colony's stores, and placement is refused
	# on affordability before it is ever refused on ground. Fund the fixture explicitly.
	for kind: StringName in def.cost:
		Colony.stock[kind] = int(def.cost[kind]) * 20
	var keep := World.grid.coord(World.keep_cell)
	# A farm is 4x2 and has to land on clear, unblighted ground inside the influence sphere, so
	# the four compass points around one radius are nowhere near enough candidates.
	for radius in range(2, 14):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue                          # perimeter of this ring only
				var point := Vector2i(keep.x + dx, keep.y + dy)
				if not World.grid.is_valid_v(point):
					continue
				var anchor := World.grid.index_v(point)
				if not bool(Colony.check_placement(def, anchor)["ok"]):
					continue
				var farm := Colony.place_building(def, anchor, entities) as Building
				if farm != null:
					farm.complete()
					return farm
	return null


## A wall has to be geometry, not hit points.
##
## Two properties, and the game was failing both. A barrier must not be a GOAL — while every
## building cell was one, the nearest goal for anything outside the wall was the wall, so the
## crossing penalty had nothing to route toward and the detour never happened. And a gate must be
## CHEAPER to cross than a wall, or a field that prices them identically has no reason to prefer
## the door and the horde just hits whichever is nearer. Together they are what turn a palisade
## from a pile of hit points into a funnel the player aims.
func _check_walls_funnel_the_horde(run: Node2D) -> void:
	var wall_def := Buildings.get_building(&"palisade")
	var gate_def := Buildings.get_building(&"gate")
	for kind: StringName in [&"wood", &"stone"]:
		Colony.stock[kind] = 9999

	# A straight run of palisade east of the keep with one gate in the middle of it.
	var keep := World.grid.coord(World.keep_cell)
	var wall_x := keep.x + 5
	var gate_y := keep.y
	var wall_cells := PackedInt32Array()
	var gate_cell := -1
	var entities: Node = run.get_node("WorldView/Sorted/Entities")
	for dy in range(-4, 5):
		var point := Vector2i(wall_x, keep.y + dy)
		if not World.grid.is_valid_v(point):
			continue
		var anchor := World.grid.index_v(point)
		var def := gate_def if point.y == gate_y else wall_def
		if not bool(Colony.check_placement(def, anchor)["ok"]):
			continue
		var piece := Colony.place_building(def, anchor, entities) as Building
		if piece == null:
			continue
		piece.complete()
		if point.y == gate_y:
			gate_cell = anchor
		else:
			wall_cells.append(anchor)
	if gate_cell == -1 or wall_cells.is_empty():
		_expect(false, "a wall and gate could be raised for the funnel check")
		return

	# Two separate settling requirements, and missing either one measures a different world than
	# the one under test. Raising a building updates World.move_cost deferred, so the layers are
	# not solid until a frame has passed; and FlowField only swaps a finished sweep into `cost`
	# on _commit(), so a half-built field still reports the PREVIOUS one. Wait for the first,
	# then drive the second to completion by hand.
	for _frame in 4:
		await run.get_tree().process_frame
	var field: FlowField = Threat.threat_field
	field.begin(Threat._goal_cells())
	var sweeps := 0
	while field.building and sweeps < 500:
		field.step(Threat.FIELD_BUDGET)
		sweeps += 1
	_expect(not field.building, "the threat field finished rebuilding for the check")

	var wall_is_goal := false
	var cheapest_wall := FlowField.UNREACHABLE
	for cell in wall_cells:
		if field.cost[cell] == 0:
			wall_is_goal = true
		cheapest_wall = mini(cheapest_wall, field.cost[cell])
	_expect(not wall_is_goal,
		"a wall is not something the horde walks toward")
	_expect(field.cost[gate_cell] < cheapest_wall,
		"the gate is the cheapest way through the line, so a wall funnels (gate %d < wall %d)"
			% [field.cost[gate_cell], cheapest_wall])


## Goods have to survive the person carrying them.
##
## Before spills, a load died with its porter — silently, into an aggregate that never showed it
## leave. A colony could lose a day of wood to one bad night and have no way of knowing. Now the
## load lands on the tile they fell on and a Worker has to walk out and get it, which is both the
## honest accounting and the reason a body on the road is worth looking at.
func _check_loose_drops_are_recovered() -> void:
	Colony.loose_drops.clear()
	var villager: Villager = Colony.villagers[0]
	villager._release_target()
	villager._release_workplace()
	villager.set_job(&"worker")
	villager.food = 80.0
	villager.water = 80.0
	villager.rest = 80.0

	# A pile appears where a load is dropped, and reports itself.
	var drop_cell := World.nearest_walkable(World.keep_cell, 6)
	var drop := Colony.drop_resource(&"wood", 9, drop_cell, &"test")
	_expect(Colony.loose_resource_total() == 9 \
			and Colony.nearest_worker_drop(drop_cell) == drop.id,
		"dropped goods lie on the ground where they fell")

	var worker_job := Jobs.get_job(&"worker")
	_expect(worker_job != null and worker_job.hauls,
		"the Worker is the job that collects them")

	# A Worker standing on it picks it up and carries it off.
	villager.position = World.grid.to_world_index(drop_cell)
	villager.stop()
	villager.state = Villager.State.IDLE
	villager.carry_amount = 0
	villager.carry_kind = &""
	for _think in 8:
		villager.think(0.1)
	_expect(Colony.loose_resource_total() < 9,
		"a Worker walks out and recovers the pile (%d left)" % Colony.loose_resource_total())

	# And building outranks it: a site on the ground must not wait on tidying.
	_expect(worker_job.target_features.is_empty() and worker_job.workplace.is_empty(),
		"the Worker has no fixed workplace, so construction still outranks loose recovery")

	Colony.loose_drops.clear()
	villager.set_job(&"")


func _check_essence_and_local_energy(run: Node2D) -> void:
	Colony.loose_drops.clear()
	var altar := Buildings.get_building(&"essence_altar")
	var occultist := Jobs.get_job(&"occultist")
	_expect(altar != null and altar.worker_slots == 1 and altar.workplace_key() == &"essence_altar" \
			and occultist != null and occultist.loose_yield_kind == Colony.ESSENCE_KIND \
			and occultist.loose_yield_amount == 3 and is_equal_approx(occultist.cycle_work, 20.0),
		"the Altar and Occultist form a one-worker, twenty-second physical Essence loop")

	var drop_cell := World.nearest_walkable(World.keep_cell, 4)
	var essence := Colony.drop_essence(drop_cell, 3, &"test")
	var packed := Colony.pack_loose_drops()
	Colony.restore_loose_drops(packed, Colony._next_loose_drop_id)
	var restored := Colony.loose_drop(essence.id)
	_expect(restored != null and restored.amount == 3 and restored.source == &"test" \
			and restored.expires_tick > Sim.tick,
		"Essence keeps identity, source, amount and one-day expiry through serialization")
	restored.expires_tick = Sim.tick
	Colony._loose_drop_timer = Colony.LOOSE_DROP_STEP
	Colony._step_loose_drops(0.0)
	_expect(Colony.essence_total() == 0, "expired Essence leaves the board after one in-game day")

	var hand := run.get_node("GodHand")
	Divine.faith = maxf(Divine.faith_max() - 10.0, 0.0)
	Colony.drop_essence(drop_cell, 2, &"hand_test")
	var faith_before := Divine.faith
	var swept: int = int(hand.sweep_essence_at(drop_cell))
	_expect(swept == 2 and Divine.faith == minf(faith_before + 2.0, Divine.faith_max()),
		"a Hand sweep turns board Essence into the existing Faith economy")

	var collector_def := Buildings.get_building(&"essence_collector")
	var anchor := _find_open_anchor(collector_def)
	_expect(collector_def != null and anchor != -1 and collector_def.energy_capacity == 150 \
			and collector_def.energy_radius == 12 and collector_def.energy_per_essence == 3,
		"the first Collector stores 150 energy and powers only a twelve-tile district")
	if collector_def == null or anchor == -1:
		return
	var collector: Building = BUILDING_SCENE.instantiate()
	collector.setup(collector_def, anchor)
	collector.position = Colony._building_origin(collector_def, anchor)
	run.entities.add_child(collector)
	collector.complete()
	Colony.drop_essence(collector.centre_cell(), 4, &"collector_test")
	Colony._loose_drop_timer = Colony.LOOSE_DROP_STEP
	Colony._step_loose_drops(0.0)
	_expect(collector.stored_energy == 12 and Colony.essence_total() == 0,
		"a Collector physically absorbs motes at three local energy each")
	var available := Colony.energy_available_near(collector.centre_cell())
	_expect(available == 12 and Colony.draw_energy_near(collector.centre_cell(), 5) \
			and collector.stored_energy == 7,
		"local consumers draw atomically from a Collector covering their tile")
	var far := World.grid.index(0, 0)
	if World.grid.dist_sq(far, collector.centre_cell()) <= collector_def.energy_radius \
			* collector_def.energy_radius:
		far = World.grid.index(World.grid.width - 1, World.grid.height - 1)
	_expect(not Colony.draw_energy_near(far, 1),
		"Collector energy cannot be spent by a building outside its physical radius")

	var magical_def := BuildingDef.new()
	magical_def.id = &"test_magic"
	magical_def.footprint = Vector2i.ONE
	magical_def.energy_per_shot = 5
	var magical: Building = BUILDING_SCENE.instantiate()
	magical.setup(magical_def, collector.centre_cell())
	run.entities.add_child(magical)
	_expect(magical._consume_ammo() and collector.stored_energy == 2 \
			and not magical._consume_ammo() and collector.stored_energy == 2,
		"a magical shot spends local energy and refuses to fire when the district runs dry")
	magical.queue_free()
	collector.destroy()
	Colony.loose_drops.clear()


## Ammunition is a physical delivery, not a radius check against global stock. The same request
## ledger supplies workshop inputs, but a tower is the sharpest regression case: an empty local
## magazine must refuse to shoot even when a distant store is full.
func _check_physical_supply(run: Node2D) -> void:
	Sim.set_phase(Sim.Phase.DAY)
	var tower_def := Buildings.get_building(&"bow_tower")
	var anchor := _find_open_anchor(tower_def)
	_expect(tower_def != null and anchor != -1,
		"an ammunition tower has valid test ground")
	if tower_def == null or anchor == -1:
		return
	var tower: Building = BUILDING_SCENE.instantiate()
	tower.setup(tower_def, anchor)
	tower.position = Colony._building_origin(tower_def, anchor)
	run.entities.add_child(tower)
	tower.complete()

	var initial_arrows := Colony.amount_of(&"arrows")
	Colony.add(&"arrows", 24)
	var distant_total := Colony.amount_of(&"arrows")
	_expect(tower.input_free() == 12 and not tower._consume_ammo() \
			and Colony.amount_of(&"arrows") == distant_total,
		"an empty tower cannot fire ammunition from distant storage")

	var worker: Villager = Colony.villagers[0]
	var second: Villager = Colony.villagers[1]
	var old_job := worker.job
	worker._release_target()
	worker._release_workplace()
	worker.set_job(&"worker")
	worker.food = 80.0
	worker.water = 80.0
	worker.rest = 80.0
	worker.carry_kind = &""
	worker.carry_amount = 0
	worker.state = Villager.State.IDLE
	worker._seek_work()
	var request_id := worker._supply_request_id
	_expect(request_id > 0 and int(Colony.supply_reserved.get(&"arrows", 0)) == 12,
		"a Worker reserves a twelve-shot tower load before collecting it")

	# A second Worker may find a different request, but never the already-promised tower load.
	var duplicate := Colony.claim_supply_request(second, second.cell(), 12)
	_expect(duplicate.is_empty() or int(duplicate.get("id", 0)) != request_id,
		"two Workers cannot duplicate the same supply request")
	if not duplicate.is_empty():
		Colony.release_supply_request(int(duplicate["id"]), second)

	worker._cancel_path_request()
	worker.position = World.grid.to_world_index(worker._fetch_from)
	worker.stop()
	worker.state = Villager.State.FETCHING
	worker._tick_fetching()
	var carried := worker.carry_amount
	_expect(carried == 12 and worker.carry_kind == &"arrows" \
			and int(Colony.supply_reserved.get(&"arrows", 0)) == 0 \
			and Colony.amount_of(&"arrows") + carried == distant_total,
		"pickup moves reserved ammunition into the carrier without duplication")

	# Loading discards stale shelf/path promises and rebuilds only what a real carrier holds.
	var packed := Colony.pack_supply_requests()
	Colony.restore_supply_requests(packed)
	Colony.rebuild_supply_reservations_from_carriers()
	var restored_request: SupplyRequest = null
	for request in Colony.supply_requests:
		if request.id == request_id:
			restored_request = request
			break
	_expect(restored_request != null and restored_request.reserved == carried \
			and restored_request.shelf_reserved == 0,
		"reload rebuilds a supply promise from the ammunition actually in transit")

	worker._cancel_path_request()
	worker._supply_destination = tower
	worker.position = World.grid.to_world_index(tower.work_cell())
	worker.stop()
	worker.state = Villager.State.DELIVERING
	worker._tick_delivering()
	_expect(worker.carry_amount == 0 and int(tower.input_buffer.get(&"arrows", 0)) == 12 \
			and Colony.amount_of(&"arrows") == distant_total,
		"the Worker visibly refills the tower and conserves every unit")

	var before_shot := Colony.amount_of(&"arrows")
	_expect(tower._consume_ammo() and Colony.amount_of(&"arrows") == before_shot - 1 \
			and int(tower.input_buffer.get(&"arrows", 0)) == 11,
		"firing consumes exactly one unit from the local magazine")

	# Death follows the same release-then-spill order as interruption, but exercises the real hook:
	# the destination promise disappears while the carried arrow remains on its exact death tile.
	var doomed: Villager = preload("res://scenes/entities/villager.tscn").instantiate()
	doomed.position = World.grid.to_world_index(World.keep_cell)
	run.entities.add_child(doomed)
	doomed.set_job(&"worker")
	var porter_def := Jobs.get_job(&"worker")
	var assigned := doomed._begin_supply_fetch(porter_def)
	if assigned:
		doomed._cancel_path_request()
		doomed.position = World.grid.to_world_index(doomed._fetch_from)
		doomed.stop()
		doomed.state = Villager.State.FETCHING
		doomed._tick_fetching()
	var before_death_total := Colony.amount_of(&"arrows") + doomed.carry_amount \
		+ Colony.loose_resource_total()
	doomed.die(&"test_supply")
	_expect(assigned and int(Colony.supply_reserved.get(&"arrows", 0)) == 0 \
			and Colony.amount_of(&"arrows") + Colony.loose_resource_total() == before_death_total,
		"a porter's death releases the request and drops, rather than deletes, its load")
	await get_tree().process_frame

	# Destruction evacuates the remaining magazine before the request is removed.
	var before_destroy_stock := Colony.amount_of(&"arrows")
	tower.destroy()
	_expect(Colony.amount_of(&"arrows") == before_destroy_stock,
		"destroying a supplied tower preserves its remaining ammunition")
	var added_left := maxi(Colony.amount_of(&"arrows") - initial_arrows, 0)
	Colony.withdraw_any(&"arrows", added_left)
	worker.set_job(old_job)


func _find_open_anchor(def: BuildingDef) -> int:
	if def == null:
		return -1
	var origin := World.grid.coord(World.keep_cell)
	for radius in range(4, 22):
		for y in range(origin.y - radius, origin.y + radius + 1):
			for x in range(origin.x - radius, origin.x + radius + 1):
				var anchor := World.grid.index(x, y)
				if anchor == -1:
					continue
				var cells := World.grid.footprint_cells(Vector2i(x, y), def.footprint)
				if cells.is_empty():
					continue
				var open := true
				for cell in cells:
					if World.claimed[cell] != 0 \
							or not Terrain.WALKABLE.get(World.terrain[cell], false) \
							or Terrain.blocks_building(World.feature[cell]):
						open = false
						break
				if open:
					return anchor
	return -1


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
