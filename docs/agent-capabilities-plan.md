# Plan: agent capabilities, policies and bots

Status: draft plan, 2026-11-09. Nothing here is implemented yet unless stated.

## Goal

An agent plays Factorio only by submitting EYG programs to a runner. The runner,
not the program, decides what each program may do. Examples:

- **Observer:** inspect and analyze the factory, change nothing.
- **Builder:** place new buildings, never tear down or repurpose existing ones.
- **Maintainer:** refuel, reload and restock, but not build or remove.

Bots are agent-written programs that run repeatedly to keep part of the factory
working, each under a fixed capability profile.

Factorio is the narrow first case of a broader idea: replacing a general agent's
shell, Python and grep tool calls with typed EYG effects under the same kind of
runner. The game is a good testbed because its effects are few and well defined,
the world is observable, and success is measurable (for example, plates grow).

## What already exists

- **Effect grants.** `mix factorio.eyg --effects A,B,...` selects effects before
  evaluation. A program that uses any other effect fails the type check and never
  runs, so nothing reaches the game.
- **28 typed effects:** 12 read-only observations, 5 long-running actions
  (`WalkTo`, `Mine`, `Craft`, `HandCraft`, `MineObject`), 9 immediate changes
  (`Build`, `BuildUnderground`, `Rotate`, `Transfer`, `ConnectPower`, `SetRecipe`,
  `SetChestLimit`, `Research`, `SpawnBot`) and 2 controls (`Wait`, `Stop`).
- **Per-run limits:** at most 100 effects, 300 s default and 600 s maximum wall
  time, a 12 KB final result.
- **Named characters:** `--bot NAME` binds a run to one of up to eight
  characters, each with its own inventory and action history.
- **Safety rules:** confirmed receipts, no automatic retries, one best-effort
  `stop` for an unconfirmed action, and an exclusive trace per run.
- **Program inputs:** `Eyg.Evaluator` accepts an `inputs` map bound as `input`,
  but `mix factorio.eyg` does not expose it yet.

## The gap: effect grants are too coarse

Leaving out `MineObject` stops direct removal, but other granted effects can
still damage existing factory parts:

| Effect | How it can undo existing work |
| --- | --- |
| `Transfer` | Takes fuel, ammunition or stock out of machines, turrets and chests |
| `Rotate` | Reverses an inserter or belt and breaks a line |
| `SetRecipe` | Repurposes an assembler |
| `Build` | Places a belt or building that blocks an existing route |
| `ConnectPower` | Joins networks that were deliberately separate |

Profiles therefore need a second layer that checks each call's arguments, not
only which effects are allowed.

## Plan

### 1. Named capability profiles

Add `--profile NAME` to `mix factorio.eyg`. A profile is an effect grant plus a
set of per-call policies (step 2), defined in Elixir alongside the contracts.
`--effects` remains and can only narrow a profile, never widen it. The trace's
start event records the profile and the resolved effects.

Starting profiles:

| Profile | Effects | Policies |
| --- | --- | --- |
| `observer` | All `Inspect*` effects | None needed |
| `maintainer` | Observations, `WalkTo`, `Transfer`, `Wait`, `Stop` | `Transfer` may only give fuel or ammunition, or take from the bot's own supply chests |
| `builder` | Observations, movement, `Craft`, `HandCraft`, `Build`, `BuildUnderground`, `ConnectPower`, `Rotate`, `SetRecipe`, `Transfer`, `Wait`, `Stop` | `Build` only inside allowed areas; `Rotate`/`SetRecipe` only on entities this bot built; no taking from existing machines |
| `full` | Everything | None |

### 2. Per-call policy layer

After a handler validates arguments and before it calls the game, the host
evaluates the profile's policies for that effect. A denied call:

- never reaches the game;
- resumes the program with a catchable `Error("policy denied: …")`, like a
  confirmed game rejection, so the agent can adapt;
- writes a `policy_denied` trace event with the rule and arguments.

Policies live outside the program, so the program cannot change them. Candidate
rules, from simplest to hardest:

1. **Areas:** allow or deny rectangles in half-tile coordinates (for example,
   never touch the wall line or the bus).
2. **Transfer direction and items:** give-only for turret ammunition and machine
   fuel; item allowlists.
3. **Ownership:** effects that alter an entity (`MineObject`, `Rotate`,
   `SetRecipe`, taking via `Transfer`) only on entities the same bot built.
   This needs step 3.

Upstream EYG documents this kind of control in its
[effect access policies](https://eyg.run/guides/effect-access-policies) guide,
and its `overlay` agent uses per-effect gate functions that pass, deny or rewrite
a call. The same shape fits here.

### 3. Ownership tracking in the mod

When `Build` or `BuildUnderground` succeeds, the mod records the building's
`unit_number` with the bot name in `storage`. `InspectEntity` and `InspectMachine`
expose a `built_by` field (empty for entities that existed before tracking).
Ownership policies use that record; pre-existing entities count as protected
under `builder`.

Mod changes follow the usual workflow: isolated Lua tests, deployment through the
Elixir Port owner, then validation through typed EYG on the headless server.
Storage stays bounded and entries are removed when an entity is mined or
destroyed.

### 4. Bots as scheduled short runs

A bot is a program, a schedule, a named character, a profile and a small state
record. A scheduler (one Elixir process per bot) runs the program on its
schedule, passes the previous run's `state` result field in as `input`, and keeps
each run's result and trace.

Rules:

- Never overlap runs for the same character.
- A failed run with an unconfirmed outcome pauses the bot and flags it for a
  person; it is never retried automatically.
- Ordinary program errors are recorded; repeated errors pause the bot.
- Add `--input FILE` to `mix factorio.eyg` so the same mechanism works by hand.

Each run stays short, bounded and auditable. Long-lived runs would need durable
continuations, which are out of scope for now.

### 5. Agent loop

The agent submits a program and names a profile it is allowed to use; the runner
returns the result and a trace summary. A person, not the agent, grants profiles.
An agent-facing wrapper (CLI or tool) comes after steps 1 to 4 work by hand.

## Milestones

1. **Profiles:** `--profile`, the four profiles as effect grants only, trace
   field, tests. Host-only, no mod change.
2. **Policies:** the policy layer with area and transfer rules, the
   `policy_denied` event, fake-backend tests for allowed and denied calls.
3. **Ownership:** mod tracking and `built_by`, ownership rules, Lua and Elixir
   tests, headless deployment and EYG validation.
4. **Bots:** `--input`, the scheduler, and one example bot. Start read-only (an
   ammunition and fuel report), then a maintainer bot that reloads turrets.
5. **Review:** decide what carries over to the general agent runner.

## Open questions

- Should a policy denial be a catchable `Error` (proposed) or stop the run?
- Ownership per bot or per run? What happens when a bot rebuilds an entity it
  previously removed?
- Should profiles and policies be Elixir code, or EYG programs themselves, like
  upstream `overlay`'s policy configuration?
- Schedule by game ticks or wall time? A paused game stops ticks but not clocks.
- Bots share machines and chests with no reservation. Is "one bot per area" a
  sufficient convention, or is a reservation effect needed?
- Is 100 effects per run enough for a useful maintenance bot?

## Not in scope yet

Durable continuations, pathfinding, the general agent integration and
multi-host control.
