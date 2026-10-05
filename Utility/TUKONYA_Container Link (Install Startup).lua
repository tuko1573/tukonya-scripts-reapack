--[[
  TUKONYA_Container Link (Install Startup).lua
  REAPER起動時に「Container Link」（コンテナの中身をそろえる見張り）が自動で始まるように登録する（1回実行）。
  `<REAPERリソース>/Scripts/__startup.lua` に印で挟んだ一塊を足すだけ。印の外側は触らない。
  旧名（TUKONYA Chain Link）の一塊があれば外して、新しい一塊に置き換える。旧名のスクリプト3本はアクション一覧から外して消す
  （旧名の目印 JSFX は保存済みのプロジェクトのために残す）。
  外すときは「(Uninstall Startup)」を実行。
--]]
local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end
local SCRIPT_DIR = this_dir()
package.path = SCRIPT_DIR .. "/lib/?.lua;" .. package.path
local S = require("cl_startup")
local TITLE = "TUKONYA Container Link"

local function read_file(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end
local function write_file(p, t) local f = io.open(p, "wb"); if not f then return false end; f:write(t); f:close(); return true end

-- 1. 旧名の一塊を外して新しい一塊を足す（1回の書き込み）
local deps = { resource_path = reaper.GetResourcePath(), script_dir = SCRIPT_DIR,
               read_file = read_file, write_file = write_file, file_exists = reaper.file_exists }
local ok, info = S.install(deps)
if not ok then
  reaper.MB("登録できませんでした。\n\n" .. tostring(info), TITLE, 0)
  return
end
-- 2. 旧名のスクリプトをアクション一覧から外す（ファイルを消しても一覧の行は残るため）
local old = S.old_files(SCRIPT_DIR)
local had_old = false
for _, p in ipairs(old) do
  if reaper.file_exists(p) then had_old = true end
  reaper.AddRemoveReaScript(false, 0, p, false)     -- also when the file is already gone (its row would stay otherwise)
end
-- 3. 新しい本体と LINK のアクションを一覧に載せる（キーやツールバーに割り当てられるように）
reaper.AddRemoveReaScript(true, 0, SCRIPT_DIR .. "/" .. S.LINK_ACTION, false)
local id = reaper.AddRemoveReaScript(true, 0, SCRIPT_DIR .. "/" .. S.MAIN, true)
-- 4. 見張りを始める（旧名の見張りが動いていても、最後に始まった1つだけが動く）
local started = false
if id and id > 0 and reaper.GetToggleCommandStateEx(0, id) ~= 1 then
  reaper.Main_OnCommand(id, 0); started = true
end
-- 5. 旧名のスクリプトのファイルを消す（自分のフォルダの、決まった3つの名前だけ）
for _, p in ipairs(old) do if reaper.file_exists(p) then os.remove(p) end end

reaper.MB("REAPER起動時に Container Link（コンテナの中身をそろえる見張り）が自動で始まるように登録しました。\n" ..
          (started and "今から見張りを始めました。\n" or "見張りはすでに動いています。\n") ..
          (had_old and "\n旧名（Chain Link）の登録は外しました。旧名のアクションをツールバーやキーに割り当てていた場合は、" ..
                       "「TUKONYA_Container Link」を割り当て直してください。\n" or "") ..
          "\nアクション「TUKONYA_Container Link - LINK (selected track)」も一覧に入れました。\n" ..
          "\n書き足した場所: " .. S.startup_path(deps) .. "\n外すときは「(Uninstall Startup)」を実行してください。",
          TITLE, 0)
