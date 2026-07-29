extends Node
## TEMPORARY verification harness — delete after use.

const RUN_SCENE := preload("res://scenes/run/run.tscn")
const OUT := "user://shots"

var _run: Node2D


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_run = RUN_SCENE.instantiate()
	add_child(_run)
	await get_tree().process_frame
	_run.start_run(424242)

	Colony.add(&"wood", 400)
	Colony.add(&"stone", 200)

	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)
	var entities := _run.get_node("WorldView/Sorted/Entities")

	_place(&"farm", grid.index(keep.x + 2, keep.y - 1), entities)
	_place(&"stockpile", grid.index(keep.x - 3, keep.y), entities)
	_place(&"stockpile", grid.index(keep.x - 3, keep.y + 1), entities)
	_place(&"hut", grid.index(keep.x - 3, keep.y + 3), entities)

	# Park villagers ON the walkable buildings and hand each one a different load.
	var spots := [
		[grid.index(keep.x + 2, keep.y - 1), &"wood"],     # farm, top-left cell
		[grid.index(keep.x + 3, keep.y), &"stone"],        # farm, bottom-right cell
		[grid.index(keep.x - 3, keep.y), &"food"],         # stockpile
		[grid.index(keep.x - 3, keep.y + 1), &"wood"],     # stockpile
		[grid.index(keep.x - 3, keep.y + 3), &"stone"],    # standing on the hut
	]
	for i in mini(spots.size(), Colony.villagers.size()):
		var v: Villager = Colony.villagers[i]
		v.stop()
		v.state = Villager.State.COMMANDED
		v._command_timer = 999.0
		v.position = grid.to_world_index(spots[i][0])
		v.carry_kind = spots[i][1]
		v.carry_amount = 5
		v.facing = Vector2.RIGHT if i % 2 == 0 else Vector2.LEFT

	Sim.set_phase(Sim.Phase.DAY)
	Sim.phase_elapsed = Sim.PHASE_DURATION[Sim.Phase.DAY] * 0.85
	var camera: Camera2D = _run.get_node("CameraRig")
	camera.zoom = Vector2(6.0, 6.0)
	camera.center_on_cell(World.keep_cell)

	await get_tree().create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/verify.png" % OUT)
	print("wrote %s" % ProjectSettings.globalize_path("%s/verify.png" % OUT))
	get_tree().quit(0)


func _place(id: StringName, anchor: int, parent: Node) -> void:
	var def := Buildings.get_building(id)
	if def == null:
		return
	var b: Node = Colony.place_building(def, anchor, parent)
	if b != null:
		b.complete()
