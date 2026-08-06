extends Node2D
## Batched presentation for every physical object record. Essence pulses so it reads as a divine
## board object; ordinary goods remain subdued so they do not compete with terrain or danger.

const PILE_RADIUS := 3.4
const ESSENCE_RADIUS := 4.0
const CATEGORY_COLORS := {
	&"raw": Color(0.78, 0.62, 0.32),
	&"processed": Color(0.62, 0.72, 0.80),
	&"made": Color(0.86, 0.72, 0.44),
}
const FALLBACK_COLOR := Color(0.72, 0.70, 0.62)

var _pulse: float = 0.0


func _ready() -> void:
	Events.loose_drops_changed.connect(func(_cell: int) -> void: queue_redraw())
	Events.run_started.connect(func(_seed: int) -> void: queue_redraw())
	set_process(false)


func _process(delta: float) -> void:
	_pulse = fmod(_pulse + delta, TAU)
	queue_redraw()
	if Colony.essence_total() <= 0:
		set_process(false)


func _draw() -> void:
	if Colony.loose_drops.is_empty():
		return
	if Colony.essence_total() > 0 and not is_processing():
		set_process(true)
	var tile := float(Grid.TILE_SIZE)
	var at_cell: Dictionary = {}
	for drop: LooseDrop in Colony.loose_drops.values():
		if not World.grid.is_valid_index(drop.cell):
			continue
		var index := int(at_cell.get(drop.cell, 0))
		at_cell[drop.cell] = index + 1
		var centre := (Vector2(World.grid.coord(drop.cell)) + Vector2(0.5, 0.58)) * tile
		var offset := Vector2((float(index % 3) - 1.0) * 4.0, float(index / 3) * 3.0)
		var at := centre + offset
		if drop.kind == Colony.ESSENCE_KIND:
			var glow := ESSENCE_RADIUS + 1.5 + sin(_pulse + float(drop.id))
			draw_circle(at, glow, Color(0.42, 0.22, 0.92, 0.20))
			draw_circle(at, ESSENCE_RADIUS, Color(0.72, 0.52, 1.0, 0.95))
			draw_circle(at - Vector2(1.2, 1.2), 1.2, Color(0.72, 1.0, 1.0, 0.95))
		else:
			draw_circle(at + Vector2(0, 1), PILE_RADIUS, Color(0, 0, 0, 0.34))
			draw_circle(at, PILE_RADIUS, _color_of(drop.kind))


func _color_of(kind: StringName) -> Color:
	var def := Resources.get_resource(kind)
	if def == null:
		return FALLBACK_COLOR
	return CATEGORY_COLORS.get(def.category, FALLBACK_COLOR)
