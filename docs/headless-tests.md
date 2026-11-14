# Offline native engine tests

Run explicitly with the pinned Factorio **2.1.24** headless distribution:

```sh
mix test --include headless test/headless_test.exs
```

The executable defaults to `factorio/bin/x64/factorio`. For another unpacked
installation, set `FACTORIO_HEADLESS_BINARY` to its real executable; its
`../../data` directory must contain the bundled `quality` and `recycler` mods.
No graphical client, account credentials, live-server access or playing-world
research progression is required. Missing/incompatible installations fail the
opt-in test rather than silently skipping it. Default `mix test` excludes both
`:headless` and the separate legacy `:live` probe.

## Isolation and lifecycle

The harness creates a new, exclusive directory in the OS temporary directory,
copies the production mod and the test-only scenario package, and supplies its
own config and mod list. The read-data directory is the headless distribution;
all writable paths point into scratch space. Quality/recycler are enabled, while
Space Age and elevated rails are disabled. Base 2.1.24 and the fixture scenario's
explicit test argument are checked before fixture creation.

It invokes only `--test-scenario factorio-control-native-tests/integration`, not
`--start-server`, `--test-save`, `--start-server-load-latest` or `scripts/server`.
No network listener, RCON connection, save path, live password, `.envrc` loading or
playing-world fixture is involved. The fixture mod has test-only data prototypes but no ordinary-save control
script, and is never linked by the normal server launcher. Its seeded items,
recipe unlocks and machine states exist only inside this fresh offline test.
These are trusted test fixtures, not gameplay effects or an OS security boundary.

`FactorioControl.Server` owns the one-shot process through an Elixir Port.
`await_exit` waits for the actual OS exit status, including immediate failures;
a timeout retains ownership. The normal stop path is used on failures, with no
forced kill, automatic retry, restart, or deletion of uncertain state. The engine
also has a 600-tick limit, but exit status 0 alone is insufficient: the test must
produce its suite marker and all expected completion records. Assertion failure
stops the native suite immediately and calls `script.finish_test(false)`.

Use a local filesystem for the OS temporary directory (`TMPDIR` where needed).
Factorio's temporary scenario-script permissions can be incompatible with shared
virtual/FUSE project filesystems. Once the process exits, the harness copies its
sources, configuration, manifest, logs and results into a unique
`tmp/headless-<id>` directory in the checkout, then removes the owned scratch
copy. Failures retain evidence too; the directory is printed before launch.

## Native cases

The scenario invokes the real `bot.request` mod interface and asserts real engine
state, not mocked inventory behavior:

- Transport inspection across base, fast and express tiers plus three genuine
  fixture-defined transport prototypes, at all five entity qualities. Every
  native line is reported; direction and mixed item qualities/counts are checked
  against unchanged before/after engine snapshots. Ghosts, unrelated entities,
  unknown prototypes, missing targets and out-of-range points are rejected.
- Entity/machine diagnostics across all five entity qualities: chest/logistic
  storage, machine inputs/outputs/modules, and quality-scaled health. Queries
  preserve contents/state and do not broaden mutation targeting.
- Inspection ambiguity and enemy-inventory guards, reach-independent entity
  inspection versus the machine inspector's 64-tile limit, and NPC/player-owned
  corpse privacy with off-grid proximity lookup.
- Exact selection and round trips at normal, uncommon, rare, epic and legendary
  qualities; legacy normal-quality receipt compatibility.
- Missing-quality and invalid-quality rejection without substitution.
- Partial-capacity rare transfers reporting the actual moved count.
- Partially used ammunition retaining its remaining rounds.
- Blueprint labels, contents, entity tags and item identity.
- Rare armor retaining uncommon equipment and stored energy.
- Damaged stacks retaining health.
- All five logistic chest types: storage observations, normal/rare round trips,
  native bars and partial capacity.
- Machine module slots: exact qualities, partial capacity, inventory observations,
  same-recipe safeguards, removal followed by recipe changes, non-module/missing
  inventory rejection, and incompatible productivity modules in beacons.
- Ownership/reach guards and hidden enemy module contents.
- Dry fluid-capable assembler-2 and assembler-3 recipe changes.
- Input, output and module inventory guards, including same-recipe no-ops.
- Native craft/productivity progress and recipe-lock guards.
- Actual lubricant residue preserved on rejection, followed by a successful item
  recipe change after explicit fixture draining.
- Unsupported fluid/category recipes and locked recipe rejection.

The fixture lives under `test/fixtures/headless/`; all artificial state setup is
confined there. No test-only remote methods or item-grant effects are added to the
production mod.

## Typed EYG conformance

Each native method request and real response is recorded in
`script-output/native-effects.jsonl`. After the engine exits, the Elixir test
replays transfer, recipe, chest-limit, inventory-inspection and transport receipts through
actual typed EYG programs,
asserting exact request equivalence, acceptance/errors, bounded moved counts,
quality acknowledgement, returned coordinates and inventory contents. Every replay has its own `.eyg` source and JSONL trace.

This checks the engine/mod boundary and native-receipt compatibility with the
production EYG host. It is **not** a simultaneous EYG-to-RCON-to-engine test;
normal protocol and fake-backend EYG tests remain separate. No bespoke offline
network bridge or substitute interpreter is introduced.

Artifacts include `manifest.json` with copied-source SHA-256 hashes,
`port-output.log`, copied mod/scenario source,
`script-output/native-results.json`, native receipts, EYG sources/traces, and
`verification.json`. Keep the directory when investigating a failure; never
resubmit uncertain playing-world mutations to reproduce a fixture assertion.
