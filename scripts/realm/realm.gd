extends Node
## Autoload: the seeded campaign world, its square regions, colony ledgers, and Blight Heart.
##
## The Realm is one continuous generated landscape. Each square on it is a complete local map;
## only one is awake at a time, while every other founded region advances from its own ledger.

const REGION_WIDTH := 12
const REGION_HEIGHT := 8
const REGION_COUNT := REGION_WIDTH * REGION_HEIGHT
const MACRO_PIXELS_PER_REGION := 32

const SETTLEMENT_COST := {&"wood": 30, &"stone": 15, &"food": 24}
const STARTING_CARGO := {&"wood": 10, &"stone": 5, &"food": 12}
const SETTLERS_REQUIRED := 2
const HEART_BASELINE_THREAT := 0.18
const BLIGHT_HEART_MAX := 300
const ASSAULT_COST := {&"tools": 8, &"cut_stone": 16}
const ASSAULT_FAITH := 70.0
const ASSAULT_DAMAGE := 100

const _ADJECTIVES: Array[String] = [
	"Amber", "Ashen", "Briar", "Cinder", "Elder", "Fallow",
	"Gloam", "Hollow", "Moss", "Riven", "Stone", "Willow",
]
const _NOUNS: Array[String] = [
	"Downs", "Fen", "Hearth", "March", "Mere", "Reach",
	"Ridge", "Thicket", "Vale", "Watch", "Weald", "Wilds",
]

var world_seed: int = 0
var sites: Dictionary = {}           ## StringName -> generated region row
var colonies: Dictionary = {}        ## StringName -> ColonyLedger
var awake_id: StringName = &""
var heart_region_id: StringName = &""
var blight_core_id: StringName = &""
var global_corruption: float = 0.0
var blight_heart_health: int = BLIGHT_HEART_MAX
var complete: bool = false
var macro_texture: ImageTexture
var corruption_sources: Array[Vector2i] = []

var _threat_serial: int = 0
var _elevation := FastNoiseLite.new()
var _moisture := FastNoiseLite.new()
var _forest := FastNoiseLite.new()
var _stone := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _wildness := FastNoiseLite.new()
var _river := FastNoiseLite.new()
var _formation := FastNoiseLite.new()
var _micro := FastNoiseLite.new()
var _continent_blobs: Array[Dictionary] = []
var _island_blobs: Array[Dictionary] = []
var _gulf_blobs: Array[Dictionary] = []
var _climate_direction := Vector2.UP


func _ready() -> void:
	Events.day_advanced.connect(_on_day_advanced)


func start_new(seed_value: int) -> void:
	world_seed = seed_value
	Climate.reset(seed_value)
	Storyteller.reset(seed_value)
	sites.clear()
	colonies.clear()
	awake_id = &""
	heart_region_id = &""
	blight_core_id = &""
	global_corruption = 0.0
	blight_heart_health = BLIGHT_HEART_MAX
	complete = false
	_threat_serial = 0
	corruption_sources.clear()
	_configure_noise()
	_configure_continent()
	_build_regions()
	_build_macro_texture()
	Events.realm_changed.emit()


func _configure_noise() -> void:
	_elevation.seed = world_seed
	_elevation.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_elevation.frequency = 0.16
	_elevation.fractal_octaves = 4
	_moisture.seed = world_seed + 7919
	_moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture.frequency = 0.20
	_forest.seed = world_seed + 31337
	_forest.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_forest.frequency = 0.28
	_stone.seed = world_seed + 17011
	_stone.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_stone.frequency = 0.25
	_detail.seed = world_seed + 48157
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail.frequency = 0.78
	_wildness.seed = world_seed + 65537
	_wildness.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_wildness.frequency = 0.19
	_river.seed = world_seed + 99277
	_river.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_river.frequency = 0.27
	_formation.seed = world_seed + 120011
	_formation.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_formation.frequency = 0.46
	_micro.seed = world_seed + 150001
	_micro.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_micro.frequency = 1.35


func _configure_continent() -> void:
	_continent_blobs.clear()
	_island_blobs.clear()
	_gulf_blobs.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0x51ED270B
	var templates := [
		[Vector2(1.8, 4.2), Vector2(2.5, 2.35)],
		[Vector2(4.3, 2.8), Vector2(3.0, 2.25)],
		[Vector2(6.4, 5.2), Vector2(3.35, 2.35)],
		[Vector2(8.5, 3.4), Vector2(3.2, 2.45)],
		[Vector2(10.3, 5.4), Vector2(2.25, 1.8)],
	]
	for template in templates:
		_continent_blobs.append({
			"center": template[0] + Vector2(rng.randf_range(-0.38, 0.38),
				rng.randf_range(-0.32, 0.32)),
			"radius": template[1] * Vector2(rng.randf_range(0.88, 1.12),
				rng.randf_range(0.88, 1.12)),
		})
	var island_templates := [
		Vector2(0.45, 1.35), Vector2(2.3, 0.35),
		Vector2(5.4, 7.72), Vector2(11.55, 1.45), Vector2(11.45, 7.0),
	]
	for point: Vector2 in island_templates:
		_island_blobs.append({
			"center": point + Vector2(rng.randf_range(-0.28, 0.28),
				rng.randf_range(-0.22, 0.22)),
			"radius": Vector2(rng.randf_range(0.42, 0.84), rng.randf_range(0.34, 0.68)),
		})
	var gulf_templates := [
		[Vector2(5.7, 0.0), Vector2(1.15, 1.85)],
		[Vector2(4.1, 8.05), Vector2(1.35, 1.9)],
		[Vector2(12.05, 3.7), Vector2(1.35, 1.15)],
	]
	for template in gulf_templates:
		_gulf_blobs.append({
			"center": template[0] + Vector2(rng.randf_range(-0.38, 0.38),
				rng.randf_range(-0.28, 0.28)),
			"radius": template[1] * rng.randf_range(0.88, 1.14),
		})
	var climate_angle := rng.randf_range(-PI, PI)
	_climate_direction = Vector2(cos(climate_angle), sin(climate_angle))


func _build_regions() -> void:
	for y in REGION_HEIGHT:
		for x in REGION_WIDTH:
			var id := region_id(Vector2i(x, y))
			var sampled := _sample_landscape(x + 0.5, y + 0.5)
			var biome: StringName = sampled["biome"]
			var settleable := biome != &"ocean"
			sites[id] = {
				"id": id,
				"name": _region_name(x, y),
				"coord": Vector2i(x, y),
				"position": Vector2(x, y),
				"seed": _region_seed(x, y),
				"connections": [],
				"biome": biome,
				"elevation": sampled["elevation"],
				"moisture": sampled["moisture"],
				"forest": sampled["forest"],
				"stone": sampled["stone"],
				"food": sampled["food"],
				"corruption": 0.0,
				"settleable": settleable,
				"blight_core": false,
			}

	# Cardinal neighbours make movement easy to read: a caravan crosses one map edge at a time.
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row["settleable"]):
			continue
		var coord: Vector2i = row["coord"]
		var links: Array[StringName] = []
		for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
			var other := site_at(coord + offset)
			if not other.is_empty() and bool(other.get("settleable", false)):
				links.append(StringName(other["id"]))
		row["connections"] = links

	blight_core_id = _choose_blight_core()
	_choose_corruption_sources()
	var total_corruption := 0.0
	var land_count := 0
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row["settleable"]):
			continue
		var coord: Vector2i = row["coord"]
		var wild := (_wildness.get_noise_2d(coord.x + 0.5, coord.y + 0.5) + 1.0) * 0.5
		# Latent pockets are deliberately invisible on the overview and do not advance until
		# somebody settles here. They only decide the small local footholds a new colony finds.
		var corruption := 0.025 + wild * 0.055
		for source: Vector2i in corruption_sources:
			var distance := Vector2(coord - source).length()
			var strength := 0.56 if source == sites[blight_core_id]["coord"] else 0.38
			corruption = maxf(corruption,
				clampf(1.0 - distance / 3.4, 0.0, 1.0) * strength + wild * 0.035)
		corruption = clampf(corruption, 0.02, 0.62)
		row["corruption"] = corruption
		total_corruption += corruption
		land_count += 1
	sites[blight_core_id]["blight_core"] = true
	sites[blight_core_id]["settleable"] = false
	sites[blight_core_id]["connections"] = []
	for id: StringName in sites:
		var links: Array = sites[id].get("connections", [])
		links.erase(blight_core_id)
	global_corruption = total_corruption / float(maxi(land_count, 1))


func _sample_landscape(x: float, y: float) -> Dictionary:
	var point := Vector2(x, y)
	var land_field := _land_field(point)
	var broad_noise := _elevation.get_noise_2d(x, y)
	var coast_noise := _detail.get_noise_2d(x * 0.58, y * 0.58)
	var landness := land_field + broad_noise * 0.19 + coast_noise * 0.075
	var elevation := clampf(0.48 + broad_noise * 0.22
		+ _stone.get_noise_2d(x * 0.72, y * 0.72) * 0.15, 0.08, 0.92)
	var moisture := clampf((_moisture.get_noise_2d(x, y) + 1.0) * 0.5, 0.0, 1.0)
	var forest_richness := clampf(
		((_forest.get_noise_2d(x, y) + 1.0) * 0.5) * 0.62 + moisture * 0.55 - 0.15,
		0.0, 1.0)
	var stone_richness := clampf(
		((_stone.get_noise_2d(x, y) + 1.0) * 0.5) * 0.70 + elevation * 0.52 - 0.28,
		0.0, 1.0)
	var food_richness := clampf(moisture * 0.62 + (1.0 - absf(elevation - 0.52)) * 0.38,
		0.0, 1.0)
	var biome: StringName
	if landness < 0.0:
		biome = &"ocean"
	elif landness < 0.105:
		biome = &"coast"
	else:
		var climate_position := Vector2(
			(x - REGION_WIDTH * 0.5) / (REGION_WIDTH * 0.5),
			(y - REGION_HEIGHT * 0.5) / (REGION_HEIGHT * 0.5))
		var climate_axis := climate_position.dot(_climate_direction)
		var formation := _formation.get_noise_2d(x, y)
		var scores := {
			&"grassland": 0.56,
			&"forest": forest_richness * 0.88 + maxf(-formation, 0.0) * 0.22,
			&"marsh": moisture * 0.82 + maxf(formation, 0.0) * 0.18,
			&"highland": stone_richness * 0.84 + maxf(formation, 0.0) * 0.25,
			&"badlands": (1.0 - moisture) * 0.78 + maxf(-formation, 0.0) * 0.20,
			&"tundra": 0.28 + climate_axis * 0.43 + (1.0 - moisture) * 0.27,
		}
		biome = &"grassland"
		var best_score := float(scores[biome])
		for kind: StringName in scores:
			if float(scores[kind]) > best_score:
				best_score = float(scores[kind])
				biome = kind
	return {
		"biome": biome,
		"landness": landness,
		"elevation": elevation,
		"moisture": moisture,
		"forest": forest_richness,
		"stone": stone_richness,
		"food": food_richness,
	}


func _land_field(point: Vector2) -> float:
	var field := -10.0
	for blob: Dictionary in _continent_blobs:
		var center: Vector2 = blob["center"]
		var radius: Vector2 = blob["radius"]
		var delta := (point - center) / radius
		field = maxf(field, 1.0 - delta.length())
	for blob: Dictionary in _island_blobs:
		var center: Vector2 = blob["center"]
		var radius: Vector2 = blob["radius"]
		var delta := (point - center) / radius
		field = maxf(field, 0.72 - delta.length())
	for blob: Dictionary in _gulf_blobs:
		var center: Vector2 = blob["center"]
		var radius: Vector2 = blob["radius"]
		var delta := (point - center) / radius
		var carve := clampf(1.0 - delta.length(), 0.0, 1.0)
		field -= carve * 0.68
	return field


func _choose_corruption_sources() -> void:
	corruption_sources.clear()
	if not sites.has(blight_core_id):
		return
	corruption_sources.append(sites[blight_core_id]["coord"])
	var candidates: Array[Dictionary] = []
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row.get("settleable", false)) or id == blight_core_id:
			continue
		var coord: Vector2i = row["coord"]
		var wild := (_wildness.get_noise_2d(coord.x + 0.5, coord.y + 0.5) + 1.0) * 0.5
		var variation := absf(sin(float(world_seed + coord.x * 41 + coord.y * 73)))
		candidates.append({"coord": coord, "score": wild * 0.72 + variation * 0.28})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))
	for candidate: Dictionary in candidates:
		var coord: Vector2i = candidate["coord"]
		var far_enough := true
		for existing: Vector2i in corruption_sources:
			if Vector2(coord - existing).length() < 2.4:
				far_enough = false
				break
		if far_enough:
			corruption_sources.append(coord)
		if corruption_sources.size() >= 4:
			break


func _choose_blight_core() -> StringName:
	var best: StringName = &""
	var best_score := -INF
	var center := Vector2(REGION_WIDTH - 2.0, REGION_HEIGHT * 0.5)
	var mainland := _largest_land_component()
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row["settleable"]) or not mainland.has(id):
			continue
		var coord: Vector2i = row["coord"]
		if coord.x < 1 or coord.x >= REGION_WIDTH - 1 or coord.y < 1 or coord.y >= REGION_HEIGHT - 1:
			continue
		var nearby_land: Array[StringName] = []
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var other := site_at(coord + Vector2i(dx, dy))
				if not other.is_empty() and bool(other.get("settleable", false)):
					nearby_land.append(StringName(other["id"]))
		if nearby_land.size() < 5:
			continue
		# The Heart cannot be a land bridge that makes half its own containment ring unreachable.
		var reachable := _component_from(nearby_land[0], id)
		var ring_reachable := true
		for neighbour: StringName in nearby_land:
			if not reachable.has(neighbour):
				ring_reachable = false
				break
		if not ring_reachable:
			continue
		var wild := (_wildness.get_noise_2d(coord.x, coord.y) + 1.0) * 0.5
		var score := wild * 0.9 - Vector2(coord).distance_to(center) * 0.035 + coord.x * 0.025
		if score > best_score:
			best_score = score
			best = id
	if best != &"":
		return best
	for id: StringName in sites:
		if bool(sites[id].get("settleable", false)):
			return id
	return &""


func _component_from(start: StringName, excluded: StringName = &"") -> Dictionary:
	var found := {}
	if start == excluded or not sites.has(start) or not bool(sites[start].get("settleable", false)):
		return found
	var queue: Array[StringName] = [start]
	found[start] = true
	while not queue.is_empty():
		var id: StringName = queue.pop_front()
		for other: StringName in sites[id].get("connections", []):
			if other == excluded or found.has(other):
				continue
			if bool(sites[other].get("settleable", false)):
				found[other] = true
				queue.append(other)
	return found


func _largest_land_component(excluded: StringName = &"") -> Dictionary:
	var visited := {}
	var largest := {}
	for id: StringName in sites:
		if id == excluded or visited.has(id) or not bool(sites[id].get("settleable", false)):
			continue
		var component := _component_from(id, excluded)
		for member in component:
			visited[member] = true
		if component.size() > largest.size():
			largest = component
	return largest


func _build_macro_texture() -> void:
	var width := REGION_WIDTH * MACRO_PIXELS_PER_REGION
	var height := REGION_HEIGHT * MACRO_PIXELS_PER_REGION
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	var materials := PackedByteArray()
	materials.resize(width * height)
	var variants := PackedByteArray()
	variants.resize(width * height)
	var tones := PackedFloat32Array()
	tones.resize(width * height)
	var berry_centers := PackedByteArray()
	berry_centers.resize(width * height)
	for py in height:
		for px in width:
			var rx := (float(px) + 0.5) / MACRO_PIXELS_PER_REGION
			var ry := (float(py) + 0.5) / MACRO_PIXELS_PER_REGION
			var sampled := _sample_landscape(rx, ry)
			var biome: StringName = sampled["biome"]
			var material := _macro_material(biome)
			var river_line := absf(_river.get_noise_2d(rx, ry))
			if biome not in [&"ocean", &"coast", &"highland"] \
					and float(sampled["moisture"]) > 0.46 and river_line < 0.014:
				material = 7
			elif material not in [0, 1]:
				# These are resources, not extra biomes. Their coverage is driven by the
				# same continuous forest/stone richness sampled into each region profile,
				# so the clean overview previews what its close local map will favor.
				material = _macro_resource_material(rx, ry, sampled, material)
			var index := py * width + px
			var formation := _formation.get_noise_2d(rx, ry)
			materials[index] = material
			variants[index] = _macro_variant(material, formation)
			tones[index] = _micro.get_noise_2d(rx * 1.7, ry * 1.7)
			berry_centers[index] = 1 if _macro_is_berry_center(px, py, sampled) else 0

	for py in height:
		for px in width:
			var index := py * width + px
			var material := int(materials[index])
			var variant := int(variants[index])
			var color := _macro_color(material, variant)
			var tone := float(tones[index])
			color = color.lightened(tone * 0.028) if tone >= 0.0 \
				else color.darkened(-tone * 0.038)

			if _macro_boundary(materials, px, py, width, height, material):
				color = Color("17201d") if material != 0 else Color("082f43")
			elif _macro_near_boundary(materials, px, py, width, height, material, 2):
				color = color.lightened(0.12)
			elif material not in [0, 7] \
					and _macro_boundary(variants, px, py, width, height, variant):
				color = color.darkened(0.28)

			var speckle := absi((px * 73856093) ^ (py * 19349663) ^ world_seed) & 255
			if material == 0 and py % 5 == 0 and speckle < 28:
				color = color.lerp(Color("2384a4"), 0.46)
			elif material != 0 and material != 7 and speckle < 3:
				color = color.lightened(0.22 if speckle == 0 else 0.12)

			# Berries stay small even on the overview: a few bright fruit pixels nestled in
			# a dark shrub, never another full terrain formation. Food richness controls how
			# often a deterministic cluster appears.
			if material not in [0, 1, 5, 7, 9] \
					and not _macro_boundary(materials, px, py, width, height, material):
				var berry_mark := _macro_berry_mark(berry_centers, px, py, width, height)
				if berry_mark == 2:
					color = Color("bd4058")
				elif berry_mark == 1:
					color = Color("315c27")
			image.set_pixel(px, py, color)
	macro_texture = ImageTexture.create_from_image(image)


func _macro_material(biome: StringName) -> int:
	match biome:
		&"ocean": return 0
		&"coast": return 1
		&"tundra": return 1
		&"grassland": return 2
		&"forest": return 3
		&"marsh": return 4
		&"highland": return 5
		&"badlands": return 6
		_: return 2


func _macro_variant(material: int, formation: float) -> int:
	if material in [0, 7]:
		return 0
	if formation > 0.30:
		return 2
	if formation < -0.22:
		return 1
	return 0


func _macro_resource_material(rx: float, ry: float, sampled: Dictionary,
		base_material: int) -> int:
	var forest_richness := float(sampled.get("forest", 0.5))
	var stone_richness := float(sampled.get("stone", 0.5))
	var forest_field := (_forest.get_noise_2d(rx * 3.05 + 37.0, ry * 3.05 - 19.0) + 1.0) * 0.5
	var stone_field := (_stone.get_noise_2d(rx * 3.35 - 23.0, ry * 3.35 + 41.0) + 1.0) * 0.5
	var forest_threshold := 0.80 - forest_richness * 0.27
	var stone_threshold := 0.84 - stone_richness * 0.23
	var forest_margin := forest_field - forest_threshold
	var stone_margin := stone_field - stone_threshold
	if forest_margin > 0.0 and forest_margin >= stone_margin * 1.08:
		return 8
	if stone_margin > 0.0:
		return 9
	return base_material


func _macro_is_berry_center(px: int, py: int, sampled: Dictionary) -> bool:
	var hash_value := absi((px * 83492791) ^ (py * 297657976) ^ (world_seed * 31))
	if hash_value % 67 != 0:
		return false
	if StringName(sampled["biome"]) in [&"ocean", &"coast"]:
		return false
	var food_richness := float(sampled.get("food", 0.5))
	if food_richness < 0.40:
		return false
	var rx := (float(px) + 0.5) / MACRO_PIXELS_PER_REGION
	var ry := (float(py) + 0.5) / MACRO_PIXELS_PER_REGION
	var berry_field := (_micro.get_noise_2d(rx * 5.8 + 11.0, ry * 5.8 - 7.0) + 1.0) * 0.5
	return berry_field > 0.68 - food_richness * 0.12


func _macro_berry_mark(centers: PackedByteArray, x: int, y: int, width: int,
		height: int) -> int:
	if centers[y * width + x] != 0:
		return 2
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if ox == 0 and oy == 0:
				continue
			var point := Vector2i(x + ox, y + oy)
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			if centers[point.y * width + point.x] != 0:
				return 1
	return 0


func _macro_color(material: int, variant: int) -> Color:
	const PALETTES := [
		["0b4059", "0b4059", "0b4059"],
		["d8cc8d", "b99a37", "eee2a7"],
		["557d27", "416b22", "71952f"],
		["11752b", "095624", "28a22d"],
		["08756c", "075850", "12978a"],
		["969894", "6e7476", "b8b7ae"],
		["9b552d", "774531", "c16c2f"],
		["1784aa", "1784aa", "1784aa"],
		["0f5124", "083819", "176a2b"],
		["76746e", "4f504d", "a09d94"],
	]
	return Color(PALETTES[clampi(material, 0, PALETTES.size() - 1)][clampi(variant, 0, 2)])


func _macro_boundary(values: PackedByteArray, x: int, y: int, width: int, height: int,
		value: int) -> bool:
	if x > 0 and values[y * width + x - 1] != value:
		return true
	if x < width - 1 and values[y * width + x + 1] != value:
		return true
	if y > 0 and values[(y - 1) * width + x] != value:
		return true
	if y < height - 1 and values[(y + 1) * width + x] != value:
		return true
	return false


func _macro_near_boundary(values: PackedByteArray, x: int, y: int, width: int, height: int,
		value: int, distance: int) -> bool:
	for oy in range(-distance, distance + 1):
		for ox in range(-distance, distance + 1):
			if absi(ox) + absi(oy) > distance:
				continue
			var point := Vector2i(x + ox, y + oy)
			if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
				continue
			if values[point.y * width + point.x] != value:
				return true
	return false


## Build the close inspection shown after selecting a region. Unsettled previews are generated
## from the exact local seed without mutating World. Settled previews use their stored terrain,
## harvested features and a deliberately subtle view of their real local Blight.
func build_region_preview(site_id: StringName) -> ImageTexture:
	if not sites.has(site_id):
		return null
	var row: Dictionary = sites[site_id]
	if StringName(row.get("biome", &"ocean")) == &"ocean":
		var water_image := Image.create(World.MAP_WIDTH, World.MAP_HEIGHT, false,
			Image.FORMAT_RGBA8)
		for y in World.MAP_HEIGHT:
			for x in World.MAP_WIDTH:
				var wave := absi(x * 37 + y * 71 + int(row["seed"])) % 43
				water_image.set_pixel(x, y,
					Color("176681") if y % 6 == 0 and wave < 9 else Color("0a3d59"))
		return ImageTexture.create_from_image(water_image)
	var preview_grid := Grid.new(World.MAP_WIDTH, World.MAP_HEIGHT)
	var terrain := PackedByteArray()
	var features := PackedByteArray()
	var blight := PackedByteArray()
	var buildings: Array = []
	var ledger := colony(site_id)
	if ledger != null and not ledger.state.is_empty():
		terrain = ledger.state.get("terrain", PackedByteArray()).duplicate()
		features = ledger.state.get("feature", PackedByteArray()).duplicate()
		blight = ledger.state.get("blight", PackedByteArray()).duplicate()
		buildings = ledger.state.get("buildings", []).duplicate(true)
	if terrain.size() != preview_grid.cell_count or features.size() != preview_grid.cell_count:
		var result := MapGen.generate(preview_grid, int(row["seed"]), -1, row)
		terrain = result.terrain
		features = result.feature
		blight = PackedByteArray()
		blight.resize(preview_grid.cell_count)

	var image := Image.create(preview_grid.width, preview_grid.height, false, Image.FORMAT_RGBA8)
	for y in preview_grid.height:
		for x in preview_grid.width:
			var cell := preview_grid.index(x, y)
			var color := _preview_terrain_color(int(terrain[cell]))
			var feature := int(features[cell])
			if feature == Terrain.Feature.TREE:
				color = Color("123e25") if _preview_feature_edge(
					preview_grid, features, cell, feature) else Color("247a36")
			elif feature == Terrain.Feature.STONE:
				color = Color("373b3e") if _preview_feature_edge(
					preview_grid, features, cell, feature) else Color("92918b")
			elif feature == Terrain.Feature.BERRIES:
				var berry_hash := absi(cell * 37 + int(row["seed"])) % 3
				color = Color("a83e55") if berry_hash == 0 else Color("315f2d")
			var surface_hash := absi(cell * 1103515245 + int(row["seed"])) & 255
			if feature == Terrain.Feature.NONE and surface_hash < 5:
				color = color.lightened(0.10)
			if ledger != null and blight.size() == preview_grid.cell_count and blight[cell] > 0:
				var amount := minf(float(blight[cell]) / 255.0 * 0.24, 0.22)
				color = color.lerp(Color("84355f"), amount)
			image.set_pixel(x, y, color)

	for packed: Dictionary in buildings:
		var anchor := int(packed.get("anchor", -1))
		if not preview_grid.is_valid_index(anchor):
			continue
		var coord := preview_grid.coord(anchor)
		var def := Buildings.get_building(StringName(packed.get("def", &"")))
		var footprint := Vector2i(2, 2) if def == null else def.footprint
		var building_color := Color("ffc66f") if bool(packed.get("complete", false)) \
			else Color("a7794d")
		image.fill_rect(Rect2i(coord, footprint), building_color)
	return ImageTexture.create_from_image(image)


func _preview_terrain_color(terrain_type: int) -> Color:
	match terrain_type:
		Terrain.Type.DEEP_WATER: return Color("0a344d")
		Terrain.Type.WATER: return Color("176681")
		Terrain.Type.SAND: return Color("c6b875")
		Terrain.Type.DIRT: return Color("795237")
		Terrain.Type.ROCK: return Color("686a69")
		Terrain.Type.RUBBLE: return Color("55504a")
		_: return Color("4d782f")


func _preview_feature_edge(grid: Grid, features: PackedByteArray, cell: int, target: int) -> bool:
	for neighbour in grid.neighbours_4(cell):
		if int(features[neighbour]) != target:
			return true
	return false


func _region_name(x: int, y: int) -> String:
	var hash_value := absi(world_seed * 31 + x * 73856093 + y * 19349663)
	var adjective := _ADJECTIVES[hash_value % _ADJECTIVES.size()]
	var noun := _NOUNS[(hash_value / _ADJECTIVES.size()) % _NOUNS.size()]
	return "%s %s" % [adjective, noun]


func _region_seed(x: int, y: int) -> int:
	var mixed := world_seed ^ (x * 73856093) ^ (y * 19349663) ^ 0x45D9F3B
	return absi(mixed) + 101


func region_id(coord: Vector2i) -> StringName:
	return StringName("r_%d_%d" % [coord.x, coord.y])


func site_at(coord: Vector2i) -> Dictionary:
	if coord.x < 0 or coord.y < 0 or coord.x >= REGION_WIDTH or coord.y >= REGION_HEIGHT:
		return {}
	return site(region_id(coord))


func suggested_first_region() -> StringName:
	var best: StringName = &""
	var best_score := -INF
	var wanted := Vector2(REGION_WIDTH * 0.34, REGION_HEIGHT * 0.52)
	var mainland := _largest_land_component(blight_core_id)
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row.get("settleable", false)) or bool(row.get("blight_core", false)):
			continue
		if not mainland.has(id):
			continue
		var score := float(row["food"]) * 1.15 + float(row["forest"]) * 0.72 \
			+ float(row["stone"]) * 0.72 - float(row["corruption"]) * 1.2 \
			- maxf(0.42 - float(row["stone"]), 0.0) * 2.8 \
			- Vector2(row["coord"]).distance_to(wanted) * 0.055
		if score > best_score:
			best_score = score
			best = id
	return best


func can_found_first(site_id: StringName) -> Dictionary:
	if not sites.has(site_id) or not bool(sites[site_id].get("settleable", false)):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_UNSETTLEABLE")}
	if bool(sites[site_id].get("blight_core", false)):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_CORE")}
	return {"ok": true, "reason": ""}


func register_first_from_live(site_id: StringName) -> void:
	if not sites.has(site_id):
		return
	var row: Dictionary = sites[site_id]
	var ledger := ColonyLedger.new()
	ledger.id = site_id
	ledger.display_name = String(row["name"])
	ledger.seed_value = World.seed_value
	ledger.keep_cell = World.keep_cell
	ledger.realm_position = Vector2(row["coord"])
	ledger.connections.assign(row["connections"])
	ledger.is_heart = true
	ledger.founded_day = Sim.day
	ledger.last_advanced_day = Sim.day
	ledger.corruption = float(row.get("corruption", 0.0))
	colonies[ledger.id] = ledger
	awake_id = ledger.id
	heart_region_id = ledger.id
	Abstractor.capture(ledger)
	Events.realm_changed.emit()
	Events.colony_awakened.emit(awake_id)


func capture_awake() -> void:
	var ledger := awake_ledger()
	if ledger == null or not Sim.running:
		return
	Abstractor.capture(ledger)


func awake_ledger() -> ColonyLedger:
	return colonies.get(awake_id) as ColonyLedger


func colony(id: StringName) -> ColonyLedger:
	return colonies.get(id) as ColonyLedger


func site(id: StringName) -> Dictionary:
	return sites.get(id, {})


func settled(id: StringName) -> bool:
	return colonies.has(id) and not (colonies[id] as ColonyLedger).fallen


func connected(from_id: StringName, to_id: StringName) -> bool:
	if not sites.has(from_id):
		return false
	return to_id in sites[from_id].get("connections", [])


func can_found(site_id: StringName) -> Dictionary:
	if not sites.has(site_id) or colonies.has(site_id):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_SETTLED")}
	if not bool(sites[site_id].get("settleable", false)):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_UNSETTLEABLE")}
	if not connected(awake_id, site_id):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_NO_ROAD")}
	if Colony.population() <= SETTLERS_REQUIRED:
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_SETTLERS")}
	for kind: StringName in SETTLEMENT_COST:
		if Colony.available(kind) < int(SETTLEMENT_COST[kind]):
			return {"ok": false, "reason": L10n.t(&"REALM_REASON_RESOURCE",
				[L10n.resource(kind)])}
	return {"ok": true, "reason": ""}


func prepare_settlement(site_id: StringName) -> Dictionary:
	var check := can_found(site_id)
	if not bool(check["ok"]):
		return check
	capture_awake()
	var source := awake_ledger()
	for kind: StringName in SETTLEMENT_COST:
		Colony.spend({kind: int(SETTLEMENT_COST[kind])})
		source.state["stock"][kind] = Colony.amount_of(kind)

	var settlers: Array = []
	var source_rows: Array = source.state.get("villagers", [])
	for _i in SETTLERS_REQUIRED:
		settlers.append(source_rows.pop_back())
	source.state["villagers"] = source_rows

	var row: Dictionary = sites[site_id]
	var ledger := ColonyLedger.new()
	ledger.id = site_id
	ledger.display_name = String(row["name"])
	ledger.seed_value = int(row["seed"])
	ledger.realm_position = Vector2(row["coord"])
	ledger.connections.assign(row["connections"])
	ledger.founded_day = Sim.day
	ledger.last_advanced_day = Sim.day
	ledger.corruption = float(row.get("corruption", 0.0))
	colonies[site_id] = ledger
	Events.realm_changed.emit()
	return {
		"ok": true,
		"ledger": ledger,
		"settlers": settlers,
		"cargo": STARTING_CARGO.duplicate(true),
	}


func can_travel(target_id: StringName) -> bool:
	return target_id != awake_id and settled(target_id) and connected(awake_id, target_id)


func set_awake(target_id: StringName) -> void:
	awake_id = target_id
	var ledger := awake_ledger()
	if ledger != null:
		ledger.advance_to(Sim.day)
	Events.realm_changed.emit()
	Events.colony_awakened.emit(awake_id)


func transfer_resource(target_id: StringName, kind: StringName, amount: int) -> bool:
	if amount <= 0 or not settled(target_id) or not connected(awake_id, target_id):
		return false
	if Colony.available(kind) < amount:
		return false
	Colony.spend({kind: amount})
	var target := colony(target_id)
	var target_stock: Dictionary = target.state.get("stock", {}).duplicate()
	target_stock[kind] = int(target_stock.get(kind, 0)) + amount
	target.state["stock"] = target_stock
	capture_awake()
	Events.realm_changed.emit()
	return true


func transfer_migrant(target_id: StringName) -> bool:
	if Colony.population() <= 1 or not settled(target_id) or not connected(awake_id, target_id):
		return false
	capture_awake()
	var source := awake_ledger()
	var rows: Array = source.state.get("villagers", [])
	if rows.is_empty():
		return false
	var row: Dictionary = rows.pop_back()
	source.state["villagers"] = rows
	var target := colony(target_id)
	var target_rows: Array = target.state.get("villagers", [])
	if target.keep_cell != -1:
		var arrival := World.grid.to_world_index(target.keep_cell)
		row["x"] = arrival.x
		row["y"] = arrival.y
	target_rows.append(row)
	target.state["villagers"] = target_rows
	var live = Colony.villagers.back()
	if is_instance_valid(live):
		live.alive = false
		Sim.unregister(live)
		Colony.villagers.erase(live)
		live.queue_free()
	Events.realm_changed.emit()
	return true


func mark_awake_fallen() -> void:
	capture_awake()
	var ledger := awake_ledger()
	if ledger != null:
		ledger.fallen = true
		ledger.state["villagers"] = []
	Events.realm_changed.emit()


func _on_day_advanced(day_number: int) -> void:
	for id in colonies:
		if id == awake_id:
			continue
		var ledger: ColonyLedger = colonies[id]
		ledger.advance_to(day_number)
	var sum := 0.0
	var count := 0
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row.get("settleable", false)):
			continue
		var local := float(row.get("corruption", 0.0))
		if colonies.has(id):
			local = (colonies[id] as ColonyLedger).corruption
		sum += local
		count += 1
	global_corruption = sum / float(maxi(count, 1))
	Events.realm_changed.emit()


func region_is_warded(site_id: StringName) -> bool:
	if not sites.has(site_id) or not bool(sites[site_id].get("settleable", false)):
		return false
	var target := Vector2(sites[site_id]["coord"])
	for ledger: ColonyLedger in colonies.values():
		if ledger.fallen:
			continue
		var radius := 0.65 + ledger.defense_strength() * 2.5
		if ledger.realm_position.distance_to(target) <= radius:
			return true
	return false


func ring_coverage() -> float:
	var land := 0
	var warded := 0
	for id: StringName in sites:
		if not bool(sites[id].get("settleable", false)):
			continue
		land += 1
		if region_is_warded(id):
			warded += 1
	return float(warded) / float(maxi(land, 1))


func _core_neighbours() -> Array[StringName]:
	var out: Array[StringName] = []
	if not sites.has(blight_core_id):
		return out
	var center: Vector2i = sites[blight_core_id]["coord"]
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var row := site_at(center + Vector2i(dx, dy))
			if not row.is_empty() and StringName(row["id"]) != blight_core_id \
					and StringName(row.get("biome", &"ocean")) != &"ocean":
				out.append(StringName(row["id"]))
	return out


func ring_closed() -> bool:
	if colonies.size() < 4:
		return false
	var neighbours := _core_neighbours()
	if neighbours.size() < 4:
		return false
	for id: StringName in neighbours:
		if not region_is_warded(id):
			return false
	return true


func _shield_at(angle: float) -> ColonyLedger:
	if not sites.has(heart_region_id):
		return null
	var origin := Vector2(sites[heart_region_id]["coord"])
	var best: ColonyLedger = null
	var best_strength := 0.0
	for ledger: ColonyLedger in colonies.values():
		if ledger.is_heart or ledger.fallen:
			continue
		var strength := ledger.defense_strength()
		if strength < 0.18:
			continue
		var offset := ledger.realm_position - origin
		if offset.length_squared() < 0.1:
			continue
		var delta := absf(wrapf(angle - offset.angle(), -PI, PI))
		var half_width := deg_to_rad(clampf(31.0 + strength * 24.0 - offset.length() * 2.4,
			12.0, 48.0))
		if delta <= half_width and strength > best_strength:
			best = ledger
			best_strength = strength
	return best


func intercept_threat(cell: int, cost: float) -> bool:
	if awake_id != heart_region_id or not World.grid.is_valid_index(cell):
		return false
	var delta := Vector2(World.grid.coord(cell) - World.grid.coord(World.keep_cell))
	var shield := _shield_at(delta.angle())
	if shield == null:
		return false
	_threat_serial += 1
	var deterministic := absf(sin(float(_threat_serial * 37 + cell * 13 + world_seed)))
	if deterministic < HEART_BASELINE_THREAT:
		return false
	shield.pressure += cost * (1.0 + global_corruption)
	Events.realm_changed.emit()
	return true


func can_assault() -> Dictionary:
	if complete:
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_HEART_BROKEN")}
	if not ring_closed():
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_RING_OPEN")}
	if Divine.faith < ASSAULT_FAITH:
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_FAITH", [int(ASSAULT_FAITH)])}
	for kind: StringName in ASSAULT_COST:
		if Colony.available(kind) < int(ASSAULT_COST[kind]):
			return {"ok": false, "reason": L10n.t(&"REALM_REASON_ASSAULT_RESOURCE",
				[L10n.resource(kind)])}
	return {"ok": true, "reason": ""}


func assault_blight_heart() -> bool:
	var check := can_assault()
	if not bool(check["ok"]):
		Events.notice.emit(String(check["reason"]), 1)
		return false
	for kind: StringName in ASSAULT_COST:
		Colony.spend({kind: int(ASSAULT_COST[kind])})
	Divine.faith -= ASSAULT_FAITH
	Events.faith_changed.emit(Divine.faith)
	blight_heart_health = maxi(blight_heart_health - ASSAULT_DAMAGE, 0)
	if blight_heart_health == 0:
		complete = true
		Events.realm_victory.emit()
	else:
		Events.notice.emit(L10n.t(&"REALM_NOTICE_HEART_CRACKS", [blight_heart_health]), 1)
	Events.realm_changed.emit()
	return true


func to_dict() -> Dictionary:
	capture_awake()
	var packed_colonies: Array = []
	for ledger: ColonyLedger in colonies.values():
		packed_colonies.append(ledger.to_dict())
	return {
		"format": 2,
		"world_seed": world_seed,
		"colonies": packed_colonies,
		"awake_id": String(awake_id),
		"heart_region_id": String(heart_region_id),
		"blight_core_id": String(blight_core_id),
		"global_corruption": global_corruption,
		"blight_heart_health": blight_heart_health,
		"complete": complete,
		"threat_serial": _threat_serial,
	}


func load_dict(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	var old_colonies: Array = data.get("colonies", []).duplicate(true)
	var old_awake := StringName(data.get("awake_id", ""))
	start_new(int(data.get("world_seed", 0)))
	if int(data.get("format", 1)) < 2:
		_migrate_legacy_colonies(old_colonies, old_awake)
	else:
		for packed: Dictionary in old_colonies:
			var ledger := ColonyLedger.from_dict(packed)
			if not sites.has(ledger.id):
				continue
			var row: Dictionary = sites[ledger.id]
			ledger.realm_position = Vector2(row["coord"])
			ledger.connections.assign(row["connections"])
			colonies[ledger.id] = ledger
		awake_id = StringName(data.get("awake_id", ""))
		heart_region_id = StringName(data.get("heart_region_id", ""))
		if heart_region_id == &"":
			for ledger: ColonyLedger in colonies.values():
				if ledger.is_heart:
					heart_region_id = ledger.id
					break
	global_corruption = float(data.get("global_corruption", global_corruption))
	blight_heart_health = int(data.get("blight_heart_health", BLIGHT_HEART_MAX))
	complete = bool(data.get("complete", false))
	_threat_serial = int(data.get("threat_serial", 0))
	Events.realm_changed.emit()
	return colonies.has(awake_id)


func _migrate_legacy_colonies(packed_colonies: Array, old_awake: StringName) -> void:
	if packed_colonies.is_empty():
		return
	var placements := _migration_placements(packed_colonies.size())
	var remap := {}
	for i in mini(packed_colonies.size(), placements.size()):
		var ledger := ColonyLedger.from_dict(packed_colonies[i])
		var old_id := ledger.id
		var id: StringName = placements[i]
		var row: Dictionary = sites[id]
		ledger.id = id
		ledger.display_name = String(row["name"])
		ledger.realm_position = Vector2(row["coord"])
		ledger.connections.assign(row["connections"])
		colonies[id] = ledger
		remap[old_id] = id
		if ledger.is_heart:
			heart_region_id = id
	if heart_region_id == &"" and not placements.is_empty():
		heart_region_id = placements[0]
		(colonies[heart_region_id] as ColonyLedger).is_heart = true
	awake_id = remap.get(old_awake, heart_region_id)


func _migration_placements(wanted: int) -> Array[StringName]:
	var out: Array[StringName] = []
	var start := suggested_first_region()
	if start == &"":
		return out
	var queue: Array[StringName] = [start]
	var seen := {start: true}
	while not queue.is_empty() and out.size() < wanted:
		var id: StringName = queue.pop_front()
		out.append(id)
		var coord: Vector2i = sites[id]["coord"]
		for offset in [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]:
			var row := site_at(coord + offset)
			if row.is_empty() or not bool(row.get("settleable", false)):
				continue
			var other := StringName(row["id"])
			if not seen.has(other):
				seen[other] = true
				queue.append(other)
	return out
