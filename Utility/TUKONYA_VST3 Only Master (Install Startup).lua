--[[
  TUKONYA_VST3 Only Master (Install Startup).lua
  REAPER起動時に「VST3 Only Master」の見張りが自動で始まるように登録する（アクション一覧から1回実行）。
  `<REAPERリソース>/Scripts/__startup.lua` に印で挟んだ一塊を足すだけ。印の外側は触らない。
  外すときは「(Uninstall Startup)」を実行。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local S = require("vom_startup")

local function read_file(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write_file(p, t) local f = io.open(p, "wb"); if not f then return false end; f:write(t); f:close(); return true end

local deps = { resource_path = reaper.GetResourcePath(), script_dir = SCRIPT_DIR,
               read_file = read_file, write_file = write_file, file_exists = reaper.file_exists }
local ok, info = S.install(deps)
if ok then
  -- 今すぐも始める（REAPERを再起動しなくていいように）
  local p = SCRIPT_DIR .. "/TUKONYA_VST3 Only Master.lua"
  local id = reaper.AddRemoveReaScript(true, 0, p, true)
  local started = false
  if id and id > 0 and reaper.GetToggleCommandStateEx(0, id) ~= 1 then
    reaper.Main_OnCommand(id, 0); started = true
  end
  reaper.MB("REAPER起動時に見張りが自動で始まるように登録しました。\n" ..
            (started and "今から見張りを始めました。\n" or "見張りはすでに動いています。\n") ..
            "\n書き足した場所: " .. S.startup_path(deps) .. "\n外すときは「(Uninstall Startup)」を実行してください。",
            "VST3 Only Master", 0)
else
  reaper.MB("登録できませんでした。\n\n" .. tostring(info), "VST3 Only Master", 0)
end
