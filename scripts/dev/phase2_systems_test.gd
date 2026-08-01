extends Node
## Focused regression for the Hand, hostile behavior roster, boss gates, and timed conditions.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const MONSTER_SCENE := preload("res://scenes/entities/monster.tscn")
const TEST_SEED := 621907

var _failures := PackedStringArray()


func _ready() -> void:
	RunSave.clear()
	var run := RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame
	Sim.set_paused(true)

	var regular := 0
	var bosses := 0
	var behavior_coverage := {}
	for def: MonsterDef in Monsters.all():
		if def.is_boss:
			bosses += 1
		else:
			regular += 1
		for tag in def.behavior_tags:
			behavior_coverage[tag] = true
	_expect(regular >= 16 and bosses >= 4,
		"the launch roster contains at least sixteen regular enemies and four bosses")
	for required in [&"splitting", &"incendiary", &"phasing", &"tunneling", &"ranged",
			&"siege", &"infection", &"support"]:
		_expect(behavior_coverage.has(required), "%s behavior has an authored counter" % required)
	_expect(Monsters.eligible(99).all(func(def: MonsterDef) -> bool: return not def.is_boss),
		"regional bosses are excluded from ordinary wave rolls")

	Threat.night_index = 4
	_expect(bool(Threat.next_night_forecast().get("empowered", false)),
		"the forecast marks each fifth night as empowered")

	var villager: Villager = Colony.villagers[0]
	villager.apply_status(&"infected", 20.0)
	var health_before := villager.health
	villager.think(1.0)
	_expect(villager.statuses.has(&"infected") and villager.health < health_before,
		"infection is forecastable state and deals deterministic typed damage")

	var split_before := Threat.monsters.size()
	Threat.spawn_children(&"swarmling", 3, villager.cell(), villager.cell())
	await get_tree().process_frame
	_expect(Threat.monsters.size() == split_before + 3,
		"splitting creates capped lightweight children through the shared director")

	var hp_before_burst := villager.health
	Threat.resolve_death_burst(villager.position, 8.0, 2.0, &"fire")
	_expect(villager.health < hp_before_burst,
		"incendiary death bursts use scheduled area impacts instead of physics bodies")

	var boss_count_before := _boss_count()
	_expect(Threat._spawn_regional_boss(&"mire_matron", villager.cell()),
		"a cleansing threshold can raise its regional guardian")
	await get_tree().process_frame
	_expect(_boss_count() == boss_count_before + 1, "the guardian is a live boss entity")
	Threat._end_night()
	await get_tree().process_frame
	_expect(_boss_count() == boss_count_before + 1,
		"regional bosses persist through dawn until defeated")

	Threat.boss_stage = 1
	var snapshot := ColonyLedger.new()
	Abstractor.capture(snapshot)
	_expect(int(snapshot.state.get("blight_boss_stage", -1)) == 1,
		"cleansing boss progression is captured by the current schema")
	var packed_villagers: Array = snapshot.state.get("villagers", [])
	_expect(not packed_villagers.is_empty() and packed_villagers[0].get("statuses", {}).has(&"infected"),
		"timed villager conditions survive an awake-colony checkpoint")

	RunSave.clear()
	_report()


func _boss_count() -> int:
	var total := 0
	for monster in Threat.monsters:
		if is_instance_valid(monster) and monster.def != null and monster.def.is_boss:
			total += 1
	return total


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Phase 2 systems test ===")
	if _failures.is_empty():
		print("all hostile-roster and boss checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
