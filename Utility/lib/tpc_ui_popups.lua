--[[
  tpc_ui_popups.lua
  Team Plugin Checker — 小窓の中に出す2つの小窓（リンクの登録／「同じものとして扱う」訂正）。
  tpc_ui_tabs.lua から再公開され、tpc_ui.lua が毎フレーム呼ぶ。
  表示する中身の計算は tpc_viewmodel が持ち、ここは並べるだけ。
--]]

local VM = require("tpc_viewmodel")

local M = {}

-- ============================================================
-- リンクを登録する小窓
-- ============================================================

local LINK_POPUP_ID = "リンクを登録"

function M.link_popup(ImGui, ctx, app, ui)
  -- 前のフレームで「探す／直す」が押されていたら、ここで開く
  -- （OpenPopup と BeginPopup を同じ階層で呼ぶ。表の行の中では開かない）
  if app.link_request then
    local req = app.link_request
    app.link_request = nil
    if req.ask_ai then
      ui.shell_open(VM.ai_url(app.config:get_ai_choice(), req.name, req.vendor))
    end
    app.link_edit = { key = req.key, name = req.name, url = req.url or "", free = req.free == true }
    ImGui.OpenPopup(ctx, LINK_POPUP_ID)
  end

  -- モーダルにする: ブラウザからURLをコピーして戻り、窓の中をクリックしても
  -- 小窓が消えないようにするため（非モーダルだと外側のクリックで閉じてしまう）。
  if ImGui.BeginPopupModal(ctx, LINK_POPUP_ID, nil, ImGui.WindowFlags_AlwaysAutoResize) then
    local e = app.link_edit
    if e then
      ImGui.Text(ctx, e.name)
      ImGui.SetNextItemWidth(ctx, 420)
      local _, url = ImGui.InputText(ctx, "公式URLを貼り付け", e.url)
      e.url = url
      local rv, free = ImGui.Checkbox(ctx, "無料", e.free)
      if rv then e.free = free end
      if ImGui.Button(ctx, "確定") then
        local ok, err = VM.save_link(app.state, e.key, e.url, e.free, app.store, app.root, app.boot.now_iso())
        app.status = ok and ("リンクを登録しました: " .. e.name)
          or ("リンクを登録できませんでした: " .. tostring(err))
        app.pending_reload = true
        app.link_edit = nil
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "キャンセル") then
        app.link_edit = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

-- ============================================================
-- 「同じものとして扱う」小窓（≒の訂正）
-- ============================================================

local ALIAS_POPUP_ID = "同じものとして扱う"

local function reason_text(c)
  if c.reason == "class_id" then return "中身の識別番号が同じ" end
  return ("名前の違いが%d文字"):format(c.dist or 0)
end

local function save(app, key, canonical, message)
  local ok, err = VM.save_alias(app.state, key, canonical, app.store, app.root, app.boot.now_iso())
  app.status = ok and message or ("訂正できませんでした: " .. tostring(err))
  if ok then app.pending_reload = true end
  return ok
end

function M.alias_popup(ImGui, ctx, app, ui)
  if app.alias_request then
    local req = app.alias_request
    app.alias_request = nil
    if app.state then
      app.alias_edit = {
        key = req.key, name = req.name, vendor = req.vendor,
        info = VM.alias_info(app.state, req.key),
      }
      ImGui.OpenPopup(ctx, ALIAS_POPUP_ID)
    end
  end

  if ImGui.BeginPopupModal(ctx, ALIAS_POPUP_ID, nil, ImGui.WindowFlags_AlwaysAutoResize) then
    local e = app.alias_edit
    if e then
      ImGui.Text(ctx, ("%s（%s）"):format(e.name or "", e.vendor or ""))
      ImGui.TextWrapped(ctx,
        "名前が似ている別の行があります。同じプラグインなら「同じものにする」を押すと、" ..
        "以後この行にまとめて表示されます（全員に配られます）。")
      ImGui.Separator(ctx)

      local info = e.info or {}
      if #(info.candidates or {}) == 0 then
        ImGui.Text(ctx, "似た候補は見つかりませんでした。")
      end
      for i, c in ipairs(info.candidates or {}) do
        ImGui.PushID(ctx, "cand" .. i)
        ImGui.Text(ctx, ("%s（%s）"):format(c.name or "", c.vendor or ""))
        ImGui.Text(ctx, ("  持っている人: %s ／ %s")
          :format(table.concat(c.holders or {}, "・"), reason_text(c)))
        if ImGui.Button(ctx, "同じものにする") then
          -- 候補の側を、今開いている行へ寄せる。
          if save(app, c.key, e.key, ("「%s」を「%s」と同じものにしました"):format(c.name, e.name)) then
            app.alias_edit = nil
            ImGui.CloseCurrentPopup(ctx)
          end
        end
        ImGui.PopID(ctx)
        ImGui.Separator(ctx)
      end

      if #(info.aliased_in or {}) > 0 then
        ImGui.Text(ctx, "この行にまとめてあるもの:")
        for i, a in ipairs(info.aliased_in) do
          ImGui.PushID(ctx, "undo" .. i)
          ImGui.Text(ctx, "  " .. a.key)
          ImGui.SameLine(ctx)
          if ImGui.SmallButton(ctx, "別物に戻す") then
            if save(app, a.key, "", ("「%s」を別物に戻しました"):format(a.key)) then
              app.alias_edit = nil
              ImGui.CloseCurrentPopup(ctx)
            end
          end
          ImGui.PopID(ctx)
        end
        ImGui.Separator(ctx)
      end

      if ImGui.Button(ctx, "閉じる") then
        app.alias_edit = nil
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.EndPopup(ctx)
  end
end

return M
