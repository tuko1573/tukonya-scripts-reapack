--[[
  tpc_normalize.lua
  Team Plugin Checker — 同一視（正規化）の規則。
  REAPER無しで動く純Lua。EnumInstalledFX が返す nameOut / identOut を受け取り、
  「名前＋メーカー」で同じプラグインを畳み込むための key を作る。

  末尾の数字は消さない（Pro-C 2 ≠ Pro-C 3）。
--]]

local M = {}

M.VERSION = 2

-- ============================================================
-- 接頭辞（フォーマット）の切り出し
-- ============================================================

-- 長い接頭辞から先に試す（"VST3i:" は "VSTi:" の部分文字列ではないが、
-- 念のため明示的な順で書く）。
local PREFIXES = {
  { pat = "^VST3i:%s*", fmt = "VST3", instrument = true },
  { pat = "^VST3:%s*",  fmt = "VST3", instrument = false },
  { pat = "^VSTi:%s*",  fmt = "VST2", instrument = true },
  { pat = "^VST:%s*",   fmt = "VST2", instrument = false },
  { pat = "^AUi:%s*",   fmt = "AU",   instrument = true },
  { pat = "^AU:%s*",    fmt = "AU",   instrument = false },
  { pat = "^CLAPi:%s*", fmt = "CLAP", instrument = true },
  { pat = "^CLAP:%s*",  fmt = "CLAP", instrument = false },
  { pat = "^JSi:%s*",   fmt = "JS",   instrument = true },
  { pat = "^JS:%s*",    fmt = "JS",   instrument = false },
  { pat = "^LV2i:%s*",  fmt = "LV2",  instrument = true },
  { pat = "^LV2:%s*",   fmt = "LV2",  instrument = false },
}

-- 末尾のチャンネル表記 (2->6ch) (16ch) (64 out) (2 in) を捨てる。
-- "(194dB Audio)" のような実際のメーカー名や "(1-Pole Crossover)" のような
-- 名前の一部は、数字の直後に文字が続く／"in""out"以外の語が続くので対象外。
-- 複数回付くことはない想定だが、念のためループする。
local CHANNEL_TAG_PATTERNS = {
  "%s*%(%d+%->%d+ch%)%s*$",
  "%s*%(%d+ch%)%s*$",
  "%s*%(%d+ out%)%s*$",
  "%s*%(%d+ in%)%s*$",
}

local function strip_channel_tag(s)
  local changed = true
  while changed do
    changed = false
    for _, pat in ipairs(CHANNEL_TAG_PATTERNS) do
      local a = s:gsub(pat, "")
      if a ~= s then s = a; changed = true end
    end
  end
  return s
end

--- nameOut を分解する。
-- @return table|nil {fmt, instrument, name, vendor} / 接頭辞が無ければ nil
function M.parse(nameOut)
  if type(nameOut) ~= "string" then return nil end
  local fmt, instrument, rest
  for _, p in ipairs(PREFIXES) do
    local m = nameOut:match(p.pat)
    if m then
      fmt = p.fmt
      instrument = p.instrument
      rest = nameOut:sub(#m + 1)
      break
    end
  end
  if not fmt then return nil end

  rest = strip_channel_tag(rest)

  -- 末尾の「一番外側の丸括弧」をメーカーとする（"Name (x86_64) (Vendor)" 形）。
  local before, vendor = rest:match("^(.-)%s*%(([^()]*)%)%s*$")
  local name
  if vendor then
    name = before
  else
    -- AUの実際の並び順は未確認。"AU: Vendor: Name" 形も許容する。
    if fmt == "AU" then
      local v, n = rest:match("^([^:]+):%s*(.+)$")
      if v and n then
        vendor, name = v, n
      end
    end
    if not vendor then
      vendor = ""
      name = rest
    end
  end

  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  vendor = vendor:gsub("^%s+", ""):gsub("%s+$", "")

  return { fmt = fmt, instrument = instrument, name = name, vendor = vendor }
end

-- ============================================================
-- 全角→半角（ASCII範囲のみ）
-- ============================================================

local function fullwidth_to_halfwidth(s)
  -- U+3000（全角空白）は \xE3 始まり、U+FF01-FF5E（全角ASCII）は \xEF 始まり。
  -- どちらも含まなければ素通し（高速化）。
  if not s:find("\227") and not s:find("\239") then return s end
  local ok, buf = pcall(function()
    local out = {}
    for _, c in utf8.codes(s) do
      if c == 0x3000 then
        out[#out + 1] = " "
      elseif c >= 0xFF01 and c <= 0xFF5E then
        out[#out + 1] = utf8.char(c - 0xFEE0)
      else
        out[#out + 1] = utf8.char(c)
      end
    end
    return table.concat(out)
  end)
  if ok then return buf end
  return s -- 不正なUTF-8ならそのまま返す（壊さない）
end

-- ============================================================
-- 名前の正規化
-- ============================================================

-- 除去するタグ（丸括弧つき）。小文字化した後の文字列に対して適用する。
local PAREN_TAGS = {
  "%(x86_64%)", "%(x64%)", "%(arm64%)", "%(universal%)", "%(64%-bit%)",
  "%(m%)", "%(s%)", "%(mono%)", "%(stereo%)",
}

-- 末尾の語（丸括弧なし）。
local TRAILING_WORDS = {
  " x64$", " arm64$", " 64bit$", " mono$", " stereo$",
  " vst3$", " vst$", " au$", " clap$",
}

local function strip_tags_once(s)
  local changed = false
  for _, pat in ipairs(PAREN_TAGS) do
    local a, n = s:gsub("%s*" .. pat, "")
    if n > 0 then s = a; changed = true end
  end
  for _, pat in ipairs(TRAILING_WORDS) do
    local a, n = s:gsub(pat, "")
    if n > 0 then s = a; changed = true end
  end
  return s, changed
end

--- プラグイン名を正規化する（メーカー名を除いた部分）。
function M.norm_name(name)
  if not name or name == "" then return "" end
  local s = fullwidth_to_halfwidth(name)
  s = s:lower()
  -- 安定するまでタグを外す（"Name (x64) (mono)" のような重なりに対応）
  for _ = 1, 10 do
    local changed
    s, changed = strip_tags_once(s)
    if not changed then break end
  end
  s = s:gsub("[%-_\226\128\147\226\128\148]", " ") -- - _ – — を空白へ（– —はUTF-8バイト列）
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

-- ============================================================
-- メーカー名の正規化
-- ============================================================

-- 法人表記の接尾辞（小文字化した後の文字列末尾に対して剥がす）。
-- 長いものから複数回試すので順不同でよい。
local LEGAL_SUFFIXES = {
  ", llc", " llc", " ltd.", " ltd", " inc.", " inc", " gmbh",
  " co., ltd.", " co. ltd", " limited", " ab", " bv", " s.a.",
  " srl", " corporation", " corp.",
}

local function strip_legal_suffix_once(s)
  local best = nil
  for _, suf in ipairs(LEGAL_SUFFIXES) do
    if #s > #suf and s:sub(-#suf) == suf then
      if not best or #suf > #best then best = suf end
    end
  end
  if best then
    return s:sub(1, -(#best + 1)), true
  end
  return s, false
end

--- 別名表（データを見て手で足していく）。
-- key: 接尾辞・記号を外した後の表記ゆれ / value: 採用する正規形。
M.VENDOR_ALIASES = {
  ["waves audio"] = "waves",
  ["universal audio uadx"] = "universal audio",
  ["universal audio (uadx)"] = "universal audio",
  ["uadx"] = "universal audio",
  ["native instruments gmbh"] = "native instruments", -- 接尾辞剥がしで通常は不要だが保険
  ["izotope inc"] = "izotope",
  ["fabfilter software instruments"] = "fabfilter",
}

--- メーカー名を正規化する（別名表を当てる前の形。畳み込み報告で使う）。
function M.norm_vendor_pre_alias(vendor)
  if not vendor or vendor == "" then return "" end
  local s = fullwidth_to_halfwidth(vendor)
  s = s:lower()
  for _ = 1, 6 do
    local changed
    s, changed = strip_legal_suffix_once(s)
    s = s:gsub("%s+$", "")
    if not changed then break end
  end
  s = s:gsub("[%.,]", "")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

--- メーカー名を正規化する。
function M.norm_vendor(vendor)
  local s = M.norm_vendor_pre_alias(vendor)
  if s == "" then return s end
  if M.VENDOR_ALIASES[s] then
    s = M.VENDOR_ALIASES[s]
  end
  return s
end

-- ============================================================
-- 先頭のメーカー名の重複を剥がす（"FabFilter Pro-L 2 (FabFilter)" 対策）
-- ============================================================

--- norm_name が norm_vendor（または、メーカーが複数語ならその最初の語で4文字以上のもの）
-- で始まっていたら、その先頭語を剥がす。
-- 何も残らなくなる／残りが2文字未満になる場合は剥がさない
-- （"Decapitator (Soundtoys)" のように名前がメーカー名そのものの場合を壊さないため）。
-- キーはメーカー名も含むので、剥がしても他メーカーの同名プラグインと衝突する心配はない。
function M.strip_vendor_prefix(norm_name_str, norm_vendor_str)
  if norm_name_str == "" or norm_vendor_str == "" then return norm_name_str end

  local candidates = {}
  candidates[#candidates + 1] = norm_vendor_str
  local first_word = norm_vendor_str:match("^(%S+)")
  if first_word and first_word ~= norm_vendor_str and #first_word >= 4 then
    candidates[#candidates + 1] = first_word
  end

  for _, prefix in ipairs(candidates) do
    if #norm_name_str > #prefix and norm_name_str:sub(1, #prefix) == prefix then
      local rest = norm_name_str:sub(#prefix + 1)
      if rest:sub(1, 1) == " " then
        local remaining = rest:gsub("^%s+", "")
        if #remaining >= 2 then
          return remaining
        end
      end
    end
  end
  return norm_name_str
end

-- ============================================================
-- key の組み立て
-- ============================================================

--- 正規化されたキー用の名前（先頭メーカー名の重複を剥がした後）。
function M.norm_name_for_key(name, vendor)
  local nn = M.norm_name(name)
  local nv = M.norm_vendor(vendor)
  return M.strip_vendor_prefix(nn, nv)
end

function M.key(parsed)
  local nn = M.norm_name_for_key(parsed.name, parsed.vendor)
  return nn .. "|" .. M.norm_vendor(parsed.vendor)
end

--- loose_key: key からさらに名前部分の空白をすべて除いたもの。
-- 第2段の畳み込み（"Sausage Fattener" と "SausageFattener" のような表記ゆれ）に
-- tpc_matcher が使う。tpc_normalize の key 自体はこの畳み込みをしない
-- （空白除去は名前を壊す事故が起きやすいので、キーそのものには使わない）。
function M.loose_key(parsed)
  local nn = M.norm_name_for_key(parsed.name, parsed.vendor)
  local loose_name = nn:gsub(" ", "")
  return loose_name .. "|" .. M.norm_vendor(parsed.vendor)
end

--- nameOut / identOut のペアから key を作る（JSはパスで識別）。
-- @return key, parsed  （parseできなければ nil, nil）
function M.key_from(nameOut, identOut)
  local parsed = M.parse(nameOut)
  if not parsed then return nil, nil end
  if parsed.fmt == "JS" then
    local ident = (identOut or ""):gsub("\\", "/"):lower()
    return "js:" .. ident, parsed
  end
  return M.key(parsed), parsed
end

-- ============================================================
-- 編集距離（近い名前の検出用）
-- ============================================================

function M.edit_distance(a, b)
  a = a or ""; b = b or ""
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local prev = {}
  for j = 0, lb do prev[j] = j end
  local cur = {}
  for i = 1, la do
    cur[0] = i
    local ca = a:sub(i, i)
    for j = 1, lb do
      local cost = (ca == b:sub(j, j)) and 0 or 1
      local del = prev[j] + 1
      local ins = cur[j - 1] + 1
      local sub = prev[j - 1] + cost
      local m = del
      if ins < m then m = ins end
      if sub < m then m = sub end
      cur[j] = m
    end
    for j = 0, lb do prev[j] = cur[j] end
  end
  return prev[lb]
end

return M
