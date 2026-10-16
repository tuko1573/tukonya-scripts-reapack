--[[
  cl_params.lua — TUKONYA Chain Link: the per-slot sync engine (pure Lua, no REAPER calls).
  A group (one Link Ch) has slots: "c" = the container itself, 1..n = the container's items without the marker
  (matched by position; the group only links members whose idents agree, so slot k is the same plugin everywhere).
  Facets per slot: values (real params + Wet/Delta roles), bypass (by role, never TrackFX_SetEnabled), hidden state
  (vst_chunk, class "vst": when it spreads is decided by commit points in cl_blob.lua, DESIGN_V2 §2; the whole-state
  write itself — blob → every param → roles → bypass — is blob_write below, §3).
  Every REAPER access goes through `io` (see cl_core.lua for the contract).
--]]

local LAG = require("cl_lag")
local M = {}

-- parameter roles (REAPER appends 3 params after the plugin's own: bypass, Wet, Delta). Addressed as numparams + role.
M.BYP, M.WET, M.DLT = -3, -2, -1
M.TOL_SELF = 1e-6     -- "changed" (member vs its own last readback), SHOULD 1
M.TOL_CROSS = 5e-4    -- "equal" across members (Waves readback drift 3e-4 [M])
M.LAG_MIN_DIFF = 0.02 -- a readback difference must be at least this big to count as evidence of a lagging plugin: a plugin that
                      -- quantises a value when it restores its state (soothe3 p72 0.686 -> 0.714 [M tests/probes/RESULTS_LAG_SEED.md]) follows its state

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

-- ------------------------------------------------------------------ lagging plugins (cl_lag; one rule, one chokepoint)
--- the lagging store (seed + Data/TUKONYA_ChainLink/lag_class.txt), loaded once per core state. S.lagset points at it, so a
--- plugin learned at runtime is lagging in every group at once (no per-slot copy).
local function lagstore(st, io)
  if not st.lag then st.lag = LAG.parse(io.lag_load and io.lag_load() or nil) end
  return st.lag
end
M.lagstore = lagstore
local function save_lag(st, io)
  local s = st.lag
  if s and s.dirty and io.lag_save then io.lag_save(LAG.serialize(s)); s.dirty = false end
end

--- true: the slot's own params (p >= 0) are NOT values (their readbacks do not follow the state). Only vst slots can lag.
local function lagging(S) return S.class == "vst" and S.lagset ~= nil and LAG.is(S.lagset, S.ident) end
M.lagging = lagging

--- THE one state comparison (2026-10-15): are the saved states a and b of slot S the same state? Raw equality, except that
--- volatile UI fields of the plugin family (cl_lag MASKS, e.g. TR5's editor GuiScale) are ignored. Every chunk comparison in
--- the lib goes through this; a normalised chunk is never written.
local function same_state(S, a, b) return LAG.same(S.ident, a, b) end
M.same_state = same_state

--- one observation that S's ident lags (chunk equal while readbacks differ / set_blob moved no readback). Learned after
--- LAG.EVIDENCE_NEEDED observations ≥ 1 s apart: a one-off (a plugin loading its state asynchronously) is never persisted.
local function lag_evidence(st, io, S, why, now)
  if S.class ~= "vst" or not S.lagset or lagging(S) then return end
  if LAG.evidence(S.lagset, S.ident, now, why, io.today and io.today() or "") then
    local line = ("lagging learned | %s | %s"):format(tostring(S.ident), why)
    if io.blog then io.blog(line) elseif io.log then io.log(line) end
    save_lag(st, io)
  end
end
M.lag_evidence = lag_evidence

-- ------------------------------------------------------------------ "is this state usable?" (Nebula family, 2026-10-15)
-- EL REY2 [M tests/probes/RESULTS_ELREY.md]: an instance whose window was never opened is asleep (readbacks 0, a valueless 818-byte state);
-- while it loads (1.1-2.7 s) and for ~0.2 s after, the state is in transition. Such a state must never be taken as the source of a copy, nor
-- compared (a "difference" against it is no difference in settings). Ready = the saved state did not change across two reads at least
-- SAMPLE_GAP apart AND it is not the asleep state (the asleep body is a stable state too, so stability alone is not enough).
M.SAMPLE_GAP = 0.25
local function needs_ready(S) return S.class == "vst" and LAG.needs_ready(S.ident) end
M.needs_ready = needs_ready

--- state of (member, slot) usable now? Always true for a plugin outside the family. Reads the state at most every SAMPLE_GAP; between
--- reads the last answer stands. Called only at decision points (join / formation / copy / LINK / commit), never per knob.
function M.state_ok(st, io, mid, k, ident, now)
  if not LAG.needs_ready(ident) then return true end
  st.sr = st.sr or {}
  local key = tostring(mid) .. "|" .. tostring(k)
  local e = st.sr[key]
  if e and e.id ~= ident then e = nil end
  if e and now - e.r < M.SAMPLE_GAP then return e.ok end
  local c = io.blob(mid, k)
  st.stats.blob_reads = st.stats.blob_reads + 1
  if not c or c == "" then st.sr[key] = { id = ident, t = now, r = now, ok = false }; return false end
  if e and e.c and LAG.same(ident, c, e.c) then
    e.r = now
    e.ok = (now - e.t >= M.SAMPLE_GAP) and not LAG.asleep(c)
    return e.ok
  end
  st.sr[key] = { id = ident, c = c, t = now, r = now, ok = false }
  return false
end

--- every slot of member m that needs the rule has a usable state
function M.member_state_ok(st, io, g, m, now)
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    if S and needs_ready(S) and not M.state_ok(st, io, m, k, S.ident, now) then return false end
  end
  return true
end

--- THE one writer of a saved state into a member for the lagging lane: an asleep (valueless) state is never written
--- (what it would do to an awake instance is unmeasured; it carries no settings in any case). Returns whether it wrote.
function M.write_state(st, io, S, t, blob)
  if needs_ready(S) and LAG.asleep(blob) then
    local line = ("refused | %s | Ch-slot %s: an asleep (valueless) state is never written into %s"):format(tostring(S.ident), tostring(S.k), tostring(t))
    if io.blog then io.blog(line) elseif io.log then io.log(line) end
    return false
  end
  io.set_blob(t, S.k, blob)
  st.stats.blob_writes = st.stats.blob_writes + 1
  return true
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
                nmap = {}, cur = 1, selfq = {}, lagset = lagstore(st, io) }
    g.slots[k] = S
    g.order[#g.order + 1] = k
    -- family by state signature (cl_lag.sniff): one state read per new vst ident, decided before any value path touches the slot
    if info.class == "vst" and LAG.SNIFFED[info.ident] == nil then
      local ok, c = pcall(io.blob, mid, k)
      if ok and LAG.sniff(info.ident, c) then
        local line = ("lagging by signature | %s | Nebula2 state: its readbacks are not its settings, compared and copied by saved state"):format(tostring(info.ident))
        if io.blog then io.blog(line) else log(io, line) end
      end
    end
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

-- params of a slot that are READ for change detection right now (static list minus dynamic exclusions, real index < min n_real):
-- sweep / hot / watch / readiness. A lagging plugin's own params are read too, but only as the signal "edited" (lag_signal).
local function scannable(S, p)
  if not S.meta.inlist[p] then return false end
  if S.frozen[p] or S.env[p] then return false end
  if p >= 0 and p >= S.n - 3 then return false end
  for _, d in pairs(S.dyn) do if d[p] then return false end end
  return true
end
M.scannable = scannable

-- THE chokepoint: params of a slot whose VALUE may be used (written to other members, stored in S.agreed / S.last for an
-- election, recorded for undo, flushed, re-asserted, compared across members). Every value path asks this; a lagging
-- plugin's own params (p >= 0) never pass: its state travels as a chunk (blob_write / cl_blob), roles (Wet/Delta/bypass) as usual.
local function synced(S, p)
  if p >= 0 and lagging(S) then return false end
  return scannable(S, p)
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
    if not rd.blob_empty then
      rd.blobcheck = false
      if S.class == "vst" and LAG.SNIFFED[S.ident] == nil and LAG.sniff(S.ident, b) and io.blog then
        io.blog(("lagging by signature | %s | Nebula2 state: its readbacks are not its settings, compared and copied by saved state"):format(tostring(S.ident)))
      end
    end
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
  -- REAPER's own roles (Wet / Delta; p < 0): a write of the value they already hold changes nothing, but on some plugins (EL REY2, TR5 [M
  -- tests/probes/LOG_elundoctl3.txt]) every script SetParam makes REAPER add its own "FX parameter edit" undo entry on top of the user's step,
  -- so one Ctrl+Z would undo that script write instead of the user's edit. Not written when equal.
  if p < 0 then
    local cur = io.get(mid, S.k, p)
    if cur and abs(cur - v) <= 1e-9 then return cur end
  end
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

--- a lagging slot's own param p was read on every member in `mem` (values v[m]). Readbacks are NOT values here: nothing is
--- elected, nothing is written, S.agreed is untouched. A member whose readback moved (more than its own tolerance, outside
--- the quiet window after our own state write) was EDITED: it gets B.sig_t = now, and cl_blob reads its chunk, waits for it
--- to settle and spreads it (the chunk is the only truth). Returns false (no election).
local function lag_signal(st, io, S, p, v, mem, ctx)
  local now = ctx.now
  local ts = tol_s(S, p)
  local sig = false
  for _, m in ipairs(mem) do
    local lm = S.last[m]
    if not lm then lm = {}; S.last[m] = lm end
    local l = lm[p]
    if l == nil then lm[p] = v[m]
    elseif abs(v[m] - l) > ts then
      lm[p] = v[m]
      local B = S.blob[m]
      if not B then B = {}; S.blob[m] = B end
      if not (B.quiet_until and now < B.quiet_until) then      -- inside the quiet window = our own state write, not an edit
        B.sig_t = now
        B.explained = now                                       -- a param move explains a chunk change (cl_blob witness)
        sig = true
      end
    end
  end
  if sig then S.hot[p] = now + ctx.cfg.hot_time end
  return false
end
M.lag_signal = lag_signal

--- elect one param p of slot S from the values v[m] just read on every member in `mem`
local function elect(st, io, g, S, p, v, mem, ctx)
  if p >= 0 and lagging(S) then return lag_signal(st, io, S, p, v, mem, ctx) end   -- readbacks are no values (cl_lag)
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
    local msg = ("Ch %d slot %s p%d frozen (%s)"):format(g.ch, tostring(S.k), p, fz.alt >= 3 and "bounces between tracks" or "keeps changing by itself")
    if io.blog then io.blog("freeze | " .. msg .. " | " .. tostring(S.ident)) else log(io, msg) end
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
        local msg = ("Ch %d slot %s p%d unfrozen (user edit)"):format(g.ch, tostring(S.k), t.p)
        if io.blog then io.blog("freeze | " .. msg .. " | " .. tostring(S.ident)) else log(io, msg) end
      end
    end
    if scannable(S, t.p) then S.hot[t.p] = math.max(S.hot[t.p] or 0, ctx.now + 0.05) end
  end
  for p, untl in pairs(S.hot) do
    if untl < ctx.now then S.hot[p] = nil
    elseif scannable(S, p) then check(st, io, g, S, p, mem, ctx) end
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
          if scannable(S, p) and not S.hot[p] and lm[p] ~= nil then
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
    if scannable(S, p) and not S.hot[p] then check(st, io, g, S, p, mem, ctx) end
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
  -- a source whose state is asleep / loading / still changing is never copied (Nebula family): deferred, the caller retries (false)
  if needs_ready(S) and not M.state_ok(st, io, src, S.k, S.ident, now) then return false end
  if with_blob and S.class == "vst" then
    local b = io.blob(src, S.k)
    if b and b ~= "" then
      M.blob_write(st, io, g, S, src, dst, b, ctx)       -- whole state: blob → all params → roles → bypass (§3)
      return true
    end
  end
  S.last[src] = S.last[src] or {}
  S.last[dst] = S.last[dst] or {}
  -- a lagging plugin's own params are no values (cl_lag): the saved state is compared and, if it differs, written
  if S.class == "vst" and lagging(S) then
    local bs = io.blob(src, S.k)
    if bs and bs ~= "" and not same_state(S, bs, io.blob(dst, S.k)) then
      M.blob_write(st, io, g, S, src, dst, bs, ctx)
      return true
    end
  end
  -- same saved state on both (e.g. right after a structure copy, which carries the plugin state): the plugin's own params
  -- are already equal in sound; a readback difference there is a lagging readback (TR5 EQ-81 shows its defaults after a
  -- load or a state write [M tests/probes/RESULTS_TR5_GAIN.md]) and must not be written over the target (2026-10-10).
  -- (An ident not yet known as lagging: this keeps the write off, and counts as one observation towards learning it.)
  local ss
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) then
      local vs, vd = io.get(src, S.k, p), io.get(dst, S.k, p)
      local lim = blob_written and tol_c(S, p) or 0
      if abs(vd - vs) > lim then
        if p >= 0 and ss == nil then
          local bs = S.class == "vst" and io.blob(src, S.k)
          ss = (bs and bs ~= "" and M.same_state(S, bs, io.blob(dst, S.k))) or false
          if ss then
            if io.blog then io.blog(("lagging readback | %s | Ch %d slot %s: same state, values left as they are"):format(tostring(S.ident), g.ch, tostring(S.k))) end
            if abs(vd - vs) > M.LAG_MIN_DIFF then lag_evidence(st, io, S, "same saved state, readbacks differ", now) end
          end
        end
        if not (p >= 0 and ss) then vd = write_param(st, io, S, dst, p, vs, now, cfg); S.agreed[p] = vs end
      else S.agreed[p] = vs end
      S.last[src][p] = vs; S.last[dst][p] = vd
    end
  end
  local es, ed = io.enabled(src, S.k), io.enabled(dst, S.k)
  if es ~= ed then ed = io.set_bypass(dst, S.k, not es); st.stats.byp_writes = st.stats.byp_writes + 1 end
  S.byp[src], S.byp[dst], S.byp_agreed = es, ed, es
  quiet_blob(S, dst, now, cfg)
  return true
end

--- differing synced values of one slot between a and b (cross tolerance), appended to `out` (up to `max`) when given.
--- A plugin whose saved state (vst_chunk) is byte-identical on both members counts as equal whatever its readbacks say:
--- some plugins (TR5 EQ-81 [M tests/probes/RESULTS_TR5_GAIN.md]) keep showing their default values after a project load
--- or a state write, so a readback difference there is not a difference in sound (2026-10-10). The state is read only
--- when a readback differs (a state read costs ms).
local function st_now(io) return io.now and io.now() or 0 end
local function slot_values(st, io, S, a, b, out, max)
  local n, found = 0, {}
  local lag = lagging(S)
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) then
      local va, vb = io.get(a, S.k, p), io.get(b, S.k, p)
      st.stats.reads = st.stats.reads + 2
      if abs(va - vb) > tol_c(S, p) then n = n + 1; found[#found + 1] = { k = S.k, p = p, va = va, vb = vb } end
    end
  end
  if lag then
    -- a lagging plugin is compared by its saved state only (its own readbacks are no values); Wet/Delta/bypass as usual.
    -- An unreadable state (empty) is not a difference.
    local ba, bb = io.blob(a, S.k), io.blob(b, S.k)
    -- an asleep state (Nebula family: window never opened) holds no settings: no difference can be read against it (deferred)
    local unusable = needs_ready(S) and (LAG.asleep(ba) or LAG.asleep(bb))
    if not unusable and ba and bb and ba ~= "" and bb ~= "" and not same_state(S, ba, bb) then n = n + 1; found[#found + 1] = { k = S.k, p = "state", va = 0, vb = 1 } end
  elseif n > 0 and S.class == "vst" then
    local ba, bb = io.blob(a, S.k), io.blob(b, S.k)
    if ba and ba ~= "" and same_state(S, ba, bb) then          -- only the plugin's own params live in its state; Wet/Delta are REAPER's
      local keep, own = {}, false
      for _, e in ipairs(found) do if e.p < 0 then keep[#keep + 1] = e elseif abs(e.va - e.vb) > M.LAG_MIN_DIFF then own = true end end
      if own then lag_evidence(st, io, S, "same saved state, readbacks differ", st_now(io)) end
      found, n = keep, #keep
    end
  end
  if out then for _, e in ipairs(found) do if #out < max then out[#out + 1] = e end end end
  return n, found[1]
end
M.slot_values = slot_values

--- number of differing synced values/bypass between members a and b (cross tolerance); used for joins
function M.diff(st, io, g, a, b)
  local n, first = 0, nil
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    if not ((S.rd[a] and S.rd[a].out) or (S.rd[b] and S.rd[b].out)) then
      local nv, f = slot_values(st, io, S, a, b)
      if nv > 0 then n = n + nv; first = first or (tostring(k) .. ":" .. f.p) end
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
      slot_values(st, io, S, a, b, out, max)
      local ea, eb = io.enabled(a, k), io.enabled(b, k)
      if ea ~= eb and #out < max then out[#out + 1] = { k = k, p = "bypass", va = ea and 1 or 0, vb = eb and 1 or 0 } end
    end
  end
  return out
end

--- number of differing synced values/bypass of one slot between members a and b (cross tolerance)
function M.slot_diff(st, io, S, a, b)
  local n = slot_values(st, io, S, a, b)
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
  if needs_ready(S) and LAG.asleep(blob) then       -- last line of defence: the valueless state of an unopened instance is never spread
    M.write_state(st, io, S, t, blob)               -- (refuses and logs)
    return
  end
  local held_in = S.pend[src]
  local lag = lagging(S)     -- known lagging ident: its own params are never written (synced is false for them), only the state
  -- the plugin's own params before the state write: some plugins (TR5 EQ-81 [M tests/probes/RESULTS_TR5_GAIN.md]) take
  -- the state but keep showing their old values, and the source may show its defaults too (untouched since the load).
  -- Then the state alone carries the settings: writing the source's readbacks afterwards would put its defaults into
  -- the target's sound (2026-10-10). For an ident not yet known as lagging this is detected per write: readbacks
  -- differed, and none followed the state write (one observation towards learning it, cl_lag).
  local before, src_v, differ, bigdiff = {}, {}, false, false
  for _, p in ipairs(S.meta.list) do
    if p >= 0 and synced(S, p) then
      local v
      if held_in and S.agreed[p] ~= nil then v = S.agreed[p] else v = io.get(src, S.k, p) end
      src_v[p] = v
      before[p] = io.get(t, S.k, p)
      if abs(before[p] - v) > tol_c(S, p) then differ = true; if abs(before[p] - v) > M.LAG_MIN_DIFF then bigdiff = true end end
    end
  end
  local chunk_differed = differ and not same_state(S, io.blob(t, S.k), blob)
  -- a lagging target whose state is already the blob: nothing to load (a readback that catches up later is then a no-op too)
  if not (lag and same_state(S, io.blob(t, S.k), blob)) then
    M.write_state(st, io, S, t, blob)
  end
  local moved_none = false
  if differ then
    moved_none = true
    for p, b in pairs(before) do if abs(io.get(t, S.k, p) - b) > tol_s(S, p) then moved_none = false; break end end
    if moved_none and io.blog then io.blog(("lagging readback | %s | Ch %d slot %s: the state was written, the values were not (they do not follow the state)"):format(tostring(S.ident), g.ch, tostring(S.k))) end
    if moved_none and chunk_differed and bigdiff then lag_evidence(st, io, S, "set_blob moved no readback while the chunk differed", now) end
  end
  local lt = S.last[t] or {}
  S.last[t] = lt
  for _, p in ipairs(S.meta.list) do
    if synced(S, p) then
      local v = src_v[p]
      if v == nil then
        if held_in and S.agreed[p] ~= nil then v = S.agreed[p] else v = io.get(src, S.k, p) end
      end
      if moved_none and p >= 0 then lt[p] = io.get(t, S.k, p)          -- no agreed value from a readback we do not trust
      else lt[p] = write_param(st, io, S, t, p, v, now, cfg); S.agreed[p] = v end
      if S.last[src] then S.last[src][p] = S.last[src][p] or v end
    elseif lag and p >= 0 and scannable(S, p) then
      lt[p] = io.get(t, S.k, p)                                         -- baseline for the edit signal: whatever it shows now
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
      if needs_ready(S) and not M.state_ok(st, io, src, S.k, S.ident, ctx.now) then
        -- the source's state is asleep / loading / changing: the held write waits (kept, not dropped)
      else
        local b = io.blob(src, S.k)
        if b and b ~= "" and not (S.blob[m] and S.blob[m].pending) then M.blob_write(st, io, g, S, src, m, b, ctx)
        elseif b and b ~= "" then S.blob[m].held = { src = src, blob = b, js = false, t = ctx.now } end   -- never over a pending edit (R3)
        S.pend_blob[m] = nil
      end
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
