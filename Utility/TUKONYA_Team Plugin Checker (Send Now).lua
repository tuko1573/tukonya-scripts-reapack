--[[
  TUKONYA_Team Plugin Checker (Send Now).lua
  Team Plugin Checker — 自分のプラグイン一覧を集めて、全プロファイルの共有フォルダへ書く。
  画面は出さない（今のプロファイルが未設定のまま手で実行したときは、小窓の設定タブへ
  案内するメッセージを1つ出して何もせずに終わる。入力はすべて小窓の設定タブで行う）。
  起動時（__startup.lua）と「今すぐ更新」ボタンの両方から呼ぶ。
  一覧の収集は1回だけ行い、プロファイルごとに書き分ける（同じ機械なので中身は同じ）。
  1日1回のスロットルと前回の指紋はプロファイルごとに持つ。

  実行前に `TPC_FORCE = true` をグローバルに立てると、今日すでに送っていても
  スロットル（1日1回）を無視して送る（「今すぐ更新」ボタン用）。

--]]

-- ============================================================
-- lib/ の場所を自分のパスから解決する
-- ============================================================

local function this_dir()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("^(.*)[/\\][^/\\]+$") or "."
end

local LIB_DIR = this_dir() .. "/lib"
package.path = LIB_DIR .. "/?.lua;" .. package.path

local tpc_bootstrap = require("tpc_bootstrap")
local tpc_store = require("tpc_store")
local tpc_collector = require("tpc_collector")
local tpc_normalize = require("tpc_normalize")
local tpc_json = require("tpc_json")

local RESOURCE_PATH = tpc_bootstrap.resource_path()
local LOG_PATH = tpc_bootstrap.log_path()

--- ログ（互換のためグローバル名も残す。実体は tpc_bootstrap.log）。
function SB_SENDNOW_LOG(msg) tpc_bootstrap.log(msg) end


-- ============================================================
-- EnumInstalledFX の収集
-- ============================================================

local function collect_entries()
  local out = {}
  local i = 0
  while true do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    out[#out + 1] = { index = i, name = name, ident = ident }
    i = i + 1
  end
  return out
end

--- reaper-vstplugins_*.ini はOSごとにファイル名が違う。存在する方を読む。
local function read_vst_ini_text(deps)
  local candidates = {
    RESOURCE_PATH .. "/reaper-vstplugins_arm64.ini", -- macOS-arm64
    RESOURCE_PATH .. "/reaper-vstplugins64.ini",      -- Win64 / OSX64
  }
  for _, path in ipairs(candidates) do
    if deps.file_exists(path) then
      return deps.read_file(path)
    end
  end
  return nil
end

-- ============================================================
-- 既存メンバーファイルの unusable フラグを引き継ぐ
-- ============================================================

local function load_existing_unusable(store, root, member_id)
  local unusable_by_key = {}
  local text = store.deps.read_file(root .. store:sep() .. "members" .. store:sep() .. member_id .. ".json")
  if not text then return unusable_by_key end
  local ok, doc = pcall(tpc_json.decode, text)
  if not ok or type(doc) ~= "table" then return unusable_by_key end
  for _, p in ipairs(doc.plugins or {}) do
    if p.unusable then unusable_by_key[p.key] = true end
  end
  return unusable_by_key
end

-- ============================================================
-- 一覧 → member doc の plugins（プロファイルごとに unusable の引き継ぎだけ違う）
-- ============================================================

local function build_plugins(inv, unusable_by_key)
  local plugins = {}
  for key, p in pairs(inv.plugins) do
    local class_id = nil
    for _, f in ipairs(p.formats) do
      if f.fmt == "VST3" and f.class_id and f.class_id ~= "" then class_id = f.class_id; break end
    end
    if not class_id then
      for _, f in ipairs(p.formats) do
        if f.class_id and f.class_id ~= "" then class_id = f.class_id; break end
      end
    end
    local formats = {}
    for _, f in ipairs(p.formats) do
      formats[#formats + 1] = { fmt = f.fmt, raw_name = f.raw_name, ident = f.ident }
    end
    plugins[#plugins + 1] = {
      key = key, name = p.name, vendor = p.vendor, instrument = p.instrument,
      unusable = unusable_by_key[key] == true,
      class_id = class_id, formats = formats,
    }
  end
  return plugins
end

-- ============================================================
-- 1つのプロファイルへ送る
-- ============================================================

--- @param pc  config:for_profile(name) の写し
-- @param ctx { store, deps, today, force, inventory = function() -> inv（初回だけ集める） }
-- @return result { name, status = "written"|"same"|"throttled"|"skipped"|"error", plugins, path, reason }
local function send_profile(name, pc, ctx)
  local store, deps = ctx.store, ctx.deps
  local member_id = pc:get_member_id()
  local display_name = pc:get_display_name()
  local shared_dir = pc:get_shared_dir()

  if not store:path_exists(shared_dir) then
    SB_SENDNOW_LOG(("[%s] 共有フォルダが見つからないので飛ばした: %s"):format(name, tostring(shared_dir)))
    return { name = name, status = "skipped", reason = "共有フォルダが見つかりません: " .. tostring(shared_dir) }
  end

  local root = store:root(shared_dir)
  store:ensure_dirs(root)
  local member_path = root .. store:sep() .. "members" .. store:sep() .. member_id .. ".json"

  -- スロットル: 今日すでに送っていれば、TPC_FORCE が無い限り何もしない。
  if not ctx.force and pc:get_last_sent_date() == ctx.today then
    -- 起動時に一覧が揃っているかを後で比べられるよう、件数だけ数えて記録する
    local n = 0
    while reaper.EnumInstalledFX(n) do n = n + 1 end
    SB_SENDNOW_LOG(("[%s] 今日はすでに送信済みなのでスキップ (member=%s, 一覧%d件)"):format(name, member_id, n))
    return { name = name, status = "throttled" }
  end

  local inv = ctx.inventory()
  local plugins = build_plugins(inv, load_existing_unusable(store, root, member_id))

  local doc = {
    schema = tpc_store.SCHEMA,
    normalizer_version = tpc_normalize.VERSION,
    member_id = member_id,
    display_name = display_name,
    os = deps.os_name,
    reaper = reaper.GetAppVersion(),
    updated_at = deps.now_iso(),
    inventory_hash = nil,
    plugins = plugins,
  }
  doc.inventory_hash = tpc_store.hash_member_doc(doc)

  local same_as_before = (doc.inventory_hash == pc:get_last_hash())

  if same_as_before and not ctx.force and deps.file_exists(member_path) then
    -- 前回と同じ一覧で、ファイルも既にある → 日付だけ更新して書かない
    pc:set_last_sent_date(ctx.today)
    SB_SENDNOW_LOG(("[%s] 前回と同じ一覧なので書き込みなし (member=%s)"):format(name, member_id))
    return { name = name, status = "same", plugins = #plugins }
  end

  local ok, err = store:write_member(root, doc)
  if not ok then
    SB_SENDNOW_LOG(("[%s] write_member失敗: %s"):format(name, tostring(err)))
    return { name = name, status = "error", reason = tostring(err) }
  end

  pc:set_last_sent_date(ctx.today)
  pc:set_last_hash(doc.inventory_hash)

  SB_SENDNOW_LOG(string.format(
    "[%s] 送信完了 member=%s plugins=%d hash=%s (前回から%s)",
    name, member_id, #plugins, doc.inventory_hash, same_as_before and "変化なし" or "変化あり"))
  return { name = name, status = "written", plugins = #plugins, path = member_path }
end

-- ============================================================
-- メイン
-- ============================================================

local STATUS_TEXT = {
  written = function(r) return ("%d件を書いた"):format(r.plugins or 0) end,
  same = function(r) return ("前回と同じ一覧（%d件）なので書き込みなし"):format(r.plugins or 0) end,
  throttled = function(_r) return "今日は送信済み" end,
  skipped = function(r) return "飛ばした（" .. tostring(r.reason) .. "）" end,
  error = function(r) return "失敗（" .. tostring(r.reason) .. "）" end,
}

local FIRST_RUN_MESSAGE = "初回設定がまだです。小窓（TUKONYA_Team Plugin Checker）の設定タブで" ..
  "共有フォルダとメンバーIDを入れてください。"

local function main()
  local deps = tpc_bootstrap.build_deps(SB_SENDNOW_LOG)
  local store = tpc_store.new(deps)
  local config = tpc_bootstrap.new_config(store, SB_SENDNOW_LOG)

  -- 起動時（TPC_QUIET）は、画面に何も出さない約束なので一切聞かない。
  -- 未設定のプロファイルは黙って飛ばし、ログにだけ残す（判断5: 起動時の通知は出さない）。
  local quiet = (TPC_QUIET == true)
  local current = config:current()

  -- 手で実行して、今のプロファイルが未設定: 案内を1つ出して止める（ここでは聞かない）
  if not quiet and not config:profile_complete(current) then
    SB_SENDNOW_LOG(("[%s] 初回設定がまだなので止めた（手で実行）"):format(current))
    SB_RESULT = { aborted = true }
    reaper.MB(FIRST_RUN_MESSAGE, "Team Plugin Checker: 今すぐ更新", 0)
    return
  end

  local inv_cache = nil
  local ctx = {
    store = store,
    deps = deps,
    today = deps.now_iso():sub(1, 10),
    force = (TPC_FORCE == true),
    inventory = function()
      if not inv_cache then
        local entries = collect_entries()
        inv_cache = tpc_collector.build_inventory(entries, { ini_vst = read_vst_ini_text(deps) })
      end
      return inv_cache
    end,
  }

  local results = {}
  for _, name in ipairs(config:profiles()) do
    local r
    if not config:profile_complete(name) then
      SB_SENDNOW_LOG(("[%s] 初回設定がまだなので飛ばした（小窓の設定タブで設定してください）"):format(name))
      r = { name = name, status = "skipped", reason = "初回設定がまだ" }
    else
      local ok, res = pcall(send_profile, name, config:for_profile(name), ctx)
      r = ok and res or { name = name, status = "error", reason = tostring(res) }
      if not ok then SB_SENDNOW_LOG(("[%s] エラー: %s"):format(name, tostring(res))) end
    end
    results[#results + 1] = r
  end
  SB_RESULT = { profiles = results }

  -- 小窓は最後の1行を結果として見せるので、全体のまとめを最後に1行残す
  local parts = {}
  for _, r in ipairs(results) do parts[#parts + 1] = r.name .. ": " .. STATUS_TEXT[r.status](r) end
  SB_SENDNOW_LOG("今すぐ更新のまとめ: " .. table.concat(parts, " / "))
end

SB_RESULT = nil
local ok, err = pcall(main)
if not ok then
  SB_SENDNOW_LOG("エラー: " .. tostring(err))
  SB_RESULT = { error = tostring(err) }
end

-- 手で実行したときだけ結果を1つのダイアログで見せる（起動時は TPC_QUIET = true で黙る）
if TPC_QUIET ~= true and not (SB_RESULT and SB_RESULT.aborted) then
  local r = SB_RESULT or {}
  local msg
  if r.error then
    msg = "失敗しました。\n\n" .. r.error .. "\n\nログ: " .. LOG_PATH
  else
    local lines = {}
    for _, pr in ipairs(r.profiles or {}) do
      lines[#lines + 1] = pr.name .. ": " .. STATUS_TEXT[pr.status](pr)
    end
    if #lines == 0 then lines[1] = "送り先のプロファイルがありません。" end
    msg = table.concat(lines, "\n") .. "\n\nログ: " .. LOG_PATH
  end
  reaper.MB(msg, "Team Plugin Checker: 今すぐ更新", 0)
end
