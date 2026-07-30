extends Node
## Autoload: loads content/locale/embergard.csv and registers a Translation per language column.
##
## Parsed at runtime rather than going through Godot's `csv_translation` importer. The importer
## needs a generated .import file and an editor pass to produce its .translation binaries, which
## means the game cannot be built or headlessly tested from a clean checkout until someone has
## opened the project once. Parsing the CSV ourselves removes that step entirely: the source of
## truth is the file in version control, adding a language is adding a column, and the headless
## smoke test exercises exactly what ships.
##
## CONVENTIONS
##
## Keys are explicit UPPER_SNAKE, never English source text. A missing entry therefore renders as
## `MISSING_KEY_NAME` on screen — loud, obvious and greppable. English-as-key fails silently, which
## means a missed string ships, and it hands translators whole sentences as identifiers.
##
## Placeholders are `{0}`-style and substituted with `String.format`, never `%s`. Positional `%s`
## cannot be reordered, and word order changes between languages — a sentence that reads
## "3 survivors ask for shelter" in English may need the count last elsewhere.
##
## Call `tr()` for a bare string and `L10n.t()` when there are arguments.

const CSV_PATH := "res://content/locale/embergard.csv"
const LOCALE_DIR := "res://content/locale"

# --- Why this file exists at all, and the trap it fell into once ------------------------------
#
# Parsing the CSV at runtime only works if the CSV is actually IN the exported package, and by
# default it is not. Godot's `csv_translation` importer claims any .csv as the source of an imported
# resource, and the exporter then ships the generated .translation binary and strips the source. In
# the editor that is invisible — the file is on disk — so the game runs perfectly right up until it
# is exported, at which point every single string in the game renders as its own key.
#
# That shipped once, to iOS. Three things stop it recurring, deliberately belt-and-braces because the
# failure is silent, total, and only visible on a device:
#
#   1. content/locale/embergard.csv.import sets importer="keep", so the CSV is copied verbatim.
#   2. export_presets.cfg sets include_filter="*.csv", which force-includes it regardless.
#   3. _load() falls back to any .translation resources in the folder if the CSV is missing anyway,
#      and `healthy()` reports the failure so the smoke test can assert against it.

## Language used when the player's OS locale has no column. Also the column every key must have,
## since it is the fallback for a partially translated language.
const FALLBACK := "en"

## key -> true, for the test that asserts nothing user-facing is missing.
var keys: Dictionary = {}
var _locales: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_load()


func _load() -> void:
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	if f == null:
		push_error("Locale: cannot open %s — falling back to imported .translation resources"
			% CSV_PATH)
		_load_imported()
		return

	# get_csv_line handles quoted fields containing commas and embedded newlines, which the credits
	# blurb and several descriptions rely on. Splitting on "," by hand would corrupt them.
	var header := f.get_csv_line()
	if header.size() < 2:
		push_error("Locale: %s has no language columns" % CSV_PATH)
		return

	var translations: Array[Translation] = []
	for i in range(1, header.size()):
		var code := header[i].strip_edges()
		if code.is_empty():
			continue
		var t := Translation.new()
		t.locale = code
		translations.append(t)
		_locales.append(code)

	var row_count := 0
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.is_empty():
			continue
		var key := row[0].strip_edges()
		if key.is_empty() or key.begins_with("#"):
			continue
		keys[key] = true
		row_count += 1
		for i in translations.size():
			var col := i + 1
			if col >= row.size():
				continue
			var value := row[col]
			if value.is_empty():
				continue
			# Escapes are written literally in the CSV because a real newline inside a quoted field
			# is legal but hostile to diff and to spreadsheet editors.
			translations[i].add_message(key, value.replace("\\n", "\n"))
	f.close()

	for t in translations:
		TranslationServer.add_translation(t)

	# Prefer the player's OS language when we have it, otherwise fall back. Set explicitly rather
	# than trusting the default so behaviour is identical headless, where there is no OS locale.
	var wanted := OS.get_locale_language()
	TranslationServer.set_locale(wanted if _locales.has(wanted) else FALLBACK)
	print("Locale: %d keys, languages %s, using %s" % [
		row_count, ", ".join(_locales), TranslationServer.get_locale()])


## Lookup lives in L10n, not here. An autoload identifier is out of scope inside a `static func`,
## so anything static — RateLedger is entirely static functions — could not reach `Locale.t()` and
## failed to parse with "Identifier not declared in the current scope". L10n is a global class via
## `class_name`, which is reachable from everywhere.


## Last-resort path: register whatever `.translation` binaries are sitting in the locale folder.
##
## Only reached if the CSV genuinely is not in the package. It cannot populate `keys` — a compiled
## Translation does not enumerate its messages — so `has_key()` degrades, but the GAME still shows
## real text instead of a screen full of identifiers, which is the difference between a cosmetic
## regression and an unshippable build.
func _load_imported() -> void:
	var dir := DirAccess.open(LOCALE_DIR)
	if dir == null:
		push_error("Locale: %s is not in the package either — every string will render as its key"
			% LOCALE_DIR)
		return
	for file in dir.get_files():
		# Exported builds list imported resources with a .remap suffix — the same strip the content
		# catalogs already do.
		var name := file.trim_suffix(".remap")
		if not name.ends_with(".translation"):
			continue
		var res: Resource = load(LOCALE_DIR + "/" + name)
		if res is Translation:
			var t: Translation = res
			TranslationServer.add_translation(t)
			_locales.append(t.locale)
	if _locales.is_empty():
		push_error("Locale: no translations found at all — every string will render as its key")
		return
	TranslationServer.set_locale(FALLBACK if _locales.has(FALLBACK) else _locales[0])
	print("Locale: recovered from .translation resources, languages %s" % ", ".join(_locales))


## Did translations load at all?
##
## The failure this guards is silent by nature: `tr()` returns its argument when there is no entry, so
## a build with no translation table looks like a build with a thousand mislabelled controls rather
## than like a missing file. Asserted by the smoke test, which also checks that a known key resolves
## to something DIFFERENT from itself — the only way to catch the table being present but empty.
func healthy() -> bool:
	return not _locales.is_empty()


## True when a key exists in the table. Used by the smoke test.
func has_key(key: StringName) -> bool:
	return keys.has(String(key))
