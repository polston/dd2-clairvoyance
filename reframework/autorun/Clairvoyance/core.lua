-- core.lua — pure logic; no sdk/re/imgui/json. Tested by tests/core_test.lua.
local M = {}

M.HYSTERESIS_UNITS = 5.0

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

local function pos_key(p)
  return string.format("p:%d:%d:%d",
    math.floor(p.x), math.floor(p.y), math.floor(p.z))
end

local STATE_TEXT = {
  startable = "startable", in_progress = "in progress",
  completed = "completed", failed = "failed", canceled = "canceled",
  giver_dead = "giver dead", locked = "locked",
}
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
  local c = { cat = cat, qids = {}, pos = e.pos, cid = e.cid }
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
  for _, e in ipairs(world.chests or {}) do
    if valid_pos(e.pos) then
      local hit, ids = false, {}
      for _, q in ipairs(type(e.gate_qids) == "table" and e.gate_qids or {}) do
        if fx.qids[q] then hit = true; break end
      end
      local gated = hit
      if e.item ~= nil and fx.items[e.item] then hit = true; ids[e.item] = true end
      for _, id in ipairs(type(e.item_ids) == "table" and e.item_ids or {}) do
        if fx.items[id] then hit = true; ids[id] = true end
      end
      if hit then
        list[#list + 1] = { cat = "chest", e = e, gated = gated, ids = ids }
        set[e] = true
      end
    end
  end
  for _, e in ipairs(world.sellers or {}) do
    if valid_pos(e.pos) then
      local hit = false
      for _, q in ipairs(type(e.qids) == "table" and e.qids or {}) do
        if fx.qids[q] then hit = true; break end
      end
      if hit then list[#list + 1] = { cat = "seller", e = e }; set[e] = true end
    end
  end
  return list, set
end

-- The candidates of the related entries, ordered by key: outside the toggles
-- and kind filters, never hidden by the cap. A hidden one (opened, undiscovered,
-- at a box) is dropped. Under a query, one that does not match is marked
-- focus_kept (drawn, but not a result).
local function related_cands(list, world, show, boxes, q, labels, origin)
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
      c.rel_ids = p.cat == "chest" and not p.gated and p.ids or nil
      out[#out + 1] = c
    end
  end
  -- SPEC 32.6.1.3: a chest matched only through items is capped per item id,
  -- nearest the origin first; a gate-matched chest is always kept
  local has_o = valid_pos(origin)
  local pend = {}
  for _, c in ipairs(out) do
    if c.rel_ids ~= nil then
      c.rel_d = has_o and valid_pos(c.pos) and dist2(c.pos, origin) or 0
      pend[#pend + 1] = c
    end
  end
  if #pend > 0 then
    table.sort(pend, function(x, y)
      if x.rel_d ~= y.rel_d then return x.rel_d < y.rel_d end
      return x.key < y.key
    end)
    local cnt, drop = {}, {}
    for _, c in ipairs(pend) do
      local keep = false
      for id in pairs(c.rel_ids) do
        if (cnt[id] or 0) < 3 then keep = true; break end
      end
      if keep then
        for id in pairs(c.rel_ids) do cnt[id] = (cnt[id] or 0) + 1 end
      else
        drop[c] = true
      end
    end
    local kept = {}
    for _, c in ipairs(out) do
      if not drop[c] then kept[#kept + 1] = c end
    end
    out = kept
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
    quest_cids, ft, kcounts, related_cands(flist, world, show, boxes, show.search, nil, origin))
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
    quest_cids, ft, g.kinds, related_cands(flist, world, show, boxes, q, g.labels, origin))
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

local function journal_pass(read, prev, always, expanded, now)
  local out = {}
  local function take(q)
    local v = read(q)
    if type(v) ~= "table" then v = { missing = true } end
    v.read_at = now
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
function M.journal_reads(adapter, quests, show, tracked_qid, nearest_qid, by_in)
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
      always, expanded, now)
  end
  if spoilers and adapter.journal_all then
    journal_all = journal_pass(adapter.journal_all, show.prev_journal_all or {},
      always, expanded, now)
  end
  return journal, journal_all
end

-- All v9 per-record fields and reads for one tick (only called while the
-- tree records exist).
function M.tree_detail(adapter, quests, show, rec_by)
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
    tracked_qid, nearest_qid, rec_by)
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

-- Matches the settings defaults so a caller that predates the show table
-- (mid-merge state before Task 4 lands) still computes v1-equivalent output.
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
    or m.needs ~= needs or #m.active ~= #active then
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
  live = live or {}
  local givers, prog = live.givers or {}, live.prog or {}
  live = { givers = givers, prog = prog }
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
    result[qid] = { npcs = npcs, step_npcs = step, items = items, places = pl }
  end

  local keep_active, keep_givers, keep_prog = {}, {}, {}
  for i, qid in ipairs(active) do
    keep_active[i] = qid
    keep_givers[i] = givers[qid]
    keep_prog[i] = (prog[qid] == true)
  end
  related_memo = { adapter = adapter, active = keep_active, givers = keep_givers,
    prog = keep_prog, rel = rel, places = places, needs = needs, objs = objs, result = result }
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

  local seen, qids = {}, {}
  local function add(list)
    if list == nil then return end
    for _, qid in ipairs(list) do
      if type(qid) == "number" and not seen[qid] then
        seen[qid] = true
        qids[#qids + 1] = qid
      end
    end
  end
  add(acceptable); add(progressing); add(catalog)
  table.sort(qids)

  local counts = { startable = 0, in_progress = 0, completed = 0,
    failed = 0, canceled = 0, giver_dead = 0, locked = 0 }
  local groups, order = {}, {}
  local unresolved, resolved_count = {}, 0
  -- Eager: a save with zero side quests still shows an empty tree.
  local quests, rec_by = nil, nil
  if show.tree_open and adapter.quest_region then quests, rec_by = {}, {} end
  local shown_inprog = {}   -- v8: in-progress qids that survive the visibility drop

  -- v19 (SPEC 32): the focused quests that are live. focus_inprog is set here,
  -- before the loop, whose first statement drops main quests.
  local active = M.focus_active(show.focus_qids, show.focus_tracked_qid, adapter)
  local fset, focus_inprog, focus_rec = {}, {}, {}
  for _, qid in ipairs(active) do
    fset[qid] = true
    if prog[qid] then focus_inprog[qid] = true end
  end

  for _, qid in ipairs(qids) do
    repeat
      if not adapter.is_side(qid) then break end

      local hint, cands = giver_candidates(adapter, qid)
      if fset[qid] then focus_rec[qid] = { hint = hint, first = cands[1] } end

      -- Category: specific before generic (SPEC §9.2).
      local cat
      if prog[qid] then
        cat = "in_progress"
      else
        local st = adapter.quest_state(qid)
        -- An unexpected state string must not crash the tick: treat it as
        -- no state rather than indexing counts/GROUP with an unknown key.
        if st ~= nil and counts[st] == nil then st = nil end
        if st ~= nil then
          cat = st
        elseif acc[qid] then
          -- An unknown NPC counts as alive; only a dead giver lands here.
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

      counts[cat] = counts[cat] + 1
      -- v7 (SPEC 14.3b): tree records, built only while the panel is open,
      -- BEFORE the visibility break and any position work. Hidden
      -- categories still get a record; ascending qid order is inherited.
      local nm
      if quests ~= nil then
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
      if cat == "in_progress" and show[GROUP[cat]] then shown_inprog[qid] = true end
      -- A locked quest that no name source can label (no log entry, nothing
      -- learned, nothing in the game's text files) gets no marker rather
      -- than a "Quest <qid>" placeholder. An empty name counts as no name.
      if quests == nil then nm = adapter.quest_name(qid) end
      if cat == "locked" and (nm == nil or nm == "") then break end

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
      if focus_rec[qid] ~= nil then focus_rec[qid].cid = M.marker_cid(g) end
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

  local tracked_qid, nearest_qid, journal, journal_all
  if quests ~= nil then
    tracked_qid, nearest_qid, journal, journal_all = M.tree_detail(adapter, quests, show, rec_by)
  end

  -- v8 (SPEC 15.3h): item markers, appended AFTER every quest marker
  local item_capped = 0
  local item_toggles = show.quest_items and show.in_progress
  if (item_toggles or next(focus_inprog) ~= nil) and adapter.item_needs ~= nil then
    local ims
    ims, item_capped = M.item_markers(adapter, item_toggles and shown_inprog or {},
      show.origin, q, focus_inprog)
    for _, m in ipairs(ims) do markers[#markers + 1] = m end
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
      and type(route.cid) == "number" then
      for n, s in ipairs(route.stops) do
        if type(s) == "table" and valid_pos(s.pos)
          and (s.discovered ~= false or undisc) then
          markers[#markers + 1] = {
            key = string.format("r:%d:%d", math.floor(route.cid), n),
            cat = "route_stop", qids = {}, pos = pos_copy(s.pos),
            label = string.format("%s %02d-%02d", tostring(route.name),
              math.floor(tonumber(s.from) or 0), math.floor(tonumber(s.to) or 0)),
            cid = route.cid, stop = n }
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
      for _, cid in ipairs(rs[qid] and rs[qid].npcs or {}) do
        if not seen_cid[cid] then
          seen_cid[cid] = true
          local covered = cover_key[cid]
          if covered ~= nil then rel_keys[covered] = true end
          if adapter.npc_alive(cid) ~= false then
            local x, y, z = adapter.npc_pos(cid)
            if x == nil then
              no_pos[#no_pos + 1] = cid
            elseif covered == nil then
              local label = names and names[cid]
              if label == nil or label == "" then
                label = adapter.npc_name and adapter.npc_name(cid) or nil
              end
              if label == nil or label == "" then label = "NPC " .. cid end
              markers[#markers + 1] = { key = string.format("n:%d", cid), cat = "focus_npc",
                cid = cid, qids = {}, pos = { x = x, y = y, z = z }, label = label }
              added = added + 1
            end
          end
        end
      end
    end
    -- 3. destination markers, one per place key
    local fplaces = (show.world or {}).focus_places
    local pk, pseen = {}, {}
    for _, qid in ipairs(active) do
      for _, key in ipairs(rs[qid] and rs[qid].places or {}) do
        if not pseen[key] then pseen[key] = true; pk[#pk + 1] = key end
      end
    end
    for _, key in ipairs(pk) do
      local pp = type(fplaces) == "table" and fplaces[key] or nil
      if valid_pos(pp) then
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
    -- 4. the hide / dim pass
    local dim = show.focus_unrelated == 1
    local function related(m)
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
    focus_counts = { related = 0, added = added, dimmed = 0, hidden = 0, no_pos = no_pos }
    pass(markers, focus_counts)
    if fullmap_world ~= nil then pass(fullmap_world) end
  end

  return {
    markers = markers,
    unresolved = unresolved,
    unnamed = unnamed,
    counts = counts,
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
    focus_counts = focus_counts,
  }
end

-- The tree walk is wanted only while the panel was drawn within the last
-- second (pure; the caller supplies both timestamps).
function M.tree_wanted(now, open_at)
  return open_at ~= nil and now - open_at < 1.0
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
      (m.cat or "") .. (m.done and "|d" or "") .. (m.faded and "|f" or "") .. (m.dim and "|m" or "") .. (m.step and ("|s" .. m.step) or ""))
  end
  table.sort(parts)
  return table.concat(parts, "|"), new_committed
end

-- v3 overhead layer (SPEC §10.2c): pure helpers, no sdk.
function M.marker_cid(m)
  if type(m) ~= "table" or type(m.key) ~= "string" then return nil end
  if m.cat == "focus_npc" then return m.cid end
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
-- { cids = {[qid]={cid,...}}, miss = {[qid]=n},
--   issued_streak = {[qid]={cid=c,n=n}} }.
function M.objective_table(records, prev, progressing)
  local prev_cids = prev and prev.cids or {}
  local prev_miss = prev and prev.miss or {}
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
  local out = { cids = {}, miss = {}, issued_streak = {} }
  for qid, set in pairs(by_qid) do
    local issued, rest = {}, {}
    for cid, is in pairs(set) do
      if is then issued[#issued + 1] = cid else rest[#rest + 1] = cid end
    end
    table.sort(issued)
    table.sort(rest)
    local arr = {}
    for _, c in ipairs(issued) do arr[#arr + 1] = c end
    for _, c in ipairs(rest) do arr[#arr + 1] = c end
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
        local top = issued[1]
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
  return out
end

return M
