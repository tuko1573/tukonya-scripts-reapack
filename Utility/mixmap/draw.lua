--[[
  draw.lua - mix-map window (ReaImGui 0.10 / Dear ImGui 1.92). Draws what model.update() produced and
  turns clicks into changes of `state.settings` or calls on `hooks`:
    hooks.select(id, wasSelected)   hooks.pick(id) (name list row: select only that track)   hooks.insert() -> added, failed   hooks.remove() -> removed
  D.new(ImGui, ctx, model) -> obj;  obj:frame(state, hooks, dt) -> keep_open
--]]
local D = {}

local FONT_FILES = {
  "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc",     -- Hiragino Kaku Gothic (macOS)
  "/System/Library/Fonts/Hiragino Sans GB.ttc",
  "C:\\Windows\\Fonts\\YuGothR.ttc", "C:\\Windows\\Fonts\\meiryo.ttc",
}

local function rgba(hex, a)   -- 0xRRGGBB, alpha 0..1 -> 0xRRGGBBAA
  a = a < 0 and 0 or (a > 1 and 1 or a)
  return ((hex & 0xffffff) << 8) | math.floor(a * 255 + 0.5)
end
local C = {
  bg = 0x0b0d12, panel = 0x12151d, line = 0x232838, fg = 0xd9dce6, dim = 0x7d8397, hudbg = 0x0e1118,
  segOn = 0x1f2535, segOff = 0x0e1118, segHover = 0x2a3248, grid = 0x1b2030, lh = 0x2f3750, lbl = 0x5a6280,
  frame = 0x3a4360, row = 0x232a3c,
}

-- the red glow: { radius factor, alpha at full strength, colour } from the outside in
local GLOW_LAYERS = { { 1.0, 0.07, 0xff3232 }, { 0.8, 0.10, 0xff3a32 }, { 0.6, 0.15, 0xff4538 }, { 0.4, 0.22, 0xff5a46 }, { 0.22, 0.30, 0xff7a60 } }

local SEG = {
  cam = { { "front", "正面" }, { "above", "少し上から" }, { "top", "真上" }, { "side", "横から" } },
  clash = { { "on", "マスキング表示" }, { "off", "なし" } },
  depth = { { "slow", "奥行き: 安定" }, { "fast", "瞬間の音量で動く" } },
  depthBy = { { "track", "奥行き: トラックごと" }, { "band", "帯域ごと" } },
  hl = { { "on", "選択を強調" }, { "off", "強調なし" } },
  split = { { "1", "Listenhub 5段" }, { "2", "各段を2分割" }, { "3", "各段を3分割" } },
  preset = { { "fast", "速い" }, { "ppm", "PPM" }, { "rms50", "RMS 50ms" }, { "rms300", "RMS 300ms" } },
  mode = { { "peak", "Peak" }, { "rms", "RMS" } },
}

-- "132 Hz" below 1 kHz, "2.4k" up to 10 kHz, "12k" above
function D.fmt_hz(f)
  if f < 1000 then return ("%d Hz"):format(math.floor(f + 0.5)) end
  if f < 9950 then return ("%.1fk"):format(f / 1000) end
  return ("%dk"):format(math.floor(f / 1000 + 0.5))
end

function D.new(ImGui, ctx, model)
  local self = { cam = nil, camTo = nil, status = nil, statusAt = 0, useJp = nil }
  local fonts = {}
  local math_min, math_max, abs = math.min, math.max, math.abs

  -- fonts must be created and attached before the first frame that uses them
  for _, f in ipairs(FONT_FILES) do
    local h = io.open(f, "rb")
    if h then
      h:close()
      local ok, font = pcall(ImGui.CreateFontFromFile, f, 0)
      if ok and font then fonts[#fonts + 1] = font end
      if #fonts > 0 then break end
    end
  end
  if #fonts == 0 then
    local ok, font = pcall(ImGui.CreateFont, "Hiragino Sans")
    if ok and font then fonts[1] = font end
  end
  for _, f in ipairs(fonts) do ImGui.Attach(ctx, f) end
  self.jpFont = fonts[1]

  -- SPEC 4.3: does the default font draw '音'? (a missing glyph has the width of '?')
  local function check_japanese()
    local ok, w1 = pcall(ImGui.CalcTextSize, ctx, "音")
    local ok2, w2 = pcall(ImGui.CalcTextSize, ctx, "?")
    local ok3, w3 = pcall(ImGui.CalcTextSize, ctx, "\u{FFFD}")   -- 1.92 may fall back to U+FFFD instead of '?'
    if not (ok and ok2) then return false end
    return w1 ~= w2 and (not ok3 or w1 ~= w3)
  end

  local function segwidth(items)
    local w = 0
    for _, it in ipairs(items) do w = w + (ImGui.CalcTextSize(ctx, it[2])) + 16 end
    return w
  end

  local function sbtn(label, active)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, rgba(active and C.segOn or C.segOff, active and 1 or 0.8))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, rgba(C.segHover, 1))
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, rgba(C.segHover, 1))
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(active and C.fg or C.dim, 1))
    local r = ImGui.Button(ctx, label)
    ImGui.PopStyleColor(ctx, 4)
    return r
  end

  -- segmented buttons at the current cursor; returns the clicked key or nil
  local function seg(id, items, cur)
    local clicked
    for i, it in ipairs(items) do
      if i > 1 then ImGui.SameLine(ctx, 0, 0) end
      if sbtn(it[2] .. "##" .. id .. it[1], it[1] == cur) then clicked = it[1] end
    end
    return clicked
  end

  -- ---------------------------------------------------------------- room
  local function room(dl, ox, oy, W, H, F, cam)
    local function P(x, y, z) local px, py, k = model.proj(cam, W, H, F, x, y, z); return ox + px, oy + py, k end
    local function line(a, b, col, th)
      local x1, y1 = P(a[1], a[2], a[3]); local x2, y2 = P(b[1], b[2], b[3])
      ImGui.DrawList_AddLine(dl, x1, y1, x2, y2, col, th or 1)
    end
    local gc = rgba(C.grid, 1)
    for i = 0, 8 do
      local z = i / 8
      line({ -1, 0, z }, { 1, 0, z }, gc); line({ -1, 1, z }, { 1, 1, z }, gc)
      line({ -1, 0, z }, { -1, 1, z }, gc); line({ 1, 0, z }, { 1, 1, z }, gc)
    end
    for i = 0, 4 do
      local x = -1 + i * 0.5
      line({ x, 0, 0 }, { x, 0, 1 }, gc); line({ x, 1, 0 }, { x, 1, 1 }, gc); line({ x, 0, 1 }, { x, 1, 1 }, gc)
    end
    local lc = rgba(C.lh, 1)
    for _, f in ipairs({ 60, 240, 900, 5000 }) do
      local y = model.fy(f)
      line({ -1, y, 0 }, { -1, y, 1 }, lc, 1.5); line({ -1, y, 1 }, { 1, y, 1 }, lc, 1.5); line({ 1, y, 1 }, { 1, y, 0 }, lc, 1.5)
    end
    local tc = rgba(C.lbl, 1)
    for _, e in ipairs({ { 20, "20" }, { 60, "60" }, { 240, "240" }, { 900, "900" }, { 5000, "5k" }, { 20000, "20k" } }) do
      local x, y = P(-1, model.fy(e[1]), 0)
      ImGui.DrawList_AddText(dl, x - 26, y - 7, tc, e[2])
    end
    local sn = self.snap
    if sn then      -- the octave of the name list, lightly, on the left wall (z 0..1) and its two edges
      local y0_, y1_ = model.fy(sn.lo), model.fy(sn.hi)
      y0_, y1_ = math_max(0, y0_), math_min(1, y1_)
      if y1_ > y0_ then
        -- left wall, back wall, right wall (same height, colour and opacity); the near edges get a line
        local fc, lc = rgba(0x8fb4ff, 0.10), rgba(0x8fb4ff, 0.6)
        local function quad(p1, p2, p3, p4)
          local ax, ay = P(p1[1], p1[2], p1[3]); local bx, by = P(p2[1], p2[2], p2[3])
          local cx, cy = P(p3[1], p3[2], p3[3]); local dx, dy = P(p4[1], p4[2], p4[3])
          ImGui.DrawList_AddTriangleFilled(dl, ax, ay, bx, by, cx, cy, fc)
          ImGui.DrawList_AddTriangleFilled(dl, ax, ay, cx, cy, dx, dy, fc)
        end
        quad({ -1, y0_, 0 }, { -1, y1_, 0 }, { -1, y1_, 1 }, { -1, y0_, 1 })
        quad({ -1, y0_, 1 }, { -1, y1_, 1 }, { 1, y1_, 1 }, { 1, y0_, 1 })
        quad({ 1, y0_, 1 }, { 1, y1_, 1 }, { 1, y1_, 0 }, { 1, y0_, 0 })
        for _, x in ipairs({ -1, 1 }) do
          local ax, ay = P(x, y0_, 0); local bx, by = P(x, y1_, 0)
          ImGui.DrawList_AddLine(dl, ax, ay, bx, by, lc, 2)
        end
      end
    end
    local lx, ly = P(-1, 0, 0); local rx, ry = P(1, 0, 0); local bx, by = P(0, 0, 1)
    ImGui.DrawList_AddText(dl, lx + 4, ly + 4, tc, "L"); ImGui.DrawList_AddText(dl, rx - 12, ry + 4, tc, "R")
    return P
  end

  -- one horizontal line: 7 segments whose alpha follows the mock's gradient, round ends, glow when focused
  local function bar(dl, P, F, x0, x1, y, z, thick, hex, al, w, glow)
    local ax, ay, ak = P(x0, y, z); local bx, by, bk = P(x1, y, z)
    local th = math_max(1.5, thick * 1.2 * F * (ak + bk) / 2)
    local edge = 1 - math_min(1, w) * 0.9
    if glow then
      ImGui.DrawList_AddLine(dl, ax, ay, bx, by, rgba(hex, al * 0.25), th + 4)
      ImGui.DrawList_AddCircleFilled(dl, ax, ay, (th + 4) / 2, rgba(hex, al * 0.25 * edge))
      ImGui.DrawList_AddCircleFilled(dl, bx, by, (th + 4) / 2, rgba(hex, al * 0.25 * edge))
    end
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    local ux, uy = 0, 0
    if len > 0 then ux, uy = dx / len, dy / len end
    local N = 7
    for s = 0, N - 1 do
      local t0, t1 = s / N, (s + 1) / N
      local tm = (t0 + t1) / 2
      local a = al * (edge + (1 - edge) * (1 - abs(2 * tm - 1)))
      local over = s < N - 1 and 0.5 or 0
      ImGui.DrawList_AddLine(dl, ax + dx * t0, ay + dy * t0, ax + dx * t1 + ux * over, ay + dy * t1 + uy * over, rgba(hex, a), th)
    end
    ImGui.DrawList_AddCircleFilled(dl, ax, ay, th / 2, rgba(hex, al * edge))
    ImGui.DrawList_AddCircleFilled(dl, bx, by, th / 2, rgba(hex, al * edge))
  end

  -- hover = {mx, my} (screen) or nil. Returns the line nearest to the cursor within 8 px: { x, z } (where on
  -- the line, and its depth), so the Hz readout can be inverted at the line's own depth.
  local function draw_scene(dl, ox, oy, W, H, state, cam, hover, avoid)
    local F = model.focal(W, H)
    local P = room(dl, ox, oy, W, H, F, cam)
    local sc, S, bands = state.scene, state.settings, state.bands
    if not sc then return end
    local pick, pickd = nil, 8
    -- far to near: the units' lines, then (when the masking display is on) the red glow cells on top of all lines,
    -- drawn on the front glass with the names (2026-11-05: behind the lines, and deep in the room, they vanished).
    local order = {}
    for _, u in ipairs(sc.units) do
      if u.a > 0.01 then local _, _, k = P(u.x, u.y, u.z); order[#order + 1] = { u = u, k = k } end
    end
    if S.clash then
      for _, g in ipairs(sc.glow or {}) do
        if g.d > 0.03 then
          local _, _, k = P(g.x, g.y, g.z)
          order[#order + 1] = { g = g, k = k, top = true }
        end
      end
    end
    table.sort(order, function(a, b)
      if (a.top or false) ~= (b.top or false) then return not a.top end
      return a.k < b.k
    end)
    local PSTEP = 2 / (model.NBIN - 1)
    for _, o in ipairs(order) do
      if o.g then
        -- soft red blob: nested ellipses, wide and faint outside, small and strong inside (ImGui has no radial
        -- gradient or additive blending; the mock's gradient is approximated by 5 steps)
        local g = o.g
        local B = bands[g.k]
        -- on the front glass, where the names are (2026-11-05 the user: the masking display was meant to be in
        -- front of everything, not inside the room at the sounds' depth). Same pan x frequency place as before.
        local GZ = -0.04
        local cx, cy = P(g.x, g.y, GZ)
        local ex = P(g.x + PSTEP * 2.4, g.y, GZ)
        local _, ey = P(g.x, g.y + model.bh(B) * 0.7, GZ)
        local rx, ry = math_max(5, abs(ex - cx)), math_max(6, abs(ey - cy))
        local d = g.d
        for _, L in ipairs(GLOW_LAYERS) do
          ImGui.DrawList_AddEllipseFilled(dl, cx, cy, rx * L[1], ry * L[1], rgba(L[3], L[2] * d))
        end
      else
      local u = o.u
      local focus = u.focus
      local base = u.a * (focus and 1 or 0.14) * (u.isReturn and 0.5 or 1)
      -- density (2026-11-05 P3): the faint fog first, then the cores on top, drawn like the old lines
      for i = 1, #bands do
        local B = bands[i]
        local dn = u.dn and u.dn[i]
        local lz = u.zb and u.zb[i] or u.z
        local cores = dn and dn.cores or u.b[i] or {}
        if dn and #dn.fog > 0 then
          local eb = 0
          for _, c in ipairs(cores) do if c.e > eb then eb = c.e end end
          if eb < 0.3 then eb = 0.3 end
          local fy = model.fy(B.c)
          for _, f in ipairs(dn.fog) do
            local al = base * f.al
            if al >= 0.015 then
              local fz = f.z or lz             -- a closed folder's child keeps its own depth (2026-11-05 夕)
              local ax, ay, ak = P(f.p0, fy, fz); local bx, by, bk = P(f.p1, fy, fz)
              local th = math_max(1.5, model.bh(B) * (0.12 + 0.6 * eb) * 0.8 * 1.2 * F * (ak + bk) / 2)
              ImGui.DrawList_AddLine(dl, ax, ay, bx, by, rgba(f.col or u.col, al), th)
            end
          end
        end
        for _, l in ipairs(cores) do
          if l.e >= 0.04 then
            local h = model.half(l.w)
            local cz = l.z or lz
            bar(dl, P, F, l.p - h, l.p + h, model.fy(B.c), cz, model.bh(B) * (0.12 + 0.6 * l.e), l.col or u.col,
                base * (0.3 + 0.7 * l.e), l.w, focus)
            if hover and base * (0.3 + 0.7 * l.e) > 0.05 then
              local ax, ay = P(l.p - h, model.fy(B.c), cz); local bx, by = P(l.p + h, model.fy(B.c), cz)
              local d, t = model.seg_dist(hover[1], hover[2], ax, ay, bx, by)
              if d <= pickd then pickd = d; pick = { x = l.p - h + t * 2 * h, z = cz } end
            end
          end
        end
      end
      end
    end
    local order2 = {}                      -- the units alone, for the names of the selected unit(s) below
    for _, o in ipairs(order) do if o.u then order2[#order2 + 1] = o end end
    order = order2
    -- masking labels in front of the room (on the glass plane): "Drums（Kick）× Bass／60-240". One per pair and
    -- stage. The labels of one stage share a height, so they are stacked downwards, strongest first.
    if S.clash then
      local FZ = -0.04
      local fc = rgba(C.frame, 1)
      local function seg3(a, b) local x1, y1 = P(a[1], a[2], FZ); local x2, y2 = P(b[1], b[2], FZ); ImGui.DrawList_AddLine(dl, x1, y1, x2, y2, fc, 1.2) end
      seg3({ -1, 0 }, { 1, 0 }); seg3({ 1, 0 }, { 1, 1 }); seg3({ 1, 1 }, { -1, 1 }); seg3({ -1, 1 }, { -1, 0 })
      -- 2026-11-05 (P4): a label is only drawn inside the front face of the room (screen box of the glass plane,
      -- and inside the canvas) and never over the response panel (bottom right) or the display panel (bottom left).
      -- It tries the right of the glow, then the left; if neither fits, it is dropped. Labels come strongest first
      -- per stage, so the weakest are the ones dropped. Thresholds are not touched.
      local fyT, fyB = math.huge, -math.huge
      for _, c in ipairs({ { -1, 0 }, { 1, 0 }, { 1, 1 }, { -1, 1 } }) do
        local _, yy = P(c[1], c[2], FZ)
        if yy < fyT then fyT = yy end
        if yy > fyB then fyB = yy end
      end
      local bxL, bxR = ox + 6, ox + W - 6
      local byT, byB = math_max(fyT, oy), math.min(fyB, oy + H)
      local function fits(x, y, w)
        if x < bxL or x + w > bxR or y < byT or y + 14 > byB then return false end
        for _, a in ipairs(avoid or {}) do
          if x < a[3] and x + w > a[1] and y < a[4] and y + 14 > a[2] then return false end
        end
        return true
      end
      local nInStage = {}
      for _, l in ipairs(sc.labels or {}) do
        local ymid = (model.fy(l.lo) + model.fy(l.hi)) / 2
        local lx, ly = P(l.x, ymid, FZ)
        local n = nInStage[l.stage] or 0
        local tw = (ImGui.CalcTextSize(ctx, l.text))
        local ty = ly - 7 + n * 15
        local tx = lx + 12
        if not fits(tx, ty, tw) then tx = lx - 12 - tw end
        if fits(tx, ty, tw) then
          nInStage[l.stage] = n + 1
          ImGui.DrawList_AddText(dl, tx, ty, rgba(0xffa096, l.i * l.d), l.text)
        end
      end
    end
    -- names of the selected unit(s)
    if sc.selValid then
      for _, o in ipairs(order) do
        local u = o.u
        if u.focus then
          local x, y = P(u.x + model.half(u.w) * 0.6, u.y, u.z)
          ImGui.DrawList_AddText(dl, x + 10, y - 17, rgba(0xe6e9f2, 1), u.name)
        end
      end
    end
    return pick
  end

  -- ---------------------------------------------------------------- right-hand list
  local function draw_list(dl, state, hooks, w, h)
    local sc = state.scene
    local rows = sc and sc.rows or {}
    for i, row in ipairs(rows) do
      local rx, ry = ImGui.GetCursorScreenPos(ctx)
      local rw = (ImGui.GetContentRegionAvail(ctx))
      local ix = rx + row.depth * 14
      if ImGui.Selectable(ctx, "##row" .. i, row.selected, 0, rw, 20) then
        local mx = ImGui.GetMousePos(ctx)
        if row.folder and mx < ix + 14 then hooks.toggle_open(row.id)   -- caret: open/close, several can stay open
        else hooks.select(row.id, row.selected) end
      end
      if row.folder then   -- caret: down when open, right when closed
        if row.open then ImGui.DrawList_AddTriangleFilled(dl, ix + 2, ry + 7, ix + 10, ry + 7, ix + 6, ry + 13, rgba(C.dim, 1))
        else ImGui.DrawList_AddTriangleFilled(dl, ix + 4, ry + 5, ix + 4, ry + 13, ix + 10, ry + 9, rgba(C.dim, 1)) end
      end
      ImGui.DrawList_AddCircleFilled(dl, ix + 20, ry + 10, 4.5, rgba(row.col, 1))
      ImGui.DrawList_AddText(dl, ix + 30, ry + 3, rgba(C.fg, 1), row.name)
      local mx = rx + rw - 50
      ImGui.DrawList_AddRectFilled(dl, mx, ry + 8, mx + 46, ry + 12, rgba(0x1b2030, 1), 2)
      if row.lv > 0.005 then ImGui.DrawList_AddRectFilled(dl, mx, ry + 8, mx + 46 * row.lv, ry + 12, rgba(C.dim, 1), 2) end
    end
    ImGui.Dummy(ctx, 1, 8)
    local bw = (ImGui.GetContentRegionAvail(ctx))
    if ImGui.Button(ctx, "選択トラックに入れる", bw, 0) then
      local added, failed, marked = hooks.insert()
      self.status = added == 0 and failed == 0 and (marked or 0) > 0 and "フォルダを1つのまとまりにしました（入れる所はもう入っています）。"
        or added == 0 and failed == 0 and "選択トラックには、もう入っています（または選択がありません）。"
        or ("%d 本に入れました%s"):format(added, failed > 0 and ("（%d 本は入れられませんでした）"):format(failed) or "")
      self.statusAt = os.time()
    end
    if ImGui.Button(ctx, "選択トラックから外す", bw, 0) then
      local n = hooks.remove()
      self.status = n == 0 and "選択トラックには、測るプラグインがありません。" or ("測るプラグインを %d 個外しました（Ctrl+Z で戻せます）"):format(n)
      self.statusAt = os.time()
    end
    if self.status and os.time() - self.statusAt < 8 then
      ImGui.Dummy(ctx, 1, 4)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(C.accent or 0x8fb4ff, 1))
      ImGui.TextWrapped(ctx, self.status)
      ImGui.PopStyleColor(ctx)
    end
  end

  -- ---------------------------------------------------------------- name list (the frozen snapshot, top of the right column)
  local SNAP_ROW = 30
  local function snap_height(sn) return 40 + 26 + math_max(1, #sn.rows) * SNAP_ROW + 8 end   -- +26: the trial slider
  local function fmt_range(sn)
    local lo, hi = math_max(20, sn.lo), math_min(20000, sn.hi)
    local function n(f) if f < 1000 then return ("%d"):format(math.floor(f + 0.5)) end return ("%.1fk"):format(f / 1000) end
    return n(lo) .. "–" .. n(hi) .. " Hz"
  end
  local function draw_snap(dl, sn, state, hooks, w)
    local rx0, ry0 = ImGui.GetCursorScreenPos(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(C.fg, 1))
    ImGui.Text(ctx, fmt_range(sn))
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx, w - 40)
    if ImGui.SmallButton(ctx, "×##snapx") then self.snap = nil; return end
    -- trial slider (2026-11-24, for the user to try): seconds a new order must hold before the list re-sorts.
    -- Kept on the window only (not saved); starts at model.SNAP_HOLD.
    ImGui.SetCursorScreenPos(ctx, rx0, ry0 + 24)
    ImGui.SetNextItemWidth(ctx, w - 110)
    local chg, v = ImGui.SliderDouble(ctx, "並び替えの待ち##snaphold", self.hold or model.SNAP_HOLD, 0.2, 3.0, "%.1f 秒")
    if chg then self.hold = v end
    local sel = state.scene and state.scene.sel
    ImGui.SetCursorScreenPos(ctx, rx0, ry0 + 26 + 26)
    if #sn.rows == 0 then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(C.dim, 1))
      ImGui.Text(ctx, "この高さで鳴っているトラックはありません")
      ImGui.PopStyleColor(ctx)
      return
    end
    for i, row in ipairs(sn.rows) do
      local x, y = ImGui.GetCursorScreenPos(ctx)
      local rw = (ImGui.GetContentRegionAvail(ctx))
      if ImGui.Selectable(ctx, "##srow" .. i, sel == row.id, 0, rw, SNAP_ROW - 2) then hooks.pick(row.id) end
      ImGui.DrawList_PushClipRect(dl, x, y, x + rw, y + SNAP_ROW, true)
      local nw = (ImGui.CalcTextSize(ctx, row.name))
      ImGui.DrawList_AddText(dl, x + 4, y + 2, rgba(C.fg, 1), row.name)
      if row.parent and row.parent ~= "" then ImGui.DrawList_AddText(dl, x + 4 + nw + 8, y + 2, rgba(C.dim, 0.75), row.parent) end
      local bx0, bw = x + 4, rw - 12
      ImGui.DrawList_AddRectFilled(dl, bx0, y + 19, bx0 + bw, y + 25, rgba(0x1b2030, 1), 2)
      ImGui.DrawList_AddRectFilled(dl, bx0, y + 19, bx0 + bw * row.len, y + 25, rgba(row.col, 0.95), 2)
      ImGui.DrawList_PopClipRect(dl)
    end
  end

  -- ---------------------------------------------------------------- one frame
  function self:frame(state, hooks, dt)
    local S = state.settings
    if self.cam == nil then
      local c = model.CAMS[S.cam] or { yaw = S.yaw, pitch = S.pitch }
      self.cam = { yaw = c.yaw, pitch = c.pitch }; self.camTo = { yaw = c.yaw, pitch = c.pitch }
    end
    if self.useJp == nil then self.useJp = check_japanese() end   -- default font first
    local usefont = (not self.useJp) and self.jpFont or nil
    if usefont then ImGui.PushFont(ctx, usefont, 13) end

    ImGui.SetNextWindowSize(ctx, 1060, 680, ImGui.Cond_FirstUseEver)
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, rgba(C.bg, 1))
    local visible, open = ImGui.Begin(ctx, "TUKONYA Mix Map###TukoMixMap", true,
      ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse)
    if visible then
      local dl = ImGui.GetWindowDrawList(ctx)
      local aw, ah = ImGui.GetContentRegionAvail(ctx)
      local x0, y0 = ImGui.GetCursorScreenPos(ctx)
      local lw = math_max(200, aw - 240 - 12)
      local x1, y1 = x0 + lw, y0 + ah

      -- room canvas (drag = turn the view). Hit-testing goes by submission order, so without AllowOverlap this
      -- full-size button would take every click meant for the HUD and the response panel drawn on top of it.
      ImGui.SetNextItemAllowOverlap(ctx)
      ImGui.InvisibleButton(ctx, "##room", lw, ah, ImGui.ButtonFlags_MouseButtonLeft | ImGui.ButtonFlags_MouseButtonRight)
      -- left drag turns the view (4 px dead zone); right press opens the name list at that height and, while held,
      -- the list follows the mouse height (fine-tune), fixed where the button is released
      if ImGui.IsItemActivated(ctx) then
        local dx0, dy0 = ImGui.GetMousePos(ctx)
        self.down = { dx0 or 0, dy0 or 0, moved = false, right = ImGui.IsMouseDown(ctx, ImGui.MouseButton_Right) }
      end
      local rightHeld = false
      if self.down then
        local mx_, my_ = ImGui.GetMousePos(ctx)
        if mx_ and (abs(mx_ - self.down[1]) >= 4 or abs(my_ - self.down[2]) >= 4) then self.down.moved = true end
        rightHeld = self.down.right
        if ImGui.IsItemDeactivated(ctx) then self.down = nil end
      end
      if ImGui.IsItemActive(ctx) and self.down and self.down.moved and not self.down.right then
        local mdx, mdy = ImGui.GetMouseDelta(ctx)
        if mdx ~= 0 or mdy ~= 0 then
          self.camTo.yaw = model.clamp(self.camTo.yaw + mdx * 0.006, -1.5, 1.5)
          self.camTo.pitch = model.clamp(self.camTo.pitch + mdy * 0.006, -0.2, 1.5)
          S.cam = "custom"; S.yaw, S.pitch = self.camTo.yaw, self.camTo.pitch
        end
      end
      self.cam.yaw = model.smooth(self.cam.yaw, self.camTo.yaw, dt, 8, 8)
      self.cam.pitch = model.smooth(self.cam.pitch, self.camTo.pitch, dt, 8, 8)
      -- response panel rectangle (bottom right; drawn further down)
      local pw, ph = 262, S.mode == "peak" and 150 or 124
      local px, py = x1 - 12 - pw, y1 - 30 - ph
      local qw, qh = 250, 120                     -- display panel rectangle (bottom left)
      local qx, qy = x0 + 12, y1 - 30 - qh

      -- mouse over the room (not over the response panel, not from straight above): the Hz readout below
      local hover
      if S.cam ~= "top" and self.cam.pitch < 1.2 then
        local mx, my = ImGui.GetMousePos(ctx)
        if mx and mx >= x0 and mx <= x1 and my >= y0 and my <= y1
           and ((self.down and self.down.right) or     -- a right drag keeps following over the panels
                (not (mx >= px and mx <= px + pw and my >= py and my <= py + ph)
                 and not (mx >= qx and mx <= qx + qw and my >= qy and my <= qy + qh))) then hover = { mx, my } end
      end

      ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, rgba(C.bg, 1), 6)
      ImGui.DrawList_PushClipRect(dl, x0, y0, x1, y1, true)
      local pick = draw_scene(dl, x0, y0, lw, ah, state, self.cam, hover, { { px, py, px + pw, py + ph }, { qx, qy, qx + qw, qy + qh } })
      ImGui.DrawList_PopClipRect(dl)
      ImGui.DrawList_AddRect(dl, x0, y0, x1, y1, rgba(C.line, 1), 6)

      -- Hz at the mouse: draw list + mouse position only (no item, so no click is taken). Near a drawn line
      -- (8 px) the height is inverted at that line's own depth; elsewhere through the wall tick marks
      -- (same proj/fy). Not shown from straight above.
      if hover then
        local F = model.focal(lw, ah)
        local f
        if pick then f = model.hz_at_screen(self.cam, lw, ah, F, hover[2] - y0, pick.x, pick.z) end
        f = f or model.hz_at_screen(self.cam, lw, ah, F, hover[2] - y0)
        if f then
          local mx, my = hover[1], hover[2]
          local txt = D.fmt_hz(f)
          local tw = (ImGui.CalcTextSize(ctx, txt))
          ImGui.DrawList_AddRectFilled(dl, mx + 12, my - 20, mx + 20 + tw, my - 2, rgba(C.hudbg, 0.85), 3)
          ImGui.DrawList_AddText(dl, mx + 16, my - 19, rgba(C.fg, 1), txt)
          if rightHeld then self.snap = model.snapshot(state, f) end
        end
      end
      if self.snap and not rightHeld then self.snap = model.snap_follow(state, self.snap, self.hold) end
      if S.cam == "top" or (ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)) then
        self.snap = nil
      end

      -- HUD buttons (wrap to the next line when the row is full)
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 8, 4)
      ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 3)
      local cx, cy = x0 + 12, y0 + 10
      local function hud(id, cur)
        local items = SEG[id]
        local w = segwidth(items)
        if cx + w > x1 - 12 and cx > x0 + 12 then cx = x0 + 12; cy = cy + 27 end
        ImGui.SetCursorScreenPos(ctx, cx, cy)
        local r = seg(id, items, cur)
        cx = cx + w + 6
        return r
      end
      local r = hud("cam", S.cam)
      if r then
        local c = model.CAMS[r]; self.camTo = { yaw = c.yaw, pitch = c.pitch }; S.cam = r; S.yaw, S.pitch = c.yaw, c.pitch
        S.depthBy = (r == "top") and "track" or "band"   -- a view comes with its depth mode; the depth button still overrides
      end
      r = hud("clash", S.clash and "on" or "off"); if r then S.clash = (r == "on") end
      r = hud("depth", S.depthFast and "fast" or "slow"); if r then S.depthFast = (r == "fast") end
      r = hud("depthBy", S.depthBy); if r then S.depthBy = r end
      r = hud("split", tostring(S.split)); if r then S.split = tonumber(r) end
      r = hud("hl", S.highlight and "on" or "off"); if r then S.highlight = (r == "on") end

      -- response panel (bottom right)
      ImGui.DrawList_AddRectFilled(dl, px, py, px + pw, py + ph, rgba(C.hudbg, 0.8), 4)
      ImGui.DrawList_AddRect(dl, px, py, px + pw, py + ph, rgba(C.line, 1), 4)
      ImGui.SetCursorScreenPos(ctx, px + 8, py + 8)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(C.dim, 1))
      ImGui.Text(ctx, "反応")
      ImGui.PopStyleColor(ctx)
      ImGui.SetCursorScreenPos(ctx, px + 8, py + 28)
      r = seg("preset", SEG.preset, S.preset)
      if r then
        for k, v in pairs(model.PRESETS[r]) do S[k] = v end
        S.preset = r
      end
      ImGui.SetCursorScreenPos(ctx, px + 8, py + 56)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, rgba(C.dim, 1))
      ImGui.Text(ctx, "検出")
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx, 0, 10)
      r = seg("mode", SEG.mode, S.mode)
      if r then S.mode = r; S.preset = "custom" end
      local function slider(label, key, lo, hi, y)
        ImGui.SetCursorScreenPos(ctx, px + 8, y)
        ImGui.SetNextItemWidth(ctx, 120)
        local ch, v = ImGui.SliderInt(ctx, label .. "##" .. key, S[key], lo, hi, "%d ms")
        if ch then S[key] = v; S.preset = "custom" end
      end
      if S.mode == "peak" then
        slider("立ち上がり", "atk", 0, 100, py + 86)
        slider("戻り", "rls", 20, 2000, py + 114)
      else
        slider("平均の長さ", "win", 10, 1000, py + 86)
      end

      -- display panel (bottom left, 2026-11-05 P3): 点感 and the masking glow levels
      ImGui.DrawList_AddRectFilled(dl, qx, qy, qx + qw, qy + qh, rgba(C.hudbg, 0.8), 4)
      ImGui.DrawList_AddRect(dl, qx, qy, qx + qw, qy + qh, rgba(C.line, 1), 4)
      local function dslider(label, key, lo, hi, fmt, y)
        ImGui.SetCursorScreenPos(ctx, qx + 8, y)
        ImGui.SetNextItemWidth(ctx, 150)
        local ch, v = ImGui.SliderDouble(ctx, label .. "##" .. key, S[key], lo, hi, fmt)
        if ch then S[key] = v end
      end
      dslider("点感", "crisp", 0, 1, "%.2f", qy + 8)
      dslider("光り始め", "glowFloor", -70, -20, "%.0f dB", qy + 36)
      dslider("最大", "glowFull", -40, 0, "%.0f dB", qy + 64)
      dslider("名前", "labelDb", -60, -10, "%.0f dB", qy + 92)
      if S.glowFull < S.glowFloor + 1 then S.glowFull = S.glowFloor + 1 end
      ImGui.PopStyleVar(ctx, 2)

      -- track list (right)
      ImGui.SetCursorScreenPos(ctx, x1 + 12, y0)
      ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, rgba(C.panel, 1))
      ImGui.PushStyleColor(ctx, ImGui.Col_Border, rgba(C.line, 1))
      local listY, listH = y0, ah
      if self.snap then      -- name list on top; the track list below it gets what is left
        local sh = snap_height(self.snap)
        if ImGui.BeginChild(ctx, "##snap", 240, sh, ImGui.ChildFlags_Borders, ImGui.WindowFlags_NoScrollbar) then
          draw_snap(ImGui.GetWindowDrawList(ctx), self.snap, state, hooks, 240)
          ImGui.EndChild(ctx)
        end
        listY, listH = y0 + sh + 8, math_max(80, ah - sh - 8)
        ImGui.SetCursorScreenPos(ctx, x1 + 12, listY)
      end
      if ImGui.BeginChild(ctx, "##list", 240, listH, ImGui.ChildFlags_Borders) then
        draw_list(ImGui.GetWindowDrawList(ctx), state, hooks, 240, listH)
        ImGui.EndChild(ctx)
      end
      ImGui.PopStyleColor(ctx, 2)
      ImGui.End(ctx)
    end
    ImGui.PopStyleColor(ctx)
    if usefont then ImGui.PopFont(ctx) end
    return open
  end

  return self
end

return D
