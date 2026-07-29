class_name Villager
extends Agent
## A survivor. Gathers, hauls, gets tired, and can be commanded directly.
##
## The state machine stays deliberately small. WHAT a villager is doing lives in
## its job; this enum only tracks HOW — travelling, working, hauling. Every time
## this list grows the AI gets harder to reason about, so new behaviour should
## become a new job or task type rather than a new state.
##
## Needs have no states of their own. They decay in think() and preempt on crossing
## a threshold, which keeps hunger and exhaustion orthogonal to work instead of
## doubling the state count.

enum State { IDLE, SEEKING, WORKING, HAULING, BUILDING, FETCHING, DELIVERING,
	EATING, SLEEPING, RESTING, GUARDING, FLEEING, COMMANDED }

## Combat. Villagers are not soldiers — one alone loses to a Shambler. They win by
## standing together under a tower and inside the light, which is exactly the
## behaviour the night is meant to teach.
const GUARD_DAMAGE := 6.0
const GUARD_RANGE := 1.4                  ## tiles
const GUARD_COOLDOWN := 1.0

const FRAME_DOWN := 0
const FRAME_UP := 2
const FRAME_SIDE := 4

const NEED_MAX := 100.0

## Needs decay slowly relative to the 4-minute day.
##
## Tuned down hard from 0.55/s after a test run watched an entire colony starve to
## death inside a single in-game day with no food source. A famine has to be a
## situation the player can NOTICE and respond to across a couple of days, not a
## wipe that happens between two glances at the screen. At 0.22 a full villager
## takes roughly two days to empty out.
const HUNGER_RATE := 0.22
const REST_RATE := 0.28
const MOOD_DRIFT := 2.5

const HUNGER_URGENT := 35.0
const REST_URGENT := 20.0

## Units of stored food one meal costs, and how much of the need it restores.
const MEAL_COST := 6
const MEAL_RESTORE := 70.0

## Rest recovered per second in a bed versus sleeping rough on the ground. The gap
## is what makes huts worth their wood rather than a decoration.
const REST_IN_BED := 16.0
const REST_ROUGH := 4.0

## Health lost per second at zero food. At 0.35 an empty-bellied villager has most
## of a day left before they die, so a famine gives the player time to react — and
## the first death is a warning rather than the start of a rout.
const STARVE_DAMAGE := 0.35

## How long a direct player command outranks the villager's own priorities. Player
## intent must beat the AI, but not permanently — a villager pinned forever by a
## forgotten tap becomes a mystery bug three hours into a run.
const COMMAND_HOLD := 30.0

## Distance at which a villager counts as "at" its target, squared.
##
## Must clear DIAGONAL adjacency, not just orthogonal. Blocking features (boulders,
## ruin walls) cannot be stood on, so villagers path to a neighbouring cell — and if
## the only free neighbour is diagonal that is 16 * sqrt(2) = 22.6px away, or 512
## squared. The first value here was 400, so quarriers who approached a boulder
## corner-on could never register as having arrived: they released the claim, walked
## off, re-claimed the same rock and looped forever, and the colony mined no stone
## at all while looking perfectly busy.
const REACH_SQ := 700.0

var job: StringName = &""
var state: State = State.IDLE

var food: float = 80.0
var rest: float = 80.0
var mood: float = 70.0

var carry_kind: StringName = &""
var carry_amount: int = 0

var selected: bool = false:
	set(value):
		selected = value
		if _ring:
			_ring.visible = value

var _target_cell: int = -1
var _work_progress: float = 0.0
var _site: Node = null
var _bed: Node = null
var _workplace: Node = null
var _fetch_kind: StringName = &""
var _fetch_from: int = -1

## Materials carried per trip to a building site. Low enough that a distant site
## takes several journeys, which is what makes a forward stockpile worth building.
const CARRY_PER_TRIP := 10
var _command_timer: float = 0.0
var _anim_time: float = 0.0
var _awaiting_path: bool = false
var _tint_timer: float = 0.0

## How often a villager re-samples the light under it for tinting.
const TINT_INTERVAL := 0.2

@onready var _sprite: Sprite2D = $Sprite
@onready var _ring: Sprite2D = $SelectionRing


func _ready() -> void:
	super()
	_ring.visible = false
	Colony.villagers.append(self)
	Events.villager_spawned.emit(self)


func _exit_tree() -> void:
	super()
	_release_target()
	_release_workplace()
	_release_bed()
	Colony.villagers.erase(self)


func set_job(new_job: StringName) -> void:
	if job == new_job:
		return
	job = new_job
	# Abandon whatever the old job had claimed, or the resource stays locked for
	# the rest of the run — and a farm slot held by someone now chopping wood keeps
	# a real farmer out of the field.
	_release_target()
	_release_workplace()
	if state in [State.SEEKING, State.WORKING]:
		stop()
		state = State.IDLE


func is_player_commanded() -> bool:
	return state == State.COMMANDED


# --- Decisions ----------------------------------------------------------------------

func think(delta: float) -> void:
	_decay_needs(delta)

	if state == State.COMMANDED:
		_command_timer -= delta
		if _command_timer <= 0.0:
			state = State.IDLE
		return

	if _awaiting_path:
		return

	# Needs preempt work, but never interrupt themselves. Hunger outranks tiredness:
	# a starving villager who lies down to sleep dies in bed.
	if state not in [State.EATING, State.SLEEPING, State.RESTING]:
		if food <= HUNGER_URGENT and Colony.has_food():
			_begin_eat()
			return
		if rest <= REST_URGENT:
			_begin_sleep()
			return

	# Nightfall IS the recall. Rather than a separate dusk-recall system that
	# re-roles everyone, work simply stops being an option once it is dark: anyone
	# not eating or asleep falls through to guard duty and heads for the light.
	if Sim.is_dark():
		_tick_guard(delta)
		return

	if state == State.GUARDING:
		state = State.IDLE

	match state:
		State.IDLE:
			_seek_work()
		State.SEEKING:
			_tick_seeking()
		State.WORKING:
			_tick_working(delta)
		State.BUILDING:
			_tick_building(delta)
		State.FETCHING:
			_tick_fetching()
		State.DELIVERING:
			_tick_delivering()
		State.HAULING:
			_tick_hauling()
		State.EATING:
			_tick_eating()
		State.SLEEPING:
			_tick_sleeping(delta)
		State.RESTING:
			rest = minf(rest + REST_ROUGH * delta, NEED_MAX)
			if rest >= NEED_MAX * 0.85:
				state = State.IDLE
		_:
			pass


# --- Guard duty --------------------------------------------------------------------------

## At dusk everyone drops what they were carrying-on-with and defends. Villagers
## rally to the brightest defended point they can find rather than scattering to
## meet monsters in the dark, because a villager caught alone outside the light is
## a villager who dies.
func _tick_guard(delta: float) -> void:
	if state != State.GUARDING:
		_release_target()
		_release_workplace()
		stop()
		state = State.GUARDING
		_work_progress = 0.0

	_work_progress = maxf(_work_progress - delta, 0.0)   # doubles as attack cooldown

	var enemy := _nearest_monster(GUARD_RANGE * Grid.TILE_SIZE)
	if enemy != null:
		stop()
		facing = (enemy.position - position).normalized()
		if _work_progress <= 0.0:
			_work_progress = GUARD_COOLDOWN
			enemy.take_damage(GUARD_DAMAGE, self)
		return

	if is_moving():
		return

	var post := _guard_post()
	if post == -1:
		return
	if World.grid.dist_sq(cell(), post) <= 4:
		return
	_request_path(post, State.GUARDING)


func _nearest_monster(reach: float) -> Node:
	var best: Node = null
	var best_dist := reach * reach
	for m in Threat.monsters:
		if not is_instance_valid(m) or not m.alive:
			continue
		var d := position.distance_squared_to(m.position)
		if d <= best_dist:
			best_dist = d
			best = m
	return best


## Where to stand at night: under a watchtower if one exists, otherwise beside the
## Ember, otherwise the keep. All three are light sources, which is the point.
func _guard_post() -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site() or b.def.light_radius < 4:
			continue
		var d := World.grid.dist_sq(cell(), b.anchor)
		if d < best_dist:
			best_dist = d
			best = b.work_cell()
	if best != -1:
		return best
	if Divine.ember_cell != -1:
		return World.nearest_walkable(Divine.ember_cell)
	return World.keep_cell


# --- Eating and sleeping ------------------------------------------------------------------

func _begin_eat() -> void:
	var source := Colony.nearest_food_source(cell())
	if source == -1:
		return
	stop()
	_release_target()
	_target_cell = source
	_request_path(source, State.EATING)


func _tick_eating() -> void:
	if is_moving():
		return
	if _target_cell == -1 or not _within_reach(_target_cell):
		state = State.IDLE
		return
	var taken := Colony.consume_food(MEAL_COST)
	if taken > 0:
		food = minf(food + MEAL_RESTORE * (float(taken) / float(MEAL_COST)), NEED_MAX)
	_target_cell = -1
	state = State.IDLE


## Head for a bed if one is free, otherwise sleep rough where you stand. Refusing to
## rest without a bed would just deadlock a colony that has not built huts yet.
func _begin_sleep() -> void:
	stop()
	_release_target()
	var hut: Node = Colony.nearest_bed(cell())
	if hut == null:
		state = State.RESTING
		return
	if not Colony.claim_bed(hut, self):
		state = State.RESTING
		return
	_bed = hut
	_target_cell = hut.anchor
	_request_path(hut.work_cell(), State.SLEEPING)


func _tick_sleeping(delta: float) -> void:
	if _bed == null or not is_instance_valid(_bed):
		_release_bed()
		state = State.RESTING
		return
	if is_moving():
		return
	if not _within_reach(_bed.work_cell()):
		# Never made it. Sleep where we are rather than looping on an unreachable hut.
		_release_bed()
		state = State.RESTING
		return
	rest = minf(rest + REST_IN_BED * delta, NEED_MAX)
	if rest >= NEED_MAX * 0.95:
		_release_bed()
		state = State.IDLE


func _release_bed() -> void:
	if _bed != null:
		Colony.release_bed(_bed, self)
		_bed = null


## Find something to gather. A villager with no job, or whose job has nothing left
## in reach, drifts instead of freezing — a colony of statues reads as broken far
## more than one that mills about.
func _seek_work() -> void:
	# Holding something with nowhere to put it — a delivery whose site vanished, or
	# a harvest interrupted by nightfall. Get rid of it before taking new work, or
	# the load is carried around forever and quietly lost when the villager dies.
	if carry_amount > 0:
		_begin_haul()
		return

	# Construction outranks gathering. Only one villager can claim a site, so this
	# self-limits: two blueprints pull two builders, not the whole colony. That
	# makes placing a building feel like it gets attention without the economy
	# grinding to a halt every time the player taps the build menu.
	if _try_claim_site():
		return

	var def := Jobs.get_job(job)
	if def == null:
		_wander()
		return

	# Workplace jobs (farming) are worked AT a building rather than harvested from
	# the map, which is what makes them renewable.
	if def.workplace != &"":
		if not _try_claim_workplace(def):
			_wander()
		return

	var target := World.resources.nearest(cell(), def, Colony.is_claimable)
	if target == -1:
		_wander()
		return
	if not Colony.claim(target, self):
		return

	_target_cell = target
	var approach: int = World.nearest_walkable(target)
	if approach == -1:
		_release_target()
		return
	_request_path(approach, State.SEEKING)


func _tick_seeking() -> void:
	# The target can vanish mid-walk: another villager finished it, or the Blight
	# ate it. Re-check rather than arriving at empty ground and standing there.
	if _target_cell == -1 or not Terrain.is_harvestable(World.feature_at(_target_cell)):
		_release_target()
		state = State.IDLE
		return
	if is_moving():
		return
	if _within_reach(_target_cell):
		_work_progress = 0.0
		state = State.WORKING
	else:
		# Path ended short — unreachable. Drop it and pick something else.
		_release_target()
		state = State.IDLE


## Take a slot at the nearest workplace of this job's type, if one is free.
func _try_claim_workplace(def: JobDef) -> bool:
	# Already holding a slot — walk back to it. Without this, a farmer returning
	# from a delivery would try to re-claim a slot it still occupies, be refused,
	# and wander off instead of going back to work.
	if _workplace != null and is_instance_valid(_workplace) and not _workplace.is_site():
		_target_cell = _workplace.anchor
		_request_path(_workplace.work_cell(), State.WORKING)
		return true

	var place: Node = Colony.nearest_workplace(def.workplace, cell())
	if place == null:
		return false
	if not Colony.claim_workplace(place, self):
		return false
	_workplace = place
	_target_cell = place.anchor
	_work_progress = 0.0
	_request_path(place.work_cell(), State.WORKING)
	return true


func _release_workplace() -> void:
	if _workplace != null:
		Colony.release_workplace(_workplace, self)
		_workplace = null


func _tick_working(delta: float) -> void:
	var def := Jobs.get_job(job)
	if def == null:
		_release_target()
		state = State.IDLE
		return

	# Workplace jobs run their own cycle: stand in the farm, work, produce a load,
	# haul it off. The slot is kept across cycles so a farmer does not re-queue a
	# claim every harvest.
	if def.workplace != &"":
		_tick_workplace(def, delta)
		return

	if _target_cell == -1:
		_release_target()
		state = State.IDLE
		return

	var feature := World.feature_at(_target_cell)
	if not Terrain.is_harvestable(feature):
		_release_target()
		state = State.IDLE
		return

	# The Ember's aura speeds up work. This is the whole point of the mechanic:
	# where you put the light decides what actually gets done.
	var rate := def.work_rate * Divine.work_bonus(cell())
	_work_progress += rate * delta

	if _work_progress < Terrain.work_for(feature):
		return

	var yields := Terrain.yield_of(feature)
	for kind: StringName in yields:
		carry_kind = kind
		carry_amount = mini(int(yields[kind]), def.carry_capacity)

	World.clear_feature(_target_cell)
	_release_target()
	_begin_haul()


## Take the nearest unclaimed construction site, if any. Builders are a ROLE rather
## than a slider job — anyone free picks up a hammer — because dedicating a slider
## to building would mean the player has to remember to staff it before anything
## they place ever gets raised.
func _try_claim_site() -> bool:
	if carry_amount > 0:
		return false
	var site: Node = Colony.nearest_build_site(cell())
	if site == null:
		return false
	if not Colony.claim(site.anchor, self):
		return false

	_site = site
	_target_cell = site.anchor

	# Materials before hammers. A site that still needs timber sends the builder to
	# a stockpile first; only once everything is on site does anyone start building.
	if site.needs_materials():
		if not _begin_fetch():
			_release_target()
			return false
		return true

	var approach: int = site.work_cell()
	if approach == -1:
		_release_target()
		return false
	_request_path(approach, State.BUILDING)
	return true


# --- Material hauling ---------------------------------------------------------------------

## Head for a stockpile to collect what the claimed site is short of.
func _begin_fetch() -> bool:
	if _site == null or not is_instance_valid(_site):
		return false
	var kind: StringName = _site.next_needed()
	if kind == &"":
		return false
	var source := Colony.nearest_stockpile(cell())
	if source == -1:
		return false
	_fetch_kind = kind
	_fetch_from = source
	_request_path(source, State.FETCHING)
	return true


func _tick_fetching() -> void:
	if _site == null or not is_instance_valid(_site) or not _site.is_site():
		_release_target()
		state = State.IDLE
		return
	if is_moving():
		return
	if _fetch_from == -1 or not _within_reach(_fetch_from):
		_release_target()
		state = State.IDLE
		return

	var want: int = mini(_site.amount_needed(_fetch_kind), CARRY_PER_TRIP)
	var taken := Colony.withdraw_reserved(_fetch_kind, want)
	if taken <= 0:
		# The stores ran dry — someone ate it, or a storehouse burned. Give up the
		# claim so this builder can do something useful instead of shuttling
		# between an empty shelf and a site forever.
		_release_target()
		state = State.IDLE
		return

	carry_kind = _fetch_kind
	carry_amount = taken
	var approach: int = _site.work_cell()
	if approach == -1:
		_release_target()
		state = State.IDLE
		return
	_request_path(approach, State.DELIVERING)


func _tick_delivering() -> void:
	if _site == null or not is_instance_valid(_site) or not _site.is_site():
		# The site vanished while we were carrying. Put the load back rather than
		# destroying it.
		if carry_amount > 0:
			Colony.add(carry_kind, carry_amount)
			carry_kind = &""
			carry_amount = 0
		_release_target()
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_site.work_cell()):
		_release_target()
		state = State.IDLE
		return

	var accepted: int = _site.deliver(carry_kind, carry_amount)
	carry_amount -= accepted
	if carry_amount <= 0:
		carry_kind = &""

	# Another trip if it is still short, otherwise pick up a hammer.
	if _site.needs_materials():
		if not _begin_fetch():
			_release_target()
			state = State.IDLE
		return

	var approach: int = _site.work_cell()
	if approach == -1:
		_release_target()
		state = State.IDLE
		return
	_request_path(approach, State.BUILDING)


func _tick_building(delta: float) -> void:
	if _site == null or not is_instance_valid(_site) or not _site.is_site():
		_release_target()
		_site = null
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_site.work_cell()):
		# Path ran out short of the site. Drop the claim so someone better placed
		# can take it rather than blocking the build forever.
		_release_target()
		_site = null
		state = State.IDLE
		return

	# The Ember speeds construction just as it speeds gathering, so parking it over
	# the builders is a real way to get a wall up before dusk.
	if _site.add_work(delta * Divine.work_bonus(cell())):
		_release_target()
		_site = null
		state = State.IDLE


func _tick_workplace(def: JobDef, delta: float) -> void:
	if _workplace == null or not is_instance_valid(_workplace) or _workplace.is_site():
		_release_workplace()
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_workplace.work_cell()):
		_release_workplace()
		state = State.IDLE
		return

	# Crops grow no faster in the dark than anything else does — the Ember's aura
	# applies here exactly as it does to felling trees.
	_work_progress += def.work_rate * Divine.work_bonus(cell()) * delta
	if _work_progress < def.cycle_work:
		return

	_work_progress = 0.0
	for kind: StringName in def.cycle_yield:
		carry_kind = kind
		carry_amount = mini(int(def.cycle_yield[kind]), def.carry_capacity)
	_begin_haul()


func _begin_haul() -> void:
	if carry_amount <= 0:
		state = State.IDLE
		return
	var drop := Colony.nearest_stockpile(cell())
	if drop == -1:
		state = State.IDLE
		return
	_target_cell = drop
	_request_path(drop, State.HAULING)


func _tick_hauling() -> void:
	if is_moving():
		return
	if _target_cell != -1 and _within_reach(_target_cell):
		if carry_amount > 0:
			Colony.add(carry_kind, carry_amount)
			carry_kind = &""
			carry_amount = 0
		_target_cell = -1
		state = State.IDLE
	else:
		# Could not reach the stockpile. Try again next think rather than dropping
		# the load — a villager stuck holding wood is recoverable, lost wood is not.
		_begin_haul()


func _enter_rest() -> void:
	stop()
	_release_target()
	state = State.RESTING


func _decay_needs(delta: float) -> void:
	food = maxf(food - HUNGER_RATE * delta, 0.0)
	rest = maxf(rest - REST_RATE * delta, 0.0)

	# Empty stomach and nothing to eat: this is the only way a villager dies of
	# neglect, and it is what gives the food economy actual stakes rather than
	# being a bar that goes down.
	if food <= 0.0:
		take_damage(STARVE_DAMAGE * delta)
		if not alive:
			return

	# Mood drifts toward a target set by how well the villager is looked after and
	# by whether the Ember is on them — which makes Ember placement a morale
	# decision as well as a productivity one.
	var target := 50.0
	if food < HUNGER_URGENT:
		target -= 30.0
	if rest < REST_URGENT:
		target -= 20.0
	if Divine.is_within_ember(cell()):
		target += 35.0
	if World.is_blighted(cell()):
		target -= 25.0
	mood = move_toward(mood, clampf(target, 0.0, NEED_MAX), MOOD_DRIFT * delta)


func _wander() -> void:
	if randf() > 0.2:
		return
	var grid: Grid = World.grid
	var here := grid.coord(cell())
	var target := Vector2i(here.x + randi_range(-4, 4), here.y + randi_range(-4, 4))
	if not grid.is_valid_v(target):
		return
	var dest := grid.index_v(target)
	if World.is_walkable(dest):
		_request_path(dest, State.IDLE)


# --- Movement -------------------------------------------------------------------------

func _within_reach(target: int) -> bool:
	return position.distance_squared_to(World.grid.to_world_index(target)) <= REACH_SQ


func _request_path(dest: int, next_state: State) -> void:
	_awaiting_path = true
	World.paths.request(cell(), dest, func(path: PackedInt32Array) -> void:
		_awaiting_path = false
		if not alive:
			return
		if path.is_empty():
			# Unreachable. Give up this target so we do not re-request it forever.
			if next_state == State.SEEKING:
				_release_target()
			state = State.IDLE
			return
		follow_path(path)
		state = next_state
	)


func _release_target() -> void:
	if _target_cell != -1:
		Colony.release(_target_cell, self)
	Colony.release_all_by(self)
	_target_cell = -1
	_site = null
	_fetch_kind = &""
	_fetch_from = -1


## Direct player order. Solved immediately rather than queued — a tap that takes
## two ticks to respond feels broken even though the same delay is invisible
## elsewhere.
func command_to(dest: int) -> void:
	var target: int = World.nearest_walkable(dest)
	if target == -1:
		return
	var path := World.paths.solve(cell(), target)
	if path.is_empty():
		return
	_release_target()
	follow_path(path)
	state = State.COMMANDED
	_command_timer = COMMAND_HOLD


func on_path_finished() -> void:
	if state == State.COMMANDED:
		_command_timer = minf(_command_timer, 1.0)
	think_urgent = true


func on_death(cause: StringName) -> void:
	_release_target()
	_release_workplace()
	_release_bed()
	Events.villager_died.emit(self, cause)


# --- Presentation ------------------------------------------------------------------------

func _process(delta: float) -> void:
	super(delta)
	_animate(delta)


## Facing and walk cycle are derived from actual movement rather than tracked as
## state, so they can never disagree with where the villager is really going.
##
## Every write here is guarded by a change check. Assigning `frame` or `modulate`
## marks the canvas item dirty even when the value is identical, and with ~170
## agents on screen those redundant writes measured as a real slice of the frame.
func _animate(delta: float) -> void:
	var moving := is_moving()
	if moving:
		_anim_time += delta * 6.0
	else:
		_anim_time = 0.0

	var step := 1 if (moving and int(_anim_time) % 2 == 1) else 0

	var want_frame: int
	var want_flip := false
	if absf(facing.x) > absf(facing.y):
		want_frame = FRAME_SIDE + step
		want_flip = facing.x < 0.0
	else:
		want_frame = (FRAME_DOWN if facing.y >= 0.0 else FRAME_UP) + step

	if _sprite.frame != want_frame:
		_sprite.frame = want_frame
	if _sprite.flip_h != want_flip:
		_sprite.flip_h = want_flip

	# Light only needs sampling a few times a second — it changes as the Ember
	# drifts, not per frame, and cell() plus a grid lookup 170 times every frame is
	# pure waste.
	_tint_timer -= delta
	if _tint_timer > 0.0:
		return
	_tint_timer = TINT_INTERVAL

	var lit := float(World.light_at(cell())) / 255.0
	var tint := Color.WHITE.lerp(Color(0.75, 0.78, 0.9), 1.0 - lit)
	if carry_amount > 0:
		# Carrying something tints them slightly warm, so a glance at the colony
		# tells you whether goods are actually flowing.
		tint = tint.lerp(Color(1.15, 1.0, 0.8), 0.35)
	if not _sprite.modulate.is_equal_approx(tint):
		_sprite.modulate = tint


func describe() -> String:
	var names := ["idle", "seeking", "working", "hauling", "building",
		"fetching", "delivering", "eating", "sleeping", "resting",
		"guarding", "fleeing", "commanded"]
	var carry := " carrying %d %s" % [carry_amount, carry_kind] if carry_amount > 0 else ""
	return "%s (%s)%s" % [names[state], job if job != &"" else "unassigned", carry]
