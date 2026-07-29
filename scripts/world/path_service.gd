class_name PathService
extends RefCounted
## Villager pathfinding: an AStarGrid2D mirror of the world's cost layer, fed by a
## rate-limited request queue.
##
## Villagers path to arbitrary, individually-chosen destinations (that tree, this
## blueprint), which is what A* is good at. Monsters do NOT use this — they all want
## the same place, so they descend a shared flow field instead and cost effectively
## nothing per agent. Using one system for both is the classic mistake here.
##
## The budget is the important part. A* on a 128x128 grid is cheap once and ruinous
## sixty times in a frame, so requests queue and are served a few per tick. Villagers
## re-path rarely — a tree does not move — so the queue never actually backs up, and
## a villager waiting two ticks for a path is invisible at 10 Hz.

## Path solves permitted per sim tick. Raising this trades frame-time spikes for
## responsiveness; 4 has been enough for every case so far.
const BUDGET_PER_TICK := 4

## Requests older than this are dropped. Prevents a queue built up during a stall
## from being serviced long after the requester stopped caring.
const MAX_AGE_TICKS := 30

class Request extends RefCounted:
	var from: int
	var to: int
	var callback: Callable
	var issued_tick: int

	func _init(f: int, t: int, cb: Callable, tick: int) -> void:
		from = f
		to = t
		callback = cb
		issued_tick = tick

var _world: Node = null
var _astar: AStarGrid2D = null
var _queue: Array[Request] = []
var _dirty: bool = true

## Diagnostics for the debug overlay — a queue that is always long means the budget
## is too low for the current population, which is worth seeing before it becomes a
## "why are my villagers standing around" bug report.
var last_queue_length: int = 0
var solves_this_tick: int = 0


func setup(world: Node) -> void:
	_world = world
	_queue.clear()
	var grid: Grid = world.grid
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, grid.width, grid.height)
	_astar.cell_size = Vector2(Grid.TILE_SIZE, Grid.TILE_SIZE)
	# Never cut a diagonal between two solid cells — without this villagers slip
	# through the corner joint of two walls, which looks like a bug and lets
	# monsters do the same thing through your defences later.
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.update()
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


# --- Requests -----------------------------------------------------------------------

## Queue a path solve. `callback` receives a PackedInt32Array of cell indices —
## empty when no route exists, so callers must handle "unreachable" rather than
## assuming success.
func request(from: int, to: int, callback: Callable) -> void:
	_queue.append(Request.new(from, to, callback, _world.tick_hint()))


## Drop any queued request belonging to a caller that no longer wants one (a
## villager that died, or was reassigned before its path arrived).
func cancel_for(target: Object) -> void:
	var kept: Array[Request] = []
	for r: Request in _queue:
		if r.callback.get_object() != target:
			kept.append(r)
	_queue = kept


func step(tick: int) -> void:
	if _dirty:
		_rebuild_solidity()
		_dirty = false

	last_queue_length = _queue.size()
	solves_this_tick = 0

	while solves_this_tick < BUDGET_PER_TICK and not _queue.is_empty():
		var r: Request = _queue.pop_front()
		if tick - r.issued_tick > MAX_AGE_TICKS:
			continue
		if not r.callback.is_valid():
			continue
		solves_this_tick += 1
		r.callback.call(solve(r.from, r.to))


# --- Solving ------------------------------------------------------------------------

## Immediate solve, bypassing the queue. Use only for player-initiated actions,
## where one solve on a tap is affordable and waiting would feel unresponsive.
func solve(from: int, to: int) -> PackedInt32Array:
	var grid: Grid = _world.grid
	if not grid.is_valid_index(from) or not grid.is_valid_index(to):
		return PackedInt32Array()

	var from_v := grid.coord(from)
	var to_v := grid.coord(to)

	# A destination inside a wall or in water is common (the player taps a tree,
	# and the tree's own cell is solid). Rather than failing, walk to the closest
	# reachable cell beside it — that is what the player meant.
	if _astar.is_point_solid(to_v):
		var alt: int = _world.nearest_walkable(to)
		if alt == -1:
			return PackedInt32Array()
		to_v = grid.coord(alt)

	if from_v == to_v:
		return PackedInt32Array()

	var points := _astar.get_id_path(from_v, to_v)
	var out := PackedInt32Array()
	for p: Vector2i in points:
		out.append(grid.index(p.x, p.y))
	return out


## Push the world's cost layer into AStar. Done wholesale rather than incrementally:
## it is a single linear pass, and tracking individual dirty cells across blight
## spread, construction and tree felling is far more code and far more bug surface
## than it saves.
func _rebuild_solidity() -> void:
	var grid: Grid = _world.grid
	var move_cost: PackedByteArray = _world.move_cost
	for y in grid.height:
		for x in grid.width:
			var i := y * grid.width + x
			var c := move_cost[i]
			var p := Vector2i(x, y)
			_astar.set_point_solid(p, c >= 255)
			if c < 255:
				_astar.set_point_weight_scale(p, float(c) / 10.0)
