--[[
  tukonya_render_core.lua  （TUKONYA RENDER / Phase 1）
  ===========================================================================
  旧3本（2mix Render / 2mix Preview / Para + 2mix）に重複していた骨組みを
  1つにまとめたもの。設定の表（tukonya_render_settings.lua の型）を受け取り、
  書き出しを実行する。窓（Phase 2）も無人試験も、ここを同じ入口から呼ぶ。

  中身:
    ・Job … 1回の実行につき、最初に1回だけ状態を控え、最後に1回だけ戻す（判断9）
    ・書き出し＋完了確認 … 42230 のあと、RENDER_TARGETS のファイルが存在し、
                           サンプル長が「範囲 × サンプルレート」に合うかを見る（判断10）
    ・工程 … ステム化 / ハード通し / Pass U / Pass D / パラ / チェーン書き出し / 透かし
    ・タブの流れ … mix2 / preview / para

  必要拡張: SWS/S&M
  ===========================================================================
--]]

local DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local S = dofile(DIR .. "tukonya_render_settings.lua")

local C = { DIR = DIR, Settings = S, VERSION = "0.1.0" }

-- 親経由パラ（規則4）で「音が混じるかもしれない」ときに、窓からの実行だけ
-- 「続行／キャンセル」を出すかどうか。将来やめるときはここを false にする。
-- 無人実行（Headless）は cfg.INTERACTIVE が立たないので、この値に関わらず記録だけ。
C.BLEED_DIALOG = true

-- ===========================================================================
-- 中断（後片付けをしてから、つこさんに理由を見せる）
-- ===========================================================================
local function abort(msg)
  error({ tukonya_abort = tostring(msg) }, 0)
end
C.abort = abort

-- ===========================================================================
-- 小物
-- ===========================================================================
local function to_int(x) return math.floor((x or 0) + 0.5) end

local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then return tr end
  end
  return nil
end

local function find_reainsert(master, match)
  for i = 0, reaper.TrackFX_GetCount(master) - 1 do
    local _, nm = reaper.TrackFX_GetFXName(master, i, "")
    if nm and string.find(string.lower(nm), match, 1, true) then return i end
  end
  return nil
end

local function media_path_of_track(tr)
  local it = reaper.GetTrackMediaItem(tr, 0)
  if not it then return nil end
  local tk = reaper.GetActiveTake(it)
  if not tk or reaper.TakeIsMIDI(tk) then return nil end
  local src = reaper.GetMediaItemTake_Source(tk)
  if not src then return nil end
  local p = reaper.GetMediaSourceFileName(src, "")
  if p and p ~= "" then return p end
  return nil
end

local function guid_set_of_all_tracks()
  local s = {}
  for i = 0, reaper.CountTracks(0) - 1 do s[reaper.GetTrackGUID(reaper.GetTrack(0, i))] = true end
  return s
end

local function clear_track_items(tr)
  for i = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do
    reaper.DeleteTrackMediaItem(tr, reaper.GetTrackMediaItem(tr, i))
  end
end

-- WAVのヘッダーを素のLuaで読んで、正味のフレーム数を返す。
-- PCM_Source_CreateFromFile を使わないのは、ピーク（.reapeaks）などの副産物を
-- 作らせないため（出力フォルダの中身が変わると突き合わせが崩れる）。
local function le(bytes)
  local v = 0
  for i = #bytes, 1, -1 do v = v * 256 + bytes:byte(i) end
  return v
end
local function wav_frames(path)
  local f = io.open(path, "rb")
  if not f then return nil, "開けません" end
  local head = f:read(12)
  if not head or #head < 12 or head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WAVE" then
    f:close(); return nil, "WAVではありません"
  end
  local ch, bits, tag, srate
  while true do
    local h = f:read(8)
    if not h or #h < 8 then f:close(); return nil, "data チャンクがありません" end
    local cid, size = h:sub(1, 4), le(h:sub(5, 8))
    if cid == "fmt " then
      local d = f:read(size)
      if not d or #d < 16 then f:close(); return nil, "fmt が読めません" end
      tag   = le(d:sub(1, 2))
      ch    = le(d:sub(3, 4))
      srate = le(d:sub(5, 8))
      bits  = le(d:sub(15, 16))
      if size % 2 == 1 then f:read(1) end
    elseif cid == "data" then
      -- ヘッダーが言う大きさぶん、本当に中身があるか。書き出しが途中で終わると
      -- ヘッダーだけ先に書かれていることがあるので、実際のファイルの長さと突き合わせる。
      local here = f:seek("cur")
      local eof  = f:seek("end")
      f:close()
      if (eof - here) < size then
        return nil, ("途中で切れています（中身 %d バイト / ヘッダーは %d バイトと言っている）")
          :format(eof - here, size)
      end
      if ch == nil then return nil, "fmt が data より後ろにあります" end
      local by = ch * math.floor((bits or 0) / 8)
      -- 1サンプルが1バイトに満たない形式（ADPCM など）は、長さを数えられない。
      -- -1 を返して「中身はあるが長さは不明」と伝える。
      if by == 0 then return -1, nil, tag, srate end
      return math.floor(size / by), nil, tag, srate
    else
      if not f:seek("cur", size + (size % 2)) then f:close(); return nil, "壊れています" end
    end
  end
end
C.wav_frames = wav_frames

-- ===========================================================================
-- Job … 1回の実行
-- ===========================================================================
local Job = {}
Job.__index = Job

function C.new(cfg)
  local ok, why = S.validate(cfg)
  if not ok then return nil, why end
  local j = setmetatable({}, Job)
  j.S = cfg
  j.restore = {}
  j.created_tracks = {}
  j.temp_files = {}
  j.produced = {}
  j.warnings = {}
  j.log_lines = {}
  j.FXN = 0
  j.SAVE_FX = {}
  j.para_count = 0
  j.t0 = os.clock()
  -- 書き出し形式（設定から組み立てる）
  j.FMT2     = S.format2_string(cfg.FORMAT2)
  j.FMT2_EXT = S.format2_ext(cfg.FORMAT2)
  j.FMT_STEM = {   -- 中間素材・premaster・パラ
    RENDER_FORMAT = S.wav_format_b64(cfg.STEM_BITS), RENDER_FORMAT2 = "",
    RENDER_SRATE = cfg.SRATE, RENDER_CHANNELS = cfg.CHANNELS,
    RENDER_DITHER = 16, RENDER_NORMALIZE = 0,
  }
  j.FMT_MASTER = {  -- Pass U（ディザー無し。WAV＋副形式）
    RENDER_FORMAT = S.wav_format_b64(cfg.MASTER_BITS), RENDER_FORMAT2 = j.FMT2,
    RENDER_SRATE = cfg.SRATE, RENDER_CHANNELS = cfg.CHANNELS,
    RENDER_DITHER = 16, RENDER_NORMALIZE = 0,
  }
  j.FMT_MASTER_D = {  -- Pass D（ディザー有り。WAVだけ）
    RENDER_FORMAT = S.wav_format_b64(cfg.MASTER_BITS), RENDER_FORMAT2 = "",
    RENDER_SRATE = cfg.SRATE, RENDER_CHANNELS = cfg.CHANNELS,
    -- 量子化をDitherトラックのプラグインが行うときは、REAPER側のディザーは必ず切る（16＝全て無効）
    RENDER_DITHER = (cfg.DITHER_MODE == "reaper") and cfg.REAPER_DITHER_BITS or 16,
    RENDER_NORMALIZE = 0,
  }
  return j
end

-- ----- 記録（実行記録ファイル。1行ずつ開いて閉じるので、途中で落ちても残る）-----
function Job:open_log()
  local function trim_sep(p) return (p:gsub("[/\\]+$", "")) end
  local res_dir = trim_sep(reaper.GetResourcePath())
  local want = self.S.LOG_DIR
  if type(want) == "string" and want ~= "" then
    want = trim_sep(want)
    reaper.RecursiveCreateDirectory(want, 0)
  else
    want = res_dir
  end
  local name = S.log_filename(os.date("%Y%m%d_%H%M%S"))
  local function try(dir)
    local p = dir .. S.path_sep(dir) .. name
    local okf, f = pcall(io.open, p, "wb")
    if okf and f then f:close(); return p end
    return nil
  end
  self.LOG_PATH = try(want)
  if self.LOG_PATH then
    self.LOG_DIR = want
  else
    self.LOG_DIR = res_dir
    self.LOG_PATH = res_dir .. "/" .. name
    if want ~= res_dir then
      self:warn(("実行記録を LOG_DIR（%s）に書けないので、REAPERのリソースフォルダに書きました。"):format(want))
    else
      self:warn("実行記録を書けませんでした（フォルダに書き込めない）。")
    end
  end
  local sws = (reaper.SNM_GetIntConfigVar ~= nil) and "あり" or "なし"
  self:log_write("wb", ("TUKONYA RENDER 実行記録\n%s\ncore %s / タブ %s / REAPER %s / OS %s / SWS %s\n")
    :format(os.date("%Y-%m-%d %H:%M:%S"), C.VERSION, tostring(self.S.TAB),
            tostring(reaper.GetAppVersion()), tostring(reaper.GetOS()), sws))
  local keys = {}
  for k in pairs(self.S) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = self.S[k]
    self:log_plain(("  %-20s= %s"):format(k, type(v) == "table" and ("{" .. table.concat(v, ", ") .. "}") or tostring(v)))
  end
  self:log_plain("実行記録の置き場: " .. self.LOG_DIR)
  self:log_plain("")
  -- 古い実行記録を、新しい方から LOG_KEEP 本だけ残して消す（他のファイルには触らない）
  local removed, failed = S.rotate_logs(self.LOG_DIR, self.S.LOG_KEEP, reaper.EnumerateFiles, os.remove)
  if #removed > 0 then
    self:log_plain(("古い実行記録 %d 本を消しました（%d 本まで残す設定）:"):format(#removed, self.S.LOG_KEEP))
    for _, n in ipairs(removed) do self:log_plain("  " .. n) end
  end
  for _, n in ipairs(failed) do self:warn("古い実行記録を消せませんでした: " .. n) end
  if #removed > 0 or #failed > 0 then self:log_plain("") end
end

function Job:log_write(mode, text)
  if not self.LOG_PATH then return end
  local okf, f = pcall(io.open, self.LOG_PATH, mode)
  if okf and f then
    pcall(function() f:write(text) end)
    f:close()
  end
end
function Job:log_plain(s) self:log_write("ab", tostring(s) .. "\n") end
function Job:log(fmt, ...)
  local s = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  self:log_write("ab", ("%s  [%7.2fs] %s\n"):format(os.date("%H:%M:%S"), os.clock() - self.t0, s))
end
function Job:warn(s)
  self.warnings[#self.warnings + 1] = s
  self:log_plain("  警告: " .. tostring(s))
end
function Job:add_produced(p)
  if p and p ~= "" then
    self.produced[#self.produced + 1] = p
    self:log_plain("  書き出し: " .. p)
  end
end

-- ----- レンダー設定まわり -----
function Job:set_pattern(p) reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", p, true) end

-- keep_tail=true のときだけ、プロジェクトのテール（尻尾）の設定に触らない。
-- Hardware Print（旧 TUKO_VoComp_Render）はテールを一度も触っていなかったので、
-- 同じファイルが出るように、そのタブだけ keep_tail を立てて呼ぶ。
function Job:apply_format(t, keep_tail)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  t.RENDER_FORMAT,  true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", t.RENDER_FORMAT2, true)
  reaper.GetSetProjectInfo(0, "RENDER_SRATE",     t.RENDER_SRATE,     true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS",  t.RENDER_CHANNELS,  true)
  reaper.GetSetProjectInfo(0, "RENDER_DITHER",    t.RENDER_DITHER,    true)
  reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", t.RENDER_NORMALIZE, true)
  -- プロジェクトのレンダー設定でテール（尻尾）が有効だと、そのぶん長いファイルが出てしまう。
  -- 全パス（名前の解決も含む）で毎回強制的に切る。
  if not keep_tail then reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true) end
end

-- いまのレンダー設定で「どこに何という名前で書かれるか」をREAPER自身に解かせる
function Job:target()
  local ok, t = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
  local first = ok and t and t:match("^([^;]+)") or nil
  if first == "" then first = nil end
  return first
end

-- 副形式（AAC/MP3）はWAVと同じ名前で出るので、拡張子を差し替えて求める
function Job:secondary(wav, ext)
  ext = ext or self.FMT2_EXT
  if not wav or not ext then return nil end
  return (wav:gsub("%.[Ww][Aa][Vv]$", ext))
end

function Job:apply_range()
  if self.RANGE_S then reaper.GetSet_LoopTimeRange(true, false, self.RANGE_S, self.RANGE_E, false) end
end

-- ----- 書き出し＋完了確認（判断10）-----
-- いまの RENDER_BOUNDSFLAG から「出るはずの長さ」を求める。分からなければ nil。
function Job:expected_seconds()
  local b = to_int(reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false))
  if b == 2 then
    if self.RANGE_S then return self.RANGE_E - self.RANGE_S, 1 end
    local a, bb = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if bb > a then return bb - a, 1 end
    return nil
  elseif b == 1 then
    local len = reaper.GetProjectLength(0)
    if len and len > 0 then return len, 1 end
    return nil
  end
  return nil
end

-- 書き出して、出来たファイルを確かめる。合わなければ中断（後片付けは呼び出しの外で行う）。
function Job:render(wav)
  self:apply_range()
  local t0 = os.clock()
  reaper.Main_OnCommand(42230, 0)  -- Render, most recent settings, auto-close
  local sec = os.clock() - t0
  self:verify(wav)
  -- ゴール4: 記録には「どのパスが終わったか」と「かかった秒数」を残す
  self:log("パス完了（%.2f 秒）: %s", sec, tostring(wav))
end

function Job:verify(wav)
  if not wav or wav == "" then
    abort("書き出し先のファイル名が分かりませんでした。中断します。")
  end
  if not reaper.file_exists(wav) then
    abort(("書き出しが終わっていません（ファイルがありません）。中断します。\n%s"):format(wav))
  end
  if not wav:lower():match("%.wav$") then return end   -- WAV以外は存在だけ見る
  local frames, why, tag, file_srate = wav_frames(wav)
  if not frames then
    abort(("書き出したファイルを読めませんでした（%s）。中断します。\n%s"):format(tostring(why), wav))
  end
  -- ADPCM や u-Law のような「1サンプルが1バイト未満／圧縮」の形式は、
  -- ヘッダーから長さを数えられない。ファイルがあることだけ確かめる。
  if frames < 0 or (tag ~= 1 and tag ~= 3 and tag ~= 0xFFFE) then
    self:log("完了確認: %s（形式 %s のため、長さは見ずに存在だけ確かめた）", wav, tostring(tag))
    return
  end
  if frames <= 0 then
    abort(("書き出したファイルが空です。中断します。\n%s"):format(wav))
  end
  local sec, strict_tol = self:expected_seconds()
  if not sec then
    self:log("完了確認: %s（%d frames / 期待の長さは不明なので存在だけ見た）", wav, frames)
    return
  end
  local srate = to_int(reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false))
  -- RENDER_SRATE=0 は「プロジェクトと同じ」（実機で確認済み）。何になったかは
  -- 出来たファイルの頭に書いてあるので、そこから読む。
  if srate <= 0 then srate = to_int(file_srate or 0) end
  if srate <= 0 then srate = to_int(self.S.SRATE) end
  if srate <= 0 then
    self:log("完了確認: %s（%d frames / サンプルレートが分からないので長さは見ない）", wav, frames)
    return
  end
  local want = math.floor(sec * srate + 0.5)
  -- 判断10どおり ±1 フレーム。長さが分からないときは、上で存在だけ見て戻っている。
  local tol = strict_tol or 1
  if math.abs(frames - want) > tol then
    abort(("書き出したファイルの長さが合いません（%d frames / 期待 %d ±%d）。中断します。\n%s")
      :format(frames, want, tol, wav))
  end
  self:log("完了確認: %s（%d frames / 期待 %d）", wav, frames, want)
end

-- ----- ディザー -----
function Job:set_dither(on)
  if self.DITHER and reaper.ValidatePtr(self.DITHER, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(self.DITHER, "I_FXEN", on and 1 or 0)
  end
end

-- ディザー版を出す直前の確認。止めずに注意を積むだけ。
function Job:check_dither_sanity()
  if self.S.DITHER_MODE ~= "track" or not self.DITHER then return end
  local D, name = self.DITHER, self.S.DITHER_TRACK_NAME
  local n = reaper.TrackFX_GetCount(D)
  local enabled, named = 0, false
  for i = 0, n - 1 do
    if reaper.TrackFX_GetEnabled(D, i) then enabled = enabled + 1 end
    local _, nm = reaper.TrackFX_GetFXName(D, i, "")
    if nm and string.find(string.lower(nm), "dither", 1, true) then named = true end
  end
  if enabled == 0 then
    self:warn(("『%s』トラックに有効なプラグインが1つもありません。ディザーがかかっていない可能性があります。"):format(name))
  elseif not named then
    self:warn(("『%s』トラックのプラグインに『Dither』を含む名前のものがありません。中身を確認してください。"):format(name))
  end
  local dv = reaper.GetMediaTrackInfo_Value(D, "D_VOL")
  local dp = reaper.GetMediaTrackInfo_Value(D, "D_PAN")
  if math.abs(dv - 1.0) > 1e-6 or math.abs(dp) > 1e-6 then
    self:warn(("『%s』トラックのフェーダーが0dB／センターではありません（音量 %.6f / パン %.6f）。"):format(name, dv, dp))
  end
  local mt = reaper.GetMasterTrack(0)
  if mt then
    local mv = reaper.GetMediaTrackInfo_Value(mt, "D_VOL")
    local mp = reaper.GetMediaTrackInfo_Value(mt, "D_PAN")
    if math.abs(mv - 1.0) > 1e-6 or math.abs(mp) > 1e-6 then
      self:warn(("REAPERのマスタートラックのフェーダーが0dB／センターではありません（音量 %.6f / パン %.6f）。"):format(mv, mp))
    end
    local mn, live = reaper.TrackFX_GetCount(mt), 0
    for i = 0, mn - 1 do if reaper.TrackFX_GetEnabled(mt, i) then live = live + 1 end end
    if live > 0 then
      self:warn(("REAPERのマスタートラックに有効なプラグインが %d 個あります（ディザーの後ろで音が変わります）。"):format(live))
    end
  end
end

-- ----- MASTERのFXの有効状態 -----
function Job:set_master_all(enabled)
  for i = 0, self.FXN - 1 do reaper.TrackFX_SetEnabled(self.MASTER, i, enabled) end
end
function Job:set_master_original()
  for i = 0, self.FXN - 1 do reaper.TrackFX_SetEnabled(self.MASTER, i, self.SAVE_FX[i]) end
end
function Job:set_master_up_to_reai()   -- ハード通し用: 0..reai=現状, reai+1..=OFF
  local r = self.reai
  for i = 0, r do reaper.TrackFX_SetEnabled(self.MASTER, i, self.SAVE_FX[i]) end
  for i = r + 1, self.FXN - 1 do reaper.TrackFX_SetEnabled(self.MASTER, i, false) end
end
function Job:set_master_after_reai()   -- 仕上げ用: 0..reai=OFF, reai+1..=現状
  local r = self.reai
  for i = 0, r do reaper.TrackFX_SetEnabled(self.MASTER, i, false) end
  for i = r + 1, self.FXN - 1 do reaper.TrackFX_SetEnabled(self.MASTER, i, self.SAVE_FX[i]) end
end

-- ===========================================================================
-- 控え（1回の実行につき1回）と、後片付け（同じく1回）
-- ===========================================================================
local function snapshot_all(key)
  local s = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    s[reaper.GetTrackGUID(tr)] = reaper.GetMediaTrackInfo_Value(tr, key)
  end
  return s
end
local function restore_all(key, s)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local v = s[reaper.GetTrackGUID(tr)]
    if v ~= nil then reaper.SetMediaTrackInfo_Value(tr, key, v) end
  end
end
C.snapshot_all, C.restore_all = snapshot_all, restore_all

-- 送り（send）1本ずつのミュート。親経由パラ（規則2b・3c）で送り単位を切るので、
-- トラックのミュートとは別に控える。番号は実行中に増減しない（送りを足さないため）。
local function snapshot_sendmutes()
  local s = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local n = reaper.GetTrackNumSends(tr, 0)
    if n > 0 then
      local a = {}
      for k = 0, n - 1 do a[k] = reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") end
      s[reaper.GetTrackGUID(tr)] = a
    end
  end
  return s
end
local function restore_sendmutes(s)
  if not s then return end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local a = s[reaper.GetTrackGUID(tr)]
    if a then
      for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        if a[k] ~= nil then reaper.SetTrackSendInfo_Value(tr, 0, k, "B_MUTE", a[k]) end
      end
    end
  end
end
C.snapshot_sendmutes, C.restore_sendmutes = snapshot_sendmutes, restore_sendmutes

-- ===== 親経由パラ（規則1〜4 / docs/sidechain_spec.md v2、2026-09-21）=====
-- P は「MASTER の直前の先祖」＝ふつうはミックス全部が入っている 2MIXBUS。
-- そこまで通して書き出し、P の中の「生かす集合 L」以外をミュートする。
-- サイドチェーンの送り元（キー元）はミュートせず、代わりに親への送り（メインセンド）と
-- 1/2ch の送りを送り単位で切って、鍵だけ残し音は混ぜない。
local function gid(tr) return reaper.GetTrackGUID(tr) end
local function sput(s, tr) if tr then s[gid(tr)] = tr end end
local function shas(s, tr) return tr ~= nil and s[gid(tr)] ~= nil end
local function snames(s)
  local t = {}
  for _, tr in pairs(s) do local _, nm = reaper.GetTrackName(tr); t[#t + 1] = nm end
  table.sort(t)
  return t
end
local function joinnames(s)
  local t = snames(s)
  return #t > 0 and table.concat(t, ", ") or "なし"
end
local function is_ancestor(anc, tr)   -- anc が tr の先祖か（同一は false）
  local p = reaper.GetParentTrack(tr)
  while p do
    if p == anc then return true end
    p = reaper.GetParentTrack(p)
  end
  return false
end
-- 規則1: T が 2MIXBUS（j.BUS）の中にいれば P = 2MIXBUS。
-- 2MIXBUS の外にいるときだけ、親が MASTER（または親無し）になる手前の先祖で止める。
-- 2MIXBUS が MASTER の直下でない組み方でも、ミックスは 2MIXBUS まで通る。
-- サイドチェーンの有無で P を変える旧規則（受け口のある最寄りの親）は廃止した。
local function pick_parent(j, T)
  if j.BUS and T ~= j.BUS and is_ancestor(j.BUS, T) then return j.BUS end
  local P, p = T, reaper.GetParentTrack(T)
  while p and p ~= j.MASTER do P = p; p = reaper.GetParentTrack(p) end
  return P
end
local function send_dst(tr, k)    -- 送り k の行き先・送り先ch・送り自体のミュート
  local dst = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, k, 1)
  local ch  = math.floor(reaper.GetTrackSendInfo_Value(tr, 0, k, "I_DSTCHAN") + 0.5) & 1023
  local mu  = reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") or 0
  return dst, ch, (mu >= 0.5)
end
local function recv_src(tr, k)    -- 受け k の送り元・受け側ch・受け自体のミュート
  local src = reaper.BR_GetMediaTrackSendInfo_Track(tr, -1, k, 0)
  local ch  = math.floor(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_DSTCHAN") + 0.5) & 1023
  local mu  = reaper.GetTrackSendInfo_Value(tr, -1, k, "B_MUTE") or 0
  return src, ch, (mu >= 0.5)
end

-- 1本ぶんの計画を作る（ここでは何も書き換えない。DRY_RUN でも同じものを作る）
local function build_para_plan(j, T)
  local P = pick_parent(j, T)
  local plan = { T = T, P = P, L = {}, path = {}, inner = {}, muted = {},
                 keep = {}, keep_cut = {}, sendmute = {}, bleed = {}, outside = {} }
  if P == T then return plan end   -- 遡る先が無い（T 自身が最上位）

  -- 通り道（P..T）と T の配下
  local seed = {}
  do
    local x = T
    while x do
      sput(plan.path, x); sput(plan.L, x); sput(plan.inner, x); sput(seed, x)
      if x == P then break end
      x = reaper.GetParentTrack(x)
    end
  end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if is_ancestor(T, tr) then sput(plan.L, tr); sput(plan.inner, tr); sput(seed, tr) end
  end
  -- 規則2: 1/2ch の送り先（リバーブ・パラコンプのバス）と、その先の送り、
  --        それらの先祖（P まで）も L に入れる
  local queue, qi = {}, 1
  for _, tr in pairs(seed) do queue[#queue + 1] = tr end
  while qi <= #queue do
    local tr = queue[qi]; qi = qi + 1
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local dst, ch, mu = send_dst(tr, k)
      if dst and ch < 2 and not mu and not shas(plan.L, dst) then
        sput(plan.L, dst)
        local a = reaper.GetParentTrack(dst)
        while a and a ~= P and not shas(plan.L, a) do sput(plan.L, a); a = reaper.GetParentTrack(a) end
        queue[#queue + 1] = dst
      end
    end
  end
  -- 規則2: P の配下で L に入らないものをミュート
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if is_ancestor(P, tr) and not shas(plan.L, tr) then sput(plan.muted, tr) end
  end

  -- 規則3a/3b: キー元を集める（L の受けのうち送り先chが3以上。そこから受けを順にたどる）
  local kroot, visited = {}, {}
  local kq, ki = {}, 1
  -- plan.outside … P の外にいるキー元（触らない。仕様の前提から外れる組み方）
  local function under_P(tr) return tr == P or is_ancestor(P, tr) end
  local function add_key(src)
    if not src or shas(plan.L, src) or visited[gid(src)] then return end
    visited[gid(src)] = true
    if not under_P(src) then
      -- P の外のトラックには一切触らない（ミュート解除もメインセンドも切らない）。
      -- ここで触ると、MASTER のメインセンドまで切って無音になりうる。
      sput(plan.outside, src)
      return
    end
    sput(kroot, src); kq[#kq + 1] = src
  end
  for _, tr in pairs(plan.L) do
    for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      local src, ch, mu = recv_src(tr, k)
      if ch >= 2 and not mu then add_key(src) end
    end
  end
  while ki <= #kq do
    local tr = kq[ki]; ki = ki + 1
    for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      local src, _, mu = recv_src(tr, k)
      if not mu then add_key(src) end
    end
  end
  -- 規則3c: K とその配下、および L に入るまでの先祖を生かす（ミュートしない）
  for _, K in pairs(kroot) do
    sput(plan.keep, K); sput(plan.keep_cut, K)
    for i = 0, reaper.CountTracks(0) - 1 do
      local tr = reaper.GetTrack(0, i)
      if is_ancestor(K, tr) and not shas(plan.L, tr) and under_P(tr) then sput(plan.keep, tr) end
    end
    local a = reaper.GetParentTrack(K)
    while a and not shas(plan.L, a) and under_P(a) do   -- P の配下から出ない
      sput(plan.keep, a); sput(plan.keep_cut, a)
      a = reaper.GetParentTrack(a)
    end
  end
  for _, tr in pairs(plan.keep) do plan.muted[gid(tr)] = nil end
  -- メインセンドを切るのは K 本体とミュート解除した先祖だけ。K の配下は親（K）へ
  -- 音を届ける役なので切らない（切ると K がフォルダのとき鍵が消える）。

  -- 規則2b・3c: 送り単位のミュート（最後の形を一度に作る）
  local function mark_send(tr, k)
    plan.sendmute[#plan.sendmute + 1] = { tr = tr, idx = k }
  end
  for _, tr in pairs(plan.muted) do          -- 規則2b: ミュートしたトラック → L への 1/2ch
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local dst, ch, mu = send_dst(tr, k)
      if dst and ch < 2 and not mu and shas(plan.L, dst) then mark_send(tr, k) end
    end
  end
  for _, tr in pairs(plan.keep) do           -- 規則3c: キー元 → キー元の集合の外への 1/2ch
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local dst, ch, mu = send_dst(tr, k)
      if dst and ch < 2 and not mu and not shas(plan.keep, dst) then mark_send(tr, k) end
    end
  end

  -- 規則4: それでも残る混じり（L の中の X が、T 以外の生きているトラックから 1/2ch で受けている）
  for _, X in pairs(plan.L) do
    if not shas(plan.path, X) then
      for k = 0, reaper.GetTrackNumSends(X, -1) - 1 do
        local src, ch, mu = recv_src(X, k)
        if src and ch < 2 and not mu and shas(plan.L, src) and not shas(plan.inner, src) then
          local _, sn = reaper.GetTrackName(src)
          local _, xn = reaper.GetTrackName(X)
          plan.bleed[#plan.bleed + 1] = sn .. " → " .. xn
        end
      end
    end
  end
  table.sort(plan.bleed)
  return plan
end

-- 計画を実際にかける（DRY_RUN のときは呼ばない）
local function apply_para_plan(plan)
  for _, tr in pairs(plan.muted) do reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
  for _, tr in pairs(plan.keep_cut) do reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0) end
  for _, s in ipairs(plan.sendmute) do
    reaper.SetTrackSendInfo_Value(s.tr, 0, s.idx, "B_MUTE", 1)
  end
end

-- 計画の文（記録・DRY_RUN の両方で同じものを使う）
local function plan_sendmute_names(plan)
  local t = {}
  for _, s in ipairs(plan.sendmute) do
    local dst = reaper.BR_GetMediaTrackSendInfo_Track(s.tr, 0, s.idx, 1)
    local _, a = reaper.GetTrackName(s.tr)
    local bn = "?"
    if dst then local _, x = reaper.GetTrackName(dst); bn = x end
    t[#t + 1] = a .. "→" .. bn
  end
  table.sort(t)
  return #t > 0 and table.concat(t, ", ") or "なし"
end
C.build_para_plan, C.apply_para_plan = build_para_plan, apply_para_plan

-- ===== 「選択トラックのSC状態を確認」の文 =====
-- 何も書き換えない。窓のボタンと、資料の書き出しの両方がここを通る。
-- label(tr) … トラックの呼び名を返す関数。窓では名前、資料では T<番号>。
local function track_name(tr)
  local _, n = reaper.GetTrackName(tr)
  return tostring(n)
end

-- 計画を作るだけ（プロジェクトには触れない）。j は { BUS=, MASTER= } だけあればよい。
function C.para_plan_preview(BUS, MASTER, T)
  if not T then return nil, "トラックが選ばれていません。" end
  return build_para_plan({ BUS = BUS, MASTER = MASTER }, T)
end

-- トラックの番号（1から数える。窓では「128:Dr_KICK」のように出す）
local function track_num(tr)
  local n = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
  return math.floor((n or 0) + 0.5)
end

-- 「選択トラックのSC状態を確認」に出す文。
--   シグナルチェーン … P から T までの通り道（本当の名前）
--   サイドチェーン   … その通り道のトラックが 3ch 以上で受けている口だけ。
--                      送り元は1段だけ（中継の先はたどらない）。ミュートされた受けは出さない。
-- opts.label     … トラックの呼び名（既定は本当の名前）
-- opts.src_label … 送り元の書き方（既定は「(番号): 名前」）
function C.sc_state_text(plan, opts)
  opts = opts or {}
  local label = opts.label or track_name
  local src_label = opts.src_label or function(tr)
    return ("%d:%s"):format(track_num(tr), track_name(tr))
  end
  local t = {}
  -- 通り道（P → … → T）
  local road, x = {}, plan.T
  while x do
    road[#road + 1] = x
    if x == plan.P then break end
    x = reaper.GetParentTrack(x)
  end
  for i = 1, math.floor(#road / 2) do road[i], road[#road - i + 1] = road[#road - i + 1], road[i] end
  local names = {}
  for _, tr in ipairs(road) do names[#names + 1] = label(tr) end
  t[#t + 1] = "シグナルチェーン:"
  t[#t + 1] = "  " .. table.concat(names, " → ")
  -- サイドチェーン（通り道のトラックの、3ch 以上の受けだけ）。T に近い方から並べる。
  local body = {}
  for ri = #road, 1, -1 do
    local tr = road[ri]
    local order, bych = {}, {}
    for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      local src, ch, mu = recv_src(tr, k)
      if src and ch >= 2 and not mu then
        if not bych[ch] then bych[ch] = {}; order[#order + 1] = ch end
        local list = bych[ch]
        list[#list + 1] = src_label(src)
      end
    end
    table.sort(order)
    for _, ch in ipairs(order) do
      body[#body + 1] = ("  %s（%d/%dch）← %s"):format(
        label(tr), ch + 1, ch + 2, table.concat(bych[ch], ", "))
    end
  end
  if #body == 0 then
    t[#t + 1] = "サイドチェーン: なし"
  else
    t[#t + 1] = "サイドチェーン:"
    for _, l in ipairs(body) do t[#t + 1] = l end
  end
  return t
end

-- ===== 構成を資料として書き出す（名前・パスの類は一切入れない）=====
-- トラックは T<番号>（1から数えた並び順）だけで呼ぶ。
local function fx_plain_name(tr, fx)
  local nm
  if reaper.TrackFX_GetNamedConfigParm then
    local ok, v = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
    if ok and type(v) == "string" and v ~= "" then nm = v end
  end
  if not nm then
    local _, v = reaper.TrackFX_GetFXName(tr, fx, "")
    nm = tostring(v or "")
    -- 「VST: ReaComp (Cockos) - 呼び名」のように後ろへ付いたものを落とす（作り手名は残す）
    local head = nm:match("^(.-%s%b())%s*[%-–—]%s*.+$")
    if head then nm = head end
  end
  return (nm:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function chan_text(v)   -- I_SRCCHAN / I_DSTCHAN を「ch 1/2」の形に
  v = math.floor((v or 0) + 0.5)
  if v < 0 then return "なし（MIDIのみ）" end
  local n = v & 1023
  if (v & 1024) ~= 0 then return ("ch %d"):format(n + 1) end
  return ("ch %d/%d"):format(n + 1, n + 2)
end
local SENDMODE = { [0] = "post-fader", [1] = "pre-FX", [3] = "pre-fader" }

local function fx_input_pins(tr, fx)
  if not (reaper.TrackFX_GetIOSize and reaper.TrackFX_GetPinMappings) then return nil end
  local ok, _, nin = pcall(reaper.TrackFX_GetIOSize, tr, fx)
  if not ok or type(nin) ~= "number" or nin <= 0 or nin > 32 then return nil end
  local mask = 0
  for pin = 0, nin - 1 do
    local ok2, lo = pcall(reaper.TrackFX_GetPinMappings, tr, fx, 0, pin)
    if ok2 and type(lo) == "number" then mask = mask | math.floor(lo) end
  end
  if mask == 0 then return nil end
  local t = {}
  for b = 0, 31 do if (mask >> b) & 1 == 1 then t[#t + 1] = tostring(b + 1) end end
  return table.concat(t, ",")
end

-- path … 書き出すファイル。T … 「確認」で選んでいるトラック（nil 可）。
-- opts … { BUS=, MASTER=, cfg=, script_version= }（無くてもよい）
function C.write_structure_report(path, T, opts)
  opts = opts or {}
  local cfg = opts.cfg or S.defaults("para")
  local BUS = opts.BUS or find_track_by_name(cfg.BUS_NAME)
  local MASTER = opts.MASTER or find_track_by_name(cfg.MASTER_NAME)

  local n = reaper.CountTracks(0)
  local idx, depth = {}, {}
  for i = 0, n - 1 do idx[gid(reaper.GetTrack(0, i))] = i + 1 end
  local function L(tr)
    if not tr then return "?" end
    local i = idx[gid(tr)]
    return i and ("T" .. i) or "T?"
  end
  for i = 0, n - 1 do
    local tr, d, p = reaper.GetTrack(0, i), 0, reaper.GetParentTrack(reaper.GetTrack(0, i))
    while p do d = d + 1; p = reaper.GetParentTrack(p) end
    depth[i + 1] = d
  end

  local t = {}
  local function w(s) t[#t + 1] = tostring(s) end
  w("TUKONYA RENDER 構成の資料")
  w("トラック名・アイテム名・ファイル名は入っていません")
  w(os.date("%Y-%m-%d %H:%M:%S"))
  w(("REAPER %s / OS %s / core %s / 窓 %s"):format(
    tostring(reaper.GetAppVersion and reaper.GetAppVersion() or "?"),
    tostring(reaper.GetOS and reaper.GetOS() or "?"),
    tostring(C.VERSION), tostring(opts.script_version or "?")))
  w(("paraに効く設定: PARA_VIA_PARENT=%s / PARA_SOLO_EACH=%s / PARA_KEEP_FOLDERS=%s"):format(
    tostring(cfg.PARA_VIA_PARENT), tostring(cfg.PARA_SOLO_EACH), tostring(cfg.PARA_KEEP_FOLDERS)))
  -- 設定のトラック名そのものは書かない（名前を出さない約束のため）。見つかったかどうかだけ。
  w(("2mixのバス役: %s / マスター役: %s"):format(
    BUS and L(BUS) or "見つからず", MASTER and L(MASTER) or "見つからず"))
  w(("トラック %d 本"):format(n))
  w("")
  w("--- トラック（字下げは入れ子の深さ）---")
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local V = function(k) return reaper.GetMediaTrackInfo_Value(tr, k) end
    local ms = (V("B_MAINSEND") >= 0.5)
    w(("%s%s  深さ=%d nch=%d 親送り=%s(nch=%d off=%d) mute=%d solo=%d アイテム=%d"):format(
      string.rep("  ", depth[i + 1]), L(tr), depth[i + 1],
      math.floor(V("I_NCHAN") + 0.5), ms and "on" or "off",
      math.floor(V("C_MAINSEND_NCH") + 0.5), math.floor(V("C_MAINSEND_OFFS") + 0.5),
      math.floor(V("B_MUTE") + 0.5), math.floor(V("I_SOLO") + 0.5),
      reaper.CountTrackMediaItems and reaper.CountTrackMediaItems(tr) or 0))
    local pad = string.rep("  ", depth[i + 1]) .. "    "   -- 送り・受け・FX は木に合わせて字下げ
    for k = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      local dst = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, k, 1)
      local md = math.floor(reaper.GetTrackSendInfo_Value(tr, 0, k, "I_SENDMODE") + 0.5)
      w((pad .. "送り: %s → %s  src %s → dst %s  %s  mute=%s"):format(
        L(tr), L(dst), chan_text(reaper.GetTrackSendInfo_Value(tr, 0, k, "I_SRCCHAN")),
        chan_text(reaper.GetTrackSendInfo_Value(tr, 0, k, "I_DSTCHAN")),
        SENDMODE[md] or ("mode " .. md),
        (reaper.GetTrackSendInfo_Value(tr, 0, k, "B_MUTE") >= 0.5) and "yes" or "no"))
    end
    for k = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      local src = reaper.BR_GetMediaTrackSendInfo_Track(tr, -1, k, 0)
      local md = math.floor(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_SENDMODE") + 0.5)
      w((pad .. "受け: %s → %s  src %s → dst %s  %s  mute=%s"):format(
        L(src), L(tr), chan_text(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_SRCCHAN")),
        chan_text(reaper.GetTrackSendInfo_Value(tr, -1, k, "I_DSTCHAN")),
        SENDMODE[md] or ("mode " .. md),
        (reaper.GetTrackSendInfo_Value(tr, -1, k, "B_MUTE") >= 0.5) and "yes" or "no"))
    end
    for fx = 0, (reaper.TrackFX_GetCount and reaper.TrackFX_GetCount(tr) or 0) - 1 do
      local pins = fx_input_pins(tr, fx)
      w((pad .. "FX %d: %s  %s%s%s"):format(fx + 1, fx_plain_name(tr, fx),
        reaper.TrackFX_GetEnabled(tr, fx) and "有効" or "無効",
        (reaper.TrackFX_GetOffline and reaper.TrackFX_GetOffline(tr, fx)) and " / オフライン" or "",
        pins and ("  in: ch " .. pins) or ""))
    end
  end

  w("")
  w("--- 選んでいるトラックのSC状態（窓の確認と同じ内容）---")
  if not T then
    w("（トラックが選ばれていないので出せません）")
  elseif not cfg.PARA_VIA_PARENT then
    w("親トラックの遡りは無効です（P = 自分）")
  else
    local plan = build_para_plan({ BUS = BUS, MASTER = MASTER }, T)
    if plan.P == T then
      w("遡る先がありません（P = 自分）")
    else
      for _, line in ipairs(C.sc_state_text(plan, { label = L, src_label = L })) do w(line) end
    end
  end

  local okf, f = pcall(io.open, path, "wb")
  if not okf or not f then return nil, ("ファイルを作れません: %s"):format(tostring(path)) end
  local okw, err = pcall(function() f:write(table.concat(t, "\n") .. "\n") end)
  f:close()
  if not okw then return nil, tostring(err) end
  return path
end


function Job:snapshot()
  local r = self.restore
  r.sel = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do r.sel[#r.sel + 1] = reaper.GetSelectedTrack(0, i) end
  r.bus_mute        = reaper.GetMediaTrackInfo_Value(self.BUS, "B_MUTE")
  if self.PREVIEW then r.prev_mute = reaper.GetMediaTrackInfo_Value(self.PREVIEW, "B_MUTE") end
  r.workrender      = to_int(reaper.SNM_GetIntConfigVar("workrender", 0))
  -- 書き出しのリサンプルモード（REAPERの「リサンプルモード」。2026-09-21 に実機で
  -- 変数名と .RPP の行 RENDER_RESAMPLE を確かめた）。値が無い機械では -1 を控える。
  r.resample        = to_int(reaper.SNM_GetIntConfigVar("projrenderresample", -1))
  r.projrenderlimit = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", 2))
  -- ミュートを切り替えたときのクリック防止フェード（REAPER の reaper.ini の mutefadems10。
  -- 単位は 0.1 ms。既定 50＝5 ms）。親経由パラでミュートを使うと、そのあとの書き出しの
  -- 頭 5 ms にフェードが乗るので、ミュートを使うときだけ 0 にして、最後に戻す。
  -- 値が無い機械では -1 を控えて何もしない。
  r.mutefade        = to_int(reaper.SNM_GetIntConfigVar("mutefadems10", -1))
  r.render_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  r.bounds          = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
  r.addtoproj       = reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, false)
  local _, cur_pat  = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
  r.pattern         = cur_pat
  local _, cur_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
  r.render_file     = cur_file
  -- 成果物のファイル名は設定の決め打ちだけを使う。プロジェクトのレンダー設定の
  -- ファイル名は読まない（終わったら元に戻すためだけに控える）。
  local _, cur_fmt  = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  "", false)
  local _, cur_fmt2 = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", "", false)
  r.format          = cur_fmt
  r.format2         = cur_fmt2
  r.srate           = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
  r.channels        = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
  r.dither          = reaper.GetSetProjectInfo(0, "RENDER_DITHER", 0, false)
  r.normalize       = reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", 0, false)
  r.tailflag        = reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, false)
  r.tailms          = reaper.GetSetProjectInfo(0, "RENDER_TAILMS", 0, false)
  r.timesel         = { reaper.GetSet_LoopTimeRange(false, false, 0, 0, false) }
  r.cursor          = reaper.GetCursorPosition()
  r.mute            = snapshot_all("B_MUTE")
  r.solo            = snapshot_all("I_SOLO")
  r.mainsend        = snapshot_all("B_MAINSEND")   -- 親経由パラ（規則3）で切るので控える
  r.sendmute        = snapshot_sendmutes()         -- 送り単位のミュート（規則2b・3c）
  self:log("元のレンダー設定を控えた（パターン: %s）", tostring(cur_pat))
end

-- 後片付けの順序: エンベロープ → MASTERのFX → DitherのFXボタン →
--   生成したトラックを削除 → 中間ファイルを削除 → ミュート →
--   レンダー設定 → 範囲とカーソル → 設定変数 → ミュート／ソロの一覧 → 選択
function Job:cleanup()
  local r = self.restore
  self:log("後片付け開始")
  -- MASTERボリューム・エンベロープ（透かし版だけが触る）
  if self.ENV then
    if not self.ENV_CREATED and self.ENV_CHUNK then
      reaper.SetEnvelopeStateChunk(self.ENV, self.ENV_CHUNK, false)
    elseif self.ENV_CREATED then
      reaper.DeleteEnvelopePointRange(self.ENV, -1.0, 1e9)
      reaper.Envelope_SortPoints(self.ENV)
      if self.MASTER and reaper.ValidatePtr(self.MASTER, "MediaTrack*") then
        reaper.SetOnlyTrackSelected(self.MASTER)
        reaper.Main_OnCommand(40406, 0) -- Toggle track volume envelope visible（作成した分を隠す）
      end
    end
    reaper.Envelope_SortPoints(self.ENV)
  end
  if self.MASTER and reaper.ValidatePtr(self.MASTER, "MediaTrack*") and self.FXN > 0 then
    self:set_master_original()
  end
  if self.DITHER and reaper.ValidatePtr(self.DITHER, "MediaTrack*") and r.dither_fxen ~= nil then
    reaper.SetMediaTrackInfo_Value(self.DITHER, "I_FXEN", r.dither_fxen)
  end
  for _, tr in ipairs(self.created_tracks) do
    if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.DeleteTrack(tr) end
  end
  for _, f in ipairs(self.temp_files) do
    pcall(os.remove, f)
    pcall(os.remove, f .. ".reapeaks")
  end
  if self.PREVIEW and reaper.ValidatePtr(self.PREVIEW, "MediaTrack*") and r.prev_mute ~= nil then
    reaper.SetMediaTrackInfo_Value(self.PREVIEW, "B_MUTE", r.prev_mute)
  end
  if self.BUS and reaper.ValidatePtr(self.BUS, "MediaTrack*") and r.bus_mute ~= nil then
    reaper.SetMediaTrackInfo_Value(self.BUS, "B_MUTE", r.bus_mute)
  end
  if r.render_settings ~= nil then reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", r.render_settings, true) end
  if r.bounds    ~= nil then reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", r.bounds, true) end
  if r.addtoproj ~= nil then reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", r.addtoproj, true) end
  if r.pattern   ~= nil then self:set_pattern(r.pattern) end
  if r.render_file ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FILE", r.render_file, true) end
  if r.format    ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  r.format,  true) end
  if r.format2   ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", r.format2, true) end
  if r.srate     ~= nil then reaper.GetSetProjectInfo(0, "RENDER_SRATE",     r.srate,     true) end
  if r.channels  ~= nil then reaper.GetSetProjectInfo(0, "RENDER_CHANNELS",  r.channels,  true) end
  if r.dither    ~= nil then reaper.GetSetProjectInfo(0, "RENDER_DITHER",    r.dither,    true) end
  if r.normalize ~= nil then reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", r.normalize, true) end
  if r.tailflag  ~= nil then reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", r.tailflag, true) end
  if r.tailms    ~= nil then reaper.GetSetProjectInfo(0, "RENDER_TAILMS",   r.tailms,   true) end
  if r.timesel then reaper.GetSet_LoopTimeRange(true, false, r.timesel[1], r.timesel[2], false) end
  if r.cursor ~= nil then reaper.SetEditCurPos(r.cursor, false, false) end
  if r.projrenderlimit ~= nil then reaper.SNM_SetIntConfigVar("projrenderlimit", r.projrenderlimit) end
  if r.mutefade ~= nil and r.mutefade >= 0 and self.mutefade_off then
    reaper.SNM_SetIntConfigVar("mutefadems10", r.mutefade)
  end
  if r.workrender ~= nil then reaper.SNM_SetIntConfigVar("workrender", r.workrender) end
  if r.resample ~= nil and r.resample >= 0 then
    reaper.SNM_SetIntConfigVar("projrenderresample", r.resample)
  end
  if r.mute then restore_all("B_MUTE", r.mute) end
  if r.solo then restore_all("I_SOLO", r.solo) end
  -- 親経由パラで触るもの（中断・キャンセルのときもここを通る）
  if r.mainsend then restore_all("B_MAINSEND", r.mainsend) end
  if r.sendmute then restore_sendmutes(r.sendmute) end
  if r.sel then
    reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    for _, tr in ipairs(r.sel) do
      if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.SetTrackSelected(tr, true) end
    end
  end
  self:log("後片付け完了")
end

-- ===========================================================================
-- 下ごしらえ（トラック探し・状態の控え・書き出し範囲）
-- ===========================================================================
function Job:prepare()
  local cfg = self.S
  if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar) then
    abort("SWS/S&M拡張が見つかりません。SWSをインストールしてください。")
  end
  self.BUS = find_track_by_name(cfg.BUS_NAME)
  if not self.BUS then
    abort(("『%s』という名前のトラックが見つかりません。\nトラック名を確認してください（大文字小文字も一致が必要）。"):format(cfg.BUS_NAME))
  end
  self.MASTER = find_track_by_name(cfg.MASTER_NAME)
  if not self.MASTER then
    abort(("『%s』という名前のトラックが見つかりません。\nトラック名を確認してください（大文字小文字も一致が必要）。"):format(cfg.MASTER_NAME))
  end
  if cfg.PREVIEW_TRACK_NAME then
    self.PREVIEW = find_track_by_name(cfg.PREVIEW_TRACK_NAME)
    if not self.PREVIEW then
      abort(("『%s』トラックが見つかりません。MASTERの外側に作ってください。"):format(cfg.PREVIEW_TRACK_NAME))
    end
  end
  self.DITHER = find_track_by_name(cfg.DITHER_TRACK_NAME)
  if cfg.DITHER_MODE == "track" and not self.DITHER then
    self:warn(("『%s』トラックが見つからなかったため、ディザー無しの1組だけを書き出しました。"):format(cfg.DITHER_TRACK_NAME))
  end
  self:log("ディザーの方式: %s / 『%s』トラック: %s", cfg.DITHER_MODE, cfg.DITHER_TRACK_NAME,
    self.DITHER and "あり" or "なし")

  -- MASTERフェーダー／パンが素通しか確認。
  -- ハード通しと仕上げでMASTERを2回通るので、0dBでないと音量が二重にかかる。
  local vol = reaper.GetMediaTrackInfo_Value(self.MASTER, "D_VOL")
  local pan = reaper.GetMediaTrackInfo_Value(self.MASTER, "D_PAN")
  if math.abs(vol - 1.0) > 0.0012 or math.abs(pan) > 0.001 then
    abort("MASTERトラックのフェーダーが0dB（またはパンがセンター）ではありません。\n音量が二重にかかるのを防ぐため中断します。\nMASTERを0dB/センターに戻してから再実行してください。")
  end

  -- MASTER FXの現状を保存（FXを触る前に必ず）
  self.FXN = reaper.TrackFX_GetCount(self.MASTER)
  for i = 0, self.FXN - 1 do self.SAVE_FX[i] = reaper.TrackFX_GetEnabled(self.MASTER, i) end

  -- 状態の控え（1回の実行につき1回）
  self:snapshot()

  -- 書き出しのリサンプルモード（サンプルレートを変えるときの変換のやり方）
  if type(cfg.RESAMPLE_MODE) == "number" and self.restore.resample and self.restore.resample >= 0 then
    reaper.SNM_SetIntConfigVar("projrenderresample", math.floor(cfg.RESAMPLE_MODE))
    self:log("リサンプルモード: %d（元は %d）", math.floor(cfg.RESAMPLE_MODE), self.restore.resample)
  end

  -- 書き出し先フォルダ。窓で指定されたときだけ差し替える（空なら今の設定のまま）。
  if type(cfg.OUTPUT_DIR) == "string" and cfg.OUTPUT_DIR ~= "" then
    local dir = (cfg.OUTPUT_DIR:gsub("[/\\]+$", ""))
    reaper.RecursiveCreateDirectory(dir, 0)
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
    self:log("書き出し先フォルダ: %s（窓の指定）", dir)
  end

  -- DitherトラックのFXボタンの現状を控えて、いったん必ず切る。
  -- ディザーは最後の1本（Pass D）だけに掛ける。保存状態には頼らない。
  if self.DITHER then
    self.restore.dither_fxen = reaper.GetMediaTrackInfo_Value(self.DITHER, "I_FXEN")
    self:set_dither(false)
  end

  -- ReaInsert検出（有効状態で存在すればハードモード）
  self.reai = find_reainsert(self.MASTER, cfg.REAINSERT_MATCH)
  self.hw_mode = (self.reai ~= nil) and (self.SAVE_FX[self.reai] == true)
  self:log("MASTER FX %d 個 / ReaInsert %s / ハード通し %s", self.FXN,
    self.reai and ("番号 " .. (self.reai + 1)) or "無し", self.hw_mode and "あり" or "なし")

  -- 安全のため、書き出し元（Source）はダイアログ任せにせず毎回明示する
  self.master_mix = to_int(self.restore.render_settings) & (~0x10EB)
  self.stems_only = self.master_mix | 128   -- 選択トラック（マスター経由）
end

-- 書き出し範囲を決める（RANGE_MODE）
function Job:resolve_range()
  local cfg = self.S
  if cfg.RANGE_MODE == "bus_items" then
    local n = reaper.CountTrackMediaItems(self.BUS)
    if n == 0 then
      abort("2MIXBUSにアイテムがありません。書き出す範囲を決めるため、2MIXBUSに曲の長さのアイテム（空でよい）を置いてから実行してください。")
    end
    local mn, mx
    for i = 0, n - 1 do
      local it = reaper.GetTrackMediaItem(self.BUS, i)
      local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local b = a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if not mn or a < mn then mn = a end
      if not mx or b > mx then mx = b end
    end
    self.RANGE_S, self.RANGE_E = mn, mx
    self:apply_range()
    self.stem_action, self.bounds_flag, self.start_pos = 41716, 2, mn
    self.range_line = ("書き出し範囲: %s〜%s（2MIXBUSのアイテムから）"):format(S.fmt_time(mn), S.fmt_time(mx))
  elseif cfg.RANGE_MODE == "project" then
    self.stem_action, self.bounds_flag, self.start_pos = 40405, 1, 0.0
    self.range_line = "書き出し範囲: プロジェクト全体"
  else -- "timesel"
    local a, b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local has_ts = (b - a) > 0.0000001
    self.stem_action = has_ts and 41716 or 40405
    self.bounds_flag = has_ts and 2 or 1
    self.start_pos   = has_ts and a or 0.0
    self.range_line  = has_ts
      and ("書き出し範囲: %s〜%s（タイムセレクションから）"):format(S.fmt_time(a), S.fmt_time(b))
      or  "書き出し範囲: プロジェクト全体（タイムセレクション無し）"
  end
  self:log("%s", self.range_line)
end

-- ===========================================================================
-- 同名ファイルの自動連番
-- ===========================================================================
-- 同じ日に2回実行すると、固定名にREAPERの「同名ファイルの扱い」（確認の窓、または
-- 無音のまま -001 連番）がぶつかり、副形式の改名や完了画面の一覧が崩れる。そこで
-- 先に名前だけ解決し、成果物セットのどれも存在しない最小の番号Nを探す。
-- build_set(suffix) … その番号での成果物のパス一覧を返す（レンダーはしない）
function Job:resolve_suffix(build_set)
  local function any_exists(set)
    for _, p in ipairs(set) do
      if p and p ~= "" and reaper.file_exists(p) then return true end
    end
    return false
  end
  local n = 0
  while any_exists(build_set((n == 0) and "" or ("-" .. string.format("%03d", n)))) do
    n = n + 1
    if n > 999 then
      abort("同名ファイルの空き番号が見つかりませんでした（-001〜-999 すべて使用中です）。")
    end
  end
  return (n == 0) and "" or ("-" .. string.format("%03d", n))
end

-- 名前だけ解決する（パターンと形式を当てて RENDER_TARGETS を読む）
function Job:resolve_target(pattern, fmt)
  self:set_pattern(pattern)
  self:apply_format(fmt)
  return self:target()
end

-- ===========================================================================
-- 工程
-- ===========================================================================
-- ステム化（2MIXBUSを、オフライン最速でステレオ・ポストフェーダーのステムにする）
function Job:make_stem()
  reaper.SNM_SetIntConfigVar("workrender", self.restore.workrender & (~8))
  reaper.Main_OnCommand(40297, 0) -- unselect all
  reaper.SetTrackSelected(self.BUS, true)
  local before = guid_set_of_all_tracks()
  self:apply_range()
  reaper.Main_OnCommand(self.stem_action, 0)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not before[reaper.GetTrackGUID(tr)] then
      self.STEM = self.STEM or tr
      self.created_tracks[#self.created_tracks + 1] = tr
      local mp = media_path_of_track(tr)
      if mp then self.temp_files[#self.temp_files + 1] = mp end
    end
  end
  if not self.STEM then
    abort("ステム化に失敗しました（新しいステムトラックが作られませんでした）。\n2MIXBUSにアイテム/信号があるか確認してください。")
  end
  self:log("ステム化完了")
end

-- ハード通し（オンライン＝実時間）。出来た音をステムの中身と差し替える。
--   pattern  … 書き出し先のパターン
--   keep     … true なら納品物として残す（Para + 2mix の #2）。false なら中間ファイルとして消す。
function Job:hardware_pass(pattern, keep)
  self:apply_format(self.FMT_STEM)
  self:set_master_up_to_reai()
  self:set_pattern(pattern)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", to_int(self.restore.addtoproj) | 1, true)
  reaper.SNM_SetIntConfigVar("projrenderlimit", 2) -- Online Render（ハード通しは必須）
  local chk = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", -1))
  if chk ~= 2 then
    abort(("レンダー速度を Online にできませんでした（現在値=%d）。\nハードを通らない録音を防ぐため中断します。"):format(chk))
  end
  local wav = self:target()
  if keep then self:add_produced(wav) end
  self:log("ハード通し（実時間）: %s", tostring(wav))
  local before2 = guid_set_of_all_tracks()
  reaper.PreventUIRefresh(-1)  -- 進捗を見せる
  self:render(wav)
  reaper.PreventUIRefresh(1)

  local p2, added2 = nil, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not before2[reaper.GetTrackGUID(tr)] then
      added2[#added2 + 1] = tr
      p2 = p2 or media_path_of_track(tr)
    end
  end
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", self.restore.addtoproj, true)
  if p2 and not keep then self.temp_files[#self.temp_files + 1] = p2 end
  if not p2 then
    for _, tr in ipairs(added2) do if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.DeleteTrack(tr) end end
    abort("ハード通しの書き出しファイルを取り込めませんでした。中断します。")
  end
  -- ステムトラックの中身をハード通しの音へ差し替え
  clear_track_items(self.STEM)
  reaper.SetOnlyTrackSelected(self.STEM)
  reaper.SetEditCurPos(self.start_pos, false, false)
  reaper.InsertMedia(p2, 0)
  for _, tr in ipairs(added2) do if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.DeleteTrack(tr) end end
  self:set_master_after_reai()
end

-- 納品物の書き出し（Pass U ＋ Pass D）。3タブで共通の心臓部。
--   pat.u        … Pass U（ディザー無し）の書き出し先パターン
--   pat.keep_u   … Pass U のWAVを納品物として残すか（false なら中間ファイル扱いで消す）
--   pat.aac      … 副形式の最終的な名前のパターン
--   pat.d        … Pass D（ディザー有り）の書き出し先パターン
--   pat.fallback … 「ディザーを掛けない」ときに1本だけ別の名前で出す道（2mix Preview 専用）。
--                  2mix Render と Para + 2mix には渡さない。渡さない場合、
--                  Ditherトラックが無いときは「ディザー＝なし」を選んだときと同じ
--                  1組（_youtube_no_dither ＋ _sample）が出る（2026-09-21 つこさん了承）。
function Job:render_deliverable(pat)
  local cfg = self.S
  reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- Full-speed Offline

  -- ディザーを掛けない条件: 「なし」を選んだか、「Ditherトラック」なのにトラックが無いか
  local no_dither = (cfg.DITHER_MODE == "none") or (cfg.DITHER_MODE == "track" and not self.DITHER)

  if no_dither and pat.fallback then
    -- 透かし版のように「1本だけ、決まった名前で」出す道
    self:apply_format(self.FMT_MASTER)
    self:set_pattern(pat.fallback)
    local wav = self:target()
    self:log("書き出し（ディザーなしの1本だけ）: %s", tostring(wav))
    self:render(wav)
    self:add_produced(wav)
    if self.FMT2_EXT then self:add_produced(self:secondary(wav)) end
    return
  end

  -- ----- Pass U（ディザー無し。WAV＋副形式）-----
  self:set_dither(false)
  self:apply_format(self.FMT_MASTER)
  self:set_pattern(pat.u)
  local wav_u = self:target()
  local tmp2  = self:secondary(wav_u)
  self:log("Pass U（ディザーなし）: %s", tostring(wav_u))
  self:render(wav_u)
  if pat.keep_u then
    self:add_produced(wav_u)
  elseif wav_u then
    self.temp_files[#self.temp_files + 1] = wav_u   -- 副形式を取るためだけのWAVは捨てる
  end

  -- 副形式の最終的な名前をREAPERに解かせてから改名する
  self:set_pattern(pat.aac)
  local final_wav = self:target()
  local final2 = self:secondary(final_wav)
  if self.FMT2_EXT and tmp2 and final2 then
    if reaper.file_exists(tmp2) then
      local okr, errr = os.rename(tmp2, final2)
      if okr then
        self:log("副形式の名前を変えました: %s → %s", tmp2, final2)
        self:add_produced(final2)
      else
        self:warn(("副形式の名前を変えられませんでした（%s → %s: %s）"):format(tmp2, final2, tostring(errr)))
      end
    else
      self:warn("副形式（" .. self.FMT2_EXT .. "）が書き出されていないため、名前を変えられませんでした: " .. tostring(tmp2))
    end
  end

  if no_dither then
    self:log("%s のため、ディザー版は書き出しません",
      (cfg.DITHER_MODE == "none") and "ディザー＝なし"
      or ("『" .. tostring(cfg.DITHER_TRACK_NAME) .. "』トラックが無い"))
    return
  end

  -- ----- Pass D（ディザー有り。WAVだけ）-----
  self:check_dither_sanity()
  if cfg.DITHER_MODE == "track" then self:set_dither(true) end
  self:apply_format(self.FMT_MASTER_D)
  self:set_pattern(pat.d)
  local wav_d = self:target()
  self:log("Pass D（ディザーあり / %s）: %s",
    (cfg.DITHER_MODE == "reaper") and ("REAPERのディザー bits=" .. tostring(cfg.REAPER_DITHER_BITS)) or "Ditherトラック",
    tostring(wav_d))
  -- [試験用の注入点]
  self:render(wav_d)
  self:set_dither(false)
  self:add_produced(wav_d)
end

-- ===========================================================================
-- 透かし（2mix Preview 専用）
-- ===========================================================================
-- PREVIEWONLYのアイテムから、ダッキング対象の区間を作る（近接は結合）
function Job:build_duck_spans()
  local cfg = self.S
  local raw = {}
  for i = 0, reaper.CountTrackMediaItems(self.PREVIEW) - 1 do
    local it = reaper.GetTrackMediaItem(self.PREVIEW, i)
    local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    raw[#raw + 1] = { pos, pos + len }
  end
  table.sort(raw, function(a, b) return a[1] < b[1] end)
  local gap = cfg.DUCK_PRE + cfg.DUCK_FADE_IN + cfg.DUCK_RELEASE
  local merged = {}
  for _, s in ipairs(raw) do
    local last = merged[#merged]
    if last and s[1] <= last[2] + gap then
      if s[2] > last[2] then last[2] = s[2] end
    else
      merged[#merged + 1] = { s[1], s[2] }
    end
  end
  return merged
end

function Job:write_duck_automation(spans, projlen)
  local cfg = self.S
  local mode = reaper.GetEnvelopeScalingMode(self.ENV)
  local function val(lin) return reaper.ScaleToEnvelopeMode(mode, lin) end
  local UNITY = val(1.0)
  local DUCK  = val(10 ^ (cfg.DUCK_DB / 20))
  -- 既存点をいったん消して、素の0dB＋ダッキングだけにする（元の状態は ENV_CHUNK で後で復元）
  reaper.DeleteEnvelopePointRange(self.ENV, -1.0, projlen + 100.0)
  reaper.InsertEnvelopePoint(self.ENV, 0.0, UNITY, 0, 0, false, true)
  for _, s in ipairs(spans) do
    local a = math.max(0.0, s[1] - cfg.DUCK_PRE - cfg.DUCK_FADE_IN) -- フェード開始(0dB)
    local b = math.max(0.0, s[1] - cfg.DUCK_PRE)                    -- 下げ切り
    local c = s[2]                                                  -- 声の終わりまでキープ
    local d = s[2] + cfg.DUCK_RELEASE                               -- 復帰(0dB)
    reaper.InsertEnvelopePoint(self.ENV, a, UNITY, 0, 0, false, true)
    reaper.InsertEnvelopePoint(self.ENV, b, DUCK,  0, 0, false, true)
    reaper.InsertEnvelopePoint(self.ENV, c, DUCK,  0, 0, false, true)
    reaper.InsertEnvelopePoint(self.ENV, d, UNITY, 0, 0, false, true)
  end
  reaper.InsertEnvelopePoint(self.ENV, projlen + 1.0, UNITY, 0, 0, false, true)
  reaper.Envelope_SortPoints(self.ENV)
end

-- ===========================================================================
-- MASTERチェーンの書き出し（Para + 2mix 専用）
-- ===========================================================================
local VP = nil
do
  local ok, mod = pcall(dofile, DIR .. "tukonya_vstpreset_lib.lua")
  if ok and type(mod) == "table" then VP = mod end
end
C.VP = VP

local function write_binfile(path, data)
  local f, e = io.open(path, "wb")
  if not f then return false, tostring(e) end
  f:write(data)
  f:close()
  return true
end

-- ファイル名に使えない文字を落とす（macOS/Windows両対応）
local function safe_filename(s)
  s = tostring(s or "")
  s = s:gsub("^VST3:%s*", "")
  s = s:gsub("%s*%b()%s*$", "")
  s = s:gsub('[/\\:%*%?"<>|]', "_")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then s = "fx" end
  return s
end

-- トラック状態チャンクから <FXCHAIN ブロックの中身だけを取り出す（入れ子対応）
local function extract_fxchain(chunk)
  local lines = {}
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local start_i, indent = nil, 0
  for i, line in ipairs(lines) do
    local sp = line:match("^(%s*)<FXCHAIN%s*$")   -- 入力FX側の <FXCHAIN_REC は拾わない
    if sp then start_i, indent = i, #sp break end
  end
  if not start_i then return nil, "トラック状態に <FXCHAIN が見つかりません" end
  local body, depth = {}, 1
  for i = start_i + 1, #lines do
    local line = lines[i]
    if line:match("^%s*<") then
      depth = depth + 1
    elseif line:match("^%s*>%s*$") then
      depth = depth - 1
      if depth == 0 then return table.concat(body, "\n") .. "\n" end
    end
    body[#body + 1] = line:sub(indent + 3)
  end
  return nil, "<FXCHAIN の閉じ > が見つかりません"
end
C.extract_fxchain = extract_fxchain

-- 失敗しても例外を投げず注意を積むだけ。ReaInsertの前後でサブフォルダを分ける。
function Job:export_master_chain(dir, reai)
  local cfg = self.S
  if not VP then
    self:warn("部品 tukonya_vstpreset_lib.lua を読み込めませんでした（.vstpresetは作れません）")
  end
  reaper.RecursiveCreateDirectory(dir, 0)
  local pre_dir, post_dir = dir, dir
  if reai ~= nil then
    pre_dir  = dir .. "/" .. cfg.PRE_HW_DIR
    post_dir = dir .. "/" .. cfg.POST_HW_DIR
    reaper.RecursiveCreateDirectory(pre_dir, 0)
    reaper.RecursiveCreateDirectory(post_dir, 0)
  end
  local wrote_any = false
  local function put(path, data)
    local ok, e = write_binfile(path, data)
    if ok then wrote_any = true; self.chain_dir = dir end
    return ok, e
  end

  -- 1) 有効になっているVST3だけ .vstpreset（番号はチェーン順に01から詰める）
  local n = 0
  for i = 0, self.FXN - 1 do
    local _, ftype = reaper.TrackFX_GetNamedConfigParm(self.MASTER, i, "fx_type")
    if self.SAVE_FX[i] and ftype ~= "VST3" and ftype ~= "VST3i" then
      -- 有効なのに VST3 ではない（CLAP / VST2 / AU / JS …）→ .vstpreset は出せない。ReaInsert は対象外。
      local _, nm = reaper.TrackFX_GetFXName(self.MASTER, i, "")
      if not string.find(string.lower(nm or ""), cfg.REAINSERT_MATCH, 1, true) then
        self:warn(("%02d %s: VST3 ではないため .vstpreset 作成をスキップしました。"):format(i + 1, nm or "?"))
      end
    end
    if self.SAVE_FX[i] and ftype == "VST3" then
      n = n + 1
      local _, name  = reaper.TrackFX_GetFXName(self.MASTER, i, "")
      local _, ident = reaper.TrackFX_GetNamedConfigParm(self.MASTER, i, "fx_ident")
      local okc, chunk = reaper.TrackFX_GetNamedConfigParm(self.MASTER, i, "vst_chunk")
      local label = safe_filename(name)
      if not VP then
        -- 部品が無い旨は既に注意済み
      elseif not (okc and chunk and chunk ~= "") then
        self:warn(("%02d %s: 設定データ(vst_chunk)が取れず .vstpreset を作れませんでした"):format(n, label))
      else
        local data, err = VP.vstpreset_from_chunk_b64(ident or "", chunk)
        if not data then
          self:warn(("%02d %s: .vstpreset を組めませんでした（%s）"):format(n, label, tostring(err)))
        else
          local sub = (reai ~= nil and i < reai) and pre_dir or post_dir
          local ok2, e2 = put(("%s/%02d_%s.vstpreset"):format(sub, n, label), data)
          if not ok2 then self:warn(("%02d %s: 書き込み失敗（%s）"):format(n, label, e2)) end
        end
      end
    end
  end

  -- 2) MASTER_CHAIN_for-REAPER.RfxChain（REAPERで丸ごと戻す用）
  local okc, chunk = reaper.GetTrackStateChunk(self.MASTER, "", false)
  if not (okc and chunk) then
    self:warn("MASTER_CHAIN_for-REAPER.RfxChain: トラック状態を読めませんでした")
  else
    local body, err = extract_fxchain(chunk)
    if not body then
      self:warn("MASTER_CHAIN_for-REAPER.RfxChain: " .. tostring(err))
    else
      local ok2, e2 = put(dir .. "/MASTER_CHAIN_for-REAPER.RfxChain", body)
      if not ok2 then self:warn("MASTER_CHAIN_for-REAPER.RfxChain: 書き込み失敗（" .. tostring(e2) .. "）") end
    end
  end
  if not wrote_any then
    self:warn(("MasterChainに1つもファイルを書けませんでした（%s）"):format(dir))
  end
end

-- ===========================================================================
-- タブの流れ
-- ===========================================================================
local FLOW = {}

-- ----- 2mix Render（旧 TUKO_2Stage_HW_Master_Render）-----
function FLOW.mix2(j)
  local cfg = j.S
  j:resolve_range()

  local PAT_U, PAT_AAC, PAT_D, PAT_DEF =
    cfg.PAT_NODITHER, cfg.PAT_AAC, cfg.PAT_DITHERED, cfg.DEFAULT_PATTERN
  local suffix = j:resolve_suffix(function(suf)
    local set = {}
    local wav_u = j:resolve_target(PAT_U .. suf, j.FMT_MASTER)
    set[#set + 1] = wav_u
    set[#set + 1] = j:secondary(wav_u)
    set[#set + 1] = j:secondary(j:resolve_target(PAT_AAC .. suf, j.FMT_MASTER))
    -- ディザー版が出るのは「Ditherトラックがある」ときだけ（無ければ上の1組だけ）
    if not (cfg.DITHER_MODE == "none" or (cfg.DITHER_MODE == "track" and not j.DITHER)) then
      set[#set + 1] = j:resolve_target(PAT_D .. suf, j.FMT_MASTER_D)
    end
    return set
  end)
  PAT_U, PAT_AAC, PAT_D, PAT_DEF =
    PAT_U .. suffix, PAT_AAC .. suffix, PAT_D .. suffix, PAT_DEF .. suffix

  -- 中間ファイルは成果物と同じフォルダに、ぶつからない名前で置く
  local pat_dir = PAT_U:match("^(.-)/[^/]*$") or ""
  local tmp_pattern = (pat_dir == "") and cfg.TMP_PREFIX or (pat_dir .. "/" .. cfg.TMP_PREFIX)

  j:make_stem()
  -- 以降の書き出しはマスターミックス＋選択範囲
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", j.bounds_flag, true)

  if j.hw_mode then
    j:hardware_pass(tmp_pattern, false)
    j:apply_format(j.FMT_MASTER)
  else
    j:apply_format(j.FMT_MASTER)
    j:set_master_original()
  end
  j:render_deliverable({ u = PAT_U, keep_u = true, aac = PAT_AAC, d = PAT_D })
end

-- ----- 2mix Preview（旧 TUKO_2Stage_Preview_Render）-----
function FLOW.preview(j)
  local cfg = j.S
  local spans = j:build_duck_spans()
  if #spans == 0 then
    abort(("『%s』トラックに波形（アイテム）がありません。透かしを置いてから実行してください。"):format(cfg.PREVIEW_TRACK_NAME))
  end
  j:resolve_range()

  local PAT_PREVIEW, PAT_DEF = cfg.PREVIEW_PATTERN, cfg.DEFAULT_PATTERN
  local suffix = j:resolve_suffix(function(suf)
    local set = {}
    local function add_final(p)
      local wav = j:resolve_target(p .. suf, j.FMT_MASTER)
      set[#set + 1] = wav
      set[#set + 1] = j:secondary(wav)
    end
    if cfg.RENDER_CLEAN_TOO then add_final(PAT_DEF) end
    add_final(PAT_PREVIEW)
    return set
  end)
  PAT_PREVIEW, PAT_DEF = PAT_PREVIEW .. suffix, PAT_DEF .. suffix

  local pat_dir = PAT_PREVIEW:match("^(.-)/[^/]*$") or ""
  local tmp_pattern = (pat_dir == "") and cfg.TMP_PREFIX or (pat_dir .. "/" .. cfg.TMP_PREFIX)
  local projlen = reaper.GetProjectLength(0)

  j:make_stem()
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", j.bounds_flag, true)

  -- PREVIEWONLYはMASTERの外側→REAPERマスター直。鳴っているとハード通しの素材に
  -- 焼き付いてしまうので、ハード通しの前に必ずミュートしておく。
  reaper.SetMediaTrackInfo_Value(j.PREVIEW, "B_MUTE", 1)

  if j.hw_mode then
    j:hardware_pass(tmp_pattern, false)
  else
    j:set_master_original()
  end

  -- クリーン版（任意。透かし無し・ダッキング無し・通常のファイル名）
  if cfg.RENDER_CLEAN_TOO then
    j:render_deliverable({ u = cfg.CLEAN_TMP_U, keep_u = false,
                           aac = PAT_DEF, d = PAT_DEF, fallback = PAT_DEF })
  end

  -- 透かし版（声を重ね、ダッキングを書き、_sample名）
  reaper.SetMediaTrackInfo_Value(j.PREVIEW, "B_MUTE", 0)
  j.ENV = reaper.GetTrackEnvelopeByChunkName(j.MASTER, "<VOLENV2")
  if not j.ENV then
    reaper.SetOnlyTrackSelected(j.MASTER)
    reaper.Main_OnCommand(40406, 0) -- Toggle track volume envelope visible（作成）
    j.ENV = reaper.GetTrackEnvelopeByChunkName(j.MASTER, "<VOLENV2")
    j.ENV_CREATED = true
  end
  if not j.ENV then abort("MASTERのボリューム・エンベロープを用意できませんでした。") end
  if not j.ENV_CREATED then
    local ok, chunk = reaper.GetEnvelopeStateChunk(j.ENV, "", false)
    if ok then j.ENV_CHUNK = chunk end
  end
  j:write_duck_automation(spans, projlen)
  j:render_deliverable({ u = cfg.PREVIEW_TMP_U, keep_u = false,
                         aac = PAT_PREVIEW, d = PAT_PREVIEW, fallback = PAT_PREVIEW })
end

-- ----- Para + 2mix（旧 TUKONYA_MasterParaRender）-----
function FLOW.para(j)
  local cfg = j.S
  if #j.restore.sel == 0 then
    abort("パラ用のトラックが選択されていません。\n書き出したいトラックを選択してから実行してください。")
  end
  j:log("選択トラック %d 本", #j.restore.sel)

  -- 納品ファイルの頭に付ける曲名（$song で使うので先に決める）
  local projfile = reaper.GetProjectName(0, "")
  if type(projfile) ~= "string" then projfile = "" end
  local SONG = S.song_name(projfile, cfg.SONG_NAME_RULE, cfg.SONG_STRIP_WORDS, cfg.SONG_NAME_CUSTOM)
  if SONG == "" then
    SONG = "untitled"
    j:warn("プロジェクトがまだ保存されていないため、曲名を untitled にしました。")
  end
  if cfg.SONG_NAME_RULE ~= "title" then SONG = SONG:gsub("[/\\:%*%?\"<>|]", "_"):gsub("%$", "_") end
  j:log("曲名: %s（プロジェクトファイル: %s / 決め方: %s）", SONG,
    projfile == "" and "(未保存)" or projfile, cfg.SONG_NAME_RULE)

  -- 書き出し先の親フォルダ <ベース>
  local cur_pat = j.restore.pattern
  local base
  if cfg.DELIVERY_BASE and cfg.DELIVERY_BASE ~= "" then
    base = S.resolve_delivery_base(cfg.DELIVERY_BASE, SONG)
  else
    base = cur_pat:match("^(.-)/" .. cfg.MIX_SUBFOLDER .. "/")
    if base == nil and cur_pat:match("^" .. cfg.MIX_SUBFOLDER .. "/") then base = "" end
    if base == nil then base = cur_pat end
    -- トラックごとに変わる語が入った区切りは、フォルダが二重に掘られるので末尾から落とす
    local segs = {}
    for seg in (base .. "/"):gmatch("([^/]*)/") do segs[#segs + 1] = seg end
    local function per_track(seg)
      local low = seg:lower()
      return low:find("$track", 1, true) or low:find("$folder", 1, true)
          or low:find("$parenttrack", 1, true) or low:find("$item", 1, true)
    end
    while #segs > 0 and (segs[#segs] == "" or per_track(segs[#segs])) do table.remove(segs) end
    base = table.concat(segs, "/")
  end
  local function sub_pat(folder, name)
    if base == "" then return folder .. "/" .. name end
    return base .. "/" .. folder .. "/" .. name
  end
  local function mpat(name) return sub_pat(cfg.MASTER_SUBFOLDER, name) end
  local PARA_PATTERN = sub_pat(cfg.MIX_SUBFOLDER, "$track")
  j:log("書き出しの土台: %s", base == "" and "(空)" or base)

  local NAME_1   = cfg.NAME_PREMASTER
  local NAME_2   = cfg.NAME_HWINSERT
  local NAME_3   = cfg.NAME_FALLBACK
  local NAME_U   = SONG .. cfg.SUFFIX_NODITHER
  local NAME_D   = SONG .. cfg.SUFFIX_DITHERED
  local NAME_AAC = SONG .. cfg.SUFFIX_AAC

  j:resolve_range()
  -- パラの範囲だけは設定で選べる（"project"=常に全体、"timesel"=マスターと同じ範囲）
  -- paraの範囲。"project"＝常に曲全体（従来どおり）／"bus_items"＝2MIXBUSのアイテムの端から端
  -- ／"timesel"＝いまの選択範囲（無ければ曲全体）。
  local para_bounds, para_range = 1, nil
  if cfg.PARA_RANGE == "bus_items" then
    local n = reaper.CountTrackMediaItems(j.BUS)
    local mn, mx
    for i = 0, n - 1 do
      local it = reaper.GetTrackMediaItem(j.BUS, i)
      local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local b = a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if not mn or a < mn then mn = a end
      if not mx or b > mx then mx = b end
    end
    if mn then para_bounds, para_range = 2, { mn, mx }
    else j:warn("paraの範囲に「2MIXBUSのアイテム」を選びましたが、アイテムがないので曲全体で書き出しました。") end
  elseif cfg.PARA_RANGE == "timesel" then
    local a, b = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if (b - a) > 0.0000001 then para_bounds, para_range = 2, { a, b }
    else j:warn("paraの範囲に「選択範囲」を選びましたが、選択範囲がないので曲全体で書き出しました。") end
  end

  -- 同名ファイルの自動連番。対象はMasterフォルダの全ファイル。
  -- パラ（Mixフォルダ）は対象外＝REAPER自身の同名ファイル処理に任せる（従来どおり）。
  local suffix = j:resolve_suffix(function(suf)
    local set = {}
    set[#set + 1] = j:resolve_target(mpat(NAME_1 .. suf), j.FMT_STEM)
    set[#set + 1] = j:resolve_target(mpat(NAME_2 .. suf), j.FMT_STEM)
    set[#set + 1] = j:resolve_target(mpat(NAME_U .. suf), j.FMT_MASTER)
    if j.FMT2_EXT then
      set[#set + 1] = j:secondary(j:resolve_target(mpat(NAME_AAC .. suf), j.FMT_MASTER))
    end
    -- ディザー版が出るのは「Ditherトラックがある」ときだけ（無ければ上の1組だけ）
    if not (cfg.DITHER_MODE == "none" or (cfg.DITHER_MODE == "track" and not j.DITHER)) then
      set[#set + 1] = j:resolve_target(mpat(NAME_D .. suf), j.FMT_MASTER_D)
    end
    return set
  end)
  NAME_1, NAME_2, NAME_3 = NAME_1 .. suffix, NAME_2 .. suffix, NAME_3 .. suffix
  NAME_U, NAME_D, NAME_AAC = NAME_U .. suffix, NAME_D .. suffix, NAME_AAC .. suffix

  -- ステム化を最速に
  reaper.SNM_SetIntConfigVar("workrender", j.restore.workrender & (~8))

  -- ============ A. パラデータ ============
  local keep_S, keep_E = j.RANGE_S, j.RANGE_E
  if para_range then j.RANGE_S, j.RANGE_E = para_range[1], para_range[2] end
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", para_bounds, true)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.stems_only, true)
  j:set_pattern(PARA_PATTERN)
  j:apply_format(j.FMT_STEM)
  do  -- パラの置き場（Mixフォルダ）の絶対パスを、REAPER自身に解かせて控える
    local t = j:target()
    j.MIX_DIR = t and t:match("^(.*)[/\\]") or nil
    j:log("パラの置き場: %s", tostring(j.MIX_DIR))
  end
  j:set_master_all(false)
  reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- オフライン最速

  local function para_name(tr)
    local _, nm = reaper.GetTrackName(tr)
    nm = (nm or "track"):gsub("[/\\:%*%?\"<>|]", "_"):gsub("%$", "_")  -- $ はワイルドカード扱いを避ける
    return nm
  end
  -- Mix/ の下に置く相対パス。REAPERのフォルダ構造をそのまま再現し、BUSとMASTERの階層だけ抜く。
  local function para_relpath(T)
    local parts = { para_name(T) }
    if cfg.PARA_KEEP_FOLDERS then
      local p = reaper.GetParentTrack(T)
      while p and p ~= j.BUS and p ~= j.MASTER do
        table.insert(parts, 1, para_name(p))
        p = reaper.GetParentTrack(p)
      end
    end
    return table.concat(parts, "/")
  end

  if cfg.PARA_SOLO_EACH or cfg.PARA_VIA_PARENT then
    if cfg.PARA_SOLO_EACH and cfg.PARA_SOLO_MASTERMIX and not cfg.DRY_RUN then
      reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix, true)
    end
    local plan = {}
    for _, T in ipairs(j.restore.sel) do
      if reaper.ValidatePtr(T, "MediaTrack*") then
        -- 1本ごとに、この実行の最初に控えた状態へ戻してから組み直す
        restore_all("B_MUTE", j.restore.mute)
        restore_all("B_MAINSEND", j.restore.mainsend)
        restore_sendmutes(j.restore.sendmute)
        local pl = cfg.PARA_VIA_PARENT and build_para_plan(j, T) or nil
        local P = pl and pl.P or T
        local _, tn = reaper.GetTrackName(T); local _, pn = reaper.GetTrackName(P)
        local line
        if pl then
          line = ("%s\n  出力: %s/%s\n  親P: %s%s\n  ミュート: %s\n  生かしたキー元: %s\n  メインセンドを切った: %s\n  送り単位で切った: %s\n  混じる可能性: %s\n  %sの外のキー元は触らない: %s"):format(
            tn, cfg.MIX_SUBFOLDER, para_relpath(T), pn, (P == T) and "（自分）" or "",
            joinnames(pl.muted), joinnames(pl.keep), joinnames(pl.keep_cut),
            plan_sendmute_names(pl),
            #pl.bleed > 0 and table.concat(pl.bleed, " / ") or "なし",
            pn, joinnames(pl.outside))
        else
          line = ("%s\n  出力: %s/%s\n  親P: %s（自分。親トラック経由は切）\n  ミュート: なし"):format(
            tn, cfg.MIX_SUBFOLDER, para_relpath(T), pn)
        end
        plan[#plan + 1] = line
        j:log_plain(line)
        -- 規則4: 混じりが残るときは、窓からの実行だけ「続行／キャンセル」を出す
        if pl and #pl.bleed > 0 then
          j:log("混じる可能性: %s", table.concat(pl.bleed, " / "))
          if C.BLEED_DIALOG and cfg.INTERACTIVE and not cfg.DRY_RUN then
            local msg = ("『%s』の書き出しで、ほかのトラックの音が混じる可能性があります。\n\n%s\n\n続けますか？")
              :format(tn, table.concat(pl.bleed, "\n"))
            if reaper.ShowMessageBox(msg, "TUKONYA RENDER", 1) ~= 1 then  -- 1 = OK / それ以外 = キャンセル
              abort("混じりの確認で「キャンセル」が押されたので、書き出しを止めました。")
            end
          end
        end
        if cfg.DRY_RUN then
          -- 計画を出すだけ（何も書き出さない）
        else
          -- ミュートを実際に使うときだけ、クリック防止フェードを 0 にする（後片付けで戻す）。
          -- これをしないと、ミュートを戻したあとの書き出しの頭 5 ms にフェードが乗る。
          if pl and next(pl.muted) ~= nil and not j.mutefade_off
             and j.restore.mutefade and j.restore.mutefade >= 0 then
            reaper.SNM_SetIntConfigVar("mutefadems10", 0)
            j.mutefade_off = true
            j:log("ミュート切り替えのフェードを 0 にした（元 %d ＝ %.1f ms。後片付けで戻す）",
                  j.restore.mutefade, j.restore.mutefade / 10)
          end
          if pl then apply_para_plan(pl) end
          if cfg.PARA_SOLO_EACH then
            for i = 0, reaper.CountTracks(0) - 1 do
              reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO", 0)
            end
            reaper.SetMediaTrackInfo_Value(P, "I_SOLO", 2) -- 2 = solo in place
          end
          reaper.SetOnlyTrackSelected(P)
          j:set_pattern(sub_pat(cfg.MIX_SUBFOLDER, para_relpath(T)))  -- 名前とフォルダは常にT基準
          j:log("パラ書き出し: %s", tn)
          j:render(j:target())
          j.para_count = j.para_count + 1
        end
      end
    end
    restore_all("B_MUTE", j.restore.mute)
    restore_all("I_SOLO", j.restore.solo)
    restore_all("B_MAINSEND", j.restore.mainsend)
    restore_sendmutes(j.restore.sendmute)
    if cfg.DRY_RUN then
      local txt = "=== パラ書き出しの計画（DRY_RUN、何も書き出していません）===\n" .. table.concat(plan, "\n") .. "\n"
      reaper.ShowConsoleMsg(txt)
      abort("DRY_RUN=true のため、計画をコンソールと実行記録に出して終了しました。")
    end
  elseif cfg.PARA_KEEP_FOLDERS then
    -- フォルダ構造を再現するため、ソロもミュートもせず1トラックずつ書き出し先を指定する
    for _, T in ipairs(j.restore.sel) do
      if reaper.ValidatePtr(T, "MediaTrack*") then
        local _, tn = reaper.GetTrackName(T)
        reaper.SetOnlyTrackSelected(T)
        j:set_pattern(sub_pat(cfg.MIX_SUBFOLDER, para_relpath(T)))
        j:log("パラ書き出し: %s → %s/%s", tn, cfg.MIX_SUBFOLDER, para_relpath(T))
        j:render(j:target())
        j.para_count = j.para_count + 1
      end
    end
  else
    j:log("パラ書き出し: 選択トラックを一括")
    j:render(j:target())
    j.para_count = #j.restore.sel
  end
  j:log("パラ書き出し完了")
  -- パラのあいだだけ差し替えていた範囲を、マスターの範囲へ戻す
  j.RANGE_S, j.RANGE_E = keep_S, keep_E
  j:apply_range()

  -- ============ マスター用: 2MIXBUSをステム化 ============
  j:make_stem()
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", j.bounds_flag, true)

  -- ============ MASTERチェーンの書き出し（音の書き出しの前に1回だけ）============
  do
    j:set_master_original()
    j:apply_format(j.FMT_MASTER)
    j:set_pattern(mpat(NAME_3))
    local first = j:target()
    local dir = first and first:match("^(.*)[/\\]") or nil
    if not dir or dir == "" then
      j:warn("書き出し先フォルダが分からず、MasterChain（プラグイン設定）を出せませんでした。")
    elseif not cfg.EXPORT_MASTER_CHAIN then
      j:log("MasterChainの書き出しは設定で無効")
    else
      j:log("MasterChain書き出し: %s", dir .. "/" .. cfg.CHAIN_SUBFOLDER)
      local okx, ex = pcall(function()
        j:export_master_chain(dir .. "/" .. cfg.CHAIN_SUBFOLDER, j.hw_mode and j.reai or nil)
      end)
      if not okx then j:warn("MasterChainの書き出しで予期しないエラー: " .. tostring(ex)) end
    end
  end

  -- ============ 1. 2MIXBUS(premaster) ============
  j:apply_format(j.FMT_STEM)
  j:set_master_all(false)
  j:set_pattern(mpat(NAME_1))
  reaper.SNM_SetIntConfigVar("projrenderlimit", 0)
  local p1 = j:target()
  j:log("#1 %s 書き出し", NAME_1)
  j:render(p1)
  j:add_produced(p1)

  local pat = { u = mpat(NAME_U), keep_u = true, aac = mpat(NAME_AAC), d = mpat(NAME_D) }
  if j.hw_mode then
    -- ============ 2. HardwareInsert（オンライン＝ハード通し。納品物として残す）============
    j:hardware_pass(mpat(NAME_2), true)
    j:render_deliverable(pat)
  else
    j:set_master_original()
    j:render_deliverable(pat)
  end
end

-- ===========================================================================
-- Hardware Print（旧 TUKO_VoComp_Render）
-- ---------------------------------------------------------------------------
-- 他の3タブと違い「選んだアイテム」が対象で、2MIXBUS も Dither も使わない。
-- そのため下ごしらえと後片付けも専用のものを使う（C.PREPARE / C.CLEANUP）。
-- 旧スクリプトの並べ替え処理（insert_leaf ほか）は、出来上がるトラックの形が
-- 1段でも変わると別物になるので、そのまま写した。
-- ===========================================================================
local function hw_trname(tr)
  if not tr then return "(なし)" end
  if tr == reaper.GetMasterTrack(0) then return "MASTER(REAPER)" end
  local _, nm = reaper.GetTrackName(tr)
  return nm or "?"
end

local function split_semi(s)
  local out = {}
  for raw in tostring(s or ""):gmatch("[^;]+") do
    local part = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end

local function track_index(tr) -- 0始まり
  return to_int(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
end
local function depth_of(tr) return to_int(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")) end
local function set_depth(tr, d) reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", d) end

-- 入れ子の深さ（GetParentTrack を何回たどれるか）
local function level_of(tr)
  local n, p = 0, reaper.GetParentTrack(tr)
  while p do n = n + 1; p = reaper.GetParentTrack(p) end
  return n
end

local function hw_is_ancestor(anc, tr)
  local p = reaper.GetParentTrack(tr)
  while p do
    if p == anc then return true end
    p = reaper.GetParentTrack(p)
  end
  return false
end

local function children_of(P)
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetParentTrack(tr) == P then out[#out + 1] = tr end
  end
  return out
end

-- P の配下で一番最後のトラック。配下が無ければ P 自身。
local function last_descendant(P)
  local last = P
  for i = track_index(P) + 1, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if hw_is_ancestor(P, tr) then last = tr else break end
  end
  return last
end

local function find_child_named(P, name)
  for _, tr in ipairs(children_of(P)) do
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then return tr end
  end
  return nil
end

-- 親子関係の写し（GUID→親GUID）。並べ替えのたびに壊れていないか見るため。
local function parent_map()
  local m = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local p = reaper.GetParentTrack(tr)
    m[reaper.GetTrackGUID(tr)] = p and reaper.GetTrackGUID(p) or "-"
  end
  return m
end

local function check_parents(snapshot)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local g = reaper.GetTrackGUID(tr)
    local want = snapshot[g]
    if want then
      local p = reaper.GetParentTrack(tr)
      local got = p and reaper.GetTrackGUID(p) or "-"
      if got ~= want then
        return ("トラック『%s』の親が変わってしまいました"):format(hw_trname(tr))
      end
    end
  end
  return nil
end

-- P の直下の末尾に、普通の（フォルダでない）トラックを1本足す。
local function insert_leaf(P, name)
  local D = last_descendant(P)
  local newtr
  if D == P then
    local p_old = depth_of(P)
    local idx = track_index(P) + 1
    reaper.InsertTrackAtIndex(idx, false)
    newtr = reaper.GetTrack(0, idx)
    set_depth(P, 1)
    set_depth(newtr, (p_old <= 0) and (p_old - 1) or -1)
  else
    local d_old = depth_of(D)
    local j = level_of(D) - level_of(P) - 1
    local idx = track_index(D) + 1
    reaper.InsertTrackAtIndex(idx, false)
    newtr = reaper.GetTrack(0, idx)
    set_depth(D, -j)
    set_depth(newtr, d_old + j)
  end
  reaper.GetSetMediaTrackInfo_String(newtr, "P_NAME", name, true)
  return newtr
end

C.hw_helpers = { insert_leaf = insert_leaf, check_parents = check_parents,
                 parent_map = parent_map, children_of = children_of,
                 last_descendant = last_descendant, split_semi = split_semi }

-- ----- 下ごしらえ（Hardware Print 専用）-----
function Job:hw_prepare()
  if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar) then
    abort("SWS/S&M拡張が見つかりません。SWSをインストールしてください。")
  end
  local r = self.restore
  r.sel = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do r.sel[#r.sel + 1] = reaper.GetSelectedTrack(0, i) end
  r.projrenderlimit = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", 2))
  r.mutefade        = to_int(reaper.SNM_GetIntConfigVar("mutefadems10", -1))  -- 控えるだけ（Hardware Printでは触らない）
  r.render_settings = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  r.bounds          = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
  r.addtoproj       = reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, false)
  local _, cur_pat  = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
  local _, cur_fmt  = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  "", false)
  local _, cur_fmt2 = reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", "", false)
  r.pattern, r.format, r.format2 = cur_pat, cur_fmt, cur_fmt2
  r.srate     = reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)
  r.channels  = reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 0, false)
  r.dither    = reaper.GetSetProjectInfo(0, "RENDER_DITHER", 0, false)
  r.normalize = reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", 0, false)
  self.hw_fxen   = {}   -- GUID（またはキー "MASTER"）→ 元の I_FXEN
  self.hw_volpan = {}   -- GUID → 元の {vol, pan}
  self.hw_origvp = {}   -- GUID → 素通しにする前の {vol, pan}（compressed側へ写すのに使う）
  self.hw_problems, self.hw_envwarn = {}, {}
  self:log("元のレンダー設定を控えた（パターン: %s）", tostring(cur_pat))

  -- 書き出し先フォルダ。窓で指定されたときだけ差し替える（空なら今の設定のまま）。
  if type(self.S.OUTPUT_DIR) == "string" and self.S.OUTPUT_DIR ~= "" then
    local _, cur_file = reaper.GetSetProjectInfo_String(0, "RENDER_FILE", "", false)
    r.render_file = cur_file
    local dir = (self.S.OUTPUT_DIR:gsub("[/\\]+$", ""))
    reaper.RecursiveCreateDirectory(dir, 0)
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
    self:log("書き出し先フォルダ: %s（窓の指定）", dir)
  end
end

-- ----- 後片付け（Hardware Print 専用。旧スクリプトの cleanup と同じ順序）-----
function Job:hw_cleanup()
  local r = self.restore
  self:log("後片付け開始")
  local byguid = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    byguid[reaper.GetTrackGUID(tr)] = tr
  end
  local problems = self.hw_problems or {}
  -- 途中で落ちたときだけ、取り込んだトラックと書き出したファイルを片付ける
  if not self.hw_done then
    for _, tr in ipairs(self.created_tracks) do
      if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.DeleteTrack(tr) end
    end
    for _, f in ipairs(self.temp_files) do
      pcall(os.remove, f)
      pcall(os.remove, f .. ".reapeaks")
    end
  end
  for key, v in pairs(self.hw_fxen or {}) do
    if key == "MASTER" then
      reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "I_FXEN", v)
    else
      local tr = byguid[key]
      if not tr then
        problems[#problems + 1] = "FXのON/OFFを元に戻せませんでした（トラックが見つかりません）"
      else
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", v)
        if math.abs(reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") - v) > 1e-9 then
          problems[#problems + 1] = ("『%s』のFXのON/OFFを元に戻せませんでした"):format(hw_trname(tr))
        end
      end
    end
  end
  for g, v in pairs(self.hw_volpan or {}) do
    local tr = byguid[g]
    if not tr then
      problems[#problems + 1] = "フェーダー／パンを元に戻せませんでした（トラックが見つかりません）"
    else
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", v.vol)
      reaper.SetMediaTrackInfo_Value(tr, "D_PAN", v.pan)
      if math.abs(reaper.GetMediaTrackInfo_Value(tr, "D_VOL") - v.vol) > 1e-9
         or math.abs(reaper.GetMediaTrackInfo_Value(tr, "D_PAN") - v.pan) > 1e-9 then
        problems[#problems + 1] = ("『%s』のフェーダー／パンを元に戻せませんでした"):format(hw_trname(tr))
      end
    end
  end
  if r.render_settings ~= nil then reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", r.render_settings, true) end
  if r.bounds    ~= nil then reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", r.bounds, true) end
  if r.addtoproj ~= nil then reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", r.addtoproj, true) end
  if r.pattern   ~= nil then self:set_pattern(r.pattern) end
  if r.render_file ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FILE", r.render_file, true) end
  if r.format    ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT",  r.format,  true) end
  if r.format2   ~= nil then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT2", r.format2, true) end
  if r.srate     ~= nil then reaper.GetSetProjectInfo(0, "RENDER_SRATE",     r.srate,     true) end
  if r.channels  ~= nil then reaper.GetSetProjectInfo(0, "RENDER_CHANNELS",  r.channels,  true) end
  if r.dither    ~= nil then reaper.GetSetProjectInfo(0, "RENDER_DITHER",    r.dither,    true) end
  if r.normalize ~= nil then reaper.GetSetProjectInfo(0, "RENDER_NORMALIZE", r.normalize, true) end
  if r.projrenderlimit ~= nil then reaper.SNM_SetIntConfigVar("projrenderlimit", r.projrenderlimit) end
  if r.mutefade ~= nil and r.mutefade >= 0 and self.mutefade_off then
    reaper.SNM_SetIntConfigVar("mutefadems10", r.mutefade)
  end
  if r.sel then
    reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    for _, tr in ipairs(r.sel) do
      if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.SetTrackSelected(tr, true) end
    end
  end
  for _, l in ipairs(problems) do self:warn(l) end
  self.hw_problems = {}
  self:log("後片付け完了")
end

-- ----- 本体 -----
function FLOW.hwprint(j)
  local cfg = j.S

  -- --- 1. 選択アイテムとそのトラック ---
  local nsel = reaper.CountSelectedMediaItems(0)
  if nsel == 0 then
    abort("アイテムが1つも選ばれていません。\n書き出したいアイテムを選んでから実行してください。")
  end
  local src, item_tracks, seen_tr = {}, {}, {}
  for i = 0, nsel - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local tr = reaper.GetMediaItem_Track(it)
    src[#src + 1] = {
      item = it, tr = tr,
      pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
      len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
      trnm = hw_trname(tr),
    }
    local g = reaper.GetTrackGUID(tr)
    if not seen_tr[g] then seen_tr[g] = true; item_tracks[#item_tracks + 1] = tr end
  end
  j:log("選択アイテム %d 個 / トラック %d 本", nsel, #item_tracks)

  -- --- 2. ハードの通り道（有効なReaInsertのあるトラック）を探す ---
  local hw_of, missing, bypassed = {}, {}, {}
  for _, tr in ipairs(item_tracks) do
    local cur, found = tr, nil
    while cur do
      for fx = 0, reaper.TrackFX_GetCount(cur) - 1 do
        local _, nm = reaper.TrackFX_GetFXName(cur, fx, "")
        if nm and string.find(string.lower(nm), cfg.REAINSERT_MATCH, 1, true)
           and reaper.TrackFX_GetEnabled(cur, fx) then
          found = cur; break
        end
      end
      if found then break end
      cur = reaper.GetParentTrack(cur)
    end
    if not found then
      missing[#missing + 1] = hw_trname(tr)
    else
      if to_int(reaper.GetMediaTrackInfo_Value(found, "I_FXEN")) == 0 then
        bypassed[#bypassed + 1] = hw_trname(found)
      end
      hw_of[reaper.GetTrackGUID(tr)] = found
    end
  end
  if #missing > 0 then
    abort(("次のトラックには、ハードの通り道（有効なReaInsert）が見つかりません:\n  ・%s\n\n何も変更せずに中断しました。")
      :format(table.concat(missing, "\n  ・")))
  end
  if #bypassed > 0 then
    abort(("ハードの通り道のトラック『%s』は、FX全体がバイパス（OFF）になっています。\nハードを通らない録音になるため中断しました。")
      :format(table.concat(bypassed, "』『")))
  end

  -- --- 3. レンダー設定 ---
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 64, true)   -- 選択アイテムをマスター経由
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)  -- 選択アイテムの範囲
  j:set_pattern(cfg.HW_PATTERN)
  j:apply_format(j.FMT_MASTER, true)   -- テール（尻尾）の設定には触らない（旧スクリプトと同じ）
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", to_int(j.restore.addtoproj) | 1, true)

  reaper.SNM_SetIntConfigVar("projrenderlimit", 2) -- Online Render（ハード通しは必須）
  local chk = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", -1))
  if chk ~= 2 then
    abort(("レンダー速度を Online にできませんでした（現在値=%d）。\nハードを通らない録音を防ぐため中断します。"):format(chk))
  end

  -- 書き出し先の下見（上書きはしない。連番も付けない＝旧スクリプトと同じ）
  local _, targets_s = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
  local targets = split_semi(targets_s)
  if #targets == 0 then
    abort("書き出すファイルがありません（レンダー設定の書き出し先が空です）。\n中断しました。")
  end
  local exist = {}
  for _, p in ipairs(targets) do
    if reaper.file_exists(p) then exist[#exist + 1] = p end
  end
  if #exist > 0 then
    abort(("書き出し先に同じ名前のファイルがもうあります（上書きしないため中断しました）:\n  ・%s\n\n古いファイルを移動してから、もう一度実行してください。")
      :format(table.concat(exist, "\n  ・")))
  end
  j:log("書き出すファイル: %d本", #targets)

  -- レンダー後のアイテムの長さの余裕（テール設定ぶん）
  local tailflag = to_int(reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, false))
  local tailms   = reaper.GetSetProjectInfo(0, "RENDER_TAILMS", 0, false)
  local tail_tol = ((tailflag & 16) ~= 0) and (tailms / 1000.0) or 0.0

  -- --- 4. ハードのトラックより上のフォルダのFXを一時的にOFF ---
  local bypassed_names = {}
  local function bypass(tr, key)
    if j.hw_fxen[key] ~= nil then return end
    j.hw_fxen[key] = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")
    reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
    bypassed_names[#bypassed_names + 1] = hw_trname(tr)
  end
  for _, tr in ipairs(item_tracks) do
    local up = reaper.GetParentTrack(hw_of[reaper.GetTrackGUID(tr)])
    while up do
      bypass(up, reaper.GetTrackGUID(up))
      up = reaper.GetParentTrack(up)
    end
  end
  if cfg.BYPASS_MASTER_TRACK then bypass(reaper.GetMasterTrack(0), "MASTER") end

  -- --- 5. フェーダー0dB／パンセンターへ（書き出しのあいだだけ）---
  local volpan_tracks, vol_pan_changed = {}, {}
  if cfg.RESET_VOL_PAN then
    local vp_tracks, vp_seen = {}, {}
    for _, tr in ipairs(item_tracks) do
      local cur = tr
      while cur do
        local g = reaper.GetTrackGUID(cur)
        if not vp_seen[g] then vp_seen[g] = true; vp_tracks[#vp_tracks + 1] = cur end
        cur = reaper.GetParentTrack(cur)
      end
    end
    for _, tr in ipairs(vp_tracks) do
      local g = reaper.GetTrackGUID(tr)
      local v = reaper.GetMediaTrackInfo_Value(tr, "D_VOL")
      local p = reaper.GetMediaTrackInfo_Value(tr, "D_PAN")
      j.hw_origvp[g] = { vol = v, pan = p }
      if math.abs(v - 1.0) > 1e-9 or math.abs(p) > 1e-9 then
        j.hw_volpan[g] = { vol = v, pan = p }
        reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1.0)
        reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0.0)
        volpan_tracks[#volpan_tracks + 1] = tr
        vol_pan_changed[#vol_pan_changed + 1] =
          ("%s: フェーダー %s ／ パン %+.0f%%"):format(hw_trname(tr),
            (v > 0) and string.format("%.1fdB", 20 * math.log(v, 10)) or "-inf", p * 100)
      end
      local function active_env(chunkname)
        local env = reaper.GetTrackEnvelopeByChunkName(tr, chunkname)
        if not env then return false end
        local okc, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
        if not okc or not chunk then return false end
        return chunk:match("[\r\n]ACT 1") ~= nil
      end
      if active_env("<VOLENV2") or active_env("<PANENV2") then
        j.hw_envwarn[#j.hw_envwarn + 1] = hw_trname(tr)
      end
    end
  end
  for _, l in ipairs(vol_pan_changed) do j:log_plain("  素通しにした: " .. l) end

  -- --- 6. レンダー実行 ---
  local parents_before = parent_map()
  local before = guid_set_of_all_tracks()
  local t0 = os.clock()
  -- [試験用の注入点 hwprint]
  reaper.PreventUIRefresh(-1)     -- 実時間レンダーの進み具合を見せる
  reaper.Main_OnCommand(42230, 0) -- 直近のレンダー設定でレンダー（ダイアログ自動クローズ）
  reaper.PreventUIRefresh(1)
  j:log("パス完了（%.2f 秒）: %d 本", os.clock() - t0, #targets)

  local added = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not before[reaper.GetTrackGUID(tr)] then added[#added + 1] = tr end
  end
  -- 途中で落ちたときに片付けられるように控える（最後まで行けば消さない）
  for _, tr in ipairs(added) do j.created_tracks[#j.created_tracks + 1] = tr end
  for _, p in ipairs(targets) do j.temp_files[#j.temp_files + 1] = p end
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", j.restore.addtoproj, true)

  -- 判断10: 書き出したファイルが本当に在るか（長さは範囲が「選択アイテム」なので見ない）
  for _, p in ipairs(targets) do j:verify(p) end
  if #added == 0 then
    abort("レンダーの結果をプロジェクトに取り込めませんでした（新しいトラックが作られませんでした）。\n書き出し自体が失敗している可能性があります。")
  end

  -- --- 7. compressed の中へ並べ直す ---
  local RAW  = find_track_by_name(cfg.RAW_TRACK_NAME)
  local DEST = find_track_by_name(cfg.DEST_TRACK_NAME)
  local moved, unmatched, tree_lines, carried = {}, {}, {}, {}
  local dest_ok = false
  local problems = j.hw_problems

  -- raw側トラックの「素通しにする前」のフェーダー／パンを、compressed側のトラックへ写す
  local function apply_orig_vp(dst, srctr)
    if not (dst and srctr) then return end
    local o = j.hw_origvp[reaper.GetTrackGUID(srctr)]
    local v = o and o.vol or reaper.GetMediaTrackInfo_Value(srctr, "D_VOL")
    local p = o and o.pan or reaper.GetMediaTrackInfo_Value(srctr, "D_PAN")
    reaper.SetMediaTrackInfo_Value(dst, "D_VOL", v)
    reaper.SetMediaTrackInfo_Value(dst, "D_PAN", p)
  end

  if not DEST then
    j:warn(("『%s』という名前のトラックが見つかりません。書き出した音はREAPERが作ったトラックに置いたままにしました。")
      :format(cfg.DEST_TRACK_NAME))
  else
    if not RAW then
      j:warn(("『%s』という名前のトラックが見つかりません。フォルダの形はまねできないので、全部『%s』の直下に置きました。")
        :format(cfg.RAW_TRACK_NAME, cfg.DEST_TRACK_NAME))
    end

    local relpath = {}
    for _, tr in ipairs(item_tracks) do
      local chain, cur = {}, reaper.GetParentTrack(tr)
      local inside = false
      while cur do
        if RAW and cur == RAW then inside = true; break end
        table.insert(chain, 1, cur)
        cur = reaper.GetParentTrack(cur)
      end
      if not inside then
        chain = {}
        if RAW then
          j:warn(("『%s』は『%s』フォルダの中にありません。『%s』の直下に置きました。")
            :format(hw_trname(tr), cfg.RAW_TRACK_NAME, cfg.DEST_TRACK_NAME))
        end
      end
      relpath[reaper.GetTrackGUID(tr)] = chain
    end

    local dest_leaf, tree_ok = {}, true
    for _, tr in ipairs(item_tracks) do
      if not tree_ok then break end
      local P = DEST
      for _, src_folder in ipairs(relpath[reaper.GetTrackGUID(tr)]) do
        local folder_name = hw_trname(src_folder)
        local snap = parent_map()
        local c = find_child_named(P, folder_name)
        if not c then
          c = insert_leaf(P, folder_name)
          apply_orig_vp(c, src_folder)
          local bad = check_parents(snap)
          if bad then
            problems[#problems + 1] = "トラックの並べ替えで矛盾が出たため、途中でやめました: " .. bad
            tree_ok = false; break
          end
        end
        P = c
      end
      if not tree_ok then break end
      local leafname = hw_trname(tr)
      local snap = parent_map()
      local leaf = find_child_named(P, leafname)
      if not leaf then
        leaf = insert_leaf(P, leafname)
        local bad = check_parents(snap)
        if bad then
          problems[#problems + 1] = "トラックの並べ替えで矛盾が出たため、途中でやめました: " .. bad
          tree_ok = false; break
        end
      end
      dest_leaf[reaper.GetTrackGUID(tr)] = leaf
    end

    dest_ok = tree_ok
    if tree_ok then
      local used = {}
      for _, atr in ipairs(added) do
        for i = reaper.CountTrackMediaItems(atr) - 1, 0, -1 do
          local it = reaper.GetTrackMediaItem(atr, i)
          local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
          local len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
          local fname = ""
          local tk = reaper.GetActiveTake(it)
          if tk and not reaper.TakeIsMIDI(tk) then
            local s = reaper.GetMediaItemTake_Source(tk)
            if s then fname = reaper.GetMediaSourceFileName(s, "") or "" end
          end

          local cand = {}
          for si, s in ipairs(src) do
            if not used[si]
               and math.abs(pos - s.pos) <= 0.001
               and len >= s.len - 0.001 and len <= s.len + tail_tol + 0.001 then
              cand[#cand + 1] = si
            end
          end
          if #cand > 1 then
            local narrowed = {}
            for _, si in ipairs(cand) do
              if fname ~= "" and string.find(fname, src[si].trnm, 1, true) then narrowed[#narrowed + 1] = si end
            end
            -- 「Vo harm」と「Vo harm1」のように名前が包含関係にあると両方当たるので、
            -- 一番長い（＝一番細かく一致した）トラック名だけを残す
            if #narrowed > 1 then
              local best = 0
              for _, si in ipairs(narrowed) do best = math.max(best, #src[si].trnm) end
              local longest = {}
              for _, si in ipairs(narrowed) do
                if #src[si].trnm == best then longest[#longest + 1] = si end
              end
              narrowed = longest
            end
            if #narrowed >= 1 then cand = narrowed end
          end

          if #cand == 1 then
            local s = src[cand[1]]
            local leaf = dest_leaf[reaper.GetTrackGUID(s.tr)]
            if leaf and reaper.MoveMediaItemToTrack(it, leaf) then
              used[cand[1]] = true
              moved[#moved + 1] = ("%s → %s"):format(fname:match("[^/\\]+$") or "?", hw_trname(leaf))
            else
              unmatched[#unmatched + 1] = (fname:match("[^/\\]+$") or "?")
            end
          else
            unmatched[#unmatched + 1] = (fname:match("[^/\\]+$") or "?")
              .. ((#cand == 0) and "（元のアイテムと結び付けられません）" or "（候補が複数あり決められません）")
          end
        end
      end

      for _, tr in ipairs(item_tracks) do
        local leaf = dest_leaf[reaper.GetTrackGUID(tr)]
        if leaf then
          apply_orig_vp(leaf, tr)
          carried[#carried + 1] = ("%s → %s: D_VOL=%.6f D_PAN=%.6f"):format(hw_trname(tr), hw_trname(leaf),
            reaper.GetMediaTrackInfo_Value(leaf, "D_VOL"), reaper.GetMediaTrackInfo_Value(leaf, "D_PAN"))
        end
      end

      -- 空になったREAPERのトラックを消す
      for i = #added, 1, -1 do
        local atr = added[i]
        if reaper.ValidatePtr(atr, "MediaTrack*") and reaper.CountTrackMediaItems(atr) == 0 then
          local snap = parent_map()
          snap[reaper.GetTrackGUID(atr)] = nil
          reaper.DeleteTrack(atr)
          local bad = check_parents(snap)
          if bad then problems[#problems + 1] = "トラックを消したあとに矛盾が出ました: " .. bad end
        end
      end
    end

    local bad = check_parents(parents_before)
    if bad then problems[#problems + 1] = "最後の確認で矛盾が見つかりました: " .. bad end

    local function dump(P, indent)
      for _, c in ipairs(children_of(P)) do
        tree_lines[#tree_lines + 1] = ("%s%s（アイテム%d個）"):format(indent, hw_trname(c), reaper.CountTrackMediaItems(c))
        dump(c, indent .. "    ")
      end
    end
    tree_lines[#tree_lines + 1] = hw_trname(DEST)
    dump(DEST, "    ")
  end

  -- ここまで来たら成功。取り込んだトラックとファイルは片付けない。
  j.hw_done = true
  j.created_tracks = {}
  j.temp_files = {}
  for _, p in ipairs(targets) do j:add_produced(p) end
  j.hw = { targets = targets, moved = moved, unmatched = unmatched, tree = tree_lines,
           bypassed = bypassed_names, dest_ok = dest_ok, carried = carried,
           vol_pan_changed = vol_pan_changed,
           out_dir = (targets[1] or ""):match("^(.*)/[^/]*$") }
  for _, l in ipairs(tree_lines) do j:log_plain("  " .. l) end
end

C.PREPARE = { hwprint = Job.hw_prepare }
C.CLEANUP = { hwprint = Job.hw_cleanup }

C.FLOW = FLOW

-- ===========================================================================
-- 入口
-- ===========================================================================
-- cfg … 設定の表（TAB が入っていること）
-- 戻り値: 結果の表
--   { ok=true/false, aborted=…, err=…, job=… }
function C.run(cfg)
  local j, why = C.new(cfg)
  if not j then return { ok = false, aborted = "設定が正しくありません: " .. tostring(why) } end
  local flow = FLOW[cfg.TAB]
  if not flow then return { ok = false, aborted = "知らないタブです: " .. tostring(cfg.TAB) } end

  j:open_log()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- タブによって下ごしらえ・後片付けを差し替える（Hardware Print は専用のものを使う）
  local prepare = C.PREPARE[cfg.TAB] or Job.prepare
  local cleanup = C.CLEANUP[cfg.TAB] or Job.cleanup

  local pok, err = pcall(function()
    prepare(j)
    flow(j)
  end)

  cleanup(j)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("TUKONYA RENDER（" .. tostring(cfg.TAB) .. "）", -1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)

  local res = { job = j, ok = false }
  if pok then
    res.ok = true
    j:log("結果: 完了")
  elseif type(err) == "table" and err.tukonya_abort then
    res.aborted = err.tukonya_abort
    j:log("結果: 中断 " .. tostring(res.aborted))
  else
    res.err = tostring(err)
    j:log("結果: 予期しないエラー " .. tostring(res.err))
  end
  return res
end

return C
