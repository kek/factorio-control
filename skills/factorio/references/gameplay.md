# Factorio player knowledge

Background game knowledge for planning. Figures were checked against the game
data shipped with the project's headless server (Factorio 2.1.24 `data/base`
and `data/space-age` prototypes) and against the official wiki. The project's
server runs **Space Age** (`space-age`, `quality`, `recycler` and
`elevated-rails` enabled), so this reference assumes Space Age; figures are for
Nauvis at normal quality unless stated. Research, modules, quality and other
planets change them. Confirm recipes with `InspectRecipe`, entity state with
`InspectEntity` and resources with `InspectResources` before computing
material lists or committing to a layout.

## Contents

1. Core mechanics and units
2. Planning formulas
3. What is available at game start
4. Fuel and burner phase
5. Mining and smelting
6. Belts, inserters and logistics
7. Power
8. Science and research order
9. Common recipes and ratios
10. Enemies, pollution and defence
11. Oil and fluids
12. Layout patterns
13. Diagnosing a stalled factory
14. Space Age
15. External resources

## 1. Core mechanics and units

- 60 ticks = 1 second at game speed 1. Recipe times are seconds at crafting
  speed 1. Recipes without an explicit time take 0.5 s.
- A tile is 1×1. Entities snap to the tile grid: odd-sized footprints (1×1, 3×3,
  5×5) are centred on half tiles (`x.5`), even-sized ones (2×2, 4×4) on integer
  coordinates.
- Chunks are 32×32 tiles. Pollution, map generation and enemy expansion work per
  chunk.
- Directions: north = −y, south = +y, east = +x, west = −x.
- A mining drill outputs to the tile in front of it. An inserter moves items
  from one side to the opposite side; confirm which is pickup and which is drop
  with the reported positions rather than assuming from `direction`.
- Hand crafting queues intermediates recursively from the actor's inventory.
  Assemblers do not; every ingredient must be delivered.
- Stack sizes (base data): ores, coal, stone, solid fuel 50; wood, plates,
  bricks, steel, gears, pipes, belts, walls, magazines 100; electronic circuits
  and copper cable 200; inserters, drills, furnaces, assemblers, poles and gun
  turrets 50; rocket fuel 20; nuclear fuel 1.
- Containers: wooden chest 16 slots, iron chest 32, steel chest 48.

## 2. Planning formulas

- **Machines for a rate**:
  `machines = target_items_per_s × recipe_time / (crafting_speed × items_per_craft × (1 + productivity))`.
  Round up. Space Age foundries, electromagnetic plants and biochambers have a
  built-in +50 % productivity.
- **Ingredient rate**: multiply each ingredient's count by
  `target_rate / (items_per_craft × (1 + productivity))`. Walk the tree from the
  final product down to raw ore.
- **Fuel burn rate**: `fuel_items_per_s = power_W / fuel_value_J`. A stone
  furnace (90 kW) on coal (4 MJ) burns 0.0225 coal/s, 1.35 coal/min.
- **Belt capacity**: two lanes, each half the listed throughput.
- **Drills per belt**: `belt_rate / (drill_rate × (1 + mining_productivity))`.
- Leave 10–20 % surplus in production and power so a slow delivery or a
  depleting patch does not cascade.

## 3. What is available at game start

Factorio 2.x locks most of the early game behind **trigger technologies**
(completed by doing something, not by science packs) and cheap red research.

- **Unlocked at start**: stone furnace, burner mining drill, burner inserter,
  iron gear wheel, transport belt, wooden chest, iron chest, firearm magazine,
  light armor, and the iron plate, copper plate and stone brick smelting
  recipes.
- **Steam power** (trigger: craft 50 iron plates): pipe, pipe-to-ground,
  offshore pump, boiler, steam engine.
- **Electronics** (trigger: craft 10 copper plates): copper cable, electronic
  circuit, inserter, lab, small electric pole.
- **Automation science pack** (trigger: craft a lab; needs steam power and
  electronics): red science packs.
- **Red-science techs** (10–75 units each): automation (assembler 1,
  long-handed inserter) 10; gun turret 10; stone wall 10; military 10;
  logistics (underground belt, splitter) 20; radar 20; electric mining drill 25;
  repair pack 25; logistic science pack 75. Steel processing and fast inserter
  also need only red packs.
- Smelted plates count toward the triggers, so the burner phase completes them
  naturally.

Consequence for an agent: **gun turrets and walls need research**. Before a lab
runs, defence is limited to the character's weapon and avoiding pollution near
nests.

## 4. Fuel and burner phase

| Fuel | Energy | Notes |
| --- | --- | --- |
| Wood | 2 MJ | From trees; also an ingredient of small electric poles. |
| Carbon (Space Age) | 2 MJ | |
| Coal | 4 MJ | Main early fuel. |
| Solid fuel | 12 MJ | From oil. |
| Rocket fuel | 100 MJ | |
| Nuclear fuel | 1.21 GJ | Vehicle fuel. |

| Entity | Power | Coal/min | Notes |
| --- | --- | --- | --- |
| Burner mining drill | 150 kW | 2.25 | 2×2, mines its own 2×2 footprint, 0.25 ore/s. |
| Stone furnace | 90 kW | 1.35 | 2×2, crafting speed 1. |
| Steel furnace | 90 kW | 1.35 | 2×2, crafting speed 2. |
| Burner inserter | 50 kJ per movement | small | Uses fuel it carries to refuel itself. |
| Boiler | 1.8 MW | 27 | Feeds two steam engines. |

Tactics:

- **Self-fuelling coal pair**: two burner drills on coal facing each other. Each
  mines 15 coal/min and burns 2.25, so the pair runs on an initial fuel load.
  Inspect both after a minute: fuel should be rising in both.
- **Drill → furnace**: a burner drill facing directly into a stone furnace
  smelts without inserters. One burner drill (0.25 ore/s) is slightly less than
  one stone furnace can smelt (0.3125/s).
- Every burner machine needs its own fuel. An empty fuel slot stops the drill and
  starves the furnace. Inserters top up fuel automatically but stop at 5 items in
  furnaces and boilers.
- Furnaces stop when the output slot is full (one stack: 100 plates).
- Replace burner drills with electric drills once researched: twice the speed, a
  5×5 mining area, no fuel logistics and less pollution per ore.

## 5. Mining and smelting

| Entity | Size | Mining area | Speed | Power | Pollution/min |
| --- | --- | --- | --- | --- | --- |
| Burner mining drill | 2×2 | 2×2 | 0.25/s | 150 kW fuel | 12 |
| Electric mining drill | 3×3 | 5×5 | 0.5/s | 90 kW | 10 |
| Big mining drill (Space Age) | 5×5 | 13×13 | 2.5/s | 300 kW | |

| Furnace | Size | Speed | Power | Pollution/min |
| --- | --- | --- | --- | --- |
| Stone furnace | 2×2 | 1 | 90 kW fuel | 2 |
| Steel furnace | 2×2 | 2 | 90 kW fuel | 4 |
| Electric furnace | 3×3 | 2 | 180 kW | 1 |

| Product | Input | Time |
| --- | --- | --- |
| Iron plate | 1 iron ore | 3.2 s |
| Copper plate | 1 copper ore | 3.2 s |
| Stone brick | 2 stone | 3.2 s |
| Steel plate | 5 iron plates | 16 s |

Ratios:

- A stone furnace makes 0.3125 plates/s. A full yellow belt (15/s) of ore needs
  **48 stone furnaces** or **24 steel/electric furnaces**.
- A full yellow belt of ore needs **30 electric drills** before mining
  productivity. Two facing rows of drills can share one belt.
- A stone furnace making steel consumes 0.3125 iron plates/s, the output of one
  iron furnace.
- The big mining drill depletes the patch at only 50 % of its output rate.
- Ore patches deplete; record observed amounts. Mixed ore under a drill produces
  mixed output, which jams a furnace column.
- Uranium ore requires sulfuric acid piped into the electric drill.

## 6. Belts, inserters and logistics

| Tier | Throughput | Underground max distance |
| --- | --- | --- |
| Transport belt (yellow) | 15/s | 5 |
| Fast belt (red) | 30/s | 7 |
| Express belt (blue) | 45/s | 9 |
| Turbo belt (green, Space Age) | 60/s | 11 |

- Each belt has two lanes at half throughput. Keep one item per lane unless a
  mixed belt is deliberate (for example ore on one lane and coal on the other
  for a furnace column).
- **Sideloading**: a belt ending perpendicular into the side of another fills
  only the near lane. A belt feeding straight into the end of another keeps both
  lanes.
- Splitters split, merge and balance belts, with optional output priority and
  item filter.
- An underground entrance pairs with the next exit of the same tier in line and
  in range.

| Inserter | Notes |
| --- | --- |
| Burner inserter | Slowest; fuel-powered. Not usable in space. |
| Inserter | Standard electric inserter. |
| Long-handed inserter | Picks up and drops two tiles away. |
| Fast inserter | Rotates about 3× as fast as the inserter. |
| Bulk inserter | Fast-inserter speed, moves many items per swing; best for chest-to-chest and trains. |
| Stack inserter (Space Age) | Bulk-inserter speed, and stacks items on belts. |

- In 2.x every inserter has a 5-slot item filter (whitelist/blacklist); there is
  no separate filter inserter. Whether the host contract can set filters is
  contract-specific.
- Inserters place items on the **far lane** of a belt and pick from either lane.
- Inserters fill fuel slots automatically, up to 5 fuel items in furnaces,
  boilers and burner inserters, and they limit how much input they load into a
  machine to a few crafts' worth.
- Inserters take products from machine outputs, not their inputs.
- Electric inserters slow down on a low-power network.

## 7. Power

Steam:

- **1 offshore pump : 20 boilers : 40 steam engines**. An offshore pump needs no
  power and supplies 1200 water/s. A boiler (1.8 MW) turns 60 water/s into 60
  steam/s at 165 °C; a steam engine (900 kW) uses 30 steam/s.
- One boiler + two engines = 1.8 MW: roughly 20 electric drills (90 kW each) or
  24 assembler 1s (75 kW each), less inserter load.
- Boilers burn 27 coal/min each and pollute 30/min. Belt-feed coal with
  inserters for production power.
- Low satisfaction slows every machine on the network.

| Pole | Wire reach | Supply area |
| --- | --- | --- |
| Small electric pole | 7.5 | 5×5 |
| Medium electric pole | 9 | 7×7 |
| Big electric pole | 32 | 4×4 |
| Substation | 18 | 18×18 |

- A machine is powered if any part of it lies in a pole's supply area. Placed
  poles connect automatically to poles within wire reach.

Solar:

- Solar panel 60 kW peak, 42 kW average on Nauvis. Accumulator 5 MJ.
- About **0.85 accumulators per panel** (simplified 6 panels : 5 accumulators).
  1 MW continuous needs about 24 panels and 20 accumulators.
- Space Age surface solar relative to Nauvis: Vulcanus 400 %, Gleba 50 %,
  Fulgora 20 %, Aquilo 1 %. Space platforms get constant light.

Nuclear: reactors, heat exchangers and steam turbines give very large output but
need uranium processing and fuel-cell management.

## 8. Science and research order

| Pack | Recipe | Time | Output |
| --- | --- | --- | --- |
| Automation (red) | 1 copper plate + 1 iron gear | 5 s | 1 |
| Logistic (green) | 1 inserter + 1 transport belt | 6 s | 1 |
| Military (grey) | 1 piercing ammo + 1 grenade + 2 walls | 10 s | 2 |
| Chemical (blue) | 2 engine units + 3 advanced circuits + 1 sulfur | 24 s | 2 |
| Production (purple) | 1 electric furnace + 1 productivity module + 30 rails | 21 s | 3 |
| Utility (yellow) | 3 low density structures + 2 processing units + 1 flying robot frame | 21 s | 3 |
| Space (white) | Made on a space platform from asteroid products | | |

- Labs consume packs per research unit; more labs research faster.
- Equal-speed assembler ratio for red:green is **5:6**.
- Suggested early order for an agent on a map with enemies: complete the steam
  power and electronics triggers while smelting → build a lab → **gun turret**
  and **stone wall** → electric mining drill → automation → logistics →
  logistic science pack → steel processing → fast inserter → electric energy
  distribution → advanced material processing → engine → fluid handling →
  oil gathering / oil processing (trigger: mine crude oil) → plastics →
  advanced circuit → sulfur processing → chemical science pack.
- Keep **physical projectile damage** and **weapon shooting speed** upgrades
  ahead of evolution.
- Mining productivity, inserter capacity and belt tiers are high-value later
  upgrades.

## 9. Common recipes and ratios

From base data; Space Age only adds crafting categories (foundry,
electromagnetic plant, cryogenic plant) to these, not new ingredients.

| Item | Ingredients | Time | Output |
| --- | --- | --- | --- |
| Iron gear wheel | 2 iron plates | 0.5 s | 1 |
| Copper cable | 1 copper plate | 0.5 s | 2 |
| Electronic circuit | 1 iron plate + 3 copper cable | 0.5 s | 1 |
| Pipe | 1 iron plate | 0.5 s | 1 |
| Iron stick | 1 iron plate | 0.5 s | 2 |
| Transport belt | 1 iron gear + 1 iron plate | 0.5 s | 2 |
| Underground belt | 5 transport belts + 10 iron plates | 1 s | 2 |
| Inserter | 1 electronic circuit + 1 iron gear + 1 iron plate | 0.5 s | 1 |
| Stone furnace | 5 stone | 0.5 s | 1 |
| Burner mining drill | 3 iron gears + 1 stone furnace + 3 iron plates | 2 s | 1 |
| Electric mining drill | 3 electronic circuits + 5 iron gears + 10 iron plates | 2 s | 1 |
| Assembling machine 1 | 3 electronic circuits + 5 iron gears + 9 iron plates | 0.5 s | 1 |
| Lab | 10 electronic circuits + 10 iron gears + 4 transport belts | 2 s | 1 |
| Small electric pole | 1 wood + 2 copper cable | 0.5 s | 2 |
| Offshore pump | 3 pipes + 2 iron gears | 0.5 s | 1 |
| Boiler | 1 stone furnace + 4 pipes | 0.5 s | 1 |
| Steam engine | 8 iron gears + 10 iron plates + 5 pipes | 0.5 s | 1 |
| Wooden chest | 2 wood | 0.5 s | 1 |
| Iron chest | 8 iron plates | 0.5 s | 1 |
| Gun turret | 10 iron gears + 10 copper plates + 20 iron plates | 8 s | 1 |
| Firearm magazine | 4 iron plates | 1 s | 1 |
| Piercing rounds magazine | 2 firearm magazines + 1 steel + 2 copper plates | 6 s | 2 |
| Stone wall | 5 stone bricks | 0.5 s | 1 |
| Engine unit | 1 steel + 1 iron gear + 2 pipes | 10 s | 1 |
| Plastic bar | 20 petroleum gas + 1 coal | 1 s | 2 |
| Advanced circuit | 2 electronic circuits + 2 plastic + 4 copper cable | 6 s | 1 |

Ratios:

- **3 copper cable : 2 electronic circuit** assemblers (same speed).
- One electronic circuit = 1 iron + 1.5 copper plates.
- One red pack = 1 copper + 2 iron. One green pack = 5.5 iron + 1.5 copper.
- Assembler speeds: AM1 0.5 (75 kW), AM2 0.75 (150 kW), AM3 1.25 (375 kW).
- A first steam setup costs about 1 offshore pump, 1 boiler, 2 steam engines
  and a few poles: roughly 70 iron plates, 5 stone and wood/copper for poles.

## 10. Enemies, pollution and defence

Pollution:

- Pollution spreads between chunks (2 % to each neighbour every 64 ticks once a
  chunk exceeds 15). Tiles absorb it (water and grass most), and so do trees.
- Pollution reaching enemy **spawners** is absorbed and converted into attack
  units; attacks launch every 1–10 minutes. Pollution cost per unit: small biter
  4, medium 20, big 80, behemoth 400.
- Pollution per minute at full power: boiler 30, burner drill 12, electric drill
  10, steel furnace 4, assembler 1 4, stone furnace 2, electric furnace 1.
  Boilers and drills dominate early pollution.

Evolution (default map settings):

- Rises with time (0.000004/s), pollution produced (0.0000009 per unit) and
  spawners destroyed (0.002 each), with diminishing increments at higher
  evolution. Worm kills do not count. In Space Age each planet tracks evolution
  separately; on Gleba spores replace pollution.
- Higher evolution brings medium, big and behemoth biters, spitters and worms.
- **Expansion**: every 4–60 minutes enemies try to settle a new base within 7
  chunks of existing spawners, preferring chunks with no player structures
  within 3 chunks.

Ranges:

| Unit | Range |
| --- | --- |
| Gun turret | 18 |
| Small spitter | 13 |
| Worms (small/medium/big/behemoth) | 25 / 30 / 38 / 48 |

Defence practices:

- Inspect for nearby spawners and worms before expanding pollution.
- Research gun turrets early; place them in groups of at least two between the
  factory and enemy bases, with an ammo supply (belt or verified resupply).
- Walls in front of turrets absorb melee attacks. Spitters attack from range, so
  keep damage research current.
- **Turret creep**: clear early nests by placing armed turrets within range of
  the spawners. **Every worm outranges a gun turret**, so locate worms first and
  stay out of their range, or use longer-ranged weapons.
- After any long absence, check turret ammo, turret health and damaged machines.

## 11. Oil and fluids

Oil (from base data):

| Recipe | Inputs | Outputs | Time |
| --- | --- | --- | --- |
| Basic oil processing | 100 crude | 45 petroleum gas | 5 s |
| Advanced oil processing | 100 crude + 50 water | 25 heavy + 45 light + 55 petroleum | 5 s |
| Heavy oil cracking | 40 heavy + 30 water | 30 light | 2 s |
| Light oil cracking | 30 light + 30 water | 20 petroleum | 2 s |
| Sulfur | 30 petroleum + 30 water | 2 sulfur | 1 s |
| Sulfuric acid | 5 sulfur + 1 iron plate + 100 water | 50 sulfuric acid | 1 s |
| Solid fuel | 10 light oil | 1 solid fuel | 1 s |
| Lubricant | 10 heavy oil | 10 lubricant | 1 s |

- Pumpjack yield declines with extraction toward a 20 % minimum.
- A refinery stops when **any** output is full. Every product needs a sink or
  cracking; storage tanks only delay the problem.

Fluids (2.x):

- Connected pipes form a **segment** where fluid level equalises; there is no
  length-based throughput falloff. A segment that spreads beyond a 320×320 tile
  area stops flowing; break it with a pump.
- Theoretical maximum 6000/s per connection, about 4200/s in practice. Pumps move
  1200/s and block back-flow.
- Pipe-to-ground spans up to 10 tiles.
- A segment holds one fluid. The game blocks most placements that would join
  different fluids, but not every case.

## 12. Layout patterns

- **Main bus**: parallel belts of plates and intermediates through the base;
  production rows branch off with splitters. Leave gaps for poles and
  undergrounds and room to add belts.
- **Smelting column**: a central belt with ore on one lane and coal on the other,
  furnaces on both sides with input inserters, output inserters onto outer belts.
  Long-handed inserters reach a second belt.
- **Direct insertion**: machine → inserter → machine for tight chains (cable into
  circuits, gears into science). Saves belts at small scale.
- Keep ore patches, water and expansion routes clear of permanent structures.
- Build a pilot (one drill, one furnace, one inserter) to confirm directions and
  connections before copying the pattern.

## 13. Diagnosing a stalled factory

Check in this order, with fresh inspections:

1. **Power**: low satisfaction slows every machine; a boiler without fuel or
   water stops all steam.
2. **Fuel**: each burner entity's fuel slot.
3. **Input**: `no_ingredients`; follow the chain upstream to the first starved
   machine.
4. **Output**: `full_output` means nothing removes products.
5. **Connections**: inserter pickup/drop targets, drill output positions and belt
   directions point where intended.
6. **Belts**: wrong lane, broken run, item mixing, backed up from the end.
7. **Resources**: depleted ore, or mixed ore jamming a furnace.
8. **Damage**: enemies destroyed an entity in the chain.

Fix the first failure in the chain, then reinspect; downstream symptoms often
clear on their own.

## 14. Space Age

- **Space platforms**: built from rocket-launched materials, travel between
  planets, and process asteroids. Space science is made on a platform.
- **Planets**:
  - Vulcanus: lava, tungsten, calcite, foundry, big mining drill; demolisher
    enemies.
  - Fulgora: scrap that is recycled for materials, lightning (lightning rods),
    electromagnetic plant.
  - Gleba: agriculture (agricultural tower, biochamber), items that **spoil**,
    pentapod enemies; spores replace pollution.
  - Aquilo: extreme cold, machines need heating (heating towers, heat pipes),
    cryogenic plant.
- **Surface conditions**: stone/steel furnaces, burner mining drills, burner
  inserters and boilers need atmospheric pressure, so they cannot be built on
  space platforms. Vehicles and rails need gravity.
- **New machines** (crafting speed / power / built-in productivity): foundry
  4 / 2.5 MW / +50 %, electromagnetic plant 2 / 2 MW / +50 %, biochamber
  2 / 500 kW / +50 %, cryogenic plant 2 / 1.5 MW. Big mining drill 2.5/s,
  300 kW, 13×13 area.
- **Quality**: normal, uncommon, rare, epic, legendary; quality modules produce
  higher tiers. The host's affordability checks cover only normal-quality
  ingredients.
- **Recycler**: returns about 25 % of an item's ingredients (an item without a
  recipe has a 25 % chance to survive itself).
- Turbo belts, stack inserters and elevated rails are available.

## 15. External resources

- Official wiki: <https://wiki.factorio.com> — mechanics and stats, updated for
  2.x and Space Age.
- Factorio Lua API: <https://lua-api.factorio.com> — for extending the mod's
  bounded host contract, not for direct gameplay control.
- Friday Facts: <https://factorio.com/blog> — design notes on mechanic changes.
- Kirk McDonald calculator: <https://kirkmcdonald.github.io> — production-chain
  rates and machine counts; ships 2.0 vanilla and Space Age data sets.
- Factorio Cheat Sheet: <https://factoriocheatsheet.com> — community-maintained
  ratios and common builds.
- The installed game data (`factorio/data/base` and `factorio/data/space-age`
  prototype Lua files) is the authoritative source for this server's numbers.
  Reading those files is planning research, not a gameplay interface.

Observations of the actual save, made through typed EYG effects, take precedence
over every source above.
