--[[
  TUKONYA_Folder Toggle.lua
  選択トラックのフォルダを、編集画面（TCP）とミキサーの両方で「閉じる／開く」と切り替える。
  子トラックを選んでいればその親フォルダが対象。複数選択なら、1つでも開いていれば全部閉じ、
  全部閉じていれば全部開く。Cmd+Z 1回で戻る。
  ショートカットやコントロールサーフェスのボタンに割り当てて使う。
--]]

-- ===== 設定 =====
local CLOSE_LEVEL = 2          -- 閉じるときの編集画面の畳み方: 1=小さく, 2=完全に畳む
local MIXER_MODE  = "action"   -- ミキサー側の書き方: "action"（アクション41665）| "chunk"
-- =================

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
package.path = this_dir() .. "/lib/?.lua;" .. package.path
local C = require("fl_core")

reaper.Undo_BeginBlock2(0)
reaper.PreventUIRefresh(1)
local targets, closed = C.toggle_selected(reaper, { close_level = CLOSE_LEVEL, mixer_mode = MIXER_MODE })
reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
local label = (#targets == 0) and "Folder Toggle (no folder)"
  or (closed and "Folder Toggle: close" or "Folder Toggle: open")
reaper.Undo_EndBlock2(0, label, -1)
