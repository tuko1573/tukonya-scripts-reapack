--[[
  al_chunk.lua — TUKONYA Auto Link: envelope state chunk handling (pure Lua, no REAPER calls).

  Synced lines (whitelist, DESIGN v1 R4): ACT, DEFSHAPE, PT, POOLEDENVINST.
  Every other line of the target (EGUID, VIS, LANEHEIGHT, ARM, VOLTYPE, unknown) stays as it is.
  Selection flags are not part of the line (R3): PT field 5, POOLEDENVINST field 6 (1-based after the keyword).
--]]

local M = {}

M.SYNC_KEYS = { ACT = true, DEFSHAPE = true, PT = true, POOLEDENVINST = true }

local function split_lines(chunk)
  local t = {}
  for line in (chunk or ""):gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if s ~= "" then t[#t + 1] = s end
  end
  return t
end
M.split_lines = split_lines

local function tokens(line)
  local t = {}
  for w in line:gmatch("%S+") do t[#t + 1] = w end
  return t
end

local function key_of(line)
  return line:match("^([%u_]+)")
end
M.key_of = key_of

local function strip_zeros(t)
  while #t > 1 and t[#t] == "0" do t[#t] = nil end
end

-- Canonical form of a synced body line: selection flag set to 0, then trailing "0" fields dropped
-- (REAPER omits trailing zero fields, so "PT 1 0.5 1" and "PT 1 0.5 1 0 1"(selected) are the same point).
-- PT time value shape [f4] [selected] [f6] [tension] ...
local function canon_pt(line)
  local t = tokens(line)
  if t[6] then t[6] = "0" end
  strip_zeros(t)
  return table.concat(t, " ")
end

-- POOLEDENVINST f1..fN : field 6 = selected
local function canon_ai(line)
  local t = tokens(line)
  if t[7] then t[7] = "0" end
  strip_zeros(t)
  return table.concat(t, " ")
end

--- Selection flag cleared but otherwise the same text (used when writing to a target).
local function unselect(line)
  local k = key_of(line)
  if k == "PT" then
    local t = tokens(line)
    if t[6] then t[6] = "0" end
    return table.concat(t, " ")
  elseif k == "POOLEDENVINST" then
    local t = tokens(line)
    if t[7] then t[7] = "0" end
    return table.concat(t, " ")
  end
  return line
end

--- Comparison key of an envelope: only the synced lines, selection removed.
-- Returns "" for nil/empty.
function M.norm_slow(chunk)
  local out = {}
  for _, line in ipairs(split_lines(chunk)) do
    local k = key_of(line)
    if k == "PT" then out[#out + 1] = canon_pt(line)
    elseif k == "POOLEDENVINST" then out[#out + 1] = canon_ai(line)
    elseif k == "ACT" or k == "DEFSHAPE" then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

function M.header(chunk)
  local l = split_lines(chunk)[1]
  return l and l:match("^(<%S+)") or nil
end

function M.count_points(chunk)
  local c = "\n" .. (chunk or ""):gsub("\r", "")
  local _, n = c:gsub("\n%s*PT ", "")
  local _, ai = c:gsub("\n%s*POOLEDENVINST ", "")
  return n, ai
end

function M.is_active(chunk)
  local a = (chunk or ""):match("\nACT%s+(%-?%d+)")
  return a ~= nil and tonumber(a) ~= 0
end

--- "Has a line": at least one point or automation item. (Active-ness is separate: ACT 0 = bypassed line.)
function M.has_line(chunk)
  local c = "\n" .. (chunk or "")
  return c:find("\n%s*PT ") ~= nil or c:find("\n%s*POOLEDENVINST ") ~= nil
end

--- Same test on a norm string (from M.norm).
function M.norm_has_line(n)
  n = "\n" .. (n or "")
  return n:find("\nPT", 1, true) ~= nil or n:find("\nPOOLEDENVINST", 1, true) ~= nil
end

--- Two norms count as the same line: equal text, or neither has any point (an unused lane).
function M.same(a, b)
  if a == b then return true end
  return (not M.norm_has_line(a)) and (not M.norm_has_line(b))
end

--- Build the chunk to write into the target: target's own lines, synced lines from source.
-- If the target has no line of its own yet (fresh / never used), the source's VIS and LANEHEIGHT are
-- taken as well so the new lane becomes visible like on the source.
function M.merge_slow(target_chunk, source_chunk)
  local tl = split_lines(target_chunk)
  local sl = split_lines(source_chunk)
  if #tl == 0 then return source_chunk end
  local fresh = not M.has_line(target_chunk)

  local src = { ACT = {}, DEFSHAPE = {}, BODY = {}, VIS = nil, LANEHEIGHT = nil }
  for i = 2, #sl do
    local line = sl[i]
    local k = key_of(line)
    if k == "ACT" or k == "DEFSHAPE" then src[k][#src[k] + 1] = line
    elseif k == "PT" or k == "POOLEDENVINST" then src.BODY[#src.BODY + 1] = unselect(line)
    elseif k == "VIS" or k == "LANEHEIGHT" then src[k] = line end
  end

  local out = { tl[1] }
  local done = {}
  local last = tl[#tl]
  local closing = (last == ">")
  local n_end = closing and (#tl - 1) or #tl
  for i = 2, n_end do
    local line = tl[i]
    local k = key_of(line)
    if k == "ACT" or k == "DEFSHAPE" then
      if not done[k] then
        for _, s in ipairs(src[k]) do out[#out + 1] = s end
        done[k] = true
      end
    elseif k == "PT" or k == "POOLEDENVINST" then
      if not done.BODY then
        for _, s in ipairs(src.BODY) do out[#out + 1] = s end
        done.BODY = true
      end
    elseif fresh and (k == "VIS" or k == "LANEHEIGHT") and src[k] then
      out[#out + 1] = src[k]
    else
      out[#out + 1] = line
    end
  end
  -- keys absent in the target: ACT/DEFSHAPE go right after the header (EGUID first if present)
  local pos = 2
  if out[2] and key_of(out[2]) == "EGUID" then pos = 3 end
  for _, k in ipairs({ "ACT", "DEFSHAPE" }) do
    if not done[k] and #src[k] > 0 then
      for j = 1, #src[k] do table.insert(out, pos, src[k][j]); pos = pos + 1 end
    else
      -- the target's own line of this key: continue inserting after it
      for i = pos, #out do if key_of(out[i]) == k then pos = i + 1 end end
    end
  end
  if not done.BODY then
    for _, s in ipairs(src.BODY) do out[#out + 1] = s end
  end
  if closing then out[#out + 1] = ">" end
  return table.concat(out, "\n") .. "\n"
end


------------------------------------------------------------------ fast path (dense lines)
-- REAPER writes the points as one block at the end: head lines, then PT / POOLEDENVINST lines, then ">".
-- For that (regular) shape the body is handled with a few whole-string gsubs instead of per-line Lua work
-- (5000 points: norm 7 ms -> well under 1 ms). Anything else falls back to the line-by-line code above;
-- tests/test_chunk.lua checks both give identical results.

local function count_plain(s, pat)
  local n, p = 0, 1
  while true do
    p = s:find(pat, p, true)
    if not p then return n end
    n = n + 1; p = p + 1
  end
end

local function split_regular(chunk)
  if not chunk or chunk:find("\r", 1, true) or chunk:find("\t", 1, true) then return nil end
  local e = #chunk
  while e > 0 and chunk:byte(e) <= 32 do e = e - 1 end
  if e < 2 or chunk:byte(e) ~= 62 or chunk:byte(e - 1) ~= 10 then return nil end   -- must end with "\n>"
  local close = e - 1
  local a = chunk:find("\nPOOLEDENVINST ", 1, true)
  local b = chunk:find("\nPT ", 1, true)
  local i = (a and b) and math.min(a, b) or a or b
  if not i then return chunk:sub(1, close), "" end      -- no body
  local body = chunk:sub(i + 1, close)                   -- every line ends with "\n"
  if body:find("  ", 1, true) or body:find("\n ", 1, true) or body:find(" \n", 1, true) then return nil end
  -- every body line must start with "PT " or "POOLEDENVINST " (plain-find counts; pattern scans are slow here)
  local lb = "\n" .. body
  local nl = count_plain(body, "\n")
  if count_plain(lb, "\nPT ") + count_plain(lb, "\nPOOLEDENVINST ") ~= nl then return nil end
  return chunk:sub(1, i), body
end
M.split_regular = split_regular

local function canon_body(body)
  local b = "\n" .. body
  b = b:gsub("\n(PT [^ \n]+ [^ \n]+ [^ \n]+ [^ \n]+) [^ \n]+", "\n%1 0")
  if b:find("POOLEDENVINST", 1, true) then b = b:gsub("\n(POOLEDENVINST %S+ %S+ %S+ %S+ %S+) %S+", "\n%1 0") end
  local n
  repeat b, n = b:gsub(" 0%f[\n]", "") until n == 0
  return b:sub(2, -2)
end

local function unselect_body(body)
  local b = "\n" .. body
  b = b:gsub("\n(PT [^ \n]+ [^ \n]+ [^ \n]+ [^ \n]+) [^ \n]+", "\n%1 0")
  if b:find("POOLEDENVINST", 1, true) then b = b:gsub("\n(POOLEDENVINST %S+ %S+ %S+ %S+ %S+) %S+", "\n%1 0") end
  return b:sub(2)
end

--- Comparison key of an envelope: only the synced lines (ACT, DEFSHAPE, PT, POOLEDENVINST), selection removed.
-- Returns "" for nil/empty.
function M.norm(chunk)
  local head, body = split_regular(chunk)
  if not head then return M.norm_slow(chunk) end
  local out = {}
  for _, line in ipairs(split_lines(head)) do
    local k = key_of(line)
    if k == "ACT" or k == "DEFSHAPE" then out[#out + 1] = line end
  end
  if body ~= "" then out[#out + 1] = canon_body(body) end
  return table.concat(out, "\n")
end

--- Build the chunk to write into the target: target's own lines, synced lines from source.
-- If the target has no line of its own yet (fresh / never used), the source's VIS and LANEHEIGHT are
-- taken as well so the new lane becomes visible like on the source.
function M.merge(target_chunk, source_chunk)
  local th, tb = split_regular(target_chunk)
  local sh, sb = split_regular(source_chunk)
  if not th or not sh then return M.merge_slow(target_chunk, source_chunk) end
  -- heads are a handful of lines: merge them with the line code, then append the source's body
  local headed = M.merge_slow(th .. (tb ~= "" and "PT 0 0\n" or "") .. ">\n", sh .. ">\n")
  -- merge_slow kept a placeholder body position only if the target had points; drop any PT lines it wrote
  local lines = {}
  for _, l in ipairs(split_lines(headed)) do
    local k = key_of(l)
    if k ~= "PT" and k ~= "POOLEDENVINST" and l ~= ">" then lines[#lines + 1] = l end
  end
  return table.concat(lines, "\n") .. "\n" .. unselect_body(sb) .. ">\n"
end

--- Short human-readable summary for logs.
function M.describe(chunk)
  local n, ai = M.count_points(chunk)
  local act = (chunk or ""):match("\nACT%s+(%S+)") or "?"
  return ("ACT%s pts=%d ai=%d"):format(act, n, ai)
end

return M
