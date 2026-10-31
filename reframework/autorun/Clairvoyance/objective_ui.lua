-- objective_ui.lua - pure view model for objective/source status and controls.
local M = {}

M.ENTRY_MAX = 512
M.IDENTITY_MAX = 1024

local PROVIDER_LABEL = {
  placed = "Placed item", chest = "Chest", loot = "Loot",
  shop = "Shop", seller = "Seller", monster = "Monster drop",
  talk_grant = "NPC grant", forgery = "Forgery", reward = "Quest reward",
}

local REASON_TEXT = {
  available = "Ready now",
  opened = "Already opened", already_opened = "Already opened",
  chest_opened = "Already opened", source_opened = "Already opened",
  collected = "Already collected", already_collected = "Already collected",
  pickup_collected = "Already collected", source_collected = "Already collected",
  claimed = "Already claimed", already_claimed = "Already claimed",
  reward_claimed = "Already claimed", processor_completed = "Already claimed",
  processor_canceled = "Reward is no longer available",
  quest_completed = "Quest is already complete", quest_canceled = "Quest was canceled",
  quest_not_progressing = "Quest is not active",
  wrong_current_task = "Not part of the current objective",
  task_mismatch = "Not part of the current objective",
  stock_exhausted = "No stock remains", quantity_exhausted = "No stock remains",
  source_exhausted = "Source is exhausted", exhausted = "Source is exhausted",
  inaccessible = "Source is inaccessible", access_blocked = "Source is inaccessible",
  source_inaccessible = "Source is inaccessible",
  shop_unreleased = "Shop offer is not available",
  monster_inaccessible = "Monster is inaccessible",
  monster_not_updating = "Monster is not active",
  dead = "Source is dead", source_dead = "Source is dead", monster_dead = "Source is dead",
  zero_chance = "Drop chance is zero", monster_zero_chance = "Drop chance is zero",
  monster_zero_count = "Drop count is zero",
  monster_disabled = "Monster is unavailable", monster_not_started = "Monster is unavailable",
  monster_invalid = "Monster is unavailable",
  forgery_mapping_disabled = "Forgery is unavailable",
  forgery_service_not_interactable = "Forgery service is inaccessible",
  forgery_order_not_ready = "Forgery is not ready",
  forgery_order_pending = "Forgery is pending",
  forgery_order_unrelated = "Another forgery order is active",
  forgery_input_not_held = "Required original is not held",
  forgery_price_unaffordable = "Forgery is unaffordable",
  processor_state_unreadable = "Source state is unreadable",
  state_unreadable = "Source state is unreadable",
  source_state_unreadable = "Source state is unreadable",
  unsupported_reward_graph = "Reward state cannot be verified",
  current_work_unavailable = "Current objective cannot be verified",
  task_snapshot_unavailable = "Current objective cannot be verified",
  source_unavailable = "Source is unavailable",
}

function M.status_text(state)
  if state == "available" then return "Available" end
  if state == "unavailable" then return "Unavailable" end
  return "Cannot verify"
end

function M.reason_text(reason)
  if type(reason) ~= "string" or reason == "" then return "Source state cannot be verified" end
  local exact = REASON_TEXT[reason]
  if exact ~= nil then return exact end
  if reason:find("opened", 1, true) then return "Already opened" end
  if reason:find("collected", 1, true) then return "Already collected" end
  if reason:find("claimed", 1, true) then return "Already claimed" end
  if reason:find("wrong_task", 1, true) or reason:find("task_mismatch", 1, true) then
    return "Not part of the current objective"
  end
  if reason:find("exhausted", 1, true) or reason:find("out_of_stock", 1, true) then
    return "Source is exhausted"
  end
  if reason:find("inaccessible", 1, true) or reason:find("access_blocked", 1, true) then
    return "Source is inaccessible"
  end
  if reason:find("zero_chance", 1, true) then return "Drop chance is zero" end
  if reason:find("dead", 1, true) then return "Source is dead" end
  if reason:find("unreadable", 1, true) then return "Source state is unreadable" end
  return "Source state cannot be verified"
end

local function dense(value, cap)
  if type(value) ~= "table" then return nil end
  local n, count = #value, 0
  if n > cap then return nil end
  for key in pairs(value) do
    if type(key) ~= "number" or math.type(key) ~= "integer" or key < 1 or key > n then return nil end
    count = count + 1
  end
  return count == n and value or nil
end

local function valid_identity(value)
  return type(value) == "string" and #value > 0 and #value <= M.IDENTITY_MAX
end

local function identity_id(identity)
  local out = {}
  for i = 1, #identity do out[i] = string.format("%02x", identity:byte(i)) end
  return table.concat(out)
end

function M.stable_token(identity)
  return valid_identity(identity) and ("k:" .. identity_id(identity)) or nil
end

local function valid_token(value)
  return type(value) == "string" and #value >= 4 and #value <= 2050
    and value:match("^k:[0-9a-f]+$") ~= nil and (#value - 2) % 2 == 0
end

local function off_set(values)
  local set = {}
  for _, value in ipairs(dense(values, M.ENTRY_MAX) or {}) do
    if valid_token(value) then set[value] = true end
  end
  return set
end

local function copy_ids(values)
  local out = {}
  for _, value in ipairs(dense(values, 256) or {}) do
    if type(value) == "number" and math.type(value) == "integer" and value > 0 then
      out[#out + 1] = value
    end
  end
  return out
end

local function item_label(item_ids, names)
  local parts = {}
  for _, item_id in ipairs(item_ids) do
    local name = type(names) == "table" and names[item_id] or nil
    parts[#parts + 1] = type(name) == "string" and name ~= ""
      and name or ("Item " .. tostring(item_id))
  end
  return #parts > 0 and table.concat(parts, " / ") or nil
end

local function target_label(target, options)
  local label = type(options.labels) == "table" and options.labels[target.key] or nil
  if type(label) == "string" and label ~= "" then return label end
  local items = item_label(copy_ids(target.item_ids), options.item_names)
  if target.kind == "npc" then
    local cid = type(target.target) == "table" and target.target.cid or nil
    return items or (cid and ("NPC " .. tostring(cid)) or "Objective NPC")
  end
  if target.kind == "source" then
    return (items or "Objective item") .. " - "
      .. (PROVIDER_LABEL[target.provider] or "Acquisition source")
  end
  return items or "Objective place"
end

local function status_label(row, options)
  local items = item_label(copy_ids(row.item_ids), options.item_names)
  local provider = PROVIDER_LABEL[row.provider] or "Acquisition source"
  return items ~= nil and (items .. " - " .. provider) or provider
end

local function route_supported(target)
  local endpoint = type(target) == "table" and target.target or nil
  if type(endpoint) ~= "table" or type(endpoint.pos) ~= "table" then return false end
  if target.kind == "npc" then return type(endpoint.cid) == "number" end
  return true
end

local function kind_text(kind, provider)
  if kind == "npc" then return "Objective NPC" end
  if kind == "place" then return "Objective place" end
  if kind == "source" then return PROVIDER_LABEL[provider] or "Acquisition source" end
  return "Objective"
end

local function add_qid(model, qid, entry)
  if type(qid) ~= "number" or math.type(qid) ~= "integer" or qid <= 0 then return end
  local rows = model.by_qid[qid]
  if rows == nil then rows = {}; model.by_qid[qid] = rows end
  local key = tostring(qid) .. "\0" .. entry.identity
  if model.seen[key] then return end
  model.seen[key] = true
  rows[#rows + 1] = entry
end

local function finish_entry(entry, marker_off, route_off)
  entry.ui_id = identity_id(entry.identity)
  entry.persist_key = M.stable_token(entry.identity)
  entry.kind_text = kind_text(entry.kind, entry.provider)
  entry.status_text = M.status_text(entry.state)
  entry.reason_text = M.reason_text(entry.reason_code)
  entry.controls_enabled = entry.state == "available" and entry.target ~= nil
  entry.marker_checked = marker_off[entry.persist_key] ~= true
  entry.route_checked = route_off[entry.persist_key] ~= true
  entry.marker_effective = entry.controls_enabled and entry.marker_checked
  entry.route_effective = entry.controls_enabled and entry.marker_checked
    and entry.route_checked and entry.route_supported
  entry.path_text = entry.route_supported and (entry.route_effective and "Waiting" or "Not requested")
    or "Unavailable"
  return entry
end

function M.build(snapshot, options)
  options = type(options) == "table" and options or {}
  local marker_off, route_off = off_set(options.marker_off), off_set(options.route_off)
  local model = { by_qid = {}, provider_rows = {}, entries = {}, identities = {},
    seen = {}, generation = 0, complete = true, passthrough = false }
  if type(snapshot) ~= "table" then return model end
  model.generation = type(snapshot.generation) == "number" and snapshot.generation or 0
  local targets = dense(snapshot.targets, M.ENTRY_MAX)
  if targets == nil and snapshot.targets ~= nil then
    model.complete, model.passthrough = false, true
    model.reason_code = type(snapshot.targets) == "table" and #snapshot.targets > M.ENTRY_MAX
      and "objective_ui_target_overflow" or "objective_ui_target_invalid"
    model.seen = nil
    return model
  end
  for _, target in ipairs(targets or {}) do
    local owners = type(target) == "table" and dense(target.owners, 256) or nil
    local item_ids = type(target) == "table" and target.item_ids or nil
    local valid = type(target) == "table" and valid_identity(target.key)
      and type(target.target) == "table" and owners ~= nil
      and (item_ids == nil or dense(item_ids, 256) ~= nil)
    if valid then
      for _, owner in ipairs(owners) do
        if type(owner) ~= "table" or type(owner.qid) ~= "number"
            or math.type(owner.qid) ~= "integer" or owner.qid <= 0 then
          valid = false; break
        end
      end
    end
    if not valid then
      model.complete, model.passthrough = false, true
      model.reason_code = "objective_ui_target_invalid"
      model.seen = nil
      return model
    end
  end
  local by_identity = {}
  for _, target in ipairs(targets or {}) do
    local entry = finish_entry({ identity = target.key, target = target,
      kind = target.kind, provider = target.provider, state = "available",
      reason_code = "available", label = target_label(target, options),
      item_ids = copy_ids(target.item_ids), ordinal = target.ordinal,
      marker_supported = true, route_supported = route_supported(target) }, marker_off, route_off)
    by_identity[entry.identity] = entry
    model.identities[entry.persist_key] = true
    model.entries[#model.entries + 1] = entry
    for _, owner in ipairs(target.owners) do
      add_qid(model, owner.qid, entry)
    end
  end
  local focus = dense(options.focus_order, 16) or {}
  local need_qids = {}
  for _, group in ipairs(dense(snapshot.need_groups, M.ENTRY_MAX) or {}) do
    if type(group) == "table" and type(group.qid) == "number"
        and math.type(group.qid) == "integer" and group.qid > 0 then
      for _, option in ipairs(dense(group.options, 256) or {}) do
        local item_id = type(option) == "table" and option.item_id or nil
        if type(item_id) == "number" and math.type(item_id) == "integer" and item_id > 0 then
          local qids = need_qids[item_id]
          if qids == nil then qids = {}; need_qids[item_id] = qids end
          qids[group.qid] = true
        end
      end
    end
  end
  local provider_seen = {}
  for _, envelope in ipairs(dense(snapshot.source_status, 16) or {}) do
    for _, row in ipairs(type(envelope) == "table" and dense(envelope.rows, M.ENTRY_MAX) or {}) do
      if type(row) == "table" and valid_identity(row.identity) then
        local entry = by_identity[row.identity]
        local target_entry = entry ~= nil
        if entry ~= nil then
          entry.state = row.state == "available" and "available"
            or row.state == "unavailable" and "unavailable" or "unknown"
          entry.reason_code = row.reason_code
          finish_entry(entry, marker_off, route_off)
        else
          entry = finish_entry({ identity = row.identity, target = nil, kind = "source",
            provider = row.provider, state = row.state == "unavailable" and "unavailable" or "unknown",
            reason_code = row.reason_code, label = status_label(row, options),
            item_ids = copy_ids(row.item_ids), qid = row.qid, task_index = row.task_index,
            marker_supported = false,
            route_supported = false }, marker_off, route_off)
          model.entries[#model.entries + 1] = entry
          by_identity[entry.identity] = entry
        end
        if row.scope == "provider" and not provider_seen[entry.identity] then
          provider_seen[entry.identity] = true
          model.provider_rows[#model.provider_rows + 1] = entry
        elseif row.scope ~= "provider" then
          model.identities[entry.persist_key] = true
        end
        if target_entry then
          -- Normalized target ownership already placed this row on the exact quests.
        elseif row.scope ~= "provider" then
          if row.qid == nil then
            local matched = {}
            for _, item_id in ipairs(entry.item_ids) do
              for qid in pairs(need_qids[item_id] or {}) do matched[qid] = true end
            end
            for _, qid in ipairs(focus) do
              if matched[qid] then add_qid(model, qid, entry) end
            end
          else
            add_qid(model, row.qid, entry)
          end
        end
      end
    end
  end
  for _, rows in pairs(model.by_qid) do
    table.sort(rows, function(a, b)
      local ao, bo = a.ordinal or math.huge, b.ordinal or math.huge
      if ao ~= bo then return ao < bo end
      return a.identity < b.identity
    end)
  end
  table.sort(model.provider_rows, function(a, b) return a.identity < b.identity end)
  model.seen = nil
  return model
end

function M.control_maps(model)
  if type(model) ~= "table" or model.passthrough == true then return nil, nil end
  local markers, routes = {}, {}
  for _, entry in ipairs(type(model) == "table" and model.entries or {}) do
    if entry.target ~= nil and entry.controls_enabled then
      if entry.marker_effective then markers[entry.identity] = true end
      if entry.route_effective then routes[entry.identity] = true end
    end
  end
  return markers, routes
end

local function sorted_saved(values)
  local out, seen = {}, {}
  for _, identity in ipairs(dense(values, M.ENTRY_MAX) or {}) do
    if valid_token(identity) and not seen[identity] then
      seen[identity] = true; out[#out + 1] = identity
    end
  end
  table.sort(out)
  return out
end

local function same_list(a, b)
  if type(a) ~= "table" or #a ~= #b then return false end
  for i, value in ipairs(b) do if a[i] ~= value then return false end end
  return true
end

function M.prune_overrides(marker_off, route_off, model)
  local markers = sorted_saved(marker_off)
  local routes = sorted_saved(route_off)
  return markers, routes, not same_list(marker_off, markers) or not same_list(route_off, routes)
end

function M.set_enabled(values, identity, enabled)
  local set = off_set(values)
  if valid_token(identity) then
    if enabled == true then set[identity] = nil else set[identity] = true end
  end
  local out = {}
  for value in pairs(set) do out[#out + 1] = value end
  table.sort(out)
  while #out > M.ENTRY_MAX do out[#out] = nil end
  return out
end

function M.search_rows(model, query, markers)
  if type(query) ~= "string" or query == "" then return {} end
  local needle = string.lower(query)
  local rows, seen = {}, {}
  for _, entry in ipairs(type(model) == "table" and model.entries or {}) do
    if entry.kind == "source" and not seen[entry.identity]
        and string.find(string.lower(entry.label or ""), needle, 1, true) then
      seen[entry.identity] = true
      rows[#rows + 1] = { identity = entry.identity, provider = entry.provider,
        state = entry.state, reason_code = entry.reason_code, item_ids = copy_ids(entry.item_ids),
        label = entry.label, qid = entry.qid, task_index = entry.task_index }
      if #rows >= M.ENTRY_MAX then break end
    end
  end
  local marker_provider = { chest = "chest", seller = "seller", shop = "shop",
    monster = "monster", quest_item = "placed", objective = "placed" }
  for _, marker in ipairs(dense(markers, M.ENTRY_MAX) or {}) do
    local provider = type(marker) == "table" and (marker.provider or marker_provider[marker.cat]) or nil
    local identity = type(marker) == "table"
      and (marker.objective_key or marker.source_id or marker.source_key or marker.key) or nil
    local label = type(marker) == "table" and (marker.label or marker.name) or nil
    if provider ~= nil and valid_identity(identity) and not seen[identity]
        and type(label) == "string" and string.find(string.lower(label), needle, 1, true) then
      local state, reason = "available", "available"
      if marker.opened == true then state, reason = "unavailable", "chest_opened"
      elseif marker.collected == true or marker.done == true then
        state, reason = "unavailable", "pickup_collected"
      elseif marker.dead == true or marker.alive == false then
        state, reason = "unavailable", "source_dead"
      elseif marker.zero_chance == true then state, reason = "unavailable", "zero_chance" end
      seen[identity] = true
      rows[#rows + 1] = { identity = identity, provider = provider, state = state,
        reason_code = reason, item_ids = copy_ids(marker.objective_item_ids or marker.item_ids),
        label = label }
      if #rows >= M.ENTRY_MAX then break end
    end
  end
  table.sort(rows, function(a, b) return a.identity < b.identity end)
  return rows
end

local function browser_rows(rows)
  local out = {}
  local bounded = dense(rows, M.ENTRY_MAX)
  if bounded == nil then return nil end
  for _, row in ipairs(bounded) do
    if type(row) == "table" and valid_identity(row.identity) then
      local state = row.state == "available" and "available"
        or row.state == "unavailable" and "unavailable" or "unknown"
      out[#out + 1] = { identity = row.identity, provider = row.provider,
        qid = row.qid, task_index = row.task_index, state = state,
        reason_code = row.reason_code, item_ids = copy_ids(row.item_ids),
        label = type(row.label) == "string" and row.label or "Acquisition source",
        status_text = M.status_text(state), reason_text = M.reason_text(row.reason_code) }
    end
  end
  table.sort(out, function(a, b) return a.identity < b.identity end)
  return out
end

local function browser_unknown(reason)
  return { { identity = "provider:source_browser", provider = "source_browser",
    state = "unknown", reason_code = reason, item_ids = {},
    label = "Acquisition sources", status_text = M.status_text("unknown"),
    reason_text = M.reason_text(reason) } }
end

local function browser_signature(query, rows)
  local parts = { query }
  for _, row in ipairs(rows) do
    parts[#parts + 1] = table.concat({ row.identity, row.provider or "", row.state,
      row.reason_code or "", row.label or "" }, "\1")
    for _, item_id in ipairs(row.item_ids) do parts[#parts + 1] = tostring(item_id) end
  end
  return table.concat(parts, "\2")
end

function M.browser_step(previous, open, query, observed_rows)
  query = type(query) == "string" and query:sub(1, 64) or ""
  local prior_generation = type(previous) == "table" and previous.generation or 0
  if open ~= true then
    return { open = false, query = query, generation = prior_generation, rows = {} }
  end
  local envelope = type(observed_rows) == "table" and type(observed_rows.rows) == "table"
    and observed_rows or nil
  local source_rows = envelope ~= nil and envelope.rows or observed_rows
  local rows = browser_rows(source_rows)
  local complete, reason_code = envelope == nil or envelope.complete == true,
    envelope ~= nil and envelope.reason_code or nil
  if rows == nil then
    complete, reason_code = false, "source_browser_status_overflow"
    rows = browser_unknown(reason_code)
  elseif not complete and #rows == 0 then
    reason_code = type(reason_code) == "string" and reason_code
      or "source_browser_incomplete"
    rows = browser_unknown(reason_code)
  end
  local signature = browser_signature(query, rows) .. "\2"
    .. tostring(complete) .. "\2" .. tostring(reason_code)
  local generation = prior_generation
  if type(previous) ~= "table" or previous.open ~= true or previous.signature ~= signature then
    generation = math.min(2147483647, math.max(1, prior_generation + 1))
  end
  return { open = true, query = query, generation = generation,
    signature = signature, rows = rows, complete = complete, reason_code = reason_code }
end

function M.browser_is_live(open, seen_frame, current_frame)
  return open == true and type(seen_frame) == "number" and type(current_frame) == "number"
    and current_frame >= seen_frame and current_frame - seen_frame <= 2
end

return M
