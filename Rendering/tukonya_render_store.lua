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
  -- v2.10.0: 保存してあった名前が古い既定とまったく同じなら、新しい既定（$renderno 入り）へ移す
  wide = S.migrate_run_patterns(tab, wide)
  overlay(wide, "wide")

  local proj, perr = M.load_project(tab, api)
  if perr then
    warns[#warns + 1] = "この曲の記憶が壊れていて読めなかったので、使いませんでした（次に書き出すと保存し直します）。"
  end
  if tab == "mastering" then proj = S.migrate_mastering(proj) end
  proj = S.migrate_run_patterns(tab, proj)
  overlay(proj, "project")

  -- v2.8.0: 『24bit Dither』／『16bit Dither』の名前は全タブ共通になった。このタブの記憶（全体の既定・この曲）の
  -- どちらにも無ければ、Mastering の記憶（全体の既定 → この曲の順に強く）に残っている値を引き継ぐ。
  if tab ~= "mastering" then
    local want = {}
    for _, k in ipairs(keys) do
      for _, sk in ipairs(S.SHARED_DITHER_KEYS) do if k == sk then want[k] = true end end
    end
    if next(want) then
      local own = {}
      for k in pairs(want) do
        if (type(wide) == "table" and wide[k] ~= nil) or (type(proj) == "table" and proj[k] ~= nil) then own[k] = true end
      end
      local mw = M.load_wide("mastering", api)
      local mp = M.load_project("mastering", api)
      for _, layer in ipairs({ { mw, "wide" }, { mp, "project" } }) do
        local got = S.inherit_shared_dither(nil, layer[1])
        for k, v in pairs(got) do
          if want[k] and not own[k] then out[k] = v; src[k] = layer[2] end
        end
      end
    end
  end

  -- 値がおかしければ初期値へ戻す（記憶が古い版で書かれていた場合など）
  local merged, mw = S.merge(tab, out)
  for _, w in ipairs(mw or {}) do warns[#warns + 1] = w end
  local clean = {}
  for _, k in ipairs(keys) do clean[k] = merged[k] end
  return clean, src, warns
end

-- ---------------------------------------------------------------- 書き出し番号（v2.10.0）
-- 2mix Render と 2mix Preview が同じ数を使う（この曲で書き出しに成功した回数）。
-- 2か所に控える: ①この曲（ProjExtState。.RPP と一緒に保存される） ②REAPER全体（ExtState。保存せず閉じても戻らない）。
--   ①の値は「プロジェクトのファイル名」と一緒に持つ。名前が変わった（別名で保存した）ら、そのファイル名の数ではない
--   ので無視する（＝01 から）。②は「プロジェクトの場所（フルパス）」をキーにして、ファイル名も一緒に持つ。
--   読むときは、今のファイル名と合う方の最大を取る。書くときは両方に同じ値を書く（食い違わない）。
--   未保存のプロジェクト（ファイル名が空）は①だけ（②は場所が無いので作らない）。保存して名前が付くと 01 から。
M.RUN_KEY = "run_count"
local function enc(x) return (tostring(x or ""):gsub("[|%%%c]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function path_hash(p)
  local h = 5381
  for i = 1, #p do h = (h * 33 + p:byte(i)) % 4294967296 end
  return ("%08x"):format(h)
end
function M.run_wide_key(path) return "runcount_" .. path_hash(tostring(path or "")) end

-- いま開いているプロジェクトの「ファイル名」と「場所」。戻り値: { name = ファイル名, path = フルパス }（未保存は両方 ""）
function M.run_context(api)
  api = api_of(api)
  local path = ""
  if api.EnumProjects then
    local _, fn = api.EnumProjects(-1, "")
    path = tostring(fn or "")
  end
  local name = path:gsub("\\", "/"):match("([^/]*)$") or ""
  if name == "" and api.GetProjectName then
    local nm = api.GetProjectName(0, "")
    if type(nm) == "string" then name = nm end
  end
  return { name = name, path = path }
end

-- 戻り値: 今の番号（これまでの成功回数。0 なら未実行）, ctx, { proj = 数/nil, wide = 数/nil }
function M.run_peek(api)
  api = api_of(api)
  local ctx = M.run_context(api)
  local best, seen = 0, { proj = nil, wide = nil }
  local ok, text = api.GetProjExtState(0, M.SECTION, M.RUN_KEY)
  if ok and ok ~= 0 and type(text) == "string" then
    local n, nm = text:match("^(%d+)|(.*)$")
    if n and nm == enc(ctx.name) then seen.proj = tonumber(n); best = math.max(best, seen.proj) end
  end
  if ctx.path ~= "" then
    local v = api.GetExtState(M.SECTION, M.run_wide_key(ctx.path))
    if type(v) == "string" and v ~= "" then
      local n, nm, pth = v:match("^(%d+)|([^|]*)|(.*)$")
      if n and nm == enc(ctx.name) and pth == enc(ctx.path) then seen.wide = tonumber(n); best = math.max(best, seen.wide) end
    end
  end
  return best, ctx, seen
end

-- 書き出しに成功した回の番号 n を確定する（両方に同じ値を書く）。戻り値: ctx
function M.run_commit(n, api)
  api = api_of(api)
  local ctx = M.run_context(api)
  n = math.floor(tonumber(n) or 0)
  api.SetProjExtState(0, M.SECTION, M.RUN_KEY, ("%d|%s"):format(n, enc(ctx.name)))
  if ctx.path ~= "" then
    api.SetExtState(M.SECTION, M.run_wide_key(ctx.path), ("%d|%s|%s"):format(n, enc(ctx.name), enc(ctx.path)), true)
  end
  return ctx
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

-- この曲で「混じる可能性」の確認画面を飛ばすか（v2.9.0、Para + 2mix）。
-- ui には入れない: ui は「既定として保存」で REAPER 全体の既定にも写るので、
-- 「聞かない」が全部の曲に広がってしまう。曲ごとの目印としてだけ持つ。
M.BLEED_SKIP_KEY = "bleed_skip_para"
function M.load_bleed_skip(api)
  api = api_of(api)
  local ok, text = api.GetProjExtState(0, M.SECTION, M.BLEED_SKIP_KEY)
  if not ok or ok == 0 then return false end
  return tostring(text) == "1"
end
function M.save_bleed_skip(on, api)
  api = api_of(api)
  api.SetProjExtState(0, M.SECTION, M.BLEED_SKIP_KEY, on and "1" or "")
end
function M.clear_bleed_skip(api) M.save_bleed_skip(false, api) end

-- 窓の値のうち、記憶する項目だけを抜き出す
function M.pick(values, keys)
  local t = {}
  for _, k in ipairs(keys) do
    if values[k] ~= nil then t[k] = S.deepcopy(values[k]) end
  end
  return t
end

return M
