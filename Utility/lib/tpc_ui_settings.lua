--[[
  tpc_ui_settings.lua
  Team Plugin Checker — 小窓の「設定」タブ。tpc_ui_tabs.lua から再公開される。
  ここだけが tpc_startup（起動時の自動送信の登録／解除）を触る。
--]]

local tpc_startup = require("tpc_startup")
local tpc_store = require("tpc_store")
local tpc_config = require("tpc_config")
local tpc_dialog = require("tpc_dialog")

local M = {}

local function tooltip(ImGui, ctx, text)
  if text and text ~= "" then ImGui.SetItemTooltip(ctx, text) end
end

-- ============================================================
-- プロファイル（共有フォルダ・メンバーID・表示名の組）
-- 初回設定・追加・共有フォルダの変更は、別のダイアログではなくこのタブの中の入力欄で行う。
-- ============================================================

--- ダイアログを出す操作は描画の外（次のフレームの頭）で行う。
local function later(app, fn)
  app.pending_action = fn
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local ERROR_COLOR = 0xFF7766FF

--- 入力欄の「保存」。検証に通れば保存して窓を読み直し、true を返す。
-- 通らなければ form.error に理由を入れて false（何も保存しない）。
function M.form_save(app, ui)
  local form = app.profile_form
  if not form then return false end
  local config, store, boot = app.config, app.store, app.boot
  form.error = nil

  local name
  if form.mode == "add" then
    name = trim(form.name)
    if not tpc_config.valid_profile_name(name) then
      form.error = "プロファイル名は半角英数字・_・- で1〜32文字にしてください（例: team2）。"
      return false
    end
    if config:has_profile(name) then
      form.error = "同じ名前のプロファイルがあります: " .. name
      return false
    end
  end

  local dir = tpc_store.normalize_pasted_path(form.shared_dir)
  if dir == "" then
    form.error = "共有フォルダのパスを入れてください（「参照…」で選べます）。"
    return false
  end
  if not store:path_exists(dir) then
    form.error = "共有フォルダが見つかりません: " .. dir .. "\n先にフォルダを作るか、「参照…」で選んでください。"
    return false
  end

  local id, display_name
  if form.mode ~= "folder" then
    id = trim(form.member_id)
    if not tpc_config.valid_member_id(id) then
      form.error = "メンバーIDは半角の小文字英数字と _ で1〜16文字にしてください（例: taro）。"
      return false
    end
    display_name = trim(form.display_name)
    if display_name == "" then display_name = id end
  end

  if form.mode == "add" then
    local ok, err = config:add_profile(name)
    if not ok then form.error = tostring(err); return false end
    config:set_current(name)
    boot.log("設定タブ: プロファイルを追加 " .. name)
  elseif form.profile and config:current() ~= form.profile then
    -- 入力中に別のプロファイルへ切り替わっていたら、入力を始めたプロファイルに書く
    config:set_current(form.profile)
  end

  config:set_shared_dir(dir)
  if form.mode ~= "folder" then
    config:set_member_id(id)
    config:set_display_name(display_name)
  end
  local cur = config:current()
  boot.log(("設定タブ: %s プロファイル %s 共有フォルダ=%s%s"):format(
    form.mode, cur, dir, id and (" member=" .. id) or ""))

  local mode = form.mode
  app.profile_form = nil
  ui.profile_changed(app)
  if mode == "add" then
    app.settings_message = ui.profile_hint(app) or
      ("プロファイル「" .. cur .. "」を追加しました。「今すぐ更新」で自分の一覧を送れます。")
  elseif mode == "first" then
    app.settings_message = ui.profile_hint(app) or
      "初回設定を保存しました。「今すぐ更新」で自分の一覧を送れます。"
  else
    app.settings_message = ui.profile_hint(app) or ("この場所を使います: " .. dir)
  end
  return true
end

--- 入力欄の「キャンセル」。
function M.form_cancel(app, ui)
  app.profile_form = nil
  app.settings_message = ui.profile_hint(app)
end

--- 「参照…」: フォルダ選択ダイアログは描画の外（次のフレームの頭）で出す。
local function browse_later(app)
  later(app, function(a)
    local form = a.profile_form
    if not form then return end
    local start = tpc_store.normalize_pasted_path(form.shared_dir)
    if start == "" or not a.store:path_exists(start) then start = nil end
    local deps = a.dialog_deps or tpc_dialog.default_deps()
    deps.log = deps.log or a.boot.log
    local path = tpc_dialog.browse_folder(deps, start)
    if path and path ~= "" then
      form.shared_dir = path
      form.error = nil
    elseif not deps.js_browse and tpc_dialog.os_kind(deps.os_name) == "other" then
      form.error = "この環境ではフォルダ選択の画面を出せません。パスを直接入れてください。"
    end
  end)
end

local FORM_TITLE = {
  first = "初回設定（プロファイル: %s）",
  add = "プロファイルを追加",
  folder = "共有フォルダを変更（プロファイル: %s）",
}

--- 入力欄（初回設定・プロファイルの追加・共有フォルダの変更で共通）。
function M.profile_form(ImGui, ctx, app, ui)
  local form = app.profile_form
  ImGui.SeparatorText(ctx, FORM_TITLE[form.mode]:format(tostring(form.profile)))
  if form.mode == "first" then
    ImGui.TextWrapped(ctx, "チームで共有しているフォルダと、自分のメンバーIDを入れて「保存」を押してください。")
  end

  if form.mode == "add" then
    ImGui.SetNextItemWidth(ctx, 200)
    local _, v = ImGui.InputText(ctx, "プロファイル名##tpc_form_name", form.name)
    form.name = v
    tooltip(ImGui, ctx, "半角英数字・_・-（例: team2）")
  end

  ImGui.SetNextItemWidth(ctx, 420)
  local _, dir = ImGui.InputText(ctx, "共有フォルダのパス##tpc_form_dir", form.shared_dir)
  form.shared_dir = dir
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "参照…") then
    browse_later(app)
  end
  tooltip(ImGui, ctx, "フォルダを選ぶ画面を出します")

  if form.mode ~= "folder" then
    ImGui.SetNextItemWidth(ctx, 200)
    local _, id = ImGui.InputText(ctx, "メンバーID##tpc_form_id", form.member_id)
    form.member_id = id
    tooltip(ImGui, ctx, "半角の小文字英数字と _、1〜16文字（例: taro）。共有フォルダの中のファイル名になるので、一度決めたら変えません")
    ImGui.SetNextItemWidth(ctx, 200)
    local _, dn = ImGui.InputText(ctx, "表示名##tpc_form_display", form.display_name)
    form.display_name = dn
    tooltip(ImGui, ctx, "画面に出る名前。日本語でもOK。空ならメンバーIDと同じ")
  end

  if form.error then
    ImGui.TextColored(ctx, ERROR_COLOR, form.error)
  end

  if ImGui.Button(ctx, "保存") then
    M.form_save(app, ui)
  end
  if ui.any_profile_complete(app.config) then
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "キャンセル") then
      M.form_cancel(app, ui)
    end
  end
end

function M.profile_section(ImGui, ctx, app, ui)
  local config = app.config
  local boot = app.boot
  local profiles = config:profiles()
  local current = config:current()

  ImGui.SeparatorText(ctx, "プロファイル")
  for i, name in ipairs(profiles) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.RadioButton(ctx, name, name == current) and name ~= current then
      config:set_current(name)
      boot.log("設定タブ: プロファイルを切り替え -> " .. name)
      ui.profile_changed(app)
      app.settings_message = ui.profile_hint(app) or ("プロファイル「" .. name .. "」に切り替えました。")
    end
  end
  tooltip(ImGui, ctx, "チームごとに、共有フォルダ・メンバーID・表示名の組を持てます")

  -- 入力欄を出している間は、ほかの操作ボタンを引っ込める（削除だけは初回設定中も出す）
  local form = app.profile_form
  if form then
    M.profile_form(ImGui, ctx, app, ui)
    if form.mode == "first" and #profiles > 1 then
      M.delete_button(ImGui, ctx, app, ui, profiles, config:current())
    end
    return
  end

  local shared = config:get_shared_dir()
  local shown = shared or "（未設定）"
  -- 毎フレーム共有フォルダを見に行かない（resolve_root で確かめた結果を使う）
  if shared and shared == app.shared_dir and not app.shared_dir_found then
    shown = shown .. "（見つかりません）"
  end
  ImGui.Text(ctx, "共有フォルダ: " .. shown)
  ImGui.Text(ctx, "メンバーID: " .. tostring(config:get_member_id() or "（未設定）"))
  tooltip(ImGui, ctx, "一度決めたら変えません（共有フォルダの中のファイル名になります）")

  local complete = config:profile_complete(current)
  if complete then
    app.edit_display_name = app.edit_display_name or (config:get_display_name() or "")
    ImGui.SetNextItemWidth(ctx, 240)
    local _, dn = ImGui.InputText(ctx, "表示名", app.edit_display_name)
    app.edit_display_name = dn
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "表示名を保存") then
      -- 空にすると初回設定が未完成に戻るので、空ならメンバーIDで埋める
      local name = (app.edit_display_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if name == "" then name = config:get_member_id() or "" end
      app.edit_display_name = name
      config:set_display_name(name)
      app.settings_message = "表示名を保存しました（次回の更新で共有フォルダにも反映されます）。"
    end
  end

  if not complete then
    -- キャンセルで閉じたあと、もう一度入力欄を出すためのボタン
    if ImGui.Button(ctx, "初回設定…") then
      ui.open_profile_form(app, "first")
    end
    tooltip(ImGui, ctx, "共有フォルダ・メンバーID・表示名をまとめて入れます")
    ImGui.SameLine(ctx)
  else
    if ImGui.Button(ctx, "共有フォルダを変更…") then
      ui.open_profile_form(app, "folder")
    end
    ImGui.SameLine(ctx)
  end
  if ImGui.Button(ctx, "プロファイルを追加…") then
    ui.open_profile_form(app, "add")
  end
  ImGui.SameLine(ctx)
  M.delete_button(ImGui, ctx, app, ui, profiles, current)
end

function M.delete_button(ImGui, ctx, app, ui, profiles, current)
  local boot = app.boot
  local only_one = #profiles <= 1
  if only_one then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "このプロファイルを削除") then
    later(app, function(a)
      local answer = reaper.MB("プロファイル「" .. current .. "」を削除しますか？\n\n" ..
        "このREAPERの設定から消すだけで、共有フォルダの中のファイルは消しません。",
        "Team Plugin Checker", 4)
      if answer ~= 6 then return end -- 6 = はい
      local ok, err = a.config:remove_profile(current)
      boot.log("設定タブ: プロファイルを削除 " .. current .. " -> " .. tostring(ok) .. " " .. tostring(err))
      ui.profile_changed(a)
      a.settings_message = ok and ("プロファイル「" .. current .. "」を削除しました。")
        or ("削除できませんでした: " .. tostring(err))
    end)
  end
  if only_one then ImGui.EndDisabled(ctx) end
end

local AI_LIST = { { "chatgpt", "ChatGPT" }, { "claude", "Claude" }, { "perplexity", "Perplexity" } }

function M.settings(ImGui, ctx, app, ui)
  local config = app.config

  M.profile_section(ImGui, ctx, app, ui)

  ImGui.SeparatorText(ctx, "リンクを探すときのAI")
  local cur = config:get_ai_choice()
  for _, item in ipairs(AI_LIST) do
    if ImGui.RadioButton(ctx, item[2], cur == item[1]) then config:set_ai_choice(item[1]) end
    ImGui.SameLine(ctx)
  end
  ImGui.NewLine(ctx)

  ImGui.SeparatorText(ctx, "データ")
  if ImGui.Button(ctx, "今すぐ更新") then
    app.pending_sendnow = true
    app.settings_message = "更新しています…"
  end
  tooltip(ImGui, ctx, "自分のプラグイン一覧を集め直して、全プロファイルの共有フォルダへ書きます")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "データを再読み込み") then
    app.pending_reload = true
  end
  ImGui.Text(ctx, "最後に送った日: " .. tostring(config:get_last_sent_date() or "（まだ）"))
  ImGui.Text(ctx, "一覧の指紋（前回）: " .. tostring(config:get_last_hash() or "（まだ）"))
  if app.state then
    ImGui.Text(ctx, ("読み込み済み: メンバー%d人 / プラグイン%d件")
      :format(#app.state.members, (function()
        local n = 0
        for _ in pairs(app.state.index) do n = n + 1 end
        return n
      end)()))
  end
  if app.settings_message then
    ImGui.TextWrapped(ctx, app.settings_message)
  end

  -- 開発用: 合成メンバーを今のプロファイルの共有フォルダに置く／消す。
  -- ExtState TeamPluginChecker/dev_fixtures にフォルダを入れた機械（開発機）でだけ出る。配布版には出ない。
  -- （または <REAPER設定フォルダ>/TeamPluginChecker.dev に、そのフォルダのパスを1行書いた機械）
  local DEV_FIX = reaper.GetExtState("TeamPluginChecker", "dev_fixtures")
  if DEV_FIX == "" then
    local f = io.open(reaper.GetResourcePath() .. "/TeamPluginChecker.dev", "rb")
    if f then DEV_FIX = (f:read("*l") or ""):gsub("%s+$", ""); f:close() end
  end
  if app.root and DEV_FIX ~= "" and reaper.file_exists(DEV_FIX .. "/kamil.json") then
    ImGui.SeparatorText(ctx, "開発用（このMacだけに出る）")
    if ImGui.Button(ctx, "試験メンバーを置く") then
      local n = 0
      for _, id in ipairs({ "kamil", "utaren", "shoki" }) do
        local text = app.store.deps.read_file(DEV_FIX .. "/" .. id .. ".json")
        if text then
          text = text:gsub('"member_id"%s*:%s*"' .. id .. '"', '"member_id":"test_' .. id .. '"', 1)
          text = text:gsub('"display_name"%s*:%s*"', '"display_name":"試験', 1)
          local dst = app.root .. app.store:sep() .. "members" .. app.store:sep() .. "test_" .. id .. ".json"
          if app.store.deps.write_file(dst, text) then n = n + 1 end
        end
      end
      app.settings_message = ("試験メンバーを%d人置きました"):format(n)
      app.pending_reload = true
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "試験メンバーを消す") then
      for _, id in ipairs({ "kamil", "utaren", "shoki" }) do
        app.store.deps.remove(app.root .. app.store:sep() .. "members" .. app.store:sep() .. "test_" .. id .. ".json")
      end
      app.settings_message = "試験メンバーを消しました"
      app.pending_reload = true
    end
  end

  ImGui.SeparatorText(ctx, "REAPER起動時の自動送信")
  M.startup_section(ImGui, ctx, app)
end

-- ============================================================
-- 起動時の自動送信（__startup.lua のマーカー付きの一塊）
-- ============================================================

--- 起動時に読み込まれるファイルを毎フレーム読みに行かないよう、結果を覚えておく。
local function startup_installed(app, force)
  if force or app.startup_installed == nil then
    local ok, res = pcall(tpc_startup.is_installed, app.startup_deps)
    app.startup_installed = ok and res or false
  end
  return app.startup_installed
end

function M.startup_section(ImGui, ctx, app)
  if not app.startup_deps then
    ImGui.TextWrapped(ctx, "このスクリプトの置き場所が分からないため、登録できません。")
    return
  end

  local installed = startup_installed(app)
  ImGui.Text(ctx, "起動時の自動送信: " .. (installed and "登録済み" or "未登録"))
  tooltip(ImGui, ctx, tpc_startup.startup_path(app.startup_deps))

  if ImGui.Button(ctx, "登録") then
    local ok, res = tpc_startup.install(app.startup_deps)
    startup_installed(app, true)
    app.settings_message = ok
      and ("登録しました。次のREAPER起動から自動で送ります（設置場所: Scripts/" .. tostring(res) .. "）。")
      or ("登録できませんでした: " .. tostring(res))
    app.boot.log("設定タブ: 起動時の自動送信 登録 -> " .. tostring(ok) .. " " .. tostring(res))
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "解除") then
    local ok, err = tpc_startup.uninstall(app.startup_deps)
    startup_installed(app, true)
    app.settings_message = ok and "解除しました（起動時には何もしません）。"
      or ("解除できませんでした: " .. tostring(err))
    app.boot.log("設定タブ: 起動時の自動送信 解除 -> " .. tostring(ok) .. " " .. tostring(err))
  end
  ImGui.TextWrapped(ctx,
    "REAPERの起動ファイルに、印で挟んだ一塊を足すだけです。印の外側は触りません。" ..
    "起動してから数秒待って送るので、画面には何も出ません。")
end

return M
