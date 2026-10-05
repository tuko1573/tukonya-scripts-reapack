--[[
  TUKONYA_Container Link.lua（常駐・トグル。旧名 TUKONYA_Chain Link）
  コンテナに目印のエフェクト「TUKONYA Container Link」を入れて同じ Link Ch を選ぶと、
  同じ Ch のコンテナ同士で、中のプラグインのつまみ・バイパス・画面だけの設定がそろい続ける。
  どのトラックで触っても、ほかのトラックへ写る（リーダーなし）。
  目印の画面の「LINK」ボタン、またはアクション「TUKONYA_Container Link - LINK (selected track)」で、
  そのトラックのコンテナを正として、同じ Ch の全部のコンテナをまるごと同じにする。
  もう一度実行すると止まる。REAPER 起動時に自動で始めるには「(Install Startup)」を1回実行。
--]]

-- ===== 設定 =====
local BLOB_WHILE_PLAYING = true   -- 再生中も、画面だけの設定（数値に出ない設定）を写す
local DEBUG = false               -- true にすると、何をしたかを ReaScript コンソールに出す
-- =================

-- コンテナの中を調べる API は REAPER 7.06 から、触ったつまみを知る API は 7 から。無ければ動かさずに知らせる
if not reaper.GetTouchedOrFocusedFX or not reaper.Undo_GetCurEntry then
  reaper.MB("TUKONYA Container Link は REAPER 7.79 以降で動きます。\nREAPER を新しくしてからお使いください。", "TUKONYA Container Link", 0)
  return
end

-- 自分の場所（旧名のファイルから dofile されたときも、この本体の場所）
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
package.path = this_dir() .. "/lib/?.lua;" .. package.path
local core = require("cl_core")
local CR = require("cl_reaper")
CR.DEBUG = DEBUG

local EXT = "TUKONYA_ChainLink"   -- 名前空間は v1 のまま（v1 の見張りを owner で止めるため、DESIGN_V2 §1）
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

local st = core.new({ blob_while_playing = BLOB_WHILE_PLAYING })
local io = CR.new(reaper)

reaper.atexit(function()
  -- 後から始まった別の1つが動いているときは、明かりも合図も消さない
  if reaper.GetExtState(EXT, "owner") == token then
    -- 画面を開いたまま止めたときも、まだ写していない「画面だけの設定」を先に全員へ写す（DESIGN_V2 §2.2 R4b）
    pcall(core.commit_pending, st, io)
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
    reaper.ShowConsoleMsg("[TUKONYA Container Link] " .. tostring(err) .. "\n")
    reaper.ShowMessageBox("Container Link が止まりました。つまみをそろえる見張りは今は動いていません。\n" ..
      "もう一度アクション「TUKONYA_Container Link」を実行すると、また動き出します。", CR.TITLE, 0)
    return
  end
  reaper.defer(loop)
end

loop()
