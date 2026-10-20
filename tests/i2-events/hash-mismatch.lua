return {
  name = "hash-mismatch",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "fresh" },
    { t = "choose", id = "miner" },
    { t = "choose", id = "f3" },
    { t = "text", s = "10" },
    { t = "text", s = "64" },
    { t = "text", s = "20" },
    { t = "choose", id = 0 },
    { t = "choose", id = "go" },
    { t = "io", op = "apply_bundle", ok = false, error = { code = "hash_mismatch", detail = "hash_mismatch" } },
    { t = "choose", id = "retry" },
  },
}
