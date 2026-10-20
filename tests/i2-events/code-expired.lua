return {
  name = "code-expired",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "code" },
    { t = "text", s = "short" },
    { t = "text", s = "c:4:1 K7Q2M9XDPT4H6N8R" },
    { t = "io", op = "rpc", ok = false, error = { code = "code_expired", detail = "code_expired" } },
    { t = "choose", id = "retry" },
  },
}
