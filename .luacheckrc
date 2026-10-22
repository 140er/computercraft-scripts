std = "lua52"
-- CC API tables are read-only globals; SO is assigned by the server boot loader.
read_globals = {
  "term", "fs", "peripheral", "rednet", "turtle", "textutils", "colors", "colours",
  "http", "sleep", "read", "write", "printError", "shell", "parallel", "keys",
  "settings", "gps", "vector", "window", "paintutils", "redstone", "rs", "disk",
  "commands", "multishell", "help", "pocket", "bit", "unpack",
  "os.epoch", "os.getComputerID", "os.getComputerLabel", "os.setComputerLabel",
  "os.pullEvent", "os.pullEventRaw", "os.queueEvent", "os.startTimer", "os.cancelTimer",
  "os.reboot", "os.shutdown", "os.version", "os.loadAPI", "os.unloadAPI",
  "os.startAlarm", "os.cancelAlarm", "os.day", "os.run", "os.sleep",
  "os.computerID", "os.computerLabel", "_HOST"
}
globals = { "SO" }
-- Keep global and unused-variable diagnostics; omit unrelated style checks.
ignore = { "4..", "5..", "6.." }
max_line_length = false

-- Boot wrappers replace these host functions in their own program environment.
files = {
  ["so-pair.lua"] = { globals = { "SO", "package", "require" } },
  ["so-server.lua"] = { globals = { "SO", "print" } },
}
