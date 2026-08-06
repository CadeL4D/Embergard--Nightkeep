extends Node
## Focused regression for GameRules, deterministic routes, and schema 9 realm logistics.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 940731

var _failures := PackedStringArray()


func _ready() -> void:
	RunSave.clear()
	var run := RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"survival", false)
	for _frame in 3:
		await get_tree().process_frame
	Sim.set_paused(true)

	_expect(Difficulties.all().size() >= 7,
		"seven realm modes are available from world creation")
	_expect(Difficulties.get_difficulty(&"peaceful") != null \
		and not Difficulties.get_difficulty(&"peaceful").hostile_spawning,
		"Peaceful keeps the economy while disabling hostile spawning")
	_expect(Difficulties.get_difficulty(&"sandbox") != null \
		and not Difficulties.get_difficulty(&"sandbox").progression_awards,
		"Sandbox explicitly disables progression awards")
	_expect(Difficulties.get_difficulty(&"harried").id == &"survival",
		"legacy difficulty ids migrate to their new rules preset")
	var custom := GameRules.from_dict({
		"id": "custom", "day_seconds": 100.0, "threat_mult": 1.7,
		"max_hostiles": 999, "max_villagers": 999, "custom_mode": true,
	})
	var custom_copy := GameRules.from_dict(custom.to_dict())
	_expect(custom_copy.day_seconds == 100.0 and custom_copy.threat_mult == 1.7,
		"Custom timing and multipliers serialize exactly")
	_expect(custom_copy.max_hostiles == 120 and custom_copy.max_villagers == 64,
		"Custom rules cannot exceed the fixed mobile performance envelope")
	_expect(Doctrines.all().size() == 24 and Unlocks.total() >= 24,
		"the optional sidegrade layer contains at least twenty-four choices")
	_expect(Chronicle.all().size() == 60,
		"the persistent Chronicle contains sixty prerequisite-linked goals")
	var completed: Array[StringName] = []
	var goal_results := Chronicle.evaluate({
		"buildings": 9999, "days": 9999, "nests": 9999, "monsters": 9999,
		"events": 9999, "realms_completed": 9999,
	}, completed)
	_expect(goal_results.size() == 60 and completed.size() == 60,
		"Chronicle evaluation can advance every branch deterministically")
	_expect(Storyteller.EVENT_IDS.size() == 30 and Storyteller.EVENT_TAGS.size() >= 25,
		"thirty storyteller events cover route household weather faith region and Blight conditions")
	Realm.set_doctrines([&"doc_lean_tables", &"doc_forager_levy", &"doc_lean_tables"])
	_expect(Realm.selected_doctrines.size() == 2 \
		and Doctrines.modifier(&"yield") > 1.0 \
		and Doctrines.modifier(&"needs") < 1.0,
		"a realm equips at most one copy of up to three doctrines and applies their tradeoffs")

	var identities_ok := true
	for id: StringName in Realm.sites:
		var site: Dictionary = Realm.site(id)
		if bool(site.get("settleable", false)) and not bool(site.get("blight_core", false)):
			identities_ok = identities_ok and not site.get("economic_identity", {}).is_empty()
	_expect(identities_ok, "every inhabitable region has a permanent specialty and demand")

	for row in [[&"wood", 240], [&"stone", 180], [&"food", 260]]:
		Colony.add(row[0], row[1])
	var heart_id := Realm.awake_id
	var neighbour_id := _first_open_neighbour(heart_id)
	_expect(neighbour_id != &"" and run.found_realm_site(neighbour_id),
		"the logistics fixture founds a second colony")
	var source_id := Realm.awake_id
	Colony.add(&"food", 100)
	var source_before := Colony.amount_of(&"food")
	var destination_before := Realm.colony(heart_id).stock_of(&"food")
	var forecast_a := Realm.route_forecast(source_id, heart_id, {&"food": 20}, 2)
	var forecast_b := Realm.route_forecast(source_id, heart_id, {&"food": 20}, 2)
	_expect(forecast_a == forecast_b and int(forecast_a.get("travel_days", 0)) >= 1,
		"route time and risk forecast deterministically before departure")

	var future := Realm.schedule_route(source_id, heart_id, {&"food": 10}, [], 1,
		&"once", 0, 40, Sim.day + 2)
	var future_route: TradeRoute = future.get("route")
	_expect(bool(future.get("ok", false)) and future_route.status == &"scheduled" \
		and Colony.amount_of(&"food") == source_before,
		"future routes reserve a plan without removing cargo before departure")
	_expect(Realm.cancel_route(future_route.route_id) and Colony.amount_of(&"food") == source_before,
		"cancelling a scheduled route cannot delete cargo")

	var scheduled := Realm.schedule_route(source_id, heart_id, {&"food": 20}, [], 2)
	var route: TradeRoute = scheduled.get("route")
	_expect(bool(scheduled.get("ok", false)) and route.status == &"in_transit",
		"an immediate route becomes a ledger-only in-transit caravan")
	_expect(Colony.amount_of(&"food") == source_before - 20 \
		and Realm.colony(heart_id).stock_of(&"food") == destination_before \
		and int(route.cargo.get(&"food", 0)) == 20,
		"cargo exists exactly once between departure and arrival")
	var route_copy := TradeRoute.from_dict(route.to_dict())
	_expect(route_copy.route_id == route.route_id and route_copy.path == route.path \
		and route_copy.arrival_day == route.arrival_day,
		"TradeRoute round-trips its path schedule cargo and seeded outcome")
	var saved_essence := Colony.drop_essence(World.grid.index(0, 0), 3, &"schema_test")
	var golem_cell := World.nearest_walkable(World.keep_cell, 6)
	var saved_golem := Colony.spawn_golem(Powers.get_power(&"labor_effigy"), golem_cell)
	if saved_golem != null:
		saved_golem.health = 43.0

	_expect(saved_golem != null and RunSave.SCHEMA_VERSION == 13 \
		and RunSave.save() and SaveService.flush(),
		"schema 13 checkpoints physical drops, local energy, mobile Golems and realm state")
	run._clear_entities()
	_expect(RunSave.load_into(run, run.entities),
		"schema 13 restores the realm with no courier Nodes")
	await get_tree().process_frame
	var restored: TradeRoute = _route_by_id(route.route_id)
	_expect(restored != null and restored.status == &"in_transit" \
		and int(restored.cargo.get(&"food", 0)) == 20,
		"save/load preserves in-transit cargo and deterministic outcome")
	_expect(Realm.selected_doctrines == [&"doc_lean_tables", &"doc_forager_levy"],
		"schema 13 preserves the realm's equipped doctrine choices")
	var restored_essence := Colony.loose_drop(saved_essence.id)
	_expect(restored_essence != null and restored_essence.amount == 3 \
		and restored_essence.source == &"schema_test" and restored_essence.expires_tick > Sim.tick,
		"schema 13 preserves a physical Essence object's amount source and expiry")
	var restored_golem: Golem = Colony.golems[0] if not Colony.golems.is_empty() else null
	_expect(restored_golem != null and restored_golem.power_id == &"labor_effigy" \
		and is_equal_approx(restored_golem.health, 43.0),
		"schema 13 restores a Golem's stable power identity and integrity")
	var expected_lost := ceili(20.0 * lerpf(0.25, 0.65,
		clampf(restored.risk, 0.0, 0.85) / 0.85)) if restored.intercepted else 0
	Realm._process_routes(restored.arrival_day)
	_expect(Realm.colony(heart_id).stock_of(&"food") == destination_before + 20 - expected_lost,
		"arrival deposits only the cargo not explicitly lost to interception")
	_expect(Colony.amount_of(&"food") + Realm.colony(heart_id).stock_of(&"food") \
			+ int(restored.lost_cargo.get(&"food", 0)) == source_before + destination_before,
		"source destination and loss ledgers strictly conserve routed resources")

	var source_pop := Colony.population()
	var destination_pop := Realm.colony(heart_id).population()
	_expect(Realm.transfer_migrant(heart_id), "a settler can join a physical route")
	var migrant_route: TradeRoute = Realm.routes.back()
	_expect(Colony.population() == source_pop - 1 and migrant_route.settlers.size() == 1 \
		and Realm.colony(heart_id).population() == destination_pop,
		"a travelling settler exists in the route rather than both colonies")
	Realm._process_routes(migrant_route.arrival_day)
	_expect(Realm.colony(heart_id).population() == destination_pop + 1,
		"the same stable villager record arrives at the destination")

	RunSave.clear()
	_report()


func _first_open_neighbour(id: StringName) -> StringName:
	for other: StringName in Realm.site(id).get("connections", []):
		if Realm.colony(other) == null and bool(Realm.site(other).get("settleable", false)):
			return other
	return &""


func _route_by_id(route_id: int) -> TradeRoute:
	for route in Realm.routes:
		if route.route_id == route_id:
			return route
	return null


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		push_error("  FAIL  %s" % label)


func _report() -> void:
	if _failures.is_empty():
		print("PHASE 4 SYSTEMS: all checks passed")
		get_tree().quit(0)
	else:
		print("PHASE 4 SYSTEMS: %d failure(s)" % _failures.size())
		for failure in _failures:
			print("  - %s" % failure)
		get_tree().quit(1)
