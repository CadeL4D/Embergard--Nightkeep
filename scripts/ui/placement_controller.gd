extends Node2D
## Drives building placement: the ghost, the validity read-out, and confirmation.
##
## Deliberately NOT tap-to-place. On a phone the player's thumb covers the exact
## spot they are aiming at, so tapping to place means never being able to see what
## you are doing. Instead the ghost is dragged — rendered offset ABOVE the finger so
## it stays visible — and committed with a separate Confirm button that sits in the
## thumb zone.
##
## Sits after GodHand in the scene so it receives input first: while placing, a drag
## moves the ghost rather than the Ember or the camera.

signal placement_changed(active: bool, status: String, valid: bool)

## How far above the touch point the ghost floats, in tiles. Roughly a fingertip —
## enough to clear the thumb without the ghost feeling detached from the gesture.
const FINGER_OFFSET_TILES := 2.0

var active: bool = false
var def: BuildingDef = null

var _anchor: int = -1
var _valid: bool = false
var _status: String = ""
var _bad_cells: Dictionary = {}
var _cells: PackedInt32Array = PackedInt32Array()
var _drag_finger: int = -1

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
	_ghost.texture = def.sprite
	_ghost.offset = Vector2(0, -def.tile_size().y)
	_ghost.visible = true

	# Start at the centre of the view rather than under the finger, so the player
	# can see the whole footprint before deciding where it goes.
	_move_to_world(_camera.get_screen_center_position())


func cancel() -> void:
	active = false
	def = null
	_anchor = -1
	_bad_cells.clear()
	_cells = PackedInt32Array()
	_ghost.visible = false
	_drag_finger = -1
	queue_redraw()
	placement_changed.emit(false, "", false)


## Commit the blueprint. Returns true if something was actually placed.
func confirm() -> bool:
	if not active or not _valid or _anchor == -1:
		return false
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

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_drag_finger = event.index
			_move_to_finger(event.position)
		elif event.index == _drag_finger:
			_drag_finger = -1
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and event.index == _drag_finger:
		_move_to_finger(event.position)
		get_viewport().set_input_as_handled()


func _move_to_finger(screen_pos: Vector2) -> void:
	var world_pos: Vector2 = _camera.get_canvas_transform().affine_inverse() * screen_pos
	world_pos.y -= FINGER_OFFSET_TILES * Grid.TILE_SIZE
	_move_to_world(world_pos)


func _move_to_world(world_pos: Vector2) -> void:
	if def == null:
		return
	var grid: Grid = World.grid
	# Centre the footprint on the cursor so a 2x2 sits where the player is pointing
	# rather than hanging down-right of it.
	var centre := grid.to_cell(world_pos)
	var anchor_coord := Vector2i(
		centre.x - def.footprint.x / 2,
		centre.y - def.footprint.y / 2
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
	if not active or _cells.is_empty():
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
