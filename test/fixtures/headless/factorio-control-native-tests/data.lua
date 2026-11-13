-- Private fixture prototypes: exercise genuine native transport under modded
-- names. These are copied into the offline test mod directory, never the normal
-- server's mod directory. No items, recipes or gameplay control scripts are added.
for _, spec in ipairs{
  {'transport-belt', 'express-transport-belt', 'native-test-belt'},
  {'underground-belt', 'express-underground-belt', 'native-test-underground'},
  {'splitter', 'express-splitter', 'native-test-splitter'}
} do
  local original = assert(data.raw[spec[1]][spec[2]])
  local clone = table.deepcopy(original)
  clone.name = spec[3]
  clone.localised_name = {'entity-name.' .. spec[2]}
  data:extend{clone}
end
