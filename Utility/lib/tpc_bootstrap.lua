--[[
  tpc_bootstrap.lua
  Team Plugin Checker — 2つの入口スクリプト（TUKONYA_Team Plugin Checker (Send Now).lua と
  TUKONYA_Team Plugin Checker.lua）が共通で必要とする「起動のお膳立て」。
  ここだけが reaper の一般APIを触る（ImGuiは触らない）。

  中身:
    - ログ（<REAPERリソース>/TeamPluginChecker.log、末尾200行だけ残す）
    - tpc_store 用の deps（ファイル読み書き・列挙・時刻）を実機reaperから組み立てる
    - tpc_config（ExtState）の生成
    （初回設定・プロファイルの追加は小窓の設定タブの入力欄に移した: tpc_ui_settings.lua）

--]]

local tpc_store = require("tpc_store")
local tpc_config = require("tpc_config")

local M = {}

M.LOG_MAX_LINES = 200

-- ============================================================
-- ログ
-- ============================================================

function M.resource_path()
  return reaper.GetResourcePath()
end

function M.log_path()
  return M.resource_path() .. "/TeamPluginChecker.log"
end

--- ログに1行足す。末尾 LOG_MAX_LINES 行だけ残す（無限に太らせない）。
function M.log(msg)
  local path = M.log_path()
  local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(msg)
  local lines = {}
  local f = io.open(path, "rb")
  if f then
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
  end
  lines[#lines + 1] = line
  local start = math.max(1, #lines - M.LOG_MAX_LINES + 1)
  local out = io.open(path, "wb")
  if out then
    for i = start, #lines do out:write(lines[i], "\n") end
    out:close()
  end
end

--- ログの最後の1行（設定タブの「今すぐ更新」の結果表示用）。
function M.log_last_line()
  local f = io.open(M.log_path(), "rb")
  if not f then return nil end
  local last = nil
  for l in f:lines() do if l ~= "" then last = l end end
  f:close()
  return last
end

-- ============================================================
-- tpc_store 用の deps
-- ============================================================

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function enumerate(fn, dir)
  local names = {}
  fn(dir, -1) -- キャッシュを無効化してから読む
  local i = 0
  while true do
    local name = fn(dir, i)
    if not name then break end
    names[#names + 1] = name
    i = i + 1
  end
  return names
end

function M.build_deps(log_fn)
  log_fn = log_fn or M.log
  return {
    os_name = reaper.GetOS(),
    getenv = os.getenv,
    file_exists = reaper.file_exists,
    enumerate_files = function(dir) return enumerate(reaper.EnumerateFiles, dir) end,
    -- 空に近い共有フォルダ（中に plugins/ しか無い等）も「ある」と分かるようにフォルダも数える
    enumerate_subdirs = reaper.EnumerateSubdirectories
      and function(dir) return enumerate(reaper.EnumerateSubdirectories, dir) end or nil,
    read_file = M.read_file,
    write_file = M.write_file,
    rename = os.rename,
    remove = os.remove,
    mkdir_p = function(path) reaper.RecursiveCreateDirectory(path, 0) end,
    now_iso = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    log = log_fn,
  }
end

function M.now_iso()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- ============================================================
-- 設定（ExtState）
-- ============================================================

--- @param store tpc_store|nil  旧版設定の引き継ぎ（Dropboxの場所探し）に使う
function M.new_config(store, log_fn)
  return tpc_config.new({
    get = function(section, key) return reaper.GetExtState(section, key) end,
    set = function(section, key, value) reaper.SetExtState(section, key, value, true) end,
    store = store,
    log = log_fn or M.log,
  })
end

function M.new_store(log_fn)
  return tpc_store.new(M.build_deps(log_fn))
end

return M
