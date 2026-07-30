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
const FEATURE_BLOCKS := {
	Feature.NONE: false,
	Feature.TREE: false,
	Feature.STONE: true,
	Feature.RUIN_WALL: true,
	Feature.RUIN_FLOOR: false,
	Feature.NEST: true,
	Feature.BERRIES: false,
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
const FEATURE_YIELD := {
	Feature.TREE: {&"wood": 12},
	Feature.STONE: {&"stone": 10},
	Feature.RUIN_WALL: {&"stone": 6},
	Feature.BERRIES: {&"food": 8},
}

## Hit points of a Blight nest.
##
## Sized as a deliberate project rather than a fight: about seven casts of Wrath, or
## four of Ward, or roughly twenty-five seconds of sustained fire from a watchtower
## built forward of the colony. Killing one is meant to be a campaign the player
## commits Faith or territory to, not something that happens in passing.
const NEST_HP := 260.0

## Villager-seconds required to fully harvest a feature.
const FEATURE_WORK := {
	Feature.TREE: 6.0,
	Feature.STONE: 9.0,
	Feature.RUIN_WALL: 5.0,
	Feature.BERRIES: 3.0,
}


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
		_: return &""
