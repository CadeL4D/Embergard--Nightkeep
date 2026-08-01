extends Node
## Thirty-day deterministic sleeping-colony soak for every launch mode.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const TEST_SEED := 440930

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
	for kind in [&"wood", &"stone", &"food", &"ore", &"herbs"]:
		Colony.add(kind, 200)
	Realm.capture_awake()
	var base := Realm.awake_ledger().to_dict()
	var modes := [&"homestead", &"survival", &"besieged", &"nightmare", &"peaceful",
		&"sandbox", &"custom"]
	for mode in modes:
		Difficulties.select(mode)
		var a := ColonyLedger.from_dict(base)
		var b := ColonyLedger.from_dict(base)
		a.advance_to(a.last_advanced_day + 30)
		b.advance_to(b.last_advanced_day + 30)
		_expect(var_to_str(a.to_dict()) == var_to_str(b.to_dict()),
			"%s repeats the same 30-day sleeping simulation" % mode)
		_expect(a.last_advanced_day >= int(base.get("last_advanced_day", 1)) + 30,
			"%s reaches the end of its 30-day soak" % mode)
	Difficulties.select(&"survival")
	RunSave.clear()
	if _failures.is_empty():
		print("PHASE 4 SOAK: all modes deterministic for 30 days")
		get_tree().quit(0)
	else:
		print("PHASE 4 SOAK: %d failure(s)" % _failures.size())
		get_tree().quit(1)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  PASS  %s" % label)
	else:
		_failures.append(label)
		push_error("  FAIL  %s" % label)
