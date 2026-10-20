-- Stub for B1 journal entries.
-- H4b2 reads a done entry to build a segment. It does not store or replay the journal.

local M = { v = 1 }

M.fields = { "v", "seq", "lease", "at", "frame", "kind", "phase", "from", "to", "name" }

function M.isEntry(entry)
  return type(entry) == "table" and entry.v == 1
    and type(entry.kind) == "string" and type(entry.phase) == "string"
end

function M.isDone(entry)
  return M.isEntry(entry) and entry.phase == "done"
end

return M
