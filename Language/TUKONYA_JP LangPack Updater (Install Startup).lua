--[[
  TUKONYA_JP LangPack Updater (Install Startup).lua
  REAPER起動時の自動確認（1日1回）を登録する。登録済みなら、外すかどうかを聞く。
  仕掛けは <REAPERリソース>/Scripts/__startup.lua の印つきの一塊だけ。中身は lib/jlu_startup.lua。
--]]

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local DIR = this_dir()
package.path = DIR .. "/lib/?.lua;" .. package.path

local jlu_util = require("jlu_util")
local jlu_startup = require("jlu_startup")

local TITLE = "JP LangPack Updater: 起動時の自動確認"

local deps = {
  resource_path = reaper.GetResourcePath(),
  script_dir = DIR,
  read_file = jlu_util.read_file,
  write_file = jlu_util.write_file,
  file_exists = reaper.file_exists,
}

if jlu_startup.is_installed(deps) then
  local ans = reaper.ShowMessageBox(
    "REAPER起動時の日本語パッチ自動確認は登録済みです。\n\n登録を外しますか？",
    TITLE, 4)
  if ans == 6 then
    local ok, err = jlu_startup.uninstall(deps)
    if ok then
      jlu_util.log("Startup: 登録を外した")
      reaper.ShowMessageBox("登録を外しました。\n次回のREAPER起動から自動確認は行いません。", TITLE, 0)
    else
      jlu_util.log("Startup: 登録を外せなかった: " .. tostring(err))
      reaper.ShowMessageBox("登録を外せませんでした。\n\n" .. tostring(err), TITLE, 0)
    end
  end
else
  local ok, info = jlu_startup.install(deps)
  if ok then
    jlu_util.log("Startup: 登録した（Scripts/" .. tostring(info) .. "）")
    reaper.ShowMessageBox(
      "登録しました。\n次回のREAPER起動から、1日1回日本語パッチの更新を確認します。\n\n"
      .. "今すぐ確認したいときは「TUKONYA_JP LangPack Updater.lua」を実行してください。",
      TITLE, 0)
  else
    jlu_util.log("Startup: 登録できなかった: " .. tostring(info))
    reaper.ShowMessageBox("登録できませんでした。\n\n" .. tostring(info), TITLE, 0)
  end
end
