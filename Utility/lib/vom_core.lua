--[[
  vom_core.lua
  VST3 Only Master — REAPERを呼ばない純Luaの判断部分。
  tests/test_core.lua で素のLuaから検証できる。

  やること:
    - MASTERのFX一覧（{guid, name, fx_type}）の中から「新しく入ったVST3以外」を選ぶ
    - 同じプラグインのVST3版を、インストール済みFX一覧から探す
    - 「このまま」にしたGUIDの覚え書きを文字列と相互変換する
--]]

local N = require("vom_normalize")

local M = {}

M.VERSION = "1.0.0"

-- 例外: 名前にこれを含むものは黙って通す（ReaInsert はハード往復用でVST3版が無い）
M.EXEMPT_NAME_PATTERNS = { "ReaInsert" }

--- fx_type が VST3 系（"VST3" / "VST3i"）か
function M.is_vst3_type(fx_type)
  return type(fx_type) == "string" and fx_type:match("^VST3") ~= nil
end

--- このFXは警告の対象か（VST3以外・コンテナ以外・例外名以外）
-- @param fx {name=, fx_type=}
function M.is_offender(fx)
  if not fx or type(fx.name) ~= "string" then return false end
  if M.is_vst3_type(fx.fx_type) then return false end
  if fx.fx_type == "Container" then return false end
  for _, pat in ipairs(M.EXEMPT_NAME_PATTERNS) do
    if fx.name:find(pat, 1, true) then return false end
  end
  return true
end

--- 前回見た集合 known（guid→true）に無い、警告対象のFXを返す。known は更新される。
-- @param chain  {{guid=, name=, fx_type=}, ...}（チェーン順）
-- @param known  guid→true
-- @param ignored guid→true（「このまま」にしたもの）
-- @return list of {index=, guid=, name=, fx_type=}
function M.find_new_offenders(chain, known, ignored)
  local out = {}
  for i, fx in ipairs(chain) do
    if fx.guid and not known[fx.guid] then
      known[fx.guid] = true
      if not (ignored and ignored[fx.guid]) and M.is_offender(fx) then
        out[#out + 1] = { index = i - 1, guid = fx.guid, name = fx.name, fx_type = fx.fx_type }
      end
    end
  end
  return out
end

--- known を chain の全GUIDで作り直す（起動時・プロジェクト切替時。何も聞かない）
function M.baseline(chain, known)
  for _, fx in ipairs(chain) do
    if fx.guid then known[fx.guid] = true end
  end
  return known
end

--- インストール済みFX一覧から、fx_name（例 "CLAP: Pro-Q 4 (FabFilter)"）と同じ物のVST3版を探す。
-- 厳密一致（名前＋メーカー）を優先し、無ければ緩い一致（名前のみ）。
-- @param fx_name   MASTER上のFXの表示名
-- @param installed {{name=, ident=}, ...}（EnumInstalledFX の nameOut/identOut）
-- @return candidates {{name=, ident=}, ...}, strictness("strict"|"loose"|"none")
function M.find_vst3_candidates(fx_name, installed)
  local parsed = N.parse(fx_name)
  if not parsed then
    -- 接頭辞が無い（JSの表示名など）。名前だけで緩く探す。
    parsed = { fmt = "?", instrument = false, name = fx_name or "", vendor = "" }
  end
  -- 厳密 = 名前＋メーカー。緩い = 名前だけ（メーカー表記の揺れを許す）
  local function loose_of(pp) return (N.norm_name_for_key(pp.name, pp.vendor):gsub(" ", "")) end
  local want_strict = N.key(parsed)
  local want_loose  = loose_of(parsed)
  local strict, loose = {}, {}
  local seen = {}
  for _, it in ipairs(installed or {}) do
    local p = N.parse(it.name or "")
    if p and p.fmt == "VST3" and not seen[it.name] then
      seen[it.name] = true
      if N.key(p) == want_strict then
        strict[#strict + 1] = { name = it.name, ident = it.ident }
      elseif loose_of(p) == want_loose then
        loose[#loose + 1] = { name = it.name, ident = it.ident }
      end
    end
  end
  if #strict > 0 then return strict, "strict" end
  if #loose > 0 then return loose, "loose" end
  return {}, "none"
end

-- ============================================================
-- 「このまま」の覚え書き（ExtState に1行で持つ）
-- ============================================================

function M.decode_ignored(s)
  local t = {}
  for g in tostring(s or ""):gmatch("[^;]+") do
    if g ~= "" then t[g] = true end
  end
  return t
end

--- 覚え書きに1つ足す。古い順に並び、cap を超えたら古い方から落とす（他のプロジェクトの分も残す）。
-- @return new_string
function M.add_ignored(s, guid, cap)
  cap = cap or 300
  local list = {}
  for g in tostring(s or ""):gmatch("[^;]+") do
    if g ~= "" and g ~= guid then list[#list + 1] = g end
  end
  list[#list + 1] = guid
  while #list > cap do table.remove(list, 1) end
  return table.concat(list, ";")
end

return M
