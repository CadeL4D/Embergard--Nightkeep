extends Node2D
## Sparse multi-tile surface contours for the solid interiors of forests and quarries.
##
## These cannot live in a 16 px atlas cell without becoming a repeated stamp. Instead,
## this view-only layer chooses deterministic points at least two resource cells from
## an edge and draws broad, irregular nested shapes spanning roughly three tiles.
## Nothing here enters World.feature, pathing or saves.

const FOREST_OUTER := Color("102217")
const FOREST_MIDDLE := Color("32643b")
const FOREST_SPECK := Color("4e8150")

const ROCK_OUTER := Color("241f1a")
const ROCK_MIDDLE := Color("796b57")
const ROCK_INNER := Color("8c7a62")
const ROCK_LINE := Color("17130f")

var _details: Array[Dictionary] = []
var _rebuild_queued := false


func _ready() -> void:
	Events.map_generated.connect(_queue_rebuild)
	Events.terrain_changed.connect(_on_terrain_changed)


func _on_terrain_changed(_cell: int) -> void:
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_rebuild")


func _rebuild() -> void:
	_rebuild_queued = false
	_details.clear()
	var grid: Grid = World.grid
	if World.feature.size() != grid.cell_count:
		queue_redraw()
		return

	var chosen: Array[Vector2] = []
	for cell in grid.cell_count:
		var feature := int(World.feature[cell])
		if feature != Terrain.Feature.TREE and feature != Terrain.Feature.STONE:
			continue
		var c := grid.coord(cell)
		var seed := _mix(c.x, c.y, feature)
		# Check the cheap density gate before the 5x5 solid-interior test.
		var density_divisor := 11 if feature == Terrain.Feature.TREE else 5
		if (seed >> 9) % density_divisor != 0:
			continue
		var solid_radius := 2 if feature == Terrain.Feature.TREE else 1
		if not _is_solid_interior(c, feature, solid_radius, grid):
			continue
		var center := grid.to_world(c)
		var clear := true
		var spacing := 58.0 if feature == Terrain.Feature.TREE else 46.0
		for other in chosen:
			if center.distance_squared_to(other) < spacing * spacing:
				clear = false
				break
		if not clear:
			continue
		chosen.append(center)
		_details.append({"feature": feature, "center": center, "seed": seed})

	queue_redraw()


func _is_solid_interior(c: Vector2i, feature: int, radius: int, grid: Grid) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var n := c + Vector2i(dx, dy)
			if not grid.is_valid_v(n) or int(World.feature[grid.index_v(n)]) != feature:
				return false
	return true


func _draw() -> void:
	for detail in _details:
		var feature := int(detail["feature"])
		var center: Vector2 = detail["center"]
		var seed := int(detail["seed"])
		var outer := _blob_points(center, seed, feature, 1.0)
		var middle_scale := 0.92 if feature == Terrain.Feature.TREE else 0.82
		var middle := _scaled_points(outer, center, middle_scale)
		if feature == Terrain.Feature.TREE:
			draw_colored_polygon(outer, FOREST_OUTER)
			draw_colored_polygon(middle, FOREST_MIDDLE)
			draw_polyline(_closed(outer), FOREST_OUTER, 1.0, false)
			draw_polyline(_closed(middle), FOREST_OUTER, 1.0, false)
			_draw_forest_speckles(center, seed)
		else:
			var inner := _scaled_points(outer, center + Vector2(-1, -1), 0.62)
			draw_colored_polygon(outer, ROCK_OUTER)
			draw_colored_polygon(middle, ROCK_MIDDLE)
			draw_colored_polygon(inner, ROCK_INNER)
			draw_polyline(_closed(outer), ROCK_LINE, 1.0, false)
			draw_polyline(_closed(middle), ROCK_OUTER, 1.0, false)


func _draw_forest_speckles(center: Vector2, seed: int) -> void:
	for i in 7:
		var h := _mix(i, seed & 0xffff, Terrain.Feature.TREE + 47)
		var dx := float((h >> 8) % 17 - 8)
		var dy := float((h >> 17) % 11 - 5)
		draw_rect(
			Rect2(Vector2(roundf(center.x + dx), roundf(center.y + dy)), Vector2.ONE),
			FOREST_SPECK
		)


func _blob_points(center: Vector2, seed: int, feature: int, scale: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var radius_x := 18.0 if feature == Terrain.Feature.STONE else 26.0
	var radius_y := 13.0 if feature == Terrain.Feature.STONE else 19.0
	var point_count := 14 if feature == Terrain.Feature.STONE else 16
	for i in point_count:
		var angle := TAU * float(i) / float(point_count)
		var wobble_hash := _mix(i, seed & 0xffff, feature + 19)
		var wobble_range := 7 if feature == Terrain.Feature.STONE else 13
		var wobble := float((wobble_hash >> 10) % wobble_range - wobble_range / 2)
		var px := center.x + cos(angle) * (radius_x + wobble) * scale
		var py := center.y + sin(angle) * (radius_y + wobble * 0.65) * scale
		points.append(Vector2(roundf(px), roundf(py)))
	return points


func _scaled_points(
		points: PackedVector2Array, center: Vector2, scale: float
	) -> PackedVector2Array:
	var scaled := PackedVector2Array()
	for point in points:
		scaled.append(Vector2(
			roundf(center.x + (point.x - center.x) * scale),
			roundf(center.y + (point.y - center.y) * scale)
		))
	return scaled


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var closed := points.duplicate()
	if not points.is_empty():
		closed.append(points[0])
	return closed


func _mix(x: int, y: int, salt: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ salt * 83492791
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return absi(h)
