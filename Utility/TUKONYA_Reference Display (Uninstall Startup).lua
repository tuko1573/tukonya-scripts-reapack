--[[
  TUKONYA_Reference Display (Uninstall Startup).lua
  起動時の自動開始をやめる（__startup.lua の印で挟んだ一塊だけを消す）。
  いま動いている Display もここで止める。
  Removes the startup block and stops the running Display.
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local S = require("ref_startup")
local core = require("ref_core")
local tx = require("ref_text")
local display = require("ref_display")

local deps = S.make_deps(reaper, SCRIPT_DIR)
local ok, err = S.uninstall(deps)
if ok then
  local id = reaper.AddRemoveReaScript(true, 0, SCRIPT_DIR .. "/" .. core.DISPLAY_FILE, false)
  local stopped = display.request_stop(reaper, id)
  reaper.MB(tx.ja("STARTUP_UNINSTALL_OK", stopped and tx.ja("STARTUP_STOPPING") or tx.ja("STARTUP_NOT_RUNNING")), tx.ja("TITLE_MAIN"), 0)
else
  reaper.MB(tx.ja("STARTUP_UNINSTALL_FAIL", tostring(err)), tx.ja("TITLE_MAIN"), 0)
end
