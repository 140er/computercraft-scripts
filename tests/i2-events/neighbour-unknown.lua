return {
  name = "neighbour-unknown",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "neighbour" },
    { t = "io", op = "scan", ok = true, value = { sides = { front = { id = 17, kind = "computer" } } } },
    { t = "choose", id = "front" },
    { t = "io", op = "rpc", ok = false, error = { code = "neighbour_unknown", detail = "not paired" } },
    { t = "choose", id = "help" },
    { t = "back" },
  },
}
