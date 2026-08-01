extends Node
## Deterministic fifteen-night combat model for the three supported defence doctrines.
## Uses authored monster health/resistances and tower damage/cooldowns; no physics or frames.

const SEEDS := [1, 7, 19, 41, 73, 101, 211, 337, 509, 733, 997, 1291, 1601, 2027, 4093, 8191]

var _failures := PackedStringArray()


func _ready() -> void:
	Difficulties.select(&"survival")
	var strategies := {
		"ranger line": Callable(self, "_ranger_line"),
		"siege works": Callable(self, "_siege_works"),
		"sacred storm": Callable(self, "_sacred_storm"),
	}
	for strategy_name in strategies:
		var lowest_margin := INF
		var cleared := true
		for seed_value in SEEDS:
			for night in range(1, 16):
				var enemies := _wave(seed_value, night)
				var margin := _resolve(strategies[strategy_name].call(night), enemies, night)
				lowest_margin = minf(lowest_margin, margin)
				if margin < 1.0:
					cleared = false
		_expect(cleared, "%s clears all sixteen deterministic fifteen-night scenarios (min %.2fx)" \
			% [strategy_name, lowest_margin])

	# A player must combine roles. Four copies of one tower cannot answer every seed and
	# every behavior through night fifteen, even when fully supplied.
	for tower_id in [&"watchtower", &"bow_tower", &"ballista", &"catapult", &"ember_beacon"]:
		var won_everything := true
		for seed_value in SEEDS:
			for night in range(1, 16):
				if _resolve({"towers": {tower_id: 4}, "walls": {}, "traps": 0},
						_wave(seed_value, night), night) < 1.0:
					won_everything = false
					break
			if not won_everything:
				break
		_expect(not won_everything, "%s alone cannot dominate every seed" % tower_id)

	print("\n=== fifteen-night defence scenarios ===")
	if _failures.is_empty():
		print("three mixed defence archetypes pass; no mono-tower solution dominates")
		get_tree().quit(0)
	else:
		for failure in _failures:
			print("FAIL: %s" % failure)
		get_tree().quit(1)


func _ranger_line(night: int) -> Dictionary:
	return {
		"towers": {
			&"watchtower": 2 + night / 4,
			&"bow_tower": 1 + night / 3,
			&"ballista": night / 5,
		},
		"walls": {&"palisade": 8 + night * 2},
		"traps": 2 + night / 2,
	}


func _siege_works(night: int) -> Dictionary:
	return {
		"towers": {
			&"watchtower": 1 + night / 5,
			&"ballista": 1 + night / 3,
			&"catapult": 1 + night / 4,
		},
		"walls": {&"stone_wall": 8 + night * 2},
		"traps": 1 + night / 3,
	}


func _sacred_storm(night: int) -> Dictionary:
	return {
		"towers": {
			&"ember_beacon": 1 + night / 3,
			&"banish_spire": 1 + night / 5,
			&"storm_rod": 1 + night / 4,
		},
		"walls": {&"ember_rampart": 6 + night * 2},
		"traps": 1 + night / 3,
	}


func _wave(seed_value: int, night: int) -> Array[MonsterDef]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 104729 + night * 8191
	var budget := (4.0 + night * 2.5 + pow(1.18, night) * 1.5) \
		* rng.randf_range(0.86, 1.14)
	var pool := Monsters.eligible(night)
	var enemies: Array[MonsterDef] = []
	var spent := 0.0
	while spent < budget and enemies.size() < 120:
		var total := 0.0
		for candidate in pool:
			total += candidate.weight
		var roll := rng.randf() * total
		var chosen: MonsterDef = pool[0]
		for candidate in pool:
			roll -= candidate.weight
			if roll <= 0.0:
				chosen = candidate
				break
		enemies.append(chosen)
		spent += chosen.threat_cost
	return enemies


func _resolve(loadout: Dictionary, enemies: Array[MonsterDef], night: int) -> float:
	if enemies.is_empty():
		return INF
	var enemy_health := 0.0
	var phasing := 0
	var support := 0
	for enemy in enemies:
		enemy_health += enemy.max_health
		if enemy.has_behavior(&"phasing") or enemy.tunnels:
			phasing += 1
		if enemy.has_behavior(&"support"):
			support += 1
	var behavior_surcharge := 1.0 + float(support) / float(enemies.size()) * 0.22
	behavior_surcharge += 0.18 if night % 5 == 0 else 0.0
	enemy_health *= behavior_surcharge

	var wall_hp := 0.0
	for wall_id: StringName in loadout.get("walls", {}):
		var wall := Buildings.get_building(wall_id)
		if wall != null:
			wall_hp += wall.max_hp * int(loadout["walls"][wall_id])
	var wall_effect := 1.0 - float(phasing) / float(enemies.size())
	var engagement := 10.0 + minf(wall_hp / 850.0, 7.0) * wall_effect
	if loadout.get("towers", {}).has(&"banish_spire"):
		engagement += minf(int(loadout["towers"][&"banish_spire"]) * 0.65, 2.6)

	var damage := 0.0
	for tower_id: StringName in loadout.get("towers", {}):
		var tower := Buildings.get_building(tower_id)
		var count := int(loadout["towers"][tower_id])
		if tower == null or count <= 0:
			continue
		var resistance_multiplier := 0.0
		for enemy in enemies:
			resistance_multiplier += DamageTypes.apply(
				tower.attack_damage, enemy.resistances, tower.attack_type) \
				/ maxf(tower.attack_damage, 0.001)
		resistance_multiplier /= float(enemies.size())
		var shots := floori(engagement / maxf(tower.attack_cooldown, 0.1))
		var splash := 1.0 + minf(tower.attack_area_radius * 0.55,
			float(enemies.size() - 1))
		damage += count * shots * tower.attack_damage * resistance_multiplier * splash

	# Traps are strong against bodies that use the approach and irrelevant to phasers/tunnellers.
	var grounded := 1.0 - float(phasing) / float(enemies.size())
	damage += int(loadout.get("traps", 0)) * 15.0 * grounded
	return damage / maxf(enemy_health, 1.0)


func _expect(ok: bool, label: String) -> void:
	print("  %s  %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures.append(label)
