class_name Agent
extends Node2D
## Base class for everything that walks: villagers and monsters.
##
## Deliberately NOT a CharacterBody2D. There is no collision response worth having
## here — units overlap freely and are separated by a cheap steering nudge — so the
## 2D physics server would be paying for a solver we never use, 160 times over, on a
## phone. Movement is plain position integration against the grid.
##
## Subclasses override think(); the base class owns movement, the path cursor and
## the registry handshake. think() is called by Sim at roughly 1.7 Hz (see
## Sim.BUCKETS), so it must never assume it runs every frame — all continuous work
## belongs in _process.

@export var move_speed: float = 26.0        ## pixels per second
@export var max_health: float = 40.0

var alive: bool = true
var health: float = 40.0
var think_urgent: bool = false              ## set to be picked up on the next tick

## Current path as cell indices, consumed front-to-back. Empty means "not walking".
var _path: PackedInt32Array = PackedInt32Array()
var _path_cursor: int = 0
var _step_target: Vector2 = Vector2.ZERO
var _has_step: bool = false

## Facing, kept as a unit vector for sprite flipping and attack direction.
var facing: Vector2 = Vector2.DOWN


func _ready() -> void:
	health = max_health
	Sim.register(self)


func _exit_tree() -> void:
	Sim.unregister(self)


# --- Per-frame movement -------------------------------------------------------------

func _process(delta: float) -> void:
	if not alive or not _has_step:
		return
	var to_target := _step_target - position
	var dist := to_target.length()
	var step := move_speed * delta * Sim.time_scale
	if dist <= step:
		position = _step_target
		_advance_path()
	else:
		var dir := to_target / dist
		position += dir * step
		facing = dir


func _advance_path() -> void:
	_path_cursor += 1
	if _path_cursor >= _path.size():
		_path = PackedInt32Array()
		_path_cursor = 0
		_has_step = false
		on_path_finished()
		return
	_step_target = World.grid.to_world_index(_path[_path_cursor])


# --- Path control -------------------------------------------------------------------

func follow_path(path: PackedInt32Array) -> void:
	_path = path
	_path_cursor = 0
	if path.is_empty():
		_has_step = false
		return
	# Skip the first node when it is the cell we are already standing in, otherwise
	# the unit visibly snaps backward to the centre of its own tile before setting off.
	if path.size() > 1 and path[0] == cell():
		_path_cursor = 1
	_step_target = World.grid.to_world_index(_path[_path_cursor])
	_has_step = true


func stop() -> void:
	_path = PackedInt32Array()
	_path_cursor = 0
	_has_step = false


func is_moving() -> bool:
	return _has_step


func cell() -> int:
	return World.grid.to_cell_index(position)


func distance_sq_to(world_pos: Vector2) -> float:
	return position.distance_squared_to(world_pos)


# --- Damage -------------------------------------------------------------------------

func take_damage(amount: float, source: Node = null) -> void:
	if not alive:
		return
	health -= amount
	think_urgent = true                     # react on the next tick, not in 600ms
	on_damaged(amount, source)
	if health <= 0.0:
		die(&"killed")


func die(cause: StringName) -> void:
	if not alive:
		return
	alive = false
	stop()
	on_death(cause)
	queue_free()


# --- Overridable hooks --------------------------------------------------------------
# Empty here rather than abstract so subclasses only implement what they care about.

## Called by Sim at ~1.7 Hz (or immediately when think_urgent is set). `delta` is the
## real time since this agent last thought — NOT the frame delta. Use it for anything
## rate-based inside a decision.
func think(_delta: float) -> void:
	pass

func on_path_finished() -> void:
	pass

func on_damaged(_amount: float, _source: Node) -> void:
	pass

func on_death(_cause: StringName) -> void:
	pass
