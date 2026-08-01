extends CanvasLayer
## Gives every climate state a readable atmosphere without covering gameplay or menus.

@onready var _tint: ColorRect = $Tint
@onready var _particles: Control = $Particles


func _ready() -> void:
	Climate.changed.connect(_refresh)
	Accessibility.changed.connect(func(kind: StringName) -> void:
		if kind == &"motion" or kind == &"graphics":
			_refresh()
	)
	_refresh()


func _refresh() -> void:
	var tint := Color.TRANSPARENT
	match Climate.weather:
		&"rain":
			tint = Color(0.16, 0.25, 0.29, 0.06 + Climate.severity * 0.05)
		&"storm":
			tint = Color(0.08, 0.13, 0.19, 0.12 + Climate.severity * 0.08)
		&"fog":
			tint = Color(0.52, 0.57, 0.54, 0.08 + Climate.severity * 0.07)
		&"snow":
			tint = Color(0.64, 0.72, 0.76, 0.06 + Climate.severity * 0.05)
		&"drought":
			tint = Color(0.42, 0.27, 0.10, 0.06 + Climate.severity * 0.04)
		&"heatwave":
			tint = Color(0.53, 0.23, 0.08, 0.07 + Climate.severity * 0.05)
	_tint.color = tint
	_particles.set_weather(Climate.weather, Climate.severity)
