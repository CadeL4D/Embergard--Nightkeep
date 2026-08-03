extends Node
## Autoload: the simulation clock, the day/night phase machine, and the agent
## "thinking" scheduler.
##
## Two rates run in this game and keeping them separate is what makes 160 agents
## affordable on a phone:
##
##   * Every frame  — agents move and animate themselves in their own _process.
##                    Pure interpolation, no decisions, no allocations.
##   * TICK_HZ      — this node steps the world (blight, needs, waves) and lets a
##                    SLICE of the agents think. Agents are spread across BUCKETS
##                    buckets by index, so per-frame cost is flat ~N/BUCKETS
##                    think-calls rather than an N-agent spike every so often.
##
## An agent that needs to react faster than its bucket (a guard being shot at) sets
## `think_urgent = true` and is picked up on the very next tick regardless of bucket.

const TICK_HZ := 10.0
const TICK_DT := 1.0 / TICK_HZ
const BUCKETS := 6                    ## agents think every 6 ticks => ~1.7 Hz baseline

enum Phase { DAY, DUSK, NIGHT, DAWN }

## Real seconds each phase lasts. Day is deliberately short — the pitch's failure
## mode is dead air, and a 4-minute day forces decisions to matter.
##
## Retuned to attack that failure mode directly. The old split was 240/90/180/15 = 525s, and
## because is_dark() trips 60% of the way through dusk, work stopped at t=294 and did not resume
## until t=525: **216 seconds of every cycle, 41% of the game, with the entire colony standing
## in a circle**. On a night where the wave died early that was minutes of nothing.
##
## Now 240/60/120/45 = 465s, with 144s dark — 31%. Night is shorter and denser, and dawn is a
## real 45-second morning for hauling and repair rather than a 15-second beat.
##
## The rest of that 31% is not a timing problem: it is that EVERYONE guards. The proper fix is
## the Warrior job (warriors fight, everyone else keeps working in lit territory), which needs
## Phase 2's job additions. This is the half that can be had from data alone.
const PHASE_DURATION := {
	Phase.DAY: 240.0,
	Phase.DUSK: 60.0,
	Phase.NIGHT: 120.0,
	Phase.DAWN: 45.0,
}

# --- Clock state -------------------------------------------------------------------

var running: bool = false
var phase: Phase = Phase.DAY
var phase_elapsed: float = 0.0
var day: int = 1
var tick: int = 0

## Player-facing speed control.
##
## `paused` is a separate flag rather than time_scale == 0 because not everything that
## moves reads time_scale: watchtowers count their reload in raw frame delta, and the
## Ember glides on a Tween that the sim does not drive at all. A colony frozen mid-frame
## while its towers kept shooting was the first thing this got wrong.
##
## Anything that animates the world should scale by `speed_scale()`, which folds both
## values into one number, and anything that acts on its own clock should check `paused`.
var paused: bool = false
var time_scale: float = 1.0

## The speeds the player can cycle through. Capped at 3x: past that a 10 Hz tick starts
## resolving several ticks per frame and the catch-up clamp in _process begins dropping
## simulation instead of accelerating it.
const SPEEDS: Array[float] = [1.0, 2.0, 3.0]

var _accum: float = 0.0

# --- Agent registry ----------------------------------------------------------------
# Villagers and monsters both live here. Order is not meaningful, but an agent's
# INDEX determines its think bucket, so removal uses swap-back rather than erase to
# avoid reshuffling every agent's bucket on every death.

var agents: Array[Agent] = []


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if not running or paused:
		return
	var scaled := delta * time_scale
	_advance_phase(scaled)
	_accum += scaled
	# Clamp catch-up: after a stall (app resumed, level loaded) never try to replay
	# more than a handful of ticks, or the game freezes trying to catch up.
	var budget := 4
	while _accum >= TICK_DT and budget > 0:
		_accum -= TICK_DT
		budget -= 1
		_step()
	if _accum > TICK_DT:
		_accum = 0.0


# --- The tick ----------------------------------------------------------------------

func _step() -> void:
	var bucket := tick % BUCKETS
	var think_dt := TICK_DT * BUCKETS
	for i in range(agents.size()):
		var a := agents[i]
		if a == null or not a.alive or a.held_by_hand:
			continue
		if a.think_urgent:
			a.think_urgent = false
			a.think(TICK_DT)
		elif i % BUCKETS == bucket:
			a.think(think_dt)

	World.step(tick)
	Colony.step(TICK_DT)
	Divine.step(TICK_DT)
	Threat.step(TICK_DT)
	tick += 1


# --- Phase machine -----------------------------------------------------------------

func _advance_phase(delta: float) -> void:
	phase_elapsed += delta
	var duration: float = Difficulties.phase_duration(phase)
	if phase_elapsed < duration:
		return
	phase_elapsed -= duration
	match phase:
		Phase.DAY:
			set_phase(Phase.DUSK)
		Phase.DUSK:
			set_phase(Phase.NIGHT)
		Phase.NIGHT:
			set_phase(Phase.DAWN)
		Phase.DAWN:
			day += 1
			Events.day_advanced.emit(day)
			set_phase(Phase.DAY)


func set_phase(next: Phase) -> void:
	phase = next
	phase_elapsed = 0.0
	Events.phase_changed.emit(next, Difficulties.phase_duration(next))


## 0.0 at the start of the current phase, 1.0 at its end. Drives the sky tint, the
## dusk countdown ring, and wave pacing.
func phase_progress() -> float:
	return clampf(phase_elapsed / Difficulties.phase_duration(phase), 0.0, 1.0)


func seconds_remaining() -> float:
	return maxf(Difficulties.phase_duration(phase) - phase_elapsed, 0.0)


## Real seconds in one full day → dusk → night → dawn cycle.
##
## Summed rather than written down as a constant so retuning a phase cannot silently
## invalidate everything that reasons in days — the food-supply gate on migration divides by
## this, and a stale 525 would quietly mis-scale the colony's whole growth curve.
func cycle_seconds() -> float:
	var total := 0.0
	for p in PHASE_DURATION:
		total += Difficulties.phase_duration(p)
	return total


func is_dark() -> bool:
	return phase == Phase.NIGHT or (phase == Phase.DUSK and phase_progress() > 0.6)


# --- Speed control -----------------------------------------------------------------------

## The single multiplier anything animating the world should use. Zero while paused.
func speed_scale() -> float:
	return 0.0 if paused else time_scale


func set_paused(value: bool) -> void:
	if paused == value:
		return
	paused = value
	Events.speed_changed.emit(speed_scale(), paused)


func toggle_pause() -> void:
	set_paused(not paused)


## Step to the next speed, wrapping. Unpauses — a player reaching for the speed button
## while paused means "get going", and making them press two buttons for that is friction
## for no reason.
func cycle_speed() -> void:
	if paused:
		paused = false
		time_scale = SPEEDS[0]
		Events.speed_changed.emit(speed_scale(), paused)
		return
	var i := SPEEDS.find(time_scale)
	if i == SPEEDS.size() - 1:
		paused = true
	else:
		time_scale = SPEEDS[i + 1] if i >= 0 else SPEEDS[0]
	Events.speed_changed.emit(speed_scale(), paused)


# --- Registry ----------------------------------------------------------------------

func register(a: Agent) -> void:
	agents.append(a)


func unregister(a: Agent) -> void:
	var i := agents.find(a)
	if i == -1:
		return
	# Swap-back: keeps bucket assignment stable for everyone but the moved agent.
	agents[i] = agents[agents.size() - 1]
	agents.resize(agents.size() - 1)


# --- Run control -------------------------------------------------------------------

func start_run() -> void:
	tick = 0
	day = 1
	phase = Phase.DAY
	phase_elapsed = 0.0
	_accum = 0.0
	# Speed is per-run state, not a preference. A player who paused to read the summary
	# card would otherwise start their next run frozen and wonder what broke.
	paused = false
	time_scale = 1.0
	running = true
	Events.speed_changed.emit(speed_scale(), paused)


## Halt the clock and drop the registry. Deliberately does NOT free the agent nodes:
## Sim does not own their lifetime, the scene does. Freeing here as well as in the
## scene produced double-free warnings and left the registry referencing nodes that
## were already queued for deletion.
func stop_run() -> void:
	running = false
	agents.clear()


## Resume after swapping the awake colony without resetting the Realm-wide calendar.
func resume_run() -> void:
	_accum = 0.0
	running = true
	Events.speed_changed.emit(speed_scale(), paused)
