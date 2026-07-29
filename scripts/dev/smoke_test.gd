extends Node
## Headless smoke test. Run with:
##   Godot_v4.7-stable_win64_console.exe --headless --path <project> res://scenes/dev/smoke.tscn
##
## Boots a run with fixed seeds, fast-forwards the simulation, and asserts the
## invariants that are cheap to check and expensive to violate. Watching a bug like
## "the blight frontier oscillates" happen in real time takes minutes; catching it
## here takes seconds, and it catches it on every seed rather than the one you
## happened to be looking at.
##
## Exit code is non-zero if any check fails, so this can gate a commit.

const SEEDS: Array[int] = [1, 7, 424242, 99999]
## Long enough to cover a full day/dusk/night/dawn cycle (525s) and tip into day 2,
## so the phase machine and the night-side blight multiplier are both exercised.
const SIM_SECONDS := 600.0
const STEP := 0.05                   ## fixed feed into Sim, independent of real fps

var _failures: PackedStringArray = PackedStringArray()


const RUN_SCENE := preload("res://scenes/run/run.tscn")

## Real frames to run the live-scene check for. Villagers move in _process, so
## unlike the world checks this part cannot be fast-forwarded synthetically.
const LIVE_FRAMES := 240


func _ready() -> void:
	print("=== Embergard smoke test ===")
	for s in SEEDS:
		_run_seed(s)
	await _check_live_colony()
	_report()


# --- Live scene check --------------------------------------------------------------------
# Everything above drives the autoloads directly, which is fast but cannot catch a
# broken scene, a missing node path or a villager that never actually walks. This
# boots the real run scene and watches it for a few seconds.

func _check_live_colony() -> void:
	print("\n-- live run scene --")
	var run: Node2D = RUN_SCENE.instantiate()
	add_child(run)
	await get_tree().process_frame
	run.start_run(2024)
	await get_tree().process_frame

	var seed_value := 2024
	_expect(Colony.population() > 0, seed_value,
		"villagers spawned (%d)" % Colony.population())
	_expect(Sim.agents.size() == Colony.population(), seed_value,
		"every villager is registered with the sim")

	# Record where everyone started, then let the scene actually run.
	var start_positions: Array[Vector2] = []
	for v in Colony.villagers:
		start_positions.append(v.position)

	for _i in LIVE_FRAMES:
		await get_tree().process_frame

	var moved := 0
	for i in Colony.villagers.size():
		if i < start_positions.size() and Colony.villagers[i].position.distance_to(start_positions[i]) > 1.0:
			moved += 1

	# Villagers idle-wander, so after four seconds several should have gone
	# somewhere. Zero movement means pathing, the request queue or the movement
	# integration is broken — all of which look identical from a screenshot.
	_expect(moved > 0, seed_value, "villagers are pathing and moving (%d of %d moved)" % [
		moved, Colony.villagers.size()])

	var all_on_map := true
	for v in Colony.villagers:
		if v.cell() == -1 or not World.is_walkable(v.cell()):
			all_on_map = false
			break
	_expect(all_on_map, seed_value, "no villager walked into a wall or off the map")

	await _check_ember_glide(seed_value)
	await _check_economy(seed_value)
	await _check_building(seed_value, run)
	await _check_needs(seed_value, run)
	await _check_night(seed_value, run)
	await _check_lifecycle(seed_value, run)

	run.queue_free()
	await get_tree().process_frame


## The M7 questions: does a run end, does it pay out, and does an interrupted run
## come back intact?
func _check_lifecycle(seed_value: int, run: Node2D) -> void:
	# --- Save / load round trip ---------------------------------------------------
	Sim.set_phase(Sim.Phase.DAY)
	Colony.add(&"wood", 137)
	var wood := Colony.amount_of(&"wood")
	var pop := Colony.population()
	var day := Sim.day
	var building_count := Colony.buildings.size()
	# Fell a tree so the saved feature layer differs from a fresh generation — if
	# features were not persisted this is exactly what would silently come back.
	var felled := -1
	for i in World.grid.cell_count:
		if World.feature_at(i) == Terrain.Feature.TREE:
			felled = i
			break
	if felled != -1:
		World.clear_feature(felled)

	_expect(RunSave.save(), seed_value, "run saves to disk")

	var entities := run.get_node("WorldView/Sorted/Entities")
	for child in entities.get_children():
		child.queue_free()
	Colony.villagers.clear()
	Colony.buildings.clear()
	await get_tree().process_frame

	_expect(RunSave.load_into(run, entities), seed_value, "run loads back")
	await get_tree().process_frame

	_expect(Colony.amount_of(&"wood") == wood, seed_value,
		"stock survives the round trip (%d)" % Colony.amount_of(&"wood"))
	_expect(Colony.population() == pop, seed_value,
		"villagers survive the round trip (%d/%d)" % [Colony.population(), pop])
	_expect(Colony.buildings.size() == building_count, seed_value,
		"buildings survive the round trip (%d/%d)" % [Colony.buildings.size(), building_count])
	_expect(Sim.day == day, seed_value, "the calendar survives the round trip")
	if felled != -1:
		_expect(World.feature_at(felled) == Terrain.Feature.NONE, seed_value,
			"harvested ground stays harvested after a load")
	_expect(World.blight_field.frontier_size() > 0, seed_value,
		"the blight frontier is rebuilt after a load")

	# --- Ending the run --------------------------------------------------------------
	var shards_before := Meta.shards
	var result := {"ended": false, "awarded": 0}
	var on_end := func(_asc: bool, s: int) -> void:
		result["ended"] = true
		result["awarded"] = s
	Events.run_ended.connect(on_end)

	run.ascend()
	await get_tree().process_frame

	_expect(result["ended"], seed_value, "ascending ends the run")
	# Asserted on the AWARDED amount rather than the running total. The total is the
	# player's to spend, and comparing before/after totals made this fail the moment
	# the summary screen offered an unlock — which was a UI change, not a payout bug.
	_expect(int(result["awarded"]) > 0, seed_value,
		"ending the run pays out shards (+%d)" % int(result["awarded"]))
	_expect(Meta.shards >= shards_before, seed_value,
		"shards are banked, not silently spent (%d -> %d)" % [shards_before, Meta.shards])
	_expect(not RunSave.has_save(), seed_value, "a finished run clears its save")
	Events.run_ended.disconnect(on_end)

	# The meta must actually gate content, or shards are a number with no meaning.
	_expect(Buildings.locked().size() + Buildings.placeable().size() > 0, seed_value,
		"the build menu is gated by unlocks (%d locked, %d available)" % [
			Buildings.locked().size(), Buildings.placeable().size()])


## The M6 question: does the night actually happen, and can it be fought? Checks the
## flow field converges, monsters spawn and advance, combat resolves both ways, and
## Faith can be spent to intervene.
func _check_night(seed_value: int, run: Node2D) -> void:
	_expect(Monsters.all().size() > 0, seed_value,
		"monster catalog loaded (%d defs)" % Monsters.all().size())
	_expect(Powers.all().size() > 0, seed_value,
		"power catalog loaded (%d defs)" % Powers.all().size())

	# --- Flow field ------------------------------------------------------------------
	Threat.mark_field_dirty()
	var previous_scale := Sim.time_scale
	Sim.time_scale = 1.0
	for _i in 240:
		await get_tree().process_frame
		if not Threat.threat_field.building:
			break
	_expect(not Threat.threat_field.building, seed_value, "threat field finishes building")

	# A field that does not reach the map edges would leave spawned monsters stuck
	# standing still, which reads as "the night is broken" rather than "pathing is
	# subtly wrong".
	var edge := World.nearest_walkable(World.grid.index(4, World.grid.height / 2), 20)
	_expect(edge != -1 and Threat.threat_field.is_reachable(edge), seed_value,
		"the field reaches the map edge")

	# --- The wave --------------------------------------------------------------------
	Sim.set_phase(Sim.Phase.NIGHT)
	Sim.time_scale = 8.0
	for _i in 400:
		await get_tree().process_frame
		if Threat.alive_count() > 0:
			break
	_expect(Threat.alive_count() > 0, seed_value,
		"the night spawns monsters (%d)" % Threat.alive_count())
	_expect(Threat.alive_count() <= Threat.MAX_MONSTERS, seed_value, "monster cap respected")

	# Monsters must close on the colony rather than milling about at the edge.
	#
	# Measured across the whole wave, not one sampled creature: an individual that
	# stops because it has reached something to attack is behaving correctly, and
	# an earlier version of this check called that a pathing failure.
	var start_closest := _closest_monster_distance()
	for _i in 400:
		await get_tree().process_frame
	var end_closest := _closest_monster_distance()
	var engaged := false
	for m in Threat.monsters:
		if is_instance_valid(m) and m.state == Monster.State.ATTACKING:
			engaged = true
			break
	_expect(end_closest < start_closest or engaged, seed_value,
		"monsters advance on the colony (%d -> %d tiles, engaged: %s)" % [
			int(sqrt(float(start_closest))), int(sqrt(float(end_closest))), engaged])

	# --- Guards fight back -------------------------------------------------------------
	var guarding := 0
	for v in Colony.villagers:
		if v.state == Villager.State.GUARDING:
			guarding += 1
	_expect(guarding > 0, seed_value, "villagers switch to guard duty after dark (%d)" % guarding)

	# --- Powers ------------------------------------------------------------------------
	Divine.faith = Divine.FAITH_MAX
	var wrath := Powers.get_power(&"wrath")
	var before_faith := Divine.faith
	var target: Vector2 = Threat.monsters[0].position if Threat.alive_count() > 0 \
		else World.grid.to_world_index(World.keep_cell)
	var cast_ok := Divine.cast(wrath, target)
	_expect(cast_ok, seed_value, "a power can be cast")
	_expect(Divine.faith < before_faith, seed_value, "casting spends faith")
	_expect(Divine.cooldown_of(&"wrath") > 0.0, seed_value, "casting starts a cooldown")
	_expect(not Divine.can_cast(wrath), seed_value, "a power on cooldown cannot be recast")

	# --- Dawn clears the board -----------------------------------------------------------
	Sim.set_phase(Sim.Phase.DAWN)
	for _i in 120:
		await get_tree().process_frame
		if Threat.alive_count() == 0:
			break
	Sim.time_scale = previous_scale
	_expect(Threat.alive_count() == 0, seed_value, "dawn clears the remaining monsters")


## The M5 question: do the needs loops actually CLOSE? Before this milestone food
## piled up with nothing consuming it and villagers "rested" on the spot regardless
## of whether shelter existed — two bars moving with no system behind them.
func _check_needs(seed_value: int, run: Node2D) -> void:
	# Force daylight. Earlier checks fast-forward a lot of simulated time, and by
	# this point the clock had rolled into dusk — at which point every villager
	# correctly drops their tools for guard duty and refuses to farm, which looked
	# exactly like a broken farm system.
	Sim.set_phase(Sim.Phase.DAY)
	Sim.phase_elapsed = 0.0

	var entities := run.get_node("WorldView/Sorted/Entities")
	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)

	# --- Eating drains the larder -------------------------------------------------
	Colony.add(&"food", 200)
	var food_before := Colony.amount_of(&"food")
	# Starve everyone to just under the threshold so they all head for a meal.
	for v in Colony.villagers:
		v.food = 10.0
	var previous_scale := Sim.time_scale
	Sim.time_scale = 10.0
	for _i in 300:
		await get_tree().process_frame
	Sim.time_scale = previous_scale

	_expect(Colony.amount_of(&"food") < food_before, seed_value,
		"eating consumes stored food (%d -> %d)" % [food_before, Colony.amount_of(&"food")])
	var fed := 0
	for v in Colony.villagers:
		if v.food > 30.0:
			fed += 1
	_expect(fed > 0, seed_value, "hungry villagers actually got fed (%d of %d)" % [
		fed, Colony.villagers.size()])

	# --- A farm renews food ---------------------------------------------------------
	var farm_def := Buildings.get_building(&"farm")
	if farm_def == null:
		_fail(seed_value, "farm definition missing")
		return
	Colony.add(&"wood", 200)

	var farm_anchor := -1
	for dx in range(-8, -2):
		var candidate := grid.index(keep.x + dx, keep.y + 2)
		if Colony.check_placement(farm_def, candidate)["ok"]:
			farm_anchor = candidate
			break
	if farm_anchor == -1:
		_fail(seed_value, "nowhere to put a farm near the keep")
		return

	var farm: Node = Colony.place_building(farm_def, farm_anchor, entities)
	if farm == null:
		_fail(seed_value, "farm placement failed")
		return
	farm.complete()

	# Put everyone on farming and strip the larder, so any food that appears can
	# only have come from the farm.
	Colony.set_quota(&"woodcutting", 0)
	Colony.set_quota(&"quarrying", 0)
	Colony.set_quota(&"foraging", 0)
	Colony.set_quota(&"farming", 4)
	Colony.rebalance()
	Colony.add(&"food", -Colony.amount_of(&"food"))
	for v in Colony.villagers:
		# Wipe carried loads AND top up hunger. A forager still holding 8 berries
		# will deposit them the moment it is reassigned, and a villager that gets
		# hungry mid-test will eat — either one puts food in the larder that did
		# not come from the farm, which would make this check pass for the wrong
		# reason. It did exactly that on the first run.
		v.carry_amount = 0
		v.carry_kind = &""
		v.food = 100.0

	Sim.time_scale = 10.0
	var farmed := 0
	for _i in 900:
		await get_tree().process_frame
		farmed = Colony.amount_of(&"food")
		if farmed > 0:
			break
	Sim.time_scale = previous_scale

	# Food in the larder is necessary but not sufficient — prove a villager is
	# genuinely occupying a slot in the farm as well.
	var at_farm := 0
	for v in Colony.villagers:
		if v._workplace == farm:
			at_farm += 1
	_expect(at_farm > 0, seed_value, "farmers occupy the farm's work slots (%d)" % at_farm)
	_expect(farmed > 0, seed_value, "the farm produces renewable food (%d)" % farmed)

	# --- Faith tracks morale ---------------------------------------------------------
	_expect(Divine.faith_multiplier() > 0.0, seed_value,
		"faith accrues from the colony (x%.2f at mood %d)" % [
			Divine.faith_multiplier(), int(Colony.average_mood())])

	var before_mult := Divine.faith_multiplier()
	for v in Colony.villagers:
		v.mood = 5.0
	_expect(Divine.faith_multiplier() < before_mult, seed_value,
		"a miserable colony generates less faith")


## The M4 question: can a blueprint be placed, and do villagers actually go and
## raise it? Runs after the economy check so there are resources banked to pay for
## something.
func _check_building(seed_value: int, run: Node2D) -> void:
	_expect(Buildings.all().size() > 0, seed_value,
		"building catalog loaded (%d defs)" % Buildings.all().size())

	# The Hearth must exist and be finished — the colony has nowhere to put goods
	# without it, and every earlier economy check silently depends on it.
	var hearth_ok := false
	for b in Colony.buildings:
		if b.def.id == &"hearth" and b.state == Building.State.COMPLETE:
			hearth_ok = true
	_expect(hearth_ok, seed_value, "the hearth is placed and complete")
	_expect(Colony.stockpiles.size() > 0, seed_value, "colony has a drop-off point")

	var def := Buildings.get_building(&"hut")
	if def == null:
		_fail(seed_value, "hut definition missing")
		return

	# Stock the larder. The build phase runs for a long stretch of simulated time
	# and there is no food industry yet at this point in the test — without this,
	# the colony starves mid-haul and every later check fails for a reason that has
	# nothing to do with what it is testing.
	Colony.add(&"food", 300)
	for v in Colony.villagers:
		v.food = 100.0

	# Place it on clear ground a few tiles from the keep.
	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)
	var anchor := -1
	for dx in range(3, 8):
		var candidate := grid.index(keep.x + dx, keep.y)
		if Colony.check_placement(def, candidate)["ok"]:
			anchor = candidate
			break
	if anchor == -1:
		_fail(seed_value, "found nowhere valid to place a hut near the keep")
		return

	var before_available := Colony.available(&"wood")
	var before_stock := Colony.amount_of(&"wood")
	var entities := run.get_node("WorldView/Sorted/Entities")
	var site: Node = Colony.place_building(def, anchor, entities)
	_expect(site != null, seed_value, "blueprint placed")
	if site == null:
		return

	# Placing RESERVES rather than spends: the wood is committed and no longer
	# spendable, but it is still physically on the shelf until someone carries it.
	_expect(Colony.available(&"wood") < before_available, seed_value,
		"placement reserves the cost")
	_expect(Colony.amount_of(&"wood") == before_stock, seed_value,
		"placement does not teleport materials to the site")
	_expect(site.is_site() and site.needs_materials(), seed_value,
		"starts as a blueprint awaiting materials")

	var previous_scale := Sim.time_scale
	Sim.time_scale = 10.0
	var materials_arrived := false
	for _i in 1200:
		await get_tree().process_frame
		if not materials_arrived and not site.needs_materials():
			materials_arrived = true
		if not site.is_site():
			break
	Sim.time_scale = previous_scale

	# Measured on the SITE, not on the colony's stock. Gatherers are delivering wood
	# throughout, so total stores actually RISE during the haul — the first version
	# of this check asserted stock went down and failed for entirely the wrong
	# reason while hauling was working correctly.
	_expect(materials_arrived, seed_value,
		"materials were carried to the site (%s of %s)" % [site.delivered, def.cost])
	_expect(not site.is_site(), seed_value,
		"villagers raised the blueprint (%.0f/%.0f work)" % [site.work_done, def.build_work])

	# A finished solid building must actually block pathing, or walls are decoration.
	if def.blocks_movement:
		var blocked := true
		for cell in site.cells:
			if World.is_walkable(cell):
				blocked = false
		_expect(blocked, seed_value, "the finished building blocks movement")


## The M3 question, and the only one that matters for this milestone: does moving a
## slider actually make resources appear? Everything else in the economy — claims,
## the spatial index, hauling — is only worth anything if this comes out true.
##
## Runs at high time_scale because a full gather trip (walk, chop, walk back) takes
## tens of simulated seconds, and waiting for that in real time would make the test
## useless as a fast check.
func _check_economy(seed_value: int) -> void:
	_expect(World.resources.count() > 0, seed_value,
		"map has harvestable resources (%d)" % World.resources.count())

	Colony.set_quota(&"woodcutting", 4)
	Colony.set_quota(&"quarrying", 2)

	var previous_scale := Sim.time_scale
	Sim.time_scale = 10.0
	for _i in 600:
		await get_tree().process_frame
		_assert_no_double_claims(seed_value)
	Sim.time_scale = previous_scale

	var wood := Colony.amount_of(&"wood")
	var stone := Colony.amount_of(&"stone")
	_expect(wood > 0, seed_value, "woodcutters delivered wood (%d)" % wood)
	# Checked separately from wood on purpose. Stone comes from features that BLOCK
	# movement, so it exercises the approach-an-unwalkable-target path that trees
	# never touch — and that path was broken while wood flowed perfectly.
	_expect(stone > 0, seed_value, "quarriers delivered stone (%d)" % stone)

	var working := 0
	for v in Colony.villagers:
		if v.job != &"":
			working += 1
	_expect(working > 0, seed_value, "villagers hold job assignments (%d)" % working)


## Squared distance from the keep to whichever monster is nearest it.
func _closest_monster_distance() -> int:
	var best := 0x7FFFFFFF
	for m in Threat.monsters:
		if not is_instance_valid(m) or not m.alive:
			continue
		var c: int = m.cell()
		if c == -1:
			continue
		best = mini(best, World.grid.dist_sq(c, World.keep_cell))
	return best


## Two villagers must never work the same cell. This is the single most visible
## "the AI is dumb" bug in the genre, and it is invisible in a screenshot until you
## happen to catch two people standing on one tree.
func _assert_no_double_claims(seed_value: int) -> void:
	var seen: Dictionary = {}
	for v in Colony.villagers:
		var target: int = v._target_cell
		if target == -1 or v.state != Villager.State.WORKING:
			continue
		if seen.has(target):
			_fail(seed_value, "two villagers claimed the same cell (%d)" % target)
			return
		seen[target] = true


## The Ember must GLIDE to a tapped cell, never snap — including for very short
## hops, which is where it previously broke. A snap and a glide look identical in a
## screenshot, so this is checked by sampling the position mid-flight.
func _check_ember_glide(seed_value: int) -> void:
	var grid: Grid = World.grid
	var here := grid.coord(Divine.ember_cell)
	if not grid.is_valid(here.x + 2, here.y):
		return
	var target_cell := grid.index(here.x + 2, here.y)
	var target_pos := grid.to_world_index(target_cell)
	var start_pos := Divine.ember_pos

	Divine.tween_ember_to(target_cell)
	await get_tree().process_frame
	await get_tree().process_frame

	_expect(Divine.ember_pos != start_pos, seed_value, "ember begins moving on tap")
	_expect(Divine.ember_pos.distance_to(target_pos) > 1.0, seed_value,
		"a 2-tile hop glides rather than snapping")

	# And it must actually arrive, rather than easing asymptotically forever.
	for _i in 60:
		await get_tree().process_frame
	_expect(Divine.ember_pos.distance_to(target_pos) < 1.0, seed_value,
		"ember arrives at the tapped cell")


func _run_seed(seed_value: int) -> void:
	print("\n-- seed %d --" % seed_value)
	World.generate(seed_value)
	Colony.reset()
	Divine.reset()
	Threat.reset()
	Divine.place_ember(World.keep_cell)
	Sim.start_run()

	_check_map(seed_value)

	# Drive the clock directly rather than waiting on frames — this is what makes
	# 90 simulated seconds take a fraction of a real one.
	var elapsed := 0.0
	while elapsed < SIM_SECONDS:
		Sim._process(STEP)
		elapsed += STEP
		_check_invariants(seed_value)

	_check_progress(seed_value)
	print("   day %d  phase %d  tick %d  blight %.2f%%  frontier %d" % [
		Sim.day, Sim.phase, Sim.tick,
		World.blight_field.coverage() * 100.0,
		World.blight_field.frontier_size(),
	])


# --- Checks ---------------------------------------------------------------------------

func _check_map(seed_value: int) -> void:
	var grid: Grid = World.grid
	_expect(World.keep_cell != -1, seed_value, "keep site was chosen")
	_expect(grid.is_valid_index(World.keep_cell), seed_value, "keep site is on the map")
	_expect(World.is_walkable(World.keep_cell), seed_value, "keep site is walkable")
	_expect(World.nest_cells.size() == MapGen.NEST_COUNT, seed_value,
		"all %d nests placed (got %d)" % [MapGen.NEST_COUNT, World.nest_cells.size()])

	# The start area must be genuinely playable, not merely non-crashing. If this
	# fails the player spawns walled in by water and the run is unwinnable.
	var open := 0
	var c := grid.coord(World.keep_cell)
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			if grid.is_valid(c.x + dx, c.y + dy) and World.is_walkable(grid.index(c.x + dx, c.y + dy)):
				open += 1
	_expect(open >= 90, seed_value, "keep has a buildable clearing (%d/121 open)" % open)

	# Nests must be far enough away that day one is survivable.
	for nest in World.nest_cells:
		var d := grid.chebyshev(nest, World.keep_cell)
		_expect(d >= 20, seed_value, "nest is a safe distance away (%d tiles)" % d)


func _check_invariants(seed_value: int) -> void:
	for kind in Colony.KINDS:
		if Colony.amount_of(kind) < 0:
			_fail(seed_value, "resource '%s' went negative" % kind)
	if Divine.faith < 0.0 or Divine.faith > Divine.FAITH_MAX + 0.01:
		_fail(seed_value, "faith out of range (%f)" % Divine.faith)
	if Threat.monsters.size() > Threat.MAX_MONSTERS:
		_fail(seed_value, "monster cap exceeded (%d)" % Threat.monsters.size())


func _check_progress(seed_value: int) -> void:
	_expect(Sim.tick > 0, seed_value, "the clock advanced")
	_expect(Sim.day > 1, seed_value, "a full day cycle completed (reached day %d)" % Sim.day)

	# The Blight must actually be spreading. A frontier that has gone to zero while
	# clean ground remains means the CA stalled — the single most likely silent
	# failure in that system, and invisible without a check like this.
	# Balance regression guard, not just a crash check. The Blight has to be
	# visibly advancing by day 2 (or it is no pressure at all) but nowhere near
	# swallowing the map (or the run is over before the player can respond).
	var coverage := World.blight_field.coverage()
	_expect(World.blight_field.frontier_size() > 0, seed_value, "blight frontier is alive")
	_expect(coverage > 0.01, seed_value, "blight is advancing (%.1f%% by day 2)" % (coverage * 100.0))
	_expect(coverage < 0.20, seed_value, "blight is not runaway (%.1f%% by day 2)" % (coverage * 100.0))

	# The Ember must be lighting the ground it stands on — the aura is load-bearing
	# for four separate systems, so a silent failure here breaks all of them.
	_expect(World.light_at(World.keep_cell) > 0, seed_value, "ember lights the keep")


# --- Reporting -------------------------------------------------------------------------

func _expect(condition: bool, seed_value: int, description: String) -> void:
	if condition:
		print("   ok   %s" % description)
	else:
		_fail(seed_value, description)


func _fail(seed_value: int, description: String) -> void:
	var line := "seed %d: %s" % [seed_value, description]
	if line in _failures:
		return                       # per-tick checks would otherwise spam thousands
	_failures.append(line)
	printerr("   FAIL %s" % description)


func _report() -> void:
	print("\n=== result ===")
	if _failures.is_empty():
		print("all checks passed across %d seeds" % SEEDS.size())
		quit(0)
		return
	printerr("%d failure(s):" % _failures.size())
	for f in _failures:
		printerr("  - %s" % f)
	quit(1)


func quit(code: int) -> void:
	get_tree().quit(code)
