class_name TomeDef
extends Resource
## One kind of Tome a priest can write. Lives as a .tres in res://content/tomes/.
##
## Tomes are the POSITIVE half of the divine economy, and they are deliberately perishable while
## ability Burden is permanent. That asymmetry is the whole tension: your obligations do not
## expire and your income does, so a Temple can never be "finished" — priests are an ongoing
## commitment rather than a one-time build.
##
## Which also means it is a real production chain, labour -> Tome -> Faith rate, putting the divine
## layer on the same footing as the material chains rather than being a special case beside them.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

## Faith per second this grants at tier 1, before toughness.
@export var faith_rate: float = 0.18

## Multiplier applied per tier above the first, compounding. At 1.9 a tier 3 is ~3.6x a tier 1,
## which is worth the six writes and two combines it took to get there.
@export var tier_scale: float = 1.9

@export_group("Wear")
## Shifts the toughness roll. A tome with a low bonus and a high bias is the "humble but lasts
## forever" archetype, and it is deliberately competitive with the flashy ones.
@export var toughness_bias: float = 0.0

@export_group("Tradeoff")
## Only produces while it is dark. Roughly a third of the cycle, so the rate has to be much
## higher to compensate — and it arrives exactly when powers are being spent.
@export var night_only: bool = false

## Mood removed from the whole colony while this is installed.
##
## A real cost rather than a flavour line: mood drives Faith generation, so an austere tome
## partially eats its own output, and it eats more of it in a colony that was already miserable.
@export var mood_penalty: float = 0.0

@export var color: Color = Color(0.82, 0.78, 0.95)
@export var order: int = 0
