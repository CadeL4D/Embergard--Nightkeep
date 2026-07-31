extends Node2D
## World-space paint surface for job-specific harvesting orders.
##
## The mask itself lives in DefenseControl so it is saved per settlement. This
## node only turns pointer strokes into circular brush stamps and shows the active
## job's marked resources.

var _painting := false
var _finger := -1
var _last_cell := -1
var _cursor_cell := -1
var _mouse_erasing := false

@onready var _camera: Camera2D = get_node("../../CameraRig")


func _ready() -> void:
	DefenseControl.changed.connect(queue_redraw)
	DefenseControl.gather_mode_changed.connect(
		func(_job_id: StringName, _erasing: bool, _radius: int) -> void:
			_painting = false
			_finger = -1
			_last_cell = -1
			queue_redraw()
	)


func _draw() -> void:
	if DefenseControl.gather_job == &"":
		return
	var job := Jobs.get_job(DefenseControl.gather_job)
	if job == null:
		return
	var color := job.color
	var fill := Color(color.r, color.g, color.b, 0.24)
	var rim := Color(color.lightened(0.28), 0.82)
	var mask: PackedByteArray = DefenseControl.gather_designations.get(
		DefenseControl.gather_job, PackedByteArray())
	var tile := float(Grid.TILE_SIZE)
	for cell in mini(mask.size(), World.grid.cell_count):
		if mask[cell] == 0:
			continue
		var c := World.grid.coord(cell)
		var center := (Vector2(c) + Vector2(0.5, 0.5)) * tile
		# Rounded marks sit behind the resource crown instead of turning painted
		# forests and quarries back into a square checkerboard.
		draw_circle(center, tile * 0.43, fill)
		draw_arc(center, tile * 0.43, 0.0, TAU, 16, rim, 1.0)

	if _cursor_cell == -1 or not World.grid.is_valid_index(_cursor_cell):
		return
	var cursor := (Vector2(World.grid.coord(_cursor_cell)) + Vector2(0.5, 0.5)) * tile
	var brush_color := Color(0.96, 0.34, 0.30, 0.92) \
		if DefenseControl.gather_erasing or _mouse_erasing else Color(color, 0.92)
	var radius_px := (float(DefenseControl.gather_radius) + 0.52) * tile
	draw_circle(cursor, radius_px, Color(brush_color, 0.055))
	draw_arc(cursor, radius_px, 0.0, TAU, 64, brush_color, 1.5)
	draw_line(cursor - Vector2(4, 0), cursor + Vector2(4, 0), brush_color, 1.0)
	draw_line(cursor - Vector2(0, 4), cursor + Vector2(0, 4), brush_color, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if DefenseControl.gather_job == &"":
		return
	if event.is_action_pressed(&"game_cancel"):
		DefenseControl.cancel_gather_paint()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_update_cursor(motion.position)
		if _painting:
			_paint_at(motion.position, _mouse_erasing)
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			return
		_mouse_erasing = button.button_index == MOUSE_BUTTON_RIGHT
		_update_cursor(button.position)
		if button.pressed:
			_painting = true
			_last_cell = -1
			_paint_at(button.position, _mouse_erasing)
		else:
			_painting = false
			_last_cell = -1
			_mouse_erasing = false
			queue_redraw()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventScreenTouch:
		# Desktop mouse events are handled above. Ignore their emulated touch twin
		# or one click stamps the brush twice.
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		var touch := event as InputEventScreenTouch
		if touch.pressed and not _painting:
			_painting = true
			_finger = touch.index
			_last_cell = -1
			_paint_at(touch.position, DefenseControl.gather_erasing)
		elif not touch.pressed and touch.index == _finger:
			_painting = false
			_finger = -1
			_last_cell = -1
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		var drag := event as InputEventScreenDrag
		if _painting and drag.index == _finger:
			_paint_at(drag.position, DefenseControl.gather_erasing)
			get_viewport().set_input_as_handled()


func _update_cursor(screen_position: Vector2) -> void:
	var world_position := _camera.get_canvas_transform().affine_inverse() * screen_position
	_cursor_cell = World.grid.to_cell_index(world_position)
	queue_redraw()


func _paint_at(screen_position: Vector2, erasing: bool) -> void:
	var world_position := _camera.get_canvas_transform().affine_inverse() * screen_position
	var cell := World.grid.to_cell_index(world_position)
	if cell == -1:
		return
	_cursor_cell = cell
	if _last_cell == -1:
		DefenseControl.paint_gather(cell, 1 if erasing else 0)
		_last_cell = cell
		queue_redraw()
		return
	if cell == _last_cell:
		return

	# Stamp between pointer samples so a fast swipe cannot leave alternating gaps.
	var from := World.grid.coord(_last_cell)
	var to := World.grid.coord(cell)
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	for step in range(1, steps + 1):
		var amount := float(step) / float(steps)
		var point := Vector2i(
			roundi(lerpf(from.x, to.x, amount)),
			roundi(lerpf(from.y, to.y, amount))
		)
		DefenseControl.paint_gather(
			World.grid.index_v(point), 1 if erasing else 0)
	_last_cell = cell
	queue_redraw()
