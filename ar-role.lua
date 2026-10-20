local args = { ... }
if args[1] == "install" then
  local h = assert(fs.open("startup.lua", "w"))
  h.write('shell.run("ar-role")\n')
  h.close()
  print("AR role installed. AR starts when a controller is attached. Chat stays off.")
  return
end
return shell.run("hub", table.unpack(args))
