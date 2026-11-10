-- Pure Lua 5.4 mocks; never loads control.lua or contacts a Factorio server.
local methods = {}
defines = {inventory = {crafter_input = 1, crafter_output = 2, crafter_trash = 3,
  assembling_machine_dump = 4, lab_input = 5, turret_ammo = 6, chest = 7}}
local function check(ok, code, message) if not ok then error({code = code, message = message}, 0) end end
local function integer(v, label, lo, hi)
  check(type(v) == 'number' and v >= lo and v <= hi and v == math.floor(v), 'invalid_argument', label)
  return v
end
local function position(p)
  check(type(p) == 'table', 'invalid_argument', 'position')
  for _, k in ipairs{'x','y'} do
    check(type(p[k]) == 'number' and p[k] == p[k] and math.abs(p[k]) <= 1000000, 'invalid_argument', k)
  end
  return {x = p.x, y = p.y}
end
local function distance(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end
local c, e, t, force, surface, busy, writes, inventories, found, generated, queries, tile_reads
local function inv(items)
  return {get_contents = function() return items end, is_empty = function() return next(items) == nil end}
end
local function reset()
  busy, writes, inventories, found, generated, queries, tile_reads = false, 0, {}, {}, true, 0, 0
  t = {name = 'automation', enabled = true, researched = false, prerequisites = {},
    prototype = {}, research_unit_count = 10, research_unit_energy = 30,
    research_unit_ingredients = {{name = 'automation-science-pack', amount = 1}}}
  force = {name = 'player', technologies = {automation = t}, recipes = {}, research_progress = 0.25}
  force.add_research = function(n) writes = writes + 1; assert(n == t.name); force.current_research = t; return true end
  surface = {
    is_chunk_generated = function(_) return generated end,
    get_tile = function(x,y)
      assert(generated); tile_reads = tile_reads + 1
      return {name = 'water', position = {x=x,y=y}, collides_with = function(layer) assert(layer == 'water_tile'); return true end}
    end,
    find_entities_filtered = function(f) queries = queries + 1; assert(f.area and f.limit == 101); return found end,
    find_entity = function(n,p) assert(p.x == 1 and p.y == 0); return e and e.name == n and e or nil end}
  c = {position = {x=0,y=0}, force = force, surface = surface, can_reach_entity = function(_) return true end}
  e = {valid = true, name = 'assembling-machine-1', type = 'assembling-machine',
    force = force, position = {x=1,y=0}, health = 200, status = 1, energy = 42,
    quality = 'normal', recipe_locked = false, crafting_progress = 0, bonus_progress = 0,
    fluids_count = 0, get_fluid = function() error('no fluid slots expected') end,
    prototype = {get_max_health = function(q) assert(q == 'normal'); return 300 end,
      crafting_categories = {crafting = true}, ingredient_count = 6, fluidbox_prototypes = {} },
    get_inventory = function(i) return inventories[i] end,
    get_fuel_inventory = function() return inventories.fuel end,
    get_output_inventory = function() return inventories[2] end,
    get_module_inventory = function() return inventories.modules end,
    is_crafting = function() return false end,
    get_recipe = function() return e.recipe end,
    set_recipe = function(n, quality)
      assert(quality == 'normal'); writes = writes + 1; e.recipe = force.recipes[n]; return {}
    end}
  force.recipes.gear = {name = 'gear', enabled = true, has_category = function(cat) return cat == 'crafting' end,
    ingredients = {{name = 'iron-plate', type = 'item', amount = 2}}, products = {{name = 'gear', type = 'item', amount = 1}}}
end
require('mods.factorio-control.expansion').register(methods, {
  check = check, integer = integer, position = position, distance = distance,
  character = function() return c end, idle = function() check(not busy, 'busy', 'busy') end,
  contents = function(i) return i and i.get_contents() or {} end, status_names = {[1] = 'working'}})
local function fails(code, fn)
  local ok, err = pcall(fn)
  assert(not ok and type(err) == 'table' and err.code == code, 'expected ' .. code .. ', got ' .. tostring(err))
end
local function area(r,p) return methods.inspect_area{position = p or {x=0,y=0}, radius = r} end
local function machine() return methods.inspect_machine{name=e.name,position={x=1,y=0}} end
local function set() return methods.set_recipe{name=e.name,position={x=1,y=0},recipe='gear'} end
local function research() return methods.research{name='automation'} end
reset()
for _, r in ipairs{0,9,1.5,'8'} do fails('invalid_argument', function() area(r) end) end
fails('out_of_range', function() area(1,{x=65,y=0}) end)
fails('invalid_argument', function() area(1,{x=0/0,y=0}) end)
fails('invalid_argument', function() methods.inspect_area(nil) end)
assert(queries == 0 and tile_reads == 0)
local a = area(8)
assert(#a.tiles == 289 and a.tiles[1].water and not a.truncated)
for i=1,101 do found[i] = e end
a = area(1); assert(#a.entities == 100 and a.truncated and a.entities[1].max_health == 300)
generated = false
a = area(8); assert(#a.tiles == 0)
fails('not_generated', machine)
assert(writes == 0)
reset()
-- Partial generation, including negative chunk coordinates: never read an absent tile.
surface.is_chunk_generated = function(p) return p.x == -1 and p.y == -1 end
surface.get_tile = function(x,y) assert(x < 0 and y < 0); return {name='land',position={x=x,y=y},collides_with=function() return false end} end
a = area(1); assert(#a.tiles == 1 and a.tiles[1].position.x == -1)
reset()
t.prototype.research_trigger = {type='craft-item',item={name='gear',quality='normal'},count=10}
local tech = methods.inspect_technology{name='automation'}
assert(tech.trigger_type == 'craft-item' and tech.trigger_item == 'gear' and tech.trigger_count == 10)
fails('trigger_research', research)
t.prototype.research_trigger = {type='mine-entity',entities={'iron-ore'}}
assert(methods.inspect_technology{name='automation'}.trigger_entity == 'iron-ore')
t.prototype.research_trigger = nil
t.prerequisites.x = {name='x',researched=false}
fails('missing_prerequisite', research)
t.prerequisites.x.researched = true
t.enabled = false; fails('invalid_technology', research); t.enabled = true
t.researched = true; fails('invalid_technology', research); t.researched = false
force.current_research = {name='other'}; fails('research_busy', research)
force.current_research = nil
assert(writes == 0)
assert(research().name == 'automation' and writes == 1)
assert(research().name == 'automation' and writes == 1)
tech = methods.inspect_technology{name='automation'}
assert(tech.current and tech.progress == .25 and tech.count == 10 and tech.energy == 30)
busy = true; fails('busy', research); busy = false
reset()
e.force = {name='enemy'}; fails('wrong_force', set); e.force = force
c.can_reach_entity = function() return false end; fails('out_of_reach', set)
c.can_reach_entity = function() return true end
force.recipes.gear.enabled = false; fails('invalid_recipe', set); force.recipes.gear.enabled = true
force.recipes.gear.ingredients[1].type = 'fluid'; fails('unsupported_recipe', set); force.recipes.gear.ingredients[1].type = 'item'
e.prototype.crafting_categories = {}; fails('unsupported_recipe', set); e.prototype.crafting_categories.crafting = true
e.recipe_locked = true; fails('recipe_locked', set); e.recipe_locked = false
for _, k in ipairs{1,2,3,4} do
  inventories[k] = inv{{name='iron-plate',count=2}}
  fails('machine_not_empty', set)
  assert(inventories[k].get_contents()[1].count == 2)
  inventories[k] = nil
end
e.is_crafting = function() return true end; fails('machine_not_empty', set)
e.is_crafting = function() return false end
e.bonus_progress = .2; fails('machine_not_empty', set); e.bonus_progress = 0
inventories.modules = inv{{name='speed-module',count=1}}
fails('machine_not_empty', set); inventories.modules = nil
e.prototype.fluidbox_prototypes = {{}}; e.fluids_count = 1
e.get_fluid = function() return {name='water',amount=0.001} end
fails('machine_not_empty', set); e.fluids_count = 0; e.prototype.fluidbox_prototypes = {}
assert(writes == 0)
assert(set().recipe == 'gear' and writes == 1)
inventories[1] = inv{{name='iron-plate',count=2}}
assert(set().recipe == 'gear' and writes == 1) -- idempotent while nonempty

-- SetRecipe is capability-based, not a list of base-game prototype names.
for _, n in ipairs{'assembling-machine-1','assembling-machine-2','assembling-machine-3',
  'foundry','electromagnetic-plant','modded-assembler'} do
  reset(); e.name = n
  e.prototype.fluidbox_prototypes = {{}, {}}
  e.fluids_count = 2
  local reads = 0
  e.get_fluid = function(i) assert(i >= 1 and i <= 2); reads = reads + 1; return nil end
  assert(set().recipe == 'gear' and writes == 1 and reads == 2)
  assert(e.recipe == force.recipes.gear)
end
for _, kind in ipairs{'furnace','rocket-silo','lab','character','container'} do
  reset(); e.type = kind
  e.get_recipe = function() error('wrong native class must not be queried') end
  fails('unsupported_machine', set); assert(writes == 0)
end
reset(); busy = true; fails('busy', set); assert(writes == 0)
reset(); generated = false; fails('not_generated', set); assert(writes == 0)
reset()
e.prototype.fixed_recipe = {name='other'}
fails('recipe_locked', set); assert(writes == 0)
e.prototype.fixed_recipe = nil; e.crafting_progress = .01
fails('machine_not_empty', set); assert(writes == 0)

-- The machine's ingredient slot capability counts ingredient kinds, not amounts.
reset()
force.recipes.gear.ingredients[2] = {name='copper-plate', type='item', amount=1000}
e.prototype.ingredient_count = 1
fails('unsupported_recipe', set); assert(writes == 0)
e.prototype.ingredient_count = 2
assert(set().recipe == 'gear' and writes == 1)
reset(); e.prototype.ingredient_count = nil
fails('unsupported_recipe', set); assert(writes == 0)
for _, field in ipairs{'ingredients','products'} do
  reset(); e.prototype.ingredient_count = 255
  for i=1,65 do force.recipes.gear[field][i] = {name='item-'..i,type='item',amount=1} end
  fails('unsupported_recipe', set); assert(writes == 0)
  reset(); force.recipes.gear[field][1].type = 'fluid'
  fails('unsupported_recipe', set); assert(writes == 0)
end
reset()
for i=1,129 do e.prototype.crafting_categories['category-'..i] = true end
fails('unsupported_machine', set); assert(writes == 0)
reset(); e.prototype.crafting_categories = {['modded-category']=true}
force.recipes.gear.has_category = function(cat) return cat == 'modded-category' end
assert(set().recipe == 'gear' and writes == 1)

-- Inspect actual engine storages even when the prototype exposes no fluidboxes.
reset(); e.fluids_count = 64
local reads = 0
e.get_fluid = function(i)
  reads = reads + 1
  if i == 64 then return {name='water',amount=0.0001} end
end
fails('machine_not_empty', set); assert(reads == 64 and writes == 0)
reset(); e.fluids_count = 2
e.get_fluid = function(i) if i == 2 then return {name='water',amount=0} end end
assert(set().recipe == 'gear' and writes == 1)
for _, n in ipairs{65, -1, 1.5, false} do
  reset(); e.fluids_count = n
  fails('unsupported_machine', set); assert(writes == 0)
end
reset(); e.fluids_count = nil
fails('unsupported_machine', set); assert(writes == 0)
reset(); e.fluids_count = 1
e.get_fluid = function() error('fluid API failure') end
local read_ok, read_error = pcall(set)
assert(not read_ok and tostring(read_error):find('fluid API failure') and writes == 0)

-- An exact same-recipe request never touches inventories, fluids, locks or progress.
reset(); e.recipe = force.recipes.gear
inventories[1] = inv{{name='iron-plate',count=2}}
inventories.modules = inv{{name='speed-module',count=1}}
e.recipe_locked = true; e.prototype.fixed_recipe = {name='gear'}
e.crafting_progress, e.bonus_progress, e.fluids_count = .25, .5, 65
e.get_inventory = function() error('no-op must not touch inventories') end
e.get_module_inventory = e.get_inventory
e.is_crafting = function() error('no-op must not inspect craft progress') end
assert(set().recipe == 'gear' and writes == 0)

-- Empty machines can switch away from an existing recipe without clearing anything.
reset(); e.name = 'assembling-machine-3'; e.recipe = {name='previous-recipe'}
assert(set().recipe == 'gear' and writes == 1)

-- Confirmed native surprises are errors, never a retry or a false success.
reset()
e.set_recipe = function(n, quality)
  assert(quality == 'normal'); writes = writes + 1; e.recipe = force.recipes[n]
  return {{name='unexpected-item',quality='normal',count=1}}
end
fails('unexpected_recipe_items', set); assert(writes == 1)
assert(machine().recipe == 'gear' and writes == 1)
reset(); e.set_recipe = function() writes = writes + 1; return {} end
fails('recipe_failed', set); assert(writes == 1)

reset()
inventories[1], inventories[2], inventories.fuel = inv{{name='iron',count=3}}, inv{{name='gear',count=2}}, inv{{name='coal',count=1}}
e.recipe = force.recipes.gear
local m = machine()
assert(m.input[1].name == 'iron' and m.output[1].name == 'gear' and m.fuel[1].name == 'coal')
assert(m.recipe == 'gear' and m.status_name == 'working' and m.energy == 42 and m.network_id == 0 and #m.fluids == 0)
e.type = 'lab'; inventories[5] = inv{{name='science',count=4}}; assert(machine().input[1].name == 'science')
e.type = 'ammo-turret'; inventories[6] = inv{{name='magazine',count=5}}; assert(machine().ammo[1].name == 'magazine')
e.type = 'container'; inventories[7] = inv{{name='stone',count=6}}; assert(machine().inventory[1].name == 'stone')
e.prototype.fluidbox_prototypes = {{}}
e.fluids_count = 2
e.get_fluid = function(i) if i == 2 then return {name='water',amount=5,temperature=20} end end
assert(machine().fluids[1].temperature == 20)
e.fluids_count = 65; fails('unsupported_machine', machine); e.fluids_count = 2
e.force = {name='enemy'}
e.get_inventory = function() error('must not inspect enemy inventory') end
e.get_fuel_inventory = e.get_inventory; e.get_output_inventory = e.get_inventory; e.get_fluid = e.get_inventory
m = machine(); assert(next(m.inventory) == nil and next(m.fuel) == nil and #m.fluids == 0)
assert(writes == 0)
reset()
e.get_fuel_inventory = function() error('API failure') end
local ok, err = pcall(machine); assert(not ok and tostring(err):find('API failure'))
reset()
surface.find_tiles_filtered = function(f)
  assert(f.radius == 64 and f.limit == 201 and f.collision_mask == 'water_tile')
  local result = {}
  for i = 1, 201 do result[i] = {name='water',position={x=i,y=0}} end
  return result
end
local water = methods.inspect_water{radius=64}
assert(#water.tiles == 200 and water.truncated and writes == 0)
fails('invalid_argument', function() methods.inspect_water{radius=65} end)
reset()
e.name, e.type = 'iron-chest', 'container'
local chest = inv{{name='coal',count=99}}
for i=1,48 do chest[i]=false end
local bar=49
chest.supports_bar=function() return true end
chest.set_bar=function(n) bar=n end
chest.get_bar=function() return bar end
inventories[7]=chest
assert(methods.set_chest_limit{name='iron-chest',position={x=1,y=0},slots=2}.slots==2)
assert(bar==3 and chest.get_contents()[1].count==99)
fails('invalid_argument',function() methods.set_chest_limit{name='iron-chest',position={x=1,y=0},slots=0} end)
e.force={name='enemy'}
fails('wrong_force',function() methods.set_chest_limit{name='iron-chest',position={x=1,y=0},slots=1} end)
print('PASS: expansion bounds, water survey, research safety, recipe conservation, stock limits and machine inventories')
