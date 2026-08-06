class_name RateLedger
extends RefCounted
## Explains the four numbers that move on their own: food, water, mood and Faith.
##
## Two comments already in this codebase state the problem outright — Hud._refresh_resources
## and Divine.faith_multiplier both say "a number that silently depends on morale is
## indistinguishable from a broken one", which is why faith_multiplier() was exposed at all.
## The player could see `faith 42 (x1.3)` and had no way to learn what the 1.3 was made of.
## This is the other half of that fix.
##
## PULL, not push. Systems are not asked to register their contributions; the ledger asks them
## on demand and only when a panel is open. A push registry would need wiring in every producer
## and would silently drift the first time someone forgot to report — and a breakdown that
## disagrees with the number above it is worse than no breakdown.
##
## Terms are exact where the game is a formula (mood, Faith) and MEASURED where it is a stream
## of discrete events (food supply). See Colony's note on measured food flow for why.

## One line of a breakdown.
class Term extends RefCounted:
	var label: String
	var value: float
	## True for multiplicative terms, which display as "x1.53" rather than "+1.53".
	var is_factor: bool
	## Shown in the label as a count, e.g. "hungry (3)". Zero hides it.
	var count: int

	func _init(l: String, v: float, factor: bool = false, n: int = 0) -> void:
		label = l
		value = v
		is_factor = factor
		count = n

	func text() -> String:
		return label if count <= 0 else "%s (%d)" % [label, count]

	func amount_text() -> String:
		if is_factor:
			return "x%.2f" % value
		return "%+.2f" % value


## What a breakdown reports back.
class Report extends RefCounted:
	var title: String = ""
	## The headline figure the terms must add (or multiply) up to.
	var total: float = 0.0
	var total_text: String = ""
	## Extra context under the total — reserve runway, current value, whatever fits.
	var note: String = ""
	var terms: Array[Term] = []
	## False when the total is a bad thing, so the UI can colour it without knowing what it is.
	var healthy: bool = true


# --- Food ----------------------------------------------------------------------------------

## Stock with flow, so the useful headline is the NET rate and the reserve runway. "nine days
## of food" is immediately actionable; "+0.0203 per second" is not.
static func food() -> Report:
	var r := Report.new()
	r.title = L10n.t(&"LEDGER_FOOD")

	var demand := Colony.food_demand_per_second()
	var supply := Colony.food_supply_per_second()
	var net := supply - demand

	r.total = net
	r.total_text = L10n.t(&"LEDGER_PER_DAY", ["%+.1f" % (net * Sim.cycle_seconds())])
	r.healthy = net >= 0.0

	r.terms.append(Term.new(L10n.t(&"LEDGER_GATHERED"), supply * Sim.cycle_seconds()))
	r.terms.append(Term.new(L10n.t(&"LEDGER_EATEN"), -demand * Sim.cycle_seconds(), false, Colony.population()))

	var days := Colony.food_days()
	if net >= 0.0:
		r.note = L10n.t(&"LEDGER_IN_STORE_HOLDING", [Colony.amount_of(&"food")])
	elif days < 900.0:
		r.note = L10n.t(&"LEDGER_IN_STORE_DAYS", [Colony.amount_of(&"food"), "%.1f" % days])
	else:
		r.note = L10n.t(&"LEDGER_IN_STORE", [Colony.amount_of(&"food")])
	return r


# --- Water ---------------------------------------------------------------------------------

## Water is not a stock — it is a place you walk to — so there is nothing to run a flow on.
## What matters instead is whether the colony is KEEPING UP: if average hydration is sliding,
## the water is too far away and the answer is a well, not a bigger larder.
static func water() -> Report:
	var r := Report.new()
	r.title = L10n.t(&"LEDGER_WATER")

	var pop := 0
	var total := 0.0
	var parched := 0
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		pop += 1
		total += v.water
		if v.water < Villager.THIRST_URGENT:
			parched += 1

	var average := total / float(maxi(pop, 1))
	r.total = average
	r.total_text = L10n.t(&"LEDGER_AVERAGE", [int(average)])
	r.healthy = average >= Villager.THIRST_URGENT and Colony.has_water_access()

	if not Colony.has_water_access():
		r.note = L10n.t(&"LEDGER_NO_WATER")
		return r

	r.terms.append(Term.new(L10n.t(&"LEDGER_THIRSTY_NOW"), float(parched), false, parched))
	var source := Colony.nearest_water_source(World.keep_cell)
	if source != -1:
		var tiles := sqrt(float(World.grid.dist_sq(World.keep_cell, source))) / float(Grid.TILE_SIZE)
		r.terms.append(Term.new(L10n.t(&"LEDGER_TILES_TO_WATER"), tiles))
		r.note = L10n.t(&"LEDGER_WELL_HINT")
	return r


# --- Mood ----------------------------------------------------------------------------------

## Mood does not accumulate — it DRIFTS toward a target assembled from a handful of conditions,
## and those conditions are exactly the branches in Villager._decay_needs. Reporting the target
## and its parts is what tells the player which lever to pull.
##
## Each term is weighted by how many villagers it applies to, so the parts sum to the average
## target rather than to one villager's.
static func mood() -> Report:
	var r := Report.new()
	r.title = L10n.t(&"LEDGER_MOOD")

	var pop := 0
	var current := 0.0
	var hungry := 0
	var thirsty := 0
	var tired := 0
	var rough := 0
	var lit := 0
	var blighted := 0
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		pop += 1
		current += v.mood
		if v.food < Villager.HUNGER_URGENT:
			hungry += 1
		if v.water < Villager.THIRST_URGENT:
			thirsty += 1
		if v.rest < Villager.REST_URGENT:
			tired += 1
		if v.state == Villager.State.RESTING:
			rough += 1
		if Divine.is_within_ember(v.cell()):
			lit += 1
		if World.is_blighted(v.cell()):
			blighted += 1

	if pop == 0:
		r.total_text = "—"
		return r

	var n := float(pop)
	var target := Villager.MOOD_BASE
	target += Villager.MOOD_HUNGRY * float(hungry) / n
	target += Villager.MOOD_THIRSTY * float(thirsty) / n
	target += Villager.MOOD_TIRED * float(tired) / n
	target += Villager.MOOD_ROUGH * float(rough) / n
	target += Villager.MOOD_EMBER * float(lit) / n
	target += Villager.MOOD_BLIGHTED * float(blighted) / n
	target = clampf(target, 0.0, Villager.NEED_MAX)

	r.total = target
	r.total_text = L10n.t(&"LEDGER_DRIFTING_TO", [int(target)])
	r.healthy = target >= 50.0
	r.note = L10n.t(&"LEDGER_NOW", [int(current / n)])

	# Every term reads its weight from the same constant the sim uses. Duplicating the numbers
	# here is how a breakdown silently stops matching the total it is printed under.
	r.terms.append(Term.new(L10n.t(&"LEDGER_BASELINE"), Villager.MOOD_BASE))
	if hungry > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_HUNGRY"), Villager.MOOD_HUNGRY * float(hungry) / n, false, hungry))
	if thirsty > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_THIRSTY"), Villager.MOOD_THIRSTY * float(thirsty) / n, false, thirsty))
	if tired > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_EXHAUSTED"), Villager.MOOD_TIRED * float(tired) / n, false, tired))
	if rough > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_SLEEPING_ROUGH"),
			Villager.MOOD_ROUGH * float(rough) / n, false, rough))
	if lit > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_IN_EMBER"),
			Villager.MOOD_EMBER * float(lit) / n, false, lit))
	if blighted > 0:
		r.terms.append(Term.new(L10n.t(&"LEDGER_IN_BLIGHT"),
			Villager.MOOD_BLIGHTED * float(blighted) / n, false, blighted))
	return r


# --- Faith ---------------------------------------------------------------------------------

## Passive generation, plus what the library adds, minus what the abilities cost.
##
##     net = passive generation + Tome bonuses - total Burden
##
## This is the single most important breakdown in the game. A permanent negative Faith rate is
## unplayable unless the player can see every line item and decide what to shed — so a Burden
## system without this panel would be a trap rather than a decision, which is why the ledger was
## built before the Temple was.
static func faith() -> Report:
	var r := Report.new()
	r.title = L10n.t(&"LEDGER_FAITH")

	var pop := Colony.population()
	var mood_factor := clampf(Colony.average_mood() / 60.0, 0.15, 1.8) if pop > 0 else 0.0
	var pop_factor := clampf(sqrt(float(pop) / 6.0), 0.4, 2.2) if pop > 0 else 0.0
	var passive := Divine.FAITH_BASE_RATE * mood_factor * pop_factor
	var net := Divine.net_faith_rate()

	r.total = net
	r.total_text = L10n.t(&"LEDGER_PER_SECOND", ["%+.2f" % net])
	r.healthy = net > 0.0

	# Faith used to be purely multiplicative — base times mood times population — and the honesty
	# check was that those multiplied out to the total. With Tomes and Burden it is a SUM of three
	# things, one of which happens to be a product. So the contract is now:
	#
	#   * NON-FACTOR terms sum to the total. That is what the smoke test verifies.
	#   * FACTOR terms annotate the non-factor term that FOLLOWS them, explaining how it got there.
	#
	# Hence base, mood and population lead in as factors and `passive` carries the actual figure.
	# The base is no longer a plain row: it would be a fourth number that looks like it belongs in
	# the sum and does not, which is exactly the kind of quiet disagreement this panel exists to
	# prevent. The two factors are still read from the same constants faith_multiplier uses.
	r.terms.append(Term.new(L10n.t(&"LEDGER_FAITH_BASE"), Divine.FAITH_BASE_RATE, true))
	r.terms.append(Term.new(L10n.t(&"LEDGER_FAITH_MOOD"), mood_factor, true,
		int(Colony.average_mood())))
	r.terms.append(Term.new(L10n.t(&"LEDGER_FAITH_WORSHIPPERS"), pop_factor, true, pop))
	r.terms.append(Term.new(L10n.t(&"LEDGER_FAITH_PASSIVE"), passive))

	# Every installed Tome by name, with how much of it is left. A crumbling book that is about to
	# take its bonus with it has to be visible BEFORE it goes, or the rate drops for no reason the
	# player can see.
	for tome in Divine.tomes:
		if not tome.installed:
			continue
		r.terms.append(Term.new(
			L10n.t(&"LEDGER_TOME", [tome.label(), int(tome.durability)]), tome.rate()))

	# Every Burden, itemised. This is what the player reads to decide what to give back.
	for id in Divine.taken_up:
		var def := Powers.get_power(id)
		if def == null or def.burden <= 0.0:
			continue
		# L10n.label, not tr(): this whole class is static functions, and tr() is an Object method
		# with no `self` to resolve against. Exactly what L10n exists for.
		r.terms.append(Term.new(
			L10n.t(&"LEDGER_BURDEN", [L10n.label(def.display_name)]), -def.burden))
	for building in Colony.buildings:
		if not is_instance_valid(building) or building.is_site() \
				or building.def.faith_upkeep <= 0.0:
			continue
		r.terms.append(Term.new(
			L10n.t(&"LEDGER_UPKEEP", [L10n.label(building.def.display_name)]),
			-building.def.faith_upkeep))
	for golem in Colony.golems:
		if not is_instance_valid(golem) or not golem.alive:
			continue
		var def := Powers.get_power(golem.power_id)
		if def == null or def.upkeep <= 0.0:
			continue
		r.terms.append(Term.new(
			L10n.t(&"LEDGER_UPKEEP", [L10n.label(def.display_name)]), -def.upkeep))

	# A deficit reports its RUNWAY, not its rate. "three minutes until your powers go dark" is
	# actionable; "-0.31 per second" is arithmetic the player has to do themselves under pressure.
	var runway := Divine.faith_runway()
	if runway >= 0.0:
		r.note = L10n.t(&"LEDGER_FAITH_DRAINING",
			[int(Divine.faith), int(runway / 60.0), int(runway) % 60])
	elif Divine.faith >= Divine.faith_max():
		r.note = L10n.t(&"LEDGER_FAITH_FULL", [int(Divine.faith_max())])
	else:
		var seconds := (Divine.faith_max() - Divine.faith) / maxf(net, 0.0001)
		r.note = L10n.t(&"LEDGER_FAITH_FILLING",
			[int(Divine.faith), int(Divine.faith_max()), int(seconds)])
	return r


## Everything, in display order. What the breakdown panel iterates.
##
## Built by appending rather than returned as a literal: an untyped array literal will not
## satisfy an Array[Report] return type.
static func all() -> Array[Report]:
	var out: Array[Report] = []
	out.append(food())
	out.append(water())
	out.append(mood())
	out.append(faith())
	return out
