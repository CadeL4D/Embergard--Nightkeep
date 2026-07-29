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
const PHASE_DURATION := {
	Phase.DAY: 240.0,
	Phase.DUSK: 90.0,
	Phase.NIGHT: 180.0,
	Phase.DAWN: 15.0,
}

# --- Clock state -------------------------------------------------------------------

var running: bool = false
var phase: Phase = Phase.DAY
var phase_elapsed: float = 0.0
var day: int = 1
var tick: int = 0
var time_scale: float = 1.0           ## debug only; ships locked at 1.0

var _accum: float = 0.0

# --- Agent registry ----------------------------------------------------------------
# Villagers and monsters both live here. Order is not meaningful, but an agent's
# INDEX determines its think bucket, so removal uses swap-back rather than erase to
# avoid reshuffling every agent's bucket on every death.

var agents: Array[Agent] = []


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if not running:
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
		if a == null or not a.alive:
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
	var duration: float = PHASE_DURATION[phase]
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
	Events.phase_changed.emit(next, PHASE_DURATION[next])


## 0.0 at the start of the current phase, 1.0 at its end. Drives the sky tint, the
## dusk countdown ring, and wave pacing.
func phase_progress() -> float:
	return clampf(phase_elapsed / PHASE_DURATION[phase], 0.0, 1.0)


func seconds_remaining() -> float:
	return maxf(PHASE_DURATION[phase] - phase_elapsed, 0.0)


func is_dark() -> bool:
	return phase == Phase.NIGHT or (phase == Phase.DUSK and phase_progress() > 0.6)


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
	running = true


## Halt the clock and drop the registry. Deliberately does NOT free the agent nodes:
## Sim does not own their lifetime, the scene does. Freeing here as well as in the
## scene produced double-free warnings and left the registry referencing nodes that
## were already queued for deletion.
func stop_run() -> void:
	running = false
	agents.clear()
