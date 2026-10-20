local M = {}

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

function M.snapshot(client)
  local api = require("wh2-wizard-adapter").open({enabled=true, client=client})
  local snapshot, err = api.snapshot()
  return assert(snapshot, err)
end

local function openBoard(client, target, allowConflict)
  target = target or peripheral.find("monitor") or term.current()
  if target.setTextScale then target.setTextScale(0.5) end
  local width, height = target.getSize()
  assert(width >= 26 and height >= 16, "board needs at least 26 columns and 16 rows")
  local board = require("wh2-board").open({enabled=true, client=client, term=target})
  board.tick()
  assert(allowConflict or not board.state.failure, board.state.status)
  return board, target, height
end

local function selectItem(board, item)
  if board.state.view == "answer" and board.state.draft and board.state.draft.item == item then return end
  if board.state.draft then board.handle("char", "b") board.tick() end
  local wanted
  for index, queued in ipairs(board.state.queue) do
    if queued == item then wanted = index break end
  end
  assert(wanted, "board lost pending item")
  for _ = 1, #board.state.queue do
    if board.state.selection == wanted then break end
    board.handle("key", board.state.selection < wanted and keys.down or keys.up)
  end
  assert(board.state.queue[board.state.selection] == item, "board lost pending item")
  board.handle("key", keys.enter)
  board.tick()
  assert(board.state.draft and board.state.draft.item == item, "board did not open answer")
end

function M.report(client, items, evidence, inventory, location)
  for _, item in ipairs(items) do
    assert((inventory.totals[item] or 0) > 0, "reported unknown is absent from native inventories")
  end
  local before = M.snapshot(client)
  for _, item in ipairs(items) do
    local reply = assert(client.call("wh2-unknown", {wh2=1, item=item, sampleLocationId=location}))
    assert(reply.ok, reply.error)
    if before.questions[item] then
      assert(same(reply.question, before.questions[item]), "duplicate report reset a durable question or draft")
    end
  end
  evidence("observed-unknowns", {items=items, totals=inventory.totals, revision=M.snapshot(client).revision})
end

function M.board(client, items, evidence, target)
  local before = M.snapshot(client)
  for _, item in ipairs(items) do
    local question = before.questions[item]
    assert(question and (question.state == "open" or question.state == "answering"), "unknown question missing")
    assert(not before.classes[item], "scenario item already has a class")
  end
  local board, display, height = openBoard(client, target)
  local skipped = board.state.queue[board.state.selection]
  board.handle("char", "s")
  board.tick()
  assert(same(M.snapshot(client).questions[skipped], before.questions[skipped]), "skip changed durable question")
  board.handle("char", "k")
  board.tick()
  for _, item in ipairs(items) do
    selectItem(board, item)
    board.handle("char", "1")
    board.tick()
    board.draw(display, "gate-monitor")
    board.handle("monitor_touch", "gate-monitor", 2, height - 4)
    for _ = 1, 3 do board.tick() end
    assert(not board.state.failure, board.state.status)
    local snapshot = M.snapshot(client)
    assert(snapshot.classes[item] and snapshot.classes[item].route == "store", "board did not commit store answer")
    assert(snapshot.questions[item].state == "resolved" and snapshot.questions[item].draft == false,
      "answer left an unresolved question or draft")
    evidence("board-answer", {item=item, revision=snapshot.revision, class=snapshot.classes[item]})
  end
  board.close()
  return M.snapshot(client)
end

function M.draft(client, item, evidence, target)
  local before = M.snapshot(client)
  assert(before.questions[item] and before.questions[item].state == "open", "draft requires an open question")
  local board = openBoard(client, target)
  selectItem(board, item)
  board.handle("char", "1")
  board.handle("char", "c")
  for _ = 1, 3 do board.tick() end
  local snapshot = M.snapshot(client)
  local question = assert(snapshot.questions[item])
  assert(question.state == "answering" and type(question.draft) == "table", "board did not persist partial answer")
  assert(question.draft.editor == os.getComputerID() and question.draft.answers.route == "store",
    "saved draft lost its editor or selected route")
  assert(not snapshot.classes[item], "partial answer became an effective class")
  board.close()
  evidence("draft-saved", {item=item, question=question, revision=snapshot.revision})
  return {item=item, question=question}
end

function M.draftRetained(client, saved, evidence, target)
  local snapshot = M.snapshot(client)
  local question = assert(snapshot.questions[saved.item], "saved draft question disappeared")
  assert(same(question, saved.question), "saved draft changed across reboot or duplicate reports")
  assert(not snapshot.classes[saved.item], "unresolved draft entered effective classes")
  local board = openBoard(client, target)
  selectItem(board, saved.item)
  local draft = board.state.draft
  assert(draft.draftRevision == question.draft.revision and draft.step == question.draft.step
    and draft.text == question.draft.text, "board did not restore the saved draft step or text")
  for field, value in pairs(question.draft.answers) do
    assert(draft[field] == value, "board did not restore draft field " .. field)
  end
  board.close()
  evidence("retained-draft", {item=saved.item, question=question, revision=snapshot.revision})
end

function M.draftOwner(client, item, evidence, target)
  local before = M.snapshot(client)
  local question = assert(before.questions[item])
  assert(question.state == "answering" and question.draft.editor ~= os.getComputerID(), "ownership check requires a foreign draft")
  local board = openBoard(client, target, true)
  selectItem(board, item)
  board.handle("char", "1")
  board.tick()
  assert(same(M.snapshot(client), before), "foreign editor changed a draft without takeover")
  local rejected = assert(client.call("wh2-class", {wh2=1, action="draft", item=item,
    questionId=question.id, baseRevision=before.revision - 1, draftRevision=question.draft.revision,
    draft=question.draft}))
  assert(not rejected.ok and rejected.code == "stale_revision", "stale editor replaced a durable draft")
  assert(same(M.snapshot(client), before), "stale draft changed authority")
  board.handle("char", "t")
  for _ = 1, 3 do board.tick() end
  local after = M.snapshot(client)
  assert(after.questions[item].draft.editor == os.getComputerID(), "explicit board takeover did not change editor")
  assert(after.questions[item].draft.revision > question.draft.revision, "takeover did not fence previous editor")
  board.close()
  evidence("draft-takeover", {item=item, previousEditor=question.draft.editor, question=after.questions[item]})
end

function M.discard(client, item, evidence, target)
  local board = openBoard(client, target)
  selectItem(board, item)
  board.handle("char", "x")
  for _ = 1, 3 do board.tick() end
  local snapshot = M.snapshot(client)
  assert(snapshot.questions[item].state == "open" and snapshot.questions[item].draft == false,
    "discard did not reset the question to open")
  assert(not snapshot.classes[item], "discard published a partial class")
  board.close()
  evidence("draft-discarded", {item=item, question=snapshot.questions[item]})
end

function M.retained(client, items, evidence, expected)
  local snapshot = M.snapshot(client)
  for _, item in ipairs(items) do
    assert(snapshot.classes[item] and snapshot.classes[item].route == "store", "answer did not survive restart")
    assert(snapshot.questions[item] and snapshot.questions[item].state == "resolved"
      and snapshot.questions[item].draft == false, "question resolution did not survive restart")
    if expected then
      assert(same(snapshot.classes[item], expected.classes[item]), "restart changed the saved class answer")
      assert(same(snapshot.questions[item], expected.questions[item]), "restart changed the saved question")
    end
  end
  evidence("retained-answers", snapshot)
  return snapshot
end

function M.fuzz(client, evidence)
  local before = M.snapshot(client)
  local malformed = {
    {"wh2-unknown", {item=false, sampleLocationId=false}},
    {"wh2-unknown", {item="bad id", sampleLocationId=false}},
    {"wh2-class", {action="set", item="minecraft:stone", value={}, baseRevision=before.revision}},
    {"wh2-class", {action="set", item="minecraft:stone", value={class="misc", route="discard", storeCategory="misc", recipeId=false}, baseRevision=before.revision}},
    {"wh2-get", {topic="questions", cursor=-1}},
    {"wh2-get", {topic="classes", cursor=0, extra=true}},
    {"wh2-unknown", {item="minecraft:stone", sampleLocationId=12}},
    {"wh2-unknown", {item="minecraft:stone", sampleLocationId=false, extra=true}},
    {"wh2-get", {topic="questions", cursor=0, revision=-1}},
    {"wh2-get", {topic="classes", cursor=0, revision="invalid"}},
    {"wh2-get", {topic="questions", cursor=0.5}},
    {"wh2-class", {action="set", item="minecraft:stone", value={class="invalid", route="store", storeCategory="misc", recipeId=false}, baseRevision=before.revision}},
    {"wh2-class", {action="set", item="minecraft:stone", value={class="misc", route="store", storeCategory="invalid", recipeId=false}, baseRevision=before.revision}},
    {"wh2-class", {action="set", item="minecraft:stone", value={class="misc", route="store", storeCategory="misc", recipeId="bad id"}, baseRevision=before.revision}},
    {"wh2-class", {action="resolve", item="minecraft:stone", questionId=false, draftRevision=-1, baseRevision=before.revision}},
    {"wh2-class", {action="draft", item="minecraft:stone", questionId="item:minecraft:stone", draftRevision=0, baseRevision=before.revision, draft=false}},
  }
  local seed = 731
  for _ = 1, 128 do
    seed = seed * 16807 % 2147483647
    malformed[#malformed + 1] = {"wh2-unknown", {item="bad " .. seed, sampleLocationId=false}}
  end
  for _, case in ipairs(malformed) do
    case[2].wh2 = 1
    local reply = client.call(case[1], case[2])
    assert(type(reply) == "table" and reply.ok == false, "malformed request was accepted or timed out")
  end
  local after = M.snapshot(client)
  assert(same(before, after), "fuzz changed durable wizard state")
  evidence("fuzz", {seed=731, cases=#malformed, revision=after.revision})
end

function M.concurrent(client, evidence)
  local before = M.snapshot(client)
  local item
  for name in pairs(before.classes) do item = name break end
  assert(item, "stale answer check requires a resolved class")
  local body = {wh2=1, action="set", item=item, baseRevision=before.revision,
    value={class="misc", route="store", storeCategory="misc", recipeId=false}}
  local first = assert(client.call("wh2-class", body))
  assert(first.ok, "first concurrent answer failed")
  local committed = M.snapshot(client)
  local stale = assert(client.call("wh2-class", body))
  assert(not stale.ok and stale.code == "stale_revision", "stale concurrent answer overwrote authority")
  assert(same(committed, M.snapshot(client)), "stale answer changed saved state")
  evidence("stale-answer", {firstRevision=first.revision, rejected=stale.code, simultaneous=false})
end

return M
