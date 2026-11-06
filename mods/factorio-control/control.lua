-- API target: Factorio 2.1.24. No network, file input, or per-tick world scans.
local methods = {}
local directions = {
  north = defines.direction.north, northeast = defines.direction.northeast,
  east = defines.direction.east, southeast = defines.direction.southeast,
  south = defines.direction.south, southwest = defines.direction.southwest,
  west = defines.direction.west, northwest = defines.direction.northwest
}
local buildable = {
  ["burner-mining-drill"] = true, ["stone-furnace"] = true,
  ["wooden-chest"] = true, ["transport-belt"] = true, ["burner-inserter"] = true
}

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
local function state()
  storage.bot = storage.bot or {sequence = 0, actions = {}}
  return storage.bot
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
local function halt()
  local c = state().character
  if c and c.valid then
    c.walking_state = {walking = false}
    c.mining_state = {mining = false}
    c.clear_selected_entity()
  end
end
local function public_action(a)
  return {id = a.id, kind = a.kind, status = a.status, started_tick = a.started_tick,
    finished_tick = a.finished_tick, deadline_tick = a.deadline_tick, error = a.error,
    position = a.position, count = a.count}
end
local function finish(status, code, message)
  local b = state()
  local a = b.active
  if not a then return end
  halt()
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
local function entity_summary(e)
  local out = {name = e.name, type = e.type, position = e.position, unit_number = e.unit_number}
  if e.type == "resource" then out.amount = e.amount end
  if e.force.name == character().force.name and e.type ~= "character" then
    out.status = e.status
    out.fuel = contents(e.get_fuel_inventory())
    out.output = contents(e.get_output_inventory())
    if e.type == "furnace" then
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

function methods.inspect(args)
  local c = character()
  local radius = number(args.radius or 16, "radius", 0, 64)
  check(args.name == nil or type(args.name) == "string", "invalid_argument", "name must be a string")
  local entities = c.surface.find_entities_filtered{position = c.position, radius = radius, name = args.name, limit = 201}
  local out = {position = c.position, surface = c.surface.name, health = c.health,
    inventory = contents(c.get_main_inventory()), entities = {}, truncated = #entities > 200,
    active_action = state().active and public_action(state().active)}
  for i = 1, math.min(#entities, 200) do
    out.entities[#out.entities + 1] = entity_summary(entities[i])
  end
  return out
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
  check(type(item) == "string" and buildable[item], "unsupported_item", "Supported: starter drill, furnace, chest, belt, burner inserter")
  local proto = prototypes.item[item]
  check(proto and proto.place_result, "unsupported_item", "Item has no placeable entity")
  local pos = position(args.position)
  local direction = args.direction or "north"
  check(direction == "north" or direction == "east" or direction == "south" or direction == "west",
    "invalid_argument", "Build direction must be north, east, south, or west")
  local dir = directions[direction]
  check(distance(pos, c.position) <= c.build_distance, "out_of_reach", "Build position is out of reach")
  local stack = {name = item, quality = "normal", count = 1}
  check(c.get_item_count(stack) >= 1, "no_item", "Required item is missing")
  -- All supported buildings have square footprints. Odd tile widths use half
  -- coordinates; even widths use integers. Do not let create_entity silently
  -- snap to a different tile after placement/reach checks.
  local offset = (proto.place_result.tile_width % 2) / 2
  check(pos.x == math.floor(pos.x) + offset and pos.y == math.floor(pos.y) + offset,
    "invalid_argument", "Build position is not aligned to the entity tile grid")
  local spec = {name = proto.place_result.name, position = pos, force = c.force,
    direction = dir, quality = "normal", build_check_type = defines.build_check_type.manual}
  check(c.can_place_entity{name = spec.name, position = pos, direction = dir}
    and c.surface.can_place_entity(spec), "blocked", "Placement is blocked")
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

local function inventory(e, name)
  if name == "fuel" then return e.get_fuel_inventory() end
  if name == "output" then return e.get_output_inventory() end
  if name == "input" and e.type == "furnace" then return e.get_inventory(defines.inventory.crafter_input) end
  if name == "main" and (e.type == "container" or e.type == "character") then
    return e.type == "character" and e.get_main_inventory() or e.get_inventory(defines.inventory.chest)
  end
  fail("invalid_inventory", "Invalid inventory for entity type")
end

function methods.transfer(args)
  idle()
  local c = character()
  local pos = position(args.position)
  check(args.direction == "take" or args.direction == "give", "invalid_argument", "direction must be take or give")
  check(type(args.entity) == "string", "invalid_argument", "entity name is required")
  local e = c.surface.find_entity(args.entity, pos)
  check(e and e ~= c and e.force == c.force, "invalid_target", "Expected a friendly entity")
  check(c.can_reach_entity(e), "out_of_reach", "Inventory is out of reach")
  local other = inventory(e, args.inventory or "main")
  check(other, "invalid_inventory", "Inventory is unavailable")
  local source, dest = c.get_main_inventory(), other
  if args.direction == "take" then source, dest = other, source end
  local item = args.item
  check(type(item) == "string" and prototypes.item[item] and prototypes.item[item].type == "item", "invalid_argument", "Only ordinary items without stack metadata are supported")
  local count = integer(args.count, "count", 1, 1000)
  local stack = {name = item, quality = "normal", count = count}
  check(source.get_item_count(stack) >= count, "no_item", "Not enough items in source")
  check(dest.get_insertable_count{name = item, quality = "normal"} >= count, "inventory_full", "Destination cannot fit requested items")
  -- Starter items have no metadata. Normal-quality stacks only.
  local inserted = dest.insert(stack)
  if inserted ~= count then
    dest.remove{name = item, quality = "normal", count = inserted}
    fail("inventory_full", "Transfer could not be completed")
  end
  source.remove(stack)
  return {item = item, count = count, direction = args.direction}
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

script.on_init(function() state() end)
script.on_event(defines.events.on_tick, function()
  local ok, err = pcall(tick)
  if not ok then
    finish("failed", "internal_error", type(err) == "table" and err.message or tostring(err))
  end
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
    local ok, result = pcall(handler, request.args or {})
    if ok then return {ok = true, tick = game.tick, data = result} end
    local err = type(result) == "table" and result or {code = "internal_error", message = tostring(result)}
    return {ok = false, tick = game.tick, error = err}
  end
})
