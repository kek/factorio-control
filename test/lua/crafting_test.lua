-- Pure Lua lifecycle checks: no Factorio process, RCON, or game world required.
defines = {direction = {}, entity_status = {}, events = {on_tick = 1}}
for i, name in ipairs({'north','northeast','east','southeast','south','southwest','west','northwest'}) do defines.direction[name] = i end
local tick, request
script = {
  on_init = function(_) end,
  on_event = function(_, fn) tick = fn end,
  active_mods = {base = '2.1.24'}
}
remote = {add_interface = function(_, interface) request = interface.request end}
game = {tick = 0}
prototypes = {item = {gear = {type = 'item'}}}
storage = {}
dofile('mods/factorio-control/control.lua')

local items, full, recipe
local function reset(iron)
  items, full = {['iron-plate'] = iron, gear = 0}, false
  recipe = {name = 'gear', enabled = true, energy = 0.5, categories = {'crafting'},
    ingredients = {{name = 'iron-plate', type = 'item', amount = 2}},
    products = {{name = 'gear', type = 'item', amount = 1}},
    has_category = function(name) return name == 'crafting' end}
  local c = {valid = true, force = {recipes = {gear = recipe}}, clear_selected_entity = function() end}
  c.get_item_count = function(filter) return items[filter.name] or 0 end
  c.get_main_inventory = function() return {get_insertable_count = function(_) return full and 0 or 100 end} end
  c.remove_item = function(stack)
    local removed = math.min(items[stack.name] or 0, stack.count)
    items[stack.name] = (items[stack.name] or 0) - removed
    return removed
  end
  c.insert = function(stack)
    assert(not full)
    items[stack.name] = (items[stack.name] or 0) + stack.count
    return stack.count
  end
  storage.bot = {sequence = 0, actions = {}, character = c}
  game.tick = 0
end
local function call(method, args) return request{method = method, args = args or {}} end
local function advance(n) for _ = 1, n do game.tick = game.tick + 1 tick() end end
local function craft(n, deadline)
  return call('craft', {recipe = 'gear', count = n, timeout_ticks = deadline or 600})
end

reset(3)
assert(craft(2).error.code == 'not_craftable')
assert(items['iron-plate'] == 3 and items.gear == 0 and not storage.bot.active)

reset(4)
assert(craft(2).ok)
advance(29)
assert(items['iron-plate'] == 4 and items.gear == 0)
advance(1)
assert(items['iron-plate'] == 2 and items.gear == 1)
advance(30)
assert(items['iron-plate'] == 0 and items.gear == 2)
assert(call('action', {id = 1}).data.status == 'completed')
assert(call('action', {id = 1}).data.count == 2)

reset(4)
assert(craft(2).ok)
advance(30)
assert(call('stop').ok)
advance(100)
assert(items['iron-plate'] == 2 and items.gear == 1)
assert(call('action', {id = 1}).data.status == 'cancelled')

reset(4)
assert(craft(2, 31).ok)
advance(100)
assert(items['iron-plate'] == 2 and items.gear == 1)
assert(call('action', {id = 1}).data.error.code == 'timeout')

reset(4)
assert(craft(2).ok)
full = true
advance(30)
assert(items['iron-plate'] == 4 and items.gear == 0)
assert(call('action', {id = 1}).data.error.code == 'inventory_full')

reset(4)
recipe.enabled = false
assert(craft(1).error.code == 'invalid_recipe')
recipe.enabled = true
recipe.products[1].probability = 0.5
assert(craft(1).error.code == 'unsupported_recipe')
recipe.products[1].probability = 1
recipe.ingredients[1].type = 'fluid'
assert(craft(1).error.code == 'not_craftable')
assert(items['iron-plate'] == 4 and items.gear == 0)
print('PASS: crafting costs, timing, cancellation, deadlines, capacity and recipe restrictions')
