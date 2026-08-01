class_name RunSave
extends RefCounted
## Crash-safe persistence for the whole Realm and whichever colony is currently awake.

## 9 adds serialized GameRules and deterministic multi-day TradeRoutes. Schema 7 and earlier are
## still distributed to real stores deterministically during restore.
const SCHEMA_VERSION := 9


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


## Restore a run into the existing Run scene. Schema 2 is migrated to a one-colony Realm so an
## older in-progress game is not discarded by the Phase 4 update.
static func load_into(_run: Node, entities: Node) -> bool:
	var data = _read()
	if data == null:
		return false
	var version := int(data.get("version", 0))
	if version == 2:
		data = _migrate_v2(data)
	elif version not in [3, 4, 5, 6, 7, 8, SCHEMA_VERSION]:
		push_warning("RunSave: schema %d is not supported" % version)
		return false

	if version >= 9 and data.has("game_rules"):
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


static func _migrate_v2(old: Dictionary) -> Dictionary:
	Realm.start_new(int(old.get("seed", 0)))
	var region_id := Realm.suggested_first_region()
	var site: Dictionary = Realm.site(region_id)
	var ledger := ColonyLedger.new()
	ledger.id = region_id
	ledger.display_name = String(site.get("name", "The First Hearth"))
	ledger.seed_value = int(old.get("seed", 0))
	ledger.keep_cell = -1
	ledger.realm_position = Vector2(site.get("coord", Vector2i.ZERO))
	ledger.connections.assign(site.get("connections", []))
	ledger.is_heart = true
	ledger.founded_day = 1
	ledger.last_advanced_day = int(old.get("day", 1))
	ledger.state = {
		"legacy_generation": true,
		"feature": old.get("feature", PackedByteArray()).duplicate(),
		"blight": old.get("blight", PackedByteArray()).duplicate(),
		"nest_hp": old.get("nest_hp", {}).duplicate(true),
		"blight_structures": old.get("blight_structures", {}).duplicate(true),
		"blight_growth": float(old.get("blight_growth", 0.0)),
		"stock": old.get("stock", {}).duplicate(true),
		"reserved": old.get("reserved", {}).duplicate(true),
		"quotas": old.get("quotas", {}).duplicate(true),
		"migration_progress": float(old.get("migration_progress", 0.0)),
		"faith": float(old.get("faith", 20.0)),
		"ember_cell": int(old.get("ember_cell", -1)),
		"night_index": int(old.get("night_index", 0)),
		"threat_pressure": 0.0,
		"villagers": old.get("villagers", []).duplicate(true),
		"buildings": old.get("buildings", []).duplicate(true),
	}
	Realm.colonies[ledger.id] = ledger
	Realm.awake_id = ledger.id
	Realm.heart_region_id = ledger.id
	return {
		"version": SCHEMA_VERSION,
		"difficulty": old.get("difficulty", String(Difficulties.DEFAULT_ID)),
		"game_rules": Difficulties.rules_dict(),
		"tick": int(old.get("tick", 0)),
		"day": int(old.get("day", 1)),
		"phase": int(old.get("phase", Sim.Phase.DAY)),
		"phase_elapsed": float(old.get("phase_elapsed", 0.0)),
		"realm": Realm.to_dict(),
		"climate": {"world_seed": Realm.world_seed},
		"storyteller": {"world_seed": Realm.world_seed, "next_event_day": 3},
	}
