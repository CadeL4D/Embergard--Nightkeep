extends Node
## Bakes the game's art from ArtData into PNG files under res://assets/.
##   Godot_v4.7-stable_win64_console.exe --headless --path <project> res://scenes/dev/bake_assets.tscn
##
## Run after editing ArtData. Output is committed like any other art, so the game
## loads plain textures and real TileSet/scene resources rather than building them
## at boot.
##
## Two kinds of art, made two different ways:
##   * Hand-drawn character maps (features, villagers, the Ember) are stamped
##     pixel-for-pixel — shape matters, so a human places every pixel.
##   * Ground tiles are generated from a tone ramp plus motif stamps, with all
##     placement wrapped modulo the tile size so they tile seamlessly. Hand-typing
##     256 pixels of convincing noise is worse than crafting the noise properly.

const TILESET_PATH := "res://assets/tilesets/terrain_atlas.png"
const VILLAGER_PATH := "res://assets/sprites/agents/villager.png"
const EMBER_PATH := "res://assets/sprites/fx/ember.png"
const LIGHT_PATH := "res://assets/sprites/fx/light_falloff.png"
const RING_PATH := "res://assets/sprites/fx/selection_ring.png"
const CARRY_PATH := "res://assets/sprites/fx/carry.png"

const CARRY_SIZE := 9

const LIGHT_SIZE := 256
const VILLAGER_W := 12
const VILLAGER_H := 14

var _failures: int = 0


# --- Ground recipes -----------------------------------------------------------------------
# base  : the dominant tone
# speck : {palette char -> how many pixels of it to scatter}
# motifs: small character maps stamped at random wrapped positions, N times each

const GROUND := {
	Terrain.Type.GRASS: {
		"base": "M",
		"speck": {"m": 16, "G": 12, "u": 3},
		"motifs": [{"map": [".g.", "mGm"], "count": 3}],
	},
	Terrain.Type.DIRT: {
		"base": "E",
		"speck": {"e": 18, "D": 12, "u": 2},
		"motifs": [{"map": ["De", "ee"], "count": 2}],
	},
	Terrain.Type.ROCK: {
		"base": "S",
		"speck": {"s": 18, "L": 10},
		"motifs": [{"map": ["s.", ".s", "s."], "count": 2}, {"map": ["LL"], "count": 2}],
	},
	Terrain.Type.SAND: {
		"base": "N",
		"speck": {"n": 16, "x": 10},
		"motifs": [{"map": ["xx"], "count": 3}],
	},
	Terrain.Type.WATER: {
		"base": "W",
		"speck": {"w": 12, "A": 9},
		"motifs": [{"map": ["AAA"], "count": 2}, {"map": ["ww"], "count": 2}],
	},
	Terrain.Type.DEEP_WATER: {
		"base": "w",
		"speck": {"W": 9, "k": 4},
		"motifs": [{"map": ["WW"], "count": 2}],
	},
	Terrain.Type.RUBBLE: {
		"base": "D",
		"speck": {"e": 14, "S": 9, "E": 9},
		"motifs": [{"map": ["SS", "sS"], "count": 3}, {"map": ["ee"], "count": 2}],
	},
}


# =========================================================================================
# CORRUPTED GROUND — the same materials after the Blight has taken them
# =========================================================================================
#
# Real tiles, not a wash. Corruption used to be drawn entirely by a shader over the top of
# clean terrain, which is why it read as something floating rather than as ground that had
# turned. These replace the tile outright once intensity passes TileAtlas.CORRUPT_THRESHOLD.
#
# Each one keeps a TRACE of what it used to be — a little sand in corrupted sand, dead
# stems in corrupted grass, stone chips in corrupted rock. That is what makes the boundary
# legible: the player can still tell which ground they lost, and rock still reads as
# harder going than soil. Painting one generic purple mud over everything would flatten
# the map's whole read.
#
# Only walkable materials appear here. Water cannot be blighted, so it has no corrupted form.

const CORRUPT_GROUND := {
	Terrain.Type.GRASS: {
		"base": "b",
		"speck": {"B": 34, "P": 9, "m": 10, "k": 6},
		# Filaments. Thin, branching, and wrapped by the baker so they tile seamlessly.
		"motifs": [{"map": ["P.", ".P", "P."], "count": 4}, {"map": ["BPB"], "count": 3}],
	},
	Terrain.Type.DIRT: {
		"base": "b",
		"speck": {"B": 30, "P": 8, "e": 12, "k": 5},
		"motifs": [{"map": [".P", "P."], "count": 5}, {"map": ["BB"], "count": 4}],
	},
	Terrain.Type.SAND: {
		"base": "b",
		"speck": {"B": 28, "P": 7, "n": 14, "x": 5},
		"motifs": [{"map": ["PP"], "count": 4}, {"map": ["B.", ".B"], "count": 4}],
	},
	Terrain.Type.ROCK: {
		# Darker base than the others: corrupted stone should still read as the hardest,
		# least inviting ground on the map.
		"base": "K",
		"speck": {"b": 32, "B": 20, "P": 6, "s": 12},
		"motifs": [{"map": ["Bs", "sB"], "count": 5}, {"map": ["P"], "count": 4}],
	},
	Terrain.Type.RUBBLE: {
		"base": "b",
		"speck": {"B": 26, "P": 8, "s": 12, "K": 8},
		"motifs": [{"map": ["sB", "Bs"], "count": 5}, {"map": ["PP"], "count": 3}],
	},
}


func _ready() -> void:
	_ensure_dirs()
	_bake_tileset()
	_bake_villager()
	_bake_carry_icons()
	_bake_monsters()
	_bake_blight_structures()
	_bake_buildings()
	_bake_ember()
	_bake_light_falloff()
	_bake_selection_ring()
	_bake_app_icons()
	_bake_preview()
	if _failures > 0:
		printerr("bake finished with %d problem(s)" % _failures)
		get_tree().quit(1)
		return
	print("bake complete")
	get_tree().quit(0)


func _ensure_dirs() -> void:
	for d: String in ["res://assets/tilesets", "res://assets/sprites/fx", "res://assets/sprites/agents"]:
		DirAccess.make_dir_recursive_absolute(d)


func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	if err != OK:
		printerr("failed to write %s (%d)" % [path, err])
		_failures += 1
	else:
		print("wrote %s %s" % [path, img.get_size()])


# --- Character-map stamping ------------------------------------------------------------------

## Validate a hand-drawn map is the size it claims to be. A miscounted row would
## otherwise silently shift every pixel after it, producing art that looks "nearly
## right" and is maddening to debug by eye.
func _check_map(name: String, map: Array, w: int, h: int) -> bool:
	if map.size() != h:
		printerr("%s: expected %d rows, got %d" % [name, h, map.size()])
		_failures += 1
		return false
	for i in map.size():
		var row: String = map[i]
		if row.length() != w:
			printerr("%s: row %d is %d chars, expected %d" % [name, i, row.length(), w])
			_failures += 1
			return false
	return true


## Draw a character map into `img` at an offset. Transparent characters are skipped
## rather than written, so sprites composite over whatever is already there.
func _stamp(img: Image, map: Array, ox: int, oy: int) -> void:
	for y in map.size():
		var row: String = map[y]
		for x in row.length():
			var c := ArtData.color_of(row[x])
			if c.a <= 0.0:
				continue
			var px := ox + x
			var py := oy + y
			if px >= 0 and py >= 0 and px < img.get_width() and py < img.get_height():
				img.set_pixel(px, py, c)


## A restrained one-pixel contact shadow gives tiny sprites a clear footprint
## against noisy ground. The scan runs backwards so pixels added as shadow never
## become new shadow sources, and region bounds prevent one animation frame from
## bleeding into the next frame in a strip.
func _add_sprite_shadow(img: Image, ox: int, oy: int, w: int, h: int) -> void:
	var shadow := Color(0.02, 0.027, 0.038, 0.58)
	for y in range(oy + h - 2, oy - 1, -1):
		for x in range(ox + w - 2, ox - 1, -1):
			if img.get_pixel(x, y).a <= 0.0:
				continue
			var dx := x + 1
			var dy := y + 1
			if dx < ox + w and dy < oy + h and img.get_pixel(dx, dy).a <= 0.0:
				img.set_pixel(dx, dy, shadow)


# --- Tileset ------------------------------------------------------------------------------

func _bake_tileset() -> void:
	var img := Image.create(
		TileAtlas.COLUMNS * TileAtlas.TILE,
		TileAtlas.ROWS * TileAtlas.TILE,
		false, Image.FORMAT_RGBA8
	)
	img.fill(Color(0, 0, 0, 0))

	# Fixed seed: re-baking must not churn the PNG in version control.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260728

	# Each material gets VARIANTS separately-noised tiles. They share a recipe, so
	# they read as the same material, but no two are pixel-identical — which is
	# what stops a field of grass from showing an obvious repeating grid.
	for t: int in GROUND:
		for v in TileAtlas.VARIANTS:
			_paint_ground(img, TileAtlas.terrain_coords(t, v), GROUND[t], rng)

	# Corrupted forms of the same materials, in the mirrored rows below.
	for t: int in CORRUPT_GROUND:
		for v in TileAtlas.VARIANTS:
			_paint_ground(img, TileAtlas.corrupt_terrain_coords(t, v), CORRUPT_GROUND[t], rng)

	var variants: Dictionary = ArtData.feature_variants()
	for f: int in ArtData.feature_maps():
		# A feature either has a list of alternate silhouettes or just its one map.
		var maps: Array = variants.get(f, [ArtData.feature_maps()[f]])
		for v in maps.size():
			var map: Array = maps[v]
			if not _check_map("feature %d variant %d" % [f, v], map, TileAtlas.TILE, TileAtlas.TILE):
				continue
			var coords := TileAtlas.feature_coords(f, v)
			_stamp(img, map, coords.x * TileAtlas.TILE, coords.y * TileAtlas.TILE)

	# Connected resources get the full N/E/S/W shape set below.
	for f: int in TileAtlas.CONNECTED_FEATURE_ROWS:
		for variant in TileAtlas.connected_variant_count(f):
			for mask in 16:
				_paint_connected_feature(
					img, TileAtlas.connected_coords(f, mask, variant), f, mask, variant
				)

	# Sparse visual dressing. These are overlays with transparent backgrounds,
	# stamped by WorldView into a layer of their own and never read by the sim.
	var decor := ArtData.decor_maps()
	for i in decor.size():
		var map: Array = decor[i]
		if not _check_map("ground decor %d" % i, map, TileAtlas.TILE, TileAtlas.TILE):
			continue
		var coords := TileAtlas.decor_coords(i)
		_stamp(img, map, coords.x * TileAtlas.TILE, coords.y * TileAtlas.TILE)

	_save(img, TILESET_PATH)


## Fill a tile with the base tone, scatter speckles, then stamp motifs. Every
## placement is taken modulo the tile size so motifs that run off one edge reappear
## on the other — which is what makes the tile seamless when repeated.
func _paint_ground(img: Image, coords: Vector2i, recipe: Dictionary, rng: RandomNumberGenerator) -> void:
	var size := TileAtlas.TILE
	var ox := coords.x * size
	var oy := coords.y * size

	var base := ArtData.color_of(recipe["base"])
	for y in size:
		for x in size:
			img.set_pixel(ox + x, oy + y, base)

	var speck: Dictionary = recipe["speck"]
	for ch: String in speck:
		var color := ArtData.color_of(ch)
		for _i in int(speck[ch]):
			var x := rng.randi_range(0, size - 1)
			var y := rng.randi_range(0, size - 1)
			img.set_pixel(ox + x, oy + y, color)

	for motif: Dictionary in recipe.get("motifs", []):
		var map: Array = motif["map"]
		for _i in int(motif["count"]):
			var mx := rng.randi_range(0, size - 1)
			var my := rng.randi_range(0, size - 1)
			for ry in map.size():
				var row: String = map[ry]
				for rx in row.length():
					var c := ArtData.color_of(row[rx])
					if c.a <= 0.0:
						continue
					var px := ox + (mx + rx) % size
					var py := oy + (my + ry) % size
					img.set_pixel(px, py, c)


## Paint the full-tile surface and its full-bleed shared edges. The atlas keeps
## the coarse transparent silhouette needed for cell composition, while
## FeatureDetails owns the one region-wide visible rim; drawing both here and
## there produced a doubled, cable-like outline.
func _paint_connected_feature(
		img: Image, coords: Vector2i, feature: int, mask: int, variant: int
	) -> void:
	var size := TileAtlas.TILE
	var ox := coords.x * size
	var oy := coords.y * size

	for y in size:
		for x in size:
			if not _connected_shape_contains(x, y, mask, feature, variant):
				continue

			var ch := "V"
			match feature:
				Terrain.Feature.TREE:
					ch = _forest_surface_char(x, y, variant)
				Terrain.Feature.STONE:
					ch = _rock_surface_char(x, y, variant)
			img.set_pixel(ox + x, oy + y, ArtData.color_of(ch))


## Cardinally connected sides count as filled just outside the tile. This prevents
## a dark outline from reappearing along shared seams.
func _connected_shape_contains(
		x: int, y: int, mask: int, feature: int, variant: int
	) -> bool:
	if x < 0:
		return (mask & TileAtlas.MASK_WEST) != 0
	if x >= TileAtlas.TILE:
		return (mask & TileAtlas.MASK_EAST) != 0
	if y < 0:
		return (mask & TileAtlas.MASK_NORTH) != 0
	if y >= TileAtlas.TILE:
		return (mask & TileAtlas.MASK_SOUTH) != 0

	var left := 0 if (mask & TileAtlas.MASK_WEST) != 0 \
		else 1 + _edge_jitter(y, feature, variant, 1)
	var right := TileAtlas.TILE - 1 if (mask & TileAtlas.MASK_EAST) != 0 \
		else TileAtlas.TILE - 2 - _edge_jitter(y, feature, variant, 2)
	var top := 0 if (mask & TileAtlas.MASK_NORTH) != 0 \
		else 1 + _edge_jitter(x, feature, variant, 3)
	var bottom := TileAtlas.TILE - 1 if (mask & TileAtlas.MASK_SOUTH) != 0 \
		else TileAtlas.TILE - 2 - _edge_jitter(x, feature, variant, 4)
	if x < left or x > right or y < top or y > bottom:
		return false

	# A cardinal mask alone produces square outside corners. Test each exposed
	# corner against a pixel quarter-circle instead of cutting a straight diagonal;
	# the latter made pointed teeth where two independently profiled sides met.
	var radius := 5 if feature == Terrain.Feature.TREE else 4
	var far := TileAtlas.TILE - 1
	if (mask & TileAtlas.MASK_WEST) == 0 and (mask & TileAtlas.MASK_NORTH) == 0:
		if x < radius and y < radius \
				and (x - radius) ** 2 + (y - radius) ** 2 > radius ** 2:
			return false
	if (mask & TileAtlas.MASK_EAST) == 0 and (mask & TileAtlas.MASK_NORTH) == 0:
		var east_x_top := far - x
		if east_x_top < radius and y < radius \
				and (east_x_top - radius) ** 2 + (y - radius) ** 2 > radius ** 2:
			return false
	if (mask & TileAtlas.MASK_WEST) == 0 and (mask & TileAtlas.MASK_SOUTH) == 0:
		var south_y_left := far - y
		if x < radius and south_y_left < radius \
				and (x - radius) ** 2 + (south_y_left - radius) ** 2 > radius ** 2:
			return false
	if (mask & TileAtlas.MASK_EAST) == 0 and (mask & TileAtlas.MASK_SOUTH) == 0:
		var east_x_bottom := far - x
		var south_y_right := far - y
		if east_x_bottom < radius and south_y_right < radius \
				and (east_x_bottom - radius) ** 2 \
				+ (south_y_right - radius) ** 2 > radius ** 2:
			return false
	return true


func _edge_jitter(axis: int, feature: int, variant: int, side: int) -> int:
	# Interpolate between seeded anchors instead of cycling a short pixel table.
	# Each exposed side now has three or four broad changes across the full 16 px,
	# so it cannot reveal the old 8 px sine-wave repetition.
	var span := 5 if feature == Terrain.Feature.TREE else 6
	var segment := floori(float(axis) / float(span))
	var local := posmod(axis, span)
	var a := _edge_anchor(segment, feature, variant, side)
	var b := _edge_anchor(segment + 1, feature, variant, side)
	return roundi(lerpf(float(a), float(b), float(local) / float(span)))


func _edge_anchor(segment: int, feature: int, variant: int, side: int) -> int:
	var h := _feature_hash(segment + side * 17, variant + side * 7, feature + 83, side)
	if feature == Terrain.Feature.TREE:
		return [0, 0, 0, 1, 1, 1, 2, 2][h % 8]
	return [0, 0, 0, 1, 1, 2][h % 6]


func _forest_surface_char(x: int, y: int, variant: int) -> String:
	var mottle := _feature_hash(
		x >> 1, y >> 1, Terrain.Feature.TREE + 31, variant
	)
	if mottle % 59 == 0:
		return "J"
	if mottle % 19 == 0:
		return "j"
	return "V"


func _rock_surface_char(x: int, y: int, variant: int) -> String:
	var texture_hash := _feature_hash(x, y, Terrain.Feature.STONE, variant)
	if texture_hash % 61 == 0:
		return "q"
	if texture_hash % 53 == 0:
		return "H"
	return "Q"


func _feature_hash(x: int, y: int, feature: int, variant: int) -> int:
	var h := x * 73856093 ^ y * 19349663 ^ feature * 83492791 ^ variant * 2654437
	h ^= h >> 13
	h *= 1274126177
	h ^= h >> 16
	return absi(h)


# --- Villager sheet -------------------------------------------------------------------------

## Horizontal strip: down_0 down_1 up_0 up_1 side_0 side_1. The renderer flips the
## side frames for left-facing rather than storing a mirrored copy.
func _bake_villager() -> void:
	var frames := ArtData.villager_frames()
	var order: Array[String] = ["down_0", "down_1", "up_0", "up_1", "side_0", "side_1"]

	var img := Image.create(VILLAGER_W * order.size(), VILLAGER_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	for i in order.size():
		var key := order[i]
		var map: Array = frames[key]
		if not _check_map("villager %s" % key, map, VILLAGER_W, VILLAGER_H):
			continue
		_stamp(img, map, i * VILLAGER_W, 0)
		_add_sprite_shadow(img, i * VILLAGER_W, 0, VILLAGER_W, VILLAGER_H)

	_save(img, VILLAGER_PATH)


## Horizontal strip of carry icons, laid out in COLONY.KINDS ORDER. That ordering is
## the contract: the villager picks its frame with Colony.KINDS.find(kind), so adding a
## resource to that array and an icon to ArtData is all a new carryable takes — no
## lookup table to keep in step, and nothing branching on a resource id.
##
## A kind with no icon still gets a slot, left blank, rather than shifting every frame
## after it and silently mislabelling every haul in the game.
func _bake_carry_icons() -> void:
	var icons := ArtData.carry_frames()
	var kinds: Array[StringName] = Colony.KINDS

	var img := Image.create(CARRY_SIZE * kinds.size(), CARRY_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	for i in kinds.size():
		var kind := kinds[i]
		if not icons.has(kind):
			printerr("carry icon missing for %s — its slot will render blank" % kind)
			_failures += 1
			continue
		var map: Array = icons[kind]
		if not _check_map("carry %s" % kind, map, CARRY_SIZE, CARRY_SIZE):
			continue
		_stamp(img, map, i * CARRY_SIZE, 0)

	_save(img, CARRY_PATH)


## One horizontal 2-frame strip per monster. Monsters have no directional art —
## they are amorphous enough that a horizontal flip reads fine, and halving the
## frame count keeps the roster cheap to extend.
func _bake_monsters() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sprites/monsters")
	for id: StringName in ArtData.monster_frames():
		var frames: Array = ArtData.monster_frames()[id]
		var img := Image.create(VILLAGER_W * frames.size(), VILLAGER_H, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		var ok := true
		for i in frames.size():
			if not _check_map("monster %s frame %d" % [id, i], frames[i], VILLAGER_W, VILLAGER_H):
				ok = false
				continue
			_stamp(img, frames[i], i * VILLAGER_W, 0)
			_add_sprite_shadow(img, i * VILLAGER_W, 0, VILLAGER_W, VILLAGER_H)
		if ok:
			_save(img, "res://assets/sprites/monsters/%s.png" % id)


## The Blight's own structures. One PNG each, like the player's buildings and for the same reason:
## they are few, they are large, and atlasing them would cost authoring friction for no batching
## win. Sizes vary — the spire is 16x32 and the totem 16x24 — so each entry carries its own.
func _bake_blight_structures() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sprites/blight")
	for id: StringName in ArtData.blight_structure_maps():
		var entry: Dictionary = ArtData.blight_structure_maps()[id]
		var w: int = entry["w"]
		var h: int = entry["h"]
		if not _check_map("blight structure %s" % id, entry["map"], w, h):
			continue
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_stamp(img, entry["map"], 0, 0)
		_add_sprite_shadow(img, 0, 0, w, h)
		_save(img, "res://assets/sprites/blight/%s.png" % id)


## One PNG per building, named by id, so a BuildingDef .tres can point straight at
## its art without an atlas lookup. Buildings are few and large — the batching win
## from atlasing them would be negligible next to the authoring friction.
func _bake_buildings() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sprites/buildings")
	for id: StringName in ArtData.building_maps():
		var entry: Dictionary = ArtData.building_maps()[id]
		var map: Array = entry["map"]
		# Square entries carry one `size`; rectangular ones carry explicit `w`/`h`. Buildings
		# stopped being uniformly 2x2 once long footprints arrived — a 3x2 sawmill is 48x32 — and
		# assuming square silently truncated anything that was not.
		var w: int = entry.get("w", entry.get("size", 16))
		var h: int = entry.get("h", entry.get("size", 16))
		if not _check_map("building %s" % id, map, w, h):
			continue
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_stamp(img, map, 0, 0)
		_add_sprite_shadow(img, 0, 0, w, h)
		_save(img, "res://assets/sprites/buildings/%s.png" % id)


func _bake_ember() -> void:
	var map: Array = ArtData.EMBER
	var size := 24
	if not _check_map("ember", map, size, size):
		return
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_stamp(img, map, 0, 0)
	_save(img, EMBER_PATH)


# --- Generated FX ----------------------------------------------------------------------------

## Radial falloff for every PointLight2D. Squared falloff reads as firelight;
## linear reads as a flat disc of paint.
func _bake_light_falloff() -> void:
	var img := Image.create(LIGHT_SIZE, LIGHT_SIZE, false, Image.FORMAT_RGBA8)
	var centre := (LIGHT_SIZE - 1) * 0.5
	for y in LIGHT_SIZE:
		for x in LIGHT_SIZE:
			var d := Vector2(x - centre, y - centre).length() / centre
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a * a))
	_save(img, LIGHT_PATH)


## Every app-icon size iOS asks for. Godot falls back to the project icon when
## these are blank — and the project icon is an SVG, which iOS cannot use, so the
## exporter rejects the configuration. It does so WITHOUT printing a reason, which
## makes this one of the more annoying failures to diagnose.
const IOS_ICON_SIZES: Array[int] = [1024, 180, 167, 152, 120, 87, 80, 76, 60, 58, 40]


## The Ember against a dark field — the game's one image, and the only thing on the
## home screen that has to read at 40 pixels. Drawn with smooth falloff rather than
## the chunky pixel-art version, because a 12px sprite scaled to 1024 looks like a
## mistake rather than a style.
func _bake_app_icons() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/icons/ios")
	for size: int in IOS_ICON_SIZES:
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var centre := (size - 1) * 0.5
		var radius := float(size) * 0.34

		for y in size:
			for x in size:
				var d := Vector2(x - centre, y - centre).length()

				# Background: a subtle vertical gradient so the tile is not flat.
				var t := float(y) / float(size)
				var bg := Color("11161f").lerp(Color("070a10"), t)

				if d > radius * 1.9:
					img.set_pixel(x, y, bg)
					continue

				# Outer bloom, falling off smoothly to nothing.
				var glow := clampf(1.0 - (d / (radius * 1.9)), 0.0, 1.0)
				var col := bg.lerp(Color("c85a1e"), glow * glow * 0.85)

				# Mid body and pale core.
				if d < radius:
					var k := clampf(1.0 - (d / radius), 0.0, 1.0)
					col = col.lerp(Color("ff9a3c"), clampf(k * 2.2, 0.0, 1.0))
					if d < radius * 0.55:
						var c := clampf(1.0 - (d / (radius * 0.55)), 0.0, 1.0)
						col = col.lerp(Color("ffd88a"), clampf(c * 1.8, 0.0, 1.0))

				col.a = 1.0
				img.set_pixel(x, y, col)

		_save(img, "res://assets/icons/ios/icon_%d.png" % size)


## Nearest-neighbour contact sheet of everything, written to user:// so it never
## ships. Pixel art at native size is unreadable on a modern monitor, and reviewing
## it inside the running game means you cannot tell a bad sprite from a bad shader.
func _bake_preview() -> void:
	var scale := 8
	var sheets: Array[String] = [TILESET_PATH, VILLAGER_PATH, EMBER_PATH, RING_PATH]
	var pad := 8

	var loaded: Array[Image] = []
	var total_h := pad
	var max_w := 0
	for path: String in sheets:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			continue
		img.resize(img.get_width() * scale, img.get_height() * scale, Image.INTERPOLATE_NEAREST)
		loaded.append(img)
		total_h += img.get_height() + pad
		max_w = maxi(max_w, img.get_width())

	if loaded.is_empty():
		return

	var sheet := Image.create(max_w + pad * 2, total_h, false, Image.FORMAT_RGBA8)
	sheet.fill(Color("101418"))          # neutral dark backdrop, not black
	var y := pad
	for img: Image in loaded:
		# blend, not blit — blit would copy the sprites' transparent pixels over the
		# backdrop, making every sprite sit in a white box instead of on the sheet.
		sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(pad, y))
		y += img.get_height() + pad

	var out := "user://art_preview.png"
	sheet.save_png(out)
	print("wrote preview %s" % ProjectSettings.globalize_path(out))


## Flat ground ellipse. At 16px tiles a ring on the floor communicates selection far
## better than an outline on a 12px sprite, which is nearly invisible on a phone.
func _bake_selection_ring() -> void:
	var w := 16
	var h := 8
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := (w - 1) * 0.5
	var cy := (h - 1) * 0.5
	for y in h:
		for x in w:
			var nx := (x - cx) / cx
			var ny := (y - cy) / cy
			var d := sqrt(nx * nx + ny * ny)
			if d <= 1.0 and d >= 0.6:
				img.set_pixel(x, y, Color(1, 1, 1, 1))
	_save(img, RING_PATH)
