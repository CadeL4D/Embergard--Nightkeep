extends Node
## Autoload: the player's own presence in the world — Faith, and the Ember.
##
## The Ember is the game's signature mechanic and it lives here rather than on a
## scene node, because half the sim needs to ask where it is: villagers check it for
## a work-speed bonus, the blight checks it for suppression, monsters check it to
## decide whether to flinch. The visual node in the run scene follows THIS, not the
## other way round.

## Faith is designed as a flow, not a hoard. It accrues continuously from villagers
## who are fed, rested and lit, and is spent on powers both day and night — the day
## sinks exist specifically so hoarding until dusk is a real sacrifice.
## How much Faith the colony can hold at once — see faith_max().
##
## A flat 100 made the ceiling a property of the game rather than of the colony: six survivors
## and sixty had the same reservoir, and a large settlement that had earned real standing hit the
## cap constantly with nowhere to put the overflow. Faith is worship, so its storage should be a
## function of how many people are doing the worshipping and of what has been built to house it.
const FAITH_BASE_CAP := 40.0
const FAITH_PER_VILLAGER := 25.0

## Kept so anything reasoning about "roughly how big is the reservoir" has a constant to compare
## against; the live ceiling is faith_max().
const FAITH_MAX := 100.0
const FAITH_BASE_RATE := 0.6           ## per second with a baseline colony

var faith: float = 20.0

## Faith earned from kills since the current night began, reported at dawn. Not saved: a night
## interrupted by a save is reported from whatever it had accumulated, which is close enough for
## a summary line.
var night_faith_earned: float = 0.0

## The Ember's authoritative position in WORLD space. `ember_cell` is derived from
## it, so the light, the aura and the sim can never disagree about where it is.
var ember_pos: Vector2 = Vector2.ZERO
var ember_cell: int = -1
var ember_radius: int = 6
var ember_strength: int = 255

## Travel speed, in pixels per second, used to derive the glide duration. The Ember
## deliberately does NOT teleport: giving it travel time is what makes its position
## a real commitment. Rushing it to a breached wall at night has to cost something,
## or the "it can only be in one place" tension evaporates.
const TRAVEL_SPEED := 105.0
## Floor on the glide duration. Without it a one-tile hop resolves in ~0.15s, which
## reads as a snap — and short repositioning nudges are the most common Ember move
## there is, so they are exactly the ones that need to feel weighty.
const TRAVEL_MIN := 0.30
const TRAVEL_MAX := 2.4

## How fast the Ember chases the finger while it is being DRAGGED, as the rate of an
## exponential approach. A drag used to snap the Ember cell to cell, which both
## stuttered in 16px steps and parked the light up to half a tile away from the
## thumb. Chasing a free world-space target fixes the offset and keeps the weight:
## high enough that the Ember stays under the finger, low enough that it still reads
## as something you are hauling rather than something you are teleporting.
const DRAG_FOLLOW_RATE := 16.0
## Settle time when the finger lifts. The Ember ends on a cell centre so the light
## grid, the sim and the sprite cannot disagree about which tile it is on.
const DRAG_SETTLE_TIME := 0.12

var _light_handle: int = 0
var _travel: Tween = null
var _dragging: bool = false
var _drag_target: Vector2 = Vector2.ZERO

## Lights dropped by Emberfall, and when they expire. Kept here rather than as
## scene nodes so they survive a scene reload and are trivially saveable.
var _temp_lights: Array = []            ## [{handle, expires}]
## power id -> seconds until it can be cast again.
var _cooldowns: Dictionary = {}

# --- Burden and Tomes -------------------------------------------------------------------------
#
#   ability Burden   negative   PERMANENT
#   Tome bonuses     positive   DECAYING
#   priests          labour     the standing cost of keeping the positive alive
#
# Obligations that do not expire against income that does. That is why a Temple can never be
# finished, and why the Burden ceiling MOVES over a run rather than sitting still.

## Powers taken up this run. Each one charges its Burden against the Faith rate for as long as it
## is held. Not the same thing as Meta.is_unlocked, which is the permanent cross-run purchase —
## a power must be bought once with shards AND taken up each run.
var taken_up: Array[StringName] = []

## Faith cost of giving an ability back. Modest, but not free: relinquishing has to be a real
## option or one greedy unlock is permanent regret, and it must not be a toggle the player flips
## mid-night to dodge a deficit.
const RELINQUISH_COST := 12.0

## Every Tome the colony owns, installed or shelved.
var tomes: Array[Tome] = []
var auto_manage_library: bool = true

## One written book. Tier and toughness are rolled INDEPENDENTLY on purpose — a rare tier 3 can
## still be fragile and a humble tier 1 can outlast everything, and that variance is what stops
## the system settling into one optimal play.
class Tome extends RefCounted:
	## Durability lost per second by an INSTALLED tome of toughness 1.0.
	##
	## Shelved tomes do not decay. That matters three ways: the player can stockpile spares and
	## plan replacements instead of watching a library rot, the Temple's installed slots become the
	## meaningful active set, and a good run cannot be undone by decay nobody could act on.
	##
	## Declared INSIDE the class rather than beside the other Divine constants: a GDScript inner
	## class does not see the outer script's scope, so a constant used by these methods has to live
	## here or the reference does not resolve.
	const TOME_WEAR := 0.055

	var archetype: StringName
	var tier: int = 1
	## 0.5 (crumbling) to 2.2 (a masterwork). Divides the wear rate.
	var toughness: float = 1.0
	var durability: float = 100.0
	var installed: bool = false
	## Locked books keep their installed/shelved state and are never consumed by auto-combine.
	var locked: bool = false

	func def() -> TomeDef:
		return Tomes.get_tome(archetype)

	## Faith per second, right now. Zero for a crumbled book, and zero in daylight for a
	## night-only one.
	func rate() -> float:
		var d := def()
		if d == null or durability <= 0.0:
			return 0.0
		if d.night_only and not Sim.is_dark():
			return 0.0
		return d.faith_rate * pow(d.tier_scale, float(tier - 1))

	func wear_per_second() -> float:
		return TOME_WEAR / maxf(toughness, 0.2)

	func label() -> String:
		var d := def()
		var name := tr(d.display_name) if d != null else String(archetype)
		return L10n.t(&"TOME_LABEL", [name, tier])


func _ready() -> void:
	reset()


func reset() -> void:
	faith = 20.0
	ember_cell = -1
	ember_pos = Vector2.ZERO
	_light_handle = 0
	_temp_lights.clear()
	_cooldowns.clear()
	_dragging = false
	night_faith_earned = 0.0
	# Both are RUN state, not profile state: shards buy the option to take a power up, and every run
	# has to earn it again by raising a Temple and choosing to carry its Burden.
	taken_up.clear()
	tomes.clear()
	auto_manage_library = true
	_grant_baseline_powers()
	_kill_travel()


## Take up every ability that needs no Temple, silently, at run start.
##
## Without this the power bar opens EMPTY, and the game's signature mechanic becomes something the
## player has to go and find in a breakdown panel before they can use it. The three baseline powers
## carry 0.24/s between them against a passive rate of roughly 0.6/s, so they are affordable from
## the first minute — and they can still be given back, which is a real option for a colony that
## would rather bank the rate.
##
## The interesting decision is not whether to have Emberfall; it is whether a Sanctum's worth of
## abilities is something the colony can carry. That decision starts at tier 1.
func _grant_baseline_powers() -> void:
	for def: PowerDef in Powers.all():
		if def.required_temple_tier > 0:
			continue
		if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
			continue
		taken_up.append(def.id)


## The Faith ceiling: a floor, plus every worshipper, plus whatever has been raised to store it.
##
## `faith_capacity` on BuildingDef is the hook the Temple will use — it is summed here so adding
## a shrine or a reliquary is a content change rather than a code change.
func faith_max() -> float:
	var total := FAITH_BASE_CAP + float(Colony.population()) * FAITH_PER_VILLAGER
	for b in Colony.buildings:
		if is_instance_valid(b) and not b.is_site():
			total += b.def.faith_capacity
	return total


## Faith is generated by the colony, not by the clock. A well-fed, rested, well-lit
## village produces it steadily; a miserable one produces almost nothing. That is
## the loop the whole design hangs on — look after your people, and you get the
## power to protect them. Neglect them and you go into the night with an empty meter.
func step(delta: float) -> void:
	_expire_lights(delta)
	_tick_cooldowns(delta)
	_wear_tomes(delta)
	if ember_cell != -1:
		absorb_essence(Colony.collect_essence_near(ember_cell, 2))

	var rate := net_faith_rate()
	if is_zero_approx(rate):
		return
	var cap := faith_max()
	if rate > 0.0 and faith >= cap:
		return
	# Clamped at zero rather than allowed to go negative. A colony carrying more Burden than it
	# generates drains its buffer and its powers go DARK — which is a legible failure the player can
	# fix by relinquishing something — instead of accruing a debt they can neither see nor pay.
	faith = clampf(faith + rate * delta, 0.0, cap)
	Events.faith_changed.emit(faith)


# --- The Faith rate -------------------------------------------------------------------------

## What the colony generates before Tomes and Burden. The original passive model, untouched.
func passive_faith_rate() -> float:
	return FAITH_BASE_RATE * faith_multiplier() * Doctrines.modifier(&"faith_rate")


## Faith per second from every installed, uncrumbled Tome.
func tome_rate() -> float:
	var total := 0.0
	for tome in tomes:
		if tome.installed:
			total += tome.rate()
	return total


## Total standing cost of every ability currently taken up.
func total_burden() -> float:
	var total := 0.0
	for id in taken_up:
		var def := Powers.get_power(id)
		if def != null:
			total += def.burden
	return total * Doctrines.modifier(&"burden")


func building_upkeep() -> float:
	var total := 0.0
	for building in Colony.buildings:
		if is_instance_valid(building) and not building.is_site():
			total += building.def.faith_upkeep
	for golem in Colony.golems:
		if not is_instance_valid(golem) or not golem.alive:
			continue
		var def := Powers.get_power(golem.power_id)
		if def != null:
			total += def.upkeep
	return total


## The number that actually matters, and the one the resource bar shows with its sign:
##
##     net = passive generation + Tome bonuses - total Burden
##
## Once this is negative the pool is a countdown, which is exactly what the buffer is for. See
## RateLedger.faith() for the breakdown that lets the player decide what to shed.
func net_faith_rate() -> float:
	return passive_faith_rate() + tome_rate() - total_burden() - building_upkeep()


## Seconds until the buffer empties at the current rate, or -1.0 while it is filling.
func faith_runway() -> float:
	var rate := net_faith_rate()
	if rate >= 0.0:
		return -1.0
	return faith / maxf(-rate, 0.0001)


## Mood the colony gives up for its library. Applied by Villager._decay_needs, so an austere order
## partially eats its own Faith output — and eats more of it in a colony that was already unhappy.
func tome_mood_penalty() -> float:
	var total := 0.0
	for tome in tomes:
		if not tome.installed or tome.durability <= 0.0:
			continue
		var d := tome.def()
		if d != null:
			total += d.mood_penalty
	return total


# --- Taking up and giving back abilities ---------------------------------------------------

func is_taken_up(id: StringName) -> bool:
	return id in taken_up


## Can this power be taken up right now? Both layers have to pass: bought once with shards, and
## earned this run by raising the Temple.
func can_take_up(def: PowerDef) -> bool:
	if def == null or is_taken_up(def.id):
		return false
	if def.unlock_cost > 0 and not Meta.is_unlocked(def.id):
		return false
	return def.required_temple_tier <= Colony.temple_tier()


func take_up(def: PowerDef) -> bool:
	if not can_take_up(def):
		return false
	taken_up.append(def.id)
	Events.powers_changed.emit()
	# Named loudly, because this is the moment the player has committed to a permanent cost and it
	# must not be something they discover later by wondering why their Faith stopped filling.
	Events.notice.emit(L10n.t(&"NOTICE_POWER_TAKEN", [tr(def.display_name), "%.2f" % def.burden]), 1)
	return true


## Give an ability back and recover its Burden exactly.
##
## Required, not optional. Without it one greedy unlock is permanent regret and the whole mechanic
## reads as a punishment rather than a decision.
func relinquish(id: StringName) -> bool:
	if not is_taken_up(id):
		return false
	if not pay(RELINQUISH_COST):
		return false
	taken_up.erase(id)
	_cooldowns.erase(id)
	var def := Powers.get_power(id)
	Events.powers_changed.emit()
	if def != null:
		Events.notice.emit(L10n.t(&"NOTICE_POWER_GIVEN_BACK", [tr(def.display_name)]), 0)
	return true


## Powers that can be cast at this instant: taken up, AND with their Temple still standing.
##
## The second half is what makes the Temple worth defending. Losing it mid-run re-locks its tier's
## abilities rather than merely stopping new ones — but the Burden is dropped with them, so a
## colony that loses its Sanctum is weakened, not also bankrupted.
func power_active(def: PowerDef) -> bool:
	if def == null or not is_taken_up(def.id):
		return false
	return def.required_temple_tier <= Colony.temple_tier()


# --- Priests and the library ---------------------------------------------------------------

## Total installed-Tome capacity across every standing Temple.
func tome_capacity() -> int:
	var total := 0
	for b in Colony.buildings:
		if not is_instance_valid(b) or b.is_site():
			continue
		var def: BuildingDef = b.def
		total += def.tome_slots
	return total


func installed_count() -> int:
	var n := 0
	for tome in tomes:
		if tome.installed:
			n += 1
	return n


## A priest finishes a work cycle. Either three junk books become one better one, or a new one is
## written.
##
## Combining is preferred when it is possible, so labour goes to consolidation before it goes to
## yet another tier 1 — and it means combining genuinely COMPETES with scribing for the same
## priests, which is the allocation tension the mechanic is for.
##
## `priests` shifts the tier odds, which is what makes staffing the Temple a scaling investment
## rather than a binary on/off.
func priest_cycle(priests: int) -> void:
	if not auto_manage_library or not _try_combine():
		_scribe(priests)
	if auto_manage_library:
		_reshelve()
	Events.library_changed.emit()


## Roll a new Tome. Heavily weighted toward tier 1; more priests raise the tail.
func _scribe(priests: int) -> void:
	var archetype := Tomes.random_archetype()
	if archetype == null:
		return

	var tome := Tome.new()
	tome.archetype = archetype.id
	# One priest: ~6% tier 2, ~0.5% tier 3. Five priests: ~22% and ~4%. Capped so a fully staffed
	# Sanctum improves the odds substantially without making tier 1 vanish — the low tiers are the
	# feedstock for combining, so a Temple that never writes them starves itself.
	var bonus := clampf(float(priests - 1) * 0.04, 0.0, 0.18)
	var roll := randf()
	if roll < 0.005 + bonus * 0.2:
		tome.tier = 3
	elif roll < 0.06 + bonus:
		tome.tier = 2
	tome.toughness = _roll_toughness(archetype)
	tomes.append(tome)
	Events.tome_written.emit(tome.tier)
	if tome.tier > 1:
		Events.notice.emit(L10n.t(&"NOTICE_TOME_WRITTEN", [tome.label()]), 0)


func _roll_toughness(archetype: TomeDef) -> float:
	return clampf(randf_range(0.5, 1.8) + archetype.toughness_bias, 0.35, 2.2)


## Three SHELVED tomes of the same tier become one of the next.
##
## The result inherits the AVERAGE toughness of its inputs, which is the detail that makes
## combining interesting: feed it three fragile books and you get a fragile better one. So the
## player is always choosing between combining their durable tomes (strong but expensive) or
## dumping their junk (cheap but short-lived).
##
## Automated, and it always takes the three LEAST durable candidates of the lowest eligible tier.
## The manual version needed a library-management panel, and "dump your junk" is the choice a
## player makes almost every time anyway; what stays in their hands is how many priests to staff
## and — through the slot count — how big the active set is.
func _try_combine() -> bool:
	for tier in [1, 2]:
		var pool: Array[Tome] = []
		for tome in tomes:
			if not tome.installed and not tome.locked and tome.tier == tier \
					and tome.durability > 0.0:
				pool.append(tome)
		if pool.size() < 3:
			continue
		pool.sort_custom(func(a: Tome, b: Tome) -> bool: return a.toughness < b.toughness)
		var inputs := pool.slice(0, 3)

		var merged := Tome.new()
		merged.archetype = inputs[randi() % 3].archetype
		merged.tier = tier + 1
		var sum := 0.0
		for t: Tome in inputs:
			sum += t.toughness
		merged.toughness = sum / 3.0
		for t: Tome in inputs:
			tomes.erase(t)
		tomes.append(merged)
		Events.tome_written.emit(merged.tier)
		Events.notice.emit(L10n.t(&"NOTICE_TOME_COMBINED", [merged.label()]), 0)
		return true
	return false


## Keep the best books in the slots.
##
## Rebuilt from scratch each time rather than diffed, so a crumbled tome, a lost Temple and a fresh
## write all resolve through one path. Sorted by CURRENT rate first and toughness second — the
## strongest book installed, and among equals the one that will last.
func _reshelve() -> void:
	var capacity := tome_capacity()
	var locked_installed: Array[Tome] = []
	var ranked: Array[Tome] = []
	for tome in tomes:
		if tome.locked and tome.installed and tome.durability > 0.0:
			locked_installed.append(tome)
		elif not tome.locked:
			ranked.append(tome)
	ranked.sort_custom(func(a: Tome, b: Tome) -> bool:
		if not is_equal_approx(a.rate(), b.rate()):
			return a.rate() > b.rate()
		return a.toughness > b.toughness)

	var used := 0
	for tome in locked_installed:
		var keep := used < capacity
		tome.installed = keep
		if keep:
			used += 1
	for tome: Tome in ranked:
		var keep := used < capacity and tome.durability > 0.0
		tome.installed = keep
		if keep:
			used += 1


func _wear_tomes(delta: float) -> void:
	if tomes.is_empty():
		return
	var crumbled := false
	for tome in tomes:
		if not tome.installed or tome.durability <= 0.0:
			continue
		tome.durability -= tome.wear_per_second() * delta
		if tome.durability <= 0.0:
			tome.durability = 0.0
			crumbled = true
			Events.notice.emit(L10n.t(&"NOTICE_TOME_CRUMBLED", [tome.label()]), 1)
	if crumbled:
		# Drop the dust and promote whatever was waiting on the shelf, so a spare the priests
		# already wrote takes over rather than the slot sitting empty until the next cycle.
		var kept: Array[Tome] = []
		for tome in tomes:
			if tome.durability > 0.0:
				kept.append(tome)
		tomes = kept
		if auto_manage_library:
			_reshelve()
		else:
			_enforce_library_capacity()
		Events.library_changed.emit()


## Called when a Temple finishes or falls, so the slot count and the installed set stay in step.
func refresh_library() -> void:
	if auto_manage_library:
		_reshelve()
	else:
		_enforce_library_capacity()
	Events.library_changed.emit()


func set_library_auto_manage(active: bool) -> void:
	auto_manage_library = active
	if active:
		_reshelve()
	else:
		_enforce_library_capacity()
	Events.library_changed.emit()


func install_tome(index: int) -> bool:
	if index < 0 or index >= tomes.size():
		return false
	var tome := tomes[index]
	if tome.durability <= 0.0:
		return false
	if tome.installed:
		tome.installed = false
		Events.library_changed.emit()
		return true
	if installed_count() >= tome_capacity():
		return false
	tome.installed = true
	Events.library_changed.emit()
	return true


func toggle_tome_lock(index: int) -> bool:
	if index < 0 or index >= tomes.size():
		return false
	tomes[index].locked = not tomes[index].locked
	Events.library_changed.emit()
	return true


func combine_tome(index: int) -> bool:
	if index < 0 or index >= tomes.size():
		return false
	var chosen := tomes[index]
	if chosen.installed or chosen.locked or chosen.tier >= 3 or chosen.durability <= 0.0:
		return false
	var inputs: Array[Tome] = [chosen]
	for tome in tomes:
		if tome == chosen or tome.installed or tome.locked or tome.tier != chosen.tier \
				or tome.durability <= 0.0:
			continue
		inputs.append(tome)
		if inputs.size() == 3:
			break
	if inputs.size() < 3:
		return false
	var merged := Tome.new()
	merged.archetype = chosen.archetype
	merged.tier = chosen.tier + 1
	var toughness_sum := 0.0
	for tome in inputs:
		toughness_sum += tome.toughness
		tomes.erase(tome)
	merged.toughness = toughness_sum / 3.0
	tomes.append(merged)
	Events.tome_written.emit(merged.tier)
	Events.notice.emit(L10n.t(&"NOTICE_TOME_COMBINED", [merged.label()]), 0)
	if auto_manage_library:
		_reshelve()
	Events.library_changed.emit()
	return true


func tome_details(index: int) -> String:
	if index < 0 or index >= tomes.size():
		return ""
	var tome := tomes[index]
	var def := tome.def()
	return L10n.t(&"LIBRARY_DETAILS", [tome.label(), int(tome.durability),
		"%.2f" % tome.rate(), "%.2f" % tome.toughness,
		tr(def.description) if def != null else ""])


func pack_library() -> Array:
	var out: Array = []
	for tome in tomes:
		out.append({
			"archetype": String(tome.archetype),
			"tier": tome.tier,
			"toughness": tome.toughness,
			"durability": tome.durability,
			"installed": tome.installed,
			"locked": tome.locked,
		})
	return out


func restore_library(rows: Array, auto_manage: bool = true) -> void:
	tomes.clear()
	auto_manage_library = auto_manage
	for row: Dictionary in rows:
		var tome := Tome.new()
		tome.archetype = StringName(row.get("archetype", &""))
		if Tomes.get_tome(tome.archetype) == null:
			continue
		tome.tier = clampi(int(row.get("tier", 1)), 1, 3)
		tome.toughness = clampf(float(row.get("toughness", 1.0)), 0.2, 2.2)
		tome.durability = clampf(float(row.get("durability", 100.0)), 0.0, 100.0)
		tome.installed = bool(row.get("installed", false))
		tome.locked = bool(row.get("locked", false))
		tomes.append(tome)
	if auto_manage_library:
		_reshelve()
	else:
		_enforce_library_capacity()
	Events.library_changed.emit()


func _enforce_library_capacity() -> void:
	var capacity := tome_capacity()
	var used := 0
	for tome in tomes:
		if not tome.installed:
			continue
		if used < capacity and tome.durability > 0.0:
			used += 1
		else:
			tome.installed = false


## How fast Faith accrues right now, as a multiple of the base rate. Exposed so the
## HUD can show the player WHY their Faith is crawling — a number that silently
## depends on morale is indistinguishable from a broken one.
func faith_multiplier() -> float:
	var pop := Colony.population()
	if pop <= 0:
		return 0.0

	# Mood maps to a multiplier around 1.0 at "content" (60). A colony in despair
	# still trickles a little rather than stopping dead, so a bad night is
	# recoverable instead of a death spiral.
	var mood_factor := clampf(Colony.average_mood() / 60.0, 0.15, 1.8)

	# More people means more worship, but with sharply diminishing returns so that
	# a large colony does not trivialise the Faith economy.
	var pop_factor := clampf(sqrt(float(pop) / 6.0), 0.4, 2.2)

	return mood_factor * pop_factor


## The light grid is restamped only when the Ember crosses into a new CELL, not on
## every sub-pixel of the glide. Restamping per frame would redo a whole disc of
## light sixty times a second for no visible gain.
func _process(delta: float) -> void:
	if ember_cell == -1:
		return

	# The glide runs on a Tween, which the sim clock does not drive. Feeding it the sim's
	# speed handles pause (scale 0 freezes it mid-flight) and fast-forward (the Ember
	# travels at the same rate the world does) in one line. Without this the Ember would
	# keep sailing across a paused map.
	if _travel != null and _travel.is_valid():
		_travel.set_speed_scale(Sim.speed_scale())

	# A drag steers a target rather than the Ember itself, so the follow stays smooth
	# however coarsely or unevenly the touch events happen to arrive.
	if _dragging:
		ember_pos = ember_pos.lerp(_drag_target, clampf(DRAG_FOLLOW_RATE * delta, 0.0, 1.0))
	var cell := World.grid.to_cell_index(ember_pos)
	if cell != -1 and cell != ember_cell:
		ember_cell = cell
		World.light_field.move_source(_light_handle, cell)
		Events.ember_moved.emit(ember_pos)


# --- The Ember ---------------------------------------------------------------------

## Snap the Ember somewhere with no travel at all. Run setup, saves, teleports —
## anything where there is no gesture to stay in step with.
func place_ember(cell: int) -> void:
	if not World.grid.is_valid_index(cell):
		return
	_dragging = false
	_kill_travel()
	ember_cell = cell
	ember_pos = World.grid.to_world_index(cell)
	if _light_handle == 0:
		_light_handle = World.light_field.add_source(cell, ember_radius, ember_strength)
	else:
		World.light_field.move_source(_light_handle, cell)
	Events.ember_moved.emit(ember_pos)


## Glide the Ember to a cell. Duration scales with distance so it holds a roughly
## constant speed, and eases out so it settles rather than stopping dead. Retargeting
## mid-flight simply replaces the tween — the Ember turns and continues.
func tween_ember_to(cell: int) -> void:
	if not World.grid.is_valid_index(cell) or ember_cell == -1:
		return
	var target := World.grid.to_world_index(cell)
	var duration := clampf(ember_pos.distance_to(target) / TRAVEL_SPEED, TRAVEL_MIN, TRAVEL_MAX)

	_dragging = false
	_kill_travel()
	_travel = create_tween()
	_travel.tween_property(self, "ember_pos", target, duration)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


# --- Dragging ---------------------------------------------------------------------
#
# Direct manipulation, so it does NOT go through the grid: the Ember follows a
# free world-space point and only settles onto a cell when the finger lifts.
# Rounding to the nearest tile mid-gesture is what made the light sit beside the
# thumb instead of under it.

## Take hold of the Ember. Any glide in flight is abandoned — the player's hand wins.
func begin_ember_drag() -> void:
	if ember_cell == -1:
		return
	_kill_travel()
	_dragging = true
	_drag_target = ember_pos


## Aim the drag. The Ember is not moved here; _process eases it toward this point.
func drag_ember_to(world_pos: Vector2) -> void:
	if not _dragging:
		return
	# Clamped to the map so a finger dragged past the edge cannot strand the Ember
	# where to_cell_index reads -1 and the light quietly stops moving with it.
	var rect := World.grid.world_rect()
	_drag_target = Vector2(
		clampf(world_pos.x, rect.position.x, rect.end.x - 1.0),
		clampf(world_pos.y, rect.position.y, rect.end.y - 1.0)
	)


## Let go. The Ember settles onto the centre of whichever tile it came to rest over.
func end_ember_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	var cell := World.grid.to_cell_index(ember_pos)
	if cell == -1:
		return
	_kill_travel()
	_travel = create_tween()
	_travel.tween_property(self, "ember_pos", World.grid.to_world_index(cell), DRAG_SETTLE_TIME)\
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func is_dragging() -> bool:
	return _dragging


func is_travelling() -> bool:
	return _travel != null and _travel.is_valid() and _travel.is_running()


func _kill_travel() -> void:
	if _travel != null and _travel.is_valid():
		_travel.kill()
	_travel = null


func ember_position() -> Vector2:
	return ember_pos


## True when a cell sits inside the Ember's aura. Hot path — called per agent per
## think, so it compares squared distances and never allocates.
func is_within_ember(cell: int) -> bool:
	if ember_cell == -1:
		return false
	return World.grid.dist_sq(cell, ember_cell) <= ember_radius * ember_radius


## Multiplier applied to villager work rate and mood retention inside the aura.
func work_bonus(cell: int) -> float:
	var bonus := 1.5 if is_within_ember(cell) else 1.0
	for building in Colony.buildings:
		if not is_instance_valid(building) or building.is_site() or building.held_by_hand \
				or building.def.work_aura <= 0.0:
			continue
		if World.grid.dist_sq(cell, building.centre_cell()) <= 5 * 5:
			bonus = maxf(bonus, 1.0 + building.def.work_aura)
	return bonus


# --- Faith -------------------------------------------------------------------------

# --- Powers ---------------------------------------------------------------------------

func cooldown_of(id: StringName) -> float:
	return _cooldowns.get(id, 0.0)


func can_cast(def: PowerDef) -> bool:
	if not power_active(def):
		return false
	return faith >= def.faith_cost and cooldown_of(def.id) <= 0.0


## Cast a power at a world position. Returns true if it actually went off — the
## caller should not assume success, because "not enough Faith" is a normal and
## frequent outcome rather than an error.
func cast(def: PowerDef, world_pos: Vector2) -> bool:
	if not can_cast(def):
		return false
	var centre := World.grid.to_cell_index(world_pos)
	if centre == -1:
		return false

	if def.kind == PowerDef.Kind.CONSTRUCT and not _can_place_construct(def, centre):
		return false
	if not pay(def.faith_cost):
		return false
	_cooldowns[def.id] = def.cooldown

	match def.kind:
		PowerDef.Kind.LIGHT:
			_cast_light(def, centre)
		PowerDef.Kind.SMITE:
			_cast_smite(def, world_pos)
		PowerDef.Kind.PURIFY:
			_cast_purify(def, centre)
		PowerDef.Kind.BUFF:
			_cast_buff(def, world_pos)
		PowerDef.Kind.HEAL:
			_cast_heal(def, world_pos)
		PowerDef.Kind.RECALL:
			_cast_recall(def, world_pos)
		PowerDef.Kind.KINDLE:
			_cast_kindle(def, centre, world_pos)
		PowerDef.Kind.HARVEST:
			_cast_harvest(def, centre)
		PowerDef.Kind.CONJURE:
			Colony.add(def.resource_kind, int(def.amount))
		PowerDef.Kind.HALLOW:
			_cast_hallow(def, world_pos)
		PowerDef.Kind.CONSTRUCT:
			_cast_construct(def, centre)
		PowerDef.Kind.BANISH:
			_cast_banish(def, world_pos)
		PowerDef.Kind.CHARM:
			_cast_charm(def, world_pos)
		PowerDef.Kind.WEATHER:
			Climate.force_weather(def.weather_id, clampf(def.amount / 100.0, 0.0, 1.0))
		PowerDef.Kind.LAST_RITE:
			_cast_heal(def, world_pos)
			_cast_smite(def, world_pos)

	Events.power_cast.emit(def.id, world_pos)
	return true


## Strengthen or steady whoever is standing here.
##
## Three independent numbers rather than a buff TYPE, so Rally (speed and damage) and Blessing
## (mood) are the same code path with different content. A power that sets only mood_boost is a
## blessing; one that sets speed and damage is a rally; one that sets all three is whatever a
## designer wants to call it. Nothing here branches on which power it is.
func _cast_buff(def: PowerDef, world_pos: Vector2) -> void:
	var reach := float(def.radius) * Grid.TILE_SIZE
	var reach_sq := reach * reach
	for v in Colony.villagers:
		if not is_instance_valid(v) or not v.alive:
			continue
		if v.position.distance_squared_to(world_pos) > reach_sq:
			continue
		if def.mood_boost > 0.0:
			# Mood lands outright and stays. It then feeds back into faith_multiplier, which is
			# why Blessing is the power that partly pays for itself.
			v.mood = minf(v.mood + def.mood_boost, Villager.NEED_MAX)
		if def.speed_boost > 0.0 or def.damage_boost > 0.0:
			v.apply_boost(def.speed_boost, def.damage_boost, def.boost_duration)


func _cast_heal(def: PowerDef, world_pos: Vector2) -> void:
	var reach_sq := pow(float(def.radius * Grid.TILE_SIZE), 2.0)
	for villager in Colony.villagers:
		if is_instance_valid(villager) and villager.alive \
				and villager.position.distance_squared_to(world_pos) <= reach_sq:
			villager.health = minf(villager.health + def.amount, villager.max_health)
	for building in Colony.buildings:
		if is_instance_valid(building) and not building.is_site() \
				and building.centre_position().distance_squared_to(world_pos) <= reach_sq:
			building.hp = minf(building.hp + def.amount, building.def.max_hp)
			building._refresh_damage_bar()


func _cast_recall(def: PowerDef, world_pos: Vector2) -> void:
	var reach_sq: float = pow(float(def.radius * Grid.TILE_SIZE), 2.0)
	var chosen: Villager = null
	var best: float = reach_sq
	for villager in Colony.villagers:
		if not is_instance_valid(villager) or not villager.alive:
			continue
		var distance: float = villager.position.distance_squared_to(world_pos)
		if distance <= best:
			best = distance
			chosen = villager
	if chosen != null:
		var safe := World.nearest_walkable(World.keep_cell, 5)
		if safe != -1:
			chosen.stop()
			chosen.position = World.grid.to_world_index(safe)
			chosen.think_urgent = true


func _cast_harvest(def: PowerDef, centre: int) -> void:
	var origin := World.grid.coord(centre)
	for dy in range(-def.radius, def.radius + 1):
		for dx in range(-def.radius, def.radius + 1):
			if dx * dx + dy * dy > def.radius * def.radius:
				continue
			var point := origin + Vector2i(dx, dy)
			if not World.grid.is_valid_v(point):
				continue
			var cell := World.grid.index_v(point)
			var feature := World.feature_at(cell)
			if not Terrain.is_harvestable(feature):
				continue
			for kind: StringName in Terrain.yield_of(feature):
				Colony.add(kind, int(Terrain.yield_of(feature)[kind]))
			World.clear_feature(cell)


func _cast_hallow(def: PowerDef, world_pos: Vector2) -> void:
	var reach_sq := pow(float(def.radius * Grid.TILE_SIZE), 2.0)
	for building in Colony.buildings:
		if not is_instance_valid(building) or building.is_site() \
				or building.centre_position().distance_squared_to(world_pos) > reach_sq:
			continue
		building.hallowed_remaining = maxf(building.hallowed_remaining, def.duration)
		building.hp = minf(building.hp + def.amount, building.def.max_hp)
		building._refresh_damage_bar()


func _can_place_construct(def: PowerDef, centre: int) -> bool:
	if not def.construct_role.is_empty():
		if Colony.golem_count() >= Colony.GOLEM_CAP \
				or (def.persistent_limit > 0 \
				and Colony.golem_count(def.id) >= def.persistent_limit):
			return false
		return World.grid.is_valid_index(centre) and World.is_walkable(centre) \
			and World.in_influence(centre)
	var construct := Buildings.get_building(def.construct_id)
	if construct == null:
		return false
	if def.persistent_limit > 0:
		var count := 0
		for building in Colony.buildings:
			if is_instance_valid(building) and building.def.id == def.construct_id:
				count += 1
		if count >= def.persistent_limit:
			return false
	return bool(Colony.check_placement(construct, centre).get("ok", false))


func _cast_construct(def: PowerDef, centre: int) -> void:
	if not def.construct_role.is_empty():
		Colony.spawn_golem(def, centre)
		return
	Colony.place_divine_construct(Buildings.get_building(def.construct_id), centre)


func _cast_banish(def: PowerDef, world_pos: Vector2) -> void:
	var reach_sq := pow(float(def.radius * Grid.TILE_SIZE), 2.0)
	for hostile: Agent in Threat.hostiles.duplicate():
		if not is_instance_valid(hostile) or not hostile.alive \
				or hostile.position.distance_squared_to(world_pos) > reach_sq:
			continue
		hostile.take_damage(def.amount, null, def.damage_type)
		hostile.knockback_from(world_pos, maxf(float(def.radius) * 0.75, 1.0))


func _cast_charm(def: PowerDef, world_pos: Vector2) -> void:
	var reach_sq: float = pow(float(def.radius * Grid.TILE_SIZE), 2.0)
	var chosen: Monster = null
	var best: float = reach_sq
	for monster in Threat.monsters:
		if not is_instance_valid(monster) or not monster.alive \
				or monster.has_behavior(&"boss") or monster.has_behavior(&"rooted"):
			continue
		var distance: float = monster.position.distance_squared_to(world_pos)
		if distance <= best:
			best = distance
			chosen = monster
	if chosen != null:
		chosen.apply_charm(def.duration)


func _cast_light(def: PowerDef, centre: int) -> void:
	var handle := World.light_field.add_source(centre, def.radius, int(def.amount))
	if def.duration > 0.0:
		_temp_lights.append({"handle": handle, "expires": def.duration})
	# A new light changes how monsters want to route, so the field has to be redone.
	Threat.mark_field_dirty()


func _cast_kindle(def: PowerDef, centre: int, world_pos: Vector2) -> void:
	var handle := World.light_field.add_source(centre, def.radius, 210)
	_temp_lights.append({"handle": handle, "expires": maxf(def.duration, 1.0)})
	Threat.mark_field_dirty()
	_cast_smite(def, world_pos)


func _cast_smite(def: PowerDef, world_pos: Vector2) -> void:
	var reach := float(def.radius) * Grid.TILE_SIZE
	var reach_sq := reach * reach
	for m in Threat.hostiles.duplicate():
		if not is_instance_valid(m) or not m.alive:
			continue
		if m.position.distance_squared_to(world_pos) <= reach_sq:
			m.take_damage(def.amount, null, def.damage_type)

	# Nests are corrupted things standing in the blast too. Without this the only way
	# to hurt a nest would be to wait for it to walk to you, which it never does — and
	# the run reward for clearing one would stay permanently unreachable.
	for nest in World.live_nest_cells():
		if World.grid.to_world_index(nest).distance_squared_to(world_pos) <= reach_sq:
			World.damage_nest(nest, def.amount)

	# And the Blight's buildings. Keys are copied first because damage_blight_structure erases from
	# the dictionary being walked when a structure falls.
	for cell in World.blight_structures.keys():
		if World.grid.to_world_index(cell).distance_squared_to(world_pos) <= reach_sq:
			World.damage_blight_structure(cell, def.amount, &"holy")


## Fraction of a purify power's strength that lands on a nest as damage.
##
## Held below 1.0 because purification is measured against a 0-255 blight intensity
## and nests have hit points on a different scale entirely — passing the raw amount
## through would let one cheap Ward delete a nest outright.
const PURIFY_NEST_SCALE := 0.5

func _cast_purify(def: PowerDef, centre: int) -> void:
	var grid: Grid = World.grid
	var c := grid.coord(centre)
	for dy in range(-def.radius, def.radius + 1):
		for dx in range(-def.radius, def.radius + 1):
			if dx * dx + dy * dy > def.radius * def.radius:
				continue
			if not grid.is_valid(c.x + dx, c.y + dy):
				continue
			var cell := grid.index(c.x + dx, c.y + dy)
			World.blight_field.purify(cell, int(def.amount))
			# Purification is the thematically right answer to a blight source, so it
			# is also the efficient one: Ward is cheaper than Wrath and hurts nests
			# harder. That split is what gives the two powers distinct jobs instead of
			# both being "press to deal damage".
			World.damage_nest(cell, def.amount * PURIFY_NEST_SCALE)
			# Same treatment for the Blight's buildings, so Consecrate is the tool for clearing a
			# whole enemy camp in one cast rather than a tower's worth of patience per structure.
			World.damage_blight_structure(cell, def.amount * PURIFY_NEST_SCALE, &"holy")


func _expire_lights(delta: float) -> void:
	if _temp_lights.is_empty():
		return
	var kept: Array = []
	for entry: Dictionary in _temp_lights:
		entry["expires"] -= delta
		if entry["expires"] > 0.0:
			kept.append(entry)
		else:
			World.light_field.remove_source(entry["handle"])
			Threat.mark_field_dirty()
	_temp_lights = kept


func _tick_cooldowns(delta: float) -> void:
	for id in _cooldowns.keys():
		var remaining: float = _cooldowns[id] - delta
		if remaining <= 0.0:
			_cooldowns.erase(id)
		else:
			_cooldowns[id] = remaining


# --- Faith -------------------------------------------------------------------------

## Faith earned by destroying a Blight creature, banked for the night's tally.
##
## Goes through here rather than straight into `faith` so the dawn report can tell the player
## what the night was worth. A reward nobody notices is not a reward.
func reward_kill(amount: float) -> void:
	if amount <= 0.0:
		return
	faith = minf(faith + amount, faith_max())
	night_faith_earned += amount
	Events.faith_changed.emit(faith)


## Essence is a board object, not a currency. Absorbing it turns the object into the existing
## Faith economy, while Collectors can instead turn the same mote into local building energy.
func absorb_essence(amount: int) -> void:
	if amount <= 0:
		return
	faith = minf(faith + float(amount), faith_max())
	Events.faith_changed.emit(faith)


func can_pay(cost: float) -> bool:
	return faith >= cost


func pay(cost: float) -> bool:
	if not can_pay(cost):
		return false
	faith -= cost
	Events.faith_changed.emit(faith)
	return true
