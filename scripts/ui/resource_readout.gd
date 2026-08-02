class_name ResourceReadout
extends Control
## Compact, icon-led resource readout. Every resource gets its own bordered chip so
## adjacent counts cannot read as one long number, even at the smallest text size.

const FONT_SIZE := 9
const LINE_HEIGHT := 17.0
const CHIP_GAP := 4.0
const CHIP_PAD := 4.0
const ICON_SIZE := 10.0

var _rows: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.x = 300.0
	resized.connect(_refresh_layout)


func set_rows(value: Array) -> void:
	_rows = value.duplicate(true)
	tooltip_text = _plain_text()
	_refresh_layout()


func _refresh_layout() -> void:
	custom_minimum_size.y = _required_height(maxf(size.x, custom_minimum_size.x))
	queue_redraw()


func _required_height(available_width: float) -> float:
	var y := 0.0
	for raw_row in _rows:
		var row: Dictionary = raw_row
		var x := 0.0
		var heading := String(row.get("label", ""))
		if not heading.is_empty():
			x = _text_width(heading + " ")
		for raw_entry in row.get("entries", []):
			var entry: Dictionary = raw_entry
			var width := _entry_width(String(entry.get("text", "")))
			if x > 0.0 and x + width > available_width:
				y += LINE_HEIGHT
				x = 0.0
			x += width + CHIP_GAP
		y += LINE_HEIGHT
	return maxf(y, LINE_HEIGHT)


func _draw() -> void:
	var available_width := maxf(size.x, custom_minimum_size.x)
	var y := 0.0
	for raw_row in _rows:
		var row: Dictionary = raw_row
		var x := 0.0
		var heading := String(row.get("label", ""))
		if not heading.is_empty():
			draw_string(ThemeDB.fallback_font, Vector2(0.0, y + 12.0), heading,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, UiPalette.TEXT_DIM)
			x = _text_width(heading + " ")
		for raw_entry in row.get("entries", []):
			var entry: Dictionary = raw_entry
			var text := String(entry.get("text", ""))
			var width := _entry_width(text)
			if x > 0.0 and x + width > available_width:
				y += LINE_HEIGHT
				x = 0.0
			_draw_entry(Rect2(Vector2(x, y + 1.0), Vector2(width, 14.0)),
				StringName(entry.get("kind", &"")), text)
			x += width + CHIP_GAP
		y += LINE_HEIGHT


func _draw_entry(rect: Rect2, kind: StringName, text: String) -> void:
	draw_rect(rect, Color(0.075, 0.09, 0.12, 0.94), true)
	draw_rect(rect, _icon_color(kind).darkened(0.18), false, 1.0)
	var centre := Vector2(rect.position.x + CHIP_PAD + ICON_SIZE * 0.5, rect.get_center().y)
	_draw_icon(kind, centre)
	draw_string(ThemeDB.fallback_font,
		Vector2(rect.position.x + CHIP_PAD + ICON_SIZE + 3.0, rect.position.y + 10.5), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, UiPalette.TEXT)


func _draw_icon(kind: StringName, centre: Vector2) -> void:
	var color := _icon_color(kind)
	var dark := Color(0.025, 0.03, 0.045, 1.0)
	match kind:
		&"wood":
			for offset in [-3.0, 0.0, 3.0]:
				draw_line(centre + Vector2(-4, offset), centre + Vector2(4, offset), color, 2.0)
		&"stone":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(-4, 3),
				centre + Vector2(-3, -2), centre + Vector2(1, -4), centre + Vector2(4, 0),
				centre + Vector2(3, 4)]), color)
		&"food":
			draw_circle(centre + Vector2(0, 1), 3.5, color)
			draw_line(centre + Vector2(0, -2), centre + Vector2(2, -5), Color(0.36, 0.82, 0.42), 1.5)
		&"ore":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(-4, 2),
				centre + Vector2(-2, -4), centre + Vector2(4, -2), centre + Vector2(3, 4)]), color)
			draw_circle(centre + Vector2(1, -1), 1.2, Color(1.0, 0.76, 0.28))
		&"emberglass":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(0, -5),
				centre + Vector2(4, 0), centre + Vector2(0, 5), centre + Vector2(-4, 0)]), color)
			draw_line(centre + Vector2(0, -3), centre + Vector2(0, 3), Color.WHITE, 1.0)
		&"herbs":
			draw_line(centre + Vector2(0, 4), centre + Vector2(0, -4), color, 1.5)
			draw_circle(centre + Vector2(-2, -1), 2.0, color)
			draw_circle(centre + Vector2(2, -3), 2.0, color.lightened(0.12))
		&"boards":
			for offset in [-3.0, 1.0]:
				draw_rect(Rect2(centre + Vector2(-4, offset), Vector2(8, 2)), color, true)
		&"cut_stone":
			for yy in [-3.0, 1.0]:
				draw_rect(Rect2(centre + Vector2(-4, yy), Vector2(8, 3)), color, true)
				draw_line(centre + Vector2(0, yy), centre + Vector2(0, yy + 3), dark, 1.0)
		&"ingots":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(-4, 3),
				centre + Vector2(-2, -3), centre + Vector2(3, -3), centre + Vector2(5, 3)]), color)
		&"rations":
			draw_circle(centre + Vector2(0, 1), 4.0, color)
			draw_line(centre + Vector2(-2, -4), centre + Vector2(2, -4), dark, 1.5)
		&"medicine":
			draw_rect(Rect2(centre + Vector2(-1.5, -5), Vector2(3, 10)), color, true)
			draw_rect(Rect2(centre + Vector2(-5, -1.5), Vector2(10, 3)), color, true)
		&"tools":
			draw_line(centre + Vector2(-3, 4), centre + Vector2(2, -3), color, 2.0)
			draw_line(centre + Vector2(-1, -4), centre + Vector2(4, -1), color.lightened(0.25), 3.0)
		&"arrows":
			_draw_projectile(centre, color, false)
		&"bolts":
			_draw_projectile(centre, color, true)
		&"population":
			draw_circle(centre + Vector2(0, -2), 2.4, color)
			draw_circle(centre + Vector2(0, 4), 4.0, color)
		&"water":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(0, -5),
				centre + Vector2(4, 2), centre + Vector2(2, 5), centre + Vector2(-2, 5),
				centre + Vector2(-4, 2)]), color)
		&"mood":
			draw_circle(centre, 4.5, color)
			draw_circle(centre + Vector2(-1.7, -1), 0.7, dark)
			draw_circle(centre + Vector2(1.7, -1), 0.7, dark)
			draw_line(centre + Vector2(-2, 2), centre + Vector2(2, 2), dark, 1.0)
		&"faith":
			draw_colored_polygon(PackedVector2Array([centre + Vector2(0, -5),
				centre + Vector2(2, -1), centre + Vector2(5, 0), centre + Vector2(2, 2),
				centre + Vector2(0, 5), centre + Vector2(-2, 2), centre + Vector2(-5, 0),
				centre + Vector2(-2, -1)]), color)
		_:
			draw_circle(centre, 3.5, color)


func _draw_projectile(centre: Vector2, color: Color, heavy: bool) -> void:
	var width := 2.5 if heavy else 1.4
	draw_line(centre + Vector2(-4, 4), centre + Vector2(3, -3), color, width)
	draw_line(centre + Vector2(0, -3), centre + Vector2(3, -3), color, width)
	draw_line(centre + Vector2(3, -3), centre + Vector2(3, 0), color, width)


func _entry_width(text: String) -> float:
	return CHIP_PAD * 2.0 + ICON_SIZE + 3.0 + _text_width(text)


func _text_width(text: String) -> float:
	return ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, FONT_SIZE).x


func _plain_text() -> String:
	var lines := PackedStringArray()
	for raw_row in _rows:
		var row: Dictionary = raw_row
		var parts := PackedStringArray()
		for raw_entry in row.get("entries", []):
			parts.append(String((raw_entry as Dictionary).get("accessible", "")))
		lines.append("%s %s" % [String(row.get("label", "")), "  ".join(parts)])
	return "\n".join(lines)


static func _icon_color(kind: StringName) -> Color:
	return {
		&"wood": Color("c88b50"), &"stone": Color("aab3c2"), &"food": Color("e15a55"),
		&"ore": Color("817b91"), &"emberglass": Color("61d9e8"), &"herbs": Color("65bd69"),
		&"boards": Color("e0b76a"), &"cut_stone": Color("d8d4c5"),
		&"ingots": Color("8ec4d6"), &"rations": Color("c99c62"),
		&"medicine": Color("75e0b6"), &"tools": Color("f0c95b"),
		&"arrows": Color("e5d8ac"), &"bolts": Color("d58fda"),
		&"population": Color("f0d39a"), &"water": Color("64bde8"),
		&"mood": Color("efb45a"), &"faith": Color("c6a5ff"),
	}.get(kind, Color.WHITE)
