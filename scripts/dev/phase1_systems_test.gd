extends Node
## Focused regression for the Phase-1 defence, repair, production, and bridge slice.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")
const TEST_SEED := 410731

var _failures := PackedStringArray()


func _ready() -> void:
	RunSave.clear()
	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame
	Sim.set_paused(true)

	_expect(Buildings.all().size() >= 44, "the expanded launch catalog loads")
	_expect(Jobs.all().size() >= 17, "the expanded job catalog loads")
	_expect(Colony.KINDS.size() == 14, "all fourteen Phase-1 resources are registered")
	var watchtower := Buildings.get_building(&"watchtower")
	var shrine := Buildings.get_building(&"shrine")
	_expect(watchtower != null and watchtower.tier == 1 and watchtower.unlock_cost == 0,
		"Watchtower is available on the first run")
	_expect(shrine != null and shrine.tier == 1 and shrine.unlock_cost == 0,
		"Shrine is available on the first run")
	_expect(Powers.all().size() == 20, "the complete twenty-miracle roster loads")
	_expect(DamageTypes.apply(100.0, {&"piercing": 0.4}, &"piercing") == 60.0,
		"typed resistance reduces incoming damage")
	_expect(DamageTypes.apply(100.0, {&"fire": -0.25}, &"fire") == 125.0,
		"typed vulnerability increases incoming damage")
	var hand: Node = run.get_node("GodHand")
	var lifted: Villager = Colony.villagers[0]
	var lifted_from := lifted.cell()
	var drop := _different_walkable(lifted_from)
	Divine.faith = 100.0
	hand.set_hand_mode(true)
	hand._handle_hand_tap(lifted.position)
	_expect(hand.held == lifted and lifted.held_by_hand,
		"explicit Hand mode lifts a villager without colliding with move orders")
	var faith_before_hand := Divine.faith
	hand._handle_hand_tap(World.grid.to_world_index(drop))
	_expect(hand.held == null and lifted.cell() == drop and Divine.faith < faith_before_hand,
		"the Hand previews a held state then spends distance-scaled Faith on drop")
	hand.set_hand_mode(false)

	for kind: StringName in Colony.KINDS:
		Colony.add(kind, 500)
		Colony.reserved[kind] = 0

	var entities := run.get_node("WorldView/Sorted/Entities")
	var tower: Building = _force_raise(Buildings.get_building(&"bow_tower"), entities)
	_expect(tower != null, "an ammunition tower can be raised")
	if tower != null:
		tower.input_buffer[tower.def.ammo_kind] = 2
		Colony.rebuild_stock_cache()
		var arrows_before := Colony.amount_of(&"arrows")
		_expect(tower._consume_ammo(), "a loaded tower can take one shot")
		_expect(Colony.amount_of(&"arrows") == arrows_before - 1,
			"tower fire conserves and consumes declared ammunition")
		var policy_before := tower.target_policy
		tower.cycle_target_policy()
		_expect(tower.target_policy != policy_before, "tower target policy cycles at runtime")
		var wood_before := Colony.amount_of(&"boards")
		tower.hp -= 70.0
		var hp_before := tower.hp
		tower.add_repair_work(tower.def.repair_work)
		_expect(tower.hp > hp_before and Colony.amount_of(&"boards") < wood_before,
			"repair work spends its declared material and restores health")

	var workshop: Building = _force_raise(Buildings.get_building(&"bowyer"), entities)
	_expect(workshop != null, "a policy-controlled workshop can be raised")
	if workshop != null:
		workshop.production_worker_limit = 1
		workshop.production_target = Colony.amount_of(&"arrows")
		var fletching := Jobs.get_job(&"fletching")
		_expect(workshop.effective_worker_slots() == 1,
			"workshop worker limits are enforced")
		_expect(not workshop.production_is_available(fletching),
			"maintain-stock policy pauses completed output")
		workshop.production_target += 1
		_expect(workshop.production_is_available(fletching),
			"maintain-stock policy resumes below target")

	var temple: Building = _force_raise(shrine, entities)
	var effigy_power := Powers.get_power(&"labor_effigy")
	var effigy_cell := _valid_golem_cell()
	var upkeep_before := Divine.building_upkeep()
	Divine.taken_up.append(effigy_power.id)
	Divine.faith = 100.0
	_expect(temple != null and effigy_cell != -1 \
		and Divine.cast(effigy_power, World.grid.to_world_index(effigy_cell)),
		"a persistent Labor Effigy can be called onto valid ground")
	_expect(Divine.building_upkeep() > upkeep_before,
		"persistent constructs reserve ongoing Faith through building upkeep")
	Divine.set_library_auto_manage(false)
	for i in 4:
		var tome := Divine.Tome.new()
		tome.archetype = &"ashen_codex"
		tome.toughness = 0.8 + float(i) * 0.1
		Divine.tomes.append(tome)
	_expect(Divine.install_tome(0) and Divine.toggle_tome_lock(0),
		"the touch library can manually install and lock a Tome")
	_expect(Divine.combine_tome(1) and Divine.tomes.size() == 2,
		"the touch library can combine three chosen unlocked shelved Tomes")
	var library_rows := Divine.pack_library()
	Divine.restore_library(library_rows, false)
	_expect(not Divine.auto_manage_library and Divine.tomes.size() == 2 \
		and Divine.tomes[0].installed and Divine.tomes[0].locked,
		"manual library mode and Tome state survive serialization")
	var effigy: Golem = Colony.golems[0] if not Colony.golems.is_empty() else null
	if effigy != null:
		var effigy_from := effigy.cell()
		hand.set_hand_mode(true)
		hand._handle_hand_tap(effigy.position)
		_expect(hand.held == effigy and effigy.held_by_hand,
			"the Hand can lift a persistent friendly construct")
		var effigy_drop := _different_walkable(effigy_from)
		var faith_before_construct := Divine.faith
		_expect(effigy_drop != -1 and hand._handle_hand_tap(
			World.grid.to_world_index(effigy_drop)) and effigy.cell() == effigy_drop \
			and not effigy.held_by_hand and Divine.faith < faith_before_construct,
			"construct relocation previews validity and moves the mobile agent")
		hand.set_hand_mode(false)

	var bridge_cell := _shallow_water_cell()
	_expect(bridge_cell != -1, "the generated map contains shallow water for a bridge check")
	if bridge_cell != -1:
		World.influence[bridge_cell] = 255
		var bridge: Building = _raise_at(Buildings.get_building(&"bridge"), bridge_cell, entities)
		_expect(bridge != null, "a bridge can be placed over shallow water")
		if bridge != null:
			World.rebuild_move_cost()
			_expect(World.is_walkable(bridge_cell), "a completed bridge opens the water cell to paths")
			bridge.destroy()
			World.rebuild_move_cost()
			_expect(not World.is_walkable(bridge_cell), "removing a bridge closes the water cell again")

	RunSave.clear()
	_report()


func _raise(def: BuildingDef, parent: Node) -> Building:
	if def == null:
		return null
	for cell in World.grid.cell_count:
		var check := Colony.check_placement(def, cell)
		if bool(check.get("ok", false)):
			return _raise_at(def, cell, parent)
	return null


func _valid_anchor(def: BuildingDef) -> int:
	if def == null:
		return -1
	for cell in World.grid.cell_count:
		if bool(Colony.check_placement(def, cell).get("ok", false)):
			return cell
	return -1


func _valid_golem_cell() -> int:
	for cell in World.grid.cell_count:
		if World.is_walkable(cell) and World.in_influence(cell):
			return cell
	return -1


func _raise_at(def: BuildingDef, cell: int, parent: Node) -> Building:
	var placed := Colony.place_building(def, cell, parent) as Building
	if placed != null:
		placed.complete()
	return placed


func _force_raise(def: BuildingDef, parent: Node) -> Building:
	if def == null:
		return null
	for cell in World.grid.cell_count:
		var cells := World.grid.footprint_cells(World.grid.coord(cell), def.footprint)
		if cells.is_empty():
			continue
		var valid := true
		for footprint_cell in cells:
			if World.claimed[footprint_cell] != 0 \
					or not Terrain.WALKABLE.get(World.terrain[footprint_cell], false) \
					or Terrain.blocks_building(World.feature[footprint_cell]):
				valid = false
				break
		if not valid:
			continue
		var building: Building = BUILDING_SCENE.instantiate()
		building.setup(def, cell)
		building.position = Colony._building_origin(def, cell)
		parent.add_child(building)
		building.complete()
		return building
	return null


func _shallow_water_cell() -> int:
	for cell in World.grid.cell_count:
		if World.terrain[cell] == Terrain.Type.WATER \
				and World.feature[cell] == Terrain.Feature.NONE and World.claimed[cell] == 0:
			return cell
	return -1


func _different_walkable(from: int) -> int:
	var origin := World.grid.coord(from)
	for radius in range(2, 9):
		for offset in [Vector2i(radius, 0), Vector2i(-radius, 0),
				Vector2i(0, radius), Vector2i(0, -radius)]:
			var point: Vector2i = origin + Vector2i(offset)
			if World.grid.is_valid_v(point):
				var cell := World.grid.index_v(point)
				if World.is_walkable(cell):
					return cell
	return from


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Phase 1 systems test ===")
	if _failures.is_empty():
		print("all Phase-1 defence and economy checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
