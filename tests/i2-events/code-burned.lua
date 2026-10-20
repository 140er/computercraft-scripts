return {
  name = "code-burned",
  machine = { kind = "turtle", id = 31, advanced = true, label = false, sides = {} },
  events = {
    { t = "io", op = "scan", ok = true, value = { kind = "turtle", id = 31, advanced = true, sides = {} } },
    { t = "choose", id = "code" },
    { t = "text", s = "short" },
    { t = "text", s = "c:4:1 K7Q2M9XDPT4H6N8R" },
    { t = "io", op = "rpc", ok = false, error = { code = "code_burned", detail = "code_burned" } },
    { t = "choose", id = "retry" },
  },
}
