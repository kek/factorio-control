# Bounded factory expansion effects

Target: Factorio 2.1.24, factorio-control 0.2.6. Contracts are defined by
`FactorioControl.Eyg.contracts/0` and `FactorioControl.Eyg.Expansion.contracts/0`.
Gameplay still goes exclusively through EYG; no arbitrary Lua or item/research
grants are exposed. Validate the headless server and typed interface, not the
graphical client's installation or connectivity.

## Observation

| Effect | Arguments | Observations |
|---|---|---|
| `InspectArea` | `{position:{x2,y2},radius}` | Generated terrain tiles (`x,y` are integer tile indices), water flags, up to 100 non-resource entities with force/health, entity `truncated` and `tiles_complete`. Radius 1–8, center within 64 tiles of the bot. Does not generate chunks. |
| `InspectWater` | `{radius}` | Up to 200 generated water-collision tiles within 1–64 tiles of the bot, plus truncation. A truncated result does not identify the globally nearest shore. |
| `InspectTechnology` | `{name}` | Enabled/researched state, prerequisites, science ingredients/cost, current progress and normal craft/mining trigger requirements. |
| `InspectMachine` | `{name,position}` | Health, status, recipe, energy/network, separate input/output/fuel/ammo/storage inventories and fluid amounts/temperatures. Friendly inventories only; known position within 64 tiles of the bot. |

Input positions use integer half tiles. Entity observations use thousandths;
fluids, temperature, research progress and health also use integer thousandths.
`energy_joules` is a rounded integer. Existing inspection contracts remain intact.
Summarize large observations in the EYG result: a final result has a 12 KB budget,
separate from protocol frame and per-query bounds. Full effect receipts remain
in the trace. Missing/truncated observations must not be interpreted as empty land.

## Construction and configuration

`Build` now has a finite allowlist of starter drills, furnaces/chests, belts,
splitters/undergrounds, inserters, small poles, assembler-1, pipes, pump, boiler,
steam engine, lab, gun turret and stone wall. See `control.lua` for exact names.
Normal inventory, reach, placement/collision rules and quality restrictions still
apply. X and Y grid parity are checked independently after rotating rectangular
footprints. Blocked placements consume nothing; a failed item removal rolls the
new entity back. Count-only placement/transfers reject damaged building stacks,
so mining and rebuilding cannot silently repair them.

| Effect | Arguments | Restrictions |
|---|---|---|
| `BuildUnderground` | `{position,direction,end_type}` | Explicit `input`/`output` endpoint, normal underground-belt item and placement rules. |
| `ConnectPower` | `{from,to}` | Two reachable friendly small poles, normal copper wire reach, player wire origin; existing connection is a no-op. Never overrides wire reach. |
| `SetRecipe` | `{name,position,recipe}` | Reachable friendly assembler-1, unlocked supported item recipe/category. Changing recipes requires empty input/output/trash/dump/module inventories, no active craft/productivity progress, no recipe lock and no fluid-capable variant. Same recipe is a no-op. |
| `SetChestLimit` | `{name,position,slots}` | Reachable friendly chest, inventory bar supported, 1–48 slots and within actual inventory size. Hides excess slots from automation without deleting contents. |

The mod uses `create_entity`, not every player placement event/undo behavior.
Check real pickup/drop targets, fluids, network connections and output growth.
Blueprint ghosts, arbitrary prototypes, higher qualities and general logistics
configuration are not supported by these effects.

## Research and normal crafting

`Research({name})` starts ordinary science-consuming force research. It rejects
locked/completed technologies, unmet prerequisites, triggered research, and a
different active research. It does not complete technology or create science.
Triggered technologies must be earned through the named normal game activity.

`Craft` retains mod-owned timed batches. `HandCraft({recipe,count,timeout_ticks})`
uses the standalone character's engine crafting queue when normal crafting
progression matters. Both require directly available normal-quality ingredients,
explicit intermediate crafts, a supported guaranteed item output and capacity.
No recursive crafting, fluid ingredients or probabilistic outputs are used.

Standalone character queues do not report force production like player queues.
`HandCraft` snapshots production statistics before submission and backfills only
missing output/consumption for completed output actually observed in inventory.
It does not double-count quantities already reported by the engine, report
unfinished batches, set a technology flag, or insert another item. The live lab
craft then unlocked red science via the normal craft-item requirement. Cancellation
cancels remaining owned batches at the queue head, preserving later foreign work.

The only additional consumable prototypes allowed are full base
`firearm-magazine` and `automation-science-pack`. Factorio 2.1 can represent a
pristine full consumable as a simple stack: check `is_ammo`/`is_tool` before
reading metadata accessors, which otherwise throw. Used ammo/science is not taken
from turret/lab inventories, and partially consumed source stacks are rejected.

`Transfer` additionally supports assembler/lab `input` and turret `ammo`. Existing
selectors retain their meaning. No count-only transfer refreshes a magazine,
science pack or damaged building's metadata.

## Actor recovery and removal

`MineObject({name,position,timeout_ticks})` performs normal character mining of a
minable neutral tree/rock or friendly allowlisted infrastructure. It uses the
existing asynchronous action/deadline/stop lifecycle. No instant destruction,
teleport or item grant is performed. Inventory and partial results must be
inspected after interruption; the terminal count describes a removed object,
not a guaranteed material yield. Walking remains straight-line steering without
general pathfinding: survey, use clear waypoints, or mine an observed neutral
obstacle normally instead of repeating a blocked walk.

`SpawnBot({position})` explicitly creates an empty character if the old actor is
absent, or returns the living existing bot without granting items. An unowned
NPC character corpse can be inspected with `InspectEntity` and looted using
`Transfer` / `main`; corpses associated with an existing player are excluded. A unique 0.4-tile lookup
handles non-grid-aligned corpses with half-tile input. Recover actual surviving
items, never replay completed crafting or replace lost inventory through grants.

All accepted asynchronous submissions retain game and terminal receipts; unknown
acceptance remains fatal and triggers only the existing best-effort stop. No
mutation is automatically retried. All per-action and wait tick limits remain
1–3600, craft batches 1–100, and the per-run effect budget is still 100.

## Verification

```sh
lua test/lua/crafting_test.lua
lua test/lua/expansion_test.lua
lua test/lua/infrastructure_test.lua
mix test
```

Lua tests use isolated mocks; Elixir tests use fake calls and the real portable
evaluator. They do not grant fixtures in the playing world. Live construction
and verification used the headless server through typed EYG, with exclusive
traces and original program sources retained under ignored `tmp/expansion/`.
