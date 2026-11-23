# Bounded factory expansion effects

Target: Factorio 2.1.25, factorio-control 0.3.0. Contracts are defined by
`FactorioControl.Eyg.contracts/0` and `FactorioControl.Eyg.Expansion.contracts/0`.
Gameplay still goes exclusively through EYG; no arbitrary Lua or item/research
grants are exposed. Validate the headless server and typed interface, not the
graphical client's installation or connectivity.

## Observation

| Effect | Arguments | Observations |
|---|---|---|
| `InspectArea` | `{position:{x2,y2},radius}` | Generated terrain tiles (`x,y` are integer tile indices), water flags, up to 100 non-resource entities with force/health, entity `truncated` and `tiles_complete`. Radius 1–8, center within 64 tiles of the bot. Does not generate chunks. |
| `InspectTransport` | `{name,position}` | Read-only inspection of native `transport-belt`, `underground-belt`, or `splitter` entity types at any tier/quality or modded prototype name on the bot's surface, within 64 tiles at a generated position. Returns `{tick,name,x_milli,y_milli,direction,lanes:[{index,items:[{name,quality,count}]}]}`. Direction is the actual integer `defines.direction` value. All real transport lines (1-based indices from `get_max_transport_line_index`, at most 8), including underground and splitter lines, are reported separately, even when empty; item qualities/counts are preserved. Errors propagate, never treated as empty lines. No inventory or entity state is changed. |
| `InspectWater` | `{radius}` | Up to 200 generated water-collision tiles within 1–64 tiles of the bot, plus truncation. A truncated result does not identify the globally nearest shore. |
| `InspectTechnology` | `{name}` | Enabled/researched state, prerequisites, science ingredients/cost, current progress and normal craft/mining trigger requirements. |
| `InspectMachine` | `{name,position}` | Health, status, recipe, energy/network, separate input/output/fuel/ammo/storage/module inventories and fluid amounts/temperatures. All entity qualities accepted, with ambiguity rejection. Friendly inventories only; known generated position within 64 tiles of the bot. |

Input positions use integer half tiles. Entity observations use thousandths;
fluids, temperature, research progress and health also use integer thousandths.
`energy_joules` is a rounded integer. Existing inspection contracts remain intact.
`InspectTransport` uses the official 2.1.24
[`get_max_transport_line_index` / `get_transport_line`](https://lua-api.factorio.com/2.1.24/classes/LuaEntity.html#get_max_transport_line_index)
and [`LuaTransportLine.get_contents`](https://lua-api.factorio.com/2.1.24/classes/LuaTransportLine.html#get_contents)
(array of `ItemWithQualityCount`), bounded to 256 distinct stacks per line.
An unsupported line count or contents bound fails rather than truncating.
Targets use a named point query without a quality filter, capped at two matches:
`find_entity` with a bare name would implicitly select normal quality in 2.1.
Ambiguous targets are rejected instead of arbitrarily selected. Prototype names
must be registered, and actual entity types are checked before transport API
access, so ghosts or unrelated entities cannot masquerade as belts. No name/tier
allowlist is used. `InspectMachine` uses the same all-quality lookup, with its
existing 64-tile/generated-position limits. The core `InspectEntity` uses a
bounded all-quality point query without an interaction-reach limit, retaining
its 0.4-tile corpse fallback and player-owned corpse inventory exclusion.
Visibility rules and mutation target lookup behavior are unchanged.
The request and result shapes are unchanged; item qualities remain in lane records.
Headless deployment and typed EYG probes confirmed 2 belt lines, 4 underground
lines and all 8 splitter lines. It was then used to trace live copper, coal and
ammunition flow; see `scenarios/resupply/`.
Summarize large observations in the EYG result: a final result has a 12 KB budget,
separate from protocol frame and per-query bounds. Full effect receipts remain
in the trace. Missing/truncated observations must not be interpreted as empty land.

## Construction and configuration

`Build` accepts plain `item` prototypes with an entity `place_result`, including
later-tier and modded buildings. Stateful vehicle items, tiles and rail planners
need dedicated placement support.
Normal inventory, reach, placement/collision rules and quality restrictions still
apply. X and Y grid parity are checked independently after rotating rectangular
footprints. Blocked placements consume nothing; a failed item removal rolls the
new entity back. Count-only placement rejects damaged building stacks, so mining
and rebuilding cannot silently repair them. Transfers use native stack movement
and preserve damage.

| Effect | Arguments | Restrictions |
|---|---|---|
| `BuildUnderground` | `{position,direction,end_type}` | Explicit `input`/`output` endpoint, normal underground-belt item and placement rules. |
| `ConnectPower` | `{from,to}` | Two reachable friendly small poles, normal copper wire reach, player wire origin; existing connection is a no-op. Never overrides wire reach. |
| `SetRecipe` | `{name,position,recipe}` | Any reachable friendly `assembling-machine` prototype, unlocked item-only recipe within its crafting categories and ingredient capacity. Changes require empty input/output/trash/dump/module inventories and all fluid stores, no active craft/productivity progress and no recipe lock/fixed recipe. Same recipe is a no-op. |
| `SetChestLimit` | `{name,position,slots}` | Reachable friendly ordinary or logistic chest, inventory bar supported, 1–48 slots and within actual inventory size. Hides excess slots from automation without deleting contents. |

`SetRecipe` uses the machine's native class, crafting categories and ingredient
capacity, not a prototype-name allowlist. This covers later-tier and modded
assemblers, including dry fluid-capable variants. A change scans every native
fluid storage (at most 64), rejecting even fractional residue; no inventory or
fluid is cleared automatically. At most 128 categories and 64 ingredients/products
per list are accepted. Changes explicitly select normal recipe quality, while an
already-selected recipe is left untouched, even if the machine is busy or locked.
Furnace auto-selection, silo-specific state and fluid recipes remain unsupported.
Native ejections or a failed read-back are errors: inspect the machine and trace
before continuing, and never blindly retry a configuration change.

The mod uses `create_entity`, not every player placement event/undo behavior.
Check real pickup/drop targets, fluids, network connections and output growth.
Blueprint deployment, stateful vehicle/tile/rail placement, higher-quality
selection and general logistics configuration remain unsupported.

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

Crafting accepts a guaranteed output of any registered item type. Transfers
move native stacks of all registered item types, including
partially consumed ammo/tools, blueprints, tags and equipment. Metadata is not
reconstructed or serialized. Destination bars and native slot restrictions apply;
a successful receipt may report less than the requested quantity when capacity
runs out. Always check its actual count before dependent work.

Both transfer effects support ordinary/logistic chest `main`, assembler/lab
`input`, turret `ammo`, and native `modules`, alongside existing selectors.
`modules` resolves through `get_module_inventory()` rather than a prototype-name
list. Missing inventories return `invalid_inventory`; only module items are
accepted. Native `can_insert(stack)` checks machine/recipe compatibility before
giving modules. Full or incompatible destinations return `inventory_full` if
nothing moves; partial capacity still reports the actual moved count. Existing
modules are never automatically replaced or upgraded.

`InspectEntity` and `InspectMachine` expose friendly modules separately as
`modules:[{name,quality,count}]`, bounded to 256 distinct stacks and empty when
unsupported. Main logistic storage is exposed as `inventory` by both inspectors.
Enemy item/module inventories remain hidden. `SetChestLimit` supports ordinary
and logistic chests with native inventory bars; no logistic request/filter
configuration is performed. Existing selectors retain their meaning. No count-only transfer refreshes a magazine,
science pack or damaged building's metadata.

`Transfer` retains its normal-quality argument shape. `TransferQuality` adds
required `quality` (an exact registered name of 1–100 bytes), with otherwise
identical position/entity/inventory/direction/item/count arguments and receipt.
It selects only that quality, never falling back to normal or combining qualities.
Inspect inventory quality names before planning a transfer; modded registered
qualities are supported without a hard-coded tier list. Invalid/unknown qualities
are rejected before moving items.

`TransferQuality` needs its own effect grant and dedicated `transfer_quality` mod
method. Old mods return `unknown_method` without moving items. The host requires
the returned quality to match; a missing/mismatched acknowledgement is fatal and
must be inspected, never retried automatically. Building/crafting/recipe-selection
quality support is unchanged. The pending capability-profile design must apply
the same transfer policies to both effects.

## Rotation

`Rotate({name,position,direction})` accepts cardinal absolute headings for friendly,
reachable item-placeable infrastructure with native `supports_direction` and
`rotatable` flags. It calls native [`LuaEntity.rotate`](https://lua-api.factorio.com/2.1.24/classes/LuaEntity.html#rotate),
never directly sets `direction`, and therefore respects collision and linked-end
rules. It uses at most 16 native steps, stopping on rejection or a repeated
heading. Already-oriented entities are a no-op. A headless 2.1.24 probe confirmed
that a placed splitter can reverse on its existing axis but cannot reach the
perpendicular heading through native rotation. That request fails rather than
forcing a direction assignment. A `rotation_incomplete` error can follow partial
changes and includes actual heading details: inspect before further work, rather than resubmitting the failed operation. No automatic rollback occurs.

`InspectEntity` now reports `direction` (integer `defines.direction` value),
`supports_direction`, `rotatable` and `minable`. These are native capability flags,
not permission to bypass ownership, item-placeability or the host's excluded types.

## Actor recovery and removal

`MineObject({name,position,timeout_ticks})` performs normal character mining of a
minable neutral tree/rock or friendly infrastructure whose prototype has
`items_to_place_this`, regardless of base-game name or tier. Characters, units,
resources, ghosts and corpses are excluded. Native minability and character
reach are checked before acceptance and rechecked with ownership during mining.
It uses the existing asynchronous action/deadline/stop lifecycle. No instant destruction,
teleport or item grant is performed. Inventory and partial results must be
inspected after interruption; the terminal count describes a removed object,
not a guaranteed material yield. Walking remains straight-line steering without
general pathfinding: survey, use clear waypoints, or mine an observed neutral
obstacle normally instead of repeating a blocked walk.

All effects are bound to the run's `--bot NAME` (default `default`). Up to eight
actors have separate inventories/actions; shared machines and research still need
coordination. Only `SpawnBot` creates an unknown name. Use the same name for
inspection, polling and recovery; action IDs are actor-local.

`SpawnBot({position})` explicitly creates an empty character if the selected actor is
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
lua test/lua/transport_test.lua
lua test/lua/infrastructure_test.lua
mix test
```

Lua tests use isolated mocks; Elixir tests use fake calls and the real in-VM EYG
evaluator. They do not grant fixtures in the playing world. Live construction
and verification used the headless server through typed EYG, with exclusive
traces and original program sources retained under ignored `tmp/expansion/`.
