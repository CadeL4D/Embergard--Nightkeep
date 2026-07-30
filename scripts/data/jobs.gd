class_name Jobs
extends RefCounted
## Catalog of every job, loaded from res://content/jobs/ on first use.
##
## Same shape as the ability catalog pattern used elsewhere in this codebase: a
## static, lazily-scanned dictionary keyed by id, so adding content is adding a
## file. Nothing here knows what any particular job does.

const JOB_DIR := "res://content/jobs"

static var _catalog: Dictionary = {}        # StringName -> JobDef
static var _ordered: Array[JobDef] = []
static var _loaded: bool = false


static func get_job(id: StringName) -> JobDef:
	_ensure_loaded()
	return _catalog.get(id)


## Every job, sorted by priority. This is the order the Job Board displays and the
## order the labour reconciler fills quotas in, so it must be stable.
static func all() -> Array[JobDef]:
	_ensure_loaded()
	return _ordered


## Jobs the colony can actually put someone to work at, right now.
##
## A workplace job with nowhere to work is not a choice, it is noise: the board opened on day one
## with ten rows, six of which — sawing, stonecutting, toolmaking, priest, farming — needed a
## building that did not exist, and a slider that cannot do anything is worse than a missing one
## because the player spends time deciding about it.
##
## Worse than cosmetic, in fact. A quota on an unstaffable job sends villagers to look for a
## workplace they will never find, so they fall through to `_wander()` while the colony has trees to
## fell — and it inflates `Colony.work_slots_free()`, which is one of the things that draws migrants.
##
## So the board GROWS with the settlement: raise a sawmill and the Sawyer row appears. Same teaching
## pattern as the resource readout's groups, and it means the player meets each job at the moment it
## first becomes useful rather than all ten at once with no context.
static func available() -> Array[JobDef]:
	var out: Array[JobDef] = []
	for job: JobDef in all():
		if has_workplace(job):
			out.append(job)
	return out


## Is there a finished building this job could be worked at? True for every field job — they work
## the map, so they always have somewhere to go.
static func has_workplace(job: JobDef) -> bool:
	if job == null:
		return false
	if job.workplace.is_empty():
		return true
	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		var def: BuildingDef = b.def
		if def.workplace_key() == job.workplace:
			return true
	return false


## The job that harvests a given map feature, or an empty name if nothing does.
static func for_feature(feature: int) -> StringName:
	_ensure_loaded()
	for job: JobDef in _ordered:
		if job.harvests(feature):
			return job.id
	return &""


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var dir := DirAccess.open(JOB_DIR)
	if dir == null:
		push_error("Jobs: cannot open %s" % JOB_DIR)
		return
	for f in dir.get_files():
		# Exported builds list some resources with a .remap suffix — strip it
		# before matching or the catalog comes up empty outside the editor.
		var fname := f.trim_suffix(".remap")
		if not fname.ends_with(".tres"):
			continue
		var res: Resource = load(JOB_DIR + "/" + fname)
		if res is JobDef:
			var job: JobDef = res
			if job.id.is_empty():
				push_warning("Jobs: %s has no id — skipped" % fname)
				continue
			_catalog[job.id] = job
			_ordered.append(job)
	_ordered.sort_custom(func(a: JobDef, b: JobDef) -> bool: return a.priority < b.priority)
