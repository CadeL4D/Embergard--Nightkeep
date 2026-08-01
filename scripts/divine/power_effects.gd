extends Node2D
## World-space miracle feedback. Mechanics resolve immediately in Divine; this view
## gives each cast a readable arrival, radius, and lingering identity.

var effects: Array[Dictionary] = []
var _redraw_accum: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Events.power_cast.connect(_on_power_cast)
	set_process(false)


func _on_power_cast(power_id: StringName, world_pos: Vector2) -> void:
	var def := Powers.get_power(power_id)
	if def == null:
		return
	var life := 1.1
	match power_id:
		&"emberfall":
			life = maxf(def.duration, 1.4)
		&"ward":
			life = 1.35
		&"wrath":
			life = 0.9
	effects.append({
		"id": power_id,
		"pos": world_pos,
		"age": 0.0,
		"life": life,
		"radius": float(def.radius * Grid.TILE_SIZE),
		"color": def.color,
	})
	set_process(true)
	queue_redraw()


func _process(delta: float) -> void:
	var kept: Array[Dictionary] = []
	for effect: Dictionary in effects:
		effect["age"] = float(effect["age"]) + delta
		if float(effect["age"]) < float(effect["life"]):
			kept.append(effect)
	effects = kept
	var interval := Accessibility.animation_interval()
	_redraw_accum += delta
	if interval <= 0.0 or _redraw_accum >= interval:
		_redraw_accum = 0.0
		queue_redraw()
	if effects.is_empty():
		set_process(false)


func _draw() -> void:
	for effect: Dictionary in effects:
		match StringName(effect["id"]):
			&"emberfall":
				_draw_emberfall(effect)
			&"ward":
				_draw_ward(effect)
			&"wrath":
				_draw_wrath(effect)
			_:
				_draw_generic(effect)


func _draw_emberfall(effect: Dictionary) -> void:
	var pos: Vector2 = effect["pos"]
	var age := float(effect["age"])
	var radius := float(effect["radius"])
	var color: Color = effect["color"]
	var burst := clampf(age / 1.2, 0.0, 1.0)
	var arrival_alpha := 1.0 - burst

	# A shaft falls out of the sky, then leaves a live ember-pool for the full
	# mechanical light duration instead of becoming an invisible buff.
	if age < 1.2:
		var head_y := pos.y - lerpf(150.0, 0.0, ease(burst, -2.0))
		for offset in [-7.0, -2.0, 3.0, 8.0]:
			draw_line(Vector2(pos.x + offset, head_y - 54.0), Vector2(pos.x + offset, pos.y),
				Color(color.r, color.g, color.b, arrival_alpha * 0.38), 2.0, true)
		draw_circle(Vector2(pos.x, head_y), 5.0 + 8.0 * arrival_alpha,
			Color(1.0, 0.92, 0.58, 0.85 * arrival_alpha))
		draw_arc(pos, radius * burst, 0.0, TAU, 48,
			Color(color.r, color.g, color.b, arrival_alpha), 2.2, true)

	var pulse := 0.5 + sin(age * 4.0) * 0.12
	draw_circle(pos, radius * (0.88 + pulse * 0.08),
		Color(color.r, color.g * 0.82, 0.18, 0.055 + pulse * 0.025))
	draw_arc(pos, radius * 0.96, 0.0, TAU, 48,
		Color(color.r, color.g, color.b, 0.22 + pulse * 0.08), 1.2, true)
	for i in 12:
		var angle := float(i) * TAU / 12.0 + age * (0.18 if i % 2 == 0 else -0.12)
		var distance := radius * (0.22 + float((i * 7) % 10) / 16.0)
		var mote := pos + Vector2.from_angle(angle) * distance
		mote.y -= 2.0 + fmod(age * (7.0 + float(i % 3) * 2.0), 10.0)
		draw_circle(mote, 1.2 if i % 3 else 1.8,
			Color(1.0, 0.72, 0.26, 0.48))


func _draw_ward(effect: Dictionary) -> void:
	var pos: Vector2 = effect["pos"]
	var age := float(effect["age"])
	var life := float(effect["life"])
	var radius := float(effect["radius"])
	var color: Color = effect["color"]
	var t := clampf(age / life, 0.0, 1.0)
	var alpha := 1.0 - t
	draw_circle(pos, radius * (0.35 + t * 0.65),
		Color(color.r * 0.55, color.g, color.b, alpha * 0.13))
	for ring in 3:
		var ring_t := clampf(t * 1.35 - float(ring) * 0.14, 0.0, 1.0)
		draw_arc(pos, radius * (0.28 + ring_t * 0.72), 0.0, TAU, 48,
			Color(color.r, color.g, color.b, alpha * (0.75 - ring * 0.14)), 1.8, true)
	for i in 8:
		var angle := float(i) * TAU / 8.0 + t * 0.35
		var inner := pos + Vector2.from_angle(angle) * radius * 0.62
		var tangent := Vector2.from_angle(angle + PI * 0.5) * 4.0
		draw_line(inner - tangent, inner + tangent,
			Color(0.78, 1.0, 0.82, alpha * 0.82), 1.8, true)


func _draw_wrath(effect: Dictionary) -> void:
	var pos: Vector2 = effect["pos"]
	var age := float(effect["age"])
	var life := float(effect["life"])
	var radius := float(effect["radius"])
	var color: Color = effect["color"]
	var t := clampf(age / life, 0.0, 1.0)
	var alpha := 1.0 - t
	draw_circle(pos, radius * (0.24 + t * 0.8),
		Color(color.r, color.g * 0.62, color.b * 0.45, alpha * 0.23))
	draw_arc(pos, radius * (0.2 + t * 0.8), 0.0, TAU, 40,
		Color(1.0, 0.74, 0.42, alpha * 0.9), 2.4, true)

	for bolt in 3:
		var points := PackedVector2Array()
		var start := pos + Vector2((bolt - 1) * 18.0, -135.0)
		for segment in 8:
			var progress := float(segment) / 7.0
			var jitter := sin(float(segment * 19 + bolt * 31)) * (8.0 * (1.0 - progress))
			points.append(start.lerp(pos, progress) + Vector2(jitter, 0.0))
		draw_polyline(points, Color(1.0, 0.88, 0.58, alpha), 2.2, true)
	for crack in 10:
		var angle := float(crack) * TAU / 10.0 + 0.23
		var inner := pos + Vector2.from_angle(angle) * radius * 0.22
		var outer := pos + Vector2.from_angle(angle + sin(float(crack)) * 0.12) \
			* radius * (0.62 + float(crack % 3) * 0.13)
		draw_line(inner, outer, Color(color.r, color.g, color.b, alpha * 0.72), 1.5, true)


func _draw_generic(effect: Dictionary) -> void:
	var age := float(effect["age"])
	var life := float(effect["life"])
	var t := clampf(age / life, 0.0, 1.0)
	var color: Color = effect["color"]
	color.a = 1.0 - t
	draw_arc(effect["pos"], float(effect["radius"]) * t, 0.0, TAU, 40, color, 2.0, true)
