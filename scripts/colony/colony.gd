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
	&"wood", &"stone", &"food",
	# Processed — a workplace turned raw material into something better. See JobDef.cycle_cost.
	&"boards", &"cut_stone",
	# Made — the gate to the upper half of the building list.
	&"tools",
]

## Groups for the resource readout, so eleven numbers do not arrive as one undifferentiated
## strip. Keys are locale keys; values are the kinds in display order.
const KIND_GROUPS: Array = [
	[&"GROUP_RAW", [&"wood", &"stone", &"food"]],
	[&"GROUP_PROCESSED", [&"boards", &"cut_stone"]],
	[&"GROUP_MADE", [&"tools"]],
]

## How often the labour reconciler runs, in seconds. Quotas are a coarse control;
## re-deriving assignments every tick would thrash villagers between jobs faster
## than they could walk anywhere.
const REBALANCE_INTERVAL := 1.0

const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")

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

## Materials promised to blueprints but not yet carried out to them. Placing a
## blueprint reserves its cost immediately, so the wood is visibly gone from your
## spendable total the moment you commit — otherwise you could queue five huts
## against one hut's worth of timber and only discover it when nothing got built.
var reserved: Dictionary = {}             ## StringName -> int
var quotas: Dictionary = {}               ## job id -> headcount the player wants
var villagers: Array = []
var buildings: Array = []

## Cells where gathered goods can be dropped off. The Hearth seeds this at run
## start; real stockpile buildings append to it in M4.
var stockpiles: PackedInt32Array = PackedInt32Array()

## cell -> villager currently working it. The single most visible "the AI is dumb"
## bug in this genre is five people converging on one tree, and this is what
## prevents it.
var _claims: Dictionary = {}

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
	reset()


func reset() -> void:
	stock.clear()
	reserved.clear()
	for k in KINDS:
		stock[k] = 0
		reserved[k] = 0
	quotas.clear()
	villagers.clear()
	buildings.clear()
	stockpiles = PackedInt32Array()
	_claims.clear()
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
	return total / float(_food_history.size())


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
		rate += float(workers) * per_worker_second * job.work_rate * FARM_DUTY_CYCLE
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
		return "no beds"
	if not has_water_access():
		return "no water"
	if food_days() < BIRTH_MIN_FOOD_DAYS:
		return "little food"
	if average_mood() < BIRTH_MIN_MOOD:
		return "unhappy"
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
	return float(amount_of(&"food")) / (per_second * Sim.cycle_seconds())


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
	if spawn_villager(cell) != null:
		Events.migrant_arrived.emit(cell)
		Events.notice.emit(tr(&"NOTICE_CHILD_BORN" if born else &"NOTICE_SURVIVOR_ARRIVES"), 0)


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
func spawn_villager(cell: int) -> Node:
	if _spawn_parent == null or not World.grid.is_valid_index(cell):
		return null
	var v: Villager = VILLAGER_SCENE.instantiate()
	v.position = World.grid.to_world_index(cell)
	_spawn_parent.add_child(v)
	return v


# --- Resources ---------------------------------------------------------------------

func add(kind: StringName, amount: int) -> void:
	stock[kind] = maxi(stock.get(kind, 0) + amount, 0)
	Events.resources_changed.emit(kind, stock[kind])


## What is actually spendable: on the shelf and not already promised elsewhere.
func available(kind: StringName) -> int:
	return maxi(stock.get(kind, 0) - reserved.get(kind, 0), 0)


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
	var taken := mini(amount, mini(stock.get(kind, 0), reserved.get(kind, 0)))
	if taken <= 0:
		return 0
	reserved[kind] = reserved.get(kind, 0) - taken
	add(kind, -taken)
	return taken


func spend(cost: Dictionary) -> bool:
	if not can_afford(cost):
		return false
	for kind: StringName in cost:
		add(kind, -int(cost[kind]))
	return true


func amount_of(kind: StringName) -> int:
	return stock.get(kind, 0)


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


## Closest drop-off point to a villager. Returns -1 if the colony has nowhere to
## put anything, in which case gatherers simply hold their load.
func nearest_stockpile(from: int) -> int:
	var best := -1
	var best_dist := 0x7FFFFFFF
	for cell in stockpiles:
		var d := World.grid.dist_sq(from, cell)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


# --- Buildings ---------------------------------------------------------------------

func register_building(b: Node) -> void:
	if not b in buildings:
		buildings.append(b)


func unregister_building(b: Node) -> void:
	buildings.erase(b)


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
func upgrade_check(b: Node) -> Dictionary:
	var result := {"ok": false, "reason": "", "def": null}
	if b == null or not is_instance_valid(b) or b.is_site():
		result["reason"] = tr(&"UPGRADE_NONE")
		return result

	# Pulled into a typed local first. `b` is a plain Node, so `b.def` arrives as a Variant and
	# every field read off it goes unchecked — the same trap that bit take_salvage_load.
	var current: BuildingDef = b.def
	var next := Buildings.upgrade_for(current.id)
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


## Begin an in-place upgrade. The cost is RESERVED, not spent, exactly as a fresh placement is —
## builders then haul it out to the building, which is why upgrading a remote outpost is slow.
func upgrade_building(b: Node) -> bool:
	var check := upgrade_check(b)
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
		elif not Terrain.WALKABLE.get(World.terrain[cell], false):
			bad[cell] = true
		elif Terrain.FEATURE_BLOCKS.get(World.feature[cell], false):
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
	return amount_of(&"food") > 0


## Take a meal from the stores. Returns how much was actually eaten, which may be
## less than asked for — a colony with two food left should still get two food of
## relief rather than nothing.
func consume_food(amount: int) -> int:
	var available := amount_of(&"food")
	var taken := mini(amount, available)
	if taken > 0:
		add(&"food", -taken)
	return taken


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
		var d := World.grid.dist_sq(from, cell)
		if d < best_dist:
			best_dist = d
			best = cell

	# Shores are checked for walkability at query time: the index is built once per map, and
	# a building raised on the waterfront since then would have closed that cell off.
	for cell in World.shore_cells:
		if not World.is_walkable(cell):
			continue
		var d := World.grid.dist_sq(from, cell)
		if d < best_dist:
			best_dist = d
			best = cell
	return best


func has_water_access() -> bool:
	return nearest_water_source(World.keep_cell) != -1


## Nearest stockpile that food can actually be eaten from. Food is a colony-wide
## pool rather than per-stockpile stock, so any drop-off point will do — the walk
## is the cost, not the logistics.
func nearest_food_source(from: int) -> int:
	return nearest_stockpile(from) if has_food() else -1


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


func workplace_free(b: Node) -> bool:
	return _slot_users(_work_users, b).size() < b.def.worker_slots


func claim_workplace(b: Node, who: Object) -> bool:
	var users := _slot_users(_work_users, b)
	if users.size() >= b.def.worker_slots or who in users:
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
func nearest_workplace(building_id: StringName, from: int) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		var def: BuildingDef = b.def
		if def.workplace_key() != building_id:
			continue
		if not workplace_free(b):
			continue
		var d := World.grid.dist_sq(from, b.anchor)
		if d < best_dist:
			best_dist = d
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
		if is_instance_valid(v) and v.job == job:
			n += 1
	return n


func population() -> int:
	return villagers.size()


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
		if not v.is_player_commanded():
			assignable.append(v)

	for job: JobDef in jobs:
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
			return a.position.distance_squared_to(_job_anchor()) < \
				b.position.distance_squared_to(_job_anchor()))
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
