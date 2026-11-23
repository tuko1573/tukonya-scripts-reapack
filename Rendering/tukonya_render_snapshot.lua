--[[
  tukonya_render_snapshot.lua  （TUKONYA RENDER v2.10.0）
  ===========================================================================
  書き出しのあとに SWS スナップショットを1つ作り、名前を付ける。

  SWS には「名前を付けて作る」道具が無い（新規は「ミックス N」で固定。名前を尋ねる設定のときだけ窓が出る）。
  クリップボードの貼り付けは毎回、合流の窓が出る（SWS Snapshots/SnapshotMerge.cpp）ので使わない。
  使うのは SWS 自身のアクション「SWS: New snapshot and edit name」（SWSSNAPSHOT_NEWEDIT）と、
  そのあとに出る一覧の名前欄（編集欄）。js_ReaScriptAPI でその欄に名前を入れ、SWS の確定の合図
  （窓への WM_TIMER 0x1000。SWS が欄の編集を終えるときに自分で回しているタイマー）を1回送って確定させる。
  （先例: https://github.com/reaper-oss/sws/blob/master/Snapshots/Snapshots.cpp の NewSnapshotEdit、
   sws_wnd.cpp の SWS_ListView::EditListItem / EditListItemEnd / OnEditingTimer。2026-11-21 に MacBook Pro の
   REAPER 7.83 + SWS 2.14.0.7 + js_ReaScriptAPI 1.31 で、名前が .RPP の <SWSSNAPSHOT "…"> に入ることを確かめた。）

  ここでやらないこと
   ・SWS の設定は触らない。「名前を尋ねる」がオン、または分からないときは作らない（名前の窓が出ると
     REAPER 全体が止まるため。2026-11-21 の実測で NEWALL でも止まった）。
   ・「選択トラックのみ保存」がオンのときも作らない（全トラックのスナップショットにならないため）。
   ・作ったかどうか分からないときに作り直さない（同じ物が増えるため）。
  reaper.* は引数 api で受け取る（既定は本物の reaper）。素のLuaでも試験できる。
  ===========================================================================
--]]

local M = {}

-- SWS の Snapshots 窓の部品の番号（resource.h の IDC_LIST / IDC_EDIT / IDC_NAMEPROMPT / IDC_SELECTEDONLY_SAVE）。
-- 実機の窓から読んだ値: 一覧 0x447、編集欄 0x448、「名前を尋ねる」0x45b、「選択トラックのみ保存」0x45c。
M.ID_LIST, M.ID_EDIT, M.ID_PROMPT, M.ID_SELONLY = 0x447, 0x448, 0x45b, 0x45c
M.DEFAULT_OPTIONS = "559 0 0 0 1 0 0 0 0 1"   -- SWS が ini に無いときの既定（Snapshots.cpp）

local function api_of(api) return api or reaper end

-- reaper.ini の「Snapshot Options」（数を空白で並べた物）。第4が「名前を尋ねる」、第6が「選択トラックのみ保存」。
-- 戻り値: { prompt = bool, selonly = bool } / nil, 理由
function M.parse_options(str)
  local t = {}
  for x in tostring(str or ""):gmatch("%-?%d+") do t[#t + 1] = tonumber(x) end
  if #t < 6 then return nil, "SWS の設定（Snapshot Options）を読み取れませんでした" end
  return { prompt = t[4] ~= 0, selonly = t[6] ~= 0 }
end

-- ini から読む。SWS が書くのは窓を閉じたときだけなので、窓が開いているときは窓の値のほうが新しい（下で上書きする）。
function M.read_options(api)
  api = api_of(api)
  local str
  if api.get_ini_file then
    local ini = api.get_ini_file()
    if api.BR_Win32_GetPrivateProfileString then
      local _, v = api.BR_Win32_GetPrivateProfileString("SWS", "Snapshot Options", "<none>", ini)
      if type(v) == "string" and v ~= "<none>" then str = v end
      if v == "<none>" then str = M.DEFAULT_OPTIONS end
    else
      local f = io.open(ini, "rb")
      if f then
        local text = f:read("*a") or ""
        f:close()
        str = text:match("\nSnapshot Options=([^\r\n]*)") or M.DEFAULT_OPTIONS
      end
    end
  end
  if not str then return nil, "reaper.ini を読めませんでした" end
  return M.parse_options(str)
end

local function has_js(api)
  return api.JS_Window_FindChildByID and api.JS_Window_ListAllTop and api.JS_Window_SetTitle
     and api.JS_WindowMessage_Send and api.JS_ListView_GetItemCount and api.JS_ListView_GetItemText
     and api.JS_Window_HandleFromAddress and api.JS_Window_GetClassName and api.JS_Window_GetTitle
     and api.JS_Window_IsVisible and api.JS_Window_GetFocus and api.JS_Window_SetFocus
end

-- Snapshots の窓（一覧と編集欄を持つ窓）を探す。戻り値: 窓, 一覧, 編集欄 / nil
-- 浮いている窓 → メイン窓の中（ドック）の順。部品の番号と種類（SysListView32 と Edit）が合う物だけ。
function M.find_dialog(api)
  api = api_of(api)
  local function try(h)
    local lv = api.JS_Window_FindChildByID(h, M.ID_LIST)
    local ed = api.JS_Window_FindChildByID(h, M.ID_EDIT)
    if lv and ed and api.JS_Window_GetClassName(lv) == "SysListView32" and api.JS_Window_GetClassName(ed) == "Edit" then
      return h, lv, ed
    end
  end
  local _, top = api.JS_Window_ListAllTop()
  for a in tostring(top or ""):gmatch("[^,]+") do
    local h = api.JS_Window_HandleFromAddress(tonumber(a))
    if h then
      local w, lv, ed = try(h)
      if w then return w, lv, ed end
    end
  end
  -- ドックの中: メイン窓の子をたどり、一覧と編集欄を見つける
  if api.GetMainHwnd and api.JS_Window_ListAllChild and api.JS_Window_GetParent then
    local _, kids = api.JS_Window_ListAllChild(api.GetMainHwnd())
    local lvf, edf
    for a in tostring(kids or ""):gmatch("[^,]+") do
      local h = api.JS_Window_HandleFromAddress(tonumber(a))
      if h then
        local cls = api.JS_Window_GetClassName(h)
        local id = tostring(api.JS_Window_GetLongPtr and api.JS_Window_GetLongPtr(h, "ID") or "")
        if cls == "SysListView32" and id:find("447", 1, true) then lvf = h end
        if cls == "Edit" and id:find("448", 1, true) then edf = h end
      end
    end
    if lvf and edf then
      local w = api.JS_Window_GetParent(lvf)
      if w then
        local w2, lv, ed = try(w)
        if w2 then return w2, lv, ed end
      end
    end
  end
  return nil
end

-- 一覧の名前の列（2列目）を全部読む
local function list_names(api, lv)
  local t = {}
  for i = 0, (api.JS_ListView_GetItemCount(lv) or 0) - 1 do
    local txt = api.JS_ListView_GetItemText(lv, i, 1, "")
    t[#t + 1] = tostring(txt or "")
  end
  return t
end

-- 窓が開いているときの「名前を尋ねる」「選択トラックのみ保存」（窓の値のほうが ini より新しい）
local function live_checks(api, w)
  local function chk(id)
    local b = api.JS_Window_FindChildByID(w, id)
    if not b then return nil end
    local r = api.JS_WindowMessage_Send(b, "BM_GETCHECK", 0, 0, 0, 0)
    if r == nil then return nil end
    return tonumber(r) == 1
  end
  return chk(M.ID_PROMPT), chk(M.ID_SELONLY)
end

-- スナップショットを1つ作って名前を付ける。
-- 戻り値の表 res:
--   res.state  = "named"（名前を付けた）/ "skipped"（作っていない）/ "unverified"（作ったが名前を確かめきれない）
--   res.name   = 付けた名前（named のとき）
--   res.reason = 理由（skipped / unverified のとき。つこさんが読む短い文）
-- opts.verify_copy = 試験用。フォルダを渡すと、プロジェクトの写しをそこへ保存して名前を読み直す（本番は使わない）
function M.create(name, api, opts)
  api = api_of(api)
  opts = opts or {}
  local function skip(why) return { state = "skipped", reason = why } end
  if not (api.NamedCommandLookup and api.Main_OnCommand and api.GetToggleCommandState) then
    return skip("REAPER の機能を使えませんでした")
  end
  local NEWEDIT = api.NamedCommandLookup("_SWSSNAPSHOT_NEWEDIT")
  local OPEN = api.NamedCommandLookup("_SWSSNAPSHOT_OPEN")
  if not NEWEDIT or NEWEDIT == 0 or not OPEN or OPEN == 0 then
    return skip("SWS が入っていないため")
  end
  if not has_js(api) then
    return skip("拡張 js_ReaScriptAPI が入っていないため")
  end
  local opt, oerr = M.read_options(api)
  if not opt then return skip(oerr or "SWS の設定を読めないため") end
  local was_open = (api.GetToggleCommandState(OPEN) == 1)
  local w0, lv0
  if was_open then
    w0, lv0 = M.find_dialog(api)
    if w0 then
      local p, s = live_checks(api, w0)
      if p ~= nil then opt.prompt = p end
      if s ~= nil then opt.selonly = s end
    else
      return skip("SWS の窓が開いているのに中を読めなかったため")
    end
  end
  if opt.prompt then return skip("SWS の「名前を尋ねる」がオンのため（名前の窓で止まってしまうので作りません）") end
  if opt.selonly then return skip("SWS の「選択トラックのみ保存」がオンのため（全トラックにならないので作りません）") end
  local count_before = lv0 and api.JS_ListView_GetItemCount(lv0) or nil
  local names0 = lv0 and list_names(api, lv0) or nil   -- 作る前の一覧（窓が開いていたときだけ読める）

  -- ここから先は、作ったかどうか分からなくなっても作り直さない
  api.Main_OnCommand(NEWEDIT, 0)
  -- 同じ呼び出しの流れのうちに名前を入れて確定する（SWS 自身の確定タイマー 50ms が回る前に）
  local w, lv, ed = M.find_dialog(api)
  local function restore()
    if not was_open and api.GetToggleCommandState(OPEN) == 1 then api.Main_OnCommand(OPEN, 0) end
  end
  -- 名前を確かめきれなかったとき、増えた行の実際の名前（「Mix 7」など）を探す。見つからなければ nil。
  -- ①作る前の一覧があれば、増えた1行 ②無ければ、名前欄に最初に入っていた名前（＝新しい行の既定名）が一覧にちょうど1つあればそれ
  local function find_actual(after, initial)
    if names0 then
      local cnt = {}
      for _, n in ipairs(names0) do cnt[n] = (cnt[n] or 0) + 1 end
      local extra = {}
      for _, n in ipairs(after) do
        if (cnt[n] or 0) > 0 then cnt[n] = cnt[n] - 1 else extra[#extra + 1] = n end
      end
      if #extra == 1 then return extra[1] end
      return nil
    end
    if initial and initial ~= "" then
      local hits = 0
      for _, n in ipairs(after) do if n == initial then hits = hits + 1 end end
      if hits == 1 then return initial end
    end
    return nil
  end
  if not w then
    restore()
    return { state = "unverified", reason = "作りましたが、SWS の名前欄が見つからず名前を付けられませんでした（SWS の一覧で確かめてください）" }
  end
  local before = list_names(api, lv)
  local initial = api.JS_Window_GetTitle(ed)
  if not api.JS_Window_IsVisible(ed) then
    local actual = find_actual(before, nil)
    restore()
    return { state = "unverified", want = name, actual = actual,
      reason = "作りましたが、名前欄が開いておらず名前を付けられませんでした（SWS の一覧で確かめてください）" }
  end
  api.JS_Window_SetTitle(ed, name)
  local f = api.JS_Window_GetFocus()
  if f and (f == ed or (api.JS_Window_IsChild and api.JS_Window_IsChild(ed, f))) then
    api.JS_Window_SetFocus(lv)   -- 欄にフォーカスがあると SWS は確定しない（フォーカスが外れたら確定する決まり）
  end
  api.JS_WindowMessage_Send(w, "WM_TIMER", 0x1000, 0, 0, 0)
  local hidden = not api.JS_Window_IsVisible(ed)
  local after = list_names(api, lv)

  -- 確かめる: 欄が閉じた／行数が同じ／変わった行がちょうど1つで、それが入れた名前／（窓が最初から開いていたなら）行が1つ増えた
  local changed, only_ok = 0, (#before == #after)
  if only_ok then
    for i = 1, #after do
      if after[i] ~= before[i] then
        changed = changed + 1
        if after[i] ~= name then only_ok = false end
      end
    end
  end
  local grew_ok = (count_before == nil) or (#before == count_before + 1)
  local ok = hidden and only_ok and changed == 1 and grew_ok
  local verified_copy
  if opts.verify_copy then
    local p = opts.verify_copy .. "/snapshot_verify.RPP"
    api.Main_SaveProjectEx(0, p, 0)
    local fh = io.open(p, "rb")
    local text = fh and fh:read("*a") or ""
    if fh then fh:close() end
    local names = {}
    for nm in text:gmatch('<SWSSNAPSHOT "([^"]*)"') do names[#names + 1] = nm end
    verified_copy = names
  end
  restore()
  if not ok then
    local why = "作りましたが、名前が付いたことを確かめきれませんでした（SWS の一覧で確かめてください）"
    return { state = "unverified", reason = why, verified_copy = verified_copy, initial = initial,
      want = name, actual = find_actual(after, initial) }
  end
  return { state = "named", name = name, verified_copy = verified_copy, initial = initial }
end

-- 完了画面と実行記録に出す1行
function M.line(res, label_name)
  if not res then return nil end
  if res.state == "named" then
    return "SWS スナップショット: " .. tostring(res.name)
  elseif res.state == "unverified" then
    -- 名前は付けられなかったが、増えた行が分かるときは「Mix 7 ＝ mix2_03」と対応を出す
    if res.actual and res.want then
      if res.actual == res.want then return "SWS スナップショット: " .. tostring(res.want) end
      return ("SWS スナップショット: %s ＝ %s"):format(tostring(res.actual), tostring(res.want))
    end
    return "SWS スナップショット: " .. tostring(res.reason)
  end
  return "SWS スナップショットは作っていません（" .. tostring(res.reason) .. "）"
end

return M
