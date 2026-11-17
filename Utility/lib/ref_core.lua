--[[
  ref_core.lua
  TUKONYA Reference — ルーター探し・切替・初期設定の中身。
  REAPER を直接は呼ばない。`r`（= reaper テーブル、試験では偽物）を引数で受け取る。
  素の Lua で試験できる（tests/test_all.lua）。SWS・js_ReaScriptAPI は使わない。

  チャンネルの組（pair）の数え方: k = 1 が 3/4、k = 2 が 5/6 ... （k = 0 は 1/2 でリファレンスには使わない）。
  1つの番号 k を両側で使う:
    ・マスターのチャンネル 2k+1 / 2k+2 にリファレンスが載る（トラックの C_MAINSEND_OFFS = 2k）
    ・マスターのハードウェア出力 I_SRCCHAN = 2k → I_DSTCHAN = 2k
    ・ルーターの入力 = k、Eater の組 = k
  （モニタリングFXが見るのはデバイス出力側のチャンネルなので、この対応が要る。tests と 記録.md の MBP 実測を参照。）
--]]

local tx = require("ref_text")

local M = {}

M.MON = 0x1000000                       -- モニタリングFX（マスターの録音入力FX扱い）の番号の下駄
M.IDENT = "phaseadjustingrouter"        -- fx_ident に含まれる語（小文字で比べる）
M.NAME_FALLBACK = "channel router"      -- fx_ident が取れないときだけ名前で探す（小文字）
M.EATER_KEY = "referencetrackeater"     -- Eater の fx_ident / 名前（小文字・空白と _ を除く）に含まれる語
-- JSFX のスライダー番号 = TrackFX_GetParam の番号（0始まり）
M.P_IN, M.P_POL, M.P_OUT, M.P_MODE = 0, 1, 2, 3
M.WANT_OUT, M.WANT_MODE = 0, 0          -- 出力 1+2 / Replace
-- 入れるときに試す名前（大文字小文字を区別するOS向けに両方）
M.ADD_NAMES = { "JS: IX/PhaseAdjustingRouter", "JS: ix/PhaseAdjustingRouter" }
-- 名前で探せないとき（ReaPack で入れた直後で REAPER がまだ一覧を読み直していない等）は、入る場所のファイル名で入れる
M.EATER_NAMES = {
  "JS: TUKONYA Reference Track Eater",
  "JS: Tukonya Scripts/Utility/TUKONYA Reference Track Eater.jsfx",
  "JS: Tukonya Scripts/Utility/TUKONYA Reference Track Eater",
}

M.MAX_PAIR = 7          -- メニューは 3/4 .. 15/16 まで

M.TOGGLE_FILE = "TUKONYA_Reference Toggle.lua"
M.DISPLAY_FILE = "TUKONYA_Reference Display.lua"
M.SETUP_UNDO = "TUKONYA Reference: Setup"

local function round(v) return math.floor((tonumber(v) or 0) + 0.5) end

--- k → "3/4"
function M.pair_label(k) return (2 * k + 1) .. "/" .. (2 * k + 2) end
--- k → "3+4"（IX の表記）
local function pair_plus(k) return (2 * k + 1) .. "+" .. (2 * k + 2) end
M.pair_plus = pair_plus

-- ============================================================
-- ルーターの判定
-- ============================================================

--- 名前または fx_ident が IX のルーターか。
local function identity(r, master, idx)
  local ok, ident = r.TrackFX_GetNamedConfigParm(master, idx, "fx_ident")
  if ok and type(ident) == "string" and ident ~= "" then
    if ident:lower():find(M.IDENT, 1, true) then return "ident" end
    return nil
  end
  local _, name = r.TrackFX_GetFXName(master, idx, "")
  if type(name) == "string" and name:lower():find(M.NAME_FALLBACK, 1, true) then
    return "name"
  end
  return nil
end

-- 出力 1+2・Replace・入力が 1+2 以外 のものを「リファレンス用ルーター」とする（入力の組がリファレンスの組）
local function settings_ok(r, master, idx)
  return round((r.TrackFX_GetParam(master, idx, M.P_IN))) ~= 0
     and round((r.TrackFX_GetParam(master, idx, M.P_OUT))) == M.WANT_OUT
     and round((r.TrackFX_GetParam(master, idx, M.P_MODE))) == M.WANT_MODE
end

--- モニタリングチェーンの IX ルーターを先頭から探す。
-- @return matched_idx|nil（設定まで合うもの、最初の1つ）, others（設定違いの IX ルーターの番号の表）
function M.find_router(r)
  local master = r.GetMasterTrack(0)
  if not master then return nil, {} end
  local others = {}
  local n = r.TrackFX_GetRecCount(master) or 0
  for i = 0, n - 1 do
    local idx = M.MON + i
    if identity(r, master, idx) then
      if settings_ok(r, master, idx) then return idx, others end
      others[#others + 1] = idx
    end
  end
  return nil, others
end

--- ルーターの入力の組 k
function M.router_pair(r, idx)
  return round((r.TrackFX_GetParam(r.GetMasterTrack(0), idx, M.P_IN)))
end

--- ルーターの直後に Eater があればその番号
function M.find_eater(r, router_idx)
  local master = r.GetMasterTrack(0)
  local idx = router_idx + 1
  if idx - M.MON >= (r.TrackFX_GetRecCount(master) or 0) then return nil end
  local ok, ident = r.TrackFX_GetNamedConfigParm(master, idx, "fx_ident")
  local key = (ok and type(ident) == "string" and ident ~= "") and ident or select(2, r.TrackFX_GetFXName(master, idx, "")) or ""
  key = tostring(key):lower():gsub("[%s_]", "")
  if key:find(M.EATER_KEY, 1, true) then return idx end
  -- ident は取れたが別物のとき、名前でも見る
  local _, name = r.TrackFX_GetFXName(master, idx, "")
  if tostring(name):lower():gsub("[%s_]", ""):find(M.EATER_KEY, 1, true) then return idx end
  return nil
end

--- リファレンス聴取中か（ルーターが見つかり、かつ有効）
function M.is_reference_on(r)
  local idx = M.find_router(r)
  if not idx then return false end
  return r.TrackFX_GetEnabled(r.GetMasterTrack(0), idx) and true or false
end

-- ============================================================
-- 切替
-- ============================================================

--- ルーターの有効／バイパスを反転する。見つからなければ何も変えない。
-- @return ok, new_enabled_or_reason
function M.toggle(r)
  local idx = M.find_router(r)
  if not idx then return false, "no_router" end
  local master = r.GetMasterTrack(0)
  local new = not r.TrackFX_GetEnabled(master, idx)
  r.TrackFX_SetEnabled(master, idx, new)
  return true, new
end

-- ============================================================
-- 兄弟スクリプトの起動（Display を動かしておく）
-- ============================================================

--- Display が動いていなければ始める。
-- @return started(bool), cmd_id|nil
function M.ensure_display(r, dir)
  local p = dir .. "/" .. M.DISPLAY_FILE
  if r.file_exists and not r.file_exists(p) then return false, nil end
  local id = r.AddRemoveReaScript(true, 0, p, false)
  if not id or id <= 0 then return false, nil end
  if r.GetToggleCommandStateEx(0, id) == 1 then return false, id end
  r.Main_OnCommand(id, 0)
  return true, id
end

--- Toggle スクリプトのコマンド番号（Display が点灯を写す先）
function M.toggle_cmd(r, dir)
  local p = dir .. "/" .. M.TOGGLE_FILE
  local id = r.AddRemoveReaScript(true, 0, p, false)
  if id and id > 0 then return id end
  return nil
end

-- ============================================================
-- プロジェクトの準備状態（Toggle のヒントが使う）
-- ============================================================

--- マスターに「I_SRCCHAN == src」（ステレオ）のハードウェア出力があるか。モノ指定(1024ビット付き)は一致としない。
function M.has_hwout(r, src)
  local master = r.GetMasterTrack(0)
  for i = 0, (r.GetTrackNumSends(master, 1) or 0) - 1 do
    if round(r.GetTrackSendInfo_Value(master, 1, i, "I_SRCCHAN")) == src then return true end
  end
  return false
end

--- このプロジェクトがリファレンスを鳴らせる状態か。ルーターの実際の組 k で判定する
-- （マスター 2k+2 ch 以上、かつ I_SRCCHAN == 2k のハードウェア出力あり）。
-- @return ready, nch_ok, hw_ok, k, need_nch
function M.project_ready(r)
  local master = r.GetMasterTrack(0)
  local idx = M.find_router(r)
  if not idx then return false, false, false, nil, nil end
  local k = M.router_pair(r, idx)
  local need = 2 * k + 2
  local nch_ok = round(r.GetMediaTrackInfo_Value(master, "I_NCHAN")) >= need
  local hw_ok = M.has_hwout(r, 2 * k)
  return (nch_ok and hw_ok), nch_ok, hw_ok, k, need
end

--- Toggle で ON にしたときに出すヒントの文面（準備済みなら nil）
function M.hint_text(r)
  local ready, nch_ok, hw_ok, k, need = M.project_ready(r)
  if ready or not k then return nil end
  return tx.ja("HINT")
end

-- ============================================================
-- チャンネル選択メニュー（純粋関数 + 表示）
-- ============================================================

local function sel_of(r, tr) return round(r.GetMediaTrackInfo_Value(tr, "I_SELECTED")) ~= 0 end

-- ハードウェア出力のチャンネル指定を「開始, 本数」に
local function hw_span(v)
  v = round(v)
  if v >= 1024 then return v - 1024, 1 end
  return v, 2
end

local function overlaps(s0, n, lo, hi) return s0 <= hi and (s0 + n - 1) >= lo end

local function who_text(names)
  local shown = {}
  for i = 1, math.min(2, #names) do shown[i] = names[i] end
  local t = table.concat(shown, ", ")
  if #names > 2 then t = t .. " " .. tx.ja("MENU_MORE", #names - 2) end
  return t
end

--- 今のプロジェクトで各チャンネルの組が使われているかを調べる（何も変えない）。
-- @return model = { items = { {k, label, used, who = {...}, current} ... }, default = k, router_pair = k|nil }
function M.menu_model(r)
  local master = r.GetMasterTrack(0)
  local ridx = M.find_router(r)
  local cur = ridx and M.router_pair(r, ridx) or nil
  local items = {}
  local ntr = r.CountTracks(0) or 0
  local nsend = r.GetTrackNumSends(master, 1) or 0
  for k = 1, M.MAX_PAIR do
    local lo, hi = 2 * k, 2 * k + 1       -- 0始まりのチャンネル番号
    local who = {}
    for i = 0, ntr - 1 do
      local tr = r.GetTrack(0, i)
      if not r.GetParentTrack(tr) and not sel_of(r, tr) and round(r.GetMediaTrackInfo_Value(tr, "B_MAINSEND")) ~= 0 then
        local offs = round(r.GetMediaTrackInfo_Value(tr, "C_MAINSEND_OFFS"))
        local n = round(r.GetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH"))
        if n == 0 then n = math.max(2, round(r.GetMediaTrackInfo_Value(tr, "I_NCHAN"))) end
        if overlaps(offs, n, lo, hi) then
          local _, name = r.GetTrackName(tr, "")
          who[#who + 1] = name
        end
      end
    end
    for i = 0, nsend - 1 do
      local sv = round(r.GetTrackSendInfo_Value(master, 1, i, "I_SRCCHAN"))
      local dv = round(r.GetTrackSendInfo_Value(master, 1, i, "I_DSTCHAN"))
      local ours = (sv == lo and dv == lo)
      local s0, sn = hw_span(sv)
      local d0, dn = hw_span(dv)
      if not ours and (overlaps(s0, sn, lo, hi) or overlaps(d0, dn, lo, hi)) then
        who[#who + 1] = tx.ja("MENU_WHO_HWOUT")
      end
    end
    items[#items + 1] = { k = k, label = M.pair_label(k), used = #who > 0, who = who, current = (cur == k) }
  end
  local default
  for _, it in ipairs(items) do if not it.used then default = it.k; break end end
  return { items = items, default = default or 1, router_pair = cur }
end

--- gfx.showmenu に渡す文字列。メニューの番号 → k の対応も返す。
-- 見出し行は置かない（灰色の行を番号に数えるかで1つずれる恐れがあるため）。各行がそのまま 1..。
-- 「今開いているプロジェクトで判定」の説明は確認ダイアログに出す。
-- @return menu_string, map（menu index → k）
function M.menu_string(model)
  local parts, map = {}, {}
  for idx, it in ipairs(model.items) do
    local t = it.label
    if it.used then t = t .. "  " .. tx.ja("MENU_USED", who_text(it.who)) end
    if it.current then t = t .. "  " .. tx.ja("MENU_CURRENT") end
    if it.k == model.default then t = "!" .. t end
    parts[#parts + 1] = t
    map[idx] = it.k
  end
  return table.concat(parts, "|"), map
end

--- 実際に gfx.showmenu を出す（js_ReaScriptAPI 不要）。小さな窓をマウス位置に開いて閉じる。
-- @return menu index（キャンセルは 0）
function M.show_menu(r, gfx, str)
  local mx, my = r.GetMousePosition()
  gfx.init("TUKONYA Reference", 1, 1, 0, mx or 100, my or 100)
  gfx.x, gfx.y = 0, 0
  local c = gfx.showmenu(str)
  gfx.quit()
  return c or 0
end

-- ============================================================
-- 初期設定（Setup）
-- ============================================================

--- 選んだ組 k で何をするかを調べるだけ（プロジェクトもFXも変えない）。
function M.plan(r, k)
  local master = r.GetMasterTrack(0)
  local matched, others = M.find_router(r)
  local old_k = matched and M.router_pair(r, matched) or nil
  local nch = round(r.GetMediaTrackInfo_Value(master, "I_NCHAN"))
  local tracks, skipped, warn_nosend = {}, {}, {}
  local n_selected = 0
  for i = 0, (r.CountSelectedTracks(0) or 0) - 1 do
    local tr = r.GetSelectedTrack(0, i)
    local _, name = r.GetTrackName(tr, "")
    n_selected = n_selected + 1
    if r.GetParentTrack(tr) then
      skipped[#skipped + 1] = name      -- フォルダの子: 送り先がマスターでなく親になる
    else
      -- すでに この組（OFFS=2k、NCH=2）になっているトラックは、やることに数えない
      if round(r.GetMediaTrackInfo_Value(tr, "C_MAINSEND_OFFS")) ~= 2 * k or round(r.GetMediaTrackInfo_Value(tr, "C_MAINSEND_NCH")) ~= 2 then
        tracks[#tracks + 1] = { track = tr, name = name }
      end
      if round(r.GetMediaTrackInfo_Value(tr, "B_MAINSEND")) == 0 then warn_nosend[#warn_nosend + 1] = name end
    end
  end
  local p = {
    k = k,
    need_insert = (matched == nil),
    other_routers = others,
    old_k = old_k,
    need_repoint = (matched ~= nil and old_k ~= k),
    nch = nch,
    need_nch = 2 * k + 2,
    need_raise = nch < 2 * k + 2,
    need_hwout = not M.has_hwout(r, 2 * k),
    tracks = tracks,
    n_selected = n_selected,
    skipped = skipped,
    warn_nosend = warn_nosend,
    old_hwouts = {},
    old_tracks = {},
  }
  -- 付け替えのとき、古い組に残る物（自動では外さない。最後に知らせる）
  if p.need_repoint and old_k then
    local lo = 2 * old_k
    for i = 0, (r.GetTrackNumSends(master, 1) or 0) - 1 do
      if round(r.GetTrackSendInfo_Value(master, 1, i, "I_SRCCHAN")) == lo then p.old_hwouts[#p.old_hwouts + 1] = i end
    end
    for i = 0, (r.CountTracks(0) or 0) - 1 do
      local tr = r.GetTrack(0, i)
      if not r.GetParentTrack(tr) and not sel_of(r, tr) and round(r.GetMediaTrackInfo_Value(tr, "B_MAINSEND")) ~= 0
         and round(r.GetMediaTrackInfo_Value(tr, "C_MAINSEND_OFFS")) == lo then
        local _, name = r.GetTrackName(tr, "")
        p.old_tracks[#p.old_tracks + 1] = name
      end
    end
  end
  -- 付け替えのとき Eater が無ければ足す
  if matched and p.need_repoint then p.need_eater = (M.find_eater(r, matched) == nil) end
  return p
end

local function list(names)
  local t = {}
  for i, n in ipairs(names) do t[i] = "「" .. n .. "」" end
  return table.concat(t, ", ")
end

--- 確認ダイアログの文面
function M.confirm_text(p)
  local ja = {}
  local function add(id, ...) ja[#ja + 1] = tx.ja(id, ...) end
  local lbl, plus = M.pair_label(p.k), pair_plus(p.k)
  if p.need_insert then
    add("CONFIRM_INSERT")
    if #p.other_routers > 0 then add("CONFIRM_OTHER_ROUTER") end
  end
  if p.need_repoint then
    add("CONFIRM_REPOINT", pair_plus(p.old_k), plus)
    if p.need_eater then add("CONFIRM_ADD_EATER") end
  end
  if p.need_raise then add("CONFIRM_RAISE", p.nch, p.need_nch) end
  if p.need_hwout then add("CONFIRM_HWOUT", lbl, lbl) end
  if #p.tracks > 0 then
    local names = {}
    for i, t in ipairs(p.tracks) do names[i] = t.name end
    add("CONFIRM_TRACKS", list(names), lbl)
  end
  if #p.skipped > 0 then add("CONFIRM_SKIPPED", list(p.skipped)) end
  if #p.warn_nosend > 0 then add("CONFIRM_NOSEND", list(p.warn_nosend)) end
  if p.n_selected == 0 then add("CONFIRM_NOTRACK") end
  return tx.ja("CONFIRM_HEAD") .. "\n" .. table.concat(ja, "\n")
end

local function nothing_to_do(p)
  return (not p.need_insert) and (not p.need_repoint) and (not p.need_raise) and (not p.need_hwout) and #p.tracks == 0
end

-- ルーターを挿入して設定する。@return fx_idx|nil
local function add_router(r, master, k)
  local fx
  for _, name in ipairs(M.ADD_NAMES) do
    fx = r.TrackFX_AddByName(master, name, true, -1000)   -- -1000 = チェーンの先頭（1番目）
    if fx and fx >= 0 then break end
    fx = nil
  end
  if not fx then return nil end
  if fx < M.MON then fx = M.MON + fx end
  r.TrackFX_SetParam(master, fx, M.P_IN, k)
  r.TrackFX_SetParam(master, fx, M.P_POL, 0)
  r.TrackFX_SetParam(master, fx, M.P_OUT, M.WANT_OUT)
  r.TrackFX_SetParam(master, fx, M.P_MODE, M.WANT_MODE)
  r.TrackFX_SetEnabled(master, fx, false)
  return fx
end

-- Eater をルーターの直後に挿入して設定する。@return fx_idx|nil
local function add_eater(r, master, router_idx, k)
  local fx
  for _, name in ipairs(M.EATER_NAMES) do
    fx = r.TrackFX_AddByName(master, name, true, -1000 - (router_idx - M.MON + 1))
    if fx and fx >= 0 then break end
    fx = nil
  end
  if not fx then return nil end
  if fx < M.MON then fx = M.MON + fx end
  r.TrackFX_SetParam(master, fx, 0, k)
  r.TrackFX_SetEnabled(master, fx, true)
  return fx
end

--- 初期設定の本体。
-- opts.choose(menu_string, model) -> menu index（0 = キャンセル）。無ければ既定の組で進める。
-- 最初に確認を取り、OK のときだけ変更する。
-- @return result table
function M.setup(r, opts)
  opts = opts or {}
  local model = M.menu_model(r)
  local k = model.default
  if opts.choose then
    local str, map = M.menu_string(model)
    local c = opts.choose(str, model)
    k = map[c or 0]
    if not k then return { cancelled = true, chosen = nil } end
  end
  local p = M.plan(r, k)
  local res = { chosen = k, skipped = p.skipped, other_routers = p.other_routers }
  local lbl, plus = M.pair_label(k), pair_plus(k)

  if nothing_to_do(p) then
    res.nothing = true
    res.message = tx.ja("NOTHING_TO_DO")
    r.MB(res.message, tx.ja("TITLE_SETUP"), 0)
    return res
  end

  if r.MB(M.confirm_text(p), tx.ja("TITLE_SETUP"), 1) ~= 1 then
    res.cancelled = true
    return res
  end

  local master = r.GetMasterTrack(0)
  local nj = { tx.ja("DONE_HEAD") }
  local function note(id, ...) nj[#nj + 1] = tx.ja(id, ...) end
  r.Undo_BeginBlock2(0)

  local router_idx = M.find_router(r)
  if p.need_insert then
    local fx = add_router(r, master, k)
    if fx then
      router_idx = fx
      res.inserted = true
      if #p.other_routers > 0 then note("DONE_OTHER_ROUTER") end
      local ea = add_eater(r, master, fx, k)
      if ea then res.eater_added = true
      else res.eater_failed = true; note("DONE_EATER_FAIL") end
    else
      router_idx = nil
      res.insert_failed = true
      note("DONE_ROUTER_FAIL", plus)
    end
  elseif p.need_repoint and router_idx then
    r.TrackFX_SetParam(master, router_idx, M.P_IN, k)
    res.repointed = true
    note("DONE_REPOINT", pair_plus(p.old_k), plus)
    local ea = M.find_eater(r, router_idx)
    if ea then
      r.TrackFX_SetParam(master, ea, 0, k)
    else
      ea = add_eater(r, master, router_idx, k)
      if ea then res.eater_added = true
      else res.eater_failed = true; note("DONE_EATER_FAIL") end
    end
  end

  if p.need_raise then
    r.SetMediaTrackInfo_Value(master, "I_NCHAN", p.need_nch)
    res.raised = true
    note("DONE_RAISED", p.need_nch)
  end

  if p.need_hwout then
    local idx = r.CreateTrackSend(master, nil)
    if idx and idx >= 0 then
      r.SetTrackSendInfo_Value(master, 1, idx, "I_SRCCHAN", 2 * k)
      r.SetTrackSendInfo_Value(master, 1, idx, "I_DSTCHAN", 2 * k)
      res.hwout_created = true
      note("DONE_HWOUT", lbl, lbl)
    else
      res.hwout_failed = true
      note("DONE_HWOUT_FAIL", lbl, lbl)
    end
  end

  res.tracks_set = 0
  for _, t in ipairs(p.tracks) do
    r.SetMediaTrackInfo_Value(t.track, "C_MAINSEND_OFFS", 2 * k)
    r.SetMediaTrackInfo_Value(t.track, "C_MAINSEND_NCH", 2)
    res.tracks_set = res.tracks_set + 1
  end
  if res.tracks_set > 0 then note("DONE_TRACKS", res.tracks_set, lbl) end

  r.Undo_EndBlock2(0, M.SETUP_UNDO, -1)

  -- 古い組に残った物（自動では外さない）
  if p.need_repoint and (#p.old_hwouts > 0 or #p.old_tracks > 0) then
    local oldlbl = M.pair_label(p.old_k)
    nj[#nj + 1] = "\n" .. tx.ja("DONE_OLD_HEAD")
    if #p.old_hwouts > 0 then note("DONE_OLD_HWOUT", oldlbl, oldlbl) end
    for _, nm in ipairs(p.old_tracks) do note("DONE_OLD_TRACK", "「" .. nm .. "」", oldlbl) end
    res.old_hwouts, res.old_tracks = p.old_hwouts, p.old_tracks
  end

  -- Eater の無い構成（既存の一致ルーターのまま）では、その組の出力にリファレンスが出続ける
  if router_idx and not M.find_eater(r, router_idx) then
    local warn = res.eater_failed and tx.ja("DONE_OUT_WARN_FAIL", lbl) or tx.ja("DONE_OUT_WARN", lbl)
    nj[#nj + 1] = "\n" .. warn
    res.out_warn = true
  end
  nj[#nj + 1] = "\n" .. tx.ja("DONE_FX_NOTE")
  res.message = table.concat(nj, "\n")
  r.MB(res.message, tx.ja("TITLE_SETUP"), 0)
  return res
end

return M
