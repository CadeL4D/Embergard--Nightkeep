class_name UiTheme
extends RefCounted
## Builds the game's Theme from UiPalette.
##
## Constructed in code rather than authored as a .tres for the same reason the sprites
## are: there is one source of truth (UiPalette) and everything else is derived from it.
## A hand-maintained theme resource would drift from the palette the first time a colour
## changed, and half the point of having a palette is that it cannot.
##
## Applied once to the root Window by the Ui autoload, which propagates it to every
## Control in every scene — including the dev scenes, which is why this is an autoload
## rather than a line in each screen's _ready.
##
## Corner radii are small and borders are one pixel. The game renders at a 640x360 base
## with canvas_items stretch, so anything softer turns to mush at 1x and anything
## heavier fights the pixel art.

const RADIUS := 3
const BORDER_W := 1

## Base font size, in a 360px-tall viewport.
##
## Godot's default of 16 is wildly too large here — a line of text was eating 4.4% of the screen
## height and the phase clock alone took over a third of the width. 12 was still too big in
## practice; 10 puts a line at under 3% of screen height, which is where a dense strategy HUD
## needs to sit. Everything scales up 2x or more on the way to a real display, so this is not as
## small as it sounds.
const FONT_SIZE := 10
const FONT_SIZE_SMALL := 8
const FONT_SIZE_TITLE := 20


static func build() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT_SIZE

	_style_panels(t)
	_style_buttons(t)
	_style_labels(t)
	_style_sliders(t)
	_style_tabs(t)
	_style_progress(t)
	return t


# --- Surfaces --------------------------------------------------------------------------

static func _style_panels(t: Theme) -> void:
	# Translucent rather than opaque so the world stays legible behind the HUD. On a
	# phone the panels cover a third of the screen and an opaque strip would hide the
	# thing the player is trying to react to.
	var panel := _flat(_alpha(UiPalette.BG_PANEL, 0.92), UiPalette.BORDER)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)

	var popup := _flat(_alpha(UiPalette.BG_DEEP, 0.97), UiPalette.BORDER_STRONG)
	t.set_stylebox("panel", "PopupPanel", popup)


# --- Buttons ---------------------------------------------------------------------------

static func _style_buttons(t: Theme) -> void:
	t.set_stylebox("normal", "Button", _flat(UiPalette.BG_RAISED, UiPalette.BORDER))
	t.set_stylebox("hover", "Button", _flat(UiPalette.BG_HOVER, UiPalette.BORDER_STRONG))
	# Pressed reads as ember-lit rather than merely darker. A colour change survives being
	# viewed under a thumb; a brightness change does not.
	t.set_stylebox("pressed", "Button", _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT))
	t.set_stylebox("disabled", "Button",
		_flat(_alpha(UiPalette.BG_RAISED, 0.45), _alpha(UiPalette.BORDER, 0.45)))
	t.set_stylebox("focus", "Button", _flat(Color(0, 0, 0, 0), UiPalette.ACCENT))

	t.set_color("font_color", "Button", UiPalette.TEXT)
	t.set_color("font_hover_color", "Button", UiPalette.ACCENT_PALE)
	t.set_color("font_pressed_color", "Button", UiPalette.TEXT_ON_ACCENT)
	t.set_color("font_disabled_color", "Button", UiPalette.TEXT_FAINT)
	t.set_color("font_focus_color", "Button", UiPalette.ACCENT_PALE)

	# A comfortable touch target. 44px is the usual minimum and the God Hand already
	# uses it for world picking (see GodHand.TOUCH_TARGET_PX) — the UI should not be
	# harder to hit than a villager.
	t.set_constant("h_separation", "Button", 4)


# --- Text ------------------------------------------------------------------------------

static func _style_labels(t: Theme) -> void:
	t.set_color("font_color", "Label", UiPalette.TEXT)
	t.set_color("font_color", "RichTextLabel", UiPalette.TEXT)


# --- Sliders ---------------------------------------------------------------------------

static func _style_sliders(t: Theme) -> void:
	# The Job Board is the game's main control surface, so its sliders get a visible
	# filled portion — a bare track gives no read on where the value sits.
	var track := _flat(UiPalette.BG_DEEP, UiPalette.BORDER, 2)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)

	var filled := _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT, 2)
	t.set_stylebox("grabber_area", "HSlider", filled)
	t.set_stylebox("grabber_area_highlight", "HSlider", _flat(UiPalette.ACCENT, UiPalette.ACCENT_PALE, 2))


# --- Tabs (used by the Phase 2 build menu) ---------------------------------------------

static func _style_tabs(t: Theme) -> void:
	t.set_stylebox("tab_selected", "TabBar", _flat(UiPalette.BG_RAISED, UiPalette.ACCENT))
	t.set_stylebox("tab_unselected", "TabBar",
		_flat(_alpha(UiPalette.BG_PANEL, 0.7), UiPalette.BORDER))
	t.set_stylebox("tab_hovered", "TabBar", _flat(UiPalette.BG_HOVER, UiPalette.BORDER_STRONG))
	t.set_color("font_selected_color", "TabBar", UiPalette.ACCENT_PALE)
	t.set_color("font_unselected_color", "TabBar", UiPalette.TEXT_DIM)
	t.set_color("font_hovered_color", "TabBar", UiPalette.TEXT)

	t.set_stylebox("panel", "TabContainer",
		_flat(_alpha(UiPalette.BG_PANEL, 0.92), UiPalette.BORDER))
	t.set_stylebox("tab_selected", "TabContainer", _flat(UiPalette.BG_RAISED, UiPalette.ACCENT))
	t.set_stylebox("tab_unselected", "TabContainer",
		_flat(_alpha(UiPalette.BG_PANEL, 0.7), UiPalette.BORDER))
	t.set_color("font_selected_color", "TabContainer", UiPalette.ACCENT_PALE)
	t.set_color("font_unselected_color", "TabContainer", UiPalette.TEXT_DIM)


# --- Bars ------------------------------------------------------------------------------

static func _style_progress(t: Theme) -> void:
	t.set_stylebox("background", "ProgressBar", _flat(UiPalette.BG_DEEP, UiPalette.BORDER, 2))
	t.set_stylebox("fill", "ProgressBar", _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT, 2))
	t.set_color("font_color", "ProgressBar", UiPalette.TEXT)


# --- Helpers ---------------------------------------------------------------------------

static func _flat(bg: Color, border: Color, radius: int = RADIUS) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(BORDER_W)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	return s


static func _alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)
