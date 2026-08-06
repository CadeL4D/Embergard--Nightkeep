class_name Golem
extends Agent
## A persistent divine worker or guard. Golems deliberately do not inherit Villager: they have no
## hunger, sleep, mood, equipment, household, job quota or reproduction hooks. They reuse only the
## colony's physical claims, delivery ledgers and building work APIs.

enum State { IDLE, FETCHING, DELIVERING, BUILDING, HAULING, GUARDING }

const REACH_SQ := 700.0

var power_id: StringName = &""
var role: StringName = &""
var state: State = State.IDLE
var carry_kind: StringName = &""
var carry_amount: int = 0
var selected: bool = false:
	set(value):
		selected = value
		if _ring != null:
			_ring.visible = value

var _power: PowerDef = null
var _target_cell: int = -1
var _site: Building = null
var _fetch_kind: StringName = &""
var _fetch_from: int = -1
var _fetch_drop_id: int = -1
var _fetching_drop: bool = false
var _supply_request_id: int = 0
var _supply_destination: Building = null
var _work_progress: float = 0.0
var _awaiting_path: bool = false
var _path_serial: int = 0
var _path_requested_tick: int = 0
var _light_handle: int = 0
var _light_cell: int = -1

@onready var _sprite: Sprite2D = $Sprite
@onready var _ring: Sprite2D = $SelectionRing
@onready var _carry: Sprite2D = $Carry


func setup(def: PowerDef) -> void:
	_power = def
	power_id = def.id if def != null else &""
	role = def.construct_role if def != null else &""
	move_speed = def.construct_move_speed if def != null else 25.0
	max_health = def.construct_max_health if def != null else 80.0
	health = max_health


func _ready() -> void:
	super()
	if _power == null:
		_power = Powers.get_power(power_id)
	if _power == null or _power.construct_role.is_empty():
		queue_free()
		return
	setup(_power)
	_ring.visible = false
	_sprite.modulate = _power.color
	_sprite.frame = 5 if role == &"guard" else 1
	_carry.hframes = Colony.KINDS.size()
	_carry.visible = false
	Colony.golems.append(self)
	if _power.construct_light_radius > 0 and World.grid.is_valid_index(cell()):
		_light_cell = cell()
		_light_handle = World.light_field.add_source(_light_cell,
			_power.construct_light_radius, 190)
	Events.golem_spawned.emit(self)


func _exit_tree() -> void:
	_cancel_path_request()
	_release_task()
	Colony.golems.erase(self)
	if _light_handle != 0 and World.light_field != null:
		World.light_field.remove_source(_light_handle)
		_light_handle = 0
	super()


func _process(delta: float) -> void:
	super(delta)
	if _light_handle != 0 and World.grid.is_valid_index(cell()) and cell() != _light_cell:
		_light_cell = cell()
		World.light_field.move_source(_light_handle, _light_cell)
	if _sprite != null:
		_sprite.flip_h = facing.x < -0.1
	if _carry != null:
		_carry.visible = carry_amount > 0 and not carry_kind.is_empty()
		if _carry.visible:
			_carry.frame = maxi(Colony.KINDS.find(carry_kind), 0)


func think(delta: float) -> void:
	if not alive:
		return
	if _awaiting_path and Sim.tick - _path_requested_tick > PathService.MAX_AGE_TICKS + Sim.BUCKETS:
		_cancel_path_request()
		_release_task()
		state = State.IDLE
	if Divine.faith <= 0.0:
		stop()
		_cancel_path_request()
		_release_task()
		state = State.IDLE
		return
	if _awaiting_path:
		return
	if role == &"guard":
		_tick_guard(delta)
	else:
		_tick_labor(delta)


func _tick_labor(delta: float) -> void:
	match state:
		State.FETCHING:
			_tick_fetching()
			return
		State.DELIVERING:
			_tick_delivering()
			return
		State.BUILDING:
			_tick_building(delta)
			return
		State.HAULING:
			_tick_hauling()
			return
		_:
			pass
	if is_moving():
		return
	if carry_amount > 0:
		if _supply_request_id > 0 and _resume_supply_delivery():
			return
		if not _begin_haul():
			state = State.IDLE
		return
	var assignment := Colony.claim_supply_request(self, cell(), carry_capacity())
	if not assignment.is_empty():
		_supply_request_id = int(assignment["id"])
		_supply_destination = Colony.supply_destination(_supply_request_id)
		_fetch_kind = StringName(assignment["resource"])
		_fetch_from = int(assignment["source"])
		_request_path(_fetch_from, State.FETCHING)
		return
	if _try_claim_repair() or _try_claim_site() or _begin_loose_drop_fetch():
		return
	state = State.IDLE


func carry_capacity() -> int:
	return maxi(_power.construct_carry_capacity, 1) if _power != null else 10


func _try_claim_site() -> bool:
	var site := Colony.nearest_build_site(cell()) as Building
	if site == null or not Colony.claim(site.anchor, self):
		return false
	_site = site
	_target_cell = site.anchor
	if site.needs_materials():
		if _begin_site_fetch():
			return true
		_release_task()
		return false
	_request_path(site.work_cell(), State.BUILDING)
	return true


func _try_claim_repair() -> bool:
	var target := Colony.nearest_repair_target(cell()) as Building
	if target == null or not Colony.claim(target.anchor, self):
		return false
	_site = target
	_target_cell = target.anchor
	_request_path(target.work_cell(), State.BUILDING)
	return true


func _begin_site_fetch() -> bool:
	if _site == null or not is_instance_valid(_site):
		return false
	_fetch_kind = _site.next_needed()
	if _fetch_kind.is_empty():
		return false
	_fetch_from = Colony.nearest_storage_source(cell(), _fetch_kind)
	if _fetch_from == -1:
		return false
	_fetching_drop = false
	_request_path(_fetch_from, State.FETCHING)
	return true


func _begin_loose_drop_fetch() -> bool:
	if Colony.loose_resource_total() <= 0:
		return false
	var drop_id := Colony.nearest_worker_drop(cell())
	var drop := Colony.loose_drop(drop_id)
	if drop == null:
		return false
	var approach := drop.cell if World.is_walkable(drop.cell) else World.nearest_walkable(drop.cell)
	if approach == -1:
		return false
	_fetch_drop_id = drop.id
	_fetch_from = drop.cell
	_fetching_drop = true
	_request_path(approach, State.FETCHING)
	return true


func _tick_fetching() -> void:
	if is_moving():
		return
	if _fetch_from == -1 or not _within_reach(_fetch_from):
		_release_task()
		state = State.IDLE
		return
	if _supply_request_id > 0:
		var taken := Colony.withdraw_supply_request(
			_supply_request_id, self, _fetch_from, carry_capacity())
		if taken <= 0:
			_release_task()
			state = State.IDLE
			return
		carry_kind = _fetch_kind
		carry_amount = taken
		_supply_destination = Colony.supply_destination(_supply_request_id)
		if _supply_destination == null:
			_release_task()
			state = State.IDLE
			return
		_request_path(_supply_destination.work_cell(), State.DELIVERING)
		return
	if _fetching_drop:
		_fetching_drop = false
		var load := Colony.take_loose_drop(
			_fetch_drop_id, carry_capacity(), LooseDrop.POLICY_WORKER)
		_fetch_drop_id = -1
		_fetch_from = -1
		if load.is_empty():
			state = State.IDLE
			return
		carry_kind = StringName(load["kind"])
		carry_amount = int(load["amount"])
		_begin_haul()
		return
	if _site == null or not is_instance_valid(_site) or not _site.is_site():
		_release_task()
		state = State.IDLE
		return
	var wanted := mini(_site.amount_needed(_fetch_kind), carry_capacity())
	var taken := Colony.withdraw_reserved_at(_fetch_from, _fetch_kind, wanted)
	if taken <= 0:
		_release_task()
		state = State.IDLE
		return
	carry_kind = _fetch_kind
	carry_amount = taken
	_request_path(_site.work_cell(), State.DELIVERING)


func _tick_delivering() -> void:
	if is_moving():
		return
	if _supply_request_id > 0:
		if _supply_destination == null or not is_instance_valid(_supply_destination):
			_release_task()
			state = State.IDLE
			return
		var deposited := Colony.deposit_building_input(
			_supply_destination, carry_kind, carry_amount)
		Colony.complete_supply_delivery(_supply_request_id, deposited)
		carry_amount -= deposited
		if carry_amount <= 0:
			carry_kind = &""
		_release_supply_task()
		if carry_amount > 0:
			_begin_haul()
		else:
			state = State.IDLE
		return
	if _site == null or not is_instance_valid(_site) or not _site.is_site():
		_drop_carry(&"lost_site")
		_release_task()
		state = State.IDLE
		return
	var accepted := _site.deliver(carry_kind, carry_amount)
	carry_amount -= accepted
	if carry_amount <= 0:
		carry_kind = &""
	if _site.needs_materials() and _begin_site_fetch():
		return
	_request_path(_site.work_cell(), State.BUILDING)


func _tick_building(delta: float) -> void:
	if is_moving():
		return
	if _site == null or not is_instance_valid(_site):
		_release_task()
		state = State.IDLE
		return
	if not _within_reach(_site.work_cell()):
		_request_path(_site.work_cell(), State.BUILDING)
		return
	var rate := (_power.construct_work_rate if _power != null else 1.0) \
		* Divine.work_bonus(cell())
	if _site.needs_repair():
		if _site.add_repair_work(delta * rate * Doctrines.modifier(&"repair")):
			_release_task()
			state = State.IDLE
		return
	if not _site.is_site() or _site.add_work(delta * rate):
		_release_task()
		state = State.IDLE


func _begin_haul() -> bool:
	if carry_amount <= 0 or carry_kind.is_empty():
		return false
	var destination := Colony.nearest_storage_destination(cell(), carry_kind)
	if destination == -1:
		return false
	_target_cell = destination
	_request_path(destination, State.HAULING)
	return true


func _tick_hauling() -> void:
	if is_moving():
		return
	if _target_cell == -1 or not _within_reach(_target_cell):
		_begin_haul()
		return
	var deposited := Colony.deposit_at(_target_cell, carry_kind, carry_amount)
	carry_amount -= deposited
	if carry_amount <= 0:
		carry_kind = &""
		_target_cell = -1
		state = State.IDLE
	else:
		_begin_haul()


func _resume_supply_delivery() -> bool:
	_supply_destination = Colony.resume_supply_request(
		_supply_request_id, self, carry_amount)
	if _supply_destination == null:
		return false
	_request_path(_supply_destination.work_cell(), State.DELIVERING)
	return true


func _tick_guard(delta: float) -> void:
	_work_progress = maxf(_work_progress - delta, 0.0)
	state = State.GUARDING
	if not DefenseControl.has_guard_zone():
		stop()
		return
	var target := _nearest_guard_hostile()
	if target == null:
		if is_moving():
			return
		var post := DefenseControl.nearest_guard_cell(cell())
		if post != -1 and World.grid.dist_sq(cell(), post) > 1:
			_request_path(post, State.GUARDING)
		return
	var reach := _power.construct_attack_range * Grid.TILE_SIZE
	if position.distance_squared_to(target.position) <= reach * reach:
		stop()
		facing = (target.position - position).normalized()
		if _work_progress <= 0.0:
			_work_progress = _power.construct_attack_cooldown
			target.take_damage(_power.construct_attack_damage, self,
				_power.construct_attack_type)
			Events.tower_fired.emit(self, _power.construct_attack_damage, target.position)
		return
	if not is_moving():
		var destination := World.nearest_walkable(target.cell())
		if destination != -1:
			_request_path(destination, State.GUARDING)


func _nearest_guard_hostile() -> Agent:
	var best: Agent = null
	var best_distance := INF
	for hostile: Agent in Threat.hostiles:
		if not is_instance_valid(hostile) or not hostile.alive \
				or not DefenseControl.is_guard_cell(hostile.cell()):
			continue
		var distance := position.distance_squared_to(hostile.position)
		if distance < best_distance:
			best_distance = distance
			best = hostile
	return best


func _request_path(destination: int, next_state: State) -> void:
	if not World.grid.is_valid_index(destination):
		return
	stop()
	_cancel_path_request()
	if _within_reach(destination):
		state = next_state
		think_urgent = true
		return
	_awaiting_path = true
	_path_requested_tick = Sim.tick
	var serial := _path_serial
	World.paths.request(cell(), destination, func(path: PackedInt32Array) -> void:
		if serial != _path_serial:
			return
		_awaiting_path = false
		if not alive:
			return
		if path.is_empty() or not DefenseControl.path_allowed(path,
				role == &"guard", role == &"labor"):
			_release_task()
			state = State.IDLE
			think_urgent = true
			return
		follow_path(path)
		state = next_state
	)


func _within_reach(target: int) -> bool:
	return World.grid.is_valid_index(target) \
		and position.distance_squared_to(World.grid.to_world_index(target)) <= REACH_SQ


func _cancel_path_request() -> void:
	_path_serial += 1
	_awaiting_path = false
	if World.paths != null:
		World.paths.cancel_for(self)


func _release_supply_task() -> void:
	if _supply_request_id > 0:
		Colony.release_supply_request(_supply_request_id, self, carry_amount)
	_supply_request_id = 0
	_supply_destination = null


func _release_task() -> void:
	_release_supply_task()
	if _target_cell != -1:
		Colony.release(_target_cell, self)
	Colony.release_all_by(self)
	_target_cell = -1
	_site = null
	_fetch_kind = &""
	_fetch_from = -1
	_fetch_drop_id = -1
	_fetching_drop = false


func _drop_carry(source: StringName) -> void:
	if carry_amount > 0 and not carry_kind.is_empty() and World.grid.is_valid_index(cell()):
		Colony.drop_resource(carry_kind, carry_amount, cell(), source)
	carry_kind = &""
	carry_amount = 0


func dismiss() -> bool:
	if _power == null or not _power.dismissible:
		return false
	die(&"dismissed")
	return true


func prepare_hand_lift() -> void:
	stop()
	_cancel_path_request()
	_release_task()
	state = State.IDLE


func on_death(cause: StringName) -> void:
	spawn_death_ghost(_sprite)
	_release_task()
	_drop_carry(&"golem")
	Events.golem_died.emit(self, cause)


func damage_resistances() -> Dictionary:
	return _power.construct_resistances if _power != null else {}


func display_name() -> String:
	return tr(_power.display_name) if _power != null else tr(&"SELECT_GOLEM")


func describe() -> String:
	if Divine.faith <= 0.0:
		return tr(&"GOLEM_DORMANT")
	if role == &"guard" and not DefenseControl.has_guard_zone():
		return tr(&"GOLEM_NEEDS_GUARD_ZONE")
	return tr(StringName("GOLEM_STATE_" + State.keys()[state]))
