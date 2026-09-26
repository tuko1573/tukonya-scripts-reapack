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
    ・工程 … ステム化 / ハード通し / Pass M / Pass U / Pass D / パラ / チェーン書き出し / 透かし
             （v2.3.0〜 ディザー版を出すときは、MASTERチェーンを通すのは Pass M（64bit float の
               中間）の1回だけ。Pass U と Pass D はその中間ファイルを仮トラックに置いて
               「選択アイテムをマスター経由」で書き出す。Ditherトラックが無い・ディザー無しの
               1本だけのときは従来どおり直接書き出す）
    ・タブの流れ … mix2 / preview / para / hwprint / mastering

  必要拡張: SWS/S&M
  ===========================================================================
--]]

local DIR = debug.getinfo(1, "S").source:match("@(.*[/\\])") or ""
local S = dofile(DIR .. "tukonya_render_settings.lua")

local C = { DIR = DIR, Settings = S, VERSION = "2.8.1" }

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
-- 経過秒。os.clock は CPU 時間（書き出しは多くのコアで走るので実時間の何倍にもなる）。
-- v2.7.1: REAPER の時計（実時間）を使う。REAPER の外（単体テスト）では os.clock のまま。
local function clock() return (reaper.time_precise and reaper.time_precise()) or os.clock() end

local function find_track_by_name(name)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == name then return tr end
  end
  return nil
end

-- v2.8.0: 以下の4つは Mastering の段から上へ移した（2mix の 3 タブのディザーの置き場でも使うため。中身は同じ）
-- 名前で探す（大文字小文字を区別しない。前後の空白も無視）。他のタブの find_track_by_name は完全一致のまま。
local function find_track_ci(name)
  local want = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if tostring(nm or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower() == want then return tr end
  end
  return nil
end
C.find_track_ci = find_track_ci
C.dither_host_kind, C.dither_plan = S.dither_host_kind, S.dither_plan   -- v2.8.0（REAPER を呼ばない）

-- トラックの状態（Dither の2本の点検用）
local function track_shape(tr)
  if not tr then return nil end
  return {
    folder  = to_int(reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")) == 1,
    muted   = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5,
    toplevel = reaper.GetParentTrack(tr) == nil,
    items   = reaper.CountTrackMediaItems(tr),
  }
end

-- アイテムを置く（自動フェードなし・素通し）
local function mst_put_item(tr, path, pos, frames, srate)
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = it and reaper.AddTakeToMediaItem(it)
  local src = reaper.PCM_Source_CreateFromFileEx(path, false)
  if not (it and tk and src) then abort("64bitの中間ファイルをアイテムとして置けませんでした。中断します。\n" .. tostring(path)) end
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", frames / srate)
  for _, k in ipairs({ "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO", "D_SNAPOFFSET" }) do
    reaper.SetMediaItemInfo_Value(it, k, 0)
  end
  reaper.SetMediaItemInfo_Value(it, "D_VOL", 1.0)
  reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
  reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_VOL", 1.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PAN", 0.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", 1.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "I_CHANMODE", 0)
  reaper.UpdateItemInProject(it)
  return it
end

local function mst_remute(list)
  for _, tr in ipairs(list or {}) do
    if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
  end
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
  j.t0 = clock()
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
  -- Pass M（MASTERチェーンを1回だけ通した中間。常に 64 bit float。STEM_BITS には従わない）
  j.FMT_M = {
    RENDER_FORMAT = S.wav_format_b64(64), RENDER_FORMAT2 = "",
    RENDER_SRATE = cfg.SRATE, RENDER_CHANNELS = cfg.CHANNELS,
    RENDER_DITHER = 16, RENDER_NORMALIZE = 0,
  }
  j.passm_n = 0
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
  self:log_write("ab", ("%s  [%7.2fs] %s\n"):format(os.date("%H:%M:%S"), clock() - self.t0, s))
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

-- 中間ファイル（自分で名前を決める一時ファイル）の書き出し先を解く。v2.6.2（2026-09-25 つこさんの実案件）:
-- 前回中断したときに残った同じ名前のファイルがあると、REAPER は名前を「01-001.wav」のようにずらして返し、
-- 実際にはそこへ書かれず中断していた。ここでは、ずれた名前から元の名前を求め、元の名前のファイルと
-- 「元の名前-NNN」のファイル（とピーク）を消してから解き直し、ずれていないことを確かめる。
-- 消すのは、いま書こうとしている中間ファイルと同じ名前のものだけ。
local function lpat_escape(x) return (tostring(x):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
local function remove_with_peaks(self, path)
  if reaper.file_exists(path) then
    pcall(os.remove, path)
    self:log("前回の中間ファイルを消した: %s", path)
  end
  for _, pk in ipairs({ path .. ".reapeaks",
      (path:gsub("^(.*)[/\\]([^/\\]+)$", "%1/peaks/%2")) .. ".reapeaks" }) do
    if reaper.file_exists(pk) then
      pcall(os.remove, pk)
      self:log("前回の中間ファイルを消した: %s", pk)
    end
  end
end
-- 書き出し先の一覧（RENDER_TARGETS。「;」区切り）と、いま選ばれているアイテム（トラック名と位置）
function Job:targets_all()
  local ok, t = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
  local list = {}
  for x in tostring(ok and t or ""):gmatch("[^;]+") do list[#list + 1] = x end
  return list
end
function Job:selected_items_desc()
  local n = reaper.CountSelectedMediaItems(0)
  local d = {}
  for i = 0, n - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    local tr = it and reaper.GetMediaItem_Track(it)
    local nm = "?"
    if tr then local _, x = reaper.GetTrackName(tr); nm = x end
    d[#d + 1] = ("%s@%.3f"):format(tostring(nm), it and reaper.GetMediaItemInfo_Value(it, "D_POSITION") or -1)
  end
  return n, d
end
local function rcwd() return reaper.SNM_GetIntConfigVar and to_int(reaper.SNM_GetIntConfigVar("renderclosewhendone", -1)) or -1 end

-- アイテムを1つだけ選ぶ（v2.6.2）。SelectAllMediaItems のあとでも2つ以上選ばれていたら、
-- プロジェクトの全アイテムを1つずつ外してから選び直す。それでも1つでなければ中断。
function Job:select_only_item(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  if reaper.CountSelectedMediaItems(0) == 1 and reaper.IsMediaItemSelected(item) then return end
  local n0, d0 = self:selected_items_desc()
  self:log("選択の直し: アイテムが %d 個選ばれていた（%s）。REAPER の『すべてのアイテムの選択を解除』を試す", n0, table.concat(d0, ", "))
  reaper.Main_OnCommand(40289, 0)   -- Item: Unselect (clear selection of) all items
  reaper.SetMediaItemSelected(item, true)
  if reaper.CountSelectedMediaItems(0) == 1 and reaper.IsMediaItemSelected(item) then return end
  self:log("選択の直し: まだ %d 個。1つずつ外して選び直す", reaper.CountSelectedMediaItems(0))
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, i)
    if it ~= item then reaper.SetMediaItemSelected(it, false) end
  end
  reaper.SetMediaItemSelected(item, true)
  local n, d = self:selected_items_desc()
  if n ~= 1 or not reaper.IsMediaItemSelected(item) then
    abort(("書き出すアイテムを1つだけ選べませんでした（%d 個選ばれています: %s）。\n"
      .. "アイテムのグループ（Item group）が掛かっていないか確かめてください。中断します。"):format(n, table.concat(d, ", ")))
  end
end

function Job:tmp_target()
  local t = self:target()
  if not t then return nil end
  local dir, base = t:match("^(.*)[/\\]([^/\\]+)$")
  if not dir then return t end
  local stem, ext = base:match("^(.-)%-%d%d%d(%.[^%./\\]+)$")
  if not stem then stem, ext = base:match("^(.-)(%.[^%./\\]+)$") end
  if not stem then return t end
  local want = dir .. "/" .. stem .. ext
  remove_with_peaks(self, want)
  for _, pk in ipairs({ dir .. "/" .. stem .. ".reapeaks", dir .. "/peaks/" .. stem .. ".reapeaks" }) do
    if reaper.file_exists(pk) then
      pcall(os.remove, pk)
      self:log("前回の中間ファイルを消した: %s", pk)
    end
  end
  if reaper.EnumerateFiles then
    reaper.EnumerateFiles(dir, -1)   -- フォルダの一覧を読み直させる
    local sib, i = {}, 0
    local pat = "^" .. lpat_escape(stem) .. "%-%d%d%d" .. lpat_escape(ext) .. "$"
    while true do
      local fn = reaper.EnumerateFiles(dir, i)
      if not fn then break end
      if fn:match(pat) then sib[#sib + 1] = dir .. "/" .. fn end
      i = i + 1
    end
    for _, f in ipairs(sib) do remove_with_peaks(self, f) end
  end
  local all = self:targets_all()
  local t2 = all[1]
  local nsel, dsel = self:selected_items_desc()
  self:log("  書き出し先の一覧（%d 件）: %s / 選択アイテム %d 個: %s / RENDER_SETTINGS=%d BOUNDSFLAG=%d renderclosewhendone=%d",
    #all, table.concat(all, ";"), nsel, table.concat(dsel, ", "),
    to_int(reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)), to_int(reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)), rcwd())
  if #all ~= 1 then
    abort(("中間ファイルの書き出し先が %d 件になりました（1件のはず）。中断します。\n%s\n選択アイテム %d 個: %s")
      :format(#all, table.concat(all, "\n"), nsel, table.concat(dsel, ", ")))
  end
  -- 名前は、パターンの最後の部分（ファイル名）そのままでなければならない
  local _, pat = reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "", false)
  local lit = tostring(pat or ""):match("([^/\\]+)$") or ""
  local function norm(x) return (tostring(x or ""):gsub("\\", "/")) end
  local got_base = tostring(t2 or ""):match("([^/\\]+)$") or ""
  if not t2 or norm(t2) ~= norm(want) or (not lit:find("$", 1, true) and got_base:gsub("%.[^%.]+$", "") ~= lit) then
    abort(("中間ファイルの名前が REAPER に読み替えられました（パターン「%s」→ 書き出し先「%s」、期待「%s」）。中断します。\n"
      .. "reaper.ini の renderclosewhendone=%d\n%s"):format(lit, tostring(got_base), stem .. ext, rcwd(), dir))
  end
  return t2
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
  local t0 = clock()
  reaper.Main_OnCommand(42230, 0)  -- Render, most recent settings, auto-close
  local sec = clock() - t0
  self:verify(wav)
  -- ゴール4: 記録には「どのパスが終わったか」と「かかった秒数」を残す
  self:log("パス完了（%.2f 秒）: %s", sec, tostring(wav))
end

function Job:verify(wav)
  if not wav or wav == "" then
    abort("書き出し先のファイル名が分かりませんでした。中断します。")
  end
  if not reaper.file_exists(wav) then
    -- そのフォルダに実際にあるファイルを10個まで添える（REAPER がどこへ書いたかの手がかり。v2.6.2）
    local dir = wav:match("^(.*)[/\\][^/\\]+$")
    local seen = {}
    if dir and reaper.EnumerateFiles then
      reaper.EnumerateFiles(dir, -1)
      local i = 0
      while #seen < 10 do
        local fn = reaper.EnumerateFiles(dir, i)
        if not fn then break end
        seen[#seen + 1] = fn
        i = i + 1
      end
    end
    abort(("書き出しが終わっていません（ファイルがありません）。中断します。\n%s\nそのフォルダにあるファイル（10個まで）: %s")
      :format(wav, (#seen > 0) and table.concat(seen, ", ") or "なし"))
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
  -- Pass M から作る Pass U / Pass D は「選択アイテムの範囲」（BOUNDSFLAG=4）で書くので、
  -- 範囲からは長さが出ない。代わりに Pass M の実際のフレーム数を期待値にする（±1）。
  if self.expect_frames then
    local want = self.expect_frames
    local etol = self.expect_tol or 1   -- Mastering でサンプルレートを変えるときだけ ±2
    if math.abs(frames - want) > etol then
      abort(("書き出したファイルの長さが合いません（%d frames / 期待 %d ±%d、Pass M と同じ長さ）。中断します。\n%s")
        :format(frames, want, etol, wav))
    end
    self:log("完了確認: %s（%d frames / 期待 %d ＝ Pass M）", wav, frames, want)
    return
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
  -- v2.8.0: 『24bit Dither』／『16bit Dither』トラック（新しい置き場。旧フォルダとは同時に使わない）
  if self.DHOST and reaper.ValidatePtr(self.DHOST, "MediaTrack*") then
    reaper.SetMediaTrackInfo_Value(self.DHOST, "I_FXEN", on and 1 or 0)
  end
end

-- v2.8.0: ディザー版（Pass D）を出すか。prepare で決めた道（self.dither_plan）だけを見る。
function Job:makes_pass_d()
  return S.plan_makes_pass_d(self.dither_plan)
end

-- REAPERのマスタートラックのFXボタン。on=false で切る、on=true で控えた値へ戻す。
function Job:set_rmaster_fx(on)
  local mt = reaper.GetMasterTrack(0)
  local orig = self.restore and self.restore.rmaster_fxen
  if not mt or orig == nil then return end
  reaper.SetMediaTrackInfo_Value(mt, "I_FXEN", on and orig or 0)
end

-- ----- サンプルレート（v2.7.0、計画書/計画書_fx_rate.md）-----
-- 「プロジェクトまたはハードウェアのサンプルレートでFXを処理」を書き出しごとに決める（元の値は後片付けで戻す）
function Job:set_fxopt(v)
  local r = self.restore or {}
  if r.rateinternal == nil or r.rateinternal < 0 then return end
  local cur = to_int(reaper.SNM_GetIntConfigVar("projrenderrateinternal", -1))
  if cur ~= v then
    reaper.SNM_SetIntConfigVar("projrenderrateinternal", v)
    self:log("「プロジェクトまたはハードウェアのサンプルレートでFXを処理」: %s", (v == 1) and "オン" or "オフ")
  end
end
-- FX を通す納品物（パラ・#1 premaster）の「…FXを処理」: FXR = OUTR → オフ、FXR = RUN → オン、どちらでもなければオフ＋注意
function Job:set_fxopt_deliverable()
  if self.FXR == self.OUTR then self:set_fxopt(0)
  elseif self.FXR == self.RUNR then self:set_fxopt(1)
  else
    self:set_fxopt(0)
    if not self.fxopt_warned then
      self.fxopt_warned = true
      self:warn(("FX処理のサンプルレート（%d Hz）が、プロジェクトの動作レート（%d Hz）とも出力のサンプルレート（%d Hz）とも違うため、"
        .. "パラと premaster は出力のサンプルレートで処理しました。"):format(self.FXR, self.RUNR, self.OUTR))
    end
  end
end
-- FX処理・出力のサンプルレートを数に直し、書き出し形式に入れる（prepare / hw_prepare の最後）
function Job:resolve_rates(hwprint)
  local cfg = self.S
  local fxr, fxwhy = C.proc_rate(cfg.FX_SRATE)
  local run = C.run_rate()
  self.FXR, self.RUNR = fxr, run
  if hwprint then
    self.OUTR = fxr
    self.FMT_MASTER.RENDER_SRATE = fxr
    self:log("FX処理のサンプルレート: %d Hz（%s）/ プロジェクトの動作レート %d Hz / 「…FXを処理」元 %s",
      fxr, fxwhy, run, (self.restore.rateinternal == 1) and "オン" or ((self.restore.rateinternal == 0) and "オフ" or "不明"))
    return
  end
  local outr, outwhy = C.proc_rate(cfg.SRATE)
  self.OUTR = outr
  self.FMT_STEM.RENDER_SRATE, self.FMT_MASTER.RENDER_SRATE, self.FMT_MASTER_D.RENDER_SRATE = outr, outr, outr
  self.FMT_M.RENDER_SRATE = fxr
  self.FMT_HW = {}
  for k, v in pairs(self.FMT_STEM) do self.FMT_HW[k] = v end
  self.FMT_HW.RENDER_SRATE = fxr
  self:log("FX処理のサンプルレート: %d Hz（%s）/ 出力のサンプルレート: %d Hz（%s）/ プロジェクトの動作レート %d Hz / 「…FXを処理」元 %s",
    fxr, fxwhy, outr, (tonumber(cfg.SRATE) or 0) > 0 and "窓で指定" or ("プロジェクトと同じ＝" .. outwhy), run,
    (self.restore.rateinternal == 1) and "オン" or ((self.restore.rateinternal == 0) and "オフ" or "不明"))
  if fxr ~= run then
    self:log("2MIXBUS までのステム化は REAPER の動作レート %d Hz で処理される（アクションはレートを選べない）", run)
  end
end

-- ディザー版を出す直前の確認。止めずに注意を積むだけ。
function Job:check_dither_sanity()
  if self.S.DITHER_MODE ~= "track" or not (self.DITHER or self.DHOST) then return end
  local D, name = self.DITHER, self.S.DITHER_TRACK_NAME
  if self.DHOST then D, name = self.DHOST, self.DHOST_NAME end   -- v2.8.0: 新しい置き場を見る
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
  -- アイテムの選択（Pass M から書き出すとき、仮のアイテムだけを選ぶので控えて最後に戻す）
  r.item_sel = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do r.item_sel[#r.item_sel + 1] = reaper.GetSelectedMediaItem(0, i) end
  r.bus_mute        = reaper.GetMediaTrackInfo_Value(self.BUS, "B_MUTE")
  -- REAPERのマスタートラックのFXボタン（Pass M のあいだだけ切る。FXは Pass U / D で1回だけ通す）
  do local mt = reaper.GetMasterTrack(0); if mt then r.rmaster_fxen = reaper.GetMediaTrackInfo_Value(mt, "I_FXEN") end end
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
  -- 書き出し窓の「プロジェクトまたはハードウェアのサンプルレートでFXを処理」（v2.7.0。書き出しごとに決め、最後に戻す）
  r.rateinternal    = to_int(reaper.SNM_GetIntConfigVar("projrenderrateinternal", -1))
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
  -- v2.8.0: 『24bit Dither』／『16bit Dither』トラック。Pass D の途中で落ちたときは、置いたアイテムを消してから
  -- FXボタンを元へ戻す（ミュート・ソロは下の一覧の戻しで元へ戻る）。
  if self.DHOST and reaper.ValidatePtr(self.DHOST, "MediaTrack*") then
    if self.DHOST_ITEM and reaper.ValidatePtr(self.DHOST_ITEM, "MediaItem*") then
      reaper.DeleteTrackMediaItem(self.DHOST, self.DHOST_ITEM)
    end
    self.DHOST_ITEM = nil
  end
  for _, x in ipairs(r.dhosts or {}) do
    if reaper.ValidatePtr(x.tr, "MediaTrack*") then reaper.SetMediaTrackInfo_Value(x.tr, "I_FXEN", x.fxen) end
  end
  self:set_rmaster_fx(true)
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
  if r.rateinternal ~= nil and r.rateinternal >= 0 then reaper.SNM_SetIntConfigVar("projrenderrateinternal", r.rateinternal) end
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
  if r.item_sel and self.passm_touched_items then
    reaper.SelectAllMediaItems(0, false)
    for _, it in ipairs(r.item_sel) do
      if reaper.ValidatePtr(it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end
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
  -- ----- ディザーの置き場（v2.8.0、docs/v280_dither_notes.md）-----
  -- 「Ditherトラック」のとき: 2mix のビット深度に合う『24bit Dither』／『16bit Dither』トラック（一番上の段の普通の
  -- トラック）があればそれ。無ければ旧方式の『Dither』フォルダ（v2.7.x と同じ道）。どちらも無ければディザー版なし。
  -- 32/64 bit float は、どの方式でもディザー版を出さない。
  local hkind = S.dither_host_kind(cfg.MASTER_BITS)
  local hname = (hkind == "d24") and cfg.DITHER24_TRACK_NAME or ((hkind == "d16") and cfg.DITHER16_TRACK_NAME or nil)
  local host = (cfg.DITHER_MODE == "track" and hname) and find_track_ci(hname) or nil
  local legacy = find_track_by_name(cfg.DITHER_TRACK_NAME)
  self.dither_plan = S.dither_plan(cfg.DITHER_MODE, cfg.MASTER_BITS, host ~= nil, legacy ~= nil)
  if self.dither_plan == "host" then
    self.DITHER = nil                        -- 旧フォルダは使わない（仮トラックは一番上の段に作る）
    self.DHOST, self.DHOST_NAME = host, hname
    self.LEGACY_UNUSED = legacy              -- 旧フォルダも残っていれば、FXボタンだけ切っておく（最後に戻す）
  else
    self.DITHER = legacy                     -- v2.7.x と同じ（方式に関わらず、あれば仮トラックの置き場になる）
  end
  local plan_label
  if self.dither_plan == "host" then plan_label = ("『%s』トラック"):format(hname)
  elseif self.dither_plan == "legacy" then plan_label = ("旧『%s』フォルダ"):format(cfg.DITHER_TRACK_NAME)
  elseif self.dither_plan == "reaper" then plan_label = ("REAPERのディザー（bits=%s）"):format(tostring(cfg.REAPER_DITHER_BITS))
  elseif self.dither_plan == "float" then plan_label = "なし（32/64bit float）"
  elseif self.dither_plan == "none" then plan_label = "なし（ディザー＝なし）"
  else plan_label = "なし（ディザーのトラックが無い）" end
  self:log("ディザーの方式: %s（設定 %s / 2mixのビット深度 %s / 旧『%s』: %s）", plan_label, cfg.DITHER_MODE,
    S.wav_format_label(cfg.MASTER_BITS), cfg.DITHER_TRACK_NAME, legacy and "あり" or "なし")
  if self.dither_plan == "float" then
    self:log("32/64bit float のためディザー版は書き出しません")
  elseif self.dither_plan == "missing" then
    if hname then
      self:warn(("『%s』トラックも旧『%s』フォルダも見つからなかったため、ディザー無しの1組だけを書き出しました。")
        :format(hname, cfg.DITHER_TRACK_NAME))
    else
      self:warn(("『%s』トラックが見つからなかったため、ディザー無しの1組だけを書き出しました。"):format(cfg.DITHER_TRACK_NAME))
    end
  end
  if self.DHOST then
    -- 形の点検（Mastering の置き場と同じ決まり）。親があると、その親の処理が Pass M と Pass D で二重にかかるので止める。
    local sh = track_shape(self.DHOST)
    if not sh.toplevel then
      abort(("『%s』が一番上の段にありません。上のフォルダの処理が二重にかかるので、一番上の段へ移してください。中断します。"):format(hname))
    end
    if sh.folder then
      self:warn(("『%s』がフォルダになっています（子トラックがあります）。子を持たない普通のトラックにすることをおすすめします。"):format(hname))
    end
    if reaper.GetMediaTrackInfo_Value(self.DHOST, "B_MAINSEND") < 0.5 then
      self:warn(("『%s』トラックのマスター送り（親への送り）が切れています。ディザー版が無音になる可能性があります。"):format(hname))
    end
  end

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
  -- 「書き出したファイルをプロジェクトに入れる」が入っていると、中間ファイルまでトラックとして増える。
  -- v2.7.2: Mastering と同じく、書き出しのあいだは切る（ハード通しの段だけ自分で入れる。最後に元へ戻る）。
  if self.restore.addtoproj ~= nil then
    reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", to_int(self.restore.addtoproj) & (~1), true)
  end

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
  -- v2.8.0: 『24bit Dither』／『16bit Dither』トラックも、あれば（使う・使わないに関わらず）FXボタンを控えて切る。
  -- 空のトラックでもディザーのプラグインは雑音を足しうるので、Pass D で使う1本を、その書き出しのあいだだけ入れる。
  self.restore.dhosts = {}
  local cands = { find_track_ci(cfg.DITHER24_TRACK_NAME), find_track_ci(cfg.DITHER16_TRACK_NAME), self.LEGACY_UNUSED }
  for i = 1, 3 do
    local tr = cands[i]
    if tr and tr ~= self.DITHER then
      local seen = false
      for _, x in ipairs(self.restore.dhosts) do if x.tr == tr then seen = true end end
      if not seen then
        self.restore.dhosts[#self.restore.dhosts + 1] = { tr = tr, fxen = reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") }
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
      end
    end
  end

  -- ReaInsert検出（有効状態で存在すればハードモード）
  self.reai = find_reainsert(self.MASTER, cfg.REAINSERT_MATCH)
  self.hw_mode = (self.reai ~= nil) and (self.SAVE_FX[self.reai] == true)
  self:log("MASTER FX %d 個 / ReaInsert %s / ハード通し %s", self.FXN,
    self.reai and ("番号 " .. (self.reai + 1)) or "無し", self.hw_mode and "あり" or "なし")

  -- 安全のため、書き出し元（Source）はダイアログ任せにせず毎回明示する
  self.master_mix = to_int(self.restore.render_settings) & (~0x10EB)
  self.stems_only = self.master_mix | 128   -- 選択トラック（マスター経由）
  self:resolve_rates(false)
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
  if n > 0 then self:log("同じ名前のファイルがあるので連番を付ける: -%03d", n) end
  return (n == 0) and "" or ("-" .. string.format("%03d", n))
end

-- 名前だけ解決する（パターンと形式を当てて RENDER_TARGETS を読む）
-- v2.8.1（2026-09-26 つこさんの実案件 Preview）: ここはレンダー設定がまだ「元の設定」（ステム用の
-- 「選択トラック」など）のまま呼ばれることがあり、選ばれたトラックが無いと REAPER は名前を 1 つも返さない。
-- すると「同じ名前のファイルは無い」と誤って判断し、連番を付けずに上書きしていた。
-- 名前を解くあいだだけ、マスターミックス＋範囲（時間選択が無ければ曲全体）に切り替えて解き、元に戻す。
-- それでも名前が返らなければ、黙って進めずに止める。
function Job:resolve_target(pattern, fmt)
  local rs0 = reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)
  local bf0 = reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", self.master_mix or 0, true)
  if self.RANGE_S and self.RANGE_E and self.RANGE_E > self.RANGE_S then
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 2, true)
    self:apply_range()
  else
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)
  end
  self:set_pattern(pattern)
  self:apply_format(fmt)
  local t = self:target()
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", rs0, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", bf0, true)
  if not t then
    abort(("書き出し先の名前を解けませんでした（パターン「%s」）。中断します。"):format(tostring(pattern)))
  end
  return t
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
  self:apply_format(self.FMT_HW or self.FMT_STEM)   -- v2.7.0: FX処理のサンプルレート
  self:set_fxopt(0)
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
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", to_int(self.restore.addtoproj) & (~1), true)   -- v2.7.2: 以降の段では入れない
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

-- ===========================================================================
-- Pass M（v2.3.0、2026-09-23 つこさん決定）
-- ---------------------------------------------------------------------------
-- ディザー版を出すときは、MASTERチェーンを通すのを1回だけにする。
--   Pass M … いつものマスターミックスを 64 bit float の中間ファイルへ（Ditherトラックは切ったまま）
--   仮トラック … Ditherフォルダの最初の子（MASTERと同じ段）。Ditherが無ければ最上位。
--                ここに Pass M を1本のアイテムとして置き、そのアイテムだけを選ぶ。
--   Pass U / Pass D … 「選択アイテムをマスター経由」（RENDER_SETTINGS の &64）＋
--                     「選択アイテムの範囲」（RENDER_BOUNDSFLAG=4）で書き出す。
-- 前提: &64 では、選んだアイテムの通り道（仮トラック → Ditherフォルダ → REAPERのマスター）
--       だけが鳴り、他のトラックのアイテム（ステム・PREVIEWONLY など）は鳴らない。
--       だから他のトラックはミュートしない。この前提は試験台（dither_rig）の
--       Pass U がゴールデンとバイト一致することで確かめる。
-- 仮トラックは作った直後に created_tracks に入れる。途中で落ちても後片付け（cleanup）が消す。
-- ===========================================================================
local function track_index0(tr)
  return to_int(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
end
local function parent_guid_map()
  local m = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local p = reaper.GetParentTrack(tr)
    m[reaper.GetTrackGUID(tr)] = p and reaper.GetTrackGUID(p) or "-"
  end
  return m
end
local function parents_changed(snap)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local want = snap[reaper.GetTrackGUID(tr)]
    if want then
      local p = reaper.GetParentTrack(tr)
      if (p and reaper.GetTrackGUID(p) or "-") ~= want then
        local _, nm = reaper.GetTrackName(tr)
        return nm or "?"
      end
    end
  end
  return nil
end

-- Pass M を書き出して、仮トラックと仮アイテムを用意する。
function Job:passm_render(pat_m)
  self:set_dither(false)
  self:apply_format(self.FMT_M)
  self:set_pattern(pat_m)
  local wav_m = self:tmp_target()
  if not wav_m then abort("Pass M（64bit中間）の書き出し先が分かりませんでした。中断します。") end
  -- 前回の取り残しがあると REAPER の「同名ファイル」の窓で止まるので、先に消す（自分の中間ファイル名だけ）
  if reaper.file_exists(wav_m) then pcall(os.remove, wav_m) end
  self.temp_files[#self.temp_files + 1] = wav_m
  local dir, base = wav_m:match("^(.*)[/\\]([^/\\]+)$")
  if dir then self.temp_files[#self.temp_files + 1] = dir .. "/peaks/" .. base .. ".reapeaks" end
  if dir then self.passm_peaks = self.passm_peaks or {}; self.passm_peaks[#self.passm_peaks + 1] = dir .. "/peaks/" .. base .. ".reapeaks" end
  -- Pass M では Ditherトラックと REAPERのマスタートラックのFXを切る（どちらも Pass U / D で1回だけ通す。
  -- 順番は 仮トラック → Dither → マスターFX のまま）。Ditherは上の set_dither(false) で切れている。
  self:set_rmaster_fx(false)
  self:set_fxopt(0)   -- v2.7.0: 中間は FX処理のサンプルレート（FMT_M）そのもので処理する
  self:log("Pass M（64bit中間）: %s（Dither・REAPERマスターのFXは切った状態）", wav_m)
  self:render(wav_m)
  self:set_rmaster_fx(true)
  local frames, why, _, srate = wav_frames(wav_m)
  if not frames or frames <= 0 or not srate or srate <= 0 then
    abort(("Pass M（64bit中間）を読めませんでした（%s）。中断します。\n%s"):format(tostring(why), wav_m))
  end
  return wav_m, frames, srate
end

function Job:passm_setup(wav_m, frames, srate)
  -- 仮トラックの置き場: Ditherがフォルダなら、その最初の子（MASTERと同じ段）。
  -- すぐ下に深さ0で差し込むので、既存のトラックの I_FOLDERDEPTH は1つも書き換えない
  -- （消すときも直す必要が無い）。
  local idx, parent = 0, nil
  if self.DITHER and reaper.ValidatePtr(self.DITHER, "MediaTrack*") then
    if to_int(reaper.GetMediaTrackInfo_Value(self.DITHER, "I_FOLDERDEPTH")) == 1 then
      idx, parent = track_index0(self.DITHER) + 1, self.DITHER
    else
      self:warn(("『%s』トラックがフォルダではないため、Pass U / D は最上位の仮トラックから書き出しました（Ditherトラックのプラグインは通りません）。"):format(tostring(self.S.DITHER_TRACK_NAME)))
    end
  end
  local snap = parent_guid_map()
  reaper.InsertTrackAtIndex(idx, false)   -- false = 既定のFX・エンベロープを付けない
  local tr = reaper.GetTrack(0, idx)
  if not tr then abort("Pass M 用の仮トラックを作れませんでした。中断します。") end
  self.created_tracks[#self.created_tracks + 1] = tr   -- 途中で落ちても cleanup が消す
  self.PASSM_TRACK = tr
  reaper.SetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH", 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "_tmp_passM", true)
  -- 仮トラックは素通しにする（新規トラックの既定フェーダー設定に左右されないように）
  reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1.0)
  reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0.0)
  reaper.SetMediaTrackInfo_Value(tr, "D_PANLAW", 1.0)   -- +0 dB（センターで素通し）
  reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 1)
  if reaper.AnyTrackSolo(0) then
    -- どこかがソロだと、仮トラックが鳴らなくなる。仮トラック自身をソロにする（消すので戻す必要なし）
    reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 2)
    self:log("ソロ中のトラックがあるため、仮トラックをソロにした")
  end
  local bad = parents_changed(snap)
  if bad then abort(("仮トラックを差し込んだら『%s』の親が変わってしまいました。中断します。"):format(bad)) end
  if reaper.GetParentTrack(tr) ~= parent then
    abort("仮トラックを Ditherフォルダの中に置けませんでした。中断します。")
  end

  -- 仮アイテム（Pass M そのもの）。自動フェードは付けない。
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = it and reaper.AddTakeToMediaItem(it)
  local src = reaper.PCM_Source_CreateFromFileEx(wav_m, false)
  if not (it and tk and src) then abort("Pass M をアイテムとして置けませんでした。中断します。") end
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", self.start_pos or 0.0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", frames / srate)
  for _, k in ipairs({ "D_FADEINLEN", "D_FADEOUTLEN", "D_FADEINLEN_AUTO", "D_FADEOUTLEN_AUTO", "D_SNAPOFFSET" }) do
    reaper.SetMediaItemInfo_Value(it, k, 0)
  end
  reaper.SetMediaItemInfo_Value(it, "D_VOL", 1.0)
  reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
  reaper.SetMediaItemInfo_Value(it, "B_LOOPSRC", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", 0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_VOL", 1.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PAN", 0.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_PLAYRATE", 1.0)
  reaper.SetMediaItemTakeInfo_Value(tk, "I_CHANMODE", 0)
  reaper.UpdateItemInProject(it)
  self.passm_touched_items = true
  self.PASSM_ITEM = it
  self:select_only_item(it)

  -- 以降の書き出し: 選択アイテムをマスター経由・選択アイテムの範囲
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", self.master_mix | 64, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)
  self.expect_frames = frames
  self.passm_frames, self.passm_srate = frames, srate
  self:log("仮トラックに Pass M を置いた（%s / 位置 %.6f 秒 / %d frames @ %d Hz）",
    parent and ("『" .. tostring(self.S.DITHER_TRACK_NAME) .. "』フォルダの中") or "最上位",
    self.start_pos or 0.0, frames, srate)

  -- Pass M の後ろ（仮トラックの通り道）のフェーダー類は Pass U / D でもう一度通る。素通しでないと二重にかかる。
  -- Ditherトラック方式では check_dither_sanity が同じ点を見るので、ここはそれ以外のときだけ。
  if self.S.DITHER_MODE ~= "track" then
    local mt = reaper.GetMasterTrack(0)
    if mt then
      local mv = reaper.GetMediaTrackInfo_Value(mt, "D_VOL")
      local mp = reaper.GetMediaTrackInfo_Value(mt, "D_PAN")
      -- FXは Pass M で切ってあるので1回だけ。フェーダー／パンは切れないので二重になる。
      if math.abs(mv - 1.0) > 1e-6 or math.abs(mp) > 1e-6 then
        self:warn("REAPERのマスタートラックのフェーダーが0dB／センターではありません。Pass M と Pass U / D で二重にかかります。")
      end
    end
  end
  if parent and reaper.GetParentTrack(parent) then
    self:warn(("『%s』トラックがさらに別のフォルダの中にあります。その親の処理は Pass M と Pass U / D で二重にかかります。")
      :format(tostring(self.S.DITHER_TRACK_NAME)))
  end
end

-- 仮トラック・仮アイテム・中間ファイルを片付けて、マスターミックスの設定へ戻す。
-- 途中で落ちたときは cleanup が同じもの（created_tracks / temp_files）を片付ける。
function Job:passm_teardown(wav_m)
  self.expect_frames, self.expect_tol, self.passm_frames, self.passm_srate = nil, nil, nil, nil
  if self.PASSM_TRACK and reaper.ValidatePtr(self.PASSM_TRACK, "MediaTrack*") then
    reaper.DeleteTrack(self.PASSM_TRACK)
  end
  self.PASSM_TRACK, self.PASSM_ITEM = nil, nil
  if wav_m then
    pcall(os.remove, wav_m)
    pcall(os.remove, wav_m .. ".reapeaks")
    local dir, base = wav_m:match("^(.*)[/\\]([^/\\]+)$")
    if dir then pcall(os.remove, dir .. "/peaks/" .. base .. ".reapeaks") end
  end
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", self.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", self.bounds_flag, true)
  self:log("Pass M の仮トラックと中間ファイルを片付けた")
end

-- 仮アイテムから1本書き出す。want … マスターミックスのときに解いておいた本来の名前。
-- v2.7.1（2026-09-26 つこさんの実案件 Preview）: 仮アイテムのほかに別のアイテムが選ばれたままだと、
-- REAPER は「-001, -002 …」と2本以上書き、こちらは違うファイルを見て「長さが合わない」で止まっていた。
-- そこで (1) 書く前に仮アイテムだけを選び直し、書き出し先が1件でなければ中断する、
-- (2) REAPER が答えた名前を信じず、書いたあとに「新しく増えたファイル」を探して、それを本来の名前へ改名する。
-- 同じ名前の一族（stem / stem-NNN）は消さない（2mix Render では同じ日の前の納品物がそこにある）。
local function derive_family(dir, want)
  -- want の一族（同じ根の名前 ＋ -NNN）の一覧。{ [名前] = 大きさ }
  local base = want:match("([^/\\]+)$") or want
  local stem, ext = base:match("^(.-)(%.[^%./\\]+)$")
  if not stem then stem, ext = base, "" end
  local root = stem:gsub("%-%d%d%d$", "")
  local pat = "^" .. lpat_escape(root) .. "%-?%d?%d?%d?" .. lpat_escape(ext) .. "$"
  local fam = {}
  if reaper.EnumerateFiles then
    reaper.EnumerateFiles(dir, -1)
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(dir, i)
      if not fn then break end
      if fn:match(pat) and (fn == root .. ext or fn:match("%-%d%d%d" .. lpat_escape(ext) .. "$")) then
        local f = io.open(dir .. "/" .. fn, "rb")
        local sz = f and f:seek("end") or -1
        if f then f:close() end
        fam[fn] = sz
      end
      i = i + 1
    end
  end
  return fam
end

function Job:passm_derive(fmt, pattern, want)
  self:apply_format(fmt)
  -- v2.7.0: 出力のレートが中間（FX処理）のレートと違うときは、長さの期待値もそのレートに直す（±2）
  if self.passm_frames and self.passm_srate and (tonumber(fmt.RENDER_SRATE) or 0) > 0
     and fmt.RENDER_SRATE ~= self.passm_srate then
    self.expect_frames = math.floor(self.passm_frames * fmt.RENDER_SRATE / self.passm_srate + 0.5)
    self.expect_tol = 2
  elseif self.passm_frames then
    self.expect_frames, self.expect_tol = self.passm_frames, nil
  end
  self:set_pattern(pattern)
  -- (1) 仮アイテムだけを選び直し、書き出し先が1件であることを確かめる
  if self.PASSM_ITEM and reaper.ValidatePtr(self.PASSM_ITEM, "MediaItem*") then
    self:select_only_item(self.PASSM_ITEM)
  end
  local all = self:targets_all()
  local nsel, dsel = self:selected_items_desc()
  self:log("  書き出し先の一覧（%d 件）: %s / 選択アイテム %d 個: %s / RENDER_SETTINGS=%d BOUNDSFLAG=%d",
    #all, table.concat(all, ";"), nsel, table.concat(dsel, ", "),
    to_int(reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, false)), to_int(reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, false)))
  -- 一覧には副形式（AAC など）が並ぶこともあるので、主形式（WAV）の数だけを見る
  local want_ext = ((want or all[1] or ""):match("(%.[^%./\\]+)$") or ".wav"):lower()
  local prim = {}
  for _, x in ipairs(all) do
    if (x:match("(%.[^%./\\]+)$") or ""):lower() == want_ext then prim[#prim + 1] = x end
  end
  if #prim ~= 1 or nsel ~= 1 then
    abort(("書き出すアイテムのほかに別のアイテムが選ばれたままです（選択 %d 個: %s / 書き出し先 %d 件）。\n"
      .. "REAPER のアレンジの何もないところをクリックして選択をすべて外してから、もう一度実行してください。中断します。\n%s")
      :format(nsel, table.concat(dsel, ", "), #all, table.concat(all, "\n")))
  end
  local got = prim[1]
  if not got or got == "" then abort("書き出し先のファイル名が分かりませんでした（Pass M から）。中断します。") end
  if want and got ~= want then
    self:log("選択アイテムの書き出しで名前が変わる: %s → 本来 %s（書いたあと改名する）", got, want)
  end
  local final = want or got
  local dir = final:match("^(.*)[/\\][^/\\]+$")
  -- (2) 書く前の一族を控え、書いたあとに増えた／変わったファイルを本当の書き先とみなす
  local before = dir and derive_family(dir, final) or {}
  self:apply_range()
  local t0 = clock()
  reaper.Main_OnCommand(42230, 0)  -- Render, most recent settings, auto-close
  local sec = clock() - t0
  local after = dir and derive_family(dir, final) or {}
  local written, extra = nil, {}
  for fn, sz in pairs(after) do
    if before[fn] == nil or before[fn] ~= sz then
      if written then extra[#extra + 1] = fn else written = fn end
    end
  end
  if not written then
    local left = {}
    for fn in pairs(after) do left[#left + 1] = fn end
    table.sort(left)
    abort(("書き出しが終わっていません（新しいファイルが増えていません）。中断します。\n%s\n"
      .. "そこにある同じ名前の一族: %s"):format(final, (#left > 0) and table.concat(left, ", ") or "なし"))
  end
  if #extra > 0 then
    abort(("書き出しで %d 本のファイルが増えました（1本のはず）: %s, %s。中断します。\n%s")
      :format(#extra + 1, written, table.concat(extra, ", "), final))
  end
  local written_path = dir .. "/" .. written
  if written_path ~= got then
    self:log("REAPER が答えた名前と違うファイルに書かれた: %s（答えは %s）", written_path, got)
  end
  if written_path ~= final then
    if reaper.file_exists(final) then
      -- 本来の名前に古いファイルが残っていた（前回の中断など）。新しいものを優先する
      self:log("本来の名前に前回のファイルが残っていたので置き換える: %s", final)
      pcall(os.remove, final)
    end
    local okr, errr = os.rename(written_path, final)
    if not okr then
      abort(("書き出したファイルの名前を戻せませんでした（%s → %s: %s）。中断します。"):format(written_path, final, tostring(errr)))
    end
    self:log("名前を本来のものへ戻した: %s → %s", written_path, final)
    local ext = (fmt.RENDER_FORMAT2 ~= "") and self.FMT2_EXT or nil
    if ext then
      local g2, w2 = self:secondary(written_path, ext), self:secondary(final, ext)
      if g2 and w2 and g2 ~= w2 and reaper.file_exists(g2) then
        if reaper.file_exists(w2) then pcall(os.remove, w2) end
        os.rename(g2, w2)
      end
    end
  end
  self:verify(final)
  self:log("パス完了（%.2f 秒）: %s", sec, tostring(final))
  return final
end

-- v2.8.0: 『24bit Dither』／『16bit Dither』トラックで Pass D を1本書く。戻り値: 書いたファイル。
-- 置いたアイテム・FXボタン・ミュート・ソロは、書き終えたらすぐ戻す。途中で落ちたときは cleanup が
-- アイテムを消し（self.DHOST_ITEM）、FXボタン（restore.dhosts）とミュート・ソロ（一覧）を戻す。
function Job:dhost_pass_d(pat, wav_m, wav_d)
  local host, hname = self.DHOST, self.DHOST_NAME
  local pos = self.start_pos or 0.0
  local frames, srate = self.passm_frames, self.passm_srate
  if not (frames and srate and srate > 0) then abort("Pass D の前に 64bit の中間の長さが分かりませんでした。中断します。") end
  local fin = pos + frames / srate
  -- 置き場に元からアイテムがあり、書き出す範囲に重なっていれば注意（選んだアイテムだけが鳴るはずだが、念のため）
  if not self.dhost_items_warned then
    for i = 0, reaper.CountTrackMediaItems(host) - 1 do
      local it = reaper.GetTrackMediaItem(host, i)
      local a = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local b = a + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if a < fin and b > pos then
        self.dhost_items_warned = true
        self:warn(("『%s』トラックに元からアイテムがあります。書き出しに混ざる可能性があります"):format(hname))
        break
      end
    end
  end
  local it = mst_put_item(host, wav_m, pos, frames, srate)
  self.DHOST_ITEM = it
  local keep_item = self.PASSM_ITEM
  self.PASSM_ITEM = it                          -- passm_derive はこのアイテムだけを選び直す
  local hun = self:mst_unmute_path(host)
  if #hun > 0 then self:log("『%s』トラックのミュートを書き出しのあいだ外した", hname) end
  local solo0 = reaper.GetMediaTrackInfo_Value(host, "I_SOLO")
  local soloed = false
  if reaper.AnyTrackSolo(0) and solo0 == 0 then
    -- どこかがソロ（Pass M の仮トラックなど）だと置き場が鳴らない。書き出しのあいだだけソロにする
    reaper.SetMediaTrackInfo_Value(host, "I_SOLO", 2)
    soloed = true
    self:log("ソロ中のトラックがあるため、『%s』トラックを書き出しのあいだソロにした", hname)
  end
  self:check_dither_sanity()
  self:set_dither(true)
  self:log("Pass D（ディザーあり / 『%s』トラック / Pass M から）: %s", hname, tostring(wav_d))
  -- [試験用の注入点 host]（dither_rig の run_rig.sh は「[試験用の注入点]」の最初の1つを置き換えるので、名前を分けてある）
  local got = self:passm_derive(self.FMT_MASTER_D, pat.d, wav_d)
  self:set_dither(false)
  if reaper.ValidatePtr(it, "MediaItem*") then reaper.DeleteTrackMediaItem(host, it) end
  self.DHOST_ITEM = nil
  self.PASSM_ITEM = keep_item
  mst_remute(hun)
  if soloed then reaper.SetMediaTrackInfo_Value(host, "I_SOLO", solo0) end
  return got
end

-- 納品物の書き出し（Pass M → Pass U ＋ Pass D）。3タブで共通の心臓部。
--   pat.u        … Pass U（ディザー無し）の書き出し先パターン
--   pat.keep_u   … Pass U のWAVを納品物として残すか（false なら中間ファイル扱いで消す）
--   pat.aac      … 副形式の最終的な名前のパターン
--   pat.d        … Pass D（ディザー有り）の書き出し先パターン
--   pat.fallback … 「ディザーを掛けない」ときに1本だけ別の名前で出す道（2mix Preview 専用）。
--                  2mix Render と Para + 2mix には渡さない。渡さない場合、
--                  Ditherトラックが無いときは「ディザー＝なし」を選んだときと同じ
--                  1組（_youtube_no_dither ＋ _sample）が出る（2026-09-21 つこさん了承）。
-- ディザー版を出さないとき（fallback も、Pass U だけの1組も）は、MASTERチェーンを通るのが
-- もともと1回なので、Pass M を挟まず従来どおり直接書き出す（出力は v2.2.3 と同じ）。
function Job:render_deliverable(pat)
  local cfg = self.S
  reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- Full-speed Offline
  -- 2mix Preview は2回呼ぶので、書き出し元と範囲を毎回ここで決め直す
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", self.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", self.bounds_flag, true)

  -- ディザーを掛けない条件: 「なし」を選んだか、「Ditherトラック」なのにトラックが無いか
  -- v2.8.0: 条件は prepare で決めた道（self.dither_plan）にまとめた。旧フォルダの道では v2.7.x と同じ結果。
  -- 32/64 bit float は、どの方式でもディザー版を出さない。
  local no_dither = not self:makes_pass_d()
  -- v2.7.0: FX処理と出力のレートが違うときは、ディザーなしでも中間（Pass M）を通す
  local fx_ne_out = (self.FXR ~= nil and self.OUTR ~= nil and self.FXR ~= self.OUTR)
  local use_passm = (not no_dither) or fx_ne_out
  self:set_fxopt(0)   -- 出力の書き出しは、ディザーも含めて出力のサンプルレートで処理する

  if no_dither and pat.fallback and not use_passm then
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

  -- 名前は先に、マスターミックスの設定のまま解いておく（従来と同じ名前になるように）
  self:set_dither(false)
  self:apply_format(self.FMT_MASTER)
  self:set_pattern(pat.u)
  local wav_u = self:target()
  local tmp2  = self:secondary(wav_u)
  self:set_pattern(pat.aac)
  local final_wav = self:target()
  local final2 = self:secondary(final_wav)
  local wav_d
  if not no_dither then
    self:apply_format(self.FMT_MASTER_D)
    self:set_pattern(pat.d)
    wav_d = self:target()
  end
  local wav_fb
  if no_dither and pat.fallback then
    self:apply_format(self.FMT_MASTER)
    self:set_pattern(pat.fallback)
    wav_fb = self:target()
  end

  -- ----- Pass M（ディザー版を出すとき、または FX処理と出力のレートが違うとき）-----
  local wav_m
  if use_passm then
    self.passm_n = self.passm_n + 1
    local u_dir = pat.u:match("^(.-)/[^/]*$") or ""
    local m_name = cfg.TMP_PREFIX .. "_passM" .. ((self.passm_n > 1) and ("_" .. self.passm_n) or "")
    local pat_m = (u_dir == "") and m_name or (u_dir .. "/" .. m_name)
    local frames, srate
    wav_m, frames, srate = self:passm_render(pat_m)
    self:passm_setup(wav_m, frames, srate)
    self:set_fxopt(0)
  end

  if wav_fb then   -- 2mix Preview のディザーなしの 1 本（FX処理と出力のレートが違うとき）
    self:log("書き出し（ディザーなしの1本だけ / Pass M から）: %s", tostring(wav_fb))
    wav_fb = self:passm_derive(self.FMT_MASTER, pat.fallback, wav_fb)
    self:add_produced(wav_fb)
    if self.FMT2_EXT then self:add_produced(self:secondary(wav_fb)) end
    self:passm_teardown(wav_m)
    return
  end

  -- ----- Pass U（ディザー無し。WAV＋副形式）-----
  if wav_m then
    self:log("Pass U（ディザーなし / Pass M から）: %s", tostring(wav_u))
    wav_u = self:passm_derive(self.FMT_MASTER, pat.u, wav_u)
  else
    self:apply_format(self.FMT_MASTER)
    self:set_pattern(pat.u)
    self:log("Pass U（ディザーなし）: %s", tostring(wav_u))
    self:render(wav_u)
  end
  if pat.keep_u then
    self:add_produced(wav_u)
  elseif wav_u then
    self.temp_files[#self.temp_files + 1] = wav_u   -- 副形式を取るためだけのWAVは捨てる
  end

  -- 副形式を最終的な名前へ改名する（名前は上で解いてある）
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
    if self.dither_plan == "float" then
      self:log("32/64bit float のためディザー版は書き出しません")
    else
      self:log("%s のため、ディザー版は書き出しません",
        (cfg.DITHER_MODE == "none") and "ディザー＝なし"
        or ("『" .. tostring(cfg.DITHER_TRACK_NAME) .. "』トラックが無い"))
    end
    if wav_m then self:passm_teardown(wav_m) end
    return
  end

  -- ----- Pass D（v2.8.0 の新しい置き場: 『24bit Dither』／『16bit Dither』トラック）-----
  -- 64bit の中間を置き場のトラックにもう1つアイテムとして置き、それだけを選んで「選択アイテムをマスター経由」で
  -- 書き出す（通り道は アイテム → 置き場の FX → REAPER マスター。Mastering の 48/24 と同じ形）。
  if self.dither_plan == "host" and self.DHOST then
    wav_d = self:dhost_pass_d(pat, wav_m, wav_d)
    self:add_produced(wav_d)
    self:passm_teardown(wav_m)
    return
  end

  -- ----- Pass D（ディザー有り。WAVだけ。Pass M から）-----
  self:check_dither_sanity()
  if cfg.DITHER_MODE == "track" then self:set_dither(true) end
  self:log("Pass D（ディザーあり / %s / Pass M から）: %s",
    (cfg.DITHER_MODE == "reaper") and ("REAPERのディザー bits=" .. tostring(cfg.REAPER_DITHER_BITS)) or "Ditherトラック",
    tostring(wav_d))
  -- [試験用の注入点]
  wav_d = self:passm_derive(self.FMT_MASTER_D, pat.d, wav_d)
  self:set_dither(false)
  self:add_produced(wav_d)
  self:passm_teardown(wav_m)
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
    if j:makes_pass_d() then   -- v2.8.0: prepare で決めた道（旧フォルダでは v2.7.x と同じ）
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
    if j:makes_pass_d() then   -- v2.8.0: prepare で決めた道（旧フォルダでは v2.7.x と同じ）
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
  j:set_fxopt_deliverable()   -- v2.7.0

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
  j:set_fxopt_deliverable()   -- v2.7.0
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
  r.rateinternal = to_int(reaper.SNM_GetIntConfigVar("projrenderrateinternal", -1))   -- v2.7.0
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
  self:resolve_rates(true)   -- v2.7.0
end

-- ----- 後片付け（Hardware Print 専用。旧スクリプトの cleanup と同じ順序）-----
function Job:hw_cleanup()
  local r = self.restore
  self:log("後片付け開始")
  if r.rateinternal ~= nil and r.rateinternal >= 0 then reaper.SNM_SetIntConfigVar("projrenderrateinternal", r.rateinternal) end
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
  j:set_fxopt(0)   -- v2.7.0: プリントは FX処理のサンプルレート（FMT_MASTER に入れてある）そのもので処理する
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
  local t0 = clock()
  -- [試験用の注入点 hwprint]
  reaper.PreventUIRefresh(-1)     -- 実時間レンダーの進み具合を見せる
  reaper.Main_OnCommand(42230, 0) -- 直近のレンダー設定でレンダー（ダイアログ自動クローズ）
  reaper.PreventUIRefresh(1)
  j:log("パス完了（%.2f 秒）: %d 本", clock() - t0, #targets)

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

-- ===========================================================================
-- Mastering（v2.4.0、計画書/計画書_mastering.md の判断1〜8）
-- ---------------------------------------------------------------------------
--   Pass M … 曲ごと・版ごとに、そのトラックのアイテムだけを選び「選択アイテムをマスター経由」で
--            64 bit float の中間を作る（MASTER のチェーンを通るのはここだけ）。
--            Dither の2トラックと REAPER のマスタートラックの FX はこのあいだ切る。
--            ReaInsert が無い・無効なら 1 本通し（オフライン）。ReaInsert が有効なら（v2.6.0）
--            2mix Render タブと同じく 3 段に分ける:
--              M-1 … MASTER の FX を全部切って 2MIXBUS まで（オフライン）
--              M-2 … M-1 の音を MASTER の最初の子の仮トラックに置き、FX は ReaInsert まで（実時間）
--              M-3 … M-2 の音を同じく置き、ReaInsert より後ろの FX で NN.wav に（オフライン）
--            M-1・M-2 のあいだ MASTER のフェーダーは 0dB／センター（ハードにはフェーダー前の音を送る）。
--            M-3 で元へ戻す。M-1・M-2 の中間は M-3 のあとすぐ消す。
--            REAPER のマスタートラックは FX・フェーダー・オートメーションとも Pass M では切り、
--            WAV・AAC・MP3 の書き出しで 1 回だけ掛ける（DDP にはフェーダーと FX を写す。v2.6.3）。
--   48/24  … 中間を「24bit Dither」トラックにアイテムとして置き、同じく「選択アイテムを
--            マスター経由」で WAV にする（通り道は 仮アイテム → 24bit Dither の FX → REAPER マスター）。
--   DDP    … 別のプロジェクトタブを開き、「16bit Dither」の FX を写したトラックに本編の中間を
--            CD の位置に並べ、!／#／@ のマーカーを置いて DDP で書き出す。書き終えたらダイアログなしで
--            閉じる（Phase 1 の E2 と同じ手順）。つこさんのプロジェクトには触らない。
-- 64bit の中間は、成功したら消し、失敗したら残して場所を知らせる（計画書 3-5）。
-- ===========================================================================
local MLIB, STORE
local function mlib()
  if not MLIB then MLIB = dofile(DIR .. "tukonya_mastering_lib.lua") end
  return MLIB
end
local function mstore()
  if not STORE then STORE = dofile(DIR .. "tukonya_render_store.lua") end
  return STORE
end
C.mlib, C.mstore = mlib, mstore


local function mst_name(tr)
  local _, nm = reaper.GetTrackName(tr)
  return tostring(nm or "")
end


-- ----- エンベロープ（オートメーション）の有効・無効（v2.6.3）-----
-- REAPER 7.80 では GetSetEnvelopeInfo_String の "ACTIVE" で読み書きできる。効かなかったときは
-- エンベロープの状態の塊（chunk）の「ACT」行を書き換える。
local function env_is_active(env)
  local ok, v = reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", "", false)
  if ok and v ~= "" then return v ~= "0" end
  local _, ch = reaper.GetEnvelopeStateChunk(env, "", false)
  return (tostring(ch):match("\nACT (%d+)") or "1") ~= "0"
end
local function env_set_active(env, on)
  if env_is_active(env) == on then return end
  reaper.GetSetEnvelopeInfo_String(env, "ACTIVE", on and "1" or "0", true)
  if env_is_active(env) ~= on then
    local _, ch = reaper.GetEnvelopeStateChunk(env, "", false)
    ch = tostring(ch):gsub("\nACT %d+", "\nACT " .. (on and "1" or "0"), 1)
    reaper.SetEnvelopeStateChunk(env, ch, false)
  end
end
-- トラックの音量・パン・幅・ミュートのエンベロープ（FX のパラメーター、テンポ、再生速度は含めない）。
-- 種類は表示名でなく状態の塊の見出しで見分ける（日本語化した REAPER では表示名が「音量」などになるため）。
--   VOLENV / PANENV / WIDTHENV … Pre-FX、VOLENV2 / VOLENV3（トリム）/ PANENV2 / WIDTHENV2 / MUTEENV … Post-FX
-- REAPER のマスタートラックは見出しの頭に MASTER が付く（MASTERVOLENV2 など。2026-09-25 MBP で確認）。
local ENV_KIND = { VOLENV = "pre", PANENV = "pre", WIDTHENV = "pre",
                   VOLENV2 = "post", VOLENV3 = "post", PANENV2 = "post", WIDTHENV2 = "post", MUTEENV = "post" }
for k, v in pairs({ VOLENV = "pre", PANENV = "pre", WIDTHENV = "pre", VOLENV2 = "post", VOLENV3 = "post",
                    PANENV2 = "post", WIDTHENV2 = "post", MUTEENV = "post" }) do ENV_KIND["MASTER" .. k] = v end
local function track_envs(tr)
  local out = {}
  if not tr then return out end
  for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
    local env = reaper.GetTrackEnvelope(tr, i)
    local _, ch = reaper.GetEnvelopeStateChunk(env, "", false)
    local tag = tostring(ch):match("^%s*<([%w_]+)")
    local kind = tag and ENV_KIND[tag]
    if kind then
      local _, nm = reaper.GetEnvelopeName(env)
      out[#out + 1] = { env = env, name = tostring(nm) .. "（" .. tag .. "）", kind = kind,
                        active = env_is_active(env), points = reaper.CountEnvelopePoints(env) }
    end
  end
  return out
end
C.track_envs, C.env_is_active = track_envs, env_is_active

-- ハード通しの段ごとのエンベロープ。stage = 1 / 2 / 3、nil なら元へ戻す。
--   MASTER の Pre-FX（音量・パン）… 1 段目だけ／それ以外（音量・パン・幅・ミュート・トリム）… 3 段目だけ
--   REAPER のマスタートラックのものは mst_rmaster が扱う。FX のパラメーターのエンベロープには触らない。
function Job:mst_envs(stage)
  for _, e in ipairs(self.mst_env_list or {}) do
    if e.owner == "MASTER" and reaper.ValidatePtr(e.env, "TrackEnvelope*") and e.active then
      local want = true
      if stage then want = (e.kind == "pre" and stage == 1) or (e.kind == "post" and stage == 3) end
      env_set_active(e.env, want)
    end
  end
end

-- プロジェクトとオーディオ機器のサンプルレート（v2.6.3）。
--   { use = 固定しているか, proj = プロジェクト設定の値, dev = オーディオ機器の値（分からなければ 0）, eff = 実際に動くレート }
function C.mst_rates()
  local use = to_int(reaper.GetSetProjectInfo(0, "PROJECT_SRATE_USE", 0, false)) ~= 0
  local proj = to_int(reaper.GetSetProjectInfo(0, "PROJECT_SRATE", 0, false))
  local dev = 0
  if reaper.GetAudioDeviceInfo then
    local ok, v = reaper.GetAudioDeviceInfo("SRATE", "")
    if ok then dev = to_int(tonumber(v) or 0) end
  end
  local eff = use and proj or dev
  return { use = use, proj = proj, dev = dev, eff = eff }
end

-- 64bit の中間と MASTER の処理のサンプルレートを数に直す（v2.6.3。0 のままでは書かない）。
-- 戻り値: レート, 理由（窓と記録にそのまま出す）
-- v2.7.0: 全タブ共通。want（0 = プロジェクトの動作レート）を数に直す。
function C.proc_rate(want)
  want = math.floor(tonumber(want) or 0)
  local r = C.mst_rates()
  if want > 0 then return want, "窓で指定" end
  if r.use and r.proj > 0 then return r.proj, "プロジェクト設定で固定" end
  if r.dev > 0 then return r.dev, "機器のレート。プロジェクト設定はサンプルレート固定なし" end
  return (r.proj > 0) and r.proj or 48000, "機器のレートが分からないのでプロジェクト設定の値"
end
-- プロジェクトの動作レート（窓の指定を見ない）
function C.run_rate() return (C.proc_rate(0)) end

function C.mst_proc_rate(cfg)
  local want = math.floor(tonumber(cfg and cfg.SRATE) or 0)
  local r = C.mst_rates()
  if want > 0 then return want, "窓で指定" end
  if r.use and r.proj > 0 then return r.proj, "プロジェクト設定で固定" end
  if r.dev > 0 then return r.dev, "機器のレート。プロジェクト設定はサンプルレート固定なし" end
  return (r.proj > 0) and r.proj or 48000, "機器のレートが分からないのでプロジェクト設定の値"
end

-- 読むだけ（書き込みはしない）。窓の一覧・関門と、書き出しの本体が同じものを使う。
-- 戻り値: info = { bus, master, d24, d16, songs = {...}, notes = {...}, solo }
--   song = { no, name, stem, track, folder, main, main_name, main_items, main_len, versions = {...} }
--   version = { track, name, stem, items, len }
--   notes = { { text, block = true/false }, ... }（出力の選び方に関係しないもの）
function C.mst_detect(cfg)
  local L = mlib()
  local info = { songs = {}, notes = {} }
  -- ver=true … 別版に関する注意（「別バージョンも書き出す」を切ったときは mst_issues で出さない。v2.6.1）
  local function note(text, block, ver)
    info.notes[#info.notes + 1] = { text = text, block = block and true or false, ver = ver and true or nil }
  end

  info.bus    = find_track_ci(cfg.BUS_NAME)
  info.master = find_track_ci(cfg.MASTER_NAME)
  info.d24    = find_track_ci(cfg.DITHER24_TRACK_NAME)
  info.d16    = find_track_ci(cfg.DITHER16_TRACK_NAME)
  info.d24_shape, info.d16_shape = track_shape(info.d24), track_shape(info.d16)
  info.solo = reaper.AnyTrackSolo(0)
  -- サンプルレート（v2.6.3）。「プロジェクトのサンプルレート」を固定していないと、REAPER はオーディオ機器のレートで動く
  info.srate = C.mst_rates()
  do   -- REAPER のマスタートラックの有効なエンベロープ（v2.6.3。64bit の中間と WAV・AAC の書き出しで 2 回かかる）
    local n = 0
    for _, e in ipairs(track_envs(reaper.GetMasterTrack(0))) do if e.active and e.points > 0 then n = n + 1 end end
    info.rmaster_envs = n
  end

  if not info.master then
    note(("『%s』という名前のトラックがありません。"):format(cfg.MASTER_NAME), true)
  else
    if to_int(reaper.GetMediaTrackInfo_Value(info.master, "I_FOLDERDEPTH")) ~= 1 then
      note(("『%s』がフォルダになっていません。『%s』を『%s』の中に入れてください。")
        :format(cfg.MASTER_NAME, cfg.BUS_NAME, cfg.MASTER_NAME), true)
    end
    if reaper.GetParentTrack(info.master) ~= nil then
      note(("『%s』が一番上の段にありません（上のフォルダの処理も一緒に書き出されます）。一番上の段に置くことをおすすめします。")
        :format(cfg.MASTER_NAME), false)
    end
  end
  if not info.bus then
    note(("『%s』という名前のトラックがありません。"):format(cfg.BUS_NAME), true)
    return info
  end
  if info.master then
    local cur, inside = reaper.GetParentTrack(info.bus), false
    while cur do
      if cur == info.master then inside = true; break end
      cur = reaper.GetParentTrack(cur)
    end
    if not inside then
      note(("『%s』が『%s』フォルダの中にありません（MASTER のプラグインを通りません）。"):format(cfg.BUS_NAME, cfg.MASTER_NAME), true)
    end
  end

  -- 親ごとの子の並び（GUID で引く）
  local kids = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local p = reaper.GetParentTrack(tr)
    if p then
      local g = reaper.GetTrackGUID(p)
      kids[g] = kids[g] or {}
      kids[g][#kids[g] + 1] = tr
    end
  end
  local function children(tr) return kids[reaper.GetTrackGUID(tr)] or {} end
  local function item_len(tr)
    local it = reaper.GetTrackMediaItem(tr, 0)
    return it and reaper.GetMediaItemInfo_Value(it, "D_LENGTH") or 0
  end
  local function lower_trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()) end

  local seen_stem = {}
  local seen_ver = {}
  local function claim(stem, who, ver)
    local k = stem:lower()
    if seen_stem[k] then
      note(("ファイル名が重なります: 『%s』と『%s』がどちらも「%s」になります。どちらかの名前を変えてください。")
        :format(seen_stem[k], who, stem), true, ver or seen_ver[k])
    else
      seen_stem[k] = who
      seen_ver[k] = ver
    end
  end

  for _, tr in ipairs(children(info.bus)) do
    local name = mst_name(tr)
    -- ミュートされた曲は飛ばす（トラック自体がミュート、またはフォルダの本編がミュート／子が全部ミュート）
    local parked = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") > 0.5
    if not parked then
      local ks = children(tr)
      if #ks > 0 then
        local named, any_unmuted = nil, false
        for _, c in ipairs(ks) do
          if not named and lower_trim(mst_name(c)) == lower_trim(name) then named = c end
          if reaper.GetMediaTrackInfo_Value(c, "B_MUTE") < 0.5 then any_unmuted = true end
        end
        if named then parked = reaper.GetMediaTrackInfo_Value(named, "B_MUTE") > 0.5
        else parked = not any_unmuted end
      end
    end
    if parked then
      note(("『%s』はミュートされているので飛ばしました。"):format(name), false)
    else
    local no = #info.songs + 1
    local stem = L.song_filename(name, { strip_number = cfg.STRIP_NUMBER })
    if stem == "" then stem = L.song_filename(name, { strip_number = false }) end
    if stem == "" then stem = ("Track%02d"):format(no) end
    stem = stem:gsub("%$", "_")   -- 「$」は REAPER のワイルドカードになるので名前に残さない
    local song = { no = no, name = name, stem = stem, track = tr, versions = {} }
    local kids_of = children(tr)
    if #kids_of == 0 then
      song.main = tr
    else
      song.folder = true
      local unmuted = {}
      for _, c in ipairs(kids_of) do
        if lower_trim(mst_name(c)) == lower_trim(name) then song.main = song.main or c end
        if reaper.GetMediaTrackInfo_Value(c, "B_MUTE") < 0.5 then unmuted[#unmuted + 1] = c end
      end
      if not song.main and #unmuted == 1 then song.main = unmuted[1] end
      for _, c in ipairs(kids_of) do
        if c ~= song.main then
          if reaper.GetMediaTrackInfo_Value(c, "B_MUTE") > 0.5 then
            local vname = mst_name(c)
            local vstem = L.song_filename(vname, { strip_number = false })
            if vstem == "" then vstem = "version" end
            vstem = vstem:gsub("%$", "_")
            song.versions[#song.versions + 1] = { track = c, name = vname, stem = vstem,
              items = reaper.CountTrackMediaItems(c), len = item_len(c) }
          else
            note(("曲『%s』の中の『%s』はミュートされていないので、別版としては書き出しません。"):format(name, mst_name(c)), false, true)
          end
        end
      end
      if not song.main then
        note(("曲『%s』の本編が分かりません。フォルダと同じ名前のトラックを置くか、ミュートしていないトラックを1本だけにしてください。")
          :format(name), true)
      end
    end
    if song.main then
      song.main_name = mst_name(song.main)
      song.main_items = reaper.CountTrackMediaItems(song.main)
      song.main_len = item_len(song.main)
      if song.main_items == 0 then
        note(("曲『%s』の本編『%s』にアイテムがありません。"):format(name, song.main_name), true)
      elseif song.main_items > 1 then
        note(("曲『%s』の本編『%s』にアイテムが %d 個あります。1つのアイテムにまとめてください。")
          :format(name, song.main_name, song.main_items), true)
      elseif song.main_len < 4.0 then
        note(("曲『%s』は4秒より短いです（%.2f秒）。CDの1曲は4秒以上が決まりです。"):format(name, song.main_len), false)
      end
      claim(stem, name)
    end
    for _, v in ipairs(song.versions) do
      if v.items == 0 then
        note(("曲『%s』の別版『%s』にアイテムが無いので、書き出しません。"):format(name, v.name), false, true)
      elseif v.items > 1 then
        note(("曲『%s』の別版『%s』にアイテムが %d 個あります。1つのアイテムにまとめてください。")
          :format(name, v.name, v.items), true, true)
      else
        claim(stem .. "_" .. v.stem, name .. " / " .. v.name, true)
      end
    end
    info.songs[#info.songs + 1] = song
    end
  end
  if #info.songs == 0 then
    note(("『%s』の中に曲がありません。"):format(cfg.BUS_NAME), true)
  end
  if info.solo then
    note("ソロになっているトラックがあります。書き出しのあいだだけソロを外し、終わったら戻します。", false)
  end
  return info
end

-- 出力の選び方（ui / cfg）に関係する点検を足した一覧。{ text, block } の並び。
-- 出力の一覧（cfg.OUTPUTS）の行ごとに、どの Dither トラックを使うかを見る。
--   WAV・AAC・MP3 の行が使うトラック … アイテムを置いて書き出す「置き場」なので、一番上の段に無ければ止める。
--   DDP の行が使う 16bit Dither … FX を別タブへ写すだけなので、段は注意だけ。
function C.mst_issues(info, cfg)
  local out = {}
  local with_versions = cfg.EXPORT_VERSIONS ~= false
  for _, n in ipairs(info.notes or {}) do
    if with_versions or not n.ver then out[#out + 1] = n end
  end
  local function add(text, block) out[#out + 1] = { text = text, block = block and true or false } end
  -- サンプルレート（v2.6.3、止めない注意）
  do
    local r = info.srate
    local want = tonumber(cfg.SRATE) or 0
    if r then
      local diff = ""
      if want > 0 and r.eff > 0 and r.eff ~= want then
        diff = ("64bit の中間ファイルは窓の指定どおり %d Hz で作ります（いまのプロジェクトは %d Hz で動いています）。"):format(want, r.eff)
      end
      if not r.use then
        -- 2026-09-25 MBP で確認: 固定していないと、REAPER の書き出しの「プロジェクトと同じ」は 44100 Hz になる。
        -- スクリプトは処理レートを数に直して書くので、その害は受けない（v2.6.3）。
        add(("プロジェクト設定で「プロジェクトのサンプルレート」が固定されていません。FX処理のサンプルレートはオーディオ機器のレート（今は %s）になります。"
          .. "レートを決めておきたいときは、プロジェクト設定で固定してください。%s"):format(
          (r.dev > 0) and (r.dev .. " Hz") or "不明", diff), false)
      elseif diff ~= "" then
        add(diff, false)
      end
    end
  end
  local rows, why = S.parse_outputs(cfg.OUTPUTS)
  if not rows then
    add("出力の一覧: " .. tostring(why), true)
    return out
  end
  -- REAPER のマスタートラックのオートメーションは WAV・AAC・MP3 に 1 回だけ掛かり、DDP には掛からない（v2.6.3）
  if (info.rmaster_envs or 0) > 0 then
    for _, r in ipairs(rows) do
      if r.fmt == "ddp" then
        add("REAPER本体のマスタートラックのオートメーションは DDP には適用されません（DDP 以外には適用されます）", false)
        break
      end
    end
  end
  local use = { track24 = nil, track16 = nil }   -- nil=使わない / "copy"=DDP だけ / "host"=置き場
  for _, r in ipairs(rows) do
    if r.dither == "track24" or r.dither == "track16" then
      local want = (r.fmt == "ddp") and "copy" or "host"
      if use[r.dither] ~= "host" then use[r.dither] = want end
    end
  end
  local function check(how, tr, shape, name)
    if not how then return end
    if not tr then
      add(("『%s』という名前のトラックがありません。作るか、その出力のディザーを「REAPERのディザー」か「なし」にしてください。"):format(name), true)
      return
    end
    if shape.folder then
      add(("『%s』がフォルダになっています（子トラックがあります）。子を持たない普通のトラックにすることをおすすめします。"):format(name), false)
    end
    if not shape.toplevel then
      if how == "host" then
        add(("『%s』が一番上の段にありません。上のフォルダの処理が二重にかかるので、一番上の段へ移してください。"):format(name), true)
      else
        add(("『%s』が一番上の段にありません。一番上の段に置くことをおすすめします。"):format(name), false)
      end
    end
    if shape.muted then
      add(("『%s』がミュートされています（書き出しのあいだだけミュートを外します）。"):format(name), false)
    end
  end
  check(use.track24, info.d24, info.d24_shape, cfg.DITHER24_TRACK_NAME)
  check(use.track16, info.d16, info.d16_shape, cfg.DITHER16_TRACK_NAME)
  return out
end

-- 出力1行の説明（記録・完了画面用）
function C.mst_output_label(r)
  if r.fmt == "wav" then
    local sr = tonumber(r.srate) or 0
    local k = sr / 1000
    local srs = (k == math.floor(k)) and ("%d"):format(k) or ("%g"):format(k)
    return ("WAV %skHz / %s"):format(srs, S.wav_format_label(r.bits))
  end
  if r.fmt == "ddp" then return "DDP" end
  return r.fmt:upper()
end

-- CD-TEXT になる曲目情報が入っているか（REAPER は CATALOG/EAN/UPC/ISRC を CD-TEXT に入れない）
local META_KEYS = { "title", "performer", "songwriter", "composer", "arranger" }
function C.mst_has_cdtext(meta)
  if type(meta) ~= "table" then return false end
  local a = meta.album or {}
  for _, k in ipairs(META_KEYS) do if (a[k] or "") ~= "" then return true end end
  for _, t in ipairs(meta.tracks or {}) do
    for _, k in ipairs(META_KEYS) do if (t[k] or "") ~= "" then return true end end
  end
  return false
end

-- 何か1つでも曲目情報があるか（EAN・ISRC だけでもマーカーに書く）
function C.mst_has_meta(meta)
  if C.mst_has_cdtext(meta) then return true end
  if type(meta) ~= "table" then return false end
  if ((meta.album or {}).ean or "") ~= "" then return true end
  for _, t in ipairs(meta.tracks or {}) do if (t.isrc or "") ~= "" then return true end end
  return false
end


local function mst_peaks_of(self, wav)
  self.passm_peaks = self.passm_peaks or {}
  self.passm_peaks[#self.passm_peaks + 1] = wav .. ".reapeaks"
  local dir, base = wav:match("^(.*)[/\\]([^/\\]+)$")
  if dir then self.passm_peaks[#self.passm_peaks + 1] = dir .. "/peaks/" .. base .. ".reapeaks" end
end

-- ----- 下ごしらえ（Mastering 専用）-----
function Job:mst_prepare()
  local cfg = self.S
  if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar) then
    abort("SWS/S&M拡張が見つかりません。SWSをインストールしてください。")
  end
  local info = C.mst_detect(cfg)
  self.mst = info
  if not info.bus then abort(("『%s』という名前のトラックが見つかりません。"):format(cfg.BUS_NAME)) end
  if not info.master then abort(("『%s』という名前のトラックが見つかりません。"):format(cfg.MASTER_NAME)) end
  self.BUS, self.MASTER = info.bus, info.master
  self.D24, self.D16 = info.d24, info.d16
  self.PROJ_A = reaper.EnumProjects(-1)
  self.mst_tmp, self.mst_items, self.mst_unmuted = {}, {}, {}

  self.FXN = reaper.TrackFX_GetCount(self.MASTER)
  for i = 0, self.FXN - 1 do self.SAVE_FX[i] = reaper.TrackFX_GetEnabled(self.MASTER, i) end
  self:snapshot()
  local r = self.restore
  if self.D24 then r.d24_fxen = reaper.GetMediaTrackInfo_Value(self.D24, "I_FXEN") end
  if self.D16 then r.d16_fxen = reaper.GetMediaTrackInfo_Value(self.D16, "I_FXEN") end
  r.marker_count = reaper.CountProjectMarkers(0)
  -- フェーダー（v2.6.0）。ハード通しの 3 段では、1・2 段目のあいだ MASTER と REAPER のマスタートラックの
  -- フェーダーを 0dB／センターにする（実際の再生では MASTER のフェーダーは ReaInsert より後ろ）。
  -- 中断したときも mst_cleanup で必ず戻す。
  -- エンベロープ（v2.6.3）。有効だったものだけを段ごとに切り替え、最後に元へ戻す
  self.mst_env_list = {}
  for _, e in ipairs(track_envs(self.MASTER)) do e.owner = "MASTER"; self.mst_env_list[#self.mst_env_list + 1] = e end
  for _, e in ipairs(track_envs(reaper.GetMasterTrack(0))) do e.owner = "RMASTER"; self.mst_env_list[#self.mst_env_list + 1] = e end
  for _, e in ipairs(self.mst_env_list) do
    self:log("エンベロープ: %s / %s（%s、点 %d 個、%s）", e.owner == "MASTER" and cfg.MASTER_NAME or "REAPERマスター",
      e.name, e.kind == "pre" and "Pre-FX" or "Post-FX", e.points, e.active and "有効" or "無効")
  end
  r.mst_master_vol = reaper.GetMediaTrackInfo_Value(self.MASTER, "D_VOL")
  r.mst_master_pan = reaper.GetMediaTrackInfo_Value(self.MASTER, "D_PAN")
  do
    local mt = reaper.GetMasterTrack(0)
    if mt then
      r.mst_rmaster_vol = reaper.GetMediaTrackInfo_Value(mt, "D_VOL")
      r.mst_rmaster_pan = reaper.GetMediaTrackInfo_Value(mt, "D_PAN")
    end
  end

  if type(cfg.RESAMPLE_MODE) == "number" and r.resample and r.resample >= 0 then
    reaper.SNM_SetIntConfigVar("projrenderresample", math.floor(cfg.RESAMPLE_MODE))
    self:log("リサンプルモード: %d（元は %d）", math.floor(cfg.RESAMPLE_MODE), r.resample)
  end
  if type(cfg.OUTPUT_DIR) == "string" and cfg.OUTPUT_DIR ~= "" then
    local dir = (cfg.OUTPUT_DIR:gsub("[/\\]+$", ""))
    reaper.RecursiveCreateDirectory(dir, 0)
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", dir, true)
    self:log("書き出し先フォルダ: %s（窓の指定）", dir)
  end

  self.reai = find_reainsert(self.MASTER, cfg.REAINSERT_MATCH)
  self.hw_mode = (self.reai ~= nil) and (self.SAVE_FX[self.reai] == true)
  self:log("MASTER FX %d 個 / ReaInsert %s / ハード通し %s", self.FXN,
    self.reai and ("番号 " .. (self.reai + 1)) or "無し", self.hw_mode and "あり" or "なし")
  self.master_mix = to_int(r.render_settings) & (~0x10EB)
  -- 「書き出したファイルをプロジェクトに入れる」が入っていると、書き出すたびにつこさんのプロジェクトへ
  -- トラックが増える。Mastering の書き出しでは必ず切る（最後に元へ戻る）。
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", to_int(r.addtoproj) & (~1), true)

  -- Pass M（64 bit float）。サンプルレートは窓の「サンプルレート」（v2.6.3。0 ならプロジェクトと同じ）。
  -- 以前は 0 固定で、「プロジェクトのサンプルレート」を固定していないプロジェクトでは
  -- オーディオ機器のレート（44.1k など）で作ってしまっていた（2026-09-25 つこさんの実案件）。
  local rs = info.srate or C.mst_rates()
  local prate, pwhy = C.mst_proc_rate(cfg)
  self.mst_prate = prate
  r.rateinternal = to_int(reaper.SNM_GetIntConfigVar("projrenderrateinternal", -1))
  self:log("FX処理のサンプルレート: %d Hz（%s）/ プロジェクト %d Hz（固定 %s）/ オーディオ機器 %s / "
    .. "「プロジェクトまたはハードウェアのサンプルレートでFXを処理」%s",
    prate, pwhy, rs.proj, rs.use and "あり" or "なし", rs.dev > 0 and (rs.dev .. " Hz") or "不明",
    (r.rateinternal == 1) and "オン" or ((r.rateinternal == 0) and "オフ" or "不明"))
  self.FMT_MST_M = {
    RENDER_FORMAT = S.wav_format_b64(64), RENDER_FORMAT2 = "",
    RENDER_SRATE = prate, RENDER_CHANNELS = 2, RENDER_DITHER = 16, RENDER_NORMALIZE = 0,
  }
end

-- DDP 用のプロジェクトタブを、ダイアログを出さずに閉じる。
-- 空のプロジェクトを「テンプレートとして」そのタブに読む（無題・未変更になる）→ 40860（いまのタブを閉じる）。
-- テンプレートとして読むと REAPER の「最近使ったプロジェクト」に載らない（2026-09-24 MBP で
-- reaper.ini の [Recent] を前後で比べて確認。Phase 1 の「保存 → 普通に開く」は一時ファイルが一覧に載った）。
function Job:mst_close_tab()
  local pB = self.DDP_PROJ
  if not pB then return true end
  self.DDP_PROJ = nil
  if not reaper.ValidatePtr(pB, "ReaProject*") then return true end
  reaper.SelectProjectInstance(pB)
  local dir = self.mst_tabdir
  local empty = dir .. "/_tukonya_empty.RPP"
  local f = io.open(empty, "w")
  if f then f:write('<REAPER_PROJECT 0.1 "7.0" 0\n>\n'); f:close() end
  self.temp_files[#self.temp_files + 1] = empty
  reaper.PreventUIRefresh(-1)
  reaper.Main_openProject("noprompt:template:" .. empty)
  reaper.Main_OnCommand(40860, 0)   -- Close current project tab
  reaper.PreventUIRefresh(1)
  if self.PROJ_A and reaper.ValidatePtr(self.PROJ_A, "ReaProject*") then
    reaper.SelectProjectInstance(self.PROJ_A)
  end
  local closed = not reaper.ValidatePtr(pB, "ReaProject*")
  self:log("DDP 用のタブを閉じた（閉じた=%s / いまのタブ=元のプロジェクト %s）", tostring(closed),
    tostring(reaper.EnumProjects(-1) == self.PROJ_A))
  return closed and reaper.EnumProjects(-1) == self.PROJ_A
end

-- ----- 後片付け（Mastering 専用。最初に DDP のタブを閉じて、元のプロジェクトへ戻る）-----
function Job:mst_cleanup()
  local r = self.restore
  if self.DDP_PROJ then
    local ok, closed = pcall(Job.mst_close_tab, self)
    if not ok or not closed then
      self:warn("DDP 用に開いたプロジェクトタブを閉じられませんでした。保存せずに閉じてください（つこさんのプロジェクトではありません）。")
    end
  end
  if self.PROJ_A and reaper.ValidatePtr(self.PROJ_A, "ReaProject*") and reaper.EnumProjects(-1) ~= self.PROJ_A then
    reaper.SelectProjectInstance(self.PROJ_A)
  end
  for _, it in ipairs(self.mst_items or {}) do
    if reaper.ValidatePtr(it, "MediaItem*") then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    end
  end
  self.mst_items = {}
  for _, u in ipairs(self.mst_item_mutes or {}) do
    if reaper.ValidatePtr(u.item, "MediaItem*") then reaper.SetMediaItemInfo_Value(u.item, "B_MUTE", u.v) end
  end
  if self.D24 and reaper.ValidatePtr(self.D24, "MediaTrack*") and r.d24_fxen ~= nil then
    reaper.SetMediaTrackInfo_Value(self.D24, "I_FXEN", r.d24_fxen)
  end
  if self.D16 and reaper.ValidatePtr(self.D16, "MediaTrack*") and r.d16_fxen ~= nil then
    reaper.SetMediaTrackInfo_Value(self.D16, "I_FXEN", r.d16_fxen)
  end
  self:mst_faders(false)   -- MASTER と REAPER のマスタートラックのフェーダーを元へ（v2.6.0）
  self:mst_envs(nil)       -- エンベロープの有効・無効を元へ（v2.6.3）
  self:mst_rmaster(false)  -- REAPER のマスタートラックのフェーダーとオートメーションを元へ（v2.6.3）
  if r.rateinternal ~= nil and r.rateinternal >= 0 and reaper.EnumProjects(-1) == self.PROJ_A then
    reaper.SNM_SetIntConfigVar("projrenderrateinternal", r.rateinternal)
  end
  Job.cleanup(self)
  if not self.mst_ok and #(self.mst_tmp or {}) > 0 then
    local kept = {}
    for _, p in ipairs(self.mst_tmp) do if reaper.file_exists(p) then kept[#kept + 1] = p end end
    if #kept > 0 then
      self.mst_kept_dir = self.mst_tmpdir
      self:warn(("64bit の中間ファイルを %d 本残しました（途中で止まったため。次に書き出すときに自動で消します）: %s"):format(#kept, tostring(self.mst_tmpdir)))
    end
  end
end

-- MASTER と REAPER のマスタートラックのフェーダー（音量・パン）。
--   neutral=true … 0dB／センターにする（ハード通しの 1・2 段目）
--   neutral=false … mst_prepare で控えた値へ戻す（3 段目と後片付け）
function Job:mst_faders(neutral)
  local r = self.restore or {}
  if self.MASTER and reaper.ValidatePtr(self.MASTER, "MediaTrack*") and r.mst_master_vol ~= nil then
    reaper.SetMediaTrackInfo_Value(self.MASTER, "D_VOL", neutral and 1.0 or r.mst_master_vol)
    reaper.SetMediaTrackInfo_Value(self.MASTER, "D_PAN", neutral and 0.0 or r.mst_master_pan)
  end
end
-- REAPER のマスタートラックのフェーダーとオートメーション（v2.6.3、2026-09-25 決定）。
-- FX と同じく、64bit の中間（Pass M のすべての段）では切り、WAV・AAC・MP3 の書き出しで 1 回だけ掛ける。
--   neutral=true … 0dB／センター・エンベロープ無効 / false … 元へ戻す
function Job:mst_rmaster(neutral)
  local r = self.restore or {}
  local mt = reaper.GetMasterTrack(0)
  if mt and r.mst_rmaster_vol ~= nil then
    reaper.SetMediaTrackInfo_Value(mt, "D_VOL", neutral and 1.0 or r.mst_rmaster_vol)
    reaper.SetMediaTrackInfo_Value(mt, "D_PAN", neutral and 0.0 or r.mst_rmaster_pan)
  end
  for _, e in ipairs(self.mst_env_list or {}) do
    if e.owner == "RMASTER" and e.active and reaper.ValidatePtr(e.env, "TrackEnvelope*") then
      env_set_active(e.env, not neutral)
    end
  end
end

-- 書き出し1本ぶんのあいだ、そのトラックと親のミュートを外す（書き終えたら戻す）
function Job:mst_unmute_path(tr)
  local list = {}
  local cur = tr
  while cur do
    if reaper.GetMediaTrackInfo_Value(cur, "B_MUTE") > 0.5 then
      reaper.SetMediaTrackInfo_Value(cur, "B_MUTE", 0)
      list[#list + 1] = cur
    end
    cur = reaper.GetParentTrack(cur)
  end
  return list
end

local function dir_of(p) return (tostring(p or ""):match("^(.*)[/\\][^/\\]+$")) end

-- 出力1行ぶんの書き出し形式（WAV・AAC・MP3。DDP は別タブで組む）
local function mst_row_format(cfg, r)
  local fmt, srate = nil, 0
  if r.fmt == "wav" then fmt, srate = S.wav_format_b64(r.bits), r.srate
  elseif r.fmt == "aac" then fmt = S.AAC_FORMAT2
  elseif r.fmt == "mp3" then fmt = S.MP3_FORMAT2 end
  return {
    RENDER_FORMAT = fmt, RENDER_FORMAT2 = "",
    RENDER_SRATE = srate, RENDER_CHANNELS = 2,
    RENDER_DITHER = (r.dither == "reaper") and cfg.REAPER_DITHER_BITS or 16,
    RENDER_NORMALIZE = 0,
  }
end
C.mst_row_format = mst_row_format

-- ----- 本体 -----
function FLOW.mastering(j)
  local cfg, L = j.S, mlib()
  local info = j.mst

  -- 1. 点検（止めるものがあれば、何も書き出さずに止める）
  local blocks = {}
  for _, is in ipairs(C.mst_issues(info, cfg)) do
    if is.block then blocks[#blocks + 1] = is.text else j:warn(is.text) end
  end
  if #blocks > 0 then abort("書き出せません:\n・" .. table.concat(blocks, "\n・")) end

  -- 2. 書き出す単位（本編と別版）
  local units, mains = {}, {}
  local with_versions = cfg.EXPORT_VERSIONS ~= false
  if not with_versions then j:log("別バージョン: 書き出さない（設定「別バージョンも書き出す」が切ってある）") end
  for _, s in ipairs(info.songs) do
    local u = { song = s, track = s.main, name = s.stem, kind = "main" }
    units[#units + 1] = u
    mains[#mains + 1] = u
    for _, v in ipairs(with_versions and s.versions or {}) do
      if v.items == 1 then
        units[#units + 1] = { song = s, track = v.track, name = s.stem .. "_" .. v.stem, kind = "version" }
      end
    end
  end
  j:log("曲 %d 曲 / 書き出す単位 %d 本（本編 %d ＋ 別版 %d）", #info.songs, #units, #mains, #units - #mains)

  -- 3. 名前と置き場を先に決める（REAPER自身に解かせる）。同じ名前が既にあれば、
  --    フォルダに -001, -002 … を付けて、上書きの確認の窓で止まらないようにする。
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix, true)
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 1, true)
  local meta = mstore().load_meta()
  local has_meta = C.mst_has_meta(meta)
  local has_cdtext = C.mst_has_cdtext(meta)
  local projname = reaper.GetProjectName(0, "")   -- 戻り値は名前1つ（.RPP 付き）
  projname = tostring(projname or ""):gsub("%.[Rr][Pp][Pp]$", "")
  local album_stem = L.song_filename((meta.album and meta.album.title ~= "" and meta.album.title) or projname,
    { strip_number = false })
  album_stem = album_stem:gsub("%$", "_")
  if album_stem == "" then album_stem = "DDP" end
  local rows = assert(S.parse_outputs(cfg.OUTPUTS))   -- 点検で壊れた一覧は止めてある
  for _, r in ipairs(rows) do
    if r.fmt ~= "ddp" then r.FMT = mst_row_format(cfg, r) end
  end
  local FMT_DDP_PROBE = mst_row_format(cfg, { fmt = "wav", bits = "pcm16", srate = 44100, dither = "none" })
  local function row_target(r, suf, name) return j:resolve_target(r.folder .. suf .. "/" .. name, r.FMT) end
  local function ddp_dir(r, suf) return dir_of(j:resolve_target(r.folder .. suf .. "/" .. album_stem, FMT_DDP_PROBE)) end
  local suffix = j:resolve_suffix(function(suf)
    local set = {}
    for _, r in ipairs(rows) do
      if r.fmt == "ddp" then
        local d = ddp_dir(r, suf)
        if d then
          set[#set + 1] = d .. "/DDPID"
          set[#set + 1] = d .. "/PQDESCR"
          set[#set + 1] = d .. "/IMAGE.DAT"
        end
      else
        for _, u in ipairs(units) do set[#set + 1] = row_target(r, suf, u.name) end
      end
    end
    return set
  end)
  if suffix ~= "" then j:log("同じ名前のファイルがあるので、フォルダ名に %s を付けた", suffix) end
  j.mst_out_dirs = {}
  local DDP_ROW, DDP_DIR, DDP_IDX
  for ri, r in ipairs(rows) do
    if r.fmt == "ddp" then
      DDP_ROW, DDP_DIR, DDP_IDX = r, ddp_dir(r, suffix), ri
      r.dir = DDP_DIR
    else
      r.want = {}
      for k, u in ipairs(units) do r.want[k] = row_target(r, suffix, u.name) end
      r.dir = dir_of(r.want[1])
    end
    j.mst_out_dirs[#j.mst_out_dirs + 1] = { label = C.mst_output_label(r), dir = r.dir, fmt = r.fmt }
  end
  j.mst_ddp_dir = DDP_DIR

  -- 4. Pass M（曲ごと・版ごとに 64 bit float。MASTER を通るのはここだけ）
  -- 4a. 前回中断したときに残した中間ファイルを消す（v2.6.2）。作業フォルダの中身が自分の中間ファイル
  --     （NN*.wav / NN*.reapeaks / _tukonya_empty.RPP、peaks/ の NN*.reapeaks）だけのときに限る。
  do
    j:apply_format(j.FMT_MST_M)
    j:set_pattern(cfg.TMP_PREFIX .. "_mastering/01")
    local tdir = dir_of(j:target())
    local function ours(fn)
      return fn:match("^%d%d[%w_%-]*%.wav$") or fn:match("^%d%d[%w_%-]*%.wav%.reapeaks$")
        or fn:match("^%d%d[%w_%-]*%.reapeaks$") or fn == "_tukonya_empty.RPP"
    end
    local function list(d)
      local t, i = {}, 0
      if not reaper.EnumerateFiles then return t end
      reaper.EnumerateFiles(d, -1)
      while true do
        local fn = reaper.EnumerateFiles(d, i)
        if not fn then break end
        t[#t + 1] = fn
        i = i + 1
      end
      return t
    end
    local files = tdir and list(tdir) or {}
    local pfiles = tdir and list(tdir .. "/peaks") or {}
    if #files + #pfiles > 0 then
      local foreign = {}
      for _, fn in ipairs(files) do if not ours(fn) then foreign[#foreign + 1] = fn end end
      for _, fn in ipairs(pfiles) do if not ours(fn) then foreign[#foreign + 1] = "peaks/" .. fn end end
      if #foreign > 0 then
        j:warn(("作業フォルダに見覚えのないファイルがあるので、前回の中間ファイルはまとめて消しませんでした（%s）: %s")
          :format(table.concat(foreign, ", "), tdir))
      else
        for _, fn in ipairs(files) do
          pcall(os.remove, tdir .. "/" .. fn)
          j:log("前回の中間ファイルを消した: %s", tdir .. "/" .. fn)
        end
        for _, fn in ipairs(pfiles) do
          pcall(os.remove, tdir .. "/peaks/" .. fn)
          j:log("前回の中間ファイルを消した: %s", tdir .. "/peaks/" .. fn)
        end
        if reaper.EnumerateFiles then reaper.EnumerateFiles(tdir, -1) end
      end
    end
  end
  for _, tr in ipairs({ j.D24, j.D16 }) do
    if tr then reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0) end
  end
  for i = 0, reaper.CountTracks(0) - 1 do    -- ソロは書き出しのあいだだけ外す（最後に戻る）
    local tr = reaper.GetTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_SOLO") ~= 0 then reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 0) end
  end
  j:set_rmaster_fx(false)
  j:mst_rmaster(true)   -- REAPER のマスタートラックのフェーダーとオートメーションも中間では切る（v2.6.3）
  if j.hw_mode then
    -- ハード通し（v2.6.0）: 2mix Render タブと同じく 3 段に分ける。実時間になるのは 2 段目だけ。
    --   1 段目 … 本編／別版のアイテムだけを選び、MASTER の FX を全部切って 64 bit float に（オフライン）
    --   2 段目 … 1 段目の音を MASTER トラック自身のアイテムとして置き（2MIXBUS は通らない）、
    --            MASTER の FX を ReaInsert まで（保存どおり）にして 64 bit float に（実時間）
    --   3 段目 … 2 段目の音を同じく置き、ReaInsert より後ろの FX（保存どおり）で NN.wav に（オフライン）
    -- 1・2 段目のあいだ MASTER と REAPER のマスタートラックのフェーダーは 0dB／センター。
    -- 3 段目で元へ戻すので、フェーダーがかかるのは今までの 1 本通しと同じ回数（ReaInsert の後ろ）。
    reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- 1 段目はオフライン
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix | 64, true)   -- 選択アイテムをマスター経由
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)                 -- 選択アイテムの範囲
    j.passm_touched_items = true
    j.mst_item_mutes = {}
    -- stage … "1" / "2" / "3"（記録の段の番号）
    local function mst_stage(k, u, pat, sel, len, label, stage)
      j:apply_format(j.FMT_MST_M)
      j:set_pattern(cfg.TMP_PREFIX .. "_mastering/" .. pat)
      j:select_only_item(sel)
      local wav = j:tmp_target()
      if not wav then abort("64bit の中間ファイルの書き出し先が分かりませんでした。中断します。") end
      j.mst_tmpdir = j.mst_tmpdir or dir_of(wav)
      if reaper.file_exists(wav) then pcall(os.remove, wav) end
      j.mst_tmp[#j.mst_tmp + 1] = wav
      mst_peaks_of(j, wav)
      j:log("Pass M-%s %d/%d（%s、%s）: %s", stage, k, #units, u.name, label, wav)
      j:render(wav)
      local frames, why, _, sr = wav_frames(wav)
      if not frames or frames <= 0 or not sr or sr <= 0 then
        abort(("64bit の中間ファイルを読めませんでした（%s）。中断します。\n%s"):format(tostring(why), wav))
      end
      local want = math.floor(len * sr + 0.5)
      if math.abs(frames - want) > 1 then
        abort(("64bit の中間ファイルの長さが合いません（%d frames / 期待 %d ±1）。中断します。\n%s"):format(frames, want, wav))
      end
      j:log("  中間ファイル: %d frames / %d Hz（書き終えたときのオーディオ機器 %d Hz）", frames, sr, C.mst_rates().dev)
      return wav, frames, sr
    end
    local function drop_item(it)
      if it and reaper.ValidatePtr(it, "MediaItem*") then
        reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
      end
      for i = #j.mst_items, 1, -1 do if j.mst_items[i] == it then table.remove(j.mst_items, i) end end
    end
    local function drop_wav(wav)
      pcall(os.remove, wav)
      pcall(os.remove, wav .. ".reapeaks")
      local d, b = wav:match("^(.*)[/\\]([^/\\]+)$")
      if d then pcall(os.remove, d .. "/peaks/" .. b .. ".reapeaks") end
    end
    -- 2・3 段目の置き場: MASTER の最初の子に入れる仮トラック（子を持たないので、ここの音だけが MASTER を通る）。
    -- MASTER トラック自身にアイテムを置くと、「選択アイテムをマスター経由」でも MASTER の中の
    -- 全トラック（2MIXBUS と曲）が一緒に鳴る（2026-09-24 MBP の試験で確認）ので使わない。
    local hw_host
    do
      local snap = parent_guid_map()
      local idx = track_index0(j.MASTER) + 1
      reaper.InsertTrackAtIndex(idx, false)
      hw_host = reaper.GetTrack(0, idx)
      if not hw_host then abort("仮トラックを作れませんでした。中断します。") end
      j.created_tracks[#j.created_tracks + 1] = hw_host
      reaper.SetMediaTrackInfo_Value(hw_host, "I_FOLDERDEPTH", 0)
      reaper.GetSetMediaTrackInfo_String(hw_host, "P_NAME", "_tmp_mastering_hw", true)
      reaper.SetMediaTrackInfo_Value(hw_host, "D_VOL", 1.0)
      reaper.SetMediaTrackInfo_Value(hw_host, "D_PAN", 0.0)
      reaper.SetMediaTrackInfo_Value(hw_host, "D_PANLAW", 1.0)
      reaper.SetMediaTrackInfo_Value(hw_host, "B_MAINSEND", 1)
      reaper.SetMediaTrackInfo_Value(hw_host, "I_FXEN", 1)
      local bad = parents_changed(snap)
      if bad then abort(("仮トラックを差し込んだら『%s』の親が変わってしまいました。中断します。"):format(bad)) end
      if reaper.GetParentTrack(hw_host) ~= j.MASTER then
        abort(("仮トラックを『%s』の中に入れられませんでした。中断します。"):format(cfg.MASTER_NAME))
      end
    end
    for k, u in ipairs(units) do
      local item = reaper.GetTrackMediaItem(u.track, 0)
      if not item then abort(("『%s』のアイテムが見つかりません。中断します。"):format(u.name)) end
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      -- 2・3 段目と 5. の置き場所は、元のアイテムと同じ時刻（v2.6.3）。MASTER のエンベロープ
      -- （フェードなど）と FX のパラメーターのエンベロープが、曲の同じ場所に掛かるように。
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      u.pos = pos
      local nn = ("%02d"):format(k)

      -- 1 段目（オフライン）: 2MIXBUS まで。MASTER の FX は全部切る
      j:mst_faders(true)
      j:mst_envs(1)
      j:set_master_all(false)
      if reaper.GetMediaItemInfo_Value(item, "B_MUTE") > 0.5 then
        j.mst_item_mutes[#j.mst_item_mutes + 1] = { item = item, v = 1 }
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
      end
      local un = j:mst_unmute_path(u.track)
      local wav1, fr1, sr1 = mst_stage(k, u, nn .. "_pre", item, len, "オフライン", "1")
      mst_remute(un)

      -- 2 段目（実時間）: MASTER の中の仮トラックに置く（2MIXBUS は通らない）。FX は ReaInsert まで
      j:set_master_up_to_reai()
      j:mst_envs(2)
      local it2 = mst_put_item(hw_host, wav1, pos, fr1, sr1)
      j.mst_items[#j.mst_items + 1] = it2
      local hun = j:mst_unmute_path(hw_host)
      reaper.SNM_SetIntConfigVar("projrenderlimit", 2) -- Online Render（ハード通しは必須）
      local chk = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", -1))
      if chk ~= 2 then
        abort(("レンダー速度を Online にできませんでした（現在値=%d）。\nハードを通らない書き出しを防ぐため中断します。"):format(chk))
      end
      local wav2, fr2, sr2 = mst_stage(k, u, nn .. "_hw", it2, len, "実時間・ReaInsertまで", "2")
      reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- ここから先はオフライン
      drop_item(it2)

      -- 3 段目（オフライン）: ReaInsert より後ろ。フェーダーを元へ戻す。名前は今までの Pass M と同じ NN.wav
      j:mst_faders(false)
      j:set_master_after_reai()
      j:mst_envs(3)
      local it3 = mst_put_item(hw_host, wav2, pos, fr2, sr2)
      j.mst_items[#j.mst_items + 1] = it3
      local wav, frames, sr = mst_stage(k, u, nn, it3, len, "オフライン・ReaInsert以降", "3")
      drop_item(it3)
      mst_remute(hun)
      drop_wav(wav1)
      drop_wav(wav2)
      u.wav_m, u.frames, u.srate = wav, frames, sr
    end
    j:set_master_original()
    j:mst_envs(nil)
    if reaper.ValidatePtr(hw_host, "MediaTrack*") then reaper.DeleteTrack(hw_host) end   -- 5. の前に消す
  else
    if j.hw_mode then
      reaper.SNM_SetIntConfigVar("projrenderlimit", 2) -- Online Render（ハード通しは必須）
      local chk = to_int(reaper.SNM_GetIntConfigVar("projrenderlimit", -1))
      if chk ~= 2 then
        abort(("レンダー速度を Online にできませんでした（現在値=%d）。\nハードを通らない書き出しを防ぐため中断します。"):format(chk))
      end
    else
      reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- Full-speed Offline
    end
    reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix | 64, true)   -- 選択アイテムをマスター経由
    reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)                 -- 選択アイテムの範囲
    j.passm_touched_items = true
    j.mst_item_mutes = {}
    for k, u in ipairs(units) do
      local item = reaper.GetTrackMediaItem(u.track, 0)
      if not item then abort(("『%s』のアイテムが見つかりません。中断します。"):format(u.name)) end
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      u.pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")   -- 5. の置き場所（v2.6.3）
      j:apply_format(j.FMT_MST_M)
      j:set_pattern(cfg.TMP_PREFIX .. "_mastering/" .. ("%02d"):format(k))
      j:select_only_item(item)
      local wav = j:tmp_target()
      if not wav then abort("64bit の中間ファイルの書き出し先が分かりませんでした。中断します。") end
      j.mst_tmpdir = j.mst_tmpdir or dir_of(wav)
      if reaper.file_exists(wav) then pcall(os.remove, wav) end
      j.mst_tmp[#j.mst_tmp + 1] = wav
      mst_peaks_of(j, wav)
      if reaper.GetMediaItemInfo_Value(item, "B_MUTE") > 0.5 then
        j.mst_item_mutes[#j.mst_item_mutes + 1] = { item = item, v = 1 }
        reaper.SetMediaItemInfo_Value(item, "B_MUTE", 0)
      end
      local un = j:mst_unmute_path(u.track)
      j:log("Pass M %d/%d（%s、%s）: %s", k, #units, u.name, j.hw_mode and "実時間" or "オフライン", wav)
      j:render(wav)
      mst_remute(un)
      local frames, why, _, sr = wav_frames(wav)
      if not frames or frames <= 0 or not sr or sr <= 0 then
        abort(("64bit の中間ファイルを読めませんでした（%s）。中断します。\n%s"):format(tostring(why), wav))
      end
      local want = math.floor(len * sr + 0.5)
      if math.abs(frames - want) > 1 then
        abort(("64bit の中間ファイルの長さが合いません（%d frames / 期待 %d ±1）。中断します。\n%s"):format(frames, want, wav))
      end
      j:log("  中間ファイル: %d frames / %d Hz", frames, sr)
      u.wav_m, u.frames, u.srate = wav, frames, sr
    end
  end
  j:set_rmaster_fx(true)
  j:mst_rmaster(false)
  reaper.SNM_SetIntConfigVar("projrenderlimit", 0) -- ここから先はオフライン（速い）

  -- 5. WAV・AAC・MP3（出力の一覧の行ごと）。64bit の中間を置き場のトラックにアイテムとして置き、
  --    「選択アイテムをマスター経由」で書き出す（通り道は 仮アイテム → 置き場の FX → REAPER マスター）。
  --    置き場は ディザー=24bit／16bit Dither トラックならそのトラック、REAPER・なし なら一番上の段の仮トラック。
  -- 「プロジェクトまたはハードウェアのサンプルレートでFXを処理」を切る（v2.6.3）。オンのままだと、出力のレートが
  -- 中間と違う行（44.1/16 など）で、ディザーのプラグインが中間のレートで動いたあとに変換され、ディザーが壊れる。
  -- 切れば、ディザーを含む通り道全体が出力のレートで動く。元の値は後片付けで戻す。
  if (j.restore.rateinternal or -1) >= 0 then
    reaper.SNM_SetIntConfigVar("projrenderrateinternal", 0)
    j:log("「プロジェクトまたはハードウェアのサンプルレートでFXを処理」: 書き出しのあいだ オフ（元は %s）",
      (j.restore.rateinternal == 1) and "オン" or "オフ")
  end
  local tmp_host
  local function plain_host()
    if tmp_host and reaper.ValidatePtr(tmp_host, "MediaTrack*") then return tmp_host end
    local snap = parent_guid_map()
    reaper.InsertTrackAtIndex(0, false)
    local host = reaper.GetTrack(0, 0)
    if not host then abort("仮トラックを作れませんでした。中断します。") end
    j.created_tracks[#j.created_tracks + 1] = host
    reaper.SetMediaTrackInfo_Value(host, "I_FOLDERDEPTH", 0)
    reaper.GetSetMediaTrackInfo_String(host, "P_NAME", "_tmp_mastering", true)
    reaper.SetMediaTrackInfo_Value(host, "D_VOL", 1.0)
    reaper.SetMediaTrackInfo_Value(host, "D_PAN", 0.0)
    reaper.SetMediaTrackInfo_Value(host, "D_PANLAW", 1.0)
    reaper.SetMediaTrackInfo_Value(host, "B_MAINSEND", 1)
    local bad = parents_changed(snap)
    if bad then abort(("仮トラックを差し込んだら『%s』の親が変わってしまいました。中断します。"):format(bad)) end
    tmp_host = host
    return host
  end
  for ri, r in ipairs(rows) do
    if r.fmt ~= "ddp" then
      local host, hname
      if r.dither == "track24" then host, hname = j.D24, cfg.DITHER24_TRACK_NAME
      elseif r.dither == "track16" then host, hname = j.D16, cfg.DITHER16_TRACK_NAME end
      if (r.dither == "track24" or r.dither == "track16") and not host then
        abort(("『%s』トラックが見つかりません。中断します。"):format(hname))
      end
      if host then
        reaper.SetMediaTrackInfo_Value(host, "I_FXEN", 1)
        local dv = reaper.GetMediaTrackInfo_Value(host, "D_VOL")
        local dp = reaper.GetMediaTrackInfo_Value(host, "D_PAN")
        if math.abs(dv - 1.0) > 1e-6 or math.abs(dp) > 1e-6 then
          j:warn(("『%s』トラックのフェーダーが0dB／センターではありません（音量 %.6f / パン %.6f）。"):format(hname, dv, dp))
        end
      else
        host = plain_host()
      end
      local hun = j:mst_unmute_path(host)
      reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", j.master_mix | 64, true)
      reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 4, true)
      local t0 = clock()
      local nout = 0
      for k, u in ipairs(units) do
        local it = mst_put_item(host, u.wav_m, u.pos or 0.0, u.frames, u.srate)
        j.mst_items[#j.mst_items + 1] = it
        j:select_only_item(it)
        j:apply_format(r.FMT)
        j:set_pattern(r.folder .. suffix .. "/" .. u.name)
        local got = j:target()
        if not got then abort(("%s の書き出し先が分かりませんでした。中断します。"):format(C.mst_output_label(r))) end
        if r.fmt == "wav" then
          local out_sr = (r.srate > 0) and r.srate or u.srate
          j.expect_frames = math.floor(u.frames * out_sr / u.srate + 0.5)
          j.expect_tol = (out_sr ~= u.srate) and 2 or 1
        end
        j:render(got)
        j.expect_frames, j.expect_tol = nil, nil
        local want = r.want[k]
        if want and got ~= want then
          local okr, errr = os.rename(got, want)
          if not okr then abort(("書き出したファイルの名前を戻せませんでした（%s → %s: %s）。中断します。"):format(got, want, tostring(errr))) end
          got = want
        end
        if r.fmt ~= "wav" then
          local f = io.open(got, "rb")
          local sz = f and f:seek("end") or 0
          if f then f:close() end
          if not sz or sz <= 0 then abort(("書き出したファイルが空です。中断します。\n%s"):format(got)) end
        end
        j:add_produced(got)
        nout = nout + 1
        reaper.DeleteTrackMediaItem(host, it)
        j.mst_items[#j.mst_items] = nil
      end
      mst_remute(hun)
      if host == j.D24 or host == j.D16 then reaper.SetMediaTrackInfo_Value(host, "I_FXEN", 0) end
      j:log("出力 %d/%d: %s / ディザー=%s / 置き場=%s → %s（%d 本、%.2f 秒）", ri, #rows, C.mst_output_label(r),
        S.OUTPUT_DITHER_LABELS[r.dither] or r.dither, mst_name(host), tostring(r.dir), nout, clock() - t0)
    end
  end

  -- 6. DDP（別のプロジェクトタブで。つこさんのプロジェクトには触らない）
  if DDP_ROW then
    local durs = {}
    for i, u in ipairs(mains) do durs[i] = u.frames / u.srate end
    local layout, lw = L.cd_layout(durs, { pregap_first = cfg.GAP_FIRST, gap = cfg.GAP_TRACKS })
    for _, w in ipairs(lw or {}) do j:warn(w) end
    local mk = L.marker_strings(meta)
    if has_meta and #(meta.tracks or {}) ~= #mains then
      j:warn(("曲の数（%d）と曲目情報の行数（%d）が違います。曲は上から順に行と対応させました。"):format(#mains, #(meta.tracks or {})))
    end
    local projA = j.PROJ_A
    local nA_tracks, nA_markers = reaper.CountTracks(projA), reaper.CountProjectMarkers(projA)
    local srate_m = mains[1].srate
    j.mst_tabdir = j.mst_tmpdir
    local src16 = (DDP_ROW.dither == "track16") and j.D16 or nil
    if DDP_ROW.dither == "track16" and not src16 then
      abort(("『%s』トラックが見つかりません。中断します。"):format(cfg.DITHER16_TRACK_NAME))
    end
    local rmaster = reaper.GetMasterTrack(projA)
    local rmaster_on = rmaster and reaper.GetMediaTrackInfo_Value(rmaster, "I_FXEN") > 0.5
    local rm_vol = rmaster and reaper.GetMediaTrackInfo_Value(rmaster, "D_VOL") or 1.0
    local rm_pan = rmaster and reaper.GetMediaTrackInfo_Value(rmaster, "D_PAN") or 0.0

    reaper.PreventUIRefresh(-1)
    reaper.Main_OnCommand(40859, 0)   -- New project tab
    reaper.PreventUIRefresh(1)
    local projB = reaper.EnumProjects(-1)
    if not projB or projB == projA then abort("DDP 用の新しいプロジェクトタブを開けませんでした。中断します。") end
    j.DDP_PROJ = projB
    j:log("DDP 用のタブを開いた")
    -- 新しいタブは既定のテンプレートで中身が入っていることがある。空にしてから使う。
    for i = reaper.CountTracks(projB) - 1, 0, -1 do reaper.DeleteTrack(reaper.GetTrack(projB, i)) end
    for i = reaper.CountProjectMarkers(projB) - 1, 0, -1 do reaper.DeleteProjectMarkerByIndex(projB, i) end
    local mB = reaper.GetMasterTrack(projB)
    for i = reaper.TrackFX_GetCount(mB) - 1, 0, -1 do reaper.TrackFX_Delete(mB, i) end
    -- REAPER のマスタートラックのフェーダーを写す（WAV と同じく 1 回だけ掛ける。v2.6.3）
    reaper.SetMediaTrackInfo_Value(mB, "D_VOL", rm_vol)
    reaper.SetMediaTrackInfo_Value(mB, "D_PAN", rm_pan)
    reaper.SetMediaTrackInfo_Value(mB, "B_MUTE", 0)
    if math.abs(rm_vol - 1.0) > 1e-9 or math.abs(rm_pan) > 1e-9 then
      j:log("REAPER のマスタートラックのフェーダー（音量 %.6f / パン %.6f）を DDP 用のタブへ写した", rm_vol, rm_pan)
    end
    reaper.GetSetProjectInfo(projB, "PROJECT_SRATE", srate_m, true)
    reaper.GetSetProjectInfo(projB, "PROJECT_SRATE_USE", 1, true)
    -- 44.1k への変換のやり方（リサンプルモード）は新しいタブには引き継がれないので、ここで揃える
    do
      local want = (type(cfg.RESAMPLE_MODE) == "number") and math.floor(cfg.RESAMPLE_MODE) or j.restore.resample
      if want and want >= 0 then
        reaper.SNM_SetIntConfigVar("projrenderresample", want)
        j:log("DDP タブのリサンプルモード: %d（現在値 %d）", want, to_int(reaper.SNM_GetIntConfigVar("projrenderresample", -1)))
      end
      -- DDP のタブでも、16bit Dither の FX を 44.1k で動かす（v2.6.3）
      if (j.restore.rateinternal or -1) >= 0 then
        reaper.SNM_SetIntConfigVar("projrenderrateinternal", 0)
        j:log("DDP タブの「プロジェクトまたはハードウェアのサンプルレートでFXを処理」: オフ（現在値 %d）",
          to_int(reaper.SNM_GetIntConfigVar("projrenderrateinternal", -1)))
      end
    end
    -- REAPER のマスタートラックの FX（48/24 では通る）を、DDP 側のマスターにも写す（同じ音にするため）
    if rmaster_on then
      local n = reaper.TrackFX_GetCount(rmaster)
      for i = 0, n - 1 do
        reaper.TrackFX_CopyToTrack(rmaster, i, mB, i, false)
        reaper.TrackFX_SetEnabled(mB, i, reaper.TrackFX_GetEnabled(rmaster, i))
      end
      if reaper.TrackFX_GetCount(mB) ~= n then abort("REAPER のマスタートラックの FX を DDP 用のタブへ写せませんでした。中断します。") end
      if n > 0 then j:log("REAPER のマスタートラックの FX %d 個を DDP 用のタブへ写した", n) end
    end
    reaper.InsertTrackAtIndex(0, false)
    local trB = reaper.GetTrack(projB, 0)
    if not trB then abort("DDP 用のトラックを作れませんでした。中断します。") end
    reaper.GetSetMediaTrackInfo_String(trB, "P_NAME", "16bit Dither (TUKONYA)", true)
    reaper.SetMediaTrackInfo_Value(trB, "D_VOL", 1.0)
    reaper.SetMediaTrackInfo_Value(trB, "D_PAN", 0.0)
    reaper.SetMediaTrackInfo_Value(trB, "D_PANLAW", 1.0)
    if src16 then
      local n = reaper.TrackFX_GetCount(src16)
      for i = 0, n - 1 do
        reaper.TrackFX_CopyToTrack(src16, i, trB, i, false)
        reaper.TrackFX_SetEnabled(trB, i, reaper.TrackFX_GetEnabled(src16, i))
      end
      if reaper.TrackFX_GetCount(trB) ~= n then abort(("『%s』の FX を DDP 用のタブへ写せませんでした。中断します。"):format(cfg.DITHER16_TRACK_NAME)) end
      reaper.SetMediaTrackInfo_Value(trB, "I_FXEN", 1)
      j:log("『%s』の FX %d 個を DDP 用のタブへ写した", cfg.DITHER16_TRACK_NAME, n)
    else
      reaper.SetMediaTrackInfo_Value(trB, "I_FXEN", 0)
    end
    for i, u in ipairs(mains) do
      local tpos = layout.tracks[i]
      mst_put_item(trB, u.wav_m, tpos.start, u.frames, u.srate)
      if tpos.index0 < tpos.start - 1e-9 then
        reaper.AddProjectMarker2(projB, false, tpos.index0, 0, "!", -1, 0)
      end
      local name = (has_meta and mk.tracks[i]) or "#"
      reaper.AddProjectMarker2(projB, false, tpos.start, 0, name, -1, 0)
      j:log("  CD %d: INDEX0 %.4f / INDEX1 %.4f / %.4f 秒 / %s", i, tpos.index0, tpos.start, tpos.length, name)
    end
    if has_meta and mk.album ~= "@" then
      reaper.AddProjectMarker2(projB, false, 0.0, 0, mk.album, -1, 0)
      j:log("  アルバム: %s", mk.album)
    end
    reaper.RecursiveCreateDirectory(DDP_DIR, 0)
    reaper.GetSetProjectInfo_String(projB, "RENDER_FILE", DDP_DIR, true)
    -- CD イメージの名前は標準の IMAGE.DAT に固定する（アルバム名だと REAPER が 17 バイトで切り詰め、
    -- 記号や日本語で拡張子まで欠ける。2026-09-24 つこさんの実案件で確認）
    reaper.GetSetProjectInfo_String(projB, "RENDER_PATTERN", "IMAGE", true)
    reaper.GetSetProjectInfo_String(projB, "RENDER_FORMAT", S.DDP_FORMAT, true)
    reaper.GetSetProjectInfo_String(projB, "RENDER_FORMAT2", "", true)
    reaper.GetSetProjectInfo(projB, "RENDER_SRATE", 44100, true)
    reaper.GetSetProjectInfo(projB, "RENDER_CHANNELS", 2, true)
    reaper.GetSetProjectInfo(projB, "RENDER_SETTINGS", 0, true)       -- マスターミックス
    reaper.GetSetProjectInfo(projB, "RENDER_BOUNDSFLAG", 2, true)     -- 時間選択 0〜最後の曲の終わり
    reaper.GetSetProjectInfo(projB, "RENDER_DITHER", (DDP_ROW.dither == "reaper") and cfg.REAPER_DITHER_BITS or 16, true)
    reaper.GetSetProjectInfo(projB, "RENDER_NORMALIZE", 0, true)
    reaper.GetSetProjectInfo(projB, "RENDER_TAILFLAG", 0, true)
    reaper.GetSetProjectInfo(projB, "RENDER_ADDTOPROJ", 0, true)
    reaper.GetSet_LoopTimeRange2(projB, true, false, 0.0, layout.total, false)
    local okT, targets = reaper.GetSetProjectInfo_String(projB, "RENDER_TARGETS", "", false)
    local first = okT and tostring(targets or ""):match("^([^;]+)") or ""
    if not first:lower():match("%.dat$") then
      abort("DDP の書き出し形式になりませんでした（書き出し先: " .. tostring(first) .. "）。中断します。")
    end
    if reaper.EnumProjects(-1) ~= projB then abort("DDP 用のタブが手前にありません。中断します。") end
    -- [試験用の注入点 mastering]
    local t0 = clock()
    reaper.Main_OnCommand(42230, 0)
    j:log("パス完了（%.2f 秒）: DDP → %s", clock() - t0, DDP_DIR)
    j:log("出力 %d/%d: DDP / ディザー=%s → %s（%d 曲）", DDP_IDX, #rows, S.OUTPUT_DITHER_LABELS[DDP_ROW.dither] or DDP_ROW.dither,
      DDP_DIR, #mains)

    local okd, notes = L.verify_ddp_dir(DDP_DIR, #mains, has_cdtext)
    for _, n in ipairs(notes) do j:log("  DDP 確認: %s", n) end
    -- CD イメージの長さ（1/75 秒のフレーム数）が並びの計算と同じか
    local want_frames = math.floor(layout.total * 75 + 0.5)
    local img, files = nil, {}
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(DDP_DIR, i)
      if not fn then break end
      files[#files + 1] = DDP_DIR .. "/" .. fn
      -- CD イメージは名前でなく「2352 バイトの倍数の大きさ」で見つける（名前は切り詰められることがある）
      do
        local f0 = io.open(DDP_DIR .. "/" .. fn, "rb")
        if f0 then
          local sz0 = f0:seek("end"); f0:close()
          if sz0 and sz0 > 0 and sz0 % 2352 == 0 then img = DDP_DIR .. "/" .. fn end
        end
      end
      i = i + 1
    end
    local img_frames
    if img then
      local f = io.open(img, "rb")
      if f then local sz = f:seek("end"); f:close(); if sz % 2352 == 0 then img_frames = sz // 2352 end end
    end
    if not okd then abort("DDP の確認で問題がありました。中断します。\n" .. table.concat(notes, "\n")) end
    if img_frames ~= want_frames then
      abort(("DDP の CD イメージの長さが合いません（%s フレーム / 期待 %d）。中断します。"):format(tostring(img_frames), want_frames))
    end
    j:log("  CD イメージ %d フレーム（期待 %d）", img_frames, want_frames)

    local closed = j:mst_close_tab()
    if not closed then abort("DDP 用のタブを閉じられませんでした。") end
    do   -- DDP のタブを閉じたあとの元のプロジェクトのレート（v2.6.3 の調べ。値を変えないこと）
      local ra = C.mst_rates()
      j:log("DDP のタブを閉じたあと: プロジェクト %d Hz（固定 %s）/ RENDER_SRATE %d / オーディオ機器 %d Hz",
        ra.proj, ra.use and "あり" or "なし", to_int(reaper.GetSetProjectInfo(0, "RENDER_SRATE", 0, false)), ra.dev)
    end
    if reaper.CountTracks(0) ~= nA_tracks or reaper.CountProjectMarkers(0) ~= nA_markers then
      abort(("元のプロジェクトのトラック数かマーカー数が変わりました（トラック %d→%d / マーカー %d→%d）。")
        :format(nA_tracks, reaper.CountTracks(0), nA_markers, reaper.CountProjectMarkers(0)))
    end
    table.sort(files)
    for _, p in ipairs(files) do j:add_produced(p) end
    j.mst_ddp_count = #mains
  end

  -- 7. 64bit の中間を片付ける（成功したときだけ。DDP のタブを閉じたあと）
  j.mst_ok = true
  for _, p in ipairs(j.mst_tmp) do pcall(os.remove, p) end
  for _, pk in ipairs(j.passm_peaks or {}) do pcall(os.remove, pk) end
  if j.mst_tmpdir then
    j.passm_dirs = { j.mst_tmpdir .. "/peaks", j.mst_tmpdir }
  end
  j.mst_units = #units
  j:log("64bit の中間ファイルを消した")
end

C.PREPARE = { hwprint = Job.hw_prepare, mastering = Job.mst_prepare }
C.CLEANUP = { hwprint = Job.hw_cleanup, mastering = Job.mst_cleanup }

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
  -- Pass M のピーク（.reapeaks）が後片付けのあとで書かれることがあるので、最後にもう一度消す
  for _, pk in ipairs(j.passm_peaks or {}) do pcall(os.remove, pk) end
  -- Mastering: 中身が空になった作業フォルダを消す（空でなければ消えない）
  for _, d in ipairs(j.passm_dirs or {}) do pcall(os.remove, d) end

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
  -- Mastering: 途中で止まったときは 64bit の中間ファイルを残し、その場所を知らせる（計画書 3-5）
  if not pok and j.mst_kept_dir then
    local add = "\n\n64bit の中間ファイルは次の場所に残してあります（次に書き出すときに自動で消します）:\n" .. tostring(j.mst_kept_dir)
    if res.aborted then res.aborted = res.aborted .. add else res.err = tostring(res.err) .. add end
  end
  return res
end

return C
