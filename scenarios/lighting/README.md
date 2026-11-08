# Factory lighting — completed save-specific build

Eight normally crafted small lamps cover the workshop, labs, service entrance
and iron output line. One additional small electric pole connects the entrance
lamp to the existing grid. Lighting research consumed ten real red science packs
in the two existing labs; no material or technology grants were used.

Lamp centres in tiles: `(55.5,-8.5)`, `(54.5,-16.5)`, `(54.5,-24.5)`,
`(54.5,-32.5)`, `(44.5,-18.5)`, `(42.5,-23.5)`, `(38.5,-34.5)`,
`(28.5,-34.5)`. The new pole is at `(43.5,-19.5)`.
All eight were confirmed healthy, energized, `working`, and on network 5.
Lamps use their normal automatic day/night behaviour.

With the RCON environment configured, run this read-only check from near the
factory (the final bot position was approximately `(29,-30.5)`):

```sh
mix factorio.eyg --effects InspectMachine,InspectBot scenarios/lighting/inspect.eyg
```

Historical construction programs and exclusive traces are retained under ignored
`tmp/lights/`. Do not replay construction against the completed layout.
Mod 0.2.8 adds `small-lamp` to the inventory-backed `Build` allowlist; existing
reach, alignment, collision, quality and item-consumption checks still apply.
Restart a connected graphical client to load the updated mod when necessary.
