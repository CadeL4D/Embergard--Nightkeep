class_name Animal
extends Agent
## Lightweight colony animal. Animals contribute Influence and can be moved by the God Hand.

var animal_kind: StringName = &"animal"
var selected := false
var _wander_serial := 0

@onready var _sprite: Sprite2D = $Sprite


func setup(kind: StringName) -> void:
	animal_kind = kind
	match animal_kind:
		&"doggo":
			move_speed = 30.0
			max_health = 38.0
		&"doofy_doggo":
			move_speed = 23.0
			max_health = 55.0
		_:
			move_speed = 22.0
			max_health = 28.0


func _ready() -> void:
	super()
	setup(animal_kind)
	health = max_health
	Colony.animals.append(self)
	DivineLedger.register_animal(animal_kind, 1)
	if _sprite != null:
		_sprite.modulate = {
			&"doggo": Color("d8ad69"), &"doofy_doggo": Color("f0d28b"),
		}.get(animal_kind, Color("9d7957"))


func _exit_tree() -> void:
	Colony.animals.erase(self)
	DivineLedger.register_animal(animal_kind, -1)
	super()


func think(_delta: float) -> void:
	if not alive or held_by_hand or is_moving():
		return
	_wander_serial += 1
	# Doggos stay near the Ember; ordinary animals meander around their current patch.
	var origin := Divine.ember_cell if animal_kind in [&"doggo", &"doofy_doggo"] \
		and Divine.ember_cell != -1 else cell()
	var offsets := [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2),
		Vector2i(1, 1), Vector2i(-1, -1)]
	var offset: Vector2i = offsets[posmod(World.seed_value + Sim.day * 17 \
		+ _wander_serial * 7 + cell(), offsets.size())]
	var target := World.grid.index_v(World.grid.coord(origin) + offset)
	if World.grid.is_valid_index(target) and World.is_walkable(target):
		follow_path(PackedInt32Array([cell(), target]))


func on_death(cause: StringName) -> void:
	spawn_death_ghost(_sprite)
	if animal_kind in [&"doggo", &"doofy_doggo"]:
		Colony.drop_resource(&"ghost_dust", 1, cell(), &"unbound_soul")
	Events.notice.emit("%s was lost (%s)" % [display_name(), String(cause)], 1)


func display_name() -> String:
	match animal_kind:
		&"doggo": return "Doggo"
		&"doofy_doggo": return "Doofy Doggo"
	return "Animal"
