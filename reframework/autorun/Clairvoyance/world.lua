-- world.lua - the v10 world tracker (SPEC 17.3, 17.10). Loads the offline
-- places file and the learned atlas, runs the throttled world round and
-- returns plain tables from w:input(). Every game read goes through the
-- injected `reads` table; world.game_reads() is the only place that touches
-- `sdk`. Tested by tests/world_test.lua with fake reads, adapter and io.
local core = require("Clairvoyance.core")

local M = {}

M.K = {
  WORLD_ROUND = 10.0,
  NPC_NAME_SLICE = 200,
  SENTIMENT_EVERY = 1.0,
  SAVE_EVERY = 60,
  REMOVE_RADIUS = 50,
  REMOVE_NEIGHBOURS = 3,
  ROUND_TO = 0.1,
  FILE_VERSION = 1,
  ATLAS = "Clairvoyance_world.json",
  OLD_ATLAS = "Clairvoyance_world.old.json",
  PLACES = "Clairvoyance_places.json",
  PLACES_VERSION = 1,
  TOKEN_ID = 167,
  BEETLE_ID = 161,
  TOKEN_BIT = 16,
  TOKEN_ITEM = 305,
  BEETLE_ITEM = 398,
  CHEST_IDS = { 10, 11, 12, 692, 693, 694 },
  EXTRA_LARGE = { "ch256", "ch260", "ch261", "ch270" },
  CLUSTER = 5,
  PLACES_SLOW_MS = 50,
  UNLISTED_STALE = 20,  -- interim: a later round on the probe save learned 2 unlisted chests (SPEC 17.10.11)
  SETTLEMENT_TYPE = 68,
  REORIGIN = 50,       -- main file: re-take the world origin after the player moves this far
  PLAYER_SEEN_S = 3,   -- main file: the minimap saw the player this recently, to run a round
  DEBUG_ROWS = 20,     -- main file: rows in the QNML_DEBUG.world() dump
}

local ATLAS_KINDS = { chest = true, token = true, beetle = true, monster = true, giver = true }
local PLACES_KINDS = { chest = true, token = true, beetle = true, chara = true }

-- ===== small helpers =====
local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function round1(v)
  local s = 1 / M.K.ROUND_TO
  return math.floor(v * s + 0.5) / s
end

-- position rules shared with core (an origin-adjacent position is unknown)
local dist, near_zero, valid_pos = core.dist, core.near_zero, core.valid_pos

-- A places or live row with no src, or src "normal", is a normal placement.
local function normal_src(s) return s == nil or s == "normal" end

-- The 5-character family prefix of a character name, or nil.
local function fam_of(nm)
  return type(nm) == "string" and #nm >= 5 and nm:sub(1, 5) or nil
end

local function to_int(v)
  if type(v) ~= "number" then return nil end
  return math.tointeger(v)
end

-- Tokens and beetles share one round branch: the output list, the item that
-- names them, and what a save record says about a collected one.
local COLLECT = {
  token = { list = "tokens", item = "TOKEN_ITEM",
    done = function(r)
      local fb = to_int(r.free_bit)
      return fb ~= nil and ((fb >> M.K.TOKEN_BIT) & 1) == 1
    end },
  beetle = { list = "beetles", item = "BEETLE_ITEM",
    done = function(r) return to_int(r.gather_num) == 0 end },
}

local function guid_of(key)
  if type(key) ~= "string" then return nil end
  return (key:match("^(.*)_[^_]*$") or key):lower()
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function nz(v)
  if v == nil or v == false then return false end
  if type(v) == "number" then return v ~= 0 end
  return true
end

function M.default_io()
  return {
    load = function(path) return json.load_file(path) end,
    dump = function(path, t) return json.dump_file(path, t) ~= false end,
    clock = os.clock,
    log = function() end,
  }
end

-- The world kind ("token", "beetle", "chest") of a gimmick id, else nil.
function M.kind_of_gimmick(id)
  if id == M.K.TOKEN_ID then return "token" end
  if id == M.K.BEETLE_ID then return "beetle" end
  for _, c in ipairs(M.K.CHEST_IDS) do
    if c == id then return "chest" end
  end
  return nil
end

-- Greedy clustering of one family (SPEC 17.10.9): each item, in uid order,
-- joins the earliest-created cluster whose seed lies within `radius`, else
-- seeds a new one. Seeds sit in a radius-sized grid, so only the 27 cells
-- around an item are tested; the result equals the linear scan over every
-- earlier seed.
function M.cluster(items, uids, radius)
  local clusters, grid, R = {}, {}, radius
  for _, uid in ipairs(uids) do
    local it = items[uid]
    local p = it.pos
    local gx, gy, gz = math.floor(p.x / R), math.floor(p.y / R), math.floor(p.z / R)
    local home = nil
    for dx = -1, 1 do
      for dy = -1, 1 do
        for dz = -1, 1 do
          local b = grid[((gx + dx) * 65536 + (gy + dy)) * 65536 + (gz + dz)]
          if b ~= nil then
            for _, c in ipairs(b) do
              if home == nil or c.n < home.n then
                local s = c.seed.pos
                local ddx, ddy, ddz = p.x - s.x, p.y - s.y, p.z - s.z
                if math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz) <= R then home = c end
              end
            end
          end
        end
      end
    end
    if home == nil then
      local c = { seed = it, count = 1, respawning = it.respawning, n = #clusters + 1,
        cids = { it.cid }, cidset = {} }
      if it.cid ~= nil then c.cidset[it.cid] = true end
      clusters[#clusters + 1] = c
      local key = (gx * 65536 + gy) * 65536 + gz
      local b = grid[key]
      if b == nil then b = {}; grid[key] = b end
      b[#b + 1] = c
    else
      home.count = home.count + 1
      if it.respawning then home.respawning = true end
      if it.cid ~= nil then
        if not home.cidset[it.cid] then
          home.cidset[it.cid] = true
          home.cids[#home.cids + 1] = it.cid
        end
      end
    end
  end
  return clusters
end

-- ===== the instance =====
function M.new(a, reads, io)
  reads = reads or {}
  do
    local given = io or {}
    io = M.default_io()
    for k, v in pairs(given) do io[k] = v end
  end
  local clock = io.clock or os.clock
  local w = { route_gen = 0 }

  local places = { state = "missing", rows = 0, dropped = 0, load_ms = 0,
    slow = false, pak = nil }
  local static = {}        -- uid -> file entry (chest, token, beetle)
  local chara_rows = {}    -- raw places chara rows
  local places_uids = {}   -- every valid places row uid
  local learned = {}       -- uid -> learned entry
  local atlas_dropped = 0
  local atlas_pruned = 0
  local loaded_pak = nil
  local dirty = false
  local committed = false
  local rev = 0            -- bumps when the learned set changes
  local givers_cache, givers_rev = nil, -1
  local names = {}         -- cid -> enum name, from every row seen
  local last_round, last_now, last_save = nil, 0, nil
  local rerun = false      -- the round deferred the drop read: run the next tick
  local input_tbl = nil
  local unlisted = 0
  local stats = { ms = {}, known = {}, monster_ids = {}, rounds = 0, saves = 0,
    save_ms = 0, last_save_reason = nil, hits = 0, misses = 0 }
  local S

  local function new_session()
    return { cast = nil, boss = nil, union = {}, badge = {},
      nodes = nil, node_chest = nil, shops = nil, sched_ids = nil, shop_of = {}, shop_cids = nil,
      settle = nil, msgs = {}, disc_set = nil, disc_count = nil,
      disc_cache = {}, need_sort = true, file_monsters = {}, held = {}, live = {},
      drop_ids = nil,
      -- v14 (SPEC 22.7-22.9): NPC name list, route, spawned-holder walk
      npc_list = {}, npc_ms = 0, npc_next = 1, npc_done = false, npc_sig = "",
      route_cid = nil, route_name = nil, route_cache = nil,
      sent = {}, walk_i = 0, walk_n = 0, walk_acc = {} }
  end
  S = new_session()
  w.spawned = {}

  -- ----- places file -----
  local function parse_places(v)
    local rows, dropped = 0, 0
    for _, r in ipairs(v.rows) do
      local ok = type(r) == "table" and PLACES_KINDS[r.k] == true
        and type(r.uid) == "string" and r.uid ~= ""
        and to_int(r.id) ~= nil and finite(r.x) and finite(r.y) and finite(r.z)
      if not ok then
        dropped = dropped + 1
      else
        rows = rows + 1
        local uid = r.uid:lower()
        places_uids[uid] = true
        local x, y, z = round1(r.x), round1(r.y), round1(r.z)
        local id = to_int(r.id)
        if r.k == "chara" then
          if type(r.name) == "string" and r.name ~= "" then names[id] = r.name end
          chara_rows[#chara_rows + 1] = { uid = uid, id = id, name = names[id],
            x = x, y = y, z = z, src = r.src, phase = r.phase }
        elseif normal_src(r.src) then
          local e = { k = r.k, id = id, x = x, y = y, z = z, src = "file" }
          if r.k == "chest" and type(r.items) == "table" then
            local items = {}
            for _, it in ipairs(r.items) do
              if type(it) == "table" and to_int(it.id) ~= nil then
                items[#items + 1] = { id = to_int(it.id), n = to_int(it.n) or 1 }
              end
            end
            if #items > 0 then e.items = items end
          end
          if r.k == "chest" then
            local q = r.quest
            if type(q) == "table" then
              local qs = {}
              for _, p in ipairs(type(q.q) == "table" and q.q or {}) do
                if type(p) == "table" and to_int(p[1]) ~= nil then
                  qs[#qs + 1] = { to_int(p[1]), p[2] == true }
                end
              end
              e.quest = { any = q.any == true, q = qs, var = q.var == true or nil }
            end
            if r.trap == true then e.trap = true end
            if r.pawn == true then e.pawn = true end
          end
          static[uid] = e
        end
      end
    end
    places.rows, places.dropped = rows, dropped
  end

  do
    local t0 = clock()
    local ok, v = pcall(io.load, M.K.PLACES)
    places.load_ms = (clock() - t0) * 1000
    places.slow = places.load_ms > M.K.PLACES_SLOW_MS
    if not ok then
      places.state = "bad"
    elseif v == nil then
      places.state = "missing"
    elseif type(v) ~= "table" or v.version ~= M.K.PLACES_VERSION
      or type(v.rows) ~= "table" then
      places.state = "bad"
    else
      local okp = pcall(parse_places, v)
      if okp then
        places.state = "ok"
        if type(v.pak) == "string" then places.pak = v.pak end
      else
        places.state = "bad"
        static, chara_rows, places_uids = {}, {}, {}
        places.rows, places.dropped = 0, 0
      end
    end
  end

  -- ----- atlas file -----
  local function load_atlas()
    local raw = require("Clairvoyance.settings_util").load_with_legacy(
      io.load, M.K.ATLAS, "QuestNPCMapLabels_world.json")
    if type(raw) ~= "table" then return end
    if raw.version ~= M.K.FILE_VERSION then
      pcall(io.dump, M.K.OLD_ATLAS, raw)
      return
    end
    if type(raw.pak) == "string" then loaded_pak = raw.pak end
    if type(raw.entries) ~= "table" then return end
    local stale_stamp = places.pak ~= nil and raw.pak ~= places.pak
    -- SPEC 17.10.9.2: chara rows the file keeps (src normal, no phase)
    local kept_chara = {}
    for _, r in ipairs(chara_rows) do
      if normal_src(r.src) and r.phase == nil then
        kept_chara[r.uid] = true
      end
    end
    for uid, e in pairs(raw.entries) do
      local good = type(uid) == "string" and type(e) == "table"
        and ATLAS_KINDS[e.k] == true and to_int(e.id) ~= nil
        and finite(e.x) and finite(e.y) and finite(e.z)
      if not good then
        atlas_dropped = atlas_dropped + 1
      else
        local ix = to_int(e.table_ix)
        local id = to_int(e.id)
        local uidl = uid:lower()
        local nm = type(e.name) == "string" and e.name or nil
        local pruned = false
        if places.state == "ok" then
          if e.k == "monster" then
            pruned = not kept_chara[uidl]
          elseif e.k == "chest" or e.k == "token" or e.k == "beetle" then
            pruned = places_uids[uidl] == true and static[uidl] == nil
          end
        end
        if pruned then
          atlas_pruned = atlas_pruned + 1
          dirty = true
        elseif stale_stamp and ix == nil then
          dirty = true
        else
          learned[uidl] = { k = e.k, id = id, x = e.x, y = e.y,
            z = e.z, src = "learned", table_ix = ix, name = nm }
          if nm then names[id] = names[id] or nm end
        end
      end
    end
  end
  pcall(load_atlas)

  -- ----- learning -----
  local function same_pos(e, x, y, z) return e.x == x and e.y == y and e.z == z end

  local function learn(uid, k, id, pos_x, pos_y, pos_z, table_ix, name)
    local x, y, z = round1(pos_x), round1(pos_y), round1(pos_z)
    local cur = learned[uid]
    if cur ~= nil then
      if cur.k == k and cur.id == id and same_pos(cur, x, y, z)
        and (table_ix == nil or cur.table_ix == table_ix)
        and (name == nil or cur.name == name) then
        return
      end
      cur.k, cur.id, cur.x, cur.y, cur.z = k, id, x, y, z
      cur.table_ix = table_ix or cur.table_ix
      cur.name = name or cur.name
    else
      local f = static[uid] or S.file_monsters[uid]
      if f ~= nil and f.k == k and f.id == id and same_pos(f, x, y, z) then
        return
      end
      learned[uid] = { k = k, id = id, x = x, y = y, z = z, src = "learned",
        table_ix = table_ix, name = name }
    end
    dirty = true
    rev = rev + 1
  end

  -- ----- classification of chara rows (SPEC 17.10.9) -----
  local function is_large(fam)
    if S.boss ~= nil and S.boss[fam] then return true end
    if S.union[fam] then return true end
    for _, f in ipairs(M.K.EXTRA_LARGE) do
      if f == fam then return true end
    end
    return false
  end

  local function family_class(fam)
    if fam == nil then return "drop" end
    if fam == "ch299" then return "drop" end
    if is_large(fam) then return "large" end
    if fam:match("^ch2[2-7]%d$") then return "small" end
    return "drop"
  end

  local function classify(id, name, src, phase)
    if S.cast ~= nil and S.cast[id] then return "giver" end
    if not normal_src(src) or phase ~= nil then return "drop" end
    return family_class(fam_of(name or names[id]))
  end

  local function sort_places()
    S.need_sort = false
    S.file_monsters = {}
    for _, r in ipairs(chara_rows) do
      local c = classify(r.id, r.name, r.src, r.phase)
      if c == "giver" then
        learn(r.uid, "giver", r.id, r.x, r.y, r.z, nil, r.name)
      elseif c == "large" or c == "small" then
        S.file_monsters[r.uid] = { k = "monster", id = r.id, x = r.x, y = r.y,
          z = r.z, src = "file", name = r.name }
      end
    end
  end

  -- ----- guarded sources -----
  -- Calls reads[name]; returns ok, value. Times the call.
  local function call(name, ...)
    local f = reads[name]
    if type(f) ~= "function" then return false, nil end
    local t0 = clock()
    local ok, v = pcall(f, ...)
    stats.ms[name] = (clock() - t0) * 1000
    return ok, v
  end

  local function table_read(name, ...)
    local ok, v = call(name, ...)
    if ok and type(v) == "table" then return v end
    return nil
  end

  -- reads[name]() as a table, else raise (for guarded sources).
  local function need_table(name)
    local v = table_read(name)
    if v == nil then error(name .. " failed") end
    return v
  end

  -- A failed read keeps the last good value for one round, then clears it.
  local function guarded(key, fn)
    local h = S.held[key]
    if h == nil then h = {}; S.held[key] = h end
    local ok, v = pcall(fn)
    if ok and v ~= nil then
      h.value, h.failed = v, false
    elseif h.failed then
      h.value = nil
    else
      h.failed = true
    end
    return h.value
  end

  -- ----- cast set (SPEC 17.10.9: first built each session) -----
  local function ensure_cast()
    if S.cast ~= nil then return true end
    local ok, set = pcall(function()
      local ids = a.catalog_ids()
      if type(ids) ~= "table" then return nil end
      local out = {}
      for _, qid in ipairs(ids) do
        local c = a.cast_ids(qid)
        if c == nil then return nil end
        for _, cid in ipairs(c) do
          local n = type(cid) == "number" and math.tointeger(cid) or nil
          if n ~= nil then out[n & 0xFFFFFFFF] = true end
        end
      end
      return out
    end)
    if ok and set ~= nil then
      S.cast = set
      S.cast_list = sorted_keys(set)
      S.need_sort = true
      return true
    end
    return false
  end

  local function ensure_boss()
    if S.boss ~= nil then return true end
    local v = table_read("boss_families")
    if v ~= nil then
      S.boss = v
      S.need_sort = true
      return true
    end
    return false
  end

  local function read_loaded_boss()
    local v = table_read("loaded_boss_families")
    if v == nil then return end
    for fam, on in pairs(v) do
      if on and not S.union[fam] then
        S.union[fam] = true
        S.need_sort = true
      end
    end
  end

  -- ----- round pieces -----
  -- A live row the places file drops (or, for a monster, does not list) draws
  -- only while reserved: it goes to S.live, never to the saved atlas.
  local function live_only(uid, k, id, x, y, z, name)
    S.live[uid] = { k = k, id = id, x = round1(x), y = round1(y), z = round1(z),
      src = "live", name = name }
  end

  -- Returns the set of every reserved row uid (lower case), valid position or not.
  local function learn_reserved(rows, chara_ok)
    local file_ok = places.state == "ok"
    local uids = {}
    for _, r in ipairs(rows) do
      local uid = type(r) == "table" and type(r.uid) == "string" and r.uid:lower() or nil
      if uid ~= nil then uids[uid] = true end
      if uid ~= nil and valid_pos(r.pos) and not near_zero(r.pos) then
        local gid = to_int(r.gimmick)
        if gid ~= nil and gid ~= 0 then
          if normal_src(r.src) then
            local k = M.kind_of_gimmick(gid)
            if k ~= nil then
              if file_ok and places_uids[uid] and static[uid] == nil then
                live_only(uid, k, gid, r.pos.x, r.pos.y, r.pos.z)
              else
                learn(uid, k, gid, r.pos.x, r.pos.y, r.pos.z, to_int(r.table_ix))
              end
            end
          end
        elseif chara_ok and to_int(r.cid) ~= nil then
          local cid = to_int(r.cid)
          if type(r.cid_name) == "string" and r.cid_name ~= "" then
            names[cid] = r.cid_name
          end
          local c = classify(cid, r.cid_name, r.src, r.phase)
          if c == "giver" then
            learn(uid, "giver", cid, r.pos.x, r.pos.y, r.pos.z,
              to_int(r.table_ix), names[cid])
          elseif c == "large" or c == "small" then
            if file_ok and S.file_monsters[uid] == nil then
              live_only(uid, "monster", cid, r.pos.x, r.pos.y, r.pos.z, names[cid])
            else
              learn(uid, "monster", cid, r.pos.x, r.pos.y, r.pos.z,
                to_int(r.table_ix), names[cid])
            end
          end
        end
      end
    end
    return uids
  end

  local function remove_patched(rows, seen)
    local by_table = {}
    for _, r in ipairs(rows) do
      if type(r) == "table" and type(r.uid) == "string" then
        local ix = to_int(r.table_ix)
        if ix ~= nil and valid_pos(r.pos) then
          local t = by_table[ix]
          if t == nil then t = {}; by_table[ix] = t end
          t[#t + 1] = r.pos
        end
      end
    end
    local drop = {}
    for uid, e in pairs(learned) do
      if e.table_ix ~= nil and not seen[uid] and by_table[e.table_ix] then
        local n = 0
        for _, p in ipairs(by_table[e.table_ix]) do
          if dist(p, e) <= M.K.REMOVE_RADIUS then
            n = n + 1
          end
        end
        if n >= M.K.REMOVE_NEIGHBOURS then drop[#drop + 1] = uid end
      end
    end
    for _, uid in ipairs(drop) do learned[uid] = nil end
    if #drop > 0 then dirty = true; rev = rev + 1 end
  end

  -- Returns nothing; sets `unlisted` and learns the unlisted placements.
  local function read_loaded(reserved_uids)
    local rows = table_read("loaded_gimmicks")
    if rows == nil then return end
    local seen, n_unlisted = {}, 0
    for _, g in ipairs(rows) do
      if type(g) == "table" and type(g.uid) == "string" and valid_pos(g.pos)
        and not near_zero(g.pos) then
        local uid = g.uid:lower()
        local id = to_int(g.gimmick)
        local k = id ~= nil and M.kind_of_gimmick(id) or nil
        if k ~= nil and not seen[uid] then
          seen[uid] = true
          if not places_uids[uid] and not (reserved_uids and reserved_uids[uid]) then
            n_unlisted = n_unlisted + 1
            learn(uid, k, id, g.pos.x, g.pos.y, g.pos.z, nil)
          end
        end
      end
    end
    if reserved_uids ~= nil then unlisted = n_unlisted end
    return seen
  end

  -- ----- settlements, discovery -----
  local function ensure_settlements()
    if S.settle ~= nil then return end
    local icons = table_read("map_icons")
    if icons == nil then return end
    local out = {}
    for _, ic in ipairs(icons) do
      if type(ic) == "table" and ic.type == M.K.SETTLEMENT_TYPE
        and valid_pos(ic.pos) and ic.disp_id ~= nil then
        local nm = S.msgs[ic.disp_id]
        if nm == nil then
          local ok, v = call("msg", ic.disp_id)
          nm = (ok and type(v) == "string" and v ~= "") and v or false
          S.msgs[ic.disp_id] = nm
        end
        if nm then
          out[#out + 1] = { name = nm, pos = { x = ic.pos.x, y = ic.pos.y, z = ic.pos.z },
            id = ic.icon_id }
        end
      end
    end
    S.settle = out
  end

  local function refresh_discovery()
    local ok, n = call("discovered_count")
    if ok and n ~= nil then
      if n ~= S.disc_count then
        local set = table_read("discovered_icons")
        if set ~= nil then
          S.disc_set, S.disc_count, S.disc_cache = set, n, {}
        end
      end
    elseif S.disc_set == nil then
      local set = table_read("discovered_icons")
      if set ~= nil then S.disc_set = set end
    end
  end

  local function discovered(key, pos)
    local c = S.disc_cache[key]
    if c ~= nil then return c end
    if S.disc_set == nil or S.settle == nil or #S.settle == 0 then return true end
    -- settlements are keyed by icon id (GuiManager.MapIconDispIdList holds ids)
    local best = core.nearest_settlement(pos, S.settle)
    if best == nil or best.id == nil then return true end
    local d = S.disc_set[best.id] == true
    S.disc_cache[key] = d
    return d
  end

  -- ----- sellers (SPEC 17.3g) -----
  local function ensure_shop_cids()
    if S.shop_cids ~= nil then return S.shop_cids end
    local ids = S.sched_ids
    if ids == nil then
      local ok, v = call("schedule_ids")
      if not ok or type(v) ~= "table" then error("schedule_ids failed") end
      ids = v
      S.sched_ids = v
    end
    local map = {}
    for _, cid in ipairs(ids) do
      local shop = S.shop_of[cid]
      if shop == nil then
        local ok, v = call("shop_of", cid)
        shop = (ok and v ~= nil) and v or false
        S.shop_of[cid] = shop
      end
      if shop then
        local l = map[shop]
        if l == nil then l = {}; map[shop] = l end
        l[#l + 1] = cid
      end
    end
    for _, l in pairs(map) do table.sort(l) end
    S.shop_cids = map
    return map
  end

  local function seller_pos(cid)
    local x, y, z
    if a.npc_alive(cid) then x, y, z = a.npc_pos(cid) end
    local p = nil
    if x ~= nil then p = { x = x, y = y, z = z }
    else
      local ok, sp = call("schedule_pos", cid)
      if ok and valid_pos(sp) then p = { x = sp.x, y = sp.y, z = sp.z } end
    end
    if p == nil or near_zero(p) then return nil end
    return p
  end

  -- the first of a shop's sellers with a usable position: cid, pos (or nil)
  local function first_seller_cid(sid)
    for _, cid in ipairs(ensure_shop_cids()[sid] or {}) do
      local p = seller_pos(cid)
      if p ~= nil then return cid, p end
    end
    return nil
  end

  local function npc_label(cid)
    return a.npc_name(cid) or ("NPC " .. tostring(cid))
  end

  -- shop buy rows grouped as item -> { { sid, rows }, ... } in shop-id order
  local function sorted_sids(shops)
    local sids = {}
    for sid in pairs(shops) do sids[#sids + 1] = sid end
    table.sort(sids, function(p, q)
      if type(p) == type(q) then return p < q end
      return tostring(p) < tostring(q)
    end)
    return sids
  end

  local function index_buys(shops)
    local sids = sorted_sids(shops)
    local by_item = {}
    for _, sid in ipairs(sids) do
      local groups = {}
      for _, b in ipairs(shops[sid]) do
        if type(b) == "table" and b.item ~= nil and b.item == b.item then
          local g = groups[b.item]
          if g == nil then g = {}; groups[b.item] = g end
          g[#g + 1] = b
        end
      end
      for item, rows in pairs(groups) do
        local l = by_item[item]
        if l == nil then l = {}; by_item[item] = l end
        l[#l + 1] = { sid = sid, rows = rows }
      end
    end
    return by_item
  end

  -- the adapter caches real names and retries a failed read
  local function item_name(id)
    return a.item_name(id) or ("Item " .. tostring(id))
  end

  local function ensure_shops()
    if S.shops == nil then
      local ok, v = call("shops")
      if not ok or type(v) ~= "table" then error("shops failed") end
      S.buys = index_buys(v)
      S.shops = v
    end
  end

  -- quest id -> state, read once per cache
  local function quest_state_cache()
    local qstate = {}
    return function(rq)
      local st = qstate[rq]
      if st == nil then
        st = a.quest_state(rq)
        if st == nil then st = false end
        qstate[rq] = st
      end
      return st or nil
    end
  end

  -- the game writes -1 for "no unlock quest" (shop 41 in game)
  local function row_counts(b, quest_state)
    local rq = b.release_qid
    local gated = type(rq) == "number" and rq > 0
    return not (gated and quest_state(rq) ~= "completed")
  end

  -- the game writes sentiment bit 1 (lowest rank) on unlocked rows
  local function row_locked(b)
    local sb = b.sentiment_bit
    return (type(sb) == "number" and sb > 1) or nz(b.total_pay) or nz(b.flag)
      or nz(b.var_cond)
  end

  local function compute_sellers()
    local needs = a.item_needs()
    if type(needs) ~= "table" then return {} end
    local by_item = core.needs_by_item(needs)
    local located = {}
    for _, r in ipairs(a.item_locations() or {}) do
      if type(r) == "table" and type(r.id) == "number" then located[r.id] = true end
    end
    local wanted = {}
    for id in pairs(by_item) do
      if not located[id] then wanted[#wanted + 1] = id end
    end
    if #wanted == 0 then return {} end
    table.sort(wanted)

    ensure_shops()
    ensure_shop_cids()
    local quest_state = quest_state_cache()

    local out = {}
    for _, id in ipairs(wanted) do
      local qs = by_item[id]
      table.sort(qs)
      local qn = {}
      for _, q in ipairs(qs) do qn[#qn + 1] = (core.quest_display_name(a, q)) end
      for _, grp in ipairs(S.buys[id] or {}) do
        local sid = grp.sid
        local passing, locked = 0, true
        for _, b in ipairs(grp.rows) do
          if row_counts(b, quest_state) then
            passing = passing + 1
            if not row_locked(b) then locked = false end
          end
        end
        if passing > 0 then
          local cid, p = first_seller_cid(sid)
          if cid ~= nil then
            out[#out + 1] = { shop = sid, item = id,
              item_name = a.item_name(id), cid = cid,
              npc = npc_label(cid),
              qids = { table.unpack(qs) }, quest = table.concat(qn, " / "),
              pos = p, maybe_locked = locked }
          end
        end
      end
    end
    return out
  end

  -- ----- monster drops for map search (SPEC 19.12.3) -----
  local function ensure_drops()
    if S.drop_ids ~= nil then return S.drop_ids end
    local ok, v = call("monster_drops")
    if not ok or type(v) ~= "table" then error("monster drops failed") end
    S.drop_ids = v
    if stats.drops_first_ms == nil then
      stats.drops_first_ms = stats.ms.monster_drops
      local n_cids, n_ids = 0, 0
      for _, l in pairs(v) do
        n_cids = n_cids + 1
        n_ids = n_ids + #l
      end
      stats.drops = { cids = n_cids, ids = n_ids }
    end
    return v
  end

  -- { [cid] = { name, ... } } for the cids of this round's monster entries
  local function drop_names(ids, monsters)
    local out = {}
    for _, m in ipairs(monsters) do
      for _, cid in ipairs(m.cids or {}) do
        if out[cid] == nil then
          local list, seen = {}, {}
          for _, id in ipairs(ids[cid] or {}) do
            local nm = a.item_name(id)
            if nm ~= nil and nm ~= "" and nm ~= "Item " .. tostring(id) then
              local low = nm:lower()
              if not seen[low] then
                seen[low] = true
                list[#list + 1] = nm
              end
            end
          end
          if #list > 0 then out[cid] = list end
        end
      end
    end
    return out
  end

  -- ----- shop index for map search and the Shops toggle (SPEC 19.7.1-19.7.2, 20.2) -----
  -- Query-independent: core does the matching and the labelling. One entry per shop that has a
  -- seller position and at least one counting buy row.
  local function compute_shops()
    ensure_shops()
    ensure_shop_cids()
    local quest_state = quest_state_cache()
    local sids = sorted_sids(S.shops)
    local out = {}
    for _, sid in ipairs(sids) do
      local cid, p = first_seller_cid(sid)
      if cid ~= nil then
        local items, by_id = {}, {}
        for _, b in ipairs(S.shops[sid]) do
          if type(b) == "table" and b.item ~= nil and b.item == b.item then
            if row_counts(b, quest_state) then
              local lk = row_locked(b)
              local it = by_id[b.item]
              if it == nil then
                it = { name = item_name(b.item), locked = true }
                by_id[b.item] = it
                items[#items + 1] = it
              end
              if not lk then it.locked = false end
            end
          end
        end
        if #items > 0 then
          out[#out + 1] = { shop = sid, cid = cid,
            npc = npc_label(cid),
            pos = p, discovered = discovered("s:" .. tostring(sid), p),
            items = items }
        end
      end
    end
    return out
  end

  -- ----- record index -----
  local function build_records(recs)
    local by = {}
    for _, r in ipairs(recs) do
      if type(r) == "table" and type(r.key) == "string" then
        local g = r.guid or guid_of(r.key)
        local l = by[g]
        if l == nil then l = {}; by[g] = l end
        l[#l + 1] = r
      end
    end
    return by
  end

  -- ----- effective atlas -----
  local function effective()
    local eff = {}
    for uid, e in pairs(static) do eff[uid] = e end
    for uid, e in pairs(S.file_monsters) do eff[uid] = e end
    for uid, e in pairs(learned) do
      if e.k == "chest" and eff[uid] ~= nil then
        if e.items == nil then e.items = eff[uid].items end
        if e.quest == nil then e.quest = eff[uid].quest end
        if e.trap == nil then e.trap = eff[uid].trap end
        if e.pawn == nil then e.pawn = eff[uid].pawn end
      end
      eff[uid] = e
    end
    for uid, e in pairs(S.live) do eff[uid] = e end
    return eff
  end

  local KEPT_ITEMS = { [77] = true, [78] = true, [81] = true }

  -- kinds in spec order: ng_shard, kept, quest, trap, pawn
  local round_errs = {}

  local function chest_kinds(row, e, recs)
    local id = row.id
    local items = row.items or e.items
    local kinds = {}
    if id == 692 or id == 693 or id == 694 then kinds[#kinds + 1] = "ng_shard" end
    local kept = false
    if id == 10 or id == 11 or id == 12 then
      for _, it in ipairs(items or {}) do
        if KEPT_ITEMS[it.id] then kept = true end
      end
    end
    if not kept then
      for _, r in ipairs(recs or {}) do
        if r.keep == true then kept = true end
      end
    end
    if kept then kinds[#kinds + 1] = "kept" end
    if type(row.quest) == "table" then kinds[#kinds + 1] = "quest" end
    if row.trap == true then kinds[#kinds + 1] = "trap" end
    if row.pawn == true then kinds[#kinds + 1] = "pawn" end
    return kinds
  end

  -- an info is known only when its quest has a known finish (spec 27.4.1)
  local function quest_met_of(quest, quest_state)
    if quest.var then return nil end
    local vals = {}
    for i, p in ipairs(quest.q) do
      local st = quest_state(p[1])
      if st == nil then vals[i] = "nil" else vals[i] = p[2] and "true" or "false" end
    end
    if #vals == 0 then return nil end
    local nt, nf = 0, 0
    for _, v in ipairs(vals) do
      if v == "true" then nt = nt + 1 elseif v == "false" then nf = nf + 1 end
    end
    if quest.any then
      if nt > 0 then return true end
      if nf > 0 then return false end
      return nil
    end
    if nf > 0 then return false end
    if nt == #vals then return true end
    return nil
  end

  -- mixed finish checks (some true, some false) use the "after" wording;
  -- only an all-false set says "until"
  local function quest_text_of(quest, reveal)
    local names, seen = {}, {}
    local until_form = #quest.q > 0
    for _, p in ipairs(quest.q) do
      local ok, nm = pcall(core.gate_name, p[1], a, reveal)
      if not ok or type(nm) ~= "string" or nm == "" then nm = "another quest" end
      if not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
      if p[2] then until_form = false end
    end
    if #names == 0 then return "quest-gated" end
    local joined = names[1]
    if #names >= 2 then
      joined = joined .. (quest.any and " or " or " and ") .. names[2]
    end
    if #names > 2 then joined = joined .. ", ..." end
    if until_form then
      return "until " .. joined .. (#names >= 2 and " end" or " ends") .. ", missable"
    end
    return "after " .. joined
  end

  local function badge(cid)
    local n = S.badge[cid]
    if n == nil then
      local ok, v = call("badge_name", cid)
      if ok and type(v) == "string" and v:match("%S") then n = v else n = "Monster" end
      S.badge[cid] = n
    end
    return n
  end

  local function pcopy(e) return { x = e.x, y = e.y, z = e.z } end

  -- ----- NPC names, positions and the route (SPEC 22.7, 22.8) -----
  local function sched_ids_list()
    if S.sched_ids == nil then
      local ok, v = call("schedule_ids")
      if ok and type(v) == "table" then S.sched_ids = v end
    end
    return S.sched_ids
  end

  local function cid_set(list)
    local set = {}
    for _, c in ipairs(type(list) == "table" and list or {}) do set[c] = true end
    return set
  end

  local function cid_signature(list)
    if type(list) ~= "table" or #list == 0 then return "" end
    local t = {}
    for i, c in ipairs(list) do t[i] = tostring(c) end
    table.sort(t)
    return table.concat(t, ",")
  end

  local function is_generic(cid)
    if type(a.is_generic) ~= "function" then return false end
    local ok, g = pcall(a.is_generic, cid)
    return ok and g == true
  end

  local function read_name(cid)
    local ok, nm = pcall(a.npc_name, cid)
    if ok and type(nm) == "string" and nm ~= "" then return nm end
    return nil
  end

  -- builds up to NPC_NAME_SLICE more names; sets rerun until the list is done
  local function build_names()
    if S.npc_done then return end
    local ids = sched_ids_list()
    if ids == nil then return end
    local last = math.min(S.npc_next + M.K.NPC_NAME_SLICE - 1, #ids)
    for i = S.npc_next, last do
      local cid = ids[i]
      if not is_generic(cid) then
        local nm = read_name(cid)
        if nm ~= nil then S.npc_list[#S.npc_list + 1] = { cid = cid, name = nm } end
      end
    end
    S.npc_next = last + 1
    if S.npc_next > #ids then
      S.npc_done = true
    else
      rerun = true
    end
  end

  local function npc_round(tg)
    local t0 = clock()
    build_names()
    local dt = (clock() - t0) * 1000
    S.npc_ms = S.npc_ms + dt
    if dt > (stats.npcs_max_slice_ms or 0) then stats.npcs_max_slice_ms = dt end
    if S.npc_done and stats.npcs_first_ms == nil then
      stats.npcs_first_ms = S.npc_ms
    end
    local want = cid_set(tg.npc_cids)
    local out = {}
    for i, e in ipairs(S.npc_list) do
      local n = { cid = e.cid, name = e.name }
      if want[e.cid] then
        local ok, alive = pcall(a.npc_alive, e.cid)
        n.alive = ok and alive == true
        local okp, p = pcall(seller_pos, e.cid)
        n.pos = okp and p or nil
        -- keyed by 200 m cell too, so an NPC that travels gets a fresh answer
        if n.pos ~= nil then
          n.discovered = discovered(string.format("n:%d:%d:%d", e.cid,
            n.pos.x // 200, n.pos.z // 200), n.pos)
        end
      end
      out[i] = n
    end
    return out
  end

  local ROUTE_ERR = "route unavailable"

  -- the raw route for the set NPC at this hour; nil for an NPC with no
  -- route (Ruling 3); raises on any failed read
  local function build_route(npcs, cid, day, hour)
    local ok, cur = pcall(reads.current_row, cid)
    if not ok then error("current_row failed") end
    local okr, rows = pcall(reads.schedule_rows, cid)
    if not okr or type(rows) ~= "table" then error("schedule_rows failed") end
    cur = type(cur) == "table" and cur or nil
    -- the quest stage's whole day replaces the live overwrite list in a
    -- copy (SPEC 26.4); a nil, empty or failed read keeps the live input
    if cur ~= nil and type(reads.quest_overrides) == "function" then
      local okq, qrows = call("quest_overrides", cid)
      if okq and type(qrows) == "table" and #qrows > 0 then
        local copy = {}
        for k, v in pairs(cur) do copy[k] = v end
        copy.overwrite = qrows
        cur = copy
      end
    end
    local function area_pos(row)
      -- a key location wins; a -1/-1 row without one has no place (spec 25.4.3)
      if type(row.key) == "number" and row.key > 0 and type(reads.key_pos) == "function" then
        local okk, kp = pcall(reads.key_pos, row.key)
        if okk and kp ~= nil then return kp end
      end
      if row.area == -1 and row.location == -1 then return nil end
      local okn, list = pcall(reads.area_nodes, row)
      if not okn or type(list) ~= "table" then return nil end
      return npcs.anchor_node(list)
    end
    local stops, unplaced, matched = npcs.route_stops(rows, npcs.today(day, hour), area_pos, cur)
    if type(stops) ~= "table" then error("route_stops failed") end
    if #stops == 0 then return nil end
    return { stops = stops, unplaced = unplaced or 0, off_schedule = (matched == false) or nil }
  end

  local function route_round()
    local cid, name = S.route_cid, S.route_name
    if cid == nil then return nil end
    local errt = { cid = cid, name = name, err = ROUTE_ERR }
    if type(reads.schedule_now) ~= "function" then return errt end
    local okn, day, hour = pcall(reads.schedule_now)
    if not okn or type(day) ~= "number" or type(hour) ~= "number" then return errt end
    -- the current entry's signature, read once per round (spec 25.5); a
    -- fixture without the read has none
    local sig = ""
    if type(reads.current_sig) == "function" then
      local ts = clock()
      local oks, a, l, k, o = pcall(reads.current_sig, cid)
      stats.ms.route_sig = (clock() - ts) * 1000
      if not oks then return errt end
      sig = tostring(a) .. "|" .. tostring(l) .. "|" .. tostring(k) .. "|" .. tostring(o)
    end
    local c = S.route_cache
    if c == nil or c.cid ~= cid or c.hour ~= hour or c.day ~= day or c.sig ~= sig then
      local t0 = clock()
      local ok, built = pcall(function()
        return build_route(require("Clairvoyance.npcs"), cid, day, hour)
      end)
      stats.ms.route = (clock() - t0) * 1000
      -- a failed build is not kept: the next round retries it
      if not ok then return errt end
      c = { cid = cid, hour = hour, day = day, sig = sig, value = built }
      S.route_cache = c
    end
    if c.value == nil then return errt end
    refresh_discovery()
    local stops = {}
    for i, st in ipairs(c.value.stops) do
      local n = {}
      for k, v in pairs(st) do n[k] = v end
      if valid_pos(st.pos) then
        local dkey = "r:" .. tostring(st.area) .. ":" .. tostring(st.location)
        if type(st.key) == "number" and st.key > 0 then dkey = "r:k:" .. st.key end
        n.discovered = discovered(dkey, st.pos)
      end
      stops[i] = n
    end
    return { cid = cid, name = name, stops = stops, unplaced = c.value.unplaced,
             off_schedule = c.value.off_schedule }
  end

  -- ----- the round -----
  local function round(now, tg)
    stats.hits, stats.misses = 0, 0
    S.live = {}
    local any_rec = tg.chests or tg.tokens or tg.beetles
    local need_shops = tg.search or tg.shops
    local cast_ok = ensure_cast()
    ensure_boss()
    local boss_ok = S.boss ~= nil
    if tg.monsters then read_loaded_boss() end

    local rows = table_read("reserved_rows")
    if cast_ok and boss_ok and S.need_sort then sort_places() end
    local reserved_uids = nil
    if rows ~= nil then reserved_uids = learn_reserved(rows, cast_ok and boss_ok) end
    local loaded_seen = read_loaded(reserved_uids)
    if rows ~= nil then remove_patched(rows, reserved_uids) end

    ensure_settlements()

    -- schedule positions of cast NPCs (SPEC 17.3b.1.2)
    local schedule = {}
    if S.cast ~= nil and type(reads.schedule_pos) == "function" then
      local t0 = clock()
      for _, cid in ipairs(S.cast_list) do
        local ok, p = pcall(reads.schedule_pos, cid)
        if ok and valid_pos(p) and not near_zero(p) then
          schedule[cid] = { x = p.x, y = p.y, z = p.z }
        end
      end
      stats.ms.schedule_loop = (clock() - t0) * 1000
    end

    local rec_idx = nil
    if any_rec then
      rec_idx = guarded("records", function()
        return build_records(need_table("save_records"))
      end)
    end
    if loaded_seen ~= nil and rec_idx ~= nil then
      for uid in pairs(loaded_seen) do
        if rec_idx[uid] ~= nil then stats.hits = stats.hits + 1
        else stats.misses = stats.misses + 1 end
      end
    end

    local eff = effective()
    local out = { chests = {}, treasure = {}, tokens = {}, beetles = {},
      monsters = {}, sellers = {}, schedule = schedule, settlements = {} }

    if S.settle ~= nil then
      for _, s in ipairs(S.settle) do
        out.settlements[#out.settlements + 1] = { name = s.name, pos = pcopy(s.pos) }
      end
    end

    -- chests, tokens, beetles
    local uids = sorted_keys(eff)
    local chest_qs = nil
    for _, uid in ipairs(uids) do
      local e = eff[uid]
      if e.k == "chest" and tg.chests then
        local state, item = "unknown", nil
        local recs = rec_idx and rec_idx[uid] or nil
        if recs ~= nil then
          local has, picked = false, false
          for _, r in ipairs(recs) do
            if r.picked ~= nil then has = true end
            if r.picked == true then picked = true end
            -- item 0 is the save's "none" (seen on gimmick-12 chests)
            if item == nil and (to_int(r.item) or 0) > 0 then item = to_int(r.item) end
          end
          if has then state = picked and "opened" or "unopened" end
        end
        local c = { uid = uid, pos = pcopy(e), gimmick = e.id, state = state,
          item = item, item_name = item ~= nil and item_name(item) or nil }
        local row = static[uid] or e
        c.kinds = chest_kinds(row, e, recs)
        if type(row.quest) == "table" then
          c.quest_text = quest_text_of(row.quest, tg.reveal_gate_names == true)
          chest_qs = chest_qs or quest_state_cache()
          c.quest_met = quest_met_of(row.quest, function(q)
            local ok, v = pcall(chest_qs, q)
            if ok then return v end
            return nil
          end)
        end
        if e.items ~= nil then
          c.items = {}
          for _, it in ipairs(e.items) do
            c.items[#c.items + 1] = { name = item_name(it.id), n = it.n }
          end
        end
        out.chests[#out.chests + 1] = c
      elseif COLLECT[e.k] and tg[COLLECT[e.k].list] then
        local def = COLLECT[e.k]
        local state = "unknown"
        if rec_idx ~= nil then
          state = "not"
          for _, r in ipairs(rec_idx[uid] or {}) do
            if def.done(r) then state = "collected" end
          end
        end
        local list = out[def.list]
        list[#list + 1] = { uid = uid, pos = pcopy(e),
          name = item_name(M.K[def.item]), state = state }
      end
    end

    -- treasure
    if tg.treasure or tg.sellers or need_shops then refresh_discovery() end
    if tg.treasure then
      if S.nodes == nil then
        local v = table_read("treasure_nodes")
        if v ~= nil then S.nodes = v end
      end
      -- each node's nearest places chest row within 3 units (SPEC 24.4); the
      -- places rows are fixed after load, so this runs once per session
      if S.nodes ~= nil and S.node_chest == nil then
        local uids = {}
        for uid, e in pairs(static) do
          if e.k == "chest" then uids[#uids + 1] = uid end
        end
        table.sort(uids)
        local map = {}
        for _, n in ipairs(S.nodes) do
          if type(n) == "table" and valid_pos(n.pos) then
            local best, bd = nil, 9
            for _, uid in ipairs(uids) do
              local e = static[uid]
              local dx, dy, dz = e.x - n.pos.x, e.y - n.pos.y, e.z - n.pos.z
              local d2 = dx * dx + dy * dy + dz * dz
              if d2 <= bd and (best == nil or d2 < bd) then best, bd = e, d2 end
            end
            map[n.name] = best
          end
        end
        S.node_chest = map
      end
      local checked = guarded("checked", function() return need_table("checked_nodes") end)
      for _, n in ipairs(S.nodes or {}) do
        if type(n) == "table" and valid_pos(n.pos) then
          out.treasure[#out.treasure + 1] = { name = n.name, pos = pcopy(n.pos),
            checked = checked ~= nil and checked[n.name] == true,
            discovered = discovered("t:" .. tostring(n.name), n.pos) }
          local ce = S.node_chest ~= nil and S.node_chest[n.name] or nil
          if ce ~= nil and ce.items ~= nil then
            local t = out.treasure[#out.treasure]
            t.items = {}
            for _, it in ipairs(ce.items) do
              t.items[#t.items + 1] = { name = item_name(it.id), n = it.n }
            end
          end
        end
      end
      table.sort(out.treasure, function(p, q) return p.name < q.name end)
    end

    -- shop stock index for map search or the Shops toggle (SPEC 19.7.1, 20.2);
    -- runs before the sellers so a shared first S.shops / shop-cid read is
    -- charged to search_first_ms, whichever trigger ran it first
    local first_shops = stats.search_first_ms == nil
    if need_shops then
      local t0 = clock()
      local list = guarded("shop_index", compute_shops)
      out.shops = list or {}
      if stats.search_first_ms == nil and list ~= nil then
        stats.search_first_ms = (clock() - t0) * 1000
      end
    end

    -- sellers
    if tg.sellers then
      local list = guarded("sellers", compute_sellers)
      for _, s in ipairs(list or {}) do
        local c = {}
        for k, v in pairs(s) do c[k] = v end
        c.discovered = discovered("s:" .. tostring(s.shop), s.pos)
        out.sellers[#out.sellers + 1] = c
      end
    end

    -- monsters
    if tg.monsters and cast_ok and boss_ok then
      local units = guarded("respawn", function() return need_table("respawn_units") end)
      local items = {}
      for uid, e in pairs(eff) do
        if e.k == "monster" then
          local nm = e.name or names[e.id]
          local fam = fam_of(nm)
          local cls = family_class(fam)
          if cls ~= "drop" then
            items[uid] = { uid = uid, cid = e.id, fam = fam or "?", pos = pcopy(e),
              small = cls == "small", respawning = false }
          end
        end
      end
      for _, u in ipairs(units or {}) do
        if type(u) == "table" and type(u.key) == "string" and to_int(u.cid) ~= nil then
          local uid = guid_of(u.key)
          local cid = to_int(u.cid)
          if type(u.cid_name) == "string" and u.cid_name ~= "" then names[cid] = u.cid_name end
          local cls = classify(cid, u.cid_name, nil, nil)
          if cls == "large" or cls == "small" then
            if items[uid] ~= nil then
              items[uid].respawning = true
            elseif valid_pos(u.pos) and not near_zero(u.pos) then
              local nm = names[cid]
              items[uid] = { uid = uid, cid = cid,
                fam = fam_of(nm) or "?",
                pos = pcopy(u.pos), small = cls == "small", respawning = true }
            end
          end
        end
      end
      -- clustering per family (SPEC 17.10.9)
      local fams = {}
      for uid, it in pairs(items) do
        local l = fams[it.fam]
        if l == nil then l = {}; fams[it.fam] = l end
        l[#l + 1] = uid
      end
      local ids = {}
      for _, fam in ipairs(sorted_keys(fams)) do
        table.sort(fams[fam])
        for _, c in ipairs(M.cluster(items, fams[fam], M.K.CLUSTER)) do
          local s = c.seed
          local nm = badge(s.cid)
          if c.count > 1 then nm = nm .. " x" .. c.count end
          out.monsters[#out.monsters + 1] = { uid = s.uid, cid = s.cid, name = nm,
            pos = pcopy(s.pos), respawning = c.respawning == true,
            small = s.small == true, count = c.count, cids = c.cids }
          ids[s.cid] = true
        end
      end
      table.sort(out.monsters, function(p, q) return p.uid < q.uid end)
      stats.monster_ids = sorted_keys(ids)
    end

    -- drops: deferred past the round whose shop index first succeeds (19.12.3.3)
    if tg.search and tg.monsters then
      if first_shops and stats.search_first_ms ~= nil and S.drop_ids == nil then
        rerun = true
      elseif #out.monsters > 0 then
        local ids = guarded("drops", ensure_drops)
        if ids ~= nil then
          local t0 = clock()
          out.drops = guarded("drop_names", function()
            return drop_names(ids, out.monsters)
          end)
          stats.ms.drop_names = (clock() - t0) * 1000
        end
      end
    end

    for _, cat in ipairs({ "chests", "treasure", "tokens", "beetles", "monsters", "sellers" }) do
      stats.known[cat] = #out[cat]
    end
    if tg.search then out.npcs = npc_round(tg) end
    out.route = route_round()
    return out
  end

  -- ----- save -----
  local function do_save(reason, now)
    if not dirty or not committed then return false end
    local entries = {}
    for uid, e in pairs(learned) do
      local t = { k = e.k, id = e.id, x = e.x, y = e.y, z = e.z }
      if e.table_ix ~= nil then t.table_ix = e.table_ix end
      if e.name ~= nil then t.name = e.name end
      entries[uid] = t
    end
    local doc = { version = M.K.FILE_VERSION, pak = places.pak or loaded_pak,
      entries = entries }
    local t0 = clock()
    local ok, r = pcall(io.dump, M.K.ATLAS, doc)
    stats.save_ms = (clock() - t0) * 1000
    last_save = now
    if ok and r ~= false then
      dirty = false
      stats.saves = stats.saves + 1
      stats.last_save_reason = reason
      return true
    end
    return false
  end

  -- a round result whose route is on: no error, the current cid, a stop
  local function published_on(res)
    local r = res and res.route
    return type(r) == "table" and r.err == nil and r.cid == S.route_cid
      and type(r.stops) == "table" and #r.stops > 0
  end

  -- ----- public -----
  function w:refresh(now, gate, toggles)
    if not gate or type(toggles) ~= "table" then return false end
    local tg = toggles
    if not (tg.chests or tg.treasure or tg.tokens or tg.beetles or tg.monsters
      or tg.sellers or tg.search or tg.shops) then
      return false
    end
    if last_round ~= nil and now - last_round < M.K.WORLD_ROUND
      and not (tg.search and cid_signature(tg.npc_cids) ~= S.npc_sig) then
      return false
    end
    last_round, last_now = now, now
    rerun = false
    if tg.search then S.npc_sig = cid_signature(tg.npc_cids) end
    local rt0 = clock()
    local ok, res = pcall(round, now, tg)
    stats.round_ms = (clock() - rt0) * 1000
    if not ok then
      local msg = tostring(res)
      if not round_errs[msg] then
        round_errs[msg] = true
        pcall(io.log, "round failed: " .. msg)
      end
    end
    if not ok or type(res) ~= "table" then return false end
    if published_on(res) and not published_on(input_tbl) then w.route_gen = w.route_gen + 1 end
    input_tbl = res
    committed = true
    if rerun then rerun = false; last_round = nil end
    stats.rounds = stats.rounds + 1
    if dirty and (last_save == nil or now - last_save >= M.K.SAVE_EVERY) then
      do_save("round", now)
    end
    return true
  end

  function w:input() return input_tbl end

  -- the next refresh runs a round even inside the throttle window
  function w:poke() last_round = nil end

  -- SPEC 22.8: the route NPC; the next refresh builds it
  function w:set_route(cid, name)
    if cid ~= S.route_cid then w.path_job = nil; w.route_gen = w.route_gen + 1 end
    S.route_cid, S.route_name, S.route_cache = cid, name, nil
    last_round = nil
  end

  function w:clear_route()
    w.path_job = nil
    w.route_gen = w.route_gen + 1
    S.route_cid, S.route_name, S.route_cache = nil, nil, nil
    if input_tbl ~= nil then input_tbl.route = nil end
  end

  -- SPEC 22.9.3: walk n holder slots per call; a finished pass replaces
  -- w.spawned. Sentiment is re-read at most once per second per cid.
  function w:spawned_step(n)
    if S.walk_i == 0 then
      local okc, count = pcall(reads.holder_count)
      if not okc or type(count) ~= "number" or count <= 0 then return end
      S.walk_n, S.walk_acc = count, {}
    end
    local npcs = require("Clairvoyance.npcs")
    local now = clock()
    local last = math.min(S.walk_i + n, S.walk_n)
    for i = S.walk_i, last - 1 do
      local ok, h = pcall(reads.holder_at, i)
      if ok and type(h) == "table" and h.cid ~= nil and not is_generic(h.cid) then
        local nm = read_name(h.cid)
        if nm ~= nil then
          local s = S.sent[h.cid]
          if s == nil or now - s.at >= M.K.SENTIMENT_EVERY then
            local oks, rank, value = pcall(reads.sentiment, h.holder)
            local tier = nil
            if oks then
              local okt, t = pcall(npcs.tier, rank)
              if okt then tier = t end
            end
            s = { at = now, tier = tier, value = oks and value or nil }
            S.sent[h.cid] = s
          end
          S.walk_acc[#S.walk_acc + 1] = { cid = h.cid, name = nm,
            transform = h.transform, tier = s.tier, value = s.value, tier_at = s.at }
        end
      end
    end
    S.walk_i = last
    if last >= S.walk_n then
      w.spawned, S.walk_i, S.walk_acc = S.walk_acc, 0, {}
    end
  end

  function w:givers()
    if givers_cache ~= nil and givers_rev == rev then return givers_cache end
    local out, ids = {}, {}
    for uid, e in pairs(learned) do
      if e.k == "giver" then
        local cur = ids[e.id]
        if cur == nil or uid < cur then
          ids[e.id] = uid
          out[e.id] = { x = e.x, y = e.y, z = e.z }
        end
      end
    end
    givers_cache, givers_rev = out, rev
    return out
  end

  function w:places_state()
    return { state = places.state, stale = unlisted > M.K.UNLISTED_STALE }
  end

  function w:reset()
    S = new_session()
    w.path_job = nil
    if type(reads.reset) == "function" then pcall(reads.reset) end
    input_tbl = nil
    committed = false
    last_round = nil
    unlisted = 0
    stats.search_first_ms = nil
    stats.npcs_first_ms, stats.npcs_max_slice_ms = nil, nil
    stats.drops_first_ms, stats.drops = nil, nil
    w.spawned = {}
  end

  function w:save(reason)
    return do_save(reason or "manual", last_now)
  end

  function w:stats()
    local nfile, nlearned = 0, 0
    for _ in pairs(static) do nfile = nfile + 1 end
    for _ in pairs(S.file_monsters) do nfile = nfile + 1 end
    for _ in pairs(learned) do nlearned = nlearned + 1 end
    local ms, known, ids = {}, {}, {}
    for k, v in pairs(stats.ms) do ms[k] = v end
    for k, v in pairs(stats.known) do known[k] = v end
    for i, v in ipairs(stats.monster_ids) do ids[i] = v end
    local drops = nil
    if stats.drops ~= nil then
      drops = { cids = stats.drops.cids, ids = stats.drops.ids }
    end
    return {
      atlas = { file = nfile, learned = nlearned, dropped = atlas_dropped,
        pruned = atlas_pruned },
      places = { state = places.state, rows = places.rows, dropped = places.dropped,
        load_ms = places.load_ms, slow = places.slow, pak = places.pak },
      index = { hits = stats.hits, misses = stats.misses },
      unlisted = unlisted, ms = ms, known = known, monster_ids = ids,
      search_first_ms = stats.search_first_ms, npcs_first_ms = stats.npcs_first_ms,
      npcs_max_slice_ms = stats.npcs_max_slice_ms,
      round_ms = stats.round_ms,
      drops_first_ms = stats.drops_first_ms, drops = drops,
      rounds = stats.rounds, saves = stats.saves, save_ms = stats.save_ms,
      last_save_reason = stats.last_save_reason,
    }
  end

  -- ----- walking graph copy and route paths (SPEC 23.6) -----
  -- The game graph is copied into flat arrays across frames; route paths
  -- are searched over the copy (never through a game path query).
  w.paths, w.near, w.copy_tries, w.pver = {}, {}, 0, 0
  w.copy_ms_max, w.search_ms_max = 0, 0
  local PATH_CAP = 64
  local path_order = {}        -- w.paths keys, oldest first
  local fail_gen = nil         -- w.route_gen when the copy last failed
  local blockbuf = { x = {}, y = {}, z = {}, lc = {}, lb = {}, ln = {} }
  local copy_failed = false
  local rp = nil               -- cached route pairs, keys and drawn list
  local rp_empty = {}

  -- the published route stops, or nil when no route is on
  local function route_stops()
    if not published_on(input_tbl) then return nil end
    return input_tbl.route.stops
  end

  local function copy_fail(err)
    w.copy, copy_failed, fail_gen = nil, true, w.route_gen
    w.copy_tries = w.copy_tries + 1
    pcall(io.log, "graph copy failed: " .. tostring(err))
  end

  -- one budgeted slice of the copy: blocks in order, then link resolution
  local function copy_run(c, limit)
    local t0 = clock()
    if c.nb == nil then
      local n = reads.graph_block_count()
      if type(n) ~= "number" or n < 1 then error("no graph blocks") end
      c.nb, c.b, c.nn, c.nl = n, 0, 0, 0
      c.off, c.x, c.y, c.z, c.lc, c.lb, c.ln = {}, {}, {}, {}, {}, {}, {}
    end
    local nb = c.nb
    local did = false
    while c.b < nb do
      -- size the read from the running mean ms a node (first read 16 nodes)
      -- the mean is floored (a 1 ms clock reads short reads as 0) and the
      -- read is capped, so a count is always a finite number
      local count = 16
      if (c.tn or 0) > 0 then
        local mean = c.tsum / c.tn
        if mean < 0.00002 then mean = 0.00002 end
        count = math.floor((limit - (clock() - t0)) / mean)
        if not (count >= 1) then
          if did then return end
          count = 1
        elseif count > 128 then
          count = 128
        end
      end
      local first = c.k or 1
      local tb = clock()
      local n, filled = reads.graph_block(c.b, blockbuf, first, count)
      if type(n) ~= "number" or n < 0 or type(filled) ~= "number" or filled < 0 then
        error("bad graph block")
      end
      local x, y, z, lc, lb, ln = c.x, c.y, c.z, c.lc, c.lb, c.ln
      local bx, by, bz, blc = blockbuf.x, blockbuf.y, blockbuf.z, blockbuf.lc
      local nn, nl = c.nn, c.nl
      if first == 1 then c.off[c.b + 1] = nn end
      local tl = 0
      for k = 1, filled do
        nn = nn + 1
        x[nn], y[nn], z[nn] = bx[k], by[k], bz[k]
        local m = blc[k]
        lc[nn] = m
        tl = tl + m
      end
      local blb, bln = blockbuf.lb, blockbuf.ln
      for k = 1, tl do
        lb[nl + k], ln[nl + k] = blb[k], bln[k]
      end
      c.nn, c.nl = nn, nl + tl
      if filled > 0 and first + filled - 1 < n then
        c.k = first + filled
      else
        c.k = nil
        c.b = c.b + 1
      end
      local now = clock()
      if filled > 0 then
        c.tsum = (c.tsum or 0) + (now - tb)
        c.tn = (c.tn or 0) + filled
      end
      did = true
      -- stop before a read that would likely overrun the budget
      if now - t0 >= limit then return end
    end
    if c.ri == nil then
      c.ri, c.rslot, c.wslot, c.ls, c.lt = 1, 1, 0, {}, {}
    end
    local nn, lc, lb, ln, off, ls, lt = c.nn, c.lc, c.lb, c.ln, c.off, c.ls, c.lt
    local ri, rslot, wslot = c.ri, c.rslot, c.wslot
    while ri <= nn do
      local m = lc[ri]
      ls[ri] = wslot + 1
      local valid = 0
      for s = rslot, rslot + m - 1 do
        local bo = off[lb[s] + 1]
        if bo ~= nil then
          local cnt = (off[lb[s] + 2] or nn) - bo
          local iid = ln[s]
          if iid >= 0 and iid < cnt then
            valid = valid + 1
            lt[wslot + valid] = bo + iid + 1
          end
        end
      end
      wslot = wslot + valid
      rslot = rslot + m
      lc[ri] = valid
      ri = ri + 1
      if ri % 256 == 0 and clock() - t0 >= limit then
        c.ri, c.rslot, c.wslot = ri, rslot, wslot
        return
      end
    end
    w.graph = { n = nn, x = c.x, y = c.y, z = c.z, ls = ls, lc = lc, lt = lt }
    w.copy = nil
  end

  local function stop_key(p)
    return string.format("%.1f,%.1f,%.1f", p.x, p.y, p.z)
  end

  local function same_route(c, stops, undisc)
    if c.undisc ~= undisc or c.cid ~= S.route_cid or c.n ~= #stops then return false end
    for i = 1, c.n do
      local s = stops[i]
      local p = s.pos
      if c.kd[i] ~= s.discovered or c.kx[i] ~= (p and p.x) or c.ky[i] ~= (p and p.y)
        or c.kz[i] ~= (p and p.z) then
        return false
      end
    end
    return true
  end

  local function build_rp(stops, undisc)
    local npcs = require("Clairvoyance.npcs")
    local c = { cid = S.route_cid, undisc = undisc, n = #stops,
      kx = {}, ky = {}, kz = {}, kd = {}, keys = {}, list_ver = -1 }
    for i = 1, c.n do
      local s = stops[i]
      local p = s.pos
      c.kd[i] = s.discovered
      if type(p) == "table" then c.kx[i], c.ky[i], c.kz[i] = p.x, p.y, p.z end
    end
    c.pairs = npcs.route_pairs(stops, undisc)
    for _, pr in ipairs(c.pairs) do
      for _, i in ipairs(pr) do
        if c.keys[i] == nil then c.keys[i] = stop_key(stops[i].pos) end
      end
    end
    c.list = {}
    return c
  end

  local function rp_get(stops, undisc)
    if rp == nil or not same_route(rp, stops, undisc) then rp = build_rp(stops, undisc) end
    return rp
  end

  -- the first unresolved item of the route: kind "near" (key, stop index)
  -- or "path" (path key, node a, node b); nil when every pair is settled
  local function next_target(c)
    local near, paths = w.near, w.paths
    for k = 1, #c.pairs do
      local pr = c.pairs[k]
      local ki, kj = c.keys[pr[1]], c.keys[pr[2]]
      local a, b = near[ki], near[kj]
      if a == nil then return "near", ki, pr[1] end
      if b == nil then return "near", kj, pr[2] end
      if a and b then
        local pk = a * 1048576 + b
        if paths[pk] == nil then return "path", pk, a, b end
      end
    end
    return nil
  end

  -- never evicts a path of the shown route; evicts the oldest others
  local function store_path(pk, entry)
    w.paths[pk] = entry
    path_order[#path_order + 1] = pk
    if #path_order > PATH_CAP then
      local keep = {}
      for _, pr in ipairs(rp and rp.pairs or rp_empty) do
        local a, b = w.near[rp.keys[pr[1]]], w.near[rp.keys[pr[2]]]
        if a and b then keep[a * 1048576 + b] = true end
      end
      local i = 1
      while #path_order > PATH_CAP and i <= #path_order do
        local k = path_order[i]
        if keep[k] then
          i = i + 1
        else
          w.paths[k] = nil
          table.remove(path_order, i)
        end
      end
    end
    w.pver = w.pver + 1
  end

  w.store_path = store_path

  local function search_slice(stops, budget_ms, undisc)
    local npcs = require("Clairvoyance.npcs")
    local c = rp_get(stops, undisc)
    local kind, k, a, b = next_target(c)
    if kind == nil then w.path_job = nil; return end
    local t0 = clock()
    local j = w.path_job
    if kind == "near" then
      if j == nil or j.kind ~= "near" or j.key ~= k then
        local p = stops[a].pos
        j = { kind = "near", key = k, job = npcs.nearest_new(w.graph, p.x, p.y, p.z) }
        w.path_job = j
      end
      if npcs.nearest_step(j.job, budget_ms, clock) == "done" then
        w.near[k] = j.job.best or false
        w.path_job = nil
      end
    else
      if j == nil or j.kind ~= "path" or j.pk ~= k then
        j = { kind = "path", pk = k, job = npcs.path_new(w.graph, a, b) }
        w.path_job = j
      end
      local st = npcs.path_step(j.job, budget_ms, clock)
      if st ~= "running" then
        w.last_expanded, w.last_pair = j.job.expanded, k
        store_path(k, st == "done" and j.job.path or false)
        w.path_job = nil
      end
    end
    local ms = (clock() - t0) * 1000
    if ms > w.search_ms_max then w.search_ms_max = ms end
  end

  -- SPEC 23.6: the path_step target; one copy slice, else one search slice
  function w:path_step(budget_ms, route_path, undisc)
    undisc = undisc and true or false
    local stops = route_stops()
    local on = stops ~= nil
    local want = on and route_path == 1
    if want and w.copy == nil and w.graph == nil and w.copy_tries < 3
      and (not copy_failed or w.route_gen ~= fail_gen) then
      w.copy, copy_failed = {}, false
    end
    if w.copy ~= nil then
      local t0 = clock()
      local ok, err = pcall(copy_run, w.copy, (budget_ms or 0) / 1000)
      if not ok then copy_fail(err) end
      local ms = (clock() - t0) * 1000
      if ms > w.copy_ms_max then w.copy_ms_max = ms end
    elseif want and w.graph ~= nil then
      search_slice(stops, budget_ms, undisc)
    end
  end

  function w:path_busy() return w.copy ~= nil end

  function w:path_status(route_path)
    if route_path ~= 1 or route_stops() == nil then return nil end
    local c = w.copy
    if c ~= nil then
      local pct = 0
      if c.nb ~= nil then pct = (100 * c.b) // c.nb end
      return "path: copying " .. pct .. "%"
    end
    if w.graph == nil then
      if copy_failed then return "path unavailable" end
      return "path: copying 0%"
    end
    if rp == nil or not same_route(rp, route_stops(), rp.undisc) or next_target(rp) ~= nil then
      return "path: finding"
    end
    return "path ready"
  end

  -- per pair { i, j, pts }: pts a flat x, y, z list (map space), nil while
  -- not found. Rebuilt only when the route, undisc or w.paths changes.
  function w:route_paths(undisc)
    undisc = undisc and true or false
    local stops = route_stops()
    if stops == nil then return rp_empty end
    local c = rp_get(stops, undisc)
    if c.list_ver ~= w.pver then
      local g = w.graph
      local list = {}
      for k, pr in ipairs(c.pairs) do
        local item = { i = pr[1], j = pr[2] }
        local a, b = w.near[c.keys[pr[1]]], w.near[c.keys[pr[2]]]
        if g ~= nil and a and b then
          local e = w.paths[a * 1048576 + b]
          if e then
            local pts = e.pts
            if pts == nil then
              pts = {}
              for q, node in ipairs(e) do
                pts[q * 3 - 2], pts[q * 3 - 1], pts[q * 3] = g.x[node], g.y[node], g.z[node]
              end
              e.pts = pts
            end
            item.pts = pts
          end
        end
        list[k] = item
      end
      c.list, c.list_ver = list, w.pver
    end
    return c.list
  end

  return w
end


-- ===== the real game reads (the only code here that touches sdk) =====
-- Names come from the adapter, SPEC 17.2/17.6/17.10 or the SDK dump. A read
-- that finds nothing where something must exist raises, so the world round
-- treats it as a failed read (one-round keep, then "unknown").
function M.game_reads()
  local R = {}

  -- Guarded reads. The bodies are named functions handed to pcall with
  -- their arguments, so no read allocates a closure.
  local function get_field(o, name) return o:get_field(name) end
  local function call_method(o, name, ...) return o:call(name, ...) end

  local function G(o, name)
    if o == nil then return nil end
    local ok, v = pcall(get_field, o, name)
    if ok then return v end
    return nil
  end

  local function C(o, name, ...)
    if o == nil then return nil end
    local ok, v = pcall(call_method, o, name, ...)
    if ok then return v end
    return nil
  end

  local function single(name)
    local ok, v = pcall(sdk.get_managed_singleton, name)
    if ok then return v end
    return nil
  end

  -- Arrays only (adapter items.elements).
  local function copy_elements(arr)
    local v = arr:get_elements()
    if v == nil then return nil end
    local t = {}
    for i = 1, #v do t[i] = v[i] end
    return t
  end

  local function elems(arr)
    if arr == nil then return nil end
    local ok, t = pcall(copy_elements, arr)
    if ok then return t end
    return nil
  end

  -- fn(item, i, extra) for each element of a List (get_Count/get_Item) or
  -- array. Arrays have get_Count but no callable get_Item (in game), so a
  -- System.Array goes through get_elements first.
  local function each(c, fn, extra)
    if c == nil then return false end
    local t = elems(c)
    if t ~= nil then
      for i = 1, #t do fn(t[i], i, extra) end
      return true
    end
    local n = C(c, "get_Count")
    if type(n) == "number" then
      for i = 0, n - 1 do fn(C(c, "get_Item", i), i + 1, extra) end
      return true
    end
    return false
  end

  -- _entries of a Dictionary or HashSet, cut to `_count` slots.
  -- `_count` (the .NET field name): verified in game 2026-10-21 (1189 records).
  local function entries(d)
    local t = elems(G(d, "_entries"))
    if t == nil then return nil end
    local n = G(d, "_count")
    if type(n) == "number" and n < #t then
      local cut = {}
      for i = 1, n do cut[i] = t[i] end
      return cut
    end
    return t
  end

  -- HashSet entry value: `Value`, then `value` (adapter scan_placed).
  local function hs_value(e)
    local v = G(e, "Value")
    if v == nil then v = G(e, "value") end
    return v
  end

  local function int_value(v)
    if type(v) == "number" then return v end
    if v == nil then return nil end
    local inner = G(v, "value__")
    if type(inner) == "number" then return inner end
    return nil
  end

  local function u32(v)
    if type(v) ~= "number" then return nil end
    local n = math.tointeger(v)
    if n ~= nil and n < 0 then n = n & 0xFFFFFFFF end
    return n
  end

  local function read_xyz(v) return v.x, v.y, v.z end

  local function xyz(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(read_xyz, v)
    if not ok or not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
  end

  local function guid_text(g)
    local s = C(g, "ToString()")
    if type(s) == "string" then return s:lower() end
    return nil
  end

  local function enum_names(type_name)
    local out = {}
    pcall(function()
      local td = sdk.find_type_definition(type_name)
      for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
          local nm = f:get_name()
          if nm ~= "value__" then
            local n = u32(f:get_data(nil))
            if n ~= nil then out[n] = nm end
          end
        end
      end
    end)
    return out
  end

  local cid_names = nil
  local function cid_name(id)
    if id == nil then return nil end
    if cid_names == nil then cid_names = enum_names("app.CharacterID") end
    return cid_names[id]
  end

  local icon_guid = {}

  local function gm_position(g)
    local tr = C(C(g, "get_GameObject"), "get_Transform")
    return xyz(C(tr, "get_UniversalPosition"))
  end

  -- app.GenerateManager._ReserveManager._ReservedGenerateSelector is a
  -- List<GenerateSelector>; each selector's <Table>k__BackingField holds the
  -- _GimmickSetInfo and _EnemySetInfo (SPEC 17.2d).
  local RESERVED_SPECS = { { "_GimmickSetInfo", true }, { "_EnemySetInfo", false } }

  local function reserved_row(out, row, ix, is_gimmick)
    local uid = guid_text(G(row, "_ManualSetGuid"))
    local pos = xyz(G(row, "_ManualPos"))
    if uid == nil or pos == nil then return end
    if is_gimmick then
      out[#out + 1] = { uid = uid, pos = pos, table_ix = ix,
        gimmick = int_value(G(row, "_GimmickID")) }
    else
      local cid = u32(int_value(G(row, "_CharaID")))
      if cid ~= nil then
        out[#out + 1] = { uid = uid, pos = pos, table_ix = ix, cid = cid,
          cid_name = cid_name(cid) }
      end
    end
  end

  local function reserved_selector(sel, ix, out)
    local tbl = G(sel, "<Table>k__BackingField")
    for _, spec in ipairs(RESERVED_SPECS) do
      for _, row in ipairs(elems(G(G(tbl, spec[1]), "_BasicRowDatas")) or {}) do
        pcall(reserved_row, out, row, ix, spec[2])
      end
    end
  end

  function R.reserved_rows()
    local out = {}
    local gm = single("app.GenerateManager")
    local ok = each(G(G(gm, "_ReserveManager"), "_ReservedGenerateSelector"),
      reserved_selector, out)
    if not ok or #out == 0 then error("reserved rows unreadable") end
    return out
  end

  function R.loaded_gimmicks()
    local out = {}
    local gm = single("app.GimmickManager")
    local outer = entries(G(gm, "<ManagedGimmicksByIDs>k__BackingField"))
    if outer == nil then error("loaded gimmicks unreadable") end
    for _, ent in ipairs(outer) do
      local id = int_value(G(ent, "key"))
      if id ~= nil and M.kind_of_gimmick(id) ~= nil then
        for _, e in ipairs(entries(G(ent, "value")) or {}) do
          pcall(function()
            local g = hs_value(e)
            if g == nil then return end
            local uid = guid_of(C(C(g, "get_UniqId"), "ToString()"))
            local pos = gm_position(g)
            if uid ~= nil and pos ~= nil then
              out[#out + 1] = { uid = uid, gimmick = id, pos = pos }
            end
          end)
        end
      end
    end
    return out
  end

  -- The schedule dictionary object is held for one second, so a round's
  -- per-cid reads share one fetch.
  local sched = { dict = nil, at = -math.huge }
  local function sched_dict()
    local now = os.clock()
    if sched.dict == nil or now - sched.at > 1 then
      sched.dict = G(single("app.NPCManager"), "<NPCScheduleCurrentDict>k__BackingField")
      sched.at = now
    end
    return sched.dict
  end

  -- ContainsKey first: get_Item on a missing key throws in the game,
  -- which REFramework logs (21 log errors per round in game, 2026-10-21).
  function R.schedule_pos(cid)
    local d = sched_dict()
    if C(d, "ContainsKey", cid) ~= true then return nil end
    return xyz(G(C(d, "get_Item", cid), "Pos"))
  end

  -- ===== v14 reads (SPEC 22.4, 22.8, 22.9; Rulings 1, 3-5) =====
  local function npc_dict(field)
    return G(single("app.NPCManager"), field)
  end

  -- A key location id: > 0 kept, else -1 (0 is None).
  local function key_of(v)
    local k = u32(int_value(v))
    if k ~= nil and k > 0 then return k end
    return -1
  end

  local function sched_row(r)
    return { start_week = int_value(G(r, "StartWeek")),
      end_week = int_value(G(r, "EndWeek")),
      start_day = int_value(G(r, "StartDay")), end_day = int_value(G(r, "EndDay")),
      start_hour = int_value(G(r, "StartHour")), end_hour = int_value(G(r, "EndHour")),
      area = int_value(G(r, "LocalArea")), location = int_value(G(r, "Location")),
      priority = int_value(G(r, "Priority")), key = key_of(G(r, "TargetKeyLocation")) }
  end

  -- Rows of one cid's daily schedule (npcs.route_stops row shape).
  function R.schedule_rows(cid)
    local d = npc_dict("<NPCScheduleDict>k__BackingField")
    if C(d, "ContainsKey", cid) ~= true then error("no schedule rows") end
    local out = {}
    local ok = each(C(d, "get_Item", cid), function(r)
      if r == nil then return end
      out[#out + 1] = sched_row(r)
    end)
    if not ok then error("schedule rows unreadable") end
    return out
  end

  function R.schedule_now()
    local nm = single("app.NPCManager")
    local day, hour = C(nm, "get_CurrentScheduleDay"), C(nm, "get_CurrentScheduleHour")
    if type(day) ~= "number" or type(hour) ~= "number" then
      error("schedule time unreadable")
    end
    return day, hour
  end

  -- NPCScheduleCurrent of one cid: area, location, map-space position.
  function R.current_row(cid)
    local d = sched_dict()
    if C(d, "ContainsKey", cid) ~= true then return nil end
    local e = C(d, "get_Item", cid)
    if e == nil then return nil end
    local overwrite = {}
    each(G(e, "OverwriteSchedule"), function(r)
      if r ~= nil then overwrite[#overwrite + 1] = sched_row(r) end
    end)
    return { area = int_value(G(e, "LocalArea")), location = int_value(G(e, "Location")),
      key = key_of(G(e, "KeyLocation")), pos = xyz(G(e, "Pos")), overwrite = overwrite }
  end

  -- Map-space position of a key location; nil when absent. ContainsKey
  -- first: get_Item on a missing key throws in the game.
  function R.key_pos(key)
    local nodes = G(single("app.AIAreaManager"), "KeyLocationNodes")
    if C(nodes, "ContainsKey", key) ~= true then return nil end
    return xyz(G(C(nodes, "get_Item", key), "_Pos"))
  end

  -- Signature of one cid's current entry: area, location, key and the
  -- overwrite rows' keys joined by ","; nil for a cid with no entry.
  function R.current_sig(cid)
    local d = sched_dict()
    if C(d, "ContainsKey", cid) ~= true then return nil end
    local e = C(d, "get_Item", cid)
    if e == nil then return nil end
    local keys = {}
    each(G(e, "OverwriteSchedule"), function(r)
      if r ~= nil then keys[#keys + 1] = tostring(key_of(G(r, "TargetKeyLocation"))) end
    end)
    return int_value(G(e, "LocalArea")), int_value(G(e, "Location")),
      key_of(G(e, "KeyLocation")), table.concat(keys, ",")
  end

  -- ===== quest override stage rows (SPEC 26) =====
  local UNKNOWN = {}
  local MAX_DEPTH = 16

  local function full_name(x) return x:get_type_definition():get_full_name() end
  local function addr_of(x) return x:get_address() end

  local function node_kind(x)
    local ok, n = pcall(full_name, x)
    if not ok or type(n) ~= "string" then return nil end
    if n:find("CheckCondiiton", 1, true) then return "group" end
    if n:find("CheckVariable", 1, true) then return "variable" end
    return nil
  end

  local walk

  -- three-valued all / any over a Lua array of nodes
  local function combine(all, nodes, depth)
    local unknown = false
    for i = 1, #nodes do
      local v = walk(nodes[i], depth + 1)
      if all then
        if v == false then return false end
      elseif v == true then
        return true
      end
      if v == UNKNOWN then unknown = true end
    end
    if unknown then return UNKNOWN end
    return all
  end

  -- true, false or UNKNOWN. Only an integer variable takes the game's
  -- evaluate(); a flag, any other node or a failed read is unknown.
  walk = function(node, depth)
    if depth > MAX_DEPTH then return UNKNOWN end
    local kind = node_kind(node)
    if kind == "group" then
      local op = int_value(G(node, "_Operator"))
      local arr = elems(G(node, "_Entity"))
      if arr == nil or #arr == 0 or (op ~= 0 and op ~= 1) then return UNKNOWN end
      return combine(op == 0, arr, depth)
    elseif kind == "variable" then
      local ve = G(node, "_Entity")
      local vt = int_value(G(ve, "_ValueType"))
      if vt == nil or vt == 1 then return UNKNOWN end
      local v = C(ve, "evaluate")
      if type(v) == "boolean" then return v end
    end
    return UNKNOWN
  end

  -- stage state of an entry's ConditionEntity, and whether its own
  -- evaluate() is true (that wins over the walk)
  local function stage_state(cond)
    if cond == nil then return UNKNOWN, false end
    if C(cond, "evaluate") == true then return true, true end
    local arr = elems(G(cond, "_ConditionArray"))
    if arr == nil then return UNKNOWN, false end
    if #arr == 0 then return G(cond, "_IsNoConditonEnable") == true, false end
    local op = int_value(G(cond, "_Operator"))
    if op ~= 0 and op ~= 1 then return UNKNOWN, false end
    return combine(op == 0, arr, 1), false
  end

  local function entry_address(e)
    local ok, a = pcall(addr_of, e)
    if ok then return a end
    return nil
  end

  -- the kept entry's rows, its "now" flag and address; nil when dropped
  local function stage_entry(qm, e)
    local state, now = stage_state(G(e, "ConditionEntity"))
    if state == false then return nil end
    local od = G(e, "OverrideData")
    if C(od, "checkEnableScheduleData") == false then return nil end
    local qid = G(e, "QuestID")
    local q = int_value(qid)
    if q == nil then q = qid end
    if q ~= nil and C(qm, "checkActivated", q) == false then return nil end
    local rows = {}
    each(G(G(od, "_Schedule"), "_Schedule"), function(r)
      if r ~= nil then rows[#rows + 1] = sched_row(r) end
    end)
    return { rows = rows, now = now, addr = entry_address(e) }
  end

  -- Rows of the quest stage's entries for one cid (SPEC 26.4); nil when
  -- the quest tables are unreadable, {} when the quest is not steering
  -- this NPC now.
  function R.quest_overrides(cid)
    local qm = single("app.QuestManager")
    local all = G(qm, "NpcOverrideDict")
    if qm == nil or all == nil then return nil end
    local applied = G(qm, "CurrentNpcOverrideDict")
    if C(applied, "ContainsKey", cid) ~= true then return {} end
    if C(all, "ContainsKey", cid) ~= true then return {} end
    local applied_addr = entry_address(C(applied, "get_Item", cid))
    local first, now, rest = {}, {}, {}
    local ok = each(C(all, "get_Item", cid), function(e)
      if e == nil then return end
      local okk, k = pcall(stage_entry, qm, e)
      if not okk or k == nil then return end
      if applied_addr ~= nil and k.addr == applied_addr then
        first[#first + 1] = k
      elseif k.now then
        now[#now + 1] = k
      else
        rest[#rest + 1] = k
      end
    end)
    if not ok then return {} end
    local out = {}
    for _, bucket in ipairs({ first, now, rest }) do
      for _, k in ipairs(bucket) do
        for _, r in ipairs(k.rows) do out[#out + 1] = r end
      end
    end
    return out
  end

  -- Node positions of a row's area (Ruling 4); nil when it has none.
  function R.area_nodes(row)
    local am = single("app.AIAreaManager")
    local list
    if row.area ~= nil and row.area >= 0 then
      list = C(am, "getKeyNodesInLocalArea", row.area)
    else
      list = C(am, "getNodeListInArea", row.location, -1, true)
    end
    if list == nil then return nil end
    local out = {}
    each(list, function(n)
      local p = xyz(C(n, "get_Pos"))
      if p ~= nil then out[#out + 1] = p end
    end)
    if #out == 0 then return nil end
    return out
  end

  -- ===== spawned holders (SPEC 22.9.3, Ruling 5) =====
  local function holder_dic() return npc_dict("NPCHolderDic") end

  function R.holder_count()
    local dic = holder_dic()
    local n = C(dic, "get_Length")
    if type(n) ~= "number" then n = C(dic, "get_Count") end
    if type(n) ~= "number" then error("holder count unreadable") end
    return n
  end

  -- Spawned holders only (a non-nil _chara); get_element, since
  -- get_elements stops at the first nil slot.
  function R.holder_at(i)
    -- get_element is the array wrapper's own method (dic:get_element(i));
    -- call("get_element") does not reach it in game. C is the fallback.
    local dic = holder_dic()
    local okd, h = pcall(function() return dic:get_element(i) end)
    if not okd then h = C(dic, "get_element", i) end
    if h == nil then return nil end
    local chara = G(h, "_chara")
    if chara == nil then return nil end
    local cid = u32(int_value(G(h, "CharaID")))
    if cid == nil then return nil end
    return { cid = cid, transform = C(chara, "get_Transform"), holder = h }
  end

  function R.sentiment(holder)
    local s = G(holder, "SentimentToPlayer")
    if s == nil then error("sentiment unreadable") end
    return int_value(G(s, "Rank")), int_value(G(s, "Value"))
  end

  function R.schedule_ids()
    local nm = single("app.NPCManager")
    local t = entries(G(nm, "<NPCScheduleCurrentDict>k__BackingField"))
    if t == nil then error("schedule ids unreadable") end
    local out = {}
    for _, e in ipairs(t) do
      local id = u32(int_value(G(e, "key")))
      if id ~= nil then out[#out + 1] = id end
    end
    return out
  end

  -- Icons carry icon_id (UInt32): GuiManager.MapIconDispIdList holds ids.
  function R.map_icons()
    local gui = single("app.GuiManager")
    local out = {}
    icon_guid = {}
    local ok = each(G(gui, "MapIconList"), function(ic)
      pcall(function()
        local g = G(ic, "_DispNameId")
        local text = guid_text(g)
        local pos = xyz(G(ic, "_Pos"))
        if text == nil or pos == nil then return end
        pcall(function() g = g:add_ref() end)
        icon_guid[text] = g
        out[#out + 1] = { type = int_value(G(ic, "_IconType")), pos = pos,
          disp_id = text, icon_id = u32(int_value(G(ic, "_IconId"))) }
      end)
    end)
    if not ok or #out == 0 then error("map icons unreadable") end
    return out
  end

  local msg_get = nil
  function R.msg(disp_id)
    local g = icon_guid[disp_id]
    if g == nil then return nil end
    if msg_get == nil then
      local t = sdk.find_type_definition("via.gui.message")
      msg_get = t ~= nil and t:get_method("get(System.Guid)") or nil
      if msg_get == nil then return nil end
    end
    local s = msg_get:call(nil, g)
    if type(s) == "string" and s ~= "" then return s end
    return nil
  end

  -- ===== save records (SPEC 17.2c) =====
  -- RecordInfo.<Record>.Contexts (and SaveData.Contexts) are List<app.Context>.
  -- One walk keeps refs to the relevant records, keyed by the text of
  -- UniqueIDContext.UniqueID; it repeats only when Records:get_Count changes.
  local rec_cache = nil

  local function type_name(x) return x:get_type_definition():get_name() end

  local function add_context(x, _, map)
    if x ~= nil then
      local ok, n = pcall(type_name, x)
      if ok and type(n) == "string" and map[n] == nil then map[n] = x end
    end
  end

  local function ctx_map(rec)
    local map = {}
    local lists = { G(C(rec, "get_Record"), "Contexts"), G(G(rec, "SaveData"), "Contexts") }
    for i = 1, 2 do each(lists[i], add_context, map) end
    return map
  end

  -- keeps a record that holds an item, a character or a token / beetle gimmick
  local function keep_record(items, rec)
    if rec == nil then return end
    local m = ctx_map(rec)
    -- verified in game 2026-10-21 (index 12 hits / 0 misses): UniqueIDContext is in the filled list
    local key = C(G(m.UniqueIDContext, "UniqueID"), "ToString()")
    if type(key) ~= "string" then return end
    local keep = m.GmItemContext ~= nil or m.CharacterIDContext ~= nil
    if not keep and m.GimmickContext ~= nil then
      local gid = int_value(G(m.GimmickContext, "_GimmickId"))
      local k = M.kind_of_gimmick(gid)
      keep = k == "token" or k == "beetle"
    end
    if keep then
      key = key:lower()
      items[#items + 1] = { key = key, guid = guid_of(key), ctx = m }
    end
  end

  local function relevant_records()
    local db = G(single("app.ContextDBMS"), "OfflineDB")
    local list = G(db, "Records")
    local count = C(list, "get_Count")
    if type(count) ~= "number" then error("save records unreadable") end
    -- the list's address (adapter qm_owner_key) tells a reloaded save apart
    local addr = nil
    pcall(function() addr = list:get_address() end)
    if rec_cache ~= nil and rec_cache.count == count and rec_cache.addr == addr then
      return rec_cache.items
    end
    local items = {}
    each(list, function(rec) pcall(keep_record, items, rec) end)
    if count > 0 and #items == 0 then error("no save record matched") end
    rec_cache = { count = count, addr = addr, items = items }
    return items
  end

  function R.save_records()
    local out = {}
    for _, it in ipairs(relevant_records()) do
      local m = it.ctx
      local r = { key = it.key, guid = it.guid }
      if m.GmItemContext ~= nil then
        r.picked = G(m.GmItemContext, "_IsPick") == true
        r.keep = G(m.GmItemContext, "_IsKeep") == true
      end
      if m.TreasureBoxGimmickContext ~= nil then
        r.item = int_value(G(m.TreasureBoxGimmickContext, "_ItemId"))
      end
      if m.GimmickContext ~= nil then
        r.free_bit = int_value(G(m.GimmickContext, "_FreeBit"))
      end
      if m.GatherContext ~= nil then r.gather_num = int_value(G(m.GatherContext, "_Num")) end
      if r.picked ~= nil or r.free_bit ~= nil or r.gather_num ~= nil then
        out[#out + 1] = r
      end
    end
    return out
  end

  local node_names = nil
  local function key_names()
    if node_names == nil then node_names = enum_names("app.AIKeyLocation") end
    return node_names
  end

  function R.treasure_nodes()
    local out = {}
    local t = entries(G(single("app.AIAreaManager"), "KeyLocationNodes"))
    if t == nil then error("treasure nodes unreadable") end
    local names = key_names()
    for _, e in ipairs(t) do
      local nm = names[u32(int_value(G(e, "key")))]
      if nm ~= nil and nm:match("^Gimmick_Treasure_%d+$") then
        local pos = xyz(G(G(e, "value"), "_Pos"))
        if pos ~= nil then out[#out + 1] = { name = nm, pos = pos } end
      end
    end
    if #out == 0 then error("no treasure nodes") end
    return out
  end

  function R.checked_nodes()
    local t = entries(G(single("app.GimmickManager"), "<KeyLocationCheckedList>k__BackingField"))
    if t == nil then error("checked nodes unreadable") end
    local names = key_names()
    local out = {}
    for _, e in ipairs(t) do
      local nm = names[u32(int_value(hs_value(e)))]
      if nm ~= nil then out[nm] = true end
    end
    return out
  end

  -- MapIconDispIdList is a HashSet<UInt32> of icon ids.
  function R.discovered_icons()
    local t = entries(G(single("app.GuiManager"), "MapIconDispIdList"))
    if t == nil then error("discovered icons unreadable") end
    local out = {}
    for _, e in ipairs(t) do
      -- unverified: Task 7 checks that the set holds _IconId values
      local v = u32(int_value(hs_value(e)))
      if v ~= nil then out[v] = true end
    end
    return out
  end

  function R.discovered_count()
    local n = C(G(single("app.GuiManager"), "MapIconDispIdList"), "get_Count")
    if type(n) ~= "number" then error("discovered count unreadable") end
    return n
  end

  function R.shop_of(cid)
    return int_value(C(single("app.TalkEventManager"), "getShopId", cid))
  end

  function R.shops()
    local tbl = G(single("app.ItemManager"), "ShopParamTable")
    local t = entries(tbl)
    if t == nil then error("shop table unreadable") end
    local out = {}
    for _, e in ipairs(t) do
      local id = int_value(G(e, "key"))
      if id ~= nil then
        local buy = {}
        each(G(G(e, "value"), "_BuyParams"), function(b)
          if b ~= nil then
            local vc = G(b, "_QuestVariableCondition")
            local q = int_value(G(vc, "_QuestID"))
            local h = int_value(G(vc, "_NameHash"))
            buy[#buy + 1] = { item = int_value(G(b, "_ItemId")),
              release_qid = int_value(G(b, "_ReleaseQuestId")),
              sentiment_bit = int_value(G(b, "_ReleaseSentimentRankBit")),
              total_pay = int_value(G(b, "_ReleaseTotalPay")),
              flag = int_value(G(b, "_ReleaseFlag")),
              -- the game writes quest -1, hash 0 for "no condition"
              var_cond = ((type(q) == "number" and q > 0) or nz(h)) and 1 or 0 }
          end
        end)
        if #buy > 0 then out[id] = buy end
      end
    end
    if next(out) == nil then error("no shop buy lists") end
    return out
  end

  -- Enemy drop tables (SPEC 19.12.2): { [cid] = { item_id, ... } }. A cid with
  -- a default entry takes its ids from the default dict only; param entries
  -- count only for a cid with no default entry (the default dict is walked
  -- first, so has_default is complete before the param dict is read).
  function R.monster_drops()
    local im = single("app.ItemManager")
    local out, has_default = {}, {}
    local function walk(dict_name, is_default)
      local t = entries(G(im, dict_name))
      if t == nil then return end
      for _, e in ipairs(t) do
        local v = G(e, "value")
        local cid = u32(int_value(G(v, "_CharaId")))
        if (cid == nil or cid == 0) and is_default then
          cid = u32(int_value(G(e, "key")))
        end
        if cid ~= nil and cid ~= 0 and (is_default or not has_default[cid]) then
          if is_default then has_default[cid] = true end
          local ids = out[cid]
          each(G(v, "_TableList"), function(tbl)
            each(G(tbl, "_ItemList"), function(row)
              local id = int_value(G(row, "_Id"))
              local rate = int_value(G(row, "_Rate"))
              if id ~= nil and id > 0 and rate ~= nil and rate > 0 then
                if ids == nil then ids = {}; out[cid] = ids end
                local dup = false
                for _, x in ipairs(ids) do
                  if x == id then dup = true; break end
                end
                if not dup then ids[#ids + 1] = id end
              end
            end)
          end)
        end
      end
    end
    walk("EnemyDefaultItemDropDataDict", true)
    walk("EnemyItemDropDataDict", false)
    if next(out) == nil then error("no enemy drop tables") end
    return out
  end

  -- _RegisteredTimeInfos is a List<RegisterInfo> with _UniqID (UniqueID) and
  -- _Key (String); each key joins a save record's CharacterIDContext.CharacterID
  -- and CharacterPosRotContext.Position.
  function R.respawn_units()
    local want = {}
    local gm = single("app.GenerateManager")
    local ok = each(G(G(gm, "_RepopManager"), "_Units"), function(u)
      each(G(u, "_RegisteredTimeInfos"), function(info)
        local s = C(G(info, "_UniqID"), "ToString()")
        if type(s) ~= "string" then s = G(info, "_Key") end  -- unverified: Task 7 checks _Key text
        if type(s) == "string" then want[s:lower()] = true end
      end)
    end)
    if not ok then error("respawn units unreadable") end
    local out = {}
    if next(want) == nil then return out end
    for _, it in ipairs(relevant_records()) do
      local m = it.ctx
      if want[it.key] and m.CharacterIDContext ~= nil and m.CharacterPosRotContext ~= nil then
        local cid = u32(int_value(G(m.CharacterIDContext, "CharacterID")))
        local pos = xyz(G(m.CharacterPosRotContext, "Position"))
        if cid ~= nil and pos ~= nil then
          out[#out + 1] = { key = it.key, cid = cid, cid_name = cid_name(cid), pos = pos }
        end
      end
    end
    return out
  end

  -- ===== the AI walking graph (SPEC 23.6) =====
  -- Each call re-acquires the chain (no object is held between frames) and
  -- raises on any failed check. Field names measured in game 2026-10-23:
  -- NodeID.blockId / indexId are 0-based list positions.
  local function managed(o, what)
    if o == nil or not sdk.is_managed_object(o) then error("graph: " .. what) end
    return o
  end

  local function graph_blocks()
    local mgr = managed(single("app.AIWorldGraphManager"), "no manager")
    local datas = managed(G(mgr, "AIWorldGraphDatas"), "no graph datas")
    local data = managed(C(datas, "get_Item", 0), "no graph data")
    local gd = managed(G(data, "<GraphData>k__BackingField"), "no graph data body")
    local graph = managed(G(gd, "AIWorldGraph"), "no graph")
    return managed(G(graph, "Nodes"), "no blocks")
  end

  function R.graph_block_count()
    local n = C(graph_blocks(), "get_Count")
    if type(n) ~= "number" then error("graph: block count") end
    return n
  end

  -- Fills out.x, out.y, out.z, out.lc from index 1 for nodes first ..
  -- first + count - 1 of block i (1-based, clamped to the block) and
  -- out.lb, out.ln for those nodes' links in node order; returns the
  -- block's node count and the number of nodes filled.
  function R.graph_block(i, out, first, count)
    local block = managed(C(graph_blocks(), "get_Item", i), "no block")
    local list = managed(G(block, "Nodes"), "no node list")
    local n = C(list, "get_Count")
    if type(n) ~= "number" then error("graph: node count") end
    local lo = first or 1
    if lo < 1 then lo = 1 end
    local hi = count ~= nil and lo + count - 1 or n
    if hi > n then hi = n end
    local x, y, z, lc, lb, ln = out.x, out.y, out.z, out.lc, out.lb, out.ln
    local nl, f = 0, 0
    for k = lo, hi do
      f = f + 1
      local node = managed(C(list, "get_Item", k - 1), "no node")
      local p = xyz(G(node, "_Pos"))
      if p == nil then error("graph: node position") end
      x[f], y[f], z[f] = p.x, p.y, p.z
      local links = managed(G(node, "Links"), "no links")
      local m = C(links, "get_Count")
      if type(m) ~= "number" then error("graph: link count") end
      for j = 0, m - 1 do
        local id = C(links, "get_Item", j)
        local b, ix = G(id, "blockId"), G(id, "indexId")
        if type(b) ~= "number" or type(ix) ~= "number" then error("graph: link id") end
        nl = nl + 1
        lb[nl], ln[nl] = b, ix
      end
      lc[f] = m
    end
    return n, f
  end

  -- Drops every held game object (new save session).
  function R.reset()
    rec_cache = nil
    sched.dict, sched.at = nil, -math.huge
    icon_guid = {}
  end

  local function family_set(ids)
    local out = {}
    for _, id in ipairs(ids) do
      local nm = cid_name(id)
      if nm ~= nil then out[nm:sub(1, 5)] = true end
    end
    return out
  end

  function R.boss_families()
    local td = sdk.find_type_definition("app.PawnPartyCombatInfo")
    local list = td ~= nil and td:get_field("BOSS_CHARACTER_ID_LIST"):get_data(nil) or nil
    local ids = {}
    local ok = each(list, function(v)
      local id = u32(int_value(v))
      if id ~= nil then ids[#ids + 1] = id end
    end)
    if not ok or #ids == 0 then error("boss list unreadable") end
    return family_set(ids)
  end

  function R.loaded_boss_families()
    local ids = {}
    local ok = each(G(single("app.EnemyManager"), "_EnemyList"), function(e)
      local ch = C(e, "get_Chara")
      if ch ~= nil and C(ch, "get_IsBoss") == true then
        local id = u32(int_value(C(ch, "get_CharaID")))
        if id ~= nil then ids[#ids + 1] = id end
      end
    end)
    if not ok then error("enemy list unreadable") end
    return family_set(ids)
  end

  function R.badge_name(id)
    local td = sdk.find_type_definition("app.GUIBase")
    local m = td ~= nil and td:get_method("getBadgeEnemyName") or nil
    if m == nil then return nil end
    local s = m:call(nil, id)
    if type(s) == "string" then return s end
    return nil
  end

  return R
end

return M
