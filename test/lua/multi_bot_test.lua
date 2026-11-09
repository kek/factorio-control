-- Isolated named-character tests; no server or gameplay fixtures.
package.path = 'mods/factorio-control/?.lua;' .. package.path
package.loaded.expansion = {register = function() end}
defines = {direction = {north=0,northeast=2,east=4,southeast=6,south=8,southwest=10,west=12,northwest=14},
  entity_status = {}, events = {on_tick=1}}
local tick, request, init
script = {active_mods={base='2.1.24'}, on_init=function(fn) init=fn end,
  on_event=function(_,fn) tick=fn end}
remote = {add_interface=function(_,i) request=i.request end}
storage, prototypes = {}, {item={},entity={}}
local surface, force, created = {name='nauvis',valid=true}, {}, 0
local function character(x,y)
  local items = {}
  return {valid=true,position={x=x,y=y},surface=surface,force=force,health=250,
    clear_selected_entity=function() end,
    get_main_inventory=function() return {get_contents=function() return items end} end}
end
surface.find_non_colliding_position=function(_,p) return p end
surface.create_entity=function(spec) created=created+1; return character(spec.position.x,spec.position.y) end
surface.find_entities_filtered=function() return {} end
game = {tick=100,surfaces={nauvis=surface},forces={player=force},speed=1,connected_players={}}
local legacy = {sequence=7,actions={},character=character(1,2)}
storage.bot=legacy
dofile('mods/factorio-control/control.lua')
init()
assert(storage.bots.default==legacy and storage.bot==legacy)
local function call(bot,method,args) return request{bot=bot,method=method,args=args or {}} end
local function ok(bot,method,args)
  local r=call(bot,method,args); assert(r.ok, r.error and r.error.message); return r.data
end
local function denied(code,bot,method,args)
  local r=call(bot,method,args); assert(not r.ok and r.error.code==code, code)
end
-- Old requests and explicit default name address the same existing actor.
assert(ok(nil,'spawn').existing and ok('default','spawn').existing and created==0)
assert(ok(nil,'inspect').position.x==1)
-- Unknown inspection never spawns; invalid names never allocate registry entries.
denied('unknown_bot','missing','inspect')
for _,n in ipairs({'','Bad','a.b','a/b',string.rep('a',33)}) do denied('invalid_bot',n,'spawn') end
denied('invalid_bot',false,'spawn')
denied('invalid_argument','failed','spawn',{position={x=0/0,y=0}})
assert(storage.bots.failed==nil)
assert(not ok('mining','spawn',{position={x=10,y=20}}).existing)
assert(not ok('lights','spawn',{position={x=30,y=40}}).existing)
assert(created==2 and next(ok('mining','inspect').inventory)==nil)
assert(ok('mining','spawn').existing and created==2)
assert(storage.bots.mining.character~=storage.bots.lights.character)
-- IDs are scoped to actors: both get ID 1, with different target/state.
local a=ok('mining','walk_to',{position={x=11,y=20},timeout_ticks=30})
local b=ok('lights','walk_to',{position={x=30,y=41},timeout_ticks=30})
assert(a.id==1 and b.id==1)
denied('busy','mining','walk_to',{position={x=12,y=20}})
assert(ok(nil,'inspect').active_action==nil)
game.tick=101; tick()
assert(storage.bots.mining.character.walking_state.direction==defines.direction.east)
assert(storage.bots.lights.character.walking_state.direction==defines.direction.south)
ok('mining','stop')
assert(ok('mining','action',{id=1}).status=='cancelled')
assert(ok('lights','action',{id=1}).status=='running')
assert(storage.bots.lights.character.walking_state.walking)
-- One bot's death fails only its action. Another completes in the same tick.
ok('mining','walk_to',{position={x=12,y=20},timeout_ticks=30})
storage.bots.mining.character.valid=false
storage.bots.lights.character.position={x=30,y=41}
game.tick=102; tick()
assert(ok('mining','action',{id=2}).error.code=='character_lost')
assert(ok('lights','action',{id=1}).status=='completed')
-- Respawn is empty and retains this actor's action sequence/history.
assert(not ok('mining','spawn',{position={x=10,y=20}}).existing)
assert(next(ok('mining','inspect').inventory)==nil)
assert(ok('mining','walk_to',{position={x=11,y=20},timeout_ticks=1}).id==3)
game.tick=103; tick()
assert(ok('mining','action',{id=3}).error.code=='timeout')
-- Error handling restores default request context; inspections remain isolated.
denied('unknown_action','lights','action',{id=999})
assert(ok(nil,'inspect').position.x==1)
-- Hard cap bounds per-tick work, including the migrated default character.
for i=1,5 do ok('extra'..i,'spawn',{position={x=i,y=0}}) end
denied('bot_limit','overflow','spawn',{position={x=0,y=0}})
assert(storage.bots.overflow==nil)
-- Simulate a mod reload/save load: registry and legacy character stay identical.
local saved=storage.bots
dofile('mods/factorio-control/control.lua')
assert(ok('lights','spawn').existing)
assert(storage.bots==saved and storage.bots.default==legacy)
print('multi_bot_test: passed')
