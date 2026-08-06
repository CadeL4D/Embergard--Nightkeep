class_name LooseDrop
extends RefCounted
## One physical stack on the map. Resources, Essence and future loot all share this record so
## collection, expiry, attraction and persistence never become parallel object systems.

const POLICY_WORKER: StringName = &"worker"
const POLICY_DIVINE: StringName = &"divine"
const POLICY_EITHER: StringName = &"either"

var id: int = 0
var cell: int = -1
var kind: StringName = &""
var amount: int = 0
var collection_policy: StringName = POLICY_WORKER
## Absolute Sim tick; -1 never expires.
var expires_tick: int = -1
var source: StringName = &""


func can_collect(policy: StringName) -> bool:
	return collection_policy == POLICY_EITHER or collection_policy == policy


func expired(at_tick: int) -> bool:
	return expires_tick >= 0 and at_tick >= expires_tick


func to_dict() -> Dictionary:
	return {
		"id": id,
		"cell": cell,
		"kind": kind,
		"amount": amount,
		"collection_policy": collection_policy,
		"expires_tick": expires_tick,
		"source": source,
	}


static func from_dict(row: Dictionary) -> LooseDrop:
	var drop := LooseDrop.new()
	drop.id = int(row.get("id", 0))
	drop.cell = int(row.get("cell", -1))
	drop.kind = StringName(row.get("kind", &""))
	drop.amount = maxi(int(row.get("amount", 0)), 0)
	drop.collection_policy = StringName(row.get(
		"collection_policy", POLICY_WORKER))
	if drop.collection_policy not in [POLICY_WORKER, POLICY_DIVINE, POLICY_EITHER]:
		drop.collection_policy = POLICY_WORKER
	drop.expires_tick = int(row.get("expires_tick", -1))
	drop.source = StringName(row.get("source", &""))
	return drop
