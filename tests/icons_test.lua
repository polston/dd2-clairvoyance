-- tests/icons_test.lua: drives Clairvoyance/icons.lua with a fake D2DX and a
-- fake clock (SPEC 21.11.1). Pure Lua; no sdk.
package.path = package.path .. ";./reframework/autorun/?.lua"
local icons = require("Clairvoyance.icons")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

local now = 0
local function clock() return now end

local function fake_image(state)
  local img = { state = state or "pending", err = "boom" }
  function img:is_ready() return self.state == "loaded" end
  function img:get_state() return self.state end
  function img:get_error() return self.err end
  return img
end

-- A fake D2DX. Every call is recorded in order; images are handed out from
-- `files` (path -> image) and an unknown path returns nil.
local function fake_d2dx()
  local d = { calls = {}, draws = {}, begin_result = true, w = 1920, h = 1080,
    files = {}, raise_draw = false, raise_load = {}, counts = {} }
  local function rec(name)
    d.counts[name] = (d.counts[name] or 0) + 1
    d.calls[#d.calls + 1] = name
  end
  d.Image = { new = function(path)
    rec("Image.new")
    if d.raise_load[path] then error("load failed") end
    return d.files[path]
  end }
  d.image_ex = function(img, x, y, w, h, opts)
    rec("image_ex")
    if d.raise_draw then error("draw failed") end
    d.draws[#d.draws + 1] = { img = img, x = x, y = y, w = w, h = h,
      tint = opts.tint, alpha = opts.alpha }
  end
  d.begin_frame = function() rec("begin_frame"); return d.begin_result end
  d.end_frame = function() rec("end_frame") end
  d.surface_size = function() rec("surface_size"); return d.w, d.h end
  return d
end

local function make(d, over)
  local st = { logs = {}, rebuilds = 0, enabled = true, mini_ok = true }
  local o = { d2dx = d, clock = clock,
    log = function(m) st.logs[#st.logs + 1] = m end,
    enabled = function() return st.enabled end,
    request_rebuild = function() st.rebuilds = st.rebuilds + 1 end,
    mini_ok = function() return st.mini_ok end }
  for k, v in pairs(over or {}) do o[k] = v end
  st.r = icons.create(o)
  return st.r, st
end

local function ready_image(d, id)
  d.files["Clairvoyance/icons/" .. id .. ".png"] = fake_image("loaded")
  return d.files["Clairvoyance/icons/" .. id .. ".png"]
end

-- Detection: true with the full surface, false with each missing function.
do
  local r = make(fake_d2dx())
  check("available with every function", r:available())
  for _, name in ipairs({ "image_ex", "begin_frame", "end_frame", "surface_size" }) do
    local d = fake_d2dx(); d[name] = nil
    check("unavailable without " .. name, not make(d):available())
  end
  local d = fake_d2dx(); d.Image.new = nil
  check("unavailable without Image.new", not make(d):available())
  d = fake_d2dx(); d.Image = nil
  check("unavailable without Image", not make(d):available())
  check("unavailable with nil d2dx", not make(nil):available())
  check("unavailable with non-table d2dx", not make(5):available())
end

-- active(): available and enabled.
do
  local r, st = make(fake_d2dx())
  check("active when enabled", r:active())
  st.enabled = false
  check("inactive when disabled", not r:active())
  local r2 = make(nil)
  check("inactive when unavailable", not r2:active())
end

-- Preload: nil result and raising load both fail with one log and one rebuild.
do
  local d = fake_d2dx()
  d.raise_load["Clairvoyance/icons/9.png"] = true
  local r, st = make(d)
  r:preload({ 8 })
  check("nil load marks failed (not ready)", not r:ready(8))
  check("nil load logged once", #st.logs == 1)
  check("nil load rebuilds once", st.rebuilds == 1)
  r:preload({ 9 })
  check("raising load logged", #st.logs == 2)
  check("raising load rebuilds once more", st.rebuilds == 2)
  r:preload({ 8, 9 })
  check("already requested ids are not reloaded", d.counts["Image.new"] == 2)
  check("failed ids counted", r.failed_ids == 2)
  check("path format", (function()
    local d2 = fake_d2dx(); local seen
    d2.Image.new = function(p) seen = p; return nil end
    make(d2):preload({ 52 })
    return seen == "Clairvoyance/icons/52.png"
  end)())
end

-- Pending to ready and pending to failed, polled with empty queues.
do
  local d = fake_d2dx()
  local img1 = fake_image("pending")
  d.files["Clairvoyance/icons/1.png"] = img1
  local img2 = fake_image("pending")
  d.files["Clairvoyance/icons/2.png"] = img2
  local r, st = make(d)
  r:preload({ 1, 2 })
  check("pending is not ready", not r:ready(1) and not r:drawable(1))
  check("pending preload requests no rebuild", st.rebuilds == 0)
  r:draw()
  check("still pending: no rebuild", st.rebuilds == 0)
  img1.state = "loaded"
  r:draw()
  check("pending to ready: ready", r:ready(1) and r:drawable(1))
  check("pending to ready: one rebuild", st.rebuilds == 1)
  check("empty queues make no begin_frame call", (d.counts.begin_frame or 0) == 0)
  check("empty queues make no D2DX draw call", (d.counts.image_ex or 0) == 0
    and (d.counts.surface_size or 0) == 0)
  img2.state = "failed"
  r:draw()
  check("pending to failed: not ready", not r:ready(2))
  check("pending to failed: one more rebuild", st.rebuilds == 2)
  check("pending to failed: logged with the error", st.logs[#st.logs]:find("boom", 1, true) ~= nil)
  r:draw()
  check("settled images are not polled again", st.rebuilds == 2)
end

-- drawable_fn and inactive.
do
  local d = fake_d2dx(); ready_image(d, 5)
  local r, st = make(d)
  r:preload({ 5 }); r:draw()
  check("drawable_fn true when ready", r.drawable_fn(5) == true)
  check("drawable_fn false for unknown id", r.drawable_fn(6) == false)
  st.enabled = false
  check("drawable_fn false when inactive", r.drawable_fn(5) == false)
end

-- Push stores the tint and the alpha product.
do
  local d = fake_d2dx(); ready_image(d, 7)
  local r = make(d)
  r:preload({ 7 }); r:draw()
  r:push("map", 7, 100, 50, 32, 0x80FFFFFF, 0.5)
  r:draw()
  check("push: one draw", #d.draws == 1)
  check("push: tint forced opaque", d.draws[1].tint == 0xFFFFFFFF)
  check("push: alpha product", math.abs(d.draws[1].alpha - (128 / 255) * 0.5) < 1e-9)
  r:push("map", 7, 100, 50, 32, 0xFF102030, 1)
  r:draw()
  check("push: opaque color kept, alpha 1", d.draws[2].tint == 0xFF102030 and d.draws[2].alpha == 1)
end

-- Pinned call at 1920x1080: center (100, 50), size 32 -> top-left (84, 34).
do
  local d = fake_d2dx(); local img = ready_image(d, 7)
  local r = make(d)
  r:preload({ 7 }); r:draw()
  r:push("map", 7, 100, 50, 32, 0xFFFFFFFF, 1)
  r:draw()
  local c = d.draws[1]
  check("pinned image_ex call", c.img == img and c.x == 84 and c.y == 34 and c.w == 32 and c.h == 32)
  check("k is 1 at 1920x1080", r:k() == 1)
end

-- Layout at other sizes.
do
  local d = fake_d2dx(); ready_image(d, 7)
  local r = make(d)
  check("k is 1 before the first pass", r:k() == 1)
  r:preload({ 7 }); r:draw()
  d.w, d.h = 2560, 1080
  r:push("map", 7, 0, 0, 20, 0xFFFFFFFF, 1)
  r:draw()
  check("2560x1080: k 1", r:k() == 1)
  check("2560x1080: ox 320 (center 0 -> 320 - 10)", d.draws[1].x == 310 and d.draws[1].y == -10)
  d.w, d.h = 1280, 720
  r:push("map", 7, 0, 0, 30, 0xFFFFFFFF, 1)
  r:draw()
  check("1280x720: k 2/3", math.abs(r:k() - 2 / 3) < 1e-12)
  check("1280x720: no offset, side scaled", d.draws[2].x == -10 and d.draws[2].w == 20)
end

-- Draw order and the head shadow.
do
  local d = fake_d2dx(); ready_image(d, 1); ready_image(d, 2); ready_image(d, 3)
  local r = make(d)
  r:preload({ 1, 2, 3 }); r:draw()
  r:push("head", 3, 500, 400, 24, 0xFF112233, 1)
  r:push("mini", 2, 10, 10, 28, 0xFFFFFFFF, 1)
  r:push("map", 1, 20, 20, 32, 0xFFFFFFFF, 1)
  r:draw()
  check("draw count: map, mini, head shadow, head", #d.draws == 4)
  check("order: map first", d.draws[1].img == d.files["Clairvoyance/icons/1.png"])
  check("order: mini second", d.draws[2].img == d.files["Clairvoyance/icons/2.png"])
  check("head shadow first", d.draws[3].tint == 0xFF000000 and d.draws[3].x == 500 - 12 + 1
    and d.draws[3].y == 400 - 12 + 1)
  check("head picture second", d.draws[4].tint == 0xFF112233 and d.draws[4].x == 488 and d.draws[4].y == 388)
  local seq = table.concat(d.calls, ",")
  check("begin_frame before draws, end_frame last", seq:find("begin_frame,image_ex,image_ex,image_ex,image_ex,end_frame$") ~= nil)
end

-- Empty queues and inactive make zero D2DX calls.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r, st = make(d)
  r:preload({ 1 }); r:draw()
  local before = #d.calls
  r:draw()
  check("empty queues: zero calls", #d.calls == before)
  st.enabled = false
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("inactive: zero calls", #d.calls == before)
  st.enabled = true
  r:draw()
  check("inactive pass emptied the map queue", #d.calls == before)
end

-- begin_frame false counts a failed pass; end_frame follows every true begin.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r = make(d)
  r:preload({ 1 }); r:draw()
  d.begin_result = false
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("begin_frame false: counted", r.fail_count == 1)
  check("begin_frame false: no end_frame", (d.counts.end_frame or 0) == 0)
  d.begin_result = true; d.raise_draw = true
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("draw raise: counted", r.fail_count == 2)
  check("draw raise: end_frame still called", d.counts.end_frame == 1)
  d.raise_draw = false
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("drawn pass resets the count", r.fail_count == 0)
  d.w = 0
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("surface width 0: counted", r.fail_count == 1)
  check("surface width 0: no begin_frame past the earlier ones", d.counts.begin_frame == 3)
end

-- Breaker: trip at the 30th failed pass, retry after 5 s, third trip stays off.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r, st = make(d)
  r:preload({ 1 }); r:draw()
  local base = st.rebuilds
  d.begin_result = false
  for i = 1, 29 do
    r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1); r:draw()
  end
  check("29 failures: still active", r:active() and r.trips == 0)
  local logs_before = #st.logs
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1); r:draw()
  check("trip logs exactly once", #st.logs == logs_before + 1)
  check("30th failure trips", not r:active() and r.trips == 1)
  check("trip requests a rebuild", st.rebuilds == base + 1)
  check("trip logs once", st.logs[#st.logs]:find("begin_frame false", 1, true) ~= nil)
  local logs = #st.logs
  now = now + 4.9
  check("off before 5 s", not r:active())
  now = now + 0.2
  d.begin_result = true
  check("retry after 5 s", r:active())
  check("end of trip requests a rebuild", st.rebuilds == base + 2)
  check("end of trip logs once", #st.logs == logs + 1)
  d.begin_result = false
  for i = 1, 30 do r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1); r:draw() end
  check("second trip", not r:active() and r.trips == 2)
  now = now + 5.1
  check("second retry", r:active())
  for i = 1, 30 do r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1); r:draw() end
  check("third trip", not r:active() and r.trips == 3)
  now = now + 3600
  check("third trip stays off", not r:active())
  check("rebuilds: three trips, two ends", st.rebuilds == base + 5)
end

-- map and head emptied every frame; mini kept until replaced or stale.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r, st = make(d)
  r:preload({ 1 }); r:draw()
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:push("head", 1, 5, 5, 8, 0xFFFFFFFF, 1)
  r:push("mini", 1, 2, 2, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("first pass draws map, mini, head (+shadow)", #d.draws == 4)
  r:draw()
  check("second pass draws only mini", #d.draws == 5)
  now = now + 0.2
  r:draw()
  check("mini persists within 0.25 s", #d.draws == 6)
  now = now + 0.3
  r:draw()
  check("mini dropped when 0.25 s stale", #d.draws == 6)
  r:push("mini", 1, 2, 2, 8, 0xFFFFFFFF, 1)
  r:mini_replace()
  r:push("mini", 1, 3, 3, 8, 0xFFFFFFFF, 1)
  r:draw()
  check("mini_replace starts a new set", #d.draws == 7 and d.draws[7].x == 3 - 4)
  r:mini_replace()
  r:draw()
  check("empty replaced set draws nothing", #d.draws == 7)
end

-- mini skipped while mini_ok() is false (kept, not dropped).
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r, st = make(d)
  r:preload({ 1 }); r:draw()
  r:push("mini", 1, 2, 2, 8, 0xFFFFFFFF, 1)
  st.mini_ok = false
  r:draw()
  check("mini skipped while mini_ok is false", #d.draws == 0 and (d.counts.begin_frame or 0) == 0)
  st.mini_ok = true
  r:draw()
  check("mini drawn again once mini_ok", #d.draws == 1)
end

-- fill: a raising reader and a nil reader push nothing and leave the breaker alone.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r = make(d)
  r:preload({ 1 }); r:draw()
  local recs = { { id = 1, size = 20, argb = 0xFFFFFFFF }, { id = 1, size = 20, argb = 0xFFFFFFFF } }
  r:fill(recs, function() error("freed") end)
  check("raising reader pushes nothing", r.map.n == 0)
  r:fill(recs, function() return nil end)
  check("nil reader pushes nothing", r.map.n == 0)
  check("breaker count unchanged", r.fail_count == 0 and r.trips == 0)
  r:fill(recs, function(rec) return 100, 200 end)
  check("good reader pushes both", r.map.n == 2)
  r:draw()
  check("fill pushes at the read position", d.draws[1].x == 90 and d.draws[1].y == 190 and d.draws[1].w == 20)
  r:fill({}, function() return 1, 1 end)
end

-- Stats line format.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r = make(d)
  r:preload({ 1 }); r:draw()
  r:push("map", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:draw()
  local s = r:stats_line()
  check("stats line format", s:match("^Draw: map 1, mini 0, head 0, fill [%d.]+ ms, draw [%d.]+ ms, trips 0, failed ids 0$") ~= nil)
end

-- A steady frame grows no pool.
do
  local d = fake_d2dx(); ready_image(d, 1)
  local r = make(d)
  r:preload({ 1 }); r:draw()
  local function frame()
    r:mini_replace()
    for i = 1, 5 do
      r:push("map", 1, i, i, 8, 0xFFFFFFFF, 1)
      r:push("mini", 1, i, i, 8, 0xFFFFFFFF, 1)
      r:push("head", 1, i, i, 8, 0xFFFFFFFF, 1)
    end
    r:draw()
  end
  frame()
  local size = r:pool_size()
  for _ = 1, 100 do frame() end
  check("pool size unchanged after 100 steady frames", r:pool_size() == size)
  check("pool holds the peak", size == 15)
end

-- Review fixes.
do
  -- (1) loaded at preload: ready before any draw, no rebuild
  local d = fake_d2dx(); ready_image(d, 1)
  local r, st = make(d)
  r:preload({ 1 })
  check("loaded at preload: ready before first draw", r:ready(1) and r:drawable(1))
  check("loaded at preload: no rebuild", st.rebuilds == 0)
  r:draw()
  check("loaded at preload: poll adds no rebuild", st.rebuilds == 0)
  -- becomes loaded between draws: ready() sees it, poll adds no rebuild
  local img = fake_image("pending")
  d.files["Clairvoyance/icons/2.png"] = img
  r:preload({ 2 })
  check("pending not ready", not r:ready(2))
  img.state = "loaded"
  check("ready() checks live state", r:ready(2))
  check("ready() flip requests one rebuild", st.rebuilds == 1)
  r:draw()
  check("ready() flip: poll adds no second rebuild", st.rebuilds == 1 and r.pending_n == 0)
  r:ready(2)
  check("repeat ready() adds none", st.rebuilds == 1)
  -- off: no poll, so a pending image is not touched through D2DX
  local img3 = fake_image("pending")
  d.files["Clairvoyance/icons/3.png"] = img3
  r:preload({ 3 })
  st.enabled = false
  local calls = 0
  local orig = img3.is_ready
  img3.is_ready = function(...) calls = calls + 1 return orig(...) end
  r:draw()
  check("off: pending image not polled", calls == 0)
  st.enabled = true
  st.enabled = true
  -- (2) fill with nil y, nil argb, nil size, non-number x
  local n0 = r.fail_count
  local recs = { { id = 1, size = 20, argb = 0xFFFFFFFF }, { id = 1, size = 20 },
    { id = 1, argb = 0xFFFFFFFF }, { id = 1, size = 20, argb = 0xFFFFFFFF } }
  r:fill(recs, function(rec) if rec == recs[4] then return "a", 1 end return 5, nil end)
  check("fill skips nil y, bad x", r.map.n == 0)
  r:fill(recs, function() return 5, 6 end)
  check("fill skips nil argb and nil size", r.map.n == 2)
  r:draw()
  check("fill bad records never touch the breaker", r.fail_count == n0 and r.trips == 0)
  -- (3) unbounded mini pushes are capped
  for i = 1, 5000 do r:push("mini", 1, i, i, 8, 0xFFFFFFFF, 1) end
  check("mini capped at 4096", r.mini.n == 4096 and #r.mini.pool == 4096)
  r:mini_replace()
  check("mini_replace resets the count", r.mini.n == 0)
  -- stale drop without mini_replace: stamped at push
  r:push("mini", 1, 1, 1, 8, 0xFFFFFFFF, 1)
  r:push("mini", 1, 2, 2, 8, 0xFFFFFFFF, 1)
  now = now + 0.3
  r:draw()
  check("stale mini dropped without mini_replace", r.mini.n == 0)
  -- (5) Image.new returning false / a number marks failed without raising
  local d2 = fake_d2dx()
  d2.Image.new = function(p) if p:find("7") then return false end return 42 end
  local r2, st2 = make(d2)
  r2:preload({ 7, 8 })
  check("non-image results fail", not r2:ready(7) and not r2:ready(8) and r2.failed_ids == 2)
  check("non-image results log once each", #st2.logs == 2 and st2.rebuilds == 1)
  r2:push("map", 7, 1, 1, 8, 0xFFFFFFFF, 1)
  check("draw does not raise on failed ids", pcall(r2.draw, r2))
end

if failures == 0 then print("icons_test: all OK") else print("icons_test: " .. failures .. " FAILED"); os.exit(1) end
