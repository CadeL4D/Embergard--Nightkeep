extends Node2D
## Cohesive resource art for forests, quarries, and berry thickets.
##
## A connected feature is still made from 16 px simulation cells, but exposing that
## staircase makes every grove and quarry look boxy. This view-only layer traces the
## outline of each entire connected region, rounds that path, and draws the perimeter
## as one continuous contour. Tree and berry cells receive overlapping, harvest-readable
## crowns, while quarries receive broad raised shelves tied to the shared rock body.
## Nothing here enters World.feature, pathing or saves.

## The isolated lab's foliage ramp. Keeping this here as the source of truth
## prevents the runtime crowns from drifting darker than the approved prototype.
const FOREST_EDGE_BASE := Color("2e4425")
const FOREST_EDGE_DARK := Color("0b130d")
const FOREST_OUTER := Color("132719")
const FOREST_DEEP := Color("1a361d")
const FOREST_BASE := Color("245323")
const FOREST_MIDDLE := Color("2f662a")
const FOREST_SPECK := Color("3d7931")
const TREE_TRUNK_DARK := Color("2a1d17")
const TREE_TRUNK := Color("60402b")

## Ported directly from the approved isolated art lab.
const ROCK_SHADOW := Color("1d1814")
const ROCK_OUTER := Color("3b332a")
const ROCK_LEDGE_SHADOW := Color("574b3e")
const ROCK_EDGE_BASE := Color("706251")
const ROCK_MIDDLE := Color("81715c")
const ROCK_INNER := Color("9a866b")
const ROCK_HIGHLIGHT := Color("b09a7b")

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
const STONE_SHELF_SPACING := 34.0
# The mobile renderer is faster with one 5k-instance batch than with dozens of
# smaller CanvasItems. Keep the code chunk-capable for larger future maps, while
# the launch-size 112x112 colony deliberately resolves to one batch.
const RESOURCE_CHUNK_CELLS := 112
const FEATURE_ATLAS_SHADER := preload(
	"res://assets/shaders/feature_atlas_multimesh.gdshader"
)

var _boundaries: Array[Dictionary] = []
var _boundary_lines: Array[Line2D] = []
var _details: Array[Dictionary] = []
var _rock_overlays: Array[Dictionary] = []
var _stone_membership := PackedByteArray()
var _tree_nodes: Array[Dictionary] = []
var _berry_nodes: Array[Dictionary] = []
var _node_atlas: ImageTexture
var _boundary_texture: ImageTexture
var _resource_material: ShaderMaterial
var _resource_multimeshes: Dictionary = {}
var _rebuild_queued := false
var _stone_rebuild_needed := true
var _draw_boundaries := true
var _draw_resource_nodes := true
var _draw_rocks := true


func _ready() -> void:
	_node_atlas = _build_node_atlas()
	_boundary_texture = _build_boundary_texture()
	_resource_material = ShaderMaterial.new()
	_resource_material.shader = FEATURE_ATLAS_SHADER
	Events.map_generated.connect(_queue_full_rebuild)
	Events.terrain_changed.connect(_on_terrain_changed)


func _queue_full_rebuild() -> void:
	_stone_rebuild_needed = true
	_queue_rebuild()


func _on_terrain_changed(cell: int) -> void:
	# Felling a tree or picking berries must not repaint every pixel of every
	# quarry. Remembering the previous stone membership lets the expensive rock
	# image remain cached until a stone cell itself is actually mined.
	if cell >= 0 and cell < _stone_membership.size() \
			and _stone_membership[cell] != 0:
		_stone_rebuild_needed = true
	elif World.grid.is_valid_index(cell) \
			and World.feature_at(cell) == Terrain.Feature.STONE:
		_stone_rebuild_needed = true
	_queue_rebuild()


func _queue_rebuild() -> void:
	if _rebuild_queued:
		return
	_rebuild_queued = true
	call_deferred("_rebuild")


func _rebuild() -> void:
	_rebuild_queued = false
	_boundaries.clear()
	_tree_nodes.clear()
	_berry_nodes.clear()
	var grid: Grid = World.grid
	if World.feature.size() != grid.cell_count:
		_details.clear()
		_rock_overlays.clear()
		_stone_membership = PackedByteArray()
		_stone_rebuild_needed = true
		_sync_resource_multimesh(grid)
		_sync_boundary_lines()
		queue_redraw()
		return

	_build_boundaries(grid)
	_sync_boundary_lines()
	if _stone_rebuild_needed:
		_details.clear()
		_rock_overlays.clear()
		_build_stone_details(grid)
		_stone_membership.resize(grid.cell_count)
		_stone_membership.fill(0)
		for cell in grid.cell_count:
			if int(World.feature[cell]) == Terrain.Feature.STONE:
				_stone_membership[cell] = 1
		_stone_rebuild_needed = false
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

	_sync_resource_multimesh(grid)
	queue_redraw()


func _sync_resource_multimesh(grid: Grid) -> void:
	var groups: Dictionary = {}
	for node in _tree_nodes:
		var variant := int(node["seed"]) % TREE_VARIANTS
		_append_resource_instance(
			groups, Vector2(node["center"]), variant, 0
		)
	for node in _berry_nodes:
		var c: Vector2i = node["coord"]
		var color_index := _mix(
			floori(float(c.x) / 3.0), floori(float(c.y) / 2.0),
			World.seed_value + 809
		) % 4
		var variant := int(node["seed"]) % BERRY_VARIANTS
		_append_resource_instance(
			groups, Vector2(node["center"]), variant, 1 + color_index
		)

	for key in _resource_multimeshes:
		(_resource_multimeshes[key] as MultiMeshInstance2D).visible = groups.has(key) \
			and _draw_resource_nodes
	for key in groups:
		var chunk := Vector2i(key)
		var batch := _resource_multimeshes.get(chunk) as MultiMeshInstance2D
		if batch == null:
			batch = MultiMeshInstance2D.new()
			batch.name = "ResourceChunk_%d_%d" % [chunk.x, chunk.y]
			batch.texture = _node_atlas
			batch.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			batch.material = _resource_material
			batch.z_index = 1
			add_child(batch)
			_resource_multimeshes[chunk] = batch
		var world_origin := Vector2(
			chunk * RESOURCE_CHUNK_CELLS * Grid.TILE_SIZE
		)
		batch.position = world_origin
		batch.visible = _draw_resource_nodes
		var entries: Array = groups[key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_2D
		multimesh.use_custom_data = true
		var quad := QuadMesh.new()
		quad.size = Vector2(NODE_SPRITE_SIZE, NODE_SPRITE_SIZE)
		multimesh.mesh = quad
		multimesh.instance_count = entries.size()
		var extent := RESOURCE_CHUNK_CELLS * Grid.TILE_SIZE
		multimesh.custom_aabb = AABB(
			Vector3(-NODE_SPRITE_SIZE, -NODE_SPRITE_SIZE, -1.0),
			Vector3(
				extent + NODE_SPRITE_SIZE * 2,
				extent + NODE_SPRITE_SIZE * 2,
				2.0
			)
		)
		for instance_index in entries.size():
			var entry: Dictionary = entries[instance_index]
			multimesh.set_instance_transform_2d(
				instance_index,
				Transform2D(
					0.0, _pixel(Vector2(entry["center"])) - world_origin
				)
			)
			multimesh.set_instance_custom_data(
				instance_index,
				Color(
					float(entry["column"]), float(entry["row"]), 0.0, 0.0
				)
			)
		batch.multimesh = multimesh


func _append_resource_instance(
	groups: Dictionary, center: Vector2, column: int, row: int
	) -> void:
	var chunk_world_size := RESOURCE_CHUNK_CELLS * Grid.TILE_SIZE
	var chunk := Vector2i(
		floori(center.x / chunk_world_size),
		floori(center.y / chunk_world_size)
	)
	var entries: Array = groups.get(chunk, [])
	entries.append({"center": center, "column": column, "row": row})
	groups[chunk] = entries


func _build_boundaries(grid: Grid) -> void:
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for cell in grid.cell_count:
		if visited[cell] != 0:
			continue
		var feature := int(World.feature[cell])
		# Stone's complete silhouette is painted from the same pixel mask as its
		# shelves. Keeping a second vector outline here was the remaining visual
		# difference from the isolated art lab.
		if feature != Terrain.Feature.TREE:
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

		var wanted := 1
		if region.size() >= 18:
			wanted = clampi(ceili(float(region.size()) / 120.0), 1, 4)
		# The lab uses an authored shelf radius range and clips it to the rock
		# surface. Only small deposits scale that range down; a huge quarry gains
		# more shelves rather than comically enlarging the ones on top.
		var shelf_scale := clampf(
			sqrt(float(region.size()) / 260.0), 0.38, 0.62
		)
		var shelf_spacing := maxf(
			STONE_SHELF_SPACING, 120.0
		)
		var clearance_by_cell: Dictionary = {}
		var max_clearance := 0
		for cell in region:
			var clearance := _stone_clearance(
				grid.coord(cell), Terrain.Feature.STONE, grid
			)
			clearance_by_cell[cell] = clearance
			max_clearance = maxi(max_clearance, clearance)
		var minimum_clearance := maxi(1, mini(3, max_clearance - 1))
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
			if int(clearance_by_cell.get(cell, 0)) >= minimum_clearance:
				interior.append(cell)
		# Highly branched or perforated quarries may not contain a full square of
		# the preferred radius. Keep their shelves conservative, but do not drop
		# the raised top altogether.
		if interior.is_empty():
			for cell in region:
				if _is_cross_interior(
						grid.coord(cell), Terrain.Feature.STONE, grid
					):
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

		var detail_start := _details.size()
		var chosen: Array[Vector2] = []
		_add_stone_detail(
			primary, grid, chosen, shelf_scale, shelf_spacing,
			int(clearance_by_cell.get(primary, 1))
		)
		while chosen.size() < wanted:
			var next_cell := -1
			var next_distance := -1.0
			for cell in interior:
				if cell == primary:
					continue
				var candidate := grid.to_world(grid.coord(cell))
				var nearest := INF
				for existing in chosen:
					nearest = minf(nearest, candidate.distance_squared_to(existing))
				var candidate_coord := grid.coord(cell)
				var placement_hash := _mix(
					candidate_coord.x, candidate_coord.y,
					World.seed_value + chosen.size() * 131
				)
				var placement_variation := lerpf(
					0.82, 1.18,
					float((placement_hash >> 9) % 1024) / 1023.0
				)
				var placement_score := nearest * placement_variation
				if placement_score > next_distance:
					next_distance = placement_score
					next_cell = cell
			if next_cell == -1 \
					or next_distance < shelf_spacing * shelf_spacing:
				break
			_add_stone_detail(
				next_cell, grid, chosen, shelf_scale, shelf_spacing,
				int(clearance_by_cell.get(next_cell, 1))
			)
		var component_details: Array[Dictionary] = []
		for detail_index in range(detail_start, _details.size()):
			component_details.append(_details[detail_index])
		_build_rock_overlay(region, component_details, grid)


func _add_stone_detail(
		cell: int, grid: Grid, chosen: Array[Vector2],
		shelf_scale: float, shelf_spacing: float, clearance: int
	) -> void:
	var c := grid.coord(cell)
	var center := grid.to_world(c)
	for other in chosen:
		if center.distance_squared_to(other) < shelf_spacing * shelf_spacing:
			return
	chosen.append(center)
	var seed := _mix(
		c.x, c.y, World.seed_value + Terrain.Feature.STONE * 97
	)
	_details.append({
		"feature": Terrain.Feature.STONE, "center": center, "seed": seed,
		"scale": shelf_scale, "clearance": clearance,
	})


## Paint the approved lab shelves as one clipped mask for this connected quarry.
##
## This deliberately mirrors `embergard--nightkeep-art-lab` instead of drawing
## independent polygons: stamps are unioned first, clipped well inside the
## authoritative stone cells, then receive a two-pixel face rim and a shallow
## lower-right depth offset.
func _build_rock_overlay(
		region: PackedInt32Array, component_details: Array[Dictionary], grid: Grid
	) -> void:
	if region.is_empty() or component_details.is_empty():
		return
	var minimum := grid.coord(region[0])
	var maximum := minimum
	for cell in region:
		var c := grid.coord(cell)
		minimum.x = mini(minimum.x, c.x)
		minimum.y = mini(minimum.y, c.y)
		maximum.x = maxi(maximum.x, c.x)
		maximum.y = maxi(maximum.y, c.y)
	# One-cell halo accommodates the lab's overlapping rock ellipses beyond the
	# strict cell rectangle.
	var halo := Grid.TILE_SIZE
	var width := (maximum.x - minimum.x + 1) * Grid.TILE_SIZE + halo * 2
	var height := (maximum.y - minimum.y + 1) * Grid.TILE_SIZE + halo * 2
	if width <= 0 or height <= 0:
		return

	var rock_mask := PackedByteArray()
	rock_mask.resize(width * height)
	for cell in region:
		var world_c := grid.coord(cell)
		var c := world_c - minimum
		var center := Vector2i(
			c.x * Grid.TILE_SIZE + halo + Grid.TILE_SIZE / 2,
			c.y * Grid.TILE_SIZE + halo + Grid.TILE_SIZE / 2
		)
		var h := _mix(
			world_c.x, world_c.y,
			World.seed_value + Terrain.Feature.STONE * 101
		)
		_stamp_local_ellipse(
			rock_mask, width, height, center,
			14 + h % 2, 12 + (h >> 5) % 2
		)
		_stamp_local_ellipse(
			rock_mask, width, height,
			center + Vector2i(
				int((h >> 9) % 7) - 3,
				int((h >> 13) % 5) - 2
			),
			12 + int((h >> 17) % 2),
			10 + int((h >> 20) % 2)
		)

	var shelf_mask := PackedByteArray()
	shelf_mask.resize(width * height)
	var world_origin := Vector2(minimum * Grid.TILE_SIZE) \
		- Vector2(halo, halo)
	for detail in component_details:
		var center := Vector2(detail["center"]) - world_origin
		var seed := int(detail["seed"])
		var scale := float(detail.get("scale", 1.0))
		var radius_x := roundi(float(58 + (seed >> 18) % 39) * scale)
		var radius_y := roundi(float(36 + (seed >> 23) % 27) * scale)
		var inset := clampi(roundi(10.0 * scale), 6, 10)
		_stamp_clipped_shelf(
			shelf_mask, rock_mask, width, height,
			Vector2i(roundi(center.x), roundi(center.y)),
			radius_x, radius_y, seed, inset
		)

	var rock_depth := _local_mask_depth(rock_mask, width, height)
	var upper_face := PackedByteArray()
	upper_face.resize(width * height)
	for pixel in rock_depth.size():
		if rock_depth[pixel] > 6:
			upper_face[pixel] = 1
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	_paint_rock_mass(
		image, rock_mask, rock_depth, upper_face, width, height
	)
	_paint_shelf_mask(image, shelf_mask, rock_mask, width, height)
	var detail_seed := _mix(
		minimum.x, minimum.y, World.seed_value + Terrain.Feature.STONE * 307
	)
	_scatter_rock_grain(
		image, rock_mask, width, height, region.size() * 2, detail_seed
	)
	_paint_rock_cracks(
		image, upper_face, width, height,
		clampi(ceili(float(region.size()) / 18.0), 1, 24),
		detail_seed + 19073
	)
	_rock_overlays.append({
		"texture": ImageTexture.create_from_image(image),
		"position": world_origin,
	})


func _stamp_local_ellipse(
		mask: PackedByteArray, width: int, height: int,
		center: Vector2i, radius_x: int, radius_y: int
	) -> void:
	for y in range(maxi(0, center.y - radius_y),
			mini(height, center.y + radius_y + 1)):
		var dy := float(y - center.y) / float(maxi(1, radius_y))
		for x in range(maxi(0, center.x - radius_x),
				mini(width, center.x + radius_x + 1)):
			var dx := float(x - center.x) / float(maxi(1, radius_x))
			if dx * dx + dy * dy <= 1.0:
				mask[y * width + x] = 1


func _stamp_clipped_shelf(
		target: PackedByteArray, clip: PackedByteArray,
		width: int, height: int, center: Vector2i,
		radius_x: int, radius_y: int, seed: int, inset: int
	) -> void:
	var phase := float(seed % 628) / 100.0
	for y in range(maxi(0, center.y - radius_y - 2),
			mini(height, center.y + radius_y + 3)):
		for x in range(maxi(0, center.x - radius_x - 2),
				mini(width, center.x + radius_x + 3)):
			if not _local_mask_at(clip, width, height, x, y) \
					or _local_near_outside(
						clip, width, height, x, y, inset
					):
				continue
			var nx := float(x - center.x) / float(maxi(1, radius_x))
			var ny := float(y - center.y) / float(maxi(1, radius_y))
			var angle := atan2(ny, nx)
			var radius := sqrt(nx * nx + ny * ny)
			var edge := 1.0 \
				+ sin(angle * 3.0 + phase) * 0.095 \
				+ sin(angle * 5.0 - phase * 0.7) * 0.065 \
				+ sin(angle * 9.0 + phase * 1.3) * 0.035
			if radius <= edge:
				target[y * width + x] = 1


## The full outcrop is painted with the lab's same stepped masks. This replaces
## the old centered Line2D border, whose evenly thick rings read as a sticker.
func _paint_rock_mass(
		image: Image, rock: PackedByteArray, rock_depth: PackedByteArray,
		upper_face: PackedByteArray, width: int, height: int
	) -> void:
	# Four-by-five lower-right drop shadow.
	for y in height:
		for x in width:
			if not _local_mask_at(rock, width, height, x, y) \
					and _local_mask_at(rock, width, height, x - 4, y - 5):
				image.set_pixel(x, y, ROCK_SHADOW)

	# Two dark outer pixels, three deeper bevel pixels, then the broad base.
	# The distance map also identifies the lab's six-pixel inset in this pass.
	for y in height:
		for x in width:
			var depth := int(rock_depth[y * width + x])
			if depth == 0:
				continue
			var color := ROCK_EDGE_BASE
			if depth <= 2:
				color = ROCK_OUTER
			elif depth <= 5:
				color = ROCK_LEDGE_SHADOW
			elif depth <= 9:
				# The inset belongs to the same silhouette; this is its three-pixel rim.
				color = ROCK_LEDGE_SHADOW
			else:
				color = ROCK_MIDDLE
			image.set_pixel(x, y, color)

	# Directional lighting matches the lab: bright upper-left, occluded lower-right.
	_paint_directional_mask_rim(
		image, rock, width, height, ROCK_HIGHLIGHT, ROCK_SHADOW
	)


func _local_mask_depth(
		mask: PackedByteArray, width: int, height: int
	) -> PackedByteArray:
	# Two linear passes produce the Chebyshev distance to open ground. Six rounds
	# of the lab's 3x3 erosion have the same distance boundary, but cost roughly
	# fifty times more work during repeated harvest redraws.
	var depth := PackedByteArray()
	depth.resize(width * height)
	depth.fill(255)
	for index in mask.size():
		if mask[index] == 0:
			depth[index] = 0
	for y in height:
		for x in width:
			var index := y * width + x
			if depth[index] == 0:
				continue
			var nearest := int(depth[index])
			if x > 0:
				nearest = mini(nearest, int(depth[index - 1]) + 1)
			if y > 0:
				nearest = mini(nearest, int(depth[index - width]) + 1)
				if x > 0:
					nearest = mini(nearest, int(depth[index - width - 1]) + 1)
				if x + 1 < width:
					nearest = mini(nearest, int(depth[index - width + 1]) + 1)
			depth[index] = mini(nearest, 255)
	for y in range(height - 1, -1, -1):
		for x in range(width - 1, -1, -1):
			var index := y * width + x
			if depth[index] == 0:
				continue
			var nearest := int(depth[index])
			if x + 1 < width:
				nearest = mini(nearest, int(depth[index + 1]) + 1)
			if y + 1 < height:
				nearest = mini(nearest, int(depth[index + width]) + 1)
				if x > 0:
					nearest = mini(nearest, int(depth[index + width - 1]) + 1)
				if x + 1 < width:
					nearest = mini(nearest, int(depth[index + width + 1]) + 1)
			depth[index] = mini(nearest, 255)
	return depth


func _paint_directional_mask_rim(
		image: Image, mask: PackedByteArray, width: int, height: int,
		light_color: Color, shadow_color: Color
	) -> void:
	for y in height:
		for x in width:
			if not _local_mask_at(mask, width, height, x, y):
				continue
			if not _local_mask_at(mask, width, height, x - 1, y - 1) \
					and _local_mask_at(mask, width, height, x + 1, y + 1):
				image.set_pixel(x, y, light_color)
			elif not _local_mask_at(mask, width, height, x + 1, y + 1) \
					and _local_mask_at(mask, width, height, x - 1, y - 1):
				image.set_pixel(x, y, shadow_color)


func _scatter_rock_grain(
		image: Image, mask: PackedByteArray, width: int, height: int,
		count: int, seed: int
	) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 6:
		attempts += 1
		var x := rng.randi_range(1, width - 2)
		var y := rng.randi_range(1, height - 2)
		if not _local_mask_at(mask, width, height, x, y) \
				or _local_near_outside(mask, width, height, x, y, 5):
			continue
		image.set_pixel(
			x, y, ROCK_HIGHLIGHT if rng.randi_range(0, 4) == 0 \
			else ROCK_LEDGE_SHADOW
		)
		placed += 1


func _paint_rock_cracks(
		image: Image, surface: PackedByteArray, width: int, height: int,
		count: int, seed: int
	) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var painted := 0
	var attempts := 0
	while painted < count and attempts < count * 20:
		attempts += 1
		var start := Vector2i(
			rng.randi_range(8, width - 9), rng.randi_range(8, height - 9)
		)
		if not _local_mask_at(surface, width, height, start.x, start.y) \
				or _local_near_outside(
					surface, width, height, start.x, start.y, 7
				):
			continue
		var angle := rng.randf_range(0.0, TAU)
		var direction := Vector2(cos(angle), sin(angle))
		var position := Vector2(start)
		var length := rng.randi_range(8, 18)
		for step in length:
			if step > 0 and step % 5 == 0:
				direction = direction.rotated(rng.randf_range(-0.55, 0.55))
			position += direction
			var at := Vector2i(roundi(position.x), roundi(position.y))
			if not _local_mask_at(surface, width, height, at.x, at.y):
				break
			image.set_pixel(at.x, at.y, ROCK_LEDGE_SHADOW)
			if step % 3 == 0 and at.x > 0 and at.y > 0:
				image.set_pixel(at.x - 1, at.y - 1, ROCK_HIGHLIGHT)
		painted += 1


func _paint_shelf_mask(
		image: Image, shelf: PackedByteArray, rock: PackedByteArray,
		width: int, height: int
	) -> void:
	# Lower-right depth layers, clipped to the same quarry.
	for y in height:
		for x in width:
			if _local_mask_at(shelf, width, height, x, y) \
					or not _local_mask_at(shelf, width, height, x - 3, y - 4) \
					or not _local_mask_at(rock, width, height, x, y):
				continue
			image.set_pixel(x, y, ROCK_LEDGE_SHADOW)
	for y in height:
		for x in width:
			if _local_mask_at(shelf, width, height, x, y) \
					or not _local_mask_at(shelf, width, height, x - 1, y - 2) \
					or not _local_mask_at(rock, width, height, x, y):
				continue
			image.set_pixel(x, y, ROCK_EDGE_BASE)

	# The face itself: two-pixel mid-tone rim and the lab's warm exposed top.
	for y in height:
		for x in width:
			if not _local_mask_at(shelf, width, height, x, y):
				continue
			var color := ROCK_EDGE_BASE \
				if _local_near_outside(shelf, width, height, x, y, 2) \
				else ROCK_INNER
			image.set_pixel(x, y, color)

	# Directional one-pixel lip. A full dark outline is what made the previous
	# pass read as boulders.
	for y in height:
		for x in width:
			if not _local_mask_at(shelf, width, height, x, y):
				continue
			if not _local_mask_at(shelf, width, height, x - 1, y - 1) \
					and _local_mask_at(shelf, width, height, x + 1, y + 1):
				image.set_pixel(x, y, ROCK_HIGHLIGHT)
			elif not _local_mask_at(shelf, width, height, x + 1, y + 1) \
					and _local_mask_at(shelf, width, height, x - 1, y - 1):
				image.set_pixel(x, y, ROCK_EDGE_BASE)


func _local_mask_at(
		mask: PackedByteArray, width: int, height: int, x: int, y: int
	) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height \
		and mask[y * width + x] != 0


func _local_near_outside(
		mask: PackedByteArray, width: int, height: int,
		x: int, y: int, radius: int
	) -> bool:
	return not _local_mask_at(mask, width, height, x - radius, y) \
		or not _local_mask_at(mask, width, height, x + radius, y) \
		or not _local_mask_at(mask, width, height, x, y - radius) \
		or not _local_mask_at(mask, width, height, x, y + radius) \
		or not _local_mask_at(mask, width, height, x - radius, y - radius) \
		or not _local_mask_at(mask, width, height, x + radius, y - radius) \
		or not _local_mask_at(mask, width, height, x - radius, y + radius) \
		or not _local_mask_at(mask, width, height, x + radius, y + radius)


func _sync_boundary_lines() -> void:
	for line in _boundary_lines:
		if is_instance_valid(line):
			line.free()
	_boundary_lines.clear()
	for boundary in _boundaries:
		var line := Line2D.new()
		line.points = boundary["points"] as PackedVector2Array
		line.width = 6.0
		line.texture = _boundary_texture
		line.texture_mode = Line2D.LINE_TEXTURE_TILE
		line.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.round_precision = 2
		line.closed = true
		line.show_behind_parent = true
		line.visible = _draw_boundaries
		add_child(line)
		_boundary_lines.append(line)
	queue_redraw()


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


func _is_cross_interior(c: Vector2i, feature: int, grid: Grid) -> bool:
	const CARDINALS: Array[Vector2i] = [
		Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT,
	]
	if not _is_feature(c, feature, grid):
		return false
	for offset in CARDINALS:
		if not _is_feature(c + offset, feature, grid):
			return false
	return true


func _stone_clearance(
		c: Vector2i, feature: int, grid: Grid, maximum: int = 7
	) -> int:
	var clearance := 0
	for radius in range(1, maximum + 1):
		if not _is_solid_interior(c, feature, radius, grid):
			break
		clearance = radius
	return clearance


func _draw() -> void:
	if _draw_rocks:
		for overlay in _rock_overlays:
			draw_texture(
				overlay["texture"] as Texture2D,
				Vector2(overlay["position"])
			)

func set_profile_hidden(parts: PackedStringArray) -> PackedStringArray:
	var applied := PackedStringArray()
	for part in parts:
		match part:
			"feature_boundaries":
				_draw_boundaries = false
				for line in _boundary_lines:
					line.visible = false
				applied.append(part)
			"feature_nodes":
				_draw_resource_nodes = false
				for batch in _resource_multimeshes.values():
					(batch as MultiMeshInstance2D).visible = false
				applied.append(part)
			"feature_rocks":
				_draw_rocks = false
				applied.append(part)
	queue_redraw()
	return applied


func profile_counts() -> Dictionary:
	return {
		"forest_boundaries": _boundaries.size(),
		"rock_overlays": _rock_overlays.size(),
		"trees": _tree_nodes.size(),
		"berries": _berry_nodes.size(),
		"resource_batches": _resource_multimeshes.size(),
	}


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


func _build_boundary_texture() -> ImageTexture:
	# A single textured six-pixel stroke reproduces the old nested 6/3.5/1.5
	# contour. That cuts each forest from three draw calls to one and lets Godot
	# cull whole off-screen forest contours independently.
	var image := Image.create(2, 6, false, Image.FORMAT_RGBA8)
	for x in 2:
		image.set_pixel(x, 0, FOREST_EDGE_DARK)
		image.set_pixel(x, 1, FOREST_OUTER)
		image.set_pixel(x, 2, FOREST_EDGE_BASE)
		image.set_pixel(x, 3, FOREST_EDGE_BASE)
		image.set_pixel(x, 4, FOREST_OUTER)
		image.set_pixel(x, 5, FOREST_EDGE_DARK)
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


func _closed(points: PackedVector2Array) -> PackedVector2Array:
	var closed := points.duplicate()
	if not points.is_empty():
		closed.append(points[0])
	return closed


func _pixel(point: Vector2) -> Vector2:
	return Vector2(roundf(point.x), roundf(point.y))


func _mix(x: int, y: int, salt: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ salt * 83492791
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return absi(h)
