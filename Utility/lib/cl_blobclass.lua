--[[
  cl_blobclass.lua — TUKONYA Container Link: hidden-state class per plugin (DESIGN_V2 §2.4; pure Lua, no REAPER).
  Classes (latency only, never decide whether an edit spreads): "unknown" (default) / "noisy" (sticky; reset = delete the
  file) / "stable" (also live settle). File Data/TUKONYA_ChainLink/blob_class.txt, one line per fx_ident:
    1<TAB>ident<TAB>class<TAB>stable_sessions<TAB>last_used (YYYY-MM-DD)
  ≤ MAX_LINES lines, least recently used dropped first. Unreadable lines are skipped.
--]]
local M = {}
M.MAX_LINES = 1000
M.FILE = "blob_class.txt"
M.LOG = "blob_log.txt"
M.STABLE_SESSIONS = 2

function M.new() return { e = {}, dirty = false } end

function M.parse(text)
  local s = M.new()
  for line in (text or ""):gmatch("[^\r\n]+") do
    local v, id, cls, n, day = line:match("^(%d+)\t([^\t]+)\t(%a+)\t(%d+)\t([%d%-]+)$")
    if v == "1" and (cls == "unknown" or cls == "noisy" or cls == "stable") then
      s.e[id] = { class = cls, stable = tonumber(n) or 0, day = day }
    end
  end
  return s
end

function M.serialize(s, max_lines)
  max_lines = max_lines or M.MAX_LINES
  local list = {}
  for id, x in pairs(s.e) do list[#list + 1] = { id = id, x = x } end
  table.sort(list, function(a, b) if a.x.day ~= b.x.day then return a.x.day > b.x.day end; return a.id < b.id end)
  local out = {}
  for i = 1, math.min(#list, max_lines) do
    local a = list[i]
    out[#out + 1] = ("1\t%s\t%s\t%d\t%s"):format(a.id, a.x.class, a.x.stable or 0, a.x.day or "1970-01-01")
  end
  -- prune in memory too
  local keep = {}
  for i = 1, math.min(#list, max_lines) do keep[list[i].id] = list[i].x end
  s.e = keep
  table.sort(out)
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

function M.get(s, id) local x = s.e[id]; return x and x.class or "unknown" end

local function touch(s, id, today)
  local x = s.e[id]
  if not x then x = { class = "unknown", stable = 0, day = today }; s.e[id] = x end
  if today and x.day ~= today then x.day = today; s.dirty = true end
  return x
end
M.touch = touch

--- unexplained change seen on an invisible instance → noisy (sticky). Returns the log line when the class changed.
function M.noisy(s, id, today, detail)
  local x = touch(s, id, today)
  if x.class == "noisy" then return nil end
  local old = x.class
  x.class = "noisy"; s.dirty = true
  return ("class %s -> noisy | %s | %s"):format(old, id, detail or "")
end

--- one witness session with ≥ 5 s of playing and no change → evidence; STABLE_SESSIONS of them → stable (never from noisy)
function M.stable_evidence(s, id, today, detail)
  local x = touch(s, id, today)
  if x.class ~= "unknown" then return nil end
  x.stable = (x.stable or 0) + 1; s.dirty = true
  if x.stable >= M.STABLE_SESSIONS then
    x.class = "stable"
    return ("class unknown -> stable | %s | %s"):format(id, detail or "")
  end
  return nil
end

return M
