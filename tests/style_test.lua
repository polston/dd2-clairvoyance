-- tests/style_test.lua - outline and thick-line helpers (SPEC 23.4.2, 23.5).
package.path = "./reframework/autorun/?.lua;" .. package.path
local S = require("Clairvoyance.style")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")
local function near(a, b, e) return math.abs(a - b) <= e end

local function rec()
  local calls = {}
  local function mk(name)
    return function(...) calls[#calls + 1] = { name = name, ... } end
  end
  return { text = mk("text"), filled_circle = mk("circle"),
    filled_quad = mk("quad") }, calls
end
local function abyte(c) return (c >> 24) & 0xFF end

local G = { outline_on = true, outline_color = 0xFF000000, outline_width = 1 }
local function with(extra)
  local t = {}
  for k, v in pairs(G) do t[k] = v end
  for k, v in pairs(extra) do t[k] = v end
  return t
end

do -- groups and group_of
  check("18 groups", #S.GROUPS == 18)
  check("group_of shop", S.group_of("shop") == "seller")
  check("group_of chest", S.group_of("chest") == "chest")
  check("group_of unknown", S.group_of("zzz") == nil)
end

do -- resolve
  local on, c, w = S.resolve(G, "chest")
  check("global chest", on == true and c == 0xFF000000 and w == 1)
  on, c, w = S.resolve(G, "route_line")
  check("global route_line", on == true and c == 0xFF000000 and w == 1)
  local s = with({ style_seller_override = true, style_seller_outline_on = true,
    style_seller_outline_color = 0xFFFF0000, style_seller_outline_width = 2 })
  on, c, w = S.resolve(s, "seller")
  check("seller override", on == true and c == 0xFFFF0000 and w == 2)
  on, c, w = S.resolve(s, S.group_of("shop"))
  check("shop uses seller override", on == true and c == 0xFFFF0000 and w == 2)
  on, c, w = S.resolve(with({ style_items_override = true,
    style_items_outline_width = 3 }), "items")
  check("partial override falls back", on == true and c == 0xFF000000 and w == 3)
  on, c, w = S.resolve({}, "chest")
  check("empty table", on == true and c == 0xFF000000 and w == 1)
  on, c, w = S.resolve(G, nil)
  check("nil group is global", on == true and c == 0xFF000000 and w == 1)
end

do -- offset, alpha
  check("offset 1,1", S.offset(1, 1) == 1)
  check("offset 1,2", S.offset(1, 2) == 2)
  check("offset 1,0.6", S.offset(1, 0.6) == 1)
  check("offset 4,1.5", S.offset(4, 1.5) == 6)
  check("alpha", near(S.alpha(0x80000000, 0.5), 0.251, 0.002))
  check("with_alpha clamps high", S.with_alpha(0xFF000000, 2) == 0xFF000000)
  check("with_alpha clamps low", S.with_alpha(0xFF000000, -1) == 0x00000000)
  check("abgr", S.abgr(0xFFFF0000) == 0xFF0000FF)
end

do -- text
  local d, calls = rec()
  S.text(d, "hi", 10, 20, 0xFF112233, true, 0xFF000000, 2, 1)
  check("text 9 calls", #calls == 9)
  local ok = true
  for i = 1, 8 do
    local o = S.OFFSETS[i]
    ok = ok and calls[i][2] == 10 + o[1] * 2 and calls[i][3] == 20 + o[2] * 2
  end
  check("text outline positions", ok)
  check("text last", calls[9][2] == 10 and calls[9][3] == 20 and calls[9][4] == 0xFF112233)
  d, calls = rec()
  S.text(d, "hi", 10, 20, 0xFF112233, false, 0xFF000000, 2, 1)
  check("text off 1 call", #calls == 1)
  d, calls = rec()
  S.text(d, "hi", 0, 0, 1, true, 0xFFFF0000, 1)
  check("text red outline abgr", calls[1][4] == 0xFF0000FF)
  d, calls = rec()
  S.text(d, "hi", 0, 0, 1, true, 0x80000000, 1, 0.5)
  check("text outline alpha", abyte(calls[1][4]) == 64)
end

do -- circle
  local d, calls = rec()
  S.circle(d, 5, 6, 7, 0xFF112233, true, 0x80000000, 2, 12, 0.5)
  check("circle count", #calls == 2)
  check("circle outline radius", calls[1][3] == 7 + 2 + 1)
  check("circle outline alpha", abyte(calls[1][4]) == 64)
  check("circle main", calls[2][3] == 7 and calls[2][4] == 0xFF112233)
end

do -- quad
  local t = { S.quad(0, 0, 10, 0, 4) }
  local want = { -2, -2, 12, -2, 12, 2, -2, 2 }
  local ok = #t == 8
  for i = 1, 8 do ok = ok and near(t[i], want[i], 1e-9) end
  check("quad horizontal", ok)
  local q = { S.quad(0, 0, 10, 10, 2) }
  local r2 = math.sqrt(2)
  local dwant = { 0, -r2, 10 + r2, 10, 10, 10 + r2, -r2, 0 }
  ok = #q == 8
  for i = 1, 8 do ok = ok and near(q[i], dwant[i], 1e-9) end
  check("quad diagonal corners and caps", ok)
end

do -- line
  local d, calls = rec()
  S.line(d, 0, 0, 10, 0, 2, 0xFF00FF00)
  check("line 9 args", #calls == 1 and #calls[1] == 9 and calls[1][9] == 0xFF00FF00)
  d, calls = rec()
  S.line(d, 3, 3, 3, 3, 2, 1)
  check("zero-length line draws nothing", #calls == 0)
end

do -- polyline
  local d, calls = rec()
  S.polyline(d, { 0, 0, 10, 0 }, 2, 0xFF00FF00, true, 0x80000000, 1, 0.5)
  check("polyline outline alpha", abyte(calls[1][9]) == 64)
  d, calls = rec()
  S.polyline(d, { 0, 0, 10, 0, 20, 0 }, 2, 0xFF00FF00, true, 0xFF000000, 1, 1)
  check("polyline 3 pts", #calls == 4 and calls[2][9] == 0xFF000000
    and calls[3][9] == 0xFF00FF00)
  check("polyline outline width w + 2o",
    near(math.abs(calls[1][8] - calls[1][2]), 4, 1e-9)
    and near(math.abs(calls[3][8] - calls[3][2]), 2, 1e-9))
  d, calls = rec()
  S.polyline(d, { 0, 0, 10, 0, false, 0, 20, 0, 30, 0 }, 2, 0xFF00FF00, true,
    0xFF000000, 1, 1)
  check("polyline break", #calls == 4 and calls[1][9] == 0xFF000000
    and calls[2][9] == 0xFF000000 and calls[3][9] == 0xFF00FF00
    and calls[4][9] == 0xFF00FF00)
  d, calls = rec()
  S.polyline(d, { 0, 0, 10, 0 }, 2, 1, false, 0, 1, 1)
  check("polyline off", #calls == 1)
end

-- resolve reads each group's own override keys (final review M2)
do
  for _, g in ipairs(S.GROUPS) do
    local s = { outline_on = true, outline_color = 0xFF111111, outline_width = 1 }
    s["style_" .. g .. "_override"] = true
    s["style_" .. g .. "_outline_on"] = false
    s["style_" .. g .. "_outline_color"] = 0xFF222222
    s["style_" .. g .. "_outline_width"] = 3
    local on, color, width = S.resolve(s, g)
    check("resolve override " .. g, on == false and color == 0xFF222222 and width == 3)
    s["style_" .. g .. "_override"] = false
    on, color, width = S.resolve(s, g)
    check("resolve no override " .. g, on == true and color == 0xFF111111 and width == 1)
  end
  local s = { style_x_override = true, style_x_outline_width = 4 }
  local _, _, w = S.resolve(s, "x")
  check("resolve group outside GROUPS", w == 4)
end

-- layout_to_screen: 1920x1080 layout units -> screen pixels (final review S3)
do
  local x, y, k = S.layout_to_screen(960, 540, 1920, 1080)
  check("layout identity at 1080p", x == 960 and y == 540 and k == 1)
  x, y, k = S.layout_to_screen(960, 540, 3840, 2160)
  check("layout 4K doubles", x == 1920 and y == 1080 and k == 2)
  x, y = S.layout_to_screen(0, 0, 2560, 1080)
  check("layout ultrawide centres", x == 320 and y == 0)
  x, y = S.layout_to_screen(18, -34, 2560, 1440)
  check("layout offsets scale", near(x, 18 * 4 / 3, 1e-9) and near(y, -34 * 4 / 3, 1e-9))
end

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("style_test: all passed")
