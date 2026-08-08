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

## New values go on the END — a saved run stores the integer.
enum State { BLUEPRINT, COMPLETE, DEMOLISHING }

signal completed(building: Building)

var def: BuildingDef
var anchor: int = -1                   ## top-left cell
var cells: PackedInt32Array = PackedInt32Array()
var state: State = State.BLUEPRINT
var hp: float = 0.0
var work_done: float = 0.0

## Materials actually carried to the site so far. Construction cannot start until
## this matches the definition's cost.
##
## Also the ONLY basis for a demolition refund. Refunding a fraction of `def.cost` instead would
## let a building that was force-completed by a debug tool, or upgraded, be farmed for materials
## nobody ever carried to it.
var delivered: Dictionary = {}

# --- Demolition -----------------------------------------------------------------------------
#
# Construction run backwards, and reusing the same code: the worker accrues effort at the site,
# then produces carry loads and hauls them to a stockpile. That is _tick_building and _begin_haul
# unchanged, which is why demolition needed no new villager state.

## Fraction of what was actually delivered that comes back out.
##
## Deliberately stingy. Salvage is the wrong place to be generous — a near-full refund makes
## teardown-and-rebuild free, which erases every placement mistake and with it the entire point
## of having a sphere of influence to plan against.
const SALVAGE_FRACTION := 0.4

## Teardown effort as a fraction of what the building cost to raise. Pulling something down is
## quicker than putting it up, but not free, so demolishing under pressure is a real cost.
const DEMOLISH_WORK_SCALE := 0.5

## Materials pulled out of the frame and waiting to be carried off, kind -> amount.
##
## Held on the building rather than handed to the worker in one lump because the salvage MUST be
## hauled: a worker takes one load, walks it to a stockpile and comes back for the next. That
## makes demolishing something far from storage cost real time, exactly as building it did.
var salvage: Dictionary = {}
var demolish_done: float = 0.0

var _light_handle: int = 0
## How often a tower with nothing in range looks again.
const SCAN_INTERVAL := 0.2

var _attack_timer: float = 0.0
var _scan_timer: float = 0.0
var _shot_target: Vector2 = Vector2.ZERO
var _shot_fade: float = 0.0

## Player policies live on the placed building, not the catalog definition.
var target_policy: StringName = &"nearest"
var marked_target_id: int = 0
var repair_priority: int = 1
var repair_progress: float = 0.0
var production_paused: bool = false
var production_worker_limit: int = -1
var production_priority: int = 1
## -1 disables maintain-stock behavior; otherwise all outputs pause at this aggregate amount.
var production_target: int = -1
var hallowed_remaining: float = 0.0
var held_by_hand: bool = false
## Numeric contents of this building's physical store. One resource stack is one
## dictionary entry; individual units never become scene nodes.
var inventory: Dictionary = {}
var item_inventory: Array[Dictionary] = []
var spoilage_progress: Dictionary = {}
var input_buffer: Dictionary = {}
var output_buffer: Dictionary = {}
## Collector charge. It belongs to this physical building and is lost if the building falls.
var stored_energy: int = 0

@onready var _sprite: Sprite2D = $Sprite
@onready var _progress_back: ColorRect = $Progress/Back
@onready var _progress_fill: ColorRect = $Progress/Fill


func setup(building_def: BuildingDef, anchor_cell: int) -> void:
	def = building_def
	anchor = anchor_cell
	cells = World.grid.footprint_cells(World.grid.coord(anchor_cell), def.footprint)
	hp = def.max_hp
	target_policy = def.default_target_policy


func _ready() -> void:
	if def == null:
		push_error("Building added to the tree without setup()")
		return

	_sprite.texture = def.sprite
	_sprite.centered = false
	# Sprite art is authored top-left-origin and the node sits at the base, so lift
	# the sprite by its own height to line the two up.
	_sprite.offset = Vector2(0, -def.tile_size().y)

	# Buildings you can WALK ON must draw beneath the people standing on them and
	# beneath the Ember hovering over them. Y-sorting
	# cannot express that: the node sits at the BOTTOM of its footprint, so a farmer
	# working the top row of a 2x2 farm sorts behind it and vanishes into the crop, and
	# a haulier on a stockpile disappears under the sacks.
	#
	# Walkability is the right signal rather than a new flag or a list of ids — anything
	# you can stand on is, by definition, something you should be drawn over. Entities'
	# parent is z +2, so relative -2 puts roads at world z 0: above the ground layers,
	# below villagers, and below the later-drawn Ember at the same global z.
	if not def.blocks_movement:
		z_index = -2

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
	Threat.release_jailed_at(self)
	Colony.unregister_building(self)


# --- Construction ---------------------------------------------------------------------

## "Not a working building." True for a blueprint AND for something being torn down.
##
## Every caller of this means "can I sleep here / farm here / draw Faith from here", and the
## answer for a half-demolished workshop is no. Keeping that in one predicate is what let
## demolition land without auditing thirty call sites.
func is_site() -> bool:
	return state != State.COMPLETE


func is_demolishing() -> bool:
	return state == State.DEMOLISHING


func remaining_work() -> float:
	return maxf(def.build_work - work_done, 0.0)


# --- Materials ---------------------------------------------------------------------------

func needs_materials() -> bool:
	# A teardown wants no deliveries. Without this the site would look permanently under-supplied
	# and builders would shuttle timber to a building they are supposed to be dismantling.
	if state == State.DEMOLISHING:
		return false
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


## Apply builder effort. Returns true when this call finished the job — raising it, or, for a
## teardown, prising the last of the materials loose.
func add_work(amount: float) -> bool:
	if state == State.DEMOLISHING:
		demolish_done += amount
		_refresh_visuals()
		return teardown_complete()
	if state == State.COMPLETE or needs_materials():
		return false
	work_done += amount
	_refresh_visuals()
	if work_done < def.build_work:
		return false
	complete()
	return true


# --- Demolition -----------------------------------------------------------------------------

## Start tearing this down. Returns false if there is nothing to tear down.
##
## A blueprint is not demolished — it is CANCELLED, immediately, by destroy(): nothing has been
## built, so there is no frame to prise apart and no reason to make the player wait. That path
## already hands back the outstanding reservation correctly.
func begin_demolish() -> bool:
	if state != State.COMPLETE:
		return false
	state = State.DEMOLISHING
	demolish_done = 0.0
	salvage = {}
	for kind: StringName in delivered:
		var amount := int(floorf(float(delivered[kind]) * SALVAGE_FRACTION))
		if amount > 0:
			salvage[kind] = amount
	Colony.evacuate_inventory(self)

	# Everything the building DID stops now, not when the last plank is carried off. A watchtower
	# under demolition should not still be shooting, and a wall being pulled down should already
	# have stopped turning the horde aside.
	_clear_effects()
	_refresh_visuals()
	Events.building_demolishing.emit(self)
	return true


func demolish_work() -> float:
	return maxf(def.build_work * DEMOLISH_WORK_SCALE, 0.01)


func teardown_complete() -> bool:
	return state == State.DEMOLISHING and demolish_done >= demolish_work()


func salvage_remaining() -> bool:
	for kind: StringName in salvage:
		if int(salvage[kind]) > 0:
			return true
	return false


## Hand a worker one armful. Returns [kind, amount], or an empty array when the pile is gone.
##
## One kind per trip because a villager carries one kind at a time; a mixed-material building
## therefore takes several journeys, which is correct — that is what it took to build it.
func take_salvage_load(capacity: int) -> Array:
	for kind: StringName in salvage:
		var have := int(salvage[kind])
		if have <= 0:
			continue
		var taken := mini(have, capacity)
		salvage[kind] = have - taken
		return [kind, taken]
	return []


# --- Upgrading ------------------------------------------------------------------------------

## Swap in a higher-tier definition and revert to a construction site, in place.
##
## Reuses the blueprint→deliver→build path wholesale, which is what this class's header says that
## path is for. The caller (Colony.upgrade_building) has already reserved the new cost and checked
## the gates; this only has to reset the construction bookkeeping and stop the OLD building
## working, because complete() will re-apply everything for the new one.
##
## The footprint is required to match. Growing it would mean re-validating ground the player never
## chose, and possibly failing halfway through an upgrade they have already paid for.
func begin_upgrade(next: BuildingDef) -> bool:
	if next == null or state != State.COMPLETE or next.footprint != def.footprint:
		return false
	_clear_effects()
	def = next
	state = State.BLUEPRINT
	work_done = 0.0
	delivered = {}
	hp = next.max_hp
	_sprite.texture = next.sprite
	_sprite.offset = Vector2(0, -next.tile_size().y)
	z_index = -2 if not next.blocks_movement else 0
	Colony.mark_supply_requests_dirty()
	_refresh_visuals()
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
	_apply_effects()
	Colony.mark_supply_requests_dirty()

	_refresh_visuals()
	completed.emit(self)
	Events.building_completed.emit(self)


# --- What a standing building DOES ----------------------------------------------------------
#
# Paired on purpose. Four things start or stop a building working — completing, being destroyed,
# being upgraded in place, and being torn down — and every one of them has to touch the same five
# world layers. Keeping them as one apply/clear pair is what stops the fifth caller forgetting the
# gate stamp and leaving an invisible wall behind for the rest of the run.

func _apply_effects() -> void:
	# Occupancy is only applied on COMPLETION. A blueprint the player has just
	# placed must not block pathing, or the builders walking to raise it can find
	# themselves locked out by the very thing they are coming to build.
	if def.blocks_movement:
		World.set_occupancy(cells, get_instance_id())
	elif def.blocks_monsters_only:
		# Stamped on completion for the same reason occupancy is: an unfinished gate
		# must not turn the horde aside, or a blueprint the player never manages to
		# raise would defend the colony for free.
		World.set_gate(cells, true)

	if def.path_tier > 0:
		World.set_path_tier(cells, def.path_tier)
	if def.bridges_water:
		World.set_bridge(cells, true)

	if def.light_radius > 0:
		_light_handle = World.light_field.add_source(centre_cell(), def.light_radius, 220)

	if def.is_stockpile:
		Colony.add_stockpile(centre_cell())
		Colony.register_storage(self)

	if def.influence_radius > 0:
		World.rebuild_influence()

	# A new Temple changes the slot count, so the library has to be re-shelved — a spare the priests
	# already wrote should go straight into the new slot rather than waiting for the next cycle.
	if def.tome_slots > 0:
		Divine.refresh_library()
	if def.temple_tier > 0:
		# Announced, because raising a Temple is what makes a whole tier of abilities available to
		# take up, and that is not a thing to discover by chance later.
		Events.notice.emit(L10n.t(&"NOTICE_TEMPLE_RAISED", [def.temple_tier]), 0)


func _clear_effects() -> void:
	# Free the ground before anything else. A destroyed wall that leaves its occupancy
	# behind would keep blocking pathing forever, and the flow field would route
	# monsters around a gap that is actually open.
	if def.blocks_movement:
		World.set_occupancy(cells, 0)
	elif def.blocks_monsters_only:
		# A broken gate is an open gap. Clear the stamp, or the flow field keeps
		# charging the horde wall-price to walk through the hole it just made.
		World.set_gate(cells, false)

	if def.path_tier > 0:
		World.set_path_tier(cells, 0)
	if def.bridges_water:
		World.set_bridge(cells, false)

	if _light_handle != 0:
		World.light_field.remove_source(_light_handle)
		_light_handle = 0

	if def.is_stockpile:
		Colony.unregister_storage(self)
		Colony.remove_stockpile(centre_cell())

	if def.influence_radius > 0:
		World.rebuild_influence()

	# Fewer slots now. Re-shelving here is what un-installs the tomes that no longer fit, so losing
	# a Sanctum costs its bonuses as well as its tier.
	if def.tome_slots > 0:
		Divine.refresh_library()


func centre_cell() -> int:
	var c := World.grid.coord(anchor)
	return World.grid.index(
		c.x + def.footprint.x / 2,
		c.y + def.footprint.y / 2
	)


func centre_position() -> Vector2:
	return World.grid.to_world_index(centre_cell())


## Exact world-space footprint. Shared by forgiving touch picking, the selection
## outline and the camera's inspect action so all three agree on what the player
## is looking at.
func world_rect() -> Rect2:
	var top_left := World.grid.to_world_index(anchor) - Vector2.ONE * Grid.TILE_SIZE * 0.5
	return Rect2(top_left, Vector2(def.tile_size()))


# --- Physical inventory -----------------------------------------------------------------

func inventory_used() -> int:
	var total := 0
	for amount in inventory.values():
		total += maxi(int(amount), 0)
	total += item_inventory.size()
	return total


func inventory_free() -> int:
	return maxi(def.inventory_capacity - inventory_used(), 0)


func accepts_resource(kind: StringName) -> bool:
	if def == null or not def.is_stockpile or def.inventory_capacity <= 0:
		return false
	var resource := Resources.get_resource(kind)
	return def.storage_tags.is_empty() or kind in def.storage_tags \
		or (resource != null and resource.matches_storage(def.storage_tags))


func accepts_item(item_def: ItemDef) -> bool:
	if item_def == null or def == null or not def.is_stockpile or def.inventory_capacity <= 0:
		return false
	if def.storage_tags.is_empty() or &"equipment" in def.storage_tags:
		return true
	if item_def.slot in def.storage_tags:
		return true
	return item_def.slot == &"consumable" and (&"food" in def.storage_tags \
		or &"medicine" in def.storage_tags)


func inventory_deposit_item(row: Dictionary) -> bool:
	var item_def := Items.get_item(StringName(row.get("def", &"")))
	if inventory_free() <= 0 or not accepts_item(item_def):
		return false
	item_inventory.append(row.duplicate(true))
	queue_redraw()
	return true


## Local mutation only. Colony owns aggregate-cache updates and calls these methods.
func inventory_deposit(kind: StringName, amount: int) -> int:
	if amount <= 0 or not accepts_resource(kind):
		return 0
	var accepted := mini(amount, inventory_free())
	if accepted > 0:
		inventory[kind] = int(inventory.get(kind, 0)) + accepted
		queue_redraw()
	return accepted


## Local mutation only. Returns exactly what left this building.
func inventory_withdraw(kind: StringName, amount: int) -> int:
	if amount <= 0:
		return 0
	var taken := mini(amount, int(inventory.get(kind, 0)))
	if taken <= 0:
		return 0
	var left := int(inventory.get(kind, 0)) - taken
	if left > 0:
		inventory[kind] = left
	else:
		inventory.erase(kind)
	queue_redraw()
	return taken


func _buffer_used(buffer: Dictionary) -> int:
	var total := 0
	for amount in buffer.values():
		total += maxi(int(amount), 0)
	return total


func input_free() -> int:
	return maxi(def.input_capacity - _buffer_used(input_buffer), 0)


func output_free() -> int:
	return maxi(def.output_capacity - _buffer_used(output_buffer), 0)


func next_input_needed(cost: Dictionary) -> StringName:
	for kind: StringName in cost:
		if int(input_buffer.get(kind, 0)) < int(cost[kind]):
			return kind
	return &""


func input_amount_needed(kind: StringName, cost: Dictionary) -> int:
	return maxi(int(cost.get(kind, 0)) - int(input_buffer.get(kind, 0)), 0)


func deposit_input_local(kind: StringName, amount: int) -> int:
	var accepted := mini(maxi(amount, 0), input_free())
	if accepted > 0:
		input_buffer[kind] = int(input_buffer.get(kind, 0)) + accepted
		queue_redraw()
	return accepted


func withdraw_input_local(kind: StringName, amount: int) -> int:
	var taken := mini(maxi(amount, 0), int(input_buffer.get(kind, 0)))
	input_buffer[kind] = int(input_buffer.get(kind, 0)) - taken
	if int(input_buffer.get(kind, 0)) <= 0:
		input_buffer.erase(kind)
	queue_redraw()
	return taken


func deposit_output_local(kind: StringName, amount: int) -> int:
	var accepted := mini(maxi(amount, 0), output_free())
	if accepted > 0:
		output_buffer[kind] = int(output_buffer.get(kind, 0)) + accepted
		queue_redraw()
	return accepted


func withdraw_output_local(kind: StringName, amount: int) -> int:
	var taken := mini(maxi(amount, 0), int(output_buffer.get(kind, 0)))
	output_buffer[kind] = int(output_buffer.get(kind, 0)) - taken
	if int(output_buffer.get(kind, 0)) <= 0:
		output_buffer.erase(kind)
	queue_redraw()
	return taken


# --- Production and repair policies -------------------------------------------------------

func effective_worker_slots() -> int:
	if production_worker_limit < 0:
		return def.worker_slots
	return clampi(production_worker_limit, 0, def.worker_slots)


## Whether this completed building can retain an allocated worker. Pausing is intentionally not
## part of this answer: Update 2d pause keeps the allocation while the worker recovers inside.
func staffing_is_available() -> bool:
	return state == State.COMPLETE and effective_worker_slots() > 0


func production_is_available(job: JobDef = null) -> bool:
	if not staffing_is_available() or production_paused:
		return false
	if job != null and not job.required_weather.is_empty() \
			and Climate.weather not in job.required_weather:
		return false
	if job != null and not job.cycle_yield.is_empty() and def.output_capacity > 0:
		var output_needed := 0
		for amount in job.cycle_yield.values():
			output_needed += maxi(int(amount), 0)
		if output_free() < output_needed:
			return false
	if production_target < 0 or job == null or job.cycle_yield.is_empty():
		if job != null and not job.cycle_yield.is_empty() and def.output_capacity > 0:
			var needed := 0
			for amount in job.cycle_yield.values():
				needed += maxi(int(amount), 0)
			return output_free() >= needed
		return true
	for kind: StringName in job.cycle_yield:
		if Colony.amount_of(kind) < production_target:
			return true
	return false


func needs_repair() -> bool:
	return state == State.COMPLETE and hp > 0.0 and hp < def.max_hp - 0.01 \
		and not def.repair_cost.is_empty() and def.repair_amount > 0.0


## Returns true when this worker should release the target: either the building is
## fully restored or stores cannot fund another declared repair batch.
func add_repair_work(amount: float) -> bool:
	if not needs_repair():
		return true
	if not Colony.can_afford(def.repair_cost):
		repair_progress = 0.0
		return true
	repair_progress += amount
	if repair_progress < maxf(def.repair_work, 0.01):
		return false
	repair_progress = 0.0
	if not Colony.spend_near(centre_cell(), def.repair_cost):
		return true
	hp = minf(hp + def.repair_amount, def.max_hp)
	_refresh_damage_bar()
	Events.building_repaired.emit(self, def.repair_amount)
	return not needs_repair()


func cycle_repair_priority() -> void:
	repair_priority = repair_priority % 3 + 1


func cycle_target_policy() -> void:
	var policies: Array[StringName] = [
		&"nearest", &"strongest", &"weakest", &"structure", &"phasing", &"marked",
	]
	var index := policies.find(target_policy)
	target_policy = policies[(maxi(index, 0) + 1) % policies.size()]


func set_marked_target(target: Agent) -> void:
	marked_target_id = target.get_instance_id() if target != null else 0
	target_policy = &"marked" if marked_target_id != 0 else &"nearest"


# --- Defence -----------------------------------------------------------------------------

## Towers fire on their own. Ticked in _process rather than through the sim
## scheduler because there are only ever a handful of them — the scheduler exists
## to spread the cost of a hundred agents, and paying its bookkeeping for four
## buildings would cost more than it saves.
func _process(delta: float) -> void:
	if held_by_hand:
		return
	if hallowed_remaining > 0.0 and not Sim.paused:
		hallowed_remaining = maxf(hallowed_remaining - delta * Sim.time_scale, 0.0)
	if _shot_fade > 0.0:
		_shot_fade = maxf(_shot_fade - delta * 5.0, 0.0)
		queue_redraw()

	if def == null or def.attack_damage <= 0.0 or state != State.COMPLETE:
		return
	# Upkeep structures go dormant when the shared Faith buffer is empty. Their
	# burden still appears in the ledger, so restoring positive income wakes them
	# automatically without destructive toggles or hidden state.
	if def.faith_upkeep > 0.0 and Divine.faith <= 0.0:
		return
	# Towers reload on raw frame delta rather than sim time, so they have to be told about
	# the pause explicitly — otherwise a paused colony keeps shooting.
	if Sim.paused:
		return
	_attack_timer = maxf(_attack_timer - delta * Sim.time_scale, 0.0)
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

	# A structure-policy tower shells the Blight economy before creatures. Every
	# other policy defends the colony first and only sieges when the field is clear.
	if target_policy == &"structure":
		var priority_structure := _find_blight_structure()
		if priority_structure != -1 and _fire_at_structure(priority_structure):
			return

	var target := _find_enemy()
	if target != null and _fire_at_enemy(target):
		return

	# Nothing alive in range: fall back to shelling the Blight's own works. A structure is preferred
	# over a nest because it is the thing that got there recently and is actively making nights
	# worse — and because it is softer, so an idle tower makes visible progress rather than chipping
	# forever at a nest's much larger pool.
	var structure := _find_blight_structure()
	if structure != -1 and _fire_at_structure(structure):
		return

	# Then a nest, if one is close enough.
	#
	# Handled here rather than inside _find_enemy because a nest is a cell in the
	# feature layer, not a Node, and widening that function's return type to cover
	# both would infect every caller. Monsters always take priority — this only fires
	# on an idle tower.
	#
	# The point of this branch is to make "push a tower forward and siege the nest" a
	# real strategy, which is the only way clearing a nest is achievable before
	# warriors exist.
	var nest := _find_nest()
	if nest == -1 or not _has_line_of_fire(nest) or not _consume_ammo():
		return
	_attack_timer = def.attack_cooldown * Doctrines.modifier(&"tower_reload")
	World.damage_nest(nest, _shot_damage())
	Events.tower_fired.emit(self, _shot_damage(), World.grid.to_world_index(nest))
	_shot_target = World.grid.to_world_index(nest) - position
	_shot_fade = 1.0
	queue_redraw()


func _fire_at_enemy(target: Agent) -> bool:
	if not _has_line_of_fire(World.grid.to_cell_index(target.position)):
		return false
	if not _consume_ammo():
		return false
	_attack_timer = def.attack_cooldown * Doctrines.modifier(&"tower_reload")
	var damage := _shot_damage()
	var targets_hit := 0
	if def.attack_area_radius > 0.0:
		var radius := def.attack_area_radius * Grid.TILE_SIZE
		var radius_sq := radius * radius
		for monster: Agent in Threat.hostiles:
			if is_instance_valid(monster) and monster.alive \
					and monster.position.distance_squared_to(target.position) <= radius_sq:
				monster.take_damage(damage, self, def.attack_type)
				targets_hit += 1
				if def.knockback_tiles > 0.0:
					monster.knockback_from(centre_position(), def.knockback_tiles)
	else:
		target.take_damage(damage, self, def.attack_type)
		targets_hit = 1
		if def.knockback_tiles > 0.0:
			target.knockback_from(centre_position(), def.knockback_tiles)
	_shot_target = target.position - position
	_shot_fade = 1.0
	if def.storm_self_damage > 0.0 and Climate.weather == &"storm":
		take_damage(def.storm_self_damage, &"elemental")
	Events.tower_fired.emit(self, damage * maxi(targets_hit, 1), target.position)
	queue_redraw()
	return true


## Persistent divine constructs are the one class of building the Hand may reposition. The
## footprint is released while held, then atomically stamped at the destination so walls and
## influence never exist in two places during a mobile gesture.
func begin_hand_move() -> bool:
	if def == null or not def.menu_hidden or state != State.COMPLETE or held_by_hand:
		return false
	held_by_hand = true
	_clear_effects()
	World.release_cells(cells, get_instance_id())
	return true


func can_drop_from_hand(new_anchor: int) -> bool:
	return held_by_hand and bool(Colony.check_placement(def, new_anchor).get("ok", false))


func drop_from_hand(new_anchor: int) -> bool:
	if not can_drop_from_hand(new_anchor):
		return false
	anchor = new_anchor
	cells = World.grid.footprint_cells(World.grid.coord(anchor), def.footprint)
	position = Colony._building_origin(def, anchor)
	World.claim_cells(cells, get_instance_id())
	held_by_hand = false
	_apply_effects()
	Threat.mark_field_dirty()
	return true


func cancel_hand_move(old_anchor: int) -> void:
	if not held_by_hand:
		return
	anchor = old_anchor
	cells = World.grid.footprint_cells(World.grid.coord(anchor), def.footprint)
	position = Colony._building_origin(def, anchor)
	World.claim_cells(cells, get_instance_id())
	held_by_hand = false
	_apply_effects()
	Threat.mark_field_dirty()


func _fire_at_structure(cell: int) -> bool:
	if not _has_line_of_fire(cell):
		return false
	if not _consume_ammo():
		return false
	_attack_timer = def.attack_cooldown * Doctrines.modifier(&"tower_reload")
	World.damage_blight_structure(cell, _shot_damage(), def.attack_type)
	Events.tower_fired.emit(self, _shot_damage(), World.grid.to_world_index(cell))
	_shot_target = World.grid.to_world_index(cell) - position
	_shot_fade = 1.0
	queue_redraw()
	return true


func _consume_ammo() -> bool:
	if not def.ammo_kind.is_empty() and def.ammo_per_shot > 0 \
			and int(input_buffer.get(def.ammo_kind, 0)) < def.ammo_per_shot:
		return false
	if def.energy_per_shot > 0 and not Colony.draw_energy_near(centre_cell(), def.energy_per_shot):
		return false
	if def.ammo_kind.is_empty() or def.ammo_per_shot <= 0:
		return true
	# A tower fires from its own magazine, never from an aggregate store on the far side of
	# the colony. consume_building_inputs also updates the stock and committed-buffer caches,
	# keeping the shot inside the same conservation ledger as workshop production.
	return Colony.consume_building_inputs(self, {def.ammo_kind: def.ammo_per_shot})


func _shot_damage() -> float:
	return def.attack_damage * Doctrines.modifier(&"tower_damage") \
		* (def.storm_damage_multiplier if Climate.weather == &"storm" else 1.0)


func _has_line_of_fire(target_cell: int) -> bool:
	if not def.requires_line_of_fire or not World.grid.is_valid_index(target_cell):
		return true
	var from := World.grid.coord(centre_cell())
	var to := World.grid.coord(target_cell)
	var x := from.x
	var y := from.y
	var dx := absi(to.x - x)
	var step_x := 1 if x < to.x else -1
	var dy := -absi(to.y - y)
	var step_y := 1 if y < to.y else -1
	var error := dx + dy
	while x != to.x or y != to.y:
		var twice := error * 2
		if twice >= dy:
			error += dy
			x += step_x
		if twice <= dx:
			error += dx
			y += step_y
		if x == to.x and y == to.y:
			break
		var cell := World.grid.index(x, y)
		var occupant := World.occupancy[cell]
		if occupant != 0 and occupant != get_instance_id():
			return false
	return true


## Nearest Blight structure inside this building's reach, or -1.
##
## Iterates the dictionary directly rather than materialising a list, for the same reason _find_nest
## does: this runs on every idle tower several times a second and the array would be pure garbage.
func _find_blight_structure() -> int:
	if World.blight_structures.is_empty():
		return -1
	var reach := def.attack_range * Grid.TILE_SIZE
	var reach_sq := reach * reach
	var origin := centre_position()
	var best := -1
	var best_dist := reach_sq
	for cell in World.blight_structures:
		var d := origin.distance_squared_to(World.grid.to_world_index(cell))
		if d <= best_dist and _has_line_of_fire(cell):
			best_dist = d
			best = cell
	return best


## Nearest live nest inside this building's reach, or -1.
##
## Walks the raw site list and tests each for life rather than calling
## live_nest_cells(), which allocates — this runs on every idle tower several times a
## second, and the array would be pure garbage.
func _find_nest() -> int:
	var reach := def.attack_range * Grid.TILE_SIZE
	var reach_sq := reach * reach
	var origin := centre_position()
	var best := -1
	var best_dist := reach_sq
	for nest in World.nest_cells:
		if not World.is_nest(nest):
			continue
		var d := origin.distance_squared_to(World.grid.to_world_index(nest))
		if d <= best_dist and _has_line_of_fire(nest):
			best_dist = d
			best = nest
	return best


func _find_enemy() -> Agent:
	var reach := def.attack_range * Grid.TILE_SIZE
	var reach_sq := reach * reach
	var origin := centre_position()
	if target_policy == &"marked" and marked_target_id != 0:
		var marked := instance_from_id(marked_target_id) as Agent
		if marked != null and marked.alive \
				and origin.distance_squared_to(marked.position) <= reach_sq:
			return marked
	var best: Agent = null
	var best_dist := reach_sq
	var best_value := INF if target_policy == &"weakest" else -INF
	for m: Agent in Threat.hostiles:
		if not is_instance_valid(m) or not m.alive:
			continue
		var d := origin.distance_squared_to(m.position)
		if d > reach_sq:
			continue
		if not _has_line_of_fire(World.grid.to_cell_index(m.position)):
			continue
		if not def.target_tags.is_empty():
			var matches := false
			for tag: StringName in def.target_tags:
				if m.has_behavior(tag):
					matches = true
					break
			if not matches:
				continue
		match target_policy:
			&"strongest":
				if m.max_health > best_value:
					best_value = m.max_health
					best = m
			&"weakest":
				if m.health < best_value:
					best_value = m.health
					best = m
			&"phasing":
				if m.has_behavior(&"phasing") and d <= best_dist:
					best_dist = d
					best = m
			_:
				if d <= best_dist:
					best_dist = d
					best = m
	# A phasing policy remains useful before Shades arrive instead of idling.
	if best == null and target_policy == &"phasing":
		var old_policy := target_policy
		target_policy = &"nearest"
		best = _find_enemy()
		target_policy = old_policy
	return best


## A fading tracer. Without it a tower is silent and the player cannot tell whether
## it is working, out of range, or was never built facing anything.
func _draw() -> void:
	if _shot_fade > 0.0:
		var origin := centre_position() - position
		draw_line(origin, _shot_target, Color(1.0, 0.85, 0.5, _shot_fade * 0.9), 1.5, true)
	if state != State.COMPLETE or def == null:
		return
	var width := float(def.tile_size().x)
	var y := 4.0
	if def.inventory_capacity > 0:
		var fill := clampf(float(inventory_used()) / float(def.inventory_capacity), 0.0, 1.0)
		draw_rect(Rect2(0, y, width, 2), Color(0.08, 0.07, 0.06, 0.8))
		draw_rect(Rect2(0, y, width * fill, 2), Color(0.78, 0.62, 0.32, 0.95))
		y += 3.0
	if def.input_capacity > 0:
		var input_fill := clampf(float(_buffer_used(input_buffer)) / float(def.input_capacity), 0.0, 1.0)
		draw_rect(Rect2(0, y, width, 2), Color(0.08, 0.07, 0.06, 0.8))
		draw_rect(Rect2(0, y, width * input_fill, 2), Color(0.86, 0.46, 0.24, 0.95))
		y += 3.0
	if def.output_capacity > 0:
		var output_fill := clampf(float(_buffer_used(output_buffer)) / float(def.output_capacity), 0.0, 1.0)
		draw_rect(Rect2(0, y, width, 2), Color(0.08, 0.07, 0.06, 0.8))
		draw_rect(Rect2(0, y, width * output_fill, 2), Color(0.34, 0.78, 0.48, 0.95))
		y += 3.0
	if def.energy_capacity > 0:
		var energy_fill := clampf(float(stored_energy) / float(def.energy_capacity), 0.0, 1.0)
		draw_rect(Rect2(0, y, width, 2), Color(0.05, 0.07, 0.14, 0.85))
		draw_rect(Rect2(0, y, width * energy_fill, 2), Color(0.48, 0.62, 1.0, 0.98))
		y += 3.0

	# Damage, shown only once it exists. A permanent green health bar over every hut is noise;
	# a red one over the two buildings the night chewed on is information.
	if needs_repair():
		var health := clampf(hp / maxf(def.max_hp, 1.0), 0.0, 1.0)
		draw_rect(Rect2(0, y, width, 2), Color(0.1, 0.05, 0.05, 0.85))
		draw_rect(Rect2(0, y, width * health, 2), Color(0.95, 0.32, 0.26, 0.95))
		y += 3.0

	# A workplace that has quietly stopped producing. This is the state that stranded farmers at
	# a full barn for a whole run: from the outside the building looked fine, the workers looked
	# busy, and nothing anywhere said the shift had ended. An amber bar says it.
	if def.worker_slots > 0 and (production_paused
			or (def.output_capacity > 0 and output_free() <= 0)):
		draw_rect(Rect2(0, y, width, 2), Color(0.96, 0.72, 0.18, 0.9))


# --- Damage -----------------------------------------------------------------------------

func take_damage(amount: float, damage_type: StringName = &"crushing") -> void:
	if state != State.COMPLETE or hp <= 0.0:
		return
	var applied := DamageTypes.apply(amount, def.resistances, damage_type)
	if hallowed_remaining > 0.0:
		applied *= 0.5 if damage_type == &"blight" else 0.8
	hp -= applied
	_flash()
	if hp <= 0.0:
		destroy()


func destroy() -> void:
	# An unfinished site squares its books. The reservation goes back, and so does everything
	# actually carried out to it — a cancelled blueprint is a pile of timber lying on the ground,
	# not a building, so there is nothing to have lost in the framing.
	#
	# Which is also why cancelling is cheap and demolishing is not: changing your mind before the
	# work starts should cost nothing, and changing it afterwards should cost 60%.
	if state == State.BLUEPRINT:
		Colony.unreserve(outstanding_cost())
		for kind: StringName in delivered:
			Colony.add(kind, int(delivered[kind]))
	elif not inventory.is_empty() or not item_inventory.is_empty() \
			or not input_buffer.is_empty() or not output_buffer.is_empty():
		# Damage may erase the container, never the resources. They become Hearth
		# overflow until hauliers can find valid capacity again.
		Colony.evacuate_inventory(self)
	# Off the roster FIRST, before anything reads it. _clear_effects rebuilds the influence layer
	# by summing over Colony.buildings, and this building is still COMPLETE at this instant — so
	# leaving it registered would have it contribute its own disc to the sphere that is supposed to
	# be shrinking because it is gone. _exit_tree calls this again; erase is idempotent.
	Colony.unregister_building(self)
	# A COMPLETE building is being destroyed by damage rather than torn down, so its effects are
	# still live and have to be lifted here. One already mid-teardown cleared them in
	# begin_demolish, and _clear_effects is safe to run twice.
	_clear_effects()
	World.release_cells(cells, get_instance_id())
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

	_refresh_damage_bar()


func _refresh_damage_bar() -> void:
	_progress_back.visible = needs_repair()
	_progress_fill.visible = needs_repair()
	_progress_fill.size = Vector2(_progress_back.size.x * health_fraction(), 2)
	_progress_fill.color = Color(0.85, 0.35, 0.3, 0.9)


# --- Presentation ----------------------------------------------------------------------

func _refresh_visuals() -> void:
	if state == State.COMPLETE:
		# Finished paths are rendered as one connected surface by PathSurfaceView.
		# Keep their ordinary sprite for blueprints so placement remains legible.
		_sprite.visible = def.path_tier <= 0
		_sprite.modulate = Color.WHITE
		_progress_back.visible = false
		_progress_fill.visible = false
		return

	_sprite.visible = true

	# Being pulled apart. Warm and fading rather than the cold blue of a blueprint, so a teardown
	# never reads as something going up — the two are opposite intentions and the player has to be
	# able to tell them apart at a glance across a busy village.
	if state == State.DEMOLISHING:
		_progress_back.visible = true
		_progress_fill.visible = true
		var left := 1.0 - clampf(demolish_done / demolish_work(), 0.0, 1.0)
		_sprite.modulate = Color(0.95, 0.72, 0.5, 0.30 + 0.55 * left)
		_progress_fill.color = Color(0.93, 0.66, 0.36, 0.9)
		_progress_fill.size = Vector2(_progress_back.size.x * left, 2)
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
	var target: int = World.nearest_walkable(centre_cell())
	return target
