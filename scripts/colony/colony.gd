extends Node
## Autoload: the survivors' side of the world — stockpiles, the villager roster,
## the job quotas the player sets on the Job Board, and the reservation ledger that
## stops two people walking to the same tree.

## Canonical resource kinds. StringName rather than an enum so content .tres files
## can name costs directly without depending on script-side enum ordering.
##
## Ordered raw → processed → made, which is the order the HUD groups them in.
##
## Water is deliberately absent: it is a place villagers walk to, not a stock. Making it a
## resource would collapse both the site-picker decision and the Well's reason to exist.
const KINDS: Array[StringName] = [
	# Raw — pulled out of the map.
	&"wood", &"stone", &"food", &"ore", &"emberglass", &"herbs", &"dirty_water",
	&"crystal", &"iron_ore", &"gold_ore", &"trash", &"ghost_dust",
	# Processed — a workplace turned raw material into something better. See JobDef.cycle_cost.
	&"boards", &"cut_stone", &"ingots", &"rations", &"medicine", &"clean_water",
	&"crylithium", &"iron_ingot", &"gold_ingot",
	# Made — the gate to the upper half of the building list.
	&"tools", &"arrows", &"bolts", &"stone_balls", &"empty_vessel", &"filled_vessel",
]

## Groups for the resource readout, so eleven numbers do not arrive as one undifferentiated
## strip. Keys are locale keys; values are the kinds in display order.
const KIND_GROUPS: Array = [
	[&"GROUP_RAW", [&"wood", &"stone", &"food", &"ore", &"emberglass", &"herbs",
		&"dirty_water", &"crystal", &"iron_ore", &"gold_ore", &"trash", &"ghost_dust"]],
	[&"GROUP_PROCESSED", [&"boards", &"cut_stone", &"ingots", &"rations", &"medicine",
		&"clean_water", &"crylithium", &"iron_ingot", &"gold_ingot"]],
	[&"GROUP_MADE", [&"tools", &"arrows", &"bolts", &"stone_balls", &"empty_vessel",
		&"filled_vessel"]],
]

## How often the labour reconciler runs, in seconds. Quotas are a coarse control;
## re-deriving assignments every tick would thrash villagers between jobs faster
## than they could walk anywhere.
const REBALANCE_INTERVAL := 3.0

const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")
const GOLEM_SCENE := preload("res://scenes/entities/golem.tscn")
const ANIMAL_SCENE := preload("res://scenes/entities/animal.tscn")
## Mobile divine constructs share one hard budget because they use the same path queue as people.
const GOLEM_CAP := 12

# --- Migration ---------------------------------------------------------------------------
#
# The single most important system in the game, because without it every quantity in a run
# only ever goes down: the colony began with six survivors and could never gain another, so
# a night that cost two people was a permanent wound and the difficulty curve had nothing to
# climb against. Huts gave beds to a population that could only shrink, and the farm's worker
# slots were a ceiling nobody would ever reach.
#
# Modelled on Rise to Ruins: arrivals are pulled by SPARE HOUSING, UNMET WORK and a FOOD
# SURPLUS. That is what turns huts and farms from upkeep into growth levers.
#
# An accumulator rather than a dice roll per dawn. Progress toward the next arrival can be
# shown as a number that visibly responds to building a hut, which is legible in a way that
# "you got unlucky again" never is.

## Two ways the colony grows, and they work differently on purpose.
##
## BIRTHS are internal and conditional. There is a minimum standard of living — a spare bed, a
## couple of days of food, water, and people who are not miserable — and while it is met the
## colony builds toward a new child. Fail any of it and progress STALLS where it is rather than
## resetting, so a bad night costs time and not the whole investment.
##
## MIGRATION is external and unconditional. Survivors are out there whatever the colony's larder
## looks like, and they turn up at the edge asking to be let in. Accepting them when there is no
## room is allowed — it is the decision. That inverts the old design, where a struggling colony
## simply never saw anyone; now it sees them and has to say no.
##
## No countdown is exposed for either. A visible ETA turned growth into a timer being watched,
## and the numbers feeding it move constantly, so the readout jittered and drew the eye to a
## figure that was never meaningful.

## Birth progress per second with every factor neutral, sized so a comfortable colony adds
## roughly one person per day cycle.
const BIRTH_BASE_RATE := 0.0024
## The minimum standard. Below any of these, births stall.
const BIRTH_MIN_FOOD_DAYS := 2.0
const BIRTH_MIN_MOOD := 45.0

## Kept under the old name because the HUD and the smoke test both talk about a food minimum;
## births use the stricter BIRTH_MIN_FOOD_DAYS.
const MIGRATION_MIN_FOOD_DAYS := 1.0

## Seconds between bands of survivors finding the colony, before jitter. Roughly two day cycles,
## so an arrival is an event rather than a routine.
const MIGRANT_INTERVAL := 900.0
## How long a band waits at the edge before giving up and moving on.
const MIGRANT_PATIENCE := 45.0
## Mood cost of turning desperate people away. Small, but it is not free.
const REFUSAL_MOOD_COST := 6.0

## Progress toward the next birth, 0-1 against a randomised target.
var migration_progress: float = 0.0
## Randomised so arrivals never feel metronomic.
var _birth_target: float = 1.0

## Survivors currently waiting at the edge for an answer. Zero means nobody is asking.
var pending_migrants: int = 0
var _migrant_patience: float = 0.0
var _migrant_timer: float = 0.0
var _migrant_cell: int = -1

## Where arriving survivors are added. Set by the run, mirroring Threat.set_spawn_parent —
## Colony owns the roster, so it owns creating members of it.
var _spawn_parent: Node = null

var stock: Dictionary = {}                ## StringName -> int
## Goods with no valid container remain physically at the Hearth. This is an
## unbounded recovery buffer, not a normal destination for hauling.
var overflow: Dictionary = {}             ## StringName -> int
var overflow_spoilage_progress: Dictionary = {}
var overflow_items: Array[Dictionary] = []

## Physical stacks lying on the map, keyed by stable id.
##
## The colony's first POSITIONAL store. Everything else here is an aggregate — stock is a number,
## overflow is a number parked at the Hearth — so a load that could not be delivered either
## teleported into the stores or ceased to exist. Neither reads as a place where something
## happened. A porter's body should leave the wood he was carrying on the tile he fell on, and
## somebody should have to go and get it.
##
## Kept as records rather than nodes: resources, expiring Essence and future loot share one batched
## draw call without paying for a scene object per mote or log pile.
var loose_drops: Dictionary = {}          ## int -> LooseDrop
var _next_loose_drop_id: int = 1
var _loose_drop_timer: float = 0.0
const LOOSE_DROP_STEP := 0.5
const ESSENCE_KIND: StringName = &"essence"
const ESSENCE_COLLECT_RADIUS := 1
var _next_item_serial: int = 1

## Materials promised to blueprints but not yet carried out to them. Placing a
## blueprint reserves its cost immediately, so the wood is visibly gone from your
## spendable total the moment you commit — otherwise you could queue five huts
## against one hut's worth of timber and only discover it when nothing got built.
var reserved: Dictionary = {}             ## StringName -> int
var buffered: Dictionary = {}             ## workshop inputs committed but not consumed
## Stock promised to a Worker for a physical delivery. This is separate from blueprint
## reservations: construction releases its promise at pickup, while a supply promise stays live
## until the load reaches the destination so another porter cannot duplicate it in transit.
var supply_reserved: Dictionary = {}       ## StringName -> int still reserved on shelves
var supply_requests: Array[SupplyRequest] = []
var _supply_reservations_by_cell: Dictionary = {}   ## cell -> {kind: amount}
var _supply_claims: Dictionary = {}        ## request id -> Agent carrier
var _next_supply_request_id: int = 1
var _supply_requests_dirty: bool = true
var _supply_refresh_tick: int = -1
var quotas: Dictionary = {}               ## job id -> headcount the player wants
var villagers: Array = []
var golems: Array = []
var animals: Array = []
var buildings: Array = []
var memorials: Array = []

## Cells where gathered goods can be dropped off. The Hearth seeds this at run
## start; real stockpile buildings append to it in M4.
var stockpiles: PackedInt32Array = PackedInt32Array()
## centre cell -> completed Building. Kept beside stockpiles so inventory lookup
## never scans all 160 buildings during hauling and needs checks.
var _storage_by_cell: Dictionary = {}

## cell -> villager currently working it. The single most visible "the AI is dumb"
## bug in this genre is five people converging on one tree, and this is what
## prevents it.
var _claims: Dictionary = {}
var _patient_claims: Dictionary = {}       ## patient iid -> medic

## Occupancy of the two kinds of building slot, keyed by building instance id.
## Kept as explicit ledgers rather than counted by scanning every villager, because
## these are queried on every hungry or tired villager's think.
var _bed_users: Dictionary = {}       ## building iid -> Array[villager]
var _work_users: Dictionary = {}      ## building iid -> Array[villager]

var _rebalance_timer: float = 0.0

# --- Measured food flow --------------------------------------------------------------------
#
# Demand can be computed exactly (see food_demand_per_second). SUPPLY cannot: it arrives from
# farms, foraging, berries, ruins and demolition salvage, in discrete hauls, at whatever moment
# a villager happens to reach a stockpile. Declaring it would mean every one of those paths
# remembering to report itself, and the first one that forgot would make the readout lie.
#
# So supply is measured instead — sample the larder on a fixed interval and difference it.
# Combined with the exact demand figure, that yields the true net.

## Sampled slowly and over a long window on purpose.
##
## The first version sampled every 2s over 20s, and a single 8-food haul landing inside one
## sample read as 4 food/second — which the readout then reported as "+7440/day". Hauls are
## lumpy by nature: nothing arrives for twenty seconds and then three people show up at once.
## Ninety seconds of window is long enough that individual deliveries stop being visible.
const FLOW_SAMPLE_INTERVAL := 3.0
const FLOW_SAMPLES := 30

## Fraction of the cycle a farm worker is actually producing — daylight only, minus the walk to
## a stockpile and back with each load. Used to turn a farm's paper rate into a real one.
const FARM_DUTY_CYCLE := 0.45

var _flow_timer: float = 0.0
var _food_history: PackedFloat32Array = PackedFloat32Array()
var _last_food: int = 0


func _ready() -> void:
	if not Events.day_advanced.is_connected(_on_day_advanced):
		Events.day_advanced.connect(_on_day_advanced)
	reset()


func reset() -> void:
	stock.clear()
	overflow.clear()
	overflow_spoilage_progress.clear()
	overflow_items.clear()
	_next_item_serial = 1
	reserved.clear()
	buffered.clear()
	supply_reserved.clear()
	for k in KINDS:
		stock[k] = 0
		overflow[k] = 0
		overflow_spoilage_progress[k] = 0.0
		reserved[k] = 0
		buffered[k] = 0
		supply_reserved[k] = 0
	supply_requests.clear()
	_supply_reservations_by_cell.clear()
	_supply_claims.clear()
	_next_supply_request_id = 1
	_supply_requests_dirty = true
	_supply_refresh_tick = -1
	quotas.clear()
	villagers.clear()
	golems.clear()
	animals.clear()
	buildings.clear()
	memorials.clear()
	stockpiles = PackedInt32Array()
	loose_drops.clear()
	_next_loose_drop_id = 1
	_loose_drop_timer = 0.0
	_storage_by_cell.clear()
	_claims.clear()
	_patient_claims.clear()
	_bed_users.clear()
	_work_users.clear()
	_rebalance_timer = 0.0
	migration_progress = 0.0
	_flow_timer = 0.0
	_food_history = PackedFloat32Array()
	_last_food = 0
	pending_migrants = 0
	_migrant_patience = 0.0
	_migrant_cell = -1
	_roll_birth_target()
	_reset_migrant_timer()

	# Default staffing so a fresh run is doing something before the player opens
	# the board. An empty board on day one reads as a broken game, not a blank slate.
	#
	# Read from the job itself rather than inferred from whether it has a workplace. That rule was
	# fine with four jobs and wrong with nine: it asked for ten people out of six, so every row on
	# the board opened amber and the colony reported unmet work it had no way to staff. Every
	# workplace job still defaults to zero — there is no farm, sawmill or temple on day one — but now
	# that is stated in the content rather than deduced.
	for job: JobDef in Jobs.all():
		quotas[job.id] = job.default_quota


func set_spawn_parent(node: Node) -> void:
	_spawn_parent = node


func step(delta: float) -> void:
	_rebalance_timer -= delta
	if _rebalance_timer <= 0.0:
		_rebalance_timer = REBALANCE_INTERVAL
		rebalance()
	_step_migration(delta)
	_step_flow(delta)
	_step_loose_drops(delta)


# --- Measured flow --------------------------------------------------------------------------

func _step_flow(delta: float) -> void:
	_flow_timer -= delta
	if _flow_timer > 0.0:
		return
	_flow_timer = FLOW_SAMPLE_INTERVAL
	var now := amount_of(&"food")
	_food_history.append(float(now - _last_food) / FLOW_SAMPLE_INTERVAL)
	_last_food = now
	while _food_history.size() > FLOW_SAMPLES:
		_food_history.remove_at(0)


## Observed change in the larder, food per second, averaged over the sample window.
func food_measured_net() -> float:
	if _food_history.is_empty():
		return 0.0
	var total := 0.0
	for v in _food_history:
		total += v
	# A fixed denominator makes the estimate settle gradually during a new run.
	# Dividing by the number of samples so far made the first berry delivery look
	# like a huge economy swing, then jump again on every early sample.
	return total / float(FLOW_SAMPLES)


## What the colony's FARMS produce per second. Computed, not measured.
##
## This is the stable half of the food picture, and it is stable because it is derived from
## something that does not jump: how many people are standing in a farm. Measuring farm output
## instead meant the readout lurched every time a load was dropped off, which made a steady
## economy look erratic and an erratic one unreadable.
func farm_supply_per_second() -> float:
	var rate := 0.0
	for job: JobDef in Jobs.all():
		if job.workplace == &"" or not job.cycle_yield.has(&"food"):
			continue
		var per_worker_second := float(job.cycle_yield[&"food"]) / maxf(job.cycle_work, 0.01)
		# Count occupied work slots rather than job headcount: a villager assigned to farming
		# who has not reached a farm is not producing anything yet.
		var workers := 0
		for b in buildings:
			if not is_instance_valid(b) or b.is_site():
				continue
			var bdef: BuildingDef = b.def
			if bdef.workplace_key() == job.workplace:
				workers += _slot_users(_work_users, b).size()
		rate += float(workers) * per_worker_second * job.work_rate * FARM_DUTY_CYCLE \
			* Climate.farm_multiplier()
	return rate


## Everything else coming in — foraging, berries, ruins, salvage. Measured, because there is no
## way to compute a rate for a finite berry patch someone happens to be walking to.
##
## Derived by subtracting what we already know from the observed net, so it only ever accounts
## for the part farms do not explain. Floored at zero: a negative here means the estimate of
## farm output ran slightly ahead of reality, not that foraging is eating food.
func gathered_supply_per_second() -> float:
	return maxf(food_measured_net() + food_demand_per_second() - farm_supply_per_second(), 0.0)


func food_supply_per_second() -> float:
	return farm_supply_per_second() + gathered_supply_per_second()


## The figure the HUD prints. Stable, because its dominant term is computed rather than sampled.
func food_net_per_second() -> float:
	return food_supply_per_second() - food_demand_per_second()


# --- Migration -----------------------------------------------------------------------------

## Births, then the wandering-survivor timer.
func _step_migration(delta: float) -> void:
	if _spawn_parent == null or villagers.is_empty():
		return                      # a dead colony neither breeds nor attracts anyone
	_step_births(delta)
	_step_migrant_offers(delta)


# --- Births ---------------------------------------------------------------------------------

## True while the colony is comfortable enough to grow on its own. Every clause is something the
## player controls, and the HUD names whichever one is failing.
func birth_blocker() -> String:
	if beds_free() <= 0:
		return "BLOCK_NO_BEDS"
	if not has_water_access():
		return "BLOCK_NO_WATER"
	if food_days() < BIRTH_MIN_FOOD_DAYS:
		return "BLOCK_LITTLE_FOOD"
	if average_mood() < BIRTH_MIN_MOOD:
		return "BLOCK_UNHAPPY"
	if _eligible_birth_pair().is_empty():
		return "BLOCK_NO_HOUSEHOLD"
	return ""


func _step_births(delta: float) -> void:
	# Stall, do not reset. Losing a day of progress to one bad night is a setback; losing all of
	# it is a punishment that makes the player stop trying to grow at all.
	if birth_blocker() != "":
		return
	migration_progress += birth_rate() * delta
	if migration_progress < _birth_target:
		return
	migration_progress = 0.0
	_roll_birth_target()
	_admit_migrant(true)


func birth_rate() -> float:
	return BIRTH_BASE_RATE \
		* clampf(float(beds_free()) / 2.0, 0.5, 1.5) \
		* clampf(food_days() / 4.0, 0.5, 1.5) \
		* clampf(average_mood() / 65.0, 0.5, 1.5) \
		* Difficulties.migration_mult()


## Each birth needs a different amount of progress, so growth never lands on a beat the player
## can count. The spread is wide enough to feel organic and tight enough to stay plannable.
func _roll_birth_target() -> void:
	_birth_target = randf_range(0.75, 1.35)


# --- Wandering survivors ---------------------------------------------------------------------

## Runs regardless of how the colony is doing. Whether these people are an asset or a burden is
## the player's problem, which is the entire point.
func _step_migrant_offers(delta: float) -> void:
	if pending_migrants > 0:
		_migrant_patience -= delta
		if _migrant_patience <= 0.0:
			Events.notice.emit(tr(&"NOTICE_MIGRANTS_LEAVE"), 1)
			_clear_offer()
		return

	_migrant_timer -= delta
	if _migrant_timer > 0.0:
		return
	_reset_migrant_timer()

	var cell := _arrival_cell()
	if cell == -1:
		return
	# Small bands, weighted toward one or two. A group of five arriving at a six-person colony
	# would be less a decision than a disaster.
	pending_migrants = 1 + (randi() % 3 if randf() < 0.45 else 0)
	_migrant_cell = cell
	_migrant_patience = MIGRANT_PATIENCE
	Events.migrants_arrived.emit(pending_migrants)
	# Separate singular and plural KEYS rather than splicing an "s" onto the number. Plural rules
	# differ wildly between languages and an English suffix hardcoded into the format string cannot
	# be translated away.
	Events.notice.emit(L10n.t(
		&"NOTICE_MIGRANTS_WAITING_ONE" if pending_migrants == 1 else &"NOTICE_MIGRANTS_WAITING",
		[pending_migrants]), 1)


func _reset_migrant_timer() -> void:
	# Jittered hard so arrivals are not predictable, and slowed on harsher tiers.
	var scale := 1.0 / maxf(Difficulties.migration_mult(), 0.1)
	_migrant_timer = MIGRANT_INTERVAL * scale * randf_range(0.6, 1.5)


## Let them in — beds or no beds. Overcrowding is a legitimate choice.
func accept_migrants() -> void:
	if pending_migrants <= 0:
		return
	var count := pending_migrants
	var cell := _migrant_cell
	_clear_offer()
	var admitted := 0
	for _i in count:
		var at := World.nearest_walkable(cell, 6)
		if at != -1 and spawn_villager(at) != null:
			admitted += 1
	if admitted > 0:
		Events.notice.emit(L10n.t(&"NOTICE_MIGRANTS_JOINED", [admitted]), 0)


## Send them away. Costs a little morale — your own people watched you do it.
func refuse_migrants() -> void:
	if pending_migrants <= 0:
		return
	_clear_offer()
	for v in villagers:
		if is_instance_valid(v) and v.alive:
			v.mood = maxf(v.mood - REFUSAL_MOOD_COST, 0.0)
	Events.notice.emit(tr(&"NOTICE_MIGRANTS_REFUSED"), 1)


func _clear_offer() -> void:
	pending_migrants = 0
	_migrant_patience = 0.0
	_migrant_cell = -1
	Events.migrants_resolved.emit()


## Spare sleeping room. The cap on the colony's size, and the reason huts matter.
func beds_free() -> int:
	var free := 0
	for b in buildings:
		if is_instance_valid(b) and not b.is_site() and b.def.sleep_slots > 0:
			free += b.def.sleep_slots - _slot_users(_bed_users, b).size()
	return free


## Work the colony has asked for and cannot currently staff. Word of a settlement that needs
## hands is what draws people; a fully staffed one still draws a trickle.
func work_slots_free() -> int:
	var wanted := 0
	for job in quotas:
		# Only work that can actually be done counts. A quota left on sawing after the sawmill
		# burned down is not a vacancy, and letting it read as one advertised the colony as busier
		# than it was — which is one of the things that draws migrants.
		var def := Jobs.get_job(job)
		if def == null or not Jobs.has_workplace(def):
			continue
		wanted += int(quotas[job])
	return maxi(wanted - population(), 0)


## How many day cycles the larder would last at the colony's current size.
##
## Derived from the villagers' own hunger constants rather than a magic number, so retuning
## hunger cannot silently break the migration gate.
func food_days() -> float:
	var per_second := food_demand_per_second()
	if per_second <= 0.0:
		return 999.0
	return float(amount_of(&"food") + amount_of(&"rations") * 2) \
		/ (per_second * Sim.cycle_seconds())


## Food the colony eats per second, right now.
##
## Derived from the villagers' own constants rather than written down, so retuning hunger
## cannot silently desync the migration gate from the readout that explains it. A villager
## eats MEAL_COST every time they fall MEAL_RESTORE worth of hunger, so the long-run rate is
## simply the ratio of the two times the decay.
func food_demand_per_second() -> float:
	var pop := population()
	if pop <= 0:
		return 0.0
	return (Villager.HUNGER_RATE * Difficulties.needs_mult() / Villager.MEAL_RESTORE) \
		* float(Villager.MEAL_COST) * float(pop)


## A new life. Born at the Hearth rather than walking in from the map edge — this one came from
## inside the colony, and the arrival should read differently from a stranger's.
func _admit_migrant(born: bool = false) -> void:
	var cell := World.nearest_walkable(World.keep_cell, 8) if born else _arrival_cell()
	if cell == -1:
		return
	if spawn_villager(cell, born) != null:
		Events.migrant_arrived.emit(cell)
		Events.notice.emit(tr(&"NOTICE_CHILD_BORN" if born else &"NOTICE_SURVIVOR_ARRIVES"), 0)


## Admit a storyteller refugee band through the same safe edge-placement path as ordinary
## migrants. Returns the number that actually reached the map.
func admit_event_survivors(count: int) -> int:
	var admitted := 0
	for _i in maxi(count, 0):
		var cell := _arrival_cell()
		if cell != -1 and spawn_villager(cell) != null:
			admitted += 1
	if admitted > 0:
		Events.notice.emit(L10n.t(&"NOTICE_MIGRANTS_JOINED", [admitted]), 0)
	return admitted


func admit_route_settler(row: Dictionary) -> bool:
	if _spawn_parent == null or population() >= workforce_cap():
		return false
	var cell := _arrival_cell()
	if cell == -1:
		cell = World.nearest_walkable(World.keep_cell, 8)
	if cell == -1:
		return false
	var v: Villager = VILLAGER_SCENE.instantiate()
	v.position = World.grid.to_world_index(cell)
	v.job = StringName(row.get("job", &""))
	v.food = float(row.get("food", 80.0))
	v.water = float(row.get("water", 80.0))
	v.rest = float(row.get("rest", 80.0))
	v.mood = float(row.get("mood", 60.0))
	v.health = float(row.get("health", v.max_health))
	v.carry_kind = StringName(row.get("carry_kind", &""))
	v.carry_amount = int(row.get("carry_amount", 0))
	v.pending_loads = row.get("pending_loads", []).duplicate(true)
	v.statuses = row.get("statuses", {}).duplicate(true)
	if row.has("record"):
		v.restore_profile(row.get("record", {}))
	_spawn_parent.add_child(v)
	_form_households()
	Events.migrant_arrived.emit(cell)
	return true


func adjust_mood(amount: float) -> void:
	for v in villagers:
		if is_instance_valid(v) and v.alive:
			v.mood = clampf(v.mood + amount, 0.0, 100.0)


## A walkable edge cell that can actually reach the keep. An arrival stranded across water
## would stand on the shore forever looking like a broken villager.
func _arrival_cell() -> int:
	var grid: Grid = World.grid
	for _attempt in 24:
		var cell := -1
		match randi() % 4:
			0: cell = grid.index(randi_range(0, grid.width - 1), 1)
			1: cell = grid.index(randi_range(0, grid.width - 1), grid.height - 2)
			2: cell = grid.index(1, randi_range(0, grid.height - 1))
			_: cell = grid.index(grid.width - 2, randi_range(0, grid.height - 1))
		var walkable := World.nearest_walkable(cell, 6)
		if walkable != -1 and not World.paths.solve(walkable, World.keep_cell).is_empty():
			return walkable
	return -1


## The one place a villager is created. Founders and migrants come through here alike, so the
## two can never drift apart.
func spawn_villager(cell: int, born: bool = false) -> Node:
	if _spawn_parent == null or not World.grid.is_valid_index(cell) \
			or population() >= workforce_cap():
		return null
	var v: Villager = VILLAGER_SCENE.instantiate()
	v.profile = Villager._make_profile(villagers.size(), born)
	if born:
		var parents := _eligible_birth_pair()
		if parents.size() == 2:
			v.profile.household_id = parents[0].profile.household_id
			# Update 2 faith conception: a pair within 90% of their combined maximum
			# conceives a Nephilim child. This is decided before the node enters the tree,
			# so Influence contribution and restoration see one stable identity.
			var combined_faith := float(parents[0].profile.faith) \
				+ float(parents[1].profile.faith)
			v.profile.villager_type = &"nephilim" if combined_faith >= 180.0 else &"child"
			for parent in parents:
				parent.profile.birth_cooldown_until_day = Sim.day + 5
				v.profile.parents.append(parent.profile.stable_id)
			# Children inherit part of both parents' learned knowledge, while their active mastery
			# begins lower so lived experience still matters. Every job is serialized by id.
			var inherited_jobs: Dictionary = {}
			for parent in parents:
				for learned_job in parent.profile.mastery:
					inherited_jobs[learned_job] = float(inherited_jobs.get(learned_job, 0.0)) \
						+ parent.profile.mastery_of(learned_job) * 0.5
			for learned_job in inherited_jobs:
				var inherited := clampf(float(inherited_jobs[learned_job]) * 0.35, 0.0, 0.35)
				v.profile.inherited_mastery[learned_job] = inherited
				v.profile.mastery[learned_job] = inherited
	v.position = World.grid.to_world_index(cell)
	_spawn_parent.add_child(v)
	_form_households()
	return v


## The one creation path for mobile divine constructs. Limits live here as well as in Divine's
## placement preview so restoration and internal callers cannot bypass the shared path budget.
func spawn_golem(def: PowerDef, cell: int) -> Golem:
	if _spawn_parent == null or def == null or def.construct_role.is_empty() \
			or golem_count() >= GOLEM_CAP \
			or (def.persistent_limit > 0 and golem_count(def.id) >= def.persistent_limit) \
			or not World.grid.is_valid_index(cell) \
			or not World.is_walkable(cell):
		return null
	var golem: Golem = GOLEM_SCENE.instantiate()
	golem.setup(def)
	golem.position = World.grid.to_world_index(cell)
	_spawn_parent.add_child(golem)
	Diagnostics.record_golem_count(golem_count())
	return golem


func golem_count(power_id: StringName = &"") -> int:
	var count := 0
	for golem in golems:
		if not is_instance_valid(golem) or not golem.alive:
			continue
		if power_id.is_empty() or golem.power_id == power_id:
			count += 1
	return count


func spawn_animal(kind: StringName, at_cell: int) -> Animal:
	if _spawn_parent == null or not World.grid.is_valid_index(at_cell) \
			or not World.is_walkable(at_cell):
		return null
	var animal: Animal = ANIMAL_SCENE.instantiate()
	animal.setup(kind)
	animal.position = World.grid.to_world_index(at_cell)
	_spawn_parent.add_child(animal)
	return animal


func _supply_carriers() -> Array:
	var out := villagers.duplicate()
	out.append_array(golems)
	return out


func _eligible_birth_pair() -> Array:
	var by_id: Dictionary = {}
	for v in villagers:
		if is_instance_valid(v) and v.alive and v.is_adult():
			by_id[v.profile.stable_id] = v
	for v in villagers:
		if not is_instance_valid(v) or not v.alive or not v.is_adult():
			continue
		if v.profile.partner_id.is_empty() or v.profile.birth_cooldown_until_day > Sim.day:
			continue
		var partner = by_id.get(v.profile.partner_id)
		if partner != null and partner.profile.birth_cooldown_until_day <= Sim.day:
			return [v, partner]
	return []


func _form_households() -> void:
	var unpaired: Array = []
	for v in villagers:
		if is_instance_valid(v) and v.alive and v.is_adult() and v.profile.partner_id.is_empty():
			unpaired.append(v)
	unpaired.sort_custom(func(a, b) -> bool: return a.profile.stable_id < b.profile.stable_id)
	while unpaired.size() >= 2:
		var first = unpaired.pop_front()
		var second = unpaired.pop_front()
		var household := "home-%s" % first.profile.stable_id
		first.profile.partner_id = second.profile.stable_id
		second.profile.partner_id = first.profile.stable_id
		first.profile.household_id = household
		second.profile.household_id = household


func refresh_households() -> void:
	_form_households()


func record_memorial(record: Dictionary) -> void:
	memorials.append(record.duplicate(true))
	if memorials.size() > 256:
		memorials.pop_front()


func release_household_partner(departed: Villager) -> void:
	if departed == null or departed.profile.partner_id.is_empty():
		return
	for villager in villagers:
		if is_instance_valid(villager) and villager != departed \
				and villager.profile.stable_id == departed.profile.partner_id:
			villager.profile.partner_id = ""
			villager.profile.household_id = ""
			break


func _on_day_advanced(_day: int) -> void:
	for v in villagers.duplicate():
		if not is_instance_valid(v) or not v.alive:
			continue
		var was_adult: bool = v.is_adult()
		v.profile.age_days += 1
		if not was_adult and v.is_adult():
			if v.profile.villager_type != &"nephilim":
				v.profile.villager_type = &"adult"
			Events.notice.emit("%s has come of age." % v.profile.display_name, 0)
		elif v.profile.villager_type != &"nephilim" and v.is_adult() \
				and v.profile.age_days >= int(v.profile.max_age_days * 0.67):
			v.profile.villager_type = &"elder"
		if v.profile.age_days >= v.profile.max_age_days:
			v.die(&"age")
	_form_households()
	apply_daily_spoilage()


# --- Resources ---------------------------------------------------------------------

func add(kind: StringName, amount: int) -> void:
	if amount == 0:
		return
	if amount < 0:
		withdraw_any(kind, -amount)
		return
	var remaining := amount
	while remaining > 0:
		var cell := nearest_storage_destination(World.keep_cell, kind)
		if cell == -1:
			break
		var b := storage_at(cell)
		if b == null:
			break
		var accepted: int = b.inventory_deposit(kind, remaining)
		if accepted <= 0:
			break
		remaining -= accepted
	if remaining > 0:
		overflow[kind] = int(overflow.get(kind, 0)) + remaining
	_change_stock(kind, amount)


## What is actually spendable: on the shelf and not already promised elsewhere.
func available(kind: StringName) -> int:
	return maxi(stock.get(kind, 0) - reserved.get(kind, 0) - buffered.get(kind, 0) \
		- supply_reserved.get(kind, 0), 0)


func can_afford(cost: Dictionary) -> bool:
	for kind: StringName in cost:
		if available(kind) < int(cost[kind]):
			return false
	return true


## Promise a cost to a blueprint. Caller must have checked can_afford first.
func reserve(cost: Dictionary) -> void:
	for kind: StringName in cost:
		reserved[kind] = reserved.get(kind, 0) + int(cost[kind])
	Events.resources_changed.emit(&"", 0)


## Give back an unspent promise — a blueprint cancelled or destroyed before its
## materials were carried out. Skipping this silently locks resources away for the
## rest of the run.
func unreserve(cost: Dictionary) -> void:
	for kind: StringName in cost:
		reserved[kind] = maxi(reserved.get(kind, 0) - int(cost[kind]), 0)
	Events.resources_changed.emit(&"", 0)


## A builder collecting promised materials from a stockpile. Takes them off the
## shelf AND releases the matching promise, since they are now in someone's arms.
func withdraw_reserved(kind: StringName, amount: int) -> int:
	var source := nearest_storage_source(World.keep_cell, kind)
	return withdraw_reserved_at(source, kind, amount) if source != -1 else 0


func withdraw_reserved_at(cell: int, kind: StringName, amount: int) -> int:
	var taken := mini(amount, mini(amount_at(cell, kind), reserved.get(kind, 0)))
	if taken <= 0:
		return 0
	reserved[kind] = reserved.get(kind, 0) - taken
	return withdraw_at(cell, kind, taken)


func spend(cost: Dictionary) -> bool:
	return spend_near(World.keep_cell, cost)


func spend_near(from: int, cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	for kind: StringName in cost:
		withdraw_any(kind, int(cost[kind]), from)
	return true


func amount_of(kind: StringName) -> int:
	return stock.get(kind, 0)


func _change_stock(kind: StringName, delta: int) -> void:
	stock[kind] = maxi(int(stock.get(kind, 0)) + delta, 0)
	Events.resources_changed.emit(kind, stock[kind])


# --- Physical supply requests -------------------------------------------------------------

func mark_supply_requests_dirty() -> void:
	_supply_requests_dirty = true


func _building_at_anchor(anchor: int) -> Building:
	for candidate in buildings:
		var b := candidate as Building
		if b != null and is_instance_valid(b) and b.anchor == anchor \
				and b.state == Building.State.COMPLETE:
			return b
	return null


func _supply_request_by_id(request_id: int) -> SupplyRequest:
	for request in supply_requests:
		if request.id == request_id:
			return request
	return null


func _supply_specs_for(b: Building) -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	if b.def.input_capacity <= 0:
		return specs
	if not b.def.ammo_kind.is_empty() and b.def.ammo_per_shot > 0:
		specs.append({
			"resource": b.def.ammo_kind,
			"target": mini(b.def.input_capacity, b.def.ammo_per_shot * 12),
			"priority": 320 if Sim.is_dark() else 260,
		})
		return specs
	for job_def in Jobs.all():
		if job_def.workplace != b.def.id or job_def.cycle_cost.is_empty() \
				or not job_def.supports_production_policy \
				or not b.production_is_available(job_def):
			continue
		var protects_needs := job_def.requires_water_access \
			or job_def.cycle_yield.has(&"food") or job_def.cycle_yield.has(&"rations")
		for raw_kind in job_def.cycle_cost:
			var kind := StringName(raw_kind)
			specs.append({
				"resource": kind,
				"target": mini(b.def.input_capacity, int(job_def.cycle_cost[kind]) * 2),
				"priority": 210 if protects_needs else 120,
			})
		break
	return specs


## Reconcile content-driven requests against the buildings that actually stand on the map.
## Existing ids survive so a carrier can still name its destination through save/reload.
func refresh_supply_requests(force: bool = false) -> void:
	if not force and not _supply_requests_dirty and _supply_refresh_tick == Sim.tick:
		return
	_supply_refresh_tick = Sim.tick
	_supply_requests_dirty = false
	var wanted: Dictionary = {}
	for candidate in buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.state != Building.State.COMPLETE:
			continue
		for spec in _supply_specs_for(b):
			var kind := StringName(spec["resource"])
			var key := "%d:%s" % [b.anchor, kind]
			wanted[key] = {
				"destination": b.anchor,
				"resource": kind,
				"target": int(spec["target"]),
				"priority": int(spec["priority"]),
			}

	var existing: Dictionary = {}
	for request in supply_requests:
		existing["%d:%s" % [request.destination, request.resource]] = request
	for key in wanted:
		var row: Dictionary = wanted[key]
		var request: SupplyRequest = existing.get(key)
		if request == null:
			request = SupplyRequest.new()
			request.id = _next_supply_request_id
			_next_supply_request_id += 1
			request.destination = int(row["destination"])
			request.resource = StringName(row["resource"])
			supply_requests.append(request)
		request.target = int(row["target"])
		request.priority = int(row["priority"])

	for i in range(supply_requests.size() - 1, -1, -1):
		var request := supply_requests[i]
		var key := "%d:%s" % [request.destination, request.resource]
		if wanted.has(key):
			continue
		_release_supply_shelf(request)
		_supply_claims.erase(request.id)
		supply_requests.remove_at(i)


func _supply_reserved_at(cell: int, kind: StringName) -> int:
	var by_kind: Dictionary = _supply_reservations_by_cell.get(cell, {})
	return int(by_kind.get(kind, 0))


func _change_supply_reserved_at(cell: int, kind: StringName, delta: int) -> void:
	if cell == -1 or delta == 0:
		return
	var by_kind: Dictionary = _supply_reservations_by_cell.get(cell, {})
	var next := maxi(int(by_kind.get(kind, 0)) + delta, 0)
	if next > 0:
		by_kind[kind] = next
	else:
		by_kind.erase(kind)
	if by_kind.is_empty():
		_supply_reservations_by_cell.erase(cell)
	else:
		_supply_reservations_by_cell[cell] = by_kind


func _reserve_supply_shelf(request: SupplyRequest, source: int, amount: int) -> void:
	if request == null or amount <= 0:
		return
	request.source = source
	request.shelf_reserved += amount
	request.reserved += amount
	supply_reserved[request.resource] = int(supply_reserved.get(request.resource, 0)) + amount
	_change_supply_reserved_at(source, request.resource, amount)
	Events.resources_changed.emit(&"", 0)


func _release_supply_shelf(request: SupplyRequest) -> int:
	if request == null or request.shelf_reserved <= 0:
		return 0
	var released := request.shelf_reserved
	supply_reserved[request.resource] = maxi(
		int(supply_reserved.get(request.resource, 0)) - released, 0)
	_change_supply_reserved_at(request.source, request.resource, -released)
	request.shelf_reserved = 0
	request.source = -1
	Events.resources_changed.emit(&"", 0)
	return released


func _nearest_supply_source(from: int, kind: StringName) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for raw_cell in _storage_by_cell.keys():
		var cell := int(raw_cell)
		if amount_at(cell, kind) - _supply_reserved_at(cell, kind) <= 0:
			continue
		var distance := World.grid.dist_sq(from, cell)
		if distance < best_dist:
			best_dist = distance
			best = cell
	var overflow_at := overflow_cell()
	if int(overflow.get(kind, 0)) - _supply_reserved_at(overflow_at, kind) > 0 \
			and World.grid.is_valid_index(overflow_at):
		var overflow_dist := World.grid.dist_sq(from, overflow_at)
		if overflow_dist < best_dist:
			best = overflow_at
	return best


## Claim the highest-priority reachable request and reserve its goods before walking toward it.
## The return row is deliberately enough to drive any physical carrier without exposing requests.
func claim_supply_request(worker: Agent, from: int, capacity: int) -> Dictionary:
	if worker == null or capacity <= 0:
		return {}
	refresh_supply_requests()
	var candidates: Array[SupplyRequest] = []
	for request in supply_requests:
		var claimant = _supply_claims.get(request.id)
		if claimant != null and (not is_instance_valid(claimant) or not claimant.alive):
			var abandoned := _release_supply_shelf(request)
			request.reserved = maxi(request.reserved - abandoned, 0)
			# A normal death releases carried goods before leaving the roster. Anything still
			# committed here belongs to an object that vanished unexpectedly, so unlock it.
			request.reserved = 0
			_supply_claims.erase(request.id)
			claimant = null
		if claimant != null or request.reserved > 0:
			continue
		var destination := _building_at_anchor(request.destination)
		if destination == null:
			continue
		var local := int(destination.input_buffer.get(request.resource, 0))
		if request.target - local <= 0 or available(request.resource) <= 0:
			continue
		if _nearest_supply_source(from, request.resource) != -1:
			candidates.append(request)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: SupplyRequest, b: SupplyRequest) -> bool:
		if a.priority != b.priority:
			return a.priority > b.priority
		return World.grid.dist_sq(from, a.destination) < World.grid.dist_sq(from, b.destination)
	)
	for request in candidates:
		var destination := _building_at_anchor(request.destination)
		if destination == null:
			continue
		var source := _nearest_supply_source(from, request.resource)
		if source == -1:
			continue
		var outstanding := maxi(request.target \
			- int(destination.input_buffer.get(request.resource, 0)) - request.reserved, 0)
		var local_free := maxi(amount_at(source, request.resource) \
			- _supply_reserved_at(source, request.resource), 0)
		var amount := mini(capacity, mini(outstanding, mini(available(request.resource), local_free)))
		if amount <= 0:
			continue
		_supply_claims[request.id] = worker
		_reserve_supply_shelf(request, source, amount)
		return {
			"id": request.id,
			"source": source,
			"destination": request.destination,
			"resource": request.resource,
			"amount": amount,
		}
	return {}


func withdraw_supply_request(request_id: int, worker: Agent, cell: int, limit: int) -> int:
	var request := _supply_request_by_id(request_id)
	if request == null or _supply_claims.get(request_id) != worker \
			or request.source != cell or request.shelf_reserved <= 0:
		return 0
	var promised := mini(request.shelf_reserved, maxi(limit, 0))
	var taken := withdraw_at(cell, request.resource, promised)
	var shelf_total := _release_supply_shelf(request)
	# The amount picked up remains reserved while it is in transit. Anything the shelf could
	# not provide is released immediately rather than becoming a phantom promise.
	request.reserved = maxi(request.reserved - shelf_total + taken, 0)
	return taken


func supply_destination(request_id: int) -> Building:
	var request := _supply_request_by_id(request_id)
	return _building_at_anchor(request.destination) if request != null else null


func resume_supply_request(request_id: int, worker: Agent, carried: int) -> Building:
	var request := _supply_request_by_id(request_id)
	var destination := supply_destination(request_id)
	if request == null or destination == null or carried <= 0:
		return null
	_supply_claims[request_id] = worker
	request.reserved = maxi(request.reserved, carried)
	return destination


func complete_supply_delivery(request_id: int, amount: int) -> void:
	var request := _supply_request_by_id(request_id)
	if request == null or amount <= 0:
		return
	request.reserved = maxi(request.reserved - amount, 0)
	mark_supply_requests_dirty()


## Release both legs of a promise. `carried` remains physically in the carrier's arms; only its
## destination commitment is removed, so ordinary hauling or a death spill can recover it.
func release_supply_request(request_id: int, worker: Agent, carried: int = 0) -> void:
	var request := _supply_request_by_id(request_id)
	if request == null:
		_supply_claims.erase(request_id)
		return
	var claimant = _supply_claims.get(request_id)
	if claimant != null and claimant != worker:
		return
	var shelf := _release_supply_shelf(request)
	request.reserved = maxi(request.reserved - shelf - maxi(carried, 0), 0)
	_supply_claims.erase(request_id)
	mark_supply_requests_dirty()


## Save only promises represented by real carried units. A path to a shelf is disposable state;
## rebuilding it on load prevents stale source reservations without moving or creating stock.
func pack_supply_requests() -> Array:
	refresh_supply_requests(true)
	var rows: Array = []
	for request in supply_requests:
		var in_transit := 0
		for carrier in _supply_carriers():
			if is_instance_valid(carrier) and carrier.alive \
					and carrier._supply_request_id == request.id \
					and carrier.carry_kind == request.resource:
				in_transit += maxi(carrier.carry_amount, 0)
		var row := request.to_dict()
		row["reserved"] = in_transit
		rows.append(row)
	return rows


func restore_supply_requests(rows: Array) -> void:
	supply_requests.clear()
	_supply_claims.clear()
	_supply_reservations_by_cell.clear()
	_next_supply_request_id = 1
	for kind in KINDS:
		supply_reserved[kind] = 0
	for row: Dictionary in rows:
		var request := SupplyRequest.from_dict(row)
		if request.id <= 0 or request.destination < 0 or request.resource.is_empty():
			continue
		supply_requests.append(request)
		_next_supply_request_id = maxi(_next_supply_request_id, request.id + 1)
	_supply_requests_dirty = true


func rebuild_supply_reservations_from_carriers() -> void:
	_supply_claims.clear()
	_supply_reservations_by_cell.clear()
	for kind in KINDS:
		supply_reserved[kind] = 0
	for request in supply_requests:
		request.reserved = 0
		request.shelf_reserved = 0
		request.source = -1
	for carrier in _supply_carriers():
		if not is_instance_valid(carrier) or carrier._supply_request_id <= 0:
			continue
		var request := _supply_request_by_id(carrier._supply_request_id)
		if request == null or supply_destination(request.id) == null \
				or carrier.carry_amount <= 0 or carrier.carry_kind != request.resource:
			carrier._supply_request_id = 0
			continue
		request.reserved += carrier.carry_amount
		_supply_claims[request.id] = carrier
	refresh_supply_requests(true)


# --- Stockpiles ---------------------------------------------------------------------

func add_stockpile(cell: int) -> void:
	if cell != -1 and not cell in stockpiles:
		stockpiles.append(cell)


func remove_stockpile(cell: int) -> void:
	var idx := stockpiles.find(cell)
	if idx == -1:
		return
	stockpiles[idx] = stockpiles[stockpiles.size() - 1]
	stockpiles.resize(stockpiles.size() - 1)


func register_storage(b: Building) -> void:
	if b == null or b.def == null or not b.def.is_stockpile:
		return
	_storage_by_cell[b.centre_cell()] = b
	# A newly completed store immediately absorbs compatible Hearth overflow. The
	# aggregate cache does not change because this is a physical move, not creation.
	for raw_kind in overflow.keys():
		var kind := StringName(raw_kind)
		var have := int(overflow.get(kind, 0))
		if have <= 0 or not DefenseControl.stockpile_accepts(b.centre_cell(), kind):
			continue
		var accepted: int = b.inventory_deposit(kind, have)
		if accepted > 0:
			overflow[kind] = have - accepted
	for i in range(overflow_items.size() - 1, -1, -1):
		if b.inventory_deposit_item(overflow_items[i]):
			overflow_items.remove_at(i)


func unregister_storage(b: Building) -> void:
	if b == null:
		return
	var cell := b.centre_cell()
	if _storage_by_cell.get(cell) == b:
		_storage_by_cell.erase(cell)


func storage_at(cell: int) -> Building:
	var b = _storage_by_cell.get(cell)
	if b == null or not is_instance_valid(b) or b.state != Building.State.COMPLETE:
		return null
	return b as Building


func overflow_cell() -> int:
	return World.keep_cell


func amount_at(cell: int, kind: StringName) -> int:
	var total := 0
	var b := storage_at(cell)
	if b != null:
		total += int(b.inventory.get(kind, 0))
	if cell == overflow_cell():
		total += int(overflow.get(kind, 0))
	return total


func deposit_at(cell: int, kind: StringName, amount: int) -> int:
	var b := storage_at(cell)
	if b == null or amount <= 0:
		return 0
	var accepted := b.inventory_deposit(kind, amount)
	if accepted > 0:
		_change_stock(kind, accepted)
	return accepted


func deposit_building_input(b: Building, kind: StringName, amount: int) -> int:
	if b == null or not is_instance_valid(b):
		return 0
	var accepted := b.deposit_input_local(kind, amount)
	if accepted > 0:
		buffered[kind] = int(buffered.get(kind, 0)) + accepted
		_change_stock(kind, accepted)
		mark_supply_requests_dirty()
	return accepted


func consume_building_inputs(b: Building, cost: Dictionary) -> bool:
	if b == null:
		return false
	for kind: StringName in cost:
		if int(b.input_buffer.get(kind, 0)) < int(cost[kind]):
			return false
	for kind: StringName in cost:
		var taken := b.withdraw_input_local(kind, int(cost[kind]))
		buffered[kind] = maxi(int(buffered.get(kind, 0)) - taken, 0)
		_change_stock(kind, -taken)
	mark_supply_requests_dirty()
	return true


func deposit_building_output(b: Building, kind: StringName, amount: int) -> int:
	if b == null or not is_instance_valid(b):
		return 0
	var accepted := b.deposit_output_local(kind, amount)
	if accepted > 0:
		_change_stock(kind, accepted)
	return accepted


func withdraw_building_output(b: Building, kind: StringName, amount: int) -> int:
	if b == null or not is_instance_valid(b):
		return 0
	var taken := b.withdraw_output_local(kind, amount)
	if taken > 0:
		_change_stock(kind, -taken)
	return taken


func withdraw_at(cell: int, kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var remaining := amount
	var taken := 0
	var b := storage_at(cell)
	if b != null:
		var local_taken: int = b.inventory_withdraw(kind, remaining)
		taken += local_taken
		remaining -= local_taken
	if remaining > 0 and cell == overflow_cell():
		var overflow_taken := mini(remaining, int(overflow.get(kind, 0)))
		overflow[kind] = int(overflow.get(kind, 0)) - overflow_taken
		taken += overflow_taken
	if taken > 0:
		_change_stock(kind, -taken)
	return taken


func withdraw_any(kind: StringName, amount: int, from: int = -1) -> int:
	var remaining := mini(maxi(amount, 0), amount_of(kind))
	var total := 0
	var origin := from if World.grid.is_valid_index(from) else World.keep_cell
	while remaining > 0:
		var cell := nearest_storage_source(origin, kind)
		if cell == -1:
			break
		var taken := withdraw_at(cell, kind, remaining)
		if taken <= 0:
			break
		total += taken
		remaining -= taken
	return total


## On destruction the container disappears but its numbers do not. Overflow is
## deliberately allowed beyond Hearth capacity so a lost warehouse cannot delete a realm.
func evacuate_inventory(b: Building) -> void:
	if b == null or (b.inventory.is_empty() and b.item_inventory.is_empty() \
			and b.input_buffer.is_empty() and b.output_buffer.is_empty()):
		return
	for raw_kind in b.inventory.keys():
		var kind := StringName(raw_kind)
		overflow[kind] = int(overflow.get(kind, 0)) + int(b.inventory.get(kind, 0))
	b.inventory.clear()
	overflow_items.append_array(b.item_inventory.duplicate(true))
	b.item_inventory.clear()
	for raw_kind in b.input_buffer.keys():
		var kind := StringName(raw_kind)
		var amount := int(b.input_buffer.get(kind, 0))
		overflow[kind] = int(overflow.get(kind, 0)) + amount
		buffered[kind] = maxi(int(buffered.get(kind, 0)) - amount, 0)
	b.input_buffer.clear()
	for raw_kind in b.output_buffer.keys():
		var kind := StringName(raw_kind)
		overflow[kind] = int(overflow.get(kind, 0)) + int(b.output_buffer.get(kind, 0))
	b.output_buffer.clear()
	mark_supply_requests_dirty()


func rebuild_stock_cache() -> void:
	for kind in KINDS:
		stock[kind] = int(overflow.get(kind, 0))
		buffered[kind] = 0
	for b in buildings:
		if not is_instance_valid(b):
			continue
		for raw_kind in b.inventory.keys():
			var kind := StringName(raw_kind)
			stock[kind] = int(stock.get(kind, 0)) + int(b.inventory.get(kind, 0))
		for raw_kind in b.input_buffer.keys():
			var kind := StringName(raw_kind)
			var amount := int(b.input_buffer.get(kind, 0))
			stock[kind] = int(stock.get(kind, 0)) + amount
			buffered[kind] = int(buffered.get(kind, 0)) + amount
		for raw_kind in b.output_buffer.keys():
			var kind := StringName(raw_kind)
			stock[kind] = int(stock.get(kind, 0)) + int(b.output_buffer.get(kind, 0))
	Events.resources_changed.emit(&"", 0)


func apply_daily_spoilage() -> void:
	for candidate in buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.inventory.is_empty():
			continue
		for raw_kind in b.inventory.keys():
			var kind := StringName(raw_kind)
			var resource: ResourceDef = Resources.get_resource(kind)
			if resource == null or resource.spoilage_per_day <= 0.0:
				continue
			var expected: float = float(b.inventory.get(kind, 0)) * resource.spoilage_per_day \
				* b.def.spoilage_multiplier * Doctrines.modifier(&"spoilage") \
				+ float(b.spoilage_progress.get(kind, 0.0))
			var lost: int = mini(floori(expected), int(b.inventory.get(kind, 0)))
			b.spoilage_progress[kind] = expected - float(lost)
			if lost > 0:
				b.inventory_withdraw(kind, lost)
				_change_stock(kind, -lost)
	for kind in KINDS:
		var resource: ResourceDef = Resources.get_resource(kind)
		if resource == null or resource.spoilage_per_day <= 0.0:
			continue
		var expected: float = float(overflow.get(kind, 0)) * resource.spoilage_per_day * 1.25 \
			* Doctrines.modifier(&"spoilage") \
			+ float(overflow_spoilage_progress.get(kind, 0.0))
		var lost: int = mini(floori(expected), int(overflow.get(kind, 0)))
		overflow_spoilage_progress[kind] = expected - float(lost)
		if lost > 0:
			overflow[kind] = int(overflow.get(kind, 0)) - lost
			_change_stock(kind, -lost)


# --- Lightweight items and equipment ----------------------------------------------------

func create_item(def_id: StringName, preferred_cell: int = -1) -> ItemRecord:
	var item_def := Items.get_item(def_id)
	if item_def == null:
		return null
	var uid := "%s-%d-%d" % [String(Realm.awake_id), Sim.tick, _next_item_serial]
	_next_item_serial += 1
	var record := ItemRecord.create(item_def, uid)
	store_item(record, preferred_cell)
	Events.resources_changed.emit(def_id, item_count(def_id))
	return record


func store_item(record: ItemRecord, preferred_cell: int = -1) -> bool:
	if record == null or Items.get_item(record.def_id) == null:
		return false
	var origin := preferred_cell if World.grid.is_valid_index(preferred_cell) else World.keep_cell
	var best: Building = null
	var best_dist := 0x7FFFFFFF
	var item_def := Items.get_item(record.def_id)
	for raw_cell in _storage_by_cell.keys():
		var cell := int(raw_cell)
		var b := storage_at(cell)
		if b == null or b.inventory_free() <= 0 or not b.accepts_item(item_def):
			continue
		var distance := World.grid.dist_sq(origin, cell)
		if distance < best_dist:
			best_dist = distance
			best = b
	if best != null and best.inventory_deposit_item(record.to_dict()):
		return true
	overflow_items.append(record.to_dict())
	return true


func item_count(def_id: StringName = &"") -> int:
	var total := 0
	for b in buildings:
		if not is_instance_valid(b):
			continue
		for row: Dictionary in b.item_inventory:
			if def_id.is_empty() or StringName(row.get("def", &"")) == def_id:
				total += 1
	for row: Dictionary in overflow_items:
		if def_id.is_empty() or StringName(row.get("def", &"")) == def_id:
			total += 1
	return total


func nearest_item_source(from: int, def_id: StringName) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for candidate in buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.is_site():
			continue
		for row: Dictionary in b.item_inventory:
			if StringName(row.get("def", &"")) != def_id:
				continue
			var distance := World.grid.dist_sq(from, b.centre_cell())
			if distance < best_dist:
				best_dist = distance
				best = b.centre_cell()
			break
	if not overflow_items.is_empty() and World.grid.is_valid_index(overflow_cell()):
		for row: Dictionary in overflow_items:
			if StringName(row.get("def", &"")) == def_id:
				var distance := World.grid.dist_sq(from, overflow_cell())
				if distance < best_dist:
					best = overflow_cell()
				break
	return best


func consume_item_at(cell: int, def_id: StringName) -> bool:
	for candidate in buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b) or b.is_site() \
				or b.centre_cell() != cell:
			continue
		for index in b.item_inventory.size():
			if StringName(b.item_inventory[index].get("def", &"")) == def_id:
				b.item_inventory.remove_at(index)
				b.queue_redraw()
				Events.resources_changed.emit(def_id, item_count(def_id))
				return true
	if cell == overflow_cell():
		for index in overflow_items.size():
			if StringName(overflow_items[index].get("def", &"")) == def_id:
				overflow_items.remove_at(index)
				Events.resources_changed.emit(def_id, item_count(def_id))
				return true
	return false


func has_stored_water() -> bool:
	return item_count(&"waterskin") > 0 or amount_of(&"clean_water") > 0 \
		or amount_of(&"dirty_water") > 0


func total_item_count(def_id: StringName = &"") -> int:
	var total := item_count(def_id)
	for villager in villagers:
		if not is_instance_valid(villager) or not villager.alive:
			continue
		for row in villager.profile.equipment.values():
			if typeof(row) == TYPE_DICTIONARY \
					and (def_id.is_empty() or StringName(row.get("def", &"")) == def_id):
				total += 1
	return total


func take_equipment(job_def: JobDef, slot: StringName, policy: StringName) -> ItemRecord:
	if policy == &"none":
		return null
	var best_row: Dictionary = {}
	var best_building: Building = null
	var best_index := -1
	var best_score := INF if policy == &"preserve_durability" else -INF
	for candidate in buildings:
		var b := candidate as Building
		if b == null or not is_instance_valid(b):
			continue
		for i in b.item_inventory.size():
			var row: Dictionary = b.item_inventory[i]
			var score := _equipment_score(row, job_def, slot)
			if score < 0.0:
				continue
			if (policy == &"preserve_durability" and score < best_score) \
					or (policy != &"preserve_durability" and score > best_score):
				best_score = score
				best_row = row
				best_building = b
				best_index = i
	for i in overflow_items.size():
		var row: Dictionary = overflow_items[i]
		var score := _equipment_score(row, job_def, slot)
		if score < 0.0:
			continue
		if (policy == &"preserve_durability" and score < best_score) \
				or (policy != &"preserve_durability" and score > best_score):
			best_score = score
			best_row = row
			best_building = null
			best_index = i
	if best_index < 0:
		return null
	if best_building != null:
		best_building.item_inventory.remove_at(best_index)
	else:
		overflow_items.remove_at(best_index)
	return ItemRecord.from_dict(best_row)


func _equipment_score(row: Dictionary, job_def: JobDef, slot: StringName) -> float:
	var item_def := Items.get_item(StringName(row.get("def", &"")))
	if item_def == null or item_def.slot != slot:
		return -1.0
	if job_def != null and not item_def.supports_job(job_def.equipment_tags):
		return -1.0
	var score := float(row.get("durability", 0)) / float(maxi(item_def.max_durability, 1))
	for value in item_def.modifiers.values():
		score += absf(float(value))
	for value in item_def.damage.values():
		score += absf(float(value)) * 0.1
	for value in item_def.resistances.values():
		score += absf(float(value))
	return score


func distribute_legacy_stock(legacy: Dictionary) -> void:
	for b in buildings:
		if is_instance_valid(b):
			b.inventory.clear()
			b.input_buffer.clear()
			b.output_buffer.clear()
	for kind in KINDS:
		stock[kind] = 0
		overflow[kind] = 0
		buffered[kind] = 0
	for raw_kind in legacy.keys():
		add(StringName(raw_kind), int(legacy.get(raw_kind, 0)))


## Drop goods on the ground at `cell`, merging with anything already lying there.
func create_loose_drop(cell: int, kind: StringName, amount: int,
		policy: StringName = LooseDrop.POLICY_WORKER, expires_tick: int = -1,
		source: StringName = &"") -> LooseDrop:
	if amount <= 0 or kind.is_empty() or not World.grid.is_valid_index(cell):
		return null
	for existing: LooseDrop in loose_drops.values():
		if existing.cell == cell and existing.kind == kind \
				and existing.collection_policy == policy \
				and existing.expires_tick == expires_tick and existing.source == source:
			existing.amount += amount
			Events.loose_drops_changed.emit(cell)
			return existing
	var drop := LooseDrop.new()
	drop.id = _next_loose_drop_id
	_next_loose_drop_id += 1
	drop.cell = cell
	drop.kind = kind
	drop.amount = amount
	drop.collection_policy = policy
	drop.expires_tick = expires_tick
	drop.source = source
	loose_drops[drop.id] = drop
	Events.loose_drops_changed.emit(cell)
	return drop


func drop_resource(kind: StringName, amount: int, cell: int,
		source: StringName = &"resource") -> LooseDrop:
	return create_loose_drop(cell, kind, amount, LooseDrop.POLICY_WORKER, -1, source)


## Nearest loose pile, or -1. Walkability is checked here rather than at spill time: a pile can be
## dropped under a building that is later raised over it, and a pile nobody can stand on is a pile
## nobody can collect.
func nearest_worker_drop(from: int) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for drop: LooseDrop in loose_drops.values():
		if not drop.can_collect(LooseDrop.POLICY_WORKER):
			continue
		if not World.has_walkable_neighbour(drop.cell) and not World.is_walkable(drop.cell):
			continue
		var distance := World.grid.dist_sq(from, drop.cell)
		if distance < best_dist:
			best_dist = distance
			best = drop.id
	return best


## Take one kind off a pile, clearing the entry when it empties. Returns {kind, amount}, empty
## when there was nothing there — a second porter can always beat you to it.
func take_loose_drop(id: int, limit: int, policy: StringName) -> Dictionary:
	var drop := loose_drops.get(id) as LooseDrop
	if drop == null or limit <= 0 or not drop.can_collect(policy):
		return {}
	var taken := mini(drop.amount, limit)
	drop.amount -= taken
	var changed_cell := drop.cell
	var kind := drop.kind
	if drop.amount <= 0:
		loose_drops.erase(id)
	Events.loose_drops_changed.emit(changed_cell)
	return {"kind": kind, "amount": taken}


func loose_resource_total() -> int:
	var total := 0
	for drop: LooseDrop in loose_drops.values():
		if drop.can_collect(LooseDrop.POLICY_WORKER):
			total += drop.amount
	return total


func essence_lifetime_ticks() -> int:
	return ceili(Sim.cycle_seconds() * Sim.TICK_HZ)


func drop_essence(cell: int, amount: int, source: StringName) -> LooseDrop:
	return create_loose_drop(cell, ESSENCE_KIND, amount, LooseDrop.POLICY_DIVINE,
		Sim.tick + essence_lifetime_ticks(), source)


func maybe_drop_harvest_essence(cell: int) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(World.seed_value) ^ (cell * 2654435761) ^ (Sim.tick * 40503)
	if rng.randf() >= 0.35:
		return false
	drop_essence(cell, 1, &"harvest")
	return true


func loose_drop(id: int) -> LooseDrop:
	return loose_drops.get(id) as LooseDrop


func essence_total() -> int:
	var total := 0
	for drop: LooseDrop in loose_drops.values():
		if drop.kind == ESSENCE_KIND and drop.can_collect(LooseDrop.POLICY_DIVINE):
			total += drop.amount
	return total


func has_essence_near(cell: int, radius: int) -> bool:
	if not World.grid.is_valid_index(cell):
		return false
	for drop: LooseDrop in loose_drops.values():
		if drop.kind == ESSENCE_KIND and drop.can_collect(LooseDrop.POLICY_DIVINE) \
				and World.grid.dist_sq(cell, drop.cell) <= radius * radius:
			return true
	return false


func collect_essence_near(cell: int, radius: int) -> int:
	if not World.grid.is_valid_index(cell):
		return 0
	var collected := 0
	var ids: Array[int] = []
	for drop: LooseDrop in loose_drops.values():
		if drop.kind == ESSENCE_KIND and drop.can_collect(LooseDrop.POLICY_DIVINE) \
				and World.grid.dist_sq(cell, drop.cell) <= radius * radius:
			ids.append(drop.id)
	for id in ids:
		var load := take_loose_drop(id, 0x7FFFFFFF, LooseDrop.POLICY_DIVINE)
		collected += int(load.get("amount", 0))
	return collected


func pack_loose_drops() -> Array[Dictionary]:
	var packed: Array[Dictionary] = []
	var ids := loose_drops.keys()
	ids.sort()
	for id in ids:
		var drop := loose_drop(int(id))
		if drop != null:
			packed.append(drop.to_dict())
	return packed


func restore_loose_drops(rows: Array, next_id: int) -> void:
	loose_drops.clear()
	_next_loose_drop_id = maxi(next_id, 1)
	for row in rows:
		if not row is Dictionary:
			continue
		var drop := LooseDrop.from_dict(row)
		if drop.id <= 0 or drop.amount <= 0 or not World.grid.is_valid_index(drop.cell):
			continue
		loose_drops[drop.id] = drop
		_next_loose_drop_id = maxi(_next_loose_drop_id, drop.id + 1)
	Events.loose_drops_changed.emit(-1)


func _step_loose_drops(delta: float) -> void:
	_loose_drop_timer += delta
	if _loose_drop_timer < LOOSE_DROP_STEP:
		return
	_loose_drop_timer = fmod(_loose_drop_timer, LOOSE_DROP_STEP)
	var changed := false
	for id in loose_drops.keys():
		var drop := loose_drop(int(id))
		if drop != null and drop.expired(Sim.tick):
			loose_drops.erase(id)
			changed = true
	var handled_essence: Dictionary = {}
	for b in buildings:
		if is_instance_valid(b) and b.state == Building.State.COMPLETE \
				and b.def.energy_capacity > 0 and b.def.energy_per_essence > 0 \
				and b.stored_energy < b.def.energy_capacity:
			changed = _attract_essence_to(b, handled_essence) or changed
	if changed:
		Events.loose_drops_changed.emit(-1)


func _attract_essence_to(collector: Building, handled: Dictionary) -> bool:
	var nearest: LooseDrop = null
	var nearest_dist := 0x7FFFFFFF
	var centre := collector.centre_cell()
	for drop: LooseDrop in loose_drops.values():
		if drop.kind != ESSENCE_KIND or not drop.can_collect(LooseDrop.POLICY_DIVINE):
			continue
		if handled.has(drop.id):
			continue
		var distance := World.grid.dist_sq(centre, drop.cell)
		if distance <= collector.def.energy_radius * collector.def.energy_radius \
				and distance < nearest_dist:
			nearest = drop
			nearest_dist = distance
	if nearest == null:
		return false
	handled[nearest.id] = true
	if nearest_dist <= ESSENCE_COLLECT_RADIUS * ESSENCE_COLLECT_RADIUS:
		var room_motes := (collector.def.energy_capacity - collector.stored_energy) \
			/ collector.def.energy_per_essence
		if room_motes <= 0:
			return false
		var load := take_loose_drop(nearest.id, room_motes, LooseDrop.POLICY_DIVINE)
		var motes := int(load.get("amount", 0))
		collector.stored_energy += motes * collector.def.energy_per_essence
		collector.queue_redraw()
		return motes > 0
	var old_cell := nearest.cell
	var from := World.grid.coord(old_cell)
	var toward := World.grid.coord(centre)
	var best := old_cell
	var best_dist := nearest_dist
	for y in range(-1, 2):
		for x in range(-1, 2):
			if x == 0 and y == 0:
				continue
			var candidate_coord := Vector2i(from.x + x, from.y + y)
			if not World.grid.is_valid_v(candidate_coord):
				continue
			var candidate := World.grid.index_v(candidate_coord)
			var distance := World.grid.dist_sq(candidate, centre)
			if distance < best_dist:
				best = candidate
				best_dist = distance
	if best == old_cell:
		return false
	nearest.cell = best
	Events.loose_drops_changed.emit(old_cell)
	Events.loose_drops_changed.emit(best)
	return true


func energy_available_near(cell: int) -> int:
	var total := 0
	for b in buildings:
		if is_instance_valid(b) and b.state == Building.State.COMPLETE \
				and b.def.energy_capacity > 0 and b.def.energy_radius > 0 \
				and World.grid.dist_sq(cell, b.centre_cell()) <= b.def.energy_radius * b.def.energy_radius:
			total += b.stored_energy
	return total


func draw_energy_near(cell: int, amount: int) -> bool:
	if amount <= 0:
		return true
	if energy_available_near(cell) < amount:
		return false
	var remaining := amount
	var collectors: Array[Building] = []
	for b in buildings:
		if is_instance_valid(b) and b.state == Building.State.COMPLETE \
				and b.def.energy_capacity > 0 and b.stored_energy > 0 \
				and World.grid.dist_sq(cell, b.centre_cell()) <= b.def.energy_radius * b.def.energy_radius:
			collectors.append(b)
	collectors.sort_custom(func(a: Building, b: Building) -> bool:
		return World.grid.dist_sq(cell, a.centre_cell()) < World.grid.dist_sq(cell, b.centre_cell()))
	for collector in collectors:
		var drawn := mini(remaining, collector.stored_energy)
		collector.stored_energy -= drawn
		remaining -= drawn
		collector.queue_redraw()
		if remaining <= 0:
			break
	return true


func nearest_storage_destination(from: int, kind: StringName) -> int:
	var best := -1
	var best_score := 0x7FFFFFFF
	for raw_cell in _storage_by_cell.keys():
		var cell := int(raw_cell)
		var b := storage_at(cell)
		if b == null or not b.accepts_resource(kind) or b.inventory_free() <= 0:
			continue
		if not DefenseControl.stockpile_accepts(cell, kind):
			continue
		var score := World.grid.dist_sq(from, cell) \
			- (DefenseControl.stockpile_priority(cell) - 1) * 400
		if score < best_score:
			best_score = score
			best = cell
	return best


func nearest_storage_source(from: int, kind: StringName) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for raw_cell in _storage_by_cell.keys():
		var cell := int(raw_cell)
		if amount_at(cell, kind) <= 0:
			continue
		var distance := World.grid.dist_sq(from, cell)
		if distance < best_dist:
			best_dist = distance
			best = cell
	var overflow_at := overflow_cell()
	if int(overflow.get(kind, 0)) > 0 and World.grid.is_valid_index(overflow_at):
		var overflow_dist := World.grid.dist_sq(from, overflow_at)
		if overflow_dist < best_dist:
			best = overflow_at
	return best


## Closest drop-off point to a villager. Returns -1 if the colony has nowhere to
## put anything, in which case gatherers simply hold their load.
func nearest_stockpile(from: int, kind: StringName = &"") -> int:
	if kind.is_empty():
		for candidate in KINDS:
			var cell := nearest_storage_destination(from, candidate)
			if cell != -1:
				return cell
		return -1
	return nearest_storage_destination(from, kind)


# --- Buildings ---------------------------------------------------------------------

func register_building(b: Node) -> void:
	if not b in buildings:
		buildings.append(b)
	mark_supply_requests_dirty()


func unregister_building(b: Node) -> void:
	buildings.erase(b)
	mark_supply_requests_dirty()
	# Destruction must release promised shelf stock immediately. A Worker may still be carrying
	# a load for this anchor; that load remains physical and falls back to ordinary hauling.
	refresh_supply_requests(true)


func building_covering(cell: int) -> Building:
	for candidate in buildings:
		var b := candidate as Building
		if b != null and is_instance_valid(b) and cell in b.cells:
			return b
	return null


# --- The Village Center -------------------------------------------------------------------

## The colony's development tier — the one dial the whole building list is gated behind.
##
## Read off whichever standing building declares the highest `center_tier` rather than looked up
## by id, so the Hearth is simply the tier-1 centre and its upgrades are tiers 2 and 3. A colony
## whose centre has been destroyed drops back to tier 1: the buildings already standing keep
## working, but nothing new from the upper list can go down until it is rebuilt.
func center_tier() -> int:
	var best := 1
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			var def: BuildingDef = b.def
			best = maxi(best, def.center_tier)
	return best


## Update 2d progression makes the Village Center and supporting buildings grant caps. The
## difficulty values remain hard safety ceilings for mobile scenarios, while the live cap is a
## visible colony statistic that can be raised through construction.
func building_cap() -> int:
	var base_by_tier: Array[int] = [0, 80, 120, 160]
	var tier := clampi(center_tier(), 1, base_by_tier.size() - 1)
	var cap := base_by_tier[tier]
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			cap += b.def.building_cap_bonus
	return mini(cap, Difficulties.max_player_buildings())


func workforce_cap() -> int:
	var base_by_tier: Array[int] = [0, 24, 44, 64]
	var tier := clampi(center_tier(), 1, base_by_tier.size() - 1)
	var cap := base_by_tier[tier]
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			cap += b.def.workforce_cap_bonus
	return mini(cap, Difficulties.max_villagers())


## Global bonuses use the strongest completed provider. Upgrade branches are alternatives, so
## stacking every copy would turn a layout choice into an exponential exploit.
func global_work_multiplier() -> float:
	var best := 1.0
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			best = maxf(best, b.def.global_work_speed_multiplier)
	return best


func global_build_multiplier() -> float:
	var best := 1.0
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			best = maxf(best, b.def.global_build_speed_multiplier)
	return best


func global_harvest_multiplier() -> float:
	var best := 1.0
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			best = maxf(best, b.def.harvest_speed_multiplier)
	return best


## Highest Temple tier standing. Gates PowerDef.required_temple_tier, so losing a Sanctum mid-run
## re-locks its abilities — which is what makes the Temple a building worth defending rather than
## a box to tick once.
func temple_tier() -> int:
	var best := 0
	for b in buildings:
		if is_instance_valid(b) and not b.is_site():
			var def: BuildingDef = b.def
			best = maxi(best, def.temple_tier)
	return best


# --- Upgrading and demolishing -------------------------------------------------------------

## Why this building can or cannot be upgraded, in the same shape check_placement returns.
##
## Split out from doing it so the selection card can show the cost and the reason greyed out.
## A button that is disabled with no explanation is indistinguishable from a broken one — the
## same rule the power bar already follows.
func upgrade_check(b: Node, next_id: StringName = &"") -> Dictionary:
	var result := {"ok": false, "reason": "", "def": null}
	if b == null or not is_instance_valid(b) or b.is_site():
		result["reason"] = tr(&"UPGRADE_NONE")
		return result

	# Pulled into a typed local first. `b` is a plain Node, so `b.def` arrives as a Variant and
	# every field read off it goes unchecked — the same trap that bit take_salvage_load.
	var current: BuildingDef = b.def
	var next: BuildingDef = null
	for option: BuildingDef in Buildings.upgrades_for(current.id):
		if next_id.is_empty() or option.id == next_id:
			next = option
			break
	if next == null:
		result["reason"] = tr(&"UPGRADE_NONE")
		return result
	result["def"] = next

	# Shard locks apply to upgrades too. Checked here rather than in Buildings.upgrade_for, because
	# a locked upgrade must still be FOUND — the end-of-run card offers it for purchase, and it
	# cannot offer something the catalog refuses to return. Without this an upgrade could be bought
	# with shards and then never gate anything, which is worse than not selling it at all.
	if next.unlock_cost > 0 and not Meta.is_unlocked(next.id):
		result["reason"] = L10n.t(&"UPGRADE_LOCKED", [next.unlock_cost])
		return result

	# A centre cannot gate its own upgrade — that would make tier 2 unreachable forever.
	if next.center_tier == 0 and next.tier > center_tier():
		result["reason"] = L10n.t(&"UPGRADE_NEEDS_TIER", [next.tier])
		return result
	if next.min_population > population():
		result["reason"] = L10n.t(&"UPGRADE_NEEDS_POP", [next.min_population])
		return result
	if next.footprint != current.footprint:
		# Content error rather than a player-facing state, but it must fail loudly here rather
		# than halfway through an upgrade the player has already paid for.
		push_warning("Upgrade %s -> %s changes footprint; refused" % [current.id, next.id])
		result["reason"] = tr(&"UPGRADE_NONE")
		return result
	if not can_afford(next.cost):
		result["reason"] = L10n.t(&"PLACE_NEED", [next.cost_text()])
		return result

	result["ok"] = true
	result["reason"] = next.cost_text()
	return result


## Choice-aware form used by the building card. Each branch preserves its own
## unlock, population and affordability reason.
func upgrade_checks(b: Node) -> Array[Dictionary]:
	var checks: Array[Dictionary] = []
	if b == null or not is_instance_valid(b) or b.is_site():
		return checks
	var current: BuildingDef = b.def
	for option: BuildingDef in Buildings.upgrades_for(current.id):
		checks.append(upgrade_check(b, option.id))
	return checks


## Begin an in-place upgrade. The cost is RESERVED, not spent, exactly as a fresh placement is —
## builders then haul it out to the building, which is why upgrading a remote outpost is slow.
func upgrade_building(b: Node, next_id: StringName = &"") -> bool:
	var check := upgrade_check(b, next_id)
	if not check["ok"]:
		return false
	var next: BuildingDef = check["def"]
	reserve(next.cost)
	if not b.begin_upgrade(next):
		unreserve(next.cost)
		return false
	Events.building_placed.emit(b)
	return true


## Tear a building down. A blueprint is cancelled outright; anything standing enters a teardown
## that a worker has to walk to and carry the salvage out of.
func demolish_building(b: Node) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	if not can_demolish(b):
		return false
	if b.state == Building.State.BLUEPRINT:
		b.destroy()
		return true
	return b.begin_demolish()


## The Village Center is not demolishable at any tier.
##
## Losing it ends the run (see Run._on_building_destroyed), so a demolish button on it is a button
## that deletes a six-hour game. Two-press confirmation is the right guard against mistapping a
## Watchtower; it is not enough of a guard against that.
func can_demolish(b: Node) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	var def: BuildingDef = b.def
	return def.center_tier == 0


## Why a building may or may not go here. Returns the per-cell verdict too, so the
## placement ghost can red-X the exact tiles that are the problem rather than just
## refusing and leaving the player to guess.
func check_placement(def: BuildingDef, anchor: int) -> Dictionary:
	var grid: Grid = World.grid
	var result := {"ok": false, "reason": "", "cells": PackedInt32Array(), "bad": {}}

	if def == null or not grid.is_valid_index(anchor):
		result["reason"] = tr(&"PLACE_OFF_MAP")
		return result
	if buildings.size() >= building_cap():
		result["reason"] = L10n.t(&"PLACE_BUILDING_CAP", [building_cap()])
		return result

	var cells := grid.footprint_cells(grid.coord(anchor), def.footprint)
	if cells.is_empty():
		result["reason"] = tr(&"PLACE_OFF_MAP")
		return result
	result["cells"] = cells

	# Gates checked before the ground is, because they are the answer to a different question.
	# "You have not raised the Great Hall yet" must not surface as "blocked ground" — the player
	# would go looking for a boulder that is not there.
	if not Buildings.unlocked_in_run(def):
		result["reason"] = L10n.t(&"PLACE_NEEDS_TIER", [def.tier, def.min_population]) \
			if def.min_population > 0 else L10n.t(&"PLACE_NEEDS_CENTER", [def.tier])
		return result

	var bad: Dictionary = {}
	var blocked := false
	var outside := false
	for cell in cells:
		# `claimed`, not `occupancy`: occupancy is only stamped when a building
		# completes, so testing it let the player stack a new blueprint on top of a
		# site still under construction — and on top of any finished building that
		# does not block movement.
		if World.claimed[cell] != 0:
			bad[cell] = true
			blocked = true
		elif def.bridges_water:
			if World.terrain[cell] != Terrain.Type.WATER or World.feature[cell] != Terrain.Feature.NONE:
				bad[cell] = true
		elif not Terrain.WALKABLE.get(World.terrain[cell], false):
			bad[cell] = true
		elif Terrain.blocks_building(World.feature[cell]):
			# blocks_building, not FEATURE_BLOCKS. Trees block MOVEMENT but a builder just clears
			# them — see Terrain.FEATURE_CLEARABLE, and place_building below, which levels them.
			# Testing the movement flag here would leave a wooded map with nowhere to build.
			bad[cell] = true
		elif World.blight[cell] > def.max_blight:
			bad[cell] = true
		elif not World.in_influence(cell):
			# Outside the sphere. Marked per-cell like every other verdict, so the placement ghost
			# red-Xes exactly the tiles that overhang the boundary rather than refusing the whole
			# footprint and leaving the player to shuffle it around blind.
			bad[cell] = true
			outside = true
	result["bad"] = bad

	if not bad.is_empty():
		# Naming the specific obstruction matters: "blocked ground" next to a half-built
		# hut reads as a bug, and the player has no way to tell that the site they are
		# aiming at is already spoken for.
		if blocked:
			result["reason"] = tr(&"PLACE_OCCUPIED")
		elif outside:
			result["reason"] = tr(&"PLACE_NO_INFLUENCE")
		else:
			result["reason"] = tr(&"PLACE_BLOCKED")
		return result
	if not can_afford(def.cost):
		result["reason"] = L10n.t(&"PLACE_NEED", [def.cost_text()])
		return result

	result["ok"] = true
	result["reason"] = def.cost_text()
	return result


## Place a blueprint. The cost is RESERVED here, not spent — builders then physically
## carry the materials out to the site before any construction happens. That haul leg
## is what makes stockpile placement matter: a quarry twenty tiles from your only
## storehouse is slow to build near, and a forward stockpile fixes it.
func place_building(def: BuildingDef, anchor: int, parent: Node) -> Node:
	var check := check_placement(def, anchor)
	if not check["ok"]:
		return null
	reserve(def.cost)

	# Clear scenery under the footprint. Trees do not block placement, so without
	# this a hut would be raised straight through a wood.
	for cell in check["cells"]:
		World.clear_feature(cell)

	var scene: PackedScene = load("res://scenes/entities/building.tscn")
	var b: Node = scene.instantiate()
	b.setup(def, anchor)
	b.position = _building_origin(def, anchor)
	parent.add_child(b)
	Events.building_placed.emit(b)
	return b


func place_divine_construct(def: BuildingDef, anchor: int) -> Building:
	if def == null or not def.menu_hidden or _spawn_parent == null:
		return null
	var placed := place_building(def, anchor, _spawn_parent) as Building
	if placed != null:
		placed.complete()
	return placed


## Bottom-left corner of the footprint in world space — see Building's note on why
## the node sits at the base rather than the centre.
func _building_origin(def: BuildingDef, anchor: int) -> Vector2:
	var c: Vector2i = World.grid.coord(anchor)
	return Vector2(c.x * Grid.TILE_SIZE, (c.y + def.footprint.y) * Grid.TILE_SIZE)


## Nearest unfinished site a builder could claim. A site still waiting on materials
## that the colony cannot supply is skipped, so builders do not stand around
## guarding a blueprint they have no way to finish.
func nearest_build_site(from: int) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or not b.is_site():
			continue
		if not is_claimable(b.anchor):
			continue
		if b.needs_materials() and not _can_supply(b):
			continue
		if not DefenseControl.allows_work(b.anchor):
			continue
		var d := World.grid.dist_sq(from, b.anchor)
		if d < best_dist:
			best_dist = d
			best = b
	return best


## Is there anything on the shelves that this site is still waiting for? The
## reservation was made at placement, so the stock is there unless it has since been
## eaten or the storehouse was destroyed.
func _can_supply(b: Node) -> bool:
	var kind: StringName = b.next_needed()
	return kind != &"" and stock.get(kind, 0) > 0


func site_count() -> int:
	var n := 0
	for b in buildings:
		if is_instance_valid(b) and b.is_site():
			n += 1
	return n


# --- Food ------------------------------------------------------------------------------

func has_food() -> bool:
	return amount_of(&"food") > 0 or amount_of(&"rations") > 0


## Take a meal from the stores. Returns how much was actually eaten, which may be
## less than asked for — a colony with two food left should still get two food of
## relief rather than nothing.
func consume_food(amount: int) -> int:
	var source := nearest_food_source(World.keep_cell)
	return consume_food_at(source, amount) if source != -1 else 0


func consume_food_at(cell: int, amount: int) -> int:
	var remaining := maxi(amount, 0)
	var raw_taken := withdraw_at(cell, &"food", mini(remaining, amount_at(cell, &"food")))
	if raw_taken > 0:
		remaining -= raw_taken
	if remaining <= 0:
		return amount
	# One preserved ration supplies two raw-food units. Spending rounds up, while
	# the returned nourishment never exceeds the meal that was requested.
	var ration_taken := withdraw_at(cell, &"rations",
		mini(ceili(float(remaining) / 2.0), amount_at(cell, &"rations")))
	if ration_taken > 0:
		remaining = maxi(remaining - ration_taken * 2, 0)
	return amount - remaining


# --- Water --------------------------------------------------------------------------------

## Nearest place a villager can drink: a well if one is closer, otherwise the shore.
##
## Water is deliberately NOT a stored resource. It is a place you go, which is what makes
## settling near water a real decision at the site picker and what gives the Well something
## to be for. Turning it into a number in the stockpile would collapse both.
func nearest_water_source(from: int) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF

	for b in buildings:
		if not is_instance_valid(b) or b.is_site() or not b.def.provides_water:
			continue
		var cell: int = b.work_cell()
		if cell == -1:
			continue
		if not DefenseControl.allows_civilian(cell):
			continue
		var d := World.grid.dist_sq(from, cell)
		if d < best_dist:
			best_dist = d
			best = cell

	# Frozen shores are not a water source. A well or cistern still is — which is what turns
	# "I have a river" from a permanent answer into a seasonal one. See Climate.FROZEN_SEASONS.
	if Climate.shores_frozen():
		return best

	# Shores are checked for walkability at query time: the index is built once per map, and
	# a building raised on the waterfront since then would have closed that cell off.
	for cell in World.shore_cells:
		if not World.is_walkable(cell):
			continue
		if not DefenseControl.allows_civilian(cell):
			continue
		var d := World.grid.dist_sq(from, cell)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


## Wells and cisterns are protected clean sources; an unbuilt shoreline is untreated water.
func water_source_is_clean(cell: int) -> bool:
	for b in buildings:
		if is_instance_valid(b) and not b.is_site() and b.def.provides_water \
				and b.work_cell() == cell:
			return true
	return false


## Water that survives a freeze: a well or a cistern, as opposed to the river.
##
## Distinct from has_water_access(), which counts the shore and is therefore true right up until
## the morning it is catastrophically not. This is the one the winter warning asks about.
func has_sheltered_water() -> bool:
	for b in buildings:
		if is_instance_valid(b) and not b.is_site() and b.def.provides_water:
			return true
	return false


func has_water_access() -> bool:
	return nearest_water_source(World.keep_cell) != -1


## Nearest stockpile that food can actually be eaten from. Food is a colony-wide
## pool rather than per-stockpile stock, so any drop-off point will do — the walk
## is the cost, not the logistics.
func nearest_food_source(from: int) -> int:
	var raw := nearest_storage_source(from, &"food")
	var ration := nearest_storage_source(from, &"rations")
	if raw == -1:
		return ration
	if ration == -1:
		return raw
	return raw if World.grid.dist_sq(from, raw) <= World.grid.dist_sq(from, ration) else ration


## Player-facing readiness score in the same rough units as a nightly threat budget.
## It is intentionally conservative: walls buy time, warriors and towers actually end a wave.
func defense_readiness() -> float:
	var score := 2.0
	score += float(headcount_of(&"warrior")) * 5.0
	for b in buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		var def: BuildingDef = b.def
		if def.attack_damage > 0.0:
			var sustained := def.attack_damage / maxf(def.attack_cooldown, 0.1)
			score += clampf(sustained * 0.7 + def.attack_range * 0.35, 2.0, 18.0)
		elif def.blocks_movement or def.blocks_monsters_only:
			score += clampf(def.max_hp / 100.0, 0.5, 4.0)
		if def.center_tier > 0:
			score += 3.0
	return score


# --- Building slots -----------------------------------------------------------------------

func _slot_users(ledger: Dictionary, b: Node) -> Array:
	var key := b.get_instance_id()
	if not ledger.has(key):
		ledger[key] = []
	# Prune dead occupants. Villagers can die or be freed mid-sleep, and a leaked
	# slot silently shrinks the colony's effective bed count for the rest of the run.
	var users: Array = ledger[key]
	var live: Array = []
	for u in users:
		if is_instance_valid(u):
			live.append(u)
	ledger[key] = live
	return live


func bed_free(b: Node) -> bool:
	return _slot_users(_bed_users, b).size() < b.def.sleep_slots


func claim_bed(b: Node, who: Object) -> bool:
	var users := _slot_users(_bed_users, b)
	if users.size() >= b.def.sleep_slots or who in users:
		return false
	users.append(who)
	return true


func release_bed(b: Node, who: Object) -> void:
	if b == null or not is_instance_valid(b):
		return
	_slot_users(_bed_users, b).erase(who)


## Nearest finished building with a spare bed.
func nearest_bed(from: int) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or b.is_site() or b.def.sleep_slots <= 0:
			continue
		if not bed_free(b):
			continue
		var d := World.grid.dist_sq(from, b.anchor)
		if d < best_dist:
			best_dist = d
			best = b
	return best


## Whether a worker of this job could start a shift here right now.
##
## The `job` argument is not optional in practice, and leaving it out was a real bug rather than a
## convenience. production_is_available() answers a WEAKER question without one — is the building
## finished, unpaused and staffed — while the worker's own tick asks the full question WITH the
## job: is there room in the output buffer, has the maintain-target already been met.
##
## When those two disagreed the villager claimed a slot the moment they released it: claim, walk
## nowhere, discover the shift is not actually available, release, claim again. A farmer whose
## barn was full stood on the spot doing that at 10 Hz for the rest of the run, never moving and
## never looking for other work. Both sides ask the same question now.
func workplace_free(b: Node, job: JobDef = null) -> bool:
	return b.staffing_is_available() and (b.production_paused or b.production_is_available(job)) \
		and _slot_users(_work_users, b).size() < b.effective_worker_slots()


func claim_workplace(b: Node, who: Object, job: JobDef = null) -> bool:
	var users := _slot_users(_work_users, b)
	if not b.staffing_is_available() \
			or (not b.production_paused and not b.production_is_available(job)) \
			or users.size() >= b.effective_worker_slots() \
			or who in users:
		return false
	users.append(who)
	return true


func release_workplace(b: Node, who: Object) -> void:
	if b == null or not is_instance_valid(b):
		return
	_slot_users(_work_users, b).erase(who)


## Nearest finished building that can staff this job. Matched on the building's workplace ROLE, so
## a Priest job naming `temple` is served by a Shrine, a Temple or a Sanctum alike — see
## BuildingDef.workplace_key.
func nearest_workplace(building_id: StringName, from: int, job: JobDef = null) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		var def: BuildingDef = b.def
		if def.workplace_key() != building_id:
			continue
		if not workplace_free(b, job):
			continue
		var d := World.grid.dist_sq(from, b.anchor)
		var score: int = d - (b.production_priority - 1) * 400
		if score < best_dist:
			best_dist = score
			best = b
	return best


## Nearest completed house regardless of whether every formal bed is occupied. A
## Village Center is the final fallback: it has no formal beds, but somebody with no
## hut should still walk home and get indoors instead of sleeping where night found them.
func nearest_shelter(from: int) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or b.is_site() \
				or (b.def.sleep_slots <= 0 and b.def.center_tier <= 0):
			continue
		var d := World.grid.dist_sq(from, b.anchor)
		if d < best_dist:
			best_dist = d
			best = b
	return best


func nearest_repair_target(from: int) -> Node:
	var best: Node = null
	var best_score := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or not b.needs_repair() or not is_claimable(b.anchor):
			continue
		if not DefenseControl.allows_work(b.anchor) or not can_afford(b.def.repair_cost):
			continue
		var score: int = World.grid.dist_sq(from, b.anchor) - (b.repair_priority - 1) * 400
		if score < best_score:
			best_score = score
			best = b
	return best


## Average mood across the colony, 0-100. Drives Faith generation.
func average_mood() -> float:
	if villagers.is_empty():
		return 0.0
	var total := 0.0
	var n := 0
	for v in villagers:
		if is_instance_valid(v) and v.alive:
			total += v.mood
			n += 1
	return total / float(n) if n > 0 else 0.0


# --- Claims ---------------------------------------------------------------------------

func is_claimable(cell: int) -> bool:
	if _claims.has(cell):
		# Stale claim from a villager who died or was reassigned — reclaim it
		# rather than leaving the resource locked out for the rest of the run.
		var owner: Object = _claims[cell]
		if not is_instance_valid(owner):
			_claims.erase(cell)
			return true
		return false
	return true


func claim(cell: int, who: Object) -> bool:
	# Re-claiming something you already hold succeeds. Without this a worker who leaves a job to
	# haul a load and comes back is refused by its own claim and wanders off instead — which is
	# exactly the loop demolition needs (work, carry a load away, return for the next one), and
	# which _try_claim_workplace had already been working around by hand.
	if _claims.get(cell) == who:
		return true
	if not is_claimable(cell):
		return false
	_claims[cell] = who
	return true


func release(cell: int, who: Object) -> void:
	if _claims.get(cell) == who:
		_claims.erase(cell)


func release_all_by(who: Object) -> void:
	for cell in _claims.keys():
		if _claims[cell] == who:
			_claims.erase(cell)
	for key in _patient_claims.keys():
		if _patient_claims[key] == who:
			_patient_claims.erase(key)


func nearest_patient(from: int, medic: Villager = null) -> Villager:
	var best: Villager = null
	var best_score := INF
	for candidate in villagers:
		var patient := candidate as Villager
		if patient == null or patient == medic or not patient.alive or not patient.needs_treatment():
			continue
		var key := patient.get_instance_id()
		if _patient_claims.has(key) and is_instance_valid(_patient_claims[key]):
			continue
		var urgency := (100.0 - patient.health) * 20.0 \
			+ (500.0 if patient.statuses.has(&"infected") else 0.0) \
			+ (300.0 if patient.statuses.has(&"poisoned") else 0.0)
		var score := float(World.grid.dist_sq(from, patient.cell())) - urgency
		if score < best_score:
			best_score = score
			best = patient
	return best


func claim_patient(patient: Villager, medic: Villager) -> bool:
	if patient == null or medic == null:
		return false
	var key := patient.get_instance_id()
	if _patient_claims.has(key) and is_instance_valid(_patient_claims[key]):
		return _patient_claims[key] == medic
	_patient_claims[key] = medic
	return true


func release_patient(patient: Villager, medic: Villager) -> void:
	if patient == null:
		return
	var key := patient.get_instance_id()
	if _patient_claims.get(key) == medic:
		_patient_claims.erase(key)


# --- Job quotas and assignment ----------------------------------------------------------

## A quota is a MINIMUM guarantee, not a cap. Surplus villagers fall through to the
## lowest-priority job rather than idling, which is what stops the colony looking
## broken whenever the player leaves a slider low.
func set_quota(job: StringName, headcount: int) -> void:
	quotas[job] = maxi(headcount, 0)
	Events.job_quotas_changed.emit()
	rebalance()


func quota_of(job: StringName) -> int:
	return quotas.get(job, 0)


func headcount_of(job: StringName) -> int:
	var n := 0
	for v in villagers:
		if is_instance_valid(v) and v.alive and v.job == job:
			n += 1
	return n


func population() -> int:
	# A dying agent remains in the scene tree until the end of the frame. Counting
	# the backing array therefore gave the final villager a one-frame "ghost life":
	# Run's deferred defeat check could run before _exit_tree erased them and never
	# receive another chance to end the run. Population is a gameplay fact, so count
	# living villagers rather than scene nodes awaiting deletion.
	var living := 0
	for villager in villagers:
		if is_instance_valid(villager) and villager.alive:
			living += 1
	return living


func worker_count() -> int:
	var adults := 0
	for villager in villagers:
		if is_instance_valid(villager) and villager.alive and villager.is_adult():
			adults += 1
	return adults


## Reconcile the roster against the player's quotas.
##
## Walks jobs in priority order and staffs each up to its quota, drawing first from
## the unassigned and then from jobs that are over their own quota. Candidates are
## chosen by proximity to the work, which on its own removes most of the "why is he
## walking across the entire map" behaviour that makes this genre's AI look stupid.
func rebalance() -> void:
	var jobs := Jobs.all()
	if jobs.is_empty():
		return

	var alive: Array = []
	for v in villagers:
		if is_instance_valid(v) and v.alive:
			alive.append(v)
	if alive.is_empty():
		return

	# Anyone the player has personally commanded is exempt — player intent outranks
	# the reconciler, though only until the command expires.
	var assignable: Array = []
	for v in alive:
		if v.is_adult() and not v.is_player_commanded():
			assignable.append(v)

	# Anyone holding a job whose workplace no longer exists is freed FIRST.
	#
	# Without this they keep the assignment, fail to find a workplace every think, and fall through
	# to _wander() — the colony looks fully employed while several people mill about doing nothing.
	# It is also the state a destroyed sawmill leaves behind, so it is not a hypothetical.
	for v in assignable:
		if v.job.is_empty():
			continue
		var held := Jobs.get_job(v.job)
		if held != null and not Jobs.has_workplace(held):
			v.set_job(&"")

	var anchor := _job_anchor()
	for job: JobDef in jobs:
		# Nothing to staff a job that has nowhere to be worked. Skipped rather than zeroed, so the
		# player's slider setting survives losing the building and comes back with it.
		if not Jobs.has_workplace(job):
			continue
		var want: int = quotas.get(job.id, 0)
		var have := 0
		for v in assignable:
			if v.job == job.id:
				have += 1
		if have >= want:
			continue

		var candidates: Array = []
		for v in assignable:
			if v.job == job.id:
				continue
			if v.job == &"":
				candidates.append(v)
			elif _is_over_quota(v.job, assignable):
				candidates.append(v)
		if candidates.is_empty():
			continue

		# Nearest to their own current cell is a decent proxy for "nearest to the
		# work" without running a search per candidate.
		var needed := want - have
		candidates.sort_custom(func(a, b) -> bool:
			return a.position.distance_squared_to(anchor) < \
				b.position.distance_squared_to(anchor))
		for i in mini(needed, candidates.size()):
			candidates[i].set_job(job.id)


func _is_over_quota(job: StringName, pool: Array) -> bool:
	var have := 0
	for v in pool:
		if v.job == job:
			have += 1
	return have > int(quotas.get(job, 0))


## Where work is centred. The keep for now; once work zones exist in M4 this
## becomes per-job so the reconciler can prefer people already near the quarry.
func _job_anchor() -> Vector2:
	return World.grid.to_world_index(World.keep_cell) if World.keep_cell != -1 else Vector2.ZERO
