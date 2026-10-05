--[[
  cl_env.lua — TUKONYA Chain Link: FX-parameter lanes on the container (P3, pure Lua, REAPER only through `io`).

  Facts (REAPER 7.80, tests/probes/RESULTS.md P0-4 + LOG_p3pre.txt):
  - a lane for an FX inside a container lives on the CONTAINER: a `CONTAINER_PARM` mapping line inside the block and a
    `<PARMENV N:…>` block after the container's FXID. The container param index N differs between tracks (creation
    order), so a lane is keyed by (slot k, inner param p) — slot = position among the items without the marker; the group
    only links members whose slot idents agree. p < 0 = REAPER's appended params by role (-3 bypass, -2 Wet, -1 Delta).
  - a target lane is created with `GetFXEnvelope(target inner addr, p, true)` (REAPER writes the target's own mapping),
    then filled with `SetEnvelopeStateChunk`: 0 undo / 0 state count. Writing 0 points + ACT 0 removes a lane (0/0).
  Chunk text rules: Auto Link al_chunk whitelist (ACT, DEFSHAPE, PT, POOLEDENVINST; selection flags ignored); every
  other target line (EGUID, header with its own N, VIS, LANEHEIGHT, ARM) stays the target's — except on a lane we just
  created, which takes the source's VIS / LANEHEIGHT / ARM (a created lane is ARM 1 [M]).

  Rules (user decision 2026-10-01: every member gets the same lane): symmetric, no leader. A member whose lane changed
  since our last look is the source — also when the lane was removed (removal spreads; Auto Link's "never spread a
  removal" does NOT apply here). Held (no writes, last[] frozen) while playing / recording / settling; the change is
  found and spread after stop. A joiner without lanes takes the group's lanes silently; a joiner whose own lanes differ
  is left out of lane sync (logged) until it carries the group's lanes.

  io:
    lanes(mid)              -> { [key] = {k, p, fp, act} }   every lane on the member's container mapped to a slot
    lane_chunk(mid, key)    -> chunk text
    lane_create(mid, k, p)  -> chunk of the new (or existing) lane      (GetFXEnvelope create=true)
    lane_set(mid, k, p, s)  -> readback chunk                           (SetEnvelopeStateChunk)
    lane_remove(mid, k, p)  -> bool                                     (0 points + ACT 0)
--]]

local M = {}

local function log(io, s) if io.log then io.log(s) end end

-- ------------------------------------------------------------------ chunk text (port of al_chunk, Auto Link v1)
local function split_lines(chunk)
  local t = {}
  for line in (chunk or ""):gmatch("[^\r\n]+") do
    local s = line:match("^%s*(.-)%s*$")
    if s ~= "" then t[#t + 1] = s end
  end
  return t
end
local function tokens(line) local t = {}; for w in line:gmatch("%S+") do t[#t + 1] = w end; return t end
local function key_of(line) return line:match("^([%u_]+)") end
local function strip_zeros(t) while #t > 1 and t[#t] == "0" do t[#t] = nil end end
local function canon_pt(line) local t = tokens(line); if t[6] then t[6] = "0" end; strip_zeros(t); return table.concat(t, " ") end
local function canon_ai(line) local t = tokens(line); if t[7] then t[7] = "0" end; strip_zeros(t); return table.concat(t, " ") end
local function unselect(line)
  local k = key_of(line)
  if k == "PT" then local t = tokens(line); if t[6] then t[6] = "0" end; return table.concat(t, " ")
  elseif k == "POOLEDENVINST" then local t = tokens(line); if t[7] then t[7] = "0" end; return table.concat(t, " ") end
  return line
end

--- comparison key of a lane: only the synced lines, selection removed; "" for no lane
function M.norm(chunk)
  local out = {}
  for _, line in ipairs(split_lines(chunk)) do
    local k = key_of(line)
    if k == "PT" then out[#out + 1] = canon_pt(line)
    elseif k == "POOLEDENVINST" then out[#out + 1] = canon_ai(line)
    elseif k == "ACT" or k == "DEFSHAPE" then out[#out + 1] = line end
  end
  return table.concat(out, "\n")
end

--- a lane "has a line": at least one point or automation item (ACT 0 = bypassed line, still a line)
function M.has_line(n)
  n = "\n" .. (n or "")
  return n:find("\nPT", 1, true) ~= nil or n:find("\nPOOLEDENVINST", 1, true) ~= nil
end

--- two norms are the same lane state: equal text, or neither has a line (absent = empty)
function M.same(a, b)
  if a == b then return true end
  return not M.has_line(a) and not M.has_line(b)
end

function M.active(n) local a = ("\n" .. (n or "")):match("\nACT%s+(%-?%d+)"); return a ~= nil and tonumber(a) ~= 0 end

--- target's own lines + the source's synced lines. created = the target lane was just created by us: it also takes the
--- source's VIS / LANEHEIGHT / ARM (a fresh lane is ARM 1 and visible [M]).
function M.merge(target_chunk, source_chunk, created)
  local tl, sl = split_lines(target_chunk), split_lines(source_chunk)
  if #tl == 0 then return source_chunk end
  local fresh = created or not M.has_line(M.norm(target_chunk))
  local src = { ACT = {}, DEFSHAPE = {}, BODY = {} }
  for i = 2, #sl do
    local line = sl[i]
    local k = key_of(line)
    if k == "ACT" or k == "DEFSHAPE" then src[k][#src[k] + 1] = line
    elseif k == "PT" or k == "POOLEDENVINST" then src.BODY[#src.BODY + 1] = unselect(line)
    elseif k == "VIS" or k == "LANEHEIGHT" or k == "ARM" then src[k] = line end
  end
  local out, done = { tl[1] }, {}
  local closing = (tl[#tl] == ">")
  local n_end = closing and (#tl - 1) or #tl
  for i = 2, n_end do
    local line = tl[i]
    local k = key_of(line)
    if k == "ACT" or k == "DEFSHAPE" then
      if not done[k] then for _, s in ipairs(src[k]) do out[#out + 1] = s end; done[k] = true end
    elseif k == "PT" or k == "POOLEDENVINST" then
      if not done.BODY then for _, s in ipairs(src.BODY) do out[#out + 1] = s end; done.BODY = true end
    elseif fresh and (k == "VIS" or k == "LANEHEIGHT" or (created and k == "ARM")) and src[k] then
      out[#out + 1] = src[k]
    else
      out[#out + 1] = line
    end
  end
  local pos = 2
  if out[2] and key_of(out[2]) == "EGUID" then pos = 3 end
  for _, k in ipairs({ "ACT", "DEFSHAPE" }) do
    if not done[k] and #src[k] > 0 then
      for j = 1, #src[k] do table.insert(out, pos, src[k][j]); pos = pos + 1 end
    else
      for i = pos, #out do if key_of(out[i]) == k then pos = i + 1 end end
    end
  end
  if not done.BODY then for _, s in ipairs(src.BODY) do out[#out + 1] = s end end
  if closing then out[#out + 1] = ">" end
  return table.concat(out, "\n") .. "\n"
end

--- the chunk that removes a lane: its own lines without points / automation items, ACT 0 [M p3pre]
function M.removal(chunk)
  local out = {}
  for _, line in ipairs(split_lines(chunk)) do
    local k = key_of(line)
    if k == "ACT" then out[#out + 1] = "ACT 0 -1"
    elseif k ~= "PT" and k ~= "POOLEDENVINST" then out[#out + 1] = line end
  end
  return table.concat(out, "\n") .. "\n"
end

function M.describe(n)
  local _, pts = ("\n" .. (n or "")):gsub("\nPT", "")
  return M.has_line(n) and ("%d pts%s"):format(pts, M.active(n) and "" or " (ACT 0)") or "no lane"
end

-- ------------------------------------------------------------------ group state
local function E_of(g)
  local E = g.env_st
  if not E then
    E = { last = {}, raw = {}, rawn = {}, fp = {}, agreed = nil, achunk = {}, excl = {}, told = {}, last_write = -1e9,
          equal = false, pending = false, rr = {} }
    g.env_st = E
  end
  return E
end
M.state = E_of

--- forget the lane baseline (structure rebuilt: slot numbers may have moved)
function M.reset(g) g.env_st = nil end

local function split_key(key)
  local k, p = key:match("^([^|]+)|(%-?%d+)$")
  return tonumber(k) or k, tonumber(p)
end
M.split_key = split_key

--- current norms of one member, reading a chunk only when the cheap fingerprint changed or the round robin is due
local function read_member(st, io, E, m, now, cfg)
  local lanes = io.lanes(m) or {}
  local cur, fps = {}, E.fp[m] or {}
  local raw, rawn = E.raw[m] or {}, E.rawn[m] or {}
  local due = now >= (E.rr[m] or 0)
  if due then E.rr[m] = now + cfg.env_rr end
  local newfp, newraw, newrawn, act = {}, {}, {}, {}
  for key, L in pairs(lanes) do
    local n
    if not due and fps[key] == L.fp and rawn[key] then n = rawn[key]; newraw[key] = raw[key]
    else
      local c = io.lane_chunk(m, key) or ""
      st.stats.env_reads = (st.stats.env_reads or 0) + 1
      if raw[key] == c and rawn[key] then n = rawn[key] else n = M.norm(c) end
      newraw[key] = c
    end
    newfp[key], newrawn[key] = L.fp, n
    cur[key] = n
    act[key] = L.act
  end
  E.fp[m], E.raw[m], E.rawn[m] = newfp, newraw, newrawn
  return cur, act
end

local function keys_of(...)
  local u, list = {}, {}
  for _, t in ipairs({ ... }) do
    for key in pairs(t or {}) do if not u[key] then u[key] = true; list[#list + 1] = key end end
  end
  table.sort(list)
  return list
end

--- make member t carry `n` (a norm) for lane key; src_chunk = a chunk with that content (nil when n has no line)
local function put(st, io, E, g, t, key, n, src_chunk, cur)
  local k, p = split_key(key)
  if not M.has_line(n) then
    if M.has_line(cur[t] and cur[t][key]) then
      io.lane_remove(t, k, p)
      st.stats.env_removes = (st.stats.env_removes or 0) + 1
      log(io, ("Ch %d lane %s: removed on %s"):format(g.ch, key, t))
    end
    E.last[t][key] = nil
    if cur[t] then cur[t][key] = nil end
    return
  end
  local tc = E.raw[t] and E.raw[t][key]
  local created = false
  if not (cur[t] and cur[t][key]) then tc = io.lane_create(t, k, p); created = true
  elseif not tc then tc = io.lane_chunk(t, key) end
  local wc = M.merge(tc or "", src_chunk, created)
  local back = io.lane_set(t, k, p, wc) or ""
  st.stats.env_writes = (st.stats.env_writes or 0) + 1
  local bn = M.norm(back)
  if bn ~= n then log(io, ("Ch %d lane %s: read-back differs on %s"):format(g.ch, key, t)) end
  E.raw[t] = E.raw[t] or {}; E.rawn[t] = E.rawn[t] or {}
  E.raw[t][key], E.rawn[t][key] = back, bn
  E.fp[t] = E.fp[t] or {}; E.fp[t][key] = nil          -- re-read next time (its fingerprint changed)
  E.last[t][key] = bn
  if cur[t] then cur[t][key] = bn end
end

local function agree(E, key, n, chunk)
  if M.has_line(n) then E.agreed[key] = n; E.achunk[key] = chunk else E.agreed[key] = nil; E.achunk[key] = nil end
end

local function pick(ps_info, list, ctx)
  local t, f = ctx.touched, ctx.focused
  for _, m in ipairs(list) do if (t and t.mid == m) or (f and f.mid == m) then return m end end
  for _, m in ipairs(list) do if ctx.selected[m] then return m end end
  return list[1]
end

-- ------------------------------------------------------------------ one step per group and tick
--- mem = linked members with the agreed structure (in track order). Sets S.env exclusions on g.slots.
--- held = no writes (playing / recording / settling). Returns nothing.
function M.step(st, io, ps, g, mem, ctx, held)
  local cfg, now = st.cfg, ctx.now
  local E = E_of(g)
  -- members that left
  local inmem = {}
  for _, m in ipairs(mem) do inmem[m] = true end
  for _, tb in ipairs({ E.last, E.raw, E.rawn, E.fp, E.excl, E.rr }) do for m in pairs(tb) do if not inmem[m] then tb[m] = nil end end end
  -- read every member (cheap fingerprints; chunks only on change / round robin)
  local cur, act = {}, {}
  for _, m in ipairs(mem) do cur[m], act[m] = read_member(st, io, E, m, now, cfg) end
  -- value-sync exclusion: a param with an active lane on any member is driven by its lane (MUST 9)
  if g.slots then
    for _, k in ipairs(g.order) do g.slots[k].env = {} end
    for _, m in ipairs(mem) do
      for key, a in pairs(act[m]) do
        if a then
          local k, p = split_key(key)
          local S = g.slots[k]
          if S then S.env[p] = true end
        end
      end
    end
  end
  -- undo/redo restore of the lanes (history guard), before any election. An undo while held is not restored later
  -- (as Auto Link): a deferred restore landing right after a Touch pass would overwrite what was just recorded.
  if g.env_restore then
    if not held then M.restore(st, io, ps, g, mem, ctx, cur); g.env_restore = nil
    elseif not g.env_restore.force then g.env_restore = nil end      -- a LINK entry's lanes wait for the stop
  end
  -- baseline: the first look at this group, then joiners
  if E.agreed == nil then
    local ref = mem[1]
    for _, m in ipairs(mem) do if next(cur[m]) then ref = m; break end end
    if not ref then return end
    E.agreed, E.achunk = {}, {}
    for key, n in pairs(cur[ref]) do agree(E, key, n, E.raw[ref][key]) end
    E.last[ref] = {}
    for key, n in pairs(cur[ref]) do E.last[ref][key] = n end
  end
  local inc = {}
  for _, m in ipairs(mem) do
    if not E.last[m] then
      -- a joiner (or a member back from a structure rebuild)
      local equal = true
      for _, key in ipairs(keys_of(cur[m], E.agreed)) do if not M.same(cur[m][key], E.agreed[key]) then equal = false end end
      if equal then
        E.last[m] = {}
        for key, n in pairs(cur[m]) do E.last[m][key] = n end
        E.excl[m] = nil
      elseif not next(cur[m]) and not held then
        E.last[m] = {}
        for key, n in pairs(E.agreed) do put(st, io, E, g, m, key, n, E.achunk[key], cur) end
        log(io, ("Ch %d: lanes of the group written to %s (it had none)"):format(g.ch, m))
      else
        if not E.excl[m] then
          E.excl[m] = true
          log(io, ("Ch %d: %s has its own different lanes — left out of lane sync until they match"):format(g.ch, m))
        end
      end
    end
    if E.last[m] then inc[#inc + 1] = m end
  end
  -- equality (for undo records): every included member carries the agreed lanes, nobody left out
  local keys = keys_of(E.agreed, table.unpack((function() local t = {}; for _, m in ipairs(inc) do t[#t + 1] = cur[m] end; return t end)()))
  -- (members left out of lane sync do not count: they must not block the undo records of the whole Ch)
  local eq = true
  local changed_any = false
  for _, key in ipairs(keys) do
    for _, m in ipairs(inc) do
      if not M.same(cur[m][key], E.agreed[key]) then eq = false end
      if not M.same(cur[m][key], E.last[m][key]) then changed_any = true end
    end
  end
  E.equal, E.pending = eq, changed_any
  E.inc = {}
  for _, m in ipairs(inc) do E.inc[m] = true end
  if held or #inc < 2 or not changed_any then return end
  if now - E.last_write < cfg.env_drag then return end
  -- election per lane key (Auto Link elect, with removal spreading)
  local wrote = false
  for _, key in ipairs(keys) do
    local changed = {}
    for _, m in ipairs(inc) do if not M.same(cur[m][key], E.last[m][key]) then changed[#changed + 1] = m end end
    if #changed > 0 then
      local first = cur[changed[1]][key] or ""
      local all_same = true
      for i = 2, #changed do if not M.same(cur[changed[i]][key], first) then all_same = false end end
      local src = pick(ps.info, changed, ctx)
      if not all_same then
        st.stats.env_conflicts = (st.stats.env_conflicts or 0) + 1
        log(io, ("Ch %d lane %s: %d members changed it differently; %s wins (touched/selected/lowest track)"):format(g.ch, key, #changed, src))
      end
      local n = cur[src][key] or ""
      local sc = E.raw[src] and E.raw[src][key]
      for _, t in ipairs(inc) do
        if t ~= src and not M.same(cur[t][key], n) then put(st, io, E, g, t, key, n, sc, cur); wrote = true
        else E.last[t][key] = cur[t][key] end
      end
      E.last[src][key] = cur[src][key]
      agree(E, key, n, sc)
      log(io, ("Ch %d lane %s: %s from %s"):format(g.ch, key, M.describe(n), src))
    end
  end
  if wrote then E.last_write = now end
  E.pending = false
  E.equal = true
  -- a lane change that never gets its own undo entry (e.g. automation recorded while playing, or an API edit) must not
  -- leave the current entry's record stale: if no new entry appears within env_rec_refresh, the record's lanes are
  -- refreshed. A GUI edit's entry appears at mouse-up, which cancels this (the previous entry's record stays as it was).
  E.refresh_at, E.refresh_h = now + cfg.env_rec_refresh, ps.hist[ctx.cur]
end

--- called every tick after the step (core): applies a due record refresh, see above
function M.refresh(st, ps, g, ctx)
  local E = g.env_st
  if not E or not E.refresh_at then return end
  local h = ps.hist[ctx.cur]
  if h ~= E.refresh_h then E.refresh_at = nil; return end           -- a new undo entry appeared: it carries the change
  if ctx.now < E.refresh_at or not M.settled(g) then return end
  E.refresh_at = nil
  local rec = h and h.ch[g.ch]
  if rec then rec.env = M.record(g); st.stats.env_rec_refresh = (st.stats.env_rec_refresh or 0) + 1 end
end

-- ------------------------------------------------------------------ LINK (DESIGN_V2 §4.1)
--- the source's lanes onto every target: source lanes written (merged into the target's own lane lines, created when
--- missing), target lanes the source has no line for removed. The group's lane baseline is reset afterwards (the next
--- step re-baselines; everyone carries the same lanes then). Returns the number of lane writes.
function M.link_copy(st, io, g, src, targets)
  local sl = io.lanes(src) or {}
  local sc = {}
  for key in pairs(sl) do
    local c = io.lane_chunk(src, key)
    if c and M.has_line(M.norm(c)) then sc[key] = c end
  end
  local n = 0
  for _, t in ipairs(targets) do
    local tl = io.lanes(t) or {}
    local keys = {}
    for key in pairs(sc) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local k, p = split_key(key)
      local tc, created = tl[key] and io.lane_chunk(t, key), false
      if not tc then tc = io.lane_create(t, k, p); created = true end
      io.lane_set(t, k, p, M.merge(tc or "", sc[key], created))
      n = n + 1
    end
    for key in pairs(tl) do
      if not sc[key] then
        local c = io.lane_chunk(t, key)
        if c and M.has_line(M.norm(c)) then
          local k, p = split_key(key)
          io.lane_remove(t, k, p)
          n = n + 1
        end
      end
    end
  end
  st.stats.env_writes = (st.stats.env_writes or 0) + n
  M.reset(g)
  log(io, ("Ch %d: LINK lanes from %s to %d targets (%d writes)"):format(g.ch, src, #targets, n))
  return n
end

-- ------------------------------------------------------------------ history guard (records and restore)
--- lane part of an undo record: the agreed lanes (norm + chunk), shared strings
function M.record(g)
  local E = g.env_st
  if not E or not E.agreed then return { lanes = {}, members = {} } end
  local r, mem = {}, {}
  for key, n in pairs(E.agreed) do r[key] = { n = n, c = E.achunk[key] } end
  for m in pairs(E.inc or {}) do mem[m] = true end
  return { lanes = r, members = mem }                 -- members = those in lane sync then (left-out members never written)
end

--- is the lane facet settled enough to be recorded? (all members carry the agreed lanes, nothing held)
function M.settled(g)
  local E = g.env_st
  if not E then return false end
  return E.agreed ~= nil and E.equal and not E.pending
end

--- after an undo/redo onto a known entry: per lane, restore the recorded state (a missing lane is a state too) onto the
--- record's members — from a record member that still carries it (al_core M2, minus "only if it has a line"), else from
--- the chunk kept in the record (REAPER can restore several members to older snapshots so that nobody carries it [M])
function M.restore(st, io, ps, g, mem, ctx, cur)
  local plan = g.env_restore
  local rec, members = plan.env or {}, plan.members or {}
  local E = E_of(g)
  local present = {}
  for _, m in ipairs(mem) do present[#present + 1] = cur[m] end
  local rk = {}
  for key in pairs(rec) do rk[key] = true end
  local keys = keys_of(rk, table.unpack(present))
  local n_w, n_nc = 0, 0
  E.agreed = E.agreed or {}
  for _, key in ipairs(keys) do
    local want = rec[key] and rec[key].n or ""
    -- only lanes the undo actually changed somewhere: a lane nobody's undo touched keeps its current agreed state (a lane
    -- recorded without an undo entry, e.g. Touch automation, must not be wiped by a stale record)
    local touched = plan.force or false
    for _, m in ipairs(mem) do
      if E.last[m] and not M.same(cur[m][key], E.last[m][key]) then touched = true end
    end
    local carrier
    for _, m in ipairs(mem) do if members[m] and M.same(cur[m][key], want) then carrier = m; break end end
    -- nobody carries the recorded lane (REAPER restored several members to older snapshots, MBP run p3run1): the record
    -- holds the agreed chunk itself, so it is written from there (same rule as P2's structure records)
    local from_rec = false
    if not touched then carrier = nil
    elseif not carrier then
      local any_member = false
      for _, m in ipairs(mem) do if members[m] then any_member = true end end
      if any_member and (want == "" or (rec[key] and rec[key].c)) then from_rec = true end
    end
    if carrier or from_rec then
      if from_rec then n_nc = n_nc + 1; st.stats.env_restores_from_record = (st.stats.env_restores_from_record or 0) + 1 end
      local chunk = rec[key] and (carrier and E.raw[carrier] and E.raw[carrier][key] or rec[key].c) or nil
      for _, m in ipairs(mem) do
        if not M.same(cur[m][key], want) then
          if members[m] then
            E.last[m] = E.last[m] or {}
            put(st, io, E, g, m, key, want, chunk, cur); n_w = n_w + 1
            if carrier and M.has_line(want) then                 -- the lane-driven value as the carrier has it now
              local k, p = split_key(key)
              local v = io.get(carrier, k, p)
              if v then io.set(m, k, p, v) end
            end
          elseif not E.excl[m] then
            E.excl[m] = true; E.last[m] = nil
            log(io, ("Ch %d: %s not in the undo record and its lane %s differs — left out of lane sync"):format(g.ch, m, key))
          end
        end
      end
      for _, m in ipairs(mem) do if E.last[m] then E.last[m][key] = cur[m][key] end end
      agree(E, key, want, chunk)
    end
  end
  st.stats.env_restores = (st.stats.env_restores or 0) + 1
  log(io, ("Ch %d: lanes restored from the undo record (%d writes, %d lanes carried by nobody → written from the record)"):format(g.ch, n_w, n_nc))
end

return M
