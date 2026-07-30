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
##   rows 7..22  = connected forest masks (eight edge/texture variants)
##   rows 23..38 = connected stone masks (eight edge/texture variants)
##   row 39      = cosmetic ground dressing
##   row 40      = compact berry-shrub variants
##
## VARIANTS exist because a single tile per material makes large areas read as an
## obvious repeating grid — the eye locks onto the identical noise instantly. Three
## variants scattered by a position hash breaks that up for three times the atlas
## space and no runtime cost.

const COLUMNS := 8
const ROWS := 41
const TILE := 16
const VARIANTS := 3

const FEATURE_ROW := 3

## Sixteen cardinal masks need two atlas rows per visual variant. Berry bushes are
## intentionally absent: even adjacent berry cells remain separate low shrubs with
## visible ground around them rather than merging into another terrain mass.
const CONNECTED_FEATURE_ROWS := {
	Terrain.Feature.TREE: 7,
	Terrain.Feature.STONE: 23,
}
const CONNECTED_FEATURE_VARIANTS := {
	Terrain.Feature.TREE: 8,
	Terrain.Feature.STONE: 8,
}

const MASK_NORTH := 1
const MASK_EAST := 2
const MASK_SOUTH := 4
const MASK_WEST := 8


static func is_connected_feature(feature: int) -> bool:
	return CONNECTED_FEATURE_ROWS.has(feature)


static func connected_variant_count(feature: int) -> int:
	return CONNECTED_FEATURE_VARIANTS.get(feature, 1)


static func connected_coords(feature: int, mask: int, variant: int = 0) -> Vector2i:
	var base_row: int = CONNECTED_FEATURE_ROWS.get(feature, 7)
	var safe_mask := mask & 15
	var variant_count := connected_variant_count(feature)
	return Vector2i(
		safe_mask % COLUMNS,
		base_row + posmod(variant, variant_count) * 2 + safe_mask / COLUMNS
	)

## Purely visual ground dressing. These never enter World.feature, never block a
## path, and never become a harvest target. Keeping them in their own TileMapLayer
## lets the map look inhabited and textural without quietly changing the sim.
const DECOR_ROW := 39
const DECOR_COUNT := 8


static func decor_coords(index: int) -> Vector2i:
	return Vector2i(posmod(index, DECOR_COUNT), DECOR_ROW)

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
const BERRY_VARIANT_COORDS: Array[Vector2i] = [
	Vector2i(5, FEATURE_ROW), Vector2i(0, 40), Vector2i(1, 40),
]


static func feature_coords(feature: int, variant: int = 0) -> Vector2i:
	if feature == Terrain.Feature.BERRIES:
		return BERRY_VARIANT_COORDS[posmod(variant, BERRY_VARIANT_COORDS.size())]
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
	return absi(h)


## Connected variants are decorrelated from the ground and mixed above the low
## parity bits. Eight possibilities give long exposed borders substantially more
## silhouette variation without changing any simulation data.
static func connected_variant_for(x: int, y: int, feature: int) -> int:
	var h := absi(x * 73856093 ^ y * 19349663 ^ feature * 83492791)
	h ^= h >> 11
	return h % connected_variant_count(feature)
