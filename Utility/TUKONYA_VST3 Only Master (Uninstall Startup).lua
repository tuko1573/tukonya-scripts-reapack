--[[
  TUKONYA_VST3 Only Master (Uninstall Startup).lua
  起動時の自動開始をやめる（__startup.lua の印で挟んだ一塊だけを消す）。
  いま動いている見張りは、アクション一覧から「TUKONYA_VST3 Only Master」をもう一度走らせると止まる。
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
local ok, err = S.uninstall(deps)
if ok then
  reaper.MB("起動時の自動開始をやめました。\n（いま動いている見張りは、アクション一覧から「TUKONYA_VST3 Only Master」を走らせると止まります）", "VST3 Only Master", 0)
else
  reaper.MB("外せませんでした。\n\n" .. tostring(err), "VST3 Only Master", 0)
end
