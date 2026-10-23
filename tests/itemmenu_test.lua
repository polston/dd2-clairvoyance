-- tests/itemmenu_test.lua: drives Clairvoyance/itemmenu.lua with a fake sdk,
-- fake hooks and fake GUI objects (SPEC 22.10.2-22.10.6; Rulings 6-8).
package.path = package.path .. ";./reframework/autorun/?.lua"
local itemmenu = require("Clairvoyance.itemmenu")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

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
local function make_world()
  local w = { scroll = 0, sel = 3, msg = "Potion\nHeals.", sets = 0,
    raise_data = {}, sdk_calls = 0, hooks = {}, logs = {}, screen_h = 1080,
    enabled = true, opens = 0, circles = {}, draw_raise = false }
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
  w.comp = obj({
    ItemGrid = obj({ _ItemCtrl = w.ctrl }),
    ItemWindow = obj({ _TxtInfo = w.txt }),
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
  end }
  w.r = itemmenu.create({
    sdk = w.sdk, draw = w.draw,
    enabled = function() return w.enabled end,
    related = function() return w.related end,
    quest_flag = function(d) return d:get_field("_SubCategory") == 4 end,
    color_abgr = function() return 0xFF00FF00 end,
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
  check("stats line", w.r:stats_line() == "menu open=true dots=0 appends=0 fails=0")
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

-- Description line.
do
  now = 0
  local w = make_world()
  local base = "Potion\nHeals."
  tick(w)
  local want = base .. "\nQuest: Lost Ring, Old Debt"
  check("suffix appended once", w.msg == want and w.sets == 1)
  tick(w)
  check("second post-hook changes nothing", w.msg == want and w.sets == 1)
  check("appends stat", w.r:stats_line():find("appends=1", 1, true) ~= nil)
  -- reopen with the same message
  now = 5
  tick(w)
  check("reopen with same message changes nothing", w.msg == want and w.sets == 1)
  -- the game rewrites the text: a new message gets the suffix once
  w.msg = "Potion\nHeals a lot."
  tick(w)
  check("new message gets the suffix", w.msg == "Potion\nHeals a lot.\nQuest: Lost Ring, Old Debt" and w.sets == 2)
  tick(w)
  check("and only once", w.sets == 2)
  -- row 7: subcategory only
  w.sel = 7
  w.msg = "Quest thing"
  tick(w)
  check("subcategory-only suffix", w.msg == "Quest thing\nQuest item")
  -- a suffix left by an earlier load (the panel outlives a script reset)
  w.msg = "Quest thing 2\nQuest item"
  tick(w)
  check("stale suffix not doubled", w.msg == "Quest thing 2\nQuest item")
  -- unrelated row leaves the message alone
  local before = w.sets
  w.sel = 1
  w.msg = "Plain"
  tick(w)
  check("unrelated row untouched", w.msg == "Plain" and w.sets == before)
  -- out of range selection
  w.sel = 99
  tick(w)
  check("out of range selection untouched", w.msg == "Plain" and w.sets == before)
  w.sel = -1
  tick(w)
  check("negative selection untouched", w.msg == "Plain" and w.sets == before)
end

-- The title list or the relation changes while the game's text does not.
do
  now = 0
  local w = make_world()
  local base = "Potion\nHeals."
  tick(w)
  check("first suffix", w.msg == base .. "\nQuest: Lost Ring, Old Debt")
  w.related = { [103] = { "Lost Ring", "Old Debt", "Third" } }
  tick(w)
  check("changed titles replace the line", w.msg == base .. "\nQuest: Lost Ring, Old Debt, Third")
  tick(w)
  check("and stay stable", w.msg == base .. "\nQuest: Lost Ring, Old Debt, Third" and w.sets == 2)
  w.related = {}
  tick(w)
  check("row no longer related: line removed", w.msg == base)
  local sets = w.sets
  tick(w)
  check("and nothing more is written", w.msg == base and w.sets == sets)
  w.related = { [103] = { "Back" } }
  tick(w)
  check("related again: line returns", w.msg == base .. "\nQuest: Back")
end

-- A raising _ItemData read leaves the message untouched.
do
  now = 0
  local w = make_world()
  w.raise_data[7] = true
  w.sel = 7
  w.msg = "Odd thing"
  tick(w)
  check("raising item data: message untouched", w.msg == "Odd thing" and w.sets == 0)
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
  check("disabled writes nothing", w.sets == 0 and w.msg == "Potion\nHeals.")
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
  -- the post-hook while closed also does nothing
  local sets = w.sets
  w.msg = "Fresh text"
  hook(w, "update").post(nil)
  check("closed: post-hook writes nothing", w.sets == sets and w.msg == "Fresh text")
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
  check("destroyed: no write", w.sets == 0)
end

-- A freed description text or window is not written.
do
  now = 0
  local w = make_world()
  w.txt.slot = { freed = true }
  tick(w)
  check("freed text: no write", w.sets == 0)
  check("freed text: not a failure", w.r:stats_line():find("fails=0", 1, true) ~= nil)
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

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("itemmenu_test: OK")
