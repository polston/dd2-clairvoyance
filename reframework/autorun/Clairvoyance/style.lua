-- style.lua - outline and thick-line drawing helpers (SPEC 23.4.2, 23.5).
-- Pure module: requires nothing, touches no host global; `draw` is injected.
local M = {}

M.GROUPS = { "startable", "in_progress", "completed", "unavailable", "locked",
  "quest_item", "chest", "treasure", "token", "beetle", "monster", "seller",
  "npc_search", "route_stop", "hint_pin", "focus_place", "focus_objective",
  "route_line", "names", "items" }

local IS_GROUP = {}
-- per-group key names, built once so resolve concatenates nothing per call
local function keys_of(g)
  local p = "style_" .. g .. "_outline_"
  return { over = "style_" .. g .. "_override", on = p .. "on",
    color = p .. "color", width = p .. "width" }
end
local KEYS = {}
for _, g in ipairs(M.GROUPS) do
  IS_GROUP[g] = true
  KEYS[g] = keys_of(g)
end

function M.group_of(cat)
  if cat == "shop" then return "seller" end
  if cat == "focus_npc" then return "npc_search" end
  if IS_GROUP[cat] then return cat end
  return nil
end

-- Marker presentation group; objective styling takes precedence over the
-- semantic category while the marker retains that category for other rules.
function M.group_of_marker(marker)
  if type(marker) == "table" and marker.objective == true then return "focus_objective" end
  return type(marker) == "table" and M.group_of(marker.cat) or nil
end

function M.resolve(settings, group)
  local on, color, width = settings.outline_on, settings.outline_color,
    settings.outline_width
  -- a group outside GROUPS builds its names (rare, never in the frame loop)
  local k = group ~= nil and (KEYS[group] or keys_of(group)) or nil
  if k ~= nil and settings[k.over] == true then
    if settings[k.on] ~= nil then on = settings[k.on] end
    if settings[k.color] ~= nil then color = settings[k.color] end
    if settings[k.width] ~= nil then width = settings[k.width] end
  end
  if on == nil then on = true end
  if color == nil then color = 0xFF000000 end
  if width == nil then width = 1 end
  return on, color, width
end

-- A point in the 1920x1080 GUI layout -> screen pixels on a w x h display:
-- uniform scale, centred (the conversion icons:to_screen applies).
function M.layout_to_screen(x, y, w, h)
  local k = math.min(w / 1920, h / 1080)
  return (w - 1920 * k) / 2 + x * k, (h - 1080 * k) / 2 + y * k, k
end

function M.offset(width, k)
  return math.max(1, math.floor(width * k + 0.5))
end

M.OFFSETS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
  { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

function M.abgr(argb)
  return (argb & 0xFF00FF00) | ((argb >> 16) & 0xFF) | ((argb & 0xFF) << 16)
end

function M.alpha(color_argb, a)
  return ((color_argb >> 24) & 0xFF) / 255 * a
end

function M.with_alpha(argb, a)
  a = math.min(1, math.max(0, a))
  return (argb & 0x00FFFFFF) | (math.floor(a * 255 + 0.5) << 24)
end

local function outline_abgr(outline_argb, a)
  a = a or 1
  return M.abgr(M.with_alpha(outline_argb, M.alpha(outline_argb, a)))
end

function M.text(draw, s, x, y, color_abgr, on, outline_argb, o, a)
  if on then
    local oc = outline_abgr(outline_argb, a)
    for i = 1, #M.OFFSETS do
      local d = M.OFFSETS[i]
      draw.text(s, x + d[1] * o, y + d[2] * o, oc)
    end
  end
  draw.text(s, x, y, color_abgr)
end

function M.circle(draw, x, y, r, color_abgr, on, outline_argb, o, segs, a)
  if on then
    draw.filled_circle(x, y, r + o + 1, outline_abgr(outline_argb, a), segs)
  end
  draw.filled_circle(x, y, r, color_abgr, segs)
end

-- Corners offset w/2 along the normal and extended w/2 past each end, going
-- around: start-left, end-left, end-right, start-right. Zero length: nil.
function M.quad(x1, y1, x2, y2, w)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len == 0 then return nil end
  local h = w / 2
  local ux, uy = dx / len * h, dy / len * h
  local nx, ny = uy, -ux
  return x1 - ux + nx, y1 - uy + ny, x2 + ux + nx, y2 + uy + ny,
    x2 + ux - nx, y2 + uy - ny, x1 - ux - nx, y1 - uy - ny
end

function M.line(draw, x1, y1, x2, y2, w, color_abgr)
  local a, b, c, d, e, f, g, h = M.quad(x1, y1, x2, y2, w)
  if a == nil then return end
  draw.filled_quad(a, b, c, d, e, f, g, h, color_abgr)
end

-- Route leg colour (SPEC 32.14.3.3). amount (0..100) moves only the RGB
-- toward end_argb by step / max(1, n - 1); alpha fades toward alpha_end
-- (0..100 percent) and the width factor toward 0.5 on that same fraction.
-- Channels and alpha round down. Returns argb, width_factor.
function M.leg_color(argb, end_argb, amount, alpha_end, step, n)
  local d = math.max(1, n - 1)
  local out = 0
  for shift = 0, 16, 8 do
    local c = (argb >> shift) & 0xFF
    local e = (end_argb >> shift) & 0xFF
    out = out | ((c + (e - c) * amount * step // (100 * d)) << shift)
  end
  local a0 = (argb >> 24) & 0xFF
  local a = a0 * (100 * d - step * (100 - alpha_end)) // (100 * d)
  return (a << 24) | out, 1 - 0.5 * step / d
end

local function segments_range(draw, pts, from, to, w, color_abgr)
  for i = from, to - 1 do
    local x1, y1 = pts[2 * i - 1], pts[2 * i]
    local x2, y2 = pts[2 * i + 1], pts[2 * i + 2]
    if x1 ~= false and x2 ~= false then
      M.line(draw, x1, y1, x2, y2, w, color_abgr)
    end
  end
end

M.segments_range = segments_range

function M.outline_range(draw, pts, from, to, w, on, outline_argb, o, a)
  if on then
    segments_range(draw, pts, from, to, w + 2 * o, outline_abgr(outline_argb, a))
  end
end

return M
