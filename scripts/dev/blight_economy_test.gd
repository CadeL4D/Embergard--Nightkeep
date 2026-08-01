extends Node
## Focused deterministic check for physical Blight workers and construction mass.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 882731

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

	_expect(BlightStructures.all().size() == 8, "all eight enemy structure roles load")
	_expect(Threat.blight_mass + Threat.workers.size() * Threat.WORKER_SPAWN_COST \
		== World.live_nest_cells().size() * Threat.INITIAL_MASS_PER_NEST,
		"fresh enemy mass and existing workers are derived from generated nests")
	var mass_before_spawn := Threat.blight_mass
	Threat._economy_timer = 0.0
	Threat._step_enemy_economy()
	await get_tree().process_frame
	_expect(Threat.workers.size() >= 1, "a visible enemy worker is spawned from the nest economy")
	_expect(Threat.blight_mass == mass_before_spawn - Threat.WORKER_SPAWN_COST,
		"worker creation spends enemy mass")
	if Threat.workers.is_empty():
		_report()
		return

	var worker: BlightWorker = Threat.workers[0]
	Threat.release_harvest_claim(worker)
	for neighbour in World.grid.neighbours_8(worker.home_cell):
		if World.is_walkable(neighbour) and not World.in_influence(neighbour):
			World.blight_field.seed_at(neighbour, 96)
			break
	var harvest_cell := Threat.claim_harvest_cell(worker, worker.home_cell)
	_expect(harvest_cell != -1, "the worker can claim corrupted ground to harvest")
	if harvest_cell != -1:
		var intensity_before := int(World.blight[harvest_cell])
		var gathered := Threat.harvest_blight_mass(worker, harvest_cell, 4)
		_expect(gathered > 0 and int(World.blight[harvest_cell]) \
			== intensity_before - gathered * Threat.HARVEST_INTENSITY_PER_MASS,
			"gathered mass is conserved by removing matching corruption")
		var before_deposit := Threat.blight_mass
		Threat.deposit_blight_mass(gathered)
		_expect(Threat.blight_mass == before_deposit + gathered,
			"carried mass enters the enemy economy only on deposit")

	Threat.night_index = 8
	Threat.set_growth_progress(1.0)
	Threat.blight_mass = 100
	var structures_before := World.blight_structures.size()
	var task := Threat.assign_worker_task(worker)
	_expect(not task.is_empty() and task.get("kind", &"") == &"build",
		"development demand reserves a funded construction task")
	if not task.is_empty():
		var cost := int(task.get("cost", 0))
		_expect(Threat.blight_mass == 100 - cost,
			"construction reserves its declared mass before work begins")
		_expect(Threat.complete_worker_task(worker), "the worker completes its claimed site")
		_expect(World.blight_structures.size() == structures_before + 1,
			"completed worker construction becomes a real enemy structure")

	var snapshot := ColonyLedger.new()
	Abstractor.capture(snapshot)
	_expect(int(snapshot.state.get("blight_mass", -1)) == Threat.blight_mass,
		"enemy mass is included in the colony checkpoint")
	_expect(snapshot.state.get("blight_workers", []).size() == Threat.workers.size(),
		"enemy workers are included in the colony checkpoint")
	var expected_mass := Threat.blight_mass
	var expected_workers := Threat.workers.size()
	var expected_structures := World.blight_structures.size()
	_expect(RunSave.SCHEMA_VERSION >= 8 and RunSave.save() and SaveService.flush(),
		"the current checkpoint commits the enemy economy")
	var entities := run.get_node("WorldView/Sorted/Entities")
	for child in entities.get_children():
		child.queue_free()
	Colony.villagers.clear()
	Colony.buildings.clear()
	await get_tree().process_frame
	_expect(RunSave.load_into(run, entities), "the current schema restores enemy economy")
	await get_tree().process_frame
	_expect(Threat.blight_mass == expected_mass and Threat.workers.size() == expected_workers,
		"enemy mass and worker roster survive save/load")
	_expect(World.blight_structures.size() == expected_structures,
		"worker-built enemy structures survive save/load")

	var sleeping_a := ColonyLedger.from_dict(snapshot.to_dict())
	var sleeping_b := ColonyLedger.from_dict(snapshot.to_dict())
	sleeping_a.state["blight_growth"] = 0.0
	sleeping_b.state["blight_growth"] = 0.0
	var conserved_before := _enemy_energy(sleeping_a.state)
	var rng_a := RandomNumberGenerator.new()
	var rng_b := RandomNumberGenerator.new()
	rng_a.seed = 93177
	rng_b.seed = 93177
	sleeping_a._advance_blight_economy(rng_a, 1.0)
	sleeping_b._advance_blight_economy(rng_b, 1.0)
	_expect(sleeping_a.state == sleeping_b.state,
		"sleeping enemy ledgers produce identical outcomes from the same seed")
	_expect(_enemy_energy(sleeping_a.state) == conserved_before,
		"sleeping workers conserve corruption mass through harvesting and recruitment")
	_expect(sleeping_a.state.get("blight_workers", []).size() <= Threat.MAX_WORKERS,
		"sleeping enemy workforces obey the same sixteen-worker mobile cap")

	RunSave.clear()
	_report()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _enemy_energy(data: Dictionary) -> int:
	var total := int(data.get("blight_mass", 0)) * Threat.HARVEST_INTENSITY_PER_MASS
	for worker: Dictionary in data.get("blight_workers", []):
		total += Threat.WORKER_SPAWN_COST * Threat.HARVEST_INTENSITY_PER_MASS
		total += int(worker.get("carry", 0)) * Threat.HARVEST_INTENSITY_PER_MASS
	for intensity in data.get("blight", PackedByteArray()):
		total += int(intensity)
	return total


func _report() -> void:
	print("\n=== Blight economy test ===")
	if _failures.is_empty():
		print("all physical enemy-economy checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
