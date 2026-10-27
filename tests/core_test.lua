-- tests/core_test.lua
package.path = "./reframework/autorun/?.lua;" .. package.path
local core = require("Clairvoyance.core")
local SHOW_ALL = { startable=true, in_progress=true, completed=true, unavailable=true, locked=true }

local function base_adapter(over)
  local a = {
    acceptable_ids = function() return {} end,
    progressing_ids = function() return {} end,
    is_side = function() return true end,
    is_unavailable = function() return false end,
    giver_hint = function() return nil end,
    is_generic = function() return false end,
    cast_ids = function() return nil end,
    catalog_pos = function() return nil end,
    static_pos = function() return nil end,
    npc_alive = function() return true end,
    npc_pos = function() return nil end,
    quest_name = function(qid) return "Q" .. qid end,
    quest_state = function() return nil end,
    catalog_ids = function() return {} end,
  }
  for k, v in pairs(over or {}) do a[k] = v end
  return a
end

-- Data-driven adapter for v2 cases: each key is a table; absent keys are empty.
local function fake_adapter(o)
  local a = {}
  local function g(k) return o[k] or {} end
  a.acceptable_ids = function() return g("acceptable") end
  a.progressing_ids = function() return g("progressing") end
  a.catalog_ids = function() return g("catalog") end
  a.quest_state = function(q) return g("states")[q] end
  a.npc_alive = function(c) return not g("dead")[c] end
  a.cast_ids = function(q) return g("casts")[q] end
  a.static_pos = function(q) return g("statics")[q] end
  a.catalog_pos = function(q)
    local p = g("catpos")[q]; if p then return p.x, p.y, p.z end
  end
  a.npc_pos = function(c)
    local p = g("npc_pos")[c]; if p then return p.x, p.y, p.z end
  end
  a.giver_hint = function(q) return g("hints")[q] end
  a.quest_name = function(q) return g("names")[q] end
  a.is_side = function() return true end
  a.is_generic = function() return false end
  a.is_unavailable = function(q) return a.quest_state(q) ~= nil end
  a.objective_cids = function(q) return g("objectives")[q] end
  if o.gates then
    a.gate_qids = function(q)
      if o.gate_calls then o.gate_calls[#o.gate_calls + 1] = q end
      return o.gates[q]
    end
  end
  if o.regions then
    a.quest_region = function(q)
      if o.region_calls then o.region_calls[#o.region_calls + 1] = q end
      return o.regions[q]
    end
  end
  if o.tgates then
    a.tree_gate_qids = function(q)
      if o.tgate_calls then o.tgate_calls[#o.tgate_calls + 1] = q end
      return o.tgates[q]
    end
  end
  if o.name_calls then
    local base = a.quest_name
    a.quest_name = function(q) o.name_calls[#o.name_calls + 1] = q; return base(q) end
  end
  if o.seen then a.seen_quest_name = function(q) return o.seen[q] end end
  if o.item_needs then
    a.item_needs = function() return o.item_needs end
    a.item_locations = function() return o.item_locs or {} end
    a.item_name = function(id)
      if o.item_name_calls then o.item_name_calls[#o.item_name_calls + 1] = id end
      return (o.item_names or {})[id]
    end
  end
  a.npc_name = function(c) return g("npc_names")[c] end
  a.objective_pos = function(c)
    local p = g("objective_pos")[c]; if p then return p.x, p.y, p.z end
  end
  return a
end

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")

-- SPEC 37.5: one cached overhead state read per frame, with disabled reads
-- clearing the cached reason without calling the reader.
do
  local block = core.overhead_block
  check("overhead_block export", type(block) == "function")
  if type(block) == "function" then
    local cache = { frame = -1, reason = nil }
    local calls, next_reason = 0, "menu"
    local function reader()
      calls = calls + 1
      return next_reason
    end
    check("overhead block disabled stamps frame without read",
      block(cache, 1, false, reader) == nil and cache.frame == 1
      and cache.reason == nil and calls == 0)
    check("overhead block caches same frame reason",
      block(cache, 2, true, reader) == "menu"
      and block(cache, 2, true, reader) == "menu" and calls == 1)
    next_reason = "cutscene"
    check("overhead block rereads on next frame",
      block(cache, 3, true, reader) == "cutscene" and calls == 2)
    check("overhead block disabled clears same-frame reason",
      block(cache, 3, false, reader) == nil and cache.frame == 3
      and cache.reason == nil and calls == 2)
    check("overhead block disabled stamps next frame without read",
      block(cache, 4, false, reader) == nil and cache.frame == 4
      and cache.reason == nil and calls == 2)
    next_reason = nil
    check("overhead block caches nil for a frame",
      block(cache, 5, true, reader) == nil
      and block(cache, 5, true, reader) == nil and calls == 3
      and cache.frame == 5 and cache.reason == nil)
  end
end

-- 1. unavailable game state
check("nil acceptable -> nil result",
  core.compute(base_adapter({ acceptable_ids = function() return nil end }), SHOW_ALL) == nil)
check("nil progressing -> nil result",
  core.compute(base_adapter({ progressing_ids = function() return nil end }), SHOW_ALL) == nil)

-- 2. empty world
local r = core.compute(base_adapter(), SHOW_ALL)
check("empty: no markers", r ~= nil and #r.markers == 0 and r.counts.startable == 0)

-- Catalog debug count is derived during the distinct quest union walk.
do
  local side_calls, total_calls = {}, 0
  local a = base_adapter({
    acceptable_ids = function() return { 101, 105 } end,
    progressing_ids = function() return { 102 } end,
    catalog_ids = function() return { 101, 102, 103, 104 } end,
    is_side = function(qid)
      total_calls = total_calls + 1
      side_calls[qid] = (side_calls[qid] or 0) + 1
      return qid ~= 104
    end,
  })
  local counted = core.compute(a, SHOW_ALL)
  check("catalog side count: overlap and live-only matrix", counted.catalog_side_count == 3)
  check("catalog side count: catalog overlap survives earlier union dedupe",
    side_calls[101] == 1 and side_calls[102] == 1)
  check("catalog side count: is_side once per unique union qid",
    total_calls == 5 and side_calls[101] == 1 and side_calls[102] == 1
      and side_calls[103] == 1 and side_calls[104] == 1 and side_calls[105] == 1)

  counted = core.compute(base_adapter({
    acceptable_ids = function() return {} end,
    progressing_ids = function() return {} end,
    catalog_ids = function() return nil end,
  }), SHOW_ALL)
  check("catalog side count: nil catalog is zero", counted.catalog_side_count == 0)
  counted = core.compute(base_adapter({
    acceptable_ids = function() return {} end,
    progressing_ids = function() return {} end,
    catalog_ids = function() return {} end,
  }), SHOW_ALL)
  check("catalog side count: empty catalog is zero", counted.catalog_side_count == 0)

  local catalog = { 111 }
  local changing = base_adapter({
    acceptable_ids = function() return {} end,
    progressing_ids = function() return {} end,
    catalog_ids = function() return catalog end,
  })
  local first = core.compute(changing, SHOW_ALL)
  catalog = { 111, 112, 113 }
  local second = core.compute(changing, SHOW_ALL)
  check("catalog side count: refreshes on each compute",
    first.catalog_side_count == 1 and second.catalog_side_count == 3)
end

-- 3. filters
r = core.compute(base_adapter({
  acceptable_ids = function() return {10, 20, 30, 40} end,
  progressing_ids = function() return {20} end,
  is_side = function(q) return q ~= 30 end,
  quest_state = function(q) if q == 40 then return "completed" end end,
  giver_hint = function(q) return q == 10 and 5 or nil end,
  npc_pos = function(c) if c == 5 then return 1, 2, 3 end end,
}), SHOW_ALL)
check("filters: only qid 10 survives", #r.markers == 1 and r.markers[1].qids[1] == 10)
check("npc marker key", r.markers[1].key == "c:5")
check("filters: 40 counted completed", r.counts.completed == 1)

-- 4. dead hint: v1 skip is gone by design (SPEC 9.2f): giver_dead, resolves via static
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  giver_hint = function() return 5 end,
  npc_alive = function() return false end,
  static_pos = function() return {x=1,y=1,z=1} end,
}), SHOW_ALL)
check("dead hint: giver_dead, resolves via static",
  #r.markers == 1 and r.markers[1].cat == "unavailable"
  and r.counts.giver_dead == 1 and r.counts.startable == 0)

-- 5. absent hint falls through: catalog, then static
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  giver_hint = function() return 5 end,
  npc_pos = function() return nil end,
  catalog_pos = function() return 7.9, -1.1, 9.5 end,
}), SHOW_ALL)
check("absent hint -> catalog pos", #r.markers == 1
  and r.markers[1].pos.x == 7.9 and r.markers[1].pos.y == -1.1
  and r.markers[1].pos.z == 9.5 and r.markers[1].key == "p:7:-2:9")
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  giver_hint = function() return 5 end,
  static_pos = function() return {x=4,y=4,z=4} end,
}), SHOW_ALL)
check("absent hint, no catalog -> static", #r.markers == 1 and r.markers[1].pos.x == 4)

-- 6. can_use_cast: multi-cast with a static fallback -> static wins
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  cast_ids = function() return {6, 7} end,
  npc_pos = function(c) return 100 + c, 0, 0 end,
  static_pos = function() return {x=4,y=4,z=4} end,
}), SHOW_ALL)
check("multi-cast + static -> static", r.markers[1].pos.x == 4)
-- multi-cast WITHOUT static -> first live cast NPC
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  cast_ids = function() return {6, 7} end,
  npc_pos = function(c) return 100 + c, 0, 0 end,
}), SHOW_ALL)
check("multi-cast, no static -> cast NPC", r.markers[1].pos.x == 106)

-- 7. generic NPCs excluded from cast
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  cast_ids = function() return {6, 7} end,
  is_generic = function(c) return c == 6 end,
  npc_pos = function(c) return 100 + c, 0, 0 end,
  static_pos = function() return {x=4,y=4,z=4} end,
}), SHOW_ALL)
check("generic excluded leaves 1 cand -> cast usable", r.markers[1].pos.x == 107)

-- 8. unresolvable -> unresolved list (with the quest's name when known)
r = core.compute(base_adapter({ acceptable_ids = function() return {10} end }), SHOW_ALL)
check("no sources -> unresolved", #r.markers == 0 and r.unresolved[10] ~= nil)
check("unresolved carries name", r.unresolved[10].name == "Q10")
-- 8b. hint ALIVE but position unresolvable and no catalog/static -> unresolved
r = core.compute(base_adapter({
  acceptable_ids = function() return {10} end,
  giver_hint = function() return 5 end,
}), SHOW_ALL)
check("alive hint, nothing resolves -> unresolved",
  #r.markers == 0 and r.unresolved[10] ~= nil and r.counts.startable == 1)

-- 9. grouping + label order + name fallback
r = core.compute(base_adapter({
  acceptable_ids = function() return {30, 10} end,
  giver_hint = function() return 5 end,
  npc_pos = function() return 1, 2, 3 end,
  quest_name = function(q) if q == 10 then return "Alpha" end return nil end,
}), SHOW_ALL)
check("shared giver groups", #r.markers == 1 and #r.markers[1].qids == 2)
check("qids ascending", r.markers[1].qids[1] == 10 and r.markers[1].qids[2] == 30)
check("label join + fallback", r.markers[1].label == "Alpha - startable / Quest 30 - startable")
check("fallback qid recorded as unnamed", r.unnamed[30] == true and r.unnamed[10] == nil)

-- 10. signature hysteresis
local m = { { key = "c:5", pos = {x=0,y=0,z=0}, qids = {10}, label = "Alpha" } }
local sig1, committed = core.signature(m, {})
m[1].pos = {x=3,y=0,z=0}  -- < 5 units
local sig2, committed2 = core.signature(m, committed)
check("<5 units: stable sig", sig1 == sig2)
check("<5 units: pos rewritten to committed", m[1].pos.x == 0)
m[1].pos = {x=6,y=0,z=0}  -- > 5 units
local sig3 = core.signature(m, committed2)
check(">5 units: sig changes", sig3 ~= sig1)

-- 11. quest-set change changes signature
local mA = { { key = "c:5", pos = {x=0,y=0,z=0}, qids = {10, 30}, label = "x" } }
local mB = { { key = "c:5", pos = {x=0,y=0,z=0}, qids = {10}, label = "x" } }
local sA = core.signature(mA, {})
local sB = core.signature(mB, {})
check("qid set in sig", sA ~= sB)

-- 12. label change changes signature (a name resolving later must rebuild)
local mC = { { key = "c:5", pos = {x=0,y=0,z=0}, qids = {10}, label = "Quest 10" } }
local mD = { { key = "c:5", pos = {x=0,y=0,z=0}, qids = {10}, label = "Alpha" } }
check("label in sig", core.signature(mC, {}) ~= core.signature(mD, {}))

-- category assignment and precedence: failed beats completed-shaped quests
do
  local a = fake_adapter({
    acceptable = {}, progressing = {},
    catalog = { 101, 102, 103, 104 },
    states = { [101]="failed", [102]="canceled", [103]="completed" },
    -- 104: no state, not acceptable -> locked
  })
  local r = core.compute(a, SHOW_ALL)
  assert(r.counts.failed == 1 and r.counts.canceled == 1)
  assert(r.counts.completed == 1 and r.counts.locked == 1)
  assert(r.counts.startable == 0)
end

-- acceptable with no hint is startable; in_progress beats state
do
  local a = fake_adapter({ acceptable = { 201 }, progressing = { 202 },
    catalog = {}, states = { [202]="completed" } })
  local r = core.compute(a, SHOW_ALL)
  assert(r.counts.startable == 1)
  assert(r.counts.in_progress == 1)
  assert(r.counts.completed == 0)
end

-- dead hinted giver -> giver_dead, still resolves via static
do
  local a = fake_adapter({ acceptable = { 301 }, hints = { [301] = 9001 },
    dead = { [9001] = true }, statics = { [301] = {x=1,y=2,z=3} } })
  local r = core.compute(a, SHOW_ALL)
  assert(r.counts.giver_dead == 1)
  assert(#r.markers == 1 and r.markers[1].cat == "unavailable")
end

-- no hint, exactly one cast candidate, dead -> giver_dead
do
  local a = fake_adapter({ acceptable = { 302 }, casts = { [302] = { 9002 } },
    dead = { [9002] = true }, statics = { [302] = {x=1,y=2,z=3} } })
  local r = core.compute(a, SHOW_ALL)
  assert(r.counts.giver_dead == 1)
end

-- hidden categories: dropped before resolution, no leaks
do
  local a = fake_adapter({
    acceptable = { 401 }, catalog = { 401, 402 },
    hints = { [401] = 9100, [402] = 9100 },     -- shared giver
    npc_pos = { [9100] = {x=10,y=0,z=10} },
  })  -- 402 has no state, not acceptable -> locked
  local show = { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=false }
  local r = core.compute(a, show)
  assert(r.counts.locked == 1)                 -- counted
  assert(#r.markers == 1)
  assert(r.markers[1].cat == "startable")
  assert(not r.markers[1].label:find("402"))   -- not in label
  assert(r.unresolved[402] == nil and r.unnamed[402] == nil)
end

-- shared position: startable outranks completed for marker color group
do
  local a = fake_adapter({ acceptable = { 501 }, catalog = { 501, 502 },
    states = { [502]="completed" },
    hints = { [501]=9200, [502]=9200 }, npc_pos = { [9200]={x=5,y=0,z=5} } })
  local r = core.compute(a, SHOW_ALL)
  assert(#r.markers == 1 and r.markers[1].cat == "startable")
  assert(r.markers[1].label:find("completed"))  -- state text still in label
  check("core gap: exact shared label",
    r.markers[1].label == "Quest 501 - startable / Quest 502 - completed")
end

-- Adapter states are limited to the three terminal states.
do
  local invalid = { "weird", "startable", "in_progress", "giver_dead", "locked" }
  local states, catalog = {}, {}
  for i, state in ipairs(invalid) do
    local qid = 510 + i
    catalog[#catalog + 1] = qid
    states[qid] = state
  end
  states[520] = "locked"
  local a = fake_adapter({ catalog = catalog, states = states,
    acceptable = { 520 }, hints = { [520] = 9520 }, dead = { [9520] = true },
    statics = { [520] = { x=1, y=2, z=3 } },
    names = { [511]="A", [512]="B", [513]="C", [514]="D", [515]="E", [520]="F" },
    regions = {} })
  local r = core.compute(a, { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=true, tree_open=true })
  local cats = {}
  for _, quest in ipairs(r.quests) do cats[quest.qid] = quest.cat end
  local all_locked = true
  for i = 1, #invalid do if cats[510 + i] ~= "locked" then all_locked = false end end
  check("core gap: category-shaped states fall through to locked", all_locked)
  check("core gap: invalid locked on acceptable quest falls through to giver-dead",
    cats[520] == "giver_dead")
end

-- A dead first candidate among multiple candidates is not a dead sole giver.
do
  local a = fake_adapter({ acceptable = { 530 }, casts = { [530] = { 9530, 9531 } },
    dead = { [9530] = true }, npc_pos = { [9531] = { x=3, y=0, z=4 } } })
  local r = core.compute(a, SHOW_ALL)
  check("core gap: multiple candidates are not a sole dead giver",
    r.counts.startable == 1 and r.counts.giver_dead == 0)
end

-- Omitted visibility uses the settings defaults.
do
  local a = fake_adapter({ acceptable = { 540 }, catalog = { 540, 541 },
    states = { [541] = "completed" }, hints = { [540] = 9540 },
    npc_pos = { [9540] = { x=4, y=0, z=0 } } })
  local r = core.compute(a)
  check("core gap: compute defaults to settings visibility",
    #r.markers == 1 and r.markers[1].qids[1] == 540 and r.counts.completed == 1)
end

-- Exact category wording is used in marker labels.
do
  local a = fake_adapter({ acceptable = { 550 }, progressing = { 551 },
    catalog = { 551 }, hints = { [550] = 9550, [551] = 9551 },
    dead = { [9550] = true }, statics = { [550] = { x=5, y=0, z=0 } },
    npc_pos = { [9551] = { x=6, y=0, z=0 } }, names = { [550]="Dead", [551]="Active" } })
  local r = core.compute(a, SHOW_ALL)
  local labels = {}
  for _, marker in ipairs(r.markers) do labels[marker.qids[1]] = marker.label end
  check("core gap: exact giver-dead label", labels[550] == "Dead - giver dead")
  check("core gap: exact in-progress label", labels[551] == "Active - in progress")
end

-- With the tree open, hidden terminal and locked quests skip giver reads;
-- a hidden acceptable quest still needs candidates for giver_dead.
do
  local hints, casts = {}, {}
  local a = base_adapter({ acceptable_ids = function() return { 561 } end,
    progressing_ids = function() return {} end,
    catalog_ids = function() return { 560, 561, 562 } end,
    quest_state = function(qid) if qid == 560 then return "completed" end end,
    giver_hint = function(qid) hints[#hints + 1] = qid; return nil end,
    cast_ids = function(qid) casts[#casts + 1] = qid; return { 9561 } end,
    npc_alive = function() return false end,
    quest_region = function() return "Vern" end })
  local r = core.compute(a, { startable=false, in_progress=false, completed=false,
    unavailable=false, locked=false, tree_open=true })
  check("core gap: open tree does not trigger hidden terminal/locked giver reads",
    r.quests ~= nil and #hints == 1 and hints[1] == 561
    and #casts == 1 and casts[1] == 561)
end

-- A focused locked quest keeps its giver for related NPC data when Locked is off.
do
  local a = fake_adapter({ catalog = { 570 }, hints = { [570] = 9570 },
    names = { [570] = "Locked" } })
  local r = core.compute(a, { startable=true, in_progress=true, completed=false,
    unavailable=false, locked=false, focus_qids={ 570 } })
  check("core gap: hidden focused locked quest retains giver",
    r.focus ~= nil and r.focus.quests[570] ~= nil and r.focus.quests[570].npcs[1] == 9570)
end

-- A focused nameless locked quest still supplies its giver to focus data.
do
  local hint_reads = 0
  local a = base_adapter({ catalog_ids = function() return { 571 } end,
    quest_name = function() return nil end,
    giver_hint = function() hint_reads = hint_reads + 1; return 9571 end,
    npc_pos = function(cid) if cid == 9571 then return 1, 0, 0 end end })
  local r = core.compute(a, { startable=true, in_progress=true, completed=false,
    unavailable=false, locked=false, focus_qids={ 571 } })
  local focus_marker = false
  for _, marker in ipairs(r.markers) do
    if marker.key == "n:9571" and marker.cat == "focus_npc" then focus_marker = true end
  end
  local quest = r.focus and r.focus.quests[571]
  check("core gap: focused nameless locked quest keeps giver and focus marker",
    hint_reads == 1 and quest ~= nil and quest.npcs[1] == 9571
    and quest.step_npcs[1] == 9571 and focus_marker)
end

-- A focused objective marker still retains its distinct hinted giver.
do
  local hints, casts = 0, 0
  local a = base_adapter({ progressing_ids = function() return { 580 } end,
    giver_hint = function() hints = hints + 1; return 9580 end,
    cast_ids = function() casts = casts + 1; return { 9581 } end,
    objective_cids = function(qid) if qid == 580 then return { 9582 } end end,
    objective_pos = function(cid) if cid == 9582 then return 2, 0, 0 end end,
    npc_pos = function(cid) if cid == 9580 then return 1, 0, 0 end end })
  local r = core.compute(a, { startable=true, in_progress=false, completed=false,
    unavailable=false, locked=false, focus_qids={ 580 } })
  local objective_marker = false
  for _, marker in ipairs(r.markers) do
    if marker.key == "c:9582" then objective_marker = true end
  end
  check("core gap: focused objective position keeps distinct hinted giver",
    objective_marker
    and r.focus.quests[580].npcs[1] == 9580 and hints == 1 and casts == 1)
end

-- Shown candidates are built once per quest per compute, then refreshed next compute.
do
  local candidates, hint_reads, cast_reads = { 9590, 9591 }, 0, 0
  local a = base_adapter({ acceptable_ids = function() return { 590 } end,
    giver_hint = function() hint_reads = hint_reads + 1; return nil end,
    cast_ids = function() cast_reads = cast_reads + 1; return candidates end,
    npc_pos = function(cid) return cid, 0, 0 end })
  local first = core.compute(a, SHOW_ALL)
  check("core gap: shown candidates are built once for category and position",
    #first.markers == 1 and first.markers[1].key == "c:9590"
    and hint_reads == 1 and cast_reads == 1)
  candidates = { 9592, 9593 }
  local second = core.compute(a, SHOW_ALL)
  check("core gap: candidate memo refreshes on next compute",
    #second.markers == 1 and second.markers[1].key == "c:9592"
    and hint_reads == 2 and cast_reads == 2)
end

-- label format: "<name> - <state>"
do
  local a = fake_adapter({ acceptable = { 601 }, hints = { [601]=9300 },
    npc_pos = { [9300]={x=1,y=1,z=1} }, names = { [601]="Alpha" } })
  local r = core.compute(a, SHOW_ALL)
  assert(r.markers[1].label == "Alpha - startable")
end

-- union universe: catalog nil must not hide acceptable quests
do
  local a = fake_adapter({ acceptable = { 701 }, hints = { [701]=9400 },
    npc_pos = { [9400]={x=1,y=1,z=1} } })
  a.catalog_ids = function() return nil end
  local r = core.compute(a, SHOW_ALL)
  assert(#r.markers == 1)
end

-- signature changes when cat changes with same label
do
  local m1 = { { key="c:1", pos={x=1,y=1,z=1}, qids={1}, label="L", cat="startable" } }
  local m2 = { { key="c:1", pos={x=1,y=1,z=1}, qids={1}, label="L", cat="completed" } }
  local s1 = core.signature(m1, {})
  local s2 = core.signature(m2, {})
  assert(s1 ~= s2)
end

-- color precedence must not be "first quest wins": startable has the HIGHER id
do
  local a = fake_adapter({ acceptable = { 502 }, catalog = { 501, 502 },
    states = { [501] = "completed" },
    hints = { [501] = 9200, [502] = 9200 }, npc_pos = { [9200] = {x=5,y=0,z=5} } })
  local r = core.compute(a, SHOW_ALL)
  assert(#r.markers == 1 and r.markers[1].cat == "startable")
end
-- and in_progress (higher id) beats a shown locked (lower id)
do
  local a = fake_adapter({ progressing = { 812 }, catalog = { 811, 812 },
    hints = { [811] = 9210, [812] = 9210 }, npc_pos = { [9210] = {x=5,y=0,z=5} } })
  local r = core.compute(a, SHOW_ALL)
  assert(#r.markers == 1 and r.markers[1].cat == "in_progress")
end

-- hidden quest must not influence a shared marker's color (not just its label)
do
  local a = fake_adapter({ progressing = { 801 }, catalog = { 802 },
    states = { [802] = "completed" },
    hints = { [801] = 9500, [802] = 9500 }, npc_pos = { [9500] = {x=1,y=1,z=1} } })
  local show = { startable=true, in_progress=false, completed=true,
    unavailable=true, locked=true }
  local r = core.compute(a, show)
  assert(#r.markers == 1 and r.markers[1].cat == "completed")
  assert(r.markers[1].label == "Quest 802 - completed")
end

-- visibility filter must run BEFORE resolution: a hidden quest that cannot
-- resolve stays out of unresolved, and hidden quests pay no position calls
do
  local calls = { pos = 0, static = 0 }
  local a = fake_adapter({
    acceptable = { 401 }, catalog = { 401, 402, 403 },
    hints = { [401] = 9100, [402] = 9100 },   -- 403: no hint/cast/static
    npc_pos = { [9100] = {x=10,y=0,z=10} },
  })
  local real_pos, real_static = a.npc_pos, a.static_pos
  a.npc_pos = function(c) calls.pos = calls.pos + 1; return real_pos(c) end
  a.static_pos = function(q)
    if q == 402 or q == 403 then calls.static = calls.static + 1 end
    return real_static(q)
  end
  local show = { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=false }
  local r = core.compute(a, show)
  assert(r.counts.locked == 2)
  assert(r.unresolved[403] == nil, "hidden unresolvable quest leaked")
  assert(r.unresolved[402] == nil and r.unnamed[402] == nil)
  assert(calls.static == 0, "hidden quests paid static_pos calls")
  assert(calls.pos == 1, "hidden quests paid npc_pos calls")
end

-- dead hinted giver resolves via CATALOG position too (not only static)
do
  local a = fake_adapter({ acceptable = { 303 }, hints = { [303] = 9003 },
    dead = { [9003] = true }, catpos = { [303] = {x=7,y=8,z=9} } })
  local r = core.compute(a, SHOW_ALL)
  assert(#r.markers == 1 and r.markers[1].pos.x == 7)
end

-- nameless quest falls back to "Quest <qid> - <state>"
do
  local a = fake_adapter({ acceptable = { 601 }, hints = { [601] = 9300 },
    npc_pos = { [9300] = {x=1,y=1,z=1} } })
  local r = core.compute(a, SHOW_ALL)
  assert(r.markers[1].label == "Quest 601 - startable")
  assert(r.unnamed[601] == true)
end

-- cut/unreleased content: a locked quest with no name from any source
-- gets no marker (counted, but suppressed before resolution) and appears in
-- neither unresolved nor unnamed
do
  local a = fake_adapter({ catalog = { 901, 902 },
    hints = { [901] = 9900, [902] = 9900 },
    npc_pos = { [9900] = {x=1,y=1,z=1} },
    names = { [901] = "Real Future Quest" } })
  local show = { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=true }
  local r = core.compute(a, show)
  check("suppress: both counted", r.counts.locked == 2)
  check("suppress: unnamed locked dropped", #r.markers == 1)
  check("suppress: label kept for named",
    r.markers[1].label == "Real Future Quest - locked")
  check("suppress: not in unresolved", r.unresolved[902] == nil)
  check("suppress: not in unnamed", r.unnamed[902] == nil)
end
-- variant: the suppressed quest has no resolvable position at all
do
  local a = fake_adapter({ catalog = { 903 } })
  local show = { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=true }
  local r = core.compute(a, show)
  check("suppress/no-pos: counted", r.counts.locked == 1)
  check("suppress/no-pos: no marker", #r.markers == 0)
  check("suppress/no-pos: not in unresolved", r.unresolved[903] == nil)
  check("suppress/no-pos: not in unnamed", r.unnamed[903] == nil)
end
-- empty-string name is treated like nil
do
  local a = fake_adapter({ catalog = { 904 },
    hints = { [904] = 9900 }, npc_pos = { [9900] = {x=1,y=1,z=1} },
    names = { [904] = "" } })
  local show = { startable=true, in_progress=true, completed=true,
    unavailable=true, locked=true }
  local r = core.compute(a, show)
  check("suppress: empty-string name suppressed", #r.markers == 0)
end

-- v3: marker_cid
assert(core.marker_cid({ key = "c:123" }) == 123, "marker_cid c-key")
assert(core.marker_cid({ key = "p:1:2:3" }) == nil, "marker_cid p-key")
assert(core.marker_cid({ key = "c:" }) == nil, "marker_cid empty")
assert(core.marker_cid({ key = "c:-3" }) == nil, "marker_cid negative")
assert(core.marker_cid({}) == nil, "marker_cid nil key")
assert(core.marker_cid(nil) == nil, "marker_cid non-table")
assert(core.marker_cid({ key = string.format("c:%d", 5.0) }) == 5,
  "marker_cid float cid round-trip")

-- v3: overhead_anchors. marker.pos is map-space, the camera transform-space
-- (SPEC §10.8b): a cid with no prev_pos is ALWAYS selected regardless of
-- marker.pos; the distance cull applies only to prev_pos entries.
local mk = function(key, x) return { key = key, pos = { x = x, y = 0, z = 0 } } end
local ms = { mk("c:1", 9999), mk("c:2", 9999), mk("p:9:9:9", 0) }
local sel = core.overhead_anchors(ms, {}, { x = 0, y = 0, z = 0 }, 50)
assert(#sel == 2, "overhead_anchors: unacquired cids never culled, p-keys excluded")
sel = core.overhead_anchors(ms, { [2] = { x = 1000, y = 0, z = 0 } },
  { x = 0, y = 0, z = 0 }, 50)
assert(#sel == 1 and sel[1].cid == 1,
  "overhead_anchors culls a far prev_pos, keeps the unacquired cid")
sel = core.overhead_anchors(ms, { [2] = { x = 10, y = 0, z = 0 } },
  { x = 0, y = 0, z = 0 }, 50)
assert(#sel == 2, "overhead_anchors keeps a near prev_pos")
sel = core.overhead_anchors({ mk("c:3", 9999) }, { [3] = { x = 50, y = 0, z = 0 } },
  { x = 0, y = 0, z = 0 }, 50)
assert(#sel == 1, "overhead_anchors boundary inclusive")
sel = core.overhead_anchors({ mk("c:1", 9999) }, { [7] = { x = 0, y = 0, z = 0 } },
  { x = 0, y = 0, z = 0 }, 50)
assert(#sel == 1 and sel[1].cid == 1,
  "overhead_anchors ignores prev_pos cids absent from markers")

-- v3: compute keys a float-typed integer cid as c:<int> (not "c:5.0")
do
  local a = fake_adapter({ acceptable = { 10 }, hints = { [10] = 5.0 },
    npc_pos = { [5] = {x=1,y=2,z=3} } })
  local r = core.compute(a, SHOW_ALL)
  assert(r and #r.markers == 1, "float cid: one marker")
  assert(r.markers[1].key == "c:5", "float cid keys as c:5")
end
-- v4: minimap_markers
local mmk = function(key, x, y, z)
  return { key = key, pos = { x = x, y = y or 0, z = z or 0 } }
end
local mm = core.minimap_markers
local lst, near = mm({ mmk("c:1", 10), mmk("p:0:0:0", 300), mmk("c:2", 50) },
  { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: in-radius kept, far dropped", #lst == 2)
check("mm: nearest-first", lst[1].key == "c:1" and lst[2].key == "c:2")
check("mm: nearest distance", near == 10)
lst = mm({ mmk("c:3", 0, 120, 160) }, { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: boundary inclusive, 3D", #lst == 1)
lst = mm({ mmk("c:4", 0, 120, 161) }, { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: just outside, 3D", #lst == 0)
lst = mm({ mmk("c:1", 30), mmk("c:2", 20), mmk("c:3", 10) },
  { x = 0, y = 0, z = 0 }, 200, 2)
check("mm: cap keeps closest", #lst == 2 and lst[1].key == "c:3" and lst[2].key == "c:2")
lst = mm({ mmk("b", 10), mmk("a", 10) }, { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: stable tie order by key", lst[1].key == "a" and lst[2].key == "b")
lst, near = mm({}, { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: empty markers", #lst == 0 and near == nil)
lst = mm({ mmk("c:1", 10) }, nil, 200, 12)
check("mm: nil origin", #lst == 0)
lst = mm(nil, { x = 0, y = 0, z = 0 }, 200, 12)
check("mm: nil markers", #lst == 0)
-- v5: objective_table
local T = core.objective_table
local P = { [10] = true }
local r1 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true},
  {qid=10,cid=7,issued=false}, {qid=10,cid=9,issued=true} }, nil, P)
check("ot: issued first, ascending, deduped",
  #r1.cids[10] == 3 and r1.cids[10][1] == 5 and r1.cids[10][2] == 9
  and r1.cids[10][3] == 7)
local r1b = T({ {qid=10,cid=9,issued=true}, {qid=10,cid=7,issued=false},
  {qid=10,cid=5,issued=true} }, nil, P)
check("ot: order independent of record order",
  r1b.cids[10][1] == 5 and r1b.cids[10][2] == 9 and r1b.cids[10][3] == 7)
check("ot: cid issued in any record sorts issued",
  T({ {qid=10,cid=7,issued=false}, {qid=10,cid=7,issued=true},
      {qid=10,cid=3,issued=false} }, nil, P).cids[10][1] == 7)
-- sticky within tier: 9 chosen first stays over 5
local s0 = T({ {qid=10,cid=9,issued=true} }, nil, P)
local s1 = T({ {qid=10,cid=9,issued=true}, {qid=10,cid=5,issued=true} }, s0, P)
check("ot: sticky first survives same-tier newcomer", s1.cids[10][1] == 9)
local s2 = T({ {qid=10,cid=9,issued=true}, {qid=10,cid=5,issued=true} }, s1, P)
check("ot: sticky first survives two same-tier builds", s2.cids[10][1] == 9)
-- debounce: non-issued sticky vs new issued cid
local d0 = T({ {qid=10,cid=7,issued=false} }, nil, P)
local d1 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true} }, d0, P)
check("ot: one issued build does not displace", d1.cids[10][1] == 7)
local d2 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true} }, d1, P)
check("ot: second consecutive issued build displaces", d2.cids[10][1] == 5)
local f1 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true} }, d0, P)
local f2 = T({ {qid=10,cid=7,issued=false} }, f1, P)
local f3 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true} }, f2, P)
check("ot: flicker resets the streak", f3.cids[10][1] == 7)
local g1 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=5,issued=true} }, d0, P)
local g2 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=3,issued=true} }, g1, P)
check("ot: streak is per top cid", g2.cids[10][1] == 7)
-- retention
local m0 = T({ {qid=10,cid=7,issued=false} }, nil, P)
local m1 = T({}, m0, P)
local m2 = T({}, m1, P)
local m3 = T({}, m2, P)
check("ot: absent qid retained 3 builds",
  m1.cids[10] ~= nil and m2.cids[10] ~= nil and m3.cids[10] ~= nil)
check("ot: dropped on 4th miss", T({}, m3, P).cids[10] == nil)
check("ot: non-progressing drops at once", T({}, m0, {}).cids[10] == nil)
check("ot: non-progressing record ignored",
  T({ {qid=11,cid=7,issued=true} }, nil, P).cids[11] == nil)

-- SPEC 39.4: the issued objective read is distinct from the legacy candidate
-- list. It contains only exact-true issued candidates and retains them across
-- clean empty / absent walks for three builds.
local oi0 = T({ {qid=10,cid=7,issued=false}, {qid=10,cid=9,issued=true},
  {qid=10,cid=5,issued=true}, {qid=10,cid=9,issued=true} }, nil, P)
check("ot issued: exact-true set sorted, unique, legacy cids retained",
  oi0.issued ~= nil and table.concat(oi0.issued[10] or {}, ",") == "5,9"
  and table.concat(oi0.cids[10] or {}, ",") == "5,9,7")
local oir = T({ {qid=10,cid=9,issued=true}, {qid=10,cid=5,issued=true} }, oi0, P)
check("ot issued: previous first remains first when still issued",
  table.concat(oir.issued[10] or {}, ",") == "5,9")
local oe1 = T({ {qid=10,cid=7,issued=false} }, oi0, P)
local oe2 = T({ {qid=10,cid=7,issued=false} }, oe1, P)
local oe3 = T({ {qid=10,cid=7,issued=false} }, oe2, P)
check("ot issued: clean empty issued set retained three builds",
  table.concat(oe1.issued[10] or {}, ",") == "5,9"
  and table.concat(oe2.issued[10] or {}, ",") == "5,9"
  and table.concat(oe3.issued[10] or {}, ",") == "5,9")
local oe4 = T({ {qid=10,cid=7,issued=false} }, oe3, P)
check("ot issued: clean empty issued set drops on fourth build",
  oe4.issued[10] == nil)
local oa1 = T({}, oi0, P)
local oa2 = T({}, oa1, P)
local oa3 = T({}, oa2, P)
check("ot issued: absent qid retention keeps issued targets",
  table.concat(oa1.issued[10] or {}, ",") == "5,9"
  and table.concat(oa2.issued[10] or {}, ",") == "5,9"
  and table.concat(oa3.issued[10] or {}, ",") == "5,9")
local onew = T({ {qid=10,cid=8,issued=true}, {qid=10,cid=9,issued=true} }, oi0, P)
check("ot issued: changed nonempty set replaces immediately with sticky first",
  table.concat(onew.issued[10] or {}, ",") == "8,9")
check("ot issued: nonprogressing qid drops immediately",
  T({}, oi0, {}).issued[10] == nil)
check("ot issued: reader returns nil when unknown",
  type(core.objective_issued_cids) == "function"
  and core.objective_issued_cids(oe4, 10) == nil
  and core.objective_issued_cids(oi0, 10) == oi0.issued[10])
local legacy_d0 = T({ { qid = 10, cid = 7, issued = false } }, nil, P)
local legacy_d1 = T({ { qid = 10, cid = 7, issued = false },
  { qid = 10, cid = 5, issued = true }, { qid = 10, cid = 9, issued = true } }, legacy_d0, P)
local legacy_d2 = T({ { qid = 10, cid = 7, issued = false },
  { qid = 10, cid = 5, issued = true }, { qid = 10, cid = 9, issued = true } }, legacy_d1, P)
check("ot: legacy candidate debounce remains independent of issued-first order",
  legacy_d1.cids[10][1] == 7 and legacy_d2.cids[10][1] == 5)
local legacy_custom_prev = { cids = { [10] = { 7 } }, issued = { [10] = { 9 } },
  miss = {}, issued_miss = {}, issued_streak = { [10] = { cid = 11, n = 1 } } }
local legacy_custom1 = T({ { qid = 10, cid = 7, issued = false },
  { qid = 10, cid = 5, issued = true }, { qid = 10, cid = 9, issued = true } }, legacy_custom_prev, P)
local legacy_custom2 = T({ { qid = 10, cid = 7, issued = false },
  { qid = 10, cid = 5, issued = true }, { qid = 10, cid = 9, issued = true } }, legacy_custom1, P)
check("ot: issued sticky order cannot alter legacy debounce winner",
  legacy_custom1.cids[10][1] == 7 and legacy_custom1.issued_streak[10].cid == 5
    and legacy_custom2.cids[10][1] == 5)

-- v5: resolution
local function objadapter(over)
  local base = {
    acceptable_ids = function() return {} end,
    progressing_ids = function() return {10} end,
    giver_hint = function() return 5 end,
    npc_pos = function(c) if c == 5 then return 1, 1, 1 end
      if c == 77 then return 9, 9, 9 end end,
    objective_cids = function(q) return q == 10 and {77} or nil end,
  }
  local a = base_adapter(base)
  for k, v in pairs(over or {}) do a[k] = v end
  return a
end
r = core.compute(objadapter(), SHOW_ALL)
check("obj: objective wins over hint",
  r.markers[1].key == "c:77" and r.markers[1].pos.x == 9)
r = core.compute(objadapter({
  giver_hint = function() return nil end,
  cast_ids = function() return {6, 7} end,
  static_pos = function() return {x=4,y=4,z=4} end,
  npc_pos = function(c) return 100 + c, 0, 0 end,
  objective_cids = function() return {77} end,
}), SHOW_ALL)
check("obj: wins over multi-cast+static (can_use_cast bypass)",
  r.markers[1].key == "c:77")
r = core.compute(objadapter({
  is_generic = function(c) return c == 77 end,
}), SHOW_ALL)
check("obj: generic objective falls through to hint", r.markers[1].key == "c:5")
r = core.compute(objadapter({
  objective_cids = function() return {66, 77} end,
  npc_alive = function(c) return c ~= 66 end,
  npc_pos = function(c) if c == 66 then return 3, 3, 3 end
    if c == 77 then return 9, 9, 9 end
    if c == 5 then return 1, 1, 1 end end,
}), SHOW_ALL)
check("obj: dead first, live second wins", r.markers[1].key == "c:77")
r = core.compute(objadapter({
  npc_pos = function(c) if c == 5 then return 1, 1, 1 end end,
}), SHOW_ALL)
check("obj: all objectives miss -> hint fallback", r.markers[1].key == "c:5")
local a_no = objadapter()
a_no.objective_cids = nil   -- pairs(over) cannot remove a key; set nil after
r = core.compute(a_no, SHOW_ALL)
check("obj: adapter without objective_cids = v4", r.markers[1].key == "c:5")
r = core.compute(objadapter({
  acceptable_ids = function() return {10} end,
  progressing_ids = function() return {} end,
}), SHOW_ALL)
check("obj: startable never consults objectives", r.markers[1].key == "c:5")
r = core.compute(objadapter({
  objective_pos = function(c) if c == 77 then return 2, 2, 2 end end,
}), SHOW_ALL)
check("obj: objective_pos preferred over npc_pos when present",
  r.markers[1].key == "c:77" and r.markers[1].pos.x == 2)
r = core.compute(objadapter({
  giver_hint = function() return nil end,
  npc_pos = function() return nil end,
}), SHOW_ALL)
check("obj: reason names objective misses",
  r.unresolved[10] ~= nil
  and r.unresolved[10].reason == "objective NPC position unavailable (1 cand)")
r = core.compute(fake_adapter({ progressing = {10}, hints = {[10]=5},
  npc_pos = {[5]={x=1,y=1,z=1}}, objectives = {[10]={77}},
  objective_pos = {[77]={x=3,y=3,z=3}}, names = {[10]="Q"} }), SHOW_ALL)
check("obj: fake_adapter objective path", r.markers[1].key == "c:77"
  and r.markers[1].pos.x == 3)
-- hidden in-progress never consults objectives (visibility break first)
local consulted = 0
r = core.compute(objadapter({
  objective_cids = function() consulted = consulted + 1; return {77} end,
}), { startable=true, in_progress=false, completed=true,
  unavailable=true, locked=true })
check("obj: hidden in-progress never consults", consulted == 0)

-- gt: gate_table
check("gt: dedup + ascending", (function()
  local t = core.gate_table({ {qid=10, ref=30}, {qid=10, ref=20}, {qid=10, ref=30} })
  return t[10][1] == 20 and t[10][2] == 30 and #t[10] == 2
end)())
check("gt: defensive drops leave the qid absent", (function()
  local t = core.gate_table({ {qid=10, ref=0}, {qid=10, ref="x"}, {qid=10, ref=10} })
  return t[10] == nil
end)())

-- hv: hover
local function hv(o, show)
  o.acceptable = o.acceptable or { 10 }
  o.hints = o.hints or { [10] = 5 }
  o.npc_pos = o.npc_pos or { [5] = { x=1, y=2, z=3 } }
  local rr = core.compute(fake_adapter(o), show or SHOW_ALL)
  return rr.markers[1]
end
local NAMES = { [10]="Ten", [20]="A", [30]="B", [40]="C", [50]="D" }
check("hv: 0 refs -> hover absent", hv({ names=NAMES, gates={} }).hover == nil)
check("hv: 1 seen ref", hv({ names=NAMES, gates={[10]={20}}, seen={[20]="Other"} }).hover
  == "Ten - startable (waiting on: Other)")
check("hv: 2 refs ascending", hv({ names=NAMES, gates={[10]={20,30}},
  seen={[20]="A", [30]="B"} }).hover == "Ten - startable (waiting on: A, B)")
check("hv: 3 distinct -> ellipsis", hv({ names=NAMES, gates={[10]={20,30,40}},
  seen={[20]="A", [30]="B", [40]="C"} }).hover
  == "Ten - startable (waiting on: A, B, ...)")
check("hv: collapse then cap", hv({ names=NAMES, gates={[10]={20,30,40}},
  seen={[40]="C"} }).hover
  == "Ten - startable (waiting on: another quest, C)")
check("hv: unseen + reveal off", hv({ names=NAMES, gates={[10]={20}} }).hover
  == "Ten - startable (waiting on: another quest)")
check("hv: unseen + reveal on -> real title", hv({ names=NAMES, gates={[10]={20}} },
  { startable=true, in_progress=true, completed=true, unavailable=true,
    locked=true, reveal_gate_names=true }).hover
  == "Ten - startable (waiting on: A)")
do
  local m = hv({ acceptable={10,11}, hints={[10]=5,[11]=5}, names={[10]="Ten",[11]="Eleven",[20]="A"},
    gates={[10]={20}}, seen={[20]="A"} })
  check("hv: ungated part identical, label clean",
    m.label == "Ten - startable / Eleven - startable"
    and m.hover == "Ten - startable (waiting on: A) / Eleven - startable")
end
check("hv: signature differs when only hover differs", (function()
  local a = hv({ names=NAMES, gates={[10]={20}}, seen={[20]="A"} })
  local b = hv({ names=NAMES, gates={[10]={30}}, seen={[30]="B"} })
  local c = hv({ names=NAMES })
  local s1 = core.signature({a}, {}); local s2 = core.signature({b}, {})
  local s3 = core.signature({c}, {})
  return a.label == b.label and s1 ~= s2 and s1 ~= s3
end)())
do
  local calls = {}
  local m = hv({ names=NAMES, acceptable={}, progressing={10}, gates={[10]={20}},
    gate_calls=calls })
  check("hv: non-startable never consults gate_qids",
    #calls == 0 and m.hover == nil)
end
check("hv: adapter without gate_qids -> hover nil", hv({ names=NAMES }).hover == nil)

-- tr: tree records
local TOPEN = { startable=true, in_progress=true, completed=false, unavailable=false,
  locked=false, tree_open=true }
local TCLOSED = { startable=true, in_progress=true, completed=false, unavailable=false,
  locked=false, tree_open=false }
local function trc(o, show) return core.compute(fake_adapter(o), show or TOPEN) end
-- R1
do
  local c1, c2 = {}, {}
  local function mk(c) return { acceptable={10}, catalog={10,11}, names={[10]="Ten",[11]="E"},
    regions={[10]="Vern"}, name_calls=c } end
  local a = core.compute(fake_adapter(mk(c1)), TCLOSED)
  local b = core.compute(fake_adapter(mk(c2)), { startable=true, in_progress=true,
    completed=false, unavailable=false, locked=false })
  check("tr R1: closed/absent -> quests nil", a.quests == nil and b.quests == nil)
  check("tr R1: name call count identical", #c1 == #c2 and #c1 > 0)
end
-- R2
do
  local ok2, r2 = pcall(trc, { acceptable={10}, progressing={12}, states={[11]="giver_dead"},
    catalog={10,11,12,13}, names={[10]="Ten",[11]="Eleven",[12]="Twelve",[13]="Thirteen"},
    regions={[10]="Vern", [11]="Battahl"} })
  check("tr R2: compute non-nil (adapter lacks gate_qids)", ok2 and r2 ~= nil)
  local q = (ok2 and r2 and r2.quests) or {}
  check("tr R2: ascending, 4 records", #q == 4 and q[1].qid == 10 and q[2].qid == 11
    and q[3].qid == 12 and q[4].qid == 13)
  check("tr R2: startable shape", #q == 4 and q[1].cat == "startable" and q[1].state == "startable"
    and q[1].grp == "startable" and q[1].name == "Ten" and q[1].region == "Vern")
  check("tr R2: invalid giver-dead state falls through to locked", #q == 4
    and q[2].cat == "locked" and q[2].state == "locked" and q[2].grp == "locked")
  check("tr R2: in progress forms", #q == 4 and q[3].state == "in progress" and q[3].grp == "in_progress")
  check("tr R2: region fallback", #q == 4 and q[3].region == "Elsewhere")
  local okn, rn = pcall(trc, { acceptable={10}, names={[10]="Ten"} })
  check("tr R2: no quest_region compute non-nil", okn and rn ~= nil)
  check("tr R2: no quest_region -> nil even when open", okn and rn ~= nil and rn.quests == nil)
  check("tr R2: zero quests -> empty table",
    (function() local x = trc({ regions={} }).quests; return type(x) == "table" and #x == 0 end)())
end
-- R3
do
  local q = trc({ catalog={20,21,22}, acceptable={21}, names={[22]="Named"}, regions={} }).quests
  check("tr R3: locked nameless omitted, others kept", #q == 2 and q[1].qid == 21 and q[2].qid == 22)
  check("tr R3: nameless startable placeholder", q[1].name == "Quest 21")
  check("tr R3: locked named kept", q[2].name == "Named" and q[2].cat == "locked")
end
-- R4
do
  local gc, tc = {}, {}
  local q = trc({ acceptable={30}, catalog={30,31}, progressing={32},
    names={[30]="S",[31]="L",[32]="P",[40]="Fore"}, regions={},
    gates={[30]={40},[31]={99},[32]={99}}, tgates={[31]={40},[30]={99},[32]={99}},
    gate_calls=gc, tgate_calls=tc, seen={[40]="Fore"} }).quests
  check("tr R4: startable uses gate_qids", q[1].waiting == " (waiting on: Fore)")
  check("tr R4: locked uses tree_gate_qids", q[2].waiting == " (waiting on: Fore)")
  check("tr R4: in progress no waiting", q[3].waiting == nil)
  local gset, tset = {}, {}
  for _, x in ipairs(gc) do gset[x] = true end
  for _, x in ipairs(tc) do tset[x] = true end
  check("tr R4: source split pinned", gset[30] and not gset[31] and not gset[32]
    and tset[31] and not tset[30] and not tset[32])
  local ok, r = pcall(trc, { acceptable={30}, names={[30]="S"}, regions={}, gates={} })
  check("tr R4b: gate_qids nil compute non-nil", ok and r ~= nil)
  check("tr R4b: gate_qids nil -> waiting nil",
    ok and r ~= nil and r.quests[1] ~= nil and r.quests[1].waiting == nil)
  ok, r = pcall(trc, { acceptable={30}, names={[30]="S"}, regions={}, gates={[30]={}} })
  check("tr R4b: empty array compute non-nil", ok and r ~= nil)
  check("tr R4b: empty array -> waiting nil",
    ok and r ~= nil and r.quests[1] ~= nil and r.quests[1].waiting == nil)
end
-- R4b isolated: empty gate array on its own fixture
do
  local ok, r = pcall(trc, { acceptable={60}, catalog={60}, names={[60]="Solo"}, regions={},
    gates={[60]={}} })
  check("tr R4b-empty: compute non-nil", ok and r ~= nil)
  check("tr R4b-empty: startable record, waiting nil",
    ok and r ~= nil and r.quests[1] ~= nil and r.quests[1].cat == "startable"
    and r.quests[1].waiting == nil)
end
-- R4b isolated: adapter lacks gate_qids and tree_gate_qids entirely
do
  local ok, r = pcall(trc, { acceptable={70}, catalog={70,71}, names={[70]="A",[71]="B"},
    regions={} })
  check("tr R4b-absent: compute non-nil", ok and r ~= nil)
  check("tr R4b-absent: records present, waiting nil",
    ok and r ~= nil and #r.quests == 2 and r.quests[1].waiting == nil
    and r.quests[2].waiting == nil)
end
-- R5
do
  local q = trc({ states={[50]="completed"}, catalog={50}, names={[50]="Done"}, regions={} }).quests
  check("tr R5: hidden category still yields record", #q == 1 and q[1].state == "completed"
    and q[1].grp == "completed")
end
-- R6
do
  local function hov(show)
    local rr = core.compute(fake_adapter({ acceptable={10,11}, hints={[10]=5,[11]=5},
      npc_pos={[5]={x=1,y=2,z=3}}, names={[10]="Ten",[11]="Eleven",[20]="A"},
      gates={[10]={20}}, seen={[20]="A"}, regions={[10]="V"} }), show)
    return rr.markers[1].label, rr.markers[1].hover
  end
  local l1, h1 = hov({ startable=true, in_progress=true, tree_open=true })
  local l2, h2 = hov({ startable=true, in_progress=true, tree_open=false })
  check("tr R6: hover identical open/closed", l1 == l2 and h1 == h2 and h1 ~= nil)
end
-- R7
check("tr R7: open", core.tree_wanted(10.5, 10.0) == true)
check("tr R7: stale", core.tree_wanted(11.5, 10.0) == false)
check("tr R7: nil open_at", core.tree_wanted(10, nil) == false)

-- it: item_need_table (v8, SPEC 15.5a.1)
do
  local nt = core.item_need_table
  local t, ign = nt({ { qid = 20090, id = 300, num = 1, op = "more" } }, {})
  check("it N1: more 1 admitted, required 1", t[20090] ~= nil
    and #t[20090] == 1 and t[20090][1].id == 300 and t[20090][1].num == 1
    and ign == 0)
  t = nt({ { qid = 1, id = 5, num = 1, op = "morethan" } }, {})
  check("it N2: morethan 1 -> required 2", t[1] ~= nil and t[1][1].num == 2)
  t = nt({ { qid = 1, id = 5, num = 0, op = "morethan" } }, {})
  check("it N3: morethan 0 -> required 1 (a real need)",
    t[1] ~= nil and t[1][1].num == 1)
  t, ign = nt({ { qid = 1, id = 5, num = 0, op = "more" },
    { qid = 1, id = 6, num = 0, op = "other" },     -- Equal 0
    { qid = 1, id = 7, num = 1, op = "other" },     -- Equal 1
    { qid = 1, id = 8, num = -1, op = "morethan" } }, {}) -- negative
  check("it N4: more 0 and other rejected and counted",
    next(t) == nil and ign == 4)
  t, ign = nt({ { qid = 1, id = 5, num = 1, op = "more" },
    { qid = 1, id = 5, num = 3, op = "more" },
    { qid = 1, id = 5, num = 1, op = "morethan" } }, {})
  check("it N5: dedupe per (qid, id) keeps the max required",
    t[1] ~= nil and #t[1] == 1 and t[1][1].num == 3 and ign == 0)
  t = nt({ { qid = 1, id = 5, num = 2, op = "more" } }, { [5] = 2 })
  check("it N6: held >= required drops; empty qid absent",
    t[1] == nil and next(t) == nil)
  t = nt({ { qid = 1, id = 5, num = 2, op = "more" } }, { [5] = 1 })
  check("it N7: held < required keeps", t[1] ~= nil and t[1][1].num == 2)
  t = nt({ { qid = 1, id = 9, num = 1, op = "more" },
    { qid = 1, id = 4, num = 1, op = "more" } }, nil)
  check("it N8: held absent = 0; ids ascending", t[1] ~= nil and #t[1] == 2
    and t[1][1].id == 4 and t[1][2].id == 9)
  t = nt({ { qid = 1, id = 5, num = 1, op = "more" },
    { qid = 2, id = 5, num = 1, op = "more" } }, {})
  check("it N9: per-qid tables", t[1] ~= nil and t[2] ~= nil
    and t[1][1].id == 5 and t[2][1].id == 5)
  t, ign = nt(nil, nil)
  check("it N10: nil input -> empty, nothing ignored",
    next(t) == nil and ign == 0)
  t, ign = nt({ { qid = 1, id = "x", num = 1, op = "more" },
    { qid = "x", id = 5, num = 1, op = "more" },
    { qid = 1, id = 5, num = "x", op = "more" } }, {})
  check("it N11: non-number field rejected and counted",
    next(t) == nil and ign == 3)
end

-- im: item markers (v8, SPEC 15.5a.2 + a.5)
do
  local IT = { startable = true, in_progress = true, quest_items = true }
  local GARB = { id = 300, pos = { x = 1, y = 2, z = 3 },
    live = { x = 7, y = 8, z = 9 }, src = "placed" }
  local function iw(over, show)
    local o = { progressing = { 10, 11 }, names = { [10] = "A", [11] = "B" },
      item_needs = { [10] = { { id = 300, num = 1 } } },
      item_locs = { GARB }, item_names = { [300] = "Beggar's Garb" } }
    for k, v in pairs(over or {}) do o[k] = v end
    return core.compute(fake_adapter(o), show or IT), o
  end
  local function items(r)
    local out = {}
    for _, m in ipairs(r.markers) do
      if m.cat == "quest_item" then out[#out + 1] = m end
    end
    return out
  end
  -- IM1 gating
  local r = iw()
  check("im IM1: shown in-progress need with a location -> one marker",
    #items(r) == 1)
  check("im IM1: quest_items off -> none",
    #items(iw(nil, { startable = true, in_progress = true, quest_items = false })) == 0)
  check("im IM1: in_progress off -> none",
    #items(iw(nil, { startable = true, in_progress = false, quest_items = true })) == 0)
  r = iw({ item_needs = false })
  check("im IM1: adapter without item_needs -> none, compute ok",
    r ~= nil and #items(r) == 0)
  -- IM2 needs only from shown in-progress quests
  check("im IM2: startable quest's need -> none", #items(iw({ progressing = {},
    acceptable = { 10 } })) == 0)
  check("im IM2: locked quest's need -> none", #items(iw({ progressing = {},
    catalog = { 10 } })) == 0)
  check("im IM2: terminal quest's need -> none (even with completed shown)",
    #items(iw({ progressing = {}, catalog = { 10 }, states = { [10] = "completed" } },
      { startable = true, in_progress = true, completed = true, quest_items = true })) == 0)
  check("im IM2: unknown qid's need -> none",
    #items(iw({ item_needs = { [99] = { { id = 300, num = 1 } } } })) == 0)
  -- IM3 key + 4 m grid on map-space x/z
  local m = items(iw())[1]
  check("im IM3: key shape", m.key == "i:300:0:0")
  local function key_at(x, z)
    return items(iw({ item_locs = { { id = 300, pos = { x = x, y = 0, z = z },
      src = "placed" } } }))[1].key
  end
  check("im IM3: x 3.9 and 0.1 share a cell", key_at(3.9, 0) == key_at(0.1, 0))
  check("im IM3: x 4.0 is the next cell", key_at(4.0, 0) ~= key_at(3.9, 0)
    and key_at(4.0, 0) == "i:300:1:0")
  check("im IM3: negative coordinates floor", key_at(-0.1, -4.1) == "i:300:-1:-2")
  -- IM4 same-key merge + source order
  r = iw({ item_locs = {
    { id = 300, pos = { x = 0.1, y = 0, z = 0 }, src = "drop" },
    { id = 300, pos = { x = 3.9, y = 0, z = 0 }, live = { x = 5, y = 5, z = 5 },
      src = "placed" },
    { id = 300, pos = { x = 2.0, y = 0, z = 0 }, src = "box" } } })
  local ims = items(r)
  check("im IM4: one marker per key", #ims == 1)
  check("im IM4: placed < box < drop supplies pos/live",
    ims[1].pos.x == 3.9 and ims[1].live.x == 5)
  r = iw({ item_locs = {
    { id = 300, pos = { x = 0.5, y = 0, z = 0 }, src = "drop" },
    { id = 300, pos = { x = 2.0, y = 0, z = 0 }, src = "box" } } })
  check("im IM4: box beats drop", items(r)[1].pos.x == 2.0)
  r = iw({ item_locs = {
    { id = 300, pos = { x = 2.5, y = 0, z = 0 }, src = "drop" },
    { id = 300, pos = { x = 0.5, y = 0, z = 0 }, src = "drop" } } })
  check("im IM4: same source -> lower position first", items(r)[1].pos.x == 0.5)
  -- IM5 two quests, one item: one marker per location, ascending qids
  r = iw({ item_needs = { [11] = { { id = 300, num = 1 } },
    [10] = { { id = 300, num = 1 } } } })
  ims = items(r)
  check("im IM5: two quests share one marker", #ims == 1
    and #ims[1].qids == 2 and ims[1].qids[1] == 10 and ims[1].qids[2] == 11)
  check("im IM5: label", ims[1].label == "Beggar's Garb (for A / B)")
  -- IM6 fallbacks
  r = iw({ names = { [10] = "A" }, item_names = {},
    item_needs = { [10] = { { id = 300, num = 1 } }, [11] = { { id = 300, num = 1 } } } })
  check("im IM6: quest + item name fallbacks",
    items(r)[1].label == "Item 300 (for A / Quest 11)")
  local base = core.compute(fake_adapter({ progressing = { 10, 11 },
    names = { [10] = "A" } }), IT)
  check("im IM6: fallback names never enter unnamed",
    next(r.unnamed) == nil and next(base.unnamed) == nil)
  -- IM7 cap 32 + item_ord per id
  local many = {}
  for i = 1, 40 do
    many[#many + 1] = { id = 300, pos = { x = i * 8, y = 0, z = 0 }, src = "placed" }
  end
  many[#many + 1] = { id = 200, pos = { x = 0, y = 0, z = 0 }, src = "placed" }
  many[#many + 1] = { id = 200, pos = { x = 8, y = 0, z = 0 }, src = "placed" }
  r = iw({ item_locs = many, item_names = { [200] = "X", [300] = "Y" },
    item_needs = { [10] = { { id = 200, num = 1 }, { id = 300, num = 1 } } } })
  ims = items(r)
  check("im IM7: capped at 32, excess counted", #ims == 32 and r.item_capped == 10)
  check("im IM7: sorted by item id, item_ord per id",
    ims[1].item_id == 200 and ims[1].item_ord == 0 and ims[2].item_ord == 1
    and ims[3].item_id == 300 and ims[3].item_ord == 0 and ims[32].item_ord == 29)
  check("im IM7: item_capped 0 without items", base.item_capped == 0)
  -- IM7b cap keeps the copies nearest show.origin (SPEC 15.3h.1, 15.7i)
  do
    local far = {}
    for i = 1, 40 do
      far[#far + 1] = { id = 300, pos = { x = i * 50, y = 0, z = 0 }, src = "placed" }
    end
    local function run(origin)
      local sh = { startable = true, in_progress = true, quest_items = true,
        origin = origin }
      local rr = iw({ item_locs = far }, sh)
      local xs = {}
      for _, m in ipairs(items(rr)) do xs[m.pos.x] = true end
      return rr, xs
    end
    local ro, xo = run({ x = 1900, y = 0, z = 0 })
    local dropped_far = true
    for x = 50, 400, 50 do if xo[x] then dropped_far = false end end
    check("im IM7b: origin keeps the nearest copy under the cap",
      #items(ro) == 32 and ro.item_capped == 8 and xo[1900] == true)
    check("im IM7b: the 8 dropped are the 8 farthest", dropped_far)
    local rn, xn = run(nil)
    check("im IM7b: nil origin keeps (item_id, key) order",
      #items(rn) == 32 and rn.item_capped == 8 and xn[1900] == nil)
  end
  -- IM8 appended after quest markers; shape
  r = iw({ acceptable = { 20 }, hints = { [20] = 5 },
    npc_pos = { [5] = { x = 1, y = 2, z = 3 } }, names = { [10] = "A", [20] = "S" } })
  check("im IM8: item markers after quest markers", #r.markers == 2
    and r.markers[1].cat == "startable" and r.markers[2].cat == "quest_item")
  m = r.markers[2]
  check("im IM8: marker shape", m.item_id == 300 and m.hover == nil
    and m.pos.x == 1 and m.pos.z == 3 and m.live.x == 7 and m.pos ~= GARB.pos
    and m.live ~= GARB.live)
  -- IM9 nothing else changes with items present
  local o_on = { progressing = { 10, 11 }, acceptable = { 20 }, names = { [10] = "A" },
    hints = { [20] = 5 }, npc_pos = { [5] = { x = 1, y = 2, z = 3 } },
    regions = { [10] = "V" } }
  local o_off = {}
  for k, v in pairs(o_on) do o_off[k] = v end
  o_on.item_needs = { [10] = { { id = 300, num = 1 } } }
  o_on.item_locs = { GARB }
  local SH = { startable = true, in_progress = true, quest_items = true, tree_open = true }
  local ron = core.compute(fake_adapter(o_on), SH)
  local roff = core.compute(fake_adapter(o_off), SH)
  local function same_keys(x, y)
    for k, v in pairs(x) do if y[k] ~= v then return false end end
    for k, v in pairs(y) do if x[k] ~= v then return false end end
    return true
  end
  local function nkeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
  check("im IM9: counts, resolved_count, unresolved, unnamed, quests unchanged",
    same_keys(ron.counts, roff.counts) and ron.resolved_count == roff.resolved_count
    and nkeys(ron.unresolved) == nkeys(roff.unresolved) and nkeys(roff.unresolved) == 2
    and same_keys(ron.unnamed, roff.unnamed) and ron.unnamed[20] == true
    and #ron.quests == #roff.quests and #ron.markers == #roff.markers + 1)
  -- IM10 one item_name call per id per compute
  local calls = {}
  iw({ item_name_calls = calls, item_locs = { GARB,
    { id = 300, pos = { x = 50, y = 0, z = 50 }, src = "drop" } } })
  check("im IM10: one item_name call per id", #calls == 1)
  -- IM11 signature: label in, live out
  local function one(lbl, lx)
    return { key = "i:300:0:0", pos = { x = 1, y = 2, z = 3 },
      live = { x = lx, y = 0, z = 0 }, qids = { 10 }, label = lbl,
      cat = "quest_item", item_id = 300 }
  end
  check("im IM11: label change changes the signature",
    core.signature({ one("a", 1) }, {}) ~= core.signature({ one("b", 1) }, {}))
  check("im IM11: live change does not",
    core.signature({ one("a", 1) }, {}) == core.signature({ one("a", 99) }, {}))
end

-- mo: item tier on the minimap, overhead points, item-walk decision (v8, SPEC 15.5a.3-4, 15.3a)
do
  local O = { x = 0, y = 0, z = 0 }
  local function q(key, x) return { key = key, pos = { x = x, y = 0, z = 0 }, cat = "startable" } end
  local function it(key, x, live)
    return { key = key, pos = { x = x, y = 0, z = 0 }, cat = "quest_item", live = live }
  end
  -- MM1 item dots compete on distance with quest markers
  local lst, near = core.minimap_markers({ it("i:1:0:0", 5), q("c:1", 50) }, O, 200, 1)
  check("mo MM1: cap binds -> nearer item kept over a farther quest marker",
    #lst == 1 and lst[1].key == "i:1:0:0")
  check("mo MM1: nearest is the nearest of all in-radius markers", near == 5)
  lst = core.minimap_markers({ it("i:1:0:0", 5), q("c:2", 60), q("c:1", 50) }, O, 200, 12)
  check("mo MM1: one distance order across items and quests", #lst == 3
    and lst[1].key == "i:1:0:0" and lst[2].key == "c:1" and lst[3].key == "c:2")
  lst = core.minimap_markers({ it("i:2:0:0", 9), it("i:1:0:0", 5) }, O, 200, 12)
  check("mo MM1: items among themselves by distance", #lst == 2
    and lst[1].key == "i:1:0:0" and lst[2].key == "i:2:0:0")
  -- OP1-OP6 overhead points
  local cam = { x = 0, y = 0, z = 0 }
  local near_item = it("i:1:0:0", 9999, { x = 3, y = 0, z = 4 })
  local pts = core.overhead_points({ near_item }, cam, 50)
  check("mo OP1: live in radius -> one point", #pts == 1 and pts[1].marker == near_item)
  check("mo OP1: the point's pos is a plain copy of live (never pos)",
    pts[1].pos ~= nil and pts[1].pos.x == 3 and pts[1].pos.z == 4
    and pts[1].pos ~= near_item.live)
  check("mo OP2: live nil -> none",
    #core.overhead_points({ it("i:1:0:0", 0, nil) }, cam, 50) == 0)
  check("mo OP3: never reads pos (pos at the camera, live far) -> none",
    #core.overhead_points({ it("i:1:0:0", 0, { x = 1000, y = 0, z = 0 }) }, cam, 50) == 0)
  local cm = { key = "c:5", pos = { x = 0, y = 0, z = 0 }, cat = "startable",
    live = { x = 0, y = 0, z = 0 } }
  local pm = { key = "p:0:0:0", pos = { x = 0, y = 0, z = 0 }, cat = "in_progress",
    live = { x = 0, y = 0, z = 0 } }
  check("mo OP4: c- and p-keyed markers -> none",
    #core.overhead_points({ cm, pm }, cam, 50) == 0)
  check("mo OP5: boundary inclusive",
    #core.overhead_points({ it("i:1:0:0", 0, { x = 50, y = 0, z = 0 }) }, cam, 50) == 1)
  check("mo OP5: nil markers -> none", #core.overhead_points(nil, cam, 50) == 0)
  -- WW1 the tick's item-round decision (both toggles, never either)
  check("mo WW1: both on -> walk", core.item_walk_wanted({ in_progress = true, quest_items = true }) == true)
  check("mo WW1: quest_items off -> no walk", core.item_walk_wanted({ in_progress = true, quest_items = false }) == false)
  check("mo WW1: in_progress off -> no walk", core.item_walk_wanted({ in_progress = false, quest_items = true }) == false)
  check("mo WW1: both off / absent -> no walk", core.item_walk_wanted({}) == false
    and core.item_walk_wanted(nil) == false)
  local sel = core.overhead_anchors({ cm, near_item }, {}, cam, 50)
  check("mo OP6: overhead_anchors ignores item markers",
    #sel == 1 and sel[1].cid == 5)
end

-- jd: v9 quest-tree detail (SPEC 16.3b-e, 16.6a)
do
  local TO = { startable = true, in_progress = true, completed = false,
    unavailable = false, locked = false, tree_open = true }
  local function show(over)
    local s = {}
    for k, v in pairs(TO) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  -- 10 startable (hint 5 at 3,0,4); 11 in progress (cast 6 at 30,0,40);
  -- 12 locked named; 13 completed (hidden); 14 startable, static p-key
  local function world(o)
    local base = { acceptable = { 10, 14 }, progressing = { 11 },
      catalog = { 10, 11, 12, 13, 14 }, states = { [13] = "completed" },
      hints = { [10] = 5, [14] = 7 }, casts = { [11] = { 6 } },
      npc_pos = { [5] = { x = 3, y = 0, z = 4 }, [6] = { x = 30, y = 0, z = 40 } },
      statics = { [14] = { x = 100, y = 0, z = 0 } }, dead = { [7] = false },
      names = { [10] = "Ten", [11] = "Eleven", [12] = "Twelve", [13] = "Thirteen",
        [14] = "Fourteen" },
      regions = { [10] = "Vern", [11] = "Vern", [12] = "Vern", [13] = "Vern", [14] = "Melve" } }
    for k, v in pairs(o or {}) do base[k] = v end
    return base
  end
  -- counting adapter: every v9 read is logged as "<reader>:<qid or cid>"
  local function jad(o, j)
    local a = fake_adapter(world(o))
    j = j or {}
    a.reads = {}
    a.npc_pos = function(c)            -- 7 has no live position: p-key
      local p = ({ [5] = { x = 3, y = 0, z = 4 }, [6] = { x = 30, y = 0, z = 40 } })[c]
      if p then return p.x, p.y, p.z end
    end
    a.tracked_qid = function() a.reads[#a.reads + 1] = "tracked"; return j.tracked end
    a.npc_name = function(cid) a.reads[#a.reads + 1] = "name:" .. cid; return (j.npc or {})[cid] end
    a.journal_now = function(q)
      a.reads[#a.reads + 1] = "now:" .. q
      local v = (j.now or {})[q]
      if v == nil then return nil end
      local c = {}
      for k, x in pairs(v) do c[k] = x end
      return c
    end
    a.journal_all = function(q)
      a.reads[#a.reads + 1] = "all:" .. q
      return (j.all or {})[q]
    end
    return a
  end
  local function count(a, prefix)
    local n = 0
    for _, r in ipairs(a.reads) do if r:sub(1, #prefix) == prefix then n = n + 1 end end
    return n
  end
  local function rec(r, qid)
    for _, x in ipairs(r.quests or {}) do if x.qid == qid then return x end end
  end

  -- TO1 tree origin freshness
  local o = { x = 1, y = 2, z = 3 }
  check("jd TO1: 2.9 s old -> origin", core.tree_origin(o, 10.0, 12.9) == o)
  check("jd TO1: 3.0 s old -> nil (under 3 s only)", core.tree_origin(o, 10.0, 13.0) == nil)
  check("jd TO1: nil stamp / nil origin -> nil",
    core.tree_origin(o, nil, 1) == nil and core.tree_origin(nil, 1, 1) == nil)

  -- PS record pos / giver rules
  local a = jad()
  local r = core.compute(a, show())
  local r10, r11, r12, r13, r14 = rec(r, 10), rec(r, 11), rec(r, 12), rec(r, 13), rec(r, 14)
  check("jd PS1: startable pos = resolved raw position (copy)", r10.pos ~= nil
    and r10.pos.x == 3 and r10.pos.z == 4 and r10.pos ~= r.markers[1].pos)
  check("jd PS2: c-key giver = that cid", r10.giver == 5 and r11.giver == 6)
  check("jd PS3: p-key (static) giver = the hint", r14.pos ~= nil and r14.pos.x == 100
    and r14.giver == 7)
  check("jd PS4: hidden categories get no pos, no giver",
    r12.pos == nil and r12.giver == nil and r13.pos == nil and r13.giver == nil)
  local ru = core.compute(jad({ npc_pos = {}, statics = {}, hints = {} ,
    casts = { [11] = { 6 } } }), show())
  check("jd PS5: unresolved quest has no pos", rec(ru, 10).pos == nil and rec(ru, 10).giver == nil)
  local rl = core.compute(jad({ statics = { [12] = { x = 9, y = 9, z = 9 },
    [14] = { x = 100, y = 0, z = 0 } } }), show({ locked = true }))
  check("jd PS6: shown locked resolves a pos", rec(rl, 12).pos ~= nil and rec(rl, 12).pos.x == 9)

  -- NR tracked / dist / nearest
  a = jad(nil, { tracked = 11 })
  r = core.compute(a, show({ tree_origin = { x = 0, y = 0, z = 0 } }))
  check("jd NR1: tracked flag", rec(r, 11).tracked == true and rec(r, 10).tracked == false
    and r.tracked_qid == 11)
  check("jd NR2: dist is 3D distance from tree_origin", rec(r, 10).dist == 5
    and rec(r, 11).dist == 50 and rec(r, 14).dist == 100)
  check("jd NR3: nearest = smallest dist", r.nearest_qid == 10)
  check("jd NR4: no dist without pos", rec(r, 12).dist == nil and rec(r, 13).dist == nil)
  r = core.compute(jad(), show({ tree_origin = nil }))
  check("jd NR5: origin nil -> no dist, no nearest", rec(r, 10).dist == nil and r.nearest_qid == nil)
  check("jd NR6: tie -> lower qid", core.nearest({ { qid = 9, cat = "startable", dist = 1 },
    { qid = 4, cat = "in_progress", dist = 1 } }).qid == 4)
  check("jd NR7: only startable / in progress compete", core.nearest({
    { qid = 1, cat = "completed", dist = 0 }, { qid = 2, cat = "locked", dist = 0 },
    { qid = 3, cat = "startable", dist = 7 } }).qid == 3)
  check("jd NR8: nil dist skipped; none -> nil", core.nearest({ { qid = 1, cat = "startable" } }) == nil)
  check("jd NR9: tracked_qid nil -> nobody tracked", rec(core.compute(jad(), show()), 11).tracked == false)

  -- GN giver names: startable records with a giver only
  a = jad(nil, { npc = { [5] = "Brant" } })
  r = core.compute(a, show())
  check("jd GN1: startable giver name read and stored", rec(r, 10).giver_name == "Brant")
  check("jd GN2: in progress / hidden never read a name",
    count(a, "name:6") == 0 and rec(r, 11).giver_name == nil)
  check("jd GN3: unresolved name -> nil", rec(r, 14).giver_name == nil and count(a, "name:7") == 1)

  -- CL panel closed: no v9 reads of any kind
  a = jad(nil, { tracked = 11 })
  r = core.compute(a, show({ tree_open = false, expanded = { [10] = true } }))
  check("jd CL1: closed -> zero v9 reads, no journal", #a.reads == 0 and r.journal == nil
    and r.tracked_qid == nil)

  -- SP spoilers and locked rows
  a = jad(nil, { now = { [12] = { name = "Twelve" } }, all = { [12] = { steps = {} } } })
  r = core.compute(a, show({ expanded = { [12] = true }, now = 1 }))
  check("jd SP1: spoilers off + expanded locked -> zero reads of either kind",
    count(a, "now:") == 0 and count(a, "all:") == 0 and r.journal_all == nil)
  a = jad(nil, { now = { [12] = { name = "Twelve" } }, all = { [12] = { steps = {} } } })
  r = core.compute(a, show({ expanded = { [12] = true }, journal_spoilers = true, now = 1 }))
  check("jd SP2: spoilers on -> locked row read by both readers",
    count(a, "now:12") == 1 and count(a, "all:12") == 1 and r.journal_all[12] ~= nil)
  a = jad(nil, { tracked = 11 })
  r = core.compute(a, show({ expanded = { [10] = true }, now = 1 }))
  check("jd SP3: spoilers off -> journal_all never called", count(a, "all:") == 0)
  check("jd SP4: tracked + expanded read once each", count(a, "now:11") == 1
    and count(a, "now:10") == 1)

  -- RD read set: tracked, nearest, expanded; nil read stored as missing
  a = jad(nil, { tracked = 99, now = { [99] = { name = "Main" } } })
  r = core.compute(a, show({ tree_origin = { x = 0, y = 0, z = 0 }, now = 7 }))
  check("jd RD1: tracked qid with no record is read", count(a, "now:99") == 1
    and r.journal[99].name == "Main" and r.journal[99].read_at == 7)
  check("jd RD2: nearest read", count(a, "now:10") == 1)
  check("jd RD3: nil read -> { missing } entry with read_at",
    r.journal[10].missing == true and r.journal[10].read_at == 7)
  check("jd RD4: expanded qid with no record is not read",
    (function()
      local b = jad()
      core.compute(b, show({ expanded = { [555] = true }, now = 1 }))
      return count(b, "now:") == 0
    end)())
  a = jad(nil, { tracked = nil })
  r = core.compute(a, show({ tree_origin = { x = 0, y = 0, z = 0 }, now = 1 }))
  check("jd RD5: nothing tracked -> nearest still read", r.tracked_qid == nil
    and r.nearest_qid == 10 and count(a, "now:10") == 1)

  -- CAP 12 reads per tick with carry-over and drop
  local qs, names, regions = {}, {}, {}
  for i = 1, 15 do qs[i] = 100 + i; names[100 + i] = "Q" .. i; regions[100 + i] = "Vern" end
  local exp = {}
  for _, q in ipairs(qs) do exp[q] = true end
  local function cap_adapter()
    return jad({ acceptable = qs, progressing = {}, catalog = qs, hints = {},
      casts = {}, statics = {}, states = {}, names = names, regions = regions })
  end
  a = cap_adapter()
  r = core.compute(a, show({ expanded = exp, now = 1 }))
  check("jd CAP1: 15 expanded -> 12 reads", count(a, "now:") == 12)
  check("jd CAP2: never-read first, ascending qid",
    r.journal[101] ~= nil and r.journal[112] ~= nil and r.journal[113] == nil)
  a = cap_adapter()
  local prev = r.journal
  prev[150] = { read_at = 0 }                       -- no longer wanted
  local ok2, r2 = pcall(core.compute, a, show({ expanded = exp, now = 2, prev_journal = prev }))
  check("jd CAP3a: ranking with a previous journal does not raise", ok2)
  if not ok2 then r2 = { journal = {} } end
  check("jd CAP3: unread qids (113-115) read before the oldest-read",
    count(a, "now:113") == 1 and count(a, "now:114") == 1 and count(a, "now:115") == 1)
  check("jd CAP4: then the oldest-read, by qid (101-109 read, 110-112 carried)",
    count(a, "now:109") == 1 and count(a, "now:110") == 0)
  check("jd CAP5: carried entry kept as-is", r2.journal[110] == prev[110]
    and r2.journal[110].read_at == 1 and r2.journal[101].read_at == 2)
  check("jd CAP6: entry for a qid no longer wanted dropped", r2.journal[150] == nil)
  a = cap_adapter()
  local ok3, r3 = pcall(core.compute, a, show({ expanded = exp, now = 3, prev_journal = r2.journal }))
  check("jd CAP7a: second ranking tick does not raise", ok3)
  if not ok3 then r3 = { journal = {} } end
  check("jd CAP7: oldest-read (110-112, read_at 1) go first next tick",
    count(a, "now:110") == 1 and count(a, "now:112") == 1 and r3.journal[112].read_at == 3)
  a = cap_adapter()
  core.compute(a, show({ expanded = exp, now = 1, journal_spoilers = true }))
  check("jd CAP8: journal_all under the same cap", count(a, "all:") == 12)

end

-- dm: v9 row detail model (SPEC 16.3d, 16.3e, 16.3h, 16.10)
do
  -- RL row label
  local R = { qid = 10, name = "Ten", state = "startable", waiting = " (waiting on: X)",
    tracked = true }
  check("jd RL1: text, tags, id", core.row_label(R, 10)
    == "Ten - startable (waiting on: X) [tracked] [nearest]###qd_10")
  check("jd RL2: no tags", core.row_label({ qid = 3, name = "A", state = "locked" }, nil)
    == "A - locked###qd_3")

  -- DM detail model per category
  local d = core.row_detail({ cat = "startable", region = "Vern", waiting = " (waiting on: X)",
    giver_name = "Brant", pos = { x = 1, y = 2, z = 3 } }, { summary = "Sum" }, nil, false)
  check("jd DM1: startable lines", #d.lines == 4 and d.lines[1] == "To start: talk to Brant"
    and d.lines[2] == "Region: Vern" and d.lines[3] == "Sum" and d.lines[4] == "(waiting on: X)")
  check("jd DM1: startable jump = record pos", d.jump.x == 1 and d.jump.z == 3)
  d = core.row_detail({ cat = "startable", region = "Vern" }, nil, nil, false)
  check("jd DM2: no giver name -> the quest giver; no pos -> no jump",
    d.lines[1] == "To start: talk to the quest giver" and #d.lines == 2 and d.jump == nil)
  d = core.row_detail({ cat = "startable", giver_name = "Brant" }, nil, nil, false)
  check("jd DM2b: no region -> no Region line", #d.lines == 1
    and d.lines[1] == "To start: talk to Brant")
  local J = { base = "Find him.", detail = "He is lost.", step_index = 1,
    checks = { { text = "Ask", done = true }, { text = "Look", done = false } },
    dest = { x = 9, y = 8, z = 7, caption = "Slums" } }
  d = core.row_detail({ cat = "in_progress", pos = { x = 1, y = 1, z = 1 } }, J, nil, false)
  check("jd DM3: in progress lines", #d.lines == 5 and d.lines[1] == "Now: Find him."
    and d.lines[2] == "He is lost." and d.lines[3] == "[x] Ask" and d.lines[4] == "[ ] Look"
    and d.lines[5] == "Destination: Slums")
  check("jd DM3: in progress jump = dest", d.jump.x == 9 and d.jump.z == 7)
  d = core.row_detail({ cat = "in_progress", pos = { x = 1, y = 1, z = 1 } }, { missing = true }, nil, false)
  check("jd DM4: no journal data -> no lines, jump = pos", #d.lines == 0 and d.jump.x == 1)
  d = core.row_detail({ cat = "locked", waiting = " (waiting on: X)", pos = { x = 1, y = 1, z = 1 } },
    { summary = "S" }, nil, false)
  check("jd DM5: locked = waiting only, no jump", #d.lines == 1
    and d.lines[1] == "(waiting on: X)" and d.jump == nil)
  for _, c in ipairs({ "completed", "failed", "canceled", "giver_dead" }) do
    d = core.row_detail({ cat = c }, { summary = "S" }, nil, false)
    check("jd DM6: " .. c .. " = summary", #d.lines == 1 and d.lines[1] == "S")
  end
  d = core.row_detail(nil, { base = "Go.", dest = { x = 1, y = 2, z = 3 } }, nil, false)
  check("jd DM7: tracked without record: in-progress lines, jump = dest",
    d.lines[1] == "Now: Go." and d.jump.y == 2)
  check("jd DM7: tracked without record, no dest -> no jump",
    core.row_detail(nil, { base = "Go." }, nil, false).jump == nil)

  -- SM step markers (0-based step_index)
  local ALL = { steps = { { base = "A" }, { base = "B" }, { base = "C" }, { base = "D" } } }
  d = core.row_detail({ cat = "in_progress" }, { step_index = 1 }, ALL, true)
  check("jd SM1: in progress markers", #d.steps == 4 and d.steps[1] == "done: A"
    and d.steps[2] == "> B" and d.steps[3] == "C" and d.steps[4] == "D")
  d = core.row_detail({ cat = "in_progress" }, { step_index = 0 }, ALL, true)
  check("jd SM2: index 0 marks the first step", d.steps[1] == "> A" and d.steps[2] == "B")
  d = core.row_detail({ cat = "completed" }, nil, ALL, true)
  check("jd SM3: completed -> every step done", d.steps[1] == "done: A" and d.steps[4] == "done: D")
  d = core.row_detail({ cat = "startable", region = "V" }, nil, ALL, true)
  check("jd SM4: other categories: no markers", d.steps[1] == "A" and d.steps[4] == "D")
  check("jd SM5: spoilers off -> no steps", core.row_detail({ cat = "in_progress" },
    { step_index = 1 }, ALL, false).steps == nil)
  check("jd SM6: no catalog entry -> no steps", core.row_detail({ cat = "in_progress" },
    { step_index = 1 }, { missing = true }, true).steps == nil)
  d = core.row_detail({ cat = "in_progress" }, { step_index = 2 }, { steps = {
    { base = "A" }, { base = "<COLOR FF0000>#Rejected#</COLOR> Mes_x_002" }, { base = "C" } } }, true)
  check("jd SM7: game-cut steps hidden, marker keeps game index",
    #d.steps == 2 and d.steps[1] == "done: A" and d.steps[2] == "> C")

  -- SN summary nodes
  local res = { quests = { { qid = 10, name = "Ten", state = "startable", dist = 5.4 },
    { qid = 11, name = "Eleven", state = "in progress", dist = 50 } },
    tracked_qid = 11, nearest_qid = 10, journal = {} }
  local sn = core.summary_nodes(res)
  check("jd SN1: tracked + nearest nodes", #sn == 2
    and sn[1].label == "Tracked: Eleven - in progress###qd_tracked"
    and sn[2].label == "Nearest: Ten - startable, 5 m###qd_nearest")
  res.tracked_qid = 10
  sn = core.summary_nodes(res)
  check("jd SN2: same quest -> one node", #sn == 1
    and sn[1].label == "Tracked and nearest: Ten - startable, 5 m###qd_tracked")
  res.tracked_qid, res.nearest_qid = 99, nil
  res.journal = { [99] = { name = "Main Quest" } }
  sn = core.summary_nodes(res)
  check("jd SN3: tracked without record -> journal name, no state", #sn == 1
    and sn[1].label == "Tracked: Main Quest###qd_tracked" and sn[1].rec == nil)
  res.journal = { [99] = { missing = true } }
  check("jd SN4: tracked without record or journal -> omitted", #core.summary_nodes(res) == 0)

  -- ST state lines (debug entry point / dump)
  res = { quests = { { qid = 10, cat = "startable", name = "Ten", state = "startable",
    region = "Vern", giver_name = "Brant", pos = { x = 1, y = 2, z = 3 } } },
    tracked_qid = nil, nearest_qid = nil, journal = {} }
  local sl = core.state_lines(res, { [10] = true }, false)
  check("jd ST1: expanded row lines", sl[1] == "[10] Ten - startable"
    and sl[2] == "  To start: talk to Brant" and sl[3] == "  Region: Vern"
    and sl[4] == "  jump 1.0, 2.0, 3.0")
  local function empty_ok(f, ...)
    local ok, v = pcall(f, ...)
    return ok and type(v) == "table" and #v == 0
  end
  check("jd ST2: no snapshot / no records -> empty lists",
    empty_ok(core.state_lines, nil, { [1] = true }, false)
    and empty_ok(core.state_lines, { quests = nil }, { [1] = true }, false)
    and empty_ok(core.summary_nodes, nil) and empty_ok(core.summary_nodes, {}))

  -- JL readout line
  check("jd JL1: journal line", core.journal_line({ read = 4, cached = 9, failed = 1,
    tracked = 20120, on_target = 2, off_target = 1, timeout = 0, canceled = 1 })
    == "Journal: 4 read, 9 text cached, 1 failed, tracked 20120; jumps 4: on target 2, off target 1, timed out 0, canceled 1")
  check("jd JL2: nothing tracked", core.journal_line({ read = 0, cached = 0, failed = 0,
    on_target = 0, off_target = 0, timeout = 0, canceled = 0 }):find("tracked none;", 1, true) ~= nil)
end

-- wd: world markers (v10, SPEC 17.4, 17.3b.1)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local SH = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_show_opened = false, world_undiscovered = false,
    world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SH) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local O = P(0, 0, 0)
  local function by_key(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end
  local function keys(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    return table.concat(t, ",")
  end

  -- WD1 labels
  local w = {
    chests = { { uid = "c1", pos = P(1), state = "unopened", item_name = "Fulminous Shield" },
               { uid = "c2", pos = P(2), state = "unopened" } },
    treasure = { { name = "Gimmick_Treasure_001", pos = P(30), checked = false, discovered = true } },
    monsters = { { uid = "m1", cid = 5, name = "Ogre", pos = P(4), respawning = false } },
    sellers = { { shop = 7, item = 9, item_name = "Fulminous Shield", cid = 100,
                  npc = "Dudley", qids = { 30150 }, quest = "Spellbound",
                  pos = P(5), maybe_locked = false, discovered = true },
                { shop = 7, item = 10, item_name = "Fulminous Shield", cid = 101,
                  npc = "Dudley", qids = { 30150 }, quest = "Spellbound",
                  pos = P(6), maybe_locked = true, discovered = true } },
  }
  local ms, panel = core.world_markers(w, sh(), O, {})
  local k = by_key(ms)
  check("wd labels: chest with item", k["w:chest:c1"].label == "Chest - Fulminous Shield")
  check("wd labels: chest plain", k["w:chest:c2"].label == "Chest")
  check("wd labels: treasure", k["w:tre:Gimmick_Treasure_001"].label == "Treasure")
  check("wd labels: monster", k["w:mon:m1"].label == "Ogre")
  check("wd labels: seller", k["w:sell:7:9"].label
    == "Fulminous Shield - sold by Dudley (for Spellbound)")
  check("wd labels: seller maybe locked", k["w:sell:7:10"].label
    == "Fulminous Shield - sold by Dudley (for Spellbound) (may be locked)")
  -- WD2 keys and qids
  check("wd keys: four prefixes", k["w:chest:c1"] and k["w:mon:m1"]
    and k["w:tre:Gimmick_Treasure_001"] and k["w:sell:7:9"])
  check("wd keys: qids empty except sellers", #k["w:chest:c1"].qids == 0
    and #k["w:mon:m1"].qids == 0 and #k["w:tre:Gimmick_Treasure_001"].qids == 0
    and #k["w:sell:7:9"].qids == 1 and k["w:sell:7:9"].qids[1] == 30150)
  check("wd keys: cat names", k["w:chest:c1"].cat == "chest"
    and k["w:mon:m1"].cat == "monster" and k["w:sell:7:9"].cat == "seller"
    and k["w:tre:Gimmick_Treasure_001"].cat == "treasure")
  check("wd panel: counts", panel.chest.shown == 2 and panel.chest.known == 2
    and panel.seller.shown == 2 and panel.treasure.known == 1
    and #panel.monster.entries == 1)
  local mw = { monsters = { { uid = "m2", cid = 5, name = "Ogre", pos = P(1), respawning = true } } }
  ms = core.world_markers(mw, sh(), O, {})
  check("wd labels: respawning suffix", ms[1].label == "Ogre (respawning)")

  -- WD3 opened / unknown / checked
  w = { chests = { { uid = "o", pos = P(1), state = "opened" },
                   { uid = "u", pos = P(2), state = "unknown" },
                   { uid = "n", pos = P(3), state = "unopened" } },
        treasure = { { name = "T1", pos = P(30), checked = true, discovered = true } } }
  ms, panel = core.world_markers(w, sh(), O, {})
  k = by_key(ms)
  check("wd opened: opened chest hidden", k["w:chest:o"] == nil and panel.chest.known == 3
    and panel.chest.shown == 2)
  check("wd opened: unknown chest done=false", k["w:chest:u"] and k["w:chest:u"].done == false)
  check("wd opened: checked treasure done=true", k["w:tre:T1"] and k["w:tre:T1"].done == true)
  ms = core.world_markers(w, sh({ world_show_opened = true }), O, {})
  k = by_key(ms)
  check("wd opened: show_opened draws done", k["w:chest:o"] and k["w:chest:o"].done == true)

  -- WD4 toggles off
  local off = sh({ world_chests = false, world_treasure = false,
    world_monsters = false, world_sellers = false, world_tokens = false,
    world_beetles = false })
  w = { chests = { { uid = "c", pos = P(1), state = "unopened" } },
        treasure = { { name = "T", pos = P(30), checked = false, discovered = true } },
        monsters = { { uid = "m", cid = 1, name = "Ogre", pos = P(3), respawning = false } },
        tokens = { { uid = "k", pos = P(5), name = "Tok", state = "not" } },
        beetles = { { uid = "b", pos = P(6), name = "Bee", state = "not" } },
        sellers = { { shop = 1, item = 2, item_name = "X", cid = 5, npc = "N", qids = { 1 },
                      quest = "Q", pos = P(4), maybe_locked = false, discovered = true } } }
  ms, panel = core.world_markers(w, off, O, {})
  check("wd toggles off: tokens and beetles known, not shown", #ms == 0
    and panel.token.known == 1 and panel.token.shown == 0
    and panel.beetle.known == 1 and panel.beetle.shown == 0)
  check("wd toggles off: no markers, known counted", #ms == 0
    and panel.chest.shown == 0 and panel.chest.known == 1
    and panel.treasure.shown == 0 and panel.treasure.known == 1
    and panel.monster.shown == 0 and panel.monster.known == 1
    and panel.seller.shown == 0 and panel.seller.known == 1)

  -- WD5 cap with mixed categories
  w = { chests = { { uid = "a", pos = P(5), state = "unopened" },
                   { uid = "b", pos = P(6), state = "unopened" } },
        treasure = { { name = "T", pos = P(100), checked = false, discovered = true } } }
  ms, panel = core.world_markers(w, sh({ world_max_markers = 2 }), O, {})
  check("wd cap: two chests win over far treasure", keys(ms) == "w:chest:a,w:chest:b"
    and panel.treasure.shown == 0 and panel.treasure.known == 1)
  w.treasure[1].pos = P(1)
  ms = core.world_markers(w, sh({ world_max_markers = 3 }), O, {})
  check("wd cap: category order then distance", keys(ms) == "w:tre:T,w:chest:a,w:chest:b")
  ms = core.world_markers(w, sh({ world_max_markers = 0 }), O, {})
  check("wd cap: zero keeps none", #ms == 0)
  w.treasure[1].pos = P(20)
  ms = core.world_markers(w, sh({ world_max_markers = 3 }), O, {})
  check("wd cap: category order beats distance in output",
    keys(ms) == "w:tre:T,w:chest:a,w:chest:b")

  -- WD6 no origin
  w = { chests = { { uid = "b", pos = P(1), state = "unopened" },
                   { uid = "a", pos = P(9), state = "unopened" } },
        treasure = { { name = "T", pos = P(50), checked = false, discovered = true } } }
  local ok
  ok, ms = pcall(core.world_markers, w, sh(), nil, {})
  check("wd no origin: category then key, no error", ok
    and keys(ms) == "w:tre:T,w:chest:a,w:chest:b")
  ok, ms = pcall(core.world_markers, w, sh({ world_max_markers = 1 }), nil, {})
  check("wd no origin: cap selects by category first", ok and keys(ms) == "w:tre:T")

  -- WD7 world_ord stable
  w = { chests = { { uid = "a", pos = P(1), state = "unopened" },
                  { uid = "b", pos = P(2), state = "unopened" },
                  { uid = "c", pos = P(3), state = "unopened" } } }
  local m1 = core.world_markers(w, sh(), P(0), {})
  local m2 = core.world_markers(w, sh(), P(10), {})
  local o1, o2, seen = by_key(m1), by_key(m2), {}
  local distinct = true
  for _, m in pairs(o1) do
    if math.type(m.world_ord) ~= "integer" or seen[m.world_ord] then distinct = false end
    seen[m.world_ord] = true
  end
  check("wd ord: distinct integers from 1", distinct and seen[1] and seen[2] and seen[3])
  check("wd ord: distance order flipped", keys(m1) ~= keys(m2))
  check("wd ord: unchanged when origin moves", o1["w:chest:a"].world_ord == o2["w:chest:a"].world_ord
    and o1["w:chest:c"].world_ord == o2["w:chest:c"].world_ord
    and o1["w:chest:a"].world_ord == 1 and o1["w:chest:c"].world_ord == 3)

  -- WD8 compute appends world markers last
  local function cw(world_over, show_over, ex)
    local o = { acceptable = { 20 }, progressing = { 10 }, names = { [10] = "A", [20] = "B" },
      statics = { [20] = P(500, 0, 500) }, casts = {},
      item_needs = { [10] = { { id = 300, num = 1 } } },
      item_locs = { { id = 300, pos = P(7, 2, 3), src = "placed" } },
      item_names = { [300] = "Garb" } }
    for kk, v in pairs(ex or {}) do o[kk] = v end
    local show = sh({ startable = true, in_progress = true, quest_items = true,
      world = world_over })
    for kk, v in pairs(show_over or {}) do show[kk] = v end
    return core.compute(fake_adapter(o), show)
  end
  local r = cw({ chests = { { uid = "z", pos = P(1), state = "unopened" } } })
  local cats = {}
  for _, m in ipairs(r.markers) do cats[#cats + 1] = m.cat end
  local seq = table.concat(cats, ",")
  check("wd compute: quest, item, world order", seq:match("quest_item,chest$") ~= nil
    and r.world ~= nil and r.world.chest.shown == 1)
  r = cw(nil)
  local has_w = false
  for _, m in ipairs(r.markers) do if m.key:sub(1, 2) == "w:" then has_w = true end end
  check("wd compute: world nil -> no world markers, no snapshot.world",
    r.world == nil and not has_w)

  r = cw({ chests = { { uid = "n1", pos = P(1), state = "unopened" },
                      { uid = "n49", pos = P(49), state = "unopened" } } },
    { world_origin = P(50), world_max_markers = 1 })
  local only = {}
  for _, m in ipairs(r.markers) do
    if m.key:sub(1, 2) == "w:" then only[#only + 1] = m.key end
  end
  check("wd compute: show.world_origin picks the nearest", #only == 1
    and only[1] == "w:chest:n49")

  -- WD10 dedupe against box records
  r = cw({ chests = { { uid = "near", pos = P(7.5, 2, 3), state = "unopened" },
                      { uid = "far", pos = P(50, 2, 3), state = "unopened" } } },
    nil, { item_locs = { { id = 300, pos = P(7, 2, 3), src = "box" } } })
  local seen_w = {}
  for _, m in ipairs(r.markers) do seen_w[m.key] = true end
  check("wd dedupe: chest within 1 unit of a box record not drawn",
    not seen_w["w:chest:near"] and seen_w["w:chest:far"])

  -- WD11 seller merge
  local sell = { shop = 3, item = 4, item_name = "Grimoire", cid = 55, npc = "Dudley",
    qids = { 10 }, quest = "A", pos = P(40), maybe_locked = false, discovered = true }
  local sell2 = { shop = 3, item = 5, item_name = "Tome", cid = 66, npc = "Gil",
    qids = { 10 }, quest = "A", pos = P(41), maybe_locked = false, discovered = true }
  r = cw({ sellers = { sell, sell2 } }, nil,
    { casts = { [20] = { 55 } }, npc_pos = { [55] = P(30, 0, 30) } })
  local qm, sm = nil, 0
  for _, m in ipairs(r.markers) do
    if m.key == "c:55" then qm = m end
    if m.key == "w:sell:3:4" then sm = sm + 1 end
  end
  local line = "Grimoire - sold by Dudley (for A)"
  check("wd merge: no seller marker for a cid with a quest marker", qm ~= nil and sm == 0)
  check("wd merge: hover ends with seller line", qm and qm.hover
    and qm.hover:sub(-#line) == line and qm.hover:find("\n", 1, true) ~= nil)
  check("wd merge: other seller still drawn, merged counts in known not shown",
    r.world.seller.known == 2 and r.world.seller.shown == 1)
  local merged_none = core.world_markers({ sellers = { sell } }, sh(), O, {}, { [55] = true })
  check("wd merge: world_markers drops merged seller", #merged_none == 0)

  -- WD12 signature includes done
  local a = { key = "w:chest:q", pos = P(1), qids = {}, cat = "chest", label = "Chest", done = false }
  local sig1 = core.signature({ a }, {})
  a.done = true
  local sig2 = core.signature({ a }, {})
  check("wd sig: done flips signature", sig1 ~= sig2)

  -- WD13 undiscovered
  w = { treasure = { { name = "T", pos = P(30), checked = false, discovered = false } },
        sellers = { { shop = 1, item = 2, item_name = "X", cid = 5, npc = "N", qids = { 1 },
                      quest = "Q", pos = P(2), maybe_locked = false, discovered = false } },
        chests = { { uid = "c", pos = P(3), state = "unopened" } } }
  ms, panel = core.world_markers(w, sh(), O, {})
  check("wd undiscovered: hidden by default", keys(ms) == "w:chest:c"
    and panel.treasure.known == 1 and panel.treasure.shown == 0 and panel.seller.known == 1)
  ms = core.world_markers(w, sh({ world_undiscovered = true }), O, {})
  check("wd undiscovered: shown when on", #ms == 3)

  -- WD14 giver fallback
  local function giver(over, show_over)
    local o = { acceptable = { 20 }, names = { [20] = "B" }, casts = { [20] = { 55, 77 } } }
    for kk, v in pairs(over or {}) do o[kk] = v end
    local show = sh({ startable = true, in_progress = true, world = {} })
    for kk, v in pairs(show_over or {}) do show[kk] = v end
    if show.world == "nil" then show.world = nil end
    local res = core.compute(fake_adapter(o), show)
    return res.markers[1]
  end
  local g = giver(nil, { world_givers = { [77] = P(1, 2, 3) } })
  check("wd giver: fallback via cast", g and g.pos.x == 1 and g.pos.y == 2 and g.pos.z == 3)
  g = giver({ npc_pos = { [55] = P(9, 9, 9) } }, { world_givers = { [77] = P(1, 2, 3) } })
  check("wd giver: NPC position wins", g and g.pos.x == 9)
  g = giver({ casts = {}, hints = { [20] = 77 } }, { world_givers = { [77] = P(1, 2, 3) } })
  check("wd giver: hint resolves", g and g.pos.x == 1)
  g = giver(nil, { world = "nil", world_givers = { [77] = P(1, 2, 3) } })
  check("wd giver: resolves with show.world absent", g and g.pos.x == 1)
  g = giver({ casts = { [20] = { 55 } } }, { world_givers = {} })
  check("wd giver: nothing -> no marker", g == nil)

  -- WD15 schedule
  g = giver({ casts = { [20] = { 55 } } }, { world = { schedule = { [55] = P(4, 5, 6) } } })
  check("wd schedule: position used", g and g.pos.x == 4 and g.pos.y == 5 and g.pos.z == 6)
  g = giver({ casts = { [20] = { 55 } } }, { world = { schedule = { [55] = P(0, 0, 0.5) } } })
  check("wd schedule: near-zero skipped", g == nil)
  g = giver({ casts = { [20] = { 55 } } },
    { world = { schedule = { [55] = P(0, 0, 0.5) } }, world_givers = { [55] = P(7, 8, 9) } })
  check("wd schedule: skipped schedule falls to giver", g and g.pos.x == 7)

  g = giver({ casts = { [20] = { 55 } } },
    { world = { schedule = { [55] = P(4, 5, 6) } }, world_givers = { [55] = P(7, 8, 9) } })
  check("wd schedule: schedule beats atlas giver", g and g.pos.x == 4)
  g = giver({ hints = { [20] = 55 } }, { world_givers = { [77] = P(1, 2, 3) } })
  check("wd giver: cast ids consulted beyond the hint", g and g.pos.x == 1)

  -- WD16 item walk
  check("wd walk: sellers alone wants the walk", core.item_walk_wanted({ world_sellers = true }) == true)
  check("wd walk: nothing on -> no walk", core.item_walk_wanted({}) == false)

  -- WD17 world_rows
  local entries = {}
  for i = 1, 12 do
    entries[i] = { key = "w:chest:" .. i, label = "Chest", pos = P(i * 10, 0, 0) }
  end
  local rows = core.world_rows(entries, { { name = "Vernworth", pos = P(0, 0, 0) },
    { name = "Melve", pos = P(5000, 0, 0) } }, P(35, 0, 0))
  check("wd rows: ten rows nearest first", #rows == 10 and rows[1].key == "w:chest:3"
    and rows[1].text == "Chest - near Vernworth" and rows[1].pos.x == 30)
  rows = core.world_rows(entries, { { name = "Vernworth", pos = P(0, 0, 0) } }, nil)
  check("wd rows: nil origin list order", #rows == 10 and rows[1].key == "w:chest:1"
    and rows[10].key == "w:chest:10")

  -- WD18 overhead ignores world
  ms = core.world_markers({ chests = { { uid = "c", pos = P(1), state = "unopened" } } }, sh(), O, {})
  check("wd overhead: w: keys give no anchors", #core.overhead_anchors(ms, {}, P(0), 50) == 0)

  -- WD9 minimap: quest and item first
  local mm = {}
  for i = 1, 12 do
    mm[#mm + 1] = { key = string.format("w:chest:%02d", i), cat = "chest", pos = P(5), qids = {} }
  end
  mm[#mm + 1] = { key = "c:1", cat = "startable", pos = P(40), qids = { 1 } }
  mm[#mm + 1] = { key = "c:2", cat = "startable", pos = P(40), qids = { 2 } }
  mm[#mm + 1] = { key = "i:300:0:0", cat = "quest_item", pos = P(40), qids = { 1 } }
  local out = core.minimap_markers(mm, O, 100, 12)
  local got = {}
  for _, m in ipairs(out) do got[m.key] = true end
  check("wd minimap: quest and item markers before world", #out == 12
    and got["c:1"] and got["c:2"] and got["i:300:0:0"])
end

-- wd2: tokens, beetles, small monsters, chest label, dedupe, grid cull (Task 10)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local SH = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SH) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local O = P(0, 0, 0)
  local function keys(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    return table.concat(t, ",")
  end
  local function by_key(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end

  -- world_six_order
  local w = {
    chests = { { uid = "c", pos = P(1), state = "unopened" } },
    treasure = { { name = "T", pos = P(50), checked = false, discovered = true } },
    tokens = { { uid = "k", pos = P(2), name = "Token A", state = "not" } },
    beetles = { { uid = "b", pos = P(3), name = "Beetle A", state = "not" } },
    monsters = { { uid = "m", cid = 1, name = "Ogre", pos = P(4), respawning = false } },
    sellers = { { shop = 1, item = 2, item_name = "X", cid = 9, npc = "N", qids = {},
                  quest = "", pos = P(5), maybe_locked = false, discovered = true } },
  }
  local ms, panel = core.world_markers(w, sh(), O, {})
  check("wd2 six order", keys(ms) == "w:tre:T,w:tok:k,w:bee:b,w:sell:1:2,w:mon:m,w:chest:c")
  check("wd2 eight cats", #core.WORLD_CATS == 8 and panel.token.shown == 1 and panel.beetle.shown == 1)
  ms = core.world_markers(w, sh({ world_max_markers = 3 }), nil, {})
  check("wd2 six order no origin", keys(ms) == "w:tre:T,w:tok:k,w:bee:b")

  -- world_toggles_new
  ms = core.world_markers(w, sh({ world_tokens = false }), O, {})
  check("wd2 tokens off", keys(ms) == "w:tre:T,w:bee:b,w:sell:1:2,w:mon:m,w:chest:c")
  ms = core.world_markers(w, sh({ world_beetles = false }), O, {})
  check("wd2 beetles off", keys(ms) == "w:tre:T,w:tok:k,w:sell:1:2,w:mon:m,w:chest:c")

  -- token_done_style
  local tw = { tokens = { { uid = "n", pos = P(1), name = "Not", state = "not" },
                          { uid = "d", pos = P(2), name = "Done", state = "collected" },
                          { uid = "u", pos = P(3), name = "Unk", state = "unknown" } } }
  ms, panel = core.world_markers(tw, sh(), O, {})
  local k = by_key(ms)
  check("wd2 token collected hidden", k["w:tok:d"] == nil and k["w:tok:n"] and panel.token.known == 3)
  check("wd2 token labels", k["w:tok:n"].label == "Not" and k["w:tok:n"].done == false
    and k["w:tok:u"].done == false)
  ms = core.world_markers(tw, sh({ world_show_opened = true }), O, {})
  k = by_key(ms)
  check("wd2 token collected shown done", k["w:tok:d"] and k["w:tok:d"].done == true
    and k["w:tok:d"].label == "Done")
  ms = core.world_markers({ beetles = tw.tokens }, sh({ world_show_opened = true }), O, {})
  check("wd2 beetle keys", by_key(ms)["w:bee:d"] and by_key(ms)["w:bee:d"].done == true)

  -- small_monster_filter
  local mw = { monsters = { { uid = "s", cid = 1, name = "Goblin", pos = P(1), small = true },
                            { uid = "g", cid = 2, name = "Ogre", pos = P(2), small = false } } }
  ms, panel = core.world_markers(mw, sh(), O, {})
  check("wd2 small absent by default", keys(ms) == "w:mon:g" and panel.monster.known == 1)
  ms, panel = core.world_markers(mw, sh({ world_small_monsters = true }), O, {})
  check("wd2 small present when on", #ms == 2 and panel.monster.known == 2)
  -- SPEC 28.12.3: Large and Small are independent; Small alone shows the small ones
  ms, panel = core.world_markers(mw, sh({ world_small_monsters = true, world_monsters = false }), O, {})
  check("wd2 small shows with Large off", keys(ms) == "w:mon:s" and panel.monster.known == 2)

  -- chest_label_rules
  local function lbl(c) return core.chest_label(c) end
  check("wd2 label item_name", lbl({ item_name = "Ferrystone" }) == "Chest - Ferrystone")
  check("wd2 label items", lbl({ items = { { name = "A", n = 2 }, { name = "B", n = 1 } } })
    == "Chest - A x2, B")
  check("wd2 label five", lbl({ items = { { name = "A", n = 1 }, { name = "B", n = 1 },
    { name = "C", n = 1 }, { name = "D", n = 1 }, { name = "E", n = 1 } } }) == "Chest - A, B, C (+2)")
  check("wd2 label none", lbl({}) == "Chest" and lbl({ items = {} }) == "Chest")
  check("wd2 label item_name wins", lbl({ item_name = "Z", items = { { name = "A", n = 1 } } })
    == "Chest - Z")
  ms = core.world_markers({ chests = { { uid = "c", pos = P(1), state = "unopened",
    items = { { name = "A", n = 3 } } } } }, sh(), O, {})
  check("wd2 label in marker", ms[1].label == "Chest - A x3")

  -- treasure labels and search by item name
  local function tl(items)
    local m = core.world_markers({ treasure = { { name = "TL", pos = P(5), checked = false,
      discovered = true, items = items } } }, sh(), O, {})
    return m[1] and m[1].label
  end
  check("tl one item", tl({ { name = "Gold", n = 1100 } }) == "Treasure - Gold x1100")
  check("tl four items", tl({ { name = "a", n = 1 }, { name = "b", n = 1 },
    { name = "c", n = 1 }, { name = "d", n = 1 } }) == "Treasure - a, b, c (+1)")
  check("tl none", tl(nil) == "Treasure")
  check("tl nil mixed", tl({ { name = nil, n = 1 }, { name = "a", n = 1 }, { name = "b", n = 1 },
    { name = "c", n = 1 }, { name = "d", n = 1 } }) == "Treasure - a, b, c (+1)")
  check("tl nil name skipped", tl({ { name = nil, n = 1 } }) == "Treasure")
  do
    local w = { treasure = {
      { name = "T1", pos = P(5), checked = false, discovered = true,
        items = { { name = "Gold", n = 1100 } } },
      { name = "T2", pos = P(60), checked = false, discovered = true },
      { name = "T3", pos = P(120), checked = false, discovered = true,
        items = { { name = nil, n = 1 } } } } }
    local function cnt(q)
      return #core.world_markers(w, sh({ search = core.parse_query(q) }), O, {})
    end
    check("tl search gold matches first only", cnt("gold") == 1)
    check("tl search treasure matches all", cnt("treasure") == 3)
  end

  -- treasure_chest_dedupe
  local function dd(dx, state)
    local m = core.world_markers({
      chests = { { uid = "c", pos = P(100), state = state or "unopened" } },
      treasure = { { name = "T", pos = P(100 + dx), checked = false, discovered = true } } },
      sh(), O, {})
    return keys(m)
  end
  check("wd2 dedupe 2.9", dd(2.9) == "w:chest:c")
  check("wd2 dedupe 3.1", dd(3.1) == "w:tre:T,w:chest:c")
  check("wd2 dedupe exactly 3", dd(3) == "w:chest:c")
  check("wd2 dedupe 3.01", dd(3.01) == "w:tre:T,w:chest:c")
  check("wd2 dedupe opened chest", dd(1, "opened") == "")

  -- grid_cull_equivalent
  local stats = core.world_stats
  local function sorted_keys(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    table.sort(t)
    return table.concat(t, ",")
  end
  local function panel_sig(p)
    local t = {}
    for _, cat in ipairs(core.WORLD_CATS) do
      local ks = {}
      for i, m in ipairs(p[cat].entries) do ks[i] = m.key end
      t[#t + 1] = cat .. ":" .. p[cat].shown .. "/" .. p[cat].known .. ":" .. table.concat(ks, "+")
    end
    return table.concat(t, "|")
  end
  local function merged_sig(mg)
    local t = {}
    for i, m in ipairs(mg) do t[i] = m.cid .. "=" .. m.line end
    table.sort(t)
    return table.concat(t, ";")
  end
  -- ser: every marker field, for markers and for every category's panel
  -- entries (sells_for joined by newline, stock as names, "!" after locked)
  local function ser(ms)
    local out = {}
    for i, m in ipairs(ms) do
      local ks = {}
      for k in pairs(m) do ks[#ks + 1] = k end
      table.sort(ks)
      local parts = {}
      for _, k in ipairs(ks) do
        local v = m[k]
        if k == "pos" then v = v.x .. "," .. v.y .. "," .. v.z
        elseif k == "qids" then v = table.concat(v, ",")
        elseif k == "sells_for" then v = table.concat(v, "\n")
        elseif k == "stock" then
          local names = {}
          for j, st in ipairs(v) do names[j] = tostring(st.name) .. (st.locked and "!" or "") end
          v = table.concat(names, ",")
        end
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
      out[i] = table.concat(parts, ";")
    end
    return table.concat(out, "|")
  end
  local function panel_ser(p)
    local t = {}
    for _, cat in ipairs(core.WORLD_CATS) do
      t[#t + 1] = cat .. ":" .. p[cat].shown .. "/" .. p[cat].known .. ":" .. ser(p[cat].entries)
    end
    for _, k in ipairs(p.monster.kinds or {}) do
      t[#t + 1] = tostring(k.kind) .. ":" .. tostring(k.fam) .. ":" .. tostring(k.small) .. ":" .. tostring(k.shown) .. ":" .. tostring(k.known)
    end
    for _, f in ipairs(p.monster.families or {}) do
      t[#t + 1] = "F" .. tostring(f.fam) .. ":" .. tostring(f.small) .. ":" .. tostring(f.name) .. ":"
        .. tostring(f.shown) .. ":" .. tostring(f.known) .. ":" .. tostring(f.n_kinds)
    end
    return table.concat(t, "#")
  end
  local shops_exercised = { merged = false, offmap = false, sells = false, stock = false }
  local all_same, grid_ok, cull_ok = true, true, true
  for seed = 1, 20 do
    math.randomseed(seed)
    local rw = { chests = {}, treasure = {}, tokens = {}, beetles = {}, monsters = {}, sellers = {} }
    local function rp() return P(math.random() * 6000 - 3000, math.random() * 50, math.random() * 6000 - 3000) end
    for i = 1, 3600 do
      local r = math.random(1, 6)
      if r == 1 then rw.chests[#rw.chests + 1] = { uid = "c" .. i, pos = rp(),
        state = (math.random() < 0.2) and "opened" or "unopened" }
      elseif r == 2 then rw.treasure[#rw.treasure + 1] = { name = "T" .. i, pos = rp(),
        checked = false, discovered = math.random() < 0.8 }
      elseif r == 3 then rw.tokens[#rw.tokens + 1] = { uid = "k" .. i, pos = rp(), name = "K" .. i,
        state = (math.random() < 0.2) and "collected" or "not" }
      elseif r == 4 then rw.beetles[#rw.beetles + 1] = { uid = "b" .. i, pos = rp(), name = "B" .. i,
        state = "not" }
      elseif r == 5 then rw.monsters[#rw.monsters + 1] = { uid = "m" .. i, cid = i, name = "M" .. i,
        kind = "K" .. (i % 7), fam = "f" .. (i % 3), pos = rp(), small = math.random() < 0.3 }
      else rw.sellers[#rw.sellers + 1] = { shop = i, item = i, item_name = "I" .. i, cid = i,
        npc = "N", qids = {}, quest = "", pos = rp(), maybe_locked = false, discovered = true } end
    end
    -- a seller far from the origin, in quest_cids
    rw.sellers[#rw.sellers + 1] = { shop = 9999, item = 1, item_name = "Far", cid = 99999, npc = "N",
      qids = {}, quest = "", pos = P(2990, 0, 2990), maybe_locked = false, discovered = true }
    -- about 60 shops: a third share a seller's shop id, two sit at quest
    -- cids; half of those sellers carry a quest, some shops get a second seller
    local first_sellers = #rw.sellers
    rw.shops = {}
    for j = 1, 60 do
      local sid, cid = 100000 + j, 90000 + j
      if j <= 20 then
        local sl = rw.sellers[2 + (j - 1) * 3]
        sid, cid = sl.shop, sl.cid
        if j % 2 == 0 then sl.quest = "Q" .. j end
        if j % 3 == 0 then
          rw.sellers[#rw.sellers + 1] = { shop = sid, item = 70000 + j, item_name = "Extra" .. j,
            cid = cid, npc = "N", qids = {}, quest = "X" .. j, pos = rp(),
            maybe_locked = false, discovered = true }
        end
      end
      if j == 58 then cid = 99999 elseif j == 59 then cid = rw.sellers[1].cid end
      local items = {}
      local n_items = (j % 6 == 0 and j < 58) and 0 or (1 + j % 5)
      for k = 1, n_items do
        items[k] = { name = ((k + j) % 4 == 0) and "Potion" or ("I" .. (j * 10 + k)),
          locked = k % 2 == 0 }
      end
      rw.shops[#rw.shops + 1] = { shop = sid, cid = cid, npc = "S" .. j, pos = rp(),
        discovered = (j >= 58) or math.random() < 0.8, items = items }
    end
    local shop_count = 0
    for _, e in ipairs(rw.shops) do if #e.items > 0 then shop_count = shop_count + 1 end end
    local origin = P(-2900, 0, -2900)
    local boxes = { rw.chests[1] and rw.chests[1].pos }
    local qc = { [99999] = true, [rw.sellers[1].cid] = true }
    local small = (seed % 2 == 0)
    local s = sh({ world_small_monsters = small })
    local b0 = stats.grid_builds
    local m1, p1, g1 = core.world_markers(rw, s, origin, boxes, qc)
    local m2, p2, g2 = core.world_markers_cached(rw, s, origin, boxes, qc)
    if keys(m1) ~= keys(m2) or panel_sig(p1) ~= panel_sig(p2)
      or merged_sig(g1) ~= merged_sig(g2) then
      all_same = false
    end
    do   -- both paths agree under a kind off set
      local so = {}
      for k, v in pairs(s) do so[k] = v end
      so.world_monster_off = { large = { K3 = true }, small = { K5 = true, ["fam:f1"] = true } }
      local o1, q1 = core.world_markers(rw, so, origin, boxes, qc)
      local o2, q2 = core.world_markers_cached(rw, so, origin, boxes, qc)
      if ser(o1) ~= ser(o2) or panel_ser(q1) ~= panel_ser(q2) then all_same = false end
    end
    if #m1 ~= 300 or not merged_sig(g2):find("99999", 1, true) then all_same = false end
    -- warm call: the ring cull must stop early, well short of a full scan
    local cb0 = stats.cand_builds
    core.world_markers_cached(rw, s, origin, boxes, qc)
    local built = stats.cand_builds - cb0
    if built * 2 >= 3600 then cull_ok = false end
    -- off-diagonal origins agree with the uncached path
    for _, o2 in ipairs({ P(0, 0, 0), P(2500, 0, -1800), P(-1700, 0, 2600) }) do
      local a1 = core.world_markers(rw, s, o2, boxes, qc)
      local a2 = core.world_markers_cached(rw, s, o2, boxes, qc)
      if keys(a1) ~= keys(a2) then all_same = false end
    end
    -- small-monster setting flipped on the same world table
    for _, flag in ipairs({ not small, small }) do
      local sf = sh({ world_small_monsters = flag })
      local f1, fp1 = core.world_markers(rw, sf, origin, boxes, qc)
      local f2, fp2 = core.world_markers_cached(rw, sf, origin, boxes, qc)
      if keys(f1) ~= keys(f2) or panel_sig(fp1) ~= panel_sig(fp2) then all_same = false end
    end
    b0 = b0 + 2
    if stats.grid_builds ~= b0 + 1 then grid_ok = false end
    -- a different cap or toggle with the same world changes the result
    local s10 = sh({ world_max_markers = 10, world_small_monsters = small })
    local m3 = core.world_markers_cached(rw, s10, origin, boxes, qc)
    if #m3 ~= 10 or keys(m3) ~= keys((core.world_markers(rw, s10, origin, boxes, qc))) then
      all_same = false
    end
    local stk = sh({ world_tokens = false, world_small_monsters = small })
    local t1 = core.world_markers_cached(rw, stk, origin, boxes, qc)
    if keys(t1) ~= keys((core.world_markers(rw, stk, origin, boxes, qc))) or keys(t1) == keys(m2) then
      all_same = false
    end
    -- nil origin
    local n1 = core.world_markers(rw, s, nil, boxes, qc)
    local n2 = core.world_markers_cached(rw, s, nil, boxes, qc)
    if keys(n1) ~= keys(n2) then all_same = false end
    if stats.grid_builds ~= b0 + 1 then grid_ok = false end
    -- new world table rebuilds
    local copy = {}
    for kk, v in pairs(rw) do copy[kk] = v end
    core.world_markers_cached(copy, s, origin, boxes, qc)
    if stats.grid_builds ~= b0 + 2 then grid_ok = false end
    -- shops on/off x search on/off x origin/none: both paths agree on every
    -- marker field, every panel entry and the merged lines
    for _, qtext in ipairs({ false, "potion, s3, i12" }) do
      for _, son in ipairs({ true, false }) do
        for _, org in ipairs({ origin, false }) do
          local so = org or nil
          local ss = sh({ world_small_monsters = small, world_shops = son,
            search = qtext and core.parse_query(qtext) or nil })
          local x1, xp1, xg1 = core.world_markers(rw, ss, so, boxes, qc)
          local x2, xp2, xg2 = core.world_markers_cached(rw, ss, so, boxes, qc)
          if ser(x1) ~= ser(x2) or panel_ser(xp1) ~= panel_ser(xp2)
            or panel_sig(xp1) ~= panel_sig(xp2) or merged_sig(xg1) ~= merged_sig(xg2) then
            all_same = false
          end
          for _, e in ipairs(xp1.shop.entries) do
            if e.merged then shops_exercised.merged = true end
            if e.offmap then shops_exercised.offmap = true end
            if #e.sells_for > 0 then shops_exercised.sells = true end
            if #e.stock > 0 then shops_exercised.stock = true end
          end
          if not qtext and son and org then
            -- the shops-on bounds: cap reached, quest-cid merge, ring cull
            if #x1 ~= 300 or not merged_sig(xg2):find("99999", 1, true) then all_same = false end
            local cbs = stats.cand_builds
            core.world_markers_cached(rw, ss, so, boxes, qc)
            local built_on = stats.cand_builds - cbs
            if built_on < shop_count or (built_on - shop_count) * 2 >= 3600 then
              cull_ok = false
            end
          end
        end
      end
    end
    -- every toggle off: zero candidate builds
    local off = sh({ world_chests = false, world_treasure = false, world_tokens = false,
      world_beetles = false, world_monsters = false, world_sellers = false,
      world_shops = false, world_small_monsters = false })   -- Small is a toggle of its own (SPEC 28.12.3)
    local c0 = stats.cand_builds
    local mo, po, go = core.world_markers_cached(copy, off, origin, boxes, qc)
    local _, pe = core.world_markers(copy, off, origin, boxes, qc)
    if #mo ~= 0 or #go ~= 0 or stats.cand_builds ~= c0 or panel_sig(po) ~= panel_sig(pe) then
      all_same = false
    end
  end
  check("wd2 grid equivalent over 20 seeds", all_same)
  check("wd2 grid reuse and rebuild counts", grid_ok)
  check("wd2 ring cull stops early", cull_ok)
  check("wd2 shops: differential exercised merged, off-map, sells_for and stock",
    shops_exercised.merged and shops_exercised.offmap and shops_exercised.sells
    and shops_exercised.stock)
  local fc = core.world_markers_cached({ chests = { { uid = "c", pos = P(1), state = "unopened" },
    { uid = "d", pos = P(2), state = "unopened" } } }, sh({ world_max_markers = 1.5 }), O, {})
  check("wd2 fractional cap", #fc == 1)

  -- SPEC 20.12.11.1: map_origin_step
  do
    local st = core.map_origin_step
    local function same(a, b) return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.z == b.z end
    check("map_origin_step: constants", core.MAP_REORIGIN == 50 and core.MAP_HOLD == 0.5)
    do
      local okn, on = pcall(st, P(10, 5, 10), P(500, 0, 500), 10, 5.0, nil)
      check("map_origin_step: nil last_at with prev set does not raise", okn and on ~= nil and on.x == 500)
    end
    local prev = P(10, 5, 10)
    local o, la = st(prev, nil, 0, 100, 3)
    check("map_origin_step: nil cursor keeps prev", o == prev and la == 3)
    o, la = st(prev, P(0.5, 0, 0.5), 0, 100, 3)
    check("map_origin_step: unset reading keeps prev", o == prev and la == 3)
    o, la = st(prev, P(0 / 0, 0, 500), 0, 100, 3)
    check("map_origin_step: NaN x keeps prev", o == prev and la == 3)
    o, la = st(nil, P(500, 0, 500), 120, 100, 3)
    check("map_origin_step: y 0 takes player_y", o ~= nil and o.y == 120 and o.x == 500 and la == 100)
    o = st(nil, P(500, 0, 500), nil, 100, 3)
    check("map_origin_step: y 0 with player_y nil stays 0", o ~= nil and o.y == 0)
    o, la = st(P(500, 9, 500), P(500, 0, 500), 120, 100, 3)
    check("map_origin_step: x/z distance only, kept", same(o, P(500, 9, 500)) and la == 3)
    o, la = st(nil, P(500, 7, 500), 0, 10, 10)
    check("map_origin_step: prev nil taken despite hold", same(o, P(500, 7, 500)) and la == 10)
    o, la = st(P(0, 0, 0), P(49, 0, 0), 0, 100, 0)
    check("map_origin_step: 49 units kept", same(o, P(0, 0, 0)) and la == 0)
    o, la = st(P(0, 0, 0), P(50, 3, 0), 0, 10.4, 10.0)
    check("map_origin_step: 50 units inside hold kept", same(o, P(0, 0, 0)) and la == 10.0)
    o, la = st(P(0, 0, 0), P(50, 3, 0), 0, 10.5, 10.0)
    check("map_origin_step: 50 units after hold taken", same(o, P(50, 3, 0)) and la == 10.5)
  end

  -- SPEC 20.12.11.2: fullmap_world and fullmap_order's third argument
  do
    local function mkc(n)
      local rw = { chests = {} }
      for i = 1, n do
        rw.chests[i] = { uid = "f" .. i, pos = P(i * 100, 0, 0), state = "unopened" }
      end
      return rw
    end
    local rw = mkc(10)
    local function run(over)
      local s = sh({ startable = true, in_progress = true, world = rw,
        world_max_markers = 3, world_origin = P(0, 0, 0) })
      for k, v in pairs(over or {}) do s[k] = v end
      return core.compute(fake_adapter({}), s)
    end
    local ws = core.world_stats
    run()   -- warm the grid cache so both measured computes see the same state
    local g0, c0 = ws.grid_builds, ws.cand_builds
    local base = run()
    local g1, c1 = ws.grid_builds, ws.cand_builds
    local far = run({ map_origin = P(1000, 0, 0) })
    local g2, c2 = ws.grid_builds, ws.cand_builds
    check("fullmap_world: nil without map_origin", base.fullmap_world == nil)
    check("fullmap_world: markers and panel unchanged by map_origin",
      ser(base.markers) == ser(far.markers) and panel_ser(base.world) == panel_ser(far.world))
    check("fullmap_world: grid and candidate build deltas equal",
      g2 - g1 == g1 - g0 and c2 - c1 == c1 - c0)
    check("fullmap_world: markers near the player", keys(base.markers) == "w:chest:f1,w:chest:f2,w:chest:f3")
    check("fullmap_world: holds the world markers nearest map_origin",
      far.fullmap_world ~= nil and #far.fullmap_world == 3
      and keys(far.fullmap_world) == "w:chest:f10,w:chest:f9,w:chest:f8")
    local ra = run({ map_origin = P(1000, 0, 0) })
    local rb = run({ map_origin = P(100, 0, 0) })
    local function sig(r)
      local all = {}
      for _, m in ipairs(r.markers) do all[#all + 1] = m end
      for _, m in ipairs(r.fullmap_world) do all[#all + 1] = m end
      return (core.signature(all, {}))
    end
    check("fullmap_world: signature differs when only map_origin moves the set", sig(ra) ~= sig(rb))
    -- a quest marker, a shop and a seller sharing one cid, with and without a search:
    -- the second pass must leave markers and the quest hover (merge lines) untouched
    do
      local function runq(over)
        local rwq = { chests = rw.chests,
          shops = { { shop = 5, cid = 9001, npc = "Merchant Gil", pos = P(60), discovered = true,
            items = { { name = "Rope", locked = false } } } },
          sellers = { { shop = 5, item = 2, item_name = "Elixir", cid = 9001, npc = "Merchant Gil",
            qids = {}, quest = "Bandage Run", pos = P(61), maybe_locked = false, discovered = true } } }
        local s = sh({ startable = true, in_progress = true, world = rwq, world_shops = true,
          world_sellers = true, world_max_markers = 3, world_origin = P(0, 0, 0) })
        for k, v in pairs(over or {}) do s[k] = v end
        return core.compute(fake_adapter({ acceptable = { 20 }, names = { [20] = "Quest B" },
          hints = { [20] = 9001 }, npc_pos = { [9001] = P(50, 0, 50) },
          npc_names = { [9001] = "Merchant Gil" } }), s)
      end
      local function hover_of(r)
        for _, m in ipairs(r.markers) do if m.key == "c:9001" then return m.hover end end
      end
      local function count_for(s)
        local n = 0
        for _ in (s or ""):gmatch("%(for ") do n = n + 1 end
        return n
      end
      for _, srch in ipairs({ "none", "gil" }) do
        local q = srch == "gil" and core.parse_query("gil") or nil
        local b0 = runq({ search = q })
        local f0 = runq({ search = q, map_origin = P(1000, 0, 0) })
        check("fullmap_world merge [" .. srch .. "]: quest hover has the seller line",
          hover_of(b0) ~= nil and count_for(hover_of(b0)) == 1)
        check("fullmap_world merge [" .. srch .. "]: markers and quest hover unchanged",
          ser(b0.markers) == ser(f0.markers) and hover_of(b0) == hover_of(f0)
          and count_for(hover_of(f0)) == 1 and panel_ser(b0.world) == panel_ser(f0.world))
      end
    end
    local function mk(key, cat, pos) return { key = key, cat = cat, pos = pos } end
    local cw1 = core.WORLD_CATS[1]
    local q1 = mk("q1", "acceptable", P(900))
    local input = { mk("w:a", cw1, P(1)), q1, mk("w:b", cw1, P(2)) }
    local repl = { mk("w:z", cw1, P(300)), mk("w:y", cw1, P(5)) }
    check("fullmap_order: third argument with a valid origin",
      keys(core.fullmap_order(input, P(0, 0, 0), repl)) == "q1,w:y,w:z")
    check("fullmap_order: third argument with no origin keeps its own order",
      keys(core.fullmap_order(input, nil, repl)) == "q1,w:z,w:y")
  end
end

-- minimap_markers: the bounded selection equals a full sort, and valid_pos
-- rejects non-finite coordinates
do
  check("valid_pos rejects NaN", core.valid_pos({ x = 0 / 0, y = 0, z = 0 }) == false)
  check("valid_pos rejects inf", core.valid_pos({ x = 0, y = math.huge, z = 0 }) == false)
  check("valid_pos accepts numbers", core.valid_pos({ x = 1, y = -2, z = 3.5 }) == true)
  math.randomseed(20261021)
  local cats = { "startable", "chest", "monster", "quest_item", "token" }
  local same = true
  for trial = 1, 60 do
    local ms = {}
    for i = 1, math.random(0, 120) do
      ms[i] = { key = string.format("k%04d", i), cat = cats[math.random(#cats)],
        pos = { x = math.random(-30, 30), y = 0, z = math.random(-30, 30) } }
    end
    local cap = math.random(0, 14)
    local origin = { x = 0, y = 0, z = 0 }
    local got, gnear = core.minimap_markers(ms, origin, 25, cap)
    local world_cat = { treasure = true, token = true, beetle = true, seller = true,
      monster = true, chest = true }
    local inside, best = {}, nil
    for _, m in ipairs(ms) do
      local d2 = m.pos.x ^ 2 + m.pos.y ^ 2 + m.pos.z ^ 2
      if d2 <= 25 * 25 then
        inside[#inside + 1] = { m = m, d2 = d2, w = world_cat[m.cat] and 1 or 0 }
        if best == nil or d2 < best then best = d2 end
      end
    end
    table.sort(inside, function(a, b)
      if a.w ~= b.w then return a.w < b.w end
      if a.d2 ~= b.d2 then return a.d2 < b.d2 end
      return a.m.key < b.m.key
    end)
    local want = math.min(cap, #inside)
    if #got ~= want then same = false end
    for i = 1, want do if got[i] ~= inside[i].m then same = false end end
    if (gnear == nil) ~= (best == nil) or (best and gnear ~= math.sqrt(best)) then
      same = false
    end
  end
  check("minimap_markers: bounded selection equals the full sort", same)
end

-- ms: map search (v11, SPEC 19)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local function Q(t) return core.parse_query(t) end
  local function tset(q)
    local s = {}
    for _, t in ipairs(q.terms) do s[t] = true end
    return s
  end
  local function keyset(ms)
    local s = {}
    for _, m in ipairs(ms) do s[m.key] = m end
    return s
  end
  local function keylist(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    return table.concat(t, ",")
  end

  -- 1 parse and match
  check("ms parse: empty and commas only", Q("") == nil and Q(" , ") == nil)
  local q = Q("goblin, minotaur")
  check("ms parse: terms trimmed", q ~= nil and tset(q).goblin and tset(q).minotaur)
  check("ms match: plural", core.query_match(Q("minotaurs"), "minotaur"))
  check("ms match: empty terms dropped", not core.query_match(Q("a, ,b"), "x y"))
  check("ms match: comma OR", core.query_match(q, "a goblin") and core.query_match(q, "minotaur"))
  check("ms match: no pattern magic", not core.query_match(Q("a.b"), "axb")
    and core.query_match(Q("a.b"), "a.b"))
  check("ms match: plural needs more than 3 chars", not core.query_match(Q("bus"), "bu"))
  check("ms match: case folded term", core.query_match(Q("MINOTAUR"), "minotaur"))

  local SHW = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_max_markers = 300, world_origin = P(0, 0, 0),
    world_show_opened = false, world_undiscovered = false }
  local function run(o, world, search, over)
    local base = { acceptable = { 20 }, names = { [20] = "Quest B" },
      hints = { [20] = 9001 }, npc_pos = { [9001] = P(50, 0, 50) },
      npc_names = { [9001] = "Merchant Gil" } }
    for k, v in pairs(o or {}) do base[k] = v end
    local show = { startable = true, in_progress = true, quest_items = true,
      world = world, search = search }
    for k, v in pairs(SHW) do show[k] = v end
    for k, v in pairs(over or {}) do show[k] = v end
    return core.compute(fake_adapter(base), show)
  end

  -- 1 spaces after commas find both; case folded
  local mw = { monsters = {
    { uid = "g", cid = 1, name = "Goblin", pos = P(1) },
    { uid = "m", cid = 2, name = "Minotaur", pos = P(2) },
    { uid = "o", cid = 3, name = "Ogre", pos = P(3) } } }
  local r = run({ acceptable = {} }, mw, Q("goblin, minotaur"))
  local ks = keyset(r.markers)
  check("ms world: both comma terms found", ks["w:mon:g"] and ks["w:mon:m"] and not ks["w:mon:o"])
  r = run({ acceptable = {} }, mw, Q("MINOTAUR"))
  check("ms world: case-insensitive", keylist(r.markers) == "w:mon:m")

  -- 2 haystack join: parts do not combine across the newline
  local cw = { chests = { { uid = "1", pos = P(1), state = "unopened",
    items = { { name = "Ore" } } } } }
  r = run({ acceptable = {} }, cw, Q("store"))
  check("ms hay: chest + ore is not store", #r.markers == 0)
  r = run({ acceptable = {} }, cw, Q("ore"))
  check("ms hay: chest item found", #r.markers == 1)

  -- 3 fourth item matches
  cw = { chests = { { uid = "4", pos = P(1), state = "unopened",
    items = { { name = "A1" }, { name = "B2" }, { name = "C3" }, { name = "Zircon" } } } } }
  r = run({ acceptable = {} }, cw, Q("zircon"))
  check("ms hay: fourth chest item matches", #r.markers == 1
    and r.markers[1].label:find("Zircon", 1, true) == nil)

  -- 4 quest markers: npc name, giver hint, no npc_name, quest-item by quest name
  r = run(nil, nil, Q("merchant gil"))
  check("ms quest: matches by npc name", #r.markers == 1 and r.markers[1].key == "c:9001")
  r = run(nil, nil, Q("nobody"))
  check("ms quest: no match drops marker", #r.markers == 0)
  r = run({ hints = { [20] = 9002 }, npc_pos = {}, statics = { [20] = P(7, 0, 7) },
    npc_names = { [9002] = "Aldric" } }, nil, Q("aldric"))
  check("ms quest: giver hint when key is not c:", #r.markers == 1
    and r.markers[1].key:sub(1, 2) ~= "c:")
  local na = base_adapter({ acceptable_ids = function() return { 20 } end,
    giver_hint = function() return 9001 end,
    npc_pos = function() return 1, 2, 3 end })
  local rn = core.compute(na, { startable = true, in_progress = true, search = Q("q20") })
  check("ms quest: adapter without npc_name computes", rn ~= nil and #rn.markers == 1)
  r = run({ acceptable = {}, progressing = { 10 }, names = { [10] = "Rescue Mission" },
    item_needs = { [10] = { { id = 300, num = 1 } } },
    item_locs = { { id = 300, pos = P(7, 2, 3), live = P(7, 2, 3), src = "placed" } },
    item_names = { [300] = "Garb" } }, nil, Q("rescue"))
  local qi = 0
  for _, m in ipairs(r.markers) do if m.cat == "quest_item" then qi = qi + 1 end end
  check("ms item: matches by needing quest name", qi == 1)

  -- 5 filter across consumers
  local fw = { chests = { { uid = "k", pos = P(5), state = "unopened",
      items = { { name = "Ruby" } } },
    { uid = "n", pos = P(6), state = "unopened", items = { { name = "Pebble" } } } },
    sellers = { { shop = 1, item = 2, item_name = "Elixir", cid = 9001, npc = "Merchant Gil",
      qids = {}, quest = "", pos = P(60), maybe_locked = false, discovered = true } } }
  local fo = { acceptable = { 20 }, progressing = { 10 },
    names = { [10] = "Alpha", [20] = "Quest B" },
    item_needs = { [10] = { { id = 300, num = 1 } } },
    item_locs = { { id = 300, pos = P(7, 2, 3), live = P(7, 2, 3), src = "placed" } },
    item_names = { [300] = "Garb" } }
  local full = run(fo, fw, nil)
  local fk = keyset(full.markers)
  check("ms filter: control, seller merged into the quest hover", fk["c:9001"]
    and fk["c:9001"].hover and fk["c:9001"].hover:find("Elixir", 1, true)
    and not fk["w:sell:1:2"])
  local r = run(fo, fw, Q("ruby"))
  fk = keyset(r.markers)
  check("ms filter: only the matching chest remains", keylist(r.markers) == "w:chest:k")
  local mm = core.minimap_markers(r.markers, P(0, 0, 0), 1e9, 99)
  check("ms filter: minimap input filtered", #mm == 1 and mm[1].key == "w:chest:k")
  check("ms filter: panel shown counts matches, known unchanged",
    r.world.chest.shown == 1 and r.world.chest.known == 2)
  r = run(fo, fw, Q("alpha"))
  local anchors = core.overhead_anchors(r.markers, {}, P(0, 0, 0), 1e9)
  local pts = core.overhead_points(r.markers, P(0, 0, 0), 1e9)
  fk = keyset(r.markers)
  check("ms filter: item marker kept, quest and world gone", fk["c:9001"] == nil
    and #anchors == 0 and #pts == 1 and #r.markers == 1)
  r = run(fo, fw, Q("elixir"))
  fk = keyset(r.markers)
  check("ms filter: seller of a filtered quest marker draws alone", fk["w:sell:1:2"]
    and fk["c:9001"] == nil)

  -- quest haystack cache stays bounded
  local qs, statics, names = {}, {}, {}
  for i = 1, 2100 do qs[i] = 1000 + i; statics[1000 + i] = P(i); names[1000 + i] = "Q" .. i end
  core.compute(fake_adapter({ acceptable = qs, statics = statics, names = names }),
    { startable = true, search = Q("zzz") })
  check("ms cache: quest haystacks cleared past 2048",
    core.search_stats.quest_hay_n > 0 and core.search_stats.quest_hay_n < 2048)

  -- 6 cand_builds counts matches only
  local big = { chests = {} }
  for i = 1, 1000 do
    big.chests[i] = { uid = "b" .. i, pos = P(i * 3, 0, 0), state = "unopened",
      items = { { name = (i == 7 or i == 900) and "Moonstone" or ("Pebble" .. i) } } }
  end
  local before = core.world_stats.cand_builds
  r = run({ acceptable = {} }, big, Q("moonstone"))
  check("ms cand_builds: matches only", core.world_stats.cand_builds - before == 2
    and #r.markers == 2)

  -- 7 item cap counts matches only
  local needs, locs, inames = {}, {}, {}
  for i = 1, 40 do
    needs[#needs + 1] = { id = 500 + i, num = 1 }
    locs[#locs + 1] = { id = 500 + i, pos = P(i, 0, 0), src = "placed" }
    inames[500 + i] = (i == 3 and "Iron Ore") or (i == 30 and "Gold Ore") or ("Thing " .. i)
  end
  r = run({ acceptable = {}, progressing = { 10 }, names = { [10] = "Alpha" },
    item_needs = { [10] = needs }, item_locs = locs, item_names = inames }, nil, Q("ore"))
  local n_items = 0
  for _, m in ipairs(r.markers) do if m.cat == "quest_item" then n_items = n_items + 1 end end
  check("ms item cap: 2 matches of 40 drawn, not capped", n_items == 2 and r.item_capped == 0)

  -- 8 empty query identical to none
  local a1 = run(fo, fw, nil)
  local a2 = run(fo, fw, Q(""))
  local same = #a1.markers == #a2.markers
  for i = 1, #a1.markers do
    local x, y = a1.markers[i], a2.markers[i]
    if x.key ~= y.key or x.label ~= y.label or x.hover ~= y.hover then same = false end
  end
  check("ms empty query: identical output", same and #a1.markers > 0)

  -- 9 shops
  check("ms shop: shop seventh, npc_search last", #core.WORLD_CATS == 8 and core.WORLD_CATS[7] == "shop"
    and core.WORLD_CATS[8] == "npc_search")
  local function shop(id, npc, items, extra)
    local s = { shop = id, cid = 9500 + id, npc = npc, pos = P(10 + id), discovered = true,
      items = items }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end
  local function it(n, l) return { name = n, locked = l == true } end
  local gil = shop(5, "Merchant Gil", { it("Healing Potion"), it("Antidote"), it("Rope"), it("Torch") })
  local sw = { shops = { gil } }
  r = run({ acceptable = {} }, sw, Q("gil"))
  fk = keyset(r.markers)
  check("ms shop: npc match lists first three", fk["w:shop:5"]
    and fk["w:shop:5"].label == "Merchant Gil sells Healing Potion, Antidote, Rope (+1)"
    and fk["w:shop:5"].cat == "shop")
  r = run({ acceptable = {} }, sw, Q("antidote"))
  fk = keyset(r.markers)
  check("ms shop: item match lists matching items only",
    fk["w:shop:5"] and fk["w:shop:5"].label == "Merchant Gil sells Antidote")
  r = run({ acceptable = {} }, { shops = { shop(6, "Locky", { it("A1", true), it("B2", true) }) } },
    Q("locky"))
  check("ms shop: all locked suffix", r.markers[1]
    and r.markers[1].label == "Locky sells A1, B2 (may be locked)")
  r = run({ acceptable = {} }, { shops = { shop(6, "Locky", { it("A1", true), it("B2") }) } },
    Q("locky"))
  check("ms shop: mixed lock has no suffix", r.markers[1]
    and r.markers[1].label == "Locky sells A1, B2")
  local function lk4(a, b, c, d)
    return { shops = { shop(8, "Fourway", { it("A1", a), it("B2", b), it("C3", c), it("D4", d) }) } }
  end
  r = run({ acceptable = {} }, lk4(true, true, true, false), Q("fourway"))
  check("ms shop: fourth item unlocked, no suffix", r.markers[1]
    and r.markers[1].label == "Fourway sells A1, B2, C3 (+1)")
  r = run({ acceptable = {} }, lk4(true, true, true, true), Q("fourway"))
  check("ms shop: all four locked, suffix", r.markers[1]
    and r.markers[1].label == "Fourway sells A1, B2, C3 (+1) (may be locked)")
  r = run({ acceptable = {} }, sw, Q("nomatch"))
  check("ms shop: no match no marker", #r.markers == 0)
  r = run({ acceptable = {} }, { shops = { shop(7, "Hidden", { it("Gem") }, { discovered = false }) } },
    Q("gem"))
  check("ms shop: undiscovered hidden", #r.markers == 0)
  r = run({ acceptable = {} }, { shops = { shop(7, "Hidden", { it("Gem") }, { discovered = false }) } },
    Q("gem"), { world_undiscovered = true })
  check("ms shop: undiscovered shown when on", #r.markers == 1)

  -- shop at a quest marker's cid merges into its hover
  local qs1 = { shops = { shop(5, "Merchant Gil", { it("Rope") }, { cid = 9001 }) } }
  r = run(nil, qs1, Q("gil"))
  fk = keyset(r.markers)
  check("ms shop: merges into the quest marker hover", fk["c:9001"] and fk["w:shop:5"] == nil
    and fk["c:9001"].hover and fk["c:9001"].hover:find("sells Rope", 1, true))

  -- seller dedupe into the shop marker
  local seller = { shop = 5, item = 2, item_name = "Antidote", cid = 9505, npc = "Merchant Gil",
    qids = {}, quest = "Bandage Run", pos = P(15), maybe_locked = false, discovered = true }
  local dw = { shops = { gil }, sellers = { seller } }
  r = run({ acceptable = {} }, dw, Q("antidote"))
  fk = keyset(r.markers)
  check("ms shop: seller not drawn, its quest text on the shop hover",
    fk["w:shop:5"] and fk["w:sell:5:2"] == nil and fk["w:shop:5"].hover
    and fk["w:shop:5"].hover:find("(for Bandage Run)", 1, true)
    and fk["w:shop:5"].hover:find("Antidote (for Bandage Run)", 1, true)
    and not fk["w:shop:5"].hover:find("sold by", 1, true))

  -- a shop standing in for the nearest seller takes its place in the cap
  local capw = { chests = { { uid = "c1", pos = P(100), state = "unopened",
      items = { { name = "Antidote" } } },
    { uid = "c2", pos = P(200), state = "unopened", items = { { name = "Antidote" } } } },
    sellers = { { shop = 5, item = 2, item_name = "Antidote", cid = 9505,
      npc = "Merchant Gil", qids = {}, quest = "", pos = P(5), maybe_locked = false,
      discovered = true } } }
  capw.shops = { shop(5, "Merchant Gil", { it("Antidote") }, { pos = P(5) }) }
  r = run({ acceptable = {} }, capw, Q("antidote"), { world_max_markers = 2 })
  check("ms cap: shop replaces the nearest seller in the cap",
    keylist(r.markers):find("w:shop:5", 1, true) and not keyset(r.markers)["w:sell:5:2"]
    and keyset(r.markers)["w:chest:c1"] and #r.markers == 2)

  -- no origin: a shop standing in for its seller ranks as the seller
  local noo = { chests = { { uid = "c1", pos = P(100), state = "unopened",
      items = { { name = "Arrow" } } },
    { uid = "c2", pos = P(200), state = "unopened", items = { { name = "Arrow" } } } },
    shops = { shop(7, "Fletcher", { it("Arrow Bundle") }) },
    sellers = { { shop = 7, item = 99, item_name = "Arrow Bundle", cid = 9507, npc = "Fletcher",
      qids = {}, quest = "", pos = P(17), maybe_locked = false, discovered = true } } }
  r = run({ acceptable = {} }, noo, Q("arrow"), { world_max_markers = 2, world_origin = false })
  check("ms cap: no origin, promoted shop keeps its seller's rank",
    keyset(r.markers)["w:shop:7"] and #r.markers == 2)

  -- an npc name that resolves later is searchable on a later tick
  local late = false
  local lad = base_adapter({ acceptable_ids = function() return { 20 } end,
    giver_hint = function() return 9001 end, npc_pos = function() return 1, 2, 3 end,
    npc_name = function() return late and "Merchant Gil" or nil end })
  local lshow = { startable = true, in_progress = true, search = Q("gil") }
  local l1 = core.compute(lad, lshow)
  late = true
  local l2 = core.compute(lad, lshow)
  check("ms quest: npc name resolving later is found", #l1.markers == 0 and #l2.markers == 1)

  -- both merge into one quest marker: shop line only
  local both = { shops = { shop(5, "Merchant Gil", { it("Antidote") }, { cid = 9001 }) },
    sellers = { { shop = 5, item = 2, item_name = "Antidote", cid = 9001, npc = "Merchant Gil",
      qids = {}, quest = "", pos = P(15), maybe_locked = false, discovered = true } } }
  r = run(nil, both, Q("gil, antidote"))
  fk = keyset(r.markers)
  check("ms shop: quest hover gains only the shop line", fk["c:9001"] and fk["c:9001"].hover
    and fk["c:9001"].hover:find("sells Antidote", 1, true)
    and not fk["c:9001"].hover:find("sold by", 1, true))

  -- 10 shared cap
  local cs = { chests = { { uid = "c1", pos = P(5), state = "unopened" },
      { uid = "c2", pos = P(6), state = "unopened" } },
    shops = { shop(1, "Chester", { it("Rope") }) } }
  r = run({ acceptable = {} }, cs, Q("chest"), { world_max_markers = 2 })
  check("ms cap: chests keep the slots", keylist(r.markers) == "w:chest:c1,w:chest:c2")
  r = run({ acceptable = {} }, cs, Q("chest"), { world_max_markers = 3 })
  fk = keyset(r.markers)
  check("ms cap: shop fills the remaining slot", fk["w:shop:1"] and #r.markers == 3
    and type(fk["w:shop:1"].world_ord) == "number"
    and fk["w:shop:1"].world_ord ~= fk["w:chest:c1"].world_ord
    and fk["w:shop:1"].world_ord ~= fk["w:chest:c2"].world_ord)
  local dd = { chests = { { uid = "cx", pos = P(300), state = "unopened",
      items = { { name = "Antidote" } } } },
    shops = { gil }, sellers = { seller } }
  r = run({ acceptable = {} }, dd, Q("antidote"), { world_max_markers = 2 })
  fk = keyset(r.markers)
  check("ms cap: deduped seller frees its slot", fk["w:shop:5"] and fk["w:chest:cx"]
    and fk["w:sell:5:2"] == nil)
  local alloff = { world_chests = false, world_treasure = false, world_monsters = false,
    world_sellers = false, world_tokens = false, world_beetles = false }
  r = run({ acceptable = {} }, sw, Q("gil"), alloff)
  check("ms shop: draws with every world toggle off", #r.markers == 1
    and r.markers[1].key == "w:shop:5")
  check("ms shop: panel known is a number", type(r.world.shop.known) == "number"
    and r.world.shop.known == 1 and r.world.shop.shown == 1)
  r = run({ acceptable = {} }, sw, nil)
  check("ms shop: none without a search", #r.markers == 0
    and type(r.world.shop.known) == "number" and r.world.shop.known == 0)

  -- 11 clearing restores everything on the next call
  r = run(fo, fw, Q("ruby"))
  local r2 = run(fo, fw, nil)
  check("ms clear: all markers return", #r2.markers == #full.markers and #r.markers < #r2.markers)
end

-- shops toggle: shops without a search (SPEC 20)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local Q = core.parse_query
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SHB) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local function shop(id, npc, items, extra)
    local s = { shop = id, cid = 9500 + id, npc = npc, pos = P(10 + id),
      discovered = true, items = items }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end
  local function it(n, l) return { name = n, locked = l == true } end
  local function seller(shop_id, item, name, quest, extra)
    local s = { shop = shop_id, item = item, item_name = name, cid = 9700 + shop_id,
      npc = "N", qids = {}, quest = quest or "", pos = P(30 + item), maybe_locked = false,
      discovered = true }
    for k, v in pairs(extra or {}) do s[k] = v end
    return s
  end
  -- runs fn(path_name, markers, panel, merged) through both entry points
  local function each(world, over, origin, qc, fn)
    local s = sh(over)
    fn("uncached", core.world_markers(world, s, origin, {}, qc))
    fn("cached", core.world_markers_cached(world, s, origin, {}, qc))
  end
  local function chk(name, path, cond) check(name .. " [" .. path .. "]", cond) end
  local function keyset(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end
  local function ends(s, suffix) return s:sub(-#suffix) == suffix end
  local ON = { world_shops = true }

  -- 1 every shop as <npc> (shop)
  local w1 = { shops = { shop(1, "Gil", { it("Antidote") }), shop(2, "Roderick", { it("Rope") }) } }
  each(w1, ON, O, nil, function(path, m, p)
    local k = keyset(m)
    chk("shops on: every shop as <npc> (shop)", path, #m == 2 and k["w:shop:1"]
      and k["w:shop:2"] and k["w:shop:1"].label == "Gil (shop)"
      and k["w:shop:2"].label == "Roderick (shop)" and k["w:shop:1"].why == nil
      and k["w:shop:2"].why == nil and p.shop.known == 2 and p.shop.shown == 2)
  end)

  -- 2 shops off: no shop work
  local acc = 0
  local hid = { shop(1, "Gil", { it("Rope") }), shop(2, "Ann", { it("Gem") }) }
  local proxy = setmetatable({}, {
    __index = function(_, k) acc = acc + 1; return hid[k] end,
    __len = function() acc = acc + 1; return #hid end })
  local base = { chests = { { uid = "c", pos = P(5), state = "unopened" } } }
  local withp = { chests = base.chests, shops = proxy }
  local cb0 = core.world_stats.cand_builds
  core.world_markers_cached(base, sh(), O, {})
  local built_base = core.world_stats.cand_builds - cb0
  cb0 = core.world_stats.cand_builds
  each(withp, nil, O, nil, function(path, m, p)
    chk("shops off: no shop work", path, #m == 1 and #p.shop.entries == 0
      and p.shop.known == 0 and acc == 0)
  end)
  check("shops off: cached cand_builds match the world without shops",
    core.world_stats.cand_builds - cb0 == built_base)
  each(withp, { world_shops = false }, O, nil, function(path, m)
    chk("shops explicitly false: no shop work", path, #m == 1 and acc == 0)
  end)

  -- 3 caps
  local w3 = { chests = { { uid = "c", pos = P(500), state = "unopened" } },
    shops = { shop(1, "Gil", { it("Rope") }) } }
  each(w3, { world_shops = true, world_max_markers = 1 }, O, nil, function(path, m)
    chk("near shop beats far chest at cap 1", path, #m == 1 and m[1].key == "w:shop:1")
  end)
  each(w3, { world_shops = true, world_max_markers = 1 }, nil, nil, function(path, m)
    chk("no origin: chest beats a plain shop at cap 1", path, #m == 1 and m[1].key == "w:chest:c")
  end)
  local w3s = { chests = w3.chests, shops = w3.shops,
    sellers = { seller(1, 2, "Rope", "") } }
  each(w3s, { world_shops = true, world_max_markers = 1 }, nil, nil, function(path, m)
    chk("no origin: seller-standing shop ranks as seller", path,
      #m == 1 and m[1].key == "w:shop:1")
  end)

  -- 4 undiscovered
  local w4 = { shops = { shop(1, "Gil", { it("Rope") }, { discovered = false }) } }
  each(w4, ON, O, nil, function(path, m, p)
    chk("undiscovered shop hidden", path, #m == 0 and p.shop.known == 1)
    chk("undiscovered shop has no off-map row", path, #p.shop.entries == 0)
  end)
  each(w4, { world_shops = true, world_undiscovered = true }, O, nil, function(path, m)
    chk("undiscovered shop draws when asked", path, #m == 1)
  end)

  -- 5 seller line
  local w5 = { shops = { shop(1, "Gil", { it("Antidote") }) },
    sellers = { seller(1, 2, "Antidote", "Bandage Run") } }
  each(w5, ON, O, nil, function(path, m, p)
    local k = keyset(m)
    chk("seller line in sells_for and hover", path, #m == 1 and k["w:shop:1"]
      and k["w:shop:1"].sells_for[1] == "Antidote (for Bandage Run)"
      and k["w:shop:1"].hover == "Gil (shop)\nAntidote (for Bandage Run)"
      and k["w:sell:1:2"] == nil and #p.seller.entries == 0)
  end)

  -- 6 quest-giver keeps the seller line
  local w6 = { shops = { shop(1, "Gil", { it("Antidote") }, { cid = 9001 }) },
    sellers = { seller(1, 2, "Antidote", "Bandage Run") } }
  each(w6, ON, O, { [9001] = true }, function(path, m, p, g)
    local e = p.shop.entries[1]
    local rows = core.world_rows(p.shop.entries, { { name = "Vernworth", pos = P(0) } }, O)
    chk("quest-giver keeps seller line", path, #g == 1 and g[1].cid == 9001
      and g[1].line:find("(for Bandage Run)", 1, true) ~= nil
      and g[1].line == "Gil (shop)\nAntidote (for Bandage Run)"
      and #p.shop.entries == 1 and e.merged == true and e.offmap == nil
      and #m == 0 and p.shop.shown == 0 and rows[1].merged == true
      and ends(rows[1].text, " - quest marker") and rows[1].sells_for[1] == "Antidote (for Bandage Run)")
  end)

  -- 7 sells_for order independent
  local w7 = { shops = { shop(1, "Gil", { it("Antidote"), it("Bandage") }, { cid = 9001 }),
      shop(2, "Ann", { it("Gem") }) },
    sellers = { seller(1, 2, "Antidote", "Bandage Run"), seller(1, 3, "Bandage", "Mend Up"),
      seller(2, 4, "Gem", "Shine"), seller(2, 5, "Gem2", "Polish") } }
  local lines, hovers = {}, {}
  each(w7, ON, O, { [9001] = true }, function(path, m, p, g)
    lines[path] = g[1] and g[1].line
    hovers[path] = m[1] and m[1].hover
  end)
  check("sells_for order independent: merged line", lines.uncached ~= nil
    and lines.uncached == lines.cached
    and lines.uncached:find("Mend Up", 1, true) ~= nil)
  check("sells_for order independent: hover", hovers.uncached ~= nil
    and hovers.uncached == hovers.cached
    and hovers.uncached:find("Polish", 1, true) ~= nil)

  -- 8 stock
  local items8 = { it("Healing Potion"), it("Antidote", true), it("Rope"), it("Torch") }
  local w8 = { shops = { shop(1, "Gil", items8) } }
  each(w8, ON, O, nil, function(path, m, p)
    local rows = core.world_rows(p.shop.entries, {}, O)
    chk("stock on marker, entry and row", path, m[1].stock == items8
      and p.shop.entries[1].stock == items8 and rows[1].stock == items8
      and m[1].stock[2].locked == true and #m[1].sells_for == 0
      and rows[1].sells_for == p.shop.entries[1].sells_for)
  end)
  each(w8, { world_shops = true, search = Q("antidote") }, O, nil, function(path, m, p)
    chk("stock is the full list under a search", path, #m == 1
      and m[1].label == "Gil sells Antidote (may be locked)" and m[1].stock == items8 and #m[1].stock == 4)
  end)

  -- 9 world_rows limit
  local es = {}
  for i = 1, 12 do es[i] = { key = "w:chest:" .. i, label = "Chest", pos = P(i) } end
  check("world_rows limit: default ten", #core.world_rows(es, {}, O) == 10
    and #core.world_rows(es, {}, O, nil) == 10)
  check("world_rows limit: huge lists all", #core.world_rows(es, {}, O, math.huge) == 12
    and #core.world_rows(es, {}, O, 3) == 3)

  -- 10 search keeps the 19.7.3 label with shops on
  local w10 = { shops = { shop(1, "Gil", { it("Antidote") }), shop(2, "Roderick", { it("Rope") }) } }
  each(w10, { world_shops = true, search = Q("antidote") }, O, nil, function(path, m, p)
    local k = keyset(m)
    chk("search keeps 19.7.3 label with shops on", path, #m == 1
      and k["w:shop:1"].label == "Gil sells Antidote" and k["w:shop:2"] == nil
      and p.shop.known == 2)
  end)

  -- 11 label follows search on the same input table
  local lab = {}
  local qa = Q("antidote")
  for i, q in ipairs({ qa, false, qa }) do
    local m = core.world_markers_cached(w10, sh({ world_shops = true, search = q or nil }), O, {})
    local k = keyset(m)
    lab[i] = (k["w:shop:1"] and k["w:shop:1"].label or "?") .. "|"
      .. (k["w:shop:2"] and k["w:shop:2"].label or "-")
  end
  check("label follows search on same input", lab[1] == "Gil sells Antidote|-"
    and lab[2] == "Gil (shop)|Roderick (shop)" and lab[3] == lab[1])

  -- 12 empty or posless shop skipped
  local w12 = { shops = { shop(1, "Empty", {}), shop(2, "Nowhere", { it("x") }, { pos = false }),
    shop(3, "Nan", { it("x") }, { pos = P(0 / 0, 0, 0) }), shop(4, "Ok", { it("x") }) } }
  each(w12, ON, O, nil, function(path, m, p)
    chk("empty or posless shop skipped", path, #m == 1 and m[1].key == "w:shop:4"
      and #p.shop.entries == 1 and p.shop.known == 4)
  end)
  each(w12, { world_shops = true, world_max_markers = 0 }, O, nil, function(path, m, p)
    chk("empty or posless shop has no off-map row", path, #m == 0 and #p.shop.entries == 1)
  end)

  -- 13 cap 0
  local w13 = { shops = { shop(1, "Gil", { it("Rope") }), shop(2, "Ann", { it("Gem") }, { cid = 9001 }),
    shop(3, "Bo", { it("Pin") }) } }
  each(w13, { world_shops = true, world_max_markers = 0 }, O, { [9001] = true }, function(path, m, p)
    local rows = core.world_rows(p.shop.entries, {}, O, math.huge)
    local by = {}
    for _, r in ipairs(rows) do by[r.key] = r end
    chk("cap 0 all off-map", path, #m == 0 and p.shop.shown == 0 and #p.shop.entries == 3
      and by["w:shop:1"].offmap == true and ends(by["w:shop:1"].text, " (not on map)")
      and by["w:shop:3"].offmap == true and ends(by["w:shop:3"].text, " (not on map)")
      and by["w:shop:2"].merged == true and by["w:shop:2"].offmap == nil
      and ends(by["w:shop:2"].text, " - quest marker"))
    chk("cap 0 entry order: merged before off-map", path,
      p.shop.entries[1].key == "w:shop:2" and p.shop.entries[2].key == "w:shop:1"
      and p.shop.entries[3].key == "w:shop:3")
  end)

  -- 14 search with the toggle off
  local w14 = { shops = { shop(1, "Gil", { it("Antidote") }),
    shop(2, "Ann", { it("Antidote") }, { cid = 9001 }) } }
  each(w14, { search = Q("antidote"), world_max_markers = 0 }, O, { [9001] = true },
    function(path, m, p)
      local n2, e2 = 0, nil
      for _, e in ipairs(p.shop.entries) do
        if e.key == "w:shop:2" then n2 = n2 + 1; e2 = e end
      end
      chk("search, toggle off: merged and off-map entries", path, #m == 0
        and #p.shop.entries == 2 and n2 == 1 and e2.merged == true and e2.offmap == nil
        and p.shop.entries[2].offmap == true and p.shop.entries[2].key == "w:shop:1")
    end)

  -- 15 sellers node
  local w15 = { shops = { shop(1, "Gil", { it("Rope") }) },
    sellers = { seller(1, 2, "Rope", ""), seller(99, 3, "Gem", "") } }
  each(w15, ON, O, nil, function(path, m, p)
    chk("sellers node with shops on", path, #p.seller.entries == 1
      and p.seller.entries[1].key == "w:sell:99:3")
  end)
end

-- drops: monsters match by their drops (SPEC 19.12)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local SH = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_show_opened = false, world_undiscovered = false,
    world_max_markers = 300 }
  local function sh(q, over)
    local s = { search = q and core.parse_query(q) or nil }
    for k, v in pairs(SH) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local O = P(0, 0, 0)
  local function ogre(drops, extra)
    local m = { uid = "m1", cid = 5, name = "Ogre", pos = P(4), respawning = false }
    for k, v in pairs(extra or {}) do m[k] = v end
    return { monsters = { m }, drops = drops }
  end
  local H = { [5] = { "Minotaur Horn", "Beast-Steak" } }

  local ms = core.world_markers(ogre(H), sh("horn"), O, {})
  check("drops: horn matches through a drop", #ms == 1 and ms[1].cat == "monster")
  ms = core.world_markers(ogre(H), sh("horn"), O, {})
  check("drops: hover is label then Drops line",
    ms[1].hover == "Ogre\nDrops Minotaur Horn" and ms[1].why == "drops Minotaur Horn")
  local five = { [5] = { "Horn A", "Horn B", "Horn C", "Horn D", "Horn E" } }
  ms = core.world_markers(ogre(five), sh("horn"), O, {})
  check("drops: three names and (+2)",
    ms[1].hover == "Ogre\nDrops Horn A, Horn B, Horn C (+2)"
    and ms[1].why == "drops Horn A, Horn B, Horn C (+2)")
  ms = core.world_markers(ogre(H), sh("ogre, horn"), O, {})
  check("drops: label and drop match both set the hover",
    #ms == 1 and ms[1].hover == "Ogre\nDrops Minotaur Horn")
  ms = core.world_markers(ogre(H), sh("ogre"), O, {})
  check("drops: label-only match sets no hover",
    #ms == 1 and ms[1].hover == nil and ms[1].why == nil)

  local w = ogre(H)
  ms = core.world_markers_cached(w, sh("horn"), O, {})
  local first = ms[1] and ms[1].hover
  ms = core.world_markers_cached(w, sh("steak"), O, {})
  check("drops: hover follows the query on the same input table",
    first == "Ogre\nDrops Minotaur Horn" and #ms == 1
    and ms[1].hover == "Ogre\nDrops Beast-Steak")

  local cl = { monsters = { { uid = "g", cid = 1, cids = { 1, 2 }, name = "Goblin",
    pos = P(3), respawning = false } },
    drops = { [1] = { "Goblin Horn" }, [2] = { "Goblin Horn", "Fang" } } }
  ms = core.world_markers(cl, sh("goblin horn, fang"), O, {})
  check("drops: cluster matches a non-seed drop, names once",
    #ms == 1 and ms[1].hover == "Goblin\nDrops Goblin Horn, Fang")
  ms = core.world_markers_cached(cl, sh("fang"), O, {})
  check("drops: cluster non-seed drop through the cache",
    #ms == 1 and ms[1].hover == "Goblin\nDrops Fang")

  local mixed = { monsters = {
      { uid = "a", cid = 5, name = "Ogre", pos = P(2), respawning = true },
      { uid = "b", cid = 6, name = "Troll", pos = P(3), respawning = false } },
    drops = { [5] = { "Horn A", "Steak" }, [6] = { "Horn B" } } }
  local a = core.world_markers(mixed, sh("horn, steak"), O, {})
  local b = core.world_markers_cached(mixed, sh("horn, steak"), O, {})
  local function ser(ms)
    local out = {}
    for i, m in ipairs(ms) do
      local ks = {}
      for k in pairs(m) do ks[#ks + 1] = k end
      table.sort(ks)
      local parts = {}
      for _, k in ipairs(ks) do
        local v = m[k]
        if k == "pos" then v = v.x .. "," .. v.y .. "," .. v.z
        elseif k == "qids" then v = table.concat(v, ",") end
        parts[#parts + 1] = k .. "=" .. tostring(v)
      end
      out[i] = table.concat(parts, ";")
    end
    return table.concat(out, "|")
  end
  check("drops: cached and uncached paths agree",
    #a == 2 and #b == 2 and ser(a) == ser(b) and ser(a) ~= ""
    and a[1].hover == "Ogre (respawning)\nDrops Horn A, Steak")

  local capw = { monsters = { { uid = "m", cid = 5, name = "Ogre", pos = P(1),
      respawning = false } },
    chests = { { uid = "c", pos = P(500), state = "unopened",
      items = { { name = "Horn Charm" } } } },
    drops = { [5] = { "Horn A" } } }
  local ms2, panel = core.world_markers(capw, sh("horn", { world_max_markers = 1 }), O, {})
  check("drops: counts in the cap and in shown",
    #ms2 == 1 and ms2[1].cat == "monster" and panel.monster.shown == 1
    and panel.chest.shown == 0)
  local _, panel_u = core.world_markers(capw, sh("horn"), O, {})
  check("drops: the chest shows without the cap", panel_u.chest.shown == 1
    and panel_u.monster.shown == 1)

  ms = core.world_markers(ogre(nil), sh("horn"), O, {})
  local ms_b = core.world_markers(ogre(nil), sh("ogre"), O, {})
  check("drops: no drops table matches by label only",
    #ms == 0 and #ms_b == 1 and ms_b[1].hover == nil)

  ms = core.world_markers(ogre({ [5] = { "Minotaur Horn" } }), sh("horns"), O, {})
  check("drops: plural matches and lists the singular name",
    #ms == 1 and ms[1].hover == "Ogre\nDrops Minotaur Horn")
  local okg, msg = pcall(core.world_markers, ogre({ [5] = { "1 G" } }), sh("g"), O, {})
  check("drops: short term lists 1 G without error",
    okg and #msg == 1 and msg[1].hover == "Ogre\nDrops 1 G")

  local none = core.world_markers(ogre(H), sh(nil), O, {})
  local none2 = core.world_markers(ogre(nil), sh(nil), O, {})
  local nonec = core.world_markers_cached(ogre(H), sh(nil), O, {})
  local idw = { monsters = {
      { uid = "a", cid = 5, name = "Ogre", pos = P(2), respawning = true },
      { uid = "b", cid = 6, cids = { 6, 7 }, name = "Troll", pos = P(3), respawning = false } },
    chests = { { uid = "c", pos = P(5), state = "unopened", item_name = "Horn Charm" } } }
  local idd = { monsters = idw.monsters, chests = idw.chests,
    drops = { [5] = { "Horn A" }, [6] = { "Horn B" }, [7] = { "Fang" } } }
  check("drops: no search, markers identical with and without drops",
    ser(core.world_markers(idd, sh(nil), O, {})) == ser(core.world_markers(idw, sh(nil), O, {}))
    and ser(core.world_markers_cached(idd, sh(nil), O, {}))
      == ser(core.world_markers_cached(idw, sh(nil), O, {}))
    and ser(core.world_markers(idd, sh(nil), O, {})) ~= "")
  check("drops: no search ignores drops",
    #none == 1 and none[1].hover == nil and none[1].why == nil
    and none[1].key == none2[1].key and nonec[1].hover == nil and nonec[1].why == nil)

  local reads = 0
  local pw = { monsters = {}, drops = setmetatable({}, { __index = function() reads = reads + 1 end }) }
  for i = 1, 20 do
    pw.monsters[i] = { uid = "p" .. i, cid = 100 + i, name = "Imp", pos = P(i), respawning = false }
  end
  core.world_markers_cached(pw, sh("horn"), O, {})
  local first_reads = reads
  reads = 0
  core.world_markers_cached(pw, sh("horn"), O, {})
  check("drops: drop-less monsters read drops once, then never",
    first_reads == 20 and reads == 0)

  local rows = core.world_rows({
    { key = "w:mon:m1", label = "Ogre", why = "drops Minotaur Horn", pos = P(1) },
    { key = "w:mon:m2", label = "Troll", pos = P(2) } },
    { { name = "Vernworth", pos = P(0) } }, O)
  check("rows: why shown", rows[1].text == "Ogre - drops Minotaur Horn - near Vernworth"
    and rows[2].text == "Troll - near Vernworth")
end

do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local function mk(key, cat, pos) return { key = key, cat = cat, pos = pos } end
  local function keys(a)
    local out = {}
    for i, m in ipairs(a) do out[i] = m.key end
    return table.concat(out, ",")
  end
  local O = P(0, 0, 0)
  local cw = core.WORLD_CATS[1]
  local chest = mk("w:chest", cw, P(100))
  local shop = mk("w:shop", "shop", P(5))
  local q1, q2 = mk("q1", "acceptable", P(900)), mk("q2", "progressing", P(-900))
  local input = { chest, q1, shop, q2 }
  local out = core.fullmap_order(input, O)
  check("fullmap_order: quest first", keys(out) == "q1,q2,w:shop,w:chest")
  local tie = core.fullmap_order({ mk("w:b", cw, P(7)), mk("w:a", cw, P(-7)) }, O)
  check("fullmap_order: nearest world first, ties by key", keys(tie) == "w:a,w:b")
  check("fullmap_order: no origin keeps order", keys(core.fullmap_order(input, nil)) == "w:chest,q1,w:shop,q2")
  check("fullmap_order: input not mutated",
    keys(input) == "w:chest,q1,w:shop,q2" and out ~= input
    and out[3] == shop and out[4] == chest and out[1] == q1)
end

-- st: v13 step numbers for in-progress quests (SPEC 21.8)
do
  local function mk(prog, steps, reads)
    local a = fake_adapter({ acceptable = {}, progressing = prog, catalog = prog,
      statics = (function() local t = {} for i, q in ipairs(prog) do t[q] = { x = i * 100, y = 0, z = 0 } end return t end)() })
    a.quest_step = function(q) reads[#reads + 1] = q; return steps[q] end
    return a
  end
  local function find(r, q)
    for _, m in ipairs(r.markers) do if m.qids[1] == q then return m end end
  end
  local reads = {}
  local r = core.compute(mk({ 11 }, { [11] = 3 }, reads), { in_progress = true, step_icons = true, now = 10 })
  check("st 1: one in-progress qid at step 3", find(r, 11).step == 3 and r.quest_steps[11].n == 3)
  check("st 1b: markers carry no scratch field", find(r, 11).inprog == nil)
  reads = {}
  r = core.compute(mk({ 11, 12 }, { [11] = 3, [12] = 2 }, reads),
    { in_progress = true, step_icons = true, now = 10,
      }) -- distinct statics: two markers, each lone
  check("st 2a: separate markers each get a step", find(r, 11).step == 3 and find(r, 12).step == 2)
  -- two in-progress qids at one position -> one marker -> nil
  local a2 = mk({ 11, 12 }, { [11] = 3, [12] = 2 }, {})
  a2.static_pos = function() return { x = 5, y = 0, z = 5 } end
  r = core.compute(a2, { in_progress = true, step_icons = true, now = 10 })
  check("st 2: two in-progress qids on one marker -> nil",
    #r.markers == 1 and r.markers[1].step == nil)
  r = core.compute(mk({ 11 }, { [11] = 6 }, {}), { in_progress = true, step_icons = true, now = 10 })
  check("st 3: step 6 -> nil", find(r, 11).step == nil)
  r = core.compute(mk({ 11 }, { [11] = 0 }, {}), { in_progress = true, step_icons = true, now = 10 })
  check("st 3b: step 0 -> nil", find(r, 11).step == nil)
  reads = {}
  r = core.compute(mk({ 11 }, { [11] = 3 }, reads), { in_progress = true, step_icons = false, now = 10 })
  check("st 4: setting off -> nil, zero reads, no quest_steps",
    find(r, 11).step == nil and #reads == 0 and r.quest_steps == nil)
  -- 5 s limit
  reads = {}
  local a = mk({ 11 }, { [11] = 3 }, reads)
  r = core.compute(a, { in_progress = true, step_icons = true, now = 10 })
  r = core.compute(a, { in_progress = true, step_icons = true, now = 14, prev_quest_steps = r.quest_steps })
  check("st 5: within 5 s no new read, step carried", #reads == 1 and find(r, 11).step == 3)
  r = core.compute(a, { in_progress = true, step_icons = true, now = 15, prev_quest_steps = r.quest_steps })
  check("st 5b: at 5 s a new read", #reads == 2 and r.quest_steps[11].at == 15)
  -- 10 per tick
  local ids, steps = {}, {}
  for i = 1, 12 do ids[i] = 100 + i; steps[100 + i] = 1 + (i % 5) end
  reads = {}
  a = mk(ids, steps, reads)
  r = core.compute(a, { in_progress = true, step_icons = true, now = 0 })
  local first = {}
  for _, q in ipairs(reads) do first[q] = true end
  check("st 6: tick 1 reads 10 never-read", #reads == 10)
  local nread = 0
  for _ in pairs(r.quest_steps) do nread = nread + 1 end
  check("st 6b: 10 entries after tick 1", nread == 10)
  for i = #reads, 1, -1 do reads[i] = nil end
  r = core.compute(a, { in_progress = true, step_icons = true, now = 5, prev_quest_steps = r.quest_steps })
  local unread_first = reads[1] ~= nil and not first[reads[1]] and reads[2] ~= nil and not first[reads[2]]
  local rest_old = true
  for i = 3, #reads do if not first[reads[i]] then rest_old = false end end
  check("st 7: tick 2 reads the 2 never-read then the 8 oldest",
    #reads == 10 and unread_first and rest_old)
  -- tick 2 carried the 2 over-cap... entries: all 12 present, un-read ones keep tick-1 data
  -- (st 7 ran tick 2 with all 10 prior eligible, so re-run the cap case with 12 never-read + carry)
  do
    local ids2, st2 = {}, {}
    for i = 1, 12 do ids2[i] = 200 + i; st2[200 + i] = 1 + (i % 5) end
    local rd = {}
    local a3 = mk(ids2, st2, rd)
    -- 12 prior entries aged 0..11, now = 20: all eligible, no never-read; cap reads the 10 oldest
    local prev = {}
    for i = 1, 12 do prev[200 + i] = { n = 1, at = i - 1 } end
    local r3 = core.compute(a3, { in_progress = true, step_icons = true, now = 20, prev_quest_steps = prev })
    local ok_order = #rd == 10
    for i = 1, 10 do if rd[i] ~= 200 + i then ok_order = false end end
    check("st 9: oldest-first order (ages 0..11 -> the 10 oldest, in order)", ok_order)
    local n3 = 0
    for _ in pairs(r3.quest_steps) do n3 = n3 + 1 end
    check("st 10: over-cap entries carried unchanged",
      n3 == 12 and r3.quest_steps[211] == prev[211] and r3.quest_steps[212] == prev[212])
  end
  -- in-progress category required: startable + in-progress on one position
  do
    local rd = {}
    local a4 = fake_adapter({ acceptable = { 21 }, progressing = { 22 }, catalog = { 21, 22 },
      statics = { [21] = { x = 5, y = 0, z = 5 }, [22] = { x = 5, y = 0, z = 5 } } })
    a4.quest_step = function(q) rd[#rd + 1] = q; return 3 end
    local r4 = core.compute(a4, { startable = true, in_progress = true, step_icons = true, now = 10 })
    check("st 11: startable + in-progress marker gets no step, no read",
      #r4.markers == 1 and r4.markers[1].cat == "startable" and r4.markers[1].step == nil and #rd == 0)
  end
  -- signature
  local function sigof(step)
    return (core.signature({ { key = "k", pos = { x = 0, y = 0, z = 0 }, qids = { 1 },
      cat = "in_progress", step = step } }, {}))
  end
  check("st 8: signature differs between step 2 and 3", sigof(2) ~= sigof(3) and sigof(nil) ~= sigof(2))
end

-- v14 (SPEC 22.7.3-22.7.6, 22.8.4, 22.10.1, 22.11.3): NPC search, route and
-- hint pin markers, item walk gate.
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local function Q(t) return core.parse_query(t) end
  local SH = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_max_markers = 300, world_origin = P(0, 0, 0), map_origin = P(0, 0, 0),
    world_show_opened = false, world_undiscovered = false }
  local function run(world, search, over, ex)
    local o = { acceptable = {}, names = {} }
    for k, v in pairs(ex or {}) do o[k] = v end
    local a = fake_adapter(o)
    if o.quest_step then a.quest_step = o.quest_step end
    local show = { startable = true, in_progress = true, quest_items = true,
      world = world, search = search }
    for k, v in pairs(SH) do show[k] = v end
    for k, v in pairs(over or {}) do show[k] = v end
    return core.compute(a, show)
  end
  local function has(list, key)
    for _, m in ipairs(list or {}) do if m.key == key then return m end end
    return nil
  end
  local function npc(cid, name, pos, extra)
    local e = { cid = cid, name = name, pos = pos, alive = true, discovered = true }
    for k, v in pairs(extra or {}) do e[k] = v end
    return e
  end

  -- basic match: snapshot markers, full map pass, row, match cids
  local w = { npcs = { npc(7, "Brant", P(10)), npc(8, "Alma", P(20)) } }
  local r = run(w, Q("bran"))
  local m = has(r.markers, "w:npc:7")
  check("npc 1: one w:npc marker in markers", m ~= nil and m.cat == "npc_search"
    and m.label == "Brant" and not has(r.markers, "w:npc:8"))
  check("npc 1: in fullmap_world with a valid map_origin",
    has(r.fullmap_world, "w:npc:7") ~= nil)
  check("npc 1: row and match cids", #r.npc_rows == 1 and r.npc_rows[1].cid == 7
    and r.npc_rows[1].alive == true and r.npc_rows[1].marker_key == "w:npc:7"
    and r.npc_rows[1].pos.x == 10 and #r.npc_match_cids == 1 and r.npc_match_cids[1] == 7)
  local r2 = run(w, Q("bran"), { map_origin = false })
  check("npc 1b: no map_origin -> no fullmap_world", r2.fullmap_world == nil
    and has(r2.markers, "w:npc:7") ~= nil)
  -- uncached twin equal
  local um = core.world_markers(w, { search = Q("bran"), world_origin = P(0), world_max_markers = 300 },
    P(0), {})
  check("npc 1c: uncached world_markers carries the marker too",
    has(um, "w:npc:7") ~= nil and #um == 1)

  -- no query
  r = run(w, nil)
  check("npc 2: no query -> no marker, no rows, no cids",
    not has(r.markers, "w:npc:7") and #r.npc_rows == 0 and #r.npc_match_cids == 0)

  -- alive false / nil pos / discovered false
  r = run({ npcs = { npc(7, "Brant", P(10), { alive = false }) } }, Q("bran"))
  check("npc 3: dead -> no marker, row alive false", not has(r.markers, "w:npc:7")
    and #r.npc_rows == 1 and r.npc_rows[1].alive == false
    and r.npc_rows[1].marker_key == nil)
  r = run({ npcs = { { cid = 7, name = "Brant" } } }, Q("bran"))
  check("npc 4: nil pos -> row, no marker", not has(r.markers, "w:npc:7")
    and #r.npc_rows == 1 and r.npc_rows[1].pos == nil and r.npc_rows[1].marker_key == nil
    and r.npc_match_cids[1] == 7)
  r = run({ npcs = { npc(7, "Brant", P(10), { discovered = false }) } }, Q("bran"))
  check("npc 5: undiscovered -> no marker", not has(r.markers, "w:npc:7")
    and #r.npc_rows == 1)
  r = run({ npcs = { npc(7, "Brant", P(10), { discovered = false }) } }, Q("bran"),
    { world_undiscovered = true })
  check("npc 5b: world_undiscovered -> marker", has(r.markers, "w:npc:7") ~= nil)

  -- dedupe: quest marker, shop marker, seller marker with the same cid
  r = run({ npcs = { npc(9001, "Brant", P(5)) } }, Q("bran"), nil,
    { acceptable = { 20 }, names = { [20] = "Brant Quest" }, hints = { [20] = 9001 },
      npc_pos = { [9001] = P(50, 0, 50) }, npc_names = { [9001] = "Brant" } })
  check("npc 6a: quest marker covers", has(r.markers, "c:9001") ~= nil
    and not has(r.markers, "w:npc:9001") and r.npc_rows[1].marker_key == "c:9001")
  r = run({ npcs = { npc(55, "Brant", P(5)) },
    shops = { { shop = 1, npc = "Brant", cid = 55, pos = P(6), discovered = true,
      items = { { name = "Rope" } } } } }, Q("bran"), { world_shops = true })
  check("npc 6b: shop marker covers", has(r.markers, "w:shop:1") ~= nil
    and not has(r.markers, "w:npc:55") and r.npc_rows[1].marker_key == "w:shop:1")
  r = run({ npcs = { npc(55, "Brant", P(5)) },
    shops = { { shop = 1, npc = "Brant", cid = 55, pos = P(6), discovered = true,
      items = { { name = "Rope" } } } } }, Q("bran"))
  check("npc 6b2: leftover shop and NPC with one cid give one marker",
    has(r.markers, "w:shop:1") ~= nil and not has(r.markers, "w:npc:55")
    and r.npc_rows[1].marker_key == "w:shop:1")
  r = run({ npcs = { npc(56, "Brant", P(5)) },
    sellers = { { shop = 2, item = 3, item_name = "Gem", cid = 56, npc = "Brant",
      qids = {}, quest = "", pos = P(7), discovered = true } } }, Q("bran"))
  check("npc 6c: seller marker covers", has(r.markers, "w:sell:2:3") ~= nil
    and not has(r.markers, "w:npc:56") and r.npc_rows[1].marker_key == "w:sell:2:3")

  -- an NPC match adds no seller whose label did not match
  r = run({ npcs = { npc(7, "Brant", P(10)) },
    sellers = { { shop = 2, item = 3, item_name = "Gem", cid = 99, npc = "Zed",
      qids = {}, quest = "", pos = P(7), discovered = true } } }, Q("bran"))
  check("npc 7: no unmatched seller", has(r.markers, "w:npc:7") ~= nil
    and not has(r.markers, "w:sell:2:3"))

  -- the cap: NPCs only fill leftover slots, nearest first
  local cw = { chests = { { uid = "a", pos = P(1), state = "unopened",
      items = { { name = "Brandy" } } },
    { uid = "b", pos = P(2), state = "unopened", items = { { name = "Brandy" } } } },
    npcs = {} }
  for i, d in ipairs({ 50, 10, 40, 20, 30 }) do
    cw.npcs[i] = npc(100 + i, "Brant " .. i, P(d))
  end
  r = run(cw, Q("bran"), { world_max_markers = 3 })
  local wk = {}
  for _, mm in ipairs(r.markers) do
    if mm.key:sub(1, 2) == "w:" then wk[#wk + 1] = mm.key end
  end
  table.sort(wk)
  check("npc 8: 2 kept + 5 matches, cap 3 -> the nearest one only",
    table.concat(wk, ",") == "w:chest:a,w:chest:b,w:npc:102")
  check("npc 8b: rows list all five, marker_key only on the drawn one",
    #r.npc_rows == 5 and r.npc_rows[1].cid == 102 and r.npc_rows[1].marker_key == "w:npc:102"
    and r.npc_rows[2].marker_key == nil)

  -- shops and NPCs share one leftover slot by distance
  local function slot(shop_d, npc_d)
    local sw = { chests = { { uid = "a", pos = P(1), state = "unopened",
        items = { { name = "Brandy" } } } },
      npcs = { npc(61, "Brant", P(npc_d)) },
      shops = { { shop = 4, npc = "Brandt", cid = 62, pos = P(shop_d), discovered = true,
        items = { { name = "Rope" } } } } }
    local rr = run(sw, Q("bran"), { world_max_markers = 2 })
    return has(rr.markers, "w:npc:61") ~= nil, has(rr.markers, "w:shop:4") ~= nil
  end
  local got_npc, got_shop = slot(30, 20)
  check("npc 8c: nearer NPC takes the one leftover slot", got_npc and not got_shop)
  got_npc, got_shop = slot(20, 30)
  check("npc 8d: nearer shop takes the one leftover slot", got_shop and not got_npc)

  -- memo: the same list and query reuse the result
  local ml = { npc(1, "Bran", P(1)) }
  local m1 = core.npc_matches(ml, Q("bran"))
  check("npc 8e: second call reuses the matches", core.npc_matches(ml, Q("bran")) == m1)
  check("npc 8f: another query recomputes", core.npc_matches(ml, Q("zzz")) ~= m1)

  -- not in the overhead list
  local anchors = core.overhead_anchors(r.markers, {}, P(0), 1000)
  local bad = false
  for _, an in ipairs(anchors) do
    if an.marker.key:sub(1, 5) == "w:npc" then bad = true end
  end
  check("npc 9: w:npc not in the overhead list", not bad)

  -- 80 matches -> 50 cids in name order
  local big = { npcs = {} }
  for i = 1, 80 do big.npcs[i] = npc(1000 + i, string.format("Npc%02d", 81 - i), P(i)) end
  r = run(big, Q("npc"))
  check("npc 10: 80 matches -> 50 cids in name order", #r.npc_match_cids == 50
    and r.npc_match_cids[1] == 1080 and r.npc_match_cids[50] == 1031)
  check("npc 10b: ten rows", #r.npc_rows == 10)

  -- row order: nearest first, no-pos last by name
  r = run({ npcs = { npc(1, "Bran C", P(30)), { cid = 2, name = "Bran A" },
    npc(3, "Bran B", P(10)), { cid = 4, name = "Bran 0" } } }, Q("bran"))
  local ord = {}
  for _, row in ipairs(r.npc_rows) do ord[#ord + 1] = row.cid end
  check("npc 11: rows nearest first, no-pos last by name",
    table.concat(ord, ",") == "3,1,4,2")

  -- route stops
  local route = { cid = 12, name = "Mara", stops = {
    { from = 6, to = 9, pos = P(5), discovered = true },
    { from = 9, to = 12, pos = P(6), discovered = false },
    { from = 12, to = 18, pos = P(7), discovered = true } } }
  r = run({}, nil, { routes = { route }, world_max_markers = 0 })
  local rs = {}
  for _, mm in ipairs(r.markers) do if mm.cat == "route_stop" then rs[#rs + 1] = mm end end
  check("npc 12: undiscovered stop skipped, others outside the cap", #rs == 2
    and rs[1].key == "r:12:1" and rs[1].cid == 12 and rs[1].stop == 1
    and rs[1].label == "Mara 06-09" and rs[2].stop == 3 and rs[2].label == "Mara 12-18"
    and #rs[1].qids == 0)
  r = run({}, nil, { routes = { route }, world_undiscovered = true })
  local n3 = 0
  for _, mm in ipairs(r.markers) do if mm.cat == "route_stop" then n3 = n3 + 1 end end
  check("npc 12b: world_undiscovered keeps all three", n3 == 3)
  route.stops[2].discovered = true
  r = run({}, nil, { routes = { route } })
  n3 = 0
  for _, mm in ipairs(r.markers) do if mm.cat == "route_stop" then n3 = n3 + 1 end end
  check("npc 12c: three stops give three markers", n3 == 3)

  -- route colour slots, place routes, route members (SPEC 32.14)
  local function stopm(slot)
    local rr = run({}, nil, { routes = { { cid = 5, name = "N", slot = slot,
      stops = { { from = 1, to = 2, pos = P(4), discovered = true } } } } })
    local mk
    for _, mm in ipairs(rr.markers) do if mm.cat == "route_stop" then mk = mm end end
    return rr, mk
  end
  local rsa, mka = stopm(4)
  local rsb, mkb = stopm(5)
  check("rc 1: stop slot", mka ~= nil and mka.slot == 4)
  check("rc 1b: slot changes the signature",
    core.signature({ mka }, {}) ~= core.signature({ mkb }, {}))
  r = run({}, nil, { routes = { { cid = -77, place = 77, name = "Q", slot = 1, stops = {
    { from = 1, to = 2, pos = P(2), discovered = true },
    { from = 2, to = 3, pos = P(3), discovered = true } } } } })
  check("rc 2: place routes give no stop markers", has(r.markers, "r:-77:1") == nil and has(r.markers, "r:-77:2") == nil)

  local function nm(cid, place) return place and ("P" .. place) or ("N" .. cid) end
  local fc = { active = { 1, 2 }, quests = { [1] = { step_npcs = { 1, 2, 3, 4, 5 }, npcs = { 1, 2, 3, 4, 5, 6 } },
    [2] = { step_npcs = { 6, 7, 8, 9 }, npcs = { 6, 7, 8, 9 } } } }
  local function cids(l) local t = {} for _, e in ipairs(l) do t[#t + 1] = e.cid end return table.concat(t, ",") end
  local l, n, tot = core.route_members(fc, {}, {}, nil, { routes = 1, places = false }, nm)
  check("rc 3: cap eight", cids(l) == "1,2,3,4,5,6,7,8" and n == 8 and tot == 9)
  l, n, tot = core.route_members(fc, {}, {}, 20, { routes = 1, places = false }, nm)
  check("rc 3b: target unlisted takes a seat", #l == 7 and n == 8 and tot == 10)
  l, n, tot = core.route_members(fc, {}, {}, 3, { routes = 1, places = false }, nm)
  check("rc 3c: target listed", #l == 8 and n == 8 and tot == 9)
  local fp = { active = { 1, 2 }, quests = { [1] = { step_npcs = { 1, 2 } }, [2] = { step_npcs = { 3 } } } }
  local rel = { [1] = { dest = { { key = 77 }, { key = 78 } } }, [2] = { dest = { { key = 77 } } } }
  local plc = { [77] = { x = 1, y = 0, z = 1 } }
  l, n, tot = core.route_members(fp, rel, plc, nil, { routes = 1, places = true }, nm)
  local last = l[#l]
  check("rc 4: one place member after the NPCs", #l == 4 and cids(l) == "1,2,3,-77"
    and last.place == 77 and last.name == "P77" and tot == 4 and n == 4)
  l = core.route_members(fp, rel, plc, nil, { routes = 0, places = true }, nm)
  check("rc 5: routes off gives places only", cids(l) == "-77")
  local seen = {}
  core.route_members(fp, rel, plc, nil, { routes = 1, places = true },
    function(c, p) seen[#seen + 1] = tostring(c) .. "/" .. tostring(p); return "x" end)
  check("rc 6: name_of args", table.concat(seen, ",") == "1/nil,2/nil,3/nil,nil/77")
  l, n, tot = core.route_members(nil, {}, {}, 9, { routes = 1, places = true }, nm)
  check("rc 7: nil focus", #l == 0 and n == 1 and tot == 1)
  l, n = core.route_members(nil, {}, {}, nil, { routes = 1, places = true }, nm)
  check("rc 7b: nil focus no target", #l == 0 and n == 0)
  local rel8 = { [1] = { dest = { { key = 77 } } } }
  l, n, tot = core.route_members(fc, rel8, plc, nil, { routes = 1, places = true }, nm)
  check("rc 8: a place never passes the cap", #l == 8 and cids(l) == "1,2,3,4,5,6,7,8"
    and n == 8 and tot == 10)
  local f7 = { active = { 1, 2 }, quests = { [1] = { step_npcs = { 1, 2, 3, 4, 5 } },
    [2] = { step_npcs = { 6, 7 } } } }
  l, n, tot = core.route_members(f7, rel8, plc, 20, { routes = 1, places = true }, nm)
  check("rc 8b: an unlisted target takes the last seat", #l == 7 and cids(l) == "1,2,3,4,5,6,7"
    and n == 8 and tot == 9)
  l, n = core.route_members(f7, rel8, plc, nil, { routes = 1, places = true }, nm)
  check("rc 8c: a free seat takes the place", cids(l) == "1,2,3,4,5,6,7,-77" and n == 8)

  -- SPEC 32.14.11: close places merge, lead route stops
  do
    local function pl(x, z) return { x = x, y = 0, z = z } end
    local function nmf(c, k) return k and ("P" .. k) or "N" end
    local function keys(lst)
      local t = {}
      for _, e in ipairs(lst) do t[#t + 1] = tostring(e.place) end
      return table.concat(t, ",")
    end
    local fa = { active = { 1 }, quests = { [1] = {} } }
    local relA = { [1] = { dest = { { key = 1 }, { key = 2 } } } }
    local function two(x2, opt)
      local o = { routes = 0, places = true }
      for k, v in pairs(opt or {}) do o[k] = v end
      return core.route_members(fa, relA, { [1] = pl(0, 0), [2] = pl(x2, 0) }, nil, o, nmf)
    end
    local ml, mn, mt = two(149, { player = pl(140, 0) })
    check("rcc merge nearest", keys(ml) == "2" and mn == 1 and mt == 1)
    ml, mn = two(151)
    check("rcc merge bounds: 151 keeps both", keys(ml) == "1,2" and mn == 2)
    ml, mn = two(150)
    check("rcc merge bounds: 150 keeps key 1 only", keys(ml) == "1" and mn == 1)
    ml = two(149, { player = pl(140, 0), prev = { [1] = true } })
    check("rcc prev sticky", keys(ml) == "1")
    local fb = { active = { 1, 2 }, quests = { [1] = {}, [2] = {} } }
    ml = core.route_members(fb, { [1] = { dest = { { key = 1 } } }, [2] = { dest = { { key = 2 } } } },
      { [1] = pl(0, 0), [2] = pl(40, 0) }, nil, { routes = 0, places = true, player = pl(0, 0) }, nmf)
    check("rcc merge across quests", keys(ml) == "1")
    ml, mn, mt = core.route_members(fb,
      { [1] = { dest = { { key = 1 } } }, [2] = { dest = { { key = 1 }, { key = 2 } } } },
      { [1] = pl(0, 0), [2] = pl(300, 0) }, nil, { routes = 0, places = true }, nmf)
    check("rcc shared key", keys(ml) == "1,2" and mt == 2)
    ml = core.route_members(fa, { [1] = { dest = { { key = 1 }, { key = 2 }, { key = 3 } } } },
      { [1] = pl(0, 0), [2] = pl(100, 0), [3] = pl(500, 0) }, nil, { routes = 0, places = true }, nmf)
    check("rcc no player", keys(ml) == "1,3")
    ml = core.route_members(fa, relA, { [1] = pl(0, 0), [2] = pl(500, 0) }, nil,
      { routes = 0, places = true, player = pl(500, 0) }, nmf)
    check("rcc kept places publish in candidate order", keys(ml) == "1,2")
    ml = core.route_members(fa, relA, { [1] = pl(0, 0), [2] = { x = 100, y = 400, z = 0 } }, nil,
      { routes = 0, places = true }, nmf)
    check("rcc merge ignores y", keys(ml) == "1")
    ml = core.route_members(fa, relA, { [1] = { x = 0, y = 1000, z = 0 }, [2] = pl(100, 0) }, nil,
      { routes = 0, places = true, player = { x = 100, y = 1000, z = 0 } }, nmf)
    check("rcc player distance ignores y", keys(ml) == "2")

    local function stops_of(r)
      local t = {}
      for _, mm in ipairs(r.markers) do if mm.cat == "route_stop" then t[#t + 1] = mm end end
      return t
    end
    local leadr = { cid = 5, name = "N", slot = 1, lead = true, stops = {
      { pos = pl(0, 0), discovered = true, lead = true }, { pos = pl(10, 10), discovered = true } } }
    local lm = stops_of(run({}, nil, { routes = { leadr } }))
    check("rcc lead markers", #lm == 1 and lm[1].stop == 2 and lm[1].num == 1 and lm[1].key == "r:5:1")
    local plain = stops_of(run({}, nil, { routes = { { cid = 5, name = "N", slot = 1, stops = {
      { pos = pl(0, 0), discovered = true }, { pos = pl(10, 10), discovered = true } } } } }))
    check("rcc plain markers", #plain == 2 and plain[1].num == 1 and plain[2].num == 2
      and plain[1].key == "r:5:1" and plain[2].key == "r:5:2")
    local one = stops_of(run({}, nil, { routes = { { cid = 5, name = "N", slot = 1, stops = {
      { pos = pl(10, 10), discovered = true } } } } }))
    check("rcc lead key", #one == 1 and one[1].key == lm[1].key)
    local leadi = { cid = 5, name = "N", slot = 1, lead = true, stops = {
      { pos = pl(0, 0), discovered = true, lead = true }, { pos = pl(10, 10), discovered = true, idx = 2 } } }
    local li = stops_of(run({}, nil, { routes = { leadi } }))
    check("rcc lead idx", #li == 1 and li[1].num == 2 and li[1].key == "r:5:2")
    local leadb = { cid = 5, name = "N", slot = 1, lead = true, stops = {
      { pos = pl(0, 0), discovered = true, lead = true }, { pos = pl(10, 10), discovered = true, idx = "x" } } }
    local lb = stops_of(run({}, nil, { routes = { leadb } }))
    check("rcc non-number idx falls back", #lb == 1 and lb[1].num == 1)
    check("rcc lead signature", core.signature(lm, {}) ~= core.signature(one, {}))
  end

  -- hint pins, with a query active, outside the cap
  r = run({ chests = {} }, Q("zzz"), { world_max_markers = 0,
    hint_pins = { { qid = 30, i = 2, label = "Look here", pos = P(9) } } })
  local hp = has(r.markers, "h:30:2")
  check("npc 13: hint pin with a query, qid and i", hp ~= nil and hp.cat == "hint_pin"
    and hp.qid == 30 and hp.i == 2 and hp.label == "Look here")

  -- neither is a search result row
  local rows = core.world_rows(r.markers, {}, P(0))
  local leak = false
  for _, row in ipairs(rows) do
    if row.key:sub(1, 2) == "h:" or row.key:sub(1, 2) == "r:" then leak = true end
  end
  check("npc 14: pins are not in the search results list", not leak)

  -- minimap tiers
  local mk = {
    { key = "w:chest:a", cat = "chest", pos = P(1) },
    { key = "h:1:1", cat = "hint_pin", pos = P(2) },
    { key = "r:1:1", cat = "route_stop", pos = P(3) },
    { key = "c:5", cat = "startable", pos = P(50) },
    { key = "w:npc:9", cat = "npc_search", pos = P(4) } }
  local sel = core.minimap_markers(mk, P(0), 100, 10)
  local sk = {}
  for _, mm in ipairs(sel) do sk[#sk + 1] = mm.key end
  check("npc 15: minimap quest < route/hint < world",
    table.concat(sk, ",") == "c:5,h:1:1,r:1:1,w:chest:a,w:npc:9")
  local overhead = core.route_overhead_points(mk)
  check("npc 15b: route stops and hint pins stay on the in-world layer",
    #overhead == 2 and overhead[1].key == "h:1:1" and overhead[2].key == "r:1:1")
  local objective_place = { key = "o:p:30040", cat = "focus_place", objective = true,
    qid = 30040, pos = P(8), label = "Objective: Vernworth Hall" }
  local ancillary_place = { key = "f:3004", cat = "focus_place", pos = P(9) }
  overhead = core.route_overhead_points({ mk[2], mk[3], objective_place, ancillary_place })
  check("npc 15b2: objective destination joins the in-world point layer alone",
    #overhead == 3 and overhead[1].key == "h:1:1" and overhead[2].key == "r:1:1"
      and overhead[3].key == "o:p:30040")
  local opo, oph, opp = core.route_point_state({ markers = { objective_place } }, {})
  check("npc 15b3: objective destination activates the point layer without routes",
    opo == false and oph == true and #opp == 1 and opp[1].key == "o:p:30040")
  local ro, hp, pts = core.route_point_state({ markers = { mk[2] } }, {})
  check("npc 15c: a hint without a route activates the point layer",
    ro == false and hp == true and #pts == 1 and pts[1].key == "h:1:1")
  local fro, fhp, fpts = core.route_point_state(nil, {}, true, true, { mk[1] })
  check("npc 15d: failed compute retains the committed point state",
    fro == true and fhp == true and #fpts == 1 and fpts[1] == mk[1])
  local pro, php, ppts = core.route_point_state({ markers = {} },
    { { cid = -77, place = 77, stops = { { pos = P(8) } } } })
  check("npc 15d2: a place route keeps route drawing active without stop markers",
    pro == true and php == true and #ppts == 0)
  local pins = {
    { qid = 20090, i = 1, label = "Ordinary" },
    { qid = 30040, i = 1, label = "Hidden door" },
    { qid = 30040, i = 2, label = "Other" },
  }
  local pc = core.filter_hint_pins(pins, true)
  local po = core.filter_hint_pins(pins, false)
  local pu = core.filter_hint_pins(pins, nil)
  check("npc 15e: only the open target door pin is filtered",
    #pc == 3 and #pu == 3 and #po == 2
      and po[1].label == "Ordinary" and po[2].label == "Other")

  local wl = core.wrap_text("one two three four", 7, function(s) return #s end)
  check("npc 15f: hint prose wraps at measured word boundaries",
    table.concat(wl, "|") == "one two|three|four")
  local ww = core.wrap_text("encyclopedia next", 4, function(s) return #s end)
  check("npc 15g: an overlong word stays intact",
    #ww == 2 and ww[1] == "encyclopedia" and ww[2] == "next")
  check("npc 15h: empty hint prose draws no lines",
    #core.wrap_text("", 40, function(s) return #s end) == 0
      and #core.wrap_text("   ", 40, function(s) return #s end) == 0)
  local wf = core.wrap_text("aa bb", 3, function() error("measure") end)
  local wn = core.wrap_text("aa bb", 3, function() return "wide" end)
  check("npc 15i: failed hint measurement falls back safely",
    table.concat(wf, "|") == "aa|bb" and table.concat(wn, "|") == "aa|bb")
  local cache, calls = {}, 0
  local function counted(s) calls = calls + 1; return #s end
  local ca = core.wrap_text_cached(cache, "one two three", "7:100", 7, counted)
  local first_calls = calls
  local cb = core.wrap_text_cached(cache, "one two three", "7:100", 7, counted)
  local same_calls = calls
  local cc = core.wrap_text_cached(cache, "one two three", "3:100", 3, counted)
  check("npc 15j: repeated frames reuse wrapping and width changes invalidate it",
    ca == cb and first_calls == same_calls and calls > same_calls
      and table.concat(ca, "|") == "one two|three"
      and table.concat(cc, "|") == "one|two|three")
  check("npc 15k: nested and narrow panels never exceed remaining width",
    core.hint_wrap_width(300, 180, 16, 160) == 104
      and core.hint_wrap_width(300.6, 180, 16, 160) == 104
      and core.hint_wrap_width(200, 195, 16, 160) == 1
      and core.hint_wrap_width(nil, nil, nil, 160) == 160)

  -- hint step reads, step_icons off
  local reads = {}
  r = run({}, nil, { hint_qids = { 77 }, now = 10, step_icons = false },
    { quest_step = function(q) reads[#reads + 1] = q; return 3 end })
  check("npc 16: hint qid read with step_icons off", #reads == 1 and reads[1] == 77
    and r.hint_steps[77] == 3 and r.quest_steps[77].n == 3)
  r = run({}, nil, { hint_qids = { 77 }, now = 12, step_icons = false,
    prev_quest_steps = r.quest_steps },
    { quest_step = function(q) reads[#reads + 1] = q; return 4 end })
  check("npc 16b: shared throttle, no re-read inside 5 s", #reads == 1
    and r.hint_steps[77] == 3)
  r = run({}, nil, { now = 10, step_icons = false },
    { quest_step = function(q) reads[#reads + 1] = q; return 3 end })
  check("npc 16c: no hint qids, step_icons off -> no reads, no steps",
    #reads == 1 and r.hint_steps == nil and r.quest_steps == nil)

  -- item walk gate and mode
  check("npc 17: gate on for marks with the menu open",
    core.item_walk_wanted({ inventory_quest_marks = true, item_menu_open = true }) == true)
  check("npc 17b: gate off with the menu closed",
    not core.item_walk_wanted({ inventory_quest_marks = true, item_menu_open = false }))
  check("npc 17c: mode needs for marks only",
    core.item_walk_mode({ inventory_quest_marks = true, item_menu_open = true }) == "needs")
  check("npc 17d: mode full for quest items and for sellers",
    core.item_walk_mode({ in_progress = true, quest_items = true }) == "full"
    and core.item_walk_mode({ world_sellers = true }) == "full")
end

-- v14 chest kinds (SPEC 27.4.2, 27.5, 27.6)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local SHK = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SHK) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local function chest(uid, x, kinds, extra)
    local c = { uid = uid, pos = P(x), state = "unopened", kinds = kinds,
      items = { { name = "Gold", n = 1 } } }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
  end
  local function lbl(c) return core.chest_label(c) end
  check("kinds: kept label", lbl({ items = { { name = "Wakestone", n = 1 } },
    kinds = { "kept" } }) == "Chest - Wakestone [stays opened in NG+]")
  check("kinds: ng_shard label", lbl({ kinds = { "ng_shard" } })
    == "Chest [new shard each cycle]")
  check("kinds: quest and trap, quest_text", lbl({ items = { { name = "Gold", n = 1 } },
    kinds = { "quest", "trap" }, quest_text = "after another quest" })
    == "Chest - Gold [after another quest, trap]")
  check("kinds: quest without text", lbl({ kinds = { "quest" } }) == "Chest [quest-gated]")
  check("kinds: pawn phrase", lbl({ kinds = { "pawn" } }) == "Chest [pawns can't open]")
  check("kinds: three kinds -> two then +1", lbl({ items = { { name = "Gold", n = 1 } },
    kinds = { "kept", "trap", "pawn" } }) == "Chest - Gold [stays opened in NG+, trap +1]")
  check("kinds: empty list no bracket", lbl({ kinds = {} }) == "Chest")
  check("kinds: nil list as before", lbl({ items = { { name = "A", n = 1 } } }) == "Chest - A")

  -- gate_name
  local ad = { quest_name = function(q) return q == 7 and "Full Seven" or nil end,
    seen_quest_name = function(q) return q == 8 and "Seen Eight" or nil end }
  check("gate_name: reveal gives full name", core.gate_name(7, ad, true) == "Full Seven")
  check("gate_name: no reveal, unseen -> another quest",
    core.gate_name(7, ad, false) == "another quest")
  check("gate_name: seen name", core.gate_name(8, ad, false) == "Seen Eight")
  check("gate_name: reveal falls back to seen", core.gate_name(8, ad, true) == "Seen Eight")
  check("gate_name: nothing -> another quest, never an id",
    core.gate_name(9, ad, true) == "another quest")
  check("gate_name: empty name", core.gate_name(7,
    { quest_name = function() return "" end }, true) == "another quest")

  -- search
  local function found(q, w)
    return #core.world_markers(w, sh({ search = core.parse_query(q) }), O, {})
  end
  local w = { chests = {
    chest("a", 1, { "ng_shard" }), chest("b", 2, { "kept" }),
    chest("c", 3, { "quest" }, { quest_text = "after Foo" }),
    chest("d", 4, { "trap" }), chest("e", 5, { "pawn" }), chest("f", 6, nil) } }
  check("kinds search: new shard", found("new shard each cycle", w) == 1)
  check("kinds search: NG+", found("stays opened in NG+", w) == 1)
  check("kinds search: quest-gated", found("quest-gated", w) == 1)
  check("kinds search: quest_text", found("after foo", w) == 1)
  check("kinds search: trap", found("trap", w) == 1)
  check("kinds search: pawns", found("pawns can't open", w) == 1)

  -- filters, uncached and cached
  local KEYS = { "ng_shard", "kept", "quest", "trap", "pawn" }
  local function shown(f, over)
    local ms = f(w, sh(over), O, {})
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = true end
    return t
  end
  for _, f in ipairs({ core.world_markers, core.world_markers_cached }) do
    local all = shown(f)
    check("kinds filter: all on shows six", (function()
      local n = 0; for _ in pairs(all) do n = n + 1 end; return n == 6 end)())
    for i, k in ipairs(KEYS) do
      local t = shown(f, { ["world_kind_" .. k] = false })
      local hid = {}
      for key in pairs(all) do if not t[key] then hid[#hid + 1] = key end end
      check("kinds filter: " .. k .. " hides only its chest",
        #hid == 1 and hid[1] == "w:chest:" .. string.char(96 + i))
    end
  end
  do
    local w2 = { chests = { chest("x", 1, { "kept", "trap" }) } }
    local c = 0
    for _, off in ipairs({ "world_kind_kept", "world_kind_trap" }) do
      if #core.world_markers(w2, sh({ [off] = false }), O, {}) == 0 then c = c + 1 end
    end
    check("kinds filter: two kinds hide when either off", c == 2)
    local none = { chests = { chest("y", 1, nil) } }
    local s5 = {}
    for _, k in ipairs(KEYS) do s5["world_kind_" .. k] = false end
    check("kinds filter: no kinds ignores all five",
      #core.world_markers(none, sh(s5), O, {}) == 1)
    check("kinds filter: show without the keys hides nothing",
      #core.world_markers(w, sh(), O, {}) == 6)
    local dd = { chests = { chest("z", 1, { "trap" }) },
      treasure = { { name = "T1", pos = P(1.5), checked = false, discovered = true } } }
    local ms, pn = core.world_markers(dd, sh({ world_kind_trap = false }), O, {})
    check("kinds filter: hidden chest still dedupes its treasure", #ms == 0
      and pn.treasure.known == 0 and pn.chest.known == 1 and pn.chest.shown == 0)
  end

  -- a name seen later relabels (new world table, same uid)
  do
    local function lab(text)
      local ms = core.world_markers_cached({ chests = { chest("r", 1, { "quest" },
        { quest_text = text }) } }, sh(), O, {})
      return ms[1].label
    end
    local l1 = lab("after another quest")
    local l2 = lab("after Foo")
    check("kinds: quest_text change relabels", l1:find("after another quest", 1, true)
      and l2:find("after Foo", 1, true) and not l2:find("another", 1, true))
  end

  -- faded
  do
    local fw = { chests = { chest("m", 1, { "quest" }, { quest_met = false }),
      chest("n", 2, { "quest" }, { quest_met = true }),
      chest("o", 3, { "quest" }) } }
    for _, f in ipairs({ core.world_markers, core.world_markers_cached }) do
      local ms = f(fw, sh(), O, {})
      local by = {}
      for _, m in ipairs(ms) do by[m.key] = m end
      check("faded: quest_met false -> faded", by["w:chest:m"].faded == true)
      check("faded: met true -> not faded", not by["w:chest:n"].faded)
      check("faded: nil -> not faded", not by["w:chest:o"].faded)
    end
    local sig = function(faded)
      return (core.signature({ { key = "k", pos = P(1), qids = {}, label = "L",
        cat = "chest", faded = faded } }, {}))
    end
    check("faded: signature differs", sig(true) ~= sig(false) and sig(nil) == sig(false))
  end
end

-- haystacks from fields (SPEC 28.4.1)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(q)
    local s = {}
    for k, v in pairs(SHB) do s[k] = v end
    s.search = core.parse_query(q)
    return s
  end
  local w = {
    monsters = { { uid = "m1", cid = 101, cids = { 101 }, name = "Goblin",
      respawning = true, pos = P(0, 0, 0) } },
    drops = { [101] = { "Rotten Meat" } },
    sellers = { { shop = 7, item = 5, item_name = "Potion", npc = "Ana", quest = "Sky",
      maybe_locked = true, pos = P(1, 0, 0), qids = {} } },
    chests = { { uid = "c1", pos = P(2, 0, 0), state = "unopened", item_name = "Ferrystone" } },
  }
  local paths = { { "uncached", core.world_markers }, { "cached", core.world_markers_cached } }
  for _, pa in ipairs(paths) do
    local function n(q) return #pa[2](w, sh(q), O, {}) end
    for _, q in ipairs({ "respawning", "for", "sold", "by", "may", "locked" }) do
      check("hay45 " .. q .. " [" .. pa[1] .. "]", n(q) == 0)
    end
    check("hay45 monster name [" .. pa[1] .. "]", n("goblin") == 1)
    check("hay45 drop [" .. pa[1] .. "]", n("rotten") == 1)
    check("hay45 seller npc [" .. pa[1] .. "]", n("ana") == 1)
    check("hay45 chest word [" .. pa[1] .. "]", n("chest") >= 1)
  end
end

-- haystack carry (SPEC 28.4.3)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(q)
    local s = {}
    for k, v in pairs(SHB) do s[k] = v end
    s.search = core.parse_query(q or "pot")
    return s
  end
  local stats = core.world_stats
  local function run(w, q) return core.world_markers_cached(w, sh(q), O, {}) end
  local function by_key(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end

  -- equal entries in fresh tables: each haystack is built once
  local function mk_equal()
    return {
      chests = { { uid = "h1", pos = P(1), state = "unopened", item_name = "Potion",
        items = { { name = "Potion", n = 1 } }, kinds = { "trap" } } },
      treasure = { { name = "HTre", pos = P(20), items = { { name = "Elixir" } } } },
      tokens = { { uid = "ht", pos = P(3), name = "Token A", state = "not" } },
      monsters = { { uid = "hm", cid = 401, cids = { 401 }, name = "Mino", pos = P(4) } },
      drops = { [401] = { "Mino Horn" } },
      sellers = { { shop = 70, item = 5, item_name = "Potion", npc = "Ana", quest = "Q",
        qids = {}, pos = P(5) } },
      shops = { { shop = 71, cid = 9171, npc = "Gil", pos = P(6), discovered = true,
        items = { { name = "Potion" }, { name = "Rope" } } } },
    }
  end
  local b0 = stats.hay_builds
  run(mk_equal())
  local first = stats.hay_builds - b0
  check("hay40 counter moves on first build", first >= 6)
  b0 = stats.hay_builds
  run(mk_equal())
  check("hay40 built once", stats.hay_builds - b0 == 0)

  -- chest item name read falls back, then succeeds
  local function mk_chest(name)
    return { chests = { { uid = "hc", pos = P(1), state = "unopened", item_name = name } } }
  end
  local ms = run(mk_chest("Item 5"))
  check("hay40 chest fallback not matched", #ms == 0)
  b0 = stats.hay_builds
  ms = run(mk_chest("Potion"))
  check("hay40 chest rebuilt", stats.hay_builds - b0 == 1)
  check("hay40 chest matches after", #ms == 1 and ms[1].key == "w:chest:hc")
  b0 = stats.hay_builds
  run(mk_chest("Potion"))
  check("hay40 chest then carried", stats.hay_builds - b0 == 0)

  -- monster drop names change
  local function mk_mon(list)
    return { monsters = { { uid = "hd", cid = 402, cids = { 402 }, name = "Troll", pos = P(1) } },
      drops = { [402] = list } }
  end
  ms = run(mk_mon({ "Rotten Meat" }), "rotten")
  check("hay40 drop matched", #ms == 1)
  b0 = stats.hay_builds
  ms = run(mk_mon({ "Bone" }), "rotten")
  check("hay40 drops rebuilt", stats.hay_builds - b0 == 1 and #ms == 0)
  b0 = stats.hay_builds
  ms = run(mk_mon({ "Bone" }), "bone")
  check("hay40 drops carried", stats.hay_builds - b0 == 0 and #ms == 1)

  -- a shop whose item unlocks between rounds: the label is fresh
  local function mk_shop(locked)
    return { shops = { { shop = 72, cid = 9172, npc = "Gil", pos = P(1), discovered = true,
      items = { { name = "Potion", locked = locked } } } } }
  end
  local k1 = by_key(run(mk_shop(true)))["w:shop:72"]
  local k2 = by_key(run(mk_shop(false)))["w:shop:72"]
  check("hay40 shop locked r1", k1 ~= nil and k1.label:find("(may be locked)", 1, true) ~= nil)
  check("hay40 shop label fresh", k2 ~= nil and k2.label:find("(may be locked)", 1, true) == nil)

  -- sellers at one shop keep their own haystacks
  local sw = { sellers = {
    { shop = 77, item = 5, item_name = "Potion", npc = "N", qids = {}, quest = "", pos = P(1) },
    { shop = 77, item = 6, item_name = "Elixir", npc = "N", qids = {}, quest = "", pos = P(2) } } }
  local pk = by_key(run(sw, "potion"))
  local ek = by_key(run(sw, "elixir"))
  check("hay40 seller keys distinct", pk["w:sell:77:5"] ~= nil and pk["w:sell:77:6"] == nil
    and ek["w:sell:77:6"] ~= nil and ek["w:sell:77:5"] == nil)

  -- the drop hover follows the new entry's label
  local function mk_resp(r)
    return { monsters = { { uid = "hg", cid = 403, cids = { 403 }, name = "Gob",
      respawning = r, pos = P(1) } }, drops = { [403] = { "Rotten Meat" } } }
  end
  run(mk_resp(false), "rotten")
  ms = run(mk_resp(true), "rotten")
  check("hay40 hover fresh", #ms == 1 and ms[1].hover ~= nil
    and ms[1].hover:sub(1, 20) == "Gob (respawning)\nDro")

  -- every compared field rebuilds: a seller's quest, a chest's kinds, a treasure's items
  local function mk_sq(quest)
    return { sellers = { { shop = 78, item = 1, item_name = "Gem", npc = "N", quest = quest,
      qids = {}, pos = P(1) } } }
  end
  run(mk_sq("Alpha"), "bravo")
  b0 = stats.hay_builds
  ms = run(mk_sq("Bravo"), "bravo")
  check("hay40 seller quest rebuilt", stats.hay_builds - b0 == 1 and by_key(ms)["w:sell:78:1"] ~= nil)
  local function mk_ck(kinds)
    return { chests = { { uid = "hk", pos = P(1), state = "unopened", kinds = kinds } } }
  end
  run(mk_ck(nil), "new shard each cycle")
  b0 = stats.hay_builds
  ms = run(mk_ck({ "ng_shard" }), "new shard each cycle")
  check("hay40 chest kinds rebuilt", stats.hay_builds - b0 == 1 and #ms == 1)
  local function mk_tr(name)
    return { treasure = { { name = "HT2", pos = P(30), items = { { name = name } } } } }
  end
  run(mk_tr("Rope"), "elixir")
  b0 = stats.hay_builds
  ms = run(mk_tr("Elixir"), "elixir")
  check("hay40 treasure items rebuilt", stats.hay_builds - b0 == 1 and #ms == 1)
end

-- merge_shops (SPEC 28.4.4)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300,
    world_shops = true }
  local w = {
    shops = { { shop = 5, cid = 9500, npc = "Gil", pos = P(10), discovered = true,
      items = { { name = "Rope" } } } },
    sellers = { { shop = 5, item = 1, item_name = "Gem", cid = 9500, npc = "Gil",
      quest = "Qx", qids = {}, pos = P(11), discovered = true } },
  }
  local qc = { [9500] = { key = "c:9500" } }   -- the shop's NPC has a quest marker
  for _, pa in ipairs({ { "uncached", core.world_markers },
    { "cached", core.world_markers_cached } }) do
    local ms, panel, merged = pa[2](w, SHB, O, {}, qc)
    local listed = 0
    for _, m in ipairs(ms) do if m.key == "w:shop:5" then listed = listed + 1 end end
    local rows, row = 0, nil
    for _, e in ipairs(panel.shop.entries) do
      if e.key == "w:shop:5" then rows = rows + 1; row = e end
    end
    check("merge_shops: merged shop not listed twice [" .. pa[1] .. "]",
      listed == 0 and rows == 1 and row.merged == true
      and #merged >= 1 and #row.sells_for == 1)
  end
end

-- toggle costs (SPEC 28.7.2)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local Q = core.parse_query
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SHB) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local stats = core.world_stats
  local function keyset(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end
  local function keys(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    table.sort(t)
    return table.concat(t, ",")
  end
  local paths = { { "uncached", core.world_markers }, { "cached", core.world_markers_cached } }
  local cats_zero = true
  for _, cat in ipairs(core.WORLD_CATS) do
    if type(core.world_stats.cell_entries) ~= "table" or core.world_stats.cell_entries[cat] ~= 0 then
      cats_zero = false
    end
  end
  check("grid: cell_entries starts at 0 for every category", cats_zero)

  -- a category that is off puts nothing in cells; turning it on adds it
  local tw = { chests = { { uid = "gc1", pos = P(1), state = "unopened" } },
    tokens = { { uid = "gt1", pos = P(5), name = "Tok", state = "not" } } }
  local ms1, p1 = core.world_markers_cached(tw, sh({ world_tokens = false }), O, {})
  local gb = stats.grid_builds
  check("grid: off category has no cells", stats.cell_entries.token == 0)
  check("grid: off category still counted", p1.token.known == 1)
  check("grid: on category has cells", stats.cell_entries.chest > 0)
  local ms2, p2 = core.world_markers_cached(tw, sh(), O, {})
  check("grid: added without rebuild", stats.grid_builds == gb
    and keyset(ms2)["w:tok:gt1"] ~= nil and p2.token.shown == 1)
  check("grid: added category has cells", stats.cell_entries.token == 1)
  -- a toggle going off never rebuilds
  core.world_markers_cached(tw, sh({ world_chests = false }), O, {})
  check("grid: toggle off keeps the grid", stats.grid_builds == gb)

  -- the added category widens the grid bounds
  local fw = { tokens = { { uid = "gtf", pos = P(5000, 0, 5000), name = "Far", state = "not" } } }
  local f1 = core.world_markers_cached(fw, sh({ world_tokens = false }), O, {})
  local f2 = core.world_markers_cached(fw, sh(), O, {})
  check("grid: add widens bounds", #f1 == 0 and keyset(f2)["w:tok:gtf"] ~= nil)

  -- no search: no haystack, no query match, no drop work
  local nw = {
    chests = { { uid = "gn1", pos = P(1), state = "unopened", item_name = "Potion" } },
    monsters = { { uid = "gn2", cid = 801, cids = { 801 }, name = "Orc", pos = P(2) } },
    drops = { [801] = { "Orc Tooth" } },
    sellers = { { shop = 81, item = 1, item_name = "Gem", cid = 9081, npc = "Gil",
      quest = "Qz", qids = {}, pos = P(3), discovered = true } },
    shops = { { shop = 81, cid = 9081, npc = "Gil", pos = P(4), discovered = true,
      items = { { name = "Potion" }, { name = "Rope" } } } },
  }
  for _, pa in ipairs(paths) do
    local h0, c0 = stats.hay_builds, stats.query_calls
    local ms = pa[2](nw, sh({ world_shops = true }), O, {})
    check("no search: zero search work [" .. pa[1] .. "]",
      stats.hay_builds - h0 == 0 and stats.query_calls - c0 == 0 and #ms >= 3)
  end
  for _, pa in ipairs(paths) do
    local c0 = stats.query_calls
    pa[2](nw, sh({ world_shops = true, search = Q("pot") }), O, {})
    check("no search: query calls move under a query [" .. pa[1] .. "]",
      stats.query_calls - c0 > 0)
  end

  -- quest items: the need read runs only with quest items and in progress on
  do
    local GARB = { id = 300, pos = { x = 1, y = 2, z = 3 }, src = "placed" }
    local function reads(show)
      local o = { progressing = { 10 }, names = { [10] = "A" },
        item_needs = { [10] = { { id = 300, num = 1 } } },
        item_locs = { GARB }, item_names = { [300] = "Beggar's Garb" } }
      local r0 = stats.item_need_reads
      core.compute(fake_adapter(o), show)
      return stats.item_need_reads - r0
    end
    check("quest items off: zero", reads({ startable = true, in_progress = true,
      quest_items = false }) == 0)
    check("in progress off: zero", reads({ startable = true, in_progress = false,
      quest_items = true }) == 0)
    check("quest items and in progress on: one read", reads({ startable = true,
      in_progress = true, quest_items = true }) == 1)
  end

  -- Monsters tree (SPEC 28.12.3): Large and Small are independent
  local mw = { monsters = {
    { uid = "ms", cid = 1, name = "Imp", pos = P(2), small = true },
    { uid = "ml", cid = 2, name = "Ogre", pos = P(3), small = false } },
    drops = { [1] = { "Imp Fang" }, [2] = { "Ogre Horn" } } }
  for _, pa in ipairs(paths) do
    local tag = " [" .. pa[1] .. "]"
    local m, p = pa[2](mw, sh({ world_monsters = false, world_small_monsters = true }), O, {})
    -- known counts every large monster whatever Large says (as a toggled-off
    -- category always reports), and a small one only while Small is on
    check("mtree: only Small shows the small one" .. tag, keys(m) == "w:mon:ms"
      and p.monster.known == 2 and p.monster.small_known == 1 and p.monster.small_shown == 1)
    m, p = pa[2](mw, sh({ world_monsters = true, world_small_monsters = false }), O, {})
    check("mtree: only Large shows the large one" .. tag, keys(m) == "w:mon:ml"
      and p.monster.known == 1 and p.monster.small_known == 0 and p.monster.small_shown == 0)
    m, p = pa[2](mw, sh({ world_monsters = true, world_small_monsters = true }), O, {})
    check("mtree: both show both" .. tag, keys(m) == "w:mon:ml,w:mon:ms"
      and p.monster.known == 2 and p.monster.shown == 2 and p.monster.small_known == 1
      and p.monster.small_shown == 1)
    local flags = {}
    for _, e in ipairs(p.monster.entries) do flags[e.key] = e.small end
    check("mtree: entries carry small" .. tag, flags["w:mon:ms"] == true
      and flags["w:mon:ml"] == false)
    m, p = pa[2](mw, sh({ world_monsters = false, world_small_monsters = false }), O, {})
    check("mtree: both off shows none" .. tag, #m == 0 and p.monster.shown == 0
      and p.monster.known == 1 and p.monster.small_known == 0)
    m = pa[2](mw, sh({ world_monsters = false, world_small_monsters = true,
      search = Q("fang") }), O, {})
    check("mtree: drop search finds the small one with only Small on" .. tag,
      keys(m) == "w:mon:ms")
    m = pa[2](mw, sh({ world_monsters = false, world_small_monsters = true,
      search = Q("horn") }), O, {})
    check("mtree: drop search skips the large one with only Small on" .. tag, #m == 0)
  end
  local mw2 = { monsters = mw.monsters, drops = mw.drops }
  core.world_markers_cached(mw2, sh({ world_monsters = false, world_small_monsters = false }), O, {})
  check("mtree: both off, monster category has no cells", stats.cell_entries.monster == 0)
  core.world_markers_cached(mw2, sh({ world_monsters = true, world_small_monsters = true }), O, {})
  check("mtree: both on, monster category has cells", stats.cell_entries.monster == 2)
  -- Large flipping with Small on re-fills the monster cells, never the grid
  local mw3 = { monsters = mw.monsters }
  local both = core.world_markers_cached(mw3, sh({ world_monsters = true, world_small_monsters = true }), O, {})
  local gb2 = stats.grid_builds
  local only_s = core.world_markers_cached(mw3, sh({ world_monsters = false, world_small_monsters = true }), O, {})
  check("mtree: Large off re-fills without a rebuild", keys(both) == "w:mon:ml,w:mon:ms"
    and keys(only_s) == "w:mon:ms" and stats.grid_builds == gb2 and stats.cell_entries.monster == 1)
  local both2 = core.world_markers_cached(mw3, sh({ world_monsters = true, world_small_monsters = true }), O, {})
  check("mtree: Large back on re-fills", keys(both2) == "w:mon:ml,w:mon:ms"
    and stats.grid_builds == gb2 and stats.cell_entries.monster == 2)

  -- monster kinds (SPEC 29.5)
  local function kmw()
    return { monsters = {
      { uid = "g", cid = 1, name = "Goblin", kind = "Goblin", pos = P(2), small = true },
      { uid = "h", cid = 2, name = "Hobgoblin", kind = "Hobgoblin", pos = P(3), small = true },
      { uid = "c", cid = 3, name = "Cyclops", kind = "Cyclops", pos = P(4), small = false },
      { uid = "ml", cid = 4, name = "Monster", kind = "Monster", pos = P(5), small = false },
      { uid = "ms", cid = 5, name = "Monster", kind = "Monster", pos = P(6), small = true } },
      drops = { [1] = { "Goblin Ear" }, [3] = { "Cyclops Eye" } } }
  end
  local function kshow(off, over)
    local o = { world_small_monsters = true, world_monster_off = off }
    for k, v in pairs(over or {}) do o[k] = v end
    return sh(o)
  end
  for _, pa in ipairs(paths) do
    local tag = " [" .. pa[1] .. "]"
    local kw = kmw()
    local m0, p0 = pa[2](kw, kshow(nil), O, {})
    local m, p = pa[2](kw, kshow({ small = { Goblin = true } }), O, {})
    check("kinds: Goblin off hides Goblin" .. tag, keys(m):find("w:mon:g", 1, true) == nil)
    check("kinds: Goblin off keeps Hobgoblin" .. tag, keys(m):find("w:mon:h", 1, true) ~= nil)
    check("kinds: Goblin off known unchanged" .. tag, p.monster.known == p0.monster.known
      and p.monster.known == 5)
    m = pa[2](kw, kshow({ small = { Goblin = true } }, { search = Q("goblin") }), O, {})
    check("kinds: query goblin finds only Hobgoblin" .. tag, keys(m) == "w:mon:h")
    m = pa[2](kw, kshow({ small = { Goblin = true } }, { search = Q("ear") }), O, {})
    check("kinds: drop search skips the off kind" .. tag, #m == 0)
    m = pa[2](kw, kshow(nil, { search = Q("ear") }), O, {})
    check("kinds: drop search finds it when on" .. tag, keys(m) == "w:mon:g")
    -- the class decides which kind is off
    m = pa[2](kw, kshow({ large = { Monster = true } }), O, {})
    local ks = keys(m)
    check("kinds: large Monster off hides only the large one" .. tag,
      ks:find("w:mon:ml", 1, true) == nil and ks:find("w:mon:ms", 1, true) ~= nil
      and ks:find("w:mon:c", 1, true) ~= nil)
    -- entries carry kind
    local all_kind = #p0.monster.entries == 5
    for _, e in ipairs(p0.monster.entries) do
      if type(e.kind) ~= "string" then all_kind = false end
    end
    check("kinds: every entry carries kind" .. tag, all_kind)
    -- a missing or non-string kind counts as Monster
    local nk = { monsters = {
      { uid = "n1", cid = 1, name = "A", pos = P(2), small = false },
      { uid = "n2", cid = 2, name = "B", kind = 5, pos = P(3), small = false },
      { uid = "n3", cid = 3, name = "C", kind = "Cyclops", pos = P(4), small = false } } }
    m = pa[2](nk, kshow({ large = { Monster = true } }), O, {})
    check("kinds: missing or non-string kind is Monster" .. tag, keys(m) == "w:mon:n3")
    local m_all = pa[2](nk, kshow(nil), O, {})
    local mk = {}
    for _, x in ipairs(m_all) do mk[x.key] = x.kind end
    check("kinds: marker kind falls back to Monster" .. tag, mk["w:mon:n1"] == "Monster"
      and mk["w:mon:n2"] == "Monster" and mk["w:mon:n3"] == "Cyclops")
    -- bad off sets show every kind
    for i, bad in ipairs({ {}, "x", { large = "x" }, { small = 7 } }) do
      m = pa[2](kw, kshow(bad), O, {})
      check("kinds: bad off set " .. i .. " shows all" .. tag, #m == 5)
    end
    m = pa[2](kw, kshow(nil), O, {})
    check("kinds: nil off set shows all" .. tag, #m == 5)
  end
  do
    local kw = kmw()
    core.world_markers_cached(kw, kshow(nil), O, {})
    local gb0 = stats.grid_builds
    local mo = core.world_markers_cached(kw, kshow({ small = { Goblin = true } }), O, {})
    local mi = core.world_markers_cached(kw, kshow({ small = {} }), O, {})
    check("kinds: untick hides on the cached path", keys(mo):find("w:mon:g", 1, true) == nil)
    check("kinds: re-tick brings it back", keys(mi):find("w:mon:g", 1, true) ~= nil)
    check("kinds: untick and re-tick run no grid rebuild", stats.grid_builds == gb0)
  end

  -- monster families (SPEC 30.5)
  local function fmw()
    return { monsters = {
      { uid = "g", cid = 1, name = "Goblin", kind = "Goblin", fam = "ch220", pos = P(2), small = true },
      { uid = "h", cid = 2, name = "Hobgoblin", kind = "Hobgoblin", fam = "ch220", pos = P(3), small = true },
      { uid = "w", cid = 3, name = "Wolf", kind = "Wolf", fam = "ch223", pos = P(4), small = true } } }
  end
  for _, pa in ipairs(paths) do
    local tag = " [" .. pa[1] .. "]"
    local fw = fmw()
    local _, p0 = pa[2](fw, kshow(nil), O, {})
    local m, p = pa[2](fw, kshow({ small = { ["fam:ch220"] = true } }), O, {})
    local ks = keys(m)
    check("fam: family off hides both kinds" .. tag,
      ks:find("w:mon:g", 1, true) == nil and ks:find("w:mon:h", 1, true) == nil)
    check("fam: family off keeps Wolf" .. tag, ks:find("w:mon:w", 1, true) ~= nil)
    check("fam: family off known unchanged" .. tag, p.monster.known == p0.monster.known
      and p.monster.known == 3)
    m = pa[2](fw, kshow({ small = { ["fam:ch220"] = true } }, { search = Q("goblin") }), O, {})
    check("fam: query goblin finds no monster when the family is off" .. tag, #m == 0)
    local by_key = {}
    for _, e in ipairs(p0.monster.entries) do by_key[e.key] = e.fam end
    check("fam: entries carry fam" .. tag, #p0.monster.entries == 3
      and by_key["w:mon:g"] == "ch220" and by_key["w:mon:w"] == "ch223")
    local bad = { monsters = {
      { uid = "b1", cid = 1, name = "A", kind = "A", fam = 5, pos = P(2), small = false },
      { uid = "b2", cid = 2, name = "B", kind = "B", pos = P(3), small = false } } }
    local _, pb = pa[2](bad, kshow(nil), O, {})
    local q_ok = #pb.monster.entries == 2
    for _, e in ipairs(pb.monster.entries) do
      if e.fam ~= "?" then q_ok = false end
    end
    check("fam: missing or non-string fam is ?" .. tag, q_ok)
  end
  do
    local fw = fmw()
    core.world_markers_cached(fw, kshow(nil), O, {})
    local gb0 = stats.grid_builds
    local mo = core.world_markers_cached(fw, kshow({ small = { ["fam:ch220"] = true } }), O, {})
    local mi = core.world_markers_cached(fw, kshow({ small = {} }), O, {})
    check("fam: untick hides on the cached path", keys(mo) == "w:mon:w")
    check("fam: re-tick brings them back", keys(mi) == "w:mon:g,w:mon:h,w:mon:w")
    check("fam: untick and re-tick run no grid rebuild", stats.grid_builds == gb0)
  end
  check("fam: family_name shortest", type(core.family_name) == "function"
    and core.family_name({ "Hobgoblin", "Goblin", "Chopper" }) == "Goblin")
  check("fam: family_name byte-order tie", type(core.family_name) == "function"
    and core.family_name({ "Garm", "Warg" }) == "Garm")
  check("fam: family_name leaves Monster out", type(core.family_name) == "function"
    and core.family_name({ "Minotaur", "Goreminotaur", "Monster" }) == "Minotaur")
  check("fam: family_name Monster alone", type(core.family_name) == "function"
    and core.family_name({ "Monster" }) == "Monster")
  check("fam: family_name empty is Other", type(core.family_name) == "function"
    and core.family_name({}) == "Other")

  -- per-family counts (SPEC 30.5.3, 30.5.4)
  local function fam_ser(p)
    local t = {}
    if type(p.monster.families) ~= "table" then return "none" end
    for i, f in ipairs(p.monster.families) do
      t[i] = tostring(f.fam) .. ":" .. tostring(f.small) .. ":" .. tostring(f.name) .. ":"
        .. tostring(f.shown) .. ":" .. tostring(f.known) .. ":" .. tostring(f.n_kinds)
    end
    return table.concat(t, ",")
  end
  local function kfam_ser(p)
    local t = {}
    if type(p.monster.kinds) ~= "table" then return "none" end
    for i, k in ipairs(p.monster.kinds) do
      t[i] = tostring(k.kind) .. "/" .. tostring(k.fam) .. ":" .. tostring(k.small) .. ":"
        .. tostring(k.shown) .. ":" .. tostring(k.known)
    end
    return table.concat(t, ",")
  end
  local function cfw()
    local w = fmw()
    w.monsters[#w.monsters + 1] = { uid = "c", cid = 4, name = "Cyclops", kind = "Cyclops",
      fam = "ch250", pos = P(5), small = false }
    return w
  end
  local want_fk = "Cyclops/ch250:false:1:1,Goblin/ch220:true:1:1,Hobgoblin/ch220:true:1:1,Wolf/ch223:true:1:1"
  local want_fam = "ch250:false:Cyclops:1:1:1,ch220:true:Goblin:2:2:2,ch223:true:Wolf:1:1:1"
  local want_fam_off = "ch250:false:Cyclops:1:1:1,ch220:true:Goblin:0:2:2,ch223:true:Wolf:1:1:1"
  local fam_paths_p = {}
  for _, pa in ipairs(paths) do
    local tag = " [" .. pa[1] .. "]"
    local _, p = pa[2](cfw(), kshow(nil), O, {})
    fam_paths_p[#fam_paths_p + 1] = p
    check("fam panel: kind rows and families" .. tag, type(p.monster.families) == "table"
      and kfam_ser(p) == want_fk and fam_ser(p) == want_fam)
    local _, po = pa[2](cfw(), kshow({ small = { ["fam:ch220"] = true } }), O, {})
    check("fam panel: family off shows 0 of known" .. tag, type(po.monster.families) == "table"
      and fam_ser(po) == want_fam_off)
    local mm = { monsters = {
      { uid = "a", cid = 1, name = "Goblin", kind = "Goblin", fam = "ch220", pos = P(2), small = true },
      { uid = "b", cid = 2, name = "Monster", kind = "Monster", fam = "ch220", pos = P(3), small = true },
      { uid = "c", cid = 3, name = "Wolf", kind = "Wolf", fam = "ch223", pos = P(4), small = true },
      { uid = "d", cid = 4, name = "Monster", kind = "Monster", fam = "ch223", pos = P(5), small = true } } }
    local _, pm = pa[2](mm, kshow(nil), O, {})
    local mon_fams = {}
    for _, k in ipairs(pm.monster.kinds or {}) do
      if k.kind == "Monster" then mon_fams[#mon_fams + 1] = tostring(k.fam) end
    end
    check("fam panel: Monster in two families is two rows" .. tag,
      table.concat(mon_fams, ",") == "ch220,ch223")
    -- fixtures without fam
    local _, pq = pa[2](kmw(), kshow(nil), O, {})
    local all_q = type(pq.monster.kinds) == "table" and #pq.monster.kinds == 5
    for _, k in ipairs(pq.monster.kinds or {}) do
      if k.fam ~= "?" then all_q = false end
    end
    check("fam panel: kinds without fam carry ?" .. tag, all_q)
    check("fam panel: no-fam fixture has one Other row per class" .. tag,
      type(pq.monster.families) == "table"
      and fam_ser(pq) == "?:false:Other:2:2:2,?:true:Other:3:3:3")
    local qw = kmw()
    qw.monsters[#qw.monsters + 1] = { uid = "z", cid = 9, name = "Z", kind = "Zed", fam = 5,
      pos = P(7), small = false }
    local _, pz = pa[2](qw, kshow(nil), O, {})
    check("fam panel: fam of 5 counts in the ? row" .. tag, type(pz.monster.families) == "table"
      and fam_ser(pz) == "?:false:Other:3:3:3,?:true:Other:3:3:3")
  end
  check("fam panel: both paths agree", type(fam_paths_p[1].monster.families) == "table"
    and fam_ser(fam_paths_p[1]) == fam_ser(fam_paths_p[2])
    and kfam_ser(fam_paths_p[1]) == kfam_ser(fam_paths_p[2]))
  for _, pa in ipairs(paths) do
    for _, order in ipairs({ { "ch230", "ch220" }, { "ch220", "ch230" } }) do
      local tw = { monsters = {
        { uid = "a", cid = 1, name = "Monster", kind = "Monster", fam = order[1], pos = P(2), small = true },
        { uid = "b", cid = 2, name = "Monster", kind = "Monster", fam = order[2], pos = P(3), small = true } } }
      local _, pt = pa[2](tw, kshow(nil), O, {})
      local ks = {}
      for _, k in ipairs(pt.monster.kinds or {}) do ks[#ks + 1] = tostring(k.fam) end
      check("fam panel: same name ordered by fam [" .. pa[1] .. "] " .. order[1],
        type(pt.monster.families) == "table"
        and fam_ser(pt) == "ch220:true:Monster:1:1:1,ch230:true:Monster:1:1:1"
        and table.concat(ks, ",") == "ch220,ch230")
    end
  end

  -- per-kind counts (SPEC 29.5.3)
  local function kinds_ser(p)
    local t = {}
    if type(p.monster.kinds) ~= "table" then return "none" end
    for i, k in ipairs(p.monster.kinds) do
      t[i] = tostring(k.kind) .. ":" .. tostring(k.small) .. ":" .. tostring(k.shown)
        .. ":" .. tostring(k.known)
    end
    return table.concat(t, ",")
  end
  local want_kinds = "Cyclops:false:1:1,Monster:false:1:1,Goblin:true:0:1,Hobgoblin:true:1:1,Monster:true:1:1"
  for _, pa in ipairs(paths) do
    local tag = " [" .. pa[1] .. "]"
    local kw = kmw()
    local _, p = pa[2](kw, kshow({ small = { Goblin = true } }), O, {})
    check("kinds panel: order and numbers" .. tag,
      type(p.monster.kinds) == "table" and kinds_ser(p) == want_kinds)
    local gw = { monsters = {
      { uid = "a", cid = 1, name = "Goblin", kind = "Goblin", pos = P(2), small = true },
      { uid = "b", cid = 1, name = "Goblin", kind = "Goblin", pos = P(3), small = true },
      { uid = "c", cid = 1, name = "Goblin", kind = "Goblin", pos = P(4), small = true } } }
    _, p = pa[2](gw, kshow(nil, { world_max_markers = 1 }), O, {})
    check("kinds panel: cap leaves shown below known" .. tag,
      type(p.monster.kinds) == "table" and kinds_ser(p) == "Goblin:true:1:3")
    local hw = { monsters = {
      { uid = "z", cid = 9, name = "Goblin", kind = "Goblin", pos = P(300), small = true } } }
    for i = 1, 11 do
      hw.monsters[#hw.monsters + 1] = { uid = "h" .. i, cid = 2, name = "Hobgoblin",
        kind = "Hobgoblin", pos = P(i), small = true }
    end
    local _, hp = pa[2](hw, kshow(nil), O, {})
    local gob_row = false
    for _, e in ipairs(hp.monster.entries) do
      if e.kind == "Goblin" then gob_row = true end
    end
    check("kinds panel: a far kind still has its entry" .. tag, gob_row)
    _, p = pa[2](kw, kshow(nil, { world_small_monsters = false }), O, {})
    local no_small = type(p.monster.kinds) == "table" and #p.monster.kinds == 2
    if no_small then
      for _, k in ipairs(p.monster.kinds) do if k.small then no_small = false end end
    end
    check("kinds panel: Small off lists only large kinds" .. tag, no_small)
  end
  do
    local kw = kmw()
    local _, pu = core.world_markers(kw, kshow({ small = { Goblin = true } }), O, {})
    local _, pc = core.world_markers_cached(kw, kshow({ small = { Goblin = true } }), O, {})
    check("kinds panel: both paths give the same array", type(pu.monster.kinds) == "table"
      and kinds_ser(pu) == kinds_ser(pc))
  end
end

-- first token (SPEC 28.9.3)
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local O = P(0, 0, 0)
  local Q = core.parse_query
  local SHB = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = false, world_beetles = true,
    world_show_opened = false, world_undiscovered = false, world_max_markers = 300 }
  local function sh(over)
    local s = {}
    for k, v in pairs(SHB) do s[k] = v end
    for k, v in pairs(over or {}) do s[k] = v end
    return s
  end
  local function keyset(ms)
    local t = {}
    for _, m in ipairs(ms) do t[m.key] = m end
    return t
  end
  local function keys(ms)
    local t = {}
    for i, m in ipairs(ms) do t[i] = m.key end
    table.sort(t)
    return table.concat(t, ",")
  end
  local function ft() return { uid = "t1", pos = P(5, 0, 5), name = "Finder's Token spot",
    state = "collected", first_seeker = true } end
  local function chest(uid, x) return { uid = uid, pos = P(x), state = "unopened" } end
  for _, pa in ipairs({ { "uncached", core.world_markers },
    { "cached", core.world_markers_cached } }) do
    local tag = " [" .. pa[1] .. "]"
    local w = { first_token = ft() }
    local ms, panel = pa[2](w, sh(), O, {})
    local m = keyset(ms)["w:tok1:t1"]
    check("tok1 shown" .. tag, m ~= nil)
    check("tok1 cat token" .. tag, m ~= nil and m.cat == "token")
    check("tok1 not done" .. tag, m ~= nil and not m.done and not m.faded and not m.hidden)
    check("tok1 not counted" .. tag, panel.token.shown == 0 and panel.token.known == 0)
    check("tok1 not in panel rows" .. tag, #panel.token.entries == 0)
    check("tok1 panel first" .. tag, panel.token.first ~= nil
      and panel.token.first.key == "w:tok1:t1")
    check("tok1 marker fields" .. tag, m ~= nil and m.first_seeker == true
      and m.world_ord == nil and m.pos.x == 5 and m.pos.z == 5
      and m.label == "Finder's Token spot")
    check("tok1 absent without the world entry" .. tag,
      keyset((pa[2]({ chests = { chest("c", 1) } }, sh(), O, {})))["w:tok1:t1"] == nil)
    ms = pa[2](w, sh({ world_max_markers = 0 }), O, {})
    check("tok1 cap 0" .. tag, keyset(ms)["w:tok1:t1"] ~= nil)
    -- no cap slot: the kept chests are the same with and without it
    local cw = { chests = { chest("ca", 1), chest("cb", 2), chest("cc", 3) } }
    local base = pa[2](cw, sh({ world_max_markers = 2 }), O, {})
    cw = { chests = cw.chests, first_token = ft() }
    local with = pa[2](cw, sh({ world_max_markers = 2 }), O, {})
    check("tok1 takes no cap slot" .. tag, keys(base) == "w:chest:ca,w:chest:cb"
      and keys(with) == "w:chest:ca,w:chest:cb,w:tok1:t1")
    -- searches do not filter it
    local gw = { first_token = ft(), monsters = { { uid = "g", cid = 1, name = "Goblin", pos = P(2) } } }
    ms = pa[2](gw, sh({ search = Q("seeker") }), O, {})
    check("tok1 stays under a query" .. tag, keyset(ms)["w:tok1:t1"] ~= nil)
    ms = pa[2](gw, sh({ search = Q("goblin") }), O, {})
    check("tok1 stays under another query" .. tag,
      keys(ms) == "w:mon:g,w:tok1:t1")
    -- Tokens on: the spot draws once, as the first token
    -- the world marks the ordinary token at the spot first_seeker
    local tw = { first_token = ft(), tokens = { { uid = "t1", pos = P(5, 0, 5), name = "Token",
      state = "collected", first_seeker = true }, { uid = "t2", pos = P(9), name = "Other", state = "not" } } }
    ms, panel = pa[2](tw, sh({ world_tokens = true, world_show_opened = true }), O, {})
    local at_spot = 0
    for _, mm in ipairs(ms) do
      if mm.pos.x == 5 and mm.pos.z == 5 then at_spot = at_spot + 1 end
    end
    check("tok1 draws once with Tokens on" .. tag, at_spot == 1
      and keyset(ms)["w:tok1:t1"] ~= nil and keyset(ms)["w:tok:t1"] == nil
      and keyset(ms)["w:tok:t2"] ~= nil)
    check("tok1 token still known" .. tag, panel.token.known == 2 and panel.token.shown == 1)
    ms = pa[2](w, sh({ world_first_token = false }), O, {})
    check("tok1 off" .. tag, keyset(ms)["w:tok1:t1"] == nil)
    -- the spot is not a search result: it is kept as a marker but listed nowhere
    ms = pa[2](w, sh({ search = Q("minotaur") }), O, {})
    check("tok1 kept under a query that matches nothing" .. tag, keyset(ms)["w:tok1:t1"] ~= nil)
    check("tok1 is not a search result row" .. tag, #core.world_rows(ms, {}, O) == 0)
    -- a first_seeker entry never becomes a marker, with or without a query
    local hw = { first_token = { uid = "h1", pos = P(7), name = "Spot", state = "not" },
      tokens = { { uid = "h1", pos = P(7), name = "Hidden", state = "not",
      first_seeker = true }, { uid = "h2", pos = P(8), name = "Shown", state = "not" } } }
    ms = pa[2](hw, sh({ world_tokens = true }), O, {})
    check("first_seeker entry hidden" .. tag, keys(ms) == "w:tok1:h1,w:tok:h2")
    ms = pa[2](hw, sh({ world_tokens = true, world_first_token = false }), O, {})
    check("first_seeker entry shown when the spot is off" .. tag,
      keys(ms) == "w:tok:h1,w:tok:h2")
    ms = pa[2](hw, sh({ world_tokens = true, search = Q("hidden") }), O, {})
    check("first_seeker entry hidden under a query" .. tag, keys(ms) == "w:tok1:h1")
  end
  check("is_result: ordinary marker", core.is_result({ cat = "chest" }) == true)
  check("is_result: route stop", core.is_result({ cat = "route_stop" }) == false)
  check("is_result: hint pin", core.is_result({ cat = "hint_pin" }) == false)
  check("is_result: first seeker", core.is_result({ cat = "token", first_seeker = true }) == false)
end

-- v19 (SPEC 32): quest focus
do
  local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local function Q(t) return core.parse_query(t) end
  local SH = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_max_markers = 300, world_origin = P(0, 0, 0), map_origin = P(0, 0, 0),
    world_show_opened = false, world_undiscovered = false }
  local function run(world, search, over, ex)
    local o = { acceptable = {}, names = {} }
    for k, v in pairs(ex or {}) do o[k] = v end
    local a = fake_adapter(o)
    if o.generic then a.is_generic = function(c) return o.generic[c] == true end end
    if o.main then a.is_side = function(q) return not o.main[q] end end
    if o.quest_step then a.quest_step = o.quest_step end
    local show = { startable = true, in_progress = true, quest_items = true,
      world = world, search = search }
    for k, v in pairs(SH) do show[k] = v end
    for k, v in pairs(over or {}) do show[k] = v end
    return core.compute(a, show)
  end
  local function has(list, key)
    for _, m in ipairs(list or {}) do if m.key == key then return m end end
    return nil
  end
  local function keys(list, prefix)
    local out = {}
    for _, m in ipairs(list or {}) do
      if m.key:sub(1, #prefix) == prefix then out[#out + 1] = m.key end
    end
    table.sort(out)
    return table.concat(out, ",")
  end

  check("fo 1: marker_cid focus_npc", core.marker_cid({ key = "n:12", cat = "focus_npc", cid = 12 }) == 12
    and core.marker_cid({ key = "f:4", cat = "focus_place", place = 4 }) == nil
    and core.marker_cid({ key = "w:npc:9", cat = "npc_search", cid = 9 }) == nil)
  check("fo 2: focus markers are not results", core.is_result({ cat = "focus_npc" }) == false
    and core.is_result({ cat = "focus_place" }) == false)
  check("fo 3: row label [F]", core.row_label({ qid = 3, name = "A", state = "locked" }, nil, true)
    == "[F] A - locked###qd_3"
    and core.row_label({ qid = 3, name = "A", state = "locked" }, nil, false) == "A - locked###qd_3")
  local function sg(dim) return (core.signature({ { key = "k", pos = P(1), qids = {}, label = "L",
    cat = "chest", dim = dim } }, {})) end
  check("fo 4: signature hashes dim", sg(true) ~= sg(nil) and sg(false) == sg(nil))
  local sel = core.minimap_markers({ { key = "f:1", cat = "focus_place", pos = P(3) },
    { key = "c:5", cat = "startable", pos = P(50) }, { key = "w:chest:a", cat = "chest", pos = P(1) },
    { key = "n:7", cat = "focus_npc", pos = P(60) } }, P(0), 100, 10)
  local sk = {}
  for _, m in ipairs(sel) do sk[#sk + 1] = m.key end
  check("fo 5: minimap tiers", table.concat(sk, ",") == "c:5,n:7,f:1,w:chest:a")
  check("fo 6: item walk with focus", core.item_walk_wanted({ focus_on = true }) == true
    and core.item_walk_mode({ focus_on = true }) == "full"
    and core.item_walk_wanted({ focus_on = false }) == false)
  local fa = fake_adapter({ states = { [12] = "completed", [13] = "failed", [14] = "canceled" } })
  check("fo 7: active set", table.concat(core.focus_active({ 11, 12, 13, 14, 15, 11 }, 15, fa), ",") == "15,11"
    and #core.focus_active({}, nil, fa) == 0
    and table.concat(core.focus_active(nil, 11, fa), ",") == "11"
    and #core.focus_active({ 0, -2 }, 12, fa) == 0)
  local r1 = { cid = 12, name = "Mara", stops = { { from = 6, to = 9, pos = P(5), discovered = true } } }
  local r2 = { cid = 13, name = "Bo", stops = { { from = 1, to = 2, pos = P(8), discovered = true } } }
  local r = run({}, nil, { routes = { r1, r2, { cid = 14, name = "X", err = "no schedule" } } })
  check("fo 8: every route's stops", keys(r.markers, "r:") == "r:12:1,r:13:1"
    and has(r.markers, "r:13:1").label == "Bo 01-02")
  r = run({}, nil, { route = r2 })
  check("fo 8b: the single route field is not read", has(r.markers, "r:13:1") == nil)

  local calls = 0
  local ra = fake_adapter({ objectives = { [20] = { 7, 8, 0 } }, casts = { [20] = { 7, 9 }, [30] = { 4 } },
    item_needs = { [20] = { { id = 300 }, { id = 301 } } } })
  ra.is_generic = function(c) return c == 9 end
  local base_cast = ra.cast_ids
  ra.cast_ids = function(q) calls = calls + 1; return base_cast(q) end
  local rel = { [20] = { cast = { 9, 11 }, npcs = { 12, 7 }, items = { 302, 300 },
      dest = { { cid = 13 }, { key = 44 }, { key = 45 } } },
    [30] = { cast = {}, npcs = { 15 }, items = {}, dest = { { key = 44 } } } }
  local places = { [44] = P(1), [46] = P(2) }
  local live = { givers = { [20] = 5, [30] = 6 }, prog = { [20] = true } }
  local function j(t) return table.concat(t, ",") end
  local rs = core.related_sets(ra, { 20, 30 }, rel, places, live)
  check("rs 1: npcs order", j(rs[20].npcs) == "5,7,8,11,12,13")
  check("rs 2: step npcs in progress = objectives", j(rs[20].step_npcs) == "7,8")
  check("rs 3: items file then live", j(rs[20].items) == "302,300,301")
  check("rs 4: places with a position", j(rs[20].places) == "44")
  check("rs 5: not in progress: step npc is the giver", j(rs[30].npcs) == "6,4,15"
    and j(rs[30].step_npcs) == "6" and #rs[30].items == 0 and j(rs[30].places) == "44")
  local n0 = calls
  check("rs 6: memo returns the same table", core.related_sets(ra, { 20, 30 }, rel, places, live) == rs
    and calls == n0)
  check("rs 7: new places recompute", core.related_sets(ra, { 20, 30 }, rel, { [44] = P(1) }, live) ~= rs)
  check("rs 8: a new giver recomputes", core.related_sets(ra, { 20, 30 }, rel, places,
    { givers = { [20] = 99, [30] = 6 }, prog = live.prog })[20].npcs[1] == 99)
  local rn = core.related_sets(ra, { 20 }, nil, places, live)
  check("rs 9: no file: live parts only", j(rn[20].npcs) == "5,7,8" and j(rn[20].items) == "300,301"
    and #rn[20].places == 0)
  local rm = core.related_sets(ra, { 40 }, rel, places, { givers = {}, prog = {} })
  check("rs 10: quest with nothing", rm[40] ~= nil and #rm[40].npcs == 0 and #rm[40].step_npcs == 0)

  -- each memo input alone forces a recompute, from a state that just hit the memo
  local function base()
    local b = core.related_sets(ra, { 20, 30 }, rel, places, live)
    return b, core.related_sets(ra, { 20, 30 }, rel, places, live) == b
  end
  local b, hit = base()
  check("rs 11: baseline hits the memo", hit)
  local rp = core.related_sets(ra, { 20, 30 }, rel, places, { givers = live.givers, prog = {} })
  check("rs 12: a changed in-progress flag recomputes", rp ~= b and j(rp[20].step_npcs) == "7,8,5")
  b, hit = base()
  local orig_oc = ra.objective_cids
  local fresh_obj = { [20] = { 7, 8, 0 } }
  ra.objective_cids = function(q) return fresh_obj[q] end
  check("rs 13: a new objective array recomputes",
    hit and core.related_sets(ra, { 20, 30 }, rel, places, live) ~= b)
  ra.objective_cids = orig_oc
  b, hit = base()
  local orig_needs = ra.item_needs
  ra.item_needs = function() return { [20] = { { id = 300 }, { id = 301 } } } end
  check("rs 14: a new needs table recomputes",
    hit and core.related_sets(ra, { 20, 30 }, rel, places, live) ~= b)
  ra.item_needs = orig_needs
  -- two quests alike in every other input, so only the order differs
  local live2 = { givers = { [60] = 5, [61] = 5 }, prog = {} }
  local b2 = core.related_sets(ra, { 60, 61 }, nil, places, live2)
  check("rs 15: the same ids in another order recompute",
    core.related_sets(ra, { 60, 61 }, nil, places, live2) == b2
    and core.related_sets(ra, { 61, 60 }, nil, places, live2) ~= b2)
  b, hit = base()
  local rel2 = { [20] = rel[20], [30] = rel[30] }
  check("rs 16: a new quest file recomputes",
    hit and core.related_sets(ra, { 20, 30 }, rel2, places, live) ~= b)
  local rsort = { [50] = { cast = {}, npcs = {}, items = {}, dest = { { key = 46 }, { key = 44 } } } }
  local rso = core.related_sets(ra, { 50 }, rsort, places, { givers = {}, prog = {} })
  check("rs 17: places come back ascending", j(rso[50].places) == "44,46")

  -- Task 3.6: focus in the quest loop and the item markers
  local qx = { acceptable = { 20, 21 }, hints = { [20] = 5, [21] = 6 },
    npc_pos = { [5] = P(1), [6] = P(2) }, names = { [20] = "Twenty", [21] = "TwentyOne" } }
  local r = run({}, nil, { startable = false }, qx)
  check("fq 1a: hidden category, no focus: no marker", has(r.markers, "c:5") == nil and r.focus == nil)
  r = run({}, nil, { startable = false, focus_qids = { 20 } }, qx)
  check("fq 1: focused quest passes a hidden category", has(r.markers, "c:5") ~= nil
    and has(r.markers, "c:6") == nil)
  r = run({}, Q("zzz"), { focus_qids = { 20 } }, qx)
  check("fq 2: focused quest marker skips the search", has(r.markers, "c:5") ~= nil)
  r = run({}, nil, { focus_qids = { 21, 20 }, focus_tracked_qid = 20 }, qx)
  check("fq 3: result.focus", r.focus ~= nil and table.concat(r.focus.active, ",") == "20,21"
    and r.focus.quests[20].npcs[1] == 5 and table.concat(r.focus.quests[21].step_npcs, ",") == "6")
  local qc = { acceptable = { 22 }, casts = { [22] = { 8, 7 } }, npc_pos = { [7] = P(3) },
    names = { [22] = "TwentyTwo" } }
  r = run({}, nil, { focus_qids = { 22 } }, qc)
  check("fq 4: giver from the c: marker before the first candidate",
    has(r.markers, "c:7") ~= nil and table.concat(r.focus.quests[22].step_npcs, ",") == "7")
  qx.states = { [20] = "completed" }
  r = run({}, nil, { completed = true, focus_qids = { 20 } }, qx)
  check("fq 5: a completed quest is not active", r.focus == nil)
  qx.states = nil
  local qi = { progressing = { 30 }, hints = { [30] = 5 }, npc_pos = { [5] = P(1) },
    names = { [30] = "Thirty" }, item_needs = { [30] = { { id = 300 } } },
    item_locs = { { id = 300, pos = P(40), src = "placed" } }, item_names = { [300] = "Gem" } }
  r = run({}, nil, { quest_items = false, focus_qids = { 30 } }, qi)
  check("fq 6: focused needs with Quest items off", has(r.markers, "i:300:10:0") ~= nil)
  r = run({}, nil, { in_progress = false, focus_qids = { 30 } }, qi)
  check("fq 6b: and with In progress off", has(r.markers, "i:300:10:0") ~= nil and has(r.markers, "c:5") ~= nil)
  r = run({}, nil, { quest_items = false }, qi)
  check("fq 6c: no focus, Quest items off: none", has(r.markers, "i:300:10:0") == nil)
  local many = { progressing = { 30, 31 }, hints = { [30] = 5, [31] = 6 },
    npc_pos = { [5] = P(1), [6] = P(2) }, names = { [30] = "Thirty", [31] = "ThirtyOne" },
    item_needs = { [30] = { { id = 300 } }, [31] = { { id = 301 } } }, item_locs = {} }
  for i = 1, 40 do
    many.item_locs[#many.item_locs + 1] = { id = 300, pos = P(i * 8), src = "placed" }
    many.item_locs[#many.item_locs + 1] = { id = 301, pos = P(i * 8, 0, 400), src = "placed" }
  end
  local function count_id(rr, id)
    local n = 0
    for _, m in ipairs(rr.markers) do if m.item_id == id then n = n + 1 end end
    return n
  end
  -- dim, so Task 3.8's hide pass keeps quest 31's items
  r = run({}, nil, { focus_qids = { 30 }, focus_unrelated = 1 }, many)
  check("fq 7: related needs take no cap slot", count_id(r, 300) == 40 and count_id(r, 301) == 32)
  local ords, dup = {}, false
  for _, m in ipairs(r.markers) do
    if m.item_id then
      local k = m.item_id .. ":" .. m.item_ord
      if ords[k] then dup = true end
      ords[k] = true
    end
  end
  check("fq 7b: one item_ord sequence", not dup)
  r = run({}, Q("zzz"), { focus_qids = { 30 } }, many)
  check("fq 7c: related needs skip the search", count_id(r, 300) == 40 and count_id(r, 301) == 0)
  local fk, n300 = true, 0
  for _, m in ipairs(r.markers) do
    if m.item_id == 300 then n300 = n300 + 1; if m.focus_kept ~= true then fk = false end end
  end
  check("fq 7d: item markers kept only by focus are flagged", n300 == 40 and fk)
  r = run({}, Q("zzz"), { focus_qids = { 20 } }, qx)
  local c5 = has(r.markers, "c:5") or {}
  check("fq 2b: a quest marker kept only by focus is not a search result",
    c5.focus_kept == true and core.is_result(c5) == false)
  r = run({}, Q("twenty"), { focus_qids = { 20 } }, qx)
  c5 = has(r.markers, "c:5")
  check("fq 2c: a matching focused startable giver stays objective, not a result",
    c5 ~= nil and c5.objective == true and core.is_result(c5) == false)
  local qm = { progressing = { 50 }, main = { [50] = true }, item_needs = { [50] = { { id = 500 } } },
    item_locs = { { id = 500, pos = P(40), src = "placed" } }, item_names = { [500] = "Seal" } }
  r = run({}, nil, { focus_tracked_qid = 50 }, qm)
  check("fq 8: a focused main quest's needs get item markers", has(r.markers, "i:500:10:0") ~= nil)
  r = run({}, nil, {}, qm)
  check("fq 8b: no focus: a main quest's needs get none", has(r.markers, "i:500:10:0") == nil)
  r = run({}, nil, { focus_tracked_qid = 50,
    quest_rel = { [50] = { cast = {}, npcs = { 12 }, items = {}, dest = {} } } }, {})
  check("fq 9: a tracked quest outside every list gets the file's related set",
    r.focus ~= nil and table.concat(r.focus.active, ",") == "50"
    and table.concat(r.focus.quests[50].npcs, ",") == "12" and #r.focus.quests[50].step_npcs == 0)
  local qo = { progressing = { 30 }, casts = { [30] = { 9 } }, objectives = { [30] = { 8 } },
    npc_pos = { [8] = P(2), [9] = P(3) }, objective_pos = { [8] = P(2) }, names = { [30] = "Thirty" } }
  r = run({}, nil, { focus_qids = { 30 } }, qo)
  check("fq 10: in progress, the objective marker is not the giver", has(r.markers, "c:8") ~= nil
    and table.concat(r.focus.quests[30].npcs, ",") == "9,8"
    and table.concat(r.focus.quests[30].step_npcs, ",") == "8")
  r = run({}, nil, { quest_items = false, focus_qids = { 30 } }, many)
  check("fq 6d: unfocused needs stay off with Quest items off",
    count_id(r, 300) == 40 and count_id(r, 301) == 0)
  local qg = { acceptable = { 20 }, hints = { [20] = 9001 }, npc_pos = { [9001] = P(1) },
    names = { [20] = "Twenty" } }
  local sw = { sellers = { { shop = 5, item = 2, item_name = "Elixir", cid = 9001, npc = "N",
    qids = {}, quest = "Q", pos = P(4), maybe_locked = false, discovered = true } } }
  r = run(sw, Q("elixir"), { focus_qids = { 20 } }, qg)
  local sell = has(r.markers, "w:sell:5:2")
  check("fq 11: a focus-kept quest marker does not absorb a matching seller",
    sell ~= nil and core.is_result(sell) == true)

  -- Task 3.7: related world entries, held apart from the cap and the search
  local function wset()
    return { chests = {
        { uid = "g1", pos = P(10), state = "unopened", gate_qids = { 20 }, kinds = { "quest" } },
        { uid = "i1", pos = P(20), state = "unopened", item = 302 },
        { uid = "i2", pos = P(30), state = "unopened", item_ids = { 7, 302 } },
        { uid = "o1", pos = P(35), state = "opened", gate_qids = { 20 } },
        { uid = "u1", pos = P(5), state = "unopened" } },
      sellers = { { shop = 9, item = 400, item_name = "Herb", cid = 77, npc = "Vendor",
        qids = { 20 }, quest = "Twenty", pos = P(15) },
        { shop = 9, item = 401, item_name = "Salt", cid = 77, npc = "Vendor",
        qids = { 99 }, quest = "Other", pos = P(16) } } }
  end
  local wq = { acceptable = { 20 }, hints = { [20] = 5 }, npc_pos = { [5] = P(1) }, names = { [20] = "Twenty" } }
  local wrel = { [20] = { cast = {}, npcs = {}, items = { 302 }, dest = {} } }
  local REL = "w:chest:g1,w:chest:i1,w:chest:i2,w:sell:9:400"
  local function relkeys(list)
    local t = {}
    for _, m in ipairs(list or {}) do if m.related then t[#t + 1] = m.key end end
    table.sort(t)
    return table.concat(t, ",")
  end
  r = run(wset(), nil, { world_chests = false, world_sellers = false, focus_qids = { 20 }, quest_rel = wrel }, wq)
  check("fw 1: related entries of off categories", relkeys(r.markers) == REL
    and has(r.markers, "w:chest:u1") == nil and has(r.markers, "w:chest:o1") == nil)
  check("fw 1b: also in the full-map pass", relkeys(r.fullmap_world) == REL)
  check("fw 1c: not counted in the panel", r.world.chest.shown == 0 and r.world.seller.shown == 0)
  r = run(wset(), nil, { world_max_markers = 0, focus_qids = { 20 }, quest_rel = wrel }, wq)
  check("fw 2: no cap slot", relkeys(r.markers) == REL and has(r.markers, "w:chest:u1") == nil)
  r = run(wset(), Q("zzz"), { focus_qids = { 20 }, quest_rel = wrel }, wq)
  check("fw 3: no search filter", relkeys(r.markers) == REL)
  r = run(wset(), nil, { world_kind_quest = false, focus_qids = { 20 }, quest_rel = wrel }, wq)
  check("fw 4: kind filters do not hide a related chest", has(r.markers, "w:chest:g1") ~= nil)
  -- dim, so Task 3.8's hide pass keeps the unrelated u1 and seller 401 in these two checks
  r = run(wset(), nil, { focus_qids = { 20 }, quest_rel = wrel, focus_unrelated = 1 }, wq)
  local n_g1, ords, odup = 0, {}, false
  for _, m in ipairs(r.markers) do
    if m.key == "w:chest:g1" then n_g1 = n_g1 + 1 end
    if m.world_ord then
      if ords[m.world_ord] then odup = true end
      ords[m.world_ord] = true
    end
  end
  check("fw 5: drawn once, world_ord unique", n_g1 == 1 and not odup
    and has(r.markers, "w:chest:u1") ~= nil and not has(r.markers, "w:chest:u1").related)
  check("fw 6: seller markers carry cid", has(r.markers, "w:sell:9:401").cid == 77)
  r = run(wset(), nil, { world_chests = false, world_sellers = false }, wq)
  check("fw 7: no focus: off categories build nothing", relkeys(r.markers) == ""
    and has(r.markers, "w:chest:g1") == nil)
  local fx = { qids = { [20] = true }, items = { [302] = true }, key = "20|302" }
  local um = core.world_markers(wset(), { world_chests = false, world_sellers = false }, P(0), {}, nil, fx)
  check("fw 8: uncached path matches", relkeys(um) == REL)
  local sw2 = { shops = { { shop = 3, pos = P(12), items = { { id = 1, name = "Rope" } }, npc = "Bo", cid = 55 } } }
  r = run(sw2, nil, { world_shops = true })
  check("fw 9: shop markers carry cid", has(r.markers, "w:shop:3") ~= nil and has(r.markers, "w:shop:3").cid == 55)
  r = run(wset(), Q("herb"), { focus_qids = { 20 }, quest_rel = wrel }, wq)
  local s400, g1 = has(r.markers, "w:sell:9:400"), has(r.markers, "w:chest:g1") or {}
  check("fw 3b: under a search only the related entries that match are results",
    s400 ~= nil and s400.focus_kept == nil and core.is_result(s400) == true
    and g1.focus_kept == true and core.is_result(g1) == false)
  -- fix round 1: cover, cache invalidation, uncached skip
  local wn = wset()
  wn.sellers[2] = nil   -- the unrelated seller of cid 77 would cover it too
  wn.npcs = { { cid = 77, name = "Vendor", pos = P(15), alive = true, discovered = true } }
  r = run(wn, Q("vendor"), { focus_qids = { 20 }, quest_rel = wrel }, wq)
  check("fw 10: a related seller covers its NPC match", has(r.markers, "w:sell:9:400") ~= nil
    and has(r.markers, "w:npc:77") == nil)
  local cw = wset()
  local cs = { world_chests = false, world_sellers = false }
  local ca = core.world_markers_cached(cw, cs, P(0), {}, nil, nil,
    { qids = { [20] = true }, items = {}, key = "20|" })
  local cb = core.world_markers_cached(cw, cs, P(0), {}, nil, nil,
    { qids = { [99] = true }, items = {}, key = "99|" })
  check("fw 11: a new fx key rebuilds the cached related list",
    relkeys(ca) == "w:chest:g1,w:sell:9:400" and relkeys(cb) == "w:sell:9:401")
  local uo = core.world_markers(wset(), {}, P(0), {}, nil, fx)
  local ng = 0
  for _, m in ipairs(uo) do if m.key == "w:chest:g1" then ng = ng + 1 end end
  check("fw 8b: uncached, categories on: a related chest is drawn once", ng == 1)

  -- Task 3.8: focus NPC and destination markers, the hide/dim pass, counts
  local function npc(cid, name, pos)
    return { cid = cid, name = name, pos = pos, alive = true, discovered = true }
  end
  local fq = { acceptable = { 20, 21 }, hints = { [20] = 5, [21] = 6 },
    npc_pos = { [5] = P(1), [6] = P(2), [12] = P(30), [13] = P(40), [17] = P(45) },
    dead = { [14] = true }, names = { [20] = "Twenty", [21] = "TwentyOne" },
    npc_names = { [13] = "Mara" } }
  local frel = { [20] = { cast = {}, npcs = { 12, 13, 14, 16, 17 }, items = {},
    dest = { { key = 44 }, { key = 45 } } }, [21] = { cast = {}, npcs = {}, items = {}, dest = { { key = 44 } } } }
  local fw = { npcs = { { cid = 12, name = "Brant" } }, focus_places = { [44] = P(50) } }
  local FO = { focus_qids = { 20 }, quest_rel = frel, reveal_gate_names = true }
  r = run(fw, nil, FO, fq)
  local n12, n13 = has(r.markers, "n:12"), has(r.markers, "n:13")
  check("ff 1: focus NPC labels", n12 and n12.cat == "focus_npc" and n12.cid == 12 and n12.label == "Brant"
    and n13 and n13.label == "Mara" and has(r.markers, "n:17").label == "NPC 17")
  check("ff 2: dead, positionless and covered NPCs get none", has(r.markers, "n:14") == nil
    and has(r.markers, "n:16") == nil and has(r.markers, "n:5") == nil
    and table.concat(r.focus_counts.no_pos, ",") == "16")
  local f44 = has(r.markers, "f:44")
  check("ff 3: destination marker", f44 and f44.cat == "focus_place" and f44.place == 44
    and f44.label == "Twenty" and f44.pos.x == 50 and has(r.markers, "f:45") == nil)
  check("ff 4: hide drops unrelated", has(r.markers, "c:6") == nil and has(r.markers, "c:5") ~= nil)
  check("ff 5: counts, hide", r.focus_counts.related == 5 and r.focus_counts.added == 4
    and r.focus_counts.hidden == 1 and r.focus_counts.dimmed == 0)
  r = run(fw, nil, { focus_qids = { 20, 21 }, quest_rel = frel, reveal_gate_names = true }, fq)
  check("ff 6: one place marker for two quests", has(r.markers, "f:44").label == "Twenty / TwentyOne"
    and keys(r.markers, "f:") == "f:44")
  local FD = { focus_qids = { 20 }, quest_rel = frel, reveal_gate_names = true, focus_unrelated = 1 }
  r = run(fw, nil, FD, fq)
  check("ff 7: dim keeps and marks", has(r.markers, "c:6").dim == true and not has(r.markers, "c:5").dim
    and r.focus_counts.dimmed == 1 and r.focus_counts.hidden == 0)
  r = run(fw, Q("twentyone"), FO, fq)
  check("ff 8: search results stay", has(r.markers, "c:6") ~= nil and not has(r.markers, "c:6").dim
    and has(r.markers, "c:5") ~= nil)
  r = run(fw, nil, { focus_qids = { 20 }, quest_rel = frel, hint_pins = {
    { qid = 21, i = 1, pos = P(3), label = "x" }, { qid = 20, i = 1, pos = P(4), label = "y" } },
    routes = { { cid = 99, name = "Z", stops = { { from = 1, to = 2, pos = P(9), discovered = true } } } } }, fq)
  check("ff 9: pins of focused quests and every route stop", has(r.markers, "h:20:1") ~= nil
    and has(r.markers, "h:21:1") == nil and has(r.markers, "r:99:1") ~= nil)
  local frel6 = { [20] = { cast = {}, npcs = { 6 }, items = {}, dest = {} } }
  r = run(fw, nil, { focus_qids = { 20 }, quest_rel = frel6 }, fq)
  check("ff 10: a covering quest marker is related", has(r.markers, "c:6") ~= nil
    and has(r.markers, "n:6") == nil)
  local fws = { npcs = { npc(12, "Brant", P(30)) } }
  r = run(fws, Q("bran"), FO, fq)
  check("ff 11: an NPC search marker covers its cid", has(r.markers, "w:npc:12") ~= nil
    and has(r.markers, "n:12") == nil)
  local fwc = { focus_places = {}, chests = { { uid = "u1", pos = P(5), state = "unopened" } } }
  r = run(fwc, nil, FO, fq)
  check("ff 12: full-map pass hidden too", has(r.fullmap_world, "w:chest:u1") == nil)
  r = run(fwc, nil, FD, fq)
  check("ff 12b: and dimmed", has(r.fullmap_world, "w:chest:u1").dim == true)
  r = run(fw, nil, { quest_rel = frel }, fq)
  check("ff 13: no focus: nothing added or dimmed", keys(r.markers, "n:") == "" and keys(r.markers, "f:") == ""
    and r.focus_counts == nil and not has(r.markers, "c:6").dim)
  r = run({ sellers = { { shop = 9, item = 401, item_name = "Salt", cid = 77, npc = "Vendor", qids = { 99 },
      quest = "Other", pos = P(16) } } }, nil,
    { focus_qids = { 20 }, quest_rel = { [20] = { cast = {}, npcs = { 77 }, items = {}, dest = {} } } },
    { acceptable = { 20 }, hints = { [20] = 5 }, npc_pos = { [5] = P(1), [77] = P(15) }, names = { [20] = "Twenty" } })
  check("ff 14: a covering seller stays in both passes", has(r.markers, "w:sell:9:401") ~= nil
    and has(r.fullmap_world, "w:sell:9:401") ~= nil and has(r.markers, "n:77") == nil
    and not has(r.markers, "w:sell:9:401").related)

  -- fix round 1 for Task 3.8
  local rel77 = { [20] = { cast = {}, npcs = { 77 }, items = {}, dest = {} } }
  local pos77 = { acceptable = { 20 }, hints = { [20] = 5 }, npc_pos = { [5] = P(1), [77] = P(15) },
    names = { [20] = "Twenty" } }
  local function seller(shop, item, cid, pos)
    return { shop = shop, item = item, item_name = "Salt", cid = cid, npc = "V", qids = { 99 },
      quest = "Other", pos = pos }
  end
  r = run({ sellers = { seller(9, 401, 77, P(16)), seller(10, 402, 78, P(1000)) } }, nil,
    { focus_qids = { 20 }, quest_rel = rel77, world_max_markers = 1, map_origin = P(1000) }, pos77)
  check("ff 15: a seller missing from the full map selection does not cover",
    has(r.fullmap_world, "w:sell:9:401") == nil
    and has(r.markers, "n:77") ~= nil)
  local np = { acceptable = { 20 }, hints = { [20] = 5 }, npc_pos = { [5] = P(1) }, names = { [20] = "Twenty" } }
  r = run({ sellers = { seller(9, 401, 77, P(16)) } }, nil, { focus_qids = { 20 }, quest_rel = rel77 }, np)
  check("ff 16: no_pos counts a covered cid without a position",
    has(r.markers, "w:sell:9:401") ~= nil and has(r.markers, "n:77") == nil
    and table.concat(r.focus_counts.no_pos, ",") == "77")
  r = run({ npcs = { { cid = 12, name = "Other" } }, focus_places = fw.focus_places }, nil, FO, fq)
  check("ff 17: a new world.npcs table refreshes the names", has(r.markers, "n:12").label == "Other")
  r = run({ sellers = { seller(9, 401, 77, P(16)) } }, nil,
    { focus_qids = { 20 }, quest_rel = rel77, map_origin = false }, pos77)
  check("ff 17b: with no full-map pass the seller covers", r.fullmap_world == nil
    and has(r.markers, "w:sell:9:401") ~= nil and has(r.markers, "n:77") == nil)
  local rel5 = { [20] = { cast = {}, npcs = { 5 }, items = {}, dest = {} } }
  r = run({ sellers = { seller(9, 401, 5, P(16)) } }, Q("salt"), { focus_qids = { 20 }, quest_rel = rel5 }, fq)
  check("ff 18: the first marker per cid covers", has(r.markers, "c:5").focus_kept == true
    and has(r.markers, "w:sell:9:401") ~= nil and r.focus_counts.related == 1
    and has(r.markers, "n:5") == nil)
end

-- SPEC 39.5: focused current-journal reads are independently capped, aged,
-- deterministic, and pruned without touching the tree journal cache.
do
  local read_focus = core.focus_journal_reads
  local supported = type(read_focus) == "function"
  check("focus journal helper exists", supported)
  if supported then
    local calls, state = {}, {}
    local function reader(qid)
      calls[#calls + 1] = qid
      return state[qid]
    end
    local active = {}
    for qid = 1, 17 do active[#active + 1] = qid end
    local cache = read_focus(reader, {}, {}, 0)
    check("focus journal empty active set", next(cache) == nil)
    cache = read_focus(reader, { 5 }, {}, 0)
    check("focus journal one new qid reads first tick", #calls == 1 and calls[1] == 5
      and cache[5] and cache[5].missing and cache[5].read_at == 0)
    state[5] = { base = "current" }
    local prev = cache
    calls = {}
    cache = read_focus(reader, { 5 }, prev, 1.99)
    check("focus journal respects two-second minimum age", #calls == 0
      and cache[5] == prev[5])
    calls = {}
    cache = read_focus(reader, { 5 }, prev, 2)
    check("focus journal reads at exact age boundary", #calls == 1
      and cache[5].base == "current" and cache[5].read_at == 2)
    calls = {}
    local cold = read_focus(reader, active, {}, 0)
    check("focus journal reads at most two per tick in qid order",
      table.concat(calls, ",") == "1,2" and cold[1] and cold[2] and not cold[3])
    local all_seen = cold[1] ~= nil and cold[2] ~= nil
    for tick = 1, 8 do
      cold = read_focus(reader, active, cold, tick * 2)
    end
    for qid = 1, 17 do if cold[qid] == nil then all_seen = false end end
    check("focus journal samples 17 cold qids within nine two-second ticks", all_seen)
    local ordered_prev = {
      [2] = { value = { base = "b" }, read_at = 4 },
      [3] = { missing = true, read_at = 1 },
      [4] = { value = { base = "d" }, read_at = 1 },
    }
    calls = {}
    read_focus(reader, { 2, 4, 3 }, ordered_prev, 10)
    check("focus journal ranks oldest then qid within cap", table.concat(calls, ",") == "3,4")
    calls = {}
    local retained_tree = { [3] = { name = "tree only" } }
    local pruned = read_focus(reader, { 2 }, ordered_prev, 10, retained_tree)
    check("focus journal prunes removed active qids only", pruned[2] ~= nil
      and pruned[3] == nil and retained_tree[3].name == "tree only")
    local tree_prev = { [2] = { base = "tree value", read_at = 10 } }
    local reused = read_focus(reader, { 2 }, {}, 10, tree_prev)
    check("focus journal reuses exact-now tree value", reused[2].base == "tree value"
      and reused[2].read_at == 10)
    local failed_record = read_focus(function() error({ base = "not a journal" }) end, { 9 }, {}, 1)
    check("focus journal turns pcall failure into missing", failed_record[9].missing == true
      and failed_record[9].base == nil)
  end

  local match_key = core.match_destination_key
  check("objective destination matcher exists", type(match_key) == "function")
  if type(match_key) == "function" then
    local function pos(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
    local rel = { [8] = { dest = { { key = 9 }, { key = 4 }, { key = 2 }, { key = 99 } } } }
    local live = { [9] = pos(1), [4] = pos(-1), [2] = pos(3), [99] = pos(20) }
    check("destination match is limited to own extracted keys and 2m",
      match_key(8, pos(0), rel, live) == 4)
    check("destination match no-match is nil", match_key(8, pos(0), rel, { [99] = pos(30) }) == nil)
    check("destination match tie chooses smallest key",
      match_key(8, pos(0), rel, { [9] = pos(1), [4] = pos(-1) }) == 4)
  end

  local function pos(x, y, z) return { x = x, y = y or 0, z = z or 0 } end
  local routes_fc = { active = { 7 }, quests = { [7] = {
    npcs = { 11, 12 }, step_npcs = { 12 }, related_shown = false,
    objective = { npcs = { 21 }, place = { x = 3, y = 4, z = 5, caption = "Hall" },
      npc_positions = { [21] = pos(2) },
      items = { 42 }, item_sources = { [42] = { key = "i:42", pos = pos(9) } },
    },
  } } }
  local function rname(cid, key) return key and "Item" or ("NPC" .. tostring(cid)) end
  local direct, dn, dt = core.route_members(routes_fc, {}, {}, nil,
    { routes = 1, places = true }, rname)
  check("objective route: NPC mode routes current target and direct place",
    #direct == 2 and direct[1].cid == 21 and direct[2].direct == true
    and direct[2].kind == "place" and direct[2].qid == 7
    and direct[2].pos.x == 3 and direct[2].name == "Objective: Hall" and dn == 2 and dt == 2)
  routes_fc.quests[7].objective.place = nil
  direct = core.route_members(routes_fc, {}, {}, nil, { routes = 1, places = true }, rname)
  check("objective route: item fallback uses retained source",
    #direct == 2 and direct[2].direct == true and direct[2].kind == "item"
    and direct[2].cid == -(0x10000000000 + 7 * 4 + 2)
    and direct[2].pos.x == 9 and direct[2].name == "Objective: Item 42 (for Quest 7)")
  routes_fc.quests[7].show_related = true
  direct = core.route_members(routes_fc, {}, {}, nil, { routes = 2, places = false }, rname)
  check("objective route: shown ancillary cids enter mode two only",
    #direct == 3 and direct[1].cid == 21 and direct[2].cid == 11 and direct[3].cid == 12)
  local ordered_focus = { active = { 1, 2 }, quests = {
    [1] = { show_related = true, npcs = { 11 }, objective = { npcs = { 1 },
      npc_positions = { [1] = pos(1) }, place = { x = 2, y = 0, z = 0, caption = "P1" } } },
    [2] = { show_related = true, npcs = { 12 }, objective = { npcs = { 2 },
      npc_positions = { [2] = pos(1) }, place = { x = 3, y = 0, z = 0, caption = "P2" } } },
  } }
  direct = core.route_members(ordered_focus, {}, {}, nil,
    { routes = 2, places = true }, rname)
  check("objective routes group NPC, destination and shown related per quest",
    #direct == 6 and direct[1].cid == 1 and direct[2].kind == "place"
      and direct[3].cid == 11 and direct[4].cid == 2
      and direct[5].kind == "place" and direct[6].cid == 12)
  local nine_primary = { active = {}, quests = {} }
  for qid = 1, 9 do
    nine_primary.active[#nine_primary.active + 1] = qid
    nine_primary.quests[qid] = { objective = { npcs = { qid },
      npc_positions = { [qid] = pos(qid) } } }
  end
  direct = core.route_members(nine_primary, {}, {}, nil, { routes = 1 }, rname)
  local primary_cids = {}
  for _, member in ipairs(direct) do primary_cids[#primary_cids + 1] = tostring(member.cid) end
  check("objective route cap keeps first eight primary cids in active order",
    #direct == 8 and table.concat(primary_cids, ",") == "1,2,3,4,5,6,7,8")
  local duplicate_target = { active = { 1, 2 }, quests = {
    [1] = { objective = { npcs = { 99 }, npc_positions = { [99] = pos(1) } } },
    [2] = { objective = { npcs = { 99 }, npc_positions = { [99] = pos(1) } } },
  } }
  local duplicate_routes, _, duplicate_total = core.route_members(duplicate_target, {}, {}, 99,
    { routes = 1 }, rname)
  check("objective route target total counts a repeated target once",
    #duplicate_routes == 1 and duplicate_routes[1].cid == 99 and duplicate_total == 1)
  local late_target_routes, late_target_count, late_target_total = core.route_members(nine_primary,
    {}, {}, 9, { routes = 1 }, rname)
  local late_target_cids = {}
  for _, member in ipairs(late_target_routes) do late_target_cids[#late_target_cids + 1] = tostring(member.cid) end
  check("objective routes reserve one capped slot for a late search target",
    table.concat(late_target_cids, ",") == "1,2,3,4,5,6,7,9"
      and late_target_count == 8 and late_target_total == 9)
  local later_routes = { active = { 1, 2 }, quests = {
    [1] = { show_related = true, related_npcs = { 101, 102, 103, 104, 105, 106, 107, 108 },
      objective = { npcs = { 1 }, npc_positions = { [1] = pos(1) } } },
    [2] = { show_related = false, objective = { npcs = { 2 },
      npc_positions = { [2] = pos(2) }, place = { x = 3, y = 0, z = 0, caption = "Later" } } },
  } }
  direct = core.route_members(later_routes, {}, {}, nil,
    { routes = 2, places = true }, rname)
  local has_later_npc, has_later_place = false, false
  for _, member in ipairs(direct) do
    if member.cid == 2 then has_later_npc = true end
    if member.qid == 2 and member.kind == "place" then has_later_place = true end
  end
  check("per-quest route order emits early ancillary routes before later objectives",
    direct[1].cid == 1 and direct[2].cid == 101 and direct[7].cid == 106
      and direct[8].cid == 107 and not has_later_npc and not has_later_place and #direct == 8)
  local route_id_fn = core.objective_route_id
  check("objective route id helper validates qid and kind",
    type(route_id_fn) == "function"
      and route_id_fn(1, "place") ~= nil and route_id_fn(1, "item") ~= nil
      and route_id_fn(1, "place") ~= route_id_fn(1, "item")
      and route_id_fn(0x7FFFFFFF, "place") ~= nil
      and route_id_fn(0x7FFFFFFF, "item") ~= nil
      and route_id_fn(0, "place") == nil and route_id_fn(1.5, "place") == nil
      and route_id_fn(math.huge, "place") == nil and route_id_fn(0 / 0, "item") == nil
      and route_id_fn(0x80000000, "place") == nil
      and route_id_fn(1, "npc") == nil)
  if type(route_id_fn) == "function" then
    local route_ids = {}
    for _, qid in ipairs({ 1, 2, 3, 999, 0x7FFFFFFF }) do
      for _, kind in ipairs({ "place", "item" }) do
        local id = route_id_fn(qid, kind)
        if id == nil or route_ids[id] then route_ids.failed = true else route_ids[id] = true end
      end
    end
    check("objective route ids fit 48-bit GUIDs and avoid NPC/legacy IDs",
      not route_ids.failed and math.abs(route_id_fn(0x7FFFFFFF, "item")) < 0x1000000000000
        and math.abs(route_id_fn(0x7FFFFFFF, "item")) * 32 < 0x1000000000000
        and math.abs(route_id_fn(1, "place")) > 0xFFFFFFFFFF
        and route_id_fn(7, "place") < 0 and route_id_fn(7, "place") ~= 77
        and route_id_fn(7, "place") ~= -77)
  end
  local route_ids = {}
  for _, qid in ipairs({ 1, 2, 3, 127, 65535, 0x7FFFFFFF }) do
    local focus = { active = { qid }, quests = { [qid] = { objective = {
      place = { x = 1, y = 2, z = 3 }, items = { 1 }, npcs = {} } } } }
    local got = core.route_members(focus, {}, {}, nil, { routes = 0, places = true }, rname)
    local code = got[1] and got[1].cid
    if code then route_ids[code] = (route_ids[code] or 0) + 1 end
  end
  check("objective route ids are injective across sampled positive qid domain",
    (function() for _, n in pairs(route_ids) do if n ~= 1 then return false end end return true end)()
    and next(route_ids) ~= nil)
  local full_ids, injective = {}, true
  for qid = 1, 4096 do
    for _, kind in ipairs({ "place", "item" }) do
      local objective = { npcs = {}, items = {}, item_sources = {} }
      if kind == "place" then objective.place = pos(qid)
      else objective.items = { qid }; objective.item_sources[qid] = {
        key = "k" .. qid, pos = pos(qid) } end
      local focus = { active = { qid }, quests = { [qid] = { objective = objective } } }
      local members = core.route_members(focus, {}, {}, nil,
        { routes = 0, places = true }, rname)
      local id = members[1] and members[1].cid
      if id == nil or full_ids[id] then injective = false else full_ids[id] = true end
    end
  end
  check("objective place and item route ids are injective across 4096 qids", injective)
  local invalid_focus = { active = { 0, -1, 1.5, 0x80000000 }, quests = {} }
  for _, qid in ipairs(invalid_focus.active) do
    invalid_focus.quests[qid] = { objective = { npcs = {}, items = {},
      place = { x = 1, y = 0, z = 1 } } }
  end
  check("objective route rejects invalid qids", #core.route_members(invalid_focus, {}, {}, nil,
    { routes = 0, places = true }, rname) == 0)
  local item_routes = { active = { 8 }, quests = { [8] = { name = "Eight", objective = {
    npcs = {}, items = { 1, 2, 3 }, item_sources = {
      [1] = { key = "z", pos = pos(5), name = "Zed" },
      [2] = { key = "b", pos = pos(-5), name = "Bee" },
      [3] = { key = "a", pos = pos(-5), name = "Ay" },
    } } } } }
  direct = core.route_members(item_routes, {}, {}, nil,
    { routes = 0, places = true, player = pos(0) }, rname)
  check("objective route chooses nearest retained item source with key tie-break",
    #direct == 1 and direct[1].kind == "item" and direct[1].name == "Objective: Ay (for Eight)"
    and direct[1].pos.x == -5)
  direct = core.route_members(item_routes, {}, {}, nil,
    { routes = 0, places = true }, rname)
  check("objective route has deterministic item source without origin",
    #direct == 1 and direct[1].name == "Objective: Ay (for Eight)")
  item_routes.quests[8].objective.item_sources = {}
  check("objective route omits item target without drawable source",
    #core.route_members(item_routes, {}, {}, nil, { routes = 0, places = true }, rname) == 0)
  local capped_focus = { active = { 7 }, quests = { [7] = { objective = {
    npcs = { 1, 2, 3, 4, 5, 6, 7, 8 }, npc_positions = {
      [1] = pos(1), [2] = pos(2), [3] = pos(3), [4] = pos(4), [5] = pos(5),
      [6] = pos(6), [7] = pos(7), [8] = pos(8) },
    place = { x = 1, y = 0, z = 1 } } } } }
  direct, dn = core.route_members(capped_focus, {}, {}, 99,
    { routes = 1, places = true }, rname)
  check("objective direct route respects eight-slot cap and search reservation",
    #direct == 7 and dn == 8 and direct[7].cid == 7)

  local obj_adapter = fake_adapter({ progressing = { 10 }, hints = { [10] = 5 },
    names = { [10] = "Ten" }, npc_pos = { [5] = pos(1), [77] = pos(2), [88] = pos(3) },
    objective_pos = { [77] = pos(2) }, objectives = { [10] = {} },
    item_needs = { [10] = { { id = 99, num = 1 } } },
    item_locs = { { id = 99, pos = pos(8), src = "world" } }, item_names = { [99] = "Token" } })
  obj_adapter.objective_issued_cids = function(qid) return qid == 10 and { 77 } end
  obj_adapter.journal_now = function() return { step_index = 0,
    dest = { x = 10, y = 0, z = 0, caption = "Hall" } } end
  local obj_world = { focus_places = { [44] = pos(10) } }
  local obj_rel = { [10] = { cast = {}, npcs = { 77, 88 }, items = {},
    dest = { { key = 44 }, { key = 45 } } } }
  local obj_show = { focus_qids = { 10 }, quest_rel = obj_rel, world = obj_world,
    prev_focus_journal = {}, now = 0, in_progress = true, quest_items = true,
    focus_related_qids = {}, focus_unrelated = 0 }
  local obj_result = core.compute(obj_adapter, obj_show)
  local orec = obj_result.focus and obj_result.focus.quests[10]
    and obj_result.focus.quests[10].objective
  local function marked(key)
    for _, m in ipairs(obj_result.markers) do if m.key == key then return m end end
  end
  check("objective snapshot unions issued npc, live place, current item and zero-based step",
    orec ~= nil and orec.step == 0 and table.concat(orec.npcs or {}, ",") == "77"
    and orec.place and orec.place.caption == "Hall" and orec.place.key == 44
    and table.concat(orec.items or {}, ",") == "99" and orec.known and orec.resolved)
  check("objective markers use dedicated place identity and cover npc/item markers",
    marked("o:p:10") and marked("o:p:10").cat == "focus_place"
    and marked("o:p:10").objective and marked("o:p:10").place == 44
    and marked("n:77") and marked("n:77").objective
    and marked("n:77").objective_qids[1] == 10
    and marked("i:99:2:0") and marked("i:99:2:0").objective
    and table.concat(marked("i:99:2:0").objective_qids or {}, ",") == "10")
  check("objective markers are not search results", core.is_result(marked("o:p:10")) == false
    and core.is_result(marked("n:77")) == false and core.is_result(marked("i:99:2:0")) == false)
  local covering_adapter = fake_adapter({ progressing = { 10 }, hints = { [10] = 5 },
    npc_pos = { [5] = pos(1), [77] = pos(2) }, objective_pos = { [77] = pos(2) },
    objectives = { [10] = {} } })
  covering_adapter.objective_issued_cids = function() return { 77 } end
  covering_adapter.journal_now = function() return {} end
  local cover_world = { focus_places = {}, world_shops = true, world_sellers = true,
    world_max_markers = 300, world_origin = pos(0), map_origin = pos(0),
    shops = { { shop = 8, cid = 77, npc = "Shopkeeper", pos = pos(2), hover = "Stock details",
      items = { { id = 1, name = "Ration" } }, discovered = true } } }
  local cover_show = { focus_qids = { 10 }, focus_related_qids = {}, world = cover_world,
    world_shops = true, world_sellers = false, world_origin = pos(0), map_origin = pos(0), now = 0 }
  local cover_result = core.compute(covering_adapter, cover_show)
  local function marker_in(list, key)
    for _, m in ipairs(list or {}) do if m.key == key then return m end end
  end
  local map_shop, full_shop = marker_in(cover_result.markers, "w:shop:8"),
    marker_in(cover_result.fullmap_world, "w:shop:8")
  check("objective covers shop in player and full-map lists", map_shop and map_shop.objective == true
    and full_shop and full_shop.objective == true and core.marker_cid(map_shop) == 77
    and map_shop.label == "Shopkeeper (shop)" and full_shop.label == map_shop.label
    and map_shop.hover == "Stock details" and full_shop.hover == map_shop.hover)
  local seller_world = { focus_places = {}, world_max_markers = 300,
    sellers = { { shop = 9, item = 2, item_name = "Salt", npc = "Vendor", cid = 77, hover = "Seller details",
      pos = pos(2), discovered = true, qids = {} } } }
  local seller_show = {}
  for k, v in pairs(cover_show) do seller_show[k] = v end
  seller_show.world, seller_show.world_shops, seller_show.world_sellers = seller_world, false, true
  local seller_result = core.compute(covering_adapter, seller_show)
  local map_seller, full_seller = marker_in(seller_result.markers, "w:sell:9:2"),
    marker_in(seller_result.fullmap_world, "w:sell:9:2")
  check("objective covers seller in player and full-map lists", map_seller and map_seller.objective == true
    and full_seller and full_seller.objective == true and core.marker_cid(map_seller) == 77
    and map_seller.label == "Salt - sold by Vendor" and full_seller.label == map_seller.label
    and map_seller.hover == "Seller details" and full_seller.hover == map_seller.hover)
  local search_world = { focus_places = {}, npcs = { { cid = 77, name = "Target", pos = pos(2), hover = "NPC details",
    alive = true, discovered = true } } }
  local search_cover = core.compute(covering_adapter, { focus_qids = { 10 },
    focus_related_qids = {}, world = search_world, search = core.parse_query("target"),
    world_origin = pos(0), map_origin = pos(0), world_max_markers = 300, now = 0 })
  local search_marker = marker_in(search_cover.markers, "w:npc:77")
  local search_full_marker = marker_in(search_cover.fullmap_world, "w:npc:77")
  check("objective covers searched NPC marker in player and full-map lists",
    search_marker and search_marker.objective == true and search_full_marker
      and search_full_marker.objective == true and core.marker_cid(search_marker) == 77
      and search_marker.label == "Target" and search_full_marker.label == search_marker.label
      and search_marker.hover == "NPC details" and search_full_marker.hover == search_marker.hover)
  local multiple_locs_adapter = fake_adapter({ progressing = { 10 }, hints = { [10] = 5 },
    npc_pos = { [5] = pos(1), [77] = pos(2) }, objective_pos = { [77] = pos(2) },
    objectives = { [10] = {} }, item_needs = { [10] = { { id = 99, num = 1 } } },
    item_locs = { { id = 99, pos = pos(8), src = "world" },
      { id = 99, pos = pos(16), src = "drop" } }, item_names = { [99] = "Token" } })
  multiple_locs_adapter.objective_issued_cids = function() return { 77 } end
  multiple_locs_adapter.journal_now = function() return {} end
  local multiple_locs = core.compute(multiple_locs_adapter, obj_show)
  local function item_marker(result, key)
    for _, m in ipairs(result.markers) do if m.key == key then return m end end
  end
  check("all retained current-need item markers are objective, with one route source",
    item_marker(multiple_locs, "i:99:2:0").objective == true
      and item_marker(multiple_locs, "i:99:4:0").objective == true
      and multiple_locs.focus.quests[10].objective.item_sources[99].key == "i:99:2:0")
  check("objective fallback giver is hidden with related NPCs off",
    marked("c:5") == nil and marked("n:88") == nil)
  local ordered_adapter = fake_adapter({ progressing = { 10 }, hints = { [10] = 5 },
    npc_pos = { [5] = pos(1), [9] = pos(2), [7] = pos(3) },
    objective_pos = { [9] = pos(2), [7] = pos(3) }, objectives = { [10] = {} } })
  ordered_adapter.objective_issued_cids = function() return { 9, 7 } end
  local ordered_result = core.compute(ordered_adapter, { focus_qids = { 10 },
    focus_related_qids = {}, now = 0 })
  check("objective preserves adapter issued NPC order", table.concat(
    ordered_result.focus.quests[10].objective.npcs, ",") == "9,7")
  local dim_show = {}
  for k, v in pairs(obj_show) do dim_show[k] = v end
  dim_show.focus_unrelated = 1
  local dim_result = core.compute(obj_adapter, dim_show)
  local function has_key(result, key)
    for _, m in ipairs(result.markers) do if m.key == key then return m end end
  end
  check("objective related gate stays hard-hidden in Dim mode",
    has_key(dim_result, "c:5") == nil and has_key(dim_result, "n:88") == nil)
  local shown_show = {}
  for k, v in pairs(obj_show) do shown_show[k] = v end
  shown_show.focus_related_qids = { 10 }
  local shown_result = core.compute(obj_adapter, shown_show)
  check("objective related opt-in restores ancillary NPCs, not their objective status",
    has_key(shown_result, "c:5") ~= nil and has_key(shown_result, "n:88") ~= nil
    and has_key(shown_result, "n:88").objective ~= true
    and has_key(shown_result, "n:77").objective == true)
  local search_show = {}
  for k, v in pairs(obj_show) do search_show[k] = v end
  search_show.search = core.parse_query("NPC 88")
  search_show.world = { focus_places = obj_world.focus_places,
    npcs = { { cid = 88, name = "NPC 88", pos = pos(3), alive = true, discovered = true } } }
  local search_result = core.compute(obj_adapter, search_show)
  local searched = has_key(search_result, "w:npc:88")
  check("objective hidden ancillary explicit search stays normal", searched ~= nil
    and searched.objective ~= true and searched.related ~= true)
  obj_adapter.npc_name = function(cid) return cid == 5 and "NPC 5" or nil end
  local quest_search_show = {}
  for k, v in pairs(obj_show) do quest_search_show[k] = v end
  quest_search_show.search = core.parse_query("NPC 5")
  local quest_search_result = core.compute(obj_adapter, quest_search_show)
  local searched_quest_marker = has_key(quest_search_result, "c:5")
  check("objective hidden ancillary quest marker search stays normal",
    searched_quest_marker ~= nil and searched_quest_marker.related_search == true
      and searched_quest_marker.objective ~= true)

  local multi_adapter = fake_adapter({ progressing = { 10, 11 }, hints = { [10] = 77, [11] = 77 },
    names = { [10] = "Ten", [11] = "Eleven" }, npc_pos = { [77] = pos(2), [88] = pos(3) },
    objective_pos = { [77] = pos(2) }, objectives = { [10] = {}, [11] = {} },
    item_needs = { [10] = { { id = 99, num = 1 } }, [11] = { { id = 99, num = 2 } } },
    item_locs = { { id = 99, pos = pos(8), src = "world" } }, item_names = { [99] = "Token" } })
  multi_adapter.objective_issued_cids = function(qid) return { 77 } end
  multi_adapter.journal_now = function(qid) return { step_index = 0,
    dest = { x = 10, y = 0, z = 0, caption = "Hall " .. qid } } end
  local multi_rel = { [10] = { npcs = { 88 }, dest = { { key = 44 } } },
    [11] = { npcs = { 88 }, dest = { { key = 44 } } } }
  local multi_result = core.compute(multi_adapter, { focus_qids = { 11, 10 },
    focus_related_qids = { 11 }, quest_rel = multi_rel,
    world = { focus_places = { [44] = pos(10) } },
    now = 0 })
  local merged_target, places_n = has_key(multi_result, "c:77"), 0
  for _, m in ipairs(multi_result.markers) do if m.key == "o:p:10" or m.key == "o:p:11" then places_n = places_n + 1 end end
  check("objective cover unions sorted qids and destinations remain per quest",
    merged_target ~= nil and merged_target.objective == true
    and table.concat(merged_target.objective_qids or {}, ",") == "10,11"
    and places_n == 2 and has_key(multi_result, "o:p:10").label ~= has_key(multi_result, "o:p:11").label)
  check("item covering marker unions sorted objective qids",
    has_key(multi_result, "i:99:2:0") ~= nil
      and table.concat(has_key(multi_result, "i:99:2:0").objective_qids or {}, ",") == "10,11")
  check("shared ancillary cid is visible when any focused owner opts in",
    has_key(multi_result, "n:88") ~= nil
    and multi_result.focus.quests[10].related_shown_count == 1
    and multi_result.focus.quests[10].related_hidden_count == 0
    and multi_result.focus.related_counts.shown == 1)
  local off_result = core.compute(multi_adapter, { focus_qids = { 10, 11 },
    focus_related_qids = {}, quest_rel = multi_rel,
    world = { focus_places = { [44] = pos(10) } }, now = 0 })
  check("shared ancillary cid is hidden only when every owner is off",
    has_key(off_result, "n:88") == nil and off_result.focus.related_counts.hidden == 1)
  check("per-quest related visibility counts are integers over live positioned NPCs",
    type(multi_result.focus.quests[10].related_shown) == "number"
      and type(multi_result.focus.quests[10].related_hidden) == "number"
      and multi_result.focus.quests[10].related_shown == 1
      and multi_result.focus.quests[10].related_hidden == 0
      and type(multi_result.focus_counts.objective) == "number")
  local state_adapter = base_adapter({ progressing_ids = function() return { 60 } end,
    npc_alive = function(cid) return cid ~= 89 end,
    npc_pos = function(cid) if cid == 88 then return 8, 0, 0 end end,
    quest_name = function() return "Visibility" end })
  local state_rel = { [60] = { npcs = { 88, 89, 90 } } }
  local state_off = core.compute(state_adapter, { focus_qids = { 60 }, focus_related_qids = {},
    quest_rel = state_rel, now = 0 })
  local state_on = core.compute(state_adapter, { focus_qids = { 60 }, focus_related_qids = { 60 },
    quest_rel = state_rel, now = 0 })
  check("related counts include only positioned live NPCs while no_pos ignores toggle",
    state_off.focus.related_counts.shown == 0 and state_off.focus.related_counts.hidden == 1
      and state_on.focus.related_counts.shown == 1 and state_on.focus.related_counts.hidden == 0
      and table.concat(state_off.focus_counts.no_pos, ",") == "90"
      and table.concat(state_on.focus_counts.no_pos, ",") == "90")
  local unresolved_adapter = base_adapter({ acceptable_ids = function() return { 20 } end,
    is_side = function() return true end, giver_hint = function() return 9 end,
    progressing_ids = function() return { 30 } end, quest_state = function(qid) return qid == 30 and "locked" end,
    quest_name = function(qid) return "Q" .. qid end })
  local unresolved_result = core.compute(unresolved_adapter,
    { focus_qids = { 20, 30 }, focus_related_qids = {}, now = 0 })
  check("objective startable and locked unresolved records stay non-drawable",
    unresolved_result.focus.quests[20].objective.known
      and not unresolved_result.focus.quests[20].objective.resolved
      and not unresolved_result.focus.quests[30].objective.known
      and not unresolved_result.focus.quests[30].objective.resolved)
  local locked_adapter = base_adapter({ acceptable_ids = function() return {} end,
    progressing_ids = function() return {} end, catalog_ids = function() return { 30 } end,
    quest_name = function() return "A locked quest" end, giver_hint = function() return 5 end,
    npc_pos = function() return 5, 0, 0 end })
  local locked_result = core.compute(locked_adapter, { focus_qids = { 30 },
    focus_related_qids = {}, now = 0 })
  check("real locked quest fixture has no current objective signal",
    locked_result.focus.quests[30].objective.known == false
      and locked_result.focus.quests[30].objective.resolved == false)
  check("known objective NPC without position does not become drawable or routable",
    unresolved_result.focus.quests[20].objective.npcs[1] == 9
      and unresolved_result.focus.quests[20].objective.npc_positions[9] == nil
      and #core.route_members(unresolved_result.focus, {}, {}, nil,
        { routes = 1, places = false }, rname) == 0)
  local fallback_adapter = fake_adapter({ progressing = { 40 }, hints = { [40] = 5 },
    names = { [40] = "Forty" }, npc_pos = { [5] = pos(1) }, objectives = { [40] = {} },
    item_needs = { [40] = { { id = 99, num = 1 } } }, item_locs = {} })
  fallback_adapter.objective_issued_cids = function() return { 77 } end
  fallback_adapter.journal_now = function() return { step_index = 0 } end
  local fallback_show = { focus_qids = { 40 }, focus_related_qids = {},
    focus_unrelated = 0, now = 0 }
  local fallback_result = core.compute(fallback_adapter, fallback_show)
  local fallback_obj = fallback_result.focus.quests[40].objective
  check("unresolved in-progress objective keeps fallback giver ancillary and unrouted",
    fallback_obj.known and not fallback_obj.resolved
      and has_key(fallback_result, "c:5") == nil
      and #core.route_members(fallback_result.focus, {}, {}, nil,
        { routes = 1, places = false }, rname) == 0)
  fallback_show.focus_unrelated = 1
  fallback_result = core.compute(fallback_adapter, fallback_show)
  check("unresolved fallback giver remains hard-hidden under Dim",
    has_key(fallback_result, "c:5") == nil)
  local position_fallback = base_adapter({ progressing_ids = function() return { 41 } end,
    static_pos = function() return pos(1) end, quest_name = function() return "Forty One" end })
  local position_result = core.compute(position_fallback, { focus_qids = { 41 },
    focus_related_qids = {}, now = 0 })
  check("position-keyed unresolved fallback giver obeys related hard-hide",
    has_key(position_result, "p:1:0:0") == nil)

  local startable_static = fake_adapter({ acceptable = { 42 }, hints = { [42] = 5 },
    names = { [42] = "Starter", [43] = "Precursor" }, statics = { [42] = pos(1) },
    gates = { [42] = { 43 } }, seen = { [43] = "Precursor" } })
  local startable_static_result = core.compute(startable_static, { focus_qids = { 42 },
    focus_related_qids = { 42 }, reveal_gate_names = true, now = 0 })
  local startable_marker, startable_count = nil, 0
  for _, m in ipairs(startable_static_result.markers) do
    if m.key == "p:1:0:0" or m.key == "n:5" then
      startable_count = startable_count + 1
      if m.key == "p:1:0:0" then startable_marker = m end
    end
  end
  local startable_anchors = core.overhead_anchors(startable_static_result.markers, {},
    { x = 0, y = 0, z = 0 }, 50)
  check("static-resolved startable giver is one semantic objective marker and an overhead anchor",
    startable_count == 1 and startable_marker ~= nil and startable_marker.objective == true
      and startable_marker.objective_qids[1] == 42 and core.marker_cid(startable_marker) == 5
      and #startable_anchors == 1 and startable_anchors[1].cid == 5
      and startable_marker.label == "Starter - startable"
      and startable_marker.hover == "Starter - startable (waiting on: Precursor)")

  local schedule_adapter = fake_adapter({ acceptable = { 20 }, hints = { [20] = 9 },
    names = { [20] = "Twenty" } })
  local schedule_result = core.compute(schedule_adapter, { focus_qids = { 20 },
    focus_related_qids = {}, world = { schedule = { [9] = pos(20) } }, now = 0 })
  check("startable giver retains schedule-resolved map position", schedule_result.focus.quests[20].objective.resolved
    and schedule_result.focus.quests[20].objective.npc_positions[9]
    and schedule_result.focus.quests[20].objective.npc_positions[9].x == 20)

  local main_adapter = fake_adapter({ progressing = { 300 }, hints = { [300] = 5 },
    npc_pos = { [77] = pos(2) }, objective_pos = { [77] = pos(2) },
    objectives = { [300] = {} } })
  main_adapter.is_side = function() return false end
  main_adapter.quest_region = function() return "Vermund" end
  main_adapter.objective_issued_cids = function() return { 77 } end
  main_adapter.journal_now = function() return { step_index = 0,
    dest = { x = 10, y = 0, z = 0, caption = "Main target" } } end
  local main_result = core.compute(main_adapter, { focus_qids = { 300 },
    focus_related_qids = {}, tree_open = true, now = 0 })
  check("focused main quest resolves current objective signals",
    main_result.focus.quests[300].objective.npcs[1] == 77
      and main_result.focus.quests[300].objective.place.caption == "Main target"
      and main_result.catalog_side_count == 0 and #main_result.quests == 0
      and main_result.counts.in_progress == 0)

  local render_filter_adapter = base_adapter({ progressing_ids = function() return { 60, 61 } end,
    npc_alive = function(cid) return cid ~= 89 end,
    npc_pos = function(cid)
      if cid == 88 then return 8, 0, 0 end
      if cid == 91 then return 9, 0, 0 end
    end,
    quest_name = function(qid) return "Q" .. qid end })
  local render_filter_result = core.compute(render_filter_adapter, { focus_qids = { 60, 61 },
    focus_related_qids = { 60 }, quest_rel = { [60] = { npcs = { 88, 89, 90, 91 } },
      [61] = { npcs = { 88 } } }, now = 0 })
  local rendered_routes = core.route_members(render_filter_result.focus, {}, {}, nil,
    { routes = 2, places = false }, rname)
  local rendered_cids = {}
  for _, member in ipairs(rendered_routes) do rendered_cids[#rendered_cids + 1] = tostring(member.cid) end
  check("mode-two routes include only shown live positioned ancillary NPCs in owner order",
    table.concat(rendered_cids, ",") == "88,91"
      and table.concat(render_filter_result.focus.quests[60].route_related_npcs or {}, ",") == "88,91"
      and #((render_filter_result.focus.quests[61].route_related_npcs) or {}) == 0)

  local journal_reads, focused_ids = 0, {}
  for qid = 1, 17 do focused_ids[#focused_ids + 1] = qid end
  local cadence_adapter = base_adapter({ progressing_ids = function() return focused_ids end,
    journal_now = function(qid) journal_reads = journal_reads + 1; return { base = "Step " .. qid } end })
  local cadence = core.compute(cadence_adapter, { focus_qids = focused_ids,
    focus_related_qids = {}, now = 0 })
  check("compute reads focused journal while tree is closed, max two per tick",
    journal_reads == 2 and cadence.focus_journal[1] ~= nil
      and cadence.focus_journal[2] ~= nil and cadence.journal == nil)
  cadence_adapter.quest_region = function() return "Region" end
  cadence_adapter.tracked_qid = function() return 1 end
  local tree_calls = 0
  cadence_adapter.journal_now = function() tree_calls = tree_calls + 1; return { base = "same tick" } end
  local tree_focus = core.compute(cadence_adapter, { focus_qids = { 1 }, focus_related_qids = {},
    tree_open = true, now = 10, prev_journal = {}, prev_focus_journal = {} })
  check("tree tracked read reuses exact-now focus journal value", tree_calls == 1
    and tree_focus.focus_journal[1].base == "same tick"
    and tree_focus.journal[1].base == "same tick")
  local obj_sign1 = core.signature({ { key = "objective-sig", pos = pos(1), qids = {}, cat = "x" } }, {})
  local obj_sign2 = core.signature({ { key = "objective-sig", pos = pos(1), qids = {}, cat = "x",
    objective = true, objective_qids = { 10 } } }, {})
  check("objective marker changes native signature", obj_sign1 ~= obj_sign2)
  check("objective ownership alone changes native signature",
    core.signature({ { key = "ownership", pos = pos(1), qids = {}, cat = "x",
      objective = true, objective_qids = { 10 } } }, {})
      ~= core.signature({ { key = "ownership", pos = pos(1), qids = {}, cat = "x",
        objective = true, objective_qids = { 11 } } }, {}))

  -- SPEC 40: typed canonical identities and objective projection model.
  ;(function()
  check("objective identities: public pure APIs exist",
    type(core.target_key) == "function" and type(core.byte_less) == "function"
      and type(core.target_registry_new) == "function"
      and type(core.target_registry_reset) == "function"
      and type(core.target_registry_allocate) == "function"
      and type(core.objective_snapshot) == "function"
      and type(core.objective_markers) == "function"
      and type(core.objective_routes) == "function")
  if type(core.target_key) == "function" and type(core.target_registry_new) == "function"
      and type(core.objective_snapshot) == "function" then
    local tk = core.target_key
    check("objective key: typed netstring separates delimiters and decimal text",
      tk({ "source", "a:1|2" }) ~= tk({ "source", "a|1:2" })
        and tk({ "source", "2" }) ~= tk({ 2, "issued_npc", 7 }))
    check("objective key: UTF-8 string length is bytes", tk({ "source", "é" }) == "t2:s6:sources2:é")
    check("objective key: canonical tuple variants use the specified component order",
      tk({ 10, "issued_npc", 77 }) == "t3:i10;s10:issued_npci77;"
        and tk({ 10, "task", 2, 3, "place" }) == "t5:i10;s4:taski2;i3;s5:place"
        and tk({ 10, "guidance", 1, 4, "npc" }) == "t5:i10;s8:guidancei1;i4;s3:npc")
    check("objective key: rejects booleans, floats and empty tuples",
      tk({ true }) == nil and tk({ 1.5 }) == nil and tk({ 10.0, "issued_npc", 7 }) == nil
        and tk({ 10, "task", 0, 1, true }) == nil
        and tk({}) == nil)
    local reg = core.target_registry_new()
    local allocated = core.target_registry_allocate(reg, { tk({ "source", "z" }), tk({ "source", "é" }), tk({ "source", "a" }) })
    check("objective registry: allocates new keys in unsigned byte order",
      allocated[tk({ "source", "a" })] == 1 and allocated[tk({ "source", "z" })] == 2
        and allocated[tk({ "source", "é" })] == 3)
    local retained = core.target_registry_allocate(reg, { tk({ "source", "z" }), tk({ "source", "a" }) })
    check("objective registry: reorder and disappearance preserve ordinals",
      retained[tk({ "source", "z" })] == 2 and retained[tk({ "source", "a" })] == 1 and reg.next_ordinal == 4)
    local invalid_keys = core.target_registry_allocate(reg, { "not-a-canonical-target", tk({ "source", "kept" }) })
    check("objective registry: malformed key failure is isolated and diagnosed",
      invalid_keys[tk({ "source", "kept" })] == 4 and #reg.diagnostics == 1
        and reg.diagnostics[1].reason == "target_key_invalid")
    core.target_registry_reset(reg)
    check("objective registry: cache-coupled session reset restarts ordinal allocation",
      reg.next_ordinal == 1 and next(reg.by_key) == nil
        and core.target_registry_allocate(reg, { tk({ "source", "a" }) })[tk({ "source", "a" })] == 1)
    local limited = core.target_registry_new(1099511627775)
    local lim = core.target_registry_allocate(limited, { tk({ "source", "last" }), tk({ "source", "overflow" }) })
    check("objective registry: maximum ordinal accepted and exhaustion diagnosed",
      lim[tk({ "source", "last" })] == 1099511627775 and lim[tk({ "source", "overflow" })] == nil
        and #limited.diagnostics == 1)
    check("objective direct route id uses only ordinal",
      core.objective_direct_route_id(1) == -4398046511105
        and core.objective_direct_route_id(1099511627775) == -5497558138879
        and core.objective_direct_route_id(0) == nil and core.objective_direct_route_id(1.5) == nil)
    check("objective direct route namespace avoids legacy ids and NPC ids",
      core.objective_direct_route_id(1) < -2147483648
        and core.objective_direct_route_id(1099511627775) < core.objective_direct_route_id(1)
        and core.objective_direct_route_id(1) ~= -1
        and core.objective_direct_route_id(1) ~= 4294967295
        and core.objective_direct_route_id(1) ~= -2147483648
        and core.objective_direct_route_id(1) ~= core.objective_route_id(2147483647, "place")
        and core.objective_direct_route_id(1) ~= core.objective_route_id(2147483647, "item")
        and core.objective_direct_route_id(1) - core.objective_direct_route_id(2) == 1)
    local snap = core.objective_snapshot({ generation = 4, quests = {
        { qid = 10, task_index = 2, read_status = "ok", issued_npcs = {
          { kind = "npc", target = { cid = 77 }, eligibility = "eligible" },
        }, task_destinations = {}, guidance = {}, item_ownership = {
          { item_id = 5, count = 1, proof_kind = "condition", eligibility = "eligible" },
        } },
      } }, { generation = 9, status = "ok", places = {} }, {
        { provider = "pickup", generation = 3, status = "ok", candidates = {
          { id = "pickup:5", kind = "placed_pickup", item_ids = { 5 },
            target = { pos = pos(8) }, eligibility = "eligible", generation = 3 },
          { id = "pickup:future", kind = "placed_pickup", item_ids = { 6 },
            target = { pos = pos(9) }, eligibility = "eligible", generation = 3 },
        } },
      }, core.target_registry_new())
    check("objective snapshot: item proof gates source and normalizes targets",
      snap and #snap.targets == 2 and snap.targets[1].kind == "npc"
        and snap.targets[2].kind == "source" and snap.targets[2].source_id == "pickup:5"
        and snap.targets[2].item_ids[1] == 5 and snap.targets[2].ordinal ~= nil)
    local routes = core.objective_routes(snap, pos(0), { npc_route_mode = 1,
      objective_places = true, focus_order = { 10 }, category_visibility = {} })
    check("objective routes: direct source member carries target identity",
      #routes.members == 1 and routes.members[1].direct == true
        and routes.members[1].ordinal == snap.targets[2].ordinal
        and routes.members[1].route_id == core.objective_direct_route_id(snap.targets[2].ordinal))

    local snapshots = core.objective_snapshot({ generation = 5, quests = {
        { qid = 11, task_index = 1, read_status = "ok", issued_npcs = {},
          task_destinations = {}, guidance = {}, item_ownership = {
            { item_id = 2, count = 1, proof_kind = "condition", eligibility = "eligible" },
          } },
        { qid = 10, task_index = 0, read_status = "ok", issued_npcs = {},
          task_destinations = {}, guidance = {}, item_ownership = {
            { item_id = 1, count = 1, proof_kind = "delivery", eligibility = "eligible" },
          } },
        { qid = 12, task_index = 1, read_status = "unknown", reason = "journal unavailable",
          issued_npcs = {}, task_destinations = {}, guidance = {}, item_ownership = {
            { item_id = 3, count = 1, proof_kind = "condition", eligibility = "eligible" },
          } },
      } }, { generation = 2, status = "unknown", places = {} }, {
        { provider = "pickup", generation = 8, status = "ok", candidates = {
          { id = "pickup:one", kind = "placed_pickup", item_ids = { 2 }, target = {}, pos = pos(5),
            eligibility = "eligible", generation = 8 },
          { id = "pickup:two", kind = "placed_pickup", item_ids = { 1 }, target = {}, pos = pos(5),
            eligibility = "eligible", generation = 8 },
          { id = "pickup:unknown-task", kind = "placed_pickup", item_ids = { 3 }, target = {}, pos = pos(1),
            eligibility = "eligible", generation = 8 },
        } },
      }, core.target_registry_new())
    check("objective snapshot: same-position sources retain distinct ids and owners",
      #snapshots.targets == 2 and snapshots.targets[1].key ~= snapshots.targets[2].key
        and snapshots.targets[1].target.pos.x == snapshots.targets[2].target.pos.x
        and snapshots.targets[1].owners[1].qid ~= snapshots.targets[2].owners[1].qid)
    local two_item_routes = core.objective_routes(snapshots, nil, { npc_route_mode = 1,
      objective_places = true, focus_order = { 11, 10 }, route_cap = 8 })
    check("objective routes: multiple needed items remain separate ordinal targets in item order",
      #two_item_routes.members == 2 and two_item_routes.members[1].item_ids[1] == 1
        and two_item_routes.members[2].item_ids[1] == 2
        and two_item_routes.members[1].ordinal ~= two_item_routes.members[2].ordinal)
    local unchanged = pos(5)
    local only_unknown = core.objective_snapshot({ generation = 6, quests = {
        { qid = 12, task_index = 1, read_status = "unknown", reason = "journal unavailable",
          issued_npcs = {}, task_destinations = {}, guidance = {}, item_ownership = {
            { item_id = 3, count = 1, proof_kind = "condition", eligibility = "eligible" },
          } },
      } }, { generation = 3, status = "unknown", places = {} }, {
        { provider = "chest", generation = 9, status = "unknown", reason = "open state unreadable",
          candidates = { { id = "must-ignore", item_ids = { 3 }, target = {}, pos = pos(1), eligibility = "eligible" } } },
      }, core.target_registry_new())
    check("objective snapshot: unknown task/provider never publishes eligible candidates",
      #only_unknown.targets == 0 and #only_unknown.diagnostics >= 2
        and unchanged.x == 5)
    local base = { { key = "c:77", cat = "quest", qids = { 10 }, cid = 77, pos = pos(1) } }
    local fullmap = { { key = "c:77", cat = "quest", qids = { 10 }, cid = 77, pos = pos(1) } }
    local projected, projected_full = core.objective_markers(base, fullmap, snap,
      { objective_places = true, category_visibility = { quest = false }, names = { npcs = { [77] = "Target" } } })
    check("objective markers: category-off NPC objectives appear on both maps without mutating inputs",
      projected[1].objective == true and projected_full[1].objective == true
        and projected[1].objective_key == projected_full[1].objective_key
        and base[1].objective == nil and fullmap[1].objective == nil)
    local wired_snapshot = { generation = 12, targets = { { key = tk({ 10, "issued_npc", 77 }), generation = 12,
      ordinal = 24, kind = "npc", target = { cid = 77, pos = pos(9) },
      owners = { { qid = 10 } }, item_ids = {}, provider = "issued_npc", eligibility = "eligible" } } }
    local wired = core.compute(objadapter(), { focus_qids = { 10 }, focus_related_qids = {}, now = 0,
      objective_snapshot = wired_snapshot,
      objective_policy = { npc_route_mode = 1, objective_places = true, focus_order = { 10 } } })
    local wired_marker
    for _, marker in ipairs(wired.markers) do if marker.objective_key == wired_snapshot.targets[1].key then wired_marker = marker end end
    check("objective compute: snapshot projects before focus filtering and publishes matching routes",
      wired_marker ~= nil and wired_marker.objective == true
        and wired.objective_routes.objective_generation == 12
        and wired.objective_routes.generation == nil
        and wired.objective_routes.members[1].target_key == wired_snapshot.targets[1].key)
    local isolated = core.objective_snapshot({ generation = 7, quests = {
        { qid = 1, task_index = 0, read_status = "ok", issued_npcs = {},
          task_destinations = {}, guidance = {}, item_ownership = {
            { item_id = 4, count = 1, proof_kind = "condition", eligibility = "eligible" },
          } },
      } }, { generation = 1, status = "unknown", places = {} }, {
        { provider = "pickup", generation = 1, status = "ok", candidates = {
          { id = "shared", item_ids = { 4 }, target = {}, pos = pos(3), eligibility = "eligible", generation = 1 },
        } },
        { provider = "pickup", generation = 2, status = "ok", candidates = {
          { id = "other", item_ids = { 4 }, target = {}, pos = pos(3), eligibility = "eligible", generation = 2 },
        } },
      }, core.target_registry_new())
    check("objective snapshot: shared-source evidence merges by id, same-place source stays distinct",
      #isolated.targets == 2 and isolated.targets[1].key ~= isolated.targets[2].key
        and isolated.targets[1].target.pos.x == isolated.targets[2].target.pos.x)
    local place_task = { generation = 8, quests = { { qid = 30, task_index = 0,
      read_status = "ok", issued_npcs = {}, task_destinations = {
        { kind = "place", task_index = 0, destination_index = 4,
          target = { place = { kind = "key_location", key = 11 } }, eligibility = "eligible" },
      }, guidance = {}, item_ownership = {} } } }
    local wrong_place = core.objective_snapshot(place_task, { generation = 2, status = "ok", places = {
      { qid = 30, task_index = 0, owner_kind = "task", owner_index = 0, signal_index = 4,
        target = { kind = "key_location", key = 12 }, pos = pos(4), eligibility = "eligible" },
    } }, {}, core.target_registry_new())
    check("objective places: index match with different place identity is rejected", #wrong_place.targets == 0)
    local exact_place = core.objective_snapshot(place_task, { generation = 2, status = "ok", places = {
      { qid = 30, task_index = 0, owner_kind = "task", owner_index = 0, signal_index = 4,
        target = { kind = "key_location", key = 11 }, pos = pos(4), eligibility = "eligible" },
    } }, {}, core.target_registry_new())
    check("objective places: exact owner and target identity resolves its position",
      #exact_place.targets == 1 and exact_place.targets[1].target.pos.x == 4)
    local owner_snapshot = { generation = 9, quests = {
      { qid = 11, task_index = 2, read_status = "ok", issued_npcs = {}, task_destinations = {}, guidance = {},
        item_ownership = { { item_id = 7, count = 1, proof_kind = "condition", eligibility = "eligible" } } },
      { qid = 10, task_index = 1, read_status = "ok", issued_npcs = {}, task_destinations = {}, guidance = {},
        item_ownership = { { item_id = 7, count = 1, proof_kind = "delivery", eligibility = "eligible" } } },
    } }
    local owner_registry = core.target_registry_new()
    local shared = core.objective_snapshot(owner_snapshot, { status = "unknown", places = {} }, {
      { provider = "pickup", generation = 1, status = "ok", candidates = {
        { id = "shared-source", item_ids = { 7 }, target = {}, pos = pos(6), eligibility = "eligible", generation = 1 },
      } },
      { provider = "pickup", generation = 2, status = "ok", candidates = {
        { id = "shared-source", item_ids = { 7 }, target = {}, pos = pos(6), eligibility = "eligible", generation = 2 },
      } },
    }, owner_registry)
    check("objective snapshot: repeated source id unions sorted owners and keeps task indices",
      #shared.targets == 1 and #shared.targets[1].owners == 2
        and shared.targets[1].owners[1].qid == 10 and shared.targets[1].owners[1].task_index == 1
        and shared.targets[1].owners[2].qid == 11 and shared.targets[1].owners[2].task_index == 2)
    local owner_removed = core.objective_snapshot({ generation = 10, quests = { owner_snapshot.quests[1] } },
      { status = "unknown", places = {} }, {
      { provider = "pickup", generation = 3, status = "ok", candidates = {
        { id = "shared-source", item_ids = { 7 }, target = {}, pos = pos(6), eligibility = "eligible", generation = 3 },
        } },
      }, owner_registry)
    check("objective snapshot: losing one owner removes only that owner and retains key ordinal",
      #owner_removed.targets == 1 and #owner_removed.targets[1].owners == 1
        and owner_removed.targets[1].owners[1].qid == 11
        and owner_removed.targets[1].ordinal == shared.targets[1].ordinal)
    local depleted = core.objective_snapshot({ generation = 11, quests = { owner_snapshot.quests[1] } },
      { status = "unknown", places = {} }, {
        { provider = "pickup", generation = 4, status = "ok", candidates = {} },
      }, owner_registry)
    check("objective snapshot: source depletion removes the prior source target",
      #depleted.targets == 0)
    local nearest = core.objective_snapshot({ generation = 12, quests = { owner_snapshot.quests[1] } },
      { status = "unknown", places = {} }, {
        { provider = "pickup", generation = 5, status = "ok", candidates = {
          { id = "z-far", item_ids = { 7 }, target = {}, pos = pos(9), eligibility = "eligible", generation = 5 },
          { id = "b-near", item_ids = { 7 }, target = {}, pos = pos(3), eligibility = "eligible", generation = 5 },
          { id = "a-near", item_ids = { 7 }, target = {}, pos = pos(-3), eligibility = "eligible", generation = 5 },
          { id = "ineligible", item_ids = { 7 }, target = {}, pos = pos(0), eligibility = "ineligible",
            reason = "not currently released" },
        } },
      }, core.target_registry_new())
    local nearest_route = core.objective_routes(nearest, pos(0),
      { npc_route_mode = 1, objective_places = true, focus_order = { 11 } })
    local no_origin_route = core.objective_routes(nearest, nil,
      { npc_route_mode = 1, objective_places = true, focus_order = { 11 } })
    check("objective routes: nearest source wins and ties use bytewise source id",
      #nearest_route.members == 1 and nearest_route.members[1].target_key == tk({ "source", "a-near" })
        and no_origin_route.members[1].target_key == tk({ "source", "a-near" }))
    check("objective routes: objective-place toggle suppresses item sources",
      #core.objective_routes(nearest, pos(0), { npc_route_mode = 1, objective_places = false }).members == 0)
    local bad_position = core.objective_snapshot({ generation = 13, quests = { owner_snapshot.quests[1] } },
      { status = "unknown", places = {} }, {
        { provider = "pickup", generation = 6, status = "ok", candidates = {
          { id = "nonfinite", item_ids = { 7 }, target = {}, pos = { x = 0 / 0, y = 0, z = 0 },
            eligibility = "eligible", generation = 6 },
        } },
      }, core.target_registry_new())
    check("objective snapshot: nonfinite source positions fail closed with a reason",
      #bad_position.targets == 0 and bad_position.diagnostics[1].reason == "source_target_unresolved")
    local search = { key = tk({ 10, "issued_npc", 77 }), ordinal = 30, kind = "npc", generation = snap.generation,
      target = { cid = 77, pos = pos(2) }, owners = { { qid = 10 } }, item_ids = {}, eligibility = "eligible" }
    local reserved = core.objective_routes(snap, pos(0), { npc_route_mode = 1, objective_places = true,
      focus_order = { 10 }, search_target = search, route_cap = 1 })
    check("objective routes: search target is reserved ahead of the route cap",
      #reserved.members == 1 and reserved.members[1].target_key == search.key)
    local order_snapshot = core.objective_snapshot({ generation = 14, focus_epoch = 2,
      journal_generation = 4, need_generation = 5, quests = {
        { qid = 10, task_index = 0, read_status = "ok", issued_npcs = {
          { kind = "npc", target = { cid = 100, pos = pos(10) }, eligibility = "eligible" },
        }, live_destination = { target = { pos = pos(10) }, eligibility = "eligible" },
          task_destinations = { { kind = "npc", task_index = 0, destination_index = 0,
            target = { cid = 101, pos = pos(11) }, eligibility = "eligible" } },
          guidance = { { concierge_index = 3, eligibility = "eligible", signals = {
            { kind = "npc", concierge_index = 3, destination_index = 1,
              target = { cid = 102, pos = pos(12) }, eligibility = "eligible" },
            { kind = "place", concierge_index = 3, destination_index = 1,
              target = { place = { kind = "key_location", key = 8 }, pos = pos(13) }, eligibility = "eligible" },
          } } }, item_ownership = {} },
        { qid = 11, task_index = 1, read_status = "ok", issued_npcs = {
          { kind = "npc", target = { cid = 110, pos = pos(20) }, eligibility = "eligible" },
        }, live_destination = { target = { pos = pos(20) }, eligibility = "eligible" },
          task_destinations = {}, guidance = {}, item_ownership = {} },
      } }, { status = "unknown", places = {} }, {}, core.target_registry_new())
    local ordered_publication = core.objective_routes(order_snapshot, pos(0),
      { npc_route_mode = 1, objective_places = true, focus_order = { 11, 10 } })
    check("objective routes: active focus and per-quest target classes define publication order",
      #ordered_publication.members == 7 and ordered_publication.members[1].qid == 11
        and ordered_publication.members[1].cid == 110
        and ordered_publication.members[2].qid == 11 and ordered_publication.members[2].direct == true
        and ordered_publication.members[3].qid == 10 and ordered_publication.members[3].cid == 100
        and ordered_publication.members[4].direct == true
        and ordered_publication.members[5].cid == 101 and ordered_publication.members[6].cid == 102
        and ordered_publication.members[7].direct == true)
    check("objective publication stamp preserves task and need generations",
      order_snapshot.stamp.focus_epoch == 2 and order_snapshot.stamp.journal_generation == 4
        and order_snapshot.stamp.need_generation == 5)
    local place_marker, place_full = core.objective_markers({}, {}, { generation = 3, targets = {
      { key = tk({ 10, "task", 0, 1, "place" }), ordinal = 31, kind = "place", generation = 3,
        target = { place = { kind = "local_area", local_area = 0 }, pos = pos(3) },
        owners = { { qid = 10, task_index = 0 } }, item_ids = {},
        provider = "task", eligibility = "eligible" },
    } }, { objective_places = true, category_visibility = { world = false } })
    check("objective markers: local-area zero gets a dedicated marker despite category off",
      #place_marker == 1 and #place_full == 1 and place_marker[1].objective_ordinal == 31
        and place_marker[1].pos.x == 3)
    local dedicated, signature_ok = core.objective_markers({}, nil, { generation = 7, targets = {
      { key = tk({ 20, "issued_npc", 4294967295 }), ordinal = 1, kind = "npc",
        target = { cid = 4294967295, pos = pos(2) }, owners = { { qid = 20 } }, item_ids = {},
        provider = "issued_npc", eligibility = "eligible", generation = 7 },
    } }, { names = { npcs = { { cid = 4294967295, name = "U32 NPC" } } } })
    local signature_call = pcall(core.signature, dedicated, {})
    check("objective markers: dedicated markers satisfy legacy signature and NPC consumers",
      #dedicated == 1 and dedicated[1].cid == 4294967295
        and table.concat(dedicated[1].qids, ",") == "20" and signature_call)
    check("objective markers: SPEC name arrays supply NPC labels",
      dedicated[1].label == "Objective: U32 NPC")

    local current_task = { catalog_version = 2, focus_epoch = 3, journal_generation = 4,
      need_generation = 5, quests = { { qid = 40, task_index = 2, read_status = "ok",
        issued_npcs = "malformed", task_destinations = {}, item_ownership = {}, guidance = {
          { concierge_index = 6, destination_index = 9, eligibility = "eligible", signals = {
            { kind = "npc", task_index = 2, target = { cid = 70, pos = pos(7) }, eligibility = "eligible" },
          } },
        } } } }
    local task_registry = core.target_registry_new()
    local guidance_ok, guidance = pcall(core.objective_snapshot, current_task,
      { generation = 1, status = "unknown", places = {} }, {}, task_registry)
    local guidance_obj = guidance_ok and guidance.targets[1] or nil
    check("objective guidance: parent index and current quest task own child target key",
      guidance_obj and guidance_obj.key == tk({ 40, "guidance", 6, 9, "npc" })
        and guidance_obj.owners[1].task_index == 2)
    local stale_task_snapshot = { catalog_version = 2, focus_epoch = 3, journal_generation = 4,
      need_generation = 5, quests = { { qid = 40, task_index = 2, read_status = "ok",
        issued_npcs = {}, item_ownership = {}, task_destinations = {
          { kind = "npc", task_index = 3, destination_index = 1,
            target = { cid = 71, pos = pos(8) }, eligibility = "eligible" },
          { kind = "npc", task_index = -1, destination_index = 2,
            target = { cid = 72, pos = pos(9) }, eligibility = "eligible" },
        }, guidance = { { concierge_index = 6, destination_index = 9, task_index = 3,
          eligibility = "eligible", signals = {
            { kind = "npc", task_index = 3, target = { cid = 73, pos = pos(10) }, eligibility = "eligible" },
          } } } } } }
    local stale_task = core.objective_snapshot(stale_task_snapshot, nil, {}, core.target_registry_new())
    check("objective guidance: future and sentinel task evidence is rejected, not relabeled current",
      #stale_task.targets == 0)
    local missing_parent_snapshot = { catalog_version = 2, focus_epoch = 3, journal_generation = 4,
      need_generation = 5, quests = { { qid = 40, task_index = 2, read_status = "ok",
        issued_npcs = {}, item_ownership = {}, task_destinations = {}, guidance = {
          { concierge_index = 6, destination_index = 9, signals = {
            { kind = "npc", target = { cid = 74, pos = pos(4) }, eligibility = "eligible" },
          } },
        } } } }
    local missing_parent = core.objective_snapshot(missing_parent_snapshot, nil, {}, core.target_registry_new())
    check("objective guidance: absent parent eligibility is rejected",
      #missing_parent.targets == 0)
    current_task.quests[1].guidance[1].eligibility = "unknown"
    local unknown_parent = core.objective_snapshot(current_task, nil, {}, core.target_registry_new())
    check("objective guidance: unknown parent suppresses all child signals",
      #unknown_parent.targets == 0)
    local malformed_issued_ok = pcall(core.objective_snapshot, { catalog_version = 2,
      focus_epoch = 1, journal_generation = 1, need_generation = 1,
      quests = { { qid = 40, task_index = 0, read_status = "ok", issued_npcs = "bad",
        item_ownership = "bad", task_destinations = "bad", guidance = "bad" } } },
      nil, "bad", core.target_registry_new())
    check("objective snapshot: malformed issued/provider arrays fail closed without throwing",
      malformed_issued_ok)

    local source_task = { catalog_version = 2, focus_epoch = 1, journal_generation = 1,
      need_generation = 1, quests = { { qid = 50, task_index = 0, read_status = "ok",
        issued_npcs = {}, task_destinations = {}, guidance = {}, item_ownership = {
          { item_id = 5, count = 1, proof_kind = "condition", eligibility = "eligible" },
        } } } }
    local source_registry = core.target_registry_new()
    local mismatch = core.objective_snapshot(source_task, nil, {
      { provider = "seller", generation = 2, status = "ok", candidates = {
        { id = "offer", kind = "shop_stock", item_ids = { 5 }, target = { cid = 88 },
          eligibility = "eligible", pos = pos(8), generation = 1 },
      } },
    }, source_registry)
    check("objective generation: stale candidate generation is rejected",
      #mismatch.targets == 0 and type(mismatch.generation) == "number" and mismatch.generation > 0)
    local no_candidate_generation = core.objective_snapshot(source_task, nil, {
      { provider = "seller", generation = 2, status = "ok", candidates = {
        { id = "offer", kind = "shop_stock", item_ids = { 5 }, target = { cid = 88 },
          eligibility = "eligible", pos = pos(8) },
      } },
    }, core.target_registry_new())
    check("objective generation: missing candidate generation is rejected",
      #no_candidate_generation.targets == 0)
    local matched = core.objective_snapshot(source_task, nil, {
      { provider = "seller", generation = 2, status = "ok", candidates = {
        { id = "offer", kind = "shop_stock", item_ids = { 5, 6 }, target = { cid = 88 },
          eligibility = "eligible", pos = pos(8), generation = 2 },
      } },
    }, source_registry)
    local stable = core.objective_snapshot(source_task, nil, {
      { provider = "seller", generation = 2, status = "ok", candidates = {
        { id = "offer", kind = "shop_stock", item_ids = { 5 }, target = { cid = 88 },
          eligibility = "eligible", pos = pos(8), generation = 2 },
      } },
    }, source_registry)
    check("objective generation: positive generation derives from declared snapshots and is stable",
      type(matched.generation) == "number" and matched.generation > 0
        and stable.generation == matched.generation
        and matched.targets[1].generation == matched.generation)
    check("objective sources: only current needed item ids receive ownership",
      matched.targets[1] ~= nil and #matched.targets[1].item_ids == 1 and matched.targets[1].item_ids[1] == 5)
    local source_routes = core.objective_routes(matched, nil,
      { npc_route_mode = 0, objective_places = true, focus_order = { 50 } })
    check("objective route publication preserves the objective snapshot generation",
      source_routes.objective_generation == matched.generation
        and source_routes.generation == nil
        and source_routes.members[1].objective_generation == matched.generation
        and source_routes.members[1].generation == nil)

    local sellers = { { key = "w:sell:1:5", cat = "seller", cid = 88, qids = { 50 }, pos = pos(8) } }
    local source_marker, source_full = core.objective_markers(sellers, sellers, matched,
      { names = { targets = { { key = matched.targets[1].key, name = "Offer" } } }, objective_places = false })
    check("objective markers: CID source reuses seller marker independent of route toggle",
      #source_marker == 1 and source_marker[1].key == "w:sell:1:5"
        and source_marker[1].objective == true and source_marker[1].label ~= "Objective: offer")
    check("objective markers: every covering target owner is unioned",
      source_marker[1] ~= nil and type(source_marker[1].objective_qids) == "table"
        and table.concat(source_marker[1].objective_qids, ",") == "50")
    local multi_cover_input = { { key = "n:70", cat = "quest", cid = 70, qids = {} } }
    local multi_cover = core.objective_markers(multi_cover_input, nil,
      { generation = 3, targets = {
        { key = tk({ 40, "issued_npc", 70 }), ordinal = 1, kind = "npc", target = { cid = 70 },
          owners = { { qid = 40 } }, item_ids = {}, eligibility = "eligible", generation = 3 },
        { key = tk({ 41, "issued_npc", 70 }), ordinal = 2, kind = "npc", target = { cid = 70 },
          owners = { { qid = 41 } }, item_ids = {}, eligibility = "eligible", generation = 3 },
      } }, {})
    check("objective markers: shared covering marker unions owner qids",
      multi_cover[1] ~= nil and type(multi_cover[1].objective_qids) == "table"
        and table.concat(multi_cover[1].objective_qids, ",") == "40,41"
        and #multi_cover_input[1].qids == 0)

    local route_cid_source = core.objective_routes(matched, nil,
      { npc_route_mode = 0, objective_places = true, focus_order = { 50 },
        names = { npcs = { { cid = 88, name = "Seller" } } } })
    check("objective routes: seller source uses direct ordinal id and copied position",
      #route_cid_source.members == 1 and route_cid_source.members[1].direct == true
        and route_cid_source.members[1].route_id == core.objective_direct_route_id(matched.targets[1].ordinal)
        and route_cid_source.members[1].cid == nil and route_cid_source.members[1].pos.x == 8
        and route_cid_source.members[1].pos ~= matched.targets[1].target.pos)
    local ancillary = core.objective_routes({ generation = 9, targets = {} }, nil,
      { npc_route_mode = 2, objective_places = false, shown_ancillary = { { qid = 50, cid = 99, name = "Ally" } } })
    check("objective routes: SPEC ancillary row does not need an undocumented position",
      #ancillary.members == 1 and ancillary.members[1].qid == 50
        and ancillary.members[1].cid == 99 and ancillary.members[1].pos == nil
        and ancillary.members[1].route_id == 99 and ancillary.members[1].kind == "npc"
        and ancillary.members[1].direct == false
        and type(ancillary.members[1].item_ids) == "table" and #ancillary.members[1].item_ids == 0
        and ancillary.members[1].objective_generation == 9
        and ancillary.members[1].generation == nil
        and ancillary.members[1].target_key == nil
        and ancillary.members[1].ordinal == nil and ancillary.members[1].place == nil)

    local marker_toggle_off = core.objective_markers({}, nil, { generation = 4, targets = {
      { key = tk({ 40, "task", 0, 1, "place" }), ordinal = 4, kind = "place",
        target = { place = { kind = "key_location", key = 7 }, pos = pos(7) },
        owners = { { qid = 40, task_index = 0 } }, item_ids = {}, eligibility = "eligible", generation = 4 },
    } }, { objective_places = false })
    check("objective markers: objective route toggle does not hide eligible places",
      #marker_toggle_off == 1 and marker_toggle_off[1].objective == true)

    local invalid_coverage_input = {
      { key = "w:place", cat = "world", qids = {} },
      { key = "n:88", cat = "quest", cid = 88, qids = {} },
      { key = "n:70", cat = "quest", cid = 70, qids = {} },
      { key = "n:0", cat = "quest", cid = 0, qids = {} },
      { key = "n:89", cat = "quest", cid = 89, qids = {} },
    }
    local invalid_coverage = core.objective_markers(invalid_coverage_input, nil, { generation = 4, targets = {
      { key = "place-without-id", ordinal = 5, kind = "place", generation = 4,
        target = { place = { kind = "key_location", key = 8 } }, owners = { { qid = 40 } }, item_ids = {}, eligibility = "eligible" },
      { key = "stale-npc", ordinal = 6, kind = "npc", generation = 3,
        target = { cid = 88 }, owners = { { qid = 40 } }, item_ids = {}, eligibility = "eligible" },
      { key = "ineligible-npc", ordinal = 7, kind = "npc", generation = 4,
        target = { cid = 70 }, owners = { { qid = 40 } }, item_ids = {}, eligibility = "unknown" },
      { key = "invalid-npc", ordinal = 8, kind = "npc", generation = 4,
        target = { cid = 0 }, owners = { { qid = 40 } }, item_ids = {}, eligibility = "eligible" },
      { key = "missing-generation-npc", ordinal = 9, kind = "npc",
        target = { cid = 89 }, owners = { { qid = 40 } }, item_ids = {}, eligibility = "eligible" },
    } }, {})
    check("objective markers: generation, eligibility, and target domain gate attachment",
      invalid_coverage[1].objective == nil and invalid_coverage[2].objective == nil
        and invalid_coverage[3].objective == nil and invalid_coverage[4].objective == nil
        and invalid_coverage[5].objective == nil)

    local negative_place_task = { focus_epoch = 1, journal_generation = 1, need_generation = 1,
      quests = { { qid = 40, task_index = 0, read_status = "ok", issued_npcs = {},
        item_ownership = {}, guidance = {}, task_destinations = {
          { kind = "place", task_index = 0, destination_index = 0,
            target = { place = { kind = "key_location", key = -1 }, pos = pos(1) },
            eligibility = "eligible" },
        } } } }
    local negative_place_snapshot = core.objective_snapshot(negative_place_task, nil, {}, core.target_registry_new())
    local negative_place_record = { key = tk({ 40, "task", 0, 0, "place" }), ordinal = 1,
      kind = "place", generation = negative_place_snapshot.generation,
      target = { place = { kind = "key_location", key = -1 }, pos = pos(1) },
      owners = { { qid = 40, task_index = 0 } }, item_ids = {}, eligibility = "eligible" }
    local negative_place_view = { generation = negative_place_snapshot.generation,
      targets = { negative_place_record } }
    local negative_place_markers = core.objective_markers({}, nil, negative_place_view, {})
    local negative_place_routes = core.objective_routes(negative_place_view, nil,
      { npc_route_mode = 1, objective_places = true })
    check("objective place domain: negative key_location is rejected by snapshot, markers, and routes",
      #negative_place_snapshot.targets == 0 and #negative_place_markers == 0
        and #negative_place_routes.members == 0)

    local legacy_only = core.compute(objadapter(), { focus_qids = { 10 }, focus_related_qids = {}, now = 0,
      objective_snapshot = { generation = 2, stamp = {}, targets = {} },
      objective_policy = { npc_route_mode = 1, objective_places = true, focus_order = { 10 } } })
    local stale_legacy = false
    for _, marker in ipairs(legacy_only.markers) do if marker.objective == true then stale_legacy = true end end
    check("objective compute: supplied empty snapshot suppresses legacy issued/live/item objectives",
      not stale_legacy and #legacy_only.objective_routes.members == 0
        and #(legacy_only.focus.quests[10].objective.npcs or {}) == 0
        and legacy_only.focus.quests[10].objective.place == nil
        and #(legacy_only.focus.quests[10].objective.items or {}) == 0)
  end
  end)()
end

if failures > 0 then os.exit(1) end
print("core_test: all OK")
