class_name Chronicle
extends RefCounted
## 117 persistent goals arranged as nine prerequisite chains. Evaluation uses lifetime ledgers,
## so progress is deterministic, offline, and cannot be rerolled by reloading a realm.

const BRANCHES := [
	{"id": "settlement", "name": "Settlement", "metric": "buildings",
		"targets": [1, 5, 12, 24, 40, 65, 95, 130, 175, 230, 300, 390, 500]},
	{"id": "endurance", "name": "Endurance", "metric": "days",
		"targets": [2, 5, 10, 18, 28, 42, 60, 85, 115, 150, 200, 275, 365]},
	{"id": "purity", "name": "Purity", "metric": "nests",
		"targets": [1, 3, 6, 10, 16, 24, 34, 46, 60, 80, 105, 135, 175]},
	{"id": "defense", "name": "Defense", "metric": "monsters",
		"targets": [5, 20, 50, 100, 180, 300, 480, 720, 1050, 1500, 2200, 3200, 5000]},
	{"id": "stories", "name": "Stories", "metric": "events",
		"targets": [1, 3, 7, 12, 20, 30, 45, 65, 90, 120, 160, 210, 275]},
	{"id": "realm", "name": "Realmcraft", "metric": "realms_completed",
		"targets": [1, 2, 3, 5, 7, 10, 14, 19, 25, 32, 40, 50, 65]},
	{"id": "logistics", "name": "Logistics", "metric": "resources_hauled",
		"targets": [50, 150, 350, 700, 1200, 2000, 3200, 5000, 7500, 11000, 16000, 23000, 32000]},
	{"id": "divinity", "name": "Divinity", "metric": "powers_cast",
		"targets": [1, 5, 15, 35, 70, 120, 200, 320, 500, 750, 1100, 1600, 2300]},
	{"id": "migration", "name": "Migration", "metric": "colonies_founded",
		"targets": [1, 2, 3, 5, 8, 12, 17, 23, 30, 38, 47, 58, 72]},
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
	var advanced := true
	while advanced:
		advanced = false
		for goal in all():
			var id := StringName(goal["id"])
			if id in completed:
				continue
			var ready := true
			for prerequisite in goal.get("prerequisites", []):
				if StringName(prerequisite) not in completed:
					ready = false
					break
			if not ready or int(stats.get(goal["metric"], 0)) < int(goal["target"]):
				continue
			completed.append(id)
			newly.append(goal)
			advanced = true
	return newly


static func _build() -> void:
	var doctrine_index := 3
	for branch_index in BRANCHES.size():
		var branch: Dictionary = BRANCHES[branch_index]
		var previous := &""
		var targets: Array = branch["targets"]
		for i in targets.size():
			var id := StringName("chron_%s_%02d" % [branch["id"], i + 1])
			var unlock := &""
			if doctrine_index < Doctrines.all().size():
				unlock = Doctrines.all()[doctrine_index].id
				doctrine_index += 1
			var prerequisites: Array[StringName] = []
			if previous != &"":
				prerequisites.append(previous)
			if branch_index > 0 and i in [4, 8, 12]:
				prerequisites.append(StringName("chron_%s_%02d" % [
					BRANCHES[branch_index - 1]["id"], i + 1]))
			_goals.append({
				"id": id,
				"branch": StringName(branch["id"]),
				"display_name": "%s %s" % [branch["name"], _roman(i + 1)],
				"metric": StringName(branch["metric"]),
				"target": int(targets[i]),
				"prerequisite": previous,
				"prerequisites": prerequisites,
				"god_xp": 20 + i * 10,
				"chest_slots": 1 if i in [4, 8, 12] else 0,
				"unlock": unlock,
			})
			previous = id


static func _roman(value: int) -> String:
	return ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
		"XI", "XII", "XIII"][clampi(value - 1, 0, 12)]
