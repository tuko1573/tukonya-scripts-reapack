--[[
  TUKONYA_Reference Setup.lua
  初期設定。リファレンス用のトラックを選んでから実行する。最初にリファレンスに使うチャンネルを選ぶメニューが出る。
  ルーターと Eater の追加は REAPER 全体で1回、マスターのチャンネル数・ハードウェア出力・トラックの送りはプロジェクトごと
  （テンプレートにしておくと楽）。
  Setup. Select the reference track first. A menu asks which channels to use. The router and Eater are added once
  (REAPER-wide); master channels, hardware output and track send are per project (save a template).
  ・確認ダイアログで、やることを見せてから実行する（OKを押すまで何も変えない）。
  ・既存のFXは削除も置き換えもしない。変更は1回の取り消し（Undo）でまとまる。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local core = require("ref_core")
core.setup(reaper, {
  -- リファレンスに使うチャンネルを選ぶメニュー（gfx.showmenu。js_ReaScriptAPI 不要）
  choose = function(menu_string) return core.show_menu(reaper, gfx, menu_string) end,
})
