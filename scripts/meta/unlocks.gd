class_name Unlocks
extends RefCounted
## Everything Relic Shards can buy, behind one interface.
##
## Exists because the end-of-run card used to offer `Buildings.locked()` and nothing else, so the
## moment powers gained an `unlock_cost` there were two parallel unlock systems with two parallel
## bits of summary UI — and the player would have been able to buy a Watchtower but never a
## Dawnbreak. One list, sorted by price, is also what makes "the cheapest thing still locked" a
## meaningful offer rather than "the cheapest BUILDING still locked".
##
## Adding a fourth kind (jobs, starting perks) means adding one loop to `locked()`. Nothing else in
## the meta layer has to know the difference.
##
## Ids share a single namespace inside `Meta.unlocked`, so a building and a power must never use the
## same id. Nothing enforces that beyond convention; `duplicate_ids()` is the guard, and the smoke
## test calls it.

## One purchasable thing, whatever kind it actually is.
class Entry extends RefCounted:
	var id: StringName
	## Locale KEY, not display text — the card translates it.
	var display_name: String
	var description: String
	var cost: int
	## Sorts the offer within a price tier, so a run does not get offered things in a jumble.
	var order: int

	func _init(entry_id: StringName, name_key: String, desc_key: String,
			shard_cost: int, sort: int) -> void:
		id = entry_id
		display_name = name_key
		description = desc_key
		cost = shard_cost
		order = sort


## Everything still behind a shard cost, cheapest first.
static func locked() -> Array[Entry]:
	var out: Array[Entry] = []
	for def: BuildingDef in Buildings.all():
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			out.append(Entry.new(def.id, def.display_name, def.description,
				def.unlock_cost, def.order))
	for def: PowerDef in Powers.all():
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			out.append(Entry.new(def.id, def.display_name, def.description,
				def.unlock_cost, 100 + def.order))
	out.sort_custom(func(a: Entry, b: Entry) -> bool:
		if a.cost != b.cost:
			return a.cost < b.cost
		return a.order < b.order)
	return out


## The cheapest thing still locked, or null when the library is complete.
static func cheapest() -> Entry:
	var list := locked()
	return null if list.is_empty() else list[0]


## Everything that HAS a shard price, bought or not. The size of the meta layer.
static func total() -> int:
	var n := 0
	for def: BuildingDef in Buildings.all():
		if def.unlock_cost > 0:
			n += 1
	for def: PowerDef in Powers.all():
		if def.unlock_cost > 0:
			n += 1
	return n


## Total shards it would take to buy everything, for balancing how many runs the meta lasts.
static func total_cost() -> int:
	var sum := 0
	for def: BuildingDef in Buildings.all():
		sum += def.unlock_cost
	for def: PowerDef in Powers.all():
		sum += def.unlock_cost
	return sum


## Ids used by more than one unlockable. Must be empty: `Meta.unlocked` is a flat list of ids, so a
## building and a power sharing one would unlock each other.
static func duplicate_ids() -> PackedStringArray:
	var seen: Dictionary = {}
	var clashes := PackedStringArray()
	for def: BuildingDef in Buildings.all():
		seen[def.id] = true
	for def: PowerDef in Powers.all():
		if seen.has(def.id):
			clashes.append(String(def.id))
	return clashes
