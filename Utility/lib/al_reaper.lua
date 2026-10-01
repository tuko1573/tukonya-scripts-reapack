--[[
  al_reaper.lua — TUKONYA Auto Link: the `io` object for al_core, backed by the real REAPER API.
  Everything that touches REAPER is here; al_core stays pure.
--]]

local core = require("al_core")
local io_open = io.open   -- the name `io` is used below for the adapter object
local M = {}

M.GMEM = "TUKONYA_AutoLink"
M.SUFFIX = "tukonya auto link.jsfx"     -- fx_ident ends with this (Effects/TUKONYA/TUKONYA Auto Link.jsfx)
M.TITLE = "TUKONYA Auto Link"

local CHUNKNAME = {}
for _, T in ipairs(core.TYPES) do CHUNKNAME[T.key] = T.chunk end

--- @param R the reaper table (a test driver may pass a table whose ShowMessageBox is replaced)
function M.new(R)
  local io = { R = R }
  local tracks = {}      -- guid -> MediaTrack (refreshed by every scan)
  local fxof = {}        -- guid -> marker FX index
  local effective_panmode
  local proj = nil
  local hb = 0
  if R.gmem_attach then R.gmem_attach(M.GMEM) end

  function io.now() return R.time_precise() end
  function io.clock() return R.time_precise() end

  function io.project()
    local p, fn = R.EnumProjects(-1)
    proj = p
    return tostring(p) .. "|" .. tostring(fn or "")
  end

  -- depth-first search through containers; returns the first marker that is not offline
  local function find_marker(tr)
    local function check(idx)
      local ok, ident = R.TrackFX_GetNamedConfigParm(tr, idx, "fx_ident")
      if not ok or not ident then return nil end
      local l = ident:lower()
      if l:sub(-#M.SUFFIX) == M.SUFFIX then
        if not R.TrackFX_GetOffline(tr, idx) then return idx end
        return nil
      end
      if ident == "__builtin_container" then
        local okc, cnt = R.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
        for k = 0, (tonumber(cnt) or 0) - 1 do
          local oki, sub = R.TrackFX_GetNamedConfigParm(tr, idx, "container_item." .. k)
          if oki and tonumber(sub) then
            local r = check(tonumber(sub))
            if r then return r end
          end
        end
      end
      return nil
    end
    for i = 0, R.TrackFX_GetCount(tr) - 1 do   -- normal chain only (input/monitoring FX are not scanned)
      local r = check(i)
      if r then return r end
    end
    return nil
  end
  io.find_marker = find_marker

  -- I_PANMODE -1 means "project default"; GetTrackUIPan reports the mode actually in use (resolved)
  function effective_panmode(tr)
    local ok, _, _, pm = R.GetTrackUIPan(tr)
    if ok and pm ~= nil and pm >= 0 then return math.floor(pm) end
    return math.floor(R.GetMediaTrackInfo_Value(tr, "I_PANMODE"))
  end

  function io.scan()
    local out = {}
    tracks = {}
    fxof = {}
    for i = 0, R.CountTracks(proj) - 1 do
      local tr = R.GetTrack(proj, i)
      local fx = find_marker(tr)
      if fx then
        local guid = R.GetTrackGUID(tr)
        local v = R.TrackFX_GetParam(tr, fx, 0)
        local ch = math.floor((v or 0) + 0.5)
        if ch < 0 or ch > 16 then ch = 0 end
        local _, name = R.GetTrackName(tr)
        tracks[guid] = tr
        fxof[guid] = fx
        local mv = R.TrackFX_GetParam(tr, fx, 1)
        out[#out + 1] = { guid = guid, ch = ch, index = i + 1, name = name,
                          mask = math.floor((mv or 1) + 0.5), mask_env = R.GetFXEnvelope(tr, fx, 1, false) ~= nil,
                          panmode = effective_panmode(tr),
                          selected = R.IsTrackSelected(tr), automode = math.floor(R.GetMediaTrackInfo_Value(tr, "I_AUTOMODE")) }
      end
    end
    return out
  end

  local function env(guid, key)
    local tr = tracks[guid]
    if not tr or not R.ValidatePtr2(proj, tr, "MediaTrack*") then return nil end
    return R.GetTrackEnvelopeByChunkName(tr, CHUNKNAME[key])
  end
  io.env = env

  function io.playing() return (R.GetPlayStateEx(proj) & 5) ~= 0 end
  function io.override() return R.GetGlobalAutomationOverride() end

  function io.undo()
    local cur = R.Undo_GetCurEntry(proj)
    return { cur = cur, desc = R.Undo_GetEntryDesc(proj, cur), time = R.Undo_GetEntryTime(proj, cur),
             pdesc = cur > 0 and R.Undo_GetEntryDesc(proj, cur - 1) or "", ptime = cur > 0 and R.Undo_GetEntryTime(proj, cur - 1) or 0,
             sc = R.GetProjectStateChangeCount(proj) }
  end

  function io.fp(guid, key)
    local e = env(guid, key)
    if not e then return "x" end
    local n = R.CountEnvelopePoints(e)
    local ai = R.CountAutomationItems(e)
    if n == 0 then return "0|" .. ai end
    local _, t0, v0, s0 = R.GetEnvelopePoint(e, 0)
    local _, tm, vm = R.GetEnvelopePoint(e, n // 2)
    local _, t1, v1, s1 = R.GetEnvelopePoint(e, n - 1)
    return string.format("%d|%d|%.10g|%.10g|%d|%.10g|%.10g|%.10g|%.10g|%d", n, ai, t0, v0, s0, tm, vm, t1, v1, s1)
  end

  function io.has_line(guid, key)
    local e = env(guid, key)
    if not e then return false end
    return R.CountEnvelopePoints(e) > 0 or R.CountAutomationItems(e) > 0
  end

  --- write the shared type mask into a marker (no undo point, P12); returns the value read back
  function io.set_mask(guid, mask)
    local tr, fx = tracks[guid], fxof[guid]
    if not tr or not fx or not R.ValidatePtr2(proj, tr, "MediaTrack*") then return nil end
    R.TrackFX_SetParam(tr, fx, 1, mask)
    return math.floor(R.TrackFX_GetParam(tr, fx, 1) + 0.5)
  end

  function io.chunk(guid, key)
    local e = env(guid, key)
    if not e then return "" end
    local ok, c = R.GetEnvelopeStateChunk(e, "", false)
    return ok and c or ""
  end

  function io.write(guid, key, chunk)
    local e = env(guid, key)
    if not e then return false end
    return R.SetEnvelopeStateChunk(e, chunk, false)
  end

  function io.ask(text, kind)
    local r = R.ShowMessageBox(text, M.TITLE, kind == "yesnocancel" and 3 or 0)
    if r == 6 then return "yes" elseif r == 7 then return "no" elseif r == 2 then return "cancel" end
    return "ok"
  end

  function io.backup(guid, key, chunk, why)
    local dir = R.GetResourcePath() .. "/Data/TUKONYA_AutoLink"
    R.RecursiveCreateDirectory(dir, 0)
    local f = io_open(dir .. "/backup_" .. os.date("%Y-%m-%d") .. ".txt", "a")
    if not f then return false end
    local _, fn = R.EnumProjects(-1)
    local name = ""
    local tr = tracks[guid]
    if tr and R.ValidatePtr2(proj, tr, "MediaTrack*") then name = select(2, R.GetTrackName(tr)) end
    f:write(("### %s | project=%s | track=%s %s | %s | %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), tostring(fn), name, guid, key, why or ""))
    f:write(chunk or "")
    f:write("\n")
    f:close()
    return true
  end

  local last_counts, last_active = {}, {}
  function io.publish(counts, active)
    hb = (hb % 1000000) + 1
    if not R.gmem_write then return end
    R.gmem_write(0, hb)
    for ch = 1, 16 do
      local n = counts[ch] or 0
      if last_counts[ch] ~= n then R.gmem_write(ch, n); last_counts[ch] = n end
      local a = (active or {})[ch] or 0
      if last_active[ch] ~= a then R.gmem_write(32 + ch, a); last_active[ch] = a end
    end
  end

  --- heartbeat off: the marker then shows "script not running"
  function io.stopped()
    if R.gmem_write then R.gmem_write(0, 0) end
  end

  function io.log(s) if M.DEBUG then R.ShowConsoleMsg("[Auto Link] " .. s .. "\n") end end

  return io
end

return M
