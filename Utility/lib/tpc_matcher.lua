--[[
  tpc_matcher.lua
  Team Plugin Checker — 全員分の member ドキュメントから「誰が何を持っているか」の索引を作り、
  共通・形式違い・整備リスト・検索・リンクの新しい方採用を計算する。REAPER呼び出しは含まない。

  索引（index）の形:
    index[key] = {
      key = "正規化キー",
      name = "表示名（一番多い生の名前。同数ならVST3側を優先）",
      vendor = "表示用メーカー名（parsed.vendorそのまま。先頭に出てきたもの）",
      instrument = bool,
      class_id = string|nil,   -- 見つかった中の最初のclass_id（VST3の補助キー）
      raw_names = {生の名前, ...},  -- 検索用（重複あり得る）
      by = {
        [member_id] = { formats = {"VST3","AU",...}, unusable = bool, idents = {...} },
      },
    }

  リンク・エイリアスの合成（LWW）・検索・近い名前判定は tpc_matcher_links.lua に分けて
  ある（1ファイル350行未満に保つため）。公開APIとしてはこの tpc_matcher だけを見ればよい
  （M.merge_links / M.merge_aliases / M.merge_hides / M.search / M.near_duplicates もここから呼べる）。

--]]

local links_part = require("tpc_matcher_links")

local M = {}

-- そのまま公開する（tpc_matcher_links.M.search は circular require を避けるため
-- intersection関数を引数で受け取る形なので、ここでラップして渡す）。
M.merge_links = links_part.merge_links
M.merge_aliases = links_part.merge_aliases
M.merge_hides = links_part.merge_hides
M.near_duplicates = links_part.near_duplicates

-- ============================================================
-- key のエイリアス解決（aliases_merged による手動訂正の適用）
-- ============================================================

local function resolve_alias(key, aliases, depth)
  depth = depth or 0
  if depth > 8 then return key end -- 循環参照の保険
  local canon = aliases and aliases[key]
  -- canon == "" は「別物に戻す（訂正の取り消し）」の意味。エイリアス無しとして扱う。
  if canon and canon ~= "" and canon ~= key then
    return resolve_alias(canon, aliases, depth + 1)
  end
  return key
end

--- key（"name|vendor"の形）から、名前部分の空白だけを除いた loose_key を作る。
-- tpc_normalize.loose_key と同じ規則だが、既にkeyになっている文字列に対して直接適用する
-- （parsed{name,vendor}を作り直さずに済む）。
local function loose_of_key(key)
  local name_part, vendor_part = key:match("^(.-)|(.*)$")
  if not name_part then return key end
  return (name_part:gsub(" ", "")) .. "|" .. vendor_part
end

-- ============================================================
-- 表示名の選定（一番多い生の名前。同数ならVST3側）
-- ============================================================

local function pick_display_name(name_counts, name_vst3)
  local best_n = -1
  for _, c in pairs(name_counts) do
    if c > best_n then best_n = c end
  end
  local ties = {}
  for n, c in pairs(name_counts) do
    if c == best_n then ties[#ties + 1] = n end
  end
  table.sort(ties)
  if #ties <= 1 then return ties[1] end
  for _, n in ipairs(ties) do
    if name_vst3[n] then return n end
  end
  return ties[1]
end

local function finalize_entry(e)
  local raw_names = {}
  local seen = {}
  for _, n in ipairs(e.raw_names_list or {}) do
    if not seen[n] then
      seen[n] = true
      raw_names[#raw_names + 1] = n
    end
  end
  return {
    key = e.key,
    name = pick_display_name(e.name_counts, e.name_vst3),
    vendor = e.vendor or "",
    instrument = e.instrument or false,
    class_id = e.class_id,
    raw_names = raw_names,
    by = e.by,
  }
end

-- ============================================================
-- M.merge: 全員分の plugins を畳み込んで索引を作る
-- ============================================================

--- @param members  store:read_members() が返す member ドキュメントの並び
-- @param aliases_merged  M.merge_aliases() の結果（{ [key] = canonical_key }）。省略可。
-- @return index
function M.merge(members, aliases_merged)
  aliases_merged = aliases_merged or {}

  -- PASS 1: エイリアス解決後のキーで集約する。
  local pass1 = {}
  for _, member in ipairs(members or {}) do
    local member_id = member.member_id
    if member_id and member_id ~= "" then
      for _, p in ipairs(member.plugins or {}) do
        local canon_key = resolve_alias(p.key, aliases_merged)
        local e = pass1[canon_key]
        if not e then
          e = {
            key = canon_key,
            name_counts = {},
            name_vst3 = {},
            raw_names_list = {},
            vendor = nil,
            instrument = false,
            class_id = nil,
            by = {},
          }
          pass1[canon_key] = e
        end

        e.name_counts[p.name] = (e.name_counts[p.name] or 0) + 1
        if p.vendor and p.vendor ~= "" and (not e.vendor or e.vendor == "") then
          e.vendor = p.vendor
        end
        if p.instrument then e.instrument = true end
        if p.class_id and p.class_id ~= "" and not e.class_id then
          e.class_id = p.class_id
        end

        local fmts, idents, has_vst3 = {}, {}, false
        for _, f in ipairs(p.formats or {}) do
          fmts[#fmts + 1] = f.fmt
          idents[#idents + 1] = f.ident
          if f.raw_name then e.raw_names_list[#e.raw_names_list + 1] = f.raw_name end
          if f.fmt == "VST3" then has_vst3 = true end
        end
        if has_vst3 then e.name_vst3[p.name] = true end

        -- 同じメンバーが、エイリアス訂正で1つに畳まれた2つのキーを両方持っていることがある
        -- （VST3は片方のキー、AUはもう片方のキー、など）。上書きすると形式と識別子が
        -- 片方だけになり、○は出るのに挿入できない行になるので、必ず合算する。
        local existing = e.by[member_id]
        if existing then
          for _, f in ipairs(fmts) do existing.formats[#existing.formats + 1] = f end
          for _, idn in ipairs(idents) do existing.idents[#existing.idents + 1] = idn end
          existing.unusable = existing.unusable or (p.unusable == true)
        else
          e.by[member_id] = { formats = fmts, unusable = (p.unusable == true), idents = idents }
        end
      end
    end
  end

  -- PASS 2: loose_key（名前の空白だけ違う表記ゆれ）でさらに畳み込む。
  local groups = {}
  for key, e in pairs(pass1) do
    local lk = loose_of_key(key)
    groups[lk] = groups[lk] or {}
    groups[lk][#groups[lk] + 1] = e
  end

  local index = {}
  for _, list in pairs(groups) do
    if #list == 1 then
      local e = list[1]
      index[e.key] = finalize_entry(e)
    else
      table.sort(list, function(a, b) return a.key < b.key end)
      local merged = {
        key = list[1].key, -- 代表キー（辞書順で一番小さいもの。決定的にするため）
        name_counts = {}, name_vst3 = {}, raw_names_list = {},
        vendor = nil, instrument = false, class_id = nil, by = {},
      }
      for _, e in ipairs(list) do
        for n, c in pairs(e.name_counts) do merged.name_counts[n] = (merged.name_counts[n] or 0) + c end
        for n in pairs(e.name_vst3) do merged.name_vst3[n] = true end
        for _, rn in ipairs(e.raw_names_list) do merged.raw_names_list[#merged.raw_names_list + 1] = rn end
        if e.vendor and e.vendor ~= "" and (not merged.vendor or merged.vendor == "") then merged.vendor = e.vendor end
        if e.instrument then merged.instrument = true end
        if e.class_id and not merged.class_id then merged.class_id = e.class_id end
        for member_id, rec in pairs(e.by) do
          local existing = merged.by[member_id]
          if not existing then
            merged.by[member_id] = rec
          else
            -- 同じメンバーが両方のキーで持っている稀なケース: 形式と識別子を合算する。
            for _, f in ipairs(rec.formats) do existing.formats[#existing.formats + 1] = f end
            for _, idn in ipairs(rec.idents) do existing.idents[#existing.idents + 1] = idn end
            existing.unusable = existing.unusable or rec.unusable
          end
        end
      end
      index[merged.key] = finalize_entry(merged)
    end
  end

  return index
end

-- ============================================================
-- 所持判定・共通計算
-- ============================================================

--- entry を member_id が「使える形で」持っているか（＝使えない印が付いていない）。
function M.has(entry, member_id)
  local rec = entry and entry.by and entry.by[member_id]
  return rec ~= nil and rec.unusable ~= true
end

--- member_ids 全員が持っている entry の並び（名前順）。
function M.intersection(index, member_ids)
  local out = {}
  for _, e in pairs(index) do
    local all_have = true
    for _, member_id in ipairs(member_ids or {}) do
      if not M.has(e, member_id) then all_have = false; break end
    end
    if all_have and #(member_ids or {}) > 0 then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.key < b.key
  end)
  return out
end

--- tpc_matcher_links.search はcircular requireを避けるため intersection を引数で受け取る。
function M.search(index, query, opts)
  return links_part.search(index, query, opts, M.intersection)
end

-- ============================================================
-- 古いメンバーの判定
-- ============================================================

local function parse_iso(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)Z?$")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(se), isdst = false,
  })
end

--- updated_at が now_iso_str から days（既定30）日より前なら「古い」。
-- パースできなければ古いとは判定しない（false）。
function M.is_stale(updated_at, now_iso_str, days)
  days = days or 30
  local t1, t2 = parse_iso(updated_at), parse_iso(now_iso_str)
  if not t1 or not t2 then return false end
  return (t2 - t1) > (days * 86400)
end

--- 「全員共通」= 古くない（30日以内に更新された）メンバー全員の共通部分。
-- @return list(entry), active_member_ids
function M.everyone(index, members, now_iso_str)
  local active_ids = {}
  for _, m in ipairs(members or {}) do
    if m.member_id and m.member_id ~= "" and not M.is_stale(m.updated_at, now_iso_str) then
      active_ids[#active_ids + 1] = m.member_id
    end
  end
  return M.intersection(index, active_ids), active_ids
end

-- ============================================================
-- 整備タブ
-- ============================================================

local function has_format(rec, fmt)
  for _, f in ipairs(rec and rec.formats or {}) do
    if f == fmt then return true end
  end
  return false
end

--- 自分は持っているがVST3ではなく、他の誰か1人でもVST3を持っている entry の並び。
function M.format_mismatch(index, me)
  local out = {}
  for _, e in pairs(index) do
    if M.has(e, me) then
      local mine = e.by[me]
      if not has_format(mine, "VST3") then
        local other_has_vst3 = false
        for member_id, rec in pairs(e.by) do
          if member_id ~= me and has_format(rec, "VST3") then other_has_vst3 = true; break end
        end
        if other_has_vst3 then out[#out + 1] = e end
      end
    end
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

--- 整備タブの3項目: (1)形式違い (2)使えない印のついた自分の物 (3)自分以外の誰かが持つ無料プラグイン。
-- (3)は当初「自分以外の全員」だったが、2026-09-11につこさんの指摘で「誰か1人でも」に変更。
-- links_merged は M.merge_links() の結果。active_members は「古くない」member_idの並び。
function M.maintenance(index, me, links_merged, active_members)
  local mismatch = M.format_mismatch(index, me)

  local unusable_mine = {}
  local free_missing = {}

  local other_active = {}
  for _, member_id in ipairs(active_members or {}) do
    if member_id ~= me then other_active[#other_active + 1] = member_id end
  end

  for key, e in pairs(index) do
    local mine = e.by and e.by[me]
    if mine and mine.unusable == true then
      unusable_mine[#unusable_mine + 1] = { entry = e, idents = mine.idents }
    end

    if not mine and #other_active > 0 then
      local link = links_merged and links_merged[key]
      if link and link.free == true then
        local someone_else_has = false
        for _, member_id in ipairs(other_active) do
          if M.has(e, member_id) then someone_else_has = true; break end
        end
        if someone_else_has then
          free_missing[#free_missing + 1] = e
        end
      end
    end
  end

  table.sort(unusable_mine, function(a, b) return a.entry.key < b.entry.key end)
  table.sort(free_missing, function(a, b) return a.key < b.key end)

  return { mismatch = mismatch, unusable_mine = unusable_mine, free_missing = free_missing }
end

return M
