-- tests/bench_core.lua: run by hand, not by the gate (SPEC 28.4.3).
-- Median ms of 20 first ticks after a new world table with 5,000 entries,
-- with no search and with the search "minotaur". Target: difference <= 1 ms.
-- Run from the worktree root: lua tests/bench_core.lua
package.path = "./reframework/autorun/?.lua;" .. package.path
local core = require("Clairvoyance.core")

local RUNS = 20
local N = 5000

local function P(x, y, z) return { x = x, y = y or 0, z = z or 0 } end

-- The same content every call, in fresh tables (a new world table per round).
local function make_world()
  math.randomseed(42)
  local function rp() return P(math.random() * 6000 - 3000, math.random() * 50, math.random() * 6000 - 3000) end
  local w = { chests = {}, treasure = {}, tokens = {}, beetles = {}, monsters = {}, sellers = {},
    shops = {}, drops = {} }
  local names = { "Goblin", "Minotaur", "Ogre", "Harpy", "Saurian", "Cyclops", "Wolf", "Skeleton" }
  for i = 1, N do
    local r = i % 10
    if r <= 2 then
      w.chests[#w.chests + 1] = { uid = "c" .. i, pos = rp(), state = "unopened",
        item_name = (i % 3 == 0) and ("Ferrystone " .. i) or nil,
        items = { { name = "Potion " .. (i % 17), n = 1 }, { name = "Rope", n = 2 } },
        kinds = (i % 5 == 0) and { "trap" } or nil }
    elseif r == 3 then
      w.treasure[#w.treasure + 1] = { name = "T" .. i, pos = rp(), checked = false,
        discovered = true, items = { { name = "Gem " .. (i % 11) } } }
    elseif r == 4 then
      w.tokens[#w.tokens + 1] = { uid = "k" .. i, pos = rp(), name = "Token " .. i, state = "not" }
    elseif r == 5 then
      w.beetles[#w.beetles + 1] = { uid = "b" .. i, pos = rp(), name = "Beetle " .. i, state = "not" }
    elseif r <= 7 then
      w.monsters[#w.monsters + 1] = { uid = "m" .. i, cid = 1000 + i, cids = { 1000 + i },
        name = names[1 + i % #names], respawning = (i % 4 == 0), pos = rp(), small = (i % 6 == 0) }
      w.drops[1000 + i] = { "Horn " .. (i % 13), "Fang" }
    else
      w.sellers[#w.sellers + 1] = { shop = i, item = i, item_name = "Item " .. i, cid = 5000 + i,
        npc = "Seller " .. (i % 40), qids = {}, quest = (i % 7 == 0) and "Some Quest" or "",
        pos = rp(), maybe_locked = (i % 9 == 0), discovered = true }
    end
  end
  for j = 1, 40 do
    w.shops[j] = { shop = 100000 + j, cid = 90000 + j, npc = "Shopkeeper " .. j, pos = rp(),
      discovered = true, items = { { name = "Potion", locked = false }, { name = "Arrow " .. j } } }
  end
  return w
end

local function show_for(text)
  return { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_tokens = true, world_beetles = true,
    world_small_monsters = true, world_show_opened = false, world_undiscovered = false,
    world_max_markers = 300, search = text and core.parse_query(text) or nil }
end

local function median(t)
  table.sort(t)
  return (t[10] + t[11]) / 2
end

local origin = P(0, 0, 0)

local function measure(text)
  local show = show_for(text)
  -- one earlier round fills the haystack cache, as the previous world round does in game
  core.world_markers_cached(make_world(), show, origin, {}, {})
  local worlds = {}
  for i = 1, RUNS do worlds[i] = make_world() end
  local ms = {}
  local hb0, cb0 = core.world_stats.hay_builds, core.world_stats.cand_builds
  collectgarbage()
  collectgarbage("stop")   -- no collection inside the timed region
  local total0 = os.clock()
  for i = 1, RUNS do
    local t0 = os.clock()
    core.world_markers_cached(worlds[i], show, origin, {}, {})
    ms[i] = (os.clock() - t0) * 1000
  end
  local total = (os.clock() - total0) * 1000 / RUNS
  collectgarbage("restart")
  return median(ms), core.world_stats.hay_builds - hb0, total,
    (core.world_stats.cand_builds - cb0) / RUNS,
    (core.world_stats.cand_builds - cb0) / RUNS
end

local none, hb_none, mean_none, cands_none = measure(nil)
local search, hb_search, mean_search, cands_search = measure("minotaur")
print(string.format("bench_core: %d entries, median of %d first ticks", N, RUNS))
print(string.format("  no search : %.3f ms (haystacks built %d, candidates per tick %d)", none, hb_none, cands_none))
print(string.format("  minotaur  : %.3f ms (haystacks built %d, candidates per tick %d)", search, hb_search, cands_search))
print(string.format("  difference: %.3f ms (target <= 1.000)", search - none))
-- os.clock ticks in whole milliseconds here, so the per-tick median is coarse;
-- the mean over the 20 ticks (one clock pair around all of them) is exact to ~0.05 ms.
print(string.format("  mean of %d: no search %.3f ms, minotaur %.3f ms, difference %.3f ms",
  RUNS, mean_none, mean_search, mean_search - mean_none))
