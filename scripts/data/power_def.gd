class_name PowerDef
extends Resource
## One divine power. Lives as a .tres in res://content/powers/.
##
## Powers are the Faith sink, and Faith comes from colony morale — so every miracle
## is ultimately paid for by having looked after your people. Keeping that chain
## short and legible is the point of the whole economy.

## What the power does where it lands. New kinds go on the END — .tres files store
## the integer index.
enum Kind {
	LIGHT,     ## drops a lasting light source
	SMITE,     ## immediate damage to every monster in radius
	PURIFY,    ## clears blight in radius
	BUFF,      ## strengthens or steadies the villagers in radius
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export var kind: Kind = Kind.SMITE
@export var faith_cost: float = 20.0
@export var cooldown: float = 6.0
## Radius in tiles.
@export var radius: int = 4
## Damage for SMITE, light strength for LIGHT, purification for PURIFY.
@export var amount: float = 30.0
## Seconds the effect persists. Zero means instantaneous.
@export var duration: float = 0.0

@export_group("Buff")
## Mood added outright to every villager in radius. Feeds straight back into Faith generation,
## which is why Blessing is the power that pays for itself.
@export var mood_boost: float = 0.0
## Extra movement, as a fraction: 0.5 is +50%.
@export var speed_boost: float = 0.0
## Extra melee damage, as a fraction of Villager.GUARD_DAMAGE.
@export var damage_boost: float = 0.0
## Seconds the speed and damage boosts last. Mood is instant and permanent, so it ignores this.
@export var boost_duration: float = 0.0

@export_group("Progression")
## Relic Shards to unlock permanently, across runs. Mirrors BuildingDef.unlock_cost exactly, so
## powers and buildings are ONE system to learn rather than two.
@export var unlock_cost: int = 0

## Temple tier that must be standing before this can be taken up at all.
##
## Zero means no Temple needed. The three powers the game shipped with are deliberately left at
## zero: Emberfall and Wrath are the core loop, and putting them behind a 20-stone building and ten
## survivors would gut the opening rather than deepen it. The Temple is additive.
@export var required_temple_tier: int = 0

## Faith per second this power costs, permanently, for as long as it is taken up.
##
## The best structural idea in the divine layer, for four reasons:
##   * abilities stop being unlock-and-forget and become a standing cost you have to sustain
##   * the managed resource becomes the faith RATE rather than the pool, and throughput economies
##     are more interesting than banks — the pool reframes as a buffer, i.e. how long you can keep
##     casting while running at a deficit
##   * it self-limits with no arbitrary cap: your ceiling is whatever your colony can support
##   * it brakes the death spiral, because a failing colony can no longer afford its miracles and
##     gets pushed back down the power curve instead of being handed tools it cannot fuel
##
## Which also makes unlocking everything a genuine trap, and restraint a real strategy.
@export var burden: float = 0.0

@export var color: Color = Color(1, 0.75, 0.4)
@export var order: int = 0
