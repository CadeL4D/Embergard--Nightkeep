class_name JobDef
extends Resource
## One assignable job. Lives as a .tres in res://content/jobs/, scanned by Jobs.
##
## Adding a job is dropping in a file — nothing in the sim branches on a job id.
## If you find yourself writing `if job == &"woodcutting"` somewhere, the property
## you actually need is missing from this class; add it here instead.

@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D

## Which map features this job harvests. Empty means the job does not gather at all
## (builders, guards) — those are roles rather than slider jobs for now.
@export var target_features: Array[int] = []

## Building this job is worked AT, instead of harvesting features from the map.
## Farming works a farm; woodcutting works the wild. Empty means a field job.
##
## This is the difference between a finite resource and a renewable one: features
## are consumed and never come back, whereas a workplace keeps producing as long as
## someone is standing in it. Every long-term supply in this game has to be a
## workplace, or the colony eventually starves no matter how well it is run.
@export var workplace: StringName = &""

## What one completed work cycle at the workplace produces, e.g. { &"food": 10 }.
@export var cycle_yield: Dictionary = {}

## What one cycle CONSUMES, e.g. { &"wood": 2 }. Empty means the job creates from nothing —
## a farm growing food, a forester felling a tree.
##
## This one field is what turns the entire production chain into content. A sawmill is a
## workplace whose cycle costs 2 wood and yields 1 board; a toolsmith costs wood and stone and
## yields a tool; a furnace costs ore and wood and yields an ingot. None of that needs code,
## because nothing in the sim branches on what a job happens to be making.
##
## Inputs are withdrawn from the colony stores when a cycle COMPLETES, not when it starts. A
## worker who is interrupted halfway — nightfall, hunger, a monster — should not have silently
## eaten the materials, and reserving them up front would mean tracking a second reservation
## ledger alongside the one construction already uses.
@export var cycle_cost: Dictionary = {}

## Villager-seconds per cycle.
@export var cycle_work: float = 8.0

@export_group("Work")
## Multiplier on harvest speed. Terrain.FEATURE_WORK holds the base cost in
## villager-seconds; this scales how fast one worker chews through it.
@export var work_rate: float = 1.0
## Maximum units carried per trip. Low capacity means more walking, which makes
## the distance to a resource matter — and therefore makes where the Blight is
## eating matter.
@export var carry_capacity: int = 12

## This job fights instead of working after dark.
##
## The remaining dead air in the game is not a timing problem — it is that EVERYONE drops their
## tools at dusk and stands in a circle, so 31% of every cycle is a colony doing nothing. Splitting
## the roster fixes it: warriors hold the line, and everybody else keeps working as long as they
## are inside the light.
##
## That also makes Ember placement an economic decision at night rather than only a defensive one,
## which is the whole point of the mechanic.
@export var defends: bool = false

## Completing a cycle at this job's workplace produces a TOME rather than a resource.
##
## A flag rather than a branch on `id == &"priest"`, per this class's own rule. It also means the
## priest reuses _tick_workplace completely: the cycle is worked at a building exactly like farming
## is, and the only difference is that what comes out is an object owned by Divine instead of a
## number in the stockpile — so `cycle_yield` stays empty and no haul is queued.
@export var scribes: bool = false

@export_group("Board")
## Fill order on the Job Board. Lower numbers are staffed first when there are not
## enough survivors to satisfy every quota.
@export var priority: int = 0

## Headcount this job is set to on a fresh run.
##
## Declared per job rather than derived. The old rule — two for every job without a workplace —
## worked when there were four jobs and broke the moment there were nine: the defaults asked for ten
## people out of six, which left the whole Job Board amber on day one and inflated the colony's
## apparent unmet work, and unmet work is one of the things that draws migrants.
##
## The sum across all jobs should equal the starting population. A fresh board must describe a
## colony that is fully and sensibly employed, because it is also the game's only tutorial for what
## the sliders are for.
@export var default_quota: int = 0
## Tint used for this job's row and for the worker's tool marker.
@export var color: Color = Color.WHITE


func harvests(feature: int) -> bool:
	return feature in target_features
