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
var _pinch_prev_midpoint: Vector2 = Vector2.ZERO
var _paint_navigation: bool = false
var _mouse_panning: bool = false
var _snap_tween: Tween
var _focus_tween: Tween
var _shake_time: float = 0.0
var _shake_duration: float = 0.0
var _shake_strength: float = 0.0
var _shake_phase: float = 0.0


func _ready() -> void:
	zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	make_current()
	# A tool can be closed by Done, another menu, or a keyboard shortcut while one
	# or both map fingers are still down. Those releases then belong to the Control
	# that replaced the tool and never reach this node, leaving ghost touches which
	# poison every later pan and pinch. Tool boundaries are gesture boundaries.
	DefenseControl.gather_mode_changed.connect(
		func(_job: StringName, _erasing: bool, _radius: int) -> void:
			_reset_touch_gesture())
	DefenseControl.paint_mode_changed.connect(
		func(_mode: int) -> void: _reset_touch_gesture())
	Events.breach_detected.connect(func(_where: Vector2) -> void: shake(3.0, 0.22))
	Events.building_destroyed.connect(func(_building: Node) -> void: shake(5.0, 0.34))
	Events.monster_spawned.connect(func(monster: Node) -> void:
		if monster is Monster and monster.def != null and monster.def.is_boss:
			shake(6.0, 0.5)
	)


func _process(delta: float) -> void:
	_tick_keyboard_pan(delta)
	if _state == State.NONE:
		if _velocity.length() <= INERTIA_CUTOFF:
			_velocity = Vector2.ZERO
		else:
			position -= _velocity * delta / zoom.x
			_velocity = _velocity.lerp(Vector2.ZERO, clampf(INERTIA_DECAY * delta, 0.0, 1.0))
			_clamp_position()
	_tick_shake(delta)


## WASD panning, as the no-hardware-required companion to the middle-drag above.
##
## Read straight off the keyboard rather than through an input action: this is desktop
## comfort, not a bound verb, and adding four actions to project.godot for it would put
## them in the rebinding surface of a game whose real input is a touchscreen. WASD
## specifically, not the arrow keys — arrows already nudge a focused job slider, and a
## camera that also slid sideways while the player adjusted a quota is a worse bug than
## the one this fixes.
const KEYBOARD_PAN_SPEED := 420.0        ## screen px/s at 1x zoom

func _tick_keyboard_pan(delta: float) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var move := Vector2(
		float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if move == Vector2.ZERO:
		return
	_velocity = Vector2.ZERO
	position += move.normalized() * KEYBOARD_PAN_SPEED * delta / zoom.x
	_clamp_position()


func shake(strength: float, duration: float) -> void:
	var scale := Accessibility.shake_scale()
	if scale <= 0.0:
		return
	_shake_strength = maxf(_shake_strength, strength * scale)
	_shake_duration = maxf(_shake_duration, duration)
	_shake_time = maxf(_shake_time, duration)


func _tick_shake(delta: float) -> void:
	if _shake_time <= 0.0:
		if offset != Vector2.ZERO:
			offset = Vector2.ZERO
		return
	_shake_time = maxf(_shake_time - delta, 0.0)
	_shake_phase += delta * 61.0
	var fade := _shake_time / maxf(_shake_duration, 0.001)
	offset = Vector2(sin(_shake_phase * 1.73), cos(_shake_phase * 2.11)) \
		* _shake_strength * fade
	if _shake_time <= 0.0:
		_shake_strength = 0.0
		_shake_duration = 0.0


func _unhandled_input(event: InputEvent) -> void:
	# Middle-drag is the one camera gesture that survives every tool, and it is checked
	# before anything else for exactly that reason. A brush owns the left button and
	# erasing owns the right, so while a harvest or zone tool was open there was no way
	# at all to move the map on desktop — the two-finger escape hatch below only exists
	# on a touchscreen. Panning has to work while painting: marking a forest you cannot
	# scroll to is not a workflow.
	if _handle_pan_button(event):
		return

	# Painted orders own one-finger drags. Their paint surfaces consume that first
	# finger, but deliberately pass a two-finger gesture through for map navigation.
	# Desktop wheel zoom also remains available.
	var hand: Node = get_node_or_null("../GodHand")
	var hand_sweep_mode: bool = hand != null and bool(hand.get("_sweep_navigating"))
	if DefenseControl.gather_job != &"" \
			or DefenseControl.paint_mode != DefenseControl.PaintMode.NONE or hand_sweep_mode:
		if event is InputEventScreenTouch:
			_handle_paint_touch(event as InputEventScreenTouch)
			return
		elif event is InputEventScreenDrag:
			_handle_paint_drag(event as InputEventScreenDrag)
			return
		elif not (event is InputEventMouseButton) \
				or (event as InputEventMouseButton).button_index not in [
					MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			return
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		_handle_wheel(event)


## Middle-button drag pan. Returns true when the event belonged to the camera.
##
## Deliberately NOT routed through the touch state machine: `emulate_touch_from_mouse`
## only mirrors the LEFT button, so a middle drag never produces a phantom finger, and
## keeping it separate means a pan started during a brush stroke cannot corrupt the
## pinch bookkeeping when the stroke ends.
func _handle_pan_button(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_MIDDLE:
			return false
		_mouse_panning = button.pressed
		if _mouse_panning:
			_begin_direct_gesture()
			_velocity = Vector2.ZERO
		get_viewport().set_input_as_handled()
		return true
	if _mouse_panning and event is InputEventMouseMotion:
		position -= (event as InputEventMouseMotion).relative / zoom.x
		_clamp_position()
		get_viewport().set_input_as_handled()
		return true
	return false


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
		_begin_direct_gesture()
		_touches[event.index] = event.position
		if _touches.size() == 1:
			_touch_start = event.position
			_touch_start_time = _now()
			_velocity = Vector2.ZERO
			_state = State.NONE
		elif _touches.size() == 2:
			_state = State.PINCHING
			_pinch_prev_dist = _touch_distance()
			_pinch_prev_midpoint = _touch_midpoint()
		return

	# Release. A short, small movement with one finger is a tap, and taps are the
	# game's primary verb — they must survive a slightly sloppy finger.
	var was_state := _state
	var elapsed := _now() - _touch_start_time
	var travelled := event.position.distance_to(_touch_start)
	_touches.erase(event.index)

	if _touches.is_empty():
		if was_state != State.PINCHING \
				and travelled < Accessibility.GESTURE_SLOP_PX \
				and elapsed < Accessibility.TAP_MAX_TIME:
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
		if event.position.distance_to(_touch_start) < Accessibility.GESTURE_SLOP_PX:
			return
		_state = State.PANNING

	if _state == State.PANNING:
		position -= event.relative / zoom.x
		# event.velocity is already in screen px/s, which is what the inertia
		# integration above expects.
		_velocity = event.velocity
		_clamp_position()


## During an order brush, one finger belongs to painting and two fingers belong
## to the camera. CameraRig receives unhandled input before the world paint node,
## so it must track the first finger without moving on it, then promote only when
## a second finger arrives.
func _handle_paint_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		_begin_direct_gesture()
		_touches[event.index] = event.position
		_velocity = Vector2.ZERO
		if _touches.size() >= 2:
			_paint_navigation = true
			_state = State.PINCHING
			_pinch_prev_dist = _touch_distance()
			_pinch_prev_midpoint = _touch_midpoint()
		else:
			_state = State.NONE
		return
	var was_navigation := _paint_navigation
	_touches.erase(event.index)
	if _touches.is_empty():
		_paint_navigation = false
		_state = State.NONE
		if was_navigation:
			_snap_zoom()
	else:
		# Releasing either finger ends navigation; the remaining finger stays a
		# brush contact until it too is lifted.
		_paint_navigation = false
		_state = State.NONE


func _handle_paint_drag(event: InputEventScreenDrag) -> void:
	if not _touches.has(event.index):
		return
	_touches[event.index] = event.position
	if _paint_navigation and _touches.size() >= 2:
		_state = State.PINCHING
		_apply_pinch()


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
	if _pinch_prev_midpoint != Vector2.ZERO:
		position -= (midpoint - _pinch_prev_midpoint) / zoom.x
		_clamp_position()
	var world_before := _screen_to_world(midpoint)

	var factor := dist / _pinch_prev_dist
	var new_zoom := clampf(zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	zoom = Vector2(new_zoom, new_zoom)
	_pinch_prev_dist = dist
	_pinch_prev_midpoint = midpoint

	var world_after := _screen_to_world(midpoint)
	position += world_before - world_after
	_clamp_position()


## A fresh physical gesture owns the camera immediately. In particular, a zoom
## snap or building-focus tween from the previous action must not keep writing the
## same properties while the player's fingers are trying to move them.
func _begin_direct_gesture() -> void:
	if _snap_tween and _snap_tween.is_valid():
		_snap_tween.kill()
	if _focus_tween and _focus_tween.is_valid():
		_focus_tween.kill()


func _reset_touch_gesture() -> void:
	_touches.clear()
	_state = State.NONE
	_velocity = Vector2.ZERO
	_pinch_prev_dist = 0.0
	_pinch_prev_midpoint = Vector2.ZERO
	_paint_navigation = false
	_mouse_panning = false
	_touch_start = Vector2.ZERO
	_touch_start_time = 0.0
	if _snap_tween and _snap_tween.is_valid():
		_snap_tween.kill()


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
	_snap_tween.tween_property(self, "zoom", Vector2(target, target),
		Accessibility.motion_duration(ZOOM_SNAP_TIME))\
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


## Bring a selected building into a comfortable inspection view. Kept as an
## explicit card action so ordinary world taps never unexpectedly move the camera.
func focus_on_rect(world_rect: Rect2) -> void:
	if world_rect.size.x <= 0.0 or world_rect.size.y <= 0.0:
		return
	_velocity = Vector2.ZERO
	var target_zoom := 2.0
	var target_position := world_rect.get_center()
	if _focus_tween and _focus_tween.is_valid():
		_focus_tween.kill()
	_focus_tween = create_tween().set_parallel(true)
	_focus_tween.tween_property(self, "position", target_position,
		Accessibility.motion_duration(0.18)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(self, "zoom", Vector2.ONE * target_zoom,
		Accessibility.motion_duration(0.18)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_focus_tween.chain().tween_callback(_clamp_position)
