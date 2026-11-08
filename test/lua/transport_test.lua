-- Isolated observation mocks only; no control.lua, server or game connection.
local methods, entity, reads, looked_up = {}, nil, {}, false
local function check(ok, code, message) if not ok then error({code=code,message=message},0) end end
local function integer(v, _, lo, hi)
  check(type(v)=='number' and v==math.floor(v) and v>=lo and v<=hi,'invalid_argument','integer')
  return v
end
local surface = {
  is_chunk_generated=function() return true end,
  find_entity=function(n,p) looked_up=true; assert(p.x==1 and p.y==0); return entity and entity.name==n and entity end
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
local function inspect(n,p) return methods.inspect_transport{name=n,position=p or {x=1,y=0}} end
local function fails(code,fn)
  local ok,err=pcall(fn); assert(not ok and type(err)=='table' and err.code==code,'expected '..code..', got '..tostring(err))
end
for _,case in ipairs{{'transport-belt',2},{'underground-belt',4},{'splitter',8}} do
  local n,count=case[1],case[2]
  reads={}
  entity={name=n,type=n,valid=true,quality={name='normal'},position={x=1.5,y=-2.5},direction=12}
  entity.get_max_transport_line_index=function() return count end
  entity.get_transport_line=function(i)
    assert(i>=1 and i<=count and not reads[i]); reads[i]=true
    return {valid=true,get_contents=function()
      if i==1 then return {} end
      return {{name='iron-plate',quality='normal',count=i},{name='copper-plate',quality='uncommon',count=1}}
    end}
  end
  -- Any attempted entity mutation is a test failure.
  setmetatable(entity,{__newindex=function() error('mutation') end})
  local result=inspect(n)
  assert(result.name==n and result.direction==12 and result.position.x==1.5 and result.position.y==-2.5)
  assert(#result.lanes==count and #result.lanes[1].items==0)
  for i=2,count do
    assert(reads[i] and result.lanes[i].index==i)
    assert(result.lanes[i].items[1].count==i and result.lanes[i].items[2].quality=='uncommon')
  end
  -- API exceptions must escape, not become an apparently empty observation.
  for _,method in ipairs{'get_max_transport_line_index','get_transport_line'} do
    local old=entity[method]; entity[method]=function() error('API failure') end
    local ok,err=pcall(function() inspect(n) end); assert(not ok and tostring(err):find('API failure'))
    entity[method]=old
  end
end
local n='splitter'
looked_up=false
fails('unsupported_transport',function() inspect('fast-transport-belt') end)
fails('invalid_argument',function() inspect(nil) end)
fails('invalid_argument',function() inspect(n,{x=0/0,y=0}) end)
fails('invalid_argument',function() inspect(n,{x=1000001,y=0}) end)
fails('out_of_range',function() inspect(n,{x=65,y=0}) end)
assert(not looked_up)
surface.is_chunk_generated=function() return false end
fails('not_generated',function() inspect(n) end)
assert(not looked_up)
surface.is_chunk_generated=function() return true end
entity.quality.name='rare'; fails('unsupported_transport',function() inspect(n) end); entity.quality.name='normal'
entity.get_max_transport_line_index=function() return 9 end
fails('invalid_argument',function() inspect(n) end)
entity.get_max_transport_line_index=function() return 8 end
entity.get_transport_line=function() return {valid=false} end
fails('unsupported_transport',function() inspect(n) end)
entity.get_transport_line=function() return {valid=true,get_contents=function() error('contents API failure') end} end
local ok,err=pcall(function() inspect(n) end); assert(not ok and tostring(err):find('contents API failure'))
entity.get_transport_line=function() return {valid=true,get_contents=function()
  local items={}; for i=1,257 do items[i]={name='item-'..i,quality='normal',count=1} end; return items
end} end
fails('unsupported_inventory',function() inspect(n) end)
-- The 64-tile boundary is accepted, using only the character's surface.
local old_find=surface.find_entity
surface.find_entity=function(name,p) assert(name==n and p.x==64 and p.y==0); return entity end
entity.get_transport_line=function() return {valid=true,get_contents=function() return {} end} end
assert(#inspect(n,{x=64,y=0}).lanes==8)
surface.find_entity=old_find
entity=nil; fails('not_found',function() inspect(n) end)
print('PASS: transport all lines, qualities, direction, bounds and API errors; read-only')
