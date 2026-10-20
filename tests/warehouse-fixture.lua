local F={air={},blocks={},inventories={}}
function F.pose(x,z,h) return {dim="minecraft:overworld",x=x,y=65,z=z,h=h or 2} end
for x=0,12 do for z=-4,4 do F.air[#F.air+1]=F.pose(x,z) end end
for x=0,10 do F.air[#F.air+1]=F.pose(x,8) end
for z=5,7 do F.air[#F.air+1]=F.pose(0,z) F.air[#F.air+1]=F.pose(10,z) end
F.air[#F.air+1]=F.pose(7,9)
for id=1,3 do
  local x=id*4-3
  F.blocks[x..",65,-1"]="minecraft:barrel"
  F.blocks[x..",65,5"]="minecraft:chest"
  F.inventories[x..",65,-1"]={{name="minecraft:dirt",count=7},{name="minecraft:iron_ingot",count=11},{name="minecraft:diamond_pickaxe",count=1}}
  F.inventories[x..",65,5"]={}
end
F.sites={charge={kind="charge",pose=F.pose(6,-3,0),side="front"}}
for id=1,3 do
  F.sites["source"..id]={kind="source",pose=F.pose(id*4-3,0,0),side="front"}
  F.sites["drop"..id]={kind="drop",pose=F.pose(id*4-3,4,2),side="front"}
end
return F
