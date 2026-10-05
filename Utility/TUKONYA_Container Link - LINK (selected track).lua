--[[
  TUKONYA_Container Link - LINK (selected track).lua
  選んだトラックのコンテナ（目印「TUKONYA Container Link」と Link Ch が付いたもの）を正として、
  同じ Ch の全部のコンテナを、FX の並び・つまみ・バイパス・オートメーションの線までまるごと同じにする。
  1つのトラックに Ch の違うコンテナが複数あれば、それぞれの Ch で LINK する。同じ Ch のトラックを複数選んだときは、
  いちばん上のトラックが正になる（ほかのトラックの目印にそう出る）。Ctrl+Z 1回で全部が元に戻る。
  見張り「TUKONYA_Container Link」が動いている必要がある。うまくいったときは何も出さない（目印に「LINK しました」）。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
package.path = this_dir() .. "/lib/?.lua;" .. package.path
local L = require("cl_link")

local EXT, TITLE = "TUKONYA_ChainLink", "TUKONYA Container Link"
-- もう一度押されたら、前の1回を止めて新しく始める
if reaper.set_action_options then reaper.set_action_options(1 | 2) end

local function say(text) reaper.MB(text, TITLE, 0) end

-- 選んだトラック（上から順）
local guids = {}
for i = 0, reaper.CountSelectedTracks(0) - 1 do
  guids[#guids + 1] = reaper.GetTrackGUID(reaper.GetSelectedTrack(0, i))
end
if #guids == 0 then
  say("LINK するトラックを選んでください。")
  return
end

-- 見張りが動いているか（合図が 0.25 秒のあいだに進むか）。defer で待つので、このスクリプト自身は undo を作らない
reaper.gmem_attach("TUKONYA_ChainLink")
local hb0, t0 = reaper.gmem_read(0), reaper.time_precise()
local id, t_req

local function wait_result()
  local v = reaper.GetExtState(EXT, "link_res")
  local r = L.decode_res(v)
  if r and r.id == id then
    reaper.DeleteExtState(EXT, "link_res", false)
    -- 0 = できた（目印と undo 履歴が知らせる）、1 = 録音中で止まってから行う（録音中にダイアログは出さない）
    if r.code ~= L.CODE.DONE and r.code ~= L.CODE.HELD and r.code ~= L.CODE.HELD_PLAY then say(r.text ~= "" and r.text or (L.TEXT[r.code] or "LINK できませんでした")) end
    return
  end
  if reaper.time_precise() - t_req > 3.0 then
    -- 自分の依頼がまだ残っていれば消す（あとで勝手に実行されないように）
    local q = L.decode_req(reaper.GetExtState(EXT, "link_req"))
    if q and q.id == id then reaper.DeleteExtState(EXT, "link_req", false) end
    say("応答がありません。アクション「TUKONYA_Container Link」を一度止めて、もう一度実行してからお試しください。")
    return
  end
  reaper.defer(wait_result)
end

local function check_alive()
  if reaper.time_precise() - t0 < 0.25 then reaper.defer(check_alive); return end
  local hb1 = reaper.gmem_read(0)
  if hb0 == 0 or hb1 == 0 or hb1 == hb0 then
    say("Container Link の見張りが動いていません。\nアクション「TUKONYA_Container Link」を実行してから、もう一度どうぞ。")
    return
  end
  t_req = reaper.time_precise()
  id = ("%.6f-%d"):format(t_req, math.random(1, 1000000000))
  reaper.DeleteExtState(EXT, "link_res", false)
  reaper.SetExtState(EXT, "link_req", L.encode_req(id, t_req, guids), false)
  reaper.defer(wait_result)
end

reaper.defer(check_alive)
