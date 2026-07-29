class_name BuildingDef
extends Resource
## One placeable structure. Lives as a .tres in res://content/buildings/.
##
## Adding a building is adding a file — no system branches on a building id. If you
## catch yourself writing `if def.id == &"watchtower"`, the property you actually
## need is missing from this class; add it here instead.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var sprite: Texture2D

@export_group("Placement")
## Size in tiles. The anchor is the top-left cell.
@export var footprint: Vector2i = Vector2i.ONE
## Solid buildings cannot be walked through — walls, towers. Storage and floors
## stay walkable so hauliers can step onto them.
@export var blocks_movement: bool = true
## Refuse placement on ground more corrupted than this. Building on the Blight
## should be a decision the player has to clear the ground for first.
@export_range(0, 255) var max_blight: int = 40

@export_group("Construction")
## Resource cost, e.g. { &"wood": 20, &"stone": 10 }.
@export var cost: Dictionary = {}
## Villager-seconds of work to raise it once the site is prepared.
@export var build_work: float = 20.0
@export var max_hp: float = 100.0

@export_group("Function")
## Tiles of light emitted once complete. This feeds the gameplay light grid, not
## just the renderer — a lit building genuinely holds back the Blight and steadies
## the villagers working near it.
@export var light_radius: int = 0
## Whether gatherers may deposit their loads here.
@export var is_stockpile: bool = false
## Beds provided. Villagers recover rest far faster indoors.
@export var sleep_slots: int = 0
## How many villagers of a matching job may work here at once.
@export var worker_slots: int = 0

@export_group("Defence")
## Damage per shot. Zero means the building does not fight.
@export var attack_damage: float = 0.0
## Range in tiles. Should comfortably exceed a Spitter's reach, or towers get
## picked apart by something they cannot answer.
@export var attack_range: float = 6.0
@export var attack_cooldown: float = 0.9

@export_group("Board")
@export var order: int = 0
@export var color: Color = Color.WHITE
## Relic Shards to unlock permanently. Zero means available from the first run.
## This is how the meta loop adds OPTIONS rather than raw power — a new building
## changes what a run can become, where a flat stat bonus just makes it easier.
@export var unlock_cost: int = 0


func cost_text() -> String:
	if cost.is_empty():
		return "free"
	var parts: PackedStringArray = PackedStringArray()
	for kind: StringName in cost:
		parts.append("%d %s" % [int(cost[kind]), kind])
	return ", ".join(parts)


func tile_size() -> Vector2i:
	return footprint * Grid.TILE_SIZE
