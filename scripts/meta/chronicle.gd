class_name Chronicle
extends RefCounted
## Sixty persistent goals arranged as six prerequisite chains. Evaluation uses lifetime ledgers,
## so progress is deterministic, offline, and cannot be rerolled by reloading a realm.

const BRANCHES := [
	{"id": "settlement", "name": "Settlement", "metric": "buildings",
		"targets": [1, 5, 12, 24, 40, 65, 95, 130, 175, 230]},
	{"id": "endurance", "name": "Endurance", "metric": "days",
		"targets": [2, 5, 10, 18, 28, 42, 60, 85, 115, 150]},
	{"id": "purity", "name": "Purity", "metric": "nests",
		"targets": [1, 3, 6, 10, 16, 24, 34, 46, 60, 80]},
	{"id": "defense", "name": "Defense", "metric": "monsters",
		"targets": [5, 20, 50, 100, 180, 300, 480, 720, 1050, 1500]},
	{"id": "stories", "name": "Stories", "metric": "events",
		"targets": [1, 3, 7, 12, 20, 30, 45, 65, 90, 120]},
	{"id": "realm", "name": "Realmcraft", "metric": "realms_completed",
		"targets": [1, 2, 3, 5, 7, 10, 14, 19, 25, 32]},
]

static var _goals: Array[Dictionary] = []


static func all() -> Array[Dictionary]:
	if _goals.is_empty():
		_build()
	return _goals


static func get_goal(id: StringName) -> Dictionary:
	for goal in all():
		if StringName(goal["id"]) == id:
			return goal
	return {}


static func evaluate(stats: Dictionary, completed: Array[StringName]) -> Array[Dictionary]:
	var newly: Array[Dictionary] = []
	for goal in all():
		var id := StringName(goal["id"])
		if id in completed:
			continue
		var prerequisite := StringName(goal.get("prerequisite", &""))
		if prerequisite != &"" and prerequisite not in completed:
			continue
		if int(stats.get(goal["metric"], 0)) < int(goal["target"]):
			continue
		completed.append(id)
		newly.append(goal)
	return newly


static func _build() -> void:
	var doctrine_index := 3
	for branch in BRANCHES:
		var previous := &""
		var targets: Array = branch["targets"]
		for i in targets.size():
			var id := StringName("chron_%s_%02d" % [branch["id"], i + 1])
			var unlock := &""
			if doctrine_index < Doctrines.all().size():
				unlock = Doctrines.all()[doctrine_index].id
				doctrine_index += 1
			_goals.append({
				"id": id,
				"branch": StringName(branch["id"]),
				"display_name": "%s %s" % [branch["name"], _roman(i + 1)],
				"metric": StringName(branch["metric"]),
				"target": int(targets[i]),
				"prerequisite": previous,
				"shards": 2 + i,
				"unlock": unlock,
			})
			previous = id


static func _roman(value: int) -> String:
	return ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][value - 1]
