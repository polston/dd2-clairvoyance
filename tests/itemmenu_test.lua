-- tests/itemmenu_test.lua: drives Clairvoyance/itemmenu.lua with a fake sdk,
-- fake hooks and fake GUI objects (SPEC 22.10.2-22.10.6; Rulings 6-8).
package.path = "./reframework/autorun/?.lua;" .. package.path
local itemmenu = require("Clairvoyance.itemmenu")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")

-- A fake managed object: fields by name, methods by name; a function value
-- is called (and may raise).
local function obj(fields, methods)
  local o = { fields = fields or {}, methods = methods or {} }
  function o:get_field(n)
    local v = self.fields[n]
    if type(v) == "function" then return v() end
    return v
  end
  function o:call(n, ...)
    local m = self.methods[n]
    if m == nil then error("no method " .. n) end
    return m(self, ...)
  end
  return o
end

local function list(items)
  return obj({}, {
    get_Count = function() return #items end,
    get_Item = function(_, i) return items[i + 1] end,
  })
end

local function array(items)
  return obj({}, {
    get_size = function() return #items end,
    get_Length = function() return #items end,
    get_element = function(_, i) return items[i + 1] end,
    get_Item = function() return nil end,   -- measured: nil on the managed array
  })
end

local now = 0
local function clock() return now end

-- The world: 25 rows, 30 slots, one description text.
local function make_world(style_args)
  local w = { scroll = 0, sel = 3, msg = "Potion\nHeals.", sets = 0,
    raise_data = {}, sdk_calls = 0, hooks = {}, logs = {}, screen_h = 1080,
    enabled = true, opens = 0, circles = {}, draw_raise = false, texts = {}, pushes = 0, pops = 0 }
  local infos = {}
  for i = 0, 24 do
    local row = i
    infos[#infos + 1] = obj({ Storage = obj({
      _ItemId = 100 + i,
      _ItemData = obj({ _SubCategory = function()
        if w.raise_data[row] then error("itemdata raised") end
        return (row == 7) and 4 or 0
      end }),
    }) })
  end
  w.slots = {}
  for i = 0, 29 do
    local slot = i
    local pnl = obj({}, { get_ActualVisible = function()
      return not w.slots[slot + 1].hidden
    end, get_GlobalPosition = function()
      local s = w.slots[slot + 1]
      return { x = s.x, y = s.y, z = 0 }
    end })
    w.slots[#w.slots + 1] = { x = 100 + 141 * (i % 5), y = 200 + 141 * (i // 5),
      pnl = pnl, freed = false }
    pnl.slot = w.slots[#w.slots]
  end
  local slot_objs = {}
  for i = 1, 30 do slot_objs[i] = obj({ Pnl = w.slots[i].pnl }) end
  local scg = obj({}, { get_ScrollRow = function() return w.scroll end })
  w.ctrl = obj({ InfoList = list(infos), ItemList = array(slot_objs), Scg = scg,
    ["<SelectedIndex>k__BackingField"] = function() return w.sel end })
  w.txt = obj({}, {
    get_Message = function() return w.msg end,
    set_Message = function(_, m) w.sets = w.sets + 1; w.msg = m end,
  })
  w.panel = obj({}, { get_GlobalPosition = function() return { x = 1274, y = 168, z = 0 } end })
  w.comp = obj({
    ItemGrid = obj({ _ItemCtrl = w.ctrl }),
    ItemWindow = obj({ _Pnl = w.panel }),
  })
  w.related = { [103] = { "Lost Ring", "Old Debt" } }

  w.sdk = {
    find_type_definition = function(name)
      return { get_method = function(_, m) return name .. "." .. m end }
    end,
    hook = function(m, pre, post) w.hooks[m] = { pre = pre, post = post } end,
    to_managed_object = function(a) w.sdk_calls = w.sdk_calls + 1; return a end,
    is_managed_object = function(o)
      w.sdk_calls = w.sdk_calls + 1
      if o == nil then return false end
      if o.slot and o.slot.freed then return false end
      return true
    end,
  }
  w.draw = { filled_circle = function(x, y, r, c, n)
    if w.draw_raise then error("draw raised") end
    w.circles[#w.circles + 1] = { x = x, y = y, r = r, c = c }
  end, text = function(t, x, y, c)
    w.texts[#w.texts + 1] = { t = t, x = x, y = y, c = c }
  end }
  w.r = itemmenu.create({
    sdk = w.sdk, draw = w.draw,
    enabled = function() return w.enabled end,
    related = function() return w.related end,
    quest_flag = function(d) return d:get_field("_SubCategory") == 4 end,
    color_abgr = function() return w.dot_color or 0xFF00FF00 end,
    label_color = function() return 0xFF00FF00 end,
    style = style_args and function() return style_args[1], style_args[2], style_args[3] end or nil,
    imgui = { push_font = function() w.pushes = w.pushes + 1 end,
      pop_font = function() w.pops = w.pops + 1 end },
    font = function() return "F" end,
    screen_h = function() return w.screen_h end,
    clock = clock,
    log = function(m) w.logs[#w.logs + 1] = m end,
    on_open = function() w.opens = w.opens + 1 end,
  })
  w.r:install()
  return w
end

local function hook(w, method) return w.hooks["app.ui060301_00." .. method] end
local function tick(w)    -- one game update of the menu
  hook(w, "update").pre({ nil, w.comp })
  hook(w, "update").post(nil)
end

-- install hooks the four methods
do
  local w = make_world()
  check("ctor hooked", hook(w, ".ctor") ~= nil)
  check("onDestroy hooked", hook(w, "onDestroy") ~= nil)
  check("update hooked with pre and post", hook(w, "update") ~= nil
    and hook(w, "update").pre ~= nil and hook(w, "update").post ~= nil)
end

-- open(): stamp within 0.25 s; on_open once per open.
do
  now = 10
  local w = make_world()
  check("closed before any stamp", not w.r:open())
  hook(w, "update").pre({ nil, w.comp })
  check("open after a stamp", w.r:open())
  check("on_open fired once", w.opens == 1)
  now = 10.1
  hook(w, "update").pre({ nil, w.comp })
  check("on_open not repeated while open", w.opens == 1)
  now = 10.34
  check("still open 0.24 s after stamp", w.r:open())
  now = 10.35
  check("closed 0.25 s after stamp", not w.r:open())
  now = 20
  hook(w, "update").pre({ nil, w.comp })
  check("reopen fires on_open again", w.opens == 2 and w.r:open())
  check("stats line", w.r:stats_line() == "menu open=true dots=0 labels=0 fails=0")
end

-- Dots: rows 3 (related) and 7 (subcategory 4) at the slots' top-right corners.
do
  now = 0
  local w = make_world()
  tick(w)
  w.r:frame()
  check("two dots", #w.circles == 2)
  local c1, c2 = w.circles[1], w.circles[2]
  -- k = 1, radius 4, corner = center + (70, -70); dot inset by the radius
  check("dot radius", c1 and c1.r == 4)
  check("dot color", c1 and c1.c == 0xFF00FF00)
  check("slot 3 dot", c1 and c1.x == 100 + 141 * 3 + 70 - 4 and c1.y == 200 - 70 + 4)
  check("slot 7 dot", c2 and c2.x == 100 + 141 * 2 + 70 - 4 and c2.y == 200 + 141 - 70 + 4)
  check("dots stat", w.r:stats_line():find("dots=2", 1, true) ~= nil)

  -- scaled by screen_h / 1080
  w.circles = {}
  w.screen_h = 2160
  w.r:frame()
  c1 = w.circles[1]
  check("scaled radius", c1 and c1.r == 8)
  check("scaled corner", c1 and c1.x == (100 + 141 * 3 + 70) * 2 - 8 and c1.y == (200 - 70) * 2 + 8)
  w.screen_h = 1080

  -- a moved Pnl draws at the new corner
  w.circles = {}
  w.slots[4].x = w.slots[4].x + 50
  w.slots[4].y = w.slots[4].y + 30
  w.r:frame()
  c1 = w.circles[1]
  check("moved slot follows", c1 and c1.x == 100 + 141 * 3 + 50 + 70 - 4 and c1.y == 200 + 30 - 70 + 4)

  -- a freed slot draws nothing and is not a failure
  w.circles = {}
  w.slots[4].freed = true
  w.r:frame()
  check("freed slot draws nothing", #w.circles == 1)
  check("freed slot is not a failure", w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

-- A hidden slot (get_ActualVisible false) draws nothing and is not a failure.
do
  now = 0
  local w = make_world()
  w.slots[4].hidden = true
  tick(w)
  w.r:frame()
  check("hidden slot draws nothing", #w.circles == 1)
  check("hidden slot is not a failure", w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

-- A failed game read inside the frame counts as a failure and skips the frame.
do
  now = 0
  local w = make_world()
  tick(w)
  w.ctrl.fields.Scg = obj({}, { get_ScrollRow = function() error("scroll raised") end })
  w.r:frame()
  check("get_ScrollRow raise: no dots", #w.circles == 0)
  check("get_ScrollRow raise: counted", w.r:stats_line():find("fails=1", 1, true) ~= nil)
  check("get_ScrollRow raise: logged", #w.logs == 1)
  for _ = 1, 29 do w.r:frame() end
  w.ctrl.fields.Scg = obj({}, { get_ScrollRow = function() return 0 end })
  now = 1
  tick(w)
  w.r:frame()
  check("30 raising reads suspend the dots", #w.circles == 0)
  now = 5.1
  tick(w)
  w.r:frame()
  check("dots resume after 5 s", #w.circles == 2)
end

-- A nil slot inside the range is a failed read, not a skip.
do
  now = 0
  local w = make_world()
  tick(w)
  w.ctrl.fields.ItemList = array({})   -- size 0: nothing to draw, no failure
  w.r:frame()
  check("empty slot array draws nothing", #w.circles == 0 and w.r:stats_line():find("fails=0", 1, true) ~= nil)
  w.ctrl.fields.ItemList = obj({}, { get_size = function() return 30 end,
    get_element = function() return nil end })
  w.r:frame()
  check("nil slot in range counts a failure", w.r:stats_line():find("fails=1", 1, true) ~= nil)
end

-- ScrollRow 1: slot 0 is row 5, so row 7 is slot 2 and row 3 is above the view.
do
  now = 0
  local w = make_world()
  w.scroll = 1
  tick(w)
  w.r:frame()
  check("scrolled: one dot", #w.circles == 1)
  local c = w.circles[1]
  check("scrolled: row 7 at slot 2", c and c.x == 100 + 141 * 2 + 70 - 4 and c.y == 200 - 70 + 4)
end

-- Rows past the list end draw nothing (25 rows, scroll 1 shows rows 5..34).
do
  now = 0
  local w = make_world()
  w.scroll = 4   -- rows 20..49
  tick(w)
  w.r:frame()
  check("rows past the end draw nothing", #w.circles == 0)
  check("no failure past the end", w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

-- Label above the item panel.
do
  now = 0
  local w = make_world()
  tick(w)
  w.r:frame()
  check("label: one text without style", #w.texts == 1)
  local tx = w.texts[1]
  check("label: text", tx and tx.t == "Quest: Lost Ring, Old Debt")
  check("label: position", tx and tx.x == 1274 + 24 and tx.y == 168 - 34)
  check("label: color", tx and tx.c == 0xFF00FF00)
  check("label: font pushed and popped once", w.pushes == 1 and w.pops == 1)
  check("labels stat", w.r:stats_line():find("labels=1", 1, true) ~= nil)
  check("description never written", w.sets == 0)

  -- scaled
  w.texts = {}
  w.screen_h = 2160
  w.r:frame()
  tx = w.texts[1]
  check("label: scaled", tx and tx.x == (1274 + 24) * 2 and tx.y == (168 - 34) * 2)
  w.screen_h = 1080

  -- related changes to three titles
  w.texts = {}
  w.related = { [103] = { "Lost Ring", "Old Debt", "Third" } }
  tick(w)
  w.r:frame()
  check("label: three titles", w.texts[1] and w.texts[1].t == "Quest: Lost Ring, Old Debt, Third")
  w.texts = {}
  w.related = {}
  tick(w)
  w.r:frame()
  check("label: no longer related draws nothing", #w.texts == 0 and w.sets == 0)
end

do
  now = 0
  local w = make_world()
  w.sel = 7
  tick(w)
  w.r:frame()
  check("label: subcategory only", w.texts[1] and w.texts[1].t == "Quest item")
end

do
  now = 0
  local w = make_world()
  w.sel = 1
  tick(w)
  w.r:frame()
  check("label: unrelated row draws no text", #w.texts == 0)
  w.sel = 99
  tick(w)
  w.r:frame()
  check("label: out of range draws no text", #w.texts == 0)
  w.sel = -1
  tick(w)
  w.r:frame()
  check("label: negative draws no text", #w.texts == 0)
  check("label: no failure", w.r:stats_line():find("fails=0", 1, true) ~= nil and w.sets == 0)
end

-- A stale label never shows on reopen.
do
  now = 0
  local w = make_world()
  tick(w)
  now = 5
  hook(w, "update").pre({ nil, w.comp })   -- reopen: label cleared before the post-hook
  w.r:frame()
  check("reopen: no stale label", #w.texts == 0)
end

-- A missing ItemWindow or panel draws no label and is not a failure.
do
  now = 0
  local w = make_world()
  w.comp.fields.ItemWindow = nil
  tick(w)
  w.r:frame()
  check("no window: no text", #w.texts == 0)
  check("no window: not a failure", w.r:stats_line():find("fails=0", 1, true) ~= nil)
  w.comp.fields.ItemWindow = obj({})
  w.r:frame()
  check("no panel: no text", #w.texts == 0 and w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

-- A panel without a position is a failure.
do
  now = 0
  local w = make_world()
  w.panel.methods.get_GlobalPosition = function() return nil end
  tick(w)
  w.r:frame()
  check("no panel position: counted", w.r:stats_line():find("fails=1", 1, true) ~= nil and #w.texts == 0)
end

-- A font failure still draws, without the font.
do
  now = 0
  local w = make_world()
  w.r = nil
  local pushes, pops = 0, 0
  w.r = itemmenu.create({
    sdk = w.sdk, draw = w.draw, enabled = function() return true end,
    related = function() return w.related end,
    quest_flag = function() return false end, color_abgr = function() return 1 end,
    label_color = function() return 2 end,
    imgui = { push_font = function() pushes = pushes + 1; error("font") end,
      pop_font = function() pops = pops + 1 end },
    font = function() return "F" end,
    screen_h = function() return 1080 end, clock = clock,
    log = function() end, on_open = function() end,
  })
  w.r:install()
  tick(w)
  w.r:frame()
  check("font failure: label still drawn", #w.texts == 1 and pops == 0)
  check("font failure: not a frame failure", w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

-- A raising _ItemData read leaves the message untouched.
do
  now = 0
  local w = make_world()
  w.raise_data[7] = true
  w.sel = 7
  tick(w)
  check("raising item data: no label", #w.texts == 0 and w.sets == 0)
  check("raising item data counts a failure", w.r:stats_line():find("fails=1", 1, true) ~= nil)
  check("raising item data logged", #w.logs == 1)
  tick(w)
  check("same failure logged once", #w.logs == 1)
end

-- enabled() false: nothing drawn, nothing written.
do
  now = 0
  local w = make_world()
  w.enabled = false
  tick(w)
  w.r:frame()
  check("disabled draws nothing", #w.circles == 0)
  check("disabled draws no label", #w.texts == 0 and w.sets == 0)
end

-- Closed: frame makes no sdk call and draws nothing.
do
  now = 0
  local w = make_world()
  tick(w)
  now = 5
  local before = w.sdk_calls
  w.r:frame()
  check("closed: no sdk call", w.sdk_calls == before)
  check("closed: no draw", #w.circles == 0)
  check("closed: no label", #w.texts == 0)
end

-- onDestroy clears the component; ctor captures it.
do
  now = 0
  local w = make_world()
  hook(w, ".ctor").pre({ nil, w.comp })
  hook(w, "update").pre({ nil, w.comp })
  hook(w, "onDestroy").pre({ nil, w.comp })
  w.r:frame()
  check("destroyed: no draw", #w.circles == 0)
  hook(w, "update").post(nil)
  check("destroyed: no label", #w.texts == 0)
end

-- The update pre-hook is under pcall.
do
  now = 0
  local w = make_world()
  w.sdk.to_managed_object = function() error("boom") end
  hook(w, "update").pre({ nil, w.comp })
  check("pre-hook raise counted, not propagated", w.r:stats_line():find("fails=1", 1, true) ~= nil)
end

-- update refreshes the captured component.
do
  now = 0
  local w = make_world()
  hook(w, ".ctor").pre({ nil, obj({}) })
  tick(w)
  w.r:frame()
  check("update re-captures the component", #w.circles == 2)
end

-- Breaker: 30 consecutive failing frames suspend the dots for 5 s.
do
  now = 0
  local w = make_world()
  tick(w)
  w.draw_raise = true
  for _ = 1, 30 do w.r:frame() end
  check("30 failures counted", w.r:stats_line():find("fails=30", 1, true) ~= nil)
  w.draw_raise = false
  w.circles = {}
  now = 1
  tick(w)
  w.r:frame()
  check("suspended: no dots", #w.circles == 0)
  now = 4.9
  tick(w)
  w.r:frame()
  check("still suspended at 4.9 s", #w.circles == 0)
  now = 5.1
  tick(w)
  w.r:frame()
  check("resumes after 5 s", #w.circles == 2)
  check("failures logged once per message", #w.logs == 1)
end

-- Log cap: 16 distinct messages.
do
  now = 0
  local w = make_world()
  tick(w)
  local n = 0
  w.draw = nil
  w.r = itemmenu.create({
    sdk = w.sdk,
    draw = { filled_circle = function() n = n + 1; error("e" .. n) end },
    enabled = function() return true end, related = function() return w.related end,
    quest_flag = function() return false end, color_abgr = function() return 1 end,
    screen_h = function() return 1080 end, clock = clock,
    log = function(m) w.logs[#w.logs + 1] = m end, on_open = function() end,
  })
  w.r:install()
  tick(w)
  for _ = 1, 20 do
    now = now + 6   -- clear any suspension
    tick(w)
    w.r:frame()
  end
  check("log capped at 16", #w.logs == 16)
end

-- Outline (SPEC 23.5): style on draws a ring behind the dot and 8 offset texts.
do
  now = 0
  local w = make_world({ true, 0xFF000000, 1 })
  w.scroll = 1   -- one dot on screen
  tick(w)
  w.r:frame()
  check("outline: one dot is two circles", #w.circles == 2)
  check("outline: ring radius", w.circles[1] and w.circles[1].r == 4 + 1 + 1)
  check("outline: dot radius", w.circles[2] and w.circles[2].r == 4)
  check("outline: label is nine texts", #w.texts == 9)
  local last = w.texts[9]
  check("outline: last text is the label", last and last.c == 0xFF00FF00
    and last.x == 1274 + 24 and last.y == 168 - 34)
  check("outline: first text offset", w.texts[1] and w.texts[1].x == 1274 + 24 + 1
    and w.texts[1].y == 168 - 34 and w.texts[1].c == 0xFF000000)
end

do
  now = 0
  local w = make_world({ false, 0xFF000000, 1 })
  w.scroll = 1   -- one dot on screen
  tick(w)
  w.r:frame()
  check("outline off: one circle and one text", #w.circles == 1 and #w.texts == 1)
end

do
  now = 0
  local w = make_world({ true, 0xFF000000, 1 })
  w.dot_color = 0x8000FF00
  w.scroll = 1   -- one dot on screen
  tick(w)
  w.r:frame()
  check("outline: ring alpha byte follows the dot alpha",
    w.circles[1] and ((w.circles[1].c >> 24) & 0xFF) == 128)
end

do
  now = 0
  local w = make_world({ true, nil, nil })
  w.scroll = 1
  tick(w)
  w.r:frame()
  check("outline: nil color and width default", #w.circles == 2 and #w.texts == 9
    and w.texts[1].c == 0xFF000000 and w.r:stats_line():find("fails=0", 1, true) ~= nil)
end

do
  now = 0
  local w = make_world({ true, 0xFF0000FF, 1 })
  w.scroll = 1
  w.screen_h = 2160
  tick(w)
  w.r:frame()
  check("outline: scaled ring radius", w.circles[1] and w.circles[1].r == 8 + 2 + 1)
  check("outline: scaled first offset", w.texts[1] and w.texts[1].x == 1298 * 2 + 2)
  check("outline: ARGB color reaches draw as ABGR", w.texts[1] and w.texts[1].c == 0xFFFF0000)
end

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("itemmenu_test: OK")
