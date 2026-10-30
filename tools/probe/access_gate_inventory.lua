local function upvalue(fn, wanted)
  for i = 1, 80 do
    local name, value = debug.getupvalue(fn, i)
    if name == nil then break end
    if name == wanted then return value end
  end
  return nil
end

local adapter = upvalue(D.dump_steps, "adapter")
if type(adapter) ~= "table" or type(adapter.filter_access_targets) ~= "function" then
  L("access adapter=false")
  return false
end

local garb_position = { x = 571.018, y = 19.753, z = -1012.515 }
local hint = { target_kind = "hint_pin", quest_id = 30040, pin_index = 1 }
local garb = { target_kind = "placed_item", type_name = "app.Gm82_000",
  item_id = 300, position = garb_position }
local filtered, decisions = adapter.filter_access_targets({ hint, garb })
local hint_visible, garb_visible = false, false
for _, target in ipairs(type(filtered) == "table" and filtered or {}) do
  if target == hint then hint_visible = true end
  if target == garb then garb_visible = true end
end
for _, decision in ipairs(type(decisions) == "table" and decisions or {}) do
  L(string.format("access gate=%s target=%s status=%s last=%s allowed=%s reason=%s",
    tostring(decision.gate_id), tostring(decision.target_kind),
    tostring(decision.current_status), tostring(decision.used_last_known),
    tostring(decision.allowed), tostring(decision.reason)))
end
L(string.format("access filtered hint=%s garb=%s", tostring(hint_visible),
  tostring(garb_visible)))

local function near_garb(pos)
  if type(pos) ~= "table" then return false end
  local dx, dy, dz = pos.x - garb_position.x, pos.y - garb_position.y,
    pos.z - garb_position.z
  return dx * dx + dy * dy + dz * dz <= 0.0625
end

local legacy_count = 0
for _, row in ipairs(adapter.item_locations() or {}) do
  if row.id == 300 and near_garb(row.pos) then legacy_count = legacy_count + 1 end
end

local focus = D.focus()
local objective_count = 0
local objective = type(focus) == "table" and focus.objective_snapshot or nil
for _, target in ipairs(type(objective) == "table" and objective.targets or {}) do
  local produces_garb = false
  for _, output in ipairs(target.outputs or {}) do
    if output.item_id == 300 then produces_garb = true; break end
  end
  if produces_garb and type(target.target) == "table" and near_garb(target.target.pos) then
    objective_count = objective_count + 1
  end
end
L(string.format("access publication legacy=%d objective=%d", legacy_count,
  objective_count))

return true
