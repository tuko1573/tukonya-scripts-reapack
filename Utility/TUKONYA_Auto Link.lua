--[[
  TUKONYA_Auto Link.lua（常駐・トグル）
  目印のエフェクト「TUKONYA Auto Link」を挿して同じ Link Ch を選んだトラック同士で、
  ミュート・ボリューム・パン・幅・トリムの線（オートメーション）を同じにそろえ続ける。
  どのトラックで書き換えても、ほかのトラックへ写る。Ctrl+Z 1回で、両方とも元に戻る。
  もう一度実行すると止まる。REAPER 起動時に自動で始めるには「(Install Startup)」を1回実行。
--]]

-- ===== 設定 =====
local HOLD_ALL_WHILE_PLAYING = true   -- 再生中は写さず、止めたときにまとめて写す（false にすると、書き込み中のトラックがある組だけ止めて待つ）
-- =================

-- 取り消し履歴を読む API は REAPER 7.79 から。無ければ動かさずに知らせる
if not reaper.Undo_GetCurEntry then
  reaper.MB("TUKONYA Auto Link は REAPER 7.79 以降で動きます。\nREAPER を新しくしてからお使いください。", "TUKONYA Auto Link", 0)
  return
end

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
package.path = this_dir() .. "/lib/?.lua;" .. package.path
local core = require("al_core")
local AR = require("al_reaper")

local EXT = "TUKONYA_AutoLink"
local _, _, sectionID, cmdID = reaper.get_action_context()
-- もう一度走らせたら止まる（1）／ツールバーの点灯・消灯を REAPER に任せる（4）。REAPER 7 以降。
if reaper.set_action_options then reaper.set_action_options(1 | 4) end
if cmdID and cmdID > 0 then
  reaper.SetToggleCommandState(sectionID, cmdID, 1)
  reaper.RefreshToolbar2(sectionID, cmdID)
end

-- 二重起動よけ: 最後に始まった1つだけが動く（古い方は次の一巡で静かに終わる）
local token = string.format("%.6f-%d", reaper.time_precise(), math.random(1, 1000000000))
reaper.SetExtState(EXT, "owner", token, false)

local st = core.new({ hold_all_playing = HOLD_ALL_WHILE_PLAYING })
local io = AR.new(reaper)

reaper.atexit(function()
  -- 後から始まった別の1つが動いているときは、明かりも合図も消さない
  if reaper.GetExtState(EXT, "owner") == token then
    if cmdID and cmdID > 0 then
      reaper.SetToggleCommandState(sectionID, cmdID, 0)
      reaper.RefreshToolbar2(sectionID, cmdID)
    end
    reaper.DeleteExtState(EXT, "owner", false)
    io.stopped()
  end
end)

local function loop()
  if reaper.GetExtState(EXT, "owner") ~= token then return end
  local ok, err = pcall(core.tick, st, io)
  if not ok then
    io.stopped()
    reaper.ShowConsoleMsg("[TUKONYA Auto Link] " .. tostring(err) .. "\n")
    reaper.ShowMessageBox("Auto Link が止まりました。線をそろえる見張りは今は動いていません。\n" ..
      "もう一度アクション「TUKONYA_Auto Link」を実行すると、また動き出します。", AR.TITLE, 0)
    return
  end
  reaper.defer(loop)
end

loop()
