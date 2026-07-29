extends Node2D
## The visual for the Ember — the game's signature object and the only genuinely
## warm, bright thing on screen.
##
## Purely presentational: it follows Divine.ember_cell and never sets it. The light
## and the glow sprite are real nodes on the scene, so their colour, energy and
## texture are editable in the inspector without touching code.
##
## The aura ring is the one thing still drawn in code, because it is genuinely
## dynamic geometry — its radius tracks Divine.ember_radius as relics upgrade it,
## and a scaled ring texture would blur the 1px outline that makes the boundary
## readable. That readability is not decoration: the player has to see exactly which
## villagers and which blighted tiles are inside the aura, or the core mechanic
## becomes guesswork.

const PULSE_SPEED := 2.2
const PULSE_AMOUNT := 0.12
const BASE_ENERGY := 1.5
const RING_COLOR := Color("ff8a3c")

@onready var light: PointLight2D = $Light
@onready var glow: Sprite2D = $Glow

var _pulse: float = 0.0


func _ready() -> void:
	_apply_radius()


func _process(delta: float) -> void:
	_pulse += delta * PULSE_SPEED
	var breath := 1.0 + sin(_pulse) * PULSE_AMOUNT
	light.energy = BASE_ENERGY * breath
	light.texture_scale = _texture_scale() * breath
	glow.scale = Vector2.ONE * (0.9 + (breath - 1.0) * 0.5)
	queue_redraw()


## The aura boundary. Drawn as a dashed, slowly-rotating ring rather than a faint
## solid one: in daylight the PointLight2D contributes almost nothing, so without a
## clearly readable ring the player simply cannot see how far the Ember's influence
## reaches — and that radius decides work speed, morale and blight suppression.
func _draw() -> void:
	var r := float(Divine.ember_radius) * Grid.TILE_SIZE
	draw_circle(Vector2.ZERO, r, Color(RING_COLOR, 0.07))

	var segments := 40
	var arc := TAU / float(segments)
	var spin := _pulse * 0.15
	for i in segments:
		if i % 2 == 1:
			continue
		var from := spin + arc * i
		draw_arc(Vector2.ZERO, r, from, from + arc * 0.85, 4,
			Color(RING_COLOR, 0.75), 2.0, true)


func _apply_radius() -> void:
	light.texture_scale = _texture_scale()


## The falloff texture is 256 px across, so scale it to cover the gameplay radius in
## world units. Keeping the light and the aura ring in agreement matters more than
## either looking good on its own — a glow that extends past the ring would promise
## a bonus the sim does not actually give.
func _texture_scale() -> float:
	return (float(Divine.ember_radius) * Grid.TILE_SIZE * 2.0) / 256.0
