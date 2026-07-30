class_name TileAtlas
extends RefCounted
## The one place that knows where each terrain and feature type lives in the
## tileset atlas.
##
## Shared by the asset baker (scripts/dev/bake_assets.gd) and the renderer
## (world_view.gd) so the two can never disagree about which tile is which — a
## mismatch there produces a map that looks plausible but is quietly lying about
## what the sim thinks is there.
##
## Layout, derived from the enum values rather than hand-listed:
##   rows 0..2 = Terrain.Type, one row per variant (column == enum value)
##   row 3     = Terrain.Feature (column == enum value - 1, since NONE is not drawn)
##   rows 4..6 = CORRUPTED Terrain.Type, same columns, one row per variant
##
## VARIANTS exist because a single tile per material makes large areas read as an
## obvious repeating grid — the eye locks onto the identical noise instantly. Three
## variants scattered by a position hash breaks that up for three times the atlas
## space and no runtime cost.

const COLUMNS := 8
const ROWS := 8
const TILE := 16
const VARIANTS := 3

const FEATURE_ROW := 3

## Row holding the DENSE interior of each clustered feature — see ArtData's note.
##
## A cell whose four orthogonal neighbours share its feature is painted from here instead of from
## the feature row, so a wood reads as one mass with a ragged rim rather than as a lattice of
## separate trees. Column is the same as the feature row's, so there is one mapping to remember.
const DENSE_ROW := 7

## Features that have a dense interior. Anything absent simply always uses its outlined sprite,
## which is correct for the things that never cluster — a ruin wall, a nest.
const DENSE_FEATURES := [
	Terrain.Feature.TREE,
	Terrain.Feature.STONE,
	Terrain.Feature.BERRIES,
]


static func has_dense(feature: int) -> bool:
	return feature in DENSE_FEATURES


static func dense_coords(feature: int) -> Vector2i:
	return Vector2i(feature - 1, DENSE_ROW)

## First row of corrupted ground. Corrupted tiles mirror the clean rows exactly — same column
## per terrain type, same three variants — so a blighted tile is a genuine terrain swap rather
## than a wash drawn over the top of the original.
const CORRUPT_ROW := 4

## Blight intensity (0-255) at which the ground itself turns and the tile is replaced.
##
## Sits well above BlightField.SEED_INTENSITY (90) on purpose: a freshly infected tile should
## look like it is being taken, not like it has already gone. The shader stipples that band, and
## the tile swaps once the corruption has really set in.
const CORRUPT_THRESHOLD := 150


static func terrain_coords(terrain_type: int, variant: int = 0) -> Vector2i:
	return Vector2i(terrain_type, variant % VARIANTS)


static func corrupt_terrain_coords(terrain_type: int, variant: int = 0) -> Vector2i:
	return Vector2i(terrain_type, CORRUPT_ROW + variant % VARIANTS)


## Water is never corrupted — the Blight only spreads across walkable ground — so it gets no
## corrupted variant and asking for one would return an empty tile.
static func is_corruptible(terrain_type: int) -> bool:
	return Terrain.WALKABLE.get(terrain_type, false)


## Columns holding the alternate silhouettes for a feature. The first entry is the
## feature's own base column, so variant 0 is always the default sprite; the spare
## columns at the end of the feature row hold the rest.
const FEATURE_VARIANT_COLS := {
	Terrain.Feature.TREE: [0, 6, 7],
}


static func feature_coords(feature: int, variant: int = 0) -> Vector2i:
	var cols: Array = FEATURE_VARIANT_COLS.get(feature, [])
	if cols.is_empty():
		return Vector2i(feature - 1, FEATURE_ROW)
	return Vector2i(cols[variant % cols.size()], FEATURE_ROW)


## Pick a variant for a cell. A cheap integer hash rather than randi() so the map
## looks identical every time it is drawn — a variant that changes on redraw would
## make the whole ground shimmer.
static func variant_for(x: int, y: int) -> int:
	var h := x * 73856093 ^ y * 19349663
	return absi(h) % VARIANTS


## A second, decorrelated hash for feature variants. Reusing variant_for() would
## make every tree on a given tile-variant pick the same silhouette, reintroducing
## the lattice the variants exist to remove.
static func feature_variant_for(x: int, y: int) -> int:
	var h := x * 40503 ^ y * 51683 ^ (x + y) * 92837111
	return absi(h) % 3
