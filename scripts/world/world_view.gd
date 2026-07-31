extends Node2D
## Renders World's grid arrays into the scene's TileMapLayers and blight overlay.
## A pure VIEW — it reads World and never writes to it, and nothing in the sim ever
## reads back from here.
##
## The node tree (TerrainLayer, Sorted/FeatureLayer, BlightOverlay) lives in
## run.tscn with its TileSet and shader assigned in the inspector, so the art can be
## swapped or retuned without touching this file. All this script does is decide
## which tile goes in which cell.

@onready var terrain_layer: TileMapLayer = $TerrainLayer
@onready var decor_layer: TileMapLayer = $DecorLayer
@onready var feature_layer: TileMapLayer = $Sorted/FeatureLayer
@onready var blight_overlay: ColorRect = $BlightOverlay
@onready var influence_overlay: ColorRect = $InfluenceOverlay

## Atlas source id inside terrain_tiles.tres. Only one source, so it is always 0.
const SOURCE_ID := 0

## The four orthogonal offsets, as a TYPED const.
##
## Typed because an inline `[Vector2i(1, 0), ...]` literal yields Variant elements, so `coord +
## offset` could not be inferred and the parser refused it. Hoisted because these loops run once per
## feature cell on a full repaint — 12k iterations that would otherwise rebuild the array each time.
const NEIGHBOURS_4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]


func _ready() -> void:
	Events.map_generated.connect(_on_map_generated)
	Events.terrain_changed.connect(_on_terrain_changed)
	Events.blight_changed.connect(_on_blight_changed)
	Events.placement_mode_changed.connect(_on_placement_mode_changed)


func _on_map_generated() -> void:
	var grid: Grid = World.grid
	terrain_layer.clear()
	decor_layer.clear()
	feature_layer.clear()

	for i in grid.cell_count:
		var c := grid.coord(i)
		_paint_terrain(i, c)
		_paint_decor(i, c)
		_paint_feature(i, c)

	_fit_overlay()


## Lay down one feature tile. Forests and quarries use a four-way connection
## mask: full-bleed on shared sides, irregular on exposed sides. Berry thickets
## are drawn by FeatureDetails so neighboring bushes can overlap beyond one tile.
##
## Nothing extra is saved; harvesting a cell repaints it and its four neighbors,
## which exposes a correctly shaped new rim automatically.
func _paint_feature(cell: int, c: Vector2i) -> void:
	var f := World.feature[cell]
	if f == Terrain.Feature.NONE:
		feature_layer.erase_cell(c)
		return
	if f == Terrain.Feature.BERRIES:
		# The old atlas icon was an isolated eye-shaped shrub. The view-only
		# detail layer now draws a full overlapping bush for this same cell.
		feature_layer.erase_cell(c)
		return
	if TileAtlas.is_connected_feature(f):
		var mask := _connection_mask(cell, f)
		var variant := TileAtlas.connected_variant_for(c.x, c.y, f)
		feature_layer.set_cell(c, SOURCE_ID, TileAtlas.connected_coords(f, mask, variant))
		return
	feature_layer.set_cell(c, SOURCE_ID,
		TileAtlas.feature_coords(f, TileAtlas.feature_variant_for(c.x, c.y)))


## Build the N/E/S/W connection mask used to select the atlas tile.
func _connection_mask(cell: int, feature: int) -> int:
	var grid: Grid = World.grid
	var c := grid.coord(cell)
	var mask := 0
	var north := c + Vector2i(0, -1)
	var east := c + Vector2i(1, 0)
	var south := c + Vector2i(0, 1)
	var west := c + Vector2i(-1, 0)
	if not grid.is_valid_v(north) or World.feature[grid.index_v(north)] == feature:
		mask |= TileAtlas.MASK_NORTH
	if not grid.is_valid_v(east) or World.feature[grid.index_v(east)] == feature:
		mask |= TileAtlas.MASK_EAST
	if not grid.is_valid_v(south) or World.feature[grid.index_v(south)] == feature:
		mask |= TileAtlas.MASK_SOUTH
	if not grid.is_valid_v(west) or World.feature[grid.index_v(west)] == feature:
		mask |= TileAtlas.MASK_WEST
	return mask


## Lay down the ground tile for a cell — corrupted or clean, whichever the Blight says.
##
## The variant hash is taken from the position and NOT re-rolled for the corrupted form, so a tile
## that turns keeps the same silhouette it had when it was clean. Re-rolling made corruption look
## like the ground was being shuffled rather than spoiled.
func _paint_terrain(cell: int, c: Vector2i) -> void:
	var t := World.terrain[cell]
	var variant := TileAtlas.variant_for(c.x, c.y)
	var coords := TileAtlas.terrain_coords(t, variant)
	if World.blight[cell] >= TileAtlas.CORRUPT_THRESHOLD and TileAtlas.is_corruptible(t):
		coords = TileAtlas.corrupt_terrain_coords(t, variant)
	terrain_layer.set_cell(c, SOURCE_ID, coords)


## Add small, non-interactive marks to otherwise empty terrain.
##
## The density and choice are derived from position, so this costs no saved state
## and a repainted cell always gets the same tuft, crack or glint. Real features
## always win; dressing is erased beneath anything the player can interact with.
func _paint_decor(cell: int, c: Vector2i) -> void:
	if World.feature[cell] != Terrain.Feature.NONE:
		decor_layer.erase_cell(c)
		return

	var h := absi(c.x * 83492791 ^ c.y * 2654435761)
	var choices: Array[int] = []
	var density := 44
	match World.terrain[cell]:
		Terrain.Type.GRASS:
			choices = [0, 1, 7]
			density = 58
		Terrain.Type.DIRT:
			choices = [3, 1, 2]
		Terrain.Type.ROCK:
			choices = [2, 6]
		Terrain.Type.SAND:
			choices = [4, 1]
		Terrain.Type.WATER, Terrain.Type.DEEP_WATER:
			choices = [5]
			density = 28
		Terrain.Type.RUBBLE:
			choices = [6, 3, 2]

	if choices.is_empty() or h % 100 >= density:
		decor_layer.erase_cell(c)
		return
	var pick := choices[posmod(h >> 7, choices.size())]
	decor_layer.set_cell(c, SOURCE_ID, TileAtlas.decor_coords(pick))


## Repaint one cell when its corruption crosses the threshold in either direction.
##
## Driven by an event rather than by polling the whole grid: the Blight only touches a handful of
## cells a second, and sweeping 16,000 tiles looking for changes would cost far more than the
## thing it is watching.
func _on_blight_changed(cell: int, _blighted: bool) -> void:
	if World.grid.is_valid_index(cell):
		_paint_terrain(cell, World.grid.coord(cell))


## Repaint a changed cell AND its four neighbours.
##
## The neighbours are the point. Felling a tree in the middle of a wood does not just empty that
## cell — it turns the four cells around it from interior into rim, and without repainting them the
## hole would be a clean square punched out of an unbroken canopy. Repainting them is what makes the
## gap read as something that was cut.
##
## Five set_cell calls per harvest is nothing; the alternative was tracking an edge set.
func _on_terrain_changed(cell: int) -> void:
	var grid: Grid = World.grid
	_paint_decor(cell, grid.coord(cell))
	_paint_feature(cell, grid.coord(cell))
	var c := grid.coord(cell)
	for offset in NEIGHBOURS_4:
		var n := c + offset
		if grid.is_valid_v(n):
			_paint_feature(grid.index_v(n), n)


## Stretch the blight ColorRect over the whole map and hand its shader the live
## intensity texture. Done once per generation rather than per frame — the texture
## object is stable; only its contents change.
func _fit_overlay() -> void:
	var grid: Grid = World.grid
	var rect := grid.world_rect()
	blight_overlay.position = rect.position
	blight_overlay.size = rect.size

	var mat: ShaderMaterial = blight_overlay.material
	if mat == null:
		push_warning("BlightOverlay has no ShaderMaterial assigned")
		return
	mat.set_shader_parameter("blight_tex", World.blight_field.texture)
	mat.set_shader_parameter("grid_size", Vector2(grid.width, grid.height))
	# The shader generates its speckle at the tileset's own pixel density so corrupted ground has
	# the same grain as the terrain it replaces. Passed rather than hardcoded in the shader so the
	# two cannot disagree if TILE_SIZE ever changes.
	mat.set_shader_parameter("tile_px", float(Grid.TILE_SIZE))
	# Handed over rather than duplicated in the shader: the shader draws the creeping band and the
	# baked tiles take over above this line, so if the two disagree the transition either
	# double-draws or leaves a gap.
	mat.set_shader_parameter("tile_takeover", float(TileAtlas.CORRUPT_THRESHOLD) / 255.0)

	influence_overlay.position = rect.position
	influence_overlay.size = rect.size
	var influence_mat: ShaderMaterial = influence_overlay.material
	if influence_mat == null:
		push_warning("InfluenceOverlay has no ShaderMaterial assigned")
		return
	influence_mat.set_shader_parameter("influence_tex", World.influence_texture)
	influence_mat.set_shader_parameter("grid_size", Vector2(grid.width, grid.height))
	influence_mat.set_shader_parameter("tile_px", float(Grid.TILE_SIZE))
	# The threshold the shader draws the line at MUST be the one placement enforces. Handed over
	# rather than written into the shader, because a boundary the player can see in one place and
	# not build up to in the other is the single worst bug this feature could ship with.
	influence_mat.set_shader_parameter("threshold", float(World.INFLUENCE_MIN) / 255.0)


## Only shown while placing. See Events.placement_mode_changed.
func _on_placement_mode_changed(active: bool) -> void:
	influence_overlay.visible = active
