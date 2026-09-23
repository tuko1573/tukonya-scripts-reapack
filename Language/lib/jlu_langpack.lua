--[[
  jlu_langpack.lua
  JP LangPack Updater — 日本語の言語ファイル（ReaperLangPack）を自動で入れ替える／切り替える。

  やること（REAPER起動のたび __startup.lua から、または「今すぐ確認」から呼ばれる）:
    1. reaper.ini の langpack= を読む（ネットは使わない）
       - この配布元の日本語パッチを指している → "update"（1日1回だけ配布元を確認）
       - 別の日本語パッチを指している         → "switch"（今すぐ入れて切り替える）
       - 英語のまま／別言語                   → "none"（何もしない）
    2. 裏で走らせる小さな手順書（macOSは sh、Windowsは PowerShell）を書き出して実行する。
       REAPERの画面は止めない。結果は status.txt を reaper.defer で見張って拾う。
    3. 入れ替え／切り替えが起きたときだけ知らせる。

  REAPERは直接呼ばない（全部 deps 経由）。純粋な部分は素のLuaで試せる
  （tests/test_langpack.lua）。Lua 5.4互換。

  deps = {
    os_name       = reaper.GetOS() の文字列,
    resource_path = "<REAPERリソースフォルダ>",
    ini_path      = "<reaper.ini のパス>"（reaper.get_ini_file()）,
    read_file(path) -> string|nil,
    write_file(path, text) -> bool,
    file_exists(path) -> bool,
    mkdir_p(path),
    remove(path),
    exec(cmdline),                 -- reaper.ExecProcess(cmd, -1)
    time_precise() -> number,
    defer(fn),
    show_message(text, title),     -- reaper.ShowMessageBox(text, title, 0)
    log(msg),
    today() -> "YYYY-MM-DD",
    get_last_check() -> "YYYY-MM-DD"|nil,   -- ExtState [JPLangPackUpdater] last_check
    set_last_check(date),
  }

  opts = { force = bool（1日1回の制限を無視）, verbose = bool（結果を必ず知らせる） }
--]]

local M = {}

M.URL = "https://stash.reaper.fm/50552/Japanese_add_SWS_kb_edit.zip"
M.NAME = "Japanese_add_SWS_kb_edit.ReaperLangPack"
M.TITLE = "JP LangPack Updater: 日本語パッチ"
M.POLL_TIMEOUT_SEC = 150

-- ============================================================
-- 小道具
-- ============================================================

local function basename(p)
  p = tostring(p or ""):gsub("\\", "/")
  return p:match("([^/]+)$") or p
end
M.basename = basename

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- ini の langpack= の値（無ければ nil）。行頭の langpack= だけを見る。
function M.read_langpack_value(ini_text)
  ini_text = tostring(ini_text or "")
  local pos = 1
  while true do
    local s, e = ini_text:find("langpack=", pos, true)
    if not s then return nil end
    local prev = (s == 1) and "\n" or ini_text:sub(s - 1, s - 1)
    if prev == "\n" or prev == "\r" then
      return ini_text:sub(e + 1):match("^[^\r\n]*") or ""
    end
    pos = e + 1
  end
end

--- 日本語のパッチらしいか。ファイル名と #NAME 行の両方で判断する。
function M.is_japanese_pack(filename, head)
  local f = tostring(filename or ""):lower()
  local h = tostring(head or "")
  if h:find("日本語", 1, true) or h:find("日本", 1, true) then return true end
  local hl = h:lower()
  if hl:find("japanese", 1, true) or hl:find("jp", 1, true) then return true end
  if f:find("日本", 1, true) then return true end
  if f:find("japan", 1, true) or f:find("jpn", 1, true) or f:find("jp", 1, true) then return true end
  return false
end

-- ============================================================
-- どの道を通るか（純粋関数）
-- ============================================================

--- @param ini_text          reaper.ini の中身
-- @param our_name           M.NAME
-- @param read_langpack_head function(basename) -> #NAME行|nil
-- @return "update" | "switch" | "none"
function M.detect_mode(ini_text, our_name, read_langpack_head)
  local value = M.read_langpack_value(ini_text)
  if value == nil then return "none" end
  value = trim(value)
  if value == "" then return "none" end

  local base = basename(value)
  if base:lower() == basename(our_name):lower() then return "update" end

  local head = nil
  if read_langpack_head then
    local ok, h = pcall(read_langpack_head, base)
    if ok then head = h end
  end
  if M.is_japanese_pack(base, head) then return "switch" end
  return "none"
end

--- langpack= の値を our_name に書き換えた ini を返す。
-- 改行の種類（CRLF/LF）と、それ以外の中身は1バイトも変えない。
-- 行が無ければ [REAPER] の直後に足す。
function M.set_langpack(ini_text, our_name)
  ini_text = tostring(ini_text or "")
  local nl = ini_text:find("\r\n", 1, true) and "\r\n" or "\n"
  local name = basename(our_name)

  local pos = 1
  while true do
    local s, e = ini_text:find("langpack=", pos, true)
    if not s then break end
    local prev = (s == 1) and "\n" or ini_text:sub(s - 1, s - 1)
    if prev == "\n" or prev == "\r" then
      local rest = ini_text:sub(e + 1)
      local old = rest:match("^[^\r\n]*") or ""
      return ini_text:sub(1, e) .. name .. rest:sub(#old + 1)
    end
    pos = e + 1
  end

  -- 行が無い: [REAPER] の見出しの直後に足す
  local hs, he = ini_text:find("%[REAPER%]")
  if hs then
    local after = ini_text:sub(he + 1)
    local eol = after:match("^\r?\n")
    if eol then
      return ini_text:sub(1, he) .. eol .. "langpack=" .. name .. eol .. after:sub(#eol + 1)
    end
    return ini_text:sub(1, he) .. nl .. "langpack=" .. name .. after
  end
  if ini_text ~= "" and ini_text:sub(-#nl) ~= nl then ini_text = ini_text .. nl end
  return ini_text .. "[REAPER]" .. nl .. "langpack=" .. name .. nl
end

-- ============================================================
-- 結果の読み取り（純粋関数）
-- ============================================================

--- status.txt の1行目を kind と code に割る。BOM と \r は落とす。
-- @return kind（"UPDATED"/"SAME"/"OFFLINE"/"FAIL"/nil）, code（残り。無ければ ""）
function M.parse_status(line)
  line = tostring(line or "")
  if line:sub(1, 3) == "\239\187\191" then line = line:sub(4) end
  line = line:match("^[^\r\n]*") or ""
  line = line:gsub("\r", "")
  line = trim(line)
  if line == "" then return nil, "" end
  local kind, rest = line:match("^(%u+)|(.*)$")
  if kind then return kind, rest end
  kind = line:match("^(%u+)$")
  if kind then return kind, "" end
  return nil, line
end

M.FAIL_REASONS = {
  NOHEADER = "配布元の応答が想定と違います（ページが変わった？）",
  DOWNLOAD = "ダウンロードに失敗しました",
  UNZIP = "zipを展開できません（配布元のファイルが変わった？）",
  NOFILE = "zipの中に言語ファイルがありません",
  BADFILE = "言語ファイルの中身が想定と違います",
  BACKUP = "今まで使っていた版のバックアップを作れません",
  INSTALL = "ファイルの差し替えに失敗しました",
  SCRIPT = "更新処理の途中でエラーが起きました",
  NOINI = "REAPERの設定ファイルを読めませんでした",
  NOWRITE = "REAPERの設定ファイルを書き換えられませんでした",
}

function M.fail_reason(code)
  code = tostring(code or "")
  local http = code:match("^HTTP%s+(%d+)$")
  if http then return ("配布元が応答 %s を返しました（リンク切れ？）"):format(http) end
  return M.FAIL_REASONS[code] or (code ~= "" and code or "原因不明")
end

--- 結果から「iniを書き換えるか」「何を知らせるか」「ログに何を書くか」を決める（純粋関数）。
-- @param mode        "update" | "switch"
-- @param kind, code  M.parse_status の結果
-- @param dest_exists 標準パッチのファイルが今あるか
-- @param verbose     手動実行（SAME/OFFLINE も知らせる）
-- @param quiet_fail  今日すでに1回試している（切り替えの失敗を毎回出さない）
-- @return { set_ini = bool, msg = string|nil, log = string }
function M.decide(mode, kind, code, dest_exists, verbose, quiet_fail)
  kind = kind or "FAIL"
  local r = { set_ini = false, msg = nil, log = ("mode=%s result=%s%s"):format(
    mode, kind, (code ~= nil and code ~= "") and ("|" .. code) or "") }

  if mode == "switch" then
    if dest_exists then
      r.set_ini = true
      r.msg = "この配布元の日本語パッチに切り替えました。\n\n"
        .. "次回のREAPER起動から反映されます。\n元のパッチファイルはそのまま残っています。"
      return r
    end
    -- 切り替えは1日1回の制限を受けない（毎回やり直す）。
    -- だから失敗の知らせも毎回は出さない: 圏外のときと、今日もう試しているときは黙る。
    if not verbose and (kind == "OFFLINE" or quiet_fail) then
      r.log = r.log .. " 知らせは出さない（圏外／今日は試行済み）"
      return r
    end
    r.msg = "日本語パッチに切り替えできませんでした。\n理由: " .. M.fail_reason(
      (kind == "OFFLINE") and "ネットにつながりませんでした" or code)
      .. "\n\n今までの表示のまま使えます。配布元:\n" .. M.URL
    return r
  end

  -- mode == "update"
  if kind == "UPDATED" then
    local old, new = code:match("^(.-)|(.*)$")
    if not old then old, new = "不明", code end
    if old == "NONE" or old == "" then old = "不明" end
    r.msg = ("日本語パッチを新版に差し替えました。\n%s → %s\n\n次回のREAPER起動から反映されます。\n（元の版は LangPack/.update に残してあります）")
      :format(old, new)
    return r
  end
  if kind == "FAIL" then
    r.msg = "日本語パッチの自動更新ができませんでした。\n理由: " .. M.fail_reason(code)
      .. "\n\n今回は今までの版のまま使えます。配布元:\n" .. M.URL
    return r
  end
  if verbose then
    if kind == "SAME" then
      r.msg = "日本語パッチはすでに最新です。"
    elseif kind == "OFFLINE" then
      r.msg = "配布元につながりませんでした。\n今までの版のまま使えます。"
    end
  end
  return r
end

-- ============================================================
-- 裏で走らせる手順書（純粋関数）
-- ============================================================

local function sq(v) -- sh の '' の中に入れる
  return (tostring(v):gsub("'", "'\\''"))
end

local SH_BODY = [[
STATUS="$WORK/status.txt"; STAMP="$WORK/last_modified.txt"
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
cd "$WORK" || exit 0
rm -rf dl.zip ex
curl -sIL --max-time 10 "$URL" > hdr.txt 2>/dev/null
code=$(grep -i '^HTTP/' hdr.txt | tail -1 | awk '{print $2}')
if [ -z "$code" ]; then echo "OFFLINE" > "$STATUS"; exit 0; fi
if [ "$code" != "200" ]; then echo "FAIL|HTTP $code" > "$STATUS"; exit 0; fi
lm=$(grep -i '^Last-Modified:' hdr.txt | tail -1 | tr -d '\r')
if [ -z "$lm" ]; then echo "FAIL|NOHEADER" > "$STATUS"; exit 0; fi
if [ -f "$DEST" ] && [ "$lm" = "$(cat "$STAMP" 2>/dev/null)" ]; then echo "SAME" > "$STATUS"; exit 0; fi
if ! curl -sL --max-time 90 -o dl.zip "$URL"; then echo "FAIL|DOWNLOAD" > "$STATUS"; exit 0; fi
if ! unzip -oq dl.zip -d ex; then echo "FAIL|UNZIP" > "$STATUS"; exit 0; fi
f=$(ls ex/*.ReaperLangPack 2>/dev/null | head -1)
if [ -z "$f" ]; then echo "FAIL|NOFILE" > "$STATUS"; exit 0; fi
if [ "$(head -c 5 "$f")" != "#NAME" ] || [ "$(wc -c < "$f")" -lt 1000000 ]; then echo "FAIL|BADFILE" > "$STATUS"; exit 0; fi
old="NONE"
if [ -f "$DEST" ]; then
  old=$(head -1 "$DEST" | tr -d '\r'); old="${old#\#NAME:}"
  if cmp -s "$f" "$DEST"; then echo "$lm" > "$STAMP"; echo "SAME" > "$STATUS"; rm -rf dl.zip ex hdr.txt; exit 0; fi
  cp -p "$DEST" "$WORK/backup_$(date +%Y%m%d_%H%M%S).ReaperLangPack" || { echo "FAIL|BACKUP" > "$STATUS"; exit 0; }
  ls -t "$WORK"/backup_*.ReaperLangPack 2>/dev/null | tail -n +4 | xargs rm -f
fi
cp "$f" "$DEST.tmp" && mv -f "$DEST.tmp" "$DEST" || { echo "FAIL|INSTALL" > "$STATUS"; exit 0; }
echo "$lm" > "$STAMP"
new=$(head -1 "$DEST" | tr -d '\r'); new="${new#\#NAME:}"
echo "UPDATED|$old|$new" > "$STATUS"
rm -rf dl.zip ex hdr.txt
]]

-- Windows: 日本語のユーザー名でも壊れないよう、パスは実行時に自分で割り出す
-- （PowerShell 5.1 は BOM無しの .ps1 をシステムのコードページで読むので、
--  ファイルの中身は ASCII だけにする）。
local PS_BODY = [[
$ErrorActionPreference = 'Stop'
$URL  = '@URL@'
$NAME = '@NAME@'
$WORK = $PSScriptRoot
$DEST = Join-Path (Split-Path -Parent $WORK) $NAME
$STATUS = Join-Path $WORK 'status.txt'
$STAMP  = Join-Path $WORK 'last_modified.txt'
$HDR    = Join-Path $WORK 'hdr.txt'
$ZIP    = Join-Path $WORK 'dl.zip'
$EX     = Join-Path $WORK 'ex'
$enc = New-Object Text.UTF8Encoding $false
function Put([string]$t) { [IO.File]::WriteAllText($STATUS, $t, $enc) }
function Head1([string]$p) { ((Get-Content -LiteralPath $p -TotalCount 1 -Encoding UTF8) -replace "`r", '') }
try {
  if (Test-Path -LiteralPath $ZIP) { Remove-Item -LiteralPath $ZIP -Force }
  if (Test-Path -LiteralPath $EX) { Remove-Item -LiteralPath $EX -Recurse -Force }
  & curl.exe -sIL --max-time 10 $URL > $HDR
  $hdr = @(Get-Content -LiteralPath $HDR)
  $codes = @($hdr | Where-Object { $_ -match '^HTTP/' })
  if ($codes.Count -eq 0) { Put 'OFFLINE'; exit 0 }
  $code = (($codes[-1] -replace "`r", '') -split '\s+')[1]
  if ($code -ne '200') { Put ('FAIL|HTTP ' + $code); exit 0 }
  $lms = @($hdr | Where-Object { $_ -match '^Last-Modified:' })
  if ($lms.Count -eq 0) { Put 'FAIL|NOHEADER'; exit 0 }
  $lm = (($lms[-1] -replace "`r", '')).Trim()
  $have = Test-Path -LiteralPath $DEST
  if ($have -and (Test-Path -LiteralPath $STAMP)) {
    if (([IO.File]::ReadAllText($STAMP)).Trim() -eq $lm) { Put 'SAME'; exit 0 }
  }
  & curl.exe -sL --max-time 90 -o $ZIP $URL
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ZIP)) { Put 'FAIL|DOWNLOAD'; exit 0 }
  New-Item -ItemType Directory -Path $EX -Force | Out-Null
  & tar.exe -xf $ZIP -C $EX
  if ($LASTEXITCODE -ne 0) { Put 'FAIL|UNZIP'; exit 0 }
  $found = @(Get-ChildItem -LiteralPath $EX -Filter '*.ReaperLangPack' -Recurse -File)
  if ($found.Count -eq 0) { Put 'FAIL|NOFILE'; exit 0 }
  $src = $found[0].FullName
  if ($found[0].Length -lt 1000000) { Put 'FAIL|BADFILE'; exit 0 }
  if ((Head1 $src) -notlike '#NAME*') { Put 'FAIL|BADFILE'; exit 0 }
  $old = 'NONE'
  if ($have) {
    $old = (Head1 $DEST) -replace '^#NAME:', ''
    if ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $DEST -Algorithm SHA256).Hash) {
      [IO.File]::WriteAllText($STAMP, $lm, $enc); Put 'SAME'; exit 0
    }
    $bk = Join-Path $WORK ('backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.ReaperLangPack')
    try { Copy-Item -LiteralPath $DEST -Destination $bk -Force } catch { Put 'FAIL|BACKUP'; exit 0 }
    Get-ChildItem -LiteralPath $WORK -Filter 'backup_*.ReaperLangPack' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force
  }
  try { Copy-Item -LiteralPath $src -Destination $DEST -Force } catch { Put 'FAIL|INSTALL'; exit 0 }
  [IO.File]::WriteAllText($STAMP, $lm, $enc)
  $new = (Head1 $DEST) -replace '^#NAME:', ''
  Put ('UPDATED|' + $old + '|' + $new)
  Remove-Item -LiteralPath $ZIP -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $EX -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HDR -Force -ErrorAction SilentlyContinue
} catch {
  try { Put 'FAIL|SCRIPT' } catch { }
}
]]

function M.is_windows(os_name)
  return tostring(os_name or ""):sub(1, 3):lower() == "win"
end

--- 裏で走らせる手順書の中身と、その起動コマンドを作る。
-- @return text, cmdline, path
function M.build_runner(os_name, url, dest, work, getenv)
  work = tostring(work):gsub("\\", "/"):gsub("/+$", "")
  if M.is_windows(os_name) then
    local path = work .. "/update.ps1"
    local text = (PS_BODY
      :gsub("@URL@", function() return (tostring(url):gsub("'", "''")) end)
      :gsub("@NAME@", function() return (basename(dest):gsub("'", "''")) end))
    text = text:gsub("\n", "\r\n")
    local ps = "powershell.exe"
    local sysroot = getenv and getenv("SystemRoot") or nil
    if sysroot and sysroot ~= "" then
      ps = tostring(sysroot):gsub("/", "\\"):gsub("\\+$", "")
        .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    end
    local win_path = path:gsub("/", "\\")
    local cmd = '"' .. ps .. '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
      .. win_path .. '"'
    return text, cmd, path
  end

  local path = work .. "/update.sh"
  local head = ("#!/bin/sh\nURL='%s'; DEST='%s'; WORK='%s'\n")
    :format(sq(url), sq(dest), sq(work))
  local text = head .. SH_BODY
  -- 空白を含むパスは double quote（REAPERがコマンド行を自分で分割するため）
  local cmd = '/bin/sh "' .. path .. '"'
  return text, cmd, path
end

-- ============================================================
-- 本体
-- ============================================================

function M.run(deps, opts)
  opts = opts or {}
  local log = deps.log or function() end

  local lang_dir = tostring(deps.resource_path):gsub("\\", "/"):gsub("/+$", "") .. "/LangPack"
  local work = lang_dir .. "/.update"
  local dest = lang_dir .. "/" .. M.NAME
  local status_file = work .. "/status.txt"

  local ini_text = deps.read_file(deps.ini_path)
  if not ini_text then
    log("LangPack: 設定ファイルを読めません: " .. tostring(deps.ini_path))
    if opts.verbose and deps.show_message then
      deps.show_message("REAPERの設定ファイルを読めませんでした。\n" .. tostring(deps.ini_path), M.TITLE)
    end
    return
  end

  local mode = M.detect_mode(ini_text, M.NAME, function(base)
    local text = deps.read_file(lang_dir .. "/" .. base)
    if not text then return nil end
    return text:match("^[^\r\n]*")
  end)

  if mode == "none" then
    log("LangPack: mode=none（日本語パッチを使っていないので何もしない）")
    if opts.verbose and deps.show_message then
      deps.show_message("日本語パッチを使っていないので、何もしませんでした。", M.TITLE)
    end
    return
  end

  -- 確認は1日1回。ただし「切り替え」は今すぐ直す必要があるので制限を受けない。
  local last = deps.get_last_check and deps.get_last_check() or nil
  local checked_today = (last ~= nil) and ((last:match("^[^\r\n]*") or "") == deps.today())
  if mode == "update" and not opts.force and checked_today then
    log("LangPack: mode=update 今日はすでに確認済み")
    return
  end

  deps.mkdir_p(work)
  if deps.set_last_check then deps.set_last_check(deps.today()) end
  if deps.remove then deps.remove(status_file) end

  local text, cmd, path = M.build_runner(deps.os_name, M.URL, dest, work, deps.getenv)
  if not deps.write_file(path, text) then
    log("LangPack: 手順書を書けません: " .. path)
    return
  end
  log(("LangPack: mode=%s 確認を開始"):format(mode))
  deps.exec(cmd)

  local t0 = deps.time_precise()
  local function poll()
    local raw = deps.read_file(status_file)
    if raw and trim(raw) ~= "" then
      local kind, code = M.parse_status(raw)
      local d = M.decide(mode, kind, code, deps.file_exists(dest) and true or false, opts.verbose, checked_today)
      if d.set_ini then
        -- iniはREAPERが動いている間に書き換わり得るので、書く直前に読み直す
        local fresh = deps.read_file(deps.ini_path)
        if fresh then
          if not deps.write_file(deps.ini_path, M.set_langpack(fresh, M.NAME)) then
            d.msg = "日本語パッチに切り替えできませんでした。\n理由: " .. M.FAIL_REASONS.NOWRITE
            d.log = d.log .. " ini書き込み失敗"
          else
            d.log = d.log .. " ini書き換え済み"
          end
        else
          d.msg = "日本語パッチに切り替えできませんでした。\n理由: " .. M.FAIL_REASONS.NOINI
          d.log = d.log .. " ini再読み込み失敗"
        end
      end
      log("LangPack: " .. d.log)
      if d.msg and deps.show_message then deps.show_message(d.msg, M.TITLE) end
      return
    end
    if deps.time_precise() - t0 < M.POLL_TIMEOUT_SEC then
      deps.defer(poll)
    else
      log("LangPack: 確認が終わりませんでした（結果ファイル無し）: " .. status_file)
      if opts.verbose and deps.show_message then
        deps.show_message("確認が時間内に終わりませんでした。\n" .. status_file, M.TITLE)
      end
    end
  end
  deps.defer(poll)
end

M.EXTSTATE_SECTION = "JPLangPackUpdater"
M.EXTSTATE_KEY_LAST_CHECK = "last_check"

--- 実機のREAPERから deps を組み立てる。
function M.reaper_deps(read_file, write_file, log)
  return {
    os_name = reaper.GetOS(),
    resource_path = reaper.GetResourcePath(),
    ini_path = reaper.get_ini_file(),
    getenv = os.getenv,
    read_file = read_file,
    write_file = write_file,
    file_exists = reaper.file_exists,
    mkdir_p = function(p) reaper.RecursiveCreateDirectory(p, 0) end,
    remove = os.remove,
    exec = function(cmd) reaper.ExecProcess(cmd, -1) end,
    time_precise = reaper.time_precise,
    defer = reaper.defer,
    show_message = function(text, title) reaper.ShowMessageBox(text, title, 0) end,
    log = log,
    today = function() return os.date("%Y-%m-%d") end,
    get_last_check = function()
      local v = reaper.GetExtState(M.EXTSTATE_SECTION, M.EXTSTATE_KEY_LAST_CHECK)
      if v == nil or v == "" then return nil end
      return v
    end,
    set_last_check = function(date)
      reaper.SetExtState(M.EXTSTATE_SECTION, M.EXTSTATE_KEY_LAST_CHECK, tostring(date), true)
    end,
  }
end

return M
