extends Node
## Autoload: the seeded campaign world, its square regions, colony ledgers, and Blight Heart.
##
## The Realm is one continuous generated landscape. Each square on it is a complete local map;
## only one is awake at a time, while every other founded region advances from its own ledger.

const REGION_WIDTH := 9
const REGION_HEIGHT := 5
const REGION_COUNT := REGION_WIDTH * REGION_HEIGHT
const MACRO_PIXELS_PER_REGION := 32

const SETTLEMENT_COST := {&"wood": 30, &"stone": 15, &"food": 24}
const STARTING_CARGO := {&"wood": 10, &"stone": 5, &"food": 12}
const SETTLERS_REQUIRED := 2
const MIGRATION_ELIGIBLE_ADULTS := 16
const MIGRATION_PARTY_SIZE := 5
const RECOVERY_COST := {&"wood": 24, &"stone": 18, &"food": 18}
const RECOVERY_CARGO := {&"wood": 8, &"stone": 4, &"food": 12}
const RECOVERY_SETTLERS := 2
const HEART_BASELINE_THREAT := 0.18
const BLIGHT_HEART_MAX := 300
const ASSAULT_COST := {&"tools": 8, &"cut_stone": 16}
const ASSAULT_FAITH := 70.0
const ASSAULT_DAMAGE := 100
const HEART_REGROW_DAYS := 7
const HEART_MAX_GROWTH := 100

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

## Readout only: normalized mean corruption across settleable regions. Combat always asks
## `region_threat()` and therefore follows the local map or sleeping colony ledger.
var blight_heart_health: int = BLIGHT_HEART_MAX
var blight_heart_max_health: int = BLIGHT_HEART_MAX
var heart_shattered: bool = false
var heart_regrow_days_left: int = 0
var heart_shatter_count: int = 0
var macro_texture: ImageTexture
var _region_preview_cache: Dictionary = {}
var corruption_sources: Array[Vector2i] = []
var routes: Array[TradeRoute] = []
var region_states: Dictionary = {}   ## StringName -> RegionState
var pending_migrations: Array[MigrationOrder] = []
var selected_doctrines: Array[StringName] = []

var _threat_serial: int = 0
var _route_serial: int = 0
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
	_region_preview_cache.clear()
	Climate.reset(seed_value)
	Storyteller.reset(seed_value)
	sites.clear()
	colonies.clear()
	awake_id = &""
	heart_region_id = &""
	blight_core_id = &""
	global_corruption = 0.0
	blight_heart_health = BLIGHT_HEART_MAX
	blight_heart_max_health = BLIGHT_HEART_MAX
	heart_shattered = false
	heart_regrow_days_left = 0
	heart_shatter_count = 0
	_threat_serial = 0
	_route_serial = 0
	routes.clear()
	region_states.clear()
	pending_migrations.clear()
	selected_doctrines.clear()
	corruption_sources.clear()
	_configure_noise()
	_configure_continent()
	_build_regions()
	var campaign_errors := validate_campaign()
	if not campaign_errors.is_empty():
		push_error("Invalid Update 2d campaign graph: %s" % "; ".join(campaign_errors))
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
			var biome: StringName = _fixed_region_biome(x, y)
			var settleable := true
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
				"economic_identity": _regional_identity(biome),
				"food": sampled["food"],
				"corruption": 0.0,
				"settleable": settleable,
				"blight_core": false,
			}
			var state := RegionState.new()
			state.id = id
			state.display_name = String(sites[id]["name"])
			state.index = y * REGION_WIDTH + x
			state.coord = Vector2i(x, y)
			state.biome = biome
			state.local_seed = int(sites[id]["seed"])
			region_states[id] = state

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
		region_states[id].connections.assign(links)

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
	global_corruption = clampf(total_corruption / float(maxi(land_count, 1)), 0.0, 1.0)


func _fixed_region_biome(x: int, y: int) -> StringName:
	if y == 0:
		return &"desert"
	if y == REGION_HEIGHT - 1:
		return &"dry_lands"
	if x <= 1:
		return &"haven"
	if x >= REGION_WIDTH - 2:
		return &"marsh"
	if x in [3, 4, 5]:
		return &"forest"
	return &"outlands"


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


## High-resolution sample used by MapGen. Both views now ask the same landscape for the same
## world coordinate: the Realm map paints it coarsely and the playable square adds tile detail.
## Nothing here is random state, so previews, visits, and save restoration remain identical.
func local_landscape_at(region_coord: Vector2i, uv: Vector2) -> Dictionary:
	var rx := float(region_coord.x) + clampf(uv.x, 0.0, 1.0)
	var ry := float(region_coord.y) + clampf(uv.y, 0.0, 1.0)
	var sampled := _sample_landscape(rx, ry)
	var biome := _fixed_region_biome(region_coord.x, region_coord.y)
	sampled["biome"] = biome
	sampled["landness"] = maxf(float(sampled.get("landness", 0.0)), 0.2)
	var material := _macro_material(biome)
	var river_line := absf(_river.get_noise_2d(rx, ry))
	if biome not in [&"ocean", &"coast", &"highland"] \
			and float(sampled["moisture"]) > 0.46 and river_line < 0.014:
		material = 7
	elif material not in [0, 1]:
		material = _macro_resource_material(rx, ry, sampled, material)
	var macro_x := floori(rx * MACRO_PIXELS_PER_REGION)
	var macro_y := floori(ry * MACRO_PIXELS_PER_REGION)
	var berry_mark := 2 if _macro_is_berry_center(macro_x, macro_y, sampled) else 0
	if berry_mark == 0:
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				if ox == 0 and oy == 0:
					continue
				var px := macro_x + ox
				var py := macro_y + oy
				var neighbour := _sample_landscape(
					(float(px) + 0.5) / MACRO_PIXELS_PER_REGION,
					(float(py) + 0.5) / MACRO_PIXELS_PER_REGION)
				if _macro_is_berry_center(px, py, neighbour):
					berry_mark = 1
					break
			if berry_mark != 0:
				break
	sampled["material"] = material
	sampled["berry_mark"] = berry_mark
	return sampled


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
			var biome: StringName = _fixed_region_biome(floori(rx), floori(ry))
			sampled["biome"] = biome
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
		&"desert": return 6
		&"dry_lands": return 6
		&"haven": return 2
		&"outlands": return 5
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
	# Unsettled terrain is seed-stable. Reopening the same region should never run
	# map generation again under the player's finger.
	if _region_preview_cache.has(site_id) and colony(site_id) == null:
		return _region_preview_cache[site_id]
	var row: Dictionary = sites[site_id]
	if StringName(row.get("biome", &"ocean")) == &"ocean":
		var water_image := Image.create(World.MAP_WIDTH, World.MAP_HEIGHT, false,
			Image.FORMAT_RGBA8)
		for y in World.MAP_HEIGHT:
			for x in World.MAP_WIDTH:
				var wave := absi(x * 37 + y * 71 + int(row["seed"])) % 43
				water_image.set_pixel(x, y,
					Color("176681") if y % 6 == 0 and wave < 9 else Color("0a3d59"))
		var water_texture := ImageTexture.create_from_image(water_image)
		_region_preview_cache[site_id] = water_texture
		return water_texture
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
	var texture := ImageTexture.create_from_image(image)
	if ledger == null:
		_region_preview_cache[site_id] = texture
	return texture


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


func _regional_identity(biome: StringName) -> Dictionary:
	match biome:
		&"desert":
			return {"specialty": &"gold_ore", "demand": &"clean_water", "local_floor": &"stone"}
		&"dry_lands":
			return {"specialty": &"iron_ore", "demand": &"rations", "local_floor": &"stone"}
		&"haven":
			return {"specialty": &"food", "demand": &"crystal", "local_floor": &"wood"}
		&"outlands":
			return {"specialty": &"crystal", "demand": &"tools", "local_floor": &"wood"}
		&"coast":
			return {"specialty": &"food", "demand": &"cut_stone", "local_floor": &"wood"}
		&"forest":
			return {"specialty": &"wood", "demand": &"stone", "local_floor": &"food"}
		&"marsh":
			return {"specialty": &"herbs", "demand": &"boards", "local_floor": &"food"}
		&"highland":
			return {"specialty": &"ore", "demand": &"food", "local_floor": &"wood"}
		&"badlands":
			return {"specialty": &"emberglass", "demand": &"rations", "local_floor": &"stone"}
		&"tundra":
			return {"specialty": &"stone", "demand": &"rations", "local_floor": &"wood"}
		&"grassland":
			return {"specialty": &"food", "demand": &"ore", "local_floor": &"wood"}
	return {"specialty": &"", "demand": &"", "local_floor": &""}


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
	if region_states.has(site_id):
		var region: RegionState = region_states[site_id]
		region.status = RegionState.Status.SETTLED
		region.settlement_day = 1
		region.threat_modifier = 1.0
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


## The awake map owns its live containment value; sleeping regions own the value in their ledger.
## Unsettled regions do not inject a hidden combat modifier into another colony.
func region_threat(region_id: StringName) -> float:
	if region_id == awake_id and World.grid.cell_count > 0:
		return 0.0 if World.region_purified else Threat.pressure
	var ledger := colony(region_id)
	return 0.0 if ledger == null or ledger.purified else clampf(ledger.pressure, 0.0, 1.0)


func mark_awake_purified() -> void:
	var ledger := awake_ledger()
	if ledger == null:
		return
	ledger.purified = true
	ledger.pressure = 0.0
	ledger.corruption = 0.0
	if sites.has(ledger.id):
		var row: Dictionary = sites[ledger.id]
		row["corruption"] = 0.0
		sites[ledger.id] = row
	if region_states.has(ledger.id):
		region_states[ledger.id].status = RegionState.Status.PURIFIED
	_recompute_global_corruption()
	Events.realm_changed.emit()


func _recompute_global_corruption() -> void:
	var total := 0.0
	var count := 0
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		if not bool(row.get("settleable", false)):
			continue
		var local := float(row.get("corruption", 0.0))
		if colonies.has(id):
			local = (colonies[id] as ColonyLedger).corruption
		total += clampf(local, 0.0, 1.0)
		count += 1
	global_corruption = clampf(total / float(maxi(count, 1)), 0.0, 1.0)


func connected(from_id: StringName, to_id: StringName) -> bool:
	if not sites.has(from_id):
		return false
	return to_id in sites[from_id].get("connections", [])


func can_found(site_id: StringName) -> Dictionary:
	if not sites.has(site_id) or colonies.has(site_id) or _migration_targets(site_id):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_SETTLED")}
	if region_states.has(site_id) and region_states[site_id].status == RegionState.Status.LOST:
		return {"ok": false, "reason": tr(&"REALM_REASON_PERMANENT_LOSS")}
	if not bool(sites[site_id].get("settleable", false)):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_UNSETTLEABLE")}
	if bool(sites[site_id].get("blight_core", false)):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_CORE")}
	if not connected(awake_id, site_id):
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_NO_ROAD")}
	if not _has_migration_way_station():
		return {"ok": false, "reason": tr(&"REALM_REASON_WAY_STATION")}
	if eligible_migration_adults().size() < MIGRATION_ELIGIBLE_ADULTS:
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
	var order := MigrationOrder.new()
	_route_serial += 1
	order.order_id = _route_serial
	order.source_id = awake_id
	order.destination_id = site_id
	order.ordered_day = Sim.day
	order.departure_day = Sim.day + 1
	order.courier_golems = 2
	order.cargo = STARTING_CARGO.duplicate(true)
	var candidates := eligible_migration_adults()
	candidates.sort_custom(func(a: Villager, b: Villager) -> bool:
		return a.profile.stress < b.profile.stress)
	for i in mini(MIGRATION_PARTY_SIZE, candidates.size()):
		order.migrants.append(_migration_snapshot(candidates[i]))
	pending_migrations.append(order)
	Events.realm_changed.emit()
	return {"ok": true, "scheduled": true, "order": order,
		"reason": L10n.t(&"REALM_MIGRATION_SCHEDULED", [order.departure_day])}


func eligible_migration_adults() -> Array[Villager]:
	var out: Array[Villager] = []
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive and villager.is_adult() \
				and villager.health >= villager.max_health * 0.8 \
				and villager.profile.thermal_comfort >= 35.0 \
				and villager.profile.panic < 50.0 and villager.statuses.is_empty():
			out.append(villager)
	return out


func _has_migration_way_station() -> bool:
	for building in Colony.buildings:
		if is_instance_valid(building) and not building.is_site() and building.def.enables_migration:
			return true
	return false


func _migration_targets(site_id: StringName) -> bool:
	for order in pending_migrations:
		if order.status == &"scheduled" and order.destination_id == site_id:
			return true
	return false


func _migration_snapshot(villager: Villager) -> Dictionary:
	return {"x": villager.position.x, "y": villager.position.y, "job": villager.job,
		"food": villager.food, "water": villager.water, "rest": villager.rest,
		"mood": villager.mood, "health": villager.health,
		"carry_kind": villager.carry_kind, "carry_amount": villager.carry_amount,
		"pending_loads": villager.pending_loads.duplicate(true),
		"statuses": villager.statuses.duplicate(true), "record": villager.profile_dict()}


func _process_migrations(day_number: int) -> void:
	for order in pending_migrations:
		if order.status != &"scheduled" or order.departure_day > day_number:
			continue
		if order.source_id != awake_id or not Colony.can_afford(SETTLEMENT_COST):
			order.status = &"failed"
			continue
		var ids: Dictionary = {}
		for row: Dictionary in order.migrants:
			ids[String(row.get("record", {}).get("id", ""))] = true
		var departing: Array[Villager] = []
		for villager in Colony.villagers:
			if is_instance_valid(villager) and villager.alive \
					and ids.has(villager.profile.stable_id):
				departing.append(villager)
		if departing.size() != order.migrants.size():
			order.status = &"failed"
			continue
		Colony.spend(SETTLEMENT_COST)
		for villager in departing:
			villager.alive = false
			villager.queue_free()
		capture_awake()
		var row: Dictionary = sites[order.destination_id]
		var ledger := ColonyLedger.new()
		ledger.id = order.destination_id
		ledger.display_name = String(row["name"])
		ledger.seed_value = int(row["seed"])
		ledger.realm_position = Vector2(row["coord"])
		ledger.connections.assign(row["connections"])
		ledger.founded_day = day_number
		ledger.last_advanced_day = day_number
		ledger.corruption = float(row.get("corruption", 0.0)) * 0.65
		ledger.pressure = 0.0
		ledger.shield_integrity = 0.75
		colonies[ledger.id] = ledger
		if region_states.has(ledger.id):
			var region: RegionState = region_states[ledger.id]
			region.status = RegionState.Status.SETTLED
			# Every migrated colony opens on its own Day 1 even though the world calendar
			# continues. The reduced opening threat is durable campaign state, not a
			# transient UI promise.
			region.settlement_day = 1
			region.threat_modifier = 0.65
		order.status = &"departed"
		Meta.lifetime_stats["colonies_founded"] = int(Meta.lifetime_stats.get(
			"colonies_founded", 0)) + 1
		Events.migration_ready.emit(order, ledger)


func can_travel(target_id: StringName) -> bool:
	return target_id != awake_id and settled(target_id) and connected(awake_id, target_id)


func set_awake(target_id: StringName) -> void:
	awake_id = target_id
	var ledger := awake_ledger()
	if ledger != null:
		ledger.advance_to(Sim.day)
	Events.realm_changed.emit()
	Events.colony_awakened.emit(awake_id)


func active_routes() -> Array[TradeRoute]:
	var out: Array[TradeRoute] = []
	for route in routes:
		if route.active():
			out.append(route)
	return out


func set_doctrines(ids: Array) -> void:
	selected_doctrines = Doctrines.sanitize(ids)
	Events.realm_changed.emit()


func has_route_path(source_id: StringName, target_id: StringName) -> bool:
	return not _route_path(source_id, target_id).is_empty()


func route_forecast(source_id: StringName, target_id: StringName,
		cargo: Dictionary = {}, escort: int = 0, departure_day: int = -1) -> Dictionary:
	if source_id == target_id or not settled(source_id) or not settled(target_id):
		return {"ok": false, "reason": L10n.t(&"REALM_ROUTE_NEEDS_COLONIES")}
	var path := _route_path(source_id, target_id)
	if path.is_empty():
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_NO_ROAD")}
	var total := 0
	for raw_kind in cargo:
		var kind := StringName(raw_kind)
		if kind not in Colony.KINDS or int(cargo[raw_kind]) < 0:
			return {"ok": false, "reason": L10n.t(&"REALM_ROUTE_BAD_CARGO")}
		total += int(cargo[raw_kind])
	var depart := Sim.day if departure_day < 0 else maxi(departure_day, Sim.day)
	var travel_weight := 0.0
	var corruption_sum := 0.0
	var weather_penalty := 0.0
	var secured_steps := 0
	for i in range(1, path.size()):
		var id: StringName = path[i]
		var row: Dictionary = site(id)
		var biome := StringName(row.get("biome", Biomes.DEFAULT_ID))
		var terrain_penalty := 0.0
		if biome in [&"marsh", &"tundra"]:
			terrain_penalty = 0.38
		elif biome in [&"badlands", &"highland"]:
			terrain_penalty = 0.24
		var climate := Climate.daily_snapshot(world_seed, int(row.get("seed", 0)),
			depart, biome)
		var weather := StringName(climate.get("weather", &"clear"))
		var local_weather := 0.0
		if weather in [&"storm", &"snow"]:
			local_weather = 0.45
		elif weather in [&"fog", &"drought", &"heatwave"]:
			local_weather = 0.18
		weather_penalty += local_weather
		travel_weight += 0.72 + terrain_penalty + local_weather
		var local_corruption := float(row.get("corruption", 0.0))
		if colonies.has(id):
			local_corruption = (colonies[id] as ColonyLedger).corruption
			if not (colonies[id] as ColonyLedger).fallen:
				secured_steps += 1
		corruption_sum += local_corruption
	var edges := maxi(path.size() - 1, 1)
	var travel_days := maxi(ceili(travel_weight * Doctrines.modifier(&"route_speed")), 1)
	var risk := 0.025 + float(edges - 1) * 0.035 \
		+ corruption_sum / float(edges) * 0.36 \
		+ weather_penalty / float(edges) * 0.10 \
		- float(secured_steps) * 0.022 - float(maxi(escort, 0)) * 0.075
	risk = clampf(risk * Doctrines.modifier(&"route_risk"), 0.01, 0.85)
	var label := &"safe"
	if risk >= 0.5:
		label = &"dire"
	elif risk >= 0.28:
		label = &"risky"
	elif risk >= 0.12:
		label = &"guarded"
	return {
		"ok": true,
		"reason": "",
		"path": path,
		"distance": edges,
		"travel_days": travel_days,
		"departure_day": depart,
		"arrival_day": depart + travel_days,
		"risk": risk,
		"risk_label": label,
		"cargo_total": total,
	}


func schedule_route(source_id: StringName, target_id: StringName, cargo: Dictionary = {},
		settlers: Array[Dictionary] = [], escort: int = 0, cargo_policy: StringName = &"once",
		daily_amount: int = 0, capacity: int = 40, departure_day: int = -1) -> Dictionary:
	var forecast := route_forecast(source_id, target_id, cargo, escort, departure_day)
	if not bool(forecast.get("ok", false)):
		return forecast
	var total := int(forecast.get("cargo_total", 0))
	var effective_capacity := clampi(roundi(float(capacity + maxi(escort, 0) * 10) \
		* Doctrines.modifier(&"route_capacity")), 1, 100)
	if total > effective_capacity:
		return {"ok": false, "reason": L10n.t(&"REALM_ROUTE_CAPACITY", [effective_capacity])}
	if _dispatch_population(source_id) <= settlers.size():
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_SETTLERS")}
	if _dispatch_population(target_id) + settlers.size() > Difficulties.max_villagers():
		return {"ok": false, "reason": L10n.t(&"REALM_ROUTE_DESTINATION_FULL")}
	for raw_kind in cargo:
		var kind := StringName(raw_kind)
		if _dispatch_available(source_id, kind) < int(cargo[raw_kind]):
			return {"ok": false, "reason": L10n.t(&"REALM_REASON_RESOURCE",
				[L10n.resource(kind)])}
	_route_serial += 1
	var route := TradeRoute.new()
	route.route_id = _route_serial
	route.source_id = source_id
	route.destination_id = target_id
	route.path.assign(forecast["path"])
	route.cargo_policy = cargo_policy if cargo_policy in [&"once", &"maintain"] else &"once"
	route.cargo = cargo.duplicate(true)
	route.daily_amount = maxi(daily_amount, 0)
	route.capacity = effective_capacity
	route.escort = maxi(escort, 0)
	route.settlers = settlers.duplicate(true)
	route.departure_day = int(forecast["departure_day"])
	route.arrival_day = int(forecast["arrival_day"])
	route.risk = float(forecast["risk"])
	route.risk_label = StringName(forecast["risk_label"])
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ (route.route_id * 104729) ^ (route.departure_day * 8191) \
		^ source_id.hash() ^ (target_id.hash() * 31)
	route.outcome_roll = rng.randf()
	route.intercepted = route.outcome_roll < route.risk
	route.status = &"scheduled"
	routes.append(route)
	if route.departure_day <= Sim.day:
		_depart_route(route, Sim.day)
	_prune_route_history()
	Events.realm_changed.emit()
	Events.trade_route_updated.emit(route.route_id, route.status)
	return {"ok": route.status != &"failed", "reason": "", "route": route,
		"forecast": forecast}


func cancel_route(route_id: int) -> bool:
	for route in routes:
		if route.route_id == route_id and route.status == &"scheduled":
			route.status = &"cancelled"
			route.result = &"cancelled"
			Events.trade_route_updated.emit(route.route_id, route.status)
			Events.realm_changed.emit()
			return true
	return false


func transfer_resource(target_id: StringName, kind: StringName, amount: int) -> bool:
	if amount <= 0:
		return false
	return bool(schedule_route(awake_id, target_id, {kind: amount}).get("ok", false))


func transfer_migrant(target_id: StringName) -> bool:
	if Colony.population() <= 1:
		return false
	return bool(schedule_route(awake_id, target_id, {}, [{}]).get("ok", false))


func _route_path(source_id: StringName, target_id: StringName) -> Array[StringName]:
	var empty: Array[StringName] = []
	if not sites.has(source_id) or not sites.has(target_id):
		return empty
	var queue: Array[StringName] = [source_id]
	var came_from: Dictionary = {source_id: &""}
	while not queue.is_empty():
		var current: StringName = queue.pop_front()
		if current == target_id:
			break
		for raw_next in sites[current].get("connections", []):
			var next := StringName(raw_next)
			if came_from.has(next) or not bool(sites.get(next, {}).get("settleable", false)):
				continue
			came_from[next] = current
			queue.append(next)
	if not came_from.has(target_id):
		return empty
	var reverse: Array[StringName] = []
	var cursor := target_id
	while cursor != &"":
		reverse.append(cursor)
		cursor = StringName(came_from.get(cursor, &""))
	reverse.reverse()
	return reverse


func _dispatch_population(source_id: StringName) -> int:
	return Colony.population() if source_id == awake_id else \
		((colonies[source_id] as ColonyLedger).population() if colonies.has(source_id) else 0)


func _dispatch_available(source_id: StringName, kind: StringName) -> int:
	return Colony.available(kind) if source_id == awake_id else \
		((colonies[source_id] as ColonyLedger).available_resource(kind)
			if colonies.has(source_id) else 0)


func _depart_route(route: TradeRoute, day_number: int) -> bool:
	if route.status != &"scheduled" or not settled(route.source_id) \
			or not settled(route.destination_id):
		if route.status == &"scheduled":
			route.status = &"failed"
			route.result = &"colony_unavailable"
		return false
	for raw_kind in route.cargo:
		var kind := StringName(raw_kind)
		if _dispatch_available(route.source_id, kind) < int(route.cargo[raw_kind]):
			route.status = &"failed"
			route.result = &"insufficient_cargo"
			Events.trade_route_updated.emit(route.route_id, route.status)
			return false
	if _dispatch_population(route.source_id) <= route.settlers.size():
		route.status = &"failed"
		route.result = &"insufficient_settlers"
		Events.trade_route_updated.emit(route.route_id, route.status)
		return false

	if route.source_id == awake_id:
		if not route.cargo.is_empty() and not Colony.spend(route.cargo):
			route.status = &"failed"
			return false
		capture_awake()
	else:
		var source := colony(route.source_id)
		for raw_kind in route.cargo:
			var kind := StringName(raw_kind)
			if source.withdraw_resource(kind, int(route.cargo[raw_kind])) \
					!= int(route.cargo[raw_kind]):
				route.status = &"failed"
				route.result = &"dispatch_invariant"
				return false
	var settler_count := route.settlers.size()
	if settler_count > 0:
		route.settlers = _take_route_settlers(route.source_id, settler_count)
		if route.settlers.size() != settler_count:
			route.status = &"failed"
			route.result = &"settler_invariant"
			return false
	route.cargo_departed = true
	route.departure_day = day_number
	route.arrival_day = maxi(route.arrival_day, day_number + 1)
	route.status = &"in_transit"
	Events.trade_route_updated.emit(route.route_id, route.status)
	return true


func _take_route_settlers(source_id: StringName, count: int) -> Array[Dictionary]:
	var source := colony(source_id)
	if source == null:
		return []
	if source_id == awake_id:
		capture_awake()
	var rows: Array = source.state.get("villagers", []).duplicate(true)
	var picked: Array[Dictionary] = []
	# Adults leave before children, and stable roster order makes the choice save/load invariant.
	for adult_only in [true, false]:
		for i in range(rows.size() - 1, -1, -1):
			if picked.size() >= count:
				break
			var row: Dictionary = rows[i]
			var record: Dictionary = row.get("record", {})
			var is_adult := int(record.get("age_days", 6)) >= int(record.get("adult_age_days", 6))
			if adult_only != is_adult:
				continue
			picked.append(row)
			rows.remove_at(i)
		if picked.size() >= count:
			break
	source.state["villagers"] = rows
	_release_sleeping_partners(rows, picked)
	if source_id == awake_id:
		for row in picked:
			var stable_id := String(row.get("record", {}).get("id", ""))
			for live in Colony.villagers.duplicate():
				if is_instance_valid(live) and live.profile.stable_id == stable_id:
					Colony.release_household_partner(live)
					live.alive = false
					Sim.unregister(live)
					Colony.villagers.erase(live)
					live.queue_free()
					break
	return picked


func _release_sleeping_partners(rows: Array, departed: Array[Dictionary]) -> void:
	var departed_ids := {}
	for row in departed:
		departed_ids[String(row.get("record", {}).get("id", ""))] = true
	for row: Dictionary in rows:
		var record: Dictionary = row.get("record", {}).duplicate(true)
		if departed_ids.has(String(record.get("partner", ""))):
			record["partner"] = ""
			record["household"] = ""
			row["record"] = record


func _process_routes(day_number: int) -> void:
	for route in routes.duplicate():
		if route.status == &"scheduled" and route.departure_day <= day_number:
			_depart_route(route, day_number)
		if route.status == &"in_transit" and route.arrival_day <= day_number:
			_arrive_route(route, day_number)
	_prune_route_history()


func _arrive_route(route: TradeRoute, day_number: int) -> void:
	var repeat_cargo: Dictionary = route.cargo.duplicate(true)
	if not settled(route.destination_id):
		route.lost_cargo = route.cargo.duplicate(true)
		route.cargo.clear()
		route.status = &"lost"
		route.result = &"destination_fallen"
		Events.trade_route_updated.emit(route.route_id, route.status)
		return
	var delivered: Dictionary = route.cargo.duplicate(true)
	if route.intercepted:
		for raw_kind in delivered.keys():
			var amount := int(delivered[raw_kind])
			var lost := ceili(float(amount) * lerpf(0.25, 0.65,
				clampf(route.risk, 0.0, 0.85) / 0.85))
			lost = mini(lost, amount)
			delivered[raw_kind] = amount - lost
			route.lost_cargo[raw_kind] = lost
		for row: Dictionary in route.settlers:
			row["health"] = maxf(float(row.get("health", 100.0)) - 20.0, 1.0)
	var target := colony(route.destination_id)
	for raw_kind in delivered:
		var amount := int(delivered[raw_kind])
		if amount <= 0:
			continue
		if route.destination_id == awake_id:
			Colony.add(StringName(raw_kind), amount)
		else:
			target.deposit_resource(StringName(raw_kind), amount)
	_deliver_route_settlers(route, target)
	if route.destination_id == awake_id:
		capture_awake()
	route.cargo.clear()
	route.settlers.clear()
	route.status = &"arrived"
	route.result = &"intercepted" if route.intercepted else &"delivered"
	Events.trade_route_updated.emit(route.route_id, route.status)
	if route.destination_id == awake_id or route.source_id == awake_id:
		Events.notice.emit(L10n.t(
			&"REALM_ROUTE_ARRIVED_HURT" if route.intercepted else &"REALM_ROUTE_ARRIVED",
			[target.display_name]), 1 if route.intercepted else 0)
	if route.cargo_policy == &"maintain" and not repeat_cargo.is_empty():
		var maintained: Dictionary = {}
		for raw_kind in repeat_cargo:
			var amount := int(repeat_cargo[raw_kind])
			if route.daily_amount > 0:
				amount = mini(amount, route.daily_amount)
			maintained[StringName(raw_kind)] = amount
		schedule_route(route.source_id, route.destination_id, maintained, [], route.escort,
			&"maintain", route.daily_amount, route.capacity, day_number + 1)


func _deliver_route_settlers(route: TradeRoute, target: ColonyLedger) -> void:
	if route.settlers.is_empty():
		return
	var waiting: Array = target.state.get("waiting_settlers", []).duplicate(true)
	if route.destination_id == awake_id:
		for row: Dictionary in route.settlers:
			if not Colony.admit_route_settler(row):
				waiting.append(row)
	else:
		var rows: Array = target.state.get("villagers", []).duplicate(true)
		for row: Dictionary in route.settlers:
			if rows.size() >= Difficulties.max_villagers():
				waiting.append(row)
				continue
			if target.keep_cell != -1:
				var arrival := _ledger_world_position(target.keep_cell)
				row["x"] = arrival.x
				row["y"] = arrival.y
			rows.append(row)
		target.state["villagers"] = rows
	target.state["waiting_settlers"] = waiting


func _prune_route_history() -> void:
	if routes.size() <= 64:
		return
	for i in range(routes.size() - 1, -1, -1):
		if routes.size() <= 64:
			break
		if not routes[i].active():
			routes.remove_at(i)


func mark_awake_fallen() -> int:
	capture_awake()
	var ledger := awake_ledger()
	var refugees := 0
	if ledger != null:
		# A destroyed center can force an evacuation while people are still alive. They return to
		# the First Hearth as refugees; the ruined buildings and altered terrain remain behind.
		refugees = mini(ledger.population(), 4)
		ledger.fallen = true
		ledger.state["villagers"] = []
		ledger.state["refugees"] = int(ledger.state.get("refugees", 0)) + refugees
		ledger.state["fallen_day"] = Sim.day
		if region_states.has(ledger.id):
			region_states[ledger.id].status = RegionState.Status.LOST
	Events.realm_changed.emit()
	return refugees


func can_recover(site_id: StringName) -> Dictionary:
	var ledger := colony(site_id)
	if ledger == null or not ledger.fallen:
		return {"ok": false, "reason": tr(&"REALM_RECOVERY_NOT_RUIN")}
	return {"ok": false, "reason": tr(&"REALM_REASON_PERMANENT_LOSS")}
	# Legacy recovery code remains below for old test fixtures but is unreachable in schema 14.
	if site_id == heart_region_id:
		return {"ok": false, "reason": tr(&"REALM_RECOVERY_HEART")}
	if not connected(awake_id, site_id):
		return {"ok": false, "reason": tr(&"REALM_REASON_NO_ROAD")}
	if Colony.population() <= RECOVERY_SETTLERS:
		return {"ok": false, "reason": L10n.t(&"REALM_RECOVERY_NEED_SETTLERS",
			[RECOVERY_SETTLERS])}
	if not Colony.can_afford(RECOVERY_COST):
		return {"ok": false, "reason": tr(&"REALM_RECOVERY_NEED_SUPPLIES")}
	return {"ok": true, "reason": ""}


## Convert a fallen ledger into a playable recovery mission. Terrain, corruption, surviving
## structures, stockpile policies, and control zones remain exact; only a basic Hearth and the
## recovery party are guaranteed so the mission cannot load into an unwinnable empty scene.
func prepare_recovery(site_id: StringName) -> Dictionary:
	# Update 2d worlds have permanent regional loss. Keep this entry point so old UI and
	# external callers receive a stable answer instead of accidentally reviving a ledger.
	if region_states.has(site_id) and region_states[site_id].status == RegionState.Status.LOST:
		return {"ok": false, "reason": tr(&"REALM_REASON_PERMANENT_LOSS")}
	var check := can_recover(site_id)
	if not bool(check["ok"]):
		return check
	capture_awake()
	var source := awake_ledger()
	Colony.spend(RECOVERY_COST)
	capture_awake()
	source = awake_ledger()
	var source_rows: Array = source.state.get("villagers", [])
	var party: Array = []
	for _i in RECOVERY_SETTLERS:
		party.append(source_rows.pop_back())
	source.state["villagers"] = source_rows

	var ledger := colony(site_id)
	var arrival := _ledger_world_position(ledger.keep_cell)
	for row: Dictionary in party:
		row["x"] = arrival.x
		row["y"] = arrival.y
		row["food"] = maxf(float(row.get("food", 80.0)), 65.0)
		row["water"] = maxf(float(row.get("water", 80.0)), 65.0)
	ledger.state["villagers"] = party
	ledger.state["stock"] = RECOVERY_CARGO.duplicate(true)
	ledger.state["reserved"] = {}
	ledger.state["recovery_attempts"] = int(ledger.state.get("recovery_attempts", 0)) + 1
	ledger.state["refugees"] = 0
	_ensure_recovery_hearth(ledger)
	ledger.fallen = false
	ledger.shield_integrity = 0.45
	ledger.last_advanced_day = Sim.day
	Events.realm_changed.emit()
	return {"ok": true, "ledger": ledger}


func _ledger_world_position(cell: int) -> Vector2:
	var x := cell % World.MAP_WIDTH
	var y := cell / World.MAP_WIDTH
	return Vector2((float(x) + 0.5) * Grid.TILE_SIZE, (float(y) + 0.5) * Grid.TILE_SIZE)


func _ensure_recovery_hearth(ledger: ColonyLedger) -> void:
	var rows: Array = ledger.state.get("buildings", [])
	for row: Dictionary in rows:
		var def := Buildings.get_building(StringName(row.get("def", &"")))
		if def != null and def.center_tier > 0 and bool(row.get("complete", false)):
			return
	var keep_x := ledger.keep_cell % World.MAP_WIDTH
	var keep_y := ledger.keep_cell / World.MAP_WIDTH
	var anchor := (keep_y - 1) * World.MAP_WIDTH + (keep_x - 1)
	rows.append({
		"def": &"hearth",
		"anchor": anchor,
		"complete": true,
		"state": Building.State.COMPLETE,
		"work": 0.0,
		"hp": 220.0,
		"delivered": {},
		"salvage": {},
		"demolish_done": 0.0,
	})
	ledger.state["buildings"] = rows


func _on_day_advanced(day_number: int) -> void:
	_advance_heart_regrowth()
	_process_migrations(day_number)
	_process_routes(day_number)
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
	global_corruption = clampf(sum / float(maxi(count, 1)), 0.0, 1.0)
	Events.realm_changed.emit()


func _advance_heart_regrowth() -> void:
	if not heart_shattered:
		return
	heart_regrow_days_left = maxi(heart_regrow_days_left - 1, 0)
	if heart_regrow_days_left > 0:
		return
	heart_shattered = false
	blight_heart_max_health = BLIGHT_HEART_MAX + heart_shatter_count * HEART_MAX_GROWTH
	blight_heart_health = blight_heart_max_health
	Events.notice.emit(L10n.t(&"REALM_NOTICE_HEART_REGROWN", [blight_heart_max_health]), 2)


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
	shield.pressure += cost * (1.0 + 0.5 * clampf(region_threat(awake_id), 0.0, 1.0))
	Events.realm_changed.emit()
	return true


func can_assault() -> Dictionary:
	if heart_shattered:
		return {"ok": false, "reason": L10n.t(&"REALM_REASON_HEART_BROKEN",
			[heart_regrow_days_left])}
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
		heart_shattered = true
		heart_shatter_count += 1
		heart_regrow_days_left = HEART_REGROW_DAYS
		Threat.pressure = 0.0
		Threat.target_pressure = 0.0
		World.repel_blight(128)
		Events.heart_shattered.emit()
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
		"format": 5,
		"world_seed": world_seed,
		"colonies": packed_colonies,
		"awake_id": String(awake_id),
		"heart_region_id": String(heart_region_id),
		"blight_core_id": String(blight_core_id),
		"global_corruption": global_corruption,
		"blight_heart_health": blight_heart_health,
		"blight_heart_max_health": blight_heart_max_health,
		"heart_shattered": heart_shattered,
		"heart_regrow_days_left": heart_regrow_days_left,
		"heart_shatter_count": heart_shatter_count,
		"threat_serial": _threat_serial,
		"route_serial": _route_serial,
		"routes": routes.map(func(route: TradeRoute) -> Dictionary: return route.to_dict()),
		"regions": region_states.values().map(
			func(region: RegionState) -> Dictionary: return region.to_dict()),
		"migrations": pending_migrations.map(
			func(order: MigrationOrder) -> Dictionary: return order.to_dict()),
		"selected_doctrines": selected_doctrines.map(func(id: StringName) -> String: return String(id)),
	}


func load_dict(data: Dictionary) -> bool:
	if data.is_empty() or int(data.get("format", 0)) != 5:
		return false
	var old_colonies: Array = data.get("colonies", []).duplicate(true)
	start_new(int(data.get("world_seed", 0)))
	for packed_region: Dictionary in data.get("regions", []):
		var restored_region := RegionState.from_dict(packed_region)
		if region_states.has(restored_region.id):
			region_states[restored_region.id] = restored_region
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
	global_corruption = clampf(float(data.get("global_corruption", global_corruption)), 0.0, 1.0)
	blight_heart_health = int(data.get("blight_heart_health", BLIGHT_HEART_MAX))
	blight_heart_max_health = int(data.get("blight_heart_max_health", BLIGHT_HEART_MAX))
	heart_shattered = bool(data.get("heart_shattered", false))
	heart_regrow_days_left = int(data.get("heart_regrow_days_left", 0))
	heart_shatter_count = int(data.get("heart_shatter_count", 0))
	_threat_serial = int(data.get("threat_serial", 0))
	selected_doctrines = Doctrines.sanitize(data.get("selected_doctrines", []))
	_route_serial = int(data.get("route_serial", 0))
	routes.clear()
	for packed_route: Dictionary in data.get("routes", []):
		var route := TradeRoute.from_dict(packed_route)
		if colonies.has(route.source_id) and colonies.has(route.destination_id):
			routes.append(route)
			_route_serial = maxi(_route_serial, route.route_id)
	pending_migrations.clear()
	for packed_migration: Dictionary in data.get("migrations", []):
		var migration := MigrationOrder.from_dict(packed_migration)
		if sites.has(migration.source_id) and sites.has(migration.destination_id):
			pending_migrations.append(migration)
			_route_serial = maxi(_route_serial, migration.order_id)
	Events.realm_changed.emit()
	return colonies.has(awake_id)


## Doom World deletes only campaign/run state. Meta owns God XP, perks, completed goals and chest
## slots in a separate profile and is intentionally untouched.
func doom_world(typed_confirmation: String, next_seed: int = 0) -> bool:
	if typed_confirmation != "RESET":
		return false
	var replacement_seed := next_seed if next_seed != 0 else world_seed + 104729
	start_new(replacement_seed)
	return true


## Development and acceptance-test invariant for the fixed Update 2d campaign topology.
func validate_campaign() -> PackedStringArray:
	var errors := PackedStringArray()
	if sites.size() != REGION_COUNT or region_states.size() != REGION_COUNT:
		errors.append("expected %d regions; got %d sites and %d records" % [
			REGION_COUNT, sites.size(), region_states.size()])
	var biome_counts: Dictionary = {}
	for id: StringName in sites:
		var row: Dictionary = sites[id]
		var biome := StringName(row.get("biome", &""))
		biome_counts[biome] = int(biome_counts.get(biome, 0)) + 1
		if not region_states.has(id):
			errors.append("missing RegionState for %s" % id)
			continue
		for other: StringName in row.get("connections", []):
			if not sites.has(other) or id not in sites[other].get("connections", []):
				errors.append("asymmetric connection %s -> %s" % [id, other])
	for required: StringName in [&"forest", &"desert", &"marsh", &"dry_lands", &"haven", &"outlands"]:
		if int(biome_counts.get(required, 0)) == 0:
			errors.append("missing biome zone %s" % required)
	if not sites.is_empty():
		var start: StringName = sites.keys()[0]
		var visited: Dictionary = {start: true}
		var frontier: Array[StringName] = [start]
		while not frontier.is_empty():
			var current: StringName = frontier.pop_front()
			for raw_next in sites[current].get("connections", []):
				var next := StringName(raw_next)
				if not visited.has(next):
					visited[next] = true
					frontier.append(next)
		if visited.size() != REGION_COUNT:
			errors.append("campaign graph is disconnected (%d/%d reachable)" % [
				visited.size(), REGION_COUNT])
	return errors
