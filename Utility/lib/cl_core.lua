--[[
  cl_core.lua — TUKONYA Container Link (v1 name: Chain Link): tick orchestration (pure Lua, REAPER only through `io`).

  A Container that holds the marker JSFX with Link Ch n (1..16) is a member of Ch n. Members of a Ch whose container
  holds the same plugins in the same order (the "sig") are linked: values, bypass (by role) and hidden plugin state
  stay identical, without a leader. P1: a member with a different order is only told so on its marker (status 1).

  io contract (all REAPER addresses are re-resolved inside io every tick; core never keeps one):
    now() clock()                -> seconds (clock = real time for the work budget)
    project()                    -> key of the current project tab
    scan()                       -> { {key, tguid, tindex, tname, selected, automode, ch, offline, cont (guid|nil),
                                       nested, order}, ... } one per marker JSFX found anywhere in the normal FX chains
    resolve(mid)                 -> { sig, order = {"c", 1, 2, ...}, slots = {[k] = {ident, class, n, open, offline}} } | nil
    meta(mid, k)                 -> { list = {p...}, tol_s = {p→}, tol_c = {p→} }  static, cached per ident (MUST 11)
    get(mid, k, p) / set(mid, k, p, v) -> value / readback   (p >= 0 real index, -3/-2/-1 = bypass/Wet/Delta role)
    enabled(mid, k) / set_bypass(mid, k, on) -> bool (readback)   bypass by role param, never TrackFX_SetEnabled
    blob(mid, k) / set_blob(mid, k, s)       vst_chunk
    dyn(mid, k, list, i0, i1)    -> {p → true} params with modulation / parameter link active
    lanes(mid) lane_chunk(mid, key) lane_create(mid, k, p) lane_set(mid, k, p, s) lane_remove(mid, k, p)   (P3, cl_env)
    link_requests()              -> { {via = "gmem", seq, ch, nonce, t, skipped} | {via = "ext", id, t, guids} }  (v2 LINK, cl_link)
    link_ack(req, code, text)    answer to the button (gmem) or the action (ExtState)
    marker_info(key) -> {req, open} | nil      clear_req(key)      slider3 (LINK nonce) of a marker; v1 markers → nil
    event(s)                     persistent capped log line (Data/TUKONYA_ChainLink/link_log.txt), also io.log
    hidden state v2 (cl_blob, DESIGN_V2 §2): resolve() slots also carry chain / chain_multi / invisible;
    mouse() -> {down} | nil (no js)   hit(mid, k) -> bool (window under the mouse = the slot's window)
    blog(s) (blob_log.txt)   class_load() / class_save(text) (blob_class.txt)   today()   with_project(key, fn)
    touched() / focused()        -> {mid, k, p} / {mid, k} or nil (the script's own last write is filtered out)
    cname(mid) / set_cname(mid, s) -> the container's display name (renamed_name, "" = unnamed) / readback; nil = not
                                      readable this tick (address moved by a block write)
    playing() override() undo()  -> bool / int / {cur, desc, time, sc}
    set_status(rec, code)  publish(counts)  ask(text, kind)  begin_block()  end_block(desc)  log(s)
--]]

local P = require("cl_params")
local H = require("cl_hist")
local SS = require("cl_struct")
local ENV = require("cl_env")
local L = require("cl_link")
local BL = require("cl_blob")
local M = {}

M.SYNC_DESC = "Container Link: 並びをそろえる"   -- the undo entry of a native structure sync (chained to the user's entry)
M.STATUS = { OK = 0, MISMATCH = 1, DUP = 2, OUTSIDE = 3, NESTED = 4, DEBOUNCE = 6, ASK = 7, LOADING = 8, DECLINED = 9,
             LINK_HOLD = 10, LINKED = 11, LINK_NOTE = 12, BLOB_LOST = 13, LINK_HOLD_PLAY = 14 }   -- 10–12 LINK, 13 hidden-state conflict lost (v2)
local ST = M.STATUS

M.DEFAULTS = {
  debounce = 1.0,          -- Link Ch must stay still this long before a container joins; leaving is immediate
  settle_ticks = 2,        -- after transport stops, wait this many ticks, then flush what was held
  budget = 0.002,          -- at most this many seconds of cold-sweep reads per tick (at least one unit always runs)
  sweep_period = 0.25,     -- the cold sweep reads every synced value of every member once per this period
  sweep_chunk = 32,        -- params per sweep unit
  dyn_chunk = 32,          -- params per modulation/link refresh unit (one unit per tick)
  watch_max = 400,         -- params of an open/focused plugin window read per tick on its own member
  env_rr = 0.5,            -- every lane chunk is re-read at least this often (fingerprints catch most edits at once)
  env_drag = 0.1,          -- lanes are written at most this often per group while they keep changing
  env_rec_refresh = 1.5,   -- a spread lane change with no undo entry of its own updates the current entry's record after this
  hot_time = 1.0,          -- a param that changed is read every tick for this long
  blob_rate = 0.2,         -- hidden-state reads per watched slot: 5 Hz
  blob_settle = 0.3,       -- live settle (idents classified "stable" only, DESIGN_V2 §2.2)
  blob_grace = 1.0,        -- readiness/blob quiet after a load or undo
  witness_while_playing = true,   -- §2.4 witness reads while playing (MBP block gap 12.4 vs 12.1 ms baseline: jitter)
  quiet_after_write = 0.5, -- a blob change right after our own write is not a user edit
  ready_window = 0.5,      -- readiness: readback must be still this long after a load/undo/join event
  ready_timeout = 5.0,     -- readiness gate: give up waiting for one member's slot after this long
  freeze_n = 30,           -- elections of one param within 2 s without a user hint → frozen (self-moving)
  lock_hold = 0.5,         -- source lock: the member changing a param keeps the lead this long after its last change
  echo_window = 0.3,       -- a target readback departing within this long after our write is an echo, not an edit
  recheck = 2.0,           -- declined members are compared again this often (relink silently when identical)
  blob_while_playing = true,
  costly_while_playing = true,   -- reorder/remove while playing: apply at once, accepting a 70–90 ms stall (user decision)
  src_wait = 3.0,          -- a structure source whose plugin state is not loaded yet is waited for this long (MUST 2)
  hist_max = 2000,         -- undo-history entries kept per project
  link_max_age = 2.0,      -- LINK requests older than this (main clock) are dropped (DESIGN_V2_REVIEW MUST 6)
  link_flash = 2.0,        -- 「LINK しました」 on the markers of a LINKed Ch
  link_note = 4.0,         -- note on a selected track whose container was not the source (a track above won)
  link_lanes_while_playing = false,   -- LINK while playing: lanes are written after stop (review Cut 3, the measured path)
  link_hold_while_playing = false,    -- (not used: user decision 2026-10-02, LINK must act while playing)
  link_undo = true,                   -- false = LINK makes no undo entry (fallback if its undo/redo cannot be made exact)
  name_records = true,     -- false = names use plain change detection on undo/redo too (tests only: shows why records exist)
  name_rec_refresh = 1.5,  -- a rename with no undo entry of its own updates the current entry's name record after this
}

local function log(io, s) if io.log then io.log(s) end end

function M.new(cfg)
  local c = {}
  for k, v in pairs(M.DEFAULTS) do c[k] = v end
  for k, v in pairs(cfg or {}) do c[k] = v end
  return { cfg = c, projects = {}, meta = {}, prof = {},
           stats = { ticks = 0, writes = 0, byp_writes = 0, blob_writes = 0, blob_reads = 0, blob_fires = 0, blob_aborts = 0,
                     reads = 0, dyn_reads = 0, meta_reads = 0, conflicts = 0, frozen = 0, dialogs = 0, joins = 0,
                     full_sweeps = 0, sweep_units = 0, undo_events = 0, align = 0, struct_writes = 0, records = 0,
                     restores = 0, restores_struct = 0, restore_nocarrier = 0, restores_from_record = 0 } }
end

local function new_ps(now)
  return { cand = {}, eff = {}, info = {}, groups = {}, jobs = {}, declined = {}, first = true, hist = {}, confirm = {},
           was_playing = false, settle = 0, rr = 0, dyn_rr = 0, t_load = now, link_hold = {}, flash = {} }
end

local function group(ps, ch)
  local g = ps.groups[ch]
  if not g then
    g = { ch = ch, members = {}, linked = {}, asking = {}, recheck = {}, state = {}, agreed_sig = nil, slots = nil,
          order = {}, env_next = 0, wrote = {}, adopt = {}, post_align = {}, pa_done = {}, pa_t = {},
          name = nil, nbase = {}, nbad = {} }     -- container names (name_step): group name (nil = not formed), baseline
    ps.groups[ch] = g
  end
  return g
end

--- MUST 1, per slot (DEVLOG 2026-10-02 14:10–): every slot of the group needs a fresh full sweep of its own before the
--- next record (cl_hist H.settled)
local function rec_mark_all(g)
  if g.slots then for _, k in ipairs(g.order) do local S = g.slots[k]; S.rec_mark = S.swept or 0 end end
end
M.rec_mark_all = rec_mark_all

local function remove_from(list, x)
  for i = #list, 1, -1 do if list[i] == x then table.remove(list, i) end end
end

local function drop_jobs(ps, pred)
  for i = #ps.jobs, 1, -1 do if pred(ps.jobs[i]) then table.remove(ps.jobs, i) end end
end

local function leave(ps, mid)
  local ch = ps.eff[mid]
  ps.eff[mid] = nil
  if not ch then return end
  local g = ps.groups[ch]
  if not g then return end
  remove_from(g.members, mid)
  g.linked[mid] = nil; g.asking[mid] = nil; g.state[mid] = nil; g.adopt[mid] = nil; g.post_align[mid] = nil
  P.forget(g, mid)
  drop_jobs(ps, function(j) return j.mid == mid or (j.kind == "form" and j.ch == ch) end)
end

-- marker issues: outside a container, nested linked container, 2nd marker in a container, 2nd container with a Ch
local function classify(recs)
  table.sort(recs, function(a, b)
    if a.tindex ~= b.tindex then return a.tindex < b.tindex end
    return (a.order or 0) < (b.order or 0)
  end)
  local cont_seen, ch_seen = {}, {}
  for _, r in ipairs(recs) do
    r.issue, r.mid = nil, nil
    if r.offline then r.issue = "offline"
    elseif not r.cont then r.issue = "outside"
    elseif r.nested then r.issue = "nested"
    else
      local kc = r.tguid .. "|" .. r.cont
      if cont_seen[kc] then r.issue = "dup"
      else
        cont_seen[kc] = true
        if r.ch ~= 0 then
          local kch = r.tguid .. "#" .. r.ch
          if ch_seen[kch] then r.issue = "dup" else ch_seen[kch] = true end
        end
      end
    end
    if not r.issue then r.mid = r.tguid .. "|" .. r.cont end
  end
end
M.classify = classify

-- writes are never sent to a track recording automation while playing (Touch/Write/Latch/Latch Preview, [M P0-5])
local function held_mode(automode, override)
  local m = automode
  if override and override >= 0 then
    if override == 5 then return false end      -- automation bypass: nothing is recorded
    m = override
  end
  return m == 2 or m == 3 or m == 4 or m == 5
end
M.held_mode = held_mode

local function link(st, io, g, m)
  g.linked[m] = true
  g.asking[m] = nil
  P.adopt(io, g, m)
  st.stats.joins = st.stats.joins + 1
  log(io, ("Ch %d: %s linked"):format(g.ch, m))
end

--- persistent record of why two members were found different (blob_log.txt): which plugin / param, both values
local function log_diff(st, io, ps, g, a, b, why)
  if not io.blog then return end
  local ok, err = pcall(function()
  local d = P.diff_detail(st, io, g, a, b, 12)
  local parts = {}
  for _, e in ipairs(d) do
    local name = io.pdesc and io.pdesc(a, e.k, e.p) or (tostring(e.k) .. ":" .. tostring(e.p))
    parts[#parts + 1] = ("%s = %.6f / %.6f"):format(name, e.va, e.vb)
  end
  local function tn(m) local r = ps.info[m]; return r and ("%s(#%s)"):format(r.tname or "?", tostring(r.tindex)) or m end
  io.blog(("diff | Ch %d | %s | %s vs %s | %d: %s"):format(g.ch, why, tn(a), tn(b), #d, table.concat(parts, "; ")))
  end)
  if not ok then log(io, "diff log failed: " .. tostring(err)) end
end

local function first_linked(g, except)
  for _, m in ipairs(g.members) do if g.linked[m] and m ~= except then return m end end
end

local function tname(ps, mid) local r = ps.info[mid]; return r and (r.tname ~= "" and r.tname or ("トラック " .. r.tindex)) or "?" end

-- ------------------------------------------------------------------ structure writes (P2)
local function decline(ps, io, g, m, why)
  if g.linked[m] then g.linked[m] = nil; P.forget(g, m) end
  g.asking[m] = nil; g.adopt[m] = nil; g.post_align[m] = nil
  ps.declined[m .. "|" .. g.ch] = true
  log(io, ("Ch %d: %s declined (%s)"):format(g.ch, m, why))
end

-- MUST 10: never while recording; reorder/remove while playing only with the flag (default on, user decision)
local function struct_allowed(cfg, ctx, old, new)
  if ctx.recording then return false end
  if ctx.playing and not cfg.costly_while_playing and SS.class(old or "", new or "") == "costly" then return false end
  return true
end

--- copy src's container block onto every target (each target keeps its own marker and FXIDs; backup first).
--- align = true: verify every value against src once the targets' slots are ready (MUST 6)
local function write_struct(st, io, ps, g, ctx, src, targets, why, align)
  local from_rec = type(src) == "table"            -- a block stored in an undo record (cl_hist)
  for _, t in ipairs(targets) do
    local ok, info
    local sig = from_rec and src.sig or (ctx.res[src] and ctx.res[src].sig)
    if from_rec then ok, info = io.write_block(src, t, why) else ok, info = io.copy_struct(src, t, why) end
    st.stats.struct_writes = st.stats.struct_writes + 1
    log(io, ("Ch %d: structure %s -> %s (%s): %s"):format(g.ch, from_rec and "record" or src, t, why, tostring(info)))
    if ok then
      g.wrote[t] = { t = ctx.now, sig = sig }          -- verified on the next tick (MUST 4: a write that did not take)
      g.pa_t[t] = ctx.now
      if align and not from_rec then g.post_align[t] = src end
    else
      decline(ps, io, g, t, "structure write failed: " .. tostring(info))
    end
  end
  g.slots = nil; g.build_from = (not from_rec) and src or nil; g.rebuilt = true
  ctx.wrote_struct = true
end

-- ------------------------------------------------------------------ dialogs (only when stopped, one per tick)
--- run fn inside a named undo block; the block is always closed, an error is logged (P1_REVIEW MUST 1).
--- ch, decl = one Ch and its members to decline when this entry is undone; or ch = { {ch = n, decl = {...}}, ... } (LINK)
local function in_block(st, io, ps, desc, ch, decl, fn)
  io.begin_block()
  local ok, err = pcall(fn)
  io.end_block(desc)
  local items = type(ch) == "table" and ch or { { ch = ch, decl = decl } }
  if not ok then
    log(io, ("%s: aborted inside the undo block: %s"):format(desc, tostring(err))); st.stats.job_errors = (st.stats.job_errors or 0) + 1
    if io.event then io.event(("%s: aborted inside the undo block: %s"):format(desc, tostring(err))) end
  end
  -- P1_REVIEW MUST 2: an undo below this entry must never let these members become a source
  ps.confirm_pending = { items = items, desc = desc }
  return ok
end

--- does the job's member still have the content the dialog is about? (P1_REVIEW MUST 1)
local function still(ps, g, ctx, m, sig)
  local r = ctx.res[m]
  return r ~= nil and ps.eff[m] == g.ch and r.sig == sig
end
local function align_all(st, io, g, src, dst, ctx)
  for _, k in ipairs(g.order) do P.align_slot(st, io, g, g.slots[k], src, dst, ctx, true) end
  st.stats.align = st.stats.align + 1
end

local function run_job(st, io, ps, job, ctx)
  local g = ps.groups[job.ch]
  if not g then return end
  local desc = ("Container Link: Ch %d をそろえる"):format(g.ch)
  if job.kind == "join_struct" then
    local j = job.mid
    local ref = first_linked(g)
    local rj, rr = ctx.res[j], ref and ctx.res[ref]
    if not g.asking[j] or not ref or not rj or not rr or rj.sig == g.agreed_sig or rj.sig ~= job.sig
       or not still(ps, g, ctx, ref, g.agreed_sig) then g.asking[j] = nil; return end
    if ctx.recording then ps.jobs[#ps.jobs + 1] = job; return end
    local a = io.ask(("「%s」のコンテナ（Link Ch %d）は、ほかのトラックとプラグインの並びが違います。\n\n" ..
      "はい: Ch %d の並びと設定に合わせる（このトラックの中身が置き換わります。元の中身は控えのファイルに残します）\n" ..
      "いいえ: このトラックの並びと設定を、Ch %d の全部のトラックに写す\n" ..
      "キャンセル: つながない"):format(tname(ps, j), g.ch, g.ch, g.ch), "yesnocancel")
    st.stats.dialogs = st.stats.dialogs + 1
    g.asking[j] = nil
    if a == "yes" then
      in_block(st, io, ps, desc, g.ch, { j }, function() write_struct(st, io, ps, g, ctx, ref, { j }, "join: take the Ch content", false) end)
      g.adopt[j] = ref
      g.slots = nil; g.build_from = ref
    elseif a == "no" then
      local targets = {}
      for _, m in ipairs(g.members) do if g.linked[m] then targets[#targets + 1] = m end end
      in_block(st, io, ps, desc, g.ch, { j }, function() write_struct(st, io, ps, g, ctx, j, targets, "join: this track's content to the Ch", true) end)
      g.agreed_sig = rj.sig
      g.linked[j] = true
    else
      ps.declined[j .. "|" .. g.ch] = true
      log(io, ("Ch %d: %s declined (structure)"):format(g.ch, j))
    end
    return
  elseif job.kind == "struct_conflict" then
    g.conflict = nil
    local a_m, b_m = job.a, job.b
    local ra, rb = ctx.res[a_m], ctx.res[b_m]
    if not ra or not rb or not g.linked[a_m] or not g.linked[b_m] or ra.sig == rb.sig then return end
    if ctx.recording then ps.jobs[#ps.jobs + 1] = job; g.conflict = true; return end
    local a = io.ask(("Link Ch %d で、2つのトラックのプラグインの並びが同時に変わりました。\n\n" ..
      "はい: 「%s」の並びにそろえる\nいいえ: 「%s」の並びにそろえる\nキャンセル: そろえない（並びが違うトラックはつなぎません）"):format(
      g.ch, tname(ps, a_m), tname(ps, b_m)), "yesnocancel")
    st.stats.dialogs = st.stats.dialogs + 1
    local src = (a == "yes") and a_m or (a == "no") and b_m or nil
    if src then
      local new = ctx.res[src].sig
      local targets = {}
      for _, m in ipairs(g.members) do if g.linked[m] and ctx.res[m] and ctx.res[m].sig ~= new then targets[#targets + 1] = m end end
      in_block(st, io, ps, desc, g.ch, {}, function() write_struct(st, io, ps, g, ctx, src, targets, "conflict: chosen in the dialog", true) end)
      g.agreed_sig = new
    else
      for _, m in ipairs(g.members) do
        if g.linked[m] and ctx.res[m] and ctx.res[m].sig ~= g.agreed_sig then decline(ps, io, g, m, "conflict: cancelled") end
      end
    end
    return
  end
  if not g.slots then return end
  if job.kind == "join" then
    local j = job.mid
    local ref = first_linked(g)
    if not g.asking[j] or not ref or not still(ps, g, ctx, j, g.agreed_sig) or not still(ps, g, ctx, ref, g.agreed_sig) then
      g.asking[j] = nil; return
    end
    local a = io.ask(("「%s」のコンテナ（Link Ch %d）は、ほかのトラックと同じプラグインですが、設定が違います。\n\n" ..
      "はい: Ch %d の設定に合わせる（このトラックの設定が変わります）\n" ..
      "いいえ: このトラックの設定を、Ch %d の全部のトラックに写す\n" ..
      "キャンセル: つながない"):format(tname(ps, j), g.ch, g.ch, g.ch), "yesnocancel")
    st.stats.dialogs = st.stats.dialogs + 1
    g.asking[j] = nil
    if a == "yes" then
      if in_block(st, io, ps, desc, g.ch, { j }, function() align_all(st, io, g, ref, j, ctx) end) then
        if P.diff(st, io, g, ref, j) > 0 then log_diff(st, io, ps, g, ref, j, "still different right after aligning (join)") end
        link(st, io, g, j)
      else ps.declined[j .. "|" .. g.ch] = true end
    elseif a == "no" then
      if in_block(st, io, ps, desc, g.ch, { j }, function()
        for _, m in ipairs(g.members) do if g.linked[m] then align_all(st, io, g, j, m, ctx) end end
      end) then link(st, io, g, j) else ps.declined[j .. "|" .. g.ch] = true end
    else
      ps.declined[j .. "|" .. g.ch] = true
      log(io, ("Ch %d: %s declined"):format(g.ch, j))
    end
  elseif job.kind == "form" then
    local ref = job.ref
    if not g.linked[ref] or not still(ps, g, ctx, ref, g.agreed_sig) then
      for _, m in ipairs(job.list) do g.asking[m] = nil end
      return
    end
    local list = {}
    for _, m in ipairs(job.list) do
      if g.asking[m] and still(ps, g, ctx, m, g.agreed_sig) then list[#list + 1] = m else g.asking[m] = nil end
    end
    if #list == 0 then return end
    local names = {}
    for _, m in ipairs(list) do names[#names + 1] = "「" .. tname(ps, m) .. "」" end
    local a = io.ask(("Link Ch %d のトラックで、プラグインの設定が違います（%s）。\n\n" ..
      "はい: 全部を「%s」の設定にそろえる\nいいえ: 設定が違うトラックはつながない"):format(g.ch, table.concat(names, "、"), tname(ps, ref)), "yesno")
    st.stats.dialogs = st.stats.dialogs + 1
    for _, m in ipairs(list) do g.asking[m] = nil end
    if a == "yes" then
      if in_block(st, io, ps, desc, g.ch, list, function() for _, m in ipairs(list) do align_all(st, io, g, ref, m, ctx) end end) then
        for _, m in ipairs(list) do
          if P.diff(st, io, g, ref, m) > 0 then log_diff(st, io, ps, g, ref, m, "still different right after aligning (form)") end
          link(st, io, g, m)
        end
      else for _, m in ipairs(list) do ps.declined[m .. "|" .. g.ch] = true end end
    else
      for _, m in ipairs(list) do ps.declined[m .. "|" .. g.ch] = true end
    end
  end
end

-- ------------------------------------------------------------------ one group per tick
local function member_states(ps, g, ctx, hold)
  for _, m in ipairs(g.members) do
    local r = ctx.res[m]
    local s
    if g.linked[m] then s = (hold or ctx.loading[m]) and ST.LOADING or ST.OK
    elseif g.asking[m] then s = ST.ASK
    elseif g.adopt[m] then s = ST.LOADING
    elseif not r or r.sig ~= g.agreed_sig then s = ST.MISMATCH
    elseif ps.declined[m .. "|" .. g.ch] then s = ST.DECLINED
    else s = ST.LOADING end
    g.state[m] = s
  end
end

local function pick_struct(ps, list, ctx)
  local t, f = ctx.touched, ctx.focused
  for _, m in ipairs(list) do if (t and t.mid == m) or (f and f.mid == m) then return m end end
  for _, m in ipairs(list) do if ctx.selected[m] then return m end end
  return list[1]
end

--- structure election among linked members (§6.3). Returns true when this group must wait (or wrote) this tick.
local function struct_step(st, io, ps, g, ctx)
  local cfg, now = st.cfg, ctx.now
  local changed, sigs, nsig = {}, {}, 0
  for _, m in ipairs(g.members) do
    if g.linked[m] then
      local r = ctx.res[m]
      if not r then g.linked[m] = nil; P.forget(g, m)
      elseif r.sig ~= g.agreed_sig then
        changed[#changed + 1] = m
        if not sigs[r.sig] then sigs[r.sig] = m; nsig = nsig + 1 end
      end
    end
  end
  if #changed == 0 then g.src_wait = nil; g.partner = nil; return false end
  if nsig > 1 then
    if not g.conflict and not ctx.playing then
      local a = pick_struct(ps, changed, ctx)
      local b
      for _, m in ipairs(changed) do if ctx.res[m].sig ~= ctx.res[a].sig then b = m; break end end
      g.conflict = true
      ps.jobs[#ps.jobs + 1] = { kind = "struct_conflict", ch = g.ch, a = a, b = b }
      log(io, ("Ch %d: two members changed their FX order differently, ask when stopped"):format(g.ch))
    end
    return true
  end
  local src = pick_struct(ps, changed, ctx)
  local new = ctx.res[src].sig
  local targets = {}
  for _, m in ipairs(g.members) do
    if g.linked[m] and ctx.res[m] and ctx.res[m].sig ~= new then targets[#targets + 1] = m end
  end
  if #targets == 0 then                                  -- everyone changed the same way (e.g. an undo of all)
    g.agreed_sig = new; g.slots = nil; g.build_from = src; g.rebuilt = true
    return true
  end
  if not g.src_wait then
    -- the user's entry this sync belongs to (the chain partner): the entry current when the change was first seen
    g.partner = ctx.u and { cur = ctx.u.cur, desc = ctx.u.desc, time = ctx.u.time } or nil
  end
  g.src_wait = g.src_wait or now
  if not io.struct_ready(src) and now - g.src_wait < cfg.src_wait then return true end   -- MUST 2: state not loaded yet
  for _, t in ipairs(targets) do
    if not struct_allowed(cfg, ctx, ctx.res[t].sig, new) then return true end
  end
  -- every structure sync is ONE named undo entry (chained to the user's entry in tick step 2, so one Ctrl+Z /
  -- Ctrl+Shift+Z moves everyone and REAPER's own snapshots stay consistent). Per target: REAPER's own moves/deletes when
  -- they express it (reorder / remove: instances kept, no stall [M e3]), else the chunk splice (an add; backup first).
  -- only when the user's entry is still the current one (no recording take, fader … in between, which a chained undo would
  -- also undo); otherwise the v1 path: silent chunk splice, the history guard handles undo
  local p = g.partner
  g.partner = nil
  if not (p and ctx.u and p.cur == ctx.u.cur and p.desc == ctx.u.desc and p.time == ctx.u.time) then
    log(io, ("Ch %d: the user's entry is no longer the current one: silent chunk sync (no undo entry)"):format(g.ch))
    write_struct(st, io, ps, g, ctx, src, targets, "FX order changed on " .. tname(ps, src), true)
    g.agreed_sig = new
    g.src_wait = nil
    return true
  end
  ps.pair_pending = { desc = p.desc, time = p.time }
  io.begin_block()
  local ok, err = pcall(function()
    for _, t in ipairs(targets) do
      if io.native_plan and io.native_plan(src, t) then
        local wok, info = io.native_struct(src, t, "FX order changed on " .. tname(ps, src))
        st.stats.struct_writes = st.stats.struct_writes + 1
        st.stats.native_syncs = (st.stats.native_syncs or 0) + 1
        log(io, ("Ch %d: structure %s -> %s (native): %s"):format(g.ch, src, t, tostring(info)))
        if wok then g.wrote[t] = { t = now, sig = new }; g.pa_t[t] = now; g.post_align[t] = src
        else decline(ps, io, g, t, "native structure write failed: " .. tostring(info)) end
      else
        write_struct(st, io, ps, g, ctx, src, { t }, "FX order changed on " .. tname(ps, src), true)
      end
    end
  end)
  io.end_block(M.SYNC_DESC)
  if not ok then log(io, ("Ch %d: structure sync aborted: %s"):format(g.ch, tostring(err))) end
  g.slots = nil; g.build_from = src; g.rebuilt = true
  ctx.wrote_struct = true
  g.agreed_sig = new
  g.src_wait = nil
  return true
end

local function process_group(st, io, ps, g, ctx, settling)
  local cfg, now = st.cfg, ctx.now
  table.sort(g.members, function(a, b) return (ps.info[a] and ps.info[a].tindex or 1e9) < (ps.info[b] and ps.info[b].tindex or 1e9) end)
  -- LINK made while playing: its lanes follow after stop (silent, outside the undo block; review Cut 3)
  if g.link_lanes and not (ctx.playing or ctx.recording or settling) then
    local src = g.link_lanes.src
    g.link_lanes = nil
    if g.linked[src] and ctx.res[src] then
      local targets = {}
      for _, m in ipairs(g.members) do if m ~= src and g.linked[m] and ctx.res[m] then targets[#targets + 1] = m end end
      local n = ENV.link_copy(st, io, g, src, targets)
      if io.event then io.event(("LINK Ch %d: lanes written after stop (%d lane writes)"):format(g.ch, n)) end
    end
  end
  -- P1_REVIEW MUST 6: "asking" lasts only while a dialog job for that member is queued
  local queued = {}
  for _, j in ipairs(ps.jobs) do
    if j.ch == g.ch then
      if j.mid then queued[j.mid] = true end
      for _, m in ipairs(j.list or {}) do queued[m] = true end
    end
  end
  for m in pairs(g.asking) do if not queued[m] then g.asking[m] = nil end end
  -- MUST 4: a structure write is checked on the first tick after it; content other than what we wrote = it did not
  -- take → that member is declined and never becomes a source
  for m, wr in pairs(g.wrote) do
    local r = ctx.res[m]
    if r then
      if wr.sig and r.sig ~= wr.sig then decline(ps, io, g, m, "our structure write did not take") end
      g.wrote[m] = nil
    end
  end
  -- every slot counts as suspended (no cold sweep, no record) unless the facet step below runs this tick
  if g.slots then for _, k in ipairs(g.order) do g.slots[k].suspended = true end end
  local function dec(gg, m, why) decline(ps, io, gg, m, why) end
  local function wstruct(src, targets, why, align) write_struct(st, io, ps, g, ctx, src, targets, why, align) end
  -- 1. a pending undo restore comes first (MUST 3); structure stage
  if g.restore and not g.restore.struct_done then
    local r = H.restore_struct(st, io, ps, g, ctx, wstruct, dec)
    if r == "wait" or r == "wrote" then member_states(ps, g, ctx, true); return end
    if r == "drop" then g.restore = nil else g.restore.struct_done = true end
  end
  -- 2. structure election among linked members
  if g.agreed_sig and next(g.linked) and not g.restore then
    if struct_step(st, io, ps, g, ctx) then member_states(ps, g, ctx, true); return end
  end
  if next(g.linked) == nil then
    -- (re)form: the content most members have (an empty container only if all are empty), tie → the lowest track
    local cnt, best = {}, nil
    for _, m in ipairs(g.members) do local r = ctx.res[m]; if r then cnt[r.sig] = (cnt[r.sig] or 0) + 1 end end
    for _, m in ipairs(g.members) do
      local r = ctx.res[m]
      if r and not ps.declined[m .. "|" .. g.ch] then
        local better = best == nil or (best == "" and r.sig ~= "") or (r.sig ~= "" and cnt[r.sig] > cnt[best])
        if better then best = r.sig end
      end
    end
    if best ~= g.agreed_sig then
      g.agreed_sig = best; g.slots = nil; g.asking = {}
      drop_jobs(ps, function(j) return j.ch == g.ch end)
    end
  end
  if not g.agreed_sig then member_states(ps, g, ctx); return end
  if not g.slots then
    local from = g.build_from
    if not (from and ctx.res[from] and ctx.res[from].sig == g.agreed_sig) then from = nil end
    if not from then
      for _, m in ipairs(g.members) do
        local r = ctx.res[m]
        if r and r.sig == g.agreed_sig then from = m; break end
      end
    end
    if not from then member_states(ps, g, ctx); return end
    P.build(st, io, g, from, ctx.res[from])
    g.build_from = nil
  end
  -- 3. readiness of every member that has the group's content
  local ready_all, cands = {}, {}
  for _, m in ipairs(g.members) do
    local r = ctx.res[m]
    if r and r.sig == g.agreed_sig then
      P.shape_check(st, io, g, m, r)
      cands[#cands + 1] = m
      local all, ld = true, false
      for _, k in ipairs(g.order) do
        local S = g.slots[k]
        if ctx.reload then P.event(S, m, now, cfg) end
        local ok = P.ready(st, io, g, S, m, r.slots[k], now, cfg)
        if not ok then ld = true; if not S.rd[m].out then all = false end end
        if S.rd[m].out then ld = true end
      end
      ready_all[m], ctx.loading[m] = all, ld
    end
  end
  -- 3b. lanes on the container (P3): sync + undo restore; also sets the value-sync exclusions S.env (MUST 9)
  do
    local lm = {}
    for _, m in ipairs(g.members) do if g.linked[m] and ctx.res[m] and ctx.res[m].sig == g.agreed_sig then lm[#lm + 1] = m end end
    ENV.step(st, io, ps, g, lm, ctx, ctx.playing or ctx.recording or settling)
  end
  -- 4. undo restore, values stage (MUST 2b: after every slot is ready and its window closed)
  if g.restore then
    local r = H.restore_values(st, io, ps, g, ctx, dec)
    if r == "wait" then member_states(ps, g, ctx, true); return end
    g.restore = nil
  end
  -- 5. joins (Q2: joiner vs group, group wins by default; Q3: several at once, majority, tie → lowest track)
  local ref = first_linked(g)
  local joiners = {}
  for _, m in ipairs(cands) do
    if not g.linked[m] and not g.asking[m] then
      if g.adopt[m] then
        local src = g.adopt[m]
        if not g.linked[src] then src = ref end
        if src and ready_all[m] and ready_all[src] then
          align_all(st, io, g, src, m, ctx)                -- values verified against the group (MUST 6), silent
          g.adopt[m] = nil
          link(st, io, g, m)
        end
      elseif ps.declined[m .. "|" .. g.ch] then
        if ref and ready_all[m] and ready_all[ref] and now >= (g.recheck[m] or 0) then
          g.recheck[m] = now + cfg.recheck
          if P.diff(st, io, g, ref, m) == 0 then ps.declined[m .. "|" .. g.ch] = nil; link(st, io, g, m) end
        end
      else joiners[#joiners + 1] = m end
    end
  end
  if ref then
    for _, j in ipairs(joiners) do
      if ready_all[j] and ready_all[ref] then
        local nd, first = P.diff(st, io, g, ref, j)
        if nd == 0 then link(st, io, g, j)
        else
          g.asking[j] = true
          ps.jobs[#ps.jobs + 1] = { kind = "join", ch = g.ch, mid = j }
          log(io, ("Ch %d: %s has %d differing values (first %s), ask when stopped"):format(g.ch, j, nd, tostring(first)))
          log_diff(st, io, ps, g, ref, j, "join")
        end
      end
    end
  elseif #joiners > 0 then
    local all = true
    for _, j in ipairs(joiners) do if not ready_all[j] then all = false end end
    if all then
      if #joiners == 1 then link(st, io, g, joiners[1])
      else
        local eq = {}
        for _, a in ipairs(joiners) do eq[a] = { n = 0 } end
        for i = 1, #joiners do
          for j = i + 1, #joiners do
            local a, b = joiners[i], joiners[j]
            if P.diff(st, io, g, a, b) == 0 then eq[a][b] = true; eq[b][a] = true; eq[a].n = eq[a].n + 1; eq[b].n = eq[b].n + 1 end
          end
        end
        local best = joiners[1]
        for _, a in ipairs(joiners) do if eq[a].n > eq[best].n then best = a end end
        link(st, io, g, best)
        local rest = {}
        for _, a in ipairs(joiners) do
          if a ~= best then
            if eq[best][a] then link(st, io, g, a)
            else g.asking[a] = true; rest[#rest + 1] = a; log_diff(st, io, ps, g, best, a, "at formation") end
          end
        end
        if #rest > 0 then ps.jobs[#ps.jobs + 1] = { kind = "form", ch = g.ch, ref = best, list = rest } end
      end
    end
  end
  member_states(ps, g, ctx)
  -- 6. sync facets per slot
  for _, k in ipairs(g.order) do
    local S = g.slots[k]
    local mem = P.slot_members(g, S)
    S.mem = mem
    local suspended = settling
    for _, m in ipairs(mem) do if not (S.rd[m] and S.rd[m].ok) then suspended = true end end
    S.suspended = suspended
    if not suspended then
      -- after a structure write: verify the target's values against the source once both are ready (MUST 6)
      for t, src in pairs(g.post_align) do
        local pa = g.pa_done[t] or {}
        g.pa_done[t] = pa
        if not pa[k] and g.linked[t] and g.linked[src] and S.rd[t] and S.rd[t].ok and S.rd[src] and S.rd[src].ok then
          P.align_slot(st, io, g, S, src, t, ctx, false)
          pa[k] = true
        end
      end
      if ctx.flush or next(S.pend) or next(S.pend_byp) or next(S.pend_blob) then P.flush(st, io, g, S, mem, ctx) end
      -- a slot the dropped plan's record did not cover (H.rebaseline): fresh readback, remaining differences resolved once
      -- by the usual tie-break (touched → focused → selected → lowest track), silent
      if S.resolve and #mem >= 2 then
        S.resolve = nil
        local all = {}
        for _, m in ipairs(mem) do all[m] = true end
        local src = P.pick(mem, all, ctx, k)
        local n = 0
        for _, m in ipairs(mem) do
          if m ~= src and P.slot_diff(st, io, S, src, m) > 0 then P.align_slot(st, io, g, S, src, m, ctx, false); n = n + 1 end
        end
        if n > 0 then log(io, ("Ch %d slot %s: re-read after a dropped undo restore, %d member(s) aligned to %s"):format(g.ch, tostring(k), n, src)) end
      end
      -- a member back from the readiness timeout takes the group's state of this slot (silent, logged)
      for _, m in ipairs(mem) do
        if S.rd[m].reenter then
          S.rd[m].reenter = false
          local src = nil
          for _, o in ipairs(mem) do if o ~= m then src = o; break end end
          -- P1_REVIEW MUST 3: equal → nothing; different → never overwrite silently: ask (Q2 dialog) when stopped
          if src and P.slot_diff(st, io, S, src, m) > 0 then
            g.linked[m] = nil; P.forget(g, m)
            g.asking[m] = true
            ps.jobs[#ps.jobs + 1] = { kind = "join", ch = g.ch, mid = m }
            log(io, ("Ch %d slot %s: %s back from loading with different values, ask when stopped"):format(g.ch, tostring(k), m))
          end
        end
      end
      if #mem >= 2 then
        P.bypass(st, io, g, S, mem, ctx)
        P.hot(st, io, g, S, mem, ctx)
        P.watch(st, io, g, S, mem, ctx)
        if not (ctx.playing and not cfg.blob_while_playing) then BL.step(st, io, ps, g, S, mem, ctx) end
      end
    end
  end
  for t, src in pairs(g.post_align) do
    local pa, all = g.pa_done[t] or {}, true
    for _, k in ipairs(g.order) do if not pa[k] then all = false end end
    if all or not g.linked[t] or not g.linked[src] or now - (g.pa_t[t] or now) > 10 then g.post_align[t] = nil; g.pa_done[t] = nil; g.pa_t[t] = nil end
  end
  -- 7. joiners whose FX order differs: a marker-only container takes the group's content silently, others are asked
  if ref and not ctx.wrote_struct then
    for _, m in ipairs(g.members) do
      local r = ctx.res[m]
      if r and r.sig ~= g.agreed_sig and not g.linked[m] and not g.asking[m] and not g.adopt[m] and not ps.declined[m .. "|" .. g.ch] then
        if r.sig == "" then
          if struct_allowed(cfg, ctx, "", g.agreed_sig) and io.struct_ready(ref) then
            write_struct(st, io, ps, g, ctx, ref, { m }, "empty container joins Ch " .. g.ch, false)
            g.adopt[m] = ref
            g.slots = nil; g.build_from = ref
            break                                          -- one structure write per group per tick
          end
        else
          g.asking[m] = true
          ps.jobs[#ps.jobs + 1] = { kind = "join_struct", ch = g.ch, mid = m, sig = r.sig }
          log(io, ("Ch %d: %s has a different FX order, ask when stopped"):format(g.ch, m))
        end
      end
    end
  end
  -- 8. undo record for the current entry (MUST 1); lane changes without an undo entry refresh it (cl_env)
  if g.slots and not ctx.wrote_struct and not ctx.no_record then H.record(st, io, ps, g, ctx); ENV.refresh(st, ps, g, ctx) end
end

-- ------------------------------------------------------------------ container names (HANDOVER N1–N4, 2026-10-02)
--[[ The members of a Ch show one container name: the container FX's renamed_name ("" = REAPER's own label). Facts
  (tests/probes/RESULTS_RENAME.md, REAPER 7.80): a script Set is silent (0 undo, +0 state count, never dirty) but costs
  0.5–5 ms, a Get 0.3 µs → every linked member is read every tick, written only where it differs; the baseline after our
  write is the readback, so our own write is never an edit. REAPER's undo restores every track whose stored state differs
  between the two entries (Q4/Q5): after a silent spread an undo may revert the source alone (Q4) or every target (Q5),
  so a member that "changed" on an undo tick is not a source. Undo/redo onto a known entry: its name record for the Ch is
  applied to every linked member; without one (or onto an entry we never saw) the baseline is re-taken only. Elsewhere
  the member that differs from its baseline is the source (several that disagree: touched/focused, selected, lowest
  track). Joining: a named group wins; an unnamed group takes the joiner's name. First formation: all equal → nothing,
  else the most common non-empty name, tie → the lowest track. ]]
local function name_step(st, io, ps, g, ctx)
  if not io.cname then return end
  local cfg, now = st.cfg, ctx.now
  local function tix(m) return ps.info[m] and ps.info[m].tindex or 1e9 end
  local list, cur, pend = {}, {}, false
  for _, m in ipairs(g.members) do
    if g.linked[m] then
      list[#list + 1] = m
      local s = io.cname(m)
      if s == nil then pend = true else cur[m] = s end
    end
  end
  for m in pairs(g.nbase) do if not g.linked[m] then g.nbase[m] = nil; g.nbad[m] = nil end end
  if #list == 0 then return end
  table.sort(list, function(a, b) return tix(a) < tix(b) end)
  local h = ps.hist[ctx.cur]
  if h and not h.names then h.names = {} end
  local undo = ctx.name_undo and cfg.name_records
  local edited = false                       -- a user rename was detected this tick (record refresh after a delay)
  local moved = false                        -- the group name changed by a join / formation (record refresh at once)
  local nowrite = false
  local function show(s) return s == "" and "(名前なし)" or s end
  if undo then
    local rec = (ctx.name_undo == "known" and h) and h.names[g.ch] or nil
    g.name_refresh = nil
    if rec ~= nil then
      g.name_target, g.name_split = rec, nil
      if g.name ~= rec then log(io, ("Ch %d: undo/redo → container name 「%s」 from the entry's record"):format(g.ch, show(rec))) end
      g.name = rec
      st.stats.name_restores = (st.stats.name_restores or 0) + 1
    else
      -- no record: REAPER's own undo stands; the baseline is re-taken (a member that differs is not a source)
      g.name_target = nil
      local first, same = nil, true
      for _, m in ipairs(list) do
        local s = cur[m]
        if s ~= nil then g.nbase[m] = s; if first == nil then first = s elseif s ~= first then same = false end end
      end
      -- members left with different names stay so (no group name is enforced) until the next rename
      if same and first ~= nil and not pend then g.name, g.name_split = first, nil else g.name_split = true end
      log(io, ("Ch %d: undo/redo onto an entry without a name record (%s): names re-baselined, not spread%s"):format(g.ch,
        ctx.name_undo, g.name_split and " (they differ: left as they are until the next rename)" or ""))
      st.stats.name_rebase = (st.stats.name_rebase or 0) + 1
      nowrite = true
    end
  elseif g.name_target ~= nil then
    -- a record restore that could not reach every member last tick: keep applying it, nothing is detected meanwhile
  elseif g.name == nil then
    if pend then return end                    -- first formation waits until every linked member is readable
    -- voters: the linked members and the members that carry the group's content (they will join next)
    local voters, cnt = {}, {}
    for _, m in ipairs(list) do voters[#voters + 1] = m end
    for _, m in ipairs(g.members) do
      local r = ctx.res[m]
      if not g.linked[m] and r and r.sig == g.agreed_sig then
        local s = io.cname(m)
        if s ~= nil then cur[m] = s; voters[#voters + 1] = m end
      end
    end
    table.sort(voters, function(a, b) return tix(a) < tix(b) end)
    local best, same = nil, true
    for _, m in ipairs(voters) do cnt[cur[m]] = (cnt[cur[m]] or 0) + 1; if cur[m] ~= cur[voters[1]] then same = false end end
    if same then best = cur[voters[1]]
    else
      for _, m in ipairs(voters) do
        local s = cur[m]
        if s ~= "" and (best == nil or cnt[s] > cnt[best]) then best = s end
      end
      log(io, ("Ch %d: container names differ at formation → 「%s」 (most common, tie → lowest track)"):format(g.ch, show(best)))
      if io.event then io.event(("Ch %d: コンテナ名がそろっていなかったので「%s」にそろえました"):format(g.ch, show(best))) end
      moved = true
    end
    g.name, g.name_split = best, nil
  else
    -- change detection among members with a baseline; a linked member without one is a joiner
    local changed, joiners = {}, {}
    for _, m in ipairs(list) do
      local s = cur[m]
      if s ~= nil then
        if g.nbase[m] == nil then joiners[#joiners + 1] = m
        elseif s ~= g.nbase[m] then changed[#changed + 1] = m end
      end
    end
    if #changed > 0 then
      local new, agree = cur[changed[1]], true
      for _, m in ipairs(changed) do if cur[m] ~= new then agree = false end end
      local src = changed[1]
      if not agree then src = pick_struct(ps, changed, ctx); new = cur[src] end
      if new ~= g.name or g.name_split then
        g.name_split = nil
        log(io, ("Ch %d: container name 「%s」 → 「%s」 (renamed on %s%s)"):format(g.ch, show(g.name), show(new), src,
          agree and "" or ", several renamed differently"))
        g.name = new
        edited = true
      end
    end
    for _, j in ipairs(joiners) do
      if g.name_split then                     -- no group name while the members differ: the joiner keeps its own
      elseif g.name == "" and cur[j] ~= "" then
        g.name = cur[j]; moved = true
        log(io, ("Ch %d: %s joins an unnamed group: its name 「%s」 becomes the group's"):format(g.ch, j, cur[j]))
      elseif cur[j] ~= g.name then
        log(io, ("Ch %d: %s joins: takes the group name 「%s」 (was 「%s」)"):format(g.ch, j, show(g.name), show(cur[j])))
      end
    end
  end
  -- spread: every readable linked member whose name differs (Get-compare first: a same-name Set costs as much as a real one)
  local want = g.name_target ~= nil and g.name_target or g.name
  for _, m in ipairs(list) do
    local s = cur[m]
    if s ~= nil and s ~= want and g.nbad[m] ~= s and not nowrite and not g.name_split then
      local rb = io.set_cname(m, want)
      st.stats.name_writes = (st.stats.name_writes or 0) + 1
      if rb ~= want then
        pend = true; g.nbad[m] = rb            -- never rewrite the same refused readback every tick
        log(io, ("Ch %d: container name write to %s did not take (readback 「%s」)"):format(g.ch, m, tostring(rb)))
      else g.nbad[m] = nil end
      cur[m] = rb
    end
  end
  if g.name_split then                         -- the members came back to one name by themselves (e.g. a later undo)
    local first, same = nil, not pend
    for _, m in ipairs(list) do if first == nil then first = cur[m] elseif cur[m] ~= first then same = false end end
    if same and first ~= nil then g.name_split = nil; g.name = first; want = first end
  end
  local agree = not pend and not g.name_split
  for _, m in ipairs(list) do
    if cur[m] ~= nil then g.nbase[m] = cur[m] end
    if cur[m] ~= want then agree = false end
  end
  if g.name_target ~= nil and agree then g.name_target = nil end
  -- name record of the current entry: taken as soon as every linked member agrees (no sweep / readiness gate)
  if not h or ctx.no_record or not agree or not cfg.name_records then return end
  if edited and not ctx.new_entry then
    -- a rename without an undo entry of its own (or one whose entry appears a moment later): the current entry's record
    -- follows only if no new entry appears within name_rec_refresh (precedent: cl_env refresh)
    g.name_refresh = { h = h, at = now + cfg.name_rec_refresh }
  end
  local rf = g.name_refresh
  if rf then
    if rf.h ~= h then g.name_refresh = nil                       -- a new entry appeared: it carries the rename
    elseif now >= rf.at then
      g.name_refresh = nil
      if h.names[g.ch] ~= g.name then
        h.names[g.ch] = g.name
        st.stats.name_rec_refresh = (st.stats.name_rec_refresh or 0) + 1
      end
      return
    else return end
  end
  if h.names[g.ch] == nil or (moved and h.names[g.ch] ~= g.name) then
    h.names[g.ch] = g.name
    st.stats.name_records = (st.stats.name_records or 0) + 1
  end
end
M.name_step = name_step

-- ------------------------------------------------------------------ LINK (DESIGN_V2 §4, review MUST 6 / MUST 9)
local function ev(io, s)                      -- log + persistent event log (Data/TUKONYA_ChainLink/link_log.txt)
  if io.event then io.event(s) else log(io, s) end
end

--- addresses on tracks whose container block was just written moved: scan + resolve again, inside the same tick
local function rescan(io, ps, ctx)
  local recs = io.scan()
  classify(recs)
  for _, r in ipairs(recs) do if r.mid then ps.info[r.mid] = r end end
  for mid in pairs(ps.eff) do ctx.res[mid] = io.resolve(mid) end
  ctx.touched, ctx.focused = io.touched(), io.focused()
  return recs
end

--- the source container per Ch of one request → { {ch, src, notes = {mid...}} } | nil, code, why
local function link_sources(io, ps, recs, req)
  if req.via == "gmem" then
    -- the pressed marker: Ch of the request and its hidden slider3 == the request's nonce
    local hits = {}
    for _, r in ipairs(recs) do
      if r.ch ~= 0 and r.ch == req.ch and io.marker_info then
        local mi = io.marker_info(r.key)
        if mi and mi.req ~= 0 and mi.req == req.nonce then hits[#hits + 1] = { r = r, open = mi.open } end
      end
    end
    for _, h in ipairs(hits) do if io.clear_req then io.clear_req(h.r.key) end end   -- silent [M P12]
    if #hits == 0 then return nil, L.CODE.FAILED, "the pressed marker was not found (nonce)" end
    local pick = hits[1]
    if #hits > 1 then for _, h in ipairs(hits) do if h.open then pick = h; break end end end   -- a stale nonce saved in a project
    local r = pick.r
    if r.issue or not r.mid or ps.eff[r.mid] ~= r.ch then return nil, L.CODE.NOT_MEMBER, "the pressed marker is not a member (" .. tostring(r.issue or "debounce") .. ")" end
    return { { ch = r.ch, src = r.mid, notes = {} } }
  end
  -- the action: every member container on the selected tracks is the source of its own Ch; a Ch reached from several
  -- selected tracks takes the topmost one (the others are noted on their markers)
  local sel = {}
  for _, gd in ipairs(req.guids or {}) do sel[gd] = true end
  local by = {}
  for mid, ch in pairs(ps.eff) do
    local inf = ps.info[mid]
    if inf and sel[inf.tguid] then by[ch] = by[ch] or {}; table.insert(by[ch], mid) end
  end
  local out = {}
  for ch, list in pairs(by) do
    table.sort(list, function(a, b) return ps.info[a].tindex < ps.info[b].tindex end)
    local notes = {}
    for i = 2, #list do notes[#notes + 1] = list[i] end
    out[#out + 1] = { ch = ch, src = list[1], notes = notes }
  end
  table.sort(out, function(a, b) return a.ch < b.ch end)
  if #out == 0 then return nil, L.CODE.NO_CONTAINER, "no member container on the selected tracks" end
  return out
end

--- LINK: the source's container becomes the content of every other container on its Ch, all Chs in one named undo
--- block. Order (DESIGN_V2 §3/§4): container blocks (backup first) → every listed param of every slot → bypass
--- (container + inner) → lanes. Returns ok (false = aborted inside the block), number of Chs linked.
local function run_link(st, io, ps, ctx, entries, rr)
  local cfg, now = st.cfg, ctx.now
  local list, chs, items = {}, {}, {}
  for _, e in ipairs(entries) do
    local g = ps.groups[e.ch]
    if g and ps.eff[e.src] == e.ch and ctx.res[e.src] then
      local targets, decl = {}, {}
      for _, m in ipairs(g.members) do
        if m ~= e.src and ctx.res[m] then targets[#targets + 1] = m end
        if not g.linked[m] then decl[#decl + 1] = m end      -- Ctrl+Z below the LINK: unlinked before → declined again
      end
      if #targets > 0 then
        list[#list + 1] = { e = e, g = g, targets = targets, sig = ctx.res[e.src].sig, ok = {}, ready = {} }
        chs[#chs + 1] = e.ch
        items[#items + 1] = { ch = e.ch, decl = decl }
      end
    else
      ev(io, ("LINK Ch %d: source %s is no longer a member, dropped"):format(e.ch, tostring(e.src)))
    end
  end
  if #list == 0 then return true, 0 end
  table.sort(chs)
  local desc = L.desc(chs)
  -- cfg.link_undo = false (fallback, user decision 2026-10-02): LINK is undo-silent — no named entry, the history record of
  -- the current entry is re-taken from the LINKed state (a later Ctrl+Z of other actions keeps the members agreeing)
  local runner = in_block
  if cfg.link_undo == false then
    runner = function(_, _, _, _, _, _, fn)
      local okr, err = pcall(fn)
      if not okr then ev(io, ("%s (silent): aborted: %s"):format(desc, tostring(err))) end
      return okr
    end
  end
  local ok = runner(st, io, ps, desc, items, nil, function()
    -- 1. structure: even when the content is equal (plugin state and REAPER's per-FX config travel with the block;
    --    same-ident items keep their instance [M P0-1])
    for _, x in ipairs(list) do
      for _, t in ipairs(x.targets) do
        local wok, info = io.copy_struct(x.e.src, t, "LINK")
        st.stats.struct_writes = st.stats.struct_writes + 1
        log(io, ("Ch %d: LINK structure %s -> %s: %s"):format(x.g.ch, x.e.src, t, tostring(info)))
        if wok then x.ok[#x.ok + 1] = t; x.g.wrote[t] = { t = now, sig = x.sig }
        else ev(io, ("LINK Ch %d: block write to %s failed: %s"):format(x.g.ch, t, tostring(info))) end
      end
    end
    rr.recs = rescan(io, ps, ctx)
    -- 2. every listed param of every slot with the source's readback (a block alone is lossy for some plugins, e.g. LED)
    for _, x in ipairs(list) do
      local g, src = x.g, x.e.src
      g.agreed_sig = x.sig
      P.build(st, io, g, src, ctx.res[src])
      g.build_from = nil
      for _, t in ipairs(x.ok) do if ctx.res[t] and ctx.res[t].sig == x.sig then x.ready[#x.ready + 1] = t end end
      local sv = { mid = src, slots = {} }
      for i, xx in ipairs(list) do if xx == x then items[i].src_vals = sv end end
      for _, k in ipairs(g.order) do
        local S0 = g.slots[k]
        local vals = {}
        for _, p in ipairs(S0.meta.list) do if P.synced(S0, p) then vals[p] = io.get(src, k, p) end end
        sv.slots[#sv.slots + 1] = { k = k, ident = S0.ident, vals = vals }
      end
      for _, k in ipairs(g.order) do
        local S = g.slots[k]
        if S.class == "vst" then
          -- the source's (pending) state travels in its block: its agreed blob = now; targets got a whole-state write
          local b = io.blob(src, k)
          local Bs = S.blob[src] or {}
          S.blob[src] = Bs
          if b and b ~= "" then Bs.agreed, Bs.last = b, b end
          Bs.pending, Bs.held = false, nil
          S.deferred, S.defer_until = nil, nil
          if b and b ~= "" then for _, t in ipairs(x.ready) do P.mark_written(S, t, b, now, cfg) end end
        end
        local ls = {}
        for _, p in ipairs(S.meta.list) do if P.synced(S, p) then ls[p] = io.get(src, k, p) end end
        S.last[src] = ls
        for p, v in pairs(ls) do S.agreed[p] = v end
        for _, t in ipairs(x.ready) do
          local lt = {}
          local same_n = ctx.res[t].slots[k] and ctx.res[t].slots[k].n == ctx.res[src].slots[k].n
          for _, p in ipairs(S.meta.list) do
            local v = ls[p]
            if v ~= nil then
              if ctx.held[t] or not same_n then lt[p] = io.get(t, k, p); S.pend[t] = ctx.held[t] or nil
              else lt[p] = io.set(t, k, p, v); st.stats.writes = st.stats.writes + 1 end
            end
          end
          if not same_n then log(io, ("Ch %d slot %s: LINK skipped values on %s (param count differs)"):format(g.ch, tostring(k), t)) end
          S.last[t] = lt
        end
      end
    end
    -- 3. bypass, container and inner (by role, never TrackFX_SetEnabled)
    for _, x in ipairs(list) do
      local g, src = x.g, x.e.src
      for _, k in ipairs(g.order) do
        local S = g.slots[k]
        local es = io.enabled(src, k)
        S.byp[src], S.byp_agreed = es, es
        for _, t in ipairs(x.ready) do
          local et = io.enabled(t, k)
          if et ~= es then
            if ctx.held[t] then S.pend_byp[t] = true
            else et = io.set_bypass(t, k, not es); st.stats.byp_writes = st.stats.byp_writes + 1 end
          end
          S.byp[t] = et
        end
      end
    end
    -- 4. lanes: stopped → now, inside the block; playing → after stop (review Cut 3)
    for _, x in ipairs(list) do
      ENV.reset(x.g)
      if (ctx.playing and not cfg.link_lanes_while_playing) or ctx.settling then x.g.link_lanes = { src = x.e.src }
      else x.lanes = ENV.link_copy(st, io, x.g, x.e.src, x.ready) end
    end
  end)
  -- the Ch's new state: everyone linked to the source, nothing left to ask (LINK is the explicit confirmation)
  for _, x in ipairs(list) do
    local g, src = x.g, x.e.src
    local rdy = {}
    for _, t in ipairs(x.ready) do rdy[t] = true end
    for _, m in ipairs(g.members) do ps.declined[m .. "|" .. g.ch] = nil end
    g.linked = { [src] = true }
    g.asking, g.adopt, g.recheck = {}, {}, {}
    -- per-member bookkeeping from before the LINK must not survive it (a stale post_align[src] would rewrite the source)
    g.post_align, g.pa_done, g.pa_t = {}, {}, {}
    local wr = {}
    for t in pairs(rdy) do wr[t] = g.wrote[t] end
    g.wrote = wr
    g.conflict, g.restore, g.env_restore, g.src_wait = nil, nil, nil, nil
    drop_jobs(ps, function(j) return j.ch == g.ch end)
    for _, m in ipairs(g.members) do
      if m ~= src then
        if rdy[m] then
          g.linked[m] = true
          g.post_align[m] = src; g.pa_t[m] = now; g.pa_done[m] = nil   -- verified again once ready (Waves async state)
        else decline(ps, io, g, m, "LINK: the block write did not take") end
      end
    end
    if not g.slots then g.build_from = src end
    rec_mark_all(g)
    g.link_tick = true
    for _, m in ipairs(g.members) do ps.flash[m] = { code = ST.LINKED, untl = now + cfg.link_flash } end
    for _, m in ipairs(x.e.notes or {}) do ps.flash[m] = { code = ST.LINK_NOTE, untl = now + cfg.link_note } end
    st.stats.links = (st.stats.links or 0) + 1
    ev(io, ("LINK Ch %d: source %s「%s」→ %d of %d targets%s%s%s"):format(g.ch, src, tname(ps, src), #x.ready, #x.targets,
      ctx.playing and " (playing)" or "", x.lanes and (", " .. x.lanes .. " lane writes") or (g.link_lanes and ", lanes after stop" or ""),
      (#(x.e.notes or {}) > 0) and (", " .. #x.e.notes .. " other selected track(s) on this Ch became targets") or ""))
  end
  if cfg.link_undo == false then
    local h = ps.hist[ctx.cur]
    if h then for _, x in ipairs(list) do h.ch[x.g.ch] = nil end end   -- re-recorded from the LINKed state once settled
  end
  ctx.no_record = true            -- (with an undo entry) the current entry is still the one before the LINK
  return ok, #list
end

--- requests from the marker button (gmem) and the action (ExtState); held ones (recording) once the transport stopped
local function link_step(st, io, ps, ctx, rr)
  local cfg, now = st.cfg, ctx.now
  local reqs = io.link_requests and io.link_requests() or {}
  local run, acks = {}, {}
  for _, req in ipairs(reqs) do
    local what = req.via == "gmem" and ("marker Ch %d"):format(req.ch or 0) or ("action, %d selected track(s)"):format(#(req.guids or {}))
    if (req.skipped or 0) > 0 then ev(io, ("LINK: %d earlier request(s) superseded by a newer one"):format(req.skipped)) end
    if L.expired(req, now, cfg.link_max_age) then
      ev(io, ("LINK request expired (%s, age %.1f s): not executed"):format(what, now - (tonumber(req.t) or 0)))
      if io.link_ack then io.link_ack(req, L.CODE.EXPIRED, L.TEXT[L.CODE.EXPIRED]) end
    else
      local entries, code, why = link_sources(io, ps, rr.recs, req)
      local real = {}
      for _, e in ipairs(entries or {}) do local g = ps.groups[e.ch]; if g and #g.members >= 2 then real[#real + 1] = e end end
      if not entries then code = code
      elseif #real == 0 then code, why = L.CODE.SINGLE, "only one container on that Ch"
      elseif ctx.recording or (ctx.playing and cfg.link_hold_while_playing) then
        for _, e in ipairs(real) do ps.link_hold[e.ch] = e end          -- latest per Ch wins
        if ctx.recording then code, why = L.CODE.HELD, "recording: held until the transport stops"
        else code, why = L.CODE.HELD_PLAY, "playing: held until the transport stops" end
      else
        for _, e in ipairs(real) do run[#run + 1] = e end
        acks[#acks + 1] = req
        code = nil
      end
      if code then
        ev(io, ("LINK request (%s): %s"):format(what, why or L.TEXT[code]))
        if io.link_ack then io.link_ack(req, code, L.TEXT[code]) end
      end
    end
  end
  if not ctx.recording and not ctx.settling and not (ctx.playing and cfg.link_hold_while_playing) and next(ps.link_hold) then
    local held = {}
    for _, e in pairs(ps.link_hold) do held[#held + 1] = e end
    table.sort(held, function(a, b) return a.ch < b.ch end)
    for _, e in ipairs(held) do table.insert(run, 1, e) end         -- a request of this tick for the same Ch comes later = wins
    ps.link_hold = {}
    ev(io, ("LINK: %d held request(s) executed after the transport stopped"):format(#held))
  end
  if #run == 0 then return end
  local per, order = {}, {}
  for _, e in ipairs(run) do if not per[e.ch] then order[#order + 1] = e.ch end; per[e.ch] = e end
  local list = {}
  for _, ch in ipairs(order) do list[#list + 1] = per[ch] end
  local ok = run_link(st, io, ps, ctx, list, rr)
  for _, req in ipairs(acks) do
    if io.link_ack then
      if ok then io.link_ack(req, L.CODE.DONE, L.TEXT[L.CODE.DONE]) else io.link_ack(req, L.CODE.FAILED, L.TEXT[L.CODE.FAILED]) end
    end
  end
end
M.link_sources = link_sources

-- ------------------------------------------------------------------ Ch picker data + rename (HANDOVER 2026-10-08)
--- what the markers' Ch list shows: per Ch the number of TRACKS whose marker is set to it (every marker, whatever its
--- state: "taken" for the free-Ch choice must also hold during the debounce), the group's container name, the lowest free Ch
local function ch_info(io, ps, recs)
  local uses, seen, names = {}, {}, {}
  for _, r in ipairs(recs or {}) do
    local ch = r.ch or 0
    if ch >= 1 and ch <= 16 then
      local k = tostring(r.tguid) .. "#" .. ch
      if not seen[k] then seen[k] = true; uses[ch] = (uses[ch] or 0) + 1 end
    end
  end
  for ch = 1, 16 do
    if uses[ch] then
      local g = ps.groups[ch]
      local nm = g and (g.name_target ~= nil and g.name_target or g.name) or nil
      if nm == nil and g and io.cname then
        for _, m in ipairs(g.members) do local x = io.cname(m); if x ~= nil then nm = x; break end end
      end
      names[ch] = nm or ""
    end
  end
  return { uses = uses, names = names, free = L.free_ch(uses) }
end
M.ch_info = ch_info

--- rename requests from a marker (gmem): expired ones are dropped (MUST 6); the others wait for the end of the tick
local function rename_collect(st, io, ps, ctx)
  if not io.rename_requests then return end
  for _, req in ipairs(io.rename_requests()) do
    if L.expired(req, ctx.now, st.cfg.link_max_age) then
      ev(io, ("rename request expired (Ch %d, age %.1f s): not executed"):format(req.ch or 0, ctx.now - (tonumber(req.t) or 0)))
      if io.rename_ack then io.rename_ack(req, L.RN.EXPIRED) end
    elseif not ps.groups[req.ch or 0] then
      ev(io, ("rename request for Ch %d: no container on that Ch"):format(req.ch or 0))
      if io.rename_ack then io.rename_ack(req, L.RN.FAILED) end
    else
      ps.renames = ps.renames or {}
      ps.renames[#ps.renames + 1] = req
    end
  end
end

--- a Ch was picked in a marker's list: the slider is already set (and the host told), but that alone makes no undo entry
--- (MBP 2026-10-08), so the next unrelated entry would swallow it and its Ctrl+Z would silently bring the old Ch back.
--- One empty named undo block captures the state with the new Ch (an empty EndBlock still makes an entry).
local function pick_collect(st, io, ps, ctx)
  if not io.pick_requests then return end
  for _, req in ipairs(io.pick_requests()) do
    if L.expired(req, ctx.now, st.cfg.link_max_age) then
      ev(io, ("Ch pick notice expired (Ch %d, age %.1f s): no undo entry"):format(req.ch or 0, ctx.now - (tonumber(req.t) or 0)))
    elseif (req.ch or -1) < 0 or req.ch > 16 then
      ev(io, "Ch pick notice with a bad Ch: ignored")
    else
      io.begin_block()
      io.end_block(L.pick_desc(req.ch))
      st.stats.picks = (st.stats.picks or 0) + 1
      log(io, ("Ch pick: %s → one undo entry"):format(L.pick_desc(req.ch)))
    end
  end
end

--- one rename: the input window (modal), then every container of the Ch gets the name inside ONE named undo block
local function rename_run(st, io, ps, ctx, req)
  local ack = function(code) if io.rename_ack then io.rename_ack(req, code) end end
  local g = ps.groups[req.ch]
  if not g or #g.members == 0 or not io.ask_name then ack(L.RN.FAILED); return end
  local cur = g.name_target ~= nil and g.name_target or g.name
  if cur == nil or g.name_split then
    cur = nil
    for _, m in ipairs(g.members) do local x = io.cname(m); if x ~= nil and x ~= "" then cur = x; break end end
  end
  if io.rename_busy then io.rename_busy(true) end
  local okq, ans = pcall(io.ask_name, req.ch, cur or "")
  if io.rename_busy then io.rename_busy(false) end
  if not okq then error(ans, 0) end
  st.stats.rename_dialogs = (st.stats.rename_dialogs or 0) + 1
  ps.last_now = io.now()                      -- the dialog blocked the loop: the next tick's dt starts from here
  if ans == nil then ack(L.RN.CANCELLED); return end
  local new = tostring(ans):gsub("[\0-\31\127]", " "):gsub("^%s+", ""):gsub("%s+$", "")
  -- the dialog was modal, but addresses are re-read (a chunk write in this tick moved them) before anything is written
  rescan(io, ps, ctx)
  g = ps.groups[req.ch]
  if not g or #g.members == 0 then ack(L.RN.FAILED); return end
  local todo = {}
  for _, m in ipairs(g.members) do
    local s = io.cname(m)
    if s ~= nil and s ~= new then todo[#todo + 1] = m end
  end
  if #todo == 0 then ack(L.RN.UNCHANGED); return end
  -- the entry we are on keeps the OLD name as its record (else the name step would record the new name onto it and one
  -- Ctrl+Z would restore the new name)
  local h = ps.hist[ctx.cur]
  if h then
    h.names = h.names or {}
    if h.names[req.ch] == nil and g.name ~= nil and g.name_target == nil and not g.name_split then h.names[req.ch] = g.name end
  end
  local desc = ("Container Link: Ch %d の名前を変更"):format(req.ch)
  local okw, bad = true, {}
  io.begin_block()
  local okp, err = pcall(function()
    for _, m in ipairs(todo) do
      local rb = io.set_cname(m, new)
      st.stats.name_writes = (st.stats.name_writes or 0) + 1
      if rb ~= new then okw = false; bad[#bad + 1] = m end
    end
  end)
  io.end_block(desc)
  if not okp then ev(io, ("%s: aborted inside the undo block: %s"):format(desc, tostring(err))); ack(L.RN.FAILED); return end
  -- bookkeeping: the members now agree on `new`; the next tick sees the block's entry and records the name on it
  g.name, g.name_target, g.name_split, g.name_refresh = new, nil, nil, nil
  for _, m in ipairs(g.members) do
    if g.linked[m] then g.nbase[m] = new; g.nbad[m] = nil end
  end
  for _, m in ipairs(bad) do g.nbad[m] = io.cname(m); g.nbase[m] = io.cname(m) end
  st.stats.renames = (st.stats.renames or 0) + 1
  ev(io, ("Ch %d: 名前を「%s」にしました（%d 本中 %d 本を書き換え）%s"):format(req.ch, new == "" and "(名前なし)" or new, #g.members, #todo - #bad,
    okw and "" or ("、書けなかったもの " .. #bad .. " 本")))
  ack(okw and L.RN.DONE or L.RN.FAILED)
end
M.rename_run = rename_run

-- ------------------------------------------------------------------ tick
local function prof(st, name, t0, t1)
  local p = st.prof[name]
  if not p then p = { sum = 0, max = 0, n = 0 }; st.prof[name] = p end
  local d = t1 - t0
  p.sum = p.sum + d; p.n = p.n + 1
  if d > p.max then p.max = d end
  return t1
end

--- R4b: every watched slot with a pending difference commits now (project change, atexit). Silent writes.
function M.commit_pending(st, io, ps)
  ps = ps or st.current
  if not ps then return 0 end
  local recs = io.scan()
  classify(recs)
  local ctx = { now = io.now(), cfg = st.cfg, held = {}, selected = {}, res = {}, playing = false, recording = false, loading = {} }
  for mid in pairs(ps.eff) do ctx.res[mid] = io.resolve(mid); ctx.selected[mid] = ps.info[mid] and ps.info[mid].selected end
  ctx.touched, ctx.focused = io.touched(), io.focused()
  local n = 0
  for _, g in pairs(ps.groups) do
    if g.slots then
      for _, k in ipairs(g.order) do
        local S = g.slots[k]
        local mem = {}
        for _, m in ipairs(P.slot_members(g, S)) do if ctx.res[m] then mem[#mem + 1] = m end end
        if #mem >= 2 then n = n + BL.commit_all(st, io, ps, g, S, mem, ctx) end
      end
    end
  end
  if n > 0 and io.blog then io.blog(("commit_pending | %d watched slot(s) committed before leaving the project"):format(n)) end
  return n
end

function M.tick(st, io)
  local cfg = st.cfg
  st.stats.ticks = st.stats.ticks + 1
  local now = io.now()
  local clock = io.clock or io.now
  local tp = clock()
  local pkey = io.project()
  if st.cur_key and pkey ~= st.cur_key and st.current and io.with_project then
    -- R4b: the project we leave commits its pending hidden-state edits first
    local old, okey = st.current, st.cur_key
    pcall(io.with_project, okey, function() M.commit_pending(st, io, old) end)
  end
  st.cur_key = pkey
  local ps = st.projects[pkey]
  if not ps then ps = new_ps(now); st.projects[pkey] = ps end
  st.current = ps

  -- 1. markers, issues, Ch debounce
  local recs = io.scan()
  classify(recs)
  local seen = {}
  for _, r in ipairs(recs) do
    local mid = r.mid
    if mid then
      seen[mid] = true
      ps.info[mid] = r
      local c = ps.cand[mid]
      if not c or c.ch ~= r.ch then c = { ch = r.ch, since = now }; ps.cand[mid] = c end
      if ps.eff[mid] ~= nil and ps.eff[mid] ~= r.ch then leave(ps, mid) end
      if ps.eff[mid] == nil and r.ch ~= 0 and now - c.since >= cfg.debounce then
        ps.eff[mid] = r.ch
        local g = group(ps, r.ch)
        g.members[#g.members + 1] = mid
      end
    end
  end
  for mid in pairs(ps.info) do
    if not seen[mid] then leave(ps, mid); ps.cand[mid] = nil; ps.info[mid] = nil end
  end

  tp = prof(st, "scan", tp, clock())
  -- 2. undo / redo / project load → history guard (before any election), readiness window, blob re-baseline
  local u = io.undo()
  -- chained undo/redo: our sync entry and the user's entry below it move together, so one Ctrl+Z / Ctrl+Shift+Z leaves
  -- every member identical and the guard never re-syncs mid-chain (RESULTS_SOOTHE_REORDER §2c a')
  local chained = false
  if ps.last_cur ~= nil and u.sc ~= ps.last_sc then
    local pr_u = ps.pairs and ps.pairs[ps.last_cur]                 -- our entry just undone: its partner must be where we land
    local pr_r = ps.pairs and ps.pairs[u.cur + 1]                   -- a redo landed on a partner whose sync entry follows
    if ps.last_u and ps.last_u.desc == M.SYNC_DESC and u.cur == ps.last_cur - 1 and not (pr_u and pr_u.desc == u.desc and pr_u.time == u.time) then
      log(io, "an undone structure-sync entry has no matching partner below it: not chained (history guard)")
    end
    if u.cur == ps.last_cur - 1 and ps.last_u and ps.last_u.desc == M.SYNC_DESC and pr_u and pr_u.desc == u.desc and pr_u.time == u.time and io.do_undo then
      io.do_undo(); u = io.undo(); chained = true
      st.stats.chained = (st.stats.chained or 0) + 1
      log(io, "undo chained: our structure sync and the user's entry below it")
    elseif u.cur == ps.last_cur + 1 and u.desc ~= M.SYNC_DESC and io.redo_desc and io.redo_desc() == M.SYNC_DESC
           and pr_r and pr_r.desc == u.desc and pr_r.time == u.time then
      io.do_redo(); u = io.undo(); chained = true
      st.stats.chained = (st.stats.chained or 0) + 1
      log(io, "redo chained: the user's entry and our structure sync above it")
    end
    if chained then                                   -- REAPER changed the chains after this tick's scan: scan again
      recs = io.scan()
      classify(recs)
      for _, r in ipairs(recs) do if r.mid then ps.info[r.mid] = r end end
    end
  end
  local reload = ps.first
  ps.first = false
  local name_undo, new_entry = nil, false        -- for name_step: "known" / "unknown" = the undo position moved onto it
  if ps.last_cur == nil then
    if not H.match(ps.hist[u.cur], u) then H.new_entry(st, ps, u, false); new_entry = true end
  elseif u.sc ~= ps.last_sc then
    local known = H.match(ps.hist[u.cur], u)
    local lu = ps.last_u
    local back = u.cur < ps.last_cur and u.desc == lu.pdesc and u.time == lu.ptime
    if known and u.cur ~= ps.last_cur then
      -- undo/redo onto a known entry: each Ch with a record gets a restore plan (applied when allowed, MUST 3)
      reload = true
      name_undo = "known"
      st.stats.undo_events = st.stats.undo_events + 1
      local h = ps.hist[u.cur]
      for ch, g in pairs(ps.groups) do
        local rec = h.ch[ch]
        -- a chained pair: REAPER's own snapshots of both entries already leave every member consistent; the guard must
        -- not re-sync in either direction (its chunk writes would be outside REAPER's snapshots)
        if chained then rec = nil end
        g.restore = rec and { rec = rec, t0 = now } or nil
        g.env_restore = rec and rec.env and { env = rec.env.lanes, members = rec.env.members,
                                              -- onto a LINK entry: its lanes may have been written after stop, outside the
                                              -- entry's snapshot → restore them even if no member "changed" (3rd attempt)
                                              force = (u.desc or ""):find("を LINK", 1, true) ~= nil } or nil
        g.wrote = {}
        g.conflict = nil
      end
    elseif not known then
      -- a new action (prune the redo side) — or an undo to an entry we never saw (keep the redo side)
      H.new_entry(st, ps, u, not back and not chained)              -- a chain landing on an unknown entry keeps the redo side
      if ps.pair_pending and u.desc == M.SYNC_DESC and u.cur > ps.last_cur then
        ps.pairs = ps.pairs or {}
        ps.pairs[u.cur] = ps.pair_pending
      end
      if ps.confirm_pending and u.desc == ps.confirm_pending.desc and u.cur > ps.last_cur then
        ps.confirm[u.cur] = ps.confirm_pending
      end
      if u.cur < ps.last_cur then reload = true; name_undo = "unknown"; st.stats.undo_events = st.stats.undo_events + 1
      else
        new_entry = true
        -- a new entry drops a restore plan that never applied: the readback baseline is from before REAPER's undo/redo
        -- (elections wait while a plan is pending) → re-baseline from the plan's record, else REAPER's own restore on a
        -- member counts as a "user change" next to the real one (DEVLOG 2026-10-02 14:10–, MBP v2_undoredo E1)
        for _, g in pairs(ps.groups) do
          if g.restore then
            local nr, nf = H.rebaseline(g, g.restore)
            st.stats.rebaselines = (st.stats.rebaselines or 0) + 1
            log(io, ("Ch %d: a new entry dropped the pending undo restore → baseline from its record (%d slot(s)), re-read (%d)"):format(g.ch, nr, nf))
          end
        end
      end
      for _, g in pairs(ps.groups) do g.restore = nil; g.env_restore = nil end
    end
    for _, g in pairs(ps.groups) do rec_mark_all(g) end                -- a record needs a fresh full sweep (MUST 1)
  end
  ps.confirm_pending = nil
  if u.sc ~= ps.last_sc then ps.pair_pending = nil end
  -- P1_REVIEW MUST 2: moved below a confirmed alignment → its joiners are declined (never a source) before elections
  if ps.last_cur and u.cur < ps.last_cur then
    for idx, c in pairs(ps.confirm) do
      if idx > u.cur and idx <= ps.last_cur then
        for _, it in ipairs(c.items) do
          local g = ps.groups[it.ch]
          for _, m in ipairs(it.decl) do
            ps.declined[m .. "|" .. it.ch] = true
            if it.src_vals and it.src_vals.mid == m and not it.src_queued then
              -- the LINK source's own values from the LINK time: REAPER's undo may re-apply its lossy state (LED Ratio)
              ps.src_fix = ps.src_fix or {}
              ps.src_fix[#ps.src_fix + 1] = { v = it.src_vals, t = now, n = 0 }
            end
            if g and g.linked[m] then g.linked[m] = nil; P.forget(g, m); log(io, ("Ch %d: %s declined (its confirmed alignment was undone)"):format(it.ch, m)) end
            if g then g.adopt[m] = nil; g.post_align[m] = nil end
          end
        end
      end
    end
  end
  -- redo across a LINK entry: LINK was the explicit confirmation, so the members it declined-on-undo are members again
  -- (else the record restore finds no carrier among the linked members; MBP RESULTS_V2 (3), review SHOULD 6)
  if ps.last_cur and u.cur > ps.last_cur then
    for idx, c in pairs(ps.confirm) do
      if idx > ps.last_cur and idx <= u.cur and c.desc and c.desc:find("を LINK", 1, true) then
        for _, it in ipairs(c.items) do for _, m in ipairs(it.decl) do ps.declined[m .. "|" .. it.ch] = nil end end
      end
    end
  end
  ps.last_cur, ps.last_sc, ps.last_u = u.cur, u.sc, u

  -- 3. transport, holds, per-member context
  local playing = io.playing()
  local override = io.override()
  if ps.was_playing and not playing then ps.settle = cfg.settle_ticks end
  ps.was_playing = playing
  local flush = false
  if ps.settle > 0 then ps.settle = ps.settle - 1; flush = (ps.settle == 0) end
  local settling = ps.settle > 0
  if reload then ps.blob_quiet_until = now + cfg.blob_grace; ps.t_reload = now end
  local ctx = { now = now, cfg = cfg, playing = playing, held = {}, selected = {}, res = {}, flush = flush, reload = reload,
                blob_quiet = now < (ps.blob_quiet_until or 0), recording = io.recording and io.recording() or false,
                loading = {}, cur = u.cur, settling = settling, u = u, name_undo = name_undo, new_entry = new_entry }
  for mid in pairs(ps.eff) do
    local r = ps.info[mid]
    ctx.held[mid] = playing and held_mode(r.automode, override)
    ctx.selected[mid] = r.selected
    ctx.res[mid] = io.resolve(mid)
  end
  -- after resolve: io maps REAPER's touched/focused FX address onto (member, slot) with this tick's addresses
  ctx.touched, ctx.focused = io.touched(), io.focused()
  -- LINK undone: the source gets its own LINK-time values back (now and once more 0.5 s later; skipped on params that have
  -- an active lane on it, and while it is held by Touch/Latch/Write)
  if ps.src_fix and #ps.src_fix > 0 then
    local keep = {}
    for _, f in ipairs(ps.src_fix) do
      local mid = f.v.mid
      local r = ctx.res[mid]
      if r and not ctx.held[mid] and now >= f.t + 0.5 * f.n then
        local ed = io.env_driven and io.env_driven(mid) or {}
        local nw = 0
        for _, sl in ipairs(f.v.slots) do
          local info = r.slots[sl.k]
          if info and info.ident == sl.ident then
            for p, v in pairs(sl.vals) do
              if not (ed[sl.k] and ed[sl.k][p]) and math.abs((io.get(mid, sl.k, p) or v) - v) > 1e-9 then io.set(mid, sl.k, p, v); nw = nw + 1 end
            end
          end
        end
        f.n = f.n + 1
        log(io, ("LINK undone: source %s values restored (%d writes, pass %d)"):format(mid, nw, f.n))
      end
      if f.n < 2 and now - f.t < 5 then keep[#keep + 1] = f end
    end
    ps.src_fix = keep
  end
  -- js mouse (DESIGN_V2 §2.2): global left button, edges per tick; nil without js_ReaScriptAPI
  do
    local ms = io.mouse and io.mouse()
    if ms then
      ctx.mouse = { down = ms.down, press = ms.down and not st.mdown, release = (not ms.down) and st.mdown or false }
      st.mdown = ms.down
    end
  end

  -- 3b. LINK requests (button / action) and held LINKs (recording) — may rewrite blocks, then rescans
  do
    local rr = { recs = recs }
    link_step(st, io, ps, ctx, rr)
    recs = rr.recs
  end
  rename_collect(st, io, ps, ctx)
  pick_collect(st, io, ps, ctx)

  tp = prof(st, "resolve", tp, clock())
  -- 4. groups
  local order = {}
  for ch, g in pairs(ps.groups) do
    if #g.members == 0 then ps.groups[ch] = nil; drop_jobs(ps, function(j) return j.ch == ch end)
    else order[#order + 1] = ch end
  end
  table.sort(order)
  local counts = {}
  for _, ch in ipairs(order) do
    local g = ps.groups[ch]
    ctx.wrote_struct = false
    if g.link_tick then g.link_tick = nil; member_states(ps, g, ctx, true)   -- LINKed this tick: verified from the next one
    else
      -- names first: on an undo tick process_group may return early (restore pending), the names must not wait for it
      name_step(st, io, ps, g, ctx)
      process_group(st, io, ps, g, ctx, settling)
    end
    -- MUST 1 per slot: a slot that is not swept this tick (suspended by readiness / settling / an early return while a
    -- restore waits, or fewer than 2 members) starts its fresh full sweep again — its readback may be older than REAPER's
    -- last undo/redo (DEVLOG 2026-10-02 14:10–, MBP v2_undoredo E2)
    if g.slots then
      for _, k in ipairs(g.order) do
        local S = g.slots[k]
        if S.suspended or not S.mem or #S.mem < 2 then S.rec_mark = S.swept or 0 end
      end
    end
    local n = 0
    for _ in pairs(g.linked) do n = n + 1 end
    counts[ch] = n
  end
  io.publish(counts)
  if io.publish_ch then io.publish_ch(ch_info(io, ps, recs)) end
  if ctx.mouse and ctx.mouse.press and ctx.any_watched and not ctx.hit_any and not st.nomatch_logged then
    st.nomatch_logged = true
    if io.blog then io.blog("fallback | a press over a watched window never matched its window: watch end only (logged once per session)") end
  end
  tp = prof(st, "groups", tp, clock())

  -- 5. cold sweep of every synced value within the budget (round robin across groups and slots)
  if not settling then
    local units = {}
    local dunits = {}
    for _, ch in ipairs(order) do
      local g = ps.groups[ch]
      if g.slots then
        for _, k in ipairs(g.order) do
          local S = g.slots[k]
          if not S.suspended and S.mem and #S.mem >= 2 then
            for i = 1, #S.meta.list, cfg.sweep_chunk do units[#units + 1] = { g, S, i } end
            for _, m in ipairs(S.mem) do
              for i = 1, #S.meta.list, cfg.dyn_chunk do dunits[#dunits + 1] = { S, m, i } end
            end
          end
        end
      end
    end
    if #units > 0 then
      local t0 = clock()
      local dt = ps.last_now and math.max(0, math.min(0.5, now - ps.last_now)) or 0.03
      ps.sweep_acc = (ps.sweep_acc or 0) + #units * dt / cfg.sweep_period
      local want = math.max(1, math.min(#units, math.floor(ps.sweep_acc)))
      ps.sweep_acc = math.max(0, ps.sweep_acc - want)
      local start = ps.rr % #units
      local done = 0
      for d = 0, want - 1 do
        local un = units[(start + d) % #units + 1]
        P.sweep(st, io, un[1], un[2], un[2].mem, ctx, un[3], un[3] + cfg.sweep_chunk - 1)
        un[2].swept = (un[2].swept or 0) + 1                           -- per slot (MUST 1, cl_hist H.settled)
        done = done + 1
        if clock() - t0 > cfg.budget then break end
      end
      ps.rr = (start + done) % #units
      st.stats.sweep_units = st.stats.sweep_units + done
      ps.swept = (ps.swept or 0) + done
      if ps.swept >= #units then ps.swept = ps.swept - #units; st.stats.full_sweeps = st.stats.full_sweeps + 1 end
    end
    if #dunits > 0 then
      ps.dyn_rr = ps.dyn_rr % #dunits + 1
      local du = dunits[ps.dyn_rr]
      P.dyn_refresh(st, io, du[1], du[2], du[3], du[3] + cfg.dyn_chunk - 1)
    end
  end

  tp = prof(st, "sweep", tp, clock())
  -- 6. marker status (written only on change by io; never to a held track while playing)
  for _, r in ipairs(recs) do
    if r.issue ~= "offline" then
      local code = ST.OK
      if r.issue == "outside" then code = ST.OUTSIDE
      elseif r.issue == "nested" then code = ST.NESTED
      elseif r.issue == "dup" then code = ST.DUP
      elseif r.ch ~= 0 then
        local ch = ps.eff[r.mid]
        if ch == nil then code = ST.DEBOUNCE
        else code = (ps.groups[ch] and ps.groups[ch].state[r.mid]) or ST.LOADING end
        local fl = ps.flash[r.mid]
        if ch and ps.link_hold[ch] and ps.link_hold[ch].src == r.mid then code = (ctx.recording or not cfg.link_hold_while_playing) and ST.LINK_HOLD or ST.LINK_HOLD_PLAY
        elseif fl then if now < fl.untl then code = fl.code else ps.flash[r.mid] = nil end end
      end
      if not (playing and held_mode(r.automode, override)) then io.set_status(r, code) end
    end
  end

  ps.last_now = now
  tp = prof(st, "status", tp, clock())

  -- 7. dialogs: only when stopped, one per tick
  local ran_dialog = false
  if not playing and #ps.jobs > 0 then
    local job = table.remove(ps.jobs, 1)
    run_job(st, io, ps, job, ctx)
    ran_dialog = true
  end
  -- the rename window (user-initiated from a marker): one modal per tick, after the join dialogs; allowed while playing
  if not ran_dialog and ps.renames and #ps.renames > 0 then
    local req = table.remove(ps.renames, 1)
    rename_run(st, io, ps, ctx, req)
  end
  return ps
end

return M
