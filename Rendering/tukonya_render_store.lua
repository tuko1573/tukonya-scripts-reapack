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
  if werr then
    warns[#warns + 1] = "保存してあった REAPER全体の既定が壊れていて読めなかったので、使いませんでした。窓で「既定として保存」をもう一度押してください。"
  end
  -- Mastering: v2.4.0 までの出力の項目（OUT_WAV など）を、出力の一覧 OUTPUTS に直してから重ねる
  if tab == "mastering" then wide = S.migrate_mastering(wide) end
  overlay(wide, "wide")

  local proj, perr = M.load_project(tab, api)
  if perr then
    warns[#warns + 1] = "この曲の記憶が壊れていて読めなかったので、使いませんでした（次に書き出すと保存し直します）。"
  end
  if tab == "mastering" then proj = S.migrate_mastering(proj) end
  overlay(proj, "project")

  -- 値がおかしければ初期値へ戻す（記憶が古い版で書かれていた場合など）
  local merged, mw = S.merge(tab, out)
  for _, w in ipairs(mw or {}) do warns[#warns + 1] = w end
  local clean = {}
  for _, k in ipairs(keys) do clean[k] = merged[k] end
  return clean, src, warns
end

-- ---------------------------------------------------------------- 曲目情報（Mastering）
-- 曲目情報（CD-TEXT のもと）とシートのURLは、タブの設定とは別の場所に置く。
-- ProjExtState なので .RPP と一緒に保存される（別のプロジェクトへは持ち越さない）。
--   meta = { album = { title, performer, songwriter, composer, arranger, ean },
--            tracks = { { no, title, performer, songwriter, composer, arranger, isrc }, ... } }
M.META_SECTION = "TUKONYA_RENDER_MASTERING"
M.META_KEY     = "metadata"
M.URL_KEY      = "sheet_url"

function M.empty_meta()
  return { album = { title = "", performer = "", songwriter = "", composer = "", arranger = "", ean = "" },
           tracks = {} }
end

-- 戻り値: meta（無ければ空の形）, 読めなかったときの理由
function M.load_meta(api)
  api = api_of(api)
  local ok, text = api.GetProjExtState(0, M.META_SECTION, M.META_KEY)
  if not ok or ok == 0 or text == "" then return M.empty_meta() end
  local t, err = parse(text)
  if type(t) ~= "table" then return M.empty_meta(), err end
  local e = M.empty_meta()
  if type(t.album) ~= "table" then t.album = e.album end
  for k, v in pairs(e.album) do if type(t.album[k]) ~= "string" then t.album[k] = v end end
  if type(t.tracks) ~= "table" then t.tracks = {} end
  return t
end

function M.save_meta(meta, api)
  api = api_of(api)
  api.SetProjExtState(0, M.META_SECTION, M.META_KEY, S.serialize(meta or M.empty_meta()))
end

function M.load_sheet_url(api)
  api = api_of(api)
  local ok, text = api.GetProjExtState(0, M.META_SECTION, M.URL_KEY)
  if not ok or ok == 0 then return "" end
  return text or ""
end

function M.save_sheet_url(url, api)
  api = api_of(api)
  api.SetProjExtState(0, M.META_SECTION, M.URL_KEY, tostring(url or ""))
end

-- この曲で最後に選んだタブ（v2.7.3）。無ければ ""。
M.LAST_TAB_KEY = "last_tab"
function M.load_last_tab(api)
  api = api_of(api)
  local ok, text = api.GetProjExtState(0, M.SECTION, M.LAST_TAB_KEY)
  if not ok or ok == 0 then return "" end
  return tostring(text or "")
end
function M.save_last_tab(tab, api)
  api = api_of(api)
  api.SetProjExtState(0, M.SECTION, M.LAST_TAB_KEY, tostring(tab or ""))
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
