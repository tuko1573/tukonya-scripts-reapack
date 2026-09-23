--[[
  jlu_util.lua
  JP LangPack Updater — ファイルの読み書きとログ（<REAPERリソース>/JPLangPackUpdater.log、末尾200行だけ残す）。
--]]

local M = {}

M.LOG_MAX_LINES = 200

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write_file(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

function M.log_path()
  return reaper.GetResourcePath() .. "/JPLangPackUpdater.log"
end

--- ログに1行足す。末尾 LOG_MAX_LINES 行だけ残す（無限に太らせない）。
function M.log(msg)
  local path = M.log_path()
  local line = os.date("!%Y-%m-%dT%H:%M:%SZ") .. " " .. tostring(msg)
  local lines = {}
  local f = io.open(path, "rb")
  if f then
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
  end
  lines[#lines + 1] = line
  local start = math.max(1, #lines - M.LOG_MAX_LINES + 1)
  local out = io.open(path, "wb")
  if out then
    for i = start, #lines do out:write(lines[i], "\n") end
    out:close()
  end
end

return M
