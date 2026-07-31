extends Node2D
## Lightweight world-space view and paint input for colony control zones.

const COLORS := {
	DefenseControl.PaintMode.FORBIDDEN: Color(0.93, 0.22, 0.25, 0.28),
	DefenseControl.PaintMode.WORK: Color(0.25, 0.72, 0.38, 0.24),
	DefenseControl.PaintMode.GUARD: Color(0.25, 0.55, 0.95, 0.28),
}

var _painting := false
var _finger := -1
var _last_cell := -1

@onready var _camera: Camera2D = get_node("../../CameraRig")


func _ready() -> void:
	DefenseControl.changed.connect(queue_redraw)
	DefenseControl.paint_mode_changed.connect(func(_mode: int) -> void: queue_redraw())


func _draw() -> void:
	if DefenseControl.paint_mode == DefenseControl.PaintMode.NONE:
		return
	var tile := float(Grid.TILE_SIZE)
	for cell in World.grid.cell_count:
		var color := Color.TRANSPARENT
		if DefenseControl.forbidden[cell] != 0:
			color = COLORS[DefenseControl.PaintMode.FORBIDDEN]
		if DefenseControl.work[cell] != 0:
			color = color.blend(COLORS[DefenseControl.PaintMode.WORK])
		if DefenseControl.guard[cell] != 0:
			color = color.blend(COLORS[DefenseControl.PaintMode.GUARD])
		if color.a <= 0.0:
			continue
		var c := World.grid.coord(cell)
		draw_rect(Rect2(Vector2(c) * tile, Vector2(tile, tile)), color, true)
		draw_rect(Rect2(Vector2(c) * tile, Vector2(tile, tile)), color.lightened(0.35), false, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if DefenseControl.paint_mode == DefenseControl.PaintMode.NONE:
		return
	if event.is_action_pressed(&"game_cancel"):
		DefenseControl.cancel_paint()
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed and not _painting:
			_painting = true
			_finger = touch.index
			_last_cell = -1
			_paint_at(touch.position)
			get_viewport().set_input_as_handled()
		elif not touch.pressed and touch.index == _finger:
			_painting = false
			_finger = -1
			_last_cell = -1
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _painting and drag.index == _finger:
			_paint_at(drag.position)
			get_viewport().set_input_as_handled()


func _paint_at(screen_position: Vector2) -> void:
	var world_position := _camera.get_canvas_transform().affine_inverse() * screen_position
	var cell := World.grid.to_cell_index(world_position)
	if cell == -1 or cell == _last_cell:
		return
	_last_cell = cell
	DefenseControl.paint(cell)
