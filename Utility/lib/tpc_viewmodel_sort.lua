--[[
  tpc_viewmodel_sort.lua
  Team Plugin Checker — tpc_viewmodel の一部。純Lua。
  検索タブの表で、列見出し（名前・メーカー）をクリックしたときの並び替えだけを持つ。
  tpc_viewmodel.lua が require して VM.rows の最後に通すので、呼び出し側は
  tpc_viewmodel だけ見ればよい（1ファイル400行未満に保つための分割）。

--]]

local M = {}

--- 列見出しクリックでの並び替え（検索タブの表）。sort.column が無ければ何もしない
-- （＝Matcher.searchの関連度順のまま。既定の並びはここを一切通らない）。
-- 大文字小文字を無視し、同点は表示名（名前で並べているときはメーカー、
-- メーカーで並べているときは名前）を次のタイブレークにし、それでも同点なら
-- 元の並び順（table.sortが不安定なため、並べ替え前の位置を最後の決め手にする）。
--- @param rows 画面に出す行の並び（VM.rows が組み立てた形。row.name / row.vendor を使う）
-- @param sort {column="name"|"vendor", descending=bool}｜nil
function M.apply_sort(rows, sort)
  if not (sort and sort.column) then return rows end
  local by_name = (sort.column == "name")
  local indexed = {}
  for i, row in ipairs(rows) do
    indexed[i] = { row = row, idx = i }
  end
  table.sort(indexed, function(a, b)
    local a_key = ((by_name and a.row.name or a.row.vendor) or ""):lower()
    local b_key = ((by_name and b.row.name or b.row.vendor) or ""):lower()
    if a_key ~= b_key then
      if sort.descending then return a_key > b_key end
      return a_key < b_key
    end
    local a_tie = ((by_name and a.row.vendor or a.row.name) or ""):lower()
    local b_tie = ((by_name and b.row.vendor or b.row.name) or ""):lower()
    if a_tie ~= b_tie then
      if sort.descending then return a_tie > b_tie end
      return a_tie < b_tie
    end
    return a.idx < b.idx -- 完全な同点は元の順を保つ（安定ソート代わり）
  end)
  local out = {}
  for i, item in ipairs(indexed) do out[i] = item.row end
  return out
end

return M
