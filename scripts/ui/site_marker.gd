class_name SiteMarker
extends Control
## Draws the ring on the tile the site picker has selected.
##
## A Control that projects world space itself, rather than a Sprite2D parented to the
## picker's CanvasLayer. A CanvasLayer does not follow the camera, so a sprite inside one
## sits at a fixed spot on the screen while the map slides underneath — the marker would
## have pointed at the wrong tile the moment the player panned.
##
## Same approach as BreachMarkers: read the camera transform, draw in screen space.

## Tiles of the guaranteed-dry pad, drawn as a footprint preview so the player can see how
## much flat ground they are being given.
var pad_radius: int = 5

var cell: int = -1:
	set(value):
		cell = value
		queue_redraw()

var valid: bool = true:
	set(value):
		valid = value
		queue_redraw()

var _camera: Camera2D = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad_radius = MapGen.KEEP_PAD_RADIUS
	_camera = get_node_or_null("../../CameraRig")


func _process(_delta: float) -> void:
	# The camera can pan and zoom while the picker is open, so the projection has to be
	# redone continuously — the selection is static but its screen position is not.
	if visible and cell != -1:
		queue_redraw()


func _draw() -> void:
	if cell == -1 or _camera == null or not World.grid.is_valid_index(cell):
		return

	var xform := _camera.get_canvas_transform()
	var tint := UiPalette.OK if valid else UiPalette.DANGER
	var tile := float(Grid.TILE_SIZE) * _camera.zoom.x

	# The pad, so "settle here" shows what it actually buys.
	var pad := float(pad_radius) * tile
	var origin: Vector2 = xform * World.grid.to_world_index(cell)
	draw_rect(Rect2(origin - Vector2(pad, pad), Vector2(pad, pad) * 2.0),
		Color(tint, 0.10), true)
	draw_rect(Rect2(origin - Vector2(pad, pad), Vector2(pad, pad) * 2.0),
		Color(tint, 0.45), false, 1.0)

	# The Hearth's 2x2 footprint, anchored up-left of the chosen cell exactly as
	# Run._raise_hearth does it.
	var foot := Rect2(origin - Vector2(tile, tile), Vector2(tile, tile) * 2.0)
	draw_rect(foot, Color(tint, 0.30), true)
	draw_rect(foot, tint, false, 1.5)
