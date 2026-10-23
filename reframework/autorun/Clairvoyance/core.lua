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

local function gate_suffix(refs, adapter, show)
  local names, seen = {}, {}
  for _, ref in ipairs(refs) do
    local nm
    if show and show.reveal_gate_names then nm = adapter.quest_name(ref) end
    if (nm == nil or nm == "") and adapter.seen_quest_name then
      nm = adapter.seen_quest_name(ref)
    end
    if nm == nil or nm == "" then nm = "another quest" end
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

function M.item_markers(adapter, shown_inprog, origin, q)
  local needs = adapter.item_needs and adapter.item_needs() or nil
  if type(needs) ~= "table" then return {}, 0 end
  local by_id = M.needs_by_item(needs, shown_inprog)   -- item id -> needing shown quests
  if next(by_id) == nil then return {}, 0 end
  for _, qs in pairs(by_id) do table.sort(qs) end

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
      if m then matched[#matched + 1] = e end
    end
    entries = matched
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
      label = label, item_ord = o,
    }
  end
  return markers, capped
end

-- v10 (SPEC 17.4): world markers. Categories in output order; WORLD_DEF.toggle
-- names the show field that switches each one and WORLD_DEF.src the world
-- table list that feeds it.
M.WORLD_CATS = { "treasure", "token", "beetle", "seller", "monster", "chest",
  "shop" }
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
}
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

-- Chest label (SPEC 17.10.11): item_name wins; else up to three item names,
-- "<name> x<n>" for n > 1, then " (+N)" for the rest; no items: "Chest".
function M.chest_label(chest)
  local e = chest or {}
  if type(e.item_name) == "string" and e.item_name ~= "" then
    return "Chest - " .. e.item_name
  end
  local items = type(e.items) == "table" and e.items or {}
  local names = {}
  for i, it in ipairs(items) do
    if i > 3 then break end
    local n = tostring(it.name)
    if type(it.n) == "number" and it.n > 1 then
      n = n .. " x" .. tostring(math.floor(it.n))
    end
    names[#names + 1] = n
  end
  if #names == 0 then return "Chest" end
  return "Chest - " .. top3(names, #items)
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

-- Is this entry a candidate at all (counted in `known`)?
local function included(cat, e, small_ok, dups)
  if not valid_pos(e.pos) then return false end
  if cat == "treasure" and dups[e] then return false end
  if cat == "monster" and e.small == true and not small_ok then return false end
  return true
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
local function monster_drops_of(e, drops)
  if type(drops) ~= "table" then return nil end
  local names, shown, seen = {}, {}, {}
  for _, c in ipairs(e.cids or { e.cid }) do
    local list = drops[c]
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
    if query_match(q, low) then hit[#hit + 1] = md.shown[i] end
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
    return hay_join(parts)
  elseif cat == "treasure" then
    return hay_join({ "Treasure" })
  elseif cat == "monster" then
    local parts = { monster_label(e) }
    if md == nil then md = monster_drops_of(e, drops) end   -- false: none
    for _, n in ipairs(md and md.names or {}) do parts[#parts + 1] = n end
    return hay_join(parts)
  elseif cat == "seller" then
    return hay_join({ seller_label(e) })
  end
  return hay_join({ e.name })
end

-- Cached haystack of an entry; `cache` may be nil (uncached path). A
-- monster with drops caches a table (SPEC 19.12.4.3); the haystack is
-- returned first, that table (or nil) second.
local function hay_of(cache, cat, e, drops)
  local h = cache and cache[e]
  if h == nil then
    local md = false   -- false: looked up, none
    if cat == "monster" and drops ~= nil then
      md = monster_drops_of(e, drops) or false
    end
    h = entry_hay(cat, e, drops, md)
    if md then h = { hay = h, names = md.names, shown = md.shown } end
    if cache then cache[e] = h end
  end
  if type(h) == "table" then return h.hay, h end
  return h
end

-- SPEC 19.7: the counting items a query selects from a shop entry, or nil.
-- hay = { npc = <lower>, names = { <lower>, ... } } (cached per entry).
local function shop_hay(cache, e)
  local h = cache and cache[e]
  if h == nil then
    h = { npc = tostring(e.npc):lower(), names = {} }
    for i, it in ipairs(e.items) do h.names[i] = tostring(it.name):lower() end
    if cache then cache[e] = h end
  end
  return h
end

local function shop_listing(e, q, h)
  local items = e.items
  if type(items) ~= "table" or #items == 0 then return nil end
  if query_match(q, h.npc) then return items end
  local out = {}
  for i, it in ipairs(items) do
    if query_match(q, h.names[i]) then out[#out + 1] = it end
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
  elseif cat == "treasure" then
    c.key = "w:tre:" .. tostring(e.name)
    c.label = "Treasure"
    c.done = e.checked == true
    c.hidden = (e.discovered == false) and not ctx.undisc
  elseif cat == "token" or cat == "beetle" then
    c.key = (cat == "token" and "w:tok:" or "w:bee:") .. tostring(e.uid)
    c.label = tostring(e.name)
    c.done = e.state == "collected"
    c.hidden = c.done and not ctx.show_opened
  elseif cat == "monster" then
    c.key = "w:mon:" .. tostring(e.uid)
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
  else
    for i, q in ipairs(e.qids or {}) do c.qids[i] = q end
    c.key = string.format("w:sell:%s:%s", tostring(e.shop), tostring(e.item))
    c.label = seller_label(e)
    c.shop = e.shop
    c.quest = e.quest
    c.item_name = e.item_name
    c.hidden = (e.discovered == false) and not ctx.undisc
  end
  return c
end

local function world_ctx(show, boxes)
  return { show_opened = show.world_show_opened == true,
    undisc = show.world_undiscovered == true, boxes = boxes or {},
    mdrop = show.search ~= nil and {} or nil }
end

-- Shop candidates (SPEC 19.7, 20.3): while a search is active (the matching
-- entries) or show.world_shops is on (every entry with stock). With neither
-- the shop list is not read at all. Returns the list, the entry count and
-- the shop-id -> visible-candidate set.
local function shop_cands(world, q, ctx, cache, shops_on)
  local out, shop_of = {}, {}
  local list = (q ~= nil or shops_on) and type(world.shops) == "table"
    and world.shops or {}
  ctx.slabel = {}
  -- no-search key "" is distinct from every query key (a query has a term)
  local qkey = q ~= nil and q.key or ""
  for _, e in ipairs(list) do
    if valid_pos(e.pos) and type(e.items) == "table" then
      local h = shop_hay(cache, e)
      if h.qkey ~= qkey then   -- listing and label change only with the query
        h.qkey = qkey
        if q ~= nil then
          h.list = shop_listing(e, q, h) or false
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
local function world_candidates(world, show, boxes, q)
  local cands, known = {}, {}
  local ctx = world_ctx(show, boxes)
  local small_ok = show.world_small_monsters == true
  local dups = treasure_dups(world)
  local drops = q ~= nil and world.drops or nil
  for _, cat in ipairs(M.WORLD_CATS) do
    known[cat] = 0
    if cat ~= "shop" then
      for _, e in ipairs(world[WORLD_DEF[cat].src] or {}) do
        if included(cat, e, small_ok, dups) then
          known[cat] = known[cat] + 1
          local md = false
          if cat == "monster" and drops ~= nil then
            md = monster_drops_of(e, drops) or false
          end
          if q == nil or query_match(q, entry_hay(cat, e, drops, md)) then
            if md then
              local hv, why = drop_hover(monster_label(e), md, q)
              if hv then ctx.mdrop[e] = { hover = hv, why = why } end
            end
            cands[#cands + 1] = make_cand(cat, e, ctx)
          end
        end
      end
    end
  end
  local sc, n, shop_of = shop_cands(world, q, ctx, nil,
    show.world_shops == true)
  known.shop = n
  for _, c in ipairs(sc) do cands[#cands + 1] = c end
  return cands, known, shop_of
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
  return panel
end

-- Seller merge or keep, shared by the uncached and the cached path.
-- Seller lines of a shop go to its `sells_for` list (hover and merged line
-- are built in world_finish, so accept order does not matter). With
-- shops_on shops compete for the cap like any category; with it off (a
-- search only) they go to their own list (`shops`) and fill what the cap
-- leaves (SPEC 19.7.5). Every shop accepted is also listed in `shop_all`.
local function world_accept(c, has_origin, origin, quest_cids, kept, merged,
                            shops, shop_of, shops_on, shop_all)
  if c.cat == "shop" then shop_all[#shop_all + 1] = c end
  if c.cat == "seller" and shop_of and shop_of[c.shop] then
    -- SPEC 19.7.7: the shop marker stands in for its seller
    local sc = shop_of[c.shop]
    if type(c.quest) == "string" and c.quest ~= "" then
      sc.sells_for[#sc.sells_for + 1] = tostring(c.item_name)
        .. " (for " .. c.quest .. ")"
    end
    -- The shop stands in for this seller: it competes for the cap at its
    -- own distance (ruling), not for the leftover slots.
    if not sc.promoted then
      sc.promoted = true
      sc.rank_cat = "seller"
      if sc.in_shops then
        for i, x in ipairs(shops) do
          if x == sc then table.remove(shops, i); break end
        end
        sc.in_shops = false
        kept[#kept + 1] = sc
      end
    end
    return
  end
  if (c.cat == "seller" or c.cat == "shop") and type(c.cid) == "number"
    and quest_cids and quest_cids[c.cid] then
    merged[#merged + 1] = { cid = c.cid, cand = c }
    if c.cat == "shop" then c.merged = true end
  else
    c.d = has_origin and dist2(c.pos, origin) or 0
    if c.cat == "shop" and not c.promoted and not shops_on then
      shops[#shops + 1] = c
      c.in_shops = true
    else
      kept[#kept + 1] = c
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
local function world_finish(kept, merged, panel, cap, has_origin, shops, shop_all)
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
  if shops and #shops > 0 and #kept < cap then
    table.sort(shops, function(x, y)
      if has_origin and x.d ~= y.d then return x.d < y.d end
      return x.key < y.key
    end)
    for i = 1, math.min(#shops, cap - #kept) do kept[#kept + 1] = shops[i] end
  end

  -- world_ord: rank by key in the kept set, so marker identity does not
  -- follow the distance order (as item_ord).
  table.sort(kept, function(x, y) return x.key < y.key end)
  for i, c in ipairs(kept) do c.world_ord = i end

  table.sort(kept, function(x, y)
    if x.cat ~= y.cat then return WORLD_CAT_RANK[x.cat] < WORLD_CAT_RANK[y.cat] end
    if has_origin and x.d ~= y.d then return x.d < y.d end
    return x.key < y.key
  end)
  local markers = {}
  local in_kept = shop_all and #shop_all > 0 and {} or nil
  for _, c in ipairs(kept) do
    if in_kept then in_kept[c] = true end
    local m = { key = c.key, cat = c.cat, qids = c.qids,
      pos = pos_copy(c.pos),
      label = c.label, done = c.done, world_ord = c.world_ord, hover = c.hover,
      why = c.why }
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
  return markers, panel, merged
end

-- Selection, order and panel (SPEC 17.4b, 17.4g). `quest_cids` (optional)
-- is a set of cids that already have a c:<cid> quest marker; their sellers
-- merge into that marker's hover instead of drawing. Returns markers,
-- panel, merged where merged is a list of { cid, line }. Uncached; the
-- per-tick entry point is world_markers_cached.
function M.world_markers(world, show, origin, boxes, quest_cids)
  world = world or {}
  show = show or {}
  local panel = new_panel()
  local cap = world_cap(show)
  local has_origin = valid_pos(origin)

  local kept, merged, shops, shop_all = {}, {}, {}, {}
  local shops_on = show.world_shops == true
  local cands, known, shop_of = world_candidates(world, show, boxes, show.search)
  for _, cat in ipairs(M.WORLD_CATS) do panel[cat].known = known[cat] end
  for _, c in ipairs(cands) do
    if (c.cat == "shop" or show[WORLD_DEF[c.cat].toggle] ~= false) and not c.hidden then
      world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
        shops_on, shop_all)
    end
  end
  return world_finish(kept, merged, panel, cap, has_origin, shops, shop_all)
end

-- Cached entry point (SPEC 17.10.10). A 256-unit grid of the world's
-- entries (x, z cells) is built once per world table and small-monster
-- setting; sellers stay a plain list. The counters are for tests.
local CELL = 256
M.world_stats = { grid_builds = 0, cand_builds = 0 }
local grid_cache = { world = nil, small = nil, grid = nil }

local function cell_of(v) return math.floor(v / CELL) end
local function cell_key(ci, cj)
  return (ci + 1048576) * 2097152 + (cj + 1048576)
end

local function build_grid(world, small_ok)
  M.world_stats.grid_builds = M.world_stats.grid_builds + 1
  local dups = treasure_dups(world)
  local g = { cells = {}, flat = {}, known = {} }
  for _, cat in ipairs(M.WORLD_CATS) do
    g.known[cat] = 0
    g.flat[cat] = {}
    for _, e in ipairs(cat ~= "shop" and world[WORLD_DEF[cat].src] or {}) do
      if included(cat, e, small_ok, dups) then
        g.known[cat] = g.known[cat] + 1
        if cat ~= "seller" then
          local ci, cj = cell_of(e.pos.x), cell_of(e.pos.z)
          local key = cell_key(ci, cj)
          local cell = g.cells[key]
          if not cell then cell = {}; g.cells[key] = cell end
          local l = cell[cat]
          if not l then l = {}; cell[cat] = l end
          l[#l + 1] = e
          local f = g.flat[cat]
          f[#f + 1] = e
          if not g.mini or ci < g.mini then g.mini = ci end
          if not g.maxi or ci > g.maxi then g.maxi = ci end
          if not g.minj or cj < g.minj then g.minj = cj end
          if not g.maxj or cj > g.maxj then g.maxj = cj end
        end
      end
    end
  end
  return g
end

function M.world_markers_cached(world, show, origin, boxes, quest_cids, stats)
  world = world or {}
  show = show or {}
  stats = stats or M.world_stats
  local small_ok = show.world_small_monsters == true
  local g = grid_cache.grid
  if grid_cache.world ~= world or grid_cache.small ~= small_ok or not g then
    g = build_grid(world, small_ok)
    grid_cache.world, grid_cache.small, grid_cache.grid = world, small_ok, g
  end
  local panel = new_panel()
  for _, cat in ipairs(M.WORLD_CATS) do panel[cat].known = g.known[cat] end
  local cap = world_cap(show)
  local has_origin = valid_pos(origin)
  local ctx = world_ctx(show, boxes)
  -- chest labels depend only on the entry, so they live as long as the grid
  g.labels = g.labels or {}
  ctx.labels = g.labels
  local on = {}
  for _, cat in ipairs(M.WORLD_CATS) do
    if cat ~= "shop" and show[WORLD_DEF[cat].toggle] ~= false then
      on[#on + 1] = cat
    end
  end

  -- SPEC 19.8.3: with a query only entries whose cached haystack matches
  -- reach make_cand; haystacks live as long as the grid.
  local q = show.search
  g.hay = g.hay or {}
  if q ~= nil and (g.mkey ~= q.key or g.match == nil) then
    g.mkey, g.match = q.key, {}
  end
  local kept, merged, shops, shop_all = {}, {}, {}, {}
  local shop_of = {}
  local shops_on = show.world_shops == true
  if q ~= nil or shops_on then
    local sc, n
    sc, n, shop_of = shop_cands(world, q, ctx, g.hay, shops_on)
    panel.shop.known = n
    for _, c in ipairs(sc) do
      stats.cand_builds = stats.cand_builds + 1
      if not c.hidden then
        world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
          shops_on, shop_all)
      end
    end
  end
  local drops = q ~= nil and world.drops or nil
  local qkey = q ~= nil and q.key or nil
  local function take(cat, e)
    if q ~= nil then
      local hay, dh = hay_of(g.hay, cat, e, drops)
      local m = g.match[e]   -- match result, memoised per query key
      if m == nil then
        m = query_match(q, hay)
        g.match[e] = m
      end
      if not m then return end
      if dh then
        if dh.qkey ~= qkey then   -- hover and why change only with the query
          dh.qkey = qkey
          dh.hover, dh.why = drop_hover(monster_label(e), dh, q)
        end
        if dh.hover then ctx.mdrop[e] = dh end
      end
    end
    stats.cand_builds = stats.cand_builds + 1
    local c = make_cand(cat, e, ctx)
    if not c.hidden then
      world_accept(c, has_origin, origin, quest_cids, kept, merged, shops, shop_of,
        shops_on, shop_all)
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
  return world_finish(kept, merged, panel, cap, has_origin, shops, shop_all)
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

-- The `limit` (default WORLD_ROWS, ten) nearest entries to origin as panel
-- rows (SPEC 17.4g); all of them in list order when origin is nil.
-- Settlement = nearest by 3D distance. Shop entries carry stock, sells_for,
-- merged and offmap onto their row (SPEC 20.5.3-7).
function M.world_rows(entries, settlements, origin, limit)
  local list = {}
  for i, e in ipairs(entries or {}) do
    list[i] = { e = e, i = i, d = valid_pos(origin) and dist2(e.pos, origin) or 0 }
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
function M.row_label(rec, nearest_qid)
  local tags = ""
  if rec.tracked then tags = tags .. " [tracked]" end
  if rec.qid == nearest_qid then tags = tags .. " [nearest]" end
  return rec.name .. " - " .. rec.state .. (rec.waiting or "") .. tags
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

  for _, qid in ipairs(qids) do
    repeat
      if not adapter.is_side(qid) then break end

      local hint, cands = giver_candidates(adapter, qid)

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
      if not show[GROUP[cat]] then break end
      if cat == "in_progress" then shown_inprog[qid] = true end
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
    end
  end

  -- v13 (SPEC 21.8): current step of a lone in-progress quest per marker.
  local quest_steps
  if show.step_icons and adapter.quest_step ~= nil then
    local want, listed = {}, {}
    for _, m in ipairs(markers) do
      if m.cat == "in_progress" and #m.inprog == 1 and not listed[m.inprog[1]] then
        listed[m.inprog[1]] = true
        want[#want + 1] = m.inprog[1]
      end
    end
    quest_steps = M.step_reads(adapter, want, show.prev_quest_steps or {}, show.now or 0)
    for _, m in ipairs(markers) do
      if m.cat == "in_progress" and #m.inprog == 1 then
        local e = quest_steps[m.inprog[1]]
        local n = e and e.n
        if type(n) == "number" and n >= 1 and n <= 5 then m.step = n end
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
  if show.quest_items and show.in_progress and adapter.item_needs ~= nil then
    local ims
    ims, item_capped = M.item_markers(adapter, shown_inprog, show.origin, q)
    for _, m in ipairs(ims) do markers[#markers + 1] = m end
  end

  -- v10 (SPEC 17.4): world markers, appended AFTER every item marker. The
  -- seller merge runs here, once the quest markers exist.
  local world_panel, fullmap_world
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
      if cid ~= nil then quest_by_cid[cid] = m end
    end
    local wms, merged
    wms, world_panel, merged = M.world_markers_cached(show.world, show,
      show.world_origin, boxes, quest_by_cid)
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
        show.map_origin, boxes, quest_by_cid, { grid_builds = 0, cand_builds = 0 })
    end
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
      (m.cat or "") .. (m.done and "|d" or "") .. (m.step and ("|s" .. m.step) or ""))
  end
  table.sort(parts)
  return table.concat(parts, "|"), new_committed
end

-- v3 overhead layer (SPEC §10.2c): pure helpers, no sdk.
function M.marker_cid(m)
  if type(m) ~= "table" or type(m.key) ~= "string" then return nil end
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
-- otherwise the tick invalidates (zero managed calls).
function M.item_walk_wanted(show)
  return show ~= nil and ((show.in_progress == true and show.quest_items == true)
    or show.world_sellers == true)
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
      local w = WORLD_DEF[m.cat] ~= nil and 1 or 0
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
