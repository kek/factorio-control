# Gameplay-only Pi adapter

The model calls **`factorio_eyg({program})`** directly. This opt-in extension
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
- `FACTORIO_EYG_ARTIFACT_ROOT`: defaults to `tmp/factorio-eyg` under the checkout.
  Use a trusted, private parent directory.

From the checkout, start a separate gameplay session:

```sh
pi --no-extensions --no-mcp --no-tools -e ./integrations/pi/index.js
```

The extension enables only `factorio_eyg` at session start and before each run.
There is no model-callable mode switch. Exit to an ordinary development session
for missing capabilities, deployment, credentials or lifecycle management.
No global Pi settings are changed by installing these files.

**Execution location:** this extension's child runs wherever Pi runs. It does
not delegate through Gondolin. Configure the checkout and endpoint for that
actual machine; guest paths/endpoints are not host paths/endpoints. Do not load
this alongside a general-purpose execution extension and assume sandbox routing.

## Policy and protocol

The fixed Elixir allowlist grants typed gameplay and observation effects. It
excludes `ConfirmLuaConsole`, `SpawnBot`, shell/filesystem/network effects and
imports. Operator setup must supply an existing bot and an already acknowledged
save. New effects do not become granted automatically. Programs cannot change
endpoint, bot, paths, grants or limits: only `program` is accepted.

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
node --test integrations/pi/adapter.test.js
```

Tests use fake game/process backends and the real EYG parser/typechecker. They
verify denial before backend dispatch, fixed grants, source/trace preservation,
non-shell process invocation, limits, uncertainty handling and the Pi tool gate.
Live Pi loading and the initial read-only game observation must be checked in
the operator's isolated session; unit tests do not establish activation here.
