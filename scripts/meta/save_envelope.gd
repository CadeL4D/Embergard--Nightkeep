class_name SaveEnvelope
extends RefCounted
## Explicit boundary between persistent profile, disposable world, and individual region state.

const ENVELOPE_VERSION := 1
const WORLD_SCHEMA := 1
const REGION_SCHEMA := 1


static func header() -> Dictionary:
	return {
		"envelope": ENVELOPE_VERSION,
		"profile_schema": Meta.SCHEMA_VERSION,
		"world_schema": WORLD_SCHEMA,
		"region_schema": REGION_SCHEMA,
		"target": BalanceCatalog.TARGET_VERSION,
	}


static func valid(data: Dictionary) -> bool:
	return int(data.get("envelope", 0)) == ENVELOPE_VERSION \
		and int(data.get("world_schema", 0)) == WORLD_SCHEMA \
		and int(data.get("region_schema", 0)) == REGION_SCHEMA
