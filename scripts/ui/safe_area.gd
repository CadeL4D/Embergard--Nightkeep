class_name SafeArea
extends RefCounted
## Applies display safe-area insets to a MarginContainer.
##
## Shared by every HUD layer, because getting this wrong is silent and total: the
## first version subtracted the safe area from the WINDOW size, and on desktop
## `get_display_safe_area()` reports the whole monitor while the window is smaller.
## That produced margins of around -600px, which pushed the entire HUD off-screen —
## the resource bar and Job Board simply were not there, with no error to explain it.
##
## The rule: an inset is how much the usable area is smaller than the window on that
## edge, and it can never be negative. When the reported safe area is larger than the
## window (any desktop, any windowed build) every inset correctly resolves to zero.

static func apply(target: MarginContainer, pad: int = 8) -> void:
	if target == null:
		return

	var safe := DisplayServer.get_display_safe_area()
	var window := DisplayServer.window_get_size()
	if window.x <= 0 or window.y <= 0:
		return

	# Insets are in real screen pixels; the HUD lives in the stretched viewport, so
	# they have to be converted or they are wrong on every device whose scale factor
	# is not 1.
	var view := target.get_tree().root.get_visible_rect().size
	var margins := calculate_margins(window, safe, view, pad)
	target.add_theme_constant_override("margin_left", margins.x)
	target.add_theme_constant_override("margin_top", margins.y)
	target.add_theme_constant_override("margin_right", margins.z)
	target.add_theme_constant_override("margin_bottom", margins.w)


## Pure geometry form used by the device-layout regression suite.
static func calculate_margins(window: Vector2i, safe: Rect2i, view: Vector2,
		pad: int = 8) -> Vector4i:
	if window.x <= 0 or window.y <= 0:
		return Vector4i(pad, pad, pad, pad)
	var inset_left := maxi(safe.position.x, 0)
	var inset_top := maxi(safe.position.y, 0)
	var inset_right := maxi(window.x - safe.end.x, 0)
	var inset_bottom := maxi(window.y - safe.end.y, 0)
	var sx := view.x / float(window.x)
	var sy := view.y / float(window.y)
	return Vector4i(
		int(inset_left * sx) + pad,
		int(inset_top * sy) + pad,
		int(inset_right * sx) + pad,
		int(inset_bottom * sy) + pad)
