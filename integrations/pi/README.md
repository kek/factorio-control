# Gameplay-only Pi adapter

The model calls **`factorio_eyg({purpose, program})`** directly (`purpose` is
optional for compatibility with older calls). This opt-in extension
exposes just that tool and blocks all other model tool calls, even if another
setting enables them. The trusted implementation spawns a fixed `mix` argv with
JSON stdin, never a shell or model-provided filenames/flags. It owns artifact
creation; the model does not call `write` first.

## Operator setup

Prepare dependencies and run `mix compile` in the checkout **before** starting
this mode. Compilation output is not adapter protocol output. Keep the playing
server under its existing Elixir Port owner; this tool never starts a server.
Supply the password through the operator environment, not a prompt or committed
configuration. Set these in the environment of the **Pi process**:

- `FACTORIO_EYG_PROJECT`: absolute checkout path on the machine running Pi.
- `FACTORIO_RCON_PASSWORD`: existing server credential.
- `FACTORIO_RCON_HOST`: defaults to `localhost`.
- `FACTORIO_RCON_PORT`: defaults to `27015`.
- `FACTORIO_BOT`: defaults to existing actor `default`.
- `FACTORIO_EYG_ALLOW_RESPAWN`: defaults to disabled. Set exactly `true` to
  explicitly authorize typed empty-actor creation/recovery for the configured bot.
- `FACTORIO_EYG_ARTIFACT_ROOT`: defaults to `tmp/factorio-eyg` under the checkout.
  Use a trusted, private parent directory.

Optionally export `FACTORIO_EYG_MEMORY_ROOT` to a trusted private directory
specific to the current world/save. Reuse it across sessions for that world only;
use a different directory for a new/reset save. For example:

```sh
export FACTORIO_EYG_MEMORY_ROOT="$HOME/.local/state/factorio-control/world-name"
```

From the checkout, start a separate gameplay session:

```sh
FACTORIO_EYG_PROJECT="$PWD" pi \
  --no-extensions --no-mcp \
  --tools factorio_eyg \
  --skill ./skills/factorio \
  -e ./integrations/pi/index.js
```

Then explicitly load the gameplay instructions with your request:

```text
/skill:factorio Develop the base until logistic and construction robots are produced, a roboport network is powered, and a logistic delivery and construction job are verified. Choose and execute the intermediate milestones yourself.
```

`--skill` registers the repository skill, which lives outside Pi's standard
skill discovery directories. Registration advertises the skill but does not
inject its full instructions; `/skill:factorio` expands them into the conversation
without granting a filesystem tool. Use the skill command when starting gameplay
so the agent receives the workflow and completion criteria.

The inline project path refers to the checkout in the shell launching Pi; the
other operator environment variables above must still be set.

The extension enables only `factorio_eyg` at session start and before each run.
There is no model-callable mode switch. Exit to an ordinary development session
for missing capabilities, deployment, credentials or lifecycle management.
No global Pi settings are changed by installing these files.

**Execution location:** this extension's child runs wherever Pi runs. It does
not delegate through Gondolin. Configure the checkout and endpoint for that
actual machine; guest paths/endpoints are not host paths/endpoints. Do not load
this alongside a general-purpose execution extension and assume sandbox routing.

## Compact tool display

Each call should include a short `purpose`, such as "Inspect science inputs" or
"Deliver furnace fuel". This model-supplied label describes intent, not a verified
outcome. It is presentation-only metadata, retained in Pi's tool-call transcript
but stripped before execution; it cannot alter grants, endpoints or the program.
The executor's private request still accepts only `program`.

Pi's supported `renderCall` and `renderResult` hooks render a compact tool row:

- The intention is visible while running; EYG source is hidden when collapsed.
- Finished rows show evaluation status and the artifact directory, without dumping
  schemas and inventory JSON into the default view. Evaluation completion is not
  a claim of gameplay completion.
- Errors, detected nested failures and recovery warnings remain visible collapsed.
- Use Pi's expand-tools shortcut (normally **Ctrl+O**, shown using the configured
  keybinding) to reveal the original EYG and complete result. No source or result
  is removed from model context, session history or retained execution artifacts.

Restart the isolated Pi session after extension changes. This uses Pi's native
expansion state rather than a separate UI or a new gameplay tool.

`index.js` is the Pi-loaded entry point and statically imports Pi's host-provided
`@earendil-works/pi-tui`. Do not install a separate TUI package in the checkout.
The dependency-free registration/validation code lives in `core.js` so offline
Node tests can import it without Pi. A dynamic TUI import inside the factory can
escape Pi's alias resolution and fail at startup even when mocked tests pass.

## Character equipment

`InspectEquipment` and `Equip` are granted gameplay effects. Inspection returns
installed armour/gun/ammunition slots and up to 32 candidate stacks in the bot's
main inventory, with slot indices, quality, health and remaining magazine rounds.
`Equip` transfers real stacks between an observed main slot and an empty equipment
slot; `direction` is `equip` or `unequip`, inventory is `armor`, `guns` or `ammo`.
Use `DescribeEffect` for exact schemas. No swaps or item grants are provided.
Native transfers preserve metadata, including armour grids and partial magazines.
Armour removal refuses inventory shrinkage that could displace carried items.
Equipping alone does not guarantee safe scouting; see combat controls below.

After deploying these Lua changes, restart the server through its existing
Elixir Port owner to load the mod, then restart the gameplay Pi session to load
the updated tool instructions and `/skill:factorio`. A graphical client may also
need restarting; client verification is not required. Never start a second server
or use live item-granting fixtures to test equipment. The isolated headless tests
exercise native equipment transfers and replay their receipts through typed EYG.

## Agent-written combat programs

`InspectCombat({radius:32})` returns local enemy IDs, positions, health, actor
health, and shootability with the currently selected gun (32 enemies maximum,
truncation reported). `Attack({unit_number:ID,gun_slot:1,ticks:60})` performs one
stationary engine weapon burst for 1–300 ticks. It requires actual equipped gun
and ammo, rejects friendly/neutral/cease-fire targets, and uses native range and
compatibility checks. The local target lookup is capped at 129 enemies within
64 tiles; it never substitutes another target. It shares the single-action slot.
Completion, cancellation, death or error clears firing. `Stop` cancels it.

The agent writes the tactical program: observe, choose targets, fire short bursts,
check health/ammo, retreat along inspected routes, and re-evaluate. No built-in
combat AI, instant damage, free ammunition or invulnerability is provided.
Simultaneous movement/firing is not supported yet. Burst completion does not
establish a kill; receipts report rounds consumed and target state, not kill credit.
After uncertain results, inspect state instead of replaying an attack.

The tested `scenarios/combat/burst.eyg` example demonstrates a health guard and
selection of one observed shootable enemy. Full skill instructions explain how to
compose bounded combat stages. The offline native suite verifies actual weapon
damage/ammo use and Stop cancellation, then replays receipts through typed EYG.
Deploy Lua changes with the existing Elixir Port owner's save/restart and restart
Pi to load the new tool instructions; no playing-world item fixtures are used.

## Empty actor recovery

`SpawnBot` already exists in the typed host/mod but is excluded from the gameplay
adapter by default. To authorize it, export this before launching a new Pi session:

```sh
export FACTORIO_EYG_ALLOW_RESPAWN=true
mix compile
```

This changes only the fixed grants selected by trusted operator configuration;
programs cannot enable it or select a different bot. The tool advertises it only
when enabled. No mod deployment or server restart is needed for this grant change.

After `InspectBot` confirms `no_character`, the agent may use
`SpawnBot({position:{x2:0,y2:0}})` with a known safe requested position in half
tiles. The mod searches nearby for a non-colliding position; that is not a
threat/safety assessment. Inspect the returned position, health and inventory.
An existing living actor is returned unchanged (`existing: true`), not teleported
or re-equipped. A replacement starts empty; the effect supplies no items and
never recreates lost inventory. Recover actual surviving NPC-corpse items only
through typed observations/transfers; leave player corpses alone.

After an uncertain spawn, inspect actor state and retained receipts before any
further attempt. Do not retry automatically. If recovery is disabled, checkpoint
the blocker and ask the operator; do not bypass the gameplay boundary.

## Goals and memory

Give the agent an outcome, not a construction script. It should choose intermediate
milestones and continue until acceptance criteria are verified or a concrete
blocker requires operator intervention. For open-ended play, ask it to keep
developing the base and choose the next useful improvement after each milestone.
Progress reports are not completion. Unsupported actions still require capability
development in a separate session.

With `FACTORIO_EYG_MEMORY_ROOT` set, the fixed typed effects additionally provide:

- `SaveCheckpoint`: append a structured world checkpoint (goal, milestones,
  verified state, pending work, hazards, evidence and game tick).
- `ReadNotes`: read the latest checkpoint or lesson proposal (`kind` is
  `checkpoint` or `lesson`, `limit` is currently exactly `1`). Results include
  a host-generated ID and a JSON text record. No arbitrary paths are accepted.
- `ProposeLesson`: append a reusable lesson with evidence for operator review.
  Proposals never modify skills, grants or safety instructions.

These are narrowly scoped note-storage effects, not general filesystem access.
Use `DescribeEffect` for exact schemas. Notes are untrusted, potentially stale
observations: reinspect the world, preserve uncertainty, and never replay actions
based on memory. The gameplay agent cannot promote its own proposals to authority.
Operators review proposals and apply justified skill changes in a development
session; no automatic approval/promotion is provided.

Storage is append-only: 1500 UTF-8 bytes per string field, 6000 encoded bytes per
note, 200 notes per kind. Reads return only the latest note to bound context.
Files have private permissions and writes are synced; write outcomes can still be
uncertain after interruption. Inspect notes before retrying. One controller may
write a world directory at a time; this is not a cross-process lease or an OS
sandbox. Use a trusted private parent directory (no symlinked/untrusted ancestors).
Operators must archive old notes when the quota is reached. Missing configuration
or quota exhaustion disables persistence, not gameplay. Existing traces continue
to retain note effect requests/results; do not put secrets in notes.

## Policy and protocol

The Elixir allowlist grants typed gameplay and observation effects, plus
`SpawnBot` only with the explicit operator opt-in above. It excludes
`ConfirmLuaConsole`, general shell/filesystem/network effects and imports.
Operator setup must supply an existing bot (or explicitly enable empty recovery)
and an already acknowledged save. New effects do not become granted automatically. Programs cannot change
endpoint, bot, paths, grants or limits. The tool accepts only `program` and
optional display-only `purpose`; the executor accepts only `program`.

- UTF-8 source: 1–48000 bytes; encoded request: at most 64000 bytes.
- At most 100 effects and 300 seconds per evaluation.
- Fixed host bounds, type checking and argument/result checks remain enforced.
- Each run retains `program.eyg` and synced `trace.jsonl` in a fresh private
  directory, including source hash, fixed grants, receipts and adapter result.
- Response: `{success,error,value,artifact_dir,recovery_required}`.
- A timeout, abort or lost response may leave gameplay partially completed.
  There are **no retries**. Inspect the world and receipts before further
  mutations; cancellation is not rollback. A killed process may leave only a
  partial trace and no terminal receipt.

Use `DescribeEffect({name:"Build"})` through EYG to obtain current argument and
result schemas without a filesystem tool. This host-local inspection does not
require a mod deployment. Tool instructions supply the syntax and effect list.
Start a gameplay session with `InspectSimulation` and `InspectBot`, not a mutation.

This is a model capability boundary, **not an OS sandbox**. Pi, trusted
extensions, user shell commands and operator configuration have process
privileges. The isolated invocation above avoids other extensions' execution
paths. It does not defend against a malicious operator or modified host code.
There is no cross-session bot lease: run only one controller for the named bot.

The upstream [overlay package](https://github.com/CrowdHailer/eyg-lang/tree/main/eyg_packages/overlay)
provides policies for the upstream overlay CLI's effects. It is not wired to this
repository's embedded evaluator. This implementation uses the existing typed
host contracts; adopting overlay is optional future work, not a prerequisite
for an enforced single-tool interface.

## Verification

```sh
mix test
node --test integrations/pi/*.test.js
```

To also exercise the actual Pi extension loader and real TUI components, set
`PI_EXTENSION_LOADER` to the absolute path of an installed Pi 1.6.0 package's
`dist/core/extensions/loader.js` and run the Node tests with Pi's supported Node
version (>=22.19). Without that variable the loader smoke test is explicitly
skipped; the remaining tests do not need Pi installed. The smoke test loads the
entry point, checks renderer registration, collapsed/expanded output and narrow
terminal widths without a model call or a game connection.

Tests use fake game/process backends and the real EYG parser/typechecker. They
verify denial before backend dispatch, fixed grants, source/trace preservation,
non-shell process invocation, limits, uncertainty handling and the Pi tool gate.
Live Pi loading and the initial read-only game observation must be checked in
the operator's isolated session; unit tests do not establish activation here.
