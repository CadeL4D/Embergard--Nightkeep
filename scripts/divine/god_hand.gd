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
## Extra grace around the Ember specifically. It is the thing players reach for
## most, so it is the thing most worth making forgiving to grab.
const EMBER_GRAB_PX := 64.0

## How far the finger must move before a touch that started on the Ember becomes a
## drag. Below this it stays a tap, so tapping a tile right next to the Ember sends
## it there with a glide instead of being eaten by the grab zone.
const DRAG_COMMIT_PX := 10.0

signal armed_changed(power: PowerDef)
signal hand_mode_changed(active: bool)

var selected: Villager = null

## The building the player has tapped, if any. Mutually exclusive with `selected` — one selection,
## one card, so the bottom of a phone screen is never fighting itself.
##
## Buildings are selectable because there is nowhere else upgrading and demolishing could live.
## They are also the safe thing to add: unlike a villager they do not move, so a tap that lands on
## one was unambiguously meant for it. Empty ground still sends the Ember, which is the verb the
## player uses constantly and must not be taken away.
var selected_building: Building = null
var hand_mode: bool = false
var held: Node = null
var _held_origin_cell: int = -1
var _hand_preview_cell: int = -1

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
	# The resource brush owns world input while active. Letting God Hand also see a
	# paint stroke would move the Ember or select villagers underneath it.
	if DefenseControl.gather_job != &"":
		return
	if event.is_action_pressed(&"game_cancel"):
		_cancel_desktop_action()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
			_cancel_desktop_action()
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch:
		_on_touch(event)
	elif event is InputEventScreenDrag:
		_on_drag(event)
	elif event is InputEventMouseMotion and hand_mode and held != null:
		_update_hand_preview(_to_world(event.position))


func _cancel_desktop_action() -> void:
	if armed != null:
		armed = null
		armed_changed.emit(null)
	_select(null)
	_select_building(null)
	if hand_mode:
		set_hand_mode(false)


func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _dragging_ember or _pending_ember_grab:
			return
		_touch_start = event.position
		_touch_start_time = _now()
		if hand_mode and held != null:
			_hand_preview_cell = World.grid.to_cell_index(_to_world(event.position))
			_drag_finger = event.index
			queue_redraw()

		# Touching the Ember does NOT move it yet — it only arms a possible drag.
		# Committing on touch-down made the Ember jump to the finger and swallowed
		# the release, so a tap anywhere inside the grab zone snapped instead of
		# gliding. The event is still consumed so the camera cannot start panning
		# out from under the gesture.
		if not hand_mode and _is_on_ember(_to_world(event.position)):
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
		if was_drag:
			Divine.end_ember_drag()
		# Armed but never moved: the player tapped, so treat it like any other tap
		# and let the Ember glide there.
		elif _handle_tap(_to_world(event.position)):
			pass
		get_viewport().set_input_as_handled()
		return

	# A short, near-stationary press is a tap. Taps are the game's primary verb, so
	# the thresholds are generous enough to survive a sloppy thumb.
	var elapsed := _now() - _touch_start_time
	var travelled := event.position.distance_to(_touch_start)
	if elapsed < Accessibility.TAP_MAX_TIME \
			and travelled < Accessibility.GESTURE_SLOP_PX:
		if _handle_tap(_to_world(event.position)):
			get_viewport().set_input_as_handled()


func _on_drag(event: InputEventScreenDrag) -> void:
	if hand_mode and held != null and event.index == _drag_finger:
		_update_hand_preview(_to_world(event.position))
		get_viewport().set_input_as_handled()
		return
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
		Divine.begin_ember_drag()

	if not _dragging_ember:
		return
	_move_ember_to(_to_world(event.position))
	get_viewport().set_input_as_handled()


# --- The Ember ------------------------------------------------------------------------

func _is_on_ember(world_pos: Vector2) -> bool:
	if Divine.ember_cell == -1:
		return false
	return world_pos.distance_to(Divine.ember_position()) <= _world_radius(EMBER_GRAB_PX)


## Hands the raw touch point straight to Divine — no rounding to a cell. Snapping
## the Ember to tile centres while the finger was still down made it lag half a tile
## behind the thumb and jump in 16px steps; Divine eases it toward this point and
## only settles on a cell when the drag ends.
func _move_ember_to(world_pos: Vector2) -> void:
	Divine.drag_ember_to(world_pos)


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
	if hand_mode:
		return _handle_hand_tap(world_pos)

	var hit := _pick_villager(world_pos)
	if hit != null:
		_select(hit)
		return true

	var cell := World.grid.to_cell_index(world_pos)
	if cell == -1:
		return false

	# A move order outranks selecting a building: with someone selected, the next tap is a
	# destination, and "walk over there" must not turn into "inspect that hut" because the
	# destination happened to have a stockpile on it.
	if selected != null and is_instance_valid(selected):
		selected.command_to(cell)
		_select(null)
		return true

	var structure := _pick_building(cell)
	if structure != null:
		_select_building(structure)
		return true

	_select_building(null)
	Divine.tween_ember_to(cell)
	return true


## Nearest villager within a zoom-independent radius. Never hit-tests the sprite's
## actual pixels — a 12px figure is far below a usable touch target, and requiring
## precision on a moving unit would make the God Hand feel broken.
func _pick_villager(world_pos: Vector2) -> Villager:
	var radius := _world_radius(Accessibility.MIN_TOUCH_TARGET_PX)
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


# --- Explicit Hand mode ---------------------------------------------------------------

func set_hand_mode(active: bool) -> void:
	if hand_mode == active:
		return
	if held != null and is_instance_valid(held):
		if held is Agent:
			held.held_by_hand = false
			held.think_urgent = true
		elif held is Building:
			held.cancel_hand_move(_held_origin_cell)
	held = null
	_held_origin_cell = -1
	_hand_preview_cell = -1
	hand_mode = active
	if active:
		disarm()
		_select(null)
		_select_building(null)
	hand_mode_changed.emit(active)
	queue_redraw()


func _handle_hand_tap(world_pos: Vector2) -> bool:
	if held == null or not is_instance_valid(held):
		var candidate: Agent = _pick_villager(world_pos)
		if candidate == null:
			candidate = _pick_light_hostile(world_pos)
		var picked: Node = candidate
		if picked == null:
			var cell := World.grid.to_cell_index(world_pos)
			var building := _pick_building(cell)
			if building != null and building.def.menu_hidden:
				picked = building
		if picked == null or not _hand_can_lift(picked):
			Events.notice.emit(tr(&"HAND_INVALID_TARGET"), 1)
			return true
		held = picked
		_held_origin_cell = _held_cell()
		if held is Agent:
			held.stop()
			held.held_by_hand = true
		else:
			held.begin_hand_move()
		Events.hand_action.emit(&"lift", world_pos)
		queue_redraw()
		return true

	var destination := World.grid.to_cell_index(world_pos)
	_hand_preview_cell = destination
	if not _hand_drop_valid(destination):
		Events.notice.emit(tr(&"HAND_INVALID_DROP"), 1)
		queue_redraw()
		return true
	var distance := sqrt(float(World.grid.dist_sq(_held_origin_cell, destination)))
	var cost := _hand_weight(held) + distance * 0.25
	if not Divine.pay(cost):
		Events.notice.emit(L10n.t(&"HAND_NEED_FAITH", [ceili(cost)]), 1)
		return true
	if held is Building:
		held.drop_from_hand(destination)
	else:
		held.position = World.grid.to_world_index(destination)
		held.held_by_hand = false
		held.think_urgent = true
	Events.hand_action.emit(&"drop", World.grid.to_world_index(destination))
	held = null
	_held_origin_cell = -1
	_hand_preview_cell = -1
	queue_redraw()
	return true


func _pick_light_hostile(world_pos: Vector2) -> Agent:
	var radius := _world_radius(Accessibility.MIN_TOUCH_TARGET_PX)
	var best: Agent = null
	var best_dist := radius * radius
	for hostile: Agent in Threat.hostiles:
		if not is_instance_valid(hostile) or not hostile.alive:
			continue
		var distance := hostile.position.distance_squared_to(world_pos)
		if distance <= best_dist:
			best_dist = distance
			best = hostile
	return best


func _hand_can_lift(candidate: Node) -> bool:
	if candidate is Building:
		return candidate.def != null and candidate.def.menu_hidden and not candidate.is_site()
	if candidate is Villager or candidate is BlightWorker:
		return true
	return candidate.max_health <= 55.0 and not candidate.has_behavior(&"boss") \
		and not candidate.has_behavior(&"rooted")


func _hand_weight(candidate: Node) -> float:
	if candidate is Building:
		return 8.0 + float(candidate.cells.size()) * 1.5
	if candidate is Villager:
		return 5.0 + float(candidate.carry_amount) * 0.2
	if candidate is BlightWorker:
		return 4.0 + float(candidate.carry_mass) * 0.5
	return 3.0 + candidate.max_health * 0.08


func _held_cell() -> int:
	if held is Building:
		return held.anchor
	if held is Agent:
		return held.cell()
	return -1


func _hand_drop_valid(destination: int) -> bool:
	if destination == -1:
		return false
	if held is Building:
		return held.can_drop_from_hand(destination)
	return World.is_walkable(destination)


func _update_hand_preview(world_pos: Vector2) -> void:
	_hand_preview_cell = World.grid.to_cell_index(world_pos)
	queue_redraw()


func hand_status() -> String:
	if not hand_mode:
		return tr(&"UI_HAND")
	if held == null or not is_instance_valid(held):
		return tr(&"HAND_PICK")
	if _hand_preview_cell != -1:
		var distance := sqrt(float(World.grid.dist_sq(_held_origin_cell, _hand_preview_cell)))
		return L10n.t(&"HAND_PREVIEW", [ceili(_hand_weight(held) + distance * 0.25),
			tr(&"HAND_VALID") if _hand_drop_valid(_hand_preview_cell) else tr(&"HAND_BLOCKED")])
	return L10n.t(&"HAND_HOLDING", [ceili(_hand_weight(held))])


## The building standing on a cell, via the claim layer.
##
## Asks `claimed` rather than sweeping Colony.buildings and testing footprints: that layer is
## already an exact cell → building-instance map maintained from the moment a blueprint goes down,
## which is precisely the question being asked. No touch padding either — a building is at least a
## whole tile and it does not move, so tile precision is honest here in a way it is not for a 12px
## villager.
func _pick_building(cell: int) -> Building:
	if not World.grid.is_valid_index(cell):
		return null
	var id := World.claimed[cell]
	if id == 0:
		return null
	var node := instance_from_id(id)
	return node if node is Building else null


func _select(v: Villager) -> void:
	if selected != null and is_instance_valid(selected):
		selected.selected = false
	selected = v
	if v != null:
		v.selected = true
		_select_building(null)


func _select_building(b: Building) -> void:
	selected_building = b
	queue_redraw()


## Called by the HUD after a demolition or an upgrade, so the card cannot keep offering actions on
## a building that is now a blueprint or gone.
func clear_building_selection() -> void:
	selected_building = null
	queue_redraw()


func _draw() -> void:
	if held != null and is_instance_valid(held):
		var held_position: Vector2 = held.centre_position() if held is Building else held.position
		draw_circle(held_position, 9.0, Color(0.95, 0.78, 0.4, 0.12))
		draw_arc(held_position, 9.0, 0.0, TAU, 24,
			Color(1.0, 0.84, 0.5, 0.9), 1.5)
		if _hand_preview_cell != -1:
			var preview_position := World.grid.to_world_index(_hand_preview_cell)
			var valid := _hand_drop_valid(_hand_preview_cell)
			var color := Color(0.42, 0.92, 0.62, 0.85) if valid \
				else Color(1.0, 0.36, 0.28, 0.85)
			draw_line(held_position, preview_position, Color(color, 0.4), 1.0)
			draw_circle(preview_position, 8.0, Color(color, 0.12))
			draw_arc(preview_position, 8.0, 0.0, TAU, 24, color, 1.5)
	if selected_building == null or not is_instance_valid(selected_building) \
			or selected_building.is_site():
		return
	var def: BuildingDef = selected_building.def
	var center := selected_building.centre_position()
	if def.attack_damage > 0.0:
		var radius := def.attack_range * Grid.TILE_SIZE
		draw_circle(center, radius, Color(0.95, 0.52, 0.25, 0.07))
		draw_arc(center, radius, 0.0, TAU, 64, Color(1.0, 0.66, 0.32, 0.8), 1.5, true)
	if def.light_radius > 0:
		var light_radius := float(def.light_radius * Grid.TILE_SIZE)
		draw_arc(center, light_radius, 0.0, TAU, 64,
			Color(1.0, 0.88, 0.48, 0.55), 1.0, true)
	if def.workplace_key() == &"maintenance":
		var repair_radius := 10.0 * Grid.TILE_SIZE
		draw_arc(center, repair_radius, 0.0, TAU, 64,
			Color(0.42, 0.82, 0.72, 0.6), 1.0, true)


# --- Helpers ----------------------------------------------------------------------------

func _to_world(screen_pos: Vector2) -> Vector2:
	return _camera.get_canvas_transform().affine_inverse() * screen_pos


func _world_radius(screen_px: float) -> float:
	return screen_px / maxf(_camera.zoom.x, 0.01)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
