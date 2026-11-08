# Starter bus, workshop and defenses — base build

This is a **constructed, save-specific factory**, not a fresh-save bootstrap.
Construction, failed preflights, recovery and commissioning sources/receipts are
preserved under ignored `tmp/expansion/`. Do not execute historical construction
stages against the completed factory. The enclosure now blocks some old waypoint
routes; use the guarded service opening.

## Installed workshop

`layout.json` is the audited base layout, in integer half-tile coordinates. The
[current resupply overlay](../resupply/README.md) adds continuous copper supply,
ten automated ammunition feeds and their power connections:

- Two bus lanes: iron at x=47.5 and copper at x=51.5.
- Powered extraction from the iron chests at `(29.5,-37.5)` and `(37.5,-37.5)`.
  The other two iron lanes remain reserve storage.
- Splitter branches and explicit underground crossings feed three assembler-1s
  at x=55.5, y=-30.5/-22.5/-14.5, making gears, magazines and belts respectively.
- A separate gear belt splits between gear storage and the belt assembler.
- A steam plant, small-pole network and two labs supply power/research.
- Output chest bars limit each workshop product to one inventory slot. The
  buffers reached 100 gears, 100 magazines and 100 belts, were used for further
  construction/arming, and refilled from the iron bus.

The base build initially fed the copper lane from a chest at `(51.5,-35.5)`,
delivering to `(54.5,-6.5)`. Automatic resupply now enters at `(51.5,-27.5)`
from a rebuilt, fueled and guarded outpost. The original upper buffer remains
outside that automatic feed; see the resupply overlay for the current routes.

## Defenses and access

The **bus/workshop enclosure** runs from x=45.5 to 64.5 and y=-38.5 to -3.5:

- 106 stone walls; the two omitted west-side tiles form the service entrance
  at `(45.5,-18.5)` and `(45.5,-17.5)`.
- Four corner turrets plus the east-side turret cover this enclosure and opening.
- Four additional turrets guard power, coal, iron and stone production: nine
  armed turrets in the base build; resupply adds a tenth copper guard. The mining,
  lab and power areas are not all inside
  this wall rectangle.
- The iron feed crosses the west wall through normal underground belts. One
  small pole was moved to keep the wall line clear without breaking power.

The opening is turret-covered, **not a researched gate or sealed wall**. Guns
are loaded from real magazine stock. The workshop automatically produces more
ammunition into storage. The resupply overlay now distributes it by belts,
balancers and powered loaders to all ten guards. Check ammunition, fuel, health
and remaining deposits before leaving the factory unattended.

## Resource production and recovery

Four coal drills feed the fuel network; source drills and the boiler were
observed automatically replenishing to five coal. The iron plant was rebuilt
under turret coverage after its original machines disappeared. Damaged pump,
boiler, steam connection and fuel delivery were also rebuilt.

Six brick lanes were constructed/restored under the stone guard. Five mining
footprints were producing at the last inspection; the lower-left drill has
`no_minable_resources` and requires relocation or expansion. Output storage is
limited to two slots per brick chest. Deposits are finite; inspect actual fuel,
inputs, remaining resources and output room rather than replaying a build phase.

The mod-owned character died during expansion. Its actual NPC corpse inventory
was recovered through the typed interface after an empty respawn. No replacement
items, research flags or administrator material fixtures were used.

## Safe checks

With the normal worker and RCON environment configured:

```sh
mix factorio.eyg --effects InspectBot,InspectMachine,InspectEntity scenarios/expansion/inspect-core.eyg
mix factorio.eyg --effects InspectEntity scenarios/expansion/brick-stock.eyg
mix factorio.eyg --effects InspectMachine scenarios/expansion/verify-walls-1.eyg
mix factorio.eyg --effects InspectMachine scenarios/expansion/verify-walls-2.eyg
```

The two wall checks inspect 53 exact positions each, staying below the 100-effect
run budget. The post-save checks found all 106 present; one wall at `(63.5,-38.5)`
had combat damage (302/350). The east-side turret at `(62,-24)` was 325/400 and
remained armed. Turret health and ammo are live state: damage must be repaired
normally, not mined
and rebuilt as an implicit health refresh. Count-only handling rejects damaged
building stacks.

See [the expansion capability boundary](../../docs/expansion-effects.md) for the
new controls and safety restrictions. All gameplay inspection and mutations were
performed through typed EYG effects on the headless server.
