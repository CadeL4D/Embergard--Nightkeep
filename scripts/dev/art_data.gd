class_name ArtData
extends RefCounted
## The game's art, authored as data.
##
## Sprites where SHAPE matters (trees, ruins, nests, people) are hand-drawn here as
## character maps — one character per pixel, indexed into a shared palette. Ground
## textures, where shape does not matter but tiling does, are generated in the baker
## from tone ramps and motifs instead; hand-stringing 256 pixels of noise produces
## worse results than crafting the noise properly.
##
## One shared palette across everything is the reason it reads as a single game:
## every sprite is limited to these 28 colours, so nothing can drift out of key.
##
## Editing: change a character map here, re-run the baker, done. The baker asserts
## every map is rectangular and the expected size, so a miscounted row fails loudly
## instead of producing silently skewed art.

const PALETTE := {
	# transparency
	"." : Color(0, 0, 0, 0),

	# neutrals / shadow
	"k" : Color("0a0e14"),   # near-black, outlines
	"K" : Color("141b24"),   # deep shadow

	# stone
	"s" : Color("2a2f38"),
	"S" : Color("3e4650"),
	"L" : Color("576170"),

	# earth / wood
	"e" : Color("241d16"),
	"E" : Color("3a2f22"),
	"D" : Color("574632"),

	# water
	"w" : Color("0a1420"),
	"W" : Color("12283c"),
	"A" : Color("1d4258"),

	# sand
	"n" : Color("574a35"),
	"N" : Color("6b5c42"),
	"x" : Color("857349"),

	# vegetation — deliberately muted. The first pass was a clean saturated green
	# that read as a pleasant farming game; this world is supposed to be sick and
	# cold, and firelight has to be the only vivid thing on screen.
	"m" : Color("18261a"),
	"M" : Color("233a27"),
	"G" : Color("324f34"),
	"g" : Color("43653f"),
	"u" : Color("34372a"),   # dead/dry growth

	# blight
	"b" : Color("2e0a1c"),
	"B" : Color("58163a"),
	"P" : Color("8f2456"),

	# firelight
	"o" : Color("c85a1e"),
	"O" : Color("ff9a3c"),
	"Y" : Color("ffd88a"),

	# people
	"f" : Color("b08968"),   # skin
	"c" : Color("6d5f4e"),   # cloth
	"C" : Color("4a4038"),   # cloth shadow
	"r" : Color("7a2f2f"),   # rust / berries
}


# =========================================================================================
# FEATURES — 16x16, drawn over the terrain tile beneath them
# =========================================================================================

## Gnarled broadleaf. Canopy is three tones so it still reads as volume at 1x zoom,
## where a flat silhouette would look like a green hole in the ground.
const TREE := [
	"................",
	"......mmm.......",
	"....mmMMMmm.....",
	"...mMMGGGMMm....",
	"..mMGGgggGGMm...",
	"..mMGgggggGMMm..",
	".mMMGgggggGGMMm.",
	".mMMGGgggGGMMMm.",
	"..mMMGGGGGMMMm..",
	"..mmMMGGGMMMm...",
	"....mmMMMmm.....",
	"......EEE.......",
	"......EEE.......",
	".....eEEEe......",
	"....eeEEEee.....",
	"...meeeeeeem....",
]

## Two more tree silhouettes. A forest of one identical sprite reads as an orchard
## planted on a lattice — the eye picks out the repetition instantly at any zoom.
## Three shapes scattered by position hash is enough to break that up.
const TREE_B := [
	"................",
	".......mm.......",
	"......mMMm......",
	".....mMGGMm.....",
	"....mMGggGMm....",
	"....mGgggGMm....",
	"...mMGgggGGMm...",
	"...mMGGgGGMMm...",
	"....mMGGGGMm....",
	".....mMGGMm.....",
	"......mMMm......",
	".......EE.......",
	".......EE.......",
	"......eEEe......",
	".....eeEEe......",
	"....meeeeem.....",
]

const TREE_C := [
	"................",
	"................",
	"................",
	"....mmmmmm......",
	"..mmMMGGMMmm....",
	".mMMGGggGGMMm...",
	".mMGGgggggGMm...",
	"mMMGgggggGGMMm..",
	"mMMGGgggGGMMMm..",
	".mMMGGGGGMMMm...",
	"..mmMMGGMMmm....",
	"....mmMMmm......",
	"......EE........",
	".....eEEe.......",
	"....eeEEee......",
	"...meeeeeem.....",
]

## Boulder cluster — one large, two small, so quarries read as a worked outcrop
## rather than a single repeated rock.
const STONE := [
	"................",
	"................",
	".....sSSSs......",
	"...sSSLLSSs.....",
	"..sSLLLLLSSs....",
	"..sSLLLSSSSs....",
	"..sSSLSSSSSs....",
	"...sSSSSSSs.....",
	"....ssSSss......",
	"..sSSs..sSSs....",
	".sSLLSs.sSLSs...",
	".sSLLLSssSLSs...",
	".sSSSSSssSSSs...",
	"..sssss..ssss...",
	"................",
	"................",
]

## A standing chunk of masonry with a broken top edge. The first pass tapered
## diagonally to the corner, which read as a ramp or a scree slope rather than a
## wall — and since these block movement, the sprite has to say "wall" instantly.
## Highlight pixels (L) on the upper courses are what separate it from RUIN_FLOOR,
## which is deliberately flat and low-contrast so it recedes underfoot.
const RUIN_WALL := [
	"................",
	"..SS.SSSS..SS...",
	"..SSSSSSSSSSSS..",
	"..SLLSSLLSSLLS..",
	"..SSSSSSSSSSSS..",
	"..sSSSSSSSSSSs..",
	"..SSLLSSLLSSLS..",
	"..SSSSSSSSSSSS..",
	"..sSSSSSSSSSSs..",
	"..SLLSSLLSSLLS..",
	"..SSSSSSSSSSSS..",
	"..sSSSSSSSSSSs..",
	"..SSLLSSLLSSSS..",
	"..SSSSSSSSSSSS..",
	"..ssssssssssss..",
	"................",
]

## Flagstones. Walkable, so it stays low-contrast — a floor should never compete
## with the units standing on it.
const RUIN_FLOOR := [
	"ssssssssssssssss",
	"sSSSSsSSSSSsSSSs",
	"sSSSSsSSSSSsSSSs",
	"sSSSSsSSSSSsSSSs",
	"ssssssssssssssss",
	"sSSSSSSSsSSSSSSs",
	"sSSSSSSSsSSSSSSs",
	"sSSSSSSSsSSSSSSs",
	"ssssssssssssssss",
	"sSSSsSSSSSSsSSSs",
	"sSSSsSSSSSSsSSSs",
	"sSSSsSSSSSSsSSSs",
	"ssssssssssssssss",
	"sSSSSSSsSSSSSSSs",
	"sSSSSSSsSSSSSSSs",
	"ssssssssssssssss",
]

## Blight nest — concentric fleshy rings around a dark maw. The one deliberately
## high-saturation object in the palette, because it is what the player must be
## drawn to attack.
const NEST := [
	"................",
	"......bbb.......",
	"....bbBBBbb.....",
	"...bBBPPPBBb....",
	"..bBPPPPPPPBb...",
	"..bBPPBBBPPBb...",
	".bBPPBbbbBPPBb..",
	".bBPPBbkbBPPBb..",
	".bBPPBbbbBPPBb..",
	"..bBPPBBBPPBb...",
	"..bBPPPPPPPBb...",
	"...bBBPPPBBb....",
	"....bbBBBbb.....",
	"......bbb.......",
	"................",
	"................",
]

const BERRIES := [
	"................",
	"................",
	"......mm........",
	".....mMMm.......",
	"....mMGGMm......",
	"...mMGrGGMm.....",
	"...mGGGrGMm.....",
	"..mMGrGGGGMm....",
	"..mMGGGGrGMm....",
	"...mMGGGGMm.....",
	"....mmGGmm......",
	"......EE........",
	"......eE........",
	".....eee........",
	"................",
	"................",
]


# =========================================================================================
# BUILDINGS — anchored bottom-left, drawn to fill their footprint in tiles
# =========================================================================================
# Lit windows and fires use the firelight ramp (o/O/Y) so that at night the colony
# reads as a constellation of warm points against the dark. That is the same trick
# the Ember relies on, applied to architecture.

## 1x1. Sharpened stakes with a cross-rail. Blocks movement.
const PALISADE := [
	"................",
	"...D..D..D..D...",
	"..DED.DED.DED.D.",
	"..DED.DED.DED.D.",
	"..DED.DED.DED.D.",
	"DDDDDDDDDDDDDDDD",
	"DeDeDeDeDeDeDeDe",
	"DDDDDDDDDDDDDDDD",
	"..DED.DED.DED.D.",
	"..DED.DED.DED.D.",
	"..DED.DED.DED.D.",
	"..DED.DED.DED.D.",
	"..eee.eee.eee.e.",
	"................",
	"................",
	"................",
]

## 1x1. Crates and sacks. Walkable — hauliers need to step onto it.
const STOCKPILE := [
	"................",
	"................",
	"..DDDD..DDDD....",
	"..DEED..DEED....",
	"..DEED..DEED....",
	"..DDDD..DDDD....",
	"................",
	"...DDDDDD.......",
	"...DEEEED.......",
	"...DEEEED.......",
	"...DDDDDD.......",
	"..DDDD..........",
	"..DEED..........",
	"..DDDD..........",
	"................",
	"................",
]

## 2x2. The colony core and the Ember's home — a stone brazier with a live fire.
##
## Sized to actually fill its 2x2 footprint and sat low in the frame. The first
## pass occupied barely half the sprite and floated in the upper-left of its tiles,
## so a finished Hearth read as a small crate rather than the heart of the colony.
const HEARTH := [
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"....ssssssssssssssssssssssss....",
	"....sSSSSSSSSSSSSSSSSSSSSSSs....",
	"....sSLLLLLLLLLLLLLLLLLLLLSs....",
	"....sSLooooooooooooooooooLSs....",
	"....sSLoOOOOOOOOOOOOOOOOoLSs....",
	"....sSLoOOYYYYYYYYYYYYOOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOYYYYYYYYYYYYYYOoLSs....",
	"....sSLoOOYYYYYYYYYYYYOOoLSs....",
	"....sSLoOOOOOOOOOOOOOOOOoLSs....",
	"....sSLooooooooooooooooooLSs....",
	"....sSLLLLLLLLLLLLLLLLLLLLSs....",
	"....sSSSSSSSSSSSSSSSSSSSSSSs....",
	"....ssssssssssssssssssssssss....",
	"....kkkkkkkkkkkkkkkkkkkkkkkk....",
	"................................",
	"................................",
	"................................",
	"................................",
]

## 2x2. Thatched cottage with two lit windows and a dark doorway.
const HUT := [
	"................................",
	"................................",
	".............nnnn...............",
	"...........nnxxxxnn.............",
	".........nnxxxxxxxxnn...........",
	".......nnxxxxxxxxxxxxnn.........",
	".....nnxxxxxxxxxxxxxxxxnn.......",
	"...nnxxxxxxxxxxxxxxxxxxxxnn.....",
	".nnxxxxxxxxxxxxxxxxxxxxxxxxnn...",
	".nNNxxxxxxxxxxxxxxxxxxxxxxNNn...",
	".nnNNNNxxxxxxxxxxxxxxxxNNNNnn...",
	"..nnnNNNNNNNNNNNNNNNNNNNNnnn....",
	"...nnnnnnnnnnnnnnnnnnnnnnnn.....",
	"....EEEEEEEEEEEEEEEEEEEEEEEE....",
	"....EDDDDDDDDDDDDDDDDDDDDDDE....",
	"....EDDDDDDDDDDDDDDDDDDDDDDE....",
	"....EDDDOOODDDDDDDDDDOOODDDE....",
	"....EDDDOOODDDDDDDDDDOOODDDE....",
	"....EDDDOOODDDDDDDDDDOOODDDE....",
	"....EDDDDDDDDDDDDDDDDDDDDDDE....",
	"....EDDDDDDDDDeeeeDDDDDDDDDE....",
	"....EDDDDDDDDDeeeeDDDDDDDDDE....",
	"....EDDDDDDDDDeeeeDDDDDDDDDE....",
	"....EDDDDDDDDDeeeeDDDDDDDDDE....",
	"....EDDDDDDDDDeeeeDDDDDDDDDE....",
	"....EEEEEEEEEEeeeeEEEEEEEEEE....",
	"....eeeeeeeeeeeeeeeeeeeeeeee....",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
]

## 2x2. Stone tower with a timber fighting platform and a lit brazier on top.
const WATCHTOWER := [
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"......DDDDDDDDDDDDDDDDDDDD......",
	"......DEEEEEEEEEEEEEEEEEED......",
	"......DEDDDDDDDDDDDDDDDDED......",
	"......DEEEEEEEEEEEEEEEEEED......",
	"......DDDDDDDDDDDDDDDDDDDD......",
	"......sSSSSSSSSSSSSSSSSSSs......",
	"......sSLLLLLLLLLLLLLLLLSs......",
	"......sSLSSSSSSSSSSSSSSLSs......",
	"......sSLSSOOOOOOOOOOSSLSs......",
	"......sSLSSOOOOOOOOOOSSLSs......",
	"......sSLSSSSSSSSSSSSSSLSs......",
	"......sSLLLLLLLLLLLLLLLLSs......",
	"......sSSSSSSSSSSSSSSSSSSs......",
	"......sSLLLLLLLLLLLLLLLLSs......",
	"......sSSSSSSSSSSSSSSSSSSs......",
	"......sSLLLLLLLLLLLLLLLLSs......",
	"......ssssssssssssssssssss......",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
]


## 2x2. Tilled beds with rows of sprouts. Walkable — farmers work from on top of it.
const FARM := [
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"....eeeeeeeeeeeeeeeeeeeeeeee....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eDDDDDDDDDDDDDDDDDDDDDDe....",
	"....eDggDDggDDggDDggDDggDDDe....",
	"....eDGGDDGGDDGGDDGGDDGGDDDe....",
	"....eeeeeeeeeeeeeeeeeeeeeeee....",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
]


static func building_maps() -> Dictionary:
	return {
		&"palisade": {"map": PALISADE, "size": 16},
		&"stockpile": {"map": STOCKPILE, "size": 16},
		&"hearth": {"map": HEARTH, "size": 32},
		&"hut": {"map": HUT, "size": 32},
		&"watchtower": {"map": WATCHTOWER, "size": 32},
		&"farm": {"map": FARM, "size": 32},
	}


# =========================================================================================
# VILLAGER — 12x14, three facings (side is mirrored for left/right), two walk frames
# =========================================================================================

const VILLAGER_DOWN_0 := [
	"............",
	"....ffff....",
	"...ffffff...",
	"...fkffkf...",
	"...ffffff...",
	"....ffff....",
	"...CCCCCC...",
	"..fCccccCf..",
	"..fCccccCf..",
	"...cccccc...",
	"...CC..CC...",
	"...CC..CC...",
	"...CC..CC...",
	"..kkk..kkk..",
]

const VILLAGER_DOWN_1 := [
	"............",
	"....ffff....",
	"...ffffff...",
	"...fkffkf...",
	"...ffffff...",
	"....ffff....",
	"...CCCCCC...",
	"..fCccccCf..",
	"..fCccccCf..",
	"...cccccc...",
	"...CC..CC...",
	"..CC....CC..",
	"..CC....CC..",
	".kkk....kkk.",
]

const VILLAGER_UP_0 := [
	"............",
	"....CCCC....",
	"...CCCCCC...",
	"...CCCCCC...",
	"...CCCCCC...",
	"....CCCC....",
	"...CCCCCC...",
	"..fCccccCf..",
	"..fCccccCf..",
	"...cccccc...",
	"...CC..CC...",
	"...CC..CC...",
	"...CC..CC...",
	"..kkk..kkk..",
]

const VILLAGER_UP_1 := [
	"............",
	"....CCCC....",
	"...CCCCCC...",
	"...CCCCCC...",
	"...CCCCCC...",
	"....CCCC....",
	"...CCCCCC...",
	"..fCccccCf..",
	"..fCccccCf..",
	"...cccccc...",
	"...CC..CC...",
	"..CC....CC..",
	"..CC....CC..",
	".kkk....kkk.",
]

## Profile view. The head is shifted toward the facing direction and shows a SINGLE
## eye — the first pass kept both eyes and a centred head, so side-on villagers were
## indistinguishable from front-on ones and the whole sheet looked static.
const VILLAGER_SIDE_0 := [
	"............",
	".....ffff...",
	"....ffffff..",
	"....fkffff..",
	"....ffffff..",
	".....ffff...",
	"...CCCCC....",
	"..fCcccC....",
	"..fCcccC....",
	"...ccccc....",
	"....CCC.....",
	"....CC......",
	"...CC.CC....",
	"..kkk.kkk...",
]

const VILLAGER_SIDE_1 := [
	"............",
	".....ffff...",
	"....ffffff..",
	"....fkffff..",
	"....ffffff..",
	".....ffff...",
	"...CCCCC....",
	"..fCcccC....",
	"..fCcccC....",
	"...ccccc....",
	"....CCC.....",
	"...CCC......",
	"..CC..CC....",
	".kkk...kkk..",
]


# =========================================================================================
# THE EMBER — 24x24. The one thing in the game allowed to be bright.
# =========================================================================================

## Round rather than faceted — the first pass was built from straight diagonals and
## read as a cut gem instead of a burning coal. The three tones step outward from a
## pale core so it still looks like it is emitting rather than reflecting.
const EMBER := [
	"........................",
	"........................",
	"........................",
	".........oooooo.........",
	".......oooOOOOooo.......",
	"......ooOOOOOOOOoo......",
	".....ooOOOOYYOOOOoo.....",
	"....ooOOOYYYYYYOOOoo....",
	"....oOOOYYYYYYYYOOOo....",
	"...ooOOYYYYYYYYYYOOoo...",
	"...oOOOYYYYYYYYYYOOOo...",
	"...oOOYYYYYYYYYYYYOOo...",
	"...oOOYYYYYYYYYYYYOOo...",
	"...oOOOYYYYYYYYYYOOOo...",
	"...ooOOYYYYYYYYYYOOoo...",
	"....oOOOYYYYYYYYOOOo....",
	"....ooOOOYYYYYYOOOoo....",
	".....ooOOOOYYOOOOoo.....",
	"......ooOOOOOOOOoo......",
	".......oooOOOOooo.......",
	".........oooooo.........",
	"........................",
	"........................",
	"........................",
]


# =========================================================================================
# Registry — everything the baker writes out as an individual sprite
# =========================================================================================

## name -> {map, path}. Feature sprites are stamped into the tileset atlas instead
## of being written individually, so they are listed separately below.
static func feature_maps() -> Dictionary:
	return {
		Terrain.Feature.TREE: TREE,
		Terrain.Feature.STONE: STONE,
		Terrain.Feature.RUIN_WALL: RUIN_WALL,
		Terrain.Feature.RUIN_FLOOR: RUIN_FLOOR,
		Terrain.Feature.NEST: NEST,
		Terrain.Feature.BERRIES: BERRIES,
	}


## Alternate silhouettes for a feature type, in the order TileAtlas expects. Only
## trees have them so far — they are the only feature dense enough for repetition
## to be obvious.
static func feature_variants() -> Dictionary:
	return {
		Terrain.Feature.TREE: [TREE, TREE_B, TREE_C],
	}


# =========================================================================================
# MONSTERS — 12x14, two frames, no facings (mirrored via flip_h)
# =========================================================================================
# Built from the blight ramp so they read instantly as the same corruption eating
# the map. Villagers are warm browns and skin; monsters are cold magenta and black.
# At 12px that colour split is doing almost all the work of telling them apart.

## Slow melee swarm. Hunched, top-heavy, with a bright core that catches the eye in
## the dark — you should be able to count them at a glance during a night assault.
const SHAMBLER_0 := [
	"............",
	"...bbbb.....",
	"..bBBBBb....",
	"..bBPPBb....",
	"..bBBBBb....",
	"...bbbb.....",
	"..bBBBBBb...",
	".bBBPPPBBb..",
	".bBBPPPBBb..",
	"..bBBBBBb...",
	"..bB...Bb...",
	"..bB...Bb...",
	"..bb...bb...",
	".kk.....kk..",
]

const SHAMBLER_1 := [
	"............",
	"...bbbb.....",
	"..bBBBBb....",
	"..bBPPBb....",
	"..bBBBBb....",
	"...bbbb.....",
	"..bBBBBBb...",
	".bBBPPPBBb..",
	".bBBPPPBBb..",
	"..bBBBBBb...",
	".bB.....Bb..",
	".bB.....Bb..",
	".bb.....bb..",
	"kk.......kk.",
]

## Fragile ranged attacker — a bulbous sac with a dark maw. Smaller silhouette than
## the Shambler so the two are distinguishable purely by shape at gameplay zoom.
const SPITTER_0 := [
	"............",
	"............",
	"....bbbb....",
	"...bBBBBb...",
	"..bBPPPPBb..",
	"..bPPkkPPb..",
	"..bPPkkPPb..",
	"..bBPPPPBb..",
	"...bBBBBb...",
	"....bbbb....",
	"...b.b.b....",
	"..b..b..b...",
	"..k..k..k...",
	"............",
]

const SPITTER_1 := [
	"............",
	"............",
	"....bbbb....",
	"...bBBBBb...",
	"..bBPPPPBb..",
	"..bPPkkPPb..",
	"..bPPkkPPb..",
	"..bBPPPPBb..",
	"...bBBBBb...",
	"....bbbb....",
	"..b.b.b.....",
	".b..b..b....",
	".k..k..k....",
	"............",
]


static func monster_frames() -> Dictionary:
	return {
		&"shambler": [SHAMBLER_0, SHAMBLER_1],
		&"spitter": [SPITTER_0, SPITTER_1],
	}


static func villager_frames() -> Dictionary:
	return {
		"down_0": VILLAGER_DOWN_0,
		"down_1": VILLAGER_DOWN_1,
		"up_0": VILLAGER_UP_0,
		"up_1": VILLAGER_UP_1,
		"side_0": VILLAGER_SIDE_0,
		"side_1": VILLAGER_SIDE_1,
	}


static func color_of(ch: String) -> Color:
	return PALETTE.get(ch, Color.MAGENTA)     # magenta = "you typo'd a palette key"
