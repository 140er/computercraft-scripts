return {
  name = "home-frame",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "fresh" },
    { t = "choose", id = "miner" },
    { t = "choose", id = "here" },
    { t = "io", op = "clock", ok = true, value = 1792500000000 },
    { t = "choose", id = 3 },
    { t = "io", op = "gps", ok = true, value = { x = 5, y = 6, z = 7 } },
  },
}
