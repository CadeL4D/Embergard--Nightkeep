extends Node
## Update 2d campaign acceptance test: fixed topology, migration, permanent loss,
## persistence, and Doom World's profile boundary.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")
const TEST_SEED := 7302026
const REQUIRED_BIOMES: Array[StringName] = [
	&"forest", &"desert", &"marsh", &"dry_lands", &"haven", &"outlands",
]

var _failures := PackedStringArray()
var _profile_snapshot: Dictionary = {}


func _ready() -> void:
	_snapshot_profile()
	RunSave.clear()
	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame
	Sim.set_paused(true)

	_expect(Realm.sites.size() == 45 and Realm.region_states.size() == 45,
		"the campaign contains exactly 45 durable region records")
	_expect(Realm.REGION_WIDTH == 9 and Realm.REGION_HEIGHT == 5,
		"the fixed campaign occupies the authored 9 by 5 topology")
	_expect(Realm.validate_campaign().is_empty(),
		"the region graph is connected, reciprocal, and internally valid")
	var biome_counts := _biome_counts()
	var all_biomes := true
	for biome in REQUIRED_BIOMES:
		all_biomes = all_biomes and int(biome_counts.get(biome, 0)) > 0
	_expect(all_biomes and biome_counts.size() == REQUIRED_BIOMES.size(),
		"Forest, Desert, Marsh, Dry Lands, Haven, and Outlands are all present")
	_expect(_zone_layout_is_correct(),
		"the five cardinal biome zones and hybrid Outlands follow the fixed layout")

	var source_id := Realm.awake_id
	var destination_id := _first_open_neighbour(source_id)
	_expect(destination_id != &"", "the first settlement has a connected expansion region")
	_expect(not bool(Realm.can_found(destination_id).get("ok", false)),
		"expansion is blocked before a Migration Way Station exists")
	var way_station := _force_raise(Buildings.get_building(&"migration_way_station"), run.entities)
	_expect(way_station != null and way_station.def.enables_migration,
		"a completed Migration Way Station unlocks the migration layer")
	_spawn_eligible_adults(Realm.MIGRATION_ELIGIBLE_ADULTS)
	_expect(Realm.eligible_migration_adults().size() >= Realm.MIGRATION_ELIGIBLE_ADULTS,
		"migration requires more than 15 healthy adult villagers")
	for kind: StringName in Realm.SETTLEMENT_COST:
		Colony.add(kind, int(Realm.SETTLEMENT_COST[kind]) + 10)

	var population_before := Colony.population()
	var source_corruption := float(Realm.site(destination_id).get("corruption", 0.0))
	_expect(run.found_realm_site(destination_id),
		"an eligible migration can be scheduled to a connected region")
	_expect(Realm.pending_migrations.size() == 1 \
			and Realm.pending_migrations[0].status == &"scheduled",
		"the migration remains pending until its recorded departure")
	_expect(Realm.awake_id == source_id and Colony.population() == population_before,
		"scheduling does not teleport settlers or switch the active colony")
	var order: MigrationOrder = Realm.pending_migrations[0]
	_expect(order.departure_day == Sim.day + 1 and order.migrants.size() == 5 \
			and order.courier_golems == 2,
		"five migrants and two Courier Golems are reserved for the next dawn")
	Realm._process_migrations(Sim.day)
	_expect(order.status == &"scheduled", "migration cannot depart early")
	Realm._process_migrations(order.departure_day)
	for _frame in 3:
		await get_tree().process_frame
	_expect(order.status == &"departed" and Realm.awake_id == destination_id,
		"the migration departs at the next dawn and wakes its destination")
	_expect(Colony.population() == Realm.MIGRATION_PARTY_SIZE,
		"the new colony contains exactly the snapshotted migrant party")
	_expect(Colony.golem_count(&"courier_golem") == 2,
		"both Courier Golems arrive as physical colony actors")
	var destination_state: RegionState = Realm.region_states[destination_id]
	_expect(destination_state.settlement_day == 1 \
			and is_equal_approx(destination_state.threat_modifier, 0.65),
		"the destination starts on local Day 1 with reduced opening threat")
	_expect(Realm.colony(destination_id).corruption <= source_corruption,
		"migration applies the reduced opening corruption pressure")

	var saved_realm := Realm.to_dict()
	_expect(Realm.load_dict(saved_realm), "the 45-region campaign round-trips through its schema")
	_expect(Realm.pending_migrations.size() == 1 \
			and Realm.pending_migrations[0].status == &"departed",
		"migration manifests and their completion state survive serialization")
	var lost_id := Realm.awake_id
	Realm.mark_awake_fallen()
	_expect(Realm.region_states[lost_id].status == RegionState.Status.LOST,
		"a destroyed settlement is permanently marked Lost")
	_expect(not bool(Realm.can_recover(lost_id).get("ok", false)) \
			and not bool(Realm.prepare_recovery(lost_id).get("ok", false)),
		"no recovery entry point can recolonize a Lost region")

	Meta.god_experience += 73
	Meta.unlocked_chest_slots += 2
	Meta.god_perks[&"test_perk"] = 2
	if &"goal_001" not in Meta.chronicle_completed:
		Meta.chronicle_completed.append(&"goal_001")
	var preserved_meta := _meta_progression_signature()
	_expect(not run.doom_world("reset"), "Doom World rejects any confirmation except exact RESET")
	_expect(run.doom_world("RESET"), "Doom World accepts the exact typed RESET confirmation")
	await get_tree().process_frame
	_expect(Realm.sites.size() == 45 and Realm.colonies.is_empty() and Realm.awake_id == &"",
		"Doom World replaces all region and settlement state")
	_expect(Realm.validate_campaign().is_empty(),
		"the replacement Doom World is again a valid 45-region campaign")
	_expect(_meta_progression_signature() == preserved_meta,
		"God XP, perks, goals, and chest slots survive Doom World")

	run._clear_entities()
	run.queue_free()
	await get_tree().process_frame
	_restore_profile()
	RunSave.clear()
	_report()


func _first_open_neighbour(id: StringName) -> StringName:
	for other: StringName in Realm.site(id).get("connections", []):
		if not Realm.colonies.has(other) and bool(Realm.site(other).get("settleable", false)) \
				and not bool(Realm.site(other).get("blight_core", false)):
			return other
	return &""


func _biome_counts() -> Dictionary:
	var counts: Dictionary = {}
	for id: StringName in Realm.sites:
		var biome := StringName(Realm.site(id).get("biome", &""))
		counts[biome] = int(counts.get(biome, 0)) + 1
	return counts


func _zone_layout_is_correct() -> bool:
	for id: StringName in Realm.sites:
		var row := Realm.site(id)
		var coord: Vector2i = row["coord"]
		var biome := StringName(row["biome"])
		if coord == Vector2i(4, 2) and biome != &"forest":
			return false
		if coord.y == 0 and coord.x in range(3, 6) and biome != &"desert":
			return false
		if coord.x == 8 and coord.y in range(1, 4) and biome != &"marsh":
			return false
		if coord.y == 4 and coord.x in range(3, 6) and biome != &"dry_lands":
			return false
		if coord.x == 0 and coord.y in range(1, 4) and biome != &"haven":
			return false
	return true


func _spawn_eligible_adults(required: int) -> void:
	var keep := World.grid.coord(World.keep_cell)
	var radius := 1
	while Colony.population() < required and radius < 16:
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if Colony.population() >= required:
					break
				if absi(dx) != radius and absi(dy) != radius:
					continue
				var point := keep + Vector2i(dx, dy)
				if not World.grid.is_valid_v(point):
					continue
				var cell := World.grid.index_v(point)
				if World.is_walkable(cell):
					Colony.spawn_villager(cell)
		radius += 1
	for villager: Villager in Colony.villagers:
		villager.profile.age_days = maxi(villager.profile.age_days, villager.profile.adult_age_days)
		villager.profile.thermal_comfort = 100.0
		villager.profile.panic = 0.0
		villager.health = villager.max_health
		villager.statuses.clear()


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


func _meta_progression_signature() -> String:
	return var_to_str({
		"god_experience": Meta.god_experience,
		"unlocked_chest_slots": Meta.unlocked_chest_slots,
		"god_perks": Meta.god_perks,
		"completed_goals": Meta.chronicle_completed,
		"chests": Meta.chests,
	})


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
		"unlocked_chest_slots": Meta.unlocked_chest_slots,
		"chest_progress": Meta.chest_progress,
		"chests": Meta.chests.duplicate(true),
		"god_perks": Meta.god_perks.duplicate(true),
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
	Meta.unlocked_chest_slots = int(_profile_snapshot["unlocked_chest_slots"])
	Meta.chest_progress = float(_profile_snapshot["chest_progress"])
	Meta.chests.assign(_profile_snapshot["chests"])
	Meta.god_perks = _profile_snapshot["god_perks"].duplicate(true)
	Meta.save_profile()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Update 2d campaign result ===")
	if _failures.is_empty():
		print("all Update 2d campaign checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
