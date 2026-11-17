--[[
  ref_startup.lua
  TUKONYA Reference — REAPER起動時に「REFERENCE」窓の常駐を自動で始める仕掛けを仕込む／外す。
  vom_startup.lua（VST3 Only Master）と同じ作り・同じ約束:
  `<REAPERリソース>/Scripts/__startup.lua` に、決まった2行の印（BEGIN / END）で挟んだ一塊を
  書くだけ。印の外側は1バイトも触らない。他のスクリプトが同じファイルを使っていても壊さない。
  REAPERは呼ばない（ファイルの読み書きと自分の場所は deps として注入する）。

  deps = { resource_path, script_dir, read_file(path), write_file(path, text), file_exists(path) }
--]]

local tx = require("ref_text")

local M = {}

M.BEGIN_MARK = "-- BEGIN TukonyaReference (managed; safe to delete)"
M.END_MARK = "-- END TukonyaReference"
M.TARGET = "TUKONYA_Reference Display.lua"
M.DELAY_SEC = 2.0   -- 起動直後を少し避ける

local function to_slash(p) return (tostring(p or ""):gsub("\\", "/")) end
M.to_slash = to_slash
local function trim_slash(p) return (to_slash(p):gsub("/+$", "")) end

--- script_dir が resource_path の Scripts/ の下のどこにあるか
-- @return subpath|nil, err
function M.install_subpath(resource_path, script_dir)
  local res = trim_slash(resource_path)
  local dir = trim_slash(script_dir)
  if res == "" or dir == "" then return nil, tx.ja("STARTUP_ERR_UNKNOWN_LOC") end
  local scripts = res .. "/Scripts"
  local lower_dir, lower_scripts = dir:lower(), scripts:lower()
  if lower_dir == lower_scripts then return "" end
  if lower_dir:sub(1, #lower_scripts + 1) == (lower_scripts .. "/") then
    return dir:sub(#scripts + 2)
  end
  return nil, tx.ja("STARTUP_ERR_OUTSIDE", dir)
end

function M.block(subpath)
  local rel = "/Scripts/"
  if subpath and subpath ~= "" then rel = rel .. to_slash(subpath) .. "/" end
  rel = rel .. M.TARGET
  -- dofile ではなく「アクションとして登録してから実行」する（トグル表示と結びつけるため）
  return table.concat({
    M.BEGIN_MARK,
    'do',
    '  local p = reaper.GetResourcePath() .. "' .. rel .. '"',
    '  if reaper.file_exists(p) then',
    '    local t0 = reaper.time_precise()',
    '    local function go()',
    '      if reaper.time_precise() - t0 < ' .. string.format("%.1f", M.DELAY_SEC) .. ' then',
    '        reaper.defer(go)',
    '      else',
    '        local id = reaper.AddRemoveReaScript(true, 0, p, true)',
    '        if id and id > 0 and reaper.GetToggleCommandStateEx(0, id) ~= 1 then reaper.Main_OnCommand(id, 0) end',
    '      end',
    '    end',
    '    reaper.defer(go)',
    '  end',
    'end',
    M.END_MARK,
  }, "\n")
end

local function find_block(content)
  local s = content:find(M.BEGIN_MARK, 1, true)
  if not s then return nil end
  local e = content:find(M.END_MARK, s, true)
  if not e then return nil end
  local after = e + #M.END_MARK
  local nl = content:sub(after):match("^\r?\n")
  if nl then after = after + #nl end
  return s, after
end

function M.apply_block(content, block)
  content = content or ""
  local s, after = find_block(content)
  if s then return content:sub(1, s - 1) .. block .. "\n" .. content:sub(after) end
  if content == "" then return block .. "\n" end
  if content:sub(-1) == "\n" then return content .. "\n" .. block .. "\n" end
  return content .. "\n\n" .. block .. "\n"
end

function M.remove_block(content)
  content = content or ""
  local s, after = find_block(content)
  if not s then return content, false end
  local head = content:sub(1, s - 1)
  head = head:gsub("(\r?\n)\r?\n$", "%1")
  return head .. content:sub(after), true
end

function M.startup_path(deps) return trim_slash(deps.resource_path) .. "/Scripts/__startup.lua" end

local function read_startup(deps)
  local path = M.startup_path(deps)
  if deps.file_exists and not deps.file_exists(path) then return "" end
  return deps.read_file(path) or ""
end

function M.is_installed(deps) return read_startup(deps):find(M.BEGIN_MARK, 1, true) ~= nil end

--- @return ok, subpath_or_err
function M.install(deps)
  local subpath, err = M.install_subpath(deps.resource_path, deps.script_dir)
  if subpath == nil then return false, err end
  local path = M.startup_path(deps)
  local new_content = M.apply_block(read_startup(deps), M.block(subpath))
  if not deps.write_file(path, new_content) then return false, tx.ja("STARTUP_ERR_WRITE", path) end
  return true, subpath
end

--- @return ok, err
function M.uninstall(deps)
  local path = M.startup_path(deps)
  if deps.file_exists and not deps.file_exists(path) then return true, nil end
  local content = deps.read_file(path)
  if content == nil then return true, nil end
  local new_content, removed = M.remove_block(content)
  if not removed then return true, nil end   -- 印が無ければ書き込まない
  if not deps.write_file(path, new_content) then return false, tx.ja("STARTUP_ERR_WRITE", path) end
  return true, nil
end

--- 実際のファイル入出力を束ねる（Install / Uninstall の2本が同じ物を使う）
function M.make_deps(r, script_dir)
  return {
    resource_path = r.GetResourcePath(),
    script_dir = script_dir,
    read_file = function(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("*a"); f:close(); return s end,
    write_file = function(p, t) local f = io.open(p, "wb"); if not f then return false end; f:write(t); f:close(); return true end,
    file_exists = r.file_exists,
  }
end

return M
