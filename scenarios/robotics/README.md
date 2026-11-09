# Progress toward construction and logistic robots

Save-specific work, controlled by the named `robotics` character. Construction is completed; do not replay historical mutation programs in `tmp/robots-progress/`.

## Completed

- Electric mining drills and steel processing researched normally.
- A red-science assembler at **(35.5,-24.5)** receives copper from the existing copper belt. A chest at **(38.5,-24.5)** supplies gears (initially 175); gears still need restocking.
- The output chest at **(35.5,-21.5)** feeds a belt route into the southern lab at **(43.5,-25.5)**. An east-facing underground pair at **(39.5,-22.5)/(41.5,-22.5)** crosses the existing ammunition conveyor without mixing items.
- All five science-system inserter pickup/drop targets were confirmed. Red science grew from an empty output chest; after the lab route was built, green-science research advanced **74 → 128 / 1000 over 1,207 ticks**, with no bot deliveries during that interval. The lab and assembler were working, with **91 gears** still in the supply chest.
- Productive iron reserves at **(25.5,-37.5)/(33.5,-37.5)** now feed the active bus chest at **(29.5,-37.5)** through two powered long-handed inserters. Source stocks fell while the destination rose; the magazine assembler was subsequently observed working with iron input.

## Remaining

Green-science research is running. Electric drills are unlocked but have **not** been crafted or installed; exhausted burner footprints at (29,-42)/(37,-42) still need replacement. Survey actual ore and preserve the coal belt crossings before construction. Then automate gears/circuits, steel and green packs, followed by oil and blue science for robotics. This save's requester/buffer-chest logistic-system research additionally requires space science.

A tree-mining attempt near (47.438,-46.875) failed with `target_lost`; no wood was collected. Inspect before a corrected attempt or capability fix. The robotics character is safely back near (39.4,-24.0), healthy and idle.

## Read-only inspection

From a configured checkout and running server:

```sh
mix factorio.eyg --bot robotics --effects InspectTechnology,InspectMachine scenarios/robotics/inspect.eyg
```

Coordinates above are ordinary tiles; EYG inputs use half tiles. This check does not move, craft, transfer or select research. It assumes the actor remains within the inspection range.

Sources, failures/recovery receipts, and exclusive live traces are retained in `tmp/robots-progress/`. No administrator materials or research grants were used.
