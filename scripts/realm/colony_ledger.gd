class_name ColonyLedger
extends RefCounted
## Authoritative state for one settlement while it is not the map currently being played.
##
## A ledger deliberately stores the exact mutable map and roster, not a lossy score.  The
## summary values shown on the Realm map are derived from this data, so waking a colony cannot
## invent people, repair buildings, or refill a stockpile.

var id: StringName = &""
var display_name: String = ""
var seed_value: int = 0
var keep_cell: int = -1
var realm_position: Vector2 = Vector2.ZERO
var connections: Array[StringName] = []
var is_heart: bool = false
var fallen: bool = false
var founded_day: int = 1
var last_advanced_day: int = 1
var pressure: float = 0.0
var corruption: float = 0.0
var shield_integrity: float = 1.0
var state: Dictionary = {}


func population() -> int:
	return state.get("villagers", []).size()


func stock_of(kind: StringName) -> int:
	return int(state.get("stock", {}).get(kind, 0))


func building_count() -> int:
	return state.get("buildings", []).size()


func average_mood() -> float:
	var rows: Array = state.get("villagers", [])
	if rows.is_empty():
		return 0.0
	var total := 0.0
	for row: Dictionary in rows:
		total += float(row.get("mood", 60.0))
	return total / float(rows.size())


func defense_strength() -> float:
	if fallen:
		return 0.0
	var strength := float(population()) * 0.035
	for row: Dictionary in state.get("buildings", []):
		if not bool(row.get("complete", false)):
			continue
		var building_id := StringName(row.get("def", &""))
		if building_id in [&"watchtower", &"stone_tower", &"wall", &"stone_wall",
				&"gate", &"stone_gate"]:
			strength += 0.16
		elif building_id in [&"hearth", &"great_hall", &"citadel"]:
			strength += 0.12
	return clampf(strength * shield_integrity, 0.0, 1.0)


func to_dict() -> Dictionary:
	return {
		"id": String(id),
		"display_name": display_name,
		"seed": seed_value,
		"keep_cell": keep_cell,
		"realm_position": realm_position,
		"connections": connections.map(func(value: StringName) -> String: return String(value)),
		"is_heart": is_heart,
		"fallen": fallen,
		"founded_day": founded_day,
		"last_advanced_day": last_advanced_day,
		"pressure": pressure,
		"corruption": corruption,
		"shield_integrity": shield_integrity,
		"state": state.duplicate(true),
	}


static func from_dict(data: Dictionary) -> ColonyLedger:
	var ledger := ColonyLedger.new()
	ledger.id = StringName(data.get("id", ""))
	ledger.display_name = String(data.get("display_name", ledger.id))
	ledger.seed_value = int(data.get("seed", 0))
	ledger.keep_cell = int(data.get("keep_cell", -1))
	ledger.realm_position = data.get("realm_position", Vector2.ZERO)
	for value in data.get("connections", []):
		ledger.connections.append(StringName(value))
	ledger.is_heart = bool(data.get("is_heart", false))
	ledger.fallen = bool(data.get("fallen", false))
	ledger.founded_day = int(data.get("founded_day", 1))
	ledger.last_advanced_day = int(data.get("last_advanced_day", ledger.founded_day))
	ledger.pressure = float(data.get("pressure", 0.0))
	ledger.corruption = float(data.get("corruption", 0.0))
	ledger.shield_integrity = float(data.get("shield_integrity", 1.0))
	ledger.state = data.get("state", {}).duplicate(true)
	return ledger


## Advance one sleeping settlement day by day. Each day is seeded independently, so loading,
## saving, or visiting another colony cannot change the result.
func advance_to(target_day: int) -> void:
	if fallen or state.is_empty():
		last_advanced_day = maxi(last_advanced_day, target_day)
		return
	while last_advanced_day < target_day:
		last_advanced_day += 1
		_advance_one_day(last_advanced_day)


func _advance_one_day(day_number: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 104729 + day_number * 8191
	var villagers: Array = state.get("villagers", [])
	var stock: Dictionary = state.get("stock", {}).duplicate()
	var quotas: Dictionary = state.get("quotas", {})
	var feature: PackedByteArray = state.get("feature", PackedByteArray()).duplicate()
	var site := Realm.site(id)
	var biome_id := StringName(site.get("biome", Biomes.DEFAULT_ID))
	var climate := Climate.daily_snapshot(Realm.world_seed, seed_value, day_number, biome_id)
	var climate_effects: Dictionary = climate.get("effects", {})
	var gather_mult := float(climate_effects.get("gather", 1.0))
	var farm_mult := float(climate_effects.get("farm", 1.0))
	var thirst_mult := float(climate_effects.get("thirst", 1.0))
	var mood_offset := float(climate_effects.get("mood", 0.0))
	var blight_mult := float(climate_effects.get("blight", 1.0))

	# Sleeping gatherers really remove features from their map. This makes their output finite and
	# guarantees that returning to the colony shows the trees and rocks they used are gone.
	_harvest(feature, Terrain.Feature.TREE, &"wood",
		mini(int(quotas.get(&"woodcutting", 0)), villagers.size()), stock, rng,
		gather_mult * Biomes.yield_multiplier(biome_id, Terrain.Feature.TREE))
	_harvest(feature, Terrain.Feature.STONE, &"stone",
		mini(int(quotas.get(&"quarrying", 0)), villagers.size()), stock, rng,
		gather_mult * Biomes.yield_multiplier(biome_id, Terrain.Feature.STONE))
	_harvest(feature, Terrain.Feature.BERRIES, &"food",
		mini(int(quotas.get(&"foraging", 0)), villagers.size()), stock, rng,
		gather_mult * Biomes.yield_multiplier(biome_id, Terrain.Feature.BERRIES))

	# Workshops use the same input/output declarations as the live jobs. A worker only receives
	# credit when its completed workplace is present.
	_run_cycles(&"farming", &"farm", quotas, villagers.size(), stock, 2, farm_mult)
	_run_cycles(&"sawing", &"sawmill", quotas, villagers.size(), stock, 2)
	_run_cycles(&"stonecutting", &"stonecutter", quotas, villagers.size(), stock, 2)
	_run_cycles(&"toolmaking", &"toolsmith", quotas, villagers.size(), stock, 1)

	var meals_needed := villagers.size() * 2
	var eaten: int = mini(int(stock.get(&"food", 0)), meals_needed)
	stock[&"food"] = int(stock.get(&"food", 0)) - eaten
	var fed_ratio := 1.0 if meals_needed == 0 else float(eaten) / float(meals_needed)
	var losses := 0
	for row: Dictionary in villagers:
		row["food"] = clampf(float(row.get("food", 80.0)) - 20.0 + fed_ratio * 22.0, 0.0, 100.0)
		row["water"] = clampf(float(row.get("water", 80.0)) - 5.0 * thirst_mult, 30.0, 100.0)
		row["rest"] = clampf(float(row.get("rest", 80.0)) + 6.0, 25.0, 100.0)
		var mood_target := (68.0 if fed_ratio >= 0.8 else 34.0) + mood_offset
		row["mood"] = lerpf(float(row.get("mood", 60.0)), mood_target, 0.18)
		if fed_ratio < 0.5:
			row["health"] = float(row.get("health", 100.0)) - (1.0 - fed_ratio) * 18.0
		if float(row.get("health", 100.0)) <= 0.0:
			losses += 1
	for _i in losses:
		if not villagers.is_empty():
			villagers.pop_back()

	# Corruption keeps moving when nobody is watching. The exact byte field is changed, not just
	# a display percentage, so reconstitution cannot roll this consequence away.
	var defense_control: Dictionary = state.get("defense_control", {}).duplicate(true)
	var cleanse_left := int(defense_control.get("cleanse_dawns_left", 0))
	if cleanse_left > 0:
		_sleeping_cleanse(state.get("blight", PackedByteArray()), cleanse_left)
		cleanse_left -= 1
		defense_control["cleanse_dawns_left"] = cleanse_left
		if cleanse_left <= 0:
			defense_control["cleanse_completed"] = true
		state["defense_control"] = defense_control
	else:
		var nest_mult := _sleeping_nest_multiplier(
			state.get("nest_cells", PackedInt32Array()), state.get("feature", PackedByteArray()))
		_advance_blight(state.get("terrain", PackedByteArray()),
			state.get("blight", PackedByteArray()), rng,
			roundi((30.0 + pressure * 18.0) * blight_mult * nest_mult))
	var blight: PackedByteArray = state.get("blight", PackedByteArray())
	var blighted := 0
	for value in blight:
		if value > 0:
			blighted += 1
	corruption = float(blighted) / float(maxi(blight.size(), 1))

	# Intercepted attacks become visible attrition against the shield instead of disappearing.
	if pressure > 0.0:
		shield_integrity = clampf(shield_integrity - pressure * 0.012, 0.15, 1.0)
		if rng.randf() < pressure * 0.035 and not villagers.is_empty():
			var victim: Dictionary = villagers[rng.randi_range(0, villagers.size() - 1)]
			victim["health"] = maxf(float(victim.get("health", 100.0)) - 16.0, 1.0)
		pressure *= 0.68
	else:
		shield_integrity = minf(shield_integrity + 0.025, 1.0)

	state["feature"] = feature
	state["stock"] = stock
	state["villagers"] = villagers
	state["blight"] = blight
	fallen = villagers.is_empty()


func _sleeping_nest_multiplier(nests: PackedInt32Array, feature: PackedByteArray) -> float:
	if nests.is_empty() or feature.is_empty():
		return 1.0
	var live := 0
	for cell in nests:
		if cell >= 0 and cell < feature.size() and feature[cell] == Terrain.Feature.NEST:
			live += 1
	return lerpf(0.25, 1.0, float(live) / float(nests.size()))


func _sleeping_cleanse(blight: PackedByteArray, dawns_left: int) -> void:
	if blight.is_empty() or dawns_left <= 0:
		return
	var cells := PackedInt32Array()
	for i in blight.size():
		if blight[i] > 0:
			cells.append(i)
	var amount := ceili(float(cells.size()) / float(dawns_left))
	for i in mini(amount, cells.size()):
		blight[cells[i]] = 0


func _harvest(feature: PackedByteArray, feature_id: int, resource: StringName,
		workers: int, stock: Dictionary, rng: RandomNumberGenerator,
		yield_multiplier: float = 1.0) -> void:
	if workers <= 0 or feature.is_empty():
		return
	var candidates := PackedInt32Array()
	for i in feature.size():
		if feature[i] == feature_id:
			candidates.append(i)
	var count := mini(workers, candidates.size())
	for _i in count:
		var pick := rng.randi_range(0, candidates.size() - 1)
		var cell := candidates[pick]
		candidates.remove_at(pick)
		feature[cell] = Terrain.Feature.NONE
		var yield_row: Dictionary = Terrain.FEATURE_YIELD.get(feature_id, {})
		var amount := maxi(roundi(float(yield_row.get(resource, 0)) * yield_multiplier), 1)
		stock[resource] = int(stock.get(resource, 0)) + amount


func _run_cycles(job_id: StringName, workplace: StringName, quotas: Dictionary,
		population_size: int, stock: Dictionary, cycles_per_worker: int,
		output_multiplier: float = 1.0) -> void:
	var workers := mini(int(quotas.get(job_id, 0)), population_size)
	if workers <= 0 or not _has_complete_building(workplace):
		return
	var def: JobDef = Jobs.get_job(job_id)
	if def == null:
		return
	for _cycle in workers * cycles_per_worker:
		var affordable := true
		for kind: StringName in def.cycle_cost:
			if int(stock.get(kind, 0)) < int(def.cycle_cost[kind]):
				affordable = false
				break
		if not affordable:
			break
		for kind: StringName in def.cycle_cost:
			stock[kind] = int(stock.get(kind, 0)) - int(def.cycle_cost[kind])
		for kind: StringName in def.cycle_yield:
			var amount := maxi(roundi(float(def.cycle_yield[kind]) * output_multiplier), 1)
			stock[kind] = int(stock.get(kind, 0)) + amount


func _has_complete_building(building_id: StringName) -> bool:
	for row: Dictionary in state.get("buildings", []):
		if StringName(row.get("def", &"")) == building_id and bool(row.get("complete", false)):
			return true
	return false


func _advance_blight(terrain: PackedByteArray, blight: PackedByteArray,
		rng: RandomNumberGenerator, passes: int) -> void:
	if blight.is_empty():
		return
	const WIDTH := World.MAP_WIDTH
	var active := PackedInt32Array()
	for i in blight.size():
		if blight[i] > 0:
			active.append(i)
	if active.is_empty():
		return
	for _pass in passes:
		var source: int = active[rng.randi_range(0, active.size() - 1)]
		blight[source] = mini(int(blight[source]) + 8, 255)
		var x := source % WIDTH
		var y := source / WIDTH
		var options := PackedInt32Array()
		if x > 0: options.append(source - 1)
		if x < WIDTH - 1: options.append(source + 1)
		if y > 0: options.append(source - WIDTH)
		if y < World.MAP_HEIGHT - 1: options.append(source + WIDTH)
		if options.is_empty():
			continue
		var target: int = options[rng.randi_range(0, options.size() - 1)]
		if not terrain.is_empty() and terrain[target] in [Terrain.Type.WATER, Terrain.Type.DEEP_WATER]:
			continue
		if blight[target] == 0 and rng.randf() < 0.28:
			blight[target] = 48
			active.append(target)
