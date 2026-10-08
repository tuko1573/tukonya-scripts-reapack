--[[
  cl_link.lua — TUKONYA Container Link: LINK request channels (pure Lua; DESIGN_V2 §4 + DESIGN_V2_REVIEW MUST 6).

  Two ways in, one way out per channel:
  - marker JSFX button → gmem (namespace TUKONYA_ChainLink, unchanged from v1):
      [32] req_seq (JSFX: atomic_add, written last)  [33] req_ch  [34] req_nonce  [39] req_stamp (= [40] at press time)
      [35] ack_seq  [36] ack_code (main: code first, then seq)
      [37] nonce counter (main seeds 1000 × random(100..9999) at start; JSFX: nonce = atomic_add([37], 1))
      [40] main clock (main writes its time_precise() every tick; the JSFX copies it into [39] → the request age is
           judged on the main's own clock, no JSFX/Lua clock equivalence assumed)
    The JSFX also puts the nonce into its hidden slider3 (bare assignment: 0 undo / 0 state count [M probe b]); the main
    finds the pressed marker by Ch + slider3 == nonce.
  Ch picker / rename (2026-10-08): a second region, far from [0..40] (see L.G2): per-Ch "tracks with a marker on this Ch"
  counts, the lowest free Ch, per-Ch names as UTF-8 bytes (one byte per slot) behind a change counter written LAST, and a
  rename request (rn_seq written last by the JSFX; same MUST 6 rules as LINK: seeded at start, stamped with [40], expired);
  PK_* = "a Ch was picked in the list" notice (new Ch, stamp [40], seq written last): the main makes ONE named undo entry for it
  (an API/@gfx slider change alone makes none, MBP 2026-10-08, and a later Ctrl+Z would silently take the Ch back with it).
  RN_BUSY = 1 while the input window is open (the loop is blocked: the markers must not report 「スクリプト停止中」).
  - action "TUKONYA_Container Link - LINK (selected track)" → ExtState section TUKONYA_ChainLink:
      key link_req = "id|time|tguid,tguid,…"   (time = the action's time_precise(): same clock as the main)
      key link_res = "id|code|text"            (main → action)
  MUST 6: the main seeds last_seq from gmem[32] at start and never acts on that value; requests older than MAX_AGE are
  dropped (logged, acked as EXPIRED); the action deletes its own link_req on timeout; a JSFX whose ack_seq is overtaken
  by a newer seq treats its request as superseded (no timeout text).
--]]
local L = {}

L.G = { SEQ = 32, CH = 33, NONCE = 34, ACK_SEQ = 35, ACK_CODE = 36, CTR = 37, STAMP = 39, CLOCK = 40 }
-- Ch picker region. VER = change counter (main writes it after every other slot of a publish; the JSFX re-reads it after
-- copying and retries on a mismatch). USE[ch] = number of TRACKS whose marker is set to the Ch (any marker state; NOT the
-- linked count of [1..16]). FREE = lowest Ch 1..16 with USE 0, 0 = none. NLEN[ch] = byte length of the name, NAME[ch] bytes.
-- slot of USE[ch] = USE + ch (1001..1016), NLEN[ch] = NLEN + ch (1020..1035), NAME[ch][i] = NAME + (ch-1) * STRIDE + i - 1
L.G2 = { VER = 1000, USE = 1000, FREE = 1017, NLEN = 1019, NAME = 1100, STRIDE = 128, MAXBYTES = 120,
         RN_SEQ = 1040, RN_CH = 1041, RN_STAMP = 1042, RN_ACK_SEQ = 1043, RN_ACK_CODE = 1044, RN_BUSY = 1045,
         PK_CH = 1046, PK_STAMP = 1047, PK_SEQ = 1048 }
L.RN = { DONE = 0, CANCELLED = 1, EXPIRED = 2, FAILED = 3, UNCHANGED = 4 }
L.MAX_AGE = 2.0
L.NONCE_BASE = 100000

L.CODE = { DONE = 0, HELD = 1, SINGLE = 2, NOT_MEMBER = 3, FAILED = 4, EXPIRED = 5, NO_CONTAINER = 6, HELD_PLAY = 7 }
L.TEXT = {
  [0] = "LINK しました",
  [1] = "録音が止まったら LINK します",
  [2] = "同じ Ch のコンテナがほかにありません",
  [3] = "このコンテナはつながっていないので LINK できません（Link Ch を確かめてください）",
  [4] = "LINK できませんでした",
  [5] = "時間切れで LINK しませんでした。もう一度どうぞ",
  [6] = "選んだトラックに Link Ch の付いたコンテナがありません",
  [7] = "停止すると LINK します",
}

--- remember the current seq without acting on it (MUST 6: a request left in gmem by an earlier run is never executed)
function L.gmem_init(state, read)
  state.last_seq = read(L.G.SEQ) or 0
end

--- a new request since the last poll, or nil. Several presses between two polls: only the latest is in gmem
--- (the earlier JSFX sees ack_seq > its seq = superseded); `skipped` counts them for the log.
function L.gmem_poll(state, read)
  local s = read(L.G.SEQ) or 0
  if state.last_seq == nil then state.last_seq = s; return nil end
  if s == state.last_seq then return nil end
  local skipped = s - state.last_seq - 1
  if skipped < 0 then skipped = 0 end
  state.last_seq = s
  return { via = "gmem", seq = s, ch = math.floor((read(L.G.CH) or 0) + 0.5), nonce = read(L.G.NONCE) or 0,
           t = read(L.G.STAMP) or 0, skipped = skipped }
end

--- remember the current rename seq without acting on it (MUST 6)
function L.rn_init(state, read) state.rn_last = read(L.G2.RN_SEQ) or 0 end

--- a new rename request since the last poll, or nil (several between two polls: the latest wins, like LINK)
function L.rn_poll(state, read)
  local s = read(L.G2.RN_SEQ) or 0
  if state.rn_last == nil then state.rn_last = s; return nil end
  if s == state.rn_last then return nil end
  state.rn_last = s
  return { via = "gmem", seq = s, ch = math.floor((read(L.G2.RN_CH) or 0) + 0.5), t = read(L.G2.RN_STAMP) or 0 }
end

--- the same for the Ch-pick notice
function L.pk_init(state, read) state.pk_last = read(L.G2.PK_SEQ) or 0 end
function L.pk_poll(state, read)
  local s = read(L.G2.PK_SEQ) or 0
  if state.pk_last == nil then state.pk_last = s; return nil end
  if s == state.pk_last then return nil end
  state.pk_last = s
  return { via = "gmem", seq = s, ch = math.floor((read(L.G2.PK_CH) or 0) + 0.5), t = read(L.G2.PK_STAMP) or 0 }
end

--- undo text of a Ch pick: "Container Link: Link Ch 4" / "Container Link: Link Ch Off"
function L.pick_desc(ch) return ("Container Link: Link Ch %s"):format(ch == 0 and "Off" or tostring(ch)) end

--- a name as it goes into gmem / the dialog: control characters → space, cut at a UTF-8 character boundary to MAXBYTES.
function L.name_bytes(s, max)
  max = max or L.G2.MAXBYTES
  s = tostring(s or ""):gsub("[\0-\31\127]", " ")
  if #s <= max then return s end
  local cut = max
  -- the first byte NOT kept must not be a continuation byte (10xxxxxx), else the cut splits a character: step back
  while cut > 0 do
    local b = s:byte(cut + 1)
    if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
  end
  return s:sub(1, cut)
end

--- the lowest Ch 1..16 nobody uses (uses[ch] = number of tracks), 0 = none
function L.free_ch(uses)
  for ch = 1, 16 do if (uses[ch] or 0) == 0 then return ch end end
  return 0
end

function L.encode_req(id, t, guids) return ("%s|%.6f|%s"):format(id, t, table.concat(guids, ",")) end

function L.decode_req(s)
  if not s or s == "" then return nil end
  local id, t, rest = s:match("^([^|]*)|([^|]*)|(.*)$")
  if not id then return nil end
  local guids = {}
  for gd in rest:gmatch("[^,]+") do guids[#guids + 1] = gd end
  return { via = "ext", id = id, t = tonumber(t) or 0, guids = guids }
end

function L.encode_res(id, code, text) return ("%s|%d|%s"):format(id, code, text or "") end

function L.decode_res(s)
  if not s or s == "" then return nil end
  local id, code, text = s:match("^([^|]*)|(%-?%d+)|(.*)$")
  if not id then return nil end
  return { id = id, code = tonumber(code), text = text }
end

--- older than max_age on the main's clock (or no time at all) → never executed
function L.expired(req, now, max_age)
  local t = tonumber(req.t) or 0
  return t <= 0 or now - t > (max_age or L.MAX_AGE)
end

--- undo text: "Container Link: Ch 2 を LINK" / "Container Link: Ch 2・5 を LINK"
function L.desc(chs)
  local t = {}
  for i, c in ipairs(chs) do t[i] = tostring(c) end
  return ("Container Link: Ch %s を LINK"):format(table.concat(t, "・"))
end

return L
