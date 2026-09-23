--[[
@description TUKONYA Team Plugin Checker
@author tuko
@version 1.0.0
@changelog
  1.0.0: Team Plugin Checker として汎用化。共有フォルダを利用者が選べるようにし、日本語パッチの更新は別品目に分離。
@about
  # Team Plugin Checker

  チームや仲間うちで、各自が持っているプラグインを共有フォルダに集め、
  REAPERの中の小窓で「誰が何を持っているか」を検索・挿入できるツール。

  必要なもの: REAPER 7以降 / ReaImGui / SWS。
  入れたあとの手順は docs/onboarding_ja.md を見てください。
@provides
  [main] TUKONYA_Team Plugin Checker (Send Now).lua
  [main] TUKONYA_Team Plugin Checker (Install Startup).lua
  [nomain] lib/tpc_bootstrap.lua
  [nomain] lib/tpc_collector.lua
  [nomain] lib/tpc_config.lua
  [nomain] lib/tpc_ini.lua
  [nomain] lib/tpc_json.lua
  [nomain] lib/tpc_matcher.lua
  [nomain] lib/tpc_matcher_links.lua
  [nomain] lib/tpc_normalize.lua
  [nomain] lib/tpc_startup.lua
  [nomain] lib/tpc_store.lua
  [nomain] lib/tpc_ui.lua
  [nomain] lib/tpc_ui_popups.lua
  [nomain] lib/tpc_ui_settings.lua
  [nomain] lib/tpc_ui_tabs.lua
  [nomain] lib/tpc_viewmodel.lua
  [nomain] lib/tpc_viewmodel_actions.lua
  [nomain] lib/tpc_viewmodel_sort.lua
--]]

--[[
  TUKONYA_Team Plugin Checker.lua
  Team Plugin Checker — REAPER内の検索小窓（検索／整備／設定）を開く入口。

  必要なもの: REAPER 7以降、ReaImGui（1.92以降）、SWS（URLとフォルダを開くのに使う。
  無くても ExecProcess で代用する）。
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB(
    "ReaImGui が見つかりません。\n\nReaPack の「Browse packages」から ReaImGui を入れてから、" ..
    "もう一度このスクリプトを実行してください。",
    "Team Plugin Checker", 0)
  return
end

local boot = require("tpc_bootstrap")
local tpc_ui = require("tpc_ui")

local store = boot.new_store(boot.log)
local config = boot.new_config(store, boot.log)

-- 今のプロファイル（共有フォルダ・メンバーID・表示名）が未設定なら、ここで1回だけ聞く
-- （小窓を開いた後にダイアログが割り込まないように、描画を始める前に済ませる）。
-- キャンセルや入力の不備でも窓は開く（設定タブで案内する）。
boot.ensure_profile(store, config, boot.log, { prompt = true })

local ok, err = pcall(tpc_ui.open, {
  boot = boot,
  config = config,
  store = store,
  sendnow_path = SCRIPT_DIR .. "/TUKONYA_Team Plugin Checker (Send Now).lua",
  script_dir = SCRIPT_DIR,
})

if not ok then
  boot.log("小窓の起動に失敗: " .. tostring(err))
  reaper.MB("小窓を開けませんでした。\n\n" .. tostring(err) .. "\n\nログ: " .. boot.log_path(),
    "Team Plugin Checker", 0)
end
