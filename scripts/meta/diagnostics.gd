extends Node
## Local balance and performance journal. Nothing leaves the device automatically.

const DIRECTORY := "user://diagnostics"
const JOURNAL_PATH := DIRECTORY + "/local_runs.jsonl"
const EXPORT_PATH := DIRECTORY + "/diagnostic_export.json"
const SAMPLE_INTERVAL := 1.0

var current: Dictionary = {}
var _sample_accum: float = 0.0
var _fps_sum: float = 0.0
var _fps_samples: int = 0
var _pressure_sum: float = 0.0
var _pressure_samples: int = 0
var _path_queue_sum: float = 0.0
var _path_queue_samples: int = 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIRECTORY))
	Events.run_started.connect(_begin_run)
	Events.run_ended.connect(_finish_run)
	Events.villager_died.connect(_on_villager_died)
	Events.power_cast.connect(func(power_id: StringName, _pos: Vector2) -> void:
		_increment_nested(&"miracles", power_id, 1.0))
	Events.tower_fired.connect(func(_tower: Node, damage: float, _target: Vector2) -> void:
		current["tower_damage"] = float(current.get("tower_damage", 0.0)) + damage)
	Events.day_advanced.connect(func(_day: int) -> void: _checkpoint())
	set_process(true)


func _begin_run(seed_value: int) -> void:
	current = {
		"seed": seed_value,
		"started_unix": int(Time.get_unix_time_from_system()),
		"mode": String(Difficulties.current.id) if Difficulties.current != null else "",
		"deaths": {}, "miracles": {}, "resource_starvation": {},
		"idle_agent_seconds": 0.0, "path_cells": 0, "paths": 0,
		"path_queue_before_golems": -1, "path_queue_peak_with_golems": 0,
		"maximum_golems": 0,
		"tower_damage": 0.0, "peak_corruption_pressure": 0.0,
		"abandoned": false, "completed": false,
	}
	_fps_sum = 0.0
	_fps_samples = 0
	_pressure_sum = 0.0
	_pressure_samples = 0
	_path_queue_sum = 0.0
	_path_queue_samples = 0


func _finish_run(victory: bool, shards: int) -> void:
	if current.is_empty():
		return
	current["completed"] = true
	current["victory"] = victory
	current["shards"] = shards
	current["ended_unix"] = int(Time.get_unix_time_from_system())
	current["day"] = Sim.day
	current["average_fps"] = _fps_sum / maxf(float(_fps_samples), 1.0)
	current["average_corruption_pressure"] = \
		_pressure_sum / maxf(float(_pressure_samples), 1.0)
	current["average_path_queue"] = _path_queue_sum / maxf(float(_path_queue_samples), 1.0)
	_append(current)
	current = {}


func mark_abandoned() -> void:
	if current.is_empty():
		return
	current["abandoned"] = true
	current["ended_unix"] = int(Time.get_unix_time_from_system())
	_append(current)
	current = {}


func record_path(cell_count: int) -> void:
	if current.is_empty() or cell_count <= 0:
		return
	current["path_cells"] = int(current.get("path_cells", 0)) + cell_count
	current["paths"] = int(current.get("paths", 0)) + 1


## Capture the queue at the moment the first mobile construct joins it, then retain a peak. The
## cap is a tuning guardrail, not permission to silently delete agents from a running colony.
func record_golem_count(count: int) -> void:
	if current.is_empty():
		return
	if count > 0 and int(current.get("path_queue_before_golems", -1)) < 0:
		current["path_queue_before_golems"] = World.paths.last_queue_length \
			if World.paths != null else 0
	current["maximum_golems"] = maxi(int(current.get("maximum_golems", 0)), count)


func record_resource_starvation(kind: StringName) -> void:
	_increment_nested(&"resource_starvation", kind, 1.0)


func export_bundle() -> bool:
	if not Accessibility.diagnostics_export_opt_in:
		return false
	var rows: Array = []
	if FileAccess.file_exists(JOURNAL_PATH):
		var source := FileAccess.open(JOURNAL_PATH, FileAccess.READ)
		while source != null and not source.eof_reached():
			var line := source.get_line().strip_edges()
			if not line.is_empty():
				rows.append(JSON.parse_string(line))
	var output := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if output == null:
		return false
	output.store_string(JSON.stringify({
		"format": 1, "exported_unix": int(Time.get_unix_time_from_system()),
		"runs": rows,
	}, "  "))
	return true


func export_path() -> String:
	return ProjectSettings.globalize_path(EXPORT_PATH)


func _process(delta: float) -> void:
	if current.is_empty() or not Sim.running:
		return
	_sample_accum += delta
	if _sample_accum < SAMPLE_INTERVAL:
		return
	var elapsed := _sample_accum
	_sample_accum = 0.0
	_fps_sum += Engine.get_frames_per_second()
	_fps_samples += 1
	_pressure_sum += Threat.pressure
	_pressure_samples += 1
	if World.paths != null:
		var queue := World.paths.last_queue_length
		_path_queue_sum += queue
		_path_queue_samples += 1
		if Colony.golem_count() > 0:
			current["path_queue_peak_with_golems"] = maxi(
				int(current.get("path_queue_peak_with_golems", 0)), queue)
	current["peak_corruption_pressure"] = maxf(
		float(current.get("peak_corruption_pressure", 0.0)), Threat.pressure)
	var idle := 0
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive \
				and villager.state == Villager.State.IDLE:
			idle += 1
	current["idle_agent_seconds"] = float(current.get("idle_agent_seconds", 0.0)) \
		+ idle * elapsed


func _on_villager_died(_villager: Node, cause: StringName) -> void:
	_increment_nested(&"deaths", cause, 1.0)
	if cause in [&"starvation", &"dehydration"]:
		record_resource_starvation(&"food" if cause == &"starvation" else &"water")


func _increment_nested(bucket: StringName, key: StringName, amount: float) -> void:
	if current.is_empty():
		return
	var values: Dictionary = current.get(String(bucket), {})
	values[String(key)] = float(values.get(String(key), 0.0)) + amount
	current[String(bucket)] = values


func _checkpoint() -> void:
	if current.is_empty():
		return
	current["day"] = Sim.day


func _append(row: Dictionary) -> void:
	var file := FileAccess.open(JOURNAL_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(JOURNAL_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.seek_end()
	file.store_line(JSON.stringify(row))
