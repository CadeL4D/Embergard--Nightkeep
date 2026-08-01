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

@export_group("Menu")
## Build-menu tab. A free-form name rather than an enum: the tab strip is derived from
## whatever categories the content files actually use (see Buildings.categories), so adding
## a tab is adding a .tres and a locale key — no UI code, no enum to keep in step.
##
## Convention is a lowercase id; the tab label is looked up as TAB_<UPPERCASE>.
@export var category: StringName = &"logistics"

## Village Center tier required before this may be placed. 1 is available from the start.
##
## ONE dial gates the whole building list, which is the cheapest legible progression there is:
## the player learns "raise the Hearth to unlock more" once and it keeps paying off. See
## Colony.center_tier().
@export var tier: int = 1

## This building IS a Village Center of this tier (0 means it is not one).
##
## Expressed as a property rather than as `if def.id == &"hearth"` so a scenario, a biome or a
## later colony type can nominate a different structure as its centre without touching the sim.
@export var center_tier: int = 0

@export_group("Placement")
## Size in tiles. The anchor is the top-left cell.
##
## Deliberately NOT square for most production buildings. Rectangles of assorted proportions
## are what make packing a village an actual puzzle — a grid of 2x2 blocks tiles perfectly and
## therefore decides nothing.
@export var footprint: Vector2i = Vector2i.ONE
## Solid buildings cannot be walked through — walls, towers. Storage and floors
## stay walkable so hauliers can step onto them.
@export var blocks_movement: bool = true
## A gate: villagers walk through freely, monsters do not.
##
## This exists because `blocks_movement` blocks EVERYONE, which makes a completed
## ring of palisade an economic suicide pact — it walls your own woodcutters away
## from the trees. A gate keeps the wall meaningful while leaving the colony able to
## work, and it deliberately becomes a funnel: monsters will break it rather than
## take a long detour, which is exactly where the player wants them.
##
## Mutually exclusive with `blocks_movement` in practice — a cell that villagers
## cannot enter has no need of this flag.
@export var blocks_monsters_only: bool = false
## Refuse placement on ground more corrupted than this. Building on the Blight
## should be a decision the player has to clear the ground for first.
@export_range(0, 255) var max_blight: int = 40

## Ground this building lays down: 0 for none, 1+ for a path of that tier.
##
## A road is a BUILDING, not a new placement system. It gets cost, reservation, hauling,
## demolition, the placement ghost and the sphere-of-influence check for free, and
## `Building.complete()` stamps the tier into World.path_tier from there. The alternative was a
## parallel paint tool that would have needed its own version of all of that.
@export var path_tier: int = 0
## Desktop may paint this one-cell structure along a mouse drag. Data, not an id check:
## walls and roads opt in while gates, towers and ordinary buildings remain one deliberate click.
@export var drag_placeable: bool = false
## Allows this one-cell structure to be placed over shallow water and makes that
## cell walkable once complete. Deep water stays outside the mobile launch scope.
@export var bridges_water: bool = false

@export_group("Construction")
## Resource cost, e.g. { &"wood": 20, &"stone": 10 }.
@export var cost: Dictionary = {}
## Villager-seconds of work to raise it once the site is prepared.
@export var build_work: float = 20.0
@export var max_hp: float = 100.0
## Fractional resistance by DamageTypes id. Positive values reduce damage;
## negative values are vulnerabilities shared with monsters and status effects.
@export var resistances: Dictionary = {}
## One completed repair cycle consumes this cost and restores `repair_amount` HP.
@export var repair_cost: Dictionary = {&"wood": 1}
@export var repair_work: float = 5.0
@export var repair_amount: float = 30.0

## The building this one replaces, upgraded IN PLACE. Empty means it is placed fresh.
##
## Upgrading reuses the blueprint→deliver→build path exactly, because Building's own header
## already notes that path exists to be re-entered. So an upgrade is: revert to a site, haul the
## new cost out, work it up. No parallel construction code, and the footprint is required to
## match so the ground never has to be re-checked.
@export var upgrades_from: StringName = &""

## Survivors required before this may be placed or upgraded to. Zero means no gate.
##
## Paired with `tier` so the upper building list is gated by the colony actually GROWING, not
## just by having stockpiled enough timber. Otherwise a turtled six-person village can buy its
## way to the endgame without ever solving the problem the game is about.
@export var min_population: int = 0

@export_group("Function")
## Tiles of light emitted once complete. This feeds the gameplay light grid, not
## just the renderer — a lit building genuinely holds back the Blight and steadies
## the villagers working near it.
@export var light_radius: int = 0
## Whether gatherers may deposit their loads here.
@export var is_stockpile: bool = false
## Villagers may drink here. A well is how you get water INSIDE your walls — without one,
## a fully gated palisade ring means every thirsty villager walks out to the shore and back,
## which is exactly the kind of thing a player should be able to design away.
@export var provides_water: bool = false
## Extra Faith the colony can hold while this stands. The Temple's reason to exist beyond
## unlocking powers — see Divine.faith_max().
@export var faith_capacity: float = 0.0
## Standing Faith burden while this completed structure remains active.
@export var faith_upkeep: float = 0.0
## Phase-3 physical inventory metadata. Phase 1 still uses the aggregate cache,
## but content declares its eventual capacity and accepted categories now.
@export var inventory_capacity: int = 0
@export var storage_tags: Array[StringName] = []
@export var input_capacity: int = 0
@export var output_capacity: int = 0
## Multiplier on ResourceDef spoilage. Granaries reduce loss but never eliminate it.
@export_range(0.0, 2.0) var spoilage_multiplier: float = 1.0

## Tiles this building pushes the buildable sphere outward (0 means it does not).
##
## Summed with saturation across every standing building rather than taken as a maximum, which
## is what makes the boundary AMORPHOUS: two structures side by side push further out together
## than either does alone, so the sphere visibly bulges toward wherever the player has been
## building. A radius per building rather than a weight against one global figure, because the
## thing a designer wants to tune is "how far does a watchtower reach", stated in tiles.
@export var influence_radius: int = 0

@export_group("Divine")
## This building is a Temple of this tier (0 means it is not one). Gates PowerDef.required_temple_tier.
@export var temple_tier: int = 0
## Tomes that may be INSTALLED here at once. Priests will scribe far more than this, so which
## ones are installed — and which are fed into a combine — is the decision.
@export var tome_slots: int = 0
## Beds provided. Villagers recover rest far faster indoors.
@export var sleep_slots: int = 0
## How many villagers of a matching job may work here at once.
@export var worker_slots: int = 0

## What JobDef.workplace has to name to be worked here. Empty means "my own id".
##
## Exists because of the upgrade chains. A Priest works at a Shrine, a Temple OR a Sanctum, and
## without this the job would have to name one building id and would silently stop working the
## moment the player upgraded the very building it was written for. All three declare the role
## `temple`; the Farm declares nothing and answers to `farm`.
@export var workplace_role: StringName = &""


## The name a job must ask for to be staffed here.
func workplace_key() -> StringName:
	return workplace_role if not workplace_role.is_empty() else id

@export_group("Defence")
## Damage per shot. Zero means the building does not fight.
@export var attack_damage: float = 0.0
## Range in tiles. Should comfortably exceed a Spitter's reach, or towers get
## picked apart by something they cannot answer.
@export var attack_range: float = 6.0
@export var attack_cooldown: float = 0.9
@export var attack_type: StringName = &"piercing"
## Radius in tiles around the chosen target. Zero is a single-target impact.
@export var attack_area_radius: float = 0.0
@export var knockback_tiles: float = 0.0
@export var ammo_kind: StringName = &""
@export var ammo_per_shot: int = 0
@export var default_target_policy: StringName = &"nearest"
@export var target_tags: Array[StringName] = []
@export var requires_line_of_fire: bool = true
## Storm Rod-style weather interaction. Other towers leave both neutral.
@export var storm_damage_multiplier: float = 1.0
@export var storm_self_damage: float = 0.0

@export_group("Board")
@export var order: int = 0
@export var color: Color = Color.WHITE
## Relic Shards to unlock permanently. Zero means available from the first run.
## This is how the meta loop adds OPTIONS rather than raw power — a new building
## changes what a run can become, where a flat stat bonus just makes it easier.
@export var unlock_cost: int = 0
@export var menu_hidden: bool = false
@export var work_aura: float = 0.0


func cost_text() -> String:
	if cost.is_empty():
		return tr(&"COST_FREE")
	var parts: PackedStringArray = PackedStringArray()
	for kind: StringName in cost:
		parts.append(L10n.t(&"COST_ENTRY",
			[int(cost[kind]), L10n.resource(kind)]))
	return ", ".join(parts)


func tile_size() -> Vector2i:
	return footprint * Grid.TILE_SIZE
