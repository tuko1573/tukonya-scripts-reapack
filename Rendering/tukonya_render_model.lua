--[[
  tukonya_render_model.lua  （TUKONYA RENDER / Phase 2）
  ===========================================================================
  窓の「中身」。ImGui は一切呼ばない。窓（TUKONYA_Render.lua）はこの表を読んで
  並べるだけで、「書き出し」を押したときに呼ぶのもここの M.run。
  無人の突き合わせ試験も同じ M.run を通るので、窓を開かずに同じ道を試せる。

  ・M.ROWS … 画面に並べる項目の表（判断12）。並べ替え・追加・削除はこの表の編集だけ。
  ・M.detect … 開いているプロジェクトから読み取る（書き込みはしない）。
  ・M.load … コードの初期値 → 読み取った値 → REAPER全体の既定 → この曲の記憶、の順に重ねる。
  ・M.run … この曲の記憶を保存してから、Phase 1 の骨組み（core）へ渡す。
  ===========================================================================
--]]

local DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local S     = dofile(DIR .. "tukonya_render_settings.lua")
local Store = dofile(DIR .. "tukonya_render_store.lua")

local M = { VERSION = "0.2.0", S = S, Store = Store }

-- 骨組み（core）は必要になったときに一度だけ読む（Mastering の読み取りと、読むだけの道具が使う）
local CORE
local function core()
  if not CORE then CORE = dofile(DIR .. "tukonya_render_core.lua") end
  return CORE
end

M.TAB_LABELS = {
  { tab = "mix2",    label = "2mix Render",    ready = true },
  { tab = "preview", label = "2mix Preview",   ready = true },
  { tab = "para",    label = "Para + 2mix",    ready = true },
  { tab = "hwprint", label = "Hardware Print", ready = true },
  { tab = "mastering", label = "Mastering",     ready = true },
}

-- ===========================================================================
-- 画面に並べる項目（判断12: この表が窓の下書きそのもの）
--   kind … "path"（欄＋参照ボタン）/ "text" / "combo" / "check" / "info"（読み取り専用）
--   info … その項目の下に出す、読み取り専用の1行（M.notes が作る）
-- ===========================================================================
-- ビット深度の選択肢は、REAPERの書き出し画面と同じ並び（設定の型が持っている表から作る）
M.WAV_OPTIONS = {}
for _, f in ipairs(S.WAV_FORMATS) do M.WAV_OPTIONS[#M.WAV_OPTIONS + 1] = { f.key, f.label } end

-- サンプルレート。0 は「プロジェクトと同じ」（REAPERの RENDER_SRATE=0。
-- 2026-09-21 に MacBook Pro で、44.1kHz のプロジェクトを 0 で書き出すと
-- 44100 のWAVが出ることを確かめた）。
M.SRATE_OPTIONS = {
  { 0, "プロジェクトと同じ" },
  { 44100, "44100 Hz" }, { 48000, "48000 Hz" }, { 88200, "88200 Hz" },
  { 96000, "96000 Hz" }, { 176400, "176400 Hz" }, { 192000, "192000 Hz" },
}
-- Mastering の FX処理のサンプルレート（v2.6.3）。0 は書き出しのときにスクリプトが実際の数に直す（0 のままでは書かない）
M.MST_PROC_SRATE_OPTIONS = { { 0, "プロジェクトの動作レート（自動）" } }
for i = 2, #M.SRATE_OPTIONS do M.MST_PROC_SRATE_OPTIONS[#M.MST_PROC_SRATE_OPTIONS + 1] = M.SRATE_OPTIONS[i] end

-- リサンプルモード（サンプルレートを変えるときの変換のやり方）。
-- 並びと言葉は REAPER 自身に聞く（Resample_EnumModes）。REAPERの外（素のLuaの試験）では
-- 下の控えを使う。控えは 2026-09-21 に MacBook Pro / REAPER 7.80 で読み出したもの。
M.RESAMPLE_FALLBACK = {
  { 0,  "シンク補間: 64ポイント（中品質）" },
  { 1,  "リニア補間（低品質）" },
  { 2,  "ポイントサンプリング（最低品質、レトロ）" },
  { 3,  "シンク補間: 192ポイント" },
  { 4,  "シンク補間: 384ポイント" },
  { 5,  "リニア補間 + IIR" },
  { 6,  "リニア補間 + IIRx2" },
  { 7,  "シンク補間: 16ポイント" },
  { 8,  "シンク補間: 512ポイント（遅い）" },
  { 9,  "シンク補間: 768ポイント（非常に遅い）" },
  { 10, "r8brain free（最高品質、速い）" },
}

local function resample_options()
  if type(reaper) == "table" and reaper.Resample_EnumModes then
    local t = {}
    for i = 0, 63 do
      local nm = reaper.Resample_EnumModes(i)
      if not nm or nm == "" then break end
      t[#t + 1] = { i, nm }
    end
    if #t > 0 then return t end
  end
  return M.RESAMPLE_FALLBACK
end
M.RESAMPLE_OPTIONS = resample_options()

M.ROWS = {
  para = {
    { kind = "section", label = "出力", rows = {
      { kind = "path",  key = "OUTPUT_DIR",    label = "ディレクトリ:",
        hint = "空の場合、プロジェクトパスを使います" },
      { kind = "text",  key = "DELIVERY_BASE", label = "ファイル名:",
        hint = "REAPER標準のワイルドカードが使用可能です" },
      { kind = "info",  note = "dest2mix",     label = "2mix:", grey = true },
      { kind = "info",  note = "destpara",     label = "para:", grey = true },
    } },

    { kind = "section", label = "オプション", rows = {
      { kind = "combo", key = "RANGE_MODE",  label = "範囲", note = "range",
        options = { { "bus_items", "2MIXBUSのアイテム" }, { "timesel", "選択範囲" },
                    { "project", "プロジェクト全体" } } },
      { kind = "combo", key = "DITHER_MODE", label = "ディザー", note = "dither",
        options = { { "track", "Ditherトラック" }, { "reaper", "REAPERのディザー" },
                    { "none", "なし" } } },
      { kind = "info",  note = "hardware",   label = "Master ReaInsert" },
    } },

    { kind = "section", label = "出力設定", rows = {
      { kind = "combo", key = "MASTER_BITS", label = "2mixのビット深度", options = M.WAV_OPTIONS },
      { kind = "combo", key = "STEM_BITS",   label = "paraのビット深度", options = M.WAV_OPTIONS },
      { kind = "combo", key = "SRATE",       label = "出力のサンプルレート", options = M.SRATE_OPTIONS },
      { kind = "combo", key = "FORMAT2",     label = "同時レンダーの形式",
        options = { { "none", "なし" }, { "aac", "AAC（.m4a）" }, { "mp3", "MP3（.mp3）" } } },
      { kind = "combo", key = "FX_SRATE",    label = "FX処理のサンプルレート", options = M.MST_PROC_SRATE_OPTIONS, note = "fx_rate" },
      { kind = "combo", key = "SONG_NAME_RULE", label = "曲名", note = "song",
        -- 「入力...」を選んだときだけ、右に文字を書く欄が出る
        extra = { key = "SONG_NAME_CUSTOM", when = "custom" },
        options = { { "strip_mix", "_mix などの稿の目印を落とす" },
                    { "project", "プロジェクト名をそのまま" },
                    { "title", "REAPERの曲名（$title）" },
                    { "custom", "入力..." } } },
      { kind = "check", key = "EXPORT_MASTER_CHAIN", label = "MASTERトラックのFXチェーンリストを書き出し" },
    } },

    { kind = "section", label = "詳細", collapsible = true, rows = {
      { kind = "check", key = "PARA_VIA_PARENT", label = "親トラックのサイドチェーンを有効にする(実験中)" },
      { kind = "check", key = "PARA_SOLO_EACH",  label = "ソロを切り替えながら書き出す(高速)" },
      { kind = "combo", key = "PARA_RANGE",      label = "paraの範囲",
        options = { { "project", "プロジェクト全体" }, { "bus_items", "2MIXBUSのアイテム" },
                    { "timesel", "選択範囲" } } },
      { kind = "combo", key = "RESAMPLE_MODE",   label = "リサンプルモード", options = M.RESAMPLE_OPTIONS },
      -- 読むだけの道具（key を持たせない＝記憶にも既定にも入れない）
      -- 「親トラックのサイドチェーンを有効にする(実験中)」を入れているときだけ出す。
      -- 中身（通り道と受け）は1本だけ選んでいるとき自動で出る（ボタンは資料の書き出しだけ）。
      { kind = "diag", id = "sidechain", label = "選択トラックのサイドチェイン状況",
        when = { key = "PARA_VIA_PARENT", value = true },
        need = "1トラック選択時のみ表示されます",
        buttons = { { id = "sc_structure", label = "サイドチェイン構成を資料で書き出す",
                      note = "意図したサイドチェーンが有効になっていない場合の参考資料として、"
                          .. "トラックやアイテムの名前を削除したデータを出力します" } } },
    } },
  },

  -- ===== 2mix Render（旧 TUKO_2Stage_HW_Master_Render）=====
  -- ファイル名は3本ぶんある。旧スクリプトの決め打ちをそのまま初期値にしてある。
  mix2 = {
    { kind = "section", label = "出力", rows = {
      { kind = "path",  key = "OUTPUT_DIR",   label = "ディレクトリ:",
        hint = "空の場合、プロジェクトパスを使います" },
      { kind = "text",  key = "PAT_NODITHER", label = "ファイル名/ディザーなし:",
        hint = "REAPER標準のワイルドカードが使用可能です", note = "dest_u" },
      -- この欄は「ディザー」の選び方で出たり消えたりする（M.visible の "dither_pattern"）
      { kind = "text",  key = "PAT_DITHERED", label = "ファイル名/ディザーあり:",
        visible = "dither_pattern",
        hint = "ディザーを通した .wav の名前", note = "dest_d" },
      -- この欄は「同時レンダーの形式」が「なし」のときは出さない（M.visible）
      { kind = "text",  key = "PAT_AAC",      label = "ファイル名/同時レンダー:",
        visible = "format2_pattern",
        hint = "同時レンダーの形式（AAC/MP3）は、この名前で出ます", note = "dest_aac" },
    } },

    { kind = "section", label = "オプション", rows = {
      { kind = "combo", key = "RANGE_MODE",  label = "範囲", note = "range",
        options = { { "bus_items", "2MIXBUSのアイテム" }, { "timesel", "選択範囲" },
                    { "project", "プロジェクト全体" } } },
      { kind = "combo", key = "DITHER_MODE", label = "ディザー", note = "dither",
        options = { { "track", "Ditherトラック" }, { "reaper", "REAPERのディザー" },
                    { "none", "なし" } } },
      { kind = "info",  note = "hardware",   label = "Master ReaInsert" },
    } },

    { kind = "section", label = "出力設定", rows = {
      { kind = "combo", key = "MASTER_BITS", label = "2mixのビット深度", options = M.WAV_OPTIONS },
      { kind = "combo", key = "SRATE",       label = "出力のサンプルレート", options = M.SRATE_OPTIONS },
      { kind = "combo", key = "FORMAT2",     label = "同時レンダーの形式",
        options = { { "none", "なし" }, { "aac", "AAC（.m4a）" }, { "mp3", "MP3（.mp3）" } } },
      { kind = "combo", key = "FX_SRATE",    label = "FX処理のサンプルレート", options = M.MST_PROC_SRATE_OPTIONS, note = "fx_rate" },
    } },

    { kind = "section", label = "詳細", collapsible = true, rows = {
      { kind = "combo", key = "RESAMPLE_MODE", label = "リサンプルモード", options = M.RESAMPLE_OPTIONS },
    } },
  },

  -- ===== 2mix Preview（旧 TUKO_2Stage_Preview_Render）=====
  preview = {
    { kind = "section", label = "出力", rows = {
      { kind = "path",  key = "OUTPUT_DIR",      label = "ディレクトリ:",
        hint = "空の場合、プロジェクトパスを使います" },
      { kind = "text",  key = "PREVIEW_PATTERN", label = "ファイル名(透かし版):",
        hint = "REAPER標準のワイルドカードが使用可能です", note = "dest_prev" },
      { kind = "check", key = "RENDER_CLEAN_TOO", label = "透かし無しの版も書き出す" },
      -- チェックを入れたときだけ出る欄
      { kind = "text",  key = "DEFAULT_PATTERN", label = "ファイル名(透かし無し):",
        when = { key = "RENDER_CLEAN_TOO", value = true },
        hint = "「透かし無しの版も書き出す」を入れたときだけ使います", note = "dest_clean" },
    } },

    { kind = "section", label = "オプション", rows = {
      { kind = "combo", key = "RANGE_MODE",  label = "範囲", note = "range",
        options = { { "bus_items", "2MIXBUSのアイテム" }, { "timesel", "選択範囲" },
                    { "project", "プロジェクト全体" } } },
      { kind = "combo", key = "DITHER_MODE", label = "ディザー", note = "dither",
        options = { { "track", "Ditherトラック" }, { "reaper", "REAPERのディザー" },
                    { "none", "なし" } } },
      { kind = "info",  note = "hardware",   label = "Master ReaInsert" },
      { kind = "info",  note = "watermark",  label = "透かし" },
    } },

    { kind = "section", label = "出力設定", rows = {
      { kind = "combo", key = "MASTER_BITS", label = "2mixのビット深度", options = M.WAV_OPTIONS },
      { kind = "combo", key = "SRATE",       label = "出力のサンプルレート", options = M.SRATE_OPTIONS },
      { kind = "combo", key = "FORMAT2",     label = "同時レンダーの形式",
        options = { { "none", "なし" }, { "aac", "AAC（.m4a）" }, { "mp3", "MP3（.mp3）" } } },
      { kind = "combo", key = "FX_SRATE",    label = "FX処理のサンプルレート", options = M.MST_PROC_SRATE_OPTIONS, note = "fx_rate" },
    } },

    { kind = "section", label = "詳細", collapsible = true, rows = {
      { kind = "combo", key = "RESAMPLE_MODE", label = "リサンプルモード", options = M.RESAMPLE_OPTIONS },
      { kind = "num",   key = "DUCK_DB",      label = "ダッキングの深さ(dB)",  step = 1.0,   fmt = "%.1f" },
      { kind = "num",   key = "DUCK_PRE",     label = "声の何秒手前で下げ切るか", step = 0.05, fmt = "%.3f" },
      { kind = "num",   key = "DUCK_FADE_IN", label = "下げるのにかける秒数",   step = 0.05, fmt = "%.3f" },
      { kind = "num",   key = "DUCK_RELEASE", label = "戻すのにかける秒数",     step = 0.05, fmt = "%.3f" },
    } },
  },

  -- ===== Mastering（計画書/計画書_mastering.md）=====
  -- 2MIXBUS 直下の曲ごとに、出力の一覧（WAV・DDP・AAC・MP3）を書き出す（v2.5.0）。
  -- 出力の一覧は kind="outputs"、曲目情報（CD-TEXT）の欄は kind="meta"（どちらも窓が専用に描く）。
  mastering = {
    { kind = "section", label = "出力", rows = {
      { kind = "path",  key = "OUTPUT_DIR",  label = "ディレクトリ:",
        hint = "空の場合、プロジェクトパスを使います" },
      { kind = "outputs", key = "OUTPUTS" },
    } },

    { kind = "section", label = "楽曲リスト", rows = {
      { kind = "info",  note = "mst_songs",  label = "トラック" },
    } },

    { kind = "section", label = "出力設定", rows = {
      { kind = "combo", key = "SRATE",       label = "FX処理のサンプルレート", options = M.MST_PROC_SRATE_OPTIONS, note = "mst_rate" },
      { kind = "check", key = "EXPORT_VERSIONS", label = "別バージョンも書き出す" },
      { kind = "check", key = "STRIP_NUMBER", label = "ファイル名と曲名から先頭の番号（「01 」など）を外す" },
      { kind = "num",   key = "GAP_FIRST",   label = "1曲目の前の無音(秒)", step = 0.5, fmt = "%.2f",
        visible = "mst_has_ddp" },
      { kind = "num",   key = "GAP_TRACKS",  label = "曲間(秒)", step = 0.5, fmt = "%.2f",
        visible = "mst_has_ddp" },
    } },

    { kind = "section", label = "曲目情報（CD-TEXT）", visible = "mst_has_ddp", rows = {
      { kind = "meta" },
    } },

    { kind = "section", label = "詳細", collapsible = true, rows = {
      { kind = "combo", key = "RESAMPLE_MODE", label = "リサンプルモード", options = M.RESAMPLE_OPTIONS },
    } },
  },

  -- ===== Hardware Print（旧 TUKO_VoComp_Render）=====
  -- 選んだアイテムが対象。範囲もディザーも使わない（そのぶん項目が少ない）。
  hwprint = {
    { kind = "section", label = "出力", rows = {
      { kind = "path",  key = "OUTPUT_DIR", label = "ディレクトリ:",
        hint = "空の場合、プロジェクトパスを使います" },
      { kind = "text",  key = "HW_PATTERN", label = "ファイル名:",
        hint = "REAPER標準のワイルドカードが使用可能です（$track はトラック名）", note = "dest_hw" },
    } },

    { kind = "section", label = "オプション", rows = {
      { kind = "info",  note = "hw_items",    label = "選んだアイテム" },
      { kind = "info",  note = "hw_reainsert", label = "Master ReaInsert" },
    } },

    { kind = "section", label = "出力設定", rows = {
      { kind = "combo", key = "MASTER_BITS", label = "ビット深度", options = M.WAV_OPTIONS },
      { kind = "combo", key = "FX_SRATE",    label = "FX処理のサンプルレート", options = M.MST_PROC_SRATE_OPTIONS, note = "fx_rate" },
    } },

    { kind = "section", label = "詳細", collapsible = true, rows = {
      { kind = "check", key = "BYPASS_MASTER_TRACK",
        label = "REAPERのマスタートラックのFXも一時的に切る" },
      { kind = "check", key = "RESET_VOL_PAN",
        label = "書き出しのあいだフェーダー／パンを素通しにする" },
      { kind = "text",  key = "RAW_TRACK_NAME",  label = "元のフォルダ名:" },
      { kind = "text",  key = "DEST_TRACK_NAME", label = "書き出し先のフォルダ名:" },
    } },
  },
}

-- 記憶する項目（窓に並んでいる項目だけ）
function M.stored_keys(tab)
  local rows = M.ROWS[tab]
  if not rows then return {} end
  local keys, seen = {}, {}
  local function add(k) if k and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  local function walk(list)
    for _, r in ipairs(list) do
      if r.rows then walk(r.rows) end
      add(r.key)
      if r.extra then add(r.extra.key) end
    end
  end
  walk(rows)
  table.sort(keys)
  return keys
end

-- ===========================================================================
-- 開いているプロジェクトから読み取る（書き込みはしない）
-- ===========================================================================
local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then return tr end
  end
  return nil
end
M.find_track_by_name = find_track_by_name

-- 2MIXBUSのアイテムの端から端。GetSet_LoopTimeRange は読むだけ（書かない）。
function M.bus_item_range(bus)
  if not bus then return nil end
  local n = reaper.CountTrackMediaItems(bus)
  if n == 0 then return nil, 0 end
  local mn, mx
  for i = 0, n - 1 do
    local it = reaper.GetTrackMediaItem(bus, i)
    local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local b = a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if not mn or a < mn then mn = a end
    if not mx or b > mx then mx = b end
  end
  return { mn, mx }, n
end

function M.is_windows()
  local os_name = reaper.GetOS() or ""
  return os_name:sub(1, 3) == "Win"
end

-- 戻り値: values（設定の値として欄に入れるもの）, d（画面に出す読み取り結果）
function M.detect(tab)
  local base = S.defaults(tab) or {}
  local d = { reasons = {} }
  local function why(s) d.reasons[#d.reasons + 1] = s end

  d.bus     = find_track_by_name(base.BUS_NAME)
  d.master  = find_track_by_name(base.MASTER_NAME)
  d.dither  = find_track_by_name(base.DITHER_TRACK_NAME)
  d.bus_range, d.bus_items = M.bus_item_range(d.bus)
  d.timesel = { reaper.GetSet_LoopTimeRange(false, false, 0, 0, false) }
  d.proj_len = reaper.GetProjectLength(0)
  d.proj_file = reaper.GetProjectName(0, "") or ""
  d.sel_tracks = reaper.CountSelectedTracks(0)
  d.track_count = reaper.CountTracks(0)
  -- 「サイドチェーンの確認」は1本だけ選んでいるときに使う。選び直したら結果を消すため
  -- GUID も控える（読むだけ。プロジェクトには書き込まない）。
  if d.sel_tracks == 1 then
    d.sel_track = reaper.GetSelectedTrack(0, 0)
    d.sel_track_guid = d.sel_track and reaper.GetTrackGUID(d.sel_track) or nil
  end
  -- 2mix Preview の透かし用トラック
  if base.PREVIEW_TRACK_NAME then
    d.preview_track = find_track_by_name(base.PREVIEW_TRACK_NAME)
    d.preview_items = d.preview_track and reaper.CountTrackMediaItems(d.preview_track) or 0
  end
  -- Hardware Print: 選んだアイテムと、そのトラックから上へたどったハードの通り道
  if tab == "hwprint" then
    d.sel_items = reaper.CountSelectedMediaItems(0)
    local seen, tracks, missing, found = {}, {}, {}, {}
    for i = 0, d.sel_items - 1 do
      local it = reaper.GetSelectedMediaItem(0, i)
      local tr = reaper.GetMediaItem_Track(it)
      local g = reaper.GetTrackGUID(tr)
      if not seen[g] then seen[g] = true; tracks[#tracks + 1] = tr end
    end
    for _, tr in ipairs(tracks) do
      local cur, hit = tr, nil
      while cur do
        for fx = 0, reaper.TrackFX_GetCount(cur) - 1 do
          local _, nm = reaper.TrackFX_GetFXName(cur, fx, "")
          if type(nm) == "string" and nm:lower():find(base.REAINSERT_MATCH, 1, true)
             and reaper.TrackFX_GetEnabled(cur, fx) then hit = cur; break end
        end
        if hit then break end
        cur = reaper.GetParentTrack(cur)
      end
      local _, nm = reaper.GetTrackName(tr)
      if hit then
        local _, hn = reaper.GetTrackName(hit)
        found[#found + 1] = hn
      else
        missing[#missing + 1] = nm
      end
    end
    d.hw_tracks, d.hw_missing, d.hw_found = tracks, missing, found
  end

  -- Mastering: 2MIXBUS 直下の曲と版、Dither の2トラック（名前は大文字小文字を区別しない）
  if tab == "mastering" then
    local okc, info = pcall(function() return core().mst_detect(base) end)
    if okc and info then
      d.mst = info
      d.bus, d.master = info.bus, info.master
    else
      d.mst = { songs = {}, notes = { { text = "曲の読み取りに失敗しました: " .. tostring(info), block = true } } }
    end
  end

  -- ハード通し: MASTERに「有効な ReaInsert」があるか
  d.reainsert = nil
  if d.master then
    local match = base.REAINSERT_MATCH
    for i = 0, reaper.TrackFX_GetCount(d.master) - 1 do
      local _, nm = reaper.TrackFX_GetFXName(d.master, i, "")
      if type(nm) == "string" and nm:lower():find(match, 1, true) then
        d.reainsert = { index = i, name = nm, enabled = reaper.TrackFX_GetEnabled(d.master, i) }
        break
      end
    end
  end
  d.hardware = (d.reainsert ~= nil) and d.reainsert.enabled or false

  local _, render_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  d.render_file = render_file or ""
  -- プロジェクトが保存されているか。保存されていれば、その .RPP があるフォルダ。
  -- 書き出し先（ディレクトリ）が空のとき、REAPERはこのフォルダへ書く
  -- （2026-09-21 に MacBook Pro で RENDER_TARGETS を読んで確かめた）。
  local _, projpath = reaper.EnumProjects(-1, "")
  projpath = tostring(projpath or "")
  d.proj_path = projpath
  d.proj_dir  = (projpath ~= "") and (projpath:match("^(.*)[/\\][^/\\]*$") or "") or ""
  d.proj_saved = (d.proj_dir ~= "")
  -- プロジェクト設定の曲名（$title）
  local _, ptitle = reaper.GetSetProjectInfo_String(0, "PROJECT_TITLE", "", false)
  d.proj_title = tostring(ptitle or "")

  local values = {}
  values.OUTPUT_DIR = d.render_file
  if d.render_file ~= "" then why("出力フォルダ: プロジェクトの書き出し先から") end
  -- ディザーの欄は、Ditherトラックが無くても「Ditherトラック」のままにする。
  -- 骨組み（core）が「Ditherトラックが無いとき」の道を持っていて、
  -- そこでのファイル名が旧スクリプトと同じになるため。ここで「なし」に倒すと、
  -- 出来るファイルの名前が旧と変わってしまう（2mix Render は $project_$date、
  -- Para + 2mix は SAMPLEMASTER が旧の名前）。「なし」はつこさんが自分で選べる。
  values.DITHER_MODE = "track"
  if tab ~= "mastering" then
  why(("ディザー: 『%s』トラックが%s → Ditherトラック%s"):format(base.DITHER_TRACK_NAME,
    d.dither and "ある" or "ない",
    d.dither and "" or "（トラックが無いので、ディザー無しの1本だけ書き出す道になる）"))
  end
  values.FORMAT2 = M.is_windows() and "mp3" or "aac"
  why("2つ目の形式: " .. (M.is_windows() and "Windows なので MP3" or "mac なので AAC"))
  why("ハード通し: " .. (d.hardware and "有効なReaInsertがある → ハードを通す"
    or (d.reainsert and "ReaInsertはあるが無効 → すべてオフライン" or "ReaInsertが無い → すべてオフライン")))
  return values, d
end

-- ===========================================================================
-- 窓を開いたときの値（判断3の重ね順）
-- ===========================================================================
-- ビット深度は、窓では名前（"pcm24" など）で扱う。
-- 昔の書き方（24 や 64 という数字）が記憶に入っていたら、ここで名前に直す。
local BITS_KEYS = { "MASTER_BITS", "STEM_BITS", "PARA_BITS" }
local function normalize_bits(ui)
  for _, k in ipairs(BITS_KEYS) do
    if ui[k] ~= nil then
      local name = S.wav_format_key(ui[k])
      if name then ui[k] = name end
    end
  end
  return ui
end
M.normalize_bits = normalize_bits

function M.load(tab, api)
  local keys = M.stored_keys(tab)
  local detected, d = M.detect(tab)
  local ui, src, warns = Store.resolve(tab, keys, detected, api)
  normalize_bits(ui)
  local st = { tab = tab, ui = ui, src = src, detect = d, warns = warns, keys = keys }
  if tab == "mastering" then
    -- 曲目情報とシートのURLは、タブの設定とは別にプロジェクトから読む
    local meta, merr = Store.load_meta(api)
    st.meta = meta
    st.sheet_url = Store.load_sheet_url(api)
    if merr then warns[#warns + 1] = "曲目情報を読めませんでした: " .. tostring(merr) end
  end
  return st
end

-- ===========================================================================
-- 画面に出す読み取り専用の文言
-- ===========================================================================
local function fmt_range(a, b) return ("%s〜%s"):format(S.fmt_time(a), S.fmt_time(b)) end

function M.song_of(st)
  local ui, d = st.ui, st.detect
  local name = S.song_name(d.proj_file, ui.SONG_NAME_RULE, S.defaults(st.tab).SONG_STRIP_WORDS,
    ui.SONG_NAME_CUSTOM)
  if name == "" then name = "untitled" end
  if ui.SONG_NAME_RULE ~= "title" then name = name:gsub("[/\\:%*%?\"<>|]", "_"):gsub("%$", "_") end
  return name
end

-- 出力先の見本。$song は曲名に、$project と $date は見えている値に置き換える。
-- 他のワイルドカードはREAPERが解くので、そのまま文字として出す。
function M.dest_preview(st)
  local ui, d = st.ui, st.detect
  local def = S.defaults(st.tab)
  local song = M.song_of(st)
  local proj = (d.proj_file or ""):gsub("\\", "/"):match("([^/]*)$") or ""
  proj = proj:gsub("%.[Rr][Pp][Pp]$", "")
  if proj == "" then proj = "無題" end
  local base = S.resolve_delivery_base(ui.DELIVERY_BASE or "", song)
  base = base:gsub("%$project", proj):gsub("%$date", os.date("%Y-%m-%d"))
  local dir = M.dest_dir(st) or M.NO_DEST
  local function join(sub)
    if base == "" then return dir .. "/" .. sub end
    return dir .. "/" .. base .. "/" .. sub
  end
  return join(def.MASTER_SUBFOLDER), join(def.MIX_SUBFOLDER)
end

-- 書き出し先の親フォルダ。
--   窓の「ディレクトリ」 → プロジェクトの書き出し先 → プロジェクトのフォルダ、の順。
-- どれも空（＝プロジェクトを一度も保存していない）ときだけ nil。
function M.dest_dir(st)
  local dir = st.ui.OUTPUT_DIR or ""
  if dir == "" then dir = st.detect.render_file or "" end
  if dir == "" then dir = st.detect.proj_dir or "" end
  dir = (dir:gsub("[/\\]+$", ""))
  if dir == "" then return nil end
  return dir
end

-- 書き出し先がまだ決まらないときに、欄の下へ出す文字
M.NO_DEST = "（プロジェクトを一度保存してください）"


-- ファイル名の見本。$song/$project/$date は見えている値に置き換え、
-- 他のワイルドカード（$track など）はREAPERが解くので、そのまま文字として出す。
function M.fill_wildcards(st, s)
  local d = st.detect
  local proj = (d.proj_file or ""):gsub("\\", "/"):match("([^/]*)$") or ""
  proj = proj:gsub("%.[Rr][Pp][Pp]$", "")
  if proj == "" then proj = "無題" end
  s = S.resolve_delivery_base(tostring(s or ""), M.song_of(st))
  return (s:gsub("%$project", proj):gsub("%$date", os.date("%Y-%m-%d")))
end

-- ひとつのファイル名パターンが、どこに何という名前で出るか
function M.pattern_note(st, key, ext)
  local dir = M.dest_dir(st) or M.NO_DEST
  return dir .. "/" .. M.fill_wildcards(st, st.ui[key]) .. (ext or ".wav")
end

-- 範囲の1行。2つ目の戻り値が false なら書き出せない。
function M.range_note(st)
  local ui, d = st.ui, st.detect
  local def = S.defaults(st.tab)
  if ui.RANGE_MODE == "bus_items" then
    if not d.bus then
      return ("『%s』トラックがありません"):format(def.BUS_NAME), false
    end
    if not d.bus_range then
      return ("『%s』にアイテムがありません"):format(def.BUS_NAME), false
    end
    return fmt_range(d.bus_range[1], d.bus_range[2]), true
  elseif ui.RANGE_MODE == "timesel" then
    local a, b = d.timesel[1], d.timesel[2]
    if (b - a) > 0.0000001 then return fmt_range(a, b), true end
    return ("タイムセレクションがありません → プロジェクト全体 %s"):format(fmt_range(0, d.proj_len)), true
  end
  return fmt_range(0, d.proj_len), true
end

function M.dither_note(st)
  local def = S.defaults(st.tab)
  if st.detect.dither then
    return ("『%s』トラック: あり"):format(def.DITHER_TRACK_NAME)
  end
  if st.ui.DITHER_MODE == "track" then
    -- トラックが無くても止めない。「ディザー＝なし」を選んだときと同じ1組を書き出す。
    return ("「%s」トラックが存在しないため、ディザーを通した.wavは出力しません。")
      :format(def.DITHER_TRACK_NAME)
  end
  return ("『%s』トラック: なし"):format(def.DITHER_TRACK_NAME)
end

function M.hardware_note(st)
  local d = st.detect
  if d.hardware then return "有効 → ハードを通します" end
  if d.reainsert then return "無効 → すべてオフライン" end
  return "なし → すべてオフライン"
end

function M.song_note(st)
  local name = M.song_of(st)
  if st.ui.SONG_NAME_RULE == "title" then
    -- $title はREAPERが解く。いま何になるかを見せる。
    local t = st.detect.proj_title or ""
    if t == "" then
      return "曲名: （プロジェクト設定の曲名が空です。$title は空文字になり、名前に何も入りません）"
    end
    return ("曲名: %s（プロジェクト設定の曲名）"):format(t)
  end
  return ("曲名: %s"):format(name)
end

-- 2mix Preview の透かし（PREVIEWONLYトラック）
function M.watermark_note(st)
  local def = S.defaults(st.tab)
  local d = st.detect
  if not d.preview_track then
    return ("『%s』トラック: なし"):format(def.PREVIEW_TRACK_NAME)
  end
  if (d.preview_items or 0) == 0 then
    return ("『%s』トラック: あり（波形が入っていません）"):format(def.PREVIEW_TRACK_NAME)
  end
  return ("『%s』トラック: あり（波形 %d 個）"):format(def.PREVIEW_TRACK_NAME, d.preview_items)
end

-- Hardware Print の「選んだアイテム」と「ハードの通り道」
function M.hw_items_note(st)
  local d = st.detect
  local n = d.sel_items or 0
  if n == 0 then return "0 個（書き出したいアイテムを選んでください）" end
  return ("%d 個 / トラック %d 本"):format(n, #(d.hw_tracks or {}))
end

function M.hw_reainsert_note(st)
  local d = st.detect
  if (d.sel_items or 0) == 0 then return "アイテムを選ぶと調べます" end
  local missing = d.hw_missing or {}
  if #missing > 0 then
    return ("見つかりません: %s（このままでは書き出せません）"):format(table.concat(missing, "、"))
  end
  local seen, names = {}, {}
  for _, n in ipairs(d.hw_found or {}) do
    if not seen[n] then seen[n] = true; names[#names + 1] = n end
  end
  return ("有効 → 『%s』を通します"):format(table.concat(names, "』『"))
end

-- ===========================================================================
-- 読むだけの道具（サイドチェーンの確認・構成の資料）
-- ===========================================================================
-- どちらもプロジェクトを書き換えない。骨組み（core）は一度だけ読んで使い回す。
M.core = core

-- ボタンを押せるか。戻り値: ok, 押せない理由（短い一言）
function M.diag_enabled(st, id)
  if id == "sc_preview" then
    if (st.detect.sel_tracks or 0) ~= 1 then return false, "1トラック選択時のみ表示されます" end
  end
  return true, nil
end

-- いまの中身を作り直す必要があるか（選んだトラックか、トラックの本数が変わったとき）。
-- 毎フレーム作り直さないための控え。
function M.sc_stale(st, cur)
  if not cur then return true end
  return cur.guid ~= st.detect.sel_track_guid or cur.ntracks ~= st.detect.track_count
end

-- 「選択トラックのSC状態を確認」。書き出さず、通り道と受けを読んで文にする。
-- 戻り値: { guid = 選んでいたトラック, lines = 読み取り専用の行 }
function M.sc_preview(st)
  local d = st.detect
  local ok, hint = M.diag_enabled(st, "sc_preview")
  if not ok then return { ntracks = st.detect.track_count, lines = { hint }, none = true } end
  local g = d.sel_track_guid
  if not st.ui.PARA_VIA_PARENT then
    return { guid = g, ntracks = d.track_count, lines = { "親トラックの遡りは無効です（P = 自分）" } }
  end
  local C = core()
  local plan, err = C.para_plan_preview(d.bus, d.master, d.sel_track)
  if not plan then return { guid = g, ntracks = d.track_count, lines = { tostring(err) } } end
  return { guid = g, ntracks = d.track_count, lines = C.sc_state_text(plan) }
end

-- 資料の置き場（実行記録と同じフォルダ。書けなければ REAPER のリソースフォルダ）
function M.structure_dirs(st)
  local def = S.defaults(st.tab)
  local dirs = {}
  local want = st.ui.LOG_DIR or def.LOG_DIR or ""
  if type(want) == "string" and want ~= "" then
    want = (want:gsub("[/\\]+$", ""))
    reaper.RecursiveCreateDirectory(want, 0)
    dirs[#dirs + 1] = want
  end
  dirs[#dirs + 1] = (tostring(reaper.GetResourcePath()):gsub("[/\\]+$", ""))
  return dirs
end

-- 「構成を資料として書き出す」。戻り値: パス / nil, 理由
function M.write_structure(st)
  local C = core()
  local cfg = S.merge(st.tab, st.ui) or S.defaults(st.tab)
  local name = "TUKONYA_structure_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
  local last
  for _, dir in ipairs(M.structure_dirs(st)) do
    local p = dir .. S.path_sep(dir) .. name
    local got, err = C.write_structure_report(p, st.detect.sel_track,
      { BUS = st.detect.bus, MASTER = st.detect.master, cfg = cfg,
        script_version = M.SCRIPT_VERSION })
    if got then return got end
    last = err
  end
  return nil, last or "資料を書き出せませんでした。"
end

-- ===========================================================================
-- 欄を出すかどうか（窓は毎フレームここを見るので、選び直せばすぐ効く）
-- ===========================================================================
--   "format2_pattern" … 同時レンダー（AAC/MP3）の名前の欄。「なし」なら出さない。
--   "dither_pattern" … ディザーを通した .wav の名前の欄。
--     「Ditherトラック」  → 『Dither』トラックがあるときだけ出す
--     「REAPERのディザー」→ いつも出す
--     「なし」            → 出さない
--   出さないときは、その .wav も書き出されない（骨組み側の決まりと同じ）。
function M.visible(st, which)
  if which == "format2_pattern" then
    -- 同時レンダー（AAC/MP3）の名前の欄。「なし」なら、そのファイル自体が出ない
    return st.ui.FORMAT2 ~= "none"
  end
  if which == "mst_has_ddp" then
    return S.outputs_have(st.ui.OUTPUTS, "ddp")
  end
  if which == "dither_pattern" then
    local mode = st.ui.DITHER_MODE
    if mode == "reaper" then return true end
    if mode == "track" then return st.detect.dither ~= nil end
    return false
  end
  return true
end

function M.note(st, which)
  if which == "range"      then return (M.range_note(st)) end
  if which == "dither"     then return M.dither_note(st) end
  if which == "hardware"   then return M.hardware_note(st) end
  if which == "song"       then return M.song_note(st) end
  if which == "dest2mix"   then local a = M.dest_preview(st); return a end
  if which == "destpara"   then local _, b = M.dest_preview(st); return b end
  if which == "dest_u"     then return M.pattern_note(st, "PAT_NODITHER") end
  if which == "dest_d"     then return M.pattern_note(st, "PAT_DITHERED") end
  if which == "dest_aac"   then
    local ext = S.format2_ext(st.ui.FORMAT2)
    if not ext then return "（同時レンダーの形式が「なし」なので出ません）" end
    return M.pattern_note(st, "PAT_AAC", ext)
  end
  if which == "dest_prev"  then return M.pattern_note(st, "PREVIEW_PATTERN") end
  if which == "dest_clean" then
    if not st.ui.RENDER_CLEAN_TOO then return "（「透かし無しの版も書き出す」を入れたときだけ出ます）" end
    return M.pattern_note(st, "DEFAULT_PATTERN")
  end
  if which == "dest_hw"      then return M.pattern_note(st, "HW_PATTERN") end
  if which == "mst_songs"    then return M.mst_songs_note(st) end
  if which == "fx_rate"      then   -- v2.7.0: 他のタブの FX処理のサンプルレート（数に直した値）
    local ok, rate, why = pcall(function() return core().proc_rate((S.merge(st.tab, st.ui or {}) or {}).FX_SRATE) end)
    if not ok or not rate then return "不明" end
    return ("%d Hz（%s）"):format(rate, why)
  end
  if which == "mst_rate"     then
    local ok, rate, why = pcall(function() return core().mst_proc_rate(M.mst_cfg(st)) end)
    if not ok or not rate then return "不明" end
    return ("%d Hz（%s）"):format(rate, why)
  end
  if which == "watermark"    then return M.watermark_note(st) end
  if which == "hw_items"     then return M.hw_items_note(st) end
  if which == "hw_reainsert" then return M.hw_reainsert_note(st) end
  return ""
end

-- 書き出せる状態か。戻り値: ok, 理由
function M.gate(st)
  local def = S.defaults(st.tab)

  if st.tab == "mastering" then return M.mst_gate(st) end

  -- Hardware Print は2MIXBUSもMASTERも使わない。見るのは「選んだアイテム」だけ。
  if st.tab == "hwprint" then
    local d = st.detect
    if (d.sel_items or 0) == 0 then
      return false, "書き出したいアイテムを選んでください。"
    end
    if #(d.hw_missing or {}) > 0 then
      return false, ("次のトラックには、ハードの通り道（有効なReaInsert）が見つかりません: %s")
        :format(table.concat(d.hw_missing, "、"))
    end
    if M.dest_dir(st) == nil then
      return false, "プロジェクトを一度保存してください（書き出し先がプロジェクトのフォルダになります）。"
    end
    return true, nil
  end

  -- 書き出し先。「ディレクトリ」が空なら、プロジェクトのフォルダへ出る（REAPERの動き）。
  -- 一度も保存していないプロジェクトだけは、書き出す場所が無いので止める。
  if M.dest_dir(st) == nil then
    return false, "プロジェクトを一度保存してください（書き出し先がプロジェクトのフォルダになります）。"
  end

  local _, ok = M.range_note(st)
  if not ok then
    if not st.detect.bus then
      return false, ("『%s』という名前のトラックがありません。"):format(def.BUS_NAME)
    end
    return false, ("『%s』にアイテムがありません。曲の長さのアイテム（空でよい）を置いてください。"):format(def.BUS_NAME)
  end
  if not st.detect.master then
    return false, ("『%s』という名前のトラックがありません。"):format(def.MASTER_NAME)
  end
  if st.ui.SONG_NAME_RULE == "custom"
     and (type(st.ui.SONG_NAME_CUSTOM) ~= "string" or st.ui.SONG_NAME_CUSTOM == "") then
    return false, "曲名を「入力...」にしたので、右の欄に曲名を書いてください。"
  end
  if st.tab == "para" and st.detect.sel_tracks == 0 then
    return false, "パラで書き出したいトラックを選択してください。"
  end
  if st.tab == "preview" then
    if not st.detect.preview_track then
      return false, ("『%s』という名前のトラックがありません。MASTERの外側に作ってください。")
        :format(def.PREVIEW_TRACK_NAME)
    end
    if (st.detect.preview_items or 0) == 0 then
      return false, ("『%s』トラックに波形（アイテム）がありません。透かしを置いてください。")
        :format(def.PREVIEW_TRACK_NAME)
    end
  end
  return true, nil
end

-- ===========================================================================
-- 書き出し（窓のボタンも、無人の試験も、ここを通る）
-- ===========================================================================
-- 窓の値 → core に渡す設定の表
function M.build_job(tab, ui)
  local cfg, warns = S.merge(tab, ui)
  if not cfg then return nil, table.concat(warns or { "設定を組み立てられません" }, "\n") end
  cfg.TAB = tab
  cfg.SHOW_DONE_POPUP = false   -- 完了は窓の完了画面で出す
  local ok, why = S.validate(cfg)
  if not ok then return nil, "設定が正しくありません: " .. tostring(why) end
  return cfg, nil, warns
end

-- st … M.load が返した状態（ui を窓で書き換えたもの）
-- 戻り値: res（core の結果）, cfg
function M.run(st, api)
  local cfg, err, warns = M.build_job(st.tab, st.ui)
  if not cfg then return { ok = false, aborted = err }, nil end
  -- 窓からの実行であることの目印。確認の窓（親経由パラの「混じる可能性」）は
  -- 人が見ているときだけ出す。無人実行（Headless）ではここを通らないので立たない。
  cfg.INTERACTIVE = true
  -- この曲の記憶は「書き出し」のたびに自動で保存する（判断3）
  Store.save_project(st.tab, Store.pick(st.ui, st.keys or M.stored_keys(st.tab)), api)
  -- Mastering: 窓で直した曲目情報を、書き出す前に必ずプロジェクトへ書いておく（core はそこから読む）
  if st.tab == "mastering" and st.meta then Store.save_meta(st.meta, api) end
  local C = dofile(DIR .. "tukonya_render_core.lua")
  local res = C.run(cfg)
  if res.job then
    for _, w in ipairs(warns or {}) do res.job.warnings[#res.job.warnings + 1] = w end
    -- 自動判定の理由は記録（ログ）にだけ残す（ゴール4）
    for _, r in ipairs(st.detect.reasons or {}) do res.job:log("自動判定: %s", r) end
  end
  return res, cfg
end

-- ===========================================================================
-- Mastering（読むだけの一覧・関門・曲目情報・完了の文）
-- ===========================================================================
local MLIB
local function mlib()
  if not MLIB then MLIB = dofile(DIR .. "tukonya_mastering_lib.lua") end
  return MLIB
end
M.mlib = mlib

-- 窓の値を既定に重ねた設定（点検は出力の選び方で変わるので、毎回ここから作る）
function M.mst_cfg(st)
  return (S.merge("mastering", st.ui or {})) or S.defaults("mastering")
end

-- ----- 出力の一覧（窓の「出力」欄。行を足す・消す・選び直すのはここ。窓は描くだけ）-----
-- サンプルレートの選択肢（「プロジェクトと同じ」はフォルダ名が決まらないので Mastering には出さない）
M.MST_SRATE_OPTIONS = {}
for _, o in ipairs(M.SRATE_OPTIONS) do
  if o[1] > 0 then M.MST_SRATE_OPTIONS[#M.MST_SRATE_OPTIONS + 1] = o end
end
M.MST_FORMAT_OPTIONS = {}
for _, f in ipairs(S.OUTPUT_FORMATS) do M.MST_FORMAT_OPTIONS[#M.MST_FORMAT_OPTIONS + 1] = { f.key, f.label } end
M.MST_DITHER_WAV = { { "track24", "24bit Ditherトラック" }, { "track16", "16bit Ditherトラック" },
                     { "reaper", "REAPERのディザー" }, { "none", "なし" } }
M.MST_DITHER_DDP = { { "track16", "16bit Ditherトラック" }, { "reaper", "REAPERのディザー" }, { "none", "なし" } }

-- 行ごとに出す欄: srate / bits / dither（DDP と整数のWAVだけ）
function M.mst_row_fields(r)
  if r.fmt == "wav" then
    return { srate = true, bits = true, dither = S.bits_is_fixed(r.bits) }
  end
  if r.fmt == "ddp" then return { dither = true } end
  return {}
end

function M.mst_rows(st) return S.split_outputs(st.ui.OUTPUTS) end
function M.mst_set_rows(st, rows) st.ui.OUTPUTS = S.serialize_outputs(rows) end

-- 新しい行（48/24 が無ければ 48/24、あれば 44.1/16）
function M.mst_new_row(rows)
  local used = {}
  for _, r in ipairs(rows or {}) do used[tostring(r.folder):lower()] = true end
  for _, cand in ipairs({ { 48000, "pcm24" }, { 44100, "pcm16" }, { 48000, "fp32" }, { 96000, "pcm24" } }) do
    local r = { fmt = "wav", srate = cand[1], bits = cand[2] }
    r.dither = S.default_dither(r)
    r.folder = S.auto_folder(r)
    if not used[r.folder:lower()] then return r end
  end
  local r = { fmt = "wav", srate = 48000, bits = "pcm24", dither = "track24" }
  r.folder = S.auto_folder(r) .. "-" .. tostring(#(rows or {}) + 1)
  return r
end

-- 行の1項目を変える。フォルダ名とディザーは「自動のままなら」新しい自動の値に追従させる。
-- 戻り値: 変えたか, 変えなかった理由
function M.mst_change_row(rows, i, field, value)
  local r = rows[i]
  if not r then return false, "その行はありません" end
  if field == "folder" then r.folder = (tostring(value or ""):gsub("[|;]", "")); return true end
  if field == "dither" then r.dither = value; return true end
  if field == "fmt" and value == "ddp" and r.fmt ~= "ddp" then
    for k, o in ipairs(rows) do
      if k ~= i and o.fmt == "ddp" then return false, "DDP は1つまでです（もう一つの行が DDP です）。" end
    end
  end
  local old_auto_folder = S.auto_folder(r)
  local old_auto_dither = S.default_dither(r)
  local was_auto_folder = (r.folder == old_auto_folder or r.folder == "")
  local was_auto_dither = (r.dither == old_auto_dither or r.dither == "")
  r[field] = value
  if field == "fmt" then
    if value == "wav" then
      r.srate = tonumber(r.srate) or 48000
      if not S.wav_format_key(r.bits) then r.bits = "pcm24" end
    else
      r.srate, r.bits = "", ""
    end
    was_auto_dither = true
  end
  if was_auto_folder then r.folder = S.auto_folder(r) end
  if was_auto_dither then r.dither = S.default_dither(r) end
  if r.fmt == "wav" and not S.bits_is_fixed(r.bits) then r.dither = "none" end
  if r.fmt == "ddp" and r.dither == "track24" then r.dither = "track16" end
  return true
end

-- 行の書き出し先の見本
function M.mst_row_dest(st, r)
  local dir = M.dest_dir(st) or M.NO_DEST
  if r.fmt == "ddp" then return ("%s/%s/（DDPID・PQDESCR・IMAGE.DAT ほか）"):format(dir, r.folder) end
  local songs = (st.detect.mst or {}).songs or {}
  local ext = (r.fmt == "wav") and ".wav" or (S.format2_ext(r.fmt) or "")
  local first = songs[1] and (songs[1].stem .. ext) or ("<曲名>" .. ext)
  return ("%s/%s/%s など"):format(dir, r.folder, first)
end

local function fmt_len(sec)
  sec = tonumber(sec) or 0
  return ("%d:%05.2f"):format(math.floor(sec / 60), sec - math.floor(sec / 60) * 60)
end

function M.mst_songs_note(st)
  local info = st.detect.mst
  if not info or #(info.songs or {}) == 0 then return "（2MIXBUS の中にトラックが見つかりません）" end
  local lines = {}
  local with_versions = M.mst_cfg(st).EXPORT_VERSIONS ~= false
  for i, s in ipairs(info.songs) do
    if s.main then
      lines[#lines + 1] = ("%d. %s → %s（%s）"):format(i, s.name, s.stem, fmt_len(s.main_len))
    else
      lines[#lines + 1] = ("%d. %s → 本編が分かりません"):format(i, s.name)
    end
    for _, v in ipairs(with_versions and s.versions or {}) do
      if v.items == 1 then
        lines[#lines + 1] = ("      別版: %s → %s_%s（DDP には入りません）"):format(v.name, s.stem, v.stem)
      end
    end
  end
  return table.concat(lines, "\n")
end

function M.mst_issues(st)
  local info = st.detect.mst
  if not info then return { { text = "まだ読み取っていません", block = true } } end
  return core().mst_issues(info, M.mst_cfg(st))
end

-- 書き出しは止めない注意（窓の下の「注意:」に出す。止めるものは「書き出せません:」に出る）
function M.warn_lines(st)
  if st.tab ~= "mastering" then return {} end
  local out = {}
  for _, is in ipairs(M.mst_issues(st)) do
    if not is.block then out[#out + 1] = is.text end
  end
  return out
end

function M.mst_gate(st)
  if M.dest_dir(st) == nil then
    return false, "プロジェクトを一度保存してください（書き出し先がプロジェクトのフォルダになります）。"
  end
  -- 欄の一覧そのものを見る（壊れていると設定の組み立てで既定へ戻ってしまうので、ここで止める）
  local _, why = S.parse_outputs(st.ui.OUTPUTS)
  if why then return false, "出力の一覧: " .. why end
  for _, is in ipairs(M.mst_issues(st)) do
    if is.block then return false, is.text end
  end
  return true, nil
end

-- ----- 曲目情報（プロジェクトに保存。タブの設定とは別）-----
M.META_FIELDS_ALBUM = { { "title", "TITLE" }, { "performer", "PERFORMER" }, { "songwriter", "SONGWRITER" },
                        { "composer", "COMPOSER" }, { "arranger", "ARRANGER" }, { "ean", "EAN/JAN" } }
M.META_FIELDS_TRACK = { { "title", "TITLE" }, { "performer", "PERFORMER" }, { "songwriter", "SONGWRITER" },
                        { "composer", "COMPOSER" }, { "arranger", "ARRANGER" }, { "isrc", "ISRC" } }
M.LOGIN_MSG = "共有設定を『リンクを知っている人』にしてください（シートを読めませんでした）。下の欄に直接書き込むこともできます。"

function M.mst_meta_load(api) return Store.load_meta(api) end
function M.mst_meta_save(meta, api) Store.save_meta(meta, api) end

-- シートから取り込む。fetch は差し替えられる（試験用）。
-- 戻り値: meta / nil, 理由, 注意の一覧
function M.mst_import(url, api, fetch)
  local L = mlib()
  url = tostring(url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  Store.save_sheet_url(url, api)
  local csv_url, why = L.sheet_export_url(url)
  if not csv_url then return nil, why end
  local body, ferr = (fetch or L.fetch_url)(csv_url)
  if not body or body == "" then return nil, "シートを読めませんでした" .. (ferr and ("（" .. tostring(ferr) .. "）") or "") .. "。" end
  if L.is_login_page(body) then return nil, M.LOGIN_MSG end
  local meta, warns = L.parse_sheet_csv(body)
  if #(meta.tracks or {}) == 0 and warns and #warns > 0 then
    return nil, "シートの形が読めませんでした: " .. table.concat(warns, " / ")
  end
  Store.save_meta(meta, api)
  return meta, nil, warns or {}
end

-- 書き出す前に見せる注意（曲とシートの行の対応、CD-TEXT の決まり）
function M.mst_meta_warnings(st, meta)
  meta = meta or st.meta or Store.empty_meta()
  local out = {}
  local songs = ((st.detect or {}).mst or {}).songs or {}
  local has = core().mst_has_meta(meta)
  if has and #(meta.tracks or {}) ~= #songs then
    out[#out + 1] = ("曲の数（%d）とシートの行数（%d）が違います。曲は上から順に行と対応させます。")
      :format(#songs, #(meta.tracks or {}))
  end
  for _, w in ipairs(mlib().validate_metadata(meta)) do out[#out + 1] = w end
  if not core().mst_has_cdtext(meta) then
    out[#out + 1] = "曲名などが空なので、CD-TEXT は作りません（DDP 自体は書き出せます）。"
  end
  return out
end

-- 曲 N ↔ シート N 行目
function M.mst_pairing(st, meta)
  meta = meta or st.meta or Store.empty_meta()
  local songs = ((st.detect or {}).mst or {}).songs or {}
  local n = math.max(#songs, #(meta.tracks or {}))
  local lines = {}
  for i = 1, n do
    local s, t = songs[i], (meta.tracks or {})[i]
    lines[#lines + 1] = ("トラック %d 『%s』 ↔ シート %s"):format(i, s and s.name or "（トラックなし）",
      t and (("%d 行目『%s』"):format(tonumber(t.no) or i, tostring(t.title or ""))) or "（行なし）")
  end
  return lines
end

-- 完了の文（Mastering）
function M.done_text_mastering(cfg, j)
  local t = {}
  t[#t + 1] = "書き出しました。"
  if j.hw_mode then
    t[#t + 1] = "ReaInsertを検出したため、ハードウェア書き出しモードで出力しました。"
  else
    t[#t + 1] = "有効なReaInsertを検出しなかったため、オフラインモードで出力しました。"
  end
  t[#t + 1] = ""
  for _, o in ipairs(j.mst_out_dirs or {}) do
    if o.fmt == "ddp" then
      if j.mst_ddp_count then t[#t + 1] = ("DDP（%d 曲） → %s"):format(j.mst_ddp_count, tostring(o.dir)) end
    else
      t[#t + 1] = ("%s → %s"):format(o.label, tostring(o.dir))
    end
  end
  t[#t + 1] = ""
  t[#t + 1] = "書き出したファイル:"
  if #j.produced == 0 then t[#t + 1] = "  （ありません）" end
  for _, f in ipairs(j.produced) do t[#t + 1] = f end
  if #j.warnings > 0 then
    t[#t + 1] = ""
    t[#t + 1] = ("注意 %d 件:"):format(#j.warnings)
    for _, w in ipairs(j.warnings) do t[#t + 1] = "  ・" .. w end
  end
  t[#t + 1] = ""
  t[#t + 1] = "中間ファイルは削除しました。"
  if j.LOG_PATH then
    t[#t + 1] = ""
    t[#t + 1] = "実行記録:"
    t[#t + 1] = j.LOG_PATH
  end
  return table.concat(t, "\n")
end

-- 完了の文（窓の完了画面と、無人の突き合わせ試験が同じ内容を使う）。
-- ゴール4のとおり「書き出したファイルの場所」と「異常」だけ。
-- Hardware Print の完了の文（旧 TUKO_VoComp_Render の画面に出ていた内容）
function M.done_text_hwprint(cfg, j)
  local t = {}
  local r = j.hw or { targets = {}, unmatched = {}, tree = {} }
  if r.dest_ok then
    t[#t + 1] = ("書き出し完了: %d本 → %s"):format(#r.targets, cfg.DEST_TRACK_NAME)
  else
    t[#t + 1] = ("書き出し完了: %d本 → %s（『%s』が見つからないので、REAPERが作ったトラックに置いたままです）")
      :format(#r.targets, r.out_dir or "書き出し先", cfg.DEST_TRACK_NAME)
  end
  if #(r.unmatched or {}) > 0 then
    t[#t + 1] = ("置き場所を決められなかったファイル: %d本（REAPERが作ったトラックに残っています）")
      :format(#r.unmatched)
  end
  if #(j.hw_envwarn or {}) > 0 then
    t[#t + 1] = ("音量／パンのオートメーションがあるトラック: %s（0dBにしてもオートメーションが優先されます）")
      :format(table.concat(j.hw_envwarn, "、"))
  end
  t[#t + 1] = ""
  t[#t + 1] = "書き出したファイル:"
  for _, p in ipairs(j.produced) do t[#t + 1] = p end
  if #(r.tree or {}) > 0 then
    t[#t + 1] = ""
    t[#t + 1] = "並べ直した結果:"
    for _, l in ipairs(r.tree) do t[#t + 1] = "  " .. l end
  end
  if #j.warnings > 0 then
    t[#t + 1] = ""
    t[#t + 1] = ("注意 %d 件:"):format(#j.warnings)
    for _, w in ipairs(j.warnings) do t[#t + 1] = "  ・" .. w end
  end
  if j.LOG_PATH then
    t[#t + 1] = ""
    t[#t + 1] = "実行記録:"
    t[#t + 1] = j.LOG_PATH
  end
  return table.concat(t, "\n")
end

function M.done_text(cfg, j)
  if cfg.TAB == "hwprint" then return M.done_text_hwprint(cfg, j) end
  if cfg.TAB == "mastering" then return M.done_text_mastering(cfg, j) end
  local t = {}
  t[#t + 1] = "完了しました。"
  if j.hw_mode then
    t[#t + 1] = "ハードはオンラインで1回通し、ReaInsertより後ろのソフトFXはオフラインで足しました。"
  else
    t[#t + 1] = "ReaInsert（有効）が無かったため、ハード通しは省略し、全てオフラインで書き出しました。"
  end
  t[#t + 1] = ""
  if j.range_line then t[#t + 1] = j.range_line end
  t[#t + 1] = ""
  if cfg.TAB == "para" then
    t[#t + 1] = ("パラ: %d本 → %s"):format(j.para_count, j.MIX_DIR or "(不明)")
    t[#t + 1] = ""
    t[#t + 1] = "Masterフォルダに書き出したファイル:"
  else
    t[#t + 1] = "書き出したファイル:"
  end
  if #j.produced == 0 then
    t[#t + 1] = "  （ありません）"
  else
    for _, f in ipairs(j.produced) do t[#t + 1] = f end
  end
  if cfg.TAB == "para" then
    t[#t + 1] = ""
    if j.chain_dir then
      t[#t + 1] = "MASTERのプラグイン設定も同じMasterフォルダの中に出しました:"
      t[#t + 1] = j.chain_dir
    elseif cfg.EXPORT_MASTER_CHAIN then
      t[#t + 1] = "MASTERのプラグイン設定（MasterChain）は出せませんでした。"
    end
  end
  if #j.warnings > 0 then
    t[#t + 1] = ""
    t[#t + 1] = ("注意 %d 件:"):format(#j.warnings)
    for _, w in ipairs(j.warnings) do t[#t + 1] = "  ・" .. w end
  end
  t[#t + 1] = ""
  t[#t + 1] = "中間ファイルは削除しました。"
  if j.LOG_PATH then
    t[#t + 1] = ""
    t[#t + 1] = "実行記録:"
    t[#t + 1] = j.LOG_PATH
  end
  return table.concat(t, "\n")
end

-- 「REAPER全体の既定」に入れてはいけない項目。
-- 出力フォルダはこの曲だけのもの（他の曲まで同じ場所へ出てしまう）。
-- 下見だけ（DRY_RUN）は、入れっぱなしだと以後どの曲も書き出さなくなる。
-- 曲名を直接書いたもの（SONG_NAME_CUSTOM）も、その曲だけのもの。
M.PROJECT_ONLY = { OUTPUT_DIR = true, DRY_RUN = true, SONG_NAME_CUSTOM = true }

function M.save_default(st, api)
  local keys = st.keys or M.stored_keys(st.tab)
  local t = Store.pick(st.ui, keys)
  for k in pairs(M.PROJECT_ONLY) do t[k] = nil end
  Store.save_wide(st.tab, t, api)
end

-- この曲の記憶だけを消して、既定の値（REAPER全体の既定 → 読み取り → 初期値）に戻す
function M.reset(st, api)
  Store.clear_project(st.tab, api)
  local fresh = M.load(st.tab, api)
  st.ui, st.src, st.warns, st.detect = fresh.ui, fresh.src, fresh.warns, fresh.detect
  return st
end

return M
