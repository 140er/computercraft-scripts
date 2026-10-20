local manifest=assert(loadfile(arg[1]))()
local selected={}
for i=2,#arg do
  local role=assert(manifest.roles[arg[i]],"Unknown role "..arg[i])
  assert(not role.unavailable,"Role is unavailable: "..arg[i])
  for _,file in ipairs(role.files) do selected[file]=true end
end
selected["bundle-manifest.lua"]=true
local files={}
for file in pairs(selected) do
  assert(file:match("^[%w%-]+%.lua$"),"Invalid role file")
  files[#files+1]=file
end
table.sort(files)
for _,file in ipairs(files) do print(file) end
