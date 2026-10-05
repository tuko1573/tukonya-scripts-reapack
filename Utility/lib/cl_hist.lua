--[[
  cl_hist.lua — TUKONYA Chain Link: undo-history guard (pure Lua). Pattern from Auto Link al_core hist_* (M2/M3 rules).

  Why: REAPER's undo restores per-track snapshots; a silent sync is folded into the wrong snapshot. Ctrl+Z after a
  structure sync reverts only the source (P0-1 i); after an unrelated undo point it reverts only the synced target
  (P0-1 ii). The guard records, per undo entry and Ch, what the members agreed on, and after an undo/redo onto a known
  entry brings every member back to that record — but only if some member of the record still carries it.

  Record (once per entry and Ch, never overwritten): { members = {mid→true}, sig, slots = {[k] = {ident, list, vals, byp}} }
  vals = string.pack'd doubles in meta.list order (NaN = not synced at record time). Taken only after a full cold sweep
  of every slot that started after the entry appeared and after that slot became ready, with every member agreeing (MUST 1).
  Restore = a per-Ch plan applied when allowed (MUST 3): structure first (block copy from a carrier whose state is
  loaded, never while recording — MUST 2, 10), then values/bypass once every slot is ready and its readiness window has
  closed (MUST 2b). Members outside the record that differ are declined, never sources (MUST 4).
--]]

local P = require("cl_params")
local ENV = require("cl_env")
local H = {}

local NAN = 0 / 0
local function abs(x) return x < 0 and -x or x end
local function log(io, s) if io.log then io.log(s) end end

-- ------------------------------------------------------------------ entries (M3: own desc/time + previous desc/time)
function H.match(h, u)
  return h ~= nil and h.desc == u.desc and h.time == u.time and h.pdesc == u.pdesc and h.ptime == u.ptime
end

function H.new_entry(st, ps, u, prune)
  if prune then for i in pairs(ps.hist) do if i >= u.cur then ps.hist[i] = nil end end end
  -- names[ch] = the container name the Ch's members agreed on at this entry (cl_core name_step; "" = unnamed, nil = none)
  ps.hist[u.cur] = { desc = u.desc, time = u.time, pdesc = u.pdesc, ptime = u.ptime, ch = {}, names = {} }
  local lim = u.cur - st.cfg.hist_max
  for i in pairs(ps.hist) do if i < lim then ps.hist[i] = nil end end
end

-- ------------------------------------------------------------------ packing
local function pack(list, val)
  local t = {}
  for i = 1, #list do t[i] = string.pack("d", val(list[i])) end
  return table.concat(t)
end
local function unpack_at(s, i) return (string.unpack("d", s, (i - 1) * 8 + 1)) end
H.unpack_at = unpack_at

-- ------------------------------------------------------------------ record (MUST 1)
--- is the Ch settled enough to be recorded for the current entry? returns ok, reason
function H.settled(g, ctx)
  if g.restore then return false, "restore pending" end
  if g.link_lanes then return false, "LINK lanes pending" end
  if not g.slots or not g.agreed_sig then return false, "no slots" end
  if next(g.post_align) or next(g.adopt) then return false, "aligning" end
  local n = 0
  for m in pairs(g.linked) do
    n = n + 1
    local r = ctx.res[m]
    if not r or r.sig ~= g.agreed_sig then return false, "structure pending" end
  end
  if n < 2 then return false, "single member" end
  if not ENV.settled(g) then return false, "lanes" end
  -- INVARIANT (MUST 1, per slot): a value may enter a record only if it was read after the slot became ready AND after
  -- the current entry appeared. Each slot counts its own cold-sweep units (cl_core step 5); its mark is reset on every
  -- undo-position move / new entry and on every tick the slot is not swept (suspended, not ready, < 2 members). A count
  -- per group is NOT enough: another slot's sweeps satisfied it while this slot was suspended, and its stale readback
  -- (from before REAPER's redo) became the record (DEVLOG 2026-10-02 14:10–, MBP v2_undoredo E2). Do not optimize back.
  local chunk = ctx.cfg and ctx.cfg.sweep_chunk or 32
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    if S.suspended or not S.mem then return false, "suspended" end
    local nu = math.ceil(#S.meta.list / chunk)
    if nu > 0 and #S.mem >= 2 and (S.swept or 0) - (S.rec_mark or 0) < nu + 1 then return false, "sweep not done" end
    if next(S.pend) or next(S.pend_byp) or next(S.pend_blob) then return false, "held writes" end
    -- DESIGN_V2 §3 / review MUST 5: records hold no blob data and do not wait for hidden-state commits
    local m0 = S.mem[1]
    if m0 then
      local l0 = S.last[m0]
      if not l0 then return false, "no readback" end
      for i = 2, #S.mem do
        local m = S.mem[i]
        local lm = S.last[m]
        if not lm then return false, "no readback" end
        if S.byp[m] ~= S.byp[m0] then return false, "bypass differs" end
        for _, p in ipairs(S.meta.list) do
          if P.synced(S, p) then
            local a, b = l0[p], lm[p]
            if a == nil or b == nil then return false, "no readback" end
            if abs(a - b) > (S.meta.tol_c[p] or P.TOL_CROSS) then return false, "values differ" end
          end
        end
      end
    end
  end
  return true
end

function H.record(st, io, ps, g, ctx)
  local h = ps.hist[ctx.cur]
  if not h or h.ch[g.ch] ~= nil then return end
  local ok = H.settled(g, ctx)
  if not ok then return end
  local rec = { members = {}, sig = g.agreed_sig, slots = {}, env = ENV.record(g) }
  for m in pairs(g.linked) do rec.members[m] = true end
  local prev = g.last_rec
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    local m0 = S.mem[1]
    local l0 = S.last[m0]
    local vals = pack(S.meta.list, function(p) if P.synced(S, p) and l0[p] ~= nil then return l0[p] end; return NAN end)
    local pk = prev and prev.slots[k]
    if pk and pk.vals == vals and pk.ident == S.ident then vals = pk.vals end   -- share the older string (memory)
    rec.slots[k] = { ident = S.ident, list = S.meta.list, vals = vals, byp = S.byp[m0] }
  end
  -- the container block itself, only when the content changed since the last record (shared otherwise): used when an
  -- undo leaves no member carrying the recorded content (a member reverted by REAPER to a pre-sync snapshot while the
  -- record's source was itself rewritten later — e.g. add FX on B, move FX on C, Ctrl+Z ×2)
  if prev and prev.sig == rec.sig and prev.block then rec.block = prev.block
  elseif io.read_block then
    rec.block = io.read_block(g.order and next(g.linked) and (function() for _, m in ipairs(g.members) do if g.linked[m] then return m end end end)())
    if rec.block then rec.block.sig = rec.sig end
  end
  h.ch[g.ch] = rec
  g.last_rec = rec
  st.stats.records = st.stats.records + 1
end

-- ------------------------------------------------------------------ a new entry dropped an unapplied plan (fix B)
--- REAPER had already applied the plan's entry to the tracks, but the elections waited while the plan was pending, so
--- S.last still holds the readback from before that undo/redo. The plan's record is the state the members were meant to
--- be in → it becomes every linked member's baseline (values, bypass, agreed); whoever departs from it now — the user's
--- new edit, or a member REAPER's per-track restore left behind — is a change as usual (one changed → it is the source;
--- several → touched → focused → selected → lowest track). A slot the record does not cover (no record for it, other
--- content): its baseline is cleared (fresh re-read) and S.resolve asks cl_core to align the members once by that same
--- tie-break. Returns slots re-baselined from the record, slots re-read.
function H.rebaseline(g, plan)
  if not g.slots then return 0, 0 end
  local rec = plan and plan.rec
  local same = rec ~= nil and g.agreed_sig == rec.sig
  local nr, nf = 0, 0
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    local rk = same and rec.slots[k] or nil
    S.hot, S.lock = {}, {}
    if rk and rk.ident == S.ident then
      local base = {}
      for i, p in ipairs(rk.list) do local v = unpack_at(rk.vals, i); if v == v then base[p] = v end end
      for _, m in ipairs(g.members) do
        if g.linked[m] then
          local lm = {}
          for p, v in pairs(base) do lm[p] = v end
          S.last[m] = lm
          if rk.byp ~= nil then S.byp[m] = rk.byp end
        end
      end
      S.agreed = base
      if rk.byp ~= nil then S.byp_agreed = rk.byp end
      nr = nr + 1
    else
      S.last = {}
      S.resolve = true
      nf = nf + 1
    end
  end
  return nr, nf
end

-- ------------------------------------------------------------------ restore, stage 1: structure
--- returns "wait" | "wrote" | "ok" | "drop"
function H.restore_struct(st, io, ps, g, ctx, write_struct, decline)
  local plan, cfg = g.restore, st.cfg
  local rec = plan.rec
  if ctx.settling then return "wait" end
  for m in pairs(rec.members) do if ctx.held[m] then return "wait" end end      -- MUST 3: keep the plan, apply later
  local need, carrier = {}, nil
  for _, m in ipairs(g.members) do
    local r = ctx.res[m]
    if r then
      if rec.members[m] then
        if r.sig == rec.sig then
          if not carrier or (not io.struct_ready(carrier) and io.struct_ready(m)) then carrier = m end
        elseif plan.wrote and plan.wrote[m] then
          decline(g, m, "undo restore: our structure write did not take")       -- never rewrite in a loop (MUST 4)
        else need[#need + 1] = m end
      elseif r.sig ~= rec.sig and g.linked[m] then
        decline(g, m, "not in the undo record, content differs")             -- MUST 4
      end
    end
  end
  if #need == 0 then
    for m in pairs(rec.members) do
      if ctx.res[m] and ctx.res[m].sig == rec.sig and not ps.declined[m .. "|" .. g.ch] then g.linked[m] = true end
    end
    if g.agreed_sig ~= rec.sig then g.agreed_sig = rec.sig; g.slots = nil; g.rebuilt = true end
    return "ok"
  end
  if not carrier and not rec.block then
    log(io, ("Ch %d: undo record (structure) carried by no member — normal rules"):format(g.ch))
    st.stats.restore_nocarrier = st.stats.restore_nocarrier + 1
    return "drop"
  end
  if ctx.recording then return "wait" end                                       -- MUST 10
  if ctx.playing and not cfg.costly_while_playing then return "wait" end         -- the flag applies to restores too
  plan.wrote = plan.wrote or {}
  for _, m in ipairs(need) do plan.wrote[m] = true end
  if carrier then
    if not io.struct_ready(carrier) and ctx.now - plan.t0 < cfg.src_wait then return "wait" end   -- MUST 2
    write_struct(carrier, need, "undo/redo", false)
  else
    -- nobody carries the recorded content: write the record's own block (values then follow the record exactly)
    write_struct(rec.block, need, "undo/redo from the record", false)
    plan.trust = true
    st.stats.restores_from_record = st.stats.restores_from_record + 1
  end
  for m in pairs(rec.members) do if ctx.res[m] and not ps.declined[m .. "|" .. g.ch] then g.linked[m] = true end end
  g.agreed_sig = rec.sig
  st.stats.restores_struct = st.stats.restores_struct + 1
  return "wrote"
end

-- ------------------------------------------------------------------ restore, stage 2: values and bypass
--- returns "wait" | "done"
function H.restore_values(st, io, ps, g, ctx, decline)
  local rec = g.restore.rec
  if ctx.settling then return "wait" end
  if not g.slots or g.agreed_sig ~= rec.sig then return "done" end
  local now = ctx.now
  local mem = {}
  for _, m in ipairs(g.members) do if g.linked[m] then mem[#mem + 1] = m end end
  -- every slot of every member ready, readiness window closed (MUST 2b), nobody held (MUST 3)
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    for _, m in ipairs(mem) do
      local rd = S.rd[m]
      if ctx.held[m] then return "wait" end
      if not (rd and rd.out) then
        if not (rd and rd.ok) or (rd.ev_until and now < rd.ev_until) then return "wait" end
      end
    end
  end
  local wrote = 0
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    local rk = rec.slots[k]
    if rk and rk.ident == S.ident then
      local smem = {}
      for _, m in ipairs(mem) do if not (S.rd[m] and S.rd[m].out) then smem[#smem + 1] = m end end
      -- RECORD-FIRST (main thread 2026-10-02, MBP RESULTS_V2 (3)): after REAPER's undo/redo every member can hold the same
      -- wrong state (a lossy blob quantises LED Ratio everywhere; a param whose lane the undo removed keeps the lane's last
      -- value on every track) — the record is then the only exact copy. Every recorded value is written to every record
      -- member that differs; a param is skipped only on a member that itself has an active lane or modulation on it now.
      local idx = {}
      for i, p in ipairs(rk.list) do
        local v = unpack_at(rk.vals, i)
        if v == v and S.meta.inlist[p] and not S.frozen[p] and not (p >= 0 and p >= S.n - 3) then
          idx[#idx + 1] = { p = p, v = v, tol = S.meta.tol_c[p] or P.TOL_CROSS }
        end
      end
      local skip = {}
      for _, m in ipairs(smem) do
        local ed = io.env_driven and io.env_driven(m) or {}
        local sk = {}
        for p in pairs(ed[k] or {}) do sk[p] = true end
        for p in pairs(S.dyn[m] or {}) do sk[p] = true end
        skip[m] = sk
      end
      local diff, cur = {}, {}
      for _, m in ipairs(smem) do
        local c, d = {}, false
        for j, e in ipairs(idx) do
          c[j] = io.get(m, k, e.p)
          if not skip[m][e.p] and abs(c[j] - e.v) > 1e-9 then d = true end
        end
        cur[m], diff[m] = c, d
      end
      st.stats.reads = st.stats.reads + #smem * #idx
      -- a member carrying the whole slot (within tolerance) lends its hidden state first (SHOULD 4 b)
      local carrier
      for _, m in ipairs(smem) do
        if rec.members[m] then
          local all = true
          for j, e in ipairs(idx) do if not skip[m][e.p] and abs(cur[m][j] - e.v) > e.tol then all = false; break end end
          if all then carrier = m; break end
        end
      end
      for _, t in ipairs(smem) do
        if diff[t] then
          if not rec.members[t] then
            local far = false
            for j, e in ipairs(idx) do if not skip[t][e.p] and abs(cur[t][j] - e.v) > e.tol then far = true end end
            if far then decline(g, t, "not in the undo record, values differ") end
          else
            if carrier and carrier ~= t and S.class == "vst" then
              local b = io.blob(carrier, k)
              if b and b ~= "" then
                io.set_blob(t, k, b); st.stats.blob_writes = st.stats.blob_writes + 1
                P.mark_written(S, t, b, now, st.cfg)          -- only a slot that got a blob re-takes its agreed (§2.1)
              end
            end
            for j, e in ipairs(idx) do
              if not skip[t][e.p] then
                local v = io.get(t, k, e.p)
                if abs(v - e.v) > 1e-9 then io.set(t, k, e.p, e.v); st.stats.writes = st.stats.writes + 1; wrote = wrote + 1 end
              end
            end
          end
        end
      end
      S.last, S.hot, S.agreed = {}, {}, {}
      for _, e in ipairs(idx) do S.agreed[e.p] = e.v end
      -- bypass
      if rk.byp ~= nil then
        local bc
        for _, m in ipairs(smem) do if rec.members[m] and io.enabled(m, k) == rk.byp then bc = m; break end end
        if bc then
          for _, t in ipairs(smem) do
            if io.enabled(t, k) ~= rk.byp then
              if not rec.members[t] then decline(g, t, "not in the undo record, bypass differs")
              else io.set_bypass(t, k, not rk.byp); st.stats.byp_writes = st.stats.byp_writes + 1; wrote = wrote + 1 end
            end
          end
          S.byp = {}; S.byp_agreed = rk.byp
        end
      end
    end
  end
  st.stats.restores = st.stats.restores + 1
  log(io, ("Ch %d: undo record restored (%d writes)"):format(g.ch, wrote))
  return "done"
end

return H
