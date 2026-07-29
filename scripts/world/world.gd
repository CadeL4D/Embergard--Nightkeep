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

const MAP_WIDTH := 128
const MAP_HEIGHT := 128

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

var seed_value: int = 0
var keep_cell: int = -1
var nest_cells: PackedInt32Array = PackedInt32Array()

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

func generate(new_seed: int) -> void:
	seed_value = new_seed
	grid.resize(MAP_WIDTH, MAP_HEIGHT)

	var result := MapGen.generate(grid, new_seed)
	terrain = result.terrain
	feature = result.feature
	keep_cell = result.keep_cell
	nest_cells = result.nest_cells

	occupancy = PackedInt32Array()
	occupancy.resize(grid.cell_count)
	claimed = PackedInt32Array()
	claimed.resize(grid.cell_count)
	light = PackedByteArray()
	light.resize(grid.cell_count)
	blight = PackedByteArray()
	blight.resize(grid.cell_count)

	light_field.setup(self)
	blight_field.setup(self)
	for nest in nest_cells:
		blight_field.seed_at(nest, 200)

	rebuild_move_cost()
	paths.setup(self)
	resources.setup(self)
	Events.map_generated.emit()


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
		move_cost[i] = mini(c, 254)
	cost_dirty = false


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


func is_blighted(i: int) -> bool:
	return blight[i] > 0


func light_at(i: int) -> int:
	return light[i] if grid.is_valid_index(i) else 0


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
