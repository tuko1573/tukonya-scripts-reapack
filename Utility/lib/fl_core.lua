--[[
  fl_core.lua — TUKONYA Folder Link / Folder Toggle の中身。

  REAPER は「編集画面（TCP）のフォルダ開閉」と「ミキサー（MCP）で子を隠す」を別々に覚える。
    TCP  : I_FOLDERCOMPACT（0=開く, 1=小さく, 2=完全に畳む）— API で読み書きできる
    MCP  : トラックチャンクの "BUSCOMP a b c d e" の 2番目（0=子を表示, 1=子を隠す）
           API 直読みは無い。読みはチャンク、書きはアクション 41665
           「Track: show/hide children of selected folder tracks in mixer」（トグル）か、
           SetTrackStateChunk。

  ここは REAPER を直接呼ばず、R（reaper テーブル相当）を注入して使う。素の Lua で試験できる。
--]]

local M = {}

M.ACT_MIXER_TOGGLE_CHILDREN = 41665

-- ============================================================
-- チャンクの読み書き（純粋関数）
-- ============================================================

--- チャンク文字列から BUSCOMP 行の 2番目（ミキサーで子を隠す=1）を返す。無ければ nil。
function M.parse_mixer_hidden(chunk)
  if type(chunk) ~= "string" then return nil end
  local a, b = chunk:match("\nBUSCOMP%s+(%-?%d+)%s+(%-?%d+)")
  if not a then a, b = chunk:match("^BUSCOMP%s+(%-?%d+)%s+(%-?%d+)") end
  if not b then return nil end
  return tonumber(b)
end

--- BUSCOMP 行の 2番目を hidden(0/1) に書き換えたチャンクを返す。行が無ければ元のまま＋false。
function M.set_mixer_hidden_in_chunk(chunk, hidden)
  local v = hidden and 1 or 0
  local n
  local out = chunk:gsub("(\nBUSCOMP%s+%-?%d+%s+)(%-?%d+)", function(head, _)
    n = (n or 0) + 1
    return head .. tostring(v)
  end, 1)
  return out, (n or 0) > 0
end

-- ============================================================
-- 対象フォルダの解決
-- ============================================================

--- 選択トラックから対象フォルダ親を集める（子が選ばれていれば親、重複は 1 つ）。
-- @return { track, ... }（プロジェクト順）
function M.resolve_targets(R, proj)
  proj = proj or 0
  local seen, list = {}, {}
  local n = R.CountSelectedTracks(proj)
  for i = 0, n - 1 do
    local tr = R.GetSelectedTrack(proj, i)
    local depth = R.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    local target = tr
    if depth ~= 1 then target = R.GetParentTrack(tr) end
    if target then
      local guid = R.GetTrackGUID(target)
      if not seen[guid] then
        seen[guid] = true
        list[#list + 1] = target
      end
    end
  end
  -- プロジェクト順に並べる（見た目と Undo の並びを安定させる）
  table.sort(list, function(a, b)
    return R.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") < R.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
  end)
  return list
end

--- 全フォルダ親を列挙する。
function M.all_folders(R, proj)
  proj = proj or 0
  local list = {}
  local n = R.CountTracks(proj)
  for i = 0, n - 1 do
    local tr = R.GetTrack(proj, i)
    if R.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      list[#list + 1] = tr
    end
  end
  return list
end

-- ============================================================
-- ミキサー側の読み書き
-- ============================================================

function M.get_mixer_hidden(R, tr)
  local ok, chunk = R.GetTrackStateChunk(tr, "", false)
  if not ok then return nil end
  return M.parse_mixer_hidden(chunk)
end

--- ミキサーで子を隠す／表示する。
-- mode = "action"（41665 を使う。既定）| "chunk"（SetTrackStateChunk, isundo=false）
-- @return changed(bool)
function M.set_mixer_hidden(R, tr, hidden, mode)
  local cur = M.get_mixer_hidden(R, tr)
  local want = hidden and 1 or 0
  if cur == nil or cur == want then return false end
  mode = mode or "action"
  if mode == "chunk" then
    local ok, chunk = R.GetTrackStateChunk(tr, "", false)
    if not ok then return false end
    local out, found = M.set_mixer_hidden_in_chunk(chunk, hidden)
    if not found then return false end
    R.SetTrackStateChunk(tr, out, false)
    return true
  end
  -- アクション経路: そのフォルダだけを選択して 41665 → 選択を戻す
  local proj = 0
  local saved = {}
  local n = R.CountSelectedTracks(proj)
  for i = 0, n - 1 do saved[#saved + 1] = R.GetSelectedTrack(proj, i) end
  R.PreventUIRefresh(1)
  R.SetOnlyTrackSelected(tr)
  R.Main_OnCommand(M.ACT_MIXER_TOGGLE_CHILDREN, 0)
  -- 選択を戻す
  local all = R.CountTracks(proj)
  for i = 0, all - 1 do R.SetTrackSelected(R.GetTrack(proj, i), false) end
  for _, t in ipairs(saved) do R.SetTrackSelected(t, true) end
  R.PreventUIRefresh(-1)
  return true
end

-- ============================================================
-- 開閉の本体
-- ============================================================

--- フォルダ 1 つを「閉じる」か「開く」かに揃える。
-- opts.close_level : 閉じるときの I_FOLDERCOMPACT（既定 2）
-- opts.mixer_mode  : "action" | "chunk"
function M.apply(R, tr, close, opts)
  opts = opts or {}
  local level = close and (opts.close_level or 2) or 0
  R.SetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT", level)
  M.set_mixer_hidden(R, tr, close, opts.mixer_mode)
end

--- 選択トラックのフォルダをまとめて反転する（編集画面側を正とする）。
-- 1 つでも開いているフォルダがあれば「全部閉じる」、全部閉じていれば「全部開く」。
-- @return targets, closed(bool)
function M.toggle_selected(R, opts)
  local targets = M.resolve_targets(R, 0)
  if #targets == 0 then return targets, nil end
  local any_open = false
  for _, tr in ipairs(targets) do
    if R.GetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT") == 0 then any_open = true; break end
  end
  local close = any_open
  for _, tr in ipairs(targets) do M.apply(R, tr, close, opts) end
  return targets, close
end

-- ============================================================
-- 常駐の追従（両方向。動いた側に合わせる）
-- ============================================================

--- 追従の状態を作る。last[guid] = { tcp = I_FOLDERCOMPACT, mix = BUSCOMP 2番目 }
function M.new_watch_state()
  return { last = {}, proj = nil }
end

--- 1 周期ぶんの追従。
--   初めて見たフォルダ（プロジェクトを開いた直後・新しいフォルダ）: 編集画面に合わせてミキサーを揃える
--   編集画面が動いた : ミキサーを合わせる（両方同時に動いたときも編集画面を正とする）
--   ミキサーが動いた : 編集画面を合わせる（閉じる=close_level, 開く=0）
-- ミキサー側の読み（チャンク読み）は重いプラグインがあると数 ms かかるので、
-- プロジェクトの変更回数（GetProjectStateChangeCount）が動いたときだけ読み直す。
-- ミキサーのアイコンを押すと Undo 点が付き、この回数が上がる。
-- opts.hide_from_level : この値以上の I_FOLDERCOMPACT で「隠す」（既定 1）
-- opts.close_level     : ミキサーで閉じたときの編集画面の畳み方（既定 2）
-- @return changed_count
function M.watch_tick(R, st, opts)
  opts = opts or {}
  local from = opts.hide_from_level or 1
  -- 閉じた結果が「隠す」に届かないと、次の周期でミキサーを開け直してしまう
  local close_level = math.max(opts.close_level or 2, from)
  local proj = R.EnumProjects(-1)
  if st.proj ~= proj then
    st.proj = proj
    st.last = {}
    st.scc = nil
  end
  local scc = R.GetProjectStateChangeCount and R.GetProjectStateChangeCount(proj) or nil
  local reread = scc == nil or scc ~= st.scc
  st.scc = scc
  local changed = 0
  local seen = {}
  for _, tr in ipairs(M.all_folders(R, 0)) do
    local guid = R.GetTrackGUID(tr)
    seen[guid] = true
    local lv = R.GetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT")
    local prev = st.last[guid]
    local mix
    if reread or prev == nil then mix = M.get_mixer_hidden(R, tr) else mix = prev.mix end
    if mix ~= nil then
      local tcp_hidden, mix_hidden = lv >= from, mix == 1
      local mixer_moved = prev ~= nil and prev.mix ~= nil and prev.mix ~= mix
      local tcp_moved = prev ~= nil and prev.tcp ~= lv
      if tcp_hidden ~= mix_hidden then
        if mixer_moved and not tcp_moved then
          lv = mix_hidden and close_level or 0
          R.SetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT", lv)
          changed = changed + 1
        elseif M.set_mixer_hidden(R, tr, tcp_hidden, opts.mixer_mode) then
          mix = tcp_hidden and 1 or 0
          changed = changed + 1
        end
      end
    end
    st.last[guid] = { tcp = lv, mix = mix }
  end
  for guid in pairs(st.last) do
    if not seen[guid] then st.last[guid] = nil end
  end
  return changed
end

return M
