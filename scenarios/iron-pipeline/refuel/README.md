# Autonomous coal supply — existing save

**Already constructed and commissioned. Do not rerun the construction stages.**
These are save-specific, inventory-backed EYG programs, not retryable blueprints
or a fresh-save bootstrap. Inspect the world and prior trace after any failure.

## Physical layout

- Reuses the coal drills at `(58,18)` and `(60,18)`, both now facing south.
- A continuous 184-belt chain carries their coal past two drill-fuel inserters,
  then through a serpentine beside the four iron lanes.
- Each iron lane has three additional burner inserters: one fuels its drill,
  one fuels its furnace, and one fuels its original plate-output inserter.
- Total: 14 coal-feeding inserters. They take their own fuel from the same coal
  stream. All pickup/drop targets were confirmed through `InspectEntity`.
- The path avoids the original wooden chests at `(30.5,-38.5)` and `(31.5,-37.5)`.
  `route.json` records every belt in integer half-tile coordinates.

The two coal drills automatically refuel from their own output stream. No bot
transfers or background maintenance process are required. Coal/iron deposits are
finite, and output chests still need room. Filling upstream fuel buffers delays
initial delivery to downstream lanes; allow the long belt time to fill.

## Completed construction stages

1. `plan.eyg`: read recipes, inventories, resources and machine connections.
2. `pilot.eyg`: collect 280 existing iron plates, craft 14 feeder inserters,
   and prove a feeder can target the lane-25 output inserter.
3. `survey.eyg`: walk/inspect the long route, without changing terrain.
4. `craft.eyg`: craft 92 gears and 92 belt batches (184 belts).
5. `build-belts-01.eyg` through `build-belts-06.eyg`: place the single chain in
   bounded phases, each stopping on its first rejected placement.
6. `build-inserters.eyg`: install the remaining 13 feeders and inspect all 14
   pickup/drop connections.
7. `activate.eyg`: rotate both coal drills south and retain only three coal in
   each drill; collect surplus real coal into the bot. They then automatically
   replenished to five, demonstrating the feedback loop.

No items were granted. Construction used existing plates and ordinary crafting.
Execution traces, including the rejected preflight request (no mutation), are
preserved in the ignored `tmp/refuel/` directory.

## Safe checks

With the normal worker/RCON environment configured:

```sh
mix factorio.eyg --effects InspectBot,InspectEntity scenarios/iron-pipeline/inspect.eyg
mix factorio.eyg --effects InspectEntity,Wait scenarios/iron-pipeline/refuel/commission.eyg
mix factorio.eyg --effects InspectEntity,Wait scenarios/iron-pipeline/refuel/verify.eyg
```

`commission.eyg` observes fuel in both coal drills and all twelve iron-lane
machines, waiting at most four 3,600-tick intervals. `verify.eyg` requires fresh
plate growth in every output chest over 3,600 ticks. Both are read-only except
for waiting. `settle.eyg` is a one-interval diagnostic.

Live verification succeeded without any further bot fuel transfers: all fourteen
machine fuel inventories were positive, the source drills were working, and the
four chests grew by 15, 15, 15 and 48 plates over 3,600 ticks. The last lane was
also draining its earlier furnace backlog.
