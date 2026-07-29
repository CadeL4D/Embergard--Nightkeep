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

@export var color: Color = Color(1, 0.75, 0.4)
@export var order: int = 0
