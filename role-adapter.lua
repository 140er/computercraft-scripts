local M = {}
function M.warehouse()
  return nil, "Warehouse service is unavailable. PR 4 supplies its dispatcher."
end
function M.view(role)
  return false, role .. " is unavailable. PR 5 supplies its view backend."
end
return M
