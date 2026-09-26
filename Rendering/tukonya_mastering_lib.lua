--[[
  tukonya_mastering_lib.lua  （TUKONYA RENDER / Mastering タブ・素のLua部分）
  ===========================================================================
  すべて reaper.* を呼ばない純粋な関数。REAPERを起動しなくても
  `lua tests/test_mastering_lib.lua` で確かめられる（fetch_url だけが
  OS の curl を呼ぶ。ここだけ分けてあるので、試験では差し替えられる）。

  含むもの:
    parse_sheet_csv   … 曲目リストCSVの読み取り（見出し文字で探す。行番号決め打ちしない）
    sheet_export_url  … スプレッドシートのURL → CSVエクスポート用URL
    fetch_url         … curl 経由での取得（OSを触る唯一の関数）
    validate_metadata … 半角英数・ISRC・EAN/JAN・「|」・アルバム側の抜け、を注意として返す
    marker_strings    … REAPERのDDPマーカー文字列（@アルバム／#曲）の組み立て
    cd_layout         … 曲の並び（INDEX0/INDEX1/長さ）を1/75秒グリッドに揃えて計算
    song_filename     … 曲名からファイル名を作る（先頭の番号を外す・禁止文字を置換）
    verify_ddp_dir    … 書き出されたDDPフォルダの確認（存在・トラック数・CDTEXTの有無）

  計画書: 計画書/計画書_mastering.md（3-2, 3-3b, 3-4, 3-5）
  ===========================================================================
--]]

local M = { VERSION = "0.1.0" }

-- ===========================================================================
-- 0. 小さな道具
-- ===========================================================================
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 見出しセルの飾り「(！)」「(!)」を外して比べやすくする
local function strip_deco(s)
  s = trim(s)
  s = s:gsub("%(!%)$", ""):gsub("%(！%)$", "")
  return trim(s)
end

-- ===========================================================================
-- 1. CSV の読み取り（引用符・埋め込み改行・埋め込みカンマ・CRLF に対応）
-- ===========================================================================
local function parse_csv_rows(text)
  text = (text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local rows = {}
  local row = {}
  local field = {}
  local i, n = 1, #text
  local in_quotes = false
  while i <= n do
    local c = text:sub(i, i)
    if in_quotes then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          field[#field + 1] = '"'
          i = i + 2
        else
          in_quotes = false
          i = i + 1
        end
      else
        field[#field + 1] = c
        i = i + 1
      end
    else
      if c == '"' then
        in_quotes = true
        i = i + 1
      elseif c == ',' then
        row[#row + 1] = table.concat(field)
        field = {}
        i = i + 1
      elseif c == '\n' then
        row[#row + 1] = table.concat(field)
        field = {}
        rows[#rows + 1] = row
        row = {}
        i = i + 1
      else
        field[#field + 1] = c
        i = i + 1
      end
    end
  end
  if #field > 0 or #row > 0 then
    row[#row + 1] = table.concat(field)
    rows[#rows + 1] = row
  end
  return rows
end
M._parse_csv_rows = parse_csv_rows -- 試験用に覗けるようにしておく

-- アルバム見出し行を探す（TITLE と EAN/JAN… を持ち、Track/ISRC は持たない行）
local function find_album_header(rows)
  for r, row in ipairs(rows) do
    local has_track, has_isrc = false, false
    for _, cell in ipairs(row) do
      local key = strip_deco(cell)
      if key == "Track" then has_track = true end
      if key == "ISRC" then has_isrc = true end
    end
    if not (has_track and has_isrc) then
      local map = {}
      for c, cell in ipairs(row) do
        local key = strip_deco(cell)
        if key == "TITLE" then map.title = c
        elseif key == "PERFORMER" then map.performer = c
        elseif key == "SONGWRITER" then map.songwriter = c
        elseif key == "COMPOSER" then map.composer = c
        elseif key == "ARRANGER" then map.arranger = c
        elseif key:find("EAN", 1, true) then map.ean = c
        end
      end
      if map.title and map.ean then
        return r, map
      end
    end
  end
  return nil
end

-- 曲見出し行を探す（Track と ISRC を両方持つ行）
local function find_track_header(rows, start_r)
  for r = (start_r or 1), #rows do
    local row = rows[r]
    local map = {}
    local has_track = false
    for c, cell in ipairs(row) do
      local key = strip_deco(cell)
      if key == "Track" then map.track = c; has_track = true
      elseif key == "TITLE" then map.title = c
      elseif key == "PERFORMER" then map.performer = c
      elseif key == "SONGWRITER" then map.songwriter = c
      elseif key == "COMPOSER" then map.composer = c
      elseif key == "ARRANGER" then map.arranger = c
      elseif key == "ISRC" then map.isrc = c
      end
    end
    if has_track and map.isrc then
      return r, map
    end
  end
  return nil
end

local function getcell(row, idx)
  if not idx or not row then return "" end
  return trim(row[idx])
end

--- CSVテキスト → { album = {...}, tracks = {...} }, warnings
function M.parse_sheet_csv(text)
  local warnings = {}
  local rows = parse_csv_rows(text)

  local album_r, album_map = find_album_header(rows)
  if not album_r then
    return {
      album = { title = "", performer = "", songwriter = "", composer = "", arranger = "", ean = "" },
      tracks = {},
    }, { "アルバムの見出し行が見つかりません" }
  end

  local avrow = rows[album_r + 1] or {}
  local album = {
    title = getcell(avrow, album_map.title),
    performer = getcell(avrow, album_map.performer),
    songwriter = getcell(avrow, album_map.songwriter),
    composer = getcell(avrow, album_map.composer),
    arranger = getcell(avrow, album_map.arranger),
    ean = getcell(avrow, album_map.ean),
  }

  local track_r, track_map = find_track_header(rows, album_r + 1)
  local tracks = {}
  if not track_r then
    warnings[#warnings + 1] = "曲の見出し行が見つかりません"
  else
    local r = track_r + 1
    while r <= #rows do
      local row = rows[r]
      local tcell = getcell(row, track_map.track)
      if tcell == "" or not tcell:match("^%d+$") then break end
      local t = {
        no = tonumber(tcell),
        title = getcell(row, track_map.title),
        performer = getcell(row, track_map.performer),
        songwriter = getcell(row, track_map.songwriter),
        composer = getcell(row, track_map.composer),
        arranger = getcell(row, track_map.arranger),
        isrc = getcell(row, track_map.isrc),
      }
      local all_empty = t.title == "" and t.performer == "" and t.songwriter == ""
        and t.composer == "" and t.arranger == "" and t.isrc == ""
      if not all_empty then
        tracks[#tracks + 1] = t
      end
      r = r + 1
    end
  end

  return { album = album, tracks = tracks }, warnings
end

--- 応答本文が（CSVでなく）Googleのログイン画面らしいHTMLか
function M.is_login_page(body)
  if not body or body == "" then return false end
  local head = body:sub(1, 1000):lower()
  return head:find("<!doctype html", 1, true) ~= nil or head:find("<html", 1, true) ~= nil
end

-- ===========================================================================
-- 2. URL 変換
-- ===========================================================================
function M.sheet_export_url(url)
  if not url or url == "" then return nil, "URLが空です" end
  if not url:match("^https?://docs%.google%.com/") then
    return nil, "docs.google.com のスプレッドシートURLではありません"
  end
  local id = url:match("/spreadsheets/d/([%w%-_]+)")
  if not id then return nil, "スプレッドシートのIDが見つかりません" end
  local gid = url:match("[#%?&]gid=(%d+)")
  local out = "https://docs.google.com/spreadsheets/d/" .. id .. "/export?format=csv"
  if gid then out = out .. "&gid=" .. gid end
  return out
end

-- ===========================================================================
-- 3. 取得（OSを触る唯一の関数）
-- ===========================================================================
function M.fetch_url(url)
  if not url or url == "" then return nil, "URLが空です" end
  local esc = url:gsub("'", "'\\''")
  local h = io.popen("curl -sL --max-time 20 '" .. esc .. "'", "r")
  if not h then return nil, "curl を起動できません" end
  local body = h:read("a")
  h:close()
  if body == nil then return nil, "応答を読めません" end
  return body
end

-- ===========================================================================
-- 4. メタデータの検証（注意を返すだけ。止めない）
-- ===========================================================================
local function has_nonascii(s)
  return s ~= nil and s:find("[\128-\255]") ~= nil
end

function M.validate_metadata(info)
  info = info or {}
  local warnings = {}
  local album = info.album or {}

  local function check_field(label, value)
    if not value or value == "" then return end
    if has_nonascii(value) then
      warnings[#warnings + 1] = label .. " に半角英数以外の文字があります（CD-TEXTに入りません）: " .. value
    end
    if value:find("|", 1, true) then
      warnings[#warnings + 1] = label .. " に「|」が含まれています: " .. value
    end
  end

  check_field("アルバムの TITLE", album.title)
  check_field("アルバムの PERFORMER", album.performer)
  check_field("アルバムの SONGWRITER", album.songwriter)
  check_field("アルバムの COMPOSER", album.composer)
  check_field("アルバムの ARRANGER", album.arranger)
  check_field("アルバムの EAN/JAN", album.ean)
  if album.ean and album.ean ~= "" and not album.ean:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
    warnings[#warnings + 1] = "アルバムの EAN/JAN が13桁の数字ではありません: " .. album.ean
  end

  local keys = { "performer", "songwriter", "composer", "arranger" }
  local used = {}
  for _, t in ipairs(info.tracks or {}) do
    local no = tostring(t.no)
    check_field("曲 " .. no .. " の TITLE", t.title)
    check_field("曲 " .. no .. " の PERFORMER", t.performer)
    check_field("曲 " .. no .. " の SONGWRITER", t.songwriter)
    check_field("曲 " .. no .. " の COMPOSER", t.composer)
    check_field("曲 " .. no .. " の ARRANGER", t.arranger)
    check_field("曲 " .. no .. " の ISRC", t.isrc)
    if t.isrc and t.isrc ~= "" and not t.isrc:match("^%w%w%w%w%w%w%w%w%w%w%w%w$") then
      warnings[#warnings + 1] = "曲 " .. no .. " の ISRC が12文字の英数字ではありません: " .. t.isrc
    end
    for _, k in ipairs(keys) do
      if t[k] and t[k] ~= "" then used[k] = true end
    end
  end
  for _, k in ipairs(keys) do
    if used[k] and (not album[k] or album[k] == "") then
      warnings[#warnings + 1] = "曲側で " .. k:upper() .. " を使っていますが、アルバム側が空です"
    end
  end

  return warnings
end

-- ===========================================================================
-- 5. DDPマーカー文字列
-- ===========================================================================
local function join_kv(title, prefix, order, kv)
  local parts = {}
  for _, k in ipairs(order) do
    local v = kv[k]
    if v and v ~= "" then parts[#parts + 1] = k .. "=" .. v end
  end
  title = title or ""
  if title ~= "" then
    if #parts > 0 then
      return prefix .. title .. "|" .. table.concat(parts, "|")
    else
      return prefix .. title
    end
  else
    return prefix .. table.concat(parts, "|")
  end
end

function M.marker_strings(info, opts)
  info = info or {}
  local album = info.album or {}
  local album_marker = join_kv(album.title, "@",
    { "PERFORMER", "SONGWRITER", "COMPOSER", "ARRANGER", "EAN" },
    {
      PERFORMER = album.performer, SONGWRITER = album.songwriter,
      COMPOSER = album.composer, ARRANGER = album.arranger, EAN = album.ean,
    })

  local tracks = {}
  for i, t in ipairs(info.tracks or {}) do
    tracks[i] = join_kv(t.title, "#",
      { "ISRC", "PERFORMER", "SONGWRITER", "COMPOSER", "ARRANGER" },
      {
        ISRC = t.isrc, PERFORMER = t.performer, SONGWRITER = t.songwriter,
        COMPOSER = t.composer, ARRANGER = t.arranger,
      })
  end

  return { album = album_marker, tracks = tracks }
end

-- ===========================================================================
-- 6. CDの並び（1/75秒グリッド）
-- ===========================================================================
local FPS = 75

-- 秒 → 1/75秒グリッドに「切り上げ」で揃えた秒（E3で確認したREAPER自身の丸め方向と同じ）
function M.snap_frame(t)
  local f = math.ceil((t or 0) * FPS - 1e-9)
  if f < 0 then f = 0 end
  return f / FPS
end

local function to_frame(t)
  local f = math.ceil((t or 0) * FPS - 1e-9)
  if f < 0 then f = 0 end
  return f
end

--- durations_sec（曲の長さの配列）, opts={pregap_first=2.0, gap=2.0}
--- → { tracks = {{no,start,index0,length}, ...}, total }, warnings
function M.cd_layout(durations, opts)
  opts = opts or {}
  local pregap_frames = to_frame(opts.pregap_first or 2.0)
  local gap_frames = to_frame(opts.gap or 2.0)

  local tracks, warnings = {}, {}
  local start_frame = pregap_frames
  local index0_frame = 0
  local last_end_frame = 0

  for i, dur in ipairs(durations) do
    local length_frames = to_frame(dur)
    local end_frame = start_frame + length_frames
    tracks[i] = {
      no = i,
      start = start_frame / FPS,
      index0 = index0_frame / FPS,
      length = dur,
    }
    if dur < 4.0 then
      warnings[#warnings + 1] = ("曲 %d の長さが4秒未満です（%.2f秒）"):format(i, dur)
    end
    last_end_frame = end_frame
    index0_frame = end_frame
    start_frame = end_frame + gap_frames
  end

  return { tracks = tracks, total = last_end_frame / FPS }, warnings
end

-- ===========================================================================
-- 7. ファイル名
-- ===========================================================================
function M.song_filename(name, opts)
  opts = opts or {}
  local strip = opts.strip_number
  if strip == nil then strip = true end
  local s = tostring(name or "")
  if strip then
    s = s:gsub("^%s*(%d+)[%.%_%s]+", "")
  end
  s = trim(s)
  s = s:gsub('[/\\:*?"<>|]', "_")
  return s
end

-- ===========================================================================
-- 8. DDPフォルダの確認
-- ===========================================================================
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

--- dir 内のファイルを列挙（io.popen("ls") のみを使う。ディレクトリだけの
--- 素朴な一覧なので、隠しファイルや特殊文字を含む名前は考慮しない）
local function list_dir(dir)
  local names = {}
  local p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  if not p then return names end
  for line in p:lines() do
    if line ~= "" then names[#names + 1] = line end
  end
  p:close()
  return names
end

--- dir, expected_tracks(数値かnil), expect_cdtext(true/false/nil) → ok, notes(一覧)
function M.verify_ddp_dir(dir, expected_tracks, expect_cdtext)
  local notes = {}
  local ok = true

  for _, name in ipairs({ "DDPID", "DDPMS", "PQDESCR" }) do
    if file_exists(dir .. "/" .. name) then
      notes[#notes + 1] = name .. " あり"
    else
      notes[#notes + 1] = name .. " がありません"
      ok = false
    end
  end

  local image_name, image_size = nil, nil
  for _, name in ipairs(list_dir(dir)) do
    local size = file_size(dir .. "/" .. name)
    if size and size > 0 and size % 2352 == 0 then
      image_name, image_size = name, size
    end
  end
  if image_name then
    notes[#notes + 1] = ("CDイメージ %s（%d バイト、%d フレーム）"):format(image_name, image_size, image_size // 2352)
  else
    notes[#notes + 1] = "CDイメージ（2352の倍数のサイズのファイル）が見つかりません"
    ok = false
  end

  local track_count = nil
  local pf = io.open(dir .. "/PQDESCR", "rb")
  if pf then
    local data = pf:read("a")
    pf:close()
    local seen = {}
    for i = 1, #data, 64 do
      local rec = data:sub(i, i + 63)
      local code = rec:sub(5, 8)
      if code:match("^%x%x01$") and code:sub(1, 2):upper() ~= "AA" then
        seen[code:sub(1, 2)] = true
      end
    end
    track_count = 0
    for _ in pairs(seen) do track_count = track_count + 1 end
    notes[#notes + 1] = ("PQDESCR のトラック数: %d"):format(track_count)
    if expected_tracks and track_count ~= expected_tracks then
      ok = false
      notes[#notes + 1] = ("期待したトラック数と違います（期待 %d、実際 %d）"):format(expected_tracks, track_count)
    end
  else
    ok = false
    notes[#notes + 1] = "PQDESCR を読めません"
  end

  if expect_cdtext ~= nil then
    local has_cdtext = file_exists(dir .. "/CDTEXT.BIN")
    if expect_cdtext and not has_cdtext then
      ok = false
      notes[#notes + 1] = "CDTEXT.BIN が無い（メタデータありのはずでした）"
    elseif (not expect_cdtext) and has_cdtext then
      ok = false
      notes[#notes + 1] = "CDTEXT.BIN がある（メタデータ無しのはずでした）"
    else
      notes[#notes + 1] = "CDTEXT.BIN の有無は想定どおり"
    end
  end

  return ok, notes
end

return M
