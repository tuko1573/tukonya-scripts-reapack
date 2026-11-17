--[[
  ref_display.lua
  TUKONYA Reference — 「REFERENCE」窓の常駐ループ。
  Reference_Monitor_Popup.lua（v1）の見た目・窓位置の記憶・閉じ方をそのまま移したもの。
  違い: (1) ルーターは名前ではなく ref_core の判定（IXルーター＋設定）で探す
        (2) ルーターの状態を「Toggle」アクションのトグル状態（点灯）に写す
        (3) 止める合図（ExtState）を見る
  r / gfx は引数で受け取る（試験では偽物を渡す）。
--]]

local core = require("ref_core")
local tx = require("ref_text")

local M = {}

-- ▼ 見た目（元スクリプトと同じ値）
M.WIN_W, M.WIN_H = 360, 140
M.BG = { 0.149, 0.149, 0.141 }
M.FG = { 0.62, 0.80, 0.20 }
M.TEXT = tx.ja("WINDOW_TEXT")
M.FONT_FACE = "Arial"
M.MARGIN_W, M.MARGIN_H = 0.90, 0.78
M.POLL_EVERY = 3

M.EXT = "ReferenceMonitorPopup"          -- 窓位置（x/y/w/h）。元のスクリプトと同じ入れ物
M.CTL = "TUKONYA_Reference"              -- 止める合図
M.CTL_STOP = "stop"

--- 止める合図を出す（Uninstall Startup が使う）。動いていないときは出さない。
function M.request_stop(r, display_cmd)
  if display_cmd and r.GetToggleCommandStateEx(0, display_cmd) == 1 then
    r.SetExtState(M.CTL, M.CTL_STOP, "1", false)
    return true
  end
  return false
end

--- @param r     reaper テーブル
--- @param gfx   gfx テーブル
--- @param script_dir  このスクリプト群のフォルダ（Toggle のコマンド番号を引くため）
--- @return "already_running" | "started"
function M.run(r, gfx, script_dir)
  local _, _, sec, cmd = r.get_action_context()

  -- 二重起動ガード（元の挙動のまま: 動いているなら何もせず終わる）
  if r.GetToggleCommandStateEx(sec, cmd) == 1 then return "already_running" end

  r.SetToggleCommandState(sec, cmd, 1)
  r.RefreshToolbar2(sec, cmd)
  r.DeleteExtState(M.CTL, M.CTL_STOP, false)   -- 前回の取り残しの合図は捨てる

  local toggle_cmd = core.toggle_cmd(r, script_dir)

  local win_open, dismissed, was_ref, frame = false, false, false, 0
  local finished = false

  local function mirror(on)
    if not toggle_cmd then return end
    local v = on and 1 or 0
    -- 覚えておいた値ではなく、今の実際の状態と比べる（Toggle 自身が先に書き換えることがある）
    if r.GetToggleCommandStateEx(0, toggle_cmd) ~= v then
      r.SetToggleCommandState(0, toggle_cmd, v)
      r.RefreshToolbar2(0, toggle_cmd)
    end
  end

  local function save_pos()
    if not win_open then return end
    local _, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
    if ww and ww > 0 then
      r.SetExtState(M.EXT, "x", tostring(math.floor(wx)), true)
      r.SetExtState(M.EXT, "y", tostring(math.floor(wy)), true)
      r.SetExtState(M.EXT, "w", tostring(math.floor(ww)), true)
      r.SetExtState(M.EXT, "h", tostring(math.floor(wh)), true)
    end
  end

  local function open_window()
    local x = tonumber(r.GetExtState(M.EXT, "x"))
    local y = tonumber(r.GetExtState(M.EXT, "y"))
    local w = tonumber(r.GetExtState(M.EXT, "w")) or M.WIN_W
    local h = tonumber(r.GetExtState(M.EXT, "h")) or M.WIN_H
    if x and y then
      gfx.init(tx.ja("WINDOW_TITLE"), w, h, 0, x, y)
    else
      gfx.init(tx.ja("WINDOW_TITLE"), w, h)
    end
    win_open = true
  end

  local function close_window()
    save_pos()
    if win_open then gfx.quit() end
    win_open = false
  end

  local function draw()
    gfx.set(M.BG[1], M.BG[2], M.BG[3], 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    gfx.set(M.FG[1], M.FG[2], M.FG[3], 0.35)
    gfx.rect(0, 0, gfx.w, gfx.h, 0)
    local bold = string.byte("b")
    local tw = gfx.w * M.MARGIN_W
    local th = gfx.h * M.MARGIN_H
    local REF = 100
    gfx.setfont(1, M.FONT_FACE, REF, bold)
    local rw, rh = gfx.measurestr(M.TEXT)
    local fit_w = (rw > 0) and (REF * tw / rw) or REF
    local fit_h = (rh > 0) and (REF * th / rh) or REF
    local sz = math.max(8, math.floor(math.min(fit_w, fit_h)))
    gfx.setfont(1, M.FONT_FACE, sz, bold)
    gfx.set(M.FG[1], M.FG[2], M.FG[3], 1)
    gfx.x, gfx.y = 0, 0
    gfx.drawstr(M.TEXT, 1 | 4, gfx.w, gfx.h)
    gfx.update()
  end

  local function finish()
    if finished then return end
    finished = true
    close_window()
    r.set_action_options(8)
    r.SetToggleCommandState(sec, cmd, 0)
    r.RefreshToolbar2(sec, cmd)
    if toggle_cmd then
      r.SetToggleCommandState(0, toggle_cmd, 0)
      r.RefreshToolbar2(0, toggle_cmd)
    end
  end

  local function loop()
    if finished then return end
    frame = frame + 1

    local ref = was_ref
    if frame % M.POLL_EVERY == 0 then
      ref = core.is_reference_on(r)
      mirror(ref)
      if r.GetExtState(M.CTL, M.CTL_STOP) == "1" then
        r.DeleteExtState(M.CTL, M.CTL_STOP, false)
        finish()
        return
      end
    end

    if ref and not was_ref then dismissed = false end
    was_ref = ref

    if ref and not dismissed then
      if not win_open then open_window() end
      draw()
      local ch = gfx.getchar()
      if ch == -1 or ch == 27 then
        close_window()
        dismissed = true
      end
    else
      if win_open then close_window() end
    end

    r.defer(loop)
  end

  r.atexit(finish)

  was_ref = core.is_reference_on(r)
  mirror(was_ref)
  if was_ref then open_window(); draw() end

  loop()
  return "started"
end

return M
