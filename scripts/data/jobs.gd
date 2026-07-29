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
