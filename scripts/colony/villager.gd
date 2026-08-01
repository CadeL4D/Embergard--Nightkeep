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
	EATING, SLEEPING, RESTING, GUARDING, FLEEING, COMMANDED, DRINKING }

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
## Mood points per second toward the target.
##
## Was 2.5, which crossed the entire 0-100 range in forty seconds. Because the target is a step
## function — it jumps the instant a villager crosses the hunger or thirst threshold — mood
## chased every one of those steps and the colony average visibly jittered. Morale is supposed
## to be the slowest-moving number in the game: something you steer over days, not seconds.
##
## At 0.5 a full swing takes most of a day cycle, so the average reads as a trend.
const MOOD_DRIFT := 0.5

## Mood falls at this fraction of the rise rate.
##
## Deliberately asymmetric. A colony that is being looked after should hold its morale through
## the ordinary rhythm of people getting hungry and going to eat; only a sustained failure should
## grind it down. Symmetric drift meant every routine trip to the water dragged the average with
## it, so the number fell faster than the colony was actually deteriorating.
const MOOD_FALL_SCALE := 0.5

# --- Mood contributions -------------------------------------------------------------------
# Baseline is CONTENT, not mediocre: a fed, watered, housed villager with nothing wrong should
# sit comfortably above the middle, so a dip means something. Penalties for transient states
# (walking to water, walking to a meal) are small — those are the system working, not failing.
# The heavy penalties are for structural failures the player has to fix: no roof, standing in
# Blight.
const MOOD_BASE := 62.0
const MOOD_HUNGRY := -20.0
const MOOD_THIRSTY := -12.0
const MOOD_TIRED := -12.0
const MOOD_ROUGH := -18.0
const MOOD_EMBER := 25.0
const MOOD_BLIGHTED := -18.0

## Thirst runs faster than hunger and is answered by WALKING somewhere rather than by
## spending a stored resource. That asymmetry is the point: food is a logistics problem you
## solve with farms and stockpiles, water is a geography problem you solve by choosing where
## to settle and by sinking a well inside your walls.
const THIRST_RATE := 0.30

const HUNGER_URGENT := 35.0
const REST_URGENT := 20.0
const THIRST_URGENT := 40.0
## Thirst bad enough to break guard duty for. Set above zero so the run is made before the
## damage starts, not after.
const THIRST_DESPERATE := 12.0

## Drinking is quick and free — the cost was the walk.
const DRINK_RESTORE := 85.0

## Health lost per second with an empty canteen. Harsher than starving: you can last days
## without food and not without water, and it makes losing water access an emergency rather
## than a slow decline.
const DEHYDRATE_DAMAGE := 0.6

## Units of stored food one meal costs, and how much of the need it restores.
const MEAL_COST := 6
const MEAL_RESTORE := 70.0

## Rest recovered per second in a bed versus sleeping rough on the ground.
##
## Retuned hard. At 16.0 a full night's sleep took 4.7 SECONDS, and sleeping rough took 19 —
## so a 24-wood hut bought about fifteen seconds per villager per five minutes, a roughly 5%
## productivity gain. Rest was not a decision and huts were very nearly decoration, whatever
## the old comment here claimed.
##
## At 6.0 a bed is worth about forty seconds of work per villager per cycle, and rough sleep
## is slow enough to actually hurt. Combined with ROUGH_REST_CAP below, huts are now the
## colony's growth lever as well — beds gate migration (see Colony.beds_free), so this is the
## number that decides how fast the settlement can grow at all.
const REST_IN_BED := 6.0
const REST_ROUGH := 1.2

## Sleeping on the ground never gets a villager past this. A roof is the only way to be
## properly rested, which is what stops a colony of six people and no huts running forever.
const ROUGH_REST_CAP := 60.0

## Mood penalty applied while sleeping rough, so the cost of no housing shows up in Faith
## generation and migration appeal rather than only in walking speed.
const ROUGH_MOOD_PENALTY := 18.0

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
var water: float = 80.0
var rest: float = 80.0
var mood: float = 70.0

var carry_kind: StringName = &""
var carry_amount: int = 0
## Additional output stacks waiting to be hauled. A single feature/workshop may
## produce more than one resource, but the visible villager still carries one
## stack at a time.
var pending_loads: Array[Dictionary] = []

## Temporary divine boosts, from a Rally or anything else with a BUFF power. Held as two plain
## multipliers and one timer rather than as a list of effects: there are two things a buff can do
## and a general effect system would be several hundred lines paying for flexibility nothing needs.
var boost_speed: float = 0.0
var boost_damage: float = 0.0
var boost_time: float = 0.0
## Lightweight timed conditions. The value is seconds remaining; effects are evaluated in the
## existing 10 Hz simulation and therefore remain identical in Battery mode.
var statuses: Dictionary = {}
var profile: VillagerRecord = VillagerRecord.new()

var selected: bool = false:
	set(value):
		selected = value
		if _ring:
			_ring.visible = value
			_apply_selection_style()

var _target_cell: int = -1
var _work_progress: float = 0.0
var _site: Node = null
var _bed: Node = null
var _workplace: Node = null
var _patient: Villager = null
var _fetch_kind: StringName = &""
var _fetch_from: int = -1
var _fetch_for_workplace: bool = false

## Materials carried per trip to a building site. Low enough that a distant site
## takes several journeys, which is what makes a forward stockpile worth building.
const CARRY_PER_TRIP := 10
var _command_timer: float = 0.0
var _anim_time: float = 0.0
var _awaiting_path: bool = false
var _tint_timer: float = 0.0
var _presentation_accum: float = 0.0

## How often a villager re-samples the light under it for tinting.
const TINT_INTERVAL := 0.2

@onready var _sprite: Sprite2D = $Sprite
@onready var _ring: Sprite2D = $SelectionRing
@onready var _carry: Sprite2D = $Carry


func _ready() -> void:
	super()
	if profile.stable_id.is_empty():
		profile = _make_profile(Colony.villagers.size(), false)
	statuses = profile.statuses.duplicate(true)
	_ring.visible = false
	_apply_selection_style()
	# Frame count read from the resource list rather than baked into the scene, so
	# adding a resource kind cannot silently leave the icon strip a frame short and
	# mislabel every haul after it.
	# The authored strip currently has six generic material glyphs. New resources
	# deliberately reuse those silhouettes until their final item art lands.
	_carry.hframes = 6
	_carry.visible = false
	Colony.villagers.append(self)
	Events.villager_spawned.emit(self)
	call_deferred("refresh_equipment")


static func _make_profile(ordinal: int, born: bool) -> VillagerRecord:
	const GIVEN := ["Alda", "Bram", "Cerys", "Dain", "Elowen", "Fenn", "Greta", "Hale",
		"Iris", "Jory", "Kest", "Luma", "Mara", "Noll", "Orin", "Pella"]
	const FAMILY := ["Ash", "Briar", "Cinder", "Dale", "Ember", "Flint", "Glen", "Hearth"]
	const TRAITS: Array[StringName] = [&"steady", &"swift", &"stout", &"kind", &"keen",
		&"grim", &"hopeful", &"careful"]
	var record := VillagerRecord.new()
	var region := String(Realm.awake_id)
	var seed_value := int(World.seed_value) * 65537 + ordinal * 8191 + region.hash()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	record.stable_id = "%s-%08x-%03d" % [region, absi(seed_value), ordinal]
	record.display_name = "%s %s" % [GIVEN[rng.randi_range(0, GIVEN.size() - 1)],
		FAMILY[rng.randi_range(0, FAMILY.size() - 1)]]
	record.age_days = 0 if born else rng.randi_range(record.adult_age_days, 42)
	record.max_age_days = rng.randi_range(72, 105)
	record.strength = rng.randf_range(0.86, 1.14)
	record.agility = rng.randf_range(0.86, 1.14)
	record.wisdom = rng.randf_range(0.86, 1.14)
	record.traits.append(TRAITS[rng.randi_range(0, TRAITS.size() - 1)])
	if rng.randf() < 0.35:
		var second := TRAITS[rng.randi_range(0, TRAITS.size() - 1)]
		if second not in record.traits:
			record.traits.append(second)
	return record


func is_adult() -> bool:
	return profile.age_days >= profile.adult_age_days


func profile_dict() -> Dictionary:
	profile.statuses = statuses.duplicate(true)
	return profile.to_dict()


func restore_profile(data: Dictionary) -> void:
	profile = VillagerRecord.from_dict(data)
	statuses = profile.statuses.duplicate(true)


func _exit_tree() -> void:
	super()
	_release_target()
	_release_workplace()
	_release_bed()
	_release_patient()
	Colony.villagers.erase(self)


func set_job(new_job: StringName) -> void:
	if not is_adult() and not new_job.is_empty():
		return
	if job == new_job:
		return
	job = new_job
	# Abandon whatever the old job had claimed, or the resource stays locked for
	# the rest of the run — and a farm slot held by someone now chopping wood keeps
	# a real farmer out of the field.
	_release_target()
	_release_workplace()
	_release_patient()
	if state in [State.SEEKING, State.WORKING]:
		stop()
		state = State.IDLE
	refresh_equipment()


func set_equipment_policy(policy: StringName) -> void:
	if policy not in [&"best_available", &"preserve_durability", &"none"]:
		return
	profile.equipment_policy = policy
	refresh_equipment()


func refresh_equipment() -> void:
	if profile == null or not is_adult():
		return
	if profile.equipment_policy == &"none":
		_drop_equipment()
		return
	var job_def := Jobs.get_job(job)
	for slot: StringName in [&"tool", &"weapon", &"armor", &"offhand", &"charm"]:
		if profile.equipment.has(slot):
			continue
		var item := Colony.take_equipment(job_def, slot, profile.equipment_policy)
		if item != null:
			profile.equipment[slot] = item.to_dict()


func _drop_equipment() -> void:
	for row in profile.equipment.values():
		if typeof(row) == TYPE_DICTIONARY:
			Colony.store_item(ItemRecord.from_dict(row), cell())
	profile.equipment.clear()


func _wear_equipment(slot: StringName, amount: int = 1) -> void:
	if not profile.equipment.has(slot):
		return
	var row: Dictionary = profile.equipment[slot]
	row["durability"] = maxi(int(row.get("durability", 0)) - amount, 0)
	if int(row["durability"]) <= 0:
		profile.equipment.erase(slot)
	else:
		profile.equipment[slot] = row


func _work_multiplier() -> float:
	var multiplier := (profile.strength + profile.wisdom) * 0.5
	var row: Dictionary = profile.equipment.get(&"tool", {})
	var item_def := Items.get_item(StringName(row.get("def", &"")))
	if item_def != null:
		multiplier *= 1.0 + float(item_def.modifiers.get(&"work_speed", 0.0))
	return multiplier


func _guard_damage() -> float:
	var damage := GUARD_DAMAGE * profile.strength
	var row: Dictionary = profile.equipment.get(&"weapon", {})
	var item_def := Items.get_item(StringName(row.get("def", &"")))
	if item_def != null:
		for value in item_def.damage.values():
			damage += float(value)
	return damage


func damage_resistances() -> Dictionary:
	var out: Dictionary = {}
	for raw_row in profile.equipment.values():
		if typeof(raw_row) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = raw_row
		var item_def := Items.get_item(StringName(row.get("def", &"")))
		if item_def == null:
			continue
		for kind in item_def.resistances:
			out[kind] = clampf(float(out.get(kind, 0.0)) \
				+ float(item_def.resistances[kind]), -0.75, 0.85)
	return out


func is_player_commanded() -> bool:
	return state == State.COMMANDED


## Take a divine boost. Refreshes rather than stacks — the answer to a breach is casting Rally
## once, not learning that four overlapping casts make a villager unkillable.
func apply_boost(speed: float, damage: float, duration: float) -> void:
	boost_speed = maxf(boost_speed, speed)
	boost_damage = maxf(boost_damage, damage)
	boost_time = maxf(boost_time, duration)


## Boosted villagers move faster over whatever they are standing on.
##
## Layered on top of the road multiplier rather than replacing it, via the hook Agent exposes for
## exactly this. A rallied villager on a paved road gets both, which is the correct answer to
## "monsters are through the gate and my warriors are on the far side of the village".
func _surface_speed(cell_index: int) -> float:
	var status_scale := 0.72 if statuses.has(&"slowed") else 1.0
	return World.speed_at(cell_index) * (1.0 + boost_speed) * status_scale * profile.agility


# --- Decisions ----------------------------------------------------------------------

func think(delta: float) -> void:
	_tick_statuses(delta)
	if not alive:
		return
	_decay_needs(delta)

	if state == State.COMMANDED:
		_command_timer -= delta
		if _command_timer <= 0.0:
			state = State.IDLE
		return

	if _awaiting_path:
		return

	# A shelter order is the one colony-wide command allowed to preempt ordinary needs and work.
	# Warriors remain on the line; everyone else drops their claim and returns to the Village Center.
	if DefenseControl.should_shelter(self):
		_tick_shelter()
		return
	elif state == State.FLEEING:
		state = State.IDLE

	# Needs preempt work, but never interrupt themselves. The order is thirst, hunger, rest:
	# dehydration kills fastest, and a villager who lies down to sleep while starving or
	# parched dies in bed.
	if state not in [State.EATING, State.DRINKING, State.SLEEPING, State.RESTING]:
		# Water is the one need that can be a long way from home, and walking to a shore in
		# the dark is how a villager dies. So thirst is only allowed to pull someone off
		# guard duty when it has become genuinely lethal — otherwise they hold the line and
		# drink at first light. Food does not need this guard: meals come from a stockpile,
		# which is by definition inside the colony.
		if water <= THIRST_URGENT and (not Sim.is_dark() or water <= THIRST_DESPERATE):
			_begin_drink()
			return
		if food <= HUNGER_URGENT and Colony.has_food():
			_begin_eat()
			return
		if rest <= REST_URGENT:
			_begin_sleep()
			return

	# Nightfall is a recall for the people it needs to be, and no longer for everybody.
	#
	# The old rule sent every villager to guard duty at dusk, which meant 31% of the game was a
	# colony standing in a circle watching. Now:
	#
	#   * WARRIORS always defend. That is the job.
	#   * Everyone else keeps working IF the ground they are on is lit. Light already gates the
	#     blight and burns monsters; this makes it gate the working day too, which turns Ember
	#     placement into an economic decision after dark instead of a purely defensive one.
	#   * Anyone caught in the dark falls back to the light, because a villager alone outside it
	#     is a villager who dies.
	if Sim.is_dark() and not _works_after_dark():
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
		State.DRINKING:
			_tick_drinking()
		State.SLEEPING:
			_tick_sleeping(delta)
		State.RESTING:
			# Capped below full: a villager with no bed tops out tired, gets back up, and
			# keeps working at a penalty rather than lying on the ground indefinitely
			# waiting for a recovery that will never arrive.
			rest = minf(rest + REST_ROUGH * delta, ROUGH_REST_CAP)
			if rest >= ROUGH_REST_CAP - 0.5:
				state = State.IDLE
		_:
			pass


func apply_status(status: StringName, duration: float) -> void:
	if status.is_empty() or duration <= 0.0:
		return
	statuses[status] = maxf(float(statuses.get(status, 0.0)), duration)
	think_urgent = true


func _tick_statuses(delta: float) -> void:
	if statuses.is_empty():
		return
	for status in statuses.keys():
		var remaining := float(statuses[status]) - delta
		if remaining <= 0.0:
			statuses.erase(status)
			continue
		statuses[status] = remaining
		match StringName(status):
			&"infected":
				take_damage(0.22 * delta, null, &"blight")
				mood = maxf(mood - 0.16 * delta, 0.0)
			&"burning":
				take_damage(0.55 * delta, null, &"fire")
			&"poisoned":
				take_damage(0.35 * delta, null, &"elemental")


## Light level a villager needs under them to keep working after dark.
##
## Below the Ember's own strength on purpose: a torch-lit watchtower should be enough to work by,
## not just the Ember itself, or the colony can only ever have one productive night shift.
const NIGHT_WORK_LIGHT := 110

## Whether this villager carries on working once it is dark.
##
## Warriors never do — they fight. Everyone else needs light where they stand, and needs a monster
## not to be breathing down their neck: a woodcutter who keeps chopping while a Shambler closes on
## them is not brave, they are a bug.
func _works_after_dark() -> bool:
	var def := Jobs.get_job(job)
	if def != null and def.defends:
		return false
	if World.light_at(cell()) < NIGHT_WORK_LIGHT:
		return false
	return _nearest_monster(GUARD_RANGE * 3.0 * Grid.TILE_SIZE) == null


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
			enemy.take_damage(_guard_damage() * (1.0 + boost_damage), self)
			_wear_equipment(&"weapon")
		return

	if is_moving():
		return

	var post := _guard_post()
	if post == -1:
		return
	if World.grid.dist_sq(cell(), post) <= 4:
		return
	_request_path(post, State.GUARDING)


## Cell of the villager currently in the most danger, for a warrior to run to.
##
## Measured as "a colonist with a monster near them", nearest to this warrior. Falls back to the
## nearest monster when nobody is being menaced yet, so warriors intercept rather than waiting for
## someone to be attacked first.
func _nearest_threatened() -> int:
	const DANGER := 5.0                       # tiles between a villager and a monster to count
	var danger_sq := (DANGER * Grid.TILE_SIZE) * (DANGER * Grid.TILE_SIZE)

	var best := -1
	var best_dist := INF
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive or v == self:
			continue
		# Autonomous warriors protect the claimed settlement. A painted guard zone
		# outside it is the player's explicit instruction to patrol farther afield.
		if not World.in_influence(v.cell()) and not DefenseControl.is_guard_cell(v.cell()):
			continue
		var near := false
		for m in Threat.hostiles:
			if is_instance_valid(m) and m.alive \
					and m.position.distance_squared_to(v.position) <= danger_sq:
				near = true
				break
		if not near:
			continue
		var d := position.distance_squared_to(v.position)
		if d < best_dist:
			best_dist = d
			best = v.cell()
	if best != -1:
		return best

	var hunt := _nearest_defended_monster()
	return World.nearest_walkable(hunt.cell()) if hunt != null else -1


func _nearest_monster(reach: float) -> Node:
	var best: Node = null
	var best_dist := reach * reach
	for m in Threat.hostiles:
		if not is_instance_valid(m) or not m.alive:
			continue
		var d := position.distance_squared_to(m.position)
		if d <= best_dist:
			best_dist = d
			best = m
	return best


func _nearest_defended_monster() -> Node:
	var best: Node = null
	var best_dist := INF
	for monster in Threat.hostiles:
		if not is_instance_valid(monster) or not monster.alive:
			continue
		var monster_cell: int = monster.cell()
		if not World.in_influence(monster_cell) \
				and not DefenseControl.is_guard_cell(monster_cell):
			continue
		var distance := position.distance_squared_to(monster.position)
		if distance < best_dist:
			best_dist = distance
			best = monster
	return best


## Where to stand at night: under a watchtower if one exists, otherwise beside the
## Ember, otherwise the keep. All three are light sources, which is the point.
func _guard_post() -> int:
	# A warrior goes to the trouble; everyone else goes to the light.
	#
	# This is the difference between the two roles. Untrained villagers survive the night by
	# huddling somewhere bright, which is what the light mechanic teaches. Warriors exist to break
	# that rule — they walk toward whoever is being attacked, which is the only way a colony spread
	# across several work sites can be defended at all.
	var def := Jobs.get_job(job)
	if def != null and def.defends:
		var threatened := _nearest_threatened()
		if threatened != -1:
			return threatened
		var patrol := DefenseControl.nearest_guard_cell(cell())
		if patrol != -1:
			return patrol

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


# --- Drinking -----------------------------------------------------------------------------

## Head for the nearest well or shore.
##
## Unlike eating, this cannot be refused for lack of stock — there is no water resource to run
## out of. It can only fail because there is nowhere to drink, which on a normal map means the
## player has walled themselves off from the water without sinking a well.
func _begin_drink() -> void:
	var source := Colony.nearest_water_source(cell())
	if source == -1:
		return
	stop()
	_release_target()
	_target_cell = source
	_request_path(source, State.DRINKING)


func _tick_drinking() -> void:
	if is_moving():
		return
	if _target_cell == -1 or not _within_reach(_target_cell):
		state = State.IDLE
		return
	water = minf(water + DRINK_RESTORE, NEED_MAX)
	_target_cell = -1
	state = State.IDLE


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
	var taken := Colony.consume_food_at(_target_cell, MEAL_COST)
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
	if not pending_loads.is_empty():
		_take_next_pending_load()
		_begin_haul()
		return
	if not is_adult():
		_wander()
		return

	# Mid-teardown. Go back to the building rather than looking for fresh work, because salvage
	# comes out one armful at a time and each trip ends here.
	#
	# Reached through `_site` rather than through nearest_build_site because the walk back is not a
	# new decision — this worker already owns that job, and asking the colony for the nearest site
	# again could hand them a different one halfway through pulling a wall down.
	if _site != null and is_instance_valid(_site) and _site.is_demolishing():
		_request_path(_site.work_cell(), State.BUILDING)
		return

	var def := Jobs.get_job(job)
	if def != null and def.heals:
		if not _try_claim_patient(def):
			_wander()
		return
	if def != null and def.repairs:
		if not _try_claim_repair():
			_wander()
		return

	# Construction outranks gathering. Only one villager can claim a site, so this
	# self-limits: two blueprints pull two builders, not the whole colony. That
	# makes placing a building feel like it gets attention without the economy
	# grinding to a halt every time the player taps the build menu.
	if _try_claim_site():
		return

	if def == null:
		_wander()
		return

	# Workplace jobs (farming) are worked AT a building rather than harvested from
	# the map, which is what makes them renewable.
	if def.workplace != &"" and def.target_features.is_empty():
		if not _try_claim_workplace(def):
			_wander()
		return
	if def.workplace != &"" and not _claim_field_workplace(def):
		_wander()
		return

	var target := World.resources.nearest(cell(), def,
		_can_work_in_catchment if def.catchment_radius > 0 else _can_work_on)
	if target == -1:
		if def.catchment_radius > 0:
			_release_workplace()
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


## Is this feature both unclaimed AND actually reachable?
##
## Two conditions, not one. Trees block movement now, so the middle of a wood has no cell a villager
## could stand on — and a claim on an unreachable tree is a villager that walks off, fails to arrive,
## drops the claim and picks the same tree again forever. See World.has_walkable_neighbour.
func _can_work_on(target: int) -> bool:
	return DefenseControl.allows_work(target) and Colony.is_claimable(target) \
		and World.has_walkable_neighbour(target)


func _can_work_in_catchment(target: int) -> bool:
	var def := Jobs.get_job(job)
	if def == null or _workplace == null or not is_instance_valid(_workplace):
		return false
	return World.grid.dist_sq(_workplace.centre_cell(), target) \
		<= def.catchment_radius * def.catchment_radius and _can_work_on(target)


func _claim_field_workplace(def: JobDef) -> bool:
	if _workplace != null and is_instance_valid(_workplace) and not _workplace.is_site():
		return true
	var place := Colony.nearest_workplace(def.workplace, cell())
	if place == null or not Colony.claim_workplace(place, self):
		return false
	_workplace = place
	return true


func _tick_seeking() -> void:
	# The target can vanish mid-walk: another villager finished it, or the Blight
	# ate it. Re-check rather than arriving at empty ground and standing there.
	if _target_cell == -1 or not Terrain.is_harvestable(World.feature_at(_target_cell)):
		_release_target()
		state = State.IDLE
		return
	var def := Jobs.get_job(job)
	if def == null or not DefenseControl.gathering_is_designated(def.id, _target_cell):
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
	if def.heals:
		_tick_healing(def, delta)
		return

	# Workplace jobs run their own cycle: stand in the farm, work, produce a load,
	# haul it off. The slot is kept across cycles so a farmer does not re-queue a
	# claim every harvest.
	if def.workplace != &"" and def.target_features.is_empty():
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
	if not DefenseControl.gathering_is_designated(def.id, _target_cell):
		_release_target()
		state = State.IDLE
		return

	# The Ember's aura speeds up work. This is the whole point of the mechanic:
	# where you put the light decides what actually gets done.
	var rate := def.work_rate * Divine.work_bonus(cell()) * _work_multiplier()
	_work_progress += rate * delta

	if _work_progress < Terrain.work_for(feature):
		return

	_queue_output(Terrain.yield_of(feature), def.carry_capacity,
		Climate.gather_multiplier(feature))
	_take_next_pending_load()

	World.clear_feature(_target_cell)
	_wear_equipment(&"tool")
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


func _try_claim_repair() -> bool:
	if carry_amount > 0:
		return false
	var target: Node = Colony.nearest_repair_target(cell())
	if target == null or not Colony.claim(target.anchor, self):
		return false
	_site = target
	_target_cell = target.anchor
	var approach: int = target.work_cell()
	if approach == -1:
		_release_target()
		_site = null
		return false
	_request_path(approach, State.BUILDING)
	return true


func _try_claim_patient(def: JobDef) -> bool:
	if _workplace == null or not is_instance_valid(_workplace):
		var clinic := Colony.nearest_workplace(def.workplace, cell())
		if clinic == null or not Colony.claim_workplace(clinic, self):
			return false
		_workplace = clinic
	var patient := Colony.nearest_patient(cell(), self)
	if patient == null or not Colony.claim_patient(patient, self):
		return false
	_patient = patient
	_target_cell = patient.cell()
	_work_progress = 0.0
	_request_path(_target_cell, State.WORKING)
	return true


func _tick_healing(def: JobDef, delta: float) -> void:
	if _patient == null or not is_instance_valid(_patient) or not _patient.alive \
			or not _patient.needs_treatment():
		_release_patient()
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_patient.cell()):
		_target_cell = _patient.cell()
		_request_path(_target_cell, State.WORKING)
		return
	_work_progress += def.work_rate * profile.wisdom * delta
	if _work_progress < def.cycle_work:
		return
	_work_progress = 0.0
	if not def.cycle_cost.is_empty() \
			and not Colony.spend_near(_workplace.centre_cell(), def.cycle_cost):
		return
	_patient.receive_treatment()
	if not _patient.needs_treatment():
		_release_patient()
		state = State.IDLE


func _release_patient() -> void:
	if _patient != null:
		Colony.release_patient(_patient, self)
	_patient = null


func needs_treatment() -> bool:
	return health < max_health - 0.01 or not profile.wounds.is_empty() \
		or statuses.has(&"infected") or statuses.has(&"poisoned") \
		or statuses.has(&"blight_sickness")


func receive_treatment() -> void:
	health = minf(health + 30.0, max_health)
	for status: StringName in [&"infected", &"poisoned", &"blight_sickness"]:
		if statuses.erase(status):
			break
	if not profile.wounds.is_empty():
		profile.wounds.erase(profile.wounds.keys()[0])
	Events.villager_treated.emit(self)


func on_damaged(amount: float, _source: Node) -> void:
	_wear_equipment(&"armor")
	Events.villager_injured.emit(self, amount)
	if amount >= 12.0:
		var severity := clampf(amount / maxf(max_health, 1.0), 0.1, 1.0)
		profile.wounds[&"trauma"] = maxf(float(profile.wounds.get(&"trauma", 0.0)), severity)


# --- Material hauling ---------------------------------------------------------------------

## Head for a stockpile to collect what the claimed site is short of.
func _begin_fetch() -> bool:
	if _site == null or not is_instance_valid(_site):
		return false
	var kind: StringName = _site.next_needed()
	if kind == &"":
		return false
	var source := Colony.nearest_storage_source(cell(), kind)
	if source == -1:
		return false
	_fetch_kind = kind
	_fetch_from = source
	_fetch_for_workplace = false
	_request_path(source, State.FETCHING)
	return true


func _begin_workplace_fetch(def: JobDef) -> bool:
	if _workplace == null or not is_instance_valid(_workplace):
		return false
	var kind: StringName = _workplace.next_input_needed(def.cycle_cost)
	if kind.is_empty():
		return false
	var source := Colony.nearest_storage_source(cell(), kind)
	if source == -1:
		return false
	_fetch_kind = kind
	_fetch_from = source
	_fetch_for_workplace = true
	_request_path(source, State.FETCHING)
	return true


func _tick_fetching() -> void:
	if _fetch_for_workplace:
		_tick_workplace_fetching()
		return
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
	var taken := Colony.withdraw_reserved_at(_fetch_from, _fetch_kind, want)
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


func _tick_workplace_fetching() -> void:
	if _workplace == null or not is_instance_valid(_workplace) or _workplace.is_site():
		_release_target()
		state = State.IDLE
		return
	if is_moving():
		return
	if _fetch_from == -1 or not _within_reach(_fetch_from):
		_release_target()
		state = State.IDLE
		return
	var def := Jobs.get_job(job)
	if def == null:
		_release_target()
		state = State.IDLE
		return
	var want := mini(_workplace.input_amount_needed(_fetch_kind, def.cycle_cost), CARRY_PER_TRIP)
	var taken := Colony.withdraw_at(_fetch_from, _fetch_kind, want)
	if taken <= 0:
		_release_target()
		state = State.IDLE
		return
	carry_kind = _fetch_kind
	carry_amount = taken
	_request_path(_workplace.work_cell(), State.DELIVERING)


func _tick_delivering() -> void:
	if _fetch_for_workplace:
		_tick_workplace_delivering()
		return
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


func _tick_workplace_delivering() -> void:
	if _workplace == null or not is_instance_valid(_workplace) or _workplace.is_site():
		if carry_amount > 0:
			Colony.add(carry_kind, carry_amount)
		carry_kind = &""
		carry_amount = 0
		_fetch_for_workplace = false
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_workplace.work_cell()):
		_request_path(_workplace.work_cell(), State.DELIVERING)
		return
	var deposited := Colony.deposit_building_input(_workplace, carry_kind, carry_amount)
	carry_amount -= deposited
	if carry_amount > 0:
		Colony.add(carry_kind, carry_amount)
	carry_kind = &""
	carry_amount = 0
	_fetch_for_workplace = false
	_fetch_from = -1
	_fetch_kind = &""
	state = State.WORKING


func _tick_building(delta: float) -> void:
	var job_def := Jobs.get_job(job)
	var repairing: bool = job_def != null and job_def.repairs \
		and _site != null and is_instance_valid(_site) and _site.needs_repair()
	if _site == null or not is_instance_valid(_site) or (not _site.is_site() and not repairing):
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

	if _site.is_demolishing():
		_tick_demolish(delta)
		return
	if repairing:
		if _site.add_repair_work(delta * Divine.work_bonus(cell()) * Doctrines.modifier(&"repair")):
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


## Construction in reverse: prise the frame apart, then carry the salvage off load by load.
##
## Runs inside _tick_building rather than in a state of its own — the villager is standing at a
## site applying effort and then hauling, which is what BUILDING and HAULING already mean. This
## class's header is explicit that new behaviour should not become a new state, and demolition is
## the case that proves the rule: it reuses add_work, _begin_haul and the haul return path whole.
func _tick_demolish(delta: float) -> void:
	# The Ember helps here too. Clearing a burnt-out district under the light is one of the few
	# things worth doing with it during the day.
	if not _site.add_work(delta * Divine.work_bonus(cell())):
		return

	# Explicitly typed, not inferred. `_site` is a plain Node, so anything it returns arrives as a
	# Variant and the parser refuses to infer from it — and `load` would have shadowed the global
	# load() function into the bargain.
	var armful: Array = _site.take_salvage_load(CARRY_PER_TRIP)
	if armful.is_empty():
		# Frame down, nothing left to carry. Only NOW does the building actually go away, so a
		# demolition that is abandoned partway leaves a visible half-torn ruin rather than
		# silently vanishing.
		_site.destroy()
		_release_target()
		_site = null
		state = State.IDLE
		return

	carry_kind = armful[0]
	carry_amount = armful[1]
	_begin_haul()


func _tick_workplace(def: JobDef, delta: float) -> void:
	if _workplace == null or not is_instance_valid(_workplace) or _workplace.is_site():
		_release_workplace()
		state = State.IDLE
		return
	if not _workplace.production_is_available(def):
		_work_progress = 0.0
		_release_workplace()
		state = State.IDLE
		return
	if is_moving():
		return
	if not _within_reach(_workplace.work_cell()):
		_release_workplace()
		state = State.IDLE
		return

	# Processing inputs are hauled into this exact workshop before effort starts.
	# The buffer is committed stock, so a second workshop cannot spend the same boards.
	if not def.cycle_cost.is_empty() and not _workplace.next_input_needed(def.cycle_cost).is_empty():
		_work_progress = 0.0
		_begin_workplace_fetch(def)
		return

	# Crops grow no faster in the dark than anything else does — the Ember's aura
	# applies here exactly as it does to felling trees.
	_work_progress += def.work_rate * Divine.work_bonus(cell()) * _work_multiplier() * delta
	if _work_progress < def.cycle_work:
		return

	# Inputs are taken HERE, on completion. Consuming them at the start would quietly destroy
	# materials whenever a worker was interrupted by nightfall or hunger, and reserving them
	# would need a second reservation ledger beside the one construction already keeps.
	if not Colony.consume_building_inputs(_workplace, def.cycle_cost):
		_work_progress = 0.0
		return

	_work_progress = 0.0
	_wear_equipment(&"tool")

	# A scribe's output is an object, not a stock. It is handed to the Temple rather than carried to
	# a stockpile, so this is the skip-the-haul branch — and it is the same branch any future
	# non-haulable output will use.
	#
	# The priest COUNT is read at completion rather than remembered, because it is what shifts the
	# tier odds and the player may have staffed or emptied the Temple mid-cycle.
	if def.scribes:
		Divine.priest_cycle(Colony.headcount_of(job))
		Events.production_completed.emit(_workplace, &"tome", 1)
		return
	if not def.item_yield.is_empty():
		Colony.create_item(def.item_yield, _workplace.centre_cell())
		Events.production_completed.emit(_workplace, def.item_yield, 1)
		return

	for kind: StringName in def.cycle_yield:
		var produced := maxi(roundi(float(def.cycle_yield[kind]) \
			* Climate.production_multiplier(def, kind)), 1)
		var stored := Colony.deposit_building_output(_workplace, kind, produced)
		if stored > 0:
			Events.production_completed.emit(_workplace, kind, stored)
		var taken := Colony.withdraw_building_output(_workplace, kind, stored)
		if taken > 0:
			_queue_output({kind: taken}, def.carry_capacity, 1.0)
	_take_next_pending_load()
	_begin_haul()


func _queue_output(yields: Dictionary, capacity: int, multiplier: float) -> void:
	var safe_capacity := maxi(capacity, 1)
	for kind: StringName in yields:
		var remaining := maxi(roundi(float(yields[kind]) * multiplier), 1)
		while remaining > 0:
			var amount := mini(remaining, safe_capacity)
			pending_loads.append({"kind": kind, "amount": amount})
			remaining -= amount


func _take_next_pending_load() -> bool:
	if carry_amount > 0 or pending_loads.is_empty():
		return carry_amount > 0
	var row: Dictionary = pending_loads.pop_front()
	carry_kind = StringName(row.get("kind", &""))
	carry_amount = int(row.get("amount", 0))
	return carry_amount > 0


func _begin_haul() -> void:
	if carry_amount <= 0:
		state = State.IDLE
		return
	var drop := Colony.nearest_storage_destination(cell(), carry_kind)
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
			var deposited := Colony.deposit_at(_target_cell, carry_kind, carry_amount)
			carry_amount -= deposited
			if carry_amount > 0:
				_begin_haul()
				return
			carry_kind = &""
		_target_cell = -1
		if _take_next_pending_load():
			_begin_haul()
		else:
			state = State.IDLE
	else:
		# Could not reach the stockpile. Try again next think rather than dropping
		# the load — a villager stuck holding wood is recoverable, lost wood is not.
		_begin_haul()


func _enter_rest() -> void:
	stop()
	_release_target()
	state = State.RESTING


## Fall back to the Hearth or highest-tier Village Center. This state deliberately uses normal
## pathfinding—the order protects civilians from danger, it does not teleport them through walls.
func _tick_shelter() -> void:
	var destination := DefenseControl.shelter_cell()
	if destination == -1:
		return
	if state != State.FLEEING:
		_release_target()
		_release_workplace()
		stop()
		state = State.FLEEING
	if is_moving():
		return
	if World.grid.dist_sq(cell(), destination) <= 4:
		return
	_request_path(destination, State.FLEEING)


func _decay_needs(delta: float) -> void:
	# Difficulty scales the decay, not the thresholds. Moving the thresholds would change
	# WHEN a villager decides to eat relative to how full they are, which quietly rewrites
	# the whole preemption model; scaling the rate just makes the same clock run faster.
	# Divine boosts expire here rather than in _process: they are decisions, not animation, and
	# think() is where every other timed decision on this class already lives.
	if boost_time > 0.0:
		boost_time -= delta
		if boost_time <= 0.0:
			boost_time = 0.0
			boost_speed = 0.0
			boost_damage = 0.0

	var wear := Difficulties.needs_mult()
	food = maxf(food - HUNGER_RATE * wear * delta, 0.0)
	water = maxf(water - THIRST_RATE * wear * Climate.thirst_multiplier() * delta, 0.0)
	rest = maxf(rest - REST_RATE * wear * delta, 0.0)

	# Empty stomach and nothing to eat: this is the only way a villager dies of
	# neglect, and it is what gives the food economy actual stakes rather than
	# being a bar that goes down.
	if food <= 0.0:
		var starvation := STARVE_DAMAGE * delta
		if health <= starvation:
			die(&"starvation")
		else:
			take_damage(starvation)
		if not alive:
			return
	if water <= 0.0:
		var dehydration := DEHYDRATE_DAMAGE * delta
		if health <= dehydration:
			die(&"dehydration")
		else:
			take_damage(dehydration)
		if not alive:
			return

	# Mood drifts toward a target set by how well the villager is looked after and
	# by whether the Ember is on them — which makes Ember placement a morale
	# decision as well as a productivity one.
	var target := MOOD_BASE
	if food < HUNGER_URGENT:
		target += MOOD_HUNGRY
	if water < THIRST_URGENT:
		target += MOOD_THIRSTY
	if rest < REST_URGENT:
		target += MOOD_TIRED
	if state == State.RESTING:
		# Sleeping in the dirt. Pushes the cost of no housing into Faith generation and
		# migration appeal, not just into a slower walk.
		target += MOOD_ROUGH
	if Divine.is_within_ember(cell()):
		target += MOOD_EMBER
	if World.is_blighted(cell()):
		target += MOOD_BLIGHTED
	# The weight of an austere library. A tome bought with the colony's cheer partly eats its own
	# Faith output, since mood is what generates Faith in the first place — which is the point of
	# giving some tomes a real cost instead of pure upside.
	target -= Divine.tome_mood_penalty()
	target += Climate.mood_offset()

	target = clampf(target, 0.0, NEED_MAX)
	var rate := MOOD_DRIFT if target > mood else MOOD_DRIFT * MOOD_FALL_SCALE
	mood = move_toward(mood, target, rate * delta)


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
	# Stand still while the solve is queued. A villager that keeps walking its OLD
	# route — a wander, most often, since _seek_work runs while one is still in
	# progress — ends up somewhere the new path never passes through, and then has to
	# walk back to the cell it asked from. Half a second of standing reads as thinking;
	# retracing your steps reads as broken.
	stop()
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
		var def := Jobs.get_job(job)
		var is_guard := def != null and def.defends
		if not DefenseControl.path_allowed(path, is_guard, next_state == State.FLEEING):
			if next_state == State.SEEKING:
				_release_target()
			state = State.IDLE
			return
		follow_path(path)
		state = next_state
	)


func _release_target() -> void:
	_release_patient()
	if _target_cell != -1:
		Colony.release(_target_cell, self)
	Colony.release_all_by(self)
	_target_cell = -1
	_site = null
	_fetch_kind = &""
	_fetch_from = -1
	_fetch_for_workplace = false


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
	var def := Jobs.get_job(job)
	var is_guard := def != null and def.defends
	if not DefenseControl.path_allowed(path, is_guard):
		Events.notice.emit(tr(&"CONTROL_PATH_BLOCKED"), 1)
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
	spawn_death_ghost(_sprite)
	_release_target()
	_release_workplace()
	_release_bed()
	profile.statuses = statuses.duplicate(true)
	profile.memorial = {
		"day": Sim.day,
		"cause": cause,
		"job": job,
		"age_days": profile.age_days,
	}
	Colony.release_household_partner(self)
	_drop_equipment()
	Colony.record_memorial(profile.to_dict())
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
	_presentation_accum += delta
	var interval := Accessibility.animation_interval()
	if interval > 0.0 and _presentation_accum < interval:
		return
	var visual_delta := _presentation_accum
	_presentation_accum = 0.0
	var moving := is_moving()
	if moving:
		_anim_time += visual_delta * (9.0 if state == State.FLEEING else 6.0)
	else:
		_anim_time += visual_delta * 3.5

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

	# Small transform poses make work readable with the existing compact sprite sheet.
	# They are presentation-only and update at 20 Hz in Battery mode.
	var phase := sin(_anim_time * PI)
	var want_position := Vector2(0.0, -absf(phase) * (1.0 if moving else 0.0))
	var want_rotation := 0.0
	var want_scale := Vector2.ONE
	var job_def := Jobs.get_job(job)
	var healing: bool = state == State.WORKING and job_def != null and job_def.heals
	var repairing: bool = state == State.BUILDING and _site != null \
		and is_instance_valid(_site) and _site.needs_repair()
	if state == State.GUARDING:
		want_rotation = phase * 0.09
		want_scale = Vector2(1.0 + maxf(phase, 0.0) * 0.08, 1.0)
	elif state == State.FLEEING:
		want_rotation = -facing.x * 0.1
	elif healing:
		want_scale = Vector2.ONE * (1.0 + absf(phase) * 0.05)
	elif repairing:
		want_rotation = phase * 0.13
		want_position.y -= absf(phase) * 1.5
	elif state in [State.WORKING, State.BUILDING]:
		want_rotation = phase * 0.08
		want_position.y -= absf(phase)
	elif carry_amount > 0:
		want_scale = Vector2(0.98, 1.03)
	if not _sprite.position.is_equal_approx(want_position):
		_sprite.position = want_position
	if not is_equal_approx(_sprite.rotation, want_rotation):
		_sprite.rotation = want_rotation
	if not _sprite.scale.is_equal_approx(want_scale):
		_sprite.scale = want_scale
	var carry_position := Vector2(0.0, -19.0 - (absf(phase) if moving else 0.0))
	if not _carry.position.is_equal_approx(carry_position):
		_carry.position = carry_position
	_apply_selection_style()

	# Light only needs sampling a few times a second — it changes as the Ember
	# drifts, not per frame, and cell() plus a grid lookup 170 times every frame is
	# pure waste.
	_tint_timer -= visual_delta
	if _tint_timer > 0.0:
		return
	_tint_timer = TINT_INTERVAL

	var lit := float(World.light_at(cell())) / 255.0
	var tint := Color.WHITE.lerp(Color(0.75, 0.78, 0.9), 1.0 - lit)
	if healing:
		tint = tint.lerp(Color(0.62, 1.0, 0.9), 0.22)
	if hurt_visual_remaining > 0.0:
		tint = tint.lerp(Color(2.0, 0.45, 0.35), 0.65)
	if not _sprite.modulate.is_equal_approx(tint):
		_sprite.modulate = tint

	# What they are carrying, held over their head. This replaces a warm tint that
	# used to stand in for "is holding something" — the tint said goods were moving
	# but never WHAT, so a stalled stone supply was indistinguishable from a healthy
	# one at a glance. Lit like the villager, or a night colony grows a row of
	# floating icons brighter than the people holding them.
	var showing := carry_amount > 0
	if _carry.visible != showing:
		_carry.visible = showing
	if not showing:
		return
	var icon := posmod(Colony.KINDS.find(carry_kind), 6)
	if icon >= 0 and _carry.frame != icon:
		_carry.frame = icon
	if not _carry.modulate.is_equal_approx(tint):
		_carry.modulate = tint


func _apply_selection_style() -> void:
	if _ring == null:
		return
	var high := Accessibility.high_visibility_targets
	var wanted_scale := Vector2.ONE * (1.4 if high else 1.0)
	var wanted_color := Color(1.0, 0.96, 0.18, 1.0) if high \
		else Color(1.0, 0.847059, 0.501961, 0.85)
	if not _ring.scale.is_equal_approx(wanted_scale):
		_ring.scale = wanted_scale
	if not _ring.modulate.is_equal_approx(wanted_color):
		_ring.modulate = wanted_color


func describe() -> String:
	var names: Array[StringName] = [&"STATE_IDLE", &"STATE_SEEKING", &"STATE_WORKING",
		&"STATE_HAULING", &"STATE_BUILDING", &"STATE_FETCHING", &"STATE_DELIVERING",
		&"STATE_EATING", &"STATE_SLEEPING", &"STATE_RESTING", &"STATE_GUARDING",
		&"STATE_FLEEING", &"STATE_COMMANDED", &"STATE_DRINKING"]
	var carry := L10n.t(&"STATE_CARRYING",
		[carry_amount, L10n.resource(carry_kind)]) if carry_amount > 0 else ""
	var role := tr(&"STATE_UNASSIGNED")
	if job != &"":
		var def := Jobs.get_job(job)
		role = tr(def.display_name) if def != null else String(job)
	return L10n.t(&"STATE_DESCRIBE", [tr(names[state]), role, carry])
