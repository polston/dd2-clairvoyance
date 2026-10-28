-- tests/world_test.lua - drives Clairvoyance/world.lua with a fake
-- reads table, a fake adapter and a fake io, all counting every call
-- (SPEC 17.3, 17.10). Pure Lua; no sdk.
package.path = "./reframework/autorun/?.lua;" .. package.path
local world = require("Clairvoyance.world")
local core = require("Clairvoyance.core")

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")

local K = world.K
local NAN = 0 / 0

local function on(...)
  local t = {}
  for _, k in ipairs({ ... }) do t[k] = true end
  return t
end
local ALL = on("chests", "treasure", "tokens", "beetles", "monsters", "small_monsters",
  "sellers")
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
  local f = { files = o.files or {}, dumps = {}, clock_t = 0, load_cost = 0, load_n = 0,
    load_raises = {}, reads_n = {}, adapter_n = {}, fail = {}, afail = {},
    data = {
      reserved = {}, loaded = {}, sched = {}, icons = {}, msgs = {},
      records = {}, nodes = {}, checked = {}, icons_found = {}, disc_n = 0,
      sched_ids = {}, shop = {}, shops = {}, respawn = {}, boss = {},
      loaded_boss = {}, badge = {}, badge_default = "Griffin",
      catalog = {}, cast = {}, needs = {}, locs = {}, qstate = {},
      gate_quests = {}, gate_vars = {}, season4 = false,
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
  def("reserved_sig", function() return d.sig end)
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
  def("game_season4", function() return d.season4 end)
  def("quest_state", function(qid) return d.gate_quests[qid] end)
  def("quest_variable", function(c)
    local key = table.concat({ c.qid, c.name_hash, c.value_type, c.compare_type,
      c.bool_value and 1 or 0, c.int_value }, ":")
    return d.gate_vars[key]
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
      f.load_n = f.load_n + 1
      if f.load_raises[path] then error("fake load failure") end
      if path == K.PLACES then
        f.places_load_n = (f.places_load_n or 0) + 1
        f.clock_t = f.clock_t + f.load_cost
      end
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

local function chest_row(uid, x, z, ix, gimmick)
  return { uid = uid, pos = P(x, 0, z), gimmick = gimmick or 10, table_ix = ix or 1 }
end

local function find(list, uid)
  for _, e in ipairs(list or {}) do if e.uid == uid then return e end end
  return nil
end

local function route_in(w, cid)
  local l = w:input() and w:input().routes
  if type(l) ~= "table" then return nil end
  if cid == nil then return l[1] end
  for _, e in ipairs(l) do if e.cid == cid then return e end end
  return nil
end

local function places(rows, pak)
  return { version = 2, pak = pak or "1:1", rows = rows }
end

-- Minimal decoder for the shared JSON fixture only; production JSON decoding
-- remains REFramework's json.load_file path.
local function decode_fixture_json(source)
  local at, null = 1, {}
  local function ws()
    while source:sub(at, at):match("%s") do at = at + 1 end
  end
  local function str()
    assert(source:sub(at, at) == '"'); at = at + 1
    local out = {}
    while at <= #source do
      local c = source:sub(at, at); at = at + 1
      if c == '"' then return table.concat(out) end
      if c == "\\" then
        local e = source:sub(at, at); at = at + 1
        local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
          b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if e == "u" then
          local hex = source:sub(at, at + 3)
          assert(hex:match("^%x%x%x%x$"), "bad fixture unicode escape")
          local cp = tonumber(hex, 16); at = at + 4
          assert(cp < 128, "fixture decoder supports ASCII escapes only")
          out[#out + 1] = string.char(cp)
        else
          assert(escapes[e] ~= nil, "bad fixture escape")
          out[#out + 1] = escapes[e]
        end
      else
        out[#out + 1] = c
      end
    end
    error("unterminated fixture string")
  end
  local value
  value = function()
    ws()
    local c = source:sub(at, at)
    if c == '"' then return str() end
    if c == "{" then
      at = at + 1; ws()
      local out = {}
      if source:sub(at, at) == "}" then at = at + 1; return out end
      while true do
        ws(); local k = str(); ws()
        assert(source:sub(at, at) == ":", "expected fixture colon"); at = at + 1
        out[k] = value(); ws()
        local sep = source:sub(at, at); at = at + 1
        if sep == "}" then return out end
        assert(sep == ",", "expected fixture object separator")
      end
    end
    if c == "[" then
      at = at + 1; ws()
      local out = {}
      if source:sub(at, at) == "]" then at = at + 1; return out end
      while true do
        out[#out + 1] = value(); ws()
        local sep = source:sub(at, at); at = at + 1
        if sep == "]" then return out end
        assert(sep == ",", "expected fixture array separator")
      end
    end
    for literal, v in pairs({ ["true"] = true, ["false"] = false, ["null"] = null }) do
      if source:sub(at, at + #literal - 1) == literal then at = at + #literal; return v end
    end
    local token = source:sub(at):match("^%-?%d+%.?%d*[eE]?[+-]?%d*")
    assert(token ~= nil and token ~= "", "bad fixture value")
    at = at + #token
    return assert(tonumber(token), "bad fixture number")
  end
  local out = value(); ws()
  assert(at > #source, "trailing fixture JSON")
  return out
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
  w, ok = case(function(f) f.files[K.PLACES] = { version = 1,
    rows = { prow("chest", "v1", 10, 1, 1) } } end)
  check("places: version 1 is bad", w:places_state().state == "bad" and ok)
  check("places: version 1 rows are not used", w:stats().places.rows == 0)
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

-- 16b. places_v2_atomic_schema
do
  local function bad_row(row)
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chara", "valid-first", 1, 10, 0, { name = "ch253000_00" }), row }) } })
    local w = f.new()
    check("v2 atomic: malformed row rejects file", w:places_state().state == "bad")
    check("v2 atomic: malformed row publishes no rows", w:stats().places.rows == 0)
    check("v2 atomic: malformed row publishes no partial atlas", w:stats().atlas.file == 0)
    w:refresh(0, true, on("monsters", "chests"))
    check("v2 atomic: earlier name/row does not draw", #w:input().monsters == 0)
  end
  local function row(extra)
    local r = prow("chara", "bad", 2, 20, 0, { name = "ch253001_00" })
    for k, v in pairs(extra) do r[k] = v end
    return r
  end
  bad_row(row({ src = "mystery" }))
  local missing_src = row({}); missing_src.src = nil; bad_row(missing_src)
  bad_row(row({ src = "subquest", table_qid = nil }))
  bad_row(row({ src = "subquest", table_qid = "12000" }))
  bad_row(row({ table_qid = 12000 }))
  bad_row(row({ phase = "season5" }))
  bad_row(row({ phase = 4 }))
  bad_row(row({ gate = { conditions = { { kind = "quest", qid = 12000, finish = true } } } }))
  bad_row(row({ gate = { check = 0, conditions = {} } }))
  bad_row(row({ gate = { check = "0", conditions = {} } }))
  bad_row(row({ gate = { check = 0.5, conditions = {} } }))
  bad_row(row({ gate = { check = 2, conditions = {} } }))
  bad_row(row({ gate = { check = 0, conditions = "bad" } }))
  bad_row(row({ gate = { check = 0, conditions = { [1] = { kind = "quest", qid = 12000, finish = true },
    [3] = { kind = "quest", qid = 12001, finish = true } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "unknown" } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "quest", qid = 0, finish = true } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "quest", qid = 12000.5, finish = true } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "quest", qid = 12000 } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "quest", qid = 12000, finish = 1 } } } }))
  bad_row(row({ gate = { check = 0, conditions = { { kind = "variable", qid = 51010,
    name_hash = 1, value_type = 0, compare_type = 0, bool_value = true,
    int_value = 0, unexpected = true } } } }))
  local variable_fields = { kind = "variable", qid = 51010, name_hash = 1,
    value_type = 0, compare_type = 0, bool_value = true, int_value = 0 }
  for _, field in ipairs({ "qid", "name_hash", "value_type", "compare_type", "bool_value", "int_value" }) do
    local c = {}
    for k, v in pairs(variable_fields) do c[k] = v end
    c[field] = nil
    bad_row(row({ gate = { check = 0, conditions = { c } } }))
  end
  local wrong_types = { qid = "51010", name_hash = "1", value_type = "0",
    compare_type = "0", bool_value = 1, int_value = "0" }
  for field, value in pairs(wrong_types) do
    local c = {}
    for k, v in pairs(variable_fields) do c[k] = v end
    c[field] = value
    bad_row(row({ gate = { check = 0, conditions = { c } } }))
  end
  local f = fixture({ files = { [K.PLACES] = places({
    prow("chara", "late-name", 3, 30, 0, { name = "ch253003_00" }),
    row({ src = "subquest" }) }) } })
  f.files[K.ATLAS] = { version = 1, pak = "1:1", entries = {
    conditional = { k = "monster", id = 4, x = 88, y = 0, z = 88 },
    unconditional = { k = "monster", id = 5, x = 99, y = 0, z = 99 } } }
  local w = f.new()
  check("v2 atomic: late invalid row rejects prior name", w:stats().places.state == "bad"
    and w:stats().places.rows == 0 and w:stats().atlas.learned == 2)
end

-- 16c. shared extractor/runtime format-2 contract
do
  local fh = assert(io.open("tests/fixtures/conditional_places_v2.json", "rb"))
  local shared = decode_fixture_json(fh:read("*a")); fh:close()
  check("shared v2 fixture: exact expected rows", shared.version == 2 and #shared.rows == 3)
  local by_id = {}
  for _, r in ipairs(shared.rows) do by_id[r.id] = r end
  check("shared v2 fixture: source and condition schema", by_id[5].src == "normal"
    and by_id[6].table_qid == 20082 and by_id[6].phase == "beforeseason4"
    and by_id[6].gate.check == 0 and by_id[6].gate.conditions[2].kind == "variable"
    and by_id[10].gate.check == 1)
  local f = fixture({ files = { [K.PLACES] = shared } })
  f.data.boss = { ch253 = true }
  f.data.season4 = false
  f.data.gate_quests[20082] = { active = true, ended = false }
  f.data.gate_quests[11040] = { active = true, ended = false }
  f.data.gate_vars["51010:110914987:1:1:1:0"] = true
  f.data.qstate[11040] = true
  -- The file has compact display names to stay tiny; give its two monster
  -- records real family names for the class renderer while preserving gates.
  by_id[5].name, by_id[6].name = "ch253000_00", "ch220000_00"
  local w = f.new()
  w:refresh(0, true, on("monsters", "small_monsters", "chests"))
  local monsters, gates = w:input().monsters, w:stats().gates
  check("shared v2: both eligible monster rows draw", find(monsters, by_id[5].uid) ~= nil
    and find(monsters, by_id[6].uid) ~= nil)
  check("shared v2: normal and conditional eligibility stats", gates.normal_source.eligible == 1
    and gates.normal_source.total == 1 and gates.quest_source.eligible == 1
    and gates.quest_source.total == 1 and gates.season4 == false)
  local chest_uid = by_id[10].uid
  local chest = find(w:input().chests, chest_uid)
  check("shared v2: chest gate projects to existing quest fields",
    chest ~= nil and #chest.gate_qids == 1 and chest.gate_qids[1] == 11040
    and chest.kinds[1] == "quest")
  local focus = { active = { 11040 }, quests = { [11040] = { items = {}, places = {} } } }
  w:refresh(10, true, { treasure = true, focus = focus })
  check("shared v2: chest gate still projects into quest focus",
    find(w:input().chests, chest_uid) ~= nil)
  f.data.gate_vars["51010:110914987:1:1:1:0"] = false
  w:refresh(20, true, on("monsters", "small_monsters"))
  check("shared v2: failed mixed gate hides only its quest monster",
    find(w:input().monsters, by_id[5].uid) ~= nil and find(w:input().monsters, by_id[6].uid) == nil)
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
    prow("chara", "r5", 5, 500, 0, { name = "ch253000_00", src = "subquest", table_qid = 12000 }),
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

-- 22c. conditional_monster_eligibility
do
  local function quest(qid, finish)
    return { kind = "quest", qid = qid, finish = finish }
  end
  local variable = { kind = "variable", qid = 51010, name_hash = 110914987,
    value_type = 1, compare_type = 0, bool_value = true, int_value = 0 }
  local function var_key(c)
    return table.concat({ c.qid, c.name_hash, c.value_type, c.compare_type,
      c.bool_value and 1 or 0, c.int_value }, ":")
  end
  local function gate(check, conditions) return { check = check, conditions = conditions } end
  local rows = {
    prow("chara", "always", 1001, 100, 0, { name = "ch253000_00" }),
    prow("chara", "before4", 1002, 200, 0, { name = "ch253000_00", phase = "beforeseason4" }),
    prow("chara", "season4", 1003, 300, 0, { name = "ch253000_00", phase = "season4" }),
    prow("chara", "before5", 1004, 400, 0, { name = "ch253000_00", src = "subquest",
      table_qid = 11040, gate = gate(0, { quest(11040, false) }) }),
    prow("chara", "and-fail", 1005, 500, 0, { name = "ch253000_00",
      gate = gate(0, { quest(11040, true), variable }) }),
    prow("chara", "or-pass", 1006, 600, 0, { name = "ch253000_00",
      gate = gate(1, { quest(11040, true), variable }) }),
    prow("chara", "table-ended", 1007, 700, 0, { name = "ch253000_00", src = "mainquest",
      table_qid = 11041 }),
    prow("chara", "table-inactive", 1008, 800, 0, { name = "ch253000_00", src = "subquest",
      table_qid = 11042 }),
  }
  local f = fixture({ files = { [K.PLACES] = places(rows) } })
  f.data.boss = { ch253 = true }
  f.data.season4 = false
  f.data.gate_quests = { [11040] = { active = true, ended = false },
    [11041] = { active = true, ended = true }, [11042] = { active = false, ended = false } }
  f.data.gate_vars[var_key(variable)] = true
  local w = f.new()
  w:refresh(0, true, on("monsters"))
  local m = w:input().monsters
  check("gates: unconditional and matching phases", find(m, "always") ~= nil
    and find(m, "before4") ~= nil and find(m, "season4") == nil)
  check("gates: BeforeSeason5 has no phase gate", find(m, "before5") ~= nil)
  check("gates: AND, OR and quest table", find(m, "and-fail") == nil
    and find(m, "or-pass") ~= nil and find(m, "table-ended") == nil
    and find(m, "table-inactive") == nil)
  check("gates: qid read once across table and both finish polarities",
    f.reads_n.quest_state == 3)
  check("gates: variable evaluator once per condition", f.reads_n.quest_variable == 1)
  local gs = w:stats().gates
  check("gates: counts and season stat", gs.season4 == false
    and gs.normal_source.total == 5 and gs.quest_source.total == 3
    and gs.normal_source.eligible == 3 and gs.quest_source.eligible == 1)
  w:refresh(10, true, on("monsters"))
  check("gates: round memo clears", f.reads_n.quest_state == 6
    and f.reads_n.quest_variable == 2 and f.reads_n.game_season4 == 2)
  f.data.season4 = true
  w:refresh(20, true, on("monsters"))
  check("gates: both season4 branches and BeforeSeason5", find(w:input().monsters, "before4") == nil
    and find(w:input().monsters, "season4") ~= nil and find(w:input().monsters, "before5") ~= nil)
  w:reset()
  w:refresh(30, true, on("monsters"))
  check("gates: owner reset clears round memo", f.reads_n.quest_state == 12
    and f.reads_n.quest_variable == 4)

  local f2 = fixture({ files = { [K.PLACES] = places({
    prow("chara", "plain", 2001, 100, 0, { name = "ch253000_00" }),
    prow("chara", "gated", 2002, 200, 0, { name = "ch253000_00",
      gate = gate(0, { quest(11999, true) }) }),
    prow("chara", "phase", 2003, 300, 0, { name = "ch253000_00", phase = "season4" }),
    prow("chara", "var-fail", 2004, 400, 0, { name = "ch253000_00",
      gate = gate(0, { variable }) }) }) } })
  f2.data.boss = { ch253 = true }
  f2.fail.quest_state = true
  f2.fail.game_season4 = true
  f2.fail.quest_variable = true
  local w2 = f2.new()
  w2:refresh(0, true, on("monsters"))
  check("gates: conditional read failures isolate", #w2:input().monsters == 1
    and find(w2:input().monsters, "plain") ~= nil)
  check("gates: failure counts", w2:stats().gates.read_failures.quest == 1
    and w2:stats().gates.read_failures.season4 == 1
    and w2:stats().gates.read_failures.variable == 1)
end

-- 22d. conditional rows stay reserved-only and learned corrections are safe
do
  local row = prow("chara", "conditional", 3001, 100, 0, { name = "ch253000_00",
    gate = { check = 0, conditions = { { kind = "quest", qid = 12040, finish = false } } } })
  local plain = prow("chara", "plain-correction", 3002, 200, 0, { name = "ch253000_00" })
  local function scenario(active)
    local files = { [K.PLACES] = places({ row, plain }),
      [K.ATLAS] = { version = 1, pak = "1:1", entries = {
        conditional = { k = "monster", id = 3001, x = 900, y = 0, z = 900 },
        ["plain-correction"] = { k = "monster", id = 3002, x = 800, y = 0, z = 800 } } } }
    local f = fixture({ files = files })
    f.data.boss = { ch253 = true }
    f.data.gate_quests[12040] = { active = true, ended = not active }
    f.data.reserved = { mrow("conditional", 3001, "ch253000_00", 500, 0) }
    local w = f.new()
    w:refresh(0, true, on("monsters"))
    check("reserved gate: live row draws regardless of file gate " .. tostring(active),
      find(w:input().monsters, "conditional") ~= nil)
    check("reserved gate: old conditional atlas entry pruned", w:stats().atlas.learned == 1
      and w:stats().gates.conditional_learned == 0)
    w:save("test")
    f.data.gate_quests[12040].ended = true
    f.data.reserved = {}
    w:refresh(20, true, on("monsters"))
    check("reserved gate: row disappears when gate fails and reservation ends",
      find(w:input().monsters, "conditional") == nil)
    w:save("test")
    check("reserved gate: conditional uid is never saved",
      f.files[K.ATLAS].entries.conditional == nil)
    check("reserved gate: unconditional learned correction stays",
      f.files[K.ATLAS].entries["plain-correction"] ~= nil)
  end
  scenario(false)
  scenario(true)
end

-- 22e. conditional quest-cast rows remain session-only file givers
do
  local uid = "60887e70-7bd1-0227-2a67-f385cc4c6a28"
  local sphinx = prow("chara", uid, 3369196004, 40, 50, {
    name = "ch253001_00", src = "subquest", table_qid = 20200 })
  local function scenario(active, label)
    local f = fixture({ files = {
      [K.PLACES] = places({ sphinx }),
      [K.ATLAS] = { version = 1, pak = "1:1", entries = {
        [uid] = { k = "giver", id = 3369196004, x = 900, y = 0, z = 900 } } } } })
    f.data.catalog, f.data.cast = { 20200 }, { [20200] = { 3369196004 } }
    f.data.gate_quests[20200] = { active = active, ended = false }
    f.data.boss = { ch253 = true }
    local w = f.new()
    w:refresh(0, true, on("monsters", "small_monsters"))
    local giver = w:givers()[3369196004]
    check("conditional cast row: Sphinx stays in the giver map " .. label,
      giver ~= nil and giver.x == 40 and giver.y == 0 and giver.z == 50)
    f.data.reserved = { mrow(uid, 3369196004, "ch253001_00", 400, 500) }
    w:refresh(20, true, on("monsters", "small_monsters"))
    local live_giver = w:givers()[3369196004]
    check("conditional cast row: live giver position overrides file " .. label,
      live_giver ~= nil and live_giver.x == 400 and live_giver.y == 0
        and live_giver.z == 500)
    f.data.reserved = {}
    w:refresh(40, true, on("monsters", "small_monsters"))
    local fallback_giver = w:givers()[3369196004]
    check("conditional cast row: file giver returns after live row leaves " .. label,
      fallback_giver ~= nil and fallback_giver.x == 40 and fallback_giver.y == 0
        and fallback_giver.z == 50)
    check("conditional cast row: absent from monster markers " .. label,
      find(w:input().monsters, uid) == nil)
    check("conditional cast row: legacy giver entry is pruned and session-only " .. label,
      w:stats().atlas.learned == 0 and w:stats().gates.conditional_learned == 0)
    w:save("test")
    check("conditional cast row: giver is not saved " .. label,
      f.files[K.ATLAS].entries[uid] == nil)
  end
  scenario(true, "while active")
  scenario(false, "before activation")
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
    { prow("chara", "sq1", 5, 500, 0, { name = "ch253000_00", src = "subquest", table_qid = 12000 }),
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
    prow("chara", "msq", 5, 500, 0, { name = "ch253000_00", src = "subquest", table_qid = 12000 }),
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

-- monster kinds (SPEC 29.4)
do
  local function kinds_of(m)
    local t = {}
    for _, e in ipairs(m) do t[#t + 1] = tostring(e.kind) end
    table.sort(t)
    return table.concat(t, ",")
  end
  local rows = {
    prow("chara", "k1", 101, 0, 0, { name = "ch221000_00" }),
    prow("chara", "k2", 102, 2, 0, { name = "ch221000_00" }) }
  local f = fixture({ files = { [K.PLACES] = places(rows) } })
  f.data.badge = { [101] = "Goblin", [102] = "Hobgoblin" }
  local w = f.new()
  w:refresh(0, true, on("monsters", "small_monsters"))
  local m = w:input().monsters
  check("kinds: two clusters", #m == 2)
  check("kinds: own kind", kinds_of(m) == "Goblin,Hobgoblin")
  check("kinds: each count 1", m[1] ~= nil and m[2] ~= nil and m[1].count == 1
    and m[2].count == 1)

  local rows2 = {
    prow("chara", "g1", 101, 0, 0, { name = "ch221000_00" }),
    prow("chara", "g2", 101, 2, 0, { name = "ch221000_00" }) }
  local f2 = fixture({ files = { [K.PLACES] = places(rows2) } })
  f2.data.badge = { [101] = "Goblin" }
  local w2 = f2.new()
  w2:refresh(0, true, on("monsters", "small_monsters"))
  local m2 = w2:input().monsters
  check("kinds: one kind one cluster", #m2 == 1 and m2[1].count == 2)
  check("kinds: label with count", m2[1] ~= nil and m2[1].name == "Goblin x2")
  check("kinds: kind has no count", m2[1] ~= nil and m2[1].kind == "Goblin"
    and not tostring(m2[1].kind):find(" x", 1, true))

  f2.data.badge_default = ""
  f2.data.badge = {}
  w2:reset()
  w2:refresh(10, true, on("monsters", "small_monsters"))
  check("kinds: failed badge gives Monster",
    w2:input().monsters[1] ~= nil and w2:input().monsters[1].kind == "Monster")

  local rows3 = {
    prow("chara", "a1", 1, 0, 0, { name = "ch253000_00" }) }
  local f3 = fixture({ files = { [K.PLACES] = places(rows3) } })
  f3.data.boss = { ch253 = true }
  local w3 = f3.new()
  w3:refresh(0, true, on("monsters"))
  check("kinds: large entry carries kind",
    w3:input().monsters[1] ~= nil and w3:input().monsters[1].kind == "Griffin")
end

-- monster families (SPEC 30.4)
do
  local rows = {
    prow("chara", "f1", 101, 0, 0, { name = "ch220000_00" }),
    prow("chara", "f2", 102, 40, 0, { name = "ch220001_00" }) }
  local f = fixture({ files = { [K.PLACES] = places(rows) } })
  f.data.badge = { [101] = "Goblin", [102] = "Hobgoblin" }
  local w = f.new()
  w:refresh(0, true, on("monsters", "small_monsters"))
  local m = w:input().monsters
  check("families: two kinds of one family", #m == 2)
  check("families: first kind carries fam", m[1] ~= nil and m[1].fam == "ch220")
  check("families: second kind carries fam", m[2] ~= nil and m[2].fam == "ch220")
  check("families: the two are different kinds", m[1] ~= nil and m[2] ~= nil and m[1].kind == "Goblin" and m[2].kind == "Hobgoblin")

  local fr = fixture()
  fr.data.respawn = { { key = "zz_0", cid = 1002, cid_name = "ch220002_00", pos = P(300, 0, 300) } }
  fr.data.badge = { [1002] = "Goblin" }
  local wr = fr.new()
  wr:refresh(0, true, on("monsters", "small_monsters"))
  local mr = wr:input().monsters
  check("families: respawning unit carries fam",
    mr[1] ~= nil and mr[1].respawning == true and mr[1].fam == "ch220")

  local fp = fixture({ files = { [K.PLACES] = places({
    prow("chara", "p1", 101, 0, 0, { name = "ch220000_00" }) }) } })
  fp.data.badge = { [101] = "Goblin" }
  local wp = fp.new()
  wp:refresh(0, true, on("monsters", "small_monsters"))
  local mp = wp:input().monsters
  check("families: placed row carries fam",
    mp[1] ~= nil and mp[1].respawning == false and mp[1].fam == "ch220")
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
  local addr_seq = 0
  local function obj(fields, methods, tname)
    local o = {}
    addr_seq = addr_seq + 1
    local my_addr = 0x1000 + addr_seq * 16
    function o:get_address() return my_addr end
    function o:get_field(n) return fields and fields[n] end
    function o:call(n, ...)
      local m = methods and methods[n]
      if m then return m(...) end
      return nil
    end
    function o:get_type_definition()
      return { get_name = function() return tname end,
        get_full_name = function() return tname end }
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
    local o = obj(nil, { get_Count = function() return #items end })
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

  -- reserved signature: count, then per selector 0 or addr:gimmicks:enemies
  local tblA = obj({
    _GimmickSetInfo = obj({ _BasicRowDatas = array({ row_obj({}) }) }),
    _EnemySetInfo = obj({ _BasicRowDatas = array({ row_obj({}) }) }) })
  local tblB = obj({
    _GimmickSetInfo = obj({ _BasicRowDatas = array({ row_obj({}), row_obj({}) }) }) })
  local selA = obj({ ["<Table>k__BackingField"] = tblA })
  local selB = obj({ ["<Table>k__BackingField"] = tblB })
  local selN = obj({})
  local addrA, addrB = tblA:get_address(), tblB:get_address()
  local function set_sels(items)
    singletons["app.GenerateManager"] = obj({ _ReserveManager =
      obj({ _ReservedGenerateSelector = list(items) }) })
  end
  set_sels({ selA, selB })
  local ok1, s1 = pcall(R.reserved_sig)
  check("reads: reserved sig lists count then each table",
    ok1 and s1 == string.format("2,%x:1:1,%x:2:-1", addrA, addrB))
  set_sels({ selB, selA })
  local ok2, s2 = pcall(R.reserved_sig)
  check("reads: reserved sig follows list order", ok2 and s2 ~= s1)
  set_sels({ selA, selN })
  local ok3, s3 = pcall(R.reserved_sig)
  check("reads: a selector with no table is 0 in its slot",
    ok3 and s3 == string.format("2,%x:1:1,0", addrA))
  singletons["app.GenerateManager"] = obj({ _ReserveManager = obj({}) })
  check("reads: unreadable selector list errors",
    type(R.reserved_sig) == "function" and not pcall(R.reserved_sig))
  for label, bad in pairs({ nil_addr = function() return nil end,
      frac_addr = function() return 1.5 end }) do
    local tblX = obj({ _GimmickSetInfo = obj({ _BasicRowDatas = array({}) }) })
    tblX.get_address = bad
    set_sels({ obj({ ["<Table>k__BackingField"] = tblX }) })
    check("reads: reserved sig errors on an unreadable table address (" .. label .. ")",
      type(R.reserved_sig) == "function" and not pcall(R.reserved_sig))
  end

  -- a raising read gives -1 / 0 in its slot, the signature still succeeds
  do
    local tblC = obj({
      _GimmickSetInfo = obj({ _BasicRowDatas = array({ row_obj({}) }) }),
      _EnemySetInfo = obj({ _BasicRowDatas = array({}) }) })
    local base = tblC.get_field
    function tblC:get_field(n)
      if n == "_EnemySetInfo" then error("raised") end
      return base(self, n)
    end
    set_sels({ obj({ ["<Table>k__BackingField"] = tblC }) })
    local okc, sc = pcall(R.reserved_sig)
    check("reads: a raising count read is -1 in its slot",
      okc and sc == string.format("1,%x:1:-1", tblC:get_address()))
    local selR = obj({})
    function selR:get_field(n) error("raised") end
    set_sels({ selR })
    local okr, sr = pcall(R.reserved_sig)
    check("reads: a raising Table read is 0 in its slot", okr and sr == "1,0")
  end

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
      ctx("GmItemContext", { _IsPick = true, _IsKeep = true }),
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
    and by.c1_0.keep == true
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
    ctx("GmItemContext", { _IsPick = false, _IsKeep = false }) }) }
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = addr_list(r1, 100) }) })
  local s1 = R.save_records()
  check("reload: first read", s1[1] and s1[1].picked == true)
  singletons["app.ContextDBMS"] = obj({ OfflineDB = obj({ Records = addr_list(r2, 200) }) })
  local s2 = R.save_records()
  check("reload: same count, new list object, records re-read", s2[1] and s2[1].picked == false)
  check("keep: _IsKeep false reads false", s2[1] and s2[1].keep == false)
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
    local function rowobj(sw, ew, sd, ed, sh, eh, loc, area, pri, key)
      return obj({ StartWeek = sw, EndWeek = ew, StartDay = sd, EndDay = ed,
        StartHour = sh, EndHour = eh, Location = loc, LocalArea = area, Priority = pri,
        TargetKeyLocation = key })
    end
    local function dict(map)
      return obj(nil, { ContainsKey = function(k) return map[k] ~= nil end,
        get_Item = function(k) return map[k] end })
    end
    local curs = { [7] = obj({ LocalArea = 49, Location = 3, Pos = P(1, 2, 3) }),
      [8] = obj({ LocalArea = -1, Location = -1, Pos = P(0, 0, 0) }),
      [9] = obj({ LocalArea = -1, Location = -1, KeyLocation = 2309, Pos = P(5, 5, 5),
        OverwriteSchedule = list({ rowobj(1, 4, 0, 6, 20, 22, -1, -1, 0, 2309),
          rowobj(1, 4, 0, 6, 22, 23, -1, -1, 0, 2310) }) }),
      [10] = obj({ LocalArea = 49, Location = 3, KeyLocation = 0,
        OverwriteSchedule = list({}) }) }
    local rowsd = { [7] = list({ rowobj(1, 4, 0, 6, 6, 18, 3, 49, 0),
      rowobj(1, 4, 0, 6, 18, 6, 3, -1, 1) }),
      [11] = list({ rowobj(1, 4, 0, 6, 0, 24, -1, -1, 0, 2309),
        rowobj(1, 4, 0, 6, 0, 24, -1, -1, 0, 0),
        rowobj(1, 4, 0, 6, 0, 24, -1, -1, 0, -2) }) }
    local keynodes = { [2309] = obj({ _Pos = P(576, 19, -1011) }) }
    local keynodes_get = 0
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
    singletons["app.AIAreaManager"] = obj({
      KeyLocationNodes = obj(nil, { ContainsKey = function(k) return keynodes[k] ~= nil end,
        get_Item = function(k) keynodes_get = keynodes_get + 1; return keynodes[k] end }) }, {
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
    local r11 = R.schedule_rows(11)
    check("reads: row key 2309 kept, 0 reads as -1", r11[1].key == 2309 and r11[2].key == -1
      and r11[3].key == 4294967294
      and rr[1].key == -1)
    local c9, c10 = R.current_row(9), R.current_row(10)
    check("reads: current row key and one overwrite row", c9.key == 2309 and #c9.overwrite == 2
      and c9.overwrite[1].key == 2309 and c9.overwrite[1].start_hour == 20
      and c9.overwrite[1].end_hour == 22 and c9.overwrite[1].area == -1
      and c9.overwrite[1].priority == 0)
    check("reads: current row key 0 reads as -1, empty overwrite", c10.key == -1
      and type(c10.overwrite) == "table" and #c10.overwrite == 0)
    check("reads: missing overwrite list gives {}", R.current_row(7).overwrite ~= nil
      and #R.current_row(7).overwrite == 0 and R.current_row(7).key == -1)
    local kp = R.key_pos(2309)
    check("reads: key_pos is the node _Pos", kp and kp.x == 576 and kp.y == 19 and kp.z == -1011)
    keynodes_get = 0
    check("reads: absent key is nil without get_Item", R.key_pos(7) == nil and keynodes_get == 0)
    local sa, sl, sk, so = R.current_sig(9)
    check("reads: current_sig area, location, key, overwrite keys",
      sa == -1 and sl == -1 and sk == 2309 and so == "2309,2310")
    check("reads: current_sig of an absent cid is nil", R.current_sig(99) == nil)
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

  -- quest override rows (SPEC 26)
  do
    local R = world.game_reads()
    local function qrow(sh, eh, key)
      return obj({ StartWeek = 1, EndWeek = 4, StartDay = 0, EndDay = 6, StartHour = sh,
        EndHour = eh, Location = -1, LocalArea = -1, Priority = 0, TargetKeyLocation = key })
    end
    local function qdict(map)
      return obj(nil, { ContainsKey = function(k) return map[k] ~= nil end,
        get_Item = function(k)
          if map[k] == nil then error("fake missing key") end
          return map[k]
        end })
    end
    local function flag()
      return obj({ _Entity = obj({ _ValueType = 1 }, { evaluate = function() return false end }) },
        nil, "app.quest.condition.CheckVariable")
    end
    local function step(v)
      return obj({ _Entity = obj({ _ValueType = 2 }, { evaluate = function()
        if v == "raise" then error("fake evaluate failure") end
        return v
      end }) }, nil, "app.quest.condition.CheckVariable")
    end
    local function tod() return obj({}, nil, "app.quest.condition.CheckTimeOfDay") end
    local function grp(op, nodes)
      return obj({ _Operator = op, _Entity = array(nodes) }, nil,
        "app.quest.condition.CheckCondiiton")
    end
    -- the top-level condition: array, operator, no-condition flag, own evaluate()
    local function cond(op, nodes, noenable, ev)
      return obj({ _Operator = op, _ConditionArray = array(nodes),
        _IsNoConditonEnable = noenable }, { evaluate = function()
          if ev == "raise" then error("fake evaluate failure") end
          return ev
        end }, "app.quest.condition.NpcOverrideConditionEntity")
    end
    -- an entry carrying one row keyed `key` (o.rows overrides the row list)
    local function entry(addr, key, c, o)
      o = o or {}
      local rows = o.rows or { qrow(6, 15, key) }
      local sched = obj({ _Schedule = o.badsched and obj() or list(rows) })
      local e = obj({ QuestID = o.quest or 1, ConditionEntity = c, OverrideData = obj({
        _Schedule = sched }, { checkEnableScheduleData = function()
          return o.disabled ~= true end }) })
      function e:get_address() return addr end
      return e
    end
    local function setup(all, applied, inactive)
      singletons["app.QuestManager"] = obj({ NpcOverrideDict = qdict(all),
        CurrentNpcOverrideDict = qdict(applied) }, { checkActivated = function(q)
          return not (inactive and inactive[q]) end })
    end
    -- the keys of the rows one read gives, in order
    local function keys(rows)
      if type(rows) ~= "table" then return tostring(rows) end
      local t = {}
      for i, r in ipairs(rows) do t[i] = r.key end
      return table.concat(t, ",")
    end
    -- one entry for cid 1, applied (so the quest steers the NPC)
    local function one(e, inactive)
      setup({ [1] = list({ e }) }, { [1] = e }, inactive)
      return keys(R.quest_overrides(1))
    end

    check("quest ov: flag leaf is unknown, entry kept",
      one(entry(10, 101, cond(0, { flag() }, false))) == "101")
    check("quest ov: step leaf false drops the entry",
      one(entry(10, 101, cond(0, { step(false) }, false))) == "")
    check("quest ov: step leaf true keeps the entry",
      one(entry(10, 101, cond(0, { step(true) }, false))) == "101")
    check("quest ov: all with a false step and a flag drops the entry",
      one(entry(10, 101, cond(0, { flag(), step(false) }, false))) == "")
    check("quest ov: any with a true step and a flag keeps the entry",
      one(entry(10, 101, cond(1, { flag(), step(true) }, false))) == "101")
    check("quest ov: any with a false step and a flag stays unknown, kept",
      one(entry(10, 101, cond(1, { flag(), step(false) }, false))) == "101")
    check("quest ov: any with only false steps drops the entry",
      one(entry(10, 101, cond(1, { step(false), step(false) }, false))) == "")
    check("quest ov: other node kinds are unknown, entry kept",
      one(entry(10, 101, cond(0, { tod() }, false))) == "101")
    check("quest ov: nested group true keeps the entry",
      one(entry(10, 101, cond(0, { grp(1, { step(false), step(true) }), step(true) }, false)))
        == "101")
    check("quest ov: nested group false drops the entry",
      one(entry(10, 101, cond(0, { grp(1, { step(false), step(false) }), step(true) }, false)))
        == "")
    check("quest ov: empty array with the no-condition flag is kept",
      one(entry(10, 101, cond(0, {}, true))) == "101")
    check("quest ov: empty array without the flag is dropped",
      one(entry(10, 101, cond(0, {}, false))) == "")
    check("quest ov: an empty nested group is unknown, entry kept",
      one(entry(10, 101, cond(0, { grp(0, {}) }, false))) == "101")
    check("quest ov: an empty nested group under any is unknown, entry kept",
      one(entry(10, 101, cond(1, { grp(1, {}) }, false))) == "101")
    check("quest ov: no ConditionEntity is unknown, entry kept",
      one(entry(10, 101, nil)) == "101")
    check("quest ov: no ConditionEntity is still gated by the schedule",
      one(entry(10, 101, nil, { disabled = true })) == "")
    check("quest ov: no ConditionEntity is still gated by the quest",
      one(entry(10, 101, nil, { quest = 7 }), { [7] = true }) == "")
    check("quest ov: a raised leaf evaluate is unknown, entry kept",
      one(entry(10, 101, cond(0, { step("raise") }, false))) == "101")
    check("quest ov: a raised leaf with a false sibling under all still drops",
      one(entry(10, 101, cond(0, { step("raise"), step(false) }, false))) == "")
    check("quest ov: schedule disabled drops the entry",
      one(entry(10, 101, cond(0, { step(true) }, false), { disabled = true })) == "")
    check("quest ov: quest not activated drops the entry",
      one(entry(10, 101, cond(0, { step(true) }, false), { quest = 7 }), { [7] = true }) == "")
    check("quest ov: own evaluate true is kept though the walk says false",
      one(entry(10, 101, cond(0, { step(false) }, false, true))) == "101")
    check("quest ov: own evaluate true is still dropped by a disabled schedule",
      one(entry(10, 101, cond(0, { step(false) }, false, true), { disabled = true })) == "")
    check("quest ov: a raised own evaluate falls back to the walk",
      one(entry(10, 101, cond(0, { step(false) }, false, "raise"))) == "")
    check("quest ov: an entry with no rows adds none",
      one(entry(10, 101, cond(0, { step(true) }, false), { rows = {} })) == "")

    -- ordering: applied (by address), then other "now" entries, then the rest
    do
      local e1 = entry(11, 201, cond(0, { flag() }, false))
      local e2 = entry(12, 202, cond(0, { step(false) }, false, true))
      local e3 = entry(13, 203, cond(0, { flag() }, false))
      local e4 = entry(14, 204, cond(0, { flag() }, false))
      local e5 = entry(15, 205, cond(0, { step(true) }, false), { rows = {} })
      -- the applied object is another instance at the same address
      local applied = entry(13, 203, cond(0, { flag() }, false))
      setup({ [1] = list({ e1, e2, e3, e4, e5 }) }, { [1] = applied })
      check("quest ov: applied entry first, then now entries, then the rest",
        keys(R.quest_overrides(1)) == "203,202,201,204")
      local multi = entry(16, 0, cond(0, { flag() }, false),
        { rows = { qrow(1, 2, 301), qrow(2, 3, 302) } })
      setup({ [1] = list({ e1, multi }) }, { [1] = e1 })
      check("quest ov: an entry's rows keep their own order",
        keys(R.quest_overrides(1)) == "201,301,302")
    end

    -- two entries that both hold now: the applied entry's rows come first
    do
      local a = entry(21, 401, cond(0, { step(true) }, false, true))
      local b = entry(22, 402, cond(0, { step(true) }, false, true))
      setup({ [1] = list({ b, a }) }, { [1] = a })
      check("quest ov: two now entries, the applied entry's rows come first",
        keys(R.quest_overrides(1)) == "401,402")
    end

    -- an unreadable schedule adds no rows, other entries still read
    do
      local bad = entry(31, 501, cond(0, { step(true) }, false), { badsched = true })
      local good = entry(32, 502, cond(0, { step(true) }, false))
      setup({ [1] = list({ bad, good }) }, { [1] = good })
      check("quest ov: an unreadable schedule adds no rows, other entries still read",
        keys(R.quest_overrides(1)) == "502")
    end
    -- a per-NPC list that is not an array gives {}
    do
      local good = entry(41, 601, cond(0, { step(true) }, false))
      setup({ [1] = obj() }, { [1] = good })
      local r = R.quest_overrides(1)
      check("quest ov: an unreadable per-NPC list gives {}", type(r) == "table" and #r == 0)
    end

    do
      local good = entry(51, 701, cond(0, { step(true) }, false))
      setup({ [1] = list({}) }, { [1] = good })
      local r = R.quest_overrides(1)
      check("quest ov: no entries gives {}", type(r) == "table" and #r == 0)
      setup({}, { [1] = good })
      r = R.quest_overrides(1)
      check("quest ov: a cid with no entry list gives {}", type(r) == "table" and #r == 0)
      setup({ [1] = list({ good }) }, {})
      r = R.quest_overrides(1)
      check("quest ov: no applied entry gives {}", type(r) == "table" and #r == 0)
      singletons["app.QuestManager"] = obj({ NpcOverrideDict = qdict({ [1] = list({ good }) }) },
        { checkActivated = function() return true end })
      r = R.quest_overrides(1)
      check("quest ov: unreadable CurrentNpcOverrideDict gives {}",
        type(r) == "table" and #r == 0)
      singletons["app.QuestManager"] = nil
      check("quest ov: unreadable QuestManager gives nil", R.quest_overrides(1) == nil)
      singletons["app.QuestManager"] = obj({ CurrentNpcOverrideDict = qdict({}) })
      check("quest ov: unreadable NpcOverrideDict gives nil", R.quest_overrides(1) == nil)
    end
    singletons["app.QuestManager"] = nil
  end
  do
    local old_find = sdk.find_type_definition
    local made, released, ended, result = {}, 0, { [11040] = false }, true
    local fail_condition_set = false
    local function managed(fields, methods)
      local o = obj(fields, methods)
      function o:add_ref() made[#made + 1] = self; return self end
      function o:set_field(k, v)
        if k == "_Condition" and fail_condition_set then
          fail_condition_set = false
          error("injected condition assignment failure")
        end
        fields[k] = v
      end
      function o:release() released = released + 1 end
      return o
    end
    sdk.find_type_definition = function(n)
      if n == "app.QuestLogManager" then
        return { get_method = function(_, signature)
          if signature ~= "isQuestLogEnd(app.QuestDefine.ID)" then error("bad signature") end
          return { call = function(_, qlm, qid) return ended[qid] end }
        end }
      elseif n == "app.QuestVariableCondition" then
        return { create_instance = function()
          return managed({}, {})
        end }
      elseif n == "app.GenerateManager.QuestFlagInfos.QuestVariableInfo" then
        return { create_instance = function()
          return managed({}, { evaluate = function() return result end })
        end }
      end
      return old_find(n)
    end
    singletons["app.GameSystem"] = obj({ ["<GameSeason4>k__BackingField"] = false },
      { get_GameSeason4 = function() return true end })
    singletons["app.QuestManager"] = obj(nil, { checkActivated = function(qid) return qid == 11040 end })
    singletons["app.QuestLogManager"] = obj({})
    local RR = world.game_reads()
    check("conditional reads: GameSeason4 method", RR.game_season4() == true)
    singletons["app.GameSystem"] = obj({ ["<GameSeason4>k__BackingField"] = false },
      { get_GameSeason4 = function() error("method unavailable") end })
    check("conditional reads: GameSeason4 backing-field fallback", RR.game_season4() == false)
    local q = RR.quest_state(11040)
    check("conditional reads: quest activation and end", q.active == true and q.ended == false)
    local c = { qid = 51010, name_hash = 110914987, value_type = 1,
      compare_type = 0, bool_value = true, int_value = 0 }
    check("conditional reads: evaluator uses retained game objects", RR.quest_variable(c) == true
      and #made == 2)
    result = false
    check("conditional reads: evaluator result comes from the game", RR.quest_variable(c) == false)
    local c2 = { qid = 51010, name_hash = 479827071, value_type = 1,
      compare_type = 0, bool_value = false, int_value = 0 }
    fail_condition_set, result = true, true
    local failed = pcall(RR.quest_variable, c2)
    check("conditional reads: failed construction releases partial refs", not failed
      and released == 2 and #made == 4)
    check("conditional reads: failed construction can retry", RR.quest_variable(c2) == true
      and #made == 6)
    RR.reset()
    check("conditional reads: reset releases and drops retained objects", released == 6
      and RR.quest_variable(c) == true and #made == 8)
    sdk.find_type_definition = old_find
    singletons["app.GameSystem"], singletons["app.QuestManager"],
      singletons["app.QuestLogManager"] = nil, nil, nil
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
  local probe_file = assert(io.open("tools/probe/conditional_monster_rows.lua", "rb"))
  local probe_source = probe_file:read("*a"); probe_file:close()
  local probe_poke = probe_source:find('wt.q("poke"', 1, true)
  local probe_refresh = probe_source:find('wt.q("refresh"', 1, true)
  check("probe: poke clears the refresh throttle", probe_poke ~= nil and probe_refresh ~= nil
    and probe_poke < probe_refresh)
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
  function stub.in_hours(h, lo, hi)
    if lo < hi then return h >= lo and h < hi end
    return h >= lo or h < hi
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
    return stops, unplaced, stub.matched
  end
  stub.matched = true
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
    rdef("current_sig", function(cid)
      local e = d.cur[cid]
      if e == nil then return nil end
      return e.area, e.location, e.key or -1, d.sig or ""
    end)
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

  do
    local f, d = nfix()
    d.rows[2001] = { { start_hour = 0, end_hour = 24, area = 49, location = 1 } }
    d.area_nodes[49] = { P(40, 0, 40) }
    local member = { route_id = 2001, cid = 2001, place = 2001, qid = 30040,
      kind = "npc", direct = false, target_key = core.target_key({ 30040, "issued_npc", 2001 }),
      ordinal = 1, pos = P(40, 0, 40), item_ids = {}, objective_generation = 3 }
    local w = f.new()
    w:set_routes({ objective_generation = 3, members = { member } })
    f.fail.schedule_now = true
    w:refresh(0, true, on("search"))
    local failed = route_in(w, 2001)
    check("objective NPC route: metadata survives schedule-read error rendering",
      failed ~= nil and failed.err ~= nil and failed.objective_generation == 3
        and failed.target_key == member.target_key and failed.ordinal == member.ordinal)
    f.fail.schedule_now = nil
    w:poke()
    w:refresh(1, true, on("search"))
    local scheduled = route_in(w, 2001)
    check("objective NPC route: metadata survives successful schedule rendering",
      scheduled ~= nil and scheduled.err == nil and scheduled.objective_generation == 3
        and scheduled.target_key == member.target_key and scheduled.ordinal == member.ordinal)
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
    -- keyed by cid and 200 m cell: a move to the discovered town re-asks
    d.npcpos[2001] = P(990, 0, 990)
    w:poke()
    w:refresh(1, true, { search = true, npc_cids = { 2001, 2002 } })
    by = {}
    for _, e in ipairs(w:input().npcs) do by[e.cid] = e end
    check("npc pos: move to another cell re-asks discovered", by[2001].discovered == true)
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
    d.rows[2002] = rows_of({ 6, 18, 49 })
    d.cur[2002] = { area = 49, location = 0 }
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
    check("route: none until set", route_in(w) == nil)
    w:set_route(2001, "Aa")
    check("route: set_route then refresh builds on that call",
      w:refresh(1, true, tg) == true)
    local r = route_in(w)
    check("route: cid and name", r ~= nil and r.cid == 2001 and r.name == "Aa")
    check("routes: a list with one member", type(w:input().routes) == "table"
      and #w:input().routes == 1 and w:input().routes[1].cid == 2001
      and w:input().routes[1].name == "Aa")
    check("routes: no input.route", w:input().route == nil)
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
      and route_in(w) and #route_in(w).stops == 2)
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
    check("route: clear_route drops the published route", route_in(w) == nil)
    check("routes: cleared list is nil", w:input().routes == nil)
    w:poke()
    w:refresh(5, true, tg)
    check("route: stays cleared", route_in(w) == nil)
    -- set again, then reset clears it
    w:set_route(2001, "Aa")
    w:refresh(6, true, tg)
    check("route: set again builds", route_in(w) ~= nil)
    w:set_route(2002, "Bb")
    check("routes: set_route removes the old target at once", route_in(w, 2001) == nil)
    w:refresh(6.5, true, tg)
    check("routes: set_route to another cid replaces the target",
      type(w:input().routes) == "table" and #w:input().routes == 1
      and w:input().routes[1].cid == 2002)
    w:reset()
    w:refresh(7, true, tg)
    check("route: reset clears the route", route_in(w) == nil)
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
    local r = route_in(w)
    check("route err: raising schedule_rows", r ~= nil and r.err == "route unavailable"
      and r.cid == 2001 and r.name == "Aa" and r.stops == nil)
    f.fail.schedule_rows = nil
    w:poke()
    w:refresh(0.5, true, tg)
    check("route err: a failed build is retried the next round, same hour",
      route_in(w).err == nil and #route_in(w).stops == 1)
    d.hour = 9
    w:set_route(2001, "Aa")
    w:refresh(1, true, tg)
    check("route err: recovers when the read works", route_in(w).err == nil
      and #route_in(w).stops == 1)
    -- -1/-1 current row
    local calls = stub.calls.route_stops
    d.cur[2001] = { area = -1, location = -1, key = 2309, pos = P(1, 1, 1) }
    stub.matched = false
    d.hour = 10
    w:set_route(2001, "Aa")
    w:refresh(2, true, tg)
    r = route_in(w)
    check("route off: unmatched key publishes stops + off_schedule",
      r.err == nil and #r.stops == 1 and r.off_schedule == true)
    check("route off: route_stops called with the current row",
      stub.calls.route_stops == calls + 1 and stub.last_cur.key == 2309)
    stub.matched = true
    d.cur[2001] = { area = 49, location = 0 }
    d.hour = 12
    w:poke()
    w:refresh(2.4, true, tg)
    check("route off: off_schedule clears on an hour-change rebuild alone",
      route_in(w).err == nil and route_in(w).off_schedule == nil)
    w:set_route(2001, "Aa")
    w:refresh(2.5, true, tg)
    check("route off: a matched current row has no off_schedule",
      route_in(w).err == nil and route_in(w).off_schedule == nil)
    d.area_nodes[49] = nil
    d.hour = 14
    w:set_route(2001, "Aa")
    w:refresh(2.55, true, tg)
    check("route off: a matched route with zero placed stops is route unavailable",
      route_in(w).err == "route unavailable" and route_in(w).stops == nil)
    d.cur[2001] = { area = -1, location = -1, pos = P(1, 1, 1) }
    d.hour = 13
    w:set_route(2001, "Aa")
    w:refresh(2.6, true, tg)
    r = route_in(w)
    check("route off: -1/-1 with nothing placeable is route unavailable",
      r.err == "route unavailable" and r.stops == nil)
    d.area_nodes[49] = { P(1, 0, 1) }
    -- a nil entry: no current row passed, no off_schedule
    d.cur[2001] = nil
    stub.last_cur = "unset"
    d.hour = 15
    w:set_route(2001, "Aa")
    w:refresh(2.62, true, tg)
    check("route off: nil entry passes nil and has no off_schedule",
      stub.last_cur == nil and route_in(w).err == nil
      and route_in(w).off_schedule == nil)
    -- an overwrite change inside the same hour rebuilds; a failed sig errs
    d.cur[2001] = { area = 49, location = 0 }
    d.sig = "a"
    d.hour = 16
    w:set_route(2001, "Aa")
    w:refresh(2.64, true, tg)
    local before = stub.calls.route_stops
    w:refresh(2.65, true, tg)
    check("route sig: unchanged signature reuses the cache", stub.calls.route_stops == before)
    d.sig = "a,b"
    w:poke()
    w:refresh(2.66, true, tg)
    check("route sig: a changed signature in the same hour rebuilds",
      stub.calls.route_stops == before + 1 and route_in(w).err == nil)
    f.fail.current_sig = true
    w:poke()
    w:refresh(2.67, true, tg)
    check("route sig: a failed signature read shows route unavailable",
      route_in(w).err == "route unavailable")
    f.fail.current_sig = nil
    d.sig = nil
    w:poke()
    w:refresh(2.68, true, tg)
    check("route sig: recovers when the read works", route_in(w).err == nil)
    -- raising route_stops leaves no partial stops
    d.cur[2001] = { area = 49, location = 0 }
    local orig = stub.route_stops
    stub.route_stops = function() error("boom") end
    d.hour = 11
    w:set_route(2001, "Aa")
    w:refresh(3, true, tg)
    stub.route_stops = orig
    r = route_in(w)
    check("route err: raising route_stops gives err, no stops",
      r.err == "route unavailable" and r.stops == nil and r.unplaced == nil)
    -- schedule_now failure
    f.fail.schedule_now = true
    w:set_route(2001, "Aa")
    w:refresh(4, true, tg)
    check("route err: schedule_now failure", route_in(w).err == "route unavailable")
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
    local r = route_in(w)
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
    local r = route_in(w)
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
    check("reset all: precondition", #w:input().npcs == 1 and route_in(w) ~= nil
      and #w.spawned == 1)
    w:reset()
    w:refresh(1, true, on("search"))
    check("reset all: route gone", route_in(w) == nil)
    check("reset all: spawned gone", #w.spawned == 0)
  end

  -- set_routes: members from the focus list (plan Task 2.2)
  do
    local function sfix()
      local f, d = nfix()
      d.bad = {}
      for c = 2001, 2009 do
        d.rows[c] = rows_of({ 6, 18, 49 })
        d.cur[c] = { area = 49, location = 0 }
      end
      d.area_nodes[49] = { P(1, 0, 1) }
      d.keypos = {}
      f.reads.key_pos = function(k)
        d.key_reads = (d.key_reads or 0) + 1
        return d.keypos[k]
      end
      f.reads.schedule_rows = function(cid)
        f.reads_n.schedule_rows = (f.reads_n.schedule_rows or 0) + 1
        if d.bad[cid] then error("fake bad cid") end
        return d.rows[cid]
      end
      return f, d
    end
    local L3 = { { cid = 2001, name = "Aa" }, { cid = 2002, name = "Bb" }, { cid = 2003, name = "Cc" } }
    local D4 = { cid = 2004, name = "Dd" }
    local tg = on("search")
    local function cids(w)
      local t = {}
      for i, e in ipairs((w:input() or {}).routes or {}) do t[i] = e.cid end
      return table.concat(t, ",")
    end
    local function settle(w, now)
      local n = 0
      repeat n = n + 1 until not w:refresh(now, true, tg) or n > 20
      return n
    end
    local f, d = sfix()
    local w = f.new()
    check("set_routes: exists", type(w.set_routes) == "function")
    if type(w.set_routes) == "function" then
      -- 1-4 at now 0
      w:set_routes(L3)
      local r1 = w:refresh(0, true, tg)
      check("set_routes: one build per round", r1 == true and stub.calls.route_stops == 1
        and cids(w) == "2001" and w:stats().route_builds == 1)
      local r2 = w:refresh(0, true, tg)
      local r3 = w:refresh(0, true, tg)
      check("set_routes: run-again builds the rest", r2 == true and r3 == true
        and stub.calls.route_stops == 3 and cids(w) == "2001,2002,2003"
        and w:refresh(0, true, tg) == false)
      local n0 = f.reads_n.current_sig
      local sig0 = f.reads.current_sig
      f.reads.current_sig = function(...) f.clock_t = f.clock_t + 0.001; return sig0(...) end
      w:poke()
      w:refresh(0, true, tg)
      w:poke()
      w:refresh(0, true, tg)
      f.reads.current_sig = sig0
      check("set_routes: every member's sig read each round",
        f.reads_n.current_sig == n0 + 6 and stub.calls.route_stops == 3)
      check("set_routes: route_sig adds every member's read",
        math.abs((w:stats().ms.route_sig or 0) - 3) < 1e-6)
      d.hour = 8
      w:poke()
      w:refresh(0, true, tg)
      check("set_routes: hour change rebuilds one per round", stub.calls.route_stops == 4
        and #w:input().routes == 3 and w:stats().route_builds == 4)
      check("set_routes: the stale rest run again", w:refresh(0, true, tg) == true
        and w:refresh(0, true, tg) == true and w:refresh(0, true, tg) == false
        and stub.calls.route_stops == 6)
      -- 5-9 at now 1
      local g = w.route_gen
      w:set_routes(L3)
      check("set_routes: idempotent", w.route_gen == g and w:refresh(1, true, tg) == false)
      -- a repeated identical call allocates nothing (early return)
      collectgarbage("collect")
      collectgarbage("stop")
      local mem0 = collectgarbage("count")
      for _ = 1, 500 do w:set_routes(L3) end
      local grew = collectgarbage("count") - mem0
      collectgarbage("restart")
      check("set_routes: a repeated identical call allocates nothing", grew < 1 and w.route_gen == g)
      -- the early return compares name and cid, not only the length
      w:set_routes({ { cid = 2001, name = "X" }, L3[2], L3[3] })
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: a changed name behind an equal length is published",
        route_in(w, 2001).name == "X")
      w:set_routes({ L3[1], L3[2], { cid = 2004, name = "Cc" } })
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: a changed cid behind an equal length is published",
        cids(w) == "2001,2002,2004" and route_in(w, 2003) == nil)
      w:set_routes(L3)
      w:poke()
      settle(w, 1)
      check("set_routes: the original list is published again",
        route_in(w, 2001).name == "Aa" and cids(w) == "2001,2002,2003")
      g = w.route_gen
      local b = stub.calls.route_stops
      w:set_routes({ L3[1], L3[2], L3[3], D4 })
      check("set_routes: an added member builds alone", w.route_gen == g + 1
        and w:refresh(1, true, tg) == true and stub.calls.route_stops == b + 1
        and cids(w) == "2001,2002,2003,2004")
      g = w.route_gen
      w:set_routes({ L3[1], L3[3], D4 })
      check("set_routes: a removed member leaves at once", w.route_gen == g + 1
        and route_in(w, 2002) == nil and cids(w) == "2001,2003,2004")
      check("set_routes: a removal pokes", w:refresh(1, true, tg) == true)
      g, b = w.route_gen, stub.calls.route_stops
      w:set_routes({ D4, L3[3], { cid = 2001, name = "Ax" } })
      local r8 = w:refresh(1, true, tg)
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: name or order change neither pokes nor bumps", w.route_gen == g
        and r8 == false and cids(w) == "2004,2003,2001" and route_in(w, 2001).name == "Ax"
        and stub.calls.route_stops == b)
      w:set_routes({ { cid = 2001 }, { cid = 2001, name = "Aa" }, { cid = 2003, name = "Cc" } })
      settle(w, 1)
      check("set_routes: duplicate legacy cids are deduplicated", cids(w) == "2001,2003")
      w:set_routes({ { cid = 2001, name = "Aa" }, { cid = "x", name = "Bad" } })
      check("set_routes: malformed legacy member rejects the whole publication", cids(w) == "")
    end

    -- 10: a failing member does not block the rest; failed members retry in turn
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      d.bad[2001] = true
      w:set_routes(L3)
      local n = settle(w, 0)
      check("set_routes: a failing member does not block the rest", n == 4
        and route_in(w, 2001).err == "route unavailable"
        and route_in(w, 2002).stops ~= nil and route_in(w, 2003).stops ~= nil)
      local b, nb = stub.calls.route_stops, w:stats().route_builds
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: a failed member is retried once a round",
        route_in(w, 2001).err == "route unavailable" and stub.calls.route_stops == b
        and w:stats().route_builds == nb + 1 and w:refresh(1, true, tg) == false)
      d.bad[2001] = nil
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: a failed member recovers", route_in(w, 2001).err == nil)
    end
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      d.bad[2001], d.bad[2002] = true, true
      w:set_routes(L3)
      settle(w, 0)
      d.bad[2002] = nil
      w:poke()
      w:refresh(1, true, tg)
      local first = route_in(w, 2002).err
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: failed members are retried in turn",
        first == "route unavailable" and route_in(w, 2002).err == nil
        and route_in(w, 2001).err == "route unavailable")
    end

    -- 11: the search target lives apart from the members (Contract 4)
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_route(2001, "Aa")
      w:set_routes({ L3[2], L3[3] })
      settle(w, 0)
      check("set_routes: target first, then the members", cids(w) == "2001,2002,2003")
      local g = w.route_gen
      w:set_routes({ L3[2], L3[3] })
      check("set_routes: the per-tick call keeps the target", cids(w) == "2001,2002,2003"
        and w.route_gen == g and w:refresh(1, true, tg) == false)
      w:clear_route()
      check("set_routes: clear_route drops only the target", cids(w) == "2002,2003")
      w:set_route(2002, "Bb")
      w:refresh(1, true, tg)
      check("set_routes: a target that is a member is published once, first",
        cids(w) == "2002,2003")
      -- the focus list drops the cid that is still the target: no poke, no bump
      settle(w, 2)
      local gd = w.route_gen
      w:set_routes({ L3[3] })
      check("set_routes: dropping the target's cid is not a removal", w.route_gen == gd
        and cids(w) == "2002,2003" and w:refresh(3, true, tg) == false)
      -- the per-tick list carries the target's cid, then the target is cleared
      w:set_routes({ L3[2], L3[3] })
      settle(w, 4)
      local b0 = w:stats().route_builds
      w:set_routes({ L3[2], L3[3] })
      w:clear_route()
      w:poke()
      w:refresh(5, true, tg)
      check("set_routes: a per-tick list with the target's cid keeps it after clear_route",
        cids(w) == "2002,2003" and w:stats().route_builds == b0)
      -- 12: reset empties target and members; the next set_routes brings them back
      w:reset()
      w:refresh(5, true, tg)
      local empty = w:input().routes == nil
      w:set_routes(L3)
      settle(w, 6)
      check("set_routes: reset empties the members", empty and cids(w) == "2001,2002,2003")
    end
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes({ L3[2], L3[1] })
      w:set_route(2001, "Aa")
      settle(w, 0)
      check("set_routes: a member that becomes the target moves first", cids(w) == "2001,2002")
      local b = stub.calls.route_stops
      w:clear_route()
      check("set_routes: clear_route keeps a member with the target's cid",
        route_in(w, 2001) ~= nil and #w:input().routes == 2)
      w:poke()
      w:refresh(1, true, tg)
      check("set_routes: that member keeps its cache, at its member place",
        cids(w) == "2002,2001" and stub.calls.route_stops == b)
    end

    -- listing the current target's cid as a new member does not poke or bump
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_route(2002, "Bb")
      settle(w, 0)
      local ga = w.route_gen
      w:set_routes({ L3[2] })
      check("set_routes: the target's cid listed as a member is not an add",
        w.route_gen == ga and w:refresh(1, true, tg) == false)
    end

    -- 13: members alone run a round
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(L3)
      check("set_routes: members alone run a round", w:refresh(0, true, {}) == true
        and w:input().routes ~= nil)
    end

    -- 14: eight members and an hour change: one build per round (SPEC 32.7.2.2)
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      local L8 = {}
      for c = 2001, 2008 do L8[#L8 + 1] = { cid = c, name = "N" .. c } end
      w:set_routes(L8)
      settle(w, 0)
      local b0 = w:stats().route_builds
      d.hour = 8
      w:poke()
      local rounds, one_each = 0, true
      while true do
        local b = w:stats().route_builds
        if not w:refresh(0, true, tg) then break end
        rounds = rounds + 1
        if w:stats().route_builds ~= b + 1 or #w:input().routes ~= 8 then one_each = false end
        if rounds > 20 then break end
      end
      check("set_routes: eight members, one rebuild per round", b0 == 8 and rounds == 8
        and one_each and w:stats().route_builds == 16)
    end

    -- route colour slots and the current stop (SPEC 32.14)
    local function slots(w)
      local t = {}
      for i, e in ipairs((w:input() or {}).routes or {}) do t[i] = e.cid .. "=" .. tostring(e.slot) end
      return table.concat(t, ",")
    end
    local function mem(...)
      local t = {}
      for _, c in ipairs({ ... }) do t[#t + 1] = { cid = c, name = "N" .. c } end
      return t
    end

    -- 1: slots are sticky
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(mem(2001, 2002, 2003))
      settle(w, 0)
      check("slots sticky: first three take 1,2,3", slots(w) == "2001=1,2002=2,2003=3")
      w:set_routes(mem(2001, 2003))
      settle(w, 0)
      check("slots sticky: a removal keeps the others", slots(w) == "2001=1,2003=3")
      w:set_routes(mem(2001, 2003, 2004))
      settle(w, 0)
      check("slots sticky: a newcomer takes the lowest free slot",
        slots(w) == "2001=1,2003=3,2004=2")
    end

    -- 2: the search target takes the lowest free slot, and frees it
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(mem(2001, 2002))
      settle(w, 0)
      w:set_route(2005, "Ee")
      settle(w, 0)
      check("target slot: the target takes the lowest free slot though listed first",
        slots(w) == "2005=3,2001=1,2002=2")
      w:clear_route()
      w:set_routes(mem(2001, 2002, 2003))
      settle(w, 0)
      check("target slot: clear_route frees it for the next member",
        slots(w) == "2001=1,2002=2,2003=3")
    end

    -- 3: error entries carry their slots
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(mem(2001, 2002))
      settle(w, 0)
      d.bad[2001] = true
      w:poke()
      d.hour = 8
      settle(w, 1)
      check("slot on error: a failed build keeps the slot",
        route_in(w, 2001).err ~= nil and slots(w) == "2001=1,2002=2")
      d.bad[2001] = nil
      d.hour = 7
      settle(w, 2)
      f.fail.current_sig = true
      w:poke()
      settle(w, 3)
      check("slot on error: a bad signature read keeps the slots",
        route_in(w, 2001).err ~= nil and route_in(w, 2002).err ~= nil
        and slots(w) == "2001=1,2002=2")
      f.fail.current_sig = nil
      settle(w, 4)
      f.fail.schedule_now = true
      w:poke()
      settle(w, 5)
      check("slot on error: a schedule_now failure keeps the slots",
        route_in(w, 2001).err ~= nil and slots(w) == "2001=1,2002=2")
      f.fail.schedule_now = nil
      local w2 = f.new()
      w2:set_routes(mem(2001, 2002))
      f.fail.schedule_now = true
      settle(w2, 0)
      check("slot on error: a schedule_now failure from the start still assigns",
        slots(w2) == "2001=1,2002=2")
      f.fail.schedule_now = nil
    end

    -- 4: past eight
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(mem(2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008))
      settle(w, 0)
      w:set_route(2009, "Ii")
      w:refresh(1, true, tg)
      check("slots past eight: the ninth has none, the eight keep theirs",
        #w:input().routes == 9 and route_in(w, 2009).slot == nil
        and slots(w) == "2009=nil,2001=1,2002=2,2003=3,2004=4,2005=5,2006=6,2007=7,2008=8")
    end

    -- 5: the current stop
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      d.rows[2001] = rows_of({ 0, 8, 49 }, { 8, 18, 49 }, { 18, 24, 49 })
      d.rows[2002] = rows_of({ 0, 8, 49 }, { 18, 24, 49 })
      w:set_routes(mem(2001, 2002))
      d.hour = 10
      settle(w, 0)
      check("current: hour 10 is the second stop", route_in(w, 2001).current == 2)
      check("current: no stop at the hour is nil", route_in(w, 2002).current == nil
        and route_in(w, 2002).stops ~= nil and route_in(w, 2002).err == nil)
      d.hour = 23
      w:poke()
      settle(w, 1)
      check("current: hour 23 is the third stop", route_in(w, 2001).current == 3
        and route_in(w, 2002).current == 2)
    end

    -- 6: reset clears the slots
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes(mem(2001, 2002))
      settle(w, 0)
      w:reset()
      w:set_routes(mem(2002, 2001))
      settle(w, 1)
      check("slots: reset starts again from 1", slots(w) == "2002=1,2001=2")
    end

    -- place routes (SPEC 32.14.5)
    local function ptg(player, keys)
      local t = on("search")
      t.player, t.focus_keys = player, keys
      return t
    end
    local PL = { { cid = 2001, name = "A" }, { cid = -77, place = 77, name = "Q" } }

    -- 1: a place member
    f, d = sfix()
    w = f.new()
    d.keypos[77] = P(200, 0, 200)
    if type(w.set_routes) == "function" then
      w:set_routes(PL)
      local t1 = ptg({ x = 5, y = 1, z = 5 }, { 77 })
      local n = 0
      repeat n = n + 1 until not w:refresh(0, true, t1) or n > 20
      local pe = route_in(w, -77)
      check("place member: after the NPC, with the place and two stops",
        cids(w) == "2001,-77" and pe ~= nil and pe.place == 77 and pe.name == "Q"
        and pe.stops ~= nil and #pe.stops == 2)
      check("place member: stops are the player and the place, both discovered",
        pe ~= nil and pe.stops ~= nil and pe.stops[1].pos.x == 5 and pe.stops[1].pos.y == 1
        and pe.stops[2].pos.x == 200 and pe.stops[2].pos.z == 200
        and pe.stops[1].discovered == true and pe.stops[2].discovered == true)
      check("place member: a slot and no current", pe ~= nil and pe.slot == 2
        and pe.current == nil and pe.err == nil)
    end

    -- 1b: a direct-position objective member shares the place publication path.
    do
      local f, d = sfix()
      local w = f.new()
      local function publication(members, generation)
        return { objective_generation = generation or 1, members = members }
      end
      local function direct_member(kind, name, pos, ordinal, generation)
        local key = kind == "item" and core.target_key({ "source", "seller:test" })
          or core.target_key({ 30040, "task", 0, ordinal or 1, "place" })
        return { route_id = core.objective_direct_route_id(ordinal or 1), place = 0,
          direct = true, qid = 30040, kind = kind == "item" and "source" or "place",
          target_key = key, ordinal = ordinal or 1, name = name, pos = pos,
          item_ids = {}, objective_generation = generation or 1 }
      end
      local function objective_npc(cid, name, pos)
        return { route_id = cid, cid = cid, place = cid, qid = 30040, kind = "npc",
          direct = false, target_key = core.target_key({ 30040, "issued_npc", cid }),
          ordinal = cid, name = name, pos = pos, item_ids = {}, objective_generation = 1 }
      end
      local direct = direct_member("place", "Objective: Hall", P(410.5, 73.5, -821.2))
      local tg = ptg(P(5, 1, 5), nil)
      local original = P(direct.pos.x, direct.pos.y, direct.pos.z)
      local route_id_calls, old_route_id = 0, core.objective_direct_route_id
      core.objective_direct_route_id = function(ordinal)
        route_id_calls = route_id_calls + 1
        return old_route_id(ordinal)
      end
      w:set_routes(publication({ direct }))
      core.objective_direct_route_id = old_route_id
      check("direct route: validation uses the shared objective route id helper",
        route_id_calls >= 1)
      local gen = w.route_gen
      w:set_routes(publication({ direct_member("place", "Objective: Hall", P(410.5, 73.5, -821.2)) }))
      check("direct route: unchanged position is idempotent", w.route_gen == gen)
      direct.pos.x = 999
      w:refresh(0, true, tg)
      local direct_id = core.objective_direct_route_id(1)
      local e = route_in(w, direct_id)
      check("direct route: publishes two stops from player to copied target",
        e ~= nil and e.place == 0 and #e.stops == 2
        and e.stops[1].pos.x == 5 and e.stops[1].pos.y == 1 and e.stops[1].pos.z == 5
        and e.stops[2].pos.x == 410.5 and e.stops[2].pos.y == 73.5
        and e.stops[2].pos.z == -821.2)
      check("direct route: retains objective metadata and has no route-stop endpoint",
        e ~= nil and e.direct == true and e.objective == true and e.qid == 30040
        and e.kind == "place" and e.name == "Objective: Hall"
        and e.pos.x == 410.5 and e.pos.y == 73.5 and e.pos.z == -821.2
        and e.route_stop == nil and e.stops[1].route_stop == nil
        and e.stops[2].route_stop == nil)
      check("direct route: bypasses NPC schedule and key reads",
        (f.reads_n.schedule_now or 0) == 0 and (f.reads_n.current_sig or 0) == 0
        and (f.reads_n.schedule_rows or 0) == 0
        and d.key_reads == nil and stub.calls.route_stops == 0)

      local target_state = { x = 410.5, y = 73.5, z = -821.2,
        kind = "place", name = "Objective: Hall" }
      local function replace(fields)
        for key, value in pairs(fields) do target_state[key] = value end
        local m = direct_member(target_state.kind, target_state.name,
          P(target_state.x, target_state.y, target_state.z))
        w:set_routes(publication({ m }))
        local changed = w:refresh(1, true, tg) == true
        local got = route_in(w, direct_id)
        return changed, got
      end
      local changed, got = replace({ x = 411.5 })
      check("direct route: x change pokes and replaces published stop",
        changed and got ~= nil and got.stops[2].pos.x == 411.5)
      changed, got = replace({ y = 74.5 })
      check("direct route: y change pokes and replaces published stop",
        changed and got ~= nil and got.stops[2].pos.y == 74.5)
      changed, got = replace({ z = -820.2 })
      check("direct route: z change pokes and replaces published stop",
        changed and got ~= nil and got.stops[2].pos.z == -820.2)
      changed, got = replace({ kind = "item" })
      check("direct route: kind change pokes and replaces published metadata",
        changed and got ~= nil and got.kind == "item")
      changed, got = replace({ name = "Objective: New Hall" })
      check("direct route: name change pokes and replaces published metadata",
        changed and got ~= nil and got.name == "Objective: New Hall")

      -- Pending NPC routes retain their slots before a direct objective takes one.
      do
        local n2, d2 = nfix()
        for cid = 2001, 2004 do
          d2.rows[cid] = rows_of({ 6, 18, 49 })
          d2.cur[cid] = { area = 49, location = 0 }
        end
        d2.area_nodes[49] = { P(1, 0, 1) }
        local w2 = n2.new()
        w2:set_routes(publication({ objective_npc(2001, "Aa", P(1, 0, 1)),
          objective_npc(2002, "Bb", P(2, 0, 2)), direct_member("place", "Objective: Hall", original) }))
        local tg2 = ptg(P(5, 1, 5), nil)
        for tick = 0, 5 do
          w2:refresh(tick, true, tg2)
        end
        local direct_id = core.objective_direct_route_id(1)
        local a, b, de = route_in(w2, 2001), route_in(w2, 2002), route_in(w2, direct_id)
        check("direct route: pending NPC readiness keeps objective in slot three",
          a ~= nil and b ~= nil and de ~= nil and a.slot == 1 and b.slot == 2 and de.slot == 3)
        w2:set_routes(publication({ objective_npc(2003, "Cc", P(3, 0, 3)),
          objective_npc(2004, "Dd", P(4, 0, 4)), direct_member("place", "Objective: Hall", original) }))
        w2:refresh(10, true, tg2)
        de = route_in(w2, direct_id)
        check("direct route: an assigned objective slot survives pending NPCs",
          de ~= nil and de.slot == 3)
      end

      local place = { cid = -77, place = 77, name = "Legacy place" }
      w:set_routes({ place })
      w:set_routes(publication({ direct_member("place", "Objective: Hall", original, 2, 2) }, 2))
      local tboth = ptg(P(5, 1, 5), { 77 })
      d.keypos[77] = P(200, 0, 200)
      w:refresh(2, true, tboth)
      local legacy, objective = route_in(w, -77), route_in(w, core.objective_direct_route_id(2))
      check("direct route: canonical ordinal id is disjoint from legacy place ids",
        legacy == nil and objective ~= nil and objective.place == 0
        and objective.direct == true and objective.cid ~= -77)

      local direct2 = core.objective_direct_route_id(2)
      w.path_job = { cid = direct2 }
      w.rps[direct2] = true
      w:set_routes({ place })
      check("direct route: leaving clears its slot, path job and path cache",
        w.path_job == nil and w.rps[direct2] == nil and route_in(w, direct2) == nil)
      w.near["5.0,1.0,5.0"] = 8
      w:set_routes(publication({ direct_member("place", "Objective: Hall", original) }))
      w:refresh(3, true, ptg(P(6, 1, 6), nil))
      check("direct route: leaving clears its place_from origin",
        w.near["5.0,1.0,5.0"] == 8)

      w:set_route(2001, "Aa")
      w:set_routes(publication({ direct_member("place", "Objective: Hall", original) }))
      local n = 0
      repeat n = n + 1 until not w:refresh(4, true, tg) or n > 20
      local routes = (w:input() or {}).routes or {}
      check("direct route: search target reservation and dedupe stay unchanged",
        #routes == 2 and routes[1].cid == 2001
        and route_in(w, core.objective_direct_route_id(1)) ~= nil)
    end

    -- 1c: direct routes require both a valid player and a valid copied target.
    do
      local f, d = sfix()
      local w = f.new()
      local direct = { route_id = core.objective_direct_route_id(1), place = 0,
        direct = true, qid = 30040, kind = "place", name = "Objective: Hall",
        target_key = core.target_key({ 30040, "task", 0, 1, "place" }), ordinal = 1,
        item_ids = {}, objective_generation = 1, pos = P(410.5, 73.5, -821.2) }
      local publication = function() return { objective_generation = 1, members = { direct } } end
      w:set_routes(publication())
      w:refresh(0, true, ptg(nil, nil))
      check("direct route: missing player publishes nothing", route_in(w, direct.route_id) == nil)
      w:poke()
      w:refresh(1, true, ptg(P(5, 1, 5), nil))
      check("direct route: valid member publishes after player appears",
        route_in(w, direct.route_id) ~= nil)
      direct.pos = { x = "invalid", y = 0, z = 0 }
      w:set_routes(publication())
      w:poke()
      w:refresh(2, true, ptg(P(5, 1, 5), nil))
      check("direct route: invalid target publishes nothing", route_in(w, direct.route_id) == nil)
    end

    -- 2: no build, no signature read, no schedule_now failure
    f, d = sfix()
    w = f.new()
    d.keypos[77] = P(10, 0, 10)
    if type(w.set_routes) == "function" then
      w:set_routes({ { cid = -77, place = 77, name = "Q" } })
      local t1 = ptg({ x = 5, y = 1, z = 5 }, { 77 })
      w:refresh(0, true, t1)
      check("place no build: only the place leaves no build and no signature read",
        route_in(w, -77) ~= nil and w:stats().route_builds == 0
        and (f.reads_n.current_sig or 0) == 0 and stub.calls.route_stops == 0)
      w:set_routes(PL)
      f.fail.schedule_now = true
      w:poke()
      w:refresh(1, true, t1)
      check("place no build: schedule_now failing errs the NPC, not the place",
        route_in(w, 2001).err ~= nil and route_in(w, -77).err == nil
        and #route_in(w, -77).stops == 2)
      f.fail.schedule_now = nil
      -- the same cid without its place: the early return must not hide it
      w:set_routes({ { cid = 2001, name = "A" }, { cid = -77, name = "Q" } })
      w:poke()
      settle(w, 2)
      check("place no build: a dropped place behind an equal length is published",
        route_in(w, -77) ~= nil and route_in(w, -77).place == nil)
    end

    -- 3: waits for the key and the player, holding no slot
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes({ { cid = -77, place = 77, name = "Q" }, { cid = 2001, name = "A" } })
      local n = 0
      local t0 = ptg(nil, { 77 })
      d.keypos[77] = P(200, 0, 200)
      repeat n = n + 1 until not w:refresh(0, true, t0) or n > 20
      check("place waits: no player, no place entry and the NPC takes slot 1",
        route_in(w, -77) == nil and slots(w) == "2001=1")
      d.keypos[77] = nil
      local t1 = ptg({ x = 5, y = 1, z = 5 }, { 77 })
      w:reset()
      w:set_routes({ { cid = -77, place = 77, name = "Q" }, { cid = 2001, name = "A" } })
      n = 0
      repeat n = n + 1 until not w:refresh(1, true, t1) or n > 20
      check("place waits: no key position, no place entry",
        route_in(w, -77) == nil and slots(w) == "2001=1")
      d.keypos[77] = P(200, 0, 200)
      w:poke()
      w:refresh(2, true, t1)
      check("place waits: both present, the entry appears with the next slot",
        route_in(w, -77) ~= nil and slots(w) == "-77=2,2001=1")
      w:poke()
      w:refresh(3, true, t0)
      check("place waits: the player gone frees the slot",
        route_in(w, -77) == nil and slots(w) == "2001=1")
      w:set_routes({ { cid = -77, place = 77, name = "Q" }, { cid = 2001, name = "A" },
        { cid = 2002, name = "B" } })
      local n2 = 0
      repeat n2 = n2 + 1 until not w:refresh(4, true, t0) or n2 > 20
      check("place waits: a member joining takes the slot the place freed",
        slots(w) == "2001=1,2002=2")
    end

    -- 4: guards
    f, d = sfix()
    w = f.new()
    if type(w.set_routes) == "function" then
      w:set_routes({ { cid = 2001, name = "A" } })
      settle(w, 0)
      local g0 = w.route_gen
      -- malformed legacy members reject the entire publication
      w:set_routes({ { cid = 2001, name = "A" }, { cid = 0, place = 0, name = "Z" },
        { cid = -1.5, place = 1.5, name = "Y" }, { cid = -9, place = 77, name = "X" },
        { cid = 2001, place = 77, name = "W" } })
      check("place guards: malformed legacy members clear the full publication",
        w.route_gen == g0 + 1 and cids(w) == "")
      local g = w.route_gen
      w:set_route(-5, "Z")
      w:set_route(0, "Z")
      check("place guards: set_route ignores a cid at or below 0",
        w.route_gen == g and cids(w) == "")
    end

    -- 5: moving the player drops the old near key
    f, d = sfix()
    w = f.new()
    d.keypos[77] = P(200, 0, 200)
    if type(w.set_routes) == "function" then
      w:set_routes({ { cid = -77, place = 77, name = "Q" } })
      w:refresh(0, true, ptg({ x = 5, y = 1, z = 5 }, { 77 }))
      w.near["5.0,1.0,5.0"] = 3
      w.near["200.0,0.0,200.0"] = 4
      w:poke()
      w:refresh(1, true, ptg({ x = 5, y = 1, z = 5 }, { 77 }))
      check("place re-path: an unmoved player keeps its near key", w.near["5.0,1.0,5.0"] == 3)
      w:poke()
      w:refresh(2, true, ptg({ x = 6, y = 1, z = 6 }, { 77 }))
      check("place re-path: a moved player drops the old near key only",
        w.near["5.0,1.0,5.0"] == nil and w.near["200.0,0.0,200.0"] == 4)
    end

    -- route clean-up (SPEC 32.14.11.2, 11.3): places held back, one-stop lead
    do
      local PA = { x = 5, y = 1, z = 5 }
      local tick = 0
      local function go(w, t)
        local n = 0
        tick = tick + 1
        w:poke()
        repeat n = n + 1 until not w:refresh(tick, true, t) or n > 20
      end
      local function one(w, t)
        tick = tick + 1
        w:poke()
        w:refresh(tick, true, t)
      end
      local function undisc(dd)
        dd.icons = {
          { type = K.SETTLEMENT_TYPE, pos = P(0, 0, 0), disp_id = "a", icon_id = 1 },
          { type = K.SETTLEMENT_TYPE, pos = P(1000, 0, 1000), disp_id = "b", icon_id = 2 } }
        dd.msgs = { a = "Town A", b = "Town B" }
        dd.icons_found = { [2] = true }
        dd.disc_n = 1
      end
      local function setup(kp)
        local ff, dd = sfix()
        dd.keypos[77] = kp or P(200, 0, 200)
        return ff, dd, ff.new()
      end
      local function bump(dd) dd.sig = (dd.sig or "") .. "x" end

      -- 1: a place on an NPC stop is not published
      local f1, d1, w1 = setup(P(150, 0, 1))
      w1:set_routes(PL)
      go(w1, ptg(PA, { 77 }))
      check("place on NPC stop: 149 m, no place entry", route_in(w1, -77) == nil
        and route_in(w1, 2001) ~= nil)
      w1:set_routes({ { cid = 2001, name = "A" }, { cid = -77, place = 77, name = "Q" },
        { cid = 2002, name = "B" } })
      go(w1, ptg(PA, { 77 }))
      check("place on NPC stop: a joining member takes the would-be slot",
        slots(w1) == "2001=1,2002=2")
      d1.keypos[77] = P(152, 0, 1)
      w1:reset()
      w1:set_routes(PL)
      go(w1, ptg(PA, { 77 }))
      check("place on NPC stop: 151 m, the place publishes", route_in(w1, -77) ~= nil)

      -- 1b: a held place frees its slot
      local f2, d2, w2 = setup()
      w2:set_routes(PL)
      go(w2, ptg(PA, { 77 }))
      check("held place frees slot: precondition", slots(w2) == "2001=1,-77=2")
      d2.area_nodes[50] = { P(200, 0, 190) }
      d2.rows[2001] = rows_of({ 6, 18, 50 })
      bump(d2)
      go(w2, ptg(PA, { 77 }))
      check("held place frees slot: no place entry", route_in(w2, -77) == nil)
      w2:set_routes({ { cid = 2001, name = "A" }, { cid = -77, place = 77, name = "Q" },
        { cid = 2002, name = "B" } })
      go(w2, ptg(PA, { 77 }))
      check("held place frees slot: a joining member takes it",
        slots(w2) == "2001=1,2002=2")

      -- 2: a place on an undiscovered stop
      local f3, d3, w3 = setup(P(11, 0, 1))
      undisc(d3)
      w3:set_routes(PL)
      go(w3, ptg(PA, { 77 }))
      check("place on undiscovered stop: published", route_in(w3, -77) ~= nil)
      local tu = ptg(PA, { 77 })
      tu.undiscovered = true
      go(w3, tu)
      check("place on undiscovered stop: held with undiscovered shown",
        route_in(w3, -77) == nil)

      -- 3: places wait for NPC builds
      local f4, d4, w4 = setup()
      w4:set_routes({ { cid = 2001, name = "A" }, { cid = 2002, name = "B" },
        { cid = -77, place = 77, name = "Q" } })
      one(w4, ptg(PA, { 77 }))
      check("places wait for NPC builds: round 1 has no place",
        route_in(w4, -77) == nil and w4:stats().route_builds == 1)
      one(w4, ptg(PA, { 77 }))
      check("places wait for NPC builds: round 2 has it", route_in(w4, -77) ~= nil
        and w4:stats().route_builds == 2)

      -- 3b: a shown place keeps its slot
      local f5, d5, w5 = setup()
      w5:set_routes(PL)
      go(w5, ptg(PA, { 77 }))
      check("shown place keeps its slot: precondition", slots(w5) == "2001=1,-77=2")
      w5:set_routes({ { cid = 2001, name = "A" }, { cid = -77, place = 77, name = "Q" },
        { cid = 2003, name = "C" }, { cid = 2004, name = "D" } })
      one(w5, ptg(PA, { 77 }))
      local pe5 = route_in(w5, -77)
      check("shown place keeps its slot: members joining", pe5 ~= nil and pe5.slot == 2
        and route_in(w5, 2003) ~= nil and route_in(w5, 2004) == nil)
      local f6, d6, w6 = setup()
      w6:set_routes(PL)
      go(w6, ptg(PA, { 77 }))
      w6:set_route(2004, "D")
      w6:set_routes({ { cid = 2001, name = "A" }, { cid = -77, place = 77, name = "Q" },
        { cid = 2005, name = "E" } })
      one(w6, ptg(PA, { 77 }))
      local pe6 = route_in(w6, -77)
      check("shown place keeps its slot: search target and a member",
        pe6 ~= nil and pe6.slot == 2)

      -- 4, 5: a one-stop NPC leads from the player
      local f7, d7, w7 = setup()
      w7:set_routes({ { cid = 2001, name = "A" } })
      go(w7, ptg(PA, nil))
      local e7 = route_in(w7, 2001)
      check("one-stop lead: lead, two stops, the player first",
        e7 ~= nil and e7.lead == true and #e7.stops == 2 and e7.stops[1].lead == true
        and e7.stops[1].pos.x == 5 and e7.stops[1].pos.z == 5
        and e7.stops[1].discovered == true)
      check("one-stop lead: the NPC stop carries idx, current 2 at its hour",
        e7.stops[2].idx == 1 and e7.stops[2].pos.x == 1 and e7.current == 2)
      local b7 = w7:stats().route_builds
      go(w7, ptg(nil, nil))
      e7 = route_in(w7, 2001)
      check("one-stop lead: no player, the cache kept one stop and no rebuild",
        w7:stats().route_builds == b7 and #e7.stops == 1 and e7.lead == nil
        and e7.stops[1].lead == nil)
      d7.hour = 20
      go(w7, ptg(PA, nil))
      check("one-stop lead: current nil off its hour", route_in(w7, 2001).lead == true
        and route_in(w7, 2001).current == nil)

      -- 6: undiscovered two-stop
      local f8, d8, w8 = setup()
      undisc(d8)
      d8.area_nodes[46] = { P(990, 0, 990) }
      d8.rows[2001] = rows_of({ 6, 12, 49 }, { 12, 18, 46 })
      w8:set_routes({ { cid = 2001, name = "A" } })
      go(w8, ptg(PA, nil))
      local e8 = route_in(w8, 2001)
      check("undiscovered two-stop: leads with the player and stop 2",
        e8 ~= nil and e8.lead == true and #e8.stops == 2 and e8.stops[2].idx == 2
        and e8.stops[2].pos.x == 990)
      local t8 = ptg(PA, nil)
      t8.undiscovered = true
      go(w8, t8)
      e8 = route_in(w8, 2001)
      check("undiscovered two-stop: undiscovered shown, no lead, two own stops",
        e8.lead == nil and #e8.stops == 2 and e8.stops[1].lead == nil)

      -- 6b: a hidden one-stop
      local f9, d9, w9 = setup()
      undisc(d9)
      w9:set_routes({ { cid = 2001, name = "A" } })
      go(w9, ptg(PA, nil))
      local e9 = route_in(w9, 2001)
      check("hidden one-stop: no lead, one stop", e9 ~= nil and e9.lead == nil
        and #e9.stops == 1)
      local t9 = ptg(PA, nil)
      t9.undiscovered = true
      go(w9, t9)
      e9 = route_in(w9, 2001)
      check("hidden one-stop: undiscovered shown, lead with two stops",
        e9.lead == true and #e9.stops == 2)

      -- 7: the lead player moves
      local f10, d10, w10 = setup()
      w10:set_routes({ { cid = 2001, name = "A" } })
      go(w10, ptg(PA, nil))
      w10.near["5.0,1.0,5.0"] = 3
      go(w10, ptg({ x = 6, y = 1, z = 6 }, nil))
      check("lead player moves: the old near key is dropped",
        w10.near["5.0,1.0,5.0"] == nil)

      -- 8: lead to two-stop
      local f11, d11, w11 = setup()
      w11:set_routes({ { cid = 2001, name = "A" } })
      go(w11, ptg(PA, nil))
      w11.near["5.0,1.0,5.0"] = 3
      d11.rows[2001] = rows_of({ 6, 12, 49 }, { 12, 18, 49 })
      d11.area_nodes[49] = { P(1, 0, 1), P(2, 0, 2) }
      bump(d11)
      go(w11, ptg(PA, nil))
      local e11 = route_in(w11, 2001)
      check("lead to two-stop: no lead, two own stops", e11.lead == nil and #e11.stops == 2
        and e11.stops[1].lead == nil)
      d11.rows[2001] = rows_of({ 6, 18, 49 })
      bump(d11)
      go(w11, ptg({ x = 6, y = 1, z = 6 }, nil))
      check("lead to two-stop: the record was cleared, A's key stays",
        route_in(w11, 2001).lead == true and w11.near["5.0,1.0,5.0"] == 3)

      -- 5: no player, a fresh NPC never led
      local f13, d13, w13 = setup()
      w13:set_routes({ { cid = 2001, name = "A" } })
      w13.near["5.0,1.0,5.0"] = 3
      go(w13, ptg(nil, nil))
      local e13 = route_in(w13, 2001)
      check("no player no lead: one stop, no lead, near key untouched",
        e13 ~= nil and e13.lead == nil and #e13.stops == 1 and e13.stops[1].lead == nil
        and w13.near["5.0,1.0,5.0"] == 3)

      -- 8b: an error round clears the lead record
      local f14, d14, w14 = setup()
      w14:set_routes({ { cid = 2001, name = "A" } })
      go(w14, ptg(PA, nil))
      w14.near["5.0,1.0,5.0"] = 3
      f14.fail.current_sig = true
      go(w14, ptg(PA, nil))
      check("lead error round: the NPC entry is an error entry",
        route_in(w14, 2001) ~= nil and route_in(w14, 2001).err ~= nil)
      f14.fail.current_sig = nil
      go(w14, ptg({ x = 6, y = 1, z = 6 }, nil))
      check("lead error round: the record was cleared, A's key stays",
        route_in(w14, 2001).lead == true and w14.near["5.0,1.0,5.0"] == 3)

      -- 1c: exactly 150 m from a drawn stop is held
      local f15, d15, w15 = setup(P(151, 0, 1))
      w15:set_routes(PL)
      go(w15, ptg(PA, { 77 }))
      check("place on NPC stop: exactly 150 m, no place entry", route_in(w15, -77) == nil
        and route_in(w15, 2001) ~= nil)

      -- 1d: the distance counts z, and ignores y
      local f16, d16, w16 = setup(P(1, 0, 150))
      w16:set_routes(PL)
      go(w16, ptg(PA, { 77 }))
      check("place on NPC stop: 149 m along z, no place entry", route_in(w16, -77) == nil
        and route_in(w16, 2001) ~= nil)
      local f17, d17, w17 = setup(P(1, 500, 152))
      w17:set_routes(PL)
      go(w17, ptg(PA, { 77 }))
      check("place on NPC stop: 151 m along z with a large y offset, the place publishes",
        route_in(w17, -77) ~= nil)

      -- 9: all_err places
      local f12, d12, w12 = setup()
      w12:set_routes(PL)
      f12.fail.schedule_now = true
      go(w12, ptg(PA, { 77 }))
      check("all_err places: a place publishes as today", route_in(w12, -77) ~= nil
        and route_in(w12, 2001).err ~= nil)
      f12.fail.schedule_now = nil

      -- 9b: an all_err round clears an NPC entry's lead record
      local f18, d18, w18 = setup()
      w18:set_routes({ { cid = 2001, name = "A" } })
      go(w18, ptg(PA, nil))
      w18.near["5.0,1.0,5.0"] = 3
      f18.fail.schedule_now = true
      go(w18, ptg(PA, nil))
      f18.fail.schedule_now = nil
      go(w18, ptg({ x = 6, y = 1, z = 6 }, nil))
      check("all_err NPC entry: the record was cleared, A's key stays",
        w18.near["5.0,1.0,5.0"] == 3)
    end
  end

  -- quest override rows replace the live overwrite list in a copy (SPEC 26.4)
  do
    local function qrun(qfn, with_cur)
      local f, d = nfix()
      d.sched_ids = { 2001 }
      d.npcname[2001] = "Aa"
      d.rows[2001] = rows_of({ 6, 18, 49 })
      d.area_nodes[49] = { P(1, 0, 1) }
      local live = { { start_hour = 20, end_hour = 22, area = -1, location = -1,
        priority = 0, key = 2309 } }
      if with_cur ~= false then
        d.cur[2001] = { area = 49, location = 0, overwrite = live }
      end
      if qfn ~= nil then
        f.reads.quest_overrides = function(cid) return qfn(cid) end
      end
      local w = f.new()
      local tg = on("search")
      w:refresh(0, true, tg)
      w:set_route(2001, "Aa")
      w:refresh(1, true, tg)
      return stub.last_cur, d, live, w
    end
    local qrows = { { start_hour = 6, end_hour = 15, area = -1, location = -1,
      priority = 0, key = 2302 } }

    local cur, _, live = qrun(function() return nil end)
    check("quest ov stub: a nil read keeps the live list", cur ~= nil and cur.overwrite == live)
    cur, _, live = qrun(function() return {} end)
    check("quest ov stub: an empty read keeps the live list", cur ~= nil and cur.overwrite == live)
    cur, _, live = qrun(function() error("fake quest read failure") end)
    check("quest ov stub: a raising read keeps the live list", cur ~= nil and cur.overwrite == live)
    cur, _, live = qrun(nil)
    check("quest ov stub: a reads table without quest_overrides keeps the live list",
      cur ~= nil and cur.overwrite == live)
    cur, _, live = qrun(function() return "bad" end)
    check("quest ov stub: a non-table read keeps the live list",
      cur ~= nil and cur.overwrite == live)

    local d, w
    cur, d, live, w = qrun(function() return qrows end)
    check("quest ov stub: the read is timed in stats.ms.quest_overrides",
      type(w:stats().ms.quest_overrides) == "number")
    check("quest ov stub: a non-empty read replaces the list in a copy",
      cur ~= nil and cur.overwrite == qrows and cur ~= d.cur[2001] and cur.area == 49
      and cur.location == 0)
    check("quest ov stub: the stored current entry is unchanged",
      d.cur[2001].overwrite == live and #live == 1 and live[1].key == 2309)

    cur = qrun(function() return qrows end, false)
    check("quest ov stub: a nil current entry with a non-empty read passes nil", cur == nil)
  end
end

-- ===== v14 Task 4: graph copy and route paths (SPEC 23.6) =====
do
  -- the real npcs search code, with route_stops replaced by fixed stops
  package.preload["Clairvoyance.npcs"] = nil
  package.loaded["Clairvoyance.npcs"] = nil
  local real = require("Clairvoyance.npcs")
  local stub = setmetatable({}, { __index = real })
  package.loaded["Clairvoyance.npcs"] = stub
  local fixed_stops = {}
  local stops_by = {}
  function stub.route_stops(rows)
    local out = {}
    for i, p in ipairs(stops_by[rows and rows.cid] or fixed_stops) do
      out[i] = { from = 0, to = 24, area = i, location = 0, pos = p }
    end
    return out, 0
  end
  local calls = { scan = 0, search = 0, pairs = 0 }
  function stub.nearest_new(...) calls.scan = calls.scan + 1; return real.nearest_new(...) end
  function stub.path_new(...) calls.search = calls.search + 1; return real.path_new(...) end
  function stub.route_pairs(...) calls.pairs = calls.pairs + 1; return real.route_pairs(...) end

  -- 3 blocks, 6 nodes; global index = block start + position + 1.
  -- Links are one-way where only one side lists the other; node 6 also
  -- lists an invalid target, which the copy drops.
  local BLOCKS = {
    { { 0, 0, 0, { { 0, 1 } } },
      { 10, 0, 0, { { 0, 0 }, { 1, 0 } } } },
    { { 20, 0, 0, { { 1, 1 }, { 2, 0 } } },
      { 30, 0, 0, { { 1, 0 } } } },
    { { 40, 0, 0, { { 1, 1 } } },
      { 50, 0, 0, { { 2, 0 }, { 9, 9 } } } },
  }

  local cur = BLOCKS
  local function gfix(blocks)
    cur = blocks or BLOCKS
    local f = fixture()
    local d = f.data
    d.day, d.hour = 33, 7
    f.tick, f.logs = 0, {}
    f.io.clock = function() f.clock_t = f.clock_t + f.tick; return f.clock_t end
    f.io.log = function(m) f.logs[#f.logs + 1] = m end
    local function rdef(name, fn)
      f.reads[name] = function(...)
        f.reads_n[name] = (f.reads_n[name] or 0) + 1
        return fn(...)
      end
    end
    rdef("schedule_rows", function(cid) return { cid = cid } end)
    rdef("schedule_now", function() return d.day, d.hour end)
    rdef("current_row", function() return { area = 1, location = 1 } end)
    rdef("area_nodes", function() return nil end)
    rdef("graph_block_count", function() return #cur end)
    rdef("graph_block", function(i, out, first, count)
      if d.graph_fail_at == i then error("fake graph failure") end
      local blk = cur[i + 1]
      local lo = first or 1
      local hi = count and math.min(#blk, lo + count - 1) or #blk
      local nl, fl = 0, 0
      for k = lo, hi do
        local nd = blk[k]
        fl = fl + 1
        out.x[fl], out.y[fl], out.z[fl] = nd[1], nd[2], nd[3]
        out.lc[fl] = #nd[4]
        for _, l in ipairs(nd[4]) do
          nl = nl + 1
          out.lb[nl], out.ln[nl] = l[1], l[2]
        end
      end
      if d.node_cost then f.clock_t = f.clock_t + d.node_cost * fl end
      if d.on_read then d.on_read(i, lo, fl) end
      return #blk, fl
    end)
    return f, d
  end

  local function with_route(f, pts)
    fixed_stops = pts
    local w = f.new()
    w:set_route(2001, "Aa")
    w:refresh(0, true, on("search"))
    return w
  end
  local function pct(s) return tonumber(s and s:match("copying (%d+)%%")) end
  local R3 = { P(0, 0, 0), P(31, 0, 0), P(41, 0, 0) }

  -- copy over budgeted slices equals one big-budget copy; N% is monotone
  do
    local fa = gfix()
    local wa = with_route(fa, R3)
    wa:path_step(1e6, 1, true)
    local fb = gfix()
    fb.tick = 0.001
    local wb = with_route(fb, R3)
    local last, mono, calls_n = -1, true, 0
    while wb.graph == nil and calls_n < 100 do
      wb:path_step(0.5, 1, true)
      calls_n = calls_n + 1
      local p = pct(wb:path_status(1, 2001))
      if p ~= nil then
        if p < last then mono = false end
        last = p
      end
    end
    check("copy: big budget finishes in one call", wa.graph ~= nil and wa.graph.n == 6)
    check("copy: slices finish", wb.graph ~= nil and calls_n > 1)
    check("copy: N% never drops", mono and last >= 66)
    local same = wb.graph ~= nil and wa.graph ~= nil and wa.graph.n == wb.graph.n
    for _, key in ipairs({ "x", "y", "z", "ls", "lc" }) do
      for i = 1, 6 do
        if not same or wa.graph[key][i] ~= wb.graph[key][i] then same = false end
      end
    end
    for i = 1, 8 do
      if not same or wa.graph.lt[i] ~= wb.graph.lt[i] then same = false end
    end
    check("copy: sliced equals one slice", same)
    local g = wa.graph
    check("copy: links resolved, invalid one dropped",
      g.lc[1] == 1 and g.lt[g.ls[1]] == 2 and g.lc[2] == 2 and g.lc[6] == 1
      and g.lt[g.ls[6]] == 5)
    check("copy: not busy when done", wa:path_busy() == false)
  end

  -- a failing block read; frames go through the main file gate
  do
    local f, d = gfix()
    local w = with_route(f, R3)
    local route_on = true
    local function frame()
      if (route_on and true) or w:path_busy() then w:path_step(1e6, 1, true) end
    end
    d.graph_fail_at = 1
    frame()
    check("fail: status unavailable", w:path_status(1, 2001) == "path unavailable")
    check("fail: no graph, not busy", w.graph == nil and w:path_busy() == false)
    check("fail: logged once", #f.logs == 1)
    frame(); frame()
    check("fail: route still on does not restart", #f.logs == 1 and w.copy_tries == 1
      and w.graph == nil)
    local function bounce()
      route_on = false
      w:clear_route()
      frame(); frame()
      fixed_stops = R3
      w:set_route(2001, "Aa")
      w:refresh(1, true, on("search"))
      route_on = true
      frame()
    end
    bounce()
    check("fail: off then on restarts (second failure)", w.copy_tries == 2 and #f.logs == 2)
    bounce()
    check("fail: third failure", w.copy_tries == 3 and #f.logs == 3)
    bounce()
    check("fail: no restart after the third", w.copy_tries == 3 and #f.logs == 3
      and w:path_busy() == false)
    d.graph_fail_at = nil
    bounce()
    check("fail: still no restart once healthy", w.graph == nil and w.copy_tries == 3)
  end

  -- a retry after one failure succeeds on the next route-on
  do
    local f, d = gfix()
    local w = with_route(f, R3)
    d.graph_fail_at = 2
    w:path_step(1e6, 1, true)
    d.graph_fail_at = nil
    w:clear_route()
    w:set_route(2001, "Aa")
    w:refresh(1, true, on("search"))
    w:path_step(1e6, 1, true)
    check("retry: healthy copy after the next route-on", w.graph ~= nil and w.graph.n == 6)
  end

  -- N% reaches 100 while links resolve (more than 256 nodes)
  do
    local nodes = {}
    for k = 1, 300 do
      nodes[k] = { k, 0, 0, k < 300 and { { 0, k } } or {} }
    end
    local f = gfix({ nodes })
    f.tick = 0.001
    local w = with_route(f, { P(1, 0, 0), P(5, 0, 0) })
    local seen100 = false
    for _ = 1, 400 do
      w:path_step(0.5, 1, true)
      if w.graph == nil and pct(w:path_status(1, 2001)) == 100 then seen100 = true end
    end
    check("copy: 100% shown during link resolution", seen100 and w.graph ~= nil
      and w.graph.n == 300 and w.graph.lc[299] == 1 and w.graph.lt[w.graph.ls[299]] == 300)
  end

  -- route off mid-copy keeps copying; turning it on does not restart
  do
    local f = gfix()
    f.tick = 0.001
    local w = with_route(f, R3)
    w:path_step(0.5, 1, true)
    check("mid: copy started", w:path_busy() == true and w.graph == nil)
    w:clear_route()
    w:path_step(0.5, 1, false)
    local before = f.reads_n.graph_block
    check("mid: keeps copying with no route", before >= 2 and w:path_busy() == true)
    w:set_route(2001, "Aa")
    w:refresh(2, true, on("search"))
    w:path_step(0.5, 1, false)
    check("mid: route on again continues the same copy", f.reads_n.graph_block > before
      and f.reads_n.graph_block_count == 1 and w:path_busy() == true)
    local guard = 0
    while w:path_busy() and guard < 100 do w:path_step(0.5, 1, false); guard = guard + 1 end
    check("mid: finished", w.graph ~= nil and w:path_busy() == false and w.graph.n == 6)
    check("mid: no restart", f.reads_n.graph_block_count == 1 and w.copy_tries == 0)
  end

  -- a slice stops between nodes: a 1000-node block over a 2 ms budget
  do
    local big = {}
    for k = 1, 1000 do
      big[k] = { k, k * 2, k * 3, { { 0, k % 1000 }, { 0, (k * 7) % 1000 } } }
    end
    local function run(cost)
      local f, d = gfix({ big })
      d.node_cost = cost
      local reads_log = {}
      d.on_read = function(_, lo, fl) reads_log[#reads_log + 1] = { lo, fl } end
      local w = with_route(f, R3)
      local slices, worst, guard = 0, 0, 0
      while w.graph == nil and guard < 2000 do
        local t0, r0 = f.clock_t, #reads_log
        w:path_step(2, 1, true)
        slices = slices + 1
        guard = guard + 1
        local nodes = 0
        for r = r0 + 1, #reads_log do nodes = nodes + reads_log[r][2] end
        -- nodes after the first read of the slice must fit the budget
        local first_n = reads_log[r0 + 1] and reads_log[r0 + 1][2] or 0
        local over = f.clock_t - t0 - (reads_log[r0 + 1] and first_n * cost or 0)
        if over > worst then worst = over end
      end
      return w, slices, worst
    end
    local wa = run(0)
    local wb, slices, worst = run(0.00002)
    check("slice: copy finishes in many slices", wb.graph ~= nil and slices > 5)
    check("slice: nothing after the first read exceeds the budget", worst <= 0.002 + 1e-9)
    -- 1 ms clock: reads time at 0 or 1 ms; a slice stays within budget + one tick
    do
      local f, d = gfix({ big })
      d.node_cost = 0.000022
      f.io.clock = function() return math.floor(f.clock_t * 1000) / 1000 end
      local w = with_route(f, R3)
      local worstq, g = 0, 0
      repeat
        local t0 = f.clock_t
        w:path_step(2, 1, true)
        g = g + 1
        if f.clock_t - t0 > worstq then worstq = f.clock_t - t0 end
      until w.graph ~= nil or g >= 2000
      check("slice: 1 ms clock keeps each slice within budget + one tick",
        w.graph ~= nil and worstq <= 0.003 + 1e-9)
    end
    -- a slow first read (mean above the budget) still lets the copy finish
    do
      local f, d = gfix({ big })
      d.node_cost = 0.000022
      local first = true
      d.on_read = function()
        if first then first = false; f.clock_t = f.clock_t + 0.04 end
      end
      local w = with_route(f, R3)
      local g = 0
      repeat w:path_step(2, 1, true); g = g + 1 until w.graph ~= nil or g >= 5000
      check("slice: slow first read does not stall the copy",
        w.graph ~= nil and w.graph.n == 1000)
    end
    local same = wa.graph ~= nil and wb.graph ~= nil and wa.graph.n == 1000
      and wb.graph.n == 1000
    for _, key in ipairs({ "x", "y", "z", "ls", "lc" }) do
      for i = 1, 1000 do
        if not same or wa.graph[key][i] ~= wb.graph[key][i] then same = false end
      end
    end
    for i = 1, 2000 do
      if not same or wa.graph.lt[i] ~= wb.graph.lt[i] then same = false end
    end
    check("slice: node-sliced copy equals the one-shot copy", same)
  end

  -- a block that changes size mid-copy never raises an index error
  do
    local big, small = {}, {}
    for k = 1, 200 do big[k] = { k, 0, 0, { { 0, 0 } } } end
    for k = 1, 5 do small[k] = { k, 0, 0, { { 0, 0 } } } end
    for _, target in ipairs({ small, {} }) do
      local f, d = gfix({ big })
      d.node_cost = 0.00002
      local swapped = false
      d.on_read = function(_, lo)
        if lo > 1 and not swapped then swapped = true; cur = { target } end
      end
      local w = with_route(f, R3)
      local n = 0
      repeat w:path_step(1, 1, true); n = n + 1 until not w:path_busy() or n >= 200
      local bad = false
      for _, m in ipairs(f.logs) do
        if m:find("attempt to") then bad = true end
      end
      check("slice: shrinking block ends without an index error (" .. #target .. ")",
        swapped and not bad and not w:path_busy() and #f.logs == 0 and w.copy_tries == 0
        and w.graph ~= nil)
    end
  end

  -- search over the finished copy
  do
    local f = gfix()
    local w = with_route(f, R3)
    w:path_step(1e6, 1, true)
    check("route: pairs listed before steps", #w:route_paths(true)[2001] == 2
      and w:route_paths(true)[2001][1].pts == nil)
    check("route: status finding", w:path_status(1, 2001) == "path: finding")
    check("route: status nil when route_path is 0", w:path_status(0, 2001) == nil)
    local n = 0
    while w:path_status(1, 2001) ~= "path ready" and n < 50 do
      w:path_step(1e6, 1, true)
      n = n + 1
    end
    local l = w:route_paths(true)[2001]
    check("route: both pairs found", #l == 2 and l[1].pts ~= nil and l[2].pts ~= nil)
    check("route: pair 1 runs node 1 to 4", l[1].i == 1 and l[1].j == 2 and #l[1].pts == 12
      and l[1].pts[1] == 0 and l[1].pts[10] == 30 and l[1].pts[12] == 0)
    check("route: pair 2 runs node 4 to 5", l[2].pts ~= nil and l[2].pts[1] == 30
      and l[2].pts[#l[2].pts - 2] == 40)
    check("route: status ready", w:path_status(1, 2001) == "path ready")
    check("route: list is cached", w:route_paths(true)[2001] == l)
    check("route: stats", w.last_expanded ~= nil and w.search_ms_max >= 0 and w.last_pair ~= nil)
    local np = 0
    for _ in pairs(w.paths) do np = np + 1 end
    check("route: two paths cached", np == 2)

    -- reset keeps the graph and caches, cancels the job
    local saved_graph, saved_paths, saved_near = w.graph, w.paths, w.near
    w.path_job = { kind = "near" }
    w:reset()
    check("reset: keeps graph, paths, near", w.graph == saved_graph and w.paths == saved_paths
      and w.near == saved_near and next(w.near) ~= nil)
    check("reset: cancels the job", w.path_job == nil)

    -- an hour change rebuilds the route with the same stop pair
    calls.scan, calls.search = 0, 0
    local pairs_before = calls.pairs
    f.data.hour = 8
    w:set_route(2001, "Aa")
    w:refresh(20, true, on("search"))
    for _ = 1, 5 do w:path_step(1e6, 1, true) end
    check("hour: no new scan or search", calls.scan == 0 and calls.search == 0
      and calls.pairs == pairs_before)
    check("hour: still ready", w:path_status(1, 2001) == "path ready"
      and w:route_paths(true)[2001][1].pts ~= nil)
  end

  -- cancellation of a running search
  do
    local f = gfix()
    f.tick = 0.001
    local w = with_route(f, R3)
    for _ = 1, 40 do
      w:path_step(0.5, 1, true)
      if w.graph ~= nil then break end
    end
    w:path_step(0.5, 1, true)
    check("cancel: a job is running", w.path_job ~= nil)
    w:clear_route()
    check("cancel: clear_route", w.path_job == nil)
    w:set_route(2001, "Aa")
    fixed_stops = R3
    w:refresh(30, true, on("search"))
    w:path_step(0.5, 1, true)
    check("cancel: job running again", w.path_job ~= nil)
    w:set_route(2001, "Aa")
    check("cancel: same cid keeps the job", w.path_job ~= nil)
    w:set_route(2002, "Bb")
    check("cancel: set_route to another cid", w.path_job == nil)
  end

  -- route members share one walking-path job (plan Task 2.3)
  do
    local f = gfix()
    f.tick = 0.001
    stops_by[2002] = { P(10, 0, 0), P(40, 0, 0) }
    local w = with_route(f, R3)
    w:set_routes({ { cid = 2001, name = "Aa" }, { cid = 2002, name = "Bb" } })
    w:refresh(1, true, on("search"))
    local n = 0
    while w:path_status(1, 2001) ~= "path ready" and n < 200 do
      w:path_step(0.5, 1, true)
      n = n + 1
    end
    check("members: status takes the member", w:path_status(1, 9999) == nil)
    check("members: first member first", w:path_status(1, 2002) == "path: finding")
    w:path_step(0.5, 1, true)
    check("members: job serves the next member", w.path_job ~= nil and w.path_job.cid == 2002)
    w:set_route(2003, "Cc")
    check("members: set_route to another cid keeps another member's job",
      w.path_job ~= nil and w.path_job.cid == 2002)
    w:clear_route()
    check("members: clear_route keeps another member's job", w.path_job ~= nil and w.path_job.cid == 2002)
    check("members: clear_route keeps a member with the target's cid",
      route_in(w, 2001) ~= nil and #w:input().routes == 2)
    w:set_routes({})
    check("members: removing a member cancels its job", w.path_job == nil)
  end

  do
    local f = gfix()
    stops_by[2002] = { P(10, 0, 0), P(40, 0, 0) }
    local w = with_route(f, R3)
    w:set_routes({ { cid = 2001, name = "Aa" }, { cid = 2002, name = "Bb" } })
    w:refresh(1, true, on("search"))
    local n = 0
    while (w:path_status(1, 2001) ~= "path ready" or w:path_status(1, 2002) ~= "path ready") and n < 200 do
      w:path_step(1e6, 1, true)
      n = n + 1
    end
    check("members: both ready", w:path_status(1, 2002) == "path ready")
    local rp = w:route_paths(true)
    local keys = {}
    for k in pairs(rp) do keys[#keys + 1] = k end
    table.sort(keys)
    check("members: route_paths keyed by cid", #keys == 2 and keys[1] == 2001 and keys[2] == 2002
      and #rp[2002] == 1 and rp[2002][1].pts ~= nil)
    check("members: route_paths cached", w:route_paths(true) == w:route_paths(true))
    w:set_routes({ { cid = 2001, name = "Aa" } })
    check("members: a removed member's pair cache leaves at once", w.rps[2002] == nil)
    check("members: a removed member's paths leave at once",
      route_in(w, 2002) == nil and w:route_paths(true)[2002] == nil
      and w:route_paths(true)[2001] ~= nil)
  end

  -- two members with the same stops: a reused job reports the cid it serves
  do
    local f = gfix()
    f.tick = 0.001
    stops_by[2002] = R3
    local w = with_route(f, R3)
    w:set_routes({ { cid = 2001, name = "Aa" }, { cid = 2002, name = "Bb" } })
    w:refresh(1, true, on("search"))
    for _ = 1, 40 do
      w:path_step(0.5, 1, true)
      if w.graph ~= nil then break end
    end
    w:path_step(0.5, 1, true)
    local before = w.path_job ~= nil and w.path_job.cid == 2001
    w:set_route(2002, "Bb")
    w:refresh(1, true, on("search"))
    w:path_step(0.5, 1, true)
    check("members: a job reused for a shared key serves the new cid",
      before and w.path_job ~= nil and w.path_job.cid == 2002)
    stops_by[2002] = nil
  end

  -- a target that is also a member keeps its job through clear_route
  do
    local f = gfix()
    f.tick = 0.001
    local w = with_route(f, R3)
    w:set_routes({ { cid = 2001, name = "Aa" } })
    for _ = 1, 40 do
      w:path_step(0.5, 1, true)
      if w.graph ~= nil then break end
    end
    w:path_step(0.5, 1, true)
    local running = w.path_job ~= nil and w.path_job.cid == 2001
    w:clear_route()
    check("members: clear_route keeps the job of a target that is a member",
      running and w.path_job ~= nil and w.path_job.cid == 2001)
    w:set_routes({})
    check("members: the cid leaving both roles cancels its job", w.path_job == nil)
  end

  -- the 64-path cap never evicts the shown route
  do
    local big, nodes = {}, {}
    for k = 1, 80 do
      local ls = {}
      if k < 80 then ls[#ls + 1] = { 0, k } end
      if k > 1 then ls[#ls + 1] = { 0, k - 2 } end
      nodes[k] = { (k - 1) * 10, 0, 0, ls }
    end
    big[1] = nodes
    local function run(w, n, cid)
      for _ = 1, n do
        if w:path_status(1, cid or 2001) == "path ready" then break end
        w:path_step(1e6, 1, true)
      end
    end
    local f = gfix(big)
    local pts = {}
    for k = 1, 71 do pts[k] = P((k - 1) * 10, 0, 0) end
    local w = with_route(f, pts)
    run(w, 600)
    local np = 0
    for _ in pairs(w.paths) do np = np + 1 end
    check("cap: 70 pairs all kept and ready", np == 70 and w:path_status(1, 2001) == "path ready")
    local l = w:route_paths(true)[2001]
    check("cap: every pair has points", #l == 70 and l[1].pts ~= nil and l[70].pts ~= nil)
    -- a short route elsewhere: the oldest paths of the old route go first
    fixed_stops = { P(710, 0, 0), P(720, 0, 0), P(730, 0, 0) }
    w:set_route(2001, "Aa")
    w:refresh(30, true, on("search"))
    run(w, 100)
    np = 0
    for _ in pairs(w.paths) do np = np + 1 end
    check("cap: back to 64, new pairs kept, oldest gone", np == 64 and w:path_status(1, 2001) == "path ready"
      and w.paths[1 * 1048576 + 2] == nil
      and w.paths[72 * 1048576 + 73] ~= nil and w.paths[73 * 1048576 + 74] ~= nil)
    stops_by[2002] = pts
    w:set_routes({ { cid = 2001, name = "Aa" }, { cid = 2002, name = "Bb" } })
    w:refresh(40, true, on("search"))
    run(w, 600, 2002)
    np = 0
    for _ in pairs(w.paths) do np = np + 1 end
    check("members: eviction keeps every member's pairs", np == 72
      and w.paths[1 * 1048576 + 2] ~= nil and w.paths[72 * 1048576 + 73] ~= nil)
  end

  -- storing with no route pair cache still caps at 64
  do
    local f = gfix()
    local w = f.new()
    for k = 1, 65 do w.store_path(k, { k }) end
    local np = 0
    for _ in pairs(w.paths) do np = np + 1 end
    check("cap: 65 stored with no cache leaves 64", np == 64 and w.paths[1] == nil
      and w.paths[65] ~= nil)
  end

  -- io: only log given
  do
    local saved = json
    json = { load_file = function() return nil end, dump_file = function() return true end }
    local ok, wio = pcall(world.new, {}, {}, { log = function() end })
    check("io: only log still loads", ok and wio ~= nil)
    json = saved
  end
end

-- reads: the walking graph over fake managed objects
do
  local function obj(fields, methods)
    local o = {}
    function o:get_field(n) return fields and fields[n] end
    function o:call(n, ...)
      local m = methods and methods[n]
      if m then return m(...) end
      return nil
    end
    return o
  end
  local function list(items)
    return obj(nil, { get_Count = function() return #items end,
      get_Item = function(i) return items[i + 1] end })
  end
  local bad = {}
  local function node(x, y, z, links)
    local ls = {}
    for i, l in ipairs(links) do ls[i] = obj({ blockId = l[1], indexId = l[2] }) end
    return obj({ _Pos = P(x, y, z), Links = list(ls) })
  end
  local blk0 = obj({ Nodes = list({ node(1, 2, 3, { { 0, 1 } }), node(4, 5, 6, {}) }) })
  local blk1 = obj({ Nodes = list({ node(7, 8, 9, { { 0, 0 }, { 1, 0 } }) }) })
  local graph = obj({ Nodes = list({ blk0, blk1 }) })
  local mgr = obj({ AIWorldGraphDatas = list({ obj({ ["<GraphData>k__BackingField"] =
    obj({ AIWorldGraph = graph }) }) }) })
  local singletons, fetches = { ["app.AIWorldGraphManager"] = mgr }, 0
  local saved_sdk = sdk
  sdk = {
    get_managed_singleton = function(n) fetches = fetches + 1; return singletons[n] end,
    is_managed_object = function(o) return not bad[o] end,
    find_type_definition = function() return nil end,
  }
  local R = world.game_reads()
  check("graph reads: block count", R.graph_block_count() == 2)
  local out = { x = {}, y = {}, z = {}, lc = {}, lb = {}, ln = {} }
  local n = R.graph_block(1, out)
  check("graph reads: block 1 as plain tables", n == 1 and out.x[1] == 7 and out.y[1] == 8
    and out.z[1] == 9 and out.lc[1] == 2 and out.lb[1] == 0 and out.ln[1] == 0
    and out.lb[2] == 1 and out.ln[2] == 0 and type(out.x) == "table")
  local nc, nf = R.graph_block(1, out, 1, 16)
  check("graph reads: clamp reports node count and filled", nc == 1 and nf == 1)
  local nc2, nf2 = R.graph_block(0, out, 2, 5)
  check("graph reads: partial read from node 2", nc2 == 2 and nf2 == 1 and out.x[1] == 4
    and out.lc[1] == 0)
  local nc3, nf3 = R.graph_block(0, out, 3, 5)
  check("graph reads: past the end fills none", nc3 == 2 and nf3 == 0)
  local n0 = R.graph_block(0, out)
  check("graph reads: block 0", n0 == 2 and out.x[2] == 4 and out.lc[1] == 1
    and out.lc[2] == 0 and out.ln[1] == 1)
  check("graph reads: chain re-acquired each call", fetches == 6)
  bad[blk0] = true
  check("graph reads: failed managed check raises", not pcall(R.graph_block, 0, out))
  bad[blk0] = nil
  bad[graph] = true
  check("graph reads: failed check up the chain raises", not pcall(R.graph_block_count))
  bad[graph] = nil
  singletons["app.AIWorldGraphManager"] = nil
  check("graph reads: no manager raises", not pcall(R.graph_block_count))
  sdk = saved_sdk
end

-- v14 Task 3: gimmick 12 chests and the treasure join (SPEC 24.2, 24.4)
do
  local f = fixture()
  f.data.reserved = { chest_row("g12", 10, 10, 1, 12) }
  local w = f.new()
  w:refresh(0, true, on("chests"))
  check("t3: gimmick 12 with no places row is learned as a chest",
    find(w:input().chests, "g12") ~= nil)
end

do
  local function tfix(nodes, rows, noplaces)
    local files = nil
    if not noplaces then files = { [K.PLACES] = places(rows) } end
    local f = fixture({ files = files })
    f.data.nodes = nodes
    f.data.iname = { [500] = "Longsword", [600] = "Dagger" }
    f.data.checked = {}
    return f
  end
  local function crow(uid, x, z, id, n)
    return prow("chest", uid, 10, x, z, { items = { { id = id, n = n } } })
  end
  local function node(name, x, z) return { name = name, pos = P(x, 0, z) } end
  local function tr(f)
    local w = f.new()
    w:refresh(0, true, on("treasure"))
    return w:input().treasure
  end
  local t1 = tr(tfix({ node("N1", 100, 100) }, { crow("c1", 100.5, 100, 500, 2) }))
  check("t3: node within range carries the chest items, Chests off",
    t1[1] ~= nil and t1[1].items ~= nil and #t1[1].items == 1 and t1[1].items[1].n == 2
    and t1[1].items[1].name == "Longsword")
  local t2 = tr(tfix({ node("N1", 100, 100) }, { crow("c1", 104, 100, 500, 2) }))
  check("t3: node 4 units from every chest has no items", t2[1] ~= nil and t2[1].items == nil)
  local t3 = tr(tfix({ node("N1", 100, 100) },
    { crow("a", 102.4, 100, 600, 1), crow("b", 100.1, 100, 500, 2) }))
  check("t3: of two rows in range the nearer one's items",
    t3[1] ~= nil and t3[1].items ~= nil and #t3[1].items == 1 and t3[1].items[1].n == 2)
  local t5 = tr(tfix({ node("N1", 100, 100) }, { crow("c1", 103, 100, 500, 2) }))
  check("t3: a row at exactly 3.0 units is mapped", t5[1] ~= nil and t5[1].items ~= nil)
  local t6 = tr(tfix({ node("N1", 100, 100) }, {
    prow("chest", "c1", 10, 100, 100.5, { y = 3, items = { { id = 500, n = 2 } } }) }))
  check("t3: the y offset counts (3D distance)", t6[1] ~= nil and t6[1].items == nil)
  local t7 = tr(tfix({ node("N1", 100, 100) },
    { crow("z", 101, 100, 600, 1), crow("y", 99, 100, 500, 2) }))
  check("t3: equal distance goes to the first sorted uid",
    t7[1] ~= nil and t7[1].items ~= nil and t7[1].items[1].n == 2)
  local ok, t4 = pcall(tr, tfix({ node("N1", 100, 100) }, nil, true))
  check("t3: no places file gives no items and no error",
    ok and t4[1] ~= nil and t4[1].items == nil)
end

-- ===== v14 Task 2b: routes through the real route builder (SPEC 25.6.2) =====
do
  local saved_loaded = package.loaded["Clairvoyance.npcs"]
  package.preload["Clairvoyance.npcs"] = nil
  package.loaded["Clairvoyance.npcs"] = nil
  local real = require("Clairvoyance.npcs")
  package.loaded["Clairvoyance.npcs"] = real

  local function rfix()
    local f = fixture()
    local d = f.data
    d.rows, d.day, d.hour, d.cur, d.keypos, d.area_nodes = {}, 33, 20, {}, {}, {}
    d.holders, d.sent, d.generic, d.hcount, d.area_calls = {}, {}, {}, 0, {}
    d.qov = {}
    local function rdef(name, fn)
      f.reads[name] = function(...)
        f.reads_n[name] = (f.reads_n[name] or 0) + 1
        return fn(...)
      end
    end
    rdef("schedule_rows", function(cid) return d.rows[cid] end)
    rdef("schedule_now", function() return d.day, d.hour end)
    rdef("current_row", function(cid) return d.cur[cid] end)
    rdef("current_sig", function(cid)
      local e = d.cur[cid]
      if e == nil then return nil end
      return e.area, e.location, e.key or -1, #(e.overwrite or {})
    end)
    rdef("key_pos", function(key) return d.keypos[key] end)
    rdef("quest_overrides", function(cid) return d.qov[cid] end)
    rdef("area_nodes", function(row)
      d.area_calls[#d.area_calls + 1] = row
      return d.area_nodes[row.area .. ":" .. tostring(row.location)]
    end)
    rdef("holder_count", function() return d.hcount end)
    rdef("holder_at", function(i) return d.holders[i] end)
    rdef("sentiment", function() return nil end)
    f.adapter.is_generic = function() return false end
    return f, d
  end
  local function row(sh, eh, area, loc, key)
    return { start_week = 1, end_week = 4, start_day = 0, end_day = 6,
      start_hour = sh, end_hour = eh, area = area, location = loc, priority = 0,
      key = key or -1 }
  end

  -- Albert: base 6-18 location 7, 18-6 area 42, overwrite 20-22 key 2309
  do
    local f, d = rfix()
    d.sched_ids = { 2696 }
    d.npcname[2696] = "Albert"
    d.rows[2696] = { row(6, 18, -1, 7), row(18, 6, 42, -1) }
    d.cur[2696] = { area = -1, location = -1, key = 2309, pos = P(576.0, 19.0, -1011.0),
      overwrite = { row(20, 22, -1, -1, 2309) } }
    d.keypos[2309] = P(576.3, 19.3, -1011.1)
    d.area_nodes["-1:7"] = { P(100, 0, 100) }
    d.area_nodes["42:-1"] = { P(300, 0, 300) }
    local w = f.new()
    local tg = on("search")
    w:refresh(0, true, tg)
    w:set_route(2696, "Albert")
    w:refresh(1, true, tg)
    local r = route_in(w)
    check("real route: albert publishes 4 stops", r ~= nil and r.err == nil and #r.stops == 4
      and r.stops[1].from == 6 and r.stops[2].from == 18 and r.stops[3].from == 20
      and r.stops[4].from == 22 and r.stops[4].to == 6)
    check("real route: albert stop 3 at the live position, no off_schedule",
      r ~= nil and r.err == nil and r.stops ~= nil and r.stops[3] ~= nil and r.stops[3].pos.x == 576.0 and r.stops[3].key == 2309
      and r.off_schedule == nil)
  end

  -- a key that does not resolve is unplaced and never asks for area nodes
  do
    local f, d = rfix()
    d.sched_ids = { 2697 }
    d.npcname[2697] = "Bb"
    d.hour = 7
    d.rows[2697] = { row(6, 18, -1, -1, 99), row(18, 6, 49, 0) }
    d.area_nodes["49:0"] = { P(1, 0, 1) }
    local w = f.new()
    local tg = on("search")
    w:refresh(0, true, tg)
    w:set_route(2697, "Bb")
    w:refresh(1, true, tg)
    local r = route_in(w)
    local bad = 0
    for _, c in ipairs(d.area_calls) do
      if c.area == -1 and c.location == -1 then bad = bad + 1 end
    end
    check("real route: unresolved key is counted unplaced",
      r ~= nil and r.err == nil and r.unplaced == 1 and #r.stops == 1)
    check("real route: unresolved key asks area_nodes zero times",
      #d.area_calls >= 1 and bad == 0)
  end

  -- two key stops near two towns get their own discovery answers
  do
    local f, d = rfix()
    d.sched_ids = { 2698 }
    d.npcname[2698] = "Cc"
    d.hour = 7
    d.rows[2698] = { row(0, 12, -1, -1, 2309), row(12, 24, -1, -1, 2310) }
    d.keypos[2309] = P(5, 0, 5)
    d.keypos[2310] = P(995, 0, 995)
    d.icons = {
      { type = K.SETTLEMENT_TYPE, pos = P(0, 0, 0), disp_id = "a", icon_id = 1 },
      { type = K.SETTLEMENT_TYPE, pos = P(1000, 0, 1000), disp_id = "b", icon_id = 2 } }
    d.msgs = { a = "Town A", b = "Town B" }
    d.icons_found = { [2] = true }
    d.disc_n = 1
    local w = f.new()
    local tg = on("search")
    w:refresh(0, true, tg)
    w:set_route(2698, "Cc")
    w:refresh(1, true, tg)
    local r = route_in(w)
    check("real route: key stops get their own discovery answers",
      r ~= nil and r.err == nil and r.stops ~= nil and #r.stops == 2 and r.stops[1].discovered == false
      and r.stops[2].discovered == true)
  end


  -- the quest stage's whole day (SPEC 26.6.2): Albert, qu020090
  do
    local stage_keys = { 2301, 2302, 2303, 2304, 2305 }
    local function albert(hour)
      local f, d = rfix()
      d.sched_ids = { 2696 }
      d.npcname[2696] = "Albert"
      d.hour = hour
      d.rows[2696] = { row(6, 18, -1, 7), row(18, 6, 42, -1) }
      d.area_nodes["-1:7"] = { P(100, 0, 100) }
      d.area_nodes["42:-1"] = { P(300, 0, 300) }
      for i, k in ipairs(stage_keys) do d.keypos[k] = P(1000 * i, 0, 5) end
      return f, d
    end
    local function route_of(f)
      local w = f.new()
      local tg = on("search")
      w:refresh(0, true, tg)
      w:set_route(2696, "Albert")
      w:refresh(1, true, tg)
      return route_in(w)
    end

    do
      local f, d = albert(8)
      d.cur[2696] = { area = -1, location = -1, key = 2302, pos = P(6666, 0, 7),
        overwrite = { row(6, 15, -1, -1, 2302), row(15, 20, -1, -1, 2303) } }
      d.qov[2696] = { row(6, 15, -1, -1, 2302), row(15, 20, -1, -1, 2303),
        row(20, 22, -1, -1, 2304), row(22, 3, -1, -1, 2305), row(3, 6, -1, -1, 2301) }
      local r = route_of(f)
      local froms, ok = {}, r ~= nil and r.err == nil and r.stops ~= nil
      if ok then
        for i, s in ipairs(r.stops) do
          froms[i] = s.from
          local want = (s.key == 2302) and 6666 or 1000 * (s.key - 2300)
          if s.pos.x ~= want then ok = false end
        end
      end
      check("quest ov real: five stops in order 3, 6, 15, 20, 22",
        r ~= nil and r.stops ~= nil and #r.stops == 5 and table.concat(froms, ",") == "3,6,15,20,22")
      check("quest ov real: key positions, the current stop at cur.pos, no off_schedule",
        ok and r.off_schedule == nil)
    end

    -- the applied entry's place wins when two "now" entries differ at the hour
    do
      local f, d = albert(8)
      d.cur[2696] = { area = -1, location = -1, key = 2302, pos = P(6666, 0, 7),
        overwrite = { row(6, 15, -1, -1, 2302) } }
      d.qov[2696] = { row(0, 24, -1, -1, 2302), row(0, 24, -1, -1, 2303) }
      local r = route_of(f)
      check("quest ov real: the applied entry's place wins",
        r ~= nil and r.err == nil and #r.stops == 1 and r.stops[1].key == 2302
        and r.stops[1].pos.x == 6666 and r.off_schedule == nil)
    end
  end

  package.loaded["Clairvoyance.npcs"] = saved_loaded
end

-- 28. chest kinds, quest state, quest text (spec 27.2, 27.4)
do
  local core = require("Clairvoyance.core")
  local saved_gate = core.gate_name
  local calls = {}
  core.gate_name = function(qid, adapter, reveal)
    calls[#calls + 1] = { qid = qid, reveal = reveal }
    return adapter.quest_name(qid) or "another quest"
  end

  local function kinds_of(c) return table.concat(c.kinds, ",") end
  local function world_of(rows, records, qstate, qname)
    local f = fixture({ files = { [K.PLACES] = places(rows) } })
    f.data.records = records or {}
    f.data.qstate = qstate or {}
    f.data.qname = qname or {}
    local w = f.new()
    return f, w
  end

  -- kinds from each field, id and item rule
  do
    local f, w = world_of({
      prow("chest", "k_quest", 10, 1, 1, { quest = { any = true, q = { { 11020, true } } } }),
      prow("chest", "k_trap", 10, 2, 2, { trap = true }),
      prow("chest", "k_pawn", 11, 3, 3, { pawn = true }),
      prow("chest", "k_692", 692, 4, 4, { items = { { id = 78, n = 1 } } }),
      prow("chest", "k_693", 693, 5, 5, {}),
      prow("chest", "k_694", 694, 6, 6, {}),
      prow("chest", "k_k77", 10, 7, 7, { items = { { id = 77, n = 1 } } }),
      prow("chest", "k_k78", 11, 8, 8, { items = { { id = 78, n = 1 } } }),
      prow("chest", "k_k81", 12, 9, 9, { items = { { id = 81, n = 1 } } }),
      prow("chest", "k_k5", 10, 10, 10, { items = { { id = 5, n = 1 } } }),
      prow("chest", "k_all", 10, 11, 11, { items = { { id = 77, n = 1 } }, trap = true,
        pawn = true, quest = { any = false, q = {}, var = true } }),
    }, nil)
    w:refresh(0, true, on("chests"))
    local ch = w:input().chests
    check("kinds: no records at all, quest", kinds_of(find(ch, "k_quest")) == "quest")
    check("kinds: trap", kinds_of(find(ch, "k_trap")) == "trap")
    check("kinds: pawn", kinds_of(find(ch, "k_pawn")) == "pawn")
    check("kinds: 692 with 78 is ng_shard only", kinds_of(find(ch, "k_692")) == "ng_shard")
    check("kinds: 693, 694 ng_shard", kinds_of(find(ch, "k_693")) == "ng_shard"
      and kinds_of(find(ch, "k_694")) == "ng_shard")
    check("kinds: kept 77/78/81", kinds_of(find(ch, "k_k77")) == "kept"
      and kinds_of(find(ch, "k_k78")) == "kept" and kinds_of(find(ch, "k_k81")) == "kept")
    check("kinds: other item has none", #find(ch, "k_k5").kinds == 0)
    check("kinds: spec order", kinds_of(find(ch, "k_all")) == "kept,quest,trap,pawn")
    check("kinds: no quest fields on a plain chest",
      find(ch, "k_trap").quest_met == nil and find(ch, "k_trap").quest_text == nil)
  end

  -- live keep adds kept once, false removes nothing
  do
    local f, w = world_of({
      prow("chest", "r1", 10, 1, 1, { items = { { id = 5, n = 1 } } }),
      prow("chest", "r2", 10, 2, 2, { items = { { id = 77, n = 1 } } }),
    }, { { key = "r1_0", picked = false, keep = true }, { key = "r1_1", picked = false, keep = true },
      { key = "r2_0", picked = false, keep = false } })
    w:refresh(0, true, on("chests"))
    local ch = w:input().chests
    check("keep: true adds kept once", kinds_of(find(ch, "r1")) == "kept")
    check("keep: false leaves the item-rule kept", kinds_of(find(ch, "r2")) == "kept")
  end

  -- a learned entry at a moved position keeps its row kinds
  do
    local f, w = world_of({
      prow("chest", "m1", 10, 1, 1, { trap = true, pawn = true,
        quest = { any = true, q = { { 1, true } } } }) })
    f.data.reserved = { chest_row("m1", 50, 60) }
    w:refresh(0, true, on("chests"))
    local c = find(w:input().chests, "m1")
    check("moved: learned at the new position", c ~= nil and c.pos.x == 50)
    check("moved: keeps quest, trap, pawn", c ~= nil and kinds_of(c) == "quest,trap,pawn")
  end

  -- quest_met
  local function met(q, qstate)
    local rows = { prow("chest", "q1", 10, 1, 1, { quest = q }) }
    local f, w = world_of(rows, nil, qstate)
    w:refresh(0, true, on("chests"))
    return find(w:input().chests, "q1").quest_met
  end
  check("met: finish true, completed", met({ any = false, q = { { 1, true } } }, { [1] = "completed" }) == true)
  check("met: finish true, nil state", met({ any = false, q = { { 1, true } } }, {}) == nil)
  check("met: finish false, completed", met({ any = false, q = { { 1, false } } }, { [1] = "completed" }) == false)
  check("met: finish false, nil state", met({ any = false, q = { { 1, false } } }, {}) == nil)
  check("met: any over (true, nil)", met({ any = true, q = { { 1, true }, { 2, true } } }, { [1] = "completed" }) == true)
  check("met: any over (false, nil)", met({ any = true, q = { { 1, false }, { 2, true } } }, { [1] = "failed" }) == false)
  check("met: any over (nil, nil)", met({ any = true, q = { { 1, true }, { 2, true } } }, {}) == nil)
  check("met: all over (true, false)", met({ any = false, q = { { 1, true }, { 2, false } } },
    { [1] = "completed", [2] = "completed" }) == false)
  check("met: all over (true, nil)", met({ any = false, q = { { 1, true }, { 2, true } } }, { [1] = "completed" }) == nil)
  check("met: all over (true, true)", met({ any = false, q = { { 1, true }, { 2, true } } },
    { [1] = "completed", [2] = "canceled" }) == true)
  check("met: all with a false and a nil is false", met({ any = false, q = { { 1, false }, { 2, true } } },
    { [1] = "completed" }) == false)
  check("met: var gives nil", met({ any = false, q = { { 1, true } }, var = true }, { [1] = "completed" }) == nil)

  -- quest_text
  local function text(q, qname, reveal)
    local rows = { prow("chest", "q1", 10, 1, 1, { quest = q }) }
    local f, w = world_of(rows, nil, nil, qname)
    calls = {}
    w:refresh(0, true, reveal ~= nil and { chests = true, reveal_gate_names = reveal } or on("chests"))
    return find(w:input().chests, "q1").quest_text
  end
  local nm = { [1] = "X", [2] = "Y", [3] = "Z", [4] = "another quest", [5] = "another quest" }
  check("text: one after", text({ any = false, q = { { 1, true } } }, nm) == "after X")
  check("text: one until", text({ any = false, q = { { 1, false } } }, nm) == "until X ends, missable")
  check("text: any of two", text({ any = true, q = { { 1, true }, { 2, true } } }, nm) == "after X or Y")
  check("text: all of two", text({ any = false, q = { { 1, true }, { 2, true } } }, nm) == "after X and Y")
  check("text: three", text({ any = true, q = { { 1, true }, { 2, true }, { 3, true } } }, nm) == "after X or Y, ...")
  check("text: names deduped", text({ any = false, q = { { 4, true }, { 5, true } } }, nm) == "after another quest")
  check("text: until two", text({ any = true, q = { { 1, false }, { 2, false } } }, nm) == "until X or Y end, missable")
  check("text: var without names", text({ any = false, q = {}, var = true }, nm) == "quest-gated")
  text({ any = false, q = { { 1, true } } }, nm, true)
  check("text: reveal passed true", #calls >= 1 and calls[1].reveal == true and calls[1].qid == 1)
  text({ any = false, q = { { 1, true } } }, nm, false)
  check("text: reveal passed false", #calls >= 1 and calls[1].reveal == false)
  text({ any = false, q = { { 1, true } } }, nm)
  check("text: reveal nil treated as false", #calls >= 1 and calls[1].reveal == false)

  -- fix round 1: a missing or raising core.gate_name must not drop the round
  do
    local function round_with(gn)
      core.gate_name = gn
      local f, w = world_of({
        prow("chest", "plain", 10, 1, 1, {}),
        prow("chest", "qc", 10, 2, 2, { quest = { any = false, q = { { 1, true } } } }) })
      w:refresh(0, true, on("chests"))
      local ch = w:input() and w:input().chests
      return ch, f
    end
    local ch = round_with(nil)
    check("gate_name nil: plain chest survives", ch ~= nil and find(ch, "plain") ~= nil)
    check("gate_name nil: quest chest reads another quest",
      ch ~= nil and find(ch, "qc") ~= nil and find(ch, "qc").quest_text == "after another quest")
    ch = round_with(function() error("boom") end)
    check("gate_name raises: plain chest survives", ch ~= nil and find(ch, "plain") ~= nil)
    check("gate_name raises: quest chest reads another quest",
      ch ~= nil and find(ch, "qc") ~= nil and find(ch, "qc").quest_text == "after another quest")
    ch = round_with(function() return 5 end)
    check("gate_name non-string: another quest",
      ch ~= nil and find(ch, "qc").quest_text == "after another quest")
    ch = round_with(function() return "" end)
    check("gate_name empty: another quest",
      ch ~= nil and find(ch, "qc").quest_text == "after another quest")
    core.gate_name = function(qid, adapter, reveal) return adapter.quest_name(qid) or "another quest" end
  end

  -- fix round 1: a failing round is logged once per distinct message
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "p", 10, 1, 1, { items = { { id = 7, n = 1 } } }) }) } })
    f.logs = {}
    f.io.log = function(m) f.logs[#f.logs + 1] = m end
    local w = f.new()
    f.afail.item_name = true
    w:refresh(0, true, on("chests"))
    w:refresh(10, true, on("chests"))
    local n = 0
    for _, m in ipairs(f.logs) do if tostring(m):find("round failed", 1, true) then n = n + 1 end end
    check("round error: logged once per distinct message", n == 1)
  end

  -- fix round 1: a learned chest reloaded from disk at a moved position
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "m1", 10, 1, 1, { items = { { id = 77, n = 1 } }, trap = true, pawn = true,
        quest = { any = true, q = { { 1, true } } } }) }),
      [K.ATLAS] = { version = K.FILE_VERSION, pak = "1:1", entries = {
        m1 = { k = "chest", id = 10, x = 50, y = 0, z = 60 } } } } })
    local w = f.new()
    w:refresh(0, true, on("chests"))
    local c = find(w:input().chests, "m1")
    check("reloaded: moved position and row kinds",
      c ~= nil and c.pos.x == 50 and kinds_of(c) == "kept,quest,trap,pawn")
  end

  -- fix round 1: a chest with no static row
  do
    local f, w = world_of({}, { { key = "n2_0", picked = false, keep = true } })
    f.data.reserved = { chest_row("n1", 10, 10, 1, 692), chest_row("n2", 20, 20, 2, 10) }
    w:refresh(0, true, on("chests"))
    local ch = w:input().chests
    check("no static row: gimmick 692 is ng_shard", kinds_of(find(ch, "n1")) == "ng_shard")
    check("no static row: keep-true record gives kept", kinds_of(find(ch, "n2")) == "kept")
  end

  -- fix round 1: mixed finish checks use the after wording
  check("text: mixed finish checks say after",
    text({ any = false, q = { { 1, true }, { 2, false } } }, nm) == "after X and Y")

  core.gate_name = saved_gate

  -- the real core.gate_name across the lane seam: the full name only
  -- with reveal_gate_names on, never an id
  do
    local rows = { prow("chest", "g1", 10, 1, 1,
      { quest = { any = false, q = { { 11020, true } } } }) }
    local _, w = world_of(rows, nil, nil, { [11020] = "Agamen Dig" })
    w:refresh(0, true, on("chests"))
    check("real gate_name: hidden name", find(w:input().chests, "g1").quest_text
      == "after another quest")
    local _, w2 = world_of(rows, nil, nil, { [11020] = "Agamen Dig" })
    w2:refresh(0, true, on("chests", "reveal_gate_names"))
    check("real gate_name: revealed name", find(w2:input().chests, "g1").quest_text
      == "after Agamen Dig")
  end
end

-- 29. per-step round timing (SPEC 28.5.2)
do
  local function timed_world()
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chara", "m5", 5, 0, 0, { name = "ch253000_00" }) }) } })
    local d = f.data
    d.boss = { ch253 = true }
    d.catalog = { 1 }
    d.cast = { [1] = { 2058, 2059 } }
    d.sched_ids = { 2058, 2059 }
    d.shop = { [2058] = 41, [2059] = 42 }
    d.sched = { [2058] = P(100, 0, 100), [2059] = P(200, 0, 100) }
    d.shops = { [41] = { { item = 378, release_qid = 0 } },
      [42] = { { item = 379, release_qid = 0 } } }
    d.reserved = { chest_row("c1", 10, 10) }
    return f, f.new()
  end
  local ALLS = { chests = true, treasure = true, tokens = true, beetles = true,
    monsters = true, sellers = true, search = true, shops = true }
  local STEPS = { "cast", "boss", "loaded_boss", "reserved", "sort", "learn", "loaded",
    "patched", "settlements", "schedule", "records", "seen", "effective", "collect",
    "discovery", "treasure", "shop_index", "sellers", "monsters", "drops", "npcs",
    "route" }
  local f, w = timed_world()
  w:refresh(0, true, ALLS)
  w:refresh(0, true, ALLS)
  local st = w:stats()
  for _, n in ipairs(STEPS) do
    check("step: " .. n, type(st.ms["step_" .. n]) == "number")
  end
  w:refresh(10, true, on("chests", "tokens", "beetles"))
  st = w:stats()
  check("step: cleared", st.ms.step_monsters == nil and st.ms.step_drops == nil
    and st.ms.step_npcs == nil and st.ms.step_shop_index == nil)
  check("step: still timed", type(st.ms.step_collect) == "number")

  -- schedule_pos is a per-round total over every call, the loop's included
  local f2 = fixture()
  local d2 = f2.data
  d2.catalog = { 1 }
  d2.cast = { [1] = { 2058, 2059 } }
  d2.sched_ids = { 2058, 2059 }
  d2.shop = { [2058] = 41, [2059] = 42 }
  d2.sched = { [2058] = P(100, 0, 100), [2059] = P(200, 0, 100) }
  d2.shops = { [41] = { { item = 378, release_qid = 0 } },
    [42] = { { item = 379, release_qid = 0 } } }
  d2.alive = false
  d2.needs = { [100] = { { id = 378, num = 1 } } }
  local inner = f2.reads.schedule_pos
  f2.reads.schedule_pos = function(cid)
    f2.clock_t = f2.clock_t + 0.001
    return inner(cid)
  end
  local w2 = f2.new()
  w2:refresh(0, true, { shops = true, sellers = true })
  local calls = f2.reads_n.schedule_pos
  local sp = w2:stats().ms.schedule_pos
  check("schedule_pos total", type(sp) == "number" and calls > 2
    and math.abs(sp - calls * 1.0) < 1e-6)
  w2:refresh(10, true, { shops = true, sellers = true })
  local calls2 = f2.reads_n.schedule_pos - calls
  check("schedule_pos cleared per round",
    math.abs(w2:stats().ms.schedule_pos - calls2 * 1.0) < 1e-6)
end

-- 30. round caches (SPEC 28.5.3)
do
  local function cache_world()
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "f1", 10, 1, 1),
      prow("chest", "f2", 10, 2, 2, { src = "subquest" }),
      prow("chara", "m1", 1, 100, 0, { name = "ch253000_00" }) }) } })
    f.data.boss = { ch253 = true }
    f.data.catalog = { 1 }
    f.data.cast = { [1] = { 2058 } }
    return f, f.new()
  end

  -- effective(): merged once per change
  do
    local f, w = cache_world()
    w:refresh(0, true, ALL)
    local b0 = w:stats().eff_builds
    check("eff counter wired", b0 == 1)
    w:refresh(10, true, ALL)
    check("eff cached", w:stats().eff_builds - b0 == 0)
    f.data.reserved = { chest_row("n1", 50, 50) }
    w:refresh(20, true, ALL)
    check("eff learn rebuilds", w:stats().eff_builds - b0 == 1)
    check("eff learn shows the new chest", find(w:input().chests, "n1") ~= nil)
    w:refresh(30, true, ALL)
    check("eff cached after learn", w:stats().eff_builds - b0 == 1)

    -- a live-only row changing does not rebuild, and shows the change
    f.data.reserved = { chest_row("f2", 5, 5) }
    w:refresh(40, true, ALL)
    local b1 = w:stats().eff_builds
    local c1 = find(w:input().chests, "f2")
    check("eff live row shown", c1 ~= nil and c1.pos.x == 5)
    f.data.reserved = { chest_row("f2", 9, 9) }
    w:refresh(50, true, ALL)
    local c2 = find(w:input().chests, "f2")
    check("eff live row change shown", c2 ~= nil and c2.pos.x == 9)
    check("eff live row change does not rebuild", w:stats().eff_builds - b1 == 0)
    f.data.reserved = {}
    w:refresh(60, true, ALL)
    check("eff live row gone", find(w:input().chests, "f2") == nil)
    check("eff live row gone does not rebuild", w:stats().eff_builds - b1 == 0)
  end

  -- one live row: same output as the same row in the places file
  do
    local function chest_uids(live)
      local rows = { prow("chest", "a1", 10, 1, 1), prow("chest", "c1", 10, 9, 9) }
      if not live then
        rows[#rows + 1] = prow("chest", "b1", 10, 5, 5)
        rows[#rows + 1] = prow("chest", "z1", 10, 20, 20)
      end
      local f = fixture({ files = { [K.PLACES] = places(rows) } })
      if live then
        rows[#rows + 1] = prow("chest", "z1", 10, 0, 0, { src = "subquest" })
        f.data.reserved = { chest_row("b1", 5, 5), chest_row("z1", 20, 20) }
        -- a listed-but-not-file row (subquest) is the live-only case
        rows[#rows + 1] = prow("chest", "b1", 10, 0, 0, { src = "subquest" })
      end
      local w = f.new()
      w:refresh(0, true, ALL)
      w:refresh(10, true, ALL)
      local t = {}
      for _, c in ipairs(w:input().chests) do t[#t + 1] = c.uid .. "@" .. c.pos.x end
      return table.concat(t, ","), w
    end
    local want = chest_uids(false)
    local got, w = chest_uids(true)
    check("live one row: same output as a file row", got == want)
    check("live one row: sorted between the cached uids", got == "a1@1.0,b1@5.0,c1@9.0,z1@20.0")
    local b0 = w:stats().eff_builds
    w:refresh(20, true, ALL)
    check("live one row: cache hit kept", w:stats().eff_builds == b0)
  end

  -- a live monster row over a uid the merge already holds: the live row wins
  do
    local f = fixture({ files = {
      [K.PLACES] = places({ prow("chara", "ov1", 5, 1, 1, { name = "ch299000_00" }),
        prow("chest", "c1", 10, 9, 9) }),
      [K.ATLAS] = { version = K.FILE_VERSION, pak = "1:1", entries = {
        ov1 = { k = "monster", id = 5, x = 1, y = 0, z = 1, name = "ch299000_00", table_ix = 1 } } } } })
    f.data.boss = { ch253 = true }
    f.data.reserved = { mrow("ov1", 5, "ch220000_00", 500, 500) }
    local w = f.new()
    w:refresh(0, true, ALL)
    w:refresh(10, true, ALL)
    local m = w:input().monsters
    check("live row over a learned uid: live row wins", #m == 1 and m[1].pos.x == 500)
  end

  -- reset invalidates the merge: no file monsters while the cast is unavailable
  do
    local f, w = cache_world()
    w:refresh(0, true, ALL)
    check("eff reset: file monster before", #w:input().monsters == 1)
    local b0 = w:stats().eff_builds
    w:reset()
    f.afail.catalog_ids = true
    w:refresh(10, true, ALL)
    check("eff reset: rebuilt", w:stats().eff_builds - b0 == 1)
    check("eff reset: no file monsters", #w:input().monsters == 0)
  end

  -- first_seller_cid is read once per round for shops and sellers together
  do
    local function sched_calls(tg)
      local f = fixture()
      local d = f.data
      d.needs = { [100] = { { id = 378, num = 1 } } }
      d.iname = { [378] = "Grimoire" }
      d.sched_ids = { 2058, 2059 }
      d.shop = { [2058] = 41, [2059] = 42 }
      d.npcname = { [2058] = "Dudley", [2059] = "Ana" }
      d.sched = { [2058] = P(100, 0, 100), [2059] = P(200, 0, 100) }
      d.alive = false
      d.shops = { [41] = { { item = 378, release_qid = 0 } },
        [42] = { { item = 379, release_qid = 0 } } }
      local w = f.new()
      w:refresh(0, true, tg)
      return f.reads_n.schedule_pos or 0, w
    end
    local both, wb = sched_calls({ shops = true, sellers = true })
    local alone = sched_calls({ shops = true })
    check("fsc: sellers appeared", #wb:input().sellers == 1)
    check("fsc: shops with sellers reads as shops alone", both == alone and alone > 0)

    -- the memo is per round: a seller that moves moves its markers
    local f = fixture()
    local d = f.data
    d.needs = { [100] = { { id = 378, num = 1 } } }
    d.iname = { [378] = "Grimoire" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.alive = false
    d.shops = { [41] = { { item = 378, release_qid = 0 } } }
    local w = f.new()
    local tg = { shops = true, sellers = true }
    w:refresh(0, true, tg)
    check("fsc: first position", w:input().shops[1].pos.x == 100
      and w:input().sellers[1].pos.x == 100)
    d.sched[2058] = P(200, 0, 200)
    w:poke()
    w:refresh(1, true, tg)
    check("fsc: memo is per round, shop", w:input().shops[1].pos.x == 200)
    check("fsc: memo is per round, seller", w:input().sellers[1].pos.x == 200)
  end

  -- item lists: kept per key, rebuilt on a changed id list or a fallback name
  do
    local nm = { [5] = "Potion", [6] = "Tonic" }
    local cache = {}
    local function name_of(id) return nm[id] or ("Item " .. id) end
    local l1, b1 = world.item_list(cache, "k", { { id = 5, n = 1 } }, name_of)
    check("item_list: first build", b1 == true and l1[1].name == "Potion")
    local l2, b2 = world.item_list(cache, "k", { { id = 5, n = 1 } }, name_of)
    check("item_list: kept", b2 == false and l2 == l1)
    local l3, b3 = world.item_list(cache, "k", { { id = 5, n = 1 }, { id = 6, n = 1 } }, name_of)
    check("item_list: ids {5} then {5,6} rebuilds", b3 == true and #l3 == 2)
    local _, b4 = world.item_list(cache, "k", { { id = 5, n = 1 }, { id = 7, n = 1 } }, name_of)
    check("item_list: a changed id rebuilds", b4 == true)
    local _, b5 = world.item_list(cache, "k", { { id = 5, n = 1 }, { id = 7, n = 1 } }, name_of)
    check("item_list: fallback name retries", b5 == true)
    nm[7] = "Elixir"
    local l6, b6 = world.item_list(cache, "k", { { id = 5, n = 1 }, { id = 7, n = 1 } }, name_of)
    check("item_list: retry takes the real name", b6 == true and l6[2].name == "Elixir")
    local _, b7 = world.item_list(cache, "k", { { id = 5, n = 1 }, { id = 7, n = 1 } }, name_of)
    check("item_list: kept after the real name", b7 == false)
  end

  -- chests and treasure through the round: a fallback name, then the real one
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "f1", 10, 1, 1, { items = { { id = 5, n = 1 } } }) }) } })
    f.data.iname = { [5] = "Item 5" }
    f.data.nodes = { { name = "Node A", pos = P(1, 0, 1) } }
    local w = f.new()
    local tg = on("chests", "treasure")
    w:refresh(0, true, tg)
    local b0 = w:stats().item_list_builds
    check("item lists counter wired", b0 == 2)
    check("item retry: fallback shown first", find(w:input().chests, "f1").items[1].name == "Item 5")
    f.data.iname[5] = "Potion"
    w:refresh(10, true, tg)
    local b1 = w:stats().item_list_builds
    check("item retry", find(w:input().chests, "f1").items[1].name == "Potion")
    check("item retry: treasure", w:input().treasure[1].items[1].name == "Potion")
    check("item retry rebuilt once each", b1 - b0 == 2)
    w:refresh(20, true, tg)
    check("item list kept", w:stats().item_list_builds - b1 == 0)
    check("item list kept: still named", find(w:input().chests, "f1").items[1].name == "Potion")
  end
end

-- 31. wants_round, hold, run-again flag (SPEC 28.6, 28.7.1, 28.8.1)
do
  check("wants: first_token alone", world.wants_round({ first_token = true }) == true)
  check("wants: none", world.wants_round({}) == false)
  for _, k in ipairs({ "chests", "treasure", "tokens", "beetles", "monsters", "sellers",
    "search", "shops" }) do
    check("wants: " .. k, world.wants_round({ [k] = true }) == true)
  end
  check("wants: unrelated toggle", world.wants_round({ reveal_gate_names = true }) == false)
  check("wants: members", world.wants_round({}, 1) == true)
  check("wants: zero members", world.wants_round({}, 0) == false)
  check("wants: focus", world.wants_round({ focus = { active = { 1 }, quests = {} } }) == true)
  check("wants: focus not a table", world.wants_round({ focus = true }) == false)

  local function held_world()
    local f = fixture()
    f.data.reserved = { chest_row("c1", 10, 10) }
    return f, f.new()
  end
  local TG = on("chests")
  local f, w = held_world()
  check("hold: first round runs", w:refresh(0, true, TG, true) == true)
  check("hold: counter starts at zero", w:stats().held_rounds == 0)
  check("hold: inside the throttle, nothing", w:refresh(3, true, TG, true) == false)
  check("hold: inside the throttle, not counted", w:stats().held_rounds == 0)
  local n = w:stats().rounds
  check("hold: throttle elapsed, skipped", w:refresh(10, true, TG, true) == false
    and w:stats().rounds == n)
  check("hold: throttle elapsed, counted", w:stats().held_rounds == 1)
  check("hold: counted per call", w:refresh(11, true, TG, true) == false
    and w:stats().held_rounds == 2)
  check("hold: released runs at once", w:refresh(12, true, TG) == true)
  check("hold: no hold, throttle as before", w:refresh(13, true, TG) == false
    and w:stats().held_rounds == 2)

  -- a cleared throttle still runs under hold, once
  w:poke()
  check("hold: poke runs once", w:refresh(14, true, TG, true) == true)
  check("hold: then held again", w:refresh(30, true, TG, true) == false)
  w:set_route(2058, "Dudley")
  check("hold: set_route runs once", w:refresh(31, true, TG, true) == true)
  check("hold: and then not again", w:refresh(32, true, TG, true) == false)
  if type(w.set_routes) == "function" then
    w:set_routes({ { cid = 2058, name = "Dudley" }, { cid = 2059, name = "Ee" } })
    check("hold: set_routes change runs once", w:refresh(33, true, TG, true) == true)
    w:set_routes({ { cid = 2058, name = "Dudley" }, { cid = 2059, name = "Ee" } })
    check("hold: unchanged set_routes holds", w:refresh(34, true, TG, true) == false)
  end

  -- a changed NPC list under search runs inside the throttle
  local f2, w2 = held_world()
  local STG = { search = true, npc_cids = { 1 } }
  check("hold: search round", w2:refresh(0, true, STG, true) == true)
  check("hold: same list inside the throttle", w2:refresh(2, true,
    { search = true, npc_cids = { 1 } }, true) == false)
  check("hold: changed list runs", w2:refresh(3, true,
    { search = true, npc_cids = { 2 } }, true) == true)
  check("hold: changed list not counted as held", w2:stats().held_rounds == 0)

  -- the run-again flag: the unfinished NPC name list
  do
    local f3 = fixture()
    f3.data.sched_ids = {}
    for i = 1, K.NPC_NAME_SLICE + 3 do
      f3.data.sched_ids[i] = 5000 + i
      f3.data.npcname[5000 + i] = "N" .. i
    end
    local w3 = f3.new()
    check("again: first slice runs", w3:refresh(0, true, { search = true }) == true)
    check("again: unfinished list runs inside the throttle, even held",
      w3:refresh(0, true, { search = true }, true) == true)
    check("again: finished list waits for the throttle",
      w3:refresh(1, true, { search = true }, true) == false)
  end
  -- ids unavailable: the list never finishes, and must not loop every tick
  do
    local f4 = fixture()
    f4.fail.schedule_ids = true
    local w4 = f4.new()
    w4:refresh(0, true, { search = true })
    check("again: no ids does not loop", w4:refresh(1, true, { search = true }) == false)
  end
end

-- 32. toggle costs, small monsters, kept-set pin (SPEC 28.7.1, 28.10.1, 28.12.2)
do
  local function cost_world()
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "f1", 10, 1, 1, { items = { { id = 5, n = 1 } } }),
      prow("token", "t1", K.TOKEN_ID, 2, 2),
      prow("beetle", "b1", K.BEETLE_ID, 3, 3),
      prow("chara", "m1", 1, 100, 0, { name = "ch253000_00" }),
      prow("chara", "m2", 2, 104, 0, { name = "ch253000_00" }),
      prow("chara", "s1", 3, 400, 0, { name = "ch220000_00" }),
      prow("chara", "s2", 4, 402, 0, { name = "ch220000_00" }),
      prow("chara", "s3", 5, 900, 0, { name = "ch221000_00" }) }) } })
    local d = f.data
    d.boss = { ch253 = true }
    d.catalog = { 1 }
    d.cast = { [1] = { 2058 } }
    d.iname = { [378] = "Grimoire", [5] = "Potion" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.alive = false
    d.shops = { [41] = { { item = 378, release_qid = 0 } } }
    d.needs = { [100] = { { id = 378, num = 1 } } }
    d.nodes = { { name = "Node A", pos = P(1, 0, 1) } }
    d.records = { { key = "f1", guid = "f1", picked = false } }
    d.loaded_boss = {}
    d.respawn = { { key = "r1_0", cid = 1001, cid_name = "ch253000_00", pos = P(10, 0, 10) },
      { key = "r2_0", cid = 1002, cid_name = "ch220000_00", pos = P(700, 0, 700) } }
    return f, f.new()
  end
  local BASE = { chests = true, treasure = true, tokens = true, beetles = true,
    monsters = true, small_monsters = true, sellers = true, shops = true }
  local function run(drop, add)
    local tg = {}
    for k, v in pairs(BASE) do tg[k] = v end
    for _, k in ipairs(drop or {}) do tg[k] = nil end
    for k, v in pairs(add or {}) do tg[k] = v end
    local f, w = cost_world()
    w:refresh(0, true, tg)
    return f, w
  end

  local f, w = run({ "treasure" })
  check("cost: treasure off, nodes", (f.reads_n.treasure_nodes or 0) == 0)
  check("cost: treasure off, checked", (f.reads_n.checked_nodes or 0) == 0)
  f, w = run()
  check("cost: treasure on reads", f.reads_n.treasure_nodes == 1 and f.reads_n.checked_nodes == 1)

  f, w = run({ "monsters", "small_monsters" })
  check("cost: monsters off, respawn", (f.reads_n.respawn_units or 0) == 0)
  check("cost: monsters off, loaded boss", (f.reads_n.loaded_boss_families or 0) == 0)
  f, w = run()
  check("cost: monsters on reads", f.reads_n.respawn_units == 1
    and f.reads_n.loaded_boss_families == 1)

  f, w = run({ "sellers" })
  check("cost: sellers off, needs", (f.adapter_n.item_needs or 0) == 0)
  check("cost: sellers off, locations", (f.adapter_n.item_locations or 0) == 0)
  f, w = run()
  check("cost: sellers on reads", f.adapter_n.item_needs == 1 and f.adapter_n.item_locations == 1)

  f, w = run({ "shops" })
  check("cost: shops off, no index", w:stats().shop_index_runs == 0)
  f, w = run()
  check("cost: shops on, one index run", w:stats().shop_index_runs == 1)
  f, w = run({ "shops" }, { search = true })
  check("cost: search alone runs the index", w:stats().shop_index_runs == 1)

  f, w = run({ "chests" })
  check("cost: chests off, no kinds", w:stats().chest_kinds_calls == 0)
  f, w = run()
  check("cost: chests on, kinds computed", w:stats().chest_kinds_calls > 0)

  f, w = run({ "chests", "tokens", "beetles" })
  check("cost: records off, no read", (f.reads_n.save_records or 0) == 0)
  f, w = run({ "tokens", "beetles" })
  check("cost: chests alone read records", f.reads_n.save_records == 1)

  -- small monsters
  local function shape(out)
    local t = {}
    for _, m in ipairs(out.monsters) do
      t[#t + 1] = m.uid .. ":" .. m.count .. ":" .. tostring(m.small)
    end
    table.sort(t)
    return table.concat(t, ",")
  end
  local function only(small)
    local t = {}
    for _, m in ipairs(small.list) do
      if (m.small == true) == small.want then t[#t + 1] = m.uid .. ":" .. m.count end
    end
    table.sort(t)
    return table.concat(t, ",")
  end
  local _, wb = run()
  local both = wb:input()
  local large_ref = only({ list = both.monsters, want = false })
  local small_ref = only({ list = both.monsters, want = true })
  check("small: fixture has both classes", large_ref ~= "" and small_ref ~= "")
  local fo, wo = run({ "small_monsters" })
  check("small off: skipped", only({ list = wo:input().monsters, want = true }) == "")
  check("small off: large clusters same", only({ list = wo:input().monsters, want = false })
    == large_ref)
  local fs, ws = run({ "monsters" })
  check("small only: large clusters none", only({ list = ws:input().monsters, want = false }) == "")
  check("small only: small clusters same", only({ list = ws:input().monsters, want = true })
    == small_ref)
  check("small only: respawn units read", fs.reads_n.respawn_units == 1
    and fs.reads_n.loaded_boss_families == 1)
  check("small only: wants_round", world.wants_round({ small_monsters = true }) == true)
  local fn, wn = run({ "monsters", "small_monsters" })
  check("both off: no monsters", #wn:input().monsters == 0)

  -- drops need either toggle
  local function drops_world(tg)
    local g = fixture({ files = { [K.PLACES] = places({
      prow("chara", "s1", 5, 400, 0, { name = "ch220000_00" }) }) } })
    g.data.iname = { [230] = "Rotten Meat" }
    g.data.drops = { [5] = { 230 } }
    local gw = g.new()
    gw:refresh(0, true, tg)
    gw:refresh(0, true, tg)
    return gw
  end
  local gd = drops_world({ search = true, small_monsters = true })
  check("small only: drops published", gd:input().drops ~= nil and gd:input().drops[5] ~= nil)
  check("drops: neither toggle, none", drops_world({ search = true }):input().drops == nil)

  -- 38a pin: a reserved large-class row whose places chara row is neither
  -- large nor small is live-only (never learned, never saved)
  do
    local g = fixture({ files = { [K.PLACES] = places({
      prow("chara", "r1", 1, 100, 0, { name = "ch410000_00" }) }) } })
    g.data.boss = { ch253 = true }
    g.data.catalog = { 1 }
    g.data.cast = { [1] = {} }
    g.data.reserved = { mrow("r1", 1, "ch253000_00", 100, 0) }
    local gw = g.new()
    local before = gw:stats().atlas.learned
    gw:refresh(0, true, on("monsters"))
    check("38a pin: draws that round", #gw:input().monsters == 1)
    check("38a pin: not learned", gw:stats().atlas.learned == before)
    check("38a pin: nothing to save", gw:save("test") == false and g:dumps_of(K.ATLAS) == 0)
  end
end

-- 33. the First Seeker's Token (SPEC 28.9.1-2)
do
  local UID = "72821825-5dd3-41a6-86b4-3e75e3b50e0a"
  local function token_world(seeker, rows)
    local f = fixture({ files = { [K.PLACES] = places(rows or {
      { k = "token", uid = UID, id = K.TOKEN_ID, x = -413.1, y = 100.3, z = -1961.7,
        src = "normal" },
      prow("token", "other", K.TOKEN_ID, 5, 5) }) } })
    f.data.first_seeker = seeker
    f.reads.first_seeker = function()
      f.reads_n.first_seeker = (f.reads_n.first_seeker or 0) + 1
      if f.fail.first_seeker then error("fake read failure: first_seeker") end
      return f.data.first_seeker
    end
    return f, f.new()
  end
  local FT = { first_token = true }

  local f, w = token_world(UID)
  check("tok1 round runs on the toggle alone", w:refresh(0, true, FT) == true)
  local ft = w:input().first_token
  check("tok1 published", ft ~= nil and ft.uid == UID and ft.first_seeker == true)
  check("tok1 name", ft and ft.name == "Finder's Token spot")
  check("tok1 pos", ft and ft.pos.x == -413.1 and ft.pos.y == 100.3 and ft.pos.z == -1961.7)
  check("tok1 state without records", ft and ft.state == "unknown")
  check("tok1 read once", f.reads_n.first_seeker == 1)
  check("tok1 step timed", type(w:stats().ms.step_first_token) == "number")
  check("tok1 not in the token list", #w:input().tokens == 0)

  -- with Tokens on and the save record collected
  f, w = token_world(UID)
  f.data.records = { { key = UID .. "_0", guid = UID, free_bit = 1 << K.TOKEN_BIT } }
  w:refresh(0, true, { first_token = true, tokens = true })
  check("tok1 state collected", w:input().first_token.state == "collected")
  check("tok1 token list still holds it", find(w:input().tokens, UID) ~= nil)
  local tk = find(w:input().tokens, UID)
  check("tok1 ordinary entry is marked first_seeker", tk ~= nil and tk.first_seeker == true)
  local other = find(w:input().tokens, "other")
  check("tok1 other token is not marked", other ~= nil and other.first_seeker == nil)
  local f1, w1 = token_world(UID)
  w1:refresh(0, true, { tokens = true })
  tk = find(w1:input().tokens, UID)
  check("tok1 toggle off: entry not marked", tk ~= nil and tk.first_seeker == nil)
  f.data.records = { { key = UID .. "_0", guid = UID, free_bit = 0 } }
  w:refresh(10, true, { first_token = true, tokens = true })
  check("tok1 state not collected", w:input().first_token.state == "not")

  -- an upper-case guid still matches
  f, w = token_world(UID:upper())
  w:refresh(0, true, FT)
  check("tok1 upper-case read matches", w:input().first_token ~= nil
    and w:input().first_token.uid == UID)

  -- nil read, unknown guid, failing read
  f, w = token_world(nil)
  w:refresh(0, true, FT)
  check("tok1 nil read gives none", w:input().first_token == nil)
  f, w = token_world("00000000-0000-0000-0000-000000000000")
  w:refresh(0, true, FT)
  check("tok1 no row gives none", w:input().first_token == nil)
  f, w = token_world(UID)
  f.fail.first_seeker = true
  check("tok1 failing read does not fail the round", w:refresh(0, true, FT) == true
    and w:input().first_token == nil)
  f, w = token_world(UID, { prow("chest", UID, 10, 1, 1) })
  w:refresh(0, true, FT)
  check("tok1 a row that is not a token gives none", w:input().first_token == nil)

  -- toggle off: the read is not made
  f, w = token_world(UID)
  w:refresh(0, true, on("tokens", "chests"))
  check("tok1 toggle off: no read", (f.reads_n.first_seeker or 0) == 0)
  check("tok1 toggle off: none", w:input().first_token == nil)

  -- the game read, against a fake object model
  local function obj(fields, methods)
    local o = {}
    function o:get_field(n) return fields and fields[n] end
    function o:call(n, ...)
      local m = methods and methods[n]
      if m then return m(...) end
      return nil
    end
    return o
  end
  local function guid(text)
    return obj(nil, { ["ToString()"] = function() return text end })
  end
  local singletons = {}
  local saved_sdk = sdk
  sdk = {
    get_managed_singleton = function(n) return singletons[n] end,
    find_type_definition = function() return nil end,
  }
  local R = world.game_reads()
  local function manager(exists, proof)
    singletons["app.GimmickManager"] = obj(
      { ["<FirstSeekerProof>k__BackingField"] = proof },
      { isExistFirstSeekerProof = function()
        if exists == "raise" then error("boom") end
        return exists
      end })
  end
  manager(true, obj({ _RowID = guid("72821825-5DD3-41A6-86B4-3E75E3B50E0A") }))
  check("first_seeker read: lower-case uid", R.first_seeker() == UID)
  manager(false, obj({ _RowID = guid(UID) }))
  check("first_seeker read: exist call false gives nil", R.first_seeker() == nil)
  manager(true, nil)
  check("first_seeker read: nil backing field gives nil", R.first_seeker() == nil)
  manager(true, obj({}))
  check("first_seeker read: no row id gives nil", R.first_seeker() == nil)
  manager("raise", obj({ _RowID = guid(UID) }))
  check("first_seeker read: a raise gives nil", R.first_seeker() == nil)
  singletons["app.GimmickManager"] = nil
  check("first_seeker read: no manager gives nil", R.first_seeker() == nil)
  sdk = saved_sdk
end

-- 32. reserved rows reused while the selector signature holds (SPEC 31)
do
  local function rfix(sig)
    local f = fixture()
    f.data.reserved = { chest_row("c1", 10, 10) }
    f.data.sig = sig
    return f, f.new()
  end
  local C = on("chests")
  do
    local f, w = rfix("a")
    w:refresh(0, true, C); w:refresh(10, true, C)
    check("reserved: equal signatures read once", f.reads_n.reserved_rows == 1)
    local st = w:stats()
    check("reserved: reuse round shows no read time",
      st.ms.reserved_rows == nil and st.ms.reserved_sig ~= nil
      and st.reserved_reused == 1 and st.reserved_reads == 1)
  end
  do
    local f, w = rfix("a")
    w:refresh(0, true, C); f.data.sig = "b"; w:refresh(10, true, C)
    check("reserved: changed signature reads again", f.reads_n.reserved_rows == 2)
  end
  do
    local f, w = rfix("a")
    f.reads.reserved_sig = nil
    w:refresh(0, true, C); w:refresh(10, true, C)
    check("reserved: no signature read reads every round", f.reads_n.reserved_rows == 2)
    local f2, w2 = rfix(5)
    w2:refresh(0, true, C); w2:refresh(10, true, C)
    check("reserved: a number signature reads every round", f2.reads_n.reserved_rows == 2)
  end
  do
    local f, w = rfix("a")
    f.fail.reserved_sig = true
    w:refresh(0, true, C); w:refresh(10, true, C)
    check("reserved: failing signature read reads", f.reads_n.reserved_rows == 2)
  end
  do
    local f, w = rfix("a")
    local n = {}
    w:refresh(0, true, C); n[1] = f.reads_n.reserved_rows
    w:refresh(50, true, C); n[2] = f.reads_n.reserved_rows
    w:refresh(60, true, C); n[3] = f.reads_n.reserved_rows
    check("reserved: age cap", n[1] == 1 and n[2] == 1 and n[3] == 2)
    w:refresh(70, true, C); n[4] = f.reads_n.reserved_rows
    local st = w:stats()
    check("reserved: a read restarts the age",
      n[4] == 2 and st.reserved_reads == 2 and st.reserved_reused == 2)
  end
  do
    local f, w = rfix("a")
    w:refresh(0, true, C)
    f.data.sig = "b"; f.fail.reserved_rows = true
    w:refresh(10, true, C)
    f.fail.reserved_rows = nil; f.data.sig = "a"
    w:refresh(20, true, C)
    check("reserved: failed read clears the cache",
      f.reads_n.reserved_rows == 3 and w:stats().reserved_reads == 3)
  end
  do
    local f, w = rfix("a")
    w:refresh(0, true, C); w:reset(); w:refresh(10, true, C)
    check("reserved: reset drops the cache", f.reads_n.reserved_rows == 2)
  end
  do
    local f, w = rfix("a")
    w:refresh(0, true, C)
    w:refresh(30, true, C, true)
    w:refresh(40, true, C)
    check("reserved: held refresh keeps the cache",
      f.reads_n.reserved_rows == 1 and f.reads_n.reserved_sig == 2)
  end
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "lv1", 10, 30, 30, { src = "subquest" }) }) } })
    f.data.reserved = { chest_row("lv1", 30, 30) }
    f.data.sig = "a"
    local w = f.new()
    w:refresh(0, true, C); w:refresh(10, true, C)
    check("reserved: reuse round still draws a live-only chest",
      f.reads_n.reserved_rows == 1 and find(w:input().chests, "lv1") ~= nil)
    local f2 = fixture({ files = { [K.PLACES] = places({
      prow("chara", "sq1", 5, 500, 0, { name = "ch253000_00", src = "subquest", table_qid = 12000 }),
      prow("chest", "other", 10, 9, 9) }) } })
    f2.data.boss = { ch253 = true }
    f2.data.reserved = { mrow("sq1", 5, "ch253000_00", 500, 0), chest_row("keep1", 1, 1) }
    f2.data.sig = "a"
    local w2 = f2.new()
    w2:refresh(0, true, ALL); w2:refresh(10, true, ALL)
    local m = w2:input().monsters
    check("reserved: reuse round still draws a live-only monster",
      f2.reads_n.reserved_rows == 1 and #m == 1 and m[1].pos.x == 500)
  end
  do
    local f, w = rfix("a")
    w:refresh(0, true, C)
    f.reads.reserved_sig = nil
    w:refresh(10, true, C)
    check("reserved: a round without a signature read clears its time",
      w:stats().ms.reserved_sig == nil)
  end
  do
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "p", 10, 1, 1, { items = { { id = 7, n = 1 } } }) }) } })
    f.data.reserved = { chest_row("c1", 10, 10) }
    f.data.sig = "a"
    local w = f.new()
    w:refresh(0, true, on("chests"))
    f.afail.item_name = true
    local ok2 = w:refresh(10, true, on("chests"))
    f.afail.item_name = nil
    w:refresh(20, true, on("chests"))
    local st = w:stats()
    check("reserved: a failed round counts neither", ok2 == false and st.rounds == 2
      and st.reserved_reads + st.reserved_reused == 2)
  end
end

-- 34. quest focus collection (SPEC 32.6.1)
do
  local function FQ(active, items)
    return { active = active, quests = { [active[1]] = { npcs = {}, step_npcs = {}, items = items or {}, places = {} } } }
  end
  local function cworld(tg, reserved)
    local f = fixture({ files = { [K.PLACES] = places({
      prow("chest", "g1", 10, 1, 1, { quest = { any = true, q = { { 11020, true }, { 11030, false } } } }),
      prow("chest", "i1", 10, 2, 2, { items = { { id = 77, n = 1 }, { id = 78, n = 2 } } }),
      prow("chest", "p0", 10, 3, 3, {}) }) } })
    f.data.records = { { key = "g1_0", picked = true, item = 305 } }
    f.data.reserved = reserved or {}
    local w = f.new()
    local ran = w:refresh(0, true, tg)
    return w, f, ran
  end
  local function ids_are(t, a, b) return t ~= nil and #t == 2 and t[1] == a and t[2] == b end
  local w = cworld(on("chests"))
  local ch = w:input().chests
  local g1, i1, p0 = find(ch, "g1"), find(ch, "i1"), find(ch, "p0")
  check("chest ids: gate_qids", g1 ~= nil and ids_are(g1.gate_qids, 11020, 11030))
  check("chest ids: item_ids", i1 ~= nil and ids_are(i1.item_ids, 77, 78))
  check("chest ids: none on a plain chest", p0 ~= nil and p0.gate_qids == nil and p0.item_ids == nil)
  w = cworld(on("chests"), { chest_row("i1", 5, 5) })
  i1 = find(w:input().chests, "i1")
  check("chest ids: a learned chest keeps its item_ids", i1 ~= nil and i1.pos.x == 5
    and ids_are(i1.item_ids, 77, 78))
  w = cworld({ treasure = true, focus = FQ({ 11020 }) })
  ch = w:input().chests
  g1 = find(ch, "g1")
  check("focus: gate chest with Chests off", g1 ~= nil and find(ch, "i1") == nil and find(ch, "p0") == nil)
  check("focus: its state is read", g1 ~= nil and g1.state == "opened" and g1.item == 305)
  w = cworld({ treasure = true, focus = FQ({ 55 }, { 78 }) })
  ch = w:input().chests
  check("focus: item chest with Chests off", find(ch, "i1") ~= nil and find(ch, "g1") == nil)
  w = cworld({ treasure = true, focus = FQ({ 55 }, { 305 }) })
  ch = w:input().chests
  check("focus: record item chest with Chests off", find(ch, "g1") ~= nil and find(ch, "i1") == nil)
  w = cworld({ chests = true, focus = FQ({ 11020 }) })
  ch = w:input().chests
  check("focus: Chests on still lists every chest", find(ch, "g1") ~= nil and find(ch, "i1") ~= nil
    and find(ch, "p0") ~= nil)
  local f
  w, f = cworld({ treasure = true })
  check("focus off: no chest, no records", #w:input().chests == 0 and (f.reads_n.save_records or 0) == 0)
  local okm = true
  for _, fq in ipairs({ { active = "x" }, true }) do
    local w2, _, ran = cworld({ treasure = true, focus = fq })
    okm = okm and ran == true and #w2:input().chests == 0
  end
  check("focus: malformed collects nothing", okm)
  -- the memo keys on the focus table: a new table on the same world rebuilds
  do
    local wf = cworld({ treasure = true, focus = FQ({ 11020 }) })
    local tgf = { treasure = true, focus = FQ({ 11020 }) }
    wf:refresh(1, true, tgf)
    wf:poke()
    local c1 = wf:input().chests
    local ok1 = find(c1, "g1") ~= nil and find(c1, "i1") == nil
    tgf.focus = FQ({ 55 }, { 78 })
    wf:poke()
    wf:refresh(2, true, tgf)
    local c2 = wf:input().chests
    check("focus: a new focus table on the same world rebuilds the sets",
      ok1 and find(c2, "i1") ~= nil and find(c2, "g1") == nil)
  end
  local w4, f4 = cworld({ treasure = true, focus = { active = { "x" }, quests = {} } })
  check("focus: no-number list reads no records", #w4:input().chests == 0 and (f4.reads_n.save_records or 0) == 0)
  local function sworld(tg)
    local f2 = fixture()
    local d = f2.data
    d.needs = { [100] = { { id = 378, num = 1 } }, [90] = { { id = 378, num = 1 } } }
    d.qname = { [90] = "Ninety", [100] = "Hundred" }
    d.iname = { [378] = "Grimoire" }
    d.sched_ids = { 2058 }
    d.shop = { [2058] = 41 }
    d.npcname = { [2058] = "Dudley" }
    d.sched = { [2058] = P(100, 0, 100) }
    d.shops = { [41] = { { item = 378, release_qid = 0, sentiment_bit = 0,
      total_pay = 0, flag = 0, var_cond = 0 } } }
    local w2 = f2.new()
    w2:refresh(0, true, tg)
    return w2:input().sellers or {}
  end
  local s = sworld({ treasure = true, focus = FQ({ 90 }) })
  check("focus: related seller with Sellers off", #s == 1 and s[1].qids[1] == 90 and s[1].qids[2] == 100)
  check("focus: unrelated seller dropped", #sworld({ treasure = true, focus = FQ({ 55 }) }) == 0)
  check("focus: Sellers on lists all", #sworld({ sellers = true, focus = FQ({ 55 }) }) == 1)
  local f3 = fixture()
  f3.new():refresh(0, true, { focus = FQ({ 90 }) })
  check("focus: focus alone refreshes discovery", (f3.reads_n.discovered_count or 0) >= 1)
end

-- 35. focus key positions (SPEC 32.7.5)
do
  local function kfix()
    local f = fixture()
    f.reads.key_pos = function(k)
      f.reads_n.key_pos = (f.reads_n.key_pos or 0) + 1
      if f.fail.key_pos then error("x") end
      return f.data.kpos[k]
    end
    f.data.kpos = { [2302] = P(1, 2, 3) }
    return f
  end
  local function fps(w) return (w:input() or {}).focus_places end
  local f = kfix()
  local w = f.new()
  local tg = { treasure = true, focus_keys = { 2302, 2309, 2302, 2309 } }
  w:refresh(0, true, tg)
  local fp = fps(w) or {}
  check("focus places: resolved key", fp[2302] ~= nil and fp[2302].x == 1 and fp[2302].y == 2
    and fp[2302].z == 3)
  check("focus places: unresolved key absent", fps(w) ~= nil and fp[2309] == nil)
  check("focus places: one read per key per round", f.reads_n.key_pos == 2)
  w:poke()
  w:refresh(0, true, tg)
  check("focus places: found keys cached", f.reads_n.key_pos == 3)
  f.data.kpos[2309] = P(4, 5, 6)
  w:poke()
  w:refresh(0, true, tg)
  fp = fps(w) or {}
  check("focus places: a later read resolves", fp[2309] ~= nil and fp[2309].x == 4)
  local n = f.reads_n.key_pos or 0
  w:reset()
  w:refresh(0, true, tg)
  check("focus places: reset drops the cache", f.reads_n.key_pos == n + 2)
  n = f.reads_n.key_pos or 0
  w:poke()
  w:refresh(0, true, { treasure = true })
  check("focus places: no list, no table, no read", fps(w) == nil and (f.reads_n.key_pos or 0) == n)
  w:poke()
  w:refresh(0, true, { treasure = true, focus_keys = { 0, -1, 1.5, "x" } })
  check("focus places: bad keys skipped", (f.reads_n.key_pos or 0) == n
    and next(fps(w) or { 0 }) == nil)
  local f2 = kfix()
  f2.fail.key_pos = true
  local w2 = f2.new()
  local ran = w2:refresh(0, true, tg)
  check("focus places: raising read", ran == true and next(fps(w2) or { 0 }) == nil)
  local f3 = kfix()
  f3.data.kpos = { [2302] = { x = "a", y = 2, z = 3 } }
  local w3 = f3.new()
  w3:refresh(0, true, { treasure = true, focus_keys = { 2302 } })
  check("focus places: malformed position not published", next(fps(w3) or { 0 }) == nil)
  w3:poke()
  w3:refresh(0, true, { treasure = true, focus_keys = { 2302 } })
  check("focus places: malformed position not cached", f3.reads_n.key_pos == 2)
end

-- 36. objective place/source snapshots and generation-atomic route handoff
do
  local f = fixture()
  f.reads.key_pos = function(key)
    f.reads_n.key_pos = (f.reads_n.key_pos or 0) + 1
    if f.fail.key_pos then error("key position unreadable") end
    return f.data.kpos and f.data.kpos[key]
  end
  f.reads.area_nodes = function(row)
    f.reads_n.area_nodes = (f.reads_n.area_nodes or 0) + 1
    f.data.area_rows_seen = f.data.area_rows_seen or {}
    f.data.area_rows_seen[#f.data.area_rows_seen + 1] = row.area
    f.data.last_area_row = row
    if f.fail.area_nodes then error("area nodes unreadable") end
    return f.data.area_nodes and f.data.area_nodes[row.area]
  end
  f.data.kpos = { [77] = P(10, 20, 30) }
  f.data.area_nodes = { [0] = { P(40, 50, 60) }, [7] = { P(70, 80, 90) } }
  local base_providers = {
    { provider = "placed", generation = 4, status = "unknown",
      reason = "objective_source_scan_not_performed", candidates = {} },
    { provider = "chest", generation = 4, status = "unknown",
      reason = "objective_source_scan_not_performed", candidates = {} },
    { provider = "loot", generation = 4, status = "unknown",
      reason = "objective_source_scan_not_performed", candidates = {} },
  }
  f.adapter.objective_item_source_snapshots = function()
    f.adapter_n.objective_item_source_snapshots = (f.adapter_n.objective_item_source_snapshots or 0) + 1
    return base_providers
  end
  local w = f.new()
  local task = { need_generation = 4, journal_generation = 2, quests = { { qid = 30040, task_index = 0,
    read_status = "ok", live_destination = nil, item_ownership = {},
    task_destinations = {
      { kind = "place", task_index = 0, destination_index = 2,
        target = { place = { kind = "local_area", local_area = 0 } }, eligibility = "eligible" },
      { kind = "place", task_index = 0, destination_index = 3,
        target = { place = { kind = "key_location", key = 77 } }, eligibility = "eligible" },
      { kind = "place", task_index = 0, destination_index = 4,
        target = { place = { kind = "local_area", local_area = 7 } }, eligibility = "eligible" },
    }, guidance = {} } } }
  local resolved_places = w:objective_place_snapshot(task)
  local resolved_generation = resolved_places.generation
  check("objective places: local-area zero and key resolve through exact node readers",
    resolved_places ~= nil and resolved_places.status == "ok" and #resolved_places.places == 3
      and resolved_places.places[1].pos.x == 40 and resolved_places.places[2].pos.x == 10
      and resolved_places.places[1].target.kind == "local_area"
      and resolved_places.places[1].target.local_area == 0
      and resolved_places.places[2].target.kind == "key_location"
      and resolved_places.places[2].target.key == 77
      and resolved_places.places[3].target.local_area == 7
      and table.concat(f.data.area_rows_seen, ",") == "0,7"
      and f.data.last_area_row.location == nil
      and (f.reads_n.key_pos or 0) == 1 and (f.reads_n.area_nodes or 0) == 2)
  task.journal_generation = 3
  local identical_places = w:objective_place_snapshot(task)
  check("objective places: identical observations keep an independent stable generation",
    identical_places.status == "ok" and identical_places.generation == resolved_generation)
  f.data.kpos[77] = P(11, 20, 30)
  local moved_places = w:objective_place_snapshot(task)
  check("objective places: a resolved position change advances observation generation",
    moved_places.status == "ok" and moved_places.generation > identical_places.generation
      and moved_places.places[2].pos.x == 11)
  f.data.kpos[78] = P(12, 20, 30)
  task.quests[1].task_destinations[#task.quests[1].task_destinations + 1] =
    { kind = "place", task_index = 0, destination_index = 5,
      target = { place = { kind = "key_location", key = 78 } }, eligibility = "eligible" }
  local expanded_places = w:objective_place_snapshot(task)
  check("objective places: resolved content changes advance observation generation",
    expanded_places.status == "ok" and #expanded_places.places == 4
      and expanded_places.generation > moved_places.generation)
  f.fail.key_pos = true
  local unreadable = w:objective_place_snapshot(task)
  check("objective places: partial native failure is wholly unknown",
    unreadable.status == "unknown" and unreadable.reason ~= nil and #unreadable.places == 0
      and unreadable.generation > expanded_places.generation)
  local repeated_unreadable = w:objective_place_snapshot(task)
  check("objective places: identical failures keep the same observation generation",
    repeated_unreadable.status == "unknown"
      and repeated_unreadable.generation == unreadable.generation)
  f.fail.key_pos = nil
  local recovered_places = w:objective_place_snapshot(task)
  check("objective places: recovery to successful evidence advances observation generation",
    recovered_places.status == "ok" and recovered_places.generation > unreadable.generation)
  f.data.kpos[77] = nil
  local empty = w:objective_place_snapshot(task)
  check("objective places: empty node result is unknown, not an empty success",
    empty.status == "unknown" and empty.reason ~= nil and #empty.places == 0
      and empty.generation > recovered_places.generation)

  local source_task = { need_generation = 4, quests = { { qid = 1001, task_index = 1 } } }
  local source_rows = w:objective_source_snapshots(nil, source_task)
  check("objective sources: adapter diagnostic envelopes pass through as frozen unknown",
    #source_rows >= 5 and source_rows[1].provider == "placed"
      and source_rows[1].status == "unknown" and #source_rows[1].candidates == 0
      and source_rows[1].reason ~= nil)
  check("objective sources: missing snapshots cannot claim shop or seller availability",
    source_rows[4].provider == "shop" and source_rows[4].status == "unknown"
      and #source_rows[4].candidates == 0 and source_rows[4].reason ~= nil
      and source_rows[5].provider == "monster" and source_rows[5].status == "unknown"
      and #source_rows[5].candidates == 0 and source_rows[5].reason ~= nil)

  local source_generation_before = source_rows[1].generation
  source_task.need_generation = 5
  local source_rows_next_need = w:objective_source_snapshots(nil, source_task)
  check("objective sources: observation generation is independent of need_generation",
    source_generation_before ~= 4
      and source_rows_next_need[1].generation == source_generation_before)

  local sf = fixture({ files = { [K.PLACES] = places({
    prow("chara", "shop_npc", 5, 0, 0, { name = "ch220000_00" }) }) } })
  sf.data.catalog, sf.data.cast = { 1 }, { [1] = { 2058 } }
  sf.data.sched_ids, sf.data.shop = { 2058 }, { [2058] = 41 }
  sf.data.sched, sf.data.shops = { [2058] = P(100, 0, 100) }, {
    [41] = { { item = 378, release_qid = 0, sentiment_bit = 0,
      total_pay = 0, flag = 0, var_cond = 0 } },
  }
  sf.data.needs, sf.data.locs = { [100] = { { id = 378, num = 1 } } }, {}
  sf.adapter.objective_item_source_snapshots = function()
    return base_providers
  end
  local sw = sf.new()
  sw:refresh(0, true, { search = true, shops = true, sellers = true })
  local available = sw:objective_source_snapshots(nil, source_task)
  check("objective sources: legacy shop and seller display rows remain unknown",
    available[4].status == "unknown" and #available[4].candidates == 0)
  local source_generation = available[4].generation
  sf.data.shops[41][1].flag = 5
  sf.data.needs = { [100] = { { id = 379, num = 1 } } }
  sw:poke()
  sw:refresh(5, true, { search = true, shops = true, sellers = true })
  local changed_source = sw:objective_source_snapshots(nil, source_task)
  check("objective sources: locked legacy display rows still cannot prove offer stock",
    changed_source[4].status == "unknown" and #changed_source[4].candidates == 0
      and changed_source[4].generation == source_generation)
  sf.fail.shops = true
  sf.afail.item_needs = true
  sw:poke()
  sw:refresh(10, true, { search = true, shops = true, sellers = true })
  local stale = sw:objective_source_snapshots(nil, source_task)
  check("objective sources: failed legacy seller refresh cannot create candidates",
    stale[4].status == "unknown" and #stale[4].candidates == 0)
  sf.fail.shops, sf.afail.item_needs = nil, nil
  sw:poke()
  sw:refresh(20, true, { search = true, shops = true, sellers = true })
  sw:input().shops[1].items[1].id = nil
  local partial = sw:objective_source_snapshots(nil, source_task)
  check("objective sources: partial legacy shop rows cannot create candidates",
    partial[4].status == "unknown" and #partial[4].candidates == 0
      and partial[4].reason ~= nil)

  local observation_fixture = fixture()
  local observed = {
    { provider = "placed", generation = 0, status = "ok", candidates = {
      { id = "p1", generation = 4, target = { cid = 2058 }, pos = P(1, 0, 1),
        eligibility = "eligible" },
    } },
    { provider = "chest", generation = 4, status = "unknown", reason = "scan_pending", candidates = {} },
    { provider = "loot", generation = 4, status = "unknown", reason = "scan_pending", candidates = {} },
  }
  observation_fixture.adapter.objective_item_source_snapshots = function() return observed end
  local observation_world = observation_fixture.new()
  local observations = observation_world:objective_source_snapshots(nil, source_task)
  local placed_generation, chest_generation = observations[1].generation, observations[2].generation
  check("objective sources: adapter generation zero fails closed and drops eligible candidates",
    observations[1].status == "unknown" and #observations[1].candidates == 0
      and placed_generation > 0 and placed_generation ~= 4)
  observed[1].generation = 4
  local normalized = observation_world:objective_source_snapshots(nil, source_task)
  check("objective sources: provider observation generations advance independently on recovery",
    normalized[1].generation > placed_generation and normalized[1].status == "ok"
      and normalized[1].candidates[1].generation == normalized[1].generation
      and normalized[2].generation == chest_generation)
  observed[1].candidates[1].id = "p2"
  local content_changed = observation_world:objective_source_snapshots(nil, source_task)
  check("objective sources: candidate content changes advance only that provider generation",
    content_changed[1].generation > normalized[1].generation
      and content_changed[2].generation == chest_generation)
  source_task.need_generation = 0
  local invalid_need = observation_world:objective_source_snapshots(nil, source_task)
  check("objective sources: invalid need generation advances normalized unknown observations",
    invalid_need[1].status == "unknown" and #invalid_need[1].candidates == 0
      and invalid_need[1].generation > content_changed[1].generation)
  source_task.need_generation = 4

  local envelope = { objective_generation = 9, members = {
    { route_id = 2001, cid = 2001, place = 2001, qid = 30040, kind = "npc",
      direct = false, target_key = core.target_key({ 30040, "issued_npc", 2001 }),
      ordinal = 1, pos = P(1, 0, 1), item_ids = {}, objective_generation = 9 },
    { route_id = core.objective_direct_route_id(1), qid = 30040, kind = "place", direct = true,
      target_key = core.target_key({ 30040, "task", 0, 1, "place" }), ordinal = 1,
      place = 0, pos = P(10, 20, 30), item_ids = {}, objective_generation = 9 },
  } }
  local route_tg = { search = true, player = P(0, 0, 0), focus_keys = {} }
  w:set_routes(envelope)
  local generation = w.route_gen
  w:set_routes(envelope)
  check("objective routes: same generation and membership is idempotent",
    w.route_gen == generation)
  local allocations, old_allocate = 0, core.target_registry_allocate
  core.target_registry_allocate = function(...)
    allocations = allocations + 1
    return old_allocate(...)
  end
  collectgarbage("collect")
  collectgarbage("stop")
  local mem_before = collectgarbage("count")
  for _ = 1, 500 do w:set_routes(envelope) end
  local mem_growth = collectgarbage("count") - mem_before
  collectgarbage("restart")
  core.target_registry_allocate = old_allocate
  check("objective routes: identical publication fast path avoids registry allocation",
    allocations == 0 and mem_growth < 1)
  local mixed = { objective_generation = 10, members = {
    { route_id = 2001, cid = 2001, place = 2001, qid = 30040, kind = "npc",
      direct = false, target_key = core.target_key({ 30040, "issued_npc", 2001 }),
      ordinal = 1, pos = P(1, 0, 1), item_ids = {}, objective_generation = 9 },
  } }
  w:set_routes(mixed)
  check("objective routes: mixed-generation envelopes clear old membership immediately",
    (w:input() == nil or w:input().routes == nil) and w.route_gen > generation)
  local malformed = { objective_generation = 11, members = {
    { route_id = 2001, cid = 2001, place = 2001, qid = 30040, kind = "npc",
      direct = false, target_key = "not-canonical", ordinal = 1, pos = P(1, 0, 1),
      item_ids = {}, objective_generation = 11 },
  } }
  w:set_routes(malformed)
  check("objective routes: malformed envelope cannot escape through legacy-list compatibility",
    w:input() == nil or w:input().routes == nil)
  w:set_routes({ [1] = { cid = 2001, name = "Dense prefix" },
    [3] = { cid = 2003, place = 2003, qid = 30040, kind = "npc", direct = false,
      target_key = core.target_key({ 30040, "issued_npc", 2003 }), ordinal = 3,
      pos = P(3, 0, 3), item_ids = {}, objective_generation = 12 } })
  w:refresh(0.5, true, route_tg)
  check("objective routes: sparse mixed publication rejects instead of installing a legacy prefix",
    w:input() == nil or w:input().routes == nil)
  w:set_routes({ { cid = 2001, name = "Legacy prefix" } })
  w:refresh(0.55, true, route_tg)
  w:set_routes({ { cid = 2001, name = "Legacy prefix" }, keyed = true })
  check("objective routes: keyed legacy table clears the prior publication",
    w:input() == nil or w:input().routes == nil)
  w:set_routes({ { cid = 2001, name = "Legacy prefix" },
    { cid = 2002, name = "Objective shaped", objective_generation = 12 } })
  check("objective routes: dense mixed legacy/objective array clears as a whole",
    w:input() == nil or w:input().routes == nil)
  w:set_routes({ objective_generation = 12, members = {
    { route_id = core.objective_direct_route_id(3), qid = 30040, kind = "item", direct = true,
      target_key = core.target_key({ "source", "seller:test" }), ordinal = 3, place = 0,
      pos = P(3, 0, 3), item_ids = { 378 }, objective_generation = 12 },
  } })
  w:refresh(0.6, true, route_tg)
  check("objective routes: unsupported item kind cannot enter the objective validator",
    route_in(w, core.objective_direct_route_id(3)) == nil)
  w:set_routes({ { cid = -77, place = 77, name = "Legacy place" } })
  w:refresh(0, true, route_tg)
  check("objective routes: bare legacy place list remains supported",
    route_in(w, -77) == nil)
  w:set_routes(envelope)
  w:refresh(0, true, route_tg)
  check("objective routes: valid direct publication carries its generation before stops",
    route_in(w, core.objective_direct_route_id(1)) ~= nil
      and route_in(w, core.objective_direct_route_id(1)).objective_generation == 9
      and route_in(w, core.objective_direct_route_id(1)).target_key == envelope.members[2].target_key)

  local sticky_world = fixture().new()
  local sticky_npc, sticky_direct = {}, {}
  for k, value in pairs(envelope.members[1]) do sticky_npc[k] = value end
  for k, value in pairs(envelope.members[2]) do sticky_direct[k] = value end
  sticky_npc.objective_generation, sticky_direct.objective_generation = 20, 20
  sticky_world:set_routes({ objective_generation = 20, members = { sticky_npc, sticky_direct } })
  sticky_world:refresh(0, true, route_tg)
  local sticky_ids = { 2001, core.objective_direct_route_id(1) }
  local sticky_before = { route_in(sticky_world, sticky_ids[1]).slot,
    route_in(sticky_world, sticky_ids[2]).slot }
  sticky_npc.objective_generation, sticky_direct.objective_generation = 21, 21
  sticky_world:set_routes({ objective_generation = 21, members = { sticky_direct, sticky_npc } })
  sticky_world:refresh(1, true, route_tg)
  check("objective routes: generation change and reorder retain surviving identity color slots",
    route_in(sticky_world, sticky_ids[1]).slot == sticky_before[1]
      and route_in(sticky_world, sticky_ids[2]).slot == sticky_before[2])

  local ancillary = { objective_generation = 12, members = {
    { route_id = 2002, cid = 2002, qid = 30040, kind = "npc", direct = false,
      item_ids = {}, objective_generation = 12 },
  } }
  local ancillary_world = fixture().new()
  ancillary_world:set_routes(ancillary)
  ancillary_world:refresh(0, true, route_tg)
  local ancillary_entry = route_in(ancillary_world, 2002)
  check("objective routes: ancillary render retains false objective status and CID-only identity",
    ancillary_entry ~= nil and ancillary_entry.objective == false
      and ancillary_entry.target_key == nil and ancillary_entry.ordinal == nil
      and ancillary_entry.objective_generation == 12)

  local startable_world = fixture().new()
  startable_world:set_routes({ objective_generation = 13, members = {
    { route_id = 2201, cid = 2201, qid = 40, kind = "npc", direct = false,
      objective = true, name = "Quest giver", pos = P(2, 0, 2), item_ids = {},
      objective_generation = 13 },
  } })
  startable_world:refresh(0, true, route_tg)
  local startable_entry = route_in(startable_world, 2201)
  check("objective routes: keyless startable giver remains objective, not ancillary",
    startable_entry ~= nil and startable_entry.objective == true
      and startable_entry.target_key == nil and startable_entry.ordinal == nil
      and startable_entry.objective_generation == 13)
  local startable_slot = startable_entry and startable_entry.slot
  startable_world:set_routes({ objective_generation = 14, members = {
    { route_id = 2201, cid = 2201, qid = 40, kind = "npc", direct = false,
      objective = true, name = "Quest giver", pos = P(2, 0, 2), item_ids = {},
      objective_generation = 14 },
  } })
  startable_world:refresh(1, true, route_tg)
  check("objective routes: keyless startable giver keeps its objective color slot across generations",
    route_in(startable_world, 2201).objective == true
      and route_in(startable_world, 2201).slot == startable_slot)

  local function objective_npc(cid, ordinal, generation)
    return { route_id = cid, cid = cid, place = cid, qid = 30040, kind = "npc", direct = false,
      target_key = core.target_key({ 30040, "issued_npc", cid }), ordinal = ordinal,
      pos = P(cid, 0, cid), item_ids = {}, objective_generation = generation }
  end
  local ancillary_member = { route_id = 2102, cid = 2102, qid = 30040, kind = "npc",
    direct = false, item_ids = {}, objective_generation = 30 }
  local mixed_world = fixture().new()
  mixed_world:set_routes({ objective_generation = 30, members = {
    objective_npc(2101, 1, 30), ancillary_member, objective_npc(2103, 2, 30),
  } })
  mixed_world:refresh(0, true, route_tg)
  local mixed_slots = { route_in(mixed_world, 2101).slot,
    route_in(mixed_world, 2102).slot, route_in(mixed_world, 2103).slot }
  mixed_world:set_routes({ objective_generation = 31, members = {
    objective_npc(2101, 1, 31), objective_npc(2104, 3, 31),
    objective_npc(2103, 2, 31),
    { route_id = 2102, cid = 2102, qid = 30040, kind = "npc", direct = false,
      item_ids = {}, objective_generation = 31 },
  } })
  mixed_world:refresh(1, true, route_tg)
  check("objective routes: mixed reorder preserves objective identities and ancillary CID slot",
    route_in(mixed_world, 2101).slot == mixed_slots[1]
      and route_in(mixed_world, 2102).slot == mixed_slots[2]
      and route_in(mixed_world, 2103).slot == mixed_slots[3]
      and route_in(mixed_world, 2104).slot == 4)
  check("objective routes: mixed render marks only canonical members as objectives",
    route_in(mixed_world, 2101).objective == true
      and route_in(mixed_world, 2102).objective == false
      and route_in(mixed_world, 2104).objective == true)

  w:set_routes(ancillary)
  local ancillary_generation = w.route_gen
  w:set_routes(ancillary)
  check("objective routes: ancillary CID-only publication is accepted and idempotent",
    w.route_gen == ancillary_generation)

  w:set_routes(envelope)
  w:refresh(1, true, route_tg)
  local old_direct = core.objective_direct_route_id(1)
  w.path_job, w.rps[old_direct] = { cid = old_direct }, true
  w:set_routes({ objective_generation = 10, members = {
    { route_id = 2001, cid = 2001, place = 2001, qid = 30040, kind = "npc",
      direct = false, target_key = core.target_key({ 30040, "issued_npc", 2001 }),
      ordinal = 1, pos = P(1, 0, 1), item_ids = {}, objective_generation = 10 },
  } })
  check("objective routes: generation change clears published stops and old path state immediately",
    (w:input() == nil or w:input().routes == nil)
      and w.path_job == nil and w.rps[old_direct] == nil)
end

-- 40. static objective source catalog boundary
do
  local source_rows = {
    { k = "item", uid = "pickup-1", id = 501, n = 2, x = 1, y = 2, z = 3,
      src = "normal", gate = { check = 0, conditions = {
        { kind = "quest", qid = 1234, finish = true } } } },
    { k = "chest", uid = "chest-1", id = 10, x = 4, y = 5, z = 6,
      items = { { id = 501, n = 3 }, { id = 502, n = 1 } }, src = "normal" },
    { k = "chest", uid = "quest-chest-1", id = 11, x = 7, y = 8, z = 9,
      items = { { id = 503, n = 1 } }, src = "subquest" },
  }
  local f = fixture({ files = { [K.PLACES] = places(source_rows) } })
  local w = f.new()
  local catalog = w:objective_static_source_catalog()
  local same_catalog = w:objective_static_source_catalog()
  check("static catalog: parses once and reuses immutable snapshot",
    f.places_load_n == 1 and catalog == same_catalog and catalog.status == "ok"
      and catalog.complete == true and catalog.generation == 1)
  check("static catalog: typed placement and multi-output chest are exposed",
    catalog.placements[1].uid == "pickup-1"
      and catalog.placements[1].source_id[1] == "source"
      and catalog.placements[1].source_id[2] == "placed"
      and catalog.placements[1].capacity_pool_id[2] == "placed"
      and catalog.placements[1].outputs[1].item_id == 501
      and catalog.placements[1].outputs[1].count == 2 and catalog.placements[1].pos.x == 1
      and catalog.placements[1].gate.conditions[1].qid == 1234
      and #catalog.chests == 2 and catalog.chests[1].uid == "chest-1"
      and #catalog.chests[1].outputs == 2
      and catalog.chests[1].source_id[2] == "chest"
      and catalog.chests[1].outputs[2].item_id == 502
      and catalog.chests[2].uid == "quest-chest-1")
  local mutation_ok = pcall(function() catalog.placements[1].outputs[1].count = 900 end)
  local nested_mutation_ok = pcall(function() catalog.chests[1].outputs[1].count = 900 end)
  check("static catalog: returned values cannot mutate private closure catalog",
    not mutation_ok and not nested_mutation_ok
      and w:objective_static_source_catalog().placements[1].outputs[1].count == 2)
  local malformed = fixture({ files = { [K.PLACES] = places({
    { k = "item", uid = "dup", id = 501, n = 1, x = 0, y = 0, z = 0, src = "normal" },
    { k = "item", uid = "dup", id = 502, n = 1, x = 1, y = 0, z = 1, src = "normal" },
  }) } }):new():objective_static_source_catalog()
  check("static catalog: duplicate identity invalidates catalog atomically",
    malformed.status == "unknown" and malformed.complete == false
      and #malformed.placements == 0 and #malformed.chests == 0)
  local missing = fixture():new():objective_static_source_catalog()
  check("static catalog: missing data is unknown and empty",
    missing.status == "unknown" and missing.complete == false
      and #missing.placements == 0 and #missing.chests == 0)
  local malformed_content = fixture({ files = { [K.PLACES] = places({
    { k = "item", uid = "bad-count", id = 501, n = 0, x = 0, y = 0, z = 0,
      src = "normal" },
  }) } }):new():objective_static_source_catalog()
  check("static catalog: malformed placement quantity fails closed",
    malformed_content.status == "unknown" and malformed_content.complete == false
      and #malformed_content.placements == 0)
  local malformed_chest = fixture({ files = { [K.PLACES] = places({
    { k = "chest", uid = "bad-chest", id = 10, x = 0, y = 1, z = 2,
      src = "normal", items = { { id = 501, n = 0 } } },
  }) } }):new():objective_static_source_catalog()
  check("static catalog: malformed chest output fails closed",
    malformed_chest.status == "unknown" and malformed_chest.complete == false
      and #malformed_chest.chests == 0)

  local sf = fixture()
  local shop_rows = { complete = true, rows = {
    { shop_id = 7, offer_ordinal = 2, seller_cid = 20, item_id = 501, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 2, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(10, 0, 20) },
    { shop_id = 7, offer_ordinal = 2, seller_cid = 21, item_id = 501, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 2, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(11, 0, 20) },
    { shop_id = 7, offer_ordinal = 3, seller_cid = 20, item_id = 501, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 1, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(10, 0, 20) },
    { shop_id = 8, offer_ordinal = 1, seller_cid = 22, item_id = 502, count = 1,
      capacity_kind = "unlimited", unlimited = true, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(12, 0, 20) },
    { shop_id = 8, offer_ordinal = 2, seller_cid = 22, item_id = 502, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 0, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(12, 0, 20) },
  } }
  sf.shop_reads = 0
  sf.reads.objective_shop_rows = function() sf.shop_reads = sf.shop_reads + 1; return shop_rows end
  local sw = sf.new()
  local source_task = { need_generation = 1, quests = { { qid = 1001, task_index = 1 } } }
  local shops = sw:objective_shop_observations(source_task)
  local shops_reused = sw:objective_shop_observations(source_task)
  check("shop objectives: finite and unlimited offers publish gated seller targets",
    shops.status == "ok" and shops.complete and #shops.candidates == 4
      and shops.candidates[1].certainty == "guaranteed"
      and shops.candidates[1].capacity_kind == "finite"
      and shops.candidates[4].capacity_kind == "unlimited"
      and shops.candidates[4].evidence.restock_readable == true
      and shops_reused.generation == shops.generation and sf.shop_reads == 1)
  check("shop objectives: multiple sellers share one offer capacity",
    shops.candidates[1].source_id[1] == "source"
      and shops.candidates[1].source_id[2] == "shop_offer"
      and shops.candidates[1].source_id[5] ~= shops.candidates[2].source_id[5]
      and shops.candidates[1].capacity_pool_id[1] == "capacity"
      and shops.candidates[1].capacity_pool_id[3] == shops.candidates[2].capacity_pool_id[3]
      and shops.candidates[1].capacity_pool_id[4] == shops.candidates[2].capacity_pool_id[4]
      and shops.candidates[1].source_id[4] ~= shops.candidates[3].source_id[4]
      and shops.candidates[1].capacity_pool_id[4] ~= shops.candidates[3].capacity_pool_id[4]
      and shops.candidates[1].available_acquisitions == 2
      and shops.candidates[2].available_acquisitions == 2)
    shop_rows.rows[1].released = false
  shop_rows.rows[2].talk_available = false
  shop_rows.rows[3].interactable = false
  sw:refresh(0, true, { chests = true })
  local interaction_gated = sw:objective_shop_observations(source_task)
  check("shop objectives: disabled interaction excludes seller target",
    interaction_gated.status == "ok" and #interaction_gated.candidates == 1
      and interaction_gated.candidates[1].capacity_kind == "unlimited")
  shop_rows.rows[3].interactable = true
  sw:refresh(10, true, { chests = true })
  local gated = sw:objective_shop_observations(source_task)
  check("shop objectives: release and talk gates exclude unavailable sellers",
    gated.status == "ok" and #gated.candidates == 2
      and gated.candidates[2].capacity_kind == "unlimited")
  table.remove(shop_rows.rows, 2)
  sw:refresh(20, true, { chests = true })
  local seller_gone = sw:objective_shop_observations(source_task)
  check("shop objectives: disappeared seller drops only its target",
    seller_gone.status == "ok" and #seller_gone.candidates == 2
      and seller_gone.generation > gated.generation)
  shop_rows.rows[2].stock = 0
  sw:refresh(30, true, { chests = true })
  local depleted = sw:objective_shop_observations(source_task)
  check("shop objectives: exhausted finite offer disappears while unlimited remains",
    depleted.status == "ok" and #depleted.candidates == 1
      and depleted.candidates[1].capacity_kind == "unlimited")
  shop_rows.rows[2].stock = 1
  shop_rows.rows[2].restock_readable = false
  sw:refresh(40, true, { chests = true })
  local stock_unknown = sw:objective_shop_observations(source_task)
  check("shop objectives: unreadable restock evidence invalidates all candidates",
    stock_unknown.status == "unknown" and #stock_unknown.candidates == 0
      and stock_unknown.generation > depleted.generation)
  shop_rows.complete = false
  sw:refresh(50, true, { chests = true })
  local partial_shop = sw:objective_shop_observations(source_task)
  check("shop objectives: partial scan invalidates all seller targets",
    partial_shop.status == "unknown" and partial_shop.complete == false
      and #partial_shop.candidates == 0 and partial_shop.generation > stock_unknown.generation)
  shop_rows.complete = true
  shop_rows.rows = {
    { shop_id = 9, offer_ordinal = 2, seller_cid = 20, item_id = 501, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 2, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(10, 0, 20) },
    { shop_id = 9, offer_ordinal = 2, seller_cid = 21, item_id = 502, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 2, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(11, 0, 20) },
  }
  sw:refresh(60, true, { chests = true })
  local conflicting_offer = sw:objective_shop_observations(source_task)
  check("shop objectives: sellers sharing an offer must agree on output and stock evidence",
    conflicting_offer.status == "unknown" and #conflicting_offer.candidates == 0)
  shop_rows.rows[2].item_id, shop_rows.rows[2].stock = 501, 3
  sw:refresh(65, true, { chests = true })
  local conflicting_stock = sw:objective_shop_observations(source_task)
  check("shop objectives: sellers sharing an offer must agree on available stock",
    conflicting_stock.status == "unknown" and #conflicting_stock.candidates == 0)
  shop_rows.rows = { { shop_id = 9, offer_ordinal = 3, seller_cid = 21, item_id = 501, count = 1,
    capacity_kind = "unlimited", unlimited = true, restock_readable = false,
    released = true, talk_available = true, interactable = true, pos = P(11, 0, 20) } }
  sw:refresh(70, true, { chests = true })
  local unreadable_unlimited = sw:objective_shop_observations(source_task)
  check("shop objectives: unlimited offers still require readable restock evidence",
    unreadable_unlimited.status == "unknown" and #unreadable_unlimited.candidates == 0
      and unreadable_unlimited.candidates[1] == nil)

  local mf = fixture()
  local monster_rows = { complete = true, rows = {
    { uid = "live-a", drop_row_id = "drop-a", item_id = 501, count = 2, chance = 0.25,
      alive = true, accessible = true, drop_table_readable = true, pos = P(30, 0, 40) },
    { uid = "live-b", drop_row_id = "drop-a", item_id = 501, count = 2, chance = 0.5,
      alive = true, accessible = true, drop_table_readable = true, pos = P(31, 0, 40) },
    { uid = "dead", drop_row_id = "drop-a", item_id = 501, count = 2, chance = 1,
      alive = false, accessible = true, drop_table_readable = true, pos = P(32, 0, 40) },
    { uid = "blocked", drop_row_id = "drop-a", item_id = 501, count = 2, chance = 1,
      alive = true, accessible = false, drop_table_readable = true, pos = P(32, 0, 40) },
    { uid = "zero", drop_row_id = "drop-a", item_id = 501, count = 2, chance = 0,
      alive = true, accessible = true, drop_table_readable = true, pos = P(33, 0, 40) },
  } }
  mf.reads.objective_monster_rows = function() return monster_rows end
  local mw = mf.new()
  local monsters = mw:objective_monster_observations(source_task)
  check("monster objectives: live instances publish probabilistic drops with stable identities",
    monsters.status == "ok" and #monsters.candidates == 2
      and monsters.candidates[1].certainty == "probabilistic"
      and monsters.candidates[1].capacity_kind == "finite"
      and monsters.candidates[1].available_acquisitions == 1
      and monsters.candidates[1].probability == 0.25
      and monsters.candidates[1].source_id[3] ~= monsters.candidates[2].source_id[3])
  monster_rows.rows[2].drop_table_readable = false
  mw:refresh(0, true, { chests = true })
  local partial_monsters = mw:objective_monster_observations(source_task)
  check("monster objectives: unreadable drop table clears whole snapshot",
    partial_monsters.status == "unknown" and #partial_monsters.candidates == 0
      and partial_monsters.generation > monsters.generation)

  local integrated = fixture()
  integrated.shop_reads, integrated.monster_reads = 0, 0
  integrated.reads.objective_shop_rows = function() integrated.shop_reads = integrated.shop_reads + 1; return { complete = true, rows = {
    { shop_id = 9, offer_ordinal = 4, seller_cid = 30, item_id = 501, count = 1,
      capacity_kind = "finite", unlimited = false, stock = 1, restock_readable = true,
      released = true, talk_available = true, interactable = true, pos = P(50, 0, 60) },
  } } end
  integrated.reads.objective_monster_rows = function() integrated.monster_reads = integrated.monster_reads + 1; return { complete = true, rows = {
    { uid = "live-c", drop_row_id = "drop-c", item_id = 502, count = 1, chance = 0.3,
      alive = true, accessible = true, drop_table_readable = true, pos = P(70, 0, 80) },
  } } end
  local integrated_world = integrated.new()
  local empty_joined = integrated_world:objective_source_snapshots(nil,
    { need_generation = 44, quests = {} })
  check("objective source snapshot: no owned current work does not invoke live readers",
    #empty_joined == 5 and empty_joined[1].status == "unknown"
      and #empty_joined[1].candidates == 0 and empty_joined[2].status == "unknown"
      and #empty_joined[2].candidates == 0 and empty_joined[3].status == "unknown"
      and #empty_joined[3].candidates == 0 and empty_joined[4].status == "unknown"
      and #empty_joined[4].candidates == 0 and empty_joined[5].status == "unknown"
      and #empty_joined[5].candidates == 0
      and integrated.shop_reads == 0 and integrated.monster_reads == 0)
  local joined = integrated_world:objective_source_snapshots(nil,
    { need_generation = 45, quests = { { qid = 1001, task_index = 1 } } })
  check("objective source snapshot: world-owned shop and monster rows use shared provider contract",
    joined[4].provider == "shop" and joined[4].status == "ok"
      and joined[4].candidates[1].source_id[2] == "shop_offer"
      and joined[5].provider == "monster" and joined[5].status == "ok"
      and joined[5].candidates[1].certainty == "probabilistic")
  local suspended = integrated_world:objective_source_snapshots(nil,
    { need_generation = 46, quests = {} })
  local resumed = integrated_world:objective_source_snapshots(nil,
    { need_generation = 45, quests = { { qid = 1001, task_index = 1 } } })
  check("objective source snapshot: empty work clears cached live candidates before resume",
    suspended[4].status == "unknown" and #suspended[4].candidates == 0
      and resumed[4].status == "ok" and #resumed[4].candidates == 1
      and integrated.shop_reads == 2 and integrated.monster_reads == 2)
end

if failures > 0 then os.exit(1) end
print("world_test: all OK")
