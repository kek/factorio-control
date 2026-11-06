# Factorio Control design

This is the maintained design reference. The current implementation targets **Factorio 2.1.24**, the version used for the live proof of concept. Earlier plans targeted 2.0; compatibility with 2.0 is not claimed. The host requires Elixir 1.18+ and OTP 27+ and has no external dependencies.

## Goal and architecture

Control a character on a headless server with a small observable loop: inspect the world, act, inspect the result. Ultimately an LLM, initially Claude, should write EYG programs using the same bot capabilities.

```text
LLM-generated EYG program (future)
          |
          v
Elixir host / effect handlers (handlers are future work)
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
| `walk_to` | `position`, optional `timeout_ticks` (1–3600, default 1800) | Accepts a bounded straight-line walking action. Stops within 0.5 tile or fails at its deadline. No pathfinding yet. |
| `mine` | Resource `position`, matching output `item`, optional `count` (1–1000, default 1) and `timeout_ticks` | Mines a single resource tile in reach using normal mining progress, until the inventory increases by `count`. Depletion before completion fails with partial count reported. |
| `action` | `id` | Current or terminal action record; unknown/expired IDs return an error. |
| `stop` | None | Cancels the active action and explicitly clears walking, mining, and selection. Safe to repeat. |
| `build` | `item`, `position`, optional cardinal `direction` | Inventory-backed placement of a starter drill, furnace, wooden chest, transport belt, or burner inserter. Returns the actual entity summary. |
| `transfer` | `entity` name, `position`, `inventory`, `direction` (`take`/`give`), `item`, `count` (1–1000) | Transfers exactly the requested quantity of normal-quality ordinary items to/from a reachable friendly entity. No transfer on insufficient items or capacity. |

Transfer inventory selectors are `fuel`, `output`, furnace `input`, and chest/character `main`. Stack types with metadata, such as blueprints, are excluded. Higher-quality stacks, fast replacement, ghosts, blueprints, arbitrary prototypes, crafting, and entity removal are outside the current gameplay API.

Building checks the supported item and its `place_result`, inventory, distance, grid alignment, character placement rules and surface collision rules before creation. Odd tile widths require half-integer coordinates; even widths require integers. Supported entities have square footprints. The item is consumed only after entity creation succeeds; failed removal destroys the newly created entity. The implementation uses validated `create_entity`, rather than promising equivalence with every player event/undo behavior. Other gameplay mods have not been tested.

## Action lifecycle and persistence

The mod stores the bot, sequence counter, active action, and the latest 64 action records in its own Factorio `storage`. One walk or mine action can run at once. Other mutations reject requests while it runs; inspection, status queries, and stopping remain available.

Actions transition from `running` to `completed`, `failed`, or `cancelled`. Records include ID, kind, start/deadline ticks, finish tick when terminal, and error details when failed. Mine actions report the collected count. Death/removal fails the active action. `on_tick` work is bounded: update movement or mining state, check progress/deadline, and clear state on completion. It performs no broad world scans.

Mining must call `update_selected_entity` as well as setting `mining_state`; setting the mining position alone did not sustain mining on the standalone character. Walking and mining are reapplied each tick. An unexpected tick-handler error fails the action and stops the character.

A host disconnect leaves the mod-owned bounded action running. `Bot.await` polls `action` without resubmitting it. Its wall-clock timeout does not cancel the in-game action; query or stop explicitly. Save/load persists active actions, deadlines, inventory, and IDs; game ticks resume from the saved tick. No `on_load` mutation is needed. Unsaved work cannot be recovered after a crash. Expired action records cannot be queried. Other actors modifying the bot inventory can affect mine-count completion, so only one host should control it.

## Verification and current evidence

The local POC built a drill feeding a furnace directly at `(29,-42)` / `(29,-40)`. A first console-driven character used the starting equipment and mined fuel. The mod-owned character is separate and starts empty.

The Elixir/mod production scenario subsequently walked to coal, mined 12 pieces, returned, refueled both machines and observed fresh plates (41 to 42 on the first run). The line remains in the test save. Protocol tests cover fragmentation, multiple replies, authentication rejection, invalid framing/IDs, deadlines, and no retries after a lost reply. Opt-in live tests exercise item conservation, failed and successful placement, transfers, cancellation, deadlines, and action queries from a new connection. See the README for commands and fixture assumptions.

## EYG effect boundary and future work

Proposed effects include `Place`, `Mine`, `Craft`, `Inspect`, `Wait(ticks)`, and `AwaitCondition`. Each handler should validate input, call the mod, and return structured results. The model should receive these capabilities rather than arbitrary Lua or RCON access. MCP is another possible adapter to the same operations.

EYG is intended to provide inferred effect types for checking plans, interchangeable handlers for dry runs, replayable traces and approval gates, and serializable continuations for suspension/resumption. This follows the earlier arm's-length email-agent design. These integration assumptions remain unverified. A suspended program also needs a defined completion notification mechanism; the initial host currently polls action status.

Models may need a compact EYG language reference, worked examples, fast type-error feedback, or JSON IR output. Further gameplay work includes crafting (`begin_crafting`), asynchronous pathfinding (`surface.request_path`), richer resource queries, inventory views, and eventually construction-robot ghost/blueprint workflows (`entity-ghost`, `LuaItemStack.build_blueprint`). Verify each new API against the pinned release.

Before expanding integration, define stable request deduplication/recovery for lost acceptance replies, richer entity selection, and whether action completion should be pushed or polled. Respawn policy, cancellation of future crafting/pathfinding, and multi-host ownership also need decisions.

## Constraints, observability, and prior art

Mods run in deterministic lockstep and cannot read network or file input. Commands arrive through RCON; output can use `rcon.print` or `script-output` files via `helpers.write_file`. Heavy per-tick work reduces UPS. Potential metrics options include Graftorio-style file export to Prometheus and `--benchmark-verbose` timings; these have not been integrated.

The Factorio Learning Environment (FLE, NeurIPS 2025) is a research lead, reported to offer a Python REPL API over RCON with MCP support and to target Factorio 1.1.110. Its compatibility and findings have not been independently checked here. Candidate higher-level primitives include belt connections and nearest-resource queries. Reported FLE findings favor good primitives, textual state and self-correction over vision; investigate them when designing the model's state and effects.
