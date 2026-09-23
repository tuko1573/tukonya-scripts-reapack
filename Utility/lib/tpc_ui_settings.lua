--[[
  tpc_ui_settings.lua
  Team Plugin Checker — 小窓の「設定」タブ。tpc_ui_tabs.lua から再公開される。
  ここだけが tpc_startup（起動時の自動送信の登録／解除）を触る。
--]]

local tpc_startup = require("tpc_startup")

local M = {}

local function tooltip(ImGui, ctx, text)
  if text and text ~= "" then ImGui.SetItemTooltip(ctx, text) end
end

-- ============================================================
-- プロファイル（共有フォルダ・メンバーID・表示名の組）
-- ============================================================

--- ダイアログを出す操作は描画の外（次のフレームの頭）で行う。
local function later(app, fn)
  app.pending_action = fn
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

  local shared = config:get_shared_dir()
  local shown = shared or "（未設定）"
  -- 毎フレーム共有フォルダを見に行かない（resolve_root で確かめた結果を使う）
  if shared and shared == app.shared_dir and not app.shared_dir_found then
    shown = shown .. "（見つかりません）"
  end
  ImGui.Text(ctx, "共有フォルダ: " .. shown)
  ImGui.Text(ctx, "メンバーID: " .. tostring(config:get_member_id() or "（未設定）"))
  tooltip(ImGui, ctx, "一度決めたら変えません（共有フォルダの中のファイル名になります）")

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

  if not config:profile_complete(current) then
    if ImGui.Button(ctx, "初回設定…") then
      later(app, function(a)
        local ok = boot.ensure_profile(a.store, a.config, boot.log, { prompt = true })
        ui.profile_changed(a)
        a.settings_message = ok and "初回設定を保存しました。「今すぐ更新」で自分の一覧を送れます。"
          or ui.profile_hint(a)
      end)
    end
    tooltip(ImGui, ctx, "共有フォルダ・メンバーID・表示名をまとめて入れます")
    ImGui.SameLine(ctx)
  end

  if ImGui.Button(ctx, "共有フォルダを変更…") then
    later(app, function(a)
      local ok, pasted = reaper.GetUserInputs("Team Plugin Checker: 共有フォルダ（プロファイル: " ..
        current .. "）", 1, "共有フォルダのパス,extrawidth=300", a.config:get_shared_dir() or "")
      if not ok then return end
      local path = require("tpc_store").normalize_pasted_path(pasted)
      if path == "" or not a.store:path_exists(path) then
        a.settings_message = "その場所は見つかりませんでした: " .. path
        return
      end
      a.config:set_shared_dir(path)
      boot.log("設定タブ: 共有フォルダを変更 -> " .. path)
      ui.profile_changed(a)
      a.settings_message = ui.profile_hint(a) or ("この場所を使います: " .. path)
    end)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "プロファイルを追加…") then
    later(app, function(a)
      local ok = boot.prompt_new_profile(a.store, a.config, boot.log)
      ui.profile_changed(a)
      a.settings_message = ok and ("プロファイル「" .. a.config:current() .. "」を追加しました。")
        or ui.profile_hint(a)
    end)
  end
  ImGui.SameLine(ctx)
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
