# Factorio Control design

This is the maintained design reference for Factorio Control. Nothing is implemented yet. API details and protocol behavior described below must be verified against the chosen Factorio 2.0 release. Untested code sketches are preserved in the appendix as reference material.

## Goal and scope

Control a character on a headless Factorio server from an external program, eventually driven by an LLM, initially Claude. Start with a small, observable loop: inspect the world, perform an action, and inspect the result.

The first milestone covers server setup, RCON communication, and spawning, walking, and building. Mining, crafting, inventory transfers, pathfinding, and EYG integration follow once that loop works.

## Architecture

```text
LLM-generated EYG program
          |
          v
Elixir host / effect handlers
          |
          | RCON commands and JSON responses
          v
Factorio headless server
          |
          v
Lua bot mod -> character and world
```

The server runs the simulation. The mod owns the bot character and actions that need work across ticks. The Elixir host manages RCON, dispatches actions, and decodes results. A normal Factorio client can join to observe the bot with a separate player character.

## Server setup

Target Factorio 2.0, pinning the exact version when implementation begins. Use the Linux headless distribution and a dedicated save. Proposed startup commands:

```sh
./bin/x64/factorio --create saves/bot.zip
./bin/x64/factorio --start-server saves/bot.zip \
  --rcon-port 27015 --rcon-password "$FACTORIO_RCON_PASSWORD" \
  --server-settings server-settings.json
```

Copy `data/server-settings.example.json` to `server-settings.json` and set `auto_pause` to `false` so the simulation continues without connected players. Supply the RCON password locally; do not commit it. Keep RCON on localhost or a private network because the protocol is unencrypted.

To observe a local server, use Multiplayer → Connect to address in the game client and connect to `localhost` on the default game port, `34197/UDP`. Client and server must use matching game versions and mods. Initially, install the bot mod in both locations by hand.

## RCON client

Implement the Source RCON protocol over TCP in Elixir. Packets contain a little-endian length, request ID, type, and a body followed by two null bytes. Authentication uses type `3`; command execution uses type `2`.

Use `/sc` (`/silent-command`) to invoke Lua and `rcon.print` to return results. An initial connectivity check is `/sc rcon.print(game.tick)`. Running script commands is expected to disable achievements for the save; verify this behavior for the chosen release.

The client in the appendix is an untested sketch. Before relying on it, verify authentication response ordering, rejection with request ID `-1`, and how Factorio splits long responses. The implementation should validate packet lengths and response IDs, handle partial reads and timeouts, and identify when a response is complete. A lost response to a state-changing command must not cause an automatic retry that repeats the action.

## Bot mod

The mod exposes a `bot` interface through `remote.add_interface`. It creates a character entity without requiring a connected human player and keeps persistent state in Factorio 2.0's `storage` (`global` in 1.1). The proposed approach controls the character through `LuaControl`, with `info.json` and `control.lua` in `mods/bot/`.

The initial interface should support:

| Action | Intended behavior |
| --- | --- |
| `spawn` | Create the bot at a valid position; define behavior if one already exists. |
| `walk` | Set a direction or stop movement. |
| `pos` / inspect | Return position and relevant world or inventory state. |
| `build` | Place an entity using the bot's inventory and allowed reach. |

Movement runs through an `on_tick` handler. Stopping must explicitly clear walking state, and handlers must tolerate a missing or invalid character. Keep per-tick work small to preserve simulation speed.

Return structured JSON through `helpers.table_to_json` and `rcon.print`, with consistent success and error results. Remote functions should preferably return data, with the RCON entry point responsible for printing it. Exact request and response schemas remain to be defined.

Building should check the required item, reach, and placement before changing inventory, and should consume items only for a successful placement. The appendix’s `can_place_entity` / `create_entity` sketch does not establish that these checks match normal player behavior; verify the supported character APIs and failure cases before implementing it.

Later actions cover mining, crafting, inventory transfers, and asynchronous pathfinding. Candidate APIs are `mining_state`, `begin_crafting`, `insert`, `remove_item`, and `surface.request_path`; verify their availability and behavior for the chosen version. Direct entity creation or item grants may be useful for test setup, but ordinary gameplay effects should enforce the intended game rules. Ghost and blueprint placement (`entity-ghost`, `LuaItemStack.build_blueprint`) is a later option for an LLM planner when construction robots are available.

## EYG effect boundary

The proposed effects include `Place`, `Mine`, `Craft`, `Inspect`, `Wait(ticks)`, and `AwaitCondition`. Each handler validates its input, calls the mod, and returns a structured result. The model should receive these capabilities rather than arbitrary Lua or RCON access.

EYG is intended to provide inferred effect types for checking plans, interchangeable handlers for dry runs, replayable recorded traces, and approval gates, and serializable continuations for suspension and resumption. The rationale for this capability boundary over FLE-style Python is that gameplay bypasses are available only if a handler exposes them. This follows the earlier arm's-length email-agent design; the details of that design are outside this document. These integration assumptions still need verification. A suspended program does not itself solve completion notification: the host needs a defined way to learn that a tick deadline or condition has been reached, so the LLM need not poll.

Start model integration with a compact language reference, worked examples, and fast error feedback. Emitting EYG's JSON IR is an option if source generation is unreliable. MCP is another possible adapter to the same bot operations.

## Constraints and open questions

Mods operate within deterministic lockstep simulation constraints and cannot directly read network or file input. Commands arrive through RCON; results can use RCON output or files in `script-output` through `helpers.write_file`. Avoid expensive scans on every tick: heavy per-tick work reduces updates per second (UPS).

Potential observability options include Graftorio-style file export to Prometheus and `--benchmark-verbose` timings. These are research options; verify their setup and suitability before adopting them.

Before expanding the action vocabulary, resolve:

- Which exact game version and mod API will be supported?
- How are the character's initial inventory, spawn position, death, and respawn handled?
- How do actions report acceptance, completion, failure, and cancellation?
- How are pending actions and host continuations reconciled after a reconnect or server restart?
- What state and higher-level primitives does the model need to act effectively?

## Prior art and model interface

The Factorio Learning Environment (FLE, NeurIPS 2025) is a prior-art research lead, reported to provide a Python REPL API over RCON with MCP support and to target Factorio 1.1.110 rather than 2.0. Its version compatibility and findings have not been independently checked here; treat these as research leads.

Borrow candidate primitives such as connecting entities with belts and finding the nearest resource. Reported FLE findings suggest that good primitives, textual state, and self-correction were more useful than vision, which worsened results. Investigate those findings when choosing the effect vocabulary and the state presented to the model.

## Implementation sequence

1. Install and pin the headless server, create a dedicated save, and verify that ticks advance with no players connected.
2. Implement and test RCON authentication, packet handling, and a round trip to `game.tick`.
3. Load the mod; spawn, walk, stop, inspect, and build a furnace while observing from a game client. Check failed placement and insufficient inventory as well as success.
4. Add mining, crafting, inventory transfers, and pathfinding with consistent JSON results and action lifecycle semantics.
5. Connect EYG effect handlers or an MCP adapter, then test short model-generated plans with recorded action results.

## Appendix: untested code sketches

These sketches provide concrete starting points. The RCON client reads its password from a local environment variable. They are not implementations of the requirements above.

### Elixir RCON client

This sketch assumes one response packet, discards response IDs and types, and lacks authentication validation, length checks, and timeouts. In particular, investigate the possible extra empty packet before the authentication response. Resolve the protocol issues in the RCON client section before using it.

```elixir
defmodule Rcon do
  def connect(host, port, pw) do
    {:ok, s} = :gen_tcp.connect(host, port, [:binary, active: false])
    :ok = send_pkt(s, 1, 3, pw)
    {:ok, _} = recv(s)
    s
  end

  def exec(s, cmd) do
    :ok = send_pkt(s, 2, 2, cmd)
    recv(s)
  end

  defp send_pkt(s, id, type, body) do
    p = <<id::little-32, type::little-32, body::binary, 0, 0>>
    :gen_tcp.send(s, <<byte_size(p)::little-32, p::binary>>)
  end

  defp recv(s) do
    {:ok, <<len::little-32>>} = :gen_tcp.recv(s, 4)
    {:ok, <<_id::little-32, _t::little-32, body::binary>>} = :gen_tcp.recv(s, len)
    {:ok, binary_part(body, 0, byte_size(body) - 2)}
  end
end

s = Rcon.connect(~c"localhost", 27015, System.fetch_env!("FACTORIO_RCON_PASSWORD"))
Rcon.exec(s, "/sc rcon.print(game.tick)")
```

### Lua bot mod

This sketch omits mod metadata and lifecycle handling. It does not explicitly stop walking, validate all character accesses, establish reach checks, or protect inventory against failed entity creation. It also prints mixed plain-text and JSON responses directly from remote functions. The design requirements above take precedence over these shortcuts; the character API calls still need verification.

```lua
remote.add_interface("bot", {
  spawn = function()
    storage.c = game.surfaces[1].create_entity{
      name = "character", position = {0, 0}, force = "player"}
  end,
  walk = function(dir) storage.dir = dir end, -- "north", nil to stop
  pos = function()
    local p = storage.c.position
    rcon.print(helpers.table_to_json{x = p.x, y = p.y})
  end,
  build = function(name, x, y)
    local c = storage.c
    if c.get_item_count(name) < 1 then return rcon.print("no item") end
    if not c.can_place_entity{name = name, position = {x, y}} then
      return rcon.print("can't place") end
    c.remove_item{name = name, count = 1}
    c.surface.create_entity{name = name, position = {x, y}, force = c.force}
    rcon.print("ok")
  end,
})

script.on_event(defines.events.on_tick, function()
  local c = storage.c
  if c and c.valid and storage.dir then
    c.walking_state = {walking = true,
                       direction = defines.direction[storage.dir]}
  end
end)
```

Example invocation:

```text
/sc remote.call("bot","build","stone-furnace",3,4)
```
