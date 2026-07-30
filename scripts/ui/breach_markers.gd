extends Control
## Screen-edge arrows pointing at things being attacked off-camera.
##
## `Events.breach_detected` has been emitted with a world position from
## Monster._strike since the day walls existed, and nothing has ever listened. The
## consequence is the single worst readability hole in the game: at night the camera shows
## one corner of the colony, a Shambler starts eating a palisade on the far side, and the
## player finds out when the wall is gone.
##
## Deliberately only marks OFF-SCREEN breaches. An arrow pointing at something already
## visible is clutter, and clutter during a night wave is worse than silence.

## How long a marker lives after its last hit. Long enough to survive the gap between an
## attacker's swings (a Shambler's cooldown is 1.3s) so a sustained attack shows a steady
## arrow rather than a flicker.
const MARKER_LIFETIME := 2.2

## Inset from the screen edge, in screen pixels.
const EDGE_MARGIN := 18.0

## Breaches closer together than this share one marker, so a pack chewing the same wall
## does not stack six arrows on top of each other.
const MERGE_DISTANCE := 48.0

const ARROW_SIZE := 7.0

## [{pos: Vector2 (world), age: float}]
var _breaches: Array = []

var _camera: Camera2D = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	Events.breach_detected.connect(_on_breach)
	Events.run_started.connect(func(_s: int) -> void: _breaches.clear())
	_camera = get_node_or_null("../../CameraRig")
	if _camera == null:
		# Not fatal: the HUD is also dropped into UI-only test scenes with no world.
		set_process(false)


func _on_breach(world_pos: Vector2) -> void:
	for b in _breaches:
		if b["pos"].distance_to(world_pos) < MERGE_DISTANCE:
			b["age"] = 0.0
			return
	_breaches.append({"pos": world_pos, "age": 0.0})


func _process(delta: float) -> void:
	if _breaches.is_empty():
		return
	var kept: Array = []
	for b in _breaches:
		b["age"] += delta
		if b["age"] < MARKER_LIFETIME:
			kept.append(b)
	_breaches = kept
	queue_redraw()


func _draw() -> void:
	if _breaches.is_empty() or _camera == null:
		return

	var view := get_viewport_rect().size
	var centre := view * 0.5
	# The safe box the marker is pinned to. Anything inside it is on screen and needs no
	# arrow; anything outside gets clamped to the boundary.
	var half := view * 0.5 - Vector2(EDGE_MARGIN, EDGE_MARGIN)
	var xform := _camera.get_canvas_transform()

	for b in _breaches:
		var screen: Vector2 = xform * b["pos"]
		var offset := screen - centre
		if absf(offset.x) < half.x and absf(offset.y) < half.y:
			continue    # visible already; the flash on the building itself is the cue

		# Project onto the edge box: scale the offset so the longer axis lands exactly on
		# the boundary. Cheaper and steadier than a rectangle-ray intersection, and the
		# marker slides along the edge as the camera pans, which is what reads as
		# "something is over there".
		# Not named `scale` — Control already has a property by that name and shadowing it
		# here would trip the shadowed-variable warning.
		var k := 1.0
		if absf(offset.x) > 0.001:
			k = minf(k, half.x / absf(offset.x))
		if absf(offset.y) > 0.001:
			k = minf(k, half.y / absf(offset.y))
		var at := centre + offset * k

		# Fade as it expires so a resolved breach releases the player's attention rather
		# than snapping off.
		var fade: float = 1.0 - (b["age"] / MARKER_LIFETIME)
		_draw_arrow(at, offset.angle(), UiPalette.DANGER * Color(1, 1, 1, fade))


func _draw_arrow(at: Vector2, angle: float, color: Color) -> void:
	var forward := Vector2.RIGHT.rotated(angle)
	var side := forward.orthogonal()
	var points := PackedVector2Array([
		at + forward * ARROW_SIZE,
		at - forward * ARROW_SIZE * 0.6 + side * ARROW_SIZE * 0.8,
		at - forward * ARROW_SIZE * 0.6 - side * ARROW_SIZE * 0.8,
	])
	draw_colored_polygon(points, color)
	# Dark outline so the arrow survives being drawn over firelight.
	draw_polyline(
		PackedVector2Array([points[0], points[1], points[2], points[0]]),
		Color(UiPalette.BG_DEEP, color.a * 0.9), 1.0)
