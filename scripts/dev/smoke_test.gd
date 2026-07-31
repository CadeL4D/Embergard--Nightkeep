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
## The tier every assertion in this file is calibrated against. Must be the neutral
## one — all of its multipliers are 1.0, so the numbers here are the real tuning
## numbers rather than a tier's view of them.
const TEST_DIFFICULTY := &"harried"
## Long enough to cover a full day/dusk/night/dawn cycle (465s) and tip into day 2,
## so the phase machine and the night-side blight multiplier are both exercised.
const SIM_SECONDS := 600.0
const STEP := 0.05                   ## fixed feed into Sim, independent of real fps

var _failures: PackedStringArray = PackedStringArray()
var _profile_snapshot: Dictionary = {}


const RUN_SCENE := preload("res://scenes/run/run.tscn")

## Real frames to run the live-scene check for. Villagers move in _process, so
## unlike the world checks this part cannot be fast-forwarded synthetically.
const LIVE_FRAMES := 240


func _ready() -> void:
	_profile_snapshot = {
		"shards": Meta.shards,
		"unlocked": Meta.unlocked.duplicate(),
		"ascension": Meta.ascension,
		"best_day": Meta.best_day,
		"runs_played": Meta.runs_played,
		"last_difficulty": Meta.last_difficulty,
		"run_history": Meta.run_history.duplicate(true),
		"lifetime_stats": Meta.lifetime_stats.duplicate(true),
		"achievements": Meta.achievements.duplicate(),
	}
	print("=== Embergard smoke test ===")
	# Pin the difficulty. Every balance assertion below is calibrated against the
	# baseline tier, and a run left on whatever the developer last played would fail
	# them for reasons that have nothing to do with the code under test.
	Difficulties.select(TEST_DIFFICULTY)
	print("difficulty: %s" % Difficulties.current_id())
	for s in SEEDS:
		_run_seed(s)
	print("\n-- localization --")
	_check_locale(SEEDS[0])
	print("\n-- Phase 5 polish --")
	_check_phase5(SEEDS[0])
	print("\n-- Phase 6 living world --")
	_check_phase6(SEEDS[0])
	print("\n-- migration and pacing --")
	_check_migration(SEEDS[SEEDS.size() - 1])
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
	run.start_run(2024, TEST_DIFFICULTY, true)
	var first_region := Realm.suggested_first_region()
	_expect(run.found_first_region(first_region), 2024,
		"the chosen Realm region opens as a local map")
	await get_tree().process_frame
	_expect(Colony.population() == 0 and not Sim.running, 2024,
		"choosing a region does not place the settlement automatically")
	var picker: CanvasLayer = run.get_node("SitePicker")
	_expect(picker.visible, 2024, "the local Hearth-site picker opens")
	run.get_node("RealmMap")._finish_first_selection()
	run.confirm_site(World.keep_cell)
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
	await _check_phase6_live(seed_value)
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
	Climate.set_mitigation(&"storm_ward", Sim.day + 3)
	var mitigation_until := int(Climate.mitigations.get("storm_ward", 0))
	var events_resolved := Storyteller.resolved_count
	# Fell a tree so the saved feature layer differs from a fresh generation — if
	# features were not persisted this is exactly what would silently come back.
	var felled := -1
	for i in World.grid.cell_count:
		if World.feature_at(i) == Terrain.Feature.TREE:
			felled = i
			break
	if felled != -1:
		World.clear_feature(felled)
	var wood_orders := DefenseControl.gathering_count(&"woodcutting")

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
	_expect(int(Climate.mitigations.get("storm_ward", 0)) == mitigation_until, seed_value,
		"weather preparations survive the round trip")
	_expect(Storyteller.resolved_count == events_resolved, seed_value,
		"storyteller history survives the round trip")
	_expect(DefenseControl.gathering_count(&"woodcutting") == wood_orders, seed_value,
		"gathering designations survive the round trip")
	if felled != -1:
		_expect(World.feature_at(felled) == Terrain.Feature.NONE, seed_value,
			"harvested ground stays harvested after a load")
	_expect(World.blight_field.frontier_size() > 0, seed_value,
		"the blight frontier is rebuilt after a load")

	# --- Ending the run --------------------------------------------------------------
	var shards_before := Meta.shards
	var history_before := Meta.run_history.size()
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
	_expect(Meta.run_history.size() == history_before + 1, seed_value,
		"the Chronicle records the finished world's seed and result")
	if not Meta.run_history.is_empty():
		_expect(int(Meta.run_history[0].get("seed", 0)) == Realm.world_seed, seed_value,
			"the recorded seed can recreate and share the same world")
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

	# Earlier live checks deliberately fast-forward the working day. On a slower
	# runner they remain in DAY; on a faster runner they can reach a natural night
	# before this isolated first-night check begins. Normalize the director and
	# clock so the assertion below always measures the night it names. Keep the
	# existing flow field: rebuilding the entire director here would also erase
	# the live colony's current navigation state, which this check needs.
	Sim.set_phase(Sim.Phase.DAY)
	for monster in Threat.monsters.duplicate():
		if is_instance_valid(monster):
			monster.queue_free()
	await get_tree().process_frame
	Threat.night_index = 0

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
	if not Colony.villagers.is_empty():
		Colony.villagers[0].set_job(&"warrior")
	Sim.set_phase(Sim.Phase.NIGHT)
	Sim.time_scale = 8.0
	for _i in 400:
		await get_tree().process_frame
		if Threat.alive_count() > 0:
			break
	_expect(Threat.alive_count() > 0, seed_value,
		"the night spawns monsters (%d)" % Threat.alive_count())
	_expect(Threat.alive_count() <= Threat.MAX_MONSTERS, seed_value, "monster cap respected")
	_expect(Threat.alive_count() <= Threat.body_cap_for_night(1), seed_value,
		"the first night respects its gentle body cap")

	var stayed_home := true
	for _i in 120:
		await get_tree().process_frame
		for monster in Threat.monsters:
			if not is_instance_valid(monster):
				continue
			if World.grid.dist_sq(monster.cell(), monster.home_cell) \
					> (Monster.WANDER_RADIUS + 1) * (Monster.WANDER_RADIUS + 1):
				stayed_home = false
	_expect(stayed_home, seed_value,
		"first-night monsters remain territorial around their corrupt camp")
	if Threat.alive_count() > 0:
		Threat.monsters[0].on_damaged(0.0, null)

	# A provoked monster must still close on the colony rather than forgetting the
	# interaction and returning to its camp.
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
		"a provoked monster advances on the colony (%d -> %d tiles, engaged: %s)" % [
			int(sqrt(float(start_closest))), int(sqrt(float(end_closest))), engaged])

	# --- Guards fight back -------------------------------------------------------------
	#
	# Sampled over a WINDOW, not at one instant, and this is the fix for a flake that had been
	# misreported as random noise for most of two sessions.
	#
	# The original counted GUARDING once. That was sound when nightfall recalled everybody, but Phase
	# 2 made the night deliberately non-uniform: warriors defend, and everyone else keeps working as
	# long as the ground they stand on is lit (Villager._works_after_dark). Add the villagers who are
	# legitimately eating, drinking or asleep at that moment and a count of zero is a perfectly
	# correct state for a six-person colony — so the assertion failed roughly one run in twenty on
	# behaviour that was working exactly as designed.
	#
	# What actually matters is that somebody takes up guard duty during the night, so that is what is
	# measured.
	var guarding := 0
	for _i in 90:
		await get_tree().process_frame
		var now := 0
		for v in Colony.villagers:
			if is_instance_valid(v) and v.state == Villager.State.GUARDING:
				now += 1
		guarding = maxi(guarding, now)
		if guarding > 0:
			break
	_expect(guarding > 0, seed_value,
		"villagers take up guard duty during the night (peak %d)" % guarding)

	# --- Powers ------------------------------------------------------------------------
	Divine.faith = Divine.faith_max()
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

	# --- Thirst is answered by walking, not by stock -------------------------------
	# Run this first: it needs villagers who are not already mid-errand, and unlike food
	# there is no resource to top up beforehand. If drinking does not work the colony dies
	# of dehydration a good deal faster than it starves.
	for v in Colony.villagers:
		v.water = 5.0
		v.food = 90.0
	var thirst_scale := Sim.time_scale
	Sim.time_scale = 10.0
	for _i in 400:
		await get_tree().process_frame
	Sim.time_scale = thirst_scale

	var drank := 0
	for v in Colony.villagers:
		if v.water > 40.0:
			drank += 1
	_expect(drank > 0, seed_value, "thirsty villagers reach water and drink (%d of %d)" % [
		drank, Colony.villagers.size()])

	# --- Eating drains the larder -------------------------------------------------
	Colony.add(&"food", 200)
	var food_before := Colony.amount_of(&"food")
	# Starve everyone to just under the threshold so they all head for a meal. Water is
	# topped up so thirst does not outrank hunger and invalidate the check below.
	for v in Colony.villagers:
		v.food = 10.0
		v.water = 90.0
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
		# Both needs, not just food: thirst outranks hunger and would pull farmers off the
		# field mid-check for a reason that has nothing to do with farming.
		v.food = 100.0
		v.water = 100.0

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
		v.water = 100.0

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

	# Ground held by an UNFINISHED site has to be off limits too. Occupancy is only
	# stamped on completion (builders must be able to walk onto the site), so a check
	# against occupancy alone happily let a second building be dropped on top of a
	# blueprint — two structures on one footprint, one of them unreachable.
	_expect(not Colony.check_placement(def, anchor)["ok"], seed_value,
		"cannot build on top of an unfinished site")

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
	_expect(DefenseControl.gathering_count(&"woodcutting") == 0 \
			and DefenseControl.gathering_count(&"quarrying") == 0,
		seed_value, "fresh field jobs have no automatic gathering orders")

	# Exercise the real brush once, then broaden the masks directly for this
	# time-compressed whole-economy check. The direct fill keeps the test from
	# spending hundreds of signal emissions painting a 112x112 map.
	var first_tree := -1
	for cell in World.grid.cell_count:
		if World.feature_at(cell) == Terrain.Feature.TREE:
			first_tree = cell
			break
	if first_tree != -1:
		DefenseControl.set_gather_mode(&"woodcutting")
		DefenseControl.paint_gather(first_tree)
		_expect(DefenseControl.gathering_is_designated(&"woodcutting", first_tree),
			seed_value, "the woodcutting brush marks a tree")
	DefenseControl.cancel_gather_paint()
	_designate_all_gathering()

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


func _designate_all_gathering() -> void:
	for job: JobDef in Jobs.all():
		if job.target_features.is_empty():
			continue
		var mask := PackedByteArray()
		mask.resize(World.grid.cell_count)
		for cell in World.grid.cell_count:
			if job.harvests(World.feature_at(cell)):
				mask[cell] = 1
		DefenseControl.gather_designations[job.id] = mask
	DefenseControl.changed.emit()


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


## Phase 0 systems: the Ward power, destructible nests, gates, difficulty tiers, the
## player-chosen keep site, and the two map-gen bugs that used to erase water and berries
## from the starting area.
## Phase 2's last four systems: the meta library, the enemy's settlement, the map size floor, and the
## dense-interior feature tiles.
func _check_phase2_tail(seed_value: int) -> void:
	# --- the meta library actually gates content ------------------------------------------
	# The failure this guards is specific and was real: exactly one building had a shard cost, a run
	# earned more than that, so after ONE run the summary said "everything is unlocked" forever.
	_expect(Unlocks.total() >= 8, seed_value,
		"the meta layer has enough to buy to outlast a few runs (%d items)" % Unlocks.total())
	_expect(Unlocks.total_cost() >= 600, seed_value,
		"buying everything takes many runs (%d shards)" % Unlocks.total_cost())
	_expect(Unlocks.duplicate_ids().is_empty(), seed_value,
		"no id is shared between a building and a power (Meta.unlocked is one flat list)")
	# Powers must be purchasable, not just buildings — that was the whole point of Unlocks.
	var power_offers := 0
	for def: PowerDef in Powers.all():
		if def.unlock_cost > 0:
			power_offers += 1
	_expect(power_offers > 0, seed_value, "powers are shard-purchasable too (%d)" % power_offers)

	# --- the map is small enough to read, and big enough to survive -------------------------
	# Both bounds are load-bearing. See World.MAP_WIDTH: below 112 the nest ring falls outside the
	# island's land radius, the fallback bunches every nest onto one position, and the colony is
	# wiped outright.
	_expect(World.MAP_WIDTH >= 112, seed_value,
		"the map is at least 112 wide, or the nest ring falls in open water (%d)" % World.MAP_WIDTH)
	_expect(MapGen.NEST_MIN_DIST >= 28, seed_value,
		"nests are far enough out to give the player warning (%d tiles)" % MapGen.NEST_MIN_DIST)
	var land_radius := 0.62 * float(World.MAP_WIDTH) * 0.5
	_expect(float(MapGen.NEST_MIN_DIST) < land_radius, seed_value,
		"the nest ring sits inside the coastline (%d vs ~%.0f)" % [
			MapGen.NEST_MIN_DIST, land_radius])

	# --- resources form connected masses ----------------------------------------------------
	# Connection masks only matter if generation actually makes solid interiors. If clumping is
	# too sparse, every mask is an isolated/rim shape and a wood becomes separate shrubs again.
	var interiors := 0
	for i in World.grid.cell_count:
		var f := World.feature[i]
		if f == Terrain.Feature.NONE or not TileAtlas.is_connected_feature(f):
			continue
		var c := World.grid.coord(i)
		var solid := true
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n := c + offset
			if World.grid.is_valid_v(n) and World.feature[World.grid.index_v(n)] != f:
				solid = false
				break
		if solid:
			interiors += 1
	_expect(interiors > 40, seed_value,
		"resource clumps have solid interiors to draw as a mass (%d cells)" % interiors)
	for f: int in TileAtlas.CONNECTED_FEATURE_ROWS:
		var seen_coords := {}
		for variant in TileAtlas.connected_variant_count(f):
			for mask in 16:
				var coords := TileAtlas.connected_coords(f, mask, variant)
				seen_coords[coords] = true
				_expect(coords.x >= 0 and coords.x < TileAtlas.COLUMNS
						and coords.y >= 0 and coords.y < TileAtlas.ROWS,
					seed_value, "feature %d mask %d variant %d is inside the atlas" % [
						f, mask, variant])
		_expect(seen_coords.size() == 16 * TileAtlas.connected_variant_count(f), seed_value,
			"feature %d has all connection masks and variants (%d)" % [f, seen_coords.size()])

	# --- the Blight builds -----------------------------------------------------------------
	_expect(BlightStructures.all().size() >= 3, seed_value,
		"the Blight has structures to raise (%d kinds)" % BlightStructures.all().size())
	var early := BlightStructures.roll(1)
	_expect(early == null, seed_value, "nothing is buildable on night 1")
	var later := BlightStructures.roll(9)
	_expect(later != null, seed_value, "something is buildable by night 9")

	# Raise one for real, next to a nest, and check every consequence.
	if later != null and not World.nest_cells.is_empty():
		var site := -1
		var near := World.grid.coord(World.nest_cells[0])
		for r in range(2, 7):
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					if site != -1:
						break
					var x := near.x + dx
					var y := near.y + dy
					if not World.grid.is_valid(x, y):
						continue
					var candidate := World.grid.index(x, y)
					if World.is_walkable(candidate) \
							and World.feature_at(candidate) == Terrain.Feature.NONE \
							and not World.has_blight_structure(candidate):
						site = candidate
			if site != -1:
				break

		if site == -1:
			_fail(seed_value, "nowhere to raise a Blight structure near a nest")
			return
		var before_threat := World.blight_threat_bonus()
		_expect(World.add_blight_structure(site, later), seed_value, "a Blight structure is raised")
		_expect(World.has_blight_structure(site), seed_value, "and the world knows it is there")
		# It has to be an OBSTACLE, or the enemy's village is scenery.
		_expect(not World.is_walkable(site), seed_value, "a Blight structure blocks the ground")
		_expect(World.blight_threat_bonus() > before_threat, seed_value,
			"it makes the night worse (%.1f -> %.1f)" % [
				before_threat, World.blight_threat_bonus()])

		# A glancing blow wounds it; enough damage levels it and gives the ground back.
		_expect(not World.damage_blight_structure(site, later.max_hp * 0.4), seed_value,
			"a glancing blow does not level it")
		_expect(World.damage_blight_structure(site, later.max_hp), seed_value,
			"enough damage levels it")
		_expect(not World.has_blight_structure(site), seed_value, "and it is gone")
		_expect(World.is_walkable(site), seed_value,
			"the ground it stood on opens up immediately")
		_expect(is_equal_approx(World.blight_threat_bonus(), before_threat), seed_value,
			"and it stops paying into the night the moment it falls")


func _check_phase0(seed_value: int) -> void:
	# --- content is actually on disk -----------------------------------------------------
	var ward := Powers.get_power(&"ward")
	_expect(ward != null, seed_value, "the Ward power exists")
	if ward != null:
		_expect(ward.kind == PowerDef.Kind.PURIFY, seed_value,
			"Ward is a PURIFY power, so _cast_purify is finally reachable")
	_expect(Buildings.get_building(&"gate") != null, seed_value, "the Gate building exists")
	_expect(Difficulties.all().size() >= 4, seed_value,
		"all four difficulty tiers load (got %d)" % Difficulties.all().size())

	# --- difficulty is neutral under test ------------------------------------------------
	_expect(is_equal_approx(Difficulties.threat_mult(), 1.0), seed_value,
		"the test tier is the neutral one, so the numbers below are the real ones")

	# --- gates: villager-passable, monster-blocked ---------------------------------------
	var gate_def := Buildings.get_building(&"gate")
	if gate_def != null:
		_expect(not gate_def.blocks_movement and gate_def.blocks_monsters_only, seed_value,
			"a gate blocks monsters without blocking villagers")

	# --- nests are destructible, and the reward is reachable ------------------------------
	_expect(World.live_nest_cells().size() == World.nest_cells.size(), seed_value,
		"every nest starts alive")
	if not World.nest_cells.is_empty():
		var nest: int = World.nest_cells[0]
		_expect(World.nest_hp.has(nest), seed_value, "a live nest has hit points")

		# A glancing blow wounds it but must not kill it, or NEST_HP means nothing.
		_expect(not World.damage_nest(nest, Terrain.NEST_HP * 0.5), seed_value,
			"half damage does not destroy a nest")
		_expect(World.is_nest(nest), seed_value, "a wounded nest is still standing")

		# The killing blow has to clear the feature, because that is what the end-of-run
		# tally and the spawn director both read.
		_expect(World.damage_nest(nest, Terrain.NEST_HP), seed_value,
			"enough damage destroys a nest")
		_expect(not World.is_nest(nest), seed_value, "a destroyed nest is gone from the map")
		_expect(not World.nest_hp.has(nest), seed_value, "a destroyed nest drops its hit points")
		_expect(World.live_nest_cells().size() == World.nest_cells.size() - 1, seed_value,
			"the threat director sees one fewer nest to spawn from")
		_expect(World.is_walkable(nest), seed_value, "the ground a nest stood on opens up")

		# Regenerate, because the checks after this one assume an untouched map.
		World.generate(seed_value)

	# --- the map-gen fixes ---------------------------------------------------------------
	# Berries used to be wiped inside KEEP_CLEAR_RADIUS, which stripped the only pre-farm
	# food source out of the starting area on every single seed.
	var grid: Grid = World.grid
	var berries := 0
	var stone_cells := 0
	for i in grid.cell_count:
		if World.feature_at(i) == Terrain.Feature.BERRIES:
			berries += 1
		elif World.feature_at(i) == Terrain.Feature.STONE:
			stone_cells += 1
	_expect(berries > 0, seed_value, "the map has berries on it (%d)" % berries)
	_expect(berries < 400, seed_value,
		"berry thickets stay compact rather than taking over the map (%d)" % berries)
	_expect(stone_cells >= 120, seed_value,
		"stone is distributed beyond the guaranteed quarry (%d cells)" % stone_cells)

	# Water used to be filled in out to radius 7, so a lakeside site had its lake paved
	# over. Only the pad is guaranteed dry now.
	var c := grid.coord(World.keep_cell)
	var pad_dry := true
	for dy in range(-MapGen.KEEP_PAD_RADIUS, MapGen.KEEP_PAD_RADIUS + 1):
		for dx in range(-MapGen.KEEP_PAD_RADIUS, MapGen.KEEP_PAD_RADIUS + 1):
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			var t := World.terrain_at(grid.index(c.x + dx, c.y + dy))
			if t == Terrain.Type.WATER or t == Terrain.Type.DEEP_WATER:
				pad_dry = false
	_expect(pad_dry, seed_value, "the keep pad is dry land")

	# --- a chosen site is honoured, and deterministic ------------------------------------
	var chosen := World.nearest_walkable(grid.index(c.x + 9, c.y + 9), 12)
	if chosen != -1:
		World.generate(seed_value, chosen)
		_expect(World.keep_cell == chosen, seed_value, "a chosen keep site is used")
		var first_nests := World.nest_cells.duplicate()
		World.generate(seed_value, chosen)
		_expect(World.nest_cells == first_nests, seed_value,
			"the same seed and site regenerate an identical map")
		World.generate(seed_value)


## Phase 1: the migration system, and the retuned threat curve.
##
## Migration is the keystone — before it existed every quantity in a run only went down — so
## it gets the most assertions of anything in this file. The gates matter as much as the
## growth: a colony with no beds or no food must NOT grow, or huts and farms stop being
## decisions again.
func _check_migration(seed_value: int) -> void:
	# Own setup and teardown: this check builds a hut, banks resources and admits a person,
	# all of which would poison anything measured afterwards. Runs once rather than per seed
	# because it exercises formulas, not map generation.
	Colony.reset()
	Colony.set_spawn_parent(self)
	Divine.reset()
	Divine.place_ember(World.keep_cell)
	for i in 2:
		var at := World.nearest_walkable(World.grid.index(
			World.grid.coord(World.keep_cell).x + i, World.grid.coord(World.keep_cell).y))
		if at != -1:
			Colony.spawn_villager(at)
	_expect(Colony.population() == 2, seed_value,
		"migration check seeded a colony (%d)" % Colony.population())

	# --- the threat curve is no longer a cliff -------------------------------------------
	# The old curve doubled every ~2.5 nights and hit 590 by night 20, five times over the
	# body cap. These bounds are deliberately loose — they are here to catch a return to
	# exponential growth, not to pin the tuning.
	Threat.pressure = 0.5
	var n10 := Threat.budget_for_night(10)
	var n20 := Threat.budget_for_night(20)
	_expect(n10 > Threat.budget_for_night(5), seed_value, "nights keep getting harder")
	_expect(n20 < n10 * 3.0, seed_value,
		"the threat curve is not exponential (night 10 %.0f, night 20 %.0f)" % [n10, n20])
	_expect(n20 < float(Threat.MAX_MONSTERS), seed_value,
		"night 20 fits inside the body cap rather than overflowing into invisible stats (%.0f)"
			% n20)

	# --- dead air -------------------------------------------------------------------------
	# is_dark() trips 60% through dusk, so the stretch where nobody works is the tail of dusk
	# plus the whole night. It used to be 216s of a 525s cycle — 41% of the game spent watching
	# a colony stand still. This guards the improvement; getting below ~25% needs the Warrior
	# job so that only warriors stop working.
	var cycle := Sim.cycle_seconds()
	# Explicitly typed: PHASE_DURATION is a Dictionary, so indexing it yields a Variant and the
	# parser will not infer a float from it.
	var dark: float = float(Sim.PHASE_DURATION[Sim.Phase.NIGHT]) \
		+ float(Sim.PHASE_DURATION[Sim.Phase.DUSK]) * 0.4
	_expect(dark / cycle < 0.33, seed_value,
		"the colony is idle for less than a third of the cycle (%.0f%%)" % (dark / cycle * 100.0))
	_expect(Sim.PHASE_DURATION[Sim.Phase.DAWN] >= 30.0, seed_value,
		"dawn is long enough to be a working morning (%.0fs)"
			% Sim.PHASE_DURATION[Sim.Phase.DAWN])

	# --- killing pays ----------------------------------------------------------------------
	for def: MonsterDef in Monsters.all():
		_expect(def.faith_on_death > 0.0, seed_value,
			"%s is worth faith to kill" % def.id)
	var faith_before := Divine.faith
	Divine.night_faith_earned = 0.0
	Divine.reward_kill(5.0)
	_expect(Divine.faith > faith_before, seed_value, "a kill grants faith")
	_expect(is_equal_approx(Divine.night_faith_earned, 5.0), seed_value,
		"kills are tallied for the dawn report")

	# --- the gates hold ------------------------------------------------------------------
	# No beds on a fresh map: the Hearth has no sleep slots, so nothing has been built that
	# anyone could sleep in.
	_expect(Colony.beds_free() == 0, seed_value, "a colony with no huts has no free beds")
	_expect(Colony.birth_blocker() != "", seed_value,
		"births stall with nowhere to sleep (%s)" % Colony.birth_blocker())

	# Give it beds but no food.
	var hut := Buildings.get_building(&"hut")
	if hut == null:
		return
	var anchor := World.nearest_walkable(World.grid.index(
		World.grid.coord(World.keep_cell).x + 4, World.grid.coord(World.keep_cell).y))
	Colony.add(&"wood", 500)
	var built: Node = Colony.place_building(hut, anchor, _spawn_root())
	_expect(built != null, seed_value, "a hut can be placed for the migration check")
	if built == null:
		return
	built.complete()

	_expect(Colony.beds_free() == hut.sleep_slots, seed_value,
		"a finished hut offers its beds (%d)" % Colony.beds_free())

	Colony.stock[&"food"] = 0
	_expect(Colony.birth_blocker() != "", seed_value,
		"births stall in a starving colony (%s)" % Colony.birth_blocker())

	# --- water is the third gate ----------------------------------------------------------
	# A generated island always has a coastline, so shore access should never be the thing
	# that blocks a run. If this fails, the shore index is broken rather than the map.
	_expect(World.shore_cells.size() > 0, seed_value,
		"the map has a drinkable shoreline (%d cells)" % World.shore_cells.size())
	_expect(Colony.has_water_access(), seed_value, "the colony can reach water")

	var well := Buildings.get_building(&"well")
	_expect(well != null, seed_value, "the Well building exists")
	if well != null:
		_expect(well.provides_water, seed_value, "a well provides water")

	# Now feed it. This must produce a positive rate, or the colony can never grow at all.
	Colony.add(&"food", 400)
	_expect(Colony.food_days() >= Colony.MIGRATION_MIN_FOOD_DAYS, seed_value,
		"400 food is more than a day's supply (%.1f days)" % Colony.food_days())
	_expect(Colony.birth_blocker() == "", seed_value,
		"a housed, fed, watered colony can grow (%.5f/s)" % Colony.birth_rate())

	# --- and it actually admits someone ---------------------------------------------------
	# Pushed clear of the target rather than to 0.999.
	#
	# Each birth needs a RANDOMISED amount of progress (0.75-1.35) so growth never lands on a beat
	# the player can count. This test used to assume the target was 1.0, which meant it passed on
	# whichever seeds happened to roll low and failed on the ones that rolled high — a genuinely
	# flaky assertion, and it was the game's anti-metronome design that was right, not the test.
	# Anything above the maximum target works on every seed, and the birth resets progress to zero
	# regardless of how far past it went.
	var before := Colony.population()
	Colony.migration_progress = 2.0
	Colony.step(1.0)
	_expect(Colony.population() == before + 1, seed_value,
		"completing migration progress admits exactly one survivor (%d -> %d)"
			% [before, Colony.population()])
	_expect(Colony.migration_progress < 0.75, seed_value,
		"admitting a survivor consumes the progress rather than looping")

	# --- rest is a real decision now -------------------------------------------------------
	# A bed has to be meaningfully better than the ground, or huts are decoration again.
	_expect(Villager.REST_IN_BED > Villager.REST_ROUGH * 3.0, seed_value,
		"a bed beats the ground by a wide margin")
	_expect(Villager.ROUGH_REST_CAP < Villager.NEED_MAX, seed_value,
		"sleeping rough cannot fully rest a villager")

	_check_ledger(seed_value)

	# Teardown. Villagers and buildings deregister themselves in _exit_tree, so freeing the
	# nodes is enough to leave the autoloads clean for the live-scene check that follows.
	for child in get_children():
		child.queue_free()
	Colony.set_spawn_parent(null)
	Colony.reset()


## The rate ledger's honesty contract: every breakdown must add up to the number printed above
## it.
##
## This is the assertion that makes the panel trustworthy. A breakdown that disagrees with its
## own total is worse than no breakdown at all — it actively teaches the player the wrong model
## of the game — and the terms are assembled by hand from formulas living in three other files,
## so nothing but a test will notice when one of them is retuned and the ledger is not.
##
## It also guards the Phase 2 Burden system, which is unplayable if the Faith breakdown cannot
## be trusted to explain a negative rate.
func _check_ledger(seed_value: int) -> void:
	# Mood: additive terms, must sum to the drift target.
	var mood := RateLedger.mood()
	var mood_sum := 0.0
	for term in mood.terms:
		mood_sum += term.value
	_expect(absf(clampf(mood_sum, 0.0, Villager.NEED_MAX) - mood.total) < 0.01, seed_value,
		"the mood breakdown sums to its total (%.2f vs %.2f)" % [mood_sum, mood.total])
	_expect(mood.terms.size() > 0, seed_value, "the mood breakdown has terms to show")

	# Faith is a SUM now, not a product: passive generation plus Tome bonuses minus ability Burden.
	# Only the non-factor terms are in that sum — the factor rows annotate the term after them,
	# explaining how the passive figure got its value. See RateLedger.faith().
	#
	# This is the honesty contract that matters most in the game, because a standing negative rate is
	# unplayable unless the panel explaining it is exactly right.
	var faith := RateLedger.faith()
	var faith_sum := 0.0
	var faith_factors := 0
	for term in faith.terms:
		if term.is_factor:
			faith_factors += 1
		else:
			faith_sum += term.value
	_expect(absf(faith_sum - faith.total) < 0.001, seed_value,
		"the faith breakdown sums to its total (%.4f vs %.4f)" % [faith_sum, faith.total])
	_expect(faith_factors >= 2, seed_value,
		"the faith breakdown still explains WHY passive generation is what it is (%d factors)"
			% faith_factors)
	_expect(is_equal_approx(faith.total, Divine.net_faith_rate()), seed_value,
		"the faith breakdown agrees with Divine.net_faith_rate")

	# Burden has to be visible as its own line, or the player cannot tell which ability to shed.
	# Every baseline power is taken up at run start, so there is always at least one.
	_expect(Divine.total_burden() > 0.0, seed_value,
		"the baseline abilities carry a real Burden (%.2f/s)" % Divine.total_burden())
	var burden_terms := 0
	for term in faith.terms:
		if not term.is_factor and term.value < 0.0:
			burden_terms += 1
	_expect(burden_terms == Divine.taken_up.size(), seed_value,
		"every Burden is itemised (%d lines for %d abilities)"
			% [burden_terms, Divine.taken_up.size()])

	# Taking an ability up must lower the net rate by EXACTLY its Burden, and giving it back must
	# restore it exactly. A ratchet that leaks in either direction makes the whole system a trap.
	var tier1: PowerDef = null
	for def: PowerDef in Powers.all():
		if def.required_temple_tier == 0 and not Divine.is_taken_up(def.id):
			tier1 = def
			break
	if tier1 == null:
		# Everything at tier 0 is already held, so test the round trip on one of those instead.
		var held: StringName = Divine.taken_up[0]
		var held_def := Powers.get_power(held)
		var before_rate := Divine.net_faith_rate()
		Divine.faith = maxf(Divine.faith, Divine.RELINQUISH_COST + 1.0)
		_expect(Divine.relinquish(held), seed_value, "an ability can be given back")
		_expect(absf((Divine.net_faith_rate() - before_rate) - held_def.burden) < 0.0001,
			seed_value, "giving an ability back recovers exactly its Burden (%.3f)"
				% held_def.burden)
		_expect(Divine.take_up(held_def), seed_value, "and it can be taken up again")
		_expect(absf(Divine.net_faith_rate() - before_rate) < 0.0001, seed_value,
			"taking it back up costs exactly its Burden again")

	# Food: supply minus demand must be the net, and demand must agree with the figure the
	# migration gate uses. If these drift, the readout and the gate tell different stories.
	var food := RateLedger.food()
	var expected := (Colony.food_supply_per_second() - Colony.food_demand_per_second()) \
		* Sim.cycle_seconds()
	var food_sum := 0.0
	for term in food.terms:
		food_sum += term.value
	_expect(absf(food_sum - expected) < 0.01, seed_value,
		"the food breakdown sums to the net flow (%.2f vs %.2f)" % [food_sum, expected])
	_expect(Colony.food_demand_per_second() > 0.0, seed_value,
		"a populated colony has a positive food demand")

	# Water has no stock, so its report is an average rather than a sum — assert it is at least
	# reporting the colony that exists.
	var water := RateLedger.water()
	_expect(water.total >= 0.0 and water.total <= Villager.NEED_MAX, seed_value,
		"the water report is a sane average (%.1f)" % water.total)


## Localization: every key a content file names must exist in the table, and must translate to
## something other than itself.
##
## This is the assertion that makes explicit keys safe. Their whole advantage over English-as-key
## is that a missed string renders as `BUILDING_GATE_DESC` on screen instead of failing silently —
## but that only helps if something notices. A typo in a .tres is otherwise invisible until a
## player screenshots it.
func _check_phase5(seed_value: int) -> void:
	_expect(Audio._sfx.size() == AudioData.SFX_IDS.size(), seed_value,
		"every Phase 5 sound effect is imported (%d)" % Audio._sfx.size())
	_expect(Audio._music_player != null and Audio._music_player.stream is AudioStreamGenerator,
		seed_value, "the infinite procedural music generator is running")
	_expect(Accessibility.PALETTE_NAMES.size() == 4, seed_value,
		"the original and three accessible colour palettes exist")
	_expect(Accessibility.TEXT_SCALES.size() >= 4, seed_value,
		"text size offers several deliberate readable steps")
	_expect(Accessibility._filter_material != null, seed_value,
		"the full-screen colour accessibility filter is available")
	for action: StringName in Accessibility.ACTION_DEFAULTS:
		_expect(InputMap.has_action(action) and not InputMap.action_get_events(action).is_empty(),
			seed_value, "desktop action '%s' has a remappable key" % action)
	for id in [&"palisade", &"path", &"road"]:
		var drag_def := Buildings.get_building(id)
		_expect(drag_def != null and drag_def.drag_placeable, seed_value,
			"%s opts into desktop drag placement" % id)
	var onboarding_script := load("res://scripts/ui/onboarding.gd")
	_expect(onboarding_script != null, seed_value,
		"contextual onboarding is present and loadable")
	_expect(Meta.HISTORY_LIMIT >= 20, seed_value,
		"the Chronicle retains a useful number of completed worlds")


func _check_phase6(seed_value: int) -> void:
	_expect(Biomes.DEFINITIONS.size() == 7, seed_value,
		"all seven settleable biomes have authored rules")
	var nest_counts := {}
	for id: StringName in Biomes.DEFINITIONS:
		nest_counts[Biomes.nest_count(id)] = true
		_expect(Locale.has_key(Biomes.name_key(id)) and Locale.has_key(Biomes.hazard_key(id)),
			seed_value, "%s has a translated identity and hazard" % id)
	_expect(nest_counts.size() >= 3, seed_value,
		"biomes vary enemy nest pressure instead of sharing one ring")
	_expect(Biomes.yield_multiplier(&"forest", Terrain.Feature.TREE) \
		> Biomes.yield_multiplier(&"badlands", Terrain.Feature.TREE), seed_value,
		"deep forest timber is richer than badlands timber")
	_expect(Biomes.movement_multiplier(&"marsh", Terrain.Type.DIRT) < 1.0, seed_value,
		"marsh ground carries a real travel cost")

	var first := Climate.daily_snapshot(seed_value, 991, 1, &"marsh")
	var repeated := Climate.daily_snapshot(seed_value, 991, 1, &"marsh")
	_expect(first == repeated, seed_value,
		"the same region and day reproduce the same weather")
	_expect(Climate.season_for_day(1) == &"spring"
		and Climate.season_for_day(6) == &"summer"
		and Climate.season_for_day(11) == &"autumn"
		and Climate.season_for_day(16) == &"winter", seed_value,
		"the four-season calendar advances every five days")
	_expect(Climate.WEATHER_IDS.size() == 7, seed_value,
		"the weather table includes clear skies and six consequential conditions")
	_expect(load("res://scenes/world/weather_view.tscn") != null, seed_value,
		"the procedural weather layer is present")
	_expect(load("res://scenes/ui/story_event_panel.tscn") != null, seed_value,
		"the storyteller decision panel is present")
	_expect(Meta.ACHIEVEMENT_TOTAL == 8, seed_value,
		"the Chronicle includes the two Phase 6 achievements")


func _check_phase6_live(seed_value: int) -> void:
	_expect(Climate.biome == World.biome_id, seed_value,
		"live weather follows the selected Realm biome")
	Climate.force_weather(&"storm", 1.0)
	_expect(Climate.light_multiplier() < 0.8 and Climate.movement_multiplier(Terrain.Type.GRASS) < 0.9,
		seed_value, "storms visibly dim the map and slow exposed travel")
	_expect(Climate.blight_multiplier() > Biomes.blight_multiplier(Climate.biome), seed_value,
		"storms feed local corruption pressure")
	Climate.clear_forced_weather()

	var before := Storyteller.resolved_count
	Colony.add(&"food", 18)
	_expect(Storyteller.force_event(&"caravan"), seed_value,
		"a deterministic caravan event can enter the live run")
	_expect(Storyteller.resolved_count == before + 1 and Storyteller.pending.is_empty(),
		seed_value, "headless event resolution takes one valid choice and clears the card")


func _check_locale(seed_value: int) -> void:
	_expect(Locale.keys.size() > 50, seed_value,
		"the translation table loaded (%d keys)" % Locale.keys.size())
	_expect(Locale.healthy(), seed_value, "at least one language registered")

	# The CSV has to be READABLE THROUGH res://, not merely present on disk.
	#
	# This is the check that would have caught the iOS build shipping with every label showing its own
	# key. The cause was the csv_translation importer claiming the file, which makes the exporter ship
	# the generated .translation and strip the source the Locale autoload actually reads — invisible in
	# the editor, total on device. It cannot fully be caught here (the suite runs before export, where
	# the file is always present), so this only guards the path and the real check is the pack
	# inspection documented in docs/PLAN.md.
	_expect(FileAccess.file_exists(Locale.CSV_PATH), seed_value,
		"the locale CSV is reachable at %s" % Locale.CSV_PATH)

	# Gather every key the content layer references, with a label for the failure message.
	var refs: Array = []
	for job: JobDef in Jobs.all():
		refs.append(["job %s name" % job.id, job.display_name])
	for def: BuildingDef in Buildings.all():
		refs.append(["building %s name" % def.id, def.display_name])
		refs.append(["building %s desc" % def.id, def.description])
	for def: PowerDef in Powers.all():
		refs.append(["power %s name" % def.id, def.display_name])
		refs.append(["power %s desc" % def.id, def.description])
	for def: DifficultyDef in Difficulties.all():
		refs.append(["difficulty %s name" % def.id, def.display_name])
		refs.append(["difficulty %s desc" % def.id, def.description])
	for def: MonsterDef in Monsters.all():
		refs.append(["monster %s name" % def.id, def.display_name])
	# Phase 2's two new content types. Omitted at first, which is exactly how a whole category of
	# strings goes unchecked — the list has to grow with the catalogs.
	for def: TomeDef in Tomes.all():
		refs.append(["tome %s name" % def.id, def.display_name])
		refs.append(["tome %s desc" % def.id, def.description])
	for def: BlightStructureDef in BlightStructures.all():
		refs.append(["blight %s name" % def.id, def.display_name])
		refs.append(["blight %s desc" % def.id, def.description])

	var missing := 0
	for entry in refs:
		var label: String = entry[0]
		var key: String = entry[1]
		if key.is_empty():
			continue
		if not Locale.has_key(key):
			missing += 1
			_fail(seed_value, "%s references unknown key '%s'" % [label, key])
		elif TranslationServer.translate(key) == key:
			missing += 1
			_fail(seed_value, "%s key '%s' has no English text" % [label, key])
	_expect(missing == 0, seed_value,
		"all %d content strings resolve" % refs.size())

	# Formatted strings must actually substitute. A key whose placeholders were written as %s
	# would silently render "{0}" to the player.
	var sample := L10n.t(&"HUD_PER_DAY", ["+3"])
	_expect(not sample.contains("{0}"), seed_value,
		"placeholders substitute (%s)" % sample)

	# And the most-seen runtime string of all.
	if not Colony.villagers.is_empty():
		var who: Villager = Colony.villagers[0]
		var described := who.describe()
		_expect(not described.contains("STATE_"), seed_value,
			"villager status is translated (%s)" % described)


## Where the migration check parents its test buildings and people.
func _spawn_root() -> Node:
	return self


func _run_seed(seed_value: int) -> void:
	print("\n-- seed %d --" % seed_value)
	World.generate(seed_value)

	# Before the colony exists, because these checks destroy nests and regenerate the map.
	# Doing that after place_ember would leave Divine holding a light handle into a light
	# field that had since been rebuilt, and every check after it would be measuring
	# nonsense.
	_check_phase0(seed_value)
	# Runs after phase 0, which is where the nest checks live — this raises and levels a Blight
	# structure of its own and must not be interleaved with those.
	_check_phase2_tail(seed_value)

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
	if Divine.faith < 0.0 or Divine.faith > Divine.faith_max() + 0.01:
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
	# Measured against the SEEDED area rather than against a flat percentage of the map.
	#
	# The old bound was a flat 0.2% by day 2, written when the Blight spread twenty times faster. It
	# was never the right shape of test: spread is per-frontier-cell, so growth is exponential from a
	# base of one cell per nest, and early absolute coverage is therefore tiny however the constant
	# is tuned — four nests are 0.02% of the map before anything happens at all. A flat floor makes
	# the test a hostage to the tuning it is supposed to be guarding.
	#
	# So: it must have at least doubled the ground it started on (which catches the real failure this
	# guarded — a frontier that stalled entirely) and must be nowhere near swallowing the map by day
	# two. Both bounds survive retuning; neither has to be revisited when BASE_SPREAD moves.
	var seeded := float(World.nest_cells.size()) / float(World.grid.cell_count)
	_expect(coverage > seeded * 2.0, seed_value,
		"blight is advancing (%.3f%% by day 2, from %.3f%% seeded)"
			% [coverage * 100.0, seeded * 100.0])
	_expect(coverage < 0.20, seed_value,
		"blight has not swallowed the map by day 2 (%.1f%%)" % (coverage * 100.0))
	_expect(coverage < 0.08, seed_value, "blight is a slow siege (%.2f%% by day 2)" % (coverage * 100.0))

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
	# Lifecycle coverage awards real shards through the same path as the shipped game. Put the
	# player's profile back before exiting so running the developer suite cannot farm or damage it.
	Meta.shards = int(_profile_snapshot["shards"])
	Meta.unlocked.assign(_profile_snapshot["unlocked"])
	Meta.ascension = int(_profile_snapshot["ascension"])
	Meta.best_day = int(_profile_snapshot["best_day"])
	Meta.runs_played = int(_profile_snapshot["runs_played"])
	Meta.last_difficulty = StringName(_profile_snapshot["last_difficulty"])
	Meta.run_history.assign(_profile_snapshot["run_history"])
	Meta.lifetime_stats = _profile_snapshot["lifetime_stats"].duplicate(true)
	Meta.achievements.assign(_profile_snapshot["achievements"])
	Meta.save_profile()
	print("\n=== result ===")
	if _failures.is_empty():
		print("all checks passed across %d seeds" % SEEDS.size())
		quit(0)
		return
	printerr("%d failure(s):" % _failures.size())
	for f in _failures:
		printerr("  - %s" % f)
	_log_failures()
	quit(1)


## Append failures to a file as well as stdout.
##
## Because this suite is not fully deterministic — blight growth, Tome scribing and migrant timing all
## draw on the global RNG — it flakes roughly one run in twenty, and a flake is worth far more than a
## pass. Twice now a red run was noticed only after its output had already scrolled away, so the
## specific assertion was never captured and the cause is still unknown.
##
## Appending, never truncating, so an overnight loop of runs leaves a record of every distinct
## failure rather than only the last one.
func _log_failures() -> void:
	var path := "user://smoke_failures.log"
	var f := FileAccess.open(path, FileAccess.READ_WRITE) if FileAccess.file_exists(path) \
		else FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	# Timestamped so repeated flakes can be told apart, and the seed list recorded because a flake
	# that only appears on one seed is a very different problem from one that floats.
	f.store_line("--- %s  seeds %s" % [Time.get_datetime_string_from_system(), str(SEEDS)])
	for line in _failures:
		f.store_line("  " + line)
	f.close()
	printerr("(also appended to %s)" % ProjectSettings.globalize_path(path))


func quit(code: int) -> void:
	get_tree().quit(code)
