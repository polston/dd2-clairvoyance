-- Source-level contracts for behavior that lives inside REFramework hooks and
-- cannot be loaded in the pure-Lua unit harness.
local f = assert(io.open("reframework/autorun/Clairvoyance.lua", "rb"))
local src = f:read("*a"):gsub("\r\n", "\n")
f:close()

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
local function slice(name, first, last)
  local a = src:find(first, 1, true)
  local b = a and src:find(last, a + #first, true)
  check(name .. " sentinels exist", a ~= nil and b ~= nil)
  if a == nil or b == nil then return "" end
  return src:sub(a, b - 1)
end

check("hook identity uses plain equality",
  src:find("local function same%(a, b%)%s+return a ~= nil and b ~= nil and a == b%s+end") ~= nil)
check("hook identity has no address fallback",
  src:find("a:get_address%(%) == b:get_address%(%)", 1, false) == nil)
check("removed fallback counter is not exposed",
  src:find("same_fallback_n", 1, true) == nil)
local objective_projection = slice("debug objective projection",
  "local provider_generations = {}", "for _, r in ipairs((wt.q(\"input\"")
local provider_projection = slice("debug provider projection",
  "local provider_generations = {}", "local source_status = {}")
local source_status_projection = slice("debug source status projection",
  "local source_status = {}", "local need_groups = {}")
check("debug focus copies bounded provider diagnostic rows",
  provider_projection:find("diagnostic_rows = {}", 1, true) ~= nil
    and provider_projection:find("math.min(#(type(provider.diagnostic_rows)", 1, true) ~= nil
    and provider_projection:find("member_id = diagnostic.member_id, gate = diagnostic.gate", 1, true) ~= nil
    and provider_projection:find("status = diagnostic.status", 1, true) ~= nil
    and provider_projection:find("reason = diagnostic.reason", 1, true) == nil)
check("debug focus copies bounded source status rows and item ids",
  source_status_projection:find("math.min(#(objective_snapshot.source_status or {}), 16)", 1, true) ~= nil
    and source_status_projection:find("math.min(#(type(observed.rows) == \"table\" and observed.rows or {}), 512)", 1, true) ~= nil
    and source_status_projection:find("math.min(#(type(row.item_ids) == \"table\" and row.item_ids or {}), 256)", 1, true) ~= nil
    and src:find("source_status = source_status", 1, true) ~= nil
    and src:find("source_status = objective_snapshot.source_status", 1, true) == nil)

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

local function ordered(name, body, tokens)
  local at = 1
  for _, token in ipairs(tokens) do
    local found = body:find(token, at, true)
    check(name .. " order: " .. token, found ~= nil)
    if found == nil then return end
    at = found + #token
  end
end

local hint_inputs = slice("hint access-gate wiring",
  "wt.hint_inputs = function()",
  "wt.hint_text = function(text)")
ordered("every hint pin uses the generic adapter access filter", hint_inputs, {
  'target_kind = "hint_pin", quest_id = qid, pin_index = i,',
  "pcall(adapter.filter_access_targets, pins)",
  'if ok and type(filtered) == "table" then',
  "pins = filtered",
  "return qids, pins",
})
check("hint access selection has no quest-specific branch",
  hint_inputs:find("qid == 30040", 1, true) == nil
    and hint_inputs:find("needs_door", 1, true) == nil
    and hint_inputs:find("masquerade", 1, true) == nil
    and hint_inputs:find("core.filter_hint_pins", 1, true) == nil)
check("main source contains no legacy masquerade access API",
  src:find("masquerade_door_closed", 1, true) == nil)

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

-- SPEC 39: current-objective integration uses one post-compute snapshot.
check("focus objective inputs include journal cache and related opt-ins",
  src:find("prev_focus_journal = snapshot and snapshot.focus_journal", 1, true) ~= nil
    and src:find("show.focus_related_qids = settings.focus_related_qids", 1, true) ~= nil)
check("quests parser preserves the validated objective catalog",
  src:find("local quests, info = npcs.parse_quests(t)", 1, true) ~= nil
    and src:find("wt.quest_catalog = type(info) == \"table\" and info or nil", 1, true) ~= nil)
local tick_body = slice("objective tick wiring",
  "local ok, err = pcall(function()",
  "local wm = result.world and result.world.monster or nil")
ordered("objective inputs flow through one snapshot before compute", tick_body, {
  "pcall(adapter.refresh_objectives)",
  "pcall(adapter.refresh_items, mode)",
  "adapter.objective_task_snapshot,",
  "core.objective_task_projection(",
  "pcall(adapter.objective_need_groups,",
  "task_snapshot.objective_needs = need_snapshot",
  'wt.q("objective_place_snapshot",',
  'wt.q("objective_source_snapshots",',
  "core.objective_snapshot(",
  "local objective_names = { npcs = {}, targets = {}, items = {} }",
  "category_visibility =",
  "local result = core.compute(adapter, show)",
})
check("objective need grouping fails closed before provider and core processing",
  tick_body:find('local failed_need_snapshot = { status = "unknown", complete = false,', 1, true) ~= nil
    and tick_body:find('reason = "need_snapshot_failed"', 1, true) ~= nil)
local compute_at = tick_body:find("local result = core.compute(adapter, show)", 1, true)
local route_at = tick_body:find('wt.q("set_routes", nil, result.objective_routes)', 1, true)
local success_at = tick_body:find("if result == nil then", 1, true)
check("routes come from the exact post-compute objective snapshot",
  compute_at ~= nil and success_at ~= nil and route_at ~= nil
    and route_at > compute_at and route_at > success_at
    and tick_body:find("wt.route_members", 1, true) == nil)
check("objective route policy preserves search, names and capped route counts",
  tick_body:find("objective_policy.search_target", 1, true) ~= nil
    and tick_body:find("local objective_names = { npcs = {}, targets = {}, items = {} }", 1, true) ~= nil
    and tick_body:find("pcall(adapter.item_name, item_id)", 1, true) ~= nil
    and tick_body:find("objective_policy.route_cap", 1, true) ~= nil
    and tick_body:find("(objective_policy.npc_route_mode or 0) < 1", 1, true) ~= nil
    and tick_body:find("category_visibility =", 1, true) ~= nil
    and tick_body:find("core.objective_routes(", 1, true) ~= nil
    and tick_body:find("route_render_projection", 1, true) ~= nil
    and tick_body:find("core.route_members", 1, true) == nil
    and tick_body:find("wt.routes_n", 1, true) ~= nil
    and tick_body:find("wt.routes_total", 1, true) ~= nil)
check("objective target reads are limited to progressing focused quests",
  tick_body:find("adapter.progressing_ids", 1, true) ~= nil
    and tick_body:find("progressing_seen[qid]", 1, true) ~= nil)
check("tree checklist separately observes visible progressing quests without publishing targets",
  tick_body:find("local checklist_qids", 1, true) ~= nil
    and tick_body:find("if tree_live and type(show.objective_snapshot)", 1, true) ~= nil
    and tick_body:find("pcall(core.objective_checklist,", 1, true) ~= nil
  and tick_body:find("core.objective_snapshot_with_checklist(", 1, true) ~= nil)
check("tree-only checklist failures cannot poison focused objective needs",
  tick_body:find("pcall(adapter.objective_need_groups,\n      task_snapshot", 1, true) ~= nil
    and tick_body:find("observed_tree_needs = pcall(adapter.objective_need_groups,", 1, true) ~= nil
    and tick_body:find("observed_task_snapshot)", 1, true) ~= nil)
local objective_task_reads = 0
for _ in tick_body:gmatch("adapter%.objective_task_snapshot") do
  objective_task_reads = objective_task_reads + 1
end
check("tree checklist and focused targets share one task observation per tick",
  objective_task_reads == 1
    and tick_body:find("core.objective_task_projection(", 1, true) ~= nil)
check("save/session reset clears the objective stability cache",
  tick_body:find("wt.objective_snapshot_cache, wt.objective_snapshot_held = nil, false", 1, true) ~= nil)
check("localized objective names cover every target owner",
  tick_body:find("for _, owner in ipairs(target.owners or {}) do", 1, true) ~= nil)
check("shown ancillary routes use the semantic route list without requiring markers",
  tick_body:find("fq ~= nil and fq.route_related_npcs or {}", 1, true) ~= nil
    and tick_body:find("pcall(adapter.npc_name, cid)", 1, true) ~= nil
    and tick_body:find("marker.cat == \"focus_npc\"", 1, true) == nil)
check("progressing-only publication carries positioned startable givers as a bounded legacy member",
  tick_body:find("policy.startable_givers = {}", 1, true) ~= nil
    and tick_body:find("fq.progressing == false", 1, true) ~= nil
    and tick_body:find("core.objective_routes(", 1, true) ~= nil)
check("world search target keeps its reserved route slot when a shown ancillary shares its CID",
  tick_body:find("if cid ~= wt.route_cid then", 1, true) ~= nil
    and tick_body:find("policy.route_cap = 8", 1, true) == nil)
check("world target-first route keeps its reserved slot and render projection",
  tick_body:find("core.route_render_projection(show.routes, route_publication)", 1, true) ~= nil
    and tick_body:find("reserved_search", 1, true) ~= nil)
check("stale objective routes are filtered individually without suppressing manual routes",
  tick_body:find("core.route_render_projection(show.routes, route_publication)", 1, true) ~= nil
    and tick_body:find("core.filter_route_points(result.markers", 1, true) ~= nil
    and tick_body:find("core.filter_route_points(result.fullmap_world", 1, true) ~= nil
    and tick_body:find("wt.render_routes = render_routes", 1, true) ~= nil
    and tick_body:find("routes_current and show.routes or nil", 1, true) == nil
    and tick_body:find("route_on, has_pts = false", 1, true) == nil)
check("generation-only objective refresh does not disable stable route rendering",
  tick_body:find("local route_changed", 1, true) == nil
    and tick_body:find("wt.objective_route_sig = route_sig", 1, true) == nil)
check("route drawing and legend consume the filtered render projection",
  src:find("local routes = wt.render_routes", 1, true) ~= nil
    and src:find("icons.cur_routes = routes", 1, true) ~= nil)
check("lead calibration records are isolated, last, zero-size and uncounted",
  src:find("if m.calibration == true then", 1, true) ~= nil
    and src:find("and not m.calibration", 1, true) ~= nil
    and src:find("snapshot.fullmap_calibration", 1, true) ~= nil
    and src:find("if m.calibration ~= true then added_count = added_count + 1 end", 1, true) ~= nil
    and src:find("if m.calibration == true then ref:set_Scale(0) end", 1, true) ~= nil
    and src:find("rec.calibration and 0 or scale", 1, true) ~= nil
    and src:find("if m.calibration ~= true then note_dropped() end", 1, true) ~= nil)
check("native map icons provide zero-cost route transform anchors",
  src:find("native.pool == pool", 1, true) ~= nil
    and src:find("marker = { pos = { x = x, y = y, z = z }, calibration = true }", 1, true) ~= nil)
check("current-route validation delegates the complete endpoint comparison",
  src:find("function M.route_render_projection", 1, true) == nil
    and tick_body:find("core.route_render_projection(show.routes, route_publication)", 1, true) ~= nil)
local set_routes_n = 0
for _ in src:gmatch('wt%.q%("set_routes"') do set_routes_n = set_routes_n + 1 end
check("main has exactly one set_routes handoff", set_routes_n == 1)
check("item objective routes use the same current player origin as compute",
  src:find("core.objective_routes(", 1, true) ~= nil
    and src:find("result.objective_snapshot, show.origin, policy)", 1, true) ~= nil)

check("objective route labels are explicit",
  src:find('"Current objective NPCs"', 1, true) ~= nil
    and src:find('"Objective + shown related NPCs"', 1, true) ~= nil
    and src:find('"Routes to objective places/items##focus_place_routes"', 1, true) ~= nil)
local path_frame = slice("route path frame", "wt.path_frame = function()",
  "re.on_frame(function() wt.layer_run(wt.path_layer")
check("fresh walking routes start path work before any line is drawable",
  path_frame:find("(wt.routes_n or 0) > 0", 1, true) ~= nil
    and path_frame:find("wt.route_on and settings.route_path == 1", 1, true) == nil)
local world_path = slice("world walking path", "wt.world_path = function(",
  "wt.route_frame = function()")
check("world walking paths use the same filtered render projection as map paths",
  world_path:find("local routes = wt.render_routes", 1, true) ~= nil
    and world_path:find('wt.q("input", nil)', 1, true) == nil)
check("route status is visible in both quest tree and open-map legend",
  src:find('wt.q("route_status", nil, settings.route_path, settings.world_undiscovered)', 1, true) ~= nil
    and src:find('"Route paths: %d/%d ready', 1, true) ~= nil
    and src:find('wt.layer_run(wt.legend_layer, "route legend", icons.legend)', 1, true) ~= nil)
check("related NPC controls and pruning are wired",
  src:find("wt.focus_prune_related = function(active)", 1, true) ~= nil
    and src:find("wt.related_toggle = function(qid, on, rec)", 1, true) ~= nil
    and src:find('imgui.checkbox("Show related NPCs##qfr_" .. qid', 1, true) ~= nil
    and src:find('wt.focus_set("focus_related_qids", {})', 1, true) ~= nil)
check("tracked main quest can show the related NPC control without a side-tree record",
  src:find("local related_live = rec == nil or", 1, true) ~= nil
    and src:find("if related_live and wt.is_focused(qid) then", 1, true) ~= nil)

check("objective appearance reaches every drawn surface",
  src:find("wt.style.group_of_marker(m)", 1, true) ~= nil
    and src:find("wt.style.group_of_marker(marker)", 1, true) ~= nil
    and src:find('{ "focus_objective", "Current objective" }', 1, true) ~= nil)

local debug_focus = slice("objective debug copy",
  "      focus = function()",
  "      -- stats plus at most 20 rows")
check("focus debug copies objective and related fields",
  debug_focus:find("objective = {", 1, true) ~= nil
    and debug_focus:find("related_shown = q.related_shown", 1, true) ~= nil
    and debug_focus:find("related_hidden = q.related_hidden", 1, true) ~= nil
    and debug_focus:find("ordinal = target.ordinal", 1, true) ~= nil
    and debug_focus:find("provider = target.provider", 1, true) ~= nil
    and debug_focus:find("owners =", 1, true) ~= nil
    and debug_focus:find("eligibility = target.eligibility", 1, true) ~= nil
    and debug_focus:find("item_ids =", 1, true) ~= nil)
check("focus debug copies provider generations and registry diagnostics",
  debug_focus:find("objective_snapshot.stamp", 1, true) ~= nil
    and debug_focus:find("provider_generations", 1, true) ~= nil
    and debug_focus:find("focus_epoch = objective_snapshot.stamp", 1, true) ~= nil
    and debug_focus:find("journal_generation = objective_snapshot.stamp", 1, true) ~= nil
    and debug_focus:find("need_generation = objective_snapshot.stamp", 1, true) ~= nil
    and debug_focus:find("registry_diagnostics", 1, true) ~= nil
    and debug_focus:find("key_type = diagnostic.key_type", 1, true) ~= nil)
check("focus debug exposes only plain access-gate decisions",
  debug_focus:find("access_gates = {}", 1, true) ~= nil
    and debug_focus:find("gate_id = decision.gate_id", 1, true) ~= nil
    and debug_focus:find("current_status = decision.current_status", 1, true) ~= nil
    and debug_focus:find("used_last_known = decision.used_last_known", 1, true) ~= nil
    and debug_focus:find("reason = decision.reason", 1, true) ~= nil)
check("focus debug exposes grouped need and source capacity evidence",
  debug_focus:find("need_groups", 1, true) ~= nil
    and debug_focus:find("capacity_pool_id =", 1, true) ~= nil
    and debug_focus:find("capacity_kind = target.capacity_kind", 1, true) ~= nil
    and debug_focus:find("available_acquisitions = target.available_acquisitions", 1, true) ~= nil
    and debug_focus:find("certainty = target.certainty", 1, true) ~= nil
    and debug_focus:find("probability = target.probability", 1, true) ~= nil
    and debug_focus:find("groups = {}", 1, true) ~= nil)
check("focus debug exposes provider status and cap omissions",
  debug_focus:find("status = provider.status", 1, true) ~= nil
    and debug_focus:find("complete = provider.complete", 1, true) ~= nil
    and debug_focus:find("reason = provider.reason", 1, true) ~= nil
    and debug_focus:find("candidate_count = provider.candidate_count", 1, true) ~= nil
    and debug_focus:find("marker_omitted", 1, true) ~= nil
    and debug_focus:find("route_omitted", 1, true) ~= nil)
check("focus debug makes no managed NPC reads",
  debug_focus:find("adapter.npc_pos", 1, true) == nil
    and debug_focus:find("adapter.npc_alive", 1, true) == nil)

local rf = assert(io.open("README.md", "rb"))
local readme = rf:read("*a"):gsub("\r\n", "\n")
rf:close()
local readme_words = readme:gsub("%s+", " ")
check("README describes objective and related-NPC focus behavior",
  readme_words:find("Show related NPCs", 1, true) ~= nil
    and readme_words:find("Routes to objective places/items", 1, true) ~= nil
    and readme_words:find("current objective", 1, true) ~= nil
    and readme_words:find("unresolved", 1, true) ~= nil)

if failures > 0 then os.exit(1) end
print("main_source_test: all OK")
