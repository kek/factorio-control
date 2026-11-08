---
name: factorio
description: Inspect and play Factorio through the factorio-control project's typed EYG effects. Use for moving the bot, mining, crafting, building, transferring items, diagnosing factories, and constructing or verifying production automation. Includes safe recovery after failed or uncertain actions.
compatibility: A factorio-control checkout, matching running server/mod, Elixir/OTP, Node 24+, and the shared portable EYG worker.
---

# Play Factorio

## Establish the game and capabilities

1. Establish the checkout, command execution environment and actual server
   endpoint before using commands. `localhost` refers to the environment running
   the command; it may differ from the environment running the server.
2. Locate the `factorio-control` checkout. Read its `AGENTS.md`, relevant README
   sections, `DESIGN.md` EYG boundary, and the contracts in
   `lib/factorio_control/eyg.ex` / `lib/factorio_control/eyg/expansion.ex`.
   Use those current contracts rather than treating this skill as an API schema.
3. Configure the server, credentials and evaluator using the portable setup below
   and the repository documentation. Keep deployment-specific paths, credentials
   and network bridges in user configuration outside the checkout.
4. Start with read-only EYG inspections: simulation, bot inventory/position/action,
   relevant machines, available resources, and recipes. Check game version, tick
   advancement, resource/list truncation, and whether another action is active.
   Existing save-specific scenario coordinates are leads, not fresh observations.
5. Use one bot controller at a time. The mod-owned bot is separate from the user's
   character. Do not move, mine, craft or transfer merely to answer a status query.

## Run factorio-control

Run commands from the checkout root. Use the game and Elixir/OTP versions
specified in `README.md` and a matching `mods/factorio-control` revision. The
headless distribution, saves, build output and local credentials are unversioned.

### Credentials, endpoints and evaluator

- Export `FACTORIO_RCON_PASSWORD` without printing it. If a trusted local `.envrc`
  supplies it, export assignments to child processes when loading that file:

  ```sh
  set -a; source .envrc; set +a
  ```

- EYG evaluation requires Node 24+ and an externally provisioned, compatible
  `portable-worker.mjs`. Set `EYG_WORKER=/absolute/path/to/portable-worker.mjs`
  or pass `--worker PATH`. The host does not install or build that evaluator.
  Its source location and provisioning procedure belong to the deployment.
- Factorio multiplayer defaults to **UDP 34197** and RCON to **TCP 27015**.
  `mix factorio.eyg` defaults to RCON at `localhost:27015`; select another
  endpoint with `--host HOST --port PORT`. RCON is unencrypted: keep it on a
  trusted private network or use a separately configured secure transport.

### Server ownership and safe startup

- Inspect listeners and process ownership before starting a server. Use **one
  Elixir Port owner per save**; do not launch a second server to troubleshoot a
  connection failure. EYG commands connect to an existing server.
- `mix factorio.server` owns the server process, streams its logs and uses
  `scripts/server` to start `factorio/saves/my-save.zip` with the linked project
  mod. Follow `README.md` for installation/save creation and `server-settings.json`
  for server settings. Confirm that the mod is enabled.
- Stop through `FactorioControl.Server.stop/1` in the owning Elixir session, or
  send SIGTERM to the verified `mix factorio.server` owner. Confirm save completion,
  game exit and released listeners before replacing that owner. Forced cleanup
  is not a reliable save boundary. Preserve old saves before recovering from a
  validated save/autosave after an interrupted shutdown.

Begin with a read-only simulation check, without starting another server:

```sh
mix factorio.eyg --effects InspectSimulation scenarios/simulation.eyg
```

For the existing iron layout, a further read-only check is:

```sh
mix factorio.eyg --effects InspectBot,InspectEntity scenarios/iron-pipeline/inspect.eyg
```

The second program assumes specific save coordinates. For a different world,
write inspections for freshly observed entities. Read scenario documentation
before using any construction program; completed construction is not a safe retry.

## Gameplay boundary

- Inspect and change the world **only through typed EYG host effects executed by
  EYG programs**, normally `mix factorio.eyg`. Grant only the effects needed by
  that phase with `--effects`.
- Do not use direct RCON/Lua, console commands, `Bot.call`, `mix factorio` gameplay
  subcommands, save-file inspection, or administrator scripts as alternatives.
  Reading source/contracts and analyzing captured EYG receipts is fine.
- Missing observations/actions require extending the typed host contract and
  bounded mod implementation, testing them offline, deploying, then using the
  capability through EYG. Do not approximate an unsupported action with cheats.
- Obtain materials from observed resources, existing inventories, and ordinary
  crafting. Never use administrator test fixtures to supply gameplay materials.
  Prefer fake-backend and isolated Lua tests; do not run item-granting live test
  fixtures in the user's playing world.
- Server installation/start/stop is separate lifecycle work and uses the Elixir
  Port owner (`mix factorio.server` / `FactorioControl.Server`), not a gameplay
  escape hatch. Do not force-kill the game to obtain a save or fix a failed action.
- Validate mod changes against the headless server and typed EYG interface.
  Do not inspect or verify graphical-client connectivity, integration, installation,
  enabled mods or source links unless explicitly requested. Client access must not
  block capability development or server deployment. Restart the server through
  the Elixir Port owner after Lua changes; mention a client restart only when
  relevant, without treating it as a verification step or deployment gate.

## Observe → plan → act in bounded stages

- Inspect threats and the research/power bootstrap before expanding pollution.
  Establish armed coverage early: the game keeps running during code development
  and long tool calls. Reinspect health and inventories after long gaps; enemies
  can destroy stock and machinery while the agent is doing other work.
- Inspect recipes before calculating materials. Craft intermediates explicitly:
  affordability covers directly available normal-quality ingredients, and craft
  counts are **recipe batches**, not necessarily output-item counts.
- Inventory stacks, resource amounts, reach, placement alignment and collisions
  constrain actions. Survey routes and obstacles through EYG before construction.
  Walking is not general pathfinding; use observed clear waypoints.
- Input positions use integer **half tiles** (`x2:51` is x=25.5). Observations use
  integer **thousandths** (`x_milli:25500` is x=25.5). Convert explicitly; odd-width
  starter entities use half-tile centers and even-width ones integer centers.
  For rectangular footprints, check X/Y parity independently after rotation.
- Use absolute cardinal directions. Inspect actual pickup/drop targets after
  placing or rotating drills/inserters; do not assume a visual direction implies
  the intended connection.
- Build a small pilot for uncertain machine interactions, then inspect confirmed
  connections before scaling. Validate planned belt adjacency, collisions and
  material counts from observed data before placing a long chain.
- Prefer physical automation—belts, inserters, buffers and self-fueling feedback—
  for requests to automate production. Clearly distinguish autonomous machinery
  from a one-off bot service run or a proposed background controller.

## EYG execution discipline

- Handle `Result` values explicitly. Chain dependent mutations so the first error
  stops later steps. Return plain JSON-compatible records with top-level
  `success` and `error`; raw `Ok`/`Error` variants cannot be returned as JSON.
  Inspect the result as well as the CLI exit status, especially for nested results.
- Current host bounds: **100 effects/run**, positions within ±2,000,000 half tiles,
  action/wait durations **1–3600 ticks**, and craft counts **1–100 batches**.
  Other count limits and supported items are contract-specific. Check the source.
- At normal speed 60 ticks = one second. A single `Wait` has a separate 65-second
  wall limit. Whole runs default to 300 seconds, maximum 600 seconds. Select both
  tick and wall deadlines to cover work plus overhead; leave the outer tool's
  timeout longer than the planned run. Split large jobs instead of overrun risks.
- Preserve each `.eyg` source and its worker version/hash alongside an exclusive
  per-run `--trace` path, preferably in ignored project `tmp/` storage retained
  across sessions. Snapshot a failed source before editing it. Never overwrite
  execution evidence or commit credentials, saves, binaries or private traces.

## Recover without duplicate mutations

- After a failed or uncertain action, stop the dependent plan. Inspect the trace's
  request, game-acceptance and terminal-action receipts, then inspect the bot,
  action ID, inventories and affected entities through EYG.
- Transport success is not game acceptance. A lost reply can leave an action
  accepted or partly completed. Neither an action ID nor reconnecting deduplicates
  a command. Never blindly rerun a phase, resubmit a mutation, or restart crafting.
- Confirmed preflight rejection with unchanged state can justify a corrected
  request. Partial mining/crafting, completed builds and transferred items must
  be accounted for before deciding the next action.
- If the actor dies, use the explicitly granted `SpawnBot` to create an empty
  replacement, then inspect and recover actual surviving NPC-corpse inventory
  through typed transfers. Never regenerate the old inventory or replay crafting
  to replace it. Player-owned corpses and unsupported metadata must remain alone.
- Use typed `Stop` when cancellation is appropriate and inspect its result. Host
  timeout cleanup is best effort; it does not establish that nothing happened.

## Verify and report

- Check fuel, input, output, status and connection targets separately. `full_output`,
  `no_ingredients`, and `no_fuel` require different fixes. Narrow or reposition
  truncated inspections; do not treat a truncated list as an empty/complete map.
- Record output baselines and observe fresh production over game ticks. Account
  for old furnace backlog and chest collections; total stored stock alone is not
  proof of new production. Check every intended lane, not just one representative.
- For fuel automation, verify replenishment in source and consumer machines after
  belt transit/startup buffering, without further bot fuel deliveries. A large
  initial fuel reserve can conceal a broken feedback loop.
- Report confirmed work, remaining material/blocking conditions, live verification
  interval/results, and source/trace locations. Treat scenarios as save-specific
  staged programs; never advertise completed construction as a safe retry.
