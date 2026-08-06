class_name BlightField
extends RefCounted
## The Blight: a cellular automaton that only ever simulates its own frontier.
##
## The naive version sweeps all 16,384 tiles looking for something to do. That is
## pure waste — the overwhelming majority of the map is either clean and far from
## corruption, or long since fully consumed. Only tiles that are blighted AND have
## a clean passable neighbour can actually spread, and on a typical map that set is
## 200-800 cells. We track exactly that set and touch nothing else.
##
## Rendering does NOT go through a TileMapLayer. Thousands of set_cell calls hitch
## badly on mobile. Instead the intensity grid is mirrored into a W*H FORMAT_R8
## Image and uploaded as one small texture (a 128x128 R8 is ~16 KB) whenever it
## changes; a single full-map ColorRect shader samples it. One draw call, one tiny
## upload every couple of seconds, and the shader can animate the edges organically
## in a way no autotile could.

const STEP_INTERVAL := 20              ## sim ticks between passes (~2s at 10Hz)
const SAMPLES_PER_PASS := 256          ## frontier cells examined per pass
const SEED_INTENSITY := 90
const RAMP_PER_PASS := 6               ## how fast an infected tile deepens
const LIGHT_RESIST := 0.9              ## how strongly light suppresses spread

## Chance that ground inside the colony's own sphere simply refuses an advance.
##
## Deliberately a resistance and not a wall. At 1.0 the settlement would be permanently immune
## and the siege would stop being a siege the moment a sphere existed; at 0.0 the light's dawn
## reclamation is a treadmill, because the frontier retakes by afternoon what first light cleared.
## At 0.8 the corruption gets in eventually, and slowly, and only where the player let their
## buildings thin out — which is a decision about where to build rather than a dice roll.
const INFLUENCE_RESIST := 0.8
## Night pressure. Modest, because the Blight is a siege and not a tide — a big night
## multiplier made corruption something that happened TO the player between dusk and dawn
## rather than something they were losing ground to over a campaign.
const NIGHT_MULTIPLIER := 1.6

## Per-frontier-cell chance to spread on a pass.
##
## Tuned down from 0.02, which with a 256-cell sample and a pass every two seconds worked out to
## roughly 1,100 new tiles per day cycle — about 7% of the map, EVERY DAY. That reads as a flood:
## the player watches the map turn over while they are still working out where to put a farm.
##
## At 0.005 it is closer to 1.8% of the map per day on the baseline tier, so losing serious
## ground takes a week and the player can see it coming, plan against it, and push back with Ward.
## Difficulty scales this (Sheltered 0.5x through Forsaken 2.2x), so the tiers differ in how fast
## the noose tightens rather than in whether it does.
##
## The smoke test asserts a coverage band so this cannot silently regress in either direction.
const BASE_SPREAD := 0.005

var _world: Node = null
var _frontier: PackedInt32Array = PackedInt32Array()
var _in_frontier: PackedByteArray = PackedByteArray()
var _cursor: int = 0
var _rng := RandomNumberGenerator.new()

## Suppression stamped by purification and the Ward power. Non-zero blocks spread
## entirely; decays over time so wards are temporary but purified ground is not.
var _suppression: PackedByteArray = PackedByteArray()

var image: Image = null
var texture: ImageTexture = null
var _image_dirty: bool = false


func setup(world: Node) -> void:
	_world = world
	var n: int = world.grid.cell_count
	_frontier = PackedInt32Array()
	_in_frontier = PackedByteArray()
	_in_frontier.resize(n)
	_suppression = PackedByteArray()
	_suppression.resize(n)
	_cursor = 0
	_rng.seed = world.seed_value ^ 0x5EED

	image = Image.create(world.grid.width, world.grid.height, false, Image.FORMAT_R8)
	image.fill(Color(0, 0, 0, 1))
	texture = ImageTexture.create_from_image(image)
	_image_dirty = false


# --- Seeding & designation ---------------------------------------------------------------

## Recompute the frontier from the blight grid. Needed after a save is loaded,
## where the intensities are restored wholesale but the frontier — which is derived
## bookkeeping, not saved state — has to be rediscovered or the Blight sits frozen.
func rebuild_frontier() -> void:
	var blight: PackedByteArray = _world.blight
	_frontier = PackedInt32Array()
	_in_frontier.resize(blight.size())
	for i in _in_frontier.size():
		_in_frontier[i] = 0
	_cursor = 0
	for i in blight.size():
		if blight[i] == 0:
			continue
		_mark_pixel(i, blight[i])
		if not _open_neighbours(i).is_empty():
			_push_frontier(i)


func seed_at(cell: int, intensity: int = SEED_INTENSITY) -> void:
	var blight: PackedByteArray = _world.blight
	if _world.region_purified or not _world.grid.is_valid_index(cell):
		return
	blight[cell] = maxi(blight[cell], intensity)
	_mark_pixel(cell, blight[cell])
	_push_frontier(cell)
	Events.blight_changed.emit(cell, true)


## Ground the colony's light takes back, applied at dawn.
##
## Light used to only SLOW corruption — see LIGHT_RESIST, which suppresses spread and nothing
## more. That made the Blight a ratchet: the sole way to reverse any of it was the Cleanse ritual,
## an end-game one-shot gated behind clearing every nest. So the map was a backdrop. Nothing was
## ever WON at night, only lost more slowly, and a night survived changed nothing you could see in
## the morning.
##
## Now a lit tile on the boundary is pushed back each dawn, which makes the edge of the settlement
## a line that moves in both directions. Holding your torches through a night is worth something,
## a beacon is territory rather than decoration, and the Ember has a job after dark that competes
## with the job it has in daylight.
##
## Frontier-only, deliberately. That set is exactly the boundary and it is the few hundred cells
## this class already tracks — reclaiming from anywhere would let one deep beacon hollow the
## corruption out from behind, which is a very different (and much cheaper) game.
const RECLAIM_LIGHT := 110             ## light needed before ground begins to clear
const RECLAIM_PER_DAWN := 22           ## intensity drained from a lit boundary tile each dawn


## Returns how many tiles came fully clean, for the morning report.
func reclaim_lit_ground() -> int:
	var light: PackedByteArray = _world.light
	var cleared := 0
	# Iterated over a copy: purify() edits the frontier as tiles come clean, and mutating the
	# array underneath the loop would skip the cells that get swapped into the vacated slots.
	for cell in _frontier.duplicate():
		if cell < 0 or cell >= light.size() or _in_frontier[cell] == 0:
			continue
		if int(light[cell]) < RECLAIM_LIGHT:
			continue
		if purify(cell, RECLAIM_PER_DAWN):
			cleared += 1
	return cleared


## Drain intensity from a tile (a Cleanser working, or the Ward power). Returns true
## when the tile is fully clean.
func purify(cell: int, amount: int) -> bool:
	var blight: PackedByteArray = _world.blight
	if not _world.grid.is_valid_index(cell) or blight[cell] == 0:
		return true
	var before := blight[cell]
	blight[cell] = maxi(blight[cell] - amount, 0)
	_mark_pixel(cell, blight[cell])
	if blight[cell] > 0:
		# Partial cleansing that drops the tile back below the takeover line has to repaint too,
		# or purified ground keeps its corrupted texture and Ward looks like it did nothing.
		if before >= TileAtlas.CORRUPT_THRESHOLD and blight[cell] < TileAtlas.CORRUPT_THRESHOLD:
			Events.blight_changed.emit(cell, false)
		return false

	# Cleaning a tile re-opens its still-blighted neighbours: they now have a clean
	# edge again, so they belong back on the frontier. Forgetting this is the classic
	# bug where purified ground never gets re-attacked and the Blight silently stalls.
	_remove_frontier(cell)
	for n in _world.grid.neighbours_4(cell):
		if blight[n] > 0:
			_push_frontier(n)
	_suppression[cell] = 255
	_world.cost_dirty = true
	Events.blight_changed.emit(cell, false)
	return true


func suppress(cell: int, value: int) -> void:
	if _world.grid.is_valid_index(cell):
		_suppression[cell] = maxi(_suppression[cell], value)


# --- The pass ------------------------------------------------------------------------------

func step(tick: int) -> void:
	if _image_dirty and tick % 4 == 0:
		texture.update(image)
		_image_dirty = false
	if _world.region_purified:
		return
	if tick % STEP_INTERVAL != 0 or _frontier.is_empty():
		return

	var blight: PackedByteArray = _world.blight
	var light: PackedByteArray = _world.light
	var night_mult: float = NIGHT_MULTIPLIER if Sim.is_dark() else 1.0
	# Hoisted with night_mult: both are constant for the whole pass, and this loop runs
	# a couple of hundred times per pass.
	var base_chance: float = BASE_SPREAD * night_mult * Difficulties.blight_mult() \
		* Climate.blight_multiplier() * DefenseControl.nest_suppression_multiplier()

	var examined := 0
	var samples := mini(SAMPLES_PER_PASS, _frontier.size())
	while examined < samples:
		examined += 1
		if _cursor >= _frontier.size():
			_cursor = 0
		var cell := _frontier[_cursor]

		# Deepen, then decide whether it is still a frontier tile at all.
		if blight[cell] < 255:
			var before := blight[cell]
			blight[cell] = mini(blight[cell] + RAMP_PER_PASS, 255)
			_mark_pixel(cell, blight[cell])
			# The ground turns partway up the ramp, not the moment it is infected. Announce that
			# crossing so the renderer can swap the tile — without this the terrain would only
			# ever update on spread and purify, and a tile deepening from "taking hold" to
			# "taken" would never actually change.
			if before < TileAtlas.CORRUPT_THRESHOLD and blight[cell] >= TileAtlas.CORRUPT_THRESHOLD:
				Events.blight_changed.emit(cell, true)

		var open := _open_neighbours(cell)
		if open.is_empty():
			_remove_frontier_at(_cursor)
			continue
		_cursor += 1

		if _suppression[cell] > 0:
			_suppression[cell] = maxi(_suppression[cell] - 8, 0)
			continue

		var chance := base_chance
		chance *= 1.0 - (float(light[cell]) / 255.0) * LIGHT_RESIST
		if chance <= 0.0 or _rng.randf() > chance:
			continue

		var target := open[_rng.randi() % open.size()]
		if _suppression[target] > 0:
			continue
		# Standing buildings hold the ground they claim. Without this, dawn reclamation was a
		# treadmill: the light cleared a tile at first light and the frontier took it back the
		# same afternoon, so the player did the work and kept none of it. The colony's own
		# sphere is the right shape for it — it is granted BY buildings, it already grows and
		# bulges toward wherever the settlement has been built, and the influence overlay means
		# the player can already SEE the line they are being asked to hold.
		if _world.resists_blight(target) and _rng.randf() < INFLUENCE_RESIST:
			continue
		blight[target] = maxi(blight[target], SEED_INTENSITY)
		_mark_pixel(target, blight[target])
		_push_frontier(target)
		_world.cost_dirty = true
		Events.blight_changed.emit(target, true)


## Clean, passable neighbours — the only cells this tile could spread into.
func _open_neighbours(cell: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var blight: PackedByteArray = _world.blight
	for n in _world.grid.neighbours_4(cell):
		if blight[n] == 0 and _world.is_walkable(n):
			out.append(n)
	return out


# --- Frontier bookkeeping ---------------------------------------------------------------
# Membership is mirrored in a byte array so the "is it already in?" test is O(1)
# rather than a linear scan of a few hundred entries every single spread.

func _push_frontier(cell: int) -> void:
	if _in_frontier[cell] != 0:
		return
	_in_frontier[cell] = 1
	_frontier.append(cell)


func _remove_frontier(cell: int) -> void:
	if _in_frontier[cell] == 0:
		return
	var idx := _frontier.find(cell)
	if idx != -1:
		_remove_frontier_at(idx)


## Swap-back removal — order in the frontier is meaningless, so there is no reason
## to pay for a shift. The rotating cursor tolerates the reshuffle.
func _remove_frontier_at(idx: int) -> void:
	var cell := _frontier[idx]
	_in_frontier[cell] = 0
	var last := _frontier.size() - 1
	_frontier[idx] = _frontier[last]
	_frontier.resize(last)
	if _cursor > last:
		_cursor = 0


# --- Rendering mirror ---------------------------------------------------------------------

func _mark_pixel(cell: int, intensity: int) -> void:
	var c: Vector2i = _world.grid.coord(cell)
	image.set_pixel(c.x, c.y, Color(float(intensity) / 255.0, 0.0, 0.0, 1.0))
	_image_dirty = true


func coverage() -> float:
	# The Audio autoload samples this on the title screen, before World.generate()
	# has called setup(). Returning an empty-map value is both accurate and keeps a
	# menu idle from producing a runtime exception every three quarters of a second.
	if _world == null or _world.blight.is_empty():
		return 0.0
	var blight: PackedByteArray = _world.blight
	var count := 0
	for i in blight.size():
		if blight[i] > 0:
			count += 1
	return float(count) / float(blight.size())


func frontier_size() -> int:
	return _frontier.size()
