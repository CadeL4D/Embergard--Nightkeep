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

const RADIUS := 4
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
	_style_fields(t)
	_style_sliders(t)
	_style_tabs(t)
	_style_progress(t)
	_style_scrollbars(t)
	return t


# --- Surfaces --------------------------------------------------------------------------

static func _style_panels(t: Theme) -> void:
	# Translucent rather than opaque so the world stays legible behind the HUD. On a
	# phone the panels cover a third of the screen and an opaque strip would hide the
	# thing the player is trying to react to.
	var panel := _flat(_alpha(UiPalette.BG_PANEL, 0.94), UiPalette.BORDER)
	panel.shadow_color = Color(0.01, 0.015, 0.025, 0.62)
	panel.shadow_size = 5
	panel.shadow_offset = Vector2(0, 2)
	t.set_stylebox("panel", "PanelContainer", panel)
	t.set_stylebox("panel", "Panel", panel)

	var popup := _flat(_alpha(UiPalette.BG_DEEP, 0.97), UiPalette.BORDER_STRONG)
	popup.shadow_color = Color(0, 0, 0, 0.72)
	popup.shadow_size = 8
	popup.shadow_offset = Vector2(0, 3)
	t.set_stylebox("panel", "PopupPanel", popup)


# --- Buttons ---------------------------------------------------------------------------

static func _style_buttons(t: Theme) -> void:
	t.set_font_size("font_size", "Button", FONT_SIZE)
	var normal := _flat(UiPalette.BG_RAISED, UiPalette.BORDER)
	normal.content_margin_left = 8
	normal.content_margin_right = 8
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	t.set_stylebox("normal", "Button", normal)

	var hover := _flat(UiPalette.BG_HOVER, UiPalette.ACCENT_DIM)
	hover.content_margin_left = 8
	hover.content_margin_right = 8
	hover.content_margin_top = 4
	hover.content_margin_bottom = 4
	t.set_stylebox("hover", "Button", hover)
	# Pressed reads as ember-lit rather than merely darker. A colour change survives being
	# viewed under a thumb; a brightness change does not.
	var pressed := _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT_PALE)
	pressed.content_margin_left = 8
	pressed.content_margin_right = 8
	pressed.content_margin_top = 5
	pressed.content_margin_bottom = 3
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("disabled", "Button",
		_flat(_alpha(UiPalette.BG_RAISED, 0.45), _alpha(UiPalette.BORDER, 0.45)))
	var focus := _flat(Color(0, 0, 0, 0), UiPalette.ACCENT_PALE)
	focus.set_border_width_all(1)
	focus.expand_margin_left = 1
	focus.expand_margin_top = 1
	focus.expand_margin_right = 1
	focus.expand_margin_bottom = 1
	t.set_stylebox("focus", "Button", focus)

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
	t.set_font_size("font_size", "Label", FONT_SIZE)
	t.set_font_size("normal_font_size", "RichTextLabel", FONT_SIZE)
	t.set_color("font_color", "Label", UiPalette.TEXT)
	t.set_color("font_color", "RichTextLabel", UiPalette.TEXT)
	# A one-pixel ink edge keeps the small strategy readouts legible over fire,
	# water and the new illustrated title backdrop without turning them into
	# heavy outlined display type.
	t.set_color("font_outline_color", "Label", _alpha(UiPalette.BG_DEEP, 0.75))
	t.set_constant("outline_size", "Label", 1)


# --- Text fields and toggles ------------------------------------------------------------

static func _style_fields(t: Theme) -> void:
	t.set_font_size("font_size", "LineEdit", FONT_SIZE)
	t.set_font_size("font_size", "CheckBox", FONT_SIZE)
	var field := _flat(UiPalette.BG_DEEP, UiPalette.BORDER_STRONG)
	field.content_margin_left = 7
	field.content_margin_right = 7
	field.content_margin_top = 4
	field.content_margin_bottom = 4
	t.set_stylebox("normal", "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", _flat(UiPalette.BG_DEEP, UiPalette.ACCENT))
	t.set_color("font_color", "LineEdit", UiPalette.TEXT)
	t.set_color("font_placeholder_color", "LineEdit", UiPalette.TEXT_FAINT)
	t.set_color("caret_color", "LineEdit", UiPalette.ACCENT_PALE)
	t.set_color("font_color", "CheckBox", UiPalette.TEXT_DIM)
	t.set_color("font_hover_color", "CheckBox", UiPalette.TEXT)
	t.set_color("font_pressed_color", "CheckBox", UiPalette.ACCENT_PALE)


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
	t.set_icon("grabber", "HSlider", _slider_grabber(UiPalette.ACCENT, UiPalette.ACCENT_PALE))
	t.set_icon("grabber_highlight", "HSlider",
		_slider_grabber(UiPalette.ACCENT_PALE, Color.WHITE))
	t.set_icon("grabber_disabled", "HSlider",
		_slider_grabber(UiPalette.TEXT_FAINT, UiPalette.BORDER))


# --- Tabs (used by the Phase 2 build menu) ---------------------------------------------

static func _style_tabs(t: Theme) -> void:
	t.set_font_size("font_size", "TabBar", FONT_SIZE_SMALL)
	t.set_font_size("font_size", "TabContainer", FONT_SIZE_SMALL)
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
	t.set_font_size("font_size", "ProgressBar", FONT_SIZE_SMALL)
	t.set_stylebox("background", "ProgressBar", _flat(UiPalette.BG_DEEP, UiPalette.BORDER, 2))
	t.set_stylebox("fill", "ProgressBar", _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT, 2))
	t.set_color("font_color", "ProgressBar", UiPalette.TEXT)


# --- Scrolling -------------------------------------------------------------------------

static func _style_scrollbars(t: Theme) -> void:
	for kind: String in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", kind, _flat(_alpha(UiPalette.BG_DEEP, 0.55), UiPalette.BORDER, 2))
		t.set_stylebox("grabber", kind, _flat(UiPalette.BORDER_STRONG, UiPalette.BORDER_STRONG, 2))
		t.set_stylebox("grabber_highlight", kind, _flat(UiPalette.ACCENT_DIM, UiPalette.ACCENT, 2))
		t.set_stylebox("grabber_pressed", kind, _flat(UiPalette.ACCENT, UiPalette.ACCENT_PALE, 2))


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


## A crisp diamond reads at 1x and stays comfortably finger-sized after the
## viewport's 2x display stretch. Using a generated theme icon also removes the
## oversized stock-Godot white knob from every settings and job slider.
static func _slider_grabber(fill: Color, edge: Color) -> ImageTexture:
	const SIZE := 9
	const MID := 4
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in SIZE:
		for x in SIZE:
			var distance := absi(x - MID) + absi(y - MID)
			if distance <= MID:
				img.set_pixel(x, y, edge if distance == MID else fill)
	return ImageTexture.create_from_image(img)
