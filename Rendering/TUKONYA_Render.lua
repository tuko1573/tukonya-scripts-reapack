--[[
  TUKONYA_Render.lua  （TUKONYA RENDER / Phase 2）
  ===========================================================================
  書き出しの設定窓（ReaImGui）。REAPERのアクションに登録して開く。

  Phase 3 で4タブとも動くようになった
  （2mix Render / 2mix Preview / Para + 2mix / Hardware Print）。

  このファイルがやるのは「描くこと」だけ。何を出すか・どう書き出すかは
  tukonya_render_model.lua が持っている（窓を開かなくても試験できるように分けてある）。

  下調べ（2026-09-20 MacBook Pro / REAPER 7.80 / ReaImGui 0.10.0.5）で分かったこと:
    ・描画の途中（Begin〜End のあいだ）で書き出し（42230）を呼ぶと、窓は即座に壊れる。
    ・次の defer の頭（描き始める前）で呼べば壊れない。11フレーム描き続けられた。
  そのため「書き出し」ボタンは予約だけして、実際の書き出しは次のフレームの頭で始める。
  それでも壊れていたら、窓を作り直して続ける。
  ===========================================================================
--]]

local SCRIPT_DIR = (debug.getinfo(1, "S").source:match("@(.*[/\\])") or "")
local Model = dofile(SCRIPT_DIR .. "tukonya_render_model.lua")
local S     = Model.S
local Store = Model.Store

local VERSION = "2.2.2"            -- 配布物の版。窓の見出しに出る
local NAME    = "TUKONYA RENDER"
local TITLE   = NAME .. "  v" .. VERSION   -- 窓の見出し（ImGuiの窓の名前でもある）
local NS      = "TUKONYA_RENDER"
Model.SCRIPT_VERSION = VERSION   -- 構成の資料に書く版

-- ===========================================================================
-- ReaImGui の確認（無い・古い場合は日本語で案内して終わる）
-- ===========================================================================
local function need_reaimgui(extra)
  reaper.MB(
    "ReaImGui（REAPERの中に窓を描く拡張）の 0.10 以降が必要です。\n\n" ..
    "REAPER の Extensions → ReaPack → Browse packages から「ReaImGui」を入れて、\n" ..
    "REAPER を再起動してからもう一度開いてください。" ..
    (extra and ("\n\n（内訳: " .. tostring(extra) .. "）") or ""),
    NAME, 0)
end

if not reaper.ImGui_GetBuiltinPath then need_reaimgui("ImGui_GetBuiltinPath が見つかりません") return end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ok_bind, ImGui = pcall(function() return require "imgui" "0.10" end)
if not ok_bind or type(ImGui) ~= "table" then need_reaimgui(ok_bind and "束ねに失敗" or tostring(ImGui)) return end

-- ===========================================================================
-- REAPER側の小さな操作
-- ===========================================================================
local function shell_open(target)
  if reaper.CF_ShellExecute then reaper.CF_ShellExecute(target); return true end
  local os_name = reaper.GetOS() or ""
  if os_name:sub(1, 3) == "Win" then
    reaper.ExecProcess('cmd /c start "" "' .. target .. '"', -1)
  else
    os.execute(('open %q'):format(target))
  end
  return true
end

-- 出力フォルダを選ぶ。js_ReaScriptAPI があれば本物のフォルダ選択、無ければ
-- 「そのフォルダの中のファイルを1つ選ぶ」で代用する（欄に直接書いてもよい）。
local function browse_folder(current)
  if reaper.JS_Dialog_BrowseForFolder then
    local ok, path = reaper.JS_Dialog_BrowseForFolder("出力フォルダを選んでください", current or "")
    if ok and path and path ~= "" then return path end
    return nil
  end
  local ok, file = reaper.GetUserFileNameForRead(current or "",
    "出力フォルダの中にあるファイルを1つ選んでください（そのフォルダを使います）", "")
  if ok and file and file ~= "" then
    return (file:match("^(.*)[/\\][^/\\]+$") or file)
  end
  return nil
end

-- ===========================================================================
-- 状態
-- ===========================================================================
-- 最初に開くタブ。無人試験は ExtState で指定する（人が開くときは Para + 2mix）。
local function first_tab()
  local want = reaper.GetExtState(NS, "tab")
  for _, t in ipairs(Model.TAB_LABELS) do
    if t.tab == want then return want end
  end
  return "para"
end

local app = {
  tab      = first_tab(),
  -- 最初の1フレームだけ、このタブを選んだ状態で開く（ImGui は既定で一番左のタブを選ぶ）
  want_tab = first_tab(),
  st       = nil,          -- Model.load の結果
  view     = "settings",   -- "settings" / "done"
  result   = nil,          -- 書き出しの結果
  message  = nil,          -- 画面下の一言
  pending_run = false,
  pending_browse = false,
  last_detect = 0,
  autorun  = (reaper.GetExtState(NS, "autorun") == "1"),  -- 無人試験用の入口
  test_hook = (reaper.GetExtState(NS, "autorun") ~= ""),  -- 無人試験のときだけ、描けたフレーム数を外へ出す
  frame_no = 0,
  ctx = nil, font = nil,
}

app.st = Model.load(app.tab)

local function reload_state(tab)
  app.tab = tab
  app.st = Model.load(tab)
  app.view = "settings"
  app.result = nil
  app.diag_sc, app.diag_path, app.diag_err = nil, nil, nil
end

-- 開いているあいだ、読み取り（範囲・ディザー・ハード）は少しずつ見直す。
-- 欄の値（ユーザーが決めたもの）には触らない。
local function refresh_detect()
  local now = reaper.time_precise()
  if now - app.last_detect < 0.5 then return end
  app.last_detect = now
  local ok, _, d = pcall(Model.detect, app.tab)
  if ok and d then app.st.detect = d end
end

-- ===========================================================================
-- 書き出し（描画の外で呼ぶこと）
-- ===========================================================================
local function do_run()
  local res, cfg = Model.run(app.st)
  app.result = res
  app.cfg = cfg
  app.view = "done"
  if app.autorun then
    -- 無人試験の合図。窓を開けたまま、外（試験台）に終わったことを伝える
    local text
    if res.job and not res.err and not res.aborted then
      text = Model.done_text(cfg, res.job)
    else
      text = tostring(res.aborted or res.err or "実行できませんでした。")
    end
    reaper.SetExtState(NS, "autorun_text", text, false)
    reaper.SetExtState(NS, "autorun_done", "1", false)
  end
end

-- ===========================================================================
-- 描く（項目の表をそのまま並べる）
-- ===========================================================================
-- 左に項目名、右に部品。REAPERの書き出し画面と同じように、名前の幅をそろえる。
local LABEL_W = 210

local function label_cell(ctx, text)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, text)
  ImGui.SameLine(ctx, LABEL_W)
end

-- 項目の下に出す、読み取り専用の1行（灰色）
local function draw_note(ctx, text)
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      ImGui.Dummy(ctx, LABEL_W - 8, 1)
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, line)
    end
  end
end

local function tooltip(ctx, text)
  if text and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

local function combo_items(options)
  local t = {}
  for _, o in ipairs(options) do t[#t + 1] = o[2] end
  return table.concat(t, "\0") .. "\0"
end

local function draw_row(ctx, row, ui)
  -- 「チェックを入れたときだけ出る欄」（row.when）
  if row.when then
    local cur = ui[row.when.key]
    if (cur and true or false) ~= (row.when.value and true or false) then return end
  end
  -- 「いまの選び方だと使わない欄」（row.visible）。毎フレーム見るので、選び直せばすぐ消える
  if row.visible and not Model.visible(app.st, row.visible) then return end
  -- 選択トラックのサイドチェイン状況。中身は Model が作る（ここは並べるだけ）。
  -- 文は毎フレーム作り直さず、選んだトラック／トラックの本数が変わったときだけ作り直す。
  if row.kind == "diag" then
    ImGui.PushID(ctx, row.id)
    ImGui.SeparatorText(ctx, row.label)
    for _, b in ipairs(row.buttons) do
      local can, why = Model.diag_enabled(app.st, b.id)
      if not can then ImGui.BeginDisabled(ctx) end
      if ImGui.Button(ctx, b.label) then app.pending_diag = b.id end
      if not can then ImGui.EndDisabled(ctx) end
      -- この欄は左端から始まるので、説明はボタンの真下に左寄せで出す（draw_note は欄名ぶん右へずらす）
      if b.note then ImGui.TextDisabled(ctx, b.note) end
      if not can and why then ImGui.TextDisabled(ctx, why) end
    end
    if app.diag_err then ImGui.TextWrapped(ctx, "資料を書き出せません: " .. tostring(app.diag_err)) end
    if app.diag_path then
      ImGui.SetNextItemWidth(ctx, -150)
      ImGui.InputText(ctx, "##structure", app.diag_path, ImGui.InputTextFlags_ReadOnly)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "フォルダを開く", 140) then
        shell_open(app.diag_path:match("^(.*)[/\\][^/\\]+$") or app.diag_path)
      end
    end
    ImGui.Dummy(ctx, 1, 2)
    if (app.st.detect.sel_tracks or 0) ~= 1 then
      app.diag_sc = nil
      ImGui.TextDisabled(ctx, row.need)
    else
      if Model.sc_stale(app.st, app.diag_sc) then
        local ok, v = pcall(Model.sc_preview, app.st)
        app.diag_sc = ok and v or { guid = app.st.detect.sel_track_guid,
                                    ntracks = app.st.detect.track_count, lines = { tostring(v) } }
      end
      for _, line in ipairs(app.diag_sc.lines) do ImGui.Text(ctx, line) end
    end
    ImGui.PopID(ctx)
    return
  end
  if row.kind == "info" then
    label_cell(ctx, row.label)
    -- row.grey が立っている行は、下に出る読み取り専用の1行と同じ灰色で出す
    if row.grey then
      ImGui.TextDisabled(ctx, tostring(Model.note(app.st, row.note)))
    else
      ImGui.Text(ctx, tostring(Model.note(app.st, row.note)))
    end
    return
  end

  ImGui.PushID(ctx, row.key)
  if row.kind == "check" then
    -- チェックは項目名の列を使わず、そのまま並べる
    local rv, v = ImGui.Checkbox(ctx, row.label, ui[row.key] and true or false)
    if rv then ui[row.key] = v end
    tooltip(ctx, row.hint)
  else
    label_cell(ctx, row.label)
    if row.kind == "path" then
      ImGui.SetNextItemWidth(ctx, -110)
      local rv, v = ImGui.InputText(ctx, "##v", tostring(ui[row.key] or ""))
      if rv then ui[row.key] = v end
      tooltip(ctx, row.hint)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "参照...") then app.pending_browse = row.key end
      tooltip(ctx, row.hint)
    elseif row.kind == "text" then
      ImGui.SetNextItemWidth(ctx, -110)
      local rv, v = ImGui.InputText(ctx, "##v", tostring(ui[row.key] or ""))
      if rv then ui[row.key] = v end
      tooltip(ctx, row.hint)
    elseif row.kind == "num" then
      ImGui.SetNextItemWidth(ctx, 250)
      local rv, v = ImGui.InputDouble(ctx, "##v", tonumber(ui[row.key]) or 0,
        row.step or 0.1, (row.step or 0.1) * 10, row.fmt or "%.3f")
      if rv then ui[row.key] = v end
      tooltip(ctx, row.hint)
    elseif row.kind == "combo" then
      local cur = 0
      for i, o in ipairs(row.options) do if o[1] == ui[row.key] then cur = i - 1 end end
      ImGui.SetNextItemWidth(ctx, 250)
      local rv, idx = ImGui.Combo(ctx, "##v", cur, combo_items(row.options))
      if rv then ui[row.key] = row.options[idx + 1][1] end
      tooltip(ctx, row.hint)
      -- 「入力...」のように、選んだときだけ右に欄が出るもの
      if row.extra and ui[row.key] == row.extra.when then
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, -10)
        local rv2, v2 = ImGui.InputText(ctx, "##extra", tostring(ui[row.extra.key] or ""))
        if rv2 then ui[row.extra.key] = v2 end
      end
    end
  end
  ImGui.PopID(ctx)
  if row.note then draw_note(ctx, Model.note(app.st, row.note)) end
end

-- 枠で囲んだひと区切り（REAPERの書き出し画面と同じ見た目）
local function draw_section(ctx, sec, ui)
  local open
  if sec.collapsible then
    open = ImGui.CollapsingHeader(ctx, sec.label)   -- 「詳細」は最初は閉じている
  else
    ImGui.Text(ctx, sec.label)
    open = true
  end
  if open then
    if ImGui.BeginChild(ctx, "sec_" .. sec.label, 0, 0,
        ImGui.ChildFlags_Borders | ImGui.ChildFlags_AutoResizeY) then
      for _, r in ipairs(sec.rows) do draw_row(ctx, r, ui) end
      ImGui.EndChild(ctx)
    end
  end
  ImGui.Dummy(ctx, 1, 6)   -- 区切りのあいだを空ける
end

local function draw_settings(ctx)
  local st = app.st
  for _, sec in ipairs(Model.ROWS[st.tab]) do draw_section(ctx, sec, st.ui) end

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "既定として保存") then
    Model.save_default(st)
    app.message = "いまの内容を、この REAPER のどのプロジェクトでも最初に出る値にしました。"
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "いまの内容を、これから開くどのプロジェクトでも最初に出る値にします。")
  if ImGui.Button(ctx, "既定に戻す") then
    Model.reset(st)
    app.message = "この曲に覚えさせた内容を消して、既定の値に戻しました。"
  end
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, "この曲に覚えた内容だけを消します（既定は消しません）。")

  ImGui.Separator(ctx)
  local can_run, why = Model.gate(st)
  if not can_run then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "書き出し", 140, 30) then app.pending_run = true end
  if not can_run then ImGui.EndDisabled(ctx) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "閉じる", 100, 30) then app.close = true end
  if not can_run then
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, "書き出せません: " .. tostring(why))
  end

  for _, w in ipairs(st.warns or {}) do ImGui.TextWrapped(ctx, "注意: " .. tostring(w)) end
  if app.message then ImGui.TextWrapped(ctx, app.message) end
end

-- 完了画面。出したファイルの場所と、異常だけを出す（ゴール4）。
local function draw_done(ctx)
  local res = app.result
  local j = res and res.job
  if res and (res.err or res.aborted) then
    ImGui.TextWrapped(ctx, res.aborted and ("中断しました:\n" .. tostring(res.aborted))
      or ("予期しないエラーが出ました:\n" .. tostring(res.err)))
    ImGui.Separator(ctx)
  else
    ImGui.Text(ctx, "書き出しました。")
  end

  if j then
    -- 書き出し先（フォルダ）を先に。ファイルはフォルダごとにまとめ、一覧は畳んでおく。
    local groups, order = {}, {}
    -- Para + 2mix は「Master」「Mix」の1つ上のフォルダを書き出し先として1行で出す（つこさん要望）
    local root = j.MIX_DIR and j.MIX_DIR:match("^(.*)[/\\][^/\\]+$") or nil
    for _, f in ipairs(j.produced) do
      local d, n = f:match("^(.*)[/\\]([^/\\]+)$")
      if not d then d, n = "", f end
      if root and d:sub(1, #root) == root then
        n = f:sub(#root + 2); d = root
      end
      if not groups[d] then groups[d] = {}; order[#order + 1] = d end
      groups[d][#groups[d] + 1] = n
    end
    ImGui.SeparatorText(ctx, "書き出し先")
    if #order == 0 then
      ImGui.Text(ctx, "（ファイルは出ていません）")
    end
    for gi, d in ipairs(order) do
      ImGui.PushID(ctx, gi)
      ImGui.SetNextItemWidth(ctx, -150)
      ImGui.InputText(ctx, "##dir", d, ImGui.InputTextFlags_ReadOnly)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "フォルダを開く", 140) then shell_open(d) end
      ImGui.PopID(ctx)
    end
    -- Hardware Print: 置き場所を決められなかったものだけは異常として出す
    if j.hw and #(j.hw.unmatched or {}) > 0 then
      ImGui.TextWrapped(ctx, ("置き場所を決められなかったファイル: %d本（REAPERが作ったトラックに残っています）")
        :format(#j.hw.unmatched))
    end
    if #j.produced > 0 then
      ImGui.Dummy(ctx, 1, 4)
      if ImGui.CollapsingHeader(ctx, ("書き出したファイル一覧（%d本）"):format(#j.produced)) then
        for gi, d in ipairs(order) do
          if #order > 1 then ImGui.TextDisabled(ctx, d) end
          for _, n in ipairs(groups[d]) do ImGui.Text(ctx, "  " .. n) end
        end
      end
    end
    if j.chain_dir then
      ImGui.SeparatorText(ctx, "MASTERのプラグイン設定")
      ImGui.SetNextItemWidth(ctx, -1)
      ImGui.InputText(ctx, "##chain", j.chain_dir, ImGui.InputTextFlags_ReadOnly)
    end
    if j.LOG_PATH then
      ImGui.Dummy(ctx, 1, 4)
      ImGui.TextDisabled(ctx, "実行記録（うまくいかなかったときに送るファイル）:")
      ImGui.SetNextItemWidth(ctx, -1)
      ImGui.InputText(ctx, "##log", j.LOG_PATH, ImGui.InputTextFlags_ReadOnly)
    end
    if #j.warnings > 0 then
      ImGui.SeparatorText(ctx, ("注意 %d 件"):format(#j.warnings))
      for _, w in ipairs(j.warnings) do ImGui.TextWrapped(ctx, "・" .. tostring(w)) end
    end
  end

  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "戻る", 100, 28) then reload_state(app.tab) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "閉じる", 100, 28) then app.close = true end
end

-- ===========================================================================
-- 窓の骨組み
-- ===========================================================================
local function make_context()
  local ctx = ImGui.CreateContext(TITLE)
  local okf, f = pcall(ImGui.CreateFont, "sans-serif")   -- 日本語が出るように
  local font
  if okf and f then
    local oka = pcall(ImGui.Attach, ctx, f)
    font = oka and f or nil
  end
  app.ctx, app.font = ctx, font
  return ctx
end

local function ctx_alive()
  local ok, v = pcall(ImGui.ValidatePtr, app.ctx, "ImGui_Context*")
  return ok and v or false
end

make_context()

local function frame()
  app.frame_no = app.frame_no + 1

  -- ---- 描く前にやること（書き出しもフォルダ選びも、描画の外で）----
  if app.pending_browse then
    local key = app.pending_browse
    app.pending_browse = nil
    local picked = browse_folder(app.st.ui[key])
    if picked then app.st.ui[key] = picked end
  end
  if app.pending_diag then
    local id = app.pending_diag
    app.pending_diag = nil
    if id == "sc_structure" then
      local ok, p, err = pcall(Model.write_structure, app.st)
      if not ok then app.diag_path, app.diag_err = nil, tostring(p)
      else app.diag_path, app.diag_err = p, (not p) and tostring(err) or nil end
    end
  end
  if app.pending_run then
    app.pending_run = false
    local ok, err = pcall(do_run)
    if not ok then
      app.result = { ok = false, err = tostring(err) }
      app.view = "done"
    end
  end

  -- 書き出しで窓が壊れていたら作り直す（下調べで壊れる道は避けているが、念のため）
  if not ctx_alive() then make_context() end
  local ctx = app.ctx

  if app.view == "settings" then refresh_detect() end

  if app.font then pcall(ImGui.PushFont, ctx, app.font, 14) end
  ImGui.SetNextWindowSize(ctx, 780, 700, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, TITLE, true)
  if visible then
    if ImGui.BeginTabBar(ctx, "tukonya_tabs") then
      for _, t in ipairs(Model.TAB_LABELS) do
        -- 開いた直後だけ、指定のタブを選んだ状態にする。
        -- これをしないと ImGui は一番左のタブを選び、そのタブに切り替わってしまう。
        local flags = (app.want_tab == t.tab) and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
        if ImGui.BeginTabItem(ctx, t.label, nil, flags) then
          if app.want_tab and t.tab ~= app.want_tab then
            -- まだ望みのタブが選ばれていない。次のフレームで選ばれるので、切り替えとしては扱わない
          elseif t.tab ~= app.tab and t.ready then
            reload_state(t.tab)
          end
          if t.tab == app.want_tab then app.want_tab = nil end
          if not t.ready then
            ImGui.Dummy(ctx, 1, 8)
            ImGui.Text(ctx, "このタブはまだ作っていません。")
          elseif app.view == "done" then
            draw_done(ctx)
          else
            draw_settings(ctx)
          end
          ImGui.EndTabItem(ctx)
        end
      end
      ImGui.EndTabBar(ctx)
    end
    -- 保険: 何かの理由でタブを選ばせられなかったときも、人が使う分には
    -- 数フレームで普通の切り替えに戻す（無人試験のときは、黙って別のタブで
    -- 走らないように、選ばれるまで待たせたままにする）。
    if not app.autorun and app.frame_no >= 5 then app.want_tab = nil end
    ImGui.End(ctx)
  end
  if app.font then pcall(ImGui.PopFont, ctx) end

  -- 無人試験の入口: ExtState で「開いたら書き出しまでやる」と言われていたら押す
  -- 望みのタブが選ばれきってから押す（タブの切り替えは1フレーム遅れることがある）
  if app.autorun and not app.autorun_fired and app.frame_no >= 3
     and not app.want_tab and app.view == "settings" then
    app.autorun_fired = true
    -- 人が押すときと同じ関門を通す。押せない状態なら、書き出さずにその理由を外へ返す
    -- （無人試験でも「押せなくなる不具合」が見つかるように）。
    local can, why = Model.gate(app.st)
    if can then
      app.pending_run = true
    else
      reaper.SetExtState(NS, "autorun_text", "書き出せません: " .. tostring(why), false)
      reaper.SetExtState(NS, "autorun_done", "1", false)
    end
  end

  -- 無人試験用: ここまで来たフレーム数を外から読めるようにする
  -- （描画で例外が出ていれば、この数は増えない＝窓が壊れたと分かる）
  if app.test_hook then reaper.SetExtState(NS, "autorun_frames", tostring(app.frame_no), false) end

  if open ~= false and not app.close then reaper.defer(frame) end
end

reaper.defer(frame)
