class_name Abstractor
extends RefCounted
## Turns the awake scene into its exact ColonyLedger representation.


static func capture(ledger: ColonyLedger) -> void:
	ledger.seed_value = World.seed_value
	ledger.keep_cell = World.keep_cell
	ledger.last_advanced_day = Sim.day
	ledger.pressure = Threat.pressure
	var state := {
		"terrain": World.terrain.duplicate(),
		"feature": World.feature.duplicate(),
		"blight": World.blight.duplicate(),
		"nest_hp": World.nest_hp.duplicate(true),
		"blight_structures": World.blight_structures.duplicate(true),
		"blight_growth": Threat.growth_progress(),
		"stock": Colony.stock.duplicate(true),
		"reserved": Colony.reserved.duplicate(true),
		"quotas": Colony.quotas.duplicate(true),
		"migration_progress": Colony.migration_progress,
		"faith": Divine.faith,
		"ember_cell": Divine.ember_cell,
		"night_index": Threat.night_index,
		"threat_pressure": Threat.pressure,
		"villagers": _pack_villagers(),
		"buildings": _pack_buildings(),
	}
	ledger.state = state
	var blighted := 0
	for value in World.blight:
		if value > 0:
			blighted += 1
	ledger.corruption = float(blighted) / float(maxi(World.blight.size(), 1))
	ledger.fallen = state["villagers"].is_empty()


static func _pack_villagers() -> Array:
	var out: Array = []
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		out.append({
			"x": v.position.x,
			"y": v.position.y,
			"job": v.job,
			"food": v.food,
			"water": v.water,
			"rest": v.rest,
			"mood": v.mood,
			"health": v.health,
		})
	return out


static func _pack_buildings() -> Array:
	var out: Array = []
	for b in Colony.buildings:
		if not is_instance_valid(b):
			continue
		out.append({
			"def": b.def.id,
			"anchor": b.anchor,
			"complete": b.state == Building.State.COMPLETE,
			"state": int(b.state),
			"work": b.work_done,
			"hp": b.hp,
			"delivered": b.delivered.duplicate(true),
			"salvage": b.salvage.duplicate(true),
			"demolish_done": b.demolish_done,
		})
	return out
