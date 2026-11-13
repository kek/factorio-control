-- Isolated read-only observation tests; no engine/server connection.
local methods, entity, backing, reads, looked_up = {}, nil, nil, {}, false
prototypes = {entity = {}}
local function check(ok, code, message) if not ok then error({code=code,message=message},0) end end
local function integer(v, _, lo, hi)
  check(type(v)=='number' and v>=lo and v<=hi and v==math.floor(v),'invalid_argument','integer')
  return v
end
local surface = {
  is_chunk_generated=function() return true end,
  find_entity=function() error('normal-quality lookup must not be used') end,
  find_entities_filtered=function(f)
    looked_up=true
    assert(f.name and f.position.x==1 and f.position.y==0 and f.limit==2)
    assert(not f.quality and not f.area and not f.radius)
    return entity and entity.name==f.name and {entity} or {}
  end
}
local c = {position={x=0,y=0},surface=surface}
require('mods.factorio-control.expansion').register(methods,{
  check=check,integer=integer,
  position=function(p)
    check(type(p)=='table','invalid_argument','position')
    for _,k in ipairs{'x','y'} do check(type(p[k])=='number' and p[k]==p[k] and math.abs(p[k])<=1000000,'invalid_argument',k) end
    return p
  end,
  distance=function(a,b) return math.sqrt((a.x-b.x)^2+(a.y-b.y)^2) end,
  character=function() return c end,
  contents=function(line) return line.get_contents() end
})
local function inspect(n,p)
  reads={}
  return methods.inspect_transport{name=n,position=p or {x=1,y=0}}
end
local function fails(code,fn)
  local ok,err=pcall(fn); assert(not ok and type(err)=='table' and err.code==code,'expected '..code..', got '..tostring(err))
end
local function fixture(name, kind, count, quality)
  prototypes.entity[name]={type=kind}
  backing={name=name,type=kind,valid=true,quality={name=quality},position={x=1.5,y=-2.5},direction=12}
  backing.get_max_transport_line_index=function() return count end
  backing.get_transport_line=function(i)
    assert(i>=1 and i<=count and not reads[i]); reads[i]=true
    return {valid=true,get_contents=function()
      if i==1 then return {} end
      return {{name='iron-plate',quality='normal',count=i},{name='copper-plate',quality='uncommon',count=1}}
    end}
  end
  -- A proxy catches writes to existing fields too, unlike __newindex on a table
  -- that already owns direction/name/quality keys.
  entity=setmetatable({}, {__index=backing,__newindex=function() error('mutation') end})
end
for _, family in ipairs{
  {'transport-belt',2,{'transport-belt','fast-transport-belt','express-transport-belt','turbo-transport-belt','modded-belt'}},
  {'underground-belt',4,{'underground-belt','fast-underground-belt','express-underground-belt','turbo-underground-belt','modded-underground'}},
  {'splitter',8,{'splitter','fast-splitter','express-splitter','turbo-splitter','modded-splitter'}}
} do
  for _, name in ipairs(family[3]) do for _, quality in ipairs{'normal','rare','legendary'} do
    local count=family[2]
    fixture(name,family[1],count,quality)
    local result=inspect(name)
    assert(result.name==name and result.direction==12 and result.position.x==1.5 and result.position.y==-2.5)
    assert(result.quality==nil) -- Existing request/result shapes remain unchanged.
    assert(#result.lanes==count and #result.lanes[1].items==0)
    for i=2,count do
      assert(reads[i] and result.lanes[i].index==i)
      assert(result.lanes[i].items[1].count==i and result.lanes[i].items[2].quality=='uncommon')
    end
    for _,method in ipairs{'get_max_transport_line_index','get_transport_line'} do
      local old=backing[method]; backing[method]=function() error('API failure') end
      local ok,err=pcall(function() inspect(name) end); assert(not ok and tostring(err):find('API failure'))
      backing[method]=old
    end
  end end
end
local n='splitter'
fixture(n,'splitter',8,'rare')
looked_up=false
fails('invalid_argument',function() inspect('unknown-prototype') end)
fails('invalid_argument',function() inspect(nil) end)
fails('invalid_argument',function() inspect(string.rep('n',201)) end)
fails('invalid_argument',function() inspect(n,{x=0/0,y=0}) end)
fails('invalid_argument',function() inspect(n,{x=1000001,y=0}) end)
fails('out_of_range',function() inspect(n,{x=65,y=0}) end)
assert(not looked_up)
surface.is_chunk_generated=function() return false end
fails('not_generated',function() inspect(n) end); assert(not looked_up)
surface.is_chunk_generated=function() return true end
for _,kind in ipairs{'container','assembling-machine','entity-ghost','loader','linked-belt'} do
  fixture('not-transport',kind,8,'normal')
  backing.get_max_transport_line_index=function() error('wrong type queried') end
  fails('unsupported_transport',function() inspect('not-transport') end)
end
fixture(n,'splitter',8,'legendary')
for _,count in ipairs{0,9,1.5,'8',0/0} do
  backing.get_max_transport_line_index=function() return count end
  fails('invalid_argument',function() inspect(n) end)
end
backing.get_max_transport_line_index=function() return 8 end
backing.get_transport_line=function() return {valid=false} end
fails('unsupported_transport',function() inspect(n) end)
backing.get_transport_line=function() end
fails('unsupported_transport',function() inspect(n) end)
backing.get_transport_line=function() return {valid=true,get_contents=function() error('contents API failure') end} end
local ok,err=pcall(function() inspect(n) end); assert(not ok and tostring(err):find('contents API failure'))
backing.get_transport_line=function() return {valid=true,get_contents=function()
  local items={}; for i=1,257 do items[i]={name='item-'..i,quality='normal',count=1} end; return items
end} end
fails('unsupported_inventory',function() inspect(n) end)
local old_find=surface.find_entities_filtered
surface.find_entities_filtered=function(f) assert(f.name==n and f.position.x==64 and f.position.y==0 and f.limit==2); return {entity} end
backing.get_transport_line=function() return {valid=true,get_contents=function() return {} end} end
assert(#inspect(n,{x=64,y=0}).lanes==8)
surface.find_entities_filtered=function() return {entity,entity} end
fails('ambiguous_target',function() inspect(n) end)
surface.find_entities_filtered=old_find
entity=nil; fails('not_found',function() inspect(n) end)
print('PASS: transport tiers, modded names, entity/item qualities, all lines, bounds and API failures; read-only')
