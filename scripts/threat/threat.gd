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
var _night_body_cap: int = 0
var _spawned_this_night: int = 0
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
	_growth_progress = 0.0
	# The enemy's settlement is run state. World.generate() lays out fresh nests but does not know
	# about anything that was built around the old ones, so leaving this would carry a previous
	# world's spires into the next one — as threat budget and as occupancy on cells that no longer
	# have anything standing on them.
	World.blight_structures.clear()
	target_pressure = 0.0
	_pending_budget = 0.0
	_pulses_left = 0
	_pulse_timer = 0.0
	_night_body_cap = 0
	_spawned_this_night = 0
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
	elif phase == Sim.Phase.DUSK:
		var forecast := next_night_forecast()
		if int(forecast["risk"]) >= 2:
			Events.notice.emit(tr(&"FORECAST_WARNING"), 2)
	elif phase == Sim.Phase.DAWN:
		_end_night()


func _begin_night() -> void:
	night_index += 1
	mark_field_dirty()
	# The Blight's own settlement pays into the night on top of the curve, so a player who leaves
	# enemy ground uncontested faces a harder night than the difficulty curve says they should —
	# and that extra difficulty is a consequence of a decision rather than a number going up.
	_pending_budget = wave_budget_for_night(night_index)
	_night_body_cap = body_cap_for_night(night_index)
	_spawned_this_night = 0
	_pulses_left = PULSES
	_pulse_timer = 0.0
	Events.wave_incoming.emit(int(_pending_budget), {})
	Events.notice.emit(L10n.t(&"NOTICE_BLIGHT_STIRS", [night_index]), 2)


# --- The Blight builds ----------------------------------------------------------------------
#
# Corruption stops being weather and becomes an opponent here. It spends its nights raising a
# settlement around its nests, so the ground the player has to take back is ground the enemy has
# been developing too — and a nest left alone for a week is a very different problem from a nest
# found on day two.
#
# Grown at DAWN rather than continuously: it should be something the player wakes up to and can see
# has changed, not something that creeps while they are watching a wall.

## Structures raised per dawn, before difficulty scaling. Under one on purpose — the enemy village
## should take a week to become frightening, matching the deliberately slow blight spread.
const GROWTH_PER_DAWN := 0.45

## How far from a live nest the Blight will build. Tight enough that its settlements read as camps
## around their nests rather than as scattered debris.
const GROWTH_RADIUS := 6

## Structures that may stand near one nest, so a single surviving nest cannot tile the map.
const GROWTH_PER_NEST := 4

var _growth_progress: float = 0.0


## Exposed for the save, so a colony that saves every phase change does not lose the Blight's
## accumulated construction credit each time.
func growth_progress() -> float:
	return _growth_progress


func set_growth_progress(value: float) -> void:
	_growth_progress = maxf(value, 0.0)


## One dawn's worth of enemy construction.
func _grow_settlements(night: int) -> void:
	# Scales with the same dial that scales corruption spread, so a tier that makes the Blight
	# advance faster also makes it build faster. One knob, two consequences.
	_growth_progress += GROWTH_PER_DAWN * Difficulties.blight_mult() \
		* Climate.blight_multiplier()
	while _growth_progress >= 1.0:
		_growth_progress -= 1.0
		if not _raise_one(night):
			# Nowhere to build. Do not bank the attempt — otherwise a boxed-in Blight silently
			# accumulates credit and erupts with a dozen structures the moment one cell frees up.
			_growth_progress = 0.0
			return


## Pick a live nest with room left and raise one structure near it. False if nothing could be built.
func _raise_one(night: int) -> bool:
	var def := BlightStructures.roll(night)
	if def == null:
		return false

	var nests := World.live_nest_cells()
	if nests.is_empty():
		return false

	var grid: Grid = World.grid
	# Nests are tried in a random order so the Blight develops all its camps rather than finishing
	# one and starting the next.
	var order := PackedInt32Array(nests)
	for i in range(order.size() - 1, 0, -1):
		var j := randi() % (i + 1)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp

	for nest in order:
		if _structures_near(nest) >= GROWTH_PER_NEST:
			continue
		var c := grid.coord(nest)
		for _attempt in 24:
			var x := c.x + randi_range(-GROWTH_RADIUS, GROWTH_RADIUS)
			var y := c.y + randi_range(-GROWTH_RADIUS, GROWTH_RADIUS)
			if not grid.is_valid(x, y):
				continue
			var cell := grid.index(x, y)
			# Never inside the player's sphere. The Blight builds on ground nobody has claimed, so
			# waking up to a spire in the middle of the village is impossible — encroachment has to
			# be something the player can see coming and go out to meet.
			if World.in_influence(cell):
				continue
			if World.add_blight_structure(cell, def):
				if def.blight_seed > 0:
					World.blight_field.seed_at(cell, def.blight_seed)
				Events.notice.emit(L10n.t(&"NOTICE_BLIGHT_BUILDS",
					[tr(def.display_name)]), 1)
				return true
	return false


func _structures_near(nest: int) -> int:
	# Grid.dist_sq is in CELLS squared, not pixels — the same units GROWTH_RADIUS is written in.
	# Scaling by TILE_SIZE here would have made the radius 16 times too large, so every nest would
	# have counted every structure on the map and the Blight would have stopped building after four.
	var n := 0
	var reach_sq := GROWTH_RADIUS * GROWTH_RADIUS
	for cell in World.blight_structures:
		if World.grid.dist_sq(nest, cell) <= reach_sq:
			n += 1
	return n


func _end_night() -> void:
	# Anything still alive at dawn burns off rather than lingering into the work
	# day. Daylight should mean safety, or the day/night rhythm collapses.
	#
	# Killed with the `dawn` cause specifically so it pays no Faith — see Monster.on_death.
	# Sunrise is not a victory.
	var fled := 0
	for m in monsters.duplicate():
		if is_instance_valid(m):
			fled += 1
			m.die(&"dawn")
	_pending_budget = 0.0
	_pulses_left = 0

	# Tell the player what the night was worth. Without this the kill reward is invisible and
	# might as well not exist.
	var earned := int(Divine.night_faith_earned)
	if earned > 0 and fled == 0:
		Events.notice.emit(L10n.t(&"NOTICE_NIGHT_BROKEN", [earned]), 0)
	elif earned > 0:
		Events.notice.emit(L10n.t(&"NOTICE_DAWN_SCATTERS", [earned]), 0)
	Divine.night_faith_earned = 0.0

	# And the Blight spent the night building. Done at dawn so it is something the player wakes up
	# to and can see has changed, rather than something that creeps while they watch a wall.
	_grow_settlements(night_index)


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
	if _spawned_this_night >= _night_body_cap:
		_pending_budget = 0.0
		return
	# The night shift is what lets a hard tier feel different rather than merely bigger:
	# Forsaken draws from a roster two nights ahead, so the player meets Spitters before
	# they have an answer to them instead of just meeting more Shamblers.
	var pool := Monsters.eligible(night_index + Difficulties.monster_night_shift())
	if pool.is_empty():
		return

	var spent := 0.0
	var guard := 0
	while spent < budget and guard < 200:
		guard += 1
		if _spawned_this_night >= _night_body_cap:
			_pending_budget = 0.0
			return
		var def := _pick(pool)
		if def == null:
			break
		if at_cap():
			# Out of body budget: bank the rest into stat scaling instead of
			# spawning past the cap. This is the pressure valve that keeps late
			# nights hard without the framerate paying for it.
			_apply_overflow(budget - spent)
			return
		if _spawn_one(def, 1.0):
			_spawned_this_night += 1
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


func _spawn_one(def: MonsterDef, stat_scale: float) -> bool:
	var cell := _spawn_cell()
	if cell == -1:
		return false
	if Realm.intercept_threat(cell, def.threat_cost):
		return false
	var m: Monster = MONSTER_SCENE.instantiate()
	# Totems empower the horde. Folded into the same stat_scale the overflow director already uses,
	# rather than a second multiplier on Monster — one place decides how tough a spawn is.
	m.setup(def, stat_scale * World.blight_monster_scale(), _nearest_corrupt_anchor(cell))
	m.position = World.grid.to_world_index(cell)
	_spawn_parent.add_child(m)
	return true


## Monsters emerge from the Blight, biased toward the most corrupted map edge.
## Thematic, and it gives purification a tactical payoff beyond a shrinking number:
## clean your western approach and the attacks shift east.
func _spawn_cell() -> int:
	var grid: Grid = World.grid
	# LIVE nests only. `nest_cells` is the historical site list and never shrinks, so
	# using it here would keep pouring monsters out of a nest the player had already
	# burned out — and destroying one is supposed to visibly shift the attacks
	# elsewhere. This line is the entire payoff for clearing a nest.
	var live_nests := World.live_nest_cells()
	var anchors := PackedInt32Array(live_nests)
	for raw_cell in World.blight_structures:
		anchors.append(int(raw_cell))
	if anchors.is_empty():
		return -1
	for _attempt in 40:
		# Creatures are inhabitants of the corrupted camps, not visitors generated at
		# an arbitrary map edge. Their home anchor is also what keeps their idle
		# wandering local until the colony actually draws their attention.
		var anchor: int = anchors[_rng.randi() % anchors.size()]
		var c := grid.coord(anchor)
		var cell := grid.index(
			clampi(c.x + _rng.randi_range(-3, 3), 0, grid.width - 1),
			clampi(c.y + _rng.randi_range(-3, 3), 0, grid.height - 1))

		var walkable: int = World.nearest_walkable(cell, 8)
		if walkable != -1 and threat_field != null and threat_field.is_reachable(walkable):
			return walkable
	return -1


func _nearest_corrupt_anchor(from: int) -> int:
	var best := from
	var best_dist := 0x7FFFFFFF
	for nest in World.live_nest_cells():
		var dist := World.grid.dist_sq(from, nest)
		if dist < best_dist:
			best_dist = dist
			best = nest
	for raw_cell in World.blight_structures:
		var cell := int(raw_cell)
		var dist := World.grid.dist_sq(from, cell)
		if dist < best_dist:
			best_dist = dist
			best = cell
	return best


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
## Threat budget for a night, in monster threat-cost points.
##
## The original curve was `3 + 1.32^night * 2`, which doubles every two and a half nights:
##
##     night   1     5      10     12     15     20
##     budget  5     10.5   35     62     141    590
##
## Against that, player power was flat or falling — population could not grow, exactly one
## defensive building existed, and Faith was capped. Past night ten no amount of defence
## mattered, which is the single most common complaint about Rise to Ruins and not a thing
## worth reproducing.
##
## The replacement is mostly LINEAR with a gentle exponential tail:
##
##     night   1     5      10     12     15     20
##     budget  8     19      36     44     58     87
##
## Every night is meaningfully harder than the last, and night twenty is a real fight rather
## than a wall — and it now sits inside the 120-body cap instead of overflowing it by 5x into
## invisible stat multipliers.
func budget_for_night(night: int) -> float:
	var base := 4.0 + float(night) * 2.5 + pow(1.18, float(night)) * 1.5
	return base * (0.75 + pressure * 0.5) * Meta.threat_dial() \
		* Difficulties.threat_mult() * Climate.threat_multiplier()


## The first week introduces the enemy rather than using the late-game curve at full
## force. Its share rises with both time and the amount of corrupted development the
## player has allowed to stand. After the first week the ordinary long curve takes over.
func wave_budget_for_night(night: int) -> float:
	var raw := budget_for_night(night) + World.blight_threat_bonus()
	if night > 7:
		return raw
	var time_maturity := clampf(float(night - 1) / 6.0, 0.0, 1.0)
	var coverage := World.blight_field.coverage() if World.blight.size() > 0 else 0.0
	var camp_maturity := clampf(
		float(World.blight_structures.size()) / 8.0
			+ coverage * 3.0,
		0.0, 1.0)
	var background_share := 0.20 + camp_maturity * 0.30
	return raw * lerpf(background_share, 1.0, time_maturity)


## Visible-body caps are intentionally more conservative than the point budget in the
## opening week. The first night is peaceful on Sheltered and exactly one creature on
## every other tier; harder modes shorten the grace period without removing it.
func body_cap_for_night(night: int) -> int:
	if night <= 0:
		return 0
	var opening: Array[int]
	match Difficulties.current_id():
		&"sheltered":
			opening = [0, 1, 1, 2, 2, 3, 4]
		&"besieged":
			opening = [1, 1, 2, 3, 4, 5, 7]
		&"forsaken":
			opening = [1, 2, 3, 4, 5, 7, 9]
		_:
			opening = [1, 1, 2, 2, 3, 4, 5]
	if night <= opening.size():
		return opening[night - 1]
	return MAX_MONSTERS


## An idle creature only becomes an invader when the colony enters its interaction
## radius, or once its difficulty/camp maturity says the background threat has grown
## into a real raid. This keeps the opening nights ominous without sending every spawn
## straight across the map to erase a new settlement.
func monster_should_raid(home_cell: int, current_cell: int) -> bool:
	if _colony_near(current_cell, Monster.INTERACTION_RADIUS) \
			or _colony_near(home_cell, Monster.INTERACTION_RADIUS):
		return true
	var first_raid := 7
	match Difficulties.current_id():
		&"sheltered":
			first_raid = 8
		&"besieged":
			first_raid = 5
		&"forsaken":
			first_raid = 3
	var development_bonus := mini(World.blight_structures.size() / 3, 2)
	return night_index >= maxi(first_raid - development_bonus, 2)


func _colony_near(origin: int, radius: int) -> bool:
	if not World.grid.is_valid_index(origin):
		return false
	if World.in_influence(origin):
		return true
	var reach_sq := radius * radius
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive \
				and World.grid.dist_sq(origin, villager.cell()) <= reach_sq:
			return true
	for building in Colony.buildings:
		if not is_instance_valid(building) or building.is_site():
			continue
		for building_cell in building.cells:
			if World.grid.dist_sq(origin, building_cell) <= reach_sq:
				return true
	return false


## Stable information the player can act on before dusk. This does not consume the wave RNG, so
## opening a tooltip can never change which monsters arrive.
func next_night_forecast() -> Dictionary:
	var next_night := night_index + 1
	var budget := wave_budget_for_night(next_night)
	var pool := Monsters.eligible(next_night + Difficulties.monster_night_shift())
	var names := PackedStringArray()
	var average_cost := 1.0
	if not pool.is_empty():
		var total := 0.0
		for monster: MonsterDef in pool:
			names.append(tr(monster.display_name))
			total += monster.threat_cost
		average_cost = total / float(pool.size())
	var readiness := Colony.defense_readiness()
	var ratio := readiness / maxf(budget, 1.0)
	var risk := 0
	if ratio < 0.72:
		risk = 2
	elif ratio < 1.08:
		risk = 1
	return {
		"night": next_night,
		"budget": ceili(budget),
		"bodies": mini(maxi(roundi(budget / average_cost), 0), body_cap_for_night(next_night)),
		"names": names,
		"readiness": roundi(readiness),
		"risk": risk,
	}


# --- Registry ----------------------------------------------------------------------

func register(monster: Node) -> void:
	monsters.append(monster)
	Events.monster_spawned.emit(monster)


func unregister(monster: Node) -> void:
	monsters.erase(monster)
	Events.monster_died.emit(monster)
	if monsters.is_empty() and Sim.phase == Sim.Phase.NIGHT and _pulses_left <= 0:
		Events.wave_cleared.emit(night_index)
		Events.notice.emit(tr(&"NOTICE_NIGHT_HOLDS"), 0)


func at_cap() -> bool:
	return monsters.size() >= MAX_MONSTERS


func alive_count() -> int:
	return monsters.size()
