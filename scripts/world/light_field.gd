class_name LightField
extends RefCounted
## The gameplay light grid — the single value that four systems read.
##
## Light is not decoration in this game. One byte per tile drives:
##   * rendering      (the CanvasModulate + PointLight2D look is built to match it)
##   * monster AI     (lit tiles cost more to path through, bright ones burn)
##   * blight spread  (cannot spread into light above a threshold)
##   * villagers      (work speed and mood decay scale with local light)
##
## Because of that it must be exact and stable, so it is recomputed ONLY when a
## source is added, removed or moved — never per frame. Each source stamps a disc;
## moving the Ember clears its old disc and stamps a new one, touching only the
## affected cells rather than the whole map.

## A light source. `radius` is in tiles; `strength` is the value at the centre,
## falling off linearly to 0 at the edge.
class Source extends RefCounted:
	var cell: int = -1
	var radius: int = 0
	var strength: int = 0

	func _init(c: int = -1, r: int = 0, s: int = 255) -> void:
		cell = c
		radius = r
		strength = s

var _world: Node = null
var _sources: Dictionary = {}          ## handle:int -> Source
var _next_handle: int = 1


func setup(world: Node) -> void:
	_world = world
	_sources.clear()
	_next_handle = 1
	_clear()


# --- Source management ----------------------------------------------------------------

func add_source(cell: int, radius: int, strength: int = 255) -> int:
	var h := _next_handle
	_next_handle += 1
	_sources[h] = Source.new(cell, radius, strength)
	_restamp(_dirty_rect_for(_sources[h]))
	return h


func move_source(handle: int, cell: int) -> void:
	var src: Source = _sources.get(handle)
	if src == null or src.cell == cell:
		return
	# Union of where it was and where it is going — one restamp, not two.
	var before := _dirty_rect_for(src)
	src.cell = cell
	var after := _dirty_rect_for(src)
	_restamp(before.merge(after))


func remove_source(handle: int) -> void:
	var src: Source = _sources.get(handle)
	if src == null:
		return
	var rect := _dirty_rect_for(src)
	_sources.erase(handle)
	_restamp(rect)


func set_radius(handle: int, radius: int) -> void:
	var src: Source = _sources.get(handle)
	if src == null:
		return
	var before := _dirty_rect_for(src)
	src.radius = radius
	_restamp(before.merge(_dirty_rect_for(src)))


# --- Stamping -------------------------------------------------------------------------

## Recompute a rectangular region from scratch. Recomputing rather than
## incrementally adding/subtracting keeps overlapping sources exact — additive
## stamping drifts as soon as two discs overlap and one of them moves.
func _restamp(rect: Rect2i) -> void:
	var grid: Grid = _world.grid
	var light: PackedByteArray = _world.light

	rect = rect.intersection(Rect2i(0, 0, grid.width, grid.height))
	if rect.size.x <= 0 or rect.size.y <= 0:
		return

	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			light[grid.index(x, y)] = 0

	for src: Source in _sources.values():
		var c := grid.coord(src.cell)
		if src.radius <= 0:
			continue
		var lo_x := maxi(c.x - src.radius, rect.position.x)
		var hi_x := mini(c.x + src.radius, rect.end.x - 1)
		var lo_y := maxi(c.y - src.radius, rect.position.y)
		var hi_y := mini(c.y + src.radius, rect.end.y - 1)
		var r_sq := src.radius * src.radius
		for y in range(lo_y, hi_y + 1):
			for x in range(lo_x, hi_x + 1):
				var dx := x - c.x
				var dy := y - c.y
				var d_sq := dx * dx + dy * dy
				if d_sq > r_sq:
					continue
				var falloff := 1.0 - sqrt(float(d_sq)) / float(src.radius)
				var value := int(src.strength * falloff)
				var i := grid.index(x, y)
				# Lights combine by max, not by sum. Summing lets a cluster of weak
				# torches fake daylight, which breaks every threshold downstream.
				if value > light[i]:
					light[i] = value

	Events.light_grid_changed.emit(rect)


func _dirty_rect_for(src: Source) -> Rect2i:
	var grid: Grid = _world.grid
	var c := grid.coord(src.cell)
	var r := src.radius + 1
	return Rect2i(c.x - r, c.y - r, r * 2 + 1, r * 2 + 1)


func _clear() -> void:
	var light: PackedByteArray = _world.light
	for i in light.size():
		light[i] = 0
