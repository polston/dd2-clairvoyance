-- NPC routes, affinity tiers, quest-item relations and quest hints
-- (SPEC 22.5, 22.8.2-22.8.3, 22.9.4, 22.10.1, 22.11). Pure: no host global
-- is read; game access arrives through arguments.
local core = require("Clairvoyance.core")
local M = {}

local floor = math.floor

-- Schedule day and week (Ruling 1).
function M.today(day, hour)
  return { week = floor(day / 7) % 4 + 1, weekday = day % 7, hour = hour }
end

-- v within lo..hi inclusive, wrapping when lo > hi.
local function in_range(v, lo, hi)
  if lo <= hi then return v >= lo and v <= hi end
  return v >= lo or v <= hi
end

-- h within [lo, hi) hours, wrapping when hi <= lo.
local function in_hours(h, lo, hi)
  if lo < hi then return h >= lo and h < hi end
  return h >= lo or h < hi
end
M.in_hours = in_hours

local function applies_today(r, today)
  return in_range(today.week, r.start_week, r.end_week)
    and in_range(today.weekday, r.start_day, r.end_day)
end

-- A key location id: a number > 0, else -1 (missing reads as -1).
local function key_of(t)
  local k = type(t) == "table" and t.key or nil
  if type(k) == "number" and k > 0 then return k end
  return -1
end

-- SPEC 25.3: when either side has a key, both must have the same key;
-- otherwise area and location are equal and not both -1.
local function same_place(r, cur)
  local kr, kc = key_of(r), key_of(cur)
  if kr > 0 or kc > 0 then return kr > 0 and kc > 0 and kr == kc end
  return r.area == cur.area and r.location == cur.location
    and not (r.area == -1 and r.location == -1)
end

-- Ruling 2: the route level is the lowest priority P > 0 with an applicable
-- base row at the current hour matching cur (SPEC 25.3); else 0.
local function pick_level(rows, today, cur)
  if type(cur) ~= "table" then return 0 end
  local best
  for _, r in ipairs(rows) do
    local p = r.priority or 0
    if p ~= 0 and (best == nil or p < best) and applies_today(r, today)
        and in_hours(today.hour, r.start_hour, r.end_hour) and same_place(r, cur) then
      best = p
    end
  end
  return best or 0
end

-- SPEC 25.4: returns stops, unplaced, matched.
function M.route_stops(rows, today, area_pos, cur)
  local level = pick_level(rows, today, cur)
  local overwrite = type(cur) == "table" and type(cur.overwrite) == "table"
    and cur.overwrite or {}
  -- Per hour: the first applicable overwrite row, else the level's row,
  -- else level 0's row.
  local per_hour = {}
  for h = 0, 23 do
    local pick, base, over
    for _, r in ipairs(overwrite) do
      if not over and applies_today(r, today) and in_hours(h, r.start_hour, r.end_hour) then
        over = r
      end
    end
    for _, r in ipairs(rows) do
      if applies_today(r, today) and in_hours(h, r.start_hour, r.end_hour) then
        local p = r.priority or 0
        if p == level and not pick then pick = r end
        if p == 0 and not base then base = r end
      end
    end
    per_hour[h] = over or pick or base
  end

  -- Runs of consecutive hours in the same place.
  local runs = {}
  for h = 0, 23 do
    local r = per_hour[h]
    if r then
      local k = key_of(r)
      local last = runs[#runs]
      if last and last.to == h and last.area == r.area and last.location == r.location
          and last.key == k then
        last.to = h + 1
      else
        runs[#runs + 1] = { from = h, to = h + 1, area = r.area,
          location = r.location, key = k, row = r }
      end
    end
  end

  -- A run crossing midnight is one stop, listed last.
  if #runs > 1 then
    local first, last = runs[1], runs[#runs]
    if first.from == 0 and last.to == 24 and first.area == last.area
        and first.location == last.location and first.key == last.key then
      last.to = first.to
      table.remove(runs, 1)
    end
  end
  for _, s in ipairs(runs) do
    if s.to == 24 then s.to = 0 end
  end

  local stops, unplaced = {}, 0
  for _, s in ipairs(runs) do
    local pos
    if type(cur) == "table" and cur.pos ~= nil and same_place(s, cur)
        and in_hours(today.hour, s.from, s.to) then
      pos = cur.pos
    else
      pos = area_pos(s.row)
    end
    if pos then
      stops[#stops + 1] = { from = s.from, to = s.to, area = s.area,
        location = s.location, key = s.key, pos = pos }
    else
      unplaced = unplaced + 1
    end
  end

  local matched = true
  if type(cur) == "table" then
    local picked = per_hour[today.hour]
    matched = picked ~= nil and same_place(picked, cur)
  end
  return stops, unplaced, matched
end

-- The position nearest the mean of the list.
function M.anchor_node(positions)
  local n = #positions
  if n == 0 then return nil end
  local sx, sy, sz = 0, 0, 0
  for _, p in ipairs(positions) do
    sx, sy, sz = sx + p.x, sy + p.y, sz + p.z
  end
  local mx, my, mz = sx / n, sy / n, sz / n
  local best, bd
  for _, p in ipairs(positions) do
    local dx, dy, dz = p.x - mx, p.y - my, p.z - mz
    local d = dx * dx + dy * dy + dz * dz
    if not bd or d < bd then best, bd = p, d end
  end
  return best
end

-- Affinity tier name for a rank (22.8.3).
function M.tier(rank)
  if type(rank) ~= "number" or rank ~= rank or rank == -501 then return nil end
  if rank <= -101 then return "Hostile" end
  if rank <= -31 then return "Hate" end
  if rank <= 99 then return "Normal" end
  if rank <= 199 then return "Like" end
  return "Love"
end

-- item_id -> ascending unique quest ids whose records need that item.
function M.related_items(records)
  local out, seen = {}, {}
  if type(records) ~= "table" then return out end
  for _, r in ipairs(records) do
    if type(r) == "table" and (r.op == "more" or r.op == "morethan")
        and type(r.qid) == "number" and type(r.id) == "number" then
      local by_id = seen[r.id]
      if not by_id then by_id = {}; seen[r.id] = by_id end
      if not by_id[r.qid] then
        by_id[r.qid] = true
        local list = out[r.id]
        if not list then list = {}; out[r.id] = list end
        list[#list + 1] = r.qid
      end
    end
  end
  for _, list in pairs(out) do table.sort(list) end
  return out
end

-- A key usable as a quest id or step index: a non-negative whole number.
local function whole_key(k)
  local n = tonumber(k)
  if n and n == floor(n) and n >= 0 then return n end
  return nil
end

-- Hints file validation (22.11.1). Malformed entries are dropped with one
-- error string each; nothing raises.
function M.parse_hints(t)
  local hints, errors = {}, {}
  if type(t) ~= "table" then
    errors[1] = "hints: top level is not an object"
    return hints, errors
  end
  for k, q in pairs(t) do
    local qid = whole_key(k)
    if not qid then
      errors[#errors + 1] = "hints: bad quest id " .. tostring(k)
    elseif type(q) ~= "table" then
      errors[#errors + 1] = "hints: quest " .. tostring(k) .. " is not an object"
    else
      local entry = { quest = type(q.quest) == "string" and q.quest or nil, steps = {}, items = {} }
      local its = q.items
      if its ~= nil and (type(its) ~= "table" or (#its == 0 and next(its) ~= nil)) then
        errors[#errors + 1] = "hints: quest " .. tostring(k) .. " items is not a list"
      elseif type(its) == "table" then
        for i, v in ipairs(its) do
          if type(v) == "number" and whole_key(v) then
            entry.items[#entry.items + 1] = v
          else
            errors[#errors + 1] = "hints: quest " .. tostring(k) .. " item " .. i
              .. " is not an item id"
          end
        end
      end
      if q.quest ~= nil and type(q.quest) ~= "string" then
        errors[#errors + 1] = "hints: quest " .. tostring(k) .. " hint is not text"
      end
      local steps = q.steps
      -- A JSON array has 1-based keys and would shift every step by one.
      if type(steps) == "table" and steps[1] ~= nil
          and steps[0] == nil and steps["0"] == nil then
        errors[#errors + 1] = "hints: quest " .. tostring(k) .. " steps is not an object"
        steps = nil
      elseif steps ~= nil and type(steps) ~= "table" then
        errors[#errors + 1] = "hints: quest " .. tostring(k) .. " steps is not an object"
      end
      if type(steps) == "table" then
        for sk, s in pairs(steps) do
          local idx = whole_key(sk)
          local label = "hints: quest " .. tostring(k) .. " step " .. tostring(sk)
          if not idx then
            errors[#errors + 1] = label .. " has a bad index"
          elseif type(s) ~= "table" or type(s.text) ~= "string" then
            errors[#errors + 1] = label .. " has no text"
          else
            local pins = {}
            if s.pins ~= nil and type(s.pins) ~= "table" then
              errors[#errors + 1] = label .. " pins is not a list"
            elseif type(s.pins) == "table" and #s.pins == 0 and next(s.pins) ~= nil then
              errors[#errors + 1] = label .. " pins is not a list"
            elseif type(s.pins) == "table" then
              for i, p in ipairs(s.pins) do
                if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number"
                    and type(p.z) == "number" and (p.label == nil or type(p.label) == "string") then
                  pins[#pins + 1] = { x = p.x, y = p.y, z = p.z, label = p.label or "" }
                else
                  errors[#errors + 1] = label .. " pin " .. i .. " is malformed"
                end
              end
            end
            entry.steps[idx] = { text = s.text, pins = pins }
          end
        end
      end
      hints[qid] = entry
    end
  end
  return hints, errors
end

-- Quest relations file. A quest key is kept when it is a whole number above 0
-- and its value is a table; list fields keep only positive whole numbers.
-- Nothing raises.
local function pos_int(v)
  if type(v) ~= "number" then return nil end
  local i = math.tointeger(v)
  if i and i > 0 and i <= 2147483647 then return i end
  return nil
end

local function int_list(t)
  local out = {}
  if type(t) ~= "table" or (#t == 0 and next(t) ~= nil) then return out end
  for _, v in ipairs(t) do
    local i = pos_int(v)
    if i then out[#out + 1] = i end
  end
  return out
end

local function legacy_uint(v)
  if type(v) ~= "number" then return nil end
  local i = math.tointeger(v)
  if i and i > 0 and i <= 4294967295 then return i end
  return nil
end

function M.parse_quests(t)
  local quests = {}
  if type(t) ~= "table" or type(t.quests) ~= "table" then return quests end
  for k, q in pairs(t.quests) do
    local qid = pos_int(tonumber(k))
    if qid and type(q) == "table" then
      local dest = {}
      if type(q.dest) == "table" and not (#q.dest == 0 and next(q.dest) ~= nil) then
        for _, d in ipairs(q.dest) do
          if type(d) == "table" then
            local cid, key = legacy_uint(d.cid), pos_int(d.key)
            if cid or key then dest[#dest + 1] = { cid = cid, key = key } end
          end
        end
      end
      local function legacy_list(values)
        local out = {}
        if type(values) == "table" and not (#values == 0 and next(values) ~= nil) then
          for _, value in ipairs(values) do
            local id = legacy_uint(value)
            if id then out[#out + 1] = id end
          end
        end
        return out
      end
      quests[qid] = { cast = legacy_list(q.cast), npcs = legacy_list(q.npcs),
        items = int_list(q.items), dest = dest, decoded = (q.decoded == true) }
    end
  end
  if t.version ~= 2 or type(t.quests) ~= "table" then return quests end

  local diagnostics, catalog_quests = {}, {}
  local function fail(message)
    diagnostics[#diagnostics + 1] = message
  end
  local function is_integer(v, lo, hi)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
      and v == floor(v) and v >= lo and v <= hi
  end
  local function bool(v) return type(v) == "boolean" end
  local function canonical_qid(k)
    if type(k) ~= "string" or not k:match("^[1-9][0-9]*$") then return nil end
    local n = tonumber(k)
    if not n or n > 2147483647 or tostring(n) ~= k then return nil end
    return n
  end
  local function dense_array(v)
    if type(v) ~= "table" then return false end
    local n, count = #v, 0
    for k in pairs(v) do
      if not is_integer(k, 1, n) then return false end
      count = count + 1
    end
    return count == n
  end
  local function copy_array(v, convert)
    if not dense_array(v) then return nil end
    local out = {}
    for i = 1, #v do
      local item = convert(v[i], i - 1)
      if item == nil then return nil end
      out[i] = item
    end
    return out
  end
  local function position(p)
    if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number"
        or type(p.z) ~= "number" then return nil end
    for _, v in ipairs({ p.x, p.y, p.z }) do
      if v ~= v or v == math.huge or v == -math.huge then return nil end
    end
    return { x = p.x, y = p.y, z = p.z }
  end
  local function copy_plain(value, seen, depth)
    if type(value) == "string" or type(value) == "boolean" then return value end
    if type(value) == "number" then
      if value ~= value or value == math.huge or value == -math.huge then return nil end
      return value
    end
    if type(value) ~= "table" or depth > 32 or seen[value] then return nil end
    seen[value] = true
    local out = {}
    for k, v in pairs(value) do
      if not (type(k) == "string" or is_integer(k, 1, 2147483647)) then seen[value] = nil; return nil end
      local copy = copy_plain(v, seen, depth + 1)
      if copy == nil then seen[value] = nil; return nil end
      out[k] = copy
    end
    seen[value] = nil
    return out
  end
  local function condition(c, depth)
    if type(c) ~= "table" or depth > 32 or type(c.kind) ~= "string" then return nil end
    local kind = c.kind
    if kind == "quest_variable" then
      if not bool(c.enabled) or not bool(c.is_not)
          or not is_integer(c.qid, 1, 2147483647)
          or not is_integer(c.name_hash, 0, 4294967295)
          or not is_integer(c.value_type, -2147483648, 2147483647)
          or not is_integer(c.compare_type, -2147483648, 2147483647)
          or not bool(c.bool_value) or not is_integer(c.int_value, -2147483648, 2147483647) then return nil end
      return { kind = kind, enabled = c.enabled, is_not = c.is_not, qid = c.qid,
        name_hash = c.name_hash, value_type = c.value_type, compare_type = c.compare_type,
        bool_value = c.bool_value, int_value = c.int_value }
    elseif kind == "quest_log_condition" then
      if not is_integer(c.qid, -2147483648, 2147483647)
          or not is_integer(c.name_hash, 0, 4294967295)
          or not is_integer(c.value_type, -2147483648, 2147483647)
          or not is_integer(c.compare_type, -2147483648, 2147483647)
          or not bool(c.bool_value) or not is_integer(c.int_value, -2147483648, 2147483647) then return nil end
      return { kind = kind, qid = c.qid, name_hash = c.name_hash, value_type = c.value_type,
        compare_type = c.compare_type, bool_value = c.bool_value, int_value = c.int_value }
    elseif kind == "item" then
      if not bool(c.enabled) or not bool(c.is_not)
          or not is_integer(c.item_id, 1, 2147483647)
          or not bool(c.set_num)
          or not is_integer(c.num, -2147483648, 2147483647) then return nil end
      return { kind = kind, enabled = c.enabled, is_not = c.is_not,
        item_id = c.item_id, set_num = c.set_num, num = c.num }
    elseif kind == "quest_variable_or" then
      if not bool(c.enabled) or not bool(c.is_not) then return nil end
      local children = copy_array(c.children, function(child) return condition(child, depth + 1) end)
      if not children then return nil end
      return { kind = kind, enabled = c.enabled, is_not = c.is_not, children = children }
    elseif kind == "quest_log_reminder" then
      local function reminder(r, reminder_depth)
        if type(r) ~= "table" or r.kind ~= "quest_log_reminder" or reminder_depth > 32
            or type(r.reminder_msg_id) ~= "string"
            or not r.reminder_msg_id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
            or not bool(r.is_finished) or not bool(r.is_or) then return nil end
        local children = copy_array(r.reminders, function(child)
          return reminder(child, reminder_depth + 1)
        end)
        if not children then return nil end
        return { kind = r.kind, reminder_msg_id = r.reminder_msg_id, is_finished = r.is_finished,
          is_or = r.is_or, reminders = children }
      end
      if type(c.reminder_msg_id) ~= "string"
          or not c.reminder_msg_id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$")
          or not bool(c.is_finished) or not bool(c.is_or) then return nil end
      local reminders = copy_array(c.reminders, function(r)
        return reminder(r, depth + 1)
      end)
      if not reminders then return nil end
      return { kind = kind, reminder_msg_id = c.reminder_msg_id,
        is_finished = c.is_finished, is_or = c.is_or, reminders = reminders }
    end
    return nil
  end
  local function place_target(v)
    if type(v) ~= "table" then return nil end
    if v.kind == "key_location" and is_integer(v.key, 1, 2147483647) then
      return { kind = v.kind, key = v.key }
    elseif v.kind == "local_area" and is_integer(v.local_area, 0, 2147483647) then
      return { kind = v.kind, local_area = v.local_area }
    end
    return nil
  end
  local function destination(d)
    if type(d) ~= "table" or not is_integer(d.index, 0, 2147483647)
        or not bool(d.set_destination) or not is_integer(d.dest_type, -2147483648, 2147483647)
        or not is_integer(d.area, -2147483648, 2147483647)
        or not bool(d.has_show_conditions) or not bool(d.is_update_condition)
        or not bool(d.has_display_conditions) then return nil end
    if d.cid ~= nil and not is_integer(d.cid, 1, 4294967295) then return nil end
    if d.key ~= nil and not is_integer(d.key, 1, 2147483647) then return nil end
    if d.local_area ~= nil and not is_integer(d.local_area, 0, 4294967295) then return nil end
    local shows = copy_array(d.show_conditions, function(c) return condition(c, 1) end)
    local displays = copy_array(d.display_conditions, function(c) return condition(c, 1) end)
    if not shows or not displays then return nil end
    return { index = d.index, set_destination = d.set_destination, dest_type = d.dest_type,
      cid = d.cid, key = d.key, area = d.area, local_area = d.local_area,
      has_show_conditions = d.has_show_conditions, show_conditions = shows,
      is_update_condition = d.is_update_condition,
      has_display_conditions = d.has_display_conditions, display_conditions = displays }
  end
  local function task_array(raw, qid)
    if not dense_array(raw) then return nil end
    local out = {}
    for i, task in ipairs(raw) do
      local index = i - 1
      if type(task) ~= "table" or task.index ~= index or not bool(task.has_destination)
          or not dense_array(task.destinations) then
        fail("quest " .. qid .. " tasks malformed")
        return nil
      end
      local destinations = {}
      for di, raw_dest in ipairs(task.destinations) do
        local dest = destination(raw_dest)
        if not dest or dest.index ~= di - 1 then
          fail("quest " .. qid .. " task " .. index .. " destination " .. (di - 1) .. " malformed")
          destinations[di] = false
        else destinations[di] = dest end
      end
      out[i] = { index = index, has_destination = task.has_destination, destinations = destinations }
    end
    return out
  end
  local function delivery_array(raw)
    if not dense_array(raw) then return nil end
    local out, by_key, by_serial = {}, {}, {}
    for i, d in ipairs(raw) do
      local valid = type(d) == "table" and is_integer(d.key, 0, 2147483647)
        and is_integer(d.serial, 0, 2147483647) and d.serial == d.key
        and bool(d.incomplete_possible) and is_integer(d.operator, -2147483648, 2147483647)
        and dense_array(d.groups)
      local groups = {}
      if valid then
        for gi, g in ipairs(d.groups) do
          local ids = type(g) == "table" and copy_array(g.item_ids, function(id)
            if not is_integer(id, 1, 2147483647) then return nil end
            return id
          end) or nil
          local ignored = type(g) == "table" and copy_array(g.ignore_restriction_items, function(id)
            if not is_integer(id, 1, 2147483647) then return nil end
            return id
          end) or nil
          if type(g) ~= "table" or g.index ~= gi - 1 or not ids or not ignored
              or not is_integer(g.count, -2147483648, 2147483647)
              or not bool(g.is_all_item) or not bool(g.is_infinite) then
            valid = false; break
          end
          groups[gi] = { index = gi - 1, item_ids = ids, count = g.count,
            is_all_item = g.is_all_item, is_infinite = g.is_infinite,
            ignore_restriction_items = ignored }
        end
      end
      if valid then
        local key_seen, serial_seen = by_key[d.key], by_serial[d.serial]
        if key_seen or serial_seen then
          valid = false
          if key_seen then out[key_seen] = false end
          if serial_seen then out[serial_seen] = false end
        else
          by_key[d.key], by_serial[d.serial] = i, i
        end
      end
      if valid then
        out[i] = { key = d.key, serial = d.serial, incomplete_possible = d.incomplete_possible,
          operator = d.operator, groups = groups }
      else
        out[i] = false
      end
    end
    for i, d in ipairs(out) do if d == false then fail("delivery " .. i .. " malformed or duplicated") end end
    return out
  end
  local function source_record(s)
    if type(s) ~= "table" or type(s.id) ~= "string" or s.id == ""
        or type(s.kind) ~= "string" or s.kind == ""
        or type(s.evidence) ~= "table" or type(s.evidence.provider) ~= "string"
        or type(s.evidence.ref) ~= "table" or not dense_array(s.item_ids)
        or not dense_array(s.inputs) then return nil end
    local ids = copy_array(s.item_ids, function(id)
      if not is_integer(id, 1, 2147483647) then return nil end
      return id
    end)
    local inputs = copy_array(s.inputs, function(input)
      if type(input) ~= "table" or not is_integer(input.item_id, 1, 2147483647)
          or not is_integer(input.count, 1, 2147483647) then return nil end
      return { item_id = input.item_id, count = input.count }
    end)
    if not ids or #ids == 0 or not inputs then return nil end
    local ref = copy_plain(s.evidence.ref, {}, 0)
    if not ref then return nil end
    local function source_place_target(v)
      local place = place_target(v)
      if place then return place end
      if type(v) == "table" and v.kind == "position" then
        local pos = position(v)
        if pos then return { kind = "position", x = pos.x, y = pos.y, z = pos.z } end
      end
      return nil
    end
    local target = s.target
    if type(target) ~= "table" or (target.cid == nil and target.place == nil)
        or (target.cid ~= nil and target.place ~= nil)
        or (target.cid ~= nil and not is_integer(target.cid, 1, 4294967295)) then return nil end
    local place = target.place and source_place_target(target.place) or nil
    if target.place ~= nil and not place then return nil end
    return { id = s.id, kind = s.kind, item_ids = ids,
      target = { cid = target.cid, place = place },
      evidence = { provider = s.evidence.provider, ref = ref }, inputs = inputs }
  end
  local function same_value(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same_value(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local conflicts, source_seen = {}, {}
  local function collect_sources(raw, label)
    local out, local_seen = {}, {}
    if raw == nil then return out end
    if not dense_array(raw) then fail(label .. " malformed"); return out end
    for i, value in ipairs(raw) do
      local source = source_record(value)
      if source then
        local old = source_seen[source.id]
        if old and not same_value(old, source) then conflicts[source.id] = true
        elseif old == nil then source_seen[source.id] = source end
        if not local_seen[source.id] then
          local_seen[source.id] = true
          out[#out + 1] = source
        end
      else fail(label .. " " .. i .. " malformed") end
    end
    return out
  end
  local catalog_sources = collect_sources(t.sources, "source")
  local quest_sources = {}
  for key, raw in pairs(t.quests) do
    local qid = canonical_qid(key)
    if qid and type(raw) == "table" then
      quest_sources[qid] = collect_sources(raw.sources, "quest " .. qid .. " source")
    end
  end
  for id in pairs(conflicts) do fail("source id conflicts: " .. id) end
  local function without_conflicts(sources)
    local out = {}
    for _, source in ipairs(sources) do
      if not conflicts[source.id] then out[#out + 1] = source end
    end
    return out
  end
  local filtered_sources = without_conflicts(catalog_sources)
  for qid, sources in pairs(quest_sources) do
    quest_sources[qid] = without_conflicts(sources)
  end
  for key, raw in pairs(t.quests) do
    local qid = canonical_qid(key)
    if qid and type(raw) == "table" then
      local entry = { tasks = task_array(raw.tasks, qid), guidance = {}, deliveries = {},
        sources = quest_sources[qid] or {} }
      local deliveries = delivery_array(raw.deliveries)
      if not deliveries then fail("quest " .. qid .. " deliveries malformed") else entry.deliveries = deliveries end
      if not dense_array(raw.guidance) then
        fail("quest " .. qid .. " guidance malformed")
      else
        local guidance = copy_array(raw.guidance, function(g, index)
          if type(g) ~= "table" or g.index ~= index
              or not is_integer(g.task_index, 0, 2147483647) or not dense_array(g.destinations) then
            fail("quest " .. qid .. " concierge " .. index .. " malformed")
            return false
          end
          local destinations = copy_array(g.destinations, function(d, di)
            if type(d) ~= "table" or d.index ~= di
                or not is_integer(d.concierge_type, 0, 2147483647)
                or not is_integer(d.gimmick_id, -2147483648, 2147483647)
                or not bool(d.is_chara_at_destination)
                or not dense_array(d.register_conditions) or not dense_array(d.conditions)
                or type(d.delivery) ~= "table" then
              fail("quest " .. qid .. " concierge " .. index .. " destination " .. di .. " malformed")
              return false
            end
            local target = place_target(d.target)
            if d.target ~= nil and not target then return false end
            if d.cid ~= nil and not is_integer(d.cid, 1, 4294967295) then return false end
            local regs = copy_array(d.register_conditions, function(c) return condition(c, 1) end)
            local conds = copy_array(d.conditions, function(c) return condition(c, 1) end)
            if not regs or not conds then
              fail("quest " .. qid .. " concierge " .. index .. " destination " .. di .. " conditions malformed")
              return false
            end
            local delivery = d.delivery
            if not bool(delivery.is_not) or not bool(delivery.check_storage)
                or not is_integer(delivery.group_id, -2147483648, 2147483647)
                or not dense_array(delivery.refs) then return false end
            local refs = copy_array(delivery.refs, function(r)
              if type(r) ~= "table" or not is_integer(r.qid, 1, 2147483647)
                  or not is_integer(r.key, 0, 2147483647)
                  or not is_integer(r.serial, 0, 2147483647) or r.key ~= r.serial then return nil end
              return { qid = r.qid, key = r.key, serial = r.serial }
            end)
            if not refs then
              fail("quest " .. qid .. " concierge " .. index .. " destination " .. di .. " delivery malformed")
              return false
            end
            return { index = di, target = target, cid = d.cid,
              concierge_type = d.concierge_type, gimmick_id = d.gimmick_id,
              is_chara_at_destination = d.is_chara_at_destination,
              register_conditions = regs, conditions = conds,
              delivery = { is_not = delivery.is_not, check_storage = delivery.check_storage,
                group_id = delivery.group_id, refs = refs } }
          end)
          if not destinations then return false end
          if g.destination_index ~= nil and not is_integer(g.destination_index, 0, 2147483647) then
            return false
          end
          return { index = index, task_index = g.task_index,
            destination_index = g.destination_index, destinations = destinations }
        end)
        if not guidance then fail("quest " .. qid .. " guidance malformed") else entry.guidance = guidance end
      end
      if entry.tasks or #entry.guidance > 0 or #entry.deliveries > 0 or #entry.sources > 0 then
        catalog_quests[qid] = entry
      end
    end
  end
  -- Concierge delivery references are exact (qid,key) joins. Array position is
  -- never used as a fallback, and one bad association disables only its record.
  for qid, entry in pairs(catalog_quests) do
    for _, g in ipairs(entry.guidance) do
      if type(g) == "table" then
        for di, d in ipairs(g.destinations) do
          if type(d) == "table" then
            local valid = true
            for _, ref in ipairs(d.delivery.refs) do
              local owner = catalog_quests[ref.qid]
              local match
              for _, delivery in ipairs(owner and owner.deliveries or {}) do
                if type(delivery) == "table" and delivery.key == ref.key then
                  if match then valid = false end
                  match = delivery
                end
              end
              if not match or match.serial ~= ref.serial then valid = false end
              local group = d.delivery.group_id
              if group >= 0 and (not match or match.groups[group + 1] == nil) then valid = false end
            end
            if not valid then
              g.destinations[di] = false
              fail("quest " .. qid .. " concierge " .. g.index .. " destination " .. d.index .. " delivery reference unresolved")
            end
          end
        end
      end
    end
  end
  return quests, { version = 2, pak = type(t.pak) == "string" and t.pak or nil,
    quests = catalog_quests, sources = filtered_sources, diagnostics = diagnostics }
end

-- True when a parsed hints entry has any text to show (a quest hint or a step).
function M.has_text(entry)
  return type(entry) == "table"
    and (entry.quest ~= nil or (type(entry.steps) == "table" and next(entry.steps) ~= nil))
end

-- { [item_id] = { qid, ... } } (ascending, unique) from the parsed hints.
function M.hint_items(hints)
  local out, seen = {}, {}
  if type(hints) ~= "table" then return out end
  for qid, q in pairs(hints) do
    if type(q) == "table" and type(q.items) == "table" then
      for _, id in ipairs(q.items) do
        local s = seen[id]
        if not s then s = {}; seen[id] = s end
        if not s[qid] then
          s[qid] = true
          local list = out[id]
          if not list then list = {}; out[id] = list end
          list[#list + 1] = qid
        end
      end
    end
  end
  for _, list in pairs(out) do table.sort(list) end
  return out
end

-- quest_step is 1-based; the file's step index is 0-based.
function M.hint_step(hints, qid, quest_step)
  if type(hints) ~= "table" or type(quest_step) ~= "number" then return nil end
  local q = hints[qid]
  if not q then return nil end
  return q.steps[quest_step - 1]
end

-- ---------------------------------------------------------------------------
-- Walking-path search, route pairs, map fit and route polylines (SPEC 23.6.4,
-- 23.6.6, 23.6.7). Graph shape g: g.n, g.x/y/z[i], g.ls[i] first link slot,
-- g.lc[i] link count, g.lt[slot] target node. clock returns seconds.
-- ---------------------------------------------------------------------------

local sqrt = math.sqrt

function M.nearest_new(g, x, y, z)
  return { g = g, x = x, y = y, z = z, i = 1, best = nil, bestd2 = math.huge,
    dist = nil, status = "running" }
end

function M.nearest_step(job, budget_ms, clock)
  if job.status == "done" then return "done" end
  local g, x, y, z = job.g, job.x, job.y, job.z
  local gx, gy, gz = g.x, g.y, g.z
  local n = g.n
  local limit = (budget_ms or 0) / 1000
  local t0 = clock()
  local i, best, bd = job.i, job.best, job.bestd2
  while i <= n do
    local dx, dy, dz = gx[i] - x, gy[i] - y, gz[i] - z
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < bd then bd = d2; best = i end
    i = i + 1
    if clock() - t0 >= limit then break end
  end
  job.i, job.best, job.bestd2 = i, best, bd
  if i > n then
    job.dist = best and sqrt(bd) or nil
    job.status = "done"
    return "done"
  end
  return "running"
end

-- Binary min-heap on two flat arrays: hk (priority) and hv (node).
local function heap_push(job, k, v)
  local hk, hv = job.hk, job.hv
  local n = job.hn + 1
  job.hn = n
  while n > 1 do
    local p = n // 2
    if hk[p] <= k then break end
    hk[n] = hk[p]; hv[n] = hv[p]
    n = p
  end
  hk[n] = k; hv[n] = v
end

local function heap_pop(job)
  local hk, hv = job.hk, job.hv
  local n = job.hn
  local rv = hv[1]
  local k, v = hk[n], hv[n]
  hk[n] = nil; hv[n] = nil
  n = n - 1
  job.hn = n
  if n > 0 then
    local i = 1
    while true do
      local c = i * 2
      if c > n then break end
      if c < n and hk[c + 1] < hk[c] then c = c + 1 end
      if hk[c] >= k then break end
      hk[i] = hk[c]; hv[i] = hv[c]
      i = c
    end
    hk[i] = k; hv[i] = v
  end
  return rv
end

-- Settle a path job: set its final status and drop the search state.
local function finish(job, status)
  job.status = status
  job.gs, job.parent, job.closed, job.hk, job.hv = nil, nil, nil, nil, nil
end

function M.path_new(g, a, b, opt)
  opt = opt or {}
  local job = { g = g, a = a, b = b, cap = opt.cap or 20000,
    weight = opt.weight or 1.2, expanded = 0, status = "running",
    hk = {}, hv = {}, hn = 0, gs = { [a] = 0 }, parent = {}, closed = {} }
  if a == b then
    job.path = { a }
    finish(job, "done")
  else
    local dx, dy, dz = g.x[a] - g.x[b], g.y[a] - g.y[b], g.z[a] - g.z[b]
    heap_push(job, job.weight * sqrt(dx * dx + dy * dy + dz * dz), a)
  end
  return job
end

function M.path_step(job, budget_ms, clock)
  if job.status ~= "running" then return job.status end
  local g = job.g
  local gx, gy, gz, ls, lc, lt = g.x, g.y, g.z, g.ls, g.lc, g.lt
  local gs, parent, closed = job.gs, job.parent, job.closed
  local b, w, cap = job.b, job.weight, job.cap
  local bx, by, bz = gx[b], gy[b], gz[b]
  local limit = (budget_ms or 0) / 1000
  local t0 = clock()
  while true do
    if job.hn == 0 then
      finish(job, "failed")
      return "failed"
    end
    local u = heap_pop(job)
    if not closed[u] then
      if u == b then
        local path, k = {}, 0
        local c = b
        while c do k = k + 1; path[k] = c; c = parent[c] end
        for i = 1, k // 2 do path[i], path[k + 1 - i] = path[k + 1 - i], path[i] end
        job.path = path
        finish(job, "done")
        return "done"
      end
      closed[u] = true
      local ex = job.expanded + 1
      job.expanded = ex
      if ex > cap then
        finish(job, "failed")
        return "failed"
      end
      local ux, uy, uz, gu = gx[u], gy[u], gz[u], gs[u]
      local s = ls[u]
      for slot = s, s + lc[u] - 1 do
        local t = lt[slot]
        local tx, ty, tz = gx[t], gy[t], gz[t]
        local dx, dy, dz = tx - ux, ty - uy, tz - uz
        local ng = gu + sqrt(dx * dx + dy * dy + dz * dz)
        local old = gs[t]
        if old == nil or ng < old then
          gs[t] = ng
          parent[t] = u
          closed[t] = nil
          dx, dy, dz = tx - bx, ty - by, tz - bz
          heap_push(job, ng + w * sqrt(dx * dx + dy * dy + dz * dz), t)
        end
      end
      if clock() - t0 >= limit then return "running" end
    end
  end
end

local function drawn(s, undisc)
  if type(s) ~= "table" then return false end
  if s.discovered == false and not undisc then return false end
  return core.valid_pos(s.pos)
end

function M.route_pairs(stops, undisc)
  local out = {}
  local prev
  for i = 1, #(stops or {}) do
    if drawn(stops[i], undisc) then
      if prev then out[#out + 1] = { prev, i } end
      prev = i
    end
  end
  return out
end

-- Fit lx = a*mx + b*mz + ox, ly = c*mx + d*mz + oy over the first n points
-- { mx, mz, lx, ly }: uniform scale s with signs sx, sz (lower residual wins);
-- opt.similarity adds a rotation. Result written into out.
local function clear_fit(out)
  if out then
    out.s, out.sx, out.sz, out.a, out.b, out.c, out.d = nil, nil, nil, nil, nil, nil, nil
    out.ox, out.oy, out.residual = nil, nil, nil
  end
end

function M.fit(points, n, opt, out)
  if type(n) ~= "number" or n < 2 then clear_fit(out); return nil end
  local far = false
  for i = 1, n - 1 do
    local p = points[i]
    for j = i + 1, n do
      local q = points[j]
      local dx, dy = p[3] - q[3], p[4] - q[4]
      if dx * dx + dy * dy >= 400 then far = true; break end
    end
    if far then break end
  end
  if not far then clear_fit(out); return nil end
  local cmx, cmz, clx, cly = 0, 0, 0, 0
  for i = 1, n do
    local p = points[i]
    cmx = cmx + p[1]; cmz = cmz + p[2]; clx = clx + p[3]; cly = cly + p[4]
  end
  cmx, cmz, clx, cly = cmx / n, cmz / n, clx / n, cly / n
  local similarity = opt and opt.similarity
  local best_res = math.huge
  local ba, bb, bc, bd, bsx, bsz, bs
  for ci = 1, similarity and 2 or 4 do
    local sx, sz
    if similarity then
      sx = 1; sz = (ci == 1) and 1 or -1
    else
      sx = (ci <= 2) and 1 or -1
      sz = (ci % 2 == 1) and 1 or -1
    end
    local den, re, im = 0, 0, 0
    for i = 1, n do
      local p = points[i]
      local dmx, dmz = sx * (p[1] - cmx), sz * (p[2] - cmz)
      local dlx, dly = p[3] - clx, p[4] - cly
      den = den + dmx * dmx + dmz * dmz
      re = re + dmx * dlx + dmz * dly
      im = im + dmx * dly - dmz * dlx
    end
    if den > 0 then
      local a, b, c, d, s
      if similarity then
        -- complex fit w = k * z with z = mx + i*sz*mz, k = (re + i*im) / den
        local kr, ki = re / den, im / den
        a, b, c, d = kr, -ki * sz, ki, kr * sz
        s = sqrt(kr * kr + ki * ki)
      else
        s = re / den
        a, b, c, d = sx * s, 0, 0, sz * s
      end
      if s > 0 then
        local res = 0
        for i = 1, n do
          local p = points[i]
          local ex = a * (p[1] - cmx) + b * (p[2] - cmz) + clx - p[3]
          local ey = c * (p[1] - cmx) + d * (p[2] - cmz) + cly - p[4]
          local e = sqrt(ex * ex + ey * ey)
          if e > res then res = e end
        end
        if res < best_res then
          best_res = res
          ba, bb, bc, bd, bsx, bsz, bs = a, b, c, d, sx, sz, s
        end
      end
    end
  end
  if not ba then clear_fit(out); return nil end
  out = out or {}
  out.s, out.sx, out.sz = bs, bsx, bsz
  out.a, out.b, out.c, out.d = ba, bb, bc, bd
  out.ox = clx - (ba * cmx + bb * cmz)
  out.oy = cly - (bc * cmx + bd * cmz)
  out.residual = best_res
  return out
end

function M.fit_apply(fit, mx, mz)
  return fit.a * mx + fit.b * mz + fit.ox, fit.c * mx + fit.d * mz + fit.oy
end

-- Writes every pair into out as flat layout points (x, y, ...) with a false
-- between pairs; clears out past the returned count. When starts is given,
-- starts[k] is the 1-based index in out of pair k's first x value (0 when the
-- pair was skipped for a missing end).
function M.route_polyline(pairs_, ends, fit, mode, out, starts)
  local n = 0
  for k = 1, #pairs_ do
    local p = pairs_[k]
    if starts then starts[k] = 0 end
    local e1, e2 = ends[p.i], ends[p.j]
    local x1, y1, x2, y2
    if e1 then
      if e1.lx then x1, y1 = e1.lx, e1.ly
      elseif fit and e1.mx then x1, y1 = M.fit_apply(fit, e1.mx, e1.mz) end
    end
    if e2 then
      if e2.lx then x2, y2 = e2.lx, e2.ly
      elseif fit and e2.mx then x2, y2 = M.fit_apply(fit, e2.mx, e2.mz) end
    end
    if x1 and x2 then
      if n > 0 then n = n + 1; out[n] = false end
      if starts then starts[k] = n + 1 end
      out[n + 1] = x1; out[n + 2] = y1; n = n + 2
      local pts = p.pts
      if mode == 1 and pts and fit then
        local fa, fb, fc, fd, fox, foy = fit.a, fit.b, fit.c, fit.d, fit.ox, fit.oy
        for q = 1, #pts - 2, 3 do
          local mx, mz = pts[q], pts[q + 2]
          out[n + 1] = fa * mx + fb * mz + fox
          out[n + 2] = fc * mx + fd * mz + foy
          n = n + 2
        end
      end
      out[n + 1] = x2; out[n + 2] = y2; n = n + 2
    end
  end
  for i = #out, n + 1, -1 do out[i] = nil end
  if starts then
    for i = #starts, #pairs_ + 1, -1 do starts[i] = nil end
  end
  return n
end

-- Step of each pair for the leg colours: out[p] = 0 for the current leg (the
-- first pair whose j is past current, else pair 1), then counting up in list
-- order, wrapping. current nil gives all 0. Clears out past the returned count.
function M.leg_steps(pairs_, current, out)
  local n = #pairs_
  local base = 1
  if current then
    for p = 1, n do
      if pairs_[p].j > current then base = p; break end
    end
  end
  for p = 1, n do
    out[p] = current and (p - base) % n or 0
  end
  for i = #out, n + 1, -1 do out[i] = nil end
  return n
end

return M
