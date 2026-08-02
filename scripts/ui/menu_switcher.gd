class_name MenuSwitcher
extends Control
## Hold-drag quick switcher for the bottom menu button.

const OPTION_HEIGHT := 30.0
const OPTION_GAP := 4.0
const SIDE_MARGIN := 8.0
const BOTTOM_OFFSET := 72.0

var _labels: PackedStringArray = PackedStringArray()
var _rects: Array[Rect2] = []
var _highlighted: int = -1
var _origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_rebuild_layout)


func open(labels: PackedStringArray, origin: Vector2) -> void:
	_labels = labels
	_origin = origin
	_highlighted = -1
	visible = true
	_rebuild_layout()
	queue_redraw()


func update_pointer(screen_position: Vector2) -> void:
	var next := -1
	for index in _rects.size():
		if _rects[index].grow(7.0).has_point(screen_position):
			next = index
			break
	if next != _highlighted:
		_highlighted = next
		queue_redraw()


func finish() -> int:
	var picked := _highlighted
	visible = false
	_highlighted = -1
	queue_redraw()
	return picked


func cancel() -> void:
	visible = false
	_highlighted = -1
	queue_redraw()


func _rebuild_layout() -> void:
	_rects.clear()
	if _labels.is_empty():
		return
	var available := maxf(size.x - SIDE_MARGIN * 2.0, 1.0)
	var width := (available - OPTION_GAP * float(_labels.size() - 1)) \
		/ float(_labels.size())
	var y := maxf(size.y - BOTTOM_OFFSET, SIDE_MARGIN)
	for index in _labels.size():
		_rects.append(Rect2(
			Vector2(SIDE_MARGIN + float(index) * (width + OPTION_GAP), y),
			Vector2(width, OPTION_HEIGHT)))


func _draw() -> void:
	if not visible:
		return
	draw_rect(Rect2(Vector2(0, maxf(size.y - 82.0, 0.0)), Vector2(size.x, 46.0)),
		Color(0.025, 0.032, 0.05, 0.92), true)
	if _highlighted >= 0 and _highlighted < _rects.size():
		draw_line(_origin, _rects[_highlighted].get_center(),
			Color(UiPalette.ACCENT, 0.55), 2.0, true)
	for index in _rects.size():
		var rect := _rects[index]
		var active := index == _highlighted
		var fill := Color(0.34, 0.22, 0.12, 0.98) if active \
			else Color(0.07, 0.085, 0.12, 0.98)
		var outline := UiPalette.ACCENT if active else UiPalette.BORDER
		draw_rect(rect, fill, true)
		draw_rect(rect, outline, false, 1.5)
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(3, 20), _labels[index],
			HORIZONTAL_ALIGNMENT_CENTER, rect.size.x - 6.0, 9,
			UiPalette.ACCENT_PALE if active else UiPalette.TEXT)
