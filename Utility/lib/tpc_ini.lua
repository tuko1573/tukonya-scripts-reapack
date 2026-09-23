--[[
  tpc_ini.lua
  Team Plugin Checker — REAPERのキャッシュiniファイルを読む（読み取り専用）。
  対象は reaper-vstplugins_*.ini（[vstcache]節）と reaper-clap-*.ini。
  補助キー（VST3のクラスID）を拾うためだけに使う。EnumInstalledFXの代わりではない。
--]]

local M = {}

-- ============================================================
-- reaper-vstplugins_*.ini  [vstcache]
-- 行の文法: key=timestampHex,decimalId[{32hexClassId],DisplayName[!!!VSTi]
-- シェルの親（子を束ねる殻）は timestampHex だけの行なので読み飛ばす。
-- シェルの子は "ファイル名<decimalId" というキーになる。
-- [xvst3_compat] 節に入ったら読むのをやめる。
-- ============================================================

function M.parse_vstplugins(text)
  local map = {}
  local in_section = false
  for line in text:gmatch("[^\r\n]+") do
    local section = line:match("^%[(.-)%]%s*$")
    if section then
      if section == "vstcache" then
        in_section = true
      elseif section == "xvst3_compat" then
        break
      else
        in_section = false
      end
    elseif in_section then
      local key, rest = line:match("^([^=]+)=[0-9A-Fa-f]+(.*)$")
      if key and rest and rest ~= "" then
        local decimal_str, tail = rest:match("^,(%-?%d+)(.*)$")
        if decimal_str then
          local class_id, display
          if tail:sub(1, 1) == "{" then
            class_id = tail:sub(2, 33):lower()
            display = tail:sub(35) -- tail:sub(34) は "," のはず
          else
            display = tail:sub(2) -- 先頭の "," を飛ばす
          end
          local vsti = false
          if display:sub(-7) == "!!!VSTi" then
            vsti = true
            display = display:sub(1, -8)
          end
          map[key] = {
            class_id = class_id,
            decimal_id = tonumber(decimal_str),
            display = display,
            vsti = vsti,
          }
        end
        -- decimal_str が取れない行（想定外の書式）は静かに無視する。
      end
      -- rest == "" はシェル親（殻）。中身のない行なので読み飛ばす。
    end
  end
  return map
end

--- REAPERがVSTのフルパスをiniキーへ丸める規則（basename、空白とハイフンを "_" へ）。
-- ident（フルパス、または "パス<番号" のシェル子）から iniキーを作る。
function M.filename_key(path)
  if not path or path == "" then return "" end
  local base = path:match("([^/\\]+)$") or path
  base = base:gsub("[ %-]", "_")
  return base
end

-- ============================================================
-- reaper-clap-macos-aarch64.ini
-- [Name.clap] 節、"_=timestamps" 行（読み飛ばす）、
-- "reverse.dns.id=FLAG|Name (Vendor)" 行（FLAG 1 = 楽器）。
-- ============================================================

function M.parse_clap(text)
  local map = {}
  local section = nil
  for line in text:gmatch("[^\r\n]+") do
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then
      section = sec
    elseif line:match("^_=") then
      -- タイムスタンプ、読み飛ばす
    else
      local id, rest = line:match("^([^=]+)=(.*)$")
      if id and rest then
        local flag, display = rest:match("^(%d+)%|(.*)$")
        if flag then
          map[id] = {
            flag = tonumber(flag),
            instrument = (tonumber(flag) == 1),
            display = display,
            file = section,
          }
        end
      end
    end
  end
  return map
end

return M
