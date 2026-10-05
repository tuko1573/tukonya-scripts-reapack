--[[
  cl_struct.lua — TUKONYA Chain Link: track-chunk text surgery for structure sync (pure Lua, strings only).

  Layout of a container inside a track chunk (REAPER 7.80, tests/probes/LOG_p2pre.txt):
    BYPASS 0 0 0                       ← the container's own bypass line (parent level, untouched here)
    <CONTAINER name ""                 ← block start
    CONTAINER_CFG 2 2 2 0 / <IN_PINS> / <OUT_PINS> / SHOW / LASTSEL / DOCKED     ← header
    BYPASS … / <VST|JS|AU|CONTAINER …> / MULTIFXLINK / PRESETNAME / FLOATPOS / FXID {…} / WAK   ← one item each
    CONTAINER_PARM <a> <item index> <param>:<name> ""   ← mapped container params (envelope lanes, P3)
    >                                  ← block end
    MULTIFXLINK 0 / FLOATPOS / FXID {container guid} / <PARMENV …> / WAK   ← parent level, untouched here
  The container is found by its own FXID line, which follows its block at the same depth.
--]]

local M = {}

local function trim(l) return (l:match("^%s*(.-)%s*$")) end

function M.lines(s)
  local t = {}
  for l in (s:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end
  if t[#t] == "" then t[#t] = nil end
  return t
end

--- block end for a block starting at line i ("<…"), or nil
local function block_end(L, i, lim)
  local d = 0
  for j = i, lim or #L do
    local l = trim(L[j])
    if l:sub(1, 1) == "<" then d = d + 1 elseif l == ">" then d = d - 1; if d == 0 then return j end end
  end
end
M.block_end = block_end

--- locate the <CONTAINER block whose own FXID line is `guid`. Returns s, e (line numbers) or nil.
function M.find_container(L, guid)
  local want = "FXID " .. guid
  local d = 0
  local last = {}          -- depth → {s, e} of the last <CONTAINER block closed at that depth
  local open = {}          -- stack of block starts
  for i = 1, #L do
    local l = trim(L[i])
    if l:sub(1, 1) == "<" then
      d = d + 1; open[d] = i
    elseif l == ">" then
      local s = open[d]
      open[d] = nil
      d = d - 1
      if s and trim(L[s]):match("^<CONTAINER") then last[d] = { s, i } end
    elseif l == want then
      local b = last[d]
      if b then return b[1], b[2] end
      return nil
    elseif l:match("^BYPASS ") then
      last[d] = nil       -- a new item begins at this depth: a container seen before belongs to an earlier item
    end
  end
end

--- split a container block (lines s..e) into header, items and trailer
function M.parse(L, s, e)
  local b = { first = L[s], head = {}, items = {}, trail = {} }
  local i = s + 1
  local cur = nil
  while i < e do
    local l = trim(L[i])
    if l:sub(1, 1) == "<" then
      local j = block_end(L, i, e - 1) or (e - 1)
      local dst = cur and cur.lines or b.head
      for q = i, j do dst[#dst + 1] = L[q] end
      i = j + 1
    else
      if l:match("^BYPASS ") then cur = { lines = {} }; b.items[#b.items + 1] = cur end
      if l:match("^CONTAINER_PARM ") then b.trail[#b.trail + 1] = L[i]
      elseif cur then cur.lines[#cur.lines + 1] = L[i]
      else b.head[#b.head + 1] = L[i] end
      i = i + 1
    end
  end
  for _, it in ipairs(b.items) do
    for _, l in ipairs(it.lines) do
      local g = trim(l):match("^FXID (%S+)")
      if g then it.fxid = g end
    end
  end
  return b
end

local function key(l) return trim(l):match("^(%S+)") end

--- copy item lines, replacing FXID / FLOATPOS / WAK by the target's own (or dropping FXID when there is no match)
local function with_own(src_item, own)
  local o = {}
  local ownl = {}
  if own then for _, l in ipairs(own.lines) do local k = key(l); if k == "FXID" or k == "FLOATPOS" or k == "WAK" then ownl[k] = l end end end
  local depth = 0
  for _, l in ipairs(src_item.lines) do
    local t = trim(l)
    if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
    local k = depth == 0 and key(l) or nil
    if k == "FXID" then
      if ownl.FXID then o[#o + 1] = ownl.FXID end      -- unmatched: no FXID line → REAPER assigns a new GUID
    elseif (k == "FLOATPOS" or k == "WAK") and ownl[k] then o[#o + 1] = ownl[k]
    else o[#o + 1] = l end
  end
  return o
end

--[[ new container block for the target, built from the source's block:
  - items = the source's items without its marker; each gets the target's own FXID/FLOATPOS/WAK when a target item with
    the same ident is still unused (greedy, in order); unmatched items lose the FXID line (never copied verbatim [M P0-7])
  - the target's own marker item (its Ch, its FXID) stays at its own position (clamped)
  - header: the source's (channel config, pins) except the first line and SHOW/LASTSEL/DOCKED, which stay the target's
  - CONTAINER_PARM lines: the target's own, item index remapped to where that FX went; lines of removed FX are dropped
  src_ids / dst_ids: fx_ident per item position (from REAPER, same order as the chunk), is_marker(ident) → bool
  returns lines, info {matched, new, dropped_parms} ]]
function M.splice(sb, db, src_ids, dst_ids, is_marker)
  local info = { matched = 0, new = 0, dropped_parms = 0 }
  -- target items by ident (excluding the marker), and the target marker
  local pool, dmark, dmark_pos = {}, nil, 1
  local dpos = 0
  for i, it in ipairs(db.items) do
    if is_marker(dst_ids[i] or "") and not dmark then dmark = it; dmark_pos = i
    else
      dpos = dpos + 1
      local id = dst_ids[i] or ""
      pool[id] = pool[id] or {}
      table.insert(pool[id], { it = it, old = i - 1 })
    end
  end
  local new_items = {}       -- {lines, old_index or nil}
  for i, it in ipairs(sb.items) do
    local id = src_ids[i] or ""
    if not is_marker(id) then
      local p = pool[id]
      local m = p and table.remove(p, 1)
      if m then info.matched = info.matched + 1 else info.new = info.new + 1 end
      new_items[#new_items + 1] = { lines = with_own(it, m and m.it), old = m and m.old }
    end
  end
  if dmark then
    local pos = math.min(dmark_pos, #new_items + 1)
    table.insert(new_items, pos, { lines = dmark.lines, old = dmark_pos - 1 })
  end
  local remap = {}
  for ni, e in ipairs(new_items) do if e.old then remap[e.old] = ni - 1 end end
  -- header
  local dh = {}
  for _, l in ipairs(db.head) do local k = key(l); if k == "SHOW" or k == "LASTSEL" or k == "DOCKED" then dh[k] = l end end
  local out = { db.first }
  for _, l in ipairs(sb.head) do
    local k = key(l)
    if k == "LASTSEL" then
      local v = tonumber((dh.LASTSEL or l):match("LASTSEL%s+(%-?%d+)")) or 0
      out[#out + 1] = "LASTSEL " .. math.max(0, math.min(v, #new_items - 1))
    elseif (k == "SHOW" or k == "DOCKED") and dh[k] then out[#out + 1] = dh[k]
    else out[#out + 1] = l end
  end
  for _, e in ipairs(new_items) do for _, l in ipairs(e.lines) do out[#out + 1] = l end end
  -- P3: the first field is the 1-based container param index (= N+1 of the lane's "<PARMENV N:a" outside the block,
  -- LOG_p3pre). Survivors are renumbered 1..n; info.amap (old a → new a, false = dropped) lets fix_parmenv drop or
  -- renumber the matching lanes so no lane is left pointing at a vanished or shifted container param.
  info.amap, info.renum = {}, false
  local na = 0
  for _, l in ipairs(db.trail) do
    local a, idx, rest = trim(l):match("^CONTAINER_PARM%s+(%S+)%s+(%d+)%s+(.*)$")
    local ni = idx and remap[tonumber(idx)]
    local an = tonumber(a)
    if ni then
      na = na + 1
      if an then info.amap[an] = na; if an ~= na then info.renum = true end end
      out[#out + 1] = ("CONTAINER_PARM %s %d %s"):format(an and tostring(na) or a, ni, rest)
    else
      info.dropped_parms = info.dropped_parms + 1
      if an then info.amap[an] = false; info.renum = true end
    end
  end
  out[#out + 1] = ">"
  return out, info
end

--- P3: lanes of the container that follow its block (parent level, up to the next item): a lane whose mapping was
--- dropped is removed, a renumbered one gets its new "N:a". L = lines of the whole new chunk, from = first line after
--- the container block. Returns new lines, number removed, number renumbered.
function M.fix_parmenv(L, from, amap)
  local out = {}
  for i = 1, from - 1 do out[#out + 1] = L[i] end
  local i, d, done, removed, renum = from, 0, false, 0, 0
  while i <= #L do
    local l = L[i]
    local t = trim(l)
    if done then out[#out + 1] = l; i = i + 1
    elseif d == 0 and (t:match("^BYPASS ") or t == ">") then done = true
    elseif d == 0 and t:match("^<PARMENV ") then
      local N, a, rest = t:match("^<PARMENV (%d+):(%d+)(.*)$")
      local j = block_end(L, i) or i
      local na = a and amap[tonumber(a)]
      if na == false then removed = removed + 1; i = j + 1
      else
        if na and na ~= tonumber(a) then
          out[#out + 1] = (l:match("^(%s*)") or "") .. ("<PARMENV %d:%d%s"):format(na - 1, na, rest); renum = renum + 1
        else out[#out + 1] = l end
        for q = i + 1, j do out[#out + 1] = L[q] end
        i = j + 1
      end
    else
      if t:sub(1, 1) == "<" then d = d + 1 elseif t == ">" then d = d - 1 end
      out[#out + 1] = l; i = i + 1
    end
  end
  return out, removed, renum
end

--- the chunk with lines s..e replaced by `blk`
function M.replace(L, s, e, blk)
  local out = {}
  for i = 1, s - 1 do out[#out + 1] = L[i] end
  for _, l in ipairs(blk) do out[#out + 1] = l end
  for i = e + 1, #L do out[#out + 1] = L[i] end
  return table.concat(out, "\n") .. "\n"
end

--- diff class of a structure change (target's old sig → new sig): "same", "append" (old is a strict prefix), "costly"
function M.class(old, new)
  if old == new then return "same" end
  if old == "" then return "append" end
  if #new > #old and new:sub(1, #old + 1) == old .. "\n" then return "append" end
  return "costly"
end

-- ------------------------------------------------------------------ native structure sync (RESULTS_SOOTHE_REORDER §2c a')
--[[ Plan REAPER's own deletes and moves that turn the target's container items into the source's order, or nil when that
  cannot express it (an item the target lacks → an add; the chunk splice is the fallback).
  src_ids / dst_ids: fx_ident per item position (marker included). The target keeps its own marker at its own position
  (clamped), like splice. Returns ops: {op = "delete", pos} / {op = "move", from, to} — 1-based positions in the target's
  item list at the time of that op; `to` is the final position (the adapter converts it to REAPER's pre-move insert
  position). Matching = the same greedy rule as splice (first unused target item with the same ident). ]]
function M.native_plan(src_ids, dst_ids, is_marker)
  local pool, dmark_pos = {}, nil
  local cur = {}                                   -- tokens of the target items: { ident, id = unique }
  for i, id in ipairs(dst_ids) do
    local tok = { ident = id, n = i, marker = is_marker(id) and dmark_pos == nil }
    if tok.marker then dmark_pos = i end
    cur[#cur + 1] = tok
    if not tok.marker then pool[id] = pool[id] or {}; table.insert(pool[id], tok) end
  end
  local want = {}
  for _, id in ipairs(src_ids) do
    if not is_marker(id) then
      local p = pool[id]
      local tok = p and table.remove(p, 1)
      if not tok then return nil end               -- the target lacks this plugin: an add (chunk path)
      want[#want + 1] = tok
    end
  end
  local used = {}
  for _, tok in ipairs(want) do used[tok] = true end
  local ops = {}
  for i = #cur, 1, -1 do                           -- deletes from the back (positions in front stay valid)
    local tok = cur[i]
    if not tok.marker and not used[tok] then ops[#ops + 1] = { op = "delete", pos = i }; table.remove(cur, i) end
  end
  local final = {}
  for _, tok in ipairs(want) do final[#final + 1] = tok end
  if dmark_pos then
    local mk
    for _, tok in ipairs(cur) do if tok.marker then mk = tok end end
    table.insert(final, math.min(dmark_pos, #final + 1), mk)
  end
  for i = 1, #final do
    local j
    for x = 1, #cur do if cur[x] == final[i] then j = x; break end end
    if j ~= i then
      ops[#ops + 1] = { op = "move", from = j, to = i }
      local tok = table.remove(cur, j)
      table.insert(cur, i, tok)
    end
  end
  return ops
end

--- REAPER's pre-move insert position (1-based) for a move that must end at `to` [M e3: item 1 → position 4 of 3 = end]
function M.insert_pos(from, to) if to > from then return to + 1 end; return to end

return M
