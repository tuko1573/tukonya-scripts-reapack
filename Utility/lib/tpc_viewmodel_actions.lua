--[[
  tpc_viewmodel_actions.lua
  Team Plugin Checker — tpc_viewmodel の一部。純Lua。
  「押したときに起きること」（使えない印の反転、リンクの保存、非表示、AIに聞くURL、
  挿入で試す名前の候補）と、形式・識別子まわりの小道具。
  tpc_viewmodel.lua が require して自分のAPIに合成するので、呼び出し側は
  tpc_viewmodel だけ見ればよい（1ファイル400行未満に保つための分割）。
--]]

local Store = require("tpc_store")

local M = {}

-- 挿入で試す形式の優先順。実測（reports/phase0_probe.md）の fmt トークンに合わせる。
M.FORMAT_RANK = { VST3 = 1, AU = 2, CLAP = 3, VST2 = 4, LV2 = 5, JS = 6 }
local FORMAT_RANK = M.FORMAT_RANK

local AI_BASE = {
  chatgpt = "https://chatgpt.com/?q=",
  claude = "https://claude.ai/new?q=",
  perplexity = "https://www.perplexity.ai/search?q=",
}

--- RFC 3986 の unreserved（A-Z a-z 0-9 - . _ ~）以外をすべて %XX にする。
-- %w は C の isalnum 経由でロケール依存になり得るので、明示的な文字クラスで書く。
function M.percent_encode(s)
  s = tostring(s or "")
  return (s:gsub("[^A-Za-z0-9%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- "VST3: Pro-Q 4 (FabFilter)" → "Pro-Q 4 (FabFilter)"
local function strip_fx_prefix(raw_name)
  return (raw_name:gsub("^%a+%d*i?:%s*", ""))
end

-- 生の名前の接頭辞 → 形式トークン（tpc_normalize の PREFIXES と同じ対応）。
local PREFIX_TO_FMT = {
  VST3 = "VST3", VST3i = "VST3", VST = "VST2", VSTi = "VST2",
  AU = "AU", AUi = "AU", CLAP = "CLAP", CLAPi = "CLAP",
  JS = "JS", JSi = "JS", LV2 = "LV2", LV2i = "LV2",
}

--- "VST3: Pro-Q 4 (FabFilter)" → "VST3"。接頭辞が無ければ nil。
local function fmt_of_raw_name(raw_name)
  if type(raw_name) ~= "string" then return nil end
  local token = raw_name:match("^(%a+%d*i?):")
  return token and PREFIX_TO_FMT[token] or nil
end

function M.sorted_formats(fmts)
  local out = {}
  local seen = {}
  for _, f in ipairs(fmts or {}) do
    if not seen[f] then seen[f] = true; out[#out + 1] = f end
  end
  table.sort(out, function(a, b)
    return (FORMAT_RANK[a] or 99) < (FORMAT_RANK[b] or 99)
  end)
  return out
end
local sorted_formats = M.sorted_formats

--- 識別子が「実体ファイルのパス」か、そうでない文字列（AUの "Vendor: Name"、
-- CLAPの逆DNS、JSの相対パス）かを見分ける。「場所を開く」ボタンの可否に使う。
function M.ident_kind(ident)
  if type(ident) ~= "string" or ident == "" then return "unknown" end
  local path = ident:gsub("<%d+$", "") -- Wavesの殻の子（…vst3<7）
  if path:match("%.vst3$") or path:match("%.vst$") or path:match("%.dll$") or path:match("%.dylib$")
    or path:match("%.clap$") or path:match("^[/\\]") or path:match("^%a:[/\\]") then
    return "path", path
  end
  return "text", ident
end
local ident_kind = M.ident_kind

-- ============================================================
-- VM.toggle_unusable — 自分のメンバーファイルの「使えない印」を反転して書き戻す
-- ============================================================

function M.toggle_unusable(state, key, store, root, now_iso)
  if not state.me then return false, "メンバーIDが未設定" end
  local doc = state.me_doc
  if not doc then return false, "自分の一覧がまだ共有フォルダにありません（設定タブの「今すぐ更新」を先に）" end

  local targets = state.mine_by_key[key]
  if not targets or #targets == 0 then return false, "自分は持っていません" end

  local new_value = not (targets[1].unusable == true)
  for _, p in ipairs(targets) do p.unusable = new_value end

  doc.updated_at = now_iso or state.now_iso or doc.updated_at
  doc.inventory_hash = Store.hash_member_doc(doc)

  local ok, err = store:write_member(root, doc)
  if not ok then
    -- 書けなかったら画面上の値も元に戻す（ディスクと食い違わせない）。
    for _, p in ipairs(targets) do p.unusable = not new_value end
    return false, err
  end
  return true, nil, new_value
end

-- ============================================================
-- VM.save_link — 自分の links/<id>.json に1件だけ足して書き戻す（LWW）
-- ============================================================

function M.save_link(state, key, url, free, store, root, now_iso)
  if not state.me then return false, "メンバーIDが未設定" end
  if not key or key == "" then return false, "キーが空" end

  local doc = nil
  for _, d in ipairs(store:read_links(root)) do
    if d.member_id == state.me then doc = d; break end
  end
  doc = doc or { member_id = state.me, links = {} }
  doc.links = doc.links or {}
  doc.member_id = state.me
  doc.links[key] = {
    url = url or "",
    free = (free == true),
    updated_at = now_iso or state.now_iso,
    by = state.me,
  }
  doc.updated_at = now_iso or state.now_iso
  return store:write_links(root, state.me, doc)
end

-- ============================================================
-- VM.save_alias — 「同じものとして扱う」訂正を自分の aliases/<id>.json へ書く
-- ============================================================

--- canonical == "" は「別物に戻す」（訂正の取り消し）。新しい更新日時で書くので、
-- 全員分を合わせたとき（tpc_matcher.merge_aliases）にこちらが勝ち、エイリアスが消える。
-- @return ok, err
function M.save_alias(state, key, canonical, store, root, now_iso)
  if not state or not state.me then return false, "メンバーIDが未設定" end
  if not key or key == "" then return false, "キーが空" end
  canonical = canonical or ""

  if canonical ~= "" then
    if canonical == key then return false, "同じキーは指定できません" end
    -- 既にエイリアスされているキーを指されたら、終端のキーまで辿ってそれを記録する
    -- （A→B→C の鎖を作らない）。途中で自分に戻ってくるなら循環なので断る。
    local cur = canonical
    for _ = 1, 8 do
      local nxt = state.aliases and state.aliases[cur]
      if not nxt or nxt == "" or nxt == cur then break end
      if nxt == key then return false, "循環する指定です" end
      cur = nxt
    end
    canonical = cur
    if canonical == key then return false, "同じキーは指定できません" end
  end

  local doc = nil
  for _, d in ipairs(store:read_aliases(root)) do
    if d.member_id == state.me then doc = d; break end
  end
  doc = doc or { member_id = state.me, aliases = {} }
  if type(doc.aliases) ~= "table" then doc.aliases = {} end
  doc.member_id = state.me
  local ts = now_iso or state.now_iso
  doc.aliases[key] = { canonical_key = canonical, updated_at = ts, by = state.me }
  doc.updated_at = ts
  return store:write_aliases(root, state.me, doc)
end

-- ============================================================
-- VM.save_hide / VM.hidden_rows — 「非表示」（全員の一覧から消す）
-- ============================================================

--- 自分の hides/<id>.json へ1件書く。hidden=true で検索タブの一覧から消え、
-- hidden=false（整備タブの「リストに復帰」）で戻る。どちらも新しい更新日時で書くので、
-- 全員分を合わせたとき（tpc_matcher.merge_hides）に最後の操作が勝つ。
-- 「使えない」印（△）とは別物: あちらは行が残って印が付くだけ、こちらは行ごと消える。
-- @return ok, err
function M.save_hide(state, key, hidden, store, root, now_iso)
  if not state or not state.me then return false, "メンバーIDが未設定" end
  if not key or key == "" then return false, "キーが空" end

  local doc = nil
  for _, d in ipairs(store:read_hides(root)) do
    if d.member_id == state.me then doc = d; break end
  end
  doc = doc or { schema = Store.SCHEMA, member_id = state.me, entries = {} }
  if type(doc.entries) ~= "table" then doc.entries = {} end
  doc.schema = doc.schema or Store.SCHEMA
  doc.member_id = state.me
  local ts = now_iso or state.now_iso
  doc.entries[key] = { hidden = (hidden == true), updated_at = ts, by = state.me }
  doc.updated_at = ts
  return store:write_hides(root, state.me, doc)
end

--- 整備タブ(4)に出す「今こうして消えているもの」の並び。
-- @return { {key, name, vendor, by, by_display, updated_at, date, holders}, ... }（名前順）
-- holders は「誰が持っているか」（表示名の並び）。索引から消えている（全員が持たなく
-- なった、または別の行へまとめられた）キーは、名前の代わりにキーをそのまま出す。
function M.hidden_rows(state)
  local out = {}
  for key, rec in pairs(state and state.hides or {}) do
    local e = state.index and state.index[key]
    local holders = {}
    local by_display = rec.by
    for _, m in ipairs(state.members or {}) do
      if e and e.by and e.by[m.id] then holders[#holders + 1] = m.display_name or m.id end
      if m.id == rec.by then by_display = m.display_name or m.id end
    end
    local ts = rec.updated_at or ""
    out[#out + 1] = {
      key = key,
      name = (e and e.name) or key,
      vendor = (e and e.vendor) or "",
      in_index = (e ~= nil),
      by = rec.by,
      by_display = by_display or rec.by or "?",
      updated_at = rec.updated_at,
      date = ts:sub(1, 10),
      holders = holders,
    }
  end
  table.sort(out, function(a, b)
    local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
    if an ~= bn then return an < bn end
    return a.key < b.key
  end)
  return out
end

-- ============================================================
-- VM.ai_url — 「リンクを探す」で開くURL
-- ============================================================

function M.ai_question(name, vendor)
  return ("「%s」（%s）というオーディオプラグインの公式ダウンロードページURLと、無料かどうかを教えてください。URLだけ1行で。")
    :format(tostring(name or ""), tostring(vendor or ""))
end

function M.ai_url(choice, name, vendor)
  local base = AI_BASE[choice] or AI_BASE.chatgpt
  return base .. M.percent_encode(M.ai_question(name, vendor))
end

-- ============================================================
-- VM.insert_candidates — TrackFX_AddByName に渡す名前の候補（試す順）
-- ============================================================

function M.insert_candidates(row)
  local out, seen = {}, {}
  local function push(s)
    if type(s) == "string" and s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end
  end

  local formats = {}
  for _, p in ipairs(row and row.mine or {}) do
    for _, f in ipairs(p.formats or {}) do formats[#formats + 1] = f end
  end
  table.sort(formats, function(a, b)
    local ra, rb = FORMAT_RANK[a.fmt] or 99, FORMAT_RANK[b.fmt] or 99
    if ra ~= rb then return ra < rb end
    return (a.raw_name or "") < (b.raw_name or "")
  end)

  for _, f in ipairs(formats) do
    if f.raw_name then
      push(f.raw_name)                      -- "VST3: Pro-Q 4 (FabFilter)"
      push(strip_fx_prefix(f.raw_name))     -- "Pro-Q 4 (FabFilter)"
    end
    push(f.ident)                           -- フルパス／逆DNS／AUの "Vendor: Name"
  end
  if #out > 0 then return out end

  -- 予備の道: 自分のメンバーファイル側の項目（row.mine）と結び付かなかった行。
  -- 畳み込みでキーが書き換わると起こり得る。索引側に残っている「自分の記録」
  -- （形式と識別子）と、その行の生の名前から候補を作り直す。○が出ているのに
  -- 「自分は持っていません」で終わらせないため。
  local mi = row and row.mine_index
  if not mi then return out end

  local raws = row.raw_names or {}
  for _, fmt in ipairs(sorted_formats(mi.formats)) do
    for _, rn in ipairs(raws) do
      if fmt_of_raw_name(rn) == fmt then
        push(rn)
        push(strip_fx_prefix(rn))
      end
    end
  end
  for _, idn in ipairs(mi.idents or {}) do push(idn) end
  for _, rn in ipairs(raws) do
    push(rn)
    push(strip_fx_prefix(rn))
  end
  return out
end

--- ident から「場所を開く」ボタン用のパスを取り出す（VST/VST3/CLAPの実体パスのみ）。
-- @return path|nil, kind ("path"|"text"|"unknown")
function M.locate_path(ident)
  local kind, value = ident_kind(ident)
  if kind == "path" then return value, kind end
  return nil, kind
end

return M
