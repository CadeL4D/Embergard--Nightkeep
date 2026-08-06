class_name Reconstitutor
extends RefCounted
## Rebuilds the awake map from a ColonyLedger. Derived grids are always regenerated.

const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")
const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")
const BLIGHT_WORKER_SCENE := preload("res://scenes/entities/blight_worker.tscn")


static func restore(ledger: ColonyLedger, entities: Node) -> bool:
	if ledger == null or ledger.state.is_empty() or ledger.fallen:
		return false
	var data := ledger.state
	var region_profile := {}
	if not bool(data.get("legacy_generation", false)):
		region_profile = Realm.site(ledger.id)
	World.generate(ledger.seed_value, ledger.keep_cell, region_profile)
	if data.has("terrain"):
		World.terrain = data["terrain"].duplicate()
	if data.has("feature"):
		World.feature = data["feature"].duplicate()
	if data.has("blight"):
		World.blight = data["blight"].duplicate()
	World.region_purified = ledger.purified
	World.rebuild_nest_hp()
	for cell in data.get("nest_hp", {}):
		var at := int(cell)
		if World.nest_hp.has(at):
			World.nest_hp[at] = float(data["nest_hp"][cell])
	World.blight_field.rebuild_frontier()
	World.resources.setup(World)
	World.cost_dirty = true
	World.rebuild_move_cost()
	World._build_shore_index()

	Colony.reset()
	var has_physical_inventory := int(data.get("physical_inventory", 0)) > 0
	if has_physical_inventory:
		Colony.overflow = data.get("overflow", {}).duplicate(true)
		Colony.overflow_spoilage_progress = data.get("overflow_spoilage", {}).duplicate(true)
		Colony.overflow_items = data.get("overflow_items", []).duplicate(true)
		Colony.restore_loose_drops(data.get("loose_drops", []),
			int(data.get("next_loose_drop_id", 1)))
		Colony._next_item_serial = int(data.get("next_item_serial", 1))
	Colony.memorials = data.get("memorials", []).duplicate(true)
	Colony.reserved = data.get("reserved", {}).duplicate(true)
	Colony.quotas = data.get("quotas", {}).duplicate(true)
	Colony.migration_progress = float(data.get("migration_progress", 0.0))
	Colony.set_spawn_parent(entities)

	Divine.reset()
	Threat.reset()
	Threat.set_spawn_parent(entities)
	Threat.night_index = int(data.get("night_index", 0))
	Threat.pressure = float(data.get("threat_pressure", ledger.pressure))
	Threat.set_growth_progress(float(data.get("blight_growth", 0.0)))
	Threat.blight_mass = int(data.get("blight_mass",
		World.live_nest_cells().size() * Threat.INITIAL_MASS_PER_NEST))
	DefenseControl.load_dict(data.get("defense_control", {}))

	for cell in data.get("blight_structures", {}):
		var at := int(cell)
		var row: Dictionary = data["blight_structures"][cell]
		var struct_def := BlightStructures.get_structure(StringName(row.get("kind", &"")))
		if struct_def == null or not World.add_blight_structure(at, struct_def,
				bool(row.get("initial_outpost", false))):
			continue
		World.blight_structures[at]["hp"] = float(row.get("hp", struct_def.max_hp))
		World.blight_structures[at]["cooldown"] = float(row.get("cooldown", 0.0))
	Threat.restore_progression_state(data.get("blight_progression", {
		"regional_boss_spawned": int(data.get("blight_boss_stage", 0)) >= 1,
		"heart_warden_spawned": int(data.get("blight_boss_stage", 0)) >= 2,
	}))
	if World.region_purified:
		Threat.complete_regional_purification()

	_restore_buildings(data.get("buildings", []), entities)
	Colony.restore_supply_requests(data.get("supply_requests", []))
	if has_physical_inventory:
		Colony.rebuild_stock_cache()
	else:
		# Schemas 2-7 owned one global stock dictionary. Put it into completed
		# stores deterministically, then keep any excess at the Hearth.
		Colony.distribute_legacy_stock(data.get("stock", {}))
	_restore_villagers(data.get("villagers", []), entities)
	Colony.rebuild_supply_reservations_from_carriers()
	Colony.refresh_households()
	_restore_blight_workers(data.get("blight_workers", []), entities)
	if data.has("taken_up_powers"):
		Divine.taken_up.clear()
		for value in data.get("taken_up_powers", []):
			var power_id := StringName(value)
			if Powers.get_power(power_id) != null:
				Divine.taken_up.append(power_id)
	Divine.restore_library(data.get("tomes", []), bool(data.get("library_auto_manage", true)))
	Divine.place_ember(int(data.get("ember_cell", World.keep_cell)))
	Divine.faith = float(data.get("faith", 20.0))
	Events.map_generated.emit()
	return true


static func _restore_buildings(rows: Array, entities: Node) -> void:
	for row: Dictionary in rows:
		var def := Buildings.get_building(StringName(row.get("def", &"")))
		if def == null:
			continue
		var b: Building = BUILDING_SCENE.instantiate()
		b.setup(def, int(row.get("anchor", World.keep_cell)))
		b.delivered = row.get("delivered", {}).duplicate(true)
		b.work_done = float(row.get("work", 0.0))
		b.target_policy = StringName(row.get("target_policy", def.default_target_policy))
		b.repair_priority = int(row.get("repair_priority", 1))
		b.repair_progress = float(row.get("repair_progress", 0.0))
		b.production_paused = bool(row.get("production_paused", false))
		b.production_worker_limit = int(row.get("production_worker_limit", -1))
		b.production_priority = int(row.get("production_priority", 1))
		b.production_target = int(row.get("production_target", -1))
		b.hallowed_remaining = float(row.get("hallowed_remaining", 0.0))
		b.inventory = row.get("inventory", {}).duplicate(true)
		b.item_inventory = row.get("items", []).duplicate(true)
		b.spoilage_progress = row.get("spoilage_progress", {}).duplicate(true)
		b.input_buffer = row.get("input_buffer", {}).duplicate(true)
		b.output_buffer = row.get("output_buffer", {}).duplicate(true)
		b.stored_energy = clampi(int(row.get("stored_energy", 0)), 0, def.energy_capacity)
		b.position = Colony._building_origin(def, b.anchor)
		entities.add_child(b)
		if bool(row.get("complete", false)):
			b.complete()
			b.hp = float(row.get("hp", def.max_hp))
		elif int(row.get("state", Building.State.BLUEPRINT)) == Building.State.DEMOLISHING:
			b.state = Building.State.DEMOLISHING
			b.salvage = row.get("salvage", {}).duplicate(true)
			b.demolish_done = float(row.get("demolish_done", 0.0))


static func _restore_villagers(rows: Array, entities: Node) -> void:
	for row: Dictionary in rows:
		var v: Villager = VILLAGER_SCENE.instantiate()
		v.position = Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0)))
		entities.add_child(v)
		v.job = StringName(row.get("job", &""))
		v.food = float(row.get("food", 80.0))
		v.water = float(row.get("water", 80.0))
		v.rest = float(row.get("rest", 80.0))
		v.mood = float(row.get("mood", 60.0))
		v.health = float(row.get("health", v.max_health))
		v.carry_kind = StringName(row.get("carry_kind", &""))
		v.carry_amount = int(row.get("carry_amount", 0))
		v._supply_request_id = int(row.get("supply_request_id", 0))
		v.pending_loads = row.get("pending_loads", []).duplicate(true)
		v.statuses = row.get("statuses", {}).duplicate(true)
		if row.has("record"):
			v.restore_profile(row.get("record", {}))


static func _restore_blight_workers(rows: Array, entities: Node) -> void:
	for row: Dictionary in rows:
		var worker: BlightWorker = BLIGHT_WORKER_SCENE.instantiate()
		worker.setup(int(row.get("home", World.keep_cell)))
		worker.position = Vector2(float(row.get("x", 0.0)), float(row.get("y", 0.0)))
		entities.add_child(worker)
		worker.restore_record(row)
