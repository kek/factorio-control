-- Offline-testable bounded capabilities. API target: Factorio 2.1.24.
local M = {}

function M.register(methods, ctx)
  local check, integer, position = ctx.check, ctx.integer, ctx.position
  local function args(a)
    check(type(a) == 'table', 'invalid_argument', 'arguments are required')
    return a
  end
  local function name(s)
    check(type(s) == 'string' and #s > 0 and #s <= 200,
      'invalid_argument', 'name must be a nonempty string of at most 200 bytes')
    return s
  end
  local function point(p) return {x = p.x, y = p.y} end
  local function nearby(c, p)
    check(ctx.distance(c.position, p) <= 64, 'out_of_range', 'position is more than 64 tiles away')
  end
  local function generated(surface, p)
    return surface.is_chunk_generated{x = math.floor(p.x / 32), y = math.floor(p.y / 32)}
  end
  local function health(e)
    -- 2.1 replaced prototype.max_health with a quality-aware method.
    return e.prototype.get_max_health(e.quality) or 0
  end
  local function target(a)
    args(a)
    local c, p = ctx.character(), position(a.position)
    nearby(c, p)
    check(generated(c.surface, p), 'not_generated', 'position is not generated')
    local e = c.surface.find_entity(name(a.name), p)
    check(e and e.valid, 'not_found', 'entity not found at position')
    return c, e
  end
  local function bounded_contents(inv)
    local result = ctx.contents(inv)
    local n = 0
    for _ in pairs(result) do n = n + 1 end
    check(n <= 256, 'unsupported_inventory', 'inventory has too many distinct stacks')
    return result
  end
  local function inventory(e, kind) return e.get_inventory(defines.inventory[kind]) end
  local function crafter(e) return e.type == 'assembling-machine' or e.type == 'furnace' or e.type == 'rocket-silo' end

  methods.inspect_area = function(a)
    args(a)
    local c, p = ctx.character(), position(a.position)
    local r = integer(a.radius, 'radius', 1, 8)
    nearby(c, p)
    local tiles, entities = {}, {}
    local x0, y0 = math.floor(p.x), math.floor(p.y)
    for y = y0 - r, y0 + r do
      for x = x0 - r, x0 + r do
        if generated(c.surface, {x = x, y = y}) then
          local tile = c.surface.get_tile(x, y)
          tiles[#tiles + 1] = {name = tile.name, position = point(tile.position),
            water = tile.collides_with('water_tile')}
        end
      end
    end
    local found = c.surface.find_entities_filtered{
      area = {{x0 - r, y0 - r}, {x0 + r + 1, y0 + r + 1}},
      type = 'resource', invert = true, limit = 101}
    for i = 1, math.min(#found, 100) do
      local e = found[i]
      entities[#entities + 1] = {name = e.name, type = e.type, position = point(e.position),
        force = e.force.name, health = e.health or 0, max_health = health(e)}
    end
    return {tiles = tiles, entities = entities, truncated = #found > 100}
  end

  methods.inspect_transport = function(a)
    args(a)
    local allowed = {['transport-belt'] = true, ['underground-belt'] = true, splitter = true}
    check(allowed[name(a.name)], 'unsupported_transport', 'expected a base belt, underground-belt or splitter')
    local _, e = target(a)
    check(allowed[e.name] and e.type == e.name and e.quality.name == 'normal',
      'unsupported_transport', 'expected normal-quality base transport')
    -- 2.1.24: query the actual maximum, including underground/ splitters' extra lines.
    -- Never assume that every entity has only the two visible belt lanes.
    local count = integer(e.get_max_transport_line_index(), 'transport line count', 1, 8)
    local lanes = {}
    for i = 1, count do
      local line = e.get_transport_line(i)
      check(line and line.valid, 'unsupported_transport', 'transport line is invalid')
      lanes[#lanes + 1] = {index = i, items = bounded_contents(line)}
    end
    return {name = e.name, position = point(e.position), direction = e.direction, lanes = lanes}
  end

  methods.inspect_water = function(a)
    args(a)
    local c = ctx.character()
    local radius = integer(a.radius, 'radius', 1, 64)
    local found = c.surface.find_tiles_filtered{position = c.position, radius = radius,
      collision_mask = 'water_tile', limit = 201}
    local tiles = {}
    for i = 1, math.min(#found, 200) do
      local tile = found[i]
      if generated(c.surface, tile.position) then
        tiles[#tiles + 1] = {name = tile.name, position = point(tile.position)}
      end
    end
    return {tiles = tiles, truncated = #found > 200}
  end

  local function technology(a)
    args(a)
    local force = ctx.character().force
    local t = force.technologies[name(a.name)]
    check(t ~= nil, 'invalid_technology', 'unknown technology')
    return force, t
  end
  local function prerequisites(t)
    local result = {}
    for _, p in pairs(t.prerequisites) do
      check(#result < 128, 'unsupported_technology', 'too many prerequisites')
      result[#result + 1] = {name = p.name, researched = p.researched}
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
  end
  local function filter_name(v)
    if type(v) == 'string' then return v end
    if type(v) == 'table' then return v.name or '' end
    return ''
  end
  methods.inspect_technology = function(a)
    local force, t = technology(a)
    local trigger = t.prototype.research_trigger
    local ingredients = {}
    for _, item in ipairs(t.research_unit_ingredients or {}) do
      check(#ingredients < 128, 'unsupported_technology', 'too many research ingredients')
      ingredients[#ingredients + 1] = {name = item.name, amount = item.amount}
    end
    local current = force.current_research ~= nil and force.current_research.name == t.name
    return {name = t.name, enabled = t.enabled, researched = t.researched,
      prerequisites = prerequisites(t), count = t.research_unit_count or 0,
      energy = t.research_unit_energy or 0, ingredients = ingredients,
      trigger_type = trigger and trigger.type or '',
      trigger_item = trigger and filter_name(trigger.item) or '',
      trigger_entity = trigger and filter_name(trigger.entity or (trigger.entities or {})[1]) or '',
      trigger_count = trigger and (trigger.count or trigger.amount or 1) or 0,
      current = current, progress = current and force.research_progress or 0}
  end
  methods.research = function(a)
    ctx.idle()
    local force, t = technology(a)
    check(t.enabled and not t.researched, 'invalid_technology', 'technology is disabled or already researched')
    check(not t.prototype.research_trigger, 'trigger_research', 'trigger technologies must be earned normally')
    for _, p in ipairs(prerequisites(t)) do
      check(p.researched, 'missing_prerequisite', 'research prerequisites are incomplete')
    end
    check(not force.current_research or force.current_research.name == t.name,
      'research_busy', 'a different technology is already being researched')
    if not force.current_research then
      check(force.add_research(t.name), 'research_failed', 'could not start research')
    end
    return {name = t.name}
  end

  methods.set_recipe = function(a)
    ctx.idle()
    local c, e = target(a)
    check(e.name == 'assembling-machine-1' and e.type == 'assembling-machine',
      'unsupported_machine', 'only assembling-machine-1 is supported')
    check(e.force == c.force, 'wrong_force', 'machine belongs to another force')
    check(c.can_reach_entity(e), 'out_of_reach', 'machine is not reachable')
    local recipe = c.force.recipes[name(a.recipe)]
    check(recipe and recipe.enabled, 'invalid_recipe', 'recipe is unknown or locked')
    -- 2.1.24 has no can_set_recipe: validate categories, locks and item-only
    -- recipes explicitly before set_recipe (which can otherwise eject items).
    local supported = false
    for category in pairs(e.prototype.crafting_categories or {}) do
      if recipe.has_category(category) then supported = true end
    end
    check(supported, 'unsupported_recipe', 'machine does not support recipe category')
    for _, list in ipairs{recipe.ingredients, recipe.products} do
      check(#list <= 64, 'unsupported_recipe', 'recipe is too large')
      for _, item in ipairs(list) do
        check(item.type == 'item', 'unsupported_recipe', 'only item recipes are supported')
      end
    end
    local previous = e.get_recipe()
    if previous and previous.name == recipe.name then return {recipe = recipe.name} end
    check(not e.recipe_locked and not e.prototype.fixed_recipe, 'recipe_locked', 'machine recipe is locked')
    check(not e.is_crafting() and (e.crafting_progress or 0) == 0 and (e.bonus_progress or 0) == 0,
      'machine_not_empty', 'machine has an in-progress craft')
    for _, kind in ipairs{'crafter_input', 'crafter_output', 'crafter_trash', 'assembling_machine_dump'} do
      local inv = inventory(e, kind)
      check(not inv or inv.is_empty(), 'machine_not_empty', 'empty machine inventories before changing recipe')
    end
    local modules = e.get_module_inventory()
    check(not modules or modules.is_empty(), 'machine_not_empty', 'empty machine modules before changing recipe')
    -- Vanilla assembler-1 has no fluids. Refuse modded fluid-capable variants
    -- rather than risking a recipe change discarding hidden fluid contents.
    check(not next(e.prototype.fluidbox_prototypes or {}),
      'unsupported_machine', 'fluid-capable assemblers are not supported')
    local removed = e.set_recipe(recipe.name)
    check(not next(removed), 'unexpected_recipe_items', 'recipe change unexpectedly ejected items; do not retry')
    local confirmed = e.get_recipe()
    check(confirmed and confirmed.name == recipe.name, 'recipe_failed', 'machine did not accept recipe')
    return {recipe = recipe.name}
  end

  methods.set_chest_limit = function(a)
    ctx.idle()
    local c, e = target(a)
    check(e.force == c.force and e.type == 'container', 'wrong_force', 'expected a friendly chest')
    check(c.can_reach_entity(e), 'out_of_reach', 'chest is not reachable')
    local inv = inventory(e, 'chest')
    check(inv and inv.supports_bar(), 'unsupported_inventory', 'chest has no inventory bar')
    local slots = integer(a.slots, 'slots', 1, math.min(48, #inv))
    inv.set_bar(slots + 1)
    check(inv.get_bar() == slots + 1, 'configuration_failed', 'chest limit was not applied')
    return {slots = slots}
  end

  methods.inspect_machine = function(a)
    local c, e = target(a)
    local out = {name = e.name, type = e.type, position = point(e.position),
      status_name = ctx.status_names[e.status] or 'unknown', health = e.health or 0,
      max_health = health(e), energy = e.energy or 0, recipe = '',
      network_id = e.electric_network_id or 0, fuel = {}, input = {}, output = {},
      ammo = {}, inventory = {}, fluids = {}}
    if e.force ~= c.force then return out end
    out.fuel = bounded_contents(e.get_fuel_inventory())
    out.output = bounded_contents(e.get_output_inventory())
    if crafter(e) then
      out.input = bounded_contents(inventory(e, 'crafter_input'))
      local recipe = e.get_recipe()
      out.recipe = recipe and recipe.name or ''
    elseif e.type == 'lab' then
      out.input = bounded_contents(inventory(e, 'lab_input'))
    end
    if e.type == 'ammo-turret' then out.ammo = bounded_contents(inventory(e, 'turret_ammo')) end
    if e.type == 'container' or e.type == 'logistic-container' then
      out.inventory = bounded_contents(inventory(e, 'chest'))
    end
    -- 2.1 removed LuaFluidBox; only query fluid storage on fluid prototypes.
    if next(e.prototype.fluidbox_prototypes or {}) then
      local n = e.fluids_count or 0
      check(n <= 64, 'unsupported_machine', 'too many fluid storages')
      for i = 1, n do
        local fluid = e.get_fluid(i)
        if fluid then out.fluids[#out.fluids + 1] = {
          name = fluid.name, amount = fluid.amount, temperature = fluid.temperature or 0} end
      end
    end
    return out
  end
end

return M
