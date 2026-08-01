extends Node2D
## Drives building placement: the ghost, the validity read-out, and confirmation.
##
## Position-then-tap. The ghost sits directly UNDER the finger and follows it, but
## releasing only leaves a preview. A separate tap on that preview commits it. An
## earlier version floated the ghost two tiles above the
## touch point so the thumb could not cover it, but the constant offset was worse
## than the occlusion: you aim at a tile and the building lands somewhere else, and
## every placement becomes a correction. Lift the thumb and the site is fully visible
## anyway, which is exactly the moment you decide whether to tap and build.
##
## Cancel is a button rather than a gesture — there is no spare gesture left, and a
## way out of a mode must be visible rather than remembered.
##
## Sits after GodHand in the scene so it receives input first: while placing, a drag
## moves the ghost rather than the Ember or the camera.

signal placement_changed(active: bool, status: String, valid: bool)

## Minimum comfortable touch target for the confirm tap, in screen pixels. A 1x1
## building is 16px of world art — far too small to demand a thumb land on it — so
## the ghost's grab zone is padded out to this at the current zoom.
## How far the finger must travel before a touch that started on the ghost counts as
## a move rather than a tap. Without it a slightly smeared confirm tap drags the
## building off its site instead of building it.
const DRAG_COMMIT_PX := 10.0

var active: bool = false
var def: BuildingDef = null

var _anchor: int = -1
var _valid: bool = false
var _status: String = ""
var _bad_cells: Dictionary = {}
var _cells: PackedInt32Array = PackedInt32Array()
var _drag_finger: int = -1
var _grabbed_ghost: bool = false
var _touch_start: Vector2 = Vector2.ZERO
var _touch_start_time: float = 0.0
var _mouse_dragging: bool = false
var _mouse_start: Vector2i = Vector2i.ZERO
var _mouse_press_screen: Vector2 = Vector2.ZERO
var _mouse_confirming: bool = false
var _pending_line: Array[Vector2i] = []
var _pending_line_valid: Dictionary = {}

@onready var _ghost: Sprite2D = $Ghost
@onready var _camera: Camera2D = get_node("../CameraRig")


func _ready() -> void:
	_ghost.visible = false
	_ghost.centered = false


# --- Mode ------------------------------------------------------------------------------

func begin(building_def: BuildingDef) -> void:
	if building_def == null:
		return
	def = building_def
	active = true
	_clear_pending_line()
	_ghost.texture = def.sprite
	_ghost.offset = Vector2(0, -def.tile_size().y)
	_ghost.visible = true

	# Start at the centre of the view rather than under the finger, so the player
	# can see the whole footprint before deciding where it goes.
	_move_to_world(_camera.get_screen_center_position())
	Events.placement_mode_changed.emit(true)


func cancel() -> void:
	active = false
	def = null
	_anchor = -1
	_bad_cells.clear()
	_cells = PackedInt32Array()
	_ghost.visible = false
	_drag_finger = -1
	_grabbed_ghost = false
	_mouse_dragging = false
	_mouse_confirming = false
	_clear_pending_line()
	queue_redraw()
	placement_changed.emit(false, "", false)
	Events.placement_mode_changed.emit(false)


## Commit the blueprint. Returns true if something was actually placed.
func confirm() -> bool:
	if not active or def == null or not _valid or _anchor == -1:
		return false
	if not _pending_line.is_empty():
		var anchors := _pending_line.duplicate()
		_clear_pending_line()
		var placed_any := false
		for point: Vector2i in anchors:
			if not active or def == null:
				break
			_move_to_world((Vector2(point) + Vector2(0.5, 0.5)) * Grid.TILE_SIZE)
			if _valid and _confirm_single():
				placed_any = true
		return placed_any
	return _confirm_single()


func _confirm_single() -> bool:
	var parent := get_node("../WorldView/Sorted/Entities")
	var placed := Colony.place_building(def, _anchor, parent)
	if placed == null:
		_evaluate()
		return false

	# Stay in placement mode after a successful placement. Chaining walls is the
	# common case, and forcing a trip back to the menu for every segment would make
	# fortifying a keep unbearable.
	var keep := def
	_evaluate()
	if not Colony.can_afford(keep.cost):
		cancel()
	return true


# --- Input ------------------------------------------------------------------------------

## Three gestures, all on one thumb:
##   * Touch empty ground — the ghost moves there and follows the finger.
##   * Drag the ghost — it stays under the finger.
##   * Tap the ghost — build it, right where it is.
##
## Tapping the ghost is the confirm because the ghost is already where the player is
## looking. Walls are placed in runs, and making someone travel to a button at the
## bottom of the screen between every segment is what turns fortifying a keep into a
## chore. The Build button stays as a second route — it is also the only place an
## invalid site can explain itself.
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event.is_action_pressed(&"game_cancel"):
		cancel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		_on_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_on_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventScreenTouch:
		# Desktop mouse input is handled directly below so roads and walls can be painted.
		# Consume its emulated touch twin to prevent one click placing twice.
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		_on_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		if not OS.has_feature("mobile"):
			get_viewport().set_input_as_handled()
			return
		_on_drag(event as InputEventScreenDrag)


func _on_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		cancel()
		get_viewport().set_input_as_handled()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	var world := _to_world(event.position)
	if event.pressed:
		_mouse_dragging = true
		_mouse_press_screen = event.position
		_mouse_confirming = _is_on_preview(world)
		if not _mouse_confirming:
			_clear_pending_line()
			_move_to_world(world)
		_mouse_start = World.grid.coord(_anchor) if _anchor != -1 else Vector2i.ZERO
	else:
		if not _mouse_dragging:
			return
		_mouse_dragging = false
		if _mouse_confirming and event.position.distance_to(_mouse_press_screen) < DRAG_COMMIT_PX:
			_mouse_confirming = false
			confirm()
			get_viewport().set_input_as_handled()
			return
		_mouse_confirming = false
		_move_to_world(world)
		var finish := World.grid.coord(_anchor) if _anchor != -1 else _mouse_start
		if def != null and def.drag_placeable and finish != _mouse_start:
			_set_pending_line(_mouse_start, finish)
	get_viewport().set_input_as_handled()


func _on_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _mouse_dragging:
		return
	if _mouse_confirming:
		if event.position.distance_to(_mouse_press_screen) < DRAG_COMMIT_PX:
			get_viewport().set_input_as_handled()
			return
		_mouse_confirming = false
		_clear_pending_line()
	_move_to_world(_to_world(event.position))
	get_viewport().set_input_as_handled()


func _set_pending_line(from: Vector2i, to: Vector2i) -> void:
	_pending_line.clear()
	_pending_line_valid.clear()
	var delta := to - from
	var steps := maxi(absi(delta.x), absi(delta.y))
	if steps == 0:
		return
	var visited := {}
	var any_valid := false
	var valid_count := 0
	for i in range(steps + 1):
		var progress := float(i) / float(steps)
		var point := Vector2i(roundi(lerpf(from.x, to.x, progress)),
			roundi(lerpf(from.y, to.y, progress)))
		if visited.has(point) or not World.grid.is_valid_v(point):
			continue
		visited[point] = true
		_pending_line.append(point)
		var anchor := World.grid.index_v(point)
		var check := Colony.check_placement(def, anchor)
		var point_valid: bool = check["ok"]
		_pending_line_valid[point] = point_valid
		any_valid = any_valid or point_valid
		if point_valid:
			valid_count += 1
	_valid = any_valid
	_status = _line_cost_text(valid_count) if any_valid else L10n.t(&"PLACE_BLOCKED")
	queue_redraw()
	placement_changed.emit(true, _status, _valid)


func _clear_pending_line() -> void:
	_pending_line.clear()
	_pending_line_valid.clear()
	queue_redraw()


func _line_cost_text(count: int) -> String:
	if def == null or def.cost.is_empty():
		return tr(&"COST_FREE")
	var parts := PackedStringArray()
	for kind: StringName in def.cost:
		parts.append(L10n.t(&"COST_ENTRY",
			[int(def.cost[kind]) * count, L10n.resource(kind)]))
	return ", ".join(parts)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_drag_finger = event.index
		_touch_start = event.position
		_touch_start_time = _now()
		_grabbed_ghost = _is_on_ghost(_to_world(event.position))
		# A touch that lands ON the ghost must not move it: that touch is most likely
		# the confirm tap, and re-centring on the finger would shift the site out from
		# under the very gesture trying to accept it.
		if not _grabbed_ghost:
			_move_to_finger(event.position)
	elif event.index == _drag_finger:
		var elapsed := _now() - _touch_start_time
		var travelled := event.position.distance_to(_touch_start)
		var was_grab := _grabbed_ghost
		_drag_finger = -1
		_grabbed_ghost = false
		if was_grab and elapsed < Accessibility.TAP_MAX_TIME \
				and travelled < Accessibility.GESTURE_SLOP_PX:
			confirm()
	get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index != _drag_finger:
		return
	# A grab only becomes a move once the finger has really travelled, so a slightly
	# smeared confirm tap still confirms.
	if not (_grabbed_ghost and event.position.distance_to(_touch_start) < DRAG_COMMIT_PX):
		_move_to_finger(event.position)
	get_viewport().set_input_as_handled()


## Is this world point on the ghost, generously? The footprint is grown to a
## thumb-sized target at the current zoom, because a 1x1 hut is 16 world pixels and
## demanding that precision to confirm would make the tap feel broken.
func _is_on_ghost(world_pos: Vector2) -> bool:
	if def == null or _anchor == -1:
		return false
	var c := World.grid.coord(_anchor)
	var rect := Rect2(
		Vector2(c) * float(Grid.TILE_SIZE),
		Vector2(def.footprint) * float(Grid.TILE_SIZE)
	)
	var target := Accessibility.MIN_TOUCH_TARGET_PX / maxf(_camera.zoom.x, 0.01)
	rect = rect.grow(maxf(0.0, (target - minf(rect.size.x, rect.size.y)) * 0.5))
	return rect.has_point(world_pos)


func _is_on_preview(world_pos: Vector2) -> bool:
	if def == null:
		return false
	if _pending_line.is_empty():
		return _is_on_ghost(world_pos)
	var target := Accessibility.MIN_TOUCH_TARGET_PX / maxf(_camera.zoom.x, 0.01)
	for point: Vector2i in _pending_line:
		var rect := Rect2(
			Vector2(point) * float(Grid.TILE_SIZE),
			Vector2(def.footprint) * float(Grid.TILE_SIZE)
		)
		rect = rect.grow(maxf(0.0, (target - minf(rect.size.x, rect.size.y)) * 0.5))
		if rect.has_point(world_pos):
			return true
	return false


func _move_to_finger(screen_pos: Vector2) -> void:
	_move_to_world(_to_world(screen_pos))


func _to_world(screen_pos: Vector2) -> Vector2:
	return _camera.get_canvas_transform().affine_inverse() * screen_pos


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _move_to_world(world_pos: Vector2) -> void:
	if def == null:
		return
	var grid: Grid = World.grid
	# Centre the footprint on the touch point in PIXELS, not in whole cells. Picking
	# the cell first and then integer-dividing the footprint hangs a 2x2 down-right
	# of the finger by a whole tile — the same detachment the floating ghost had,
	# just smaller.
	var anchor_coord := Vector2i(
		roundi(world_pos.x / float(Grid.TILE_SIZE) - def.footprint.x * 0.5),
		roundi(world_pos.y / float(Grid.TILE_SIZE) - def.footprint.y * 0.5)
	)
	if not grid.is_valid_v(anchor_coord):
		return
	_anchor = grid.index_v(anchor_coord)
	_ghost.position = Vector2(
		anchor_coord.x * Grid.TILE_SIZE,
		(anchor_coord.y + def.footprint.y) * Grid.TILE_SIZE
	)
	_evaluate()


func _evaluate() -> void:
	if def == null or _anchor == -1:
		return
	var check := Colony.check_placement(def, _anchor)
	_valid = check["ok"]
	_status = check["reason"]
	_bad_cells = check["bad"]
	_cells = check["cells"]
	_ghost.modulate = Color(0.55, 1.0, 0.6, 0.6) if _valid else Color(1.0, 0.4, 0.4, 0.55)
	queue_redraw()
	placement_changed.emit(true, _status, _valid)


# --- Ghost overlay --------------------------------------------------------------------

## Per-cell validity, drawn rather than sprited because the footprint varies per
## building. Marking the individual offending tiles matters: "blocked ground" alone
## does not tell the player whether to nudge one tile left or find a new site.
func _draw() -> void:
	if not active:
		return
	if not _pending_line.is_empty() and def != null:
		for point: Vector2i in _pending_line:
			var good: bool = _pending_line_valid.get(point, false)
			var rect := Rect2(
				point.x * Grid.TILE_SIZE, point.y * Grid.TILE_SIZE,
				def.footprint.x * Grid.TILE_SIZE, def.footprint.y * Grid.TILE_SIZE
			)
			draw_rect(rect, Color(0.5, 1, 0.6, 0.24) if good else Color(1, 0.3, 0.3, 0.35), true)
			draw_rect(rect, Color(0.7, 1, 0.75, 0.8) if good else Color(1, 0.4, 0.4, 0.8), false, 1.0)
		return
	if _cells.is_empty():
		return
	var grid: Grid = World.grid
	for cell in _cells:
		var c := grid.coord(cell)
		var rect := Rect2(
			c.x * Grid.TILE_SIZE, c.y * Grid.TILE_SIZE,
			Grid.TILE_SIZE, Grid.TILE_SIZE
		)
		var bad: bool = _bad_cells.has(cell)
		draw_rect(rect, Color(1, 0.3, 0.3, 0.35) if bad else Color(0.5, 1, 0.6, 0.18), true)
		draw_rect(rect, Color(1, 0.4, 0.4, 0.8) if bad else Color(0.6, 1, 0.7, 0.5), false, 1.0)
