--[[
  al_core.lua — TUKONYA Auto Link: the link logic (pure Lua; every REAPER access goes through `io`).

  io (see al_reaper.lua for the real one, tests/ for the fake):
    io.now() -> seconds          io.clock() -> seconds for the per-tick work budget (optional, default io.now)
    io.project() -> key string (project pointer + file path)
    io.scan() -> { {guid, ch (0 = Off), mask, mask_env, panmode, index, name, selected, automode}, ... }  tracks with the marker
    io.playing() -> bool        io.override() -> global automation override (-1 none)
    io.undo() -> {cur, desc, time, sc}   (Undo_GetCurEntry / GetEntryDesc / GetEntryTime / GetProjectStateChangeCount)
    io.fp(guid, type) -> cheap fingerprint string      io.chunk(guid, type) -> envelope chunk
    io.write(guid, type, chunk) -> bool                 io.backup(guid, type, chunk, why)
    io.ask(text, kind) -> "yes" | "no" | "cancel" | "ok"
    io.publish(counts, active)   counts[ch] = linked tracks; active[ch] = bitmask of types with a line on any member
    io.has_line(guid, type) -> bool (points or automation items; bypassed counts)
    io.set_mask(guid, mask) -> read-back mask (marker slider 2 "Link Types")
    io.log(text) (optional)

  Order inside one tick (contract, see docs/DESIGN.md v1 + tests/probes/RESULTS.md P6):
    project -> marker scan -> Ch debounce -> HOLD -> undo/redo check -> fingerprints -> full compare
    -> no-line rules -> source election -> writes -> undo-history record -> dialogs (only when stopped)
--]]

local C = require("al_chunk")
local M = {}

-- bit = position in the marker's "Link Types" mask (slider2); jp = the name REAPER's Japanese UI shows
M.TYPES = {
  { key = "MUTE",     chunk = "<MUTEENV",   bit = 0, jp = "ミュート" },
  { key = "VOL",      chunk = "<VOLENV2",   bit = 1, jp = "音量" },
  { key = "PAN",      chunk = "<PANENV2",   bit = 2, jp = "パン", pan = true },
  { key = "WIDTH",    chunk = "<WIDTHENV2", bit = 3, jp = "Width", pan = true },
  { key = "TRIM",     chunk = "<VOLENV3",   bit = 4, jp = "トリミング量" },
  { key = "VOLPRE",   chunk = "<VOLENV",    bit = 5, jp = "音量(Pre-FX)" },
  { key = "PANPRE",   chunk = "<PANENV",    bit = 6, jp = "パン(Pre-FX)", pan = true },
  { key = "WIDTHPRE", chunk = "<WIDTHENV",  bit = 7, jp = "パン幅(Pre-FX)", pan = true },
}
M.TYPE_BY_KEY = {}
for _, t in ipairs(M.TYPES) do M.TYPE_BY_KEY[t.key] = t end

M.DEFAULTS = {
  debounce = 1.0,        -- Ch must stay the same this long before a track joins (R5)
  settle_ticks = 2,      -- after transport stops, wait this many ticks before comparing (HOLD)
  rr_rate = 20,          -- round-robin full compares per second (catches same-count drags; fixed rate, not per tick)
  budget = 0.002,        -- seconds of full-compare work per tick (at least one item always runs)
  drag_interval = 0.1,   -- the same line is written at most this often while it keeps changing
  hold_all_playing = true,  -- true = never write while playing; the other tracks update when transport stops
  hist_max = 2000,       -- undo-history entries kept per project
}

local HOLD_TRACK = { [2] = true, [3] = true, [4] = true, [5] = true } -- touch, write, latch, latch preview
local HOLD_GLOBAL = { [2] = true, [3] = true, [4] = true }

local function log(io, s) if io.log then io.log(s) end end

local function bit_on(mask, T) return mask ~= nil and ((math.floor(mask) >> T.bit) & 1) == 1 end
M.bit_on = bit_on

local norm = C.norm
M.norm = norm

-- per (member, type) cache: the last chunk text read and its norm. A steady line then costs one string
-- compare instead of re-parsing its points (T12 dense).
local function gnorm(gt, m, c)
  if gt.raw[m] == c then return gt.rawn[m] end
  local n = norm(c)
  gt.raw[m], gt.rawn[m] = c, n
  return n
end

function M.new(cfg)
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  return { cfg = c, projects = {}, stats = { writes = 0, dialogs = 0, notices = 0, restores = 0, ticks = 0, mask_writes = 0 } }
end

local function new_ps()
  return { cand = {}, eff = {}, info = {}, groups = {}, hist = {}, jobs = {}, notified = {},
           last_cur = nil, last_sc = nil, was_playing = false, settle = 0, rr = 0, rr_acc = 0, last_now = nil,
           declined_join = {}, eff_t = {}, eff_seq = 0 }
end

local function new_gt()
  return { last = {}, fp = {}, excl = {}, raw = {}, rawn = {}, agreed = nil, achunk = nil, conflict = false, careful = false,
           dirty = true, last_write = -1e9 }
end

local function group(ps, ch)
  local g = ps.groups[ch]
  if not g then
    g = { ch = ch, members = {}, joiners = {}, t = {}, mask = nil, mask_last = {} }
    for _, T in ipairs(M.TYPES) do g.t[T.key] = new_gt() end
    ps.groups[ch] = g
  end
  return g
end

local function sort_members(ps, list)
  table.sort(list, function(a, b)
    local ia, ib = ps.info[a] and ps.info[a].index or 1e9, ps.info[b] and ps.info[b].index or 1e9
    return ia < ib
  end)
end

local function remove_from(list, x)
  for i = #list, 1, -1 do if list[i] == x then table.remove(list, i) end end
end

local function leave(ps, guid)
  local ch = ps.eff[guid]
  ps.eff[guid] = nil
  if not ch then return end
  local g = ps.groups[ch]
  if not g then return end
  remove_from(g.members, guid)
  g.joiners[guid] = nil
  g.mask_last[guid] = nil
  for _, gt in pairs(g.t) do gt.last[guid] = nil; gt.fp[guid] = nil; gt.excl[guid] = nil; gt.raw[guid] = nil; gt.rawn[guid] = nil; gt.dirty = true end
  for i = #ps.jobs, 1, -1 do
    local j = ps.jobs[i]
    if j.guid == guid or (j.kind == "conflict" and j.ch == ch) then
      if j.kind == "conflict" then g.t[j.type].conflict = false end
      table.remove(ps.jobs, i)
    end
  end
end

-- members of g that take part for type key (not pending / declined)
local function included(g, key)
  local gt, out = g.t[key], {}
  for _, m in ipairs(g.members) do if not gt.excl[m] then out[#out + 1] = m end end
  return out
end

local function write(st, io, guid, key, chunk)
  local ok = io.write(guid, key, chunk)
  if ok ~= false then st.stats.writes = st.stats.writes + 1 end
  return ok ~= false
end

local function name_of(ps, guid)
  local r = ps.info[guid]
  return (r and r.name and r.name ~= "") and r.name or ("トラック " .. tostring(r and r.index or "?"))
end

-- Make every member in `targets` carry the line (src_chunk/src_norm). Returns number of writes.
local function spread(st, io, gt, key, targets, src_chunk, src_norm, skip)
  local n = 0
  for _, m in ipairs(targets) do
    if m ~= skip then
      local mc = io.chunk(m, key)
      if gnorm(gt, m, mc) ~= src_norm then
        local wc = C.merge(mc, src_chunk)
        write(st, io, m, key, wc); n = n + 1
        local bc = io.chunk(m, key)
        local back
        if bc == wc then back = src_norm; gt.raw[m], gt.rawn[m] = bc, src_norm else back = gnorm(gt, m, bc) end
        if back ~= src_norm then log(io, "read-back differs on " .. tostring(m) .. " " .. key) end
        gt.last[m] = back
      else
        gt.last[m] = src_norm
      end
      gt.fp[m] = io.fp(m, key)
    end
  end
  return n
end

local function settle_line(gt, norm, chunk) gt.agreed = norm; gt.achunk = chunk end

local function pick_source(ps, list)
  local best
  for _, m in ipairs(list) do
    local r = ps.info[m]
    if not best then best = m
    else
      local rb = ps.info[best]
      if (r and r.selected) and not (rb and rb.selected) then best = m
      elseif ((r and r.selected) == (rb and rb.selected)) and (r and r.index or 1e9) < (rb and rb.index or 1e9) then best = m end
    end
  end
  return best
end

local function is_held(st, ps, g, io, playing, override)
  if not playing then return false end
  if st.cfg.hold_all_playing then return true end
  if HOLD_GLOBAL[override] then return true end
  for _, m in ipairs(g.members) do
    local r = ps.info[m]
    if r and HOLD_TRACK[r.automode] then return true end
  end
  return false
end

------------------------------------------------------------------ joins
local function handle_joins(st, io, ps, g)
  local joiners = {}
  for guid in pairs(g.joiners) do joiners[#joiners + 1] = guid end
  if #joiners == 0 then return end
  sort_members(ps, joiners)
  local joining = {}
  for _, j in ipairs(joiners) do joining[j] = true end
  for _, j in ipairs(joiners) do
    local conflict_types = {}
    for _, T in ipairs(M.TYPES) do
     if bit_on(g.mask, T) then
      local gt = g.t[T.key]
      gt.excl[j] = nil
      local ref
      for _, m in ipairs(g.members) do
        if m ~= j and not joining[m] and not gt.excl[m] then ref = m; break end
      end
      local jc = io.chunk(j, T.key); local jn = norm(jc)
      if not ref then
        gt.last[j] = jn
        settle_line(gt, jn, jc)
      else
        local rc = io.chunk(ref, T.key); local rn = norm(rc)
        if C.same(jn, rn) then
          gt.last[j] = jn
          if gt.agreed == nil then settle_line(gt, rn, rc) end
        elseif not C.norm_has_line(jn) then
          -- joiner has no line: it takes the group's line, silently
          spread(st, io, gt, T.key, { j }, rc, rn)
          settle_line(gt, rn, rc)
        elseif not C.norm_has_line(rn) then
          -- only the joiner has a line: it spreads to the others
          local others = {}
          for _, m in ipairs(g.members) do if m ~= j and not joining[m] and not gt.excl[m] then others[#others + 1] = m end end
          spread(st, io, gt, T.key, others, jc, jn)
          gt.last[j] = jn
          settle_line(gt, jn, jc)
        else
          gt.excl[j] = "pending"
          gt.last[j] = jn
          conflict_types[#conflict_types + 1] = T.key
        end
      end
      gt.fp[j] = io.fp(j, T.key)
     end
    end
    joining[j] = nil
    if #conflict_types > 0 then
      local dk = j .. "|" .. g.ch
      if ps.declined_join[dk] then
        for _, k in ipairs(conflict_types) do g.t[k].excl[j] = "declined" end
      else
        ps.jobs[#ps.jobs + 1] = { kind = "join", guid = j, ch = g.ch, types = conflict_types }
      end
    end
  end
  g.joiners = {}
end

------------------------------------------------------------------ link types (v2: shared per-Ch mask)
-- a type was unchecked: stop syncing it and forget its state; nothing is written
local function reset_type(ps, g, key)
  g.t[key] = new_gt()
  g.t[key].dirty = false
  for i = #ps.jobs, 1, -1 do
    local j = ps.jobs[i]
    if j.ch == g.ch and (j.type == key) then table.remove(ps.jobs, i)
    elseif j.ch == g.ch and j.kind == "join" then
      remove_from(j.types, key)
      if #j.types == 0 then table.remove(ps.jobs, i) end
    end
  end
end

-- a type was checked (or must be looked at again): join rules across all linked tracks of the Ch
local function activate(st, io, ps, g, key)
  local gt = g.t[key]
  gt.activate = false
  local inc = included(g, key)
  local chunks, norms, distinct, order = {}, {}, {}, {}
  local cand = {}
  for _, m in ipairs(inc) do cand[#cand + 1] = m end
  table.sort(cand, function(a, b)
    local ra, rb = ps.info[a], ps.info[b]
    local sa, sb = ra and ra.selected or false, rb and rb.selected or false
    if sa ~= sb then return sa end
    return (ra and ra.index or 1e9) < (rb and rb.index or 1e9)
  end)
  for _, m in ipairs(cand) do
    local c = io.chunk(m, key)
    chunks[m] = c; norms[m] = gnorm(gt, m, c)
    gt.fp[m] = io.fp(m, key)
    if C.norm_has_line(norms[m]) and not distinct[norms[m]] then distinct[norms[m]] = true; order[#order + 1] = m end
  end
  if #order == 0 then
    for _, m in ipairs(inc) do gt.last[m] = norms[m] end
    if inc[1] then settle_line(gt, norms[inc[1]], chunks[inc[1]]) end
  elseif #order == 1 then
    local s = order[1]
    spread(st, io, gt, key, inc, chunks[s], norms[s], s)
    gt.last[s] = norms[s]
    settle_line(gt, norms[s], chunks[s])
  else
    for _, m in ipairs(inc) do gt.last[m] = norms[m] end
    gt.conflict = true
    ps.jobs[#ps.jobs + 1] = { kind = "activate", ch = g.ch, type = key, guids = order }
  end
  gt.dirty = false
end

local function apply_mask_change(ps, g, old, new)
  if old == nil or old == new then return end
  for _, T in ipairs(M.TYPES) do
    local was, now = bit_on(old, T), bit_on(new, T)
    if was and not now then reset_type(ps, g, T.key)
    elseif now and not was then g.t[T.key] = new_gt(); g.t[T.key].activate = true end
  end
end

-- the Ch's shared mask: a change on one linked track wins and goes to all; joiners take the Ch's mask
local function mask_step(st, io, ps, g)
  if #g.members == 0 then return end
  local old = g.mask
  if g.mask == nil then
    local best
    for _, m in ipairs(g.members) do
      if not best or (ps.eff_t[m] or 0) < (ps.eff_t[best] or 0) then best = m end
    end
    g.mask = ps.info[best] and ps.info[best].mask or 1
  end
  local changed, vals, nvals = {}, {}, 0
  for _, m in ipairs(g.members) do
    local r = ps.info[m]
    if r and g.mask_last[m] ~= nil and r.mask ~= g.mask_last[m] and not r.mask_env then
      changed[#changed + 1] = m
      if not vals[r.mask] then vals[r.mask] = true; nvals = nvals + 1 end
    end
  end
  if #changed > 0 then
    local w = (nvals == 1) and changed[1] or pick_source(ps, changed)
    g.mask = ps.info[w].mask
  end
  for _, m in ipairs(g.members) do
    local r = ps.info[m]
    if r and r.mask ~= g.mask and not r.mask_env then   -- a mask driven by its own envelope is not fought every tick
      local back = io.set_mask(m, g.mask)
      st.stats.mask_writes = st.stats.mask_writes + 1
      r.mask = back or g.mask
    end
    if r then g.mask_last[m] = r.mask end
  end
  apply_mask_change(ps, g, old, g.mask)
end

-- pan types: a track whose pan mode differs from the first linked track is left out (log only)
local function pan_mode_rule(io, ps, g)
  local ref = g.members[1] and ps.info[g.members[1]] and ps.info[g.members[1]].panmode
  for _, T in ipairs(M.TYPES) do
    if T.pan and bit_on(g.mask, T) then
      local gt = g.t[T.key]
      for _, m in ipairs(g.members) do
        local pm = ps.info[m] and ps.info[m].panmode
        if pm ~= ref then
          if gt.excl[m] ~= "panmode" then
            gt.excl[m] = "panmode"
            log(io, ("pan mode differs on %s: %s not linked"):format(name_of(ps, m), T.jp))
          end
        elseif gt.excl[m] == "panmode" then
          gt.excl[m] = nil; gt.last[m] = nil; gt.activate = true
        end
      end
    end
  end
end

------------------------------------------------------------------ undo history (R1, see RESULTS.md P6)
-- M2: a record is restored only (a) if it has a line (a removal is never spread, R10), (b) onto the members that
-- were linked when it was recorded (a track that joined later keeps its own line), and (c) if at least one of
-- those members already carries exactly that line (so a stale or mistaken record never invents a line).
local function hist_restore(st, io, ps, h, held_by_ch)
  local restored = {}
  -- the Ch's type mask (same guard: only if one of the record's tracks carries it now)
  for ch, rec in pairs(h.mk or {}) do
    local g = ps.groups[ch]
    local differs = g ~= nil and rec.mask ~= g.mask
    if g and not differs then
      for _, m in ipairs(g.members) do
        if rec.members[m] and ps.info[m] and ps.info[m].mask ~= rec.mask then differs = true end
      end
    end
    if g and not held_by_ch[ch] and differs then
      local someone = false
      for m in pairs(rec.members) do
        local r = ps.info[m]
        if r and r.ch == ch and r.mask == rec.mask then someone = true; break end
      end
      if someone then
        local old = g.mask
        g.mask = rec.mask
        for _, m in ipairs(g.members) do
          local r = ps.info[m]
          if r and rec.members[m] and r.mask ~= rec.mask and not r.mask_env then
            r.mask = io.set_mask(m, rec.mask) or rec.mask
            st.stats.mask_writes = st.stats.mask_writes + 1
          end
          if r then g.mask_last[m] = r.mask end
        end
        apply_mask_change(ps, g, old, g.mask)
        restored["mask|" .. ch] = true
      end
    end
  end
  for gkey, rec in pairs(h.g) do
    local ch, key = gkey:match("^(%d+)|(%u+)$")
    ch = tonumber(ch)
    local g = ps.groups[ch]
    if g and #g.members >= 2 and not held_by_ch[ch] and C.norm_has_line(rec.norm) and bit_on(g.mask, M.TYPE_BY_KEY[key]) then
      local gt = g.t[key]
      local targets, someone = {}, false
      for _, m in ipairs(included(g, key)) do
        if rec.members[m] then targets[#targets + 1] = m end
      end
      -- "someone carries it": any track of the record that is present with this Ch now, also one that is
      -- still waiting out the 1 s join delay (e.g. a deleted track brought back by this undo)
      for m in pairs(rec.members) do
        local r = ps.info[m]
        if r and r.ch == ch and norm(io.chunk(m, key)) == rec.norm then someone = true; break end
      end
      if someone then
        spread(st, io, gt, key, targets, rec.chunk, rec.norm)
        settle_line(gt, rec.norm, rec.chunk)
        -- members that were not linked then keep their own line; if it differs they stay unlinked for now
        for _, m in ipairs(included(g, key)) do
          if not rec.members[m] then
            local n = gnorm(gt, m, io.chunk(m, key))
            gt.last[m] = n; gt.fp[m] = io.fp(m, key)
            if not C.same(n, rec.norm) then gt.excl[m] = "declined" end
          end
        end
        gt.conflict = false
        for i = #ps.jobs, 1, -1 do local jb = ps.jobs[i]; if jb.kind == "conflict" and jb.ch == ch and jb.type == key then table.remove(ps.jobs, i) end end
        gt.dirty = false
        restored[gkey] = true
      end
    end
  end
  if next(restored) then st.stats.restores = st.stats.restores + 1 end
  return restored
end

local function hist_record(st, ps, cur, held_by_ch)
  local h = ps.hist[cur]
  if not h then return end
  for ch, g in pairs(ps.groups) do
    if #g.members >= 2 and not held_by_ch[ch] then
      h.mk = h.mk or {}
      if h.mk[ch] == nil and g.mask ~= nil then
        local mem = {}
        for _, m in ipairs(g.members) do mem[m] = true end
        h.mk[ch] = { mask = g.mask, members = mem }
      end
      for key, gt in pairs(g.t) do
        local gk = ch .. "|" .. key
        if bit_on(g.mask, M.TYPE_BY_KEY[key]) and h.g[gk] == nil and gt.agreed ~= nil and not gt.conflict and not gt.dirty and not gt.activate then
          local mem = {}
          for _, m in ipairs(included(g, key)) do mem[m] = true end
          h.g[gk] = { norm = gt.agreed, chunk = gt.achunk, members = mem }
        end
      end
    end
  end
end

-- M3: an entry is identified by its own name+time AND the previous entry's name+time, so an index that
-- shifts (undo memory full) or a same-second branch is much less likely to be taken for a known entry.
local function hist_match(h, u)
  return h ~= nil and h.desc == u.desc and h.time == u.time and h.pdesc == u.pdesc and h.ptime == u.ptime
end

local function hist_new_entry(st, ps, u, prune)
  if prune then for i, _ in pairs(ps.hist) do if i >= u.cur then ps.hist[i] = nil end end end
  ps.hist[u.cur] = { desc = u.desc, time = u.time, pdesc = u.pdesc, ptime = u.ptime, g = {} }
  local lim = u.cur - st.cfg.hist_max
  for i, _ in pairs(ps.hist) do if i < lim then ps.hist[i] = nil end end
end

------------------------------------------------------------------ dialogs
local function types_jp(keys)
  local t = {}
  for _, k in ipairs(keys) do t[#t + 1] = M.TYPE_BY_KEY[k].jp end
  return table.concat(t, "・")
end

local function run_job(st, io, ps, job)
  local g = ps.groups[job.ch]
  if not g then return end
  if job.kind == "join" then
    local j = job.guid
    local still = {}
    for _, key in ipairs(job.types) do
      local gt = g.t[key]
      if gt.excl[j] == "pending" then
        local inc = included(g, key)
        local jn = norm(io.chunk(j, key))
        if inc[1] and not C.same(jn, norm(io.chunk(inc[1], key))) then still[#still + 1] = key
        else gt.excl[j] = nil; gt.last[j] = jn end
      end
    end
    if #still == 0 then return end
    st.stats.dialogs = st.stats.dialogs + 1
    local nm = name_of(ps, j)
    local text = ("「%s」の %s の線が、Link Ch %d のほかのトラックの線と違います。\n\n" ..
      "はい：このトラックの線を、Ch %d の線に合わせる\n" ..
      "いいえ：このトラックの線を、Ch %d のほかのトラックへ写す\n" ..
      "キャンセル：今は合わせない（このトラックの %s はつながらないままになります。\n" ..
      "　REAPER を閉じるまで、このトラックと Ch %d の組み合わせについてはもう聞きません）\n\n" ..
      "書き換えられる前の線は、控えとして保存します。")
      :format(nm, types_jp(still), job.ch, job.ch, job.ch, types_jp(still), job.ch)
    local ans = io.ask(text, "yesnocancel")
    for _, key in ipairs(still) do
      local gt = g.t[key]
      gt.excl[j] = nil
      local inc = included(g, key)
      if ans == "yes" then
        local ref
        for _, m in ipairs(inc) do if m ~= j then ref = m; break end end
        local rc = io.chunk(ref, key); local rn = norm(rc)
        io.backup(j, key, io.chunk(j, key), "join: replaced by Ch " .. job.ch)
        spread(st, io, gt, key, { j }, rc, rn)
        settle_line(gt, rn, rc)
      elseif ans == "no" then
        local jc = io.chunk(j, key); local jn = norm(jc)
        for _, m in ipairs(inc) do if m ~= j then io.backup(m, key, io.chunk(m, key), "join: replaced by " .. nm) end end
        spread(st, io, gt, key, inc, jc, jn, j)
        gt.last[j] = jn
        settle_line(gt, jn, jc)
      else
        gt.excl[j] = "declined"
        ps.declined_join[j .. "|" .. job.ch] = true
      end
      gt.dirty = false
    end
  elseif job.kind == "activate" then
    local gt = g.t[job.type]
    if not gt.conflict or not bit_on(g.mask, M.TYPE_BY_KEY[job.type]) then return end
    local inc = included(g, job.type)
    local cands, seen = {}, {}
    for _, m in ipairs(job.guids) do
      for _, x in ipairs(inc) do
        if x == m then
          local c = io.chunk(m, job.type); local n = norm(c)
          if C.norm_has_line(n) and not seen[n] then seen[n] = true; cands[#cands + 1] = { guid = m, chunk = c, norm = n } end
        end
      end
    end
    gt.conflict = false
    if #cands < 2 then gt.activate = true; return end
    st.stats.dialogs = st.stats.dialogs + 1
    local a, b = cands[1], cands[2]
    local tj = M.TYPE_BY_KEY[job.type].jp
    local text = ("Link Ch %d で「%s」をつなぐと、トラックによって線が違います。\n\n" ..
      "はい：「%s」の線に合わせる\n" ..
      "いいえ：「%s」の線に合わせる\n" ..
      "キャンセル：今は合わせない（線が違うトラックは、同じ線になるまで「%s」がつながりません）\n\n" ..
      "書き換えられる前の線は、控えとして保存します。")
      :format(job.ch, tj, name_of(ps, a.guid), name_of(ps, b.guid), tj)
    local ans = io.ask(text, "yesnocancel")
    if ans == "yes" or ans == "no" then
      local s = (ans == "yes") and a or b
      for _, m in ipairs(inc) do
        if m ~= s.guid then
          local mc = io.chunk(m, job.type)
          if C.has_line(mc) and norm(mc) ~= s.norm then io.backup(m, job.type, mc, "link type checked: replaced by " .. name_of(ps, s.guid)) end
        end
      end
      spread(st, io, gt, job.type, inc, s.chunk, s.norm, s.guid)
      gt.last[s.guid] = s.norm
      settle_line(gt, s.norm, s.chunk)
      gt.last_write = io.now()
    else
      settle_line(gt, a.norm, a.chunk)
      for _, m in ipairs(inc) do
        local n = norm(io.chunk(m, job.type))
        gt.last[m] = n; gt.fp[m] = io.fp(m, job.type)
        if not C.same(n, a.norm) then gt.excl[m] = "declined" end
      end
    end
    gt.dirty = false
  elseif job.kind == "conflict" then
    local gt = g.t[job.type]
    if not gt.conflict then return end
    local inc = included(g, job.type)
    local norms, cands, seen = {}, {}, {}
    for _, m in ipairs(job.guids) do
      local present = false
      for _, x in ipairs(inc) do if x == m then present = true end end
      if present then
        local c = io.chunk(m, job.type); local n = norm(c)
        if not seen[n] then seen[n] = true; cands[#cands + 1] = { guid = m, chunk = c, norm = n } end
      end
    end
    if #cands < 2 then
      gt.conflict = false; gt.dirty = true
      return
    end
    st.stats.dialogs = st.stats.dialogs + 1
    local a, b = cands[1], cands[2]
    local text = ("Link Ch %d の %s の線が、「%s」と「%s」で別々に書き換えられています。\n\n" ..
      "はい：「%s」の線に合わせる\n" ..
      "いいえ：「%s」の線に合わせる\n" ..
      "キャンセル：今は合わせない（次にどちらかを書き換えたとき、そちらに合わせます）")
      :format(job.ch, M.TYPE_BY_KEY[job.type].jp, name_of(ps, a.guid), name_of(ps, b.guid), name_of(ps, a.guid), name_of(ps, b.guid))
    local ans = io.ask(text, "yesnocancel")
    gt.conflict = false
    if ans == "yes" or ans == "no" then
      local s = (ans == "yes") and a or b
      spread(st, io, gt, job.type, inc, s.chunk, s.norm, s.guid)
      gt.last[s.guid] = s.norm
      settle_line(gt, s.norm, s.chunk)
      gt.last_write = io.now()
    else
      for _, m in ipairs(inc) do gt.last[m] = norm(io.chunk(m, job.type)); gt.fp[m] = io.fp(m, job.type) end
    end
    gt.dirty = false
  end
end

-- U1: informational notices are not shown as dialogs any more; they only go to the log
local function notice_removed(st, io, ps, g, key, guid)
  local k = guid .. "|" .. key
  if ps.notified[k] then return end
  ps.notified[k] = true
  st.stats.notices = st.stats.notices + 1
  log(io, ("%s: %s line removed; the other tracks of Ch %d keep theirs"):format(name_of(ps, guid), M.TYPE_BY_KEY[key].jp, g.ch))
end

------------------------------------------------------------------ election on one (group, type)
local function elect(st, io, ps, g, key, now)
  local gt = g.t[key]
  -- declined / pending members: rejoin silently once they carry the same line again
  for _, m in ipairs(g.members) do
    if gt.excl[m] == "declined" and gt.agreed ~= nil then
      local n = norm(io.chunk(m, key))
      if C.same(n, gt.agreed) then gt.excl[m] = nil; gt.last[m] = n end
    end
  end
  local inc = included(g, key)
  if #inc < 2 then
    -- a single linked track: its line is the group's line (a declined track can come back to it)
    for _, m in ipairs(inc) do
      local c = io.chunk(m, key)
      gt.last[m] = norm(c); gt.fp[m] = io.fp(m, key)
      settle_line(gt, gt.last[m], c)
    end
    return
  end
  if gt.conflict then return end
  if now - gt.last_write < st.cfg.drag_interval then gt.dirty = true; return end
  local chunks, norms, changed = {}, {}, {}
  for _, m in ipairs(inc) do
    local c = io.chunk(m, key)
    chunks[m] = c; norms[m] = gnorm(gt, m, c)
    gt.fp[m] = io.fp(m, key)
    if norms[m] ~= gt.last[m] then changed[#changed + 1] = m end
  end
  -- S6: volume / trim lanes whose fader-scale setting (VOLTYPE) differs between tracks: tell once, still sync
  if (key == "VOL" or key == "TRIM") and not ps.notified["vt|" .. g.ch .. "|" .. key] then
    local first, differ = nil, false
    for _, m in ipairs(inc) do
      if C.has_line(chunks[m]) then
        local v = chunks[m]:match("\nVOLTYPE (%d+)") or "0"
        if first == nil then first = v elseif v ~= first then differ = true end
      end
    end
    if differ then
      ps.notified["vt|" .. g.ch .. "|" .. key] = true
      st.stats.notices = st.stats.notices + 1
      log(io, ("Ch %d: %s scale setting (VOLTYPE) differs between tracks; synced anyway"):format(g.ch, M.TYPE_BY_KEY[key].jp))
    end
  end
  -- S1: right after moving back in the undo list without a restore: differing lines are asked, not picked
  if gt.careful then
    gt.careful = false
    local distinct, order = {}, {}
    for _, m in ipairs(inc) do
      local n = norms[m]
      if C.norm_has_line(n) and not distinct[n] then distinct[n] = true; order[#order + 1] = m end
    end
    if #order >= 2 then
      gt.conflict = true
      local list = {}
      for _, m in ipairs(changed) do if distinct[norms[m]] then list[#list + 1] = m end end
      for _, m in ipairs(order) do
        local dup = false
        for _, x in ipairs(list) do if x == m then dup = true end end
        if not dup then list[#list + 1] = m end
      end
      ps.jobs[#ps.jobs + 1] = { kind = "conflict", ch = g.ch, type = key, guids = list }
      return
    end
  end
  if #changed == 0 then return end
  local agreed_has = gt.agreed ~= nil and C.norm_has_line(gt.agreed)
  local rest = {}
  for _, m in ipairs(changed) do
    local n = norms[m]
    if agreed_has and not C.norm_has_line(n) then
      -- the line was removed on this track: never spread a removal (R10); others keep their line
      gt.last[m] = n
      notice_removed(st, io, ps, g, key, m)
    elseif agreed_has and gt.last[m] ~= nil and not C.norm_has_line(gt.last[m]) and n ~= gt.agreed then
      -- an emptied lane got a line again (e.g. lane shown again): it takes the group's line
      spread(st, io, gt, key, { m }, gt.achunk, gt.agreed)
    else
      rest[#rest + 1] = m
    end
  end
  if #rest == 0 then return end
  local first = norms[rest[1]]
  local all_same = true
  for i = 2, #rest do if norms[rest[i]] ~= first then all_same = false end end
  if all_same then
    local s = pick_source(ps, rest)
    local n = spread(st, io, gt, key, inc, chunks[s], norms[s], s)
    gt.last[s] = norms[s]
    settle_line(gt, norms[s], chunks[s])
    if n > 0 then gt.last_write = now end
  else
    -- R2: several tracks changed differently: never pick a silent winner
    gt.conflict = true
    local list = {}
    for _, m in ipairs(rest) do list[#list + 1] = m end
    table.sort(list, function(a, b)
      local ra, rb = ps.info[a], ps.info[b]
      local sa, sb = ra and ra.selected or false, rb and rb.selected or false
      if sa ~= sb then return sa end
      return (ra and ra.index or 1e9) < (rb and rb.index or 1e9)
    end)
    ps.jobs[#ps.jobs + 1] = { kind = "conflict", ch = g.ch, type = key, guids = list }
  end
end

------------------------------------------------------------------ tick
function M.tick(st, io)
  local cfg = st.cfg
  st.stats.ticks = st.stats.ticks + 1
  local now = io.now()
  local pkey = io.project()
  local ps = st.projects[pkey]
  if not ps then ps = new_ps(); st.projects[pkey] = ps end
  st.current = ps

  -- 1. marker scan + 2. debounce
  local recs = io.scan()
  local seen = {}
  for _, r in ipairs(recs) do
    seen[r.guid] = true
    ps.info[r.guid] = r
    local c = ps.cand[r.guid]
    if not c or c.ch ~= r.ch then c = { ch = r.ch, since = now }; ps.cand[r.guid] = c end
    local eff = ps.eff[r.guid]
    if eff ~= nil and eff ~= r.ch then leave(ps, r.guid); eff = nil end
    if eff == nil and r.ch ~= 0 and now - c.since >= cfg.debounce then
      ps.eff[r.guid] = r.ch
      ps.eff_seq = ps.eff_seq + 1
      ps.eff_t[r.guid] = ps.eff_seq
      local g = group(ps, r.ch)
      g.members[#g.members + 1] = r.guid
      g.joiners[r.guid] = true
    end
  end
  for guid in pairs(ps.info) do
    if not seen[guid] then leave(ps, guid); ps.cand[guid] = nil; ps.info[guid] = nil end
  end
  local counts, active = {}, {}
  for ch, g in pairs(ps.groups) do
    sort_members(ps, g.members)
    counts[ch] = #g.members
    local a = 0
    for _, T in ipairs(M.TYPES) do
      for _, m in ipairs(g.members) do
        if io.has_line(m, T.key) then a = a | (1 << T.bit); break end
      end
    end
    active[ch] = a
  end
  io.publish(counts, active)

  -- 3. HOLD
  local playing = io.playing()
  local override = io.override()
  if ps.was_playing and not playing then ps.settle = cfg.settle_ticks end
  ps.was_playing = playing
  local held = {}
  for ch, g in pairs(ps.groups) do held[ch] = is_held(st, ps, g, io, playing, override) end
  local settling = ps.settle > 0
  if settling then ps.settle = ps.settle - 1 end

  -- 4. undo / redo check (before any election)
  local u = io.undo()
  if ps.last_cur == nil then
    ps.last_cur, ps.last_sc = u.cur, u.sc
    if not hist_match(ps.hist[u.cur], u) then hist_new_entry(st, ps, u, false) end
  elseif u.sc ~= ps.last_sc then
    local known = hist_match(ps.hist[u.cur], u)
    -- a real undo lands on the entry that was "previous" a moment ago; an index that only went down because
    -- the undo list dropped old entries (memory full) lands on a brand-new entry instead
    local lu = ps.last_u
    local back = lu ~= nil and u.cur < ps.last_cur and u.desc == lu.pdesc and u.time == lu.ptime
    local restored = {}
    if known and u.cur ~= ps.last_cur then
      restored = hist_restore(st, io, ps, ps.hist[u.cur], held)
    elseif not known then
      -- a new action (prune the redo side) — or an undo to an entry we never saw (keep the redo side)
      hist_new_entry(st, ps, u, not back)
    end
    for ch, g in pairs(ps.groups) do
      for key, gt in pairs(g.t) do
        gt.dirty = true
        -- S1: moved back in the undo list and nothing restored: differing members are asked, never a silent pick
        if back and not restored[ch .. "|" .. key] then gt.careful = true end
      end
    end
  end
  ps.last_cur, ps.last_sc, ps.last_u = u.cur, u.sc, u

  -- 5. joins, fingerprints, round robin, election
  local order = {}
  for ch, g in pairs(ps.groups) do
    if #g.members == 0 and next(g.joiners) == nil then ps.groups[ch] = nil
    else order[#order + 1] = ch end
  end
  table.sort(order)
  local work = {}
  for _, ch in ipairs(order) do
    local g = ps.groups[ch]
    if not held[ch] and not settling then
      mask_step(st, io, ps, g)
      handle_joins(st, io, ps, g)
      pan_mode_rule(io, ps, g)
      for _, T in ipairs(M.TYPES) do
        if bit_on(g.mask, T) then
          local gt = g.t[T.key]
          if gt.activate then activate(st, io, ps, g, T.key) end
          if not gt.dirty then
            for _, m in ipairs(g.members) do
              if gt.fp[m] ~= io.fp(m, T.key) then gt.dirty = true; break end
            end
          end
          work[#work + 1] = { g = g, key = T.key }
        end
      end
    end
  end
  if #work > 0 then
    local dt = ps.last_now and math.max(0, math.min(1, now - ps.last_now)) or 0
    ps.rr_acc = ps.rr_acc + dt * cfg.rr_rate
    local n = math.min(#work, math.floor(ps.rr_acc))
    ps.rr_acc = ps.rr_acc - n
    for _ = 1, n do
      ps.rr = ps.rr % #work + 1
      local w = work[ps.rr]
      w.g.t[w.key].dirty = true
    end
  end
  ps.last_now = now
  local clock = io.clock or io.now
  local t0 = clock()
  local did = 0
  for _, w in ipairs(work) do
    local gt = w.g.t[w.key]
    if gt.dirty then
      if did > 0 and clock() - t0 > cfg.budget then break end
      gt.dirty = false
      elect(st, io, ps, w.g, w.key, now)
      did = did + 1
    end
  end

  -- 6. record the undo history entry for this position (once per group/type)
  hist_record(st, ps, u.cur, held)

  -- 7. dialogs: only when stopped, one per tick
  if not playing and #ps.jobs > 0 then
    local job = table.remove(ps.jobs, 1)
    run_job(st, io, ps, job)
  end
  return ps
end

return M
