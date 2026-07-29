extends Node2D
## The player's direct touch on the world: dragging the Ember, and selecting or
## commanding individual villagers.
##
## Sits in front of CameraRig in the input order (Godot delivers _unhandled_input
## to later siblings first), so grabbing the Ember or tapping a villager consumes
## the event and the camera never pans out from under the gesture.
##
## Two verbs, deliberately only two:
##   * DRAG the Ember — the signature mechanic, and the only direct-manipulation
##     target in the game. It works because the Ember is one large, high-contrast,
##     always-visible object; nothing else on screen is reliably grabbable at a
##     phone's pixel density.
##   * TAP a villager to select, tap again elsewhere to send them there. Everything
##     else — what people work on, who guards — goes through the Job Board, because
##     per-villager micromanagement is exactly what does not fit on a phone.

## Minimum comfortable touch target, in screen pixels. Converted to world units at
## the current zoom so picking works identically however far out the player is.
const TOUCH_TARGET_PX := 44.0

## Extra grace around the Ember specifically. It is the thing players reach for
## most, so it is the thing most worth making forgiving to grab.
const EMBER_GRAB_PX := 64.0

const TAP_MAX_TIME := 0.25
const TAP_MAX_TRAVEL := 12.0

## How far the finger must move before a touch that started on the Ember becomes a
## drag. Below this it stays a tap, so tapping a tile right next to the Ember sends
## it there with a glide instead of being eaten by the grab zone.
const DRAG_COMMIT_PX := 10.0

signal armed_changed(power: PowerDef)

var selected: Villager = null

## The power waiting for a target, if any. While armed, a tap casts instead of
## doing anything else — the arm-then-tap flow exists because casting on the first
## tap would make every misplaced thumb an expensive mistake.
var armed: PowerDef = null

var _dragging_ember: bool = false
var _pending_ember_grab: bool = false
var _drag_finger: int = -1
var _touch_start: Vector2 = Vector2.ZERO
var _touch_start_time: float = 0.0

@onready var _camera: Camera2D = get_node("../CameraRig")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _dragging_ember or _pending_ember_grab:
			return
		_touch_start = event.position
		_touch_start_time = _now()

		# Touching the Ember does NOT move it yet — it only arms a possible drag.
		# Committing on touch-down made the Ember jump to the finger and swallowed
		# the release, so a tap anywhere inside the grab zone snapped instead of
		# gliding. The event is still consumed so the camera cannot start panning
		# out from under the gesture.
		if _is_on_ember(_to_world(event.position)):
			_pending_ember_grab = true
			_drag_finger = event.index
			get_viewport().set_input_as_handled()
		return

	# --- release ---
	if event.index == _drag_finger and (_dragging_ember or _pending_ember_grab):
		var was_drag := _dragging_ember
		_dragging_ember = false
		_pending_ember_grab = false
		_drag_finger = -1
		# Armed but never moved: the player tapped, so treat it like any other tap
		# and let the Ember glide there.
		if not was_drag and _handle_tap(_to_world(event.position)):
			pass
		get_viewport().set_input_as_handled()
		return

	# A short, near-stationary press is a tap. Taps are the game's primary verb, so
	# the thresholds are generous enough to survive a sloppy thumb.
	var elapsed := _now() - _touch_start_time
	var travelled := event.position.distance_to(_touch_start)
	if elapsed < TAP_MAX_TIME and travelled < TAP_MAX_TRAVEL:
		if _handle_tap(_to_world(event.position)):
			get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if event.index != _drag_finger:
		return

	# Promote an armed touch to a real drag only once the finger has actually
	# travelled, so a slightly imprecise tap is still a tap.
	if _pending_ember_grab and not _dragging_ember:
		if event.position.distance_to(_touch_start) < DRAG_COMMIT_PX:
			get_viewport().set_input_as_handled()
			return
		_dragging_ember = true
		_pending_ember_grab = false

	if not _dragging_ember:
		return
	_move_ember_to(_to_world(event.position))
	get_viewport().set_input_as_handled()


# --- The Ember ------------------------------------------------------------------------

func _is_on_ember(world_pos: Vector2) -> bool:
	if Divine.ember_cell == -1:
		return false
	return world_pos.distance_to(Divine.ember_position()) <= _world_radius(EMBER_GRAB_PX)


func _move_ember_to(world_pos: Vector2) -> void:
	var cell := World.grid.to_cell_index(world_pos)
	if cell == -1:
		return
	Divine.place_ember(cell)


# --- Villagers -------------------------------------------------------------------------

## Returns true if the tap was consumed.
##
## Priority, and why:
##   1. A villager under the finger — selecting a person is always what was meant.
##   2. Ground while someone is selected — that is a move order, and the selection
##      clears so the next tap goes back to the default verb.
##   3. Ground with nothing selected — send the Ember there. This is the DEFAULT
##      because repositioning the light is the thing the player does constantly;
##      making it the no-selection tap keeps the core mechanic one thumb-press away.
func arm(power: PowerDef) -> void:
	armed = power if armed != power else null
	armed_changed.emit(armed)
	queue_redraw()


func disarm() -> void:
	if armed != null:
		armed = null
		armed_changed.emit(null)
		queue_redraw()


func _handle_tap(world_pos: Vector2) -> bool:
	# An armed power consumes the tap wherever it lands, including on a villager —
	# healing or smiting the ground your own people are standing on has to be
	# possible, and second-guessing the player here would be worse than letting
	# them miss.
	if armed != null:
		var cast_def := armed
		if Divine.cast(cast_def, world_pos):
			# Stay armed only if it can be cast again immediately, so chaining is
			# possible but a spent power does not leave a dead cursor armed.
			if not Divine.can_cast(cast_def):
				disarm()
			return true
		disarm()
		return true

	var hit := _pick_villager(world_pos)
	if hit != null:
		_select(hit)
		return true

	var cell := World.grid.to_cell_index(world_pos)
	if cell == -1:
		return false

	if selected != null and is_instance_valid(selected):
		selected.command_to(cell)
		_select(null)
		return true

	Divine.tween_ember_to(cell)
	return true


## Nearest villager within a zoom-independent radius. Never hit-tests the sprite's
## actual pixels — a 12px figure is far below a usable touch target, and requiring
## precision on a moving unit would make the God Hand feel broken.
func _pick_villager(world_pos: Vector2) -> Villager:
	var radius := _world_radius(TOUCH_TARGET_PX)
	var best: Villager = null
	var best_dist := radius * radius
	for v: Villager in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		var d := v.position.distance_squared_to(world_pos)
		if d <= best_dist:
			best_dist = d
			best = v
	return best


func _select(v: Villager) -> void:
	if selected != null and is_instance_valid(selected):
		selected.selected = false
	selected = v
	if v != null:
		v.selected = true


# --- Helpers ----------------------------------------------------------------------------

func _to_world(screen_pos: Vector2) -> Vector2:
	return _camera.get_canvas_transform().affine_inverse() * screen_pos


func _world_radius(screen_px: float) -> float:
	return screen_px / maxf(_camera.zoom.x, 0.01)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
