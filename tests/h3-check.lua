for _,path in ipairs({"tests/h3-runtime.lua", "tests/h3-driver.lua", "tests/h3-review.lua", "tests/sandbox/driver.lua"}) do
  assert(loadfile(path))
  print("Lua syntax passed " .. path)
end
