extends Node2D
## Pixel-rugged seams between ground materials and fully corrupted tiles.
##
## Terrain remains one simulation cell per tile. This view paints narrow,
## deterministic teeth across unlike borders so coastlines, soil patches, and
## corruption no longer reveal the square grid underneath.

const BASE: Array[Color] = [
	Color("0a1928"), # deep water
	Color("16354b"), # water
	Color("7b6748"), # sand
	Color("29462e"), # grass
	Color("443423"), # dirt
	Color("665847"), # exposed rock
	Color("684e32"), # rubble
]
const EDGE: Array[Color] = [
	Color("16354b"),
	Color("28627c"),
	Color("625039"),
	Color("1a2b1d"),
	Color("281f16"),
	Color("4b4035"),
	Color("443423"),
]
const PRIORITY: Array[int] = [0, 1, 2, 4, 3, 5, 6]
const CORRUPT_BASE := Color("58163a")
const CORRUPT_EDGE := Color("2e0a1c")
const SEGMENT := 2


func _ready() -> void:
	Events.map_generated.connect(queue_redraw)
	Events.terrain_changed.connect(func(_cell: int) -> void: queue_redraw())
	Events.blight_changed.connect(
		func(_cell: int, _blighted: bool) -> void: queue_redraw())


func _draw() -> void:
	if World.terrain.size() != World.grid.cell_count:
		return
	var grid := World.grid
	for y in grid.height:
		for x in grid.width:
			var cell := grid.index(x, y)
			if x + 1 < grid.width:
				_draw_vertical(cell, grid.index(x + 1, y), x + 1, y)
			if y + 1 < grid.height:
				_draw_horizontal(cell, grid.index(x, y + 1), x, y + 1)


func _draw_vertical(left: int, right: int, seam_x: int, tile_y: int) -> void:
	if not _needs_seam(left, right):
		return
	var source_left := _source_is_first(left, right)
	var source := left if source_left else right
	var base := _cell_base(source)
	var edge := _cell_edge(source)
	var x := float(seam_x * Grid.TILE_SIZE)
	var y := float(tile_y * Grid.TILE_SIZE)
	for offset in range(0, Grid.TILE_SIZE, SEGMENT):
		var depth := _seam_depth(seam_x, tile_y * Grid.TILE_SIZE + offset, source)
		var rect := Rect2(
			x if source_left else x - depth,
			y + offset,
			depth,
			SEGMENT)
		draw_rect(rect, base, true)
		var rim_x := x + depth - 1.0 if source_left else x - depth
		draw_rect(Rect2(rim_x, y + offset, 1, SEGMENT), edge, true)
		_draw_vertical_fleck(x, y + offset, depth, source_left, source, base)


func _draw_horizontal(top: int, bottom: int, tile_x: int, seam_y: int) -> void:
	if not _needs_seam(top, bottom):
		return
	var source_top := _source_is_first(top, bottom)
	var source := top if source_top else bottom
	var base := _cell_base(source)
	var edge := _cell_edge(source)
	var x := float(tile_x * Grid.TILE_SIZE)
	var y := float(seam_y * Grid.TILE_SIZE)
	for offset in range(0, Grid.TILE_SIZE, SEGMENT):
		var depth := _seam_depth(tile_x * Grid.TILE_SIZE + offset, seam_y, source)
		var rect := Rect2(
			x + offset,
			y if source_top else y - depth,
			SEGMENT,
			depth)
		draw_rect(rect, base, true)
		var rim_y := y + depth - 1.0 if source_top else y - depth
		draw_rect(Rect2(x + offset, rim_y, SEGMENT, 1), edge, true)
		_draw_horizontal_fleck(x + offset, y, depth, source_top, source, base)


func _needs_seam(first: int, second: int) -> bool:
	return World.terrain[first] != World.terrain[second] \
		or _is_corrupt(first) != _is_corrupt(second)


func _source_is_first(first: int, second: int) -> bool:
	var first_corrupt := _is_corrupt(first)
	var second_corrupt := _is_corrupt(second)
	if first_corrupt != second_corrupt:
		return first_corrupt
	var first_type := int(World.terrain[first])
	var second_type := int(World.terrain[second])
	if PRIORITY[first_type] == PRIORITY[second_type]:
		return _hash(first, second, World.seed_value) % 2 == 0
	return PRIORITY[first_type] > PRIORITY[second_type]


func _cell_base(cell: int) -> Color:
	return CORRUPT_BASE if _is_corrupt(cell) else BASE[int(World.terrain[cell])]


func _cell_edge(cell: int) -> Color:
	return CORRUPT_EDGE if _is_corrupt(cell) else EDGE[int(World.terrain[cell])]


func _is_corrupt(cell: int) -> bool:
	return World.blight[cell] >= TileAtlas.CORRUPT_THRESHOLD \
		and TileAtlas.is_corruptible(int(World.terrain[cell]))


func _seam_depth(x: int, y: int, source: int) -> float:
	# Three-to-eight pixels breaks the visible 16-pixel stair-step while retaining
	# enough of both authored terrain textures to read the materials.
	return float(3 + _hash(x, y, source + World.seed_value) % 6)


func _draw_vertical_fleck(
		seam_x: float, y: float, depth: float, source_left: bool,
		source: int, color: Color) -> void:
	if _hash(roundi(seam_x), roundi(y), source) % 5 != 0:
		return
	var x := seam_x + depth + 1.0 if source_left else seam_x - depth - 2.0
	draw_rect(Rect2(x, y + float(_hash(source, roundi(y), 31) % 2), 1, 1), color, true)


func _draw_horizontal_fleck(
		x: float, seam_y: float, depth: float, source_top: bool,
		source: int, color: Color) -> void:
	if _hash(roundi(x), roundi(seam_y), source) % 5 != 0:
		return
	var y := seam_y + depth + 1.0 if source_top else seam_y - depth - 2.0
	draw_rect(Rect2(x + float(_hash(source, roundi(x), 47) % 2), y, 1, 1), color, true)


static func _hash(a: int, b: int, salt: int) -> int:
	var value := a * 92837111 ^ b * 689287499 ^ salt * 283923481
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))
