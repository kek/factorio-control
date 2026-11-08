# Factorio Control design

This is the maintained design reference. The current implementation targets **Factorio 2.1.24**, the version used for the live proof of concept. Earlier plans targeted 2.0; compatibility with 2.0 is not claimed. The host requires Elixir 1.18+ and OTP 27+ and has no external dependencies.

## Goal and architecture

Control a character on a headless server with a small observable loop: inspect the world, act, inspect the result. Ultimately an LLM, initially Claude, should write EYG programs using the same bot capabilities.

```text
LLM-generated EYG program
          |
          v
Shared JS evaluator ↔ Elixir host / effect handlers
          |
          | Source RCON over TCP; Lua calls and JSON responses
          v
Factorio headless server
          |
          v
factorio-control mod -> character and world
```

The mod owns the character and actions spanning ticks. The Elixir host serializes RCON requests and decodes structured results. A normal client can join with a separate character to observe. The mod is installed in both server and client; versions and enabled mods must match.

## Server and transport

`FactorioControl.Server` optionally owns the headless OS process through an Elixir `Port`; `mix factorio.server` runs that owner and streams output. The Port launches `scripts/server`, which execs Factorio with the game save, mod, and `server-settings.json` as described in the README. The password must be supplied through `FACTORIO_RCON_PASSWORD`; the script never reads or commits credentials itself. The settings disable auto-pause so simulation continues without players. Game clients connect on `34197/UDP`; RCON uses `27015/TCP`. The protocol is unencrypted and belongs on localhost or a private network.

The server owner retains the latest 64 KiB of output, monitors the OS exit status, and exposes startup/readiness/status and stop operations. `/quit` on stdin requests a save and graceful shutdown; stop waits for the actual exit status. It does not rely on closing a Port to kill the OS child. SIGTERM of the Mix server task requests this shutdown. A shutdown timeout leaves ownership and logs available for inspection, with no automatic restart. Forced VM/OS termination can bypass cleanup and requires external process supervision for a stronger lifecycle guarantee.

`FactorioControl.Rcon` is a separate GenServer owning a passive TCP socket. Source RCON packets have a little-endian signed length, request ID and type, UTF-8 body, and two null terminators. Authentication uses type 3; commands use type 2. The client accepts an optional empty type-0 authentication packet, verifies the type-2 reply and ID, and rejects ID -1.

Commands use `/sc` (`/silent-command`) and `rcon.print`. Script commands disable achievements; the game may require repeating the initial command. The client never automatically confirms or repeats it. Lua is wrapped in `pcall` and terminated with a random completion marker. The receiver skips empty packets, joins fragments (even a split marker), validates nonempty response IDs, packet sizes and terminators, and applies a single deadline to the entire response. Frames are capped at 4 MiB and accumulated replies at 16 MiB.

A transport/protocol failure closes the socket and reports an **unknown outcome**. No automatic reconnect or retry occurs. If a reply to a mutation is lost, inspect the world and inventory after reconnecting. Async action IDs remain queryable if the caller received the ID; they do not provide deduplication for a request whose acceptance response was lost. `Rcon.lua` is an administrator escape hatch for setup/debugging, separate from `Bot.call`'s gameplay methods.

## Mod interface

`mods/factorio-control` exposes `remote.call("bot", "request", request)`. Requests are `{method = "...", args = {...}}`; remote functions return data and the RCON entry point prints JSON through `helpers.table_to_json`. Host arguments are JSON-encoded and then escaped as Lua string bytes, never interpolated as Lua expressions.

Success responses are `{ok = true, tick = game.tick, data = ...}`. Errors are `{ok = false, tick = game.tick, error = {code = "...", message = "..."}}`. A successful transport call can contain a game error. Empty Lua collections currently serialize as `{}` rather than `[]`; nonempty inventory collections contain `{name, quality, count}` entries.

| Method | Arguments | Result / behavior |
| --- | --- | --- |
| `spawn` | Optional `position: {x,y}`, `surface` (default `nauvis`) | Creates an empty player-force character at a noncolliding position within 16 tiles; returns the existing living bot on repeat. Explicit spawn after death creates a replacement without recovering lost inventory. |
| `inspect` | Optional `radius` (0–64, default 16), `name` entity filter | Position, health, inventory, active action, and up to 200 nearby entity summaries with a truncation flag. Friendly machines include fuel/output; furnaces include input. |
| `inspect_entity` | `name`, `position` | A single entity lookup on the bot's surface, independent of reach. Friendly entities expose symbolic `status_name`, inventories and machine input/output where applicable; numeric `status` remains available. Missing entities return `not_found`. |
| `inspect_simulation` | None | Game speed, `tick_paused`, connected player count and base version, without requiring a bot character. |
| `inspect_recipe` | `name` | Enabled recipe, categories, ingredient/product quantities and directly affordable batches. |
| `craft` | `recipe`, `count` (1–100), `timeout_ticks` | Timed recipe batches consuming direct ingredients; reports produced item count and stops at completion/deadline. |
| `walk_to` | `position`, optional `timeout_ticks` (1–3600, default 1800) | Accepts a bounded straight-line walking action. Stops within 0.5 tile or fails at its deadline. No pathfinding yet. |
| `mine` | Resource `position`, matching output `item`, optional `count` (1–1000, default 1) and `timeout_ticks` | Mines a single resource tile in reach using normal mining progress, until the inventory increases by `count`. Depletion before completion fails with partial count reported. |
| `action` | `id` | Current or terminal action record; unknown/expired IDs return an error. |
| `stop` | None | Cancels the active action and explicitly clears walking, mining, and selection. Safe to repeat. |
| `build` | `item`, `position`, optional cardinal `direction` | Inventory-backed placement of a starter drill, furnace, wooden chest, transport belt, or burner inserter. Returns the actual entity summary. |
| `transfer` | `entity` name, `position`, `inventory`, `direction` (`take`/`give`), `item`, `count` (1–1000) | Transfers exactly the requested quantity of normal-quality ordinary items to/from a reachable friendly entity. No transfer on insufficient items or capacity. |

Transfer inventory selectors are `fuel`, `output`, furnace/assembler/lab `input`, turret `ammo`, and chest/character `main`. Unowned NPC corpses also support read-only inventory inspection and `main` recovery; corpses associated with an existing player are excluded. Ordinary normal-quality items and full base firearm magazines/red science packs are supported. Partially consumed magazines/tools cannot be refreshed by a count-only transfer; taking used consumables from turrets or labs is rejected. Blueprints and other arbitrary metadata stacks, higher quality, ghosts, fast replacement and arbitrary prototypes remain unsupported. `MineObject` performs normal mining of neutral trees/rocks or friendly allowlisted infrastructure.

Building checks the supported item and its `place_result`, inventory, distance, grid alignment, character placement rules and surface collision rules before creation. Odd tile dimensions require half-integer coordinates; even dimensions require integers. Width and height are checked independently and swapped for east/west orientation, supporting rectangular splitters, boilers and generators. The item is consumed only after entity creation succeeds; failed removal destroys the newly created entity. The implementation uses validated `create_entity`, rather than promising equivalence with every player event/undo behavior. Other gameplay mods have not been tested.

## Action lifecycle and persistence

The mod stores the bot, sequence counter, active action, and the latest 64 action records in its own Factorio `storage`. One walk, mine or craft action can run at once. Other mutations reject requests while it runs; inspection, status queries, and stopping remain available.

Actions transition from `running` to `completed`, `failed`, or `cancelled`. Records include ID, kind, start/deadline ticks, finish tick when terminal, and error details when failed. Mine actions report the collected count. Death/removal fails the active action. `on_tick` work is bounded: update movement or mining state, check progress/deadline, and clear state on completion. It performs no broad world scans.

Mining must call `update_selected_entity` as well as setting `mining_state`; setting the mining position alone did not sustain mining on the standalone character. Walking and mining are reapplied each tick. An unexpected tick-handler error fails the action and stops the character.

A host disconnect leaves the mod-owned bounded action running. `Bot.await` polls `action` without resubmitting it. Its wall-clock timeout does not cancel the in-game action; query or stop explicitly. Save/load persists active actions, deadlines, inventory, and IDs; game ticks resume from the saved tick. No `on_load` mutation is needed. Unsaved work cannot be recovered after a crash. Expired action records cannot be queried. Other actors modifying the bot inventory can affect mine-count completion, so only one host should control it.

## Verification and current evidence

The local POC built a drill feeding a furnace directly at `(29,-42)` / `(29,-40)`. A first console-driven character used the starting equipment and mined fuel. The mod-owned character is separate and starts empty.

The Elixir/mod production scenario subsequently walked to coal, mined 12 pieces, returned, refueled both machines and observed fresh plates (41 to 42 on the first run). The line remains in the test save. Protocol tests cover fragmentation, multiple replies, authentication rejection, invalid framing/IDs, deadlines, and no retries after a lost reply. Opt-in live tests exercise item conservation, failed and successful placement, transfers, cancellation, deadlines, and action queries from a new connection. See the README for commands and fixture assumptions.

## EYG effect boundary

`FactorioControl.Eyg` embeds the shared evaluator through an NDJSON worker at
`config/pi/agent/extensions/eyg-action/portable-worker.mjs`. The shared Gleam
module parses, checks a host-owned structural effect context and retains the
continuation while Elixir handles each request. The runtime has no Pi imports.
Elixir owns credentials, RCON and game action lifecycles. This uses the current
JavaScript target; a native BEAM evaluator has not been investigated.

Every effect returns EYG `Result(value, String)`. `Inspect({radius})` returns a
fixed `{tick, inventory, entities, truncated}` record. Inventory/output stacks
are `{name, quality, count}`; entities expose `{name,x_milli,y_milli,amount,output}`. `amount` is the remaining resource quantity, or zero for other entities.
Absent/empty Lua collections become lists. Coordinates in observations are
rounded to integer thousandths of a tile. Inspection is bounded by the existing
200-entity mod limit and the shared 64,000-byte protocol frame limit; preserve
and check `truncated` before treating a missing entity as absent.

Focused read-only effects expose the troubleshooting information without
granting any mutations:

| Effect | Request | Result fields (in addition to `tick`) |
| --- | --- | --- |
| `InspectBot` | `{}` | `bot:{x_milli,y_milli,health_milli,surface,inventory,active_actions}` |
| `InspectEntity` | `{name,position:{x2,y2}}` | `entity:{name,type,unit_number,x_milli,y_milli,amount,status,inventory,fuel,input,output}` |
| `InspectResources` | `{item,radius}` | `resources:[{name,x_milli,y_milli,amount}],truncated` |
| `InspectAction` | `{id}` | `action:{id,kind,status,count,started_tick,deadline_tick,finished_tick,has_position,x_milli,y_milli,error_code,error_message}` |
| `InspectSimulation` | `{}` | `speed_milli,tick_paused,connected_players,version` |

`InspectBot` and `InspectResources` use the existing bounded `inspect` method;
the resource query applies a name filter before the 200-entity limit.
`InspectEntity` uses the dedicated single-entity mod lookup. Inserters and drills also expose pickup/drop positions
and target names for checking material flow. It can inspect
known locations anywhere on the bot's current surface, matching the earlier
administrator diagnostics, but cannot execute arbitrary Lua. Inventories are
exposed only for friendly entities: character/chest main inventory, machine
fuel/output, and furnace/assembler input. Unsupported inventories are empty
lists. Status strings use the game's `defines.entity_status` names, with
`not_applicable` when no machine status is reported. Missing unit numbers and
non-resource amounts are zero. Inventory stack records retain name, quality
and count, without stack metadata.

Bot health and game speed use integer thousandths to preserve fractional values.
`active_actions` contains zero or one action. Action summaries retain partial
progress and match the records used by `await`; `finished_tick` is zero for
nonterminal actions, absent positions have `has_position:false` and zero
coordinates, and absent errors use empty strings. Unknown/expired IDs are
ordinary errors. Inspection never awaits, cancels, spawns, or retries an action.
`InspectSimulation` reports `game.tick_paused`, which does not by itself establish
whether server auto-pause is preventing tick advancement.

`scenarios/inspect.eyg` demonstrates these diagnostics with inspection-only
grants. The example summarizes resource quantities rather than returning an
entire large resource list, keeping its final result within the worker's 12 KB
result budget. Each read is a separate tick-stamped snapshot, not an atomic
snapshot across multiple effects. Existing `Inspect({radius})` programs keep
their original result shape.

Other effects return `{tick,count,action_id}` (`action_id:0` for immediate
operations; `count:0` where not applicable):

| Effect | Request |
| --- | --- |
| `WalkTo` | `{position:{x2,y2},timeout_ticks}` |
| `Mine` | `{position:{x2,y2},item,count,timeout_ticks}` |
| `Rotate` | `{name,position,direction}`; cardinal orientation, friendly reachable starter drills/inserters/belts |
| `Craft` | `{recipe,count,timeout_ticks}`; 1–100 batches, explicit intermediate crafts |
| `Build` | `{position:{x2,y2},item,direction}`; direction is `north/east/south/west` |
| `Transfer` | `{position:{x2,y2},entity,inventory,direction,item,count}` |
| `Wait` | `{ticks}` |
| `Stop` | `{}` |

Input positions use **integer half-tile units**, so `{x2:91,y2:35}` means
`(45.5,17.5)`. Floats and null are not supported by the bridge. Position
components are limited to ±2,000,000; counts to 1–1000; durations to 1–3600
ticks; names to 100 UTF-8 bytes. The mod retains its stricter gameplay checks.
There is no spawn/respawn effect or administrator Lua escape hatch.

`WalkTo`, `Mine` and `Craft` submit once, then poll the accepted action ID through
`Bot.await`. They resume the EYG continuation only after a terminal result.
Confirmed game rejection or failed/cancelled actions return catchable `Error`;
raw game/action receipts retain partial progress. Transport loss, unknown action
status, malformed replies, host exceptions and timeouts stop evaluation without
resuming as an ordinary error. Requests are never automatically retried or
reconnected. IDs do not deduplicate lost acceptance replies.

`Wait` polls game ticks (not elapsed wall time), with a separate 65-second wall
limit. The whole run defaults to 300 seconds, maximum 600 seconds, including
handlers, and allows at most 100 external effects. These are distinct from each
action's in-game tick deadline. A paused game can reach a wall deadline without
advancing its simulation deadline.

The host kills its disposable Node worker at completion, timeout or host-process
death. A host-submitted walk/mine/craft action that lacks a confirmed rejection or
matching terminal receipt on a returned host failure triggers one best-effort
`stop` through the same connection, recorded separately. A worker request alone
does not establish that an action was submitted. It does
not reconnect, retry the action, undo a build/transfer, or establish that an
uncertain mutation did not occur. A typecheck/read-only failure performs no
cleanup mutation. Abrupt VM/application death may prevent cleanup; the mod's
tick deadline remains the fallback. Concurrent controllers are unsupported.

The CLI exclusively creates a private NDJSON trace and flushes requests,
host submission attempts, acceptance receipts, terminal receipts and replies. Confirmed receipts also
survive a worker/handler failure in the returned trace. Source hashes and worker
paths aid audit but do not pin a save, runtime or mod version. Durable
continuations, deterministic world replay, plan approvals, request deduplication
and multi-host ownership remain future work. A fake backend can implement the
same call/await callbacks; that tests orchestration, not collision, reachability
or resource availability in a real world.

The production scenarios inspect the known coal patch and select a tile with at
least 12 coal, rather than repeatedly targeting a depleted tile. Before checking
production, they transfer existing furnace output to the bot inventory and take
a fresh baseline. Inventory-capacity failures remain explicit errors; no items
are discarded. The search is bounded to five tiles around the known coal waypoint,
so exhaustion of that area requires choosing another waypoint.

Verification includes fake-backend runs of `production.eyg` with empty, partially
filled, and full furnace output, insufficient coal tiles and no remaining coal,
unknown mutation replies, acceptance-receipt retention after handler timeout,
restricted contexts, empty collection normalization, and killing a CPU-bound
worker. A live EYG run with a depleted original coal tile and 100 plates in the
furnace successfully collected the plates and observed new output grow from 1
to 2. The interpreter process still has
OS permissions; this is an effect interface, not a hardened hostile-code sandbox.

Further gameplay work includes asynchronous pathfinding, richer
resource queries and construction-robot workflows. Verify new game APIs against
the pinned Factorio release before adding them.

## Constraints, observability, and prior art

Mods run in deterministic lockstep and cannot read network or file input. Commands arrive through RCON; output can use `rcon.print` or `script-output` files via `helpers.write_file`. Heavy per-tick work reduces UPS. Potential metrics options include Graftorio-style file export to Prometheus and `--benchmark-verbose` timings; these have not been integrated.

The Factorio Learning Environment (FLE, NeurIPS 2025) is a research lead, reported to offer a Python REPL API over RCON with MCP support and to target Factorio 1.1.110. Its compatibility and findings have not been independently checked here. Candidate higher-level primitives include belt connections and nearest-resource queries. Reported FLE findings favor good primitives, textual state and self-correction over vision; investigate them when designing the model's state and effects.

## Recipe-driven crafting

`InspectRecipe({name})` returns `tick` and a recipe with `name`, `enabled`,
`categories`, `time_milli`, `craftable`, ingredient quantities, and product
quantity/probability ranges in integer thousandths. `craftable` counts only
batches affordable from direct normal-quality ingredients; it does not assume
recursive ingredient crafting.

`Craft({recipe,count,timeout_ticks})` accepts an asynchronous action and waits
through the same action lifecycle as walking/mining. The count is 1–100 recipe
batches; terminal receipts count actual output items. The mod restricts recipes
to enabled `crafting` categories, integer item inputs, and a single guaranteed
supported item result. Ordinary items plus full base firearm magazines and
red science packs are allowed. It checks all ingredients and output capacity
before starting. No fluids, arbitrary metadata stacks, probabilistic outputs or
item grants are supported.

The initial native approach encountered a player-only API on the standalone
character. The current effect implements recipe-driven crafting in the mod:
one recipe execution completes after its base energy × 60
ticks. At that tick the mod rechecks ingredients/capacity, consumes that batch's
inputs and inserts exactly its output. Unfinished batches have consumed nothing,
so cancellation or timeout needs no refund. Player crafting-speed bonuses and
native recursive crafting are not applied. Completed counts and remaining
materials persist through save/load in the existing mod storage.

The separate `HandCraft` effect now uses the engine queue on the standalone
character, retaining owned cancellation and reporting only genuinely completed
output to force production statistics when the engine has not reported it. This
allows normal craft-triggered progression without granting technology. See
[the expanded effect boundary](docs/expansion-effects.md) for that behavior and
the infrastructure, research, inventory and actor-recovery controls.

Game tasks must use only EYG effects, including planning observations. See
`AGENTS.md` for that workflow and headless-server deployment rules. The staged
programs under `scenarios/iron-pipeline/` construct and verify the physical starter
pipeline without administrator Lua or generated materials.

The iron pipeline's inserters require `north` to pick up from the furnace and
place into the chest south of the arm. This was checked with actual pickup/drop
targets, rather than inferred from mining-drill orientation. `Rotate` changes
only a reachable friendly supported entity's cardinal direction; it neither
creates an entity nor retries an uncertain change. `service.eyg` uses this effect
and inventory inspections to restore flow and top up fuel from the coal station.
