--[[
  cl_backup.lua — TUKONYA Chain Link: cap for the pre-overwrite backups.
  Backups: <ResourcePath>/Data/TUKONYA_ChainLink/backup_YYYY-MM-DD.txt (one file per day, appended before every
  container-block overwrite, cl_reaper backup()). Without a cap they grow forever.
  Policy: keep the newest KEEP_FILES day files AND at most MAX_BYTES in total (oldest go first); today's file is
  never deleted. Pure (no REAPER): the adapter passes the listing and does the deleting. Tests: tests/test_backup.lua.
--]]
local M = {}

M.KEEP_FILES = 14
M.MAX_BYTES = 64 * 1024 * 1024

local PATTERN = "^backup_%d%d%d%d%-%d%d%-%d%d%.txt$"
function M.is_backup_name(name) return type(name) == "string" and name:match(PATTERN) ~= nil end
function M.name_for(date_str) return "backup_" .. date_str .. ".txt" end

--- @param files  list of { name = "backup_YYYY-MM-DD.txt", bytes = n } (other names are ignored, never deleted)
--- @param today  today's file name (kept whatever its size)
--- @return list of names to delete (oldest first)
function M.plan(files, today, keep_files, max_bytes)
  keep_files = keep_files or M.KEEP_FILES
  max_bytes = max_bytes or M.MAX_BYTES
  local list = {}
  for _, f in ipairs(files or {}) do
    if M.is_backup_name(f.name) then list[#list + 1] = { name = f.name, bytes = tonumber(f.bytes) or 0 } end
  end
  table.sort(list, function(a, b) return a.name > b.name end)       -- newest first (ISO dates sort as text)
  local keep, total, del, cut = 0, 0, {}, false
  for _, f in ipairs(list) do
    if f.name == today then
      keep = keep + 1; total = total + f.bytes
    elseif not cut and keep < keep_files and total + f.bytes <= max_bytes then
      keep = keep + 1; total = total + f.bytes
    else
      cut = true                                                   -- everything older than the first drop goes too
      del[#del + 1] = f.name
    end
  end
  local out = {}
  for i = #del, 1, -1 do out[#out + 1] = del[i] end                -- oldest first
  return out
end

--- apply the plan to a folder through injected file functions.
--- deps = { list = function(dir) -> {names}, size = function(path) -> bytes|nil, remove = function(path) -> ok }
--- @return number of files removed
function M.prune(dir, today, deps, keep_files, max_bytes)
  local files = {}
  for _, name in ipairs(deps.list(dir) or {}) do
    if M.is_backup_name(name) then files[#files + 1] = { name = name, bytes = deps.size(dir .. "/" .. name) or 0 } end
  end
  local n = 0
  for _, name in ipairs(M.plan(files, today, keep_files, max_bytes)) do
    if deps.remove(dir .. "/" .. name) then n = n + 1 end
  end
  return n
end

-- ------------------------------------------------------------------ capped event log (review MUST 9: LINK events)
M.LOG_NAME = "link_log.txt"
M.LOG_MAX = 256 * 1024

--- the text to keep when an append-only log grew past `cap`: the newest whole lines, at most 3/4 of the cap
function M.trim_log(text, cap)
  cap = cap or M.LOG_MAX
  if #text <= cap then return text end
  local keep = math.floor(cap * 3 / 4)
  local start = #text - keep + 1
  local nl = text:find("\n", start, true)
  if not nl then return "" end
  return text:sub(nl + 1)
end

return M
