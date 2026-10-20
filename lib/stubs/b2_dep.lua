local M = {}

local DECISIONS = { wait = true, retry = true, reroute = true, ["return"] = true, skip = true }

local function integer(n)
  return type(n) == "number" and n == n and n % 1 == 0
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function validEntry(entry)
  if type(entry) ~= "table" or entry.v ~= 1 then return "bad entry" end
  if entry.kind ~= "problem" then return "bad entry" end
  if entry.phase ~= "intent" and entry.phase ~= "done" then return "bad entry" end
  if type(entry.lease) ~= "string" or entry.lease == "" then return "bad entry" end
  if not integer(entry.at) then return "bad entry" end
  if type(entry.frame) ~= "string" or entry.frame == "" then return "bad entry" end
  if type(entry.code) ~= "string" or entry.code == "" then return "bad entry" end
  if not DECISIONS[entry.decision] then return "bad entry" end
  if not integer(entry.attempts) or entry.attempts < 0 then return "bad entry" end
  if entry.seq ~= nil and (not integer(entry.seq) or entry.seq < 1) then return "bad entry" end
  return nil
end

function M.leaseStatus(lease, now)
  if lease == nil or lease == false then return "none" end
  if type(lease) ~= "table" or lease.v ~= 2 then return nil, "bad lease" end
  if not integer(now) then return nil, "bad time" end
  if not integer(lease.untilAt) then return nil, "bad lease" end
  if lease.returnOnly == true then return "return_only" end
  if now >= lease.untilAt then return "expired" end
  return "active"
end

function M.journalRoom(head)
  if head == nil or head == false then return "none" end
  if type(head) ~= "table" or head.v ~= 1 then return nil, "bad journal" end
  if not integer(head.bytes) or head.bytes < 0 then return nil, "bad journal" end
  if not integer(head.budget) or head.budget < 1 then return nil, "bad journal" end
  if not integer(head.committed) or head.committed < 0 then return nil, "bad journal" end
  if head.bytes >= head.budget then return "full" end
  if head.bytes * 5 >= head.budget * 4 then return "home" end
  return "ok"
end

local function size(entry)
  return 32 + #entry.code + #entry.decision + #entry.lease
end

function M.append(head, entry)
  local room, roomErr = M.journalRoom(head)
  if not room then return nil, roomErr end
  if room == "none" then return nil, "bad journal" end
  local entryErr = validEntry(entry)
  if entryErr then return nil, entryErr end
  if entry.seq and entry.seq <= head.committed then
    local stored = head.entries and head.entries[entry.seq]
    if not stored then return nil, "unknown seq" end
    return copy(head), copy(stored)
  end
  local seq = entry.seq or (head.committed + 1)
  if seq ~= head.committed + 1 then return nil, "seq gap" end
  if room == "full" then return nil, "journal full" end
  local saved = copy(entry)
  saved.seq = seq
  local nextBytes = head.bytes + size(saved)
  if nextBytes > head.budget then return nil, "journal full" end
  local nextHead = copy(head)
  nextHead.entries = nextHead.entries or {}
  nextHead.entries[seq] = saved
  nextHead.committed = seq
  nextHead.bytes = nextBytes
  return nextHead, copy(saved)
end

function M.commit(head, seq)
  local room, roomErr = M.journalRoom(head)
  if not room or room == "none" then return nil, roomErr or "bad journal" end
  if not integer(seq) or not head.entries or not head.entries[seq] then return nil, "unknown seq" end
  local nextHead = copy(head)
  local entry = copy(head.entries[seq])
  if entry.phase == "done" then return nextHead, entry end
  if entry.phase ~= "intent" then return nil, "bad phase" end
  entry.phase = "done"
  nextHead.entries[seq] = entry
  return nextHead, copy(entry)
end

return M
