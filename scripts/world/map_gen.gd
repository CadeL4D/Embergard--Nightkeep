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
const NEST_COUNT := 4
const MIN_RESOURCE_REGION := 8

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
static func generate(grid: Grid, seed_value: int, keep_override: int = -1) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var res := Result.new()
	res.terrain = PackedByteArray()
	res.terrain.resize(grid.cell_count)
	res.feature = PackedByteArray()
	res.feature.resize(grid.cell_count)

	_fill_terrain(grid, res, seed_value)
	# Score a site even when one was handed to us, so the rng advances identically either
	# way. Skipping the call would give the same seed two different feature scatters
	# depending on whether the player picked, and the save format assumes it cannot.
	var scored := _choose_keep(grid, res, rng)
	res.keep_cell = keep_override if grid.is_valid_index(keep_override) else scored
	_flatten_keep(grid, res, res.keep_cell)
	_scatter_features(grid, res, seed_value, rng)
	res.nest_cells = _place_nests(grid, res, rng)
	_clear_around_keep(grid, res, res.keep_cell)
	_prune_isolated_resources(grid, res)
	_prune_small_resource_regions(grid, res)
	return res


# --- Terrain -------------------------------------------------------------------------

static func _fill_terrain(grid: Grid, res: Result, seed_value: int) -> void:
	var elevation := FastNoiseLite.new()
	elevation.seed = seed_value
	elevation.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	elevation.frequency = 0.018
	elevation.fractal_octaves = 4

	var moisture := FastNoiseLite.new()
	moisture.seed = seed_value + 7919
	moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	moisture.frequency = 0.03

	# Radial falloff pushes the map edges toward water so the playfield reads as an
	# island. It also gives monsters clean approach lanes instead of a hard border.
	var cx := grid.width * 0.5
	var cy := grid.height * 0.5
	var max_r := minf(cx, cy)

	for y in grid.height:
		for x in grid.width:
			var e := (elevation.get_noise_2d(x, y) + 1.0) * 0.5
			var m := (moisture.get_noise_2d(x, y) + 1.0) * 0.5
			var r := Vector2(x - cx, y - cy).length() / max_r
			e -= smoothstep(0.62, 1.0, r) * 0.55

			var t: int
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

static func _scatter_features(grid: Grid, res: Result, seed_value: int, rng: RandomNumberGenerator) -> void:
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

	for i in grid.cell_count:
		var t := res.terrain[i]
		var c := grid.coord(i)
		var n := (clump.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		# Two densities per clump rather than one, so a wood has a SOLID CORE and a ragged fringe.
		#
		# The old single test filled 55% of a clump, which is close to the worst possible number:
		# too dense to look scattered and far too sparse for any cell to have all four neighbours
		# wooded, so the renderer's dense-interior tile would essentially never have been used and a
		# forest stayed a lattice of separate trees. A near-solid core plus a thin fringe gives the
		# eye a mass to read and the player something to cut into — see WorldView._paint_feature.
		match t:
			Terrain.Type.GRASS:
				if n > 0.66:
					if rng.randf() < 0.98:
						res.feature[i] = Terrain.Feature.TREE
				elif n > 0.56:
					if rng.randf() < 0.62:
						res.feature[i] = Terrain.Feature.TREE
				# Raised from 0.012. Berries are the only food on the map before a farm
				# exists, and at just over one percent of grass tiles the opening of every
				# run was the same scramble regardless of where the player settled.
				elif rng.randf() < 0.035:
					res.feature[i] = Terrain.Feature.BERRIES
			Terrain.Type.ROCK:
				if n > 0.60:
					if rng.randf() < 0.96:
						res.feature[i] = Terrain.Feature.STONE
				elif n > 0.49:
					if rng.randf() < 0.55:
						res.feature[i] = Terrain.Feature.STONE
			Terrain.Type.DIRT:
				if n > 0.64 and rng.randf() < 0.55:
					res.feature[i] = Terrain.Feature.TREE
			Terrain.Type.RUBBLE:
				if rng.randf() < 0.3:
					res.feature[i] = Terrain.Feature.RUIN_WALL

	_consolidate_resource_masses(grid, res)


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


## Clearing the keep can cut a fringe cell away from the forest it belonged to.
## Prune once more afterward so the starting view does not regain a ring of sparse
## individual trees around an otherwise deliberate clearing.
static func _prune_isolated_resources(grid: Grid, res: Result) -> void:
	var before: PackedByteArray = res.feature.duplicate()
	for i in grid.cell_count:
		var feature := int(before[i])
		if feature != Terrain.Feature.TREE and feature != Terrain.Feature.STONE:
			continue
		if _matching_resource_neighbours(grid, before, i, feature) <= 1:
			res.feature[i] = Terrain.Feature.NONE


## The neighbour pass above removes dust but can leave diagonal chains whose cells
## are not actually connected for harvesting or rendering. Remove whole cardinal
## components below a small 8-cell grove so every starting forest/quarry reads as a grouped
## destination rather than a lone clover-shaped prop.
static func _prune_small_resource_regions(grid: Grid, res: Result) -> void:
	var visited := PackedByteArray()
	visited.resize(grid.cell_count)
	for start in grid.cell_count:
		if visited[start] != 0:
			continue
		var feature := int(res.feature[start])
		if feature != Terrain.Feature.TREE and feature != Terrain.Feature.STONE:
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
		if region.size() >= MIN_RESOURCE_REGION:
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
static func _place_nests(grid: Grid, res: Result, rng: RandomNumberGenerator) -> PackedInt32Array:
	var out := PackedInt32Array()
	var keep := grid.coord(res.keep_cell)
	var angle_step := TAU / float(NEST_COUNT)

	for n in NEST_COUNT:
		var base_angle := angle_step * n + rng.randf_range(-0.3, 0.3)
		var cell := -1

		# Try the ideal ring position first, jittering the distance.
		for _attempt in 24:
			var dist := rng.randf_range(NEST_MIN_DIST, NEST_MIN_DIST + NEST_DIST_SPAN)
			var x := keep.x + int(cos(base_angle) * dist)
			var y := keep.y + int(sin(base_angle) * dist)
			if not grid.is_valid(x, y):
				continue
			var i := grid.index(x, y)
			if _nest_site_ok(grid, res, i, keep):
				cell = i
				break

		# Fall back to the nearest acceptable site to the ideal point. Without this
		# an arm of the ring that happens to land in a lake silently drops its nest,
		# which quietly halves the Blight's spread rate and leaves one side of the
		# map with nothing to push back against.
		if cell == -1:
			var mid := NEST_MIN_DIST + NEST_DIST_SPAN * 0.5
			var tx := keep.x + int(cos(base_angle) * mid)
			var ty := keep.y + int(sin(base_angle) * mid)
			cell = _find_nest_site_near(grid, res, tx, ty, keep)

		if cell != -1:
			res.feature[cell] = Terrain.Feature.NEST
			out.append(cell)

	return out


static func _nest_site_ok(grid: Grid, res: Result, i: int, keep: Vector2i) -> bool:
	if not Terrain.WALKABLE.get(res.terrain[i], false):
		return false
	if res.feature[i] == Terrain.Feature.NEST:
		return false
	return grid.chebyshev(i, grid.index(keep.x, keep.y)) >= NEST_MIN_DIST - 6


## Spiral outward from a target point looking for a valid nest site. Rings are walked
## in a fixed order so the result stays deterministic for a given seed.
static func _find_nest_site_near(grid: Grid, res: Result, tx: int, ty: int, keep: Vector2i) -> int:
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
				if _nest_site_ok(grid, res, i, keep):
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
