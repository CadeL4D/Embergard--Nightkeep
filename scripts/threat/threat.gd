extends Node
## Autoload: everything that wants the colony dead — the threat flow field, wave
## scheduling, the monster registry, and the storyteller's pressure model.

const MONSTER_SCENE := preload("res://scenes/entities/monster.tscn")

## Hard ceiling on live monsters. A performance safety valve that exists from day
## one deliberately: budget that cannot be spent on bodies is converted into stat
## multipliers on the monsters that DO spawn, so late-run difficulty has somewhere
## to go that does not melt the phone.
const MAX_MONSTERS := 120

## Cells of flow field rebuilt per tick. The whole map is ~16k cells, so this
## spreads a full rebuild over roughly a second and a half.
##
## Tuned DOWN from 2200 after the stress test showed a 9 ms worst-case frame against
## a 1.1 ms average — that spike was a rebuild chunk. Nine milliseconds is survivable
## on a desktop and a visible hitch on a phone, and a flow field that is a second
## stale costs nothing: a monster walking two tiles toward where the keep still is
## has lost nothing at all.
const FIELD_BUDGET := 900

## Waves arrive in pulses rather than one blob — better tension curve, and it
## flattens the spawn-frame cost spike.
const PULSES := 3

var monsters: Array = []
var night_index: int = 0

var threat_field: FlowField = null

## Storyteller state. `pressure` is what the colony is currently under; `target` is
## what the tension curve says it should be. Events are chosen to close the gap —
## that is what makes it a director rather than a random event table.
var pressure: float = 0.0
var target_pressure: float = 0.0

var _spawn_parent: Node = null
var _pending_budget: float = 0.0
var _pulses_left: int = 0
var _pulse_timer: float = 0.0
var _field_dirty: bool = true
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	reset()
	Events.phase_changed.connect(_on_phase_changed)
	Events.building_completed.connect(_on_structures_changed)
	Events.building_destroyed.connect(_on_structures_changed)


func reset() -> void:
	for m in monsters:
		if is_instance_valid(m):
			m.queue_free()
	monsters.clear()
	night_index = 0
	pressure = 0.0
	target_pressure = 0.0
	_pending_budget = 0.0
	_pulses_left = 0
	_pulse_timer = 0.0
	_field_dirty = true
	threat_field = FlowField.new()
	if World.grid.cell_count > 0:
		threat_field.setup(World)
	_rng.seed = World.seed_value ^ 0x7A17


func set_spawn_parent(node: Node) -> void:
	_spawn_parent = node


func step(delta: float) -> void:
	_update_pressure(delta)
	_step_field()
	_step_waves(delta)


# --- Flow field ---------------------------------------------------------------------

## The field is rebuilt when the structures change (a new wall reroutes everything)
## and at the start of each night. Light changes constantly as the Ember moves, and
## rebuilding for that would thrash — a field that is a few seconds stale still
## sends monsters the right way.
func _step_field() -> void:
	if threat_field == null:
		return
	if not threat_field.building and _field_dirty:
		_field_dirty = false
		threat_field.begin(_goal_cells())
	if threat_field.building:
		threat_field.step(FIELD_BUDGET)


func _goal_cells() -> PackedInt32Array:
	var goals := PackedInt32Array()
	# Everything the colony would hate to lose. Multi-source means monsters head
	# for whatever is nearest rather than all funnelling to one point.
	for b in Colony.buildings:
		if is_instance_valid(b) and not b.is_site():
			for cell in b.cells:
				goals.append(cell)
	if goals.is_empty() and World.keep_cell != -1:
		goals.append(World.keep_cell)
	return goals


func mark_field_dirty() -> void:
	_field_dirty = true


func _on_structures_changed(_b: Node) -> void:
	mark_field_dirty()


# --- Waves ------------------------------------------------------------------------------

func _on_phase_changed(phase: int, _duration: float) -> void:
	if phase == Sim.Phase.NIGHT:
		_begin_night()
	elif phase == Sim.Phase.DAWN:
		_end_night()


func _begin_night() -> void:
	night_index += 1
	mark_field_dirty()
	_pending_budget = budget_for_night(night_index)
	_pulses_left = PULSES
	_pulse_timer = 0.0
	Events.wave_incoming.emit(int(_pending_budget), {})
	Events.notice.emit("The Blight stirs — night %d" % night_index, 2)


func _end_night() -> void:
	# Anything still alive at dawn burns off rather than lingering into the work
	# day. Daylight should mean safety, or the day/night rhythm collapses.
	for m in monsters.duplicate():
		if is_instance_valid(m):
			m.die(&"dawn")
	_pending_budget = 0.0
	_pulses_left = 0


func _step_waves(delta: float) -> void:
	if _pulses_left <= 0 or Sim.phase != Sim.Phase.NIGHT:
		return
	_pulse_timer -= delta
	if _pulse_timer > 0.0:
		return
	# Spread the pulses across the first two thirds of the night, so the last third
	# is spent fighting rather than waiting for more arrivals.
	_pulse_timer = (Sim.PHASE_DURATION[Sim.Phase.NIGHT] * 0.66) / float(PULSES)
	_spawn_pulse(_pending_budget / float(_pulses_left))
	_pulses_left -= 1


func _spawn_pulse(budget: float) -> void:
	if _spawn_parent == null:
		return
	var pool := Monsters.eligible(night_index)
	if pool.is_empty():
		return

	var spent := 0.0
	var guard := 0
	while spent < budget and guard < 200:
		guard += 1
		var def := _pick(pool)
		if def == null:
			break
		if at_cap():
			# Out of body budget: bank the rest into stat scaling instead of
			# spawning past the cap. This is the pressure valve that keeps late
			# nights hard without the framerate paying for it.
			_apply_overflow(budget - spent)
			return
		_spawn_one(def, 1.0)
		spent += def.threat_cost
	_pending_budget = maxf(_pending_budget - spent, 0.0)


func _pick(pool: Array[MonsterDef]) -> MonsterDef:
	var total := 0.0
	for def: MonsterDef in pool:
		total += def.weight
	if total <= 0.0:
		return null
	var roll := _rng.randf() * total
	for def: MonsterDef in pool:
		roll -= def.weight
		if roll <= 0.0:
			return def
	return pool[pool.size() - 1]


func _apply_overflow(leftover: float) -> void:
	if leftover <= 0.0 or monsters.is_empty():
		return
	var scale := 1.0 + clampf(leftover / float(monsters.size()) * 0.1, 0.0, 1.5)
	for m in monsters:
		if is_instance_valid(m):
			m.max_health *= scale
			m.health *= scale


func _spawn_one(def: MonsterDef, stat_scale: float) -> void:
	var cell := _spawn_cell()
	if cell == -1:
		return
	var m: Monster = MONSTER_SCENE.instantiate()
	m.setup(def, stat_scale)
	m.position = World.grid.to_world_index(cell)
	_spawn_parent.add_child(m)


## Monsters emerge from the Blight, biased toward the most corrupted map edge.
## Thematic, and it gives purification a tactical payoff beyond a shrinking number:
## clean your western approach and the attacks shift east.
func _spawn_cell() -> int:
	var grid: Grid = World.grid
	for _attempt in 40:
		var cell := -1
		if not World.nest_cells.is_empty() and _rng.randf() < 0.6:
			# Near a nest, which is where the corruption is thickest.
			var nest: int = World.nest_cells[_rng.randi() % World.nest_cells.size()]
			var c := grid.coord(nest)
			cell = grid.index(
				clampi(c.x + _rng.randi_range(-3, 3), 0, grid.width - 1),
				clampi(c.y + _rng.randi_range(-3, 3), 0, grid.height - 1))
		else:
			# Otherwise a random map edge.
			match _rng.randi() % 4:
				0: cell = grid.index(_rng.randi_range(0, grid.width - 1), 1)
				1: cell = grid.index(_rng.randi_range(0, grid.width - 1), grid.height - 2)
				2: cell = grid.index(1, _rng.randi_range(0, grid.height - 1))
				_: cell = grid.index(grid.width - 2, _rng.randi_range(0, grid.height - 1))

		var walkable: int = World.nearest_walkable(cell, 8)
		if walkable != -1 and threat_field != null and threat_field.is_reachable(walkable):
			return walkable
	return -1


# --- Storyteller -------------------------------------------------------------------

## Target tension rises with the day count but is pulled DOWN by how much the player
## is struggling, so a colony on the ropes gets a breather and a thriving one gets
## squeezed.
func _update_pressure(delta: float) -> void:
	var day := float(Sim.day)
	var blight_cover: float = World.blight_field.coverage() if World.blight_field else 0.0
	var pop := float(maxi(Colony.population(), 1))

	target_pressure = 0.35 + day * 0.04 + blight_cover * 0.5
	var strength := clampf(pop / 20.0, 0.0, 1.5)
	target_pressure = clampf(target_pressure * (0.6 + strength * 0.4), 0.0, 2.0)
	pressure = lerpf(pressure, target_pressure, clampf(delta * 0.1, 0.0, 1.0))


## Threat budget for a night, in monster threat-cost points.
func budget_for_night(night: int) -> float:
	var base := 3.0 + pow(1.32, float(night)) * 2.0
	return base * (0.75 + pressure * 0.5) * Meta.threat_dial()


# --- Registry ----------------------------------------------------------------------

func register(monster: Node) -> void:
	monsters.append(monster)
	Events.monster_spawned.emit(monster)


func unregister(monster: Node) -> void:
	monsters.erase(monster)
	Events.monster_died.emit(monster)
	if monsters.is_empty() and Sim.phase == Sim.Phase.NIGHT and _pulses_left <= 0:
		Events.wave_cleared.emit(night_index)
		Events.notice.emit("The night holds.", 0)


func at_cap() -> bool:
	return monsters.size() >= MAX_MONSTERS


func alive_count() -> int:
	return monsters.size()
