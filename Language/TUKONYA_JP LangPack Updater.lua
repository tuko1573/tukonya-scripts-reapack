-- @description TUKONYA JP LangPack Updater
-- @author tuko
-- @version 1.0.0
-- @changelog 1.0.0: Shippo Blend Plugins 0.3.0 の日本語パッチ自動更新を独立させた。
-- @about
--   REAPERの日本語パッチ（ReaperLangPack）を配布元から自動で最新に保ちます。
--   REAPER起動時に1日1回だけ確認し、新しい版があれば差し替えます。別の日本語パッチを使っている場合はこの配布元の版に切り替えます（元のファイルは残します）。
--   最初に「TUKONYA_JP LangPack Updater (Install Startup).lua」を1回実行してください。このスクリプトは「今すぐ確認」です。
-- @provides
--   [main] TUKONYA_JP LangPack Updater (Install Startup).lua
--   [nomain] lib/jlu_langpack.lua
--   [nomain] lib/jlu_startup.lua
--   [nomain] lib/jlu_util.lua

--[[
  TUKONYA_JP LangPack Updater.lua
  日本語パッチの更新を「今すぐ」確認する（Actionsから手で実行）。
  1日1回の制限を無視し、結果を必ずダイアログで知らせる。

  REAPER起動時は __startup.lua の一塊から JLU_QUIET = true で呼ばれる。
  そのときは1日1回の制限を守り、確認結果のダイアログ（最新です等）は出さない。
  中身は lib/jlu_langpack.lua。
--]]

local quiet = (JLU_QUIET == true)

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

package.path = this_dir() .. "/lib/?.lua;" .. package.path

local jlu_util = require("jlu_util")
local jlu_langpack = require("jlu_langpack")

local deps = jlu_langpack.reaper_deps(jlu_util.read_file, jlu_util.write_file, jlu_util.log)

local opts = quiet and {} or { force = true, verbose = true }
local ok, err = pcall(jlu_langpack.run, deps, opts)
if not ok then
  jlu_util.log("LangPack: エラー: " .. tostring(err))
  if not quiet then
    reaper.ShowMessageBox(
      "日本語パッチの確認でエラーが起きました。\n\n" .. tostring(err)
      .. "\n\nログ: " .. jlu_util.log_path(),
      jlu_langpack.TITLE, 0)
  end
end
