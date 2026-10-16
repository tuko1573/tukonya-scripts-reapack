--[[
  cl_lag.lua — TUKONYA Container Link: "lagging" plugins (pure Lua, no REAPER). 2026-10-10.
  A lagging plugin is one whose parameter READBACKS do not follow its state: after a project load or a vst_chunk write
  TrackFX_GetParamNormalized keeps returning old values (often the plugin defaults) while the state and the sound are
  right [M tests/probes/RESULTS_TR5_GAIN.md, TR5 EQ-81]. For such an ident the saved state (vst_chunk) is the only truth;
  its own params are never used as values (cl_params `synced`); a readback change is only the signal "this member was
  edited" (cl_params lag_signal → cl_blob), and the edit travels as a chunk spread.
  Sources: SEED (probed, tests/probes/RESULTS_LAG_SEED.md) + the learned file Data/TUKONYA_ChainLink/lag_class.txt, one line
  per ident: 1<TAB>ident<TAB>why<TAB>day. The file is never pruned and a line is never removed by the script (not un-learned
  silently); deleting it by hand is the reset. blob_class.txt is a different file (latency class, LRU-pruned).
  A seed key without "<" matches the plugin file name (the ident minus its folder and its "<hash{guid" tail), so the same
  entry works on every machine; a key with "<" must equal the ident.
--]]
local M = {}
M.FILE = "lag_class.txt"
M.EVIDENCE_NEEDED = 2        -- independent observations (≥ EVIDENCE_GAP apart) before a plugin is learned
M.EVIDENCE_GAP = 1.0

-- Seed: plugins probed on the MBP (REAPER 7.80) whose readbacks lag. See tests/probes/RESULTS_LAG_SEED.md.
M.SEED = {
  ["TR5 Black 76.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Brickwall Limiter.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 British Channel.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Bus Compressor.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 CSR Hall.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 CSR Inverse.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 CSR Plate.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 CSR Room.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Classic Clipper.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Classic Comp.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Classic EQ.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Classic Multi Band Limiter.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Comprexxor.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 De Esser.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Dyna-Mu.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQ-73.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQ-81.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQ-PA.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQ-PB.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQ-PG.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQP-1A.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 EQual.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Fame Studio Reverb.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Joe Chiccarelli Vocal Strip.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Leslie.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Linear Phase EQ.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Master EQ-432.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Mic Room.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 One.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Opto Comp.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Precision Comp-Limiter.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Quad Compressor.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Quad Image.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Quad Limiter.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Saturator X.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Space Delay.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Stealth Limiter.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Sunset Sound Studio Reverb.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 TASCAM 388.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 TASCAM PORTA ONE.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 TEAC A-3340S.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 TEAC A-6100 MKII.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Tape Echo.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Tape Machine 24.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Tape Machine 440.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Tape Machine 80.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 Tape Machine 99.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 The Farm Stone Room.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 VC-670.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 White 2A.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  ["TR5 White Channel.vst3"] = "seed 2026-10-10 MBP probe (REAPER 7.80): readback stays at the default after a chunk write and after a reopen",
  -- EL REY2 (Acustica Acqua, Nebula engine) [M tests/probes/RESULTS_ELREY.md, 2026-10-15]: an instance whose window was never opened is
  -- asleep (every readback 0, a valueless 818-byte state), readbacks are 0 while it loads and for ~0.2 s after, p9 "Reserved" stays stale,
  -- and on the Studio even an awake instance reads the default program. Its settings live in the saved state only.
  ["EL REY2.vst3"] = "seed 2026-10-15 MBP probe (REAPER 7.80): readbacks are 0 when asleep / loading, stale p9, the default program on the Studio; the state carries the settings",
}

-- ------------------------------------------------------------------ volatile UI fields (2026-10-15)
-- Some plugins keep UI-only fields inside their saved state that the plugin rewrites by itself, e.g. when the editor is
-- opened (TR5: <GuiScale ScaleRatioWidth=.. ScaleRatioHeight=../> in the XML tail of the decoded vst_chunk; opening ONE
-- instance's editor makes its chunk differ from every identical instance by 11 bytes [M tests/probes/LOG_tr5vol.txt]).
-- setState ignores the field, so a chunk copy does not carry it and a "spread until equal" never converges. Every chunk
-- comparison therefore goes through M.same / M.norm (cl_params P.same_state): the state is base64-decoded and these fields
-- are cut out before comparing. A normalised chunk is NEVER written anywhere, only compared and logged.
-- Data-driven: one row per plugin family; `family` is a Lua pattern on the plugin file name (M.base), `pats` are Lua
-- patterns removed from the decoded bytes (no "%" -captures needed).
M.MASKS = {
  { family = "^TR5 ", why = "editor GUI scale", pats = { "<GuiScale[^>]*/>" } },
  -- Nebula engine (Acustica Acqua: EL REY2, 2026-10-15): every instance has its own uuid="<32 hex>" in <nuwCustomChunkTreeData .../>, and
  -- dirty="0|1" is the preset-modified flag of the editor. A state copy, a duplicate and a new instance from a chunk with the same settings
  -- differ ONLY there (tests/probes/LOG_elsig.txt: equal after the cut, INIT vs edited program still differ). fam = true: also applied to an
  -- ident detected by the state signature (M.sniff), whatever its file name.
  -- 2026-10-15 (user repaired members with EL REY2's own preset load): presetname / presetuuid are not settings either, and the first
  -- 4 bytes of the state are its total length, so cutting bytes is not enough. The Nebula family therefore compares CONTENT (`extract`):
  -- the Nebula body (between "Nebula2" and "<?xml") + the XML without uuid / dirty / presetname / presetuuid + the JUCE tail. Never written.
  { family = "^EL REY2", fam = true, why = "Nebula per-instance uuid / dirty flag / preset name", extract = "nebula" },
}
local NEB_ATTRS = { "uuid", "dirty", "presetname", "presetuuid" }
--- the compared content of a decoded Nebula state; anything unexpected is returned unchanged (compared byte for byte)
local function extract_nebula(dec)
  local i = dec:find("Nebula2", 1, true)
  local j = i and dec:find("<?xml", i, true)
  if not j then return dec end
  local ks, ke = dec:find("<nuwCustomChunkTreeData[^>]*/>", j)
  if not ks then return dec end
  local el = dec:sub(ks, ke)
  for _, a in ipairs(NEB_ATTRS) do el = el:gsub("%s+" .. a .. '="[^"]*"', "") end
  el = el:gsub("%s+", " ")          -- the plugin re-wraps the element's lines after a preset load [M LOG_elundo_final.txt: 1431 -> 1507 bytes]
  return dec:sub(i, j - 1) .. "\1" .. dec:sub(j, ks - 1) .. el .. "\1" .. dec:sub(ke + 1)
end
local function apply_mask(m, dec)
  if m.extract == "nebula" then return extract_nebula(dec) end
  for _, pat in ipairs(m.pats) do dec = dec:gsub(pat, "") end
  return dec
end
M.CACHE_MAX = 64
M.HEADER_BYTES = 64          -- size fields at the start of a decoded VST3 state (diagnostics only)

-- ------------------------------------------------------------------ plugin family by state signature (2026-10-15)
-- A plugin whose decoded state carries "Nebula2" and "nuwCustomChunkTreeData" is a Nebula-engine (Acustica Acqua) plugin: its readbacks are
-- not its settings (see SEED "EL REY2.vst3"), so it is lagging whatever its file name, with the same mask and the same readiness rules.
-- The decision is per ident, kept for the session (module level because M.same / M.norm only get the ident), decided from the first
-- state that is read (cl_params.build / ready), also from an asleep instance (its 818-byte state has both strings).
M.FAM = {}              -- ident -> true  (detected by signature)
M.SNIFFED = {}          -- ident -> true/false (decided)
M.SNIFF_MAX = 300000    -- base64 chars; a bigger state is not decoded (and is not a Nebula state)
M.ASLEEP_BODY_MAX = 256 -- bytes between "Nebula2" and "<?xml": the asleep body is 192 [M LOG_elsig.txt]; an awake one is 750+
M.READY_NAMES = { "^EL REY2" }   -- file names that need the readiness rule before their name has been sniffed
function M.reset_family() M.FAM, M.SNIFFED = {}, {} end

--- decide the family of `ident` from one state read; true = Nebula family. A decided ident is not decoded again.
function M.sniff(ident, chunk)
  local d = M.SNIFFED[ident]
  if d ~= nil then return d end
  if type(chunk) ~= "string" or chunk == "" then return false end          -- nothing to decide from yet: try again with the next read
  local res = false
  if #chunk <= M.SNIFF_MAX then
    local dec = M.unb64(chunk) or chunk
    res = (dec:find("Nebula2", 1, true) ~= nil and dec:find("nuwCustomChunkTreeData", 1, true) ~= nil)
  end
  M.SNIFFED[ident] = res
  if res then M.FAM[ident] = true end
  return res
end

--- does this ident need the "state is ready" rule (never source / compare a state that is asleep, loading or still changing)?
function M.needs_ready(ident)
  if M.FAM[ident] then return true end
  local base = M.base(ident)
  for _, pat in ipairs(M.READY_NAMES) do if base:find(pat) then return true end end
  return false
end

--- is this saved state the valueless state of an instance whose window was never opened ("asleep")? A hint only: the real test
--- of a usable state is stability (cl_params.state_ok). Needs the Nebula body between "Nebula2" and "<?xml".
function M.asleep(chunk)
  if type(chunk) ~= "string" or chunk == "" or #chunk > M.SNIFF_MAX then return false end
  local dec = M.unb64(chunk) or chunk
  local i = dec:find("Nebula2", 1, true)
  local j = i and dec:find("<?xml", i, true)
  return (i ~= nil and j ~= nil and j - i <= M.ASLEEP_BODY_MAX) or false
end

local function mask_for(ident)
  local base = M.base(ident)
  for i, m in ipairs(M.MASKS) do
    if base:find(m.family) or (m.fam and M.FAM[ident]) then return i, m end
  end
end
M.mask_for = mask_for

local B64DEC
local function unb64(s)
  if not B64DEC then
    B64DEC = {}
    local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, 64 do B64DEC[a:byte(i)] = i - 1 end
  end
  local body = s:gsub("[%s=]+$", "")
  if #body == 0 or #body % 4 == 1 or body:find("[^A-Za-z0-9+/\r\n]") then return nil end    -- not base64: compared raw
  body = body:gsub("[\r\n]", "")
  local d, out, n = B64DEC, {}, 0
  local full = #body - #body % 4
  for i = 1, full, 4 do
    local a, b, c, e = body:byte(i, i + 3)
    local x = (d[a] << 18) | (d[b] << 12) | (d[c] << 6) | d[e]
    n = n + 1; out[n] = string.char(x >> 16, (x >> 8) & 255, x & 255)
  end
  local r = #body - full
  if r == 2 then
    local a, b = body:byte(full + 1, full + 2)
    n = n + 1; out[n] = string.char(((d[a] << 18) | (d[b] << 12)) >> 16)
  elseif r == 3 then
    local a, b, c = body:byte(full + 1, full + 3)
    local x = (d[a] << 18) | (d[b] << 12) | (d[c] << 6)
    n = n + 1; out[n] = string.char(x >> 16, (x >> 8) & 255)
  end
  return table.concat(out)
end
M.unb64 = unb64

local cache, ncache = {}, 0
--- the chunk as it is compared: base64-decoded with the volatile fields of the ident's family removed. An ident without a
--- mask (or a chunk that is not base64) is returned as it is, so every other plugin keeps its exact byte comparison.
function M.norm(ident, chunk)
  if type(chunk) ~= "string" or chunk == "" then return chunk end
  local mi, m = mask_for(ident)
  if not mi then return chunk end
  local c = cache[mi]
  if not c then c = {}; cache[mi] = c end
  local hit = c[chunk]
  if hit ~= nil then return hit end
  local dec = unb64(chunk)
  local out = chunk
  if dec then out = apply_mask(m, dec) end
  if ncache >= M.CACHE_MAX then cache, ncache = {}, 0; c = {}; cache[mi] = c end
  c[chunk] = out; ncache = ncache + 1
  return out
end

--- are two saved states the same state? Raw equality first (the common case, no decode), then the masked comparison.
--- An empty / missing chunk equals only an identical one (an unreadable state is never "the same" as a readable one).
function M.same(ident, a, b)
  if a == b then return true end
  if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return false end
  if not mask_for(ident) then return false end
  return M.norm(ident, a) == M.norm(ident, b)
end

local function hexasc(s, i, j)
  local hx, as = {}, {}
  for k = i, j do
    local c = s:byte(k)
    if c then hx[#hx + 1] = ("%02x"):format(c); as[#as + 1] = (c >= 32 and c < 127) and string.char(c) or "." end
  end
  return table.concat(hx, " "), table.concat(as)
end

--- diagnostics: the first differing decoded byte offset of two states (volatile fields removed) with `ctxn` bytes of context
--- on each side. One line, no tabs or newlines, bounded (≈ 2 * (ctxn*2*4) chars). nil when the states are the same.
function M.first_diff(ident, a, b, ctxn)
  ctxn = ctxn or 32
  if type(a) ~= "string" or type(b) ~= "string" or a == "" or b == "" then return nil end
  if M.same(ident, a, b) then return nil end
  local da, db = M.norm_decoded(ident, a), M.norm_decoded(ident, b)
  local isdec = unb64(a) ~= nil and unb64(b) ~= nil
  if not isdec then da, db = a, b end
  local n = math.min(#da, #db)
  local off = n + 1
  for i = 1, n do if da:byte(i) ~= db:byte(i) then off = i; break end end
  -- the first bytes of a VST3 state are size fields (header): when the two states differ in length they differ right there and
  -- say nothing about the setting. Report that briefly, then give the context at the first difference after the header.
  local note = ""
  local hdr = math.max(M.HEADER_BYTES, (da:find("<?xml", 1, true) or 1) - 1)    -- size fields come before the XML of the state
  if off <= hdr then
    local off2
    for i = hdr + 1, n do if da:byte(i) ~= db:byte(i) then off2 = i; break end end
    note = ("header differs at %d; "):format(off - 1)
    if off2 then off = off2 elseif #da ~= #db then off = hdr + 1; note = note .. "only the length differs after it; " end
  end
  local lo, hi = math.max(1, off - ctxn), off + ctxn - 1
  local ha, aa = hexasc(da, lo, math.min(hi, #da))
  local hb, ab = hexasc(db, lo, math.min(hi, #db))
  return ("%s %soffset %d (len %d/%d) from %d: A %s |%s| B %s |%s|"):format(isdec and "decoded" or "raw", note, off - 1, #da, #db, lo - 1, ha, aa, hb, ab)
end

--- decoded + masked bytes (the raw string when it is not base64)
function M.norm_decoded(ident, chunk)
  local dec = unb64(chunk)
  if not dec then return chunk end
  local _, m = mask_for(ident)
  if m then dec = apply_mask(m, dec) end
  return dec
end

function M.new() return { e = {}, seed = {}, dirty = false, cand = {}, keep = {} } end

--- the plugin file name of an ident: "/Library/.../TR5 EQ-81.vst3<512119323{5653..." → "TR5 EQ-81.vst3"
function M.base(ident)
  local s = tostring(ident or "")
  s = s:match("^([^<]*)") or s
  return s:match("([^/\\]*)$") or s
end

function M.parse(text)
  local s = M.new()
  for k, why in pairs(M.SEED) do s.seed[k] = why end
  for line in (text or ""):gmatch("[^\r\n]+") do
    local v, id, why, day = line:match("^(%d+)\t([^\t]+)\t([^\t]*)\t([%d%-]*)$")
    if v == "1" then s.e[id] = { why = why, day = day } else s.keep[#s.keep + 1] = line end   -- a line we cannot read is kept, not dropped
  end
  return s
end

function M.serialize(s)
  local ids = {}
  for id in pairs(s.e) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = {}
  for _, id in ipairs(ids) do out[#out + 1] = ("1\t%s\t%s\t%s"):format(id, ((s.e[id].why or ""):gsub("[\t\r\n]", " ")), s.e[id].day or "") end
  for _, l in ipairs(s.keep or {}) do out[#out + 1] = l end
  return #out > 0 and (table.concat(out, "\n") .. "\n") or ""
end

--- is this ident lagging? (seed, then learned)
function M.is(s, ident)
  if not s or not ident then return false end
  if s.e[ident] then return true end
  if s.seed[ident] or s.seed[M.base(ident)] then return true end
  if M.FAM[ident] then return true end
  return false
end

--- one observation of "chunk equal / set_blob changed no readback". Returns true when the ident has just been learned.
function M.evidence(s, ident, now, why, day)
  if not s or M.is(s, ident) then return false end
  local c = s.cand[ident]
  if not c then s.cand[ident] = { n = 1, t = now }; return false end
  if now - c.t < M.EVIDENCE_GAP then return false end
  c.n, c.t = c.n + 1, now
  if c.n >= M.EVIDENCE_NEEDED then
    s.e[ident] = { why = why or "observed", day = day or "" }
    s.dirty = true
    s.cand[ident] = nil
    return true
  end
  return false
end

return M
