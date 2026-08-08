class_name Biomes
extends RefCounted
## Static rules that turn a Realm region's biome id into local-map and simulation identity.
##
## Realm owns the continuous macro climate. This class owns the deliberately small set of
## authored consequences: how many nests a region supports, which resources thrive there,
## which ground is tiring to cross, and how readily the Blight takes hold.

const DEFAULT_ID := &"forest"

const DEFINITIONS := {
	&"desert": {
		"name": &"BIOME_DESERT", "hazard": &"BIOME_DESERT_HAZARD",
		"nest_count": 1, "nest_min": 28, "nest_span": 7.0,
		"forest_bonus": -0.18, "stone_bonus": 0.08, "food_bonus": -0.12,
		"threat": 1.12, "blight": 0.92,
	},
	&"dry_lands": {
		"name": &"BIOME_DRY_LANDS", "hazard": &"BIOME_DRY_LANDS_HAZARD",
		"nest_count": 1, "nest_min": 29, "nest_span": 7.0,
		"forest_bonus": -0.12, "stone_bonus": 0.12, "food_bonus": -0.08,
		"threat": 1.10, "blight": 0.96,
	},
	&"haven": {
		"name": &"BIOME_HAVEN", "hazard": &"BIOME_HAVEN_HAZARD",
		"nest_count": 1, "nest_min": 32, "nest_span": 8.0,
		"forest_bonus": 0.04, "stone_bonus": -0.02, "food_bonus": 0.10,
		"threat": 0.90, "blight": 0.86,
	},
	&"outlands": {
		"name": &"BIOME_OUTLANDS", "hazard": &"BIOME_OUTLANDS_HAZARD",
		"nest_count": 1, "nest_min": 29, "nest_span": 8.0,
		"forest_bonus": 0.01, "stone_bonus": 0.04, "food_bonus": -0.01,
		"threat": 1.08, "blight": 1.06,
	},
	&"coast": {
		"name": &"BIOME_COAST",
		"hazard": &"BIOME_COAST_HAZARD",
		"nest_count": 1, "nest_min": 31, "nest_span": 7.0,
		"forest_bonus": -0.03, "stone_bonus": -0.01, "food_bonus": 0.05,
		"threat": 0.92, "blight": 0.90,
	},
	&"grassland": {
		"name": &"BIOME_GRASSLAND",
		"hazard": &"BIOME_GRASSLAND_HAZARD",
		"nest_count": 1, "nest_min": 30, "nest_span": 8.0,
		"forest_bonus": -0.02, "stone_bonus": -0.02, "food_bonus": 0.07,
		"threat": 1.00, "blight": 1.00,
	},
	&"forest": {
		"name": &"BIOME_FOREST",
		"hazard": &"BIOME_FOREST_HAZARD",
		"nest_count": 1, "nest_min": 29, "nest_span": 8.0,
		"forest_bonus": 0.15, "stone_bonus": -0.05, "food_bonus": 0.01,
		"threat": 1.04, "blight": 1.08,
	},
	&"marsh": {
		"name": &"BIOME_MARSH",
		"hazard": &"BIOME_MARSH_HAZARD",
		"nest_count": 1, "nest_min": 28, "nest_span": 7.0,
		"forest_bonus": 0.03, "stone_bonus": -0.12, "food_bonus": 0.10,
		"threat": 1.10, "blight": 1.20,
	},
	&"highland": {
		"name": &"BIOME_HIGHLAND",
		"hazard": &"BIOME_HIGHLAND_HAZARD",
		"nest_count": 1, "nest_min": 32, "nest_span": 6.0,
		"forest_bonus": -0.10, "stone_bonus": 0.18, "food_bonus": -0.04,
		"threat": 0.96, "blight": 0.82,
	},
	&"badlands": {
		"name": &"BIOME_BADLANDS",
		"hazard": &"BIOME_BADLANDS_HAZARD",
		"nest_count": 1, "nest_min": 28, "nest_span": 7.0,
		"forest_bonus": -0.17, "stone_bonus": 0.08, "food_bonus": -0.10,
		"threat": 1.13, "blight": 0.92,
	},
	&"tundra": {
		"name": &"BIOME_TUNDRA",
		"hazard": &"BIOME_TUNDRA_HAZARD",
		"nest_count": 1, "nest_min": 31, "nest_span": 7.0,
		"forest_bonus": -0.08, "stone_bonus": 0.08, "food_bonus": -0.08,
		"threat": 1.03, "blight": 0.74,
	},
}


static func definition(id: StringName) -> Dictionary:
	return DEFINITIONS.get(id, DEFINITIONS[DEFAULT_ID])


static func name_key(id: StringName) -> StringName:
	return definition(id).get("name", &"BIOME_GRASSLAND")


static func hazard_key(id: StringName) -> StringName:
	return definition(id).get("hazard", &"BIOME_GRASSLAND_HAZARD")


static func nest_count(id: StringName) -> int:
	return int(definition(id).get("nest_count", 1))


static func nest_min_distance(id: StringName) -> int:
	return int(definition(id).get("nest_min", 30))


static func nest_distance_span(id: StringName) -> float:
	return float(definition(id).get("nest_span", 8.0))


static func richness_bonus(id: StringName, kind: StringName) -> float:
	return float(definition(id).get("%s_bonus" % kind, 0.0))


static func threat_multiplier(id: StringName) -> float:
	return float(definition(id).get("threat", 1.0))


static func blight_multiplier(id: StringName) -> float:
	return float(definition(id).get("blight", 1.0))


## A full harvested feature still yields an integer load. Multipliers are intentionally
## modest: biome selection should matter without making a poor region unable to bootstrap.
static func yield_multiplier(id: StringName, feature: int) -> float:
	match id:
		&"desert":
			return 1.14 if feature in [Terrain.Feature.STONE, Terrain.Feature.DARK_CRYSTAL] else 0.82
		&"dry_lands":
			return 1.18 if feature in [Terrain.Feature.STONE, Terrain.Feature.RUIN_WALL] else 0.86
		&"haven":
			return 1.18 if feature == Terrain.Feature.BERRIES else 1.04
		&"outlands":
			return 1.16 if feature == Terrain.Feature.DARK_CRYSTAL else 0.96
		&"forest":
			return 1.24 if feature == Terrain.Feature.TREE else 0.94
		&"marsh":
			return 1.22 if feature == Terrain.Feature.BERRIES else (
				0.84 if feature == Terrain.Feature.STONE else 1.0)
		&"highland":
			return 1.28 if feature in [Terrain.Feature.STONE, Terrain.Feature.RUIN_WALL] \
				else 0.90
		&"badlands":
			return 1.14 if feature in [Terrain.Feature.STONE, Terrain.Feature.RUIN_WALL] \
				else 0.86
		&"tundra":
			return 1.10 if feature == Terrain.Feature.STONE else 0.88
		&"coast":
			return 1.12 if feature == Terrain.Feature.BERRIES else 0.96
		_:
			return 1.08 if feature == Terrain.Feature.BERRIES else 1.0


## Bare-ground travel identity. Roads multiply on top of this, so paving a bog or a rocky
## ascent is a stronger strategic improvement than paving open grass.
static func movement_multiplier(id: StringName, terrain_type: int) -> float:
	match id:
		&"desert", &"dry_lands":
			return 0.90 if terrain_type in [Terrain.Type.DIRT, Terrain.Type.RUBBLE] else 0.96
		&"outlands":
			return 0.92 if terrain_type in [Terrain.Type.ROCK, Terrain.Type.RUBBLE] else 0.97
		&"haven":
			return 1.02
		&"marsh":
			return 0.80 if terrain_type in [Terrain.Type.DIRT, Terrain.Type.SAND] else 0.92
		&"highland":
			return 0.86 if terrain_type in [Terrain.Type.ROCK, Terrain.Type.RUBBLE] else 0.95
		&"badlands":
			return 0.90 if terrain_type in [Terrain.Type.DIRT, Terrain.Type.RUBBLE] else 0.96
		&"tundra":
			return 0.88
		&"forest":
			return 0.94 if terrain_type in [Terrain.Type.GRASS, Terrain.Type.DIRT] else 1.0
		_:
			return 1.0
