local previousColors=colors
colors={white=1,black=32768,gray=128,lightGray=256,cyan=512,lime=32,orange=2,red=16384,blue=2048}
local V=dofile('views.lua')
local function screen(w,h,color)
 local lines={} local x,y=1,1
 return {name='term',buttons={},t={getSize=function()return w,h end,isColor=function()return color end,setBackgroundColor=function() if not color then error('colour not supported') end end,setTextColor=function() if not color then error('colour not supported') end end,clear=function()lines={}end,setCursorPos=function(a,b)assert(a>=1 and a<=w and b>=1 and b<=h) x,y=a,b end,write=function(s)assert(x+#s-1<=w,'clipped output') lines[y]=(lines[y]or'')..s end},lines=function()return table.concat(lines,'\n')end}
end
local scene={dim='minecraft:overworld',cells={},sites={},stale=false}
local ui=V.new({mode='pro'}, {scene=function()return scene end})
local fleet={}
for i=1,39 do fleet[i]={id=i,label='Turtle '..i,fuel='unlimited',free=12,status='mining',age=1,x=i,y=64,z=0} end
local s=screen(51,19,true)
ui.draw(s,fleet,1,{P=true,T=false,O=true,A=false})
assert(s.lines():find('unlimited',1,true),'unlimited fuel is visible')
assert(s.lines():find('HUD',1,true),'pro view has an AR tap target')
local hudTap=ui.click(s,1,19)
assert(hudTap and hudTap.kind=='layer' and hudTap.key=='P','HUD tap does not toggle the HUD layer')
local oreTap=ui.click(s,9,19)
assert(oreTap and oreTap.kind=='layer' and oreTap.key=='O','ORE tap does not toggle the ore layer')
assert(s.lines():find('1/3',1,true),'fleet paginates')
ui.key(']') ui.draw(s,fleet,1)
assert(s.lines():find('2/3',1,true),'page changes')
for _,size in ipairs({{12,6},{1,1},{26,12},{80,24}}) do ui.draw(screen(size[1],size[2],false),fleet,1) end
local short=screen(20,5,true)
ui.draw(short,fleet,1)
assert(not short.lines():find('E-stop',1,true),'short monitor hides the footer')
assert(not short.lines():find('HUD',1,true),'short monitor hides AR taps')
ui.key('m')
ui.key('t')
scene.cells={{x=0,y=64,z=0,name=false}}
ui.camera.center={x=0,y=64,z=0}
ui.draw(s,fleet,1)
local px,py=dofile('view-scene.lua').project(scene.cells[1],ui.camera,51,14)
px,py=math.floor(px),math.floor(py)+2
local footer=ui.click(s,1,19)
assert(not footer or footer.kind~='layer','map view kept the pro AR taps')
local picked=ui.click(s,px,py)
assert(picked and picked.kind=='move' and picked.point.y==64,'known AIR click carries world coordinates')
assert(picked.point.dim=='minecraft:overworld','click preserves dimension')
scene.cells[1].name='minecraft:stone'
ui.draw(s,fleet,1)
assert(not ui.click(s,px,py),'solid cell cannot move')
scene.cells[1].name=false
scene.stale=true
local a=ui.click(s,px,py)
assert(not a or a.kind~='move','stale map cannot move')
assert(ui.key('e').kind=='estop','emergency stop remains explicit')
assert(ui.key('r').kind=='recall','recall action')
assert(ui.key('h').kind=='resume','resume action')
print('view UI checks passed')
colors=previousColors
