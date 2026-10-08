--[[
  cl_params.lua — TUKONYA Chain Link: the per-slot sync engine (pure Lua, no REAPER calls).
  A group (one Link Ch) has slots: "c" = the container itself, 1..n = the container's items without the marker
  (matched by position; the group only links members whose idents agree, so slot k is the same plugin everywhere).
  Facets per slot: values (real params + Wet/Delta roles), bypass (by role, never TrackFX_SetEnabled), hidden state
  (vst_chunk, class "vst": when it spreads is decided by commit points in cl_blob.lua, DESIGN_V2 §2; the whole-state
  write itself — blob → every param → roles → bypass — is blob_write below, §3).
  Every REAPER access goes through `io` (see cl_core.lua for the contract).
--]]

local M = {}

-- parameter roles (REAPER appends 3 params after the plugin's own: bypass, Wet, Delta). Addressed as numparams + role.
M.BYP, M.WET, M.DLT = -3, -2, -1
M.TOL_SELF = 1e-6     -- "changed" (member vs its own last readback), SHOULD 1
M.TOL_CROSS = 5e-4    -- "equal" across members (Waves readback drift 3e-4 [M])

local function abs(x) return x < 0 and -x or x end
local function log(io, s) if io.log then io.log(s) end end

-- ------------------------------------------------------------------ slot construction
--- static per-plugin metadata, cached by ident|numparams for the session (MUST 11)
local function meta(st, io, mid, k, info)
  local key = info.ident .. "|" .. tostring(info.n) .. "|" .. info.class
  local m = st.meta[key]
  if not m then
    m = io.meta(mid, k)   -- { list = {p...}, tol_s = {p→}, tol_c = {p→}, nexcl = number }
    m.inlist = {}
    for _, p in ipairs(m.list) do m.inlist[p] = true end       -- P1_REVIEW MUST 5: only listed params are ever synced
    st.meta[key] = m
    st.stats.meta_reads = st.stats.meta_reads + 1
  end
  return m
end

--- build the slot table of a group from one member's resolution (all linked members share the sig).
--- The hidden-state table S.blob (per member: agreed blob, pending edit, holds — DESIGN_V2 §2) lives on the group per
--- (position, ident) and survives slot rebuilds, so a structure change elsewhere never drops a pending edit (§2 invariant).
function M.build(st, io, g, mid, res)
  g.slots, g.order = {}, {}
  g.bst = g.bst or {}
  for _, k in ipairs(res.order) do
    local info = res.slots[k]
    local bkey = tostring(k) .. "|" .. info.ident
    g.bst[bkey] = g.bst[bkey] or {}
    local S = { k = k, ident = info.ident, class = info.class, n = info.n, meta = meta(st, io, mid, k, info),
                last = {}, agreed = {}, hot = {}, fz = {}, frozen = {}, env = {}, dyn = {},
                byp = {}, byp_agreed = nil, blob = g.bst[bkey], rd = {}, pend = {}, pend_byp = {}, pend_blob = {},
                nmap = {}, cur = 1, selfq = {} }
    g.slots[k] = S
    g.order[#g.order + 1] = k
  end
end

--- forget everything about one member in this group's slots (it left, or its sig changed)
function M.forget(g, mid)
  if not g.slots then return end
  for _, S in pairs(g.slots) do
    S.last[mid] = nil; S.byp[mid] = nil; S.blob[mid] = nil; S.rd[mid] = nil; S.dyn[mid] = nil; S.nmap[mid] = nil
    S.pend[mid] = nil; S.pend_byp[mid] = nil; S.pend_blob[mid] = nil
  end
end

--- MUST 8: a member whose param count changed on a slot resets that slot's value tables (indices may have moved)
function M.shape_check(st, io, g, mid, res)
  for _, k in ipairs(g.order) do
    local S, info = g.slots[k], res.slots[k]
    if info and S.nmap[mid] ~= nil and S.nmap[mid] ~= info.n then
      log(io, ("Ch %d slot %s: param count %d -> %d, slot reset"):format(g.ch, tostring(k), S.nmap[mid], info.n))
      S.last, S.agreed, S.hot, S.fz, S.dyn = {}, {}, {}, {}, {}
      S.n = math.min(S.n, info.n)
      S.meta = meta(st, io, mid, k, info)
    end
    if info then S.nmap[mid] = info.n; S.n = math.min(S.n, info.n) end
  end
end

-- params of a slot that are value-synced right now (static list minus dynamic exclusions, real index < min n_real)
local function synced(S, p)
  if not S.meta.inlist[p] then return false end
  if S.frozen[p] or S.env[p] then return false end
  if p >= 0 and p >= S.n - 3 then return false end
  for _, d in pairs(S.dyn) do if d[p] then return false end end
  return true
end
M.synced = synced

local function tol_s(S, p) return S.meta.tol_s[p] or M.TOL_SELF end
local function tol_c(S, p) return S.meta.tol_c[p] or M.TOL_CROSS end

-- members that take part in slot S (linked, not timed out by the readiness gate)
local function slot_members(g, S)
  local out = {}
  for _, m in ipairs(g.members) do
    if g.linked[m] and not (S.rd[m] and S.rd[m].out) then out[#out + 1] = m end
  end
  return out
end
M.slot_members = slot_members

-- ------------------------------------------------------------------ readiness gate (MUST 2a)
--- an event (join, project load, undo/redo) opens a watch window: if the slot's readback changes inside it, the slot
--- is not ready until it has been still for `ready_window`; vst slots with an empty blob are not ready.
function M.event(S, mid, now, cfg)
  local rd = S.rd[mid]
  if not rd then rd = {}; S.rd[mid] = rd end
  rd.ev_until = now + cfg.ready_window
  rd.fp = nil; rd.fpx = nil
  rd.blobcheck = (S.class == "vst")
  rd.next_blob = 0
end

local function fingerprint(io, S, mid, rd)
  local list, t, n = S.meta.list, {}, 0
  if not rd.fpx then rd.fpx = io.dyn(mid, S.k, list, 1, math.min(#list, 48)) or {} end   -- P1_REVIEW MUST 3
  for i = 1, #list do
    local p = list[i]
    if p >= 0 and synced(S, p) and not rd.fpx[p] then
      n = n + 1
      t[n] = io.get(mid, S.k, p)
      if n >= 16 then break end
    end
  end
  return table.concat(t, ",")
end

--- @return ready (bool). Sets rd.out after `ready_timeout` of not being ready (member excluded from this slot).
function M.ready(st, io, g, S, mid, info, now, cfg)
  local rd = S.rd[mid]
  if not rd then rd = {}; S.rd[mid] = rd; M.event(S, mid, now, cfg) end
  local r = true
  if not info or info.offline then r = false end
  -- load failure: a plugin's params vanished (not for the container: its mapped params come and go, P1_REVIEW MUST 4)
  if info and S.class ~= "container" and info.n <= 3 and (rd.n_prev or 0) > 3 then r = false
  elseif info then rd.n_prev = info.n end
  if r and rd.blobcheck and now >= (rd.next_blob or 0) then
    rd.next_blob = now + cfg.blob_rate
    local b = io.blob(mid, S.k)
    st.stats.blob_reads = st.stats.blob_reads + 1
    rd.blob_empty = (b == nil or b == "")
    if not rd.blob_empty then rd.blobcheck = false end
  end
  if rd.blobcheck and rd.blob_empty then r = false end
  if r and rd.ev_until and now < rd.ev_until then
    local fp = fingerprint(io, S, mid, rd)
    if rd.fp and fp ~= rd.fp then rd.ev_until = now + cfg.ready_window; rd.unstable = true end
    rd.fp = fp
    if rd.unstable then r = false end
  elseif rd.ev_until and now >= rd.ev_until then
    rd.unstable = false; rd.ev_until = nil
  end
  if r then
    rd.nr_since = nil
    if rd.out then
      rd.out = false; rd.reenter = true
      log(io, ("Ch %d slot %s: %s ready again"):format(g.ch, tostring(S.k), mid))
    end
  else
    rd.nr_since = rd.nr_since or now
    if not rd.out and now - rd.nr_since >= cfg.ready_timeout then
      rd.out = true
      log(io, ("Ch %d slot %s: %s not ready after %.0f s, left out of this slot"):format(g.ch, tostring(S.k), mid, cfg.ready_timeout))
    end
  end
  rd.ok = r
  return r
end

-- ------------------------------------------------------------------ writes
--- a value/bypass write into (mid, slot): never touches the agreed blob (DESIGN_V2 §2.1, review R1b); it only explains a
--- blob change seen by a witness read (§2.4)
local function quiet_blob(S, mid, now, cfg)
  local b = S.blob[mid]
  if b then b.explained = now end
end
M.quiet_blob = quiet_blob

--- echo = true: a re-assert of the agreed value (does not restart the echo window, else a user who takes over on that
--- member would be reverted for as long as he drags)
local function write_param(st, io, S, mid, p, v, now, cfg, echo)
  local r = io.set(mid, S.k, p, v)
  st.stats.writes = st.stats.writes + 1
  quiet_blob(S, mid, now, cfg)
  if not echo then
    S.wr = S.wr or {}
    local w = S.wr[mid]; if not w then w = {}; S.wr[mid] = w end
    w[p] = now
  end
  return r
end

--- preset-loader params (soothe3 p143 "Program" loads a factory preset: 46 params change [M RESULTS_SOOTHE_REORDER §1a];
--- Waves "Bank"): never value-synced — the preset travels with the plugin state (hidden-state path)
function M.is_program_name(name)
  local l = (name or ""):lower():match("^%s*(.-)%s*$")
  if l == "program" or l == "bank" or l == "preset" or l == "programs" or l == "presets" then return true end
  if l:match("^program[%s_%-:]") or l:match("^bank[%s_%-:]") or l:match("^preset[%s_%-:]") then return true end
  return l:find("program change", 1, true) ~= nil or l:find("preset select", 1, true) ~= nil
end

-- ------------------------------------------------------------------ value election (§6.1, readback based)
--- tie-break among members that changed in the same tick: touched → focused → the member that changed most recently
--- before (a drag in progress; RESULTS_SOOTHE_REORDER §1c) → selected → track order
local function pick(members, set, ctx, k, recent)
  local t, f = ctx.touched, ctx.focused
  if t and set[t.mid] and (k == nil or t.k == k) then return t.mid end
  if f and set[f.mid] and (k == nil or f.k == k) then return f.mid end
  if recent then
    local best, bt = nil, -1e18
    for _, m in ipairs(members) do if set[m] and recent[m] and recent[m] > bt then best, bt = m, recent[m] end end
    if best and ctx.now - bt < 2.0 then return best end
  end
  for _, m in ipairs(members) do if set[m] and ctx.selected[m] then return m end end
  for _, m in ipairs(members) do if set[m] then return m end end   -- members are sorted by track index
end

M.pick = pick

--- elect one param p of slot S from the values v[m] just read on every member in `mem`
local function elect(st, io, g, S, p, v, mem, ctx)
  local now, cfg = ctx.now, ctx.cfg
  local ts, tc = tol_s(S, p), tol_c(S, p)
  local changed, cset, n = {}, {}, 0
  for _, m in ipairs(mem) do
    local lm = S.last[m]
    if not lm then lm = {}; S.last[m] = lm end
    local l = lm[p]
    local sq = S.selfq and S.selfq[m]
    if l == nil then lm[p] = v[m]
    elseif abs(v[m] - l) > ts and sq and now < sq.untl then
      -- DESIGN_V2 §3: moved within quiet_after_write of our own blob write = self-caused (LED re-runs its callbacks):
      -- never a source; the agreed value is written back, at most twice per write, then logged
      lm[p] = v[m]
      local a = S.agreed[p]
      if a ~= nil and abs(v[m] - a) > 1e-9 then              -- exact (LED auto gain rewrites Output a tick later)
        sq.n[p] = (sq.n[p] or 0) + 1
        if sq.n[p] <= 2 then lm[p] = write_param(st, io, S, m, p, a, now, cfg)
        elseif sq.n[p] == 3 then log(io, ("Ch %d slot %s p%d: %s keeps moving after our state write; left as it is"):format(g.ch, tostring(S.k), p, m)) end
      end
    elseif abs(v[m] - l) > ts and S.wr and S.wr[m] and S.wr[m][p] and now - S.wr[m][p] <= cfg.echo_window then
      -- echo guard: a target's readback departing within 300 ms of our own write is not a user change (stale readback,
      -- editor echo): the agreed value is re-asserted, nothing is elected (M2, RESULTS_SOOTHE_REORDER §1b)
      local a = S.agreed[p]
      if a ~= nil and abs(v[m] - a) > tc then lm[p] = write_param(st, io, S, m, p, a, now, cfg, true) else lm[p] = v[m] end
    elseif abs(v[m] - l) > ts then n = n + 1; changed[n] = m; cset[m] = true end
  end
  if n == 0 then return false end
  -- source lock: the member that is changing p keeps the lead until lock_hold after its last change; changes on other
  -- members inside that window are echoes (overwritten with the leader's value, never elected)
  S.lock = S.lock or {}
  local lk = S.lock[p]
  if lk and (now - lk.t > cfg.lock_hold or not v[lk.m]) then lk = nil; S.lock[p] = nil end
  if lk and not cset[lk.m] then
    local a = S.agreed[p]
    for i = 1, n do
      local m = changed[i]
      if a ~= nil and abs(v[m] - a) > tc then S.last[m][p] = write_param(st, io, S, m, p, a, now, cfg, true) else S.last[m][p] = v[m] end
    end
    return false
  end
  for i = 1, n do local b = S.blob[changed[i]]; if b then b.explained = now end end   -- a param change explains a blob change (§2.4)
  local winner
  S.mt = S.mt or {}
  if lk then winner = lk.m
  elseif n == 1 then winner = changed[1]
  else
    local same = true
    for i = 2, n do if abs(v[changed[i]] - v[changed[1]]) > tc then same = false; break end end
    winner = pick(mem, cset, ctx, S.k, S.mt)
    if not same then
      st.stats.conflicts = st.stats.conflicts + 1
      log(io, ("Ch %d slot %s p%d: %d members changed differently, %s wins"):format(g.ch, tostring(S.k), p, n, winner))
    end
  end
  local w = v[winner]
  local held_lock = lk ~= nil
  S.lock[p] = { m = winner, t = now }
  S.mt[winner] = now
  for i = 1, n do S.last[changed[i]][p] = v[changed[i]] end
  S.agreed[p] = w
  S.hot[p] = now + cfg.hot_time
  S.last_src, S.last_src_t = winner, now
  for _, m in ipairs(mem) do
    if m ~= winner and v[m] ~= w and not (cset[m] and abs(v[m] - w) <= tc) then
      if ctx.held[m] then S.pend[m] = true
      else S.last[m][p] = write_param(st, io, S, m, p, w, now, cfg) end
    end
  end
  -- freeze (§6.2 + SHOULD 3): without a user hint on the elected member (touched param or focused FX), a param whose
  -- source keeps alternating (ping-pong) or that keeps changing by itself (meters, self-moving) is frozen for the session
  local fz = S.fz[p]
  if not fz or now - fz.t0 > 2.0 then fz = { t0 = now, alt = 0, n = 0, src = winner }; S.fz[p] = fz end
  local t, f = ctx.touched, ctx.focused
  local hinted = (t and t.mid == winner and t.k == S.k) or (f and f.mid == winner and f.k == S.k)
  -- a continuous drag by the lock holder with a window showing that plugin is a user, not a self-moving param (M1)
  local info = ctx.res and ctx.res[winner] and ctx.res[winner].slots[S.k]
  local window = info and (info.open or info.chain)
  if held_lock and window then hinted = true end
  if not hinted then
    fz.n = fz.n + 1
    if fz.src ~= winner then fz.alt = fz.alt + 1 end
  end
  fz.src = winner
  if fz.alt >= 3 or fz.n >= cfg.freeze_n then
    S.frozen[p] = true
    st.stats.frozen = st.stats.frozen + 1
    log(io, ("Ch %d slot %s p%d frozen (%s)"):format(g.ch, tostring(S.k), p, fz.alt >= 3 and "bounces between tracks" or "keeps changing by itself"))
  end
  return true
end
M.elect = elect

--- read p on every member of the slot and elect
local function check(st, io, g, S, p, mem, ctx)
  local v = {}
  for _, m in ipairs(mem) do v[m] = io.get(m, S.k, p) end
  st.stats.reads = st.stats.reads + #mem
  return elect(st, io, g, S, p, v, mem, ctx)
end
M.check = check

--- hot params of a slot (recently changed, or last touched by the user): every tick
function M.hot(st, io, g, S, mem, ctx)
  local t = ctx.touched
  if t and t.k == S.k and g.linked[t.mid] then
    local key = t.mid .. "|" .. t.p
    if S.dyn_t ~= key and t.p >= 0 and S.meta.inlist[t.p] then          -- SHOULD 6: modulation of the touched param now
      S.dyn_t = key
      for _, m in ipairs(mem) do
        local d = S.dyn[m] or {}; S.dyn[m] = d
        d[t.p] = (io.dyn(m, S.k, { t.p }, 1, 1) or {})[t.p] or nil
      end
    end
    if S.frozen[t.p] and S.meta.inlist[t.p] then                        -- SHOULD 1: a hinted edit unfreezes
      local v = io.get(t.mid, S.k, t.p)
      local l = S.last[t.mid] and S.last[t.mid][t.p]
      if l and abs(v - l) > tol_s(S, t.p) then
        S.frozen[t.p] = nil; S.fz[t.p] = nil
        log(io, ("Ch %d slot %s p%d unfrozen (user edit)"):format(g.ch, tostring(S.k), t.p))
      end
    end
    if synced(S, t.p) then S.hot[t.p] = math.max(S.hot[t.p] or 0, ctx.now + 0.05) end
  end
  for p, untl in pairs(S.hot) do
    if untl < ctx.now then S.hot[p] = nil
    elseif synced(S, p) then check(st, io, g, S, p, mem, ctx) end
  end
end

--- an open or focused plugin window: read its params on that member every tick (a user is probably editing there);
--- a change found there is elected across all members at once
function M.watch(st, io, g, S, mem, ctx)
  local f = ctx.focused
  for _, m in ipairs(mem) do
    local info = ctx.res[m] and ctx.res[m].slots[S.k]
    if (info and info.open) or (f and f.mid == m and f.k == S.k) then
      local list, lm = S.meta.list, S.last[m]
      if lm then
        local n = #list
        local cnt = math.min(n, ctx.cfg.watch_max)
        S.wcur = S.wcur or {}
        local i = S.wcur[m] or 1
        for _ = 1, cnt do
          if i > n then i = 1 end
          local p = list[i]
          i = i + 1
          if synced(S, p) and not S.hot[p] and lm[p] ~= nil then
            local v = io.get(m, S.k, p)
            st.stats.reads = st.stats.reads + 1
            if abs(v - lm[p]) > tol_s(S, p) then check(st, io, g, S, p, mem, ctx) end
          end
        end
        S.wcur[m] = i
      end
    end
  end
end

--- cold sweep: params list[i0..i1] of slot S
function M.sweep(st, io, g, S, mem, ctx, i0, i1)
  local list = S.meta.list
  for i = i0, math.min(i1, #list) do
    local p = list[i]
    if synced(S, p) and not S.hot[p] then check(st, io, g, S, p, mem, ctx) end
  end
end

-- ------------------------------------------------------------------ bypass facet (by role)
function M.bypass(st, io, g, S, mem, ctx)
  if S.env[M.BYP] or S.byp_frozen then return end      -- P1_REVIEW MUST 7: a bypass lane drives it / ping-pong frozen
  local e, changed, cset, n = {}, {}, {}, 0
  for _, m in ipairs(mem) do
    e[m] = io.enabled(m, S.k)
    if S.byp[m] == nil then S.byp[m] = e[m]
    elseif S.byp[m] ~= e[m] then n = n + 1; changed[n] = m; cset[m] = true end
  end
  if n == 0 then
    if S.byp_agreed == nil and #mem > 0 then S.byp_agreed = e[mem[1]] end
    return
  end
  local winner = (n == 1) and changed[1] or pick(mem, cset, ctx, S.k)
  local w = e[winner]
  S.byp_agreed = w
  -- freeze: the source alternates between members ≥ 3 times within 2 s without a user hint on it
  local t, f = ctx.touched, ctx.focused
  local hinted = (t and t.mid == winner and t.k == S.k) or (f and f.mid == winner and f.k == S.k)
  local bz = S.bfz
  if not bz or ctx.now - bz.t0 > 2.0 then bz = { t0 = ctx.now, alt = 0, src = winner }; S.bfz = bz end
  if not hinted and bz.src ~= winner then bz.alt = bz.alt + 1 end
  bz.src = winner
  if bz.alt >= 3 then
    S.byp_frozen = true
    st.stats.frozen = st.stats.frozen + 1
    log(io, ("Ch %d slot %s bypass frozen (bounces between tracks)"):format(g.ch, tostring(S.k)))
    return
  end
  for i = 1, n do S.byp[changed[i]] = e[changed[i]] end
  for _, m in ipairs(mem) do
    if e[m] ~= w then
      if ctx.held[m] then S.pend_byp[m] = true
      else
        S.byp[m] = io.set_bypass(m, S.k, not w)
        st.stats.byp_writes = st.stats.byp_writes + 1
        quiet_blob(S, m, ctx.now, ctx.cfg)
      end
    end
  end
end

-- ------------------------------------------------------------------ align one member to another (joins, re-entry)
--- copy src's state of slot S onto dst: blob first (vst), then values verified against src (MUST 6), bypass
function M.align_slot(st, io, g, S, src, dst, ctx, with_blob)
  local now, cfg = ctx.now, ctx.cfg
  local blob_written = false
  if with_blob and S.class == "vst" then
    local b = io.blob(src, S.k)
    if b and b ~= "" then
      M.blob_write(st, io, g, S, src, dst, b, ctx)       -- whole state: blob → all params → roles → bypass (§3)
      return
    end
  end
  S.last[src] = S.last[src] or {}
  S.last[dst] = S.last[dst] or {}
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) then
      local vs, vd = io.get(src, S.k, p), io.get(dst, S.k, p)
      local lim = blob_written and tol_c(S, p) or 0
      if abs(vd - vs) > lim then vd = write_param(st, io, S, dst, p, vs, now, cfg) end
      S.last[src][p] = vs; S.last[dst][p] = vd; S.agreed[p] = vs
    end
  end
  local es, ed = io.enabled(src, S.k), io.enabled(dst, S.k)
  if es ~= ed then ed = io.set_bypass(dst, S.k, not es); st.stats.byp_writes = st.stats.byp_writes + 1 end
  S.byp[src], S.byp[dst], S.byp_agreed = es, ed, es
  quiet_blob(S, dst, now, cfg)
end

--- number of differing synced values/bypass between members a and b (cross tolerance); used for joins
function M.diff(st, io, g, a, b)
  local n, first = 0, nil
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    if not ((S.rd[a] and S.rd[a].out) or (S.rd[b] and S.rd[b].out)) then
      for _, p in ipairs(S.meta.list) do
        if synced(S, p) then
          local va, vb = io.get(a, k, p), io.get(b, k, p)
          st.stats.reads = st.stats.reads + 2
          if abs(va - vb) > tol_c(S, p) then n = n + 1; first = first or (tostring(k) .. ":" .. p) end
        end
      end
      if io.enabled(a, k) ~= io.enabled(b, k) then n = n + 1; first = first or (tostring(k) .. ":bypass") end
    end
  end
  return n, first
end

--- the differing synced values/bypass between a and b, for the log (at most `max`): { {k, p, va, vb}, ... }
function M.diff_detail(st, io, g, a, b, max)
  local out = {}
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    if not ((S.rd[a] and S.rd[a].out) or (S.rd[b] and S.rd[b].out)) then
      for _, p in ipairs(S.meta.list) do
        if synced(S, p) then
          local va, vb = io.get(a, k, p), io.get(b, k, p)
          if abs(va - vb) > tol_c(S, p) and #out < max then out[#out + 1] = { k = k, p = p, va = va, vb = vb } end
        end
      end
      local ea, eb = io.enabled(a, k), io.enabled(b, k)
      if ea ~= eb and #out < max then out[#out + 1] = { k = k, p = "bypass", va = ea and 1 or 0, vb = eb and 1 or 0 } end
    end
  end
  return out
end

--- number of differing synced values/bypass of one slot between members a and b (cross tolerance)
function M.slot_diff(st, io, S, a, b)
  local n = 0
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) and abs(io.get(a, S.k, p) - io.get(b, S.k, p)) > tol_c(S, p) then n = n + 1 end
  end
  st.stats.reads = st.stats.reads + 2 * #S.meta.list
  if io.enabled(a, S.k) ~= io.enabled(b, S.k) then n = n + 1 end
  return n
end

--- a member that is now linked: take its current readbacks as its baseline (no change detected on the next read)
function M.adopt(io, g, mid)
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    local lm = {}
    for _, p in ipairs(S.meta.list) do if synced(S, p) then lm[p] = io.get(mid, k, p) end end
    S.last[mid] = lm
    S.byp[mid] = io.enabled(mid, k)
  end
end

-- ------------------------------------------------------------------ hidden state (vst_chunk): whole-state write
-- (the commit-point trigger that decides WHEN a member's state spreads is cl_blob.lua, DESIGN_V2 §2)

--- after a write of t's whole state (our blob write, LINK, a restore that wrote a blob): t's agreed blob is re-taken from
--- its own read ≥ quiet_after_write later (cl_blob), or = the written blob if a js press / watch transition happened in
--- between (§2.1, review R1d). Held inbound writes and pending marks of t end here (an explicit whole-state write).
function M.mark_written(S, t, blob, now, cfg)
  local B = S.blob[t]
  if not B then B = {}; S.blob[t] = B end
  B.quiet_until = now + cfg.quiet_after_write
  B.wrote = blob
  B.quiet_keep = false
  B.pending = false
  B.held = nil
  B.explained = now
  S.selfq = S.selfq or {}
  S.selfq[t] = { untl = now + cfg.quiet_after_write, n = {} }
end

--- DESIGN_V2 §3: blob, then EVERY listed host param from the source's current readback (a param whose inbound write to
--- the source is held takes the agreed value), roles (Wet/Delta are the last list entries), then bypass.
function M.blob_write(st, io, g, S, src, t, blob, ctx)
  local now, cfg = ctx.now, ctx.cfg
  io.set_blob(t, S.k, blob)
  st.stats.blob_writes = st.stats.blob_writes + 1
  local lt = S.last[t] or {}
  S.last[t] = lt
  local held_in = S.pend[src]
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) then
      local v
      if held_in and S.agreed[p] ~= nil then v = S.agreed[p] else v = io.get(src, S.k, p) end
      lt[p] = write_param(st, io, S, t, p, v, now, cfg)
      S.agreed[p] = v
      if S.last[src] then S.last[src][p] = S.last[src][p] or v end
    end
  end
  local es = (S.pend_byp[src] and S.byp_agreed ~= nil) and S.byp_agreed or io.enabled(src, S.k)
  local et = io.enabled(t, S.k)
  if et ~= es then et = io.set_bypass(t, S.k, not es); st.stats.byp_writes = st.stats.byp_writes + 1 end
  S.byp[t] = et
  M.mark_written(S, t, blob, now, cfg)
end

-- ------------------------------------------------------------------ flush after stop
function M.flush(st, io, g, S, mem, ctx)
  for m in pairs(S.pend) do
    if not ctx.held[m] then
      local lm = S.last[m] or {}
      for p, a in pairs(S.agreed) do
        if synced(S, p) then
          local v = io.get(m, S.k, p)
          if lm[p] ~= nil and abs(v - lm[p]) <= tol_s(S, p) and abs(v - a) > tol_c(S, p) then
            lm[p] = write_param(st, io, S, m, p, a, ctx.now, ctx.cfg)
          end
        end
      end
      S.pend[m] = nil
    end
  end
  for m in pairs(S.pend_byp) do
    if not ctx.held[m] then
      if S.byp_agreed ~= nil and io.enabled(m, S.k) ~= S.byp_agreed then
        S.byp[m] = io.set_bypass(m, S.k, not S.byp_agreed)
        st.stats.byp_writes = st.stats.byp_writes + 1
      end
      S.pend_byp[m] = nil
    end
  end
  for m, src in pairs(S.pend_blob) do
    if not ctx.held[m] then
      local b = io.blob(src, S.k)
      if b and b ~= "" and not (S.blob[m] and S.blob[m].pending) then M.blob_write(st, io, g, S, src, m, b, ctx)
      elseif b and b ~= "" then S.blob[m].held = { src = src, blob = b, js = false, t = ctx.now } end   -- never over a pending edit (R3)
      S.pend_blob[m] = nil
    end
  end
end

-- ------------------------------------------------------------------ dynamic exclusions
--- refresh mod/plink/acs flags of member m for list[i0..i1] (round robin, MUST 11)
function M.dyn_refresh(st, io, S, m, i0, i1)
  local list = S.meta.list
  local d = S.dyn[m]
  if not d then d = {}; S.dyn[m] = d end
  local act = io.dyn(m, S.k, list, i0, math.min(i1, #list))
  st.stats.dyn_reads = st.stats.dyn_reads + (math.min(i1, #list) - i0 + 1)
  for i = i0, math.min(i1, #list) do d[list[i]] = act[list[i]] or nil end
end

return M
