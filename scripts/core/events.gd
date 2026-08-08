extends Node
## Autoload: the global signal bus.
##
## The sim is event-heavy and its producers and consumers are deliberately kept
## ignorant of each other — the blight grid does not know the HUD exists, a dying
## villager does not know the storyteller is counting deaths. Everything that
## crosses a system boundary goes through here.
##
## Convention: signals are named <subject>_<past_tense_verb>. Emit from the system
## that owns the state; never emit someone else's signal. If only one system cares
## and it already holds a reference, call it directly instead of adding a signal.

# --- Run lifecycle ---------------------------------------------------------------
signal run_started(seed_value: int)
signal run_ended(victory: bool, shards: int)
signal day_advanced(day: int)
signal phase_changed(phase: int, duration: float)   ## phase is Sim.Phase
signal speed_changed(scale: float, paused: bool)

# --- World -----------------------------------------------------------------------
signal map_generated()
signal light_grid_changed(dirty_rect: Rect2i)
signal blight_changed(cell: int, blighted: bool)
signal terrain_changed(cell: int)
signal nest_destroyed(cell: int)
signal climate_changed(season: StringName, weather: StringName, severity: float)
## The Blight raised or lost one of its own buildings. The view spawns and frees sprites from these
## rather than polling World.blight_structures, which changes a handful of times a night.
signal blight_structure_raised(cell: int, kind: StringName)
signal blight_structure_razed(cell: int)
## Rich destruction event used by the regional enemy-settlement progression. The legacy
## `blight_structure_razed` signal remains the view's simple remove notification.
signal blight_structure_destroyed(cell: int, kind: StringName, was_initial_outpost: bool)

# --- Colony ----------------------------------------------------------------------
signal resources_changed(kind: StringName, amount: int)
## A physical resource or Essence object appeared, moved, expired, or was collected.
signal loose_drops_changed(cell: int)
signal villager_spawned(villager: Node)
signal villager_died(villager: Node, cause: StringName)
signal golem_spawned(golem: Node)
signal golem_died(golem: Node, cause: StringName)
signal migrant_arrived(cell: int)
## A band is waiting at the edge for an answer.
signal migrants_arrived(count: int)
## Accepted, refused, or gave up waiting.
signal migrants_resolved()
signal job_quotas_changed()
signal building_placed(building: Node)
signal building_completed(building: Node)
signal building_destroyed(building: Node)
signal tower_fired(tower: Node, damage: float, target_pos: Vector2)
signal production_completed(building: Node, kind: StringName, amount: int)
signal building_repaired(building: Node, amount: float)
signal villager_injured(villager: Node, amount: float)
signal villager_treated(villager: Node)
## Workers have started tearing something down. Separate from building_destroyed, which fires
## when it is actually gone — the two are a long way apart in time now that salvage is hauled.
signal building_demolishing(building: Node)
## The buildable sphere was recomputed. The overlay redraws from this rather than polling a
## 16k-cell array every frame looking for a change that happens a few times a run.
signal influence_changed()

# --- Divine ----------------------------------------------------------------------
signal faith_changed(amount: float)
signal ember_moved(world_pos: Vector2)
signal power_cast(power_id: StringName, world_pos: Vector2)
signal hand_action(action: StringName, world_pos: Vector2)
## An ability was taken up or given back, so the power bar and the Faith panel have to rebuild.
signal powers_changed()
## A priest finished a Tome, by writing or by combining. Carries the tier so a stinger can scale.
signal tome_written(tier: int)
signal library_changed()

# --- Threat ----------------------------------------------------------------------
signal wave_incoming(size: int, composition: Dictionary)
signal wave_cleared(night: int)
signal monster_spawned(monster: Node)
signal monster_died(monster: Node)
signal monster_attacked(monster: Node, target: Node)
signal breach_detected(world_pos: Vector2)

# --- Meta / UI -------------------------------------------------------------------
signal storyteller_event(event_id: StringName, payload: Dictionary)
signal storyteller_resolved(event_id: StringName, choice_id: StringName)
## The player has entered or left building placement. The sphere-of-influence boundary is only
## DRAWN during placement: it is a placement aid, and a permanent glowing ring around the village
## would be six hours of decoration nobody asked for.
signal placement_mode_changed(active: bool)
signal notice(text: String, urgency: int)           ## 0 info, 1 warning, 2 alarm

# --- Realm ------------------------------------------------------------------------
signal realm_changed()
signal colony_awakened(colony_id: StringName)
signal trade_route_updated(route_id: int, status: StringName)
signal migration_ready(order, ledger)
signal heart_shattered()
