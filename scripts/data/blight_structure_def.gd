class_name BlightStructureDef
extends Resource
## One thing the Blight builds for itself. Lives as a .tres in res://content/blight/.
##
## The corruption stops being weather and becomes an OPPONENT here. Before this, nests sat where the
## generator put them and the only thing that ever changed was how many monsters came out; now the
## Blight spends its nights raising a settlement, and the map the player has to take back is one the
## enemy has been developing too.
##
## Deliberately modelled on nests rather than on the player's Building, because a nest is already
## exactly the right shape: a cell in the world with hit points that towers and miracles can whittle
## down and whose death opens the ground. Reusing that path means these inherit tower targeting,
## Wrath, Ward, Consecrate, save/load and the end-of-run tally with no new integration.

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var sprite: Texture2D

@export_group("Body")
@export var max_hp: float = 60.0
## Tiles tall the art is. Sprites are one tile WIDE and drawn from the base upward, so a 2-tile
## spire overhangs the cell above it visually while occupying only its own.
@export var height_tiles: int = 1

@export_group("Growth")
## Earliest night this kind can be raised, so the enemy's settlement unfolds like the roster does.
@export var min_night: int = 2
## Relative likelihood of being chosen once eligible.
@export var weight: float = 1.0
## Physical Blight mass carried by workers and spent to raise this structure.
@export var mass_cost: int = 8
## Additional worker capacity supplied while this structure stands.
@export var worker_capacity: int = 0
@export var repairs_workers: bool = false
@export var economy_role: StringName = &""

@export_group("Effect")
## Added to the night's threat budget while this stands.
##
## The reason a player must go and break these rather than turtling: left alone, the Blight's
## village makes every night worse than the curve says it should be, so the difficulty the player
## faces is partly a consequence of ground they chose not to contest.
@export var threat_bonus: float = 0.0

## Blight intensity pushed into the surrounding tiles on each growth pass. Turns a structure into a
## secondary corruption source, so a spire left standing spreads rot that its nest alone would not.
@export var blight_seed: int = 0

## Extra light this throws, 0-255. A lit enemy camp is a real problem: light suppresses blight
## spread and burns monsters, so the Blight would never build one — this exists for the totem, whose
## glow is corruption's own and is the tell that something is empowering the horde.
@export_range(0, 255) var glow: int = 0

## Multiplier on the stats of monsters spawned while this stands.
@export var monster_scale: float = 1.0
@export var mass_harvest_multiplier: float = 1.0

@export_group("Defence")
@export var attack_damage: float = 0.0
@export var attack_range: float = 0.0
@export var attack_cooldown: float = 1.0
@export var attack_type: StringName = &"blight"
@export var resistances: Dictionary = {}

@export var color: Color = Color(0.56, 0.14, 0.34)
@export var order: int = 0
