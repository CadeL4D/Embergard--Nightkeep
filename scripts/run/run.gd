extends Node2D
## Root of a single run. Owns the scene-side wiring: generate the map, place the
## Ember, spawn the founding survivors, start the clock, and keep the sky tint in
## step with the phase.
##
## Everything durable lives in the autoloads; this node is the thing you throw away
## and rebuild when a run ends. Keeping that boundary clean is what makes "Ascend to
## a new map" a scene reload rather than a hunt for stale state.

const VILLAGER_SCENE := preload("res://scenes/entities/villager.tscn")

## The band that survivors arrive with. Small enough that every individual matters
## on day one, which is what makes the first night frightening.
const STARTING_VILLAGERS := 6

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

var _sky_from: Color = Color.WHITE
var _sky_to: Color = Color.WHITE

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

	if RunSave.has_save():
		if _resume():
			return
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
	Events.notice.emit("The keep endures. Day %d." % Sim.day, 0)
	return true


func start_run(seed_value: int) -> void:
	_clear_entities()
	_ended = false
	_buildings_raised = 0
	RunSave.clear()

	World.generate(seed_value)
	Colony.reset()
	Divine.reset()
	Threat.reset()
	# Monsters share the Y-sorted container with villagers and buildings so they
	# draw in the right order against everything they are attacking.
	Threat.set_spawn_parent(entities)

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
	# Spiral outward from the keep rather than stacking everyone on one tile, so
	# the founding band reads as a group of people instead of a single sprite.
	while placed < STARTING_VILLAGERS and radius < 12:
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if placed >= STARTING_VILLAGERS:
					break
				if absi(dx) != radius and absi(dy) != radius:
					continue
				if not grid.is_valid(keep.x + dx, keep.y + dy):
					continue
				var cell := grid.index(keep.x + dx, keep.y + dy)
				if not World.is_walkable(cell):
					continue
				_spawn_villager(cell)
				placed += 1
		radius += 1


func _spawn_villager(cell: int) -> void:
	var v: Villager = VILLAGER_SCENE.instantiate()
	v.position = World.grid.to_world_index(cell)
	entities.add_child(v)


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


func _on_building_destroyed(b: Node) -> void:
	if b.def.id == &"hearth":
		call_deferred("_end_run", false, "The Hearth is broken. The light goes out.")
	else:
		call_deferred("_check_defeat")


func _check_defeat() -> void:
	if _ended:
		return
	if Colony.population() <= 0:
		_end_run(false, "The last of them has fallen.")


## Voluntarily leave with what you have earned. "Ascend" exists so a good run can be
## banked rather than played until it collapses — losing should be a payout, and so
## should knowing when to stop.
func ascend() -> void:
	if not _ended:
		_end_run(true, "You carry the Ember onward.")


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
	Meta.award(shards, Sim.day)
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

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_reseed"):
		start_run(randi())
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"debug_speed_up"):
		Sim.time_scale = minf(Sim.time_scale * 2.0, 8.0)
	elif event.is_action_pressed(&"debug_speed_down"):
		Sim.time_scale = maxf(Sim.time_scale * 0.5, 0.25)
