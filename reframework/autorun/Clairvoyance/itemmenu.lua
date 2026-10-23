-- itemmenu.lua: item-menu quest dots and description line (SPEC 22.10.2-22.10.6).
-- No host globals: the sdk, draw table, clock and every game fact arrive
-- through opt.
local M = {}

local TYPE_NAME = "app.ui060301_00"
local OPEN_WINDOW = 0.25   -- seconds since the last update stamp that still count as open (Ruling 6)
local COLUMNS = 5          -- slots per grid row (Ruling 7)
local SLOT_SIZE = 140      -- slot width and height in GUI pixels (Ruling 7)
local DOT_RADIUS = 4       -- at 1080 lines
local DOT_SEGMENTS = 24
local TRIP_AT = 30         -- consecutive failed frames before the dots suspend (10.3b)
local TRIP_SECONDS = 5.0
local LOG_CAP = 16         -- distinct messages logged per layer (10.3b)

-- One call that may raise (a missing method raises in the host): value or nil.
local function try(o, name, ...)
  local ok, v = pcall(o.call, o, name, ...)
  if ok then return v end
  return nil
end

-- Strict reads for the frame and the append: a failed or empty read raises,
-- so the caller's pcall counts it (SPEC 22.10.6).
-- get_size/get_element are wrapper methods on a managed array (o:get_size()),
-- not methods reached through call(); a List answers get_Count/get_Item.
local function direct(o, name, ...)
  local ok, f = pcall(function() return o[name] end)
  if not ok or type(f) ~= "function" then return nil end
  local ok2, v = pcall(f, o, ...)
  if ok2 then return v end
  return nil
end

local function size_of(coll)
  local n = direct(coll, "get_size")
  if n == nil then n = try(coll, "get_size") end
  if n == nil then n = try(coll, "get_Count") end
  if type(n) ~= "number" then error("no size on collection") end
  return n
end

local function element_of(coll, i)
  local e = direct(coll, "get_element", i)
  if e == nil then e = try(coll, "get_element", i) end
  if e == nil then e = try(coll, "get_Item", i) end
  if e == nil then error("no element " .. i) end
  return e
end

-- GUI-to-screen conversion of one corner point; Task 11 fixes it here.
local function to_screen(x, y, k)
  return x * k, y * k
end

function M.create(opt)
  local r = {}
  local comp = nil          -- the app.ui060301_00 component (.ctor / update)
  local cur_this = nil      -- `this` of the update running now (pre -> post)
  local stamp = nil         -- opt.clock() at the last update pre-hook
  local kept = nil          -- the message the game wrote, before our suffix
  local written = nil       -- the text we last set (kept .. suffix), or nil
  local dots, appends, fails = 0, 0, 0
  local fail_frames, suspend_until = 0, 0.0
  local logged, logged_n = {}, 0

  local function note_fail(where, err)
    fails = fails + 1
    local msg = where .. ": " .. tostring(err)
    if not logged[msg] and logged_n < LOG_CAP then
      logged[msg] = true
      logged_n = logged_n + 1
      opt.log("item menu " .. msg)
    end
  end

  function r:open()
    return stamp ~= nil and opt.clock() - stamp < OPEN_WINDOW
  end

  -- The ItemCtrl of a live component, or nil.
  local function item_ctrl(c)
    if c == nil or not opt.sdk.is_managed_object(c) then return nil end
    local grid = c:get_field("ItemGrid")
    if grid == nil then return nil end
    return grid:get_field("_ItemCtrl")
  end

  -- Marked state of one row: titles (array, possibly empty) or nil when the
  -- row is not quest-related. Raises on a failed read.
  local function row_marks(infos, row, related)
    local info = element_of(infos, row)
    local storage = info:get_field("Storage")
    if storage == nil then error("row " .. row .. " has no Storage") end
    local id = storage:get_field("_ItemId")
    local titles = related[id]
    if titles ~= nil and #titles > 0 then return titles end
    if opt.quest_flag(storage:get_field("_ItemData")) then return {} end
    return nil
  end

  local function frame_body()
    local ctrl = item_ctrl(comp)
    if ctrl == nil then dots = 0; return end
    local infos = ctrl:get_field("InfoList")
    local slots = ctrl:get_field("ItemList")
    local scg = ctrl:get_field("Scg")
    if infos == nil or slots == nil or scg == nil then error("grid fields missing") end
    local total = size_of(infos)
    local nslots = size_of(slots)
    local scroll_raw = scg:call("get_ScrollRow")
    if type(scroll_raw) ~= "number" then error("no scroll row") end
    local scroll = math.floor(scroll_raw)
    local k = opt.screen_h() / 1080
    local radius = DOT_RADIUS * k
    local color = opt.color_abgr()
    local related = opt.related() or {}
    local n = 0
    for i = 0, nslots - 1 do
      local row = scroll * COLUMNS + i
      if row >= 0 and row < total then
        local slot = element_of(slots, i)
        local pnl = slot:get_field("Pnl")
        -- a freed or hidden slot draws nothing and is not a failure
        if pnl ~= nil and opt.sdk.is_managed_object(pnl)
            and try(pnl, "get_ActualVisible") ~= false then
          if row_marks(infos, row, related) ~= nil then
            local p = pnl:call("get_GlobalPosition")
            if p == nil then error("no global position") end
            -- the top-right corner, the dot inset by its radius
            local sx, sy = to_screen(p.x + SLOT_SIZE, p.y, k)
            opt.draw.filled_circle(sx - radius, sy + radius, radius, color, DOT_SEGMENTS)
            n = n + 1
          end
        end
      end
    end
    dots = n
  end

  function r:frame()
    if not self:open() or not opt.enabled() then return end
    if opt.clock() < suspend_until then return end
    local ok, err = pcall(frame_body)
    if ok then
      fail_frames = 0
    else
      dots = 0
      fail_frames = fail_frames + 1
      note_fail("frame", err)
      if fail_frames >= TRIP_AT then
        fail_frames = 0
        suspend_until = opt.clock() + TRIP_SECONDS
      end
    end
  end

  -- The description append (update post-hook; set_Message only takes effect
  -- here, Ruling 8). Raises on a failed read; nothing is written then.
  local function append_body(this)
    local ctrl = item_ctrl(this)
    if ctrl == nil then return end
    local sel = ctrl:get_field("<SelectedIndex>k__BackingField")
    if type(sel) ~= "number" or sel < 0 then return end
    local infos = ctrl:get_field("InfoList")
    if infos == nil or sel >= size_of(infos) then return end
    local titles = row_marks(infos, sel, opt.related() or {})
    local suffix = nil
    if titles ~= nil then
      if #titles > 0 then
        suffix = "\nQuest: " .. table.concat(titles, ", ")
      else
        suffix = "\nQuest item"
      end
    end
    if suffix == nil and written == nil then return end
    local win = this:get_field("ItemWindow")
    if win == nil or not opt.sdk.is_managed_object(win) then return end
    local txt = win:get_field("_TxtInfo")
    if txt == nil or not opt.sdk.is_managed_object(txt) then return end
    local msg = txt:call("get_Message")
    if type(msg) ~= "string" then return end
    local target
    if msg == written then
      -- the game has not rewritten the text: bring our line up to date
      target = (suffix ~= nil) and (kept .. suffix) or kept
      if target == msg then return end
    else
      -- the panel outlives a script reset (Ruling 6): drop a line an earlier
      -- load wrote, so it is never taken for the game's own text
      kept = (msg:gsub("\nQuest item$", ""):gsub("\nQuest: [^\n]*$", ""))
      if suffix == nil then written = nil; return end
      target = kept .. suffix
    end
    txt:call("set_Message", target)
    written = (suffix ~= nil) and target or nil
    appends = appends + 1
  end

  local function on_update_post()
    local this = cur_this
    cur_this = nil
    if this == nil or not r:open() or not opt.enabled() then return end
    local ok, err = pcall(append_body, this)
    if not ok then note_fail("append", err) end
  end

  function r:install()
    local sdk = opt.sdk
    local t = sdk.find_type_definition(TYPE_NAME)
    local function hook(name, pre, post)
      local m = t ~= nil and t:get_method(name) or nil
      if m == nil then
        opt.log("hook skipped: " .. TYPE_NAME .. "." .. name)
        return
      end
      sdk.hook(m, pre, post)
    end
    hook(".ctor", function(args) comp = sdk.to_managed_object(args[2]) end)
    hook("onDestroy", function()
      comp = nil
      cur_this = nil
    end)
    hook("update", function(args)
      local ok, err = pcall(function()
        local now = opt.clock()
        local was_open = stamp ~= nil and now - stamp < OPEN_WINDOW
        stamp = now
        local this = sdk.to_managed_object(args[2])
        cur_this = this
        comp = this
        if not was_open then opt.on_open() end
      end)
      if not ok then note_fail("update", err) end
    end, function(retval)
      on_update_post()
      return retval
    end)
  end

  function r:stats_line()
    return string.format("menu open=%s dots=%d appends=%d fails=%d",
      tostring(self:open()), dots, appends, fails)
  end

  return r
end

return M
