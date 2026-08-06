class_name MapGen
extends RefCounted
## Seeded procedural map generation. Stateless: hand it a Grid and a seed, get back
## filled terrain and feature arrays plus the chosen keep site and nest sites.
##
## Determinism is a hard requirement — the run save stores only the seed plus the
## deltas players caused, so the same seed MUST regenerate byte-identical arrays on
## any device. That means: one RandomNumberGenerator threaded through everything, no
## calls to the global rng, and no iteration over unordered containers.
##
## Generation order matters and is deliberate:
##   1. elevation/moisture noise -> terrain
##   2. carve a guaranteed-buildable plateau at the keep site
##   3. scatter features, biased by terrain
##   4. place nests in a ring, far enough out that day one is survivable
##   5. clear a safe radius around the keep

const KEEP_CLEAR_RADIUS := 7        ## tiles around the keep guaranteed empty of features
## Tiles around the keep guaranteed to be dry, buildable land.
##
## Smaller than KEEP_CLEAR_RADIUS on purpose. Flattening the full seven tiles converted
## every water cell in range to dirt, so a player who deliberately chose a lakeside site
## had the lake filled in underneath them — and once villagers need to drink, that turns
## the most attractive spot on the map into a death sentence.
##
## Five rather than three because the smoke test requires an 11x11 box around the keep to
## be almost entirely walkable ("the player spawns walled in by water and the run is
## unwinnable"), and five is exactly the radius that keeps that promise. Water from six
## tiles out survives, which is comfortably close enough for a shore or a well to matter.
const KEEP_PAD_RADIUS := 5
## Nests never spawn closer than this to the keep.
##
## 30 on a 112 map. Deliberately NOT the proportional equivalent of the old 34 on 128 (that would be
## 30 too, as it happens — but for the wrong reason). What this number actually controls is the
## horde's APPROACH TIME, which is the entire warning the player gets before a wave lands, and it is
## bounded from both sides: below ~28 the monsters arrive too fast to answer, above the island's land
## radius the ring falls in open water and every nest bunches onto the fallback position. See
## World.MAP_WIDTH for the arithmetic and for the two ways a 96 map broke.
##
## It is also the distance that decides how soon a forward Watchtower can reach a nest, which is the
## only way clearing one is achievable before Consecrate exists.
const NEST_MIN_DIST := 30

## How much further out than the minimum a nest may be jittered.
##
## Tightened from 18 with the smaller map: 30-48 would have put the far end of the range past the
## coastline of a 112 grid, where `_find_nest_site_near` fails and the fallback bunches every nest
## that missed onto the same mid-ring position.
const NEST_DIST_SPAN := 8.0
## One nest, not four.
##
## Four gave the map four independent corruption clocks and no single place to point at. The
## player could clear one and watch the ground keep turning anyway, so destroying a nest never
## felt like it accomplished anything and the Blight read as weather rather than as something
## with a source. One nest is a THING ON THE MAP: it can be found, walled off, pushed back from,
## and eventually assaulted, and every one of those is a decision about a place.
const NEST_COUNT := 1
const MIN_RESOURCE_REGION := 8
const MIN_BERRY_REGION := 4

class Result extends RefCounted:
	var terrain: PackedByteArray
	var feature: PackedByteArray
	var keep_cell: int = -1
	var nest_cells: PackedInt32Array = PackedInt32Array()


## Generate a map.
##
## `keep_override` lets the caller dictate the keep site instead of having one scored.
## The site picker uses this by generating once to show the player the land, then
## regenerating with their chosen cell — everything downstream of the keep (the flatten
## pad, the nest ring, the cleared start area) has to be rebuilt around it, and running
## generation twice is far simpler and less fragile than trying to unpick and redo those
## three passes in place. It stays perfectly deterministic because the result is a pure
## function of (seed, keep).
static func generate(grid: Grid, seed_value: int, keep_override: int = -1,
		region_profile: Dictionary = {}) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var res := Result.new()
	res.terrain = PackedByteArray()
	res.terrain.resize(grid.cell_count)
	res.feature = PackedByteArray()
	res.feature.resize(grid.cell_count)

	_fill_terrain(grid, res, seed_value, region_profile)
	# Score a site even when one was handed to us, so the rng advances identically either
	# way. Skipping the call would give the same seed two different feature scatters
	# depending on whether the player picked, and the save format assumes it cannot.
	var scored := _choose_keep(grid, res, rng)
	res.keep_cell = keep_override if grid.is_valid_index(keep_override) else scored
	_flatten_keep(grid, res, res.keep_cell)
	_scatter_features(grid, res, seed_value, rng, region_profile)
	res.nest_cells = _place_nests(grid, res, rng, region_profile)
	_clear_around_keep(grid, res, res.keep_cell)
	# Every playable local map gets a reachable quarry, including standalone and
	# developer maps that do not carry a Realm region profile.
	_ensure_starting_stone(grid, res)
	# The guaranteed starting quarry is added after the main feature scatter,
	# so perform the visual separation here, once every resource is final.
	_separate_berry_thickets(grid, res)
	_prune_isolated_resources(grid, res)
	_prune_small_resource_regions(grid, res)
	return res


## Regional scarcity should shape expansion, not soft-lock the first hours of a colony. Every
## settleable local map therefore receives one modest, reachable quarry near the Hearth. Rich
## highlands still contain vastly more; this is the handhold that lets any region reach them.
static func _ensure_starting_stone(grid: Grid, res: Result) -> void:
	const QUARRY_SHAPE: Array[Vector2i] = [
		Vector2i(-1, -3), Vector2i(0, -3), Vector2i(1, -3),
		Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2),
		Vector2i(1, -2), Vector2i(2, -2),
		Vector2i(-3, -1), Vector2i(-2, -1), Vector2i(-1, -1),
		Vector2i(0, -1), Vector2i(1, -1), Vector2i(2, -1),
		Vector2i(-3, 0), Vector2i(-2, 0), Vector2i(-1, 0),
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(-2, 1), Vector2i(-1, 1), Vector2i(0, 1),
		Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(-2, 2), Vector2i(-1, 2), Vector2i(0, 2), Vector2i(1, 2),
	]
	var keep := grid.coord(res.keep_cell)
	for radius in range(11, 24):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if absi(dx) != radius and absi(dy) != radius:
					continue
				var center := keep + Vector2i(dx, dy)
				if not grid.is_valid(center.x - 3, center.y - 3) \
						or not grid.is_valid(center.x + 3, center.y + 3):
					continue
				var usable := true
				for oy in range(-3, 4):
					for ox in range(-3, 4):
						var point := center + Vector2i(ox, oy)
						var cell := grid.index_v(point)
						if res.terrain[cell] in [Terrain.Type.WATER, Terrain.Type.DEEP_WATER] \
								or res.feature[cell] == Terrain.Feature.NEST:
							usable = false
							break
					if not usable:
						break
				if not usable:
					continue

				# Find a real terrain route before stamping. The old version only cleared the
				# quarry's apron; on a forest-heavy seed that left seven clear tiles completely
				# enclosed by trees, so the quarry existed visually but no quarrier could reach it.
				var route := _starting_resource_route(
					grid, res, res.keep_cell, grid.index_v(center), center)
				if route.is_empty():
					continue

				# Clear a one-tile apron and the route back to the already guaranteed Hearth
				# clearing. Widened by one cell so it reads as an intentional trail rather than
				# a pinhole through the canopy.
				for oy in range(-3, 4):
					for ox in range(-3, 4):
						res.feature[grid.index_v(center + Vector2i(ox, oy))] = Terrain.Feature.NONE
				for route_cell in route:
					for neighbour in grid.neighbours_8(route_cell):
						var nearby_feature := int(res.feature[neighbour])
						if nearby_feature in [Terrain.Feature.TREE, Terrain.Feature.BERRIES]:
							res.feature[neighbour] = Terrain.Feature.NONE
					var route_feature := int(res.feature[route_cell])
					if route_feature in [Terrain.Feature.TREE, Terrain.Feature.BERRIES]:
						res.feature[route_cell] = Terrain.Feature.NONE
				# A broad, asymmetric connected face rather than a rectangular
				# 4x5 stamp. It supplies more stone and gives the contour renderer
				# enough silhouette for one quarry to read as a landform.
				for offset in QUARRY_SHAPE:
					res.feature[grid.index_v(center + offset)] = Terrain.Feature.STONE
				return


## Cardinal route across ground the founding settlers can open. Trees and berries may be cleared;
## boulders, ruins, nests, and water must be routed around. The prospective quarry apron is treated
## as empty because it will be cleared immediately after this succeeds.
static func _starting_resource_route(grid: Grid, res: Result, start: int, goal: int,
		apron_center: Vector2i) -> PackedInt32Array:
	var parent := PackedInt32Array()
	parent.resize(grid.cell_count)
	parent.fill(-2)
	var queue := PackedInt32Array([start])
	parent[start] = -1
	var head := 0
	while head < queue.size():
		var cell := queue[head]
		head += 1
		if cell == goal:
			break
		for next in grid.neighbours_4(cell):
			if parent[next] != -2 or not Terrain.WALKABLE.get(res.terrain[next], false):
				continue
			var next_coord := grid.coord(next)
			var in_apron := absi(next_coord.x - apron_center.x) <= 3 \
				and absi(next_coord.y - apron_center.y) <= 3
			var feature := int(res.feature[next])
			if feature == Terrain.Feature.NEST:
				continue
			if not in_apron and Terrain.FEATURE_BLOCKS.get(feature, false) \
					and feature not in [Terrain.Feature.TREE, Terrain.Feature.BERRIES]:
				continue
			parent[next] = cell
			queue.append(next)

	if parent[goal] == -2:
		return PackedInt32Array()
	var reversed := PackedInt32Array()
	var at := goal
	while at != -1:
		reversed.append(at)
		at = parent[at]
	reversed.reverse()
	return reversed


# --- Terrain -------------------------------------------------------------------------

static func _fill_terrain(grid: Grid, res: Result, seed_value: int,
		region_profile: Dictionary = {}) -> void:
	var elevation := FastNoiseLite.new()
	elevation.seed = seed_value
	elevation.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	elevation.frequency = 0.018
	elevation.fractal_octaves = 4

	var moisture := FastNoiseLite.new()
	moisture.seed = seed_value + 7919
	moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	moisture.frequency = 0.03
	var hydrology := FastNoiseLite.new()
	hydrology.seed = seed_value + 22093
	hydrology.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hydrology.frequency = 0.042

	# Standalone/debug maps retain the old island falloff. Realm regions do not: they are one
	# window into a continuous continent, so their edges must join the neighbouring squares.
	var cx := grid.width * 0.5
	var cy := grid.height * 0.5
	var max_r := minf(cx, cy)
	var elevation_bias := 0.0
	var moisture_bias := 0.0
	var biome_id := StringName(region_profile.get("biome", Biomes.DEFAULT_ID))
	var has_macro_source := region_profile.has("coord") and Realm.world_seed != 0
	var region_coord: Vector2i = region_profile.get("coord", Vector2i.ZERO)
	if not region_profile.is_empty():
		elevation_bias = (float(region_profile.get("elevation", 0.5)) - 0.5) * 0.30
		moisture_bias = (float(region_profile.get("moisture", 0.5)) - 0.5) * 0.42
	match biome_id:
		&"coast":
			elevation_bias -= 0.055
			moisture_bias += 0.08
		&"forest":
			moisture_bias += 0.08
		&"marsh":
			elevation_bias -= 0.035
			moisture_bias += 0.15
		&"highland":
			elevation_bias += 0.10
			moisture_bias -= 0.04
		&"badlands":
			elevation_bias += 0.025
			moisture_bias -= 0.20
		&"tundra":
			elevation_bias += 0.035
			moisture_bias -= 0.08

	for y in grid.height:
		for x in grid.width:
			var e := (elevation.get_noise_2d(x, y) + 1.0) * 0.5 + elevation_bias
			var m := clampf((moisture.get_noise_2d(x, y) + 1.0) * 0.5 + moisture_bias,
				0.0, 1.0)
			var r := Vector2(x - cx, y - cy).length() / max_r
			if not has_macro_source:
				e -= smoothstep(0.62, 1.0, r) * 0.55
			var h := (hydrology.get_noise_2d(x, y) + 1.0) * 0.5

			var t: int
			var local := {}
			if has_macro_source:
				local = Realm.local_landscape_at(region_coord,
					Vector2((float(x) + 0.5) / float(grid.width),
						(float(y) + 0.5) / float(grid.height)))
				var material := int(local.get("material", 2))
				m = clampf(float(local.get("moisture", m)) * 0.72 + m * 0.28, 0.0, 1.0)
				match material:
					0:
						t = Terrain.Type.DEEP_WATER \
							if float(local.get("landness", -0.1)) < -0.055 else Terrain.Type.WATER
					1:
						t = Terrain.Type.SAND
					5, 9:
						t = Terrain.Type.ROCK if h < 0.82 else Terrain.Type.RUBBLE
					6:
						t = Terrain.Type.DIRT if h < 0.86 else Terrain.Type.RUBBLE
					7:
						t = Terrain.Type.WATER
					_:
						t = Terrain.Type.DIRT if m < 0.36 else Terrain.Type.GRASS
			else:
				if e < 0.22:
					t = Terrain.Type.DEEP_WATER
				elif e < 0.30:
					t = Terrain.Type.WATER
				elif e < 0.35:
					t = Terrain.Type.SAND
				elif e > 0.72:
					t = Terrain.Type.ROCK
				elif m < 0.38:
					t = Terrain.Type.DIRT
				else:
					t = Terrain.Type.GRASS
			# Each region keeps the shared tileset but arranges it differently. Broad ponds,
			# tidal cuts, scree and dry rubble make the biome readable before one resource is
			# harvested, while the keep flattening pass below still guarantees a safe opening.
			match biome_id:
				&"coast":
					if not has_macro_source and r > 0.38 and r < 0.82 \
							and absf(h - 0.50) < 0.030 \
							and t in [Terrain.Type.SAND, Terrain.Type.GRASS, Terrain.Type.DIRT]:
						t = Terrain.Type.WATER
				&"marsh":
					if r < 0.78 and h > 0.73 \
							and t in [Terrain.Type.GRASS, Terrain.Type.DIRT, Terrain.Type.SAND]:
						t = Terrain.Type.WATER
					elif t == Terrain.Type.GRASS and h < 0.38:
						t = Terrain.Type.DIRT
				&"highland":
					if t in [Terrain.Type.GRASS, Terrain.Type.DIRT] and h > 0.55:
						t = Terrain.Type.ROCK
					elif t == Terrain.Type.ROCK and h > 0.78:
						t = Terrain.Type.RUBBLE
				&"badlands":
					if t == Terrain.Type.GRASS:
						t = Terrain.Type.DIRT
					if t in [Terrain.Type.DIRT, Terrain.Type.ROCK] and h > 0.82:
						t = Terrain.Type.RUBBLE
				&"tundra":
					if t == Terrain.Type.GRASS and h < 0.48:
						t = Terrain.Type.DIRT
					elif t == Terrain.Type.GRASS and h > 0.76:
						t = Terrain.Type.ROCK
			res.terrain[grid.index(x, y)] = t


# --- Keep site -------------------------------------------------------------------------

## Pick the most buildable spot near the middle. Sampling candidates and scoring them
## beats "just use the centre", which lands the keep in a lake often enough to matter.
static func _choose_keep(grid: Grid, res: Result, rng: RandomNumberGenerator) -> int:
	var best := -1
	var best_score := -1
	var cx := grid.width / 2
	var cy := grid.height / 2
	for _attempt in 96:
		var x := cx + rng.randi_range(-grid.width / 6, grid.width / 6)
		var y := cy + rng.randi_range(-grid.height / 6, grid.height / 6)
		if not grid.is_valid(x, y):
			continue
		var score := _score_keep_site(grid, res, x, y)
		if score > best_score:
			best_score = score
			best = grid.index(x, y)
	return best if best != -1 else grid.index(cx, cy)


static func _score_keep_site(grid: Grid, res: Result, x: int, y: int) -> int:
	var score := 0
	for dy in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
		for dx in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
			var nx := x + dx
			var ny := y + dy
			if not grid.is_valid(nx, ny):
				score -= 4                      # penalise sites hanging off the map
				continue
			var t := res.terrain[grid.index(nx, ny)]
			if t == Terrain.Type.DEEP_WATER or t == Terrain.Type.WATER:
				score -= 3
			elif t == Terrain.Type.GRASS or t == Terrain.Type.DIRT:
				score += 2
			else:
				score += 1
	return score


## Guarantee dry ground immediately under the keep, and no further.
##
## Only KEEP_PAD_RADIUS, not KEEP_CLEAR_RADIUS: the promise this has to keep is "the
## Hearth can be placed here", not "there is no water anywhere nearby". Water in view
## of the colony is a feature, not a defect.
static func _flatten_keep(grid: Grid, res: Result, keep: int) -> void:
	var c := grid.coord(keep)
	for dy in range(-KEEP_PAD_RADIUS, KEEP_PAD_RADIUS + 1):
		for dx in range(-KEEP_PAD_RADIUS, KEEP_PAD_RADIUS + 1):
			var nx := c.x + dx
			var ny := c.y + dy
			if not grid.is_valid(nx, ny):
				continue
			var i := grid.index(nx, ny)
			if res.terrain[i] == Terrain.Type.DEEP_WATER or res.terrain[i] == Terrain.Type.WATER:
				res.terrain[i] = Terrain.Type.DIRT


# --- Features ---------------------------------------------------------------------------

static func _scatter_features(grid: Grid, res: Result, seed_value: int,
		rng: RandomNumberGenerator, region_profile: Dictionary = {}) -> void:
	# Noise-driven clumping rather than uniform random: forests and quarries should
	# read as places you travel TO, because that is what makes the Ember's position
	# and the spreading Blight matter.
	var clump := FastNoiseLite.new()
	clump.seed = seed_value + 31337
	clump.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# Lower frequency makes fewer, broader regions. The cleanup pass below then
	# removes isolated cells and closes small holes, producing actual destinations
	# rather than a uniform dusting of resources.
	clump.frequency = 0.045
	var berry_clump := FastNoiseLite.new()
	berry_clump.seed = seed_value + 7907
	berry_clump.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# Berries use a tighter field than forests and quarries. That creates small
	# forage thickets inside otherwise open grass instead of evenly scattered
	# single pickup points.
	berry_clump.frequency = 0.12
	var stone_clump := FastNoiseLite.new()
	stone_clump.seed = seed_value + 55217
	stone_clump.noise_type = FastNoiseLite.TYPE_SIMPLEX
	# Independent from the forest field so ordinary regions receive several
	# coherent outcrops rather than stone existing only where the terrain pass
	# happened to produce a rare rock tile.
	stone_clump.frequency = 0.052
	var forest_bias := 0.0
	var stone_bias := 0.0
	var food_bias := 0.0
	var biome_id := StringName(region_profile.get("biome", Biomes.DEFAULT_ID))
	var has_macro_source := region_profile.has("coord") and Realm.world_seed != 0
	var region_coord: Vector2i = region_profile.get("coord", Vector2i.ZERO)
	if not region_profile.is_empty():
		forest_bias = (float(region_profile.get("forest", 0.5)) - 0.5) * 0.24
		stone_bias = (float(region_profile.get("stone", 0.5)) - 0.5) * 0.24
		food_bias = (float(region_profile.get("food", 0.5)) - 0.5) * 0.04
	forest_bias += Biomes.richness_bonus(biome_id, &"forest") * 0.55
	stone_bias += Biomes.richness_bonus(biome_id, &"stone") * 0.55
	food_bias += Biomes.richness_bonus(biome_id, &"food") * 0.35

	for i in grid.cell_count:
		var t := res.terrain[i]
		var c := grid.coord(i)
		var n := (clump.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		var berry_n := (berry_clump.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		var macro := {}
		if has_macro_source:
			macro = Realm.local_landscape_at(region_coord,
				Vector2((float(c.x) + 0.5) / float(grid.width),
					(float(c.y) + 0.5) / float(grid.height)))
			var material := int(macro.get("material", 2))
			if material == 8 and t in [Terrain.Type.GRASS, Terrain.Type.DIRT]:
				if rng.randf() < (0.98 if n > 0.35 else 0.78):
					res.feature[i] = Terrain.Feature.TREE
				continue
			if material == 9 and t in [Terrain.Type.ROCK, Terrain.Type.RUBBLE]:
				if rng.randf() < (0.97 if n > 0.35 else 0.74):
					res.feature[i] = Terrain.Feature.STONE
				continue
			if int(macro.get("berry_mark", 0)) > 0 and t == Terrain.Type.GRASS:
				if rng.randf() < (0.48 if int(macro["berry_mark"]) == 2 else 0.16):
					res.feature[i] = Terrain.Feature.BERRIES
				continue
		# Two densities per clump rather than one, so a wood has a SOLID CORE and a ragged fringe.
		#
		# The old single test filled 55% of a clump, which is close to the worst possible number:
		# too dense to look scattered and far too sparse for any cell to have all four neighbours
		# wooded, so the renderer's dense-interior tile would essentially never have been used and a
		# forest stayed a lattice of separate trees. A near-solid core plus a thin fringe gives the
		# eye a mass to read and the player something to cut into — see WorldView._paint_feature.
		match t:
			Terrain.Type.GRASS:
				if n > 0.66 - forest_bias:
					if rng.randf() < 0.98:
						res.feature[i] = Terrain.Feature.TREE
				elif n > 0.56 - forest_bias:
					if rng.randf() < 0.62:
						res.feature[i] = Terrain.Feature.TREE
				else:
					# Keep exactly one shared-rng draw for every open grass
					# cell, matching the old scatterer's sequence. Berry
					# art must not quietly move quarries generated later.
					var berry_roll := rng.randf()
					# Two densities give each patch a packed center and a
					# ragged edge. Food-rich regions lower both thresholds.
					if berry_n > 0.72 - food_bias * 2.0:
						if berry_roll < 0.68:
							res.feature[i] = Terrain.Feature.BERRIES
					elif berry_n > 0.67 - food_bias * 2.0:
						if berry_roll < 0.20:
							res.feature[i] = Terrain.Feature.BERRIES
			Terrain.Type.ROCK:
				if n > 0.60 - stone_bias:
					if rng.randf() < 0.96:
						res.feature[i] = Terrain.Feature.STONE
				elif n > 0.49 - stone_bias:
					if rng.randf() < 0.55:
						res.feature[i] = Terrain.Feature.STONE
			Terrain.Type.DIRT:
				if n > 0.64 - forest_bias and rng.randf() < 0.55:
					res.feature[i] = Terrain.Feature.TREE
			Terrain.Type.RUBBLE:
				if rng.randf() < 0.3:
					res.feature[i] = Terrain.Feature.RUIN_WALL

	_seed_secondary_stone_masses(grid, res, stone_clump, stone_bias)
	_consolidate_resource_masses(grid, res)
	_consolidate_berry_thickets(grid, res)


## Add a restrained second layer of connected stone across otherwise open land.
##
## Terrain ROCK still carries the richest quarries, but tying every mineable cell
## to that terrain made lowland and forest regions contain only the emergency
## starting deposit. A separate low-frequency field produces a few broad outcrops
## throughout the map while preserving biome richness and leaving existing forests,
## berries, ruins, and water untouched.
static func _seed_secondary_stone_masses(
		grid: Grid, res: Result, stone_clump: FastNoiseLite, stone_bias: float
	) -> void:
	var regional_shift := clampf(stone_bias * 0.45, -0.04, 0.07)
	for cell in grid.cell_count:
		if int(res.feature[cell]) != Terrain.Feature.NONE:
			continue
		var threshold := 1.0
		match int(res.terrain[cell]):
			Terrain.Type.ROCK:
				threshold = 0.61
			Terrain.Type.DIRT:
				threshold = 0.69
			Terrain.Type.GRASS:
				threshold = 0.72
			Terrain.Type.SAND:
				threshold = 0.76
			_:
				continue
		var c := grid.coord(cell)
		var value := (stone_clump.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		# A tiny stable threshold wobble roughens the level-set boundary without
		# consuming the shared RNG that determines nests and other gameplay.
		var hash := absi(
			c.x * 73856093 ^ c.y * 19349663 ^ 55217
		)
		var edge_wobble := (float(hash % 1024) / 1023.0 - 0.5) * 0.035
		if value > threshold - regional_shift + edge_wobble:
			res.feature[cell] = Terrain.Feature.STONE


## Remove one-off resource props and close small gaps inside a mass. This is a
## deterministic cellular pass over a snapshot, so iteration order cannot change
## the generated map and saves still regenerate byte-identically.
static func _consolidate_resource_masses(grid: Grid, res: Result) -> void:
	var before: PackedByteArray = res.feature.duplicate()
	for i in grid.cell_count:
		var feature := int(before[i])
		if feature == Terrain.Feature.TREE or feature == Terrain.Feature.STONE:
			if _matching_resource_neighbours(grid, before, i, feature) <= 1:
				res.feature[i] = Terrain.Feature.NONE
			continue
		if feature != Terrain.Feature.NONE:
			continue

		var target := Terrain.Feature.NONE
		match res.terrain[i]:
			Terrain.Type.GRASS, Terrain.Type.DIRT:
				target = Terrain.Feature.TREE
			Terrain.Type.ROCK:
				target = Terrain.Feature.STONE
		if target != Terrain.Feature.NONE \
				and _matching_resource_neighbours(grid, before, i, target) >= 5:
			res.feature[i] = target


## Close small holes in a berry patch and discard its stray fringe cells. This
## uses a snapshot so the result is independent of grid iteration order.
static func _consolidate_berry_thickets(grid: Grid, res: Result) -> void:
	var before: PackedByteArray = res.feature.duplicate()
	for i in grid.cell_count:
		var feature := int(before[i])
		var berry_neighbours := _matching_resource_neighbours(
			grid, before, i, Terrain.Feature.BERRIES
		)
		if feature == Terrain.Feature.BERRIES:
			if berry_neighbours <= 1:
				res.feature[i] = Terrain.Feature.NONE
			continue
		if feature == Terrain.Feature.NONE \
				and res.terrain[i] == Terrain.Type.GRASS \
				and berry_neighbours >= 5:
			res.feature[i] = Terrain.Feature.BERRIES


## Keep low berry crowns from visually sitting on top of a forest wall or quarry
## ledge. The empty cell is also useful gameplay language: blocking resources are
## destinations, while walkable forage patches occupy their nearby clearings.
static func _separate_berry_thickets(grid: Grid, res: Result) -> void:
	var before: PackedByteArray = res.feature.duplicate()
	for i in grid.cell_count:
		if int(before[i]) != Terrain.Feature.BERRIES:
			continue
		for neighbor in grid.neighbours_8(i):
			var nearby := int(before[neighbor])
			if nearby == Terrain.Feature.TREE or nearby == Terrain.Feature.STONE:
				res.feature[i] = Terrain.Feature.NONE
				break


## Clearing the keep can cut a fringe cell away from the forest it belonged to.
## Prune once more afterward so the starting view does not regain a ring of sparse
## individual trees around an otherwise deliberate clearing.
static func _prune_isolated_resources(grid: Grid, res: Result) -> void:
	var before: PackedByteArray = res.feature.duplicate()
	for i in grid.cell_count:
		var feature := int(before[i])
		if feature != Terrain.Feature.TREE \
				and feature != Terrain.Feature.STONE \
				and feature != Terrain.Feature.BERRIES:
			continue
		if _matching_resource_neighbours(grid, before, i, feature) <= 1:
			res.feature[i] = Terrain.Feature.NONE


## The neighbour pass above removes dust but can leave diagonal chains whose cells
## are not actually connected for harvesting or rendering. Remove whole cardinal
## components below their minimum useful size so every forest, quarry, and berry
## thicket reads as a grouped destination rather than a lone prop.
static func _prune_small_resource_regions(grid: Grid, res: Result) -> void:
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for start in grid.cell_count:
		if visited[start] != 0:
			continue
		var feature := int(res.feature[start])
		if feature != Terrain.Feature.TREE \
				and feature != Terrain.Feature.STONE \
				and feature != Terrain.Feature.BERRIES:
			continue
		var region := PackedInt32Array()
		var queue := PackedInt32Array([start])
		visited[start] = 1
		var head := 0
		while head < queue.size():
			var cell := queue[head]
			head += 1
			region.append(cell)
			for neighbor in grid.neighbours_4(cell):
				if visited[neighbor] == 0 and int(res.feature[neighbor]) == feature:
					visited[neighbor] = 1
					queue.append(neighbor)
		var minimum_size := MIN_BERRY_REGION \
			if feature == Terrain.Feature.BERRIES else MIN_RESOURCE_REGION
		if region.size() >= minimum_size:
			continue
		for cell in region:
			res.feature[cell] = Terrain.Feature.NONE


static func _matching_resource_neighbours(
		grid: Grid, features: PackedByteArray, cell: int, target: int
	) -> int:
	var c := grid.coord(cell)
	var matches := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n := c + Vector2i(dx, dy)
			if grid.is_valid_v(n) and features[grid.index_v(n)] == target:
				matches += 1
	return matches


# --- Nests ------------------------------------------------------------------------------

## Nests ring the keep at distance. They are the blight's spread origins and the
## reason the player must eventually go on the offensive. Spread by angle so waves
## never all arrive from one side.
static func _place_nests(grid: Grid, res: Result, rng: RandomNumberGenerator,
		region_profile: Dictionary = {}) -> PackedInt32Array:
	var out := PackedInt32Array()
	var keep := grid.coord(res.keep_cell)
	var biome_id := StringName(region_profile.get("biome", Biomes.DEFAULT_ID))
	# Every region has one campaign Core. Biomes still vary its distance, terrain and
	# surrounding economy; they no longer silently replace it with three to five Cores.
	var nest_count := NEST_COUNT
	var nest_min := NEST_MIN_DIST if region_profile.is_empty() \
		else Biomes.nest_min_distance(biome_id)
	var nest_span := NEST_DIST_SPAN if region_profile.is_empty() \
		else Biomes.nest_distance_span(biome_id)
	var angle_step := TAU / float(nest_count)

	for n in nest_count:
		var base_angle := angle_step * n + rng.randf_range(-0.3, 0.3)
		var cell := -1

		# Try the ideal ring position first, jittering the distance.
		for _attempt in 24:
			var dist := rng.randf_range(nest_min, nest_min + nest_span)
			var x := keep.x + int(cos(base_angle) * dist)
			var y := keep.y + int(sin(base_angle) * dist)
			if not grid.is_valid(x, y):
				continue
			var i := grid.index(x, y)
			if _nest_site_ok(grid, res, i, keep, nest_min):
				cell = i
				break

		# Fall back to the nearest acceptable site to the ideal point. Without this
		# an arm of the ring that happens to land in a lake silently drops its nest,
		# which quietly halves the Blight's spread rate and leaves one side of the
		# map with nothing to push back against.
		if cell == -1:
			var mid := nest_min + nest_span * 0.5
			var tx := keep.x + int(cos(base_angle) * mid)
			var ty := keep.y + int(sin(base_angle) * mid)
			cell = _find_nest_site_near(grid, res, tx, ty, keep, nest_min)

		if cell != -1:
			res.feature[cell] = Terrain.Feature.NEST
			out.append(cell)

	return out


static func _nest_site_ok(grid: Grid, res: Result, i: int, keep: Vector2i,
		nest_min: int = NEST_MIN_DIST) -> bool:
	if not Terrain.WALKABLE.get(res.terrain[i], false):
		return false
	if res.feature[i] == Terrain.Feature.NEST:
		return false
	return grid.chebyshev(i, grid.index(keep.x, keep.y)) >= nest_min - 6


## Spiral outward from a target point looking for a valid nest site. Rings are walked
## in a fixed order so the result stays deterministic for a given seed.
static func _find_nest_site_near(grid: Grid, res: Result, tx: int, ty: int,
		keep: Vector2i, nest_min: int = NEST_MIN_DIST) -> int:
	for r in range(0, 30):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if r > 0 and absi(dx) != r and absi(dy) != r:
					continue
				var x := tx + dx
				var y := ty + dy
				if not grid.is_valid(x, y):
					continue
				var i := grid.index(x, y)
				if _nest_site_ok(grid, res, i, keep, nest_min):
					return i
	return -1


# --- Safe start --------------------------------------------------------------------------

## The player must be able to place their first buildings without fighting the map.
## Clear features from the immediate keep area, but leave a couple of trees just
## outside it so woodcutting has a target on day one.
##
## BERRIES are spared. They are the only food on the map before a farm exists, they do
## not block placement or movement, and they were previously deleted wholesale here —
## which quietly stripped the starting area of the one thing that makes day one
## survivable and made every run open with the same scramble.
static func _clear_around_keep(grid: Grid, res: Result, keep: int) -> void:
	var c := grid.coord(keep)
	for dy in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
		for dx in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			if dx * dx + dy * dy > KEEP_CLEAR_RADIUS * KEEP_CLEAR_RADIUS:
				continue
			var i := grid.index(c.x + dx, c.y + dy)
			if res.feature[i] == Terrain.Feature.BERRIES:
				continue
			res.feature[i] = Terrain.Feature.NONE
