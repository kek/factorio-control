-- Isolated engine tests, never installed by scripts/server. No fixture runs in
-- ordinary saves: this requires Factorio's offline --test-scenario test argument.
assert(script.test_arg == 'factorio-control-native-tests/v1', 'Use the isolated headless test runner')
assert(script.active_mods.base == '2.1.24', 'These tests require Factorio 2.1.24')

local actor, chest, source, carried, assembler2, assembler3
local completed, current = {}, 'setup'
local function eq(actual, expected)
  assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
local function request(method, args)
  local envelope = {method = method, args = args, bot = 'default'}
  local response = remote.call('bot', 'request', envelope)
  helpers.write_file('native-effects.jsonl', helpers.table_to_json{
    case_name = current, request = envelope, response = response} .. '\n', true)
  return response
end
local function ok(method, args)
  local response = request(method, args)
  assert(response.ok, helpers.table_to_json(response))
  return response.data
end
local function reject(code, method, args)
  local response = request(method, args)
  assert(not response.ok, 'unexpected acceptance')
  eq(response.error.code, code)
end
local function transfer(direction, item, quality, count, legacy, target, inventory_name)
  target = target or chest
  local args = {entity = target.name, position = target.position, inventory = inventory_name or 'main',
    direction = direction, item = item, count = count}
  if not legacy then args.quality = quality end
  return legacy and 'transfer' or 'transfer_quality', args
end
local function move(...)
  local method, args = transfer(...)
  return ok(method, args)
end
local function count(inv, item, quality)
  return inv.get_item_count{name = item, quality = quality}
end
local function stack(inv, item, quality)
  local found = inv.find_item_stack{name = item, quality = quality}
  assert(found, 'missing native stack')
  return found
end
local function empty_items()
  carried.clear(); source.clear(); source.set_bar()
end
local function recipe_args(e, recipe)
  return {name = e.name, position = e.position, recipe = recipe}
end
local function selected(e, name)
  local recipe, quality = e.get_recipe()
  eq(recipe and recipe.name, name); eq(quality.name, 'normal')
end
local function set(e, name)
  eq(ok('set_recipe', recipe_args(e, name)).recipe, name)
  selected(e, name)
end
local function prepare(e, name)
  e.recipe_locked = false; e.crafting_progress = 0; e.bonus_progress = 0
  for _, kind in ipairs{'crafter_input', 'crafter_output', 'crafter_trash', 'assembling_machine_dump'} do
    local inv = e.get_inventory(defines.inventory[kind])
    if inv then inv.clear() end
  end
  local modules = e.get_module_inventory(); if modules then modules.clear() end
  for i = 1, e.fluids_count do e.remove_fluid(i, 1000000000) end
  assert(not next(e.set_recipe(name, 'normal')), 'fixture setup unexpectedly ejected items')
  selected(e, name)
end
local function transport_snapshot(e)
  local lanes = {}
  for i = 1, e.get_max_transport_line_index() do
    lanes[i] = {index = i, items = e.get_transport_line(i).get_contents()}
  end
  return lanes
end
local function transport_signature(lanes)
  local rows = {}
  for _, lane in ipairs(lanes) do
    rows[#rows + 1] = lane.index .. ':present'
    for _, item in ipairs(lane.items) do
      rows[#rows + 1] = lane.index .. ':' .. item.name .. '@' .. item.quality .. '=' .. item.count
    end
  end
  table.sort(rows)
  return table.concat(rows, '\n')
end
local function test(name, body)
  current = name
  body()
  completed[#completed + 1] = name
  log('FACTORIO_CONTROL_NATIVE_PASS ' .. name)
end

local function setup()
  local surface = game.surfaces.nauvis
  surface.request_to_generate_chunks({0, 0}, 1)
  surface.force_generate_chunk_requests()
  for _, e in pairs(surface.find_entities_filtered{area = {{-16, -16}, {16, 16}}}) do
    if e.type ~= 'character' then e.destroy() end
  end
  local tiles = {}
  for x = -16, 16 do for y = -16, 16 do
    tiles[#tiles + 1] = {name = 'stone-path', position = {x, y}}
  end end
  surface.set_tiles(tiles)
  local force = game.forces.player
  for _, name in ipairs{'iron-gear-wheel', 'copper-cable', 'electric-engine-unit', 'sulfur'} do
    assert(force.recipes[name], 'missing fixture recipe ' .. name).enabled = true
  end
  local spawned = ok('spawn', {position = {x = 0, y = 0}})
  local actors = surface.find_entities_filtered{type = 'character', position = spawned.position, radius = 0.1}
  eq(#actors, 1); actor = actors[1]; carried = actor.get_main_inventory()
  chest = assert(surface.create_entity{name = 'iron-chest', position = {3.5, 0.5}, force = force})
  source = chest.get_inventory(defines.inventory.chest)
  assembler2 = assert(surface.create_entity{name = 'assembling-machine-2', position = {-2.5, 3.5}, force = force})
  assembler3 = assert(surface.create_entity{name = 'assembling-machine-3', position = {3.5, 4.5}, force = force})
end

local function run()
  setup()
  test('transport-tiers-qualities-and-modded-prototypes', function()
    for _, family in ipairs{
      {'transport-belt',2,{'transport-belt','fast-transport-belt','express-transport-belt','native-test-belt'}},
      {'underground-belt',4,{'underground-belt','fast-underground-belt','express-underground-belt','native-test-underground'}},
      {'splitter',8,{'splitter','fast-splitter','express-splitter','native-test-splitter'}}
    } do
      for _, name in ipairs(family[3]) do for _, quality in ipairs{'normal','uncommon','rare','epic','legendary'} do
        local direction = quality == 'normal' and defines.direction.north or defines.direction.east
        local p = {4.5,-4.5}
        if family[1]=='splitter' then
          p = direction == defines.direction.north and {4,-4.5} or {4.5,-4}
        end
        local force = quality == 'rare' and game.forces.enemy or actor.force
        local e = assert(actor.surface.create_entity{name=name,position=p,direction=direction,quality=quality,force=force})
        eq(e.type,family[1]); eq(e.quality.name,quality)
        eq(e.get_max_transport_line_index(),family[2])
        assert(e.get_transport_line(1).insert_at_back{name='iron-plate',quality='rare',count=1})
        assert(e.get_transport_line(2).insert_at_back{name='copper-plate',quality='uncommon',count=1})
        local before = transport_signature(transport_snapshot(e))
        local snapshot = ok('inspect_transport',{name=e.name,position=e.position})
        eq(snapshot.name,name); eq(snapshot.direction,direction)
        eq(snapshot.position.x,e.position.x); eq(snapshot.position.y,e.position.y)
        eq(#snapshot.lanes,family[2])
        for i,lane in ipairs(snapshot.lanes) do eq(lane.index,i) end
        eq(transport_signature(snapshot.lanes),before)
        eq(transport_signature(transport_snapshot(e)),before)
        eq(e.direction,direction); eq(e.force,force); eq(e.quality.name,quality)
        assert(carried.is_empty())
        e.destroy()
      end end
    end
  end)
  test('transport-invalid-targets-and-bounds', function()
    local args = {name=chest.name,position=chest.position}
    reject('unsupported_transport','inspect_transport',args)
    local ghost = assert(actor.surface.create_entity{name='entity-ghost',inner_name='transport-belt',position={4.5,-4.5},force=actor.force})
    eq(ghost.ghost_name,'transport-belt')
    reject('unsupported_transport','inspect_transport',{name='entity-ghost',position=ghost.position})
    assert(ghost.valid); ghost.destroy()
    reject('invalid_argument','inspect_transport',{name='unknown-native-transport-prototype',position={x=4.5,y=-4.5}})
    reject('not_found','inspect_transport',{name='fast-splitter',position={x=4,y=-4.5}})
    reject('out_of_range','inspect_transport',{name='express-transport-belt',position={x=65,y=0}})
    assert(carried.is_empty()); assert(source.is_empty())
  end)
  test('exact-quality-and-legacy', function()
    empty_items()
    for _, quality in ipairs{'normal', 'uncommon', 'rare', 'epic', 'legendary'} do
      eq(source.insert{name = 'iron-plate', quality = quality, count = 5}, 5)
    end
    for _, quality in ipairs{'normal', 'uncommon', 'rare', 'epic', 'legendary'} do
      local receipt = move('take', 'iron-plate', quality, 3)
      eq(receipt.count, 3); eq(receipt.quality, quality)
      eq(count(carried, 'iron-plate', quality), 3)
      eq(count(source, 'iron-plate', quality), 2)
      eq(move('give', 'iron-plate', quality, 3).count, 3)
      eq(count(source, 'iron-plate', quality), 5)
    end
    local legacy = move('take', 'iron-plate', 'normal', 2, true)
    eq(legacy.count, 2); eq(legacy.quality, nil)
    eq(move('give', 'iron-plate', 'normal', 2, true).count, 2)
    eq(count(source, 'iron-plate', 'rare'), 5)
  end)
  test('no-quality-substitution', function()
    empty_items()
    eq(source.insert{name = 'iron-plate', count = 10}, 10)
    local method, args = transfer('take', 'iron-plate', 'rare', 1)
    reject('no_item', method, args)
    eq(count(source, 'iron-plate', 'normal'), 10); assert(carried.is_empty())
    args.quality = 'unknown-native-test-quality'
    reject('invalid_quality', method, args)
    eq(count(source, 'iron-plate', 'normal'), 10); assert(carried.is_empty())
  end)
  test('rare-partial-capacity', function()
    empty_items(); source.set_bar(2)
    eq(carried.insert{name = 'iron-plate', quality = 'rare', count = 150}, 150)
    local r = move('give', 'iron-plate', 'rare', 150)
    eq(r.count, 100); eq(r.quality, 'rare')
    eq(count(carried, 'iron-plate', 'rare'), 50)
    eq(count(source, 'iron-plate', 'rare'), 100)
    eq(move('take', 'iron-plate', 'rare', 100).count, 100)
    eq(count(carried, 'iron-plate', 'rare'), 150)
  end)
  test('partial-ammunition', function()
    empty_items()
    assert(source[1].set_stack{name = 'firearm-magazine', quality = 'rare', count = 1})
    source[1].ammo = 3
    move('take', 'firearm-magazine', 'rare', 1)
    eq(stack(carried, 'firearm-magazine', 'rare').ammo, 3)
    move('give', 'firearm-magazine', 'rare', 1)
    eq(stack(source, 'firearm-magazine', 'rare').ammo, 3)
  end)
  test('blueprint-metadata', function()
    empty_items()
    assert(source[1].set_stack{name = 'blueprint', count = 1})
    local bp = source[1]
    bp.set_blueprint_entities{{entity_number = 1, name = 'transport-belt',
      position = {0, 0}, direction = defines.direction.east}}
    bp.label = 'native-integration-blueprint'
    bp.set_blueprint_entity_tag(1, 'integration', 'preserved')
    local id = assert(bp.item_number)
    move('take', 'blueprint', 'normal', 1)
    bp = stack(carried, 'blueprint', 'normal')
    eq(bp.label, 'native-integration-blueprint'); eq(bp.item_number, id)
    eq(bp.get_blueprint_entities()[1].direction, defines.direction.east)
    eq(bp.get_blueprint_entity_tag(1, 'integration'), 'preserved')
    move('give', 'blueprint', 'normal', 1)
    eq(stack(source, 'blueprint', 'normal').item_number, id)
  end)
  test('equipped-armor', function()
    empty_items()
    assert(source[1].set_stack{name = 'power-armor-mk2', quality = 'rare', count = 1})
    local grid = assert(source[1].grid)
    local equipment = assert(grid.put{name = 'battery-equipment', quality = 'uncommon', position = {0, 0}})
    equipment.energy = 1234
    move('take', 'power-armor-mk2', 'rare', 1)
    equipment = assert(stack(carried, 'power-armor-mk2', 'rare').grid.get{0, 0})
    eq(equipment.name, 'battery-equipment'); eq(equipment.quality.name, 'uncommon'); eq(equipment.energy, 1234)
    move('give', 'power-armor-mk2', 'rare', 1)
    eq(stack(source, 'power-armor-mk2', 'rare').grid.get{0, 0}.energy, 1234)
  end)
  test('damaged-stack', function()
    empty_items()
    assert(source[1].set_stack{name = 'iron-chest', quality = 'epic', count = 1})
    source[1].health = 0.4
    move('take', 'iron-chest', 'epic', 1)
    assert(math.abs(stack(carried, 'iron-chest', 'epic').health - 0.4) < 0.001)
    move('give', 'iron-chest', 'epic', 1)
    assert(math.abs(stack(source, 'iron-chest', 'epic').health - 0.4) < 0.001)
  end)
  test('logistic-container-inventories', function()
    for _, name in ipairs{'passive-provider-chest', 'active-provider-chest', 'storage-chest', 'buffer-chest', 'requester-chest'} do
      empty_items()
      local e = assert(actor.surface.create_entity{name=name,position={-3.5,-1.5},force=actor.force})
      eq(e.type, 'logistic-container')
      local inv=e.get_inventory(defines.inventory.chest)
      eq(inv.insert{name='iron-plate',quality='normal',count=10},10)
      eq(inv.insert{name='iron-plate',quality='rare',count=5},5)
      eq(move('take','iron-plate','rare',2,false,e).count,2)
      eq(move('give','iron-plate','rare',2,false,e).count,2)
      eq(move('take','iron-plate','normal',1,true,e).count,1)
      eq(move('give','iron-plate','normal',1,true,e).count,1)
      for _, method in ipairs{'inspect_entity','inspect_machine'} do
        local snapshot=ok(method,{name=e.name,position=e.position})
        local n=0
        for _, s in ipairs(snapshot.inventory) do n=n+s.count end
        eq(n,15); eq(#snapshot.modules,0)
      end
      inv.clear(); carried.clear()
      if inv.supports_bar() then
        eq(ok('set_chest_limit',{name=e.name,position=e.position,slots=1}).slots,1)
        eq(inv.get_bar(),2)
        eq(carried.insert{name='transport-belt',count=108},108)
        eq(move('give','transport-belt','normal',108,false,e).count,100)
        eq(move('take','transport-belt','normal',100,false,e).count,100)
        eq(count(carried,'transport-belt','normal'),108)
      else
        reject('unsupported_inventory','set_chest_limit',{name=e.name,position=e.position,slots=1})
      end
      e.destroy()
    end
  end)
  test('machine-module-transfers', function()
    empty_items(); prepare(assembler2,'iron-gear-wheel')
    local inv=assert(assembler2.get_module_inventory())
    eq(#inv,2)
    eq(carried.insert{name='speed-module',quality='rare',count=3},3)
    eq(carried.insert{name='speed-module',quality='normal',count=2},2)
    local r=move('give','speed-module','rare',3,false,assembler2,'modules')
    eq(r.count,2); eq(r.quality,'rare')
    eq(count(inv,'speed-module','rare'),2)
    eq(count(carried,'speed-module','rare'),1); eq(count(carried,'speed-module','normal'),2)
    eq(carried.insert{name='speed-module',quality='legendary',count=1},1)
    local full_method,full_args=transfer('give','speed-module','legendary',1,false,assembler2,'modules')
    reject('inventory_full',full_method,full_args)
    eq(count(inv,'speed-module','rare'),2); eq(count(carried,'speed-module','legendary'),1)
    for _, method in ipairs{'inspect_entity','inspect_machine'} do
      local snapshot=ok(method,{name=assembler2.name,position=assembler2.position})
      eq(snapshot.modules[1].name,'speed-module'); eq(snapshot.modules[1].quality,'rare'); eq(snapshot.modules[1].count,2)
    end
    reject('machine_not_empty','set_recipe',recipe_args(assembler2,'copper-cable'))
    eq(move('take','speed-module','rare',2,false,assembler2,'modules').count,2)
    eq(count(carried,'speed-module','rare'),3)
    set(assembler2,'copper-cable')
    eq(move('give','speed-module','normal',1,true,assembler2,'modules').count,1)
    eq(move('take','speed-module','normal',1,true,assembler2,'modules').count,1)
    eq(carried.insert{name='iron-plate',count=1},1)
    local method,args=transfer('give','iron-plate','normal',1,false,assembler2,'modules')
    reject('invalid_argument',method,args); eq(count(carried,'iron-plate','normal'),1)
    method,args=transfer('give','speed-module','rare',1,false,chest,'modules')
    reject('invalid_inventory',method,args); eq(count(carried,'speed-module','rare'),3)
    local beacon=assert(actor.surface.create_entity{name='beacon',position={-3.5,-4.5},force=actor.force})
    local beacon_modules=assert(beacon.get_module_inventory())
    eq(carried.insert{name='productivity-module',quality='rare',count=1},1)
    assert(not beacon_modules.can_insert(stack(carried,'productivity-module','rare')), 'fixture requires a native module incompatibility')
    method,args=transfer('give','productivity-module','rare',1,false,beacon,'modules')
    reject('inventory_full',method,args)
    assert(beacon_modules.is_empty()); eq(count(carried,'productivity-module','rare'),1)
    beacon.destroy()
  end)
  test('inventory-permission-guards', function()
    empty_items(); prepare(assembler2,'iron-gear-wheel')
    local inv=assembler2.get_module_inventory()
    eq(inv.insert{name='speed-module',quality='rare',count=1},1)
    assembler2.force=game.forces.enemy
    local method,args=transfer('take','speed-module','rare',1,false,assembler2,'modules')
    reject('invalid_target',method,args)
    local snapshot=ok('inspect_entity',{name=assembler2.name,position=assembler2.position})
    eq(snapshot.modules,nil)
    snapshot=ok('inspect_machine',{name=assembler2.name,position=assembler2.position})
    eq(#snapshot.modules,0); eq(count(inv,'speed-module','rare'),1)
    assembler2.force=actor.force; inv.clear()
    local e=assert(actor.surface.create_entity{name='storage-chest',position={14.5,0.5},force=actor.force})
    assert(not actor.can_reach_entity(e), 'fixture must be out of interaction reach')
    method,args=transfer('take','iron-plate','normal',1,false,e)
    reject('out_of_reach',method,args)
    e.destroy()
  end)
  test('dry-fluid-capable-assembler-tiers', function()
    for _, e in ipairs{assembler2, assembler3} do
      assert(next(e.prototype.fluidbox_prototypes), 'fixture must be genuinely fluid-capable')
      assert(e.prototype.ingredient_count >= 1)
      prepare(e, 'copper-cable')
      set(e, 'iron-gear-wheel'); set(e, 'copper-cable')
    end
  end)
  test('nonempty-input-output-and-modules', function()
    local e = assembler2
    prepare(e, 'iron-gear-wheel')
    local input = e.get_inventory(defines.inventory.crafter_input)
    eq(input.insert{name = 'iron-plate', count = 1}, 1)
    set(e, 'iron-gear-wheel') -- same-recipe no-op while nonempty
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'copper-cable'))
    selected(e, 'iron-gear-wheel'); eq(input.get_item_count('iron-plate'), 1)
    input.clear(); set(e, 'copper-cable')
    local output = e.get_output_inventory()
    assert(output[1].set_stack{name = 'copper-cable', count = 2})
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'iron-gear-wheel'))
    selected(e, 'copper-cable'); eq(output.get_item_count('copper-cable'), 2)
    output.clear()
    local modules = e.get_module_inventory()
    eq(modules.insert{name = 'speed-module', count = 1}, 1)
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'iron-gear-wheel'))
    eq(modules.get_item_count('speed-module'), 1)
    modules.clear(); set(e, 'iron-gear-wheel')
  end)
  test('native-progress-and-recipe-locks', function()
    local e = assembler2
    prepare(e, 'iron-gear-wheel')
    e.crafting_progress = 0.25
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'copper-cable'))
    eq(e.crafting_progress, 0.25); e.crafting_progress = 0
    e.bonus_progress = 0.25
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'copper-cable'))
    eq(e.bonus_progress, 0.25); e.bonus_progress = 0
    e.recipe_locked = true
    reject('recipe_locked', 'set_recipe', recipe_args(e, 'copper-cable'))
    set(e, 'iron-gear-wheel'); eq(e.recipe_locked, true)
    e.recipe_locked = false
  end)
  test('fluid-residue-is-preserved', function()
    local e = assembler2
    prepare(e, 'electric-engine-unit')
    eq(e.insert_fluid{name = 'lubricant', amount = 1}, 1)
    assert(e.fluids_count > 0)
    reject('machine_not_empty', 'set_recipe', recipe_args(e, 'iron-gear-wheel'))
    selected(e, 'electric-engine-unit')
    eq(e.get_fluid_contents().lubricant, 1)
    for i = 1, e.fluids_count do e.remove_fluid(i, 1000000000) end
    set(e, 'iron-gear-wheel')
    assert(not next(e.get_fluid_contents()))
  end)
  test('unsupported-and-locked-recipes', function()
    local e = assembler2
    prepare(e, 'iron-gear-wheel')
    reject('unsupported_recipe', 'set_recipe', recipe_args(e, 'electric-engine-unit'))
    reject('unsupported_recipe', 'set_recipe', recipe_args(e, 'sulfur'))
    game.forces.player.recipes['copper-cable'].enabled = false
    reject('invalid_recipe', 'set_recipe', recipe_args(e, 'copper-cable'))
    selected(e, 'iron-gear-wheel')
  end)
end

script.on_event(defines.events.on_tick, function()
  if storage.native_tests_finished then return end
  storage.native_tests_finished = true
  local passed, error_message = pcall(run)
  local result = {suite = 'factorio-control-native-tests/v1', passed = passed,
    completed = completed, current = current, error = passed and '' or tostring(error_message)}
  helpers.write_file('native-results.json', helpers.table_to_json(result), false)
  log('FACTORIO_CONTROL_NATIVE_RESULT ' .. helpers.table_to_json(result))
  script.finish_test(passed)
end)
