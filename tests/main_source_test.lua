-- Source-level contracts for behavior that lives inside REFramework hooks and
-- cannot be loaded in the pure-Lua unit harness.
local f = assert(io.open("reframework/autorun/Clairvoyance.lua", "rb"))
local src = f:read("*a"):gsub("\r\n", "\n")
f:close()

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

check("hook identity uses plain equality",
  src:find("local function same%(a, b%)%s+return a ~= nil and b ~= nil and a == b%s+end") ~= nil)
check("hook identity has no address fallback",
  src:find("a:get_address%(%) == b:get_address%(%)", 1, false) == nil)
check("removed fallback counter is not exposed",
  src:find("same_fallback_n", 1, true) == nil)

check("catalog side count helper removed",
  src:find("local function catalog_side_count", 1, true) == nil)
local catalog_reads = {}
for block in src:gmatch('"Catalog:.-cs%.distinct%)%)') do
  catalog_reads[#catalog_reads + 1] = block
end
local snapshot_count_reads = 0
for _ in src:gmatch("snapshot%.catalog_side_count") do
  snapshot_count_reads = snapshot_count_reads + 1
end
check("catalog log and panel use the snapshot count",
  #catalog_reads == 2 and snapshot_count_reads == 2
    and catalog_reads[1]:find("(snapshot and snapshot.catalog_side_count) or 0", 1, true) ~= nil
    and catalog_reads[2]:find("(snapshot and snapshot.catalog_side_count) or 0", 1, true) ~= nil)

local function slice(name, first, last)
  local a = src:find(first, 1, true)
  local b = a and src:find(last, a + #first, true)
  check(name .. " sentinels exist", a ~= nil and b ~= nil)
  if a == nil or b == nil then return "" end
  return src:sub(a, b - 1)
end

local function ordered(name, body, tokens)
  local at = 1
  for _, token in ipairs(tokens) do
    local found = body:find(token, at, true)
    check(name .. " order: " .. token, found ~= nil)
    if found == nil then return end
    at = found + #token
  end
end

local overhead_wiring = slice("overhead cache wiring",
  "wt.overhead_state = { frame = -1, reason = nil }",
  "-- Records why this frame drew nothing")
check("cache is stored on wt",
  overhead_wiring:find("wt.overhead_state = { frame = -1, reason = nil }", 1, true) ~= nil)
ordered("field-assigned shared helper", overhead_wiring, {
  "wt.overhead_block_reason = function()",
  "return core.overhead_block(wt.overhead_state, jump_frame,",
  "settings.hide_overhead_in_cutscenes_and_menus, adapter.overhead_block_reason)",
})

local overhead_body = slice("overhead_frame body",
  "local function overhead_frame()",
  "re.on_frame(function()")
ordered("marker gate precedes work", overhead_body, {
  "if not settings.enabled then return overhead_idle(\"disabled\") end",
  "if not settings.show_overhead then return overhead_idle(\"toggle\") end",
  "if snapshot == nil then",
  "if ui_map ~= nil then return overhead_idle(\"map open\") end",
  "local reason = wt.overhead_block_reason()",
  "if reason ~= nil then return overhead_idle(reason) end",
  "local cx, cy, cz = camera_pos()",
  "overhead_pass(cx, cy, cz)",
})

local route_body = slice("wt.route_frame body",
  "wt.route_frame = function()",
  "re.on_frame(function() wt.layer_run(wt.route_layer")
ordered("route gate precedes route work", route_body, {
  "if not settings.enabled or not settings.show_overhead or not wt.has_pts",
  "local reason = wt.overhead_block_reason()",
  "if reason ~= nil then return end",
  "core.route_overhead_points(snapshot.markers)",
  "camera_pos()",
  "wt.world_path(cx, cy, cz, ox, oy, oz, max_d2)",
})

local names_body = slice("wt.names_frame body",
  "wt.names_frame = function()",
  "re.on_frame(function() wt.layer_run(wt.names_layer")
ordered("names gate clears counts before work", names_body, {
  "if not settings.enabled or mode == 0 or ui_map ~= nil",
  "local reason = wt.overhead_block_reason()",
  "if reason ~= nil then",
  "wt.names_stats.spawned, wt.names_stats.drawn, wt.names_stats.skipped = 0, 0, 0",
  "return",
  "local cx, cy, cz = camera_pos()",
  "wt.q(\"spawned_step\", nil, 200)",
})

local state_body = slice("debug state getter",
  "      state = function()",
  "      end,\n    }")
ordered("debug state reports fresh cached gate", state_body, {
  "wt.overhead_state.frame == jump_frame",
  "overhead_state = overhead_reason",
  "overhead_gate = overhead_gate",
  "overhead_drawn = overhead_drawn",
})
check("debug getter does not read gate", state_body:find("overhead_block_reason()", 1, true) == nil)

local checkbox_body = slice("NPC checkbox handler",
  "changed, settings.show_overhead =",
  "local sc, sv = imgui.slider_float(\"Overhead distance\"")
ordered("checkbox saves immediately", checkbox_body, {
  "imgui.checkbox(\"Overhead NPC indicators\", settings.show_overhead)",
  "if changed then save_settings() end",
  "imgui.checkbox(\"Hide overhead overlays in cutscenes and menus\",",
  "settings.hide_overhead_in_cutscenes_and_menus)",
  "if changed then save_settings() end",
})
check("toggle handler has no rebuild side effects",
  checkbox_body:find("want_update", 1, true) == nil
    and checkbox_body:find("last_tick", 1, true) == nil)

if failures > 0 then os.exit(1) end
print("main_source_test: all OK")
