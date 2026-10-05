--[[
  cl_reaper.lua — TUKONYA Container Link (v1 name: Chain Link): the `io` object for cl_core, backed by the real REAPER API.
  Everything that touches REAPER is here; cl_core / cl_params stay pure.
  Rules from the P0 probes (tests/probes/RESULTS.md, REAPER 7.80):
  - container item addresses shift when the top-level FX count changes → every address is re-resolved each tick
  - TrackFX_SetEnabled makes an undo point → bypass is written through the appended bypass param (numparams-3)
  - the script's own SetParam becomes "last touched" → touched() filters the last own write
--]]

local S = require("cl_struct")
local B = require("cl_backup")
local L = require("cl_link")
local P = require("cl_params")
local M = {}

M.GMEM = "TUKONYA_ChainLink"           -- unchanged in v2 (DESIGN_V2 §1)
M.EXT = "TUKONYA_ChainLink"
-- fx_ident ends with one of these (any Effects/ subfolder, e.g. Effects/Tukonya Scripts/Utility/). v2 name first; the v1
-- file name stays accepted so projects saved with v1 markers keep working (DESIGN_V2 §1 MUST).
M.SUFFIXES = { "tukonya container link.jsfx", "tukonya chain link.jsfx" }
M.TITLE = "TUKONYA Container Link"
M.DEBUG = false

local function is_marker(id)
  if id == nil then return false end
  local l = id:lower()
  for _, sfx in ipairs(M.SUFFIXES) do if l:sub(-#sfx) == sfx then return true end end
  return false
end
M.is_marker = is_marker

--- @param R the reaper table (a test driver may pass a table whose ShowMessageBox is replaced)
function M.new(R)
  local io = { R = R, logs = {}, stats = { status_writes = 0, blob_reads = {}, blob_writes = {}, sets = 0, bypass_sets = 0 } }
  local proj = nil
  local last_proj = nil  -- the project before the last tab switch (R4b commit_pending)
  local mids = {}        -- mid → { tr, tidx (0-based), cont (addr), children = {addr...}, ids = {ident...}, addr = {[k] = addr}, class = {[k]} }
  local addrmap = {}     -- tidx → { [addr] = {mid, k} }
  local markers = {}     -- rec.key → { tr, addr, tidx }
  local own = nil        -- the script's last write: { ti, a, p } (REAPER reports it as last touched [M P0-3])
  local classes = {}     -- ident → class
  local hb = 0
  local dirty = {}       -- tidx → true: a chunk was written to this track in this tick (marker address may have moved)
  if R.gmem_attach then R.gmem_attach(M.GMEM) end
  -- LINK channels (cl_link): remember the request seq left from earlier runs (never executed, MUST 6), and seed the
  -- nonce counter with a random base so a nonce saved in a project by an earlier run does not match a new one
  local lstate = {}
  if R.gmem_read then
    L.gmem_init(lstate, R.gmem_read)
    -- 1000 × (100..9999): ≥ 100000 (never 0/1 = a v1 marker's bypass at index 2) and < 2^24, so the nonce stays exact
    -- even if gmem or a slider were single precision [U]
    if R.gmem_write then R.gmem_write(L.G.CTR, 1000 * math.random(L.NONCE_BASE // 1000, 9999)) end
  end

  function io.now() return R.time_precise() end
  function io.clock() return R.time_precise() end

  function io.project()
    local p, fn = R.EnumProjects(-1)
    if proj ~= p then last_proj = proj end
    proj = p
    return tostring(p) .. "|" .. tostring(fn or "")
  end

  local function cfg(tr, a, key)
    local ok, v = R.TrackFX_GetNamedConfigParm(tr, a, key)
    if ok then return v end
    return nil
  end

  local function class_of(tr, a, id)
    local c = classes[id]
    if c then return c end
    local t = (cfg(tr, a, "fx_type") or ""):upper()
    if id == "__builtin_container" or t == "CONTAINER" then c = "container"
    elseif t:sub(1, 2) == "AU" then c = "au"
    elseif t:sub(1, 2) == "JS" then c = "js"
    elseif t:sub(1, 3) == "VST" then c = "vst"   -- all VST2/VST3 incl. LED (DESIGN_V2 §3; no special case)
    else c = "params_only" end         -- CLAP, LV2, unknown: values + bypass only
    classes[id] = c
    return c
  end

  -- every marker anywhere in the normal FX chains (input FX and the master track are not scanned)
  function io.scan()
    local out = {}
    mids, addrmap, markers = {}, {}, {}
    dirty = {}
    local order = 0
    for i = 0, R.CountTracks(proj) - 1 do
      local tr = R.GetTrack(proj, i)
      local tguid = R.GetTrackGUID(tr)
      addrmap[i] = {}
      local tinfo
      local function info()
        if not tinfo then
          local _, name = R.GetTrackName(tr)
          tinfo = { name = name, selected = R.IsTrackSelected(tr), automode = math.floor(R.GetMediaTrackInfo_Value(tr, "I_AUTOMODE")) }
        end
        return tinfo
      end
      local function walk(addrs, parent, parent_guid, ancestors_marked)
        local ids, has_marker = {}, false
        for j, a in ipairs(addrs) do
          ids[j] = cfg(tr, a, "fx_ident") or ""
          if is_marker(ids[j]) then has_marker = true end
        end
        for j, a in ipairs(addrs) do
          order = order + 1
          local id = ids[j]
          if is_marker(id) then
            local v = R.TrackFX_GetParam(tr, a, 0)
            local ch = math.floor((v or 0) + 0.5)
            if ch < 0 or ch > 16 then ch = 0 end
            local inf = info()
            local key = tguid .. ":" .. tostring(R.TrackFX_GetFXGUID(tr, a) or a)
            out[#out + 1] = { key = key, tguid = tguid, tindex = i + 1, tname = inf.name, selected = inf.selected,
                              automode = inf.automode, ch = ch, offline = R.TrackFX_GetOffline(tr, a), cont = parent_guid,
                              nested = parent ~= nil and ancestors_marked, order = order }
            markers[key] = { tr = tr, addr = a, tidx = i }
            if parent and parent_guid then
              local mid = tguid .. "|" .. parent_guid
              if not mids[mid] then mids[mid] = { tr = tr, tidx = i, cont = parent, cont_guid = parent_guid, children = addrs, ids = ids, tname = inf.name } end
            end
          elseif id == "__builtin_container" then
            local n = tonumber(cfg(tr, a, "container_count")) or 0
            local sub = {}
            for k = 0, n - 1 do
              local s = tonumber(cfg(tr, a, "container_item." .. k))
              if s then sub[#sub + 1] = s end
            end
            walk(sub, a, R.TrackFX_GetFXGUID(tr, a), ancestors_marked or (parent ~= nil and has_marker))
          end
        end
      end
      local top = {}
      for f = 0, R.TrackFX_GetCount(tr) - 1 do top[#top + 1] = f end
      walk(top, nil, nil, false)
    end
    return out
  end

  local function subsig(tr, a)
    local n = tonumber(cfg(tr, a, "container_count")) or 0
    local t = {}
    for k = 0, n - 1 do
      local s = tonumber(cfg(tr, a, "container_item." .. k))
      if s then
        local id = cfg(tr, s, "fx_ident") or ""
        t[#t + 1] = (id == "__builtin_container") and ("[" .. subsig(tr, s) .. "]") or id
      end
    end
    return table.concat(t, "\n")
  end

  local function addrmap_has(m, a)
    for _, x in ipairs(m.children) do if x == a then return true end end
    return false
  end
  --- an inner address shown in the track chain that belongs to no container of this track we know → undecodable
  local function cv_unknown(tr, cv)
    for _, mm in pairs(mids) do if mm.tr == tr and addrmap_has(mm, cv) then return false end end
    return true
  end

  function io.resolve(mid)
    local m = mids[mid]
    if not m then return nil end
    local tr = m.tr
    -- DESIGN_V2 §2.1 chain-shown: GetChainVisible -1 hidden, -2 shown with nothing selected, an index = the FX shown.
    -- = this container → the selected inner slot is unknown: every slot of it [U]; ≥ 0x2000000 → that inner slot if it is
    -- in this container's map, else (another container) none; a top-level FX → none.
    local cv = R.TrackFX_GetChainVisible(tr)
    local cont_open = R.TrackFX_GetOpen(tr, m.cont)
    local res = { order = { "c" }, slots = {} }
    res.slots.c = { ident = "__builtin_container", class = "container", n = R.TrackFX_GetNumParams(tr, m.cont), open = false, offline = false }
    m.addr, m.class = { c = m.cont }, { c = "container" }
    addrmap[m.tidx][m.cont] = { mid = mid, k = "c" }
    -- probe (a) [M]: with the container selected in the track chain, GetOpen(inner) is true for exactly the inner FX shown
    -- there → that slot is already watched (single-slot); all slots + multi only when no inner reports open
    local any_open = false
    if cv == m.cont then
      for j, a in ipairs(m.children) do if not is_marker(m.ids[j]) and R.TrackFX_GetOpen(tr, a) then any_open = true end end
    end
    local sig, k = {}, 0
    for j, a in ipairs(m.children) do
      local id = m.ids[j]
      if not is_marker(id) then
        k = k + 1
        local c = class_of(tr, a, id)
        local open = R.TrackFX_GetOpen(tr, a)
        local chain, multi = false, false
        if cv == m.cont then if not any_open then chain, multi = true, true end
        elseif cv == a then chain = true
        elseif cv >= 0x2000000 and not addrmap_has(m, cv) and cv_unknown(tr, cv) then chain, multi = true, true end
        res.slots[k] = { ident = id, class = c, n = R.TrackFX_GetNumParams(tr, a), open = open, offline = R.TrackFX_GetOffline(tr, a),
                         chain = chain, chain_multi = multi, invisible = (cv == -1) and not cont_open and not open }
        res.order[#res.order + 1] = k
        m.addr[k], m.class[k] = a, c
        addrmap[m.tidx][a] = { mid = mid, k = k }
        sig[#sig + 1] = (id == "__builtin_container") and ("[" .. subsig(tr, a) .. "]") or id
      end
    end
    res.sig = table.concat(sig, "\n")
    return res
  end

  local function at(mid, k)
    local m = mids[mid]
    if not m or not m.addr then return nil end
    return m.tr, m.addr[k], m
  end

  --- static metadata of one slot (cached by core per ident): synced real params + Wet/Delta roles, tolerances
  function io.meta(mid, k)
    local tr, a, m = at(mid, k)
    local res = { list = {}, tol_s = {}, tol_c = {} }
    local n = R.TrackFX_GetNumParams(tr, a)
    if m.class[k] ~= "container" then
      for p = 0, n - 4 do
        local au = cfg(tr, a, "param." .. p .. ".automatable")
        local _, name = R.TrackFX_GetParamName(tr, a, p)
        if au ~= "0" and not (name or ""):match("^MIDI CC") and P.is_program_name(name) then
          io.log(("p%d 「%s」: preset loader, not value-synced (its effect travels with the plugin state)"):format(p, tostring(name)))
        end
        if au ~= "0" and not (name or ""):match("^MIDI CC") and not P.is_program_name(name) then
          res.list[#res.list + 1] = p
          local ok, step, _, _, tog = R.TrackFX_GetParameterStepSizes(tr, a, p)
          if ok and tog then res.tol_s[p] = 0.5; res.tol_c[p] = 0.5
          elseif ok and step and step > 0 then
            local _, mn, mx = R.TrackFX_GetParam(tr, a, p)
            if mx and mn and mx > mn then
              local ns = step / (mx - mn)
              if ns > 0 and ns < 1 then res.tol_s[p] = math.max(1e-6, ns / 2); res.tol_c[p] = math.max(5e-4, ns / 2) end
            end
          end
        end
      end
    end
    res.list[#res.list + 1] = -2       -- Wet
    res.list[#res.list + 1] = -1       -- Delta (on/off)
    res.tol_s[-1] = 0.5; res.tol_c[-1] = 0.5
    return res
  end

  function io.get(mid, k, p)
    local tr, a = at(mid, k)
    if p < 0 then p = R.TrackFX_GetNumParams(tr, a) + p end
    return R.TrackFX_GetParamNormalized(tr, a, p)
  end

  function io.set(mid, k, p, v)
    local tr, a, m = at(mid, k)
    if p < 0 then p = R.TrackFX_GetNumParams(tr, a) + p end
    R.TrackFX_SetParamNormalized(tr, a, p, v)
    own = { ti = m.tidx, a = a, p = p }
    io.stats.sets = io.stats.sets + 1
    return R.TrackFX_GetParamNormalized(tr, a, p)
  end

  function io.enabled(mid, k)
    local tr, a = at(mid, k)
    return R.TrackFX_GetEnabled(tr, a)
  end

  --- bypass through REAPER's appended bypass param (1 = bypassed, silent [M p1cost]); returns GetEnabled
  function io.set_bypass(mid, k, on)
    local tr, a, m = at(mid, k)
    local p = R.TrackFX_GetNumParams(tr, a) - 3
    R.TrackFX_SetParamNormalized(tr, a, p, on and 1 or 0)
    own = { ti = m.tidx, a = a, p = p }
    io.stats.bypass_sets = io.stats.bypass_sets + 1
    return R.TrackFX_GetEnabled(tr, a)
  end

  function io.blob(mid, k)
    local tr, a, m = at(mid, k)
    local c = m.class[k]
    io.stats.blob_reads[c] = (io.stats.blob_reads[c] or 0) + 1
    local ok, s = R.TrackFX_GetNamedConfigParm(tr, a, "vst_chunk")
    if ok then return s end
    return nil
  end

  function io.set_blob(mid, k, s)
    local tr, a, m = at(mid, k)
    local c = m.class[k]
    io.stats.blob_writes[c] = (io.stats.blob_writes[c] or 0) + 1
    local ok = R.TrackFX_SetNamedConfigParm(tr, a, "vst_chunk", s)
    own = { ti = m.tidx, a = a, p = nil }   -- a state load makes REAPER report this FX as last touched (any param)
    return ok
  end

  --- params with modulation (LFO/ACS) or a parameter link active ([M] inactive reads "")
  function io.dyn(mid, k, list, i0, i1)
    local tr, a = at(mid, k)
    local out = {}
    for i = i0, i1 do
      local p = list[i]
      if p >= 0 then
        if cfg(tr, a, "param." .. p .. ".mod.active") == "1" or cfg(tr, a, "param." .. p .. ".plink.active") == "1" then out[p] = true end
      end
    end
    return out
  end

  local function env_active(env)
    local ok, c = R.GetEnvelopeStateChunk(env, "", false)
    return ok and c:find("\nACT 1", 1, true) ~= nil
  end

  --- inner params driven by an active container envelope (mapping list on the container [M p1cost / P0-4])
  function io.env_driven(mid)
    local m = mids[mid]
    if not m then return {} end
    local tr, c = m.tr, m.cont
    local out = {}
    local nc = R.TrackFX_GetNumParams(tr, c)
    for N = 0, nc - 4 do
      local env = R.GetFXEnvelope(tr, c, N, false)
      if env and env_active(env) then
        local fi = tonumber(cfg(tr, c, "param." .. N .. ".container_map.fx_index"))
        local fp = tonumber(cfg(tr, c, "param." .. N .. ".container_map.fx_parm"))
        local a = fi and m.children[fi + 1]
        local e = a and addrmap[m.tidx][a]
        if e and e.mid == mid and fp then
          -- REAPER's appended params (bypass/Wet/Delta) are keyed by role, as in the core (P1_REVIEW MUST 7)
          local n = R.TrackFX_GetNumParams(tr, a)
          if fp >= n - 3 then fp = fp - n end
          out[e.k] = out[e.k] or {}
          out[e.k][fp] = true
        end
      end
    end
    return out
  end

  -- ---------------------------------------------------------------- lanes on the container (P3, cl_env)
  --- every lane on the member's container whose mapping points at one of its slots, keyed "k|p" (p < 0 = role).
  --- Cheap fingerprint per lane: point count, ACTIVE, and the points themselves for lanes up to 64 points.
  function io.lanes(mid)
    local m = mids[mid]
    if not m then return {} end
    local tr, c = m.tr, m.cont
    local out = {}
    m.lanes = {}
    local nc = R.TrackFX_GetNumParams(tr, c)
    for N = 0, nc - 1 do
      local env = R.GetFXEnvelope(tr, c, N, false)
      if env then
        local k, p
        if N >= nc - 3 then k, p = "c", N - nc
        else
          local fi = tonumber(cfg(tr, c, "param." .. N .. ".container_map.fx_index"))
          local fp = tonumber(cfg(tr, c, "param." .. N .. ".container_map.fx_parm"))
          local a = fi and m.children[fi + 1]
          local e = a and addrmap[m.tidx][a]
          if e and e.mid == mid and fp then
            local n = R.TrackFX_GetNumParams(tr, a)
            if fp >= n - 3 then fp = fp - n end
            k, p = e.k, fp
          end
        end
        if k then
          local key = k .. "|" .. p
          local np = R.CountEnvelopePoints(env)
          local _, act = R.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
          local f = { np, act, R.CountAutomationItems(env) }
          if np <= 64 then
            for i = 0, np - 1 do
              local _, t, v, sh, tn = R.GetEnvelopePoint(env, i)
              f[#f + 1] = ("%.9g:%.9g:%d:%.4g"):format(t, v, sh, tn)
            end
          end
          out[key] = { k = k, p = p, fp = table.concat(f, " "), act = act ~= "0" }
          m.lanes[key] = env
        end
      end
    end
    return out
  end

  function io.lane_chunk(mid, key)
    local m = mids[mid]
    local env = m and m.lanes and m.lanes[key]
    if not env then return nil end
    local ok, c = R.GetEnvelopeStateChunk(env, "", false)
    return ok and c or nil
  end

  local function lane_env(mid, k, p, create)
    local m = mids[mid]
    if not m or not m.addr then return nil end
    local key = k .. "|" .. p
    local a = m.addr[k]
    if not a then return nil end
    local rp = p
    if p < 0 then rp = R.TrackFX_GetNumParams(m.tr, a) + p end
    local env = R.GetFXEnvelope(m.tr, a, rp, create)     -- REAPER writes the target's own container mapping [M p3pre]
    if env then m.lanes = m.lanes or {}; m.lanes[key] = env end
    return env
  end

  function io.lane_create(mid, k, p)
    local env = lane_env(mid, k, p, true)
    if not env then return nil end
    io.stats.lane_creates = (io.stats.lane_creates or 0) + 1
    local ok, c = R.GetEnvelopeStateChunk(env, "", false)
    return ok and c or nil
  end

  function io.lane_set(mid, k, p, s)
    local env = lane_env(mid, k, p, false)
    if not env then return nil end
    R.SetEnvelopeStateChunk(env, s, false)
    io.stats.lane_sets = (io.stats.lane_sets or 0) + 1
    local ok, c = R.GetEnvelopeStateChunk(env, "", false)
    return ok and c or nil
  end

  --- 0 points + ACT 0 removes the lane (PARMENV gone, mapping kept), 0 undo / 0 state count [M p3pre]
  function io.lane_remove(mid, k, p)
    local env = lane_env(mid, k, p, false)
    if not env then return false end
    local ok, c = R.GetEnvelopeStateChunk(env, "", false)
    if not ok then return false end
    R.SetEnvelopeStateChunk(env, require("cl_env").removal(c), false)
    io.stats.lane_removes = (io.stats.lane_removes or 0) + 1
    local m = mids[mid]; if m and m.lanes then m.lanes[k .. "|" .. p] = nil end
    return true
  end

  function io.touched()
    local ok, ti, ii, _, fx, p = R.GetTouchedOrFocusedFX(0)
    if not ok or ii ~= -1 or ti < 0 then return nil end
    if own and own.ti == ti and own.a == fx and (own.p == nil or own.p == p) then return nil end
    local e = addrmap[ti] and addrmap[ti][fx]
    if not e then return nil end
    local tr, a = at(e.mid, e.k)
    local n = R.TrackFX_GetNumParams(tr, a)
    if p >= n - 3 then p = p - n end
    return { mid = e.mid, k = e.k, p = p }
  end

  function io.focused()
    local ok, ti, ii, _, fx, flag = R.GetTouchedOrFocusedFX(1)
    if not ok or ii ~= -1 or ti < 0 or (flag & 1) == 1 then return nil end
    local e = addrmap[ti] and addrmap[ti][fx]
    if not e then return nil end
    return { mid = e.mid, k = e.k }
  end

  function io.playing() return (R.GetPlayStateEx(proj) & 5) ~= 0 end
  function io.recording() return (R.GetPlayStateEx(proj) & 4) ~= 0 end

  --- every vst-class item of the container has its state loaded (Waves: vst_chunk empty right after instantiation [M])
  function io.struct_ready(mid)
    local m = mids[mid]
    if not m then return false end
    for j, a in ipairs(m.children) do
      local id = m.ids[j]
      if not is_marker(id) and class_of(m.tr, a, id) == "vst" then
        local ok, s = R.TrackFX_GetNamedConfigParm(m.tr, a, "vst_chunk")
        if ok and s == "" then return false end
      end
    end
    return true
  end

  local backup_dir, pruned_day
  local function backup(dm, block, why)
    if not backup_dir then
      backup_dir = R.GetResourcePath() .. "/Data/TUKONYA_ChainLink"
      R.RecursiveCreateDirectory(backup_dir, 0)
    end
    local day = os.date("%Y-%m-%d")
    if pruned_day ~= day then                            -- cap (cl_backup): once per session and per new day, never per write
      pruned_day = day
      pcall(function()
        io.stats.backup_pruned = (io.stats.backup_pruned or 0) + B.prune(backup_dir, B.name_for(day), {
          list = function(dir)
            local t, i = {}, 0
            if R.EnumerateFiles then R.EnumerateFiles(dir, -1) end   -- -1: re-read the folder (REAPER caches listings)
            while true do
              local n = R.EnumerateFiles(dir, i)
              if not n then break end
              t[#t + 1] = n; i = i + 1
            end
            return t
          end,
          size = function(p)
            local f = _G.io.open(p, "rb"); if not f then return nil end
            local n = f:seek("end"); f:close(); return n
          end,
          remove = function(p) return os.remove(p) ~= nil end,
        })
      end)
    end
    local f = _G.io.open(backup_dir .. "/" .. B.name_for(day), "a")
    if not f then return false end
    local _, pfn = R.EnumProjects(-1)
    f:write(("=== %s | project %s | track %d「%s」| %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), tostring(pfn ~= "" and pfn or "(unsaved)"),
      dm.tidx + 1, tostring(dm.tname or ""), why))
    f:write(table.concat(block, "\n") .. "\n")
    f:close()
    io.stats.backups = (io.stats.backups or 0) + 1
    return true
  end

  --- structure sync: replace only the target's <CONTAINER block, built from the source's block (cl_struct.splice).
  --- 0 undo points / 0 state count [M P0-1]. The target's old block goes to the backup file first.
  --- a member's container block as text (lines + item idents), e.g. to keep in an undo record
  function io.read_block(mid)
    local sm = mids[mid]
    if not sm or not sm.cont_guid then return nil end
    local _, sc = R.GetTrackStateChunk(sm.tr, "", false)
    local SL = S.lines(sc)
    local ss, se = S.find_container(SL, sm.cont_guid)
    if not ss then return nil end
    local blk = {}
    for i = ss, se do blk[#blk + 1] = SL[i] end
    local ids = {}
    for j, id in ipairs(sm.ids) do ids[j] = id end
    return { lines = blk, ids = ids }
  end

  --- write a block (from read_block) into the target's container: cl_struct.splice keeps the target's own marker,
  --- FXIDs and mappings; the target's old block goes to the backup file first. 0 undo / 0 state count [M P0-1].
  function io.write_block(src, dst, why)
    local dm = mids[dst]
    if not src or not dm or not dm.cont_guid then return false, "unresolved" end
    local t0 = R.time_precise()
    local _, dc = R.GetTrackStateChunk(dm.tr, "", false)
    local DL = S.lines(dc)
    local ds, de = S.find_container(DL, dm.cont_guid)
    if not ds then return false, "container block not found" end
    local sb, db = S.parse(src.lines, 1, #src.lines), S.parse(DL, ds, de)
    if #sb.items ~= #src.ids or #db.items ~= #dm.ids then
      return false, ("item count mismatch src %d/%d dst %d/%d"):format(#sb.items, #src.ids, #db.items, #dm.ids)
    end
    local blk, info = S.splice(sb, db, src.ids, dm.ids, is_marker)
    local old = {}
    for i = ds, de do old[#old + 1] = DL[i] end
    if not backup(dm, old, why or "") then return false, "backup failed" end
    local newc = S.replace(DL, ds, de, blk)
    local lanes_note = ""
    if info.renum then                                   -- P3: lanes of dropped / renumbered mappings follow
      local NL, rm, rn = S.fix_parmenv(S.lines(newc), ds + #blk, info.amap)
      newc = table.concat(NL, "\n") .. "\n"
      lanes_note = (", %d lanes removed, %d renumbered"):format(rm, rn)
    end
    local ok = R.SetTrackStateChunk(dm.tr, newc, false)
    local ms = (R.time_precise() - t0) * 1000
    io.stats.struct_writes = (io.stats.struct_writes or 0) + 1
    io.stats.struct_ms = io.stats.struct_ms or {}
    io.stats.struct_ms[#io.stats.struct_ms + 1] = ms
    mids[dst] = nil                                      -- addresses on that track are stale until the next scan
    dirty[dm.tidx] = true
    return ok, ("%.1f ms, %d kept FXIDs, %d new, %d mappings dropped%s"):format(ms, info.matched, info.new, info.dropped_parms, lanes_note)
  end

  --- structure sync: the source's current block into the target (both re-read now)
  function io.copy_struct(src, dst, why)
    if src == dst then return false, "same member" end
    local b = io.read_block(src)
    if not b then return false, "source block not found" end
    return io.write_block(b, dst, why)
  end
  -- ---------------------------------------------------------------- native structure sync (reorder / remove)
  --- the deletes/moves turning dst into src's order, or nil (an add, a nested container, unresolved → chunk path)
  function io.native_plan(src, dst)
    local sm, dm = mids[src], mids[dst]
    if not sm or not dm or src == dst then return nil end
    if dm.cont >= 0x2000000 then return nil end         -- nested container: the item address formula is not trusted [M P5]
    return S.native_plan(sm.ids, dm.ids, is_marker)
  end

  --- REAPER's own TrackFX_Delete / TrackFX_CopyToTrack(is_move) on the target; instances are kept (0.01–0.2 ms per op,
  --- no audio gap [M e3]). Must run inside the caller's undo block. Returns ok, info.
  function io.native_struct(src, dst, why)
    local dm = mids[dst]
    local ops = io.native_plan(src, dst)
    if not ops then return false, "not expressible natively" end
    local tr, ci = dm.tr, dm.cont
    local t0 = R.time_precise()
    local function items()
      local n = tonumber(cfg(tr, ci, "container_count")) or 0
      local t = {}
      for k = 0, n - 1 do t[#t + 1] = tonumber(cfg(tr, ci, "container_item." .. k)) end
      return t
    end
    local function caddr(pos) return 0x2000000 + pos * (R.TrackFX_GetCount(tr) + 1) + (ci + 1) end
    local nd, nm = 0, 0
    for _, o in ipairs(ops) do
      local it = items()
      if o.op == "delete" then R.TrackFX_Delete(tr, it[o.pos]); nd = nd + 1
      else R.TrackFX_CopyToTrack(tr, it[o.from], tr, caddr(S.insert_pos(o.from, o.to)), true); nm = nm + 1 end
    end
    local ms = (R.time_precise() - t0) * 1000
    io.stats.native_ms = io.stats.native_ms or {}
    io.stats.native_ms[#io.stats.native_ms + 1] = ms
    mids[dst] = nil
    dirty[dm.tidx] = true
    return true, ("native: %d moves, %d deletes, %.2f ms (%s)"):format(nm, nd, ms, tostring(why))
  end

  --- undo/redo chaining (one Ctrl+Z / Ctrl+Shift+Z moves the user's entry and our sync entry together)
  function io.do_undo() return R.Undo_DoUndo2(proj) end
  function io.do_redo() return R.Undo_DoRedo2(proj) end
  function io.redo_desc() return R.Undo_CanRedo2(proj) end

  function io.override() return R.GetGlobalAutomationOverride() end

  function io.undo()
    local cur = R.Undo_GetCurEntry(proj)
    return { cur = cur, desc = R.Undo_GetEntryDesc(proj, cur), time = R.Undo_GetEntryTime(proj, cur),
             pdesc = cur > 0 and R.Undo_GetEntryDesc(proj, cur - 1) or "", ptime = cur > 0 and R.Undo_GetEntryTime(proj, cur - 1) or 0,
             sc = R.GetProjectStateChangeCount(proj) }
  end

  --- the container's display name (renamed_name; "" = REAPER's localized label, so never GetFXName [M RESULTS_RENAME Q1]).
  --- nil = not readable this tick (the track's chunk was written in this tick: its addresses are stale until the next scan)
  function io.cname(mid)
    local m = mids[mid]
    if not m or dirty[m.tidx] then return nil end
    return cfg(m.tr, m.cont, "renamed_name")
  end

  --- set it: silent (0 undo, +0 state count, never dirty) but 0.5–5 ms [M Q1/Q2] → core compares with cname first. Readback.
  function io.set_cname(mid, s)
    local m = mids[mid]
    if not m or dirty[m.tidx] then return nil end
    R.TrackFX_SetNamedConfigParm(m.tr, m.cont, "renamed_name", s)
    io.stats.name_sets = (io.stats.name_sets or 0) + 1
    return cfg(m.tr, m.cont, "renamed_name")
  end

  --- status code into the marker's hidden slider (silent [M P12]); only when it differs
  function io.set_status(rec, code)
    local mk = markers[rec.key]
    if not mk or dirty[mk.tidx] then return end
    local v = R.TrackFX_GetParam(mk.tr, mk.addr, 1)
    if math.floor((v or 0) + 0.5) ~= code then
      R.TrackFX_SetParam(mk.tr, mk.addr, 1, code)
      own = { ti = mk.tidx, a = mk.addr, p = 1 }
      io.stats.status_writes = io.stats.status_writes + 1
    end
  end

  local last_counts = {}
  function io.publish(counts)
    hb = (hb % 1000000) + 1
    if not R.gmem_write then return end
    R.gmem_write(0, hb)
    R.gmem_write(L.G.CLOCK, R.time_precise())     -- the LINK button stamps its request with this (main clock)
    for ch = 1, 16 do
      local n = counts[ch] or 0
      if last_counts[ch] ~= n then R.gmem_write(ch, n); last_counts[ch] = n end
    end
  end

  --- heartbeat off: the marker then shows 「スクリプト停止中」
  function io.stopped()
    if R.gmem_write then R.gmem_write(0, 0) end
  end

  -- ---------------------------------------------------------------- LINK (cl_link, DESIGN_V2 §4)
  --- new requests since the last tick: the marker button (gmem) and the action (ExtState link_req, deleted when read)
  function io.link_requests()
    local out = {}
    if R.gmem_read then
      local q = L.gmem_poll(lstate, R.gmem_read)
      if q then out[#out + 1] = q end
    end
    if R.GetExtState then
      local v = R.GetExtState(M.EXT, "link_req")
      if v and v ~= "" then
        R.DeleteExtState(M.EXT, "link_req", false)
        local q = L.decode_req(v)
        if q then out[#out + 1] = q end
      end
    end
    return out
  end

  --- the answer: gmem (code first, then seq: the JSFX waits for ack_seq == its seq) or ExtState link_res
  function io.link_ack(req, code, text)
    if req.via == "gmem" then
      if R.gmem_write then R.gmem_write(L.G.ACK_CODE, code); R.gmem_write(L.G.ACK_SEQ, req.seq) end
    elseif R.SetExtState then
      R.SetExtState(M.EXT, "link_res", L.encode_res(req.id, code, text), false)
    end
  end

  -- a v1 marker (2 sliders) has REAPER's appended bypass at index 2: only a marker with ≥ 3 sliders has slider3
  local function req_slider(mk)
    return R.TrackFX_GetNumParams(mk.tr, mk.addr) >= 6
  end

  --- the hidden slider3 (LINK nonce) of a marker and whether its window is open
  function io.marker_info(key)
    local mk = markers[key]
    if not mk or dirty[mk.tidx] or not req_slider(mk) then return nil end
    return { req = R.TrackFX_GetParam(mk.tr, mk.addr, 2) or 0, open = R.TrackFX_GetOpen(mk.tr, mk.addr) }
  end

  --- reset slider3 to 0 once its request was handled (TrackFX_SetParam on a JSFX slider: silent [M P12])
  function io.clear_req(key)
    local mk = markers[key]
    if not mk or dirty[mk.tidx] or not req_slider(mk) then return end
    if (R.TrackFX_GetParam(mk.tr, mk.addr, 2) or 0) ~= 0 then
      R.TrackFX_SetParam(mk.tr, mk.addr, 2, 0)
      own = { ti = mk.tidx, a = mk.addr, p = 2 }
    end
  end

  --- persistent event log (review MUST 9): Data/TUKONYA_ChainLink/link_log.txt, capped (cl_backup.trim_log)
  local log_path
  function io.event(s)
    io.log(s)
    pcall(function()
      if not log_path then
        local dir = R.GetResourcePath() .. "/Data/TUKONYA_ChainLink"
        R.RecursiveCreateDirectory(dir, 0)
        log_path = dir .. "/" .. B.LOG_NAME
      end
      local _, pfn = R.EnumProjects(-1)
      local f = _G.io.open(log_path, "a")
      if not f then return end
      f:write(("%s | %s | %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), (pfn and pfn ~= "") and pfn or "(unsaved)", s))
      local size = f:seek("end")
      f:close()
      if size and size > B.LOG_MAX then
        local r = _G.io.open(log_path, "rb"); if not r then return end
        local text = r:read("a"); r:close()
        local w = _G.io.open(log_path, "wb"); if not w then return end
        w:write(B.trim_log(text, B.LOG_MAX)); w:close()
      end
    end)
  end

  -- ---------------------------------------------------------------- hidden state v2 (cl_blob, DESIGN_V2 §2.2)
  -- js_ReaScriptAPI and SWS detected separately; each missing piece falls back to "watch end", logged once per session
  local JSM, JSFP, JSGP, JSADDR = R.JS_Mouse_GetState, R.JS_Window_FromPoint, R.JS_Window_GetParent, R.JS_Window_AddressFromHandle
  local CFCH = R.CF_GetTrackFXChain
  local told = {}
  local function once(key, s) if not told[key] then told[key] = true; io.blog(s) end end
  function io.mouse()
    if not JSM then once("jsm", "fallback | js_ReaScriptAPI (JS_Mouse_GetState) missing: hidden-state commits at watch end only"); return nil end
    return { down = (JSM(1) & 1) == 1 }
  end
  local function top(h)
    if not h or not JSGP then return h end
    for _ = 1, 32 do local p = JSGP(h); if not p then break end; h = p end
    return h
  end
  local function addr(h) if not h then return nil end; return JSADDR and JSADDR(h) or tostring(h) end
  --- is the window under the mouse (at button-down) the slot's own window: inner float, container window, track chain
  function io.hit(mid, k)
    if not (JSFP and R.GetMousePosition) then once("jsfp", "fallback | JS_Window_FromPoint missing: watch end only"); return false end
    local tr, a, m = at(mid, k)
    if not tr then return false end
    local x, y = R.GetMousePosition()
    local h = addr(top(JSFP(x, y)))
    if not h then return false end
    local cands = { R.TrackFX_GetFloatingWindow(tr, a) }
    if R.TrackFX_GetOpen(tr, a) then cands[#cands + 1] = R.TrackFX_GetFloatingWindow(tr, m.cont) end
    if R.TrackFX_GetChainVisible(tr) ~= -1 then
      if CFCH then cands[#cands + 1] = CFCH(tr)
      else once("cf", "fallback | SWS CF_GetTrackFXChain missing: presses in the track FX chain commit at watch end") end
    end
    local any = false
    for _, c in ipairs(cands) do
      if c then any = true; if addr(top(c)) == h then return true end end
    end
    if not any then once("nilhwnd", "fallback | a watched slot had no window handle (nil hwnd): watch end only") end
    return false
  end

  -- class store and blob log (Data/TUKONYA_ChainLink/blob_class.txt, blob_log.txt capped like link_log)
  local data_dir
  local function dir()
    if not data_dir then data_dir = R.GetResourcePath() .. "/Data/TUKONYA_ChainLink"; R.RecursiveCreateDirectory(data_dir, 0) end
    return data_dir
  end
  function io.class_load()
    local f = _G.io.open(dir() .. "/blob_class.txt", "rb")
    if not f then return nil end
    local t = f:read("a"); f:close(); return t
  end
  function io.class_save(text)
    local f = _G.io.open(dir() .. "/blob_class.txt", "wb")
    if not f then io.blog("class file not writable: in memory only"); return end
    f:write(text); f:close()
  end
  function io.today() return os.date("%Y-%m-%d") end
  function io.blog(s)
    io.log(s)
    pcall(function()
      local p = dir() .. "/blob_log.txt"
      local _, pfn = R.EnumProjects(-1)
      local f = _G.io.open(p, "a"); if not f then return end
      f:write(("%s | %s | %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), (pfn and pfn ~= "") and pfn or "(unsaved)", s))
      local size = f:seek("end"); f:close()
      if size and size > B.LOG_MAX then
        local r = _G.io.open(p, "rb"); if not r then return end
        local text = r:read("a"); r:close()
        local w = _G.io.open(p, "wb"); if not w then return end
        w:write(B.trim_log(text, B.LOG_MAX)); w:close()
      end
    end)
  end
  --- run fn with `proj` = the project we are leaving (R4b), if it still exists
  function io.with_project(key, fn)
    local cur = proj
    if not last_proj or (R.ValidatePtr and not R.ValidatePtr(last_proj, "ReaProject*")) then return end
    proj = last_proj
    local ok, err = pcall(fn)
    proj = cur
    if not ok then error(err) end
  end

  function io.ask(text, kind)
    local r = R.ShowMessageBox(text, M.TITLE, kind == "yesnocancel" and 3 or 4)
    if r == 6 then return "yes" elseif r == 7 then return "no" elseif r == 2 then return "cancel" end
    return "cancel"
  end

  function io.begin_block() R.Undo_BeginBlock2(proj) end
  function io.end_block(desc) R.Undo_EndBlock2(proj, desc, -1) end

  function io.log(s)
    local l = io.logs
    l[#l + 1] = s
    if #l > 200 then table.remove(l, 1) end
    if M.DEBUG then R.ShowConsoleMsg("[Container Link] " .. s .. "\n") end
  end

  return io
end

return M
