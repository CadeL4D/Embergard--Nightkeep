class_name Terrain
extends RefCounted
## Stateless rulebook for terrain and map features. No nodes, no state — just the
## type tables and the queries everything else asks about them.
##
## Two layers, both PackedByteArrays owned by World:
##   * terrain  — what the ground IS (water, grass, rock). Never changes at runtime
##                except through purification/blight recolouring.
##   * feature  — what is ON the ground (a tree, a stone outcrop, a ruin wall).
##                Consumed by harvesting, cleared by building.
##
## Both are bytes, so the enums must stay under 256 entries and new values go on the
## END — save files store the raw arrays.

enum Type {
	DEEP_WATER,
	WATER,
	SAND,
	GRASS,
	DIRT,
	ROCK,
	RUBBLE,
}

enum Feature {
	NONE,
	TREE,
	STONE,
	RUIN_WALL,
	RUIN_FLOOR,
	NEST,          ## blight source; killing it permanently stops one spread origin
	BERRIES,
	DARK_CRYSTAL,
}

## Terrain a unit can stand on. Water is impassable in the slice; bridges later.
const WALKABLE := {
	Type.DEEP_WATER: false,
	Type.WATER: false,
	Type.SAND: true,
	Type.GRASS: true,
	Type.DIRT: true,
	Type.ROCK: true,
	Type.RUBBLE: true,
}

## Features that block movement. Trees do NOT — villagers walk through woodland,
## which keeps early pathing forgiving and stops forests from becoming mazes.
## Features nobody can walk through.
##
## TREE blocks now. It did not before, and that single flag is most of why the map read as decoration
## rather than as terrain: a forest you can stroll through is a green texture, whereas one you have to
## go round — or cut a road through — is a place. It makes woodland a wall the colony carves into, it
## gives the flow field something real to route the horde around, and it means clearing trees is
## genuinely how you open ground.
##
## BERRIES stay walkable. They are a low bush and, more importantly, the only food on the map before a
## farm exists; making a scattered food source into an obstacle course would punish the opening for no
## design gain.
const FEATURE_BLOCKS := {
	Feature.NONE: false,
	Feature.TREE: true,
	Feature.STONE: true,
	Feature.RUIN_WALL: true,
	Feature.RUIN_FLOOR: false,
	Feature.NEST: true,
	Feature.BERRIES: false,
	Feature.DARK_CRYSTAL: true,
}

## Extra pathing cost per terrain, in tenths. Kept small — big spreads make units
## take absurd detours that read as broken AI rather than smart routing.
const MOVE_COST := {
	Type.DEEP_WATER: 255,
	Type.WATER: 255,
	Type.SAND: 12,
	Type.GRASS: 10,
	Type.DIRT: 10,
	Type.ROCK: 14,
	Type.RUBBLE: 16,
}

## What a feature yields when harvested: resource kind and amount per full harvest.
## What one harvested feature gives up.
##
## Cut hard from 12 wood / 10 stone / 8 food. Combined with the work times below, raw gathering was
## fast enough that the early game had no scarcity in it at all: two woodcutters kept ahead of every
## build order, so choosing WHAT to build was never a real decision and the production chain existed
## to convert a surplus rather than to relieve a shortage.
##
## The point is not to make the player wait. It is that wood, stone and food have to be worth
## deciding between, which they are not while all three are abundant.
const FEATURE_YIELD := {
	Feature.TREE: {&"wood": 7},
	# Secondary yields make the Phase-1 resource catalog reachable without adding
	# extra scene nodes or visually ambiguous deposit types. Haulers carry each
	# stack separately; nothing is created directly in the global cache.
	Feature.STONE: {&"stone": 5, &"ore": 1},
	Feature.RUIN_WALL: {&"stone": 6, &"emberglass": 1},
	Feature.BERRIES: {&"food": 5, &"herbs": 1},
	Feature.DARK_CRYSTAL: {&"crystal": 4},
}

## Hit points of a Blight nest.
##
## Sized as a deliberate project rather than a fight: about seven casts of Wrath, or
## four of Ward, or roughly twenty-five seconds of sustained fire from a watchtower
## built forward of the colony. Killing one is meant to be a campaign the player
## commits Faith or territory to, not something that happens in passing.
const NEST_HP := 260.0

## Villager-seconds required to fully harvest a feature.
## Villager-seconds to harvest one feature.
##
## Raised alongside the yields being cut, so the two multiply: a tree was 12 wood for 6 seconds and is
## now 7 wood for 11, which is roughly a third of the old rate. Stone is slower again, because it is
## the material the upper half of the build list wants and it should be the thing a colony has to
## commit quarriers to rather than something that accumulates.
##
## Berries stay quick. They are meant to be the thing that keeps day one alive while the player works
## out where the farm goes, and a slow forage would just make the opening tense for the wrong reason.
const FEATURE_WORK := {
	Feature.TREE: 11.0,
	Feature.STONE: 18.0,
	Feature.RUIN_WALL: 9.0,
	Feature.BERRIES: 4.0,
	Feature.DARK_CRYSTAL: 14.0,
}


## Features that raising a building simply clears out of the way.
##
## Necessary because TREE now blocks movement, and `Colony.check_placement` refuses any cell held by a
## blocking feature — which would have meant a forested map had nowhere to build at all except the
## pre-cleared ground around the keep, with no way to order a specific tree felled.
##
## So building on woodland IS clearing it: the site is valid, and `place_building` levels the trees on
## the footprint. Boulders, ruin walls and nests are not on this list — those are genuine obstacles the
## player has to send someone to break first.
const FEATURE_CLEARABLE := {
	Feature.TREE: true,
	Feature.BERRIES: true,
}


## Does a builder have to remove this before the ground is usable, or can they just build over it?
static func blocks_building(feature: int) -> bool:
	return FEATURE_BLOCKS.get(feature, false) and not FEATURE_CLEARABLE.get(feature, false)


static func is_walkable(terrain_type: int, feature: int) -> bool:
	return WALKABLE.get(terrain_type, false) and not FEATURE_BLOCKS.get(feature, false)


static func move_cost(terrain_type: int) -> int:
	return MOVE_COST.get(terrain_type, 10)


static func is_harvestable(feature: int) -> bool:
	return FEATURE_YIELD.has(feature)


static func yield_of(feature: int) -> Dictionary:
	return FEATURE_YIELD.get(feature, {})


static func work_for(feature: int) -> float:
	return FEATURE_WORK.get(feature, 5.0)


## Which resource job category harvests this feature. Drives work-order routing:
## a villager assigned to Woodcutting only claims orders whose job matches.
static func job_for_feature(feature: int) -> StringName:
	match feature:
		Feature.TREE: return &"woodcutting"
		Feature.STONE, Feature.RUIN_WALL: return &"quarrying"
		Feature.BERRIES: return &"foraging"
		Feature.DARK_CRYSTAL: return &"crystal_harvester"
		_: return &""
