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

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("npcs_test: all passed")
