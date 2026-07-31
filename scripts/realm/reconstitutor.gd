class_name Reconstitutor
extends RefCounted
## Rebuilds the awake map from a ColonyLedger. Derived grids are always regenerated.

const BUILDING_SCENE := preload("res://scenes/entities/building.tscn")
const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")


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
	Colony.stock = data.get("stock", {}).duplicate(true)
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

	for cell in data.get("blight_structures", {}):
		var at := int(cell)
		var row: Dictionary = data["blight_structures"][cell]
		var struct_def := BlightStructures.get_structure(StringName(row.get("kind", &"")))
		if struct_def == null or not World.add_blight_structure(at, struct_def):
			continue
		World.blight_structures[at]["hp"] = float(row.get("hp", struct_def.max_hp))

	_restore_buildings(data.get("buildings", []), entities)
	_restore_villagers(data.get("villagers", []), entities)
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
