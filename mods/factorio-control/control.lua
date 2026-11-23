-- API target: Factorio 2.1.25. No network, file input, or per-tick world scans.
local methods = {}
local directions = {
  north = defines.direction.north, northeast = defines.direction.northeast,
  east = defines.direction.east, southeast = defines.direction.southeast,
  south = defines.direction.south, southwest = defines.direction.southwest,
  west = defines.direction.west, northwest = defines.direction.northwest
}
-- Prototype capability, not a list of base-game names. Characters, resources,
-- ghosts and corpses do not have a real item placement recipe.
local function placed_infrastructure(e)
  if e.type == "character" or e.type == "unit" or e.type == "resource" or
      e.type == "entity-ghost" or e.type == "tile-ghost" or
      e.type == "character-corpse" or e.type == "corpse" then return false end
  local items = e.prototype.items_to_place_this
  return items ~= nil and items[1] ~= nil
end
local function mineable_object(c, e)
  return e.valid and e.minable and (
    (e.force.name == "neutral" and (e.type == "tree" or e.type == "simple-entity")) or
    (e.force == c.force and placed_infrastructure(e)))
end
local function supported_product(name)
  return prototypes.item[name] ~= nil
end
local status_names = {}
for name, value in pairs(defines.entity_status) do status_names[value] = name end

local function fail(code, message)
  error({code = code, message = message}, 0)
end
local function check(condition, code, message)
  if not condition then fail(code, message) end
end
local function number(value, name, min, max)
  check(type(value) == "number" and value == value and value >= min and value <= max,
    "invalid_argument", name .. " is out of range")
  return value
end
local function integer(value, name, min, max)
  number(value, name, min, max)
  check(value == math.floor(value), "invalid_argument", name .. " must be an integer")
  return value
end
local function position(value)
  check(type(value) == "table", "invalid_argument", "position is required")
  return {x = number(value.x, "x", -1000000, 1000000),
          y = number(value.y, "y", -1000000, 1000000)}
end
local function distance(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end
-- Factorio dispatches requests and tick handlers synchronously. This context is
-- selected only by the trusted request envelope, never by individual effects.
local selected_bot = "default"
local MAX_BOTS = 8
local function registry()
  storage.bot = storage.bot or {sequence = 0, actions = {}}
  storage.bots = storage.bots or {}
  -- Preserve the legacy object (including its inventory and in-flight action).
  -- Keep storage.bot as a compatibility alias for the default actor.
  storage.bots.default = storage.bot
  return storage.bots
end
local function state()
  local b = registry()[selected_bot]
  check(b ~= nil, "unknown_bot", "Spawn the selected bot explicitly first")
  return b
end
local function character()
  local c = state().character
  check(c and c.valid, "no_character", "Spawn the bot first; a dead character requires an explicit respawn")
  return c
end
local function idle()
  check(not state().active, "busy", "Stop or await the active action first")
end
local function contents(inventory)
  return inventory and inventory.get_contents() or {}
end
local function module_contents(e)
  local result = contents(e.get_module_inventory())
  check(#result <= 256, "unsupported_inventory", "Too many distinct module stacks")
  return result
end
local function undamaged(inventory, item)
  for i = 1, #inventory do
    local s = inventory[i]
    if s.valid_for_read and s.name == item and s.quality.name == "normal" then
      check(s.health == nil or s.health == 1, "unsupported_stack", "Damaged item stacks require metadata-preserving handling")
    end
  end
end
local function ammo_rounds(c, slot)
  local inv = c.get_inventory(defines.inventory.character_ammo)
  local s = inv and inv[slot]
  if not s or not s.valid_for_read then return 0 end
  return (s.count - 1) * s.prototype.magazine_size + s.ammo
end
local function combat_target(c, e)
  return e and e.valid and e.force.name == 'enemy' and not c.force.get_friend(e.force)
    and not c.force.get_cease_fire(e.force) and e.health and e.health > 0
    and (e.type == 'unit' or e.type == 'turret' or e.type == 'unit-spawner')
end
local function halt()
  local c = state().character
  if c and c.valid then
    c.walking_state = {walking = false}
    c.mining_state = {mining = false}
    if defines.shooting then c.shooting_state = {state = defines.shooting.not_shooting, position = c.position} end
    c.clear_selected_entity()
  end
end
local function public_action(a)
  return {id = a.id, kind = a.kind, status = a.status, started_tick = a.started_tick,
    finished_tick = a.finished_tick, deadline_tick = a.deadline_tick, error = a.error,
    position = a.position, count = a.count, target_gone = a.target_gone,
    initial_health_milli = a.initial_health_milli, final_health_milli = a.final_health_milli}
end
local function report_hand_craft(c, a)
  -- Standalone character queues do not report force production like player
  -- queues. Backfill only missing statistics for output actually observed in
  -- inventory; never set a technology or create another item.
  local stats = c.force.get_item_production_statistics(c.surface)
  local observed = math.min(a.count, a.requested)
  local item = {name = a.item, quality = "normal"}
  local missing = observed - math.max(0, stats.get_input_count(item) - a.production_before)
  if missing > 0 then stats.on_flow(item, missing) end
  local completed = math.floor(observed / a.per_craft)
  for _, ingredient in ipairs(a.ingredients) do
    local key = {name = ingredient.name, quality = "normal"}
    local consumed = completed * ingredient.amount
    local recorded = math.max(0, stats.get_output_count(key) - a.consumption_before[ingredient.name])
    if consumed > recorded then stats.on_flow(key, -(consumed - recorded)) end
  end
end

local function finish(status, code, message)
  local b = state()
  local a = b.active
  if not a then return end
  if a.kind == 'attack' and b.character and b.character.valid then
    a.count = math.max(0, a.initial_rounds - ammo_rounds(b.character, a.gun_slot))
    a.target_gone = not (a.target and a.target.valid)
    a.final_health_milli = a.target_gone and 0 or math.floor((a.target.health or 0) * 1000 + 0.5)
  end
  halt()
  if a.kind == "hand-craft" and status ~= "completed" and b.character and b.character.valid then
    local c = b.character
    a.count = math.max(0, c.get_item_count{name = a.item, quality = "normal"} - a.initial)
    local remaining = math.max(0, a.batches - math.floor(a.count / a.per_craft))
    local queue = c.crafting_queue or {}
    -- The queue was empty on submission. Cancel only the remaining owned
    -- batches at its head, never later work another controller may have added.
    if remaining > 0 and queue[1] and queue[1].recipe == a.recipe then
      c.cancel_crafting{index = 1, count = math.min(remaining, queue[1].count)}
    end
  end
  if a.kind == "hand-craft" and b.character and b.character.valid then
    report_hand_craft(b.character, a)
  end
  a.status, a.finished_tick = status, game.tick
  if code then a.error = {code = code, message = message} end
  b.active = nil
  -- Entity references are only needed while running; don't retain dead targets.
  a.target = nil
end
local function start(kind, args)
  idle()
  local b = state()
  local ticks = integer(args.timeout_ticks or 1800, "timeout_ticks", 1, 3600)
  b.sequence = b.sequence + 1
  local a = {id = b.sequence, kind = kind, status = "running", started_tick = game.tick,
    deadline_tick = game.tick + ticks}
  b.actions[a.id], b.active = a, a
  b.actions[a.id - 64] = nil
  return a
end
local function find_target(c, name, pos, any_quality)
  local e
  if any_quality then
    local found = c.surface.find_entities_filtered{name = name, position = pos, limit = 2}
    check(#found < 2, "ambiguous_target", "More than one matching entity at position")
    e = found[1]
  else
    -- Mutation callers retain the native bare-name/normal-quality lookup.
    e = c.surface.find_entity(name, pos)
  end
  if not e and name == "character-corpse" then
    -- Corpses are not tile-aligned; the typed half-tile point can be up to
    -- sqrt(.25^2+.25^2) away from their exact position.
    local near = c.surface.find_entities_filtered{name = name, position = pos, radius = 0.4, limit = 2}
    check(#near < 2, "ambiguous_target", "More than one corpse is near the requested point")
    e = near[1]
  end
  return e
end
local function npc_corpse(e)
  return e.type == "character-corpse" and not game.get_player(e.character_corpse_player_index)
end
local function entity_summary(e)
  local out = {name = e.name, type = e.type, position = e.position, unit_number = e.unit_number,
    direction = e.direction, supports_direction = e.supports_direction,
    rotatable = e.rotatable, minable = e.minable}
  if e.type == "resource" then out.amount = e.amount end
  if e.type == "inserter" then
    out.pickup_position = e.pickup_position
    out.pickup_target = e.pickup_target and e.pickup_target.name
  end
  if e.type == "inserter" or e.type == "mining-drill" then
    out.drop_position = e.drop_position
    out.drop_target = e.drop_target and e.drop_target.name
  end
  if e.force.name == character().force.name then
    if e.type == "character" then out.inventory = contents(e.get_main_inventory()) end
    if e.type == "container" or e.type == "logistic-container" then
      out.inventory = contents(e.get_inventory(defines.inventory.chest))
    end
  end
  if npc_corpse(e) then out.inventory = contents(e.get_inventory(defines.inventory.character_corpse)) end
  if e.force.name == character().force.name and e.type ~= "character" then
    out.status = e.status
    out.status_name = status_names[e.status] or "unknown"
    out.fuel = contents(e.get_fuel_inventory())
    out.modules = module_contents(e)
    out.output = contents(e.get_output_inventory())
    if e.type == "furnace" or e.type == "assembling-machine" then
      out.input = contents(e.get_inventory(defines.inventory.crafter_input))
    end
  end
  return out
end

function methods.spawn(args)
  local b = state()
  if b.character and b.character.valid then
    return {position = b.character.position, existing = true}
  end
  idle()
  local surface = game.surfaces[args.surface or "nauvis"]
  check(surface and surface.valid, "invalid_argument", "Unknown surface")
  local force = game.forces.player
  local pos = position(args.position or force.get_spawn_position(surface))
  local free = surface.find_non_colliding_position("character", pos, 16, 0.5)
  check(free, "blocked", "No safe spawn position")
  local c = surface.create_entity{name = "character", position = free, force = force}
  check(c, "blocked", "Character creation failed")
  b.character = c
  halt()
  return {position = c.position, existing = false}
end

local equipment_inventories = {
  armor = defines.inventory.character_armor,
  guns = defines.inventory.character_guns,
  ammo = defines.inventory.character_ammo
}
local function equipment_slot(inv, index, s)
  return {inventory = inv, slot = index, name = s.valid_for_read and s.name or "",
    quality = s.valid_for_read and s.quality.name or "", count = s.valid_for_read and s.count or 0,
    health_milli = s.valid_for_read and math.floor((s.health or 1) * 1000 + 0.5) or 0,
    ammo = s.valid_for_read and s.prototype.type == "ammo" and s.ammo or 0}
end
function methods.inspect_equipment(args)
  local c = character()
  local slots, candidates, truncated = {}, {}, false
  for _, name in ipairs{"armor", "guns", "ammo"} do
    local inv = c.get_inventory(equipment_inventories[name])
    if inv then
      for i = 1, #inv do slots[#slots + 1] = equipment_slot(name, i, inv[i]) end
    end
  end
  local main = c.get_main_inventory()
  local empty_main_slots = {}
  for i = 1, #main do
    local s = main[i]
    if not s.valid_for_read and #empty_main_slots < 32 then empty_main_slots[#empty_main_slots + 1] = i end
    if s.valid_for_read and (s.prototype.type == "armor" or s.prototype.type == "gun" or s.prototype.type == "ammo") then
      if #candidates < 32 then candidates[#candidates + 1] = equipment_slot("main", i, s)
      else truncated = true end
    end
  end
  return {slots = slots, candidates = candidates, truncated = truncated, empty_main_slots = empty_main_slots, main_size = #main}
end
function methods.equip(args)
  local c = character(); idle()
  local kind = equipment_inventories[args.inventory]
  check(kind, "invalid_argument", "inventory must be armor, guns or ammo")
  check(args.direction == "equip" or args.direction == "unequip", "invalid_argument", "direction must be equip or unequip")
  local gear, main = c.get_inventory(kind), c.get_main_inventory()
  check(gear and main, "unsupported_inventory", "Character equipment inventory unavailable")
  local index = integer(args.slot, "slot", 1, #gear)
  local main_index = integer(args.main_slot, "main_slot", 1, math.min(#main, 1000))
  local src, dst = main[main_index], gear[index]
  if args.direction == "unequip" then src, dst = dst, src end
  check(src.valid_for_read, "empty_source", "Source slot is empty")
  check(not dst.valid_for_read, "occupied_destination", "Destination must be empty; no implicit swap")
  local expected = ({armor = "armor", guns = "gun", ammo = "ammo"})[args.inventory]
  check(src.prototype.type == expected, "invalid_item", "Item type does not match equipment inventory")
  -- Refuse armor removal if shrinking the main inventory could displace items.
  if args.inventory == "armor" and args.direction == "unequip" then
    local bonus = src.prototype.get_inventory_size_bonus(src.quality)
    local remaining = #main - bonus
    check(main_index <= remaining, "inventory_full", "Choose a main slot retained after armor removal")
    for i = math.max(1, remaining + 1), #main do
      check(not main[i].valid_for_read, "inventory_full", "Empty bonus inventory slots before removing armor")
    end
  end
  local count = src.count
  -- Native transfer preserves quality, partial magazines, durability and grids.
  check(dst.transfer_stack(src), "transfer_rejected", "Native equipment transfer rejected")
  return {count = count}
end

function methods.inspect_combat(args)
  local c = character()
  local radius = integer(args.radius, 'radius', 1, 64)
  local found = c.surface.find_entities_filtered{position=c.position,radius=radius,force='enemy',limit=33}
  local enemies = {}
  for i=1,math.min(#found,32) do
    local e = found[i]
    if combat_target(c,e) and e.unit_number then
      enemies[#enemies+1] = {unit_number=e.unit_number,name=e.name,x_milli=math.floor(e.position.x*1000+0.5),
        y_milli=math.floor(e.position.y*1000+0.5),health_milli=math.floor(e.health*1000+0.5),can_shoot=c.can_shoot(e,e.position)}
    end
  end
  return {health=c.health,selected_gun_slot=c.selected_gun_index or 0,enemies=enemies,truncated=#found>32}
end
function methods.attack(args)
  local c = character(); idle()
  local id = integer(args.unit_number, 'unit_number', 1, 9007199254740991)
  local slot = integer(args.gun_slot, 'gun_slot', 1, 3)
  local ticks = integer(args.ticks, 'ticks', 1, 300)
  -- Unit prototypes need not carry the get-by-unit-number flag. Resolve only
  -- within a bounded local enemy survey, never through an unbounded world scan.
  local e
  for _, candidate in ipairs(c.surface.find_entities_filtered{position=c.position,radius=64,force='enemy',limit=129}) do
    if candidate.unit_number == id then e = candidate; break end
  end
  check(combat_target(c,e) and e.surface == c.surface, 'invalid_target', 'Expected a live hostile enemy unit, turret or spawner on this surface')
  local guns = c.get_inventory(defines.inventory.character_guns)
  local gun = guns and guns[slot]
  check(gun and gun.valid_for_read, 'no_weapon', 'Equip a gun in the chosen slot first')
  local rounds = ammo_rounds(c,slot)
  check(rounds>0, 'no_ammo', 'Equip real ammunition in the corresponding slot first')
  local old_slot = c.selected_gun_index
  c.selected_gun_index = slot
  local permitted = c.can_shoot(e,e.position)
  c.selected_gun_index = old_slot
  check(permitted,'cannot_shoot','Native weapon/ammo compatibility and range check rejected the target')
  local a = start('attack',{timeout_ticks=ticks+1})
  a.target,a.gun_slot,a.end_tick,a.initial_rounds = e,slot,game.tick+ticks,rounds
  a.count,a.initial_health_milli,a.final_health_milli,a.target_gone = 0,math.floor(e.health*1000+0.5),math.floor(e.health*1000+0.5),false
  c.selected_gun_index = slot
  return public_action(a)
end

function methods.inspect(args)
  local c = character()
  local radius = number(args.radius or 16, "radius", 0, 64)
  check(args.name == nil or type(args.name) == "string", "invalid_argument", "name must be a string")
  check(args.name == nil or prototypes.entity[args.name], "invalid_argument", "Unknown entity name")
  local entities = c.surface.find_entities_filtered{position = c.position, radius = radius, name = args.name, limit = 201}
  local out = {position = c.position, surface = c.surface.name, health = c.health,
    inventory = contents(c.get_main_inventory()), entities = {}, truncated = #entities > 200,
    active_action = state().active and public_action(state().active)}
  for i = 1, math.min(#entities, 200) do
    out.entities[#out.entities + 1] = entity_summary(entities[i])
  end
  return out
end

function methods.inspect_entity(args)
  local c = character()
  check(type(args.name) == "string" and prototypes.entity[args.name],
    "invalid_argument", "A valid entity name is required")
  local pos = position(args.position)
  -- Bounded named-point lookup on this surface, across all qualities. Keep the
  -- existing reach-independent behavior and narrow corpse fallback.
  local e = find_target(c, args.name, pos, true)
  check(e and e.valid, "not_found", "No matching entity at position")
  return entity_summary(e)
end

function methods.inspect_simulation(_args)
  return {speed = game.speed, tick_paused = game.tick_paused,
    connected_players = #game.connected_players, version = script.active_mods.base}
end

local function craftable_count(c, r)
  if not r.enabled or not r.has_category("crafting") or #r.ingredients == 0 then return 0 end
  local available = 2147483647
  for _, i in pairs(r.ingredients) do
    if i.type ~= "item" or i.amount <= 0 or i.amount ~= math.floor(i.amount) then return 0 end
    available = math.min(available, math.floor(c.get_item_count{name = i.name, quality = "normal"} / i.amount))
  end
  return available
end

function methods.inspect_recipe(args)
  local c = character()
  check(type(args.name) == "string", "invalid_argument", "Recipe name is required")
  local r = c.force.recipes[args.name]
  check(r, "not_found", "Unknown recipe")
  return {name = r.name, enabled = r.enabled, categories = r.categories, energy = r.energy,
    ingredients = r.ingredients, products = r.products, craftable = craftable_count(c, r)}
end

local function craft_request(args)
  idle()
  local c = character()
  check(type(args.recipe) == "string", "invalid_argument", "Recipe name is required")
  local r = c.force.recipes[args.recipe]
  check(r and r.enabled and r.has_category("crafting"), "invalid_recipe", "Recipe is unknown, locked or not hand-craftable")
  local n = integer(args.count or 1, "count", 1, 100)
  local products = r.products
  check(#products == 1 and products[1].type == "item" and products[1].amount
    and products[1].amount == math.floor(products[1].amount)
    and (not products[1].probability or products[1].probability == 1)
    and supported_product(products[1].name),
    "unsupported_recipe", "Crafting requires a single guaranteed supported item product")
  check(craftable_count(c, r) >= n, "not_craftable", "Missing ingredients; craft intermediate items explicitly first")
  local product = products[1]
  check(c.get_main_inventory().get_insertable_count{name = product.name, quality = "normal"} >= n * product.amount,
    "inventory_full", "Not enough room for crafted items")
  return c, r, n, product
end

function methods.craft(args)
  local c, r, n, product = craft_request(args)
  local a = start("craft", args)
  a.item, a.per_craft, a.requested = product.name, product.amount, n
  a.ingredients, a.completed, a.count = r.ingredients, 0, 0
  a.duration = math.max(1, math.ceil(r.energy * 60))
  a.next_tick = game.tick + a.duration
  return public_action(a)
end

-- Use the real engine crafting queue when normal crafting events/research
-- triggers matter. Never recursively craft missing intermediates.
function methods.hand_craft(args)
  local c, r, n, product = craft_request(args)
  integer(args.timeout_ticks or 1800, "timeout_ticks", 1, 3600)
  check(#(c.crafting_queue or {}) == 0, "busy", "Character crafting queue is not empty")
  local initial = c.get_item_count{name = product.name, quality = "normal"}
  local stats = c.force.get_item_production_statistics(c.surface)
  local production_before = stats.get_input_count{name = product.name, quality = "normal"}
  local consumption_before = {}
  for _, ingredient in ipairs(r.ingredients) do
    consumption_before[ingredient.name] = stats.get_output_count{name = ingredient.name, quality = "normal"}
  end
  local accepted = c.begin_crafting{recipe = r.name, count = n, silent = true}
  check(accepted > 0, "craft_rejected", "Engine did not accept any crafting batches")
  local a = start("hand-craft", args)
  a.item, a.initial, a.requested, a.count = product.name, initial, n * product.amount, 0
  a.recipe, a.batches, a.per_craft = r.name, accepted, product.amount
  a.production_before, a.consumption_before, a.ingredients = production_before, consumption_before, r.ingredients
  return public_action(a)
end

function methods.mine_object(args)
  idle()
  local c, p = character(), position(args.position)
  check(type(args.name) == "string", "invalid_argument", "Entity name is required")
  check(distance(c.position, p) <= c.resource_reach_distance, "out_of_reach", "Mining target is out of reach")
  local e = c.surface.find_entity(args.name, p)
  check(e and mineable_object(c, e),
    "invalid_target", "Expected a minable neutral tree/rock or friendly item-placeable infrastructure")
  check(c.can_reach_entity(e), "out_of_reach", "Mining target is out of reach")
  local a = start("mine-object", args)
  -- Resolve the half-tile request once, then mine the actual entity. Natural
  -- trees are off-grid: the lookup point need not select the same entity.
  a.position, a.target, a.count = {x = e.position.x, y = e.position.y}, e, 0
  return public_action(a)
end

function methods.walk_to(args)
  character()
  local pos = position(args.position)
  local a = start("walk_to", args)
  a.position = pos
  return public_action(a)
end

function methods.mine(args)
  local c = character()
  idle()
  local pos = position(args.position)
  local count = integer(args.count or 1, "count", 1, 1000)
  local item = args.item
  check(type(item) == "string" and prototypes.item[item], "invalid_argument", "A valid output item is required")
  check(distance(pos, c.position) <= c.resource_reach_distance, "out_of_reach", "Mining target is out of reach")
  -- Limit this first implementation to resource tiles; entity removal has a
  -- different completion condition and should be a separate action.
  local targets = c.surface.find_entities_filtered{type = "resource", position = pos, radius = 0.2}
  local target = targets[1]
  check(target and target.name == item, "invalid_target", "Expected a resource matching item at position")
  local a = start("mine", args)
  a.position, a.item, a.requested = pos, item, count
  a.initial, a.count, a.target = c.get_item_count{name = item, quality = "normal"}, 0, target
  return public_action(a)
end

function methods.stop(_args)
  finish("cancelled")
  halt()
  return {stopped = true}
end

function methods.action(args)
  local id = integer(args.id, "id", 1, 2147483647)
  local a = state().actions[id]
  check(a, "unknown_action", "Action is unknown or older than the last 64 actions")
  return public_action(a)
end

function methods.build(args)
  idle()
  local c = character()
  local item = args.item
  check(type(item) == "string", "invalid_argument", "Item name is required")
  local proto = prototypes.item[item]
  check(proto and proto.place_result, "unsupported_item", "Item has no placeable entity")
  -- Count-backed placement cannot restore vehicle inventories/equipment or tags.
  -- Such items can be transferred intact, but need a dedicated placement effect.
  check(proto.type == "item", "unsupported_item", "Placement requires a plain entity-building item")
  local pos = position(args.position)
  local direction = args.direction or "north"
  check(direction == "north" or direction == "east" or direction == "south" or direction == "west",
    "invalid_argument", "Build direction must be north, east, south, or west")
  local dir = directions[direction]
  check(distance(pos, c.position) <= c.build_distance, "out_of_reach", "Build position is out of reach")
  if args.end_type ~= nil then
    check(proto.place_result.type == "underground-belt" and (args.end_type == "input" or args.end_type == "output"),
      "invalid_argument", "Underground end must be input or output")
  end
  local stack = {name = item, quality = "normal", count = 1}
  check(c.get_item_count(stack) >= 1, "no_item", "Required item is missing")
  undamaged(c.get_main_inventory(), item)
  -- Direction-sensitive rectangular footprints (splitters, boilers, generators)
  -- must be checked on both axes before create_entity can snap the position.
  local width, height = proto.place_result.tile_width, proto.place_result.tile_height
  height = height or width
  if direction == "east" or direction == "west" then width, height = height, width end
  local ox, oy = (width % 2) / 2, (height % 2) / 2
  check(pos.x == math.floor(pos.x) + ox and pos.y == math.floor(pos.y) + oy,
    "invalid_argument", "Build position is not aligned to the entity tile grid")
  local spec = {name = proto.place_result.name, position = pos, force = c.force,
    direction = dir, quality = "normal", build_check_type = defines.build_check_type.manual}
  check(c.can_place_entity{name = spec.name, position = pos, direction = dir}
    and c.surface.can_place_entity(spec), "blocked", "Placement is blocked")
  if proto.place_result.type == "underground-belt" then spec.type = args.end_type or "input" end
  -- Creating before consumption avoids losing the item on failed placement.
  -- No other action interleaves within this call. Roll back if removal fails.
  local e = c.surface.create_entity(spec)
  check(e, "blocked", "Placement failed")
  if c.remove_item(stack) ~= 1 then
    e.destroy()
    fail("no_item", "Could not consume building item")
  end
  return entity_summary(e)
end

function methods.build_underground(args)
  check(args.end_type == "input" or args.end_type == "output", "invalid_argument", "Underground end must be input or output")
  return methods.build{item = "underground-belt", position = args.position,
    direction = args.direction, end_type = args.end_type}
end

function methods.rotate(args)
  idle()
  local c = character()
  check(type(args.name) == "string", "invalid_argument", "Entity name is required")
  local pos = position(args.position)
  local e = c.surface.find_entity(args.name, pos)
  check(e and e.valid and e.force == c.force, "invalid_target", "Expected a friendly entity")
  check(placed_infrastructure(e) and e.supports_direction and e.rotatable,
    "unsupported_item", "Expected item-placeable infrastructure that supports native rotation")
  check(c.can_reach_entity(e), "out_of_reach", "Entity is out of reach")
  local name = args.direction
  check(name == "north" or name == "east" or name == "south" or name == "west",
    "invalid_argument", "Direction must be cardinal")
  local desired, original = directions[name], e.direction
  if original == desired then return entity_summary(e) end
  -- Native rotation enforces collisions, entity-specific rules and linked ends.
  -- A multi-step absolute rotation can stop partway: report the actual heading,
  -- never overwrite direction or automatically roll back/retry engine changes.
  local reverse = (desired - original) % 16 > 8
  local seen = {[original] = true}
  for step = 1, 16 do
    local rotated = e.rotate{reverse = reverse}
    if rotated and e.direction == desired then return entity_summary(e) end
    if not rotated or seen[e.direction] then
      fail("rotation_incomplete", "Native rotation stopped; original=" .. original ..
        ", current=" .. e.direction .. ", requested=" .. desired ..
        ", attempts=" .. step .. "; inspect before continuing")
    end
    seen[e.direction] = true
  end
  fail("rotation_incomplete", "Native rotation exceeded 16 steps; current=" ..
    e.direction .. ", requested=" .. desired .. "; inspect before continuing")
end

local function inventory(e, name)
  if name == "modules" then return e.get_module_inventory() end
  if name == "fuel" then return e.get_fuel_inventory() end
  if name == "output" then return e.get_output_inventory() end
  if name == "input" and (e.type == "furnace" or e.type == "assembling-machine") then return e.get_inventory(defines.inventory.crafter_input) end
  if name == "input" and e.type == "lab" then return e.get_inventory(defines.inventory.lab_input) end
  if name == "ammo" and e.type == "ammo-turret" then return e.get_inventory(defines.inventory.turret_ammo) end
  if name == "main" and npc_corpse(e) then return e.get_inventory(defines.inventory.character_corpse) end
  if name == "main" and (e.type == "container" or e.type == "logistic-container" or e.type == "character") then
    return e.type == "character" and e.get_main_inventory() or e.get_inventory(defines.inventory.chest)
  end
  fail("invalid_inventory", "Invalid inventory for entity type")
end

local function transfer(args, quality)
  idle()
  check(type(quality) == "string" and #quality >= 1 and #quality <= 100 and prototypes.quality[quality],
    "invalid_quality", "A registered quality name is required")
  local c = character()
  local pos = position(args.position)
  check(args.direction == "take" or args.direction == "give", "invalid_argument", "direction must be take or give")
  check(type(args.entity) == "string", "invalid_argument", "entity name is required")
  local e = find_target(c, args.entity, pos)
  check(e and e ~= c and (e.force == c.force or (npc_corpse(e) and args.direction == "take")),
    "invalid_target", "Expected a friendly entity or an unowned NPC corpse for recovery")
  check(c.can_reach_entity(e), "out_of_reach", "Inventory is out of reach")
  local other = inventory(e, args.inventory or "main")
  check(other, "invalid_inventory", "Inventory is unavailable")
  local source, dest = c.get_main_inventory(), other
  if args.direction == "take" then source, dest = other, source end
  local item = args.item
  check(type(item) == "string" and supported_product(item), "invalid_argument", "A valid item prototype is required")
  if args.inventory == "modules" then
    check(prototypes.item[item].type == "module", "invalid_argument", "Only module items may use module slots")
  end
  local count = integer(args.count, "count", 1, 1000)
  check(source.get_item_count{name = item, quality = quality} >= count,
    "no_item", "Not enough " .. quality .. "-quality items in source")
  -- Native slot transfers preserve blueprints, equipment, tags, spoilage,
  -- damage and partially consumed ammo/tools. Never reconstruct name/count stacks.
  -- Respect the destination bar explicitly; slot writes respect native filters.
  local limit = #dest
  if dest.supports_bar() then limit = math.min(limit, dest.get_bar() - 1) end
  check(#source <= 1024 and #source * limit <= 65536,
    "unsupported_inventory", "Inventory transfer exceeds the bounded slot budget")
  local moved = 0
  for i = 1, #source do
    local s = source[i]
    if s.valid_for_read and s.name == item and s.quality.name == quality and
        (args.inventory ~= "modules" or args.direction ~= "give" or dest.can_insert(s)) then
      -- Module compatibility depends on the owning machine and its recipe.
      -- Ask the native inventory before using individual stack transfers.
      for j = 1, limit do
        local before = s.count
        dest[j].transfer_stack(s, math.min(count - moved, before))
        moved = moved + before - (s.valid_for_read and s.count or 0)
        if moved == count or not s.valid_for_read then break end
      end
    end
    if moved == count then break end
  end
  check(moved > 0, "inventory_full", "Destination cannot accept the requested item")
  -- Capacity depends on stack metadata, not just prototype counts. A successful
  -- receipt reports the actual quantity; callers must account for partial moves.
  return {item = item, quality = quality, count = moved, direction = args.direction}
end

function methods.transfer(args)
  check(args.quality == nil, "invalid_argument", "Use transfer_quality for explicit quality selection")
  local result = transfer(args, "normal")
  result.quality = nil -- Preserve the legacy wire receipt as well as its selection.
  return result
end

-- A distinct method makes old mods fail closed with unknown_method instead of
-- ignoring a quality argument and transferring normal stacks by mistake.
function methods.transfer_quality(args)
  return transfer(args, args.quality)
end

local function tick()
  local b = state()
  local a = b.active
  if not a then return end
  local c = b.character
  if not c or not c.valid then finish("failed", "character_lost", "Character died or was removed") return end
  if game.tick >= a.deadline_tick then finish("failed", "timeout", "Action reached its tick deadline") return end
  if a.kind == "walk_to" then
    if distance(c.position, a.position) <= 0.5 then finish("completed") return end
    local dx, dy = a.position.x - c.position.x, a.position.y - c.position.y
    local horizontal = math.abs(dx) > 0.2 and (dx > 0 and "east" or "west") or ""
    local vertical = math.abs(dy) > 0.2 and (dy > 0 and "south" or "north") or ""
    c.walking_state = {walking = true, direction = directions[vertical .. horizontal]}
  elseif a.kind == 'attack' then
    if not a.target.valid or game.tick >= a.end_tick then finish('completed'); return end
    if not combat_target(c,a.target) then finish('failed','invalid_target','Target is no longer a permitted enemy'); return end
    if ammo_rounds(c,a.gun_slot) == 0 then finish('completed'); return end
    c.selected_gun_index = a.gun_slot
    c.update_selected_entity(a.target.position)
    if c.selected ~= a.target then finish('failed','target_lost','Could not select the explicit hostile target'); return end
    c.shooting_state = {state=defines.shooting.shooting_selected,position=a.target.position}
  elseif a.kind == "craft" then
    if game.tick < a.next_tick then return end
    for _, i in pairs(a.ingredients) do
      if c.get_item_count{name = i.name, quality = "normal"} < i.amount then
        finish("failed", "not_craftable", "An ingredient was removed during crafting") return
      end
    end
    if c.get_main_inventory().get_insertable_count{name = a.item, quality = "normal"} < a.per_craft then
      finish("failed", "inventory_full", "Crafted items no longer fit") return
    end
    -- One atomic recipe execution per completion tick. Unfinished crafts have
    -- not consumed ingredients, so cancellation and deadlines need no refunds.
    for _, i in pairs(a.ingredients) do c.remove_item{name = i.name, quality = "normal", count = i.amount} end
    c.insert{name = a.item, quality = "normal", count = a.per_craft}
    a.completed = a.completed + 1
    a.count = a.completed * a.per_craft
    if a.completed == a.requested then finish("completed")
    else a.next_tick = game.tick + a.duration end
  elseif a.kind == "hand-craft" then
    a.count = math.max(0, c.get_item_count{name = a.item, quality = "normal"} - a.initial)
    if a.count >= a.requested then finish("completed")
    elseif #(c.crafting_queue or {}) == 0 then finish("failed", "craft_incomplete", "Engine crafting ended before requested output was observed") end
  elseif a.kind == "mine-object" then
    if not a.target.valid then a.count = 1; finish("completed") return end
    if not mineable_object(c, a.target) then
      finish("failed", "invalid_target", "Mining target is no longer minable or permitted") return
    end
    if distance(c.position, a.position) > c.resource_reach_distance or not c.can_reach_entity(a.target) then
      finish("failed", "out_of_reach", "Mining target moved out of reach") return
    end
    c.update_selected_entity(a.position)
    local selected_position = a.position
    if c.selected ~= a.target then
      -- Overlapping tree selection boxes can cover the centre. Try at most nine
      -- inset points in the resolved target's selection box; never mine another
      -- selected entity just because it overlaps the requested one.
      local box = a.target.selection_box
      if box then
        for _, fx in ipairs{0.5, 0.1, 0.9} do
          for _, fy in ipairs{0.5, 0.1, 0.9} do
            local point = {x = box.left_top.x + (box.right_bottom.x - box.left_top.x) * fx,
              y = box.left_top.y + (box.right_bottom.y - box.left_top.y) * fy}
            c.update_selected_entity(point)
            if c.selected == a.target then selected_position = point; break end
          end
          if c.selected == a.target then break end
        end
      end
    end
    if c.selected ~= a.target then finish("failed", "target_lost", "Could not select the resolved mining target") return end
    c.mining_state = {mining = true, position = selected_position}
  elseif a.kind == "mine" then
    a.count = math.max(0, c.get_item_count{name = a.item, quality = "normal"} - a.initial)
    if a.count >= a.requested then finish("completed") return end
    if not a.target.valid then finish("failed", "target_lost", "Resource depleted before requested count") return end
    if distance(c.position, a.position) > c.resource_reach_distance then
      finish("failed", "out_of_reach", "Mining target moved out of reach") return
    end
    -- mining_state.position alone does not select a resource for a standalone character.
    c.update_selected_entity(a.position)
    if c.selected ~= a.target then finish("failed", "target_lost", "Could not select mining target") return end
    c.mining_state = {mining = true, position = a.position}
  end
end

function methods.connect_power(args)
  idle()
  local c, from, to = character(), position(args.from), position(args.to)
  local a, b = c.surface.find_entity("small-electric-pole", from), c.surface.find_entity("small-electric-pole", to)
  check(a and b and a.valid and b.valid and a.force == c.force and b.force == c.force,
    "invalid_target", "Expected two friendly small electric poles")
  check(c.can_reach_entity(a) and c.can_reach_entity(b), "out_of_reach", "Both poles must be reachable")
  local aa = a.get_wire_connector(defines.wire_connector_id.pole_copper, true)
  local bb = b.get_wire_connector(defines.wire_connector_id.pole_copper, true)
  check(aa and bb, "invalid_target", "Pole copper connector unavailable")
  check(aa.is_connected_to(bb) or aa.connect_to(bb, true, defines.wire_origin.player),
    "out_of_reach", "Poles cannot be joined within normal wire reach")
  return {connected = true}
end

require("expansion").register(methods, {
  character = character, idle = idle, check = check, integer = integer,
  position = position, distance = distance, contents = contents, status_names = status_names
})

script.on_init(function() state() end)
script.on_event(defines.events.on_tick, function()
  local names = {}
  for name in pairs(registry()) do names[#names + 1] = name end
  table.sort(names)
  local previous = selected_bot
  for _, name in ipairs(names) do
    selected_bot = name
    local ok, err = pcall(tick)
    if not ok then
      finish("failed", "internal_error", type(err) == "table" and err.message or tostring(err))
    end
  end
  selected_bot = previous
end)
remote.add_interface("bot", {
  request = function(request)
    if type(request) ~= "table" or type(request.method) ~= "string" then
      return {ok = false, tick = game.tick, error = {code = "invalid_request", message = "Expected method and args"}}
    end
    local handler = methods[request.method]
    if not handler then
      return {ok = false, tick = game.tick, error = {code = "unknown_method", message = "Unknown bot method"}}
    end
    if request.args ~= nil and type(request.args) ~= "table" then
      return {ok = false, tick = game.tick, error = {code = "invalid_argument", message = "args must be an object"}}
    end
    local name = request.bot
    if name == nil then name = "default" end
    if type(name) ~= "string" or #name < 1 or #name > 32 or not name:match("^[a-z][a-z0-9_-]*$") then
      return {ok = false, tick = game.tick, error = {code = "invalid_bot", message = "Expected a bot name matching [a-z][a-z0-9_-]{0,31}"}}
    end
    local bots = registry()
    local created = false
    if not bots[name] then
      if request.method ~= "spawn" then
        return {ok = false, tick = game.tick, error = {code = "unknown_bot", message = "Spawn the selected bot explicitly first"}}
      end
      local count = 0
      for _ in pairs(bots) do count = count + 1 end
      if count >= MAX_BOTS then
        return {ok = false, tick = game.tick, error = {code = "bot_limit", message = "At most eight named bots are supported"}}
      end
      bots[name] = {sequence = 0, actions = {}}
      created = true
    end
    local previous = selected_bot
    selected_bot = name
    local ok, result = pcall(handler, request.args or {})
    selected_bot = previous
    if not ok and created then bots[name] = nil end
    if ok then return {ok = true, tick = game.tick, data = result} end
    local err = type(result) == "table" and result or {code = "internal_error", message = tostring(result)}
    return {ok = false, tick = game.tick, error = err}
  end
})
