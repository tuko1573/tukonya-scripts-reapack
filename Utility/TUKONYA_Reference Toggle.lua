--[[
  TUKONYA_Reference Toggle.lua
  リファレンスとミックスを切り替える。ショートカット・ツールバー・MIDI/OSC・Stream Deck に割り当てて使う。
  マスターのモニターFXにある IX ルーター（入力3+4 → 出力1+2・Replace）の有効／バイパスを反転する。
  Switches between mix and reference by flipping the IX router in the master monitoring FX.
  ルーターが無ければ何も変えず、「Setup」を案内する。Display が動いていなければ始める。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local core = require("ref_core")
local tx = require("ref_text")

local ok, state = core.toggle(reaper)
if not ok then
  reaper.MB(tx.ja("MSG_NO_ROUTER"), tx.ja("TITLE_MAIN"), 0)
  return
end

-- 自分のトグル状態（ツールバーの点灯）を今の状態に合わせる。Display も同じ値を写し続ける。
local _, _, sec, cmd = reaper.get_action_context()
reaper.SetToggleCommandState(sec, cmd, state and 1 or 0)
reaper.RefreshToolbar2(sec, cmd)

core.ensure_display(reaper, SCRIPT_DIR)

-- このプロジェクトがリファレンスを鳴らせる状態でない（マスターのチャンネル数が足りない、またはルーターの組に合う
-- ハードウェア出力が無い）と無音になる。Setup を案内する（リファレンスに替えたときだけ）。
if state then
  local hint = core.hint_text(reaper)
  if hint then reaper.MB(hint, tx.ja("TITLE_MAIN"), 0) end
end

-- 取り消し履歴に「ReaScript: Run」を積まない（押すたびに Cmd+Z が汚れないように）
reaper.defer(function() end)
