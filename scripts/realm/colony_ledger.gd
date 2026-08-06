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
var purified: bool = false
var founded_day: int = 1
var last_advanced_day: int = 1
var pressure: float = 0.0
var corruption: float = 0.0
var shield_integrity: float = 1.0
var state: Dictionary = {}


func population() -> int:
	return state.get("villagers", []).size()


func golem_count(role: StringName = &"") -> int:
	var count := 0
	for row: Dictionary in state.get("golems", []):
		var def := Powers.get_power(StringName(row.get("power", &"")))
		if def != null and (role.is_empty() or def.construct_role == role):
			count += 1
	return count


func sleeping_labor_multiplier() -> float:
	return 1.0 + float(golem_count(&"labor")) * 0.06


func stock_of(kind: StringName) -> int:
	return int(state.get("stock", {}).get(kind, 0))


func available_resource(kind: StringName) -> int:
	var total := stock_of(kind)
	var reserved: Dictionary = state.get("reserved", {})
	var buffered := 0
	for row: Dictionary in state.get("buildings", []):
		buffered += int(row.get("input_buffer", {}).get(kind, 0))
	return maxi(total - int(reserved.get(kind, 0)) - buffered, 0)


func deposit_resource(kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var stock: Dictionary = state.get("stock", {}).duplicate(true)
	stock[kind] = int(stock.get(kind, 0)) + amount
	if int(state.get("physical_inventory", 0)) > 0:
		_sync_physical_inventory(stock)
	state["stock"] = stock
	return amount


func withdraw_resource(kind: StringName, amount: int) -> int:
	var taken := mini(maxi(amount, 0), available_resource(kind))
	if taken <= 0:
		return 0
	var stock: Dictionary = state.get("stock", {}).duplicate(true)
	stock[kind] = maxi(int(stock.get(kind, 0)) - taken, 0)
	if int(state.get("physical_inventory", 0)) > 0:
		_sync_physical_inventory(stock)
	state["stock"] = stock
	return taken


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
	for row: Dictionary in state.get("golems", []):
		var power := Powers.get_power(StringName(row.get("power", &"")))
		if power != null and power.construct_role == &"guard":
			strength += clampf(power.construct_attack_damage \
				/ maxf(power.construct_attack_cooldown, 0.1) / 75.0, 0.08, 0.24)
	for row: Dictionary in state.get("buildings", []):
		if not bool(row.get("complete", false)):
			continue
		var building_id := StringName(row.get("def", &""))
		var def := Buildings.get_building(building_id)
		if def != null and def.attack_damage > 0.0:
			strength += clampf(def.attack_damage / maxf(def.attack_cooldown, 0.1) / 75.0,
				0.06, 0.22)
		elif def != null and (def.blocks_movement or def.blocks_monsters_only):
			strength += clampf(def.max_hp / 1400.0, 0.04, 0.2)
		elif def != null and def.center_tier > 0:
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
		"purified": purified,
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
	ledger.purified = bool(data.get("purified", false))
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
	var gather_mult := float(climate_effects.get("gather", 1.0)) * Difficulties.yield_mult()
	var farm_mult := float(climate_effects.get("farm", 1.0)) * Difficulties.yield_mult()
	var thirst_mult := float(climate_effects.get("thirst", 1.0))
	var mood_offset := float(climate_effects.get("mood", 0.0))
	var blight_mult := float(climate_effects.get("blight", 1.0))
	# Labor Golems become logistics strength while this colony sleeps. They do not invent a new
	# job or consume food; they make the assigned people and completed workshops more effective.
	var labor_scale := sleeping_labor_multiplier()
	if int(state.get("physical_inventory", 0)) > 0:
		_apply_sleeping_spoilage(stock)

	# Sleeping gatherers really remove features from their map. This makes their output finite and
	# guarantees that returning to the colony shows the trees and rocks they used are gone.
	_harvest(feature, Terrain.Feature.TREE, &"wood",
		mini(int(quotas.get(&"woodcutting", 0)), villagers.size()), stock, rng,
		gather_mult * labor_scale * Biomes.yield_multiplier(biome_id, Terrain.Feature.TREE))
	_harvest(feature, Terrain.Feature.STONE, &"stone",
		mini(int(quotas.get(&"quarrying", 0)), villagers.size()), stock, rng,
		gather_mult * labor_scale * Biomes.yield_multiplier(biome_id, Terrain.Feature.STONE))
	_harvest(feature, Terrain.Feature.BERRIES, &"food",
		mini(int(quotas.get(&"foraging", 0)), villagers.size()), stock, rng,
		gather_mult * labor_scale * Biomes.yield_multiplier(biome_id, Terrain.Feature.BERRIES))

	# Workshops use the same input/output declarations as the live jobs. A worker only receives
	# credit when its completed workplace is present.
	_run_cycles(&"farming", &"farm", quotas, villagers.size(), stock, 2,
		farm_mult * labor_scale)
	_run_cycles(&"sawing", &"sawmill", quotas, villagers.size(), stock, 2, labor_scale)
	_run_cycles(&"stonecutting", &"stonecutter", quotas, villagers.size(), stock, 2, labor_scale)
	_run_cycles(&"toolmaking", &"toolsmith", quotas, villagers.size(), stock, 1, labor_scale)

	var meals_needed := villagers.size() * 2
	var eaten: int = mini(int(stock.get(&"food", 0)), meals_needed)
	stock[&"food"] = int(stock.get(&"food", 0)) - eaten
	var fed_ratio := 1.0 if meals_needed == 0 else float(eaten) / float(meals_needed)
	var losses := 0
	for row: Dictionary in villagers:
		if row.has("record"):
			var record: Dictionary = row.get("record", {}).duplicate(true)
			record["age_days"] = int(record.get("age_days", 0)) + 1
			row["record"] = record
		row["food"] = clampf(float(row.get("food", 80.0)) - 20.0 + fed_ratio * 22.0, 0.0, 100.0)
		row["water"] = clampf(float(row.get("water", 80.0)) - 5.0 * thirst_mult, 30.0, 100.0)
		row["rest"] = clampf(float(row.get("rest", 80.0)) + 6.0, 25.0, 100.0)
		var mood_target := (68.0 if fed_ratio >= 0.8 else 34.0) + mood_offset
		row["mood"] = lerpf(float(row.get("mood", 60.0)), mood_target, 0.18)
		if fed_ratio < 0.5:
			row["health"] = float(row.get("health", 100.0)) - (1.0 - fed_ratio) * 18.0
		if float(row.get("health", 100.0)) <= 0.0:
			losses += 1
		elif row.has("record"):
			var record: Dictionary = row.get("record", {})
			if int(record.get("age_days", 0)) >= int(record.get("max_age_days", 100)):
				row["health"] = 0.0
				losses += 1
	if losses > 0:
		var survivors: Array = []
		var memorials: Array = state.get("memorials", []).duplicate(true)
		for row: Dictionary in villagers:
			if float(row.get("health", 100.0)) > 0.0:
				survivors.append(row)
				continue
			if row.has("record"):
				var record: Dictionary = row.get("record", {}).duplicate(true)
				record["memorial"] = {
					"day": day_number,
					"cause": &"age" if int(record.get("age_days", 0)) \
						>= int(record.get("max_age_days", 100)) else &"hunger",
					"job": row.get("job", &""),
					"age_days": record.get("age_days", 0),
				}
				memorials.append(record)
		villagers = survivors
		state["memorials"] = memorials

	# Corruption keeps moving when nobody is watching. The exact byte field is changed, not just
	# a display percentage, so reconstitution cannot roll this consequence away.
	var defense_control: Dictionary = state.get("defense_control", {}).duplicate(true)
	var cleanse_left := int(defense_control.get("cleanse_dawns_left", 0))
	if purified:
		cleanse_left = 0
		defense_control["cleanse_dawns_left"] = 0
		defense_control["cleanse_completed"] = true
		state["defense_control"] = defense_control
	elif cleanse_left > 0:
		_sleeping_cleanse(state.get("blight", PackedByteArray()), cleanse_left)
		cleanse_left -= 1
		defense_control["cleanse_dawns_left"] = cleanse_left
		if cleanse_left <= 0:
			defense_control["cleanse_completed"] = true
			purified = true
		state["defense_control"] = defense_control
	else:
		var nest_mult := _sleeping_nest_multiplier(
			state.get("nest_cells", PackedInt32Array()), state.get("feature", PackedByteArray()))
		_advance_blight(state.get("terrain", PackedByteArray()),
			state.get("blight", PackedByteArray()), rng,
			roundi((30.0 + pressure * 18.0) * blight_mult * nest_mult))
		_advance_blight_economy(rng, blight_mult)
	var blight: PackedByteArray = state.get("blight", PackedByteArray())
	var blighted := 0
	for value in blight:
		if value > 0:
			blighted += 1
	corruption = 0.0 if purified else float(blighted) / float(maxi(blight.size(), 1))
	pressure = 0.0 if purified else Threat.containment_target_for(
		corruption, state.get("blight_structures", {}).size(), day_number)

	# Intercepted attacks become visible attrition against the shield instead of disappearing.
	if pressure > 0.0:
		shield_integrity = clampf(shield_integrity - pressure * 0.012, 0.15, 1.0)
		if rng.randf() < pressure * 0.035 and not villagers.is_empty():
			var victim: Dictionary = villagers[rng.randi_range(0, villagers.size() - 1)]
			victim["health"] = maxf(float(victim.get("health", 100.0)) - 16.0, 1.0)
	else:
		shield_integrity = minf(shield_integrity + 0.025, 1.0)

	state["feature"] = feature
	if int(state.get("physical_inventory", 0)) > 0:
		_sync_physical_inventory(stock)
	state["stock"] = stock
	state["villagers"] = villagers
	state["blight"] = blight
	fallen = villagers.is_empty()


func _apply_sleeping_spoilage(stock: Dictionary) -> void:
	var rows: Array = state.get("buildings", [])
	for row: Dictionary in rows:
		var def: BuildingDef = Buildings.get_building(StringName(row.get("def", &"")))
		if def == null:
			continue
		var inventory: Dictionary = row.get("inventory", {}).duplicate(true)
		var progress: Dictionary = row.get("spoilage_progress", {}).duplicate(true)
		for raw_kind in inventory.keys():
			var kind := StringName(raw_kind)
			var resource: ResourceDef = Resources.get_resource(kind)
			if resource == null or resource.spoilage_per_day <= 0.0:
				continue
			var expected: float = float(inventory.get(kind, 0)) * resource.spoilage_per_day \
				* def.spoilage_multiplier * Doctrines.modifier(&"spoilage") \
				+ float(progress.get(kind, 0.0))
			var lost: int = mini(floori(expected), int(inventory.get(kind, 0)))
			inventory[kind] = int(inventory.get(kind, 0)) - lost
			progress[kind] = expected - float(lost)
			stock[kind] = maxi(int(stock.get(kind, 0)) - lost, 0)
		row["inventory"] = inventory
		row["spoilage_progress"] = progress
	var overflow: Dictionary = state.get("overflow", {}).duplicate(true)
	var overflow_progress: Dictionary = state.get("overflow_spoilage", {}).duplicate(true)
	for kind in Colony.KINDS:
		var resource: ResourceDef = Resources.get_resource(kind)
		if resource == null or resource.spoilage_per_day <= 0.0:
			continue
		var expected: float = float(overflow.get(kind, 0)) * resource.spoilage_per_day * 1.25 \
			* Doctrines.modifier(&"spoilage") \
			+ float(overflow_progress.get(kind, 0.0))
		var lost: int = mini(floori(expected), int(overflow.get(kind, 0)))
		overflow[kind] = int(overflow.get(kind, 0)) - lost
		overflow_progress[kind] = expected - float(lost)
		stock[kind] = maxi(int(stock.get(kind, 0)) - lost, 0)
	state["buildings"] = rows
	state["overflow"] = overflow
	state["overflow_spoilage"] = overflow_progress


## Apply sleeping-simulation deltas to the same numeric containers the awake map
## will restore. No courier Nodes are invented off screen and conservation remains inspectable.
func _sync_physical_inventory(desired: Dictionary) -> void:
	var rows: Array = state.get("buildings", [])
	var overflow: Dictionary = state.get("overflow", {}).duplicate(true)
	var actual: Dictionary = {}
	for kind in Colony.KINDS:
		actual[kind] = int(overflow.get(kind, 0))
	for row: Dictionary in rows:
		var inventory: Dictionary = row.get("inventory", {})
		for raw_kind in inventory.keys():
			var kind := StringName(raw_kind)
			actual[kind] = int(actual.get(kind, 0)) + int(inventory.get(kind, 0))
		for key in ["input_buffer", "output_buffer"]:
			var buffer: Dictionary = row.get(key, {})
			for raw_kind in buffer.keys():
				var kind := StringName(raw_kind)
				actual[kind] = int(actual.get(kind, 0)) + int(buffer.get(kind, 0))

	for kind in Colony.KINDS:
		var delta := int(desired.get(kind, 0)) - int(actual.get(kind, 0))
		if delta > 0:
			for row: Dictionary in rows:
				if delta <= 0 or not bool(row.get("complete", false)):
					continue
				var def := Buildings.get_building(StringName(row.get("def", &"")))
				if def == null or not def.is_stockpile or def.inventory_capacity <= 0:
					continue
				var resource := Resources.get_resource(kind)
				if not def.storage_tags.is_empty() and not kind in def.storage_tags \
						and (resource == null or not resource.matches_storage(def.storage_tags)):
					continue
				var inventory: Dictionary = row.get("inventory", {}).duplicate(true)
				var used := 0
				for amount in inventory.values():
					used += maxi(int(amount), 0)
				var accepted := mini(delta, maxi(def.inventory_capacity - used, 0))
				if accepted > 0:
					inventory[kind] = int(inventory.get(kind, 0)) + accepted
					row["inventory"] = inventory
					delta -= accepted
			if delta > 0:
				overflow[kind] = int(overflow.get(kind, 0)) + delta
		elif delta < 0:
			var remaining := -delta
			for row: Dictionary in rows:
				if remaining <= 0:
					break
				var inventory: Dictionary = row.get("inventory", {}).duplicate(true)
				var taken := mini(remaining, int(inventory.get(kind, 0)))
				if taken > 0:
					inventory[kind] = int(inventory.get(kind, 0)) - taken
					if int(inventory[kind]) <= 0:
						inventory.erase(kind)
					row["inventory"] = inventory
					remaining -= taken
			if remaining > 0:
				var overflow_taken := mini(remaining, int(overflow.get(kind, 0)))
				overflow[kind] = int(overflow.get(kind, 0)) - overflow_taken
				remaining -= overflow_taken
			# Workshop outputs are available stock. Committed inputs are last because callers
			# such as routes exclude them; sleeping production may legitimately consume them.
			for buffer_key in ["output_buffer", "input_buffer"]:
				if remaining <= 0:
					break
				for row: Dictionary in rows:
					if remaining <= 0:
						break
					var buffer: Dictionary = row.get(buffer_key, {}).duplicate(true)
					var taken := mini(remaining, int(buffer.get(kind, 0)))
					if taken <= 0:
						continue
					buffer[kind] = int(buffer.get(kind, 0)) - taken
					if int(buffer[kind]) <= 0:
						buffer.erase(kind)
					row[buffer_key] = buffer
					remaining -= taken
	state["buildings"] = rows
	state["overflow"] = overflow


## The sleeping form of the same finite enemy economy used on the awake map. There are no
## off-screen Nodes: worker rows are deterministic ledgers, but mass is still harvested from the
## exact corruption bytes, worker creation still costs five mass, repairs cost two, and every new
## structure reserves its authored cost before it appears.
func _advance_blight_economy(rng: RandomNumberGenerator, blight_mult: float) -> void:
	if not Difficulties.hostile_spawning():
		return
	var feature: PackedByteArray = state.get("feature", PackedByteArray())
	var terrain: PackedByteArray = state.get("terrain", PackedByteArray())
	var blight: PackedByteArray = state.get("blight", PackedByteArray())
	if feature.is_empty() or terrain.is_empty() or blight.is_empty():
		return
	var structures: Dictionary = state.get("blight_structures", {}).duplicate(true)
	var workers: Array = state.get("blight_workers", []).duplicate(true)
	var mass := int(state.get("blight_mass", 0))
	var growth := float(state.get("blight_growth", 0.0)) \
		+ Threat.GROWTH_PER_DAWN * Difficulties.blight_mult() * blight_mult
	var live_nests := PackedInt32Array()
	for raw_cell in state.get("nest_cells", PackedInt32Array()):
		var cell := int(raw_cell)
		if cell >= 0 and cell < feature.size() and feature[cell] == Terrain.Feature.NEST:
			live_nests.append(cell)
	if live_nests.is_empty():
		state["blight_workers"] = []
		state["blight_mass"] = mass
		state["blight_growth"] = growth
		return

	# Finish or refund whatever an awake worker was physically carrying toward a site when the
	# colony went to sleep. This is the simulation-boundary equivalent of arriving there.
	for worker: Dictionary in workers:
		mass += int(worker.get("carry", 0))
		worker["carry"] = 0
		var task: Dictionary = worker.get("task", {})
		if task.is_empty():
			continue
		var cell := int(task.get("cell", -1))
		var completed := false
		if task.get("kind", &"") == &"repair" and structures.has(cell):
			var row: Dictionary = structures[cell]
			var def := BlightStructures.get_structure(StringName(row.get("kind", &"")))
			if def != null:
				row["hp"] = minf(float(row.get("hp", def.max_hp)) + 35.0, def.max_hp)
				structures[cell] = row
				completed = true
		elif task.get("kind", &"") == &"build" and _sleeping_blight_site_open(
				cell, feature, terrain, structures):
			var def := BlightStructures.get_structure(StringName(task.get("def", &"")))
			if def != null:
				structures[cell] = {"kind": def.id, "hp": def.max_hp, "cooldown": 0.0}
				_sleeping_seed_blight(blight, cell, def.blight_seed)
				completed = true
		if not completed:
			mass += int(task.get("cost", 0))
		worker["task"] = {}

	# Fill funded workforce capacity. Worker bodies are part of the conserved budget: removing a
	# row never refunds its creation cost, matching an awake worker killed by the player.
	var capacity := live_nests.size()
	for raw_cell in structures:
		var def := BlightStructures.get_structure(
			StringName(structures[raw_cell].get("kind", &"")))
		if def != null:
			capacity += def.worker_capacity
	capacity = mini(capacity, Threat.MAX_WORKERS)
	while workers.size() < capacity and mass >= Threat.WORKER_SPAWN_COST:
		mass -= Threat.WORKER_SPAWN_COST
		var home: int = live_nests[workers.size() % live_nests.size()]
		var coord := Vector2i(home % World.MAP_WIDTH, home / World.MAP_WIDTH)
		workers.append({"x": float(coord.x * Grid.TILE_SIZE + Grid.TILE_SIZE / 2),
			"y": float(coord.y * Grid.TILE_SIZE + Grid.TILE_SIZE / 2),
			"home": home, "carry": 0, "task": {}})

	# One ledger-day represents enough awake ticks for every worker to complete one four-mass
	# harvest trip. Each unit is removed from the byte field before it enters the mass balance.
	for _worker in workers:
		var harvested := _sleeping_harvest_mass(blight, rng, 4)
		mass += harvested

	# Repairs outrank expansion, exactly as assign_worker_task does on the awake map.
	for raw_cell in structures.keys():
		if mass < 2:
			break
		var cell := int(raw_cell)
		var row: Dictionary = structures[cell]
		var def := BlightStructures.get_structure(StringName(row.get("kind", &"")))
		if def == null or not def.repairs_workers or float(row.get("hp", def.max_hp)) >= def.max_hp:
			continue
		mass -= 2
		row["hp"] = minf(float(row.get("hp", def.max_hp)) + 35.0, def.max_hp)
		structures[cell] = row

	var occupied := _sleeping_player_cells()
	var builders := workers.size()
	while growth >= 1.0 and builders > 0:
		var def := BlightStructures.roll(maxi(last_advanced_day, 1), rng)
		if def == null or mass < def.mass_cost:
			break
		var site_cell := _sleeping_find_blight_site(
			live_nests, feature, terrain, structures, occupied, rng)
		if site_cell == -1:
			growth = 0.0
			break
		mass -= def.mass_cost
		growth -= 1.0
		builders -= 1
		structures[site_cell] = {"kind": def.id, "hp": def.max_hp, "cooldown": 0.0}
		_sleeping_seed_blight(blight, site_cell, def.blight_seed)

	state["blight"] = blight
	state["blight_mass"] = mass
	state["blight_growth"] = minf(growth, 4.0)
	state["blight_workers"] = workers
	state["blight_structures"] = structures


func _sleeping_harvest_mass(blight: PackedByteArray, rng: RandomNumberGenerator,
		capacity: int) -> int:
	if blight.is_empty():
		return 0
	var gathered := 0
	var start := rng.randi_range(0, blight.size() - 1)
	for offset in blight.size():
		var cell := (start + offset) % blight.size()
		var available := int(blight[cell]) / Threat.HARVEST_INTENSITY_PER_MASS
		if available <= 0:
			continue
		var taken := mini(available, capacity - gathered)
		blight[cell] = int(blight[cell]) - taken * Threat.HARVEST_INTENSITY_PER_MASS
		gathered += taken
		if gathered >= capacity:
			break
	return gathered


func _sleeping_find_blight_site(nests: PackedInt32Array, feature: PackedByteArray,
		terrain: PackedByteArray, structures: Dictionary, occupied: Dictionary,
		rng: RandomNumberGenerator) -> int:
	for _nest_attempt in nests.size():
		var nest: int = nests[rng.randi_range(0, nests.size() - 1)]
		if _sleeping_structures_near(nest, structures) >= Threat.GROWTH_PER_NEST:
			continue
		var origin := Vector2i(nest % World.MAP_WIDTH, nest / World.MAP_WIDTH)
		for _attempt in 32:
			var point := origin + Vector2i(rng.randi_range(-Threat.GROWTH_RADIUS,
				Threat.GROWTH_RADIUS), rng.randi_range(-Threat.GROWTH_RADIUS,
				Threat.GROWTH_RADIUS))
			if point.x < 0 or point.y < 0 or point.x >= World.MAP_WIDTH \
					or point.y >= World.MAP_HEIGHT:
				continue
			var cell := point.y * World.MAP_WIDTH + point.x
			if occupied.has(cell) or not _sleeping_blight_site_open(
					cell, feature, terrain, structures):
				continue
			return cell
	return -1


func _sleeping_blight_site_open(cell: int, feature: PackedByteArray,
		terrain: PackedByteArray, structures: Dictionary) -> bool:
	return cell >= 0 and cell < feature.size() and not structures.has(cell) \
		and feature[cell] == Terrain.Feature.NONE \
		and Terrain.WALKABLE.get(terrain[cell], false)


func _sleeping_structures_near(nest: int, structures: Dictionary) -> int:
	var origin := Vector2i(nest % World.MAP_WIDTH, nest / World.MAP_WIDTH)
	var total := 0
	for raw_cell in structures:
		var cell := int(raw_cell)
		var coord := Vector2i(cell % World.MAP_WIDTH, cell / World.MAP_WIDTH)
		if origin.distance_squared_to(coord) <= Threat.GROWTH_RADIUS * Threat.GROWTH_RADIUS:
			total += 1
	return total


func _sleeping_player_cells() -> Dictionary:
	var occupied := {}
	for row: Dictionary in state.get("buildings", []):
		var def := Buildings.get_building(StringName(row.get("def", &"")))
		if def == null:
			continue
		var anchor := int(row.get("anchor", -1))
		if anchor < 0:
			continue
		var origin := Vector2i(anchor % World.MAP_WIDTH, anchor / World.MAP_WIDTH)
		for y in def.footprint.y:
			for x in def.footprint.x:
				var point := origin + Vector2i(x, y)
				if point.x >= 0 and point.y >= 0 and point.x < World.MAP_WIDTH \
						and point.y < World.MAP_HEIGHT:
					occupied[point.y * World.MAP_WIDTH + point.x] = true
	return occupied


func _sleeping_seed_blight(blight: PackedByteArray, cell: int, intensity: int) -> void:
	if cell >= 0 and cell < blight.size() and intensity > 0:
		blight[cell] = maxi(int(blight[cell]), intensity)


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
