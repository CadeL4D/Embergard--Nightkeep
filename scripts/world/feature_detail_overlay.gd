extends Node2D
## Region-wide boundaries and sparse surface contours for forests and quarries.
##
## A connected feature is still made from 16 px simulation cells, but exposing that
## staircase makes every grove and quarry look boxy. This view-only layer traces the
## outline of each entire connected region, rounds that path, and draws the perimeter
## as one continuous contour. It also chooses deterministic solid-interior points for
## broad, irregular surface shapes that cannot fit in one atlas cell without repeating.
## Nothing here enters World.feature, pathing or saves.

const FOREST_EDGE_BASE := Color("1b3823")
const FOREST_EDGE_DARK := Color("090d13")
const FOREST_OUTER := Color("102217")
const FOREST_MIDDLE := Color("32643b")
const FOREST_SPECK := Color("4e8150")

const ROCK_OUTER := Color("241f1a")
const ROCK_EDGE_BASE := Color("665847")
const ROCK_MIDDLE := Color("796b57")
const ROCK_INNER := Color("8c7a62")
const ROCK_LINE := Color("17130f")

var _boundaries: Array[Dictionary] = []
var _boundary_lines: Array[Line2D] = []
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
	_boundaries.clear()
	_details.clear()
	var grid: Grid = World.grid
	if World.feature.size() != grid.cell_count:
		_sync_boundary_lines()
		queue_redraw()
		return

	_build_boundaries(grid)
	_sync_boundary_lines()
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


func _build_boundaries(grid: Grid) -> void:
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for cell in grid.cell_count:
		if visited[cell] != 0:
			continue
		var feature := int(World.feature[cell])
		if feature != Terrain.Feature.TREE and feature != Terrain.Feature.STONE:
			continue
		var region := _collect_region(cell, feature, grid, visited)
		var edges: Dictionary = {}
		for region_cell in region:
			var c := grid.coord(region_cell)
			# Edges run with the resource on their right. That orientation keeps
			# outer rims and clearing/hole rims as independent closed loops.
			if not _is_feature(c + Vector2i.UP, feature, grid):
				_add_edge(edges, c, c + Vector2i.RIGHT)
			if not _is_feature(c + Vector2i.RIGHT, feature, grid):
				_add_edge(edges, c + Vector2i.RIGHT, c + Vector2i(1, 1))
			if not _is_feature(c + Vector2i.DOWN, feature, grid):
				_add_edge(edges, c + Vector2i(1, 1), c + Vector2i.DOWN)
			if not _is_feature(c + Vector2i.LEFT, feature, grid):
				_add_edge(edges, c + Vector2i.DOWN, c)
		_trace_loops(edges, feature)


func _sync_boundary_lines() -> void:
	for line in _boundary_lines:
		if is_instance_valid(line):
			line.free()
	_boundary_lines.clear()

	for boundary in _boundaries:
		var feature := int(boundary["feature"])
		var points: PackedVector2Array = boundary["points"]
		var closed := _closed(points)
		if feature == Terrain.Feature.TREE:
			_add_boundary_line(closed, FOREST_EDGE_DARK, 7.0)
			_add_boundary_line(closed, FOREST_OUTER, 4.0)
			_add_boundary_line(closed, FOREST_EDGE_BASE, 1.5)
		else:
			_add_boundary_line(closed, ROCK_LINE, 7.0)
			_add_boundary_line(closed, ROCK_OUTER, 4.0)
			_add_boundary_line(closed, ROCK_EDGE_BASE, 1.5)


func _add_boundary_line(points: PackedVector2Array, color: Color, width: float) -> void:
	var line := Line2D.new()
	line.points = points
	line.width = width
	line.default_color = color
	line.antialiased = false
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.round_precision = 4
	line.show_behind_parent = true
	add_child(line)
	_boundary_lines.append(line)


func _collect_region(
	start: int, feature: int, grid: Grid, visited: PackedByteArray
	) -> PackedInt32Array:
	var region := PackedInt32Array()
	var queue := PackedInt32Array([start])
	visited[start] = 1
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		region.append(cell)
		for neighbor in grid.neighbours_4(cell):
			if visited[neighbor] == 0 and int(World.feature[neighbor]) == feature:
				visited[neighbor] = 1
				queue.append(neighbor)
	return region


func _is_feature(c: Vector2i, feature: int, grid: Grid) -> bool:
	return grid.is_valid_v(c) and int(World.feature[grid.index_v(c)]) == feature


func _add_edge(edges: Dictionary, start: Vector2i, finish: Vector2i) -> void:
	var outgoing: Array[Vector2i] = []
	if edges.has(start):
		outgoing = edges[start]
	outgoing.append(finish)
	edges[start] = outgoing


func _trace_loops(edges: Dictionary, feature: int) -> void:
	while not edges.is_empty():
		var starts: Array = edges.keys()
		var start := Vector2i(starts[0])
		var current := start
		var incoming := Vector2i.ZERO
		var raw: Array[Vector2i] = [start]
		var guard := 0
		while guard < 100000:
			guard += 1
			var next := _take_next_edge(edges, current, incoming)
			if next == Vector2i(-2147483648, -2147483648):
				break
			incoming = next - current
			current = next
			if current == start:
				break
			raw.append(current)
		if raw.size() < 3:
			continue
		var simplified := _simplify_loop(raw)
		if simplified.size() < 3:
			continue
		var natural := _naturalize_loop(simplified, feature)
		# Two subdivisions turn the remaining right-angle changes into broad
		# canopy/rock lobes. Each loop is its own CanvasItem, so off-screen
		# geometry is still culled as a unit.
		var rounded := _chaikin_closed(natural, 2)
		_boundaries.append({"feature": feature, "points": rounded})


func _take_next_edge(
	edges: Dictionary, start: Vector2i, incoming: Vector2i
	) -> Vector2i:
	var missing := Vector2i(-2147483648, -2147483648)
	if not edges.has(start):
		return missing
	var outgoing: Array[Vector2i] = edges[start]
	var chosen := 0
	var best_score := -1
	for i in outgoing.size():
		var direction := outgoing[i] - start
		var score := _turn_score(incoming, direction)
		if score > best_score:
			best_score = score
			chosen = i
	var finish := outgoing[chosen]
	outgoing.remove_at(chosen)
	if outgoing.is_empty():
		edges.erase(start)
	else:
		edges[start] = outgoing
	return finish


func _turn_score(incoming: Vector2i, outgoing: Vector2i) -> int:
	if incoming == Vector2i.ZERO:
		return 0
	var right := Vector2i(-incoming.y, incoming.x)
	if outgoing == right:
		return 3
	if outgoing == incoming:
		return 2
	if outgoing == -right:
		return 1
	return 0


func _simplify_loop(raw: Array[Vector2i]) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := raw.size()
	for i in count:
		var before := raw[(i - 1 + count) % count]
		var current := raw[i]
		var after := raw[(i + 1) % count]
		var first := current - before
		var second := after - current
		if first.x * second.y - first.y * second.x == 0:
			continue
		points.append(Vector2(current * Grid.TILE_SIZE))
	return points


func _naturalize_loop(points: PackedVector2Array, feature: int) -> PackedVector2Array:
	var natural := PackedVector2Array()
	var spacing := 18.0 if feature == Terrain.Feature.TREE else 22.0
	var amplitude := 3.0 if feature == Terrain.Feature.TREE else 2.5
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		var delta := b - a
		var length := delta.length()
		if length <= 0.01:
			continue
		var steps := maxi(1, ceili(length / spacing))
		var outside := Vector2(delta.y, -delta.x).normalized()
		for step in steps:
			var t := float(step) / float(steps)
			var point := a.lerp(b, t)
			var h := _mix(roundi(point.x), roundi(point.y), feature * 97 + i * 7 + step)
			# Broad signed changes keep long edges organic without restarting one
			# scallop in every tile. The line is wide enough to bridge these small
			# offsets back to the coarse transparent atlas silhouette.
			var variation := float((h >> 8) % 1024) / 1023.0
			var offset := amplitude * (variation * 2.0 - 1.0)
			natural.append(point + outside * offset)
	return natural


func _chaikin_closed(points: PackedVector2Array, iterations: int) -> PackedVector2Array:
	var rounded := points
	for _iteration in iterations:
		var next := PackedVector2Array()
		for i in rounded.size():
			var a := rounded[i]
			var b := rounded[(i + 1) % rounded.size()]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		rounded = next
	return rounded


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
