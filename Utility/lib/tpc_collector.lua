--[[
  tpc_collector.lua
  Team Plugin Checker — EnumInstalledFX の生の並びから、畳み込んだ一覧（inventory）を作る。
  REAPER呼び出しは含まない。列挙する関数は外から渡す（テストではfixtureから作る）。
--]]

local normalize = require("tpc_normalize")
local ini = require("tpc_ini")

local M = {}

--- enum_fn(i) を i=0,1,2,... と呼び、false が返るまで集める。
-- enum_fn(i) -> ok, name, ident
function M.collect(enum_fn, opts)
  opts = opts or {}
  local out = {}
  local i = 0
  while true do
    local ok, name, ident = enum_fn(i)
    if not ok then break end
    out[#out + 1] = { index = i, name = name, ident = ident }
    i = i + 1
    if opts.max and i >= opts.max then break end
  end
  return out
end

--- entries（{index,name,ident}の並び）から inventory を作る。
-- opts.ini_vst に reaper-vstplugins_*.ini の中身（文字列）を渡すと、
-- VST2/VST3のクラスIDを補助キーとして拾う。
function M.build_inventory(entries, opts)
  opts = opts or {}
  local vst_ini_map = nil
  if opts.ini_vst then
    vst_ini_map = ini.parse_vstplugins(opts.ini_vst)
  end

  local plugins = {}
  local stats = {
    total_entries = #entries,
    parsed = 0,
    unparsed = 0,
    unparsed_samples = {},
    formats_count = {},
  }

  for _, e in ipairs(entries) do
    local key, parsed = normalize.key_from(e.name, e.ident)
    if not key then
      stats.unparsed = stats.unparsed + 1
      if #stats.unparsed_samples < 20 then
        stats.unparsed_samples[#stats.unparsed_samples + 1] = e.name
      end
    else
      stats.parsed = stats.parsed + 1
      local fmt = parsed.fmt
      stats.formats_count[fmt] = (stats.formats_count[fmt] or 0) + 1

      local p = plugins[key]
      if not p then
        p = {
          key = key,
          name = parsed.name,
          vendor = parsed.vendor,
          norm_name = normalize.norm_name_for_key(parsed.name, parsed.vendor),
          norm_vendor = normalize.norm_vendor(parsed.vendor),
          instrument = false,
          formats = {},
          _name_counts = {},
          _seen_format_ident = {},
        }
        plugins[key] = p
      end

      p._name_counts[parsed.name] = (p._name_counts[parsed.name] or 0) + 1
      if parsed.instrument then p.instrument = true end

      local dedupe_key = fmt .. "\0" .. (e.ident or "")
      if not p._seen_format_ident[dedupe_key] then
        p._seen_format_ident[dedupe_key] = true
        local class_id = nil
        if vst_ini_map and (fmt == "VST2" or fmt == "VST3") then
          local fkey = ini.filename_key(e.ident or "")
          local rec = vst_ini_map[fkey]
          if rec then class_id = rec.class_id end
        end
        p.formats[#p.formats + 1] = {
          fmt = fmt,
          raw_name = e.name,
          ident = e.ident,
          class_id = class_id,
        }
      end
    end
  end

  -- 表示名は「一番よく出てくる生の名前」を採用する。
  for _, p in pairs(plugins) do
    local best_name, best_n = p.name, 0
    for n, c in pairs(p._name_counts) do
      if c > best_n then
        best_name, best_n = n, c
      end
    end
    p.name = best_name
    p._name_counts = nil
    p._seen_format_ident = nil
  end

  return { plugins = plugins, stats = stats }
end

return M
