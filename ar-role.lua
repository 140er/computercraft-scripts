local args = { ... }
if args[1] == "install" then
  local h = assert(fs.open("startup.lua", "w"))
  h.write('shell.run("ar-role")\n')
  h.close()
  print("AR role installed. It uses the hub owner. AR and chat remain opt-in.")
  return
end
return shell.run("hub", table.unpack(args))
