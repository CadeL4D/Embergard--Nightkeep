# Embergard: Nightkeep — Development Plan

**Living document.** Update it when work lands or a decision changes. If this file and the code
disagree, the file is wrong — fix it.

Last updated: 2026-07-30

---

## Status

| Phase | Scope | State |
|---|---|---|
| **0** | Close dead systems, menu, difficulty, gates, site picker, pause, audio plumbing | ✅ **done** |
| **1** | Population growth, threat curve, needs + thirst, dead air, kill rewards, rate ledger | ✅ **done** |
| **3** | Localization scaffolding | ✅ **done** |
| **2** | Colony depth | ✅ **done** — 2.1–2.9, smaller grid, resource masses |
| **4** | The Realm — seeded regional world + independent colonies | ✅ **done** |
| **5** | Audio content, onboarding, accessibility, desktop parity, stats | ✅ **done** |
| **6** | Biomes, storyteller events, weather | ⬜ pending |

## Visual scale and presentation overhaul — done 2026-07-30

This pass answered the "128 px buildings" problem without changing the simulation grid:

- **Authored cells remain 16 px.** The apparent size came from a 2× camera inside the 2× display
  stretch. The default camera is now **1×**, with curated 0.5/0.75/1/1.5/2/3/4× snap points. The
  default view therefore shows twice as much in each direction — roughly four times the map area —
  while pathfinding, placement, footprints and saves keep the same coordinates.
- **Maps gained a visual-only dressing layer.** Atlas row 39 contains deterministic grass tufts,
  weeds, stones, cracks, sand ripples, water glints, rubble and flowers. `WorldView` never writes
  them into `World.feature`, so decoration cannot block a route, become a fake resource or enter a
  save. Ground noise was reduced at the same time so deliberate details read instead of dissolving
  into salt-and-pepper texture.
- **Forests and quarries now use 16 connection-mask tiles with eight visual variants each.** Each
  cell selects a four-bit N/E/S/W connection mask plus an independently mixed surface variant. Shared
  edges are full-bleed and the atlas retains only the coarse transparent silhouette needed to compose
  cells. Harvesting repaints the changed cell and its four neighbors without adding save state.
  - **The visible rim is traced once around each whole connected region.** `FeatureDetails` flood-fills
    every forest and quarry, traces both outer boundaries and clearing holes, inserts broad seeded
    variations along long runs, and applies two corner-cutting smoothing passes. Separate culled line
    items draw the near-black/deep-green forest bands and warm rock bands. The simulation remains
    exactly cell-based, but the player no longer sees a 16 px staircase or one repeated scallop per
    tile. The old atlas rim was removed after capture review because drawing both systems produced a
    doubled cable-like outline.
  - **Large surface contours use the same view-only layer.** A small deterministic set of irregular
    3-tile-wide canopy lobes and stone shelves is placed only where a resource is solid for one or two
    cells around the chosen point. They reproduce the reference's broad interior forms without
    restarting in every atlas cell, never cross an exposed resource edge, and rebuild after harvesting
    without entering pathing or save data. Tile-local contour stamps remain deliberately excluded
    because their repetition was visible at gameplay scale.
  - **Berries do not use the connected terrain system.** Three compact shrub silhouettes occupy
    less than one 16 px cell, leave ground visible around them, and retain bright fruit accents even
    when several berry cells are adjacent.
  - Visual-development reference: `assets/concepts/connected_natural_features_reference.png`.
  - Resource noise frequency was reduced from 0.06 to 0.045, core fill was raised, and deterministic
    cleanup removes isolated cells, closes small holes, and deletes cardinally connected regions below
    eight cells after the keep clearing is cut. The result is fewer, larger forests and quarries rather
    than lone props or resources dusted evenly across the map.
- **World art was re-keyed and re-baked.** The shared `ArtData` palette has clearer stone, timber,
  water and foliage ramps, and every unit/building/blight sprite gets a restrained one-pixel contact
  shadow from the baker. Existing widened building silhouettes and gameplay footprints are kept.
  Villagers now have a stronger hood/scarf/tunic silhouette, and all six carried-resource icons were
  redrawn at 9×9 px so raw and processed goods remain distinct at the 1× camera.
- **The title screen now has a production backdrop** at
  `assets/ui/nightkeep_menu_backdrop.png`, with a left-side readability gradient and a responsive
  menu column. Root, New World, Options and Credits are captured by
  `scenes/dev/menu_screenshot.tscn`.
- **The shared theme now actually reaches every Control.** A plain `Node` or `CanvasLayer` breaks
  Godot theme inheritance; the old root-window-only application silently left many buttons and
  sliders at stock 16 px sizing. `Ui` now reapplies the same `UiTheme` wherever Control inheritance
  restarts, including runtime-built rows and buttons.
- **HUD drawers are mutually exclusive and clipped.** Resource breakdown, jobs, build placement and
  the survivor prompt cannot stack into one another. Building cards and the power/action bar scroll
  horizontally when needed; the job board scrolls vertically; selection cards yield to the active
  drawer. The job board is now 294 px wide and 220 px tall, with a precise minus and plus button
  around every slider. Resource and phase bars remain visible in the 800×360 safe area.
- **All menu states and gameplay phases were visually checked at 1600×720 output.** The gameplay
  capture set now includes the new 1× default plus jobs, building, dusk and night views.

Local engine used for this workspace:
`C:\Users\cadel\Documents\Godot\Godot_v4.7-stable_win64_console.exe`.

## Verified state

Phases 0–3 are **engine-verified**: the whole project parses with zero errors, the smoke test passes
**all checks across 4 seeds**, and the stress test shows no regression.

**One caveat, stated because it is real.** The suite has nondeterministic timing margins. During the
visual-overhaul verification, one run reached the farm assertion before its first yield (`0` food);
the next reached the construction assertion at `17/22` work and consequently failed its dependent
blocking check. The immediately following run passed every check across all four seeds. Neither
visual code nor camera scale enters those formulas; the failures identify the existing timed waits
that need deterministic completion conditions. Blight growth, Tome scribing and migrant timing also
draw on the global RNG, so other roll-sensitive margins may remain.

`_report()` now appends every failure to `user://smoke_failures.log`, so the next flake is captured
whether or not anyone is watching. Run the suite in a loop and read that file rather than hunting it
live — that is what finally identifies it.

**Latest rounded-terrain validation (2026-07-30):** the final eight-cell cleanup passed all four
seeds and the live run, including day-one wood and stone delivery. A 12-cell experiment was rejected
because it removed seed 2024's practical opening quarry. Before that tuning, one run hit the
documented live-scene margin at exactly 9/22 construction work; its immediate rerun passed. The final
iOS pack is 4,116,172 bytes, and `verify_export.py` confirms that every runtime catalog and directly
read file is present.

```
Godot_v4.7-stable_win64_console.exe --headless --import --path .                          # 1
Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/dev/bake_assets.tscn # 2
Godot_v4.7-stable_win64_console.exe --headless --import --path .                          # 3
Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/dev/smoke.tscn
Godot_v4.7-stable_win64_console.exe --headless --path . res://scenes/dev/stress.tscn
```

**Import, bake, import — in that order, and every step earns its place.** Only the editor writes
`.import` files and registers `class_name` scripts; a headless bake does neither. So:

- **without step 1**, a bake that references a newly added `class_name` fails to parse it
  (`Could not find type "BlightStructureDef"`) and takes half the autoloads down with it
- **without step 3**, `load()` on the freshly written PNGs fails and *the catalogs skip the entry
  with no error at the point of use* — it presented as `building catalog loaded (6 defs)` when 19
  exist, which looks exactly like a content bug and is not one. It also leaves the imported atlas at
  its old size, so a new tileset row is "outside the texture" and every tile in it fails to create.

All three failure modes are silent or misleading at the place they surface. Run the full sequence.

### Verify the EXPORT, not just the project

```
Godot_v4.7-stable_win64_console.exe --headless --path . --export-pack "iOS" build/verify/test.pck
python tools/verify_export.py build/verify/test.pck
```

**The smoke test runs from source, so it structurally cannot catch a file the exporter drops.** One
was, and it shipped: `content/locale/embergard.csv.import` carried `importer="csv_translation"`, which
makes Godot treat the CSV as the *source* of an imported resource and ship only the generated
`.translation`. The `Locale` autoload reads the CSV itself, so on device it found nothing, registered
zero translations, and **every label and button in the game rendered as its own key** — `UI_NEW_WORLD`,
`RESOURCE_WOOD`, the entire UI. In the editor it was completely invisible.

Fixed three ways, deliberately redundant because the failure is silent, total, and only visible on a
device: the `.import` is now `importer="keep"`, `export_presets.cfg` sets `include_filter="*.csv"`, and
`Locale` falls back to any `.translation` resources it can find and reports `healthy()`.

**Anything the game opens with `FileAccess` rather than `load()` has this exposure.** `verify_export.py`
checks the pack for those paths *and* for their content — a path can sit in the index while the payload
is an imported stub — plus every content catalog. Run it before any store build.

**Performance:** post-overhaul stress is **7.74 ms** average at 60 villagers + 118 live monsters,
against a 5.5 ms
desktop target. Mid-phase, a stashed pre-Phase-2 baseline measured **6.92 ms** against 6.90 ms for the
same-day Phase 2 build — i.e. the influence layer, road cost table, per-tile speed sampling and six
monster types cost nothing detectable.

The later ~1 ms rise is **not attributed**. Two candidates were measured and ruled out or fixed:
`rebalance()`'s workplace gating costs 0.04 ms, and `_on_roster_changed` was rebuilding the entire
tab strip and card row on *every villager spawn* (~420 card instantiations during a 60-villager
setup) — now signature-guarded, which is worth doing regardless but landed inside noise. A clean A/B
is no longer possible by stashing, because the work is committed; it needs a `git worktree` at
`12e6fcf` measured back to back. **Do not assume it is drift and do not assume it is a regression** —
measure it properly before acting.

The verdict is `OVER` and was `OVER` before any of this, so it is a standing item. Roughly a 2× margin
against a 60 fps frame; worth profiling before mobile, not before then.

---

## Locked decisions

| Decision | Choice |
|---|---|
| Identity | Roguelite. The whole world regenerates from a seed each run; only the `Meta` profile persists. |
| Objective | Everything orbits the **Heart** (first colony). Later colonies **directionally shield** it. |
| Run length | Long haul — 6-10 hours per world, save-and-resume. |
| Platform | **Mobile-first, desktop playable.** 800×360 (20:9), `canvas_items` stretch, `expand` aspect. |
| Audio | Procedural, baked to WAV mirroring `bake_assets.gd`. Music synthesized at runtime. |
| Background colonies | Abstracted ledger + deterministic reconstitution + visitable. No autoload refactor. |
| Difficulty | 4 tiers, chosen at world creation. Every field is a multiplier on an existing tuned value. |
| Economy | Multi-stage production chain, gated by a tiered Village Center. |
| Buildable area | Sphere of influence — amorphous, grows directionally. |
| Divine layer | Passive Faith + ability **Burden**; priests scribe perishable **Tomes**. |
| UI styling | One `Theme` built in code from `UiPalette`. No scattered `add_theme_*_override`. |

### Standing conventions

- **Data-driven or nothing.** `JobDef`, `BuildingDef`, `MonsterDef`, `PowerDef`, `DifficultyDef`
  all carry the rule: *if you catch yourself writing `if def.id == ...`, the property you need is
  missing from the class.* Add an `@export`, not a branch.
- **Derived state is never saved.** Occupancy, move cost, light, flow fields, the shore index and
  the nest-HP table are all rebuilt from what is saved.
- **One source of truth per number.** The rate ledger reads `Villager.MOOD_*` constants rather
  than restating them; the blight shader is handed `TileAtlas.CORRUPT_THRESHOLD` rather than
  duplicating it. Duplicated tuning silently drifts.
- **Typed locals.** Reading a member off an `InputEvent`- or `Node`-typed value yields a Variant
  and breaks `:=` inference. Narrow with a cast, or type the parameter.

---

## Phase 0 — done

| # | Item | Notes |
|---|---|---|
| 0.1 | Ward power | `content/powers/ward.tres`, `kind = 2`. `_cast_purify` was implemented and unreachable. |
| 0.2 | Destructible nests | `Terrain.NEST_HP = 260`. Damaged by Wrath (42), Ward (60, the efficient answer), and idle watchtowers (siege play). `Threat._spawn_cell` reads **live** nests only, so clearing one shifts attacks. |
| 0.3 | Notifications | `notice_log.gd` toasts + `breach_markers.gd` screen-edge arrows for off-screen breaches only. `Events.notice` previously had one subscriber that discarded everything below urgency 2. |
| 0.4 | Selection card | Finally calls `Villager.describe()`, which was written and never invoked. |
| 0.5 | Debug keys guarded | **R** wiped the run with no confirmation in retail. |
| 0.6 | Pause + speed | Real `Sim.paused` flag. `time_scale = 0` alone was not enough — towers count reload in raw delta and the Ember glides on a Tween. |
| 0.7 | Main menu | Title / New World / Options / Credits as swapped panels. Seeds are text and hash if non-numeric, so worlds can be named. |
| 0.8 | Difficulty | Sheltered / Harried / Besieged / Forsaken. |
| 0.9 | Gates | `blocks_monsters_only` + a dedicated `World.gate` byte layer (the flow field reads it 16k times per sweep). Charged `WALL_PENALTY`, not forbidden — the funnel is the point. |
| 0.10 | Site picker | `MapGen.generate(seed, keep_override)`; regenerates around the chosen cell. `_choose_keep` still runs so the RNG advances identically either way. |
| 0.11 | UI Theme | `UiPalette` + `UiTheme` + `Ui` autoload. |
| 0.12 | Audio plumbing | 4 buses, linear→dB volumes, 12-player pool, `play_sfx()` no-ops on unknown ids so call sites can be written now. |

**Two map-gen bugs fixed:** `_flatten_keep` converted all water within radius 7 to dirt (filling
in the lake you deliberately settled beside — `KEEP_PAD_RADIUS = 5` now, sized to preserve the
smoke test's walkability guarantee); `_clear_around_keep` deleted all berries near spawn.

---

## Phase 1 — done

### Final tuned values

These **override** what the plan originally specified. Several were retuned from live play.

| System | Value | Why |
|---|---|---|
| Threat budget | `4 + night*2.5 + 1.18^night * 1.5` | Was `3 + 1.32^night * 2` — night 20 hit 519, five times over the 120-body cap. Now 95, inside it. |
| Phases | 240 / 60 / 120 / 45 = **465s** | Idle share 41% → 31%. Sub-25% needs the Warrior job. |
| `REST_IN_BED` | 6.0 (was 16.0) | A full night's sleep took **4.7 seconds**; a hut bought ~5% productivity. |
| `ROUGH_REST_CAP` | 60 + mood penalty | A roof is the only route to properly rested. |
| Farm | 18s work / 6 food | One farmer fed 16.5 people; now 5.6. |
| Berries | 0.035 (was 0.012) | Only pre-farm food, at ~1% of grass tiles. |
| `THIRST_RATE` | 0.30, urgent at 40 | ~2.6 drinks/cycle. Answered by walking, not by stock. |
| `MOOD_DRIFT` | 0.5, falling at ×0.5 | Was 2.5 — the full range in 40s, chasing every threshold flip. Asymmetric so routine hunger does not drag the average. |
| Mood terms | base 62; hungry −20, thirsty −12, tired −12, rough −18, ember +25, blighted −18 | Transient states (walking to water) are the system working, not failing. Heavy penalties are for structural failures. |
| Faith cap | `40 + pop*25 + Σ building.faith_capacity` | Hearth contributes 60. A flat 100 made the ceiling a property of the game, not of the colony. |
| `BASE_SPREAD` | 0.005, night ×1.6 | Was 0.02 / ×2.0 = **7.3% of the map per day**. Now 1.8% on Harried — 25% of the map in 14 days. |
| `faith_on_death` | Shambler 1.2, Spitter 2.4 | Scaled off `threat_cost`. Dawn burn-off pays nothing — sunrise is not a victory. |

### Growth: two systems, deliberately different

**Births** — internal, conditional, and they **stall rather than reset**. Minimum standard: a spare
bed, water, 2 days of food, mood ≥ 45. Progress freezes on failure, so a bad night costs time and
not the whole investment. Threshold randomised per birth (0.75–1.35) so growth never lands on a
countable beat.

**Migration** — external, ~2 cycles apart, heavily jittered, and runs **regardless** of colony
state. A band of 1–3 arrives and the player **accepts or turns them away**. Accepting with no beds
is allowed; that is the decision. Refusing costs 6 mood. They leave after 45s.

**No countdown is exposed.** An ETA turned growth into a watched timer, and its inputs move
continuously so the figure jittered uselessly. The HUD shows one blocker word instead.

### Rate ledger (1.6)

`RateLedger` is **pull, not push** — nothing registers contributions; it asks the systems on demand
and only while the panel is open. Terms are **computed where the game is a formula** (mood, Faith)
and **measured where it is a stream of events** (foraging).

Farm supply is computed from occupied work slots, which is why the readout is stable. Measuring it
produced `+7440/day` from a single 8-food haul inside a 2-second sample. Window is now 90s.

`_check_ledger` asserts every breakdown **adds up to the number printed above it**. This is a hard
prerequisite for Phase 2.8 — a Burden system is unplayable if a negative Faith rate cannot explain
itself.

### Corruption rendering (unplanned; added from play feedback)

Blight read as floating fog. Three causes:

1. **`BlightOverlay` was the last child of `WorldView`, after `Sorted`** — so it drew over
   villagers, trees and buildings. Now `z_index = -1`.
2. **The shader was fog by construction** — UV warp off the tile grid, translucent alpha, a `sin`
   pulse. Now no warp, opaque, 4×4 ordered dither, no animation.
3. **It was never terrain.** Atlas extended to 7 rows; rows 4-6 mirror 0-2 with corrupted variants
   of each walkable material, each keeping a trace of what it was.

Two-stage transition: blight 90→150 stipples via shader, ≥150 the baked tile takes over and the
shader discards. `blight_changed` now fires on the threshold crossing in **both** directions.

The menu was reusing this shader with no `blight_tex` bound; split into `menu_backdrop.gdshader`.

---

## Phase 3 — localization scaffolding — done

`content/locale/embergard.csv` holds ~190 keys, parsed at runtime by the **`Locale` autoload**
(first in the autoload order, since everything below it may translate while starting up).

**Not** using Godot's `csv_translation` importer. That needs a generated `.import` and an editor
pass to produce its `.translation` binaries, so the game could not be built or headlessly tested
from a clean checkout until someone had opened the project once. Parsing the CSV ourselves removes
that step: the file in version control is the source of truth, and the smoke test exercises exactly
what ships.

### Conventions
- **Explicit UPPER_SNAKE keys, never English source text.** A missing entry renders as
  `MISSING_KEY_NAME` — loud, obvious, greppable. English-as-key fails silently and hands
  translators whole sentences as identifiers.
- **`{0}` placeholders via `String.format`, never `%s`.** Positional `%s` cannot be reordered and
  word order changes between languages.
- **Separate singular and plural KEYS** rather than splicing an `"s"` onto a count. Plural rules
  differ wildly and an English suffix baked into a format string cannot be translated away.
- `tr()` for bare strings, `Locale.t(key, args)` when there are arguments.
- Content `.tres` files hold keys in `display_name` / `description`; the display site calls `tr()`.

### Adding a language
Add a column to the CSV. No code changes.

### What is covered
Notices, the HUD (clock, resource bar, growth blocker, migrant prompt, selection card), the main
menu, world creation, options, credits, the summary card, the site picker, placement verdicts,
`BuildingDef.cost_text()`, and `Villager.describe()`. Scene `text` properties that are overwritten
on first refresh were left as placeholders; the wordmark `EMBERGARD` is deliberately untranslated.

`_check_locale` asserts every key a content file names exists **and** translates to something other
than itself — which is what makes a typo in a `.tres` a test failure rather than a screenshot.

---

## Phase 2 — colony depth — done

### Landed so far

- **2.1 Production chain.** `JobDef.cycle_cost` is the whole mechanism. Sawing (3 wood → 1 board),
  stonecutting (3 stone → 1 cut stone), toolmaking (1 board + 1 cut stone → 1 tool). Inputs are
  taken on cycle COMPLETION, not start — otherwise an interrupted worker silently destroys
  materials. A workplace with no input idles instead of banking unearned progress. `Colony.KINDS`
  is 3 → 6 with `KIND_GROUPS` for the readout. The **Watchtower now costs 2 tools**, so the chain
  gates something.
- **Rectangular footprints.** Sawmill 3×2, Stonecutter 2×3, Toolsmith 3×2, with matching 48×32 /
  32×48 art. Everything used to be 2×2, which made layout tiling rather than a puzzle — a 3×2 shed
  does not fit the gap a 2×3 yard leaves. The baker now takes explicit `w`/`h`; it assumed square
  and would have truncated all three.
- **2.3 Warrior job** (`JobDef.defends`). The real fix for the remaining dead air: warriors hold
  the line, **everyone else keeps working if the ground they stand on is lit**
  (`NIGHT_WORK_LIGHT = 110`, below the Ember's own strength so a watchtower is enough). That makes
  Ember placement an economic decision after dark, not only a defensive one. Warriors walk toward
  *threatened villagers* rather than to a light post — the only way a colony spread over several
  work sites can be defended.
- **2.6 Monster roster** 2 → 6. Brute (night 4, wall-breaker), Swarmling (3, cheap and numerous),
  Burrower (5, `tunnels`), Shade (6, `burn_per_second = 0` so light cannot touch it).
  `tunnels` is implemented as "does not read the flow field" — it walks a straight line at the
  nearest structure. A second wall-free field would fork the thing that makes a hundred monsters
  affordable, and a tunneller has no use for pathfinding anyway.
- **2.2 Tabs, upgrades, demolition.** `BuildingDef.category` drives a tab strip *derived from the
  content* — `Buildings.categories()` reads whatever categories exist and orders them by the lowest
  `order` in each, so adding a tab is adding a `.tres` and a locale key. Upgrading is **in place**,
  reusing the blueprint→deliver→build path exactly as `Building`'s header says that path exists to
  be re-entered; footprints must match, so the ground never needs re-validating mid-upgrade.
  Demolition needed **no new villager state**: `add_work` in reverse, then salvage carried off one
  armful at a time via `_begin_haul`. Refund is 40% of `delivered` (never `def.cost`, or a
  force-completed building could be farmed), and a *blueprint* refunds in full — changing your mind
  before work starts should cost nothing, and after it should cost 60%.
- **2.2 Village Center tiers.** Hearth → Great Hall (pop 10) → Stone Keep (pop 18), gating the
  build list through `BuildingDef.tier` against `Colony.center_tier()`. One dial, read off whichever
  standing building declares the highest `center_tier` rather than by id — which also fixed a latent
  bug: `Run._on_building_destroyed` tested `id == &"hearth"`, so upgrading would have silently
  disabled the defeat condition on the only building that matters.
- **2.4 Paths.** A road is a **building**, not a new placement system, so it inherits cost,
  reservation, hauling, demolition, the ghost and the influence check. `path_tier` overrides terrain
  cost in `rebuild_move_cost`, so a paved route across marsh is as quick as one across grass — which
  is the reason to pave the marsh. Villagers prefer roads in exact proportion to the saving, with no
  AI code. `Agent._surface_speed` makes them genuinely faster (sampled once per tile, not per
  frame); monsters override it to keep **half** the bonus and pay `PATH_PENALTY` in the flow field,
  so roads still funnel the horde — which is good, a predictable approach is one you can tower — but
  favour you on net.
- **2.5 Sphere of influence.** An `influence` byte layer, contributions **summed with saturation**
  rather than maxed: that is what makes the boundary amorphous and bulge toward wherever you have
  been building, instead of being a union of circles. Full rebuild on completion and destruction —
  additive stamping cannot be un-stamped without the classic drifting-accumulator bug, and there are
  only ever a few dozen buildings. Gated in `check_placement` per cell, so the ghost red-Xes exactly
  the tiles that overhang. Rendered by copying BlightField's R8-texture + shader trick, and shown
  **only during placement**: it is a placement aid, not six hours of decoration.
- **2.8 Temple, Burden, Tomes.** Shrine → Temple → Sanctum (2×3, upgraded in place). Every ability
  taken up charges a permanent `PowerDef.burden` against the Faith rate, so the managed resource is
  the **rate** and the pool reframes as a buffer — `Divine.faith_runway()` reports how long until the
  powers go dark. Faith clamps at zero rather than going negative: a colony that overreaches loses
  its miracles, which is legible, instead of accruing an invisible debt. Relinquishing costs 12
  Faith — required, or one greedy unlock is permanent regret. Priests are a workplace job
  (`JobDef.scribes`) reusing `_tick_workplace` untouched, and the *skip-the-haul* branch it needed is
  the same one any future non-haulable output will use. `PowerDef.Kind.BUFF` is three independent
  numbers (mood / speed / damage), so Rally and Blessing are one code path with different content.
- **Per-job default quotas** (`JobDef.default_quota`). The old rule — two for every job without a
  workplace — was fine at four jobs and wrong at ten: it asked for ten people out of six, opening
  every board row amber and inflating the unmet work that draws migrants. Defaults now sum to
  exactly the starting population.

### The last four items

- **2.7 Meta unlocks.** 1 → **11 unlockables, 1255 shards**, which at 40–70 shards a run is 18–31
  runs of progression instead of one. New `Unlocks` puts buildings and powers behind one interface,
  because the summary card offered `Buildings.locked()` and nothing else — the moment powers gained
  a price there were two unlock systems and the player could buy a Watchtower but never a Dawnbreak.
  `Meta.ascension` is finally **written**: `threat_dial()` has always read it and nothing ever set
  it, so baseline difficulty could only climb 0.03 per unlock and topped out at 1.03 forever. It now
  counts a run banked deliberately and taken past day 5 — not a death (losing is already a payout
  and should not also be progress) and not a day-2 exit (or the optimal play is to ascend
  immediately and repeatedly).
  - **What is locked is breadth, never the spine.** The whole production chain up to a Great Hall is
    free, so run 1 can still work it. My first pass locked the **Gate**, which was wrong and I
    reverted it: palisade is free from run 1, so a gate-less player walls their own woodcutters away
    from the trees. An unlock that makes the game worse until you buy it is not content. Two upgrade
    tiers took its place, which also needed `Colony.upgrade_check` to honour shard locks — otherwise
    an upgrade could be sold and then gate nothing.
- **2.9 Blight settlements.** The Blight now spends its nights building: Hovels (night 2, cheap,
  more bodies), Spires (4, seed corruption into the ground), Totems (6, empower the horde and glow
  while doing it). Implemented as **nests with different art and effects** — a Dictionary of
  cell → hp, exactly like `nest_hp` — which is why they inherit tower targeting, Wrath, Ward,
  Consecrate, occupancy and save/load with no new integration. Grown at **dawn**, so it is something
  the player wakes up to rather than something that creeps while they watch a wall, and never inside
  the player's sphere, so encroachment is always something you can go out and meet.
- **Smaller grid: 128 → 112, and 96 was tried and rejected.** Two numbers fight. The island falloff
  puts the coastline at ~0.62 of the half-width; `NEST_MIN_DIST` is not a layout figure at all but
  the horde's **approach time**, which is the player's entire warning. At 96 the nest ring lands in
  open water, the fallback bunches every nest onto one position, and the colony is wiped — all-green
  to nine failures with the whole population dead. Scaling the ring down proportionally instead
  halved the approach time and overran the colony a different way. Going below 112 needs the falloff
  widened, not a constant retuned; recorded as a Phase 6 item.
- **Resource masses.** Two states — **interior and edge** — rather than the sixteen a full
  neighbour-mask autotile needs: 3 new tiles instead of 48. A cell whose four neighbours share its
  feature gets a full-bleed, outline-free tile that merges with them; everything else keeps its
  outlined silhouette, which becomes the mass's ragged rim. It maintains itself — felling a tree
  repaints its four neighbours, so the hole is edged for free, which is exactly "gets eaten into".
  Clump generation had to change too: the old flat 55% fill was the worst possible number, too dense
  to read as scattered and far too sparse for any cell to have four wooded neighbours, so the dense
  tile would essentially never have appeared. Now a near-solid core with a thin fringe, giving
  120–170 interior cells per map.

### From device feedback

- **The Job Board hides jobs it cannot staff.** `Jobs.available()` — a workplace job with nowhere to
  work is not a choice, it is noise: the board opened with ten rows, six of which needed a building
  that did not exist. Worse than cosmetic, because a quota on an unstaffable job sent villagers
  looking for a workplace they would never find and they fell through to `_wander()` while there were
  trees to fell, *and* it inflated `Colony.work_slots_free()`, which is one of the things that draws
  migrants. `rebalance()` now frees anyone holding such a job, and the board grows with the
  settlement — raise a sawmill and the Sawyer row appears. The quota itself is skipped, not zeroed, so
  the player's setting survives losing the building and returns with it.
- **The Job Board scrolls.** Rows are 26px and there are ten of them; on a 360-tall screen the board
  covered the game. A 132px vertical `ScrollContainer` shows five. Horizontal scrolling is disabled —
  on a touch panel it steals the drag from the sliders, which are the entire control surface.
- **Rebuilt only when the visible set changes**, guarded by a signature like the ability buttons: this
  now runs on every building completion, and a slider destroyed and recreated under a thumb is a
  slider that drops the drag.

### Bugs the first real test run caught

Worth recording, because every one of them was invisible to inspection and three were latent long
before Phase 2:

- **The sphere of influence blocked the founding Hearth.** Influence is granted *by* standing
  buildings, so gating the first one on it meant the Village Center could never be placed, the run
  silently fell back to a bare stockpile, and every later placement failed too. Fixed by
  `World.has_influence()`: a colony with no sphere may build anywhere. Stated as "is there a sphere
  yet" rather than "is this the Hearth", so it also covers a colony type that founds itself with
  something else.
- **Cleared ground stayed impassable.** `clear_feature` sets `cost_dirty` and defers the rebuild to
  the next `World.step`, so straight after burning out a nest `is_walkable()` still reported solid
  rock — villagers could not path onto ground the player had just taken. Pre-existing, and it would
  have read as "clearing nests does nothing". `damage_nest` now rebuilds immediately; nests die a
  handful of times a run.
- **`Run._on_building_destroyed` tested `id == &"hearth"`.** Upgrading in place changes the
  definition, so raising the Hearth into a Great Hall would have silently disabled the defeat
  condition on the only building that matters. Now tests `center_tier`. Exactly the failure mode
  `BuildingDef`'s header warns about.
- **A flaky assertion, not a bug.** The migration test set `migration_progress = 0.999` assuming a
  target of 1.0, but each birth needs a *randomised* 0.75–1.35 so growth never lands on a countable
  beat. It passed on seeds that rolled low and failed on ones that rolled high. The game was right.
- **Three carry icons were missing** for boards, cut stone and tools. The baker warned; a blank
  frame makes a haul of boards look identical to a villager carrying nothing.

### Decisions that differ from the original spec, and why

- **Baseline powers are taken up automatically at run start.** The spec gated Emberfall and Ward
  behind a Shrine. That would have put the game's signature mechanic behind a 20-stone building and
  ten survivors, gutting the opening rather than deepening it. The three tier-0 powers carry 0.24/s
  between them against a passive ~0.6/s, and they can still be given back. The interesting decision
  is not whether to have Emberfall; it is whether a Sanctum's worth of abilities is something the
  colony can carry — and that starts at tier 1.
- **Combining and installing Tomes are automated.** The spec had the player queue combines and
  choose which books to install. Both needed a library-management panel; instead priests combine the
  three *least durable* shelved tomes of the lowest eligible tier (the choice a player makes almost
  every time), and the best books are auto-shelved into the available slots. Averaged toughness on
  combine is preserved, so feeding it junk still yields a fragile result. What stays in the player's
  hands is how many priests to staff and — through the tier — how large the active set is. **This is
  the one place Phase 2 has less player agency than specified**; a panel is the obvious later
  addition if the mechanic proves worth it.
- **`influence_radius` in tiles, not `influence_weight`.** The thing a designer wants to tune is
  "how far does a watchtower reach", stated in tiles, not a weight against one global constant.
- **`BuildingDef.workplace_role`.** Added because a Priest works at a Shrine, a Temple *or* a
  Sanctum, and a job naming one building id would have silently stopped working the moment the
  player upgraded the building it was written for.
- **No Granary.** Storage caps do not exist, so a Granary would have been a building that does
  nothing. Housing got the Longhouse instead.

### Still to do

Nothing. Phase 2 is complete. Two items were deliberately deferred rather than dropped:

- **A Tome library panel.** Combining and installing are automated (see the deviations below). If the
  mechanic proves worth more player agency, this is the addition.
- **A map smaller than 112.** Needs `MapGen._fill_terrain`'s island falloff widened so the land
  radius stops fighting the nest ring. A Phase 6 job, not a constant to retune.

Largest phase. **All of it lands before Phase 4**, because the Realm's `ColonyLedger` must
serialize the finished colony state — building the abstractor twice is waste.

### Original per-item specification

Everything below is the spec Phase 2 was built from, kept for reference. It is **not** a
to-do list — see "The last four items" and "Decisions that differ from the original spec"
above for what actually shipped and where it diverged.

### 2.1 Production chain
`JobDef` has `cycle_yield` but no inputs. **Add `cycle_cost: Dictionary`** — one field turns the
whole chain into content.

```
RAW          →  TOOLS GATE   →  PROCESSED      →  METAL          →  MILITARY
wood            Toolsmith       Sawmill           Ore node          Blacksmith
stone           wood+stone      wood → boards     Furnace           ingots+boards
food             → tools        Stonecutter       ore+wood → ingots  → weapons
water                           stone → cut stone
```

Tools are a **consumable construction input** for tier-2+ buildings. Upgrades accept **either 3×
raw or 1× processed**, so skipping the Sawmill slows you but never hard-blocks you.

Resource kinds go 4 → ~11. The 1.6 readout was built for an arbitrary list, so this adds rows plus
grouping (Raw / Processed / Military). Storage caps become necessary (Granary / Warehouse).

### 2.2 Upgrades, tiers, tabs, demolition
Gate everything behind a tiered **Village Center** (Hearth T1→T3), each tier needing a population
threshold *and* processed materials. One legible dial.

New `BuildingDef` fields: `category` (tab), `tier`, `upgrades_from`, `influence_weight`,
`path_tier`.

Upgrade **in place**, reusing the existing blueprint→complete path.

**Demolition:** refund a fraction of **`Building.delivered`** — never of `def.cost`, or a
force-completed building can be farmed. ~40%, difficulty-tunable; salvage is the wrong place to be
generous. Salvage must be **carried**, not teleported. Buildings left outside a shrunken sphere are
**grandfathered**.

### 2.3 Jobs
`JobDef` already supports everything needed, so most are content.

| Job | Behaviour |
|---|---|
| **Worker** | Idle unless something needs building. Formalizes the implicit builder role. |
| **Warrior** | Defends threatened villagers; fights at night while others keep working. **This is the real fix for 1.4's dead air.** |
| **Priest** | Workplace job at the Temple; scribes and combines Tomes. |
| Toolsmith / Sawyer / Stonecutter / Smelter / Blacksmith | Workplace jobs, pure content once `cycle_cost` exists. |
| **Miner** | Harvests the new ore feature. |
| **Hunter** | Renewable food away from the keep; risky. |

Only the Warrior needs new `State` values. Everything else reuses `_tick_workplace`.

### 2.4 Paths
`rebuild_move_cost()` already derives one cost array that villagers A* over, so **a path is just a
tile that lowers cost** — villagers prefer it proportionally to the saving, which is exactly "prefer
but don't detour." **No AI code.** Tiers are a `path_tier` byte layer.

Two things do need code: `Agent._process` uses a flat `move_speed` and never reads cost; and
**monsters read the same array, so roads are invasion highways.** Keep that — it makes gate placement
matter — but add a modest monster-side penalty so roads favour the player on net.

### 2.5 Sphere of influence
A `PackedByteArray influence` layer. The Village Center stamps a large radius by tier; each building
stamps a small one weighted by `influence_weight`. Radial falloff summed across sources produces an
amorphous blob that **bulges toward wherever you build**, with no special-case geometry.

Two clean reuses: gate placement in `Colony.check_placement()` (already returns per-cell verdicts,
so the ghost red-Xes out-of-influence tiles for free), and render via `blight_field`'s proven
R8-image-plus-shader pattern.

### 2.6 Monster variety
Art **done** for Brute, Shade, Swarmling, Burrower. Still needed: `MonsterDef` .tres files, a night
boss every 5th night, and visually distinct **empowered** variants (`_apply_overflow` caps at 2.5×
and silently discards excess budget, while a 2.5×-HP shambler looks identical to a night-1 one).

### 2.7 Meta unlocks
One building has `unlock_cost > 0`. A run earns ~30-50 shards, so after **one run** the summary says
"Everything is unlocked" forever and `threat_dial()` tops out at 1.03. `Meta.ascension` is read and
**never written**. Need 12-20 unlockables at 30-400 shards.

### 2.8 The Temple — Divine progression
`PowerDef` has **no unlock field at all**, so the signature system has zero progression.

**Faith stays passive. Every unlocked ability applies a permanent negative rate — its Burden.**

```
net Faith rate = passive generation + Tome bonuses − total Burden
```

The managed resource becomes the **rate**, not the pool; the pool reframes as a buffer. It
self-limits without an arbitrary cap, and it **brakes the death spiral** — a declining colony can no
longer afford its abilities. Unlocking everything becomes a trap.

**Relinquishing is required**, or one greedy unlock is permanent regret. Going net-negative must be
loud: `faith 64/150 ▼−0.31/s · 3m 30s`.

**Priests scribe Tomes** at the Temple. Tier is random; higher-tier odds rise with priest count.
**3× same tier → 1× next**, inheriting the **average** toughness of its inputs — so combining is a
real choice. Tomes have durability; **only installed ones decay**.

The resulting economy: obligations permanent, income perishable, priests the standing cost of
keeping it alive. A Temple can never be "finished."

> **Balance risk:** permanent Burden against perishable income is a **ratchet**. Tune so a modest
> standing priest assignment sustains a modest Burden indefinitely. Smoke test must assert a
> baseline Temple staff holds a stable net rate across 10 days.

Tiers: Shrine (1 priest / 1 Tome slot / cap 100) → Temple (3/2/150) → Sanctum (5/3/220). Eight
powers across three tiers; needs one new `Kind.BUFF` appended to the enum.

### 2.9 Blight settlements (new — not in the original plan)
Nests should **grow into villages** rather than being spawn markers. Art done: `spire` (16×32),
`hovel` (16×16), `totem` (16×24) in `assets/sprites/blight/`.

Behaviour outstanding: nests periodically raise structures nearby; structures raise local threat,
speed blight spread, or house extra spawns; each is destructible. Turns a nest from a spawn point
into an objective, and pairs with the now-slower corruption — a days-long siege gives them time to
build.

### 2.10 More buildings
**Gate** ✅ done. Still needed: Well ✅ done; **Granary** (spoilage + storage caps), **Barracks**,
**Stone Wall**, **Ballista**, **Shrine/Temple/Sanctum**, **Bridge** (water is a hard wall today;
`terrain.gd` already says "bridges later").

---

## Phase 4 — The Realm ✅ complete

**Reworked on 2026-07-30.** The Realm is now one seeded continuous landscape backed by a
**12×8 set of 96 selectable regions**. The divisions are deliberately invisible in the overview:
the player clicks directly on the landscape, the camera zooms into that exact region's detailed
112×112 preview, and only the explicit **Begin settlement here** confirmation creates and opens its
gameplay map. Back returns to the clean world view without mutating an unsettled region. Later
colonies occupy adjacent regions on the same world. This replaces the rejected seven-node
constellation and the visible checkerboard prototype.

The macro landscape and every region are pure functions of the world seed. Several overlapping
land masses, carved gulfs and satellite islands replace the old radial oval. Coastlines, forests,
highlands, marshes, badlands and tundra use heavy pixel-art outer outlines, light inner rims,
nested formation contours, seeded surface variation and water-wave detail. The generated provinces
are intentionally irregular and pronounced instead of being circular colour patches.
Connected dark-canopy and grey-quarry formations are then projected over that terrain from the
same continuous forest and stone richness used by local generation. Berry-rich ground receives
occasional tiny shrub-and-fruit clusters rather than full-tile fills. The overview therefore
communicates what a selected local map favors without exposing its hidden region boundaries.

Broad corruption is **not drawn on the world map**, and the hidden Blight Heart is not advertised
before discovery. Each seed distributes several latent corruption sources across different
regions. An unsettled region's latent risk remains stationary and its preview is generated without
creating or simulating a colony. Once settled, the local 112×112 map receives several small,
separated corruption pockets; only that colony's stored local field advances. Existing settlement
markers may show a restrained local warning arc, never a global purple wash.

**Gated on Phases 1 and 2.** Autoloads stay singletons and hold whichever colony is **awake**.

| New | Kind | Responsibility |
|---|---|---|
| `Realm` | autoload | Seeded macro landscape, region grid, colony ledgers, spatial wards |
| `ColonyLedger` | RefCounted | Abstract state of one colony, including production chain |
| `Abstractor` | static | Live colony → ledger, on departure |
| `Reconstitutor` | static | Ledger → live colony, on arrival |

All four are implemented in `scripts/realm/`. Every ledger owns its own stock, reserved goods,
quotas, Faith, roster, buildings, harvested feature field, blight field and enemy settlement.
`Abstractor` captures that exact state before departure; `Reconstitutor` rebuilds derived grids and
nodes from it on arrival.

### Regional expansion and containment

Travel, founding, resource shipments and settlers cross shared region edges. A founding caravan
subtracts its resources and exact villager rows from the awake colony before the new ledger exists.
There is no global stockpile: visiting Willow Thicket can show 10 wood while the First Hearth still
has 80, because those are different colonies.

Every living colony wards nearby regions. Population, completed Hearth tiers and defensive
buildings expand that spatial protection. The Realm map draws settled routes and clean colony
markers without restoring the hidden selection grid or revealing the Heart. The final assault
unlocks only after at least four colonies collectively ward every land region touching the Heart.

Threat interception still begins with a real local spawn cell. Its direction from the First Hearth
is projected across the macro world; a developed colony in that direction absorbs pressure into its
own ledger. A permanent 18% baseline still reaches home, so expansion reduces danger without
turning the first colony off.

### Abstracted colonies that feel simulated
Not simulated — stored as a ledger and **deterministically reconstituted**, seeded from
`colony_seed + days_elapsed`. Needs and jobs are derived from the ledger, so a colony that was
starving greets you with hungry villagers. O(1) per colony per day.

**Blight is the exception — advance it for real.** It is the pressure, and pressure must be honest.

Sleeping days are seeded independently from colony seed + day. Gatherers remove finite trees,
rocks and berry patches from the stored feature field; workshops consume declared inputs; hunger
changes the stored villagers; intercepted pressure damages their ward; and a bounded real blight
advance mutates the stored byte field. Returning therefore shows the same stock, needs, cleared
ground and corruption the summary described.

> **Three invariants.** (1) The ledger is the single source of truth; reconstitution must never
> contradict the summary the player was shown. (2) No resources from nothing. (3) Neglect is a
> choice, never an ambush — local corruption bars warn continuously and counterplay exists.

### Also
Save schema 4 stores the world seed, difficulty, selected regions and N independent ledgers. Schema
2 single-map saves and schema 3 constellation saves migrate onto deterministic reachable regions
instead of being discarded. Three resource-and-Faith strikes destroy the contained Blight Heart;
only the final strike records `Meta.ascension`.

Local generation accepts the selected region profile. Forest regions produce denser connected
woods, highlands favor stone, wetter regions favor food and dangerous regions begin with more
Blight. A modest guaranteed quarry prevents resource-poor starts from becoming soft locks while
preserving the much larger differences between biomes.

---

## Phase 5 — polish ✅ complete

**Completed on 2026-07-30.** Phase 5 turns the finished simulation into a game that explains
itself, sounds intentional, supports different players and remembers the worlds they made.

### 5.1 Audio content

- Twelve deterministic one-shots are authored by `audio_data.gd`, baked to ordinary 22.05 kHz
  PCM WAV files by `bake_audio.gd`, imported, and registered at startup: distinct UI press/back,
  construction start/finish, resource delivery, miracle, alarm, wave, monster/villager death,
  Tome and dawn cues. A throttled resource cue prevents busy colonies becoming noise.
- `AudioStreamGenerator` produces an infinite low-cost score with a root/fifth drone and sparse
  modal melody. It moves from Dorian by day into Aeolian at night, blends through dusk/dawn, uses
  a 0.55 second buffer and pushes frames without per-sample allocations.
- Master, Music, Sound and Interface buses have separate live-preview controls. Button sounds are
  connected centrally, so runtime-created controls cannot silently miss audio.

### 5.2 Contextual onboarding

- Nine event-driven Field Guide cards teach the Realm, Ember, Job Board, placement, dusk, Burden,
  production, separate colonies and local Blight when each system first becomes relevant.
- Cards pause safely, queue instead of overlapping, are shown once, can be skipped permanently,
  and can be reset from Accessibility. Headless automation bypasses presentation without bypassing
  the underlying systems.

### 5.3 Accessibility and controls

- Options is now a fitted three-tab surface: Audio, Access and Controls.
- Original, red/green-safe, blue/yellow-safe and high-contrast full-screen palettes preserve the
  important Blight/fire/monster/influence distinctions. Text has four deliberate scale steps,
  including scene-authored overrides. Reduced motion covers menu, summary, Realm and camera
  transitions; haptics are optional and mobile-only.
- Pause, speed, Jobs, Build, Realm and Cancel actions are fully remappable and persisted. Settings,
  audio, tutorials and Meta now load-merge the shared profile file; earning shards can no longer
  erase preferences.

### 5.4 Desktop parity

- Mouse wheel zoom remains cursor-anchored. Right-click and Escape cancel placement, armed powers
  and selections. Remappable hotkeys open every major HUD surface.
- Palisades, paths and roads opt into `BuildingDef.drag_placeable`; a mouse drag paints a
  deterministic line, validates and pays for every cell, and stops cleanly when resources run out.
  Other buildings remain one-click deliberate placements. Build and power cards retain hover help.

### 5.5 Chronicle, seed sharing and achievements

- The profile schema now retains the latest 24 runs with seed, difficulty, outcome, day,
  population, colony count, buildings, nests, kills, losses and payout, plus lifetime totals.
- Chronicle cards and the run summary copy the exact world seed to the clipboard.
- Six persistent achievements cover first night, construction, nest clearing, ten-day survival,
  a four-colony network and Realm completion. Newly earned achievements appear on the payout card.

---

## Phase 6 — long tail

- **Biome depth.** Macro biomes and local resource bias shipped with Phase 4. Still vary local
  `NEST_COUNT`, nest distance, water topology, weather and unique regional hazards by biome tier.
- **Storyteller events.** `Events.storyteller_event` is declared and **never emitted**. Caravans,
  refugee bands, blight surges, storms that dim light, droughts that dry wells.
- **Weather / seasons** affecting light, yield and spread.

---

## Verification

Extend the existing harness; do not replace it. `smoke_test.gd` runs 4 seeds
(`1, 7, 424242, 99999`), 600 sim-seconds at a fixed 0.05 step, ~125 assertions.
`stress_test.gd` covers performance; `screenshot.gd` covers visuals.

`realm_test.gd` adds the Phase 4 conservation and world suite: gridless first-region selection,
zoom-before-confirmation, stationary unsettled corruption, multiple local corruption pockets,
deterministic macro generation, different seeds, reachability across varied seeds, region-derived
local maps, separate stockpiles across repeated travel, founding deductions, equal transfer
debits/credits, deterministic sleeping outcomes, N-ledger save/load, spatial containment,
directional interception with the Heart baseline, three-stage victory, and ascension. A real
renderer captures `artifacts/phase4_world_select.png`, `artifacts/phase4_region_preview.png`, and
`artifacts/phase4_realm_map.png` at 1600×720 for layout and art QA. The iOS export pack is audited
with dev, build and artifact folders excluded.

Phase 5 extends the smoke suite with the twelve imported sound cues, live procedural generator,
four palette modes, text-scale steps, remappable desktop actions, drag-placeable content,
onboarding availability and Chronicle retention. A real renderer captures every title-screen
state, all three fixed settings tabs, the red/green-safe shader, the first Field Guide card and the
run summary at 1600×720. The final focused Realm suite and four-seed smoke suite pass, and the
4,215,100-byte iOS pack audit verifies all 411 translations, twelve audio cues and every runtime
content catalog.

### Manual checks that automation cannot cover
- **Sphere geometry:** Watchtower east, Stockpile west — the boundary should bulge strongly east
  and barely west.
- **Spatial shielding:** develop a colony east of the First Hearth; eastern pressure should shift
  into that colony while the opposite direction and baseline still reach home.
- **Gates under load:** wall a village completely with one gate; monsters should funnel to it and
  villagers should not be stuck inside.
- **Corruption read:** blighted ground should look like ground, and the frontier should stipple
  before tiles flip.

---

## Reference
- [World Map — Rise to Ruins Wiki](https://rise-to-ruins.fandom.com/wiki/World_Map)
- [Corruption Threat — Rise to Ruins Wiki](https://rise-to-ruins.fandom.com/wiki/Global_Corruption_Power)
- [InDev 31 – The World Update](https://rayvolution.itch.io/risetoruins/devlog/48767/indev-31-the-world-update-released)
- [Is this game just too hard? — Steam](https://steamcommunity.com/app/328080/discussions/0/353915953249211160)
