-- tests/npcs_test.lua - NPC routes, affinity tiers, quest items, hints
-- (SPEC 22.5, 22.8, 22.9.4, 22.10.1, 22.11).
package.path = "./reframework/autorun/?.lua;" .. package.path
local N = require("Clairvoyance.npcs")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")

-- today
do
  local t = N.today(33, 2)
  check("today 33,2", t.week == 1 and t.weekday == 5 and t.hour == 2)
  check("today 35 weekday 0", N.today(35, 0).weekday == 0)
  check("today 56 week 1", N.today(56, 0).week == 1)
  check("today 49 week 4", N.today(49, 0).week == 4)
end

-- route_stops
local function row(sh, eh, area, prio, extra)
  local r = { start_week = 1, end_week = 4, start_day = 0, end_day = 6,
    start_hour = sh, end_hour = eh, area = area, location = -1,
    priority = prio or 0 }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end
local function pos_of(r) return { x = r.area, y = 0, z = 0 } end
local TODAY = { week = 1, weekday = 5, hour = 2 }

local function flat(stops)
  local o = {}
  for i, s in ipairs(stops) do o[i] = s.from .. "-" .. s.to .. ":" .. s.area end
  return table.concat(o, ",")
end

do
  local stops, un = N.route_stops({ row(6, 18, 49), row(18, 6, 46) }, TODAY, pos_of, nil)
  check("basic stops", flat(stops) == "6-18:49,18-6:46")
  check("basic unplaced", un == 0)
  check("stop pos from area_pos", stops[1].pos.x == 49 and stops[2].pos.x == 46)
  check("stop location", stops[1].location == -1)
end

do -- priority 1 only when cur matches at the current hour
  local rows = { row(0, 24, 49), row(6, 18, 50, 1) }
  local T10 = { week = 1, weekday = 5, hour = 10 }
  local s1 = N.route_stops(rows, T10, pos_of,
    { area = 50, location = -1, pos = { x = 1, y = 2, z = 3 } })
  check("p1 used when cur matches", flat(s1) == "6-18:50,18-6:49")
  local s2 = N.route_stops(rows, T10, pos_of, { area = 49, location = -1 })
  check("p1 ignored when cur differs", flat(s2) == "0-0:49")
  local s3 = N.route_stops(rows, T10, pos_of, nil)
  check("p1 ignored without cur", flat(s3) == "0-0:49")
  local s4 = N.route_stops(rows, { week = 1, weekday = 5, hour = 20 },
    pos_of, { area = 50, location = -1 })
  check("p1 not matching at current hour", flat(s4) == "0-0:49")
end

do -- priority 2 matching nothing
  local rows = { row(0, 24, 49), row(0, 24, 866, 2, { location = 133 }) }
  local s = N.route_stops(rows, TODAY, pos_of, { area = 49, location = -1 })
  check("p2 ignored", flat(s) == "0-0:49")
  local s2 = N.route_stops(rows, TODAY, pos_of, { area = 866, location = 133 })
  check("p2 used when matching", flat(s2) == "0-0:866")
  local rows3 = { row(0, 24, 49), row(0, 24, 60, 1), row(0, 24, 70, 2) }
  local s3 = N.route_stops(rows3, TODAY, pos_of, { area = 60, location = -1 })
  check("lowest matching level", flat(s3) == "0-0:60")
  local s4 = N.route_stops(rows3, TODAY, pos_of, { area = 70, location = -1 })
  check("level 2 when only it matches", flat(s4) == "0-0:70")
end

do -- weekday wrap 4-0
  local rows = { row(0, 24, 49, 0, { start_day = 4, end_day = 0 }) }
  for _, wd in ipairs({ 4, 5, 6, 0 }) do
    local s = N.route_stops(rows, { week = 1, weekday = wd, hour = 2 }, pos_of, nil)
    check("wrap day " .. wd, #s == 1)
  end
  local s = N.route_stops(rows, { week = 1, weekday = 1, hour = 2 }, pos_of, nil)
  check("wrap day 1 excluded", #s == 0)
  local rw = { row(0, 24, 49, 0, { start_week = 4, end_week = 1 }) }
  check("week wrap 4", #N.route_stops(rw, { week = 4, weekday = 0, hour = 0 }, pos_of, nil) == 1)
  check("week wrap 1", #N.route_stops(rw, { week = 1, weekday = 0, hour = 0 }, pos_of, nil) == 1)
  check("week wrap 2 excluded", #N.route_stops(rw, { week = 2, weekday = 0, hour = 0 }, pos_of, nil) == 0)
end

do -- gaps skipped
  local s = N.route_stops({ row(6, 18, 49) }, TODAY, pos_of, nil)
  check("gap skipped", flat(s) == "6-18:49")
  local s2 = N.route_stops({ row(6, 24, 49) }, TODAY, pos_of, nil)
  check("ends at midnight", flat(s2) == "6-0:49")
end

do -- unplaced
  local rows = { row(6, 18, 49), row(18, 6, 46) }
  local s, un = N.route_stops(rows, TODAY, function(r)
    if r.area == 46 then return nil end
    return pos_of(r)
  end, nil)
  check("unplaced stops", flat(s) == "6-18:49")
  check("unplaced count", un == 1)
  local s2, u2 = N.route_stops({ row(6, 18, 49, 0, { start_day = 1, end_day = 2 }) }, TODAY, pos_of, nil)
  check("none today", #s2 == 0 and u2 == 0)
  local s3, u3 = N.route_stops(rows, TODAY, function() return nil end, nil)
  check("all unplaced", #s3 == 0 and u3 == 2)
end

do -- cur.pos
  local P = { x = 9, y = 9, z = 9 }
  local rows = { row(6, 18, 49), row(18, 6, 46) }
  local s = N.route_stops(rows, TODAY, pos_of, { area = 46, location = -1, pos = P })
  check("cur pos taken", s[2].pos == P)
  check("other stop keeps node", s[1].pos.x == 49)
  local s2 = N.route_stops(rows, TODAY, pos_of, { area = 49, location = -1, pos = P })
  check("cur area differs keeps node", s2[2].pos.x == 46)
  local s3 = N.route_stops(rows, TODAY, pos_of, { area = 46, location = 5, pos = P })
  check("cur location differs keeps node", s3[2].pos.x == 46)
end

-- anchor_node
do
  local a = N.anchor_node({ { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, { x = 4, y = 0, z = 0 } })
  check("anchor nearest mean", a and a.x == 4 and a.y == 0 and a.z == 0)
  check("anchor empty", N.anchor_node({}) == nil)
end

-- tier
do
  local cases = { { -501, nil }, { -502, "Hostile" }, { -199, "Hostile" },
    { -101, "Hostile" }, { -100, "Hate" }, { -31, "Hate" }, { -30, "Normal" },
    { 99, "Normal" }, { 100, "Like" }, { 199, "Like" }, { 200, "Love" },
    { 299, "Love" }, { "x", nil } }
  for _, c in ipairs(cases) do
    check("tier " .. tostring(c[1]), N.tier(c[1]) == c[2])
  end
  check("tier nil", N.tier(nil) == nil)
end

-- related_items
do
  local r = N.related_items({
    { qid = 2, id = 5, num = 0, op = "morethan" },
    { qid = 1, id = 5, num = 1, op = "more" },
    { qid = 3, id = 5, num = 1, op = "other" },
    { qid = 4, id = 6, num = 1, op = "equal" },
    { qid = 1, id = 5, num = 1, op = "more" },
    "junk", 7,
  })
  check("related two quests ascending", r[5] and #r[5] == 2 and r[5][1] == 1 and r[5][2] == 2)
  check("related ignores other/equal", r[6] == nil)
  local r2 = N.related_items({ { qid = 9, id = 5, num = 1, op = "more" },
    { qid = 3, id = 5, num = 1, op = "more" } })
  check("related ascending", r2[5][1] == 3 and r2[5][2] == 9)
  local r3 = N.related_items({ { qid = 3, id = 5, num = 0, op = "morethan" } })
  check("morethan num 0 kept", r3[5] and r3[5][1] == 3)
  check("related non-table input", next(N.related_items(nil)) == nil)
end

-- parse_hints
do
  local h, e = N.parse_hints(nil)
  check("hints nil", next(h) == nil and #e == 1)
  h, e = N.parse_hints("x")
  check("hints string", next(h) == nil and #e == 1)
  h, e = N.parse_hints({ ["20010"] = { quest = "a", steps = { ["0"] = { text = "b" } } } })
  check("hints ok", h[20010] and h[20010].quest == "a" and h[20010].steps[0].text == "b"
    and #h[20010].steps[0].pins == 0 and #e == 0)
  h, e = N.parse_hints({ abc = { quest = "a" } })
  check("hints bad qid", next(h) == nil and #e == 1)
  h, e = N.parse_hints({ ["1"] = { steps = { ["0"] = { pins = {} } } } })
  check("hints step no text", h[1] and next(h[1].steps) == nil and #e == 1)
  h, e = N.parse_hints({ ["1"] = { steps = { ["0"] = { text = "t",
    pins = { { x = "1", y = 2, z = 3, label = "p" }, { x = 1, y = 2, z = 3 } } } } } })
  local pins = h[1] and h[1].steps[0] and h[1].steps[0].pins
  check("hints bad pin dropped", pins and #pins == 1 and #e == 1)
  check("hints pin no label", pins and pins[1].label == "" and pins[1].x == 1
    and pins[1].y == 2 and pins[1].z == 3)
end

-- parse_hints validation of keys, steps shape, pins shape, quest text
do
  local h, e = N.parse_hints({ ["1.5"] = { quest = "a" }, ["-1"] = { quest = "a" } })
  check("fractional/negative qid dropped", next(h) == nil and #e == 2)
  h, e = N.parse_hints({ ["1"] = { steps = { ["1.5"] = { text = "t" }, ["x"] = { text = "t" } } } })
  check("bad step index dropped", h[1] and next(h[1].steps) == nil and #e == 2)
  h, e = N.parse_hints({ ["1"] = { steps = { { text = "a" } } } })
  check("array steps rejected", h[1] and next(h[1].steps) == nil and #e == 1)
  h, e = N.parse_hints({ ["1"] = { steps = { [0] = { text = "a" }, [1] = { text = "b" } } } })
  check("zero-based numeric steps kept", h[1].steps[0].text == "a" and h[1].steps[1].text == "b" and #e == 0)
  h, e = N.parse_hints({ ["1"] = { steps = { ["0"] = { text = "t", pins = { a = 1 } } } } })
  check("object pins rejected", h[1].steps[0] and #h[1].steps[0].pins == 0 and #e == 1)
  h, e = N.parse_hints({ ["1"] = { quest = 5 } })
  check("non-string quest logged", h[1] and h[1].quest == nil and #e == 1)
  local r = N.related_items({ { qid = 1, id = 5, num = 1, op = "more" },
    { qid = 1.0, id = 5.0, num = 1, op = "more" } })
  check("related float dedup", #r[5] == 1)
end

-- parse_hints items, hint_items
do
  local h, e = N.parse_hints({ ["1"] = { quest = "a" } })
  check("items absent: empty list", #h[1].items == 0 and #e == 0)
  h, e = N.parse_hints({ ["1"] = { items = { 310, 395 } } })
  check("items kept", #h[1].items == 2 and h[1].items[1] == 310 and h[1].items[2] == 395 and #e == 0)
  h, e = N.parse_hints({ ["1"] = { items = "x" } })
  check("items string rejected", #h[1].items == 0 and #e == 1 and e[1]:find("items is not a list", 1, true))
  h, e = N.parse_hints({ ["1"] = { items = { a = 1 } } })
  check("items object rejected", #h[1].items == 0 and #e == 1 and e[1]:find("items is not a list", 1, true))
  h, e = N.parse_hints({ ["1"] = { items = { 310, 1.5, -2, 395 } } })
  check("bad item ids dropped", #h[1].items == 2 and h[1].items[1] == 310 and h[1].items[2] == 395
    and #e == 2 and e[1]:find("item 2 is not an item id", 1, true)
    and e[2]:find("item 3 is not an item id", 1, true))
  local m = N.hint_items({ [20] = { items = { 310 } }, [10] = { items = { 310, 395, 395 } } })
  check("hint_items map", #m[310] == 2 and m[310][1] == 10 and m[310][2] == 20
    and #m[395] == 1 and m[395][1] == 10)
  check("hint_items nil", next(N.hint_items(nil)) == nil)
end

-- route ties: first row read wins
do
  local s = N.route_stops({ row(0, 24, 49), row(0, 24, 50) }, TODAY, pos_of, nil)
  check("tie first row wins", flat(s) == "0-0:49")
end

-- hint_step
do
  local hints = N.parse_hints({ ["7"] = { steps = { ["0"] = { text = "a" }, ["1"] = { text = "b" } } } })
  check("hint_step 1", N.hint_step(hints, 7, 1).text == "a")
  check("hint_step 2", N.hint_step(hints, 7, 2).text == "b")
  check("hint_step missing", N.hint_step(hints, 7, 3) == nil)
  check("hint_step unknown qid", N.hint_step(hints, 8, 1) == nil)
  check("hint_step nil hints", N.hint_step(nil, 7, 1) == nil)
  check("hint_step bad step", N.hint_step(hints, 7, "x") == nil)
end

-- walking-path search, route pairs, fit, route polyline (SPEC 23.6)
do
  -- links = { [i] = { targets... } }; coords = { {x,y,z}, ... }
  local function mkgraph(coords, links)
    local g = { n = #coords, x = {}, y = {}, z = {}, ls = {}, lc = {}, lt = {} }
    local slot = 1
    for i, c in ipairs(coords) do
      g.x[i], g.y[i], g.z[i] = c[1], c[2], c[3]
      local l = links[i] or {}
      g.ls[i] = slot
      g.lc[i] = #l
      for _, t in ipairs(l) do g.lt[slot] = t; slot = slot + 1 end
    end
    return g
  end
  local function run(job, budget)
    local st
    repeat st = N.path_step(job, budget or 1e9, function() return 0 end)
    until st ~= "running"
    return st
  end
  local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
  end

  local chain = mkgraph({ {0,0,0}, {1,0,0}, {2,0,0}, {3,0,0} },
    { {2}, {1, 3}, {2, 4}, {3} })
  local j = N.path_new(chain, 1, 4)
  check("path chain done", run(j) == "done")
  check("path chain", same(j.path, { 1, 2, 3, 4 }))
  check("path chain expanded", j.expanded >= 3)
  local same_job = N.path_new(chain, 2, 2)
  check("path a==b", N.path_step(same_job, 1, function() return 0 end) == "done"
    and same(same_job.path, { 2 }))
  check("path done is sticky",
    N.path_step(same_job, 1, function() return 0 end) == "done")

  -- detour: 1 -> 2 (near goal 5, long link 2->5) and 1 -> 3 -> 4 -> 5
  local det = mkgraph({ {0,0,0}, {9,-3,0}, {3,1,0}, {7,1,0}, {10,0,0} },
    { {2, 3}, {5}, {4}, {5}, {} })
  j = N.path_new(det, 1, 5)
  check("detour", run(j) == "done" and same(j.path, { 1, 3, 4, 5 }))

  -- one-way
  local ow = mkgraph({ {0,0,0}, {1,0,0} }, { {2}, {} })
  j = N.path_new(ow, 1, 2)
  check("one-way forward", run(j) == "done" and same(j.path, { 1, 2 }))
  j = N.path_new(ow, 2, 1)
  check("one-way back failed", run(j) == "failed" and j.path == nil)
  check("failed is sticky",
    N.path_step(j, 1, function() return 0 end) == "failed")

  -- unreachable, cap
  local iso = mkgraph({ {0,0,0}, {1,0,0}, {5,0,0} }, { {2}, {1}, {} })
  j = N.path_new(iso, 1, 3)
  check("unreachable", run(j) == "failed")
  local coords, links = {}, {}
  for i = 1, 30 do
    coords[i] = { i, 0, 0 }
    links[i] = { i + 1 <= 30 and i + 1 or nil }
  end
  local long = mkgraph(coords, links)
  j = N.path_new(long, 1, 30, { cap = 10 })
  check("cap failed", run(j) == "failed" and j.expanded > 10)
  j = N.path_new(long, 1, 30)
  check("cap default", j.cap == 20000 and j.weight == 1.2)
  check("long chain ok", run(j) == "done" and #j.path == 30)
  coords, links = {}, {}
  for i = 1, 20002 do
    coords[i] = { i, 0, 0 }
    links[i] = i < 20002 and { i + 1 } or {}
  end
  local cross_world = mkgraph(coords, links)
  j = N.path_new(cross_world, 1, 20002)
  check("cap scales with graph and completes past 20000 expansions",
    j.cap == 40004 and run(j) == "done" and j.expanded > 20000
      and #j.path == 20002)

  -- resumable on a 40x50 grid
  local W, H = 40, 50
  coords, links = {}, {}
  for r = 0, H - 1 do
    for c = 0, W - 1 do
      local i = r * W + c + 1
      coords[i] = { c, 0, r }
      local l = {}
      if c > 0 then l[#l + 1] = i - 1 end
      if c < W - 1 then l[#l + 1] = i + 1 end
      if r > 0 then l[#l + 1] = i - W end
      if r < H - 1 then l[#l + 1] = i + W end
      links[i] = l
    end
  end
  local grid = mkgraph(coords, links)
  local full = N.path_new(grid, 1, W * H)
  check("grid full", run(full) == "done")
  local t = 0
  local clk = function() t = t + 0.001; return t end
  local sliced = N.path_new(grid, 1, W * H)
  local calls, st = 0, "running"
  while st == "running" and calls < 5000 do
    st = N.path_step(sliced, 0.5, clk)
    calls = calls + 1
  end
  check("grid sliced done", st == "done")
  check("grid sliced took several calls", calls > 1)
  check("grid sliced same path", same(sliced.path, full.path))

  -- nearest
  local ng = mkgraph({ {0,0,0}, {10,0,0}, {10,10,10} }, {})
  local nj = N.nearest_new(ng, 9, 1, 0)
  check("nearest", N.nearest_step(nj, 1e9, function() return 0 end) == "done"
    and nj.best == 2 and math.abs(nj.dist - math.sqrt(2)) < 1e-9)
  t = 0
  nj = N.nearest_new(ng, 10, 9, 9)
  calls, st = 0, "running"
  while st == "running" and calls < 100 do
    st = N.nearest_step(nj, 0.5, clk)
    calls = calls + 1
  end
  check("nearest budgeted", st == "done" and nj.best == 3 and calls > 1)

  local masked = mkgraph({ { 0, 0, 0 }, { 1, 0, 0 }, { 2, 0, 0 } },
    { { 2 }, { 1, 3 }, { 2 } })
  masked.ok = { true, false, true }
  nj = N.nearest_new(masked, 1, 0, 0)
  check("nearest skips disabled graph nodes",
    N.nearest_step(nj, 1e9, function() return 0 end) == "done" and nj.best ~= 2)
  j = N.path_new(masked, 1, 3)
  check("path cannot traverse a disabled graph node", run(j) == "failed")
end

-- route_pairs
do
  local function s(d, x) return { discovered = d, pos = { x = x or 0, y = 0, z = 0 } } end
  local rp = N.route_pairs({ s(true), s(false), s(true) }, false)
  check("pairs skip undiscovered", #rp == 1 and rp[1][1] == 1 and rp[1][2] == 3)
  rp = N.route_pairs({ s(true), s(false), s(true) }, true)
  check("pairs undisc", #rp == 2 and rp[1][2] == 2 and rp[2][1] == 2 and rp[2][2] == 3)
  rp = N.route_pairs({ s(true), s(true, 0 / 0), s(true) }, false)
  check("pairs skip nan", #rp == 1 and rp[1][2] == 3)
  check("pairs one stop", #N.route_pairs({ s(true) }, false) == 0)
  check("pairs nil discovered counts",
    #N.route_pairs({ { pos = { x = 0, y = 0, z = 0 } }, s(true) }, false) == 1)
end

-- fit
do
  local pts = { { 0, 0, 100, 0 }, { 100, 0, 300, 0 } }
  local f = N.fit(pts, 2, nil, {})
  check("fit 2 points", f and math.abs(f.s - 2) < 1e-9 and f.residual < 0.01)

  local function mk(fx)
    local p = {}
    for i, m in ipairs({ { 0, 0 }, { 100, 0 }, { 0, 100 }, { 40, 70 } }) do
      local lx, ly = fx(m[1], m[2])
      p[i] = { m[1], m[2], lx, ly }
    end
    return p
  end
  local ps = mk(function(mx, mz) return 2 * mx + 100, -2 * mz + 50 end)
  local out = {}
  f = N.fit(ps, 3, nil, out)
  check("fit returns out", f == out)
  check("fit signs", f and f.s and math.abs(f.s - 2) < 1e-9 and f.sx == 1 and f.sz == -1)
  check("fit residual", f and f.residual < 0.01)
  if f then
    local lx, ly = N.fit_apply(f, 40, 70)
    check("fit_apply", math.abs(lx - 180) < 1e-6 and math.abs(ly - (-90)) < 1e-6)
  end
  local flip = mk(function(mx, mz) return -3 * mx + 10, 3 * mz + 20 end)
  f = N.fit(flip, 4, nil, {})
  check("fit sx flip", f and f.sx == -1 and f.sz == 1 and math.abs(f.s - 3) < 1e-9)

  check("fit too close", N.fit({ { 0, 0, 0, 0 }, { 100, 0, 10, 0 } }, 2, nil, {}) == nil)
  check("fit one point", N.fit({ { 0, 0, 0, 0 } }, 1, nil, {}) == nil)

  local th = math.rad(30)
  local c, sn = math.cos(th), math.sin(th)
  local rot = mk(function(mx, mz)
    local ux, uy = 2 * mx, -2 * mz
    return 100 + c * ux - sn * uy, 50 + sn * ux + c * uy
  end)
  f = N.fit(rot, 3, { similarity = true }, {})
  check("fit similarity", f and f.residual < 0.01)
  if f then
    local lx, ly = N.fit_apply(f, rot[4][1], rot[4][2])
    check("fit similarity apply", math.abs(lx - rot[4][3]) < 1e-6
      and math.abs(ly - rot[4][4]) < 1e-6)
  end
  f = N.fit(rot, 3, nil, {})
  check("fit rotated plain residual", f and f.residual > 2)
  f = N.fit(ps, 3, { similarity = true }, {})
  check("fit similarity on plain data", f and f.residual < 0.01)
end

-- route_polyline
do
  local fit = { a = 2, b = 0, c = 0, d = 2, ox = 10, oy = 20 }
  local ends = { { lx = 1, ly = 2 }, { lx = 3, ly = 4 }, { lx = 5, ly = 6 } }
  local out = {}
  local n = N.route_polyline({ { i = 1, j = 3 } }, ends, nil, 0, out)
  check("polyline mode 0", n == 4 and out[1] == 1 and out[2] == 2 and out[3] == 5
    and out[4] == 6 and out[5] == nil)
  local pairs1 = { { i = 1, j = 3, pts = { 1, 0, 1, 2, 0, 2, 3, 0, 3 } } }
  n = N.route_polyline(pairs1, ends, fit, 1, out)
  check("polyline mode 1", n == 10 and out[3] == 12 and out[4] == 22
    and out[7] == 16 and out[8] == 26 and out[9] == 5 and out[10] == 6)
  n = N.route_polyline({ { i = 1, j = 3 } }, ends, fit, 1, out)
  check("polyline walking path omits missing geometry", n == 0 and #out == 0)
  n = N.route_polyline(pairs1, ends, fit, 0, out)
  check("polyline mode 1 off", n == 4)
  n = N.route_polyline(pairs1, ends, nil, 1, out)
  check("polyline no fit straight", n == 4)
  n = N.route_polyline({ { i = 1, j = 3 } }, { { lx = 1, ly = 2 }, nil, { mx = 5, mz = 6 } },
    fit, 0, out)
  check("polyline map end fitted", n == 4 and out[3] == 20 and out[4] == 32)
  n = N.route_polyline({ { i = 1, j = 3 } }, { { lx = 1, ly = 2 }, nil, { mx = 5, mz = 6 } },
    nil, 0, out)
  check("polyline map end no fit omitted", n == 0 and #out == 0)
  n = N.route_polyline({ { i = 1, j = 2 } }, { { lx = 1, ly = 2 } }, fit, 0, out)
  check("polyline nil end omitted", n == 0)
  n = N.route_polyline({ { i = 1, j = 2 }, { i = 2, j = 3 } }, ends, fit, 0, out)
  check("polyline separator", n == 9 and out[5] == false and out[6] == 3 and out[9] == 6)
  n = N.route_polyline({ { i = 1, j = 2 } }, ends, fit, 0, out)
  check("polyline clears tail", n == 4 and #out == 4 and out[5] == nil)
end

-- leg_steps and polyline starts
do
  local function steps(pr, cur, out)
    local n = N.leg_steps(pr, cur, out)
    return n, table.concat(out, ",", 1, n)
  end
  local p3 = { { i = 1, j = 2 }, { i = 2, j = 3 }, { i = 3, j = 4 } }
  local out = { 9, 9, 9, 9, 9 }
  local n, s = steps(p3, 2, out)
  check("leg_steps", n == 3 and s == "2,0,1" and out[4] == nil and out[5] == nil)
  n, s = steps(p3, nil, out)
  check("leg_steps no current", n == 3 and s == "0,0,0")
  n, s = steps(p3, 4, out)
  check("leg_steps overnight", n == 3 and s == "0,1,2")
  n, s = steps({ { i = 2, j = 3 }, { i = 3, j = 4 } }, 1, out)
  check("leg_steps overnight short", n == 2 and s == "0,1")
  n, s = steps({ { i = 1, j = 2 }, { i = 2, j = 4 }, { i = 4, j = 5 } }, 3, out)
  check("leg_steps spanning", n == 3 and s == "2,0,1")

  local ends = { { lx = 1, ly = 2 }, { lx = 3, ly = 4 }, { lx = 5, ly = 6 } }
  local o, st = {}, {}
  n = N.route_polyline({ { i = 1, j = 2 }, { i = 2, j = 3 } }, ends, nil, 0, o, st)
  check("route_polyline starts", n == 9 and st[1] == 1 and st[2] == 6 and o[5] == false)
  n = N.route_polyline({ { i = 1, j = 2 }, { i = 2, j = 9 }, { i = 2, j = 3 } }, ends, nil, 0, o, st)
  check("route_polyline starts skipped", n == 9 and st[1] == 1 and st[2] == 0 and st[3] == 6)
  local o2 = {}
  local n2 = N.route_polyline({ { i = 1, j = 2 }, { i = 2, j = 3 } }, ends, nil, 0, o2)
  local parts = {}
  for i = 1, n2 do parts[i] = tostring(o2[i]) end
  check("route_polyline starts nil same output",
    n2 == 9 and #o2 == 9 and table.concat(parts, ",") == "1,2,3,4,false,3,4,5,6")
  n = N.route_polyline({ { i = 1, j = 2 } }, ends, nil, 0, o, st)
  check("route_polyline starts cleared past last pair",
    n == 4 and st[1] == 1 and st[2] == nil and st[3] == nil)
end

-- review fixes: stale pops, freed finished jobs, cleared failed fits
do
  local g = { n = 3, x = { 0, 1, 2 }, y = { 0, 0, 0 }, z = { 0, 0, 0 },
    ls = { 1, 2, 3 }, lc = { 1, 1, 0 }, lt = { 2, 3 } }
  local t = 0
  local clk = function() t = t + 0.001; return t end
  local j = N.path_new(g, 1, 3)
  check("stale: first step running", N.path_step(j, 0.5, clk) == "running" and j.expanded == 1)
  -- node 1 is closed; put a stale entry for it on top of the heap
  j.hk = { 0.5, 5 }; j.hv = { 1, 2 }; j.hn = 2
  check("stale: still expands one", N.path_step(j, 0.5, clk) == "running" and j.expanded == 2)
  local done = N.path_new(g, 1, 3)
  check("freed done", N.path_step(done, 1e9, function() return 0 end) == "done"
    and done.gs == nil and done.parent == nil and done.closed == nil
    and done.hk == nil and done.hv == nil and #done.path == 3)
  local same = N.path_new(g, 2, 2)
  check("freed a==b", same.gs == nil and same.hk == nil and same.path[1] == 2)
  local fail = N.path_new(g, 3, 1)
  check("freed failed", N.path_step(fail, 1e9, function() return 0 end) == "failed"
    and fail.gs == nil and fail.parent == nil and fail.closed == nil
    and fail.hk == nil and fail.hv == nil)
  local capj = N.path_new(g, 1, 3, { cap = 1 })
  check("freed cap", N.path_step(capj, 1e9, function() return 0 end) == "failed"
    and capj.gs == nil and capj.hv == nil)
  local out = {}
  local ok = N.fit({ { 0, 0, 100, 0 }, { 100, 0, 300, 0 } }, 2, nil, out)
  check("fit ok before clear", ok == out and out.a ~= nil)
  check("fit nil clears (close)", N.fit({ { 0, 0, 0, 0 }, { 100, 0, 10, 0 } }, 2, nil, out) == nil
    and out.a == nil and out.s == nil and out.residual == nil and out.ox == nil)
  N.fit({ { 0, 0, 100, 0 }, { 100, 0, 300, 0 } }, 2, nil, out)
  check("fit nil clears (one point)", N.fit({ { 0, 0, 0, 0 } }, 1, nil, out) == nil and out.a == nil)
  check("fit nil without out", N.fit({ { 0, 0, 0, 0 } }, 1, nil) == nil)
end

-- schedule overrides and key locations (SPEC 25)
do
  local function krow(sh, eh, area, loc, key)
    return row(sh, eh, area, 0, { location = loc, key = key })
  end
  local function kpos(r) return { x = r.key or r.area, y = 0, z = r.location } end
  local base = { krow(6, 18, -1, 7), krow(18, 6, 42, -1) }
  local ow = krow(20, 22, -1, -1, 2309)
  local day = { week = 1, weekday = 5 }
  local function at(h) return { week = day.week, weekday = day.weekday, hour = h } end
  local P = { x = 1, y = 2, z = 3 }
  local function ft(stops)
    local o = {}
    for i, s in ipairs(stops) do o[i] = s.from .. "/" .. s.to end
    return table.concat(o, ",")
  end

  local s, _, m = N.route_stops(base, at(20), kpos,
    { area = -1, location = -1, key = 2309, pos = P, overwrite = { ow } })
  check("albert hour 20 stops", #s == 4 and ft(s) == "6/18,18/20,20/22,22/6")
  check("albert hour 20 pos", s[3].pos == P and s[3].key == 2309)
  check("albert hour 20 matched", m == true)

  s, _, m = N.route_stops(base, at(7), kpos,
    { area = -1, location = 7, key = -1, pos = P, overwrite = { ow } })
  local want = kpos(ow)
  check("albert hour 7 key pos", s[3].pos ~= P and s[3].pos.x == want.x
    and s[3].pos.y == want.y and s[3].pos.z == want.z)
  check("albert hour 7 current pos", s[1].pos == P)
  check("albert hour 7 matched", m == true)

  s = N.route_stops(base, at(20), kpos, { area = -1, location = -1, key = 11, pos = P,
    overwrite = { krow(20, 22, -1, -1, 11), krow(20, 22, -1, -1, 12) } })
  check("first overwrite wins", s[3].from == 20 and s[3].to == 22 and s[3].key == 11)

  s = N.route_stops(base, at(20), kpos, { area = 42, location = -1, pos = P,
    overwrite = { row(20, 22, -1, 0, { location = -1, key = 2309, start_week = 2, end_week = 2 }) } })
  check("overwrite not today", #s == 2 and ft(s) == "6/18,18/6")

  local _, _, m2 = N.route_stops({ krow(0, 24, -1, -1, 5) }, at(3), kpos,
    { area = -1, location = -1, key = 9, pos = P })
  check("different keys no match", m2 == false)
  local s5 = N.route_stops({ krow(0, 24, -1, -1, 5) }, at(3), kpos,
    { area = -1, location = -1, key = 9, pos = P })
  check("different keys pos from area_pos", s5[1].pos.x == 5)

  local _, _, m3 = N.route_stops({ krow(0, 24, -1, -1) }, at(3), kpos,
    { area = -1, location = -1, pos = P })
  check("keyless -1/-1 no match", m3 == false)

  s = N.route_stops({ krow(0, 6, -1, -1, 5), krow(22, 24, -1, -1, 6) }, at(3), kpos, nil)
  check("no midnight merge across keys", #s == 2)

  s = N.route_stops({ krow(0, 6, -1, -1, 5), krow(6, 24, -1, -1, 6) }, at(3), kpos, nil)
  check("no run merge across keys", #s == 2)

  local _, _, m7 = N.route_stops({ krow(0, 24, 5, 7, 9) }, at(3), kpos,
    { area = 5, location = 7, pos = P })
  check("key on one side no match", m7 == false)

  local _, _, m4 = N.route_stops(base, at(20), kpos,
    { area = 42, location = -1, pos = P, overwrite = { ow } })
  check("overwrite unmatched", m4 == false)

  local _, _, m5 = N.route_stops(base, at(7), kpos, nil)
  check("nil cur matched", m5 == true)
  local _, _, m6 = N.route_stops({ krow(0, 5, -1, 7) }, at(7), kpos,
    { area = -1, location = 7, pos = P })
  check("no row picked unmatched", m6 == false)
end

-- has_text: an items-only entry has nothing to show (final review S1)
do
  local h = N.parse_hints({ ["1"] = { items = { 300 } }, ["2"] = { quest = "q" },
    ["3"] = { steps = { ["0"] = { text = "t" } } } })
  check("has_text items only", N.has_text(h[1]) == false)
  check("has_text quest text", N.has_text(h[2]) == true)
  check("has_text step text", N.has_text(h[3]) == true)
  check("has_text nil", N.has_text(nil) == false)
end

do
  local q, catalog = N.parse_quests({ version = 1, pak = "p7", quests = {
    ["10010"] = { cast = { 5, 6.0, -1, 2.5, "7" }, npcs = { 8 }, items = { 300 },
      dest = { { cid = 9 }, { key = 44 }, { cid = 0, key = 0 }, "x", { cid = 10, key = 45 } },
      decoded = true },
    ["1.5"] = { cast = { 1 } }, ["-3"] = {}, abc = {}, ["10020"] = "x",
    ["10030"] = { cast = 5, npcs = { a = 1 }, decoded = false } } })
  local a = q[10010]
  check("quests: lists keep positive whole numbers", a and table.concat(a.cast, ",") == "5,6"
    and math.type(a.cast[2]) == "integer" and a.npcs[1] == 8 and a.items[1] == 300 and a.decoded == true)
  check("quests: dest keeps entries with a positive cid or key", a and #a.dest == 3
    and a.dest[1].cid == 9 and a.dest[1].key == nil and a.dest[2].key == 44
    and a.dest[3].cid == 10 and a.dest[3].key == 45)
  local b = q[10030]
  check("quests: bad fields become empty lists", b and #b.cast == 0 and #b.npcs == 0
    and #b.items == 0 and #b.dest == 0 and b.decoded == false)
  check("quests: bad keys and non-table entries dropped", q[10020] == nil
    and catalog == nil)
  q, catalog = N.parse_quests(nil)
  check("quests: nil input", next(q) == nil and catalog == nil)
  q, catalog = N.parse_quests({ pak = 5 })
  check("quests: no quests table, non-string pak", next(q) == nil and catalog == nil)
  q, catalog = N.parse_quests({ version = "1", quests = { ["5"] = { decoded = 1 } } })
  check("quests: decoded only when true, version only when a number",
    q[5] and q[5].decoded == false and catalog == nil)
end

-- SPEC 40: v2 catalog is additive, validated, and isolated per quest.
do
  local legacy, catalog = N.parse_quests({ version = 2, quests = {
    ["10"] = { cast = { 7 }, tasks = {
      { index = 0, has_destination = false, destinations = {} },
      { index = 1, has_destination = true, destinations = {
        { index = 0, set_destination = true, dest_type = 1, cid = 4294967295,
          key = nil, area = 0, local_area = nil, has_show_conditions = false,
          show_conditions = {}, is_update_condition = false,
          has_display_conditions = false, display_conditions = {} },
      } },
    }, guidance = {}, deliveries = {} },
    ["11"] = { tasks = { { index = 1, has_destination = false, destinations = {} } } },
  } })
  check("quests v2: second return is objective catalog with stable zero based task indices",
    legacy[10] and legacy[10].cast[1] == 7 and catalog and catalog.version == 2
      and catalog.quests[10] and #catalog.quests[10].tasks == 2
      and catalog.quests[10].tasks[1].index == 0
      and catalog.quests[10].tasks[2].index == 1
      and catalog.quests[10].tasks[2].destinations[1].cid == 4294967295)
  check("quests v2: one malformed quest does not disable another",
    catalog and catalog.quests[10] ~= nil and catalog.quests[11] == nil
      and #catalog.diagnostics > 0)
end
do
  local nested = { operator = "or", operator_value = 1, parameters = {
    { kind = "processor_result", proc_id = 21, result_no = 0,
      action_type = "app.quest.action.Trigger", result_status = "observed" },
  }, children = {} }
  local row = { family = "quest_reward", quest_id = 12,
    source_identity = { quest_id = 12, action_ordinal = 0, processor_id = 34 },
    action_type = "app.quest.action.QuestReward", ownership_status = "exact",
    branch_status = "unverified", branch_diagnostics = {
      "predecessor_action_semantics_unverified",
    }, precondition = { nested }, reward_rows = { { ordinal = 0, name_hash = 56 } },
    reward_payload_status = "complete", task_endpoint_join = {
      status = "unproven", reason = "journal_task_to_drawable_reward_endpoint_unverified",
    }, unresolved_joins = { "journal_task_to_reward_endpoint",
      "reward_action_to_drawable_target", "current_branch_truth", "claim_state",
      "runtime_reward_hash_to_item_count" }, eligibility = "unknown" }
  local _, catalog = N.parse_quests({ version = 2, quests = {
    ["12"] = { tasks = {}, guidance = {}, deliveries = {},
      reward_diagnostics = { row, { family = "quest_reward", quest_id = 12 } } },
  } })
  local rewards = catalog and catalog.quests[12] and catalog.quests[12].reward_diagnostics
  check("quests v2 rewards: exact nested archive diagnostics survive validation",
    rewards and rewards[1] and rewards[1].source_identity.processor_id == 34
      and rewards[1].precondition[1].parameters[1].action_type == "app.quest.action.Trigger"
      and rewards[1].reward_rows[1].name_hash == 56
      and rewards[1].task_endpoint_join.status == "unproven")
  check("quests v2 rewards: malformed diagnostic is isolated at its stable ordinal",
    rewards and rewards[2] == false and #catalog.diagnostics > 0)
  nested.parameters[1].action_type = "mutated"
  row.reward_rows[1].name_hash = 99
  check("quests v2 rewards: parsed diagnostic is a detached structural copy",
    rewards and rewards[1].precondition[1].parameters[1].action_type == "app.quest.action.Trigger"
      and rewards[1].reward_rows[1].name_hash == 56)
end
do
  local _, catalog = N.parse_quests({ version = 2, quests = {
    ["20"] = { tasks = {}, guidance = {}, deliveries = {}, sources = {
      { id = "same", kind = "placed_pickup", item_ids = { 5 },
        target = { cid = 1, place = nil }, evidence = { provider = "pickup", ref = {} }, inputs = {} },
      { id = "same", kind = "placed_pickup", item_ids = { 5 },
        target = { cid = 2, place = nil }, evidence = { provider = "pickup", ref = {} }, inputs = {} },
    } },
    ["21"] = { tasks = {}, guidance = {}, deliveries = {} },
  } })
  check("quests v2: conflicting source ids suppress every occurrence only",
    catalog and catalog.quests[20] and #catalog.quests[20].sources == 0
      and catalog.quests[21] ~= nil)
end
do
  for _, doc in ipairs({
    { quests = { ["30"] = { cast = { 3 }, tasks = {}, guidance = {}, deliveries = {} } } },
    { version = 1, quests = { ["30"] = { cast = { 3 }, tasks = {}, guidance = {}, deliveries = {} } } },
    { version = 99, quests = { ["30"] = { cast = { 3 }, tasks = {}, guidance = {}, deliveries = {} } } },
  }) do
    local rel, cat = N.parse_quests(doc)
    check("quests compatibility: legacy relations survive without v2 extension",
      rel[30] and rel[30].cast[1] == 3 and cat == nil)
  end
end
do
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["40"] = { tasks = {
      { index = 0, has_destination = false, destinations = {} },
      { index = 2, has_destination = false, destinations = {} },
    }, guidance = {}, deliveries = {} },
  } })
  check("quests v2: malformed task array disables extension without compaction",
    cat and cat.quests[40] == nil and #cat.diagnostics > 0)
end
do
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["50"] = { tasks = {
      { index = 0, has_destination = false, destinations = {
        { index = 0, set_destination = true, dest_type = 0, cid = 4294967296,
          area = 0, has_show_conditions = false, show_conditions = {},
          is_update_condition = false, has_display_conditions = false, display_conditions = {} },
      } },
      { index = 1, has_destination = true, destinations = {} },
    }, guidance = {}, deliveries = {} },
    ["051"] = { tasks = {}, guidance = {}, deliveries = {} },
  } })
  check("quests v2: malformed destination is isolated and later task index stays stable",
    cat and cat.quests[50] and cat.quests[50].tasks[1].destinations[1] == false
      and cat.quests[50].tasks[2].index == 1 and cat.quests[51] == nil)
end
do
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["60"] = { tasks = { { index = 0, has_destination = false, destinations = {
      { index = 0, set_destination = false, dest_type = 0, cid = 4294967295,
        area = -2147483648, local_area = 0, has_show_conditions = true,
        show_conditions = { { kind = "quest_variable", enabled = true, is_not = false,
          qid = 2147483647, name_hash = 4294967295, value_type = 0,
          compare_type = 0, bool_value = false, int_value = -2147483648 } },
        is_update_condition = true, has_display_conditions = false, display_conditions = {} },
    } } }, guidance = {}, deliveries = {} },
    ["61"] = { tasks = { { index = 0, has_destination = false, destinations = {
      { index = 0, set_destination = true, dest_type = 0, cid = 0, key = 0,
        area = 0, local_area = 4294967296, has_show_conditions = false,
        show_conditions = {}, is_update_condition = false,
        has_display_conditions = false, display_conditions = {} },
    } } }, guidance = {}, deliveries = {} },
  } })
  check("quests v2: signed and unsigned maximum boundaries are accepted",
    cat and cat.quests[60] and cat.quests[60].tasks[1].destinations[1].cid == 4294967295
      and cat.quests[60].tasks[1].destinations[1].area == -2147483648)
  check("quests v2: zero sentinels and overflow values never become targets",
    cat and cat.quests[61] and cat.quests[61].tasks[1].destinations[1] == false)
end
do
  local _, cat = N.parse_quests({ version = 2, sources = {
    { id = "source:1|é", kind = "placed_pickup", item_ids = { 5 },
      target = { cid = nil, place = { kind = "local_area", local_area = 0 } },
      evidence = { provider = "pickup", ref = { index = 1 } }, inputs = {} },
    { id = "source:1|é", kind = "placed_pickup", item_ids = { 5 },
      target = { cid = nil, place = { kind = "local_area", local_area = 0 } },
      evidence = { provider = "pickup", ref = { index = 1 } }, inputs = {} },
  }, quests = { ["70"] = { tasks = {}, guidance = {}, deliveries = {} } } })
  check("quests v2: identical repeated source descriptors keep one stable id",
    cat and #cat.sources == 1 and cat.sources[1].id == "source:1|é")
end
do
  local _, cat = N.parse_quests({ version = 2, sources = {
    { id = "global-position", kind = "placed_pickup", item_ids = { 5 },
      target = { place = { kind = "position", x = 1.5, y = -2, z = 3 } },
      evidence = { provider = "pickup", ref = { index = 1 } }, inputs = {} },
  }, quests = { ["73"] = { tasks = {}, guidance = {}, deliveries = {}, sources = {
    { id = "quest-position", kind = "quest_reward", item_ids = { 6 },
      target = { place = { kind = "position", x = -4, y = 5.25, z = 6 } },
      evidence = { provider = "reward", ref = { index = 2 } }, inputs = {} },
  } } } })
  check("quests v2: top-level and quest-local position sources stay connected",
    cat and #cat.sources == 1 and cat.sources[1].target.place.kind == "position"
      and cat.sources[1].target.place.x == 1.5
      and cat.quests[73] and #cat.quests[73].sources == 1
      and cat.quests[73].sources[1].id == "quest-position"
      and cat.quests[73].sources[1].target.place.y == 5.25)
end
do
  local _, cat = N.parse_quests({ version = 2, sources = {
    { id = "cross-scope-conflict", kind = "placed_pickup", item_ids = { 5 },
      target = { cid = 1 }, evidence = { provider = "pickup", ref = {} }, inputs = {} },
  }, quests = { ["74"] = { tasks = {}, guidance = {}, deliveries = {}, sources = {
    { id = "cross-scope-conflict", kind = "placed_pickup", item_ids = { 5 },
      target = { cid = 2 }, evidence = { provider = "pickup", ref = {} }, inputs = {} },
  } } } })
  check("quests v2: conflicting source ids are removed across ownership scopes",
    cat and #cat.sources == 0 and cat.quests[74] and #cat.quests[74].sources == 0
      and #cat.diagnostics > 0)
end
do
  local good_delivery = { key = 3, serial = 3, incomplete_possible = true, operator = 0,
    groups = { { index = 0, item_ids = { 5, 6 }, count = 2, is_all_item = false,
      is_infinite = false, ignore_restriction_items = {} } } }
  local function guidance(index, group_id, ref_key)
    return { index = index, task_index = 0, destinations = {
      { index = 0, target = { kind = "key_location", key = 9 }, cid = nil,
        concierge_type = 1, gimmick_id = 0, is_chara_at_destination = false,
        register_conditions = {}, conditions = {}, delivery = { is_not = false,
          check_storage = true, group_id = group_id,
          refs = { { qid = 72, key = ref_key, serial = ref_key } } } },
    } }
  end
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["71"] = { tasks = {}, guidance = { guidance(0, 0, 3), guidance(1, 1, 3) }, deliveries = {} },
    ["72"] = { tasks = {}, guidance = {}, deliveries = { good_delivery } },
  } })
  check("quests v2: exact cross-quest delivery key joins and valid group index survive",
    cat and cat.quests[71] and cat.quests[71].guidance[1].destinations[1].delivery.refs[1].serial == 3
      and cat.quests[71].guidance[1].destinations[1].delivery.group_id == 0)
  check("quests v2: invalid delivery group disables only its destination association",
    cat and cat.quests[71] and cat.quests[71].guidance[2].destinations[1] == false
      and cat.quests[72] ~= nil)
end
do
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["80"] = { tasks = { { index = 0, has_destination = false, destinations = {} } },
      guidance = {}, deliveries = {} },
    ["081"] = { tasks = {}, guidance = {}, deliveries = {} },
  } })
  check("quests v2: quest ids require canonical positive signed-32-bit decimals",
    cat and cat.quests[80] ~= nil and cat.quests[81] == nil)
end
do
  local keep = { key = 7, serial = 7, incomplete_possible = false, operator = 1,
    groups = { { index = 0, item_ids = { 12 }, count = 1, is_all_item = true,
      is_infinite = false, ignore_restriction_items = {} } } }
  local _, cat = N.parse_quests({ version = 2, quests = {
    ["90"] = { tasks = {}, guidance = {}, deliveries = {
      { key = 8, serial = 9, incomplete_possible = false, operator = 0, groups = {} }, keep,
    } },
  } })
  check("quests v2: malformed delivery record is isolated from valid definitions",
    cat and cat.quests[90] and #cat.quests[90].deliveries == 2
      and cat.quests[90].deliveries[1] == false
      and cat.quests[90].deliveries[2].key == 7)
end
do
  local ref = { placement = { stable = "before" } }
  local _, cat = N.parse_quests({ version = 2, sources = {
    { id = "copy-check", kind = "placed_pickup", item_ids = { 1 },
      target = { place = { kind = "key_location", key = 2 } },
      evidence = { provider = "pickup", ref = ref }, inputs = {} },
  }, quests = { ["91"] = { tasks = {}, guidance = {}, deliveries = {} } } })
  ref.placement.stable = "after"
  check("quests v2: normalized source evidence is a detached structural copy",
    cat and cat.sources[1].evidence.ref.placement.stable == "before")
end
do
  local reminder = { kind = "quest_log_reminder",
    reminder_msg_id = "00000000-0000-0000-0000-000000000002",
    is_finished = true, is_or = false, reminders = {} }
  local artifact_shaped = { version = 2, quests = { ["100"] = {
    cast = { 4294967295 }, npcs = { 4294967295 }, items = { 2147483647 },
    dest = { { cid = 4294967295, key = 2147483647 } },
    tasks = {}, deliveries = { { key = 0, serial = 0, incomplete_possible = false,
      operator = 1, groups = { { index = 0, item_ids = { 1 }, count = 1,
        is_all_item = false, is_infinite = false, ignore_restriction_items = {} } } } },
    guidance = { { index = 0, task_index = 1, destination_index = 0, destinations = {
      { index = 0, target = { kind = "local_area", local_area = 2147483647 }, cid = nil,
        concierge_type = 1, gimmick_id = -2147483648, is_chara_at_destination = false,
        register_conditions = { { kind = "item", enabled = true, is_not = false,
          item_id = 1, set_num = true, num = 2 } },
        conditions = { { kind = "quest_log_reminder",
          reminder_msg_id = "00000000-0000-0000-0000-000000000001",
          is_finished = false, is_or = true, reminders = { reminder } } },
        delivery = { is_not = false, check_storage = true, group_id = 0,
          refs = { { qid = 100, key = 0, serial = 0 } } } },
    } } },
  } } }
  local rel, catalog = N.parse_quests(artifact_shaped)
  local q = catalog and catalog.quests[100]
  check("quests artifact shape: unsigned legacy NPC fields preserve U32 max",
    rel[100] and rel[100].cast[1] == 4294967295 and rel[100].npcs[1] == 4294967295
      and rel[100].dest[1].cid == 4294967295)
  check("quests artifact shape: zero delivery key/serial resolves without rejection",
    q and q.deliveries[1] and q.deliveries[1].key == 0 and q.guidance[1]
      and type(q.guidance[1].destinations[1]) == "table"
      and q.guidance[1].destinations[1].delivery.refs[1].serial == 0)
  check("quests artifact shape: bool item set_num and recursive reminder records survive",
    q and q.guidance[1] and type(q.guidance[1].destinations[1]) == "table"
      and q.guidance[1].destinations[1].register_conditions[1].set_num == true
      and q.guidance[1].destinations[1].conditions[1].reminders[1].is_finished == true
      and q.guidance[1].destinations[1].conditions[1].reminders[1].kind == "quest_log_reminder"
      and q.guidance[1].destinations[1].conditions[1].reminders[1].reminders ~= nil)
  check("quests artifact shape: parent destination index and signed fields preserve wire values",
    q and q.guidance[1] and type(q.guidance[1].destinations[1]) == "table"
      and q.guidance[1].destination_index == 0
      and q.guidance[1].destinations[1].gimmick_id == -2147483648
      and q.guidance[1].destinations[1].target.local_area == 2147483647)
  local wrong_reminder = { version = 2, quests = { ["100"] = artifact_shaped.quests["100"] } }
  wrong_reminder.quests["100"].guidance[1].destinations[1].conditions[1].reminders[1].kind = "quest_log_condition"
  local _, invalid_catalog = N.parse_quests(wrong_reminder)
  check("quests artifact shape: recursive reminder record kind is validated",
    invalid_catalog and invalid_catalog.quests[100]
      and invalid_catalog.quests[100].guidance[1].destinations[1] == false)
end

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("npcs_test: all passed")
