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

const KEEP_CLEAR_RADIUS := 7        ## tiles around the keep guaranteed flat and empty
const NEST_MIN_DIST := 34           ## nests never spawn closer than this to the keep
const NEST_COUNT := 4

class Result extends RefCounted:
	var terrain: PackedByteArray
	var feature: PackedByteArray
	var keep_cell: int = -1
	var nest_cells: PackedInt32Array = PackedInt32Array()


static func generate(grid: Grid, seed_value: int) -> Result:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var res := Result.new()
	res.terrain = PackedByteArray()
	res.terrain.resize(grid.cell_count)
	res.feature = PackedByteArray()
	res.feature.resize(grid.cell_count)

	_fill_terrain(grid, res, seed_value)
	res.keep_cell = _choose_keep(grid, res, rng)
	_flatten_keep(grid, res, res.keep_cell)
	_scatter_features(grid, res, seed_value, rng)
	res.nest_cells = _place_nests(grid, res, rng)
	_clear_around_keep(grid, res, res.keep_cell)
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


static func _flatten_keep(grid: Grid, res: Result, keep: int) -> void:
	var c := grid.coord(keep)
	for dy in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
		for dx in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
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
	clump.frequency = 0.06

	for i in grid.cell_count:
		var t := res.terrain[i]
		var c := grid.coord(i)
		var n := (clump.get_noise_2d(c.x, c.y) + 1.0) * 0.5
		match t:
			Terrain.Type.GRASS:
				if n > 0.58 and rng.randf() < 0.55:
					res.feature[i] = Terrain.Feature.TREE
				elif rng.randf() < 0.012:
					res.feature[i] = Terrain.Feature.BERRIES
			Terrain.Type.ROCK:
				if n > 0.5 and rng.randf() < 0.4:
					res.feature[i] = Terrain.Feature.STONE
			Terrain.Type.DIRT:
				if n > 0.72 and rng.randf() < 0.18:
					res.feature[i] = Terrain.Feature.TREE
			Terrain.Type.RUBBLE:
				if rng.randf() < 0.3:
					res.feature[i] = Terrain.Feature.RUIN_WALL


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
			var dist := rng.randf_range(NEST_MIN_DIST, NEST_MIN_DIST + 18.0)
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
			var mid := NEST_MIN_DIST + 9.0
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
static func _clear_around_keep(grid: Grid, res: Result, keep: int) -> void:
	var c := grid.coord(keep)
	for dy in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
		for dx in range(-KEEP_CLEAR_RADIUS, KEEP_CLEAR_RADIUS + 1):
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			if dx * dx + dy * dy > KEEP_CLEAR_RADIUS * KEEP_CLEAR_RADIUS:
				continue
			res.feature[grid.index(c.x + dx, c.y + dy)] = Terrain.Feature.NONE
