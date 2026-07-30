class_name FlowField
extends RefCounted
## A Dijkstra map: solve once for the whole grid, and every agent heading for the
## same place reads a single byte to know where to go.
##
## This is the reason a hundred monsters cost almost nothing. They all want the
## keep, so pathing them individually with A* would redo the same search a hundred
## times; instead one sweep fills a direction per tile and each monster does one
## array lookup per step. Villagers still use A* — they head for individually chosen
## destinations, which is the opposite problem.
##
## Two things are baked into the cost function rather than handled by the agents:
##   * LIGHT raises cost, so monsters naturally flow around lit ground and pour
##     through the dark gaps. "Monsters fear light" falls out of pathing for free,
##     and lit corridors become a real defensive structure.
##   * WALLS are expensive but not impassable, so monsters route around a palisade
##     when there is a way round and smash through it when there is not. That gives
##     siege behaviour without a single line of siege AI.
##
## Building is CHUNKED. A full 16k-cell sweep in GDScript is tens of milliseconds,
## which would be a visible hitch every time a wall goes up, so the field is built
## a budget of cells per tick into a back buffer and swapped in when finished.
## Agents read a slightly stale field in the meantime, which is harmless — a monster
## walking two tiles toward where the keep still is loses nothing.

const UNREACHABLE := 0x3FFFFFFF
const NO_DIR := 8

const DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]
## Diagonal steps cost sqrt(2); everything is in tenths to stay integer.
const STEP_COST: Array[int] = [10, 14, 10, 14, 10, 14, 10, 14]

## Extra cost for crossing a fully lit tile. Big enough to make monsters prefer a
## dark detour, small enough that they will still cross light to reach the keep
## rather than milling about at the edge of a torch.
const LIGHT_PENALTY := 60
## Cost of breaking through a solid building, in the same units.
const WALL_PENALTY := 220

## Added back on top of a road, per tier, cancelling most of the saving the surface gave.
##
## The horde reads the same `move_cost` array villagers do, so without this every road the player
## laid would be a free approach lane straight to the Hearth — and the optimal play would be never
## to pave anything, which makes the whole feature dead content.
##
## Deliberately does NOT cancel it entirely. Roads SHOULD funnel monsters, because a predictable
## approach is one the player can line with towers and close with a gate. The point is to make
## paving a decision about where you want them to come from, not a mistake.
const PATH_PENALTY := 4

var width: int = 0
var height: int = 0

## The live field agents read.
var dir: PackedByteArray = PackedByteArray()
var cost: PackedInt32Array = PackedInt32Array()

var building: bool = false

var _world: Node = null
var _next_dir: PackedByteArray = PackedByteArray()
var _next_cost: PackedInt32Array = PackedInt32Array()
var _frontier: PackedInt32Array = PackedInt32Array()
var _head: int = 0
var _move_cost: PackedByteArray = PackedByteArray()
var _light: PackedByteArray = PackedByteArray()
var _gate: PackedByteArray = PackedByteArray()
var _path: PackedByteArray = PackedByteArray()


func setup(world: Node) -> void:
	_world = world
	width = world.grid.width
	height = world.grid.height
	dir = PackedByteArray()
	dir.resize(width * height)
	dir.fill(NO_DIR)
	cost = PackedInt32Array()
	cost.resize(width * height)
	cost.fill(UNREACHABLE)
	building = false


## Start a rebuild toward `goals`. Snapshots the cost and light layers so the sweep
## cannot be corrupted by the world changing underneath it mid-build.
func begin(goals: PackedInt32Array) -> void:
	if _world == null or goals.is_empty():
		return
	var n := width * height
	_next_cost = PackedInt32Array()
	_next_cost.resize(n)
	_next_cost.fill(UNREACHABLE)
	_next_dir = PackedByteArray()
	_next_dir.resize(n)
	_next_dir.fill(NO_DIR)

	_move_cost = _world.move_cost.duplicate()
	_light = _world.light.duplicate()
	# Sized defensively: _cell_cost indexes this on the hot path with no bounds check,
	# so a field built before the world finished sizing its layers would crash rather
	# than misbehave.
	_gate = _world.gate.duplicate()
	if _gate.size() != n:
		_gate.resize(n)
	_path = _world.path_tier.duplicate()
	if _path.size() != n:
		_path.resize(n)

	_frontier = PackedInt32Array()
	for g in goals:
		if g >= 0 and g < n:
			_next_cost[g] = 0
			_frontier.append(g)
	_head = 0
	building = not _frontier.is_empty()


## Expand up to `budget` cells. Returns true when the field is complete and swapped in.
func step(budget: int) -> bool:
	if not building:
		return true

	var processed := 0
	while processed < budget:
		if _head >= _frontier.size():
			_commit()
			return true
		var current := _frontier[_head]
		_head += 1
		processed += 1

		var base := _next_cost[current]
		var cx := current % width
		var cy := current / width

		for d in 8:
			var dv: Vector2i = DIRS[d]
			var nx := cx + dv.x
			var ny := cy + dv.y
			if nx < 0 or ny < 0 or nx >= width or ny >= height:
				continue
			var ni := ny * width + nx
			var terrain_cost := _cell_cost(ni)
			if terrain_cost < 0:
				continue                                  # genuinely impassable
			var candidate := base + STEP_COST[d] * terrain_cost / 10
			if candidate >= _next_cost[ni]:
				continue
			_next_cost[ni] = candidate
			# Record the direction pointing BACK toward the source, so an agent
			# standing on ni walks along it to descend the field. No second pass.
			_next_dir[ni] = (d + 4) % 8
			_frontier.append(ni)

	# Housekeeping: the frontier is append-only during a build, so trim the consumed
	# prefix occasionally or a large map's array grows without bound.
	if _head > 4096:
		_frontier = _frontier.slice(_head)
		_head = 0
	return false


## Cost of entering a cell, in tenths. Negative means impassable.
func _cell_cost(i: int) -> int:
	var mc := _move_cost[i]
	var lit := (int(_light[i]) * LIGHT_PENALTY) / 255

	if mc >= 255:
		# Solid. A building can be broken through; bare terrain (water) cannot.
		if _world.occupancy[i] != 0:
			return WALL_PENALTY + lit
		return -1

	# A gate is walkable ground as far as villagers and `move_cost` are concerned, but
	# to the horde it costs the same as smashing a wall. Charged rather than forbidden
	# so a gate in a long wall still reads as the cheap way in — the funnel is the
	# point, and a monster that would rather chew the gate than walk twenty tiles
	# around it is walking into the player's guns.
	if _gate[i] != 0:
		return WALL_PENALTY + lit

	return int(mc) + lit + int(_path[i]) * PATH_PENALTY


func _commit() -> void:
	cost = _next_cost
	dir = _next_dir
	_next_cost = PackedInt32Array()
	_next_dir = PackedByteArray()
	_frontier = PackedInt32Array()
	_head = 0
	building = false


# --- Queries ------------------------------------------------------------------------------

## The next cell to move to from `from`, or -1 if there is nowhere to go.
func next_cell(from: int) -> int:
	if from < 0 or from >= dir.size():
		return -1
	var d := dir[from]
	if d == NO_DIR:
		return -1
	var dv: Vector2i = DIRS[d]
	var nx := (from % width) + dv.x
	var ny := (from / width) + dv.y
	if nx < 0 or ny < 0 or nx >= width or ny >= height:
		return -1
	return ny * width + nx


## Walk the field up to `max_steps` and return the cells as a path. Agents take a
## multi-step path so they keep moving smoothly between their infrequent thinks.
func path_from(from: int, max_steps: int = 8) -> PackedInt32Array:
	var out := PackedInt32Array()
	var current := from
	for _i in max_steps:
		var next := next_cell(current)
		if next == -1 or next == current:
			break
		out.append(next)
		current = next
	return out


func is_reachable(from: int) -> bool:
	return from >= 0 and from < cost.size() and cost[from] < UNREACHABLE
