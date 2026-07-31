extends Node2D
## Connected, irregular visual surface for finished paths and roads.
##
## Buildings still own costs, placement, saves, and movement bonuses. Their square
## sprites are hidden once complete and this view draws the same World.path_tier
## cells as a continuous low strip.

const PATH_BASE := Color("715a3c")
const PATH_EDGE := Color("3b2c1f")
const PATH_LIGHT := Color("92764e")
const ROAD_BASE := Color("59636d")
const ROAD_EDGE := Color("303841")
const ROAD_LIGHT := Color("7d8994")
const DIRECTIONS: Array[Vector2i] = [
	Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT,
]


func _ready() -> void:
	Events.map_generated.connect(queue_redraw)
	Events.building_completed.connect(func(_building: Node) -> void: queue_redraw())
	Events.building_destroyed.connect(func(_building: Node) -> void: queue_redraw())
	Events.building_demolishing.connect(func(_building: Node) -> void: queue_redraw())


func _draw() -> void:
	if World.path_tier.size() != World.grid.cell_count:
		return
	# Draw every shadow before any surface. Interleaving them cell by cell leaves a
	# dark divider at each join and makes one continuous path look like paving slabs.
	for cell in World.grid.cell_count:
		var tier := int(World.path_tier[cell])
		if tier > 0:
			_draw_path_cell(cell, tier, true)
	for cell in World.grid.cell_count:
		var tier := int(World.path_tier[cell])
		if tier > 0:
			_draw_path_cell(cell, tier, false)


func _draw_path_cell(cell: int, tier: int, shadow_only: bool) -> void:
	var grid := World.grid
	var c := grid.coord(cell)
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * float(Grid.TILE_SIZE)
	var base := ROAD_BASE if tier >= 2 else PATH_BASE
	var edge := ROAD_EDGE if tier >= 2 else PATH_EDGE
	var light := ROAD_LIGHT if tier >= 2 else PATH_LIGHT
	var seed := _hash(c.x, c.y, World.seed_value + tier * 101)
	var half_x := float(5 + (seed >> 3) % 2)
	var half_y := float(5 + (seed >> 6) % 2)

	# Connect first; the central blob then hides every internal join.
	for direction in DIRECTIONS:
		var next := c + direction
		if not grid.is_valid_v(next) or World.path_tier[grid.index_v(next)] <= 0:
			continue
		var width := float(8 + _hash(next.x, next.y, seed) % 3)
		var connector := Rect2()
		if direction.x != 0:
			var left := center.x if direction.x > 0 else center.x - Grid.TILE_SIZE
			connector = Rect2(left, center.y - width * 0.5, Grid.TILE_SIZE, width)
		else:
			var top := center.y if direction.y > 0 else center.y - Grid.TILE_SIZE
			connector = Rect2(center.x - width * 0.5, top, width, Grid.TILE_SIZE)
		if shadow_only:
			draw_rect(connector.grow(1.0), edge, true)
		else:
			draw_rect(connector, base, true)

	var blob := PackedVector2Array([
		center + Vector2(-half_x + float(seed % 3), -half_y),
		center + Vector2(half_x - 2.0, -half_y + float((seed >> 2) % 3)),
		center + Vector2(half_x, -1.0),
		center + Vector2(half_x - float((seed >> 5) % 3), half_y),
		center + Vector2(-half_x + 1.0, half_y - float((seed >> 8) % 3)),
		center + Vector2(-half_x, 1.0),
	])
	if shadow_only:
		draw_colored_polygon(_offset(blob, Vector2(0, 1)), edge)
		return
	draw_colored_polygon(blob, base)

	# Sparse, stable marks give a run material without turning it into a tiled icon.
	if tier >= 2:
		var chip_x := center.x - 3.0 + float(seed % 7)
		var chip_y := center.y - 2.0 + float((seed >> 4) % 5)
		draw_rect(Rect2(chip_x, chip_y, 3, 1), light, true)
	else:
		var grain_x := center.x - 4.0 + float(seed % 9)
		var grain_y := center.y - 3.0 + float((seed >> 4) % 7)
		draw_rect(Rect2(grain_x, grain_y, 2, 1), light, true)


static func _offset(points: PackedVector2Array, amount: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for point in points:
		out.append(point + amount)
	return out


static func _hash(a: int, b: int, salt: int) -> int:
	var value := a * 92837111 ^ b * 689287499 ^ salt * 283923481
	value = (value ^ (value >> 13)) * 1274126177
	return absi(value ^ (value >> 16))
