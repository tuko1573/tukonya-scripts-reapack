--[[
  io.lua - mix-map: everything that reads or writes REAPER (the `reaper` table is injected so a
  fake can stand in for it in tests).  Writes to the project happen only in:
    renumber() (only when a slot is -1 / out of range / duplicated), insert(), remove()  -
  each inside ONE Undo_BeginBlock/Undo_EndBlock, and never when there is nothing to change.
--]]
local M = {}

M.GMEM = "TukoMixMap"
M.SUFFIX = "/TUKONYA_MixMap_Meter.jsfx"                 -- fx_ident must END with exactly this
-- where the meter may be installed: the owner's own folder, ReaPack (Tukonya Scripts), directly in Effects/
M.ADD_NAMES = { "JS:TUKONYA/TUKONYA_MixMap_Meter.jsfx", "JS:Tukonya Scripts/Utility/TUKONYA_MixMap_Meter.jsfx",
                "JS:TUKONYA_MixMap_Meter.jsfx" }
M.ADD_NAME = M.ADD_NAMES[1]
function M.add_meter(R, tr, pos)                       -- first name that loads wins; -1 if none
  for _, n in ipairs(M.ADD_NAMES) do
    local idx = R.TrackFX_AddByName(tr, n, false, pos)
    if idx and idx >= 0 then M.ADD_NAME = n; return idx end
  end
  return -1
end
M.SLOT_PARAM = 0                                         -- slider1 = slot
M.ROLE_PARAM = 1                                         -- slider2 = role: 0 = end of chain ("post"), 1 = head of a folder ("pre")
M.BUS_METERS = false                                     -- 2026-11-18: folders get no pre/post meters (true = the P1/P4 bus meters)
M.BASE0, M.STRIDE, M.MAXSLOT = 1024, 512, 255
-- masking grids (RMS 50 ms, fixed): after the slot table, 256 numbers per slot, cell = (band-1)*17 + (position-1)
M.MBASE, M.MSTRIDE = M.BASE0 + (M.MAXSLOT + 1) * M.STRIDE, 256
M.GMEM_VERSION = 2          -- gmem[0]: 1 = display grids only, 2 = + masking grids
M.MASK_EVERY = 0.1          -- seconds between reads of one track's masking grid (it is smoothed over 0.7 s anyway)
M.EXT_SECTION = "TukoMixMap"
M.GROUP_KEY = "P_EXT:TUKONYA_MixMap_group"   -- on a folder track (saved with the project): "1" = this folder is one group
-- How a folder's open/closed state is read from REAPER's mixer (MCP). "compact" (default since 2026-11-05) =
-- I_FOLDERCOMPACT (TCP; 0 = open), which the user's Folder Link keeps in step with the mixer (within 0.2 s);
-- "chunk" = the 2nd field of the track chunk line "BUSCOMP a b c d e" (1 = children hidden; same as
-- reaper/folder-link fl_core.lua). GetTrackStateChunk makes every plugin on the folder save its state, so its cost
-- grows with heavy plugins. See SPEC 4.1.
M.MIXER_MODE = "compact"
M.MIXER_EVERY = 0.7          -- seconds between reads of one folder
M.MIXER_PER_FRAME = 2        -- most folders read in one frame (oldest first, so many folders take turns)

-- 2nd field of "BUSCOMP a b c d e" in a track chunk (1 = children hidden in the mixer); nil when there is no such line
function M.parse_mixer_hidden(chunk)
  if type(chunk) ~= "string" then return nil end
  local _, b = chunk:match("\nBUSCOMP%s+(%-?%d+)%s+(%-?%d+)")
  if not b then _, b = chunk:match("^BUSCOMP%s+(%-?%d+)%s+(%-?%d+)") end
  return tonumber(b)
end

local function ends_with(s, suf) return #s >= #suf and s:sub(-#suf) == suf end
M.ends_with = ends_with

function M.new(R)
  R = R or reaper
  local self = { R = R }
  local seen, nextOrder = {}, 0     -- FX GUID -> order first seen (the older one keeps a duplicated slot)
  local attempts = {}               -- FX GUID -> renumber tries (stop after 3 so a failing write cannot loop)
  local nodes, nodeByGuid, markers, allinfo = {}, {}, {}, {}
  local lastScan, lastCount, needScan = -1e9, -1, true
  local saved = {}                  -- last value written to ExtState per key
  local hbSeen = {}                 -- slot -> { value, time it last moved } for the JSFX heartbeat
  local mcache = {}                 -- slot -> { t = time of the last read, cells = the grid read then }
  local mixer = {}                  -- folder guid -> { open = bool, t = time of the last read }
  self.mixer_mode = M.MIXER_MODE

  if R.gmem_attach then R.gmem_attach(M.GMEM) end

  -- ---------------------------------------------------------------- finding the meter FX
  -- call fn(fxindex, ident) for every non-container FX of the normal chain (containers recursed)
  local function walk(tr, fn)
    local function visit(idx, depth)
      local ok, ident = R.TrackFX_GetNamedConfigParm(tr, idx, "fx_ident")
      if not ok or not ident then return end
      if ident == "__builtin_container" then
        if depth > 8 then return end
        local okc, cnt = R.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
        for k = 0, (tonumber(cnt) or 0) - 1 do
          local oki, sub = R.TrackFX_GetNamedConfigParm(tr, idx, "container_item." .. k)
          if oki and tonumber(sub) then visit(math.floor(tonumber(sub)), depth + 1) end
        end
      else
        fn(idx, ident)
      end
    end
    for i = 0, R.TrackFX_GetCount(tr) - 1 do visit(i, 0) end   -- input FX (0x1000000) are not scanned
  end

  local function meters_on(tr)
    local list = {}
    -- exact file name, in a subfolder ("TUKONYA/...") or directly in Effects/ (ident without a slash)
    walk(tr, function(idx, ident)
      if ends_with(ident, M.SUFFIX) or ident == M.SUFFIX:sub(2) then list[#list + 1] = idx end
    end)
    return list
  end
  self.meters_on = meters_on

  local function read_slot(tr, fx)
    local v = R.TrackFX_GetParam(tr, fx, M.SLOT_PARAM)
    if type(v) ~= "number" then return -1 end
    local s = math.floor(v + 0.5)
    if math.abs(v - s) > 0.01 or s < 0 or s > M.MAXSLOT then return -1 end
    return s
  end

  -- 0 = "post" (end of the chain, drawn), 1 = "pre" (head of a folder's chain: its summed input). Old meters have no
  -- slider2 value other than the default 0, so they keep working as "post".
  local function read_role(tr, fx)
    local v = R.TrackFX_GetParam(tr, fx, M.ROLE_PARAM)
    if type(v) ~= "number" then return 0 end
    return v >= 0.5 and 1 or 0
  end
  self.read_role = read_role

  local function guid_of(tr) return R.GetTrackGUID(tr) end

  -- full scan: rebuilds markers and the node list (measured tracks + their parent folders)
  function self.scan()
    markers = {}
    local info, ordered = {}, {}
    allinfo = info
    for i = 0, R.CountTracks(0) - 1 do
      local tr = R.GetTrack(0, i)
      local g = guid_of(tr)
      local par = R.GetParentTrack(tr)
      local e = { tr = tr, guid = g, idx = i, parent = par and guid_of(par) or nil }
      info[g] = e; ordered[#ordered + 1] = e
      for _, fx in ipairs(meters_on(tr)) do
        local fg = R.TrackFX_GetFXGUID(tr, fx) or (g .. ":" .. fx)
        if not seen[fg] then nextOrder = nextOrder + 1; seen[fg] = nextOrder end
        local m = { tr = tr, fx = fx, tguid = g, fguid = fg, slot = read_slot(tr, fx), order = seen[fg], role = read_role(tr, fx) }
        if m.slot >= 0 then attempts[fg] = nil end      -- a valid number again (e.g. after undo): allow future repairs
        markers[#markers + 1] = m
        -- e.marker = the "post" meter (what is drawn), e.pre = the "pre" meter of a folder (bus input, phase P2)
        if m.role == 1 then if not e.pre then e.pre = m end
        elseif not e.marker then e.marker = m end
      end
    end
    for _, e in ipairs(ordered) do if e.parent and info[e.parent] then info[e.parent].folder = true end end
    -- group marks live on folders only (P_EXT in the project); a track's group = its nearest marked ancestor
    for _, e in ipairs(ordered) do
      if e.folder then
        local ok, v = R.GetSetMediaTrackInfo_String(e.tr, M.GROUP_KEY, "", false)
        e.marked = ok and v == "1" or false
      end
    end
    for _, e in ipairs(ordered) do
      local g, depth = e.parent, 0
      while g and info[g] and depth < 64 do
        if info[g].marked then e.group = g; break end
        g = info[g].parent; depth = depth + 1
      end
    end
    local keep = {}
    for _, e in ipairs(ordered) do
      if e.marker or e.pre then
        local g = e.guid
        while g and info[g] and not keep[g] do keep[g] = true; g = info[g].parent end
      end
    end
    nodes, nodeByGuid = {}, {}
    for _, e in ipairs(ordered) do
      if keep[e.guid] then nodes[#nodes + 1] = e; nodeByGuid[e.guid] = e end
    end
    needScan = false
    return markers
  end

  -- ---------------------------------------------------------------- slot numbers
  -- Decide which markers need a (new) number. Pure bookkeeping, writes nothing.
  local function plan_slots()
    local keeper, used = {}, {}
    for _, m in ipairs(markers) do
      if m.slot >= 0 then
        local k = keeper[m.slot]
        if not k or m.order < k.order then keeper[m.slot] = m end
      end
    end
    for s in pairs(keeper) do used[s] = true end
    local bad = {}
    for _, m in ipairs(markers) do
      if m.slot < 0 or keeper[m.slot] ~= m then bad[#bad + 1] = m end
    end
    table.sort(bad, function(a, b) return a.order < b.order end)
    local function free()
      for s = 0, M.MAXSLOT do if not used[s] then used[s] = true; return s end end
    end
    local changes = {}
    for _, m in ipairs(bad) do
      if (attempts[m.fguid] or 0) < 3 then
        local s = free()
        if s then changes[#changes + 1] = { m = m, slot = s } end
      end
    end
    return changes
  end

  -- Renumber -1 / out-of-range / duplicated slots. Nothing to fix = no write, no undo block.
  function self.renumber()
    local changes = plan_slots()
    if #changes == 0 then return 0 end
    R.Undo_BeginBlock()
    for _, c in ipairs(changes) do
      attempts[c.m.fguid] = (attempts[c.m.fguid] or 0) + 1
      R.TrackFX_SetParam(c.m.tr, c.m.fx, M.SLOT_PARAM, c.slot)
      c.m.slot = read_slot(c.m.tr, c.m.fx)
      if c.m.slot >= 0 then attempts[c.m.fguid] = nil end   -- the write stuck; only failing writes count toward the cap
    end
    R.Undo_EndBlock("mix-map: 番号の振り直し", -1)
    return #changes
  end

  -- called every frame: rescan when the project changed or every second
  function self.tick(now)
    local cnt = R.GetProjectStateChangeCount(0)
    if needScan or cnt ~= lastCount or now - lastScan >= 1.0 then
      lastScan, lastCount = now, cnt
      self.scan()
      self.renumber()
      lastCount = R.GetProjectStateChangeCount(0)    -- our own renumber must not trigger another scan
      return true
    end
    return false
  end

  -- ---------------------------------------------------------------- insert / remove (buttons)
  local function selected_tracks()
    local list = {}
    for i = 0, R.CountSelectedTracks(0) - 1 do list[#list + 1] = R.GetSelectedTrack(0, i) end
    return list
  end

  -- ---- folder helpers (use the info of the last scan(): parent GUID per track, children lists)
  local function children_of(g)
    local list = {}
    for _, e in pairs(allinfo) do if e.parent == g then list[#list + 1] = e end end
    table.sort(list, function(a, b) return a.idx < b.idx end)
    return list
  end

  -- "real FX": any FX of the normal chain except our meter that is neither bypassed nor offline. A container
  -- counts as one unit: a bypassed/offline container hides its contents, an empty one has nothing.
  local function has_real_fx(tr)
    local function real(idx, depth)
      local ok, ident = R.TrackFX_GetNamedConfigParm(tr, idx, "fx_ident")
      if not ok or not ident then return false end
      if R.TrackFX_GetEnabled(tr, idx) == false or R.TrackFX_GetOffline(tr, idx) == true then return false end
      if ident == "__builtin_container" then
        if depth > 8 then return false end
        local okc, cnt = R.TrackFX_GetNamedConfigParm(tr, idx, "container_count")
        for k = 0, (tonumber(cnt) or 0) - 1 do
          local oki, sub = R.TrackFX_GetNamedConfigParm(tr, idx, "container_item." .. k)
          if oki and tonumber(sub) and real(math.floor(tonumber(sub)), depth + 1) then return true end
        end
        return false
      end
      return not (ends_with(ident, M.SUFFIX) or ident == M.SUFFIX:sub(2))
    end
    for i = 0, R.TrackFX_GetCount(tr) - 1 do if real(i, 0) then return true end end
    return false
  end

  local function mark_of(tr)
    local ok, v = R.GetSetMediaTrackInfo_String(tr, M.GROUP_KEY, "", false)
    return ok and v == "1"
  end

  -- where the meters go for one selected folder F (2026-11-05, P1): every leaf track below F gets a "post" meter
  -- (position comes only from tracks before they are mixed). F itself and every folder below it that has real FX is a
  -- bus: it gets a "post" meter at the end of its chain and a "pre" meter at FX index 0 (its summed input), used for
  -- the bus ratio and never drawn. Folders without real FX get nothing. out = list of { tr =, bus = bool }.
  local function targets_below(F, out, seen_t)
    local function add(e, bus)
      local t = seen_t[e.guid]
      if not t then t = { tr = e.tr, bus = bus }; seen_t[e.guid] = t; out[#out + 1] = t
      elseif bus then t.bus = true end
    end
    -- 2026-11-18 the user: the pre/post meters on folders made the FX lists of folders cluttered and hard to use, so
    -- by default a folder walk puts meters on the leaves only (no bus meters, so no bus ratio). M.BUS_METERS = true
    -- brings the P1/P4 bus meters back. 外す still clears bus meters left over from the old way.
    local function visit(e, depth)
      if depth > 32 then return end
      if M.BUS_METERS and has_real_fx(e.tr) then add(e, true) end
      for _, c in ipairs(children_of(e.guid)) do
        if c.folder then visit(c, depth + 1) else add(c, false) end
      end
    end
    visit(allinfo[F], 0)
    -- ancestors of F (2026-11-05, P4): every folder above F (up to the top of the track list; the real master
    -- track is not a track here) that has real FX is also a bus and gets pre + post, so the processing of INST,
    -- 2MIXBUS, ... reaches the leaves. Ancestors are never marked as groups (the mark stays on the selected F).
    local g, depth = M.BUS_METERS and allinfo[F] and allinfo[F].parent, 0
    while g and allinfo[g] and depth < 64 do
      if has_real_fx(allinfo[g].tr) then add(allinfo[g], true) end
      g = allinfo[g].parent; depth = depth + 1
    end
  end

  -- which roles already have a meter on this track: { [0] = bool, [1] = bool }
  local function roles_on(tr)
    local has = {}
    for _, fx in ipairs(meters_on(tr)) do has[read_role(tr, fx)] = true end
    return has
  end

  -- add the meters the selected tracks lack. A plain selected track gets a "post" meter (as before). A selected
  -- folder gets the walk above instead and is marked as a group. Checks are per role: an existing end meter counts
  -- as the "post" one. returns added, failed, marked
  function self.insert()
    self.scan()
    local targets, seen_t, marks = {}, {}, {}
    for _, tr in ipairs(selected_tracks()) do
      local e = allinfo[guid_of(tr)]
      if e and e.folder then
        marks[#marks + 1] = tr
        targets_below(e.guid, targets, seen_t)
      elseif not seen_t[guid_of(tr)] then
        local t = { tr = tr, bus = false }
        seen_t[guid_of(tr)] = t; targets[#targets + 1] = t
      end
    end
    local todo, tomark, nAdd = {}, {}, 0
    for _, t in ipairs(targets) do
      local has = roles_on(t.tr)
      local job = { tr = t.tr, post = not has[0], pre = t.bus and not has[1] }
      if job.post or job.pre then
        todo[#todo + 1] = job
        nAdd = nAdd + (job.post and 1 or 0) + (job.pre and 1 or 0)
      end
    end
    for _, tr in ipairs(marks) do if not mark_of(tr) then tomark[#tomark + 1] = tr end end
    if #todo == 0 and #tomark == 0 then return 0, 0, 0 end
    local used = {}
    for _, m in ipairs(markers) do if m.slot >= 0 then used[m.slot] = true end end
    local function free() for s = 0, M.MAXSLOT do if not used[s] then used[s] = true; return s end end end
    local added, failed = 0, 0
    R.Undo_BeginBlock()
    for _, job in ipairs(todo) do
      local tr = job.tr
      -- "post" first (its index is the end), then "pre" at index 0 (inserting at 0 shifts the post meter by one,
      -- which is fine: its slot is already written)
      if job.post then
        local idx = M.add_meter(R, tr, -1000 - R.TrackFX_GetCount(tr))
        local s = free()
        if idx and idx >= 0 and s then
          R.TrackFX_SetParam(tr, idx, M.SLOT_PARAM, s)
          added = added + 1
        else failed = failed + 1 end
      end
      if job.pre then
        local idx = M.add_meter(R, tr, -1000)
        local s = free()
        if idx and idx >= 0 and s then
          R.TrackFX_SetParam(tr, idx, M.ROLE_PARAM, 1)
          R.TrackFX_SetParam(tr, idx, M.SLOT_PARAM, s)
          added = added + 1
        else failed = failed + 1 end
      end
    end
    for _, tr in ipairs(tomark) do R.GetSetMediaTrackInfo_String(tr, M.GROUP_KEY, "1", true) end
    R.Undo_EndBlock("mix-map: 測るプラグインを入れる", -1)
    needScan = true
    return added, failed, #tomark
  end

  -- delete only the meter FX (exact fx_ident suffix, containers included; both roles) from the selected tracks. A
  -- selected folder that is marked as a group loses the meters of everything below it and of itself, and its mark.
  function self.remove()
    self.scan()
    local targets, seen_t, unmark = {}, {}, {}
    local function add(tr) local g = guid_of(tr); if not seen_t[g] then seen_t[g] = true; targets[#targets + 1] = tr end end
    for _, tr in ipairs(selected_tracks()) do
      add(tr)
      local e = allinfo[guid_of(tr)]
      if e and e.folder and e.marked then
        unmark[#unmark + 1] = tr
        local function below(g, depth)
          if depth > 64 then return end
          for _, c in ipairs(children_of(g)) do add(c.tr); if c.folder then below(c.guid, depth + 1) end end
        end
        below(e.guid, 0)
      end
    end
    -- 2026-11-05 (P4): a folder above that got a "pre" meter only to carry its bus processing down (INST, 2MIXBUS,
    -- MASTER, ...) loses its meters too once nothing measured is left below it, so the last 外す leaves no meter in
    -- folders the user did not select. Repeated until nothing changes (clearing INST can leave 2MIXBUS empty).
    local function meter_left_below(g, depth)
      if depth > 64 then return false end
      for _, c in ipairs(children_of(g)) do
        if not seen_t[c.guid] and #meters_on(c.tr) > 0 then return true end
        if c.folder and meter_left_below(c.guid, depth + 1) then return true end
      end
      return false
    end
    local changed = true
    while changed do
      changed = false
      for i = 1, #targets do
        local e = allinfo[guid_of(targets[i])]
        local g, depth = e and e.parent, 0
        while g and allinfo[g] and depth < 64 do
          local a = allinfo[g]
          if not seen_t[g] and roles_on(a.tr)[1] and not meter_left_below(g, 0) then add(a.tr); changed = true end
          g = a.parent; depth = depth + 1
        end
      end
    end
    local todo = {}
    for _, tr in ipairs(targets) do if #meters_on(tr) > 0 then todo[#todo + 1] = tr end end
    if #todo == 0 and #unmark == 0 then return 0 end
    local removed = 0
    R.Undo_BeginBlock()
    for _, tr in ipairs(todo) do
      for _ = 1, 64 do
        local list = meters_on(tr)               -- re-scan after each delete: container addresses shift
        if #list == 0 then break end
        local hi = list[1]
        for _, idx in ipairs(list) do if idx > hi then hi = idx end end
        R.TrackFX_Delete(tr, hi)
        removed = removed + 1
      end
    end
    for _, tr in ipairs(unmark) do R.GetSetMediaTrackInfo_String(tr, M.GROUP_KEY, "", true) end
    R.Undo_EndBlock("mix-map: 測るプラグインを外す", -1)
    needScan = true
    return removed
  end

  -- ---------------------------------------------------------------- per-frame reading
  -- is the folder shown open in the mixer (children visible)? true / false, nil when unreadable
  local function read_mixer_open(tr)
    if self.mixer_mode == "chunk" then
      local ok, chunk = R.GetTrackStateChunk(tr, "", false)
      local hidden = ok and M.parse_mixer_hidden(chunk) or nil
      if hidden then return hidden == 0 end
    end
    local c = R.GetMediaTrackInfo_Value(tr, "I_FOLDERCOMPACT")
    return c == 0
  end
  -- refresh the stale folders, oldest first, a few per frame (GetTrackStateChunk is slow on FX-heavy tracks)
  local function refresh_mixer(now)
    local stale = {}
    for _, e in ipairs(nodes) do
      if e.folder then
        local m = mixer[e.guid]
        if not m then m = { open = false, t = -1e9 }; mixer[e.guid] = m end
        if now - m.t >= M.MIXER_EVERY then stale[#stale + 1] = m; m.e = e end
      end
    end
    table.sort(stale, function(a, b) return a.t < b.t end)
    for i = 1, math.min(#stale, M.MIXER_PER_FRAME) do
      local m = stale[i]
      if R.ValidatePtr2(0, m.e.tr, "MediaTrack*") then
        local o = read_mixer_open(m.e.tr)
        if o ~= nil then m.open = o end
      end
      m.t = now
    end
  end

  -- the display grid and the masking grid of one meter; nil, nil when it is not running (a bypassed/offline JSFX
  -- stops its heartbeat: after 0.5 s it is drawn as silent)
  local function read_grids(m, nb)
    local now = R.time_precise()
    if m.slot < 0 then return nil, nil end
    local hb = R.gmem_read(M.BASE0 + m.slot * M.STRIDE) or 0
    local h = hbSeen[m.slot]
    if not h then h = { v = hb, t = -1e9 }; hbSeen[m.slot] = h      -- first sight does not count as moving
    elseif hb ~= h.v then h.v, h.t = hb, now end
    if now - h.t >= 0.5 then return nil, nil end
    local base, cells = M.BASE0 + m.slot * M.STRIDE, {}
    for b = 1, nb do
      local row, a = {}, base + 8 + (b - 1) * 17
      for p = 1, 17 do row[p] = R.gmem_read(a + p - 1) or 0 end
      cells[b] = row
    end
    -- masking grid (RMS 50 ms): read at most every MASK_EVERY seconds, the last read is reused in between
    local mc = mcache[m.slot]
    if not mc or now - mc.t >= M.MASK_EVERY or #mc.cells ~= nb then
      local mb, mcells = M.MBASE + m.slot * M.MSTRIDE, {}
      for b = 1, nb do
        local row, a = {}, mb + (b - 1) * 17
        for p = 1, 17 do row[p] = R.gmem_read(a + p - 1) or 0 end
        mcells[b] = row
      end
      mc = { t = now, cells = mcells }; mcache[m.slot] = mc
    end
    return cells, mc.cells
  end

  -- returns the model input { sel=, tracks={...} } (see model.lua header)
  -- colour of a track as drawn (2026-11-18): its own colour when it has one that shows on the dark room; an uncoloured
  -- or near-black track takes the colour of the nearest folder above it that has one (the user: the drums inside DRUMS
  -- should be DRUMS' orange, not black and not grey); nothing above = the neutral grey.
  local function own_col(tr)
    local c = R.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
    if c ~= 0 and (math.floor(c) & 0x1000000) ~= 0 then
      local r, g, b = R.ColorFromNative(math.floor(c) & 0xffffff)
      if 0.299 * r + 0.587 * g + 0.114 * b >= 48 then return (r << 16) | (g << 8) | b end
    end
    return nil
  end
  local colCache
  local function col_of(guid)
    local hit = colCache[guid]
    if hit then return hit end
    local col, g, depth = nil, guid, 0
    while g and allinfo[g] and depth < 64 do
      local tr = allinfo[g].tr
      if R.ValidatePtr2(0, tr, "MediaTrack*") then col = own_col(tr) end
      if col then break end
      g = allinfo[g].parent; depth = depth + 1
    end
    col = col or 0x7d8397
    colCache[guid] = col
    return col
  end

  function self.frame(nb)
    refresh_mixer(R.time_precise())
    colCache = {}
    local anySolo = R.AnyTrackSolo(0)
    local list, byG = {}, {}
    for _, e in ipairs(nodes) do
      local tr = e.tr
      if not R.ValidatePtr2(0, tr, "MediaTrack*") then needScan = true
      else
        local _, name = R.GetTrackName(tr)
        local col = col_of(e.guid)
        local _, vol = R.GetTrackUIVolPan(tr)
        local _, p1, p2, pm = R.GetTrackUIPan(tr)
        if not pm or pm < 0 then pm = math.floor(R.GetMediaTrackInfo_Value(tr, "I_PANMODE")) end
        local m = e.marker
        -- group: GUID of the nearest ancestor folder marked with P_EXT (insert on a folder); nil = none (meters put in
        -- the old way). Tracks with the same group are one unit for the masking glow (model.lua).
        local t = { id = e.guid, group = e.group, expanded = e.folder and mixer[e.guid] and mixer[e.guid].open or nil, name = name, col = col, parent = e.parent, measured = m ~= nil,
                    vol = vol or 1, pan1 = p1 or 0, pan2 = p2 or 0, panmode = pm, send = 0, hasReturn = false,
                    muted = R.GetMediaTrackInfo_Value(tr, "B_MUTE") ~= 0,
                    soloed = R.GetMediaTrackInfo_Value(tr, "I_SOLO") > 0 }
        if m then
          -- t.send stays 0: the send amount no longer moves the depth (2026-11-03), so the sends are not read
          t.hasReturn = R.GetTrackNumSends(tr, -1) >= 1
          t.cells, t.mcells = read_grids(m, nb)
        end
        -- the "pre" meter of a bus folder (its summed input). Only kept for the bus ratio (phase P2), never drawn.
        if e.pre then t.preSlot = e.pre.slot; t.preCells, t.preMcells = read_grids(e.pre, nb) end
        if m then t.postSlot = m.slot end
        list[#list + 1] = t; byG[t.id] = t
      end
    end
    -- isBus: a folder with a measured ("post") track somewhere below it. Its own meters are never drawn (model.lua).
    for _, t in ipairs(list) do
      if t.measured then
        local g, d = t.parent, 0
        while g and byG[g] and d < 64 do byG[g].isBus = true; g = byG[g].parent; d = d + 1 end
      end
    end
    -- the selected track is always included, even when it does not measure, so the model can open its folder path
    local selg = R.GetSelectedTrack(0, 0)
    selg = selg and guid_of(selg) or nil
    if selg and not byG[selg] and allinfo[selg] and R.ValidatePtr2(0, allinfo[selg].tr, "MediaTrack*") then
      local e = allinfo[selg]
      local _, name = R.GetTrackName(e.tr)
      local par = e.parent      -- skip folders that are not nodes (unmeasured, nothing measured below)
      while par and not byG[par] and allinfo[par] do par = allinfo[par].parent end
      local t = { id = selg, name = name, parent = par, measured = false, audible = true, idx = e.idx,
                  col = col_of(selg), vol = 1, pan1 = 0, pan2 = 0, panmode = 0, send = 0, hasReturn = false }
      list[#list + 1] = t; byG[selg] = t
      local idxOf = {}
      for _, n in ipairs(nodes) do idxOf[n.guid] = n.idx end
      idxOf[selg] = e.idx
      table.sort(list, function(a, b) return (idxOf[a.id] or 0) < (idxOf[b.id] or 0) end)
    end
    -- audible: not muted (itself or any folder above); with a solo somewhere, only soloed tracks,
    -- tracks inside a soloed folder, and folders that contain a soloed track
    local soloBelow = {}
    for _, t in ipairs(list) do
      if t.soloed then
        local g = t.id
        while g and byG[g] do soloBelow[g] = true; g = byG[g].parent end
      end
    end
    for _, t in ipairs(list) do
      local muted, soloUp, g = false, false, t.id
      while g and byG[g] do
        if byG[g].muted then muted = true end
        if byG[g].soloed then soloUp = true end
        g = byG[g].parent
      end
      t.audible = (not muted) and ((not anySolo) or soloUp or soloBelow[t.id] or false)
    end
    -- transport for the name list's time average (model.lua): moving or not, where, which project
    local running, pos, proj
    if R.GetPlayState then
      local ps = R.GetPlayState()
      running = (ps & 2) == 0 and (ps & 5) ~= 0
      pos = R.GetPlayPosition2 and R.GetPlayPosition2() or nil
      proj = R.EnumProjects and tostring((R.EnumProjects(-1))) or nil
    end
    return { sel = selg, tracks = list, running = running, pos = pos, proj = proj }
  end

  -- click on a row of the name list: select exactly that track (by pointer, so equal names are no problem); never a toggle
  function self.pick(guid)
    local e = nodeByGuid[guid]
    if not e or not R.ValidatePtr2(0, e.tr, "MediaTrack*") then return end
    R.SetOnlyTrackSelected(e.tr)
  end

  -- click on a list row: select that track (click again on the selected one = deselect)
  function self.select(guid, selected)
    local e = nodeByGuid[guid]
    if not e or not R.ValidatePtr2(0, e.tr, "MediaTrack*") then return end
    if selected then R.SetTrackSelected(e.tr, false) else R.SetOnlyTrackSelected(e.tr) end
  end

  -- ---------------------------------------------------------------- gmem header / settings
  local MODE = { peak = 0, rms = 1 }
  function self.write_header(S, now)
    R.gmem_write(0, M.GMEM_VERSION)
    R.gmem_write(1, now)
    R.gmem_write(2, S.split)
    R.gmem_write(3, MODE[S.mode] or 0)
    R.gmem_write(4, S.atk); R.gmem_write(5, S.rls); R.gmem_write(6, S.win)
  end
  function self.close() R.gmem_write(1, 0) end

  function self.load_settings(defaults)
    local S = {}
    for k, d in pairs(defaults) do
      local raw = R.GetExtState(M.EXT_SECTION, k)
      local v = d
      if raw and raw ~= "" then
        if type(d) == "number" then v = tonumber(raw) or d
        elseif type(d) == "boolean" then v = (raw == "1")
        else v = raw end
      end
      S[k] = v; saved[k] = raw
    end
    return S
  end
  function self.save_settings(S)
    for k, v in pairs(S) do
      local raw = type(v) == "boolean" and (v and "1" or "0") or tostring(v)
      if saved[k] ~= raw then R.SetExtState(M.EXT_SECTION, k, raw, true); saved[k] = raw end
    end
  end

  return self
end

return M
