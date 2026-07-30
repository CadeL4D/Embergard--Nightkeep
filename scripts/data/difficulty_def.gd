class_name DifficultyDef
extends Resource
## One difficulty tier, chosen when a world is created. Lives as a .tres in
## res://content/difficulties/.
##
## Every field is a MULTIPLIER on an existing tuned value rather than a replacement for
## one. That is deliberate: there is exactly one balance curve in this game and four
## lenses onto it, so tuning the game tunes all four tiers at once. A tier that carried
## its own absolute numbers would drift out of step with the base game within a month.
##
## Adding a tier is dropping in a file. Nothing in the sim branches on a difficulty id.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export_group("Pressure")
## Scales the nightly threat budget. See Threat.budget_for_night().
@export var threat_mult: float = 1.0
## Scales how fast the Blight spreads. See BlightField.BASE_SPREAD.
@export var blight_mult: float = 1.0
## Brings nastier monsters forward by this many nights. Positive makes a tier harder:
## a shift of 2 means night 3 draws from night 5's roster.
@export var monster_night_shift: int = 0

@export_group("Colony")
## Scales hunger, thirst and exhaustion decay. Above 1.0 means needs bite sooner.
@export var needs_mult: float = 1.0
## Scales how readily new survivors arrive.
@export var migration_mult: float = 1.0
## Added to the founding band. May be negative.
@export var start_pop_bonus: int = 0

@export_group("Reward")
## Scales the Relic Shard payout. Must rise with the tier — a harder run that pays the
## same is a run nobody sane picks, and the whole point of shipping four tiers is that
## all four get played.
@export var shard_mult: float = 1.0

@export_group("Menu")
@export var order: int = 0
@export var color: Color = Color.WHITE
