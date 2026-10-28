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
  RESERVED_MAX_AGE = 60.0,
  REMOVE_RADIUS = 50,
  REMOVE_NEIGHBOURS = 3,
  ROUND_TO = 0.1,
  FILE_VERSION = 1,
  ATLAS = "Clairvoyance_world.json",
  OLD_ATLAS = "Clairvoyance_world.old.json",
  PLACES = "Clairvoyance_places.json",
  PLACES_VERSION = 2,
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
local PLACES_KINDS = { chest = true, token = true, beetle = true, chara = true, item = true }
local PLACE_SOURCES = { normal = true, random = true, subquest = true, mainquest = true }
local PLACE_PHASES = { beforeseason4 = true, season4 = true }

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

-- Live rows may omit src; validated format-2 file rows may not. Missing live
-- src and explicit "normal" are both normal placements.
local function normal_src(s) return s == nil or s == "normal" end

-- The 5-character family prefix of a character name, or nil.
local function fam_of(nm)
  return type(nm) == "string" and #nm >= 5 and nm:sub(1, 5) or nil
end

local function to_int(v)
  if type(v) ~= "number" then return nil end
  return math.tointeger(v)
end

-- Public objective catalog values are recursively detached read-only proxies.
-- The backing tables stay closure-private even when a caller keeps a snapshot.
local function readonly(value, cache)
  if type(value) ~= "table" then return value end
  cache = cache or {}
  if cache[value] ~= nil then return cache[value] end
  local proxy = {}
  cache[value] = proxy
  local mt = {
    __index = function(_, key) return readonly(value[key], cache) end,
    __newindex = function() error("immutable objective catalog", 2) end,
    __len = function() return #value end,
    __pairs = function()
      local function iter(_, key)
        local next_key, next_value = next(value, key)
        if next_key ~= nil then return next_key, readonly(next_value, cache) end
      end
      return iter, proxy, nil
    end,
    __metatable = false,
  }
  return setmetatable(proxy, mt)
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

-- What the save records say about one collectable: "unknown" without a
-- records index, else "collected" if any record of the uid is done, else "not".
local function collect_state(def, rec_idx, uid)
  if rec_idx == nil then return "unknown" end
  local state = "not"
  for _, r in ipairs(rec_idx[uid] or {}) do
    if def.done(r) then state = "collected" end
  end
  return state
end

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

-- Whether any toggle needs a world round (SPEC 28.7.1).
function M.wants_round(tg, members)
  return (tg.chests or tg.treasure or tg.tokens or tg.beetles or tg.monsters
    or tg.small_monsters or tg.sellers or tg.search or tg.shops
    or tg.first_token or type(tg.focus) == "table" or (members or 0) > 0) and true or false
end

-- An item list kept per key in `cache` (SPEC 28.5.3.3): { { name, n }, ... }
-- for `items` ({ { id, n }, ... }) with names from name_of(id). Returns the
-- list and whether it was built this call. It is rebuilt when the id list
-- differs (length, any id or count) or when a name last time was the
-- "Item <id>" fallback, so a name the adapter could not read yet is retried.
function M.item_list(cache, key, items, name_of)
  local c = cache[key]
  if c ~= nil and not c.retry and #c.ids == #items then
    local same = true
    for i, it in ipairs(items) do
      if c.ids[i] ~= it.id or c.ns[i] ~= it.n then same = false; break end
    end
    if same then return c.list, false end
  end
  local ids, ns, list, retry = {}, {}, {}, false
  for i, it in ipairs(items) do
    local nm = name_of(it.id)
    ids[i], ns[i] = it.id, it.n
    list[i] = { name = nm, n = it.n }
    if nm == nil or nm == "Item " .. tostring(it.id) then retry = true end
  end
  cache[key] = { ids = ids, ns = ns, list = list, retry = retry }
  return list, true
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
  local objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "unknown",
    complete = false, generation = 1, reason = "places_unavailable",
    placements = {}, chests = {} })
  local chara_rows = {}    -- raw places chara rows
  local places_uids = {}   -- every valid places row uid
  local conditional_uids = {} -- conditional file chara UIDs, including givers
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
  local input_tbl = nil
  local unlisted = 0
  local stats = { ms = {}, known = {}, monster_ids = {}, rounds = 0, saves = 0,
    save_ms = 0, last_save_reason = nil, hits = 0, misses = 0,
    eff_builds = 0, item_list_builds = 0, held_rounds = 0,
    shop_index_runs = 0, chest_kinds_calls = 0,
    reserved_reused = 0, reserved_reads = 0, route_builds = 0 }
  local res_reused = false
  local S
  local EMPTY = {} -- shared read-only empty list for the per-row loops

  local function new_session()
    return { cast = nil, boss = nil, union = {}, badge = {},
      nodes = nil, node_chest = nil, shops = nil, sched_ids = nil, shop_of = {}, shop_cids = nil,
      settle = nil, msgs = {}, disc_set = nil, disc_count = nil,
      disc_cache = {}, need_sort = true, file_monsters = {}, held = {}, live = {},
      drop_ids = nil, eligible_file_monsters = {}, file_giver_rows = {}, file_givers = {},
      live_givers = {},
      -- SPEC 28.5.3.3: item lists kept per chest uid / treasure name
      chest_lists = {}, treasure_lists = {},
      -- v14 (SPEC 22.7-22.9): NPC name list, route, spawned-holder walk
      npc_list = {}, npc_ms = 0, npc_next = 1, npc_done = false, npc_sig = "",
      target_member = nil, members = {}, member_of = {}, objective_generation = nil,
      objective_publication = nil, objective_place_observation = nil,
      objective_source_observations = {}, objective_live_source_cache = {}, route_cache = {},
      route_fail = {}, fail_seq = 0,
      -- SPEC 32.14: sticky route colour slots; slot_of (cid -> slot) and
      -- slot_cid (slot -> cid) together are the spec's S.slots
      slot_of = {}, slot_cid = {},
      -- SPEC 32.14.5.4: place cid -> the stop key of its last player stop
      place_from = {},
      -- SPEC 32.7.5: focused quests' key locations found so far
      key_pos = {},
      sent = {}, walk_i = 0, walk_n = 0, walk_acc = {},
      -- SPEC 31: the reserved rows kept while the selector signature holds
      res = nil }
  end
  S = new_session()
  w.spawned = {}

  -- ----- places file -----
  local function parse_places(v)
    local rows, dropped = 0, 0
    local new_static, new_chara, new_uids, new_names, new_conditional = {}, {}, {}, {}, {}
    local new_placements, new_chests, source_uids = {}, {}, { item = {}, chest = {} }
    local source_catalog_bad = nil
    local function dense_array(t)
      local n, max = 0, 0
      for k in pairs(t) do
        if type(k) ~= "number" or math.tointeger(k) ~= k or k < 1 then return false end
        n = n + 1
        if k > max then max = k end
      end
      return n == max and #t == max
    end
    local function exact_fields(t, allowed)
      for k in pairs(t) do if not allowed[k] then return false end end
      return true
    end
    local function valid_gate(g)
      if type(g) ~= "table" or not exact_fields(g, { check = true, conditions = true })
        or (g.check ~= 0 and g.check ~= 1) or math.tointeger(g.check) == nil
        or type(g.conditions) ~= "table" or #g.conditions == 0
        or not dense_array(g.conditions) then return false end
      for _, c in ipairs(g.conditions) do
        if type(c) ~= "table" then return false end
        if c.kind == "quest" then
          if not exact_fields(c, { kind = true, qid = true, finish = true })
            or type(c.qid) ~= "number" or math.tointeger(c.qid) == nil or c.qid <= 0
            or type(c.finish) ~= "boolean" then return false end
        elseif c.kind == "variable" then
          if not exact_fields(c, { kind = true, qid = true, name_hash = true,
            value_type = true, compare_type = true, bool_value = true, int_value = true })
            or type(c.qid) ~= "number" or math.tointeger(c.qid) == nil or c.qid <= 0
            or type(c.name_hash) ~= "number" or math.tointeger(c.name_hash) == nil
            or type(c.value_type) ~= "number" or math.tointeger(c.value_type) == nil
            or type(c.compare_type) ~= "number" or math.tointeger(c.compare_type) == nil
            or type(c.bool_value) ~= "boolean"
            or type(c.int_value) ~= "number" or math.tointeger(c.int_value) == nil then
            return false
          end
        else
          return false
        end
      end
      return true
    end
    local function chest_quest(g)
      if g == nil then return nil end
      local q, var = {}, false
      for _, c in ipairs(g.conditions) do
        if c.kind == "quest" then q[#q + 1] = { c.qid, c.finish }
        else var = true end
      end
      return { any = g.check == 1, q = q, var = var or nil }
    end
    if not dense_array(v.rows) then error("invalid places rows") end
    for _, r in ipairs(v.rows) do
      if type(r) ~= "table" or not PLACE_SOURCES[r.src]
        or (r.phase ~= nil and (r.k ~= "chara" or not PLACE_PHASES[r.phase])) then
        error("invalid places metadata")
      end
      if r.k == "chara" then
        if (r.src == "subquest" or r.src == "mainquest") then
          if type(r.table_qid) ~= "number" or math.tointeger(r.table_qid) == nil
            or r.table_qid < 0 then error("invalid quest table owner") end
        elseif r.table_qid ~= nil then error("stray quest table owner") end
      elseif r.table_qid ~= nil then error("quest table owner on non-monster row") end
      if r.gate ~= nil and (r.k ~= "chara" and r.k ~= "chest" and r.k ~= "item"
          or not valid_gate(r.gate)) then
        error("invalid places gate")
      end
      local ok = type(r) == "table" and PLACES_KINDS[r.k] == true
        and type(r.uid) == "string" and r.uid ~= ""
        and to_int(r.id) ~= nil and finite(r.x) and finite(r.y) and finite(r.z)
      if not ok then
        if type(r) == "table" and (r.k == "item" or r.k == "chest") then
          source_catalog_bad = source_catalog_bad or "malformed_source_identity_or_position"
        end
        dropped = dropped + 1
      else
        rows = rows + 1
        local uid = r.uid:lower()
        if r.k == "item" or r.k == "chest" then
          if source_uids[r.k][uid] then source_catalog_bad = "duplicate_source_identity" end
          source_uids[r.k][uid] = true
        end
        new_uids[uid] = true
        local x, y, z = round1(r.x), round1(r.y), round1(r.z)
        local id = to_int(r.id)
        if r.k == "item" then
          local item_id, count = to_int(r.item or r.id), to_int(r.n or r.count)
          if item_id == nil or item_id <= 0 or count == nil or count <= 0
            or type(r.src) ~= "string" or not normal_src(r.src) then
            source_catalog_bad = source_catalog_bad or "malformed_placement"
          else
            new_placements[#new_placements + 1] = { uid = uid,
              source_id = { "source", "placed", uid },
              capacity_pool_id = { "capacity", "placed", uid },
              outputs = { { item_id = item_id, count = count } },
              pos = { x = x, y = y, z = z }, gate = r.gate }
          end
        elseif r.k == "chara" then
          if type(r.name) == "string" and r.name ~= "" then new_names[id] = r.name end
          new_chara[#new_chara + 1] = { uid = uid, id = id, name = r.name,
            x = x, y = y, z = z, src = r.src, phase = r.phase,
            table_qid = r.table_qid, gate = r.gate }
          if r.src == "subquest" or r.src == "mainquest" or r.phase ~= nil or r.gate ~= nil then
            new_conditional[uid] = true
          end
        elseif r.k == "chest" or normal_src(r.src) then
          local legacy_visible = normal_src(r.src)
          local e = { k = r.k, id = id, x = x, y = y, z = z, src = "file" }
          if r.k == "chest" and type(r.items) == "table" then
            if not dense_array(r.items) or #r.items == 0 then
              source_catalog_bad = source_catalog_bad or "malformed_chest_contents"
            end
            local items = {}
            for _, it in ipairs(r.items) do
              local item_id = type(it) == "table" and to_int(it.id) or nil
              local count = type(it) == "table" and to_int(it.n) or nil
              if item_id ~= nil and item_id > 0 and count ~= nil and count > 0 then
                items[#items + 1] = { id = item_id, n = count }
              else
                source_catalog_bad = source_catalog_bad or "malformed_chest_output"
              end
            end
            if #items > 0 then e.items = items end
          elseif r.k == "chest" then
            source_catalog_bad = source_catalog_bad or "chest_contents_missing"
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
          if r.k == "chest" then
            e.quest = chest_quest(r.gate) or e.quest
            if e.items ~= nil then
              local outputs = {}
              for _, item in ipairs(e.items) do
                outputs[#outputs + 1] = { item_id = item.id, count = item.n }
              end
              new_chests[#new_chests + 1] = { uid = uid,
                source_id = { "source", "chest", uid },
                capacity_pool_id = { "capacity", "chest", uid }, outputs = outputs,
                pos = { x = x, y = y, z = z }, gate = r.gate }
            end
          end
          if legacy_visible and r.k ~= "item" then new_static[uid] = e end
        end
      end
    end
    for id, name in pairs(new_names) do names[id] = name end
    static, chara_rows, places_uids, conditional_uids = new_static, new_chara, new_uids,
      new_conditional
    if source_catalog_bad == nil then
      objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "ok",
        complete = true, generation = 1, placements = new_placements, chests = new_chests })
    else
      objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "unknown",
        complete = false, generation = 1, reason = source_catalog_bad,
        placements = {}, chests = {} })
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
      objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "unknown",
        complete = false, generation = 1, reason = "places_invalid", placements = {}, chests = {} })
    elseif v == nil then
      places.state = "missing"
    elseif type(v) ~= "table" or v.version ~= M.K.PLACES_VERSION
      or type(v.rows) ~= "table" then
      places.state = "bad"
      objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "unknown",
        complete = false, generation = 1, reason = "places_invalid", placements = {}, chests = {} })
    else
      local okp = pcall(parse_places, v)
      if okp then
        places.state = "ok"
        if type(v.pak) == "string" then places.pak = v.pak end
      else
        places.state = "bad"
        objective_catalog = readonly({ version = M.K.PLACES_VERSION, status = "unknown",
          complete = false, generation = 1, reason = "places_invalid",
          placements = {}, chests = {} })
        static, chara_rows, places_uids, conditional_uids = {}, {}, {}, {}
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
    -- SPEC 17.10.9.2: unconditional chara rows (no quest source, phase or gate)
    local kept_chara = {}
    for _, r in ipairs(chara_rows) do
      if not conditional_uids[r.uid] then
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
          if conditional_uids[uidl] then
            pruned = true
          elseif e.k == "monster" then
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
    if conditional_uids[uid] then return end
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

  local function classify(id, name)
    if S.cast ~= nil and S.cast[id] then return "giver" end
    return family_class(fam_of(name or names[id]))
  end

  local function sort_places()
    S.need_sort = false
    S.file_monsters = {}
    S.file_giver_rows = {}
    S.file_givers = {}
    givers_cache, givers_rev = nil, -1
    for _, r in ipairs(chara_rows) do
      local c = classify(r.id, r.name)
      if c == "giver" then
        if conditional_uids[r.uid] then
          S.file_giver_rows[r.uid] = { uid = r.uid, id = r.id, x = r.x, y = r.y, z = r.z }
        else
          learn(r.uid, "giver", r.id, r.x, r.y, r.z, nil, r.name)
        end
      elseif c == "large" or c == "small" then
        S.file_monsters[r.uid] = { k = "monster", id = r.id, x = r.x, y = r.y,
          z = r.z, src = "file", name = r.name }
      end
    end
  end

  -- ----- guarded sources -----
  -- Per-round timings, one mechanism (SPEC 28.5.2): lap(name, t0) stores a
  -- section's time under stats.ms["step_" .. name] and notes the key so the
  -- next round clears it; call() adds up the ACCUM names over the round
  -- instead of keeping the last call's time.
  local ACCUM = { schedule_pos = true, route_sig = true, key_pos = true }
  -- reads that run only on some rounds: their timing is cleared each round
  local CONDITIONAL_READS = { "reserved_rows", "reserved_sig" }
  local STEP_KEY = setmetatable({}, { __index = function(t, n)
    local k = "step_" .. n
    t[n] = k
    return k
  end })
  local lapped = {}
  local function lap(name, t0)
    local k = STEP_KEY[name]
    stats.ms[k] = (clock() - t0) * 1000
    lapped[#lapped + 1] = k
  end

  -- Calls reads[name]; returns ok, value. Times the call.
  local function call(name, ...)
    local f = reads[name]
    if type(f) ~= "function" then return false, nil end
    local t0 = clock()
    local ok, v = pcall(f, ...)
    local dt = (clock() - t0) * 1000
    if ACCUM[name] then dt = (stats.ms[name] or 0) + dt end
    stats.ms[name] = dt
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
    return h.value, ok and v ~= nil
  end

  local gate_round = { quests = {}, variables = {}, season_read = false, season = nil }
  local gate_stats = { season4 = nil, normal = { eligible = 0, total = 0 },
    quest = { eligible = 0, total = 0 }, read_failures = { season4 = 0, quest = 0, variable = 0 } }

  local function gate_quest(qid)
    local cached = gate_round.quests[qid]
    if cached ~= nil then return cached end
    local ok, value = call("quest_state", qid)
    if not ok or type(value) ~= "table" or type(value.active) ~= "boolean"
      or type(value.ended) ~= "boolean" then
      gate_stats.read_failures.quest = gate_stats.read_failures.quest + 1
      value = false
    end
    gate_round.quests[qid] = value
    return value
  end

  local function gate_season()
    if gate_round.season_read then return gate_round.season end
    gate_round.season_read = true
    local ok, value = call("game_season4")
    if ok and type(value) == "boolean" then gate_round.season = value
    else gate_stats.read_failures.season4 = gate_stats.read_failures.season4 + 1 end
    gate_stats.season4 = gate_round.season
    return gate_round.season
  end

  local function gate_variable(c)
    local key = table.concat({ c.qid, c.name_hash, c.value_type, c.compare_type,
      c.bool_value and 1 or 0, c.int_value }, ":")
    local cached = gate_round.variables[key]
    if cached ~= nil then return cached end
    local ok, value = call("quest_variable", c)
    if not ok or type(value) ~= "boolean" then
      gate_stats.read_failures.variable = gate_stats.read_failures.variable + 1
      value = false
    end
    gate_round.variables[key] = value
    return value
  end

  local function row_eligible(r)
    if r.table_qid ~= nil then
      local state = gate_quest(r.table_qid)
      if state == false or state.active ~= true or state.ended ~= false then return false end
    end
    if r.phase ~= nil then
      local season = gate_season()
      if season == nil or (r.phase == "season4") ~= season then return false end
    end
    local g = r.gate
    if g == nil then return true end
    local matched = 0
    for _, c in ipairs(g.conditions) do
      local ok
      if c.kind == "quest" then
        local state = gate_quest(c.qid)
        ok = state ~= false and state.ended == c.finish
      else
        ok = gate_variable(c)
      end
      if ok then matched = matched + 1
      elseif g.check == 0 then return false end
    end
    return g.check == 0 or matched > 0
  end

  local function apply_file_gates(enabled)
    gate_round = { quests = {}, variables = {}, season_read = false, season = nil }
    gate_stats = { season4 = nil, normal = { eligible = 0, total = 0 },
      quest = { eligible = 0, total = 0 }, read_failures = { season4 = 0, quest = 0, variable = 0 } }
    local eligible, file_givers = {}, {}
    local gate_work = enabled or next(S.file_giver_rows) ~= nil
    if gate_work then
      for _, r in ipairs(chara_rows) do
        local group = (r.src == "subquest" or r.src == "mainquest") and "quest" or "normal"
        local counts = gate_stats[group]
        counts.total = counts.total + 1
        local yes = row_eligible(r)
        if yes then counts.eligible = counts.eligible + 1 end
        if yes and S.file_monsters[r.uid] ~= nil then eligible[r.uid] = S.file_monsters[r.uid] end
        -- Quest-cast rows are giver anchors, not monster spawns. Keep their
        -- file positions available even before the source quest activates.
        local fg = S.file_giver_rows[r.uid]
        if fg ~= nil then
          local current_giver = file_givers[fg.id]
          if current_giver == nil or fg.uid < current_giver.uid then file_givers[fg.id] = fg end
        end
      end
    end
    local current, changed = S.eligible_file_monsters, false
    for uid in pairs(current) do if eligible[uid] == nil then changed = true; break end end
    if not changed then
      for uid in pairs(eligible) do if current[uid] == nil then changed = true; break end end
    end
    if changed then S.eligible_file_monsters = eligible end
    local giver_changed = false
    for id, current_giver in pairs(S.file_givers) do
      local next_giver = file_givers[id]
      if next_giver == nil or next_giver.uid ~= current_giver.uid then
        giver_changed = true; break
      end
    end
    if not giver_changed then
      for id, next_giver in pairs(file_givers) do
        local current_giver = S.file_givers[id]
        if current_giver == nil or current_giver.uid ~= next_giver.uid then
          giver_changed = true; break
        end
      end
    end
    if giver_changed then
      S.file_givers = file_givers
      givers_cache, givers_rev = nil, -1
    end
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
    local uids, live_givers = {}, {}
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
          local c = classify(cid, r.cid_name)
          if c == "giver" then
            if conditional_uids[uid] then
              local current_giver = live_givers[cid]
              if current_giver == nil or uid < current_giver.uid then
                live_givers[cid] = { uid = uid, x = round1(r.pos.x),
                  y = round1(r.pos.y), z = round1(r.pos.z) }
              end
            else
              learn(uid, "giver", cid, r.pos.x, r.pos.y, r.pos.z,
                to_int(r.table_ix), names[cid])
            end
          elseif c == "large" or c == "small" then
            if file_ok and (conditional_uids[uid] or S.file_monsters[uid] == nil) then
              live_only(uid, "monster", cid, r.pos.x, r.pos.y, r.pos.z, names[cid])
            else
              learn(uid, "monster", cid, r.pos.x, r.pos.y, r.pos.z,
                to_int(r.table_ix), names[cid])
            end
          end
        end
      end
    end
    S.live_givers = live_givers
    givers_cache, givers_rev = nil, -1
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

  -- the first of a shop's sellers with a usable position: cid, pos (or nil);
  -- computed once per round and shared by shops and sellers (SPEC 28.5.3.2)
  local fsc_memo = {}
  local function first_seller_cid(sid)
    local m = fsc_memo[sid]
    if m == nil then
      m = false
      for _, cid in ipairs(ensure_shop_cids()[sid] or {}) do
        local p = seller_pos(cid)
        if p ~= nil then m = { cid, p }; break end
      end
      fsc_memo[sid] = m
    end
    if m then return m[1], m[2] end
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
    if type(needs) ~= "table" then error("item needs unavailable") end
    local by_item = core.needs_by_item(needs)
    local located = {}
    local locations = a.item_locations()
    if type(locations) ~= "table" then error("item locations unavailable") end
    for _, r in ipairs(locations) do
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
    stats.shop_index_runs = stats.shop_index_runs + 1
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
                it = { id = b.item, name = item_name(b.item), locked = true }
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
  -- The static + eligible file monsters + learned merge and its sorted keys
  -- are kept until the learned set (rev) or eligibility changes. The live rows
  -- are laid over it (S.live first, the merge behind it). Returns that map and
  -- the sorted keys, live uids included.
  local eff_cache = nil
  local function effective()
    local c = eff_cache
    if c == nil or c.rev ~= rev or c.eligible ~= S.eligible_file_monsters then
      stats.eff_builds = stats.eff_builds + 1
      local eff = {}
      for uid, e in pairs(static) do eff[uid] = e end
      for uid, e in pairs(S.eligible_file_monsters) do eff[uid] = e end
      for uid, e in pairs(learned) do
        if e.k == "chest" and eff[uid] ~= nil then
          if e.items == nil then e.items = eff[uid].items end
          if e.quest == nil then e.quest = eff[uid].quest end
          if e.trap == nil then e.trap = eff[uid].trap end
          if e.pawn == nil then e.pawn = eff[uid].pawn end
        end
        eff[uid] = e
      end
      c = { rev = rev, eligible = S.eligible_file_monsters,
        map = eff, keys = sorted_keys(eff) }
      eff_cache = c
    end
    if next(S.live) == nil then return c.map, c.keys end
    -- the live rows are laid over the cached merge once, here: the returned
    -- map is S.live itself with the merge behind it, so a reader does one
    -- lookup. Only the live uids the merge lacks join the key list: sorted
    -- on their own, then merged into a new array in one pass.
    local live = S.live
    local extra = nil
    for uid in pairs(live) do
      if c.map[uid] == nil then
        extra = extra or {}
        extra[#extra + 1] = uid
      end
    end
    local keys = c.keys
    if extra ~= nil then
      table.sort(extra)
      keys = {}
      local n, i, j, ck, ne = 0, 1, 1, c.keys, #extra
      while i <= #ck and j <= ne do
        n = n + 1
        if ck[i] < extra[j] then keys[n] = ck[i]; i = i + 1
        else keys[n] = extra[j]; j = j + 1 end
      end
      while i <= #ck do n = n + 1; keys[n] = ck[i]; i = i + 1 end
      while j <= ne do n = n + 1; keys[n] = extra[j]; j = j + 1 end
    end
    c.mt = c.mt or { __index = c.map }
    return setmetatable(live, c.mt), keys
  end

  local KEPT_ITEMS = { [77] = true, [78] = true, [81] = true }

  -- kinds in spec order: ng_shard, kept, quest, trap, pawn
  local round_errs = {}

  local function chest_kinds(row, e, recs)
    stats.chest_kinds_calls = stats.chest_kinds_calls + 1
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

  -- builds up to NPC_NAME_SLICE more names; returns true while the list is
  -- unfinished and more can be built (the round then asks to run again)
  local function build_names()
    if S.npc_done then return false end
    local ids = sched_ids_list()
    if ids == nil then return false end
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
      return false
    end
    return true
  end

  -- returns the NPC list and whether the name list wants another round
  local function npc_round(tg)
    local t0 = clock()
    local more = build_names()
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
    return out, more
  end

  local ROUTE_ERR = "route unavailable"
  local ROUTE_SLOTS = 8 -- the colour slots (the eight route_colors)
  -- a place this close to a drawn NPC stop is held back (SPEC 32.14.11.2 sets
  -- it to the place-merge distance)
  local PLACE_STOP_M = core.MERGE_STOP_M

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

  -- the published route entries: the search target, then the members in
  -- order, a cid listed once
  local function published()
    local list, seen = {}, {}
    local t = S.target_member
    if t ~= nil then list[1] = t; seen[t.cid] = true end
    for _, m in ipairs(S.members) do
      if not seen[m.cid] then list[#list + 1] = m; seen[m.cid] = true end
    end
    return list
  end

  -- the cid is the target's or a member's
  local function live(cid)
    local t = S.target_member
    return (t ~= nil and t.cid == cid) or S.member_of[cid] ~= nil
  end

  local function free_slot(cid)
    local slot = S.slot_of[cid]
    if slot ~= nil then
      S.slot_of[cid] = nil
      S.slot_cid[slot] = nil
    end
  end

  -- a cid that left the route set drops its per-cid state
  local function leave(cid)
    if cid == nil or live(cid) then return end
    free_slot(cid)
    S.place_from[cid] = nil
    S.route_cache[cid] = nil
    S.route_fail[cid] = nil
    if w.rps ~= nil then w.rps[cid] = nil end
    if w.path_job ~= nil and w.path_job.cid == cid then w.path_job = nil end
    local l = input_tbl and input_tbl.routes
    if type(l) ~= "table" then return end
    for i = #l, 1, -1 do
      if l[i].cid == cid then table.remove(l, i) end
    end
    if #l == 0 then input_tbl.routes = nil end
  end

  -- the published entry for a member from its cached route (nil cache or no
  -- route: the error entry)
  local function route_contract(entry, member)
    if member.objective_generation ~= nil then
      entry.objective, entry.qid, entry.kind = member.objective == true, member.qid, member.kind
      entry.target_key, entry.ordinal = member.target_key, member.ordinal
      entry.objective_generation = member.objective_generation
    end
    return entry
  end
  local function render(member, c, hour)
    local cid, name = member.cid, member.name
    local errt = route_contract({ cid = cid, name = name, err = ROUTE_ERR }, member)
    if c == nil or c.value == nil then return errt end
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
    -- the stop whose hours hold the game hour (nil when none does)
    local current = nil
    if type(hour) == "number" then
      local npcs = require("Clairvoyance.npcs")
      for i, st in ipairs(stops) do
        if type(st.from) == "number" and type(st.to) == "number"
            and npcs.in_hours(hour, st.from, st.to) then
          current = i
          break
        end
      end
    end
    return route_contract({ cid = cid, name = name, stops = stops, unplaced = c.value.unplaced,
      off_schedule = c.value.off_schedule, current = current }, member)
  end

  -- every entry of the final list gets its sticky colour slot: the entry
  -- keeps the one it has, else the lowest free (nil past the eighth)
  local function give_slots(out)
    for _, e in ipairs(out) do
      local s = S.slot_of[e.cid]
      if s == nil then
        for k = 1, ROUTE_SLOTS do
          if S.slot_cid[k] == nil then s = k; break end
        end
        if s ~= nil then
          S.slot_of[e.cid] = s
          S.slot_cid[s] = e.cid
        end
      end
      e.slot = s
    end
    return out
  end

  local function stop_key(p)
    return string.format("%.1f,%.1f,%.1f", p.x, p.y, p.z)
  end

  -- the player end of a route entry (place or lead): remember where the
  -- route starts; when it moved, the old stop's walking-graph node is dropped
  local function set_from(cid, pl)
    local from = stop_key(pl)
    local old = S.place_from[cid]
    if old ~= nil and old ~= from then w.near[old] = nil end
    S.place_from[cid] = from
  end

  -- a drawn stop (SPEC 32.14.11.2): positioned, and discovered or shown anyway
  local function drawn_stop(st, tg)
    return valid_pos(st.pos) and (st.discovered ~= false or tg.undiscovered == true)
  end

  -- a place member's entry (SPEC 32.14.5.3): the player to the place, both
  -- discovered; nil (and no slot held) until both positions exist. When the
  -- player stop moved, the old stop's walking-graph node is dropped.
  local function place_entry(m, tg)
    local pl = type(tg) == "table" and tg.player or nil
    local kp = S.key_pos[m.place]
    if not valid_pos(pl) or kp == nil then
      free_slot(m.cid)
      return nil
    end
    set_from(m.cid, pl)
    return { cid = m.cid, place = m.place, name = m.name,
             stops = { { pos = pcopy(pl), discovered = true },
                       { pos = pcopy(kp), discovered = true } } }
  end

  -- A direct objective member shares the place route publication shape, but
  -- owns its copied position and never enters the key-position cache.
  local function direct_entry(m, tg)
    local pl = type(tg) == "table" and tg.player or nil
    if not valid_pos(pl) or not valid_pos(m.pos) then
      free_slot(m.cid)
      return nil
    end
    set_from(m.cid, pl)
    return { cid = m.cid, place = 0, direct = true, objective = m.objective,
      qid = m.qid, kind = m.kind, target_key = m.target_key, ordinal = m.ordinal,
      objective_generation = m.objective_generation, name = m.name, pos = pcopy(m.pos),
      stops = { { pos = pcopy(pl), discovered = true },
                { pos = pcopy(m.pos), discovered = true } } }
  end

  local function direct_member(e)
    if type(e) ~= "table" then return false end
    if e.ordinal ~= nil then
      return type(e.target_key) == "string" and e.target_key ~= ""
        and core.objective_direct_route_id(e.ordinal) == e.cid
        and e.place == 0 and e.objective == true and valid_pos(e.pos)
    end
    local route_id = core.objective_route_id(e.qid, e.kind)
    return route_id ~= nil and e.cid == route_id
      and e.place == 0 and e.objective == true and type(e.name) == "string"
      and valid_pos(e.pos)
  end

  local function same_direct_payload(a, b)
    return type(a) == "table" and type(b) == "table"
      and a.direct == true and b.direct == true and a.name == b.name
      and a.qid == b.qid and a.kind == b.kind and a.objective == b.objective
      and a.target_key == b.target_key and a.ordinal == b.ordinal
      and a.objective_generation == b.objective_generation
      and valid_pos(a.pos) and valid_pos(b.pos) and a.pos.x == b.pos.x
      and a.pos.y == b.pos.y and a.pos.z == b.pos.z
  end

  -- every member of the published list as an error entry (places still resolve)
  local function all_err(list, tg)
    local out = {}
    for _, m in ipairs(list) do
      if m.direct then
        local de = direct_entry(m, tg)
        if de ~= nil then out[#out + 1] = de end
      elseif m.place ~= nil then
        local pe = place_entry(m, tg)
        if pe ~= nil then out[#out + 1] = pe end
      else
        out[#out + 1] = route_contract({ cid = m.cid, name = m.name, err = ROUTE_ERR }, m)
        S.place_from[m.cid] = nil
      end
    end
    if #out == 0 then return nil, false end
    return give_slots(out), false
  end

  local function routes_round(tg)
    local list = published()
    if #list == 0 then return nil, false end
    local needs_schedule = false
    for _, m in ipairs(list) do
      if m.place == nil and not m.direct then needs_schedule = true; break end
    end
    if not needs_schedule then return all_err(list, tg) end
    if type(reads.schedule_now) ~= "function" then return all_err(list, tg) end
    local okn, day, hour = pcall(reads.schedule_now)
    if not okn or type(day) ~= "number" or type(hour) ~= "number" then return all_err(list, tg) end
    -- every member's signature is read each round (spec 25.5); a fixture
    -- without the read has none
    local info = {}
    local has_sig = type(reads.current_sig) == "function"
    for i, m in ipairs(list) do
      local sig, bad = "", false
      local is_place = m.place ~= nil and not m.direct
      local is_direct = m.direct == true
      if has_sig and not is_place and not is_direct then
        local ts = clock()
        local oks, a, l, k, o = pcall(reads.current_sig, m.cid)
        stats.ms.route_sig = (stats.ms.route_sig or 0) + (clock() - ts) * 1000
        if oks then
          sig = tostring(a) .. "|" .. tostring(l) .. "|" .. tostring(k) .. "|" .. tostring(o)
        else
          bad = true
        end
      end
      local e = { m = m, sig = sig, bad = bad, place = is_place, direct = is_direct }
      if not bad and not is_place and not is_direct then
        local c = S.route_cache[m.cid]
        e.key = tostring(day) .. "|" .. tostring(hour) .. "|" .. sig
        e.stale = c == nil or c.hour ~= hour or c.day ~= day or c.sig ~= sig
        local f = S.route_fail[m.cid]
        e.failed = e.stale and f ~= nil and f.key == e.key
      end
      info[i] = e
    end
    -- one build per round: the first stale cid that has not failed, else
    -- the oldest failure
    local pick, oldest = nil, nil
    for _, e in ipairs(info) do
      if e.stale and not e.failed then pick = e; break end
      if e.stale and e.failed then
        local seq = S.route_fail[e.m.cid].seq
        if oldest == nil or seq < S.route_fail[oldest.m.cid].seq then oldest = e end
      end
    end
    pick = pick or oldest
    if pick ~= nil then
      local cid = pick.m.cid
      local t0 = clock()
      local ok, built = pcall(function()
        return build_route(require("Clairvoyance.npcs"), cid, day, hour)
      end)
      stats.ms.route = (clock() - t0) * 1000
      stats.route_builds = stats.route_builds + 1
      if ok then
        S.route_cache[cid] = { cid = cid, hour = hour, day = day, sig = pick.sig, value = built }
        S.route_fail[cid] = nil
        pick.stale, pick.failed, pick.built = false, false, true
      else
        S.fail_seq = S.fail_seq + 1
        S.route_fail[cid] = { key = pick.key, seq = S.fail_seq }
        pick.failed, pick.built = true, true
      end
    end
    -- the NPC entries first (a place waits on them), then the final list in
    -- member order
    local out, again = {}, false
    local ents, npc_ready, block = {}, true, {}
    local pl = valid_pos(tg.player) and tg.player or nil
    for i, e in ipairs(info) do
      local m = e.m
      if not e.direct and not e.place then
        if e.bad or e.failed then
          ents[i] = route_contract({ cid = m.cid, name = m.name, err = ROUTE_ERR }, m)
          S.place_from[m.cid] = nil
        else
          local c = S.route_cache[m.cid]
          if e.stale then again = true end
          if c ~= nil then
            local r = render(m, c, hour)
            ents[i] = r
            local nd, di = 0, nil
            for k, st in ipairs(r.stops or {}) do
              if drawn_stop(st, tg) then
                nd = nd + 1
                di = di or k
                block[#block + 1] = st.pos
              end
            end
            -- exactly one drawn stop and a player: the route leads from them
            if nd == 1 and pl ~= nil then
              local st = r.stops[di]
              st.idx = di
              r.stops = { { pos = pcopy(pl), discovered = true, lead = true }, st }
              r.lead = true
              r.current = (r.current == di) and 2 or nil
              set_from(m.cid, pl)
            else
              S.place_from[m.cid] = nil
            end
          else
            npc_ready = false
          end
        end
      end
    end
    for i, e in ipairs(info) do
      local m = e.m
      if e.direct then
        local held = S.slot_of[m.cid] == nil and not npc_ready
        if held then free_slot(m.cid) else ents[i] = direct_entry(m, tg) end
        if ents[i] ~= nil then out[#out + 1] = ents[i] end
      elseif e.place then
        local held = S.slot_of[m.cid] == nil and not npc_ready
        local kp = S.key_pos[m.place]
        if not held and kp ~= nil then
          for _, p in ipairs(block) do
            local dx, dz = kp.x - p.x, kp.z - p.z
            if dx * dx + dz * dz <= PLACE_STOP_M * PLACE_STOP_M then held = true; break end
          end
        end
        local pe = nil
        if held then free_slot(m.cid) else pe = place_entry(m, tg) end
        if pe ~= nil then out[#out + 1] = pe end
      elseif ents[i] ~= nil then
        out[#out + 1] = ents[i]
      end
    end
    if #out == 0 then return nil, again end
    return give_slots(out), again
  end

  -- The quest focus (SPEC 32.6.1) as sets: the active quest ids (nil unless
  -- the list holds a number) and the item ids the active quests need.
  local function build_focus_sets(f)
    local iset = {}
    if type(f) ~= "table" or type(f.active) ~= "table" then return nil, iset end
    local qset, any = {}, false
    for _, q in ipairs(f.active) do
      if type(q) == "number" then
        qset[q] = true
        any = true
        local fq = type(f.quests) == "table" and f.quests[q] or nil
        if type(fq) == "table" and type(fq.items) == "table" then
          for _, id in ipairs(fq.items) do iset[id] = true end
        end
      end
    end
    if not any then return nil, iset end
    return qset, iset
  end

  -- memoised on the identity of the focus table (the caller hands the same
  -- table until the focus changes). The memo keys on table identity, so a
  -- caller passes a new table when the content changes.
  local function focus_sets(f)
    if type(f) ~= "table" then return build_focus_sets(f) end
    if S.fsrc ~= f then
      S.fq, S.fi = build_focus_sets(f)
      S.fsrc = f
    end
    return S.fq, S.fi
  end

  -- ----- the round -----
  -- returns the round's output and whether it wants another round at once
  -- (an unfinished NPC name list, a deferred drop read; SPEC 28.6)
  local function round(now, tg)
    local again = false
    local fq, fi = focus_sets(tg.focus)
    stats.hits, stats.misses = 0, 0
    S.live = {}
    fsc_memo = {}
    -- the per-round timings start empty (one-shot read timings stay)
    for i = #lapped, 1, -1 do
      stats.ms[lapped[i]] = nil
      lapped[i] = nil
    end
    for k in pairs(ACCUM) do stats.ms[k] = nil end
    for _, k in ipairs(CONDITIONAL_READS) do stats.ms[k] = nil end
    res_reused = false
    local any_rec = tg.chests or tg.tokens or tg.beetles or fq
    local need_shops = tg.search or tg.shops
    local t = clock()
    local cast_ok = ensure_cast()
    lap("cast", t)
    t = clock()
    ensure_boss()
    lap("boss", t)
    local boss_ok = S.boss ~= nil
    local any_monsters = tg.monsters or tg.small_monsters
    if any_monsters then
      t = clock()
      read_loaded_boss()
      lap("loaded_boss", t)
    end

    t = clock()
    local rows
    local sig_ok, sig = call("reserved_sig")
    if not (sig_ok and type(sig) == "string") then sig = nil end
    local res = S.res
    if sig ~= nil and res ~= nil and sig == res.sig
      and now - res.at < M.K.RESERVED_MAX_AGE then
      rows = res.rows
      res_reused = true
    else
      rows = table_read("reserved_rows")
      S.res = (rows ~= nil and sig ~= nil) and { rows = rows, sig = sig, at = now } or nil
    end
    lap("reserved", t)
    t = clock()
    if cast_ok and boss_ok and S.need_sort then sort_places() end
    apply_file_gates(any_monsters)
    lap("sort", t)
    local reserved_uids = nil
    t = clock()
    if rows ~= nil then
      reserved_uids = learn_reserved(rows, cast_ok and boss_ok)
    elseif next(S.live_givers) ~= nil then
      S.live_givers = {}
      givers_cache, givers_rev = nil, -1
    end
    lap("learn", t)
    t = clock()
    local loaded_seen = read_loaded(reserved_uids)
    lap("loaded", t)
    t = clock()
    if rows ~= nil then remove_patched(rows, reserved_uids) end
    lap("patched", t)

    t = clock()
    ensure_settlements()
    lap("settlements", t)

    -- schedule positions of cast NPCs (SPEC 17.3b.1.2)
    local schedule = {}
    t = clock()
    if S.cast ~= nil and type(reads.schedule_pos) == "function" then
      for _, cid in ipairs(S.cast_list) do
        local ok, p = call("schedule_pos", cid)
        if ok and valid_pos(p) and not near_zero(p) then
          schedule[cid] = { x = p.x, y = p.y, z = p.z }
        end
      end
    end
    lap("schedule", t)

    local rec_idx = nil
    if any_rec then
      t = clock()
      rec_idx = guarded("records", function()
        return build_records(need_table("save_records"))
      end)
      lap("records", t)
    end
    -- the First Seeker's Token spot (SPEC 28.9.2): straight from the places
    -- row, so it exists with the Tokens toggle off
    local first_token = nil
    if tg.first_token then
      t = clock()
      local ok, v = call("first_seeker")
      if ok and type(v) == "string" then
        local uid = v:lower()
        local row = static[uid]
        if row ~= nil and row.k == "token" then
          first_token = { uid = uid, pos = pcopy(row), name = "Finder's Token spot",
            state = collect_state(COLLECT.token, rec_idx, uid), first_seeker = true }
        end
      end
      lap("first_token", t)
    end
    t = clock()
    if loaded_seen ~= nil and rec_idx ~= nil then
      for uid in pairs(loaded_seen) do
        if rec_idx[uid] ~= nil then stats.hits = stats.hits + 1
        else stats.misses = stats.misses + 1 end
      end
    end
    lap("seen", t)

    t = clock()
    local eff, uids = effective()
    lap("effective", t)
    local out = { chests = {}, treasure = {}, tokens = {}, beetles = {},
      monsters = {}, sellers = {}, schedule = schedule, settlements = {},
      objective_source_status = {},
      first_token = first_token }

    if S.settle ~= nil then
      for _, s in ipairs(S.settle) do
        out.settlements[#out.settlements + 1] = { name = s.name, pos = pcopy(s.pos) }
      end
    end

    -- chests, tokens, beetles
    local collect_t0 = clock()
    local chest_qs = nil
    for _, uid in ipairs(uids) do
      local e = eff[uid]
      if e.k == "chest" and (tg.chests or fq) then
        local row = static[uid] or e
        local gate_qids, item_ids = nil, nil
        -- the id lists are kept per uid while the row stays the same table
        local ck = S.chest_ids and S.chest_ids[uid]
        if ck ~= nil and ck.row == row then
          gate_qids, item_ids = ck.g, ck.i
        else
          if type(row.quest) == "table" and type(row.quest.q) == "table" then
            for _, qe in ipairs(row.quest.q) do
              local qid = type(qe) == "table" and qe[1] or nil
              if type(qid) == "number" then
                gate_qids = gate_qids or {}
                gate_qids[#gate_qids + 1] = qid
              end
            end
          end
          if type(row.items) == "table" then
            for _, it in ipairs(row.items) do
              local id = type(it) == "table" and to_int(it.id) or nil
              if id ~= nil then
                item_ids = item_ids or {}
                item_ids[#item_ids + 1] = id
              end
            end
          end
          S.chest_ids = S.chest_ids or {}
          S.chest_ids[uid] = { row = row, g = gate_qids, i = item_ids }
        end
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
        local wanted = tg.chests and true or false
        if not wanted and fq then
          for _, q in ipairs(gate_qids or EMPTY) do
            if fq[q] then wanted = true; break end
          end
          for _, id in ipairs(item_ids or EMPTY) do
            if wanted then break end
            if fi[id] then wanted = true end
          end
          if not wanted and item ~= nil and fi[item] then wanted = true end
        end
        if wanted then
          local c = { uid = uid, pos = pcopy(e), gimmick = e.id, state = state,
            item = item, item_name = item ~= nil and item_name(item) or nil,
            gate_qids = gate_qids, item_ids = item_ids }
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
            local built
            c.items, built = M.item_list(S.chest_lists, uid, e.items, item_name)
            if built then stats.item_list_builds = stats.item_list_builds + 1 end
          end
          out.chests[#out.chests + 1] = c
        end
      elseif COLLECT[e.k] and tg[COLLECT[e.k].list] then
        local def = COLLECT[e.k]
        local list = out[def.list]
        local entry = { uid = uid, pos = pcopy(e),
          name = item_name(M.K[def.item]),
          state = collect_state(def, rec_idx, uid) }
        -- the ordinary entry for the Finder's Token spot is marked, so
        -- consumers can leave it out of results (it still counts as known)
        if e.k == "token" and first_token ~= nil and uid == first_token.uid then
          entry.first_seeker = true
        end
        list[#list + 1] = entry
      end
    end

    lap("collect", collect_t0)

    -- treasure
    if tg.treasure or tg.sellers or need_shops or fq then
      t = clock()
      refresh_discovery()
      lap("discovery", t)
    end
    local treasure_t0 = clock()
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
            local built
            t.items, built = M.item_list(S.treasure_lists, n.name, ce.items, item_name)
            if built then stats.item_list_builds = stats.item_list_builds + 1 end
          end
        end
      end
      table.sort(out.treasure, function(p, q) return p.name < q.name end)
      lap("treasure", treasure_t0)
    end

    -- shop stock index for map search or the Shops toggle (SPEC 19.7.1, 20.2);
    -- runs before the sellers so a shared first S.shops / shop-cid read is
    -- charged to search_first_ms, whichever trigger ran it first
    local first_shops = stats.search_first_ms == nil
    if need_shops then
      local t0 = clock()
      local list, fresh = guarded("shop_index", compute_shops)
      lap("shop_index", t0)
      out.shops = list or {}
      out.objective_source_status.shop = fresh and "ok" or "unknown"
      if not fresh then out.objective_source_status.shop_reason = "shop_snapshot_unreadable" end
      if stats.search_first_ms == nil and list ~= nil then
        stats.search_first_ms = (clock() - t0) * 1000
      end
    end

    -- sellers
    if tg.sellers or fq then
      t = clock()
      local list, fresh = guarded("sellers", compute_sellers)
      lap("sellers", t)
      out.objective_source_status.seller = fresh and "ok" or "unknown"
      if not fresh then out.objective_source_status.seller_reason = "seller_snapshot_unreadable" end
      for _, s in ipairs(list or EMPTY) do
        local keep = tg.sellers and true or false
        if not keep then
          for _, q in ipairs(s.qids or EMPTY) do
            if fq[q] then keep = true; break end
          end
        end
        if keep then
          local c = {}
          for k, v in pairs(s) do c[k] = v end
          c.discovered = discovered("s:" .. tostring(s.shop), s.pos)
          out.sellers[#out.sellers + 1] = c
        end
      end
    end

    -- monsters
    if any_monsters and cast_ok and boss_ok then
      local monsters_t0 = clock()
      -- each class is skipped before clustering when its own toggle is off
      -- (SPEC 28.7.1, 28.12.2)
      local want_large, want_small = tg.monsters == true, tg.small_monsters == true
      local units = guarded("respawn", function() return need_table("respawn_units") end)
      local items = {}
      local function add_monster(uid, e)
        if e.k == "monster" then
          local nm = e.name or names[e.id]
          local fam = fam_of(nm)
          local cls = family_class(fam)
          if (cls == "small" and want_small) or (cls ~= "small" and cls ~= "drop" and want_large) then
            items[uid] = { uid = uid, cid = e.id, fam = fam or "?", pos = pcopy(e),
              small = cls == "small", respawning = false }
          end
        end
      end
      for _, uid in ipairs(uids) do add_monster(uid, eff[uid]) end
      for _, u in ipairs(units or {}) do
        if type(u) == "table" and type(u.key) == "string" and to_int(u.cid) ~= nil then
          local uid = guid_of(u.key)
          local cid = to_int(u.cid)
          if type(u.cid_name) == "string" and u.cid_name ~= "" then names[cid] = u.cid_name end
          local cls = classify(cid, u.cid_name, nil, nil)
          if (cls == "small" and want_small) or (cls == "large" and want_large) then
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
      -- clustering per family and kind (SPEC 17.10.9, 29.4)
      local groups = {}
      for uid, it in pairs(items) do
        local key = it.fam .. "\0" .. badge(it.cid)
        local l = groups[key]
        if l == nil then l = {}; groups[key] = l end
        l[#l + 1] = uid
      end
      local ids = {}
      for _, key in ipairs(sorted_keys(groups)) do
        table.sort(groups[key])
        for _, c in ipairs(M.cluster(items, groups[key], M.K.CLUSTER)) do
          local s = c.seed
          local kind = badge(s.cid)
          local nm = kind
          if c.count > 1 then nm = nm .. " x" .. c.count end
          out.monsters[#out.monsters + 1] = { uid = s.uid, cid = s.cid, name = nm,
            kind = kind, fam = s.fam,
            pos = pcopy(s.pos), respawning = c.respawning == true,
            small = s.small == true, count = c.count, cids = c.cids }
          ids[s.cid] = true
        end
      end
      table.sort(out.monsters, function(p, q) return p.uid < q.uid end)
      stats.monster_ids = sorted_keys(ids)
      lap("monsters", monsters_t0)
    end

    -- drops: deferred past the round whose shop index first succeeds (19.12.3.3)
    if tg.search and any_monsters then
      local drops_t0 = clock()
      if first_shops and stats.search_first_ms ~= nil and S.drop_ids == nil then
        again = true
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
      lap("drops", drops_t0)
    end

    for _, cat in ipairs({ "chests", "treasure", "tokens", "beetles", "monsters", "sellers" }) do
      stats.known[cat] = #out[cat]
    end
    if tg.search then
      local more
      t = clock()
      out.npcs, more = npc_round(tg)
      lap("npcs", t)
      again = again or more == true
    end
    if type(tg.focus_keys) == "table" then
      t = clock()
      local places, seen = {}, {}
      for _, v in ipairs(tg.focus_keys) do
        local key = to_int(v)
        if key ~= nil and key > 0 and not seen[key] then
          seen[key] = true
          local p = S.key_pos[key]
          if p == nil then
            local ok, v2 = call("key_pos", key)
            if ok and valid_pos(v2) then
              p = pcopy(v2)
              S.key_pos[key] = p
            end
          end
          if p ~= nil then places[key] = pcopy(p) end
        end
      end
      out.focus_places = places
      lap("focus_places", t)
    end
    t = clock()
    local more_routes
    out.routes, more_routes = routes_round(tg)
    lap("route", t)
    return out, again or more_routes
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

  -- a route entry that has no error and at least one stop
  local function has_stops(r)
    return r.err == nil and type(r.stops) == "table" and #r.stops > 0
  end

  -- a round result with a route on: some entry has no error and a stop
  local function routes_on(res)
    local l = res and res.routes
    if type(l) ~= "table" then return false end
    for _, r in ipairs(l) do
      if has_stops(r) then return true end
    end
    return false
  end

  -- ----- public -----
  -- hold (the full map is open or the game is paused) skips a round that is
  -- merely due; a round whose throttle was cleared (a poke, the run-again
  -- flag, set_route) or whose NPC list changed still runs (SPEC 28.8.1)
  function w:refresh(now, gate, toggles, hold)
    if not gate or type(toggles) ~= "table" then return false end
    local tg = toggles
    if not M.wants_round(tg, #S.members) then return false end
    if last_round ~= nil
      and not (tg.search and cid_signature(tg.npc_cids) ~= S.npc_sig) then
      if now - last_round < M.K.WORLD_ROUND then return false end
      if hold then
        stats.held_rounds = stats.held_rounds + 1
        return false
      end
    end
    last_round, last_now = now, now
    if tg.search then S.npc_sig = cid_signature(tg.npc_cids) end
    local rt0 = clock()
    local ok, res, again = pcall(round, now, tg)
    stats.round_ms = (clock() - rt0) * 1000
    if not ok then
      local msg = tostring(res)
      if not round_errs[msg] then
        round_errs[msg] = true
        pcall(io.log, "round failed: " .. msg)
      end
    end
    if not ok or type(res) ~= "table" then return false end
    if routes_on(res) and not routes_on(input_tbl) then w.route_gen = w.route_gen + 1 end
    input_tbl = res
    committed = true
    if again then last_round = nil end
    stats.rounds = stats.rounds + 1
    if res_reused then stats.reserved_reused = stats.reserved_reused + 1
    else stats.reserved_reads = stats.reserved_reads + 1 end
    if dirty and (last_save == nil or now - last_save >= M.K.SAVE_EVERY) then
      do_save("round", now)
    end
    return true
  end

  function w:input() return input_tbl end

  local function objective_clone(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
      out[objective_clone(k, seen)] = objective_clone(v, seen)
    end
    return out
  end
  local function objective_same(a0, b0, pairs_seen)
    if type(a0) ~= type(b0) then return false end
    if type(a0) ~= "table" then return a0 == b0 end
    pairs_seen = pairs_seen or {}
    local seen = pairs_seen[a0]
    if seen ~= nil then return seen == b0 end
    pairs_seen[a0] = b0
    for k, v in pairs(a0) do
      if rawget(b0, k) == nil and v ~= nil then return false end
      if not objective_same(v, b0[k], pairs_seen) then return false end
    end
    for k, v in pairs(b0) do
      if rawget(a0, k) == nil and v ~= nil then return false end
    end
    return true
  end

  function w:objective_place_snapshot(task_snapshot)
    local journal_generation = type(task_snapshot) == "table"
      and task_snapshot.journal_generation or nil
    local function array(value)
      if type(value) ~= "table" then return nil end
      local n, count = #value, 0
      for k in pairs(value) do
        if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
        count = count + 1
      end
      return count == n and value or nil
    end
    local function integer(value, minimum)
      return type(value) == "number" and math.type(value) == "integer" and value >= minimum
    end
    local function copy_pos(pos)
      return valid_pos(pos) and { x = pos.x, y = pos.y, z = pos.z } or nil
    end
    local function publish(status, reason, places)
      local evidence = { status = status, reason = reason,
        places = objective_clone(places) }
      for _, place in ipairs(evidence.places) do place.generation = nil end
      local state = S.objective_place_observation
      local generation = state and state.generation or 1
      if state ~= nil and not objective_same(state.value, evidence) then
        generation = math.min(2147483647, generation + 1)
      end
      S.objective_place_observation = { generation = generation,
        value = objective_clone(evidence) }
      local out = objective_clone(places)
      for _, place in ipairs(out) do place.generation = generation end
      return { generation = generation, status = status, reason = reason, places = out }
    end
    local function unknown(reason) return publish("unknown", reason, {}) end
    if not integer(journal_generation, 1) or type(task_snapshot) ~= "table"
        or array(task_snapshot.quests) == nil then
      return unknown("task_snapshot_unavailable")
    end
    local places, seen, wanted = {}, {}, false
    local function resolve(qid, task_index, owner_kind, owner_index, signal_index, target)
      if type(target) ~= "table" or type(target.place) ~= "table" then return true end
      wanted = true
      local place = target.place
      local pos = copy_pos(target.pos)
      if pos == nil and place.kind == "key_location" and integer(place.key, 1) then
        local ok, value = call("key_pos", place.key)
        if ok then pos = copy_pos(value) end
      elseif pos == nil and place.kind == "local_area" and integer(place.local_area, 0) then
        local ok, values = call("area_nodes", { area = place.local_area })
        local rows = ok and array(values) or nil
        if rows == nil or #rows == 0 then return false end
        for _, value in ipairs(rows) do
          local point = copy_pos(value)
          if point == nil then return false end
          if pos == nil then pos = point end
        end
      end
      if pos == nil or (place.kind ~= "key_location" and place.kind ~= "local_area") then return false end
      local key = table.concat({ tostring(qid), tostring(task_index), tostring(owner_kind),
        tostring(owner_index), tostring(signal_index) }, ":")
      if not seen[key] then
        seen[key] = true
        places[#places + 1] = { qid = qid, task_index = task_index,
          owner_kind = owner_kind, owner_index = owner_index, signal_index = signal_index,
          target = { kind = place.kind,
            key = place.kind == "key_location" and place.key or nil,
            local_area = place.kind == "local_area" and place.local_area or nil },
          pos = pos, eligibility = "eligible" }
      end
      return true
    end
    for _, quest in ipairs(task_snapshot.quests) do
      if type(quest) ~= "table" or quest.read_status ~= "ok"
          or not integer(quest.qid, 1) or not integer(quest.task_index, 0) then
        return unknown(type(quest) == "table" and quest.reason or "task_snapshot_partial")
      end
      local task_signals, guidance_rows = array(quest.task_destinations), array(quest.guidance)
      if task_signals == nil or guidance_rows == nil then return unknown("task_snapshot_partial") end
      for _, signal in ipairs(task_signals) do
        if type(signal) ~= "table" then return unknown("task_destination_malformed") end
        if signal.kind == "place" and signal.task_index == quest.task_index then
          if signal.eligibility == "unknown" then return unknown(signal.reason or "task_place_unknown") end
          if signal.eligibility == "eligible" and not resolve(quest.qid, quest.task_index,
              "task", quest.task_index, signal.destination_index, signal.target) then
            return unknown(signal.reason or "task_place_unresolved")
          end
        end
      end
      for _, guidance in ipairs(guidance_rows) do
        if type(guidance) ~= "table" then return unknown("guidance_malformed") end
        if guidance.task_index == quest.task_index then
          if guidance.eligibility == "unknown" then return unknown(guidance.reason or "guidance_place_unknown") end
          if guidance.eligibility == "eligible" then
            local signals = array(guidance.signals)
            if signals == nil then return unknown("guidance_signals_unreadable") end
            for _, signal in ipairs(signals) do
              if type(signal) ~= "table" then return unknown("guidance_signal_malformed") end
              if signal.kind == "place" and signal.eligibility == "eligible"
                  and not resolve(quest.qid, quest.task_index, "guidance",
                    guidance.concierge_index, guidance.destination_index, signal.target) then
                return unknown(signal.reason or "guidance_place_unresolved")
              elseif signal.kind == "place" and signal.eligibility == "unknown" then
                return unknown(signal.reason or "guidance_place_unknown")
              end
            end
          end
        end
      end
    end
    if not wanted or #places == 0 then return unknown("current_place_unavailable") end
    return publish("ok", nil, places)
  end

  local function objective_task_rows(task_snapshot)
    local function integer(value, minimum)
      return type(value) == "number" and math.type(value) == "integer" and value >= minimum
    end
    local function array(value)
      if type(value) ~= "table" then return nil end
      local n, count = #value, 0
      for k in pairs(value) do
        if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
        count = count + 1
      end
      return count == n and value or nil
    end
    if type(task_snapshot) ~= "table" or not integer(task_snapshot.need_generation, 1) then return nil end
    local quests = array(task_snapshot.quests)
    if quests == nil then return nil end
    local current = {}
    for _, quest in ipairs(quests) do
      if type(quest) == "table" and integer(quest.qid, 1)
          and integer(quest.task_index, 0) and quest.read_status == "ok" then
        if current[quest.qid] ~= nil and current[quest.qid] ~= quest.task_index then return nil end
        current[quest.qid] = quest.task_index
      end
    end
    return current
  end

  local function objective_need_proves_current_work(task_snapshot, need_snapshot, current_tasks)
    local function integer(value, minimum)
      return type(value) == "number" and math.type(value) == "integer" and value >= minimum
    end
    local function array(value)
      if type(value) ~= "table" then return nil end
      local n, count = #value, 0
      for k in pairs(value) do
        if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
        count = count + 1
      end
      return count == n and value or nil
    end
    if current_tasks == nil or next(current_tasks) == nil or type(need_snapshot) ~= "table"
        or need_snapshot.status ~= "ok" or need_snapshot.complete ~= true
        or need_snapshot.generation ~= task_snapshot.need_generation
        or not integer(need_snapshot.generation, 1)
        or not integer(need_snapshot.source_generation, 1) then return false end
    local groups = array(need_snapshot.groups)
    if groups == nil or #groups == 0 then return false end
    local matched = false
    for _, group in ipairs(groups) do
      if type(group) ~= "table" or not integer(group.qid, 1)
          or not integer(group.task_index, 0)
          or current_tasks[group.qid] ~= group.task_index
          or group.status ~= "eligible" or group.complete ~= true
          or group.generation ~= need_snapshot.source_generation
          or not integer(group.remaining, 1) then return false end
      local options = array(group.options)
      if options == nil or #options == 0 then return false end
      for _, option in ipairs(options) do
        if type(option) ~= "table" or not integer(option.item_id, 1)
            or not integer(option.accepted_count, 1) then return false end
      end
      matched = true
    end
    return matched
  end

  function w:objective_source_snapshots(objective_catalog, task_snapshot)
    local function array(value)
      if type(value) ~= "table" then return nil end
      local n, count = #value, 0
      for k in pairs(value) do
        if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
        count = count + 1
      end
      return count == n and value or nil
    end
    local function integer(value, minimum)
      return type(value) == "number" and math.type(value) == "integer" and value >= minimum
    end
    local function candidate_evidence(rows)
      if type(rows) ~= "table" then return objective_clone(rows) end
      local out = objective_clone(rows)
      for _, candidate in ipairs(out) do
        if type(candidate) == "table" then candidate.generation = nil end
      end
      return out
    end
    local function observe(name, status, reason, evidence)
      local state = S.objective_source_observations[name]
      local generation = state and state.generation or 1
      if state ~= nil and not objective_same(state.value, evidence) then
        generation = math.min(2147483647, generation + 1)
      end
      S.objective_source_observations[name] = { generation = generation,
        value = objective_clone(evidence) }
      return { provider = name, generation = generation, status = status,
        reason = reason, candidates = {} }
    end
    local generation = type(task_snapshot) == "table" and task_snapshot.need_generation or nil
    local current_tasks = objective_task_rows(task_snapshot)
    local task_array_valid = type(task_snapshot) == "table"
      and type(generation) == "number" and math.type(generation) == "integer" and generation > 0
      and array(task_snapshot.quests) ~= nil
    local need_snapshot, need_readable = nil, false
    if task_array_valid and type(a.objective_need_groups) == "function" then
      need_readable, need_snapshot = pcall(a.objective_need_groups, task_snapshot)
    end
    local valid_task = objective_need_proves_current_work(task_snapshot,
      need_readable and need_snapshot or nil, current_tasks)
    local providers, rows_by_provider = {}, {}
    local ok, base = false, nil
    if valid_task and type(a.objective_item_source_snapshots) == "function" then
      ok, base = pcall(a.objective_item_source_snapshots, objective_catalog, task_snapshot)
    end
    local base_rows = ok and array(base) or nil
    if base_rows ~= nil then
      for _, row in ipairs(base_rows) do
        if type(row) == "table" and (row.provider == "placed" or row.provider == "chest"
            or row.provider == "loot") and rows_by_provider[row.provider] == nil then
          rows_by_provider[row.provider] = row
        end
      end
    end
    for _, name in ipairs({ "placed", "chest", "loot" }) do
      local row = rows_by_provider[name]
      local status, reason, candidates = "unknown", nil, {}
      if not valid_task then
        reason = "task_snapshot_unavailable"
      elseif row == nil then
        reason = base_rows == nil and "adapter_source_snapshot_unavailable" or "provider_snapshot_missing"
      elseif not integer(row.generation, 1) then
        reason = "provider_generation_invalid"
      elseif row.status == "unknown" then
        reason = type(row.reason) == "string" and row.reason ~= "" and row.reason
          or "provider_evidence_unproven"
      elseif row.status == "ok" and array(row.candidates) ~= nil then
        local candidates_valid = true
        for _, candidate in ipairs(row.candidates) do
          if type(candidate) ~= "table" or candidate.generation ~= row.generation then
            candidates_valid = false; break
          end
        end
        if candidates_valid then status, candidates = "ok", objective_clone(row.candidates)
        else reason = "candidate_generation_mismatch" end
      else
        reason = type(row.reason) == "string" and row.reason or "provider_snapshot_partial"
      end
      local evidence = { task_valid = valid_task and true or false,
        status = status, reason = reason,
        adapter_status = row and row.status or nil,
        adapter_reason = row and row.reason or nil,
        adapter_candidates = row and candidate_evidence(row.candidates) or nil }
      if row ~= nil then
        for k, v in pairs(row) do
          if k ~= "generation" and k ~= "status" and k ~= "reason" and k ~= "candidates" then
            evidence[k] = objective_clone(v)
          end
        end
      end
      local out = observe(name, status, reason, evidence)
      out.candidates = candidates
      for _, candidate in ipairs(out.candidates) do
        if type(candidate) == "table" then candidate.generation = out.generation end
      end
      if row ~= nil then
        for k, v in pairs(row) do
          if k ~= "generation" and k ~= "status" and k ~= "reason" and k ~= "candidates" then
            out[k] = objective_clone(v)
          end
        end
      end
      providers[#providers + 1] = out
    end
    local shop = w:objective_shop_observations(valid_task and task_snapshot or nil,
      valid_task and need_snapshot or nil)
    local monster = w:objective_monster_observations(valid_task and task_snapshot or nil,
      valid_task and need_snapshot or nil)
    providers[#providers + 1] = shop
    providers[#providers + 1] = monster
    return providers
  end

  -- World-owned live source readers are optional until their managed gates are
  -- proven. Missing or partial reads publish unknown and never retain rows.
  local function objective_live_sources(provider, read_name, normalize, task_snapshot, need_snapshot)
    local need_generation = type(task_snapshot) == "table"
      and to_int(task_snapshot.need_generation) or nil
    local current_tasks = objective_task_rows(task_snapshot)
    local owns_current_work = objective_need_proves_current_work(task_snapshot,
      need_snapshot, current_tasks)
    if not owns_current_work then
      S.objective_live_source_cache[provider] = nil
      local evidence = { status = "unknown", reason = "current_work_unavailable" }
      local key = "world-" .. provider
      local state = S.objective_source_observations[key]
      local generation = state and state.generation or 1
      if state ~= nil and not objective_same(state.value, evidence) then
        generation = math.min(2147483647, generation + 1)
      end
      S.objective_source_observations[key] = { generation = generation,
        value = objective_clone(evidence) }
      return { provider = provider, status = "unknown", complete = false,
        generation = generation, reason = evidence.reason, candidates = {} }
    end
    local cached = S.objective_live_source_cache[provider]
    if cached ~= nil and cached.round == last_round
      and cached.need_generation == need_generation then return objective_clone(cached.value) end
    local ok, raw = call(read_name, task_snapshot, objective_catalog)
    local rows = type(raw) == "table" and raw.rows or nil
    local dense, n = type(rows) == "table", type(rows) == "table" and #rows or 0
    if dense then
      local count = 0
      for k in pairs(rows) do
        if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then
          dense = false; break
        end
        count = count + 1
      end
      dense = dense and count == n
    end
    local candidates, reason, status = {}, nil, "unknown"
    if not ok or type(raw) ~= "table" then
      reason = provider .. "_live_state_unavailable"
    elseif raw.complete ~= true or not dense then
      reason = provider .. "_scan_incomplete"
    else
      local seen, seen_end = {}, {}
      local function already_seen(tuple)
        local node = seen
        for i, part in ipairs(tuple) do
          if i == #tuple then
            if node[part] == nil then node[part] = {} end
            node = node[part]
            if node[seen_end] then return true end
            node[seen_end] = true
          else
            if node[part] == nil then node[part] = {} end
            node = node[part]
          end
        end
        return false
      end
      local valid = true
      for _, row in ipairs(rows) do
        local candidate, row_reason = normalize(row)
        if row_reason ~= nil then reason, valid = row_reason, false; break end
        if candidate ~= nil and candidate ~= false then
          if already_seen(candidate.source_id) then
            reason, valid = "duplicate_source_identity", false; break
          end
          candidates[#candidates + 1] = candidate
        end
      end
      if valid then status = "ok" else candidates = {} end
    end
    local evidence = { status = status, reason = reason, raw = raw }
    local key = "world-" .. provider
    local state = S.objective_source_observations[key]
    local generation = state and state.generation or 1
    if state ~= nil and not objective_same(state.value, evidence) then
      generation = math.min(2147483647, generation + 1)
    end
    S.objective_source_observations[key] = { generation = generation,
      value = objective_clone(evidence) }
    for _, candidate in ipairs(candidates) do candidate.generation = generation end
    local result = { provider = provider, status = status, complete = status == "ok",
      generation = generation, reason = reason, candidates = candidates }
    S.objective_live_source_cache[provider] = { round = last_round,
      need_generation = need_generation,
      value = objective_clone(result) }
    return result
  end

  function w:objective_shop_observations(task_snapshot, need_snapshot)
    local offers = {}
    return objective_live_sources("shop", "objective_shop_rows", function(row)
      if type(row) ~= "table" then return nil, "shop_row_malformed" end
      local sid, ordinal, cid = to_int(row.shop_id), to_int(row.offer_ordinal), to_int(row.seller_cid)
      local item_id, count = to_int(row.item_id), to_int(row.count)
      if sid == nil or sid <= 0 or ordinal == nil or ordinal <= 0 or cid == nil or cid <= 0
        or item_id == nil or item_id <= 0 or count == nil or count <= 0
        or not valid_pos(row.pos) or near_zero(row.pos) then
        return nil, "shop_identity_output_or_position_invalid"
      end
      if type(row.released) ~= "boolean" or type(row.talk_available) ~= "boolean"
        or type(row.interactable) ~= "boolean" or type(row.restock_readable) ~= "boolean" then
        return nil, "shop_gate_unreadable"
      end
      if not row.restock_readable then return nil, "shop_stock_unreadable" end
      local capacity_kind, available
      if row.capacity_kind == "unlimited" and row.unlimited == true then
        capacity_kind = "unlimited"
      elseif row.capacity_kind == "finite" and row.unlimited == false
        and row.restock_readable and to_int(row.stock) ~= nil and row.stock >= 0 then
        capacity_kind, available = "finite", row.stock
      else
        return nil, "shop_stock_unreadable"
      end
      local by_ordinal = offers[sid]
      if by_ordinal == nil then by_ordinal = {}; offers[sid] = by_ordinal end
      local signature = { item_id, count, capacity_kind, row.unlimited,
        row.restock_readable, available }
      local prior = by_ordinal[ordinal]
      if prior ~= nil then
        for i, value in ipairs(signature) do
          if prior[i] ~= value then return nil, "shop_offer_capacity_conflict" end
        end
      else
        by_ordinal[ordinal] = signature
      end
      if not row.released or not row.talk_available or not row.interactable
        or (capacity_kind == "finite" and available == 0) then return false end
      local source_id = { "source", "shop_offer", sid, ordinal, cid }
      local pool_id = { "capacity", "shop_offer", sid, ordinal }
      return { source_id = source_id, provider = "shop",
        target = { kind = "seller", shop_id = sid, offer_ordinal = ordinal,
          seller_cid = cid, pos = { x = row.pos.x, y = row.pos.y, z = row.pos.z } },
        outputs = { { item_id = item_id, count = count } },
        capacity_pool_id = pool_id, capacity_kind = capacity_kind,
        available_acquisitions = available, certainty = "guaranteed",
        eligibility = "eligible", evidence = { released = true, talk_available = true,
          interactable = true, restock_readable = row.restock_readable } }
    end, task_snapshot, need_snapshot)
  end

  function w:objective_monster_observations(task_snapshot, need_snapshot)
    return objective_live_sources("monster", "objective_monster_rows", function(row)
      if type(row) ~= "table" then return nil, "monster_row_malformed" end
      local drop_id = row.drop_row_id
      local valid_drop_id = (type(drop_id) == "string" and drop_id ~= "")
        or (to_int(drop_id) ~= nil and drop_id > 0)
      if type(row.uid) ~= "string" or row.uid == "" or not valid_drop_id
        or type(row.alive) ~= "boolean"
        or type(row.accessible) ~= "boolean" then
        return nil, "monster_identity_or_gate_unreadable"
      end
      if not row.alive or not row.accessible then return false end
      if row.drop_table_readable ~= true then return nil, "monster_drop_table_unreadable" end
      local item_id, count = to_int(row.item_id), to_int(row.count)
      if item_id == nil or item_id <= 0 or count == nil or count <= 0
        or not valid_pos(row.pos) or near_zero(row.pos)
        or not finite(row.chance) or row.chance < 0 then
        return nil, "monster_drop_evidence_invalid"
      end
      if row.chance == 0 then return false end
      local source_id = { "source", "monster_drop", row.uid, drop_id }
      return { source_id = source_id, provider = "monster",
        target = { kind = "monster", uid = row.uid, pos = { x = row.pos.x,
          y = row.pos.y, z = row.pos.z } },
        outputs = { { item_id = item_id, count = count } },
        capacity_pool_id = { "capacity", "monster_drop", row.uid, drop_id },
        capacity_kind = "finite", available_acquisitions = 1, certainty = "probabilistic",
        probability = row.chance, eligibility = "eligible",
        evidence = { alive = true, accessible = true, drop_table_readable = true } }
    end, task_snapshot, need_snapshot)
  end

  -- the next refresh runs a round even inside the throttle window
  function w:poke()
    last_round = nil
    S.objective_live_source_cache = {}
  end

  -- SPEC 22.8: the route NPC; the next refresh builds it
  function w:set_route(cid, name)
    if type(cid) ~= "number" or cid <= 0 then return end
    local old = S.target_member and S.target_member.cid
    S.target_member = { cid = cid, name = name }
    if cid ~= old then
      w.route_gen = w.route_gen + 1
      leave(old)
    end
    S.route_cache[cid] = nil
    S.route_fail[cid] = nil
    last_round = nil
    S.objective_live_source_cache = {}
  end

  -- Remove every published member before replacing an objective generation.
  local function clear_members_now(preserve_members)
    local old = S.members
    local preserve = {}
    for _, m in ipairs(preserve_members or EMPTY) do
      if preserve[m.cid] == nil and m.objective == true
          and type(m.target_key) == "string" and type(m.ordinal) == "number" then
        preserve[m.cid] = { kind = "objective", target_key = m.target_key, ordinal = m.ordinal }
      elseif preserve[m.cid] == nil and m.objective == true
          and m.target_key == nil and m.ordinal == nil and m.direct ~= true then
        preserve[m.cid] = { kind = "startable" }
      elseif preserve[m.cid] == nil and m.objective == false
          and m.target_key == nil and m.ordinal == nil and m.direct ~= true then
        preserve[m.cid] = { kind = "ancillary" }
      end
    end
    S.members, S.member_of = {}, {}
    for _, m in ipairs(old) do
      local cid = m.cid
      local identity = preserve[cid]
      local exact = identity ~= nil and identity.kind == "objective" and m.objective == true
        and identity.target_key == m.target_key and identity.ordinal == m.ordinal
      local ancillary = identity ~= nil and identity.kind == "ancillary" and m.objective == false
        and m.target_key == nil and m.ordinal == nil and m.direct ~= true
      local startable = identity ~= nil and identity.kind == "startable" and m.objective == true
        and m.target_key == nil and m.ordinal == nil and m.direct ~= true
      if not exact and not ancillary and not startable then
        free_slot(cid)
      end
      local place_from = S.place_from[cid]
      if place_from ~= nil and w.near ~= nil then w.near[place_from] = nil end
      S.place_from[cid], S.route_cache[cid], S.route_fail[cid] = nil, nil, nil
      if w.rps ~= nil then w.rps[cid] = nil end
      if w.path_job ~= nil and w.path_job.cid == cid then w.path_job = nil end
      local routes = input_tbl and input_tbl.routes
      if type(routes) == "table" then
        for i = #routes, 1, -1 do
          if type(routes[i]) == "table" and routes[i].cid == cid then table.remove(routes, i) end
        end
        if #routes == 0 then input_tbl.routes = nil end
      end
    end
  end

  local function route_dense_array(value)
    if type(value) ~= "table" then return nil end
    local n, count = #value, 0
    for k in pairs(value) do
      if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
      count = count + 1
    end
    return count == n and value or nil
  end
  local function route_positive(value, maximum)
    return type(value) == "number" and math.type(value) == "integer"
      and value >= 1 and value <= maximum
  end
  local function route_key_valid(key)
    if type(key) ~= "string" or key:sub(1, 1) ~= "t" then return false end
    local sep = key:find(":", 2, true)
    if sep == nil then return false end
    local count_text = key:sub(2, sep - 1)
    local count = tonumber(count_text)
    if count == nil or count < 1 or count > 5 or count % 1 ~= 0
        or count_text ~= tostring(count) then return false end
    local tuple, at = {}, sep + 1
    for i = 1, count do
      local tag = key:sub(at, at)
      if tag == "i" then
        local stop = key:find(";", at + 1, true)
        if stop == nil then return false end
        local raw = key:sub(at + 1, stop - 1)
        local value = tonumber(raw)
        if value == nil or math.type(value) ~= "integer" or tostring(value) ~= raw then return false end
        tuple[i], at = value, stop + 1
      elseif tag == "s" then
        local colon = key:find(":", at + 1, true)
        if colon == nil then return false end
        local length_text = key:sub(at + 1, colon - 1)
        local length = tonumber(length_text)
        if length == nil or length < 0 or length % 1 ~= 0
            or length_text ~= tostring(length) then return false end
        local first, last = colon + 1, colon + length
        if last > #key then return false end
        tuple[i], at = key:sub(first, last), last + 1
      else
        return false
      end
    end
    return at == #key + 1 and core.target_key(tuple) == key
  end
  local function route_ids_valid(ids)
    ids = route_dense_array(ids)
    if ids == nil then return false end
    for _, id in ipairs(ids) do if not route_positive(id, 2147483647) then return false end end
    return true
  end
  local function route_ids_copy(ids)
    local out = {}
    for i, id in ipairs(ids or {}) do out[i] = id end
    return out
  end
  local function normalize_objective_publication(publication)
    local only_expected = true
    for k in pairs(publication) do
      if k ~= "objective_generation" and k ~= "members" then only_expected = false; break end
    end
    local generation = publication.objective_generation
    local raw_members = route_dense_array(publication.members)
    local normalized = {}
    local valid = only_expected and route_positive(generation, 2147483647) and raw_members ~= nil
    if not valid then return nil, generation, false end
    for _, e in ipairs(raw_members) do
      if type(e) ~= "table" or e.objective_generation ~= generation
          or not route_positive(e.qid, 2147483647) or not route_ids_valid(e.item_ids) then
        return nil, generation, false
      end
      for k in pairs(e) do
        if k ~= "route_id" and k ~= "cid" and k ~= "place" and k ~= "qid" and k ~= "kind"
            and k ~= "direct" and k ~= "target_key" and k ~= "ordinal" and k ~= "name"
            and k ~= "pos" and k ~= "item_ids" and k ~= "objective"
            and k ~= "objective_generation" then
          return nil, generation, false
        end
      end
      local ancillary = e.target_key == nil and e.ordinal == nil
      local m
      if e.direct == true then
        if ancillary or (e.objective ~= nil and e.objective ~= true)
            or not route_key_valid(e.target_key)
            or not route_positive(e.ordinal, 1099511627775)
            or core.objective_direct_route_id(e.ordinal) ~= e.route_id
            or e.cid ~= nil or e.place ~= 0 or not valid_pos(e.pos)
            or (e.kind ~= "place" and e.kind ~= "source") then
          return nil, generation, false
        end
        m = { cid = e.route_id, name = type(e.name) == "string" and e.name or "Objective",
          place = 0, direct = true, objective = true, qid = e.qid,
          kind = e.kind == "source" and "item" or e.kind,
          target_key = e.target_key, ordinal = e.ordinal,
          objective_generation = generation, pos = pcopy(e.pos), item_ids = route_ids_copy(e.item_ids) }
      elseif ancillary then
        if e.direct ~= false or e.kind ~= "npc" or not route_positive(e.cid, 4294967295)
            or e.route_id ~= e.cid or e.place ~= nil or #e.item_ids ~= 0
            or (e.objective ~= nil and type(e.objective) ~= "boolean")
            or (e.objective == true and not valid_pos(e.pos))
            or (e.pos ~= nil and not valid_pos(e.pos)) then
          return nil, generation, false
        end
        local name = e.name
        if type(name) ~= "string" then
          local ok_name, value = pcall(a.npc_name, e.cid)
          name = ok_name and type(value) == "string" and value or ("NPC " .. tostring(e.cid))
        end
        m = { cid = e.cid, name = name, objective = e.objective == true,
          qid = e.qid, kind = "npc", pos = valid_pos(e.pos) and pcopy(e.pos) or nil,
          objective_generation = generation, item_ids = {} }
      else
        if e.direct ~= false or (e.objective ~= nil and e.objective ~= true)
            or not route_key_valid(e.target_key)
            or not route_positive(e.ordinal, 1099511627775) or e.kind ~= "npc"
            or not route_positive(e.cid, 4294967295) or e.route_id ~= e.cid or e.place ~= e.cid
            or not valid_pos(e.pos) then
          return nil, generation, false
        end
        local name = e.name
        if type(name) ~= "string" then
          local ok_name, value = pcall(a.npc_name, e.cid)
          name = ok_name and type(value) == "string" and value or ("NPC " .. tostring(e.cid))
        end
        m = { cid = e.cid, name = name, objective = true,
          qid = e.qid, kind = "npc", target_key = e.target_key, ordinal = e.ordinal,
          objective_generation = generation, item_ids = route_ids_copy(e.item_ids), pos = pcopy(e.pos) }
      end
      normalized[#normalized + 1] = m
    end
    return normalized, generation, true
  end

  local objective_member_scalars = { "route_id", "cid", "place", "qid", "kind", "direct",
    "target_key", "ordinal", "name", "objective", "objective_generation" }
  local function same_objective_publication(publication)
    if S.objective_publication == nil or publication.objective_generation ~= S.objective_generation then
      return false
    end
    for k in pairs(publication) do
      if k ~= "objective_generation" and k ~= "members" then return false end
    end
    local members, previous = route_dense_array(publication.members), S.objective_publication.members
    if members == nil or #members ~= #previous then return false end
    for i, member in ipairs(members) do
      local old = previous[i]
      if type(member) ~= "table" or type(old) ~= "table" then return false end
      for k in pairs(member) do
        if k ~= "route_id" and k ~= "cid" and k ~= "place" and k ~= "qid" and k ~= "kind"
            and k ~= "direct" and k ~= "target_key" and k ~= "ordinal" and k ~= "name"
            and k ~= "pos" and k ~= "item_ids" and k ~= "objective"
            and k ~= "objective_generation" then return false end
      end
      for k in pairs(old) do if rawget(member, k) == nil then return false end end
      for _, key in ipairs(objective_member_scalars) do
        if member[key] ~= old[key] then return false end
      end
      local pos, old_pos = member.pos, old.pos
      if type(pos) ~= type(old_pos) then return false end
      if pos ~= nil then
        if type(pos) ~= "table" or type(old_pos) ~= "table"
            or pos.x ~= old_pos.x or pos.y ~= old_pos.y or pos.z ~= old_pos.z then return false end
        for k in pairs(pos) do if k ~= "x" and k ~= "y" and k ~= "z" then return false end end
        for k in pairs(old_pos) do if rawget(pos, k) == nil then return false end end
      end
      local ids, old_ids = route_dense_array(member.item_ids), old.item_ids
      if ids == nil or #ids ~= #old_ids then return false end
      for j, id in ipairs(ids) do if id ~= old_ids[j] then return false end end
    end
    return true
  end
  local function legacy_publication_array(publication)
    local list = route_dense_array(publication)
    if list == nil then return nil end
    for _, e in ipairs(list) do
      if type(e) ~= "table" or e.objective == true or e.objective_generation ~= nil
          or e.target_key ~= nil or e.ordinal ~= nil or e.direct ~= nil or e.route_id ~= nil then
        return nil
      end
      if type(e.cid) ~= "number" or math.type(e.cid) ~= "integer" or e.cid == 0
          or (e.place ~= nil and (not route_positive(e.place, 2147483647) or e.cid ~= -e.place))
          or (e.name ~= nil and type(e.name) ~= "string") then return nil end
      for k in pairs(e) do
        if k ~= "cid" and k ~= "name" and k ~= "place" then return nil end
      end
    end
    return list
  end

  -- Exact objective publications use a generation-bearing envelope. Bare
  -- lists remain only for the staged legacy caller and reject any objective
  -- shape before that compatibility path can observe it.
  function w:set_routes(publication)
    local is_envelope = type(publication) == "table"
      and (rawget(publication, "members") ~= nil or rawget(publication, "objective_generation") ~= nil)
    local generation, list = nil, publication
    if is_envelope then
      if same_objective_publication(publication) then return end
      local normalized, valid_generation, valid = normalize_objective_publication(publication)
      generation = valid_generation
      if not valid then
        local had = #S.members > 0 or S.objective_generation ~= nil
        clear_members_now()
        S.objective_generation = nil
        S.objective_publication = nil
        if had then w.route_gen = w.route_gen + 1 end
        last_round = nil
        return
      end
      list = normalized
      S.objective_publication = objective_clone(publication)
    elseif type(publication) == "table" then
      local legacy = legacy_publication_array(publication)
      if legacy == nil then
        local had = #S.members > 0 or S.objective_generation ~= nil
        clear_members_now()
        S.objective_generation, S.objective_publication = nil, nil
        if had then w.route_gen = w.route_gen + 1 end
        last_round = nil
        return
      end
      list = legacy
      S.objective_generation, S.objective_publication = nil, nil
    else
      local had = #S.members > 0 or S.objective_generation ~= nil
      clear_members_now()
      S.objective_generation, S.objective_publication = nil, nil
      if had then w.route_gen = w.route_gen + 1 end
      last_round = nil
      return
    end

    if is_envelope and S.objective_generation ~= generation then
      clear_members_now(list)
      S.objective_generation = generation
      last_round = nil
      w.route_gen = w.route_gen + 1
    end
    -- the same list as the current members: nothing to rebuild
    -- the same list as the current members: nothing to rebuild
    if type(list) == "table" and #list == #S.members then
      local same = true
      for i, e in ipairs(list) do
        local m = S.members[i]
        local any_direct = type(e) == "table" and (e.direct == true or m.direct == true)
        if type(e) ~= "table" or e.cid ~= m.cid or e.place ~= m.place
            or (any_direct and not same_direct_payload(e, m))
            or (not any_direct and (e.name ~= m.name
              or e.objective ~= m.objective or e.qid ~= m.qid or e.kind ~= m.kind
              or e.target_key ~= m.target_key or e.ordinal ~= m.ordinal
              or e.objective_generation ~= m.objective_generation
              or (e.pos == nil) ~= (m.pos == nil)
              or (e.pos ~= nil and (not valid_pos(e.pos) or not valid_pos(m.pos)
                or e.pos.x ~= m.pos.x or e.pos.y ~= m.pos.y or e.pos.z ~= m.pos.z)))) then
          same = false
          break
        end
      end
      if same then return end
    end
    local before = {}
    for cid in pairs(S.member_of) do before[cid] = true end
    local t = S.target_member
    if t ~= nil then before[t.cid] = true end
    local members, member_of = {}, {}
    if type(list) == "table" then
      for _, e in ipairs(list) do
        local is_direct = type(e) == "table" and e.direct == true and direct_member(e)
        if type(e) == "table" and type(e.cid) == "number" and member_of[e.cid] == nil
            and (is_direct or (e.direct ~= true and (e.place == nil
              or (type(e.place) == "number" and e.place > 0 and e.place % 1 == 0
                and e.cid == -e.place)))) then
          local m = { cid = e.cid, name = e.name, place = e.place }
          if is_direct then
            m.direct, m.objective, m.qid, m.kind = true, e.objective, e.qid, e.kind
            m.target_key, m.ordinal = e.target_key, e.ordinal
            m.objective_generation = e.objective_generation
            m.pos = pcopy(e.pos)
          elseif is_envelope then
            m.objective, m.qid, m.kind = e.objective, e.qid, e.kind
            m.target_key, m.ordinal = e.target_key, e.ordinal
            m.objective_generation = e.objective_generation
            m.item_ids, m.pos = e.item_ids, e.pos
          end
          members[#members + 1] = m
          member_of[e.cid] = m
        end
      end
    end
    local was_member = S.member_of
    S.members, S.member_of = members, member_of
    local changed = false
    for cid in pairs(member_of) do
      if not before[cid] then changed = true end
    end
    for cid in pairs(was_member) do
      if member_of[cid] == nil then
        if not (t ~= nil and t.cid == cid) then changed = true end
        leave(cid)
      end
    end
    for _, m in ipairs(members) do
      local old = was_member[m.cid]
      if old ~= nil and m.direct and old.direct
          and not same_direct_payload(m, old) then
        changed = true
        S.route_cache[m.cid], S.route_fail[m.cid] = nil, nil
        if w.path_job ~= nil and w.path_job.cid == m.cid then w.path_job = nil end
        if w.rps ~= nil then w.rps[m.cid] = nil end
      end
    end
    if changed then
      last_round = nil
      w.route_gen = w.route_gen + 1
    end
  end

  function w:clear_route()
    local old = S.target_member and S.target_member.cid
    S.target_member = nil
    w.route_gen = w.route_gen + 1
    leave(old)
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
    for id, e in pairs(S.file_givers) do
      local cur = ids[id]
      if cur == nil or e.uid < cur then
        ids[id] = e.uid
        out[id] = { x = e.x, y = e.y, z = e.z }
      end
    end
    for id, e in pairs(S.live_givers) do
      out[id] = { x = e.x, y = e.y, z = e.z }
    end
    givers_cache, givers_rev = out, rev
    return out
  end

  function w:places_state()
    return { state = places.state, stale = unlisted > M.K.UNLISTED_STALE }
  end

  -- Shared with adapter-owned live joins; the generated artifact was parsed
  -- during construction and this immutable snapshot is never reloaded.
  function w:objective_static_source_catalog()
    return objective_catalog
  end

  function w:reset()
    S = new_session()
    givers_cache, givers_rev = nil, -1
    w.path_job = nil
    if type(reads.reset) == "function" then pcall(reads.reset) end
    gate_round = { quests = {}, variables = {}, season_read = false, season = nil }
    gate_stats = { season4 = nil, normal = { eligible = 0, total = 0 },
      quest = { eligible = 0, total = 0 }, read_failures = { season4 = 0, quest = 0, variable = 0 } }
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
    local conditional_learned = 0
    for uid in pairs(learned) do if conditional_uids[uid] then conditional_learned = conditional_learned + 1 end end
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
      reserved_reused = stats.reserved_reused, reserved_reads = stats.reserved_reads,
      rounds = stats.rounds, saves = stats.saves, save_ms = stats.save_ms,
      eff_builds = stats.eff_builds, item_list_builds = stats.item_list_builds,
      held_rounds = stats.held_rounds, route_builds = stats.route_builds,
      shop_index_runs = stats.shop_index_runs, chest_kinds_calls = stats.chest_kinds_calls,
      last_save_reason = stats.last_save_reason,
      gates = { season4 = gate_stats.season4,
        normal_source = { eligible = gate_stats.normal.eligible, total = gate_stats.normal.total },
        quest_source = { eligible = gate_stats.quest.eligible, total = gate_stats.quest.total },
        read_failures = { season4 = gate_stats.read_failures.season4,
          quest = gate_stats.read_failures.quest, variable = gate_stats.read_failures.variable },
        conditional_learned = conditional_learned },
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
  w.rps = {}                   -- cid -> cached route pairs, keys and drawn list
  local rp_empty = {}
  local rp_out, rp_out_key = nil, nil  -- the cached route_paths outer table

  -- the published entry for the cid when it has a route with stops, else nil
  local function entry_of(cid)
    local l = input_tbl and input_tbl.routes
    if cid == nil or type(l) ~= "table" then return nil end
    for _, r in ipairs(l) do
      if r.cid == cid then
        if has_stops(r) then return r end
        return nil
      end
    end
    return nil
  end

  -- whether any published entry has stops
  local function any_route()
    return routes_on(input_tbl)
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

  local function same_route(c, cid, stops, undisc)
    if c.undisc ~= undisc or c.cid ~= cid or c.n ~= #stops then return false end
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

  local function build_rp(cid, stops, undisc)
    local npcs = require("Clairvoyance.npcs")
    local c = { cid = cid, undisc = undisc, n = #stops,
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

  local function rp_get(cid, stops, undisc)
    local c = w.rps[cid]
    if c == nil or not same_route(c, cid, stops, undisc) then
      c = build_rp(cid, stops, undisc)
      w.rps[cid] = c
    end
    return c
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
      for cid, rp in pairs(w.rps) do
        if live(cid) then
          for _, pr in ipairs(rp.pairs) do
            local a, b = w.near[rp.keys[pr[1]]], w.near[rp.keys[pr[2]]]
            if a and b then keep[a * 1048576 + b] = true end
          end
        end
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

  local function search_slice(budget_ms, undisc)
    local npcs = require("Clairvoyance.npcs")
    local c, stops, kind, k, a, b
    for _, r in ipairs(input_tbl and input_tbl.routes or rp_empty) do
      if has_stops(r) then
        local rc = rp_get(r.cid, r.stops, undisc)
        local kd, kk, ka, kb = next_target(rc)
        if kd ~= nil then
          c, stops, kind, k, a, b = rc, r.stops, kd, kk, ka, kb
          break
        end
      end
    end
    if kind == nil then w.path_job = nil; return end
    local t0 = clock()
    local j = w.path_job
    if j ~= nil then j.cid = c.cid end  -- a reused job serves this cid now
    if kind == "near" then
      if j == nil or j.kind ~= "near" or j.key ~= k then
        local p = stops[a].pos
        j = { kind = "near", key = k, cid = c.cid, job = npcs.nearest_new(w.graph, p.x, p.y, p.z) }
        w.path_job = j
      end
      if npcs.nearest_step(j.job, budget_ms, clock) == "done" then
        w.near[k] = j.job.best or false
        w.path_job = nil
      end
    else
      if j == nil or j.kind ~= "path" or j.pk ~= k then
        j = { kind = "path", pk = k, cid = c.cid, job = npcs.path_new(w.graph, a, b) }
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
    local on = any_route()
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
      search_slice(budget_ms, undisc)
    end
  end

  function w:path_busy() return w.copy ~= nil end

  function w:path_status(route_path, cid)
    local e = entry_of(cid)
    if route_path ~= 1 or e == nil then return nil end
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
    local rp = w.rps[cid]
    if rp == nil or not same_route(rp, cid, e.stops, rp.undisc) or next_target(rp) ~= nil then
      return "path: finding"
    end
    return "path ready"
  end

  -- per pair { i, j, pts }: pts a flat x, y, z list (map space), nil while
  -- not found. Rebuilt only when the route, undisc or w.paths changes.
  local route_list
  function w:route_paths(undisc)
    undisc = undisc and true or false
    if not any_route() then return rp_empty end
    local k = rp_out_key
    if rp_out ~= nil and k.tbl == input_tbl and k.undisc == undisc and k.pver == w.pver
      and k.gen == w.route_gen then
      return rp_out
    end
    local out = {}
    for _, r in ipairs(input_tbl.routes) do
      if has_stops(r) and out[r.cid] == nil then
        out[r.cid] = route_list(rp_get(r.cid, r.stops, undisc))
      end
    end
    rp_out = out
    rp_out_key = { tbl = input_tbl, undisc = undisc, pver = w.pver, gen = w.route_gen }
    return out
  end

  -- the drawn list of one cached route, rebuilt when w.paths changed
  route_list = function(c)
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
  local variable_objects, quest_log_end_method = {}, nil
  local variable_info_type, variable_condition_type = nil, nil

  function R.game_season4()
    local gs = single("app.GameSystem")
    local value = C(gs, "get_GameSeason4")
    if type(value) == "boolean" then return value end
    local field = G(gs, "<GameSeason4>k__BackingField")
    if type(field) == "boolean" then return field end
    error("GameSeason4 unreadable")
  end

  function R.quest_state(qid)
    local qm = single("app.QuestManager")
    local qlm = single("app.QuestLogManager")
    local active = C(qm, "checkActivated", qid)
    if type(active) ~= "boolean" then error("quest activation unreadable") end
    if quest_log_end_method == nil then
      local ok, method = pcall(function()
        local td = sdk.find_type_definition("app.QuestLogManager")
        return td ~= nil and td:get_method("isQuestLogEnd(app.QuestDefine.ID)") or nil
      end)
      if ok then quest_log_end_method = method end
    end
    if qlm == nil or quest_log_end_method == nil then error("quest log end method unavailable") end
    local ok, ended = pcall(function() return quest_log_end_method:call(qlm, qid) end)
    if not ok or type(ended) ~= "boolean" then error("quest end state unreadable") end
    return { active = active, ended = ended }
  end

  function R.quest_variable(c)
    local key = table.concat({ c.qid, c.name_hash, c.value_type, c.compare_type,
      c.bool_value and 1 or 0, c.int_value }, ":")
    local wrapper = variable_objects[key]
    if wrapper == nil then
      local condition, info, condition_ref, info_ref
      local ok, result = pcall(function()
        variable_info_type = variable_info_type or sdk.find_type_definition(
          "app.GenerateManager.QuestFlagInfos.QuestVariableInfo")
        variable_condition_type = variable_condition_type or sdk.find_type_definition(
          "app.QuestVariableCondition")
        if variable_info_type == nil or variable_condition_type == nil then error("condition type missing") end
        condition = variable_condition_type:create_instance()
        if condition == nil then error("condition construction failed") end
        local condition_added = condition:add_ref()
        condition_ref = true
        if condition_added == nil then error("condition retention failed") end
        condition = condition_added
        info = variable_info_type:create_instance()
        if info == nil then error("variable info construction failed") end
        local info_added = info:add_ref()
        info_ref = true
        if info_added == nil then error("variable info retention failed") end
        info = info_added
        condition:set_field("_QuestID", c.qid)
        condition:set_field("_NameHash", c.name_hash)
        condition:set_field("_ValueType", c.value_type)
        condition:set_field("_CompareType", c.compare_type)
        condition:set_field("_BoolValue", c.bool_value)
        condition:set_field("_IntValue", c.int_value)
        info:set_field("_Condition", condition)
        return { info = info, condition = condition }
      end)
      if not ok or result == nil then
        if info_ref and info ~= nil then pcall(function() info:release() end) end
        if condition_ref and condition ~= nil then pcall(function() condition:release() end) end
        error("variable condition construction failed")
      end
      variable_objects[key] = result
      wrapper = result
    end
    local qm = single("app.QuestManager")
    local value = C(wrapper.info, "evaluate", qm)
    if type(value) ~= "boolean" then error("variable evaluation failed") end
    return value
  end

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

  local function addr_of(x) return x:get_address() end

  -- One selector's signature inputs, read with plain calls under one pcall
  -- (the caller): the table address, with each spec's row count left in
  -- counts (-1 for a missing array or an unreadable count). nil for no Table.
  local function read_selector_sig(sel, counts)
    local tbl = sel:get_field("<Table>k__BackingField")
    if tbl == nil then return nil end
    local addr = math.tointeger(addr_of(tbl))
    if addr == nil then error("table address unreadable") end
    for i, spec in ipairs(RESERVED_SPECS) do
      local info = tbl:get_field(spec[1])
      local arr = info ~= nil and info:get_field("_BasicRowDatas") or nil
      local n = arr ~= nil and arr:call("get_Count") or nil
      counts[i] = type(n) == "number" and n or -1
    end
    return addr
  end

  -- The same reads, each guarded on its own: used only for a selector whose
  -- fast read raised, so a raising read gives nil (no Table) or -1 (count).
  local function read_selector_sig_guarded(sel, counts)
    local tbl = G(sel, "<Table>k__BackingField")
    if tbl == nil then return nil end
    local ok, a = pcall(addr_of, tbl)
    local addr = ok and math.tointeger(a) or nil
    if addr == nil then error("table address unreadable") end
    for i, spec in ipairs(RESERVED_SPECS) do
      local n = C(G(G(tbl, spec[1]), "_BasicRowDatas"), "get_Count")
      counts[i] = type(n) == "number" and n or -1
    end
    return addr
  end

  local sig_counts = {}

  local function sig_selector(sel, _, parts)
    local ok, addr = pcall(read_selector_sig, sel, sig_counts)
    if not ok then addr = read_selector_sig_guarded(sel, sig_counts) end
    if addr == nil then
      parts[#parts + 1] = "0"
      return
    end
    local s = string.format("%x", addr)
    for i = 1, #RESERVED_SPECS do
      s = s .. string.format(":%d", sig_counts[i])
    end
    parts[#parts + 1] = s
  end

  -- Cheap change signal for the reserved selector list (SPEC 31.3.1): the
  -- selector count, then per selector 0 or address:count per spec.
  function R.reserved_sig()
    local parts = {}
    local gm = single("app.GenerateManager")
    local ok = each(G(G(gm, "_ReserveManager"), "_ReservedGenerateSelector"),
      sig_selector, parts)
    if not ok then error("reserved selectors unreadable") end
    table.insert(parts, 1, #parts)
    return table.concat(parts, ",")
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

  -- The uid of the first Seeker's Token's gimmick (SPEC 28.9.1); nil on any
  -- failure, never a raise (the world round just publishes no marker).
  function R.first_seeker()
    local gm = single("app.GimmickManager")
    if C(gm, "isExistFirstSeekerProof") ~= true then return nil end
    return guid_text(G(G(gm, "<FirstSeekerProof>k__BackingField"), "_RowID"))
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
    for _, pair in pairs(variable_objects) do
      for _, obj in pairs(pair) do
        if obj ~= nil then pcall(function() obj:release() end) end
      end
    end
    variable_objects = {}
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
