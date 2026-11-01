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
    g.dst = g.dst or {}
    g.dst[bkey] = g.dst[bkey] or {}                  -- drift per member (source gate, 2026-11-01): survives slot rebuilds like g.bst
    local S = { k = k, ident = info.ident, class = info.class, n = info.n, meta = meta(st, io, mid, k, info),
                last = {}, agreed = {}, hot = {}, fz = {}, frozen = {}, env = {}, dyn = {},
                byp = {}, byp_agreed = nil, blob = g.bst[bkey], rd = {}, pend = {}, pend_byp = {}, pend_blob = {},
                nmap = {}, cur = 1, selfq = {}, lagset = lagstore(st, io), drift = g.dst[bkey] }
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
    if S.drift then S.drift[mid] = nil end
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
  -- only VST3 waits for its saved state: a VST2 has none here (ReaComp, VST2 Pro-C 2: vst_chunk read is empty
  -- [M LOG_reacomp.txt 2026-10-26, RESULTS_HIDDEN]) and waiting for it left the slot without members (stopped the script)
  rd.blobcheck = (S.class == "vst") and tostring(S.ident):lower():find("vst3", 1, true) ~= nil
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


-- ------------------------------------------------------------------ source gate (2026-11-01, docs/SOURCE_GATE_2026-11-01.md)
-- Per Link Ch at most ONE slot is the source: the last focused FX slot (kept while REAPER reports nothing); to become it, its window
-- must be showing at that moment. `touched` never makes a source (the script's own writes are reported as touched). A change on a member that
-- is not the source is not written anywhere: it is remembered as drift (S.drift[m][p], p = a param index or "state"), the marker says so.
-- A write into the member (value election, state write, LINK, undo restore) ends the drift it overwrites.
-- Selected track first (2026-11-01, docs/SOURCE_GATE_2026-11-01.md): only members on selected tracks (ctx.selected) may be the source.
-- One selected member = the source for all its slots. Several: the member holding the focused FX (last non-nil kept), else the one the user
-- touched, else (no preference) the member that changes first takes over; an earlier source stays while it is among them. Nothing is selected = no source.
function M.update_source(g, ctx)
  local sel, list = {}, {}
  for _, m in ipairs(g.members) do
    if g.linked[m] and ctx.res[m] and ctx.selected[m] then sel[m] = true; list[#list + 1] = m end
  end
  g.sel_set = sel
  local f, t = ctx.focused, ctx.touched
  if f and g.linked[f.mid] then g.focus_last = f.mid end
  if g.focus_last and not g.linked[g.focus_last] then g.focus_last = nil end
  g.src_pref = false
  if #list == 0 then g.src = nil; return end
  if #list == 1 then g.src = { m = list[1] }; g.src_pref = true; return end
  if g.focus_last and sel[g.focus_last] then g.src = { m = g.focus_last }; g.src_pref = true; return end
  if t and sel[t.mid] then g.src = { m = t.mid }; g.src_pref = true; return end
  if not (g.src and sel[g.src.m]) then g.src = { m = list[1] } end        -- topmost (g.members is sorted by track index)
end

function M.can_source(g, S, m)
  if not (g.sel_set and g.sel_set[m] and g.linked[m]) then return false end
  if g.src and g.src.m == m then return true end
  if g.src_pref then return false end                  -- a focused / touched / only selected member decides
  g.src = { m = m }                                     -- no preference: the selected member that changes takes over
  return true
end

local function drift_mark(S, m, key)
  if not S.drift then return end
  local d = S.drift[m]
  if not d then d = {}; S.drift[m] = d end
  d[key] = true
end
M.drift_mark = drift_mark
local function drift_clear(S, m, key)
  local d = S.drift and S.drift[m]
  if d then d[key] = nil; if next(d) == nil then S.drift[m] = nil end end
end
M.drift_clear = drift_clear

--- members of slot S that count for "all members agree" (drifted ones are left out; all of them if every member drifted)
function M.undrifted(S)
  local out = {}
  for _, m in ipairs(S.mem) do if not (S.drift and S.drift[m]) then out[#out + 1] = m end end
  if #out == 0 then return S.mem end
  return out
end

--- does member m differ from the group in any slot (drift)? -> marker status
function M.drifted(g, m)
  if not g.dst then return false end
  for _, d in pairs(g.dst) do if d[m] and next(d[m]) then return true end end
  return false
end

--- how many differences member m holds on this Ch (all slots): a rise is a new one
function M.drift_count(g, m)
  local n = 0
  if not g.dst then return 0 end
  for _, d in pairs(g.dst) do if d[m] then for _ in pairs(d[m]) do n = n + 1 end end end
  return n
end

--- pushed-back knob events of member m (a rise is a new one)
function M.push_count(g, m) return g.push_n and g.push_n[m] or 0 end

--- LINK: every member of the Ch is the group's again
function M.clear_drift(g)
  if not g.dst then return end
  for _, d in pairs(g.dst) do for m in pairs(d) do d[m] = nil end end
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
  drift_clear(S, mid, p)
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

--- is a window of member m's container showing (cached per tick)
local function win_showing(io, ctx, m)
  if not io.showing then return false end
  local c = ctx.showc; if not c then c = {}; ctx.showc = c end
  local s = c[m]; if s == nil then s = io.showing(m) and true or false; c[m] = s end
  return s
end

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
    elseif abs(v[m] - l) > ts then
      if M.can_source(g, S, m) then n = n + 1; changed[n] = m; cset[m] = true
      else
        -- not the source (an unselected track, user decision 2026-11-01 "C"): a VALUE change is pushed back to the group's value at once.
        -- Nothing spreads; the write is an echo-type re-assert (no new edit). Only values: a state change stays drift (cl_blob).
        local bm = S.blob[m]; if bm then bm.explained = now end        -- a param change still explains a state change (witness, §2.4)
        local ref = S.agreed[p]
        if ref == nil then
          for _, o in ipairs(mem) do
            if o ~= m and (ref == nil or (g.src and g.src.m == o)) then ref = v[o] end
          end
        end
        if ref ~= nil and abs(v[m] - ref) > tc and win_showing(io, ctx, m) then
          -- (2026-11-01 "A", Studio crash 20:04) its window is showing: nothing is written under it (a band removed under an open
          -- Pro-Q 4 crashed REAPER on the next click). It is a difference of this track until the window closes, then pushed back.
          lm[p] = v[m]
          S.pend_push = S.pend_push or {}
          local q = S.pend_push[m]; if not q then q = {}; S.pend_push[m] = q end
          q[p] = true
          drift_mark(S, m, p)
        elseif ref ~= nil and abs(v[m] - ref) > tc then
          lm[p] = write_param(st, io, S, m, p, ref, now, cfg, true)
          S.pushed = S.pushed or {}
          local pm = S.pushed[m]; if not pm then pm = {}; S.pushed[m] = pm end
          if now - (pm[p] or -1e9) > 1.0 then g.push_n = g.push_n or {}; g.push_n[m] = (g.push_n[m] or 0) + 1 end
          pm[p] = now
          -- a param that keeps moving by itself on a non-source member (meters) must not be fought for ever: frozen after 10 pushes within 2 s
          S.pcnt = S.pcnt or {}
          local pc = S.pcnt[p]
          if not pc or now - pc.t0 > 2.0 then pc = { t0 = now, n = 0 }; S.pcnt[p] = pc end
          pc.n = pc.n + 1
          local wi = ctx.res and ctx.res[m] and ctx.res[m].slots[S.k]
          if pc.n >= 10 and not (wi and (wi.open or wi.chain)) then       -- (a user dragging in its window is no self-moving param)
            S.frozen[p] = true
            st.stats.frozen = st.stats.frozen + 1
            if io.blog then io.blog(("freeze | Ch %d slot %s p%d frozen (keeps changing by itself on a non-source member) | %s"):format(g.ch, tostring(S.k), p, tostring(S.ident))) end
          end
        else
          lm[p] = v[m]
          drift_clear(S, m, p)
        end
      end
    end
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
  drift_clear(S, winner, p)                                       -- the source's own value is the group's now
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

--- (2026-11-01 "A") once per tick: an unselected track whose window has closed gets its held-back changes pushed back to the group's value
function M.flush_pend(st, io, g, ctx)
  for _, k in ipairs(g.order or {}) do
    local S = g.slots and g.slots[k]
    if S and S.pend_push then
      for m, pp in pairs(S.pend_push) do
        if not g.linked[m] then S.pend_push[m] = nil
        elseif not win_showing(io, ctx, m) then
          S.pend_push[m] = nil
          local lm = S.last[m]; if not lm then lm = {}; S.last[m] = lm end
          for p in pairs(pp) do
            local ref, cur = S.agreed[p], io.get(m, k, p)
            if ref == nil then                                 -- no agreed value yet: the source's (else another linked member's) value
              local o = g.src and g.src.m ~= m and g.linked[g.src.m] and g.src.m
              if not o then for _, x in ipairs(S.mem or g.members) do if x ~= m and g.linked[x] then o = x; break end end end
              if o then ref = io.get(o, k, p) end
            end
            if ref ~= nil and cur ~= nil and abs(cur - ref) > tol_c(S, p) then lm[p] = write_param(st, io, S, m, p, ref, ctx.now, ctx.cfg, true)
            elseif cur ~= nil then lm[p] = cur end
            drift_clear(S, m, p)
          end
        end
      end
    end
  end
end

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

-- ------------------------------------------------------------------ one rule: a delivered state is not overwritten by a stale readback
--- 2026-10-28 (LED Compressor [M tests/mbp_run/v2/LOG_ledcase_base.txt, MBP 7.83]): a plugin's readbacks can follow its saved state
--- while the SOURCE's readbacks are stale (LED auto-gain: the source's state says Output -7 dB, its readback still shows 0 dB).
--- A copy that carries the state (block copy: LINK, structure sync) then has right readbacks, and writing the source's readbacks over
--- them made the copy +11 dB. For a vst slot that is not lagging, whose saved state on `t` is not byte-equal to the source's and whose
--- own readbacks differ from the source's (cross tolerance), the source's readbacks are therefore not written: the release path's
--- whole-state write is used (blob_write: the source's state, readbacks that follow it are kept, st.follows), own params only
--- (roles and bypass stay with the caller, no lagging evidence). A slot whose readbacks already equal the source's, or whose state
--- is byte-equal, takes no extra state write. Returns nd (number of differing readbacks), follows; or nil when the rule does not apply.
--- `before` = { [p] = readback }: t's readbacks from before a block write, when the caller has them (LINK).
function M.state_owner_write(st, io, g, S, src, t, bsrc, ctx, before)
  if S.class ~= "vst" or lagging(S) or not bsrc or bsrc == "" then return nil end
  if same_state(S, io.blob(t, S.k), bsrc) then return nil end
  local nd = 0
  for _, p in ipairs(S.meta.list) do
    if p >= 0 and synced(S, p) and abs(io.get(t, S.k, p) - io.get(src, S.k, p)) > tol_c(S, p) then nd = nd + 1 end
  end
  if nd == 0 then return nil end
  return nd, M.blob_write(st, io, g, S, src, t, bsrc, ctx, { link = true, before = before })
end

-- ------------------------------------------------------------------ align one member to another (joins, re-entry)
--- copy src's state of slot S onto dst: blob first (vst), then values verified against src (MUST 6), bypass.
--- with_blob = "values": dst got src's state by a state write (native structure fallback, cl_reaper.copy_struct), where
--- some plugins keep showing their old numbers (Pro-Q 3 [M tests/mbp_run/v2/LOG_melodyne2.txt]): the differing values of a
--- plugin not known as lagging are written, not taken as a lagging readback (no learning from our own write).
function M.align_slot(st, io, g, S, src, dst, ctx, with_blob)
  local values_mode = with_blob == "values"
  if values_mode then with_blob = false end
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
  -- the state is the truth where the readbacks disagree (see state_owner_write): its own params are not written from the source's readbacks
  local delivered = false
  if S.class == "vst" then
    local nd = M.state_owner_write(st, io, g, S, src, dst, io.blob(src, S.k), ctx)
    if nd then
      delivered = true
      if io.blog then io.blog(("state owner | %s | Ch %d slot %s: %d readback(s) differ from the source, state written, readbacks kept"):format(tostring(S.ident), g.ch, tostring(S.k), nd)) end
    end
  end
  -- same saved state on both (e.g. right after a structure copy, which carries the plugin state): the plugin's own params
  -- are already equal in sound; a readback difference there is a lagging readback (TR5 EQ-81 shows its defaults after a
  -- load or a state write [M tests/probes/RESULTS_TR5_GAIN.md]) and must not be written over the target (2026-10-10).
  -- (An ident not yet known as lagging: this keeps the write off, and counts as one observation towards learning it.)
  local ss
  for _, p in ipairs(S.meta.list) do
    if delivered and p >= 0 and synced(S, p) then
      S.last[src][p] = io.get(src, S.k, p); S.last[dst][p] = io.get(dst, S.k, p)       -- the state owns it (blob_write kept the readbacks)
    elseif synced(S, p) then
      local vs, vd = io.get(src, S.k, p), io.get(dst, S.k, p)
      local lim = blob_written and tol_c(S, p) or 0
      if abs(vd - vs) > lim then
        if p >= 0 and ss == nil and not values_mode then
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
  if S.drift then S.drift[t] = nil end                 -- a whole-state write ends the member's drift in this slot
  S.selfq = S.selfq or {}
  S.selfq[t] = { untl = now + cfg.quiet_after_write, n = {} }
end

--- DESIGN_V2 §3: blob, then EVERY listed host param from the source's current readback (a param whose inbound write to
--- the source is held takes the agreed value), roles (Wet/Delta are the last list entries), then bypass.
--- opts (LINK step 2, cl_core run_link; nil on every other route):
---   link = true: the plugin's own params only — LINK writes the roles and the bypass itself (no second write); no lagging
---     evidence (after the block the readbacks may already show the state, so "the state write moved nothing" is no sign of a
---     lagging plugin). Readbacks that moved (block + state write, from `before`) are kept in st.follows as on the release path,
---     so a second LINK, whose targets already show the state, is not mistaken for a copy that did not take.
---   before = { [p] = readback }: t's own readbacks from before the LINK's block write, the baseline for "followed".
--- Returns true when t's own readbacks are known to follow its state (moved past tol_c from `before` here, or st.follows).
function M.blob_write(st, io, g, S, src, t, blob, ctx, opts)
  opts = opts or {}
  local now, cfg = ctx.now, ctx.cfg
  if needs_ready(S) and LAG.asleep(blob) then       -- last line of defence: the valueless state of an unopened instance is never spread
    M.write_state(st, io, S, t, blob)               -- (refuses and logs)
    return false
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
      before[p] = (opts.before and opts.before[p]) or io.get(t, S.k, p)
      if abs(before[p] - v) > tol_c(S, p) then differ = true; if abs(before[p] - v) > M.LAG_MIN_DIFF then bigdiff = true end end
    end
  end
  local chunk_differed = differ and not same_state(S, io.blob(t, S.k), blob)
  -- a lagging target whose state is already the blob: nothing to load (a readback that catches up later is then a no-op too)
  if not (lag and same_state(S, io.blob(t, S.k), blob)) then
    M.write_state(st, io, S, t, blob)
  end
  -- readbacks that followed the state write. A plugin whose readbacks follow its state (KA1776 [M HANDOVER 2026-10-25
  -- 20:36], LED [M V3_P1 Item 2]) must not get the source's readbacks afterwards: a stale one (KA1776 INPUT R, LED Output)
  -- would overwrite the state's value and the copy would differ from the source (2026-10-26, one route per copy).
  -- Pro-Q 3 readbacks do not follow (LOG_melodyne2): those are still written, else it is learned as lagging.
  -- (moved: a readback that went more than tol_c away from where it was; a Waves readback jitter (3e-4) is no sign.
  -- Not "only where it differed from the source": the live value route has usually sent the source's readback already.)
  local any_moved, moved_any_s = false, false
  for p, b in pairs(before) do
    local d = abs(io.get(t, S.k, p) - b)
    if d > tol_s(S, p) then moved_any_s = true end
    if d > tol_c(S, p) then any_moved = true end
  end
  st.follows = st.follows or {}
  if any_moved then st.follows[S.ident] = true end
  local follows = st.follows[S.ident]
  local moved_none = false
  if differ then
    moved_none = not moved_any_s
    if moved_none and io.blog then io.blog(("lagging readback | %s | Ch %d slot %s: the state was written, the values were not (they do not follow the state)"):format(tostring(S.ident), g.ch, tostring(S.k))) end
    if moved_none and chunk_differed and bigdiff and not opts.link then lag_evidence(st, io, S, "set_blob moved no readback while the chunk differed", now) end
  end
  local lt = S.last[t] or {}
  S.last[t] = lt
  for _, p in ipairs(S.meta.list) do
    if opts.link and p < 0 then
      -- LINK writes the roles itself (cl_core run_link step 2)
    elseif synced(S, p) then
      local v = src_v[p]
      if v == nil then
        if held_in and S.agreed[p] ~= nil then v = S.agreed[p] else v = io.get(src, S.k, p) end
      end
      if (moved_none or follows) and p >= 0 then lt[p] = io.get(t, S.k, p)  -- no agreed value from a readback we do not trust
      else lt[p] = write_param(st, io, S, t, p, v, now, cfg); S.agreed[p] = v end
      if S.last[src] then S.last[src][p] = S.last[src][p] or v end
    elseif lag and p >= 0 and scannable(S, p) then
      lt[p] = io.get(t, S.k, p)                                         -- baseline for the edit signal: whatever it shows now
    end
  end
  if not opts.link then                                                -- LINK writes the bypass itself (run_link step 3)
    local es = (S.pend_byp[src] and S.byp_agreed ~= nil) and S.byp_agreed or io.enabled(src, S.k)
    local et = io.enabled(t, S.k)
    if et ~= es then et = io.set_bypass(t, S.k, not es); st.stats.byp_writes = st.stats.byp_writes + 1 end
    S.byp[t] = et
  end
  M.mark_written(S, t, blob, now, cfg)
  return follows and true or false
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
