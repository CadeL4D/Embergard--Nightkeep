extends Node2D
## Draws the Blight's buildings. A pure VIEW — reads World and never writes to it.
##
## One Sprite2D per structure, created and freed on signals rather than rebuilt from
## `World.blight_structures` each frame: there are only ever a few dozen and they change a handful
## of times a night, so a full rebuild would be work done thousands of times for nothing.
##
## Sits inside the Y-sorted Entities parent so a villager walking in front of a spire draws over it,
## exactly as it would for one of the player's own buildings.

## cell -> Sprite2D
var _sprites: Dictionary = {}


func _ready() -> void:
	Events.blight_structure_raised.connect(_on_raised)
	Events.blight_structure_razed.connect(_on_razed)
	# A loaded run restores the dictionary wholesale without ever emitting the raised signal, so the
	# view has to be able to catch up from scratch.
	Events.map_generated.connect(rebuild)


func rebuild() -> void:
	for cell in _sprites.keys():
		_free_sprite(cell)
	for cell in World.blight_structures:
		_on_raised(cell, World.blight_structures[cell]["kind"])


func _on_raised(cell: int, kind: StringName) -> void:
	if _sprites.has(cell):
		return
	var def := BlightStructures.get_structure(kind)
	if def == null or def.sprite == null:
		return

	var sprite := Sprite2D.new()
	sprite.texture = def.sprite
	sprite.centered = false
	# Art is authored top-left-origin and these are anchored at the BASE of their cell, so the sprite
	# is lifted by its own height. A two-tile spire therefore overhangs the tile above it visually
	# while occupying only the one cell it actually blocks — the same trick the player's buildings use.
	sprite.offset = Vector2(0, -float(def.height_tiles * Grid.TILE_SIZE))
	var c := World.grid.coord(cell)
	sprite.position = Vector2(c.x * Grid.TILE_SIZE, (c.y + 1) * Grid.TILE_SIZE)
	add_child(sprite)
	_sprites[cell] = sprite


func _on_razed(cell: int) -> void:
	_free_sprite(cell)


func _free_sprite(cell: int) -> void:
	if not _sprites.has(cell):
		return
	var sprite: Node = _sprites[cell]
	_sprites.erase(cell)
	if is_instance_valid(sprite):
		remove_child(sprite)
		sprite.queue_free()
