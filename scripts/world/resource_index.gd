class_name ResourceIndex
extends RefCounted
## Spatial index of every harvestable feature on the map, bucketed into chunks.
##
## Villagers constantly ask "where is the nearest tree I can claim?". Answering that
## by scanning all 16,384 cells would cost 60 villagers x 16k = a million checks a
## second, so instead every harvestable cell is filed into an 8x8-tile chunk and the
## query walks chunk rings outward from the asker, stopping as soon as a ring
## produces a hit. Typical searches touch a handful of chunks.
##
## The index is authoritative about WHERE things are, never about whether they are
## claimed — reservations live in Colony, because who is working what is colony
## state, not world state.

const CHUNK := 8

var _world: Node = null
var _chunks: Dictionary = {}          ## chunk id -> PackedInt32Array of cells
var _chunks_x: int = 0
var _chunks_y: int = 0


func setup(world: Node) -> void:
	_world = world
	_chunks.clear()
	var grid: Grid = world.grid
	_chunks_x = ceili(float(grid.width) / CHUNK)
	_chunks_y = ceili(float(grid.height) / CHUNK)

	for i in grid.cell_count:
		if Terrain.is_harvestable(world.feature[i]):
			_add(i)


func _chunk_of(cell: int) -> int:
	var grid: Grid = _world.grid
	var x := (cell % grid.width) / CHUNK
	var y := (cell / grid.width) / CHUNK
	return y * _chunks_x + x


func _add(cell: int) -> void:
	var c := _chunk_of(cell)
	if not _chunks.has(c):
		_chunks[c] = PackedInt32Array()
	var list: PackedInt32Array = _chunks[c]
	list.append(cell)
	_chunks[c] = list


## Drop a cell from the index. Called when a feature is harvested out or consumed
## by the Blight — forgetting this leaves villagers walking to trees that are no
## longer there, which reads as broken AI rather than a stale index.
func remove(cell: int) -> void:
	var c := _chunk_of(cell)
	if not _chunks.has(c):
		return
	var list: PackedInt32Array = _chunks[c]
	var idx := list.find(cell)
	if idx == -1:
		return
	# Order within a chunk is meaningless, so swap-back rather than shifting.
	list[idx] = list[list.size() - 1]
	list.resize(list.size() - 1)
	_chunks[c] = list


func add(cell: int) -> void:
	if Terrain.is_harvestable(_world.feature[cell]):
		_add(cell)


# --- Query ----------------------------------------------------------------------------

## Nearest cell holding a feature this job harvests, that `is_free` accepts.
## Returns -1 when nothing suitable is in range.
##
## `is_free` is passed in rather than the index consulting Colony directly, so this
## class stays a pure spatial structure and can be tested without a colony.
func nearest(from: int, job: JobDef, is_free: Callable, max_rings: int = 8) -> int:
	if job == null or _world == null:
		return -1
	var grid: Grid = _world.grid
	var origin := _chunk_of(from)
	var ox := origin % _chunks_x
	var oy := origin / _chunks_x

	var best := -1
	var best_dist := 0x7FFFFFFF

	for ring in range(0, max_rings + 1):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				# Perimeter of this ring only; inner chunks were covered already.
				if ring > 0 and absi(dx) != ring and absi(dy) != ring:
					continue
				var cx := ox + dx
				var cy := oy + dy
				if cx < 0 or cy < 0 or cx >= _chunks_x or cy >= _chunks_y:
					continue
				var list: PackedInt32Array = _chunks.get(cy * _chunks_x + cx, PackedInt32Array())
				for cell in list:
					if not job.harvests(_world.feature[cell]):
						continue
					if not is_free.call(cell):
						continue
					var d := grid.dist_sq(from, cell)
					if d < best_dist:
						best_dist = d
						best = cell

		# Stop one ring AFTER the first hit: a closer cell can still be hiding in
		# the next ring out, because chunk distance is not cell distance.
		if best != -1 and ring > 0:
			break

	return best


func count() -> int:
	var total := 0
	for list: PackedInt32Array in _chunks.values():
		total += list.size()
	return total
