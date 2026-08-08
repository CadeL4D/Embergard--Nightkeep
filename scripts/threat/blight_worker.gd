class_name BlightWorker
extends Agent
## A lightweight enemy laborer. It converts existing corrupted ground into a
## carried numeric stack, deposits that mass, then physically visits build and
## repair sites. Decisions run in Sim's existing think buckets.

enum State { IDLE, TO_HARVEST, HARVESTING, RETURNING, TO_TASK, WORKING }

const HARVEST_TIME := 1.8
const BUILD_TIME := 3.0
const CARRY_CAPACITY := 4

var state: State = State.IDLE
var home_cell: int = -1
var target_cell: int = -1
var carry_mass: int = 0
var work_left: float = 0.0
var jailed_anchor: int = -1
var _awaiting_path := false
var _anim_time := 0.0

@onready var _sprite: Sprite2D = $Sprite
@onready var _carry_mark: Polygon2D = $CarryMark


func setup(home: int) -> void:
	home_cell = home
	max_health = 18.0
	move_speed = 17.0


func _ready() -> void:
	super()
	Threat.register_worker(self)


func _exit_tree() -> void:
	World.paths.cancel_for(self)
	Threat.unregister_worker(self)
	super()


func think(delta: float) -> void:
	if not alive or _awaiting_path or is_moving():
		return
	if state == State.IDLE and carry_mass > 0:
		_start_return()
		return
	match state:
		State.TO_HARVEST:
			state = State.HARVESTING
			work_left = HARVEST_TIME
		State.HARVESTING:
			work_left -= delta
			if work_left <= 0.0:
				carry_mass = Threat.harvest_blight_mass(self, target_cell, CARRY_CAPACITY)
				_start_return() if carry_mass > 0 else _idle()
		State.RETURNING:
			Threat.deposit_blight_mass(carry_mass)
			carry_mass = 0
			_idle()
		State.TO_TASK:
			state = State.WORKING
			work_left = BUILD_TIME
		State.WORKING:
			work_left -= delta
			if work_left <= 0.0:
				Threat.complete_worker_task(self)
				_idle()
		_:
			var task := Threat.assign_worker_task(self)
			if not task.is_empty():
				target_cell = int(task["cell"])
				_go(target_cell, State.TO_TASK)
				return
			target_cell = Threat.claim_harvest_cell(self, home_cell)
			if target_cell != -1:
				_go(target_cell, State.TO_HARVEST)


func _start_return() -> void:
	home_cell = Threat.worker_home(cell())
	var destination := World.nearest_walkable(home_cell, 5)
	if destination == -1:
		_idle()
		return
	_go(destination, State.RETURNING)


func _go(destination: int, next_state: State) -> void:
	stop()
	if World.grid.chebyshev(cell(), destination) <= 1:
		state = next_state
		think_urgent = true
		return
	_awaiting_path = true
	World.paths.request(cell(), destination, func(path: PackedInt32Array) -> void:
		_awaiting_path = false
		if not alive:
			return
		if path.is_empty():
			if next_state == State.TO_HARVEST:
				Threat.release_harvest_claim(self)
			elif next_state == State.TO_TASK:
				Threat.cancel_worker_task(self)
			_idle()
			return
		follow_path(path)
		state = next_state
	)


func _idle() -> void:
	target_cell = -1
	work_left = 0.0
	state = State.IDLE
	think_urgent = true


func restore_record(row: Dictionary) -> void:
	home_cell = int(row.get("home", home_cell))
	carry_mass = int(row.get("carry", 0))
	jailed_anchor = int(row.get("jailed_anchor", -1))
	if jailed_anchor != -1:
		var jail := Colony.building_covering(jailed_anchor)
		if jail != null and jail.def.jails_drones:
			jail_at(jail)
			return
	var task: Dictionary = row.get("task", {}).duplicate(true)
	if not task.is_empty():
		Threat.restore_worker_task(self, task)
		target_cell = int(task.get("cell", -1))
		_go(target_cell, State.TO_TASK)
	else:
		state = State.IDLE
		think_urgent = true


func jail_at(building: Building) -> void:
	stop()
	World.paths.cancel_for(self)
	jailed_anchor = building.anchor
	position = building.centre_position()
	held_by_hand = true
	state = State.IDLE
	target_cell = -1


func release_from_jail(cell_index: int) -> void:
	jailed_anchor = -1
	held_by_hand = false
	var release_cell := World.nearest_walkable(cell_index)
	if release_cell != -1:
		position = World.grid.to_world_index(release_cell)
	think_urgent = true


func on_path_finished() -> void:
	think_urgent = true


func damage_resistances() -> Dictionary:
	return {&"blight": 0.7, &"holy": -0.4}


func has_behavior(tag: StringName) -> bool:
	return tag == &"worker" or tag == &"light"


func knockback_from(origin: Vector2, tiles: float) -> void:
	if tiles <= 0.0:
		return
	var away := (position - origin).normalized()
	var landing := World.nearest_walkable(World.grid.to_cell_index(
		position + away * tiles * Grid.TILE_SIZE), ceili(tiles) + 2)
	if landing != -1:
		stop()
		position = World.grid.to_world_index(landing)
		think_urgent = true


func on_death(cause: StringName) -> void:
	if cause != &"dawn":
		Divine.reward_kill(0.5)


func _process(delta: float) -> void:
	super(delta)
	_anim_time += delta * (5.0 if is_moving() else 1.5)
	_sprite.frame = int(_anim_time) % 2
	if absf(facing.x) > 0.05:
		_sprite.flip_h = facing.x < 0.0
	_carry_mark.visible = carry_mass > 0
