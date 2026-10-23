-- tests/npcs_test.lua - NPC routes, affinity tiers, quest items, hints
-- (SPEC 22.5, 22.8, 22.9.4, 22.10.1, 22.11).
package.path = package.path .. ";./reframework/autorun/?.lua"
local N = require("Clairvoyance.npcs")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

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

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("npcs_test: all passed")
