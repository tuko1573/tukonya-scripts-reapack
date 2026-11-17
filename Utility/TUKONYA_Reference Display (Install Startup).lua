--[[
  TUKONYA_Reference Display (Install Startup).lua
  REAPER起動時に「REFERENCE」窓の常駐が自動で始まるように登録する（アクション一覧から1回実行）。
  `<REAPERリソース>/Scripts/__startup.lua` に印で挟んだ一塊を足すだけ。印の外側は触らない。
  Registers the Display script to start with REAPER. Undo with "(Uninstall Startup)".
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

local deps = S.make_deps(reaper, SCRIPT_DIR)
local ok, info = S.install(deps)
if ok then
  core.ensure_display(reaper, SCRIPT_DIR)
  reaper.MB(tx.ja("STARTUP_INSTALL_OK"), tx.ja("TITLE_MAIN"), 0)
else
  reaper.MB(tx.ja("STARTUP_INSTALL_FAIL", tostring(info)), tx.ja("TITLE_MAIN"), 0)
end
