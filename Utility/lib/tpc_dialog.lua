--[[
  tpc_dialog.lua
  Team Plugin Checker — OS のフォルダ選択ダイアログ（設定タブの「参照…」）。

  順番:
    1. js_ReaScriptAPI があれば reaper.JS_Dialog_BrowseForFolder
    2. macOS: osascript の choose folder
    3. Windows: PowerShell の FolderBrowserDialog（一時 .ps1 を UTF-8 BOM付きで書いて -File で実行）
    4. それ以外（Linux）: nil（パスは手で入れてもらう）

  ここは reaper を直接触らない。reaper 依存は deps で受け取る（M.default_deps が実機用）。
  どれもダイアログが閉じるまで REAPER を止めるので、ImGui の描画の外（次のフレームの頭）で呼ぶこと。

  REAPER の ExecProcess はコマンド行を自分で空白で割り、二重引用符だけを束ねとして扱う
  （jlu_langpack と同じ前提）。なので一重引用符は使わず、引数は全部 "…" で包み、
  AppleScript の本文の中にも二重引用符を置かない（プロンプトと開始フォルダは argv で渡す）。
--]]

local M = {}

M.TITLE = "共有フォルダを選ぶ"
M.PROMPT = "共有フォルダを選んでください"
M.PS1_NAME = "TeamPluginChecker_pick_folder.ps1"
M.OUT_NAME = "TeamPluginChecker_pick_folder.txt"

local function os_kind(os_name)
  local s = tostring(os_name or "")
  if s:match("^[Ww]in") then return "win" end
  if s:match("^OSX") or s:match("^macOS") then return "mac" end
  return "other"
end
M.os_kind = os_kind

--- ExecProcess の戻り（"<終了コード>\n<出力>"）を割る。
-- @return code(number|nil), output(string)
function M.parse_exec(ret)
  if type(ret) ~= "string" then return nil, "" end
  local code, out = ret:match("^(%-?%d+)\r?\n(.*)$")
  if not code then
    code = ret:match("^(%-?%d+)%s*$")
    return code and tonumber(code) or nil, ""
  end
  return tonumber(code), out
end

--- 出力から1つ目の空でない行を取り、末尾の改行と区切り文字を落とす（ドライブ直下 C:\ は残す）。
function M.clean_path(out)
  local line = nil
  for raw in tostring(out or ""):gmatch("[^\r\n]+") do
    local l = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if l ~= "" then line = l; break end
  end
  if not line then return nil end
  if line:sub(1, 3) == "\239\187\191" then line = line:sub(4) end -- BOM
  if not line:match("^%a:[/\\]$") and line ~= "/" then
    line = line:gsub("[/\\]+$", "")
  end
  if line == "" then return nil end
  return line
end

-- ============================================================
-- macOS
-- ============================================================

-- 各行は二重引用符で包んで -e に渡すので、行の中に二重引用符を入れない。
local MAC_LINES_WITH_START = {
  "on run argv",
  "activate",
  "set p to item 1 of argv",
  "try",
  "set d to (POSIX file (item 2 of argv)) as alias",
  "on error",
  "return POSIX path of (choose folder with prompt p)",
  "end try",
  "return POSIX path of (choose folder with prompt p default location d)",
  "end run",
}
local MAC_LINES = {
  "on run argv",
  "activate",
  "return POSIX path of (choose folder with prompt (item 1 of argv))",
  "end run",
}

--- @return cmdline
function M.mac_command(start_dir)
  local use_start = start_dir and start_dir ~= "" and not start_dir:find('"', 1, true)
  local lines = use_start and MAC_LINES_WITH_START or MAC_LINES
  local parts = { "/usr/bin/osascript" }
  for _, l in ipairs(lines) do parts[#parts + 1] = '-e "' .. l .. '"' end
  parts[#parts + 1] = '"' .. M.PROMPT .. '"'
  if use_start then parts[#parts + 1] = '"' .. start_dir .. '"' end
  return table.concat(parts, " ")
end

-- ============================================================
-- Windows
-- ============================================================

local function ps_quote(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- .ps1 の中身（UTF-8 BOM付き・CRLF）。選んだパスは UTF-8 で OUT_NAME に書き、標準出力にも出す。
function M.win_script(start_dir)
  local lines = {
    "$ErrorActionPreference = 'Stop'",
    "Add-Type -AssemblyName System.Windows.Forms",
    "$out = Join-Path $PSScriptRoot '" .. M.OUT_NAME .. "'",
    "if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }",
    "$d = New-Object System.Windows.Forms.FolderBrowserDialog",
    "$d.Description = " .. ps_quote(M.PROMPT),
    "$d.ShowNewFolderButton = $true",
  }
  if start_dir and start_dir ~= "" then
    lines[#lines + 1] = "$d.SelectedPath = " .. ps_quote(start_dir)
  end
  -- 手前に出す（REAPER の窓の裏に隠れないように）
  lines[#lines + 1] = "$owner = New-Object System.Windows.Forms.Form"
  lines[#lines + 1] = "$owner.TopMost = $true"
  lines[#lines + 1] = "if ($d.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {"
  lines[#lines + 1] = "  [IO.File]::WriteAllText($out, $d.SelectedPath, (New-Object Text.UTF8Encoding $false))"
  lines[#lines + 1] = "  [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false"
  lines[#lines + 1] = "  Write-Output $d.SelectedPath"
  lines[#lines + 1] = "  exit 0"
  lines[#lines + 1] = "}"
  lines[#lines + 1] = "exit 1"
  return "\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n"
end

--- @return cmdline, ps1_path(/区切り), out_path(/区切り)
function M.win_command(resource_path, getenv)
  local work = tostring(resource_path or ""):gsub("\\", "/"):gsub("/+$", "")
  local ps1 = work .. "/" .. M.PS1_NAME
  local out = work .. "/" .. M.OUT_NAME
  local ps = "powershell.exe"
  local sysroot = getenv and getenv("SystemRoot") or nil
  if sysroot and sysroot ~= "" then
    ps = tostring(sysroot):gsub("/", "\\"):gsub("\\+$", "")
      .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
  end
  local cmd = '"' .. ps .. '" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "'
    .. ps1:gsub("/", "\\") .. '"'
  return cmd, ps1, out
end

-- ============================================================
-- 本体
-- ============================================================

--- 実機用の deps（reaper のグローバルから組み立てる）。
function M.default_deps()
  return {
    os_name = reaper.GetOS and reaper.GetOS() or "",
    js_browse = reaper.JS_Dialog_BrowseForFolder,
    exec = reaper.ExecProcess and function(cmd, timeout) return reaper.ExecProcess(cmd, timeout) end or nil,
    resource_path = reaper.GetResourcePath and reaper.GetResourcePath() or nil,
    getenv = os.getenv,
    read_file = function(path)
      local f = io.open(path, "rb")
      if not f then return nil end
      local s = f:read("*a")
      f:close()
      return s
    end,
    write_file = function(path, text)
      local f = io.open(path, "wb")
      if not f then return false end
      f:write(text)
      f:close()
      return true
    end,
    remove = os.remove,
  }
end

--- フォルダを選ばせる。
-- @param deps  { os_name, js_browse?, exec?, resource_path?, getenv?, read_file?, write_file?, remove?, log? }
-- @param start_dir 開いたときの場所（空・nil なら既定）。実在するときだけ渡すこと。
-- @return path（選ばれた）／nil（キャンセル・使えない）, how（"js"|"mac"|"win"|理由）
function M.browse_folder(deps, start_dir)
  deps = deps or M.default_deps()
  local log = deps.log or function() end
  if start_dir == "" then start_dir = nil end

  if deps.js_browse then
    local rv, path = deps.js_browse(M.TITLE, start_dir or "")
    if rv == 1 and type(path) == "string" and path ~= "" then
      return M.clean_path(path), "js"
    end
    return nil, "js"
  end

  local kind = os_kind(deps.os_name)
  if not deps.exec or kind == "other" then
    return nil, "unsupported"
  end

  if kind == "mac" then
    local ret = deps.exec(M.mac_command(start_dir), 0) -- 0 = 閉じるまで待つ
    local code, out = M.parse_exec(ret)
    if code ~= 0 then
      log("フォルダ選択(mac): 閉じた／失敗 code=" .. tostring(code))
      return nil, "mac"
    end
    return M.clean_path(out), "mac"
  end

  -- Windows
  local cmd, ps1, out_path = M.win_command(deps.resource_path, deps.getenv)
  if not deps.write_file or not deps.write_file(ps1, M.win_script(start_dir)) then
    log("フォルダ選択(win): 一時ファイルを書けない " .. ps1)
    return nil, "win"
  end
  local ret = deps.exec(cmd, 0)
  local code, out = M.parse_exec(ret)
  local path = nil
  if code == 0 then
    -- 標準出力はコンソールの文字コードに化けることがあるので、UTF-8 で書いたファイルを優先する
    local text = deps.read_file and deps.read_file(out_path) or nil
    path = M.clean_path(text) or M.clean_path(out)
  else
    log("フォルダ選択(win): 閉じた／失敗 code=" .. tostring(code))
  end
  if deps.remove then
    pcall(deps.remove, ps1)
    pcall(deps.remove, out_path)
  end
  return path, "win"
end

return M
