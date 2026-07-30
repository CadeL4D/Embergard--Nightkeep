class_name L10n
extends RefCounted
## Translation lookup that works from ANY context, including static functions.
##
## This exists because of a Godot scoping rule that bites twice:
##
##   * `tr()` is an Object method, so it cannot be called from a `static func` — there is no
##     `self` for it to resolve against.
##   * An AUTOLOAD identifier is not in scope inside a `static func` either, so reaching for
##     `L10n.t()` instead fails with "Identifier not declared in the current scope".
##
## `TranslationServer` is a real engine singleton rather than an autoload, so it is reachable
## from everywhere. Wrapping it in a global class via `class_name` gives one call that is always
## valid — RateLedger is entirely static functions and needs this.
##
## Non-static code may still use plain `tr()`; it is shorter and does the same thing.

## Translate a key. Returns the key itself when there is no entry, which is the loud failure the
## UPPER_SNAKE convention is chosen for.
static func t(key: StringName, args: Array = []) -> String:
	var text := TranslationServer.translate(key)
	if args.is_empty():
		return text
	# Positional {0}/{1} so translators can reorder freely. See Locale for why not %s.
	return text.format(args)


## Translate a resource kind's display name: `&"cut_stone"` -> "cut stone".
##
## Centralised because the mapping from a resource id to its locale key is a convention
## (`RESOURCE_` + upper case) and three separate places were about to spell it out by hand.
static func resource(kind: StringName) -> String:
	return t(StringName("RESOURCE_" + String(kind).to_upper()))


## Translate a `display_name` or `description` field.
##
## Separate from t() only because content files declare those as `String` while keys everywhere
## else are `StringName`. Without this the call sites either convert by hand or quietly rely on an
## implicit cast, and the whole point of this class is that there is exactly one always-valid way
## to translate something.
static func label(key: String) -> String:
	return t(StringName(key))
