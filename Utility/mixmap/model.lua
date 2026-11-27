--[[
  model.lua - mix-map: pure computation (NO `reaper.` calls). Port of the approved mock v6
  (measure / proj) with the SPEC changes: cells (17 L/R positions per band, already
  detector-smoothed by the JSFX) -> pan/fader mapping -> 33-bin histogram -> lobes.

  INPUT  model.update(state, input, dt)
    input.sel    = id of the first selected track or nil
    input.tracks = list in project order, one entry per track that is measured OR is an ancestor
                   of a measured one:
      { id, name, col=0xRRGGBB, parent=id|nil, measured=bool, audible=bool, hasReturn=bool,
        send=0..1, vol=linear, pan1, pan2, panmode, cells={[band]={[1..17]=power}} | nil }
    state = model.new(settings);  settings = model.default_settings()

  OUTPUT  model.update returns (and keeps in state.scene):
    scene = { units = {unit...} (project order), glow = {cell...}, labels = {label...}, rows = {row...}, selValid=bool,
              pairs = {{a,b,stage,db}...} (only when state.keepPairs is set: the calibration numbers) }
    unit  = { id,name,col,aggregated,isReturn,focus, a,x,y,z,w,lv,lvSlow, b = {[band]={ {e,p,w}... }},
              zb = {[band]=z} | nil (only with settings.depthBy == "band") }
    glow cell = { k=sub-band, c=output pan cell 1..33, x=-1..1, y=band centre height, z=depth, i=0..1 (the grade of the
              smoothed overlap summed over all pairs; never changed by the selection), d=0..1 (i as drawn: the pairs that
              do not involve the selection are dimmed by GLOW_DIM) }
    label = { key, stage, lo, hi (Hz of the stage), db (total overlap in the stage), text="Drums（Kick）× Bass／60-240",
              names, ids, x (pan of the overlap), z, i (strength 0.4..1), d (1, or GLOW_DIM when the selection is elsewhere) }
    row   = { id,name,col,depth,folder,open,selected,lv }

  model.summary(state) -> plain table (what would be drawn), shape:
    { selValid=bool,
      units   = { { id,name,focus,aggregated,isReturn, a,x,y,z,w,lv,
                    bands = { [k] = { {center=,width=,e=}, ... } } }, ... },
      labels  = { "Drums（Kick）× Bass／60-240", ... } (sorted), glow = { {k,c,i,d}... }, pairs = {...} }
  model.format_summary(sum) -> multi-line string of the above (for the integration test dump).
--]]

local M = {}
local exp, log10, sqrt, abs, floor, min, max = math.exp, function(x) return math.log(x, 10) end,
  math.sqrt, math.abs, math.floor, math.min, math.max
local mlog = math.log      -- mlog(x, 10) = log10(x) without the extra call (hot loops)

local function clamp(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
local function smooth(c, tg, dt, up, dn) return c + (tg - c) * (1 - exp(-dt * (tg > c and up or dn))) end
M.clamp, M.smooth = clamp, smooth

-- ---------------------------------------------------------------- bands (mock makeBands)
M.LH = { { 20, 60 }, { 60, 240 }, { 240, 900 }, { 900, 5000 }, { 5000, 20000 } }
M.LH_LABEL = { "20-60", "60-240", "240-900", "900-5k", "5k-20k" }
M.NPOS = 17    -- measured L/R positions per band
M.NBIN = 33    -- output histogram bins

-- ---------------------------------------------------------------- ear weighting (ITU-R BS.1770-5 K-weighting, 48 kHz)
-- Two biquads (Tables 1 and 2 of the recommendation). |H|^2 is normalised to 1 at 997 Hz (as Faust's
-- itu_r_bs_1770_4_kfilter does) so a mid-range sine keeps its level. The cells are power, so |H|^2 is
-- the right factor. The screen never says LUFS: this is only used for how far back a track sits.
M.KW_FS = 48000
M.KW = {
  { b0 = 1.53512485958697, b1 = -2.69169618940638, b2 = 1.19839281085285, a1 = -1.69065929318241, a2 = 0.73248077421585 },
  { b0 = 1.0, b1 = -2.0, b2 = 1.0, a1 = -1.99004745483398, a2 = 0.99007225036621 },
}
local function kw_raw(f)
  local w = 2 * math.pi * f / M.KW_FS
  local c1, s1, c2, s2 = math.cos(w), -math.sin(w), math.cos(2 * w), -math.sin(2 * w)   -- z^-1, z^-2
  local g = 1
  for _, q in ipairs(M.KW) do
    local nr, ni = q.b0 + q.b1 * c1 + q.b2 * c2, q.b1 * s1 + q.b2 * s2
    local dr, di = 1 + q.a1 * c1 + q.a2 * c2, q.a1 * s1 + q.a2 * s2
    g = g * (nr * nr + ni * ni) / (dr * dr + di * di)
  end
  return g
end
local KW_REF = kw_raw(997)
function M.ear_weight(f) return kw_raw(f) / KW_REF end

function M.make_bands(n)
  local bands = {}
  for s, r in ipairs(M.LH) do
    local lo, hi = r[1], r[2]
    for j = 0, n - 1 do
      local a, b = lo * (hi / lo) ^ (j / n), lo * (hi / lo) ^ ((j + 1) / n)
      -- weight of the band = mean of |H|^2 over 16 log-spaced points (the 38 Hz high-pass changes a lot inside 20-60)
      local wsum = 0
      for q = 0, 15 do wsum = wsum + M.ear_weight(a * (b / a) ^ ((q + 0.5) / 16)) end
      bands[#bands + 1] = { lo = a, hi = b, c = sqrt(a * b), stage = s, label = M.LH_LABEL[s], wt = wsum / 16 }
    end
  end
  return bands
end

function M.fy(f) return (math.log(f, 10) - math.log(20, 10)) / (math.log(20000, 10) - math.log(20, 10)) end
function M.inv_fy(y) return 20 * 1000 ^ y end   -- 20 Hz * (20000/20)^y
function M.bh(B) return M.fy(B.hi) - M.fy(B.lo) end
function M.half(w) return 0.025 + w * 0.85 end   -- half line length in pan units (mock)

-- ---------------------------------------------------------------- settings / presets / camera
M.PRESETS = {
  fast  = { mode = "peak", atk = 5, rls = 150 },
  ppm   = { mode = "peak", atk = 5, rls = 740 },
  rms50 = { mode = "rms", win = 50 },
  rms300 = { mode = "rms", win = 300 },
}
M.CAMS = {
  front = { yaw = 0, pitch = 0.05 }, above = { yaw = -0.18, pitch = 0.32 },
  top = { yaw = 0, pitch = 1.45 }, side = { yaw = 1.35, pitch = 0.15 },
}

-- list caret: open/close a folder by hand (independent of the selection)
-- It flips that folder against the mixer state until that folder's mixer state next changes (see update, step 3).
function M.toggle_open(state, id)
  if state.flip[id] then state.flip[id] = nil
  else state.flip[id] = { base = state.exp[id] or false } end
end

function M.default_settings()
  return { split = 2, depthFast = false, clash = true, cam = "above", preset = "fast",
           mode = "peak", atk = 5, rls = 150, win = 50, yaw = -0.18, pitch = 0.32, highlight = true,
           weight = "ear",        -- "ear" (K-weighted level decides the depth) | "flat" (plain level)
           depthBy = "track",     -- "track" (one depth per track) | "band" (each band's lines get their own depth)
           hold = 0.5,              -- no longer used (the boxes are gone, 2026-11-04); the key still loads from old saves
           mask = "clear",          -- no longer used (the sensitivity buttons are gone); the key still loads from old saves
           crisp = M.CRISP_DEFAULT,    -- 点感 0..1 (2026-11-05 P3): 1 = only the cores, lower = more of the fog shows
           glowFloor = -45, glowFull = -20, labelDb = -32 }  -- masking: 光り始め / 最大 / 名前 (dB; defaults = the old constants)
end

local RH, RD = 1.2, 1.6   -- room height and depth (width is 2)
function M.focal(W, H) return min(W * 0.85, H * 1.25) end
function M.proj(cam, W, H, F, x, y, z)
  local px, py, pz = x, (y - 0.5) * RH, (z - 0.5) * RD
  local cy, sy, cp, sp = math.cos(cam.yaw), math.sin(cam.yaw), math.cos(cam.pitch), math.sin(cam.pitch)
  local x1, z1 = px * cy - pz * sy, px * sy + pz * cy
  local y2, z2 = py * cp + z1 * sp, -py * sp + z1 * cp
  local k = 1 / (3.2 + z2)
  return W / 2 + x1 * F * k, H * 0.53 - y2 * F * k, k
end

-- Inverse of the wall tick marks: the tick for f sits at proj(cam, ..., -1, fy(f), 0). Given a screen height
-- (relative to the room's top-left) find the wall height y by bisection on the same proj; nil when the
-- height is outside the wall. Hz at that height: inv_fy(y). With x and z given it inverts at that depth
-- instead (a line drawn at (x, z)): the wall edge alone is several sub-bands off for lines far back.
function M.hz_at_screen(cam, W, H, F, sy, x, z)
  x, z = x or -1, z or 0
  local function g(y) local _, py = M.proj(cam, W, H, F, x, y, z); return py end
  local g0, g1 = g(0), g(1)
  if (sy - g0) * (sy - g1) > 0 then return nil end
  local lo, hi = 0, 1
  local up = g1 > g0                      -- does the screen y grow with y?
  for _ = 1, 40 do
    local mid = (lo + hi) / 2
    if (g(mid) < sy) == up then lo = mid else hi = mid end
  end
  return M.inv_fy((lo + hi) / 2)
end

-- distance from (px, py) to the segment a-b, and where on it (0..1)
function M.seg_dist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = l2 > 0 and clamp(((px - ax) * dx + (py - ay) * dy) / l2, 0, 1) or 0
  local qx, qy = ax + t * dx, ay + t * dy
  return sqrt((px - qx) ^ 2 + (py - qy) ^ 2), t
end

-- ---------------------------------------------------------------- pan / fader mapping (SPEC 4.2)
function M.pan_map(q, pan1, pan2, mode)
  local o
  if mode == 5 then o = pan1 + q * pan2 * (1 - abs(pan1))                 -- stereo pan (pan2 = width)
  elseif mode == 6 then o = pan1 + (q + 1) / 2 * (pan2 - pan1)            -- dual pan
  else o = q * (1 - abs(pan1)) + pan1 end                                 -- classic (0) / balance (3)
  return clamp(o, -1, 1)
end

-- where a measured position q of track t ends up in the mix: t's own pan, then the pan/width of every folder
-- above it, nearest first (ups = list of those folders' track tables; nil = none). 2026-11-05 夜 the user: a folder
-- "main" (no FX) panned or narrowed did not move the lines of its children; only the folder faders were applied.
function M.out_pos(q, t, ups)
  local o = M.pan_map(q, t.pan1 or 0, t.pan2 or 0, t.panmode or 0)
  if ups then
    for _, a in ipairs(ups) do o = M.pan_map(o, a.pan1 or 0, a.pan2 or 0, a.panmode or 0) end
  end
  return o
end

-- where the 17 measured positions of track t land in the 33 output bins this frame: bin[p] (1..33) and the
-- fraction fr[p] that goes to bin[p] + 1 (0 at the right edge). Same for every band, so done once per track and
-- frame (shared by the lines and the masking glow).
local function pan_bins(t, ups, bin, fr)
  local NBIN = M.NBIN
  -- M.out_pos with the pans read once (the same arithmetic as M.pan_map)
  local m0, a0, b0 = t.panmode or 0, t.pan1 or 0, t.pan2 or 0
  local nu = ups and #ups or 0
  for p = 1, M.NPOS do
    local o, q = 0, (p - 9) / 8
    for u = 0, nu do
      local mode, pan1, pan2 = m0, a0, b0
      if u > 0 then local a = ups[u]; mode, pan1, pan2 = a.panmode or 0, a.pan1 or 0, a.pan2 or 0 end
      if mode == 5 then o = pan1 + q * pan2 * (1 - abs(pan1))
      elseif mode == 6 then o = pan1 + (q + 1) / 2 * (pan2 - pan1)
      else o = q * (1 - abs(pan1)) + pan1 end
      if o < -1 then o = -1 elseif o > 1 then o = 1 end
      q = o
    end
    local x = (o + 1) * 16                       -- 0..32
    local i = floor(x)
    if i >= 32 then bin[p], fr[p] = NBIN, 0 else bin[p], fr[p] = i + 1, x - i end
  end
end

-- 17 measured positions of one band -> 33-bin output histogram (into hist), scaled by volume^2 (g)
local function band_hist(hist, cells, g, bin, fr)
  local NBIN = M.NBIN
  for j = 1, NBIN do hist[j] = 0 end
  if not cells then return hist end
  for p = 1, M.NPOS do
    local amt = (cells[p] or 0) * g
    if amt > 0 then
      local i = bin[p]
      if i == NBIN then hist[NBIN] = hist[NBIN] + amt
      else
        local f = fr[p]
        hist[i] = hist[i] + amt * (1 - f)
        hist[i + 1] = hist[i + 1] + amt * f
      end
    end
  end
  return hist
end

-- histogram -> lobes. Bins >= 12% of the band max and >= -60 dB; runs separated by a single
-- empty bin are joined. w maps 2*sqrt(3)*std (width of an equal-variance uniform spread) back
-- through the mock's half(w) = .025 + .85 w  (line length = .05 + 1.7 w) to 0..1.
-- lobes_into writes them into the arrays le, lp, lw, la (reused) and returns their count.
local L_ON = {}
local function lobes_into(hist, le, lp, lw, la, m)       -- m: max of hist when the caller has it
  local NBIN = M.NBIN
  if not m then m = 0; for j = 1, NBIN do if hist[j] > m then m = hist[j] end end end
  if m <= 1e-6 then return 0 end
  local thr = max(m * 0.12, 1e-6)
  local on = L_ON
  for j = 1, NBIN do
    on[j] = hist[j] >= thr or (j > 1 and j < NBIN and hist[j - 1] >= thr and hist[j + 1] >= thr)
  end
  local n, j = 0, 1
  while j <= NBIN do
    if on[j] then
      local a = j
      while j + 1 <= NBIN and on[j + 1] do j = j + 1 end
      local amt, sp = 0, 0
      for q = a, j do amt = amt + hist[q]; sp = sp + hist[q] * (-1 + (q - 1) / 16) end
      local c = sp / amt
      local var = 0
      for q = a, j do local d = -1 + (q - 1) / 16 - c; var = var + hist[q] * (d * d) end
      local std = sqrt(var / amt)
      local db = 10 * mlog(amt, 10)
      n = n + 1
      le[n], lp[n], lw[n], la[n] = clamp((db + 54) / 54, 0, 1), clamp(c, -1, 1), clamp((2 * sqrt(3) * std - 0.05) / 1.7, 0, 1), amt
    end
    j = j + 1
  end
  return n
end
function M.lobes_from_hist(hist)
  local le, lp, lw, la = {}, {}, {}, {}
  local out = {}
  for k = 1, lobes_into(hist, le, lp, lw, la) do out[k] = { e = le[k], p = lp[k], w = lw[k], amt = la[k] } end
  return out
end

-- ---------------------------------------------------------------- state
function M.new(settings)
  return { settings = settings or M.default_settings(), tr = {}, agg = {}, bandsN = 0, bands = {}, scene = nil,
           flip = {},          -- folders flipped by hand in the list: id -> { base = mixer state when flipped }
           exp = {},           -- folder id -> expanded in the mixer (input.tracks[].expanded), from the last update
           lastSel = nil,      -- selection at the last update
           selOpen = {},       -- folders the selection opened: id -> mixer state then (dropped when it changes)
           clock = 0,          -- the model's own clock in seconds
           -- masking glow (step 6): all of it independent of the selection
           ov = {},            -- smoothed overlap power: ov[idA][idB][band] = { [cell] = power } (one-pole, GLOW_TAU)
           lab = {},           -- labels that are on: "idA|idB|stage" -> true (hysteresis)
           ovc = {},           -- main contributing child per labelled pair: "idA|idB|stage" -> { a = {leaf -> smoothed}, b = {...} }
           mh = {},            -- leaf id -> band -> { h = 33 bins of masking power after pan and fader, lo, hi, tot }
           mu = {},            -- unit id -> band -> same (sum of the unit's leaves)
           gG = {}, gF = {}, gZ = {} }
end

-- level 0..1 from power: 0 dBFS sine = 1, -40 dB = 0 (LV_RANGE). lv_sum adds levels as powers (folders, rows).
M.LV_RANGE = 40
-- masking glow (update, step 6; SPEC 4.2). The overlap of two units in one sub-band and one output pan cell is
-- min(powerA, powerB) of the masking grid (RMS 50 ms, measured by the JSFX, independent of the window's reaction
-- setting), smoothed per pair x sub-band x cell with a one-pole of GLOW_TAU on power. Grades are dB of that value.
M.GLOW_TAU = 0.7          -- seconds (2026-11-04: the gap Kick x Bass vs click x Pad does not depend on it, experiments/2026-11-04_overlap_amount.md)
M.GLOW_FLOOR_DB = -45     -- a cell at or below this smoothed overlap does not glow
M.GLOW_FULL_DB = -20      -- a cell at or above this glows fully
M.GLOW_MIN = 0.03         -- cells fainter than this (0..1) are not put into the scene
M.GLOW_DIM = 0.2          -- selection only dims: the glow of pairs that do not involve the selection, times this
M.LABEL_DB = -32          -- a pair gets its text when its strongest single spot (one pan cell of one sub-band of the stage,
                          -- this pair alone) reaches this level; an absolute level, no count cap. 2026-11-05: was the total
                          -- over the 33 cells (-29), so wide pairs got names without a visible glow. Names now follow the
                          -- glow: tsuko wants a name where the overlap hits one place, pan included. -32 keeps a centred
                          -- pair labelled at the same level as before (a centred -29 total peaks at about -32 in one cell).
M.LABEL_HYST_DB = 2       -- and keeps it down to this much below
M.LABEL_CAND_DB = 8       -- pairs this close to the label level keep a smoothed "main child" (so it does not jump around)
M.BUS_TAU = 0.7           -- seconds: smoothing of a bus's pre and post band powers before their ratio (P2, 2026-11-05)
M.BUS_MIN_DB = -24        -- the bus ratio of one band is clamped to this ..
M.BUS_MAX_DB = 12         -- .. and this
M.BUS_PRE_FLOOR_DB = -80  -- below this smoothed input power the band's ratio is 1 (no change)
M.MASK_BLUR = 0.25       -- weight each neighbour pan cell gets from a cell (0 = none): two sounds one cell apart still meet
M.MASK_EPS = 1e-9         -- power below this (-90 dB) is zero
M.MASK_EVERY = 3          -- the glow is worked out every this many frames (1 = every frame; see update, step 6)
local function lv_of_power(p) return p > 0 and clamp((10 * log10(p) + M.LV_RANGE) / M.LV_RANGE, 0, 1) or 0 end
local function lv_sum(list)
  local p = 0
  for _, v in ipairs(list) do if v > 0 then p = p + 10 ^ ((v - 1) * M.LV_RANGE / 10) end end
  return lv_of_power(p)
end
M.lv_of_power, M.lv_sum = lv_of_power, lv_sum
-- depth from a level (0..1): louder = nearer. One track and a closed folder (from its summed power) use the same
-- mapping and smoothing.
function M.depth_z(cur, lz, first, dt, fast)
  local z = 0.1 + (1 - lz) * 0.8
  if first or cur == nil then return z end
  if fast then return smooth(cur, z, dt, 20, 6) end
  return smooth(cur, z, dt, 1.5, 1.5)
end
-- depth of several measured tracks heard together (a closed folder, a masking unit): from their summed power, with
-- the same mapping and smoothing as one track (2026-11-05 夕, M30). One track alone keeps its own depth exactly.
-- g: a state table kept per folder/unit between frames; trs: state.tr. Returns z and the per-band depths g.bz.
function M.sum_depth(g, ls, trs, nb, dt, fast)
  if #ls == 1 then
    local s = trs[ls[1]]
    g.z, g.bz, g.dlSlow, g.blSlow = nil, nil, nil, nil
    return s.z, s.bz
  end
  local P, PB = 0, {}
  for i = 1, nb do PB[i] = 0 end
  for _, lid in ipairs(ls) do
    local s = trs[lid]
    P = P + (s.pw or 0)
    for i = 1, nb do PB[i] = PB[i] + ((s.bpw and s.bpw[i]) or 0) end
  end
  local first = g.z == nil
  local dl = M.lv_of_power(P)
  g.dlSlow = first and dl or smooth(g.dlSlow, dl, dt, 3, 1)
  g.z = M.depth_z(g.z, fast and dl or g.dlSlow, first, dt, fast)
  g.blSlow, g.bz = g.blSlow or {}, g.bz or {}
  for i = 1, nb do
    local l = M.lv_of_power(PB[i] * nb)
    g.blSlow[i] = (first or g.blSlow[i] == nil) and l or smooth(g.blSlow[i], l, dt, 3, 1)
    g.bz[i] = M.depth_z(g.bz[i], fast and l or g.blSlow[i], first or g.bz[i] == nil, dt, fast)
  end
  return g.z, g.bz
end

local function new_tr()
  return { b = {}, x = 0, y = 0.5, z = 0.5, lv = 0, lvSlow = 0, w = 0.1, a = 0, init = false,
           dl = 0, dlSlow = 0,               -- level that decides the depth (weighted or flat), instant / smoothed like lvSlow
           blSlow = {}, bz = {}, dn = {}, hs = {} }   -- dn[band] = density (cores, fog) of this frame (P3)            -- the same per band (depthBy = "band"): smoothed level, depth
end

-- density drawing (2026-11-05 P3, 「点と線」をはっきり / 点感). One band's 33-bin output histogram ->
--   cores: runs of bins >= CORE_FRAC of the band max (joined across a shallow dip whose bins all stay >= VALLEY_FRAC,
--          never across a real valley), each grown by at most one
--          "shoulder" bin per side (the linear interpolation of a single position always spreads into 2 bins, so a
--          mono source panned anywhere stays one core and leaves no fog). Drawn like the old line: { p, w, e, amt }.
--   fog:   the other bins whose share of the band max is >= fog_min(crisp) and whose power is >= -60 dB, as runs of
--          bins { p0, p1, al } (al per run: the mean of rel^0.8 of its bins x fog_gain(crisp), quantised to 1/16 so
--          neighbouring bins merge into one segment).
--   crisp = 1 hides every fog bin; the default shows fog only where a sound is clearly spread.
M.CORE_FRAC = 0.5
M.SPLIT_VAR = (0.125 / 2) ^ 2   -- variance a mono source gets from the two-cell split (see density_into)
M.VALLEY_FRAC = 0.3
M.CRISP_DEFAULT = 0.75
M.DENS_UP, M.DENS_DN = 25, 6      -- 1/s: smoothing of the histogram the density is drawn from (about 40 ms up, 170 ms down)
function M.fog_min(crisp) return M.CORE_FRAC * 10 ^ (-(1 - clamp(crisp, 0, 1)) * 2.5) end
function M.fog_gain(crisp) return 0.15 + 0.55 * (1 - clamp(crisp, 0, 1)) end
local function bin_pos(j) return -1 + (j - 1) / 16 end
local D_HIST, D_USED = {}, {}         -- scratch of density (reused every call; nothing returned points into them)
local D_STAMP = 0                     -- D_USED[q] == D_STAMP: bin q belongs to a core in this call
-- density_into fills out = { cores, fog } in place (its entries are reused; extra ones are dropped). measure_track
-- keeps one out per track and band (s.dn[band], which the scene already shares with the track state).
local function density_into(out, hist0, crisp, fmin, gain)
  local NBIN = M.NBIN
  -- the 17 measured positions land on every other one of the 33 bins when the pan does not squeeze them (pan at
  -- centre, full width): fill such a single empty bin with the mean of its neighbours for the shape (the amounts of
  -- the cores are still summed from the real histogram, hist0)
  local hist, m = D_HIST, 0
  for j = 1, NBIN do
    local v = hist0[j]
    if v <= 0 and j > 1 and j < NBIN and hist0[j - 1] > 0 and hist0[j + 1] > 0 then v = (hist0[j - 1] + hist0[j + 1]) / 2 end
    hist[j] = v
    if v > m then m = v end
  end
  local cores, fog = out.cores, out.fog
  local nc, nf = 0, 0
  if m > 1e-6 then
    local cut, keep = m * M.CORE_FRAC, m * M.VALLEY_FRAC
    local used, stamp = D_USED, D_STAMP + 1
    D_STAMP = stamp
    local j = 1
    while j <= NBIN do
      if hist[j] >= cut then
        local a = j
        while j + 1 <= NBIN and hist[j + 1] >= cut do j = j + 1 end
        -- a shallow dip (every bin of it >= VALLEY_FRAC of the max) does not split a core: a wide, uneven sound stays
        -- one core instead of several that come and go; a real valley between two sounds still splits them
        while true do
          local k = j + 1
          while k <= NBIN and hist[k] < cut and hist[k] >= keep do k = k + 1 end
          if k > j + 1 and k <= NBIN and hist[k] >= cut then
            j = k
            while j + 1 <= NBIN and hist[j + 1] >= cut do j = j + 1 end
          else break end
        end
        local b = j
        if a > 1 and used[a - 1] ~= stamp and hist[a - 1] > 0 then a = a - 1 end        -- shoulders
        if b < NBIN and hist[b + 1] > 0 and hist[b + 1] < cut then b = b + 1 end
        local amt, sp = 0, 0
        for q = a, b do used[q] = stamp; local h = hist0[q]; amt = amt + h; sp = sp + h * (-1 + (q - 1) / 16) end
        local c = sp / amt
        local var = 0
        for q = a, b do local d = (-1 + (q - 1) / 16) - c; var = var + hist0[q] * (d * d) end
        -- 2026-11-18 (the user: a mono guitar looks a bit wide): the meter splits a single position between two
        -- neighbouring cells (linear, 0.125 apart), which alone adds up to (0.125/2)^2 of variance and drew a mono source
        -- up to 4x longer depending on where its pan fell. Take that off (Sheppard-style correction for binned data).
        local std = sqrt(max(0, var / amt - M.SPLIT_VAR))
        nc = nc + 1
        local e, p, w = clamp((10 * mlog(amt, 10) + 54) / 54, 0, 1), clamp(c, -1, 1), clamp((2 * sqrt(3) * std - 0.05) / 1.7, 0, 1)
        local o = cores[nc]
        if o then o.e, o.p, o.w, o.amt = e, p, w, amt else cores[nc] = { e = e, p = p, w = w, amt = amt } end
        j = b
      end
      j = j + 1
    end
    if not fmin then fmin, gain = M.fog_min(crisp), M.fog_gain(crisp) end
    if fmin < M.CORE_FRAC then
      local rj0, rj1, ral = 0, 0, nil             -- the current run of fog bins (ral == nil: none)
      for q = 1, NBIN + 1 do
        local al
        if q <= NBIN and used[q] ~= stamp and hist[q] >= 1e-6 then
          local rel = hist[q] / m
          if rel >= fmin then al = floor(16 * gain * rel ^ 0.8 + 0.5) / 16 end
        end
        if al and al > 0 and ral and ral == al and rj1 == q - 1 then rj1 = q
        else
          if ral then
            nf = nf + 1
            local p0, p1 = bin_pos(rj0) - 1 / 32, bin_pos(rj1) + 1 / 32
            local o = fog[nf]
            if o then o.p0, o.p1, o.al = p0, p1, ral else fog[nf] = { p0 = p0, p1 = p1, al = ral } end
          end
          if al and al > 0 then rj0, rj1, ral = q, q, al else ral = nil end
        end
      end
    end
  end
  for q = #cores, nc + 1, -1 do cores[q] = nil end
  for q = #fog, nf + 1, -1 do fog[q] = nil end
  return out
end
function M.density(hist0, crisp) return density_into({ cores = {}, fog = {} }, hist0, crisp) end

-- per measured track: mock measure() with lobes taken from the histogram.
-- fc = per-frame constants (update): yc[band] = M.fy(centre), and the smoothing factors 1 - exp(-dt * rate) as
-- kUp/kDn (DENS_UP/DENS_DN), k12, k3, k1 (the same numbers smooth() would compute for that dt).
local MT_HIST, MT_E, MT_P, MT_W, MT_A = {}, {}, {}, {}, {}   -- scratch (reused)
local function measure_track(state, t, s, dt, vol, ups, fc)
  local bands, S = state.bands, state.settings
  local NBIN, nb = M.NBIN, #bands
  local bin, fr = s.bin, s.fr
  if not bin then bin, fr = {}, {}; s.bin, s.fr = bin, fr end
  pan_bins(t, ups, bin, fr)                       -- kept in s for the masking glow (leaf_hist) of this frame
  local hist, le, lp, lw, la = MT_HIST, MT_E, MT_P, MT_W, MT_A
  local k12, kUp, kDn, yc = fc.k12, fc.kUp, fc.kDn, fc.yc
  local crisp = S.crisp or M.CRISP_DEFAULT
  local fmin, fgain = M.fog_min(crisp), M.fog_gain(crisp)
  local cells, g = t.cells, vol * vol
  local sb, shs, sdn = s.b, s.hs, s.dn
  local E, Y, P, Wd = 0, 0, 0, 0
  for i = 1, nb do
    band_hist(hist, cells and cells[i], g, bin, fr)
    -- the density is drawn from a lightly time-smoothed copy of the histogram (up fast, down slower), so a wide,
    -- fluctuating sound (an uncorrelated pad under the fast Peak detector) does not split into cores that jump about
    local hs, m = shs[i], 0
    if not hs or #hs ~= NBIN then hs = {}; for j = 1, NBIN do local tg = hist[j]; hs[j] = tg; if tg > m then m = tg end end; shs[i] = hs
    else
      for j = 1, NBIN do
        local c, tg = hs[j], hist[j]
        hs[j] = c + (tg - c) * (tg > c and kUp or kDn)
        if tg > m then m = tg end
      end
    end
    local nr = lobes_into(hist, le, lp, lw, la, m)
    sdn[i] = density_into(sdn[i] or { cores = {}, fog = {} }, hs, crisp, fmin, fgain)
    local cur = sb[i]
    if not cur or #cur ~= nr then
      cur = {}
      for k = 1, nr do cur[k] = { e = le[k], p = lp[k], w = lw[k] } end
    else
      for k = 1, nr do
        local c = cur[k]
        c.e = le[k]; c.p = c.p + (lp[k] - c.p) * k12; c.w = c.w + (lw[k] - c.w) * k12
      end
    end
    sb[i] = cur
    local y = yc[i]
    for k = 1, nr do
      local c = cur[k]
      local v = c.e
      E = E + v; Y = Y + v * y; P = P + v * c.p; Wd = Wd + v * c.w
    end
  end
  -- level from the total measured power after the fader (the e of the lines are on a dB scale and would saturate a sum)
  local ptot, pw, g2 = 0, 0, vol ^ 2
  local ear = S.weight ~= "flat"
  local bp = s.bpw or {}                          -- power per band after the fader (ear-weighted in "ear" mode)
  for i = 1, nb do
    local row, sum = cells and cells[i], 0
    if row then for p = 1, #row do sum = sum + (row[p] or 0) end end
    ptot = ptot + sum
    bp[i] = sum * g2 * (ear and bands[i].wt or 1)
    pw = pw + bp[i]
  end
  local lv = lv_of_power(ptot * g2)
  s.lv = lv
  s.lvSlow = smooth(s.lvSlow, lv, dt, 3, 1)
  if E > 0 then
    s.y = s.y + (Y / E - s.y) * k12; s.x = s.x + (P / E - s.x) * k12; s.w = s.w + (Wd / E - s.w) * k12
  end
  -- depth = level only (2026-11-03 the user: a send does not move the dry sound back, it only adds the reverb,
  -- which already shows as the return track's own lines). The level is ear-weighted (or flat); the smoothing
  -- and the z mapping are the same for both, and the same for the per-track and the per-band depth.
  s.dl = lv_of_power(pw)
  s.dlSlow = smooth(s.dlSlow, s.dl, dt, 3, 1)
  s.pw, s.bpw = pw, bp                            -- kept for a closed folder's depth (summed power, M30)
  local fast, first = S.depthFast, not s.init
  local k3, k1, k15, k20, k6, blSlow, bz = fc.k3, fc.k1, fc.k15, fc.k20, fc.k6, s.blSlow, s.bz
  s.z = M.depth_z(s.z, fast and s.dl or s.dlSlow, first, dt, fast)
  local LVR = M.LV_RANGE
  for i = 1, nb do
    -- x #bands (+10*log10(N) dB): a band with its fair share of the power sits at the track's own depth
    local pb = bp[i] * nb                         -- lv_of_power, M.depth_z and smooth written out (same arithmetic)
    local l = pb > 0 and clamp((10 * mlog(pb, 10) + LVR) / LVR, 0, 1) or 0
    local c = blSlow[i] or 0
    c = c + (l - c) * (l > c and k3 or k1)
    blSlow[i] = c
    local cz, zt = bz[i], 0.1 + (1 - (fast and l or c)) * 0.8
    if first or cz == nil then bz[i] = zt
    elseif fast then bz[i] = cz + (zt - cz) * (zt > cz and k20 or k6)
    else bz[i] = cz + (zt - cz) * k15 end
  end
  s.init = true
  s.a = smooth(s.a, s.lvSlow > 0.03 and 1 or 0, dt, 6, 1.2)
end

-- ---------------------------------------------------------------- masking glow
-- One leaf's masking power in one band -> the 33-bin output histogram after pan and fader (volume^2 in g),
-- then blurred by MASK_BLUR into the neighbouring cells (total power unchanged; the edge cells fold back).
-- slot = { h = {33}, lo, hi, tot }; lo > hi means empty.
local function fill_hist(slot, row, g, bin, fr)
  local h = slot.h
  for j = 1, M.NBIN do h[j] = 0 end
  local tot = 0
  if row then
    for p = 1, M.NPOS do
      local v = row[p]
      if v and v > 0 then
        v = v * g
        tot = tot + v
        local i, f = bin[p], fr[p]
        if f == 0 then h[i] = h[i] + v else h[i] = h[i] + v * (1 - f); h[i + 1] = h[i + 1] + v * f end
      end
    end
  end
  slot.tot = tot
  if tot < M.MASK_EPS then slot.lo, slot.hi = 1, 0; return end
  local lo, hi = M.NBIN, 1
  for j = 1, M.NBIN do if h[j] > 0 then if j < lo then lo = j end; hi = j end end
  local s = M.MASK_BLUR
  if s > 0 then
    local l, r = max(lo - 1, 1), min(hi + 1, M.NBIN)
    local prev, cur = (l == 1) and h[1] or h[l - 1], h[l]
    for j = l, r do
      local nxt = (j < M.NBIN) and h[j + 1] or h[M.NBIN]
      h[j] = s * prev + (1 - 2 * s) * cur + s * nxt
      prev, cur = cur, nxt
    end
    lo, hi = l, r
  end
  slot.lo, slot.hi = lo, hi
end

-- env: { tracks, byId, order, live, gains, kids, openM, collect_units(open), leaves(id, acc), under(id, anc),
--        sel, rawdt }
-- The units compared here are decided WITHOUT the selection (the selection only dims): the top-level display units
-- with only the mixer state and the hand flips deciding what is open (not what the selection opened).
-- A track with a `group` is its own unit (a group's members are never compared with each other); a folder that is
-- shown closed is one unit made of its measured leaves. Return tracks (with receives) are left out.
local function masking(state, env)
  local S, bands = state.settings, state.bands
  -- 光り始め / 最大 / 名前 (window sliders, 2026-11-05 P3); the defaults are the old constants
  local GLOW_FLOOR = tonumber(S.glowFloor) or M.GLOW_FLOOR_DB
  local GLOW_FULL = math.max(tonumber(S.glowFull) or M.GLOW_FULL_DB, GLOW_FLOOR + 1)
  local LABEL_DB = tonumber(S.labelDb) or M.LABEL_DB
  local nb = #bands
  local byId, live = env.byId, env.live
  local rawdt = env.rawdt

  -- 1. the units
  local us, gunit = {}, {}
  for _, id in ipairs(env.collect_units(env.openM)) do
    local own = live[id] and { id } or env.leaves(id, {})
    local plain = {}
    for _, lid in ipairs(own) do
      local lt = byId[lid]
      if not lt.hasReturn then
        if lt.group ~= nil then
          -- all measured tracks with the same group (a marked folder) are ONE unit named after that folder; the
          -- main child shows in brackets in the label like any aggregated folder
          local gu = gunit[lt.group]
          if not gu then
            local gt = byId[lt.group]
            gu = { id = "g:" .. tostring(lt.group), name = (gt and gt.name) or lt.name or "", group = lt.group, leaves = {},
                   grouped = true, agg = true }
            gunit[lt.group] = gu; us[#us + 1] = gu
          end
          gu.leaves[#gu.leaves + 1] = lid
        else plain[#plain + 1] = lid end
      end
    end
    if #plain > 0 then
      local t = byId[id]
      us[#us + 1] = { id = id, name = t.name or "", group = "u:" .. id, grouped = false,
                      leaves = plain, agg = not live[id] }
    end
  end
  local n = #us

  -- 2. each leaf's histograms (once per frame), then the units'
  local fh, MH = {}, state.mh
  local function leaf_hist(lid)
    local e = fh[lid]
    if e then return e end
    local t = byId[lid]
    local mc = t.mcells or t.cells
    local ent = MH[lid]
    if not ent then ent = { b = {}, bin = {}, fr = {} }; MH[lid] = ent end
    local g = (env.gains[lid] or 1) ^ 2
    -- the pan -> bin mapping of this frame, worked out by measure_track (every leaf is a live measured track)
    local tr = state.tr[lid]
    local bin, fr = tr and tr.bin, tr and tr.fr
    if not bin then bin, fr = ent.bin, ent.fr; pan_bins(t, env.ups and env.ups[lid], bin, fr) end
    for k = 1, nb do
      local slot = ent.b[k]
      if not slot then slot = { h = {}, lo = 1, hi = 0, tot = 0 }; ent.b[k] = slot end
      fill_hist(slot, mc and mc[k], g, bin, fr)
    end
    fh[lid] = ent
    return ent
  end
  local MU = state.mu
  for _, u in ipairs(us) do
    u.b = {}
    if #u.leaves == 1 then
      u.b = leaf_hist(u.leaves[1]).b
    else
      local ent = MU[u.id]
      if not ent then ent = {}; MU[u.id] = ent end
      for k = 1, nb do
        local slot = ent[k]
        if not slot then slot = { h = {}, lo = 1, hi = 0, tot = 0 }; ent[k] = slot end
        local h = slot.h
        for j = 1, M.NBIN do h[j] = 0 end
        local lo, hi, tot = M.NBIN, 1, 0
        for _, lid in ipairs(u.leaves) do
          local ls = leaf_hist(lid).b[k]
          if ls.hi >= ls.lo then
            local lh = ls.h
            for j = ls.lo, ls.hi do h[j] = h[j] + lh[j] end
            if ls.lo < lo then lo = ls.lo end
            if ls.hi > hi then hi = ls.hi end
            tot = tot + ls.tot
          end
        end
        slot.tot = tot
        if tot < M.MASK_EPS then slot.lo, slot.hi = 1, 0 else slot.lo, slot.hi = lo, hi end
        u.b[k] = slot
      end
    end
    -- depth of the unit per band (the glow takes the smaller one of a pair, as the old boxes did)
    -- 2026-11-05 夕 (M30): from the summed power of the unit's leaves, like a closed folder's lines
    state.mz = state.mz or {}
    local zg = state.mz[u.id] or {}; state.mz[u.id] = zg
    local uz, ubz = M.sum_depth(zg, u.leaves, state.tr, nb, env.zdt or (env.rawdt and math.min(env.rawdt, 0.05)) or 0.033, S.depthFast)
    u.z = {}
    for k = 1, nb do u.z[k] = (S.depthBy == "band" and ubz[k]) or uz end
  end
  -- ids still in use (drop the stale state)
  local inUse, leafUse = {}, {}
  for _, u in ipairs(us) do inUse[u.id] = true; for _, lid in ipairs(u.leaves) do leafUse[lid] = true end end
  for id in pairs(state.mu) do if not inUse[id] then state.mu[id] = nil end end
  for id in pairs(state.mz or {}) do if not inUse[id] then state.mz[id] = nil end end
  for id in pairs(state.mh) do if not leafUse[id] then state.mh[id] = nil end end
  for ida in pairs(state.ov) do
    if not inUse[ida] then state.ov[ida] = nil
    else for idb in pairs(state.ov[ida]) do if not inUse[idb] then state.ov[ida][idb] = nil end end end
  end

  -- 3. focus (only for dimming)
  local sel, selValid = env.sel, false
  for _, u in ipairs(us) do
    local f = false
    if sel and S.highlight then
      f = env.under(u.id, sel) or env.under(sel, u.id)
      if not f then for _, lid in ipairs(u.leaves) do if env.under(lid, sel) then f = true; break end end end
    end
    u.focus = f
    if f then selValid = true end
  end
  for _, u in ipairs(us) do if not selValid then u.focus = true end end

  -- 4. the pairs
  local alpha = 1 - exp(-rawdt / M.GLOW_TAU)
  local decay = 1 - alpha
  local eps = M.MASK_EPS
  local G, F, Z = state.gG, state.gF, state.gZ
  for i = 1, nb * M.NBIN do G[i] = 0; F[i] = 0; Z[i] = 0 end
  local ov = state.ov
  local newLab, newOvc, labels, pairs_dbg = {}, {}, {}, {}
  local nst = #M.LH
  local pm, pxs, pws, pzs = {}, {}, {}, {}
  local stBands = {}                    -- stage -> its bands, in band order
  for st = 1, nst do stBands[st] = {} end
  for k = 1, nb do local l = stBands[bands[k].stage]; if l then l[#l + 1] = k end end
  for i = 1, n do
    local A = us[i]
    for j = i + 1, n do
      local B = us[j]
      local skip = A.group == B.group
      if not skip and not (A.grouped or B.grouped) and (env.under(A.id, B.id) or env.under(B.id, A.id)) then skip = true end
      if skip then
        if ov[A.id] then ov[A.id][B.id] = nil end
      else
        local ps = ov[A.id] and ov[A.id][B.id]
        local any = false
        for st = 1, nst do pm[st], pxs[st], pws[st], pzs[st] = 0, 0, 0, 0 end
        local foc = A.focus or B.focus
        for k = 1, nb do
          local ha, hb = A.b[k], B.b[k]
          local cur = ps and ps[k]
          local lo, hi = 1, 0
          if ha.hi >= ha.lo and hb.hi >= hb.lo then lo, hi = max(ha.lo, hb.lo), min(ha.hi, hb.hi) end
          if cur or hi >= lo then
            -- cur = { lo, hi, [cell] = smoothed power }: one pass over the cells it already holds and the new ones
            if not cur then
              if not ps then
                ov[A.id] = ov[A.id] or {}
                ps = {}; ov[A.id][B.id] = ps
              end
              cur = { lo = lo, hi = hi }
              ps[k] = cur
            end
            local ulo, uhi = cur.lo, cur.hi
            if hi >= lo then
              if lo < ulo then ulo = lo end
              if hi > uhi then uhi = hi end
            end
            local da, db = ha.h, hb.h
            local st = bands[k].stage
            local zp = min(A.z[k], B.z[k])
            local base = (k - 1) * M.NBIN
            local sk, sx, sc = 0, 0, 0
            for c = ulo, uhi do
              local v = (cur[c] or 0) * decay
              if c >= lo and c <= hi then
                local x, y = da[c], db[c]
                if not (x < y) then x = y end
                v = v + x * alpha
              end
              if v < eps then v = 0; cur[c] = 0 else
                cur[c] = v
                local gi = base + c
                G[gi] = G[gi] + v
                if foc then F[gi] = F[gi] + v end
                Z[gi] = Z[gi] + v * zp
                sk = sk + v
                if v > sc then sc = v end
                sx = sx + v * (c - 17)
              end
            end
            while ulo <= uhi and cur[ulo] == 0 do ulo = ulo + 1 end
            while uhi >= ulo and cur[uhi] == 0 do uhi = uhi - 1 end
            if ulo > uhi then ps[k] = nil
            else
              cur.lo, cur.hi = ulo, uhi
              any = true
              pws[st] = pws[st] + sk
              pxs[st] = pxs[st] + sx / 16
              pzs[st] = pzs[st] + sk * zp
              if sc > pm[st] then pm[st] = sc end
            end
          end
        end
        if ps and not any then ov[A.id][B.id] = nil end
        -- labels: one per pair and Listenhub stage, by the pair's strongest single spot in the stage
        for st = 1, nst do
          local m = pm[st]
          if m > 0 then
            local dB = 10 * log10(m)
            if state.keepPairs and dB >= -60 then pairs_dbg[#pairs_dbg + 1] = { a = A.name, b = B.name, stage = st, db = dB } end
            local aggA, aggB = A.agg, B.agg
            if dB >= LABEL_DB - M.LABEL_CAND_DB and (dB >= LABEL_DB - M.LABEL_HYST_DB or aggA or aggB) then
              local key = A.id .. "|" .. B.id .. "|" .. st
              local on = dB >= LABEL_DB or (state.lab[key] and dB >= LABEL_DB - M.LABEL_HYST_DB) or false
              -- main child of a folder: smoothed share of the overlap in this stage, kept for pairs near the label level
              local old = state.ovc[key]
              local rec = { a = {}, b = {} }
              if aggA or aggB then newOvc[key] = rec end
              for side = 1, 2 do
                local U, V, tgt = A, B, rec.a
                local o = old and old.a
                if side == 2 then U, V, tgt, o = B, A, rec.b, old and old.b end
                if U.agg then
                  local Vb, sb, ul = V.b, stBands[st], U.leaves
                  for li = 1, #ul do
                    local lid = ul[li]
                    local lb = leaf_hist(lid).b
                    local sum = 0
                    for bi = 1, #sb do
                      local k = sb[bi]
                      local ls, vs = lb[k], Vb[k]
                      if ls.hi >= ls.lo and vs.hi >= vs.lo then
                        local lh, vh = ls.h, vs.h
                        for c = max(ls.lo, vs.lo), min(ls.hi, vs.hi) do
                          local x, y = lh[c], vh[c]
                          sum = sum + (x < y and x or y)
                        end
                      end
                    end
                    local pv = o and o[lid]
                    tgt[lid] = pv and (pv + alpha * (sum - pv)) or sum
                  end
                end
              end
              if on then
                newLab[key] = true
                local function nm(U, side)
                  if not U.agg then return U.name end
                  local best, bv = nil, -1
                  for _, lid in ipairs(U.leaves) do
                    local v = (side == 1 and rec.a or rec.b)[lid] or 0
                    if v > bv then bv, best = v, lid end
                  end
                  local cn = best and byId[best].name or ""
                  if cn == "" or cn == U.name then return U.name end
                  return U.name .. "（" .. cn .. "）"
                end
                local w = pws[st]
                local nameA, nameB = nm(A, 1), nm(B, 2)
                labels[#labels + 1] = {
                  key = key, stage = st, lo = M.LH[st][1], hi = M.LH[st][2], db = dB,
                  text = nameA .. (nameA:sub(-3) == "）" and "× " or " × ") .. nameB .. "／" .. M.LH_LABEL[st],
                  names = { A.name, B.name }, ids = { A.id, B.id },
                  x = w > 0 and pxs[st] / w or 0, z = w > 0 and pzs[st] / w or 0.5,
                  i = clamp(0.4 + (dB - LABEL_DB) / 10, 0.4, 1), focus = foc,
                }
              end
            end
          end
        end
      end
    end
  end
  state.lab, state.ovc = newLab, newOvc

  -- 5. the glow cells
  local glow = {}
  local span = GLOW_FULL - GLOW_FLOOR
  for k = 1, nb do
    local B = bands[k]
    local base = (k - 1) * M.NBIN
    for c = 1, M.NBIN do
      local v = G[base + c]
      if v > eps then
        local i = clamp((10 * log10(v) - GLOW_FLOOR) / span, 0, 1)
        if i >= M.GLOW_MIN then
          local d = i
          if selValid then
            local fv = F[base + c]
            local fi = fv > eps and clamp((10 * log10(fv) - GLOW_FLOOR) / span, 0, 1) or 0
            d = fi + M.GLOW_DIM * (i - fi)
          end
          glow[#glow + 1] = { k = k, c = c, x = (c - 17) / 16, y = M.fy(B.c), z = Z[base + c] / v, i = i, d = d }
        end
      end
    end
  end
  table.sort(labels, function(a, b)
    if a.stage ~= b.stage then return a.stage < b.stage end
    if a.db ~= b.db then return a.db > b.db end
    return a.key < b.key
  end)
  for _, l in ipairs(labels) do l.d = (selValid and not l.focus) and M.GLOW_DIM or 1 end
  return glow, labels, pairs_dbg, selValid
end

-- ---------------------------------------------------------------- update
-- ---------------------------------------------------------------- 溜まりの名前一覧 (2026-11-23, 試作)
-- Click a height in the room -> the tracks that sounded most in that octave over the last ~3 s. Per metered leaf and per
-- band an exponential average of the band power after the fader (s.bpw, the same numbers the depth uses): tau 1.5 s is
-- about a 3 s window; no ring buffer. state.avg[id] = { [band] = tau-weighted SUM }, state.avgW = the matching weight
-- sum (1 - exp(-t/tau) summed the same way), so the mean = avg / avgW is right from the first frame after a reset.
-- Muted / not audible / silent leaves are fed 0 (never a stale bpw); while the transport is stopped nothing moves.
M.SNAP_TAU = 1.5          -- seconds
M.SNAP_ROWS = 6           -- rows shown at most
M.SNAP_FLOOR_DB = -70     -- a track whose power in the range is below this (dB, 0 dB = a full-scale sine) is left out
M.SNAP_RANGE_DB = 30      -- and so is one more than this far below the strongest row (also the length scale of the bars)
M.SNAP_HOLD = 0.8        -- seconds a new order must hold, while playing, before the name list re-sorts
M.SNAP_SEEK_S = 0.75      -- a play position that jumps by more than this (or goes back) = a seek: the averages restart

-- share (0..1) of a band's power that lies inside lo..hi Hz, power spread evenly over the band's log-frequency width
function M.band_overlap(B, lo, hi)
  local a, b = max(B.lo, lo), min(B.hi, hi)
  if b <= a then return 0 end
  return mlog(b / a) / mlog(B.hi / B.lo)
end

-- cands = { { id =, bp = { [band] = power } }... } -> rows sorted by power in the range, strongest first:
-- { id =, p = power in lo..hi, db =, len = 0..1 (bar length: SNAP_RANGE_DB below the strongest = 0) }.
-- opts: scale (multiplies bp, default 1), rows, floor_db, range_db. Ties are broken by id so the order is stable.
function M.rank_range(cands, bands, lo, hi, opts)
  opts = opts or {}
  local scale, nrows = opts.scale or 1, opts.rows or M.SNAP_ROWS
  local fl, rg = 10 ^ ((opts.floor_db or M.SNAP_FLOOR_DB) / 10), opts.range_db or M.SNAP_RANGE_DB
  local ov, nb = {}, #bands
  for i = 1, nb do ov[i] = M.band_overlap(bands[i], lo, hi) end
  local list = {}
  for _, c in ipairs(cands) do
    local p, bp = 0, c.bp
    for i = 1, nb do if ov[i] > 0 then p = p + (bp[i] or 0) * ov[i] end end
    p = p * scale
    if p >= fl and p > 0 then list[#list + 1] = { id = c.id, p = p } end
  end
  table.sort(list, function(a, b) if a.p ~= b.p then return a.p > b.p end return tostring(a.id) < tostring(b.id) end)
  local rows = {}
  local top = list[1] and 10 * log10(list[1].p)
  for _, e in ipairs(list) do
    if #rows >= nrows then break end
    local db = 10 * log10(e.p)
    if top - db <= rg then
      rows[#rows + 1] = { id = e.id, p = e.p, db = db, len = clamp(1 - (top - db) / rg, 0.04, 1) }
    end
  end
  return rows
end

-- the frozen snapshot for the octave centred on f (Hz): { f, lo, hi, rows = { {id,name,parent,col,p,db,len}... } }.
-- Only leaves that are live now (metered, not muted / under a muted folder / not soloed out, not a bus) can appear.
local function snap_cands(state)
  local cands, live = {}, state.liveNow or {}
  for id, av in pairs(state.avg or {}) do
    if live[id] then cands[#cands + 1] = { id = id, bp = av } end
  end
  local w = state.avgW or 0
  return cands, w > 0 and 1 / w or 0
end

local function snap_names(state, rows)
  local byId = state.byId or {}
  for _, r in ipairs(rows) do
    local t = byId[r.id] or {}
    local par = t.parent and byId[t.parent]
    r.name, r.parent, r.col = t.name or "", par and par.name or nil, t.col or 0x7d8397
  end
  return rows
end

function M.snapshot(state, f)
  local lo, hi = f / sqrt(2), f * sqrt(2)
  local cands, scale = snap_cands(state)
  local rows = snap_names(state, M.rank_range(cands, state.bands, lo, hi, { scale = scale }))
  return { f = f, lo = lo, hi = hi, rows = rows, at = state.clock }
end

-- While the transport runs, the list follows the same octave: the bars move every frame, but the order
-- (which tracks, in what rank) only changes once a new order has held for M.SNAP_HOLD seconds.
-- Stopped: returned unchanged (the averages are frozen anyway).
local function ids_key(rows) local t = {} for i, r in ipairs(rows) do t[i] = tostring(r.id) end return table.concat(t, "\1") end
function M.snap_follow(state, sn, hold)
  if not sn or not state.avgRun then return sn end
  local fresh = M.snapshot(state, sn.f)
  local key, now = ids_key(fresh.rows), state.clock or 0
  if key == ids_key(sn.rows) then return fresh end
  if sn.pend ~= key then sn.pend, sn.pendAt = key, now end
  if now - sn.pendAt >= (hold or M.SNAP_HOLD) then return fresh end
  -- keep the shown order, refresh each bar against the current top
  local cands, scale = snap_cands(state)
  local all = M.rank_range(cands, state.bands, sn.lo, sn.hi, { scale = scale, rows = math.huge, range_db = math.huge, floor_db = -300 })
  local by = {} for _, r in ipairs(all) do by[r.id] = r end
  local top = fresh.rows[1] and fresh.rows[1].db
  for _, r in ipairs(sn.rows) do
    local e = by[r.id]
    r.p, r.db = e and e.p or 0, e and e.db or -300
    r.len = (top and e) and clamp(1 - (top - e.db) / M.SNAP_RANGE_DB, 0.04, 1) or 0.04
  end
  return sn
end

function M.avg_reset(state) state.avg = {}; state.avgW = 0 end

-- advance the per-frame bookkeeping of the averages (called once per update, before the tracks are walked);
-- returns whether the averages move this frame, and the decay factor
local function avg_begin(state, input, rawdt)
  if not state.avg then M.avg_reset(state) end
  local run = input.running ~= false
  local proj = input.proj
  if proj ~= nil and state.avgProj ~= nil and proj ~= state.avgProj then M.avg_reset(state) end
  state.avgProj = proj
  local pos = input.pos
  if run then
    local last = state.avgPos            -- play position at the last frame the transport was running (or nil)
    if pos and last and (pos < last - 0.3 or pos > last + rawdt * 2 + M.SNAP_SEEK_S) then M.avg_reset(state) end
    if pos then state.avgPos = pos end
  end
  if not run then return false, 1 end
  local d = exp(-rawdt / M.SNAP_TAU)
  state.avgW = (state.avgW or 0) * d + (1 - d)
  return true, d
end

function M.update(state, input, dt)
  local rawdt = min(dt or 0.033, 0.5)
  dt = clamp(dt or 0.033, 0.0005, 0.05)
  local S = state.settings
  state.clock = (state.clock or 0) + rawdt
  if state.bandsN ~= S.split then
    state.bandsN = S.split; state.bands = M.make_bands(S.split)
    state.tr = {}; state.agg = {}; state.ov = {}; state.lab = {}; state.ovc = {}; state.mh = {}; state.mu = {}; state.mz = {}
    state.mk = nil
    M.avg_reset(state)
  end
  local bands = state.bands
  local tracks, byId, kids, order = input.tracks or {}, {}, {}, {}
  for n, t in ipairs(tracks) do
    byId[t.id] = t; order[t.id] = n
    if t.parent then kids[t.parent] = kids[t.parent] or {}; table.insert(kids[t.parent], t.id) end
  end
  for id in pairs(state.tr) do if not byId[id] then state.tr[id] = nil end end
  for id in pairs(state.agg) do if not byId[id] then state.agg[id] = nil end end

  -- 0. what a track ends up as in the mix: its own fader times the faders of every folder above it (not the
  -- master), silent when it or a folder above it is muted. A folder's bus processing is not known unless the
  -- folder itself is measured.
  local gains, muteUp = {}, {}
  local function gain_of(id, depth)
    if gains[id] then return gains[id], muteUp[id] end
    local t = byId[id]
    local g, m = t.vol or 1, t.muted or false
    if t.parent and byId[t.parent] and depth < 32 then
      local pg, pm = gain_of(t.parent, depth + 1)
      g = g * pg; m = m or pm
    end
    gains[id], muteUp[id] = g, m
    return g, m
  end
  for _, t in ipairs(tracks) do gain_of(t.id, 0) end
  -- the folders above each track, nearest first: their pan/width is applied after the track's own (M.out_pos)
  local ups = {}
  for _, t in ipairs(tracks) do
    local l, p, depth = {}, t.parent, 0
    while p and byId[p] and depth < 64 do l[#l + 1] = byId[p]; p = byId[p].parent; depth = depth + 1 end
    ups[t.id] = l
  end

  -- 0b. buses (2026-11-05, P1): a folder with a measured track somewhere below it. Its own meters ("post" at the end
  -- of its chain, "pre" at its head) are never turned into lines, glow units or labels, open or closed: a mixed sum
  -- cannot say where each source sits. Its grids are kept in state.bus for the bus ratio (phase P2, not applied yet).
  -- A measured folder with nothing measured below it (meter put in the old way) still draws its own sound.
  local bus, mBelow = {}, {}
  local function mb(id, depth)
    if mBelow[id] ~= nil then return mBelow[id] end
    local r = false
    if depth < 64 then
      for _, k in ipairs(kids[id] or {}) do if byId[k].measured or mb(k, depth + 1) then r = true end end
    end
    mBelow[id] = r
    return r
  end
  state.bus = {}
  for _, t in ipairs(tracks) do
    -- P4: a track that has a "pre" meter is always a bus (an ancestor bus whose leaves were removed must not
    -- fall back to drawing its own folder sum)
    if (kids[t.id] and (mb(t.id, 0) or t.isBus)) or t.preSlot ~= nil or t.preMcells ~= nil then
      bus[t.id] = true
      state.bus[t.id] = { post = t.mcells, pre = t.preMcells, postCells = t.cells, preCells = t.preCells }
    end
  end
  state.isBus = bus

  -- 0c. bus ratio (2026-11-05, P2): per bus that has both meters, per band r = smoothed(post) / smoothed(pre) of
  -- the masking grids (RMS 50 ms, the 17 cells summed), each a 1st-order average over BUS_TAU in real time, r clamped
  -- to BUS_MIN_DB..BUS_MAX_DB, r = 1 while pre is below BUS_PRE_FLOOR_DB. Every measured track below a bus gets
  -- its display and masking cells multiplied per band by the product of the r of all its bus ancestors: what the
  -- bus processing (EQ, comp, ...) does to the level of each band. Positions are not touched. Measured on the MBP
  -- (tests/integration/out/p2_step0c_2026-11-05): bypassed bus with an exact duplicate child 0.00 dB, a -6 dB ReaEQ
  -- bell = the filter's band average within 0.02 dB, ReaFIR (4096 samples of latency) within +-1.2 dB.
  state.br = state.br or {}
  local ratio = {}
  local nbands = #bands
  local function bsum(grid, b) local row, s = grid and grid[b], 0; if row then for p = 1, #row do s = s + (row[p] or 0) end end; return s end
  local aB = 1 - exp(-rawdt / M.BUS_TAU)
  for id in pairs(state.br) do if not state.bus[id] then state.br[id] = nil end end
  for id, B in pairs(state.bus) do
    if B.pre and B.post then
      local e = state.br[id]
      if not e or #e.pre ~= nbands then e = { pre = {}, post = {}, first = true }; state.br[id] = e end
      local r = {}
      for b = 1, nbands do
        local pr, po = bsum(B.pre, b), bsum(B.post, b)
        if e.first then e.pre[b], e.post[b] = pr, po
        else e.pre[b] = e.pre[b] + (pr - e.pre[b]) * aB; e.post[b] = e.post[b] + (po - e.post[b]) * aB end
        if e.pre[b] <= 10 ^ (M.BUS_PRE_FLOOR_DB / 10) then r[b] = 1
        else r[b] = clamp(e.post[b] / e.pre[b], 10 ^ (M.BUS_MIN_DB / 10), 10 ^ (M.BUS_MAX_DB / 10)) end
      end
      e.first = false
      ratio[id] = r
    else state.br[id] = nil end
  end
  state.ratio = ratio
  if next(ratio) then
    -- work on a copy of the list so the caller's track tables are never changed
    local copyT = {}
    for n, t in ipairs(tracks) do
      local f, any = nil, false
      if t.measured and not bus[t.id] then
        local p, depth = t.parent, 0
        while p and byId[p] and depth < 64 do
          local r = ratio[p]
          if r then
            f = f or {}
            for b = 1, nbands do f[b] = (f[b] or 1) * r[b]; if f[b] ~= 1 then any = true end end
          end
          p = byId[p].parent; depth = depth + 1
        end
      end
      if any then
        local function scale(grid)
          if not grid then return nil end
          local out = {}
          for b, row in ipairs(grid) do
            local k, nr = f[b] or 1, {}
            for p = 1, #row do nr[p] = (row[p] or 0) * k end
            out[b] = nr
          end
          return out
        end
        local t2 = {}
        for k, v in pairs(t) do t2[k] = v end
        t2.cells, t2.mcells = scale(t.cells), scale(t.mcells)
        t2.busGain = f
        copyT[n] = t2; byId[t.id] = t2
      else copyT[n] = t end
    end
    tracks = copyT
  end

  -- 1. per-track values (every live measured track, shown or not)
  local fc = { yc = {}, k12 = 1 - exp(-dt * 12), kUp = 1 - exp(-dt * M.DENS_UP), kDn = 1 - exp(-dt * M.DENS_DN),
               k3 = 1 - exp(-dt * 3), k1 = 1 - exp(-dt * 1), k15 = 1 - exp(-dt * 1.5), k20 = 1 - exp(-dt * 20),
               k6 = 1 - exp(-dt * 6) }
  for i = 1, #bands do fc.yc[i] = M.fy(bands[i].c) end
  local live = {}
  local avgRun, avgD = avg_begin(state, input, rawdt)
  state.avgRun = avgRun
  local avg, nb = state.avg, #bands
  for id in pairs(avg) do if not byId[id] then avg[id] = nil end end
  for _, t in ipairs(tracks) do
    local s = state.tr[t.id]
    if not s then s = new_tr(); state.tr[t.id] = s end
    live[t.id] = t.measured and not bus[t.id] and t.audible ~= false and not muteUp[t.id]
    if live[t.id] then measure_track(state, t, s, dt, gains[t.id], ups[t.id], fc)
    else s.a = smooth(s.a, 0, dt, 6, 1.2); s.lv = 0 end
    if avgRun then                       -- the time average for the name list: 0 is recorded when the track is silent
      local av = avg[t.id]
      if live[t.id] then
        local bp = s.bpw
        if not av then av = {}; avg[t.id] = av; for i = 1, nb do av[i] = 0 end end
        local k = 1 - avgD
        for i = 1, nb do local v = av[i] * avgD + (bp[i] or 0) * k; av[i] = v < 1e-13 and 0 or v end   -- flush: no denormals
      elseif av then
        local zero = true
        for i = 1, nb do local v = av[i] * avgD; if v < 1e-13 then v = 0 else zero = false end; av[i] = v end
        if zero then avg[t.id] = nil end
      end
    end
  end
  state.byId, state.liveNow = byId, live   -- for M.snapshot (references only; replaced every frame)

  -- 2. does a track or one of its descendants measure?
  local hasLive = {}
  local function hl(id)
    if hasLive[id] ~= nil then return hasLive[id] end
    local r = live[id] or false
    for _, k in ipairs(kids[id] or {}) do if hl(k) then r = true end end
    hasLive[id] = r
    return r
  end
  for _, t in ipairs(tracks) do hl(t.id) end

  -- 3. selection: open the folder itself and the path to it
  local sel = input.sel
  if sel and not byId[sel] then sel = nil end
  -- Base state of a folder = the mixer's (input expanded = children shown). A hand flip (list caret) inverts it
  -- until that folder's mixer state changes. A new selection opens the folder and the path to it (state.selOpen)
  -- until the selection moves or that folder's mixer state changes, so a mixer open/close after selecting wins.
  local open = {}
  state.exp = {}
  for id in pairs(kids) do state.exp[id] = byId[id].expanded or false end
  for id, f in pairs(state.flip) do if state.exp[id] == nil or state.exp[id] ~= f.base then state.flip[id] = nil end end
  for id in pairs(kids) do open[id] = (state.exp[id] ~= (state.flip[id] ~= nil)) or nil end
  local openM = {}                      -- the same without what the selection opens: the masking glow ignores the selection
  for id, v in pairs(open) do openM[id] = v end
  if sel ~= state.lastSel then
    state.selOpen = {}
    if sel then
      if kids[sel] then state.selOpen[sel] = state.exp[sel] end
      local p = byId[sel].parent
      while p and byId[p] do if kids[p] then state.selOpen[p] = state.exp[p] end; p = byId[p].parent end
    end
  end
  state.lastSel = sel
  for id, base in pairs(state.selOpen) do
    if state.exp[id] ~= base then state.selOpen[id] = nil else open[id] = true end
  end

  -- 4. units (collect_units(open) is also used by the masking glow, with the folders the selection opened left out)
  local function collect_units(openMap)
    local unitIds = {}
    local function collect(id)
      if not hasLive[id] then return end
      if kids[id] and openMap[id] then
        -- an open folder that measures itself keeps its own unit when some direct child has no meter below it
        -- (that child's sound is only in the folder's own lines); with every child measured only the children show
        local own = false
        if live[id] then for _, k in ipairs(kids[id]) do if not hasLive[k] then own = true end end end
        if own then unitIds[#unitIds + 1] = id end
        for _, k in ipairs(kids[id]) do collect(k) end
      else unitIds[#unitIds + 1] = id end
    end
    for _, t in ipairs(tracks) do
      if not t.parent or not byId[t.parent] then collect(t.id) end
    end
    table.sort(unitIds, function(a, b) return order[a] < order[b] end)
    return unitIds
  end
  local unitIds = collect_units(open)

  local function leaves(id, acc)
    if live[id] then acc[#acc + 1] = id
    else for _, k in ipairs(kids[id] or {}) do if hasLive[k] then leaves(k, acc) end end end
    return acc
  end

  local units = {}
  for _, id in ipairs(unitIds) do
    local t = byId[id]
    local u = { id = id, name = t.name or "", col = t.col or 0x7d8397 }
    if live[id] then
      local s = state.tr[id]
      u.b, u.x, u.y, u.z, u.w, u.lv, u.lvSlow, u.a = s.b, s.x, s.y, s.z, s.w, s.lv, s.lvSlow, s.a
      u.dn = s.dn
      if S.depthBy == "band" then u.zb = s.bz end
      u.isReturn = t.hasReturn or false
    else  -- folder that does not measure: its measured descendants, in the folder's colour
      u.aggregated = true
      local g = state.agg[id]
      if not g then g = { x = 0, y = 0.5, lvSlow = 0, a = 0 }; state.agg[id] = g end
      local ls = leaves(id, {})
      u.b, u.dn = {}, {}
      for i = 1, #bands do u.b[i] = {}; u.dn[i] = { cores = {}, fog = {} } end
      local E, X, Y, allRet, kidLv = 0, 0, 0, true, {}
      -- depth (2026-11-05 夕, M30): from the summed power of the leaves (M.sum_depth). The mean of the leaves' depths
      -- pulled a closed folder back whenever a child was quiet or silent (the user「閉めると音がすごいちっちゃい扱いになる」).
      local gz, gbz = 0.5, nil
      if #ls > 0 then gz, gbz = M.sum_depth(g, ls, state.tr, #bands, dt, S.depthFast) end
      local zb = nil
      if S.depthBy == "band" and gbz then zb = {}; for i = 1, #bands do zb[i] = gbz[i] end end
      u.zb = zb
      local byBand = S.depthBy == "band"
      for _, lid in ipairs(ls) do
        local s = state.tr[lid]
        local sa, col, sb, sdn = s.a, byId[lid].col, s.b, s.dn
        for i = 1, #bands do
          -- each child keeps its own colour (2026-11-03 the user) and its own depth (2026-11-05 夕 the user「開閉しても
          -- 開けてる時と同じ配置であればいい」): closing a folder moves nothing in the room
          local lz = (byBand and s.bz[i]) or s.z
          local ub, ls_ = u.b[i], sb[i]
          if ls_ then
            local n = #ub
            for q = 1, #ls_ do local l = ls_[q]; n = n + 1; ub[n] = { e = l.e * sa, p = l.p, w = l.w, col = col, z = lz } end
          end
          local dn = sdn[i]
          if dn then
            local ud = u.dn[i]
            local uc, uf, dc, df = ud.cores, ud.fog, dn.cores, dn.fog
            local n = #uc
            for q = 1, #dc do
              local c = dc[q]; n = n + 1
              uc[n] = { e = c.e * sa, p = c.p, w = c.w, amt = c.amt, col = col, z = lz }
            end
            n = #uf
            for q = 1, #df do
              local f = df[q]; n = n + 1
              uf[n] = { p0 = f.p0, p1 = f.p1, al = f.al * sa, col = col, z = lz }
            end
          end
        end
        E = E + s.lv; X = X + s.x * s.lv; Y = Y + s.y * s.lv; kidLv[#kidLv + 1] = s.lv
        if not byId[lid].hasReturn then allRet = false end
      end
      if E > 0 then g.x = X / E; g.y = Y / E end
      u.x, u.y, u.z, u.w = g.x, g.y, gz, 0.3
      u.lv = lv_sum(kidLv)
      g.lvSlow = smooth(g.lvSlow, u.lv, dt, 3, 1)
      g.a = smooth(g.a, g.lvSlow > 0.03 and 1 or 0, dt, 6, 1.2)
      u.lvSlow, u.a = g.lvSlow, g.a
      u.isReturn = allRet and #ls > 0
    end
    units[#units + 1] = u
  end

  -- 5. focus: the selected unit (and, for a folder, everything inside it)
  local function under(id, anc)  -- id is anc or inside it
    while id do
      if id == anc then return true end
      id = byId[id] and byId[id].parent
    end
    return false
  end
  local selValid = false
  if sel then
    for _, u in ipairs(units) do
      u.focus = under(u.id, sel) or under(sel, u.id)
      if u.focus then selValid = true end
    end
  end
  if not S.highlight then selValid = false end      -- highlight off: selection still opens folders, nothing dims
  for _, u in ipairs(units) do if not selValid then u.focus = true end end

  -- 6. masking glow (graded overlap, not an on/off judgment; SPEC 4.2). Independent of the selection.
  -- Worked out every MASK_EVERY-th frame with the real time since the last time (its smoothing is over GLOW_TAU =
  -- 0.7 s); the frames between show the last result. Done at once when the selection, the units compared or the
  -- glow settings change (the drawn d follows the selection on the same frame).
  local glow, labels, pairsDbg, mSelValid
  local every = M.MASK_EVERY or 1
  local env = { byId = byId, live = live, gains = gains, ups = ups, openM = openM,
    collect_units = collect_units, leaves = leaves, under = under, sel = sel, rawdt = rawdt }
  if every <= 1 then
    state.mk = nil
    glow, labels, pairsDbg, mSelValid = masking(state, env)
  else
    local key = { tostring(sel), tostring(S.highlight), tostring(S.glowFloor), tostring(S.glowFull), tostring(S.labelDb),
                  tostring(S.depthBy), tostring(S.depthFast), tostring(state.keepPairs), tostring(S.split) }
    for _, id in ipairs(collect_units(openM)) do
      key[#key + 1] = "/" .. tostring(id)
      for _, lid in ipairs(live[id] and { id } or leaves(id, {})) do
        local lt = byId[lid]
        key[#key + 1] = tostring(lid) .. (lt.hasReturn and "r" or "") .. ":" .. tostring(lt.group)
      end
    end
    key = table.concat(key, "|")
    local mk = state.mk
    if mk then mk.n, mk.acc, mk.accZ = mk.n + 1, mk.acc + rawdt, mk.accZ + min(rawdt, 0.05) end
    if not mk or mk.key ~= key or mk.n >= every then
      env.rawdt = mk and mk.acc or rawdt
      env.zdt = mk and mk.accZ or nil
      glow, labels, pairsDbg, mSelValid = masking(state, env)
      state.mk = { key = key, n = 0, acc = 0, accZ = 0, glow = glow, labels = labels, pairs = pairsDbg, mSelValid = mSelValid }
    else
      glow, labels, pairsDbg, mSelValid = mk.glow, mk.labels, mk.pairs, mk.mSelValid
    end
  end

  -- 7. list rows (measured tracks and the folders above them; children only while the folder is open)
  local rows = {}
  local function rowlv(id)
    if live[id] then return state.tr[id].lv end
    local l = {}
    for _, k in ipairs(kids[id] or {}) do if hasLive[k] then l[#l + 1] = rowlv(k) end end
    return lv_sum(l)
  end
  local function addrow(id, depth)
    if not hasLive[id] then return end
    local t = byId[id]
    rows[#rows + 1] = { id = id, name = t.name or "", col = t.col or 0x7d8397, depth = depth,
                        folder = kids[id] ~= nil, open = open[id] or false, selected = (sel == id), lv = rowlv(id) }
    if open[id] then for _, k in ipairs(kids[id] or {}) do addrow(k, depth + 1) end end
  end
  for _, t in ipairs(tracks) do if not t.parent or not byId[t.parent] then addrow(t.id, 0) end end

  state.scene = { units = units, glow = glow, labels = labels, pairs = pairsDbg, mSelValid = mSelValid, rows = rows, selValid = selValid, sel = sel }
  return state.scene
end

-- ---------------------------------------------------------------- summary (for tests / dump)
function M.summary(state)
  local sc = state.scene or { units = {}, labels = {}, glow = {} }
  local sum = { selValid = sc.selValid or false, units = {}, labels = {}, glow = {}, pairs = {} }
  for _, u in ipairs(sc.units) do
    local e = { id = u.id, name = u.name, focus = u.focus, aggregated = u.aggregated or false,
                isReturn = u.isReturn or false, a = u.a, x = u.x, y = u.y, z = u.z, w = u.w, lv = u.lv, bands = {} }
    for k, ls in ipairs(u.b) do
      local list = {}
      for _, l in ipairs(ls) do list[#list + 1] = { center = l.p, width = l.w, e = l.e } end
      e.bands[k] = list
    end
    e.dn = {}                                   -- density (P3): per band { cores = {{center, width, e}}, fog = {{p0, p1, al}} }
    for k, d in pairs(u.dn or {}) do
      local cs, fs = {}, {}
      for _, c in ipairs(d.cores) do cs[#cs + 1] = { center = c.p, width = c.w, e = c.e } end
      for _, f in ipairs(d.fog) do fs[#fs + 1] = { p0 = f.p0, p1 = f.p1, al = f.al } end
      e.dn[k] = { cores = cs, fog = fs }
    end
    sum.units[#sum.units + 1] = e
  end
  for _, l in ipairs(sc.labels or {}) do sum.labels[#sum.labels + 1] = l.text end
  table.sort(sum.labels)
  for _, g in ipairs(sc.glow or {}) do sum.glow[#sum.glow + 1] = { k = g.k, c = g.c, i = g.i, d = g.d } end
  for _, p in ipairs(sc.pairs or {}) do sum.pairs[#sum.pairs + 1] = p end
  return sum
end

function M.format_summary(sum)
  local out = { ("selValid=%s"):format(tostring(sum.selValid)) }
  for _, u in ipairs(sum.units) do
    out[#out + 1] = ("unit %s [%s]%s%s focus=%s a=%.2f x=%.2f y=%.2f z=%.2f w=%.2f lv=%.2f"):format(
      u.id, u.name, u.aggregated and " (folder sum)" or "", u.isReturn and " (return)" or "",
      tostring(u.focus), u.a, u.x, u.y, u.z, u.w, u.lv)
    for k, ls in ipairs(u.bands) do
      for _, l in ipairs(ls) do
        out[#out + 1] = ("  band %d: center=%+.2f width=%.2f e=%.2f"):format(k, l.center, l.width, l.e)
      end
    end
    for k = 1, #u.bands do
      local d = u.dn and u.dn[k]
      if d and (#d.cores > 0 or #d.fog > 0) then
        local t = {}
        for _, c in ipairs(d.cores) do t[#t + 1] = ("core %+.2f/%.2f"):format(c.center, c.width) end
        for _, f in ipairs(d.fog) do t[#t + 1] = ("fog %+.2f..%+.2f a=%.2f"):format(f.p0, f.p1, f.al) end
        out[#out + 1] = ("  dens %d: %s"):format(k, table.concat(t, " "))
      end
    end
  end
  for _, l in ipairs(sum.labels) do out[#out + 1] = "label " .. l end
  -- the five strongest glow cells (band, pan cell, intensity before and after the selection dims it)
  local g = {}
  for _, c in ipairs(sum.glow) do g[#g + 1] = c end
  table.sort(g, function(a, b) return a.i > b.i end)
  for n = 1, math.min(5, #g) do out[#out + 1] = ("glow band %d cell %d i=%.2f d=%.2f"):format(g[n].k, g[n].c, g[n].i, g[n].d) end
  out[#out + 1] = ("glow cells=%d"):format(#sum.glow)
  -- calibration: total overlap per pair and stage in dB (state.keepPairs = true)
  local ps = {}
  for _, p in ipairs(sum.pairs) do ps[#ps + 1] = p end
  table.sort(ps, function(a, b) return a.db > b.db end)
  for _, p in ipairs(ps) do out[#out + 1] = ("overlap %s × %s／%s %.1f dB"):format(p.a, p.b, M.LH_LABEL[p.stage], p.db) end
  return table.concat(out, "\n")
end

return M
