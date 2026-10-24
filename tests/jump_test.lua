-- tests/jump_test.lua - map-jump state machine with a fake frame clock
-- (SPEC 16.3g, 16.6a).
package.path = "./reframework/autorun/?.lua;" .. package.path
local J = require("Clairvoyance.jump")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")

-- Fake world: w.ui is the captured map UI, w.ctor the .ctor counter,
-- w.dead[ui] marks a freed object, w.rb the readback apply returns.
local function world()
  local w = { ui = nil, ctor = 0, dead = {}, opens = {}, applies = {}, rb = nil }
  w.m = J.new({
    open = function(pos)
      w.opens[#w.opens + 1] = pos
      if w.open_err then error("open boom") end
      return w.open_ok ~= false
    end,
    apply = function(ui, pos)
      w.applies[#w.applies + 1] = { ui = ui, pos = pos }
      if w.apply_err then error("boom") end
      return w.rb
    end,
    ui = function() return w.ui end,
    is_live = function(ui) return not w.dead[ui] end,
    ctor_count = function() return w.ctor end,
    menu_open = function() return w.menu == true end,
    close_menu = function() w.closes = (w.closes or 0) + 1; if w.close_err then error("close boom") end end,
  })
  return w
end
local P = { x = 100, y = 5, z = -200 }
-- runs frames from..to (t = frame / 60 s); returns the first result and its frame
local function run(w, from, to, each)
  for f = from, to do
    if each then each(f) end
    local res = w.m:step(f, f / 60)
    if res ~= nil then return res, f end
  end
end

-- J1 new instance: request at frame 1, construction at frame 5, apply at 5 + 45
do
  local w = world()
  w.rb = { x = 100.4, z = -200.5 }
  w.m:request(P)
  local res, f = run(w, 1, 400, function(f)
    if f == 5 then w.ctor = 1; w.ui = "ui_new" end
  end)
  check("jm J1: open called once with the target", #w.opens == 1 and w.opens[1].x == 100
    and w.opens[1].z == -200)
  check("jm J1: applied on frame 50 (45 after the construction)", f == 50 and #w.applies == 1
    and w.applies[1].ui == "ui_new")
  check("jm J1: on target within 1 unit", res.result == "on_target" and res.branch == "new"
    and res.readback.x == 100.4 and res.opened == true)
end
-- J2 existing instance: live UI, no construction -> apply at frame 1 + 30
do
  local w = world()
  w.ui = "ui_old"
  w.rb = { x = 100, z = -200 }
  w.m:request(P)
  local res, f = run(w, 1, 400)
  check("jm J2: applied to the existing UI on frame 31", f == 31 and #w.applies == 1
    and w.applies[1].ui == "ui_old")
  check("jm J2: branch existing, on target", res.result == "on_target" and res.branch == "existing")
end
-- J3 no UI and no construction: waits, then times out at 10 s
do
  local w = world()
  w.m:request(P)
  local res, f = run(w, 1, 2000)
  check("jm J3: timeout at 10 s (frame 601 at 60 fps), never applied",
    res ~= nil and res.result == "timeout" and f == 601 and #w.applies == 0)
end
-- J4 destroyed during the 45-frame wait -> canceled
do
  local w = world()
  w.m:request(P)
  local res = run(w, 1, 400, function(f)
    if f == 5 then w.ctor = 1; w.ui = "ui_new" end
    if f == 20 then w.ui = nil end              -- onDestroy clears ui_map
  end)
  check("jm J4: destroyed before apply -> canceled", res.result == "canceled" and #w.applies == 0)
end
-- J5 existing UI destroyed before frame 30 -> canceled
do
  local w = world()
  w.ui = "ui_old"
  w.m:request(P)
  local res = run(w, 1, 400, function(f) if f == 10 then w.dead["ui_old"] = true end end)
  check("jm J5: existing UI freed -> canceled", res.result == "canceled"
    and res.branch == "existing" and #w.applies == 0)
end
-- J6 readback rules
do
  local w = world()
  w.ui = "u"
  w.rb = { x = 101.5, z = -200 }               -- 1.5 away: the unexplored edge
  w.m:request(P)
  check("jm J6: 1.5 units away -> off_target", run(w, 1, 400).result == "off_target")
  w.rb = nil
  w.m:request(P)
  check("jm J6: nil readback -> off_target", run(w, 1, 400).result == "off_target")
  w.apply_err = true
  w.m:request(P)
  check("jm J6: apply raising -> off_target, no error", run(w, 1, 400).result == "off_target")
end
-- J7 a new request replaces the running one; idle steps return nil
do
  local w = world()
  w.ui = "u"
  w.rb = { x = 7, z = 8 }
  w.m:request(P)
  check("jm J7: first step only starts", w.m:step(1, 0) == nil and w.m:busy())
  w.m:request({ x = 7, y = 0, z = 8 })
  local res = run(w, 2, 400)
  check("jm J7: one result, for the replacement", res.target.x == 7 and #w.applies == 1
    and res.result == "on_target")
  check("jm J7: idle -> nil", w.m:step(500, 500) == nil and not w.m:busy())
end
-- J8 a construction during the existing-UI wait switches to the new path
do
  local w = world()
  w.ui = "ui_old"
  w.rb = { x = 100, z = -200 }
  w.m:request(P)
  local res, f = run(w, 1, 400, function(f)
    if f == 10 then w.ctor = 1; w.ui = "ui_new" end
  end)
  check("jm J8: construction wins: applied to the new UI 45 frames later",
    f == 55 and w.applies[1].ui == "ui_new" and res.branch == "new")
end

-- J6b the 1-unit radius, z axis only
do
  local w = world()
  w.ui = "u"
  w.rb = { x = 100, z = -201 }                 -- exactly 1.0 off in z
  w.m:request(P)
  check("jm J6b: exactly 1.0 off in z -> on_target", run(w, 1, 400).result == "on_target")
  w.rb = { x = 100, z = -201.2 }               -- 1.2 off in z
  w.m:request(P)
  check("jm J6b: 1.2 off in z -> off_target", run(w, 1, 400).result == "off_target")
end
-- J4b a freed new UI still held by the caller -> canceled
do
  local w = world()
  w.m:request(P)
  local res = run(w, 1, 400, function(f)
    if f == 5 then w.ctor = 1; w.ui = "ui_new" end
    if f == 20 then w.dead["ui_new"] = true end
  end)
  check("jm J4b: new UI freed while held -> canceled", res.result == "canceled"
    and res.branch == "new" and #w.applies == 0)
end
-- J5b the existing UI swapped for a different one -> canceled
do
  local w = world()
  w.ui = "ui_old"
  w.m:request(P)
  local res = run(w, 1, 400, function(f) if f == 10 then w.ui = "ui_other" end end)
  check("jm J5b: existing UI replaced -> canceled", res.result == "canceled"
    and res.branch == "existing" and #w.applies == 0)
end
-- J3b an apply landing on the timeout frame wins (timeout is checked last)
do
  local w = world()
  w.rb = { x = 100, z = -200 }
  w.m:request(P)
  local res, f = run(w, 1, 2000, function(f)
    if f == 556 then w.ctor = 1; w.ui = "ui_new" end
  end)
  check("jm J3b: apply on frame 601 beats the timeout", f == 601 and res.result == "on_target"
    and res.branch == "new")
end
-- J9 open returning false / raising
do
  local w = world()
  w.ui = "u"
  w.rb = { x = 100, z = -200 }
  w.open_ok = false
  w.m:request(P)
  local res = run(w, 1, 400)
  check("jm J9: open false -> opened == false, run continues", res.opened == false
    and res.result == "on_target")
  w.open_ok = nil
  w.open_err = true
  w.m:request(P)
  local ok, res2 = pcall(run, w, 1, 400)
  check("jm J9b: open raising -> no error, opened == false, run continues",
    ok and res2.opened == false and res2.result == "on_target")
end
-- J10 the request copies the caller's table
do
  local w = world()
  w.ui = "u"
  w.rb = { x = 7, z = 8 }
  local pos = { x = 7, y = 1, z = 8 }
  w.m:request(pos)
  pos.x, pos.y, pos.z = 999, 999, 999
  local res = run(w, 1, 400)
  check("jm J10: target keeps the values at request time", res.target.x == 7
    and res.target.y == 1 and res.target.z == 8 and res.result == "on_target")
end
-- J11 timeout after a construction reports branch "new"
do
  local w = world()
  w.m:request(P)
  w.m:step(1, 0)
  w.ctor = 1; w.ui = "ui_new"
  local r1 = w.m:step(5, 0.1)
  local res = w.m:step(10, 11)
  check("jm J11: timeout after a construction -> branch new", r1 == nil
    and res ~= nil and res.result == "timeout" and res.branch == "new" and #w.applies == 0)
end

-- J4c the new UI swapped for a different live one -> canceled
do
  local w = world()
  w.m:request(P)
  local res = run(w, 1, 400, function(f)
    if f == 5 then w.ctor = 1; w.ui = "ui_new" end
    if f == 20 then w.ui = "ui_other" end
  end)
  check("jm J4c: new UI replaced -> canceled", res.result == "canceled"
    and res.branch == "new" and #w.applies == 0)
end
-- J2b a dead UI that was never live is not applied to; the request times out
do
  local w = world()
  w.ui = "ghost"
  w.dead["ghost"] = true
  w.m:request(P)
  local res = run(w, 1, 2000)
  check("jm J2b: dead UI present from the start -> never applied, timeout",
    res.result == "timeout" and #w.applies == 0)
end

-- J12 a second construction during the 45-frame wait re-arms the delay
do
  local w = world()
  w.rb = { x = 100, z = -200 }
  w.m:request(P)
  local res, f = run(w, 1, 400, function(f)
    if f == 5 then w.ctor = 1; w.ui = "ui_new1" end
    if f == 20 then w.ctor = 2; w.ui = "ui_new2" end
  end)
  check("jm J12: second construction wins: applied to the second map on frame 65",
    f == 65 and #w.applies == 1 and w.applies[1].ui == "ui_new2" and res.branch == "new"
    and res.result == "on_target")
end

-- J13 a pause menu is open: close it, wait until it is gone, then open fresh
do
  local w = world()
  w.menu = true
  w.ui = "ui_behind"
  w.rb = { x = 100, z = -200 }
  w.m:request(P)
  local res, f = run(w, 1, 400, function(f)
    if f == 20 then w.menu = false; w.dead["ui_behind"] = true end
    if f == 25 then w.ctor = 1; w.ui = "ui_new" end
  end)
  check("jm J13: menu closed once, map opened only after it was gone",
    w.closes == 1 and #w.opens == 1)
  check("jm J13: applied to the fresh map 45 frames after its construction",
    f == 70 and res.result == "on_target" and res.branch == "new"
    and w.applies[1].ui == "ui_new")
end
-- J14 the menu never closes: timeout with no open call
do
  local w = world()
  w.menu = true
  w.m:request(P)
  local res = run(w, 1, 1000)
  check("jm J14: menu stuck open times out without opening the map",
    res.result == "timeout" and #w.opens == 0 and res.branch == nil)
end
-- J15 a raising close_menu still waits and times out cleanly
do
  local w = world()
  w.menu = true
  w.close_err = true
  w.m:request(P)
  local res = run(w, 1, 1000)
  check("jm J15: raising close_menu is contained", res ~= nil and res.result == "timeout")
end

if failures > 0 then os.exit(1) end
print("jump_test: all OK")
