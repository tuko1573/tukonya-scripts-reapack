--[[
  tpc_matcher_links.lua
  Team Plugin Checker — tpc_matcher の一部。リンク・エイリアスの合成（LWW）、検索、
  近い名前（"≒"印）の判定。tpc_matcher.lua が require して自分のAPIに合成する
  （モジュールを350行未満に保つための分割。呼び出し側は tpc_matcher だけ見ればよい）。
--]]

local normalize = require("tpc_normalize")

local M = {}

-- ============================================================
-- リンク・エイリアスの合成（最新更新日時優先＝LWW）
-- ============================================================

--- link_docs: store:read_links() の並び。各ドキュメントは
--   { member_id = "kamil", links = { [key] = {url=.., free=.., updated_at=..}, ... } }
-- の形（tpc_store は中身を関知しないので、この形はSendNow/UI側で書く約束にする）。
-- @return { [key] = {url, free, updated_at, by} }
-- url=="" は「消去」の意味。一番新しい更新が url=="" ならそのキーは結果から消える。
function M.merge_links(link_docs)
  local out = {}
  for _, doc in ipairs(link_docs or {}) do
    local member_id = doc.member_id
    for key, rec in pairs(doc.links or {}) do
      local cur = out[key]
      local ts = rec.updated_at or ""
      if not cur or ts > (cur.updated_at or "") then
        out[key] = { url = rec.url or "", free = rec.free == true, updated_at = rec.updated_at, by = member_id }
      end
    end
  end
  for key, rec in pairs(out) do
    if rec.url == "" then out[key] = nil end
  end
  return out
end

--- alias_docs: store:read_aliases() の並び。各ドキュメントは
--   { member_id = "kamil", aliases = { [key] = { canonical_key = .., updated_at = .. }, ... } }
-- の形。同じキーに複数の訂正があれば、一番新しい更新日時のものが勝つ（LWW）。
-- canonical_key == "" は「別物に戻す」＝訂正の取り消し。LWWの比較には参加するが、
-- 最後に勝った値が "" なら結果から消える（＝エイリアス無し）。merge_links と同じ形。
-- @return { [key] = canonical_key }
function M.merge_aliases(alias_docs)
  local out = {}
  local latest_ts = {}
  for _, doc in ipairs(alias_docs or {}) do
    for key, rec in pairs(doc.aliases or {}) do
      local canon, ts
      if type(rec) == "table" then
        canon, ts = rec.canonical_key, rec.updated_at
      else
        canon, ts = rec, doc.updated_at
      end
      ts = ts or ""
      if canon and (not latest_ts[key] or ts > latest_ts[key]) then
        latest_ts[key] = ts
        out[key] = canon
      end
    end
  end
  for key, canon in pairs(out) do
    if canon == "" then out[key] = nil end
  end
  return out
end

--- hide_docs: store:read_hides() の並び。各ドキュメントは
--   { member_id = "kamil", entries = { [key] = { hidden = true|false, updated_at = .. }, ... } }
-- の形。「非表示」＝検索タブの一覧から全員分まとめて消すこと（「使えない」△とは別物で、
-- こちらは行ごと出なくなる）。同じキーに複数あれば一番新しい更新日時が勝つ（LWW）。
-- hidden == false は「リストに復帰」＝非表示の取り消し。merge_aliases の "" と同じ扱いで、
-- LWWの比較には参加するが、最後に勝った値が false なら結果から消える。
-- @return { [key] = { hidden = true, updated_at, by } }
function M.merge_hides(hide_docs)
  local out = {}
  for _, doc in ipairs(hide_docs or {}) do
    local member_id = doc.member_id
    for key, rec in pairs(doc.entries or {}) do
      if type(rec) == "table" then
        local cur = out[key]
        local ts = rec.updated_at or ""
        if not cur or ts > (cur.updated_at or "") then
          out[key] = { hidden = (rec.hidden == true), updated_at = rec.updated_at, by = rec.by or member_id }
        end
      end
    end
  end
  for key, rec in pairs(out) do
    if rec.hidden ~= true then out[key] = nil end
  end
  return out
end

-- ============================================================
-- 検索
-- ============================================================

local function alnum_only(s)
  return (s:lower():gsub("[^%w]", ""))
end

--- opts.only_members: この並びの全員が持っている物だけに絞る（相手を選んで絞る機能）。
-- intersection_fn は tpc_matcher.intersection（循環requireを避けるため呼び出し側から渡す）。
function M.search(index, query, opts, intersection_fn)
  opts = opts or {}
  query = query or ""

  local words = {}
  for w in query:lower():gmatch("%S+") do words[#words + 1] = w end
  local compact_query = alnum_only(query)

  local restrict = nil
  if opts.only_members and #opts.only_members > 0 and intersection_fn then
    restrict = {}
    for _, e in ipairs(intersection_fn(index, opts.only_members)) do restrict[e.key] = true end
  end

  local results = {}
  for key, e in pairs(index) do
    if not restrict or restrict[key] then
      local parts = { e.name or "", e.vendor or "" }
      for _, rn in ipairs(e.raw_names or {}) do parts[#parts + 1] = rn end
      local haystack = table.concat(parts, " "):lower()

      local matched
      if query == "" then
        matched = true
      else
        matched = true
        for _, w in ipairs(words) do
          if not haystack:find(w, 1, true) then matched = false; break end
        end
        if not matched and compact_query ~= "" then
          local compact_haystack = alnum_only(haystack)
          if compact_haystack:find(compact_query, 1, true) then matched = true end
        end
      end

      if matched then results[#results + 1] = e end
    end
  end

  local q = query:lower()
  table.sort(results, function(a, b)
    local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
    if q ~= "" then
      local a_prefix = an:sub(1, #q) == q
      local b_prefix = bn:sub(1, #q) == q
      if a_prefix ~= b_prefix then return a_prefix end
    end
    if an ~= bn then return an < bn end
    return a.key < b.key
  end)
  return results
end

-- ============================================================
-- 近い名前（"≒"印）
-- ============================================================

--- 同メーカーで編集距離<=2、または class_id が同じで別キーの組を挙げる。
-- （tools/report_phase1.lua の考え方を索引ベースで再利用。UIの "≒" 印用。）
function M.near_duplicates(index)
  local list = {}
  for _, e in pairs(index) do list[#list + 1] = e end
  table.sort(list, function(a, b) return a.key < b.key end)

  local out = {}

  local by_vendor = {}
  for _, e in ipairs(list) do
    if e.vendor and e.vendor ~= "" then
      by_vendor[e.vendor] = by_vendor[e.vendor] or {}
      by_vendor[e.vendor][#by_vendor[e.vendor] + 1] = e
    end
  end
  for _, group in pairs(by_vendor) do
    for i = 1, #group do
      for j = i + 1, #group do
        local a, b = group[i], group[j]
        local an = a.key:match("^(.-)|") or a.key
        local bn = b.key:match("^(.-)|") or b.key
        local dist = normalize.edit_distance(an, bn)
        if dist > 0 and dist <= 2 then
          out[#out + 1] = { a = a, b = b, reason = "edit_distance", dist = dist }
        end
      end
    end
  end

  local by_class = {}
  for _, e in ipairs(list) do
    if e.class_id and e.class_id ~= "" then
      by_class[e.class_id] = by_class[e.class_id] or {}
      by_class[e.class_id][#by_class[e.class_id] + 1] = e
    end
  end
  for class_id, group in pairs(by_class) do
    if #group > 1 then
      for i = 1, #group do
        for j = i + 1, #group do
          if group[i].key ~= group[j].key then
            out[#out + 1] = { a = group[i], b = group[j], reason = "class_id", class_id = class_id }
          end
        end
      end
    end
  end

  table.sort(out, function(x, y)
    if x.a.key ~= y.a.key then return x.a.key < y.a.key end
    return x.b.key < y.b.key
  end)
  return out
end

return M
