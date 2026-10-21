-- shortcut: idle home fixture only; use Minecraft to test movement and mining.
local selected, heading = 1, 0
return {
  select = function(slot) selected = slot return true end,
  getSelectedSlot = function() return selected end,
  getFuelLevel = function() return "unlimited" end,
  getFuelLimit = function() return 100000 end,
  getItemCount = function(slot) return (slot or selected) == 1 and 1 or 0 end,
  getItemDetail = function(slot)
    if (slot or selected) == 1 then return { name = "minecraft:bucket", count = 1 } end
  end,
  refuel = function() return false end,
  turnRight = function() heading = (heading + 1) % 4 return true end,
  turnLeft = function() heading = (heading + 3) % 4 return true end,
  inspect = function()
    if heading == 2 then return true, { name = "minecraft:chest" } end
    return false, "No block to inspect"
  end,
  suck = function() return false end,
  drop = function() return true end,
  -- No movement methods: an unexpected mining job must fail this smoke test.
}
