extends Node2D
## Root of a single run. Owns the scene-side wiring: generate the map, place the
## Ember, spawn the founding survivors, start the clock, and keep the sky tint in
## step with the phase.
##
## Everything durable lives in the autoloads; this node is the thing you throw away
## and rebuild when a run ends. Keeping that boundary clean is what makes "Ascend to
## a new map" a scene reload rather than a hunt for stale state.

## The band that survivors arrive with. Small enough that every individual matters
## on day one, which is what makes the first night frightening.
##
## Difficulty adjusts this rather than replacing it — see starting_villagers().
const STARTING_VILLAGERS := 6


## How many survivors this run actually begins with. Floored at two: a difficulty tier
## is allowed to make the opening desperate, never to make it unplayable, and a single
## founder cannot gather, build and stand watch at once.
func starting_villagers() -> int:
	return maxi(STARTING_VILLAGERS + Difficulties.start_pop_bonus(), 2)

## Sky colour per phase. The whole art direction rests on this: the world is cold
## and desaturated so that firelight — and the Ember — are the only warm things on
## screen. Night is deliberately dark enough to be uncomfortable.
const SKY_COLORS := {
	Sim.Phase.DAY: Color("cfd4dd"),
	Sim.Phase.DUSK: Color("8a6a5c"),
	Sim.Phase.NIGHT: Color("2b3350"),
	Sim.Phase.DAWN: Color("9b8497"),
}

@onready var world_view: Node2D = $WorldView
@onready var entities: Node2D = $WorldView/Sorted/Entities
@onready var camera: Camera2D = $CameraRig
@onready var sky: CanvasModulate = $Sky
@onready var ember: Node2D = $Ember
## Optional: absent in the dev and test scenes, which found a colony directly.
@onready var site_picker: Node = get_node_or_null("SitePicker")

var _sky_from: Color = Color.WHITE
var _sky_to: Color = Color.WHITE
## The seed being played. Held because confirming a site has to regenerate with it, and by
## then the caller's argument is long gone.
var _pending_seed: int = 0

## Set once the run is over, so the end sequence cannot fire twice — a keep can be
## destroyed on the same frame its last villager dies.
var _ended: bool = false
## Running tally for the summary screen.
var _buildings_raised: int = 0


func _ready() -> void:
	Events.phase_changed.connect(_on_phase_changed)
	Events.villager_died.connect(_on_villager_died)
	Events.building_destroyed.connect(_on_building_destroyed)
	Events.building_completed.connect(_on_building_completed)

	# An explicit request from the main menu wins over anything on disk: the player asked
	# for a new world, and silently resuming their old one instead would be maddening.
	var request := NewRunRequest.consume()
	if bool(request["pending"]):
		start_run(int(request["seed"]), request["difficulty"], bool(request["pick_site"]))
		return

	if RunSave.has_save():
		if _resume():
			return
	# No request and no save. Reached by the dev scenes and by running run.tscn directly,
	# so it founds immediately rather than waiting on a site choice nobody asked for.
	start_run(randi())


## Continue an interrupted run. Failing to resume falls through to a fresh run
## rather than dropping the player on a broken screen.
func _resume() -> bool:
	_clear_entities()
	if not RunSave.load_into(self, entities):
		return false
	_ended = false
	camera.center_on_cell(World.keep_cell)
	_sky_from = SKY_COLORS[Sim.phase]
	_sky_to = _sky_from
	sky.color = _sky_from
	Events.run_started.emit(World.seed_value)
	Events.notice.emit(L10n.t(&"NOTICE_KEEP_ENDURES", [Sim.day]), 0)
	return true


## Begin a fresh run. An empty difficulty id means "whatever the player chose last",
## which is what keeps a debug reseed and the summary screen's Next Run button on the
## tier the player was actually playing.
##
## `pick_site` opens the site picker instead of founding immediately. Off by default so
## every existing caller — the smoke test, the debug reseed, the summary card — keeps
## working unchanged and headlessly; only the New World flow turns it on.
func start_run(seed_value: int, difficulty_id: StringName = &"", pick_site: bool = false) -> void:
	_clear_entities()
	_ended = false
	_buildings_raised = 0
	_pending_seed = seed_value
	RunSave.clear()

	# Settled before anything reads it: the founding band size and the first night's
	# threat budget both depend on the tier, and both are decided below.
	#
	# Selecting does NOT write the profile. Remembering a preference is the world-creation
	# screen's job (it is the only place the player actually expresses one) — doing it here
	# would mean every headless test and debug reseed silently rewrote the player's saved
	# choice.
	Difficulties.select(difficulty_id if difficulty_id != &"" else Meta.last_difficulty)

	World.generate(seed_value)

	if pick_site:
		_begin_site_selection()
		return
	_found_colony(seed_value)


## Show the generated land and let the player choose where to settle.
##
## Nothing is founded yet and the clock does not run, so the player can pan and zoom over
## a still world with no pressure. This is the first real decision of a run and it should
## be the calmest.
func _begin_site_selection() -> void:
	camera.center_on_cell(World.keep_cell)
	# Daylight, so the land is actually legible while it is being judged.
	_sky_from = SKY_COLORS[Sim.Phase.DAY]
	_sky_to = _sky_from
	sky.color = _sky_from
	_sync_ember()
	if site_picker != null:
		site_picker.begin(_suggested_site())


## Where the generator would have put the keep. Offered as a suggestion so a player who
## does not want to make this decision can take one tap and move on.
func _suggested_site() -> int:
	return World.keep_cell


## Commit to a site. Regenerates the map around the chosen cell — the flatten pad, the
## nest ring and the cleared start area all key off the keep, so they have to be rebuilt
## rather than patched.
func confirm_site(cell: int) -> void:
	if not World.grid.is_valid_index(cell):
		return
	World.generate(_pending_seed, cell)
	if site_picker != null:
		site_picker.finish()
	_found_colony(_pending_seed)


## Raise the colony and start the clock. Everything from the Ember to the founding band,
## shared by the picked and unpicked paths so the two cannot drift apart.
func _found_colony(seed_value: int) -> void:
	Colony.reset()
	Divine.reset()
	Threat.reset()
	# Monsters share the Y-sorted container with villagers and buildings so they
	# draw in the right order against everything they are attacking.
	Threat.set_spawn_parent(entities)
	# Migrants arrive on their own schedule, so Colony needs to be able to create people
	# without asking the scene.
	Colony.set_spawn_parent(entities)

	# The Ember goes down before anything else — half the sim asks where it is.
	Divine.place_ember(World.keep_cell)
	_sync_ember()

	_raise_hearth()

	_spawn_starting_villagers()

	camera.center_on_cell(World.keep_cell)
	Sim.start_run()

	_sky_from = SKY_COLORS[Sim.Phase.DAY]
	_sky_to = _sky_from
	sky.color = _sky_from
	Events.run_started.emit(seed_value)


## The Hearth is placed by the run rather than by the player: it is the colony's
## only drop-off point on day one, and its zero build cost and zero work time mean
## it stands finished the moment it is created. Centred on the keep site, so the
## 2x2 footprint straddles the cell everything else measures distance from.
func _raise_hearth() -> void:
	var def := Buildings.get_building(&"hearth")
	if def == null:
		push_error("no hearth building definition found")
		Colony.add_stockpile(World.keep_cell)
		return

	var grid: Grid = World.grid
	var c := grid.coord(World.keep_cell)
	var anchor := grid.index(c.x - def.footprint.x / 2, c.y - def.footprint.y / 2)
	if Colony.place_building(def, anchor, entities) == null:
		# Should not happen on a generated map — the keep clearing is guaranteed
		# flat — but a colony with nowhere to store goods is unplayable, so fall
		# back to a bare drop-off point rather than shipping a dead run.
		push_warning("could not place the hearth; falling back to a bare stockpile")
		Colony.add_stockpile(World.keep_cell)


func _clear_entities() -> void:
	Sim.stop_run()
	for child in entities.get_children():
		child.queue_free()
	Colony.villagers.clear()


func _spawn_starting_villagers() -> void:
	var grid: Grid = World.grid
	var keep := grid.coord(World.keep_cell)
	var placed := 0
	var radius := 1
	var want := starting_villagers()
	# Spiral outward from the keep rather than stacking everyone on one tile, so
	# the founding band reads as a group of people instead of a single sprite.
	while placed < want and radius < 12:
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if placed >= want:
					break
				if absi(dx) != radius and absi(dy) != radius:
					continue
				if not grid.is_valid(keep.x + dx, keep.y + dy):
					continue
				var cell := grid.index(keep.x + dx, keep.y + dy)
				if not World.is_walkable(cell):
					continue
				Colony.spawn_villager(cell)
				placed += 1
		radius += 1


func _process(_delta: float) -> void:
	# Cross-fade across the whole phase rather than snapping on transition, so dusk
	# visibly bleeds into night while the player is still scrambling.
	sky.color = _sky_from.lerp(_sky_to, Sim.phase_progress())
	_sync_ember()


func _on_phase_changed(phase: int, _duration: float) -> void:
	_sky_from = sky.color
	_sky_to = SKY_COLORS.get(phase, Color.WHITE)
	# Phase boundaries are natural, frequent checkpoints, and there are only four a
	# day — cheap enough to save on every one.
	if not _ended:
		RunSave.save()


## Android can kill a backgrounded app with no warning, so the only safe moment to
## save is the moment we are told we are going away.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if not _ended and Sim.running:
			RunSave.save()


# --- Run lifecycle -----------------------------------------------------------------------

func _on_building_completed(_b: Node) -> void:
	_buildings_raised += 1


func _on_villager_died(_v: Node, _cause: StringName) -> void:
	# Deferred: the roster still contains the dying villager at emit time.
	call_deferred("_check_defeat")


## Losing the Village Center ends the run, whatever tier it had reached.
##
## Tested on `center_tier` rather than on `id == &"hearth"`, because upgrading is done IN PLACE and
## changes the definition: a colony that had raised its Hearth into a Great Hall would have had the
## defeat condition silently stop applying to the only building that matters. Exactly the failure
## BuildingDef's header warns about — the property needed was missing, not the branch.
func _on_building_destroyed(b: Node) -> void:
	var def: BuildingDef = b.def
	if def.center_tier > 0:
		call_deferred("_end_run", false, tr(&"NOTICE_HEARTH_BROKEN"))
	else:
		call_deferred("_check_defeat")


func _check_defeat() -> void:
	if _ended:
		return
	if Colony.population() <= 0:
		_end_run(false, tr(&"NOTICE_LAST_FALLEN"))


## Days a run must reach before ascending counts toward the difficulty ratchet. Low enough that a
## competent run clears it easily, high enough that it cannot be farmed on day one.
const ASCENSION_MIN_DAY := 5

## Voluntarily leave with what you have earned. "Ascend" exists so a good run can be
## banked rather than played until it collapses — losing should be a payout, and so
## should knowing when to stop.
func ascend() -> void:
	if not _ended:
		_end_run(true, tr(&"NOTICE_ASCEND"))


func _end_run(ascended: bool, message: String) -> void:
	if _ended:
		return
	_ended = true
	Sim.running = false

	var nests_cleared := 0
	for nest in World.nest_cells:
		if World.feature_at(nest) != Terrain.Feature.NEST:
			nests_cleared += 1

	var shards := Meta.shards_for_run(Sim.day, _buildings_raised, nests_cleared)
	if ascended:
		# Leaving on your own terms is worth more than being driven out.
		shards = int(shards * 1.25)
	# Harder tiers pay proportionally more. Without this the hard tiers are strictly
	# worse choices and nobody plays the content.
	shards = int(shards * Difficulties.shard_mult())
	Meta.award(shards, Sim.day)

	# Ascension: the meta layer's difficulty ratchet, and until now a number `threat_dial()` read
	# and NOTHING ever wrote — so baseline difficulty could only ever climb 0.03 per unlock and
	# topped out at 1.03 forever.
	#
	# Counted for a run BANKED on the player's own terms and taken far enough to mean something.
	# Not for dying, because losing is already a payout and should not also be progress; and not for
	# a day-2 exit, or the optimal play is to ascend immediately, repeatedly, and inflate the dial
	# without ever having played a run.
	#
	# Phase 4 replaces this with closing the ring around the Heart. Voluntarily walking away from a
	# world you have made safe is the closest thing this version has to completing one.
	if ascended and Sim.day >= ASCENSION_MIN_DAY:
		Meta.record_ascension()
	RunSave.clear()

	Events.run_ended.emit(ascended, shards)
	Events.notice.emit(message, 2)


func _sync_ember() -> void:
	if Divine.ember_cell == -1:
		ember.visible = false
		return
	ember.visible = true
	ember.position = Divine.ember_position()


# --- Debug -----------------------------------------------------------------------------

## Debug-only shortcuts, and they must stay that way: `debug_reseed` is bound to R and
## throws the current run away without confirmation. In a shipped build that is one
## stray keypress between a player and three hours of progress, so the whole block is
## compiled out of release. Player-facing speed control lives on the HUD instead.
func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed(&"debug_reseed"):
		start_run(randi())
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"debug_speed_up"):
		Sim.time_scale = minf(Sim.time_scale * 2.0, 8.0)
	elif event.is_action_pressed(&"debug_speed_down"):
		Sim.time_scale = maxf(Sim.time_scale * 0.5, 0.25)
