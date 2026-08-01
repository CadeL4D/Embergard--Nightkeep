class_name CodexEntries
extends RefCounted
## Searchable field-guide content. Overlay ids let warnings and future help links open the same
## explanation and then point at the relevant world view instead of maintaining parallel copy.

const ROWS := [
	{"id": &"controls", "title": &"TUTORIAL_WELCOME_TITLE", "body": &"TUTORIAL_WELCOME_BODY", "overlay": &""},
	{"id": &"ember", "title": &"TUTORIAL_EMBER_TITLE", "body": &"TUTORIAL_EMBER_BODY", "overlay": &"light"},
	{"id": &"jobs", "title": &"TUTORIAL_JOBS_TITLE", "body": &"TUTORIAL_JOBS_BODY", "overlay": &"work"},
	{"id": &"building", "title": &"TUTORIAL_BUILD_TITLE", "body": &"TUTORIAL_BUILD_BODY", "overlay": &"influence"},
	{"id": &"dusk", "title": &"TUTORIAL_DUSK_TITLE", "body": &"TUTORIAL_DUSK_BODY", "overlay": &"threat"},
	{"id": &"powers", "title": &"TUTORIAL_POWERS_TITLE", "body": &"TUTORIAL_POWERS_BODY", "overlay": &"faith"},
	{"id": &"production", "title": &"TUTORIAL_PRODUCTION_TITLE", "body": &"TUTORIAL_PRODUCTION_BODY", "overlay": &"logistics"},
	{"id": &"storage", "title": &"TUTORIAL_STORAGE_TITLE", "body": &"TUTORIAL_STORAGE_BODY", "overlay": &"storage"},
	{"id": &"repairs", "title": &"TUTORIAL_REPAIR_TITLE", "body": &"TUTORIAL_REPAIR_BODY", "overlay": &"repair"},
	{"id": &"hand", "title": &"TUTORIAL_HAND_TITLE", "body": &"TUTORIAL_HAND_BODY", "overlay": &"faith"},
	{"id": &"routes", "title": &"TUTORIAL_ROUTES_TITLE", "body": &"TUTORIAL_ROUTES_BODY", "overlay": &"routes"},
	{"id": &"colonies", "title": &"TUTORIAL_COLONIES_TITLE", "body": &"TUTORIAL_COLONIES_BODY", "overlay": &"routes"},
	{"id": &"blight", "title": &"TUTORIAL_BLIGHT_TITLE", "body": &"TUTORIAL_BLIGHT_BODY", "overlay": &"corruption"},
	{"id": &"climate", "title": &"TUTORIAL_CLIMATE_TITLE", "body": &"TUTORIAL_CLIMATE_BODY", "overlay": &"weather"},
	{"id": &"stories", "title": &"TUTORIAL_STORIES_TITLE", "body": &"TUTORIAL_STORIES_BODY", "overlay": &""},
	{"id": &"doctrines", "title": &"CODEX_DOCTRINES_TITLE", "body": &"CODEX_DOCTRINES_BODY", "overlay": &""},
	{"id": &"damage", "title": &"CODEX_DAMAGE_TITLE", "body": &"CODEX_DAMAGE_BODY", "overlay": &"range"},
	{"id": &"modes", "title": &"CODEX_MODES_TITLE", "body": &"CODEX_MODES_BODY", "overlay": &""},
]


static func all() -> Array[Dictionary]:
	return ROWS.duplicate(true)


static func search(query: String) -> Array[Dictionary]:
	var wanted := query.strip_edges().to_lower()
	if wanted.is_empty():
		return all()
	var out: Array[Dictionary] = []
	for row in ROWS:
		var haystack := (TranslationServer.translate(row["title"]) + " " \
			+ TranslationServer.translate(row["body"])).to_lower()
		if wanted in haystack:
			out.append(row.duplicate(true))
	return out


static func for_warning(reason: String) -> StringName:
	var copy := reason.to_lower()
	if "ammo" in copy: return &"damage"
	if "storage" in copy or "capacity" in copy: return &"storage"
	if "road" in copy or "route" in copy: return &"routes"
	if "faith" in copy or "burden" in copy: return &"powers"
	if "repair" in copy or "damage" in copy: return &"repairs"
	if "influence" in copy or "reach" in copy: return &"building"
	if "blight" in copy or "corruption" in copy: return &"blight"
	return &"controls"
