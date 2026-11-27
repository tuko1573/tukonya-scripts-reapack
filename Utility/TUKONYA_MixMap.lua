-- TUKONYA Mix Map (window title "TUKONYA Mix Map"; needs ReaImGui 0.10 and the JSFX TUKONYA_MixMap_Meter.jsfx (TUKONYA/, Tukonya Scripts/Utility/ or Effects root))
-- Entry point only: reads settings, runs the frame loop, tells the meter FX when the window is closed.
local r = reaper

local _, script_path = r.get_action_context()
local dir = (script_path or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = dir .. "/?.lua;" .. package.path          -- parts live in <this folder>/mixmap/
for k in pairs(package.loaded) do if k:match("^mixmap%.") then package.loaded[k] = nil end end

if not r.ImGui_GetBuiltinPath then
  r.ShowMessageBox("ReaImGui が入っていません。ReaPack から ReaImGui を入れてください。", "TUKONYA Mix Map", 0)
  return
end
package.path = r.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ok_imgui, ImGui = pcall(function() return require("imgui")("0.10") end)
if not ok_imgui then
  r.ShowMessageBox("ReaImGui 0.10 以降が必要です。\n" .. tostring(ImGui), "TUKONYA Mix Map", 0)
  return
end

local model = require("mixmap.model")
local IO = require("mixmap.io")
local Draw = require("mixmap.draw")

local io_ = IO.new(r)
local settings = io_.load_settings(model.default_settings())
-- keep stored values in range (ExtState can hold anything)
local function fix(S)
  local d = model.default_settings()
  S.split = math.floor(model.clamp(S.split, 1, 3))
  if S.mode ~= "peak" and S.mode ~= "rms" then S.mode = d.mode end
  if S.cam ~= "custom" and not model.CAMS[S.cam] then S.cam = d.cam end
  S.weight = "ear"            -- the button is gone (2026-11); the setting stays so it can come back
  if S.depthBy ~= "track" and S.depthBy ~= "band" then S.depthBy = d.depthBy end
  -- S.hold and S.mask (the old box hold / sensitivity) are no longer used; old saves still load them, nothing reads them
  S.atk = model.clamp(S.atk, 0, 100); S.rls = model.clamp(S.rls, 20, 2000); S.win = model.clamp(S.win, 10, 1000)
  -- 点感 and the masking glow levels (2026-11-05 P3)
  S.crisp = model.clamp(tonumber(S.crisp) or d.crisp, 0, 1)
  S.glowFloor = model.clamp(tonumber(S.glowFloor) or d.glowFloor, -70, -20)
  S.glowFull = model.clamp(tonumber(S.glowFull) or d.glowFull, -40, 0)
  if S.glowFull < S.glowFloor + 1 then S.glowFull = S.glowFloor + 1 end
  S.labelDb = model.clamp(tonumber(S.labelDb) or d.labelDb, -60, -10)
end
fix(settings)

local state = model.new(settings)
local ctx = ImGui.CreateContext("TukoMixMap")
local win = Draw.new(ImGui, ctx, model)
local hooks = {
  select = function(id, was) io_.select(id, was) end,
  toggle_open = function(id) model.toggle_open(state, id) end,
  pick = function(id) io_.pick(id) end,                     -- a row of the name list
  insert = function() return io_.insert() end,
  remove = function() return io_.remove() end,
}

local last = r.time_precise()
local closed = false
local function shutdown()
  if closed then return end
  closed = true
  io_.close()                    -- gmem[1] = 0: the meters go to sleep within 1.5 s
  io_.save_settings(settings)
end
r.atexit(shutdown)

-- Test switch (off by default): reaper.SetExtState("TukoMixMap", "dump_path", "<file>", false)  -- persist=false!
-- makes the window write its model summary to <file> about once a second. Unset = writes nothing.
-- With the dump on, the dump also carries the frame times (ms, mean / max since the last dump) and a test may set one
-- setting by SetExtState("TukoMixMap", "test_set", "key=value", false) (read and cleared here; "cam" also moves the view).
local dumpAt = 0
local perf = { n = 0, io = 0, model = 0, draw = 0, max = 0 }
local function maybe_dump(now)
  local path = r.GetExtState("TukoMixMap", "dump_path")
  if path == "" then return end
  local ts = r.GetExtState("TukoMixMap", "test_set")
  if ts ~= "" then
    r.DeleteExtState("TukoMixMap", "test_set", false)
    local k, v = ts:match("^([%w_]+)=(.*)$")
    if k and settings[k] ~= nil then
      if type(settings[k]) == "number" then settings[k] = tonumber(v) or settings[k]
      elseif type(settings[k]) == "boolean" then settings[k] = (v == "1" or v == "true")
      else settings[k] = v end
      if k == "cam" and model.CAMS[v] then local c = model.CAMS[v]; settings.yaw, settings.pitch = c.yaw, c.pitch; win.cam = nil end
    end
  end
  -- name list test switches (also only with the dump on): "snap_req" = "<Hz>" opens the name list at that frequency exactly
  -- as a click in the room does; "snap_pick" = "<n>" = a click on row n; "snap_dump" = anything: write what is on the list.
  -- Everything is appended to the file named by "snap_path". Read and cleared here.
  local sp = r.GetExtState("TukoMixMap", "snap_path")
  if sp ~= "" then
    local req, pick, dumpq = r.GetExtState("TukoMixMap", "snap_req"), r.GetExtState("TukoMixMap", "snap_pick"), r.GetExtState("TukoMixMap", "snap_dump")
    if req ~= "" or pick ~= "" or dumpq ~= "" then
      r.DeleteExtState("TukoMixMap", "snap_req", false); r.DeleteExtState("TukoMixMap", "snap_pick", false); r.DeleteExtState("TukoMixMap", "snap_dump", false)
      local f = io.open(sp, "a")
      if req ~= "" and tonumber(req) then win.snap = model.snapshot(state, tonumber(req)); f:write("REQ ", req, "\n") end
      if pick ~= "" and win.snap and win.snap.rows[tonumber(pick) or 0] then hooks.pick(win.snap.rows[tonumber(pick)].id); f:write("PICK ", pick, "\n") end
      f:write(("SNAP %s\n"):format(dumpq ~= "" and dumpq or (req ~= "" and "req" or "pick")))
      if win.snap then
        for i, row in ipairs(win.snap.rows) do f:write(("ROW %d %s | %s | %.3f | %.3f\n"):format(i, row.name, tostring(row.parent), row.db, row.len)) end
      end
      f:write("END\n"); f:close()
    end
  end
  if now - dumpAt < 1 then return end
  dumpAt = now
  state.keepPairs = true            -- the dump also lists every pair's overlap per stage (calibration numbers)
  local f = io.open(path, "w")
  if f then
    local n = math.max(1, perf.n)
    f:write(("time=%.2f split=%d\n"):format(now, settings.split),
      ("perf frames=%d io=%.3f model=%.3f draw=%.3f max_total=%.3f ms\n"):format(perf.n, perf.io / n, perf.model / n, perf.draw / n, perf.max),
      model.format_summary(model.summary(state)), "\n")
    perf = { n = 0, io = 0, model = 0, draw = 0, max = 0 }
    f:close()
  end
end

local function body()
  local now = r.time_precise()
  local dt = now - last; last = now
  io_.write_header(settings, now)                    -- heartbeat + settings, every frame
  io_.tick(now)                                      -- rescan on project change / every 1 s; renumber only if needed
  local t1 = r.time_precise()
  local input = io_.frame(5 * settings.split)
  local t2 = r.time_precise()
  model.update(state, input, dt)
  local t3 = r.time_precise()
  local open = win:frame(state, hooks, dt)
  local t4 = r.time_precise()
  perf.n = perf.n + 1
  perf.io, perf.model, perf.draw = perf.io + (t2 - t1) * 1000, perf.model + (t3 - t2) * 1000, perf.draw + (t4 - t3) * 1000
  if (t4 - t1) * 1000 > perf.max then perf.max = (t4 - t1) * 1000 end
  io_.save_settings(settings)
  maybe_dump(now)
  return open
end

local function loop()
  local ok, open = xpcall(body, debug.traceback)
  if not ok then
    r.ShowConsoleMsg("TUKONYA Mix Map: エラー\n" .. tostring(open) .. "\n")
    shutdown()
    return
  end
  if open then r.defer(loop) else shutdown() end
end
r.defer(loop)
