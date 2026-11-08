# Factorio Control

An Elixir host controls a character on a headless Factorio server through a small Lua mod. EYG programs can use the same constrained gameplay interface through an Elixir effect host and a shared, Pi-independent evaluator.

**Status:** working prototype on **Factorio 2.1.24**. RCON, inspection, walking, mining, placement, inventory transfers, and iron production have been exercised on the local server. The EYG coal-to-iron program has also passed on the live server, including a depleted coal tile and a full furnace output. Recipe-driven crafting is available; pathfinding remains future work.

## Run locally

Requires Elixir 1.18+ with OTP 27+ and the Factorio 2.1.24 Linux headless distribution unpacked into `factorio/`. There are no Hex dependencies. The game, saves, build output, and local credentials are ignored by version control.

Create a save if needed:

```sh
cd factorio
./bin/x64/factorio --create ./saves/my-save.zip
cd ..
```

Set `FACTORIO_RCON_PASSWORD` locally (the existing `.envrc` supplies it), then start the server:

```sh
source .envrc
mix factorio.server
```

`mix factorio.server` owns the game process through an Elixir `Port` and streams its output. It launches `scripts/server`, which links the mod from `mods/factorio-control` into the server's mod directory and execs the game with `my-save.zip` and `server-settings.json`. These settings keep ticks advancing with no connected players. If the mod was previously disabled, enable `factorio-control` in `factorio/mods/mod-list.json` before starting.

For a graphical client, install the same mod directory under `~/.factorio/mods/factorio-control`, restart/synchronize mods, and connect to **localhost:34197**. Match the server's game version and enabled official mods. Mod code changes require restarting both server and client. The local test installation uses symlinks to this checkout.

The standalone Linux client can use its unpacked directory instead of `~/.factorio`.
For the installation at `~/Applications/factorio`, install the mod in
`~/Applications/factorio/mods/factorio-control`. Check `Write data path` in the
client's `factorio-current.log` to identify the correct location. The local mod
is unpublished, so the multiplayer sync dialog cannot download it from the mod
portal; install it locally first, enable it, and restart the client.
When updating the mod, update both installations together. In this development
setup the server and standalone client both link to `mods/factorio-control`, so
edits reach both automatically; restart both processes to load the new Lua code.
Server capability work is validated against the headless server and typed EYG;
these client joining instructions are not a requirement to inspect or verify the
graphical client for each change.

RCON listens on TCP port 27015; game clients use UDP port 34197. RCON is unencrypted: keep it on a trusted local/private network. Lua console commands disable achievements in the save; Factorio may require repeating the first command to confirm. This client does not repeat commands automatically.

To own the server from an interactive Elixir session instead, use `iex -S mix`:

```elixir
{:ok, server} = FactorioControl.Server.start_link()
FactorioControl.Server.await_ready(server)
FactorioControl.Server.status(server)
# After playing:
FactorioControl.Server.stop(server)
```

Use one server launcher at a time. `Server.stop/1` sends `/quit` through the Port's stdin and waits for the process to save and exit. `mix factorio.server` also handles SIGTERM for orderly shutdown. A double Ctrl-C or forced VM kill can bypass cleanup; a Port closing alone does not guarantee the OS process exits. Startup/shutdown timeouts remain visible in `Server.status/1`; no automatic server restart occurs. Server ownership is opt-in, so running client commands or tests does not launch a second game server.

## Control the bot

```sh
mix factorio spawn '{"position":{"x":29,"y":-38}}'
mix factorio inspect '{"radius":8}'
mix factorio walk_to '{"position":{"x":35,"y":-35},"timeout_ticks":600}'
# Use the returned action ID:
mix factorio action '{"id":1}'
mix factorio stop
```

`spawn` creates an empty character or returns the existing living bot. It grants no starter items. Transfer supplies from a nearby friendly character or chest using `transfer`; see [DESIGN.md](DESIGN.md) for request fields and limits. The first POC character and its smelting line are separate from the mod-owned bot.

The Elixir API is also available from `iex -S mix`:

```elixir
alias FactorioControl.{Bot, Rcon}
{:ok, client} = Rcon.start_link(password: System.fetch_env!("FACTORIO_RCON_PASSWORD"))
{:ok, %{"data" => %{"id" => id}}} =
  Bot.call(client, :walk_to, %{"position" => %{"x" => 35, "y" => -35}})
Bot.await(client, id)
Rcon.close(client)
```

`Bot.call` returns `{:ok, response}` when transport and JSON decoding succeed. Check `response["ok"]` for game acceptance, then an asynchronous action's terminal `status` for completion. `Bot.await` polls status without resubmitting the action. Only one movement/mining action runs at once; immediate mutations reject requests while it is active.

A lost command response returns `{:error, {:unknown_outcome, reason}}` and closes the connection. Reconnect and inspect world/inventory/action state before deciding what to do. The client never retries a mutation or reconnects automatically. Tick deadlines survive host disconnects; time does not advance while the game itself is paused.

## Verification

```sh
mix test
# Opt-in: modifies the running test world with a small temporary fixture.
mix test --include live
# On the existing POC save: mines real fuel and verifies fresh iron production.
mix run scenarios/production.exs
```

Process-lifecycle tests use small fake executables to exercise Port output, readiness, startup failure, and graceful shutdown. Protocol tests use local fake TCP servers, covering fragmented reads, multi-packet replies, authentication rejection, malformed frames, response IDs, deadlines, and lost replies without retries. Live tests require an idle mod-owned bot on Nauvis with room nearby, spare inventory space, and no furnace in its inventory. They temporarily grant two chest items and two wood through administrator Lua, then clean up the fixture. Do not run another bot plan concurrently. A failed test or transport loss can require manual fixture cleanup.

Both production scenarios use the existing POC iron drill at `(29,-42)`, furnace at `(29,-40)`, and coal patch near `(44,17)`. They inspect the patch, choose an observed tile with at least 12 coal, walk to it and mine 12 pieces. They return, collect finished plates into the bot inventory, record a new output baseline, fuel both machines, and wait for fresh plates. They create no items. The route must remain clear, a suitable coal tile must remain within the five-tile search radius, and the bot must have room for fuel and collected plates.

## EYG programs

Build the shared evaluator from the sibling config checkout (Gleam and Node 24+):

```sh
(cd ../config/pi/agent/extensions/eyg-action && gleam build)
export EYG_WORKER="$PWD/../config/pi/agent/extensions/eyg-action/portable-worker.mjs"
mix test
```

Tests default to that sibling worker location; set `EYG_WORKER` for a different
layout. The evaluator is shared source, not copied into this repository or
published as a package. It uses its existing pinned Gleam dependencies. There
are still no Hex dependencies in the Elixir host.

With a running server, RCON credentials and an existing idle bot, run:

```sh
mix factorio.eyg --effects Inspect,WalkTo,Mine,Transfer,Wait scenarios/production.eyg
```

This **changes the world**: it selects an available tile in the known coal patch,
mines 12 coal, returns to the POC iron line, collects finished plates, gives five
coal to each machine, and checks for fresh iron plates for at most 1,200 ticks.
It creates no items. It assumes the same world layout as `scenarios/production.exs`;
prepare the bot explicitly with `mix factorio spawn` if needed. Use one controller
at a time. The EYG program has passed fake-backend tests and a live run starting
with the original coal tile depleted and 100 plates blocking the furnace. The
reported `before`/`after` counts describe furnace output after collecting the old
plates; collected plates remain in the bot inventory.

`--effects` is the host's capability selection, checked before evaluation; the
program cannot add effects. Omit it to enable all available effects, including
the read-only inspections below and the bounded expansion effects.
`--worker`, `--timeout` (milliseconds, default 300000, maximum 600000),
`--max-effects` (default/maximum 100), `--host`, `--port` and `--trace` are
available. No arbitrary Lua, RCON, shell, filesystem or network effect is exposed.

Each run writes an exclusive mode-0600 NDJSON trace to the printed temporary
path, or `--trace PATH`. Requests precede gameplay calls; game acceptance and
terminal action receipts are flushed separately before resuming the program.
The trace includes a source hash, chosen effects and worker path. Preserve the
source and worker revision alongside it for replay; this is not a deterministic
world replay or durable continuation store.

See [the EYG integration design](DESIGN.md#eyg-effect-boundary) for contracts,
coordinate units and failure/cancellation behavior.

## Read-only EYG inspections

Run the same inspections used to diagnose the production line, without granting
movement, mining, building, transfers, or stopping:

```sh
mix factorio.eyg \
  --effects InspectBot,InspectEntity,InspectResources,InspectSimulation \
  scenarios/inspect.eyg
```

The example reports the POC furnace and drill inventories/status, bot inventory
and position, simulation state, and a summary of nearby coal. It neither spawns
a bot nor changes the world. It requires an existing bot and the updated mod on
the server; your standalone client needs the same mod when joining.

| Effect | Available information |
| --- | --- |
| `InspectBot({})` | Position, health, surface, inventory, and active action (if any). |
| `InspectEntity({name,position:{x2,y2}})` | One entity on the bot's surface, including symbolic status (`full_output`, `no_fuel`, etc.), resource amount, and separate main, fuel, input and output inventories where supported. The lookup does not require the bot to be within interaction reach. |
| `InspectResources({item,radius})` | Positions and remaining quantities for up to 200 matching resource tiles within 0–64 tiles of the bot, plus a truncation flag. |
| `InspectAction({id})` | Action status, partial collected count, target, tick deadlines, and error details. IDs come from action receipts in the trace; only the latest 64 actions are retained. |
| `InspectSimulation({})` | Tick, game speed, explicit pause flag, connected player count, and game version. Works even before spawning a bot. |

All return `Result(value, String)`. Observed positions, health and simulation
speed use integer thousandths (`speed_milli:1000` means normal speed). Input
positions still use integer half tiles. Empty inventories/actions are lists;
the diagnostic's coal sum covers only observed tiles and is incomplete if
`truncated` is true. Missing entities and expired action IDs return errors.
The explicit `tick_paused` flag is not a substitute for observing tick advancement
when diagnosing server auto-pause.

## Agent gameplay and the iron pipeline

Agents inspect and control the world exclusively through EYG effects. If an
operation is missing, extend and test its typed host/mod capability first. Direct
RCON/Lua or Bot API calls are not a gameplay or planning fallback. Mod deployment
and Port-owned server lifecycle operations are separate from gameplay.

`Craft({recipe,count,timeout_ticks})` crafts 1–100 batches of an unlocked recipe
with a single guaranteed supported item output (ordinary items, full firearm magazines or red science packs). `InspectRecipe({name})` exposes
categories, ingredient quantities, products, base crafting time and the number
of batches affordable from **directly available normal-quality ingredients**.
Craft intermediate items explicitly. This implementation uses a mod-owned crafting action rather than a player
hand-crafting queue; it enforces base recipe time and consumes the direct
ingredients only when each batch completes. Stop/timeout preserves completed
items and consumes nothing for unfinished batches. The receipt count is produced
items, which may differ from the requested batch count (for example belts).

`InspectEntity` also exposes pickup/drop positions and target entity names for
inserters and mining drills. `Build` supports iron chests as well as the existing
starter buildings. `Rotate({name,position,direction})` sets a reachable friendly
starter inserter, drill or belt to an absolute cardinal direction. The output
inserters in this layout use `north`: their pickup is from the furnace above
and their drop goes into the chest below, verified through connection inspection.

The EYG files in `scenarios/iron-pipeline/` implement this save's starter pipeline:

- `plan.eyg`: inspect recipes and resources.
- `craft-chests.eyg`: craft four iron storage chests.
- `prepare.eyg`: mine 40 stone, craft furnaces/gears, build two mutually fueling
  coal drills at `(58,18)` and `(60,18)`.
- `fuel.eyg`: mine uncovered coal and collect drill surplus, retaining fuel in both.
- `build.eyg`: craft the remaining equipment, reuse the POC iron lane, and build
  four drill → furnace → burner inserter → chest lanes at x=25,29,33,37.
- `service.eyg`: collect coal-station surplus, set output inserters to the correct
  direction, and replenish missing drill/furnace/inserter fuel.
- `verify.eyg`: observe each output chest over 1,200 ticks and require growth on
  all four lanes.
- `inspect.eyg`: read-only inspection of the completed setup and coal station.

These are **staged, save-specific construction programs**, not automatic retries
or a fresh-save bootstrap. Do not rerun completed crafting/build stages blindly;
inspect the world and inventory first. After construction the machines handle
ore, smelting and output transfer independently. These initial stages relied on
bot coal deliveries; the autonomous belt supply described below replaces that
routine maintenance.

The mod's crafting lifecycle can also be checked without the game:

```sh
lua test/lua/crafting_test.lua
```

This additional test requires Lua 5.4 and checks material costs, timing,
cancellation, deadlines, inventory capacity and recipe restrictions.

## Autonomous coal refuelling (current save)

The initial permanent coal supply used **184 transport belts and 14
coal-feeding burner inserters**. The two original coal drills face south onto
the belt and automatically refuel from that stream. The expansion below adds
two more coal drills and branches for steam power and stone bricks. Each iron lane receives
coal for its drill, furnace and original plate-output inserter. No background
bot servicing process is needed.

Construction used existing plates and ordinary inventory-backed crafting. All
connections were inspected through EYG. After startup, all fourteen machine
fuel inventories were positive and all four output chests gained plates over
3,600 ticks, with no further bot fuel deliveries.

See [the staged construction record and safe checks](scenarios/iron-pipeline/refuel/README.md).
The construction stages are already complete; do not rerun them blindly. The
older `service.eyg` routine predates this belt supply and is no longer needed for
routine refuelling. Coal/iron deposits must remain available and output chests
must have room.

`scenarios/iron-pipeline/inspect.eyg` inspects the existing line;
`scenarios/iron-pipeline/refuel/verify.eyg` checks fresh plate growth in every
lane. Execution evidence is retained in the ignored `tmp/refuel/` directory.

## Bus, workshop and starter defenses

The expanded save has an iron/copper bus, three powered assembler branches for
gears, firearm magazines and belts, a steam plant/two-lab grid, and guarded
resource production. The workshop buffers each reached 100 products, supplied
subsequent construction and turret loads, and refilled from the iron bus.

A 106-wall enclosure surrounds the bus/workshop, with a turret-covered two-tile
service opening. Nine armed turrets cover this enclosure and the iron, stone,
coal and power areas. The resource/power outposts are not all inside the wall
rectangle; copper supply is currently buffer-fed and turret reloads remain
inventory transfers, not a claimed automatic perimeter loader.

See [the current layout and safe checks](scenarios/expansion/README.md) and
[the bounded expansion effect contracts](docs/expansion-effects.md). Historical
construction/recovery programs and exclusive traces are kept in ignored
`tmp/expansion/`; do not replay them against the completed factory.

Before shutting down the sandbox runtime, stop its server through the Elixir
Port owner and confirm save completion/exit. A backend's short forced-cleanup
grace is not a guaranteed save boundary. Recover an interrupted save only from
a validated save/autosave, retaining the old files before replacement.
