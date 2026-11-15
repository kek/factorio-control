# Fresh-world bootstrap — constructed layout

This layout belongs to the fresh default world created from
`fresh-start-20261115T212752Z-5eee384f.zip`. Earlier iron-pipeline, expansion and
resupply scenarios describe the archived world. **Do not replay their construction
programs here.** `layout.json` records confirmed placements in half-tile units.
Construction sources and exclusive typed EYG traces are retained in ignored
`tmp/fresh-base/`; they are historical evidence, not safe retries.

## Production and power

- Two electric drills at **(8.5,22.5)** and **(12.5,22.5)** feed stone furnaces
  at **(8,20)** and **(12,20)** directly. Both were observed working, powered,
  and dropping into their respective furnaces. The full-health original burner
  drills were mined normally and remain in the bot inventory.
- Coal drills **(10,-44)** east and **(12,-44)** west feed each other. Both
  grew from three starter coal to 50 without additional bot fuel deliveries.
  Waiting for destination space at 50 is expected; coal export is still manual.
- Copper drill **(46,-46)** feeds furnace **(46,-44)**. At verification the
  furnace held 100 plates and 70 ore and was full, not broken.
- Offshore pump **(-41.5,-6.5)** faces west. Water passes through
  **(-40.5,-6.5)** to boiler **(-38.5,-7)**; steam passes through
  **(-38.5,-8.5)** to engine **(-38.5,-11.5)**. One engine currently powers the
  lab, assembler, inserters and electric iron drills on network 1.
- Lab **(-33.5,-10.5)** completed gun turret, stone wall, automation and
  electric mining drill research using normally crafted red packs. No research
  flags, inventory grants or playing-world fixtures were used.

## Iron delivery and ammunition

Two powered output arms, **(7.5,18.5)** and **(11.5,18.5)** facing south, take
plates from the furnaces and drop north onto a westbound belt at **y=17.5**.
The belt turns north at **(-21.5,17.5)** and ends at **(-21.5,-8.5)**.
There are **60 belt tiles**. Intake arm **(-22.5,-8.5)** faces east and drops
into the wooden buffer at **(-23.5,-8.5)**.

The buffer feeds magazine assembler **(-26.5,-8.5)** through arm
**(-24.5,-8.5)**. Output arm **(-28.5,-8.5)** feeds the power guard directly;
both arms face east. Fourteen poles connect the production sites and workshop.

The workshop's iron buffer rose **2 → 29 → 55** over 6,016 ticks without a bot
plate delivery. Pickup/drop inspection confirmed both furnace-to-belt links
and the belt-to-chest link. The power guard was explicitly emptied by recovering
its actual ammunition, then reloaded to **10 magazines** through the machinery,
without another bot ammunition give. A full gun/output buffer normally pauses
magazine production; this preserves iron for construction in the shared chest.

## Defense and latest observations

| Guard | Health | Magazines |
| --- | ---: | ---: |
| Power/workshop **(-30,-8)** | 400/400 | 10, automatically reloaded |
| Iron **(14,19)** | 400/400 | 18 |
| Coal **(16,-42)** | 400/400 | 18 |
| Copper **(46,-42)** | 400/400 | 8 |

These are guarded posts, not a sealed perimeter or a cleared enemy map.
Only the power guard currently has an automatic ammo feed. Other guards still
need physical resupply. Reinspect before relying on historical counts.

**Coal delivery remains the next priority.** The boiler, iron furnaces and
copper machines still have finite manually delivered fuel. Last verified boiler
stock was 21 coal; iron furnaces had 26/23, copper furnace 36 and copper drill 6.
The bot is parked near **(16,17)** under the iron guard, full health and idle.
Do not leave the simulation running unattended through long development breaks.
Save-stop through the host's Port owner when it cannot be serviced.

## Verification and continuation

- `tmp/fresh-base/iron-feed-belt-01-20261115.jsonl`: belt delivery baseline,
  two later samples and all three loader connections.
- `tmp/fresh-base/research-electric-01-20261115.jsonl`: normal research setup
  and automatic reload using belt-supplied iron.
- `tmp/fresh-base/electric-iron-upgrade-02-20261115.jsonl`: two ordinary mining
  recoveries, new electric drill crafts/placements and working power states.
- `tmp/fresh-base/electric-milestone-verify-01-20261115.jsonl`: all four guards,
  production, power, fuel and both electric drill drop targets.
- `tmp/fresh-base/park-bot-01-20261115.jsonl`: final actor health/inventory/action.

Inspect the whole layout from approximately **(16,-10)** to keep every machine
inside the 64-tile machine-observation limit. Inspection programs must remain
read-only; moving to that observation position is a separate explicit action.
Next: a self-fueling coal export lane to the boiler, then furnace/copper fuel
branches and expanded ammo distribution. Survey new routes through typed EYG
before construction. Preserve existing metadata and do not mine/rebuild damaged
machines as a health refresh.
