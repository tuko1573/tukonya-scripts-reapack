--[[
  tukonya_vstpreset_lib.lua
  ===========================================================================
  REAPERが持っているVST3の設定データ（vst_chunk, base64）から、
  Steinberg標準の .vstpreset ファイルの中身を組み立てるための部品集。

  reaper.* を一切呼ばないので、REAPERの外（素のLua）でもそのまま動く。
  テストは tests/test_vstpreset.lua。

  形式（2026-09-08 実機の手動Exportとバイト一致で確認済み）:
    vst_chunk（base64を戻したもの）:
      u32 compLen | u32 flag | Comp[compLen] | u32 contLen | u32 flag | Cont[contLen]
    .vstpreset:
      "VST3" | i32 version=1 | classID 32文字ASCII hex | i64 listOffset   … 48バイト
      Comp本体 | (contLen>0のときだけ) Cont本体
      "List" | i32 count | { "Comp"/"Cont" | i64 offset | i64 size } × count
  ===========================================================================
--]]

local M = {}

-- ===== base64デコード（純Lua） =====
local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64LOOKUP = {}
for i = 1, 64 do
  B64LOOKUP[B64CHARS:sub(i, i)] = i - 1
end

--- base64文字列をバイト列へ戻す。
-- 改行・空白など、base64に無い文字は無視する（REAPERの chunk は折り返しが入る）。
function M.b64decode(s)
  if type(s) ~= "string" then return nil, "b64decode: string ではありません" end
  local clean = s:gsub("[^A-Za-z0-9+/=]", "")
  clean = clean:gsub("=+$", "")
  local out = {}
  local acc, bits = 0, 0
  for i = 1, #clean do
    local c = clean:sub(i, i)
    local v = B64LOOKUP[c]
    if not v then return nil, ("b64decode: 不正な文字 %q"):format(c) end
    acc = acc * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = math.floor(acc / (2 ^ bits))
      acc = acc - byte * (2 ^ bits)
      out[#out + 1] = string.char(byte)
    end
  end
  return table.concat(out)
end

-- ===== REAPERのVST3 vst_chunk を Comp / Cont に割る =====
--- @param raw string base64を戻した生バイト列
--- @return string|nil comp, string|nil cont_or_error, number|nil 余りバイト数
function M.parse_reaper_vst3_chunk(raw)
  if type(raw) ~= "string" then return nil, "parse: string ではありません" end
  if #raw < 16 then return nil, "parse: 短すぎます（16バイト未満）" end

  local compLen, _, pos = string.unpack("<I4<I4", raw, 1)
  if compLen < 0 or 8 + compLen + 8 > #raw then
    return nil, ("parse: compLen=%d がデータ長 %d に合いません"):format(compLen, #raw)
  end
  local comp = raw:sub(pos, pos + compLen - 1)
  pos = pos + compLen

  local contLen, _, pos2 = string.unpack("<I4<I4", raw, pos)
  if pos2 - 1 + contLen > #raw then
    return nil, ("parse: contLen=%d がデータ長 %d に合いません"):format(contLen, #raw)
  end
  local cont = raw:sub(pos2, pos2 + contLen - 1)
  local leftover = #raw - (pos2 - 1 + contLen)

  return comp, cont, leftover
end

-- ===== .vstpreset を組み立てる =====
--- @param class_id_32hex string 32文字のASCII hex（fx_ident の { の後ろ）
--- @param comp string
--- @param cont string
--- @return string|nil バイナリ文字列, string|nil エラー
function M.build_vstpreset(class_id_32hex, comp, cont)
  if type(class_id_32hex) ~= "string" or #class_id_32hex ~= 32 then
    return nil, "build: クラスIDが32文字ではありません"
  end
  comp = comp or ""
  cont = cont or ""

  local HEADER_LEN = 48                                    -- "VST3"(4) + i32(4) + classID(32) + i64(8)
  local list_offset = HEADER_LEN + #comp + #cont

  local parts = {}
  parts[#parts + 1] = "VST3"
  parts[#parts + 1] = string.pack("<i4", 1)                -- version
  parts[#parts + 1] = class_id_32hex
  parts[#parts + 1] = string.pack("<i8", list_offset)
  parts[#parts + 1] = comp
  if #cont > 0 then parts[#parts + 1] = cont end

  local entries = {}
  entries[#entries + 1] = { "Comp", HEADER_LEN, #comp }
  if #cont > 0 then
    entries[#entries + 1] = { "Cont", HEADER_LEN + #comp, #cont }
  end

  parts[#parts + 1] = "List"
  parts[#parts + 1] = string.pack("<i4", #entries)
  for _, e in ipairs(entries) do
    parts[#parts + 1] = e[1]
    parts[#parts + 1] = string.pack("<i8", e[2])
    parts[#parts + 1] = string.pack("<i8", e[3])
  end

  return table.concat(parts)
end

-- ===== fx_ident からクラスIDを取り出す =====
--- 例: ".../FabFilter Pro-Q 4.vst3<934538646{ED57BD725C60467EA64DD2F400758B6F"
--- @return string|nil 32文字のhex
function M.class_id_from_ident(fx_ident)
  if type(fx_ident) ~= "string" then return nil end
  local hex = fx_ident:match("{(%x+)")
  if hex and #hex >= 32 then return hex:sub(1, 32) end
  return nil
end

--- vst_chunk(base64) と fx_ident から .vstpreset を一気に作る便利関数。
--- @return string|nil データ, string|nil エラー文
function M.vstpreset_from_chunk_b64(fx_ident, chunk_b64)
  local cid = M.class_id_from_ident(fx_ident)
  if not cid then return nil, "fx_ident からクラスID（32桁hex）が取れません" end
  local raw, err = M.b64decode(chunk_b64)
  if not raw then return nil, err end
  local comp, cont = M.parse_reaper_vst3_chunk(raw)
  if not comp then return nil, cont end
  return M.build_vstpreset(cid, comp, cont)
end

return M
