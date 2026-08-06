extends Node
## Focused regional Realm test: deterministic macro generation, separate colonies,
## persistence, sleeping simulation, spatial wards, UI layout, and victory.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 7302026

var _failures := PackedStringArray()
var _profile_snapshot := {}


func _ready() -> void:
	_snapshot_profile()
	RunSave.clear()
	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", true)
	await get_tree().process_frame
	var first_picker := run.get_node("RealmMap")
	_expect(first_picker.visible and Realm.awake_id == &"",
		"a new world opens on the regional map before a colony exists")
	var first_canvas: RealmMapCanvas = first_picker.get_node(
		"Backdrop/Safe/Panel/Layout/Main/MapFrame/Map")
	_expect(not first_canvas.zoomed_in,
		"the world opens as a clean gridless overview")
	await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
		var first_image := get_viewport().get_texture().get_image()
		_expect(first_image.save_png("res://artifacts/phase4_world_select.png") == OK,
			"the first-settlement regional screen can be captured for visual QA")
	var picked_region := Realm.suggested_first_region()
	var exact_region_hits := true
	for y in Realm.REGION_HEIGHT:
		for x in Realm.REGION_WIDTH:
			var region_id := Realm.region_id(Vector2i(x, y))
			if first_canvas._site_from_point(first_canvas._region_rect(region_id).get_center()) \
					!= region_id:
				exact_region_hits = false
	_expect(exact_region_hits,
		"every visible overview region opens the same local region at its centre")
	# Desktop delivers one physical click as a mouse press and an emulated touch.
	# The second event used to hit Back on the newly-open preview and make it flash.
	await get_tree().process_frame
	var edge_region := Realm.region_id(Vector2i(0, 0))
	var edge_point := first_canvas._region_rect(edge_region).get_center()
	var mouse_click := InputEventMouseButton.new()
	mouse_click.button_index = MOUSE_BUTTON_LEFT
	mouse_click.pressed = true
	mouse_click.position = edge_point
	first_canvas._gui_input(mouse_click)
	var touch_twin := InputEventScreenTouch.new()
	touch_twin.index = 0
	touch_twin.pressed = true
	touch_twin.position = edge_point
	first_canvas._gui_input(touch_twin)
	_expect(first_canvas.zoomed_in and is_equal_approx(first_canvas._zoom_progress, 1.0),
		"a mouse/touch twin opens the local map once and does not flash back out")
	first_canvas.reset_view()
	_expect(Realm.corruption_sources.size() >= 3,
		"latent local corruption is distributed across multiple hidden places")
	var latent_before := float(Realm.site(picked_region)["corruption"])
	Realm._on_day_advanced(5)
	_expect(is_equal_approx(float(Realm.site(picked_region)["corruption"]), latent_before),
		"an unsettled region's latent corruption remains stationary")
	first_canvas.zoom_to(picked_region)
	for _frame in 18:
		await get_tree().process_frame
	_expect(first_canvas.zoomed_in and first_picker._primary.visible,
		"selecting an area zooms into its detailed local preview before confirmation")
	var outside_tap := InputEventScreenTouch.new()
	outside_tap.index = 4
	outside_tap.pressed = true
	outside_tap.position = Vector2(1.0, first_canvas.size.y * 0.5)
	first_canvas._gui_input(outside_tap)
	for _frame in 18:
		await get_tree().process_frame
	_expect(not first_canvas.zoomed_in,
		"tapping beside the local preview returns to the full Realm overview")
	first_canvas.zoom_to(picked_region)
	for _frame in 18:
		await get_tree().process_frame
	if DisplayServer.get_name() != "headless":
		var preview_image := get_viewport().get_texture().get_image()
		_expect(preview_image.save_png("res://artifacts/phase4_region_preview.png") == OK,
			"the selected-region preview can be captured for visual QA")
	_expect(run.found_first_region(picked_region),
		"choosing one square creates that square's full gameplay map")
	run.confirm_site(World.keep_cell)
	_expect(Realm.heart_region_id == picked_region and Realm.awake_id == picked_region,
		"the chosen square becomes the first colony")
	first_picker._finish_first_selection()
	run.start_run(TEST_SEED, &"harried")
	await get_tree().process_frame

	var heart_id := Realm.heart_region_id
	_expect(Realm.sites.size() == Realm.REGION_COUNT,
		"the seed creates a complete 12 by 8 regional world")
	_expect(heart_id != &"" and Realm.awake_id == heart_id,
		"the suggested starting region becomes the first awake colony")
	_expect(Realm.blight_core_id != &"" and Realm.blight_core_id != heart_id,
		"the Blight Heart occupies its own hidden source region")
	_expect(World.seed_value == int(Realm.site(heart_id)["seed"]),
		"the awake gameplay map is generated from its selected region")
	_expect(_macro_local_agreement() >= 0.58,
		"the playable terrain continues the Realm map's water and resource formations")
	_expect(_blight_components() >= 4,
		"a settled local map contains several small separated corruption pockets")

	var first_signature := _world_signature()
	var realm_snapshot := Realm.to_dict()
	Realm.start_new(TEST_SEED)
	_expect(_world_signature() == first_signature,
		"the same world seed regenerates the same coastlines and region traits")
	Realm.start_new(TEST_SEED + 1)
	_expect(_world_signature() != first_signature,
		"a different world seed creates a different regional landscape")
	var progression_reachable := true
	for seed_value in [11, 42, 1337, 8675309]:
		Realm.start_new(seed_value)
		var reachable := Realm._component_from(Realm.suggested_first_region(), Realm.blight_core_id)
		var core: Vector2i = Realm.site(Realm.blight_core_id)["coord"]
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var around := Realm.site_at(core + Vector2i(dx, dy))
				if around.is_empty() or StringName(around.get("biome", &"ocean")) == &"ocean":
					continue
				if not reachable.has(StringName(around["id"])):
					progression_reachable = false
	_expect(progression_reachable,
		"the starting region can reach the Blight Heart containment ring across varied seeds")
	_expect(Realm.load_dict(realm_snapshot), "the live Realm restores after determinism checks")

	for row in [
		[&"wood", 200], [&"stone", 150], [&"food", 200],
		[&"tools", 60], [&"cut_stone", 100],
	]:
		Colony.add(row[0], row[1])
	var heart_pop := Colony.population()
	var heart_wood := Colony.amount_of(&"wood")
	var heart_food := Colony.amount_of(&"food")
	var neighbour_id := _first_open_neighbour(heart_id)
	_expect(neighbour_id != &"", "the first settlement has an adjacent land region")
	_expect(run.found_realm_site(neighbour_id), "an adjacent square can be founded as a colony")
	_expect(Realm.awake_id == neighbour_id, "the founded colony becomes awake")
	_expect(Colony.population() == Realm.SETTLERS_REQUIRED,
		"only the transferred settlers appear in the new colony")
	_expect(Realm.colony(heart_id).population() == heart_pop - Realm.SETTLERS_REQUIRED,
		"the same settlers left the source ledger")
	_expect(Realm.colony(heart_id).stock_of(&"wood") ==
		heart_wood - int(Realm.SETTLEMENT_COST[&"wood"]),
		"founding costs come only from the source colony")
	_expect(Colony.amount_of(&"wood") == int(Realm.STARTING_CARGO[&"wood"]),
		"the new colony begins with only its own caravan cargo")

	Colony.add(&"wood", 33)
	_expect(run.travel_to_colony(heart_id), "travel returns to the adjacent first colony")
	_expect(Colony.amount_of(&"wood") == heart_wood - int(Realm.SETTLEMENT_COST[&"wood"]),
		"the first colony restores its separate wood stockpile")
	_expect(Colony.amount_of(&"food") == heart_food - int(Realm.SETTLEMENT_COST[&"food"]),
		"the first colony restores its separate food stockpile")
	_expect(run.travel_to_colony(neighbour_id), "the new colony can be revisited")
	_expect(Colony.amount_of(&"wood") == int(Realm.STARTING_CARGO[&"wood"]) + 33,
		"the new colony kept its own changed stockpile")
	var zone_cell := World.grid.index_v(World.grid.coord(World.keep_cell) + Vector2i(9, 0))
	DefenseControl.paint_mode = DefenseControl.PaintMode.WORK
	DefenseControl.paint(zone_cell)
	var store_cell := int(Colony.stockpiles[0])
	DefenseControl.cycle_stockpile_filter(store_cell)
	DefenseControl.cycle_stockpile_priority(store_cell)
	Realm.capture_awake()
	_expect(run.travel_to_colony(heart_id), "control-order check can visit the first colony")
	_expect(DefenseControl.work[zone_cell] == 0,
		"painted work areas belong only to their own colony")
	_expect(run.travel_to_colony(neighbour_id), "control-order check returns to the outpost")
	_expect(DefenseControl.work[zone_cell] != 0,
		"the outpost restores its painted work area")
	_expect(DefenseControl.stockpile_filter(store_cell) == DefenseControl.StockFilter.FOOD \
			and DefenseControl.stockpile_priority(store_cell) == 2,
		"stockpile filters and priorities restore with their colony")

	var outpost_food := Colony.amount_of(&"food")
	var heart_food_before := Realm.colony(heart_id).stock_of(&"food")
	_expect(run.send_realm_resource(heart_id, &"food", 10),
		"supplies can cross one shared region edge")
	_expect(Colony.amount_of(&"food") == outpost_food - 10,
		"sending supplies subtracts them from the awake stockpile")
	_expect(Realm.colony(heart_id).stock_of(&"food") == heart_food_before \
			and not Realm.active_routes().is_empty(),
		"dispatched supplies remain in a countable caravan until arrival")
	var supply_route: TradeRoute = Realm.routes.back()
	Realm._process_routes(supply_route.arrival_day)
	var delivered_food := 10 - int(supply_route.lost_cargo.get(&"food", 0))
	_expect(Realm.colony(heart_id).stock_of(&"food") == heart_food_before + delivered_food,
		"arrival delivers exactly the cargo not recorded as an interception loss")

	var original := Realm.colony(heart_id)
	var a := ColonyLedger.from_dict(original.to_dict())
	var b := ColonyLedger.from_dict(original.to_dict())
	var corruption_before := a.corruption
	a.advance_to(a.last_advanced_day + 3)
	b.advance_to(b.last_advanced_day + 3)
	_expect(var_to_str(a.to_dict()) == var_to_str(b.to_dict()),
		"sleeping colonies advance deterministically")
	_expect(a.corruption >= corruption_before,
		"sleeping blight advances the stored local map")

	var awake_before := Realm.awake_id
	var wood_before := Colony.amount_of(&"wood")
	_expect(RunSave.save(), "the multi-colony regional world saves")
	run._clear_entities()
	_expect(RunSave.load_into(run, run.entities), "the multi-colony regional world loads")
	await get_tree().process_frame
	_expect(Realm.colonies.size() == 2, "all separate colony ledgers survive save and load")
	_expect(Realm.awake_id == awake_before, "the awake region survives save and load")
	_expect(Colony.amount_of(&"wood") == wood_before,
		"the awake colony stock survives save and load")
	_expect(DefenseControl.work[zone_cell] != 0,
		"painted control zones survive the run-save round trip")

	var forecast := Threat.next_night_forecast()
	var forecast_names: PackedStringArray = forecast["names"]
	_expect(int(forecast["budget"]) > 0 and not forecast_names.is_empty(),
		"the HUD can forecast the next night's strength and enemy types")
	var power_effects := run.get_node("WorldView/PowerEffects")
	Events.power_cast.emit(&"ward", World.grid.to_world_index(World.keep_cell))
	_expect(power_effects.effects.size() == 1,
		"casting a miracle creates visible world-space feedback")
	power_effects.effects.clear()
	run.camera.zoom = Vector2(0.5, 0.5)
	await get_tree().process_frame
	_expect(run.world_view.influence_overlay.visible,
		"maximum zoom-out automatically reveals the buildable influence sphere")
	run.camera.zoom = Vector2.ONE
	var pause_menu := run.get_node("PauseMenu")
	pause_menu.open()
	_expect(pause_menu.visible and Sim.paused,
		"the in-game menu pauses safely and exposes navigation/settings")
	pause_menu.close()
	_expect(not pause_menu.visible and not Sim.paused,
		"returning from the in-game menu resumes the colony")
	await _check_released_footprints(run)
	DefenseControl.toggle_shelter()
	_expect(DefenseControl.should_shelter(Colony.villagers[0]),
		"the emergency order immediately recalls civilians")
	DefenseControl.toggle_shelter()

	var refugees := Realm.mark_awake_fallen()
	_expect(Realm.colony(neighbour_id).fallen,
		"a lost outpost remains on the Realm as recoverable ruins")
	_expect(run._wake_colony(Realm.heart_region_id, false),
		"survivors can retreat from a fallen outpost to the First Hearth")
	Colony.admit_event_survivors(refugees)
	for kind: StringName in Realm.RECOVERY_COST:
		Colony.add(kind, int(Realm.RECOVERY_COST[kind]))
	_expect(run.recover_colony(neighbour_id),
		"a supplied recovery party can re-enter the fallen colony")
	_expect(not Realm.colony(neighbour_id).fallen \
			and Colony.population() == Realm.RECOVERY_SETTLERS,
		"recovery restores a playable party without regenerating the region")
	_expect(DefenseControl.work[zone_cell] != 0,
		"recovery preserves the ruined colony's painted orders")

	var suppression_before := DefenseControl.nest_suppression_multiplier()
	var live_nests := World.live_nest_cells()
	if not live_nests.is_empty():
		World.damage_nest(live_nests[0], Terrain.NEST_HP * 2.0)
	_expect(DefenseControl.nest_suppression_multiplier() < suppression_before,
		"destroying a nest permanently weakens local corruption spread")
	for nest in World.live_nest_cells():
		World.damage_nest(nest, Terrain.NEST_HP * 2.0)
	for cell in World.blight_structures.keys():
		var def := World.blight_structure_def(int(cell))
		if def != null:
			World.damage_blight_structure(int(cell), def.max_hp * 2.0)
	for hostile in Threat.hostiles.duplicate():
		if is_instance_valid(hostile):
			hostile.die(&"test")
	await get_tree().process_frame
	Colony.add(&"stone", 80)
	Colony.add(&"tools", 40)
	Divine.faith = 60.0
	_expect(DefenseControl.start_cleanse(),
		"a cleared late-game region can begin its final cleansing project")
	for _dawn in DefenseControl.CLEANSE_DAWNS:
		DefenseControl._on_phase_changed(Sim.Phase.DAWN, Sim.PHASE_DURATION[Sim.Phase.DAWN])
	_expect(World.blight_field.coverage() == 0.0 and DefenseControl.cleanse_completed,
		"the cleansing project removes every remaining minor corruption tile")

	heart_id = Realm.heart_region_id
	_expect(run.travel_to_colony(heart_id), "the test returns home before testing protection")
	var purified_ledger := Realm.colony(neighbour_id)
	var purified_blight: PackedByteArray = purified_ledger.state.get(
		"blight", PackedByteArray()).duplicate()
	purified_ledger.advance_to(purified_ledger.last_advanced_day + 2)
	_expect(purified_ledger.purified and purified_ledger.pressure == 0.0 \
			and purified_ledger.corruption == 0.0 \
			and purified_ledger.state.get("blight", PackedByteArray()) == purified_blight,
		"a sleeping purified region cannot regrow Blight or pressure")
	_build_test_containment()
	_expect(Realm.ring_closed(), "developed colonies can ward every region around the Blight Heart")
	var intercepted := 0
	var attempts := 0
	for cell in _boundary_cells():
		for _i in 8:
			attempts += 1
			if Realm.intercept_threat(cell, 4.0):
				intercepted += 1
	_expect(intercepted > 0 and intercepted < attempts,
		"spatial colonies intercept attacks while preserving pressure on the first Hearth")

	var realm_map := run.get_node("RealmMap")
	realm_map.open()
	await get_tree().process_frame
	await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var image: Image = null
	if DisplayServer.get_name() != "headless":
		image = get_viewport().get_texture().get_image()
	if image != null:
		var screenshot_error := image.save_png("res://artifacts/phase4_realm_map.png")
		_expect(screenshot_error == OK and image.get_width() >= 800 and image.get_height() >= 360,
			"the regional world screen renders at the shipping viewport without overlap")
	else:
		_expect(DisplayServer.get_name() == "headless",
			"the regional world screen builds under the headless UI runner")
	realm_map.close()

	Divine.faith = 240.0
	Colony.add(&"tools", 30)
	Colony.add(&"cut_stone", 60)
	var ascension_before := Meta.ascension
	var shatter_result := {"seen": false}
	var on_shatter := func() -> void: shatter_result["seen"] = true
	Events.heart_shattered.connect(on_shatter)
	_expect(Realm.assault_blight_heart(), "containment unlocks the first Heart strike")
	_expect(Realm.blight_heart_health == 200, "a Heart strike deals persistent damage")
	_expect(Realm.assault_blight_heart(), "the second Heart strike spends its own cost")
	_expect(Realm.assault_blight_heart(), "the final Heart strike resolves")
	await get_tree().process_frame
	_expect(bool(shatter_result["seen"]) and Realm.heart_shattered \
			and Realm.heart_regrow_days_left == Realm.HEART_REGROW_DAYS \
			and Sim.running,
		"shattering the spatial Blight Heart leaves the Realm playable")
	_expect(Meta.ascension == ascension_before + 1,
		"shattering the Heart advances ascension exactly once")
	for _day in Realm.HEART_REGROW_DAYS:
		Realm._advance_heart_regrowth()
	_expect(not Realm.heart_shattered \
			and Realm.blight_heart_health == Realm.BLIGHT_HEART_MAX + Realm.HEART_MAX_GROWTH,
		"the Heart regrows stronger for another cycle")
	Events.heart_shattered.disconnect(on_shatter)

	_restore_profile()
	RunSave.clear()
	_report()


func _first_open_neighbour(id: StringName) -> StringName:
	for other: StringName in Realm.site(id).get("connections", []):
		if Realm.colony(other) == null and bool(Realm.site(other).get("settleable", false)):
			return other
	return &""


func _check_released_footprints(run: Node2D) -> void:
	var def := Buildings.get_building(&"path")
	if def == null:
		_expect(false, "the footprint regression test has a path definition")
		return
	for kind: StringName in def.cost:
		Colony.add(kind, int(def.cost[kind]) * 4)
	var anchor := -1
	var keep := World.grid.coord(World.keep_cell)
	for radius in range(3, 18):
		for y in range(keep.y - radius, keep.y + radius + 1):
			for x in range(keep.x - radius, keep.x + radius + 1):
				if not World.grid.is_valid(x, y):
					continue
				var candidate := World.grid.index(x, y)
				if bool(Colony.check_placement(def, candidate)["ok"]):
					anchor = candidate
					break
			if anchor != -1:
				break
		if anchor != -1:
			break
	_expect(anchor != -1, "the footprint regression test finds buildable ground")
	if anchor == -1:
		return

	var neighbour_anchor := -1
	var anchor_coord := World.grid.coord(anchor)
	for offset in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
		var point: Vector2i = anchor_coord + offset
		if World.grid.is_valid_v(point):
			var candidate := World.grid.index_v(point)
			if bool(Colony.check_placement(def, candidate)["ok"]):
				neighbour_anchor = candidate
				break
	_expect(neighbour_anchor != -1, "the drag-preview regression test finds a second path cell")
	if neighbour_anchor != -1:
		var placement := run.get_node("PlacementController")
		var building_count := Colony.buildings.size()
		placement.begin(def)
		placement._set_pending_line(anchor_coord, World.grid.coord(neighbour_anchor))
		_expect(Colony.buildings.size() == building_count,
			"releasing a dragged building line leaves a preview without constructing")
		placement.confirm()
		_expect(Colony.buildings.size() > building_count,
			"a separate confirmation tap commits the released preview")
		for index in range(Colony.buildings.size() - 1, building_count - 1, -1):
			var preview_building = Colony.buildings[index]
			if is_instance_valid(preview_building):
				preview_building.destroy()
		placement.cancel()
		await get_tree().process_frame

	var destroyed := Colony.place_building(def, anchor, run.entities)
	_expect(destroyed != null, "a test building can occupy the regression footprint")
	if destroyed == null:
		return
	destroyed.complete()
	destroyed.destroy()
	await get_tree().process_frame
	_expect(bool(Colony.check_placement(def, anchor)["ok"]),
		"a monster-destroyed building immediately releases its whole footprint")

	var demolished := Colony.place_building(def, anchor, run.entities)
	if demolished != null:
		demolished.complete()
	_expect(demolished != null and demolished.begin_demolish(),
		"a replacement building can begin demolition on the same footprint")
	if demolished == null:
		return
	demolished.demolish_done = demolished.demolish_work()
	demolished.salvage.clear()
	demolished.destroy()
	await get_tree().process_frame
	_expect(bool(Colony.check_placement(def, anchor)["ok"]),
		"a completed demolition also releases the footprint for rebuilding")


func _blight_components() -> int:
	var visited := PackedByteArray()
	visited.resize(World.grid.cell_count)
	var components := 0
	for start in World.grid.cell_count:
		if visited[start] != 0 or World.blight[start] == 0:
			continue
		components += 1
		var queue := PackedInt32Array([start])
		visited[start] = 1
		var head := 0
		while head < queue.size():
			var cell := queue[head]
			head += 1
			for neighbour in World.grid.neighbours_4(cell):
				if visited[neighbour] == 0 and World.blight[neighbour] > 0:
					visited[neighbour] = 1
					queue.append(neighbour)
	return components


func _world_signature() -> String:
	var rows := PackedStringArray()
	for y in Realm.REGION_HEIGHT:
		for x in Realm.REGION_WIDTH:
			var row := Realm.site_at(Vector2i(x, y))
			rows.append("%s:%0.2f:%0.2f" % [
				String(row.get("biome", &"")),
				float(row.get("forest", 0.0)),
				float(row.get("stone", 0.0)),
			])
	return "|".join(rows) + ":" + String(Realm.blight_core_id)


func _macro_local_agreement() -> float:
	var row := Realm.site(Realm.awake_id)
	var coord: Vector2i = row["coord"]
	var matched := 0
	var compared := 0
	for y in range(2, World.grid.height - 2, 3):
		for x in range(2, World.grid.width - 2, 3):
			var cell := World.grid.index(x, y)
			if World.grid.chebyshev(cell, World.keep_cell) <= MapGen.KEEP_CLEAR_RADIUS + 1:
				continue
			var sample := Realm.local_landscape_at(coord,
				Vector2((float(x) + 0.5) / World.grid.width,
					(float(y) + 0.5) / World.grid.height))
			var material := int(sample["material"])
			var agrees := false
			match material:
				0, 7:
					agrees = World.terrain_at(cell) in [
						Terrain.Type.WATER, Terrain.Type.DEEP_WATER]
				1:
					agrees = World.terrain_at(cell) == Terrain.Type.SAND
				8:
					agrees = World.feature_at(cell) == Terrain.Feature.TREE
				9:
					agrees = World.feature_at(cell) == Terrain.Feature.STONE
				_:
					continue
			compared += 1
			if agrees:
				matched += 1
	return float(matched) / float(maxi(compared, 1))


func _build_test_containment() -> void:
	Realm.capture_awake()
	var core: Vector2i = Realm.site(Realm.blight_core_id)["coord"]
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var site := Realm.site_at(core + Vector2i(dx, dy))
			if site.is_empty() or StringName(site.get("biome", &"ocean")) == &"ocean":
				continue
			var id := StringName(site["id"])
			var ledger := Realm.colony(id)
			if ledger == null:
				ledger = ColonyLedger.new()
				ledger.id = id
				ledger.display_name = String(site["name"])
				ledger.seed_value = int(site["seed"])
				ledger.realm_position = Vector2(site["coord"])
				ledger.connections.assign(site["connections"])
				ledger.founded_day = Sim.day
				ledger.last_advanced_day = Sim.day
				ledger.state = Realm.awake_ledger().state.duplicate(true)
				Realm.colonies[id] = ledger
			var people: Array = []
			for _person in 12:
				people.append({
					"x": 0.0, "y": 0.0, "job": &"warrior",
					"food": 80.0, "water": 80.0, "rest": 80.0, "mood": 70.0, "health": 100.0,
				})
			ledger.state["villagers"] = people
			ledger.state["buildings"] = [
				{"def": &"hearth", "complete": true},
				{"def": &"watchtower", "complete": true},
				{"def": &"watchtower", "complete": true},
				{"def": &"watchtower", "complete": true},
			]
			ledger.shield_integrity = 1.0
			ledger.fallen = false
	Events.realm_changed.emit()


func _boundary_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	var middle_x := World.grid.width / 2
	var middle_y := World.grid.height / 2
	out.append(World.grid.index(middle_x, 1))
	out.append(World.grid.index(middle_x, World.grid.height - 2))
	out.append(World.grid.index(1, middle_y))
	out.append(World.grid.index(World.grid.width - 2, middle_y))
	return out


func _snapshot_profile() -> void:
	_profile_snapshot = {
		"shards": Meta.shards,
		"unlocked": Meta.unlocked.duplicate(),
		"ascension": Meta.ascension,
		"best_day": Meta.best_day,
		"runs_played": Meta.runs_played,
		"last_difficulty": Meta.last_difficulty,
		"run_history": Meta.run_history.duplicate(true),
		"lifetime_stats": Meta.lifetime_stats.duplicate(true),
		"achievements": Meta.achievements.duplicate(),
		"chronicle_completed": Meta.chronicle_completed.duplicate(),
		"equipped_doctrines": Meta.equipped_doctrines.duplicate(),
	}


func _restore_profile() -> void:
	Meta.shards = int(_profile_snapshot["shards"])
	Meta.unlocked.assign(_profile_snapshot["unlocked"])
	Meta.ascension = int(_profile_snapshot["ascension"])
	Meta.best_day = int(_profile_snapshot["best_day"])
	Meta.runs_played = int(_profile_snapshot["runs_played"])
	Meta.last_difficulty = StringName(_profile_snapshot["last_difficulty"])
	Meta.run_history.assign(_profile_snapshot["run_history"])
	Meta.lifetime_stats = _profile_snapshot["lifetime_stats"].duplicate(true)
	Meta.achievements.assign(_profile_snapshot["achievements"])
	Meta.chronicle_completed.assign(_profile_snapshot["chronicle_completed"])
	Meta.equipped_doctrines.assign(_profile_snapshot["equipped_doctrines"])
	Meta.save_profile()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Phase 4 regional Realm test ===")
	if _failures.is_empty():
		print("all Phase 4 regional checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
