extends Camera2D
## Touch camera: one-finger drag to pan with inertia, two-finger pinch to zoom.
##
## Handles InputEventScreenTouch/Drag ONLY, never mouse events. With
## `pointing/emulate_touch_from_mouse` enabled in project settings, desktop
## development exercises this exact code path — which is the only reliable way to
## avoid discovering touch bugs for the first time on a device.
##
## Lives in _unhandled_input so Control-based UI consumes its own touches first,
## and so the placement controller and God Hand (added in later milestones) can sit
## in front of it in the input order.

const PAN_THRESHOLD := 12.0            ## px of movement before a touch becomes a pan
const TAP_MAX_TIME := 0.25             ## seconds; longer than this is not a tap
const INERTIA_DECAY := 6.0             ## higher = the flick stops sooner
const INERTIA_CUTOFF := 4.0            ## px/s below which we just stop
## The art is authored at 16 px per cell, but a 2x camera inside a 2x desktop
## stretch made one terrain cell occupy 64 physical pixels.  That is why the old
## view felt like it was built out of 128 px building blocks even though the sim
## grid itself was already small.
##
## 1x is now the authored/default view.  Nothing in pathfinding or placement
## changes; the player simply sees twice as much settlement in each direction.
const DEFAULT_ZOOM := 1.0
const ZOOM_MIN := 0.5
const ZOOM_MAX := 4.0
const ZOOM_SNAP_TIME := 0.1
const ZOOM_STEPS: Array[float] = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

signal tapped(world_pos: Vector2)

enum State { NONE, PANNING, PINCHING }

var _state: State = State.NONE
var _touches: Dictionary = {}          ## finger index -> current position
var _touch_start: Vector2 = Vector2.ZERO
var _touch_start_time: float = 0.0
var _velocity: Vector2 = Vector2.ZERO
var _pinch_prev_dist: float = 0.0
var _snap_tween: Tween


func _ready() -> void:
	zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	make_current()


func _process(delta: float) -> void:
	if _state != State.NONE:
		return
	if _velocity.length() <= INERTIA_CUTOFF:
		_velocity = Vector2.ZERO
		return
	position -= _velocity * delta / zoom.x
	_velocity = _velocity.lerp(Vector2.ZERO, clampf(INERTIA_DECAY * delta, 0.0, 1.0))
	_clamp_position()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		_handle_wheel(event)


## Desktop convenience only. There is no pinch gesture on a PC, so the wheel stands
## in for it — anchored under the cursor for the same reason the pinch is anchored
## at the finger midpoint. Mobile never sees these events.
func _handle_wheel(event: InputEventMouseButton) -> void:
	if not event.pressed:
		return
	var factor := 0.0
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		factor = 1.1
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		factor = 1.0 / 1.1
	else:
		return

	var world_before := _screen_to_world(event.position)
	var new_zoom := clampf(zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	zoom = Vector2(new_zoom, new_zoom)
	position += world_before - _screen_to_world(event.position)
	_clamp_position()
	get_viewport().set_input_as_handled()


# --- Touch ---------------------------------------------------------------------------

func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_touch_start = event.position
			_touch_start_time = _now()
			_velocity = Vector2.ZERO
			_state = State.NONE
		elif _touches.size() == 2:
			_state = State.PINCHING
			_pinch_prev_dist = _touch_distance()
		return

	# Release. A short, small movement with one finger is a tap, and taps are the
	# game's primary verb — they must survive a slightly sloppy finger.
	var was_state := _state
	var elapsed := _now() - _touch_start_time
	var travelled := event.position.distance_to(_touch_start)
	_touches.erase(event.index)

	if _touches.is_empty():
		if was_state != State.PINCHING and travelled < PAN_THRESHOLD and elapsed < TAP_MAX_TIME:
			_velocity = Vector2.ZERO
			tapped.emit(_screen_to_world(event.position))
		_state = State.NONE
		if was_state == State.PINCHING:
			_snap_zoom()
	elif _touches.size() == 1:
		# Second finger lifted: resume panning from wherever the remaining one is,
		# rather than snapping the map by the delta between the two.
		_state = State.PANNING
		_touch_start = _touches.values()[0]
		_velocity = Vector2.ZERO
		_snap_zoom()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		return
	_touches[event.index] = event.position

	if _touches.size() >= 2:
		_state = State.PINCHING
		_apply_pinch()
		return

	if _state == State.NONE:
		if event.position.distance_to(_touch_start) < PAN_THRESHOLD:
			return
		_state = State.PANNING

	if _state == State.PANNING:
		position -= event.relative / zoom.x
		# event.velocity is already in screen px/s, which is what the inertia
		# integration above expects.
		_velocity = event.velocity
		_clamp_position()


# --- Pinch ---------------------------------------------------------------------------

## Anchored at the two-finger midpoint: we record the world point under the midpoint,
## apply the zoom, then shift the camera so that same world point is back under the
## midpoint. Without this the map appears to zoom toward the screen centre and the
## gesture feels detached from your fingers.
func _apply_pinch() -> void:
	var dist := _touch_distance()
	if _pinch_prev_dist <= 0.0 or dist <= 0.0:
		_pinch_prev_dist = dist
		return

	var midpoint := _touch_midpoint()
	var world_before := _screen_to_world(midpoint)

	var factor := dist / _pinch_prev_dist
	var new_zoom := clampf(zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	zoom = Vector2(new_zoom, new_zoom)
	_pinch_prev_dist = dist

	var world_after := _screen_to_world(midpoint)
	position += world_before - world_after
	_clamp_position()


## Snap to a curated set of zooms on release, tweened. Whole numbers made the
## useful wide views (0.5x and 0.75x) impossible to hold; arbitrary fractional
## values make pixel art shimmer at rest.
func _snap_zoom() -> void:
	var target := ZOOM_STEPS[0]
	var best_distance := absf(zoom.x - target)
	for step in ZOOM_STEPS:
		var distance := absf(zoom.x - step)
		if distance < best_distance:
			target = step
			best_distance = distance
	if is_equal_approx(target, zoom.x):
		return
	if _snap_tween and _snap_tween.is_valid():
		_snap_tween.kill()
	_snap_tween = create_tween()
	_snap_tween.tween_property(self, "zoom", Vector2(target, target), ZOOM_SNAP_TIME)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


# --- Helpers ---------------------------------------------------------------------------

func _touch_distance() -> float:
	var pts: Array = _touches.values()
	return pts[0].distance_to(pts[1]) if pts.size() >= 2 else 0.0


func _touch_midpoint() -> Vector2:
	var pts: Array = _touches.values()
	return (pts[0] + pts[1]) * 0.5 if pts.size() >= 2 else Vector2.ZERO


func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * screen_pos


## Keep the camera inside the map, inset by half a viewport so the player can never
## drag the world entirely off screen. When the map is smaller than the view (deep
## zoom-out) the clamp collapses to the map centre rather than fighting the player.
func _clamp_position() -> void:
	var map_rect := World.grid.world_rect()
	var half_view := get_viewport_rect().size * 0.5 / zoom.x
	var min_pos := map_rect.position + half_view
	var max_pos := map_rect.end - half_view
	var centre := map_rect.get_center()
	if min_pos.x > max_pos.x:
		position.x = centre.x
	else:
		position.x = clampf(position.x, min_pos.x, max_pos.x)
	if min_pos.y > max_pos.y:
		position.y = centre.y
	else:
		position.y = clampf(position.y, min_pos.y, max_pos.y)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func center_on_cell(cell: int) -> void:
	if cell == -1:
		return
	position = World.grid.to_world_index(cell)
	_clamp_position()
