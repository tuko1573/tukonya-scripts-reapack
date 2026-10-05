--[[
  cl_blob.lua — TUKONYA Container Link: hidden state by commit points (DESIGN_V2 §2, re-review R1–R4). Pure Lua.

  Per (member m, slot S) state S.blob[m] = B:
    agreed   m's own blob as last agreed (never compared across members: Pro-Q 3 blobs differ per instance [M])
    last     last read; pending = (last ≠ agreed) while watched; t_change = when last changed
    watched  watched in the previous tick; pressed = a js press matched this slot's window (js-backed) since agreement
    t_up     js button-up time; recheck = one extra commit check at t_up + 0.5 s
    quiet_until / wrote / quiet_keep   after our whole-state write (cl_params.mark_written)
    held     {src, blob, js, t}: an inbound spread held over this member's pending edit (R3)
  INVARIANT (tested): a pending difference ends only by its own commit, an explicit LINK / undo restore, or by losing a
  logged conflict to a newer commit. A misclassification costs latency, never an edit.
  Commit events: watch end (always), js mouse-up in the slot's window (+0.15 s, re-check +0.5 s), live settle 0.3 s for
  idents classified "stable", project change / atexit (commit_all). Spread = pending value spreads first, then
  cl_params.blob_write (blob → all params → roles → bypass) per target, ranked against pending targets (§2.3).
--]]
local P = require("cl_params")
local CL = require("cl_blobclass")
local M = {}

local function log(io, s) if io.log then io.log(s) end end
local function blog(io, s) if io.blog then io.blog(s) else log(io, s) end end
local function today(io) return io.today and io.today() or os.date("%Y-%m-%d") end

-- ------------------------------------------------------------------ watched (§2.1; `touched` never used)
local function info_of(ctx, m, k) return ctx.res[m] and ctx.res[m].slots[k] end
function M.watched(S, m, ctx)
  if ctx.force_end then return false end
  local info = info_of(ctx, m, S.k)
  local f = ctx.focused
  return (info and (info.open or info.chain)) or (f and f.mid == m and f.k == S.k) or false
end
local function multi(S, m, ctx) local info = info_of(ctx, m, S.k); return info and info.chain_multi end
local function invisible(S, m, ctx) local info = info_of(ctx, m, S.k); return info and info.invisible end

-- ------------------------------------------------------------------ class store (§2.4)
local function classes(st, io)
  if not st.bclass then
    local text = io.class_load and io.class_load() or nil
    st.bclass = CL.parse(text)
  end
  return st.bclass
end
local function class_of(st, io, ident) return CL.get(classes(st, io), ident) end
local function save_classes(st, io)
  local s = st.bclass
  if s and s.dirty and io.class_save then io.class_save(CL.serialize(s)); s.dirty = false end
end
local function tracks_of(ctx, list)
  local t = {}
  for _, m in ipairs(list) do local r = ctx.res[m]; t[#t + 1] = r and r.tname or tostring(m) end
  return table.concat(t, ",")
end

-- ------------------------------------------------------------------ writes into one target (ranked, §2.3 / R3)
local function hold(io, g, S, t, src, blob, js, ctx, why)
  local Bt = S.blob[t]
  Bt.held = { src = src, blob = blob, js = js, t = ctx.now }
  log(io, ("Ch %d slot %s: spread from %s held over %s (%s)"):format(g.ch, tostring(S.k), src, t, why))
end

local function write_to(st, io, g, S, src, t, blob, ctx)
  P.blob_write(st, io, g, S, src, t, blob, ctx)
  S.wit_until = ctx.now + 10                    -- witness reads on the targets for 10 s (§2.4)
end

--- spread the committed blob of src to every other member of the slot
local function spread(st, io, ps, g, S, mem, src, blob, js, ctx)
  local mouse = ctx.mouse
  for _, t in ipairs(mem) do
    if t ~= src then
      local Bt = S.blob[t]
      if not Bt then Bt = {}; S.blob[t] = Bt end
      if ctx.held[t] then S.pend_blob[t] = src
      elseif Bt.watched and mouse and mouse.down then hold(io, g, S, t, src, blob, js, ctx, "button down in its window")
      elseif Bt.pending then
        if Bt.pressed and not js then hold(io, g, S, t, src, blob, js, ctx, "its own js-backed pending edit wins over a non-js commit")
        elseif js and not Bt.pressed then
          write_to(st, io, g, S, src, t, blob, ctx)
          blog(io, ("conflict | %s | js-backed commit on %s overwrote a pending edit without a press (wheel/keyboard) on %s"):format(S.ident, tracks_of(ctx, { src }), tracks_of(ctx, { t })))
        else hold(io, g, S, t, src, blob, js, ctx, "pending on both: the later commit wins") end
      else write_to(st, io, g, S, src, t, blob, ctx) end
    end
  end
  st.stats.blob_fires = st.stats.blob_fires + 1
end

-- ------------------------------------------------------------------ ping-pong guard (§2.3): defer, never drop (R4a)
local function guard(io, g, S, src, js, ctx)
  local now = ctx.now
  local h = S.pp or {}
  local keep = {}
  for _, e in ipairs(h) do if now - e.t <= 10 then keep[#keep + 1] = e end end
  keep[#keep + 1] = { t = now, src = src, js = js }
  S.pp = keep
  if js then return false end
  local nonjs = 0
  for _, e in ipairs(keep) do if not e.js then nonjs = nonjs + 1 end end
  local n = #keep
  local alt = n >= 3 and keep[n].src == keep[n - 2].src and keep[n - 1].src ~= keep[n].src
  return nonjs >= 3 or alt
end

--- one commit of member m (its last read differs from its agreed blob)
local function commit(st, io, ps, g, S, mem, m, ctx, trig)
  local B = S.blob[m]
  local blob = B.last
  local js = B.pressed and trig == "js" and not multi(S, m, ctx)
  -- a held inbound write over m is discarded: m's own newer commit wins (R3); the loser is told on its marker
  if B.held then
    local loser = B.held.src
    blog(io, ("conflict | %s | %s's commit wins over the held spread from %s"):format(S.ident, tracks_of(ctx, { m }), tracks_of(ctx, { loser })))
    if ps.flash then ps.flash[loser] = { code = 13, untl = ctx.now + 4 } end
    B.held = nil
  end
  -- pending value edits of this slot first (§2.3)
  for _, p in ipairs(S.meta.list) do if P.synced(S, p) then P.check(st, io, g, S, p, mem, ctx) end end
  local backed = B.pressed and not multi(S, m, ctx)
  B.agreed = blob; B.pending = false; B.pressed = false; B.t_up = nil; B.recheck = nil
  -- ping-pong guard: defer (keep the latest commit), never drop
  if S.deferred and js then
    blog(io, ("deferral ended by a js commit | %s | Ch %d"):format(S.ident, g.ch))
    S.deferred, S.defer_until = nil, nil
  end
  if S.deferred or guard(io, g, S, m, backed, ctx) then
    if not S.deferred then
      S.defer_until = ctx.now + 30
      blog(io, ("deferral | %s | Ch %d | 3 commits in 10 s or A→B→A without a press: hidden-state spreads of this slot wait ≤ 30 s"):format(S.ident, g.ch))
    end
    S.deferred = { src = m, blob = blob, js = js, t = ctx.now }
    return
  end
  log(io, ("Ch %d slot %s: hidden state of %s committed (%s)"):format(g.ch, tostring(S.k), m, trig))
  spread(st, io, ps, g, S, mem, m, blob, js, ctx)
end

-- ------------------------------------------------------------------ witness reads → classification (§2.4)
local function witness(st, io, g, S, mem, ctx, ps)
  local cfg, now = ctx.cfg, ctx.now
  if ctx.playing and not cfg.witness_while_playing then return end
  local cs = classes(st, io)
  local first = not (cs.e[S.ident]) and not (st.bseen and st.bseen[S.ident])
  if first then
    st.bseen = st.bseen or {}; st.bseen[S.ident] = true
    S.wit_until = math.max(S.wit_until or 0, now + 3)
  end
  if not S.wit_until or now > S.wit_until then
    if S.wit_until and S.wit then
      -- session over: ≥ 5 s of playing without any change on some witness → stable evidence
      local ok = false
      for _, W in pairs(S.wit) do if (W.play or 0) >= 5 and not W.moved then ok = true end end
      if ok then
        local line = CL.stable_evidence(cs, S.ident, today(io), "Ch " .. g.ch)
        if line then blog(io, line) end
        save_classes(st, io)
      end
    end
    S.wit_until, S.wit = nil, nil
    return
  end
  S.wit = S.wit or {}
  for _, m in ipairs(mem) do
    if not invisible(S, m, ctx) then S.wit[m] = nil      -- visible = maybe edited: its witness baseline starts over
    else
      local W = S.wit[m]
      if not W then W = {}; S.wit[m] = W end
      if now >= (W.next or 0) then
        local r = io.blob(m, S.k)
        st.stats.blob_reads = st.stats.blob_reads + 1
        W.next = now + 1.0
        local B = S.blob[m] or {}
        if r and r ~= "" and W.last then
          if ctx.playing and W.t then W.play = (W.play or 0) + (now - W.t) end
          if r ~= W.last then
            local explained = (B.explained and B.explained >= (W.t or 0) - 0.5) or (B.quiet_until and now < B.quiet_until + 0.5)
              or ((ps.t_reload or -1e9) >= (W.t or 0) - 0.5)
            if not explained and B.wrote and #r == #B.wrote then
              -- a change toward the blob we wrote (late settle) is explained
              local toward = true
              for i = 1, #r do
                local c = r:sub(i, i)
                if c ~= W.last:sub(i, i) and c ~= B.wrote:sub(i, i) then toward = false; break end
              end
              explained = toward
            end
            if not explained then
              W.moved = true
              local line = CL.noisy(cs, S.ident, today(io), ("Ch %d, %s, len %d"):format(g.ch, tracks_of(ctx, { m }), #r))
              if line then blog(io, line); save_classes(st, io) end
            end
          end
        end
        if r and r ~= "" then W.last = r; W.t = now end
      end
    end
  end
end

-- ------------------------------------------------------------------ one slot per tick
function M.step(st, io, ps, g, S, mem, ctx)
  if S.class ~= "vst" or S.demoted then return end
  local cfg, now = ctx.cfg, ctx.now
  local mouse = ctx.mouse
  local cls = class_of(st, io, S.ident)
  local clock = io.clock or io.now
  -- deferred commit due (30 s)
  if S.deferred and now >= (S.defer_until or 0) then
    local d = S.deferred
    S.deferred, S.defer_until, S.pp = nil, nil, {}
    blog(io, ("deferral over | %s | Ch %d | the latest commit is applied"):format(S.ident, g.ch))
    if ctx.res[d.src] then spread(st, io, ps, g, S, mem, d.src, d.blob, d.js, ctx) end
  end
  for _, m in ipairs(mem) do
    local B = S.blob[m]
    if not B then B = {}; S.blob[m] = B end
    local w = M.watched(S, m, ctx)
    local was = B.watched
    if mouse and mouse.press and w then
      ctx.any_watched = true
      if io.hit and io.hit(m, S.k) then B.pressed = true; ctx.hit_any = true end
    end
    if mouse and mouse.release and B.pressed then B.t_up = now; B.recheck = nil end
    if B.quiet_until and now < B.quiet_until and ((mouse and mouse.press and B.pressed) or (was ~= nil and was ~= w)) then B.quiet_keep = true end
    B.watched = w
    if not w and not was and B.quiet_until and now >= B.quiet_until + 1 then
      B.quiet_until, B.quiet_keep, B.wrote = nil, nil, nil       -- written while unwatched: agreed re-taken at its next read
      B.agreed = nil
    end
    local ended = was and not w
    local read_now = false
    if (w and now >= (B.next or 0)) or ended then
      local t0 = clock()
      local r = io.blob(m, S.k)
      local dt = clock() - t0
      st.stats.blob_reads = st.stats.blob_reads + 1
      read_now = true
      -- per-slot phase so several open windows never read in the same tick
      B.next = now + (B.slow and 1.0 or cfg.blob_rate)
      if dt > 0.010 or (r and #r > 262144) then
        S.demoted = true
        blog(io, ("params_only | %s | blob read %.1f ms, %d chars: values and bypass only this session"):format(S.ident, dt * 1000, r and #r or 0))
        return
      elseif dt > 0.002 and not B.slow then
        B.slow = true
        blog(io, ("slow read | %s | %.1f ms: 1 Hz"):format(S.ident, dt * 1000))
      end
      if r and r ~= "" then
        if B.agreed == nil then
          B.agreed = r
          B.quiet_until, B.quiet_keep, B.wrote = nil, nil, nil   -- a quiet window from long ago must not re-take it later
        elseif B.quiet_until and B.quiet_keep then
          -- a js press or a watch transition inside the quiet window (R1d): agreed = what we wrote, at once, so an edit
          -- made now is pending (at worst one harmless extra spread), never absorbed
          B.agreed = B.wrote or r
          B.quiet_until, B.quiet_keep = nil, nil
        elseif B.quiet_until and now >= B.quiet_until then
          B.agreed = r
          B.quiet_until, B.quiet_keep = nil, nil
        end
        if r ~= B.last then B.t_change = now end
        B.last = r
        B.pending = (B.quiet_until == nil) and (r ~= B.agreed)
      end
    end
    -- commit events
    local trig
    if ended then trig = "watch end"
    elseif read_now and B.pending and B.pressed and B.t_up and not (mouse and mouse.down) and now - B.t_up >= 0.15 then trig = "js"
    elseif read_now and B.pending and w and cls == "stable" and B.t_change and now - B.t_change >= cfg.blob_settle then trig = "settle" end
    if trig and B.pending then
      commit(st, io, ps, g, S, mem, m, ctx, trig)
    elseif read_now and B.pressed and B.t_up and not B.pending and not (mouse and mouse.down) and now - B.t_up >= 0.15 then
      -- the plugin may store its state later: one re-check at +0.5 s (the press stays until watch end)
      if not B.recheck then B.recheck = B.t_up + 0.5; B.next = math.min(B.next, B.recheck)
      elseif now >= B.recheck then B.t_up = nil; B.recheck = nil end
    end
    if ended then B.pressed = false; B.t_up = nil; B.recheck = nil; B.pending = false end
    -- a held inbound write: applied once this member has no pending difference and no button down in its window
    if B.held and not B.pending and not (w and mouse and mouse.down) then
      local h = B.held
      B.held = nil
      if ctx.res[h.src] then
        log(io, ("Ch %d slot %s: held spread from %s applied to %s"):format(g.ch, tostring(S.k), h.src, m))
        write_to(st, io, g, S, h.src, m, h.blob, ctx)
      end
    end
  end
  witness(st, io, g, S, mem, ctx, ps)
end

-- ------------------------------------------------------------------ project change / atexit (R4b)
--- every slot with a pending difference commits now (same code path; writes are silent [M])
function M.commit_all(st, io, ps, g, S, mem, ctx)
  if S.class ~= "vst" or S.demoted then return 0 end
  local n = 0
  for _, m in ipairs(mem) do if S.blob[m] and S.blob[m].watched then n = n + 1 end end
  if n == 0 then return 0 end
  local c = setmetatable({ force_end = true }, { __index = ctx })
  M.step(st, io, ps, g, S, mem, c)
  return n
end

return M
