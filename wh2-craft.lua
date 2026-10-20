-- Craft jobs, recipe-query tickets, and plan uploads. W1 calls run() from the
-- SSOT worker. This module writes only s.wh2.craft. wh2.enabled defaults off.

local M = {}

M.limits = {
  jobs = 98304,
  plan = 65536,
  steps = 128,
  queries = 4,
  fragment = 4096,
  result = 65536,
  idleMs = 30000,
  claimMs = 120000,
  page = 4096,
  pageRecords = 64,
}

local CODES = {
  invalid = true, forbidden = true, disabled = true, unavailable = true,
  stale_revision = true, busy = true, capacity = true, blocked = true,
  too_large = true, recipe_unavailable = true, incompatible = true,
  overdue = true, upload_expired = true, reconcile_required = true,
}

local JOB_STATES = {
  planning = true, planned = true, running = true, blocked = true,
  done = true, cancelled = true, uncertain = true,
}
local STEP_STATES = { pending = true, running = true, done = true, blocked = true, uncertain = true }
local UNRESOLVED = {
  chance_only = true, cycle = true, adapter_unsupported = true,
  components_unresolved = true, alternatives_incomplete = true,
  empty_tag = true, plan_limit = true,
}
local CRAFT_SLOTS = { [1] = true, [2] = true, [3] = true, [5] = true, [6] = true, [7] = true, [9] = true, [10] = true, [11] = true }

local function int(n, a, b)
  return type(n) == "number" and n == n and n % 1 == 0 and n >= a and n <= b
end

local function ident(v, max)
  return type(v) == "string" and #v > 0 and #v <= (max or 64) and v:match("^[%w_:./-]+$") ~= nil
end

local function itemId(v)
  return type(v) == "string" and #v <= 128 and v:match("^[%w_]+:[%w_/.-]+$") ~= nil
end

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return nil end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    local ck, cv = copy(k, seen), copy(v, seen)
    if ck == nil or cv == nil then seen[value] = nil return nil end
    out[ck] = cv
  end
  seen[value] = nil
  return out
end

local function bytes(value)
  local ok, text = pcall(textutils.serialize, value, { compact = true })
  if not ok then ok, text = pcall(textutils.serialize, value) end
  if not ok or type(text) ~= "string" then return nil, nil end
  return #text, text
end

function M.empty()
  return { v = 1, revision = 0, seq = 0, jobs = {}, queries = {}, planUploads = {} }
end

local function fail(code, err)
  if not CODES[code] then code = "invalid" end
  return { ok = false, wh2 = 1, code = code, error = err }
end

local function fingerprint(v)
  return v == false or (type(v) == "string" and #v <= 128)
end

local function validPath(path)
  if type(path) ~= "table" then return false end
  local n = 0
  for i, row in ipairs(path) do
    n = i
    if type(row) ~= "table" or (row.kind ~= "item" and row.kind ~= "recipe") or not itemId(row.id) then
      return false
    end
  end
  for k in pairs(path) do if not int(k, 1, n) then return false end end
  return n <= 64
end

local function validUnresolved(row)
  return type(row) == "table" and UNRESOLVED[row.code] and validPath(row.path)
    and (row.item == false or itemId(row.item))
    and (row.recipeId == false or itemId(row.recipeId))
    and type(row.detail) == "string" and #row.detail <= 256
end

local function validMissing(row)
  return type(row) == "table" and itemId(row.item) and int(row.count, 1, 1000000) and fingerprint(row.nbt)
end

local function validIngredient(row)
  return type(row) == "table" and itemId(row.item) and fingerprint(row.nbt)
    and int(row.perBatch, 1, 4096)
    and ((row.orderKey == false and row.line == false) or (ident(row.orderKey) and int(row.line, 1, 64)))
end

local function validPattern(pattern)
  if pattern == false then return true end
  if type(pattern) ~= "table" then return false end
  local n = 0
  for slot, value in pairs(pattern) do
    n = n + 1
    if n > 9 or not CRAFT_SLOTS[slot] or not (value == false or itemId(value)) then return false end
  end
  return true
end

local function validStep(step, count)
  if type(step) ~= "table" or not int(step.id, 1, count) then return false end
  if not itemId(step.recipeId) or not ident(step.type, 128) or not STEP_STATES[step.state] then return false end
  if not int(step.batches, 1, 1000000) then return false end
  if not (step.machineLocationId == false or ident(step.machineLocationId)) then return false end
  if not (step.outputItem == false or itemId(step.outputItem)) then return false end
  if not validPattern(step.pattern) or type(step.needs) ~= "table" or type(step.ingredients) ~= "table" then
    return false
  end
  if #step.needs > 128 or #step.ingredients > 64 then return false end
  for i, dep in ipairs(step.needs) do
    if not int(dep, 1, count) or dep >= step.id then return false end
  end
  for _, ingredient in ipairs(step.ingredients) do
    if not validIngredient(ingredient) then return false end
  end
  if step.observed ~= nil and step.observed ~= false then
    local seen = step.observed
    if type(seen) ~= "table" or not itemId(seen.item) or not int(seen.count, 0, 1000000)
      or not int(seen.delivered, 0, 1000000) or not (seen.locationId == false or ident(seen.locationId))
      or not int(seen.stockRevision or 0, 0, 2147483647) then
      return false
    end
  end
  return true
end

local function validJob(job)
  if type(job) ~= "table" or job.v ~= 1 or not ident(job.id) or not ident(job.key) then return false end
  if not int(job.requestedBy, 0, 2147483647) or not int(job.revision, 0, 2147483647) then return false end
  if type(job.output) ~= "table" or not itemId(job.output.item) or not int(job.output.count, 1, 1000000)
    or not fingerprint(job.output.nbt) then
    return false
  end
  if type(job.recipeChoices) ~= "table" or not JOB_STATES[job.state] then return false end
  if not (job.generation == false or ident(job.generation, 128)) then return false end
  if not (job.outputLocationId == false or ident(job.outputLocationId)) then return false end
  local claim = job.owner ~= false or job.token ~= false or job.epoch ~= false
  if claim then
    if not int(job.owner, 0, 2147483647) or not ident(job.token) or not int(job.epoch, 0, 2147483647) then
      return false
    end
  end
  if not (job.untilAt == false or int(job.untilAt, 0, 9007199254740991)) then return false end
  if not (job.overdueAt == false or int(job.overdueAt, 0, 9007199254740991)) then return false end
  if not (job.boot == false or ident(job.boot, 128)) then return false end
  if not (job.currentStep == false or int(job.currentStep, 1, 128)) then return false end
  if type(job.steps) ~= "table" or #job.steps > M.limits.steps then return false end
  for index, step in ipairs(job.steps) do
    if step.id ~= index or not validStep(step, #job.steps) then return false end
  end
  if type(job.missing) ~= "table" or type(job.unresolved) ~= "table" or type(job.events) ~= "table" then
    return false
  end
  if #job.missing > 128 or #job.unresolved > 128 then return false end
  for _, row in ipairs(job.missing) do if not validMissing(row) then return false end end
  for _, row in ipairs(job.unresolved) do if not validUnresolved(row) then return false end end
  if not int(job.progressSeq, 0, 1000000) or not int(job.produced, 0, 1000000)
    or not int(job.delivered, 0, 1000000) then
    return false
  end
  if not (job.error == false or (type(job.error) == "string" and #job.error <= 256)) then return false end
  local events = 0
  for seq, event in pairs(job.events) do
    events = events + 1
    if events > 4096 or not int(seq, 1, job.progressSeq) or type(event) ~= "table"
      or not ident(event.eventId) or type(event.body) ~= "string" or #event.body > 4096 then
      return false
    end
  end
  if job.state == "planning" and (claim or job.progressSeq ~= 0) then return false end
  if job.state == "planned" and claim then return false end
  if job.state == "done" and (claim or #job.missing > 0 or #job.unresolved > 0) then return false end
  if job.state == "done" and job.delivered < job.output.count then return false end
  return true
end

local function validQuery(query)
  if type(query) ~= "table" or query.v ~= 1 or not ident(query.ticket) or not ident(query.key) then
    return false
  end
  if not int(query.owner, 0, 2147483647) then return false end
  if query.method ~= "getRecipesFor" and query.method ~= "getUsesOf" and query.method ~= "getRecipe"
    and query.method ~= "list" and query.method ~= "resolveTag" then
    return false
  end
  if not (query.item == false or itemId(query.item)) or not int(query.page, 1, 1000000)
    or not int(query.pageSize, 1, 100) then
    return false
  end
  if query.state ~= "pending" and query.state ~= "claimed" and query.state ~= "published" then
    return false
  end
  local claimed = query.token ~= false or query.epoch ~= false or query.hub ~= false
  if claimed and (not ident(query.token) or not int(query.epoch, 0, 2147483647) or not int(query.hub, 0, 2147483647)) then
    return false
  end
  if not (query.boot == false or ident(query.boot, 128)) then return false end
  if not int(query.untilAt, 0, 9007199254740991) or not int(query.offset, 0, M.limits.result) then
    return false
  end
  if not (query.generation == false or ident(query.generation, 128)) then return false end
  if query.fragment ~= false then
    local part = query.fragment
    if type(part) ~= "table" or part.encoding ~= "lua" or type(part.data) ~= "string"
      or #part.data > M.limits.fragment or not int(part.offset, 0, M.limits.result)
      or not int(part.nextOffset, 0, M.limits.result) or not int(part.totalBytes, 0, M.limits.result) then
      return false
    end
  end
  return true
end

local function validUpload(upload)
  if type(upload) ~= "table" or upload.v ~= 1 or not ident(upload.jobId) then return false end
  if not (upload.generation == false or ident(upload.generation, 128)) then return false end
  if not int(upload.baseRevision, 0, 2147483647) or not int(upload.offset, 0, M.limits.steps) then
    return false
  end
  if type(upload.steps) ~= "table" or #upload.steps > M.limits.steps then return false end
  for index, step in ipairs(upload.steps) do
    if step.id ~= index or not validStep(step, math.max(#upload.steps, step.id)) then return false end
  end
  if type(upload.chunks) ~= "table" or type(upload.missing) ~= "table" or type(upload.unresolved) ~= "table" then
    return false
  end
  return int(upload.updatedAt, 0, 9007199254740991) and int(upload.bytes, 0, M.limits.plan)
end

function M.valid(value, poseValidator)
  if value == nil then return true end
  if type(poseValidator) ~= "function" and poseValidator ~= nil then return false end
  if type(value) ~= "table" or value.v ~= 1 or not int(value.revision, 0, 2147483647)
    or not int(value.seq, 0, 2147483647) then
    return false
  end
  if type(value.jobs) ~= "table" or type(value.queries) ~= "table" or type(value.planUploads) ~= "table" then
    return false
  end
  local jobs = 0
  for id, job in pairs(value.jobs) do
    jobs = jobs + 1
    if id ~= job.id or not validJob(job) then return false end
  end
  local queries = 0
  for id, query in pairs(value.queries) do
    queries = queries + 1
    if queries > M.limits.queries or id ~= query.ticket or not validQuery(query) then return false end
  end
  for id, upload in pairs(value.planUploads) do
    if id ~= upload.jobId or not validUpload(upload) then return false end
  end
  local size = bytes(value)
  return size ~= nil and size <= M.limits.jobs and jobs <= 256
end

local function enabled(context)
  return type(context) == "table" and type(context.config) == "table" and context.config.enabled == true
end

local function operator(context, sender)
  local ops = context.config and context.config.operators or {}
  return ops[tostring(sender)] == true
end

local function hub(context, sender)
  return type(context.config) == "table" and context.config.recipeHubId == sender
end

local function craftingOn(context)
  return type(context.settings) == "table" and context.settings.crafting == true
end

local function budget(context)
  return context and context.budget or M.limits.jobs
end

local function planBudget(context)
  return context and context.planBudget or M.limits.plan
end

local function nowOf(context)
  if type(context) ~= "table" or not int(context.now, 0, 9007199254740991) then return nil end
  if not int(context.epoch, 0, 2147483647) then return nil end
  return context.now
end

local function reply(tree, body)
  body.ok = true
  body.wh2 = 1
  body.revision = tree.revision
  return body
end

local function publicJob(job)
  local out = copy(job)
  out.events = nil
  return out
end

local function totals(job)
  local produced, delivered = 0, 0
  for _, step in ipairs(job.steps) do
    local seen = step.observed
    if type(seen) == "table" and seen.item == job.output.item
      and (job.output.nbt == false or seen.nbt == job.output.nbt) then
      produced = produced + seen.count
      if seen.delivered > delivered then delivered = seen.delivered end
    end
  end
  if #job.steps == 0 and type(job.delivery) == "table" and job.delivery.item == job.output.item then
    produced = job.delivery.count
    delivered = job.delivery.delivered
  end
  job.produced = produced
  job.delivered = delivered
end

local function refreshStep(job)
  job.currentStep = false
  for _, step in ipairs(job.steps) do
    if step.state ~= "done" then job.currentStep = step.id break end
  end
end

local function finishIfDone(job)
  refreshStep(job)
  if #job.missing > 0 or #job.unresolved > 0 then
    if job.state ~= "cancelled" and job.state ~= "uncertain" then job.state = "blocked" end
    return
  end
  for _, step in ipairs(job.steps) do
    if step.state ~= "done" then return end
  end
  if job.delivered >= job.output.count and job.state ~= "cancelled" then
    job.state = "done"
    job.owner, job.token, job.epoch = false, false, false
    job.untilAt, job.boot = false, false
    job.currentStep = false
  end
end

local function commit(s, tree, context)
  if not M.valid(tree, context.pose) then return fail("invalid", "craft state rejected") end
  local size = bytes(tree)
  if not size or size > budget(context) then return fail("capacity", "craft state does not fit") end
  if context.admit and context.admit(size) == false then return fail("capacity", "ledger refused the craft state") end
  s.wh2.craft = tree
  return nil
end

function M.maintain(s, now)
  if type(s) ~= "table" or type(s.wh2) ~= "table" or type(s.wh2.craft) ~= "table" then return false end
  if not int(now, 0, 9007199254740991) then return false end
  local tree = s.wh2.craft
  local changed = false
  for id, query in pairs(tree.queries) do
    if type(query) == "table" and int(query.untilAt, 0, 9007199254740991) and query.untilAt <= now then
      tree.queries[id] = nil
      changed = true
    end
  end
  for id, upload in pairs(tree.planUploads) do
    if type(upload) == "table" and int(upload.updatedAt, 0, 9007199254740991)
      and now - upload.updatedAt >= M.limits.idleMs then
      tree.planUploads[id] = nil
      changed = true
    end
  end
  for _, job in pairs(tree.jobs) do
    if type(job) == "table" and job.token ~= false and job.overdueAt == false
      and int(job.untilAt, 0, 9007199254740991) and job.untilAt <= now then
      job.overdueAt = now
      if job.state == "running" then job.state = "uncertain" end
      for _, step in ipairs(job.steps or {}) do
        if step.state == "running" then step.state = "uncertain" end
      end
      changed = true
    end
  end
  if changed then tree.revision = tree.revision + 1 end
  return changed
end

local function sameOutput(job, body)
  local output = body.output or {}
  return job.output.item == output.item and job.output.count == output.count
    and (job.output.nbt or false) == (output.nbt or false)
    and job.outputLocationId == (body.outputLocationId or false)
end

local function choicesEqual(a, b)
  local _, left = bytes(a or {})
  local _, right = bytes(b or {})
  return left == right
end

local function jobByKey(tree, key)
  for _, job in pairs(tree.jobs) do
    if job.key == key then return job end
  end
end

local function handleCreate(tree, sender, body, context)
  if not operator(context, sender) then return fail("forbidden", "operator required") end
  if not ident(body.key) or type(body.output) ~= "table" or not itemId(body.output.item)
    or not int(body.output.count, 1, 1000000) or not fingerprint(body.output.nbt or false) then
    return fail("invalid", "invalid craft request")
  end
  if body.outputLocationId ~= nil and body.outputLocationId ~= false and not ident(body.outputLocationId) then
    return fail("invalid", "invalid output location")
  end
  local choices = body.recipeChoices or {}
  if type(choices) ~= "table" then return fail("invalid", "invalid recipe choices") end
  local n = 0
  for item, recipe in pairs(choices) do
    n = n + 1
    if n > 32 or not itemId(item) or not itemId(recipe) then return fail("invalid", "invalid recipe choice") end
  end
  local existing = jobByKey(tree, body.key)
  if existing then
    if not sameOutput(existing, body) or not choicesEqual(existing.recipeChoices, choices) then
      return fail("invalid", "craft key conflict")
    end
    return reply(tree, { job = publicJob(existing) })
  end
  if tree.seq >= 2147483647 then return fail("invalid", "craft id space exhausted") end
  tree.seq = tree.seq + 1
  tree.revision = tree.revision + 1
  local job = {
    v = 1, id = "craft:" .. sender .. ":" .. tree.seq, key = body.key, requestedBy = sender,
    revision = 1, output = { item = body.output.item, count = body.output.count, nbt = body.output.nbt or false },
    recipeChoices = copy(choices), generation = false,
    outputLocationId = body.outputLocationId or false, state = "planning",
    owner = false, token = false, epoch = false, untilAt = false, overdueAt = false, boot = false,
    currentStep = false, steps = {}, missing = {}, unresolved = {}, progressSeq = 0,
    produced = 0, delivered = 0, error = false, events = {}, delivery = false,
  }
  tree.jobs[job.id] = job
  return reply(tree, { job = publicJob(job) })
end

local function dense(list)
  if type(list) ~= "table" then return false end
  local n = #list
  for k in pairs(list) do if not int(k, 1, n) then return false end end
  return true
end

local function handlePlan(tree, sender, body, context)
  if not hub(context, sender) then return fail("forbidden", "recipe hub required") end
  local job = tree.jobs[body.jobId or ""]
  if not job or not ident(body.jobId) then return fail("invalid", "unknown craft job") end
  if job.state ~= "planning" and job.state ~= "blocked" and job.state ~= "planned" then
    return fail("blocked", "job cannot accept a plan")
  end
  if job.owner ~= false or job.progressSeq ~= 0 then return fail("blocked", "job already started") end
  if not int(body.baseRevision, 0, 2147483647) or body.baseRevision ~= job.revision then
    return fail("stale_revision", "job revision changed")
  end
  if not ident(body.generation, 128) then return fail("invalid", "invalid provider generation") end
  if not int(body.offset, 0, M.limits.steps) or not dense(body.steps or {}) then
    return fail("invalid", "invalid plan fragment")
  end
  local upload = tree.planUploads[job.id]
  if upload and upload.generation ~= body.generation then
    return fail("stale_revision", "provider generation changed")
  end
  if upload and context.now - upload.updatedAt >= M.limits.idleMs then
    tree.planUploads[job.id] = nil
    return fail("upload_expired", "plan upload expired")
  end
  local incoming = body.steps or {}
  local accepted = upload and upload.offset or 0
  if body.offset == accepted and accepted + #incoming > M.limits.steps then
    tree.planUploads[job.id] = nil
    job.steps, job.missing = {}, {}
    job.unresolved = { { code = "plan_limit", item = job.output.item, recipeId = false, path = {}, detail = "steps" } }
    job.state, job.generation = "blocked", body.generation
    job.revision = job.revision + 1
    tree.revision = tree.revision + 1
    return reply(tree, { job = publicJob(job), nextOffset = 0, final = true })
  end
  for _, step in ipairs(incoming) do
    if not validStep(step, M.limits.steps) then return fail("invalid", "invalid plan step") end
  end
  local _, packed = bytes(incoming)
  if not packed then return fail("invalid", "plan fragment is unreadable") end
  if not upload then
    if body.offset ~= 0 then return fail("invalid", "plan offset gap") end
    upload = {
      v = 1, jobId = job.id, generation = body.generation, baseRevision = job.revision,
      offset = 0, steps = {}, chunks = {}, missing = {}, unresolved = {},
      updatedAt = context.now, bytes = 0,
    }
    tree.planUploads[job.id] = upload
  elseif upload.baseRevision ~= job.revision then
    return fail("stale_revision", "job revision changed")
  end
  if body.offset < upload.offset then
    if upload.chunks[body.offset] ~= packed then return fail("invalid", "plan fragment changed") end
    return reply(tree, { job = publicJob(job), nextOffset = upload.offset, final = false })
  end
  if body.offset ~= upload.offset then return fail("invalid", "plan offset gap") end
  if upload.offset + #incoming > M.limits.steps then
    tree.planUploads[job.id] = nil
    job.steps, job.missing = {}, {}
    job.unresolved = { { code = "plan_limit", item = job.output.item, recipeId = false, path = {}, detail = "steps" } }
    job.state, job.generation = "blocked", body.generation
    job.revision = job.revision + 1
    tree.revision = tree.revision + 1
    return reply(tree, { job = publicJob(job), nextOffset = 0, final = true })
  end
  for i, step in ipairs(incoming) do
    if step.id ~= body.offset + i then return fail("invalid", "plan step id gap") end
  end
  local staged = copy(upload.steps)
  for _, step in ipairs(incoming) do staged[#staged + 1] = copy(step) end
  local missing = body.final and (body.missing or {}) or upload.missing
  local unresolved = body.final and (body.unresolved or {}) or upload.unresolved
  if not dense(missing) or not dense(unresolved) then return fail("invalid", "invalid plan tail") end
  local size = bytes({ steps = staged, missing = missing, unresolved = unresolved })
  if not size or size > planBudget(context) or upload.bytes + #packed > planBudget(context) then
    tree.planUploads[job.id] = nil
    job.steps, job.missing = {}, {}
    job.unresolved = { { code = "plan_limit", item = job.output.item, recipeId = false, path = {}, detail = "bytes" } }
    job.state, job.generation = "blocked", body.generation
    job.revision = job.revision + 1
    tree.revision = tree.revision + 1
    return reply(tree, { job = publicJob(job), nextOffset = 0, final = true })
  end
  upload.chunks[body.offset] = packed
  upload.steps = staged
  upload.offset = #staged
  upload.bytes = upload.bytes + #packed
  upload.updatedAt = context.now
  upload.missing = copy(missing)
  upload.unresolved = copy(unresolved)
  if not body.final then
    return reply(tree, { job = publicJob(job), nextOffset = upload.offset, final = false })
  end
  for _, row in ipairs(missing) do if not validMissing(row) then return fail("invalid", "invalid shortage") end end
  for _, row in ipairs(unresolved) do
    if not validUnresolved(row) then return fail("invalid", "invalid unresolved row") end
  end
  for index, step in ipairs(staged) do
    if not validStep(step, #staged) or step.id ~= index then return fail("invalid", "invalid committed step") end
    if step.state ~= "pending" then return fail("invalid", "a new plan step starts pending") end
  end
  job.steps = staged
  job.missing = copy(missing)
  job.unresolved = copy(unresolved)
  job.generation = body.generation
  job.revision = job.revision + 1
  tree.revision = tree.revision + 1
  job.currentStep = job.steps[1] and job.steps[1].id or false
  if #job.missing > 0 or #job.unresolved > 0 then job.state = "blocked"
  else job.state = "planned" end
  tree.planUploads[job.id] = nil
  return reply(tree, { job = publicJob(job), nextOffset = upload.offset, final = true })
end

local function handleClaim(tree, sender, body, context)
  if not craftingOn(context) then return fail("disabled", "crafting is off") end
  local job = tree.jobs[body.jobId or ""]
  if not job then return fail("invalid", "unknown craft job") end
  if not (body.boot == false or body.boot == nil or ident(body.boot, 128)) then
    return fail("invalid", "invalid boot")
  end
  if job.owner ~= false and job.owner ~= sender then return fail("forbidden", "another worker owns this job") end
  if job.overdueAt ~= false then
    return fail("overdue", "reconcile the craft claim before new work")
  end
  if job.state ~= "planned" and not (job.state == "running" and job.owner == sender) then
    return fail("blocked", "job is not a complete plan")
  end
  if #job.missing > 0 or #job.unresolved > 0 then return fail("blocked", "plan has open requirements") end
  if job.owner == sender and job.token ~= false then
    job.untilAt = context.now + M.limits.claimMs
    return reply(tree, { job = publicJob(job), token = job.token, epoch = job.epoch, untilAt = job.untilAt })
  end
  tree.seq = tree.seq + 1
  tree.revision = tree.revision + 1
  job.revision = job.revision + 1
  job.owner = sender
  job.token = "claim:" .. sender .. ":" .. tree.seq
  job.epoch = context.epoch
  job.boot = body.boot or false
  job.untilAt = context.now + M.limits.claimMs
  job.overdueAt = false
  job.state = "running"
  if job.currentStep == false and job.steps[1] then job.currentStep = job.steps[1].id end
  return reply(tree, { job = publicJob(job), token = job.token, epoch = job.epoch, untilAt = job.untilAt })
end

local function claimMatches(job, body, sender)
  return job.owner == sender and job.token == body.token and job.epoch == body.epoch
    and (body.boot == nil or body.boot == job.boot)
end

local function observedOk(row)
  return type(row) == "table" and itemId(row.item) and int(row.count, 0, 1000000)
    and int(row.delivered, 0, 1000000) and fingerprint(row.nbt or false)
    and (row.locationId == false or row.locationId == nil or ident(row.locationId))
    and (row.stockRevision == nil or int(row.stockRevision, 0, 2147483647))
end

local function remember(job, body, packed)
  job.events[body.seq] = { eventId = body.eventId, body = packed }
end

local function applyObserved(job, step, body)
  local seen = {
    item = body.observed.item, count = body.observed.count, delivered = body.observed.delivered,
    nbt = body.observed.nbt or false, locationId = body.observed.locationId or false,
    stockRevision = body.observed.stockRevision or 0,
  }
  if step then
    step.observed = seen
    if STEP_STATES[body.state] then step.state = body.state end
  else
    job.delivery = seen
  end
  totals(job)
  if body.state == "running" and job.state ~= "done" and job.state ~= "cancelled" then
    job.state = "running"
  end
  if body.state == "uncertain" then job.state = "uncertain" end
  if body.state == "blocked" then job.state = "blocked" end
  finishIfDone(job)
  refreshStep(job)
end

local function progressBody(body)
  if not ident(body.eventId) or not int(body.seq, 1, 1000000) then return false end
  if body.stepId ~= false and not int(body.stepId, 1, M.limits.steps) then return false end
  if not STEP_STATES[body.state or ""] and body.state ~= nil then return false end
  return observedOk(body.observed)
end

local function handleProgress(tree, sender, body, context, reconcile)
  local job = tree.jobs[body.jobId or ""]
  if not job then return fail("invalid", "unknown craft job") end
  if job.overdueAt ~= false and not reconcile then return fail("overdue", "reconcile required") end
  if not claimMatches(job, body, sender) then return fail("forbidden", "craft claim rejected") end
  if not progressBody(body) then return fail("invalid", "invalid craft progress") end
  local step = false
  if body.stepId == false then
    if #job.steps ~= 0 then return fail("invalid", "step required") end
  else
    step = job.steps[body.stepId]
    if not step then return fail("invalid", "unknown craft step") end
  end
  local _, packed = bytes({
    eventId = body.eventId, seq = body.seq, stepId = body.stepId or false,
    state = body.state, observed = body.observed,
  })
  if not packed or #packed > 4096 then return fail("too_large", "progress event is too large") end
  local prior = job.events[body.seq]
  if prior then
    if prior.eventId == body.eventId and prior.body == packed then
      return reply(tree, { job = publicJob(job), duplicate = true })
    end
    return fail("invalid", "progress event changed")
  end
  if body.seq ~= job.progressSeq + 1 then return fail("invalid", "progress sequence gap") end
  for _, event in pairs(job.events) do
    if event.eventId == body.eventId then return fail("invalid", "progress event id reused") end
  end
  if step and type(step.observed) == "table" and not reconcile then
    if body.observed.item == step.observed.item and body.observed.count < step.observed.count then
      return fail("reconcile_required", "observed count decreased")
    end
    if body.observed.delivered < step.observed.delivered and body.observed.item == job.output.item then
      return fail("reconcile_required", "delivered count decreased")
    end
  end
  if not step and type(job.delivery) == "table" and not reconcile then
    if body.observed.count < job.delivery.count then
      return fail("reconcile_required", "observed count decreased")
    end
  end
  applyObserved(job, step, body)
  job.progressSeq = body.seq
  if reconcile then
    job.overdueAt = false
    job.untilAt = context.now + M.limits.claimMs
    if job.state ~= "done" and job.state ~= "cancelled" then job.state = "uncertain" end
    if step and step.state ~= "done" then step.state = body.state or "uncertain" end
  end
  remember(job, body, packed)
  job.revision = job.revision + 1
  tree.revision = tree.revision + 1
  finishIfDone(job)
  return reply(tree, { job = publicJob(job), duplicate = false })
end

local function handleCancel(tree, sender, body, context)
  if not operator(context, sender) then return fail("forbidden", "operator required") end
  local job = tree.jobs[body.jobId or ""]
  if not job then return fail("invalid", "unknown craft job") end
  if job.state == "cancelled" then return reply(tree, { job = publicJob(job) }) end
  if job.state == "done" then return fail("blocked", "finished craft cannot be cancelled") end
  job.state = "cancelled"
  job.owner, job.token, job.epoch = false, false, false
  job.untilAt, job.boot, job.overdueAt = false, false, false
  job.revision = job.revision + 1
  tree.revision = tree.revision + 1
  tree.planUploads[job.id] = nil
  return reply(tree, { job = publicJob(job) })
end

local function activeQueries(tree)
  local n = 0
  for _ in pairs(tree.queries) do n = n + 1 end
  return n
end

local function queryByKey(tree, key)
  for _, query in pairs(tree.queries) do
    if query.key == key then return query end
  end
end

local function handleQuery(tree, sender, body, context)
  if not ident(body.key) then return fail("invalid", "invalid recipe query") end
  local method = body.method
  if method ~= "getRecipesFor" and method ~= "getUsesOf" and method ~= "getRecipe"
    and method ~= "list" and method ~= "resolveTag" then
    return fail("invalid", "unknown recipe method")
  end
  if method ~= "list" and not itemId(body.id or "") then return fail("invalid", "invalid recipe id") end
  local page = body.page or 1
  local pageSize = body.pageSize or 20
  if not int(page, 1, 1000000) or not int(pageSize, 1, 100) then return fail("invalid", "invalid recipe page") end
  local existing = queryByKey(tree, body.key)
  if existing then
    if existing.owner ~= sender then return fail("forbidden", "recipe ticket is owned elsewhere") end
    return reply(tree, { ticket = existing.ticket, state = existing.state, query = {
      method = existing.method, id = existing.item, page = existing.page, pageSize = existing.pageSize,
    } })
  end
  if activeQueries(tree) >= M.limits.queries then return fail("busy", "recipe queue is full") end
  tree.seq = tree.seq + 1
  tree.revision = tree.revision + 1
  local query = {
    v = 1, ticket = "recipe:" .. sender .. ":" .. tree.seq, key = body.key, owner = sender,
    method = method, item = method == "list" and false or body.id, page = page, pageSize = pageSize,
    state = "pending", token = false, epoch = false, hub = false, boot = false,
    untilAt = context.now + M.limits.idleMs, offset = 0, generation = false, fragment = false,
  }
  tree.queries[query.ticket] = query
  return reply(tree, { ticket = query.ticket, state = query.state, query = {
    method = query.method, id = query.item, page = query.page, pageSize = query.pageSize,
  } })
end

local function touch(query, context)
  query.untilAt = context.now + M.limits.idleMs
end

local function handleQueryClaim(tree, sender, body, context)
  if not hub(context, sender) then return fail("forbidden", "recipe hub required") end
  local query = tree.queries[body.ticket or ""]
  if not query then return fail("upload_expired", "recipe ticket expired") end
  if query.hub ~= false and query.hub ~= sender then return fail("forbidden", "ticket is claimed") end
  if query.token == false then
    tree.seq = tree.seq + 1
    query.token = "recipe-claim:" .. tree.seq
    query.epoch = context.epoch
    query.hub = sender
    query.boot = body.boot or false
    query.state = "claimed"
    tree.revision = tree.revision + 1
  end
  touch(query, context)
  return reply(tree, {
    ticket = query.ticket, token = query.token, epoch = query.epoch, untilAt = query.untilAt,
    query = { method = query.method, id = query.item, page = query.page, pageSize = query.pageSize },
  })
end

local function handlePublish(tree, sender, body, context)
  if not hub(context, sender) then return fail("forbidden", "recipe hub required") end
  local query = tree.queries[body.ticket or ""]
  if not query then return fail("upload_expired", "recipe ticket expired") end
  if query.hub ~= sender or query.token ~= body.token or query.epoch ~= body.epoch then
    return fail("forbidden", "recipe claim rejected")
  end
  if body.boot ~= nil and body.boot ~= query.boot then return fail("forbidden", "hub boot changed") end
  if not ident(body.generation, 128) or body.encoding ~= "lua" or type(body.data) ~= "string" then
    return fail("invalid", "invalid recipe fragment")
  end
  if #body.data > M.limits.fragment then return fail("too_large", "recipe fragment exceeds 4096") end
  if not int(body.offset, 0, M.limits.result) or not int(body.nextOffset, 0, M.limits.result)
    or not int(body.totalBytes, 0, M.limits.result) then
    return fail("invalid", "invalid recipe offsets")
  end
  if body.totalBytes > M.limits.result then return fail("too_large", "recipe result exceeds 65536") end
  if body.offset ~= query.offset then return fail("invalid", "recipe offset mismatch") end
  if query.fragment ~= false then return fail("busy", "recipe fragment is still unread") end
  if query.generation ~= false and query.generation ~= body.generation then
    return fail("stale_revision", "recipe generation changed")
  end
  query.generation = body.generation
  query.fragment = {
    offset = body.offset, nextOffset = body.nextOffset, totalBytes = body.totalBytes,
    encoding = "lua", data = body.data, generation = body.generation,
  }
  query.state = "published"
  query.offset = body.nextOffset
  touch(query, context)
  tree.revision = tree.revision + 1
  return reply(tree, { ticket = query.ticket, nextOffset = query.offset })
end

local function handleRead(tree, sender, body)
  local query = tree.queries[body.ticket or ""]
  if not query then return fail("upload_expired", "recipe ticket expired") end
  if query.owner ~= sender then return fail("forbidden", "recipe ticket owner required") end
  if body.generation ~= nil and query.generation ~= false and body.generation ~= query.generation then
    return fail("stale_revision", "recipe generation changed")
  end
  return reply(tree, { ticket = query.ticket, fragment = query.fragment, generation = query.generation })
end

local function handleAdvance(tree, sender, body, context)
  local query = tree.queries[body.ticket or ""]
  if not query then return fail("upload_expired", "recipe ticket expired") end
  if query.owner ~= sender then return fail("forbidden", "recipe ticket owner required") end
  if query.fragment == false then return fail("invalid", "no recipe fragment") end
  if body.generation ~= query.generation or body.nextOffset ~= query.fragment.nextOffset then
    return fail("invalid", "recipe advance mismatch")
  end
  query.fragment = false
  if query.state == "published" then query.state = "claimed" end
  touch(query, context)
  tree.revision = tree.revision + 1
  return reply(tree, { ticket = query.ticket, nextOffset = query.offset })
end

local function handleRelease(tree, sender, body)
  local query = tree.queries[body.ticket or ""]
  if not query then return reply(tree, { ticket = body.ticket, released = true }) end
  if query.owner ~= sender then return fail("forbidden", "recipe ticket owner required") end
  tree.queries[query.ticket] = nil
  tree.revision = tree.revision + 1
  return reply(tree, { ticket = query.ticket, released = true })
end

local function handleGet(tree, sender, body, context)
  if body.revision ~= nil and body.revision ~= tree.revision then
    return fail("stale_revision", "craft revision changed")
  end
  local ids = {}
  for id in pairs(tree.jobs) do ids[#ids + 1] = id end
  table.sort(ids)
  if body.id ~= nil then
    local job = tree.jobs[body.id]
    if not job then return fail("invalid", "unknown craft job") end
    return reply(tree, { records = { publicJob(job) }, cursor = 0 })
  end
  local cursor = body.cursor or 0
  if not int(cursor, 0, #ids) then return fail("invalid", "invalid cursor") end
  local records, size = {}, 0
  local index = cursor
  while index < #ids and #records < M.limits.pageRecords do
    local row = publicJob(tree.jobs[ids[index + 1]])
    if row.owner ~= sender and not operator(context, sender) then row.token = false end
    local n = bytes(row)
    if not n then return fail("invalid", "unreadable craft job") end
    if #records > 0 and size + n > M.limits.page then break end
    if n > M.limits.page then return fail("too_large", "craft record exceeds a page") end
    records[#records + 1] = row
    size = size + n
    index = index + 1
  end
  local nextCursor = index >= #ids and 0 or index
  return reply(tree, { records = records, cursor = nextCursor })
end

function M.run(s, senderId, message, context)
  if not int(senderId, 0, 2147483647) then return fail("invalid", "invalid sender") end
  if type(message) ~= "table" or type(message.body) ~= "table" then return fail("invalid", "invalid craft message") end
  if not enabled(context) then return fail("disabled", "wh2 craft is off") end
  if not nowOf(context) then return fail("invalid", "invalid server clock") end
  s.wh2 = s.wh2 or {}
  if s.wh2.craft == nil then s.wh2.craft = M.empty() end
  if not M.valid(s.wh2.craft, context.pose) then return fail("invalid", "craft state is unreadable") end
  M.maintain(s, context.now)
  local tree = copy(s.wh2.craft)
  if not tree then return fail("invalid", "craft state is cyclic") end
  local op, body = message.op, message.body
  local result
  if op == "wh2-get" then
    if body.topic ~= "crafts" then return fail("invalid", "unexpected topic") end
    result = handleGet(tree, senderId, body, context)
  elseif op == "wh2-craft" then
    if body.action == "create" then result = handleCreate(tree, senderId, body, context)
    elseif body.action == "plan" then result = handlePlan(tree, senderId, body, context)
    elseif body.action == "claim" then result = handleClaim(tree, senderId, body, context)
    elseif body.action == "progress" then result = handleProgress(tree, senderId, body, context, false)
    elseif body.action == "reconcile" then result = handleProgress(tree, senderId, body, context, true)
    elseif body.action == "cancel" then result = handleCancel(tree, senderId, body, context)
    else return fail("invalid", "unknown craft action") end
  elseif op == "wh2-recipe" then
    if body.action == "query" then result = handleQuery(tree, senderId, body, context)
    elseif body.action == "claim" then result = handleQueryClaim(tree, senderId, body, context)
    elseif body.action == "publish" then result = handlePublish(tree, senderId, body, context)
    elseif body.action == "read" then result = handleRead(tree, senderId, body, context)
    elseif body.action == "advance" then result = handleAdvance(tree, senderId, body, context)
    elseif body.action == "release" then result = handleRelease(tree, senderId, body, context)
    else return fail("invalid", "unknown recipe action") end
  else
    return fail("unavailable", "craft does not own this operation")
  end
  if not result.ok then return result end
  local refused = commit(s, tree, context)
  if refused then return refused end
  return result
end

return M
