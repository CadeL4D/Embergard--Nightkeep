class_name RunSave
extends RefCounted
## Crash-safe persistence for the whole Realm and whichever colony is currently awake.

## 11 is the cohesion-roadmap state: one Core, initial outposts, local containment, permanent
## purification, the regrowing Heart, and physical building-supply requests. This project has no
## released save contract, so older schemas are deliberately invalidated rather than guessed into
## the new progression or logistics state.
const SCHEMA_VERSION := 13


static func has_save() -> bool:
	return SaveService.has_save()


static func clear() -> void:
	SaveService.clear_all()


static func save() -> bool:
	if Realm.awake_id == &"":
		return false
	var data := {
		"version": SCHEMA_VERSION,
		"difficulty": String(Difficulties.current_id()),
		"game_rules": Difficulties.rules_dict(),
		"tick": Sim.tick,
		"day": Sim.day,
		"phase": int(Sim.phase),
		"phase_elapsed": Sim.phase_elapsed,
		"realm": Realm.to_dict(),
		"climate": Climate.to_dict(),
		"storyteller": Storyteller.to_dict(),
	}
	return SaveService.queue_snapshot(data)


static func load_into(_run: Node, entities: Node) -> bool:
	var data = _read()
	if data == null:
		return false
	var version := int(data.get("version", 0))
	if version != SCHEMA_VERSION:
		push_warning("RunSave: schema %d is not supported" % version)
		return false

	if data.has("game_rules"):
		Difficulties.load_rules(data.get("game_rules", {}))
	else:
		Difficulties.select(StringName(data.get("difficulty", Difficulties.DEFAULT_ID)))
	if not Realm.load_dict(data.get("realm", {})):
		return false
	var ledger := Realm.awake_ledger()
	ledger.advance_to(int(data.get("day", 1)))
	if not Reconstitutor.restore(ledger, entities):
		return false

	Sim.start_run()
	Sim.tick = int(data.get("tick", 0))
	Sim.day = int(data.get("day", 1))
	Sim.phase = int(data.get("phase", Sim.Phase.DAY))
	Sim.phase_elapsed = float(data.get("phase_elapsed", 0.0))
	Climate.load_dict(data.get("climate", {"world_seed": Realm.world_seed}))
	Storyteller.load_dict(data.get("storyteller", {
		"world_seed": Realm.world_seed,
		"next_event_day": Sim.day + 2,
	}))
	Events.phase_changed.emit(Sim.phase, Difficulties.phase_duration(Sim.phase))
	Events.colony_awakened.emit(Realm.awake_id)
	if bool(data.get("__autosave_recovered", false)):
		Events.notice.emit(L10n.t(&"SAVE_RECOVERED"), 1)
	return true


static func _read():
	var result := SaveService.read_latest()
	if result.is_empty():
		return null
	var data = result.get("data")
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("RunSave: save file is not a dictionary")
		return null
	data = data.duplicate(true)
	data["__autosave_recovered"] = bool(result.get("recovered", false))
	return data
