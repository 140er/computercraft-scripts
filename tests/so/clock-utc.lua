local files = {
  "so-log.lua",
  "so-lumber-plan.lua",
  "so-mine-plan.lua",
  "so-mod-ar.lua",
  "so-mod-cells.lua",
  "so-mod-daily.lua",
  "so-mod-display.lua",
  "so-mod-drops.lua",
  "so-mod-lease.lua",
  "so-mod-lumber.lua",
  "so-mod-map.lua",
  "so-mod-mine.lua",
  "so-mod-panel.lua",
  "so-mod-shop.lua",
  "so-mod-state.lua",
  "so-pair.lua",
  "so-plan.lua",
  "so-proto.lua",
  "so-server.lua",
  "so-store.lua",
  "so-ui.lua",
  "worker.lua",
  "display.lua",
}
local function read(path)
  local f = assert(io.open(path,"rb"))
  local s = f:read("*a");f:close();return s
end
return function(test)
  test("clock UTC reads match the reviewed real-date and wire allow-list",function()
    local allowed = {}
    for line in read("tests/so/clock-utc.tsv"):gmatch("[^\r\n]+") do allowed[line]=true end
    for _, path in ipairs(files) do
      for line in read(path):gmatch("[^\r\n]+") do
        if line:match([[os%s*%.%s*epoch%s*%(%s*["']utc["']%s*%)]]) then
          local key=path.."\t"..line:match("^%s*(.-)%s*$")
          assert(allowed[key],path..": unreviewed UTC read: "..line)
          allowed[key]=nil
        end
      end
    end
    assert(next(allowed)==nil,"stale UTC allowance")
  end)
end
