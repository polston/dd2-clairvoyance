-- Pure registry and evaluator for world access gates.
local M = {}

M.registry = {
  gates = {
    {
      id = "masquerade_passage",
      observer_family = "door_leaf",
      fingerprint = {
        bucket_id = 85,
        type_name = "app.gm05_046",
        game_object_name = "gm80_026",
        position = { x = 396.075, y = 73.5, z = -819.250 },
        tolerance = 0.25,
        leaf_count = 1,
      },
    },
    {
      id = "beggars_garb_entrance",
      observer_family = "door_leaf",
      fingerprint = {
        bucket_id = 74,
        type_name = "app.gm05_046",
        game_object_name = "gm05_046",
        position = { x = 568.247, y = 19.779, z = -1014.327 },
        tolerance = 0.25,
        leaf_count = 1,
      },
    },
  },
  bindings = {
    {
      target_kind = "hint_pin",
      selector = { quest_id = 30040, pin_index = 1 },
      gate_id = "masquerade_passage",
      predicate = { field = "closed", equals = true },
      unknown_policy = "allow",
      may_use_last_known = true,
    },
    {
      target_kind = "placed_item",
      selector = {
        type_name = "app.Gm82_000",
        item_id = 300,
        position = { x = 571.018, y = 19.753, z = -1012.515 },
        position_tolerance = 0.25,
      },
      gate_id = "beggars_garb_entrance",
      predicate = { field = "locked", equals = false },
      unknown_policy = "deny",
      may_use_last_known = false,
    },
  },
}

local function finite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function array_length(t)
  if type(t) ~= "table" then return nil end
  local count, max_index = 0, 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return nil end
    count = count + 1
    if k > max_index then max_index = k end
  end
  if count ~= max_index then return nil end
  return count
end

local function valid_id(id)
  return type(id) == "string" and #id > 0
    and id:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

local function validate_selector(kind, selector)
  if type(selector) ~= "table" then return false end
  if kind == "hint_pin" then
    for key in pairs(selector) do
      if key ~= "quest_id" and key ~= "pin_index" then return false end
    end
    if type(selector.quest_id) ~= "number" or selector.quest_id < 1
      or selector.quest_id % 1 ~= 0 or type(selector.pin_index) ~= "number"
      or selector.pin_index < 1 or selector.pin_index % 1 ~= 0 then return false end
  elseif kind == "placed_item" then
    for key in pairs(selector) do
      if key ~= "type_name" and key ~= "item_id" and key ~= "position"
          and key ~= "position_tolerance" then return false end
    end
    local position = selector.position
    if type(selector.type_name) ~= "string" or selector.type_name == ""
        or type(selector.item_id) ~= "number" or selector.item_id < 1
        or selector.item_id % 1 ~= 0 or type(position) ~= "table"
        or not finite(position.x) or not finite(position.y) or not finite(position.z)
        or not finite(selector.position_tolerance)
        or selector.position_tolerance <= 0 then return false end
    for key in pairs(position) do
      if key ~= "x" and key ~= "y" and key ~= "z" then return false end
    end
  else
    return false
  end
  return true
end

function M.validate(registry)
  if type(registry) ~= "table" then return false, "registry is not a table" end
  local gate_count = array_length(registry.gates)
  local binding_count = array_length(registry.bindings)
  if gate_count == nil or binding_count == nil then
    return false, "gates and bindings must be dense arrays"
  end
  local gate_ids, fingerprint_keys, binding_keys = {}, {}, {}
  for i = 1, gate_count do
    local gate = registry.gates[i]
    local fp = type(gate) == "table" and gate.fingerprint or nil
    if type(gate) ~= "table" or not valid_id(gate.id) or gate_ids[gate.id]
      or gate.observer_family ~= "door_leaf" or type(fp) ~= "table"
      or not finite(fp.bucket_id) or fp.bucket_id < 0 or fp.bucket_id % 1 ~= 0
      or type(fp.type_name) ~= "string" or #fp.type_name == 0
      or type(fp.game_object_name) ~= "string" or #fp.game_object_name == 0
      or type(fp.position) ~= "table" or not finite(fp.position.x)
      or not finite(fp.position.y) or not finite(fp.position.z)
      or not finite(fp.tolerance) or fp.tolerance <= 0
      or fp.leaf_count ~= 1 then
      return false, "invalid gate at index " .. tostring(i)
    end
    local p = fp.position
    local fingerprint_key = tostring(fp.bucket_id) .. "\0" .. fp.type_name
      .. "\0" .. fp.game_object_name .. "\0" .. tostring(p.x)
      .. "\0" .. tostring(p.y) .. "\0" .. tostring(p.z)
      .. "\0" .. tostring(fp.tolerance) .. "\0" .. tostring(fp.leaf_count)
    if fingerprint_keys[fingerprint_key] then return false, "duplicate gate fingerprint" end
    gate_ids[gate.id] = true
    fingerprint_keys[fingerprint_key] = true
  end
  for i = 1, binding_count do
    local binding = registry.bindings[i]
    if type(binding) ~= "table" or not validate_selector(binding.target_kind, binding.selector)
      or not gate_ids[binding.gate_id] or type(binding.predicate) ~= "table"
      or (binding.predicate.field ~= "closed" and binding.predicate.field ~= "locked")
      or type(binding.predicate.equals) ~= "boolean"
      or (binding.unknown_policy ~= "allow" and binding.unknown_policy ~= "deny")
      or type(binding.may_use_last_known) ~= "boolean" then
      return false, "invalid binding at index " .. tostring(i)
    end
    local key = binding.target_kind
    if binding.target_kind == "hint_pin" then
      key = key .. "\0" .. tostring(binding.selector.quest_id)
        .. "\0" .. tostring(binding.selector.pin_index)
    else
      local p = binding.selector.position
      key = key .. "\0" .. binding.selector.type_name
        .. "\0" .. tostring(binding.selector.item_id)
        .. "\0" .. tostring(p.x) .. "\0" .. tostring(p.y) .. "\0" .. tostring(p.z)
        .. "\0" .. tostring(binding.selector.position_tolerance)
    end
    if binding_keys[key] then return false, "duplicate binding" end
    binding_keys[key] = true
  end
  return true
end

function M.requested_gate_ids(registry, requested)
  local n = array_length(requested)
  if n == nil then return nil, "requested ids must be a dense array" end
  local known, selected = {}, {}
  for i = 1, #registry.gates do known[registry.gates[i].id] = true end
  for i = 1, n do
    local id = requested[i]
    if known[id] and not selected[id] then selected[id] = true end
  end
  local out = {}
  for i = 1, #registry.gates do
    local id = registry.gates[i].id
    if selected[id] then out[#out + 1] = id end
  end
  return out
end

local function selector_matches(binding, target)
  if type(target) ~= "table" or target.target_kind ~= binding.target_kind then return false end
  if binding.target_kind == "placed_item" then
    if target.type_name ~= binding.selector.type_name
        or target.item_id ~= binding.selector.item_id
        or type(target.position) ~= "table" or not finite(target.position.x)
        or not finite(target.position.y) or not finite(target.position.z) then return false end
    local expected, tolerance = binding.selector.position, binding.selector.position_tolerance
    local dx, dy, dz = target.position.x - expected.x, target.position.y - expected.y,
      target.position.z - expected.z
    return dx * dx + dy * dy + dz * dz <= tolerance * tolerance
  end
  for key, value in pairs(binding.selector) do
    if target[key] ~= value then return false end
  end
  return true
end

function M.match_binding(registry, target)
  local found
  for i = 1, #registry.bindings do
    local binding = registry.bindings[i]
    if selector_matches(binding, target) then
      if found ~= nil then return nil, "ambiguous" end
      found = binding
    end
  end
  return found
end

local function observed_value(observation, field)
  if type(observation) == "table" and observation.status == "known"
    and type(observation.values) == "table"
    and type(observation.values[field]) == "boolean" then
    return observation.values[field]
  end
end

function M.evaluate(binding, current, last_known)
  local field = binding.predicate.field
  local value = observed_value(current, field)
  local source = "current"
  if value == nil and binding.may_use_last_known then
    value = observed_value(last_known, field)
    source = "last_known"
  end
  if value == nil then return binding.unknown_policy == "allow", "unknown" end
  return value == binding.predicate.equals, source
end

return M
