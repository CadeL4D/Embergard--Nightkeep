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
		"nest_cells": World.nest_cells.duplicate(),
		"nest_hp": World.nest_hp.duplicate(true),
		"blight_structures": World.blight_structures.duplicate(true),
		"blight_growth": Threat.growth_progress(),
		"blight_mass": Threat.blight_mass,
		"blight_boss_stage": Threat.boss_stage,
		"blight_workers": _pack_blight_workers(),
		"physical_inventory": 1,
		"stock": Colony.stock.duplicate(true),
		"overflow": Colony.overflow.duplicate(true),
		"overflow_spoilage": Colony.overflow_spoilage_progress.duplicate(true),
		"overflow_items": Colony.overflow_items.duplicate(true),
		"next_item_serial": Colony._next_item_serial,
		"memorials": Colony.memorials.duplicate(true),
		"reserved": Colony.reserved.duplicate(true),
		"quotas": Colony.quotas.duplicate(true),
		"migration_progress": Colony.migration_progress,
		"faith": Divine.faith,
		"ember_cell": Divine.ember_cell,
		"taken_up_powers": Divine.taken_up.duplicate(),
		"tomes": Divine.pack_library(),
		"library_auto_manage": Divine.auto_manage_library,
		"night_index": Threat.night_index,
		"threat_pressure": Threat.pressure,
		"defense_control": DefenseControl.to_dict(),
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
			"carry_kind": v.carry_kind,
			"carry_amount": v.carry_amount,
			"pending_loads": v.pending_loads.duplicate(true),
			"statuses": v.statuses.duplicate(true),
			"record": v.profile_dict(),
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
			"target_policy": b.target_policy,
			"repair_priority": b.repair_priority,
			"repair_progress": b.repair_progress,
			"production_paused": b.production_paused,
			"production_worker_limit": b.production_worker_limit,
			"production_priority": b.production_priority,
			"production_target": b.production_target,
			"hallowed_remaining": b.hallowed_remaining,
			"inventory": b.inventory.duplicate(true),
			"items": b.item_inventory.duplicate(true),
			"spoilage_progress": b.spoilage_progress.duplicate(true),
			"input_buffer": b.input_buffer.duplicate(true),
			"output_buffer": b.output_buffer.duplicate(true),
		})
	return out


static func _pack_blight_workers() -> Array:
	var out: Array = []
	for worker in Threat.workers:
		if not is_instance_valid(worker) or not worker.alive:
			continue
		out.append({
			"x": worker.position.x,
			"y": worker.position.y,
			"home": worker.home_cell,
			"carry": worker.carry_mass,
			"task": Threat.worker_task_for_save(worker),
		})
	return out
