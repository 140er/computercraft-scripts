local D = dofile("depth-result.lua")
local W = dofile("wh2-wizard.lua")
local checks = {}
local item = "superbwarfare:galena_ore"

local function check(name, ok, err)
  D.check(checks, name, ok, err)
end

local function ctx(now)
  return {
    now = now or 10000, epoch = 3,
    config = { enabled = true, operators = { ["4"] = true } },
  }
end

local function phase()
  if not fs.exists("wizard-phase") then return "" end
  local handle = fs.open("wizard-phase", "r")
  local text = handle.readAll()
  handle.close()
  return text
end

local function setPhase(text)
  local handle = fs.open("wizard-phase", "w")
  handle.write(text)
  handle.close()
end

local function saveState(state)
  local handle = fs.open("wizard-state", "w")
  handle.write(textutils.serialize(state))
  handle.close()
end

local function loadState()
  local handle = fs.open("wizard-state", "r")
  local text = handle.readAll()
  handle.close()
  return textutils.unserialize(text)
end

local function show(question)
  local text = question.draft and question.draft.text or question.item
  local stepName = question.draft and question.draft.step or question.state
  local handle = fs.open("board.txt", "w")
  handle.write("Wizard " .. question.id .. " step " .. tostring(stepName) .. "\n" .. tostring(text) .. "\n")
  handle.close()
  term.clear()
  term.setCursorPos(1, 1)
  print("Wizard question")
  print(question.id)
  print("step " .. tostring(stepName))
  print(text)
end

if phase() == "" then
  local state = {}
  local first = W.run(state, 4, {
    op = "wh2-unknown", body = { item = item, sampleLocationId = false },
  }, ctx(10000))
  check("unknown ore opens a question", first.ok == true and first.question.item == item, first.error)
  local draft = W.run(state, 4, {
    op = "wh2-class",
    body = {
      action = "draft", baseRevision = first.revision, item = item,
      questionId = first.question.id, draftRevision = 0,
      draft = {
        v = 1, editor = 4, revision = 0, step = "route", updatedAt = 10000,
        answers = { class = "ores", route = "blast" },
        text = "Galena ore smelts in a blast furnace.",
      },
    },
  }, ctx(11000))
  check("partial answer is saved", draft.ok == true, draft.error)
  local again = W.run(state, 4, {
    op = "wh2-unknown", body = { item = item, sampleLocationId = false },
  }, ctx(12000))
  local kept = again.question and again.question.draft and again.question.draft.text
  check("repeated unknown keeps the draft", again.ok == true and kept == "Galena ore smelts in a blast furnace.", again.error)
  show(again.question)
  saveState(state)
  setPhase("mid")
  local handle = fs.open("wizard-ready", "w")
  handle.write("mid")
  handle.close()
  return
end

if phase() == "mid" then
  local state = loadState()
  local question = state.wh2.wizard.questions[item]
  show(question)
  check("reboot redisplays the saved step", question and question.draft and question.draft.step == "route"
    and question.draft.answers.route == "blast" and question.draft.text == "Galena ore smelts in a blast furnace.",
    "draft missing after reboot")
  local resolved = W.run(state, 4, {
    op = "wh2-class",
    body = {
      action = "resolve", baseRevision = state.wh2.wizard.revision, item = item,
      questionId = question.id, draftRevision = question.draft.revision,
      value = { class = "ores", route = "blast", storeCategory = "ores", recipeId = false },
    },
  }, ctx(13000))
  check("answer resolves the ore", resolved.ok == true, resolved.error)
  saveState(state)
  setPhase("answered")
  local handle = fs.open("wizard-ready", "w")
  handle.write("answered")
  handle.close()
  return
end

local state = loadState()
local row = state.wh2.wizard.classes[item]
check("answer survives reboot", row and row.route == "blast" and row.class == "ores", "class missing")
local question = state.wh2.wizard.questions[item]
show(question or { id = "item:" .. item, item = item, state = "resolved" })
D.finish(checks)
