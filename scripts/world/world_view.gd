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
@onready var feature_layer: TileMapLayer = $Sorted/FeatureLayer
@onready var blight_overlay: ColorRect = $BlightOverlay

## Atlas source id inside terrain_tiles.tres. Only one source, so it is always 0.
const SOURCE_ID := 0


func _ready() -> void:
	Events.map_generated.connect(_on_map_generated)
	Events.terrain_changed.connect(_on_terrain_changed)


func _on_map_generated() -> void:
	var grid: Grid = World.grid
	terrain_layer.clear()
	feature_layer.clear()

	for i in grid.cell_count:
		var c := grid.coord(i)
		var variant := TileAtlas.variant_for(c.x, c.y)
		terrain_layer.set_cell(c, SOURCE_ID, TileAtlas.terrain_coords(World.terrain[i], variant))
		var f := World.feature[i]
		if f != Terrain.Feature.NONE:
			feature_layer.set_cell(c, SOURCE_ID,
				TileAtlas.feature_coords(f, TileAtlas.feature_variant_for(c.x, c.y)))

	_fit_overlay()


func _on_terrain_changed(cell: int) -> void:
	var c := World.grid.coord(cell)
	var f := World.feature[cell]
	if f == Terrain.Feature.NONE:
		feature_layer.erase_cell(c)
	else:
		feature_layer.set_cell(c, SOURCE_ID, TileAtlas.feature_coords(f))


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
