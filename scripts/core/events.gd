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

# --- World -----------------------------------------------------------------------
signal map_generated()
signal light_grid_changed(dirty_rect: Rect2i)
signal blight_changed(cell: int, blighted: bool)
signal terrain_changed(cell: int)

# --- Colony ----------------------------------------------------------------------
signal resources_changed(kind: StringName, amount: int)
signal villager_spawned(villager: Node)
signal villager_died(villager: Node, cause: StringName)
signal job_quotas_changed()
signal building_placed(building: Node)
signal building_completed(building: Node)
signal building_destroyed(building: Node)

# --- Divine ----------------------------------------------------------------------
signal faith_changed(amount: float)
signal ember_moved(world_pos: Vector2)
signal power_cast(power_id: StringName, world_pos: Vector2)

# --- Threat ----------------------------------------------------------------------
signal wave_incoming(size: int, composition: Dictionary)
signal wave_cleared(night: int)
signal monster_spawned(monster: Node)
signal monster_died(monster: Node)
signal breach_detected(world_pos: Vector2)

# --- Meta / UI -------------------------------------------------------------------
signal storyteller_event(event_id: StringName, payload: Dictionary)
signal notice(text: String, urgency: int)           ## 0 info, 1 warning, 2 alarm
