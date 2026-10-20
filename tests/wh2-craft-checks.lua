-- Behavior checks for wh2 craft. Host and CraftOS both call this.

return function(test, Craft, Recipes, Worker)
  local function assertEq(actual, expected, message)
    if actual ~= expected then
      error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual), 0)
    end
  end

  local function ctx(now, extra)
    local context = {
      now = now or 10000, epoch = 3,
      config = { enabled = true, operators = { ["17"] = true }, recipeHubId = 5 },
      settings = { crafting = true },
    }
    for key, value in pairs(extra or {}) do context[key] = value end
    return context
  end

  local function call(state, sender, op, body, context)
    return Craft.run(state, sender, { op = op, body = body }, context or ctx())
  end

  local function step(id, item, recipe, needs)
    return {
      id = id, recipeId = recipe or ("minecraft:" .. item:match(":(.+)$")),
      type = "minecraft:smelting", batches = 1, machineLocationId = false,
      needs = needs or {}, state = "pending", outputItem = item, pattern = false,
      ingredients = {
        { item = "minecraft:sand", nbt = false, perBatch = 1, orderKey = false, line = false },
      },
    }
  end

  local function findStep(steps, item)
    for _, row in ipairs(steps) do
      if row.outputItem == item then return row end
    end
  end

  test("wh2 craft stays disabled until the server flag is on", function()
    local state = {}
    local result = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:one",
      output = { item = "minecraft:stick", count = 1 },
    }, ctx(10000, { config = { enabled = false, operators = { ["17"] = true }, recipeHubId = 5 } }))
    assertEq(result.ok, false)
    assertEq(result.code, "disabled")
    assertEq(state.wh2, nil)
    assertEq(Craft.limits.jobs, 98304)
    assertEq(Craft.limits.plan, 65536)
    assertEq(Craft.limits.steps, 128)
    assertEq(Craft.limits.queries, 4)
    assertEq(Craft.limits.fragment, 4096)
    assertEq(Craft.limits.idleMs, 30000)
    assertEq(Craft.limits.claimMs, 120000)
  end)

  test("create is idempotent for operators and rejects everyone else", function()
    local state = { wh2 = { layout = { sentinel = true } } }
    local body = {
      action = "create", key = "board:17:request9",
      output = { item = "minecraft:glass_pane", count = 16 },
      outputLocationId = "warehouse-out", recipeChoices = {},
    }
    local denied = call(state, 9, "wh2-craft", body)
    assertEq(denied.code, "forbidden")
    local created = call(state, 17, "wh2-craft", body)
    assertEq(created.ok, true)
    assertEq(created.job.state, "planning")
    assertEq(created.job.id, "craft:17:1")
    assertEq(state.wh2.layout.sentinel, true)
    local again = call(state, 17, "wh2-craft", body)
    assertEq(again.job.id, created.job.id)
    assertEq(again.job.revision, created.job.revision)
    body.output = { item = "minecraft:glass_pane", count = 32 }
    local conflict = call(state, 17, "wh2-craft", body)
    assertEq(conflict.code, "invalid")
    assertEq(Craft.valid(state.wh2.craft, function() return true end), true)
  end)

  test("plans upload in pages, retry, and stop at the step and byte caps", function()
    local state = {}
    local created = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:plan",
      output = { item = "minecraft:glass_pane", count = 16 },
      outputLocationId = "warehouse-out",
    }).job
    local first = step(1, "minecraft:glass")
    local partial = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = { first }, final = false,
    })
    assertEq(partial.ok, true)
    assertEq(partial.final, false)
    assertEq(partial.nextOffset, 1)
    local retry = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = { first }, final = false,
    })
    assertEq(retry.nextOffset, 1)
    local changed = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:9:other", offset = 1, steps = { step(2, "minecraft:glass_pane", "minecraft:glass_pane", { 1 }) },
      final = true,
    })
    assertEq(changed.code, "stale_revision")
    local gap = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:5:boot:cat", offset = 2, steps = {}, final = true,
    })
    assertEq(gap.code, "invalid")
    local done = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:5:boot:cat", offset = 1,
      steps = { step(2, "minecraft:glass_pane", "minecraft:glass_pane", { 1 }) },
      missing = {}, unresolved = {}, final = true,
    })
    assertEq(done.job.state, "planned")
    assertEq(#done.job.steps, 2)
    local stranger = call(state, 17, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = done.job.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = {}, final = true,
    })
    assertEq(stranger.code, "forbidden")

    local limited = {}
    local job = call(limited, 17, "wh2-craft", {
      action = "create", key = "board:17:cap",
      output = { item = "minecraft:stone", count = 1 },
    }).job
    local many = {}
    for id = 1, 129 do many[id] = { id = id } end
    local capped = call(limited, 5, "wh2-craft", {
      action = "plan", jobId = job.id, baseRevision = job.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = many, final = true,
    })
    assertEq(capped.job.state, "blocked")
    assertEq(#capped.job.steps, 0)
    assertEq(capped.job.unresolved[1].code, "plan_limit")
    assertEq(capped.job.unresolved[1].detail, "steps")

    local tight = {}
    local small = call(tight, 17, "wh2-craft", {
      action = "create", key = "board:17:bytes",
      output = { item = "minecraft:stone", count = 1 },
    }).job
    local over = call(tight, 5, "wh2-craft", {
      action = "plan", jobId = small.id, baseRevision = small.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = { step(1, "minecraft:stone") },
      final = true,
    }, ctx(10000, { planBudget = 40 }))
    assertEq(over.job.unresolved[1].code, "plan_limit")
    assertEq(over.job.unresolved[1].detail, "bytes")
    assertEq(#over.job.steps, 0)
  end)

  test("claims, progress, reconcile, expiry and cancel keep observed totals", function()
    local state = {}
    local created = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:panes",
      output = { item = "minecraft:glass_pane", count = 16 },
      outputLocationId = "warehouse-out",
    }).job
    local uploaded = call(state, 5, "wh2-craft", {
      action = "plan", jobId = created.id, baseRevision = created.revision,
      generation = "hub:5:boot:cat", offset = 0, final = true,
      steps = {
        step(1, "minecraft:glass"),
        step(2, "minecraft:glass_pane", "minecraft:glass_pane", { 1 }),
      },
    }).job
    assertEq(uploaded.state, "planned")
    local off = call(state, 21, "wh2-craft", { action = "claim", jobId = uploaded.id, boot = "boot:21" },
      ctx(10000, { settings = { crafting = false } }))
    assertEq(off.code, "disabled")
    local missing = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:short",
      output = { item = "minecraft:glass_pane", count = 16 },
    }).job
    local blocked = call(state, 5, "wh2-craft", {
      action = "plan", jobId = missing.id, baseRevision = missing.revision,
      generation = "hub:5:boot:cat", offset = 0, final = true,
      steps = { step(1, "minecraft:glass") },
      missing = { { item = "minecraft:red_dye", count = 1, nbt = false } },
    }).job
    assertEq(blocked.state, "blocked")
    assertEq(call(state, 21, "wh2-craft", { action = "claim", jobId = blocked.id }).code, "blocked")

    local claim = call(state, 21, "wh2-craft", { action = "claim", jobId = uploaded.id, boot = "boot:21" })
    assertEq(claim.ok, true)
    assertEq(claim.epoch, 3)
    local other = call(state, 22, "wh2-craft", { action = "claim", jobId = uploaded.id, boot = "boot:22" })
    assertEq(other.code, "forbidden")
    local again = call(state, 21, "wh2-craft", { action = "claim", jobId = uploaded.id, boot = "boot:21" })
    assertEq(again.token, claim.token)

    local function progress(seq, stepId, item, count, delivered, mark, action)
      return call(state, 21, "wh2-craft", {
        action = action or "progress", jobId = uploaded.id, token = claim.token, epoch = claim.epoch,
        boot = "boot:21", eventId = "cp:21:" .. seq, seq = seq, stepId = stepId, state = mark or "running",
        observed = { locationId = "furnace-1", item = item, count = count, delivered = delivered, stockRevision = 8 },
      })
    end
    local glass = progress(1, 1, "minecraft:glass", 6, 0)
    assertEq(glass.job.produced, 0)
    assertEq(glass.job.delivered, 0)
    local repeatGlass = progress(1, 1, "minecraft:glass", 6, 0)
    assertEq(repeatGlass.duplicate, true)
    assertEq(repeatGlass.job.produced, 0)
    local changed = progress(1, 1, "minecraft:glass", 7, 0)
    assertEq(changed.code, "invalid")
    assertEq(state.wh2.craft.jobs[uploaded.id].produced, 0)
    local gap = progress(3, 2, "minecraft:glass_pane", 16, 16, "done")
    assertEq(gap.code, "invalid")
    local lower = progress(2, 1, "minecraft:glass", 5, 0)
    assertEq(lower.code, "reconcile_required")
    assertEq(state.wh2.craft.jobs[uploaded.id].steps[1].observed.count, 6)
    local fixed = progress(2, 1, "minecraft:glass", 4, 0, "uncertain", "reconcile")
    assertEq(fixed.ok, true)
    assertEq(fixed.job.steps[1].observed.count, 4)
    assertEq(fixed.job.state, "uncertain")
    local panes = progress(3, 2, "minecraft:glass_pane", 16, 16, "done")
    assertEq(panes.job.produced, 16)
    assertEq(panes.job.delivered, 16)
    local glassDone = progress(4, 1, "minecraft:glass", 4, 0, "done")
    assertEq(glassDone.job.state, "done")
    assertEq(glassDone.job.token, false)
    assertEq(glassDone.job.produced, 16)

    local fresh = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:expire",
      output = { item = "minecraft:glass", count = 1 },
    }).job
    fresh = call(state, 5, "wh2-craft", {
      action = "plan", jobId = fresh.id, baseRevision = fresh.revision,
      generation = "hub:5:boot:cat", offset = 0, steps = { step(1, "minecraft:glass") }, final = true,
    }).job
    local held = call(state, 21, "wh2-craft", { action = "claim", jobId = fresh.id, boot = "boot:21" }, ctx(5000))
    local saw = call(state, 21, "wh2-craft", {
      action = "progress", jobId = fresh.id, token = held.token, epoch = held.epoch, boot = "boot:21",
      eventId = "cp:21:9", seq = 1, stepId = 1, state = "running",
      observed = { item = "minecraft:glass", count = 1, delivered = 0, locationId = false, stockRevision = 1 },
    }, ctx(5000))
    assertEq(saw.job.produced, 1)
    local late = call(state, 21, "wh2-craft", {
      action = "progress", jobId = fresh.id, token = held.token, epoch = held.epoch, boot = "boot:21",
      eventId = "cp:21:10", seq = 2, stepId = 1, state = "running",
      observed = { item = "minecraft:glass", count = 1, delivered = 0, locationId = false, stockRevision = 1 },
    }, ctx(5000 + 120000))
    assertEq(late.code, "overdue")
    assertEq(state.wh2.craft.jobs[fresh.id].produced, 1)
    local recovered = call(state, 21, "wh2-craft", {
      action = "reconcile", jobId = fresh.id, token = held.token, epoch = held.epoch, boot = "boot:21",
      eventId = "cp:21:10", seq = 2, stepId = 1, state = "uncertain",
      observed = { item = "minecraft:glass", count = 1, delivered = 0, locationId = false, stockRevision = 1 },
    }, ctx(5000 + 120000))
    assertEq(recovered.ok, true)
    assertEq(recovered.job.produced, 1)
    local cancelled = call(state, 17, "wh2-craft", { action = "cancel", jobId = fresh.id })
    assertEq(cancelled.job.state, "cancelled")
    assertEq(cancelled.job.produced, 1)
    assertEq(call(state, 17, "wh2-craft", { action = "cancel", jobId = fresh.id }).job.state, "cancelled")
  end)

  test("recipe tickets stay bounded and expire without touching jobs", function()
    local state = {}
    local job = call(state, 17, "wh2-craft", {
      action = "create", key = "board:17:queue",
      output = { item = "minecraft:glass", count = 1 },
    }).job
    local tickets = {}
    for n = 1, 4 do
      local result = call(state, 17, "wh2-recipe", {
        action = "query", key = "board:17:lookup" .. n, method = "getRecipesFor",
        id = "minecraft:glass", page = 1, pageSize = 20,
      })
      assertEq(result.ok, true)
      tickets[n] = result.ticket
    end
    local full = call(state, 17, "wh2-recipe", {
      action = "query", key = "board:17:lookup9", method = "getRecipesFor", id = "minecraft:glass",
    })
    assertEq(full.code, "busy")
    local same = call(state, 17, "wh2-recipe", {
      action = "query", key = "board:17:lookup1", method = "getRecipesFor", id = "minecraft:glass",
    })
    assertEq(same.ticket, tickets[1])
    assertEq(call(state, 9, "wh2-recipe", { action = "claim", ticket = tickets[1] }).code, "forbidden")
    local claimed = call(state, 5, "wh2-recipe", { action = "claim", ticket = tickets[1], boot = "hub:5" })
    assertEq(claimed.epoch, 3)
    local data = "return {id='minecraft:glass'}"
    local published = call(state, 5, "wh2-recipe", {
      action = "publish", ticket = tickets[1], token = claimed.token, epoch = claimed.epoch,
      boot = "hub:5", generation = "hub:5:boot:cat", offset = 0, nextOffset = #data,
      totalBytes = #data, encoding = "lua", data = data,
    })
    assertEq(published.ok, true)
    assertEq(call(state, 18, "wh2-recipe", { action = "read", ticket = tickets[1] }).code, "forbidden")
    local read = call(state, 17, "wh2-recipe", { action = "read", ticket = tickets[1] })
    assertEq(read.fragment.data, data)
    local advanced = call(state, 17, "wh2-recipe", {
      action = "advance", ticket = tickets[1], generation = "hub:5:boot:cat", nextOffset = #data,
    })
    assertEq(advanced.ok, true)
    assertEq(call(state, 5, "wh2-recipe", {
      action = "publish", ticket = tickets[1], token = "nope", epoch = claimed.epoch,
      generation = "hub:5:boot:cat", offset = #data, nextOffset = #data, totalBytes = #data,
      encoding = "lua", data = "x",
    }).code, "forbidden")
    local huge = string.rep("a", 4097)
    assertEq(call(state, 5, "wh2-recipe", {
      action = "publish", ticket = tickets[1], token = claimed.token, epoch = claimed.epoch,
      boot = "hub:5", generation = "hub:5:boot:cat", offset = #data, nextOffset = #data + #huge,
      totalBytes = #data + #huge, encoding = "lua", data = huge,
    }).code, "too_large")
    assertEq(call(state, 17, "wh2-recipe", { action = "release", ticket = tickets[1] }).released, true)
    local produced = state.wh2.craft.jobs[job.id].produced
    local expired = call(state, 17, "wh2-recipe", { action = "read", ticket = tickets[2] }, ctx(10000 + 30000))
    assertEq(expired.code, "upload_expired")
    assertEq(state.wh2.craft.jobs[job.id].produced, produced)
    local page = call(state, 9, "wh2-get", { topic = "crafts", cursor = 0 })
    assertEq(page.records[1].id, job.id)
    assertEq(page.records[1].token, false)
    local malformed = call(state, 17, "wh2-craft", { action = "nope" })
    assertEq(malformed.code, "invalid")
    for _, junk in ipairs({ { action = "create" }, { action = "progress", jobId = 1 }, { action = "query" } }) do
      local result = Craft.run(state, 17, { op = "wh2-craft", body = junk }, ctx())
      assertEq(result.ok, false)
    end
  end)

  test("the planner is deterministic and reports shortages, cycles and tags", function()
    local function recipe(id, typeName, inputs, output, count, chance, pattern)
      return {
        id = id, type = typeName, inputs = inputs,
        outputs = { { item = output, count = count or 1, chance = chance or 1 } },
        pattern = pattern or false,
      }
    end
    local catalog = {
      generation = "hub:5:boot:cat",
      tags = { ["minecraft:planks"] = { "minecraft:birch_planks", "minecraft:oak_planks" } },
      recipes = {
        ["minecraft:glass"] = recipe("minecraft:glass", "minecraft:smelting",
          { { count = 1, item = "minecraft:sand" } }, "minecraft:glass"),
        ["minecraft:red_stained_glass"] = recipe("minecraft:red_stained_glass", "minecraft:crafting", {
          { count = 8, item = "minecraft:glass" },
          { count = 1, item = "minecraft:red_dye" },
        }, "minecraft:red_stained_glass", 8),
        ["minecraft:red_stained_glass_pane"] = recipe("minecraft:red_stained_glass_pane", "minecraft:crafting",
          { { count = 6, item = "minecraft:red_stained_glass" } }, "minecraft:red_stained_glass_pane", 16),
        ["minecraft:a_glass"] = recipe("minecraft:a_glass", "minecraft:smelting",
          { { count = 1, item = "minecraft:sand" } }, "minecraft:choice_glass"),
        ["minecraft:b_glass"] = recipe("minecraft:b_glass", "minecraft:smelting",
          { { count = 2, item = "minecraft:sand" } }, "minecraft:choice_glass"),
        ["minecraft:oak_planks"] = recipe("minecraft:oak_planks", "minecraft:crafting",
          { { count = 1, item = "minecraft:oak_log" } }, "minecraft:oak_planks", 4),
        ["minecraft:stick"] = recipe("minecraft:stick", "minecraft:crafting",
          { { count = 2, tag = "minecraft:planks" } }, "minecraft:stick", 4),
        ["minecraft:loop_a"] = recipe("minecraft:loop_a", "minecraft:crafting",
          { { count = 1, item = "minecraft:loop_b" } }, "minecraft:loop_a"),
        ["minecraft:loop_b"] = recipe("minecraft:loop_b", "minecraft:crafting",
          { { count = 1, item = "minecraft:loop_a" } }, "minecraft:loop_b"),
        ["minecraft:lucky"] = recipe("minecraft:lucky", "minecraft:smelting",
          { { count = 1, item = "minecraft:gravel" } }, "minecraft:flint", 1, 0.1),
        ["create:mix"] = recipe("create:mix", "create:mixing",
          { { count = 1, item = "minecraft:sand" } }, "minecraft:mixed"),
      },
    }
    local function run(output, count, stock, choices, adapters)
      return Recipes.plan({
        output = { item = output, count = count, nbt = false },
        catalog = catalog, stock = stock or {}, recipeChoices = choices or {}, adapters = adapters,
      })
    end
    local panes = run("minecraft:red_stained_glass_pane", 32, { ["minecraft:sand"] = 1000 })
    assertEq(#panes.unresolved, 0)
    assertEq(panes.missing[1].item, "minecraft:red_dye")
    assertEq(panes.missing[1].count, 2)
    assertEq(findStep(panes.steps, "minecraft:glass").batches, 16)
    local again = run("minecraft:red_stained_glass_pane", 32, { ["minecraft:sand"] = 1000 })
    assertEq(#again.steps, #panes.steps)
    assertEq(again.steps[1].recipeId, panes.steps[1].recipeId)
    assertEq(again.missing[1].count, panes.missing[1].count)

    local picked = run("minecraft:choice_glass", 1, { ["minecraft:sand"] = 5 })
    assertEq(findStep(picked.steps, "minecraft:choice_glass").recipeId, "minecraft:a_glass")
    local chosen = run("minecraft:choice_glass", 1, { ["minecraft:sand"] = 5 },
      { ["minecraft:choice_glass"] = "minecraft:b_glass" })
    assertEq(findStep(chosen.steps, "minecraft:choice_glass").recipeId, "minecraft:b_glass")

    local oak = run("minecraft:stick", 4, { ["minecraft:oak_planks"] = 10, ["minecraft:birch_planks"] = 10 })
    assertEq(findStep(oak.steps, "minecraft:stick").ingredients[1].item, "minecraft:birch_planks")
    local onlyOak = run("minecraft:stick", 4, { ["minecraft:oak_planks"] = 10 })
    assertEq(findStep(onlyOak.steps, "minecraft:stick").ingredients[1].item, "minecraft:oak_planks")
    local birch = run("minecraft:stick", 4, { ["minecraft:birch_planks"] = 10 })
    assertEq(findStep(birch.steps, "minecraft:stick").ingredients[1].item, "minecraft:birch_planks")
    local made = run("minecraft:stick", 4, {})
    assertEq(findStep(made.steps, "minecraft:oak_planks") ~= nil, true)

    local emptyTags = {
      generation = "hub:5:boot:cat", tags = { ["minecraft:planks"] = {} },
      recipes = { ["minecraft:stick"] = catalog.recipes["minecraft:stick"] },
    }
    local empty = Recipes.plan({
      output = { item = "minecraft:stick", count = 4 }, catalog = emptyTags, stock = {},
    })
    assertEq(empty.unresolved[1].code, "empty_tag")
    local incomplete = Recipes.plan({
      output = { item = "minecraft:stick", count = 4 },
      catalog = {
        generation = "hub:5:boot:cat", tags = {},
        recipes = { ["minecraft:stick"] = {
          id = "minecraft:stick", type = "minecraft:crafting",
          inputs = { { count = 2, tag = "minecraft:planks", more = true } },
          outputs = { { item = "minecraft:stick", count = 4, chance = 1 } },
        } },
      },
      stock = {},
    })
    assertEq(incomplete.unresolved[1].code, "alternatives_incomplete")
    assertEq(#incomplete.missing, 0)

    local cycle = run("minecraft:loop_a", 1, {})
    assertEq(cycle.unresolved[1].code, "cycle")
    assertEq(cycle.unresolved[1].path[1].kind, "item")
    local chance = run("minecraft:flint", 1, { ["minecraft:gravel"] = 8 })
    assertEq(chance.unresolved[1].code, "chance_only")
    assertEq(#chance.steps, 0)
    local adapter = run("minecraft:mixed", 1, { ["minecraft:sand"] = 4 })
    assertEq(adapter.unresolved[1].code, "adapter_unsupported")
    local fueled = run("minecraft:glass", 6, { ["minecraft:sand"] = 10 }, {}, {
      ["minecraft:smelting"] = { fuelPerBatch = { item = "minecraft:coal", count = 1 } },
      ["minecraft:crafting"] = true,
    })
    assertEq(findStep(fueled.steps, "minecraft:glass").batches, 6)
    local coal = false
    for _, row in ipairs(fueled.missing) do if row.item == "minecraft:coal" then coal = row.count end end
    assertEq(coal, 6)

    local dumped, err = Recipes.importDump({
      tags = { ["minecraft:planks"] = { "minecraft:oak_planks" } },
      ["minecraft:glass"] = {
        n = "Furnace", s = "minecraft:smelting",
        l = { { "minecraft:sand", 1 } }, o = { { "minecraft:glass", 1, 1 } },
      },
    }, "abc12345")
    assertEq(err, nil)
    assertEq(dumped.recipes["minecraft:glass"].type, "minecraft:smelting")
    assertEq(dumped.recipes["minecraft:glass"].inputs[1].item, "minecraft:sand")
    assertEq(dumped.hash, "abc12345")

    local cache = Recipes.cache(80)
    assertEq(cache.put("a", { item = "minecraft:sand" }), true)
    assertEq(cache.put("b", { item = "minecraft:glass" }), true)
    assertEq(cache.bytes() <= 80, true)
    local lines = {}
    local service = Recipes.open({
      width = 39,
      peripheral = { getRecipesFor = function(id) return { { id = id } } end },
      draw = function(shown) lines = shown end,
    })
    assertEq(service.handle({ t = "text", s = "minecraft:glass" }), true)
    local tick = service.tick()
    assertEq(tick.ok, true)
    assertEq(#tick.fragments[1].data <= 4096, true)
    local drawn = service.draw()
    assertEq(#drawn <= 13, true)
    assertEq(#drawn[1] <= 39, true)
    local down = Recipes.open({}).tick()
    assertEq(down.code, "recipe_unavailable")
  end)

  test("the worker journals one event id and will not move stock without layout", function()
    local saved
    local journal = Worker.journal({
      read = function() return saved end,
      write = function(value) saved = value end,
    }, 21)
    local first = journal.begin({
      seq = 1, stepId = 1, state = "running", jobId = "craft:17:1",
      token = "claim:21:1", epoch = 3, observed = { item = "minecraft:glass", count = 1 },
    })
    local second = journal.begin({ seq = 2, stepId = 1, state = "running", observed = { count = 9 } })
    assertEq(second.eventId, first.eventId)
    assertEq(second.seq, 1)
    assertEq(journal.ack(1), true)
    assertEq(journal.pending(), false)
    local third = journal.begin({
      seq = 2, stepId = 1, state = "done", jobId = "craft:17:1",
      token = "claim:21:1", epoch = 3, observed = { item = "minecraft:glass", count = 1 },
    })
    assertEq(third.eventId == first.eventId, false)
    local reserved, why = Worker.prepareMove({ id = 1 })
    assertEq(reserved, false)
    assertEq(why, "layout_unavailable")
    assertEq(Worker.classify("minecraft:sand").route, "unknown")
    local slots = {}
    local function detail(slot) return slots[slot] end
    slots[4] = { item = "minecraft:stick", count = 1 }
    local ready, reason = Worker.gridReady(detail, { [1] = "minecraft:oak_planks" })
    assertEq(ready, false)
    assertEq(reason, "slot_occupied")
    slots[4] = nil
    slots[1] = { item = "minecraft:oak_planks", count = 1 }
    assertEq(Worker.gridReady(detail, { [1] = "minecraft:oak_planks" }), true)
    local crafted = false
    local ok = Worker.placeAndCraft({
      getItemDetail = detail,
      craft = function() crafted = true return true end,
    }, { [1] = "minecraft:oak_planks" }, 1)
    assertEq(ok, true)
    assertEq(crafted, true)
    local dep = Worker.dependency()
    assertEq(dep.register().module, "wh2-craft")
    assertEq(dep.register().topic, "crafts")
  end)

  test("factory keeps the legacy program unless wh2.enabled is true", function()
    local text
    if type(fs) == "table" and fs.open then
      local handle = fs.open("factory.lua", "r")
      if handle then text = handle.readAll() handle.close() end
    end
    if not text and type(io) == "table" and io.open then
      local handle = io.open("factory.lua", "rb")
      if handle then text = handle:read("*a") handle:close() end
    end
    assert(text, "factory.lua unreadable")
    assert(text:find("cfg.wh2.enabled == true", 1, true), "craft flag missing")
    assert(text:find("factory build", 1, true), "legacy factory build removed")
    assert(text:find('dofile("craft.lua")', 1, true), "factory adapter missing")
  end)
end
