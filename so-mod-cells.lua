-- so-mod-cells.lua - cell stub. SO4 replaces this file and keeps these calls.

return {
  name = "cells",
  handlers = {},
  tick = function() end,
  reserve = function() return true end,
  release = function() return true end,
  isFree = function() return true end,
  markDug = function() end,
  isDug = function() return false end,
  forget = function() end,
}
