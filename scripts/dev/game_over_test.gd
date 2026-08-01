extends Node
## Focused regression for the Realm's terminal loss condition.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 9472031

var _failures := PackedStringArray()
var _profile_snapshot := {}


func _ready() -> void:
	_snapshot_profile()
	RunSave.clear()

	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(TEST_SEED, &"harried", false)
	for _frame in 3:
		await get_tree().process_frame

	_expect(Realm.awake_id == Realm.heart_region_id and Colony.population() > 0,
		"the first Hearth begins with a living founding band")
	_expect(RunSave.save() and RunSave.has_save(),
		"the active settlement has a resumable save before defeat")

	var founding_band := Colony.villagers.duplicate()
	for villager in founding_band:
		if is_instance_valid(villager):
			villager.die(&"test_no_survivors")
	for _frame in 4:
		await get_tree().process_frame

	var summary: CanvasLayer = run.get_node("RunSummary")
	_expect(Colony.population() == 0 and run._ended,
		"losing the final settler ends the Realm")
	_expect(not RunSave.has_save(),
		"the no-survivors defeat retires the continue save")
	_expect(summary.visible and summary._title.text == tr(&"SUMMARY_NO_SURVIVORS"),
		"the dedicated no-survivors game-over screen is shown")
	_expect(summary._message.text == tr(&"SUMMARY_NO_SURVIVORS_BODY"),
		"the game-over screen explains that the active save was retired")

	_restore_profile()
	RunSave.clear()
	_report()


func _snapshot_profile() -> void:
	_profile_snapshot = {
		"shards": Meta.shards,
		"unlocked": Meta.unlocked.duplicate(),
		"ascension": Meta.ascension,
		"best_day": Meta.best_day,
		"runs_played": Meta.runs_played,
		"last_difficulty": Meta.last_difficulty,
		"run_history": Meta.run_history.duplicate(true),
		"lifetime_stats": Meta.lifetime_stats.duplicate(true),
		"achievements": Meta.achievements.duplicate(),
		"chronicle_completed": Meta.chronicle_completed.duplicate(),
		"equipped_doctrines": Meta.equipped_doctrines.duplicate(),
	}


func _restore_profile() -> void:
	Meta.shards = int(_profile_snapshot["shards"])
	Meta.unlocked.assign(_profile_snapshot["unlocked"])
	Meta.ascension = int(_profile_snapshot["ascension"])
	Meta.best_day = int(_profile_snapshot["best_day"])
	Meta.runs_played = int(_profile_snapshot["runs_played"])
	Meta.last_difficulty = StringName(_profile_snapshot["last_difficulty"])
	Meta.run_history.assign(_profile_snapshot["run_history"])
	Meta.lifetime_stats = _profile_snapshot["lifetime_stats"].duplicate(true)
	Meta.achievements.assign(_profile_snapshot["achievements"])
	Meta.chronicle_completed.assign(_profile_snapshot["chronicle_completed"])
	Meta.equipped_doctrines.assign(_profile_snapshot["equipped_doctrines"])
	Meta.save_profile()


func _expect(condition: bool, message: String) -> void:
	if condition:
		print("   ok   %s" % message)
	else:
		print("   FAIL %s" % message)
		_failures.append(message)


func _report() -> void:
	print("\n=== No-survivors game-over test ===")
	if _failures.is_empty():
		print("all game-over checks passed")
		get_tree().quit(0)
		return
	for failure in _failures:
		print(" - %s" % failure)
	get_tree().quit(1)
