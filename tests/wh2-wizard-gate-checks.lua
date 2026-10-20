local M = {}

local function count(rows)
  local n = 0
  for _ in pairs(rows) do n = n + 1 end
  return n
end

function M.board(client, items, evidence, target)
  local Adapter = require("wh2-wizard-adapter")
  local Board = require("wh2-board")
  local api = Adapter.open({enabled=true, client=client})
  local before = assert(api.snapshot())
  for _, item in ipairs(items) do
    assert(before.questions[item] and before.questions[item].state == "open", "unknown question missing")
    assert(not before.classes[item], "scenario item already has a class")
  end
  target = target or peripheral.find("monitor") or term.current()
  if target.setTextScale then target.setTextScale(0.5) end
  local width, height = target.getSize()
  assert(width >= 26 and height >= 20, "board needs a real monitor of at least 26 x 20")
  local board = Board.open({enabled=true, client=client, term=target})
  board.tick()
  assert(not board.state.failure, board.state.status)
  local skipped = board.state.queue[board.state.selection]
  board.handle("char", "s")
  board.tick()
  assert(assert(api.snapshot()).questions[skipped].state == "open", "skip resolved durable question")
  board.handle("char", "k")
  board.tick()
  assert(#board.state.queue == count(before.questions), "show skipped lost question")
  for _ = 1, #items do
    local item = board.state.queue[board.state.selection]
    assert(item, "board lost pending item")
    board.handle("key", keys.enter)
    assert(board.state.draft and board.state.draft.item == item, "board did not open answer")
    board.handle("char", "1")
    board.draw(target, "gate-monitor")
    board.handle("monitor_touch", "gate-monitor", 2, height - 4)
    board.tick()
    assert(not board.state.failure, board.state.status)
    board.tick()
    local snapshot = assert(api.snapshot())
    assert(snapshot.classes[item].route == "store", "board did not commit store answer")
    assert(snapshot.questions[item].state == "resolved", "answer left question open")
    evidence("board-answer", {item=item, revision=snapshot.revision, class=snapshot.classes[item]})
  end
  board.close()
  return assert(api.snapshot())
end

function M.retained(client, items, evidence)
  local api = require("wh2-wizard-adapter").open({enabled=true, client=client})
  local snapshot = assert(api.snapshot())
  for _, item in ipairs(items) do
    assert(snapshot.classes[item] and snapshot.classes[item].route == "store", "answer did not survive restart")
    assert(snapshot.questions[item] and snapshot.questions[item].state == "resolved", "question resolution did not survive restart")
  end
  evidence("retained-answers", snapshot)
end

function M.fuzz(client, evidence)
  local api = require("wh2-wizard-adapter").open({enabled=true, client=client})
  local before = assert(api.snapshot())
  local malformed = {
    {"wh2-unknown", {item=false, sampleLocationId=false}},
    {"wh2-unknown", {item="bad id", sampleLocationId=false}},
    {"wh2-class", {item="minecraft:stone", value={}, baseRevision=before.revision}},
    {"wh2-class", {item="minecraft:stone", value={class="misc", route="discard", storeCategory="misc", recipeId=false}, baseRevision=before.revision}},
    {"wh2-get", {topic="questions", cursor=-1}},
    {"wh2-get", {topic="classes", cursor=0, extra=true}},
    {"wh2-unknown", {item="minecraft:stone", sampleLocationId=12}},
    {"wh2-unknown", {item="minecraft:stone", sampleLocationId=false, extra=true}},
    {"wh2-get", {topic="questions", cursor=0, revision=-1}},
    {"wh2-get", {topic="classes", cursor=0, revision="invalid"}},
    {"wh2-get", {topic="questions", cursor=0.5}},
    {"wh2-class", {item="minecraft:stone", value={class="invalid", route="store", storeCategory="misc", recipeId=false}, baseRevision=before.revision}},
    {"wh2-class", {item="minecraft:stone", value={class="misc", route="store", storeCategory="invalid", recipeId=false}, baseRevision=before.revision}},
    {"wh2-class", {item="minecraft:stone", value={class="misc", route="store", storeCategory="misc", recipeId="bad id"}, baseRevision=before.revision}},
  }
  local seed = 731
  for i = 1, 128 do
    seed = seed * 16807 % 2147483647
    malformed[#malformed + 1] = {"wh2-unknown", {item="bad " .. seed, sampleLocationId=false}}
  end
  for _, case in ipairs(malformed) do
    case[2].wh2 = 1
    local reply = client.call(case[1], case[2])
    assert(type(reply) == "table" and reply.ok == false, "malformed request was accepted or timed out")
  end
  local after = assert(api.snapshot())
  assert(textutils.serialize(before) == textutils.serialize(after), "fuzz changed durable wizard state")
  evidence("fuzz", {seed=731, cases=#malformed, revision=after.revision})
end

function M.concurrent(client, evidence)
  local api = require("wh2-wizard-adapter").open({enabled=true, client=client})
  local snapshot = assert(api.snapshot())
  local body = {wh2=1, item="superbwarfare:scheelite", baseRevision=snapshot.revision,
    value={class="misc", route="store", storeCategory="misc", recipeId=false}}
  local first = assert(client.call("wh2-class", body))
  assert(first.ok, "first concurrent answer failed")
  local stale = assert(client.call("wh2-class", body))
  assert(not stale.ok and stale.code == "stale_revision", "stale concurrent answer overwrote authority")
  evidence("stale-answer", {firstRevision=first.revision, rejected=stale.code, simultaneous=false})
end

return M
