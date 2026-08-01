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
const CHUNK_CELLS := 16
const CHUNK_BLEED := 10

var _chunk_textures: Dictionary = {}
var _dirty_chunks: Dictionary = {}
var _rebuild_queued := false


func _ready() -> void:
	Events.map_generated.connect(_queue_full_rebuild)
	Events.terrain_changed.connect(_queue_cell_rebuild)
	Events.blight_changed.connect(
		func(cell: int, _blighted: bool) -> void: _queue_cell_rebuild(cell))


func _queue_full_rebuild() -> void:
	if World.grid.cell_count <= 0:
		return
	var chunk_columns := ceili(float(World.grid.width) / CHUNK_CELLS)
	var chunk_rows := ceili(float(World.grid.height) / CHUNK_CELLS)
	for chunk_y in chunk_rows:
		for chunk_x in chunk_columns:
			_dirty_chunks[Vector2i(chunk_x, chunk_y)] = true
	_queue_rebuild()


func _queue_cell_rebuild(cell: int) -> void:
	if not World.grid.is_valid_index(cell):
		return
	var c := World.grid.coord(cell)
	_mark_chunk_for_cell(c)
	# A changed cell also changes the seam owned by its left and top neighbor.
	_mark_chunk_for_cell(c + Vector2i.LEFT)
	_mark_chunk_for_cell(c + Vector2i.UP)
	_queue_rebuild()


func _mark_chunk_for_cell(c: Vector2i) -> void:
	if not World.grid.is_valid_v(c):
		return
	_dirty_chunks[Vector2i(c.x / CHUNK_CELLS, c.y / CHUNK_CELLS)] = true


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_rebuild_dirty_chunks")


func _rebuild_dirty_chunks() -> void:
	_rebuild_queued = false
	if World.terrain.size() != World.grid.cell_count:
		return
	var chunks := _dirty_chunks.keys()
	_dirty_chunks.clear()
	for key in chunks:
		var chunk := Vector2i(key)
		var image := _build_chunk(chunk)
		var texture := _chunk_textures.get(chunk) as ImageTexture
		if texture == null:
			texture = ImageTexture.create_from_image(image)
			_chunk_textures[chunk] = texture
		else:
			texture.update(image)
	queue_redraw()


func _build_chunk(chunk: Vector2i) -> Image:
	var grid := World.grid
	var world_origin := chunk * CHUNK_CELLS * Grid.TILE_SIZE \
		- Vector2i(CHUNK_BLEED, CHUNK_BLEED)
	var image_size := CHUNK_CELLS * Grid.TILE_SIZE + CHUNK_BLEED * 2
	var image := Image.create(image_size, image_size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var start_x := chunk.x * CHUNK_CELLS
	var start_y := chunk.y * CHUNK_CELLS
	var end_x := mini(start_x + CHUNK_CELLS, grid.width)
	var end_y := mini(start_y + CHUNK_CELLS, grid.height)
	for y in range(start_y, end_y):
		for x in range(start_x, end_x):
			var cell := grid.index(x, y)
			if x + 1 < grid.width:
				_paint_vertical(
					image, world_origin, cell, grid.index(x + 1, y), x + 1, y
				)
			if y + 1 < grid.height:
				_paint_horizontal(
					image, world_origin, cell, grid.index(x, y + 1), x, y + 1
				)
	return image


func _draw() -> void:
	for key in _chunk_textures:
		var chunk := Vector2i(key)
		var world_position := chunk * CHUNK_CELLS * Grid.TILE_SIZE \
			- Vector2i(CHUNK_BLEED, CHUNK_BLEED)
		draw_texture(_chunk_textures[key] as Texture2D, Vector2(world_position))


func _paint_vertical(
	image: Image, origin: Vector2i,
	left: int, right: int, seam_x: int, tile_y: int
	) -> void:
	if not _needs_seam(left, right):
		return
	var source_left := _source_is_first(left, right)
	var source := left if source_left else right
	var base := _cell_base(source)
	var edge := _cell_edge(source)
	var x := seam_x * Grid.TILE_SIZE
	var y := tile_y * Grid.TILE_SIZE
	for offset in range(0, Grid.TILE_SIZE, SEGMENT):
		var depth := roundi(_seam_depth(
			seam_x, tile_y * Grid.TILE_SIZE + offset, source
		))
		var rect := Rect2i(
			x if source_left else x - depth,
			y + offset,
			depth,
			SEGMENT)
		_fill_rect(image, origin, rect, base)
		var rim_x := x + depth - 1 if source_left else x - depth
		_fill_rect(image, origin, Rect2i(rim_x, y + offset, 1, SEGMENT), edge)
		_paint_vertical_fleck(
			image, origin, x, y + offset, depth, source_left, source, base
		)


func _paint_horizontal(
	image: Image, origin: Vector2i,
	top: int, bottom: int, tile_x: int, seam_y: int
	) -> void:
	if not _needs_seam(top, bottom):
		return
	var source_top := _source_is_first(top, bottom)
	var source := top if source_top else bottom
	var base := _cell_base(source)
	var edge := _cell_edge(source)
	var x := tile_x * Grid.TILE_SIZE
	var y := seam_y * Grid.TILE_SIZE
	for offset in range(0, Grid.TILE_SIZE, SEGMENT):
		var depth := roundi(_seam_depth(
			tile_x * Grid.TILE_SIZE + offset, seam_y, source
		))
		var rect := Rect2i(
			x + offset,
			y if source_top else y - depth,
			SEGMENT,
			depth)
		_fill_rect(image, origin, rect, base)
		var rim_y := y + depth - 1 if source_top else y - depth
		_fill_rect(image, origin, Rect2i(x + offset, rim_y, SEGMENT, 1), edge)
		_paint_horizontal_fleck(
			image, origin, x + offset, y, depth, source_top, source, base
		)


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


func _paint_vertical_fleck(
	image: Image, origin: Vector2i,
	seam_x: int, y: int, depth: int, source_left: bool,
	source: int, color: Color) -> void:
	if _hash(seam_x, y, source) % 5 != 0:
		return
	var x := seam_x + depth + 1 if source_left else seam_x - depth - 2
	_fill_rect(
		image, origin,
		Rect2i(x, y + _hash(source, y, 31) % 2, 1, 1), color
	)


func _paint_horizontal_fleck(
	image: Image, origin: Vector2i,
	x: int, seam_y: int, depth: int, source_top: bool,
	source: int, color: Color) -> void:
	if _hash(x, seam_y, source) % 5 != 0:
		return
	var y := seam_y + depth + 1 if source_top else seam_y - depth - 2
	_fill_rect(
		image, origin,
		Rect2i(x + _hash(source, x, 47) % 2, y, 1, 1), color
	)


func _fill_rect(
	image: Image, origin: Vector2i, world_rect: Rect2i, color: Color
	) -> void:
	var local_rect := Rect2i(world_rect.position - origin, world_rect.size)
	var clipped := local_rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if clipped.has_area():
		image.fill_rect(clipped, color)


static func _hash(a: int, b: int, salt: int) -> int:
	var value := a * 92837111 ^ b * 689287499 ^ salt * 283923481
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))
