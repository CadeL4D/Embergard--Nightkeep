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

var _run: Node2D


func _ready() -> void:
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await get_tree().process_frame
	_run.start_run(424242)
	await get_tree().process_frame

	var entities := _run.get_node("WorldView/Sorted/Entities")
	_populate(entities)

	# Night, so monsters advance and guards fight — the expensive case, not an
	# idle field of sprites.
	Sim.set_phase(Sim.Phase.NIGHT)
	Threat.mark_field_dirty()

	print("=== stress: %d villagers, %d monsters ===" % [
		Colony.population(), Threat.alive_count()])

	# Uncap first. With vsync on, every frame measures exactly 16.67ms no matter how
	# much headroom there is — the first version of this test "measured" 60fps and
	# was reporting the monitor's refresh rate, not the game's cost.
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	for _i in WARMUP_FRAMES:
		await get_tree().process_frame

	# TIME_PROCESS is seconds of CPU actually spent in _process this frame, which is
	# independent of vsync and is the number that decides whether this fits on a
	# phone. Rendering is measured separately by the GPU, and is not what this
	# architecture was designed to protect.
	# Wall clock between frames, measured directly. The engine's TIME_PROCESS
	# monitor and get_frames_per_second() disagreed with each other by a factor of
	# twenty-five here, so neither is trusted — a stopwatch cannot be ambiguous.
	var worst := 0.0
	var total := 0.0
	var samples := 0
	var last := Time.get_ticks_usec()
	for _i in SAMPLE_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := float(now - last) / 1000.0
		last = now
		total += ms
		worst = maxf(worst, ms)
		samples += 1

	var average := total / float(maxi(samples, 1))
	print("villagers alive : %d" % Colony.population())
	print("monsters alive  : %d" % Threat.alive_count())
	print("nodes           : %d" % Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	print("orphan nodes    : %d" % Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	print("frame avg       : %.2f ms  (%.0f fps uncapped)" % [average, 1000.0 / maxf(average, 0.01)])
	print("frame max       : %.2f ms" % worst)
	print("path queue      : %d" % World.paths.last_queue_length)
	print("blight frontier : %d" % World.blight_field.frontier_size())

	# Desktop headroom target. A mid-range phone is several times slower, so the
	# only way 60fps survives on device is if this machine finishes a worst-case
	# frame in a fraction of its budget. 5.5 ms leaves roughly a 3x margin.
	var ok := average <= 5.5
	print("VERDICT: %s (desktop target 5.5 ms)" % ("within" if ok else "OVER"))
	get_tree().quit(0 if ok else 1)


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
