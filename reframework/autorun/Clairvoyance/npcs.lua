-- NPC routes, affinity tiers, quest-item relations and quest hints
-- (SPEC 22.5, 22.8.2-22.8.3, 22.9.4, 22.10.1, 22.11). Pure: no host global
-- is read; game access arrives through arguments.
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

local function applies_today(r, today)
  return in_range(today.week, r.start_week, r.end_week)
    and in_range(today.weekday, r.start_day, r.end_day)
end

local function same_place(r, cur)
  return r.area == cur.area and r.location == cur.location
end

-- The hour h is covered by a stop {from, to}: to <= from wraps midnight.
local function stop_covers(s, h)
  if s.from < s.to then return h >= s.from and h < s.to end
  return h >= s.from or h < s.to
end

-- Ruling 2: the route level is the lowest priority P > 0 with an applicable
-- row at the current hour matching cur's area and location; else 0.
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

function M.route_stops(rows, today, area_pos, cur)
  local level = pick_level(rows, today, cur)
  -- Per hour: the level's row, else level 0's row.
  local per_hour = {}
  for h = 0, 23 do
    local pick, base
    for _, r in ipairs(rows) do
      if applies_today(r, today) and in_hours(h, r.start_hour, r.end_hour) then
        local p = r.priority or 0
        if p == level and not pick then pick = r end
        if p == 0 and not base then base = r end
      end
    end
    per_hour[h] = pick or base
  end

  -- Runs of consecutive hours in the same place.
  local runs = {}
  for h = 0, 23 do
    local r = per_hour[h]
    if r then
      local last = runs[#runs]
      if last and last.to == h and last.area == r.area and last.location == r.location then
        last.to = h + 1
      else
        runs[#runs + 1] = { from = h, to = h + 1, area = r.area,
          location = r.location, row = r }
      end
    end
  end

  -- A run crossing midnight is one stop, listed last.
  if #runs > 1 then
    local first, last = runs[1], runs[#runs]
    if first.from == 0 and last.to == 24 and first.area == last.area
        and first.location == last.location then
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
        and stop_covers(s, today.hour) then
      pos = cur.pos
    else
      pos = area_pos(s.row)
    end
    if pos then
      stops[#stops + 1] = { from = s.from, to = s.to, area = s.area,
        location = s.location, pos = pos }
    else
      unplaced = unplaced + 1
    end
  end
  return stops, unplaced
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
      local key = r.id .. ":" .. r.qid
      if not seen[key] then
        seen[key] = true
        local list = out[r.id]
        if not list then list = {}; out[r.id] = list end
        list[#list + 1] = r.qid
      end
    end
  end
  for _, list in pairs(out) do table.sort(list) end
  return out
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
    local qid = tonumber(k)
    if not qid then
      errors[#errors + 1] = "hints: bad quest id " .. tostring(k)
    elseif type(q) ~= "table" then
      errors[#errors + 1] = "hints: quest " .. tostring(k) .. " is not an object"
    else
      local entry = { quest = type(q.quest) == "string" and q.quest or nil, steps = {} }
      if q.steps ~= nil and type(q.steps) ~= "table" then
        errors[#errors + 1] = "hints: quest " .. tostring(k) .. " steps is not an object"
      end
      if type(q.steps) == "table" then
        for sk, s in pairs(q.steps) do
          local idx = tonumber(sk)
          local label = "hints: quest " .. tostring(k) .. " step " .. tostring(sk)
          if not idx then
            errors[#errors + 1] = label .. " has a bad index"
          elseif type(s) ~= "table" or type(s.text) ~= "string" then
            errors[#errors + 1] = label .. " has no text"
          else
            local pins = {}
            if s.pins ~= nil and type(s.pins) ~= "table" then
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

-- quest_step is 1-based; the file's step index is 0-based.
function M.hint_step(hints, qid, quest_step)
  if type(hints) ~= "table" or type(quest_step) ~= "number" then return nil end
  local q = hints[qid]
  if not q then return nil end
  return q.steps[quest_step - 1]
end

return M
