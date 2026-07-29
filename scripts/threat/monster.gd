class_name Monster
extends Agent
## A Blight creature. Walks the threat flow field toward the keep, attacks whatever
## stands between it and there, and burns in bright light.
##
## Deliberately has almost no AI. It never pathfinds — it reads a direction byte
## from the shared field, which is what lets a hundred of them run at once. All the
## "intelligence" (avoid light, break walls only when going round is worse) lives in
## the field's cost function, not here.

enum State { ADVANCING, ATTACKING, DYING }

## How far ahead to walk the flow field per think. Long enough to keep moving
## smoothly between infrequent thinks, short enough to stay responsive when the
## field is rebuilt.
const PATH_LOOKAHEAD := 8

var def: MonsterDef
var state: State = State.ADVANCING

const TINT_INTERVAL := 0.2

var _attack_timer: float = 0.0
var _target: Node = null
var _anim_time: float = 0.0
var _tint_timer: float = 0.0

@onready var _sprite: Sprite2D = $Sprite


func setup(monster_def: MonsterDef, stat_scale: float = 1.0) -> void:
	def = monster_def
	# The director converts unspendable budget into stat multipliers rather than
	# more bodies, so late nights get harder without exceeding the entity cap.
	max_health = def.max_health * stat_scale
	move_speed = def.move_speed


func _ready() -> void:
	if def == null:
		push_error("Monster added to the tree without setup()")
		return
	super()
	_sprite.texture = def.sprite
	_sprite.hframes = 2
	Threat.register(self)


func _exit_tree() -> void:
	super()
	Threat.unregister(self)


# --- Decisions --------------------------------------------------------------------------

func think(delta: float) -> void:
	_attack_timer = maxf(_attack_timer - delta, 0.0)
	_burn(delta)
	if not alive:
		return

	var victim := _find_target()
	if victim != null:
		_target = victim
		state = State.ATTACKING
		stop()
		if _attack_timer <= 0.0:
			_strike(victim)
		return

	_target = null
	state = State.ADVANCING
	_advance()


## Standing in bright light hurts. This is the mechanical teeth behind "monsters
## fear the light" — the flow field routes them around it, and anything that pushes
## through anyway pays for it.
func _burn(delta: float) -> void:
	if def.burn_per_second <= 0.0:
		return
	var lit := World.light_at(cell())
	if lit < def.burn_threshold:
		return
	var scale := float(lit - def.burn_threshold) / float(maxi(255 - def.burn_threshold, 1))
	take_damage(def.burn_per_second * scale * delta)


func _advance() -> void:
	if is_moving():
		return
	var field: FlowField = Threat.threat_field
	if field == null:
		return
	var path := field.path_from(cell(), PATH_LOOKAHEAD)
	if path.is_empty():
		return
	follow_path(path)


## Nearest thing worth hitting inside attack range: a villager first, then whatever
## structure is in the way. Villagers outrank buildings so monsters that break into
## a keep go for the people rather than politely demolishing the furniture.
func _find_target() -> Node:
	var reach := def.attack_range * Grid.TILE_SIZE
	var reach_sq := reach * reach

	var best: Node = null
	var best_dist := reach_sq
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		var d := position.distance_squared_to(v.position)
		if d <= best_dist:
			best_dist = d
			best = v
	if best != null:
		return best

	# Melee creatures chew through whatever blocks them; ranged ones do so little
	# structural damage that it is not worth stopping for.
	if def.structure_damage_scale < 0.5:
		return null
	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site() or not b.def.blocks_movement:
			continue
		var d := position.distance_squared_to(b.centre_position())
		if d <= best_dist:
			best_dist = d
			best = b
	return best


func _strike(victim: Node) -> void:
	_attack_timer = def.attack_cooldown
	facing = (victim.global_position - position).normalized()
	if victim is Building:
		victim.take_damage(def.damage * def.structure_damage_scale)
		Events.breach_detected.emit(victim.global_position)
	else:
		victim.take_damage(def.damage, self)


# --- Presentation ---------------------------------------------------------------------------

## Guarded writes: assigning `frame` or `flip_h` dirties the canvas item even when
## the value has not changed, and with 120 monsters that showed up in the frame
## budget as pure overhead.
func _process(delta: float) -> void:
	super(delta)
	_anim_time += delta * (5.0 if is_moving() else 1.5)
	var want_frame := int(_anim_time) % 2
	if _sprite.frame != want_frame:
		_sprite.frame = want_frame
	if absf(facing.x) > 0.05:
		var want_flip := facing.x < 0.0
		if _sprite.flip_h != want_flip:
			_sprite.flip_h = want_flip

	_tint_timer -= delta
	if _tint_timer <= 0.0:
		_tint_timer = TINT_INTERVAL
		_apply_tint()


## Monsters glow faintly with corruption in the dark.
##
## Without this they are unplayable: the night CanvasModulate crushes an already
## dark magenta sprite to near-black, so an attacking wave was genuinely invisible
## against unlit ground. Boosting them in darkness rather than lightening the night
## keeps the world gloomy while making the threat readable — and it reads as the
## Blight being luminous, which is better than it being merely lit.
func _apply_tint() -> void:
	var lit := float(World.light_at(cell())) / 255.0
	# Full boost in pitch dark, no boost when standing in bright light — where the
	# world is bright enough to show them anyway, and where they are burning.
	var boost := lerpf(1.0, 0.0, lit)
	var tint := Color(
		1.0 + 1.05 * boost,
		1.0 + 0.35 * boost,
		1.0 + 0.85 * boost
	)
	if not _sprite.modulate.is_equal_approx(tint):
		_sprite.modulate = tint


func on_death(_cause: StringName) -> void:
	state = State.DYING
