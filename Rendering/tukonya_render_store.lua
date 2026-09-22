--[[
  tukonya_render_store.lua  （TUKONYA RENDER / Phase 2）
  ===========================================================================
  設定の記憶（判断3の2段）。

    強い順に  この曲の記憶（ProjExtState） ＞ REAPER全体の既定（ExtState）
              ＞ 開いているプロジェクトから読み取った値 ＞ コードの初期値

  ・この曲の記憶 … 「書き出し」を押すたびに自動で保存する
  ・REAPER全体の既定 … 「既定として保存」を押したときだけ保存する
  ・「既定に戻す」 … この曲の記憶だけを消す（REAPER全体の既定は消さない）

  reaper.* は引数 api で受け取る（既定は本物の reaper）。
  こうすると REAPER を起動しない素のLuaでも試験できる。
  ===========================================================================
--]]

local DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local S = dofile(DIR .. "tukonya_render_settings.lua")

local M = { SECTION = "TUKONYA_RENDER" }

function M.wide_key(tab)    return "defaults_" .. tostring(tab) end
function M.project_key(tab) return "ui_" .. tostring(tab) end

local function api_of(api) return api or reaper end

-- ---------------------------------------------------------------- 読み書き
-- 文字列を表に戻す。壊れていたら nil と理由。
local function parse(text)
  if type(text) ~= "string" or text == "" then return nil end
  local t, err = S.deserialize(text)
  if not t then return nil, err end
  return t
end

-- REAPER全体の既定（この機械のREAPER全部で共通）
function M.load_wide(tab, api)
  api = api_of(api)
  return parse(api.GetExtState(M.SECTION, M.wide_key(tab)))
end

function M.save_wide(tab, values, api)
  api = api_of(api)
  api.SetExtState(M.SECTION, M.wide_key(tab), S.serialize(values), true)
end

function M.clear_wide(tab, api)
  api = api_of(api)
  api.DeleteExtState(M.SECTION, M.wide_key(tab), true)
end

-- この曲（プロジェクトファイル）の記憶
function M.load_project(tab, api)
  api = api_of(api)
  local ok, text = api.GetProjExtState(0, M.SECTION, M.project_key(tab))
  if not ok or ok == 0 then return nil end
  return parse(text)
end

function M.save_project(tab, values, api)
  api = api_of(api)
  api.SetProjExtState(0, M.SECTION, M.project_key(tab), S.serialize(values))
end

function M.clear_project(tab, api)
  api = api_of(api)
  api.SetProjExtState(0, M.SECTION, M.project_key(tab), "")
end

-- ---------------------------------------------------------------- 重ね方
-- keys … 記憶する項目の一覧（窓に並んでいる項目だけ。窓に無い項目は記憶しない）
-- 戻り値: 値の表, どこから来たかの表（"code"/"detect"/"wide"/"project"）, 警告の一覧
function M.resolve(tab, keys, detected, api)
  local base = S.defaults(tab)
  local out, src, warns = {}, {}, {}
  for _, k in ipairs(keys) do
    out[k] = S.deepcopy(base[k])
    src[k] = "code"
  end
  local function overlay(t, tag)
    if type(t) ~= "table" then return end
    for _, k in ipairs(keys) do
      if t[k] ~= nil then out[k] = S.deepcopy(t[k]); src[k] = tag end
    end
  end
  overlay(detected, "detect")

  local wide, werr = M.load_wide(tab, api)
  if werr then warns[#warns + 1] = "REAPER全体の既定を読めませんでした: " .. tostring(werr) end
  overlay(wide, "wide")

  local proj, perr = M.load_project(tab, api)
  if perr then warns[#warns + 1] = "この曲の記憶を読めませんでした: " .. tostring(perr) end
  overlay(proj, "project")

  -- 値がおかしければ初期値へ戻す（記憶が古い版で書かれていた場合など）
  local merged, mw = S.merge(tab, out)
  for _, w in ipairs(mw or {}) do warns[#warns + 1] = w end
  local clean = {}
  for _, k in ipairs(keys) do clean[k] = merged[k] end
  return clean, src, warns
end

-- 窓の値のうち、記憶する項目だけを抜き出す
function M.pick(values, keys)
  local t = {}
  for _, k in ipairs(keys) do
    if values[k] ~= nil then t[k] = S.deepcopy(values[k]) end
  end
  return t
end

return M
