extends Node2D
## Touch-safe world paint surface for Waymaker and terrain work orders.

const HOLD_TO_CANCEL_SECONDS := 0.55

var _painting := false
var _finger := -1
var _last_cell := -1
var _cursor_cell := -1
var _mouse_cancel := false
var _touch_positions: Dictionary = {}
var _navigating := false
var _hold_elapsed := 0.0
var _hold_cancelled := false
var _hold_screen_position := Vector2.ZERO

@onready var _camera: Camera2D = get_node("../../CameraRig")


func _ready() -> void:
	WorkOrders.changed.connect(queue_redraw)
	WorkOrders.tool_changed.connect(_on_tool_changed)
	set_process(false)


func _on_tool_changed(_kind: int, _size: int, _shape: WorkOrder.Shape) -> void:
	_painting = false
	_finger = -1
	_last_cell = -1
	_cursor_cell = -1
	_touch_positions.clear()
	_navigating = false
	_hold_elapsed = 0.0
	_hold_cancelled = false
	set_process(false)
	queue_redraw()


func _process(delta: float) -> void:
	if not _painting or _navigating or _finger < 0 or _hold_cancelled:
		return
	_hold_elapsed += delta
	if _hold_elapsed < HOLD_TO_CANCEL_SECONDS:
		return
	_hold_cancelled = true
	var cell := _screen_to_cell(_hold_screen_position)
	if cell != -1:
		WorkOrders.paint_active(cell, true)
		Events.notice.emit("Orders cancelled under brush", 0)
	queue_redraw()


func _draw() -> void:
	var tile := float(Grid.TILE_SIZE)
	for order: WorkOrder in WorkOrders.orders:
		var color := _kind_color(order.kind)
		for cell in order.cells:
			if cell in order.completed_cells or not World.grid.is_valid_index(cell):
				continue
			var coord := World.grid.coord(cell)
			var rect := Rect2(Vector2(coord) * tile + Vector2(2.0, 2.0),
				Vector2(tile - 4.0, tile - 4.0))
			draw_rect(rect, Color(color, 0.18), true)
			draw_rect(rect, Color(color, 0.78), false, 1.0)
	if WorkOrders.active_kind < 0 or _cursor_cell < 0 \
			or not World.grid.is_valid_index(_cursor_cell):
		return
	var center := (Vector2(World.grid.coord(_cursor_cell)) + Vector2(0.5, 0.5)) * tile
	var color := Color(0.96, 0.31, 0.27, 0.95) if _mouse_cancel or _hold_cancelled \
		else _kind_color(WorkOrders.active_kind as WorkOrder.Kind)
	var radius := (float(WorkOrders.active_brush_size) - 0.48) * tile
	if WorkOrders.active_shape == WorkOrder.Shape.CIRCLE:
		draw_circle(center, radius, Color(color, 0.06))
		draw_arc(center, radius, 0.0, TAU, 64, color, 1.5)
	else:
		var rect := Rect2(center - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
		draw_rect(rect, Color(color, 0.06), true)
		draw_rect(rect, color, false, 1.5)
	draw_line(center - Vector2(4, 0), center + Vector2(4, 0), color, 1.0)
	draw_line(center - Vector2(0, 4), center + Vector2(0, 4), color, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if WorkOrders.active_kind < 0:
		return
	if event.is_action_pressed(&"game_cancel"):
		WorkOrders.cancel_tool()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_update_cursor(motion.position)
		if _painting:
			_paint_at(motion.position, _mouse_cancel)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			return
		_mouse_cancel = button.button_index == MOUSE_BUTTON_RIGHT
		_update_cursor(button.position)
		if button.pressed:
			_painting = true
			_last_cell = -1
			_paint_at(button.position, _mouse_cancel)
		else:
			_painting = false
			_last_cell = -1
			_mouse_cancel = false
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenTouch:
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_positions[touch.index] = touch.position
		else:
			_touch_positions.erase(touch.index)
		if _navigating:
			if _touch_positions.is_empty():
				_navigating = false
			return
		if touch.pressed and not _painting:
			_painting = true
			_finger = touch.index
			_last_cell = -1
			_hold_elapsed = 0.0
			_hold_cancelled = false
			_hold_screen_position = touch.position
			set_process(true)
			_paint_at(touch.position, false)
		elif touch.pressed and touch.index != _finger:
			_navigating = true
			_painting = false
			_last_cell = -1
			set_process(false)
			if not _camera._touches.has(_finger):
				var first := InputEventScreenTouch.new()
				first.index = _finger
				first.position = Vector2(_touch_positions.get(_finger, touch.position))
				first.pressed = true
				_camera._handle_paint_touch(first)
			return
		elif not touch.pressed and touch.index == _finger:
			_painting = false
			_finger = -1
			_last_cell = -1
			set_process(false)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		var drag := event as InputEventScreenDrag
		_touch_positions[drag.index] = drag.position
		if _navigating:
			return
		if _painting and drag.index == _finger:
			if drag.position.distance_to(_hold_screen_position) > Accessibility.GESTURE_SLOP_PX:
				_hold_elapsed = 0.0
				_hold_screen_position = drag.position
			_paint_at(drag.position, false)
			get_viewport().set_input_as_handled()


func _paint_at(screen_position: Vector2, cancelling: bool) -> void:
	var cell := _screen_to_cell(screen_position)
	if cell < 0:
		return
	_cursor_cell = cell
	if _last_cell == -1:
		WorkOrders.paint_active(cell, cancelling)
		_last_cell = cell
		queue_redraw()
		return
	if cell == _last_cell:
		return
	var from := World.grid.coord(_last_cell)
	var to := World.grid.coord(cell)
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	for step in range(1, steps + 1):
		var amount := float(step) / float(steps)
		var point := Vector2i(roundi(lerpf(from.x, to.x, amount)),
			roundi(lerpf(from.y, to.y, amount)))
		WorkOrders.paint_active(World.grid.index_v(point), cancelling)
	_last_cell = cell
	queue_redraw()


func _update_cursor(screen_position: Vector2) -> void:
	_cursor_cell = _screen_to_cell(screen_position)
	queue_redraw()


func _screen_to_cell(screen_position: Vector2) -> int:
	var world_position := _camera.get_canvas_transform().affine_inverse() * screen_position
	return World.grid.to_cell_index(world_position)


static func _kind_color(kind: WorkOrder.Kind) -> Color:
	match kind:
		WorkOrder.Kind.DIG: return Color("d49b5b")
		WorkOrder.Kind.DESTROY_TERRAIN: return Color("e36d5f")
		WorkOrder.Kind.BUILD_ROAD: return Color("d6bd78")
		WorkOrder.Kind.REMOVE_ROAD: return Color("aa7a68")
		WorkOrder.Kind.DISMANTLE: return Color("f04f54")
		_: return Color("b9c8d8")
