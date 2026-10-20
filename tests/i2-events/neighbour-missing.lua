return {
  name = "neighbour-missing",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "neighbour" },
    { t = "io", op = "scan", ok = true, value = { sides = {} } },
    { t = "choose", id = "retry" },
    { t = "io", op = "scan", ok = true, value = { sides = { front = { id = 17, kind = "computer" } } } },
  },
}
