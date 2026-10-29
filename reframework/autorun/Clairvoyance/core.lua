-- core.lua — pure logic; no sdk/re/imgui/json. Tested by tests/core_test.lua.
local M = {}

M.HYSTERESIS_UNITS = 5.0

-- Share one overhead-state read across drawing layers within a game frame.
function M.overhead_block(cache, frame, enabled, reader)
  if not enabled then
    cache.frame, cache.reason = frame, nil
    return nil
  end
  if cache.frame ~= frame then
    cache.frame, cache.reason = frame, reader()
  end
  return cache.reason
end

local function dist(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end
M.dist = dist

-- Quest display name; second result is true when the "Quest <id>"
-- placeholder stood in for a missing or empty name.
local function quest_display_name(adapter, qid)
  local name = adapter.quest_name(qid)
  if name == nil or name == "" then return "Quest " .. qid, true end
  return name, false
end
M.quest_display_name = quest_display_name

local MERGE_STOP_M = 150 -- stops this close (metres) merge into one
M.MERGE_STOP_M = MERGE_STOP_M
local ROUTE_CAP = 8 -- most published routes (the target counts)

local function pos_key(p)
  return string.format("p:%d:%d:%d",
    math.floor(p.x), math.floor(p.y), math.floor(p.z))
end

local STATE_TEXT = {
  startable = "startable", in_progress = "in progress",
  completed = "completed", failed = "failed", canceled = "canceled",
  giver_dead = "giver dead", locked = "locked",
}
local VALID_STATE = { completed = true, failed = true, canceled = true }
-- category -> color/show group
local GROUP = {
  startable = "startable", in_progress = "in_progress",
  completed = "completed", failed = "unavailable", canceled = "unavailable",
  giver_dead = "unavailable", locked = "locked",
}
-- marker color precedence (lower wins), SPEC §9.5
local PRECEDENCE = { startable = 1, in_progress = 2, completed = 3,
  unavailable = 4, locked = 5 }

-- Pure builder for the gate table (SPEC 13.3b). records = {{qid, ref}, ...}.
-- Defensive drops: non-number, <= 0, ref == qid. Refs deduped and ascending;
-- a qid with no surviving ref is absent, never an empty array.
function M.gate_table(records)
  local sets, out = {}, {}
  for _, r in ipairs(records or {}) do
    local qid, ref = r.qid, r.ref
    if type(qid) == "number" and type(ref) == "number"
      and ref > 0 and ref ~= qid then
      local s = sets[qid]
      if s == nil then s = {}; sets[qid] = s end
      s[ref] = true
    end
  end
  for qid, s in pairs(sets) do
    local arr = {}
    for ref in pairs(s) do arr[#arr + 1] = ref end
    table.sort(arr)
    out[qid] = arr
  end
  return out
end

-- v8 (SPEC 15.3e): pure builder for the quest-item need table.
-- records = {{qid, id, num, op}, ...} with op "more" | "morethan" |
-- "other"; held = {[id] = count} (absent = 0). Admits "more" with
-- num >= 1 (required = num) and "morethan" with num >= 0 (required =
-- num + 1); every other record is rejected and counted. Dedupe per
-- (qid, id) keeps the max required; a need with held >= required is
-- satisfied and dropped. Returns {[qid] = {{id, num = required}, ...}}
-- (ids ascending; a qid with no surviving need is absent, never an
-- empty array) and the rejected-record count.
function M.item_need_table(records, held)
  held = held or {}
  local best, ignored = {}, 0
  for _, r in ipairs(records or {}) do
    local req = nil
    if type(r) == "table" and type(r.qid) == "number"
      and type(r.id) == "number" and type(r.num) == "number" then
      if r.op == "more" and r.num >= 1 then
        req = r.num
      elseif r.op == "morethan" and r.num >= 0 then
        req = r.num + 1
      end
    end
    if req == nil then
      ignored = ignored + 1
    else
      local q = best[r.qid]
      if q == nil then q = {}; best[r.qid] = q end
      if q[r.id] == nil or req > q[r.id] then q[r.id] = req end
    end
  end
  local out = {}
  for qid, q in pairs(best) do
    local arr = {}
    for id, req in pairs(q) do
      if (held[id] or 0) < req then arr[#arr + 1] = { id = id, num = req } end
    end
    if #arr > 0 then
      table.sort(arr, function(x, y) return x.id < y.id end)
      out[qid] = arr
    end
  end
  return out, ignored
end

-- SPEC 13.3d, 27.4.2: the name a gate shows for one quest: the full name only
-- with `reveal`, else the seen name, else "another quest"; never an id.
function M.gate_name(qid, adapter, reveal)
  local nm
  if reveal then nm = adapter.quest_name(qid) end
  if (nm == nil or nm == "") and adapter.seen_quest_name then
    nm = adapter.seen_quest_name(qid)
  end
  if nm == nil or nm == "" then nm = "another quest" end
  return nm
end

local function gate_suffix(refs, adapter, show)
  local names, seen = {}, {}
  for _, ref in ipairs(refs) do
    local nm = M.gate_name(ref, adapter, show and show.reveal_gate_names)
    if not seen[nm] then
      seen[nm] = true
      names[#names + 1] = nm
    end
  end
  local joined = names[1]
  if #names >= 2 then joined = joined .. ", " .. names[2] end
  if #names > 2 then joined = joined .. ", ..." end
  return " (waiting on: " .. joined .. ")"
end

-- Returns label, hover. hover is nil when identical to label.
local function label_for(qids, cats, adapter, unnamed, show)
  local parts, hparts = {}, {}
  for i, qid in ipairs(qids) do
    local name, fallback = quest_display_name(adapter, qid)
    if fallback then unnamed[qid] = true end
    local part = name .. " - " .. STATE_TEXT[cats[i]]
    parts[#parts + 1] = part
    local hpart = part
    if cats[i] == "startable" and adapter.gate_qids then
      local refs = adapter.gate_qids(qid)
      if type(refs) == "table" and #refs > 0 then
        hpart = part .. gate_suffix(refs, adapter, show)
      end
    end
    hparts[#hparts + 1] = hpart
  end
  local joined = table.concat(parts, " / ")
  local hjoined = table.concat(hparts, " / ")
  return joined, (hjoined ~= joined) and hjoined or nil
end

-- v8 (SPEC 15.3h): item markers. shown_inprog = qids this compute
-- assigned in_progress that survived the visibility drop, so a need never
-- comes from a hidden, locked, terminal or non-progressing quest even if
-- the adapter's committed need table still holds it. Returns the markers
-- (sorted by item_id then key, capped, item_ord set) and the excess count.
M.ITEM_MARKER_MAX = 32
local SRC_RANK = { placed = 1, box = 2, drop = 3 }

local function item_key(id, pos)
  return string.format("i:%d:%d:%d", id,
    math.floor(pos.x / 4), math.floor(pos.z / 4))
end

-- Item id -> list of the quests that need it (each once, unsorted), from
-- a.item_needs(). `keep_qid` (optional set) limits which quests count.
function M.needs_by_item(needs, keep_qid)
  local by_id = {}
  for qid, list in pairs(needs) do
    if (keep_qid == nil or keep_qid[qid]) and type(list) == "table" then
      for _, nd in ipairs(list) do
        if type(nd) == "table" and type(nd.id) == "number" then
          local qs = by_id[nd.id]
          if qs == nil then qs = {}; by_id[nd.id] = qs end
          local dup = false
          for _, q in ipairs(qs) do if q == qid then dup = true end end
          if not dup then qs[#qs + 1] = qid end
        end
      end
    end
  end
  return by_id
end

-- v11 (SPEC 19.5): map search. A query is { terms = { ... } } (nil = no
-- search); a haystack is lower-cased parts joined by a newline.
local function parse_uncached(text)
  local terms, seen = {}, {}
  local function add(t)
    if not seen[t] then seen[t] = true; terms[#terms + 1] = t end
  end
  for part in (text:lower() .. ","):gmatch("([^,]*),") do
    local t = part:match("^%s*(.-)%s*$")
    if t ~= "" then
      add(t)
      if #t > 3 and t:sub(-1) == "s" then add(t:sub(1, -2)) end
    end
  end
  if #terms == 0 then return nil end
  return { terms = terms, key = table.concat(terms, ",") }
end

local query_memo = {}   -- one entry: the same text returns the same query table
function M.parse_query(text)
  if type(text) ~= "string" then return nil end
  if query_memo.text == text then return query_memo.query end
  local q = parse_uncached(text)
  query_memo.text, query_memo.query = text, q
  return q
end

function M.query_match(q, h)
  if q == nil then return true end
  if type(h) ~= "string" then return false end
  for _, t in ipairs(q.terms) do
    if string.find(h, t, 1, true) then return true end
  end
  return false
end
local query_match = M.query_match

-- The world builders' match, counted for the tests (M.world_stats is created
-- further down; the field is read at call time).
local function wmatch(q, h)
  local st = M.world_stats
  st.query_calls = st.query_calls + 1
  return query_match(q, h)
end

local function hay_join(parts)
  for i, p in ipairs(parts) do parts[i] = tostring(p) end
  return table.concat(parts, "\n"):lower()
end

-- Quest-marker haystacks (SPEC 19.6.1), keyed by label, hover and cid;
-- emptied once it passes QUEST_HAY_MAX entries.
local QUEST_HAY_MAX = 2048
local quest_hay_cache = {}
M.search_stats = { quest_hay_n = 0 }

local function quest_hay(adapter, g)
  local cid = M.marker_cid(g)
  if cid == nil and g.qids[1] ~= nil then cid = adapter.giver_hint(g.qids[1]) end
  local key = g.label .. "\0" .. (g.hover or "") .. "\0" .. tostring(cid)
  local h = quest_hay_cache[key]
  if h == nil then
    local st = M.search_stats
    if st.quest_hay_n >= QUEST_HAY_MAX then
      quest_hay_cache = {}
      st.quest_hay_n = 0
    end
    local nm
    if type(cid) == "number" and adapter.npc_name then nm = adapter.npc_name(cid) end
    h = hay_join({ g.label, g.hover or "", nm or "" })
    if not (type(cid) == "number" and nm == nil) then
      quest_hay_cache[key] = h
      st.quest_hay_n = st.quest_hay_n + 1
    end
  end
  return h
end

-- v19 (SPEC 32): `focus_inprog` (set or nil) marks the focused in-progress
-- quests. An entry whose item such a quest needs skips the query and the cap
-- and shares the one item_ord sequence with the rest.
function M.item_markers(adapter, shown_inprog, origin, q, focus_inprog)
  local needs
  if adapter.item_needs then
    M.world_stats.item_need_reads = M.world_stats.item_need_reads + 1
    needs = adapter.item_needs()
  end
  if type(needs) ~= "table" then return {}, 0 end
  local keep_qids = shown_inprog
  if type(focus_inprog) == "table" and next(focus_inprog) ~= nil then
    keep_qids = {}
    for qid, on in pairs(shown_inprog) do if on then keep_qids[qid] = true end end
    for qid, on in pairs(focus_inprog) do if on then keep_qids[qid] = true end end
  end
  local by_id = M.needs_by_item(needs, keep_qids)   -- item id -> needing shown quests
  if next(by_id) == nil then return {}, 0 end
  local focus_item = {}   -- item id -> a focused quest needs it
  for id, qs in pairs(by_id) do
    table.sort(qs)
    if type(focus_inprog) == "table" then
      for _, qid in ipairs(qs) do
        if focus_inprog[qid] then focus_item[id] = true end
      end
    end
  end

  local recs = {}
  local locs = adapter.item_locations and adapter.item_locations() or nil
  for _, r in ipairs(locs or {}) do
    if type(r) == "table" and type(r.id) == "number" and by_id[r.id] ~= nil
      and type(r.pos) == "table" then
      recs[#recs + 1] = { key = item_key(r.id, r.pos),
        rank = SRC_RANK[r.src] or 4, r = r }
    end
  end
  table.sort(recs, function(x, y)
    if x.key ~= y.key then return x.key < y.key end
    if x.rank ~= y.rank then return x.rank < y.rank end
    local p, q = x.r.pos, y.r.pos
    if p.x ~= q.x then return p.x < q.x end
    if p.y ~= q.y then return p.y < q.y end
    return p.z < q.z
  end)

  -- One lightweight entry per key (the first record supplies pos/live);
  -- pos/live/qids/label are built only for the entries that survive the cap.
  local entries, last = {}, nil
  for _, e in ipairs(recs) do
    if e.key ~= last then
      last = e.key
      entries[#entries + 1] = { key = e.key, item_id = e.r.id, r = e.r }
    end
  end
  local function by_id_key(x, y)
    if x.item_id ~= y.item_id then return x.item_id < y.item_id end
    return x.key < y.key
  end
  local item_labels, quest_names, item_inames = {}, {}, {}
  local function qname(qid)
    local nm = quest_names[qid]
    if nm == nil then
      nm = quest_display_name(adapter, qid)
      quest_names[qid] = nm
    end
    return nm
  end
  local function iname(id)
    local inm = item_inames[id]
    if inm == nil then
      if adapter.item_name then inm = adapter.item_name(id) end
      if inm == nil or inm == "" then inm = "Item " .. id end
      item_inames[id] = inm
    end
    return inm
  end
  -- SPEC 19.8.2: non-matching entries leave before the cap, so
  -- `capped` counts matches only.
  if q ~= nil then
    local ok, matched = {}, {}
    for _, e in ipairs(entries) do
      local m = ok[e.item_id]
      if m == nil then
        local parts = { iname(e.item_id) }
        for _, qid in ipairs(by_id[e.item_id]) do parts[#parts + 1] = qname(qid) end
        m = query_match(q, hay_join(parts))
        ok[e.item_id] = m
      end
      if m then
        matched[#matched + 1] = e
      elseif focus_item[e.item_id] then
        e.focus_kept = true
        matched[#matched + 1] = e
      end
    end
    entries = matched
  end
  -- Related needs are held out of the cap and put back after it.
  local held = {}
  if next(focus_item) ~= nil then
    local rest = {}
    for _, e in ipairs(entries) do
      if focus_item[e.item_id] then held[#held + 1] = e else rest[#rest + 1] = e end
    end
    entries = rest
  end
  local capped = 0
  if #entries > M.ITEM_MARKER_MAX then
    -- SPEC 15.7i: within each item id the nearest copies survive the
    -- cap; (item_id, key) order is the tie-break. Without a usable
    -- origin every distance is 0, which is exactly (item_id, key) order.
    local has_origin = type(origin) == "table" and type(origin.x) == "number"
      and type(origin.y) == "number" and type(origin.z) == "number"
    for _, e in ipairs(entries) do
      e.d = 0
      if has_origin then    -- squared: no sqrt rounding ties
        local p = e.r.pos
        local dx, dy, dz = p.x - origin.x, p.y - origin.y, p.z - origin.z
        e.d = dx * dx + dy * dy + dz * dz
      end
    end
    table.sort(entries, function(x, y)
      if x.item_id ~= y.item_id then return x.item_id < y.item_id end
      if x.d ~= y.d then return x.d < y.d end
      return x.key < y.key
    end)
    capped = #entries - M.ITEM_MARKER_MAX
    for i = #entries, M.ITEM_MARKER_MAX + 1, -1 do entries[i] = nil end
  end
  for _, e in ipairs(held) do entries[#entries + 1] = e end
  -- Kept set back in (item_id, key) order so item_ord (marker identity)
  -- does not shuffle as the origin moves.
  table.sort(entries, by_id_key)

  local markers, ord = {}, {}
  for _, e in ipairs(entries) do
    local r = e.r
    local id = e.item_id
    local label = item_labels[id]
    local qs = {}
    if label == nil then
      local inm = iname(id)
      local parts = {}
      for i, q in ipairs(by_id[id]) do
        qs[i] = q
        parts[i] = qname(q)
      end
      label = inm .. " (for " .. table.concat(parts, " / ") .. ")"
      item_labels[id] = label
    else
      for i, q in ipairs(by_id[id]) do qs[i] = q end
    end
    local lv = r.live
    local o = ord[id] or 0
    ord[id] = o + 1
    markers[#markers + 1] = {
      key = e.key,
      pos = { x = r.pos.x, y = r.pos.y, z = r.pos.z },
      live = type(lv) == "table" and { x = lv.x, y = lv.y, z = lv.z } or nil,
      qids = qs, item_id = id, cat = "quest_item",
      label = label, item_ord = o, focus_kept = e.focus_kept,
    }
  end
  return markers, capped
end

-- v10 (SPEC 17.4): world markers. Categories in output order; WORLD_DEF.toggle
-- names the show field that switches each one and WORLD_DEF.src the world
-- table list that feeds it (shop and npc_search have none: they are fed by
-- their own candidate builders).
M.WORLD_CATS = { "treasure", "token", "beetle", "seller", "monster", "chest",
  "shop", "npc_search" }
local WORLD_DEF = {
  treasure = { toggle = "world_treasure", src = "treasure" },
  token = { toggle = "world_tokens", src = "tokens" },
  beetle = { toggle = "world_beetles", src = "beetles" },
  seller = { toggle = "world_sellers", src = "sellers" },
  monster = { toggle = "world_monsters", src = "monsters" },
  chest = { toggle = "world_chests", src = "chests" },
  -- v11/v12: no toggle entry. Shop candidates exist while a search is
  -- active or show.world_shops == true (SPEC 20.3).
  shop = { src = "shops" },
  -- v14: NPC name matches. No toggle; candidates exist only while a query
  -- does, and fill the leftover slots together with shops.
  npc_search = {},
}
-- Categories whose candidates are built outside the generic per-src loops.
local function special_cat(cat) return cat == "shop" or cat == "npc_search" end
-- SPEC 28.12.3: which monsters are shown. A large one needs Large
-- (world_monsters ~= false), a small one needs Small
-- (world_small_monsters == true). The one place the rule is written.
local function monster_shown(small, show)
  if small then return show.world_small_monsters == true end
  return show.world_monsters ~= false
end
-- Is a generic category switched on? Monsters are a tree (SPEC 28.12.3): the
-- category is on when either Large or Small is.
local function cat_on(cat, show)
  if cat == "monster" then
    return monster_shown(false, show) or monster_shown(true, show)
  end
  return show[WORLD_DEF[cat].toggle] ~= false
end
local WORLD_CAT_RANK = {}
for i, cat in ipairs(M.WORLD_CATS) do WORLD_CAT_RANK[cat] = i end
M.WORLD_MARKER_MAX = 300
M.WORLD_ROWS = 10

local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function valid_pos(p)
  return type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z)
end
M.valid_pos = valid_pos

local function dist2(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return dx * dx + dy * dy + dz * dz
end

local function pos_copy(p)
  if type(p) ~= "table" then return nil end
  return { x = p.x, y = p.y, z = p.z }
end

-- A position within 1 unit of (0, 0, 0) is unknown (SPEC 17.3g).
local ZERO = { x = 0, y = 0, z = 0 }
local function near_zero(p) return dist2(p, ZERO) <= 1 end
M.near_zero = near_zero

local DEDUPE_R = 3

-- "a, b, c" for the first three names, then " (+N)" for the rest of `total`.
local function top3(names, total)
  local out = table.concat(names, ", ", 1, math.min(3, #names))
  if total > 3 then out = out .. " (+" .. tostring(total - 3) .. ")" end
  return out
end

-- Joined item list for a chest or treasure label: up to three names,
-- "<name> x<n>" for n > 1, then " (+N)"; nil when there is nothing to list.
-- skip_nil drops items without a name (treasure); chests keep tostring.
-- Item lists are dense (built by append), so ipairs counts them all.
local function items_text(items, skip_nil)
  items = type(items) == "table" and items or {}
  local names, total = {}, 0
  for _, it in ipairs(items) do
    if not (skip_nil and it.name == nil) then
      total = total + 1
      if total <= 3 then
        local n = tostring(it.name)
        if type(it.n) == "number" and it.n > 1 then
          n = n .. " x" .. tostring(math.floor(it.n))
        end
        names[#names + 1] = n
      end
    end
  end
  if #names == 0 then return nil end
  return top3(names, total)
end

-- SPEC 27.2, 27.6: the chest kinds, in order, with the phrase labels and
-- search use and the settings key that turns each off.
local KIND_PHRASE = { ng_shard = "new shard each cycle",
  kept = "stays opened in NG+", quest = "quest-gated", trap = "trap",
  pawn = "pawns can't open" }
local KIND_KEY = { ng_shard = "world_kind_ng_shard", kept = "world_kind_kept",
  quest = "world_kind_quest", trap = "world_kind_trap",
  pawn = "world_kind_pawn" }

-- The label's kind phrases: quest shown as its quest_text (SPEC 27.5).
local function kind_phrase(e, k)
  if k == "quest" and type(e.quest_text) == "string" and e.quest_text ~= "" then
    return e.quest_text
  end
  return KIND_PHRASE[k]
end

-- Chest label (SPEC 17.10.11): item_name wins; else up to three item names,
-- "<name> x<n>" for n > 1, then " (+N)" for the rest; no items: "Chest".
-- Kinds (SPEC 27.5) add a bracket: at most two phrases, then " +N".
function M.chest_label(chest)
  local e = chest or {}
  local text
  if type(e.item_name) == "string" and e.item_name ~= "" then
    text = e.item_name
  else
    text = items_text(e.items, false)
  end
  local out = text and ("Chest - " .. text) or "Chest"
  if type(e.kinds) == "table" then
    local ph = {}
    for _, k in ipairs(e.kinds) do
      local p = kind_phrase(e, k)
      if p then ph[#ph + 1] = p end
    end
    if #ph > 0 then
      local shown = ph[1]
      if #ph >= 2 then shown = shown .. ", " .. ph[2] end
      if #ph > 2 then shown = shown .. " +" .. (#ph - 2) end
      out = out .. " [" .. shown .. "]"
    end
  end
  return out
end

-- Treasure nodes within 3 units of any chest are the chest's own marker
-- (SPEC 17.10.11); returns a set keyed by the treasure entry table.
local function treasure_dups(world)
  local dups = {}
  local tre, chests = world.treasure, world.chests
  if not (tre and chests and #tre > 0 and #chests > 0) then return dups end
  local function cell(v) return math.floor(v / DEDUPE_R) end
  local function ckey(x, y, z) return x .. "," .. y .. "," .. z end
  local grid = {}
  for _, c in ipairs(chests) do
    if valid_pos(c.pos) then
      local key = ckey(cell(c.pos.x), cell(c.pos.y), cell(c.pos.z))
      local b = grid[key]
      if not b then b = {}; grid[key] = b end
      b[#b + 1] = c.pos
    end
  end
  local r2 = DEDUPE_R * DEDUPE_R
  for _, e in ipairs(tre) do
    if valid_pos(e.pos) then
      local cx, cy, cz = cell(e.pos.x), cell(e.pos.y), cell(e.pos.z)
      for dx = -1, 1 do
        for dy = -1, 1 do
          for dz = -1, 1 do
            local b = grid[ckey(cx + dx, cy + dy, cz + dz)]
            if b then
              for _, p in ipairs(b) do
                if dist2(e.pos, p) <= r2 then dups[e] = true end
              end
            end
          end
        end
      end
    end
  end
  return dups
end

-- Is this entry a candidate at all (counted in `known`)? Small monsters count
-- only while Small is on; every other entry counts whatever its category
-- toggle says (a toggled-off category still reports `known`).
local function included(cat, e, small_ok, dups)
  if not valid_pos(e.pos) then return false end
  if cat == "treasure" and dups[e] then return false end
  if cat == "monster" and e.small == true and not small_ok then return false end
  return true
end

-- SPEC 29.3: a monster's kind; a missing or non-string one counts as "Monster".
local function kind_of(e)
  return type(e.kind) == "string" and e.kind or "Monster"
end
M.kind_of = kind_of

-- SPEC 30.5.1: a monster's family; a missing or non-string one counts as "?".
local function fam_of(e)
  return type(e.fam) == "string" and e.fam or "?"
end
M.fam_of = fam_of

-- "fam:" .. fam, built once per family rather than per monster per tick.
local FAM_KEY = setmetatable({}, { __index = function(t, f)
  local k = "fam:" .. f; t[f] = k; return k
end })

-- SPEC 30.2.1: a family's display name: its shortest kind name, ties by byte
-- order, "Monster" left out unless it is the only one, "Other" for no kinds.
function M.family_name(names)
  local best
  for _, n in ipairs(names or {}) do
    if n ~= "Monster" and (best == nil or #n < #best or (#n == #best and n < best)) then
      best = n
    end
  end
  if best ~= nil then return best end
  if names ~= nil and names[1] ~= nil then return names[1] end
  return "Other"
end

-- The monster class a small flag names.
local function class_of(small)
  return small and "small" or "large"
end

-- SPEC 29.5.2: is this monster's kind switched off in its class?
local function kind_off(e, show)
  local off = show.world_monster_off
  if type(off) ~= "table" then return false end
  local cls = off[class_of(e.small == true)]
  if type(cls) ~= "table" then return false end
  return cls[kind_of(e)] == true or cls[FAM_KEY[fam_of(e)]] == true
end

-- SPEC 29.5.3, 30.5.3: count one known monster into
-- kc = { large = {}, small = {} } as kc[class][fam][kind].
local function count_kind(kc, e)
  local cls = kc[class_of(e.small == true)]
  local f, k = fam_of(e), kind_of(e)
  local fc = cls[f]
  if not fc then fc = {}; cls[f] = fc end
  fc[k] = (fc[k] or 0) + 1
end

local function monster_label(e)
  local label = tostring(e.name)
  if e.respawning then label = label .. " (respawning)" end
  return label
end

local function seller_label(e)
  local label = tostring(e.item_name) .. " - sold by " .. tostring(e.npc)
  if type(e.quest) == "string" and e.quest ~= "" then
    label = label .. " (for " .. e.quest .. ")"
  end
  if e.maybe_locked then label = label .. " (may be locked)" end
  return label
end

-- SPEC 19.12.4: the drop names of a monster entry over its cluster's cids,
-- one lower-cased name kept once; nil when there are none. names are the
-- lower-cased names, shown the display names, in list order.
local function monster_drops_of(e, drops, pre)
  if type(drops) ~= "table" then return nil end
  local names, shown, seen = {}, {}, {}
  for i, c in ipairs(e.cids or { e.cid }) do
    local list
    if pre then list = pre[i] else list = drops[c] end   -- pre: lists already read
    if type(list) == "table" then
      for _, n in ipairs(list) do
        local low = tostring(n):lower()
        if not seen[low] then
          seen[low] = true
          names[#names + 1] = low
          shown[#shown + 1] = tostring(n)
        end
      end
    end
  end
  if #names == 0 then return nil end
  return { names = names, shown = shown }
end

-- SPEC 19.12.5: hover and why for the drop names the query matches, or
-- nil, nil. md is a monster_drops_of result.
local function drop_hover(label, md, q)
  local hit = {}
  for i, low in ipairs(md.names) do
    if wmatch(q, low) then hit[#hit + 1] = md.shown[i] end
  end
  if #hit == 0 then return nil, nil end
  local list = top3(hit, #hit)
  return label .. "\n" .. "Drops " .. list, "drops " .. list
end

-- SPEC 19.6.3-4: the haystack of a (non-shop) world entry.
local function entry_hay(cat, e, drops, md)
  if cat == "chest" then
    local parts = { "chest" }
    if type(e.item_name) == "string" and e.item_name ~= "" then
      parts[#parts + 1] = e.item_name
    end
    for _, it in ipairs(type(e.items) == "table" and e.items or {}) do
      parts[#parts + 1] = it.name
    end
    for _, k in ipairs(type(e.kinds) == "table" and e.kinds or {}) do
      if KIND_PHRASE[k] then parts[#parts + 1] = KIND_PHRASE[k] end
    end
    if type(e.quest_text) == "string" and e.quest_text ~= "" then
      parts[#parts + 1] = e.quest_text
    end
    return hay_join(parts)
  elseif cat == "treasure" then
    local parts = { "Treasure" }
    for _, it in ipairs(type(e.items) == "table" and e.items or {}) do
      if it.name ~= nil then parts[#parts + 1] = it.name end
    end
    return hay_join(parts)
  elseif cat == "monster" then
    local parts = { e.name }   -- the name, never the "(respawning)" label
    if md == nil then md = monster_drops_of(e, drops) end   -- false: none
    for _, n in ipairs(md and md.names or {}) do parts[#parts + 1] = n end
    return hay_join(parts)
  elseif cat == "seller" then
    -- item, NPC and quest fields, never the "sold by / for / may be locked" words
    local parts = {}
    if e.item_name ~= nil then parts[#parts + 1] = e.item_name end
    if e.npc ~= nil then parts[#parts + 1] = e.npc end
    if type(e.quest) == "string" and e.quest ~= "" then parts[#parts + 1] = e.quest end
    return hay_join(parts)
  end
  return hay_join({ e.name })
end

-- SPEC 28.4.3: haystacks carry across grid rebuilds. The identity cache is
-- keyed by category and entry identity (seller shop:item, shop id, treasure
-- name, every other category uid) and stores only the lower-cased strings and
-- drop-name lists, with the source fields they were built from (a flat
-- array). A lookup compares the entry's current source fields against the
-- stored array (same_src, no allocation) and reuses the record only when every
-- field is equal (strings by value, a list by length and each name); only a
-- rebuild collects them into `scratch`. Per-query memos
-- stay keyed by entry table in the per-grid record, never here. Emptied once
-- it passes HAY_MAX records (a bound, not a tuning knob).
local HAY_MAX = 20000
local hay_ids, hay_n = {}, 0
local scratch, scratch_n = {}, 0
local mon_lists, mon_n = {}, 0   -- the drop lists collect read for the monster, by cid index

local function put(v)
  scratch_n = scratch_n + 1
  if v == nil then v = false end
  scratch[scratch_n] = v
end

-- A count, then each string / each item's name: the mirror of same_strs and
-- same_names below.
local function put_strs(list)
  local n = type(list) == "table" and #list or 0
  put(n)
  for i = 1, n do put(list[i]) end
end

local function put_names(items)
  local n = type(items) == "table" and #items or 0
  put(n)
  for i = 1, n do put(items[i].name) end
end

-- One cid's drop list, kept in mon_lists for the rebuild that follows.
local function put_list(drops, i, c)
  local list = drops[c]
  mon_lists[i] = list
  mon_n = i
  put_strs(list)
end

-- The source fields of an entry, in a fixed order, into `scratch`.
local function collect(cat, e, drops)
  scratch_n = 0
  if cat == "chest" then
    put(e.item_name); put(e.quest_text)
    put_strs(e.kinds)
    put_names(e.items)
  elseif cat == "treasure" then
    put_names(e.items)
  elseif cat == "monster" then
    put(e.name)
    if drops == nil then
      put(-2)
    elseif e.cids then
      -- each cid's drop list is read once; a rebuild reuses the lists read here
      for i, c in ipairs(e.cids) do put_list(drops, i, c) end
    else
      put_list(drops, 1, e.cid)
    end
  elseif cat == "seller" then
    put(e.item_name); put(e.npc); put(e.quest)
  elseif cat == "shop" then
    put(e.npc)
    put_names(e.items)
  else
    put(e.name)
  end
end

-- Comparisons against the stored source array `s`, from index k: each returns
-- the next index, or false on a difference. They allocate nothing (the carry
-- path runs once per entry per grid).
local function same_names(s, k, items)   -- a count, then each item's name
  local n = type(items) == "table" and #items or 0
  if s[k] ~= n then return false end
  for i = 1, n do
    if s[k + i] ~= (items[i].name or false) then return false end
  end
  return k + n + 1
end

local function same_strs(s, k, list)   -- a count, then each string
  local n = type(list) == "table" and #list or 0
  if s[k] ~= n then return false end
  for i = 1, n do
    if s[k + i] ~= list[i] then return false end
  end
  return k + n + 1
end

-- Does the stored record match the entry's current source fields? Mirrors
-- collect, field for field.
local function same_src(cat, rec, e, drops)
  local s = rec.src
  local k
  if cat == "chest" then
    if s[1] ~= (e.item_name or false) or s[2] ~= (e.quest_text or false) then return false end
    k = same_strs(s, 3, e.kinds)
    if not k then return false end
    -- the items are last in the array; the same list table is the same names
    if rec.items_ref ~= nil and rec.items_ref == e.items then
      k = rec.sn + 1
    else
      k = same_names(s, k, e.items)
      if not k then return false end
    end
  elseif cat == "treasure" then
    if rec.items_ref ~= nil and rec.items_ref == e.items then
      k = rec.sn + 1
    else
      k = same_names(s, 1, e.items)
    end
  elseif cat == "monster" then
    if s[1] ~= (e.name or false) then return false end
    if drops == nil then
      if s[2] ~= -2 then return false end
      k = 3
    else
      k = 2
      if e.cids then
        for _, c in ipairs(e.cids) do
          k = same_strs(s, k, drops[c])
          if not k then return false end
        end
      else
        k = same_strs(s, k, drops[e.cid])
      end
    end
  elseif cat == "seller" then
    if s[1] ~= (e.item_name or false) or s[2] ~= (e.npc or false)
      or s[3] ~= (e.quest or false) then return false end
    k = 4
  elseif cat == "shop" then
    if s[1] ~= (e.npc or false) then return false end
    k = same_names(s, 2, e.items)
  else
    if s[1] ~= (e.name or false) then return false end
    k = 2
  end
  return k == rec.sn + 1
end

-- The cached record of an entry: { hay, names, shown } for a search entry
-- (names and shown only for a monster with drops, SPEC 19.12.4.3), or
-- { npc, names } for a shop (SPEC 19.7). A seller is keyed shop, then item.
local function hay_rec(cat, e, drops)
  local bycat = hay_ids[cat]
  if bycat == nil then bycat = {}; hay_ids[cat] = bycat end
  local id, sub
  if cat == "seller" then
    id, sub = e.shop, e.item
  elseif cat == "shop" then
    id = e.shop
  elseif cat == "treasure" then
    id = e.name
  else
    id = e.uid
  end
  local keyed = id ~= nil and id == id and (cat ~= "seller" or (sub ~= nil and sub == sub))
  local slot = bycat
  if keyed and cat == "seller" then
    slot = bycat[id]
    if slot == nil then slot = {}; bycat[id] = slot end
    id = sub
  end
  local rec = keyed and slot[id] or nil
  if rec and same_src(cat, rec, e, drops) then return rec end
  collect(cat, e, drops)
  M.world_stats.hay_builds = M.world_stats.hay_builds + 1
  local fresh = { sn = scratch_n, src = table.move(scratch, 1, scratch_n, 1, {}) }
  if cat == "chest" or cat == "treasure" then
    -- item lists are never changed after they are built (M.item_list returns
    -- the same table while ids and counts stay equal), so identity is equality
    fresh.items_ref = type(e.items) == "table" and e.items or nil
  end
  if cat == "shop" then
    fresh.npc = tostring(e.npc):lower()
    fresh.names = {}
    for i, it in ipairs(e.items) do fresh.names[i] = tostring(it.name):lower() end
  else
    local md = false   -- false: looked up, none
    if cat == "monster" and drops ~= nil then
      md = monster_drops_of(e, drops, mon_lists) or false
      for i = 1, mon_n do mon_lists[i] = nil end   -- do not keep the lists alive
      mon_n = 0
    end
    fresh.hay = entry_hay(cat, e, drops, md)
    if md then fresh.names, fresh.shown = md.names, md.shown end
  end
  if keyed then
    if rec ~= nil then
      slot[id] = fresh
    elseif hay_n >= HAY_MAX then
      hay_ids, hay_n = {}, 0   -- over the bound: start empty, this one is rebuilt next time
    else
      hay_n = hay_n + 1
      slot[id] = fresh
    end
  end
  return fresh
end

-- SPEC 28.4.2: does the entry match the query? One path for the cached and the
-- uncached world builders. `gc` is the grid record { hay, match, mkey, dhov };
-- the uncached path passes a fresh { hay = {}, match = {} }. The match result
-- and the drop hover are memoised per query key, keyed by the entry table, and
-- start empty for every new query. A drop match writes ctx.mdrop[e].
local function entry_search(cat, e, drops, gc, q, ctx)
  if q == nil then return true end
  if gc.mkey ~= q.key or gc.match == nil then
    gc.mkey, gc.match, gc.dhov = q.key, {}, {}
  end
  local rec = gc.hay[e]   -- per-grid memo by entry table over the identity cache
  if rec == nil then
    rec = hay_rec(cat, e, drops)
    gc.hay[e] = rec
  end
  local m = gc.match[e]
  if m == nil then
    m = wmatch(q, rec.hay)
    gc.match[e] = m
  end
  if not m then return false end
  local dh = rec.names and rec or nil   -- a monster with drops
  if dh then
    local hv = gc.dhov[e]
    if hv == nil then
      local hover, why = drop_hover(monster_label(e), dh, q)
      hv = hover and { hover = hover, why = why } or false
      gc.dhov[e] = hv
    end
    if hv then ctx.mdrop[e] = hv end
  end
  return true
end

-- SPEC 19.7: the counting items a query selects from a shop entry, or nil.
-- h = { npc = <lower>, names = { <lower>, ... } } (the identity cache,
-- SPEC 28.4.3; only a search reads it).
local function shop_listing(e, q, h)
  local items = e.items
  if type(items) ~= "table" or #items == 0 then return nil end
  if wmatch(q, h.npc) then return items end
  local out = {}
  for i, it in ipairs(items) do
    if wmatch(q, h.names[i]) then out[#out + 1] = it end
  end
  if #out > 0 then return out end
  return nil
end

local function shop_label(e, list)
  local names, all_locked = {}, true
  for i = 1, #list do
    if i <= 3 then names[i] = tostring(list[i].name) end
    if not list[i].locked then all_locked = false end
  end
  local out = tostring(e.npc) .. " sells " .. top3(names, #list)
  if all_locked then out = out .. " (may be locked)" end
  return out
end

-- One candidate for an entry, with `hidden` set by the show filters.
local function make_cand(cat, e, ctx)
  local c = { cat = cat, qids = {}, pos = e.pos, cid = e.cid, hover = e.hover }
  if cat == "chest" then
    c.key = "w:chest:" .. tostring(e.uid)
    local lab = ctx.labels and ctx.labels[e]
    if lab == nil then
      lab = M.chest_label(e)
      if ctx.labels then ctx.labels[e] = lab end
    end
    c.label = lab
    c.done = e.state == "opened"
    local near_box = false
    for _, b in ipairs(ctx.boxes) do
      if valid_pos(b) and dist2(e.pos, b) <= 1 then near_box = true; break end
    end
    c.hidden = near_box or (c.done and not ctx.show_opened)
    -- SPEC 27.6: a chest is hidden when any of its kinds is off
    if not c.hidden and type(e.kinds) == "table" then
      for _, k in ipairs(e.kinds) do
        if KIND_KEY[k] and ctx.show_kind[KIND_KEY[k]] == false then
          c.hidden = true; break
        end
      end
    end
    c.faded = e.quest_met == false
  elseif cat == "treasure" then
    c.key = "w:tre:" .. tostring(e.name)
    local text = items_text(e.items, true)
    c.label = text and ("Treasure - " .. text) or "Treasure"
    c.done = e.checked == true
    c.hidden = (e.discovered == false) and not ctx.undisc
  elseif cat == "token" or cat == "beetle" then
    c.key = (cat == "token" and "w:tok:" or "w:bee:") .. tostring(e.uid)
    c.label = tostring(e.name)
    c.done = e.state == "collected"
    c.hidden = c.done and not ctx.show_opened
  elseif cat == "monster" then
    c.key = "w:mon:" .. tostring(e.uid)
    c.small = e.small == true
    c.kind = kind_of(e)
    c.fam = fam_of(e)
    c.label = monster_label(e)
    local md = ctx.mdrop and ctx.mdrop[e]
    if md then c.hover, c.why = md.hover, md.why end
  elseif cat == "shop" then
    c.key = "w:shop:" .. tostring(e.shop)
    c.label = ctx.slabel[e]
    c.shop = e.shop
    c.stock = e.items        -- by reference (SPEC 20.4)
    c.sells_for = {}         -- seller lines, filled by world_accept
    c.hidden = (e.discovered == false) and not ctx.undisc
  elseif cat == "npc_search" then
    c.key = "w:npc:" .. tostring(e.cid)
    c.label = tostring(e.name)
    c.hidden = e.alive == false
      or ((e.discovered == false) and not ctx.undisc)
  else
    for i, q in ipairs(e.qids or {}) do c.qids[i] = q end
    c.key = string.format("w:sell:%s:%s", tostring(e.shop), tostring(e.item))
    c.label = seller_label(e)
    c.shop = e.shop
    c.quest = e.quest
    c.item_name = e.item_name
    c.hidden = (e.discovered == false) and not ctx.undisc
  end
  -- the ordinary token at the First Seeker's Token spot draws as the spot
  -- (SPEC 28.9.3) while the spot itself is built; it stays in `known`
  if e.first_seeker and ctx.spot then c.hidden = true end
  return c
end

-- v14 (SPEC 22.7.3): the entries of `npcs` whose name matches the query, in
-- name order (lower-cased name, then cid). No query: none. Lower-cased names
-- are cached per entry (weak keys).
local npc_hay = setmetatable({}, { __mode = "k" })
local function npc_low(e)
  local h = npc_hay[e]
  if h == nil or h.name ~= e.name then
    h = { name = e.name, low = e.name:lower() }
    npc_hay[e] = h
  end
  return h.low
end

-- One memo entry: the same list (and size) with the same query returns the
-- same result table, so a tick scans and sorts the name list once. Callers
-- must not modify the result.
local npc_memo = {}
function M.npc_matches(npcs, q)
  if q == nil or type(npcs) ~= "table" then return {} end
  if npc_memo.npcs == npcs and npc_memo.n == #npcs and npc_memo.key == q.key then
    return npc_memo.out
  end
  local out = {}
  for _, e in ipairs(npcs) do
    if type(e) == "table" and type(e.name) == "string"
      and type(e.cid) == "number" and query_match(q, npc_low(e)) then
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    local la, lb = npc_low(a), npc_low(b)
    if la ~= lb then return la < lb end
    return a.cid < b.cid
  end)
  npc_memo.npcs, npc_memo.n, npc_memo.key, npc_memo.out = npcs, #npcs, q.key, out
  return out
end

-- Ruling 10: the first 50 matched cids, in name order.
M.NPC_MATCH_MAX = 50
function M.npc_match_cids(matches)
  local out = {}
  for i = 1, math.min(M.NPC_MATCH_MAX, #matches) do out[i] = matches[i].cid end
  return out
end

-- Candidates of the matched NPCs that have a position (one per cid).
local function npc_cands(matches, ctx)
  local out, seen = {}, {}
  for _, e in ipairs(matches) do
    if valid_pos(e.pos) and not seen[e.cid] then
      seen[e.cid] = true
      out[#out + 1] = make_cand("npc_search", e, ctx)
    end
  end
  return out
end

-- The panel rows of the matches (SPEC 22.7.5): at most `limit` (ten), those
-- with a position nearest to `origin` first (name order without one), the
-- ones without a position last by name. `cover` maps a cid to the key of
-- the marker that stands for it.
function M.npc_rows(matches, origin, cover, limit)
  local with, without = {}, {}
  local has = valid_pos(origin)
  for i, e in ipairs(matches) do
    local r = { cid = e.cid, name = e.name, alive = e.alive ~= false,
      marker_key = cover and cover[e.cid] or nil }
    if valid_pos(e.pos) then
      r.pos = pos_copy(e.pos)
      with[#with + 1] = { r = r, i = i, d = has and dist2(e.pos, origin) or 0 }
    else
      without[#without + 1] = r
    end
  end
  table.sort(with, function(x, y)
    if x.d ~= y.d then return x.d < y.d end
    return x.i < y.i
  end)
  local max = limit or M.WORLD_ROWS
  local rows = {}
  for _, w in ipairs(with) do
    if #rows >= max then break end
    rows[#rows + 1] = w.r
  end
  for _, r in ipairs(without) do
    if #rows >= max then break end
    rows[#rows + 1] = r
  end
  return rows
end

local function world_ctx(show, boxes)
  return { show_opened = show.world_show_opened == true,
    undisc = show.world_undiscovered == true, boxes = boxes or {},
    show_kind = show,
    mdrop = show.search ~= nil and {} or nil }
end

-- Shop candidates (SPEC 19.7, 20.3): while a search is active (the matching
-- entries) or show.world_shops is on (every entry with stock). With neither
-- the shop list is not read at all. Returns the list, the entry count and
-- the shop-id -> visible-candidate set.
local function shop_cands(world, q, ctx, gc, shops_on)
  local out, shop_of = {}, {}
  local list = (q ~= nil or shops_on) and type(world.shops) == "table"
    and world.shops or {}
  ctx.slabel = {}
  -- the listing and label memo: one record per entry table in the per-grid
  -- record (no lower-cased names in it)
  gc.shop = gc.shop or {}
  local memo = gc.shop
  -- no-search key "" is distinct from every query key (a query has a term)
  local qkey = q ~= nil and q.key or ""
  for _, e in ipairs(list) do
    if valid_pos(e.pos) and type(e.items) == "table" then
      local h = memo[e]
      if h == nil then h = {}; memo[e] = h end
      if h.qkey ~= qkey then   -- listing and label change only with the query
        h.qkey = qkey
        if q ~= nil then
          h.list = shop_listing(e, q, hay_rec("shop", e)) or false
          h.label = h.list and shop_label(e, h.list) or nil
        else
          h.list = (#e.items > 0) and e.items or false
          h.label = h.list and (tostring(e.npc) .. " (shop)") or nil
        end
      end
      if h.list then
        ctx.slabel[e] = h.label
        local c = make_cand("shop", e, ctx)
        out[#out + 1] = c
        if not c.hidden then shop_of[c.shop] = c end
      end
    end
  end
  return out, #list, shop_of
end

-- Uncached candidates: every included entry counts in `known`; with a
-- query only the matching ones become candidates (before make_cand).
local function world_candidates(world, show, boxes, q, spot, skip)
  local cands, known = {}, {}
  local ctx = world_ctx(show, boxes)
  ctx.spot = spot
  local small_ok = monster_shown(true, show)
  local dups = treasure_dups(world)
  local drops = q ~= nil and world.drops or nil
  local gc = { hay = {}, match = {} }
  known.monster_small = 0
  known.kinds = { large = {}, small = {} }
  for _, cat in ipairs(M.WORLD_CATS) do
    known[cat] = 0
    if not special_cat(cat) then
      for _, e in ipairs(world[WORLD_DEF[cat].src] or {}) do
        if included(cat, e, small_ok, dups) then
          known[cat] = known[cat] + 1
          if cat == "monster" and e.small == true then
            known.monster_small = known.monster_small + 1
          end
          if cat == "monster" then count_kind(known.kinds, e) end
          if not (skip and skip[e]) and not (cat == "monster" and kind_off(e, show))
            and entry_search(cat, e, drops, gc, q, ctx) then
            cands[#cands + 1] = make_cand(cat, e, ctx)
          end
        end
      end
    end
  end
  local sc, n, shop_of = shop_cands(world, q, ctx, gc,
    show.world_shops == true)
  known.shop = n
  for _, c in ipairs(sc) do cands[#cands + 1] = c end
  if q ~= nil then
    local matches = M.npc_matches(world.npcs, q)
    known.npc_search = #matches
    for _, c in ipairs(npc_cands(matches, ctx)) do cands[#cands + 1] = c end
  end
  return cands, known, shop_of
end

-- SPEC 28.9.3: the First Seeker's Token spot, from world.first_token while
-- show.world_first_token ~= false. One candidate in the token category with no
-- world_ord (map GUID slot 0), held apart from `kept`: no cap slot, no toggle
-- or query filter, never done, faded or hidden.
local function first_token_cand(world, show)
  local t = world.first_token
  if show.world_first_token == false or type(t) ~= "table" or not valid_pos(t.pos) then
    return nil
  end
  return { cat = "token", qids = {}, key = "w:tok1:" .. tostring(t.uid),
    pos = t.pos, label = tostring(t.name) }
end

-- v19 (SPEC 32.6): the world entries related to the focused quests: chests
-- whose gate quest is focused or that hold a needed item, and sellers of a
-- focused quest. Returns { { cat, e }, ... } in world order and the set of
-- their entry tables. Entries without a valid position are left out.
local function focus_entries(world, fx)
  local list, set = {}, {}
  if fx == nil then return list, set end
  local function any_in(s, l)
    if type(l) ~= "table" then return false end
    for _, v in ipairs(l) do
      if s[v] then return true end
    end
    return false
  end
  for _, e in ipairs(world.chests or {}) do
    if valid_pos(e.pos) then
      local hit = any_in(fx.qids, e.gate_qids) or (e.item ~= nil and fx.items[e.item])
        or any_in(fx.items, e.item_ids)
      if hit then list[#list + 1] = { cat = "chest", e = e }; set[e] = true end
    end
  end
  for _, e in ipairs(world.sellers or {}) do
    if valid_pos(e.pos) then
      if any_in(fx.qids, e.qids) then list[#list + 1] = { cat = "seller", e = e }; set[e] = true end
    end
  end
  return list, set
end

-- The candidates of the related entries, ordered by key: outside the toggles
-- and kind filters, never hidden by the cap. A hidden one (opened, undiscovered,
-- at a box) is dropped. Under a query, one that does not match is marked
-- focus_kept (drawn, but not a result).
local function related_cands(list, world, show, boxes, q, labels)
  local rctx = world_ctx(show, boxes)
  rctx.show_kind = {}
  rctx.labels = labels
  local drops = q ~= nil and world.drops or nil
  local gc = { hay = {}, match = {} }
  local out = {}
  for _, p in ipairs(list) do
    local ok = entry_search(p.cat, p.e, drops, gc, q, rctx)
    local c = make_cand(p.cat, p.e, rctx)
    if not c.hidden then
      if not ok then c.focus_kept = true end
      out[#out + 1] = c
    end
  end
  table.sort(out, function(x, y) return x.key < y.key end)
  return out
end

local function world_cap(show)
  local cap = show.world_max_markers
  if type(cap) ~= "number" then cap = M.WORLD_MARKER_MAX end
  return math.max(0, math.floor(cap))
end

local function new_panel()
  local panel = {}
  for _, cat in ipairs(M.WORLD_CATS) do
    panel[cat] = { shown = 0, known = 0, entries = {} }
  end
  panel.monster.small_shown, panel.monster.small_known = 0, 0   -- SPEC 28.12.3
  return panel
end

-- Seller merge or keep, shared by the uncached and the cached path.
-- Seller lines of a shop go to its `sells_for` list (hover and merged line
-- are built in world_finish, so accept order does not matter). With
-- shops_on shops compete for the cap like any category; with it off (a
-- search only) they go to their own list (`shops`) and fill what the cap
-- leaves (SPEC 19.7.5). Every shop accepted is also listed in `shop_all`.
-- A seller whose shop is visible is only noted in `hits`; merge_shops adds its
-- line and promotes the shop (SPEC 28.4.4).
local function world_accept(c, has_origin, origin, quest_cids, kept, merged,
                            shops, shop_of, shops_on, shop_all, hits)
  if c.cat == "npc_search" then
    -- v14: NPC matches only ever fill the leftover slots (SPEC 22.7.4)
    c.d = has_origin and dist2(c.pos, origin) or 0
    shops[#shops + 1] = c
    c.in_shops = true
    return
  end
  if c.cat == "shop" then shop_all[#shop_all + 1] = c end
  if c.cat == "seller" and shop_of and shop_of[c.shop] then
    -- SPEC 19.7.7: the shop marker stands in for its seller
    hits[#hits + 1] = c
    return
  end
  if (c.cat == "seller" or c.cat == "shop") and type(c.cid) == "number"
    and quest_cids and quest_cids[c.cid] then
    merged[#merged + 1] = { cid = c.cid, cand = c }
    if c.cat == "shop" then c.merged = true end
  else
    c.d = has_origin and dist2(c.pos, origin) or 0
    if c.cat == "shop" and not shops_on then
      shops[#shops + 1] = c
      c.in_shops = true
    else
      kept[#kept + 1] = c
    end
  end
end

-- SPEC 28.4.4: one step, run before world_finish on both paths. Each seller
-- candidate that hit a visible shop adds its quest line to the shop and gives
-- the shop its seller's rank. The shop stands in for the seller, so it
-- competes for the cap at its own distance (ruling), not for the leftover
-- slots: a shop still in `shops` moves to `kept`. A shop merged into a quest
-- marker is in neither list, and one already kept (Shops on) is not moved.
local function merge_shops(kept, shops, shop_of, hits)
  for _, h in ipairs(hits) do
    local sc = shop_of[h.shop]
    if type(h.quest) == "string" and h.quest ~= "" then
      sc.sells_for[#sc.sells_for + 1] = tostring(h.item_name)
        .. " (for " .. h.quest .. ")"
    end
    sc.rank_cat = "seller"
    if sc.in_shops then
      for i, x in ipairs(shops) do
        if x == sc then table.remove(shops, i); break end
      end
      sc.in_shops = false
      kept[#kept + 1] = sc
    end
  end
end

-- The seller lines of a shop candidate under its label ("\n"-joined), or
-- the bare label when there are none.
local function with_sells(c)
  if c.sells_for and #c.sells_for > 0 then
    return c.label .. "\n" .. table.concat(c.sells_for, "\n")
  end
  return c.label
end

-- Cap selection, world_ord and the output order, shared by both paths.
-- `shop_all`: every visible shop candidate in world.shops order. After the
-- cap, a shop merged into a quest marker adds a `merged` panel entry and one
-- the cap left out an `offmap` entry (SPEC 20.5.5, 20.5.7); neither is a
-- marker or counted in `shown`.
local function world_finish(kept, merged, panel, cap, has_origin, shops, shop_all,
                            quest_cids, ft, kcounts, rel)
  -- Nearest win the cap (ties by key); no origin: (category, key) order.
  local function by_pick(x, y)
    if has_origin then
      if x.d ~= y.d then return x.d < y.d end
    else
      local rx, ry = x.rank_cat or x.cat, y.rank_cat or y.cat
      if rx ~= ry then return WORLD_CAT_RANK[rx] < WORLD_CAT_RANK[ry] end
    end
    return x.key < y.key
  end
  if #kept > cap then
    table.sort(kept, by_pick)
    for i = #kept, cap + 1, -1 do kept[i] = nil end
  end
  -- SPEC 19.7.5 (search with world_shops off): matching shops fill the
  -- remaining slots, nearest first.
  -- v14: cover maps a cid to the key of the marker already standing for it
  -- (a quest marker, or a kept shop or seller marker), so an NPC match with
  -- that cid adds none (SPEC 22.7.4).
  local cover = {}
  for cid, v in pairs(quest_cids or {}) do
    cover[cid] = type(v) == "table" and v.key or ("c:" .. tostring(cid))
  end
  for _, c in ipairs(kept) do
    if (c.cat == "shop" or c.cat == "seller") and type(c.cid) == "number"
      and cover[c.cid] == nil then
      cover[c.cid] = c.key
    end
  end
  for _, c in ipairs(rel or {}) do
    if c.cat == "seller" and type(c.cid) == "number" and cover[c.cid] == nil then
      cover[c.cid] = c.key
    end
  end
  if shops and #shops > 0 and #kept < cap then
    table.sort(shops, function(x, y)
      if has_origin and x.d ~= y.d then return x.d < y.d end
      return x.key < y.key
    end)
    -- Shops and NPC matches share the leftover slots, nearest first. A
    -- covered NPC takes none; a shop takes the place of a chosen NPC with
    -- its cid.
    local room = cap - #kept
    local chosen, npc_at, shop_cid = {}, {}, {}
    for _, c in ipairs(shops) do
      local cid = type(c.cid) == "number" and c.cid or nil
      if c.cat == "npc_search" then
        if not (cid and (cover[cid] or shop_cid[cid])) and #chosen < room then
          chosen[#chosen + 1] = c
          if cid then npc_at[cid] = #chosen end
        end
      elseif cid and npc_at[cid] then
        chosen[npc_at[cid]] = c
        npc_at[cid] = nil
        shop_cid[cid] = true
      elseif #chosen < room then
        chosen[#chosen + 1] = c
        if cid then shop_cid[cid] = true end
      end
    end
    for _, c in ipairs(chosen) do
      kept[#kept + 1] = c
      if type(c.cid) == "number" and cover[c.cid] == nil then
        cover[c.cid] = c.key
      end
    end
  end

  -- world_ord: rank by key in the kept set, so marker identity does not
  -- follow the distance order (as item_ord).
  table.sort(kept, function(x, y) return x.key < y.key end)
  for i, c in ipairs(kept) do c.world_ord = i end
  for i, c in ipairs(rel or {}) do c.world_ord = #kept + i end

  table.sort(kept, function(x, y)
    if x.cat ~= y.cat then return WORLD_CAT_RANK[x.cat] < WORLD_CAT_RANK[y.cat] end
    if has_origin and x.d ~= y.d then return x.d < y.d end
    return x.key < y.key
  end)
  local markers = {}
  local shown = { large = {}, small = {} }   -- SPEC 29.5.3 per-kind shown
  local in_kept = shop_all and #shop_all > 0 and {} or nil
  for _, c in ipairs(kept) do
    if in_kept then in_kept[c] = true end
    local m = { key = c.key, cat = c.cat, qids = c.qids,
      pos = pos_copy(c.pos),
      label = c.label, done = c.done, world_ord = c.world_ord, hover = c.hover,
      why = c.why, faded = c.faded }
    if c.cat == "npc_search" or c.cat == "shop" or c.cat == "seller" then m.cid = c.cid end
    if c.cat == "monster" then
      m.small = c.small
      m.kind = c.kind
      m.fam = c.fam
      if c.small then panel.monster.small_shown = panel.monster.small_shown + 1 end
      local cls = shown[class_of(c.small)]
      local fc = cls[c.fam]
      if not fc then fc = {}; cls[c.fam] = fc end
      fc[c.kind] = (fc[c.kind] or 0) + 1
    end
    if c.cat == "shop" then
      if #c.sells_for > 0 then m.hover = with_sells(c) end
      m.stock, m.sells_for = c.stock, c.sells_for
    end
    markers[#markers + 1] = m
    local p = panel[c.cat]
    p.shown = p.shown + 1
    p.entries[#p.entries + 1] = m
  end
  for _, mg in ipairs(merged) do
    mg.line = with_sells(mg.cand)
  end
  -- SPEC 29.5.3, 30.5.3, 30.5.4: per-(class, fam, kind) rows and per-family
  -- rows, large first, then family name, then fam, then kind.
  local kinds, families = {}, {}
  for _, class in ipairs({ "large", "small" }) do
    local rows = {}
    for f, fc in pairs(kcounts[class]) do
      local names = {}
      for k in pairs(fc) do names[#names + 1] = k end
      table.sort(names)
      local sf = shown[class][f] or {}
      local row = { fam = f, small = class == "small", shown = 0, known = 0,
        n_kinds = #names, kinds = {} }
      row.name = (f == "?") and "Other" or M.family_name(names)
      for _, k in ipairs(names) do
        local kr = { kind = k, fam = f, small = row.small, shown = sf[k] or 0, known = fc[k] }
        row.kinds[#row.kinds + 1] = kr
        row.shown = row.shown + kr.shown
        row.known = row.known + kr.known
      end
      rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b)
      if a.name ~= b.name then return a.name < b.name end
      return a.fam < b.fam
    end)
    for _, row in ipairs(rows) do
      for _, kr in ipairs(row.kinds) do kinds[#kinds + 1] = kr end
      families[#families + 1] = { fam = row.fam, small = row.small, name = row.name,
        shown = row.shown, known = row.known, n_kinds = row.n_kinds }
    end
  end
  panel.monster.kinds = kinds
  panel.monster.families = families
  if shop_all and #shop_all > 0 then
    local entries = panel.shop.entries
    for _, c in ipairs(shop_all) do
      if c.merged then
        entries[#entries + 1] = { key = c.key, label = c.label,
          pos = pos_copy(c.pos),
          stock = c.stock, sells_for = c.sells_for, merged = true }
      end
    end
    for _, c in ipairs(shop_all) do
      if not c.merged and not in_kept[c] then
        entries[#entries + 1] = { key = c.key, label = c.label,
          pos = pos_copy(c.pos),
          stock = c.stock, sells_for = c.sells_for, offmap = true }
      end
    end
  end
  -- SPEC 28.9.3: the First Seeker's Token spot goes last, after the cap trim
  -- and the leftover fill; the token panel's counts and entries are untouched.
  if ft then
    local m = { key = ft.key, cat = "token", qids = ft.qids, pos = pos_copy(ft.pos),
      label = ft.label, first_seeker = true }
    markers[#markers + 1] = m
    panel.token.first = m
  end
  -- v19 (SPEC 32.6): the related entries go last, outside the cap and the panel
  for _, c in ipairs(rel or {}) do
    markers[#markers + 1] = { key = c.key, cat = c.cat, qids = c.qids,
      pos = pos_copy(c.pos), label = c.label, done = c.done, world_ord = c.world_ord,
      hover = c.hover, why = c.why, faded = c.faded,
      cid = c.cat == "seller" and c.cid or nil,
      related = true, focus_kept = c.focus_kept }
  end
  return markers, panel, merged, cover
end

-- Selection, order and panel (SPEC 17.4b, 17.4g). `quest_cids` (optional)
-- is a set of cids that already have a c:<cid> quest marker; their sellers
-- merge into that marker's hover instead of drawing. Returns markers,
-- panel, merged where merged is a list of { cid, line }. Uncached; the
-- per-tick entry point is world_markers_cached.
function M.world_markers(world, show, origin, boxes, quest_cids, fx)
  world = world or {}
  show = show or {}
  local panel = new_panel()
  local cap = world_cap(show)
  local has_origin = valid_pos(origin)

  local kept, merged, shops, shop_all, hits = {}, {}, {}, {}, {}
  local shops_on = show.world_shops == true
  local ft = first_token_cand(world, show)
  local flist, fset = focus_entries(world, fx)
  local cands, known, shop_of = world_candidates(world, show, boxes, show.search, ft ~= nil, fset)
  for _, cat in ipairs(M.WORLD_CATS) do panel[cat].known = known[cat] end
  panel.monster.small_known = known.monster_small
  local kcounts = known.kinds
  for _, c in ipairs(cands) do
    if (special_cat(c.cat) or (cat_on(c.cat, show)
      and (c.cat ~= "monster" or monster_shown(c.small, show)))) and not c.hidden then
      world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
        shops_on, shop_all, hits)
    end
  end
  merge_shops(kept, shops, shop_of, hits)
  return world_finish(kept, merged, panel, cap, has_origin, shops, shop_all,
    quest_cids, ft, kcounts, related_cands(flist, world, show, boxes, show.search))
end

-- Cached entry point (SPEC 17.10.10). A 256-unit grid of the world's
-- entries (x, z cells) is built once per world table and small-monster
-- setting; sellers stay a plain list. The counters are for tests.
local CELL = 256
M.world_stats = { grid_builds = 0, cand_builds = 0, hay_builds = 0,
  query_calls = 0, item_need_reads = 0, cell_entries = {} }
for _, cat in ipairs(M.WORLD_CATS) do M.world_stats.cell_entries[cat] = 0 end
local grid_cache = { world = nil, small = nil, grid = nil }

local function cell_of(v) return math.floor(v / CELL) end
local function cell_key(ci, cj)
  return (ci + 1048576) * 2097152 + (cj + 1048576)
end

-- SPEC 28.7.2: one pass over a category's list. Counts `known` (and the small
-- monsters among them) for every category; puts the entries in cells and the
-- flat list only when `fill` (the category is on), widening the bounds.
-- Sellers are never in cells (the merge needs the whole list). Returns
-- known, small known, entries put in cells.
local function walk_cat(g, world, cat, fill, show, kc)
  local known, small_known, put_n = 0, 0, 0
  fill = fill and cat ~= "seller"
  for _, e in ipairs(world[WORLD_DEF[cat].src] or {}) do
    if included(cat, e, g.small_ok, g.dups) then
      known = known + 1
      if cat == "monster" and e.small == true then small_known = small_known + 1 end
      if cat == "monster" and kc ~= nil then count_kind(kc, e) end
      if fill and (cat ~= "monster" or monster_shown(e.small == true, show)) then
        local ci, cj = cell_of(e.pos.x), cell_of(e.pos.z)
        local key = cell_key(ci, cj)
        local cell = g.cells[key]
        if not cell then cell = {}; g.cells[key] = cell end
        local l = cell[cat]
        if not l then l = {}; cell[cat] = l end
        l[#l + 1] = e
        local f = g.flat[cat]
        f[#f + 1] = e
        put_n = put_n + 1
        if not g.mini or ci < g.mini then g.mini = ci end
        if not g.maxi or ci > g.maxi then g.maxi = ci end
        if not g.minj or cj < g.minj then g.minj = cj end
        if not g.maxj or cj > g.maxj then g.maxj = cj end
      end
    end
  end
  return known, small_known, put_n
end

-- What a category's cells were filled for: true, or for monsters the pair of
-- toggles (they decide which monsters are in the cells); false when not filled.
local function fill_key(cat, show)
  if not cat_on(cat, show) then return false end
  if cat == "monster" then
    return (monster_shown(false, show) and 1 or 0) + (monster_shown(true, show) and 2 or 0)
  end
  return true
end

-- The grid is built for the small-monster setting (it decides which monsters
-- count as known); every category toggle only decides which categories get
-- cells, and a category is filled later by add_cat when it turns on.
local function build_grid(world, show)
  M.world_stats.grid_builds = M.world_stats.grid_builds + 1
  local g = { cells = {}, flat = {}, known = {}, filled = {}, known_small = 0,
    small_ok = monster_shown(true, show),
    dups = treasure_dups(world) }
  g.kinds = { large = {}, small = {} }
  for _, cat in ipairs(M.WORLD_CATS) do
    g.known[cat] = 0
    g.flat[cat] = {}
    M.world_stats.cell_entries[cat] = 0
    if not special_cat(cat) then
      local key = fill_key(cat, show)
      local known, small_known, put_n = walk_cat(g, world, cat, key, show, g.kinds)
      g.known[cat] = known
      if cat == "monster" then g.known_small = small_known end
      g.filled[cat] = key
      M.world_stats.cell_entries[cat] = put_n
    end
  end
  return g
end

-- A category that turned on after the grid was built (or a monster toggle that
-- changed which monsters are shown): fill its cells now, never rebuild.
local function add_cat(g, world, cat, show)
  g.filled[cat] = fill_key(cat, show)
  if cat == "seller" then return end   -- sellers are a plain list, never in cells
  if cat == "monster" then   -- drop what an earlier fill put in
    for _, cell in pairs(g.cells) do cell.monster = nil end
    g.flat.monster = {}
  end
  local _, _, put_n = walk_cat(g, world, cat, true, show)
  M.world_stats.cell_entries[cat] = put_n
end

function M.world_markers_cached(world, show, origin, boxes, quest_cids, stats, fx)
  world = world or {}
  show = show or {}
  stats = stats or M.world_stats
  local small_ok = monster_shown(true, show)
  local g = grid_cache.grid
  if grid_cache.world ~= world or grid_cache.small ~= small_ok or not g then
    g = build_grid(world, show)
    grid_cache.world, grid_cache.small, grid_cache.grid = world, small_ok, g
  end
  local panel = new_panel()
  for _, cat in ipairs(M.WORLD_CATS) do panel[cat].known = g.known[cat] end
  panel.monster.small_known = g.known_small
  local cap = world_cap(show)
  local has_origin = valid_pos(origin)
  local ctx = world_ctx(show, boxes)
  -- chest labels depend only on the entry, so they live as long as the grid
  g.labels = g.labels or {}
  ctx.labels = g.labels
  local on = {}
  for _, cat in ipairs(M.WORLD_CATS) do
    if not special_cat(cat) and cat_on(cat, show) then
      if g.filled[cat] ~= fill_key(cat, show) then add_cat(g, world, cat, show) end
      on[#on + 1] = cat
    end
  end

  -- SPEC 19.8.3: with a query only entries whose cached haystack matches
  -- reach make_cand; the per-query memos live as long as the grid, the
  -- haystacks themselves carry across grids in the identity cache (SPEC 28.4.3).
  local q = show.search
  g.hay = g.hay or {}
  local kept, merged, shops, shop_all, hits = {}, {}, {}, {}, {}
  local shop_of = {}
  local shops_on = show.world_shops == true
  if q ~= nil or shops_on then
    local sc, n
    sc, n, shop_of = shop_cands(world, q, ctx, g, shops_on)
    panel.shop.known = n
    for _, c in ipairs(sc) do
      stats.cand_builds = stats.cand_builds + 1
      if not c.hidden then
        world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
          shops_on, shop_all, hits)
      end
    end
  end
  if q ~= nil then
    -- v14 (SPEC 22.7.3): the NPC matches, after the shops; not grid-bound,
    -- they number at most the name list.
    local matches = M.npc_matches(world.npcs, q)
    panel.npc_search.known = #matches
    for _, c in ipairs(npc_cands(matches, ctx)) do
      stats.cand_builds = stats.cand_builds + 1
      if not c.hidden then
        world_accept(c, has_origin, origin, quest_cids, kept, merged, shops,
          shop_of, shops_on, shop_all, hits)
      end
    end
  end
  local drops = q ~= nil and world.drops or nil
  -- the spot's candidate is built once per world table (the grid is rebuilt
  -- for a new one); the toggle is read every tick
  local ft
  if show.world_first_token ~= false then
    if g.ft_src ~= world.first_token then
      g.ft_src, g.ft = world.first_token, first_token_cand(world, show)
    end
    ft = g.ft
  end
  ctx.spot = ft ~= nil
  -- v19 (SPEC 32.6): the related entries, kept on the grid record while the
  -- key is the same (the grid itself changes with the world table)
  local flist, fset = {}, {}
  if fx ~= nil then
    if g.fx_key ~= fx.key or g.fx_list == nil then
      g.fx_key = fx.key
      g.fx_list, g.fx_set = focus_entries(world, fx)
    end
    flist, fset = g.fx_list, g.fx_set
  end
  local function take(cat, e)
    if fset[e] then return end
    if cat == "monster" and kind_off(e, show) then return end
    if not entry_search(cat, e, drops, g, q, ctx) then return end
    stats.cand_builds = stats.cand_builds + 1
    local c = make_cand(cat, e, ctx)
    if not c.hidden then
      world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
        shops_on, shop_all, hits)
    end
  end

  -- Sellers: the full list, every call (the seller merge needs all of them).
  if show[WORLD_DEF.seller.toggle] ~= false then
    for _, e in ipairs(world.sellers or {}) do
      if valid_pos(e.pos) then take("seller", e) end
    end
  end

  if has_origin then
    if cap > 0 and g.mini then
      local oi, oj = cell_of(origin.x), cell_of(origin.z)
      local rmin = math.max(0, g.mini - oi, oi - g.maxi, g.minj - oj, oj - g.maxj)
      local rmax = math.max(math.abs(g.mini - oi), math.abs(g.maxi - oi),
        math.abs(g.minj - oj), math.abs(g.maxj - oj))
      local function read_cell(ci, cj)
        local cell = g.cells[cell_key(ci, cj)]
        if not cell then return end
        for _, cat in ipairs(on) do
          local l = cell[cat]
          if l then
            for _, e in ipairs(l) do take(cat, e) end
          end
        end
      end
      for r = rmin, rmax do
        if r >= 2 and #kept >= cap then
          -- Stop once the next ring cannot hold anything closer than the
          -- cap-th candidate (equal distances still read, ties go by key).
          local ds = {}
          for i, c in ipairs(kept) do ds[i] = c.d end
          table.sort(ds)
          local lim = (r - 1) * CELL
          if lim * lim > ds[cap] then break end
        end
        if r == 0 then
          read_cell(oi, oj)
        else
          for dj = -r, r do
            read_cell(oi - r, oj + dj)
            read_cell(oi + r, oj + dj)
          end
          for di = -r + 1, r - 1 do
            read_cell(oi + di, oj - r)
            read_cell(oi + di, oj + r)
          end
        end
      end
    end
  else
    for _, cat in ipairs(on) do
      if cat ~= "seller" then
        for _, e in ipairs(g.flat[cat]) do take(cat, e) end
      end
    end
  end
  merge_shops(kept, shops, shop_of, hits)
  return world_finish(kept, merged, panel, cap, has_origin, shops, shop_all,
    quest_cids, ft, g.kinds, related_cands(flist, world, show, boxes, q, g.labels))
end

-- The settlement nearest to pos by 3D distance (first wins a tie), or nil.
-- Settlements without a valid position are skipped.
function M.nearest_settlement(pos, settlements)
  local best, best_d = nil, nil
  for _, s in ipairs(settlements or {}) do
    if valid_pos(s.pos) then
      local d = dist2(pos, s.pos)
      if best_d == nil or d < best_d then best, best_d = s, d end
    end
  end
  return best
end

-- Is a marker a search result? v14: route and hint pins are not; the First
-- Seeker's Token spot is kept as a marker but listed nowhere (SPEC 28.9.3).
function M.is_result(m)
  if type(m) == "table" and m.objective == true then return false end
  return m.cat ~= "route_stop" and m.cat ~= "hint_pin" and not m.first_seeker
    and m.cat ~= "focus_npc" and m.cat ~= "focus_place" and not m.focus_kept
end

-- v19 (SPEC 32): the focused quests that are still live, tracked first, then
-- focus_qids in order; numbers above 0 only, no repeats, minus quests whose
-- state is completed, failed or canceled.
function M.focus_active(focus_qids, tracked_qid, adapter)
  local out, seen = {}, {}
  local function add(q)
    if type(q) ~= "number" or q <= 0 or seen[q] then return end
    seen[q] = true
    local st = adapter.quest_state(q)
    if st == "completed" or st == "failed" or st == "canceled" then return end
    out[#out + 1] = q
  end
  add(tracked_qid)
  for _, q in ipairs(type(focus_qids) == "table" and focus_qids or {}) do add(q) end
  return out
end

-- The `limit` (default WORLD_ROWS, ten) nearest entries to origin as panel
-- rows (SPEC 17.4g); all of them in list order when origin is nil.
-- Settlement = nearest by 3D distance. Shop entries carry stock, sells_for,
-- merged and offmap onto their row (SPEC 20.5.3-7).
function M.world_rows(entries, settlements, origin, limit)
  local list = {}
  for _, e in ipairs(entries or {}) do
    if M.is_result(e) then
      local i = #list + 1
      list[i] = { e = e, i = i, d = valid_pos(origin) and dist2(e.pos, origin) or 0 }
    end
  end
  if valid_pos(origin) then
    table.sort(list, function(x, y)
      if x.d ~= y.d then return x.d < y.d end
      if x.e.key ~= y.e.key then return tostring(x.e.key) < tostring(y.e.key) end
      return x.i < y.i
    end)
  end
  local rows = {}
  for i = 1, math.min(limit or M.WORLD_ROWS, #list) do
    local e = list[i].e
    local best = M.nearest_settlement(e.pos, settlements)
    local text = tostring(e.label)
    if e.why then text = text .. " - " .. tostring(e.why) end
    if best ~= nil then text = text .. " - near " .. tostring(best.name) end
    if e.merged then text = text .. " - quest marker"
    elseif e.offmap then text = text .. " (not on map)" end
    rows[i] = { text = text, pos = pos_copy(e.pos),
      key = e.key, stock = e.stock, sells_for = e.sells_for,
      merged = e.merged, offmap = e.offmap }
  end
  return rows
end

-- v9 (SPEC 16.3b-f): quest-tree detail helpers.
M.JOURNAL_CAP = 12
M.TREE_ORIGIN_MAX_AGE = 3.0

-- The tree origin is trusted only while fresh (under 3 s old).
function M.tree_origin(origin, stamp, now)
  if origin ~= nil and stamp ~= nil and now ~= nil
    and now - stamp < M.TREE_ORIGIN_MAX_AGE then
    return origin
  end
  return nil
end

-- Nearest startable / in-progress record by numeric dist; ties -> lower qid.
function M.nearest(quests)
  local best = nil
  for _, r in ipairs(quests or {}) do
    if (r.cat == "startable" or r.cat == "in_progress")
      and type(r.dist) == "number" then
      if best == nil or r.dist < best.dist
        or (r.dist == best.dist and r.qid < best.qid) then
        best = r
      end
    end
  end
  return best
end

local function journal_pass(read, prev, always, expanded, now, reuse)
  local out = {}
  local function take(q)
    local shared = reuse and reuse[q]
    local v
    if type(shared) == "table" and shared.read_at == now then
      v = {}
      for k, value in pairs(shared) do v[k] = value end
    else
      v = read(q)
      if type(v) ~= "table" then v = { missing = true } end
      v.read_at = now
    end
    out[q] = v
  end
  for _, q in ipairs(always) do take(q) end
  -- Expanded rows: never-read first, then oldest-read; qid breaks ties.
  local ranked = {}
  for _, q in ipairs(expanded) do ranked[#ranked + 1] = q end
  table.sort(ranked, function(x, y)
    local px, py = prev[x], prev[y]
    if (px == nil) ~= (py == nil) then return px == nil end
    if px ~= nil and px.read_at ~= py.read_at then
      return (px.read_at or 0) < (py.read_at or 0)
    end
    return x < y
  end)
  for i, q in ipairs(ranked) do
    if i <= M.JOURNAL_CAP then take(q)
    elseif prev[q] ~= nil then out[q] = prev[q] end
  end
  return out
end

-- Journal reads for the tracked quest, the nearest quest and the expanded
-- rows. Locked records are read only with spoilers on.
function M.journal_reads(adapter, quests, show, tracked_qid, nearest_qid, by_in, focus_journal)
  local by = by_in
  if by == nil then
    by = {}
    for _, r in ipairs(quests or {}) do by[r.qid] = r end
  end
  local spoilers = show.journal_spoilers and true or false
  local function allowed(q)
    local r = by[q]
    return r == nil or r.cat ~= "locked" or spoilers
  end
  local always, listed = {}, {}
  local function push(q)
    if q ~= nil and not listed[q] and allowed(q) then
      listed[q] = true
      always[#always + 1] = q
    end
  end
  push(tracked_qid)
  push(nearest_qid)
  local expanded = {}
  for q, on in pairs(show.expanded or {}) do
    if on and by[q] ~= nil and not listed[q] and allowed(q) then
      expanded[#expanded + 1] = q
    end
  end
  local now = show.now or 0
  local journal, journal_all = {}, nil
  if adapter.journal_now then
    journal = journal_pass(adapter.journal_now, show.prev_journal or {},
      always, expanded, now, focus_journal)
  end
  if spoilers and adapter.journal_all then
    journal_all = journal_pass(adapter.journal_all, show.prev_journal_all or {},
      always, expanded, now)
  end
  return journal, journal_all
end

-- All v9 per-record fields and reads for one tick (only called while the
-- tree records exist).
function M.tree_detail(adapter, quests, show, rec_by, focus_journal)
  local tracked_qid = adapter.tracked_qid and adapter.tracked_qid() or nil
  local origin = show.tree_origin
  local has_origin = type(origin) == "table" and type(origin.x) == "number"
    and type(origin.y) == "number" and type(origin.z) == "number"
  for _, r in ipairs(quests) do
    r.tracked = (tracked_qid ~= nil and r.qid == tracked_qid)
    if has_origin and r.pos ~= nil then r.dist = dist(r.pos, origin) end
    if r.cat == "startable" and r.giver ~= nil and adapter.npc_name then
      r.giver_name = adapter.npc_name(r.giver)
    end
  end
  local n = M.nearest(quests)
  local nearest_qid = n and n.qid or nil
  local journal, journal_all = M.journal_reads(adapter, quests, show,
    tracked_qid, nearest_qid, rec_by, focus_journal)
  return tracked_qid, nearest_qid, journal, journal_all
end

local function usable(e) return type(e) == "table" and not e.missing end

local function nonempty(s) return type(s) == "string" and s ~= "" end

-- Row label: the visible text, tags, then a stable ImGui id after ###.
function M.row_label(rec, nearest_qid, focused)
  local tags = ""
  if rec.tracked then tags = tags .. " [tracked]" end
  if rec.qid == nearest_qid then tags = tags .. " [nearest]" end
  return (focused and "[F] " or "") .. rec.name .. " - " .. rec.state .. (rec.waiting or "") .. tags
    .. "###qd_" .. rec.qid
end

local function step_lines(rec, j, ja, spoilers)
  if not spoilers or not usable(ja) or type(ja.steps) ~= "table" then return nil end
  local cat = rec and rec.cat or "in_progress"
  local cur = nil
  if cat == "in_progress" and usable(j) and type(j.step_index) == "number" then
    cur = j.step_index
  end
  local out = {}
  for i, s in ipairs(ja.steps) do
    local text = (type(s) == "table" and nonempty(s.base)) and s.base or ("Step " .. i)
    -- The game's message table marks developer-cut tasks "#Rejected#"; hide
    -- them but keep the original index i so the current-step marker stays
    -- aligned with the game's task index.
    if not text:find("#Rejected#", 1, true) then
      local prefix = ""
      if cat == "completed" then prefix = "done: "
      elseif cur ~= nil then
        if i <= cur then prefix = "done: "
        elseif i == cur + 1 then prefix = "> " end
      end
      out[#out + 1] = prefix .. text
    end
  end
  return out
end

-- Detail model for one expanded row (rec nil = the tracked quest without a
-- record). j = journal_now entry, ja = journal_all entry.
function M.row_detail(rec, j, ja, spoilers)
  local lines = {}
  local function add(s) if nonempty(s) then lines[#lines + 1] = s end end
  local cat = rec and rec.cat or "in_progress"
  local jump = nil
  local waiting = rec and nonempty(rec.waiting) and rec.waiting:gsub("^%s+", "") or nil
  if cat == "startable" then
    add("To start: talk to " .. (nonempty(rec.giver_name) and rec.giver_name or "the quest giver"))
    if nonempty(rec.region) then add("Region: " .. rec.region) end
    if usable(j) then add(j.summary) end
    add(waiting)
    jump = pos_copy(rec.pos)
  elseif cat == "in_progress" then
    if usable(j) then
      if nonempty(j.base) then add("Now: " .. j.base) end
      add(j.detail)
      for _, c in ipairs(j.checks or {}) do
        add((c.done and "[x] " or "[ ] ") .. tostring(c.text))
      end
      if type(j.dest) == "table" then
        if nonempty(j.dest.caption) then add("Destination: " .. j.dest.caption) end
        if j.dest.x ~= nil then jump = pos_copy(j.dest) end
      end
    end
    if jump == nil and rec ~= nil then jump = pos_copy(rec.pos) end
  elseif cat == "locked" then
    add(waiting)
  else
    if usable(j) then add(j.summary) end
    jump = pos_copy(rec.pos)
  end
  return { lines = lines, steps = step_lines(rec, j, ja, spoilers), jump = jump }
end

-- qid -> record for a compute result: compute's own map, else built (hand-
-- made results).
local function rec_index(result)
  if result.rec_by ~= nil then return result.rec_by end
  local by = {}
  for _, r in ipairs(result.quests) do by[r.qid] = r end
  return by
end

-- Tracked / nearest nodes above the regions.
function M.summary_nodes(result)
  local out = {}
  if type(result) ~= "table" or result.quests == nil then return out end
  local by = rec_index(result)
  local t, n = result.tracked_qid, result.nearest_qid
  local function dist_text(r) return string.format("%.0f m", r.dist) end
  if t ~= nil and n ~= nil and t == n and by[t] ~= nil and by[t].dist ~= nil then
    local r = by[t]
    out[#out + 1] = { qid = t, rec = r, label = "Tracked and nearest: " .. r.name
      .. " - " .. r.state .. ", " .. dist_text(r) .. "###qd_tracked" }
    return out
  end
  if t ~= nil then
    local r = by[t]
    if r ~= nil then
      out[#out + 1] = { qid = t, rec = r, label = "Tracked: " .. r.name .. " - "
        .. r.state .. "###qd_tracked" }
    else
      local je = result.journal and result.journal[t]
      if usable(je) and nonempty(je.name) then
        out[#out + 1] = { qid = t, rec = nil,
          label = "Tracked: " .. je.name .. "###qd_tracked" }
      end
    end
  end
  if n ~= nil and by[n] ~= nil and by[n].dist ~= nil then
    local r = by[n]
    out[#out + 1] = { qid = n, rec = r, label = "Nearest: " .. r.name .. " - "
      .. r.state .. ", " .. dist_text(r) .. "###qd_nearest" }
  end
  return out
end

-- Plain-text dump of the summary nodes and expanded rows (5 s dump and the
-- debug entry point). Works whatever the panel state.
function M.state_lines(result, expanded, spoilers)
  local out = {}
  if type(result) ~= "table" or result.quests == nil then return out end
  local function strip(label) return (label:gsub("###.*$", "")) end
  local function emit(head, rec, qid)
    out[#out + 1] = head
    local d = M.row_detail(rec, result.journal and result.journal[qid],
      result.journal_all and result.journal_all[qid], spoilers)
    for _, l in ipairs(d.lines) do out[#out + 1] = "  " .. l end
    for _, l in ipairs(d.steps or {}) do out[#out + 1] = "    " .. l end
    if d.jump then
      out[#out + 1] = string.format("  jump %.1f, %.1f, %.1f", d.jump.x, d.jump.y, d.jump.z)
    end
  end
  for _, node in ipairs(M.summary_nodes(result)) do
    emit(strip(node.label), node.rec, node.qid)
  end
  local ids = {}
  for q, on in pairs(expanded or {}) do if on then ids[#ids + 1] = q end end
  table.sort(ids)
  local by = rec_index(result)
  for _, q in ipairs(ids) do
    local r = by[q]
    if r ~= nil then
      emit("[" .. q .. "] " .. strip(M.row_label(r, result.nearest_qid)), r, q)
    end
  end
  return out
end

-- Journal readout line for the Status section (SPEC 16.3h).
function M.journal_line(stats)
  local jumps = (stats.on_target or 0) + (stats.off_target or 0)
    + (stats.timeout or 0) + (stats.canceled or 0)
  return string.format("Journal: %d read, %d text cached, %d failed, tracked %s; jumps %d: on target %d, off target %d, timed out %d, canceled %d",
    stats.read or 0, stats.cached or 0, stats.failed or 0,
    stats.tracked ~= nil and tostring(stats.tracked) or "none", jumps,
    stats.on_target or 0, stats.off_target or 0, stats.timeout or 0, stats.canceled or 0)
end

-- Matches the settings defaults.
local DEFAULT_SHOW = { startable = true, in_progress = true,
  completed = false, unavailable = false, locked = false, quest_items = true }

-- Giver resolution, candidate list (SPEC 5.9.1): the hint alone, else the
-- cast list without generic, non-positive or repeated ids.
local function giver_candidates(adapter, qid)
  local hint = adapter.giver_hint(qid)
  if hint ~= nil then return hint, { hint } end
  local cands, seen = {}, {}
  local cast = adapter.cast_ids(qid)
  if cast == nil then return hint, cands end
  for _, id in ipairs(cast) do
    if type(id) == "number" and id > 0 and not adapter.is_generic(id)
      and not seen[id] then
      seen[id] = true
      cands[#cands + 1] = id
    end
  end
  return hint, cands
end

-- Giver resolution, position (SPEC 5.9.3): the live cast NPC position, then
-- the catalog position, then (v10, SPEC 17.3b.1) a cast NPC's schedule
-- position and the atlas giver position, then the static point.
local function giver_position(adapter, qid, cands, static, world_in, givers)
  local pos
  if #cands == 1 or static == nil then
    for _, cid in ipairs(cands) do
      if adapter.npc_alive(cid) then
        local x, y, z = adapter.npc_pos(cid)
        if x ~= nil then
          return string.format("c:%d", cid), { x = x, y = y, z = z }
        end
      end
    end
    local x, y, z = adapter.catalog_pos(qid)
    if x ~= nil then
      pos = { x = x, y = y, z = z }
      return pos_key(pos), pos
    end
    local schedule = type(world_in) == "table" and world_in.schedule or nil
    if type(schedule) == "table" or type(givers) == "table" then
      local ids, seen = {}, {}
      for _, cid in ipairs(cands) do
        if not seen[cid] then seen[cid] = true; ids[#ids + 1] = cid end
      end
      for _, cid in ipairs(adapter.cast_ids(qid) or {}) do
        if type(cid) == "number" and not seen[cid] then
          seen[cid] = true; ids[#ids + 1] = cid
        end
      end
      for _, src in ipairs({ schedule or {}, givers or {} }) do
        for _, cid in ipairs(ids) do
          local p = src[cid]
          if valid_pos(p) and not near_zero(p) then
            return string.format("c:%d", cid), { x = p.x, y = p.y, z = p.z }
          end
        end
      end
    end
  end
  if static ~= nil then
    pos = { x = static.x, y = static.y, z = static.z }
    return pos_key(pos), pos
  end
  return nil
end

-- v19 (SPEC 32.5): the related NPCs, items and places of each focused quest.
-- Pure; the caller resolves each giver and the in-progress set into `live`.
-- The previous result table itself is returned while every input matches.
local related_memo = nil
local focus_names_memo = {}   -- cid -> name, cached on the identity of world.npcs

local function related_same(m, adapter, active, rel, places, needs, live, objs)
  if m == nil or m.adapter ~= adapter or m.rel ~= rel or m.places ~= places
    or m.needs ~= needs or m.progressing_known ~= live.progressing_known
    or #m.active ~= #active then
    return false
  end
  for i, qid in ipairs(active) do
    if m.active[i] ~= qid or m.givers[i] ~= live.givers[qid]
      or m.prog[i] ~= (live.prog[qid] == true) or m.objs[i] ~= objs[i] then
      return false
    end
  end
  return true
end

function M.related_sets(adapter, active, rel, places, live)
  local progressing_known = type(live) == "table" and type(live.prog) == "table"
  live = live or {}
  local givers, prog = live.givers or {}, live.prog or {}
  live = { givers = givers, prog = prog, progressing_known = progressing_known }
  local needs = adapter.item_needs and adapter.item_needs() or nil
  local objs = {}
  for i, qid in ipairs(active) do
    objs[i] = adapter.objective_cids and adapter.objective_cids(qid) or false
  end
  local m = related_memo
  if related_same(m, adapter, active, rel, places, needs, live, objs) then
    return m.result
  end

  local function good(c)
    return type(c) == "number" and c > 0 and not adapter.is_generic(c)
  end
  local result = {}
  for i, qid in ipairs(active) do
    local entry = type(rel) == "table" and rel[qid] or nil
    local npcs, nseen, step, sseen = {}, {}, {}, {}
    local function add(list, seen, c)
      if good(c) and not seen[c] then seen[c] = true; list[#list + 1] = c end
    end
    local function add_all(list, seen, src)
      for _, c in ipairs(type(src) == "table" and src or {}) do add(list, seen, c) end
    end
    local giver = givers[qid]
    local oc = objs[i] or nil
    add(npcs, nseen, giver)
    add_all(npcs, nseen, oc)
    add_all(npcs, nseen, adapter.cast_ids(qid))
    add_all(step, sseen, oc)
    if entry ~= nil then
      add_all(npcs, nseen, entry.cast)
      add_all(npcs, nseen, entry.npcs)
      for _, d in ipairs(type(entry.dest) == "table" and entry.dest or {}) do
        if type(d) == "table" then add(npcs, nseen, d.cid) end
      end
    end
    if not prog[qid] then add(step, sseen, giver) end

    local items, iseen = {}, {}
    local function add_item(id)
      if type(id) == "number" and not iseen[id] then iseen[id] = true; items[#items + 1] = id end
    end
    if entry ~= nil and type(entry.items) == "table" then
      for _, id in ipairs(entry.items) do add_item(id) end
    end
    if type(needs) == "table" and type(needs[qid]) == "table" then
      for _, n in ipairs(needs[qid]) do
        if type(n) == "table" then add_item(n.id) end
      end
    end

    local pl, pseen = {}, {}
    if entry ~= nil and type(places) == "table" and type(entry.dest) == "table" then
      for _, d in ipairs(entry.dest) do
        if type(d) == "table" and d.key ~= nil and places[d.key] ~= nil and not pseen[d.key] then
          pseen[d.key] = true; pl[#pl + 1] = d.key
        end
      end
      table.sort(pl)
    end
    local progressing
    if progressing_known then progressing = prog[qid] == true end
    result[qid] = { npcs = npcs, step_npcs = step, items = items, places = pl,
      progressing = progressing }
  end

  local keep_active, keep_givers, keep_prog = {}, {}, {}
  for i, qid in ipairs(active) do
    keep_active[i] = qid
    keep_givers[i] = givers[qid]
    keep_prog[i] = (prog[qid] == true)
  end
  related_memo = { adapter = adapter, active = keep_active, givers = keep_givers,
    prog = keep_prog, progressing_known = progressing_known,
    rel = rel, places = places, needs = needs, objs = objs, result = result }
  return result
end

-- v13 (SPEC 21.8.2): step reads for in-progress quests, newest data carried
-- through prev. Never-read first, then oldest; at most STEP_CAP reads per
-- tick and one per qid per STEP_MIN_AGE seconds.
M.STEP_CAP = 10
M.STEP_MIN_AGE = 5
function M.step_reads(adapter, qids, prev, now)
  local out = {}
  local ranked = {}
  for _, q in ipairs(qids) do
    local p = prev[q]
    if p ~= nil and now - (p.at or 0) < M.STEP_MIN_AGE then
      out[q] = p
    else
      ranked[#ranked + 1] = q
    end
  end
  table.sort(ranked, function(x, y)
    local px, py = prev[x], prev[y]
    if (px == nil) ~= (py == nil) then return px == nil end
    if px ~= nil and px.at ~= py.at then return (px.at or 0) < (py.at or 0) end
    return x < y
  end)
  local reads = 0
  for _, q in ipairs(ranked) do
    if reads < M.STEP_CAP then
      reads = reads + 1
      local ok, n = pcall(adapter.quest_step, q)
      if not ok or type(n) ~= "number" or n ~= math.floor(n) then n = nil end
      out[q] = { n = n, at = now }
    elseif prev[q] ~= nil then
      out[q] = prev[q]
    end
  end
  return out
end

-- SPEC 39.5: a small independent cache for current focused journal entries.
-- Each record is the plain journal value plus read_at; nil/failed reads are
-- represented as { missing = true, read_at = now }. A same-tick tree read is
-- shared, but this cache never changes or prunes the caller's tree cache.
M.FOCUS_JOURNAL_CAP = 2
M.FOCUS_JOURNAL_MIN_AGE = 2
function M.focus_journal_reads(read, active, prev, now, tree)
  prev, tree = prev or {}, tree or {}
  local out, live, ranked = {}, {}, {}
  for _, qid in ipairs(active or {}) do
    if type(qid) == "number" and not live[qid] then
      live[qid] = true
      local old = prev[qid]
      local shared = tree[qid]
      if type(shared) == "table" and shared.read_at == now then
        out[qid] = shared
      elseif old ~= nil and now - (old.read_at or 0) < M.FOCUS_JOURNAL_MIN_AGE then
        out[qid] = old
      else
        ranked[#ranked + 1] = qid
      end
    end
  end
  table.sort(ranked, function(a, b)
    local pa, pb = prev[a], prev[b]
    if (pa == nil) ~= (pb == nil) then return pa == nil end
    local aa, ab = pa and pa.read_at or 0, pb and pb.read_at or 0
    if aa ~= ab then return aa < ab end
    return a < b
  end)
  local reads = 0
  for _, qid in ipairs(ranked) do
    if reads < M.FOCUS_JOURNAL_CAP then
      reads = reads + 1
      local ok, value = pcall(read, qid)
      local rec = {}
      if ok and type(value) == "table" then
        for k, v in pairs(value) do rec[k] = v end
      else
        rec.missing = true
      end
      rec.read_at = now
      out[qid] = rec
    elseif prev[qid] ~= nil then
      out[qid] = prev[qid]
    end
  end
  return out
end

function M.compute(adapter, show)
  show = show or DEFAULT_SHOW
  local q = show.search
  local acceptable = adapter.acceptable_ids()
  local progressing = adapter.progressing_ids()
  if acceptable == nil or progressing == nil then return nil end
  local catalog = adapter.catalog_ids()   -- nil allowed: union degrades

  local prog, acc = {}, {}
  for _, qid in ipairs(progressing) do prog[qid] = true end
  for _, qid in ipairs(acceptable) do acc[qid] = true end

  local seen, qids, catalog_set = {}, {}, {}
  local function add(list, is_catalog)
    if list == nil then return end
    for _, qid in ipairs(list) do
      if type(qid) == "number" then
        if is_catalog then catalog_set[qid] = true end
        if not seen[qid] then
          seen[qid] = true
          qids[#qids + 1] = qid
        end
      end
    end
  end
  add(acceptable); add(progressing); add(catalog, true)
  table.sort(qids)

  local counts = { startable = 0, in_progress = 0, completed = 0,
    failed = 0, canceled = 0, giver_dead = 0, locked = 0 }
  local groups, order = {}, {}
  local unresolved, resolved_count = {}, 0
  -- Eager: a save with zero side quests still shows an empty tree.
  local quests, rec_by = nil, nil
  if show.tree_open and adapter.quest_region then quests, rec_by = {}, {} end
  local shown_inprog = {}   -- v8: in-progress qids that survive the visibility drop
  local catalog_side_count = 0

  -- v19 (SPEC 32): the focused quests that are live. focus_inprog is set here,
  -- before the loop, whose first statement drops main quests.
  local active = M.focus_active(show.focus_qids, show.focus_tracked_qid, adapter)
  local fset, focus_inprog, focus_rec, focus_cat = {}, {}, {}, {}
  for _, qid in ipairs(active) do
    fset[qid] = true
    if prog[qid] then focus_inprog[qid] = true end
  end

  for _, qid in ipairs(qids) do
    repeat
      local side_quest = adapter.is_side(qid)
      if not side_quest and not fset[qid] then break end
      if side_quest and catalog_set[qid] then catalog_side_count = catalog_side_count + 1 end

      local hint, cands
      local function get_candidates()
        if cands == nil then hint, cands = giver_candidates(adapter, qid) end
        return hint, cands
      end

      -- Category: specific before generic (SPEC §9.2).
      local cat
      if prog[qid] then
        cat = "in_progress"
      else
        local st = adapter.quest_state(qid)
        -- An unexpected state string must not crash the tick: treat it as
        -- no state rather than indexing counts/GROUP with an unknown key.
        if st ~= nil and not VALID_STATE[st] then st = nil end
        if st ~= nil then
          cat = st
        elseif acc[qid] then
          -- An unknown NPC counts as alive; only a dead giver lands here.
          get_candidates()
          local sole = (hint ~= nil and hint)
            or (#cands == 1 and cands[1]) or nil
          if sole ~= nil and not adapter.npc_alive(sole) then
            cat = "giver_dead"
          else
            cat = "startable"
          end
        else
          cat = "locked"
        end
      end

      if side_quest then counts[cat] = counts[cat] + 1 end
      -- v7 (SPEC 14.3b): tree records, built only while the panel is open,
      -- BEFORE the visibility break and any position work. Hidden
      -- categories still get a record; ascending qid order is inherited.
      local nm
      if quests ~= nil and side_quest then
        nm = adapter.quest_name(qid)
        local nameless = (nm == nil or nm == "")
        if not (cat == "locked" and nameless) then
          local waiting = nil
          if cat == "startable" or cat == "locked" then
            local e = nil
            if cat == "startable" then
              if adapter.gate_qids then e = adapter.gate_qids(qid) end
            else
              if adapter.tree_gate_qids then e = adapter.tree_gate_qids(qid) end
            end
            if type(e) == "table" and #e > 0 then
              waiting = gate_suffix(e, adapter, show)
            end
          end
          local rec = {
            qid = qid, cat = cat, state = STATE_TEXT[cat],
            grp = GROUP[cat],
            name = nameless and ("Quest " .. qid) or nm,
            region = adapter.quest_region(qid) or "Elsewhere",
            waiting = waiting,
          }
          quests[#quests + 1] = rec
          rec_by[qid] = rec
        end
      end
      -- Visibility BEFORE resolution: hidden quests never reach groups,
      -- labels, unresolved, or unnamed (SPEC §9.3).
      if not show[GROUP[cat]] and not fset[qid] then break end
      if side_quest and cat == "in_progress" and show[GROUP[cat]] then shown_inprog[qid] = true end
      if fset[qid] then
        get_candidates()
        focus_rec[qid] = { hint = hint, first = cands[1] }
        focus_cat[qid] = cat
      end
      -- A locked quest that no name source can label (no log entry, nothing
      -- learned, nothing in the game's text files) gets no marker rather
      -- than a "Quest <qid>" placeholder. An empty name counts as no name.
      if quests == nil then nm = adapter.quest_name(qid) end
      if cat == "locked" and (nm == nil or nm == "") then break end

      get_candidates()

      local static = adapter.static_pos(qid)

      local key, pos
      -- v5 (SPEC 12.3d): an in-progress quest anchors to its objective
      -- NPC when the adapter can name one. Guarded: an adapter without
      -- objective_cids behaves exactly as v4. NOT gated by giver_position's multi-cast rule.
      local objective_tried = 0
      if cat == "in_progress" then
        local oc = adapter.objective_cids and adapter.objective_cids(qid)
        if type(oc) == "table" then
          for _, ocid in ipairs(oc) do
            if type(ocid) == "number" and ocid > 0
              and not adapter.is_generic(ocid) then
              objective_tried = objective_tried + 1
              if adapter.npc_alive(ocid) then
                local ox, oy, oz
                if adapter.objective_pos ~= nil then
                  ox, oy, oz = adapter.objective_pos(ocid)
                else
                  ox, oy, oz = adapter.npc_pos(ocid)
                end
                if ox ~= nil then
                  key, pos = string.format("c:%d", ocid),
                    { x = ox, y = oy, z = oz }
                  break
                end
              end
            end
          end
        end
      end
      if key == nil then
        key, pos = giver_position(adapter, qid, cands, static,
          show.world, show.world_givers)
      end

      if key == nil then
        local reason
        if objective_tried > 0 then
          reason = "objective NPC position unavailable ("
            .. objective_tried .. " cand)"
        elseif #cands == 0 then
          reason = "no giver NPC known"
        else
          reason = "giver position unavailable (" .. #cands .. " cand)"
        end
        unresolved[qid] = { reason = reason, name = adapter.quest_name(qid) }
        break
      end

      resolved_count = resolved_count + 1
      -- v9 (SPEC 16.3f): the record carries this tick's raw position and
      -- the giver (c-key cid, else the hint). Hidden and unresolved
      -- quests never reach this line, so they keep pos/giver nil.
      local g = groups[key]
      if g == nil then
        g = { key = key, pos = pos, qids = {}, raw_cats = {}, inprog = {} }
        groups[key] = g
        order[#order + 1] = key
      end
      local rec = rec_by and rec_by[qid]
      if rec ~= nil then
        rec.pos = { x = pos.x, y = pos.y, z = pos.z }
        rec.giver = M.marker_cid(g) or hint
      end
      if focus_rec[qid] ~= nil then
        focus_rec[qid].cid = M.marker_cid(g)
        focus_rec[qid].key = key
        focus_rec[qid].pos = pos_copy(pos)
      end
      g.qids[#g.qids + 1] = qid
      g.raw_cats[qid] = cat
      if cat == "in_progress" then g.inprog[#g.inprog + 1] = qid end
    until true
  end

  local markers, unnamed = {}, {}
  for _, key in ipairs(order) do
    local g = groups[key]
    table.sort(g.qids)
    local cats, best = {}, nil
    for i, qid in ipairs(g.qids) do
      cats[i] = g.raw_cats[qid]
      local grp = GROUP[cats[i]]
      if best == nil or PRECEDENCE[grp] < PRECEDENCE[best] then best = grp end
    end
    g.label, g.hover = label_for(g.qids, cats, adapter, unnamed, show)
    g.cat = best
    g.raw_cats = nil
    -- SPEC 19.8.1: filtered before the item markers and quest_by_cid
    if q == nil or query_match(q, quest_hay(adapter, g)) then
      markers[#markers + 1] = g
    else
      for _, qid in ipairs(g.qids) do
        if fset[qid] then
          g.focus_kept = true
          markers[#markers + 1] = g
          break
        end
      end
    end
  end

  -- v19 (SPEC 32.5): the related sets of the focused quests. A giver is the
  -- hint, else the marker's NPC (not in progress), else the first candidate.
  local focus_result, fx
  if #active > 0 then
    local givers = {}
    for qid, rec in pairs(focus_rec) do
      givers[qid] = rec.hint or (not prog[qid] and rec.cid) or rec.first
    end
    local rs = M.related_sets(adapter, active, show.quest_rel,
      (show.world or {}).focus_places, { givers = givers, prog = prog })
    focus_result = { active = active, quests = rs }
    -- v19 (SPEC 32.6): what the world entries are matched against
    local qset, iset, qs, is = {}, {}, {}, {}
    for _, qid in ipairs(active) do
      if not qset[qid] then qset[qid] = true; qs[#qs + 1] = qid end
      for _, id in ipairs(rs[qid] and rs[qid].items or {}) do
        if not iset[id] then iset[id] = true; is[#is + 1] = id end
      end
    end
    table.sort(qs)
    table.sort(is)
    fx = { qids = qset, items = iset,
      key = table.concat(qs, ",") .. "|" .. table.concat(is, ",") }
  end

  -- v13 (SPEC 21.8): current step of a lone in-progress quest per marker.
  -- v14 (SPEC 22.11.3): hint qids join the same read list and throttle,
  -- whatever step_icons says.
  local quest_steps, hint_steps
  local hint_qids = type(show.hint_qids) == "table" and show.hint_qids or {}
  if (show.step_icons or #hint_qids > 0) and adapter.quest_step ~= nil then
    local want, listed = {}, {}
    if show.step_icons then
      for _, m in ipairs(markers) do
        if m.cat == "in_progress" and #m.inprog == 1 and not listed[m.inprog[1]] then
          listed[m.inprog[1]] = true
          want[#want + 1] = m.inprog[1]
        end
      end
    end
    for _, hq in ipairs(hint_qids) do
      if type(hq) == "number" and not listed[hq] then
        listed[hq] = true
        want[#want + 1] = hq
      end
    end
    quest_steps = M.step_reads(adapter, want, show.prev_quest_steps or {}, show.now or 0)
    if show.step_icons then
      for _, m in ipairs(markers) do
        if m.cat == "in_progress" and #m.inprog == 1 then
          local e = quest_steps[m.inprog[1]]
          local n = e and e.n
          if type(n) == "number" and n >= 1 and n <= 5 then m.step = n end
        end
      end
    end
    for _, hq in ipairs(hint_qids) do
      local e = quest_steps[hq]
      if e and type(e.n) == "number" then
        hint_steps = hint_steps or {}
        hint_steps[hq] = e.n
      end
    end
  end
  for _, m in ipairs(markers) do m.inprog = nil end

  local focus_journal = {}
  if adapter.journal_now ~= nil then
    local focus_in_progress = {}
    for _, qid in ipairs(active) do
      if prog[qid] then focus_in_progress[#focus_in_progress + 1] = qid end
    end
    focus_journal = M.focus_journal_reads(adapter.journal_now,
      focus_in_progress, show.prev_focus_journal or {}, show.now or 0)
  end
  if focus_result ~= nil then
    local related_controlled = type(show.focus_related_qids) == "table"
    local related_on = {}
    for _, qid in ipairs(show.focus_related_qids or {}) do related_on[qid] = true end
    local needs = adapter.item_needs and adapter.item_needs() or {}
    for _, qid in ipairs(active) do
      local cat = focus_cat[qid]
      local rec = focus_result.quests[qid]
      rec.name = adapter.quest_name(qid)
      local objective = { qid = qid, step = nil, npcs = {}, place = nil,
        npc_positions = {}, items = {}, item_sources = {}, known = false, resolved = false }
      if cat == "in_progress" and show.objective_snapshot == nil then
        local j = focus_journal[qid]
        if type(j) == "table" and not j.missing then
          if type(j.step_index) == "number" and j.step_index >= 0
            and j.step_index == math.floor(j.step_index) then objective.step = j.step_index end
          local d = j.dest
          if type(d) == "table" and valid_pos(d) then
            local p = { x = d.x, y = d.y, z = d.z, caption = d.caption }
            p.key = M.match_destination_key(qid, p, show.quest_rel,
              (show.world or {}).focus_places)
            objective.place = p
          end
        end
        local issued = adapter.objective_issued_cids
          and adapter.objective_issued_cids(qid) or nil
        local seen_npcs = {}
        for _, cid in ipairs(type(issued) == "table" and issued or {}) do
          if type(cid) == "number" and cid > 0 and cid == math.floor(cid)
            and not adapter.is_generic(cid) and not seen_npcs[cid] then
            seen_npcs[cid] = true; objective.npcs[#objective.npcs + 1] = cid
          end
        end
        -- The adapter's issued list is already deterministic and sticky.
        -- Preserve its order for marker and route priority.
        local seen_items = {}
        for _, n in ipairs(type(needs) == "table" and needs[qid] or {}) do
          if type(n) == "table" and type(n.id) == "number" then
            if not seen_items[n.id] then
              seen_items[n.id] = true
              objective.items[#objective.items + 1] = n.id
            end
          end
        end
        table.sort(objective.items)
      elseif cat == "startable" then
        local giver = focus_rec[qid] and (focus_rec[qid].cid
          or focus_rec[qid].hint or focus_rec[qid].first) or nil
        if type(giver) == "number" and giver > 0 and not adapter.is_generic(giver) then
          objective.npcs[1] = giver
        end
      end
      objective.known = #objective.npcs > 0 or objective.place ~= nil or #objective.items > 0
      for _, cid in ipairs(objective.npcs) do
        if adapter.npc_alive(cid) ~= false then
          local x, y, z
          local resolved_pos = cat == "startable" and focus_rec[qid]
            and focus_rec[qid].pos or nil
          if resolved_pos ~= nil then
            x, y, z = resolved_pos.x, resolved_pos.y, resolved_pos.z
          elseif cat == "in_progress" and adapter.objective_pos ~= nil then
            x, y, z = adapter.objective_pos(cid)
          else
            x, y, z = adapter.npc_pos(cid)
          end
          if x ~= nil and finite(x) and finite(y) and finite(z) then
            objective.npc_positions[cid] = { x = x, y = y, z = z }
            objective.resolved = true
          end
        end
      end
      if objective.place ~= nil then objective.resolved = true end
      rec.objective = objective
      rec.show_related = not related_controlled or related_on[qid] == true
      rec.related_shown, rec.related_hidden = 0, 0
    end
  end
  local tracked_qid, nearest_qid, journal, journal_all
  if quests ~= nil then
    tracked_qid, nearest_qid, journal, journal_all = M.tree_detail(adapter, quests,
      show, rec_by, focus_journal)
  end

  -- v8 (SPEC 15.3h): item markers, appended AFTER every quest marker
  local item_capped = 0
  local item_toggles = show.quest_items and show.in_progress
  if (item_toggles or (show.objective_snapshot == nil and next(focus_inprog) ~= nil))
      and adapter.item_needs ~= nil then
    local ims
    ims, item_capped = M.item_markers(adapter, item_toggles and shown_inprog or {},
      show.origin, q, focus_inprog)
    for _, m in ipairs(ims) do markers[#markers + 1] = m end
  end

  -- Attach the chosen drawable current-item source to the objective snapshot.
  if focus_result ~= nil and show.objective_snapshot == nil then
    for _, qid in ipairs(active) do
      local objective = focus_result.quests[qid].objective
      for _, id in ipairs(objective.items or {}) do
        local best, best_d2
        for _, m in ipairs(markers) do
          if m.cat == "quest_item" and m.item_id == id then
            local d2 = valid_pos(show.origin) and dist2(m.pos, show.origin) or 0
            if best == nil or d2 < best_d2 or (d2 == best_d2 and m.key < best.key) then
              best, best_d2 = m, d2
            end
          end
        end
        if best ~= nil then
          objective.item_sources[id] = { key = best.key, pos = pos_copy(best.pos),
            name = adapter.item_name and adapter.item_name(id) or nil }
          objective.resolved = true
        end
      end
    end
    local owners_by_item = {}
    for _, qid in ipairs(active) do
      local objective = focus_result.quests[qid].objective
      for _, id in ipairs(objective.items or {}) do
        local owners = owners_by_item[id] or {}
        owners[#owners + 1] = qid
        owners_by_item[id] = owners
      end
    end
    for _, m in ipairs(markers) do
      local owners = owners_by_item[m.item_id]
      if m.cat == "quest_item" and owners ~= nil then
        table.sort(owners)
        m.objective, m.objective_qids = true, owners
      end
    end
  end

  -- v10 (SPEC 17.4): world markers, appended AFTER every item marker. The
  -- seller merge runs here, once the quest markers exist.
  local world_panel, fullmap_world
  local npc_rows, npc_match_cids = {}, {}
  if show.world then
    local boxes, quest_by_cid = {}, {}
    local locs = adapter.item_locations and adapter.item_locations() or nil
    for _, r in ipairs(locs or {}) do
      if type(r) == "table" and r.src == "box" and valid_pos(r.pos) then
        boxes[#boxes + 1] = r.pos
      end
    end
    for _, m in ipairs(markers) do
      local cid = M.marker_cid(m)
      if cid ~= nil and not m.focus_kept then quest_by_cid[cid] = m end
    end
    local wms, merged, cover
    wms, world_panel, merged, cover = M.world_markers_cached(show.world, show,
      show.world_origin, boxes, quest_by_cid, nil, fx)
    if q ~= nil then
      local matches = M.npc_matches(show.world.npcs, q)
      npc_match_cids = M.npc_match_cids(matches)
      npc_rows = M.npc_rows(matches, show.world_origin, cover)
    end
    for _, mg in ipairs(merged) do
      local qm = quest_by_cid[mg.cid]
      qm.hover = (qm.hover or qm.label or "") .. "\n" .. mg.line
    end
    for _, m in ipairs(wms) do markers[#markers + 1] = m end
    -- SPEC 20.12.1: a second selection around the map origin, for the full
    -- map only. Its panel and merged lines are dropped and its counters go
    -- to a throwaway table, so the player pass stays the one the stats describe.
    if valid_pos(show.map_origin) then
      fullmap_world = M.world_markers_cached(show.world, show,
        show.map_origin, boxes, quest_by_cid, { grid_builds = 0, cand_builds = 0 }, fx)
    end
  end

  -- v14 (SPEC 22.8.4, 22.11.3): the route stops and hint pins, outside the
  -- cap and the search filter. cid / stop and qid / i identify the icon.
  local undisc = show.world_undiscovered == true
  for _, route in ipairs(type(show.routes) == "table" and show.routes or {}) do
    if type(route) == "table" and type(route.stops) == "table"
      and type(route.cid) == "number" and route.place == nil then
      for n, s in ipairs(route.stops) do
        if type(s) == "table" and s.lead ~= true and valid_pos(s.pos)
          and (s.discovered ~= false or undisc) then
          -- SPEC 32.14.11.4: num is the number shown; a lead entry's first
          -- stop is the player, so its stops count from 1 after it.
          local num = tonumber(s.idx) or (route.lead == true and n - 1) or n
          markers[#markers + 1] = {
            key = string.format("r:%d:%d", math.floor(route.cid), math.floor(num)),
            cat = "route_stop", qids = {}, pos = pos_copy(s.pos),
            label = string.format("%s %02d-%02d", tostring(route.name),
              math.floor(tonumber(s.from) or 0), math.floor(tonumber(s.to) or 0)),
            cid = route.cid, stop = n, num = num, slot = route.slot }
        end
      end
    end
  end
  for _, p in ipairs(type(show.hint_pins) == "table" and show.hint_pins or {}) do
    if type(p) == "table" and type(p.qid) == "number" and type(p.i) == "number"
      and valid_pos(p.pos) then
      markers[#markers + 1] = {
        key = string.format("h:%d:%d", math.floor(p.qid), math.floor(p.i)),
        cat = "hint_pin", qids = {}, pos = pos_copy(p.pos),
        label = tostring(p.label or ""), qid = p.qid, i = p.i }
    end
  end

  -- v19 (SPEC 32.6.2): focus NPC and destination markers, then the hide/dim
  -- pass over both marker lists.
  local focus_counts
  if focus_result ~= nil then
    local rs = focus_result.quests
    local akey = {}
    for _, qid in ipairs(active) do akey[qid] = true end
    -- 1. cid -> covering marker key (first marker per cid)
    local cover_key, rel_keys = {}, {}
    local objective_cids, ancillary_owners = {}, {}
    for _, qid in ipairs(active) do
      local fq = rs[qid]
      local objective = fq and fq.objective or nil
      for _, cid in ipairs(objective and objective.npcs or {}) do
        if valid_pos(objective.npc_positions and objective.npc_positions[cid]) then
          objective_cids[cid] = true
        end
      end
    end
    -- A startable quest resolved only to a static/catalog map point still
    -- represents its giver. Promote that existing point in place so it keeps
    -- its label/hover and becomes one cid-addressable objective marker.
    for _, qid in ipairs(active) do
      local fq = rs[qid]
      local f = focus_rec[qid]
      local objective = fq and fq.objective or nil
      if focus_cat[qid] == "startable" and f ~= nil
        and type(f.key) == "string" and objective ~= nil then
        for _, cid in ipairs(objective.npcs or {}) do
          if valid_pos(objective.npc_positions and objective.npc_positions[cid]) then
            for _, m in ipairs(markers) do
              if m.key == f.key then
                m.cid = m.cid or cid
                m.objective = true
                local owners, found = m.objective_qids or {}, false
                for _, owner in ipairs(owners) do if owner == qid then found = true; break end end
                if not found then owners[#owners + 1] = qid end
                table.sort(owners)
                m.objective_qids = owners
                break
              end
            end
            break
          end
        end
      end
    end
    for _, qid in ipairs(active) do
      local fq = rs[qid]
      local objective = fq and fq.objective or nil
      local rel_npcs, rel_seen = {}, {}
      for _, cid in ipairs(fq and fq.npcs or {}) do
        if not objective_cids[cid] and not rel_seen[cid] then
          rel_seen[cid] = true
          rel_npcs[#rel_npcs + 1] = cid
          local owners = ancillary_owners[cid]
          if owners == nil then owners = {}; ancillary_owners[cid] = owners end
          owners[#owners + 1] = qid
        end
      end
      if fq ~= nil then fq.related_npcs = rel_npcs end
    end
    local hidden_ancillary = {}
    local renderable_cids, hidden_fallback_keys = {}, {}
    for cid, owners in pairs(ancillary_owners) do
      local shown = type(show.focus_related_qids) ~= "table"
      for _, owner in ipairs(owners) do
        if rs[owner] and rs[owner].show_related == true then shown = true end
      end
      if not shown and not objective_cids[cid] then hidden_ancillary[cid] = true end
    end
    local fallback_owners = {}
    for _, qid in ipairs(active) do
      local f = focus_rec[qid]
      if focus_cat[qid] == "in_progress" and f ~= nil and f.key ~= nil then
        local owners = fallback_owners[f.key] or {}
        owners[#owners + 1] = qid
        fallback_owners[f.key] = owners
      end
    end
    for key, owners in pairs(fallback_owners) do
      local shown = false
      for _, owner in ipairs(owners) do
        if rs[owner] and rs[owner].show_related == true then shown = true end
      end
      local cid = tonumber(tostring(key):match("^c:(%d+)$"))
      if not shown and not (cid ~= nil and objective_cids[cid]) then
        hidden_fallback_keys[key] = true
      end
    end
    local function hidden_pass(list)
      if list == nil then return end
      local n = 0
      for _, m in ipairs(list) do
        local cid = M.marker_cid(m)
        if cid == nil and (m.cat == "npc_search" or m.cat == "shop" or m.cat == "seller") then cid = m.cid end
        if type(cid) == "number" and valid_pos(m.pos)
          and adapter.npc_alive(cid) ~= false then renderable_cids[cid] = true end
        local explicit_result = q ~= nil and m.focus_kept ~= true and M.is_result(m)
        local hide = (cid ~= nil and hidden_ancillary[cid]) or hidden_fallback_keys[m.key]
        if not hide or explicit_result then
          if explicit_result and hide then m.related_search = true end
          n = n + 1; list[n] = m
        end
      end
      for i = #list, n + 1, -1 do list[i] = nil end
    end
    hidden_pass(markers)
    hidden_pass(fullmap_world)
    -- a world marker covers only when the full map also holds it (SPEC 32.6.2)
    local fm_keys
    if fullmap_world ~= nil then
      fm_keys = {}
      for _, m in ipairs(fullmap_world) do fm_keys[m.key] = true end
    end
    for _, m in ipairs(markers) do
      local cid = M.marker_cid(m)
      if cid == nil and (m.cat == "npc_search" or m.cat == "shop" or m.cat == "seller")
        and (fm_keys == nil or fm_keys[m.key]) then
        cid = m.cid
      end
      if type(cid) == "number" and cover_key[cid] == nil then cover_key[cid] = m.key end
    end
    -- 2. focus NPC markers
    local names
    local wn = (show.world or {}).npcs
    if type(wn) == "table" then
      if focus_names_memo.src ~= wn then
        local map = {}
        for _, e in ipairs(wn) do
          if type(e) == "table" and e.cid ~= nil and map[e.cid] == nil then map[e.cid] = e.name end
        end
        focus_names_memo.src, focus_names_memo.map = wn, map
      end
      names = focus_names_memo.map
    end
    local no_pos, seen_cid, added = {}, {}, 0
    for _, qid in ipairs(active) do
      local all = {}
      local function add_cid(cid)
        for _, old in ipairs(all) do if old == cid then return end end
        all[#all + 1] = cid
      end
      for _, cid in ipairs(rs[qid] and rs[qid].npcs or {}) do add_cid(cid) end
      for _, cid in ipairs(rs[qid] and rs[qid].objective and rs[qid].objective.npcs or {}) do
        if valid_pos(rs[qid].objective.npc_positions and rs[qid].objective.npc_positions[cid]) then add_cid(cid) end
      end
      for _, cid in ipairs(all) do
        if not seen_cid[cid] then
          seen_cid[cid] = true
          local covered = cover_key[cid]
          local objective_target = objective_cids[cid] == true
          local owners = ancillary_owners[cid] or {}
          local visible_related = false
          for _, owner in ipairs(owners) do
            local fq = rs[owner]
            if fq ~= nil and fq.show_related == true then visible_related = true end
          end
          local visible = objective_target or visible_related
          if covered ~= nil and visible then rel_keys[covered] = true end
          if adapter.npc_alive(cid) ~= false then
            local target_pos
            if objective_target then
              for _, owner in ipairs(active) do
                local p = rs[owner] and rs[owner].objective
                  and rs[owner].objective.npc_positions[cid]
                if valid_pos(p) then target_pos = p; break end
              end
            end
            local x, y, z
            if target_pos ~= nil then x, y, z = target_pos.x, target_pos.y, target_pos.z
            else x, y, z = adapter.npc_pos(cid) end
            if x == nil then
              if objective_target or #owners > 0 then no_pos[#no_pos + 1] = cid end
            elseif visible and covered == nil then
              local label = names and names[cid]
              if label == nil or label == "" then
                label = adapter.npc_name and adapter.npc_name(cid) or nil
              end
              if label == nil or label == "" then label = "NPC " .. cid end
              local objective_qids = {}
              for _, owner in ipairs(active) do
                for _, target in ipairs(rs[owner] and rs[owner].objective and rs[owner].objective.npcs or {}) do
                  if target == cid then objective_qids[#objective_qids + 1] = owner end
                end
              end
              table.sort(objective_qids)
              markers[#markers + 1] = { key = string.format("n:%d", cid), cat = "focus_npc",
                cid = cid, qids = {}, pos = { x = x, y = y, z = z }, label = label,
                objective = objective_target or nil, objective_qids = #objective_qids > 0 and objective_qids or nil }
              added = added + 1
            end
          end
          if covered ~= nil and visible and objective_target then
            local function annotate(list)
              for _, m in ipairs(list or {}) do
                if m.key == covered then
                  local oq, seen = m.objective_qids or {}, {}
                  for _, owner in ipairs(oq) do seen[owner] = true end
                  for _, owner in ipairs(active) do
                    for _, target in ipairs(rs[owner] and rs[owner].objective
                      and rs[owner].objective.npcs or {}) do
                      if target == cid and not seen[owner] then
                        seen[owner] = true; oq[#oq + 1] = owner
                      end
                    end
                  end
                  table.sort(oq)
                  m.objective, m.objective_qids = true, oq
                  return
                end
              end
            end
            annotate(markers)
            annotate(fullmap_world)
          end
        end
      end
    end
    -- Objective destinations are separate qid-addressed markers. Existing
    -- extracted-place markers within two metres are suppressed below.
    local objective_places = {}
    for _, qid in ipairs(active) do
      local objective = rs[qid] and rs[qid].objective or nil
      local p = objective and objective.place or nil
      if type(p) == "table" and valid_pos(p) then
        objective_places[#objective_places + 1] = { qid = qid, pos = p }
        local caption = p.caption
        if type(caption) ~= "string" or caption == "" then caption = adapter.quest_name(qid) end
        if caption == nil or caption == "" then caption = "Quest " .. qid end
        markers[#markers + 1] = { key = "o:p:" .. tostring(qid), cat = "focus_place",
          qid = qid, place = p.key, qids = {}, pos = pos_copy(p),
          label = "Objective: " .. caption, objective = true, objective_qids = { qid } }
        added = added + 1
      end
    end
    -- 3. ancillary/extracted destination markers, one per place key
    local fplaces = (show.world or {}).focus_places
    local pk, pseen = {}, {}
    for _, qid in ipairs(active) do
      for _, key in ipairs(rs[qid] and rs[qid].places or {}) do
        if not pseen[key] then pseen[key] = true; pk[#pk + 1] = key end
      end
    end
    for _, key in ipairs(pk) do
      local pp = type(fplaces) == "table" and fplaces[key] or nil
      local covered_by_objective = false
      if valid_pos(pp) then
        for _, o in ipairs(objective_places) do
          local dx, dy, dz = pp.x - o.pos.x, pp.y - o.pos.y, pp.z - o.pos.z
          if dx * dx + dy * dy + dz * dz <= 4 then covered_by_objective = true; break end
        end
      end
      if valid_pos(pp) and not covered_by_objective then
        local nms = {}
        for _, qid in ipairs(active) do
          for _, k2 in ipairs(rs[qid] and rs[qid].places or {}) do
            if k2 == key then
              nms[#nms + 1] = M.gate_name(qid, adapter, show.reveal_gate_names)
              break
            end
          end
        end
        markers[#markers + 1] = { key = "f:" .. tostring(key), cat = "focus_place",
          place = key, qids = {}, pos = pos_copy(pp), label = table.concat(nms, " / ") }
        added = added + 1
      end
    end
    local related_status, shown_n, hidden_n, per_quest_counts = {}, 0, 0, {}
    for cid, owners in pairs(ancillary_owners) do
      local x, y, z = adapter.npc_pos(cid)
      local positioned = (x ~= nil and finite(x) and finite(y) and finite(z))
        or renderable_cids[cid] == true
      if adapter.npc_alive(cid) ~= false and positioned then
        local shown = type(show.focus_related_qids) ~= "table"
        for _, owner in ipairs(owners) do
          if rs[owner] and rs[owner].show_related == true then shown = true end
        end
        related_status[cid] = shown
        if shown then shown_n = shown_n + 1 else hidden_n = hidden_n + 1 end
      end
    end
    for _, qid in ipairs(active) do
      local fq = rs[qid]
      local shown, hidden = 0, 0
      local route_related_npcs = {}
      for _, cid in ipairs(fq and fq.related_npcs or {}) do
        if related_status[cid] == true then shown = shown + 1
        elseif related_status[cid] == false then hidden = hidden + 1 end
        if fq ~= nil and fq.show_related == true and related_status[cid] == true then
          route_related_npcs[#route_related_npcs + 1] = cid
        end
      end
      if fq ~= nil then
        fq.related_shown, fq.related_hidden = shown, hidden
        fq.related_shown_count, fq.related_hidden_count = shown, hidden
        fq.route_related_npcs = route_related_npcs
      end
      per_quest_counts[qid] = { related_shown = shown, related_hidden = hidden }
    end
    focus_result.related_counts = { shown = shown_n, hidden = hidden_n,
      per_quest = per_quest_counts }
    -- SPEC 40: project one completed objective snapshot before focus hide/dim.
    -- Version-1 callers omit it and retain the existing quest-wide item path.
    local objective_route_publication
    if type(show.objective_snapshot) == "table" then
      local objective_policy = show.objective_policy or {}
      local marker_policy = {}
      for key, value in pairs(objective_policy) do marker_policy[key] = value end
      marker_policy.origin = show.origin
      local marker_projection
      markers, fullmap_world, marker_projection = M.objective_markers(markers, fullmap_world,
        show.objective_snapshot, marker_policy)
      local route_policy = {}
      for key, value in pairs(objective_policy) do route_policy[key] = value end
      route_policy.visible_objective_keys = marker_projection.visible_keys
      objective_route_publication = M.objective_routes(show.objective_snapshot,
        show.origin, route_policy)
      focus_result.objective_marker_projection = marker_projection
    end

    -- 4. the hide / dim pass
    local dim = show.focus_unrelated == 1
    local function related(m)
      if m.related_search == true then return false end
      if m.objective == true then return true end
      if m.cat == "focus_npc" or m.cat == "focus_place" or m.cat == "route_stop"
        or m.related or rel_keys[m.key] then return true end
      if m.cat == "hint_pin" and akey[m.qid] then return true end
      for _, qid in ipairs(m.qids or {}) do
        if akey[qid] then return true end
      end
      return false
    end
    local function pass(list, counts)
      local n = 0
      for i = 1, #list do
        local m = list[i]
        local keep = true
        if related(m) then
          if counts then counts.related = counts.related + 1 end
        elseif q ~= nil and M.is_result(m) then
          keep = true
        elseif dim then
          m.dim = true
          if counts then counts.dimmed = counts.dimmed + 1 end
        else
          keep = false
          if counts then counts.hidden = counts.hidden + 1 end
        end
        if keep then n = n + 1; list[n] = m end
      end
      for i = #list, n + 1, -1 do list[i] = nil end
    end
    focus_counts = { related = 0, added = added, dimmed = 0, hidden = 0, no_pos = no_pos,
      ancillary_shown = focus_result.related_counts and focus_result.related_counts.shown or 0,
      ancillary_hidden = focus_result.related_counts and focus_result.related_counts.hidden or 0,
      per_quest = focus_result.related_counts and focus_result.related_counts.per_quest or {},
      objective = 0 }
    focus_result.objective_routes = objective_route_publication
    pass(markers, focus_counts)
    if fullmap_world ~= nil then pass(fullmap_world) end
    for _, m in ipairs(markers) do
      if m.objective == true and valid_pos(m.pos) then focus_counts.objective = focus_counts.objective + 1 end
    end
  end

  return {
    markers = markers,
    unresolved = unresolved,
    unnamed = unnamed,
    counts = counts,
    catalog_side_count = catalog_side_count,
    resolved_count = resolved_count,
    quests = quests,
    rec_by = rec_by,
    item_capped = item_capped,
    world = world_panel,
    fullmap_world = fullmap_world,
    tracked_qid = tracked_qid,
    nearest_qid = nearest_qid,
    journal = journal,
    journal_all = journal_all,
    quest_steps = quest_steps,
    hint_steps = hint_steps,
    npc_rows = npc_rows,
    npc_match_cids = npc_match_cids,
    focus = focus_result,
    objective_snapshot = show.objective_snapshot,
    objective_routes = focus_result and focus_result.objective_routes or nil,
    focus_journal = focus_journal,
    focus_counts = focus_counts,
  }
end

-- The tree walk is wanted only while the panel was drawn within the last
-- second (pure; the caller supplies both timestamps).
function M.tree_wanted(now, open_at)
  return open_at ~= nil and now - open_at < 1.0
end

-- Match a live journal destination to one of this quest's extracted keys.
-- Position is authoritative; the extracted key only supplies stable metadata.
function M.match_destination_key(qid, dest, quest_rel, focus_places)
  if not valid_pos(dest) or type(quest_rel) ~= "table"
    or type(focus_places) ~= "table" then return nil end
  local entry = quest_rel[qid]
  local best, best_d2
  for _, d in ipairs(type(entry) == "table" and entry.dest or {}) do
    local key = type(d) == "table" and d.key or nil
    local pos = key ~= nil and focus_places[key] or nil
    if valid_pos(pos) then
      local d2 = dist2(dest, pos)
      if d2 <= 4 and (best_d2 == nil or d2 < best_d2
        or (d2 == best_d2 and key < best)) then
        best, best_d2 = key, d2
      end
    end
  end
  return best
end

-- Hysteresis: a marker's committed position moves only when the live one is
-- more than HYSTERESIS_UNITS away. Markers are rewritten to the committed
-- position so what is drawn always matches the signature.
function M.signature(markers, committed)
  local parts = {}
  local new_committed = {}
  for _, m in ipairs(markers) do
    local prev = committed[m.key]
    local c = prev
    if c == nil or dist(c, m.pos) > M.HYSTERESIS_UNITS then
      c = { x = m.pos.x, y = m.pos.y, z = m.pos.z }
    end
    new_committed[m.key] = c
    m.pos = c
    parts[#parts + 1] = string.format("%s=%d:%d:%d[%s]{%s}{%s}<%s>",
      m.key, math.floor(c.x), math.floor(c.y), math.floor(c.z),
      table.concat(m.qids, ","), m.label or "", m.hover or "",
      (m.cat or "") .. (m.done and "|d" or "") .. (m.faded and "|f" or "") .. (m.dim and "|m" or "") .. (m.step and ("|s" .. m.step) or "")
        .. (m.slot and ("|k" .. m.slot) or "")
        .. (m.objective and "|o" or "")
        .. (type(m.objective_key) == "string" and ("|ok" .. #m.objective_key .. ":" .. m.objective_key) or "")
        .. (type(m.objective_ordinal) == "number" and ("|oi" .. tostring(m.objective_ordinal)) or "")
        .. (function()
          local qids = {}
          for _, qid in ipairs(m.objective_qids or {}) do qids[#qids + 1] = qid end
          table.sort(qids)
          return #qids > 0 and ("|oq" .. table.concat(qids, ",")) or ""
        end)()
        .. (m.cat == "route_stop" and ("|t" .. tostring(m.stop)) or ""))
  end
  table.sort(parts)
  return table.concat(parts, "|"), new_committed
end

-- Route members (SPEC 39.8): for each active quest, emit its positioned
-- objective NPCs, direct destination/item, then shown positioned ancillary
-- NPCs, preserving order and uniqueness. The search target reserves one of
-- the eight slots until included. Returns list, n (published), total.
function M.objective_route_id(qid, kind)
  if type(qid) ~= "number" or not finite(qid) or qid <= 0
    or qid ~= math.floor(qid) or qid > 0x7FFFFFFF then return nil end
  local code = kind == "place" and 1 or kind == "item" and 2 or nil
  if code == nil then return nil end
  return -(0x10000000000 + qid * 4 + code)
end

function M.route_members(focus, quest_rel, places, target_cid, opt, name_of)
  local list, seen, inlist = {}, {}, {}
  local total = target_cid ~= nil and 1 or 0
  local active = focus ~= nil and focus.active or nil
  local mode = opt ~= nil and opt.routes or 0
  -- slots held back for the target while it is not yet in the list
  local function reserve() return (target_cid ~= nil and not inlist[target_cid]) and 1 or 0 end
  if active ~= nil and #active > 0 then
    local has_objective = false
    for _, qid in ipairs(active) do
      local q = focus.quests ~= nil and focus.quests[qid] or nil
      if q ~= nil and q.objective ~= nil then has_objective = true; break end
    end
    if has_objective then
      local groups, primary_seen = {}, {}
      for _, qid in ipairs(active) do
        local q = focus.quests ~= nil and focus.quests[qid] or nil
        local objective = q ~= nil and q.objective or nil
        local primary, ancillary = {}, {}
        local function add_primary(member)
          if member.cid == nil or not primary_seen[member.cid] then
            if member.cid ~= nil then primary_seen[member.cid] = true end
            primary[#primary + 1] = member
          end
        end
        if mode > 0 then
          local candidates = {}
          if objective ~= nil then
            for _, cid in ipairs(objective.npcs or {}) do
              if valid_pos(objective.npc_positions and objective.npc_positions[cid]) then
                candidates[#candidates + 1] = cid
              end
            end
          else
            local src = mode == 1 and q and q.step_npcs or q and q.npcs
            for _, cid in ipairs(src or {}) do candidates[#candidates + 1] = cid end
          end
          for _, cid in ipairs(candidates) do
            add_primary({ cid = cid, name = name_of(cid, nil) })
          end
        end
        if objective ~= nil and opt ~= nil and opt.places == true then
          local endpoint, kind, name
          local p = objective.place
          if type(p) == "table" and valid_pos(p) then
            endpoint, kind = pos_copy(p), "place"
            local caption = p.caption
            if type(caption) ~= "string" or caption == "" then caption = q.name end
            if type(caption) ~= "string" or caption == "" then caption = "Quest " .. qid end
            name = "Objective: " .. caption
          else
            local candidates = {}
            for _, id in ipairs(objective.items or {}) do
              local source = objective.item_sources and objective.item_sources[id]
              if type(source) == "table" and valid_pos(source.pos) then
                local d = valid_pos(opt.player) and dist2(source.pos, opt.player) or 0
                candidates[#candidates + 1] = { id = id, source = source, d = d }
              end
            end
            table.sort(candidates, function(a, b)
              if a.d ~= b.d then return a.d < b.d end
              return tostring(a.source.key) < tostring(b.source.key)
            end)
            local best = candidates[1]
            if best ~= nil then
              endpoint, kind = pos_copy(best.source.pos), "item"
              local item = best.source.name
              if type(item) ~= "string" or item == "" then item = "Item " .. tostring(best.id) end
              local quest = q.name
              if type(quest) ~= "string" or quest == "" then quest = "Quest " .. qid end
              name = "Objective: " .. item .. " (for " .. quest .. ")"
            end
          end
          if endpoint ~= nil then
            local cid = M.objective_route_id(qid, kind)
            if cid ~= nil then
              add_primary({ cid = cid, place = 0, direct = true, objective = true,
                qid = qid, kind = kind, name = name, pos = endpoint })
            end
          end
        end
        if mode == 2 and q ~= nil and q.show_related == true then
          local related = type(q.route_related_npcs) == "table"
            and q.route_related_npcs or (q.related_npcs or q.npcs or {})
          for _, cid in ipairs(related) do
            if not primary_seen[cid] then ancillary[#ancillary + 1] = { cid = cid, name = name_of(cid, nil) } end
          end
        end
        groups[#groups + 1] = { primary = primary, ancillary = ancillary }
      end
      local target_counted = target_cid ~= nil
      local function append(member)
        local cid = member.cid
        if cid == target_cid then
          if not target_counted then total = total + 1; target_counted = true end
          if not inlist[cid] and #list < ROUTE_CAP then
            list[#list + 1] = member; inlist[cid] = true
          end
        elseif cid == nil or not seen[cid] then
          total = total + 1
          if cid ~= nil then seen[cid] = true end
          if #list + reserve() < ROUTE_CAP then list[#list + 1] = member end
        end
      end
      -- SPEC 39.8: emit each quest's objective routes and shown ancillary
      -- routes together, preserving active-quest order under the cap.
      for _, group in ipairs(groups) do
        for _, member in ipairs(group.primary) do
          append(member)
        end
        for _, member in ipairs(group.ancillary) do append(member) end
      end
      return list, #list + reserve(), total
    end
    if mode > 0 then
      for _, qid in ipairs(active) do
        local q = focus.quests ~= nil and focus.quests[qid] or nil
        local src = q ~= nil and (mode == 1 and q.step_npcs or q.npcs) or nil
        for _, cid in ipairs(src or {}) do
          if not seen[cid] then
            seen[cid] = true
            if cid ~= target_cid then total = total + 1 end
            if cid == target_cid or #list + reserve() < ROUTE_CAP then
              list[#list + 1] = { cid = cid, name = name_of(cid, nil) }
              inlist[cid] = true
            end
          end
        end
      end
    end
    if opt ~= nil and opt.places == true and places ~= nil then
      -- SPEC 32.14.11.1: gather the candidates, order them (prev first, then
      -- nearest the player, then candidate order), keep one place per 150 m
      -- cluster, and publish the kept ones in candidate order.
      local pseen, cand = {}, {}
      for _, qid in ipairs(active) do
        local rel = quest_rel ~= nil and quest_rel[qid] or nil
        for _, d in ipairs(rel ~= nil and rel.dest or {}) do
          local key = d.key
          if key ~= nil and not pseen[key] and places[key] ~= nil then
            pseen[key] = true
            cand[#cand + 1] = { key = key, pos = places[key], ord = #cand + 1 }
          end
        end
      end
      local prev = opt.prev
      local player = opt.player
      local dp = {}
      if player ~= nil then
        for _, c in ipairs(cand) do
          if c.pos ~= nil then
            local dx, dz = c.pos.x - player.x, c.pos.z - player.z
            dp[c] = dx * dx + dz * dz
          end
        end
      end
      table.sort(cand, function(a, b)
        local pa = prev ~= nil and prev[a.key] == true
        local pb = prev ~= nil and prev[b.key] == true
        if pa ~= pb then return pa end
        if player ~= nil then
          local da, db = dp[a] or math.huge, dp[b] or math.huge
          if da ~= db then return da < db end
        end
        return a.ord < b.ord
      end)
      local kept = {}
      for _, c in ipairs(cand) do
        local near = false
        for _, k in ipairs(kept) do
          if k.pos ~= nil and c.pos ~= nil then
            local dx, dz = c.pos.x - k.pos.x, c.pos.z - k.pos.z
            if dx * dx + dz * dz <= MERGE_STOP_M * MERGE_STOP_M then near = true; break end
          end
        end
        if not near then kept[#kept + 1] = c end
      end
      table.sort(kept, function(a, b) return a.ord < b.ord end)
      for _, c in ipairs(kept) do
        total = total + 1
        if #list + reserve() < ROUTE_CAP then
          list[#list + 1] = { cid = -c.key, place = c.key, name = name_of(nil, c.key) }
        end
      end
    end
  end
  return list, #list + reserve(), total
end

-- v3 overhead layer (SPEC §10.2c): pure helpers, no sdk.
function M.marker_cid(m)
  if type(m) ~= "table" or type(m.key) ~= "string" then return nil end
  if m.cat == "focus_npc" then return m.cid end
  if m.objective == true and type(m.cid) == "number" then return m.cid end
  if m.objective == true and (m.cat == "npc_search" or m.cat == "shop" or m.cat == "seller") then
    return m.cid
  end
  return tonumber(m.key:match("^c:(%d+)$"))
end

function M.overhead_anchors(markers, prev_pos, cam, radius)
  local out = {}
  for _, m in ipairs(markers) do
    local cid = M.marker_cid(m)
    if cid ~= nil then
      -- marker.pos lives in map space, the camera in transform space
      -- (verified in-game: one NPC reads (564,10,-975) vs (-84,11,50) —
      -- SPEC §10.8b). A cid with no live-space position yet is always
      -- looked up; the cull applies only to positions from earlier live
      -- reads, which share the camera's space.
      local p = prev_pos[cid]
      local keep = true
      if p ~= nil then
        local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
        keep = dx * dx + dy * dy + dz * dz <= radius * radius
      end
      if keep then out[#out + 1] = { cid = cid, marker = m } end
    end
  end
  return out
end

-- v8 (SPEC 15.3l.1): item overhead points. Reads ONLY marker.live
-- (transform space, the camera's); marker.pos is map space (§10.8b) and
-- is never compared with the camera. Inclusive squared-distance cull.
-- Each point carries its own plain copy of `live` as `pos`, so the main
-- file stores the result as-is and derives no position itself.
function M.overhead_points(markers, cam, radius)
  local out, r2 = {}, radius * radius
  for _, m in ipairs(markers or {}) do
    if m.cat == "quest_item" and type(m.live) == "table" then
      local p = m.live
      local dx, dy, dz = p.x - cam.x, p.y - cam.y, p.z - cam.z
      if dx * dx + dy * dy + dz * dz <= r2 then
        out[#out + 1] = { marker = m, pos = { x = p.x, y = p.y, z = p.z } }
      end
    end
  end
  return out
end

-- v14 (SPEC 22.11.3): the one shared hint-pin list feeds every surface.
-- Unknown door state is visible; only a confirmed open passage drops its pin.
function M.filter_hint_pins(pins, masquerade_closed)
  local out = {}
  for _, p in ipairs(type(pins) == "table" and pins or {}) do
    if not (p.qid == 30040 and p.i == 1 and masquerade_closed == false) then
      out[#out + 1] = p
    end
  end
  return out
end

-- Fit prose to a measured width without changing its words. A word wider than
-- the line remains intact rather than being split into unreadable fragments.
function M.wrap_text(text, max_width, measure)
  local out = {}
  if type(text) ~= "string" or text == "" then return out end
  if type(max_width) ~= "number" or max_width <= 0 then return { text } end
  if type(measure) ~= "function" then measure = string.len end
  local line = nil
  for word in text:gmatch("%S+") do
    local candidate = line ~= nil and (line .. " " .. word) or word
    local ok, width = pcall(measure, candidate)
    if not ok or type(width) ~= "number" then width = #candidate end
    if line ~= nil and width > max_width then
      out[#out + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= nil then out[#out + 1] = line end
  return out
end

-- Keep one measured layout per text. Resizing the window or changing UI scale
-- replaces that entry; steady frames reuse it without measuring every word.
function M.wrap_text_cached(cache, text, cache_key, max_width, measure)
  if type(cache) ~= "table" then return M.wrap_text(text, max_width, measure) end
  local old = cache[text]
  if type(old) == "table" and old.key == cache_key then return old.lines end
  local lines = M.wrap_text(text, max_width, measure)
  cache[text] = { key = cache_key, lines = lines }
  return lines
end

function M.hint_wrap_width(window_x, cursor_x, padding, fallback)
  local width = finite(fallback) and fallback or 160
  if finite(window_x) and finite(cursor_x) then
    width = window_x - cursor_x - (finite(padding) and padding or 0)
  end
  return math.max(1, math.floor(width))
end

-- v14: route stops and hint pins are the fixed map-space points drawn in-world.
function M.route_overhead_points(markers)
  local out = {}
  for _, m in ipairs(markers or {}) do
    if m.cat == "route_stop" or m.cat == "hint_pin"
        or (m.cat == "focus_place" and m.objective == true) then
      out[#out + 1] = m
    end
  end
  return out
end

-- A failed compute retains the complete committed point-layer state. A
-- successful compute derives the route gate from the published routes and the
-- overhead points from the same marker list consumed by map and minimap.
function M.route_point_state(result, routes, prior_route_on, prior_has_pts, prior_pts)
  if type(result) ~= "table" then
    return prior_route_on == true, prior_has_pts == true, prior_pts or {}
  end
  local pts = M.route_overhead_points(result.markers)
  local route_on = false
  for _, route in ipairs(type(routes) == "table" and routes or {}) do
    if type(route.stops) == "table" and #route.stops > 0 then
      route_on = true
      break
    end
  end
  return route_on, route_on or #pts > 0, pts
end

-- v8 (SPEC 15.3a): the item round runs only while BOTH toggles are on;
-- otherwise the tick invalidates (zero managed calls). v19 (SPEC 32.6.1): the
-- round also runs while show.focus_on.
function M.item_walk_wanted(show)
  return show ~= nil and ((show.in_progress == true and show.quest_items == true)
    or show.world_sellers == true
    or (show.inventory_quest_marks == true and show.item_menu_open == true)
    or show.focus_on == true)
end

-- v14 (SPEC 22.10.1): "full" when the round also feeds the quest-item and
-- seller markers, "needs" when only the item menu marks want it. v19 (SPEC
-- 32.6.1): also "full" while show.focus_on.
function M.item_walk_mode(show)
  if show ~= nil and ((show.in_progress == true and show.quest_items == true)
    or show.world_sellers == true or show.focus_on == true) then
    return "full"
  end
  return "needs"
end

-- v4 minimap (SPEC §11.1): nearest-first in-radius selection, capped.
-- origin is anything indexable by .x/.y/.z; 3D distance, inclusive.
-- v8 (SPEC 15.3k): item markers compete on distance like quest markers
-- (in-game 2026-10-19 a tier below quests let 12 farther quest markers
-- crowd out an item 8 m away); `nearest` is the nearest of ALL.
function M.minimap_markers(markers, origin, radius, cap)
  if markers == nil or origin == nil then return {}, nil end
  local radius2, best = radius * radius, nil
  local lim = math.floor(cap)
  -- sel holds the best `lim` markers so far, ordered by (w, d2, key)
  local sel, n = {}, 0
  local function before(w1, d1, k1, e2)
    if w1 ~= e2.w then return w1 < e2.w end
    if d1 ~= e2.d2 then return d1 < e2.d2 end
    return k1 < e2.m.key
  end
  -- v10 (SPEC 17.4b): world markers (the categories in WORLD_DEF) take
  -- slots after quest and item markers.
  for _, m in ipairs(markers) do
    local dx = m.pos.x - origin.x
    local dy = m.pos.y - origin.y
    local dz = m.pos.z - origin.z
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 <= radius2 then
      if best == nil or d2 < best then best = d2 end
      -- quest and item markers 0, route stops and hint pins 1, world 2
      local w = 0
      if WORLD_DEF[m.cat] ~= nil then w = 2
      elseif m.cat == "route_stop" or m.cat == "hint_pin"
        or m.cat == "focus_place" then w = 1 end
      if lim >= 1 and (n < lim or before(w, d2, m.key, sel[n])) then
        local i = n < lim and n + 1 or n
        if n < lim then n = n + 1 end
        while i > 1 and before(w, d2, m.key, sel[i - 1]) do
          sel[i] = sel[i - 1]
          i = i - 1
        end
        sel[i] = { m = m, d2 = d2, w = w }
      end
    end
  end
  local out, nearest = {}, nil
  if best ~= nil then nearest = math.sqrt(best) end
  for i = 1, n do out[i] = sel[i].m end
  return out, nearest
end

-- v12 (SPEC 20.11, 20.12.2): the order the full map adds markers in.
-- Non-world markers first (input order), then world markers nearest to origin
-- first (ties by key). With no valid origin the input order is kept.
-- world_list, when non-nil, replaces the world markers of markers: with a
-- valid origin it is sorted the same way; without one it is appended in its
-- own order. Returns a new array of the same tables.
function M.fullmap_order(markers, origin, world_list)
  local has = valid_pos(origin)
  if not has and world_list == nil then
    -- no origin: markers keep their input order, world ones where they sat
    local same = {}
    for i, m in ipairs(markers) do same[i] = m end
    return same
  end
  local out = {}
  local src = world_list
  if src == nil then
    src = {}
    for _, m in ipairs(markers) do
      if WORLD_DEF[m.cat] ~= nil then src[#src + 1] = m else out[#out + 1] = m end
    end
  else
    for _, m in ipairs(markers) do
      if WORLD_DEF[m.cat] == nil then out[#out + 1] = m end
    end
  end
  if not has then
    for _, m in ipairs(src) do out[#out + 1] = m end
    return out
  end
  local world = {}
  for i, m in ipairs(src) do
    world[i] = { m = m, d = valid_pos(m.pos) and dist2(m.pos, origin) or math.huge }
  end
  table.sort(world, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return a.m.key < b.m.key
  end)
  for _, w in ipairs(world) do out[#out + 1] = w.m end
  return out
end

-- SPEC 20.12.4: the map-cursor origin step. cursor is the raw reading
-- ({x,y,z} or nil); returns the held origin and the time it was last taken.
M.MAP_REORIGIN = 50
M.MAP_HOLD = 0.5
function M.map_origin_step(prev, cursor, player_y, now, last_at)
  last_at = last_at or 0
  if type(cursor) ~= "table" or not finite(cursor.x) or not finite(cursor.z)
    or (math.abs(cursor.x) <= 1 and math.abs(cursor.z) <= 1) then
    return prev, last_at
  end
  local function cand()
    local y = cursor.y
    if not finite(y) or y == 0 then
      y = (player_y ~= nil and finite(player_y)) and player_y or 0
    end
    return { x = cursor.x, y = y, z = cursor.z }
  end
  if prev == nil then return cand(), now end
  local dx, dz = cursor.x - prev.x, cursor.z - prev.z
  if dx * dx + dz * dz >= M.MAP_REORIGIN * M.MAP_REORIGIN and now - last_at >= M.MAP_HOLD then
    return cand(), now
  end
  return prev, last_at
end

-- v5 (SPEC 12.3b): pure builder for the objective table.
-- records: array of {qid, cid, issued}; progressing: {[qid]=true};
-- prev: previous return value or nil. Returns
-- { cids = {[qid]={cid,...}}, issued = {[qid]={cid,...}},
--   miss = {[qid]=n}, issued_miss = {[qid]=n},
--   issued_streak = {[qid]={cid=c,n=n}} }.
function M.objective_table(records, prev, progressing)
  local prev_cids = prev and prev.cids or {}
  local prev_issued = prev and prev.issued or {}
  local prev_miss = prev and prev.miss or {}
  local prev_issued_miss = prev and prev.issued_miss or {}
  local prev_streak = prev and prev.issued_streak or {}
  local by_qid = {}   -- qid -> {cid -> issued(bool)}
  for _, r in ipairs(records or {}) do
    if type(r.qid) == "number" and progressing[r.qid]
      and type(r.cid) == "number" and r.cid > 0 then
      local set = by_qid[r.qid]
      if set == nil then set = {}; by_qid[r.qid] = set end
      set[r.cid] = set[r.cid] or (r.issued == true)
    end
  end
  local out = { cids = {}, issued = {}, miss = {}, issued_miss = {}, issued_streak = {} }
  for qid, set in pairs(by_qid) do
    local issued, rest = {}, {}
    for cid, is in pairs(set) do
      if is then issued[#issued + 1] = cid else rest[#rest + 1] = cid end
    end
    table.sort(issued)
    table.sort(rest)
    local legacy_top = issued[1]
    local arr = {}
    for _, c in ipairs(issued) do arr[#arr + 1] = c end
    for _, c in ipairs(rest) do arr[#arr + 1] = c end
    if #issued > 0 then
      local prior = prev_issued[qid] and prev_issued[qid][1] or nil
      if prior ~= nil and set[prior] == true and issued[1] ~= prior then
        for i, cid in ipairs(issued) do
          if cid == prior then table.remove(issued, i); break end
        end
        table.insert(issued, 1, prior)
      end
      out.issued[qid] = issued
    else
      local prior = prev_issued[qid]
      if prior ~= nil then
        local n = (prev_issued_miss[qid] or 0) + 1
        if n <= 3 then
          out.issued[qid] = prior
          out.issued_miss[qid] = n
        end
      end
    end
    -- Debounced stickiness (SPEC 12.3b): the previous first cid keeps
    -- first place while it is in the top tier; a new top issued cid
    -- displaces a non-issued sticky first only after 2 consecutive
    -- builds, so one flickering build never moves the marker.
    local pf = prev_cids[qid] and prev_cids[qid][1] or nil
    if pf ~= nil and set[pf] ~= nil and arr[1] ~= pf then
      local pf_in_top = (#issued == 0) or (set[pf] == true)
      if pf_in_top then
        -- Tie-break inside the same tier: previous first wins.
        for i, c in ipairs(arr) do
          if c == pf then table.remove(arr, i) break end
        end
        table.insert(arr, 1, pf)
      else
        local top = legacy_top
        local ps = prev_streak[qid]
        local n = (ps ~= nil and ps.cid == top) and (ps.n + 1) or 1
        out.issued_streak[qid] = { cid = top, n = n }
        if n < 2 then
          for i, c in ipairs(arr) do
            if c == pf then table.remove(arr, i) break end
          end
          table.insert(arr, 1, pf)
        end
      end
    end
    out.cids[qid] = arr
  end
  -- Retention: a progressing qid absent from records keeps its previous
  -- array for up to 3 consecutive builds, then drops. Non-progressing
  -- qids drop immediately.
  for qid, arr in pairs(prev_cids) do
    if out.cids[qid] == nil and progressing[qid] then
      local n = (prev_miss[qid] or 0) + 1
      if n <= 3 then
        out.cids[qid] = arr
        out.miss[qid] = n
      end
    end
  end
  -- Issued targets share the same three-build retention when the qid is
  -- absent from the processor walk. A non-progressing quest drops at once.
  for qid, arr in pairs(prev_issued) do
    if out.issued[qid] == nil and by_qid[qid] == nil and progressing[qid] then
      local n = (prev_issued_miss[qid] or 0) + 1
      if n <= 3 then
        out.issued[qid] = arr
        out.issued_miss[qid] = n
      end
    end
  end
  return out
end

-- Nil means no current issued NPC target is known.
function M.objective_issued_cids(table_, qid)
  return type(table_) == "table" and type(table_.issued) == "table"
    and table_.issued[qid] or nil
end

-- SPEC 40.10: typed netstring target identities. Lua strings are byte strings,
-- so #s is the required UTF-8 byte length and string comparison is bytewise.
local OBJECTIVE_ORDINAL_MAX = 1099511627775 -- 2^40 - 1
local OBJECTIVE_DIRECT_BASE = 4398046511104 -- 2^42

function M.byte_less(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  local n = math.min(#a, #b)
  for i = 1, n do
    local aa, bb = string.byte(a, i), string.byte(b, i)
    if aa ~= bb then return aa < bb end
  end
  return #a < #b
end

local function canonical_integer(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    and math.type(v) == "integer" and math.abs(v) <= 9007199254740991
end

local function valid_target_tuple(tuple, count)
  local family = tuple[1]
  if family == "source" or family == "capacity" or family == "need" then
    if count < 2 or count > 32 then return false end
    if (family == "source" or family == "capacity")
        and (type(tuple[2]) ~= "string" or tuple[2] == "") then return false end
    for i = 2, count do
      local value = tuple[i]
      if type(value) == "string" then
        if value == "" then return false end
      elseif not canonical_integer(value) then
        return false
      end
    end
    -- Keep the legacy two-component source identity readable while requiring
    -- family qualification for every new capacity and need identity.
    return family == "source" or count >= 3
  end
  local qid = tuple[1]
  if type(qid) ~= "number" or not canonical_integer(qid) or qid < 1 or qid > 2147483647 then return false end
  if count == 3 then
    return tuple[2] == "live_destination" and tuple[3] == 0
      or tuple[2] == "issued_npc" and canonical_integer(tuple[3])
        and tuple[3] >= 1 and tuple[3] <= 4294967295
  end
  if count == 5 then
    local kind = tuple[5]
    if kind ~= "npc" and kind ~= "place" then return false end
    if tuple[2] == "task" then
      return canonical_integer(tuple[3]) and tuple[3] >= 0 and tuple[3] <= 2147483647
        and canonical_integer(tuple[4]) and tuple[4] >= 0 and tuple[4] <= 2147483647
    elseif tuple[2] == "guidance" then
      return canonical_integer(tuple[3]) and tuple[3] >= 0 and tuple[3] <= 2147483647
        and canonical_integer(tuple[4]) and tuple[4] >= 0 and tuple[4] <= 2147483647
    end
  end
  return false
end

local function canonical_key_valid(key)
  if type(key) ~= "string" or key:sub(1, 1) ~= "t" then return false end
  local sep = key:find(":", 2, true)
  if not sep then return false end
  local count = tonumber(key:sub(2, sep - 1))
  if not count or count < 1 or count > 32 or count ~= math.floor(count) then return false end
  if key:sub(2, sep - 1) ~= tostring(count) then return false end
  local tuple, at = {}, sep + 1
  for i = 1, count do
    local tag = key:sub(at, at)
    if tag == "i" then
      local end_at = key:find(";", at + 1, true)
      if not end_at then return false end
      local raw = key:sub(at + 1, end_at - 1)
      local n = tonumber(raw)
      if not n or not canonical_integer(n) or string.format("%.0f", n) ~= raw then return false end
      tuple[i], at = n, end_at + 1
    elseif tag == "s" then
      local colon = key:find(":", at + 1, true)
      if not colon then return false end
      local size = tonumber(key:sub(at + 1, colon - 1))
      if not size or size < 0 or size ~= math.floor(size) then return false end
      if key:sub(at + 1, colon - 1) ~= tostring(size) then return false end
      local start, finish = colon + 1, colon + size
      if finish > #key then return false end
      tuple[i], at = key:sub(start, finish), finish + 1
    else return false end
  end
  return at == #key + 1 and valid_target_tuple(tuple, count)
end

function M.target_key(tuple)
  if type(tuple) ~= "table" then return nil end
  local count, maximum = 0, 0
  for k in pairs(tuple) do
    if not canonical_integer(k) or k < 1 then return nil end
    count = count + 1
    if k > maximum then maximum = k end
  end
  if count == 0 or count ~= maximum then return nil end
  if not valid_target_tuple(tuple, count) then return nil end
  local out = { "t", tostring(count), ":" }
  for i = 1, count do
    local v = tuple[i]
    if canonical_integer(v) then
      out[#out + 1] = "i" .. string.format("%.0f", v) .. ";"
    elseif type(v) == "string" then
      out[#out + 1] = "s" .. tostring(#v) .. ":" .. v
    else
      return nil
    end
  end
  return table.concat(out)
end

function M.target_registry_new(next_ordinal)
  if next_ordinal == nil then next_ordinal = 1 end
  if not canonical_integer(next_ordinal) or next_ordinal < 1
      or next_ordinal > OBJECTIVE_ORDINAL_MAX then next_ordinal = OBJECTIVE_ORDINAL_MAX + 1 end
  return { by_key = {}, next_ordinal = next_ordinal, diagnostics = {} }
end

function M.target_registry_reset(registry)
  if type(registry) ~= "table" then return M.target_registry_new() end
  registry.by_key, registry.next_ordinal, registry.diagnostics = {}, 1, {}
  return registry
end

function M.target_registry_allocate(registry, keys)
  local out = {}
  if type(registry) ~= "table" or type(registry.by_key) ~= "table"
      or type(registry.diagnostics) ~= "table" or type(keys) ~= "table" then return out end
  local unique, sorted = {}, {}
  for _, key in ipairs(keys) do
    if canonical_key_valid(key) then
      if not unique[key] then unique[key] = true; sorted[#sorted + 1] = key end
    else
      registry.diagnostics[#registry.diagnostics + 1] = { reason = "target_key_invalid",
        key_type = type(key) }
    end
  end
  table.sort(sorted, M.byte_less)
  for _, key in ipairs(sorted) do
    local ordinal = registry.by_key[key]
    if ordinal ~= nil and (not canonical_integer(ordinal) or ordinal < 1
        or ordinal > OBJECTIVE_ORDINAL_MAX) then
      registry.diagnostics[#registry.diagnostics + 1] = { key = key, reason = "ordinal_invalid" }
      ordinal = nil
    end
    if ordinal == nil then
      local next_ordinal = registry.next_ordinal
      if canonical_integer(next_ordinal) and next_ordinal >= 1
          and next_ordinal <= OBJECTIVE_ORDINAL_MAX then
        ordinal = next_ordinal
        registry.by_key[key] = ordinal
        registry.next_ordinal = ordinal + 1
      else
        registry.diagnostics[#registry.diagnostics + 1] = { key = key, reason = "ordinal_exhausted" }
      end
    end
    if ordinal ~= nil then out[key] = ordinal end
  end
  return out
end

function M.objective_direct_route_id(ordinal)
  if not canonical_integer(ordinal) or ordinal < 1 or ordinal > OBJECTIVE_ORDINAL_MAX then return nil end
  return -(OBJECTIVE_DIRECT_BASE + ordinal)
end

local function objective_place_key(place)
  if type(place) ~= "table" then return nil end
  if place.kind == "key_location" and canonical_integer(place.key) and place.key >= 1 then
    return "key:" .. tostring(place.key)
  elseif place.kind == "local_area" and canonical_integer(place.local_area) and place.local_area >= 0 then
    return "area:" .. tostring(place.local_area)
  end
  return nil
end

local function objective_uint(v, maximum)
  return type(v) == "number" and math.type(v) == "integer" and v >= 1 and v <= maximum
end

local function objective_index(v, maximum)
  return type(v) == "number" and math.type(v) == "integer" and v >= 0 and v <= maximum
end

local function objective_generation(v)
  return type(v) == "number" and math.type(v) == "integer" and v > 0
end

local function objective_copy_pos(p)
  if not valid_pos(p) then return nil end
  return { x = p.x, y = p.y, z = p.z }
end

local function objective_owner(owners, qid, task_index)
  for _, owner in ipairs(owners) do
    if owner.qid == qid and owner.task_index == task_index then return end
  end
  owners[#owners + 1] = { qid = qid, task_index = task_index }
end

local function objective_array(value)
  if type(value) ~= "table" then return nil end
  local n, count = #value, 0
  for k in pairs(value) do
    if type(k) ~= "number" or math.type(k) ~= "integer" or k < 1 or k > n then return nil end
    count = count + 1
  end
  if count ~= n then return nil end
  return value
end

local function objective_tuple_copy(value)
  local dense = objective_array(value)
  if not dense then return nil end
  local out = {}
  for i, part in ipairs(dense) do
    if type(part) ~= "string" and not canonical_integer(part) then return nil end
    out[i] = part
  end
  return out
end

local function objective_need_signatures(task_snapshot)
  local snapshot = type(task_snapshot) == "table" and task_snapshot.objective_needs or nil
  if type(snapshot) ~= "table" then return {} end
  local signatures = { "status=" .. tostring(snapshot.status),
    "complete=" .. tostring(snapshot.complete), "generation=" .. tostring(snapshot.generation),
    "source_generation=" .. tostring(snapshot.source_generation),
    "task_generation=" .. tostring(snapshot.task_generation) }
  local groups = {}
  for _, group in ipairs(objective_array(snapshot.groups) or {}) do
    if type(group) == "table" then
      local options = {}
      for _, option in ipairs(objective_array(group.options) or {}) do
        if type(option) == "table" then
          options[#options + 1] = tostring(option.item_id) .. "=" .. tostring(option.accepted_count)
        else
          options[#options + 1] = "invalid"
        end
      end
      table.sort(options)
      groups[#groups + 1] = table.concat({ M.target_key(group.id) or "invalid",
        tostring(group.qid), tostring(group.task_index), tostring(group.remaining),
        tostring(group.status), tostring(group.complete), tostring(group.generation),
        table.concat(options, ",") }, "|")
    else
      groups[#groups + 1] = "invalid"
    end
  end
  table.sort(groups, M.byte_less)
  for _, signature in ipairs(groups) do signatures[#signatures + 1] = signature end
  return signatures
end

local function objective_stamp(task_snapshot, place_snapshot, provider_snapshots)
  local providers = {}
  for _, p in ipairs(objective_array(provider_snapshots) or {}) do
    if type(p) == "table" then providers[#providers + 1] = p end
  end
  table.sort(providers, function(a, b) return tostring(a.provider) < tostring(b.provider) end)
  local parts = { task_snapshot.focus_epoch, task_snapshot.journal_generation,
    task_snapshot.need_generation, place_snapshot.generation }
  for _, signature in ipairs(objective_need_signatures(task_snapshot)) do
    parts[#parts + 1] = signature
  end
  for _, p in ipairs(providers) do
    parts[#parts + 1] = p.provider
    parts[#parts + 1] = p.generation
  end
  local hash = 17
  for _, part in ipairs(parts) do
    local s = tostring(part or "")
    for i = 1, #s do hash = (hash * 131 + s:byte(i)) % 2147483647 end
    hash = (hash * 131 + 31) % 2147483647
  end
  return hash + 1
end

-- Purely normalize exact task/provider snapshots. No game reads or settings.
function M.objective_snapshot(task_snapshot, place_snapshot, provider_snapshots, registry)
  if type(task_snapshot) ~= "table" or type(task_snapshot.quests) ~= "table"
      or type(registry) ~= "table" then return nil end
  place_snapshot = type(place_snapshot) == "table" and place_snapshot or { generation = 0, status = "unknown", places = {} }
  local objective_gen = objective_stamp(task_snapshot, place_snapshot, provider_snapshots)
  local places = {}
  if place_snapshot.status == "ok" and type(place_snapshot.places) == "table" then
    for _, p in ipairs(objective_array(place_snapshot.places) or {}) do
      if type(p) == "table" and p.eligibility == "eligible" and valid_pos(p.pos) then
        places[table.concat({ tostring(p.qid), tostring(p.task_index), tostring(p.owner_kind),
          tostring(p.owner_index), tostring(p.signal_index) }, ":")] = { pos = p.pos, target = p.target }
      end
    end
  end
  local grouped_needs = task_snapshot.objective_needs ~= nil
  local item_owners, current_tasks, need_groups, targets, by_key = {}, {}, {}, {}, {}
  local diagnostics = {}
  local function diagnostic(provider, reason, id)
    diagnostics[#diagnostics + 1] = { provider = provider, reason = reason, id = id }
  end
  local function add(qid, task_index, tuple, kind, target, provider, source_id,
      item_ids, eligibility, reason)
    if eligibility ~= "eligible" then
      if reason ~= nil then diagnostic(provider, reason, source_id) end
      return
    end
    local key = M.target_key(tuple)
    if not key then return end
    local pos = objective_copy_pos(target.pos)
    local cid = target.cid
    if cid ~= nil and (not objective_uint(cid, 4294967295) or target.place ~= nil) then return end
    if target.place ~= nil and not objective_place_key(target.place) then return end
    if not pos and not (type(cid) == "number" and cid > 0) then return end
    local obj = by_key[key]
    if not obj then
      local route_order = provider == "issued_npc" and 1
        or provider == "live_destination" and 2
        or provider == "task" and 3
        or provider == "guidance" and (kind == "npc" and 4 or 5) or 9
      obj = { key = key, kind = kind, target = { cid = cid, place = target.place,
          pos = pos }, owners = {}, item_ids = {}, provider = provider,
        source_id = source_id, eligibility = eligibility, reason = reason,
        route_order = route_order, sequence = #targets + 1,
        generation = objective_gen }
      by_key[key] = obj; targets[#targets + 1] = obj
    end
    objective_owner(obj.owners, qid, task_index)
    for _, item_id in ipairs(item_ids or {}) do
      local seen = false
      for _, old in ipairs(obj.item_ids) do if old == item_id then seen = true; break end end
      if not seen then obj.item_ids[#obj.item_ids + 1] = item_id end
    end
  end
  for _, quest in ipairs(objective_array(task_snapshot.quests) or {}) do
    local valid_qid = type(quest) == "table" and objective_uint(quest.qid, 2147483647)
    local valid_task = valid_qid and objective_index(quest.task_index, 2147483647)
      and quest.read_status == "ok"
    if valid_qid and not valid_task then
      for _, signal in ipairs(objective_array(quest.issued_npcs) or {}) do
        if type(signal) == "table" and signal.task_index == nil then
          local target = type(signal.target) == "table" and signal.target or {}
          if signal.kind == "npc" and type(target.cid) == "number" then
            add(quest.qid, nil, { quest.qid, "issued_npc", target.cid }, "npc", target,
              "issued_npc", nil, nil, signal.eligibility, signal.reason)
          end
        end
      end
    end
    if type(quest) == "table" and objective_uint(quest.qid, 2147483647)
        and objective_index(quest.task_index, 2147483647)
        and quest.read_status == "ok" then
      local qid, task_index = quest.qid, quest.task_index
      current_tasks[qid] = task_index
      for _, owner in ipairs(not grouped_needs and (objective_array(quest.item_ownership) or {}) or {}) do
        if type(owner) == "table" and owner.eligibility == "eligible"
            and objective_uint(owner.item_id, 2147483647)
            and objective_uint(owner.count, 2147483647)
            and (owner.proof_kind == "condition" or owner.proof_kind == "delivery") then
          local set = item_owners[owner.item_id]
          if not set then set = {}; item_owners[owner.item_id] = set end
          set[qid] = task_index
        end
      end
      for _, signal in ipairs(objective_array(quest.issued_npcs) or {}) do
        if type(signal) == "table"
            and (signal.task_index == nil or (objective_index(signal.task_index, 2147483647)
              and signal.task_index == task_index)) then
          local target = type(signal.target) == "table" and signal.target or {}
          if signal.kind == "npc" and type(target.cid) == "number" then
            add(qid, task_index, { qid, "issued_npc", target.cid }, "npc", target, "issued_npc", nil, nil,
              signal.eligibility, signal.reason)
          end
        end
      end
      local live = quest.live_destination
      if type(live) == "table" and (live.task_index == nil
          or (objective_index(live.task_index, 2147483647) and live.task_index == task_index)) then
        local target = type(live.target) == "table" and live.target or {}
        if target.pos or target.cid then
          add(qid, task_index, { qid, "live_destination", 0 }, target.cid and "npc" or "place", target,
            "live_destination", nil, nil, live.eligibility, live.reason)
        end
      end
      local function signal_list(list, owner_kind, owner_index, parent_destination_index)
        for _, signal in ipairs(objective_array(list) or {}) do
          if type(signal) == "table" and (signal.task_index == nil
              or (objective_index(signal.task_index, 2147483647) and signal.task_index == task_index)) then
            local signal_kind = signal.kind
            local target = type(signal.target) == "table" and signal.target or {}
            local index = parent_destination_index or signal.destination_index or signal.signal_index
            local ti = task_index
            local pos = objective_copy_pos(target.pos)
            if not pos and target.place then
              local pkey = table.concat({ tostring(qid), tostring(ti), tostring(owner_kind),
                tostring(owner_kind == "task" and ti or owner_index or signal.concierge_index),
                tostring(index) }, ":")
              local resolved = places[pkey]
              if resolved and objective_place_key(resolved.target) == objective_place_key(target.place) then
                pos = objective_copy_pos(resolved.pos)
              end
            end
            target = { cid = target.cid, place = target.place, pos = pos }
            if signal_kind == "npc" and type(target.cid) == "number" then
              local identity = owner_kind == "task"
                and { qid, "task", ti, index, "npc" }
                or { qid, "guidance", owner_index or signal.concierge_index, index, "npc" }
              add(qid, task_index, identity,
                "npc", target, owner_kind, nil, nil, signal.eligibility, signal.reason)
            elseif signal_kind == "place" and pos then
              local identity = owner_kind == "task"
                and { qid, "task", ti, index, "place" }
                or { qid, "guidance", owner_index or signal.concierge_index, index, "place" }
              add(qid, task_index, identity,
                "place", target, owner_kind, nil, nil, signal.eligibility, signal.reason)
            end
          end
        end
      end
      signal_list(quest.task_destinations, "task", nil)
      for _, guidance in ipairs(objective_array(quest.guidance) or {}) do
        if type(guidance) == "table" and guidance.eligibility == "eligible"
            and (guidance.task_index == nil or (objective_index(guidance.task_index, 2147483647)
              and guidance.task_index == task_index)) then
          signal_list(guidance.signals, "guidance", guidance.concierge_index,
            guidance.destination_index)
        end
      end
    elseif type(quest) == "table" then
      diagnostic("task", quest.reason or (quest.read_status == "unknown"
        and "task_snapshot_unknown" or "task_snapshot_status_invalid"), quest.qid)
    end
  end
  local grouped_needs_valid = not grouped_needs
  if grouped_needs then
    local snapshot = task_snapshot.objective_needs
    grouped_needs_valid = type(snapshot) == "table" and snapshot.status == "ok"
      and snapshot.complete == true and objective_generation(snapshot.generation)
      and snapshot.generation == task_snapshot.need_generation
      and objective_generation(snapshot.source_generation)
      and objective_array(snapshot.groups) ~= nil
    local seen = {}
    if grouped_needs_valid then
      for _, group in ipairs(snapshot.groups) do
        local id = type(group) == "table" and objective_tuple_copy(group.id) or nil
        local key = id and M.target_key(id) or nil
        local options, option_ids, accepted_count = {}, {}, nil
        local valid = type(group) == "table" and key ~= nil and id[1] == "need"
          and group.status == "eligible" and group.complete == true
          and objective_generation(group.generation)
          and group.generation == snapshot.source_generation
          and objective_uint(group.qid, 2147483647)
          and objective_index(group.task_index, 2147483647)
          and current_tasks[group.qid] == group.task_index
          and objective_uint(group.remaining, 2147483647)
          and objective_array(group.options) ~= nil and #group.options > 0
          and not seen[key]
        if valid then
          for _, option in ipairs(group.options) do
            if type(option) ~= "table" or not objective_uint(option.item_id, 2147483647)
                or not objective_uint(option.accepted_count, 2147483647)
                or option_ids[option.item_id]
                or (accepted_count ~= nil and option.accepted_count ~= accepted_count) then
              valid = false; break
            end
            accepted_count = option.accepted_count
            option_ids[option.item_id] = true
            options[#options + 1] = { item_id = option.item_id,
              accepted_count = option.accepted_count }
          end
        end
        valid = valid and group.remaining <= (accepted_count or 0)
        if not valid then
          grouped_needs_valid = false
          diagnostic("needs", "need_group_invalid", key)
          break
        end
        seen[key] = true
        table.sort(options, function(a, b) return a.item_id < b.item_id end)
        need_groups[#need_groups + 1] = { id = id, key = key, qid = group.qid,
          task_index = group.task_index, remaining = group.remaining, options = options,
          option_ids = option_ids, status = "eligible", complete = true,
          generation = group.generation }
      end
    else
      diagnostic("needs", "need_snapshot_invalid")
    end
    if not grouped_needs_valid then need_groups = {} end
    table.sort(need_groups, function(a, b) return M.byte_less(a.key, b.key) end)
  end
  local provider_generations = {}
  local invalid_sources, invalid_pools, capacity_pools = {}, {}, {}
  local grouped_contracts, source_claims = {}, {}
  local capacity_claims, capacity_contracts = {}, {}
  local function outputs_signature(outputs)
    local parts = {}
    for _, output in ipairs(outputs) do
      parts[#parts + 1] = tostring(output.item_id) .. "=" .. tostring(output.count)
    end
    table.sort(parts)
    return table.concat(parts, ",")
  end
  local function grouped_identity_claim(candidate)
    if type(candidate) ~= "table" then return {} end
    local source_tuple = objective_tuple_copy(candidate.source_id)
    local capacity_tuple = objective_tuple_copy(candidate.capacity_pool_id)
    local source_key = source_tuple and M.target_key(source_tuple) or nil
    local capacity_key = capacity_tuple and M.target_key(capacity_tuple) or nil
    if not (source_key ~= nil and source_tuple[1] == "source") then
      source_tuple, source_key = nil, nil
    end
    if not (capacity_key ~= nil and capacity_tuple[1] == "capacity") then
      capacity_tuple, capacity_key = nil, nil
    end
    return { source_tuple = source_tuple, capacity_tuple = capacity_tuple,
      source_key = source_key, capacity_key = capacity_key }
  end
  local function grouped_contract(provider, candidate, claim)
    if type(candidate) ~= "table" or (candidate.eligibility ~= "eligible"
        and candidate.eligibility ~= "ineligible" and candidate.eligibility ~= "unknown") then
      return nil
    end
    local source_tuple, capacity_tuple = claim.source_tuple, claim.capacity_tuple
    local source_key, capacity_key = claim.source_key, claim.capacity_key
    local outputs, output_ids = {}, {}
    local valid = source_key ~= nil and capacity_key ~= nil
      and candidate.provider == provider.provider and type(candidate.target) == "table"
      and candidate.generation == provider.generation
      and objective_array(candidate.outputs) ~= nil and #candidate.outputs > 0
    if valid then
      for _, output in ipairs(candidate.outputs) do
        if type(output) ~= "table" or not objective_uint(output.item_id, 2147483647)
            or not objective_uint(output.count, 2147483647) or output_ids[output.item_id] then
          valid = false; break
        end
        output_ids[output.item_id] = true
        outputs[#outputs + 1] = { item_id = output.item_id, count = output.count }
      end
    end
    table.sort(outputs, function(a, b) return a.item_id < b.item_id end)
    local finite_capacity = candidate.capacity_kind == "finite"
      and objective_index(candidate.available_acquisitions, 2147483647)
      and candidate.available_acquisitions > 0
    local unlimited_capacity = candidate.capacity_kind == "unlimited"
      and candidate.available_acquisitions == nil
    local certainty_ok = candidate.certainty == "guaranteed"
      or candidate.certainty == "probabilistic"
    local probability_ok = candidate.certainty ~= "probabilistic"
      or (type(candidate.probability) == "number" and candidate.probability == candidate.probability
        and candidate.probability > 0 and candidate.probability < math.huge)
    local target = type(candidate.target) == "table" and candidate.target or {}
    local candidate_pos = candidate.pos or target.pos
    local target_ok = (valid_pos(candidate_pos) or objective_uint(target.cid, 4294967295))
      and (target.cid == nil or (objective_uint(target.cid, 4294967295)
        and target.place == nil))
      and (target.place == nil or objective_place_key(target.place))
    valid = valid and (finite_capacity or unlimited_capacity) and certainty_ok
      and probability_ok and target_ok
    if not valid then return nil end
    return { source_tuple = source_tuple, capacity_tuple = capacity_tuple,
      source_key = source_key, capacity_key = capacity_key, outputs = outputs,
      target = target, candidate_pos = candidate_pos,
      pool_signature = table.concat({ candidate.capacity_kind,
        tostring(candidate.available_acquisitions), candidate.certainty,
        tostring(candidate.probability), outputs_signature(outputs) }, "|") }
  end
  if grouped_needs and grouped_needs_valid then
    for _, provider in ipairs(objective_array(provider_snapshots) or {}) do
      if type(provider) == "table" and objective_generation(provider.generation)
          and provider.status == "ok" and provider.complete == true
          and objective_array(provider.candidates) ~= nil then
        for _, candidate in ipairs(provider.candidates) do
          local claim = grouped_identity_claim(candidate)
          if claim.source_key then
            source_claims[claim.source_key] = (source_claims[claim.source_key] or 0) + 1
          end
          if claim.capacity_key then
            capacity_claims[claim.capacity_key] = (capacity_claims[claim.capacity_key] or 0) + 1
          end
          local contract = grouped_contract(provider, candidate, claim)
          if contract then
            grouped_contracts[candidate] = contract
            capacity_contracts[contract.capacity_key]
              = (capacity_contracts[contract.capacity_key] or 0) + 1
            local previous = capacity_pools[contract.capacity_key]
            if previous ~= nil and previous ~= contract.pool_signature then
              invalid_pools[contract.capacity_key] = true
            else
              capacity_pools[contract.capacity_key] = contract.pool_signature
            end
          else
            diagnostic(provider.provider, "source_contract_invalid")
          end
        end
      end
    end
    for source_key, count in pairs(source_claims) do
      if count > 1 then invalid_sources[source_key] = true end
    end
    for capacity_key, count in pairs(capacity_claims) do
      if count > 1 and count ~= (capacity_contracts[capacity_key] or 0) then
        invalid_pools[capacity_key] = true
      end
    end
    for source_key in pairs(invalid_sources) do
      diagnostic("source", "source_identity_duplicate", source_key)
    end
    for capacity_key in pairs(invalid_pools) do
      diagnostic("capacity", "capacity_pool_conflict", capacity_key)
    end
  end
  local function grouped_candidate(provider, candidate)
    local contract = grouped_contracts[candidate]
    if not contract then return end
    local source_tuple, capacity_tuple = contract.source_tuple, contract.capacity_tuple
    local source_key, capacity_key = contract.source_key, contract.capacity_key
    local outputs, target, candidate_pos = contract.outputs, contract.target, contract.candidate_pos
    if invalid_sources[source_key] or invalid_pools[capacity_key] then return end
    if candidate.eligibility ~= "eligible" then
      diagnostic(provider.provider, candidate.reason or "candidate_ineligible_or_unknown", source_key)
      return
    end
    local matches, matched_ids = {}, {}
    for _, group in ipairs(need_groups) do
      local ids, contribution = {}, 0
      for _, output in ipairs(outputs) do
        if group.option_ids[output.item_id] then
          ids[#ids + 1] = output.item_id
          matched_ids[output.item_id] = true
          contribution = contribution + output.count
        end
      end
      if contribution > 0 then
        matches[#matches + 1] = { key = group.key, id = objective_tuple_copy(group.id),
          qid = group.qid, task_index = group.task_index, remaining = group.remaining,
          item_ids = ids, contribution = contribution }
      end
    end
    if #matches == 0 then
      diagnostic(provider.provider, "source_has_no_current_need", source_key)
      return
    end
    local item_ids = {}
    for id in pairs(matched_ids) do item_ids[#item_ids + 1] = id end
    table.sort(item_ids)
    table.sort(matches, function(a, b) return M.byte_less(a.key, b.key) end)
    local obj = { key = source_key, kind = "source",
      target = { cid = target.cid, place = target.place,
        pos = objective_copy_pos(candidate_pos), marker_key = target.marker_key },
      owners = {}, item_ids = item_ids, provider = provider.provider,
      source_id = source_key, source_tuple = source_tuple, capacity_key = capacity_key,
      capacity_pool_id = capacity_tuple, outputs = outputs, groups = matches,
      capacity_kind = candidate.capacity_kind,
      available_acquisitions = candidate.available_acquisitions,
      certainty = candidate.certainty, probability = candidate.probability,
      eligibility = "eligible", reason = candidate.reason, route_order = 6,
      generation = objective_gen }
    for _, match in ipairs(matches) do objective_owner(obj.owners, match.qid, match.task_index) end
    by_key[source_key] = obj
    targets[#targets + 1] = obj
  end
  for _, provider in ipairs(objective_array(provider_snapshots) or {}) do
    if type(provider) == "table" then
      local provider_candidates = objective_array(provider.candidates)
      provider_generations[#provider_generations + 1] = { provider = provider.provider,
        generation = provider.generation, status = provider.status,
        complete = provider.complete, reason = provider.reason,
        candidate_count = provider_candidates and #provider_candidates or nil }
      if grouped_needs then
        if not grouped_needs_valid then
          diagnostic(provider.provider, "need_snapshot_invalid")
        elseif not objective_generation(provider.generation) then
          diagnostic(provider.provider, "provider_generation_invalid")
        elseif provider.status == "ok" and provider.complete == true
            and objective_array(provider.candidates) ~= nil then
          for _, candidate in ipairs(provider.candidates) do grouped_candidate(provider, candidate) end
        elseif provider.status == "unknown" then
          diagnostic(provider.provider, provider.reason or "provider_unknown")
        else
          diagnostic(provider.provider, "provider_snapshot_invalid")
        end
      elseif not objective_generation(provider.generation) then
        diagnostic(provider.provider, "provider_generation_invalid")
      elseif provider.status == "ok" and type(provider.candidates) == "table" then
        for _, candidate in ipairs(provider.candidates) do
          if type(candidate) == "table" and candidate.eligibility == "eligible"
              and type(candidate.id) == "string" and candidate.id ~= ""
              and objective_array(candidate.item_ids) ~= nil then
            local owns = false
            local valid_items = true
            for _, id in ipairs(candidate.item_ids) do
              if not objective_uint(id, 2147483647) then valid_items = false
              elseif item_owners[id] then owns = true end
            end
            local target = type(candidate.target) == "table" and candidate.target or {}
            local candidate_pos = candidate.pos or target.pos
            local target_ok = (valid_pos(candidate_pos) or objective_uint(target.cid, 4294967295))
              and (target.cid == nil or (objective_uint(target.cid, 4294967295) and target.place == nil))
              and (target.place == nil or objective_place_key(target.place))
            local generation_ok = candidate.generation == provider.generation
            if owns and valid_items and target_ok and generation_ok then
              local tuple = { "source", candidate.id }
              local key = M.target_key(tuple)
              local obj = key and by_key[key] or nil
              if not obj and key then
                obj = { key = key, kind = "source", target = { cid = target.cid,
                    place = target.place, pos = objective_copy_pos(candidate_pos) },
                  owners = {}, item_ids = {}, provider = provider.provider,
                  source_id = candidate.id, eligibility = "eligible",
                  reason = candidate.reason, route_order = 6,
                  generation = objective_gen }
              by_key[key] = obj; targets[#targets + 1] = obj
              end
              if obj then
                for id in pairs(item_owners) do
                  for _, candidate_id in ipairs(candidate.item_ids) do
                    if id == candidate_id then
                      for qid, task_index in pairs(item_owners[id]) do
                        objective_owner(obj.owners, qid, task_index)
                      end
                    end
                  end
                end
                for _, id in ipairs(candidate.item_ids) do
                  local seen = false; for _, old in ipairs(obj.item_ids) do if old == id then seen = true end end
                  if item_owners[id] and not seen then obj.item_ids[#obj.item_ids + 1] = id end
                end
              end
            end
            if not owns then diagnostic(provider.provider, "source_has_no_current_item_owner", candidate.id)
            elseif not valid_items then diagnostic(provider.provider, "source_item_id_invalid", candidate.id)
            elseif not target_ok then diagnostic(provider.provider, "source_target_unresolved", candidate.id)
            elseif not generation_ok then diagnostic(provider.provider, "candidate_generation_mismatch", candidate.id) end
          elseif type(candidate) == "table" then
            diagnostic(provider.provider, candidate.reason or "candidate_ineligible_or_unknown", candidate.id)
          end
        end
      elseif provider.status == "unknown" then
        diagnostic(provider.provider, provider.reason or "provider_unknown")
      end
    end
  end
  if grouped_needs then
    local filtered, filtered_by_key = {}, {}
    for _, obj in ipairs(targets) do
      if obj.kind ~= "source" or (not invalid_sources[obj.key]
          and not invalid_pools[obj.capacity_key]) then
        filtered[#filtered + 1] = obj
        filtered_by_key[obj.key] = obj
      end
    end
    targets, by_key = filtered, filtered_by_key
  end
  local keys = {}
  for key in pairs(by_key) do keys[#keys + 1] = key end
  local ordinals = M.target_registry_allocate(registry, keys)
  local kept = {}
  for _, obj in ipairs(targets) do
    local ordinal = ordinals[obj.key]
    if ordinal then
      obj.ordinal = ordinal
      table.sort(obj.item_ids)
      table.sort(obj.owners, function(a, b)
        if a.qid ~= b.qid then return a.qid < b.qid end
        return (a.task_index or -1) < (b.task_index or -1)
      end)
      kept[#kept + 1] = obj
    end
  end
  return { generation = objective_gen, grouped_needs = grouped_needs,
    need_groups = need_groups,
    stamp = { focus_epoch = task_snapshot.focus_epoch, journal_generation = task_snapshot.journal_generation,
      need_generation = task_snapshot.need_generation,
      need_source_generation = type(task_snapshot.objective_needs) == "table"
        and task_snapshot.objective_needs.source_generation or nil,
      providers = provider_generations }, targets = kept,
      diagnostics = diagnostics, registry_diagnostics = registry.diagnostics }
end

local function objective_name(policy, obj)
  local names = policy.names or {}
  local function lookup(rows, key, field)
    if type(rows) ~= "table" then return nil end
    local direct = rows[key]
    if type(direct) == "string" then return direct end
    for _, row in ipairs(objective_array(rows) or {}) do
      if type(row) == "table" and row[field] == key and type(row.name) == "string" then return row.name end
    end
  end
  if obj.source_id then
    local name = lookup(names.targets, obj.key, "key")
    if name then return name end
  end
  if obj.target.cid then
    local name = lookup(names.npcs, obj.target.cid, "cid")
    if name then return name end
  end
  return obj.source_id or (obj.target.cid and tostring(obj.target.cid)) or "Objective"
end

local function objective_record_valid(snapshot, obj)
  if type(snapshot) ~= "table" or not objective_generation(snapshot.generation)
      or type(obj) ~= "table" or obj.generation ~= snapshot.generation
      or obj.eligibility ~= "eligible" or type(obj.key) ~= "string" or obj.key == ""
      or not objective_generation(obj.ordinal) or type(obj.target) ~= "table" then return false end
  local target = obj.target
  if target.cid ~= nil and (not objective_uint(target.cid, 4294967295) or target.place ~= nil) then return false end
  if target.place ~= nil and not objective_place_key(target.place) then return false end
  if target.pos ~= nil and not valid_pos(target.pos) then return false end
  local owners = objective_array(obj.owners)
  if not owners or #owners == 0 then return false end
  for _, owner in ipairs(owners) do
    if type(owner) ~= "table" or not objective_uint(owner.qid, 2147483647)
        or (owner.task_index ~= nil and not objective_index(owner.task_index, 2147483647)) then return false end
  end
  if obj.kind == "npc" then return target.cid ~= nil and target.place == nil end
  if obj.kind == "place" then return target.cid == nil and (target.place ~= nil or target.pos ~= nil) end
  if obj.kind == "source" then
    local ids = objective_array(obj.item_ids)
    if not ids or #ids == 0 then return false end
    for _, id in ipairs(ids) do if not objective_uint(id, 2147483647) then return false end end
    if snapshot.grouped_needs then
      if type(obj.source_id) ~= "string" or not canonical_key_valid(obj.source_id)
          or type(obj.capacity_key) ~= "string" or not canonical_key_valid(obj.capacity_key)
          or (obj.capacity_kind ~= "finite" and obj.capacity_kind ~= "unlimited")
          or (obj.capacity_kind == "finite" and (not objective_index(obj.available_acquisitions,
            2147483647) or obj.available_acquisitions == 0))
          or (obj.capacity_kind == "unlimited" and obj.available_acquisitions ~= nil)
          or (obj.certainty ~= "guaranteed" and obj.certainty ~= "probabilistic")
          or objective_array(obj.outputs) == nil or #obj.outputs == 0
          or objective_array(obj.groups) == nil or #obj.groups == 0 then return false end
      for _, group in ipairs(obj.groups) do
        if type(group) ~= "table" or type(group.key) ~= "string"
            or not canonical_key_valid(group.key) or not objective_uint(group.qid, 2147483647)
            or not objective_index(group.task_index, 2147483647)
            or not objective_uint(group.remaining, 2147483647)
            or not objective_uint(group.contribution, 2147483647)
            or objective_array(group.item_ids) == nil or #group.item_ids == 0 then return false end
      end
    end
    return target.cid ~= nil or target.place ~= nil or target.pos ~= nil
  end
  return false
end

function M.objective_markers(base_markers, fullmap_world, snapshot, policy)
  policy = type(policy) == "table" and policy or {}
  local out, full = {}, {}
  local want_full = fullmap_world ~= nil
  local operations = 0
  local function clone_markers(source, target)
    for _, original in ipairs(source or {}) do
      local copy = {}
      for k, v in pairs(original) do
        if k == "qids" or k == "objective_qids" or k == "objective_group_keys"
            or k == "objective_group_qids" or k == "objective_item_ids" then
          copy[k] = {}
          for i, qid in ipairs(objective_array(v) or {}) do copy[k][i] = qid end
        else copy[k] = v end
      end
      target[#target + 1] = copy
    end
  end
  clone_markers(objective_array(base_markers) or {}, out)
  if want_full then clone_markers(objective_array(fullmap_world) or {}, full) end
  local function index_new()
    return { objective = {}, source = {}, key = {}, cid = {}, source_claim = {} }
  end
  local function bucket_add(map, key, marker)
    if key == nil then return end
    local bucket = map[key]
    if not bucket then bucket = {}; map[key] = bucket end
    bucket[#bucket + 1] = marker
  end
  local function index_add(index, marker)
    if type(marker) ~= "table" then return end
    operations = operations + 1
    bucket_add(index.objective, marker.objective_key, marker)
    bucket_add(index.source, marker.source_key, marker)
    bucket_add(index.source, marker.source_id, marker)
    bucket_add(index.key, marker.key, marker)
    local cid = type(marker.cid) == "number" and marker.cid or M.marker_cid(marker)
    bucket_add(index.cid, cid, marker)
    if marker.objective_kind == "source" and type(marker.objective_key) == "string" then
      index.source_claim[marker] = marker.objective_key
    end
  end
  local function build_index(list)
    local index = index_new()
    for _, marker in ipairs(list) do index_add(index, marker) end
    return index
  end
  local out_index = build_index(out)
  local full_index = want_full and build_index(full) or nil
  local function find_marker(index, obj)
    local buckets = { index.objective[obj.key] }
    if obj.kind == "source" then
      buckets[#buckets + 1] = index.source[obj.key]
      buckets[#buckets + 1] = index.source[obj.source_id]
      if obj.target.marker_key ~= nil then buckets[#buckets + 1] = index.key[obj.target.marker_key] end
      if not snapshot.grouped_needs then buckets[#buckets + 1] = index.key[obj.source_id] end
    elseif obj.target.cid ~= nil then
      buckets[#buckets + 1] = index.cid[obj.target.cid]
    end
    local seen = {}
    for _, bucket in ipairs(buckets) do
      for _, marker in ipairs(bucket or {}) do
        if not seen[marker] then
          seen[marker] = true; operations = operations + 1
          local claim = index.source_claim[marker]
          if obj.kind ~= "source" or claim == nil or claim == obj.key then return marker end
        end
      end
    end
    return nil
  end
  local function decorate(index, marker, obj)
    marker.objective, marker.objective_key, marker.objective_ordinal = true, obj.key, obj.ordinal
    marker.objective_kind, marker.objective_certainty = obj.kind, obj.certainty
    marker.objective_route_order, marker.objective_sequence = obj.route_order, obj.sequence
    marker.objective_group_keys, marker.objective_group_qids, marker.objective_item_ids = {}, {}, {}
    for _, group in ipairs(objective_array(obj.groups) or {}) do
      marker.objective_group_keys[#marker.objective_group_keys + 1] = group.key
      marker.objective_group_qids[#marker.objective_group_qids + 1] = group.qid
    end
    for _, item_id in ipairs(objective_array(obj.item_ids) or {}) do
      marker.objective_item_ids[#marker.objective_item_ids + 1] = item_id
    end
    marker.cid = marker.cid or obj.target.cid
    marker.key = marker.key or ("objective:" .. tostring(obj.ordinal))
    marker.qids = objective_array(marker.qids) or {}
    marker.objective_qids = objective_array(marker.objective_qids) or {}
    local seen, objective_seen = {}, {}
    for _, qid in ipairs(marker.qids) do seen[qid] = true end
    for _, qid in ipairs(marker.objective_qids) do
      seen[qid], objective_seen[qid] = true, true
    end
    for _, owner in ipairs(objective_array(obj.owners) or {}) do
      if not seen[owner.qid] then marker.qids[#marker.qids + 1] = owner.qid; seen[owner.qid] = true end
      if not objective_seen[owner.qid] then
        marker.objective_qids[#marker.objective_qids + 1] = owner.qid
        objective_seen[owner.qid] = true
      end
    end
    if obj.kind == "source" then index.source_claim[marker] = obj.key end
  end
  local function make_marker(obj)
    local marker = { key = "objective:" .. tostring(obj.ordinal), cat = "objective",
      cid = obj.target.cid, qids = {}, pos = objective_copy_pos(obj.target.pos),
      label = "Objective: " .. objective_name(policy, obj), objective_qids = {} }
    return marker
  end
  local function attach_or_add(list, index, obj)
    local marker = find_marker(index, obj)
    if marker then
      decorate(index, marker, obj)
    elseif valid_pos(obj.target.pos) then
      marker = make_marker(obj)
      list[#list + 1] = marker
      index_add(index, marker)
      decorate(index, marker, obj)
    end
  end
  for _, obj in ipairs(type(snapshot) == "table" and objective_array(snapshot.targets) or {}) do
    if objective_record_valid(snapshot, obj) then
      attach_or_add(out, out_index, obj)
      if want_full then attach_or_add(full, full_index, obj) end
    end
  end
  local projection = { generation = type(snapshot) == "table" and snapshot.generation or 0,
    operations = operations,
    visible_keys = {}, omitted = { search = 0, objective_people_places = 0,
      objective_sources = 0, ordinary = 0, ancillary = 0 } }
  local focus_rank = {}
  for i, qid in ipairs(objective_array(policy.focus_order) or {}) do focus_rank[qid] = i end
  local function marker_class(marker)
    if marker.related_search == true or (policy.search_marker_key ~= nil
        and marker.key == policy.search_marker_key) then return 1, "search" end
    if marker.objective == true and marker.objective_kind ~= "source" then
      return 2, "objective_people_places"
    end
    if marker.objective == true and marker.objective_kind == "source" then
      return 3, "objective_sources"
    end
    if marker.related == true or marker.ancillary == true then return 5, "ancillary" end
    return 4, "ordinary"
  end
  local function apply_cap(list, record_omitted)
    local cap = policy.marker_cap
    if not canonical_integer(cap) or cap < 0 then cap = #list end
    local ranked = {}
    for index, marker in ipairs(list) do
      local class, name = marker_class(marker)
      local rank, group_key, certainty, distance = math.huge, "", 2, math.huge
      local route_order, sequence = math.huge, math.huge
      if class == 3 then
        local group_keys = objective_array(marker.objective_group_keys) or {}
        local group_qids = objective_array(marker.objective_group_qids) or {}
        for i, qid in ipairs(group_qids) do
          local next_rank = focus_rank[qid] or math.huge
          if next_rank < rank or (next_rank == rank
              and (group_key == "" or M.byte_less(group_keys[i] or "", group_key))) then
            rank, group_key = next_rank, group_keys[i] or ""
          end
        end
        certainty = marker.objective_certainty == "guaranteed" and 1 or 2
        if valid_pos(policy.origin) and valid_pos(marker.pos) then
          distance = (marker.pos.x-policy.origin.x)^2 + (marker.pos.y-policy.origin.y)^2
            + (marker.pos.z-policy.origin.z)^2
        end
      elseif class == 2 then
        for _, qid in ipairs(objective_array(marker.objective_qids) or {}) do
          rank = math.min(rank, focus_rank[qid] or math.huge)
        end
        route_order = marker.objective_route_order or math.huge
        sequence = marker.objective_sequence or math.huge
      end
      ranked[#ranked + 1] = { marker = marker, class = class, name = name,
        index = index, rank = rank, group_key = group_key,
        certainty = certainty, distance = distance,
        route_order = route_order, sequence = sequence }
    end
    if cap < #ranked then
      table.sort(ranked, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        if a.class == 2 then
          if a.rank ~= b.rank then return a.rank < b.rank end
          if a.route_order ~= b.route_order then return a.route_order < b.route_order end
          if a.sequence ~= b.sequence then return a.sequence < b.sequence end
          local ak, bk = a.marker.objective_key or "", b.marker.objective_key or ""
          if ak ~= bk then return M.byte_less(ak, bk) end
        elseif a.class == 3 then
          if a.rank ~= b.rank then return a.rank < b.rank end
          if a.group_key ~= b.group_key then return M.byte_less(a.group_key, b.group_key) end
          if a.certainty ~= b.certainty then return a.certainty < b.certainty end
          if a.distance ~= b.distance then return a.distance < b.distance end
          local ak, bk = a.marker.objective_key or "", b.marker.objective_key or ""
          if ak ~= bk then return M.byte_less(ak, bk) end
        end
        return a.index < b.index
      end)
    end
    local kept = {}
    for i, row in ipairs(ranked) do
      if i <= cap then
        kept[#kept + 1] = row.marker
      elseif record_omitted then
        projection.omitted[row.name] = projection.omitted[row.name] + 1
      end
    end
    return kept
  end
  out = apply_cap(out, true)
  if want_full then full = apply_cap(full, false) end
  for _, marker in ipairs(out) do
    if type(marker.objective_key) == "string" then
      projection.visible_keys[marker.objective_key] = true
    end
  end
  return out, want_full and full or nil, projection
end

local function objective_grouped_routes(snapshot, player_origin, policy)
  local members, by_endpoint = {}, {}
  local generation = snapshot.generation
  local visible = type(policy.visible_objective_keys) == "table"
    and policy.visible_objective_keys or nil
  local focus_rank, focus_order = {}, {}
  for i, qid in ipairs(objective_array(policy.focus_order) or {}) do
    if objective_uint(qid, 2147483647) and focus_rank[qid] == nil then
      focus_rank[qid] = i; focus_order[#focus_order + 1] = qid
    end
  end
  local function owner_order(obj)
    local best, rank = nil, math.huge
    for _, owner in ipairs(objective_array(obj.owners) or {}) do
      local next_rank = focus_rank[owner.qid] or math.huge
      if next_rank < rank or (next_rank == rank and (best == nil or owner.qid < best.qid)) then
        best, rank = owner, next_rank
      end
    end
    return best, rank
  end
  local function shown(obj)
    return objective_record_valid(snapshot, obj) and (visible == nil or visible[obj.key] == true)
  end
  local function add_obj(obj, source_group)
    if not shown(obj) then return end
    local direct = obj.kind ~= "npc"
    if direct and policy.objective_places ~= true then return end
    if not direct and (policy.npc_route_mode or 0) < 1 then return end
    local pos, cid = objective_copy_pos(obj.target.pos), obj.target.cid
    if direct and not pos then return end
    if not direct and (not cid or not pos) then return end
    local route_id = direct and M.objective_direct_route_id(obj.ordinal) or cid
    local endpoint = direct and ("d:" .. tostring(obj.ordinal)) or ("n:" .. tostring(cid))
    if not route_id or by_endpoint[endpoint] then return end
    local first = owner_order(obj)
    local member = { route_id = route_id, qid = source_group and source_group.qid
        or (first and first.qid), target_key = obj.key, ordinal = obj.ordinal,
      kind = obj.kind, direct = direct, pos = pos, item_ids = obj.item_ids,
      objective = true, objective_generation = generation }
    if obj.kind == "source" then
      member.certainty, member.probability = obj.certainty, obj.probability
      member.capacity_key, member.capacity_kind = obj.capacity_key, obj.capacity_kind
      member.group_keys = {}
      for _, group in ipairs(objective_array(obj.groups) or {}) do
        member.group_keys[#member.group_keys + 1] = group.key
      end
      local item = objective_name(policy, obj)
      if item == obj.source_id then item = "Item " .. tostring(obj.item_ids[1] or "?") end
      local quest = (policy.quest_names or {})[member.qid]
        or ("Quest " .. tostring(member.qid or "?"))
      member.name = "Objective: " .. item .. " (for " .. quest .. ")"
    elseif obj.kind == "npc" then
      member.name = objective_name(policy, obj)
    else
      local caption = objective_name(policy, obj)
      if caption == "Objective" and first then
        caption = (policy.quest_names or {})[first.qid] or ("Quest " .. tostring(first.qid))
      end
      member.name = caption:sub(1, 11) == "Objective: " and caption
        or ("Objective: " .. caption)
    end
    if direct then member.place = 0 else member.cid, member.place = cid, cid end
    by_endpoint[endpoint] = true
    members[#members + 1] = member
  end
  local function add_startable(row)
    if (policy.npc_route_mode or 0) < 1 or type(row) ~= "table"
        or not objective_uint(row.qid, 2147483647)
        or not objective_uint(row.cid, 4294967295) or not valid_pos(row.pos) then return end
    local endpoint = "n:" .. tostring(row.cid)
    if by_endpoint[endpoint] then return end
    by_endpoint[endpoint] = true
    members[#members + 1] = { route_id = row.cid, cid = row.cid, qid = row.qid,
      name = row.name or objective_name(policy, { target = { cid = row.cid } }),
      item_ids = {}, kind = "npc", direct = false, pos = objective_copy_pos(row.pos),
      objective = true, objective_generation = generation }
  end

  local actual_by_qid, missing_focus = {}, {}
  for _, obj in ipairs(snapshot.targets) do
    if shown(obj) and obj.kind ~= "source" then
      local owner = owner_order(obj)
      if owner then
        local list = actual_by_qid[owner.qid]
        if not list then list = {}; actual_by_qid[owner.qid] = list end
        list[#list + 1] = obj
        if focus_rank[owner.qid] == nil then missing_focus[owner.qid] = true end
      end
    end
  end
  for _, list in pairs(actual_by_qid) do
    table.sort(list, function(a, b)
      if (a.route_order or 9) ~= (b.route_order or 9) then
        return (a.route_order or 9) < (b.route_order or 9)
      end
      if (a.sequence or math.huge) ~= (b.sequence or math.huge) then
        return (a.sequence or math.huge) < (b.sequence or math.huge)
      end
      return M.byte_less(a.key, b.key)
    end)
  end

  local group_states = {}
  for _, group in ipairs(objective_array(snapshot.need_groups) or {}) do
    if type(group) == "table" and type(group.key) == "string"
        and objective_uint(group.remaining, 2147483647) then
      local options = {}
      local option_ids = {}
      for _, option in ipairs(objective_array(group.options) or {}) do
        options[option.item_id] = true; option_ids[#option_ids + 1] = option.item_id
      end
      table.sort(option_ids)
      local state = { key = group.key, qid = group.qid, task_index = group.task_index,
        remaining = group.remaining, options = options, option_ids = option_ids }
      group_states[#group_states + 1] = state
      if focus_rank[group.qid] == nil then missing_focus[group.qid] = true end
    end
  end
  table.sort(group_states, function(a, b)
    local ar, br = focus_rank[a.qid] or math.huge, focus_rank[b.qid] or math.huge
    if ar ~= br then return ar < br end
    if a.qid ~= b.qid then return a.qid < b.qid end
    return M.byte_less(a.key, b.key)
  end)
  local pools, pool_by_key = {}, {}
  for _, obj in ipairs(snapshot.targets) do
    if shown(obj) and obj.kind == "source" then
      local pool = pool_by_key[obj.capacity_key]
      if not pool then
        pool = { key = obj.capacity_key, kind = obj.capacity_kind,
          remaining_acquisitions = obj.available_acquisitions,
          certainty = obj.certainty, probability = obj.probability,
          outputs = obj.outputs, sources = {}, matches = {}, selected = false }
        pool_by_key[obj.capacity_key] = pool; pools[#pools + 1] = pool
      end
      pool.sources[#pool.sources + 1] = obj
      for _, match in ipairs(obj.groups) do
        pool.matches[match.key] = match.contribution
      end
    end
  end
  local function distance(obj)
    if not valid_pos(player_origin) or not valid_pos(obj.target.pos) then return math.huge end
    return (obj.target.pos.x-player_origin.x)^2 + (obj.target.pos.y-player_origin.y)^2
      + (obj.target.pos.z-player_origin.z)^2
  end
  local function nearest(pool)
    table.sort(pool.sources, function(a, b)
      local ad, bd = distance(a), distance(b)
      if ad ~= bd then return ad < bd end
      return M.byte_less(a.key, b.key)
    end)
    return pool.sources[1]
  end
  local selected_by_qid = {}
  local function select_pool(pool, group)
    if pool.selected then return end
    pool.selected = true
    local list = selected_by_qid[group.qid]
    if not list then list = {}; selected_by_qid[group.qid] = list end
    list[#list + 1] = { obj = nearest(pool), group = group }
  end
  local function pool_less(a, b)
    local ao, bo = nearest(a), nearest(b)
    local ad, bd = distance(ao), distance(bo)
    if ad ~= bd then return ad < bd end
    return M.byte_less(ao.key, bo.key)
  end
  local surplus, unlimited = {}, {}
  local function consume_surplus(group)
    for _, item_id in ipairs(group.option_ids) do
      if unlimited[item_id] then group.remaining = 0; return end
      local available = surplus[item_id] or 0
      if available > 0 and group.remaining > 0 then
        local used = math.min(available, group.remaining)
        surplus[item_id] = available - used
        group.remaining = group.remaining - used
      end
    end
  end
  for _, group in ipairs(group_states) do
    consume_surplus(group)
    if group.remaining > 0 then
      local candidates = {}
      for _, pool in ipairs(pools) do
        if pool.certainty == "guaranteed" and pool.matches[group.key]
            and (pool.kind == "unlimited" or (pool.remaining_acquisitions or 0) > 0) then
          candidates[#candidates + 1] = pool
        end
      end
      table.sort(candidates, pool_less)
      for _, pool in ipairs(candidates) do
        if group.remaining <= 0 then break end
        local per_acquisition = pool.matches[group.key]
        local used
        if pool.kind == "unlimited" then
          used = math.ceil(group.remaining / per_acquisition)
        else
          used = math.min(pool.remaining_acquisitions,
            math.ceil(group.remaining / per_acquisition))
          pool.remaining_acquisitions = pool.remaining_acquisitions - used
        end
        select_pool(pool, group)
        for _, output in ipairs(pool.outputs) do
          if pool.kind == "unlimited" then
            unlimited[output.item_id] = true
          else
            surplus[output.item_id] = (surplus[output.item_id] or 0) + output.count * used
          end
        end
        consume_surplus(group)
      end
    end
  end
  for _, group in ipairs(group_states) do
    if group.remaining > 0 then
      local candidates = {}
      for _, pool in ipairs(pools) do
        if pool.certainty == "probabilistic" and pool.matches[group.key] then
          candidates[#candidates + 1] = pool
        end
      end
      table.sort(candidates, pool_less)
      if candidates[1] then select_pool(candidates[1], group) end
    end
  end
  local extra = {}; for qid in pairs(missing_focus) do extra[#extra + 1] = qid end
  table.sort(extra)
  for _, qid in ipairs(extra) do focus_order[#focus_order + 1] = qid end
  local startable_by_qid = {}
  for _, row in ipairs(objective_array(policy.startable_givers) or {}) do
    if type(row) == "table" and objective_uint(row.qid, 2147483647) then
      local list = startable_by_qid[row.qid]
      if not list then list = {}; startable_by_qid[row.qid] = list end
      list[#list + 1] = row
    end
  end
  for _, list in pairs(startable_by_qid) do
    table.sort(list, function(a, b) return (a.cid or math.huge) < (b.cid or math.huge) end)
  end
  if policy.search_target then add_obj(policy.search_target) end
  for _, qid in ipairs(focus_order) do
    for _, row in ipairs(startable_by_qid[qid] or {}) do add_startable(row) end
    for _, obj in ipairs(actual_by_qid[qid] or {}) do add_obj(obj) end
    for _, selected in ipairs(selected_by_qid[qid] or {}) do
      add_obj(selected.obj, selected.group)
    end
  end
  if (policy.npc_route_mode or 0) >= 2 then
    for _, row in ipairs(objective_array(policy.shown_ancillary) or {}) do
      if type(row) == "table" and objective_uint(row.cid, 4294967295)
          and objective_uint(row.qid, 2147483647) then
        local endpoint = "n:" .. tostring(row.cid)
        if not by_endpoint[endpoint] then
          by_endpoint[endpoint] = true
          members[#members + 1] = { route_id = row.cid, cid = row.cid,
            name = row.name or objective_name(policy, { target = { cid = row.cid } }),
            item_ids = {}, qid = row.qid, kind = "npc", direct = false,
            pos = objective_copy_pos(row.pos), objective = false,
            objective_generation = generation }
        end
      end
    end
  end
  local cap = math.min(8, math.max(0, policy.route_cap or 8))
  local total = #members
  while #members > cap do members[#members] = nil end
  return { objective_generation = generation, members = members,
    total = total, omitted = total - #members }, #members, total
end

function M.objective_routes(snapshot, player_origin, policy)
  policy = type(policy) == "table" and policy or {}
  local members, by_endpoint = {}, {}
  if type(snapshot) ~= "table" or not objective_generation(snapshot.generation)
      or objective_array(snapshot.targets) == nil then
    return { objective_generation = 0, members = members, total = 0, omitted = 0 }, 0, 0
  end
  if snapshot.grouped_needs == true and objective_array(snapshot.need_groups) ~= nil then
    return objective_grouped_routes(snapshot, player_origin, policy)
  end
  local generation = snapshot.generation
  local focus_rank = {}
  for i, qid in ipairs(objective_array(policy.focus_order) or {}) do focus_rank[qid] = i end
  local function owner_order(obj)
    local best, best_rank = nil, math.huge
    for _, owner in ipairs(objective_array(obj.owners) or {}) do
      if type(owner) == "table" and objective_uint(owner.qid, 2147483647) then
        local rank = focus_rank[owner.qid] or math.huge
        if rank < best_rank or (rank == best_rank and (best == nil or owner.qid < best.qid)) then
          best, best_rank = owner, rank
        end
      end
    end
    return best, best_rank
  end
  local items = {}
  for _, obj in ipairs(snapshot.targets) do
    if objective_record_valid(snapshot, obj) and obj.kind == "source" then
      for _, item_id in ipairs(objective_array(obj.item_ids) or {}) do
        local prev = items[item_id]
        local d2 = valid_pos(player_origin) and valid_pos(obj.target.pos)
          and ((obj.target.pos.x-player_origin.x)^2+(obj.target.pos.y-player_origin.y)^2+(obj.target.pos.z-player_origin.z)^2) or math.huge
        if not prev or d2 < prev.d2 or (d2 == prev.d2 and M.byte_less(obj.source_id, prev.obj.source_id)) then
          items[item_id] = { obj = obj, d2 = d2 }
        end
      end
    end
  end
  local ordered = {}
  for _, obj in ipairs(snapshot.targets) do
    if objective_record_valid(snapshot, obj) and obj.kind ~= "source" then
      ordered[#ordered + 1] = obj
    end
  end
  table.sort(ordered, function(a, b)
    local _, ar = owner_order(a)
    local _, br = owner_order(b)
    if ar ~= br then return ar < br end
    local ak, bk = a.route_order or 9, b.route_order or 9
    if ak ~= bk then return ak < bk end
    if (a.sequence or math.huge) ~= (b.sequence or math.huge) then
      return (a.sequence or math.huge) < (b.sequence or math.huge)
    end
    return M.byte_less(a.key, b.key)
  end)
  local function add(obj)
    if not objective_record_valid(snapshot, obj) then return end
    if obj.kind == "source" and policy.objective_places ~= true then return end
    local direct = obj.kind ~= "npc"
    if direct and policy.objective_places ~= true then return end
    if obj.kind == "source" then
      if policy.objective_places ~= true then return end
    elseif not direct and (policy.npc_route_mode or 0) < 1 then return end
    local pos = objective_copy_pos(obj.target.pos)
    local cid = obj.target.cid
    if direct and not pos then return end
    if not direct and (not cid or not pos) then return end
    local route_id = direct and M.objective_direct_route_id(obj.ordinal) or cid
    if not route_id then return end
    local endpoint = direct and ("d:" .. tostring(obj.ordinal)) or ("n:" .. tostring(cid))
    if by_endpoint[endpoint] then return end
    local first = owner_order(obj)
    local member = { route_id = route_id, qid = first and first.qid, target_key = obj.key,
      ordinal = obj.ordinal, kind = obj.kind, direct = direct, pos = pos, item_ids = obj.item_ids,
      objective = true, objective_generation = generation }
    if obj.kind == "npc" then
      member.name = objective_name(policy, obj)
    elseif obj.kind == "place" then
      local caption = objective_name(policy, obj)
      if caption == "Objective" and first ~= nil then
        caption = (policy.quest_names or {})[first.qid] or ("Quest " .. tostring(first.qid))
      end
      member.name = caption:sub(1, 11) == "Objective: " and caption or ("Objective: " .. caption)
    else
      local item = objective_name(policy, obj)
      if item == obj.source_id then
        item = "Item " .. tostring((objective_array(obj.item_ids) or {})[1] or "?")
      end
      local quest = first ~= nil and (policy.quest_names or {})[first.qid] or nil
      if type(quest) ~= "string" or quest == "" then
        quest = "Quest " .. tostring(first and first.qid or "?")
      end
      member.name = "Objective: " .. item .. " (for " .. quest .. ")"
    end
    if direct then member.place = 0 else member.cid, member.place = cid, cid end
    by_endpoint[endpoint] = true; members[#members + 1] = member
  end
  if policy.search_target then add(policy.search_target) end
  -- SPEC 39 compatibility: startable givers are outside the progressing-only
  -- objective snapshot; merge them into focus order before the next quest.
  local startable_givers, next_startable = {}, 1
  if (policy.npc_route_mode or 0) >= 1 then
    for _, row in ipairs(objective_array(policy.startable_givers) or {}) do
      if type(row) == "table" and objective_uint(row.qid, 2147483647)
          and objective_uint(row.cid, 4294967295) and valid_pos(row.pos) then
        startable_givers[#startable_givers + 1] = row
      end
    end
    table.sort(startable_givers, function(a, b)
      local ar, br = focus_rank[a.qid] or math.huge, focus_rank[b.qid] or math.huge
      if ar ~= br then return ar < br end
      if a.qid ~= b.qid then return a.qid < b.qid end
      return a.cid < b.cid
    end)
  end
  local function add_startable(row)
    if type(row) == "table" and objective_uint(row.qid, 2147483647)
        and objective_uint(row.cid, 4294967295) and valid_pos(row.pos) then
      local endpoint = "n:" .. tostring(row.cid)
      if not by_endpoint[endpoint] then
        by_endpoint[endpoint] = true
        members[#members + 1] = { route_id = row.cid, cid = row.cid,
          name = row.name or objective_name(policy, { target = { cid = row.cid } }),
          item_ids = {}, qid = row.qid, kind = "npc", direct = false,
          pos = objective_copy_pos(row.pos), objective = true,
          objective_generation = generation }
      end
    end
  end
  for _, obj in ipairs(ordered) do
    local _, rank = owner_order(obj)
    while startable_givers[next_startable] ~= nil do
      local row = startable_givers[next_startable]
      local giver_rank = focus_rank[row.qid] or math.huge
      if giver_rank > rank then break end
      add_startable(row)
      next_startable = next_startable + 1
    end
    add(obj)
  end
  while startable_givers[next_startable] ~= nil do
    add_startable(startable_givers[next_startable])
    next_startable = next_startable + 1
  end
  local ids = {}; for id in pairs(items) do ids[#ids + 1] = id end; table.sort(ids)
  for _, id in ipairs(ids) do add(items[id].obj) end
  if (policy.npc_route_mode or 0) >= 2 then
  for _, row in ipairs(objective_array(policy.shown_ancillary) or {}) do
    if type(row) == "table" and objective_uint(row.cid, 4294967295)
        and objective_uint(row.qid, 2147483647) then
      local seen = false
      for _, member in ipairs(members) do if member.cid == row.cid then seen = true end end
      if not seen then members[#members + 1] = { route_id = row.cid, cid = row.cid,
        name = row.name or objective_name(policy, { target = { cid = row.cid } }), item_ids = {},
        qid = row.qid, kind = "npc", direct = false, pos = objective_copy_pos(row.pos),
        objective = false, objective_generation = generation } end
    end
  end
  end
  local cap = math.min(8, math.max(0, policy.route_cap or 8))
  local total = #members
  while #members > cap do members[#members] = nil end
  return { objective_generation = generation, members = members,
    total = total, omitted = total - #members }, #members, total
end

return M
