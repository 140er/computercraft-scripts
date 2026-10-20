return function(limit)
  local n = tonumber(limit)
  assert(n, "gate disk limit missing")
  assert(fs.getCapacity("/") == n, "disk is " .. tostring(fs.getCapacity("/")))
  return n
end
