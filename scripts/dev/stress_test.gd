extends Node
## Worst-case performance check. Run with:
##   Godot_v4.7-stable_win64_console.exe --path <project> res://scenes/dev/stress.tscn
##
## The entire simulation architecture — the 10 Hz tick, the staggered thinking, the
## shared flow field instead of per-monster pathfinding — was chosen to hit a budget
## of 60 villagers plus 120 monsters at 60fps. That claim was never actually
## measured, and an unmeasured performance claim is just an intention.
##
## Numbers here are from a desktop GPU and are NOT the shipping target; the real
## check is this same scene deployed to a mid-range phone. What this catches is
## algorithmic regressions — an accidental per-frame full-map sweep shows up as a
## 10x change here long before anyone plugs a device in.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const MONSTER_SCENE := preload("res://scenes/entities/monster.tscn")
const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")

const TARGET_VILLAGERS := 60
const TARGET_MONSTERS := 120
const WARMUP_FRAMES := 90
const SAMPLE_FRAMES := 300

const PROFILE_NODES := {
	"feature_details": "WorldView/FeatureDetails",
	"terrain_transitions": "WorldView/TerrainTransitions",
	"decor": "WorldView/DecorLayer",
	"feature_tiles": "WorldView/Sorted/FeatureLayer",
	"path_surface": "WorldView/PathSurface",
	"blight_overlay": "WorldView/BlightOverlay",
	"influence": "WorldView/InfluenceOverlay",
	"control_zones": "WorldView/ControlZones",
	"gather_designations": "WorldView/GatherDesignations",
	"power_effects": "WorldView/PowerEffects",
	"weather": "WeatherView",
	"hud": "Hud",
}


class FrameProbe extends Node:
	## SceneTree.process_frame fires immediately before node processing. Running this
	## node last measures actual frame work without counting OS/headless frame pacing.
	var frame_start_usec: int = 0
	var last_work_ms: float = 0.0

	func _ready() -> void:
		process_priority = 1000000
		get_tree().process_frame.connect(_on_frame_start)

	func _on_frame_start() -> void:
		frame_start_usec = Time.get_ticks_usec()

	func _process(_delta: float) -> void:
		if frame_start_usec > 0:
			last_work_ms = float(Time.get_ticks_usec() - frame_start_usec) / 1000.0

var _run: Node2D


func _ready() -> void:
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await get_tree().process_frame
	_run.start_run(424242)
	await get_tree().process_frame
	var disabled := _apply_profile_options()

	var entities := _run.get_node("WorldView/Sorted/Entities")
	seed(424242)
	_populate(entities)
	var probe := FrameProbe.new()
	add_child(probe)

	# Night, so monsters advance and guards fight — the expensive case, not an
	# idle field of sprites.
	Sim.set_phase(Sim.Phase.NIGHT)
	Threat.mark_field_dirty()

	print("=== stress: %d villagers, %d monsters; disabled: %s ===" % [
		Colony.population(), Threat.alive_count(),
		"none" if disabled.is_empty() else ",".join(disabled)])

	# Uncap first. With vsync on, every frame measures exactly 16.67ms no matter how
	# much headroom there is — the first version of this test "measured" 60fps and
	# was reporting the monitor's refresh rate, not the game's cost.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	for _i in WARMUP_FRAMES:
		await get_tree().process_frame

	# FrameProbe brackets node processing directly. Wall time is kept separately
	# because Windows/headless scheduling can impose an idle floor even when game
	# processing is disabled. Rendering remains a separate device GPU gate.
	# The probe is therefore the authoritative CPU-work measurement for this gate.
	var wall_times := PackedFloat32Array()
	wall_times.resize(SAMPLE_FRAMES)
	var work_times := PackedFloat32Array()
	work_times.resize(SAMPLE_FRAMES)
	var wall_total := 0.0
	var work_total := 0.0
	var last := Time.get_ticks_usec()
	for sample_index in SAMPLE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var wall_ms := float(now - last) / 1000.0
		last = now
		wall_total += wall_ms
		work_total += probe.last_work_ms
		wall_times[sample_index] = wall_ms
		work_times[sample_index] = probe.last_work_ms

	wall_times.sort()
	work_times.sort()
	var average := work_total / float(maxi(work_times.size(), 1))
	var p95 := _percentile(work_times, 0.95)
	var p99 := _percentile(work_times, 0.99)
	var worst := work_times[-1] if not work_times.is_empty() else 0.0
	var wall_average := wall_total / float(maxi(wall_times.size(), 1))
	print("villagers alive : %d" % Colony.population())
	print("monsters alive  : %d" % Threat.alive_count())
	print("nodes           : %d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("orphan nodes    : %d" % Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("objects         : %d" % Performance.get_monitor(Performance.OBJECT_COUNT))
	print("resources       : %d" % Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	print("static memory   : %.1f MiB" % (
		Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0))
	print("video memory    : %.1f MiB" % (
		RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0))
	print("draw calls      : %d" % RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	print("render objects  : %d" % RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME))
	var feature_details := _run.get_node_or_null("WorldView/FeatureDetails")
	if feature_details != null and feature_details.has_method("profile_counts"):
		print("feature detail  : %s" % str(feature_details.profile_counts()))
	print("frame avg       : %.2f ms  (%.0f fps uncapped)" % [average, 1000.0 / maxf(average, 0.01)])
	print("frame p95       : %.2f ms" % p95)
	print("frame p99       : %.2f ms" % p99)
	print("frame max       : %.2f ms" % worst)
	print("wall/frame avg  : %.2f ms (host pacing diagnostic)" % wall_average)
	print("path queue      : %d" % World.paths.last_queue_length)
	print("blight frontier : %d" % World.blight_field.frontier_size())

	# Desktop headroom target. A mid-range phone is several times slower, so the
	# only way 60fps survives on device is if this machine finishes a worst-case
	# frame in a fraction of its budget. 5.5 ms leaves roughly a 3x margin.
	var ok := average <= 5.5
	print("VERDICT: %s (desktop target 5.5 ms)" % ("within" if ok else "OVER"))
	get_tree().quit(0 if ok else 1)


func _apply_profile_options() -> PackedStringArray:
	var requested := PackedStringArray()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--disable="):
			requested = argument.trim_prefix("--disable=").split(",", false)
	var applied := PackedStringArray()
	var feature_parts := PackedStringArray()
	for key in requested:
		if key == "run":
			_run.process_mode = Node.PROCESS_MODE_DISABLED
			applied.append(key)
			continue
		if key == "sim":
			Sim.process_mode = Node.PROCESS_MODE_DISABLED
			applied.append(key)
			continue
		if key == "villagers":
			for villager in Colony.villagers:
				if is_instance_valid(villager):
					villager.process_mode = Node.PROCESS_MODE_DISABLED
			applied.append(key)
			continue
		if key == "monsters":
			for monster in Threat.hostiles:
				if is_instance_valid(monster):
					monster.process_mode = Node.PROCESS_MODE_DISABLED
			applied.append(key)
			continue
		if key in ["feature_boundaries", "feature_nodes", "feature_rocks"]:
			feature_parts.append(key)
			continue
		if key == "y_sort":
			for path in [
				"WorldView/Sorted",
				"WorldView/Sorted/Entities",
				"WorldView/Sorted/BlightStructures",
			]:
				var sorted := _run.get_node_or_null(path) as Node2D
				if sorted != null:
					sorted.y_sort_enabled = false
			applied.append(key)
			continue
		if not PROFILE_NODES.has(key):
			push_warning("Unknown stress profile component: %s" % key)
			continue
		var node := _run.get_node_or_null(PROFILE_NODES[key])
		if node == null:
			push_warning("Stress profile node is missing: %s" % PROFILE_NODES[key])
			continue
		node.process_mode = Node.PROCESS_MODE_DISABLED
		if node is CanvasItem:
			(node as CanvasItem).visible = false
		applied.append(key)
	var feature_details := _run.get_node_or_null("WorldView/FeatureDetails")
	if not feature_parts.is_empty() and feature_details != null \
			and feature_details.has_method("set_profile_hidden"):
		applied.append_array(feature_details.set_profile_hidden(feature_parts))
	return applied


func _percentile(sorted_samples: PackedFloat32Array, percentile: float) -> float:
	if sorted_samples.is_empty():
		return 0.0
	var index := ceili(percentile * float(sorted_samples.size())) - 1
	return sorted_samples[clampi(index, 0, sorted_samples.size() - 1)]


func _populate(entities: Node) -> void:
	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)

	while Colony.population() < TARGET_VILLAGERS:
		var cell := _scatter_cell(keep, 14)
		if cell == -1:
			continue
		var v: Villager = VILLAGER_SCENE.instantiate()
		v.position = grid.to_world_index(cell)
		entities.add_child(v)

	var pool := Monsters.all()
	if pool.is_empty():
		return
	var i := 0
	while Threat.alive_count() < TARGET_MONSTERS:
		var cell := _scatter_cell(keep, 34)
		if cell == -1:
			continue
		var m: Monster = MONSTER_SCENE.instantiate()
		m.setup(pool[i % pool.size()], 1.0)
		m.position = grid.to_world_index(cell)
		entities.add_child(m)
		i += 1


func _scatter_cell(centre: Vector2i, spread: int) -> int:
	var grid: Grid = World.grid
	var x := centre.x + randi_range(-spread, spread)
	var y := centre.y + randi_range(-spread, spread)
	if not grid.is_valid(x, y):
		return -1
	return World.nearest_walkable(grid.index(x, y), 6)
