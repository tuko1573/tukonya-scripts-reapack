--[[
  tpc_bootstrap.lua
  Team Plugin Checker — 2つの入口スクリプト（TUKONYA_Team Plugin Checker (Send Now).lua と
  TUKONYA_Team Plugin Checker.lua）が共通で必要とする「起動のお膳立て」。
  ここだけが reaper の一般APIを触る（ImGuiは触らない）。

  中身:
    - ログ（<REAPERリソース>/TeamPluginChecker.log、末尾200行だけ残す）
    - tpc_store 用の deps（ファイル読み書き・列挙・時刻）を実機reaperから組み立てる
    - tpc_config（ExtState）の生成
    - 初回設定（今のプロファイルの 共有フォルダ・メンバーID・表示名）の確認
    - プロファイルの追加

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

-- ============================================================
-- 初回設定（今のプロファイル: 共有フォルダ・メンバーID・表示名）
-- ============================================================

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fail(log_fn, reason, quiet)
  log_fn("初回設定: " .. reason)
  if not quiet and reaper and reaper.MB then
    reaper.MB(reason, "Team Plugin Checker", 0)
  end
  return false, reason
end

--- 今のプロファイルがそろっていなければ、1つのダイアログで3項目を聞く。
-- @param opts { prompt = bool }  prompt=false なら聞かずに false を返す（起動時・小窓の自動処理）
-- @return true（そろっている／今そろえた） / false, reason
function M.ensure_profile(store, config, log_fn, opts)
  opts = opts or {}
  log_fn = log_fn or M.log
  local name = config:current()
  if config:profile_complete(name) then return true end

  if opts.prompt == false then
    log_fn(("プロファイル %s の初回設定がまだ（共有フォルダ・メンバーID・表示名）"):format(name))
    return false, "未設定"
  end

  local prefill_dir = config:get_shared_dir()
  if not prefill_dir then prefill_dir = store:suggest_shared_dir() end
  local defaults = table.concat({
    prefill_dir or "", config:get_member_id() or "", config:get_display_name() or "",
  }, ",")

  local ok, csv = reaper.GetUserInputs(
    "Team Plugin Checker 初回設定（プロファイル: " .. name .. "）", 3,
    "共有フォルダのパス,メンバーID（半角英数）,表示名,extrawidth=300", defaults)
  if not ok then
    log_fn("初回設定がキャンセルされた（プロファイル: " .. name .. "）")
    return false, "キャンセル"
  end

  local dir, id, display_name = csv:match("^([^,]*),([^,]*),(.*)$")
  dir = tpc_store.normalize_pasted_path(dir)
  id = trim(id)
  display_name = trim(display_name)

  if dir == "" then
    return fail(log_fn, "共有フォルダのパスが空です。", opts.quiet)
  end
  if not store:path_exists(dir) then
    return fail(log_fn, "共有フォルダが見つかりません: " .. dir ..
      "\n\n先にフォルダを作ってから、もう一度実行してください。", opts.quiet)
  end
  if not tpc_config.valid_member_id(id) then
    return fail(log_fn, "メンバーIDは半角の小文字英数字とアンダースコアのみ、1〜16文字です（例: taro）。" ..
      "\n入力: " .. id, opts.quiet)
  end
  if display_name == "" then display_name = id end

  config:set_shared_dir(dir)
  config:set_member_id(id)
  config:set_display_name(display_name)
  log_fn(("初回設定: プロファイル %s 共有フォルダ=%s member=%s"):format(name, dir, id))
  return true
end

--- プロファイル名を聞いて追加し、今のプロファイルにしてから初回設定を聞く。
-- 3項目の方でキャンセルされたら、追加したプロファイルは残す（設定タブで後から埋められる）。
-- @return true / false, reason
function M.prompt_new_profile(store, config, log_fn)
  log_fn = log_fn or M.log
  local ok, name = reaper.GetUserInputs("Team Plugin Checker: プロファイルを追加", 1,
    "プロファイル名（半角英数・_・-）", "")
  if not ok then return false, "キャンセル" end
  name = trim(name)
  local added, err = config:add_profile(name)
  if not added then
    return fail(log_fn, tostring(err), false)
  end
  config:set_current(name)
  log_fn("プロファイルを追加: " .. name)
  return M.ensure_profile(store, config, log_fn, { prompt = true })
end

return M
