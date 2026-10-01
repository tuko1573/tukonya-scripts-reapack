--[[
  TUKONYA_Folder Link.lua（常駐・トグル）
  編集画面（TCP）とミキサーのフォルダ開閉を連動させる。両方向で、動いた側にもう片方を合わせる。
  プロジェクトを開いたとき（タブ切替も）にずれていたら、編集画面に合わせてミキサーをそろえる。
  もう一度実行すると止まる。REAPER 起動時に自動で始めるには「(Install Startup)」を1回実行。
--]]

-- ===== 設定 =====
local HIDE_FROM_LEVEL = 1        -- 編集画面の畳み方がこの値以上ならミキサーで子を隠す（1=小さくでも隠す, 2=完全に畳んだときだけ）
local CLOSE_LEVEL     = 2        -- ミキサーで閉じたときの編集画面の畳み方（1=小さく, 2=完全に畳む）
local MIXER_MODE      = "chunk"  -- "chunk"（Undo履歴を汚さない。既定）| "action"（アクション41665。Undo点が1つ増える）
local INTERVAL_SEC    = 0.2
-- =================

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
package.path = this_dir() .. "/lib/?.lua;" .. package.path
local C = require("fl_core")

local _, _, sectionID, cmdID = reaper.get_action_context()
-- もう一度走らせたら止まる（1）／ツールバーの点灯・消灯を REAPER に任せる（4）。REAPER 7 以降。
if reaper.set_action_options then reaper.set_action_options(1 | 4) end
if cmdID and cmdID > 0 then
  reaper.SetToggleCommandState(sectionID, cmdID, 1)
  reaper.RefreshToolbar2(sectionID, cmdID)
end
reaper.atexit(function()
  if cmdID and cmdID > 0 then
    reaper.SetToggleCommandState(sectionID, cmdID, 0)
    reaper.RefreshToolbar2(sectionID, cmdID)
  end
end)

local st = C.new_watch_state()
local next_t = 0

local function loop()
  local now = reaper.time_precise()
  if now >= next_t then
    next_t = now + INTERVAL_SEC
    local ok, res = pcall(C.watch_tick, reaper, st, { hide_from_level = HIDE_FROM_LEVEL, close_level = CLOSE_LEVEL, mixer_mode = MIXER_MODE })
    if not ok then reaper.ShowConsoleMsg("[Folder Link] " .. tostring(res) .. "\n")
    elseif res and res > 0 then reaper.TrackList_AdjustWindows(false) end
  end
  reaper.defer(loop)
end

loop()
