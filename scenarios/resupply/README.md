# Automatic copper and ammunition supply — completed save-specific build

These are physical belts, inserters and power connections. No background bot
service is required. Historical construction sources, failures, resumptions and
exclusive EYG traces are retained in ignored `tmp/resupply/`; do not replay them.

`layout.json` overlays the immutable base layout in `../expansion/layout.json`.
It records 620 new ground belts, 20 underground endpoints, three ammunition
balancers, 41 poles, the loaders and the rebuilt copper machines. Four offline
layout tests check rotated footprints, power reach and possible transport paths
from the supply heads to all ten guard pickups and the copper bus sink. These
are structural checks; live EYG observations establish actual contents/power.

## Copper

- The remote outpost at x=-68/-66 now has three coal-fed burner drills and three
  furnaces. Two destroyed drills and all three destroyed furnaces were replaced
  with normally crafted items. The surviving drill remains at **17/150 health**;
  it was retained without mining/rebuilding it into a repaired machine. Its
  footprint was exhausted by final verification, so **two lanes remain productive**.
  The upper furnace is idle for lack of ore; the other two were backed up with
  copper output when storage filled.
- Coal is extracted from the existing stone fuel perimeter at `(-0.5,-29.5)`.
  The westbound belt runs to x=-70.5, down to y=8.5, and around to the furnace
  fuel pickup column at x=-61.5. Drill feeders refuel themselves from coal.
- Six powered long-handed inserters feed furnace fuel across the copper conveyor
  and extract copper plates. The pole chain is connected to the existing steam
  grid; each of the six consumers was observed with five coal without bot fuel
  deliveries to those machines.
- Copper returns north on x=-62.5, then east on y=-27.5 through three underground
  crossings. It joins the existing **southbound copper bus at (51.5,-27.5)**.
  The upper copper stub and original chest at `(51.5,-35.5)` are retained but are
  not automatically fed by this mid-bus connection. New consumers above the
  entry require a separate branch.
- The terminal chest `(54.5,-6.5)` grew from empty to **200 real plates**. Forty
  were subsequently collected for the ammunition balancers; it refilled to 200.
  All three new smelters were observed working with copper ore inputs.

## Ammunition

The magazine assembler's chest feeds a clockwise loop around the workshop.
Long-handed inserters reach across the walls; the west corners use short belt
buffers and relay arms to avoid the labs. Branches reach the iron, stone, coal
and power guards. A separate westbound ammunition line supplies the new copper
outpost guard at `(-62,10)`.

Three default splitters share supply between the southern outposts and workshop,
between the western outposts and northern loop, and between stone and copper.
This prevents a long empty branch from monopolizing all new magazines while its
buffer fills. The assembler continues producing as its output is withdrawn.

The original nine loaded turrets retained their ammunition. Their loaders were
checked for power, belt pickups and turret drop targets. Existing stocks above
the engine's normal refill threshold leave the arms waiting for destination
space. The new copper guard was commissioned by normally mining its **undamaged**
body, recovering its real ammunition, rebuilding it empty and observing its
inserter reload **five magazines without a bot ammunition transfer**, followed
by ten at the final check. A separate 37-cell northern-arc inspection confirmed
magazines circulating past the workshop’s upper loop.

One workshop turret already had combat damage (325/400). That damage and the
weak copper drill still require ordinary maintenance (repair/relocation of the
exhausted drill); resupply does not repair them.
Resource and power outposts remain guarded rather than fully walled.

## Read-only checks

Set the normal worker/RCON environment first. Coordinates are half tiles in
program inputs and thousandths in observations.

Near the factory centre (commissioning observation point: `(39.5,-15.5)`):

```sh
mix factorio.eyg --effects InspectEntity,InspectMachine,InspectTransport scenarios/resupply/verify-ammo.eyg
mix factorio.eyg --effects InspectTransport scenarios/resupply/inspect-northern-ammo.eyg
```

This checks the original nine loader connections; instantaneous pickup belt
counts are included. A moving packet can be between sampled tiles.

Near the copper outpost (for example `(-60.5,-0.5)`):

```sh
mix factorio.eyg --effects InspectMachine,InspectTransport scenarios/resupply/inspect-copper.eyg
```

The copper guard is included in this separate check because it is beyond the
64-tile observation limit from the factory centre. These checks do not move the
bot; an out-of-range response requires an appropriate observation position.

`InspectTransport` was developed with isolated Lua/fake-backend tests, deployed
through the Elixir Port owner as mod 0.2.7, and validated through typed EYG on the
headless server for ground belts, undergrounds and splitters. No graphical-client
verification was used for capability development or deployment.
