extends Node
## Focused regression for rotating, asynchronous, checksummed run saves.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 881204

var _failures := PackedStringArray()
var _write_durations: Array[float] = []


func _ready() -> void:
	RunSave.clear()
	SaveService.save_completed.connect(func(_sequence: int, duration_ms: float, ok: bool) -> void:
		_write_durations.append(duration_ms)
		_expect(ok, "the background checkpoint commits successfully")
	)

	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame

	for expected_tick in [101, 202, 303]:
		Sim.tick = expected_tick
		_expect(RunSave.save(), "checkpoint %d is accepted without waiting for disk" % expected_tick)
		_expect(SaveService.flush(), "checkpoint %d is durable" % expected_tick)

	var newest := SaveService.read_latest()
	_expect(int(newest.get("sequence", 0)) >= 3, "three checkpoints receive increasing sequences")
	_expect(int(newest.get("data", {}).get("tick", 0)) == 303,
		"the newest checkpoint wins before corruption")
	_expect(_slot_count() == 3, "the run retains exactly three rotating slots")
	_expect(_temp_count() == 0, "no partial temporary save remains after a flush")

	var damaged_path := SaveService.latest_slot_path()
	var damaged := FileAccess.open(damaged_path, FileAccess.WRITE)
	if damaged != null:
		damaged.store_buffer("deliberately damaged".to_utf8_buffer())
		damaged.close()
	var recovered := SaveService.read_latest()
	_expect(not recovered.is_empty() and bool(recovered.get("recovered", false)),
		"a damaged newest slot automatically selects a valid fallback")
	_expect(int(recovered.get("data", {}).get("tick", 0)) == 202,
		"fallback restores the immediately preceding checkpoint")
	_expect(_write_durations.size() == 3 and _write_durations.max() < 50.0,
		"desktop checkpoint I/O stays below the 50 ms suspension budget")

	RunSave.clear()
	_expect(not RunSave.has_save(), "clearing a finished run removes every slot")
	_report()


func _slot_count() -> int:
	var count := 0
	for i in SaveService.SLOT_COUNT:
		if FileAccess.file_exists("user://run_%d.dat" % i):
			count += 1
	return count


func _temp_count() -> int:
	var count := 0
	for i in SaveService.SLOT_COUNT:
		if FileAccess.file_exists("user://run_%d.tmp" % i):
			count += 1
	return count


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== Rotating autosave test ===")
	if _failures.is_empty():
		print("all autosave checks passed; writes %s ms" % str(_write_durations))
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
