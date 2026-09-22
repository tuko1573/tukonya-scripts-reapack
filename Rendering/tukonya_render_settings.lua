--[[
  tukonya_render_settings.lua  （TUKONYA RENDER / Phase 1）
  ===========================================================================
  設定の「型」。reaper.* を一切呼ばないので、REAPERの外（素のLua）でも動く。
  窓（Phase 2）も、無人試験も、ここで作った表を書き出し処理へ渡す。

  タブ（tab）は3つ:
    "mix2"    … 2mix Render     （旧 TUKO_2Stage_HW_Master_Render）
    "preview" … 2mix Preview    （旧 TUKO_2Stage_Preview_Render）
    "para"    … Para + 2mix     （旧 TUKONYA_MasterParaRender）
    "hwprint" … Hardware Print  （旧 TUKO_VoComp_Render）

  使い方:
    local S = dofile(".../tukonya_render_settings.lua")
    local t, warns = S.merge("mix2", { MASTER_BITS = 16 })
    local ok, err  = S.validate(t)
    local text     = S.serialize(t)
    local t2, err2 = S.deserialize(text)
  ===========================================================================
--]]

local M = { VERSION = "0.1.0" }

M.TABS = { "mix2", "preview", "para", "hwprint" }

-- ===========================================================================
-- 書き出し形式（RENDER_FORMAT / RENDER_FORMAT2）の組み立て
-- ===========================================================================
local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i), s:byte(i + 1), s:byte(i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local t = {}
    for k = 1, 4 do
      local x = ((v >> (24 - k * 6)) & 63) + 1
      t[k] = B64CHARS:sub(x, x)
    end
    if not b then t[3], t[4] = "=", "="
    elseif not c then t[4] = "=" end
    out[#out + 1] = table.concat(t)
  end
  return table.concat(out)
end

-- WAVの RENDER_FORMAT（"evaw" ＋ 形式の1バイト ＋ 0x00 0x00 の7バイトをbase64にしたもの）。
-- 形式の1バイトは、2026-09-21 に MacBook Pro（REAPER 7.80）で0〜255まで総当たりし、
-- 出来たWAVの fmt チャンクを読み戻して確かめた（docs/phase2_notes.md の表）。記憶では決めていない。
-- 並びは REAPER の書き出し画面のビット深度の並びと同じ。
M.WAV_FORMATS = {
  { key = "pcm8",    label = "8 bit PCM",       byte = 0x08 },
  { key = "pcm16",   label = "16 bit PCM",      byte = 0x10 },
  { key = "pcm24",   label = "24 bit PCM",      byte = 0x18 },
  { key = "pcm32",   label = "32 bit PCM",      byte = 0x21 },
  { key = "fp32",    label = "32 bit FP",       byte = 0x20 },
  { key = "fp64",    label = "64 bit FP",       byte = 0x40 },
  { key = "adpcm4",  label = "4 bit IMA ADPCM", byte = 0x04 },
  { key = "cadpcm2", label = "2 bit cADPCM",    byte = 0x02 },
  { key = "ulaw8",   label = "8 bit u-Law",     byte = 0x0E },
}

-- 昔の書き方（数字）との対応。数字の 32 は **32 bit FP**（実機で確認済み）。
M.WAV_LEGACY = { [8] = "pcm8", [16] = "pcm16", [24] = "pcm24", [32] = "fp32", [64] = "fp64" }

local BY_KEY = {}
for _, f in ipairs(M.WAV_FORMATS) do BY_KEY[f.key] = f end
M.WAV_BY_KEY = BY_KEY

function M.wav_format_key(spec)
  if type(spec) == "number" then return M.WAV_LEGACY[spec] end
  if type(spec) == "string" and BY_KEY[spec] then return spec end
  return nil
end

function M.wav_format_label(spec)
  local k = M.wav_format_key(spec)
  return k and BY_KEY[k].label or tostring(spec)
end

function M.wav_format_b64(spec)
  local k = M.wav_format_key(spec)
  if not k then error("知らないビット深度です: " .. tostring(spec)) end
  return b64encode("evaw" .. string.char(BY_KEY[k].byte) .. "\0\0")
end

assert(M.wav_format_b64(24) == "ZXZhdxgAAA==", "24bitのRENDER_FORMATが既知の値と違う")
assert(M.wav_format_b64(64) == "ZXZhd0AAAA==", "64bitのRENDER_FORMATが既知の値と違う")
assert(M.wav_format_b64(32) == "ZXZhdyAAAA==", "32bitのRENDER_FORMATが既知の値と違う")
assert(M.wav_format_b64("pcm24") == M.wav_format_b64(24), "pcm24 と 24 が食い違う")
assert(M.wav_format_b64("fp64") == M.wav_format_b64(64), "fp64 と 64 が食い違う")
assert(M.wav_format_b64("fp32") == M.wav_format_b64(32), "fp32 と 32 が食い違う")

-- 副形式AAC（macOS専用のエンコーダ）。旧3本が使っていた値をそのまま写した。
M.AAC_FORMAT2 = "RlZBWAMAAAAAAAAAAAgAAAAAAADAAAAAgAcAADgEAAAAAPBBAQAAAF8AAAAAAA=="
-- 副形式MP3。4文字のsink IDは「その形式の既定設定」を意味する（API資料 RENDER_FORMAT2）
M.MP3_FORMAT2 = "l3pm"

function M.format2_string(kind)
  if kind == "aac" then return M.AAC_FORMAT2 end
  if kind == "mp3" then return M.MP3_FORMAT2 end
  return ""
end

function M.format2_ext(kind)
  if kind == "aac" then return ".m4a" end
  if kind == "mp3" then return ".mp3" end
  return nil
end

-- ===========================================================================
-- 既定値
-- ===========================================================================
-- 3タブに共通する項目
local COMMON = {
  -- 書き出し先の親フォルダ（REAPERのレンダー画面でいう「ディレクトリ」）。
  -- 空なら、いまプロジェクトに設定されている書き出し先をそのまま使う（Phase 1 と同じ動き）。
  OUTPUT_DIR          = "",
  BUS_NAME            = "2MIXBUS",   -- まとめ役の2mixトラック名
  MASTER_NAME         = "MASTER",    -- ReaInsert＋マスターチェーンを持つフォルダトラック名
  REAINSERT_MATCH     = "reainsert", -- FX名にこの文字列を含むものをReaInsertとみなす（小文字比較）
  DITHER_TRACK_NAME   = "Dither",    -- ディザー用プラグインを載せたトラック名
  -- 書き出す範囲の決め方。"bus_items"=2MIXBUSのアイテムの端から端 / "timesel" / "project"
  RANGE_MODE          = "bus_items",
  -- 書き出しのサンプルレート。0 は「プロジェクトと同じ」（REAPERの RENDER_SRATE=0。
  -- 2026-09-21 に MacBook Pro で、44.1kHz のプロジェクトを 0 で書き出して
  -- 出来たWAVの頭が 44100 になることを確かめた）。
  SRATE               = 48000,
  -- サンプルレートを変える必要が出たときの変換のやり方（REAPERの「リサンプルモード」）。
  -- 番号は REAPER の一覧の並びそのもの。10 = r8brain free（最高品質、速い）。
  RESAMPLE_MODE       = 10,
  CHANNELS            = 2,
  MASTER_BITS         = 24,          -- 納品するマスターのビット深度
  STEM_BITS           = 64,          -- 中間素材・premaster・パラのビット深度
  FORMAT2             = "aac",       -- 2つ目の形式 "none" / "aac" / "mp3"
  -- ディザーのかけ方。"track"=Ditherトラックのプラグイン / "reaper"=REAPER本体 / "none"=かけない
  DITHER_MODE         = "track",
  REAPER_DITHER_BITS  = 3,
  TMP_PREFIX          = "_tmp_hwpass_$project", -- ハード通しの中間ファイル名。最後に消す
  SHOW_DONE_POPUP     = true,
  DRY_RUN             = false,
  LOG_DIR             = "",          -- 空ならREAPERのリソースフォルダ
  LOG_KEEP            = 20,        -- 実行記録を何本残すか（窓では触らせない）
}

local PER_TAB = {
  mix2 = {
    PAT_NODITHER    = "bounce/$project_$date_youtube_no_dither",   -- Pass U のWAV（納品物）
    PAT_AAC         = "bounce/$project_$date_sample",              -- Pass U の副形式の最終的な名前
    PAT_DITHERED    = "bounce/$project_$date_distribute_dithered", -- Pass D のWAV
    DEFAULT_PATTERN = "bounce/$project_$date",                     -- ディザー無しのときの名前
  },
  preview = {
    PREVIEW_TRACK_NAME = "PREVIEWONLY",
    PREVIEW_PATTERN    = "bounce/$project_$date_sample",                -- 透かし版（Pass D）の名前
    PREVIEW_TMP_U      = "bounce/_tmp_undith_$project_$date_sample",    -- Pass U（副形式を取るためだけ）
    DEFAULT_PATTERN    = "bounce/$project_$date",                       -- クリーン版の名前
    CLEAN_TMP_U        = "bounce/_tmp_undith_$project_$date",           -- クリーン版の Pass U
    RENDER_CLEAN_TOO   = false,  -- true なら透かし無しの版も先に書き出す
    DUCK_DB            = -12.0,  -- 本編を下げる量
    DUCK_PRE           = 0.100,  -- 声の何秒手前で下げ切るか
    DUCK_FADE_IN       = 0.150,  -- 下げるフェード時間
    DUCK_RELEASE       = 0.300,  -- 声の後、復帰にかける時間
  },
  para = {
    -- 書き出し先の土台（$song ＝このスクリプトが決める曲名。他はREAPERのワイルドカード）。
    -- つこさんが旧スクリプトで使っていた形をそのまま初期値にしてある。
    DELIVERY_BASE       = "bounce/$song_processed data_BPM$tempo",
    PARA_RANGE          = "project",         -- "project" / "timesel"
    EXPORT_MASTER_CHAIN = true,
    PARA_KEEP_FOLDERS   = true,
    PARA_VIA_PARENT     = true,
    PARA_SOLO_EACH      = true,
    PARA_SOLO_MASTERMIX = true,
    SUFFIX_DITHERED     = "_distribute_dithered",
    SUFFIX_NODITHER     = "_youtube_no_dither",
    SUFFIX_AAC          = "_sample",
    SONG_NAME_RULE      = "strip_mix",       -- "strip_mix" / "project" / "title" / "custom"
    SONG_NAME_CUSTOM    = "",                -- SONG_NAME_RULE="custom" のときに使う曲名
    SONG_STRIP_WORDS    = { "mix", "mst", "master", "mastering", "ma", "pre", "premaster",
                            "rough", "demo", "ver", "v", "rev", "take", "fix", "final", "tmp" },
    MASTER_SUBFOLDER    = "Master",
    MIX_SUBFOLDER       = "Mix",
    CHAIN_SUBFOLDER     = "MasterChain",
    PRE_HW_DIR          = "1_before-hardware",
    POST_HW_DIR         = "2_after-hardware",
    NAME_PREMASTER      = "2MIXBUS(premaster)",
    NAME_HWINSERT       = "HardwareInsert",
    NAME_FALLBACK       = "SAMPLEMASTER",    -- Ditherトラックが無いときの1本の名前
    FORMAT2             = "aac",             -- 2つ目の形式（macは.m4a）
  },
  -- Hardware Print（旧 TUKO_VoComp_Render）。選んだアイテムをハードのコンプへ通して
  -- 書き出し、compressed フォルダの中に raw と同じ形のフォルダを作って並べ直す。
  -- 既定値は旧スクリプトの定数をそのまま写したもの（音とファイル名が変わらないように）。
  hwprint = {
    HW_PATTERN          = "vocomp/$track_pcd", -- 書き出し先（レンダー設定の根フォルダからの相対）
    RAW_TRACK_NAME      = "raw",               -- 元のアイテムが入っているフォルダトラック名
    DEST_TRACK_NAME     = "compressed",        -- 書き出した音を並べるフォルダトラック名
    BYPASS_MASTER_TRACK = true,                -- REAPERのマスタートラックのFXも一時的に切るか
    RESET_VOL_PAN       = true,                -- 書き出しのあいだ0dB・センターにするか（終わったら戻す）
    CHANNELS            = 1,                   -- モノ（旧スクリプトの FMT と同じ）
    MASTER_BITS         = 64,                  -- 64 bit FP（旧スクリプトの FMT と同じ）
    FORMAT2             = "none",              -- 副形式は作らない（ファイルは1本だけ）
  },
}

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepcopy(x) end
  return t
end
M.deepcopy = deepcopy

-- tab の既定値（共通＋タブ固有）を新しい表として返す
function M.defaults(tab)
  local per = PER_TAB[tab]
  if not per then return nil, ("知らないタブです: %s"):format(tostring(tab)) end
  local t = { TAB = tab }
  for k, v in pairs(COMMON) do t[k] = deepcopy(v) end
  for k, v in pairs(per)    do t[k] = deepcopy(v) end
  return t
end

-- ===========================================================================
-- 検証（範囲チェック）
-- ===========================================================================
local ALLOWED_BITS = { [16] = true, [24] = true, [32] = true, [64] = true }
local ENUMS = {
  RANGE_MODE     = { bus_items = true, timesel = true, project = true },
  FORMAT2        = { none = true, aac = true, mp3 = true },
  DITHER_MODE    = { track = true, reaper = true, none = true },
  PARA_RANGE     = { project = true, timesel = true, bus_items = true },
  SONG_NAME_RULE = { strip_mix = true, project = true, title = true, custom = true },
}
-- 空文字を許さない文字列のキー
local NONEMPTY = {
  BUS_NAME = true, MASTER_NAME = true, DITHER_TRACK_NAME = true, REAINSERT_MATCH = true,
  TMP_PREFIX = true, PAT_NODITHER = true, PAT_AAC = true, PAT_DITHERED = true,
  DEFAULT_PATTERN = true, PREVIEW_TRACK_NAME = true, PREVIEW_PATTERN = true,
  PREVIEW_TMP_U = true, CLEAN_TMP_U = true, MASTER_SUBFOLDER = true, MIX_SUBFOLDER = true,
  CHAIN_SUBFOLDER = true, NAME_PREMASTER = true, NAME_HWINSERT = true, NAME_FALLBACK = true,
  HW_PATTERN = true, RAW_TRACK_NAME = true, DEST_TRACK_NAME = true,
}

-- 1つのキーの値を見る。戻り値: ok, 理由
local function check_key(tab, k, v)
  local def = M.defaults(tab)[k]
  if def == nil then return true end           -- 知らないキーは素通し（窓の追加項目など）
  if ENUMS[k] then
    if type(v) ~= "string" or not ENUMS[k][v] then
      return false, ("%s の値が不正です（%s）"):format(k, tostring(v))
    end
    return true
  end
  if k == "PARA_BITS" or k == "MASTER_BITS" or k == "STEM_BITS" then
    -- 数字（8/16/24/32/64。昔の書き方）でも、名前（"pcm24" など）でも受ける
    if not M.wav_format_key(v) then
      return false, ("%s の形式が分かりません（%s）"):format(k, tostring(v))
    end
    return true
  end
  if k == "SRATE" then
    -- 0 は「プロジェクトと同じ」。それ以外は正の数。
    if type(v) ~= "number" or v < 0 then return false, "SRATE は 0（プロジェクトと同じ）か正の数にしてください" end
    return true
  end
  if k == "RESAMPLE_MODE" then
    if type(v) ~= "number" or v < 0 or v > 63 or v ~= math.floor(v) then
      return false, "RESAMPLE_MODE は 0〜63 の整数にしてください"
    end
    return true
  end
  if k == "CHANNELS" then
    if type(v) ~= "number" or v < 1 or v > 64 then return false, "CHANNELS は 1〜64 にしてください" end
    return true
  end
  if k == "REAPER_DITHER_BITS" then
    if type(v) ~= "number" or v < 0 or v > 31 then return false, "REAPER_DITHER_BITS は 0〜31 にしてください" end
    return true
  end
  if k == "LOG_KEEP" then
    if type(v) ~= "number" or v < 1 then return false, "LOG_KEEP は 1 以上にしてください" end
    return true
  end
  if k == "DUCK_DB" then
    if type(v) ~= "number" or v > 0 or v < -96 then return false, "DUCK_DB は -96〜0 dB にしてください" end
    return true
  end
  if k == "DUCK_PRE" or k == "DUCK_FADE_IN" or k == "DUCK_RELEASE" then
    if type(v) ~= "number" or v < 0 or v > 10 then return false, ("%s は 0〜10 秒にしてください"):format(k) end
    return true
  end
  if k == "SONG_STRIP_WORDS" then
    if type(v) ~= "table" or #v == 0 then return false, "SONG_STRIP_WORDS は空でない一覧にしてください" end
    for _, x in ipairs(v) do
      if type(x) ~= "string" or x == "" then return false, "SONG_STRIP_WORDS は空でない文字列の一覧にしてください" end
    end
    return true
  end
  if type(def) == "boolean" then
    if type(v) ~= "boolean" then return false, ("%s は true/false にしてください（%s）"):format(k, tostring(v)) end
    return true
  end
  if type(def) == "number" then
    if type(v) ~= "number" then return false, ("%s は数にしてください（%s）"):format(k, tostring(v)) end
    return true
  end
  if type(def) == "string" then
    if type(v) ~= "string" then return false, ("%s は文字にしてください（%s）"):format(k, tostring(v)) end
    if NONEMPTY[k] and v == "" then return false, ("%s を空にはできません"):format(k) end
    return true
  end
  return true
end

-- 既定値に loaded を重ねる。不正な値は既定値に戻し、警告を積む。
-- 戻り値: 設定の表, 警告の一覧
function M.merge(tab, loaded)
  local s = M.defaults(tab)
  if not s then return nil, { ("知らないタブです: %s"):format(tostring(tab)) } end
  local w = {}
  if type(loaded) ~= "table" then return s, w end
  for k, v in pairs(loaded) do
    if k ~= "TAB" then
      local ok, why = check_key(tab, k, v)
      if ok then
        s[k] = deepcopy(v)
      else
        w[#w + 1] = ("%s。既定値 %s を使います。"):format(why, tostring(s[k]))
      end
    end
  end
  return s, w
end

-- 表全体を見る。戻り値: ok, 最初に見つかった理由
function M.validate(t)
  if type(t) ~= "table" then return false, "設定が表ではありません" end
  local tab = t.TAB
  if not PER_TAB[tab] then return false, ("タブ（TAB）が不正です: %s"):format(tostring(tab)) end
  local def = M.defaults(tab)
  for k in pairs(def) do
    if t[k] == nil then return false, ("設定 %s がありません"):format(k) end
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    if k ~= "TAB" then
      local ok, why = check_key(tab, k, t[k])
      if not ok then return false, why end
    end
  end
  -- 曲名を「入力...」にしたのに、何も書いていない
  if t.SONG_NAME_RULE == "custom" and (type(t.SONG_NAME_CUSTOM) ~= "string" or t.SONG_NAME_CUSTOM == "") then
    return false, "曲名に「入力...」を選んだときは、曲名を書いてください"
  end
  return true
end

-- ===========================================================================
-- 文字列にする／戻す（JSONは使えないので、Luaの表そのままの書き方）
-- ===========================================================================
local function quote(s)
  return ("%q"):format(s):gsub("\\\n", "\\n")
end

local function ser(v, indent)
  local t = type(v)
  if t == "string" then return (quote(v)) end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  end
  if t ~= "table" then error("設定に入れられない値です: " .. t) end
  local pad, pad2 = string.rep(" ", indent), string.rep(" ", indent + 2)
  local out = { "{" }
  local n = #v
  if n > 0 then
    for i = 1, n do out[#out + 1] = pad2 .. ser(v[i], indent + 2) .. "," end
  end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
      if type(k) ~= "string" then error("設定のキーは文字だけにしてください") end
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = ("%s[%s] = %s,"):format(pad2, quote(k), ser(v[k], indent + 2))
  end
  out[#out + 1] = pad .. "}"
  return table.concat(out, "\n")
end

function M.serialize(t)
  return "return " .. ser(t, 0) .. "\n"
end

-- 文字列を表に戻す。安全のため、何も呼べない空の環境で読む。
function M.deserialize(text)
  if type(text) ~= "string" or text == "" then return nil, "設定の文字列が空です" end
  local chunk, err = load(text, "settings", "t", {})
  if not chunk then return nil, "設定を読めません: " .. tostring(err) end
  local ok, v = pcall(chunk)
  if not ok then return nil, "設定を読めません: " .. tostring(v) end
  if type(v) ~= "table" then return nil, "設定が表ではありません" end
  return v
end

-- ===========================================================================
-- 曲名の決め方（旧 TUKONYA_MasterParaRender の M.song_name をそのまま）
-- ===========================================================================
function M.song_name(projfile, rule, words, custom)
  if rule == "custom" then return tostring(custom or "") end
  local name = tostring(projfile or "")
  name = name:gsub("\\", "/"):match("([^/]*)$") or ""
  name = name:gsub("%.[Rr][Pp][Pp]$", "")
  if rule == "title" then return "$title" end
  if rule == "project" then return name end
  words = words or PER_TAB.para.SONG_STRIP_WORDS
  local lname = name:lower()
  local best
  for _, word in ipairs(words) do
    local w = tostring(word or ""):lower()
    if w ~= "" then
      local from = 1
      while true do
        local st, en = lname:find("_" .. w, from, true)
        if not st then break end
        local q = en + 1
        local b = lname:byte(q)
        while b and b >= 48 and b <= 57 do q = q + 1; b = lname:byte(q) end
        local nxt = lname:sub(q, q)
        if nxt == "" or nxt == "_" or nxt == "-" or nxt == " " then
          if not best or st < best then best = st end
          break
        end
        from = st + 1
      end
    end
  end
  if best then
    local cut = name:sub(1, best - 1)
    if cut ~= "" then return cut end
  end
  return name
end

-- 時刻の表示（0:03.500 の形）
function M.fmt_time(t)
  t = tonumber(t) or 0
  if t < 0 then t = 0 end
  local m = math.floor(t / 60)
  return ("%d:%06.3f"):format(m, t - m * 60)
end

-- DELIVERY_BASE の中の "$song" だけを曲名に差し替える（他のワイルドカードはREAPERに渡す）
function M.resolve_delivery_base(base, song)
  if type(base) ~= "string" then return base end
  if type(song) ~= "string" then song = tostring(song or "") end
  return (base:gsub("%$song%f[%A]", function() return song end))
end

-- ===========================================================================
-- 実行記録のファイル名と世代管理
-- ===========================================================================
M.LOG_PREFIX  = "TUKONYA_Render_"
M.LOG_PATTERN = "^TUKONYA_Render_%d%d%d%d%d%d%d%d_%d%d%d%d%d%d%.log$"

function M.log_filename(stamp) return M.LOG_PREFIX .. stamp .. ".log" end

local function path_sep(dir) return dir:find("\\") and "\\" or "/" end
M.path_sep = path_sep

function M.rotate_logs(dir, keep, listfiles, removefile)
  local removed, failed = {}, {}
  if type(dir) ~= "string" or dir == "" then return removed, failed end
  if type(keep) ~= "number" or keep < 1 then return removed, failed end
  pcall(listfiles, dir, -1)
  local names = {}
  local i = 0
  while i < 100000 do
    local ok, n = pcall(listfiles, dir, i)
    if not ok or type(n) ~= "string" then break end
    if n:match(M.LOG_PATTERN) then names[#names + 1] = n end
    i = i + 1
  end
  table.sort(names)
  local sep = path_sep(dir)
  for k = 1, #names - keep do
    local ok, err = removefile(dir .. sep .. names[k])
    if ok then removed[#removed + 1] = names[k]
    else failed[#failed + 1] = ("%s（%s）"):format(names[k], tostring(err)) end
  end
  return removed, failed
end

return M
