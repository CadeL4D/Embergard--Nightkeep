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
		"speck": {"m": 34, "G": 28, "u": 5},
		"motifs": [{"map": [".g.", "mGm"], "count": 6}],
	},
	Terrain.Type.DIRT: {
		"base": "E",
		"speck": {"e": 40, "D": 26, "u": 4},
		"motifs": [{"map": ["De", "ee"], "count": 4}],
	},
	Terrain.Type.ROCK: {
		"base": "S",
		"speck": {"s": 38, "L": 24},
		"motifs": [{"map": ["s.", ".s", "s."], "count": 4}, {"map": ["LL"], "count": 5}],
	},
	Terrain.Type.SAND: {
		"base": "N",
		"speck": {"n": 36, "x": 22},
		"motifs": [{"map": ["xx"], "count": 5}],
	},
	Terrain.Type.WATER: {
		"base": "W",
		"speck": {"w": 26, "A": 22},
		"motifs": [{"map": ["AAA"], "count": 4}, {"map": ["ww"], "count": 3}],
	},
	Terrain.Type.DEEP_WATER: {
		"base": "w",
		"speck": {"W": 18, "k": 10},
		"motifs": [{"map": ["WW"], "count": 3}],
	},
	Terrain.Type.RUBBLE: {
		"base": "D",
		"speck": {"e": 30, "S": 20, "E": 20},
		"motifs": [{"map": ["SS", "sS"], "count": 5}, {"map": ["ee"], "count": 4}],
	},
}


func _ready() -> void:
	_ensure_dirs()
	_bake_tileset()
	_bake_villager()
	_bake_monsters()
	_bake_buildings()
	_bake_ember()
	_bake_light_falloff()
	_bake_selection_ring()
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

	_save(img, VILLAGER_PATH)


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
		if ok:
			_save(img, "res://assets/sprites/monsters/%s.png" % id)


## One PNG per building, named by id, so a BuildingDef .tres can point straight at
## its art without an atlas lookup. Buildings are few and large — the batching win
## from atlasing them would be negligible next to the authoring friction.
func _bake_buildings() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sprites/buildings")
	for id: StringName in ArtData.building_maps():
		var entry: Dictionary = ArtData.building_maps()[id]
		var map: Array = entry["map"]
		var size: int = entry["size"]
		if not _check_map("building %s" % id, map, size, size):
			continue
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		_stamp(img, map, 0, 0)
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
