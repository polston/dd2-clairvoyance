-- tests/world_test.lua - drives Clairvoyance/world.lua with a fake
-- reads table, a fake adapter and a fake io, all counting every call
-- (SPEC 17.3, 17.10). Pure Lua; no sdk.
package.path = package.path .. ";./reframework/autorun/?.lua"
local world = require("Clairvoyance.world")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

local K = world.K
local NAN = 0 / 0

local function on(...)
  local t = {}
  for _, k in ipairs({ ... }) do t[k] = true end
  return t
end
local ALL = on("chests", "treasure", "tokens", "beetles", "monsters", "sellers")
local NONE = {}

local function total(t)
  local n = 0
  for _, v in pairs(t) do n = n + v end
  return n
end

local function P(x, y, z) return { x = x, y = y, z = z } end

-- One fixture = fake reads + adapter + io, each call counted by name.
local function fixture(o)
  o = o or {}
  local f = { files = o.files or {}, dumps = {}, clock_t = 0, load_cost = 0,
    load_raises = {}, reads_n = {}, adapter_n = {}, fail = {}, afail = {},
    data = {
      reserved = {}, loaded = {}, sched = {}, icons = {}, msgs = {},
      records = {}, nodes = {}, checked = {}, icons_found = {}, disc_n = 0,
      sched_ids = {}, shop = {}, shops = {}, respawn = {}, boss = {},
      loaded_boss = {}, badge = {}, badge_default = "Griffin",
      catalog = {}, cast = {}, needs = {}, locs = {}, qstate = {},
      alive = true, npcpos = {}, iname = {}, npcname = {}, qname = {},
      drops = { [5] = { 230, 231 }, [9] = { 241 } },
    } }
  local d = f.data
  f.reads = {}
  local function def(name, fn)
    f.reads[name] = function(...)
      f.reads_n[name] = (f.reads_n[name] or 0) + 1
      if f.fail[name] then error("fake read failure: " .. name) end
      return fn(...)
    end
  end
  def("reserved_rows", function() return d.reserved end)
  def("loaded_gimmicks", function() return d.loaded end)
  def("schedule_pos", function(cid) return d.sched[cid] end)
  def("map_icons", function() return d.icons end)
  def("msg", function(id) return d.msgs[id] end)
  def("save_records", function() return d.records end)
  def("treasure_nodes", function() return d.nodes end)
  def("checked_nodes", function() return d.checked end)
  def("discovered_icons", function() return d.icons_found end)
  def("discovered_count", function() return d.disc_n end)
  def("schedule_ids", function() return d.sched_ids end)
  def("shop_of", function(cid) return d.shop[cid] end)
  def("shops", function() return d.shops end)
  def("respawn_units", function() return d.respawn end)
  def("monster_drops", function()
    d.drops_calls = (d.drops_calls or 0) + 1
    return d.drops
  end)
  def("boss_families", function() return d.boss end)
  def("loaded_boss_families", function() return d.loaded_boss end)
  def("badge_name", function(id)
    local b = d.badge[id]
    if b == nil then return d.badge_default end
    return b
  end)

  f.adapter = {}
  local function adef(name, fn)
    f.adapter[name] = function(...)
      f.adapter_n[name] = (f.adapter_n[name] or 0) + 1
      if f.afail[name] then error("fake adapter failure: " .. name) end
      return fn(...)
    end
  end
  adef("quest_state", function(q) return d.qstate[q] end)
  adef("item_needs", function() return d.needs end)
  adef("item_locations", function() return d.locs end)
  adef("catalog_ids", function() return d.catalog end)
  adef("cast_ids", function(q) return d.cast[q] end)
  adef("npc_alive", function() return d.alive end)
  adef("npc_pos", function(cid)
    local p = d.npcpos[cid]
    if p == nil then return nil end
    return p.x, p.y, p.z
  end)
  adef("item_name", function(id) return d.iname[id] end)
  adef("npc_name", function(cid) return d.npcname[cid] end)
  adef("quest_name", function(q) return d.qname[q] end)

  f.io = {
    load = function(path)
      if f.load_raises[path] then error("fake load failure") end
      if path == K.PLACES then f.clock_t = f.clock_t + f.load_cost end
      return f.files[path]
    end,
    dump = function(path, t)
      f.dumps[#f.dumps + 1] = { path = path, t = t }
      f.files[path] = t
      return true
    end,
    clock = function() return f.clock_t end,
  }
  function f.new() return world.new(f.adapter, f.reads, f.io) end
  function f.clear_counts() f.reads_n, f.adapter_n = {}, {} end
  function f.dumps_of(path)
    local n = 0
    for _, dd in ipairs(f.dumps) do if dd.path == path then n = n + 1 end end
    return n
  end
  return f
end

local function chest_row(uid, x, z, ix)
  return { uid = uid, pos = P(x, 0, z), gimmick = 10, table_ix = ix or 1 }
end

local function find(list, uid)
  for _, e in ipairs(list or {}) do if e.uid == uid then return e end end
  return nil
end

local function places(rows, pak)
  return { version = 1, pak = pak or "1:1", rows = rows }
end

local function prow(k, uid, id, x, z, extra)
  local r = { k = k, uid = uid, id = id, x = x, y = 0, z = z, src = "normal" }
  for kk, v in pairs(extra or {}) do r[kk] = v end
  return r
end

-- 1. atlas_merge_overwrite
do
  local f = fixture()
  local w = f.new()
  f.data.reserved = { chest_row("c1", 10, 10) }
  w:refresh(0, true, on("chests"))
  f.data.reserved = { chest_row("c1", 50, 60) }
  w:refresh(10, true, on("chests"))
  local ch = w:input().chests
  check("merge: one entry", #ch == 1)
  check("merge: new position", ch[1] and ch[1].pos.x == 50 and ch[1].pos.z == 60)
end

-- 2. atlas_remove_patched
do
  local function scenario(neigh_count, neigh_ix, gap)
    local f = fixture()
    local w = f.new()
    f.data.reserved = { chest_row("c1", 100, 100, 5) }
    w:refresh(0, true, on("chests"))
    local rows = {}
    for i = 1, neigh_count do
      rows[#rows + 1] = chest_row("n" .. i, 100 + (gap or i), 100, neigh_ix)
    end
    f.data.reserved = rows
    w:refresh(10, true, on("chests"))
    return find(w:input().chests, "c1") ~= nil
  end
  check("remove: 3 own-table neighbours removes", scenario(3, 5) == false)
  check("remove: 2 own-table neighbours stays", scenario(2, 5) == true)
  check("remove: 3 other-table neighbours stays", scenario(3, 6) == true)
  check("remove: neighbours 51 units away do not count", scenario(3, 5, 51) == true)
  check("remove: neighbours 49 units away count", scenario(3, 5, 49) == false)

  local f = fixture({ files = { [K.PLACES] = places({ prow("chest", "f1", 10, 100, 100) }) } })
  local w = f.new()
  f.data.loaded = { { uid = "L1", gimmick = 10, pos = P(100, 0, 100) } }
  f.data.reserved = { chest_row("n1", 101, 100, 5), chest_row("n2", 102, 100, 5),
    chest_row("n3", 103, 100, 5) }
  w:refresh(0, true, on("chests"))
  check("remove: unlisted learned entry learned", find(w:input().chests, "l1") ~= nil)
  f.data.loaded = {}
  w:refresh(10, true, on("chests"))
  check("remove: file entry never removed", find(w:input().chests, "f1") ~= nil)
  check("remove: learned entry without table_ix never removed",
    find(w:input().chests, "l1") ~= nil)
end

-- 3. atlas_load_rejects
do
  local f = fixture({ files = { [K.ATLAS] = "junk" } })
  local w = f.new()
  check("rejects: non-table gives empty atlas", w:stats().atlas.learned == 0)
  f.data.reserved = { chest_row("c1", 10, 10) }
  w:refresh(0, true, on("chests"))
  check("rejects: next save overwrites",
    f.dumps_of(K.ATLAS) == 1 and f.dumps[#f.dumps].t.entries.c1 ~= nil)

  local f2 = fixture()
  f2.load_raises[K.ATLAS] = true
  local ok, w2 = pcall(f2.new)
  check("rejects: raising load does not raise", ok)
  f2.data.reserved = { chest_row("c1", 10, 10) }
  w2:refresh(0, true, on("chests"))
  check("rejects: raising load starts empty and saves", f2.dumps_of(K.ATLAS) == 1)

  local f3 = fixture({ files = { [K.ATLAS] = { version = 2,
    entries = { a = { k = "chest", id = 10, x = 1, y = 2, z = 3 } } } } })
  local w3 = f3.new()
  check("rejects: version 2 dumps the old copy once", f3.dumps_of(K.OLD_ATLAS) == 1)
  check("rejects: version 2 starts empty", w3:stats().atlas.learned == 0)

  local f4 = fixture({ files = { [K.ATLAS] = { version = 1, entries = {
    a = { k = "x", id = 1, x = 1, y = 1, z = 1 },
    b = { k = "chest", id = 10, x = NAN, y = 1, z = 1 },
    c = { k = "token", id = 167, x = 1, y = 2, z = 3 },
    d = { k = "beetle", id = 161, x = 4, y = 5, z = 6 } } } } })
  local w4 = f4.new()
  check("rejects: unknown k and NaN dropped and counted",
    w4:stats().atlas.dropped == 2 and w4:stats().atlas.learned == 2)
  w4:refresh(0, true, on("tokens", "beetles"))
  check("rejects: token and beetle survive a load",
    find(w4:input().tokens, "c") ~= nil and find(w4:input().beetles, "d") ~= nil)
end

-- 4. atlas_rows_near_zero
do
  local f = fixture()
  local w = f.new()
  f.data.reserved = { { uid = "z1", pos = P(0.5, 0.2, 0.1), gimmick = 10, table_ix = 1 } }
  w:refresh(0, true, on("chests"))
  check("near zero: not learned", w:stats().atlas.learned == 0 and #w:input().chests == 0)
end

-- 5. atlas_save_rate
do
  local f = fixture()
  local w = f.new()
  f.data.reserved = { chest_row("c1", 10, 10) }
  w:refresh(0, true, on("chests"))
  f.data.reserved = { chest_row("c1", 20, 10) }
  w:refresh(30, true, on("chests"))
  check("save rate: two rounds 30 s apart save once", f.dumps_of(K.ATLAS) == 1)
  f.data.reserved = { chest_row("c1", 30, 10) }
  w:refresh(60, true, on("chests"))
  check("save rate: a round 60 s after the save saves again", f.dumps_of(K.ATLAS) == 2)
  local n = f.dumps_of(K.ATLAS)
  f.data.reserved = { chest_row("c1", 40, 10) }
  w:refresh(100, false, ALL)
  check("save rate: failed-gate round never saves", f.dumps_of(K.ATLAS) == n)
  w:save("reset")
  check("save rate: changed entry flushes on w:save", f.dumps_of(K.ATLAS) == n)

  local f2 = fixture()
  local w2 = f2.new()
  f2.data.reserved = { chest_row("c1", 10, 10) }
  w2:refresh(0, true, on("chests"))
  local n2 = f2.dumps_of(K.ATLAS)
  w2:save("reset")
  check("save rate: no change, no dump", f2.dumps_of(K.ATLAS) == n2)

  local f3 = fixture({ files = { [K.ATLAS] = f2.files[K.ATLAS] } })
  local w3 = f3.new()
  w3:save("config")
  check("save rate: loaded atlas, no committed round, no dump", f3.dumps_of(K.ATLAS) == 0)

  local f4 = fixture()
  local w4 = f4.new()
  f4.data.reserved = { chest_row("c1", 10, 10) }
  w4:refresh(0, true, on("chests"))
  f4.data.reserved = { chest_row("c1", 20, 10) }
  w4:refresh(10, true, on("chests"))
  local n4 = f4.dumps_of(K.ATLAS)
  w4:reset()
  w4:save("reset")
  check("save rate: no dump after reset until a round commits", f4.dumps_of(K.ATLAS) == n4)
  w4:refresh(40, true, on("chests"))
  w4:save("config")
  check("save rate: dump after the next committed round", f4.dumps_of(K.ATLAS) == n4 + 1)
end

-- 6. chest_state
do
  local f = fixture({ files = { [K.PLACES] = places({
    prow("chest", "p1", 10, 1, 1, { items = { { id = 7, n = 2 }, { id = 8, n = 1 } } }) }) } })
  f.data.iname = { [305] = "Seeker's Token", [8] = "Potion" }
  f.data.reserved = { chest_row("g1", 10, 10), chest_row("g2", 20, 20), chest_row("g3", 30, 30) }
  f.data.records = { { key = "g1_0", picked = true, item = 305 },
    { key = "g2_0", picked = false } }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  local ch = w:input().chests
  check("chest state: opened", find(ch, "g1").state == "opened")
  check("chest state: unopened", find(ch, "g2").state == "unopened")
  check("chest state: unknown", find(ch, "g3").state == "unknown")
  check("chest state: item name from adapter",
    find(ch, "g1").item == 305 and find(ch, "g1").item_name == "Seeker's Token")
  local p1 = find(ch, "p1")
  check("chest items: names from the adapter", p1.items[2].name == "Potion" and p1.items[2].n == 1)
  check("chest items: Item N when no name", p1.items[1].name == "Item 7" and p1.items[1].n == 2)
end

-- helpers for monsters
local function mrow(uid, cid, name, x, z, ix)
  return { uid = uid, cid = cid, cid_name = name, pos = P(x, 0, z), table_ix = ix or 1 }
end

-- 7. respawn_suffix
do
  local f = fixture()
  f.data.boss = { ch253 = true }
  f.data.reserved = { mrow("m1", 1001, "ch253000_00", 10, 10) }
  f.data.respawn = { { key = "m1_0", cid = 1001, cid_name = "ch253000_00", pos = P(10, 0, 10) } }
  local w = f.new()
  w:refresh(0, true, on("monsters"))
  local m = w:input().monsters
  check("respawn: matched entry gets respawning, no second monster",
    #m == 1 and m[1].respawning == true)

  local f2 = fixture()
  f2.data.boss = { ch253 = true }
  f2.data.respawn = { { key = "zz_0", cid = 1002, cid_name = "ch253002_00", pos = P(300, 0, 300) } }
  local w2 = f2.new()
  w2:refresh(0, true, on("monsters"))
  local m2 = w2:input().monsters
  check("respawn: unmatched unit gives one respawning monster at its position",
    #m2 == 1 and m2[1].respawning == true and m2[1].pos.x == 300)

  local f3 = fixture()
  f3.data.respawn = { { key = "an_0", cid = 1003, cid_name = "ch299001_A_00", pos = P(5, 0, 5) } }
  local w3 = f3.new()
  w3:refresh(0, true, on("monsters"))
  check("respawn: ch299 gives no monster", #w3:input().monsters == 0)
end

-- 8. giver_rows
do
  local f = fixture()
  f.data.catalog = { 20200 }
  f.data.cast = { [20200] = { 2001, 1500 } }
  f.data.reserved = { mrow("s1", 2001, "ch253001_00", 40, 50) }
  local w = f.new()
  w:refresh(0, true, ALL)
  local g = w:givers()[2001]
  check("giver: in w:givers", g ~= nil and g.x == 40 and g.z == 50)
  local in_list = false
  for _, cat in ipairs({ "chests", "treasure", "tokens", "beetles", "monsters", "sellers" }) do
    if #w:input()[cat] > 0 then in_list = true end
  end
  check("giver: in no category list", not in_list)
  f.data.reserved = {}
  w:refresh(10, true, ALL)
  check("giver: survives a round without the row", w:givers()[2001] ~= nil)
  local dump = f.dumps[#f.dumps]
  check("giver: dumped", dump ~= nil and dump.t.entries.s1 ~= nil and dump.t.entries.s1.k == "giver")

  local f2 = fixture({ files = { [K.ATLAS] = dump.t } })
  local w2 = f2.new()
  check("giver: fresh world has it", w2:givers()[2001] ~= nil)
  check("giver: fresh world made no reads or adapter calls",
    total(f2.reads_n) == 0 and total(f2.adapter_n) == 0)

  local f3 = fixture({ files = { [K.PLACES] = places({
    prow("chara", "pg", 2001, 7, 8, { name = "ch253001_00" }) }) } })
  f3.data.catalog = { 20200 }
  f3.data.cast = { [20200] = { 2001 } }
  local w3 = f3.new()
  w3:refresh(0, true, ALL)
  check("giver: places chara row with a cast id becomes a giver", w3:givers()[2001] ~= nil)
  check("giver: places giver in no list", #w3:input().monsters == 0)
  local d3 = f3.dumps[#f3.dumps]
  check("giver: places giver dumped as learned giver",
    d3 ~= nil and d3.t.entries.pg ~= nil and d3.t.entries.pg.k == "giver")
end

-- 9. seller_gate
do
  local function seller_world(mod)
    local f = fixture()
    local d = f.data
    d.needs = { [100] = { { id = 378, num = 1 } }, [90] = { { id = 378, num = 1 } } }
    d.qname = { [90] = "Ninety", [100] = "Hundred" }
    d.iname = { [378] = "Grimoire" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.shops = { [41] = { { item = 378, release_qid = 0, sentiment_bit = 0,
      total_pay = 0, flag = 0, var_cond = 0 } } }
    if mod then mod(f) end
    local w = f.new()
    w:refresh(0, true, on("sellers"))
    return w:input().sellers
  end
  local s = seller_world()
  check("seller: one seller", #s == 1)
  check("seller: npc from adapter", s[1] and s[1].npc == "Dudley")
  check("seller: quest names ascending", s[1] and s[1].quest == "Ninety / Hundred"
    and s[1].qids[1] == 90 and s[1].qids[2] == 100)
  check("seller: not locked", s[1] and s[1].maybe_locked == false)
  check("seller: gated by an incomplete quest", #seller_world(function(f)
    f.data.shops[41][1].release_qid = 555
    f.data.qstate[555] = "in_progress"
  end) == 0)
  check("seller: completed gate quest passes", #seller_world(function(f)
    f.data.shops[41][1].release_qid = 555
    f.data.qstate[555] = "completed"
  end) == 1)
  check("seller: release_qid -1 means no gate", #seller_world(function(f)
    f.data.shops[41][1].release_qid = -1
  end) == 1)
  local locked = seller_world(function(f) f.data.shops[41][1].flag = 5 end)
  check("seller: non-zero flag sets maybe_locked", locked[1] and locked[1].maybe_locked == true)
  check("seller: unset schedule position skips", #seller_world(function(f)
    f.data.sched[2058] = P(0.3, 0.2, 0.1)
  end) == 0)
  check("seller: item with a location gives none", #seller_world(function(f)
    f.data.locs = { { id = 378, pos = P(1, 1, 1), src = "placed" } }
  end) == 0)
end

-- 10. cast_nil_retry
do
  local f = fixture()
  f.data.catalog = { 1, 2 }
  f.data.cast = { [1] = { 2001 } }
  f.data.boss = { ch253 = true }
  f.data.reserved = { mrow("m1", 1001, "ch253000_00", 10, 10) }
  local w = f.new()
  w:refresh(0, true, on("monsters"))
  check("cast nil: no monsters", #w:input().monsters == 0)
  f.data.cast[2] = {}
  w:refresh(10, true, on("monsters"))
  check("cast nil: next round builds the set", #w:input().monsters == 1)
end

-- 11. round_gated_zero_calls
do
  local f = fixture()
  f.data.reserved = { chest_row("c1", 10, 10) }
  local w = f.new()
  w:refresh(0, false, ALL)
  w:refresh(1, true, NONE)
  check("gated: zero reads and adapter calls",
    total(f.reads_n) == 0 and total(f.adapter_n) == 0)
  check("gated: no input", w:input() == nil)

  local f2 = fixture()
  f2.data.reserved = { chest_row("c1", 10, 10) }
  local w2 = f2.new()
  w2:refresh(0, true, on("chests"))
  local n = f2.reads_n
  check("chests only: reserved rows read", (n.reserved_rows or 0) >= 1)
  local zero = true
  for _, name in ipairs({ "shop_of", "shops", "badge_name", "treasure_nodes",
    "checked_nodes", "respawn_units", "discovered_count" }) do
    if (n[name] or 0) ~= 0 then zero = false; print("  called: " .. name) end
  end
  check("chests only: no calls to other categories' sources", zero)

  local f3 = fixture()
  f3.data.catalog = { 1 }
  f3.data.cast = { [1] = { 2001 } }
  f3.data.reserved = { mrow("s1", 2001, "ch253001_00", 40, 50) }
  local w3 = f3.new()
  w3:refresh(0, true, on("treasure"))
  check("treasure only: still learns a giver row", w3:givers()[2001] ~= nil)
end

-- 12. round_clock
do
  local f = fixture()
  f.data.reserved = { chest_row("c1", 10, 10) }
  local w = f.new()
  w:refresh(0, true, ALL)
  f:clear_counts()
  local r = w:refresh(5, true, ALL)
  check("clock: second refresh within 10 s returns false", r == false)
  check("clock: second refresh makes zero calls",
    total(f.reads_n) == 0 and total(f.adapter_n) == 0)
  check("clock: refresh at 10 s runs", w:refresh(10, true, ALL) == true)
end

-- 13. failed_read_keeps_one_round
do
  local f = fixture()
  f.data.reserved = { chest_row("c1", 10, 10),
    { uid = "t1", pos = P(20, 0, 20), gimmick = 167, table_ix = 1 },
    { uid = "b1", pos = P(30, 0, 30), gimmick = 161, table_ix = 1 } }
  f.data.records = { { key = "c1_0", picked = true }, { key = "t1_0", free_bit = 65536 },
    { key = "b1_0", gather_num = 0 } }
  local w = f.new()
  w:refresh(0, true, on("chests", "tokens", "beetles"))
  local function states()
    local i = w:input()
    return i.chests[1].state, i.tokens[1].state, i.beetles[1].state
  end
  local c, t, b = states()
  check("records: good round", c == "opened" and t == "collected" and b == "collected")
  f.fail.save_records = true
  w:refresh(10, true, on("chests", "tokens", "beetles"))
  c, t, b = states()
  check("records: kept one round", c == "opened" and t == "collected" and b == "collected")
  w:refresh(20, true, on("chests", "tokens", "beetles"))
  c, t, b = states()
  check("records: unknown after the second failure",
    c == "unknown" and t == "unknown" and b == "unknown")

  local f2 = fixture()
  f2.data.nodes = { { name = "Gimmick_Treasure_007", pos = P(1, 0, 1) } }
  f2.data.checked = { Gimmick_Treasure_007 = true }
  local w2 = f2.new()
  w2:refresh(0, true, on("treasure"))
  f2.fail.checked_nodes = true
  w2:refresh(10, true, on("treasure"))
  check("checked: kept one round", w2:input().treasure[1].checked == true)
  w2:refresh(20, true, on("treasure"))
  check("checked: cleared after two failures", w2:input().treasure[1].checked == false)

  local f3 = fixture()
  local d = f3.data
  d.needs = { [100] = { { id = 378, num = 1 } } }
  d.sched_ids = { 2058 }; d.shop = { [2058] = 41 }; d.sched = { [2058] = P(100, 0, 100) }
  d.shops = { [41] = { { item = 378, release_qid = 0 } } }
  local w3 = f3.new()
  w3:refresh(0, true, on("sellers"))
  check("sellers: built", #w3:input().sellers == 1)
  f3.afail.item_locations = true
  w3:refresh(10, true, on("sellers"))
  check("sellers: kept one round", #w3:input().sellers == 1)
  w3:refresh(20, true, on("sellers"))
  check("sellers: cleared after two failures", #w3:input().sellers == 0)

  local f4 = fixture()
  f4.data.boss = { ch253 = true }
  f4.data.reserved = { mrow("m1", 1001, "ch253000_00", 10, 10) }
  f4.data.respawn = { { key = "m1_0", cid = 1001, cid_name = "ch253000_00", pos = P(10, 0, 10) } }
  local w4 = f4.new()
  w4:refresh(0, true, on("monsters"))
  f4.fail.respawn_units = true
  w4:refresh(10, true, on("monsters"))
  check("respawn: kept one round", w4:input().monsters[1].respawning == true)
  w4:refresh(20, true, on("monsters"))
  check("respawn: cleared after two failures", w4:input().monsters[1].respawning == false)
end

-- 14. reset_keeps_atlas
do
  local f = fixture({ files = { [K.PLACES] = places({
    prow("chara", "pc", 1, 500, 500, { name = "ch253000_00" }) }) } })
  local d = f.data
  d.boss = { ch253 = true }
  d.reserved = { chest_row("c1", 10, 10) }
  d.records = { { key = "c1_0", picked = true } }
  d.nodes = { { name = "Gimmick_Treasure_001", pos = P(1, 0, 1) } }
  d.icons = { { type = 68, pos = P(5, 0, 5), disp_id = "s1", icon_id = 77 } }
  d.msgs = { s1 = "Vernworth" }
  d.needs = { [100] = { { id = 378, num = 1 } } }
  d.sched_ids = { 2058 }; d.shop = { [2058] = 41 }; d.sched = { [2058] = P(100, 0, 100) }
  d.shops = { [41] = { { item = 378, release_qid = 0 } } }
  d.respawn = {}
  local w = f.new()
  w:refresh(0, true, ALL)
  check("reset: pre-reset monster is large", w:input().monsters[1].small == false)
  local learned_before = w:stats().atlas.learned
  w:reset()
  check("reset: input nil", w:input() == nil)
  check("reset: atlas kept", w:stats().atlas.learned == learned_before and learned_before >= 1)
  f.clear_counts()
  d.boss = {}
  f.fail.save_records = true
  w:refresh(10, true, ALL)
  local n = f.reads_n
  check("reset: fixed sources re-read",
    n.treasure_nodes == 1 and n.shops == 1 and n.map_icons == 1 and n.msg == 1
    and n.schedule_ids == 1 and n.boss_families == 1)
  check("reset: chara rows re-sorted", w:input().monsters[1].small == true)
  check("reset: chest state cleared", w:input().chests[1].state == "unknown")
  check("reset: seller state rebuilt", #w:input().sellers == 1)
end

-- 15. discovery_recompute
do
  local f = fixture()
  local d = f.data
  d.nodes = { { name = "Gimmick_Treasure_001", pos = P(5, 0, 6) } }
  d.icons = { { type = 68, pos = P(5, 0, 5), disp_id = "s1", icon_id = 77 } }
  d.msgs = { s1 = "Vernworth" }
  d.disc_n = 1
  local w = f.new()
  w:refresh(0, true, on("treasure"))
  check("discovery: undiscovered at first", w:input().treasure[1].discovered == false)
  d.icons_found = { [77] = true }
  w:refresh(10, true, on("treasure"))
  check("discovery: unchanged count keeps the old answer",
    w:input().treasure[1].discovered == false)
  d.disc_n = 2
  w:refresh(20, true, on("treasure"))
  check("discovery: changed count recomputes", w:input().treasure[1].discovered == true)
  check("discovery: settlements listed",
    w:input().settlements[1] and w:input().settlements[1].name == "Vernworth")
end

-- 16. places_load_rejects
do
  local atlas = { version = 1, entries = { a1 = { k = "chest", id = 10, x = 1, y = 2, z = 3 } } }
  local function case(setup)
    local f = fixture({ files = { [K.ATLAS] = atlas } })
    setup(f)
    local w = f.new()
    w:refresh(0, true, on("chests"))
    return w, find(w:input().chests, "a1") ~= nil
  end
  local w, ok = case(function() end)
  check("places: nil load is missing", w:places_state().state == "missing" and ok)
  w, ok = case(function(f) f.files[K.PLACES] = "junk" end)
  check("places: string is bad", w:places_state().state == "bad" and ok)
  w, ok = case(function(f) f.files[K.PLACES] = { version = 2,
    rows = { prow("chest", "v2", 10, 1, 1) } } end)
  check("places: version 2 is bad", w:places_state().state == "bad" and ok)
  check("places: version 2 rows are not used", w:stats().places.rows == 0)
  w, ok = case(function(f) f.load_raises[K.PLACES] = true end)
  check("places: raising load is bad", w:places_state().state == "bad" and ok)

  local f = fixture({ files = { [K.PLACES] = places({
    prow("x", "r1", 1, 1, 1), prow("chest", "r2", 1.5, 1, 1),
    prow("chest", "r3", 10, NAN, 1), prow("chest", "r4", 3.0, 7, 8) }) } })
  local w2 = f.new()
  check("places: bad rows dropped and counted", w2:stats().places.dropped == 3
    and w2:stats().places.rows == 1)
  w2:refresh(0, true, on("chests"))
  local c = find(w2:input().chests, "r4")
  check("places: 3.0 kept as integer", c ~= nil and math.type(c.gimmick) == "integer"
    and c.gimmick == 3)
  check("places: state ok", w2:places_state().state == "ok")
end

-- 17. places_seed_and_override
do
  local f = fixture({ files = {
    [K.PLACES] = places({ prow("chest", "p1", 10, 1, 1), prow("chest", "p2", 10, 2, 2) }),
    [K.ATLAS] = { version = 1, pak = "1:1",
      entries = { p1 = { k = "chest", id = 10, x = 9, y = 9, z = 9, table_ix = 3 } } } } })
  f.data.reserved = { chest_row("n1", 3, 2, 4), chest_row("n2", 4, 2, 4), chest_row("n3", 5, 2, 4) }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  local ch = w:input().chests
  local n = 0
  for _, e in ipairs(ch) do if e.uid == "p1" then n = n + 1 end end
  check("override: one p1 at the learned position",
    n == 1 and find(ch, "p1").pos.x == 9)
  check("override: file row absent from reserved rows stays", find(ch, "p2") ~= nil)
  local t = f.dumps[#f.dumps].t
  check("override: dump holds learned entries only",
    t.entries.p1 ~= nil and t.entries.n1 ~= nil and t.entries.p2 == nil)
  check("override: file rows counted", w:stats().atlas.file == 2)
end

-- 18. places_stamp_change
do
  local atlas = { version = 1, pak = "1:2", entries = {
    u1 = { k = "chest", id = 10, x = 1, y = 2, z = 3 },
    u2 = { k = "chest", id = 10, x = 4, y = 5, z = 6, table_ix = 2 } } }
  local function count(pak)
    local f = fixture({ files = { [K.PLACES] = places({}, pak), [K.ATLAS] = atlas } })
    return f.new():stats().atlas.learned
  end
  check("stamp: different stamp drops the entry without table_ix", count("1:3") == 1)
  check("stamp: same stamp keeps it", count("1:2") == 2)
end

-- 19. token_bit
do
  local f = fixture()
  f.data.reserved = {
    { uid = "t1", pos = P(1, 0, 1), gimmick = 167, table_ix = 1 },
    { uid = "t2", pos = P(2, 0, 2), gimmick = 167, table_ix = 1 },
    { uid = "t3", pos = P(3, 0, 3), gimmick = 167, table_ix = 1 } }
  f.data.records = { { key = "t1_0", free_bit = 65536 }, { key = "t2_0", free_bit = 16 } }
  f.data.iname = { [305] = "Seeker's Token" }
  local w = f.new()
  w:refresh(0, true, on("tokens"))
  local tk = w:input().tokens
  check("token: bit 16 set is collected", find(tk, "t1").state == "collected")
  check("token: 16 is not bit 16", find(tk, "t2").state == "not")
  check("token: no record is not", find(tk, "t3").state == "not")
  check("token: name from adapter", find(tk, "t1").name == "Seeker's Token")
  f.data.iname = {}
  w:reset()
  w:refresh(20, true, on("tokens"))
  check("token: fallback name while the read fails", find(w:input().tokens, "t1").name == "Item 305")
  f.data.iname = { [305] = "Seeker's Token" }
  w:refresh(40, true, on("tokens"))
  check("token: fallback not cached", find(w:input().tokens, "t1").name == "Seeker's Token")
end

-- 20. beetle_num
do
  local f = fixture()
  f.data.reserved = {
    { uid = "b1", pos = P(1, 0, 1), gimmick = 161, table_ix = 1 },
    { uid = "b2", pos = P(2, 0, 2), gimmick = 161, table_ix = 1 } }
  f.data.records = { { key = "b1_0", gather_num = 0 }, { key = "b2_0", gather_num = 1 } }
  local w = f.new()
  w:refresh(0, true, on("beetles"))
  local bt = w:input().beetles
  check("beetle: num 0 collected", find(bt, "b1").state == "collected")
  check("beetle: num 1 not", find(bt, "b2").state == "not")
end

-- 21. unlisted_count
do
  local f = fixture({ files = { [K.PLACES] = places({ prow("chest", "u1", 10, 1, 1) }) } })
  f.data.loaded = { { uid = "u1", gimmick = 10, pos = P(1, 0, 1) },
    { uid = "u2", gimmick = 10, pos = P(77, 0, 88) } }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  check("unlisted: count is 1", w:stats().unlisted == 1)
  local c = find(w:input().chests, "u2")
  check("unlisted: learned at its position", c ~= nil and c.pos.x == 77 and c.pos.z == 88)
  check("unlisted: default threshold is the interim 20", K.UNLISTED_STALE == 20)
  check("unlisted: not stale below the default threshold", w:places_state().stale == false)
  local keep = K.UNLISTED_STALE
  K.UNLISTED_STALE = 0
  check("unlisted: stale above the threshold", w:places_state().stale == true)
  K.UNLISTED_STALE = keep
end

-- 22. chara_sort
do
  local rows = {
    prow("chara", "r1", 1, 100, 0, { name = "ch253000_00" }),
    prow("chara", "r2", 2, 200, 0, { name = "ch256000_00" }),
    prow("chara", "r3", 3, 300, 0, { name = "ch220000_00" }),
    prow("chara", "r4", 4, 400, 0, { name = "ch299001_A_00" }),
    prow("chara", "r5", 5, 500, 0, { name = "ch253000_00", src = "subquest" }),
    prow("chara", "r6", 6, 600, 0, { name = "ch253000_00", phase = "season4" }),
    prow("chest", "r7", 10, 700, 0, { src = "subquest" }) }
  local f = fixture({ files = { [K.PLACES] = places(rows) } })
  f.data.boss = { ch253 = true }
  local w = f.new()
  w:refresh(0, true, ALL)
  local m = w:input().monsters
  local large, small = 0, 0
  for _, e in ipairs(m) do if e.small then small = small + 1 else large = large + 1 end end
  check("sort: two large, one small, rest dropped", large == 2 and small == 1 and #m == 3)
  check("sort: subquest chest dropped", #w:input().chests == 0)
  f.data.loaded_boss = { ch220 = true }
  w:refresh(10, true, ALL)
  large, small = 0, 0
  for _, e in ipairs(w:input().monsters) do if e.small then small = small + 1 else large = large + 1 end end
  check("sort: loaded boss family makes the small one large", large == 3 and small == 0)
  w:reset()
  f.data.loaded_boss = {}
  w:refresh(20, true, ALL)
  small = 0
  for _, e in ipairs(w:input().monsters) do if e.small then small = small + 1 end end
  check("sort: small again after reset", small == 1)

  local f2 = fixture({ files = { [K.PLACES] = places({
    prow("chara", "r1", 1, 100, 0, { name = "ch253000_00" }) }) } })
  f2.data.boss = { ch253 = true }
  local w2 = f2.new()
  w2:refresh(0, true, on("chests"))
  w2:refresh(10, true, on("chests", "monsters"))
  local m2 = w2:input().monsters
  check("sort: monsters turned on later, large without a reset", #m2 == 1 and m2[1].small == false)
end

-- 22b. live rows the places file drops are session-only (SPEC 17.10.6, 17.10.9.2)
do
  local function session_only(label, prows, reserved, kind, uid, x)
    local f = fixture({ files = { [K.PLACES] = places(prows) } })
    f.data.boss = { ch253 = true }
    local keep = chest_row("keep1", 1, 1)
    reserved[#reserved + 1] = keep
    f.data.reserved = reserved
    local w = f.new()
    w:refresh(0, true, ALL)
    local list = w:input()[kind]
    check(label .. ": draws while reserved", find(list, uid) ~= nil or (kind == "monsters" and #list == 1 and list[1].pos.x == x))
    f.data.reserved = { keep }
    w:refresh(20, true, ALL)
    local l1 = w:input()[kind]
    check(label .. ": gone once no longer reserved", find(l1, uid) == nil and (kind ~= "monsters" or #l1 == 0))
    f.data.reserved = reserved
    w:save("test")
    local atlas = f.files[K.ATLAS]
    check(label .. ": other learned rows still saved", atlas ~= nil and atlas.entries.keep1 ~= nil)
    check(label .. ": absent from the dump", atlas ~= nil and atlas.entries[uid] == nil)
    local f2 = fixture({ files = f.files })
    f2.data.boss = { ch253 = true }
    local w2 = f2.new()
    w2:refresh(0, true, ALL)
    local l2 = w2:input()[kind]
    check(label .. ": gone next session", find(l2, uid) == nil and (kind ~= "monsters" or #l2 == 0))
  end
  session_only("live subquest chara",
    { prow("chara", "sq1", 5, 500, 0, { name = "ch253000_00", src = "subquest" }),
      prow("chest", "other", 10, 9, 9) },
    { mrow("sq1", 5, "ch253000_00", 500, 0) }, "monsters", "sq1", 500)
  session_only("live not-in-file chara",
    { prow("chest", "other", 10, 9, 9) },
    { mrow("nf1", 6, "ch253000_00", 600, 0) }, "monsters", "nf1", 600)
  session_only("live subquest chest",
    { prow("chest", "sc1", 10, 700, 0, { src = "subquest" }) },
    { chest_row("sc1", 700, 0) }, "chests", "sc1", 700)

  -- a gimmick absent from the file is still learned (patch correction)
  local f = fixture({ files = { [K.PLACES] = places({ prow("chest", "other", 10, 9, 9) }) } })
  f.data.reserved = { chest_row("gnf", 800, 0) }
  local w = f.new()
  w:refresh(0, true, ALL)
  w:save("test")
  check("live not-in-file chest: saved", f.files[K.ATLAS] ~= nil and f.files[K.ATLAS].entries.gnf ~= nil)
  local f2 = fixture({ files = f.files })
  local w2 = f2.new()
  w2:refresh(0, true, ALL)
  check("live not-in-file chest: draws next session", find(w2:input().chests, "gnf") ~= nil)
end

-- 22c. load-time pruning of learned entries the file would drop
do
  local rows = {
    prow("chara", "mkeep", 1, 100, 0, { name = "ch253000_00" }),
    prow("chara", "msq", 5, 500, 0, { name = "ch253000_00", src = "subquest" }),
    prow("chara", "mph", 7, 1500, 0, { name = "ch253000_00", phase = "beforeseason4" }),
    prow("chest", "csq", 10, 700, 0, { src = "subquest" }) }
  local function atlas()
    local function e(k, id, x) return { k = k, id = id, x = x, y = 0, z = 0 } end
    return { version = K.FILE_VERSION, pak = "1:1", entries = {
      mkeep = e("monster", 1, 100), msq = e("monster", 5, 500),
      mnf = e("monster", 6, 600), mph = e("monster", 7, 1500), csq = e("chest", 10, 700),
      cnf = e("chest", 10, 800), g1 = e("giver", 77, 900) } }
  end
  local f = fixture({ files = { [K.PLACES] = places(rows), [K.ATLAS] = atlas() } })
  local w = f.new()
  local s = w:stats()
  check("prune: four removed", s.atlas.pruned == 4)
  check("prune: three kept", s.atlas.learned == 3)
  f.data.reserved = {}
  w:refresh(0, true, ALL)
  w:save("test")
  local ent = f.files[K.ATLAS].entries
  check("prune: pruned entries leave the file",
    ent.msq == nil and ent.mnf == nil and ent.mph == nil and ent.csq == nil)
  check("prune: kept entries stay", ent.mkeep ~= nil and ent.cnf ~= nil and ent.g1 ~= nil)

  for _, state in ipairs({ "missing", "bad" }) do
    local files = { [K.ATLAS] = atlas() }
    if state == "bad" then files[K.PLACES] = { version = 99, rows = {} } end
    local f2 = fixture({ files = files })
    local s2 = f2.new():stats()
    check("prune: nothing pruned when places is " .. state,
      s2.places.state == state and s2.atlas.pruned == 0 and s2.atlas.learned == 7)
  end
end

-- 23. chara_cluster
do
  local rows = {
    prow("chara", "a1", 1, 0, 0, { name = "ch253000_00" }),
    prow("chara", "a2", 2, 3, 0, { name = "ch253000_00" }),
    prow("chara", "a3", 3, 0, 4, { name = "ch253000_00" }),
    prow("chara", "a5", 5, 50, 0, { name = "ch253000_00" }) }
  local f = fixture({ files = { [K.PLACES] = places(rows) } })
  f.data.boss = { ch253 = true }
  local w = f.new()
  w:refresh(0, true, on("monsters"))
  local m = w:input().monsters
  check("cluster: two monsters", #m == 2)
  check("cluster: counts and names", m[1].count == 3 and m[1].name == "Griffin x3"
    and m[2].count == 1 and m[2].name == "Griffin")
  check("cluster: seed uid", m[1].uid == "a1")
  f.data.badge_default = ""
  w:reset()
  w:refresh(10, true, on("monsters"))
  check("cluster: blank badge gives Monster", w:input().monsters[2].name == "Monster")

  local rows2 = {
    prow("chara", "c1", 1, 0, 0, { name = "ch253000_00" }),
    prow("chara", "c2", 2, 6, 0, { name = "ch253000_00" }),
    prow("chara", "c3", 3, 3, 0, { name = "ch253000_00" }) }
  local f2 = fixture({ files = { [K.PLACES] = places(rows2) } })
  f2.data.boss = { ch253 = true }
  local w2 = f2.new()
  w2:refresh(0, true, on("monsters"))
  local m2 = w2:input().monsters
  check("cluster: a row joins the first matching cluster",
    #m2 == 2 and m2[1].uid == "c1" and m2[1].count == 2 and m2[2].uid == "c2"
    and m2[2].count == 1)
end

-- 24. places_slow
do
  local f = fixture()
  f.load_cost = 0.06
  check("slow: 60 ms is slow", f.new():stats().places.slow == true)
  local f2 = fixture()
  f2.load_cost = 0.01
  check("slow: 10 ms is not", f2.new():stats().places.slow == false)
end

-- 25. input_identity
do
  local f = fixture()
  f.data.reserved = { chest_row("c1", 10, 10) }
  local w = f.new()
  check("identity: nil before a round", w:input() == nil)
  w:refresh(0, true, ALL)
  check("identity: same table without a round", rawequal(w:input(), w:input()))
  local first = w:input()
  w:refresh(10, true, ALL)
  check("identity: new table after a committed round", not rawequal(first, w:input()))
end

-- ===== review round 1: world-side findings =====

-- 13. cast ids are normalised to unsigned
do
  local f = fixture()
  f.data.catalog = { 1 }
  f.data.cast = { [1] = { -1 } }
  f.data.reserved = { mrow("sg", 4294967295, "ch253001_00", 40, 50) }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  check("cast unsigned: signed cast id matches the unsigned row", w:givers()[4294967295] ~= nil)
end

-- 17. a monster entry with no name draws nothing
do
  local f = fixture({ files = { [K.ATLAS] = { version = 1, entries = {
    nm = { k = "monster", id = 9, x = 1, y = 2, z = 3 } } } } })
  local w = f.new()
  w:refresh(0, true, on("monsters"))
  check("nameless monster entry is dropped", #w:input().monsters == 0)
end

-- 18. K.ROUND_TO is read
do
  local f = fixture()
  f.data.reserved = { chest_row("rt", 10.4, 10.4) }
  local w = f.new()
  K.ROUND_TO = 1
  w:refresh(0, true, on("chests"))
  K.ROUND_TO = 0.1
  check("round: K.ROUND_TO used", w:input().chests[1].pos.x == 10)
end

-- 19. index hits and misses count per round
do
  local f = fixture()
  f.data.loaded = { { uid = "g1", gimmick = 10, pos = P(5, 0, 5) } }
  f.data.records = { { key = "g1_0", picked = false } }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  w:refresh(10, true, on("chests"))
  local ix = w:stats().index
  check("index: counts the latest round only", ix.hits == 1 and ix.misses == 0)
end

-- ===== game_reads against a fake object model =====
do
  local function obj(fields, methods, tname)
    local o = {}
    function o:get_field(n) return fields and fields[n] end
    function o:call(n, ...)
      local m = methods and methods[n]
      if m then return m(...) end
      return nil
    end
    function o:get_type_definition()
      return { get_name = function() return tname end }
    end
    return o
  end
  local function guid(text)
    return obj(nil, { ["ToString()"] = function() return text end })
  end
  local function list(items)
    return obj(nil, { get_Count = function() return #items end,
      get_Item = function(i) return items[i + 1] end })
  end
  local function array(items)
    local o = obj()
    function o:get_elements() return items end
    return o
  end
  local function hset(vals, with_count)
    local es = {}
    for i, v in ipairs(vals) do es[i] = obj({ HashCode = i, Next = -1, Value = v }) end
    return obj({ _entries = array(es), _count = #es },
      { get_Count = function() return #vals end })
  end
  local function ctx(tname, fields) return obj(fields, nil, tname) end
  local function enum_field(name, v)
    return { is_static = function() return true end, get_name = function() return name end,
      get_data = function() return v end }
  end

  local singletons, fetches = {}, {}
  local walks = 0
  local saved_sdk = sdk
  sdk = {
    get_managed_singleton = function(n)
      fetches[n] = (fetches[n] or 0) + 1
      return singletons[n]
    end,
    find_type_definition = function(n)
      if n == "app.CharacterID" then
        return { get_fields = function()
          return { enum_field("value__", 0), enum_field("ch253000_00", 1001),
            enum_field("ch220000_00", 5) } end }
      elseif n == "app.AIKeyLocation" then
        return { get_fields = function()
          return { enum_field("Gimmick_Treasure_007", 7) } end }
      end
      return nil
    end,
  }
  local R = world.game_reads()

  -- reserved rows: List<GenerateSelector> -> <Table> -> set infos
  local function row_obj(f) return obj(f) end
  local sel = obj({ ["<Table>k__BackingField"] = obj({
    _GimmickSetInfo = obj({ _BasicRowDatas = array({ row_obj({
      _ManualSetGuid = guid("AA-1"), _ManualPos = P(1, 2, 3), _GimmickID = 10 }) }) }),
    _EnemySetInfo = obj({ _BasicRowDatas = array({ row_obj({
      _ManualSetGuid = guid("BB-2"), _ManualPos = P(4, 5, 6), _CharaID = 1001 }) }) }) }) })
  singletons["app.GenerateManager"] = obj({ _ReserveManager =
    obj({ _ReservedGenerateSelector = list({ sel }) }) })
  local ok, rows = pcall(R.reserved_rows)
  check("reads: reserved rows via the selector table", ok and #rows == 2
    and rows[1].uid == "aa-1" and rows[1].gimmick == 10 and rows[1].table_ix == 1
    and rows[2].cid == 1001 and rows[2].cid_name == "ch253000_00")
  singletons["app.GenerateManager"] = obj({ _ReserveManager =
    obj({ _ReservedGenerateSelector = list({}) }) })
  check("reads: no reserved rows is a failed read", not pcall(R.reserved_rows))

  -- save records: contexts one hop down, in Record or SaveData
  local function rec(ctxs, via)
    local l = list(ctxs)
    local r
    if via == "SaveData" then
      r = obj({ SaveData = obj({ Contexts = l }) })
    else
      r = obj(nil, { get_Record = function()
        walks = walks + 1
        return obj({ Contexts = l })
      end })
    end
    return r
  end
  local recs = {
    rec({ ctx("UniqueIDContext", { UniqueID = guid("C1_0") }),
      ctx("GmItemContext", { _IsPick = true }),
      ctx("TreasureBoxGimmickContext", { _ItemId = 305 }) }),
    rec({ ctx("UniqueIDContext", { UniqueID = guid("T1_0") }),
      ctx("GimmickContext", { _GimmickId = 167, _FreeBit = 65536 }) }, "SaveData"),
    rec({ ctx("UniqueIDContext", { UniqueID = guid("B1_0") }),
      ctx("GimmickContext", { _GimmickId = 161 }),
      ctx("GatherContext", { _Num = 0 }) }),
    rec({ ctx("UniqueIDContext", { UniqueID = guid("N1_0") }),
      ctx("GimmickContext", { _GimmickId = 5, _FreeBit = 1 }) }),
    rec({ ctx("UniqueIDContext", { UniqueID = guid("M1_0") }),
      ctx("CharacterIDContext", { CharacterID = 1001 }),
      ctx("CharacterPosRotContext", { Position = P(9, 0, 9) }) }),
    rec({ ctx("UniqueIDContext", { UniqueID = guid("M2_0") }),
      ctx("CharacterIDContext", {}),
      ctx("CharacterPosRotContext", { Position = P(8, 0, 8) }) }),
  }
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = list(recs) }) })
  local ok2, sr = pcall(R.save_records)
  local by = {}
  for _, r in ipairs(ok2 and sr or {}) do by[r.key] = r end
  check("reads: save records join chest, token and beetle",
    ok2 and #sr == 3 and by.c1_0 and by.c1_0.picked == true and by.c1_0.item == 305
    and by.t1_0 and by.t1_0.free_bit == 65536 and by.b1_0 and by.b1_0.gather_num == 0)

  singletons["app.GenerateManager"] = obj({ _RepopManager = obj({ _Units = array({
    obj({ _RegisteredTimeInfos = list({ obj({ _UniqID = guid("M1_0") }),
      obj({ _UniqID = guid("M2_0") }) }) }) }) }) })
  local ok3, ru = pcall(R.respawn_units)
  check("reads: respawn units join a record by UniqID",
    ok3 and #ru == 1 and ru[1].cid == 1001 and ru[1].cid_name == "ch253000_00"
    and ru[1].pos.x == 9 and ru[1].key == "m1_0")
  local before = walks
  pcall(R.save_records)
  pcall(R.respawn_units)
  check("reads: one record walk while the count is unchanged", walks == before)

  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = list({
    obj(nil, { get_Record = function() return obj({ Contexts = list({}) }) end }) }) }) })
  check("reads: records with no match are a failed read", not pcall(R.save_records))

  -- checked nodes: HashSet entry field Value
  singletons["app.GimmickManager"] = obj({
    ["<KeyLocationCheckedList>k__BackingField"] = hset({ 7 }) })
  local ok4, cn = pcall(R.checked_nodes)
  check("reads: checked node read from Value", ok4 and cn.Gimmick_Treasure_007 == true)
  singletons["app.GimmickManager"] = obj({})
  check("reads: missing checked list is a failed read", not pcall(R.checked_nodes))

  -- discovered icons are ids
  singletons["app.GuiManager"] = obj({ MapIconDispIdList = hset({ 77 }),
    MapIconList = list({ obj({ _DispNameId = guid("G1"), _Pos = P(1, 2, 3),
      _IconType = 68, _IconId = 77 }) }) })
  local ok5, di = pcall(R.discovered_icons)
  check("reads: discovered icons keyed by icon id", ok5 and di[77] == true)
  check("reads: discovered count", R.discovered_count() == 1)
  local mi = R.map_icons()
  check("reads: map icons carry the icon id", mi[1].icon_id == 77 and mi[1].type == 68)

  -- shops: variable condition object
  local function buy(vc)
    return obj({ _ItemId = 378, _ReleaseQuestId = 0, _ReleaseSentimentRankBit = 0,
      _ReleaseTotalPay = 0, _ReleaseFlag = 0, _QuestVariableCondition = vc })
  end
  singletons["app.ItemManager"] = obj({ ShopParamTable = obj({ _entries = array({
    obj({ key = 41, value = obj({ _BuyParams = array({
      buy(obj({ _QuestID = 0, _NameHash = 5 })), buy(nil),
      buy(obj({ _QuestID = -1, _NameHash = 0 })),
      buy(obj({ _QuestID = 40060, _NameHash = 0 })) }) }) }) }) }) })
  local ok6, sh = pcall(R.shops)
  check("reads: variable condition sets var_cond",
    ok6 and sh[41][1].var_cond == 1 and sh[41][2].var_cond == 0)
  check("reads: game default condition (quest -1, hash 0) is none",
    ok6 and sh[41][3].var_cond == 0 and sh[41][4].var_cond == 1)

  -- schedule dictionary is fetched once for repeated reads
  singletons["app.NPCManager"] = obj({ ["<NPCScheduleCurrentDict>k__BackingField"] =
    obj(nil, { get_Item = function() return obj({ Pos = P(1, 2, 3) }) end }) })
  fetches["app.NPCManager"] = 0
  R.schedule_pos(1); R.schedule_pos(2); R.schedule_pos(3)
  check("reads: schedule dictionary fetched once", fetches["app.NPCManager"] == 1)

  -- a reload with the same count but a new list object must not reuse records
  local function addr_list(items, addr)
    local l = list(items)
    function l:get_address() return addr end
    return l
  end
  local r1 = { rec({ ctx("UniqueIDContext", { UniqueID = guid("C1_0") }),
    ctx("GmItemContext", { _IsPick = true }) }) }
  local r2 = { rec({ ctx("UniqueIDContext", { UniqueID = guid("C1_0") }),
    ctx("GmItemContext", { _IsPick = false }) }) }
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = addr_list(r1, 100) }) })
  local s1 = R.save_records()
  check("reload: first read", s1[1] and s1[1].picked == true)
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = addr_list(r2, 200) }) })
  local s2 = R.save_records()
  check("reload: same count, new list object, records re-read", s2[1] and s2[1].picked == false)
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = addr_list(r1, 200) }) })
  check("reload: same address and count keeps the cache", R.save_records()[1].picked == false)
  R.reset()
  check("reload: reset clears the cache", R.save_records()[1].picked == true)

  -- w:reset() calls reads.reset
  local fr = fixture()
  local resets = 0
  fr.reads.reset = function() resets = resets + 1 end
  local wr = fr.new()
  wr:reset()
  check("reset: world reset calls reads.reset", resets == 1)

  -- the _count cut: a stale slot past _count is ignored
  local es = { obj({ Value = 1 }), obj({ Value = 2 }), obj({ Value = 99 }) }
  singletons["app.GuiManager"] = obj({ MapIconDispIdList =
    obj({ _entries = array(es), _count = 2 }, { get_Count = function() return 2 end }) })
  local ok7, di7 = pcall(R.discovered_icons)
  check("reads: entries past _count are ignored", ok7 and di7[1] and di7[2] and not di7[99])

  -- monster drops: the two enemy drop dictionaries (SPEC 19.12.2)
  do
    local function item(id, rate) return obj({ _Id = id, _Rate = rate }) end
    local function dentry(key, cid, items)
      return obj({ key = key, value = obj({ _CharaId = cid, _TableList = array({
        obj({ _ItemList = array(items) }) }) }) })
    end
    local function dict(es) return obj({ _entries = array(es), _count = #es }) end
    local function setdrops(def_es, par_es)
      singletons["app.ItemManager"] = obj({ EnemyDefaultItemDropDataDict = dict(def_es),
        EnemyItemDropDataDict = dict(par_es) })
    end
    local function same(a, b)
      if a == nil or #a ~= #b then return false end
      for i = 1, #b do if a[i] ~= b[i] then return false end end
      return true
    end
    setdrops({ dentry(5, 5, { item(230, 3), item(231, 3), item(230, 3), item(0, 5),
      item(232, 0) }), dentry(6, 6, { item(300, 0) }) }, {})
    local okd, dr = pcall(R.monster_drops)
    check("reads: drops distinct ids in first-seen order", okd and same(dr[5], { 230, 231 }))
    check("reads: rate 0 and id 0 skipped, empty cid absent", okd and dr[6] == nil
      and dr[5] ~= nil and #dr[5] == 2)
    setdrops({ dentry(6, 6, { item(300, 3) }), dentry(5, 5, { item(230, 3), item(231, 3) }) },
      { dentry(50, 5, { item(240, 3) }), dentry(51, 6, { item(301, 3) }) })
    local okp, dp = pcall(R.monster_drops)
    check("reads: param ignored for a cid whose default entry comes later",
      okp and same(dp[5], { 230, 231 }) and same(dp[6], { 300 }))
    setdrops({ dentry(5, 5, { item(230, 3) }) },
      { dentry(60, 9, { item(241, 3) }), dentry(61, 0, { item(242, 3) }) })
    local okq, dq = pcall(R.monster_drops)
    check("reads: param counts for a cid with no default entry",
      okq and same(dq[9], { 241 }) and dq[61] == nil and same(dq[5], { 230 }))
    local nkeys = 0
    for _ in pairs(dq or {}) do nkeys = nkeys + 1 end
    check("reads: a param entry with no cid adds no key", nkeys == 2)
    setdrops({ dentry(7, 0, { item(250, 3) }) }, {})
    local okk, dk = pcall(R.monster_drops)
    check("reads: default entry without CharaId uses the key", okk and same(dk[7], { 250 }))
    setdrops({ dentry(1, -1233720880, { item(230, 3) }) }, {})
    local okn, dn = pcall(R.monster_drops)
    check("reads: negative cid normalised", okn and same(dn[3061246416], { 230 })
      and dn[-1233720880] == nil)
    setdrops({}, {})
    check("reads: empty walk raises", not pcall(R.monster_drops))
  end

  -- v14 reads: schedule rows, current row, area nodes, holders, sentiment
  do
    local R = world.game_reads()
    local function rowobj(sw, ew, sd, ed, sh, eh, loc, area, pri)
      return obj({ StartWeek = sw, EndWeek = ew, StartDay = sd, EndDay = ed,
        StartHour = sh, EndHour = eh, Location = loc, LocalArea = area, Priority = pri })
    end
    local function dict(map)
      return obj(nil, { ContainsKey = function(k) return map[k] ~= nil end,
        get_Item = function(k) return map[k] end })
    end
    local curs = { [7] = obj({ LocalArea = 49, Location = 3, Pos = P(1, 2, 3) }),
      [8] = obj({ LocalArea = -1, Location = -1, Pos = P(0, 0, 0) }) }
    local rowsd = { [7] = list({ rowobj(1, 4, 0, 6, 6, 18, 3, 49, 0),
      rowobj(1, 4, 0, 6, 18, 6, 3, -1, 1) }) }
    local nodes_by_area = { [49] = list({ obj(nil, { get_Pos = function() return P(1, 0, 1) end }),
      obj(nil, { get_Pos = function() return P(2, 0, 2) end }) }) }
    local listed = {}
    singletons["app.NPCManager"] = obj({
      ["<NPCScheduleCurrentDict>k__BackingField"] = dict(curs),
      ["<NPCScheduleDict>k__BackingField"] = dict(rowsd),
      NPCHolderDic = obj(nil, { get_Length = function() return 3 end,
        get_element = function(i)
          if i == 0 then
            return obj({ _chara = obj(nil, { get_Transform = function() return "tf" end }),
              CharaID = 1001,
              SentimentToPlayer = obj({ Rank = 100, Value = 137 }) })
          elseif i == 1 then
            return obj({ CharaID = 5 })
          end
          return nil
        end }) }, { get_CurrentScheduleDay = function() return 33 end,
        get_CurrentScheduleHour = function() return 7 end })
    singletons["app.AIAreaManager"] = obj(nil, {
      getKeyNodesInLocalArea = function(area) listed.area = area; return nodes_by_area[area] end,
      getNodeListInArea = function(loc, a2, flag)
        listed.loc, listed.a2, listed.flag = loc, a2, flag
        return list({ obj(nil, { get_Pos = function() return P(9, 0, 9) end }) })
      end })

    local okr, rr = pcall(R.schedule_rows, 7)
    check("reads: schedule rows shape", okr and #rr == 2 and rr[1].area == 49
      and rr[1].start_hour == 6 and rr[1].end_hour == 18 and rr[1].location == 3
      and rr[1].priority == 0 and rr[1].start_week == 1 and rr[1].end_day == 6
      and rr[2].area == -1 and rr[2].priority == 1)
    check("reads: schedule rows of an unknown cid fail", not pcall(R.schedule_rows, 99))
    local okn, day, hour = pcall(R.schedule_now)
    check("reads: schedule now", okn and day == 33 and hour == 7)
    local cr = R.current_row(7)
    check("reads: current row", cr and cr.area == 49 and cr.location == 3 and cr.pos.x == 1)
    local c8 = R.current_row(8)
    check("reads: current row -1/-1", c8 and c8.area == -1 and c8.location == -1)
    check("reads: current row of an unknown cid is nil", R.current_row(99) == nil)
    local an = R.area_nodes({ area = 49, location = 3 })
    check("reads: area nodes by local area (integer)", an and #an == 2 and listed.area == 49)
    local ab = R.area_nodes({ area = -1, location = 6 })
    check("reads: area nodes by location", ab and #ab == 1 and listed.loc == 6
      and listed.a2 == -1 and listed.flag == true)
    check("reads: an area with no nodes is nil", R.area_nodes({ area = 50, location = 3 }) == nil)
    check("reads: holder count", R.holder_count() == 3)
    local h0 = R.holder_at(0)
    check("reads: spawned holder", h0 and h0.cid == 1001 and h0.transform == "tf"
      and h0.holder ~= nil)
    check("reads: unspawned holder is nil", R.holder_at(1) == nil)
    check("reads: empty slot is nil", R.holder_at(2) == nil)
    local rk, vl = R.sentiment(h0.holder)
    check("reads: sentiment rank and value", rk == 100 and vl == 137)
    check("reads: unreadable sentiment raises", not pcall(R.sentiment, obj({})))
  end
  sdk = saved_sdk
end

-- ===== world.cluster equals the linear scan on a randomized fixture =====
do
  local function linear(items, uids, radius)
    local clusters = {}
    for _, uid in ipairs(uids) do
      local it = items[uid]
      local home = nil
      for _, c in ipairs(clusters) do
        local s = c.seed.pos
        local dx, dy, dz = it.pos.x - s.x, it.pos.y - s.y, it.pos.z - s.z
        if math.sqrt(dx * dx + dy * dy + dz * dz) <= radius then home = c; break end
      end
      if home == nil then
        clusters[#clusters + 1] = { seed = it, count = 1, respawning = it.respawning }
      else
        home.count = home.count + 1
        if it.respawning then home.respawning = true end
      end
    end
    return clusters
  end
  math.randomseed(20261021)
  local same = true
  for trial = 1, 40 do
    local n = math.random(1, 300)
    local span = ({ 12, 40, 400 })[trial % 3 + 1]
    local items, uids = {}, {}
    for i = 1, n do
      local uid = string.format("u%04d", i)
      items[uid] = { uid = uid, respawning = math.random() < 0.2,
        pos = { x = (math.random() - 0.5) * span, y = (math.random() - 0.5) * span / 4,
          z = (math.random() - 0.5) * span } }
      uids[i] = uid
    end
    for _, radius in ipairs({ 5, 3, 11 }) do
      local a = linear(items, uids, radius)
      local b = world.cluster(items, uids, radius)
      if #a ~= #b then same = false
      else
        for i = 1, #a do
          if a[i].seed ~= b[i].seed or a[i].count ~= b[i].count
            or (a[i].respawning == true) ~= (b[i].respawning == true) then
            same = false
          end
        end
      end
    end
  end
  check("cluster: grid output equals the linear scan", same)
end

-- 12. search shop index (SPEC 19.7, 19.9)
do
  local function shop_world(mod)
    local f = fixture()
    local d = f.data
    d.iname = { [378] = "Grimoire", [379] = "Tonic" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.shops = { [41] = {
      { item = 378, release_qid = 0, sentiment_bit = 0, total_pay = 0, flag = 0, var_cond = 0 },
      { item = 379, release_qid = -1, sentiment_bit = 0, total_pay = 0, flag = 0, var_cond = 0 } } }
    if mod then mod(f) end
    local w = f.new()
    w:refresh(0, true, { search = true })
    return w, f
  end
  local w, f = shop_world()
  local sh = w:input() and w:input().shops
  check("shops: published with every category off", sh ~= nil and #sh == 1)
  local e = sh and sh[1]
  check("shops: entry fields", e and e.shop == 41 and e.cid == 2058 and e.npc == "Dudley"
    and e.pos.x == 100 and e.pos.z == 100 and e.discovered == true and #e.items == 2)
  check("shops: item names and release -1 counts", e and e.items[1].name == "Grimoire"
    and e.items[1].locked == false and e.items[2].name == "Tonic")
  w = shop_world(function(g)
    g.data.shops[41][1].release_qid = 555
    g.data.qstate[555] = "in_progress"
  end)
  check("shops: incomplete release quest drops the row",
    #w:input().shops[1].items == 1 and w:input().shops[1].items[1].name == "Tonic")
  w = shop_world(function(g) g.data.shops[41][1].flag = 5 end)
  check("shops: non-zero flag sets locked", w:input().shops[1].items[1].locked == true
    and w:input().shops[1].items[2].locked == false)
  w = shop_world(function(g) g.data.sched[2058] = P(0.3, 0.2, 0.1) end)
  check("shops: unset schedule position gives no entry", #w:input().shops == 0)
  w = shop_world(function(g) g.data.alive = false end)
  check("shops: npc not alive uses schedule position", #w:input().shops == 1)
  w = shop_world(function(g) g.data.alive = false; g.data.sched = {} end)
  check("shops: not alive and no schedule position gives no entry", #w:input().shops == 0)

  -- search off: no shops, no read
  local f2 = fixture()
  f2.data.chests = nil
  f2.data.reserved = { chest_row("c1", 10, 10) }
  f2.data.shops = { [41] = { { item = 378, release_qid = 0 } } }
  local w2 = f2.new()
  w2:refresh(0, true, { chests = true, search = false })
  check("shops: search false publishes none", w2:input().shops == nil)
  check("shops: search false makes no shops read", (f2.reads_n.shops or 0) == 0)

  -- poke
  local f3 = fixture()
  local w3 = f3.new()
  w3:refresh(0, true, { search = true })
  local r1 = w3:stats().rounds
  w3:refresh(3, true, { search = true })
  check("poke: round throttled before poke", w3:stats().rounds == r1)
  w3:poke()
  w3:refresh(4, true, { search = true })
  check("poke: next refresh runs a round", w3:stats().rounds == r1 + 1)

  -- discovery refreshed with search on, treasure and sellers off
  local f4 = fixture()
  local w4 = f4.new()
  w4:refresh(0, true, { search = true })
  check("shops: discovery refreshed under search", (f4.reads_n.discovered_count or 0) >= 1)

  -- search_first_ms
  local f5 = fixture()
  f5.data.sched_ids = { 2058 }
  f5.data.shop = { [2058] = 41 }
  f5.data.sched = { [2058] = P(100, 0, 100) }
  f5.data.shops = { [41] = { { item = 378, release_qid = 0 } } }
  local w5 = f5.new()
  check("first: nil before any search round", w5:stats().search_first_ms == nil)
  w5:refresh(0, true, ALL)
  check("first: nil after a round without search", w5:stats().search_first_ms == nil)
  f5.reads.shops = (function(orig) return function(...)
    f5.clock_t = f5.clock_t + 0.5
    return orig(...)
  end end)(f5.reads.shops)
  w5:refresh(10, true, { search = true })
  local ms1 = w5:stats().search_first_ms
  check("first: number after the first search round", type(ms1) == "number" and ms1 > 0)
  f5.clock_t = f5.clock_t + 5
  w5:refresh(20, true, { search = true })
  check("first: unchanged by later rounds", w5:stats().search_first_ms == ms1)
  w5:reset()
  check("first: reset re-arms", w5:stats().search_first_ms == nil)
  w5:refresh(30, true, { search = true })
  check("first: timed again after reset", type(w5:stats().search_first_ms) == "number")

  -- distinct items, lock rule, missing name
  w = shop_world(function(g)
    g.data.iname = {}
    g.data.shops[41] = {
      { item = 378, release_qid = 0, sentiment_bit = 0, total_pay = 0, flag = 5, var_cond = 0 },
      { item = 378, release_qid = 0, sentiment_bit = 0, total_pay = 0, flag = 0, var_cond = 0 },
      { item = 379, release_qid = 0, sentiment_bit = 0, total_pay = 0, flag = 5, var_cond = 0 },
      { item = 379, release_qid = 0, sentiment_bit = 0, total_pay = 0, flag = 5, var_cond = 0 } }
  end)
  local it = w:input().shops[1].items
  check("shops: one entry per distinct item", #it == 2)
  check("shops: locked only when every counting row is locked",
    it[1].locked == false and it[2].locked == true)
  check("shops: missing name reads Item id", it[1].name == "Item 378" and it[2].name == "Item 379")

  -- sentiment bit 1 is the game's unlocked default; higher bits lock
  w = shop_world(function(g)
    g.data.shops[41] = {
      { item = 378, release_qid = 0, sentiment_bit = 1, total_pay = 0, flag = 0, var_cond = 0 },
      { item = 379, release_qid = 0, sentiment_bit = 16, total_pay = 0, flag = 0, var_cond = 0 } }
  end)
  it = w:input().shops[1].items
  check("shops: sentiment bit 1 is unlocked, 16 is locked",
    it[1].locked == false and it[2].locked == true)

  -- undiscovered shop reads discovered = false (SPEC 19.7.6)
  w = shop_world(function(g)
    g.data.icons = { { type = 68, pos = P(105, 0, 105), disp_id = "s1", icon_id = 77 } }
    g.data.msgs = { s1 = "Vernworth" }
    g.data.disc_n = 1
    g.data.icons_found = {}
  end)
  check("shops: undiscovered shop reads discovered false",
    w:input().shops[1] ~= nil and w:input().shops[1].discovered == false)

  -- sellers and search in one first round: the shared read is charged to search
  local f6 = fixture()
  local d6 = f6.data
  d6.needs = { [100] = { { id = 378, num = 1 } } }
  d6.sched_ids = { 2058 }; d6.shop = { [2058] = 41 }; d6.sched = { [2058] = P(100, 0, 100) }
  d6.shops = { [41] = { { item = 378, release_qid = 0 } } }
  local orig6 = f6.reads.shops
  f6.reads.shops = function(...)
    f6.clock_t = f6.clock_t + 0.5
    return orig6(...)
  end
  local w6 = f6.new()
  w6:refresh(0, true, { sellers = true, search = true })
  check("first: includes a read shared with sellers",
    #w6:input().sellers == 1 and w6:stats().search_first_ms >= 500)

  -- a failed first shop read does not lock the timing
  local f7 = fixture()
  f7.data.sched_ids = { 2058 }; f7.data.shop = { [2058] = 41 }
  f7.data.sched = { [2058] = P(100, 0, 100) }
  f7.data.shops = { [41] = { { item = 378, release_qid = 0 } } }
  f7.fail.shops = true
  local w7 = f7.new()
  w7:refresh(0, true, { search = true })
  check("first: failed read leaves it unset", w7:stats().search_first_ms == nil)
  f7.fail.shops = false
  local orig7 = f7.reads.shops
  f7.reads.shops = function(...)
    f7.clock_t = f7.clock_t + 0.5
    return orig7(...)
  end
  w7:refresh(10, true, { search = true })
  check("first: recovered round is timed", w7:stats().search_first_ms >= 500)
end

-- 13. monster drops in the world round (SPEC 19.12)
do
  local MS = on("monsters", "search")
  local function drops_world(mod)
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chara", "m5", 5, 0, 0, { name = "ch253000_00" }),
      prow("chara", "m9", 9, 100, 0, { name = "ch253000_01" }) }) } })
    f.data.boss = { ch253 = true }
    f.data.iname = { [230] = "Minotaur Horn", [231] = "Beast-Steak", [241] = "Ferrystone" }
    if mod then mod(f) end
    return f.new(), f
  end

  -- none without search or without monsters
  do
    local w, f = drops_world()
    w:refresh(0, true, { monsters = true })
    check("drops: none without search", w:input().drops == nil and f.data.drops_calls == nil)
    local w2, f2 = drops_world()
    w2:refresh(0, true, { search = true })
    check("drops: none without monsters", w2:input().drops == nil and f2.data.drops_calls == nil)
  end

  -- deferred from the first shop-index round
  do
    local w, f = drops_world()
    w:refresh(0, true, MS)
    check("drops: first search round has no drops and no read",
      w:input().drops == nil and f.data.drops_calls == nil)
    check("drops: the next refresh runs a round at once", w:refresh(0, true, MS) == true)
    local dr = w:input().drops
    check("drops: published on the second round",
      dr ~= nil and dr[5] ~= nil and dr[5][1] == "Minotaur Horn" and f.data.drops_calls == 1)

    local w2 = drops_world()
    w2:refresh(0, true, { search = true })
    check("drops: a search round without monsters keeps the throttle",
      w2:refresh(3, true, { search = true }) == false)

    local w3, f3 = drops_world()
    w3:refresh(0, true, on("sellers", "monsters"))
    check("drops: a sellers round does not start the search timing",
      w3:stats().search_first_ms == nil)
    w3:refresh(10, true, MS)
    check("drops: deferred when the shop index first succeeds",
      w3:input().drops == nil and f3.data.drops_calls == nil
      and w3:stats().search_first_ms ~= nil)
    check("drops: a refresh at the same time reads them", w3:refresh(10, true, MS) == true
      and w3:input().drops ~= nil and f3.data.drops_calls == 1)
    check("drops: then the throttle is back", w3:refresh(13, true, MS) == false)

    local w4 = drops_world(function(g)
      g.data.respawn = setmetatable({}, { __index = function() error("boom") end })
    end)
    check("drops: a raising round returns false", w4:refresh(0, true, MS) == false)
    check("drops: the raising round was after the shop index",
      w4:stats().search_first_ms ~= nil)
    check("drops: a raising round keeps the throttle", w4:refresh(3, true, MS) == false)

    -- ids already cached: the first shop success does not defer (no flicker)
    local w5, f5 = drops_world(function(g) g.fail.shops = true end)
    w5:refresh(0, true, MS)
    check("drops: read lands while the shop index fails",
      w5:input().drops ~= nil and f5.data.drops_calls == 1
      and w5:stats().search_first_ms == nil)
    f5.fail.shops = false
    w5:refresh(10, true, MS)
    check("drops: first shop success keeps cached drops",
      w5:input().drops ~= nil and f5.data.drops_calls == 1
      and w5:stats().search_first_ms ~= nil)

    -- no monster entries: no drop read
    local w6, f6 = drops_world(function(g) g.fail.boss_families = true end)
    w6:refresh(0, true, MS)
    w6:refresh(0, true, MS)
    check("drops: no read while the round has no monsters",
      #w6:input().monsters == 0 and f6.data.drops_calls == nil)
  end

  -- names, fallback and duplicates
  do
    local w, f = drops_world(function(g)
      g.data.iname = { [230] = "Minotaur Horn", [231] = "Item 231", [241] = "minotaur horn" }
      g.data.drops = { [5] = { 230, 231 }, [9] = { 241, 230 } }
    end)
    w:refresh(0, true, MS)
    w:refresh(0, true, MS)
    local dr = w:input().drops
    check("drops: fallback name left out", dr ~= nil and #dr[5] == 1 and dr[5][1] == "Minotaur Horn")
    check("drops: duplicate name left out of a list", dr ~= nil and #dr[9] == 1
      and dr[9][1] == "minotaur horn")
    f.data.iname[231] = "Beast-Steak"
    w:poke()
    w:refresh(1, true, MS)
    local dr2 = w:input().drops
    check("drops: names resolved every round",
      dr2 ~= nil and #dr2[5] == 2 and dr2[5][2] == "Beast-Steak")

    local w2 = drops_world(function(g) g.fail.monster_drops = true end)
    local ok1 = w2:refresh(0, true, MS)
    local ok2 = w2:refresh(0, true, MS)
    check("drops: a failed read gives no drops and no error",
      ok1 == true and ok2 == true and w2:input().drops == nil and w2:input().monsters ~= nil)

    local w3 = drops_world(function(g) g.data.drops = { [77] = { 230 } } end)
    w3:refresh(0, true, MS)
    w3:refresh(0, true, MS)
    check("drops: name build is timed", type(w:stats().ms.drop_names) == "number")
    check("drops: only the cids of this round's monsters",
      w3:input().drops == nil or w3:input().drops[77] == nil)
  end

  -- cluster cids
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chara", "a1", 1001, 0, 0, { name = "ch253000_00" }),
      prow("chara", "a2", 1002, 1, 0, { name = "ch253000_01" }),
      prow("chara", "a3", 1003, 100, 0, { name = "ch253000_02" }) }) } })
    f.data.boss = { ch253 = true }
    local w = f.new()
    w:refresh(0, true, MS)
    local m = w:input().monsters
    check("cluster: cids of a two-cid cluster, seed first",
      #m == 2 and m[1].cids ~= nil and #m[1].cids == 2 and m[1].cids[1] == 1001
      and m[1].cids[2] == 1002)
    check("cluster: a lone monster has its own cid", m[2] ~= nil and m[2].cids ~= nil
      and #m[2].cids == 1 and m[2].cids[1] == 1003)
  end

  -- stats
  do
    local w, f = drops_world()
    check("drops stats: nil before", w:stats().drops_first_ms == nil and w:stats().drops == nil)
    w:refresh(0, true, MS)
    w:refresh(0, true, MS)
    local s = w:stats()
    check("drops stats: set after the drop round", type(s.drops_first_ms) == "number"
      and s.drops ~= nil and s.drops.cids == 2 and s.drops.ids == 3)
    local first = s.drops_first_ms
    f.clock_t = f.clock_t + 1
    w:refresh(10, true, MS)
    check("drops stats: unchanged by a later round", w:stats().drops_first_ms == first
      and w:stats().drops.cids == 2)
    s.drops.cids = 99
    check("drops stats: a copy", w:stats().drops.cids == 2)
    w:reset()
    check("drops stats: reset clears", w:stats().drops_first_ms == nil and w:stats().drops == nil)
    local calls = f.data.drops_calls
    w:refresh(20, true, MS)
    check("drops stats: the first refresh after reset does not read", f.data.drops_calls == calls)
    w:refresh(20, true, MS)
    check("drops stats: the second refresh reads again", f.data.drops_calls == calls + 1
      and w:stats().drops_first_ms ~= nil and w:stats().drops.ids == 3)
  end
end

-- 14. Shops toggle drives the shop index (SPEC 20.2)
do
  local function shops_world(mod)
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chara", "m5", 5, 0, 0, { name = "ch253000_00" }) }) } })
    local d = f.data
    d.boss = { ch253 = true }
    d.iname = { [378] = "Grimoire", [230] = "Minotaur Horn" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.shops = { [41] = { { item = 378, release_qid = 0, sentiment_bit = 0, total_pay = 0,
      flag = 0, var_cond = 0 } } }
    if mod then mod(f) end
    return f.new(), f
  end
  local w, f = shops_world()
  w:refresh(0, true, { shops = true })
  local sh = w:input() and w:input().shops
  check("shops toggle: index published", sh ~= nil and #sh == 1 and sh[1].npc == "Dudley")
  check("shops toggle: discovery refreshed", (f.reads_n.discovered_count or 0) >= 1)
  check("shops toggle: search_first_ms set", w:stats().search_first_ms ~= nil)

  local w2, f2 = shops_world()
  w2:refresh(0, true, { shops = true, monsters = true })
  w2:refresh(0, true, { shops = true, monsters = true })
  check("shops toggle: no drop read", (f2.reads_n.monster_drops or 0) == 0
    and f2.data.drops_calls == nil)
  check("shops toggle: no drops published", w2:input().drops == nil)

  local w3, f3 = shops_world()
  check("shops toggle: round_ms nil before a round", w3:stats().round_ms == nil)
  f3.reads.shops = (function(orig) return function(...)
    f3.clock_t = f3.clock_t + 0.25
    return orig(...)
  end end)(f3.reads.shops)
  w3:refresh(0, true, { shops = true })
  check("shops toggle: round_ms is a number", type(w3:stats().round_ms) == "number"
    and w3:stats().round_ms > 0)

  local w4, f4 = shops_world()
  check("shops toggle: all off returns early", w4:refresh(0, true, {}) == false)
  check("shops toggle: all off reads no shops", (f4.reads_n.shops or 0) == 0)
  local w5 = shops_world()
  check("shops toggle: early return does not fire", w5:refresh(0, true, { shops = true }) == true)
end

-- ===== v14 Task 4: NPC names, routes and spawned holders (SPEC 22.7-22.9) =====
do
  local stub = { calls = { route_stops = 0, area_pos = 0 } }
  function stub.today(day, hour)
    return { week = math.floor(day / 7) % 4 + 1, weekday = day % 7, hour = hour }
  end
  function stub.route_stops(rows, today, area_pos, cur)
    stub.calls.route_stops = stub.calls.route_stops + 1
    stub.last_cur, stub.last_today = cur, today
    local stops, unplaced = {}, 0
    for _, r in ipairs(rows) do
      stub.calls.area_pos = stub.calls.area_pos + 1
      local p = area_pos(r)
      if p == nil then unplaced = unplaced + 1
      else
        stops[#stops + 1] = { from = r.start_hour, to = r.end_hour, area = r.area,
          location = r.location, pos = p }
      end
    end
    return stops, unplaced
  end
  function stub.anchor_node(list) return list[1] end
  function stub.tier(rank)
    if type(rank) ~= "number" or rank == -501 then return nil end
    return "T" .. rank
  end
  package.loaded["Clairvoyance.npcs"] = nil
  package.preload["Clairvoyance.npcs"] = function() return stub end

  local function nfix()
    local f = fixture()
    local d = f.data
    d.rows, d.day, d.hour, d.cur, d.area_nodes = {}, 33, 7, {}, {}
    d.holders, d.sent, d.generic, d.hcount = {}, {}, {}, 0
    local function rdef(name, fn)
      f.reads[name] = function(...)
        f.reads_n[name] = (f.reads_n[name] or 0) + 1
        if f.fail[name] then error("fake read failure: " .. name) end
        return fn(...)
      end
    end
    rdef("schedule_rows", function(cid) return d.rows[cid] end)
    rdef("schedule_now", function() return d.day, d.hour end)
    rdef("current_row", function(cid) return d.cur[cid] end)
    rdef("area_nodes", function(row)
      return d.area_nodes[row.area .. ":" .. tostring(row.location)] or d.area_nodes[row.area]
    end)
    rdef("holder_count", function() return d.hcount end)
    rdef("holder_at", function(i) return d.holders[i] end)
    rdef("sentiment", function(h) return d.sent[h.cid] and d.sent[h.cid].rank,
      d.sent[h.cid] and d.sent[h.cid].value end)
    f.adapter.is_generic = function(cid) return d.generic[cid] == true end
    stub.calls.route_stops, stub.calls.area_pos = 0, 0
    return f, d
  end

  local function ids(n)
    local t = {}
    for i = 1, n do t[i] = 1000 + i end
    return t
  end

  -- names: 200 per round, rerun until done, generic and nil names skipped
  do
    local f, d = nfix()
    d.sched_ids = ids(450)
    for _, c in ipairs(d.sched_ids) do d.npcname[c] = "N" .. c end
    d.generic[1003] = true
    d.npcname[1005] = nil
    local w = f.new()
    local tg = on("search")
    check("names: round ran", w:refresh(0, true, tg))
    check("names: first slice 200 cids read", (f.adapter_n.npc_name or 0) <= 200
      and (f.adapter_n.npc_name or 0) >= 199)
    local n1 = w:input().npcs
    check("names: 198 entries after round 1 (generic and nil skipped)",
      n1 ~= nil and #n1 == 198)
    check("names: not done sets rerun (next refresh runs inside throttle)",
      w:refresh(0.5, true, tg) == true)
    check("names: 2 rounds read 400 cids", #w:input().npcs == 398)
    check("names: round 3 still inside throttle runs", w:refresh(1, true, tg) == true)
    check("names: all 450 less 2 after round 3", #w:input().npcs == 448)
    local seen = {}
    for _, e in ipairs(w:input().npcs) do seen[e.cid] = e.name end
    check("names: generic excluded", seen[1003] == nil)
    check("names: nil name excluded", seen[1005] == nil)
    check("names: name carried", seen[1010] == "N1010")
    check("names: entry has no pos without npc_cids", w:input().npcs[1].pos == nil
      and w:input().npcs[1].alive == nil)
    check("names: npcs_first_ms set", w:stats().npcs_first_ms ~= nil)
    check("names: finished, no rerun", w:refresh(1.5, true, tg) == false)
    f.clear_counts()
    w:poke()
    w:refresh(20, true, tg)
    check("names: finished list is not re-read", (f.adapter_n.npc_name or 0) == 0)
    w:reset()
    check("names: reset clears npcs_first_ms", w:stats().npcs_first_ms == nil)
    check("names: reset empties the published list", w:input() == nil)
    w:refresh(30, true, tg)
    check("names: after reset the list rebuilds from the start",
      #w:input().npcs == 198)
  end

  -- search off: no name read
  do
    local f, d = nfix()
    d.sched_ids = ids(10)
    for _, c in ipairs(d.sched_ids) do d.npcname[c] = "N" .. c end
    local w = f.new()
    w:refresh(0, true, on("chests"))
    check("names: search off reads no name", (f.adapter_n.npc_name or 0) == 0)
    check("names: search off publishes no npcs", w:input().npcs == nil)
  end

  -- positions only for npc_cids; discovered key per cid
  do
    local f, d = nfix()
    d.sched_ids = { 2001, 2002 }
    d.npcname[2001], d.npcname[2002] = "Aa", "Bb"
    d.npcpos[2001] = P(10, 0, 10)
    d.npcpos[2002] = P(900, 0, 900)
    d.icons = {
      { type = K.SETTLEMENT_TYPE, pos = P(0, 0, 0), disp_id = "a", icon_id = 1 },
      { type = K.SETTLEMENT_TYPE, pos = P(1000, 0, 1000), disp_id = "b", icon_id = 2 } }
    d.msgs = { a = "Town A", b = "Town B" }
    d.icons_found = { [2] = true }
    d.disc_n = 1
    local w = f.new()
    w:refresh(0, true, { search = true, npc_cids = { 2001 } })
    local by = {}
    for _, e in ipairs(w:input().npcs) do by[e.cid] = e end
    check("npc pos: listed cid has pos", by[2001].pos ~= nil and by[2001].pos.x == 10)
    check("npc pos: listed cid alive", by[2001].alive == true)
    check("npc pos: listed cid discovered false (near town A)",
      by[2001].discovered == false)
    check("npc pos: other cid has no pos", by[2002].pos == nil)
    check("npc pos: other cid has no alive", by[2002].alive == nil)
    check("npc pos: other cid has no discovered", by[2002].discovered == nil)
    check("npc pos: one alive read", (f.adapter_n.npc_alive or 0) >= 1)
    -- cached under "n:<cid>": a move to the discovered town keeps the answer
    d.npcpos[2001] = P(990, 0, 990)
    w:poke()
    w:refresh(1, true, { search = true, npc_cids = { 2001, 2002 } })
    by = {}
    for _, e in ipairs(w:input().npcs) do by[e.cid] = e end
    check("npc pos: discovered cached under n:cid", by[2001].discovered == false)
    check("npc pos: second cid computed on its own key", by[2002].discovered == true)
  end

  -- dead and unpositioned
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.alive = false
    local w = f.new()
    w:refresh(0, true, { search = true, npc_cids = { 2001 } })
    local e = w:input().npcs[1]
    check("npc pos: dead cid alive == false", e.alive == false)
    check("npc pos: no position leaves pos nil", e.pos == nil and e.discovered == nil)
  end

  -- npc_cids change runs a round inside the throttle
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    local w = f.new()
    w:refresh(0, true, { search = true, npc_cids = { 2002, 2001 } })
    check("sig: unchanged set (other order) does not run",
      w:refresh(1, true, { search = true, npc_cids = { 2001, 2002 } }) == false)
    check("sig: changed set runs a round",
      w:refresh(2, true, { search = true, npc_cids = { 2001 } }) == true)
    check("sig: nil set differs from a set",
      w:refresh(3, true, { search = true }) == true)
    check("sig: nil again does not run",
      w:refresh(4, true, { search = true }) == false)
  end

  -- route
  local function rows_of(...)
    local t = {}
    for _, r in ipairs({ ... }) do
      t[#t + 1] = { start_week = 1, end_week = 4, start_day = 0, end_day = 6,
        start_hour = r[1], end_hour = r[2], area = r[3], location = r[4] or 0,
        priority = 0 }
    end
    return t
  end

  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.rows[2001] = rows_of({ 6, 18, 49 }, { 18, 6, 46 }, { 0, 1, 99 })
    d.cur[2001] = { area = 49, location = 0, pos = P(5, 5, 5) }
    d.area_nodes[49] = { P(1, 0, 1), P(2, 0, 2) }
    d.area_nodes[46] = { P(990, 0, 990) }
    d.icons = {
      { type = K.SETTLEMENT_TYPE, pos = P(0, 0, 0), disp_id = "a", icon_id = 1 },
      { type = K.SETTLEMENT_TYPE, pos = P(1000, 0, 1000), disp_id = "b", icon_id = 2 } }
    d.msgs = { a = "Town A", b = "Town B" }
    d.icons_found = { [2] = true }
    d.disc_n = 1
    local w = f.new()
    local tg = on("search")
    w:refresh(0, true, tg)
    check("route: none until set", w:input().route == nil)
    w:set_route(2001, "Aa")
    check("route: set_route then refresh builds on that call",
      w:refresh(1, true, tg) == true)
    local r = w:input().route
    check("route: cid and name", r ~= nil and r.cid == 2001 and r.name == "Aa")
    check("route: stops from route_stops", r and #r.stops == 2 and r.stops[1].area == 49
      and r.stops[1].pos.x == 1 and r.stops[2].area == 46)
    check("route: unplaced carried", r and r.unplaced == 1)
    check("route: no error", r and r.err == nil)
    check("route: cur passed", stub.last_cur and stub.last_cur.area == 49
      and stub.last_cur.pos.x == 5)
    check("route: today passed", stub.last_today and stub.last_today.hour == 7
      and stub.last_today.weekday == 5)
    check("route: stop discovered asked (undiscovered town)",
      r and r.stops[1].discovered == false)
    check("route: each stop asks its own area key (second is in a discovered town)",
      r and r.stops[2].discovered == true)
    check("route: one build", stub.calls.route_stops == 1)
    -- unchanged hour reuses cache
    w:poke()
    w:refresh(2, true, tg)
    check("route: unchanged hour reuses the cache", stub.calls.route_stops == 1
      and w:input().route and #w:input().route.stops == 2)
    check("route: cache reads rows once", (f.reads_n.schedule_rows or 0) == 1)
    -- a new day at the same hour rebuilds
    d.day = 34
    w:poke()
    w:refresh(2.5, true, tg)
    check("route: day change at the same hour rebuilds", stub.calls.route_stops == 2)
    d.day = 33
    w:poke()
    w:refresh(2.6, true, tg)
    stub.calls.route_stops = 1
    -- hour change rebuilds once
    d.hour = 8
    w:poke()
    w:refresh(3, true, tg)
    check("route: hour change rebuilds", stub.calls.route_stops == 2)
    w:poke()
    w:refresh(4, true, tg)
    check("route: next round at the same hour reuses", stub.calls.route_stops == 2)
    -- clear
    w:clear_route()
    check("route: clear_route drops the published route", w:input().route == nil)
    w:poke()
    w:refresh(5, true, tg)
    check("route: stays cleared", w:input().route == nil)
    -- set again, then reset clears it
    w:set_route(2001, "Aa")
    w:refresh(6, true, tg)
    check("route: set again builds", w:input().route ~= nil)
    w:reset()
    w:refresh(7, true, tg)
    check("route: reset clears the route", w:input().route == nil)
  end

  -- route errors
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.rows[2001] = rows_of({ 6, 18, 49 })
    d.cur[2001] = { area = 49, location = 0 }
    d.area_nodes[49] = { P(1, 0, 1) }
    local w = f.new()
    local tg = on("search")
    f.fail.schedule_rows = true
    w:set_route(2001, "Aa")
    w:refresh(0, true, tg)
    local r = w:input().route
    check("route err: raising schedule_rows", r ~= nil and r.err == "route unavailable"
      and r.cid == 2001 and r.name == "Aa" and r.stops == nil)
    f.fail.schedule_rows = nil
    w:poke()
    w:refresh(0.5, true, tg)
    check("route err: a failed build is retried the next round, same hour",
      w:input().route.err == nil and #w:input().route.stops == 1)
    d.hour = 9
    w:set_route(2001, "Aa")
    w:refresh(1, true, tg)
    check("route err: recovers when the read works", w:input().route.err == nil
      and #w:input().route.stops == 1)
    -- -1/-1 current row
    local calls = stub.calls.route_stops
    d.cur[2001] = { area = -1, location = -1, pos = P(1, 1, 1) }
    d.hour = 10
    w:set_route(2001, "Aa")
    w:refresh(2, true, tg)
    r = w:input().route
    check("route err: -1/-1 is route unavailable", r.err == "route unavailable"
      and r.stops == nil)
    check("route err: -1/-1 never calls route_stops", stub.calls.route_stops == calls)
    -- raising route_stops leaves no partial stops
    d.cur[2001] = { area = 49, location = 0 }
    local orig = stub.route_stops
    stub.route_stops = function() error("boom") end
    d.hour = 11
    w:set_route(2001, "Aa")
    w:refresh(3, true, tg)
    stub.route_stops = orig
    r = w:input().route
    check("route err: raising route_stops gives err, no stops",
      r.err == "route unavailable" and r.stops == nil and r.unplaced == nil)
    -- schedule_now failure
    f.fail.schedule_now = true
    w:set_route(2001, "Aa")
    w:refresh(4, true, tg)
    check("route err: schedule_now failure", w:input().route.err == "route unavailable")
  end

  -- area_nodes through anchor_node; missing nodes leave a stop unplaced
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.rows[2001] = rows_of({ 6, 18, 49 }, { 18, 6, 77 })
    d.cur[2001] = { area = 49, location = 0 }
    d.area_nodes[49] = { P(9, 0, 9), P(1, 0, 1) }
    d.area_nodes[77] = {}
    local w = f.new()
    w:set_route(2001, "Aa")
    w:refresh(0, true, on("search"))
    local r = w:input().route
    check("route: anchor_node picks the stop position", #r.stops == 1
      and r.stops[1].pos.x == 9)
    check("route: empty node list stays unplaced", r.unplaced == 1)
  end

  -- -1 stops are keyed by area and location
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.rows[2001] = rows_of({ 6, 12, -1, 6 }, { 12, 18, -1, 7 })
    d.cur[2001] = { area = 49, location = 0 }
    d.area_nodes["-1:6"] = { P(5, 0, 5) }
    d.area_nodes["-1:7"] = { P(995, 0, 995) }
    d.icons = {
      { type = K.SETTLEMENT_TYPE, pos = P(0, 0, 0), disp_id = "a", icon_id = 1 },
      { type = K.SETTLEMENT_TYPE, pos = P(1000, 0, 1000), disp_id = "b", icon_id = 2 } }
    d.msgs = { a = "Town A", b = "Town B" }
    d.icons_found = { [2] = true }
    d.disc_n = 1
    local w = f.new()
    w:set_route(2001, "Aa")
    w:refresh(0, true, on("search"))
    local r = w:input().route
    check("route key: area -1 with different locations asked separately",
      r and #r.stops == 2 and r.stops[1].discovered == false
      and r.stops[2].discovered == true)
  end

  -- a failing position read does not lose the round
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    f.afail.npc_alive = true
    local w = f.new()
    local tg = { search = true, npc_cids = { 2001 } }
    check("npc pos: failing alive read keeps the round", w:refresh(0, true, tg) == true
      and #w:input().npcs == 1 and w:input().npcs[1].pos == nil)
    check("npc pos: signature recorded, no back-to-back rounds",
      w:refresh(1, true, tg) == false)
  end

  -- npcs_first_ms spans the whole build
  do
    local f, d = nfix()
    d.sched_ids = ids(450)
    for _, c in ipairs(d.sched_ids) do d.npcname[c] = "N" .. c end
    local base = f.adapter.npc_name
    f.adapter.npc_name = function(cid)
      f.clock_t = f.clock_t + 0.001
      return base(cid)
    end
    local w = f.new()
    local tg = on("search")
    w:refresh(0, true, tg)
    check("first ms: nil after round 1", w:stats().npcs_first_ms == nil)
    w:refresh(0.1, true, tg)
    w:refresh(0.2, true, tg)
    local st = w:stats()
    check("first ms: total spans all three rounds (450 reads of 1 ms)",
      st.npcs_first_ms ~= nil and st.npcs_first_ms > 449 and st.npcs_first_ms < 451)
    check("first ms: largest slice recorded (200 reads)",
      st.npcs_max_slice_ms ~= nil and st.npcs_max_slice_ms > 199
      and st.npcs_max_slice_ms < 201)
    w:reset()
    check("first ms: reset clears the slice maximum", w:stats().npcs_max_slice_ms == nil)
  end

  -- spawned holders
  local function holder(cid, tf) return { cid = cid, transform = tf or { cid = cid }, holder = { cid = cid } } end

  do
    local f, d = nfix()
    d.hcount = 1706
    d.holders[10] = holder(3001)
    d.holders[300] = holder(3002)
    d.holders[1705] = holder(3003)
    d.generic[3002] = true
    d.npcname[3001], d.npcname[3003] = "Aa", "Cc"
    d.npcname[3002] = "Gen"
    d.sent[3001] = { rank = 100, value = 137 }
    d.sent[3003] = { rank = -30, value = 2 }
    local w = f.new()
    check("spawned: empty before a pass", #w.spawned == 0)
    for i = 1, 8 do w:spawned_step(200) end
    check("spawned: not complete after 8 calls", #w.spawned == 0)
    w:spawned_step(200)
    check("spawned: complete after 9 calls", #w.spawned == 2)
    local by = {}
    for _, e in ipairs(w.spawned) do by[e.cid] = e end
    check("spawned: generic holder skipped", by[3002] == nil)
    check("spawned: entry fields", by[3001] and by[3001].name == "Aa"
      and by[3001].tier == "T100" and by[3001].value == 137
      and by[3001].transform ~= nil and type(by[3001].tier_at) == "number")
    check("spawned: second entry", by[3003] and by[3003].tier == "T-30")
    check("spawned: every slot read once", (f.reads_n.holder_at or 0) == 1706)

    -- a nil-named holder is skipped
    local f2, d2 = nfix()
    d2.hcount = 5
    d2.holders[1] = holder(3001)
    d2.holders[2] = holder(3002)
    d2.npcname[3001] = "Aa"
    local w2 = f2.new()
    w2:spawned_step(200)
    check("spawned: nil-named holder skipped", #w2.spawned == 1 and w2.spawned[1].cid == 3001)

    -- a raising holder_at slot is skipped, the pass continues
    local f3, d3 = nfix()
    d3.hcount = 4
    d3.holders[0] = holder(3001)
    d3.holders[3] = holder(3002)
    d3.npcname[3001], d3.npcname[3002] = "Aa", "Bb"
    local orig = f3.reads.holder_at
    f3.reads.holder_at = function(i) if i == 1 then error("freed") end return orig(i) end
    local w3 = f3.new()
    w3:spawned_step(200)
    check("spawned: a raising slot is skipped", #w3.spawned == 2)
  end

  -- sentiment: once per second, raising keeps the entry
  do
    local f, d = nfix()
    d.hcount = 3
    d.holders[0] = holder(3001)
    d.holders[1] = holder(3002)
    d.npcname[3001], d.npcname[3002] = "Aa", "Bb"
    d.sent[3001] = { rank = 200, value = 1 }
    d.sent[3002] = { rank = 100, value = 2 }
    local w = f.new()
    w:spawned_step(200)
    check("sentiment: read once per cid", f.reads_n.sentiment == 2)
    f.clock_t = f.clock_t + 0.5
    w:spawned_step(200)
    check("sentiment: second pass within 1 s does not re-read", f.reads_n.sentiment == 2)
    check("sentiment: cached tier kept", w.spawned[1].tier ~= nil and #w.spawned == 2)
    f.clock_t = f.clock_t + 1
    w:spawned_step(200)
    check("sentiment: re-read after 1 s", f.reads_n.sentiment == 4)

    -- raising sentiment keeps the entry with tier nil
    local f2, d2 = nfix()
    d2.hcount = 2
    d2.holders[0] = holder(3001)
    d2.npcname[3001] = "Aa"
    f2.fail.sentiment = true
    local w2 = f2.new()
    w2:spawned_step(200)
    check("sentiment: raising keeps the entry", #w2.spawned == 1)
    check("sentiment: raising leaves tier nil", w2.spawned[1].tier == nil
      and w2.spawned[1].value == nil)
    local n = f2.reads_n.sentiment
    w2:spawned_step(200)
    check("sentiment: a failed read is not retried inside 1 s", f2.reads_n.sentiment == n)

    -- a full pass replaces the list
    d2.holders[0] = nil
    f2.clock_t = f2.clock_t + 2
    w2:spawned_step(200)
    check("spawned: a full pass replaces the list", #w2.spawned == 0)

    -- reset empties the list
    local f5, d5 = nfix()
    d5.hcount = 2
    d5.holders[0] = holder(3001)
    d5.npcname[3001] = "Aa"
    local w5 = f5.new()
    w5:spawned_step(200)
    w5:reset()
    check("spawned: reset empties the list", #w5.spawned == 0)
    w5:spawned_step(200)
    check("spawned: walk works after reset", #w5.spawned == 1)
    -- a count that is unreadable does nothing and does not raise
    local f6, d6 = nfix()
    f6.fail.holder_count = true
    local w6 = f6.new()
    local ok = pcall(w6.spawned_step, w6, 200)
    check("spawned: unreadable count does not raise", ok and #w6.spawned == 0)
  end

  -- reset empties names, route, spawned together
  do
    local f, d = nfix()
    d.sched_ids = { 2001 }
    d.npcname[2001] = "Aa"
    d.rows[2001] = rows_of({ 6, 18, 49 })
    d.cur[2001] = { area = 49, location = 0 }
    d.area_nodes[49] = { P(1, 0, 1) }
    d.hcount = 1
    d.holders[0] = holder(2001)
    local w = f.new()
    w:set_route(2001, "Aa")
    w:refresh(0, true, on("search"))
    w:spawned_step(200)
    check("reset all: precondition", #w:input().npcs == 1 and w:input().route ~= nil
      and #w.spawned == 1)
    w:reset()
    w:refresh(1, true, on("search"))
    check("reset all: route gone", w:input().route == nil)
    check("reset all: spawned gone", #w.spawned == 0)
  end
end

if failures > 0 then os.exit(1) end
print("world_test: all OK")
