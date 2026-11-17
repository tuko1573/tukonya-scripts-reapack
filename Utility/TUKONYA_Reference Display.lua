--[[
  TUKONYA_Reference Display.lua
  リファレンス聴取中（ルーターが有効）の間だけ、大きな「REFERENCE」窓を出す常駐スクリプト。
  Shows a big REFERENCE window while the reference router is enabled (background script).

  ・もう一度走らせても何もしない（動いているのは常に1つ）。
  ・止めるには: 「(Uninstall Startup)」を実行する、または REAPER を終了する。
  ・Toggle アクションの点灯（トグル状態）も、ルーターの状態に合わせて更新する。
  ・窓の位置・大きさは ExtState "ReferenceMonitorPopup" に記憶する。Esc か × で、そのON中だけ引っ込める。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local display = require("ref_display")
display.run(reaper, gfx, SCRIPT_DIR)
