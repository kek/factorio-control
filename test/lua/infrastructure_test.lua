-- Isolated Lua 5.4 contract tests; no engine, server, or expansion effects.
package.path = 'mods/factorio-control/?.lua;' .. package.path
package.loaded.expansion = {register = function() end}

defines = {
  direction = {north = 0, northeast = 2, east = 4, southeast = 6,
    south = 8, southwest = 10, west = 12, northwest = 14},
  entity_status = {}, events = {on_tick = 1},
  inventory = {chest = 1, crafter_input = 2, lab_input = 3, turret_ammo = 4, character_corpse = 5},
  build_check_type = {manual = 1}, wire_connector_id = {pole_copper = 1},
  wire_origin = {player = 1}
}
local tick, request, init
script = {active_mods = {base = '2.1.24'},
  on_init = function(fn) init = fn end,
  on_event = function(event, fn) assert(event == defines.events.on_tick); tick = fn end}
remote = {add_interface = function(name, interface)
  assert(name == 'bot'); request = interface.request
end}
storage, prototypes, game = {}, {item = {}, entity = {}}, {tick = 0}
dofile('mods/factorio-control/control.lua')
init()

local function eq(actual, expected, message)
  assert(actual == expected, (message or 'unexpected value') .. ': expected ' ..
    tostring(expected) .. ', got ' .. tostring(actual))
end
local function call(method, args)
  return request{method = method, args = args or {}}
end
local function ok(method, args)
  local result = call(method, args)
  assert(result.ok, result.error and (result.error.code .. ': ' .. result.error.message))
  return result.data
end
local function denied(code, method, args)
  local result = call(method, args)
  eq(result.ok, false, method .. ' must be denied')
  eq(result.error.code, code)
end
local function advance(n)
  for _ = 1, n do game.tick = game.tick + 1; tick() end
end
local function inventory(items, slots)
  local inv = slots or {}
  inv.items = items or {}
  inv.get_item_count = function(s)
    eq(s.quality, 'normal', 'inventory quality filter')
    return inv.items[s.name] or 0
  end
  inv.get_insertable_count = function(s)
    eq(s.quality, 'normal'); return inv.full and 0 or 1000
  end
  inv.insert = function(s)
    eq(s.quality, 'normal'); inv.items[s.name] = (inv.items[s.name] or 0) + s.count
    return s.count
  end
  inv.remove = function(s)
    eq(s.quality, 'normal')
    local n = math.min(s.count, inv.items[s.name] or 0)
    inv.items[s.name] = (inv.items[s.name] or 0) - n
    return n
  end
  inv.get_contents = function() return {} end
  return inv
end
local c, main, world, surface, created, begin_calls, cancelled
local function reset()
  prototypes.item = {
    gear = {type = 'item'}, ['iron-plate'] = {type = 'item'},
    ['firearm-magazine'] = {type = 'ammo', magazine_size = 10},
    ['automation-science-pack'] = {type = 'tool', get_durability = function(q)
      eq(q, 'normal'); return 1
    end}, ['piercing-rounds-magazine'] = {type = 'ammo'}, ['repair-pack'] = {type = 'repair-tool'}
  }
  game.tick, world, created, begin_calls, cancelled = 0, {}, {}, {}, {}
  main = inventory({['iron-plate'] = 100})
  surface = {}
  surface.find_entity = function(name, pos)
    for _, e in ipairs(world) do
      if e.name == name and e.position.x == pos.x and e.position.y == pos.y then return e end
    end
  end
  surface.can_place_entity = function(_) return true end
  c = {valid = true, position = {x = 0, y = 0}, force = {name = 'player', recipes = {}},
    surface = surface, resource_reach_distance = 10, build_distance = 10, crafting_queue = {}}
  local stats = {produced = {}, consumed = {}, flows = {}}
  stats.get_input_count = function(id) return stats.produced[id.name] or 0 end
  stats.get_output_count = function(id) return stats.consumed[id.name] or 0 end
  stats.on_flow = function(id, n)
    stats.flows[#stats.flows + 1] = {name=id.name,count=n}
    local target = n >= 0 and stats.produced or stats.consumed
    target[id.name] = (target[id.name] or 0) + math.abs(n)
  end
  c.force.stats = stats
  c.force.get_item_production_statistics = function(s) eq(s,surface); return stats end
  c.clear_selected_entity = function() c.selected = nil end
  c.update_selected_entity = function(p)
    c.selected = surface.find_entity('tree', p) or surface.find_entity('rock', p)
  end
  c.get_main_inventory = function() return main end
  c.get_item_count, c.remove_item, c.insert = main.get_item_count, main.remove, main.insert
  c.can_place_entity = function(_) return true end
  c.can_reach_entity = function(e) return not e.unreachable end
  c.begin_crafting = function(spec)
    begin_calls[#begin_calls + 1] = spec
    c.crafting_queue = {{recipe = spec.recipe, count = spec.count}}
    return spec.count
  end
  c.cancel_crafting = function(spec)
    cancelled[#cancelled + 1] = {index = spec.index, count = spec.count,
      recipe = c.crafting_queue[spec.index].recipe}
    table.remove(c.crafting_queue, spec.index)
  end
  surface.create_entity = function(spec)
    created[#created + 1] = spec
    return {valid = true, name = spec.name, type = 'container', position = spec.position,
      force = c.force, get_inventory = function() return inventory() end,
      get_fuel_inventory = function() end, get_output_inventory = function() end,
      destroy = function() created.destroyed = true end}
  end
  storage.bot = {sequence = 0, actions = {}, character = c}
end
local function entity(name, kind, force, x)
  local e = {name = name, type = kind, force = force or c.force, valid = true,
    minable = true, position = {x = x or 1, y = 0}, prototype = {},
    direction = defines.direction.north, supports_direction = false, rotatable = false,
    get_inventory = function() end, get_fuel_inventory = function() end,
    get_output_inventory = function() end}
  world[#world + 1] = e
  return e
end
local function recipe(product, amount)
  c.force.recipes.test = {name = 'test', enabled = true, energy = 0.1,
    has_category = function(category) return category == 'crafting' end,
    ingredients = {{name = 'iron-plate', type = 'item', amount = 2}},
    products = {{name = product or 'gear', type = 'item', amount = amount or 1}}}
  return c.force.recipes.test
end
local function build(item, w, h)
  prototypes.item[item] = {type = 'item', place_result = {name = item, type = item == 'underground-belt' and 'underground-belt' or 'container', tile_width = w, tile_height = h}}
  main.items[item] = 10
end
local passed, failed = 0, 0
local function test(name, fn)
  reset()
  local success, err = pcall(fn)
  if success then passed = passed + 1; print('PASS: ' .. name)
  else failed = failed + 1; print('FAIL: ' .. name .. ': ' .. tostring(err)) end
end

test('spawn creates an empty character only when the previous bot is absent', function()
  local original=c
  game.surfaces={nauvis=surface};game.forces={player=c.force}
  surface.valid=true
  local creates=0
  surface.find_non_colliding_position=function(name,p,radius,step) eq(name,'character');eq(radius,16);return p end
  surface.create_entity=function(spec)
    eq(spec.name,'character');creates=creates+1
    local fresh={valid=true,position=spec.position,force=original.force,surface=surface,clear_selected_entity=function() end}
    fresh.get_main_inventory=function() return inventory({}) end
    return fresh
  end
  assert(ok('spawn',{position={x=3,y=4}}).existing);eq(creates,0)
  storage.bot.character=nil
  local made=ok('spawn',{position={x=3,y=4}})
  assert(not made.existing);eq(creates,1);eq(next(storage.bot.character.get_main_inventory().items),nil)
end)

test('prototype-based building supports later tiers and modded plain items', function()
  for _, item in ipairs({'splitter', 'underground-belt', 'assembling-machine-1', 'inserter',
    'small-electric-pole', 'electric-mining-drill', 'boiler', 'steam-engine', 'offshore-pump',
    'pipe', 'pipe-to-ground', 'lab', 'gun-turret', 'stone-wall', 'small-lamp',
    'assembling-machine-3', 'fast-transport-belt', 'modded-building'}) do
    build(item, 1, 1)
    ok('build', {item = item, position = {x = 0.5, y = 0.5}})
    eq(main.items[item], 9)
  end
  build('splitter', 2, 1)
  c.can_place_entity = function() return false end
  denied('blocked', 'build', {item = 'splitter', position = {x = 0, y = 0.5}})
  eq(main.items.splitter, 10)
  c.can_place_entity = function() return true end
  surface.can_place_entity = function() return false end
  denied('blocked', 'build', {item = 'splitter', position = {x = 0, y = 0.5}})
  eq(main.items.splitter, 10)
  surface.can_place_entity = function() return true end
  surface.create_entity = function() return nil end
  denied('blocked', 'build', {item = 'splitter', position = {x = 0, y = 0.5}})
  eq(main.items.splitter, 10)
end)

test('building rejects unknown, nonplaceable and stateful items without consuming stock', function()
  denied('unsupported_item', 'build', {item = 'unknown', position = {x = .5, y = .5}})
  denied('unsupported_item', 'build', {item = 'repair-pack', position = {x = .5, y = .5}})
  build('car', 2, 2); prototypes.item.car.type = 'item-with-entity-data'
  denied('unsupported_item', 'build', {item = 'car', position = {x = 0, y = 0}})
  eq(main.items.car, 10); eq(#created, 0)
  build('fast-underground-belt', 1, 1)
  prototypes.item['fast-underground-belt'].place_result.type = 'underground-belt'
  ok('build', {item = 'fast-underground-belt', position = {x = .5, y = .5}, end_type = 'output'})
  eq(created[1].type, 'output')
end)

test('lamps require owned stock, aligned reachable unblocked placement', function()
  build('small-lamp', 1, 1)
  local args = {item = 'small-lamp', position = {x = 0.5, y = 0.5}}
  main.items['small-lamp'] = 0
  denied('no_item', 'build', args)
  main.items['small-lamp'] = 1
  args.position.x = 20.5
  denied('out_of_reach', 'build', args)
  args.position.x = 0
  denied('invalid_argument', 'build', args)
  args.position.x = 0.5
  surface.can_place_entity = function() return false end
  denied('blocked', 'build', args)
  eq(main.items['small-lamp'], 1); eq(#created, 0)
  surface.can_place_entity = function() return true end
  ok('build', args)
  eq(main.items['small-lamp'], 0); eq(#created, 1)
end)

test('underground endpoints use explicit input/output types without arbitrary prototypes', function()
  build('underground-belt',1,1)
  for _,kind in ipairs{'input','output'} do
    ok('build_underground',{position={x=.5,y=.5},direction='south',end_type=kind})
    eq(created[#created].type,kind)
  end
  denied('invalid_argument','build_underground',{position={x=.5,y=.5},end_type='other'})
end)

test('friendly item-placeable belts are mined normally, never hostile infrastructure', function()
  local e=entity('transport-belt','transport-belt')
  e.prototype.items_to_place_this = {{name = 'transport-belt', count = 1}}
  c.update_selected_entity=function() c.selected=e end
  ok('mine_object',{name='transport-belt',position=e.position,timeout_ticks=10})
  advance(1); assert(c.mining_state.mining)
  e.valid=false; advance(1); eq(ok('action',{id=1}).status,'completed')
  e.valid=true;e.force={name='enemy'}
  denied('invalid_target','mine_object',{name='transport-belt',position=e.position})
end)

test('rectangle parity rotates for east/west and preserves engine direction', function()
  build('boiler', 3, 2)
  for _, direction in ipairs({'north', 'south', 'east', 'west'}) do
    local rotated = direction == 'east' or direction == 'west'
    local p = rotated and {x = -2, y = -1.5} or {x = -1.5, y = -2}
    local bad = {x = p.y, y = p.x}
    local before = main.items.boiler
    denied('invalid_argument', 'build', {item = 'boiler', position = bad, direction = direction})
    eq(main.items.boiler, before)
    ok('build', {item = 'boiler', position = p, direction = direction})
    eq(created[#created].direction, defines.direction[direction])
    eq(created[#created].quality, 'normal')
    eq(created[#created].build_check_type, defines.build_check_type.manual)
    eq(created[#created].position.x, p.x); eq(created[#created].position.y, p.y)
  end
  denied('invalid_argument', 'build', {item = 'boiler', position = {x = 0.5, y = 0}, direction = 'northeast'})
end)

test('build rolls back created entity when source removal fails', function()
  build('lab', 3, 3)
  c.remove_item = function() return 0 end
  denied('no_item', 'build', {item = 'lab', position = {x = 0.5, y = 0.5}})
  eq(created.destroyed, true); eq(main.items.lab, 10)
end)

test('Craft supports outputs of any registered item prototype type', function()
  for _, product in ipairs({'gear', 'firearm-magazine', 'automation-science-pack', 'piercing-rounds-magazine', 'repair-pack'}) do
    recipe(product, 2)
    local a = ok('craft', {recipe = 'test', count = 2})
    advance(12)
    eq(ok('action', {id = a.id}).status, 'completed')
    eq(main.items[product], 4)
  end
  recipe('unknown-item')
  denied('unsupported_recipe', 'craft', {recipe = 'test'})
end)

-- Slot-faithful fake for the native transfer API. Metadata travels with stacks;
-- the production implementation must never read, serialize or recreate it.
local function native_inventory(stacks, size)
  local inv = {}
  for i = 1, size or 4 do
    local slot = stacks[i] or {count = 0}
    slot.quality = slot.quality or {name = 'normal'}
    slot.valid_for_read = (slot.count or 0) > 0
    slot.transfer_stack = function(source, amount)
      if inv.full or (slot.filter and slot.filter ~= source.name) then return false end
      if slot.valid_for_read and (slot.name ~= source.name or slot.metadata ~= source.metadata
        or slot.quality.name ~= source.quality.name) then return false end
      local n = math.min(amount, source.count, (inv.capacity or 1000) - (slot.count or 0))
      if n <= 0 then return false end
      slot.name, slot.quality, slot.metadata = source.name, source.quality, source.metadata
      slot.count, slot.valid_for_read = (slot.count or 0) + n, true
      source.count = source.count - n
      source.valid_for_read = source.count > 0
      return n == amount
    end
    inv[i] = slot
  end
  inv.get_item_count = function(spec)
    local n = 0
    for _, slot in ipairs(inv) do
      if slot.valid_for_read and slot.name == spec.name and slot.quality.name == spec.quality then
        n = n + slot.count
      end
    end
    return n
  end
  inv.supports_bar = function() return inv.bar ~= nil end
  inv.get_bar = function() return inv.bar end
  return inv
end

local function transfer_target(kind, slot, item, metadata)
  local e = entity('target', kind)
  main = native_inventory({{name = item, count = 5, metadata = metadata}})
  c.get_main_inventory = function() return main end
  local other = native_inventory({})
  e.get_inventory = function(id) eq(id, slot); return other end
  return {entity = 'target', position = e.position,
    inventory = kind == 'ammo-turret' and 'ammo' or 'input',
    direction = 'give', item = item, count = 2}, other
end

test('Transfer supports every prototype type without reconstructing its metadata', function()
  for _, kind in ipairs({'item', 'ammo', 'tool', 'repair-tool', 'armor', 'gun',
    'capsule', 'module', 'blueprint', 'blueprint-book', 'item-with-tags',
    'item-with-entity-data', 'item-with-inventory', 'rail-planner',
    'deconstruction-item', 'upgrade-item', 'selection-tool'}) do
    world = {}
    prototypes.item.generic = {type = kind}
    local metadata = {ammo = 3, durability = .4, health = .5, spoil_tick = 1234,
      tags = {custom = 'preserve'}, blueprint = {}, equipment = {}}
    local a, dest = transfer_target('assembling-machine', defines.inventory.crafter_input, 'generic', metadata)
    eq(ok('transfer', a).count, 2)
    eq(main[1].count, 3); eq(dest[1].count, 2); eq(dest[1].metadata, metadata)
    a.direction = 'take'
    eq(ok('transfer', a).count, 2)
    eq(main[1].count, 5); eq(dest[1].count, 0); eq(main[1].metadata, metadata)
  end
end)

test('Transfer can recover partially consumed turret ammo and lab science', function()
  for _, row in ipairs({{'ammo-turret', defines.inventory.turret_ammo, 'firearm-magazine'},
    {'lab', defines.inventory.lab_input, 'automation-science-pack'}}) do
    world = {}
    local a, dest = transfer_target(table.unpack(row))
    eq(ok('transfer', a).count, 2)
    a.direction = 'take'
    eq(ok('transfer', a).count, 2); eq(main[1].count, 5)
  end
end)

test('Transfer preserves distinct stacks and skips other qualities', function()
  local a, dest = transfer_target('lab', defines.inventory.lab_input, 'automation-science-pack')
  main[1].quality.name = 'rare'
  denied('no_item', 'transfer', a); eq(dest[1].count, 0)
  main[2].name, main[2].count, main[2].valid_for_read = a.item, 1, true
  main[3].name, main[3].count, main[3].valid_for_read = a.item, 2, true
  main[2].metadata, main[3].metadata = {durability = .1}, {durability = .9}
  eq(ok('transfer', a).count, 2)
  eq(main[1].count, 5); eq(main[3].count, 1)
  eq(dest[1].metadata, main[2].metadata); eq(dest[2].metadata, main[3].metadata)
  a.item = 'unknown'
  denied('invalid_argument', 'transfer', a)
end)

test('Transfer respects bars, filters, slot budgets and reports partial capacity', function()
  local a, dest = transfer_target('lab', defines.inventory.lab_input, 'automation-science-pack')
  a.count = 6
  denied('no_item', 'transfer', a); eq(main[1].count, 5); eq(dest[1].count, 0)
  a.count = 2
  dest.bar = 1
  denied('inventory_full', 'transfer', a); eq(main[1].count, 5)
  dest.bar = 2; dest[1].filter = 'other'
  denied('inventory_full', 'transfer', a); eq(main[1].count, 5)
  dest[1].filter = nil; dest.capacity = 1
  eq(ok('transfer', a).count, 1); eq(main[1].count, 4)
  dest.bar = nil
  for i = 5, 20000 do dest[i] = dest[1] end
  denied('unsupported_inventory', 'transfer', a); eq(main[1].count, 4)
end)

test('ConnectPower checks friendly/reachable poles and normal wire reach/player origin', function()
  local a = entity('small-electric-pole', 'electric-pole', nil, 1)
  local b = entity('small-electric-pole', 'electric-pole', nil, 2)
  local attempts, target, allow = 0, {}, false
  local connector = {is_connected_to = function(other) eq(other, target); return false end,
    connect_to = function(other, normal_reach, origin)
      eq(other, target); eq(normal_reach, true); eq(origin, defines.wire_origin.player)
      attempts = attempts + 1; return allow
    end}
  a.get_wire_connector = function(id, create) eq(id, defines.wire_connector_id.pole_copper); eq(create, true); return connector end
  b.get_wire_connector = function() return target end
  local args = {from = a.position, to = b.position}
  b.force = {name = 'enemy'}
  denied('invalid_target', 'connect_power', args); eq(attempts, 0)
  b.force = c.force; b.unreachable = true
  denied('out_of_reach', 'connect_power', args); eq(attempts, 0)
  b.unreachable = false
  denied('out_of_reach', 'connect_power', args); eq(attempts, 1)
  allow = true; eq(ok('connect_power', args).connected, true); eq(attempts, 2)
  connector.is_connected_to = function() return true end
  ok('connect_power', args); eq(attempts, 2)
end)

test('MineObject rejects non-neutral/non-minable/non-tree-or-rock targets', function()
  local e = entity('tree', 'tree', {name = 'enemy'})
  local args = {name = 'tree', position = e.position}
  denied('invalid_target', 'mine_object', args)
  e.force = {name = 'neutral'}; e.type = 'resource'
  denied('invalid_target', 'mine_object', args)
  e.type = 'tree'; e.minable = false
  denied('invalid_target', 'mine_object', args)
  e.minable = true; e.position.x = 11
  denied('out_of_reach', 'mine_object', args)
  eq(storage.bot.active, nil)
end)

test('MineObject uses normal async mining and completes exactly once for trees/rocks', function()
  for _, kind in ipairs({'tree', 'simple-entity'}) do
    local name = kind == 'tree' and 'tree' or 'rock'
    local e = entity(name, kind, {name = 'neutral'})
    local a = ok('mine_object', {name = name, position = e.position})
    eq(a.status, 'running'); eq(a.count, 0)
    advance(1)
    eq(c.selected, e); eq(c.mining_state.mining, true); eq(c.mining_state.position.x, 1)
    e.valid = false; advance(1)
    local result = ok('action', {id = a.id})
    eq(result.status, 'completed'); eq(result.count, 1)
    eq(c.mining_state.mining, false); eq(c.selected, nil)
    eq(storage.bot.actions[a.id].target, nil)
    advance(3); eq(ok('action', {id = a.id}).finished_tick, result.finished_tick)
    world = {}
  end
end)

test('MineObject bounded timeout, Stop, lost selection and lost reach', function()
  local e = entity('tree', 'tree', {name = 'neutral'})
  local args = {name = 'tree', position = e.position, timeout_ticks = 2}
  denied('invalid_argument', 'mine_object', {name = 'tree', position = e.position, timeout_ticks = 3601})
  local a = ok('mine_object', args)
  advance(2); eq(ok('action', {id = a.id}).error.code, 'timeout'); eq(c.mining_state.mining, false)
  a = ok('mine_object', args); advance(1); ok('stop'); advance(3)
  eq(ok('action', {id = a.id}).status, 'cancelled'); eq(c.mining_state.mining, false)
  a = ok('mine_object', args); c.update_selected_entity = function() end
  advance(1); eq(ok('action', {id = a.id}).error.code, 'target_lost')
  a = ok('mine_object', args); c.position = {x = 30, y = 0}
  advance(1); eq(ok('action', {id = a.id}).error.code, 'out_of_reach')
end)

test('MineObject accepts later-tier, differently named and modded placement prototypes', function()
  for _, name in ipairs({'radar', 'assembling-machine-3', 'steel-chest', 'fast-transport-belt',
    'modded-refinery', 'car', 'straight-rail'}) do
    world = {}
    local e = entity(name, name == 'car' and 'car' or 'assembling-machine')
    e.prototype.items_to_place_this = {{name = 'different-building-item', count = 2}}
    c.update_selected_entity = function() c.selected = e end
    c.insert = function() error('mining must not grant items') end
    local a = ok('mine_object', {name = name, position = e.position})
    advance(1); assert(c.mining_state.mining); eq(c.selected, e)
    e.valid = false; advance(1)
    eq(ok('action', {id = a.id}).count, 1)
    eq(ok('action', {id = a.id}).status, 'completed')
  end
end)

test('MineObject excludes actors, resources, ghosts, corpses and nonplaceable objects', function()
  for _, kind in ipairs({'character', 'unit', 'resource', 'entity-ghost', 'tile-ghost', 'character-corpse', 'corpse'}) do
    world = {}
    local e = entity('unsafe', kind)
    e.prototype.items_to_place_this = {{name = 'modded-item', count = 1}}
    denied('invalid_target', 'mine_object', {name = e.name, position = e.position})
  end
  world = {}
  local e = entity('unplaceable', 'simple-entity')
  denied('invalid_target', 'mine_object', {name = e.name, position = e.position})
  e.prototype.items_to_place_this = {}
  denied('invalid_target', 'mine_object', {name = e.name, position = e.position})
  e.prototype.items_to_place_this = {{name = 'valid-item', count = 1}}
  e.unreachable = true
  denied('out_of_reach', 'mine_object', {name = e.name, position = e.position})
  eq(storage.bot.active, nil)
end)

test('MineObject rechecks ownership, minability and native reach during mining', function()
  for _, change in ipairs({'force', 'minable', 'unreachable'}) do
    world = {}
    local e = entity('modded-machine', 'assembling-machine')
    e.prototype.items_to_place_this = {{name = 'modded-machine', count = 1}}
    c.update_selected_entity = function() c.selected = e end
    local a = ok('mine_object', {name = e.name, position = e.position})
    advance(1)
    if change == 'force' then e.force = {name = 'enemy'}
    elseif change == 'minable' then e.minable = false
    else e.unreachable = true end
    advance(1)
    local done = ok('action', {id = a.id})
    eq(done.status, 'failed'); eq(done.count, 0)
    eq(done.error.code, change == 'unreachable' and 'out_of_reach' or 'invalid_target')
    eq(c.mining_state.mining, false); eq(c.selected, nil)
  end
end)

local function rotating_entity(name, step)
  local e = entity(name, 'assembling-machine')
  e.prototype.items_to_place_this = {{name = 'different-item', count = 1}}
  prototypes.entity[name] = e.prototype
  e.supports_direction, e.rotatable, e.calls = true, true, 0
  e.rotate = function(spec)
    e.calls = e.calls + 1
    if e.block_at == e.calls then return false end
    if not e.stuck then e.direction = (e.direction + (spec.reverse and -step or step)) % 16 end
    return true
  end
  return e, {name = name, position = e.position, direction = 'west'}
end

test('Rotate uses bounded native rotation for any item-placeable prototype', function()
  for _, name in ipairs({'assembling-machine-3', 'fast-transport-belt', 'splitter', 'modded-machine'}) do
    world = {}
    local e, a = rotating_entity(name, 4)
    local summary = ok('rotate', a)
    eq(e.calls, 1); eq(e.direction, defines.direction.west)
    eq(summary.direction, defines.direction.west); assert(summary.rotatable)
    a.direction = 'east'; ok('rotate', a)
    eq(e.calls, 3); eq(e.direction, defines.direction.east)
    ok('rotate', a); eq(e.calls, 3) -- already oriented: no native side effects
  end
end)

-- Headless 2.1.24 probe: a placed splitter reverses on its existing axis.
test('Rotate respects the native splitter two-heading cycle', function()
  local e, a = rotating_entity('splitter', 8)
  a.direction = 'south'; ok('rotate', a)
  eq(e.direction, defines.direction.south); eq(e.calls, 1)
  ok('rotate', a); eq(e.calls, 1)
  a.direction = 'east'; denied('rotation_incomplete', 'rotate', a)
  eq(e.direction, defines.direction.south); eq(e.calls, 3)
end)

test('Rotate handles fine native direction steps without directly assigning headings', function()
  local e, a = rotating_entity('modded-16-way', 1)
  a.direction = 'east'; ok('rotate', a)
  eq(e.calls, 4); eq(e.direction, defines.direction.east)
end)

test('Rotate rejects forbidden entities, reach and headings before any native change', function()
  local e, a = rotating_entity('modded-machine', 4)
  e.force = {name = 'enemy'}; denied('invalid_target', 'rotate', a)
  e.force = c.force; e.unreachable = true; denied('out_of_reach', 'rotate', a)
  e.unreachable = false; a.direction = 'northeast'; denied('invalid_argument', 'rotate', a)
  a.direction = 'west'
  e.rotatable = false; denied('unsupported_item', 'rotate', a)
  e.rotatable = true; e.supports_direction = false; denied('unsupported_item', 'rotate', a)
  e.supports_direction = true; e.prototype.items_to_place_this = nil
  denied('unsupported_item', 'rotate', a)
  e.prototype.items_to_place_this = {{name = 'modded-item', count = 1}}
  e.type = 'character'; denied('unsupported_item', 'rotate', a)
  eq(e.calls, 0)
  e.type = 'assembling-machine'; a.name = 'absent'
  denied('invalid_target', 'rotate', a); eq(e.calls, 0)
end)

test('Rotate never bypasses native blocks or silently succeeds after partial rotation', function()
  local e, a = rotating_entity('modded-machine', 4)
  a.direction = 'south'; e.block_at = 2
  denied('rotation_incomplete', 'rotate', a)
  eq(e.calls, 2); eq(e.direction, defines.direction.east)
  local observed = ok('inspect_entity', {name = e.name, position = e.position})
  eq(observed.direction, defines.direction.east)
  e.calls, e.direction, e.block_at, e.stuck = 0, 0, nil, true
  denied('rotation_incomplete', 'rotate', a); eq(e.calls, 1); eq(e.direction, 0)
  e.stuck = false; e.rotate = function() e.calls = e.calls + 1; e.direction = (e.direction + 8) % 16; return true end
  e.calls = 0; a.direction = 'east'
  denied('rotation_incomplete', 'rotate', a); eq(e.calls, 2); eq(e.direction, 0)
  e.calls = 0; e.block_at = 1; e.rotate = function() e.calls = e.calls + 1; return false end
  denied('rotation_incomplete', 'rotate', a); eq(e.calls, 1); eq(e.direction, 0)
end)

test('mining and rotation reject an actor with an active action', function()
  local e, a = rotating_entity('modded-machine', 4)
  ok('walk_to', {position = {x = 2, y = 2}, timeout_ticks = 10})
  denied('busy', 'rotate', a)
  denied('busy', 'mine_object', {name = e.name, position = e.position})
  eq(e.calls, 0)
end)

test('HandCraft validates direct ingredients, queue and timeout before engine submission', function()
  recipe('gear')
  main.items['iron-plate'] = 1
  denied('not_craftable', 'hand_craft', {recipe = 'test'})
  main.items['iron-plate'] = 100
  denied('invalid_argument', 'hand_craft', {recipe = 'test', timeout_ticks = 3601})
  c.crafting_queue = {{recipe = 'foreign', count = 3}}
  denied('busy', 'hand_craft', {recipe = 'test'})
  ok('stop'); eq(#c.crafting_queue, 1); eq(#cancelled, 0); eq(#begin_calls, 0)
  c.crafting_queue = {}; main.full = true
  denied('inventory_full', 'hand_craft', {recipe = 'test'}); eq(#begin_calls, 0)
end)

test('HandCraft rejects locked, fluid, probabilistic and unsupported recipes without submission', function()
  local r = recipe()
  r.enabled = false
  denied('invalid_recipe', 'hand_craft', {recipe = 'test'})
  r.enabled = true; r.ingredients[1].type = 'fluid'
  denied('not_craftable', 'hand_craft', {recipe = 'test'})
  r.ingredients[1].type = 'item'; r.products[1].probability = 0.5
  denied('unsupported_recipe', 'hand_craft', {recipe = 'test'})
  r.products[1].probability = 1; r.products[1].name = 'unknown-item'
  denied('unsupported_recipe', 'hand_craft', {recipe = 'test'})
  eq(#begin_calls, 0); eq(storage.bot.active, nil)
end)

test('HandCraft accepts non-starter item prototype outputs', function()
  recipe('repair-pack')
  local a = ok('hand_craft', {recipe = 'test', count = 1})
  eq(a.status, 'running'); eq(#begin_calls, 1)
end)

test('HandCraft submits once to real engine queue and records observed output counts', function()
  recipe('gear', 2); main.items.gear = 7
  local a = ok('hand_craft', {recipe = 'test', count = 2})
  eq(a.status, 'running'); eq(#begin_calls, 1)
  eq(begin_calls[1].recipe, 'test'); eq(begin_calls[1].count, 2); eq(begin_calls[1].silent, true)
  advance(1); eq(main.items.gear, 7); eq(main.items['iron-plate'], 100)
  main.items.gear = 9; advance(1); eq(ok('action', {id = a.id}).count, 2)
  main.items.gear = 11; c.crafting_queue = {}; advance(1)
  local result = ok('action', {id = a.id})
  eq(result.status, 'completed'); eq(result.count, 4); eq(#begin_calls, 1); eq(#cancelled, 0)
end)

test('HandCraft detects engine queue ending without promised output', function()
  recipe(); local a = ok('hand_craft', {recipe = 'test'})
  c.crafting_queue = {}; advance(1)
  eq(ok('action', {id = a.id}).error.code, 'craft_incomplete')
end)

test('HandCraft Stop and timeout cancel owned queue exactly once', function()
  recipe()
  for _, stop in ipairs({true, false}) do
    local a = ok('hand_craft', {recipe = 'test', count = 3, timeout_ticks = 2})
    local before = #cancelled
    if stop then ok('stop') else advance(2) end
    eq(#cancelled, before + 1); eq(cancelled[#cancelled].count, 3)
    eq(cancelled[#cancelled].recipe, 'test'); eq(#c.crafting_queue, 0)
    local result = ok('action', {id = a.id})
    eq(result.status, stop and 'cancelled' or 'failed')
    if not stop then eq(result.error.code, 'timeout') end
    advance(3); ok('stop'); eq(#cancelled, before + 1)
  end
end)

-- Regression: another actor may append work after this action starts. It is not
-- owned by this action and must survive both cancellation paths.
for _, mode in ipairs({'Stop', 'timeout'}) do
  test('HandCraft ' .. mode .. ' preserves later unowned queue entries', function()
    recipe()
    ok('hand_craft', {recipe = 'test', count = 2, timeout_ticks = 2})
    c.crafting_queue[2] = {recipe = 'foreign', count = 5}
    if mode == 'Stop' then ok('stop') else advance(2) end
    eq(#c.crafting_queue, 1, 'unowned queue entry must survive')
    eq(c.crafting_queue[1].recipe, 'foreign')
    eq(#cancelled, 1); eq(cancelled[1].recipe, 'test')
  end)
end

test('HandCraft backfills only genuine production and consumption, exactly once', function()
  recipe('gear', 2)
  local a = ok('hand_craft', {recipe='test',count=2})
  main.items.gear = 4; c.crafting_queue = {}; advance(1)
  eq(ok('action',{id=a.id}).status,'completed')
  eq(c.force.stats.produced.gear,4); eq(c.force.stats.consumed['iron-plate'],4)
  eq(#c.force.stats.flows,2); advance(5); eq(#c.force.stats.flows,2)
end)
test('HandCraft does not double count statistics already reported by the engine', function()
  recipe('gear',2); ok('hand_craft',{recipe='test',count=2})
  main.items.gear=4; c.force.stats.produced.gear=4; c.force.stats.consumed['iron-plate']=4
  c.crafting_queue={}; advance(1); eq(#c.force.stats.flows,0)
end)
test('HandCraft cancellation counts completed output, never unfinished batches', function()
  recipe('gear',2); ok('hand_craft',{recipe='test',count=2})
  main.items.gear=2; advance(1); ok('stop')
  eq(c.force.stats.produced.gear,2); eq(c.force.stats.consumed['iron-plate'],2)
  eq(cancelled[1].count,1)
end)
test('count-only placement cannot refresh damaged building items', function()
  build('iron-chest',1,1)
  main[1]={valid_for_read=true,name='iron-chest',quality={name='normal'},health=.5}
  denied('unsupported_stack','build',{item='iron-chest',position={x=.5,y=.5}})
  eq(main.items['iron-chest'],10);eq(#created,0)
end)

test('NPC corpse recovery transfers real inventory and rejects player-owned corpses', function()
  game.get_player=function(i) if i==1 then return {index=1} end end
  local corpse=entity('character-corpse','character-corpse',{name='neutral'})
  corpse.character_corpse_player_index=0
  local recovered=native_inventory({{name='iron-plate',count=1135}})
  main=native_inventory({})
  c.get_main_inventory=function() return main end
  corpse.get_inventory=function(id) eq(id,defines.inventory.character_corpse);return recovered end
  local a={entity='character-corpse',position=corpse.position,inventory='main',direction='take',item='iron-plate',count=1000}
  ok('transfer',a);eq(main[1].count,1000);eq(recovered[1].count,135)
  a.count=135;ok('transfer',a);eq(main[1].count+main[2].count,1135);eq(recovered[1].count,0)
  corpse.character_corpse_player_index=1
  denied('invalid_target','transfer',a)
end)
print(string.format('Infrastructure: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
