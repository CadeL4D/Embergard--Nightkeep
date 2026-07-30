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
	"k" : Color("090d13"),   # near-black, outlines
	"K" : Color("18212c"),   # deep shadow

	# stone
	"s" : Color("313945"),
	"S" : Color("4b5663"),
	"L" : Color("6b7888"),
	# Warm exposed-rock ramp. Natural ridges use this rather than the colder
	# dressed-stone ramp above, matching the earthier plateaus in the reference.
	"q" : Color("241f1a"),
	"Q" : Color("665847"),
	"H" : Color("9a866c"),

	# earth / wood
	"e" : Color("281f16"),
	"E" : Color("443423"),
	"D" : Color("684e32"),

	# water
	"w" : Color("0a1928"),
	"W" : Color("16354b"),
	"A" : Color("28627c"),

	# sand
	"n" : Color("625039"),
	"N" : Color("7b6748"),
	"x" : Color("a08756"),

	# vegetation — deliberately muted. The first pass was a clean saturated green
	# that read as a pleasant farming game; this world is supposed to be sick and
	# cold, and firelight has to be the only vivid thing on screen.
	"m" : Color("1a2b1d"),
	"M" : Color("29462e"),
	"G" : Color("3d633f"),
	"g" : Color("568151"),
	# Connected woods use their own deeper ramp. Grass deliberately uses M/G,
	# so sharing those colours made a forest read as decorated ground instead of
	# a raised canopy mass.
	"v" : Color("102217"),
	"V" : Color("1b3823"),
	"j" : Color("32643b"),
	"J" : Color("4e8150"),
	"u" : Color("484834"),   # dead/dry growth

	# blight
	"b" : Color("2e0a1c"),
	"B" : Color("58163a"),
	"P" : Color("8f2456"),

	# firelight
	"o" : Color("c85a1e"),
	"O" : Color("ff9a3c"),
	"Y" : Color("ffd88a"),

	# people
	"f" : Color("c09672"),   # skin
	"c" : Color("786957"),   # cloth
	"C" : Color("50463d"),   # cloth shadow
	"r" : Color("913d3b"),   # rust / berries
	"R" : Color("c95750"),   # ripe berry highlight
}


# =========================================================================================
# GROUND DRESSING — visual detail with no simulation footprint
# =========================================================================================
#
# Eight sparse overlays share one atlas row. WorldView scatters them by a stable
# position hash only where there is no real feature, so clear land no longer reads
# as a flat checkerboard while every tree, stone and berry remains mechanically
# honest.

const DECOR_GRASS := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	".....m..........",
	"....mGm.........",
	".....m..........",
	".........m......",
	"........mGm.....",
	".........m......",
	"................",
]

const DECOR_WEED := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"..........u.....",
	".........u.u....",
	"..........u.....",
	".........e......",
	".........e......",
	"................",
	"...u............",
	"..ueu...........",
	"................",
]

const DECOR_STONES := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"....s...........",
	"...sSs..........",
	"....ss..........",
	"..........s.....",
	".........sLs....",
	"..........s.....",
	"................",
]

const DECOR_CRACK := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"...e............",
	"..e.E...........",
	".e...e..........",
	".....e..........",
	".....E.e........",
	"........e.......",
	"................",
	"................",
	"................",
]

const DECOR_SAND := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"..xx............",
	"................",
	"......xxx.......",
	"................",
	"............xx..",
	"................",
	"................",
	"................",
	"................",
	"................",
]

const DECOR_WATER := [
	"................",
	"................",
	"...AAA..........",
	"................",
	"..........ww....",
	"................",
	"................",
	".......AA.......",
	"................",
	"................",
	"...........AAA..",
	"................",
	"................",
	"................",
	"................",
	"................",
]

const DECOR_RUBBLE := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"...s............",
	"..sSL...........",
	"...ss.....L.....",
	"..........Ss....",
	"................",
	"......s.........",
	".....sSs........",
	"................",
	"................",
]

const DECOR_FLOWERS := [
	"................",
	"................",
	"................",
	"................",
	"................",
	"................",
	"........G.......",
	".......GrG......",
	"........m.......",
	"........m.......",
	"................",
	"...G............",
	"..GrG...........",
	"...m............",
	"................",
	"................",
]


static func decor_maps() -> Array:
	return [
		DECOR_GRASS, DECOR_WEED, DECOR_STONES, DECOR_CRACK,
		DECOR_SAND, DECOR_WATER, DECOR_RUBBLE, DECOR_FLOWERS,
	]


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
	"................",
	".....vvvv.......",
	"...vvVVVVvv.....",
	"..vVjRjJVv......",
	"..vVJjRJJVv.....",
	"...vVjRjVv......",
	"....vvVvv.......",
	"......EE........",
	"......eE........",
	".....eee........",
	"................",
	"................",
	"................",
	"................",
]

const BERRIES_B := [
	"................",
	"................",
	"................",
	".......vv.......",
	".....vvVVvv.....",
	"....vVJRjVv.....",
	"...vVjJRVVv.....",
	"....vVRjVv......",
	".....vvVv.......",
	"......EE........",
	"......eE........",
	".....eee........",
	"................",
	"................",
	"................",
	"................",
]

const BERRIES_C := [
	"................",
	"................",
	"................",
	"....vvvvvv......",
	"..vvVVjjVVvv....",
	".vVjRJjRjJVv....",
	".vVJjRJJjRVv....",
	"..vVjJjJVv......",
	"...vvVVvv.......",
	".....E..E.......",
	".....E..E.......",
	"....ee..ee......",
	"................",
	"................",
	"................",
	"................",
]


# =========================================================================================
# DENSE FEATURE INTERIORS — the inside of a wood, a rock field, a thicket
# =========================================================================================
# Resources are generated in clumps, and a clump of individually-outlined sprites reads as a
# lattice of objects rather than as a MASS. So a cell whose four neighbours share its feature is
# painted with one of these instead: full-bleed texture, no outline, no transparency, tiling
# seamlessly with its neighbours. The outlined sprites are kept for the rim.
#
# Two states rather than the sixteen a full neighbour-mask autotile would need, which would have
# been 48 new tiles across three features. Interior-versus-edge captures what actually matters —
# solid middle, ragged border — for three.

## 16x16. The INTERIOR of a wood — canopy only, no silhouette, no outline, no transparency.
##
## Four of these side by side merge into one unbroken mass, which is the whole point: a forest
## should read as a solid thing the colony eats into, not as a lattice of individual trees. All the
## shape lives in the ordinary TREE tiles, which the renderer keeps for the RIM of the mass.
##
## It maintains itself as the wood is felled: clearing an interior cell turns its neighbours into
## edges on the next repaint, so the hole the player cuts has a ragged border for free.
const TREE_DENSE := [
	"GgGMGGgGMGgGGMgG",
	"gGgGMGgGGMgGGgGM",
	"GMGgGGMgGgGGMGgG",
	"MGgGGgGMGGgGgGGM",
	"GgGMGgGGMGgGMGgG",
	"gGGgGMGgGGMGgGGM",
	"GMGgGGgGMGGgGMgG",
	"gGgGMGGgGgGMGgGG",
	"GgGGgGMGgGGMGGgM",
	"MGgGMGgGGMgGgGGG",
	"GgGGgGGMGgGMGgGM",
	"gGMGgGMgGGgGGMgG",
	"GGgGGgGGMGgGgGGM",
	"MGgGMGgGMGGMGgGg",
	"GgGGgGMGgGGgGMGG",
	"gGMGgGGgGMGgGGgM",
]


## 16x16. The interior of a rock field. Same idea as TREE_DENSE — see there for why.
const STONE_DENSE := [
	"SLSSLSSLLSSLSSLS",
	"LSSLLSSLSSLLSSLL",
	"SSLSSLLSSLSSLSSL",
	"LLSSLSSLSSLLSSLS",
	"SLSSLLSSLLSSLSSL",
	"SSLLSSLSSLSSLLSS",
	"LSSLSSLLSSLLSSLS",
	"SLLSSLSSLSSLSSLL",
	"SSLSSLLSSLLSSLSS",
	"LSSLLSSLSSLSSLLS",
	"SLSSLSSLLSSLLSSL",
	"LLSSLLSSLSSLSSLS",
	"SSLSSLSSLLSSLLSS",
	"LSSLLSSLLSSLSSLL",
	"SLLSSLSSLSSLLSSL",
	"SSLSSLLSSLLSSLSS",
]


## Legacy berry-thicket comparison tile. Runtime berries now always use the
## smaller BERRIES/BERRIES_B/BERRIES_C shrub silhouettes above.
const BERRIES_DENSE := [
	"GgGMGrGGMGgGGMgG",
	"gGgGMGgGrMgGGgGM",
	"GMGgGrMgGgGGMGgG",
	"MGgGGgGMGGgGrGGM",
	"GgGMGgGrMGgGMGgG",
	"gGGgGMGgGGMGrGGM",
	"GrGgGGgGMGGgGMgG",
	"gGgGMGGgGgGMGgGr",
	"GgGGgGrGgGGMGGgM",
	"MGgGMGgGGMgGgGGG",
	"GgGGgGGMGrGMGgGM",
	"gGMGgGMgGGgGGMgG",
	"GGgGGgGrMGgGgGGM",
	"MGgGMGgGMGGMGgGg",
	"GgGGgGMGgGGgGMGG",
	"gGMGrGGgGMGgGGgM",
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

## 1x1. Slots into a palisade run, so it has to read as a GATE at a glance rather than
## as another stretch of wall — a player who cannot see where their gate is cannot
## defend it. Palisade is vertical stakes in bare wood; this is deliberately the
## opposite: heavy stone posts either side, horizontal banded timber between them.
const GATE := [
	"................",
	".LL..........LL.",
	".LSL........LSL.",
	".LSL.DDDDDD.LSL.",
	".LSL.DeeeeD.LSL.",
	".LSLDDDDDDDDLSL.",
	".LSL.DeeeeD.LSL.",
	".LSLDDDDDDDDLSL.",
	".LSL.DeeeeD.LSL.",
	".LSL.DDDDDD.LSL.",
	".LSL........LSL.",
	".LSL........LSL.",
	".LsL........LsL.",
	"..ee........ee..",
	"................",
	"................",
]

## 1x1. Stone ring with a dark shaft and a timber winch. Walkable, so villagers can stand
## on it to drink, and it has to read as water at a glance against the stockpile beside it —
## hence the cool blue in the shaft where every other building is wood and stone.
const WELL := [
	"................",
	"................",
	"....LSSSSL......",
	"...LSwwwwSL.....",
	"...LSwAAwSL.....",
	"...LSwwwwSL.....",
	"...LSSSSSSL.....",
	"....LLSSLL......",
	"....D....D......",
	"....D....D......",
	"....DDDDDD......",
	".....E..E.......",
	"................",
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


# =========================================================================================
# PROCESSING BUILDINGS — deliberately NOT square
# =========================================================================================
#
# Every building was 2x2, which made the colony a grid-packing exercise with one piece shape.
# Long rectangles are what make layout an actual puzzle: a 3x2 sawmill does not slot into the
# gap a 2x3 stonecutter leaves, so a colony has to be planned rather than tiled.
#
# They also read better. A sawmill is a long shed with a saw pit; a stonecutter is a tall yard
# with a crane. Shape carries function at a glance, which matters more than usual here because
# every building shares one muted palette.

## 3x2 = 48x32. Long low shed, open front, saw pit and a stack of cut boards.
const SAWMILL := [
	"................................................",
	"..........DDDDDDDDDDDDDDDDDDDDDDDD..............",
	".........DEEEEEEEEEEEEEEEEEEEEEEEED.............",
	"........DEEDDDDDDDDDDDDDDDDDDDDDEEED............",
	".......DEEDeeeeeeeeeeeeeeeeeeeeeeDEEED..........",
	"......DEEDeeDDDDDDDDDDDDDDDDDDDDeeDEEED.........",
	"DDDDDDEEDeeDEEEEEEEEEEEEEEEEEEEEDeeDEEDDDDDDDDD.",
	"DEEEEEEEDeeDEEDDDDDDDDDDDDDDDDEEDeeDEEEEEEEEEED.",
	"DEEDDDDDDeeDEEDeeeeeeeeeeeeeeDEEDeeDDDDDDDDDEED.",
	"DEEDeeeeeeeeDEEDeeLLLLLLLLLLeeDEEDeeeeeeeeeeEED.",
	"DEEDeeDDDDDDDEEDeeLSSSSSSSSLeeDEEDDDDDDDDDDDEED.",
	"DEEDeeDEEEEEEEEDeeLSsssssssLeeDEEEEEEEEEEEEDEED.",
	"DEEDeeDEEDDDDDDDeeLSsssssssLeeDDDDDDDDDDDEEDEED.",
	"DEEDeeDEEDeeeeeeeeLSsssssssLeeeeeeeeeeeeDEEDEED.",
	"DEEDeeDEEDeeDDDDDDLSSSSSSSSLDDDDDDDDDDeeDEEDEED.",
	"DEEDeeDEEDeeDEEEEELLLLLLLLLLEEEEEEEEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDDDDDDDDDDDDDDDDDDDDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeeeeeeeeeeeeeeeeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDDDDDDDDDDDDDDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEEEEEEEEEEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEDDDDDDDDEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEDeeeeeeDEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEDeeeeeeDEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEDeeeeeeDEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEDDDDDDDDEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDEEEEEEEEEEEEDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeDDDDDDDDDDDDDDeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDeeeeeeeeeeeeeeeeeeDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEDDDDDDDDDDDDDDDDDDDDEEDeeDEEDEED.",
	"DEEDeeDEEDeeDEEEEEEEEEEEEEEEEEEEEEEEEDeeDEEDEED.",
	"DeeDeeDeeDeeDDDDDDDDDDDDDDDDDDDDDDDDDDeeDeeDeeD.",
	"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk.",
]

## 2x3 = 32x48. Tall stone yard: a crane frame over a cutting floor with dressed blocks stacked.
const STONECUTTER := [
	"................................",
	".........LLLLLLLLLLLLLL.........",
	"........LSSSSSSSSSSSSSSL........",
	"........LSssssssssssssSL........",
	"........LSsLLLLLLLLLLsSL........",
	"........LSsLSSSSSSSSLsSL........",
	"........LSsLSssssssSLsSL........",
	"........LSsLSsLLLLsSLsSL........",
	"........LSsLSsLssLsSLsSL........",
	"........LSsLSsLssLsSLsSL........",
	"........LSsLSsLLLLsSLsSL........",
	"........LSsLSssssssSLsSL........",
	"........LSsLSSSSSSSSLsSL........",
	"........LSsLLLLLLLLLLsSL........",
	"........LSssssssssssssSL........",
	"........LSSSSSSSSSSSSSSL........",
	"........LLLLLLLLLLLLLLLL........",
	"..........L..........L..........",
	"..........L..........L..........",
	"..........L..........L..........",
	"..LLLLLLLLLLLLLLLLLLLLLLLLLLLL..",
	".LSSSSSSSSSSSSSSSSSSSSSSSSSSSSL.",
	".LSsssssssssssssssssssssssssssL.",
	".LSsLLLLLLLLLLLLLLLLLLLLLLLLsSL.",
	".LSsLSSSSSSSSSSSSSSSSSSSSSSLsSL.",
	".LSsLSssssssssssssssssssssSLsSL.",
	".LSsLSsLLLLLLLLLLLLLLLLLLsSLsSL.",
	".LSsLSsLSSSSSSSSSSSSSSSSLsSLsSL.",
	".LSsLSsLSssssssssssssssSLsSLsSL.",
	".LSsLSsLSsLLLLLLLLLLLLsSLsSLsSL.",
	".LSsLSsLSsLSSSSSSSSSSLsSLsSLsSL.",
	".LSsLSsLSsLSssssssssSLsSLsSLsSL.",
	".LSsLSsLSsLSssssssssSLsSLsSLsSL.",
	".LSsLSsLSsLSSSSSSSSSSLsSLsSLsSL.",
	".LSsLSsLSsLLLLLLLLLLLLsSLsSLsSL.",
	".LSsLSsLSssssssssssssssSLsSLsSL.",
	".LSsLSsLSSSSSSSSSSSSSSSSLsSLsSL.",
	".LSsLSsLLLLLLLLLLLLLLLLLLsSLsSL.",
	".LSsLSssssssssssssssssssssSLsSL.",
	".LSsLSSSSSSSSSSSSSSSSSSSSSSLsSL.",
	".LSsLLLLLLLLLLLLLLLLLLLLLLLLsSL.",
	".LSssssssssssssssssssssssssssSL.",
	".LSSSSSSSSSSSSSSSSSSSSSSSSSSSSL.",
	".LLLLLLLLLLLLLLLLLLLLLLLLLLLLLL.",
	".ss..ss..ss..ss..ss..ss..ss..ss.",
	".LL..LL..LL..LL..LL..LL..LL..LL.",
	"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk.",
	"................................",
]

## 3x2 = 48x32. Workshop with a lit forge mouth, an anvil, and a rack of finished tools.
const TOOLSMITH := [
	"................................................",
	"................................................",
	"................................................",
	"................................................",
	"....DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD....",
	"....DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED....",
	"...DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED...",
	"..DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED..",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEooooooooooooooooooooooEEEEEEEEEED...",
	".DEEEEEEEEEEoOoOoOoOoOoOoOoOoOoOoOEEEEEEEEEED...",
	".DEEEEEEEEEEoOYYYYYYYYYYYYYYYYYYOoEEEEEEEEEED...",
	".DEEEEEEEEEEoOYYYYYYYYYYYYYYYYYYOoEEEEEEEEEED...",
	".DEEEEEEEEEEoOoOoOoOoOoOoOoOoOoOoOEEEEEEEEEED...",
	".DEEEEEEEEEEooooooooooooooooooooooEEEEEEEEEED...",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEED.",
	".DeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeD.",
	".DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD.",
	"........LLLLLLLLLL..............................",
	"........LSSSSSSSSL..............................",
	"........LSssssssSL..............................",
	"........LSSSSSSSSL..............................",
	"........LLLLLLLLLL..............................",
	"..........................LssLssLssL............",
	"..........................LL..LL..LL............",
	"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk",
]


# =========================================================================================
# PHASE 2 STRUCTURES — upgrade tiers, the Temple line, and road surfaces
# =========================================================================================
# The three Village Center tiers and the three Temple tiers each share a footprint, because
# upgrading in place requires it (see Building.begin_upgrade). So the progression is carried by
# silhouette and by LIGHT — every tier throws more of it — rather than by getting wider.

## 1x1. A trodden dirt track. Lowers move cost, so villagers prefer it exactly as much as
## it saves them — see World.PATH_COST.
const PATH := [
	"NnNNnNnnNNnNNnNn",
	"nNNnNNnNnNnNNnNN",
	"NnNxNnNNnNxNnNnN",
	"nNNnNnxNNnNnNNnN",
	"NNnNNnNnNxNNnNNn",
	"nNxNnNNnNNnNnNxN",
	"NnNNnNxNnNnNNnNN",
	"nNnNNnNnNNxNnNnN",
	"NNnNxNnNNnNnNNnN",
	"nNnNnNNnNxNNnNxN",
	"NnNNnNnNnNnNNnNN",
	"nNxNnNxNNnNnNnNn",
	"NnNnNNnNnNxNNnNN",
	"nNNnNnNNnNnNnNxN",
	"NnNNnNxNnNNnNNnN",
	"nNnNnNNnNxNnNnNn",
]


## 1x1. Dressed stone, laid in courses. The fastest surface in the game.
const ROAD := [
	"LSSLSSLSSLSSLSSL",
	"LSSLSSLSSLSSLSSL",
	"ssssssssssssssss",
	"SLSSLSSLSSLSSLSS",
	"SLSSLSSLSSLSSLSS",
	"ssssssssssssssss",
	"LSSLSSLSSLSSLSSL",
	"LSSLSSLSSLSSLSSL",
	"ssssssssssssssss",
	"SLSSLSSLSSLSSLSS",
	"SLSSLSSLSSLSSLSS",
	"ssssssssssssssss",
	"LSSLSSLSSLSSLSSL",
	"LSSLSSLSSLSSLSSL",
	"ssssssssssssssss",
	"SLSSLSSLSSLSSLSS",
]


## 2x2. Village Center tier 2, upgraded in place from the Hearth.
##
## Deliberately the Hearth grown rather than a different building: same firelight core, same
## stone footing, now with a raised roof and a doorway. An upgrade that changes silhouette
## entirely reads as the old building being replaced, which is not what happened.
const GREAT_HALL := [
	"................................",
	"..............kk................",
	".............kOOk...............",
	"............kYOOYk..............",
	"...........kkYOYkk..............",
	".........kkkkkkkkkkk............",
	".......kkDDDDDDDDDDDkk..........",
	"....kkkDDEEEEEEEEEEEDDkkk.......",
	"..kkDDDEEEeeeeeeeeeEEEDDDkk.....",
	".kDDDEEEeeeEEEEEEEeeeEEEDDDk....",
	"kDDEEEeeeEEEDDDDDEEEeeeEEEDDk...",
	"kDEEeeeEEEDDDDDDDDDEEEeeeEEDDk..",
	"kEEeeEEEDDDDDDDDDDDDDEEEeeEEDk..",
	"kDDDDDDDDDDDDDDDDDDDDDDDDDDDDk..",
	"kEDDDDDDDDDDDDDDDDDDDDDDDDDDEk..",
	"kEDDDDDDDDDDDDDDDDDDDDDDDDDDEk..",
	".kEEDDDDDDDDDDDDDDDDDDDDDDDEEk..",
	".kSSSSSSSSSSSSSSSSSSSSSSSSSSSk..",
	".kSLLSSSSSSSSSSSSSSSSSSSSLLSSk..",
	".kSLYLSSSSSkkkkkkkkSSSSSLYLSSk..",
	".kSLOLSSSSkDDDDDDDDkSSSSLOLSSk..",
	".kSLOLSSSSkDeeeeeeDkSSSSLOLSSk..",
	".kSLoLSSSSkDeYYYYeDkSSSSLoLSSk..",
	".kSSSSSSSSkDeYOOYeDkSSSSSSSSSk..",
	".kSSSSSSSSkDeYOOYeDkSSSSSSSSSk..",
	".kSSSSSSSSkDeeOOeeDkSSSSSSSSSk..",
	".kSsSSSSSSkDDeooeDDkSSSSSSSsSk..",
	".kSsSSSSSSSkDeooeDkSSSSSSSSsSk..",
	".kSsSSSSSSSkkeooekkSSSSSSSSsSk..",
	".kssssssssssseooesssssssssssSk..",
	"..kkkkkkkkkkkkeekkkkkkkkkkkkk...",
	"................................",
]


## 2x2. Village Center tier 3. Battlements, corner braziers, a barred gate.
##
## The keep is the one building the player will look at for six hours, so it carries the most
## firelight of anything in the colony — four lit points plus the gate, which at night makes the
## centre of the settlement read as the safest place on the map.
const STONE_KEEP := [
	"................................",
	"...kk......................kk...",
	"..kOOk....................kOOk..",
	"..kYYk....................kYYk..",
	".kkSSkk..................kkSSkk.",
	".kSLLSk..................kSLLSk.",
	".kSLLSkkkkkkkkkkkkkkkkkkkkSLLSk.",
	".kSLLSSLLSSLLSSLLSSLLSSLLSSLLSk.",
	".kSLLSSLLSSLLSSLLSSLLSSLLSSLLSk.",
	".kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk.",
	".kSssSSSSSSSSSSSSSSSSSSSSSSssSk.",
	".kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk.",
	".kSLLSSSkkkkSSSSSSSSkkkkSSSLLSk.",
	".kSLYLSSkOOkSSSSSSSSkOOkSSSLYLk.",
	".kSLOLSSkYYkSSSSSSSSkYYkSSSLOLk.",
	".kSLOLSSkooKSSSSSSSSkooKSSSLOLk.",
	".kSLoLSSSkkSSSSSSSSSSkkSSSSLoLk.",
	".kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk.",
	".kSssSSSSSSSSSSSSSSSSSSSSSSssSk.",
	".kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk.",
	".kSSSSSSSSSSkkkkkkkkSSSSSSSSSSk.",
	".kSSSSSSSSSkSSSSSSSSkSSSSSSSSSk.",
	".kSLLSSSSSkSSLLLLLLSSkSSSSSLLSk.",
	".kSLYLSSSSkSLYYYYYYLSkSSSSLYLSk.",
	".kSLOLSSSSkSLYOOOOYLSkSSSSLOLSk.",
	".kSLOLSSSSkSLYOOOOYLSkSSSSLOLSk.",
	".kSLoLSSSSkSLLOOOOLLSkSSSSLoLSk.",
	".kSSSSSSSSkSSLLooLLSSkSSSSSSSSk.",
	".kSssSSSSSkSSSLooLSSSkSSSSSssSk.",
	".kSSSSSSSSkSSSeooeSSSkSSSSSSSSk.",
	".kssssssssssssseeesssssssssssssk",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkkkk..",
]


## 2x2. Housing tier 2, upgraded in place from a Hut. Twice the beds.
##
## Three lit windows instead of the Hut's one, which is the whole point of it: at night the
## difference between a colony that has housed its people and one that has not should be
## visible from across the map without opening a panel.
const LONGHOUSE := [
	"................................",
	"................................",
	"..............kk................",
	".............kEEk...............",
	"...........kkkEEkkk.............",
	"........kkkDDDDDDDDDkkk.........",
	".....kkkDDDEEEEEEEEEDDDkkk......",
	"...kkDDDEEEeeeeeeeeeEEEDDDkk....",
	"..kDDDEEEeeEEEEEEEEEeeEEEDDDk...",
	"..kDEEEeeEEEDDDDDDDEEEeeEEEDk...",
	"..kEEeeEEEDDDDDDDDDDDEEEeeEEk...",
	"..kDDDDDDDDDDDDDDDDDDDDDDDDDk...",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDEk...",
	"..kEEDDDDDDDDDDDDDDDDDDDDDEEk...",
	"..kEEEDDDDDDDDDDDDDDDDDDDEEEk...",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEk...",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDEk...",
	"..kEDkkkkDDDkkkkDDDkkkkDDDDEk...",
	"..kEDkYYkDDDkYYkDDDkYYkDDDDEk...",
	"..kEDkOOkDDDkOOkDDDkOOkDDDDEk...",
	"..kEDkooKDDDkooKDDDkooKDDDDEk...",
	"..kEDkkkkDDDkkkkDDDkkkkDDDDEk...",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDEk...",
	"..kEDDDDDDDkkkkkkDDDDDDDDDDEk...",
	"..kEDDDDDDDkEEEEkDDDDDDDDDDEk...",
	"..kEDDDDDDDkeYYekDDDDDDDDDDEk...",
	"..kEEDDDDDDkeOOekDDDDDDDDDEEk...",
	"..kEEEDDDDDkeOOekDDDDDDDDEEEk...",
	"..kSSSSSSSSSeooeSSSSSSSSSSSSk...",
	"..kSsSsSsSsSeooeSsSsSsSsSsSSk...",
	"..kssssssssseeesssssssssssssk...",
	"...kkkkkkkkkkkkkkkkkkkkkkkkk....",
]


## 2x3. Temple tier 1 — the Shrine. One priest, one Tome slot.
##
## Tall and narrow rather than square, both because the divine buildings should not look like
## workshops and because a 2x3 is genuinely awkward to pack, which is the point of having
## non-square footprints at all.
const SHRINE := [
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"..............kk................",
	".............kYYk...............",
	".............kOOk...............",
	"............kkooKk..............",
	"...........kkSSSSkk.............",
	"..........kSSLLLLSSk............",
	".........kSSLLLLLLSSk...........",
	"........kSSLLSSSSLLSSk..........",
	"........kSLLSSSSSSLLSk..........",
	"........kSLSSSSSSSSLSk..........",
	"........kSSSSSSSSSSSSk..........",
	"........kSsSSSSSSSSsSk..........",
	"........kSSSSSSSSSSSSk..........",
	".......kkSSSSSSSSSSSSkk.........",
	"......kSSLLSSSSSSSSLLSSk........",
	".....kSSLLLLSSSSSSLLLLSSk.......",
	"....kSSLLSSLLSSSSLLSSLLSSk......",
	"....kSLLSSSSLLSSLLSSSSLLSk......",
	"....kSLSSSSSSLLLLSSSSSSLSk......",
	"....kSSSSSSSSSSSSSSSSSSSSk......",
	"....kSsSSSSSSSSSSSSSSSSsSk......",
	"....kSSSSSSSSSSSSSSSSSSSSk......",
	"....kSSSSSSkkkkkkkkSSSSSSk......",
	"....kSSSSSkSLLLLLLSkSSSSSk......",
	"....kSSSSSkSLYYYYLSkSSSSSk......",
	"....kSLLSSkSLYOOYLSkSSLLSk......",
	"....kSLYLSkSLYOOYLSkSLYLSk......",
	"....kSLOLSkSLLOOLLSkSLOLSk......",
	"....kSLoLSkSSLOOLSSkSLoLSk......",
	"....kSSSSSSkSLooLSkSSSSSSk......",
	"....kSsSSSSkSLooLSkSSSSsSk......",
	"....kSSSSSSSkeooekSSSSSSSk......",
	"....kSSSSSSSkeooekSSSSSSSk......",
	"....kSsSsSsSSeooeSSsSsSsSk......",
	"....kSSSSSSSSeooeSSSSSSSSk......",
	"....ksssssssseeeessssssssk......",
	"....kkkkkkkkkkkkkkkkkkkkkk......",
	"................................",
	"................................",
]


## 2x3. Temple tier 2. Three priests, two Tome slots, a taller spire and four lit windows.
const TEMPLE := [
	"................................",
	"................................",
	"..............kk................",
	".............kYYk...............",
	".............kOOk...............",
	".............kOOk...............",
	"............kkooKk..............",
	"...........kSSSSSSk.............",
	"..........kSSLLLLSSk............",
	".........kSSLLLLLLSSk...........",
	"........kSSLLSSSSLLSSk..........",
	".......kSSLLSSSSSSLLSSk.........",
	"......kSSLLSSSSSSSSLLSSk........",
	".....kSSLLSSSSSSSSSSLLSSk.......",
	"....kSSLLSSSSSSSSSSSSLLSSk......",
	"...kSSLLSSSSSSSSSSSSSSLLSSk.....",
	"..kSSLLSSSSSSSSSSSSSSSSLLSSk....",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSk....",
	"..kSsSSSSSSSSSSSSSSSSSSSSsSk....",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSk....",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSk....",
	"..kSLLSSLLSSSSSSSSSSLLSSLLSk....",
	"..kSLYLSLYLSSSSSSSSSLYLSLYLk....",
	"..kSLOLSLOLSSSSSSSSSLOLSLOLk....",
	"..kSLOLSLOLSSSSSSSSSLOLSLOLk....",
	"..kSLoLSLoLSSSSSSSSSLoLSLoLk....",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSk....",
	"..kSsSSSSSSSSSSSSSSSSSSSSsSk....",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSk....",
	"..kSSSSSSSSSkkkkkkSSSSSSSSSk....",
	"..kSSSSSSSSkSLLLLSkSSSSSSSSk....",
	"..kSSSSSSSSkSLYYLSkSSSSSSSSk....",
	"..kSLLSSSSSkSLYOLSkSSSSSLLSk....",
	"..kSLYLSSSSkSLYOLSkSSSSLYLSk....",
	"..kSLOLSSSSkSLLOLLSkSSSLOLSk....",
	"..kSLOLSSSSkSSLOOLSkSSSLOLSk....",
	"..kSLoLSSSSSkSLOOLSkSSSLoLSk....",
	"..kSSSSSSSSSkSLooLSkSSSSSSSk....",
	"..kSsSSSSSSSkSLooLSkSSSSsSSk....",
	"..kSSSSSSSSSSkeooekSSSSSSSSk....",
	"..kSSSSSSSSSSkeooekSSSSSSSSk....",
	"..kSsSsSsSsSSSeooeSSsSsSsSsk....",
	"..kSSSSSSSSSSSeooeSSSSSSSSSk....",
	"..kSSSSSSSSSSSeooeSSSSSSSSSk....",
	"..ksssssssssssseeesssssssssk....",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkk....",
	"................................",
	"................................",
]


## 2x3. Temple tier 3 — the Sanctum. Five priests, three Tome slots.
##
## Seven lit windows plus the spire flame. By the time a colony can raise this, the Sanctum
## should be the brightest thing on the map that is not the Ember itself.
const SANCTUM := [
	"..............kk................",
	".............kYYk...............",
	".............kOYk...............",
	".............kOOk...............",
	".............kOOk...............",
	"............kkooKk..............",
	"...........kSSSSSSk.............",
	"..........kSSLYYLSSk............",
	"..........kSLYOOYLSk............",
	".........kSSLLOOLLSSk...........",
	"........kSSLLSSSSLLSSk..........",
	".......kSSLLSSSSSSLLSSk.........",
	"......kSSLLSSSSSSSSLLSSk........",
	".....kSSLLSSSSSSSSSSLLSSk.......",
	"....kSSLLSSSSSSSSSSSSLLSSk......",
	"...kSSLLSSSSSSSSSSSSSSLLSSk.....",
	"..kSSLLSSSSSSSSSSSSSSSSLLSSk....",
	".kSSLLSSSSSSSSSSSSSSSSSSLLSSk...",
	"kSSLLSSSSSSSSSSSSSSSSSSSSLLSSk..",
	"kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk..",
	"kSsSSSSSSSSSSSSSSSSSSSSSSSSsSk..",
	"kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk..",
	"kSLLSSLLSSLLSSSSSSLLSSLLSSLLSk..",
	"kSLYLSLYLSLYLSSSSSLYLSLYLSLYLk..",
	"kSLOLSLOLSLOLSSSSSLOLSLOLSLOLk..",
	"kSLOLSLOLSLOLSSSSSLOLSLOLSLOLk..",
	"kSLoLSLoLSLoLSSSSSLoLSLoLSLoLk..",
	"kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk..",
	"kSsSSSSSSSSSSSSSSSSSSSSSSSSsSk..",
	"kSSSSSSSSSSSSSSSSSSSSSSSSSSSSk..",
	"kSSSSSSSSSSSSkkkkkkSSSSSSSSSSk..",
	"kSSSSSSSSSSSkSLLLLSkSSSSSSSSSk..",
	"kSLLSSSSSSSSkSLYYLSkSSSSSSLLSk..",
	"kSLYLSSSSSSSkSLYOLSkSSSSSLYLSk..",
	"kSLOLSSSSSSSkSLYOLSkSSSSSLOLSk..",
	"kSLOLSSSSSSSkSLLOLLSkSSSSLOLSk..",
	"kSLoLSSSSSSSkSSLOOLSkSSSSLoLSk..",
	"kSSSSSSSSSSSSkSLOOLSkSSSSSSSSk..",
	"kSsSSSSSSSSSSkSLooLSkSSSSSsSSk..",
	"kSSSSSSSSSSSSkSLooLSkSSSSSSSSk..",
	"kSSSSSSSSSSSSSkeooekSSSSSSSSSk..",
	"kSsSsSsSsSsSSSkeooekSsSsSsSsSk..",
	"kSSSSSSSSSSSSSSeooeSSSSSSSSSSk..",
	"kSSSSSSSSSSSSSSeooeSSSSSSSSSSk..",
	"kSsSsSsSsSsSsSSeooeSSsSsSsSsSk..",
	"kssssssssssssssseeessssssssssk..",
	"kkkkkkkkkkkkkkkkkkkkkkkkkkkkkk..",
	"................................",
]


# =========================================================================================
# WIDENED FOOTPRINTS — the shapes that make packing a village a puzzle
# =========================================================================================
# A grid of 2x2 blocks tiles perfectly and therefore decides nothing. These four take the shape
# list to 1x1, 2x1, 2x2, 3x2, 2x3 and 4x2, which do NOT tessellate against each other — so where a
# building goes is a real choice, and the sphere of influence is what makes the room finite.

## 2x1. Sacks and crates under a low roof.
##
## Widened from 1x1 with the footprint pass. A 2x1 is the most awkward shape on the list — it fits
## neither the gap a 3x2 workshop leaves nor a square one — which is exactly what makes laying out a
## village a puzzle rather than tiling a grid.
const STOCKPILE_WIDE := [
	"................................",
	"..........kkkkkkkk..............",
	".......kkkDDDDDDDDkkk...........",
	"....kkkDDDEEEEEEEEDDDkkk........",
	"..kkDDDEEEeeeeeeeeEEEDDDkk......",
	"..kDDEEEeeEEEEEEEEeeEEEDDk......",
	"..kEEeeEEEDDDDDDDDEEEeeEEk......",
	"..kDDDDDDDDDDDDDDDDDDDDDDk......",
	"..kEDDDDDDDDDDDDDDDDDDDDEk......",
	"..kEDDNNNDDDNNNDDDNNNDDDEk......",
	"..kEDDNxNDDDNxNDDDNxNDDDEk......",
	"..kEDDNNNDDDNNNDDDNNNDDDEk......",
	"..kEEDDDDDDDDDDDDDDDDDDEEk......",
	"..kSSSSSSSSSSSSSSSSSSSSSSk......",
	"..kssssssssssssssssssssssk......",
	"...kkkkkkkkkkkkkkkkkkkkkk.......",
]


## 3x2. Four beds. Widened from 2x2 so housing is a rectangle rather than a square.
##
## The lit window and the doorway are at different heights and widths on purpose: at 1x zoom the
## thing that separates a Hut from a Longhouse is how many warm points it has, so the two must not
## read as one silhouette at two sizes.
const HUT_WIDE := [
	"................................................",
	"......................kk........................",
	".....................kEEk.......................",
	".....................kEEk.......................",
	"...................kkkEEkkk.....................",
	"...............kkkDDDDDDDDDkkk..................",
	"..........kkkkDDDEEEEEEEEEDDDkkkk...............",
	".......kkkDDDEEEeeeeeeeeeeeEEEDDDkkk............",
	"....kkkDDDEEEeeEEEEEEEEEEEEEeeEEEDDDkkk.........",
	"..kkDDDEEEeeEEEDDDDDDDDDDDDDEEEeeEEEDDDkk.......",
	"..kDDEEEeeEEEDDDDDDDDDDDDDDDDDEEEeeEEEDDk.......",
	"..kEEeeEEEDDDDDDDDDDDDDDDDDDDDDDDEEEeeEEk.......",
	"..kDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDk.......",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEk.......",
	"..kEEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEEk.......",
	"..kEEEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEEEk.......",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEk.......",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEk.......",
	"..kEDDDDDDDkkkkkkDDDDDDDDDDkkkkkkDDDDDDEk.......",
	"..kEDDDDDDDkYYYYkDDDDDDDDDDkEEEEkDDDDDDEk.......",
	"..kEDDDDDDDkOOOOkDDDDDDDDDDkeYYekDDDDDDEk.......",
	"..kEDDDDDDDkooooKDDDDDDDDDDkeOOekDDDDDDEk.......",
	"..kEDDDDDDDkkkkkkDDDDDDDDDDkeOOekDDDDDDEk.......",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDkeooekDDDDDDEk.......",
	"..kEEDDDDDDDDDDDDDDDDDDDDDDkeooekDDDDDEEk.......",
	"..kEEEDDDDDDDDDDDDDDDDDDDDDkeooekDDDDEEEk.......",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSSeooeSSSSSSSSk.......",
	"..kSsSsSsSsSsSsSsSsSsSsSsSSSeooeSsSsSsSSk.......",
	"..kSSSSSSSSSSSSSSSSSSSSSSSSSeooeSSSSSSSSk.......",
	"..kssssssssssssssssssssssssseeesssssssssk.......",
	"...kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk........",
	"................................................",
]


## 3x2. Nine beds. Four lit windows where the Hut has one, plus a second chimney.
##
## At night the difference between a colony that has housed its people and one that has not should be
## readable from across the map without opening a panel.
const LONGHOUSE_WIDE := [
	"................................................",
	"..................kk......kk....................",
	".................kEEk....kEEk...................",
	"...............kkkEEkkkkkkEEkkk.................",
	"..........kkkkDDDDDDDDDDDDDDDDDkkkk.............",
	".......kkkDDDDDEEEEEEEEEEEEEEEEEDDDDkkk.........",
	"....kkkDDDEEEEEeeeeeeeeeeeeeeeeeeEEEEEDDDkkk....",
	"..kkDDDEEEeeeEEEEEEEEEEEEEEEEEEEEEEEeeeEEEDDDk..",
	"..kDDEEEeeEEEDDDDDDDDDDDDDDDDDDDDDDDEEEeeEEEDk..",
	"..kEEeeEEEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEEEeeEk..",
	"..kDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDk..",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEk..",
	"..kEEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEEk..",
	"..kEEEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEEEk..",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEk..",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEk..",
	"..kEDkkkkkkDDDDkkkkkkDDDDkkkkkkDDDDkkkkkkDDDEk..",
	"..kEDkYYYYkDDDDkYYYYkDDDDkYYYYkDDDDkYYYYkDDDEk..",
	"..kEDkOOOOkDDDDkOOOOkDDDDkOOOOkDDDDkOOOOkDDDEk..",
	"..kEDkooooKDDDDkooooKDDDDkooooKDDDDkooooKDDDEk..",
	"..kEDkkkkkkDDDDkkkkkkDDDDkkkkkkDDDDkkkkkkDDDEk..",
	"..kEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDEk..",
	"..kEDDDDDDDDDDDDDDDDkkkkkkDDDDDDDDDDDDDDDDDDEk..",
	"..kEDDDDDDDDDDDDDDDDkEEEEkDDDDDDDDDDDDDDDDDDEk..",
	"..kEEDDDDDDDDDDDDDDDkeYYekDDDDDDDDDDDDDDDDDEEk..",
	"..kEEEDDDDDDDDDDDDDDkeOOekDDDDDDDDDDDDDDDDEEEk..",
	"..kSSSSSSSSSSSSSSSSSSeOOeSSSSSSSSSSSSSSSSSSSSk..",
	"..kSsSsSsSsSsSsSsSsSSeooeSSsSsSsSsSsSsSsSsSsSk..",
	"..kSSSSSSSSSSSSSSSSSSeooeSSSSSSSSSSSSSSSSSSSSk..",
	"..kssssssssssssssssssseeessssssssssssssssssssk..",
	"...kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk...",
	"................................................",
]


## 4x2. Two long furrowed beds and a lit tool shed at one end.
##
## The longest footprint in the game, deliberately: a farm should be the thing the player has to
## find real room for, and a 4x2 will not fit anywhere a 2x2 would. Walkable, so farmers stand in
## it, which is why it draws beneath them (see Building._ready on z_index).
##
## Rows are BUILT rather than hand-typed: counting 64 characters by eye produced an off-by-one row
## three separate times, and the result of one is a silently skewed sprite.
const FARM_LONG := [
	"................................................................",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk..",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNEk..",
	"..kEuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGEk..",
	"..kEGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgEk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNEk..",
	"..kEuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGEk..",
	"..kEGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgEk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNEk..",
	"..kEuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGuGEk..",
	"..kEGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgGgEk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNnNEk..",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEk..",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk..",
	"................................................................",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkkkkkk............kkkkkkkkkkkk........",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEk.........kkkDDDDDDDDDDDDkkk.....",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNEk......kkkDDDEEEEEEEEEEEEDDDkkk..",
	"..kEuGuGuGuGuGuGuGuGuGuGuGuGuGEk....kDDDEEEeeeeeeeeeeeeEEEDDDk..",
	"..kEGgGgGgGgGgGgGgGgGgGgGgGgGgEk....kDEEeeEEEEEEEEEEEEeeEEEDDk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNEk....kEeeEEEDDDDDDDDDDDEEEeeEEk..",
	"..kEuGuGuGuGuGuGuGuGuGuGuGuGuGEk....kDDDDDDDDDDDDDDDDDDDDDDDDk..",
	"..kEGgGgGgGgGgGgGgGgGgGgGgGgGgEk....kEDDDDDDkkkkkkkkDDDDDDDDEk..",
	"..kEnNnNnNnNnNnNnNnNnNnNnNnNnNEk....kEEDDDDDkYYYYYYkDDDDDDDEEk..",
	"..kEEEEEEEEEEEEEEEEEEEEEEEEEEEEk....kSSSSSSSkOOOOOOkSSSSSSSSSk..",
	"..kkkkkkkkkkkkkkkkkkkkkkkkkkkkkk....kssssssskooooooKsssssssssk..",
	"................................................................",
	"................................................................",
	"................................................................",
	"................................................................",
	"................................................................",
]


static func building_maps() -> Dictionary:
	return {
		&"palisade": {"map": PALISADE, "size": 16},
		&"gate": {"map": GATE, "size": 16},
		&"well": {"map": WELL, "size": 16},
		&"stockpile": {"map": STOCKPILE_WIDE, "w": 32, "h": 16},
		&"hearth": {"map": HEARTH, "size": 32},
		&"hut": {"map": HUT_WIDE, "w": 48, "h": 32},
		&"watchtower": {"map": WATCHTOWER, "size": 32},
		&"farm": {"map": FARM_LONG, "w": 64, "h": 32},
		# Rectangular. `size` is the SQUARE cases only; these carry explicit w/h.
		&"sawmill": {"map": SAWMILL, "w": 48, "h": 32},
		&"stonecutter": {"map": STONECUTTER, "w": 32, "h": 48},
		&"toolsmith": {"map": TOOLSMITH, "w": 48, "h": 32},
		&"great_hall": {"map": GREAT_HALL, "w": 32, "h": 32},
		&"stone_keep": {"map": STONE_KEEP, "w": 32, "h": 32},
		&"longhouse": {"map": LONGHOUSE_WIDE, "w": 48, "h": 32},
		&"shrine": {"map": SHRINE, "w": 32, "h": 48},
		&"temple": {"map": TEMPLE, "w": 32, "h": 48},
		&"sanctum": {"map": SANCTUM, "w": 32, "h": 48},
		&"path": {"map": PATH, "w": 16, "h": 16},
		&"road": {"map": ROAD, "w": 16, "h": 16},
	}


# =========================================================================================
# VILLAGER — 12x14, three facings (side is mirrored for left/right), two walk frames
# =========================================================================================

const VILLAGER_DOWN_0 := [
	"....kkkk....",
	"...kCCCCk...",
	"...kCffCk...",
	"...kfkfCk...",
	"...kffffk...",
	"....kkkk....",
	"...krrrrk...",
	"..fkCccCkf..",
	"..fkCccCkf..",
	"...kCDDCk...",
	"...kCCCCk...",
	"...kC..Ck...",
	"..kkk..kkk..",
	"..kk....kk..",
]

const VILLAGER_DOWN_1 := [
	"....kkkk....",
	"...kCCCCk...",
	"...kCffCk...",
	"...kfkfCk...",
	"...kffffk...",
	"....kkkk....",
	"...krrrrk...",
	"..fkCccCkf..",
	"..fkCccCkf..",
	"...kCDDCk...",
	"...kCCCCk...",
	"..kC....Ck..",
	".kkk....kkk.",
	".kk......kk.",
]

const VILLAGER_UP_0 := [
	"....kkkk....",
	"...kCCCCk...",
	"...kCccCk...",
	"...kcccck...",
	"...kCccCk...",
	"....kkkk....",
	"...krrrrk...",
	"..fkCccCkf..",
	"..fkCccCkf..",
	"...kCDDCk...",
	"...kCCCCk...",
	"...kC..Ck...",
	"..kkk..kkk..",
	"..kk....kk..",
]

const VILLAGER_UP_1 := [
	"....kkkk....",
	"...kCCCCk...",
	"...kCccCk...",
	"...kcccck...",
	"...kCccCk...",
	"....kkkk....",
	"...krrrrk...",
	"..fkCccCkf..",
	"..fkCccCkf..",
	"...kCDDCk...",
	"...kCCCCk...",
	"..kC....Ck..",
	".kkk....kkk.",
	".kk......kk.",
]

## Profile view, facing RIGHT — the renderer mirrors it for left. The head is shifted
## toward the facing direction and shows a SINGLE eye; the first pass kept both eyes
## and a centred head, so side-on villagers were indistinguishable from front-on ones
## and the whole sheet looked static.
##
## The eye must sit at the FRONT of the head (column 8 of the 4..9 span). It was at
## column 5 — the back of the skull — which fought the rightward head shift and made
## every villager walking east look like it was facing west. At twelve pixels the eye
## is the only facing cue there is, so one pixel on the wrong side reads as the whole
## colony walking backwards.
const VILLAGER_SIDE_0 := [
	".....kkkk...",
	"....kCCCCk..",
	"....kCfffk..",
	"....kCffkf..",
	"....kffffk..",
	".....kkkk...",
	"...krrrrk...",
	"..fkCcccCk..",
	"..fkCcccCk..",
	"...kCDDDk...",
	"...kCCCCk...",
	"....kCCk....",
	"...kkk.kkk..",
	"..kk....kk..",
]

const VILLAGER_SIDE_1 := [
	".....kkkk...",
	"....kCCCCk..",
	"....kCfffk..",
	"....kCffkf..",
	"....kffffk..",
	".....kkkk...",
	"...krrrrk...",
	"..fkCcccCk..",
	"..fkCcccCk..",
	"...kCDDDk...",
	"...kCCCCk...",
	"...kCC......",
	"..kkk..kkk..",
	".kk.....kk..",
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


## Legacy full-bleed texture references retained for art comparison. The baker now
## generates the full connection-mask set instead of using this two-state shortcut.
static func dense_feature_maps() -> Dictionary:
	return {
		Terrain.Feature.TREE: TREE_DENSE,
		Terrain.Feature.STONE: STONE_DENSE,
		Terrain.Feature.BERRIES: BERRIES_DENSE,
	}


## Alternate silhouettes for a feature type, in the order TileAtlas expects. Only
## trees have them so far — they are the only feature dense enough for repetition
## to be obvious.
static func feature_variants() -> Dictionary:
	return {
		Terrain.Feature.TREE: [TREE, TREE_B, TREE_C],
		Terrain.Feature.BERRIES: [BERRIES, BERRIES_B, BERRIES_C],
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


# =========================================================================================
# CARRY ICONS — 7x7, floated above a villager's head while it is holding something
# =========================================================================================
#
# Heavily outlined in near-black. These are read at a glance against grass, mud, stone
# and full night, and a silhouette without an outline disappears against at least one
# of those. Seven pixels is as small as a recognisable shape gets, and the icon still
# has to be distinguishable from the other two at 1x zoom — hence one strong shape
# cue each: stacked planks, a faceted lump, a round cluster.

## Stacked planks, banded light-dark-light. The first pass alternated dark wood with
## black separator rows and photographed as a solid black rectangle at gameplay zoom —
## a seven-pixel icon has no room for interior outlines, so the banding has to come
## from tone contrast alone.
const CARRY_WOOD := [
	".........",
	"..kkkkk..",
	".kDDDDDk.",
	".kDxxxDk.",
	".kDxxxDk.",
	".kDDDDDk.",
	"..kDkDk..",
	"..kkkkk..",
	".........",
]

const CARRY_STONE := [
	".........",
	"...kkk...",
	"..kLLLk..",
	".kLLSSSk.",
	".kLSSSSk.",
	".kSSSSSk.",
	"..kSSSk..",
	"...kkk...",
	".........",
]

const CARRY_FOOD := [
	"....m....",
	"...mgm...",
	"..mgggm..",
	"..kkkkk..",
	".krrrrrk.",
	".krrxrrk.",
	".krrrrrk.",
	"..kkkkk..",
	".........",
]


## Sawn boards, seen end-on: a neat stack rather than the raw log's ring banding.
##
## The processed goods have to be distinguishable from their inputs at seven pixels, because the
## whole point of watching a haul is knowing whether the sawmill is actually producing. So boards
## are lighter and squarer than wood, cut stone is pale and regular where rough stone is a lumpy
## grey mass, and tools are the only icon in the set with a metal highlight.
const CARRY_BOARDS := [
	".........",
	".kkkkkkk.",
	".kNNNNNk.",
	".kDDDDDk.",
	".kkkkkkk.",
	".kNNNNNk.",
	".kDDDDDk.",
	".kkkkkkk.",
	".........",
]

## Dressed blocks — square, pale, mortared. Reads as masonry against rough stone's boulder.
const CARRY_CUT_STONE := [
	".........",
	".kkkkkkk.",
	".kLLLkLk.",
	".kLLLkLk.",
	".kkkkkkk.",
	".kLkLLLk.",
	".kLkLLLk.",
	".kkkkkkk.",
	".........",
]

## A hammer. The only carried good with a bright metal head, because tools are the gate to the
## upper half of the build list and a player should be able to see one crossing the village.
const CARRY_TOOLS := [
	".........",
	".kkkkk...",
	".kLLYk...",
	".kkkkkk..",
	"....kEk..",
	"....kEk..",
	"....kEk..",
	"....kkk..",
	".........",
]


## Keyed by resource kind. The baker lays these out in Colony.KINDS order so the
## villager can pick its frame with a single array lookup instead of a match block.
##
## Must cover every entry in Colony.KINDS. The baker prints a loud warning for any it cannot find
## and leaves that slot blank, which is how the three processed goods were caught — a blank frame
## makes a haul of boards indistinguishable from a villager carrying nothing at all.
static func carry_frames() -> Dictionary:
	return {
		&"wood": CARRY_WOOD,
		&"stone": CARRY_STONE,
		&"food": CARRY_FOOD,
		&"boards": CARRY_BOARDS,
		&"cut_stone": CARRY_CUT_STONE,
		&"tools": CARRY_TOOLS,
	}


# =========================================================================================
# MORE OF THE BLIGHT — 12x14, two frames each, same conventions as the Shambler
# =========================================================================================
#
# Every one of these has to be identifiable by SILHOUETTE alone. At gameplay zoom on a phone,
# in the dark, colour is nearly useless — the whole roster shares the same three blight tones —
# so the shape has to carry the read. The design rule is one distinct outline per threat:
#
#   Shambler   hunched and top-heavy      the baseline melee
#   Spitter    small bulbous sac          fragile, ranged
#   Brute      wide, squat, armoured      breaks walls; you must not ignore it
#   Shade      tall, thin, legless        immune to light; punishes Ember reliance
#   Swarmling  tiny, barely there         arrives in numbers; rewards AoE
#   Burrower   low and flat with a maw    ignores walls; punishes pure turtling
#
# If two of these are ever confusable in a night fight the fix is the outline, not the palette.

## Wide and heavy, with slab shoulders and a small sunken head. Reads as a battering ram, which
## is exactly what it is — the answer to a player who thinks a wall is a solution.
const BRUTE_0 := [
	"............",
	"..bb....bb..",
	".bBBb..bBBb.",
	".bBBbbbbBBb.",
	"bBBBBPPBBBBb",
	"bBBBPPPPBBBb",
	"bBBBBPPBBBBb",
	"bBBBBBBBBBBb",
	".bBBBBBBBBb.",
	".bBB.bb.BBb.",
	".bB..bb..Bb.",
	".bb..bb..bb.",
	"kk...bb...kk",
	"......bb....",
]

const BRUTE_1 := [
	"............",
	"...bb..bb...",
	"..bBBbbBBb..",
	".bBBbbbbBBb.",
	"bBBBBPPBBBBb",
	"bBBBPPPPBBBb",
	"bBBBBPPBBBBb",
	"bBBBBBBBBBBb",
	".bBBBBBBBBb.",
	"..bB.bb.Bb..",
	"..bB.bb.Bb..",
	"..bb.bb.bb..",
	".kk..bb..kk.",
	"......bb....",
]

## Tall, narrow, and trailing off into nothing at the base — no legs, so it reads as drifting.
## Deliberately the least solid shape on the roster: the thing light cannot burn should not look
## like it is standing on the ground.
const SHADE_0 := [
	"....bbbb....",
	"...bBPPBb...",
	"...bPPPPb...",
	"...bBPPBb...",
	"...bBBBBb...",
	"....bBBb....",
	"....bBBb....",
	"...bBBBBb...",
	"...bB..Bb...",
	"..bB....Bb..",
	"..b......b..",
	"...b....b...",
	"....b..b....",
	".....bb.....",
]

const SHADE_1 := [
	"....bbbb....",
	"...bBPPBb...",
	"...bPPPPb...",
	"...bBPPBb...",
	"...bBBBBb...",
	"....bBBb....",
	"....bBBb....",
	"...bBBBBb...",
	"...bB..Bb...",
	"..bB....Bb..",
	"...b....b...",
	"....b..b....",
	".....bb.....",
	"............",
]

## Barely a creature. Small enough that a dozen on screen still reads as a swarm rather than a
## wall of sprites, which is what makes Wrath feel good against them.
const SWARMLING_0 := [
	"............",
	"............",
	"............",
	"............",
	"....bbb.....",
	"...bBPBb....",
	"...bBBBb....",
	"....bbb.....",
	"...b...b....",
	"..k.....k...",
	"............",
	"............",
	"............",
	"............",
]

const SWARMLING_1 := [
	"............",
	"............",
	"............",
	"............",
	"....bbb.....",
	"...bBPBb....",
	"...bBBBb....",
	"....bbb.....",
	"....b.b.....",
	"...k...k....",
	"............",
	"............",
	"............",
	"............",
]

## Low, flat and almost all mouth. Sits close to the ground so it reads as something that came up
## through it — the visual promise that a wall will not stop this one.
const BURROWER_0 := [
	"............",
	"............",
	"............",
	"............",
	"............",
	"..bbb..bbb..",
	".bBBBbbBBBb.",
	"bBPPPPPPPPBb",
	"bBPkkkkkkPBb",
	"bBBPPPPPPBBb",
	".bBBBBBBBBb.",
	"..bb.bb.bb..",
	"...k.....k..",
	"............",
]

const BURROWER_1 := [
	"............",
	"............",
	"............",
	"............",
	"..bbb..bbb..",
	".bBBBbbBBBb.",
	"bBPPPPPPPPBb",
	"bBPkkkkkkPBb",
	"bBPkkkkkkPBb",
	"bBBPPPPPPBBb",
	".bBBBBBBBBb.",
	"..bb.bb.bb..",
	"...k.....k..",
	"............",
]


# =========================================================================================
# BLIGHT STRUCTURES — what the corruption builds around its nests
# =========================================================================================
#
# The Blight should look like it is SETTLING, not just spawning. A nest ringed by growths reads as
# a place with intent behind it — somewhere the player has to go and destroy — rather than a spawn
# marker sitting on the ground.
#
# All three are anchored bottom-left like the player's buildings, so they Y-sort against villagers
# the same way, and all three are built from the same three blight tones as the creatures that come
# out of them.

## 16x32. A tall barbed growth — the silhouette that tells the player from across the map that a
## nest has taken root here.
const BLIGHT_SPIRE := [
	".......PP.......",
	"......bPPb......",
	"......bPPb......",
	".....bBPPBb.....",
	".....bBPPBb.....",
	"....bBBPPBBb....",
	"...bBBBPPBBBb...",
	"...bBB.PP.BBb...",
	"..bBB..PP..BBb..",
	"..bB...PP...Bb..",
	".bB..bBPPBb..Bb.",
	".b..bBBPPBBb..b.",
	"...bBBBPPBBBb...",
	"..bBBB.PP.BBBb..",
	"..bBB..PP..BBb..",
	".bBB...PP...BBb.",
	".bB....PP....Bb.",
	"bB....bPPb....Bb",
	"bB...bBPPBb...Bb",
	"bB..bBBPPBBb..Bb",
	"bB.bBBBPPBBBb.Bb",
	"bBbBBBBPPBBBBbBb",
	"bBBBBBB..BBBBBBb",
	"bBBBBB....BBBBBb",
	".bBBBB....BBBBb.",
	".bBBBBB..BBBBBb.",
	"..bBBBBBBBBBBb..",
	"..bbBBBBBBBBbb..",
	"...bbBBBBBBbb...",
	"....bbbBBbbb....",
	"......bbbb......",
	".....kkkkkk.....",
]

## 16x16. A squat fleshy dwelling. Where the lesser creatures come from — low, wide, and clearly
## something that houses rather than something that grows.
const BLIGHT_HOVEL := [
	"................",
	"................",
	".....bbbbb......",
	"...bbBBBBBbb....",
	"..bBBBPPPBBBb...",
	".bBBPPPPPPPBBb..",
	".bBPPPBBBPPPBb..",
	"bBBPPBBBBBPPBBb.",
	"bBPPBBkkkBBPPBb.",
	"bBPBBBkkkBBBPBb.",
	"bBBBBBkkkBBBBBb.",
	"bBBBBBkkkBBBBBb.",
	".bBBBBkkkBBBBb..",
	".bbBBBBBBBBBbb..",
	"..bbbbbbbbbbb...",
	"...kkkkkkkkk....",
]

## 16x24. A bone-and-sinew marker. Cheap for the Blight to raise, so it is what spreads first —
## and a visual warning that a nest is expanding in this direction.
const BLIGHT_TOTEM := [
	"......bb........",
	".....bPPb.......",
	".....bPPb.......",
	"....bBPPBb......",
	"...bBB..BBb.....",
	"..bBB....BBb....",
	"..bB......Bb....",
	"..b...bb...b....",
	"......bPPb......",
	"......bPPb......",
	".....bBPPBb.....",
	"....bBBPPBBb....",
	"...bBB.PP.BBb...",
	"...bB..PP..Bb...",
	"...b...PP...b...",
	".......PP.......",
	"......bPPb......",
	"......bPPb......",
	".....bBPPBb.....",
	".....bBBBBb.....",
	"....bBBBBBBb....",
	"....bbBBBBbb....",
	".....bbbbbb.....",
	"......kkkk......",
]


static func monster_frames() -> Dictionary:
	return {
		&"shambler": [SHAMBLER_0, SHAMBLER_1],
		&"spitter": [SPITTER_0, SPITTER_1],
		&"brute": [BRUTE_0, BRUTE_1],
		&"shade": [SHADE_0, SHADE_1],
		&"swarmling": [SWARMLING_0, SWARMLING_1],
		&"burrower": [BURROWER_0, BURROWER_1],
	}


## Structures the Blight raises around its nests. Static, so one frame each.
static func blight_structure_maps() -> Dictionary:
	return {
		&"spire": {"map": BLIGHT_SPIRE, "w": 16, "h": 32},
		&"hovel": {"map": BLIGHT_HOVEL, "w": 16, "h": 16},
		&"totem": {"map": BLIGHT_TOTEM, "w": 16, "h": 24},
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
