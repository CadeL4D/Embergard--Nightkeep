extends Node
## Dev tool: boot a run, let it settle, and write frames to disk. Run with:
##   Godot_v4.7-stable_win64_console.exe --path <project> res://scenes/dev/screenshot.tscn
##
## Exists because most of this game's visuals are generated in code (the tileset,
## the blight shader, the Ember's falloff) rather than authored as art, so there is
## no way to eyeball them in the editor's import view. Capturing at several points
## in the day cycle also makes lighting regressions obvious at a glance.

const OUT_DIR := "user://shots"
const RUN_SCENE := preload("res://scenes/run/run.tscn")
const SEED := 424242

## Phase to jump to, and how long to let it settle before capturing.
const SHOTS := [
	{"name": "01_day_close", "phase": Sim.Phase.DAY, "settle": 1.2, "zoom": 2.0, "panel": ""},
	{"name": "01b_quarry_close", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 0.75,
		"panel": "", "focus": "stone"},
	{"name": "01c_berries_close", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 2.0,
		"panel": "", "focus": "berries"},
	{"name": "01d_blight_edge", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 2.0,
		"panel": "", "focus": "blight"},
	{"name": "02_day_default", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 1.0, "panel": ""},
	{"name": "02b_paths_close", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 2.0,
		"panel": "", "focus": "paths"},
	{"name": "03_job_board", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 1.0, "panel": "jobs"},
	{"name": "03b_gather_brush", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 1.5,
		"panel": "gather", "focus": "trees"},
	{"name": "04_build_menu", "phase": Sim.Phase.DAY, "settle": 0.4, "zoom": 1.0, "panel": "build"},
	{"name": "05_dusk", "phase": Sim.Phase.DUSK, "settle": 0.4, "zoom": 1.5, "panel": ""},
	{"name": "06_night", "phase": Sim.Phase.NIGHT, "settle": 3.0, "zoom": 1.0, "panel": "", "monsters": 18},
]

var _run: Node2D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	# Developer captures must show the world being inspected, never a profile's
	# contextual guidance card. This is in-memory only and does not change settings.
	Accessibility.tutorials_enabled = false
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await get_tree().process_frame
	_run.start_run(SEED)
	_seed_buildings()
	await _capture_all()
	get_tree().quit(0)


## Drop a few finished structures next to the keep. Screenshots are for judging how
## the game LOOKS, and an empty field of grass says nothing about whether the
## buildings read at gameplay zoom or sit correctly against the terrain.
func _seed_buildings() -> void:
	Colony.add(&"wood", 400)
	Colony.add(&"stone", 200)

	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)
	var entities := _run.get_node("WorldView/Sorted/Entities")

	var layout := [
		[&"hut", Vector2i(-6, -3)],
		[&"hut", Vector2i(-6, 1)],
		[&"watchtower", Vector2i(4, -4)],
		[&"farm", Vector2i(3, 1)],
		[&"stockpile", Vector2i(1, -3)],
		[&"stockpile", Vector2i(2, -3)],
	]
	for entry in layout:
		_place(entry[0], grid.index(keep.x + entry[1].x, keep.y + entry[1].y), entities)

	# A short palisade run, to check that walls tile into a readable line.
	for i in range(-5, 6):
		_place(&"palisade", grid.index(keep.x + i, keep.y + 4), entities)

	# Finished path/road surfaces are rendered as connected world geometry, so keep
	# a short bend in the standard capture for transition regressions.
	for i in range(-5, 5):
		_place(&"path", grid.index(keep.x + i, keep.y + 6), entities)
	for i in range(0, 5):
		_place(&"path", grid.index(keep.x + 4, keep.y + 6 + i), entities)


## Drop attackers near the keep so a night shot shows an actual assault rather than
## an empty dark field. Spawned close in on purpose — a wave still walking in from
## the map edge photographs as nothing happening.
func _seed_monsters(count: int) -> void:
	if count <= 0:
		return
	var scene: PackedScene = load("res://scenes/entities/monster.tscn")
	var pool := Monsters.all()
	if pool.is_empty():
		return
	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)
	var entities := _run.get_node("WorldView/Sorted/Entities")

	for i in count:
		var angle := TAU * float(i) / float(count)
		var dist := randf_range(6.0, 13.0)
		var x := keep.x + int(cos(angle) * dist)
		var y := keep.y + int(sin(angle) * dist)
		if not grid.is_valid(x, y):
			continue
		var cell: int = World.nearest_walkable(grid.index(x, y), 6)
		if cell == -1:
			continue
		var m: Monster = scene.instantiate()
		m.setup(pool[i % pool.size()], 1.0)
		m.position = grid.to_world_index(cell)
		entities.add_child(m)


func _place(id: StringName, anchor: int, parent: Node) -> void:
	var def := Buildings.get_building(id)
	if def == null:
		return
	var b: Node = Colony.place_building(def, anchor, parent)
	if b != null:
		b.complete()          # skip construction; we are photographing the result


func _capture_all() -> void:
	var camera: Camera2D = _run.get_node("CameraRig")
	var hud: CanvasLayer = _run.get_node("Hud")
	for shot: Dictionary in SHOTS:
		var panel: String = shot.get("panel", "")
		DefenseControl.cancel_gather_paint()
		var menu_id: StringName = &"jobs" if panel == "jobs" else (
			&"build" if panel == "build" else &"powers")
		hud._activate_bottom_menu(hud.BOTTOM_MENU_IDS.find(menu_id))
		if panel == "gather":
			DefenseControl.set_gather_mode(&"woodcutting")
		_seed_monsters(int(shot.get("monsters", 0)))
		Sim.set_phase(shot["phase"])
		# Push the phase most of the way through so the sky tint has actually
		# reached that phase's colour rather than still bleeding from the last one.
		Sim.phase_elapsed = Sim.PHASE_DURATION[shot["phase"]] * 0.85
		camera.zoom = Vector2(shot["zoom"], shot["zoom"])
		var focus_cell := World.keep_cell
		if shot.get("focus", "") == "stone":
			focus_cell = _best_resource_focus(Terrain.Feature.STONE)
		elif shot.get("focus", "") == "berries":
			focus_cell = _best_resource_focus(Terrain.Feature.BERRIES)
		elif shot.get("focus", "") == "trees":
			focus_cell = _best_resource_focus(Terrain.Feature.TREE)
			DefenseControl.paint_gather(focus_cell)
		elif shot.get("focus", "") == "paths":
			var keep := World.grid.coord(World.keep_cell)
			focus_cell = World.grid.index(keep.x, keep.y + 6)
		elif shot.get("focus", "") == "blight" and not World.nest_cells.is_empty():
			focus_cell = World.nest_cells[0]
		camera.center_on_cell(focus_cell)

		await get_tree().create_timer(shot["settle"]).timeout
		await RenderingServer.frame_post_draw

		var top_row: Control = _run.get_node("Hud/SafeArea/Layout/TopRow")
		var bottom_row: Control = _run.get_node("Hud/SafeArea/Layout/BottomRow")
		var resource_bar: Control = _run.get_node(
			"Hud/SafeArea/Layout/TopRow/ResourceColumn/ResourceBar")
		var phase_bar: Control = _run.get_node("Hud/SafeArea/Layout/TopRow/PhaseBar")
		print("layout %s: top=%s visible=%s resource=%s/%s phase=%s/%s bottom=%s" % [
			shot["name"], top_row.get_global_rect(), top_row.is_visible_in_tree(),
			resource_bar.get_global_rect(), resource_bar.is_visible_in_tree(),
			phase_bar.get_global_rect(), phase_bar.is_visible_in_tree(),
			bottom_row.get_global_rect()])

		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s.png" % [OUT_DIR, shot["name"]]
		img.save_png(path)
		print("wrote %s  (%s)" % [ProjectSettings.globalize_path(path), img.get_size()])


func _best_resource_focus(feature: int) -> int:
	var grid: Grid = World.grid
	var best := World.keep_cell
	var best_size := 0
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for start in grid.cell_count:
		if visited[start] != 0 or World.feature[start] != feature:
			continue
		var region := PackedInt32Array([start])
		var queue := PackedInt32Array([start])
		visited[start] = 1
		var centroid := Vector2.ZERO
		var head := 0
		while head < queue.size():
			var cell := queue[head]
			head += 1
			var c := grid.coord(cell)
			centroid += Vector2(c)
			for neighbour in grid.neighbours_4(cell):
				if visited[neighbour] != 0 or World.feature[neighbour] != feature:
					continue
				visited[neighbour] = 1
				queue.append(neighbour)
				region.append(neighbour)
		if region.size() <= best_size:
			continue
		best_size = region.size()
		centroid /= float(region.size())
		var nearest := INF
		for cell in region:
			var distance := Vector2(grid.coord(cell)).distance_squared_to(centroid)
			if distance < nearest:
				nearest = distance
				best = cell
	return best
