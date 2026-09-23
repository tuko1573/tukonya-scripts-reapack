--[[
  vom_startup.lua
  VST3 Only Master — REAPER起動時に見張りを自動で始める仕掛けを仕込む／外す。
  （Team Plugin Checker の tpc_startup.lua と同じ作り）

  仕掛けは `<REAPERリソース>/Scripts/__startup.lua` に、決まった2行の印
  （BEGIN / END）で挟んだ一塊を書くだけ。印の外側は1バイトも触らない。
  他のスクリプトが同じファイルを使っていても壊さないための約束。

  REAPERは呼ばない（ファイルの読み書きと自分の場所は deps として注入する）。
  素のLuaでテストできる（tests/test_startup.lua）。

  deps = {
    resource_path = "<REAPERリソースフォルダ>",
    script_dir    = "<このスクリプト群が置かれているフォルダ>",
    read_file(path) -> string|nil,
    write_file(path, text) -> bool,
    file_exists(path) -> bool,
  }
--]]

local M = {}

M.BEGIN_MARK = "-- BEGIN VST3OnlyMaster (managed; safe to delete)"
M.END_MARK = "-- END VST3OnlyMaster"

-- 起動直後は EnumInstalledFX の一覧がまだ揃っていない可能性がある（計画書1章の「不明」）。
-- 何フレームで揃うかは分からないので、時間で待つ。
M.DELAY_SEC = 3.0

-- ============================================================
-- 自分の設置場所（Scripts/ からの相対）
-- ============================================================

local function to_slash(p)
  return (tostring(p or ""):gsub("\\", "/"))
end
M.to_slash = to_slash

local function trim_slash(p)
  return (to_slash(p):gsub("/+$", ""))
end

--- script_dir が resource_path の Scripts/ の下のどこにあるかを返す。
-- 開発中の手置き   → "VST3OnlyMaster"
-- ReaPack経由      → "Tukonya Scripts/Utility"
-- @return subpath|nil, err
function M.install_subpath(resource_path, script_dir)
  local res = trim_slash(resource_path)
  local dir = trim_slash(script_dir)
  if res == "" or dir == "" then return nil, "場所が分かりません" end

  local scripts = res .. "/Scripts"
  -- Windowsはドライブレターの大小が揺れるので、比較だけ小文字で行い、
  -- 切り出しは元の文字列から行う。
  local lower_dir, lower_scripts = dir:lower(), scripts:lower()
  if lower_dir == lower_scripts then return "" end
  if lower_dir:sub(1, #lower_scripts + 1) == (lower_scripts .. "/") then
    return dir:sub(#scripts + 2)
  end
  return nil, "REAPERのScriptsフォルダの外にあります: " .. dir
end

-- ============================================================
-- 書き込む一塊
-- ============================================================

--- @param subpath  M.install_subpath の結果（"" なら Scripts 直下）
function M.block(subpath)
  local rel = "/Scripts/"
  if subpath and subpath ~= "" then rel = rel .. to_slash(subpath) .. "/" end
  rel = rel .. "TUKONYA_VST3 Only Master.lua"

  -- dofile ではなく「アクションとして登録してから実行」する。
  -- そうしないとアクション一覧のトグル（点灯／消灯）と結びつかず、
  -- あとで手で走らせたときに止まらずに2つ目が動いてしまう。
  return table.concat({
    M.BEGIN_MARK,
    'do',
    '  local p = reaper.GetResourcePath() .. "' .. rel .. '"',
    '  if reaper.file_exists(p) then',
    '    -- 起動直後はプラグインの一覧がまだ揃っていないことがあるので少し待つ',
    '    local t0 = reaper.time_precise()',
    '    local function go()',
    '      if reaper.time_precise() - t0 < ' .. string.format("%.1f", M.DELAY_SEC) .. ' then',
    '        reaper.defer(go)',
    '      else',
    '        local id = reaper.AddRemoveReaScript(true, 0, p, true)',
    '        if id and id > 0 then reaper.Main_OnCommand(id, 0) end',
    '      end',
    '    end',
    '    reaper.defer(go)',
    '  end',
    'end',
    M.END_MARK,
  }, "\n")
end

-- ============================================================
-- 文字列の差し替え（純粋関数。テストはここを直接叩ける）
-- ============================================================

--- content の中の BEGIN〜END を探して {開始位置, 終端の次の位置} を返す。
-- END の直後の改行（\r\n でも \n でも）を1つだけ飲み込む。
local function find_block(content, begin_mark, end_mark)
  begin_mark = begin_mark or M.BEGIN_MARK
  end_mark = end_mark or M.END_MARK
  local s = content:find(begin_mark, 1, true)
  if not s then return nil end
  local e = content:find(end_mark, s, true)
  if not e then return nil end
  local after = e + #end_mark
  local nl = content:sub(after):match("^\r?\n")
  if nl then after = after + #nl end
  return s, after
end

--- 既にある一塊を差し替える。無ければ末尾に足す（前に空行を1つ置く）。
function M.apply_block(content, block)
  content = content or ""
  local s, after = find_block(content)
  if s then
    return content:sub(1, s - 1) .. block .. "\n" .. content:sub(after)
  end
  if content == "" then return block .. "\n" end
  if content:sub(-1) == "\n" then
    return content .. "\n" .. block .. "\n"
  end
  return content .. "\n\n" .. block .. "\n"
end

--- 一塊と、その直前に置いた空行1つだけを取り除く。印が無ければそのまま返す。
function M.remove_block(content)
  content = content or ""
  local s, after = find_block(content)
  if not s then return content, false end
  local head = content:sub(1, s - 1)
  head = head:gsub("(\r?\n)\r?\n$", "%1")
  return head .. content:sub(after), true
end

-- ============================================================
-- ファイルに対する操作
-- ============================================================

function M.startup_path(deps)
  return trim_slash(deps.resource_path) .. "/Scripts/__startup.lua"
end

local function read_startup(deps)
  local path = M.startup_path(deps)
  if deps.file_exists and not deps.file_exists(path) then return "" end
  return deps.read_file(path) or ""
end

--- @return true（印がある）/ false
function M.is_installed(deps)
  local content = read_startup(deps)
  return content:find(M.BEGIN_MARK, 1, true) ~= nil
end

--- @return ok, subpath_or_err
function M.install(deps)
  local subpath, err = M.install_subpath(deps.resource_path, deps.script_dir)
  if subpath == nil then return false, err end
  local path = M.startup_path(deps)
  local content = read_startup(deps)
  local new_content = M.apply_block(content, M.block(subpath))
  if not deps.write_file(path, new_content) then
    return false, "書き込めませんでした: " .. path
  end
  return true, subpath
end

--- @return ok, err
function M.uninstall(deps)
  local path = M.startup_path(deps)
  if deps.file_exists and not deps.file_exists(path) then return true, nil end
  local content = deps.read_file(path)
  if content == nil then return true, nil end
  local new_content, removed = M.remove_block(content)
  if not removed then return true, nil end
  if new_content == "" then
    -- 中身が空になったら、空のファイルを残す（消すとREAPER側の想定外になり得るので触らない）
    new_content = ""
  end
  if not deps.write_file(path, new_content) then
    return false, "書き込めませんでした: " .. path
  end
  return true, nil
end

return M
