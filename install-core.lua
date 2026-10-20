-- Pure install state machine. transition(state, event) returns a new state
-- and effects. It does not touch the terminal, the filesystem, rednet, or GPS.

local M = { v = 1 }

local RETRY = {
  code_expired = "enter_code", code_replayed = "enter_code", code_burned = "enter_code",
  code_rejected = "enter_code", code_unknown = "enter_code",
  neighbour_missing = "neighbour", neighbour_unknown = "neighbour",
  disk_full = "fetch", hash_mismatch = "fetch", missing = "fetch",
}

local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, item in pairs(v) do out[copy(k, seen)] = copy(item, seen) end
  return out
end

function M.fits(role, kind)
  return role.on == kind or (role.on == "any" and kind ~= "pocket")
end

function M.boot(machine, catalog)
  machine = machine or {}
  local state = {
    v = 1, step = "detect",
    machine = {
      kind = machine.kind or "computer",
      advanced = machine.advanced == true,
      id = machine.id or 0,
      label = machine.label or false,
      sides = copy(machine.sides or {}),
    },
    source = false, role = false, enrol = false, pos = false, files = false,
    error = false, history = {}, draft = false, manifest = false,
    catalog = copy(catalog or {}),
  }
  return state, { { op = "scan" } }
end

function M.options(state)
  local step = state.step
  if step == "source" then
    return {
      { id = "code", label = "Copy a code" },
      { id = "neighbour", label = "Copy from a neighbour" },
      { id = "fresh", label = "Set up as new" },
    }
  end
  if step == "role" then
    local out = {}
    for _, role in ipairs(state.catalog or {}) do
      if M.fits(role, state.machine.kind) then
        out[#out + 1] = { id = role.id, label = role.name }
      end
    end
    return out
  end
  if step == "neighbour" then
    local out = {}
    for side, info in pairs(state.machine.sides or {}) do
      if type(info) == "table" and (info.kind == "computer" or info.kind == "turtle")
        and type(info.id) == "number" then
        out[#out + 1] = { id = side, label = side .. " #" .. info.id, side = side, nid = info.id }
      end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
  end
  if step == "position" and not (state.draft and state.draft.phase) then
    return {
      { id = "f3", label = "Type the F3 position" },
      { id = "here", label = "This spot is home" },
    }
  end
  if step == "facing" then
    return {
      { id = 0, label = "North" },
      { id = 1, label = "East" },
      { id = 2, label = "South" },
      { id = 3, label = "West" },
    }
  end
  if step == "review" then
    return { { id = "go", label = "Install" }, { id = "back", label = "Back" } }
  end
  if step == "error" then
    return {
      { id = "retry", label = "Retry" },
      { id = "back", label = "Back" },
      { id = "help", label = "Help" },
    }
  end
  return {}
end

local function push(state)
  state.history[#state.history + 1] = state.step
end

local function fail(state, code, retry, detail)
  push(state)
  state.step = "error"
  state.error = { code = code, retry = retry, detail = detail or "" }
  state.draft = false
  return state, {}
end

local function onward(state)
  if not state.role then
    state.step, state.draft = "role", false
  elseif state.pos == false or state.pos.x == nil then
    state.step, state.draft = "position", false
  elseif type(state.pos.h) ~= "number" then
    state.step, state.draft = "facing", false
  else
    state.step, state.draft = "review", false
  end
  return state, {}
end

local function bundle(state)
  state.step = "fetch"
  state.draft = false
  return state, { { op = "apply_bundle", role = state.role, filesRef = state.enrol and state.enrol.filesRef or false } }
end

local function cfgOf(state)
  return {
    v = 1, role = state.role, source = state.source, pos = state.pos,
    manifest = state.manifest or false,
    pairingKey = state.enrol and state.enrol.pairingKey or false,
  }
end

local function retry(state)
  local code = state.error and state.error.code
  local dest = (state.error and state.error.retry) or RETRY[code] or "source"
  state.error, state.draft = false, false
  state.step = dest
  if dest == "detect" or dest == "neighbour" then return state, { { op = "scan" } } end
  if dest == "fetch" then return bundle(state) end
  if dest == "pair" then return state, { { op = "write_cfg", cfg = cfgOf(state) } } end
  return state, {}
end

local function back(state)
  if #state.history == 0 then return state, {} end
  state.step = table.remove(state.history)
  state.error, state.draft = false, false
  return state, {}
end

local function integer(text, lo, hi)
  if not text:match("^%-?%d+$") then return nil end
  local n = tonumber(text)
  if not n or n % 1 ~= 0 or n < lo or n > hi then return nil end
  return n
end

function M.transition(prev, event)
  local state = copy(prev)
  event = event or {}
  if event.t == "back" then return back(state) end
  if event.t == "retry" and state.step == "error" then return retry(state) end
  if event.t == "io" and event.op == "gps" then return state, {} end

  if state.step == "detect" then
    if event.t == "io" and event.op == "scan" and event.ok and type(event.value) == "table" then
      local machine = event.value
      state.machine.kind = machine.kind or state.machine.kind
      state.machine.advanced = machine.advanced == true
      state.machine.id = machine.id or state.machine.id
      state.machine.label = machine.label or false
      state.machine.sides = copy(machine.sides or {})
      push(state)
      state.step = "source"
      return state, {}
    end
    if event.t == "io" and event.op == "scan" then
      return fail(state, "scan_failed", "detect", "This computer could not be read.")
    end
    return state, {}
  end

  if state.step == "error" then
    local opts = M.options(state)
    if event.t == "choose" and opts[event.n] then
      local pick = opts[event.n].id
      if pick == "retry" then return retry(state) end
      if pick == "back" then return back(state) end
      if pick == "help" then
        state.draft = { help = true }
        return state, {}
      end
    end
    return state, {}
  end

  if event.t == "choose" then
    local opts = M.options(state)
    local pick = opts[event.n]
    if not pick then return state, {} end
    if state.step == "source" then
      push(state)
      state.source = pick.id == "code" and "code" or pick.id == "neighbour" and "neighbour" or "fresh"
      if pick.id == "code" then
        state.step, state.draft = "enter_code", false
        return state, {}
      end
      if pick.id == "neighbour" then
        state.step = "neighbour"
        return state, { { op = "scan" } }
      end
      state.step = "role"
      return state, {}
    end
    if state.step == "role" then
      push(state)
      state.role = pick.id
      return onward(state)
    end
    if state.step == "neighbour" then
      push(state)
      return state, { { op = "rpc", call = "enrol-neighbour", neighbour = pick.nid, side = pick.side } }
    end
    if state.step == "position" and pick.id == "f3" then
      state.draft = { phase = "x" }
      return state, {}
    end
    if state.step == "position" and pick.id == "here" then
      state.draft = { phase = "clock" }
      return state, { { op = "clock" } }
    end
    if state.step == "facing" then
      push(state)
      state.pos = copy(state.pos)
      state.pos.h = pick.id
      state.step, state.draft = "review", false
      return state, {}
    end
    if state.step == "review" and pick.id == "go" then
      push(state)
      return bundle(state)
    end
    if state.step == "review" and pick.id == "back" then return back(state) end
    return state, {}
  end

  if state.step == "enter_code" and event.t == "text" then
    local text = tostring(event.s or "")
    if #text < 16 or #text > 48 or not text:match("^[%w:._ -]+$") then
      state.draft = { note = "Enter the 16 character code." }
      return state, {}
    end
    state.draft = { pending = true }
    return state, { { op = "rpc", call = "enrol-hello", code = text } }
  end

  if state.step == "position" and state.draft and state.draft.phase
    and state.draft.phase ~= "clock" and event.t == "text" then
    local phase = state.draft.phase
    local lo, hi = -30000000, 30000000
    if phase == "y" then lo, hi = -2048, 2048 end
    local n = integer(tostring(event.s or ""), lo, hi)
    if not n then
      state.draft.note = "Enter a whole number."
      return state, {}
    end
    state.draft[phase] = n
    state.draft.note = false
    if phase == "x" then state.draft.phase = "y"
    elseif phase == "y" then state.draft.phase = "z"
    else
      push(state)
      state.pos = {
        v = 1, frame = "abs", yAbs = true, dim = "minecraft:overworld",
        x = state.draft.x, y = state.draft.y, z = state.draft.z, h = false,
        conf = "certain", src = "typed", anchoredAt = false,
      }
      state.step, state.draft = "facing", false
    end
    return state, {}
  end

  if event.t ~= "io" then return state, {} end

  if state.step == "neighbour" and event.op == "scan" then
    if not (event.ok and type(event.value) == "table") then
      return fail(state, "neighbour_missing", "neighbour", "No neighbour answered.")
    end
    state.machine.sides = copy(event.value.sides or {})
    if #M.options(state) == 0 then
      return fail(state, "neighbour_missing", "neighbour", "No computer or turtle is on any side.")
    end
    state.draft = false
    return state, {}
  end

  if event.op == "clock" and state.draft and state.draft.phase == "clock" then
    if not (event.ok and type(event.value) == "number") then
      return fail(state, "clock", "position", "No clock.")
    end
    push(state)
    state.pos = {
      v = 1, frame = "f:" .. tostring(state.machine.id) .. ":" .. string.format("%.0f", event.value),
      yAbs = false, dim = "minecraft:overworld",
      x = 0, y = 0, z = 0, h = false,
      conf = "suspect", src = "reckoned", anchoredAt = event.value,
    }
    state.step, state.draft = "facing", false
    return state, {}
  end

  if event.op == "rpc" then
    if not event.ok then
      local err = event.error or {}
      local code = err.code or "code_rejected"
      return fail(state, code, RETRY[code] or "source", err.detail or "")
    end
    local value = event.value or {}
    if value.role then state.role = value.role end
    if value.home then state.pos = copy(value.home) end
    if value.pos then state.pos = copy(value.pos) end
    state.enrol = copy(value)
    if state.step == "neighbour" or state.step == "enter_code" then push(state) end
    return onward(state)
  end

  if state.step == "fetch" and event.op == "apply_bundle" then
    if not event.ok then
      local err = event.error or {}
      local code = err.code or "hash_mismatch"
      return fail(state, code, RETRY[code] or "fetch", err.detail or "")
    end
    state.files = copy(event.value and event.value.files or {})
    state.manifest = event.value and event.value.manifest or false
    push(state)
    state.step = "pair"
    return state, { { op = "write_cfg", cfg = cfgOf(state) } }
  end

  if state.step == "pair" and event.op == "write_cfg" then
    if not event.ok then
      return fail(state, "pair_failed", "pair", (event.error and event.error.detail) or "Could not save install.cfg.")
    end
    push(state)
    state.step = "done"
    return state, { { op = "reboot" } }
  end

  return state, {}
end

return M
