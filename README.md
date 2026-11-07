# Factorio Control

An Elixir host controls a character on a headless Factorio server through a small Lua mod. EYG programs can use the same constrained gameplay interface through an Elixir effect host and a shared, Pi-independent evaluator.

**Status:** working prototype on **Factorio 2.1.24**. RCON, inspection, walking, mining, placement, inventory transfers, and iron production have been exercised on the local server. The EYG adapter and coal-to-iron program are verified against a fake backend; a live EYG run remains unverified. Crafting and pathfinding remain future work.

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

The production scenario uses the existing POC iron drill at `(29,-42)`, furnace at `(29,-40)`, and coal tile at `(45.5,17.5)`. It walks to coal, mines 12 pieces, returns, fuels both machines, and waits for the iron-plate count to increase. It creates no items. It requires that coal tile still exist, the route remain clear, and the furnace output have room.

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

This **changes the world**: it walks to the existing coal tile, mines 12 coal,
returns to the POC iron line, gives five coal to each machine, and checks for
fresh iron plates for at most 1,200 ticks. It creates no items. It assumes the
same world layout as `scenarios/production.exs`; prepare the bot explicitly with
`mix factorio spawn` if needed. Use one controller at a time. The EYG program
has passed a fake-backend integration test; it has not yet been run live.

`--effects` is the host's capability selection, checked before evaluation; the
program cannot add effects. Omit it to enable all seven gameplay effects.
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
