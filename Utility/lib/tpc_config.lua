--[[
  tpc_config.lua
  Team Plugin Checker — ExtState（REAPERの設定保存）の薄いラッパー。プロファイル対応。
  section は固定で "TeamPluginChecker"。REAPER呼び出しは含まない
  （get/set関数を注入する。テストは素のテーブルを使う。実機では
  reaper.GetExtState/SetExtState(section, key, val, true) を渡す — 第4引数trueで
  永続化＝reaper-extstate.ini に残る）。

  キーの並び:
    全体      profiles（名前を "," でつないだ一覧）, current, ai_choice, startup_installed
    プロファイルごと  p.<名前>.shared_dir / member_id / display_name / last_sent_date / last_hash

  プロファイル＝「共有フォルダ＋メンバーID＋表示名」の組。get_member_id などの
  従来の名前の読み書きは「今のプロファイル」に効く。別のプロファイルを直接触るときは
  for_profile(name) で見る先を固定した写しを使う（SendNowが全プロファイルを回すのに使う）。

  旧版（区画 "ShippoBlend"）からの引き継ぎ:
    プロファイルが1つも無い状態で current() が呼ばれたとき、"default" を作り、
    旧区画に member_id と display_name があればそれを写す。共有フォルダは
    （旧 dropbox_override か、Dropboxの自動検出）＋ 区切り ＋ "Shippo Blend" が
    実在するときだけ写す。deps.store（tpc_store）が無ければフォルダは写さない。
--]]

local M = {}
M.SECTION = "TeamPluginChecker"
M.LEGACY_SECTION = "ShippoBlend"
M.LEGACY_TEAM_FOLDER = "Shippo Blend"
M.DEFAULT_PROFILE = "default"
M.PROFILE_SEP = ","

local PROFILE_KEYS = { "shared_dir", "member_id", "display_name", "last_sent_date", "last_hash" }
M.PROFILE_KEYS = PROFILE_KEYS

local AI_CHOICES = { chatgpt = true, claude = true, perplexity = true }

--- deps = { get(section, key) -> string, set(section, key, value), store = tpc_store|nil, log = fn|nil }
-- get/set が無ければインメモリのテーブルで代用する（テスト用途。区画ごとに分けて持つ）。
function M.new(deps)
  deps = deps or {}
  local self = setmetatable({}, { __index = M })
  if deps.get and deps.set then
    self.deps = deps
  else
    local store = {} -- store[section][key]
    self.deps = {
      get = function(section, key) return store[section] and store[section][key] end,
      set = function(section, key, value)
        store[section] = store[section] or {}
        store[section][key] = value
      end,
      store = deps.store,
      log = deps.log,
    }
  end
  return self
end

function M:get(key)
  local v = self.deps.get(M.SECTION, key)
  if v == nil or v == "" then return nil end
  return v
end

function M:set(key, value)
  self.deps.set(M.SECTION, key, value or "")
end

local function log(self, msg)
  if self.deps.log then pcall(self.deps.log, msg) end
end

-- ============================================================
-- 検証
-- ============================================================

--- 半角英数・アンダースコアのみ、1〜16文字。
function M.valid_member_id(id)
  return type(id) == "string" and id:match("^[a-z0-9_]+$") ~= nil and #id >= 1 and #id <= 16
end

--- プロファイル名: 半角英数・アンダースコア・ハイフン、1〜32文字。
function M.valid_profile_name(name)
  return type(name) == "string" and name:match("^[A-Za-z0-9_%-]+$") ~= nil and #name >= 1 and #name <= 32
end

-- ============================================================
-- プロファイル一覧と「今のプロファイル」
-- ============================================================

local function pkey(name, key)
  return "p." .. name .. "." .. key
end
M.profile_key = pkey

--- 保存されている順のプロファイル名一覧（自動作成はしない）。
function M:profiles()
  local out, seen = {}, {}
  local raw = self:get("profiles") or ""
  for raw_name in raw:gmatch("[^,]+") do
    local name = raw_name:gsub("^%s+", ""):gsub("%s+$", "")
    if M.valid_profile_name(name) and not seen[name] then
      out[#out + 1] = name
      seen[name] = true
    end
  end
  return out
end

function M:has_profile(name)
  for _, n in ipairs(self:profiles()) do
    if n == name then return true end
  end
  return false
end

local function save_profiles(self, list)
  self:set("profiles", table.concat(list, M.PROFILE_SEP))
end

--- 今のプロファイル名。1つも無ければ "default" を作る（旧版の設定があれば引き継ぐ）。
function M:current()
  local list = self:profiles()
  if #list == 0 then
    save_profiles(self, { M.DEFAULT_PROFILE })
    self:set("current", M.DEFAULT_PROFILE)
    self:migrate_legacy(M.DEFAULT_PROFILE)
    return M.DEFAULT_PROFILE
  end
  local cur = self:get("current")
  for _, n in ipairs(list) do
    if n == cur then return cur end
  end
  self:set("current", list[1])
  return list[1]
end

function M:set_current(name)
  if not self:has_profile(name) then return false, "そのプロファイルはありません: " .. tostring(name) end
  self:set("current", name)
  return true
end

function M:add_profile(name)
  if not M.valid_profile_name(name) then
    return false, "プロファイル名は半角英数字・アンダースコア・ハイフン、1〜32文字"
  end
  self:current() -- 一覧が空なら先に default を作る
  local list = self:profiles()
  for _, n in ipairs(list) do
    if n == name then return false, "同じ名前のプロファイルがあります: " .. name end
  end
  list[#list + 1] = name
  save_profiles(self, list)
  return true
end

function M:remove_profile(name)
  local list = self:profiles()
  local idx = nil
  for i, n in ipairs(list) do
    if n == name then idx = i end
  end
  if not idx then return false, "そのプロファイルはありません: " .. tostring(name) end
  if #list <= 1 then return false, "最後の1つは消せません" end
  local was_current = (self:get("current") == name)
  table.remove(list, idx)
  save_profiles(self, list)
  for _, key in ipairs(PROFILE_KEYS) do
    self:set(pkey(name, key), "")
  end
  if was_current then self:set("current", list[1]) end
  return true
end

--- 共有フォルダ・メンバーID・表示名が全部そろっているか。
function M:profile_complete(name)
  name = name or self:current()
  local function has(key)
    local v = self:get(pkey(name, key))
    return v ~= nil
  end
  return has("shared_dir") and has("member_id") and has("display_name")
end

--- 見る先のプロファイルを固定した写し。存在しない名前なら nil。
function M:for_profile(name)
  if not self:has_profile(name) then return nil end
  local view = setmetatable({ deps = self.deps, _profile = name }, { __index = M })
  return view
end

--- このインスタンスが読み書きするプロファイル名。
function M:profile_name()
  return self._profile or self:current()
end

function M:pget(key)
  return self:get(pkey(self:profile_name(), key))
end

function M:pset(key, value)
  self:set(pkey(self:profile_name(), key), value)
end

-- ============================================================
-- 各項目の get/set（今のプロファイル、または for_profile で固定した先）
-- ============================================================

function M:get_member_id() return self:pget("member_id") end

--- 検証NGなら書き込まず false, err を返す。
function M:set_member_id(id)
  if not M.valid_member_id(id) then
    return false, "member_idは半角英数字とアンダースコアのみ、1〜16文字"
  end
  self:pset("member_id", id)
  return true
end

function M:get_display_name() return self:pget("display_name") end
function M:set_display_name(name) self:pset("display_name", name) end

function M:get_shared_dir() return self:pget("shared_dir") end
function M:set_shared_dir(path)
  -- 貼り付けの引用符・空白・末尾区切りを落としてから保存する（入口が複数あるのでここで必ず通す）
  self:pset("shared_dir", require("tpc_store").normalize_pasted_path(path))
end

function M:get_last_sent_date() return self:pget("last_sent_date") end
function M:set_last_sent_date(date) self:pset("last_sent_date", date) end

function M:get_last_hash() return self:pget("last_hash") end
function M:set_last_hash(hash) self:pset("last_hash", hash) end

-- 以下は全体の設定（プロファイルに依らない）

function M:get_ai_choice() return self:get("ai_choice") or "chatgpt" end

function M:set_ai_choice(choice)
  if not AI_CHOICES[choice] then
    return false, "ai_choiceは chatgpt|claude|perplexity のいずれか"
  end
  self:set("ai_choice", choice)
  return true
end

function M:get_startup_installed()
  return self:get("startup_installed") == "1"
end

function M:set_startup_installed(installed)
  self:set("startup_installed", installed and "1" or "0")
end

--- 一度に全部読む（無ければnil）。UIの設定タブ・開発用の表示向け。
function M:read_all()
  local name = self:profile_name()
  local out = {
    profiles = self:profiles(),
    current = self:current(),
    profile_name = name,
    ai_choice = self:get("ai_choice"),
    startup_installed = self:get("startup_installed"),
    profile = {},
  }
  for _, key in ipairs(PROFILE_KEYS) do
    out.profile[key] = self:get(pkey(name, key))
  end
  return out
end

-- ============================================================
-- 旧版（ShippoBlend）の設定の引き継ぎ
-- ============================================================

--- @return true（何か写した）/ false
function M:migrate_legacy(name)
  local function lget(key)
    local v = self.deps.get(M.LEGACY_SECTION, key)
    if v == nil or v == "" then return nil end
    return v
  end
  local member_id = lget("member_id")
  local display_name = lget("display_name")
  if not member_id or not display_name or not M.valid_member_id(member_id) then
    return false
  end
  self:set(pkey(name, "member_id"), member_id)
  self:set(pkey(name, "display_name"), display_name)

  local store = self.deps.store
  local base, how = nil, nil
  if store then
    local override = lget("dropbox_override")
    if override then
      base, how = store.normalize_pasted_path(override), "旧設定の手入力"
    else
      local path = store:suggest_shared_dir()
      if path then base, how = path, "Dropboxの自動検出" end
    end
  end
  local dir = nil
  if base and base ~= "" then
    local candidate = base .. store:sep() .. M.LEGACY_TEAM_FOLDER
    if store:path_exists(candidate) then dir = candidate end
    if dir then
      self:set(pkey(name, "shared_dir"), dir)
      log(self, ("旧設定を引き継いだ: member=%s 共有フォルダ=%s（%s）"):format(member_id, dir, how))
    else
      log(self, ("旧設定を引き継いだ: member=%s。共有フォルダ候補が見つからない: %s（%s）")
        :format(member_id, candidate, how))
    end
  else
    log(self, ("旧設定を引き継いだ: member=%s。共有フォルダは未設定のまま"):format(member_id))
  end
  return true
end

return M
