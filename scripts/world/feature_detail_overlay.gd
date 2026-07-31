extends Node2D
## Cohesive resource art for forests, quarries, and berry thickets.
##
## A connected feature is still made from 16 px simulation cells, but exposing that
## staircase makes every grove and quarry look boxy. This view-only layer traces the
## outline of each entire connected region, rounds that path, and draws the perimeter
## as one continuous contour. Tree and berry cells receive overlapping, harvest-readable
## crowns, while quarries receive broad raised shelves tied to the shared rock body.
## Nothing here enters World.feature, pathing or saves.

const FOREST_EDGE_BASE := Color("1b3823")
const FOREST_EDGE_DARK := Color("101d16")
const FOREST_OUTER := Color("102217")
const FOREST_DEEP := Color("173a20")
const FOREST_BASE := Color("23572c")
const FOREST_MIDDLE := Color("32643b")
const FOREST_SPECK := Color("4e8150")
const TREE_TRUNK_DARK := Color("2a1d17")
const TREE_TRUNK := Color("60402b")

const ROCK_SHADOW := Color("17130f")
const ROCK_OUTER := Color("241f1a")
const ROCK_LEDGE_SHADOW := Color("4b4035")
const ROCK_EDGE_BASE := Color("665847")
const ROCK_MIDDLE := Color("796b57")
const ROCK_INNER := Color("8c7a62")
const ROCK_HIGHLIGHT := Color("aa9577")
const ROCK_LINE := Color("17130f")

const BUSH_OUTER := Color("102018")
const BUSH_DEEP := Color("193822")
const BUSH_BASE := Color("2a5730")
const BUSH_LIGHT := Color("477642")
const BERRY_RED_DEEP := Color("943743")
const BERRY_RED := Color("d65b61")
const BERRY_VIOLET_DEEP := Color("70428f")
const BERRY_VIOLET := Color("b66bd2")
const BERRY_AMBER_DEEP := Color("9f6829")
const BERRY_AMBER := Color("dfa64b")
const BERRY_BLUE_DEEP := Color("3f6699")
const BERRY_BLUE := Color("6e9bd5")
const BERRY_GLINT := Color("f2d7af")

const NODE_SPRITE_SIZE := 32
const NODE_ATLAS_COLS := 8
const TREE_VARIANTS := 8
const BERRY_VARIANTS := 4

var _boundaries: Array[Dictionary] = []
var _boundary_lines: Array[Line2D] = []
var _details: Array[Dictionary] = []
var _tree_nodes: Array[Dictionary] = []
var _berry_nodes: Array[Dictionary] = []
var _node_atlas: ImageTexture
var _rebuild_queued := false


func _ready() -> void:
	_node_atlas = _build_node_atlas()
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
	_tree_nodes.clear()
	_berry_nodes.clear()
	var grid: Grid = World.grid
	if World.feature.size() != grid.cell_count:
		_sync_boundary_lines()
		queue_redraw()
		return

	_build_boundaries(grid)
	_sync_boundary_lines()
	_build_stone_details(grid)
	for cell in grid.cell_count:
		var feature := int(World.feature[cell])
		var c := grid.coord(cell)
		var seed := _mix(c.x, c.y, feature * 97 + World.seed_value)
		if feature == Terrain.Feature.TREE:
			var tree_center := grid.to_world(c) + Vector2(
				float((seed >> 4) % 7 - 3),
				float((seed >> 9) % 7 - 3)
			)
			_tree_nodes.append({
				"center": tree_center, "seed": seed, "coord": c,
			})
			continue
		if feature == Terrain.Feature.BERRIES:
			var berry_center := grid.to_world(c) + Vector2(
				float((seed >> 5) % 7 - 3),
				float((seed >> 10) % 7 - 3)
			)
			_berry_nodes.append({
				"center": berry_center, "seed": seed, "coord": c,
			})

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


## Every connected quarry receives a raised top, including the compact guaranteed
## starting deposit. Larger regions gain more shelves only when they can be kept
## far enough apart to remain features of one landform rather than stone nodes.
func _build_stone_details(grid: Grid) -> void:
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for start in grid.cell_count:
		if visited[start] != 0 \
			or int(World.feature[start]) != Terrain.Feature.STONE:
			continue
		var region := _collect_region(
			start, Terrain.Feature.STONE, grid, visited
		)
		if region.is_empty():
			continue

		var interior := PackedInt32Array()
		var primary := region[0]
		var centroid := Vector2.ZERO
		for cell in region:
			centroid += Vector2(grid.coord(cell))
		centroid /= float(region.size())
		var primary_distance := INF
		for cell in region:
			var c := grid.coord(cell)
			var distance := Vector2(c).distance_squared_to(centroid)
			if distance < primary_distance:
				primary_distance = distance
				primary = cell
			if _is_solid_interior(c, Terrain.Feature.STONE, 1, grid):
				interior.append(cell)
		if not interior.is_empty():
			primary = interior[0]
			primary_distance = INF
			for cell in interior:
				var c := grid.coord(cell)
				var distance := Vector2(c).distance_squared_to(centroid)
				if distance < primary_distance:
					primary_distance = distance
					primary = cell

		var chosen: Array[Vector2] = []
		var shelf_scale := clampf(
			sqrt(float(region.size()) / 38.0), 0.68, 1.15
		)
		_add_stone_detail(primary, grid, chosen, shelf_scale)
		if region.size() < 38:
			continue
		for cell in interior:
			if cell == primary:
				continue
			var c := grid.coord(cell)
			var seed := _mix(
				c.x, c.y, World.seed_value + Terrain.Feature.STONE * 97
			)
			if seed % 3 != 0:
				continue
			_add_stone_detail(cell, grid, chosen, shelf_scale)


func _add_stone_detail(
		cell: int, grid: Grid, chosen: Array[Vector2], shelf_scale: float
	) -> void:
	var c := grid.coord(cell)
	var center := grid.to_world(c)
	for other in chosen:
		if center.distance_squared_to(other) < 68.0 * 68.0:
			return
	chosen.append(center)
	var seed := _mix(
		c.x, c.y, World.seed_value + Terrain.Feature.STONE * 97
	)
	_details.append({
		"feature": Terrain.Feature.STONE, "center": center, "seed": seed,
		"scale": shelf_scale,
	})


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
			_add_boundary_line(closed, FOREST_EDGE_DARK, 6.0)
			_add_boundary_line(closed, FOREST_OUTER, 3.5)
			_add_boundary_line(closed, FOREST_EDGE_BASE, 1.5)
		else:
			_add_boundary_line(closed, ROCK_SHADOW, 9.0)
			_add_boundary_line(closed, ROCK_OUTER, 6.0)
			_add_boundary_line(closed, ROCK_EDGE_BASE, 2.5)
			_add_boundary_line(closed, ROCK_HIGHLIGHT, 1.0)


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
	for node in _tree_nodes:
		_draw_tree_node(node)

	for detail in _details:
		var center: Vector2 = detail["center"]
		var seed := int(detail["seed"])
		_draw_rock_shelf(center, seed, float(detail.get("scale", 1.0)))

	for node in _berry_nodes:
		_draw_berry_node(node)


func _draw_tree_node(node: Dictionary) -> void:
	var center: Vector2 = node["center"]
	var seed := int(node["seed"])
	var variant := seed % TREE_VARIANTS
	var source := Rect2(
		Vector2(variant * NODE_SPRITE_SIZE, 0),
		Vector2(NODE_SPRITE_SIZE, NODE_SPRITE_SIZE)
	)
	var destination := Rect2(
		_pixel(center) - Vector2(NODE_SPRITE_SIZE / 2, NODE_SPRITE_SIZE / 2),
		Vector2(NODE_SPRITE_SIZE, NODE_SPRITE_SIZE)
	)
	draw_texture_rect_region(_node_atlas, destination, source)


func _draw_rock_shelf(center: Vector2, seed: int, scale: float) -> void:
	var outer := _organic_blob(
		center, seed, 25.0 * scale, 17.0 * scale,
		16, 3.2 * scale
	)
	var shadow := _offset_points(outer, Vector2(1, 2))
	var middle := _scaled_points(outer, center, 0.90)
	var inner := _scaled_points(outer, center + Vector2(-1, -2), 0.68)
	draw_colored_polygon(shadow, ROCK_LEDGE_SHADOW)
	draw_colored_polygon(outer, ROCK_EDGE_BASE)
	draw_colored_polygon(middle, ROCK_MIDDLE)
	draw_colored_polygon(inner, ROCK_INNER)
	draw_polyline(_closed(outer), ROCK_OUTER, 1.25, false)
	draw_polyline(_closed(middle), ROCK_EDGE_BASE, 1.0, false)
	draw_polyline(_upper_arc(inner), ROCK_HIGHLIGHT, 1.25, false)


func _draw_berry_node(node: Dictionary) -> void:
	var center: Vector2 = node["center"]
	var seed := int(node["seed"])
	var c: Vector2i = node["coord"]
	var group_x := floori(float(c.x) / 3.0)
	var group_y := floori(float(c.y) / 2.0)
	var color_index := _mix(group_x, group_y, World.seed_value + 809) \
		% 4
	var variant := seed % BERRY_VARIANTS
	var source := Rect2(
		Vector2(
			variant * NODE_SPRITE_SIZE,
			(1 + color_index) * NODE_SPRITE_SIZE
		),
		Vector2(NODE_SPRITE_SIZE, NODE_SPRITE_SIZE)
	)
	var destination := Rect2(
		_pixel(center) - Vector2(NODE_SPRITE_SIZE / 2, NODE_SPRITE_SIZE / 2),
		Vector2(NODE_SPRITE_SIZE, NODE_SPRITE_SIZE)
	)
	draw_texture_rect_region(_node_atlas, destination, source)


func _build_node_atlas() -> ImageTexture:
	var rows := 5
	var image := Image.create(
		NODE_ATLAS_COLS * NODE_SPRITE_SIZE,
		rows * NODE_SPRITE_SIZE,
		false,
		Image.FORMAT_RGBA8
	)
	image.fill(Color(0, 0, 0, 0))
	for variant in TREE_VARIANTS:
		_paint_tree_sprite(image, Vector2i(variant * NODE_SPRITE_SIZE, 0), variant)
	for family in 4:
		for variant in BERRY_VARIANTS:
			_paint_berry_sprite(
				image,
				Vector2i(
					variant * NODE_SPRITE_SIZE,
					(1 + family) * NODE_SPRITE_SIZE
				),
				variant,
				family
			)
	return ImageTexture.create_from_image(image)


func _paint_tree_sprite(image: Image, origin: Vector2i, variant: int) -> void:
	var center := Vector2i(16, 16)
	var seed := _mix(variant, 401, 1709)
	var rx := 9
	var ry := 8
	match variant % 4:
		0:
			rx = 11
			ry = 8
		1:
			rx = 8
			ry = 10
		2:
			rx = 10
			ry = 9
	if variant == TREE_VARIANTS - 1:
		rx = 7
		ry = 7

	_paint_sprite_rect(image, origin, center + Vector2i(-1, 3), Vector2i(3, 7), TREE_TRUNK_DARK)
	_paint_sprite_rect(image, origin, center + Vector2i(0, 4), Vector2i(1, 6), TREE_TRUNK)
	_paint_sprite_blob(image, origin, center + Vector2i(2, 3), rx + 1, ry + 1, seed + 5, FOREST_OUTER)
	_paint_sprite_blob(image, origin, center, rx, ry, seed + 17, FOREST_DEEP)
	_paint_sprite_blob(
		image, origin, center + Vector2i(-1, -1),
		maxi(4, rx - 1), maxi(4, ry - 1), seed + 29, FOREST_BASE
	)
	_paint_sprite_blob(
		image, origin, center + Vector2i(-3, -3),
		maxi(2, roundi(rx * 0.42)), maxi(2, roundi(ry * 0.38)),
		seed + 43, FOREST_MIDDLE
	)
	if variant % 3 == 0:
		_paint_sprite_blob(
			image, origin, center + Vector2i(-4, -4),
			2 + variant % 2, 2, seed + 61, FOREST_SPECK
		)


func _paint_berry_sprite(
		image: Image, origin: Vector2i, variant: int, family: int
	) -> void:
	var fruit_deep_colors: Array[Color] = [
		BERRY_RED_DEEP, BERRY_VIOLET_DEEP, BERRY_AMBER_DEEP, BERRY_BLUE_DEEP,
	]
	var fruit_light_colors: Array[Color] = [
		BERRY_RED, BERRY_VIOLET, BERRY_AMBER, BERRY_BLUE,
	]
	var center := Vector2i(16, 16)
	var seed := _mix(variant, family, 2609)
	var rx := 8 + variant % 3
	var ry := 6 + (variant + 1) % 3
	_paint_sprite_blob(
		image, origin, center + Vector2i(1, 2),
		rx + 1, ry + 1, seed + 7, BUSH_OUTER
	)
	_paint_sprite_blob(image, origin, center, rx, ry, seed + 19, BUSH_DEEP)
	_paint_sprite_blob(
		image, origin, center + Vector2i(-1, -1),
		maxi(4, rx - 2), maxi(3, ry - 2), seed + 31, BUSH_BASE
	)
	_paint_sprite_blob(
		image, origin, center + Vector2i(-3, -2),
		maxi(2, roundi(rx * 0.40)), maxi(2, roundi(ry * 0.35)),
		seed + 43, BUSH_LIGHT
	)

	var fruit_count := 4 + variant % 3
	for fruit in fruit_count:
		var fruit_hash := _mix(variant * 13 + fruit, family * 17 - fruit, 733)
		var fx := center.x + int((fruit_hash >> 5) % maxi(3, rx * 2 - 4)) - rx + 2
		var fy := center.y + int((fruit_hash >> 11) % maxi(3, ry * 2 - 4)) - ry + 2
		_paint_sprite_rect(
			image, origin, Vector2i(fx, fy), Vector2i(2, 2),
			fruit_deep_colors[family]
		)
		_set_sprite_pixel(image, origin, Vector2i(fx, fy), fruit_light_colors[family])
		if fruit_hash % 4 == 0:
			_set_sprite_pixel(
				image, origin, Vector2i(fx, fy - 1), BERRY_GLINT
			)


func _paint_sprite_blob(
		image: Image, origin: Vector2i, center: Vector2i,
		rx: int, ry: int, seed: int, color: Color
	) -> void:
	var phase := float(seed % 628) / 100.0
	for y in range(maxi(0, center.y - ry - 2), mini(NODE_SPRITE_SIZE, center.y + ry + 3)):
		for x in range(maxi(0, center.x - rx - 2), mini(NODE_SPRITE_SIZE, center.x + rx + 3)):
			var nx := float(x - center.x) / float(maxi(1, rx))
			var ny := float(y - center.y) / float(maxi(1, ry))
			var angle := atan2(ny, nx)
			var radius := sqrt(nx * nx + ny * ny)
			var edge := 1.0 \
				+ sin(angle * 3.0 + phase) * 0.10 \
				+ sin(angle * 5.0 - phase * 0.7) * 0.07 \
				+ sin(angle * 8.0 + phase * 1.1) * 0.035
			if radius <= edge:
				image.set_pixel(origin.x + x, origin.y + y, color)


func _paint_sprite_rect(
		image: Image, origin: Vector2i, top_left: Vector2i,
		size: Vector2i, color: Color
	) -> void:
	for y in range(maxi(0, top_left.y), mini(NODE_SPRITE_SIZE, top_left.y + size.y)):
		for x in range(maxi(0, top_left.x), mini(NODE_SPRITE_SIZE, top_left.x + size.x)):
			image.set_pixel(origin.x + x, origin.y + y, color)


func _set_sprite_pixel(
		image: Image, origin: Vector2i, point: Vector2i, color: Color
	) -> void:
	if point.x >= 0 and point.y >= 0 \
			and point.x < NODE_SPRITE_SIZE and point.y < NODE_SPRITE_SIZE:
		image.set_pixel(origin.x + point.x, origin.y + point.y, color)


func _organic_blob(
		center: Vector2, seed: int, radius_x: float, radius_y: float,
		point_count: int, wobble: float
	) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in point_count:
		var angle := TAU * float(i) / float(point_count)
		var wobble_hash := _mix(i, seed & 0xffff, point_count + 19)
		var variation := float((wobble_hash >> 10) % 1024) / 1023.0
		var offset := (variation * 2.0 - 1.0) * wobble
		var px := center.x + cos(angle) * (radius_x + offset)
		var py := center.y + sin(angle) * (radius_y + offset * 0.65)
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


func _offset_points(points: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var shifted := PackedVector2Array()
	for point in points:
		shifted.append(point + offset)
	return shifted


func _upper_arc(points: PackedVector2Array) -> PackedVector2Array:
	var arc := PackedVector2Array()
	if points.is_empty():
		return arc
	var halfway := points.size() / 2
	for i in range(halfway, points.size()):
		arc.append(points[i])
	arc.append(points[0])
	return arc


func _pixel(point: Vector2) -> Vector2:
	return Vector2(roundf(point.x), roundf(point.y))


func _mix(x: int, y: int, salt: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ salt * 83492791
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return absi(h)
