-- Whole-product focused-objective acceptance gate. This deliberately checks
-- total target/route publication, not only the provider currently under work.
local focus = D.focus()
if type(focus) ~= "table" or type(focus.objective_snapshot) ~= "table" then
  error("objective acceptance: snapshot unavailable")
end

local snapshot = focus.objective_snapshot
local need_count = #(snapshot.need_groups or {})
local target_count = #(snapshot.targets or {})
local objective_route_count, source_route_count = 0, 0
local source_target_count, source_target_keys = 0, {}
for _, target in ipairs(snapshot.targets or {}) do
  if target.kind == "source" and type(target.key) == "string" then
    source_target_count = source_target_count + 1
    source_target_keys[target.key] = true
  end
end
for _, route in ipairs(focus.routes or {}) do
  if route.objective == true then
    objective_route_count = objective_route_count + 1
    -- The final renderer presents direct source routes as kind="item"; stable
    -- target ownership, not presentation kind, proves the route-source join.
    if source_target_keys[route.target_key] then
      source_route_count = source_route_count + 1
    end
  end
end

for _, provider in ipairs((snapshot.stamp and snapshot.stamp.providers) or {}) do
  L(string.format(
    "objective_accept provider=%s status=%s complete=%s reason=%s candidates=%s",
    tostring(provider.provider), tostring(provider.status), tostring(provider.complete),
    tostring(provider.reason), tostring(provider.candidate_count)))
end
L(string.format(
  "objective_accept needs=%d targets=%d source_targets=%d routes=%d source_routes=%d active=%d",
  need_count, target_count, source_target_count, objective_route_count,
  source_route_count, #(focus.active or {})))

if need_count > 0 and target_count == 0 then
  error("objective acceptance: focused needs exist but no targets were published")
end
if target_count > 0 and objective_route_count == 0 then
  error("objective acceptance: targets exist but no objective routes were published")
end
if source_target_count > 0 and source_route_count == 0 then
  error("objective acceptance: source targets exist but no matching source route was published")
end
return string.format(
  "objective acceptance OK needs=%d targets=%d source_targets=%d routes=%d source_routes=%d",
  need_count, target_count, source_target_count, objective_route_count, source_route_count)
