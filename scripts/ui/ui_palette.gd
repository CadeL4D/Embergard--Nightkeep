class_name UiPalette
extends RefCounted
## The one place a UI colour is allowed to be written down.
##
## Before this existed every screen typed its own literals — `Color(0.9, 0.72, 0.35)`
## in the job board, `Color(1.0, 0.55, 0.42)` on the summary card, and a phase colour
## table inline in the HUD. Six near-identical ambers that could never be changed
## together is exactly why the UI could not be made to look like one product.
##
## Colours are SEMANTIC, not descriptive: call sites ask for `WARN`, never for "amber".
## That is what lets the palette be retuned — or swapped for a colourblind variant —
## without touching a single screen.
##
## The values deliberately share hexes with the world art in ArtData. The art direction
## is already written down in two places (ArtData.PALETTE and Run.SKY_COLORS): the world
## is cold and desaturated so that firelight is the only warm thing on screen. The UI
## obeys that rather than inventing a second look.

# --- Surfaces --------------------------------------------------------------------------

const BG_DEEP := Color("12161d")      ## modal backdrops, the darkest ground
const BG_PANEL := Color("1b2129")     ## standard panel fill
const BG_RAISED := Color("262e38")    ## buttons, rows, anything sitting on a panel
const BG_HOVER := Color("323c48")
const BORDER := Color("3a4450")
const BORDER_STRONG := Color("576170")

# --- Text ------------------------------------------------------------------------------

const TEXT := Color("d8dee6")
const TEXT_DIM := Color("b3c2d1")     ## secondary readouts; was Color(0.7, 0.76, 0.82)
const TEXT_FAINT := Color("74808d")   ## disabled
const TEXT_ON_ACCENT := Color("12161d")

# --- Accent ----------------------------------------------------------------------------
# The Ember. Shared with ArtData's firelight ramp ("o" / "O" / "Y") on purpose — the
# warm colour in the UI and the warm colour in the world are the same colour.

const ACCENT := Color("ff9a3c")
const ACCENT_DIM := Color("c85a1e")
const ACCENT_PALE := Color("ffd88a")

# --- Status ----------------------------------------------------------------------------

const OK := Color("b8e0b8")           ## valid placement; was Color(0.72, 0.88, 0.72)
const WARN := Color("e6b859")         ## understaffed; was Color(0.9, 0.72, 0.35)
const DANGER := Color("f29a8c")       ## invalid, destroyed; was Color(0.95, 0.6, 0.55)
const BLIGHT := Color("8f2456")       ## corruption, shared with ArtData "P"

# --- Phase -----------------------------------------------------------------------------
## Indexed by Sim.Phase. Lifted out of the HUD so the clock, any future world-map
## overlay, and the music mood can all read one table instead of three copies.
const PHASE: Array[Color] = [
	Color("d1dbe6"),   # DAY
	Color("ffa65c"),   # DUSK
	Color("b89ef2"),   # NIGHT
	Color("e6cc99"),   # DAWN
]


static func phase_color(phase: int) -> Color:
	return PHASE[phase] if phase >= 0 and phase < PHASE.size() else TEXT
