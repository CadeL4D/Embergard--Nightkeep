class_name Building
extends Node2D
## A placed structure, from blueprint through to finished.
##
## One node with a state enum and swapped visuals, NOT a scene per state — damage
## later reverts a finished building to the construction path, so the two features
## share one code path rather than duplicating it.
##
## The node sits at the BOTTOM-left of its footprint and the sprite is offset
## upward from there. That puts the node's y at the building's base, which is what
## Y-sorting needs: a villager standing in front of a hut must draw over it, and a
## villager behind it must draw under.

enum State { BLUEPRINT, COMPLETE }

signal completed(building: Building)

var def: BuildingDef
var anchor: int = -1                   ## top-left cell
var cells: PackedInt32Array = PackedInt32Array()
var state: State = State.BLUEPRINT
var hp: float = 0.0
var work_done: float = 0.0

## Materials actually carried to the site so far. Construction cannot start until
## this matches the definition's cost.
var delivered: Dictionary = {}

var _light_handle: int = 0
## How often a tower with nothing in range looks again.
const SCAN_INTERVAL := 0.2

var _attack_timer: float = 0.0
var _scan_timer: float = 0.0
var _shot_target: Vector2 = Vector2.ZERO
var _shot_fade: float = 0.0

@onready var _sprite: Sprite2D = $Sprite
@onready var _progress_back: ColorRect = $Progress/Back
@onready var _progress_fill: ColorRect = $Progress/Fill


func setup(building_def: BuildingDef, anchor_cell: int) -> void:
	def = building_def
	anchor = anchor_cell
	cells = World.grid.footprint_cells(World.grid.coord(anchor_cell), def.footprint)
	hp = def.max_hp


func _ready() -> void:
	if def == null:
		push_error("Building added to the tree without setup()")
		return

	_sprite.texture = def.sprite
	_sprite.centered = false
	# Sprite art is authored top-left-origin and the node sits at the base, so lift
	# the sprite by its own height to line the two up.
	_sprite.offset = Vector2(0, -def.tile_size().y)

	var width := float(def.tile_size().x)
	_progress_back.size = Vector2(width, 2)
	_progress_back.position = Vector2(0, 2)
	_progress_fill.position = _progress_back.position

	Colony.register_building(self)
	# The ground is spoken for from this moment, not from completion. Pathing still
	# only closes on completion (see complete()) so builders can reach the site.
	World.claim_cells(cells, get_instance_id())
	_refresh_visuals()

	# A zero-work building (the Hearth) is finished the moment it is placed.
	if def.build_work <= 0.0:
		complete()


func _exit_tree() -> void:
	if _light_handle != 0:
		World.light_field.remove_source(_light_handle)
		_light_handle = 0
	# Released here rather than only in destroy(), so a building torn down by a scene
	# reload or by queue_free from anywhere else cannot leave its footprint locked out
	# of placement for the rest of the run.
	World.release_cells(cells, get_instance_id())
	Colony.unregister_building(self)


# --- Construction ---------------------------------------------------------------------

func is_site() -> bool:
	return state == State.BLUEPRINT


func remaining_work() -> float:
	return maxf(def.build_work - work_done, 0.0)


# --- Materials ---------------------------------------------------------------------------

func needs_materials() -> bool:
	return not materials_complete()


func materials_complete() -> bool:
	for kind: StringName in def.cost:
		if delivered.get(kind, 0) < int(def.cost[kind]):
			return false
	return true


## The next material this site is short of, or an empty name if it has everything.
func next_needed() -> StringName:
	for kind: StringName in def.cost:
		if delivered.get(kind, 0) < int(def.cost[kind]):
			return kind
	return &""


func amount_needed(kind: StringName) -> int:
	return maxi(int(def.cost.get(kind, 0)) - delivered.get(kind, 0), 0)


## Accept a load. Returns how much was taken — a builder arriving with more than the
## site still wants keeps the remainder rather than having it vanish.
func deliver(kind: StringName, amount: int) -> int:
	var wanted := amount_needed(kind)
	var taken := mini(amount, wanted)
	if taken <= 0:
		return 0
	delivered[kind] = delivered.get(kind, 0) + taken
	_refresh_visuals()
	return taken


## What is still owed, for handing back to the colony if this site is cancelled.
func outstanding_cost() -> Dictionary:
	var out: Dictionary = {}
	for kind: StringName in def.cost:
		var short := amount_needed(kind)
		if short > 0:
			out[kind] = short
	return out


## Apply builder effort. Returns true when this call finished the building.
func add_work(amount: float) -> bool:
	if state == State.COMPLETE or needs_materials():
		return false
	work_done += amount
	_refresh_visuals()
	if work_done < def.build_work:
		return false
	complete()
	return true


func complete() -> void:
	if state == State.COMPLETE:
		return
	# Force-completing a site (debug tools, scripted setup) must square the books:
	# anything still owed was reserved at placement and would otherwise stay locked
	# away from the colony forever.
	if needs_materials():
		Colony.unreserve(outstanding_cost())
		for kind: StringName in def.cost:
			delivered[kind] = int(def.cost[kind])
	state = State.COMPLETE
	work_done = def.build_work
	hp = def.max_hp

	# Occupancy is only applied on COMPLETION. A blueprint the player has just
	# placed must not block pathing, or the builders walking to raise it can find
	# themselves locked out by the very thing they are coming to build.
	if def.blocks_movement:
		World.set_occupancy(cells, get_instance_id())

	if def.light_radius > 0:
		_light_handle = World.light_field.add_source(_centre_cell(), def.light_radius, 220)

	if def.is_stockpile:
		Colony.add_stockpile(_centre_cell())

	_refresh_visuals()
	completed.emit(self)
	Events.building_completed.emit(self)


func _centre_cell() -> int:
	var c := World.grid.coord(anchor)
	return World.grid.index(
		c.x + def.footprint.x / 2,
		c.y + def.footprint.y / 2
	)


func centre_position() -> Vector2:
	return World.grid.to_world_index(_centre_cell())


# --- Defence -----------------------------------------------------------------------------

## Towers fire on their own. Ticked in _process rather than through the sim
## scheduler because there are only ever a handful of them — the scheduler exists
## to spread the cost of a hundred agents, and paying its bookkeeping for four
## buildings would cost more than it saves.
func _process(delta: float) -> void:
	if _shot_fade > 0.0:
		_shot_fade = maxf(_shot_fade - delta * 5.0, 0.0)
		queue_redraw()

	if def == null or def.attack_damage <= 0.0 or state != State.COMPLETE:
		return
	_attack_timer = maxf(_attack_timer - delta, 0.0)
	if _attack_timer > 0.0:
		return

	# Only rescan a few times a second. With the cooldown elapsed and nothing in
	# range, the naive version swept every live monster on every single frame —
	# with 120 monsters and a row of towers that is thousands of distance checks
	# per frame, spent entirely on finding nothing.
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return
	_scan_timer = SCAN_INTERVAL

	var target := _find_enemy()
	if target == null:
		return
	_attack_timer = def.attack_cooldown
	target.take_damage(def.attack_damage, self)
	_shot_target = target.position - position
	_shot_fade = 1.0
	queue_redraw()


func _find_enemy() -> Node:
	var reach := def.attack_range * Grid.TILE_SIZE
	var reach_sq := reach * reach
	var origin := centre_position()
	var best: Node = null
	var best_dist := reach_sq
	for m in Threat.monsters:
		if not is_instance_valid(m) or not m.alive:
			continue
		var d := origin.distance_squared_to(m.position)
		if d <= best_dist:
			best_dist = d
			best = m
	return best


## A fading tracer. Without it a tower is silent and the player cannot tell whether
## it is working, out of range, or was never built facing anything.
func _draw() -> void:
	if _shot_fade <= 0.0:
		return
	var origin := centre_position() - position
	draw_line(origin, _shot_target, Color(1.0, 0.85, 0.5, _shot_fade * 0.9), 1.5, true)


# --- Damage -----------------------------------------------------------------------------

func take_damage(amount: float) -> void:
	if state != State.COMPLETE or hp <= 0.0:
		return
	hp -= amount
	_flash()
	if hp <= 0.0:
		destroy()


func destroy() -> void:
	# An unfinished site hands its undelivered materials back, or the colony has
	# quietly lost them for the rest of the run.
	if state == State.BLUEPRINT:
		Colony.unreserve(outstanding_cost())
	# Free the ground before anything else. A destroyed wall that leaves its
	# occupancy behind would keep blocking pathing forever, and the flow field would
	# route monsters around a gap that is actually open.
	if def.blocks_movement:
		World.set_occupancy(cells, 0)
	World.release_cells(cells, get_instance_id())
	if def.is_stockpile:
		Colony.remove_stockpile(_centre_cell())
	Events.building_destroyed.emit(self)
	queue_free()


func health_fraction() -> float:
	return clampf(hp / maxf(def.max_hp, 0.001), 0.0, 1.0)


## Brief white flash on hit. At 16px a building has no room for a hit animation, so
## the flash is the only feedback that a wall is being chewed on — and knowing which
## wall is under attack is the entire decision the player makes at night.
func _flash() -> void:
	if state != State.COMPLETE:
		return
	_sprite.modulate = Color(2.0, 1.4, 1.4)
	var tween := create_tween()
	tween.tween_property(_sprite, "modulate", Color.WHITE, 0.25)

	_progress_back.visible = true
	_progress_fill.visible = true
	_progress_fill.size = Vector2(_progress_back.size.x * health_fraction(), 2)
	_progress_fill.color = Color(0.85, 0.35, 0.3, 0.9)


# --- Presentation ----------------------------------------------------------------------

func _refresh_visuals() -> void:
	if state == State.COMPLETE:
		_sprite.modulate = Color.WHITE
		_progress_back.visible = false
		_progress_fill.visible = false
		return

	# Blueprints are drawn as a translucent ghost so an unbuilt site never reads as
	# a finished one at a glance. Awaiting-materials is dimmer and colder than
	# under-construction, so the player can tell at a distance whether a site is
	# stalled waiting on a delivery or actually being worked.
	_progress_back.visible = true
	_progress_fill.visible = true

	if needs_materials():
		_sprite.modulate = Color(0.45, 0.55, 0.75, 0.32)
		_progress_fill.color = Color(0.55, 0.62, 0.75, 0.85)
		_progress_fill.size = Vector2(_progress_back.size.x * _material_fraction(), 2)
		return

	_sprite.modulate = Color(0.55, 0.72, 1.0, 0.45)
	_progress_fill.color = Color(0.482, 0.718, 0.961, 0.9)
	var fraction := clampf(work_done / maxf(def.build_work, 0.001), 0.0, 1.0)
	_progress_fill.size = Vector2(_progress_back.size.x * fraction, 2)


func _material_fraction() -> float:
	var want := 0.0
	var have := 0.0
	for kind: StringName in def.cost:
		want += float(def.cost[kind])
		have += float(delivered.get(kind, 0))
	return clampf(have / maxf(want, 0.001), 0.0, 1.0)


## Cell a builder should stand on to work this site — just outside the footprint for
## solid buildings, since they cannot stand inside one.
func work_cell() -> int:
	var target: int = World.nearest_walkable(_centre_cell())
	return target
