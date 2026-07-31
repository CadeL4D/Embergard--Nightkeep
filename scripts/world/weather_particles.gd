extends Control
## Lightweight procedural weather drawn above the world and below every menu.

var weather: StringName = &"clear"
var severity: float = 0.0
var _time: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func set_weather(id: StringName, amount: float) -> void:
	weather = id
	severity = clampf(amount, 0.0, 1.0)
	queue_redraw()


func _process(delta: float) -> void:
	if weather == &"clear" or severity <= 0.05:
		return
	_time += delta * (0.15 if Accessibility.reduced_motion else 1.0)
	queue_redraw()


func _draw() -> void:
	var count := roundi(lerpf(18.0, 94.0, severity))
	match weather:
		&"rain", &"storm":
			_draw_rain(count, weather == &"storm")
		&"snow":
			_draw_snow(roundi(count * 0.72))
		&"fog":
			_draw_fog()
		&"drought", &"heatwave":
			_draw_heat(roundi(count * 0.35))


func _draw_rain(count: int, storm: bool) -> void:
	var speed := 260.0 if storm else 170.0
	var length := 13.0 if storm else 8.0
	var color := Color(0.58, 0.73, 0.82, 0.38 if storm else 0.25)
	for i in count:
		var x := fmod(float(i * 83 + 17), maxf(size.x + 80.0, 1.0)) - 40.0
		var phase := fmod(_time * speed + float(i * 47), maxf(size.y + 50.0, 1.0)) - 25.0
		draw_line(Vector2(x, phase), Vector2(x - length * 0.42, phase + length),
			color, 1.0, false)


func _draw_snow(count: int) -> void:
	var speed := 28.0
	for i in count:
		var drift := sin(_time * 0.8 + float(i) * 1.71) * 12.0
		var x := fmod(float(i * 97 + 11), maxf(size.x, 1.0)) + drift
		var y := fmod(_time * speed + float(i * 59), maxf(size.y + 20.0, 1.0)) - 10.0
		var radius := 0.8 + float(i % 3) * 0.45
		draw_circle(Vector2(x, y), radius, Color(0.86, 0.91, 0.93, 0.48))


func _draw_fog() -> void:
	for i in 7:
		var y := size.y * (0.12 + float(i) * 0.135)
		var drift := sin(_time * 0.17 + float(i) * 1.9) * 24.0
		draw_line(Vector2(-30.0 + drift, y), Vector2(size.x + 30.0 + drift, y),
			Color(0.62, 0.68, 0.67, 0.045 + severity * 0.035), 18.0, true)


func _draw_heat(count: int) -> void:
	for i in count:
		var x := fmod(float(i * 113 + 31), maxf(size.x, 1.0))
		var y := fmod(_time * 14.0 + float(i * 71), maxf(size.y, 1.0))
		draw_circle(Vector2(x, size.y - y), 0.7 + float(i % 2) * 0.5,
			Color(0.83, 0.66, 0.35, 0.18))
