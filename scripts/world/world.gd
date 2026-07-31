extends Node
## Autoload: the authoritative world state — every grid layer, plus map generation.
##
## GOLDEN RULE: gameplay never queries a TileMapLayer. The TileMapLayer is a *view*
## rendered from these arrays. Anything that asks "is this walkable / lit / blighted"
## asks World. Breaking this rule is how a project like this ends up needing a
## rewrite in month three, because the renderer and the sim slowly disagree.
##
## Layers, all flat arrays of grid.cell_count indexed y * width + x:
##   terrain   PackedByteArray  Terrain.Type       — what the ground is
##   feature   PackedByteArray  Terrain.Feature    — what sits on it
##   occupancy PackedInt32Array building instance id, or 0 for empty (PATHING)
##   claimed   PackedInt32Array building instance id, or 0 for empty (PLACEMENT)
##   light     PackedByteArray  0-255              — gameplay light, not the renderer's
##   blight    PackedByteArray  0-255 intensity
##   move_cost PackedByteArray  1-254, 255 = impassable (derived; never saved)
##   gate      PackedByteArray  1 where a gate stands (derived; never saved)
##   path_tier PackedByteArray  0 = bare ground, 1+ = road of that tier (derived)
##   influence PackedByteArray  0-255 buildable sphere strength (derived)

## 112 rather than 128 — and 96 was tried and rejected.
##
## 16k cells read as a plain with a village somewhere on it: the colony occupied a corner and the
## map's own scale worked against the thing the game is about, which is a small place you are trying
## to hold. Smaller is better here, but there is a hard floor and it is not a layout constraint.
##
## Two numbers fight. `MapGen._fill_terrain` puts the coastline at roughly 0.62 of the half-width, so
## the LAND radius is about 0.62 * (size / 2). And `MapGen.NEST_MIN_DIST` is not really a layout
## figure at all — it is the horde's APPROACH TIME, which is the entire warning the player gets
## before a wave lands. Nests must sit inside the land radius AND far enough out to give that warning:
##
##   size 128 -> land radius ~40, nests at 34    comfortable
##   size 112 -> land radius ~35, nests at 30    workable, and what shipped
##   size  96 -> land radius ~30, nests at 32    impossible
##
## At 96 the nest ring falls in open water, `_find_nest_site_near` fails, the fallback bunches every
## nest onto one mid-ring position, and the concentrated spawns wiped the colony outright — the smoke
## test went from all-green to nine failures with the whole population dead. Scaling the ring down
## proportionally instead (to 26) halved the approach time and overran the colony a different way:
## six survivors down to two before the farm check.
##
## Going below 112 needs the island falloff widened, not a constant retuned. Left as a Phase 6 item.
##
## 112 is also 23% fewer cells, which every full-map pass benefits from: the move-cost rebuild, the
## flow field sweep, the influence stamp and the blight texture upload.
const MAP_WIDTH := 112
const MAP_HEIGHT := 112

var grid: Grid = Grid.new(MAP_WIDTH, MAP_HEIGHT)

var terrain: PackedByteArray = PackedByteArray()
var feature: PackedByteArray = PackedByteArray()
var occupancy: PackedInt32Array = PackedInt32Array()
## Ground spoken for by a building, from the instant the blueprint goes down.
## Deliberately NOT the same layer as occupancy: occupancy is about pathing and is
## only stamped when a building COMPLETES, because builders have to be able to walk
## onto a site to raise it. That left unfinished sites invisible to placement, so a
## second hut could be dropped straight on top of one already under construction.
var claimed: PackedInt32Array = PackedInt32Array()
var light: PackedByteArray = PackedByteArray()
var blight: PackedByteArray = PackedByteArray()
var move_cost: PackedByteArray = PackedByteArray()
## Cells holding a gate. Deliberately its OWN layer rather than a lookup through
## `occupancy` into the building instance: the monster flow field reads this once per
## cell per rebuild, and resolving an instance id to a node 16,000 times a sweep is
## exactly the kind of cost this codebase avoids everywhere else.
##
## Not saved — restored for free, because loading a run calls Building.complete()
## on every finished structure and that is where the stamp happens.
var gate: PackedByteArray = PackedByteArray()

## Road surface per cell. Feeds rebuild_move_cost, so villagers prefer a road exactly in
## proportion to how much time it saves them — which is precisely "prefer paths but do not walk
## out of your way for one", with no AI code at all.
##
## Not saved, for the same reason `gate` is not: every finished road stamps itself in
## Building.complete() when a run is loaded.
var path_tier: PackedByteArray = PackedByteArray()

## The buildable sphere. 0 is outside it; placement needs INFLUENCE_MIN or better.
##
## A layer rather than a per-building radius test at placement time, because the UI needs to
## DRAW the boundary (one R8 texture, one shader, one draw call — the same trick BlightField
## uses) and because `check_placement` already validates cell by cell.
var influence: PackedByteArray = PackedByteArray()
## Mirror of `influence` for the overlay shader. See BlightField for why this is a texture
## rather than a TileMapLayer.
var influence_image: Image = null
var influence_texture: ImageTexture = null
## Whether any cell clears INFLUENCE_MIN. See has_influence().
var _influence_any: bool = false

var seed_value: int = 0
var keep_cell: int = -1
var region_profile: Dictionary = {}
var biome_id: StringName = Biomes.DEFAULT_ID
## Every nest site the map generated, live or cleared. Kept whole rather than pruned so
## the end-of-run tally can still count how many were destroyed — ask
## `live_nest_cells()` for the ones that still matter.
var nest_cells: PackedInt32Array = PackedInt32Array()
## Remaining hit points per live nest, keyed by cell. A Dictionary rather than a map
## layer because there are only ever a handful of nests on a 16k-cell map.
var nest_hp: Dictionary = {}

## The Blight's own buildings: cell -> {"kind": StringName, "hp": float}.
##
## A Dictionary keyed by cell, exactly like nest_hp, and for the same reason: there are only ever a
## few dozen on the map, and modelling them as nodes would mean a parallel version of everything
## nests already get for free — tower targeting, Wrath, Ward, Consecrate, occupancy, save/load.
##
## They are, mechanically, nests with different art and different side effects. Treating them as
## anything else would have been a second system to keep in step with the first.
var blight_structures: Dictionary = {}

## Walkable cells with open water next to them — where a villager can kneel and drink.
##
## Precomputed once per map rather than searched on demand: water is terrain, so the
## ResourceIndex (which indexes features) cannot answer this, and sweeping 16k cells every
## time somebody got thirsty would be absurd. A coastline is only a few hundred cells, so a
## linear nearest-scan over this is cheap and needs no spatial structure.
var shore_cells: PackedInt32Array = PackedInt32Array()

var light_field: LightField
var blight_field: BlightField
var paths: PathService
var resources: ResourceIndex

## Set true by any change that invalidates pathing, so the flow fields and the
## AStar mirror rebuild lazily instead of once per individual tile edit.
var cost_dirty: bool = false


func _ready() -> void:
	light_field = LightField.new()
	blight_field = BlightField.new()
	paths = PathService.new()
	resources = ResourceIndex.new()


## Sim's current tick, read defensively so PathService can age its queue without
## World and Sim having to know about each other's init order.
func tick_hint() -> int:
	return Sim.tick if Sim else 0


# --- Generation ---------------------------------------------------------------------

## Build one local map. `keep_override` restores an existing colony's center; `region_profile`
## makes a new map reflect the selected macro biome and its resources.
func generate(new_seed: int, keep_override: int = -1, region_profile: Dictionary = {}) -> void:
	seed_value = new_seed
	self.region_profile = region_profile.duplicate(true)
	biome_id = StringName(region_profile.get("biome", Biomes.DEFAULT_ID))
	grid.resize(MAP_WIDTH, MAP_HEIGHT)

	var result := MapGen.generate(grid, new_seed, keep_override, region_profile)
	terrain = result.terrain
	feature = result.feature
	keep_cell = result.keep_cell
	nest_cells = result.nest_cells
	rebuild_nest_hp()

	occupancy = PackedInt32Array()
	occupancy.resize(grid.cell_count)
	claimed = PackedInt32Array()
	claimed.resize(grid.cell_count)
	light = PackedByteArray()
	light.resize(grid.cell_count)
	blight = PackedByteArray()
	blight.resize(grid.cell_count)
	gate = PackedByteArray()
	gate.resize(grid.cell_count)
	path_tier = PackedByteArray()
	path_tier.resize(grid.cell_count)
	influence = PackedByteArray()
	influence.resize(grid.cell_count)
	# A fresh map has no sphere until something is raised on it, so placement is unrestricted until
	# the founding Village Center stamps one. Reset explicitly — a stale true here would gate the
	# next run's first building against the previous run's boundary.
	_influence_any = false
	influence_image = Image.create(grid.width, grid.height, false, Image.FORMAT_R8)
	influence_image.fill(Color(0, 0, 0, 1))
	influence_texture = ImageTexture.create_from_image(influence_image)

	light_field.setup(self)
	blight_field.setup(self)
	for nest in nest_cells:
		blight_field.seed_at(nest, 200)
	_seed_regional_blight(region_profile)

	rebuild_move_cost()
	_build_shore_index()
	paths.setup(self)
	resources.setup(self)
	Events.map_generated.emit()


func _seed_regional_blight(region_profile: Dictionary) -> void:
	if region_profile.is_empty():
		return
	var corruption := float(region_profile.get("corruption", 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ 0x6A09E667
	var keep := grid.coord(keep_cell)
	var patch_centers: Array[Vector2i] = []
	var wanted_patches := 2 + int(round(corruption * 3.0))
	for _patch in wanted_patches:
		var center := Vector2i(-1, -1)
		for _attempt in 240:
			var candidate := grid.coord(rng.randi_range(0, grid.cell_count - 1))
			if not Terrain.WALKABLE.get(terrain[grid.index_v(candidate)], false):
				continue
			if Vector2(candidate - keep).length() < 18.0:
				continue
			var clear := true
			for existing: Vector2i in patch_centers:
				if Vector2(candidate - existing).length() < 12.0:
					clear = false
					break
			if clear:
				center = candidate
				break
		if center.x < 0:
			continue
		patch_centers.append(center)
		var cells_in_patch := 2 + int(round(corruption * 3.0))
		var offsets := [
			Vector2i.ZERO, Vector2i.RIGHT, Vector2i.DOWN,
			Vector2i.LEFT, Vector2i.UP,
		]
		for i in mini(cells_in_patch, offsets.size()):
			var point: Vector2i = center + offsets[i]
			if not grid.is_valid_v(point):
				continue
			var cell := grid.index_v(point)
			if Terrain.WALKABLE.get(terrain[cell], false):
				blight_field.seed_at(cell, int(42.0 + corruption * 72.0))


## Find every walkable cell that touches open water. Must run after rebuild_move_cost,
## because it asks whether a cell can be stood on.
func _build_shore_index() -> void:
	shore_cells = PackedInt32Array()
	for i in grid.cell_count:
		if not is_walkable(i):
			continue
		for n in grid.neighbours_4(i):
			var t := terrain[n]
			if t == Terrain.Type.WATER or t == Terrain.Type.DEEP_WATER:
				shore_cells.append(i)
				break


## Full rebuild of the derived cost layer. Cheap enough (one linear pass) that it is
## not worth doing incrementally — call it whenever cost_dirty is set.
func rebuild_move_cost() -> void:
	move_cost.resize(grid.cell_count)
	for i in grid.cell_count:
		if occupancy[i] != 0:
			move_cost[i] = 255
			continue
		var t := terrain[i]
		var f := feature[i]
		if not Terrain.is_walkable(t, f):
			move_cost[i] = 255
			continue
		var c := Terrain.move_cost(t)
		# Blighted ground drags on villagers. Monsters ignore this (they read their
		# own flow field, built with a different cost function).
		c += (blight[i] * 6) / 255
		# A road overrides the terrain underneath it rather than discounting it, so a paved
		# route across marsh is as quick as a paved route across grass. That is the whole
		# reason to pave the marsh.
		var road := path_tier[i]
		if road > 0:
			c = PATH_COST[mini(road, PATH_COST.size() - 1)]
		move_cost[i] = mini(c, 254)
	cost_dirty = false


# --- Paths -------------------------------------------------------------------------------

## Move cost by path tier. Index 0 is unused (bare ground keeps its terrain cost).
##
## Terrain.move_cost puts open grass at 10, so tier 1 is a modest saving, tier 2 clearly worth
## the stone and tier 3 close to the floor. Villagers A* over exactly this array, so nothing
## else has to be told that roads are preferable — a route that saves cost wins, and one that
## costs a long detour does not, which is precisely the behaviour asked for.
const PATH_COST: Array[int] = [10, 7, 5, 3]

## Lay or lift a road. Cost is derived, so this only has to flip the layer and mark it dirty.
func set_path_tier(cells: PackedInt32Array, tier: int) -> void:
	for i in cells:
		if grid.is_valid_index(i):
			path_tier[i] = tier
	cost_dirty = true
	# Roads change how the horde wants to come in too — see FlowField._cell_cost.
	if Threat:
		Threat.mark_field_dirty()


## Walk-speed multiplier for a cell, used by Agent to make the road actually FASTER rather than
## merely more attractive to the pathfinder.
##
## Derived from the same PATH_COST table that pathing uses, so the two can never disagree about
## which surface is quicker. Without this, roads changed the route villagers chose and not the
## time they took, which reads as the feature doing nothing.
func speed_at(i: int) -> float:
	if not grid.is_valid_index(i):
		return 1.0
	var road := path_tier[i]
	var road_multiplier := 1.0 if road == 0 else \
		float(PATH_COST[0]) / float(PATH_COST[mini(road, PATH_COST.size() - 1)])
	return road_multiplier * Climate.movement_multiplier(terrain_at(i))


# --- Sphere of influence ------------------------------------------------------------------

## Minimum influence a cell needs before anything may be built on it.
##
## Low on purpose. The sphere is a leash on sprawl, not a precision tool — the interesting
## decision is which direction to grow, and a high threshold would turn every placement into
## fighting the boundary by one tile.
const INFLUENCE_MIN := 40

## Recompute the buildable sphere from scratch.
##
## A full rebuild rather than incremental stamping, and deliberately so: contributions are
## ADDITIVE, so removing one building would require unstamping a disc that has been summed with
## its neighbours' — the classic drifting-accumulator bug. There are only ever a few dozen
## buildings, each covering a small disc, so recomputing on completion and destruction is
## cheaper than the bookkeeping would be, and it cannot go stale.
func rebuild_influence() -> void:
	if influence.size() != grid.cell_count:
		influence.resize(grid.cell_count)
	influence.fill(0)

	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		# Typed local: `b` is a plain Node, so `b.def` is a Variant and every field read off it
		# would go unchecked, including the int handed to _stamp_influence.
		var def: BuildingDef = b.def
		if def.influence_radius <= 0:
			continue
		_stamp_influence(b.centre_cell(), def.influence_radius)

	_upload_influence()


## One radial falloff, accumulated with saturation.
##
## Summing is what makes the boundary amorphous instead of a union of circles: where two
## buildings' skirts overlap the total clears the threshold further out than either would alone,
## so the sphere bulges toward whatever the player has been developing. A max() here would give
## scalloped circle edges and no directional growth at all.
func _stamp_influence(centre: int, radius: int) -> void:
	if not grid.is_valid_index(centre) or radius <= 0:
		return
	var c := grid.coord(centre)
	var r_sq := radius * radius
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var d_sq := dx * dx + dy * dy
			if d_sq > r_sq:
				continue
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			var i := grid.index(c.x + dx, c.y + dy)
			var falloff := 1.0 - sqrt(float(d_sq)) / float(radius)
			influence[i] = mini(influence[i] + int(falloff * 255.0), 255)


func _upload_influence() -> void:
	# The "is there a sphere at all" flag is recomputed here rather than in rebuild_influence,
	# because this is the one pass that already visits every cell.
	_influence_any = false
	if influence_image == null:
		for i in grid.cell_count:
			if influence[i] >= INFLUENCE_MIN:
				_influence_any = true
				break
		return
	for i in grid.cell_count:
		var c := grid.coord(i)
		if influence[i] >= INFLUENCE_MIN:
			_influence_any = true
		influence_image.set_pixel(c.x, c.y, Color(float(influence[i]) / 255.0, 0.0, 0.0, 1.0))
	if influence_texture != null:
		influence_texture.update(influence_image)
	Events.influence_changed.emit()


func influence_at(i: int) -> int:
	return influence[i] if grid.is_valid_index(i) else 0


func in_influence(i: int) -> bool:
	# A colony with no sphere at all may build anywhere. This is not a special case for the Hearth —
	# it is the resolution of a genuine chicken-and-egg: influence is granted BY standing buildings,
	# so gating the first one on it meant the founding Village Center could never be placed, the run
	# fell back to a bare stockpile, and every subsequent placement failed too.
	#
	# Stated as "is there a sphere yet" rather than "is this the Hearth" so it also covers a scenario
	# or a later colony type that founds itself with something else.
	if not has_influence():
		return true
	return influence_at(i) >= INFLUENCE_MIN


## Does any ground at all fall inside the buildable sphere?
##
## Tracked as a flag maintained by rebuild_influence rather than scanned per query: this is asked
## once per cell of every placement check, and sweeping 16k bytes each time would make dragging a
## 3x2 ghost cost six full-map passes per frame.
func has_influence() -> bool:
	return _influence_any


# --- Per-tick ---------------------------------------------------------------------

func step(tick: int) -> void:
	blight_field.step(tick)
	if cost_dirty:
		rebuild_move_cost()
		paths.mark_dirty()
	paths.step(tick)


# --- Queries ------------------------------------------------------------------------

func is_walkable(i: int) -> bool:
	return grid.is_valid_index(i) and move_cost[i] < 255


## Can anything stand next to this cell?
##
## Necessary the moment trees started blocking movement. A dense clump is now a solid mass, and the
## cells in the MIDDLE of one cannot be harvested at all — there is nowhere for a woodcutter to stand.
## Without this check the resource index happily handed out an interior tree, the villager pathed to
## the nearest walkable cell several tiles away, failed `_within_reach`, dropped the claim and asked
## for the same tree again: a forest that looked full of work and produced nothing.
##
## With it, woodland is eaten from the edge inward, and each felled tree exposes the ones behind it.
func has_walkable_neighbour(i: int) -> bool:
	if not grid.is_valid_index(i):
		return false
	for n in grid.neighbours_4(i):
		if is_walkable(n):
			return true
	return false


func is_blighted(i: int) -> bool:
	return blight[i] > 0


func light_at(i: int) -> int:
	return int(float(light[i]) * Climate.light_multiplier()) if grid.is_valid_index(i) else 0


## Event-scale interventions. Both walk the byte field once, which is acceptable for a
## deliberate choice but would be inappropriate inside the regular simulation tick.
func repel_blight(cells_to_clean: int) -> int:
	var candidates: Array[int] = []
	for i in blight.size():
		if blight[i] > 0:
			candidates.append(i)
	candidates.sort_custom(func(a: int, b: int) -> bool: return blight[a] > blight[b])
	var cleaned := 0
	for i in mini(cells_to_clean, candidates.size()):
		if blight_field.purify(candidates[i], 255):
			cleaned += 1
	return cleaned


func seed_blight_surge(cells_to_seed: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value ^ (Sim.day * 65537) ^ 0xB117
	var seeded := 0
	var candidates := PackedInt32Array()
	for i in grid.cell_count:
		if blight[i] == 0 and is_walkable(i) and grid.chebyshev(i, keep_cell) > 14:
			candidates.append(i)
	for _i in mini(cells_to_seed, candidates.size()):
		var pick := rng.randi_range(0, candidates.size() - 1)
		var cell := candidates[pick]
		candidates.remove_at(pick)
		blight_field.seed_at(cell, 64)
		seeded += 1
	return seeded


func terrain_at(i: int) -> int:
	return terrain[i] if grid.is_valid_index(i) else Terrain.Type.DEEP_WATER


func feature_at(i: int) -> int:
	return feature[i] if grid.is_valid_index(i) else Terrain.Feature.NONE


func clear_feature(i: int) -> void:
	if not grid.is_valid_index(i) or feature[i] == Terrain.Feature.NONE:
		return
	var was := feature[i]
	feature[i] = Terrain.Feature.NONE
	# Drop it from the spatial index here rather than at every call site — a
	# harvested tree left in the index sends the next villager to walk to empty
	# ground, which reads as broken AI rather than a stale lookup table.
	if resources:
		resources.remove(i)
	if Terrain.FEATURE_BLOCKS.get(was, false):
		cost_dirty = true
	Events.terrain_changed.emit(i)


func set_occupancy(cells: PackedInt32Array, building_id: int) -> void:
	for i in cells:
		if grid.is_valid_index(i):
			occupancy[i] = building_id
	cost_dirty = true


# --- Nests -----------------------------------------------------------------------------

## Give every nest still standing in the FEATURE layer full health.
##
## Derived from `feature`, not from `nest_cells`, because a restored run overlays a
## feature layer in which some nests are already gone — seeding from the site list
## would resurrect everything the player had destroyed. Must therefore be called AFTER
## any feature overlay, not just at generation.
func rebuild_nest_hp() -> void:
	nest_hp.clear()
	for nest in nest_cells:
		if grid.is_valid_index(nest) and feature[nest] == Terrain.Feature.NEST:
			nest_hp[nest] = Terrain.NEST_HP


## Nests that are still alive. This is what the threat director should ask about:
## `nest_cells` is the historical site list and never shrinks, so using it to pick
## spawn points would keep pouring monsters out of a nest the player has already
## burned out — which is precisely the payoff clearing one is supposed to deliver.
func live_nest_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	for nest in nest_cells:
		if grid.is_valid_index(nest) and feature[nest] == Terrain.Feature.NEST:
			out.append(nest)
	return out


func is_nest(cell: int) -> bool:
	return grid.is_valid_index(cell) and feature[cell] == Terrain.Feature.NEST


## Hurt a nest. Returns true on the blow that destroys it.
##
## Clearing the feature is what makes the kill count: `nests_cleared` at the end of a
## run is measured by asking whether each site still holds a NEST, and the threat
## director stops spawning from it the moment this returns true.
func damage_nest(cell: int, amount: float) -> bool:
	if amount <= 0.0 or not is_nest(cell):
		return false
	var remaining: float = float(nest_hp.get(cell, Terrain.NEST_HP)) - amount
	if remaining > 0.0:
		nest_hp[cell] = remaining
		return false

	nest_hp.erase(cell)
	# Clearing the feature opens the ground up — NEST blocks movement, so this also
	# flips cost_dirty. The threat field has to be told separately: it only rebuilds on
	# structure changes and at nightfall, and it must stop treating this cell as a
	# spawn anchor and a wall.
	clear_feature(cell)
	# Rebuilt IMMEDIATELY rather than left for the next World.step. cost_dirty defers the pass to
	# the following tick, so until then `is_walkable` still reported the burnt-out nest as solid —
	# villagers could not path onto ground the player had just cleared, and any caller reading
	# walkability straight after a kill got the wrong answer. Nests die a handful of times a run,
	# so one extra linear pass costs nothing.
	rebuild_move_cost()
	paths.mark_dirty()
	if Threat:
		Threat.mark_field_dirty()
	Events.nest_destroyed.emit(cell)
	Events.notice.emit(tr(&"NOTICE_NEST_BURNED"), 1)
	return true


# --- The Blight's settlements -----------------------------------------------------------------

## Raise one. Returns false if the ground will not take it.
##
## Stamps occupancy, so an enemy structure is a real obstacle that reshapes both the monster flow
## field and villager pathing — the Blight's village genuinely gets in the way, which is most of
## what makes contesting it interesting.
func add_blight_structure(cell: int, def: BlightStructureDef) -> bool:
	if def == null or not grid.is_valid_index(cell):
		return false
	if blight_structures.has(cell) or is_nest(cell) or claimed[cell] != 0:
		return false
	if not Terrain.WALKABLE.get(terrain[cell], false):
		return false
	if feature[cell] != Terrain.Feature.NONE:
		return false

	blight_structures[cell] = {"kind": def.id, "hp": def.max_hp}
	# Negative id so it can never collide with a Building's instance id, and so anything reading
	# occupancy to find a building gets nothing rather than a wrong answer.
	occupancy[cell] = -cell - 1
	cost_dirty = true
	rebuild_move_cost()
	paths.mark_dirty()
	if def.glow > 0:
		light_field.add_source(cell, 3, def.glow)
	if Threat:
		Threat.mark_field_dirty()
	Events.blight_structure_raised.emit(cell, def.id)
	return true


func has_blight_structure(cell: int) -> bool:
	return blight_structures.has(cell)


func blight_structure_def(cell: int) -> BlightStructureDef:
	if not blight_structures.has(cell):
		return null
	return BlightStructures.get_structure(blight_structures[cell]["kind"])


## Hurt one. Returns true on the blow that levels it.
##
## Deliberately the same signature and semantics as damage_nest, so every existing attacker — towers,
## Wrath, Ward, Consecrate — can be pointed at these with one extra call rather than a new code path.
func damage_blight_structure(cell: int, amount: float) -> bool:
	if amount <= 0.0 or not blight_structures.has(cell):
		return false
	var entry: Dictionary = blight_structures[cell]
	var remaining: float = float(entry["hp"]) - amount
	if remaining > 0.0:
		entry["hp"] = remaining
		return false

	blight_structures.erase(cell)
	occupancy[cell] = 0
	cost_dirty = true
	# Rebuilt immediately for the same reason damage_nest does it: until the pass runs, `is_walkable`
	# still reports ground the player has just cleared as solid.
	rebuild_move_cost()
	paths.mark_dirty()
	if Threat:
		Threat.mark_field_dirty()
	Events.blight_structure_razed.emit(cell)
	Events.notice.emit(tr(&"NOTICE_BLIGHT_RAZED"), 1)
	return true


## Threat budget the enemy's settlement adds to a night, and the stat multiplier it grants.
##
## Summed here rather than in Threat so there is one place that knows what a standing structure is
## worth, and so a structure razed mid-night stops paying immediately.
func blight_threat_bonus() -> float:
	var total := 0.0
	for cell in blight_structures:
		var def := blight_structure_def(cell)
		if def != null:
			total += def.threat_bonus
	return total


func blight_monster_scale() -> float:
	var scale := 1.0
	for cell in blight_structures:
		var def := blight_structure_def(cell)
		if def != null:
			scale *= def.monster_scale
	# Capped: four totems should be frightening, not a run-ender that arrived without warning.
	return minf(scale, 2.5)


## 0.0-1.0 for a live nest, 0.0 for a dead one. For HUD readouts.
func nest_health_fraction(cell: int) -> float:
	if not is_nest(cell):
		return 0.0
	return clampf(float(nest_hp.get(cell, Terrain.NEST_HP)) / Terrain.NEST_HP, 0.0, 1.0)


## Stamp or clear gate cells. Villager pathing is untouched — a gate is walkable, so
## it never appears in `occupancy` — but the monster flow field has to be rebuilt,
## because a new gate changes where the horde wants to go.
func set_gate(cells: PackedInt32Array, present: bool) -> void:
	var value := 1 if present else 0
	for i in cells:
		if grid.is_valid_index(i):
			gate[i] = value
	if Threat:
		Threat.mark_field_dirty()


func is_gate(i: int) -> bool:
	return grid.is_valid_index(i) and gate[i] != 0


## Take ground for a building. Costs nothing to pathing — this layer exists purely so
## placement can see sites that are not finished yet.
func claim_cells(cells: PackedInt32Array, building_id: int) -> void:
	for i in cells:
		if grid.is_valid_index(i):
			claimed[i] = building_id


## Release ground, but only the cells this building still holds. A blanket zeroing
## would let a demolished building free tiles a neighbour had legitimately taken.
func release_cells(cells: PackedInt32Array, building_id: int) -> void:
	for i in cells:
		if grid.is_valid_index(i) and claimed[i] == building_id:
			claimed[i] = 0


func is_claimed(cell: int) -> bool:
	return grid.is_valid_index(cell) and claimed[cell] != 0


## Nearest walkable cell to `from`, searched outward. Used when a spawn point or a
## commanded destination lands on water or inside a wall — returning -1 and making
## the caller handle it produces far more bugs than just snapping to something sane.
func nearest_walkable(from: int, max_radius: int = 12) -> int:
	if is_walkable(from):
		return from
	var c := grid.coord(from)
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue                      # perimeter of the ring only
				var x := c.x + dx
				var y := c.y + dy
				if not grid.is_valid(x, y):
					continue
				var i := grid.index(x, y)
				if is_walkable(i):
					return i
	return -1
