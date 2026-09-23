--[[
  TUKONYA_VST3 Only Master.lua
  「MASTER」という名前のトラック（TUKONYA RENDER が .vstpreset を出すマスターチェーンのトラック。
  REAPER 本体のマスタートラックではない）に VST3 以外のプラグイン（CLAP / VST2 / AU / JSFX …）が
  挿さった瞬間に気づいて、VST3版に差し替えるか聞く見張り役。ReaInsert は黙って通す。

  使い方:
    - アクション一覧から走らせると見張りが始まる（トグル。もう一度走らせると止まる）。
    - 「(Install Startup)」を1回走らせておくと、REAPER起動時に自動で始まる。
    - 窓が出たら「はい」= VST3版を同じ位置に新品で入れ、元を消す（設定は引き継がない。Cmd+Z で戻る）。
      「いいえ」= このまま。同じ名前のプラグインは、そのプロジェクトを閉じる（切り替える）まで聞かない。
      （ファイルには残さない）
    - すでに入っているものは何も言わない（起動時とプロジェクト切替時は黙って覚えるだけ）。

  試験用の差し込み口（無人試験でのみ使う。普段は無い）:
    VOM_TEST = { ask = function(msg) return true end, pick = function(cands) return 1 end,
                 notify = function(msg) end, oneshot = true }
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path

local C = require("vom_core")

local TITLE = "VST3 Only Master"
local MASTER_TRACK_NAME = "MASTER" -- TUKONYA RENDER の設定 MASTER_NAME と同じ（大文字小文字も一致）
local POLL_SEC = 0.5

-- 旧版（v1.0.0 試作）がファイルに残した「いいえ」の覚え書きは使わないので消す
pcall(reaper.DeleteExtState, "TUKONYA_VST3OnlyMaster", "ignored_guids", true)

local T = rawget(_G, "VOM_TEST") or {}

-- ============================================================
-- トグル（もう一度走らせたら止まる。ツールバーに置けば点灯する）
-- ============================================================
local _, _, section_id, cmd_id = reaper.get_action_context()
if reaper.set_action_options then
  reaper.set_action_options(1 | 4)
end
if section_id and cmd_id and cmd_id ~= 0 then
  reaper.SetToggleCommandState(section_id, cmd_id, 1)
  reaper.RefreshToolbar2(section_id, cmd_id)
end
reaper.atexit(function()
  if section_id and cmd_id and cmd_id ~= 0 then
    reaper.SetToggleCommandState(section_id, cmd_id, 0)
    reaper.RefreshToolbar2(section_id, cmd_id)
  end
end)

-- ============================================================
-- REAPER との出入り
-- ============================================================
local function find_master_track()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == MASTER_TRACK_NAME then return tr end
  end
  return nil
end

--- @return track|nil, chain（トラックが無ければ nil, {}）
local function master_chain()
  local master = find_master_track()
  local chain = {}
  if not master then return nil, chain end
  local n = reaper.TrackFX_GetCount(master)
  for i = 0, n - 1 do
    local _, name = reaper.TrackFX_GetFXName(master, i, "")
    local _, ftype = reaper.TrackFX_GetNamedConfigParm(master, i, "fx_type")
    chain[#chain + 1] = { guid = reaper.TrackFX_GetFXGUID(master, i), name = name, fx_type = ftype }
  end
  return master, chain
end

local function index_of_guid(master, guid)
  local n = reaper.TrackFX_GetCount(master)
  for i = 0, n - 1 do
    if reaper.TrackFX_GetFXGUID(master, i) == guid then return i end
  end
  return nil
end

local function installed_fx()
  local list = {}
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    list[#list + 1] = { name = name, ident = ident }
    i = i + 1
  end
  return list
end

local function ask(msg)
  if T.ask then return T.ask(msg) end
  return reaper.MB(msg, TITLE, 4) == 6 -- 6 = はい
end

local function notify(msg)
  if T.notify then return T.notify(msg) end
  reaper.MB(msg, TITLE, 0)
end

--- 候補が複数のとき番号で選ぶ。nil = やめる
local function pick(cands)
  if T.pick then return T.pick(cands) end
  local lines = { "VST3版の候補が複数あります。番号を入れてください。", "" }
  for i, c in ipairs(cands) do lines[#lines + 1] = ("%d: %s"):format(i, c.name) end
  reaper.MB(table.concat(lines, "\n"), TITLE, 0)
  local ok, ret = reaper.GetUserInputs(TITLE, 1, ("番号 (1-%d)"):format(#cands), "1")
  if not ok then return nil end
  local k = tonumber(ret)
  if k and cands[k] then return k end
  return nil
end

-- 「いいえ」の覚え書きはメモリだけ。プラグインの名前で覚え、プロジェクトが切り替わる（閉じる）と忘れる
local ignored_names = {}
local function is_ignored(fx) return ignored_names[fx.name] == true end
local function remember_ignored(fx) ignored_names[fx.name] = true end

-- ============================================================
-- 差し替え
-- ============================================================
local function swap(master, off, known)
  local cands, how = C.find_vst3_candidates(off.name, installed_fx())
  if #cands == 0 then
    notify(("VST3版が見つかりませんでした。そのままにします。\n\n%s"):format(off.name))
    return false
  end
  local k = 1
  if #cands > 1 then
    k = pick(cands)
    if not k then return false end
  end
  local target = cands[k].name

  local idx = index_of_guid(master, off.guid)
  if not idx then return false end -- もう無い（消された・戻された）
  local enabled = reaper.TrackFX_GetEnabled(master, idx)

  reaper.Undo_BeginBlock2(0)
  local newidx = reaper.TrackFX_AddByName(master, target, false, -1000 - idx)
  if newidx < 0 then
    reaper.Undo_EndBlock2(0, TITLE .. ": 差し替え失敗", -1)
    notify(("VST3版を入れられませんでした。そのままにします。\n\n%s"):format(target))
    return false
  end
  known[reaper.TrackFX_GetFXGUID(master, newidx)] = true
  local oldidx = index_of_guid(master, off.guid)
  if oldidx then reaper.TrackFX_Delete(master, oldidx) end
  local ni = index_of_guid(master, reaper.TrackFX_GetFXGUID(master, newidx)) or newidx
  reaper.TrackFX_SetEnabled(master, ni, enabled)
  reaper.Undo_EndBlock2(0, TITLE .. ": " .. off.name .. " → " .. target, -1)
  return true
end

-- ============================================================
-- 見張りの本体
-- ============================================================
local known = {}
local cur_proj = nil   -- 「タブ＋ファイル名」。同じタブに別のプロジェクトを開いたときも切替扱いにする
local last_t = 0

local function check_once()
  local proj, fn = reaper.EnumProjects(-1)
  local proj_key = tostring(proj) .. "|" .. tostring(fn or "")
  local master, chain = master_chain()
  if proj_key ~= cur_proj then
    cur_proj = proj_key
    known = {}
    ignored_names = {}   -- プロジェクトが変わったら「いいえ」も忘れる
    C.baseline(chain, known) -- 開いた時点で入っている物には何も言わない
    return
  end
  if not master then return end -- 「MASTER」トラックが無いプロジェクトでは何もしない
  local offenders = C.find_new_offenders(chain, known, {})
  for _, off in ipairs(offenders) do
    if is_ignored(off) then goto continue end
    local yes = ask((
      "MASTER に VST3 以外がインサートされました:\n\n  %s\n\n" ..
      "VST3版に差し替えますか？\n" ..
      "（「いいえ」を選んだ場合は差し替えません。今立ち上がっているプロジェクトが閉じられるまで、" ..
      "同名プラグインは確認を行いません）"):format(off.name))
    if yes then
      if not swap(master, off, known) then remember_ignored(off) end
    else
      remember_ignored(off)
    end
    ::continue::
  end
end

local function loop()
  local t = reaper.time_precise()
  if t - last_t >= POLL_SEC then
    last_t = t
    local ok, err = pcall(check_once)
    if not ok then reaper.ShowConsoleMsg(TITLE .. ": " .. tostring(err) .. "\n") end
  end
  if T.oneshot then return end
  reaper.defer(loop)
end

-- 起動時: 今の中身を黙って覚える
check_once()
if T.oneshot then
  -- 無人試験: 呼び手が VOM_CHECK() で任意のタイミングに1回ずつ調べられる
  VOM_CHECK = check_once
else
  reaper.defer(loop)
end
