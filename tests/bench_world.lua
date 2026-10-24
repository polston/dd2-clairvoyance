-- tests/bench_world.lua - run by hand, not by the gate (SPEC 28.5.1):
--   lua tests/bench_world.lua
-- Drives Clairvoyance/world.lua with its own copy of world_test's fixture
-- (fake reads, adapter and io), scaled to the places file's 4,488 rows
-- (3,248 chara, 922 chest, 240 token, 78 beetle), and prints the median of
-- 20 steady samples per step (each the mean of 10 rounds), in ms. The fakes cost almost nothing except reserved_rows, which builds 3,009 throwaway rows per call to stand for the game read (SPEC 31.4.5), so the
-- table is the work world.lua does itself plus that read.
package.path = "./reframework/autorun/?.lua;" .. package.path
local world = require("Clairvoyance.world")
local K = world.K

local function P(x, y, z) return { x = x, y = y, z = z } end

local bench_sig = 0
local function fixture(files)
  local f = { files = files, data = {
    reserved = {}, loaded = {}, sched = {}, icons = {}, msgs = {}, records = {},
    nodes = {}, checked = {}, icons_found = {}, sched_ids = {}, shop = {},
    shops = {}, respawn = {}, boss = {}, loaded_boss = {}, catalog = {},
    cast = {}, needs = {}, locs = {}, qstate = {}, iname = {}, npcname = {},
    drops = {} } }
  local d = f.data
  f.reads = {
    -- 3,009 throwaway rows per call stand for the real row read's cost
    reserved_rows = function()
      local junk = {}
      for i = 1, 3009 do
        junk[i] = { uid = "junk-" .. i, pos = { x = i, y = 0, z = i }, gimmick = 10, table_ix = 1 }
      end
      local out = {}
      for i, r in ipairs(d.reserved) do out[i] = r end
      return out
    end,
    reserved_sig = function() return "bench" .. bench_sig end,
    loaded_gimmicks = function() return d.loaded end,
    schedule_pos = function(cid) return d.sched[cid] end,
    map_icons = function() return d.icons end,
    msg = function(id) return d.msgs[id] end,
    save_records = function() return d.records end,
    treasure_nodes = function() return d.nodes end,
    checked_nodes = function() return d.checked end,
    discovered_icons = function() return d.icons_found end,
    discovered_count = function() return 0 end,
    schedule_ids = function() return d.sched_ids end,
    shop_of = function(cid) return d.shop[cid] end,
    shops = function() return d.shops end,
    respawn_units = function() return d.respawn end,
    monster_drops = function() return d.drops end,
    boss_families = function() return d.boss end,
    loaded_boss_families = function() return d.loaded_boss end,
    badge_name = function() return "Griffin" end,
  }
  f.adapter = {
    quest_state = function(q) return d.qstate[q] end,
    item_needs = function() return d.needs end,
    item_locations = function() return d.locs end,
    catalog_ids = function() return d.catalog end,
    cast_ids = function(q) return d.cast[q] end,
    npc_alive = function() return false end,
    npc_pos = function() return nil end,
    item_name = function(id) return d.iname[id] end,
    npc_name = function(cid) return d.npcname[cid] end,
    quest_name = function() return nil end,
  }
  f.io = {
    load = function(path) return f.files[path] end,
    dump = function(path, t) f.files[path] = t; return true end,
    clock = os.clock,
  }
  return f
end

-- ----- the scaled places file -----
local N_CHARA, N_CHEST, N_TOKEN, N_BEETLE = 3248, 922, 240, 78
local N_CAST, N_SHOPS = 120, 40
local rows = {}
local function add(k, uid, id, x, z, extra)
  local r = { k = k, uid = uid, id = id, x = x, y = 0, z = z, src = "normal" }
  for kk, v in pairs(extra or {}) do r[kk] = v end
  rows[#rows + 1] = r
end
for i = 1, N_CHARA do
  local name
  if i <= N_CAST then name = "ch30" .. string.format("%04d", i) .. "_00"
  elseif i % 3 == 0 then name = "ch253000_" .. (i % 7)
  elseif i % 3 == 1 then name = "ch220000_" .. (i % 7)
  else name = "ch410000_" .. (i % 7) end
  add("chara", string.format("chara-%05d", i), i <= N_CAST and (2000 + i) or (10000 + i),
    (i * 37) % 3000, (i * 91) % 3000, { name = name })
end
for i = 1, N_CHEST do
  add("chest", string.format("chest-%05d", i), 10 + (i % 3), (i * 53) % 3000,
    (i * 17) % 3000, { items = { { id = 100 + (i % 40), n = 1 }, { id = 200 + (i % 40), n = 2 } },
      quest = (i % 25 == 0) and { any = false, q = { { 11000 + (i % 5), true } } } or nil })
end
for i = 1, N_TOKEN do
  add("token", string.format("token-%05d", i), K.TOKEN_ID, (i * 71) % 3000, (i * 29) % 3000)
end
for i = 1, N_BEETLE do
  add("beetle", string.format("beetle-%05d", i), K.BEETLE_ID, (i * 43) % 3000, (i * 83) % 3000)
end

add("chest", "live-00001", 10, 1234, 1234, { src = "subquest" })   -- listed, never in the atlas: live-only
local f = fixture({ [K.PLACES] = { version = 1, pak = "1:1", rows = rows } })
local d = f.data
d.boss = { ch253 = true }
d.catalog = { 1 }
d.cast = { [1] = {} }
for i = 1, N_CAST do
  local cid = 2000 + i
  d.cast[1][i] = cid
  d.sched_ids[i] = cid
  d.sched[cid] = P((i * 37) % 3000, 0, (i * 91) % 3000)
  d.npcname[cid] = "Npc " .. i
  d.shop[cid] = (i <= N_SHOPS) and (100 + i) or nil
end
for s = 1, N_SHOPS do
  local list = {}
  for j = 1, 8 do
    list[j] = { item = 100 + ((s * 7 + j) % 60), release_qid = (j % 4 == 0) and 12000 or -1,
      sentiment_bit = 1, total_pay = 0, flag = 0, var_cond = 0 }
  end
  d.shops[100 + s] = list
end
for i = 1, 300 do d.iname[i] = "Item name " .. i end
d.needs = {}
for i = 1, 30 do d.needs[i] = { quest = 13000 + i, item = 100 + i, n = 1 } end
for i = 1, 60 do
  d.reserved[i] = { uid = string.format("chest-%05d", i), pos = P((i * 53) % 3000, 0, (i * 17) % 3000),
    gimmick = 10, table_ix = 1 + (i % 6) }
end
for i = 1, 40 do
  d.loaded[i] = { uid = string.format("chest-%05d", i), gimmick = 10,
    pos = P((i * 53) % 3000, 0, (i * 17) % 3000) }
end
for i = 1, N_CHEST do
  d.records[#d.records + 1] = { key = string.format("chest-%05d", i), guid = string.format("chest-%05d", i),
    picked = (i % 3 == 0) }
end
for i = 1, N_TOKEN do
  d.records[#d.records + 1] = { key = string.format("token-%05d", i), guid = string.format("token-%05d", i),
    free_bit = (i % 2 == 0) and (1 << K.TOKEN_BIT) or 0 }
end
for i = 1, N_BEETLE do
  d.records[#d.records + 1] = { key = string.format("beetle-%05d", i), guid = string.format("beetle-%05d", i),
    gather_num = i % 2 }
end
for i = 1, 100 do
  d.respawn[i] = { key = string.format("chara-%05d", N_CAST + i), cid = 10000 + N_CAST + i,
    cid_name = "ch253000_0", pos = P((i * 37) % 3000, 0, (i * 91) % 3000) }
end
for i = 1, 60 do d.nodes[i] = { name = "Node " .. i, pos = P((i * 61) % 3000, 0, (i * 13) % 3000) } end
for i = 1, 200 do d.drops[10000 + i] = { 100 + (i % 40) } end

-- the First Seeker's Token read, and one live-only row (a reserved chest the
-- places file lists only as a subquest row), so both paths are in the table
f.reads.first_seeker = function() return "token-00001" end
d.reserved[#d.reserved + 1] = { uid = "live-00001", pos = P(1234, 0, 1234),
  gimmick = 10, table_ix = 9 }

local TG = { chests = true, treasure = true, tokens = true, beetles = true,
  monsters = true, small_monsters = true, sellers = true, search = true, shops = true,
  first_token = true }

local w = world.new(f.adapter, f.reads, f.io)
local t = 0
local function round(new_sig)
  t = t + 10
  if new_sig ~= false then bench_sig = bench_sig + 1 end
  w:poke()
  assert(w:refresh(t, true, TG), "round did not run")
  local ms = w:stats().ms
  local one = {}
  for k, v in pairs(ms) do one[k] = v end
  one.round_ms = w:stats().round_ms
  return one
end

for _ = 1, 4 do round() end   -- warm up: loads, first-time reads, name slices

-- os.clock ticks in whole milliseconds here, so one sample is the mean of
-- PER rounds (the quantisation averages out); the median is over 20 samples.
local PER = 10
local samples = {}
for i = 1, 20 do
  local acc = {}
  for _ = 1, PER do
    for k, v in pairs(round()) do acc[k] = (acc[k] or 0) + v / PER end
  end
  samples[i] = acc
end

local function median(list)
  table.sort(list)
  return list[(#list + 1) // 2]
end

local keys = {}
for k in pairs(samples[1]) do
  if k:sub(1, 5) == "step_" or k == "round_ms" or k == "schedule_pos" then keys[#keys + 1] = k end
end
table.sort(keys)
print(string.format("%-22s %10s", "step", "median ms"))
local sum = 0
for _, k in ipairs(keys) do
  local vals = {}
  for i = 1, #samples do vals[i] = samples[i][k] or 0 end
  local m = median(vals)
  if k:sub(1, 5) == "step_" then sum = sum + m end
  print(string.format("%-22s %10.3f", k, m))
end
print(string.format("%-22s %10.3f", "(sum of step_*)", sum))

-- read rounds against reuse rounds: 20 pairs, a new signature then the same one
local st0 = w:stats()
local r0, u0 = st0.reserved_reads, st0.reserved_reused
local read_sum, reuse_sum = 0, 0
for _ = 1, 20 do
  read_sum = read_sum + round(true).step_reserved
  reuse_sum = reuse_sum + round(false).step_reserved
end
local st1 = w:stats()
print(string.format("reserved: read rounds %.3f ms, reuse rounds %.3f ms, reads %d, reused %d",
  read_sum / 20, reuse_sum / 20, st1.reserved_reads - r0, st1.reserved_reused - u0))
