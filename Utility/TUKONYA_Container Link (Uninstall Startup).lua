--[[
  TUKONYA_Container Link (Uninstall Startup).lua
  「(Install Startup)」で __startup.lua に足した一塊（旧名 Chain Link の一塊も）を取り除く。印の外側は触らない。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local S = require("cl_startup")

local function read_file(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write_file(p, t) local f = io.open(p, "wb"); if not f then return false end; f:write(t); f:close(); return true end

local deps = { resource_path = reaper.GetResourcePath(), script_dir = SCRIPT_DIR,
               read_file = read_file, write_file = write_file, file_exists = reaper.file_exists }
local ok, err = S.uninstall(deps)
if ok then
  reaper.MB("起動時の自動開始を外しました。\n（今動いている見張りは、アクション「TUKONYA_Container Link」をもう一度実行すると止まります）", "TUKONYA Container Link", 0)
else
  reaper.MB("外せませんでした。\n\n" .. tostring(err), "TUKONYA Container Link", 0)
end
