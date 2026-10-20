local M={blocks={},ores={},untouched={}}
local function put(x,y,z,name,ore)
  local p={x=x,y=y,z=z,name=name}
  M.blocks[#M.blocks+1]=p
  if ore then M.ores[#M.ores+1]=p end
end
for x=0,11 do for y=64,66 do for z=1,6 do put(x,y,z,"minecraft:stone") end end end
for id=1,3 do
  local x=id*4-3
  local vein={{x,65,1},{x,66,1},{x,64,1},{x-1,65,1},{x+1,65,1},{x-1,65,2},
    {x-1,66,2},{x,66,2},{x+1,66,2},{x+2,66,2},{x+2,66,3},{x+1,66,3}}
  if id==2 then
    for a=x-1,x+2 do for z=3,5 do vein[#vein+1]={a,66,z} end end
  end
  local seen={}
  for _,v in ipairs(vein) do
    local k=table.concat(v,",")
    if not seen[k] then put(v[1],v[2],v[3],id==2 and "minecraft:deepslate_diamond_ore" or "minecraft:diamond_ore",true) seen[k]=true end
  end
  local gap={x=x+2,y=65,z=6,name="minecraft:diamond_ore"}
  put(gap.x,gap.y,gap.z,gap.name) M.untouched[#M.untouched+1]=gap
end
put(9,65,4,"minecraft:gravel")
put(10,64,5,"minecraft:bedrock")
return M
