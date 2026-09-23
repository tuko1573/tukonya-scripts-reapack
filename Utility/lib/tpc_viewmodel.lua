--[[
  tpc_viewmodel.lua
  Team Plugin Checker — 小窓（tpc_ui）が表示するものを、データだけから組み立てる純Lua部分。
  REAPER も ImGui も呼ばない（テストが素のLuaで走る）。突き合わせの規則そのものは
  tpc_matcher / tpc_store / tpc_normalize が持ち、ここでは「画面に出す形」に整えるだけ
  ＝ロジックをUI側へ複製しない。

--]]

local Matcher = require("tpc_matcher")
local Actions = require("tpc_viewmodel_actions")
local Sort = require("tpc_viewmodel_sort")

local M = {}

M.ALL = "__all__"

-- 「押したときに起きること」は tpc_viewmodel_actions に置いてある（同じAPIとして公開する）。
M.percent_encode    = Actions.percent_encode
M.ai_question       = Actions.ai_question
M.ai_url            = Actions.ai_url
M.insert_candidates = Actions.insert_candidates
M.locate_path       = Actions.locate_path
M.toggle_unusable   = Actions.toggle_unusable
M.save_link         = Actions.save_link
M.save_alias        = Actions.save_alias
M.save_hide         = Actions.save_hide
M.hidden_rows       = Actions.hidden_rows

local sorted_formats = Actions.sorted_formats
local ident_kind = Actions.ident_kind

-- ============================================================
-- VM.load — ディスクから読み直して、画面に必要な状態を組み立てる
-- ============================================================

--- メンバー・リンクの「変わっていないか」を判定するための署名。
local function signature(member_docs, link_docs, alias_docs, hide_docs, me)
  local parts = { "me=" .. tostring(me) }
  local rows = {}
  for _, d in ipairs(member_docs) do
    rows[#rows + 1] = string.format("m:%s:%s:%s",
      tostring(d.member_id), tostring(d.updated_at), tostring(d.inventory_hash))
  end
  for _, d in ipairs(link_docs) do
    local n = 0
    for _ in pairs(d.links or {}) do n = n + 1 end
    rows[#rows + 1] = string.format("l:%s:%d:%s", tostring(d.member_id), n, tostring(d.updated_at))
  end
  for _, d in ipairs(alias_docs) do
    local n = 0
    for _ in pairs(d.aliases or {}) do n = n + 1 end
    rows[#rows + 1] = string.format("a:%s:%d:%s", tostring(d.member_id), n, tostring(d.updated_at))
  end
  for _, d in ipairs(hide_docs) do
    local n = 0
    for _ in pairs(d.entries or {}) do n = n + 1 end
    rows[#rows + 1] = string.format("h:%s:%d:%s", tostring(d.member_id), n, tostring(d.updated_at))
  end
  table.sort(rows)
  for _, r in ipairs(rows) do parts[#parts + 1] = r end
  return table.concat(parts, "\n")
end

--- 自分のプラグイン（member doc の plugins[]）を、索引側のキーへ結びつける。
-- tpc_matcher.merge はエイリアス解決と loose_key の畳み込みでキーを書き換えることがあるので、
-- doc の p.key をそのまま索引のキーとして使ってはいけない。識別子（ident）で橋渡しする。
local function build_mine_by_key(index, me, me_doc)
  local ident_to_key = {}
  for key, e in pairs(index) do
    local rec = e.by and e.by[me]
    if rec then
      for _, idn in ipairs(rec.idents or {}) do
        if idn and idn ~= "" then ident_to_key[idn] = key end
      end
    end
  end

  local mine = {}
  for _, p in ipairs(me_doc and me_doc.plugins or {}) do
    local key = nil
    for _, f in ipairs(p.formats or {}) do
      if f.ident and ident_to_key[f.ident] then key = ident_to_key[f.ident]; break end
    end
    key = key or p.key
    mine[key] = mine[key] or {}
    mine[key][#mine[key] + 1] = p
  end
  return mine
end

--- @param store  tpc_store のインスタンス
-- @param root   store:root(shared_dir) の結果
-- @param config tpc_config のインスタンス（member_id / display_name を読む）
-- @param now_iso "YYYY-MM-DDTHH:MM:SSZ"
-- @param prev_state 直前の state（省略可）。中身が同じなら再計算せずそのまま返す。
function M.load(store, root, config, now_iso, prev_state)
  local me = config and config:get_member_id() or nil
  local me_display = (config and config:get_display_name()) or me

  local member_docs = store:read_members(root)
  local link_docs = store:read_links(root)
  local alias_docs = store:read_aliases(root)
  local hide_docs = store:read_hides(root)

  local sig = signature(member_docs, link_docs, alias_docs, hide_docs, me)
  if prev_state and prev_state.sig == sig then
    prev_state.now_iso = now_iso
    return prev_state
  end

  local aliases = Matcher.merge_aliases(alias_docs)
  local index = Matcher.merge(member_docs, aliases)
  local links = Matcher.merge_links(link_docs)
  local hides = Matcher.merge_hides(hide_docs)

  local members, me_doc = {}, nil
  local active_ids = {}
  for _, d in ipairs(member_docs) do
    if d.member_id and d.member_id ~= "" then
      local stale = Matcher.is_stale(d.updated_at, now_iso)
      members[#members + 1] = {
        id = d.member_id,
        display_name = (d.display_name ~= nil and d.display_name ~= "") and d.display_name or d.member_id,
        updated_at = d.updated_at,
        stale = stale,
        is_me = (d.member_id == me),
        plugin_count = #(d.plugins or {}),
      }
      if not stale then active_ids[#active_ids + 1] = d.member_id end
      if d.member_id == me then me_doc = d end
    end
  end

  -- 自分のファイルがまだ無い（SendNowを1度も動かしていない）場合も、自分の列は出す。
  local me_has_file = (me_doc ~= nil)
  if me and not me_has_file then
    members[#members + 1] = {
      id = me, display_name = me_display or me, updated_at = nil,
      stale = false, is_me = true, plugin_count = 0, no_file = true,
    }
  end

  table.sort(members, function(a, b)
    if a.is_me ~= b.is_me then return a.is_me end
    return a.id < b.id
  end)

  local mismatch_keys = {}
  if me then
    for _, e in ipairs(Matcher.format_mismatch(index, me)) do mismatch_keys[e.key] = true end
  end

  return {
    me = me,
    me_display = me_display,
    me_has_file = me_has_file,
    me_in_index = (me ~= nil and me_has_file),
    members = members,
    active_ids = active_ids,
    index = index,
    links = links,
    aliases = aliases,
    hides = hides,
    member_docs = member_docs,
    me_doc = me_doc,
    mine_by_key = build_mine_by_key(index, me, me_doc),
    mismatch_keys = mismatch_keys,
    near_keys = nil, -- 重いので初回参照時に作る（M.ensure_near）
    now_iso = now_iso,
    sig = sig,
    generation = (prev_state and prev_state.generation or 0) + 1,
  }
end

--- 「≒」印（近い名前）のキー集合。O(n^2) になり得るので、必要になった時に1回だけ作る。
-- @return near_keys, near_pairs（訂正の小窓が候補を出すのに使う組の並び）
function M.ensure_near(state)
  if state.near_keys then return state.near_keys, state.near_pairs end
  local list = Matcher.near_duplicates(state.index)
  local keys = {}
  for _, pair in ipairs(list) do
    keys[pair.a.key] = true
    keys[pair.b.key] = true
  end
  state.near_keys = keys
  state.near_pairs = list
  return keys, list
end

-- ============================================================
-- VM.alias_info — 「同じものとして扱う」小窓に出す中身
-- ============================================================

--- そのentryを持っている人の表示名の並び。
local function holders_of(state, e)
  local names = {}
  for _, m in ipairs(state.members) do
    if e.by and e.by[m.id] then names[#names + 1] = m.display_name or m.id end
  end
  return names
end

--- @return {
--   key, candidates = { {key,name,vendor,holders,reason,dist}, ... },
--   aliased_in = { {key, canonical} , ... }   -- この行に「同じ物」として寄せてあるキー
-- }
function M.alias_info(state, key)
  local _, pairs_list = M.ensure_near(state)

  local seen, candidates = {}, {}
  for _, pair in ipairs(pairs_list or {}) do
    local other = nil
    if pair.a.key == key then other = pair.b
    elseif pair.b.key == key then other = pair.a end
    if other and not seen[other.key] then
      seen[other.key] = true
      candidates[#candidates + 1] = {
        key = other.key, name = other.name, vendor = other.vendor,
        holders = holders_of(state, other),
        reason = pair.reason, dist = pair.dist, class_id = pair.class_id,
      }
    end
  end
  table.sort(candidates, function(a, b) return a.key < b.key end)

  local aliased_in = {}
  for k, canon in pairs(state.aliases or {}) do
    if canon == key and k ~= key then aliased_in[#aliased_in + 1] = { key = k, canonical = canon } end
  end
  table.sort(aliased_in, function(a, b) return a.key < b.key end)

  return { key = key, candidates = candidates, aliased_in = aliased_in, alias_of = (state.aliases or {})[key] }
end

-- ============================================================
-- VM.rows — 検索タブの表
-- ============================================================

--- 選ばれたメンバーidの並びを、実際に絞り込みに使うidの並びへ変換する。
-- "__all__" は「古くないメンバー全員」。自分は常に含める（自分が持っていない物を
-- 「共通」に出しても挿せないため）。ただし自分がまだ索引に居ないときは加えない
-- （全部0件になってしまうので）。
function M.effective_members(state, selected_member_ids)
  local set, out = {}, {}
  local function add(id)
    if id and id ~= "" and not set[id] then set[id] = true; out[#out + 1] = id end
  end
  local any = false
  for _, id in ipairs(selected_member_ids or {}) do
    any = true
    if id == M.ALL then
      for _, a in ipairs(state.active_ids or {}) do add(a) end
    else
      add(id)
    end
  end
  if not any then return {} end
  if state.me_in_index then add(state.me) end
  return out
end

--- @param opts { near = bool, include_hidden = bool, sort = {column="name"|"vendor", descending=bool} }
-- near=true のときだけ「≒」判定を行う（重いので既定でオン）。
-- 「非表示」にされたキーは既定で落とす（include_hidden=true で残す）。エイリアス解決と
-- 畳み込みが済んだ後のキー＝画面に出ているキーで判定する。
-- opts.sort（列見出しクリック）が無ければ Matcher.search の関連度順のまま返す。
function M.rows(state, query, selected_member_ids, opts)
  opts = opts or {}
  local only = M.effective_members(state, selected_member_ids)
  local entries = Matcher.search(state.index, query or "", { only_members = only })

  local want_near = (opts.near ~= false)
  local near_keys = want_near and M.ensure_near(state) or {}

  local hides = (not opts.include_hidden) and (state.hides or {}) or nil

  local me = state.me
  local rows = {}
  for _, e in ipairs(entries) do
    if not (hides and hides[e.key]) then
      local by_member = {}
      for _, m in ipairs(state.members) do
        local rec = e.by and e.by[m.id]
        if not rec then
          by_member[m.id] = "none"
        elseif rec.unusable then
          by_member[m.id] = "unusable"
        else
          by_member[m.id] = "has"
        end
      end

      local mine_rec = me and e.by and e.by[me] or nil
      local formats_mine = sorted_formats(mine_rec and mine_rec.formats)

      rows[#rows + 1] = {
        key = e.key,
        name = e.name,
        vendor = e.vendor,
        instrument = e.instrument,
        by_member = by_member,
        formats_mine = formats_mine,
        unusable_mine = (mine_rec ~= nil and mine_rec.unusable == true),
        mismatch = (state.mismatch_keys[e.key] == true),
        near = (near_keys[e.key] == true),
        link = state.links[e.key],
        mine = state.mine_by_key[e.key],
        -- 索引側に残っている「自分の記録」。mine が nil のときの挿入の予備に使う。
        mine_index = mine_rec and { formats = mine_rec.formats, idents = mine_rec.idents } or nil,
        raw_names = e.raw_names,
      }
    end
  end
  return Sort.apply_sort(rows, opts.sort)
end

-- ============================================================
-- VM.maintenance — 整備タブの3つの一覧
-- ============================================================

local function decorate(state, e, extra)
  local me = state.me
  local mine_rec = me and e.by and e.by[me] or nil
  local row = {
    key = e.key,
    name = e.name,
    vendor = e.vendor,
    formats_mine = sorted_formats(mine_rec and mine_rec.formats),
    link = state.links[e.key],
    mine = state.mine_by_key[e.key],
    mine_index = mine_rec and { formats = mine_rec.formats, idents = mine_rec.idents } or nil,
    raw_names = e.raw_names,
  }
  for k, v in pairs(extra or {}) do row[k] = v end
  return row
end

--- 自分以外で、その entry をVST3で持っている人の表示名の並び（整備タブ(1)の説明用）。
local function vst3_holders(state, e)
  local names = {}
  for _, m in ipairs(state.members) do
    if m.id ~= state.me then
      local rec = e.by and e.by[m.id]
      for _, f in ipairs(rec and rec.formats or {}) do
        if f == "VST3" then names[#names + 1] = m.display_name or m.id; break end
      end
    end
  end
  return names
end

function M.maintenance(state)
  local res = Matcher.maintenance(state.index, state.me, state.links, state.active_ids)

  local mismatch = {}
  for _, e in ipairs(res.mismatch) do
    mismatch[#mismatch + 1] = decorate(state, e, { vst3_members = vst3_holders(state, e) })
  end

  local unusable_mine = {}
  for _, item in ipairs(res.unusable_mine) do
    local idents = {}
    for _, idn in ipairs(item.idents or {}) do
      local kind, value = ident_kind(idn)
      idents[#idents + 1] = { raw = idn, kind = kind, value = value or idn }
    end
    unusable_mine[#unusable_mine + 1] = decorate(state, item.entry, { idents = idents })
  end

  local free_missing = {}
  for _, e in ipairs(res.free_missing) do free_missing[#free_missing + 1] = decorate(state, e) end

  return { mismatch = mismatch, unusable_mine = unusable_mine, free_missing = free_missing }
end

return M
