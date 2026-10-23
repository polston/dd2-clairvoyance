-- style.lua - outline and thick-line drawing helpers (SPEC 23.4.2, 23.5).
-- Pure module: requires nothing, touches no host global; `draw` is injected.
local M = {}

M.GROUPS = { "startable", "in_progress", "completed", "unavailable", "locked",
  "quest_item", "chest", "treasure", "token", "beetle", "monster", "seller",
  "npc_search", "route_stop", "hint_pin", "route_line", "names", "items" }

local IS_GROUP = {}
for _, g in ipairs(M.GROUPS) do IS_GROUP[g] = true end

function M.group_of(cat)
  if cat == "shop" then return "seller" end
  if IS_GROUP[cat] then return cat end
  return nil
end

function M.resolve(settings, group)
  local on, color, width = settings.outline_on, settings.outline_color,
    settings.outline_width
  if group ~= nil and settings["style_" .. group .. "_override"] == true then
    local p = "style_" .. group .. "_outline_"
    if settings[p .. "on"] ~= nil then on = settings[p .. "on"] end
    if settings[p .. "color"] ~= nil then color = settings[p .. "color"] end
    if settings[p .. "width"] ~= nil then width = settings[p .. "width"] end
  end
  if on == nil then on = true end
  if color == nil then color = 0xFF000000 end
  if width == nil then width = 1 end
  return on, color, width
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

local function segments(draw, pts, w, color_abgr)
  for i = 1, #pts // 2 - 1 do
    local x1, y1 = pts[2 * i - 1], pts[2 * i]
    local x2, y2 = pts[2 * i + 1], pts[2 * i + 2]
    if x1 ~= false and x2 ~= false then
      M.line(draw, x1, y1, x2, y2, w, color_abgr)
    end
  end
end

function M.polyline(draw, pts, w, color_abgr, on, outline_argb, o, a)
  if on then segments(draw, pts, w + 2 * o, outline_abgr(outline_argb, a)) end
  segments(draw, pts, w, color_abgr)
end

return M
