class_name Grid
extends RefCounted
## Pure grid math for the world. No state beyond dimensions, no nodes, no signals.
##
## Every world layer (terrain, light, blight, occupancy) is a flat array of
## width * height entries indexed `y * width + x`. That layout is the single most
## important performance decision in the project: it keeps whole-map sweeps
## (the blight CA, the monster flow field) as tight linear scans over a
## Packed*Array instead of Dictionary lookups or 2D array-of-arrays chasing.
##
## Cell indices are plain ints and are passed around everywhere in preference to
## Vector2i — they are cheaper to compare, hash and store. Convert at the edges.
##
## World owns the single Grid instance; get it via World.grid.

const TILE_SIZE := 16                 ## pixels per tile; art is authored at this size

var width: int = 0
var height: int = 0
var cell_count: int = 0


func _init(w: int = 0, h: int = 0) -> void:
	resize(w, h)


func resize(w: int, h: int) -> void:
	width = w
	height = h
	cell_count = w * h


# --- Index <-> coordinate ---------------------------------------------------------

func index(x: int, y: int) -> int:
	return y * width + x


func index_v(cell_pos: Vector2i) -> int:
	return cell_pos.y * width + cell_pos.x


func coord(i: int) -> Vector2i:
	return Vector2i(i % width, i / width)


func is_valid(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height


func is_valid_v(cell_pos: Vector2i) -> bool:
	return is_valid(cell_pos.x, cell_pos.y)


func is_valid_index(i: int) -> bool:
	return i >= 0 and i < cell_count


# --- World space <-> grid space ---------------------------------------------------
# World origin is the top-left corner of cell (0, 0). `to_world` returns the CENTRE
# of the cell, which is what units path to and what buildings anchor on.

func to_world(cell_pos: Vector2i) -> Vector2:
	return Vector2(
		cell_pos.x * TILE_SIZE + TILE_SIZE * 0.5,
		cell_pos.y * TILE_SIZE + TILE_SIZE * 0.5
	)


func to_world_index(i: int) -> Vector2:
	return to_world(coord(i))


func to_cell(world_pos: Vector2) -> Vector2i:
	return Vector2i(floori(world_pos.x / TILE_SIZE), floori(world_pos.y / TILE_SIZE))


func to_cell_index(world_pos: Vector2) -> int:
	var c := to_cell(world_pos)
	return index(c.x, c.y) if is_valid_v(c) else -1


func world_rect() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(width * TILE_SIZE, height * TILE_SIZE))


# --- Neighbours -------------------------------------------------------------------
# Returned as indices. The 4-way form is used by the blight CA and flood fills; the
# 8-way form by the flow field and unit movement. Both skip out-of-bounds rather
# than returning -1, so callers never need to filter.

const DIR_4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]
const DIR_8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)
]


func neighbours_4(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x := i % width
	var y := i / width
	if x > 0: out.append(i - 1)
	if x < width - 1: out.append(i + 1)
	if y > 0: out.append(i - width)
	if y < height - 1: out.append(i + width)
	return out


func neighbours_8(i: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var x := i % width
	var y := i / width
	for d in DIR_8:
		var nx := x + d.x
		var ny := y + d.y
		if nx >= 0 and nx < width and ny >= 0 and ny < height:
			out.append(ny * width + nx)
	return out


# --- Footprints -------------------------------------------------------------------
# Multi-tile buildings anchor on their top-left cell. `footprint_cells` returns every
# cell a building of the given size would cover, or an empty array if any part of it
# falls off the map — so callers can treat "empty result" as "invalid placement".

func footprint_cells(anchor: Vector2i, size: Vector2i) -> PackedInt32Array:
	var out := PackedInt32Array()
	for dy in size.y:
		for dx in size.x:
			var x := anchor.x + dx
			var y := anchor.y + dy
			if not is_valid(x, y):
				return PackedInt32Array()
			out.append(y * width + x)
	return out


# --- Distance ---------------------------------------------------------------------
# Squared distance where possible: units only ever compare distances, never need the
# true magnitude, and sqrt across 160 agents per tick is real cost.

func dist_sq(a: int, b: int) -> int:
	var dx := (a % width) - (b % width)
	var dy := (a / width) - (b / width)
	return dx * dx + dy * dy


func chebyshev(a: int, b: int) -> int:
	return maxi(absi((a % width) - (b % width)), absi((a / width) - (b / width)))
