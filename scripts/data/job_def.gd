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

@export_group("Board")
## Fill order on the Job Board. Lower numbers are staffed first when there are not
## enough survivors to satisfy every quota.
@export var priority: int = 0
## Tint used for this job's row and for the worker's tool marker.
@export var color: Color = Color.WHITE


func harvests(feature: int) -> bool:
	return feature in target_features
