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
local function transfer(direction, item, quality, count, legacy)
  local args = {entity = 'iron-chest', position = chest.position, inventory = 'main',
    direction = direction, item = item, count = count}
  if not legacy then args.quality = quality end
  return legacy and 'transfer' or 'transfer_quality', args
end
local function move(direction, item, quality, count, legacy)
  local method, args = transfer(direction, item, quality, count, legacy)
  return ok(method, args)
end
local function count(inv, item, quality)
  return inv.get_item_count{name = item, quality = quality}
end
local function stack(inv, item, quality)
  return assert(inv.find_item_stack{name = item, quality = quality}, 'missing native stack')
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
