extends Node
## Autoload: the survivors' side of the world — stockpiles, the villager roster,
## the job quotas the player sets on the Job Board, and the reservation ledger that
## stops two people walking to the same tree.

## Canonical resource kinds. StringName rather than an enum so content .tres files
## can name costs directly without depending on script-side enum ordering.
const KINDS: Array[StringName] = [&"wood", &"stone", &"food"]

## How often the labour reconciler runs, in seconds. Quotas are a coarse control;
## re-deriving assignments every tick would thrash villagers between jobs faster
## than they could walk anywhere.
const REBALANCE_INTERVAL := 1.0

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

	# Default staffing so a fresh run is doing something before the player opens
	# the board. An empty board on day one reads as a broken game, not a blank slate.
	for job: JobDef in Jobs.all():
		quotas[job.id] = 2


func step(delta: float) -> void:
	_rebalance_timer -= delta
	if _rebalance_timer <= 0.0:
		_rebalance_timer = REBALANCE_INTERVAL
		rebalance()


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


## Why a building may or may not go here. Returns the per-cell verdict too, so the
## placement ghost can red-X the exact tiles that are the problem rather than just
## refusing and leaving the player to guess.
func check_placement(def: BuildingDef, anchor: int) -> Dictionary:
	var grid: Grid = World.grid
	var result := {"ok": false, "reason": "", "cells": PackedInt32Array(), "bad": {}}

	if def == null or not grid.is_valid_index(anchor):
		result["reason"] = "off the map"
		return result

	var cells := grid.footprint_cells(grid.coord(anchor), def.footprint)
	if cells.is_empty():
		result["reason"] = "off the map"
		return result
	result["cells"] = cells

	var bad: Dictionary = {}
	for cell in cells:
		if World.occupancy[cell] != 0:
			bad[cell] = true
		elif not Terrain.WALKABLE.get(World.terrain[cell], false):
			bad[cell] = true
		elif Terrain.FEATURE_BLOCKS.get(World.feature[cell], false):
			bad[cell] = true
		elif World.blight[cell] > def.max_blight:
			bad[cell] = true
	result["bad"] = bad

	if not bad.is_empty():
		result["reason"] = "blocked ground"
		return result
	if not can_afford(def.cost):
		result["reason"] = "need %s" % def.cost_text()
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


## Nearest finished building of the given type with a spare work slot.
func nearest_workplace(building_id: StringName, from: int) -> Node:
	var best: Node = null
	var best_dist := 0x7FFFFFFF
	for b in buildings:
		if not is_instance_valid(b) or b.is_site() or b.def.id != building_id:
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
