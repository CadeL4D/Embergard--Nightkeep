extends CanvasLayer
## "Where do we settle?" — the first decision of a run, made before the clock starts.
##
## Worth having for three reasons. It is the only choice in the game made with zero time
## pressure, so it is the right place to teach that the map is worth reading. It makes the
## generator's work visible — a player who never sees the land cannot know the nest ring or
## the water was ever there. And it creates real trade-offs: forest edge is fast wood and
## no stone, a peninsula is a natural chokepoint with thin resources, open ground is
## balanced and attacked from every side.
##
## Deliberately NOT a separate scene from the run. The run scene already renders the world,
## pans and zooms; this is an overlay on top of it, so the player judges the site in exactly
## the view they will play it in.

signal confirmed(cell: int)

## Camera-relative touch handling is the camera rig's job; this only needs taps. Reuses the
## God Hand's touch target so picking a tile is no fiddlier than picking a villager.
@onready var _status: Label = $SafeArea/Layout/Panel/Rows/Status
@onready var _hint: Label = $SafeArea/Layout/Panel/Rows/Hint
@onready var _confirm: Button = $SafeArea/Layout/Buttons/ConfirmButton
@onready var _suggest: Button = $SafeArea/Layout/Buttons/SuggestButton
@onready var _marker: SiteMarker = $Marker

var _cell: int = -1
var _suggested: int = -1
var _touch_start: Vector2 = Vector2.ZERO
var _touch_time: float = 0.0
var _camera: Camera2D = null


func _ready() -> void:
	visible = false
	set_process_unhandled_input(false)
	_confirm.pressed.connect(_on_confirm)
	_suggest.pressed.connect(func() -> void: _select(_suggested))
	_camera = get_node_or_null("../CameraRig")


func begin(suggested: int) -> void:
	_suggested = suggested
	visible = true
	set_process_unhandled_input(true)
	_select(suggested)
	_hint.text = tr(&"SITE_HINT")


func finish() -> void:
	visible = false
	set_process_unhandled_input(false)


# --- Choosing --------------------------------------------------------------------------

func _select(cell: int) -> void:
	_cell = cell
	var verdict := _judge(cell)
	var ok := bool(verdict["ok"])
	_confirm.disabled = not ok
	_status.text = verdict["text"]
	_status.add_theme_color_override("font_color", UiPalette.OK if ok else UiPalette.DANGER)
	# The marker projects world space itself — see SiteMarker on why it is not a sprite.
	_marker.valid = ok
	_marker.cell = cell


## Can a colony be founded here, and what is here worth?
##
## The rules are only about whether the Hearth will physically fit — a bad-but-legal site is
## the player's business, and refusing anything short of unbuildable would turn the one open
## decision in the game into a guessing game about hidden requirements.
func _judge(cell: int) -> Dictionary:
	if not World.grid.is_valid_index(cell):
		return {"ok": false, "text": tr(&"SITE_OFF_MAP")}
	if not World.is_walkable(cell):
		return {"ok": false, "text": tr(&"SITE_UNBUILDABLE")}

	var c := World.grid.coord(cell)
	# The Hearth is 2x2 anchored up-left of the keep, so those are the cells that must be
	# clear. Everything else about the site is advice, not a rule.
	for dy in range(-1, 1):
		for dx in range(-1, 1):
			if not World.grid.is_valid(c.x + dx, c.y + dy):
				return {"ok": false, "text": tr(&"SITE_TOO_CLOSE_TO_EDGE")}

	return {"ok": true, "text": _describe_site(cell)}


## A one-line read on the surroundings, so the choice is informed rather than aesthetic.
func _describe_site(cell: int) -> String:
	var grid: Grid = World.grid
	var c := grid.coord(cell)
	var trees := 0
	var stone := 0
	var water := 0
	var berries := 0
	const R := 12
	for dy in range(-R, R + 1):
		for dx in range(-R, R + 1):
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			var i := grid.index(c.x + dx, c.y + dy)
			match World.feature_at(i):
				Terrain.Feature.TREE: trees += 1
				Terrain.Feature.STONE: stone += 1
				Terrain.Feature.BERRIES: berries += 1
			var t := World.terrain_at(i)
			if t == Terrain.Type.WATER or t == Terrain.Type.DEEP_WATER:
				water += 1

	var parts := PackedStringArray()
	parts.append(L10n.t(&"SITE_WOOD", [_rate(trees, 40, 110)]))
	parts.append(L10n.t(&"SITE_STONE", [_rate(stone, 12, 40)]))
	parts.append(L10n.t(&"SITE_WATER", [_rate(water, 6, 40)]))
	if berries > 0:
		parts.append(L10n.t(&"SITE_BERRIES", [berries]))
	return "  ·  ".join(parts)


## Static, so it uses Locale.t rather than tr() — tr() is an Object method and there is no self
## in a static context for it to resolve against.
static func _rate(count: int, low: int, high: int) -> String:
	if count >= high:
		return L10n.t(&"SITE_PLENTIFUL")
	if count >= low:
		return L10n.t(&"SITE_SOME")
	return L10n.t(&"SITE_LITTLE")


func _on_confirm() -> void:
	if _cell == -1:
		return
	confirmed.emit(_cell)
	var run := get_parent()
	if run != null and run.has_method("confirm_site"):
		run.confirm_site(_cell)


# --- Input -----------------------------------------------------------------------------
# Taps only, and only the ones the camera rig did not claim for a pan. Sits after
# CameraRig in the scene so the rig sees drags first.

func _unhandled_input(event: InputEvent) -> void:
	if not visible or _camera == null:
		return
	if not (event is InputEventScreenTouch):
		return
	# Cast once, then work with a typed value. Reading `.position` straight off an
	# InputEvent-typed variable gives a Variant, which both warns and defeats inference.
	var touch := event as InputEventScreenTouch

	if touch.pressed:
		_touch_start = touch.position
		_touch_time = float(Time.get_ticks_msec()) / 1000.0
		return

	var elapsed := float(Time.get_ticks_msec()) / 1000.0 - _touch_time
	if elapsed > Accessibility.TAP_MAX_TIME \
			or touch.position.distance_to(_touch_start) > Accessibility.GESTURE_SLOP_PX:
		return
	var world: Vector2 = _camera.get_canvas_transform().affine_inverse() * touch.position
	var cell := World.grid.to_cell_index(world)
	if cell != -1:
		_select(cell)
		get_viewport().set_input_as_handled()
