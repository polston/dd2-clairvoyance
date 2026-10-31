-- Offline load + export-completeness check for adapter.lua.
-- Stubs the REFramework globals permissively; the adapter is never exercised
-- against the real game here, only loaded.
package.path = "reframework/autorun/Clairvoyance/?.lua;"
  .. "reframework/autorun/?.lua;" .. package.path

-- npcs.lua stand-in (the real module arrives from another lane): same
-- signature as related_items(records) -> { [item_id] = { qid, ... } }
-- (only "more"/"morethan" records; qids unique, ascending).
package.preload["Clairvoyance.npcs"] = function()
  local M = {}
  function M.related_items(records)
    M.last = records
    if M.override ~= nil then return M.override end
    local seen, out = {}, {}
    for _, r in ipairs(records) do
      if r.op == "more" or r.op == "morethan" then
        seen[r.id] = seen[r.id] or {}
        seen[r.id][r.qid] = true
      end
    end
    for id, set in pairs(seen) do
      local l = {}
      for q in pairs(set) do l[#l + 1] = q end
      table.sort(l)
      out[id] = l
    end
    return out
  end
  return M
end

local function permissive()
  local obj = {}
  setmetatable(obj, {
    __index = function() return function() return nil end end,
  })
  return obj
end

-- isQuestLogEnd stand-in: end_truth[qid] == true reads as ended.
local end_truth = {}
local method_stub = { call = function(_, _, qid) return end_truth[qid] == true end }

local function type_stub()
  local t = {}
  function t.get_field() return { get_offset_from_base = function() return 8 end } end
  function t.get_method() return method_stub end
  function t.get_runtime_type() return {} end
  function t.create_instance() return permissive() end
  return t
end

sdk = permissive()
function sdk.find_type_definition() return type_stub() end
log = permissive()
re = permissive()
ValueType = {
  new = function()
    local bytes = {}
    return {
      bytes = bytes,
      write_byte = function(_, offset, value) bytes[offset] = value end,
    }
  end,
}
Vector3f = permissive()
-- learned-name store: stored file with good and bad entries; dumps captured
local dumped, dump_count, dump_result = nil, 0, true
local json_reads, close_attempts = {}, 0
json = {
  load_file = function(path)
    json_reads[#json_reads + 1] = path
    return { ["20001"] = "Alpha", ["x"] = "bad", ["20002"] = "",
      ["20003"] = 7, ["10030"] = "Learned Override" }
  end,
  dump_file = function(_, t)
    dumped = t; dump_count = dump_count + 1; return dump_result
  end,
}

local real_io_open = io.open
local io_open_calls = {}
io.open = function(path, mode)
  if path == "Clairvoyance_names.json" then
    io_open_calls[#io_open_calls + 1] = path
    return nil, "missing"
  end
  if path == "QuestNPCMapLabels_names.json" then
    io_open_calls[#io_open_calls + 1] = path
    return { close = function() close_attempts = close_attempts + 1 end }
  end
  return real_io_open(path, mode)
end
local require_ok, A = pcall(require, "adapter")
io.open = real_io_open
assert(require_ok, "adapter require failed: " .. tostring(A))
assert(#io_open_calls == 2 and io_open_calls[1] == "Clairvoyance_names.json"
  and io_open_calls[2] == "QuestNPCMapLabels_names.json",
  "both fixed learned-name paths checked")
assert(close_attempts == 1, "legacy existence handle close attempted once")
assert(#json_reads == 1 and json_reads[1] == "QuestNPCMapLabels_names.json",
  "missing new store skips parsing and legacy store loads")

local exports = {
  "GIVER_HINTS", "GENERIC_NPC_IDS", "QUEST_REGION",
  "get_runtime_cast_charaids", "get_runtime_quest_position",
  "item_marker_guid", "world_marker_guid", "map_marker_guid", "ITEM_NAMES_BY_ICON",
  "is_npc_alive_and_ready", "get_character_world_pos", "guid_parse",
  "get_icon_pool", "argb_to_abgr", "int_value_offset", "uint_value_offset",
  "set_debug", "debug_probe", "rebuild_npc_pos_cache",
  "marker_guid", "new_map_icon_info", "new_unique_id", "make",
  "save_learned_names", "catalog_stats", "quest_log_is_end", "catalog_ids",
  "learn_names", "npc_live_pos", "probe_lookup", "refresh_objectives",
  "refresh_gates", "refresh_tree_gates", "refresh_items",
  "read_world_access_gates",
  "overhead_block_reason",
}
for _, name in ipairs(exports) do
  assert(A[name] ~= nil, "missing export: " .. name)
end
assert(A.PUBLIC_MAP_POSITIONS == nil, "PUBLIC_MAP_POSITIONS must be gone")

local parsed_guid = A.guid_parse("00112233-4455-6677-8899-aabbccddeeff")
local guid_bytes = {}
for offset = 0, 15 do
  guid_bytes[#guid_bytes + 1] = string.format("%02x", parsed_guid.bytes[offset])
end
assert(table.concat(guid_bytes) == "33221100554477668899aabbccddeeff",
  "guid_parse writes the expected zero-based bytes")
local malformed_guid = "not-a-guid"
local guid_ok, guid_error = pcall(A.guid_parse, malformed_guid)
assert(not guid_ok and tostring(guid_error):find("malformed GUID '" .. malformed_guid .. "'", 1, true),
  "guid_parse preserves malformed input in its error")

do
  local old_pools = A.icon_pools
  local panel, sprite = { label = "panel", array = "Panels", ref = "Panel" },
    { label = "sprite", array = "Sprites", ref = "Sprite" }
  A.icon_pools = { panel, sprite }
  local panel_ref, sprite_ref = {}, {}
  local pos = { x = 10, y = 2, z = 30 }
  local info = { Panel = panel_ref, Sprite = sprite_ref, Pos = pos }
  local this = {
    MapIconInfoList = { get_Count = function() return 1 end,
      get_Item = function(_, i) return i == 0 and info or nil end },
    Panels = { get_Length = function() return 2 end },
    Sprites = { get_Length = function() return 4 end },
  }
  local selected, used, capacity, native = A.get_icon_pool(this)
  assert(selected == sprite and used == 1 and capacity == 4
    and #native == 2 and native[1].ref == panel_ref and native[1].pos == pos
    and native[1].pool == panel and native[2].ref == sprite_ref
    and native[2].pool == sprite,
    "get_icon_pool returns each native ref with its map position and owning pool")
  A.icon_pools = old_pools
end

-- giver_audit_step (SPEC 18.5.1.4)
do
  assert(A.giver_audit_step(nil, {}, nil, nil, nil, nil) == false, "nil ids")
  assert(A.giver_audit_step({}, {}, nil, nil, nil, nil) == false, "empty ids")
  local lines = {}
  local done = A.giver_audit_step({ 20040, 10010 }, {},
    function(q) return q == 20040 end,
    function(q) return { 7 } end,
    function(c) return "chX" end,
    function(l) lines[#lines + 1] = l end)
  assert(done == true, "step must report done")
  assert(A.make().static_pos(20040) == nil, "static_pos must return nil")
  assert(#lines == 1, "exactly one audit line, got " .. #lines)
  assert(lines[1]:find("[20040]", 1, true) and lines[1]:find("7(chX)", 1, true),
    "audit line content: " .. tostring(lines[1]))
  -- a hinted quest is skipped
  local hl = {}
  local d2, n2 = A.giver_audit_step({ 20040, 20060 }, { [20040] = 5 },
    function() return true end,
    function() return { 7 } end,
    function() return "chX" end,
    function(l) hl[#hl + 1] = l end)
  assert(d2 == true and n2 == 1, "hinted quest must not count, got " .. tostring(n2))
  assert(#hl == 1 and hl[1]:find("[20060]", 1, true)
    and not hl[1]:find("[20040]", 1, true), "only the hintless quest is logged")
end

local a = A.make()
assert(type(a) == "table", "make() must return a table")
local contract = {
  "acceptable_ids", "progressing_ids", "is_side", "is_unavailable",
  "giver_hint", "is_generic", "cast_ids", "catalog_pos", "static_pos",
  "npc_alive", "npc_pos", "quest_name",
  "quest_state", "catalog_ids",
  "objective_cids", "objective_issued_cids", "objective_pos",
  "refresh_objectives", "objective_stats", "objective_task_snapshot",
  "objective_item_source_snapshots",
  "refresh_gates", "gate_qids", "gate_stats", "invalidate_gates",
  "seen_quest_name", "quest_region",
  "refresh_tree_gates", "invalidate_tree_gates", "tree_gate_qids",
  "tree_gate_table", "tree_gate_stats",
  "invalidate_items", "item_needs", "objective_need_groups", "item_locations", "item_name", "item_stats",
  "refresh_items", "item_related", "reset_item_throttle", "quest_steps_text",
  "tracked_qid", "journal_now", "journal_all", "npc_name", "journal_stats",
  "map_open", "map_jump_apply", "journal_note_jump", "map_cursor",
  "quest_step", "filter_access_targets",
  "overhead_block_reason",
}
assert(#contract == 54)
for _, name in ipairs(contract) do
  assert(type(a[name]) == "function", "contract function missing: " .. name)
end
local grouped, grouped_complete = A.objective_need_builder.build({
  { qid = 700, processor_id = 800, list_index = 0, condition_index = 1,
    complete = true, current_work = true, options = {
      { item_id = 900, required = 2, op = "more" },
      { item_id = 901, required = 2, op = "more" },
    } },
}, { [900] = 1 }, { generation = 3, task_generation = 3,
  task_index = { [700] = 4 } })
assert(grouped_complete and #grouped == 1 and grouped[1].remaining == 1
  and #grouped[1].options == 2 and grouped[1].id[1] == "need"
  and grouped[1].generation == 3, "adapter exports objective-only grouped need model")
local empty_need_snapshot = a.objective_need_groups()
assert(empty_need_snapshot.status == "unknown" and not empty_need_snapshot.complete
  and #empty_need_snapshot.groups == 0, "unrefreshed objective group snapshot is unknown")
local forgery_identity = { "source", "forgery", 1919, 0, 17, 25, 11, 29 }
local function forgery_evidence(overrides)
  local e = { identity = forgery_identity, service_talk_event_id = 1919,
    service_index = 0, service_chara_id = 17, service_shop_id = 25, output_item_id = 29,
    mapping_input_item_id = 11, mapping_output_item_id = 29, price = 6, mapping_price = 6,
    service_type = "NpcShopForgeryParam", service_position = { x = 1, y = 2, z = 3 },
    interactable = true, row_enabled = true, input_held = true, price_held = true,
    idle = true, busy = false, kept_item_id = 0, kept_item_count = 0,
    completed = false, completion_readable = true, busy_readable = true,
    kept_readable = true, completion_time_readable = true, completion_time = 0,
    order_owner_readable = true }
  for k, v in pairs(overrides or {}) do e[k] = v end
  return e
end
local pre_order = a.objective_forgery_evidence(forgery_evidence(), 7)
assert(pre_order.evidence_only == true and pre_order.publication_ready == false
  and pre_order.eligibility == "eligible" and pre_order.reason == "forgery_order_can_start"
  and pre_order.evidence_generation == 7 and pre_order.provider == nil
  and pre_order.status == nil and pre_order.complete == nil and pre_order.candidates == nil,
  "forgery classification is explicit evidence-only data, never an eligible provider publication")
local pending = a.objective_forgery_evidence(forgery_evidence({ idle = false, busy = true,
  input_held = false, price_held = false, kept_item_id = 11, kept_item_count = 1 }))
assert(pending.eligibility == "ineligible" and pending.reason == "forgery_order_pending",
  "forgery pending order is an ineligible evidence finding")
local complete = a.objective_forgery_evidence(forgery_evidence({ completed = true,
  input_held = false, price_held = false, kept_item_id = 29, kept_item_count = 1 }))
assert(complete.eligibility == "eligible" and complete.reason == "matching_forgery_output_ready"
  and complete.publication_ready == false,
  "completed matching output remains eligible without input or price")
local unrelated = a.objective_forgery_evidence(forgery_evidence({ completed = true,
  input_held = false, price_held = false, kept_item_id = 30, kept_item_count = 1 }))
assert(unrelated.eligibility == "ineligible" and unrelated.reason == "forgery_order_unrelated",
  "unrelated completed order is ineligible")
local unrelated_busy = a.objective_forgery_evidence(forgery_evidence({ idle = false, busy = true,
  input_held = false, price_held = false, kept_item_id = 30, kept_item_count = 1 }))
assert(unrelated_busy.eligibility == "ineligible"
  and unrelated_busy.reason == "forgery_order_unrelated",
  "unrelated active order is ineligible and distinct from a matching pending order")
local unreadable = a.objective_forgery_evidence(forgery_evidence({ busy_readable = false }))
assert(unreadable.eligibility == "unknown" and unreadable.reason == "forgery_busy_state_unreadable",
  "unreadable forgery state invalidates provider without stale candidates")
local completion_time_unreadable = a.objective_forgery_evidence(forgery_evidence({
  completion_time_readable = false }))
assert(completion_time_unreadable.eligibility == "unknown"
  and completion_time_unreadable.reason == "forgery_completion_time_unreadable",
  "forgery classification requires readable completion-time evidence")
local disabled = a.objective_forgery_evidence(forgery_evidence({ row_enabled = false,
  completion_time_readable = false }))
assert(disabled.eligibility == "ineligible" and disabled.reason == "forgery_mapping_disabled",
  "exact disabled forgery mapping is ineligible, not unknown")
local blocked = a.objective_forgery_evidence(forgery_evidence({ interactable = false,
  busy_readable = false }))
assert(blocked.eligibility == "ineligible"
  and blocked.reason == "forgery_service_not_interactable",
  "exact non-interactable service is ineligible, not unknown")
for _, bad in ipairs({
    { "false service id", { service_shop_id = false } },
    { "false input id", { mapping_input_item_id = false } },
    { "false output id", { output_item_id = false } },
    { "false mapped output id", { mapping_output_item_id = false } },
    { "false kept item id", { kept_item_id = false } },
    { "fractional service id", { service_shop_id = 17.5 } },
    { "fractional output id", { output_item_id = 29.5 } },
    { "fractional mapped output id", { mapping_output_item_id = 29.5 } },
    { "fractional kept item id", { kept_item_id = 0.5 } },
    { "fractional count", { kept_item_count = 0.5 } },
    { "infinite count", { kept_item_count = math.huge } },
    { "infinite position", { service_position = { x = math.huge, y = 2, z = 3 } } },
    { "nan position", { service_position = { x = 1, y = 0 / 0, z = 3 } } },
    { "infinite price", { price = math.huge, mapping_price = math.huge } },
    { "infinite completion time", { completion_time = math.huge } },
  }) do
  local malformed = a.objective_forgery_evidence(forgery_evidence(bad[2]))
  assert(malformed.eligibility == "unknown" and malformed.reason == "forgery_evidence_malformed",
    "malformed forgery evidence rejected: " .. bad[1])
end
for _, generation in ipairs({ 1.5, math.huge }) do
  local malformed = a.objective_forgery_evidence(forgery_evidence(), generation)
  assert(malformed.eligibility == "unknown" and malformed.reason == "forgery_generation_invalid",
    "fractional or infinite forgery evidence generation is rejected")
end

-- Talk-grant and forgery production providers are pure over atomic native
-- observations. Complete talk evidence publishes only reachable, currently
-- playable grants; incomplete source gates remain diagnostic and fail closed.
do
  assert(type(A.objective_talk_grant_provider_snapshot) == "function",
    "talk-grant provider classifier is exported")
  assert(type(A.objective_forgery_provider_snapshot) == "function",
    "forgery provider classifier is exported")
  local talk_observation = { complete = true, wanted = { 29 }, events = {
    { event_id = 1900, playable = true, playing = false,
      speaker_cid = 101, speaker_position = { x = 1, y = 2, z = 3 },
      interaction_readable = true, interaction_enabled = true,
      history_readable = true, history_present = false, nodes = {
        { index = 0, kind = "app.RootSegmentNode", node_id = "start",
          node_name_hash = 10, edges = {
          { index = 0, next_node_id = "grant", next_node_name_hash = 11,
            condition_count = 0 }, } },
        { index = 1, kind = "app.ItemControlSegmentNode", node_id = "grant",
          node_name_hash = 11, edges = {},
          grants = { { item_index = 0, item_id = 29, count = 1 } } },
      } }, } }
  local talk = A.objective_talk_grant_provider_snapshot(talk_observation, 7)
  assert(talk.provider == "talk_grant" and talk.generation == 7
    and talk.status == "ok" and talk.complete == true
    and #talk.candidates == 1 and #talk.diagnostics == 1
    and talk.candidates[1].source_id[2] == "talk_grant"
    and talk.candidates[1].source_id[3] == 1900
    and talk.candidates[1].source_id[4] == "grant"
    and talk.candidates[1].target.cid == 101
    and talk.candidates[1].outputs[1].item_id == 29
    and talk.candidates[1].eligibility == "eligible"
    and talk.diagnostics[1].eligibility == "eligible"
    and talk.source_status.complete == true and #talk.source_status.rows == 1
    and talk.source_status.rows[1].state == "available",
    "complete reachable direct grant publishes one stable positioned source")
  local function talk_variant(fields, edge_conditions, middle_kind, mismatched_hash)
    local event = {
      event_id = 1900, playable = true, playing = false, speaker_cid = 101,
      speaker_position = { x = 1, y = 2, z = 3 }, interaction_readable = true,
      interaction_enabled = true, history_readable = true, history_present = false,
      nodes = {
        { index = 0, kind = "app.RootSegmentNode", node_id = "start",
          node_name_hash = 10, edges = { { index = 0, next_node_id = "talk",
            next_node_name_hash = mismatched_hash or 12,
            condition_count = edge_conditions or 0 } } },
        { index = 1, kind = middle_kind or "app.TalkSegmentNode", node_id = "talk",
          node_name_hash = 12, edges = { { index = 0, next_node_id = "grant",
            next_node_name_hash = 11, condition_count = 0 } } },
        { index = 2, kind = "app.ItemControlSegmentNode", node_id = "grant",
          node_name_hash = 11, edges = {},
          grants = { { item_index = 0, item_id = 29, count = 1 } } },
      },
    }
    for key, value in pairs(fields or {}) do event[key] = value end
    return A.objective_talk_grant_provider_snapshot(
      { complete = true, wanted = { 29 }, events = { event } }, 8)
  end
  local modeled_talk = talk_variant()
  assert(#modeled_talk.candidates == 1
    and modeled_talk.diagnostics[1].eligibility == "eligible",
    "root and talk segments form a modeled unconditional grant path")
  local conditional_talk = talk_variant(nil, 1)
  assert(conditional_talk.status == "ok" and conditional_talk.complete
    and #conditional_talk.candidates == 0
    and conditional_talk.diagnostics[1].eligibility == "unknown"
    and conditional_talk.diagnostics[1].reason == "talk_grant_branch_condition_unmodeled"
    and conditional_talk.source_status.rows[1].state == "unknown"
    and conditional_talk.source_status.rows[1].reason_code
      == "talk_grant_branch_condition_unmodeled",
    "unsupported branch conditions remain unknown without hiding supported events")
  local gated_talk = talk_variant(nil, 0, "app.ItemDeliverySegmentNode")
  assert(#gated_talk.candidates == 0
    and gated_talk.diagnostics[1].eligibility == "unknown"
    and gated_talk.diagnostics[1].reason == "talk_grant_intermediate_node_unmodeled",
    "an unmodeled intermediate segment cannot become an unconditional grant path")
  local conflicting_edge = talk_variant(nil, 0, nil, 11)
  assert(#conflicting_edge.candidates == 0
    and conflicting_edge.diagnostics[1].eligibility == "unknown"
    and conflicting_edge.diagnostics[1].reason == "talk_grant_node_identity_conflict",
    "edge node id and name hash must resolve to the same stable node")
  local unavailable_talk = talk_variant({ playable = false })
  assert(#unavailable_talk.candidates == 0
    and unavailable_talk.diagnostics[1].eligibility == "ineligible"
    and unavailable_talk.diagnostics[1].reason == "talk_grant_event_unavailable"
    and unavailable_talk.source_status.rows[1].state == "unavailable",
    "a complete negative playability read rejects the grant")
  local claimed_talk = talk_variant({ history_present = true,
    history_played = false, history_result = 60 })
  assert(#claimed_talk.candidates == 1
    and claimed_talk.diagnostics[1].eligibility == "eligible",
    "a previously recorded but currently playable direct event remains obtainable")
  for _, observed_result in ipairs({ -1, 0, 60 }) do
    local recorded = talk_variant({ history_present = true,
      history_played = false, history_result = observed_result })
    assert(#recorded.candidates == 1,
      "observed playable history result is branch evidence, not claim state")
  end
  for _, blocked in ipairs({
      { { playing = true }, "ineligible", "talk_grant_event_playing" },
      { { interaction_enabled = false }, "ineligible", "talk_grant_interaction_disabled" },
      { { history_readable = false }, "unknown", "talk_grant_history_unreadable" },
      { { history_present = true, history_played = true }, "ineligible",
        "talk_grant_history_played" },
      { { history_present = true, history_played = nil }, "unknown",
        "talk_grant_history_state_unreadable" },
      { { history_present = true, history_played = false, history_result = false },
        "unknown", "talk_grant_history_result_unreadable" },
      { { speaker_position = false }, "unknown", "talk_grant_speaker_position_unreadable" },
    }) do
    local result = talk_variant(blocked[1])
    assert(#result.candidates == 0
      and result.diagnostics[1].eligibility == blocked[2]
      and result.diagnostics[1].reason == blocked[3],
      "talk-grant source gate: " .. blocked[3])
  end
  local no_talk = A.objective_talk_grant_provider_snapshot(
    { complete = true, wanted = { 29 }, events = {} }, 9)
  assert(no_talk.status == "ok" and no_talk.complete and #no_talk.candidates == 0,
    "a complete catalog scan with no matching talk grant is authoritative empty")
  local partial_talk = A.objective_talk_grant_provider_snapshot(
    { complete = false, reason = "talk_grant_nodes_truncated", wanted = { 29 }, events = {} }, 10)
  assert(partial_talk.status == "unknown" and not partial_talk.complete
    and partial_talk.reason == "talk_grant_nodes_truncated" and #partial_talk.candidates == 0
    and partial_talk.source_status.complete == false
    and partial_talk.source_status.rows[1].identity == "provider:talk_grant",
    "a partial talk catalog scan clears all candidates")

  local forgery_observation = { complete = true, wanted = { 29 },
    services = { { job = 94, talk_event_id = 1919, service_index = 0,
      chara_id = 3472286413, shop_id = 25, service_type = "app.NpcShopForgeryParam",
      playable = true, speaker_present = true, interactable = true,
      interaction_disabled = false, condition_truth_readable = false } },
    mappings = { { input_item_id = 11, output_item_id = 29, price = 6,
      enabled_readable = false } },
    order = { kept_readable = true, kept_item_id = 0, kept_item_count = 0,
      completion_time_readable = true, completion_time = 0,
      completed_readable = true, completed = false } }
  local forgery = A.objective_forgery_provider_snapshot(forgery_observation, 11)
  assert(forgery.provider == "forgery" and forgery.generation == 11
    and forgery.status == "ok" and forgery.complete and forgery.reason == nil
    and #forgery.candidates == 0 and #forgery.diagnostics.services == 1
    and #forgery.diagnostics.mappings == 1
    and forgery.source_status.rows[1].state == "unknown"
    and forgery.source_status.rows[1].reason_code == "forgery_mapping_enablement_unproven",
    "forgery provider preserves typed diagnostics and publishes unknown status")
  local enabled_observation = {
    complete = true, wanted = { 29 }, services = forgery_observation.services,
    mappings = { { input_item_id = 11, output_item_id = 29, price = 6,
      enabled_readable = true, enabled = true, held_readable = false,
      price_readable = false } }, order = forgery_observation.order }
  local enabled_forgery = A.objective_forgery_provider_snapshot(enabled_observation, 12)
  assert(enabled_forgery.status == "ok" and enabled_forgery.complete
    and enabled_forgery.source_status.rows[1].state == "unknown"
    and enabled_forgery.source_status.rows[1].reason_code == "forgery_service_speaker_join_unproven",
    "a readable enabled mapping exposes the exact structured-speaker join gate")
  local availability_service = {}
  for key, value in pairs(forgery_observation.services[1]) do
    availability_service[key] = value
  end
  availability_service.speaker_matches_service = true
  availability_service.availability_readable = false
  local availability_observation = {
    complete = true, wanted = { 29 }, services = { availability_service },
    mappings = enabled_observation.mappings, order = forgery_observation.order }
  local availability_forgery = A.objective_forgery_provider_snapshot(
    availability_observation, 13)
  assert(availability_forgery.status == "ok" and availability_forgery.complete
    and availability_forgery.source_status.rows[1].state == "unknown"
    and availability_forgery.source_status.rows[1].reason_code == "forgery_service_availability_unproven",
    "a matched speaker exposes the exact structured service-availability gate")
  local no_mapping = A.objective_forgery_provider_snapshot({ complete = true,
    wanted = { 29 }, services = forgery_observation.services, mappings = {},
    order = forgery_observation.order }, 14)
  assert(no_mapping.status == "ok" and no_mapping.complete and #no_mapping.candidates == 0,
    "a complete item catalog scan with no forgery mapping is authoritative empty")
  local partial_forgery = A.objective_forgery_provider_snapshot({ complete = false,
    reason = "forgery_service_catalog_truncated", wanted = { 29 }, services = {},
    mappings = {}, order = {} }, 15)
  assert(partial_forgery.status == "unknown" and not partial_forgery.complete
    and partial_forgery.reason == "forgery_service_catalog_truncated"
    and #partial_forgery.candidates == 0,
    "a partial forgery catalog scan clears all candidates")

  local function production_forgery(fields)
    local observation = { complete = true, wanted = { 29 },
      services = { { job = 94, talk_event_id = 1919, service_index = 0,
        chara_id = 3472286413, shop_id = 25,
        service_type = "app.NpcShopForgeryParam", playable = true,
        speaker_present = true, speaker_matches_service = true,
        availability_readable = true, available = true,
        speaker_position = { x = 10, y = 20, z = 30 },
        interactable = true, interaction_disabled = false } },
      mappings = { { input_item_id = 11, output_item_id = 29, price = 6,
        enabled_readable = true, enabled = true, held_readable = true,
        held_count = 1, price_readable = true, affordable = true } },
      order = { kept_readable = true, kept_item_id = 0, kept_item_count = 0,
        completion_time_readable = true, completion_time = 0,
        kept_state_readable = true, kept_active = false,
        completed_readable = true, completed = false,
        remaining_minutes_readable = true, remaining_minutes = 0 } }
    for key, value in pairs(fields or {}) do observation[key] = value end
    return observation
  end
  local preorder = A.objective_forgery_provider_snapshot(production_forgery(), 21)
  assert(preorder.status == "ok" and preorder.complete and preorder.reason == nil
    and #preorder.candidates == 1 and preorder.candidates[1].provider == "forgery"
    and preorder.candidates[1].generation == 21
    and preorder.candidates[1].source_id[1] == "source"
    and preorder.candidates[1].source_id[2] == "forgery"
    and preorder.candidates[1].source_id[3] == 1919
    and preorder.candidates[1].source_id[4] == 0
    and preorder.candidates[1].source_id[5] == 3472286413
    and preorder.candidates[1].source_id[6] == 25
    and preorder.candidates[1].source_id[7] == 11
    and preorder.candidates[1].source_id[8] == 29
    and preorder.candidates[1].target.cid == 3472286413
    and preorder.candidates[1].outputs[1].item_id == 29
    and preorder.source_status.complete == true
    and preorder.source_status.generation == 21
    and #preorder.source_status.rows == 1
    and preorder.source_status.rows[1].state == "available"
    and preorder.source_status.rows[1].reason_code == "forgery_order_can_start",
    "idle affordable forgery publishes one stable service/transformation source")
  local pending_observation = production_forgery()
  pending_observation.order.kept_item_id = 11
  pending_observation.order.kept_item_count = 1
  pending_observation.order.kept_active = true
  pending_observation.order.remaining_minutes = 3
  local pending_forgery = A.objective_forgery_provider_snapshot(pending_observation, 22)
  assert(pending_forgery.status == "ok" and pending_forgery.complete
    and #pending_forgery.candidates == 0
    and pending_forgery.source_status.rows[1].state == "unavailable"
    and pending_forgery.source_status.rows[1].reason_code == "forgery_order_pending",
    "matching pending forgery is visible as unavailable and never routed")
  local ready_observation = production_forgery()
  ready_observation.mappings[1].held_count = 0
  ready_observation.mappings[1].affordable = false
  ready_observation.order.kept_item_id = 29
  ready_observation.order.kept_item_count = 1
  ready_observation.order.completed = true
  local ready_forgery = A.objective_forgery_provider_snapshot(ready_observation, 23)
  assert(ready_forgery.status == "ok" and ready_forgery.complete
    and #ready_forgery.candidates == 1
    and ready_forgery.candidates[1].source_id[3] == 1919
    and ready_forgery.source_status.rows[1].state == "available"
    and ready_forgery.source_status.rows[1].reason_code == "matching_forgery_output_ready",
    "matching completed forgery routes to collection without input or payment")
  local ambiguous_ready = production_forgery()
  ambiguous_ready.services[2] = { job = 95, talk_event_id = 1920, service_index = 1,
    chara_id = 3472286414, shop_id = 25,
    service_type = "app.NpcShopForgeryParam", playable = true,
    speaker_present = true, speaker_matches_service = true,
    availability_readable = true, available = true,
    speaker_position = { x = 40, y = 20, z = 30 },
    interactable = true, interaction_disabled = false }
  ambiguous_ready.order.kept_item_id = 29
  ambiguous_ready.order.kept_item_count = 1
  ambiguous_ready.order.completed = true
  local ambiguous_forgery = A.objective_forgery_provider_snapshot(ambiguous_ready, 24)
  assert(ambiguous_forgery.status == "ok" and ambiguous_forgery.complete
      and #ambiguous_forgery.candidates == 0
      and #ambiguous_forgery.source_status.rows == 2
      and ambiguous_forgery.source_status.rows[1].identity
        ~= ambiguous_forgery.source_status.rows[2].identity
      and ambiguous_forgery.source_status.rows[1].state == "unknown"
      and ambiguous_forgery.source_status.rows[2].state == "unknown"
      and ambiguous_forgery.source_status.rows[1].reason_code
        == "forgery_order_service_unreadable"
      and ambiguous_forgery.source_status.rows[2].reason_code
        == "forgery_order_service_unreadable",
    "a global completed order cannot be routed when service ownership is ambiguous")
  local unrelated_observation = production_forgery()
  unrelated_observation.order.kept_item_id = 30
  unrelated_observation.order.kept_item_count = 1
  unrelated_observation.order.completed = true
  local unrelated_forgery = A.objective_forgery_provider_snapshot(unrelated_observation, 24)
  assert(unrelated_forgery.status == "ok" and unrelated_forgery.complete
    and #unrelated_forgery.candidates == 0
    and unrelated_forgery.source_status.rows[1].state == "unavailable"
    and unrelated_forgery.source_status.rows[1].reason_code == "forgery_order_unrelated",
    "an unrelated completed forgery cannot produce a stale candidate")
  local unknown_observation = production_forgery()
  unknown_observation.mappings[1].price_readable = false
  local unknown_forgery = A.objective_forgery_provider_snapshot(unknown_observation, 25)
  assert(unknown_forgery.status == "ok" and unknown_forgery.complete
    and #unknown_forgery.candidates == 0
    and unknown_forgery.source_status.generation == 25
    and unknown_forgery.source_status.rows[1].state == "unknown"
    and unknown_forgery.source_status.rows[1].reason_code == "forgery_preorder_evidence_unreadable",
    "unreadable affordability clears candidates in the same generation")
  local integrated = a.objective_item_source_snapshots(nil,
    { need_generation = 8 }, nil, nil, { talk_grant = {
      complete = true, wanted = { 29 }, events = {} }, forgery = production_forgery() })
  assert(#integrated == 6 and integrated[6].provider == "forgery"
    and integrated[6].status == "ok" and integrated[6].complete
    and #integrated[6].candidates == 1
    and integrated[6].candidates[1].generation == integrated[6].generation
    and integrated[6].source_status.generation == integrated[6].generation,
    "objective source integration retains one generation-atomic forgery publication")
  local integrated_unknown = production_forgery()
  integrated_unknown.mappings[1].price_readable = false
  local invalidated = a.objective_item_source_snapshots(nil,
    { need_generation = 8 }, nil, nil, { talk_grant = {
      complete = true, wanted = { 29 }, events = {} }, forgery = integrated_unknown })
  assert(invalidated[6].generation == integrated[6].generation + 1
    and #invalidated[6].candidates == 0
    and invalidated[6].source_status.generation == invalidated[6].generation
    and invalidated[6].source_status.rows[1].state == "unknown",
    "a changed unreadable forgery observation advances generation and drops the old route")

  local aux = { talk_grant = talk_observation, forgery = forgery_observation }
  local first = a.objective_item_source_snapshots(nil, { need_generation = 3 }, nil, nil, aux)
  local repeated = a.objective_item_source_snapshots(nil, { need_generation = 3 }, nil, nil, aux)
  assert(first[5].status == "ok" and first[5].complete
    and #first[5].candidates == 1
    and first[6].status == "ok" and first[6].complete
    and first[6].source_status.rows[1].reason_code == "forgery_mapping_enablement_unproven"
    and repeated[5].generation == first[5].generation
    and repeated[6].generation == first[6].generation,
    "identical production observations keep independent provider generations stable")
  local changed_aux = { talk_grant = {
      complete = true, wanted = { 29 }, events = {} },
    forgery = forgery_observation }
  local changed = a.objective_item_source_snapshots(nil, { need_generation = 3 }, nil, nil, changed_aux)
  assert(changed[5].generation == first[5].generation + 1
    and changed[5].status == "ok" and #changed[5].candidates == 0
    and changed[6].generation == first[6].generation,
    "a changed talk observation advances only talk generation and leaves no stale candidate")
end

-- Native catalog readers reconcile bounded managed collections atomically and
-- retain only plain diagnostic values (never managed-object references).
do
  assert(type(A.read_objective_talk_grant_observation) == "function",
    "talk-grant native observation reader is exported")
  assert(type(A.read_objective_forgery_observation) == "function",
    "forgery native observation reader is exported")
  local function managed(fields, calls, name)
    local object = { fields = fields or {}, calls = calls or {} }
    function object.get_field(_, key) return object.fields[key] end
    function object.call(_, method, ...)
      local value = object.calls[method]
      if type(value) == "function" then return value(...) end
      return value
    end
    function object.get_type_definition()
      return { get_full_name = function() return name end }
    end
    function object.get_address()
      local address = object.calls.get_address
      return type(address) == "function" and address() or address
    end
    return object
  end
  local function managed_list(values, count)
    return managed({}, { get_Count = count or #values,
      get_Item = function(index) return values[index + 1] end })
  end
  local function managed_array(values)
    return { get_elements = function() return values end,
      call = function(_, method)
        if method == "get_size" then return #values end
      end }
  end
  local function managed_dict(rows, expected, counter)
    local entries, by_key = {}, {}
    for index, row in ipairs(rows) do
      entries[index] = managed({ Next = -1, Key = row[1], Value = row[2] })
      by_key[row[1]] = row[2]
    end
    local array = { get_elements = function() return entries end }
    return managed({ _count = #entries, _freeCount = 0, _entries = array },
      { get_Item = function(key) return by_key[key] end,
        get_Count = function()
        if counter ~= nil then counter.reads = counter.reads + 1 end
        return expected or #entries
      end })
  end
  local grant = managed({ _ItemId = 29, _Num = 2 })
  local edge_conditions = managed({ _ConditionList = managed_array({}) })
  local edge = managed({ _NextNodeId = "grant", _NextNodeNameHash = 11,
    _Conditions = edge_conditions })
  local start = managed({ _NodeId = "start", _NodeNameHash = 10,
    _NextNodesCandidates = managed_array({ edge }) }, nil, "app.RootSegmentNode")
  local grant_node = managed({ _NodeId = "grant", _NodeNameHash = 11,
    _NextNodesCandidates = managed_array({}), _ChangeType = 0,
    _Items = managed_array({ grant }) }, nil, "app.ItemControlSegmentNode")
  local reward_end = managed({ _NodeId = "reward-end", _NodeNameHash = 13,
    _Result = 0, _IsKeepPreviousResult = false,
    _NextNodesCandidates = managed_array({}) }, nil, "app.EndSegmentNode")
  local reward_choice = managed({ _NextNodeId = "reward-end", _NextNodeNameHash = 13,
    _Conditions = edge_conditions })
  local reward_root = managed({ _NodeId = "reward-root", _NodeNameHash = 12,
    _NextNodesCandidates = managed_array({}),
    _Choices = managed_array({ reward_choice }) }, nil, "app.ChoiceSegmentNode")
  local absent_root = managed({ _NodeId = "absent-root", _NodeNameHash = 14,
    _NextNodesCandidates = managed_array({}) }, nil, "app.RootSegmentNode")
  local event_data = managed({ _SegmentNodes = managed_array({ start, grant_node }) }, {
    get_address = function() return 0x190000 end })
  local event_ref = managed({ _Item = event_data })
  local reward_event_data = managed({ _SegmentNodes = managed_array({ reward_root, reward_end }) }, {
    get_address = function() return 0x190100 end })
  local reward_event_ref = managed({ _Item = reward_event_data })
  local absent_event_ref = managed({ _Item = managed({
    _SegmentNodes = managed_array({ absent_root }) }, { get_address = function() return 0x190200 end }) })
  local talk_reads, shop_reads, mapping_reads = { reads = 0 }, { reads = 0 }, { reads = 0 }
  local talk_dict = managed_dict({ { 1900, event_ref }, { 1901, reward_event_ref },
    { 1902, absent_event_ref }, { 1903, absent_event_ref }, { 1904, absent_event_ref } }, nil, talk_reads)
  local character_data = managed({}, {}, "app.CharacterData")
  local blackboard = managed({}, {}, "app.AIBlackBoardController")
  local speaker = managed({}, {
    get_AIBlackBoardController = function() return blackboard end,
    get_UniversalPosition = function() return { x = 10, y = 20, z = 30 } end,
  }, "app.Character")
  local speaker_holder = managed({ CharaID = 3472286413, _chara = speaker }, {
    get_chara = function() return speaker end,
    get_UniversalPosition = function() return { x = 10, y = 20, z = 30 } end,
  }, "app.NPCHolder")
  local holder_dict = managed({}, { get_Item = function(chara_id)
    return chara_id == 3472286413 and speaker_holder or nil
  end })
  local npc_manager = managed({ NPCHolderDic = holder_dict }, {
    getNPCCharacterData = function(chara_id)
      return chara_id == 3472286413 and character_data or nil
    end,
  })
  local talk_manager = managed({ _ResourceCatalog = managed({
      ["<MergedCatalog>k__BackingField"] = talk_dict }),
      _PlayingEventIDList = managed_list({}) }, {
    getTalkEventInitialSpeaker = function(event_id)
      return event_id == 1900 and 3472286413 or nil
    end,
    isEventPlayable = function(event_id) return event_id == 1900 end,
    getHistory = function() return nil end,
    canTalkEventInteract = function() return false end,
  })
  local service = managed({ _CharaID = 3472286413, _ShopID = 25 }, nil,
    "app.NpcShopForgeryParam")
  local shop_data = managed({ _TalkEventID = 1919,
    _CharacterShopData = managed_list({ service }) })
  local shop_dict = managed_dict({ { 94, shop_data } }, nil, shop_reads)
  talk_manager.fields._ShopTalkEventDataCatalog = shop_dict
  local mapping = managed({ _Id = 11, _FakeItemId = 29, _FakePrice = 6 }, {
      get_IsEnableFake = function() return true end },
    "app.ItemDataParam")
  local mapping_other = managed({ _Id = 12, _FakeItemId = 30, _FakePrice = 7 }, {
      get_IsEnableFake = function() return true end },
    "app.ItemDataParam")
  local item_manager = managed({ _ItemDataDict = managed_dict({ { 11, mapping },
      { 12, mapping_other } }, nil,
      mapping_reads) }, {
    get__Golden = function() return 10 end,
    get_FakeShopKeepedItem = function() return managed({ _ItemId = 0, _Num = 0 }) end,
    get_FakeShopCompleteTime = function() return 0 end,
    isFakeShopKeeped = function() return false end,
    isFakeShopCompleted = function() return false end,
    isFakeShopRemainingMinute = function() return 0 end,
  })
  talk_manager.calls.getTalkEventInitialSpeaker = function(event_id)
    if event_id == 1904 then return -1 end
    if event_id == 1903 then return 1 end
    return (event_id == 1900 or event_id == 1901 or event_id == 1919)
      and 3472286413 or nil
  end
  talk_manager.calls.isEventPlayable = function(event_id)
    return event_id == 1900 or event_id == 1901 or event_id == 1902
      or event_id == 1903 or event_id == 1904 or event_id == 1919
  end
  local reward_history = managed({ Played = false, ResultNum = 0 })
  talk_manager.calls.getHistory = function(event_id)
    return event_id == 1901 and reward_history or nil
  end
  talk_manager.calls.isTalkEventInteractDisabled = function(chara_id)
    return chara_id ~= 3472286413
  end
  talk_manager.calls.isShopTalkEventAvailableForChara = function(data, board)
    return data == character_data and board == blackboard
  end
  local original_singleton = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(name)
    if name == "app.TalkEventManager" then return talk_manager end
    if name == "app.ItemManager" then return item_manager end
    if name == "app.NPCManager" then return npc_manager end
    return nil
  end
  local no_talk_need = A.read_objective_talk_grant_observation({})
  local no_forgery_need = A.read_objective_forgery_observation({})
  assert(no_talk_need.complete and no_forgery_need.complete
    and talk_reads.reads == 0 and shop_reads.reads == 0 and mapping_reads.reads == 0,
    "no focused item need performs no provider catalog or live scan")
  local forgery_registry_read = A.read_objective_forgery_observation({}, true)
  assert(forgery_registry_read.complete and #forgery_registry_read.wanted == 2
      and forgery_registry_read.wanted[1] == 29
      and forgery_registry_read.wanted[2] == 30
      and #forgery_registry_read.mappings == 2
      and forgery_registry_read.mappings[1].output_item_id == 29,
    "shared source registry discovers all bounded forgery outputs independent of query")
  ;(function()
    local registry_adapter = A.make()
    registry_adapter.item_name = function(item_id)
      return item_id == 29 and "Needle Forgery Output" or "Unrelated Forgery Output"
    end
    local providers = registry_adapter.objective_source_registry({ status = "ok",
      complete = true, placements = {}, chests = {} }, { version = 2, quests = {} },
      {}, "needle forgery")
    local forgery
    for _, provider in ipairs(providers) do
      if provider.provider == "forgery" then forgery = provider; break end
    end
    assert(forgery and forgery.status == "ok" and forgery.complete
        and #forgery.source_status.rows == 1
        and forgery.source_status.rows[1].item_ids[1] == 29,
      "source registry filters forgery mappings by the explicit item query before live classification")
  end)()
  ;(function()
    local registry_read = A.read_objective_talk_grant_observation({}, nil, true)
    assert(registry_read.complete and #registry_read.wanted == 1
        and registry_read.wanted[1] == 29
        and #registry_read.events == 1
        and registry_read.events[1].event_id == 1900,
      "shared source registry discovers all bounded talk-grant outputs independent of query")
  end)()
  local talk_read = A.read_objective_talk_grant_observation({ [29] = true })
  assert(talk_read.complete and #talk_read.wanted == 1 and talk_read.wanted[1] == 29
    and #talk_read.events == 1 and talk_read.events[1].event_id == 1900
    and #talk_read.events[1].nodes == 2
    and talk_read.events[1].nodes[1].edges[1].next_node_id == "grant"
    and talk_read.events[1].nodes[1].edges[1].condition_count == 0
    and talk_read.events[1].nodes[2].grants[1].item_id == 29
    and talk_read.events[1].nodes[2].grants[1].count == 2
    and talk_read.events[1].speaker_cid == 3472286413
    and talk_read.events[1].speaker_position.x == 10
    and talk_read.events[1].playing == false
    and talk_read.events[1].interaction_readable
    and talk_read.events[1].interaction_enabled,
    "talk reader scans the typed graph and current numeric-speaker gates")
  local exact_reward_event = A.read_objective_talk_grant_observation({}, { 1901 })
  assert(exact_reward_event.complete and #exact_reward_event.events == 1
    and exact_reward_event.events[1].event_id == 1901
    and exact_reward_event.events[1].root_node_id == "reward-root"
    and exact_reward_event.events[1].reward_nodes[1].choices[1].to_node_id == "reward-end"
    and exact_reward_event.events[1].reward_nodes[2].node_type == "End"
    and exact_reward_event.events[1].reward_nodes[2].end_result == 0
    and exact_reward_event.events[1].reward_nodes[2].keep_previous_result == false
    and exact_reward_event.events[1].owner_token == "190100"
    and exact_reward_event.events[1].speaker.interaction_disabled == false
    and exact_reward_event.events[1].speaker.interaction_allowed == false
    and exact_reward_event.events[1].history.played_readable
    and exact_reward_event.events[1].history.played == false,
    "exact event-ID mode reads graph choices, End fields, owner identity and false overlays")
  local destination_number = { task_index = 1, destination_index = 2, kind = "place",
    target = { key = 7, place = { kind = "key_location", key = 8, local_area = 0 } } }
  local destination_string = { task_index = 1, destination_index = 2, kind = "place",
    target = { key = "7", place = { kind = "key_location", key = 8, local_area = 0 } } }
  assert(A.objective_destination_signature({ destination_number })
      ~= A.objective_destination_signature({ destination_string }),
    "destination identity encoding preserves numeric versus string place keys")
  local many_destinations = {}
  for i = 1, 30 do
    many_destinations[i] = { task_index = 1, destination_index = i, kind = "place",
      target = { key = i, place = { kind = "key_location", key = 100 + i, local_area = 0 } } }
  end
  local many_signature = A.objective_destination_signature(many_destinations)
  local reordered_destinations = {}
  for i = 1, #many_destinations do
    reordered_destinations[i] = many_destinations[#many_destinations - i + 1]
  end
  assert(type(many_signature) == "string"
      and many_signature == A.objective_destination_signature(reordered_destinations),
    "destination identity remains canonical beyond the target tuple component cap")
  many_destinations[30].target.place.key = 999
  assert(many_signature ~= A.objective_destination_signature(many_destinations),
    "length-prefixed destination identity detects a changed member beyond the tuple cap")
  local sparse_destinations = { destination_number }
  sparse_destinations[3] = destination_string
  assert(A.objective_destination_signature(sparse_destinations) == nil,
    "destination identity rejects sparse arrays instead of ignoring later rows")
  local too_many_reward_events = {}
  for i = 1, 65 do too_many_reward_events[i] = 1900 + i end
  local over_cap_events = A.read_objective_talk_grant_observation({}, too_many_reward_events)
  assert(not over_cap_events.complete and over_cap_events.reason == "talk_grant_event_ids_truncated"
    and #over_cap_events.events == 0,
    "talk reader rejects 65 requested event IDs before catalog preflight")
  local absent_speaker_event = A.read_objective_talk_grant_observation({}, { 1902 })
  assert(absent_speaker_event.complete and #absent_speaker_event.events == 1
    and absent_speaker_event.events[1].initial_speaker_readable
    and absent_speaker_event.events[1].initial_speaker_cid == nil
    and absent_speaker_event.events[1].speaker_present_readable
    and absent_speaker_event.events[1].speaker_present == false
    and absent_speaker_event.events[1].speaker == nil,
    "a successful absent initial-speaker read remains distinct from a failed call")
  local missing_holder_event = A.read_objective_talk_grant_observation({}, { 1903 })
  assert(missing_holder_event.complete and #missing_holder_event.events == 1
    and missing_holder_event.events[1].initial_speaker_cid == 1
    and missing_holder_event.events[1].speaker_present_readable
    and missing_holder_event.events[1].speaker_present == false
    and missing_holder_event.events[1].speaker == nil,
    "a readable absent NPC holder remains false and keeps its speaker nil")
  local malformed_speaker_event = A.read_objective_talk_grant_observation({}, { 1904 })
  assert(malformed_speaker_event.complete and #malformed_speaker_event.events == 1
    and malformed_speaker_event.events[1].initial_speaker_readable == false
    and malformed_speaker_event.events[1].initial_speaker_cid == nil,
    "a successful malformed speaker value is unreadable instead of native absence")
  local saved_interaction_disabled = talk_manager.calls.isTalkEventInteractDisabled
  talk_manager.calls.isTalkEventInteractDisabled = function() return true end
  local disabled_talk = A.read_objective_talk_grant_observation({ [29] = true })
  assert(disabled_talk.events[1].interaction_readable
    and disabled_talk.events[1].interaction_enabled == false,
    "a readable disabled interaction remains a negative Boolean gate")
  talk_manager.calls.isTalkEventInteractDisabled = saved_interaction_disabled
  local forgery_read = A.read_objective_forgery_observation({ [29] = true })
  assert(forgery_read.complete and #forgery_read.wanted == 1
    and #forgery_read.services == 1
    and forgery_read.services[1].service_type == "app.NpcShopForgeryParam"
    and forgery_read.services[1].talk_event_id == 1919
    and forgery_read.services[1].chara_id == 3472286413
    and forgery_read.services[1].speaker_cid == 3472286413
    and forgery_read.services[1].speaker_matches_service
    and forgery_read.services[1].availability_readable
    and forgery_read.services[1].available
    and forgery_read.services[1].interaction_disabled == false
    and #forgery_read.mappings == 1
    and forgery_read.mappings[1].input_item_id == 11
    and forgery_read.mappings[1].output_item_id == 29
    and forgery_read.mappings[1].enabled_readable
    and forgery_read.mappings[1].enabled == true
    and forgery_read.mappings[1].held_readable == false
    and forgery_read.mappings[1].price_readable == true
    and forgery_read.mappings[1].affordable == true
    and forgery_read.mappings[1].available_gold == 10
    and forgery_read.order.kept_readable and forgery_read.order.kept_item_id == 0
    and forgery_read.order.kept_state_readable
    and forgery_read.order.kept_active == false
    and forgery_read.order.completion_time_readable
    and forgery_read.order.completed_readable
    and forgery_read.order.remaining_minutes_readable
    and forgery_read.order.remaining_minutes == 0,
    "forgery reader joins typed service, live affordability, mapping and exact raw order getters")
  local saved_gold = item_manager.calls.get__Golden
  item_manager.calls.get__Golden = function() return math.huge end
  local nonfinite_gold = A.read_objective_forgery_observation({ [29] = true })
  assert(nonfinite_gold.complete and nonfinite_gold.mappings[1].price_readable == false
      and nonfinite_gold.mappings[1].affordable == nil
      and nonfinite_gold.mappings[1].available_gold == nil,
    "non-finite currency evidence remains unreadable and cannot grant eligibility")
  item_manager.calls.get__Golden = saved_gold
  local saved_kept = item_manager.calls.get_FakeShopKeepedItem
  local saved_time = item_manager.calls.get_FakeShopCompleteTime
  local saved_kept_state = item_manager.calls.isFakeShopKeeped
  local saved_completed = item_manager.calls.isFakeShopCompleted
  local saved_remaining = item_manager.calls.isFakeShopRemainingMinute
  item_manager.calls.get_FakeShopKeepedItem = function() return nil end
  item_manager.calls.get_FakeShopCompleteTime = function() return nil end
  item_manager.calls.isFakeShopKeeped = function() return nil end
  item_manager.calls.isFakeShopCompleted = function() return nil end
  item_manager.calls.isFakeShopRemainingMinute = function() return nil end
  local unreadable_order = A.read_objective_forgery_observation({ [29] = true })
  assert(not unreadable_order.order.kept_readable
    and not unreadable_order.order.completion_time_readable
    and not unreadable_order.order.kept_state_readable
    and not unreadable_order.order.completed_readable
    and not unreadable_order.order.remaining_minutes_readable,
    "every raw forgery order seam keeps an independent unreadable flag")
  item_manager.calls.get_FakeShopKeepedItem = saved_kept
  item_manager.calls.get_FakeShopCompleteTime = saved_time
  item_manager.calls.isFakeShopKeeped = saved_kept_state
  item_manager.calls.isFakeShopCompleted = saved_completed
  item_manager.calls.isFakeShopRemainingMinute = saved_remaining
  local saved_initial_speaker = talk_manager.calls.getTalkEventInitialSpeaker
  talk_manager.calls.getTalkEventInitialSpeaker = function(event_id)
    return event_id == 1900 and 3472286413 or 1
  end
  local wrong_speaker = A.read_objective_forgery_observation({ [29] = true })
  assert(wrong_speaker.services[1].speaker_cid == 1
    and not wrong_speaker.services[1].speaker_matches_service
    and wrong_speaker.services[1].join_reason == "forgery_service_speaker_join_unproven"
    and not wrong_speaker.services[1].availability_readable,
    "forgery service target rejects a structured speaker CID mismatch")
  talk_manager.calls.getTalkEventInitialSpeaker = saved_initial_speaker
  local cached_talk_reads, cached_shop_reads, cached_mapping_reads =
    talk_reads.reads, shop_reads.reads, mapping_reads.reads
  A.read_objective_talk_grant_observation({ [29] = true })
  A.read_objective_forgery_observation({ [29] = true })
  assert(talk_reads.reads == cached_talk_reads
    and shop_reads.reads == cached_shop_reads
    and mapping_reads.reads == cached_mapping_reads,
    "static provider catalogs are built once while focused live gates refresh")
  assert(type(A.invalidate_objective_provider_catalogs) == "function",
    "provider catalog invalidation is exported")
  A.invalidate_objective_provider_catalogs()
  event_data.fields._SegmentNodes = managed_array({ [1] = start, [3] = grant_node })
  local sparse = A.read_objective_talk_grant_observation({ [29] = true })
  assert(not sparse.complete and sparse.reason == "talk_grant_nodes_unreadable"
    and #sparse.events == 0,
    "a sparse managed array fails atomically instead of compacting holes")
  A.invalidate_objective_provider_catalogs()
  event_data.fields._SegmentNodes = managed_list({ start, grant_node }, 1025)
  local truncated = A.read_objective_talk_grant_observation({ [29] = true })
  assert(not truncated.complete and truncated.reason == "talk_grant_nodes_truncated"
    and #truncated.events == 0,
    "an over-limit talk graph fails atomically without partial rows")
  sdk.get_managed_singleton = original_singleton
end
local empty_source_snapshots = a.objective_item_source_snapshots()
assert(type(a.objective_forgery_evidence) == "function"
  and a.objective_forgery_candidate == nil, "forgery helper must be evidence-only")
assert(#empty_source_snapshots == 6 and empty_source_snapshots[1].provider == "placed"
  and empty_source_snapshots[2].provider == "chest" and empty_source_snapshots[3].provider == "loot"
  and empty_source_snapshots[1].status == "unknown"
  and empty_source_snapshots[1].complete == false
  and empty_source_snapshots[1].reason == "source_catalog_unavailable"
  and empty_source_snapshots[2].complete == false
  and empty_source_snapshots[2].reason == "source_catalog_unavailable"
  and empty_source_snapshots[4].provider == "reward"
  and empty_source_snapshots[4].status == "unknown"
  and empty_source_snapshots[4].complete == false
  and type(empty_source_snapshots[4].reason) == "string"
  and #empty_source_snapshots[4].candidates == 0
  and empty_source_snapshots[5].provider == "talk_grant"
  and empty_source_snapshots[5].status == "unknown"
  and empty_source_snapshots[5].complete == false
  and empty_source_snapshots[5].reason == "objective_need_snapshot_incomplete"
  and #empty_source_snapshots[5].candidates == 0
  and empty_source_snapshots[5].generation > 0
  and empty_source_snapshots[6].provider == "forgery"
  and empty_source_snapshots[6].status == "unknown"
  and empty_source_snapshots[6].complete == false
  and empty_source_snapshots[6].reason == "objective_need_snapshot_incomplete"
  and #empty_source_snapshots[6].candidates == 0
  and empty_source_snapshots[6].generation > 0
  and empty_source_snapshots[1].generation > 0
  and empty_source_snapshots[2].generation > 0 and empty_source_snapshots[3].generation > 0,
  "source envelopes initialize with separate positive generations: "
    .. tostring(#empty_source_snapshots) .. "/"
    .. tostring(empty_source_snapshots[2] and empty_source_snapshots[2].reason) .. "/"
    .. tostring(empty_source_snapshots[4] and empty_source_snapshots[4].reason) .. "/"
    .. tostring(empty_source_snapshots[5] and empty_source_snapshots[5].reason) .. "/"
    .. tostring(empty_source_snapshots[6] and empty_source_snapshots[6].reason))

-- Pickup/chest classification is pure over one complete static catalog and
-- one atomic adapter observation.  The live reader feeds this same contract.
do
  assert(type(A.objective_source_provider_snapshots) == "function",
    "pickup/chest provider classifier is exported")
  local function base_catalog()
    return { version = 2, status = "ok", complete = true, generation = 3,
      placements = {
        { uid = "11111111-1111-1111-1111-111111111111", index = 0,
          table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", layer = 0,
          source_id = { "source", "placed", "11111111-1111-1111-1111-111111111111", 0 },
          capacity_pool_id = { "capacity", "placed", "11111111-1111-1111-1111-111111111111", 0 },
          outputs = { { item_id = 501, count = 2 } }, pos = { x = 1, y = 2, z = 3 } },
      }, chests = {
        { uid = "22222222-2222-2222-2222-222222222222", index = 0,
          table_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", layer = 0,
          source_id = { "source", "chest", "22222222-2222-2222-2222-222222222222", 0 },
          capacity_pool_id = { "capacity", "chest", "22222222-2222-2222-2222-222222222222", 0 },
          outputs = { { item_id = 601, count = 1 }, { item_id = 602, count = 3 } },
          pos = { x = 4, y = 5, z = 6 }, unlock_item = 0, is_seal = false,
          fake_unlock_item = 0, quest_override = false },
      } }
  end
  local function base_observation()
    return { complete = true, persisted_complete = true, generation_complete = true,
      requested_complete = true, loaded_complete = true,
      persisted = {}, never = {}, dead = {}, disabled_tables = {}, blacklist = {},
      requested_tables = {}, loaded = {}, gate_results = {} }
  end
  local function classify(catalog, observation, generation)
    local rows = A.objective_source_provider_snapshots(catalog, observation, generation or 7)
    return rows[1], rows[2]
  end
  local placed, chest = classify(base_catalog(), base_observation())
  assert(placed.status == "unknown" and placed.complete == false
    and placed.reason == "placed_current_state_unproven" and #placed.candidates == 0,
    "placed provider fails closed when persisted and loaded state are both absent")
  assert(chest.status == "unknown" and chest.complete == false
    and chest.reason == "chest_current_state_unproven" and #chest.candidates == 0,
    "chest provider fails closed when persisted and loaded state are both absent")

  local available = base_observation()
  available.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 0 }
  available.persisted["22222222-2222-2222-2222-222222222222:0"] =
    { family = "chest", pick = false, keep = false, unlock = false, seal = false }
  placed, chest = classify(base_catalog(), available)
  assert(placed.status == "ok" and placed.complete == true and #placed.candidates == 1
    and placed.candidates[1].generation == 7 and placed.candidates[1].provider == "placed"
    and placed.candidates[1].target.uid == "11111111-1111-1111-1111-111111111111"
    and placed.candidates[1].outputs[1].item_id == 501
    and placed.candidates[1].outputs[1].count == 2,
    "placed provider accepts exact persisted evidence of an uncollected source")
  assert(placed.source_status.complete and #placed.source_status.rows == 1
      and placed.source_status.rows[1].state == "available"
      and placed.source_status.rows[1].item_ids[1] == 501,
    "pickup view status retains an available source row")
  assert(chest.status == "ok" and chest.complete == true and #chest.candidates == 1
    and #chest.candidates[1].outputs == 2
    and chest.candidates[1].outputs[2].item_id == 602
    and chest.candidates[1].outputs[2].count == 3,
    "chest provider preserves exact multi-item outputs")

  local collected = base_observation()
  collected.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 3 }
  placed = classify(base_catalog(), collected)
  assert(placed.status == "ok" and #placed.candidates == 0
      and placed.source_status.complete and #placed.source_status.rows == 1
      and placed.source_status.rows[1].state == "unavailable"
      and placed.source_status.rows[1].reason_code == "pickup_collected",
    "pickup free bits remove routing but retain a collected browser row")
  local opened = base_observation()
  opened.persisted["22222222-2222-2222-2222-222222222222:0"] =
    { family = "chest", pick = true, keep = false, unlock = false, seal = false }
  _, chest = classify(base_catalog(), opened)
  assert(chest.status == "ok" and #chest.candidates == 0
      and chest.source_status.complete and #chest.source_status.rows == 1
      and chest.source_status.rows[1].state == "unavailable"
      and chest.source_status.rows[1].reason_code == "chest_opened",
    "chest Pick/opened removes routing but retains an opened browser row")
  local unopened_keep = base_observation()
  unopened_keep.persisted["22222222-2222-2222-2222-222222222222:0"] =
    { family = "chest", pick = false, keep = true, unlock = false, seal = false }
  _, chest = classify(base_catalog(), unopened_keep)
  assert(chest.status == "ok" and #chest.candidates == 1,
    "chest Keep and Unlock false do not remove an unopened zero-key source")

  local live = base_observation()
  live.loaded["11111111-1111-1111-1111-111111111111:0"] = {
    family = "placed", table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    generated = true, disabled = false, freebit = 0, broken = false, used = false }
  live.loaded["22222222-2222-2222-2222-222222222222:0"] = {
    family = "chest", table_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    generated = true, disabled = false, pick = false, keep = false, unlock = false,
    opened = false, unlock_api = false, seal = false, unlock_item = 0,
    fake_unlock_item = 0, pawn_restrict = true }
  placed, chest = classify(base_catalog(), live, 9)
  assert(#placed.candidates == 1 and #chest.candidates == 1
    and placed.candidates[1].generation == 9 and chest.candidates[1].generation == 9,
    "exact loaded/catalog joins publish one stable generation")
  live.loaded["22222222-2222-2222-2222-222222222222:0"].opened = true
  placed, chest = classify(base_catalog(), live, 10)
  assert(placed.status == "ok" and #placed.candidates == 1
    and chest.status == "unknown" and chest.complete == false and #chest.candidates == 0
    and chest.reason == "chest_loaded_state_inconsistent",
    "one family inconsistency fails closed without stale candidates")

  local wrong_join = base_observation()
  wrong_join.loaded["11111111-1111-1111-1111-111111111111:0"] = {
    family = "placed", table_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    generated = true, disabled = false, freebit = 0, broken = false, used = false }
  placed = classify(base_catalog(), wrong_join)
  assert(placed.status == "unknown" and #placed.candidates == 0
    and placed.reason == "placed_loaded_identity_unreadable",
    "a negative loaded UID/table join invalidates the placed observation")
  local wrong_persisted = base_observation()
  wrong_persisted.persisted["11111111-1111-1111-1111-111111111111:0"] = {
    family = "chest", pick = false, keep = false, unlock = false }
  placed = classify(base_catalog(), wrong_persisted)
  assert(placed.status == "unknown" and #placed.candidates == 0,
    "a negative persisted UID/family join fails closed")
  for _, exclusion in ipairs({ "never", "dead" }) do
    local excluded = base_observation()
    excluded[exclusion]["11111111-1111-1111-1111-111111111111:0"] = true
    placed = classify(base_catalog(), excluded)
    assert(placed.status == "ok" and #placed.candidates == 0,
      "full-UID " .. exclusion .. " exclusion removes a pickup")
  end
  local excluded = base_observation()
  excluded.blacklist["22222222-2222-2222-2222-222222222222"] = true
  _, chest = classify(base_catalog(), excluded)
  assert(chest.status == "ok" and #chest.candidates == 0,
    "bare-GUID blacklist removes a chest")
  excluded = base_observation()
  excluded.disabled_tables["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] = true
  placed = classify(base_catalog(), excluded)
  assert(placed.status == "ok" and #placed.candidates == 0,
    "disabled table removes its pickup")
  local removed_live = base_observation()
  removed_live.loaded["11111111-1111-1111-1111-111111111111:0"] = {
    family = "placed", table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    generated = true, disabled = false, freebit = 0, broken = true, used = false }
  removed_live.loaded["22222222-2222-2222-2222-222222222222:0"] = {
    family = "chest", table_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    generated = true, disabled = false, pick = true, keep = false, unlock = false,
    opened = true, unlock_api = false, unlock_item = 0, fake_unlock_item = 0,
    pawn_restrict = false }
  placed, chest = classify(base_catalog(), removed_live)
  assert(placed.status == "ok" and chest.status == "ok"
    and #placed.candidates == 0 and #chest.candidates == 0,
    "loaded broken pickup and opened chest are removed without stale candidates")

  local duplicate_catalog = base_catalog()
  duplicate_catalog.chests[1].uid = duplicate_catalog.placements[1].uid
  placed, chest = classify(duplicate_catalog, base_observation())
  assert(placed.status == "unknown" and chest.status == "unknown"
    and placed.reason == "source_catalog_identity_duplicate",
    "cross-family duplicate native identity invalidates both providers")

  local gated_catalog = base_catalog()
  gated_catalog.placements[1].gate = { check = 0, conditions = {
    { kind = "quest", qid = 20040, finish = true } } }
  local gated = base_observation()
  gated.gate_results["placed:11111111-1111-1111-1111-111111111111:0"] = false
  placed = classify(gated_catalog, gated)
  assert(placed.status == "ok" and #placed.candidates == 0,
    "a proven false structured row gate removes the source")
  gated.gate_results = {}
  placed = classify(gated_catalog, gated)
  assert(placed.status == "unknown" and #placed.candidates == 0
    and placed.reason == "placed_gate_state_unreadable",
    "an unreadable structured gate makes the provider unknown")

  local subquest_catalog = base_catalog()
  subquest_catalog.placements[1].layer = 2
  local requested = base_observation()
  requested.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 0 }
  requested.requested_tables["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] = {
    active = true, failed = false, finished = true,
    uids = { ["11111111-1111-1111-1111-111111111111:0"] = true } }
  placed = classify(subquest_catalog, requested)
  assert(placed.status == "ok" and #placed.candidates == 1,
    "active complete requested subquest table admits its exact UID")
  local mainquest_catalog = base_catalog()
  mainquest_catalog.placements[1].layer = 3
  placed = classify(mainquest_catalog, requested)
  assert(placed.status == "ok" and #placed.candidates == 1,
    "active complete requested mainquest table admits its exact UID")
  requested.requested_tables["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"].uids = {}
  placed = classify(subquest_catalog, requested)
  assert(placed.status == "ok" and #placed.candidates == 0,
    "subquest table without exact UID is ineligible")
  requested.requested_tables["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"].finished = nil
  placed = classify(subquest_catalog, requested)
  assert(placed.status == "unknown" and #placed.candidates == 0,
    "partial subquest request fails closed")

  local partial = base_observation()
  partial.persisted_complete = false
  placed, chest = classify(base_catalog(), partial)
  assert(placed.status == "unknown" and chest.status == "unknown"
    and #placed.candidates == 0 and #chest.candidates == 0,
    "an incomplete shared sparse scan invalidates both providers atomically")
  local future_access = base_catalog()
  future_access.chests[1].unlock_item = 77
  _, chest = classify(future_access, base_observation())
  assert(chest.status == "unknown" and #chest.candidates == 0
    and chest.reason == "chest_access_domain_unmodeled",
    "future keyed chest access stays unknown")

  local broad_catalog, broad_observation = base_catalog(), base_observation()
  broad_catalog.placements = {}
  broad_catalog.chests = {}
  for i = 1, 513 do
    local uid = string.format("%08x-0000-0000-0000-%012x", i, i)
    broad_catalog.placements[i] = { uid = uid, index = 0,
      table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", layer = 0,
      outputs = { { item_id = 501, count = 1 } }, pos = { x = i, y = 2, z = 3 } }
    broad_observation.persisted[uid .. ":0"] = { family = "placed", freebit = 0 }
  end
  local broad = A.objective_source_provider_snapshots(broad_catalog,
    broad_observation, 11, { 501 })[1]
  assert(broad.status == "ok" and broad.complete == true
      and broad.reason == nil and #broad.candidates == 513
      and broad.source_status.complete == false
      and broad.source_status.reason_code == "placed_status_overflow"
      and #broad.source_status.rows == 1
      and broad.source_status.rows[1].identity == "provider:placed",
    "a 513-row status overflow preserves candidates and degrades only its envelope")

  local world_mod = require("Clairvoyance.world")
  local integrated_rows = {
    { k = "item", uid = "11111111-1111-1111-1111-111111111111", index = 0,
      table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", layer = 0,
      id = 501, n = 2, x = 1, y = 2, z = 3, src = "normal" },
    { k = "chest", uid = "22222222-2222-2222-2222-222222222222", index = 0,
      table_id = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", layer = 0,
      id = 10, x = 4, y = 5, z = 6, src = "normal",
      unlock_item = 0, is_seal = false, fake_unlock_item = 0, quest_override = false,
      items = { { id = 601, n = 1 }, { id = 602, n = 3 } } },
  }
  local integrated_world = world_mod.new(a, {}, {
    load = function(path)
      if path == world_mod.K.PLACES then
        return { version = 2, pak = "1:1", rows = integrated_rows }
      end
    end,
    dump = function() return true end,
    clock = function() return 0 end,
  })
  local integrated_catalog = integrated_world:objective_static_source_catalog()
  local integrated_observation = base_observation()
  integrated_observation.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 0 }
  integrated_observation.persisted["22222222-2222-2222-2222-222222222222:0"] =
    { family = "chest", pick = false, keep = false, unlock = false, seal = false }
  local integrated_placed, integrated_chest = classify(integrated_catalog,
    integrated_observation, 12)
  assert(integrated_catalog.status == "ok" and integrated_placed.status == "ok"
    and integrated_chest.status == "ok" and #integrated_placed.candidates == 1
    and #integrated_chest.candidates == 1
    and integrated_placed.candidates[1].source_id[4] == 0
    and integrated_chest.candidates[1].outputs[2].item_id == 602,
    "generated world metadata reaches the real pickup/chest classifier")

  local wired_catalog, wired_observation = base_catalog(), base_observation()
  wired_observation.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 0 }
  wired_observation.persisted["22222222-2222-2222-2222-222222222222:0"] =
    { family = "chest", pick = false, keep = false, unlock = false, seal = false }
  local wired = a.objective_item_source_snapshots(nil, { need_generation = 11 },
    wired_catalog, wired_observation)
  local wired_repeat = a.objective_item_source_snapshots(nil, { need_generation = 11 },
    wired_catalog, wired_observation)
  assert(wired[1].status == "ok" and wired[2].status == "ok"
    and #wired[1].candidates == 1 and #wired[2].candidates == 1
    and wired_repeat[1].generation == wired[1].generation,
    "adapter provider API publishes and keeps an identical observation generation stable")
  wired_observation.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 3 }
  local wired_changed = a.objective_item_source_snapshots(nil, { need_generation = 11 },
    wired_catalog, wired_observation)
  assert(wired_changed[1].generation == wired[1].generation + 1
    and #wired_changed[1].candidates == 0 and #wired_changed[2].candidates == 1,
    "a changed atomic source observation advances generation and removes stale pickup")

  local focused_catalog, focused_observation = base_catalog(), base_observation()
  focused_catalog.placements[#focused_catalog.placements + 1] = {
    uid = "33333333-3333-3333-3333-333333333333", index = 0,
    table_id = "cccccccc-cccc-cccc-cccc-cccccccccccc", layer = 0,
    source_id = { "source", "placed", "33333333-3333-3333-3333-333333333333", 0 },
    capacity_pool_id = { "capacity", "placed", "33333333-3333-3333-3333-333333333333", 0 },
    outputs = { { item_id = 999, count = 1 } }, pos = { x = 7, y = 8, z = 9 },
  }
  focused_observation.persisted["11111111-1111-1111-1111-111111111111:0"] =
    { family = "placed", freebit = 0 }
  local saved_need_groups = a.objective_need_groups
  a.objective_need_groups = function()
    return { status = "ok", complete = true, generation = 12, groups = {
      { qid = 20090, task_index = 0, remaining = 1,
        options = { { item_id = 501, accepted_count = 1 } } },
    } }
  end
  local focused = a.objective_item_source_snapshots(nil,
    { need_generation = 12, quests = {} }, focused_catalog, focused_observation)
  a.objective_need_groups = saved_need_groups
  assert(focused[1].status == "ok" and focused[1].complete
    and #focused[1].candidates == 1
    and focused[1].candidates[1].outputs[1].item_id == 501,
    "an unrelated unproved pickup cannot suppress a proven current-needed pickup")

  local saved_source_reader, saved_source_clock = A.read_objective_source_observation, os.clock
  local scan_count, scanned_catalogs, fake_now = 0, {}, 100
  A.read_objective_source_observation = function(catalog)
    scan_count = scan_count + 1
    scanned_catalogs[#scanned_catalogs + 1] = catalog
    return base_observation()
  end
  os.clock = function() return fake_now end
  local cache_adapter, cache_catalog = A.make(), base_catalog()
  cache_adapter.objective_need_groups = function()
    return { status = "ok", complete = true, generation = 1, groups = {
      { qid = 20090, task_index = 0, remaining = 1,
        options = { { item_id = 501, accepted_count = 1 } } },
    } }
  end
  cache_adapter.objective_item_source_snapshots(nil, { need_generation = 1 }, cache_catalog)
  fake_now = 100.4
  cache_adapter.objective_item_source_snapshots(nil, { need_generation = 1 }, cache_catalog)
  fake_now = 100.8
  cache_adapter.objective_item_source_snapshots(nil, { need_generation = 1 }, cache_catalog)
  assert(scan_count == 1,
    "stable current needs reuse the complete source observation across tick cadence")
  cache_adapter.objective_item_source_snapshots(nil, { need_generation = 2 }, cache_catalog)
  A.read_objective_source_observation, os.clock = saved_source_reader, saved_source_clock
  assert(scan_count == 2,
    "a current-need generation change forces a complete source rescan")
  assert(scanned_catalogs[1] == scanned_catalogs[2],
    "need-driven rescans reuse the exact filtered static-catalog table")

  -- The native reader reconciles sparse persisted records and exact loaded
  -- identities before the pure classifier sees them.
  local function robj(fields, calls, name)
    local o = { fields = fields or {}, calls = calls or {} }
    function o.get_field(_, key) return o.fields[key] end
    function o.call(_, method, ...)
      local value = o.calls[method]
      if type(value) == "function" then return value(...) end
      return value
    end
    function o.get_type_definition()
      return { get_full_name = function() return name end }
    end
    return o
  end
  local function rlist(values, count)
    return robj({}, { get_Count = count or #values,
      get_Item = function(index) return values[index + 1] end })
  end
  local function rdict(rows)
    local entries = {}
    for i, row in ipairs(rows or {}) do
      entries[i] = robj({ Next = -1, Key = row[1], Value = row[2] })
    end
    local array = { get_elements = function() return entries end }
    return robj({ _count = #entries, _freeCount = 0, _entries = array },
      { get_Count = #entries })
  end
  local function rguid(text) return robj({}, { ["ToString()"] = text }) end
  local function ruid(text, index)
    return robj({ _RowID = rguid(text), _Index = index or 0 })
  end
  local function holder(contexts)
    local rows = {}
    for i, context in ipairs(contexts) do
      rows[i] = { i, robj({ ["<CurrentContext>k__BackingField"] = context }) }
    end
    return robj({ Contexts = rdict(rows), RestoredContexts = rdict({}) })
  end
  local scanner_catalog = base_catalog()
  local chest_uid = scanner_catalog.chests[1].uid
  local chest_item = robj({ _IsPick = false, _IsKeep = true, _IsUnlock = false }, nil,
    "app.GmItemContext")
  local chest_record = robj({ Contexts = rlist({
    robj({ UniqueID = ruid(chest_uid) }, nil, "app.UniqueIDContext"), chest_item,
  }) })
  local chest_record_info = robj({ ["<Record>k__BackingField"] = chest_record })
  local unrelated_uid = "33333333-3333-3333-3333-333333333333"
  local unrelated_record = robj({ Contexts = rlist({
    robj({ UniqueID = ruid(unrelated_uid, -7) }, nil, "app.UniqueIDContext"),
    robj({}, nil, "app.CharacterIDContext"),
  }) })
  local unrelated_record_info = robj({ ["<Record>k__BackingField"] = unrelated_record })
  local gen_context = robj({ _IsGenerated = true, _IsDisableGenerate = false }, nil,
    "app.GenerateInfoContext")
  local live_holder = holder({ gen_context, chest_item })
  local table_guid = rguid(scanner_catalog.chests[1].table_id)
  local generator_id = robj({ _TableID = table_guid })
  local common = robj({ _CustomGeneratorID = generator_id })
  local comp_generate = robj({ _Container = robj({ _CommonInfo = common }) })
  local live_chest = robj({ ["<UniqId>k__BackingField"] = ruid(chest_uid),
      ["<CompContext>k__BackingField"] = live_holder,
      ["<CompGenerateInfo>k__BackingField"] = comp_generate,
      ItemContext = chest_item, UnlockItem = 0, FakeUnlockItem = 0,
      _IsPawnRestrict = false },
    { get_IsOpenedFreeBit = false, get_IsUnlockFreeBit = false }, "app.gm80_001")
  local empty_set = function() return rdict({}) end
  local unrelated_table = "dddddddd-dddd-dddd-dddd-dddddddddddd"
  local unrelated_request = robj({ _IsFailedAllRequest = false,
    _IsFinishAllRequestForGenerateTable = true,
    _Requests = rdict({ { "character", ruid(unrelated_uid, -7) } }) })
  local generation_manager = robj({ _NeverGenetateID = empty_set(),
    _NeverGenerateIDByDeadRequests = empty_set(), _DisableGenerateRequests = empty_set(),
    _GenerateBlacklistUniqueIDHashSet = empty_set(), _RequestedTableInfos = rdict({ {
      robj({ _TableID = rguid(unrelated_table), _ExtraID = 0 }), unrelated_request } }) })
  local game_managers = {
    ["app.ContextDBMS"] = robj({ OfflineDB = robj({
      Records = rlist({ nil, unrelated_record_info, chest_record_info }, 3) }) }),
    ["app.GenerateManager"] = generation_manager,
    ["app.GimmickManager"] = robj({
      ["<ManagedGimmicksByIDs>k__BackingField"] = rdict({ { 80,
        rdict({ { chest_uid, live_chest } }) } }) }),
    ["app.QuestManager"] = robj(), ["app.QuestLogManager"] = robj(),
  }
  local saved_singleton = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(name) return game_managers[name] end
  local scanned = A.read_objective_source_observation(scanner_catalog)
  sdk.get_managed_singleton = saved_singleton
  assert(scanned.complete == true and scanned.persisted_complete == true
    and scanned.persisted[chest_uid .. ":0"].keep == true
    and scanned.loaded[chest_uid .. ":0"].table_id == scanner_catalog.chests[1].table_id
    and scanned.persisted[scanner_catalog.placements[1].uid .. ":0"] == nil,
    "native reader treats sparse nil slots and complete pickup absence exactly")
  placed, chest = classify(scanner_catalog, scanned)
  assert(placed.status == "unknown" and #placed.candidates == 0
    and placed.reason == "placed_current_state_unproven"
    and chest.status == "ok" and #chest.candidates == 1,
    "complete scanner absence is unknown while exact live/persisted chest joins publish: "
      .. tostring(placed.status) .. "/" .. tostring(#placed.candidates) .. "/"
      .. tostring(placed.reason) .. " chest " .. tostring(chest.status) .. "/"
      .. tostring(#chest.candidates) .. "/" .. tostring(chest.reason))
end
assert(type(a.reset_session_caches) == "function", "reset_session_caches missing")
assert(a.objective_cids(1) == nil, "no walk committed yet")
assert(a.objective_issued_cids(1) == nil, "no issued target before a walk")
assert(type(A.argb_to_abgr(0xFF112233)) == "number")
assert(A.argb_to_abgr(0xFF112233) == 0xFF332211)
assert(type(A.debug_probe()) == "string")

assert(type(A.catalog_ids) == "function", "catalog_ids exported")
assert(type(A.quest_state) == "function", "quest_state exported")

-- SPEC 37.5: each singleton fetch is independently protected; method reads
-- use the adapter's existing safe-call seam and accept exact true only.
do
  local old_get = sdk.get_managed_singleton
  local function singleton(result, calls, raising)
    return { call = function(_, name)
      calls[#calls + 1] = name
      if raising then error("call failed") end
      return result
    end }
  end
  local function scenario(fetch, expected, want_fetches, want_calls)
    local fetched, calls = {}, {}
    sdk.get_managed_singleton = function(name)
      fetched[#fetched + 1] = name
      return fetch(name, calls)
    end
    local result = a.overhead_block_reason()
    assert(result == expected, "overhead reason: expected " .. tostring(expected)
      .. ", got " .. tostring(result))
    assert(table.concat(fetched, ",") == want_fetches,
      "overhead singleton fetch order: " .. table.concat(fetched, ","))
    assert(table.concat(calls, ",") == want_calls,
      "overhead call order: " .. table.concat(calls, ","))
  end
  local ok, err = xpcall(function()
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(true, calls) end
    end, "menu", "app.GuiManager", "isPausedGUI")
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(false, calls) end
      return singleton(true, calls)
    end, "cutscene", "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(nil, calls) end
      return singleton(false, calls)
    end, nil, "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(false, calls) end
      return singleton(nil, calls)
    end, nil, "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(false, calls) end
      return singleton(7, calls)
    end, nil, "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
    for _, truthy in ipairs({ 1, "yes" }) do
      scenario(function(name, calls)
        if name == "app.GuiManager" then return singleton(truthy, calls) end
        return singleton("true", calls)
      end, nil, "app.GuiManager,app.DemoMediator",
        "isPausedGUI,get_IsPlayingDemo")
    end
    for _, nontrue in ipairs({ false, 1 }) do
      scenario(function(name, calls)
        if name == "app.GuiManager" then return singleton(nontrue, calls) end
        return singleton(true, calls)
      end, "cutscene", "app.GuiManager,app.DemoMediator",
        "isPausedGUI,get_IsPlayingDemo")
    end
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton("yes", calls) end
      return singleton(true, calls)
    end, "cutscene", "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
    for _, broken in ipairs({ "missing", "raising" }) do
      scenario(function(name, calls)
        if name == "app.GuiManager" then
          if broken == "missing" then return nil end
          error("GuiManager fetch failed")
        end
        return singleton(true, calls)
      end, "cutscene", "app.GuiManager,app.DemoMediator",
        "get_IsPlayingDemo")
      scenario(function(name, calls)
        if name == "app.GuiManager" then
          if broken == "missing" then return nil end
          return singleton(nil, calls, true)
        end
        return singleton(true, calls)
      end, "cutscene",
        "app.GuiManager,app.DemoMediator",
        broken == "missing" and "get_IsPlayingDemo"
          or "isPausedGUI,get_IsPlayingDemo")
      scenario(function(name, calls)
        if name == "app.GuiManager" then return singleton(false, calls) end
        if broken == "missing" then return nil end
        error("DemoMediator fetch failed")
      end, nil, "app.GuiManager,app.DemoMediator", "isPausedGUI")
    end
    scenario(function(name, calls)
      if name == "app.GuiManager" then return singleton(false, calls) end
      return singleton(nil, calls, true)
    end, nil, "app.GuiManager,app.DemoMediator",
      "isPausedGUI,get_IsPlayingDemo")
  end, debug.traceback)
  sdk.get_managed_singleton = old_get
  if not ok then error(err) end
end
assert(type(A.quest_log_is_end) == "function", "quest_log_is_end exported")
assert(type(A.catalog_stats) == "function", "catalog_stats exported")
local st = A.catalog_stats()
assert(type(st) == "table" and type(st.entries) == "number"
  and type(st.skipped) == "number" and type(st.distinct) == "number")
-- with the stubbed sdk returning no managers, both degrade to nil:
assert(A.catalog_ids() == nil)
assert(A.quest_state(12345) == nil)

-- learned-name store (load filter, fallback, string-key dump, dirty flag)
do
  local names = {}   -- qid -> live name served by the getQuestLog stub
  local qlm_names = { call = function(_, m, qid)
    if m == "getQuestLog" and names[qid] then
      return { get_field = function(_, f)
        if f == "QuestName" then return names[qid] end
      end }
    end
  end }
  local prev = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestLogManager" then return qlm_names end
  end
  assert(a.quest_name(20001) == "Alpha", "stored name is the fallback")
  assert(a.quest_name(20002) == nil, "empty stored name filtered")
  assert(a.quest_name(20003) == nil, "non-string stored name filtered")
  assert(a.quest_name(77777) == nil, "unknown qid has no name")
  -- extracted-table fallback: 20010 is not in the learned store
  assert(a.quest_name(20010) == "Medicament Predicament",
    "extracted title is the last fallback")
  -- 10030 has both a learned entry and an extracted title: learned wins
  assert(a.quest_name(10030) == "Learned Override",
    "learned name beats the extracted title")
  -- sudden-quest band 29000..29999 is never a side quest
  assert(a.is_side(29000) == false, "29000 not side")
  assert(a.is_side(29500) == false, "29500 not side")
  assert(a.is_side(29999) == false, "29999 not side")
  A.save_learned_names()
  assert(dump_count == 0, "nothing learned yet: no write")
  names[30001] = "Beta"
  assert(a.quest_name(30001) == "Beta", "live name wins")
  dump_result = false
  A.save_learned_names()
  assert(dump_count == 1, "write attempted")
  A.save_learned_names()
  assert(dump_count == 2, "failed write keeps dirty flag, retries")
  dump_result = true
  A.save_learned_names()
  assert(dump_count == 3, "retry succeeds")
  assert(dumped["30001"] == "Beta" and dumped["20001"] == "Alpha",
    "string keys, stored + learned")
  for k in pairs(dumped) do assert(type(k) == "string", "string keys only") end
  A.save_learned_names()
  assert(dump_count == 3, "second save without new name is a no-op")
  -- learn_names tolerates a missing catalog
  A.learn_names(32)
  sdk.get_managed_singleton = prev
end

-- quest_state precedence: swap in a QuestManager stub (the predicate ORDER
-- is the SPEC 9.2 guarantee; reordering QUEST_STATE_CHECKS must fail here)
local truthy = { isFailedQuest = true, isClearedQuest = true }
local qm_stub = { call = function(_, m) return truthy[m] == true end }
local real_gms = sdk.get_managed_singleton
local qlm_obj = nil
sdk.get_managed_singleton = function(n)
  if n == "app.QuestManager" then return qm_stub end
  if n == "app.QuestLogManager" then return qlm_obj end
end
assert(A.quest_state(1) == "failed", "failed beats cleared")
truthy = { isCanceledQuest = true, isEndedQuest = true }
assert(A.quest_state(2) == "canceled", "canceled beats ended")
truthy = { isFailedQuest = true, isCanceledQuest = true }
assert(A.quest_state(4) == "failed", "failed beats canceled")
truthy = { isEndedQuest = true }
assert(A.quest_state(3) == "completed", "ended alone is completed")
-- terminal states cache: flipping the stub must not change a cached answer
truthy = {}
assert(A.quest_state(3) == "completed", "terminal state cached")

-- isQuestLogEnd alone (no specific predicate) reads as completed
qlm_obj = { call = function() return nil end }
end_truth[5] = true
assert(A.quest_state(5) == "completed", "isQuestLogEnd-only is completed")
assert(A.quest_state(55) == nil, "not ended stays nil")

-- self-healing cache: presence in a live list clears a cached terminal state
local live_list = { get_field = function() return nil end,
  call = function(_, m)
    if m == "get_size" then return 1 end
    if m == "get_element" then return 8 end
  end }
qlm_obj = { call = function(_, m)
  if m == "getAcceptableQuestList" then return live_list end
end }
truthy = { isFailedQuest = true }
assert(A.quest_state(8) == "failed")
truthy = {}
assert(A.quest_state(8) == "failed", "cached before list read")
local acc = a.acceptable_ids()
assert(acc ~= nil and acc[1] == 8, "acceptable list read")
assert(A.quest_state(8) == nil, "list presence clears cached state")

-- session reset (new QuestLogManager) drops cached states
qlm_obj = { id = "a" }
a.reset_session_caches()
truthy = { isFailedQuest = true }
assert(A.quest_state(7) == "failed")
truthy = {}
assert(A.quest_state(7) == "failed", "cached within session")
qlm_obj = { id = "b" }
assert(a.reset_session_caches() == true, "new QuestLogManager resets")
assert(A.quest_state(7) == nil, "reset drops cached state")
qlm_obj = nil
sdk.get_managed_singleton = real_gms

-- catalog index: stubbed QuestManager + indexed collections (the same
-- get_size/get_element shape read_collection_items path 1 reads).
local function mobj(fields)
  fields.get_field = function(self, n) return self[n] end
  fields.call = function() return nil end
  return fields
end
-- In-game get_elements() returns a sol vector USERDATA (type() is not
-- "table"; # and 1-based [i] work; probe P17c). Pure Lua 5.4 cannot
-- make a userdata, so a coroutine with a thread metatable stands in.
local vec_of = setmetatable({}, { __mode = "k" })
debug.setmetatable(coroutine.create(function() end), {
  __len = function(co) return #vec_of[co] end,
  __index = function(co, i) return vec_of[co][i] end,
})
local function arr(elems)
  return { get_field = function() return nil end,
    get_element = function(_, index) return elems[index + 1] end,
    get_elements = function()
      local co = coroutine.create(function() end)
      vec_of[co] = elems
      return co
    end }
end
local function mcoll(items, counter)
  return {
    get_field = function() return nil end,
    call = function(_, m, i)
      if m == "get_size" then
        if counter then counter.walks = counter.walks + 1 end
        return #items
      end
      if m == "get_element" then return items[i + 1] end
      return nil
    end,
  }
end
local counter = { walks = 0 }
local function mdict(values)
  return {
    get_field = function() return nil end,
    call = function(_, m)
      if m == "getValues" or m == "get_Values" then return values end
      return nil
    end,
  }
end
-- entries: qids 30, 10, 10 — first 10 carries cast {5}
local full_entries = {
  mobj({ ContextData = mobj({ ContextDataArray = mcoll({
    mobj({ _IDValue = 30 }) }) }) }),
  mobj({ ContextData = mobj({ ContextDataArray = mcoll({
    mobj({ _IDValue = 10, CastNPCIDs = mcoll({ 5 }) }) }) }) }),
  mobj({ ContextData = mobj({ ContextDataArray = mcoll({
    mobj({ _IDValue = 10, CastNPCIDs = mcoll({ 7 }) }) }) }) }),
}
local current_dict = mdict(mcoll({}, counter))   -- start EMPTY
local qm_catalog = {
  get_field = function(_, n)
    if n == "QuestCatalogDict" then return current_dict end
  end,
  call = function() return nil end,
}
local t = 1000.0
local real_clock = os.clock
os.clock = function() return t end
sdk.get_managed_singleton = function(n)
  if n == "app.QuestManager" then return qm_catalog end
end

assert(A.catalog_ids() == nil, "empty walk not committed")
current_dict = mdict(mcoll(full_entries, counter))
assert(A.catalog_ids() == nil, "backoff holds before retry window")
t = t + 10.0
local ids = A.catalog_ids()
assert(ids ~= nil and #ids == 2 and ids[1] == 10 and ids[2] == 30,
  "sorted deduped ids after refill")
local a2 = A.make()
local cast10 = a2.cast_ids(10)
assert(#cast10 == 1 and cast10[1] == 5, "first entry per qid wins")
local st2 = A.catalog_stats()
assert(st2.entries == 3 and st2.skipped == 0 and st2.distinct == 2)
local walks_before = counter.walks
A.catalog_ids(); a2.cast_ids(10); a2.catalog_pos(30); a2.cast_ids(10)
assert(counter.walks == walks_before, "no re-walk while index committed")
local stc = A.catalog_stats()
stc.entries = 999
assert(A.catalog_stats().entries == 3, "catalog_stats returns a copy")
assert(A.catalog_stats().cast_skipped == 0)

-- (a) a qid added after the first walk is picked up by exactly one re-walk
local late_entries = { full_entries[1], full_entries[2], full_entries[3],
  mobj({ ContextData = mobj({ ContextDataArray = mcoll({
    mobj({ _IDValue = 40, CastNPCIDs = mcoll({ 9 }) }) }) }) }) }
current_dict = mdict(mcoll(late_entries, counter))
t = t + 10.0
local wb = counter.walks
local c40 = a2.cast_ids(40)
assert(#c40 == 1 and c40[1] == 9, "late-added qid picked up")
assert(counter.walks == wb + 1, "exactly one extra walk")
a2.cast_ids(40)
assert(counter.walks == wb + 1, "no further walk without time advancing")

-- a qid absent from the catalog re-walks once per committed index, not forever
t = t + 10.0
wb = counter.walks
assert(#a2.cast_ids(99) == 0)
assert(counter.walks == wb + 1, "first miss re-walks once")
t = t + 10.0
assert(#a2.cast_ids(99) == 0)
assert(counter.walks == wb + 1, "missed qid memoized for this index")

-- (b) enumerator-only collections are skipped, never read (SPEC 5 crash class)
local function enum_coll()
  local steps = 0
  local enumerator = { get_field = function() return nil end,
    call = function(_, m)
      if m == "MoveNext" then steps = steps + 1; return steps == 1 end
      if m == "get_Current" then return 77 end
    end }
  return { get_field = function() return nil end,
    call = function(_, m)
      if m == "GetEnumerator" then return enumerator end
    end }
end
local qm_enum = {
  get_field = function(_, n)
    if n == "QuestCatalogDict" then return mdict(mcoll({
      mobj({ ContextData = mobj({ ContextDataArray = mcoll({
        mobj({ _IDValue = 60, CastNPCIDs = enum_coll() }) }) }) }),
      mobj({ ContextData = mobj({ ContextDataArray = enum_coll() }) }),
    })) end
  end,
  call = function() return nil end,
}
sdk.get_managed_singleton = function(n)
  if n == "app.QuestManager" then return qm_enum end
end
local ids3 = A.catalog_ids()
assert(ids3 ~= nil and #ids3 == 1 and ids3[1] == 60, "new owner re-walks")
local st3 = A.catalog_stats()
assert(st3.skipped == 1, "enumerator-only array counted as skipped")
assert(st3.cast_skipped == 1, "enumerator-only cast list counted separately")
assert(A.make().cast_ids(60) == nil, "failed cast read is unknown, not empty")
os.clock = real_clock
sdk.get_managed_singleton = real_gms

-- v3: npc_live_pos is live-only and skips a character without a transform
do
  local asked = {}
  local tr = { call = function(_, m)
    if m == "get_Position" then return { x = 1, y = 2, z = 3 } end end }
  local go = { call = function(_, m)
    if m == "get_Transform" then return tr end end }
  local bare = { call = function() return nil end }  -- character, no transform
  local full = { call = function(_, m)
    if m == "get_GameObject" then return go end end }
  local cm = { call = function(_, m)
    if m == "findByCharacterID" then return bare end
    if m == "findCharacterByCharacterID" then return full end end }
  local prev = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(n)
    asked[n] = true
    if n == "app.CharacterManager" then return cm end
  end
  local live, mname = A.npc_live_pos(42)
  assert(live ~= nil and live.x == 1 and live.transform == tr,
    "npc_live_pos live hit")
  assert(mname == "findCharacterByCharacterID",
    "npc_live_pos skips a character without a transform")
  assert(asked["app.NPCManager"] == nil, "npc_live_pos: no holder lookup")
  assert(A.npc_live_pos("42") == nil, "npc_live_pos non-number cid")
  sdk.get_managed_singleton = prev
end

-- vec_xyz contract: a vector missing or failing any component reads as nil
do
  local function live_with(vec)
    local tr = { call = function(_, m)
      if m == "get_Position" then return vec end end }
    local go = { call = function(_, m)
      if m == "get_Transform" then return tr end end }
    local ch = { call = function(_, m)
      if m == "get_GameObject" then return go end end }
    local cm = { call = function(_, m)
      if m == "findByCharacterID" then return ch end end }
    local prev = sdk.get_managed_singleton
    sdk.get_managed_singleton = function(n)
      if n == "app.CharacterManager" then return cm end
    end
    local res = A.npc_live_pos(42)
    sdk.get_managed_singleton = prev
    return res
  end
  assert(live_with({ x = 1, y = 2, z = 3 }) ~= nil, "full vector reads")
  assert(live_with({ x = 1, z = 3 }) == nil, "missing y gives nil")
  assert(live_with({ x = 1, y = 2 }) == nil, "missing z gives nil")
  local raising = setmetatable({ x = 1, z = 3 }, {
    __index = function(_, k) if k == "y" then error("no y") end end })
  assert(live_with(raising) == nil, "failing y read gives nil")
  assert(live_with({ x = 1, y = 0 / 0, z = 3 }) == nil, "NaN gives nil")
end

-- v5 objective_pos: 6 s grace window, holder read only (SPEC 12.3c)
do
  local X = 555
  local vec = { x = 1, y = 2, z = 3 }
  local holder = { CharaID = X }
  holder.get_field = function(self, n) return self[n] end
  holder.call = function(_, m)
    if m == "get_UniversalPosition" then return vec end
  end
  local values = {
    get_field = function() return nil end,
    call = function(_, m, i)
      if m == "get_size" then return 1 end
      if m == "get_element" then return holder end
    end,
  }
  local dic_reads = 0
  local dic = { get_field = function() return nil end,
    call = function(_, m)
      if m == "getValues" then dic_reads = dic_reads + 1; return values end
    end }
  local nm = { get_field = function(_, n)
    if n == "NPCHolderDic" then return dic end end,
    call = function() return nil end }
  local prev_gms, prev_clock, prev_live = sdk.get_managed_singleton,
    os.clock, sdk.is_managed_object
  local prev_time = os.time
  local tm = 100000
  os.time = function() return tm end
  local clk = 5000.0
  os.clock = function() return clk end
  local live = true
  sdk.is_managed_object = function() return live end
  local qlm_s = { id = "s1" }
  sdk.get_managed_singleton = function(n)
    if n == "app.NPCManager" then return nm end
    if n == "app.QuestLogManager" then return qlm_s end
  end
  local ao = A.make()
  local x, y, z = ao.objective_pos(X)
  assert(x == 1 and y == 2 and z == 3, "objective_pos live holder read")
  assert(ao.objective_pos("bad") == nil, "non-number cid")
  live = false
  clk = clk + 5.9
  x, y, z = ao.objective_pos(X)
  assert(x == 1 and y == 2 and z == 3, "inside grace: last good served")
  clk = clk + 0.2
  assert(ao.objective_pos(X) == nil, "past 6 s grace: nil")
  assert(ao.objective_pos(X) == nil, "stays nil once expired")

  -- a session reset (new QuestLogManager) drops the grace value at once
  live = true
  clk = clk + 1
  assert(ao.objective_pos(X) == 1, "live again")
  live = false
  qlm_s = { id = "s2" }
  assert(ao.reset_session_caches() == true, "session reset ran")
  assert(ao.objective_pos(X) == nil, "reset clears the grace value")

  -- objective_pos never runs the per-cid 5 s miss retry: an uncached cid
  -- polled 6 s apart inside the TTL causes no second dictionary read
  ao.objective_pos(99999)
  local reads = dic_reads
  tm = tm + 6
  ao.objective_pos(99999)
  assert(dic_reads == reads, "no per-cid miss retry from objective_pos")
  sdk.get_managed_singleton, os.clock, sdk.is_managed_object =
    prev_gms, prev_clock, prev_live
  os.time = prev_time
end

-- get_character_world_pos: owner sync must precede the direct-holder lookup
-- (a direct hit must land in the NEW owner's cache, not a wiped old one)
do
  local function npc_manager(hit, held_cid)
    local holder = { CharaID = held_cid }
    holder.get_field = function(self, n) return self[n] end
    holder.call = function(_, m)
      if m == "get_UniversalPosition" then return { x = 5, y = 5, z = 5 } end
    end
    local dic = { get_field = function() return nil end }
    dic.call = function(_, m)
      if m == "get_Item" and dic.hit then return holder end
    end
    dic.hit = hit
    return { get_field = function(_, n)
      if n == "NPCHolderDic" then return dic end end,
      call = function() return nil end }, dic
  end
  local nm_a = npc_manager(true, 2)
  local nm_b, dic_b = npc_manager(true, 1)
  local cur = nm_a
  local prev_gms = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(n)
    if n == "app.NPCManager" then return cur end
  end
  assert(A.get_character_world_pos(2) == 5, "manager A direct hit")
  cur = nm_b
  local x, y, z = A.get_character_world_pos(1)
  assert(x == 5 and y == 5 and z == 5, "manager B direct hit")
  dic_b.hit = false
  x, y, z = A.get_character_world_pos(1)
  assert(x == 5 and y == 5 and z == 5,
    "direct hit survives in the new owner's cache")
  assert(A.get_character_world_pos(2) == nil,
    "manager A's cached entry does not leak into manager B")
  sdk.get_managed_singleton = prev_gms
end

-- v5 objective walk against stubbed processors; the real builder is
-- merged, so the spy wraps it directly.
do
  local qc = require("Clairvoyance.core")
  local real_ot = qc.objective_table
  assert(type(real_ot) == "function", "core.objective_table missing")
  local inner_ot = real_ot
  local spy = { records = nil }
  qc.objective_table = function(records, prev, prog)
    spy.records = records
    return inner_ot(records, prev, prog)
  end

  local side_qid = 20040
  local npc_cid = 777
  local function proc(o)
    local p = {
      ["<RefQuestController>k__BackingField"] =
        mobj({ _QuestID = side_qid }),
      ["<IsStarted>k__BackingField"] = o.started,
      Process = mobj({ QuestAction = mobj({
        _NpcHolder = mobj({ CharaID = (not o.nocid) and npc_cid or nil }),
        IsIssuedTask = o.issued,
        get_type_definition = function()
          return { get_full_name = function() return o.tn end }
        end,
      }) }),
    }
    p.get_field = function(self, n) return self[n] end
    p.call = function(_, m)
      if m == "get_ProcessFinished" then return o.fin end
    end
    return p
  end
  local NPC = "app.quest.action.NpcControl"
  local procs = {}
  local count_override = nil
  local gi = { n = 0 }   -- get_Item call counter (index-reuse pins)
  local drop_item_once = nil   -- index whose next get_Item returns nil once
  local qm_addr_n = 0          -- distinct address per stub instance
  local function new_qm(addr)
    if addr == nil then qm_addr_n = qm_addr_n + 1; addr = qm_addr_n end
    return {
      get_address = function() return addr end,
      get_field = function(_, n)
        if n == "DistributedQuestProcessors" then
          return { get_field = function() return nil end,
            call = function(_, m, i)
              if m == "get_Count" then return count_override or #procs end
              if m == "get_Item" then
                gi.n = gi.n + 1
                if drop_item_once == i then drop_item_once = nil return nil end
                return procs[i + 1]
              end
            end }
        end
      end,
      call = function() return nil end,
    }
  end
  local qm = new_qm()
  local prog_ids, prog_nil = { side_qid }, false
  local issued_live_task = { call = function(_, m)
    if m == "getActiveDestinations" then return mcoll({}) end
  end }
  local issued_live_info = { call = function(_, m)
    if m == "get_CurrentTaskIndex" then return 0 end
  end }
  local issued_live_dict = { call = function(_, m, q)
    if m == "get_Item" and q == side_qid then return issued_live_info end
  end }
  local qlm = { get_field = function(_, n)
    if n == "_QuestLogInfoDict" then return issued_live_dict end
  end, call = function(_, m, q)
    if m == "getProgressingQuestIds" and not prog_nil then return mcoll(prog_ids) end
    if m == "getCurrentTask" and q == side_qid then return issued_live_task end
  end }
  local prev_gms = sdk.get_managed_singleton
  local use_qm = true
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestManager" then return use_qm and qm or nil end
    if n == "app.QuestLogManager" then return qlm end
  end
  local aw = A.make()

  -- (1) get_ProcessFinished nil: skipped and counted, no cid kept
  procs = { proc({ started = true, fin = nil, tn = NPC, issued = true }) }
  A.refresh_objectives()
  local st = aw.objective_stats()
  assert(st.skipped == 1 and st.kept == 0, "nil finished is skipped+counted")
  assert(aw.objective_cids(side_qid) == nil, "no cid from a skipped entry")
  -- (2) IsStarted=false: dropped, not counted
  procs = { proc({ started = false, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()
  st = aw.objective_stats()
  assert(st.skipped == 0 and st.kept == 0, "not started: dropped uncounted")
  -- (3) non-NpcControl type dropped uncounted
  procs = { proc({ started = true, fin = false, tn = "app.quest.action.Other",
    issued = true }) }
  aw.refresh_objectives()
  st = aw.objective_stats()
  assert(st.skipped == 0 and st.kept == 0, "other action type dropped")
  -- a valid NpcControl entry is kept and reaches the builder
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()
  st = aw.objective_stats()
  assert(st.kept == 1 and st.entries == 1 and st.quests == 1, "valid kept")
  local got = aw.objective_cids(side_qid)
  assert(got ~= nil and got[1] == npc_cid, "objective_cids serves the table")
  local issued = aw.objective_issued_cids(side_qid)
  assert(issued ~= nil and #issued == 1 and issued[1] == npc_cid,
    "exact true IsIssuedTask is exposed as an objective target")
  local without_catalog = aw.objective_task_snapshot({ side_qid }, nil).quests[1]
  local with_v1_catalog = aw.objective_task_snapshot({ side_qid }, { version = 1, quests = {} }).quests[1]
  assert(without_catalog.read_status == "ok" and without_catalog.task_index == 0
    and #without_catalog.issued_npcs == 1
    and without_catalog.issued_npcs[1].target.cid == npc_cid
    and with_v1_catalog.read_status == "ok" and with_v1_catalog.task_index == 0
    and #with_v1_catalog.issued_npcs == 1,
    "invalid and v1 catalogs leave independent issued NPC evidence intact")
  local issued_core = require("Clairvoyance.core").objective_snapshot(
    aw.objective_task_snapshot({ side_qid }, nil), { status = "unknown", places = {} }, {},
    require("Clairvoyance.core").target_registry_new())
  assert(issued_core ~= nil and #issued_core.targets == 1
    and issued_core.targets[1].provider == "issued_npc",
    "nil catalog preserves issued targets through the core boundary")
  local issued_v1_core = require("Clairvoyance.core").objective_snapshot(
    aw.objective_task_snapshot({ side_qid }, { version = 1, quests = {} }),
    { status = "unknown", places = {} }, {}, require("Clairvoyance.core").target_registry_new())
  assert(issued_v1_core ~= nil and #issued_v1_core.targets == 1
    and issued_v1_core.targets[1].provider == "issued_npc",
    "v1 catalog preserves issued targets through the core boundary")
  prog_ids = {}
  aw.refresh_objectives()
  assert(aw.objective_issued_cids(side_qid) == nil,
    "non-progressing qid clears issued targets")
  prog_ids = { side_qid }
  procs = { proc({ started = true, fin = false, tn = NPC, issued = false }) }
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid)[1] == npc_cid,
    "objective_cids still includes non-issued candidates")
  assert(aw.objective_issued_cids(side_qid) == nil,
    "false IsIssuedTask is excluded")
  procs = { proc({ started = true, fin = false, tn = NPC, issued = nil }) }
  aw.refresh_objectives()
  assert(aw.objective_issued_cids(side_qid) == nil,
    "nil IsIssuedTask is excluded")
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()
  procs = {
    proc({ started = true, fin = false, tn = NPC, issued = true }),
    proc({ started = true, fin = false, tn = NPC, issued = true }),
  }
  aw.refresh_objectives()
  issued = aw.objective_issued_cids(side_qid)
  assert(issued ~= nil and #issued == 1 and issued[1] == npc_cid,
    "duplicate issued records deduplicate through core")
  -- (X1) finished process dropped uncounted
  procs = { proc({ started = true, fin = true, tn = NPC, issued = true }) }
  aw.refresh_objectives()
  st = aw.objective_stats()
  assert(st.skipped == 0 and st.kept == 0, "finished process dropped")
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()
  -- (X2) session reset clears the committed table
  assert(aw.objective_cids(side_qid) ~= nil, "pre-reset table")
  local qlm_saved = qlm
  qlm = { call = qlm_saved.call }
  assert(aw.reset_session_caches() == true, "session reset ran (walk)")
  assert(aw.objective_cids(side_qid) == nil, "reset clears objective table")
  assert(aw.objective_issued_cids(side_qid) == nil,
    "session reset clears issued targets immediately")
  aw.refresh_objectives()
  -- (4) 3 consecutive missing QuestManager walks empty the table
  use_qm = false
  aw.refresh_objectives(); aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) ~= nil, "two failures keep last table")
  assert(aw.objective_issued_cids(side_qid) ~= nil,
    "first two failed walks retain issued targets")
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) == nil, "3 failures empty the table")
  assert(aw.objective_issued_cids(side_qid) == nil,
    "third failed walk clears issued targets")
  assert(aw.objective_stats().failed_total == 3, "failed_total counts walks")
  -- (5) a new QuestManager instance resets failed_total
  use_qm = true
  qm = new_qm()
  aw.refresh_objectives()
  assert(aw.objective_stats().failed_total == 0, "new instance resets stats")
  -- (6) a raising builder counts as a failed walk and re-raises
  local good_ot = qc.objective_table
  qc.objective_table = function() error("boom") end
  local ok6 = pcall(aw.refresh_objectives)
  qc.objective_table = good_ot
  assert(ok6 == false, "builder error propagates")
  assert(aw.objective_stats().failed_total == 1, "raising builder counted")
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) ~= nil, "walk recovers after a raise")

  -- (7) an unreadable progressing list is a failed walk; table retained
  local ft = aw.objective_stats().failed_total
  prog_nil = true
  aw.refresh_objectives()
  assert(aw.objective_stats().failed_total == ft + 1, "nil progressing = failed")
  assert(aw.objective_cids(side_qid) ~= nil, "failed walk retains the table")
  prog_nil = false
  -- (8) progressing set with no side quest still commits (empty)
  prog_ids = { 3 }
  local saved_procs = procs
  local p3 = proc({ started = true, fin = false, tn = NPC, issued = true })
  p3["<RefQuestController>k__BackingField"] = mobj({ _QuestID = 3 })
  procs = { p3 }
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) == nil, "non-side progressing commits empty")
  assert(aw.objective_cids(3) == nil and aw.objective_stats().kept == 0,
    "non-side quest's processor is not kept")
  -- (8b) a focused main quest reaches the objective walk, and clearing the
  -- focus excludes it again
  aw.set_focus_qids({ 3 })
  procs = { p3, saved_procs[1] }   -- count change rebuilds the slot index
  aw.refresh_objectives()
  local h1 = aw.objective_cids(3)
  assert(h1 ~= nil and h1[1] == npc_cid, "focused main quest reaches the walk")
  aw.set_focus_qids(nil)
  aw.refresh_objectives()
  assert(aw.objective_cids(3) == nil, "unfocused main quest excluded again")
  procs = saved_procs
  prog_ids = { side_qid }
  -- (9) every unreadable-entry path is counted as skipped
  local good = { started = true, fin = false, tn = NPC, issued = true }
  local function variant(k, v)
    local o = {}
    for kk, vv in pairs(good) do o[kk] = vv end
    o[k] = v
    return o
  end
  procs = {
    false,                                         -- get_Item -> nil below
    proc(variant("tn", nil)),                      -- nil type name
    proc(variant("nocid", true)),                  -- holder has no CharaID
    proc(variant("started", nil)),                 -- IsStarted unreadable
    proc(variant("fin", nil)),                     -- ProcessFinished unreadable
  }
  procs[1] = nil
  count_override = 5
  -- procs[1] is nil: table.remove-free layout, index shift handled by get_Item
  local shifted = { nil, procs[2], procs[3], procs[4], procs[5] }
  procs = shifted
  aw.refresh_objectives()
  st = aw.objective_stats()
  assert(st.skipped == 5 and st.kept == 0, "five-way skipped counting")
  count_override = nil
  -- (10) IssuedTask must be strictly true
  procs = { proc(variant("issued", 1)) }
  aw.refresh_objectives()
  assert(spy.records[1] ~= nil and spy.records[1].issued == false,
    "truthy non-boolean IsIssuedTask is not issued")

  -- (11) index reuse: a second walk over an unchanged list reads only the
  -- progressing-matched entries, not the whole list
  local function proc_qid(o, q)
    local p = proc(o)
    p["<RefQuestController>k__BackingField"] = mobj({ _QuestID = q })
    return p
  end
  procs = {
    proc({ started = true, fin = false, tn = NPC, issued = true }),
    proc_qid({ started = true, fin = false, tn = NPC, issued = true }, 99),
  }
  aw.refresh_objectives()           -- count changed: rebuild (2) + walk (1)
  local gi0 = gi.n
  aw.refresh_objectives()
  assert(gi.n - gi0 == 1, "index reuse: one get_Item per matched entry")
  assert(aw.objective_cids(side_qid) ~= nil, "index walk serves the table")
  -- (12) a count change rebuilds the index and picks up new entries
  procs[3] = proc_qid({ started = true, fin = false, tn = NPC, issued = true }, 98)
  gi0 = gi.n
  aw.refresh_objectives()           -- rebuild (3) + walk (1)
  assert(gi.n - gi0 == 4, "count change rebuilds the index")
  -- (13) a reshuffle under an unchanged count is NOT a failed walk: the
  -- walk rebuilds once in the same call and commits from the fresh index
  procs[1], procs[2] = procs[2], procs[1]
  local ft11 = aw.objective_stats().failed_total
  local ot_calls = 0
  local counted_ot = qc.objective_table
  qc.objective_table = function(...) ot_calls = ot_calls + 1 return counted_ot(...) end
  aw.refresh_objectives()
  assert(aw.objective_stats().failed_total == ft11, "reshuffle is not a failure")
  assert(ot_calls == 1, "reshuffle walk commits exactly once")
  assert(aw.objective_cids(side_qid) ~= nil
    and aw.objective_stats().kept == 1, "reshuffle walk recovers in-call")
  -- (14) a PERSISTENT mismatch (qid differs on every read) is a failed
  -- walk and never commits partial records
  -- qid alternates per read: build caches side_qid (progressing, so the
  -- walk visits it), every verify read then differs -> mismatch on both
  -- the first pass and the post-rebuild pass
  local flip = 0
  local p_flip = proc({ started = true, fin = false, tn = NPC, issued = true })
  p_flip["<RefQuestController>k__BackingField"] = {
    get_field = function(_, fn)
      if fn == "_QuestID" then
        flip = flip + 1
        if flip % 2 == 1 then return side_qid end
        return 999
      end
    end,
    call = function() return nil end,
  }
  -- the flipping entry sits FIRST so the good side_qid record is gathered
  -- after it would have been committed by a fall-through bug
  local saved13 = procs
  procs = { p_flip,
    proc({ started = true, fin = false, tn = NPC, issued = true }) }
  ot_calls = 0
  local ftp = aw.objective_stats().failed_total
  aw.refresh_objectives()   -- count change: build reads flip-qid, walk differs
  assert(aw.objective_stats().failed_total == ftp + 1,
    "persistent mismatch is a failed walk")
  assert(ot_calls == 0, "mismatch walk never commits (no partial records)")
  assert(aw.objective_cids(side_qid) ~= nil, "mismatch walk retains the table")
  qc.objective_table = counted_ot
  procs = saved13
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) ~= nil, "clean list recovers")
  -- (15) a transient nil at index build is retried on the SAME walk
  -- (retry slot), not hidden until the next rebuild
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  drop_item_once = 0   -- get_Item(0) returns nil exactly once (build read)
  aw.refresh_objectives()
  assert(aw.objective_stats().kept == 1
    and aw.objective_cids(side_qid) ~= nil,
    "build-time nil entry recovers via retry slot on the same walk")
  -- (16) a qid unreadable DURING a walk skips that entry, never the walk
  local qc_toggle_nil = false
  procs = {
    proc({ started = true, fin = false, tn = NPC, issued = true }),
    proc({ started = true, fin = false, tn = NPC, issued = true }),
  }
  procs[1]["<RefQuestController>k__BackingField"] = {
    get_field = function(_, fn)
      if fn == "_QuestID" and not qc_toggle_nil then return side_qid end
    end,
    call = function() return nil end,
  }
  aw.refresh_objectives()   -- count change: clean build of both entries
  local ftm = aw.objective_stats().failed_total
  qc_toggle_nil = true
  aw.refresh_objectives()
  local stm = aw.objective_stats()
  assert(stm.failed_total == ftm, "unreadable qid does not fail the walk")
  assert(stm.kept == 1 and stm.skipped == 1,
    "unreadable qid entry skipped+counted, the rest kept")
  qc_toggle_nil = false
  -- (17) a QuestManager instance change rebuilds the index
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()   -- settle on count 1
  qm = new_qm()
  gi0 = gi.n
  aw.refresh_objectives()
  assert(gi.n - gi0 == 2, "owner change rebuilds (1 build + 1 walk read)")
  assert(aw.objective_stats().index_builds == 1,
    "owner change resets and counts the rebuild")
  -- (17b) a DIFFERENT stub table with the SAME address is the same owner
  qm = new_qm(qm.get_address())
  gi0 = gi.n
  aw.refresh_objectives()
  assert(gi.n - gi0 == 1, "same address = same owner, index reused")
  -- (17c) an unreadable address is a failed walk, never a kept object
  local qm_noaddr = new_qm()
  qm_noaddr.get_address = nil
  qm = qm_noaddr
  local ftl7 = aw.objective_stats().failed_total
  aw.refresh_objectives()
  assert(aw.objective_stats().failed_total == ftl7 + 1,
    "unreadable qm address is a failed walk")
  qm = new_qm()
  aw.refresh_objectives()   -- new owner settles first
  -- (18) a session reset rebuilds the index
  qlm = { call = qlm.call }   -- new session owner so the reset fires
  assert(aw.reset_session_caches() == true, "session reset ran (index)")
  gi0 = gi.n
  aw.refresh_objectives()
  assert(gi.n - gi0 == 2, "session reset rebuilds (1 build + 1 walk read)")
  -- (19) the 60 s age check rebuilds; 59 s does not
  local real_clock = os.clock
  os.clock = function() return real_clock() + 59 end
  gi0 = gi.n
  aw.refresh_objectives()
  assert(gi.n - gi0 == 1, "59 s old index is reused")
  os.clock = function() return real_clock() + 61 end
  gi0 = gi.n
  local ib19 = aw.objective_stats().index_builds
  aw.refresh_objectives()
  assert(gi.n - gi0 == 2, "61 s old index is rebuilt")
  assert(aw.objective_stats().index_builds == ib19 + 1,
    "age rebuild increments index_builds")
  os.clock = real_clock
  -- (20) the empty-progressing path still maintains the index, so the
  -- next objective walk reuses it instead of rebuilding
  procs = {
    proc({ started = true, fin = false, tn = NPC, issued = true }),
    proc_qid({ started = true, fin = false, tn = NPC, issued = true }, 99),
  }                                  -- count change: next walk rebuilds
  prog_ids = { 3 }                   -- non-side only
  aw.refresh_objectives()            -- empty-progressing: index built here
  prog_ids = { side_qid }
  gi0 = gi.n
  local ib20 = aw.objective_stats().index_builds
  aw.refresh_objectives()
  assert(gi.n - gi0 == 1, "post-empty walk reuses the index (1 visit read)")
  assert(aw.objective_stats().index_builds == ib20,
    "post-empty walk does not rebuild")
  -- (17d) an owner change whose first walk FAILS at the count read must
  -- still clear the committed table (SPEC 12.3a.7)
  procs = { proc({ started = true, fin = false, tn = NPC, issued = true }) }
  aw.refresh_objectives()            -- commit a table
  assert(aw.objective_cids(side_qid) ~= nil, "pre-17d table")
  local qm_badcount = new_qm()
  local qbc_get = qm_badcount.get_field
  qm_badcount.get_field = function(self, nmf)
    if nmf == "DistributedQuestProcessors" then
      return { get_field = function() return nil end,
        call = function(_, m) if m == "get_Count" then return nil end end }
    end
    return qbc_get(self, nmf)
  end
  qm = qm_badcount
  aw.refresh_objectives()            -- failed walk, NEW owner
  assert(aw.objective_cids(side_qid) == nil,
    "owner change clears the table even when its first walk fails")
  qm = new_qm()

  qc.objective_table = real_ot
  sdk.get_managed_singleton = prev_gms
end

-- ===== v6 tasks 2a+2b: gate analysis, liveness, walk, accessors =====
-- Everything is driven through the public refresh_gates walk with a spy on
-- the core module's gate_table that records the adapter's raw records and
-- delegates to the real builder (end-to-end commit shape).
do
  local qc = require("Clairvoyance.core")
  local real_gt = qc.gate_table
  local G = { calls = 0, last = nil }
  qc.gate_table = function(records)
    G.calls = G.calls + 1
    G.last = records
    return real_gt(records)
  end

  local CV = "app.quest.condition.CheckQuestVariable"
  local CS = "app.quest.condition.CheckQuestStatus"
  local CT = "app.quest.condition.CheckQuestCondition"
  local IS = "app.quest.condition.CheckScenarioParam"
  local IQ = "app.quest.condition.CheckQuestParam"
  local NPC = "app.quest.action.NpcControl"
  local OWN = 20040
  local AN = { n = 0 }   -- outer ConditionLists get_Count calls = analyses

  local function typed(tn, fields)
    local o = mobj(fields or {})
    o.get_type_definition = function()
      return { get_full_name = function() return tn end }
    end
    return o
  end
  local function lst(items, count, ctr)
    return {
      get_field = function() return nil end,
      call = function(_, m, i)
        if m == "get_Count" then
          if ctr then ctr.n = ctr.n + 1 end
          if count ~= nil then return count end
          return #items
        end
        if m == "get_Item" then return items[i + 1] end
      end,
    }
  end
  local function cvar(qid, vt, fk, fact, ek, exp)
    local prm = mobj({ _QuestID = qid, _ValueType = vt })
    if ek then prm[ek] = exp end
    local c = typed(CV, { _Param = prm })
    if fk then c[fk] = fact end
    return c
  end
  local function cstat(qid)
    return typed(CS, { Param = mobj({ _QuestID = qid }) })
  end
  local function ctree(items)
    return typed(CT, { _Condition = mobj({ ConditionParamArray = arr(items) }) })
  end

  local pid_n = 0
  local function gproc(o)
    pid_n = pid_n + 1
    local p = mobj({
      ["<RefQuestController>k__BackingField"] =
        o.qc or mobj({ _QuestID = o.qid or OWN }),
      ProcID = o.procid or pid_n,
    })
    if o.started_nil then p["<IsStarted>k__BackingField"] = nil
    elseif o.started ~= nil then p["<IsStarted>k__BackingField"] = o.started
    else p["<IsStarted>k__BackingField"] = true end
    if not o.nocls then
      p.ConditionLists = o.cls or lst({ lst(o.conds or {}) }, nil, AN)
    end
    if o.action then
      p.Process = mobj({ QuestAction = mobj({
        _NpcHolder = mobj({ CharaID = 777 }),
        IsIssuedTask = true,
        get_type_definition = function()
          return { get_full_name = function() return NPC end }
        end,
      }) })
    end
    p.call = function(_, m)
      if m == "get_ProcessFinished" then
        if o.fin_nil then return nil end
        if o.fin ~= nil then return o.fin end
        return false
      end
    end
    if o.flaky then
      p.get_field = function(self, n)
        if n == "ConditionLists" and o.flaky.broken then return nil end
        return self[n]
      end
    end
    return p
  end

  -- world stubs
  local S = { procs = {}, acc = {}, prog = {}, acc_nil = false,
    prog_nil = false, qm_on = true, gi = 0, qm = nil,
    catalog = nil, ended = nil }
  local addr_n = 7000
  local function new_qm(o)
    o = o or {}
    addr_n = addr_n + 1
    local addr = o.addr or addr_n
    return {
      get_address = function() return addr end,
      get_field = function(_, n)
        if n == "DistributedQuestProcessors" then
          return { get_field = function() return nil end,
            call = function(_, m, i)
              if m == "get_Count" then
                if o.badcount then return nil end
                return #S.procs
              end
              if m == "get_Item" then S.gi = S.gi + 1 return S.procs[i + 1] end
            end }
        end
        if n == "QuestCatalogDict" and S.catalog ~= nil then
          S.cat_reads = (S.cat_reads or 0) + 1
          local entries = {}
          for _, q in ipairs(S.catalog) do
            entries[#entries + 1] = mobj({ ContextData = mobj({
              ContextDataArray = mcoll({ mobj({ _IDValue = q }) }) }) })
          end
          return mdict(mcoll(entries))
        end
      end,
      call = function(_, m, qid)
        -- state route: S.ended[qid] answers the cleared-quest check
        if S.state_qids ~= nil and (m == "isFailedQuest" or m == "isCanceledQuest"
            or m == "isClearedQuest" or m == "isEndedQuest") then
          S.state_qids[qid] = (S.state_qids[qid] or 0) + 1
        end
        if m == "isClearedQuest" and S.ended ~= nil and S.ended[qid] then
          return true
        end
        return nil
      end,
    }
  end
  local names = {}
  local qlm = { call = function(_, m, qid)
    if m == "getAcceptableQuestList" then
      if S.acc_nil then return nil end
      return mcoll(S.acc)
    end
    if m == "getProgressingQuestIds" then
      if S.prog_nil then return nil end
      return mcoll(S.prog)
    end
    if m == "getQuestLog" and names[qid] then
      return { get_field = function(_, f)
        if f == "QuestName" then return names[qid] end
      end }
    end
  end }
  local prev_gms, prev_clock = sdk.get_managed_singleton, os.clock
  local clk = 50000.0
  os.clock = function() return clk end
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestManager" then return S.qm_on and S.qm or nil end
    if n == "app.QuestLogManager" then return qlm end
  end

  local aw = A.make()
  local function fresh()
    clk = clk + 1000
    S.qm = new_qm()
    S.qm_on, S.acc_nil, S.prog_nil = true, false, false
    S.catalog, S.ended = nil, nil
    S.acc, S.prog = { OWN }, {}
    G.last = nil
  end
  local function recs()
    local out = {}
    for _, r in ipairs(G.last or {}) do out[#out + 1] = r.ref end
    table.sort(out)
    return out
  end
  local function eq(t, ...)
    local e = { ... }
    if #t ~= #e then return false end
    for i = 1, #e do if t[i] ~= e[i] then return false end end
    return true
  end
  -- one processor, one walk: returns committed refs + stats.skipped
  local function walk1(conds, o)
    fresh()
    o = o or {}
    o.conds = conds
    S.procs = { gproc(o) }
    aw.refresh_gates()
    assert(G.last ~= nil, "walk1: expected a commit")
    return recs(), aw.gate_stats().skipped
  end

  -- ---- analysis pins, through the walk (formerly G1-G7) ----
  local r, sk = walk1({ cvar(30100, 2), cvar(OWN, 2) })
  assert(eq(r, 30100) and sk == 0, "G1 foreign var kept, own var dropped")
  r = walk1({ cstat(-1), cstat(30100) })
  assert(eq(r), "G1 -1 status is non-root: refs dropped")
  r = walk1({ cstat(OWN), cstat(30100) })
  assert(eq(r), "G1b own-qid status is non-root")
  r = walk1({ cstat(30100) })
  assert(eq(r, 30100), "G2 bare foreign status")
  r = walk1({ ctree({ typed(IS, { _QuestID = 30200 }),
    typed(IQ, { _QuestID = -1 }) }) })
  assert(eq(r), "G3 quest param -1 in tree is non-root")
  r = walk1({ ctree({ typed(IS, { _QuestID = 30200 }) }) })
  assert(eq(r, 30200), "G3 scenario param in tree is a status ref")
  r = walk1({ typed(CV, { _Param = mobj({
    _QuestID = mobj({ value__ = 30100 }), _ValueType = 2 }) }) })
  assert(eq(r, 30100), "G4 boxed qid unwrapped")
  -- slots: the open gate sits in a different slot than the closed one
  r = walk1({ cvar(30101, 2, "_IntFact", 3, "_IntValue", 3),
    cvar(30102, 2, "_IntFact", -1, "_IntValue", 3) })
  assert(eq(r, 30102), "G1 inner slot index is exact")
  fresh()
  S.procs = { gproc({ cls = lst({
    lst({ cvar(30103, 2, "_IntFact", 3, "_IntValue", 3) }),
    lst({ cvar(30104, 2, "_IntFact", -1, "_IntValue", 3) }) }) }) }
  aw.refresh_gates()
  assert(eq(recs(), 30104), "G1 outer slot index is exact")
  -- G5: unknown name ignored, nil name counted
  r, sk = walk1({ typed("some.Other", {}) })
  assert(eq(r) and sk == 0, "G5 unknown ignored")
  local nameless = mobj({})
  nameless.get_type_definition = function()
    return { get_full_name = function() return nil end }
  end
  r, sk = walk1({ nameless })
  assert(eq(r) and sk == 1, "G5 nil type name counted")
  -- G6: nil ConditionLists is valid (root, zero refs); bad count skipped
  r, sk = walk1(nil, { nocls = true })
  assert(eq(r) and sk == 0, "G6 nil lists")
  r, sk = walk1(nil, { cls = lst({}, "x") })
  assert(eq(r) and sk == 1, "G6 non-number count")
  -- G7: caps (a cap hit is counted in the stat, never fatal)
  local outer = {}
  for i = 1, 17 do outer[i] = lst({ cvar(30100 + i, 2) }) end
  r, sk = walk1(nil, { cls = lst(outer) })
  assert(#r == 16 and sk == 0, "G7 outer cap (not a read failure)")
  local items = {}
  for i = 1, 9 do items[i] = typed(IS, { _QuestID = 31000 + i }) end
  r, sk = walk1({ ctree(items) })
  assert(#r == 8 and sk == 0, "G7 tree cap")
  local conds17 = {}
  for i = 1, 17 do conds17[i] = cvar(30100 + i, 2) end
  r, sk = walk1(conds17)
  assert(#r == 16 and sk == 0, "G7 inner cap")
  -- G7b: a capped-but-readable analysis IS cached
  fresh()
  S.procs = { gproc({ cls = lst(outer, nil, AN) }) }
  AN.n = 0
  aw.refresh_gates()
  assert(AN.n == 1 and #recs() == 16, "G7b first round analyzes")
  clk = clk + 31
  local g7 = G.calls
  aw.refresh_gates()
  assert(G.calls == g7 + 1, "G7b second round walked")
  assert(AN.n == 1, "G7b capped analysis cached (no re-analysis)")

  r = walk1({ ctree({ typed(IQ, { _QuestID = OWN }) }), cstat(30100) })
  assert(eq(r), "G3 in-tree own-qid quest param is non-root")
  r = walk1({ typed(CS, { Param = mobj({
    _QuestID = mobj({ value__ = -1 }) }) }), cstat(30100) })
  assert(eq(r), "G4 boxed status qid unwrapped")
  local badinner = { get_field = function() return nil end,
    call = function(_, m)
      if m == "get_Count" then return 1 end
      return nil
    end }
  r, sk = walk1(nil, { cls = badinner })
  assert(eq(r) and sk == 1, "unreadable inner list is skipped")
  r = walk1({ ctree({ typed(IS, { _QuestID = OWN }) }) })
  assert(eq(r), "in-tree own-qid scenario ref not kept")
  r = walk1({ cstat(-5), cstat(30100) })
  assert(eq(r, 30100), "negative status qid not kept, processor stays root")
  r, sk = walk1({ typed(CV, { _Param = mobj({ _ValueType = 2 }) }) })
  assert(eq(r) and sk == 1, "nil var qid read is skipped")
  r, sk = walk1({ typed(CS, { Param = mobj({}) }) })
  assert(eq(r) and sk == 1, "nil status qid read is skipped")

  -- ---- G8r: an unreadable payload read is never cached (SPEC 13.3a.5) ----
  do -- var vtype unreadable: kept closed this walk, re-analyzed next walk
    fresh()
    local prm = mobj({ _QuestID = 30100, _IntValue = 3 })
    local c = typed(CV, { _Param = prm, _IntFact = 3 })
    S.procs = { gproc({ conds = { c } }) }
    AN.n = 0
    aw.refresh_gates()
    assert(eq(recs(), 30100) and aw.gate_stats().skipped == 1,
      "G8r unreadable vtype: closed and counted")
    prm._ValueType = 2
    clk = clk + 31
    aw.refresh_gates()
    assert(AN.n == 2 and eq(recs()) and aw.gate_stats().skipped == 0,
      "G8r vtype readable: re-analyzed, open gate drops the ref")
  end
  do -- in-tree quest param unreadable: root-ness not frozen
    fresh()
    local iq = typed(IQ, {})
    S.procs = { gproc({ conds = { ctree({ iq }), cstat(30100) } }) }
    aw.refresh_gates()
    assert(eq(recs(), 30100) and aw.gate_stats().skipped == 1,
      "G8r unreadable in-tree quest param counted")
    iq._QuestID = -1
    clk = clk + 31
    aw.refresh_gates()
    assert(eq(recs()) and aw.gate_stats().skipped == 0,
      "G8r readable -1 quest param makes the processor non-root")
  end
  do -- in-tree scenario param unreadable: ref not frozen out
    fresh()
    local is = typed(IS, {})
    S.procs = { gproc({ conds = { ctree({ is }) } }) }
    aw.refresh_gates()
    assert(eq(recs()) and aw.gate_stats().skipped == 1,
      "G8r unreadable scenario param counted")
    is._QuestID = 30200
    clk = clk + 31
    aw.refresh_gates()
    assert(eq(recs(), 30200), "G8r scenario ref appears once readable")
  end

  -- ---- G8p: steady-state read set (SPEC 13.3a.5) ----
  do -- a cached non-root processor is never re-read for IsStarted
    fresh()
    local reads = 0
    local p = gproc({ conds = { cstat(-1), cstat(30100) } })
    local gf = p.get_field
    p.get_field = function(self, n)
      if n == "<IsStarted>k__BackingField" then reads = reads + 1 end
      return gf(self, n)
    end
    S.procs = { p }
    aw.refresh_gates()
    assert(reads == 1, "G8p first walk reads IsStarted before analysis")
    clk = clk + 31
    aw.refresh_gates()
    assert(reads == 1 and eq(recs()), "G8p cached non-root: no IsStarted re-read")
  end
  do -- one quest_state query per ref per walk, however many roots name it
    fresh()
    S.acc = { OWN, 20060 }
    S.procs = { gproc({ conds = { cstat(30100) } }),
      gproc({ qid = 20060, conds = { cstat(30100) } }) }
    local q = 0
    S.qm.call = function(_, m) if m == "isFailedQuest" then q = q + 1 end return nil end
    aw.refresh_gates()
    assert(q == 1 and eq(recs(), 30100, 30100), "G8p quest_state memoized per walk")
  end

  -- ---- G9: the var gate reads closed unless both sides read equal ----
  r = walk1({ cvar(30100, 2, "_IntFact", -1, "_IntValue", 3) })
  assert(eq(r, 30100), "G9a fact ~= expected is closed (ref kept)")
  r = walk1({ cvar(30100, 2, "_IntFact", 3, "_IntValue", 3) })
  assert(eq(r), "G9b fact == expected is open (ref dropped)")
  r = walk1({ cvar(30100, 2) })
  assert(eq(r, 30100), "G9c both nil is closed")
  r = walk1({ cvar(30100, 3, "_IntFact", 3, "_IntValue", 3) })
  assert(eq(r, 30100), "G9e unknown vtype is closed")
  r = walk1({ cvar(30100, 1, "_BoolFact", 1, "_BoolValue", 1) })
  assert(eq(r, 30100), "G9f non-boolean is closed")
  r = walk1({ cvar(30100, 1, "_BoolFact", true, "_BoolValue", true) })
  assert(eq(r), "G9f boolean equal is open")
  do -- G9d: slot unreachable at liveness time (analysis cached) = closed
    fresh()
    local fl = { broken = false }
    S.procs = { gproc({ flaky = fl,
      conds = { cvar(30100, 2, "_IntFact", 3, "_IntValue", 3) } }) }
    aw.refresh_gates()
    assert(eq(recs()), "G9d open while readable")
    fl.broken = true
    clk = clk + 31
    aw.refresh_gates()
    assert(eq(recs(), 30100), "G9d unreachable slot reads closed")
  end

  -- ---- G10: cadence ----
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  S.gi = 0
  aw.refresh_gates()
  assert(S.gi > 0 and G.calls > 0 and aw.gate_qids(OWN) ~= nil,
    "G10 first call walks immediately")
  local gi10, gc10 = S.gi, G.calls
  clk = clk + 10
  aw.refresh_gates()
  assert(S.gi == gi10 and G.calls == gc10, "G10 within 30 s: no walk ")
  clk = clk + 21
  aw.refresh_gates()
  assert(S.gi > gi10 and G.calls == gc10 + 1, "G10 after 30 s: walks")
  -- G10b: a failed walk also waits the interval
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  local ft = aw.gate_stats().failed_total
  S.qm_on = false
  aw.refresh_gates()
  assert(aw.gate_stats().failed_total == ft + 1, "G10b failure counted")
  S.qm_on = true
  clk = clk + 5
  S.gi = 0
  aw.refresh_gates()
  assert(S.gi == 0 and aw.gate_stats().failed_total == ft + 1,
    "G10b failed walk waits the interval")
  clk = clk + 26
  aw.refresh_gates()
  assert(S.gi > 0 and aw.gate_qids(OWN) ~= nil, "G10b walks after the interval")

  -- ---- G11: amortized population ----
  fresh()
  local many = {}
  for i = 1, 100 do many[i] = gproc({ conds = { cstat(40000 + i) } }) end
  S.procs = many
  AN.n = 0
  local gc11, ft11 = G.calls, aw.gate_stats().failed_total
  aw.refresh_gates()
  assert(G.calls == gc11 and aw.gate_qids(OWN) == nil,
    "G11 call 1 commits nothing")
  assert(AN.n == 80 and aw.gate_stats().failed_total == ft11,
    "G11 budget of 80 analyses; a partial walk is not a failure")
  aw.refresh_gates()   -- no clock advance: population bypasses the interval
  assert(G.calls == gc11 + 1 and AN.n == 100, "G11 call 2 completes")
  local t11 = aw.gate_qids(OWN)
  assert(t11 ~= nil and #t11 == 100, "G11 committed all refs")
  -- G11b: misses under the budget commit on the first call
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }),
    gproc({ conds = { cstat(30101) } }) }
  gc11 = G.calls
  aw.refresh_gates()
  assert(G.calls == gc11 + 1 and #aw.gate_qids(OWN) == 2, "G11b first call commits")

  -- G11c: partial call, then a failed call, then a call inside the
  -- interval reads nothing (the failed walk re-stamps the interval)
  fresh()
  S.procs = many
  aw.refresh_gates()                 -- partial: population open
  S.qm_on = false
  aw.refresh_gates()                 -- failed (bypasses interval while populating)
  S.qm_on = true
  S.gi = 0
  aw.refresh_gates()
  assert(S.gi == 0, "G11c call inside the interval after a failure reads 0 get_Item")
  -- livelock: 81 always-failing analyses + 1 good processor must commit
  fresh()
  local badp = {}
  for i = 1, 81 do
    badp[i] = gproc({ cls = lst({}, "x") })
  end
  badp[82] = gproc({ conds = { cstat(31999) } })
  S.procs = badp
  local calls_needed = nil
  for k = 1, 6 do
    aw.refresh_gates()
    if aw.gate_qids(OWN) ~= nil then calls_needed = k break end
  end
  assert(calls_needed ~= nil and calls_needed <= 3,
    "G11d failing analyses cannot livelock the round")
  assert(eq(aw.gate_qids(OWN), 31999) and aw.gate_stats().skipped == 81,
    "G11d good quest's refs present, failures counted once")

  -- ---- G12: invalidate ----
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  aw.refresh_gates()
  aw.invalidate_gates()
  assert(aw.gate_qids(OWN) == nil, "G12 invalidated table is nil")
  local gc12 = G.calls
  aw.refresh_gates()   -- same clock: no interval wait
  assert(G.calls == gc12 + 1 and aw.gate_qids(OWN) ~= nil,
    "G12 next call walks regardless of the interval")

  -- ---- G13: owner change seen by either walk clears both ----
  local function obj_setup()
    fresh()
    S.prog = { OWN }
    S.procs = { gproc({ conds = { cstat(30100) }, action = true }) }
    aw.refresh_objectives()
    aw.refresh_gates()
    assert(aw.objective_cids(OWN) ~= nil and aw.gate_qids(OWN) ~= nil,
      "G13 setup: both tables committed")
  end
  obj_setup()   -- gate walk sees the new owner first
  S.qm = new_qm()
  clk = clk + 31
  S.gi = 0
  aw.refresh_gates()
  assert(aw.objective_cids(OWN) == nil, "G13 gate-first clears the objective table")
  assert(S.gi == 2, "G13 gate-first rebuilt the index (1 build + 1 visit)")
  aw.refresh_objectives()
  assert(aw.objective_cids(OWN) ~= nil, "G13 objective table recovers")
  obj_setup()   -- objective walk sees the new owner first
  S.qm = new_qm()
  aw.refresh_objectives()
  assert(aw.gate_qids(OWN) == nil, "G13 objective-first clears the gate table")
  -- count-fail variants (the new owner's first walk fails after the owner read)
  obj_setup()
  S.qm = new_qm({ badcount = true })
  aw.refresh_objectives()
  assert(aw.gate_qids(OWN) == nil,
    "G13 objective-first count failure still clears the gate table")
  obj_setup()
  S.qm = new_qm({ addr = 99001, badcount = true })
  clk = clk + 31
  aw.refresh_gates()
  assert(aw.objective_cids(OWN) == nil,
    "G13 gate-first count failure still clears the objective table")
  S.qm = new_qm({ addr = 99001 })   -- same owner, count readable again
  S.gi = 0
  aw.refresh_objectives()
  assert(S.gi == 2 and aw.objective_cids(OWN) ~= nil,
    "G13 the cleared index is rebuilt by the next objective walk")

  -- ---- G14: index verify ----
  fresh()
  local pA = gproc({ conds = { cstat(30100) } })
  local pB = gproc({ qid = 20060, conds = { cstat(30200) } })
  S.procs = { pA, pB }
  aw.refresh_gates()
  assert(eq(aw.gate_qids(OWN), 30100), "G14a baseline")
  S.procs = { pB, pA }   -- reshuffle under an unchanged count
  clk = clk + 31
  local gc14, ft14 = G.calls, aw.gate_stats().failed_total
  aw.refresh_gates()
  assert(aw.gate_stats().failed_total == ft14, "G14a reshuffle is not a failure")
  assert(G.calls == gc14 + 1 and eq(aw.gate_qids(OWN), 30100),
    "G14a rebuild-once recovery commits the right table")
  -- G14b: persistent mismatch (qid alternates on every read)
  local flip = 0
  local STABLE14 = false
  local p_flip = gproc({ conds = { cstat(30300) }, qc = {
    get_field = function(_, fn)
      if fn == "_QuestID" then
        flip = flip + 1
        if STABLE14 or flip % 2 == 1 then return OWN end
        return 999
      end
    end,
    call = function() return nil end } })
  S.procs = { p_flip, pA, pB }   -- count change: build then verify differs
  clk = clk + 31
  gc14, ft14 = G.calls, aw.gate_stats().failed_total
  aw.refresh_gates()
  assert(aw.gate_stats().failed_total == ft14 + 1, "G14b persistent mismatch fails")
  assert(G.calls == gc14, "G14b zero builder calls")
  assert(eq(aw.gate_qids(OWN), 30100), "G14b table retained")
  -- the failed walk dropped the index: with an unchanged count the next
  -- walk must still rebuild it
  STABLE14 = true   -- same list, qid now stable
  clk = clk + 31
  local ib14 = aw.objective_stats().index_builds
  aw.refresh_gates()
  assert(aw.objective_stats().index_builds == ib14 + 1,
    "G14b next walk rebuilds the dropped index")
  assert(eq(aw.gate_qids(OWN), 30100, 30300), "G14b recovers")

  -- ---- G15: failed-walk semantics ----
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  aw.refresh_gates()
  assert(aw.gate_qids(OWN) ~= nil, "G15 baseline table")
  ft = aw.gate_stats().failed_total
  S.acc_nil = true
  clk = clk + 31 aw.refresh_gates()
  clk = clk + 31 aw.refresh_gates()
  assert(aw.gate_qids(OWN) ~= nil, "G15 two failures keep the table")
  clk = clk + 31 aw.refresh_gates()
  assert(aw.gate_qids(OWN) == nil and aw.gate_stats().failed_total == ft + 3,
    "G15 three failures empty the table")
  S.acc_nil = false
  S.acc = { 10110 }   -- readable, zero side quests
  clk = clk + 31
  gc14 = G.calls
  aw.refresh_gates()
  assert(G.calls == gc14, "G15 zero side quests: builder not called")
  assert(aw.gate_qids(OWN) == nil and aw.gate_stats().gated == 0
    and aw.gate_stats().acceptable == 0 and aw.gate_stats().refs == 0,
    "G15 zero side quests commits empty")
  S.acc = { OWN }
  clk = clk + 31
  aw.refresh_gates()
  assert(aw.gate_qids(OWN) ~= nil, "G15 recovers")
  local st15 = aw.gate_stats()
  assert(st15.gated == 1 and st15.acceptable == 1 and st15.refs == 1,
    "G15 stats after a commit")
  -- a raising builder counts as a failed walk and re-raises
  local ok_gt = qc.gate_table
  qc.gate_table = function() error("boom") end
  ft = aw.gate_stats().failed_total
  clk = clk + 31
  assert(pcall(aw.refresh_gates) == false, "G15 builder error propagates")
  assert(aw.gate_stats().failed_total == ft + 1, "G15 raising builder counted")
  qc.gate_table = ok_gt
  -- a non-table builder result is an error too
  qc.gate_table = function() return 5 end
  clk = clk + 31
  assert(pcall(aw.refresh_gates) == false, "G15 bad builder result rejected")
  qc.gate_table = ok_gt

  -- ---- G16: seen_quest_name ----
  fresh()
  S.acc, S.prog = { OWN, 20010 }, { 10110 }
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  names[20050] = "LiveName"
  aw.refresh_gates()
  assert(aw.seen_quest_name(20050) == "LiveName", "G16 live name wins")
  assert(aw.seen_quest_name(20001) == "Alpha", "G16 learned name next")
  assert(aw.seen_quest_name(10110) == "An Unsettling Encounter",
    "G16 extracted title for a qid seen only as progressing")
  assert(aw.seen_quest_name(20010) == "Medicament Predicament",
    "G16 extracted title for an acceptable qid")
  assert(aw.seen_quest_name(10120) == nil, "G16 unseen extracted title is nil")
  assert(aw.seen_quest_name(77777) == nil, "G16 unknown qid is nil")
  assert(aw.quest_name(10120) == "The Caged Magistrate",
    "G16 quest_name still serves the extracted title")

  -- ---- G17: session reset clears all gate state ----
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) } }) }
  aw.refresh_gates()
  assert(aw.gate_qids(OWN) ~= nil and aw.gate_stats().gated == 1, "G17 setup")
  qlm = { call = qlm.call }   -- new session owner so the reset fires
  assert(aw.reset_session_caches() == true, "G17 session reset ran")
  assert(aw.gate_qids(OWN) == nil, "G17 table cleared")
  local st17 = aw.gate_stats()
  assert(st17.gated == 0 and st17.refs == 0 and st17.acceptable == 0
    and st17.failed_total == 0, "G17 stats zeroed")
  assert(aw.seen_quest_name(10110) == nil, "G17 seen set cleared")
  AN.n = 0
  local gc17 = G.calls
  aw.refresh_gates()   -- same clock: interval state reset
  assert(G.calls == gc17 + 1 and AN.n == 1,
    "G17 next call walks and re-analyzes (condition cache emptied)")

  -- ---- G18: liveness filters ----
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) }, fin = true }) }
  aw.refresh_gates()
  assert(eq(recs()) and aw.gate_stats().skipped == 0, "G18 finished: dropped")
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) }, started = 1 }) }
  aw.refresh_gates()
  assert(eq(recs()) and aw.gate_stats().skipped == 0,
    "G18 truthy non-boolean IsStarted is dropped")
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) }, started_nil = true }) }
  aw.refresh_gates()
  assert(eq(recs()) and aw.gate_stats().skipped == 1,
    "G18 nil IsStarted is skipped and counted")
  fresh()
  S.procs = { gproc({ conds = { cstat(30100) }, fin_nil = true }) }
  aw.refresh_gates()
  assert(eq(recs()) and aw.gate_stats().skipped == 1,
    "G18 nil ProcessFinished is skipped and counted")

  -- ---- G20: empty progressing set, gate walk builds the index itself ----
  fresh()
  S.prog = {}
  S.procs = { gproc({ conds = { cstat(31777) } }) }
  S.gi = 0
  aw.refresh_gates()
  assert(S.gi == 2, "G20 gate walk built the index (1 build + 1 visit)")
  assert(eq(aw.gate_qids(OWN), 31777), "G20 refs served")

  -- ---- G19: ended gating quest, and the unreadable-count retry ----
  fresh()
  S.procs = { gproc({ conds = { cstat(31900), cstat(31901) } }) }
  end_truth[31900] = true
  aw.refresh_gates()
  assert(eq(recs(), 31901), "G19 ended gating quest is dropped")
  end_truth[31900] = nil
  fresh()
  local bad = true
  local cls_bad = { get_field = function() return nil end,
    call = function(_, m, i)
      if m == "get_Count" then
        AN.n = AN.n + 1
        if bad then return "x" end
        return 1
      end
      if m == "get_Item" then return lst({ cstat(31950) }) end
    end }
  S.procs = { gproc({ cls = cls_bad }),
    gproc({ conds = { cstat(31951) } }) }
  aw.refresh_gates()
  assert(eq(recs(), 31951) and aw.gate_stats().skipped == 1,
    "G19 unreadable count: round still commits, skip counted")
  bad = false
  clk = clk + 31
  aw.refresh_gates()
  assert(eq(recs(), 31950, 31951) and aw.gate_stats().skipped == 0,
    "G19 ref appears once readable (no frozen cache)")


  -- ===== v7 task 2: tree walk (SPEC 14.3c) =====
  -- Catalog route: S.catalog serves QuestCatalogDict through new_qm; one
  -- A.catalog_ids() call commits CATALOG_IDS. S.acc_nil / S.prog_nil make
  -- either list unreadable independently; S.ended warms QUEST_STATE_CACHE.
  local T_ACC, T_PRG, T_CAT, T_END, T_NS = 20040, 20060, 20080, 20090, 29001
  local TCATALOG = { T_ACC, T_PRG, T_CAT, T_END, T_NS }
  local function tfresh(catalog)
    fresh()
    S.catalog = catalog
    A.catalog_ids()
  end
  -- one root processor per quest, each gated on quest 30100
  local function tprocs(...)
    local out = {}
    for _, q in ipairs({ ... }) do
      out[#out + 1] = gproc({ qid = q, conds = { cstat(30100) } })
    end
    return out
  end
  local function tstat() return aw.tree_gate_stats() end

  -- ---- TW1: tracked composition ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, { T_PRG }
  S.ended = { [T_END] = true }
  assert(aw.quest_state(T_END) == "completed", "TW1 ended warmed via state stub")
  S.procs = tprocs(T_ACC, T_PRG, T_CAT, T_END)
  aw.refresh_tree_gates()
  assert(eq(aw.tree_gate_qids(T_CAT) or {}, 30100), "TW1 catalog-only included")
  assert(aw.tree_gate_qids(T_ACC) == nil, "TW1 acceptable excluded")
  assert(aw.tree_gate_qids(T_PRG) == nil, "TW1 progressing non-acceptable excluded")
  assert(aw.tree_gate_qids(T_END) == nil, "TW1 ended (cache hit) excluded")
  assert(aw.tree_gate_qids(T_NS) == nil and tstat().tracked == 1
    and tstat().gated == 1 and tstat().refs == 1,
    "TW1 non-side excluded; tracked == 1")
  -- either list unreadable = failed walk, table retained
  local ft1 = tstat().failed_total
  S.prog_nil = true
  clk = clk + 121
  aw.refresh_tree_gates()
  assert(tstat().failed_total == ft1 + 1 and aw.tree_gate_qids(T_CAT) ~= nil,
    "TW1 progressing list nil: failed walk, table retained")
  S.prog_nil, S.acc_nil = false, true
  clk = clk + 121
  aw.refresh_tree_gates()
  assert(tstat().failed_total == ft1 + 2 and aw.tree_gate_qids(T_CAT) ~= nil,
    "TW1 acceptable list nil: failed walk, table retained")
  -- no committed catalog: no commit, no failure, next call walks anyway
  tfresh(nil)
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  assert(tstat().commits == 0 and tstat().failed_total == 0
    and aw.tree_gate_table() == nil, "TW1 no catalog: no commit, no failure")
  S.catalog = TCATALOG
  clk = clk + 6                      -- clear the catalog retry backoff only
  S.cat_reads = 0
  aw.refresh_tree_gates()            -- catalog servable but not committed
  assert(tstat().commits == 0 and S.cat_reads == 0
    and aw.tree_gate_table() == nil, "TW1 the walk never builds the catalog")
  A.catalog_ids()
  aw.refresh_tree_gates()            -- well inside the 120 s interval
  assert(tstat().commits == 1 and eq(aw.tree_gate_qids(T_CAT) or {}, 30100),
    "TW1 next call walks despite the interval once the catalog commits")

  -- ---- TW2: edges + accessor identity ----
  assert(aw.tree_gate_table() == aw.tree_gate_table(), "TW2 same reference")
  assert(aw.tree_gate_table()[T_CAT] == aw.tree_gate_qids(T_CAT),
    "TW2 qids serves the committed table's array")
  assert(aw.gate_qids(T_CAT) == nil, "TW2 v6 table untouched by tree commit")

  -- ---- TW3: 120 s cadence ----
  tfresh(TCATALOG)
  S.procs = tprocs(T_CAT)
  local gc3 = G.calls
  aw.refresh_tree_gates()
  assert(G.calls == gc3 + 1, "TW3 first call walks")
  clk = clk + 119
  aw.refresh_tree_gates()
  assert(G.calls == gc3 + 1, "TW3 inside 120 s: no walk")
  clk = clk + 2
  aw.refresh_tree_gates()
  assert(G.calls == gc3 + 2, "TW3 past 120 s: walks")
  S.prog_nil = true
  clk = clk + 121
  aw.refresh_tree_gates()
  local ft3, cm3 = tstat().failed_total, tstat().commits
  S.prog_nil = false
  clk = clk + 10
  aw.refresh_tree_gates()
  assert(tstat().failed_total == ft3 and tstat().commits == cm3
    and G.calls == gc3 + 2, "TW3 failed walk waits the interval")
  clk = clk + 111
  aw.refresh_tree_gates()
  assert(tstat().commits == cm3 + 1, "TW3 walks again after the interval")

  -- ---- TW4: separation from the v6 walk ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC, 20010 }, {}
  S.procs = tprocs(T_ACC, T_CAT)
  aw.refresh_gates()
  assert(aw.tree_gate_table() == nil and tstat().commits == 0,
    "TW4 v6 commit never touches the tree table")
  local v6_arr = aw.gate_qids(T_ACC)
  assert(eq(v6_arr or {}, 30100), "TW4 v6 setup")
  local v6_stats = {}
  for k, v in pairs(aw.gate_stats()) do v6_stats[k] = v end
  assert(aw.seen_quest_name(20010) == "Medicament Predicament", "TW4 seen setup")
  S.acc, S.prog = { T_ACC }, { 10110 }   -- different lists for the tree walk
  aw.refresh_tree_gates()
  assert(eq(aw.tree_gate_qids(T_CAT) or {}, 30100), "TW4 tree committed")
  assert(aw.gate_qids(T_ACC) == v6_arr and aw.gate_qids(T_CAT) == nil,
    "TW4 tree commit never touches GATE_TABLE")
  for k, v in pairs(v6_stats) do
    assert(aw.gate_stats()[k] == v, "TW4 GATE_STATS unchanged: " .. k)
  end
  assert(aw.seen_quest_name(20010) == "Medicament Predicament"
    and aw.seen_quest_name(10110) == nil,
    "TW4 tree walk never touches SEEN_QUEST_IDS")
  local tree_ref, tree_commits = aw.tree_gate_table(), tstat().commits
  clk = clk + 31
  aw.refresh_gates()
  assert(aw.tree_gate_table() == tree_ref and tstat().commits == tree_commits
    and aw.tree_gate_qids(T_ACC) == nil, "TW4 v6 re-walk leaves the tree alone")

  -- ---- TW5: shared condition cache across v6 -> tree ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_CAT }, {}
  S.procs = tprocs(T_CAT)
  AN.n = 0
  aw.refresh_gates()
  assert(AN.n == 1, "TW5 v6 analyzes the processor once")
  S.acc = {}                           -- now catalog-only, non-acceptable
  aw.refresh_tree_gates()
  assert(AN.n == 1, "TW5 tree walk hits the shared cache (no re-analysis)")
  assert(eq(aw.tree_gate_qids(T_CAT) or {}, 30100), "TW5 tree edges from the cache")

  -- ---- TW6: invalidate + commit counting ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  clk = clk + 121
  aw.refresh_tree_gates()
  assert(tstat().commits == 2, "TW6 commits per successful commit")
  S.acc = { T_ACC, T_PRG, T_CAT, T_END }   -- nothing left to track
  clk = clk + 121
  aw.refresh_tree_gates()
  assert(tstat().commits == 3 and tstat().tracked == 0
    and aw.tree_gate_table() ~= nil and next(aw.tree_gate_table()) == nil,
    "TW6 empty-tracked commit counts and installs an empty table")
  aw.invalidate_tree_gates()
  assert(aw.tree_gate_table() == nil and aw.tree_gate_qids(T_CAT) == nil,
    "TW6 invalidate clears")
  S.acc = { T_ACC }
  aw.refresh_tree_gates()              -- same clock: no interval wait
  assert(tstat().commits == 1 and eq(aw.tree_gate_qids(T_CAT) or {}, 30100),
    "TW6 next call walks regardless of the interval (stats reset)")

  -- ---- TW7: failure semantics + owner change ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  assert(aw.tree_gate_qids(T_CAT) ~= nil, "TW7 baseline")
  S.prog_nil = true
  clk = clk + 121 aw.refresh_tree_gates()
  clk = clk + 121 aw.refresh_tree_gates()
  assert(aw.tree_gate_qids(T_CAT) ~= nil and tstat().failed_total == 2,
    "TW7 two failures keep the table")
  clk = clk + 121 aw.refresh_tree_gates()
  assert(aw.tree_gate_qids(T_CAT) == nil and aw.tree_gate_table() ~= nil
    and next(aw.tree_gate_table()) == nil and tstat().failed_total == 3,
    "TW7 three failures empty the table")
  S.prog_nil = false
  local ok_gt7 = qc.gate_table
  qc.gate_table = function() error("boom") end
  local ft7 = tstat().failed_total
  clk = clk + 121
  assert(pcall(aw.refresh_tree_gates) == false, "TW7 builder error propagates")
  assert(tstat().failed_total == ft7 + 1, "TW7 raising builder counted")
  qc.gate_table = function() return 5 end
  clk = clk + 121
  assert(pcall(aw.refresh_tree_gates) == false, "TW7 bad builder result rejected")
  qc.gate_table = ok_gt7
  -- owner change seen first by the v6 walk
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  assert(aw.tree_gate_table() ~= nil, "TW7 owner setup (gate-first)")
  S.qm = new_qm()
  clk = clk + 31
  aw.refresh_gates()
  assert(aw.tree_gate_table() == nil and tstat().commits == 0,
    "TW7 v6 walk seeing the new owner first clears the tree state")
  -- ... or by the objective walk
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  assert(aw.tree_gate_table() ~= nil, "TW7 owner setup (objective-first)")
  S.qm = new_qm()
  aw.refresh_objectives()
  assert(aw.tree_gate_table() == nil and tstat().commits == 0,
    "TW7 objective walk seeing the new owner first clears the tree state")
  -- ... or by the session reset
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  assert(aw.tree_gate_table() ~= nil, "TW7 owner setup (session reset)")
  qlm = { call = qlm.call }
  assert(aw.reset_session_caches() == true, "TW7 session reset ran")
  assert(aw.tree_gate_table() == nil and tstat().commits == 0
    and tstat().failed_total == 0, "TW7 session reset clears the tree state")

  -- ---- TW7b: owner change seen FIRST by the tree walk (catalog not ready) ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_ACC, T_CAT)
  aw.refresh_gates()
  aw.refresh_tree_gates()
  assert(aw.gate_qids(T_ACC) ~= nil and aw.tree_gate_table() ~= nil,
    "TW7b both tables committed")
  S.qm = new_qm()
  S.catalog = nil
  A.catalog_ids()                    -- new catalog owner: CATALOG_IDS now nil
  clk = clk + 121
  aw.refresh_tree_gates()
  assert(aw.tree_gate_table() == nil and tstat().commits == 0,
    "TW7b tree walk seeing the new owner first clears the tree state")
  assert(aw.gate_qids(T_ACC) == nil and aw.gate_stats().gated == 0,
    "TW7b ... and the v6 gate table")

  -- ---- TW3b: amortized population (tree analogue of G11) ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  local tmany = {}
  for i = 1, 100 do
    tmany[i] = gproc({ qid = T_CAT, conds = { cstat(40000 + i) } })
  end
  S.procs = tmany
  AN.n = 0
  aw.refresh_tree_gates()
  assert(tstat().commits == 0 and aw.tree_gate_table() == nil
    and AN.n == 80 and tstat().failed_total == 0,
    "TW3b call 1: 80 analyses, round open, nothing committed, no failure")
  aw.refresh_tree_gates()            -- inside the 120 s interval
  assert(tstat().commits == 1 and AN.n == 100
    and #(aw.tree_gate_qids(T_CAT) or {}) == 100,
    "TW3b call 2 inside the interval completes and commits")

  -- ---- TW3c: partial, failed, then inside the interval ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tmany
  aw.refresh_tree_gates()            -- partial: round open
  S.qm_on = false
  aw.refresh_tree_gates()            -- failed (bypasses interval while populating)
  assert(tstat().failed_total == 1, "TW3c failure counted")
  S.qm_on = true
  S.gi = 0
  aw.refresh_tree_gates()
  assert(S.gi == 0 and tstat().commits == 0,
    "TW3c call inside the interval after a failure does not walk (round closed)")

  -- ---- TW4b: zero catalog-dict reads, zero state calls for catalog qids ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, { T_PRG }
  S.ended = { [T_END] = true }
  S.procs = tprocs(T_CAT)
  assert(aw.quest_state(T_END) == "completed", "TW4b ended warmed")
  S.cat_reads, S.state_qids = 0, {}
  aw.refresh_tree_gates()
  assert(tstat().commits == 1 and S.cat_reads == 0,
    "TW4b tree walk reads QuestCatalogDict zero times")
  for _, q in ipairs(TCATALOG) do
    assert(S.state_qids[q] == nil, "TW4b no state-route call for catalog qid " .. q)
  end

  -- ---- TW6b: streak reset by an empty-tracked commit ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = tprocs(T_CAT)
  aw.refresh_tree_gates()
  S.prog_nil = true
  clk = clk + 121 aw.refresh_tree_gates()
  clk = clk + 121 aw.refresh_tree_gates()
  S.prog_nil = false
  S.acc = { T_ACC, T_PRG, T_CAT, T_END }
  clk = clk + 121 aw.refresh_tree_gates()
  local empty_ref = aw.tree_gate_table()
  assert(empty_ref ~= nil and next(empty_ref) == nil and tstat().tracked == 0,
    "TW6b empty-tracked commit installed")
  S.prog_nil = true
  clk = clk + 121 aw.refresh_tree_gates()
  assert(tstat().failed_total == 3 and aw.tree_gate_table() == empty_ref,
    "TW6b streak was reset by the commit: table is the committed one, not a 3-streak drop")

  -- ---- TW5b: round-tried tables are not shared between the walks ----
  tfresh(TCATALOG)
  S.acc, S.prog = { T_ACC }, {}
  S.procs = { gproc({ qid = T_CAT, cls = lst({}, "x", AN) }) }
  AN.n = 0
  aw.refresh_tree_gates()            -- failing analysis, recorded in the tree round
  local an_tree = AN.n
  assert(an_tree >= 1 and tstat().commits == 1, "TW5b tree walk analyzed + committed")
  S.acc = { T_CAT }
  aw.refresh_gates()                 -- must re-analyze: no stale tree-round entry
  assert(AN.n > an_tree, "TW5b v6 walk does not reuse the tree walk's failed analysis")

  qc.gate_table = real_gt
  sdk.get_managed_singleton, os.clock = prev_gms, prev_clock
end
-- v7 task 1: curated quest regions
do
  local expected = {
  [20010] = "Melve",
  [20020] = "Melve",
  [20030] = "Melve",
  [20040] = "Melve",
  [20050] = "Melve",
  [20060] = "Bakbattahl",
  [20070] = "Vernworth",
  [20080] = "Harve",
  [20082] = "Harve",
  [20090] = "Vernworth",
  [20100] = "Melve",
  [20110] = "Vernworth",
  [20120] = "Vernworth",
  [20130] = "Vernworth",
  [20140] = "Vernworth",
  [20150] = "Vernworth",
  [20190] = "Vernworth",
  [20200] = "Checkpoint Rest Town",
  [20220] = "Vernworth",
  [20230] = "Vernworth",
  [20240] = "Vernworth",
  [20250] = "Checkpoint Rest Town",
  [20270] = "Volcanic Island",
  [20280] = "Bakbattahl",
  [20290] = "Bakbattahl",
  [20310] = "Vernworth",
  [20330] = "Bakbattahl",
  [20340] = "Vernworth",
  [20350] = "Checkpoint Rest Town",
  [20360] = "Unmoored",
  [20370] = "Unmoored",
  [20380] = "Unmoored",
  [20390] = "Vernworth",
  [20420] = "Bakbattahl",
  [20440] = "Bakbattahl",
  [20450] = "Sacred Arbor",
  [20460] = "Volcanic Island",
  [20470] = "Volcanic Island",
  [20480] = "Vernworth",
  [30010] = "Vernworth",
  [30040] = "Vernworth",
  [30041] = "Vernworth",
  [30042] = "Vernworth",
  [30050] = "Vernworth",
  [30060] = "Vernworth",
  [30070] = "Vernworth",
  [30080] = "Sacred Arbor",
  [30090] = "Bakbattahl",
  [30100] = "Melve",
  [30110] = "Melve",
  [30120] = "Vernworth",
  [30130] = "Bakbattahl",
  [30140] = "Bakbattahl",
  [30160] = "Checkpoint Rest Town",
  [30170] = "Volcanic Island",
  [30180] = "Vernworth",
  [30200] = "Volcanic Island",
  [30210] = "Checkpoint Rest Town",
  [30220] = "Bakbattahl",
  [30230] = "Vernworth",
  [30240] = "Volcanic Island",
  }
  local n = 0
  for qid, region in pairs(expected) do
    n = n + 1
    assert(a.quest_region(qid) == region, "quest_region " .. qid)
  end
  assert(n == 61, "61 region entries")
  local m = 0
  for _ in pairs(A.QUEST_REGION) do m = m + 1 end
  assert(m == n, "QUEST_REGION holds exactly the pinned entries")
  assert(a.quest_region(99999) == nil)
end

-- ===== v8: quest-item suite (SPEC 15.5b) =====
-- Self-contained world stubs. Four adapter instances: AI (enum fully
-- resolved: More 4, Morethan 5), AH (Morethan unresolved), AM (More
-- unresolved) and the file's original A (loaded with type_stub, so both
-- constants are unresolved).
do
  local function load_instance(enum_fields)
    local prev_ftd = sdk.find_type_definition
    sdk.find_type_definition = function(name)
      if name == "app.quest.condition.LogicalOperatorInt" then
        return { get_field = function(_, f)
          local v = enum_fields[f]
          if v == nil then return nil end
          return { get_data = function() return v end }
        end }
      end
      return type_stub()
    end
    package.loaded["adapter"] = nil
    local inst = require("adapter")
    package.loaded["adapter"] = A
    sdk.find_type_definition = prev_ftd
    return inst
  end
  local AI = load_instance({ More = 4, Morethan = 5 })
  local AH = load_instance({ More = 4 })        -- Morethan unresolved
  local AM = load_instance({ Morethan = 5 })    -- More unresolved
  assert(AI ~= A and AH ~= A and AM ~= A and AI ~= AH and AH ~= AM,
    "four independent instances")

  local HAS = "app.quest.condition.CheckHasItem"
  local IS = { procs = {}, prog = {}, prog_nil = false, qm = nil, qm_on = true,
    im_on = true, dict = nil, icons = {}, icon_fail = {}, gm = nil, gets = {},
    data_calls = 0, dict_reads = 0, cls_reads = 0, loot_reads = 0, started_reads = 0,
    count_reads = 0, drift = 0 }
  local function typed(tn, fields)
    local o = mobj(fields)
    o.get_type_definition = function()
      return { get_full_name = function() return tn end }
    end
    return o
  end
  local function ilist(items, on_count, on_item)
    return { get_field = function() return nil end,
      call = function(_, m, i)
        if m == "get_Count" then
          if on_count then on_count() end
          return #items
        end
        if m == "get_Item" then
          if on_item then on_item() end
          return items[i + 1]
        end
      end }
  end
  -- one CheckHasItem condition; infos = {{id=, num=, lv=}, ...}, an absent
  -- field reads nil
  local function has_item(infos, tn)
    local elems = {}
    for i, it in ipairs(infos) do
      elems[i] = mobj({ _ID = it.id, _Number = it.num, _Logic = it.lv })
    end
    return typed(tn or HAS, { Param = mobj({ _ItemInfoArray = arr(elems) }) })
  end
  -- one CheckDeliver condition; an absent field reads nil, raise_param makes
  -- the _Param read raise
  local function deliver(id, num, lv, raise_param)
    local c = typed("app.quest.condition.CheckDeliver", {})
    if raise_param then
      c.get_field = function(_, n)
        if n == "_Param" then error("param down") end
      end
    else
      c._Param = mobj({ _ItemID = id, _Count = num, _Logic = lv })
    end
    return c
  end
  local iproc_n = 0
  local function iproc(qid, conds, o)
    o = o or {}
    iproc_n = iproc_n + 1
    local p = mobj({
      ["<RefQuestController>k__BackingField"] = mobj({ _QuestID = qid }),
      ProcID = o.procid or (900 + iproc_n),
      ConditionLists = ilist(o.condition_lists or { ilist(conds) },
        function() IS.cls_reads = IS.cls_reads + 1 end),
    })
    p.get_field = function(self, n)
      if n == "ConditionLists" and (o.cls_nil_reads or 0) > 0 then
        o.cls_nil_reads = o.cls_nil_reads - 1   -- a failed read (safe_field nil)
        return nil
      end
      if n == "<IsStarted>k__BackingField" then
        IS.started_reads = IS.started_reads + 1
        if o.unread_started then return nil end
        if o.started == nil then return true end
        return o.started
      end
      return self[n]
    end
    p.call = function(_, m)
      if m == "get_ProcessFinished" then return o.fin == true end
    end
    return p
  end
  local iaddr = 91000
  local function new_iqm()
    iaddr = iaddr + 1
    local addr = iaddr
    return { get_address = function() return addr end,
      get_field = function(_, n)
        if n == "DistributedQuestProcessors" then
          return { get_field = function() return nil end,
            call = function(_, m, i)
              if m == "get_Count" then
                IS.count_reads = IS.count_reads + 1
                return #IS.procs
              end
              if m == "get_Item" then return IS.procs[i + 1] end
            end }
        end
      end,
      call = function() return nil end }
  end
  local iqlm = { call = function(_, m)
    if m == "getProgressingQuestIds" then
      if IS.prog_nil then return nil end
      return mcoll(IS.prog)
    elseif m == "getCurrentTask" then
      return { call = function(_, method)
        if method == "getActiveDestinations" then return mcoll({}) end
      end }
    end
  end,
    get_field = function(_, name)
      if name == "_QuestLogInfoDict" then
        return { call = function(_, method, qid)
          if method == "get_Item" then
            return { call = function(_, method_name)
              if method_name == "get_CurrentTaskIndex" then
                if IS.task_index_unreadable then return nil end
                return IS.task_index or 0
              end
            end }
          end
        end }
      end
    end }
  local function sd(id, num) return mobj({ _ItemId = id, _Num = num }) end
  local function storage(entries)   -- {key=, value=}; value absent = free slot
    local elems = {}
    for i, e in ipairs(entries) do elems[i] = mobj({ key = e.key, value = e.value }) end
    return mobj({ _entries = arr(elems) })
  end
  local iim = { get_field = function() return nil end,
    call = function(_, m, id)
      if m == "getStorageDict" then
        IS.dict_reads = IS.dict_reads + 1
        return IS.dict
      end
      if m == "getItemData(System.Int32)" then
        IS.data_calls = IS.data_calls + 1
        if IS.icon_fail[id] then return nil end
        local d = mobj({ _IconNo = IS.icons[id] })
        if IS.gname and IS.gname[id] then
          d.call = function(_, m) if m == "get_Name" then return IS.gname[id] end end
        end
        return d
      end
    end }
  local function gim(tn, fields, upos, lpos)
    local g = typed(tn, fields)
    local tr = { get_field = function() return nil end, call = function(_, m)
      if m == "get_UniversalPosition" then return upos end
      if m == "get_Position" then return lpos end
    end }
    local go = { get_field = function() return nil end, call = function(_, m)
      if m == "get_Transform" then return tr end
    end }
    g.call = function(_, m) if m == "get_GameObject" then return go end end
    return g
  end
  local function placed(id, upos, lpos, tn)
    return gim(tn or "app.Gm82_000", { ItemId = id, ItemNum = 1 }, upos, lpos)
  end
  local drop_id = 0
  local function drop(id, upos, lpos, deleted, uid, amount)
    drop_id = drop_id + 1
    if uid == nil then uid = string.format("00000000-0000-4000-8000-%012x", drop_id) end
    if amount == nil then amount = 1 end
    local fields = { ItemId = id, MyContext = mobj({ _ItemId = id, _Num = amount }) }
    if deleted ~= "unreadable" then fields["<IsDeleted>k__BackingField"] = deleted == true end
    local out = gim("app.Gm82_000_01", fields, upos, lpos)
    local original_call = out.call
    out.call = function(self, method, ...)
      if method == "get_UniqId" then
        if uid == false then return nil end
        return { call = function(_, name) if name == "ToString()" then return uid end end }
      end
      return original_call(self, method, ...)
    end
    return out
  end
  local function box(ids, upos, lpos)
    local items = {}
    for i, id in ipairs(ids) do items[i] = mobj({ ItemId = id, ItemNum = 1 }) end
    return gim("app.gm80_001", { ItemId = ids[1], ItemList = ilist(items) },
      upos, lpos)
  end
  local function hset(gs)        -- false = free slot
    local elems = {}
    local count, free = 0, 0
    for i, g in ipairs(gs) do
      if g == false then
        elems[i], free = mobj({ next = -2 }), free + 1
      else
        elems[i], count = mobj({ Value = g, next = -1 }), count + 1
      end
    end
    local collection = mobj({ _entries = arr(elems), _count = #elems,
      _freeCount = free })
    collection.call = function(_, method)
      if method == "get_Count" then return count end
    end
    return collection
  end
  local function managed(sets)   -- false = free outer slot
    local elems = {}
    local count, free = 0, 0
    for i, s in ipairs(sets) do
      if s == false then
        elems[i], free = mobj({ next = -2 }), free + 1
      else
        elems[i], count = mobj({ key = i, value = s, next = -1 }), count + 1
      end
    end
    local collection = mobj({ _entries = arr(elems), _count = #elems,
      _freeCount = free })
    collection.call = function(_, method)
      if method == "get_Count" then return count end
    end
    return collection
  end
  local function gmgr(o, access_locked, omit_access)
    local outer = {}
    local raw = o.managed and o.managed._entries and o.managed._entries:get_elements() or {}
    local has_garb = false
    for i = 1, #raw do
      outer[#outer + 1] = raw[i]
      local set = raw[i] and raw[i].value
      local entries = set and set._entries and set._entries:get_elements() or {}
      for _, entry in ipairs(entries) do
        local gimmick = entry and (entry.Value or entry.value) or nil
        if gimmick and gimmick.ItemId == 300 then has_garb = true end
      end
    end
    if has_garb and omit_access ~= true then
      local leaf = mobj({ IsClose = true, IsLock = access_locked == true })
      local leaf_list = ilist({ leaf })
      local pos = { x = 568.247, y = 19.779, z = -1014.327 }
      local transform = { call = function(_, method)
        if method == "get_UniversalPosition" then return pos end
      end }
      local game_object = { call = function(_, method)
        if method == "get_Name" then return "gm05_046" end
        if method == "get_Transform" then return transform end
      end }
      local gate_door = typed("app.gm05_046", { CompDoorList = leaf_list })
      gate_door.call = function(_, method)
        if method == "get_GameObject" then return game_object end
      end
      outer[#outer + 1] = mobj({ key = 74, value = hset({ gate_door }), next = -1 })
    end
    local occupied = 0
    for _, entry in ipairs(outer) do
      if type(entry.next) == "number" and entry.next >= -1 then occupied = occupied + 1 end
    end
    o.managed = mobj({ _entries = arr(outer), _count = #outer,
      _freeCount = #outer - occupied })
    o.managed.call = function(_, method)
      if method == "get_Count" then return occupied end
    end
    return mobj({
      ["<ManagedGimmicksByIDs>k__BackingField"] = o.managed,
      ["<DropItemGimmicks>k__BackingField"] = o.drops and ilist(o.drops,
        function() IS.loot_reads = IS.loot_reads + 1 end) or nil,
      ["<TreasureBoxGimmicks>k__BackingField"] = o.boxes and ilist(o.boxes) or nil,
    })
  end

  local prev_gms, prev_clock = sdk.get_managed_singleton, os.clock
  local iclk = 70000.0
  os.clock = function()
    iclk = iclk + IS.drift
    return iclk
  end
  sdk.get_managed_singleton = function(n)
    IS.gets[n] = (IS.gets[n] or 0) + 1
    if n == "app.QuestManager" then return IS.qm_on and IS.qm or nil end
    if n == "app.QuestLogManager" then return iqlm end
    if n == "app.ItemManager" then return IS.im_on and iim or nil end
    if n == "app.GimmickManager" then return IS.gm end
  end

  local PL, BOXK, PAWN = 2891076981, 65535, 123
  local V = { x = 571.0, y = 19.8, z = -1012.5 }   -- map space (SPEC 15.2d)
  local L = { x = -84.0, y = 11.0, z = 50.0 }      -- transform space
  -- fresh world: A Beggar's Tale (20090) in progress needing item 300
  -- (More 1), garb not held, one placed copy loaded. A new QuestManager
  -- address every time, so the first walk resets the instance's item state.
  local function ifresh()
    iclk = iclk + 1000
    IS.qm = new_iqm()
    IS.qm_on, IS.im_on, IS.prog_nil, IS.drift = true, true, false, 0
    IS.prog = { 20090 }
    IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }) }
    IS.task_index = 0
    IS.dict = storage({ { key = PL, value = ilist({}) } })
    IS.icons = { [300] = 2017 }
    IS.icon_fail = {}
    IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
      drops = {}, boxes = {} })
    IS.gets = {}
    IS.loot_reads = 0
    IS.data_calls, IS.dict_reads, IS.cls_reads = 0, 0, 0
    IS.started_reads, IS.count_reads = 0, 0
  end

  local ai, ah, am, au = AI.make(), AH.make(), AM.make(), A.make()

  -- ---- Task 2 pins ----
  -- NT1 shipped name table
  local nn = 0
  for _ in pairs(A.ITEM_NAMES_BY_ICON) do nn = nn + 1 end
  assert(nn == 334, "NT1 334 icon names")
  assert(A.ITEM_NAMES_BY_ICON[2017] == "Beggar's Garb"
    and A.ITEM_NAMES_BY_ICON[10] == "Apple"
    and A.ITEM_NAMES_BY_ICON[8038] == "Explorer's Camping Kit",
    "NT1 spot entries (apostrophes survive)")
  -- LG1 enum constants by name
  assert(ai.item_stats().logic_ok == true, "LG1 resolved instance: logic ok")
  assert(ah.item_stats().logic_ok == false, "LG1 Morethan missing: unresolved")
  assert(am.item_stats().logic_ok == false, "LG1 More missing: unresolved")
  assert(au.item_stats().logic_ok == false, "LG1 type_stub instance: unresolved")
  -- LG2 no enum literal (Global Constraint 3): the only source of the two
  -- LOGIC_OP keys in adapter.lua is the pair of enum_value reads, and
  -- every LOGIC_OP key assignment uses those locals
  do
    local f = assert(io.open("reframework/autorun/Clairvoyance/adapter.lua", "r"))
    local n, k = 0, 0
    for line in f:lines() do
      local code = line:gsub("%-%-.*$", "")
      for rhs in code:gmatch("local more, morethan%s*=%s*([^=].*)$") do
        n = n + 1
        assert(rhs:match("^enum_value%(lt, \"More\"%), enum_value%(lt, \"Morethan\"%)"),
          "LG2 enum constants read from something other than the type: " .. line)
      end
      for key in code:gmatch("LOGIC_OP%[([^%]]*)%]%s*=") do
        k = k + 1
        assert(key == "more" or key == "morethan",
          "LG2 LOGIC_OP key not from the enum reads: " .. line)
      end
    end
    f:close()
    assert(n == 1 and k == 2, "LG2 exactly one enum_value pair + two LOGIC_OP assignments")
  end
  -- ST1 nothing committed yet
  ifresh()
  assert(ai.item_needs() == nil and #ai.item_locations() == 0
    and ai.item_stats().rounds == 0 and ai.item_stats().needs == 0,
    "ST1 no commit before the first round")
  ;(function()
    ifresh()
    IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
      drops = {}, boxes = {} }, true)
    ai.refresh_items()
    assert(#ai.item_locations() == 0, "locked Garb placement is omitted before item commit")
    ifresh()
    IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
      drops = {}, boxes = {} }, nil, true)
    ai.refresh_items()
    assert(#ai.item_locations() == 1,
      "unknown Garb access preserves the placement before item commit")
    ifresh()
    IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
      drops = {}, boxes = {} })
    ai.refresh_items()
    assert(#ai.item_locations() == 1, "closed and unlocked Garb placement remains available")
  end)()
  ifresh()
  -- NM1-NM4 name cache
  assert(ai.item_name(300) == "Beggar's Garb" and IS.data_calls == 1,
    "NM1 icon route")
  assert(ai.item_name(300) == "Beggar's Garb" and IS.data_calls == 1,
    "NM1 readable icon cached")
  IS.icons[301] = 1                         -- an icon not in the table
  assert(ai.item_name(301) == "Item 301" and ai.item_name(301) == "Item 301"
    and IS.data_calls == 2, "NM2 table miss cached as Item <id>")
  IS.icon_fail[302] = true
  assert(ai.item_name(302) == "Item 302" and ai.item_name(302) == "Item 302"
    and IS.data_calls == 4, "NM3 failed read uncached")
  IS.icon_fail[302] = nil
  IS.icons[302] = mobj({ value__ = 2017 })  -- boxed icon number
  assert(ai.item_name(302) == "Beggar's Garb" and IS.data_calls == 5,
    "NM3 retried next call; boxed icon via int_value")
  IS.gname = { [304] = "Waterfowl Cloak", [305] = "Final Roar" }
  IS.icons[304] = 1                         -- table miss, game name present
  assert(ai.item_name(304) == "Waterfowl Cloak", "NM2b table miss uses get_Name")
  IS.icons[305] = nil                       -- no icon, game name present
  assert(ai.item_name(305) == "Final Roar", "NM2c no icon uses get_Name")
  IS.gname = nil
  IS.im_on = false
  assert(ai.item_name(303) == "Item 303", "NM4 no ItemManager -> fallback")
  IS.im_on = true
  -- NM5 owner change seen by another walk clears the name cache
  local dc = IS.data_calls
  IS.qm = new_iqm()
  pcall(ai.refresh_objectives)
  assert(ai.item_name(300) == "Beggar's Garb" and IS.data_calls == dc + 1,
    "NM5 owner reset registered: name cache cleared")
  -- NM6 session reset clears it too
  ai.reset_session_caches()                 -- primes the session owner
  ai.item_name(300)
  dc = IS.data_calls
  iqlm = { call = iqlm.call, get_field = iqlm.get_field }
  assert(ai.reset_session_caches() == true, "NM6 session reset ran")
  ai.item_name(300)
  assert(IS.data_calls == dc + 1, "NM6 reset_runtime_caches clears the name cache")
  ai.reset_session_caches()
  -- GU1 item UniqId
  local real_gp = A.guid_parse
  A.guid_parse = function(s) return s end
  assert(A.item_marker_guid(300, 0) == "51a1c0de-0000-4001-8000-0000012c0000",
    "GU1 layout: prefix + %08x id + %04x ord")
  assert(A.item_marker_guid(300, 1) ~= A.item_marker_guid(300, 0),
    "GU1 ord distinguishes copies")
  assert(A.marker_guid(300) == "51a1c0de-0000-4000-8000-00000000012c"
    and A.item_marker_guid(300, 0) ~= A.marker_guid(300),
    "GU1 never equal to a quest marker guid for equal numbers")
  assert(A.item_marker_guid(-1, 70000) == "51a1c0de-0000-4001-8000-ffffffff1170",
    "GU1 modulo wrap")
  assert(A.map_marker_guid({ cat = "quest_item", item_id = 300, item_ord = 1,
      qids = { 20090 } }) == "51a1c0de-0000-4001-8000-0000012c0001",
    "GU1 map_marker_guid: item markers take the item prefix")
  assert(A.map_marker_guid({ cat = "in_progress", qids = { 300, 400 } })
      == "51a1c0de-0000-4000-8000-00000000012c",
    "GU1 map_marker_guid: quest markers keep marker_guid(lowest qid)")
  -- world marker UniqId (SPEC 17.4a)
  A.guid_parse = function(s) return s end
  local WG = "51a1c0de-0000-4002-8000-000000000005"
  assert(A.world_marker_guid(5) == WG, "world_marker_guid layout")
  for _, c in ipairs({ "chest", "treasure", "token", "beetle", "monster", "seller" }) do
    local okc, gc = pcall(A.map_marker_guid, { cat = c, world_ord = 5 })
    assert(okc and gc == WG,
      "world cat " .. c .. " takes the world branch")
  end
  local okw, wz = pcall(A.map_marker_guid, { cat = "chest" })
  assert(okw and wz == "51a1c0de-0000-4002-8000-000000000000",
    "world marker without world_ord uses ordinal 0")
  assert(A.map_marker_guid({ cat = "quest_item", item_id = 300, item_ord = 1 })
      == "51a1c0de-0000-4001-8000-0000012c0001", "world branch leaves items")
  assert(A.map_marker_guid({ cat = "in_progress", qids = { 300 } })
      == "51a1c0de-0000-4000-8000-00000000012c", "world branch leaves quests")
  -- v14 marker ids (SPEC 22.6.6)
  do
    local rg = A.map_marker_guid({ cat = "route_stop", cid = 7, stop = 3 })
    assert(A.map_marker_guid({ cat = "route_stop", cid = 7, stop = 2, num = 1 })
        == "51a1c0de-0000-4003-8000-" .. string.format("%012x", 7 * 32 + 1),
      "MG route_stop uses num when set")
    local hg = A.map_marker_guid({ cat = "hint_pin", qid = 20090, i = 1 })
    local qg = A.map_marker_guid({ cat = "in_progress", qids = { 20090 } })
    assert(rg == "51a1c0de-0000-4003-8000-" .. string.format("%012x", 7 * 32 + 3),
      "MG route_stop layout: " .. tostring(rg))
    assert(hg == "51a1c0de-0000-4004-8000-" .. string.format("%012x", 20090 * 32 + 1),
      "MG hint_pin layout: " .. tostring(hg))
    assert(rg ~= hg and rg ~= qg and hg ~= qg, "MG r:, h: and quest guids differ")
    assert(A.map_marker_guid({ cat = "route_stop", cid = 0x7fffffffffff, stop = 9 })
      == "51a1c0de-0000-4003-8000-" .. string.format("%012x",
        (0x7fffffffffff * 32 + 9) % 0x1000000000000), "MG modulo 2^48")
    assert(A.map_marker_guid({ cat = "npc_search", world_ord = 4 })
      == "51a1c0de-0000-4002-8000-000000000004", "MG npc_search keeps the world guid")
    local okn, ng = pcall(A.map_marker_guid, { cat = "focus_npc", cid = 1234, qids = {} })
    local okp, pg = pcall(A.map_marker_guid, { cat = "focus_place", place = 77, qids = {} })
    assert(okn and ng == "51a1c0de-0000-4005-8000-" .. string.format("%012x", 1234),
      "MG focus_npc layout: " .. tostring(ng))
    assert(okp and pg == "51a1c0de-0000-4006-8000-" .. string.format("%012x", 77),
      "MG focus_place layout: " .. tostring(pg))
    assert(ng ~= A.map_marker_guid({ cat = "focus_place", place = 1234, qids = {} }),
      "MG focus_npc and focus_place differ for one number")
    assert(A.map_marker_guid({ cat = "focus_npc", cid = 0x1000000000005, qids = {} })
      == "51a1c0de-0000-4005-8000-000000000005", "MG focus_npc modulo 2^48")
    assert(A.map_marker_guid({ cat = "focus_place", key = "o:p:30040", qid = 30040,
        place = 3004, qids = { 30040 } })
      == "51a1c0de-0000-4007-8000-" .. string.format("%012x", 30040),
      "MG objective destination has a qid-keyed 4007 GUID with a matched place")
    assert(A.map_marker_guid({ cat = "focus_place", key = "o:p:0x1000000000005",
        qid = 0x1000000000005, place = nil, qids = { 0x1000000000005 } })
      == "51a1c0de-0000-4007-8000-000000000005",
      "MG objective destination has the 4007 prefix without a matched place and wraps 48 bits")
    local obj_guid = A.map_marker_guid({ cat = "objective", objective_ordinal = 1 })
    assert(obj_guid == "51a1c0de-0000-4008-8000-000000000001",
      "MG dedicated objective marker uses its target ordinal in 4008")
    assert(A.map_marker_guid({ cat = "objective", objective_ordinal = 1099511627775 })
      == "51a1c0de-0000-4008-8000-00ffffffffff",
      "MG 4008 accepts the complete 40-bit ordinal ceiling")
    for _, ordinal in ipairs({ 0, -1, 1.5, 1099511627776 }) do
      assert(A.map_marker_guid({ cat = "objective", objective_ordinal = ordinal }) == nil,
        "MG rejects out-of-domain 4008 ordinal " .. tostring(ordinal))
    end
    assert(A.map_marker_guid({ cat = "objective" }) == nil,
      "MG rejects a missing 4008 ordinal")
    local same_suffix = {}
    for _, cat in ipairs({ "in_progress", "quest_item", "chest", "route_stop",
        "hint_pin", "focus_npc", "focus_place" }) do
      local marker = { cat = cat, qids = { 1 }, item_id = 1, item_ord = 1,
        world_ord = 1, cid = 0, stop = 1, num = 0, qid = 0, i = 1,
        place = 1 }
      same_suffix[cat] = A.map_marker_guid(marker)
      assert(same_suffix[cat] ~= obj_guid,
        "MG 4008 is disjoint from " .. cat .. " for the same numeric suffix")
    end
  end
  A.guid_parse = real_gp

  -- ---- Task 3 pins (refresh_items) ----
  local function needs_of(inst, qid) return (inst.item_needs() or {})[qid] end
  -- IW1 extraction + commit: the garb row, 20090 -> 300 More 1
  ifresh()
  ai.refresh_items()
  local nd = needs_of(ai, 20090)
  assert(nd ~= nil and #nd == 1 and nd[1].id == 300 and nd[1].num == 1,
    "IW1 need committed")
  local task_snapshot = ai.objective_task_snapshot({ 20090 })
  local need_snapshot = ai.objective_need_groups(task_snapshot)
  assert(need_snapshot.status == "ok" and need_snapshot.complete
    and #need_snapshot.groups == 1 and nd ~= nil and #nd == 1
    and need_snapshot.groups[1].qid == 20090
    and need_snapshot.groups[1].task_index == 0
    and need_snapshot.groups[1].remaining == 1
    and need_snapshot.groups[1].options[1].item_id == 300
    and need_snapshot.groups[1].options[1].accepted_count == 1,
    "IW1 fresh focused legacy need supplies a current-task fallback group")
  ;(function()
  local unrelated_only = ai.objective_need_groups({ need_generation = task_snapshot.need_generation,
    quests = { { qid = 20100, task_index = 0, read_status = "ok", item_ownership = {} } } })
  assert(unrelated_only.status == "ok" and unrelated_only.complete
      and #unrelated_only.groups == 0,
    "IW1 records outside the requested quest set do not invalidate an empty projection")
  local condition_owner = { proof_kind = "condition", eligibility = "eligible",
    item_id = 300, count = 1, task_index = 0, concierge_index = 0,
    destination_index = 0 }
  local function checklist_projection(item_id)
    return { need_generation = task_snapshot.need_generation, quests = { {
      qid = 20090, task_index = 0, read_status = "ok", item_ownership = {
        condition_owner,
        { proof_kind = "delivery", task_index = 0,
          delivery = { is_not = false, check_storage = true, groups = {
            { delivery = { groups = { { index = 0, item_ids = { item_id }, count = 1,
              is_all_item = false, is_infinite = false } } } },
          } } },
      },
    } } }
  end
  local saved_projection_dict = IS.dict
  IS.dict = storage({ { key = PL, value = ilist({ sd(301, 1), sd(302, 1) }) } })
  local dict_reads_before_checklists = IS.dict_reads
  local projection_301 = ai.objective_need_groups(checklist_projection(301))
  local projection_302 = ai.objective_need_groups(checklist_projection(302))
  local projection_301_again = ai.objective_need_groups(checklist_projection(301))
  assert(projection_301.status == "ok" and projection_301.held[301] == 1
      and projection_302.status == "ok" and projection_302.held[302] == 1
      and projection_301_again.status == "ok" and projection_301_again.held[301] == 1,
    "IW1 alternating checklist projections remain readable")
  assert(IS.dict_reads == dict_reads_before_checklists + 2,
    "IW1 checklist held reads cache each generation/signature projection (delta "
      .. tostring(IS.dict_reads - dict_reads_before_checklists) .. ")")
  IS.dict = saved_projection_dict
  end)()
  task_snapshot.quests[1].item_ownership = { {
    proof_kind = "condition", eligibility = "unknown",
    reason = "native_item_condition_leaf_unread", item_id = 300, count = 1,
    task_index = 0, concierge_index = 0, destination_index = 0,
  } }
  need_snapshot = ai.objective_need_groups(task_snapshot)
  assert(need_snapshot.status == "unknown"
    and not need_snapshot.complete and #need_snapshot.groups == 0,
    "IW1 unread native item ownership remains unrouted")
  task_snapshot.quests[1].item_ownership[1].eligibility = "eligible"
  task_snapshot.quests[1].item_ownership[1].reason = nil
  local owned_need_snapshot = ai.objective_need_groups(task_snapshot)
  assert(owned_need_snapshot.status == "ok" and owned_need_snapshot.complete
    and #owned_need_snapshot.groups == 1
    and owned_need_snapshot.groups[1].qid == 20090
    and owned_need_snapshot.groups[1].task_index == 0
    and owned_need_snapshot.groups[1].remaining == 1
    and owned_need_snapshot.groups[1].options[1].item_id == 300
    and type(owned_need_snapshot.held) == "table"
    and (owned_need_snapshot.held[300] or 0) == 0,
    "IW1 exact current concierge item ownership unlocks the matching processor need")
  task_snapshot.quests[1].item_ownership = {}
  -- The loot reader tests below exercise provider behavior independently of
  -- processor-to-task ownership. Supply the proven need snapshot they require.
  ai._test_real_objective_need_groups = ai.objective_need_groups
  ai._test_owned_need_generation = task_snapshot.need_generation
  ai.objective_need_groups = function(snapshot)
    local row = type(snapshot) == "table" and type(snapshot.quests) == "table"
      and snapshot.quests[1] or nil
    if type(row) ~= "table" or row.qid ~= 20090 or row.task_index ~= 0
        or snapshot.need_generation ~= ai._test_owned_need_generation then
      return { status = "unknown", complete = false, groups = {},
        generation = type(snapshot) == "table" and snapshot.need_generation or nil }
    end
    return { status = "ok", complete = true, generation = snapshot.need_generation,
      groups = { { qid = 20090, task_index = 0, remaining = 1,
        options = { { item_id = 300, accepted_count = 1 } } } } }
  end
  local live_drop = drop(300, V, L, false,
    "00000000-0000-4000-8000-000000000101", 2)
  IS.gm = gmgr({ managed = managed({}), drops = { live_drop }, boxes = {} })
  local source_views = ai.objective_item_source_snapshots(nil, task_snapshot)
  local loot_view = source_views[3]
  assert(loot_view.provider == "loot" and loot_view.status == "ok"
    and loot_view.complete and #loot_view.candidates == 1,
    "IW1 current focused loot publishes one complete source")
  local loot_candidate = loot_view.candidates[1]
  assert(loot_candidate.source_id[1] == "source"
    and loot_candidate.source_id[2] == "loot"
    and loot_candidate.source_id[3] == "00000000-0000-4000-8000-000000000101"
    and loot_candidate.outputs[1].item_id == 300 and loot_candidate.outputs[1].count == 2
    and loot_candidate.target.kind == "loot"
    and loot_candidate.target.uid == "00000000-0000-4000-8000-000000000101"
    and loot_candidate.target.pos.x == V.x
    and loot_candidate.capacity_kind == "finite"
    and loot_candidate.available_acquisitions == 1
    and loot_candidate.capacity_pool_id[1] == "capacity"
    and loot_candidate.capacity_pool_id[2] == "loot"
    and loot_candidate.certainty == "guaranteed"
    and loot_candidate.eligibility == "eligible"
    and loot_candidate.evidence.deleted == false
    and loot_candidate.generation == task_snapshot.need_generation,
    "IW1 loot observation carries UID, exact output, position and capacity")
  local native_uid = "00000000-0000-4000-8000-000000000105_0"
  IS.gm = gmgr({ managed = managed({}),
    drops = { drop(300, V, L, false, native_uid, 2) }, boxes = {} })
  iclk = iclk + 0.6
  loot_view = ai.objective_item_source_snapshots(nil, task_snapshot)[3]
  assert(loot_view.status == "ok" and #loot_view.candidates == 1
    and loot_view.candidates[1].target.uid == native_uid
    and loot_view.candidates[1].source_id[3] == native_uid,
    "IW1 native indexed GUID UID is accepted and preserved")
  local duplicate_uid = "00000000-0000-4000-8000-000000000106_0"
  IS.gm = gmgr({ managed = managed({}), drops = {
    drop(999, V, L, true, duplicate_uid, 1),
    drop(300, V, L, false, duplicate_uid, 2) }, boxes = {} })
  iclk = iclk + 0.6
  loot_view = ai.objective_item_source_snapshots(nil, task_snapshot)[3]
  assert(loot_view.status == "unknown" and not loot_view.complete
    and #loot_view.candidates == 0,
    "IW1 duplicate UID across unwanted and deleted rows invalidates loot atomically")
  local loot_count_reads = IS.loot_reads
  ai.objective_item_source_snapshots(nil, task_snapshot)
  assert(IS.loot_reads == loot_count_reads,
    "IW1 repeated snapshot reuses the bounded loot observation")
  IS.gm = gmgr({ managed = managed({}), drops = { live_drop }, boxes = {} })
  live_drop["<IsDeleted>k__BackingField"] = true
  iclk = iclk + 0.6
  loot_view = ai.objective_item_source_snapshots(nil, task_snapshot)[3]
  assert(loot_view.status == "ok" and loot_view.complete
    and #loot_view.candidates == 0, "IW1 collected loot disappears on refresh")
  local function loot_unknown(next_drop, label)
    IS.gm = gmgr({ managed = managed({}), drops = { next_drop }, boxes = {} })
    iclk = iclk + 0.6
    local view = ai.objective_item_source_snapshots(nil, task_snapshot)[3]
    assert(view.status == "unknown" and not view.complete and #view.candidates == 0,
      "IW1 " .. label .. " fails closed without retained loot")
  end
  loot_unknown(drop(300, V, L, false, false, 1), "UID unreadable")
  loot_unknown(drop(300, nil, nil, false, "00000000-0000-4000-8000-000000000102", 1),
    "position unreadable")
  loot_unknown(drop(300, V, L, "unreadable",
    "00000000-0000-4000-8000-000000000103", 1), "deletion state unreadable")
  loot_unknown(drop(300, V, L, false,
    "00000000-0000-4000-8000-000000000104", 0), "nonpositive count")
  local too_many_drops = {}
  for i = 1, 65 do too_many_drops[i] = drop(999, V, L, false) end
  IS.gm = gmgr({ managed = managed({}), drops = too_many_drops, boxes = {} })
  iclk = iclk + 0.6
  loot_view = ai.objective_item_source_snapshots(nil, task_snapshot)[3]
  assert(loot_view.status == "unknown" and loot_view.reason == "loot_rows_truncated"
    and #loot_view.candidates == 0, "IW1 over-limit loot list is unknown")
  local s = ai.item_stats()
  assert(s.needs == 1 and s.ids == 1 and s.located == 1 and s.rounds == 1
    and s.skipped == 0 and s.ignored == 0 and s.failed_total == 0,
    "IW1 stats (rounds re-counted after the owner reset): " .. table.concat({ s.needs,
      s.ids, s.located, s.rounds, s.skipped, s.ignored, s.failed_total }, "/"))
  IS.gm = gmgr({ managed = managed({}), drops = { drop(300, V, L, false) }, boxes = {} })
  iclk = iclk + 0.6
  source_views = ai.objective_item_source_snapshots(nil, task_snapshot)
  assert(#source_views[3].candidates == 1, "IW1 loot is present before task change")
  IS.task_index = 1
  local changed_task = ai.objective_task_snapshot({ 20090 })
  loot_view = ai.objective_item_source_snapshots(nil, changed_task)[3]
  assert(loot_view.status == "unknown" and #loot_view.candidates == 0,
    "IW1 task change invalidates cached loot candidates")
  IS.task_index = 0
  ai.invalidate_items()
  local changed_needs = ai.objective_task_snapshot({ 20090 })
  loot_view = ai.objective_item_source_snapshots(nil, changed_needs)[3]
  assert(loot_view.status == "unknown" and #loot_view.candidates == 0,
    "IW1 need invalidation removes cached loot candidates")
  ai.objective_need_groups = ai._test_real_objective_need_groups
  ai._test_real_objective_need_groups, ai._test_owned_need_generation = nil, nil
  IS.task_index = 1
  changed_task = ai.objective_task_snapshot({ 20090 })
  local invalidated = ai.objective_need_groups(changed_task)
  assert(invalidated.status == "unknown" and not invalidated.complete
    and #invalidated.groups == 0, "IW1 task change immediately invalidates old groups")
  -- A skipped processor row makes the current-objective walk incomplete even
  -- when other rows produced usable groups.
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }),
    iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }, { unread_started = true }) }
  ai.refresh_items()
  local skipped_group_snapshot = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(skipped_group_snapshot.status == "unknown" and not skipped_group_snapshot.complete
    and #skipped_group_snapshot.groups == 0,
    "IW1 skipped processor row empties objective groups")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }) }
  local exact_held = {}
  for i = 1, 512 do exact_held[i] = sd(900 + i, 1) end
  IS.dict = storage({ { key = PL, value = ilist(exact_held) } })
  ai.refresh_items()
  need_snapshot = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(need_snapshot.status == "ok" and need_snapshot.complete
      and #need_snapshot.groups == 1 and need_snapshot.groups[1].options[1].item_id == 300
      and #needs_of(ai, 20090) == 1,
    "IW1 exact held-owner cap retains the focused legacy fallback group")
  local over_held = {}
  for i = 1, 513 do over_held[i] = sd(900 + i, 1) end
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }) }
  IS.dict = storage({ { key = PL, value = ilist(over_held) } })
  ai.refresh_items()
  local over_held_snapshot = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(over_held_snapshot.status == "unknown" and #over_held_snapshot.groups == 0
    and #needs_of(ai, 20090) == 1, "IW1 over-cap held list only invalidates objective groups")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }) }
  IS.dict = storage({ { key = PL, value = ilist({ sd(300, 1), sd(false, 1) }) } })
  ai.refresh_items()
  local unreadable_held_snapshot = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(unreadable_held_snapshot.status == "unknown" and #unreadable_held_snapshot.groups == 0,
    "IW1 unreadable held entry invalidates objective groups")
  ifresh()
  ai.refresh_items()
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  IS.task_index = 1
  ai.objective_task_snapshot({ 20100 })
  IS.task_index = 0
  ai.objective_task_snapshot({ 20100 })
  task_snapshot._unrelated_task_groups = ai.objective_need_groups(task_snapshot)
  assert(task_snapshot._unrelated_task_groups.status == "ok"
      and #task_snapshot._unrelated_task_groups.groups == 1,
    "IW1 unrelated task churn does not invalidate a coherent focused need")
  IS.task_index = 1
  ai.objective_task_snapshot({ 20090 })
  IS.task_index = 0
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  local returned_task_groups = ai.objective_need_groups(task_snapshot)
  assert(returned_task_groups.status == "unknown" and #returned_task_groups.groups == 0,
    "IW1 task change away and back invalidates groups until a fresh item scan")
  iclk = iclk + 10
  ai.refresh_items("needs")
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  assert(ai.objective_need_groups(task_snapshot).status == "ok",
    "IW1 fresh item scan restores the focused legacy fallback")
  IS.task_index_unreadable = true
  ai.objective_task_snapshot({ 20090 })
  IS.task_index_unreadable = false
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  local recovered_task_groups = ai.objective_need_groups(task_snapshot)
  assert(recovered_task_groups.status == "unknown" and #recovered_task_groups.groups == 0,
    "IW1 unreadable task observation invalidates groups until a fresh item scan")
  iclk = iclk + 10
  ai.refresh_items("needs")
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  assert(ai.objective_need_groups(task_snapshot).status == "ok",
    "IW1 fresh item scan restores fallback after task observation recovers")
  IS.task_index = 0
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }),
    deliver(nil, 1, 4) }) }
  ai.refresh_items()
  task_snapshot = ai.objective_task_snapshot({ 20090 })
  need_snapshot = ai.objective_need_groups(task_snapshot)
  assert(need_snapshot.status == "unknown" and not need_snapshot.complete
    and #need_snapshot.groups == 0 and #needs_of(ai, 20090) == 1,
    "IW1 incomplete sibling expression empties objective groups and preserves legacy need")
  ifresh()
  ai.refresh_items()
  IS.prog_nil = true
  iclk = iclk + 10
  ai.refresh_items("needs")
  need_snapshot = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(need_snapshot.status == "unknown" and #need_snapshot.groups == 0,
    "IW1 failed refresh immediately clears objective groups")
  local function other_conditions(n)
    local out = {}
    for _ = 1, n do out[#out + 1] = typed("app.quest.condition.Other", {}) end
    return out
  end
  local function objective_after_lists(outer_count, inner_count)
    ifresh()
    local lists = {}
    if outer_count == 1 then
      lists[1] = ilist(other_conditions(inner_count))
    else
      for i = 1, outer_count do lists[i] = ilist({}) end
    end
    IS.procs = { iproc(20090, {}, { condition_lists = lists }) }
    ai.refresh_items()
    return ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  end
  local exact_inner = objective_after_lists(1, 16)
  assert(exact_inner.status == "ok" and exact_inner.complete
    and #exact_inner.groups == 0, "IW1 exact inner condition limit remains complete")
  local over_inner = objective_after_lists(1, 17)
  assert(over_inner.status == "unknown" and not over_inner.complete
    and #over_inner.groups == 0, "IW1 over-limit inner list empties objective groups")
  local exact_outer = objective_after_lists(16, 0)
  assert(exact_outer.status == "ok" and exact_outer.complete,
    "IW1 exact outer condition limit remains complete")
  local over_outer = objective_after_lists(17, 0)
  assert(over_outer.status == "unknown" and not over_outer.complete
    and #over_outer.groups == 0, "IW1 over-limit outer list empties objective groups")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } },
    "app.quest.condition.CheckHasItemParam") }) }
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil, "IW1 exact full-name type test")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = mobj({ value__ = 300 }),
    num = mobj({ value__ = 1 }), lv = mobj({ value__ = 4 }) } }) }) }
  ai.refresh_items()
  assert(needs_of(ai, 20090) ~= nil and needs_of(ai, 20090)[1].id == 300,
    "IW1 boxed values via int_value")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { num = 1, lv = 4 },
    { id = 301, num = 1, lv = 4 } }) }) }
  ai.refresh_items()
  nd = needs_of(ai, 20090)
  assert(ai.item_stats().skipped == 1 and #nd == 1 and nd[1].id == 301,
    "IW1 nil read skipped + counted, row not kept")
  ifresh()
  IS.procs = { iproc(20090, { deliver(378, 1, 4) }) }
  ai.refresh_items()
  nd = needs_of(ai, 20090)
  assert(nd ~= nil and #nd == 1 and nd[1].id == 378 and nd[1].num == 1
    and ai.item_stats().skipped == 0, "IW1 CheckDeliver yields one row")
  ifresh()
  IS.procs = { iproc(20090, { deliver(nil, 1, 4) }) }
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil and ai.item_stats().skipped == 1,
    "IW1 CheckDeliver nil _ItemID is one skip, no row")
  ifresh()
  IS.procs = { iproc(20090, { deliver(378, 1, 4, true) }) }
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil and ai.item_stats().skipped == 1,
    "IW1 CheckDeliver raising _Param read is one skip")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }),
    deliver(378, 2, 4) }) }
  ai.refresh_items()
  nd = needs_of(ai, 20090)
  assert(#nd == 2 and nd[1].id == 300 and nd[2].id == 378 and nd[2].num == 2
    and ai.item_stats().skipped == 0,
    "IW1 mixed CheckHasItem + CheckDeliver yield both rows")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { num = 1, lv = 4 },
    { id = 301, num = 1, lv = 4 } }) }) }
  ai.refresh_items()
  local r1 = IS.cls_reads
  iclk = iclk + 10
  ai.refresh_items()
  assert(IS.cls_reads == r1 + 1 and ai.item_stats().skipped == 1,
    "IW1 dirty read not cached: re-read next round; skipped is per round")
  ifresh()
  ai.refresh_items()
  r1 = IS.cls_reads
  iclk = iclk + 10
  ai.refresh_items()
  assert(IS.cls_reads == r1 and ai.item_stats().rounds == 2,
    "IW1 clean read cached per ProcID")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) },
    { cls_nil_reads = 1 }) }
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil and ai.item_stats().skipped == 1,
    "IW1 failed ConditionLists read is a counted skip")
  iclk = iclk + 10
  ai.refresh_items()
  assert(needs_of(ai, 20090) ~= nil,
    "IW1 ... never cached as empty: the need appears on the next round")
  ifresh()
  IS.procs = { iproc(20090, {}) }          -- processor without CheckHasItem
  ai.refresh_items()
  local sr = IS.started_reads
  iclk = iclk + 10
  ai.refresh_items()
  assert(IS.started_reads == sr and next(ai.item_needs()) == nil,
    "IW1 empty cached row list: no IsStarted/finished reads")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) },
    { fin = true }) }
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil, "IW1 finished processor contributes nothing")
  local excluded = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(excluded.status == "ok" and excluded.complete and #excluded.groups == 0,
    "IW1 finished processor contributes no current objective group")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) },
    { started = false }) }
  ai.refresh_items()
  excluded = ai.objective_need_groups(ai.objective_task_snapshot({ 20090 }))
  assert(excluded.status == "ok" and excluded.complete and #excluded.groups == 0,
    "IW1 unstarted processor contributes no current objective group")
  ifresh()
  IS.procs = {}
  ai.refresh_items()
  local no_need_task = ai.objective_task_snapshot({ 20090 })
  IS.gm = gmgr({ managed = managed({}), drops = { drop(300, V, L, false) }, boxes = {} })
  local no_need_reads = IS.loot_reads
  loot_view = ai.objective_item_source_snapshots(nil, no_need_task)[3]
  assert(loot_view.status == "ok" and loot_view.complete
    and #loot_view.candidates == 0 and IS.loot_reads == no_need_reads,
    "IW1 no focused item need skips the live loot scan")
  -- IW2 enum by name: Morethan 1 -> 2, Morethan 0 -> 1, Equal ignored
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 5 },
    { id = 301, num = 0, lv = 5 }, { id = 302, num = 1, lv = 2 } }) }) }
  ai.refresh_items()
  nd = needs_of(ai, 20090)
  assert(#nd == 2 and nd[1].id == 300 and nd[1].num == 2 and nd[2].id == 301
    and nd[2].num == 1 and ai.item_stats().ignored == 1,
    "IW2 Morethan by enum value; Equal ignored and counted")
  ifresh()
  au.refresh_items()
  assert(au.item_needs() ~= nil and next(au.item_needs()) == nil
    and au.item_stats().ignored == 1 and au.item_stats().logic_ok == false
    and (IS.gets["app.ItemManager"] or 0) == 0,
    "IW2 unresolved enum: every row other, no needs, no held read")
  ifresh()
  ah.refresh_items()
  assert(next(ah.item_needs()) == nil, "IW2 Morethan unresolved: still no needs")
  ifresh()
  IS.procs = { iproc(20090, { has_item({ { id = 300, num = 1, lv = 5 } }) }) }
  am.refresh_items()
  assert(next(am.item_needs()) == nil, "IW2 More unresolved: still no needs")
  -- IW3 held count
  ifresh()
  IS.dict = storage({ { key = PL, value = ilist({ sd(1, 5) }) },
    { key = BOXK, value = ilist({ sd(300, 1) }) } })
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil,
    "IW3 storage-box copy satisfies the owned-item need")
  ifresh()
  IS.dict = storage({ { key = PL, value = ilist({}) }, { key = 0 },
    { key = PAWN, value = ilist({ sd(300, 1) }) } })
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil and ai.item_stats().skipped == 0,
    "IW3 pawn copy satisfies the need; free slot skipped uncounted")
  ifresh()
  IS.dict = storage({ { value = ilist({ sd(300, 1) }) } })   -- key unreadable
  ai.refresh_items()
  assert(#(needs_of(ai, 20090) or {}) == 1 and ai.item_stats().skipped == 1,
    "IW3 failed entry read skipped + counted")
  local function more2(dict_entries)
    ifresh()
    IS.procs = { iproc(20090, { has_item({ { id = 300, num = 2, lv = 4 } }) }) }
    IS.dict = storage(dict_entries)
    ai.refresh_items()
    return needs_of(ai, 20090)
  end
  assert(more2({ { key = PL, value = ilist({ sd(300, 1) }) },
    { key = PAWN, value = ilist({ sd(300, 1) }) } }) == nil,
    "IW3 copies summed across owners (1 + 1 satisfies More 2)")
  local kept2 = more2({ { key = PL, value = ilist({ sd(300, 1) }) } })
  assert(kept2 ~= nil and kept2[1].num == 2, "IW3 one copy keeps More 2")
  assert(more2({ { key = PL, value = ilist({ sd(300, 2) }) } }) == nil,
    "IW3 a stack counts by _Num")
  -- IW4 failure semantics: keep, keep, 3rd commits {}
  ifresh()
  ai.refresh_items()
  local kept = ai.item_needs()
  IS.dict = nil
  local V2 = { x = 600, y = 20, z = -1000 }
  IS.gm = gmgr({ managed = managed({ hset({ placed(300, V2, L) }) }),
    drops = {}, boxes = {} })
  iclk = iclk + 10
  ai.refresh_items()
  assert(ai.item_needs() == kept and ai.item_stats().failed_total == 1,
    "IW4 unreadable dict = failed round, table kept")
  assert(ai.item_locations()[1].pos.x == V2.x,
    "IW4 scans still run on the committed table after a failed need step")
  IS.dict = mobj({})                       -- no _entries
  iclk = iclk + 10
  ai.refresh_items()
  assert(ai.item_needs() == kept and ai.item_stats().failed_total == 2,
    "IW4 unreadable _entries = failed round")
  IS.im_on = false
  iclk = iclk + 10
  ai.refresh_items()
  assert(ai.item_needs() ~= kept and next(ai.item_needs()) == nil
    and ai.item_stats().failed_total == 3 and #ai.item_locations() == 0,
    "IW4 third consecutive failure commits {} and clears the locations")
  ifresh()
  ai.refresh_items()
  IS.prog_nil = true
  iclk = iclk + 10 ai.refresh_items()
  iclk = iclk + 10 ai.refresh_items()
  IS.prog_nil = false
  iclk = iclk + 10 ai.refresh_items()
  IS.prog_nil = true
  iclk = iclk + 10 ai.refresh_items()
  iclk = iclk + 10 ai.refresh_items()
  assert(#(needs_of(ai, 20090) or {}) == 1 and ai.item_stats().failed_total == 4,
    "IW4 a clean round resets the streak")
  -- IW4b owner change seen first by another walk clears all item state
  ifresh()
  ai.refresh_items()
  assert(ai.item_needs() ~= nil and #ai.item_locations() == 1, "IW4b setup")
  IS.qm = new_iqm()
  pcall(ai.refresh_gates)
  s = ai.item_stats()
  assert(ai.item_needs() == nil and #ai.item_locations() == 0 and s.rounds == 0
    and s.failed_total == 0, "IW4b owner change via the gate walk clears item state")
  r1 = IS.cls_reads
  ai.refresh_items()
  assert(IS.cls_reads == r1 + 1, "IW4b condition cache cleared too")
  -- IW4c session reset clears all item state
  ai.reset_session_caches()
  ifresh()
  ai.refresh_items()
  iqlm = { call = iqlm.call }
  assert(ai.reset_session_caches() == true, "IW4c session reset ran")
  assert(ai.item_needs() == nil and #ai.item_locations() == 0
    and ai.item_stats().rounds == 0, "IW4c reset_runtime_caches clears item state")
  -- IW13 side filter / nothing in progress
  ifresh()
  IS.prog = { 10100 }
  IS.procs = { iproc(10100, { has_item({ { id = 376, num = 1, lv = 4 } }) }) }
  ai.refresh_items()
  assert(ai.item_needs() ~= nil and next(ai.item_needs()) == nil
    and IS.cls_reads == 0 and (IS.gets["app.ItemManager"] or 0) == 0
    and (IS.gets["app.GimmickManager"] or 0) == 0,
    "IW13 main quest excluded: empty table committed, no walk, held or scan")
  -- IW13b a focused main quest reaches the item-needs walk, and clearing the
  -- focus excludes it again
  ifresh()
  IS.prog = { 10100 }
  IS.procs = { iproc(10100, { has_item({ { id = 376, num = 1, lv = 4 } }) }) }
  ai.set_focus_qids({ 10100 })
  ai.refresh_items()
  local hn = (ai.item_needs() or {})[10100]
  assert(hn ~= nil and hn[1].id == 376, "IW13b focused main quest reaches the item walk")
  ai.set_focus_qids(nil)
  ifresh()
  IS.prog = { 10100 }
  IS.procs = { iproc(10100, { has_item({ { id = 376, num = 1, lv = 4 } }) }) }
  ai.refresh_items()
  assert((ai.item_needs() or {})[10100] == nil, "IW13b unfocused excluded again")
  -- IW5 10 s throttle, attempt-start stamp, rounds per attempt
  ifresh()
  ai.refresh_items()
  local c0 = IS.count_reads
  iclk = iclk + 9
  ai.refresh_items()
  assert(IS.count_reads == c0 and ai.item_stats().rounds == 1, "IW5 no round inside 10 s")
  iclk = iclk + 1
  ai.refresh_items()
  assert(IS.count_reads > c0 and ai.item_stats().rounds == 2, "IW5 round at 10 s")
  IS.qm_on = false
  iclk = iclk + 10
  ai.refresh_items()
  assert(ai.item_stats().rounds == 3 and ai.item_stats().failed_total == 1,
    "IW5 a failed attempt is a round")
  IS.qm_on = true
  c0 = IS.count_reads
  iclk = iclk + 5
  ai.refresh_items()
  assert(IS.count_reads == c0 and ai.item_stats().rounds == 3,
    "IW5 a failed round also waits 10 s")
  -- IW6 drop scan every call; deleted drop skipped uncounted
  ifresh()
  ai.refresh_items()
  IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
    drops = { drop(300, { x = 10, y = 1, z = 10 }, { x = 1, y = 1, z = 1 }),
      drop(300, { x = 20, y = 1, z = 20 }, nil, true) }, boxes = {} })
  iclk = iclk + 1
  ai.refresh_items()
  local locs = ai.item_locations()
  assert(#locs == 2 and locs[2].src == "drop" and locs[2].pos.x == 10
    and ai.item_stats().skipped == 0 and ai.item_stats().rounds == 1,
    "IW6 drop scan between rounds; deleted entry skipped uncounted")
  -- IW7 free hash-set slots (outer and inner) are not skipped reads
  ifresh()
  IS.gm = gmgr({ managed = managed({ false, hset({ false, placed(300, V, L), false }) }),
    drops = {}, boxes = {} })
  ai.refresh_items()
  assert(#ai.item_locations() == 1 and ai.item_stats().skipped == 0,
    "IW7 free slots uncounted")
  ifresh()
  do
    local lower_values = mobj({ _entries = arr({
      mobj({ value = placed(300, V, L), next = -1 }) }), _count = 1, _freeCount = 0 })
    lower_values.call = function(_, method) if method == "get_Count" then return 1 end end
    IS.gm = gmgr({ managed = managed({ lower_values }), drops = {}, boxes = {} })
  end
  ai.refresh_items()
  assert(#ai.item_locations() == 1, "IW7 hash-set entry read via the lower-case value fallback")
  -- IW8 invalidate_items
  ifresh()
  IS.drift = 0.001                         -- clock advances per read: last_ms > 0
  ai.refresh_items()
  IS.drift = 0
  assert(ai.item_stats().last_ms > 0, "IW8 setup: a round has wall time")
  ai.item_name(300)
  local dc8, cr8 = IS.data_calls, IS.cls_reads
  ai.invalidate_items()
  s = ai.item_stats()
  assert(ai.item_needs() == nil and #ai.item_locations() == 0 and s.last_ms == 0
    and s.needs == 0 and s.ids == 0 and s.located == 0 and s.rounds == 1,
    "IW8 invalidate clears needs + locations, zeroes last_ms, keeps rounds")
  ai.refresh_items()                       -- same clock: walks anyway
  assert(ai.item_stats().rounds == 2 and IS.cls_reads == cr8
    and needs_of(ai, 20090) ~= nil, "IW8 next call walks; condition cache kept")
  ai.item_name(300)
  assert(IS.data_calls == dc8, "IW8 name cache kept")
  ifresh()
  IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
    drops = { drop(300, nil, L) }, boxes = {} })
  ai.refresh_items()
  assert(ai.item_stats().skipped == 1, "IW8 setup: a drop-scan skip")
  ai.invalidate_items()
  s = ai.item_stats()
  assert(s.skipped == 0 and s.capped == 0, "IW8 invalidate zeroes skipped and capped")
  ifresh()
  ai.refresh_items()
  IS.prog_nil = true
  iclk = iclk + 10 ai.refresh_items()
  iclk = iclk + 10 ai.refresh_items()   -- streak 2
  ai.invalidate_items()
  ai.refresh_items()                     -- streak 1 after the clear, not 3
  assert(ai.item_needs() == nil, "IW8 invalidate clears the failure streak")
  IS.prog_nil = false
  -- IW9 empty need table: no scan; a need going empty clears the sets
  ifresh()
  IS.dict = storage({ { key = PL, value = ilist({ sd(300, 1) }) } })
  ai.refresh_items()
  iclk = iclk + 1
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil and (IS.gets["app.GimmickManager"] or 0) == 0
    and #ai.item_locations() == 0, "IW9 nothing needed: zero scans")
  ifresh()
  ai.refresh_items()
  assert(#ai.item_locations() == 1, "IW9 setup")
  IS.dict = storage({ { key = PL, value = ilist({ sd(300, 1) }) } })
  iclk = iclk + 10
  ai.refresh_items()
  assert(#ai.item_locations() == 0, "IW9 picked up: need and locations gone")
  -- IW10 managed type filter, box record at the box, nil pos / nil live
  ifresh()
  local B = { x = 100, y = 5, z = 100 }
  IS.gm = gmgr({
    managed = managed({ hset({ placed(300, V, L),
      placed(300, { x = 1, y = 1, z = 1 }, L, "app.Gm82_000_01"),
      placed(300, { x = 2, y = 2, z = 2 }, L, "app.gm80_001"),
      placed(301, { x = 3, y = 3, z = 3 }, L),
      placed(300, nil, L),
      placed(300, { x = 4, y = 4, z = 4 }, nil) }) }),
    drops = { drop(300, { x = 9, y = 9, z = 9 }, L), drop(300, nil, L) },
    boxes = { box({ 7, 300 }, B, L), box({ 8 }, { x = 6, y = 6, z = 6 }, L) },
  })
  ai.refresh_items()
  locs = ai.item_locations()
  assert(#locs == 4, "IW10 Gm82_000_01 / gm80_001 / unwanted ignored, nil pos dropped")
  assert(locs[1].src == "placed" and locs[1].id == 300 and locs[1].pos.x == V.x
    and locs[1].live.x == L.x, "IW10 placed: map-space pos, transform-space live")
  assert(locs[2].src == "placed" and locs[2].pos.x == 4 and locs[2].live == nil,
    "IW10 nil live kept")
  assert(locs[3].src == "box" and locs[3].id == 300 and locs[3].pos.x == B.x
    and locs[3].live ~= nil and locs[3].live.x == L.x,
    "IW10 box record at the box position, with its live position")
  assert(locs[4].src == "drop" and locs[4].pos.x == 9, "IW10 order placed, box, drop")
  assert(ai.item_stats().skipped == 2 and ai.item_stats().located == 4,
    "IW10 nil pos (placed and drop) counted as skips; located counts all sets")
  -- IW10b one record per wanted id per box (a duplicate id is one record)
  ifresh()
  IS.gm = gmgr({ managed = managed({}), drops = {},
    boxes = { box({ 300, 300 }, B, L) } })
  ai.refresh_items()
  assert(#ai.item_locations() == 1, "IW10b duplicate id in one box: one record")
  -- IW11 top-level scan failure: keep once, clear on the second
  ifresh()
  ai.refresh_items()
  IS.gm = nil
  iclk = iclk + 10
  ai.refresh_items()
  assert(#ai.item_locations() == 1, "IW11 first top-level failure keeps the set")
  iclk = iclk + 10
  ai.refresh_items()
  assert(#ai.item_locations() == 0, "IW11 second consecutive failure clears it")
  ifresh()
  ai.refresh_items()
  IS.gm = gmgr({ managed = managed({ hset({}) }), drops = {}, boxes = {} })
  iclk = iclk + 10
  ai.refresh_items()
  assert(#ai.item_locations() == 0, "IW11 clean scan without the item removes it")
  -- IW11b a clean scan resets the keep-once flag
  ifresh()
  ai.refresh_items()
  local good_gm = IS.gm
  IS.gm = nil
  iclk = iclk + 10 ai.refresh_items()          -- failure 1: kept
  IS.gm = good_gm
  iclk = iclk + 10 ai.refresh_items()          -- clean: flag reset
  IS.gm = nil
  iclk = iclk + 10 ai.refresh_items()          -- failure again: kept once more
  assert(#ai.item_locations() == 1, "IW11b clean scan resets keep-once")
  -- IW15 an error on a tick that started no round is not a failed round
  ifresh()
  ai.refresh_items()
  local kept15 = ai.item_needs()
  local real_clock = os.clock
  os.clock = function() error("clock down") end
  for _ = 1, 3 do pcall(ai.refresh_items) end
  os.clock = real_clock
  assert(ai.item_needs() == kept15 and ai.item_stats().failed_total == 0,
    "IW15 between-rounds errors do not count toward the 3-failure commit")
  -- IW12 raised builder error propagates and counts as a failed round
  ifresh()
  local qcore = require("Clairvoyance.core")
  local real_nt = qcore.item_need_table
  qcore.item_need_table = function() return 5 end
  assert(pcall(ai.refresh_items) == false and ai.item_stats().failed_total == 1,
    "IW12 bad builder result raises, counted")
  qcore.item_need_table = real_nt
  -- IW14 caps (each counted in `capped`, each list read at most cap times)
  local function many(n, mk)
    local t = {}
    for i = 1, n do t[i] = mk(i) end
    return t
  end
  ifresh()
  IS.gm = gmgr({ managed = managed({ hset(many(4099,
    function() return placed(7, V, L) end)) }), drops = {}, boxes = {} })
  ai.refresh_items()
  assert(ai.item_stats().capped == 3, "IW14 managed scan cap 4096")
  ifresh()
  local drop_reads = 0
  local dl = ilist(many(65, function() return drop(7, V, L) end), nil,
    function() drop_reads = drop_reads + 1 end)
  IS.gm = mobj({ ["<ManagedGimmicksByIDs>k__BackingField"] = managed({}),
    ["<DropItemGimmicks>k__BackingField"] = dl,
    ["<TreasureBoxGimmicks>k__BackingField"] = ilist({}) })
  ai.refresh_items()
  assert(ai.item_stats().capped == 1 and drop_reads == 64, "IW14 drop scan cap 64")
  ifresh()
  IS.gm = gmgr({ managed = managed({}), drops = {},
    boxes = many(67, function() return box({ 7 }, V, L) end) })
  ai.refresh_items()
  assert(ai.item_stats().capped == 3, "IW14 box scan cap 64")
  ifresh()
  local ids17 = many(16, function() return 7 end)
  ids17[17] = 300
  IS.gm = gmgr({ managed = managed({}), drops = {}, boxes = { box(ids17, V, L) } })
  ai.refresh_items()
  assert(ai.item_stats().capped == 1 and #ai.item_locations() == 0,
    "IW14 box item cap 16 (the 17th item is not read)")
  ifresh()
  local owner_reads = 0
  IS.dict = storage({ { key = PL, value = ilist(many(513, function() return sd(1, 1) end),
    nil, function() owner_reads = owner_reads + 1 end) } })
  ai.refresh_items()
  assert(owner_reads == 512, "IW14 held-count owner cap 512")

  -- ---- v14: quest-related items, needs-only round (SPEC 22.10.1) ----
  local nstub = require("Clairvoyance.npcs")
  local function rel_world()
    ifresh()
    IS.prog = { 20090, 20091 }
    IS.procs = {
      iproc(20090, { has_item({ { id = 300, num = 2, lv = 4 } }) }),
      iproc(20091, { has_item({ { id = 300, num = 0, lv = 5 },
        { id = 301, num = 1, lv = 99 } }) }),
    }
    IS.dict = storage({ { key = PL, value = ilist({ sd(300, 2) }) } })
  end
  nstub.override = nil
  rel_world()
  ai.refresh_items()
  assert(next(ai.item_needs()) == nil, "RL1 held 2 satisfies both needs")
  assert(nstub.last[2].qid == 20091 and nstub.last[2].op == "morethan"
    and nstub.last[2].num == 0, "RL1 a morethan record reaches npcs")
  assert(type(nstub.last) == "table" and #nstub.last == 3
    and nstub.last[1].qid == 20090 and nstub.last[1].id == 300
    and nstub.last[1].num == 2 and nstub.last[1].op == "more",
    "RL1 npcs got the raw records")
  local rel = ai.item_related()
  assert(#rel[300] == 2 and rel[301] == nil, "RL1 other op absent, two titles for item 300")
  assert(rel[300][1] == ai.quest_name(20090) and type(rel[300][1]) == "string",
    "RL1 title of the first quest")
  assert(rel[300][2] == (ai.quest_name(20091) or "Quest 20091"), "RL1 second title")
  assert(ai.item_related() == rel, "RL2 cached until the next commit")
  nstub.override = { [300] = { 20090, 20099 } }
  assert(ai.item_related() == rel, "RL2 override does not leak into the cache")
  iclk = iclk + 10
  ai.refresh_items()
  rel = ai.item_related()
  assert(rel[300][2] == "Quest 20099" and ai.quest_name(20099) == nil,
    "RL3 a quest with no name gives Quest <qid>")
  nstub.override = nil
  -- RL3b a raising related_items keeps the previous map and the round counts clean
  rel_world()
  ai.refresh_items()
  local rel3b, fail3b = ai.item_related(), ai.item_stats().failed_total
  local real_ri = nstub.related_items
  nstub.related_items = function() error("npcs down") end
  iclk = iclk + 10
  ai.refresh_items()
  nstub.related_items = real_ri
  assert(ai.item_stats().failed_total == fail3b and #(ai.item_related()[300] or {}) == #rel3b[300],
    "RL3b raise in related_items: round not failed, map kept")
  -- RL4 failed round keeps the table
  rel_world()
  ai.refresh_items()
  local rel4 = ai.item_related()
  IS.dict = nil
  iclk = iclk + 10
  ai.refresh_items()
  assert(ai.item_stats().failed_total == 1 and ai.item_related() == rel4
    and #rel4[300] == 2, "RL4 a failed round keeps the related table")
  -- RL5 third failed round empties it
  iclk = iclk + 10 ai.refresh_items()
  iclk = iclk + 10 ai.refresh_items()
  assert(ai.item_stats().failed_total == 3 and next(ai.item_related()) == nil,
    "RL5 third failed round clears")
  -- RL6 invalidate
  rel_world()
  ai.refresh_items()
  assert(next(ai.item_related()) ~= nil, "RL6 setup")
  ai.invalidate_items()
  assert(next(ai.item_related()) == nil, "RL6 invalidate clears")
  -- RL7 owner reset
  rel_world()
  ai.refresh_items()
  assert(next(ai.item_related()) ~= nil, "RL7 setup")
  IS.qm = new_iqm()
  pcall(ai.refresh_gates)
  assert(next(ai.item_related()) == nil, "RL7 owner reset clears")
  -- RL8 empty wanted set (no side quest in progress)
  rel_world()
  ai.refresh_items()
  IS.prog = { 10100 }
  iclk = iclk + 10
  ai.refresh_items()
  assert(next(ai.item_related()) == nil, "RL8 empty-wanted early return clears")

  -- RS hints-file item quests join the live ones
  rel_world()
  ai.refresh_items()
  ai.set_item_quests({ [310] = { 20090 } })
  assert(ai.quest_name(20090) ~= nil and ai.seen_quest_name(20090) == nil,
    "RS1 setup: a named quest the player has not met")
  assert(ai.item_related()[310][1] == "another quest" and #ai.item_related()[310] == 1,
    "RS1 static only, reveal off: the gate-name rule hides the full name")
  assert(ai.item_related(true)[310][1] == ai.quest_name(20090),
    "RS1 static only, reveal on: the full name")
  assert(ai.item_related()[310][1] == "another quest",
    "RS1 the reveal flag changes the cached titles back")
  ai.set_item_quests({ [300] = { 20090, 20091 } })
  ai.invalidate_items()
  rel_world()
  iclk = iclk + 10
  ai.refresh_items()
  local live1 = ai.item_related()[300]
  assert(#live1 == 2, "RS2 setup: live has two for item 300")
  ai.set_item_quests({ [300] = { 20091, 20077 } })
  local u = ai.item_related()[300]
  assert(#u == 3 and u[1] == live1[1] and u[2] == live1[2] and u[3] == "another quest"
    and ai.quest_name(20077) == nil, "RS2 union: live first, static appended, no repeat")
  ai.set_item_quests({ [311] = { 20090 } })
  assert(ai.item_related()[311] ~= nil and #ai.item_related()[300] == 2,
    "RS3 set_item_quests clears the cache")
  ai.set_item_quests({ [312] = { 20090, 20077 } })
  local two = ai.item_related()[312]
  assert(#two == 1 and two[1] == "another quest",
    "RS5 two unmet quests on one item: one 'another quest', not repeated")
  ai.set_item_quests(nil)
  assert(ai.item_related()[311] == nil, "RS4 nil clears the static map")

  -- RN needs-only round (Ruling 9)
  ifresh()
  ai.refresh_items("needs")
  assert((IS.gets["app.GimmickManager"] or 0) == 0, "RN1 no scan fetch")
  assert(ai.item_needs() ~= nil and ai.item_needs()[20090] ~= nil
    and IS.cls_reads > 0, "RN1 the needs read ran")
  assert(#ai.item_locations() == 0, "RN1 no locations scanned")
  local rc = IS.count_reads
  iclk = iclk + 1
  ai.refresh_items("needs")
  assert(IS.count_reads == rc, "RN2 inside 10 s: no second read")
  ai.reset_item_throttle()
  ai.refresh_items("needs")
  assert(IS.count_reads > rc, "RN3 reset_item_throttle: next call reads at once")
  rc = IS.count_reads
  ai.refresh_items("needs")
  assert(IS.count_reads == rc, "RN3 and only the first of two calls")
  assert((IS.gets["app.GimmickManager"] or 0) == 0, "RN3 still no scan fetch")
  ai.refresh_items()
  assert((IS.gets["app.GimmickManager"] or 0) > 0, "RN4 default mode still scans")

  -- Seed a real adapter-produced current need for the objective task snapshot
  -- tests; the snapshot must join this committed table, not invent ownership.
  local saved_task_gms = sdk.get_managed_singleton
  local function nobj(fields, calls, type_name)
    local o = { fields = fields or {}, calls = calls or {}, type_name = type_name }
    function o.get_field(_, k) return o.fields[k] end
    function o.get_address() return o.address end
    function o.call(_, m, ...)
      local v = o.calls[m]
      if v == "RAISE" then error(m) end
      if type(v) == "function" then return v(...) end
      return v
    end
    function o.get_type_definition()
      return { get_full_name = function() return o.type_name end }
    end
    return o
  end
  local od = nobj({}, { get_DestType = 3, get_CharaID = 101,
    get_KeyLocation = 2308, get_LocalArea = 0, getDestination = { x = 1, y = 2, z = 3 } })
  local ot = nobj({ _Destinations = mcoll({ od }) }, { getActiveDestinations = mcoll({ od }) })
  local og = nobj({ _GuidancePos = nobj({ _Process = nobj({ _KeyLocation = 2308 }, nil,
      "app.GuidanceKeyLocation") }, nil, "app.ClassSelector`1<app.GuidanceData>"),
    _Conditions = mcoll({
    nobj({ _Process = nobj({ _ItemID = 9001, _SetNum = false, _Num = 1,
      _IsEnabled = true, _IsNot = true }, { evaluate = true },
      "app.ConciergeConditionItem") }, nil,
      "app.ClassSelector`1<app.ConciergeConditionBase>"),
    nobj({ _Process = nobj({}, { evaluate = true },
      "app.ConciergeConditionQuestVariable") }, nil,
      "app.ClassSelector`1<app.ConciergeConditionBase>") }) },
    { evaluate = 0, evaluateRegisterCondition = true,
    get_CharaID = 1857826560 })
  og.test_selector = og.fields._Conditions:call("get_element", 0)
  og.test_process = og.test_selector:get_field("_Process")
  local oc = nobj({ _TaskIndex = 0 }, { get_TaskIndex = 0,
    get_Destinations = mcoll({ og }) })
  local oi = nobj({}, { get_CurrentTaskIndex = 0, getCurrentTaskConciergeData = oc })
  local own_resource = nobj({ _ConciergeList = mcoll({ oc }) }, { get_QuestId = 20040 })
  local own_native_catalog = nobj({}, { getCount = 1,
    getValues = arr({ own_resource }) })
  local oq = nobj({ _QuestLogInfoDict = nobj({}, { get_Item = function(q)
    if q == 20040 or q == 20090 then return oi end
  end }), _Catalog = own_native_catalog }, {
    getProgressingQuestIds = function() return mcoll(IS.prog) end,
    getCurrentTask = function(q) if q == 20040 or q == 20090 then return ot end end })
  oq.address = 0x202
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestLogManager" then return oq end
    return saved_task_gms(n)
  end
  ai.objective_task_snapshot({ 20040 }, nil)
  ifresh()
  IS.prog = { 20040 }
  IS.procs = { iproc(20040, { has_item({ { id = 9001, num = 1, lv = 4 } }) }) }
  ai.refresh_items("needs")
  IS._fixture_needs = ai.item_needs()
  assert(IS._fixture_needs ~= nil and IS._fixture_needs[20040] ~= nil
    and IS._fixture_needs[20040][1].id == 9001,
    "objective task fixture has one live unsatisfied item need")
  local own_catalog = { version = 2, sources = {
    { id = "global-source", kind = "placed" },
  }, quests = {} }
  own_catalog.quests[20040] = {
    tasks = { { index = 0, has_destination = false, destinations = {
      { index = 0, set_destination = false, dest_type = 3, cid = 101, key = 2308,
        local_area = 0, has_show_conditions = false, show_conditions = {},
        is_update_condition = false, has_display_conditions = false, display_conditions = {} },
    } } }, guidance = { { index = 0, task_index = 0, destination_index = 0,
      destinations = { { index = 0, cid = nil, target = { kind = "key_location", key = 2308 },
        conditions = {
          { kind = "item", enabled = true, is_not = true, item_id = 9001, set_num = false, num = 1 },
          { kind = "quest_variable", enabled = true, is_not = false, qid = 20040,
            name_hash = 123, value_type = 2, compare_type = 0, bool_value = true, int_value = 0 },
        }, delivery = { is_not = false, check_storage = true, group_id = 3,
          refs = { { qid = 777, key = 2, serial = 2 } } } } } } },
    deliveries = {}, sources = { { id = "fixture-source", kind = "placed" } },
  }
  own_catalog.quests[777] = { deliveries = { { key = 2, serial = 2,
    incomplete_possible = true, operator = 0, groups = { { index = 0,
      item_ids = { 9002 }, count = 1, is_all_item = true, is_infinite = false,
      ignore_restriction_items = {} } } } } }
  local reward_fixture = {}
  reward_fixture.diagnostic = function(qid, proc_id, hash, ordinal)
    return { family = "quest_reward", quest_id = qid,
      action_type = "app.quest.action.QuestReward",
      source_identity = { quest_id = qid, processor_id = proc_id, action_ordinal = ordinal or 0 },
      reward_rows = { { ordinal = 0, name_hash = hash } }, branch_status = "unverified",
      endpoint_evidence = { kind = "single_talk_trigger", reward_root_count = 1,
        reward_operator = "or", reward_operator_value = 1, reward_relation_count = 1,
        reward_child_count = 0, relation_result_no = 0,
        predecessor_processor_id = proc_id + 1000,
        predecessor_action_type = "app.quest.action.Trigger", trigger_parameter_count = 1,
        condition_operator = "and", condition_operator_value = 0, condition_count = 1,
        condition_type = "app.quest.condition.CheckTalkEventEndNoParam",
        talk_event_id = qid, end_no = 0, accept_minus_one = false },
      task_endpoint_join = { status = "unproven",
        reason = "journal_task_to_drawable_reward_endpoint_unverified" },
      unresolved_joins = { "journal_task_to_reward_endpoint", "reward_action_to_drawable_target",
        "current_branch_truth", "claim_state", "runtime_reward_hash_to_item_count" } }
  end
  own_catalog.quests[888] = { reward_diagnostics = { reward_fixture.diagnostic(888, 40, 90) } }
  own_catalog.quests[889] = { reward_diagnostics = { reward_fixture.diagnostic(889, 41, 91) } }
  reward_fixture.scans = { entries = 0, processors = 0, event_nodes = 0 }
  reward_fixture.sequence = function(rows, scan_name)
    return { get_elements = function() return rows end,
      call = function(_, method, index)
        if method == "get_size" then
          if scan_name then reward_fixture.scans[scan_name] = reward_fixture.scans[scan_name] + 1 end
          return #rows
        elseif method == "get_element" then
          if scan_name then
            local key = scan_name .. "_elements"
            reward_fixture.scans[key] = (reward_fixture.scans[key] or 0) + 1
          end
          return rows[index + 1]
        end
      end }
  end
  reward_fixture.managed = function(fields, calls)
    local object = { fields = fields or {}, calls = calls or {} }
    function object.get_field(_, name)
      if object.fields.__graph == true then
        reward_fixture.scans.graph = (reward_fixture.scans.graph or 0) + 1
      end
      return object.fields[name]
    end
    function object.call(_, name, ...)
      local value = object.calls[name]
      if type(value) == "function" then return value(...) end
      return value
    end
    function object.get_address() return object.fields.__address end
    function object.get_type_definition()
      if object.fields.__type ~= nil then
        reward_fixture.scans.type_defs = (reward_fixture.scans.type_defs or 0) + 1
      end
      return { get_full_name = function() return object.fields.__type end }
    end
    return object
  end
  reward_fixture.entries = reward_fixture.sequence({
    reward_fixture.managed({ key = 77, value = reward_fixture.managed({ _ItemList = reward_fixture.sequence({
      reward_fixture.managed({ _ItemId = 9001, _Num = 2 }) }) }), next = -1 }),
    reward_fixture.managed({ next = -2 }),
    reward_fixture.managed({ key = 78, value = reward_fixture.managed({ _ItemList = reward_fixture.sequence({
      reward_fixture.managed({ _ItemId = 9001, _Num = 3 }) }) }), next = -1 }),
  }, "entries")
  reward_fixture.previous_singleton = sdk.get_managed_singleton
  reward_fixture.calls = { get_Count = 2 }
  reward_fixture.reward_dict = reward_fixture.managed({ __address = 0x7700,
    _entries = reward_fixture.entries, _count = 3, _freeCount = 1 }, reward_fixture.calls)
  reward_fixture.manager_address = 0x7710
  reward_fixture.destination = reward_fixture.managed({}, {
    get_DestType = 3, get_CharaID = 101, get_KeyLocation = 2308, get_LocalArea = 0,
    getDestination = function() return { x = 1, y = 2, z = 3 } end })
  reward_fixture.current_task = reward_fixture.managed({
    _Destinations = mcoll({ reward_fixture.destination }) }, {
    getActiveDestinations = function() return mcoll({ reward_fixture.destination }) end })
  reward_fixture.quest_log = reward_fixture.managed({ __address = 0x7740,
    _QuestLogInfoDict = reward_fixture.managed({}, {
      get_Item = function(qid)
        return qid == 20040 and reward_fixture.managed({}, {
          get_CurrentTaskIndex = function() return reward_fixture.current_task_index or 0 end }) or nil
      end }) }, {
    getProgressingQuestIds = function() return reward_fixture.progressing_collection
      or mcoll(reward_fixture.progressing_qids or { 20040 }) end,
    getCurrentTask = function(qid) return qid == 20040 and reward_fixture.current_task or nil end })
  reward_fixture.overlay = {}
  reward_fixture.trigger_action = reward_fixture.managed({}, {
    get_CurrentPhase = function() return reward_fixture.overlay.trigger_action_phase or 1 end,
    get_DoneAction = function() return reward_fixture.overlay.action_done == true end,
    get_CanceledAction = function() return reward_fixture.overlay.action_canceled == true end,
    get_ActionResultNo = function() return reward_fixture.overlay.action_result or 0 end })
  reward_fixture.trigger_action.fields.__type = "app.quest.action.Trigger"
  reward_fixture.trigger_action.fields.__address = 0x7790
  reward_fixture.reward_action = reward_fixture.managed({}, {
    get_CurrentPhase = 2, get_DoneAction = false, get_CanceledAction = false,
    get_ActionResultNo = 0 })
  reward_fixture.reward_action.fields.__type = "app.quest.action.QuestReward"
  reward_fixture.reward_action.fields.__address = 0x7791
  reward_fixture.reward_action_two = reward_fixture.managed({}, {
    get_CurrentPhase = 2, get_DoneAction = false, get_CanceledAction = false,
    get_ActionResultNo = 0 })
  reward_fixture.reward_action_two.fields.__type = "app.quest.action.QuestReward"
  reward_fixture.reward_action_two.fields.__address = 0x7792
  reward_fixture.trigger_process = reward_fixture.managed({ QuestAction = reward_fixture.trigger_action }, {
    get_CurrentPhase = function() return reward_fixture.overlay.process_phase or 1 end,
    get_Executed = function() return reward_fixture.overlay.process_executed == true end,
    get_Canceled = function() return reward_fixture.overlay.process_canceled == true end })
  reward_fixture.reward_process = reward_fixture.managed({ QuestAction = reward_fixture.reward_action }, {
    get_CurrentPhase = 1, get_Executed = false, get_Canceled = false })
  reward_fixture.trigger_process_two = reward_fixture.managed({ QuestAction = reward_fixture.trigger_action }, {
    get_CurrentPhase = function() return reward_fixture.overlay.process_phase or 1 end,
    get_Executed = function() return reward_fixture.overlay.process_executed == true end,
    get_Canceled = function() return reward_fixture.overlay.process_canceled == true end })
  reward_fixture.reward_process_two = reward_fixture.managed({ QuestAction = reward_fixture.reward_action_two }, {
    get_CurrentPhase = 1, get_Executed = false, get_Canceled = false })
  reward_fixture.trigger_processor = reward_fixture.managed({ ProcID = 1040,
    Process = reward_fixture.trigger_process }, {
    get_CurrentPhase = function() return reward_fixture.overlay.trigger_processor_phase or 3 end })
  reward_fixture.reward_processor = reward_fixture.managed({ ProcID = 40,
    Process = reward_fixture.reward_process }, {
    get_CurrentPhase = function() return reward_fixture.overlay.reward_processor_phase or 1 end })
  reward_fixture.trigger_processor_two = reward_fixture.managed({ ProcID = 1042,
    Process = reward_fixture.trigger_process_two }, {
    get_CurrentPhase = function() return reward_fixture.overlay.trigger_processor_phase or 3 end })
  reward_fixture.reward_processor_two = reward_fixture.managed({ ProcID = 42,
    Process = reward_fixture.reward_process_two }, {
    get_CurrentPhase = function() return reward_fixture.overlay.reward_processor_phase or 1 end })
  reward_fixture.processor_list = reward_fixture.sequence({
    reward_fixture.reward_processor, reward_fixture.reward_processor_two,
    reward_fixture.trigger_processor, reward_fixture.trigger_processor_two }, "processors")
  reward_fixture.controller = reward_fixture.managed({ __address = 0x7780,
    _ProcessorFolderController = reward_fixture.managed({ _ProcessorList = reward_fixture.processor_list }) })
  reward_fixture.quest_entity = reward_fixture.managed({ Controller = reward_fixture.controller })
  reward_fixture.entity_dict = reward_fixture.managed({}, {
    get_Item = function(qid) return qid == 20040 and reward_fixture.quest_entity or nil end })
  reward_fixture.reward_root_edge = reward_fixture.managed({ _NextNodeId = "reward-end",
    _NextNodeNameHash = 202, _Conditions = reward_fixture.managed({
      _ConditionList = reward_fixture.sequence({}) }) })
  reward_fixture.reward_root = reward_fixture.managed({ __type = "app.RootSegmentNode",
    __graph = true,
    _NodeId = "reward-root", _NodeNameHash = 201,
    _NextNodesCandidates = reward_fixture.sequence({ reward_fixture.reward_root_edge }) })
  reward_fixture.reward_end = reward_fixture.managed({ __type = "app.EndSegmentNode",
    __graph = true,
    _NodeId = "reward-end", _NodeNameHash = 202, _Result = 0, _IsKeepPreviousResult = false,
    _NextNodesCandidates = reward_fixture.sequence({}) })
  reward_fixture.event_data = reward_fixture.managed({ __address = 0x200400,
    _SegmentNodes = reward_fixture.sequence({ reward_fixture.reward_root, reward_fixture.reward_end }, "event_nodes") })
  reward_fixture.talk_catalog = reward_fixture.managed({}, {
    get_Item = function(event_id)
      return event_id == 20040 and reward_fixture.managed({ _Item = reward_fixture.event_data }) or nil
    end })
  reward_fixture.talk_manager = reward_fixture.managed({
    _ResourceCatalog = reward_fixture.managed({ ["<MergedCatalog>k__BackingField"] = reward_fixture.talk_catalog }),
    _PlayingEventIDList = mcoll({}) }, {
    getTalkEventInitialSpeaker = function()
      if reward_fixture.overlay.initial_speaker_absent then return nil end
      return reward_fixture.overlay.initial_speaker_cid or 101
    end,
    isEventPlayable = function() return reward_fixture.overlay.playable ~= false end,
    getHistory = function()
      if reward_fixture.history_claimed then return reward_fixture.managed({ Played = true, ResultNum = 0 }) end
      if reward_fixture.overlay.history_played ~= nil then
        return reward_fixture.managed({ Played = reward_fixture.overlay.history_played, ResultNum = 0 })
      end
      return nil
    end,
    isTalkEventInteractDisabled = function() return reward_fixture.overlay.interaction_disabled == true end,
    canTalkEventInteract = function() return reward_fixture.overlay.interaction_allowed ~= false end })
  reward_fixture.speaker = reward_fixture.managed({}, {
    get_UniversalPosition = function()
      if reward_fixture.overlay.position_unreadable then return nil end
      return reward_fixture.overlay.position or { x = 1, y = 2, z = 3 }
    end })
  reward_fixture.speaker_holder = reward_fixture.managed({}, {
    get_chara = function() return reward_fixture.speaker end })
  reward_fixture.npc_manager = reward_fixture.managed({ NPCHolderDic = reward_fixture.managed({}, {
    get_Item = function(cid)
      if reward_fixture.overlay.speaker_present == false then return nil end
      if reward_fixture.overlay.initial_speaker_absent then return nil end
      return cid == (reward_fixture.overlay.initial_speaker_cid or 101)
        and reward_fixture.speaker_holder or nil
    end }) })
  reward_fixture.singleton = function(name)
    if name == "app.QuestManager" then return reward_fixture.managed({ __address = reward_fixture.manager_address,
      RewardDict = reward_fixture.reward_dict, EntityDict = reward_fixture.entity_dict }) end
    if name == "app.QuestLogManager" then return reward_fixture.quest_log end
    if name == "app.TalkEventManager" then return reward_fixture.talk_manager end
    if name == "app.NPCManager" then return reward_fixture.npc_manager end
    return reward_fixture.previous_singleton(name)
  end
  reward_fixture.previous_need_groups = ai.objective_need_groups
  own_catalog.quests[890] = { reward_diagnostics = { false } }
  local owned_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  reward_fixture.original_need_generation = owned_snapshot.need_generation
  local owned = owned_snapshot.quests[1].item_ownership
  assert(#owned == 2 and owned[1].item_id == 9001 and owned[1].count == 1
    and owned[1].proof_kind == "condition" and owned[1].eligibility == "eligible"
    and owned[1].task_index == 0
    and owned[1].concierge_index == 0 and owned[1].destination_index == 0,
    "objective task owner accepts one exact true native item leaf beside non-item conditions")
  assert(owned[2].proof_kind == "delivery" and owned[2].eligibility == "unknown"
    and owned[2].delivery.group_id == 3 and owned[2].delivery.check_storage == true
    and #owned[2].delivery.refs == 1 and #owned[2].delivery.groups == 1
    and owned[2].delivery.groups[1].delivery.groups[1].item_ids[1] == 9002,
    "objective task owner preserves delivery groups without promoting their alternatives")
  owned_snapshot._natural_groups = ai.objective_need_groups(owned_snapshot)
  assert(owned_snapshot._natural_groups.status == "ok" and owned_snapshot._natural_groups.complete
    and #owned_snapshot._natural_groups.groups == 1
    and owned_snapshot._natural_groups.groups[1].options[1].item_id == 9001,
    "native item-condition ownership unlocks the matching current need without test injection")
  reward_fixture.prior_storage = IS.dict
  own_catalog.quests[20040].guidance[1].destinations[1].delivery.group_id = 0
  reward_fixture.delivery_group = own_catalog.quests[777].deliveries[1].groups[1]
  reward_fixture.delivery_group.item_ids = { 9002, 9003 }
  reward_fixture.delivery_group.is_all_item = false
  IS.dict = storage({ { key = 65535, value = ilist({ sd(9003, 1) }) },
    { key = PL, value = ilist({ sd(9002, 1) }) } })
  owned_snapshot._alternative_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  owned_snapshot._alternative_needs = ai.objective_need_groups(owned_snapshot._alternative_snapshot)
  assert(owned_snapshot._alternative_needs.status == "ok"
      and owned_snapshot._alternative_needs.complete
      and owned_snapshot._alternative_needs.held[9002] == 1
      and owned_snapshot._alternative_needs.held[9003] == 1
      and type(owned_snapshot._alternative_needs.held_carried) == "table"
      and owned_snapshot._alternative_needs.held_carried[9002] == 1
      and owned_snapshot._alternative_needs.held_carried[9003] == nil,
    "structured delivery alternatives preserve carried and storage-scoped held counts")
  IS.dict = reward_fixture.prior_storage
  IS.prog = { 20040, 20090 }
  IS.procs = {
    iproc(20040, { has_item({ { id = 9001, num = 1, lv = 4 } }) }),
    iproc(20090, { has_item({ { id = 300, num = 1, lv = 4 } }) }),
  }
  iclk = iclk + 10
  sdk.get_managed_singleton = reward_fixture.previous_singleton
  ai.refresh_items("needs")
  owned_snapshot = ai.objective_task_snapshot({ 20040, 20090 }, own_catalog)
  owned_snapshot._mixed = ai.objective_need_groups(owned_snapshot)
  owned = owned_snapshot._mixed.groups
  assert(owned_snapshot._mixed.status == "ok" and owned_snapshot._mixed.complete
      and #owned == 2 and owned[1].qid == 20040 and owned[1].options[1].item_id == 9001
      and owned[2].qid == 20090 and owned[2].options[1].item_id == 300,
    "mixed structured and legacy quests retain both exact current need groups")
  IS.prog = { 20040 }
  IS.procs = { iproc(20040, { has_item({ { id = 9001, num = 1, lv = 4 } }) }) }
  iclk = iclk + 10
  ai.refresh_items("needs")
  owned_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  own_catalog.quests[20040].reward_diagnostics = {
    reward_fixture.diagnostic(20040, 40, 77),
    reward_fixture.diagnostic(20040, 42, 78, 1) }
  own_catalog.quests[888].reward_diagnostics = {}
  own_catalog.quests[889].reward_diagnostics = {}
  own_catalog.quests[890].reward_diagnostics = {}
  og.test_process.calls.evaluate = false
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "ineligible"
    and owned_snapshot._condition_case.item_ownership[1].reason == "native_item_condition_false",
    "a readable false native item leaf remains ineligible")
  og.test_process.calls.evaluate = true
  og.test_process.fields._IsEnabled = false
  own_catalog.quests[20040].guidance[1].destinations[1].conditions[1].enabled = false
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "ineligible"
    and owned_snapshot._condition_case.item_ownership[1].reason
      == "native_item_condition_disabled",
    "a disabled native item leaf remains ineligible even if its evaluator returns true")
  og.test_process.fields._IsEnabled = true
  own_catalog.quests[20040].guidance[1].destinations[1].conditions[1].enabled = true
  og.test_process.fields._IsNot = false
  own_catalog.quests[20040].guidance[1].destinations[1].conditions[1].is_not = false
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "ineligible"
    and owned_snapshot._condition_case.item_ownership[1].reason
      == "native_item_condition_not_missing",
    "a true possession-oriented item leaf does not prove an outstanding acquisition need")
  og.test_process.fields._IsNot = true
  own_catalog.quests[20040].guidance[1].destinations[1].conditions[1].is_not = true
  og.test_process.calls.evaluate = nil
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "unknown"
    and owned_snapshot._condition_case.item_ownership[1].reason
      == "native_item_condition_result_unreadable",
    "an unreadable native item result remains unknown")
  og.test_process.calls.evaluate = true
  og.test_process.fields._ItemID = 9002
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "unknown"
    and owned_snapshot._condition_case.item_ownership[1].reason
      == "native_item_condition_catalog_mismatch",
    "a native item field mismatch remains unknown")
  og.test_process.fields._ItemID = 9001
  og.test_selector.type_name = "app.OtherSelector"
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(owned_snapshot._condition_case.item_ownership[1].eligibility == "unknown"
    and owned_snapshot._condition_case.item_ownership[1].reason
      == "native_item_condition_selector_mismatch",
    "a non-exact native selector type remains unknown")
  og.test_selector.type_name = "app.ClassSelector`1<app.ConciergeConditionBase>"
  own_catalog.quests[20040].guidance[1].destinations[1].conditions[2] = {
    kind = "item", enabled = true, is_not = true, item_id = 9002, set_num = false, num = 1 }
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(#owned_snapshot._condition_case.item_ownership == 1
    and owned_snapshot._condition_case.item_ownership[1].proof_kind == "delivery",
    "multiple item leaves never promote one catalog option")
  own_catalog.quests[20040].guidance[1].destinations[1].conditions = { {
    kind = "quest_variable_or", enabled = true, is_not = false, children = { {
      kind = "item", enabled = true, is_not = true, item_id = 9001,
      set_num = false, num = 1 } } } }
  owned_snapshot._condition_case = ai.objective_task_snapshot({ 20040 }, own_catalog).quests[1]
  assert(#owned_snapshot._condition_case.item_ownership == 1
    and owned_snapshot._condition_case.item_ownership[1].proof_kind == "delivery",
    "an alternative item expression remains unknown and unrouted")
  own_catalog.quests[20040].guidance[1].destinations[1].conditions = { {
    kind = "item", enabled = true, is_not = true, item_id = 9001,
    set_num = false, num = 1 } }
  og.fields._Conditions = mcoll({ og.test_selector })
  owned_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  reward_fixture.original_need_generation = owned_snapshot.need_generation
  sdk.get_managed_singleton = reward_fixture.singleton
  assert(type(ai.objective_reward_catalog_snapshot) == "function",
    "query-independent reward catalog snapshot is exported")
  ;(function()
    local snapshot = ai.objective_reward_catalog_snapshot(own_catalog, 1)
    assert(snapshot.provider == "reward"
        and snapshot.status == "ok"
        and snapshot.complete == true
        and #snapshot.candidates == 0
        and snapshot.source_status.complete == true
        and #snapshot.source_status.rows == 1
        and snapshot.source_status.rows[1].state == "unknown"
        and snapshot.source_status.rows[1].reason_code
          == "reward_current_task_unverified"
        and snapshot.source_status.rows[1].item_ids[1] == 9001
        and #snapshot.registry_entries == 1
        and snapshot.registry_entries[1].source_id[1] == "reward_status_endpoint"
        and snapshot.registry_entries[1].route_capable == false
        and snapshot.registry_entries[1].outputs[1].item_id == 9001
        and snapshot.registry_entries[1].outputs[1].count == 5,
      "inactive reward catalog publishes searchable unknown rows without route candidates")
    local unmatched = ai.objective_reward_catalog_snapshot(own_catalog, 1, {},
      function(item_id) return item_id == 9999 end)
    local matched = ai.objective_reward_catalog_snapshot(own_catalog, 1, {},
      function(item_id) return item_id == 9001 end)
    assert(unmatched.complete and #unmatched.source_status.rows == 0
        and matched.complete and #matched.source_status.rows == 1
        and #matched.matched_item_ids == 1 and matched.matched_item_ids[1] == 9001,
      "reward registry filters off-focus catalog rows by the explicit item query")
  end)()
  ;(function()
    local snapshot = ai.objective_reward_catalog_snapshot(nil, 2)
    assert(snapshot.provider == "reward" and snapshot.status == "unknown"
        and snapshot.complete == false and #snapshot.candidates == 0
        and snapshot.source_status.complete == false
        and #snapshot.source_status.rows == 1
        and snapshot.source_status.rows[1].scope == "provider"
        and snapshot.source_status.rows[1].identity == "provider:reward"
        and snapshot.source_status.rows[1].state == "unknown"
        and snapshot.source_status.rows[1].reason_code == "reward_catalog_unavailable",
      "incomplete reward catalog emits the required provider-scoped unknown row")
  end)()
  do (function()
    local singleton_reads = 0
    sdk.get_managed_singleton = function(name)
      if name == "app.QuestLogManager" or name == "app.QuestManager" then
        singleton_reads = singleton_reads + 1
      end
      return reward_fixture.singleton(name)
    end
    local empty_wanted = ai.read_objective_reward_observation({ false }, {}, nil, nil)
    sdk.get_managed_singleton = reward_fixture.singleton
    assert(empty_wanted.complete and empty_wanted.owner_token == "empty-wanted"
      and singleton_reads == 0 and #empty_wanted.reward_outputs == 0
      and #empty_wanted.progressing_qids == 0,
      "empty reward wanted set returns before QuestLogManager or QuestManager reads")
  end)() end
  ai.objective_need_groups = function()
    return { status = "ok", complete = true, groups = { { options = {
      { item_id = reward_fixture.wanted_id or 9001 } } } } }
  end
  reward_fixture.managed_observation = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77),
      reward_fixture.diagnostic(20040, 42, 78, 1) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(reward_fixture.managed_observation.complete
    and reward_fixture.managed_observation.controllers[1].processors[3].process_completed == false
    and reward_fixture.managed_observation.controllers[1].processors[3].process_canceled == false
    and reward_fixture.managed_observation.controllers[1].processors[3].nested_action_completed == false
    and reward_fixture.managed_observation.controllers[1].processors[3].nested_action_canceled == false,
    "managed processor reads preserve all four readable false frontier flags: "
      .. tostring(reward_fixture.managed_observation.complete) .. "/"
      .. tostring(reward_fixture.managed_observation.reason) .. "/"
      .. tostring(reward_fixture.managed_observation.controllers[1]
        and #reward_fixture.managed_observation.controllers[1].processors) .. "/"
      .. tostring(reward_fixture.managed_observation.controllers[1]
        and reward_fixture.managed_observation.controllers[1].processors[3]
        and reward_fixture.managed_observation.controllers[1].processors[3].process_completed))
  local source_snapshots = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)
  assert(source_snapshots[4].provider == "reward" and source_snapshots[4].status == "ok"
    and source_snapshots[4].complete == true
    and source_snapshots[4].source_status.complete == true
    and #source_snapshots[4].candidates == 1
    and #source_snapshots[4].diagnostic_rows == 0
    and source_snapshots[4].candidates[1].outputs[1].item_id == 9001
    and source_snapshots[4].candidates[1].outputs[1].count == 5
    and #source_snapshots[4].candidates[1].source_id == 13
    and source_snapshots[4].candidates[1].target.cid == 101,
    "managed co-granted rewards union outputs and one capacity through adapter policy: "
      .. tostring(source_snapshots[4].status) .. "/" .. tostring(source_snapshots[4].reason)
      .. "/" .. tostring(#source_snapshots[4].candidates) .. "/"
      .. tostring(source_snapshots[4].candidates[1] and source_snapshots[4].candidates[1].outputs[1]
        and source_snapshots[4].candidates[1].outputs[1].count))
  owned_snapshot.objective_needs = { status = "ok", complete = true,
    generation = owned_snapshot.need_generation, source_generation = owned_snapshot.need_generation,
    groups = { { id = { "need", 20040, 0, 0 }, qid = 20040, task_index = 0,
      remaining = 1, options = { { item_id = 9001, accepted_count = 1 } },
      status = "eligible", complete = true, generation = owned_snapshot.need_generation } } }
  reward_fixture.registry = require("Clairvoyance.core").target_registry_new()
  reward_fixture.core_snapshot = require("Clairvoyance.core").objective_snapshot(
    owned_snapshot, nil, source_snapshots, reward_fixture.registry)
  reward_fixture.routes = require("Clairvoyance.core").objective_routes(
    reward_fixture.core_snapshot, { x = 0, y = 0, z = 0 },
    { objective_places = true, focus_order = { 20040 } })
  reward_fixture.markers = require("Clairvoyance.core").objective_markers(
    {}, {}, reward_fixture.core_snapshot, { objective_places = true, focus_order = { 20040 } })
  reward_fixture.reward_marker_count = 0
  for _, marker in ipairs(reward_fixture.markers) do
    if marker.objective_kind == "source" then
      reward_fixture.reward_marker_count = reward_fixture.reward_marker_count + 1
    end
  end
  assert(#reward_fixture.core_snapshot.targets == 2 and #reward_fixture.routes.members == 1
    and reward_fixture.reward_marker_count == 1,
    "adapter reward output reaches one focused marker and route through the real core")
  reward_fixture.history_claimed = true
  reward_fixture.claimed = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  reward_fixture.claimed_core = require("Clairvoyance.core").objective_snapshot(
    owned_snapshot, nil, { reward_fixture.claimed }, reward_fixture.registry)
  reward_fixture.claimed_routes = require("Clairvoyance.core").objective_routes(
    reward_fixture.claimed_core, { x = 0, y = 0, z = 0 },
    { objective_places = true, focus_order = { 20040 } })
  reward_fixture.claimed_markers = require("Clairvoyance.core").objective_markers(
    {}, {}, reward_fixture.claimed_core, { objective_places = true, focus_order = { 20040 } })
  reward_fixture.claimed_source_markers = 0
  for _, marker in ipairs(reward_fixture.claimed_markers) do
    if marker.objective_kind == "source" then
      reward_fixture.claimed_source_markers = reward_fixture.claimed_source_markers + 1
    end
  end
  assert(#reward_fixture.claimed.candidates == 1
    and reward_fixture.claimed.candidates[1].eligibility == "ineligible"
    and reward_fixture.claimed.candidates[1].outputs[1].count == 5
    and #reward_fixture.claimed_core.targets == 1
    and #reward_fixture.claimed_routes.members == 0
    and reward_fixture.claimed_source_markers == 0,
    "claim-state loss removes adapter reward marker and route atomically: "
      .. tostring(reward_fixture.claimed.status) .. "/" .. tostring(reward_fixture.claimed.reason)
      .. "/" .. tostring(#reward_fixture.claimed.candidates) .. "/"
      .. tostring(reward_fixture.claimed.candidates[1] and reward_fixture.claimed.candidates[1].eligibility)
      .. "/" .. tostring(#reward_fixture.claimed_core.targets) .. "/"
      .. tostring(#reward_fixture.claimed_routes.members) .. "/"
      .. tostring(reward_fixture.claimed_source_markers))
  reward_fixture.history_claimed = false
  source_snapshots[4] = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  reward_fixture.first_generation = source_snapshots[4].generation
  reward_fixture.entries_after_first = reward_fixture.scans.entries
  reward_fixture.processors_after_first = reward_fixture.scans.processors
  reward_fixture.graph_after_first = reward_fixture.scans.graph
  reward_fixture.event_elements_after_first = reward_fixture.scans.event_nodes_elements
  reward_fixture.type_defs_after_first = reward_fixture.scans.type_defs
  reward_fixture.reused = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(#reward_fixture.reused.candidates == 1 and reward_fixture.reused.status == "ok"
    and reward_fixture.scans.entries == reward_fixture.entries_after_first
    and reward_fixture.scans.graph == reward_fixture.graph_after_first
    and reward_fixture.scans.event_nodes_elements == reward_fixture.event_elements_after_first
    and reward_fixture.scans.type_defs == reward_fixture.type_defs_after_first
    and reward_fixture.reused.generation == reward_fixture.first_generation,
    "live overlays reclassify without reopening reward mappings or event graphs: "
      .. tostring(reward_fixture.reused.status) .. "/" .. tostring(reward_fixture.reused.reason)
      .. "/" .. tostring(#reward_fixture.reused.candidates) .. "/"
      .. tostring(reward_fixture.reused.generation) .. "/" .. tostring(reward_fixture.first_generation))
  do (function()
  local original_reward_diagnostics = own_catalog.quests[20040].reward_diagnostics
  own_catalog.quests[20040].reward_diagnostics = false
  local false_array = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(false_array.status == "unknown" and not false_array.complete
      and #false_array.candidates == 0,
    "quest-level malformed reward sentinel reaches the provider atomically")
  own_catalog.quests[20040].reward_diagnostics = { false }
  local false_member = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(false_member.status == "unknown" and not false_member.complete
      and #false_member.candidates == 0,
    "member-level malformed reward sentinel reaches the provider atomically")
  own_catalog.quests[20040].reward_diagnostics = original_reward_diagnostics
  local sentinel_restored = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(sentinel_restored.status == "ok" and sentinel_restored.complete
      and #sentinel_restored.candidates == 1,
    "restoring valid reward diagnostics restores the eligible provider")
  end)() end
  do (function()
  local overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event and overlay_event.playable == true
    and overlay_event.speaker_present == true and overlay_event.history.present == false,
    "reward event overlay baseline has readable playability and speaker presence")
  local overlay_graph_before = reward_fixture.scans.graph
  local overlay_entries_before = reward_fixture.scans.entries
  local overlay_type_defs_before = reward_fixture.scans.type_defs
  reward_fixture.overlay.playable = false
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.playable_readable and overlay_event.playable == false,
    "reward event playability is read fresh")
  reward_fixture.overlay.playable = true
  reward_fixture.overlay.history_played = true
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.history.played_readable and overlay_event.history.played == true,
    "reward event history is read fresh")
  reward_fixture.overlay.history_played = nil
  reward_fixture.overlay.initial_speaker_absent = true
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.initial_speaker_readable and overlay_event.initial_speaker_cid == nil
    and overlay_event.speaker_present_readable and overlay_event.speaker_present == false,
    "reward event distinguishes an absent initial speaker from an unreadable lookup")
  reward_fixture.overlay.initial_speaker_absent = nil
  reward_fixture.overlay.position_unreadable = true
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.speaker.position_readable == false,
    "reward event speaker position is read fresh")
  reward_fixture.overlay.position_unreadable = nil
  reward_fixture.overlay.interaction_disabled = true
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.speaker.interaction_disabled_readable
    and overlay_event.speaker.interaction_disabled == true,
    "reward event reads the disabled interaction gate")
  reward_fixture.overlay.interaction_disabled = nil
  reward_fixture.overlay.interaction_allowed = false
  overlay_event = A.read_objective_talk_grant_observation({}, { 20040 }).events[1]
  assert(overlay_event.speaker.interaction_allowed_readable
    and overlay_event.speaker.interaction_allowed == false,
    "reward event reads the allowed interaction gate")
  reward_fixture.overlay.interaction_allowed = nil
  reward_fixture.overlay.process_phase = 3
  reward_fixture.overlay.trigger_processor_phase = 4
  reward_fixture.overlay.action_result = 2
  local overlay_controller = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(overlay_controller.complete and overlay_controller.controllers[1].processors[3].process_phase == "Executed"
    and overlay_controller.controllers[1].processors[3].processor_phase == "Completed"
    and overlay_controller.controllers[1].processors[3].nested_action_result == 2,
    "reward processor phases and result are read fresh")
  reward_fixture.overlay = {}
  assert(reward_fixture.scans.graph == overlay_graph_before
    and reward_fixture.scans.entries == overlay_entries_before
    and reward_fixture.scans.type_defs == overlay_type_defs_before,
    "event and processor overlays do not rebuild reward mappings or event graphs: "
      .. tostring(reward_fixture.scans.graph) .. "/" .. tostring(overlay_graph_before) .. "/"
      .. tostring(reward_fixture.scans.entries) .. "/" .. tostring(overlay_entries_before))

  local entries_before_manager = reward_fixture.scans.entries
  reward_fixture.manager_address = 0x7711
  local manager_replacement = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(manager_replacement.status == "ok" and #manager_replacement.candidates == 1
    and reward_fixture.scans.entries == entries_before_manager + 1,
    "QuestManager identity change rebuilds reward mappings once")
  reward_fixture.manager_address = 0x7710
  local manager_restored = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(manager_restored.status == "ok" and #manager_restored.candidates == 1,
    "restoring QuestManager identity restores the current reward mapping")
  local entries_before_dict = reward_fixture.scans.entries
  reward_fixture.reward_dict = reward_fixture.managed({ __address = 0x7701,
    _entries = reward_fixture.entries, _count = 3, _freeCount = 1 }, reward_fixture.calls)
  local dict_replacement = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(dict_replacement.status == "ok" and #dict_replacement.candidates == 1
    and reward_fixture.scans.entries == entries_before_dict + 1,
    "RewardDict identity change rebuilds reward mappings once")
  local processor_elements_before_controller = reward_fixture.scans.processors_elements or 0
  local type_defs_before_controller = reward_fixture.scans.type_defs
  reward_fixture.quest_entity.fields.Controller = reward_fixture.managed({ __address = 0x7781,
    _ProcessorFolderController = reward_fixture.managed({ _ProcessorList = reward_fixture.processor_list }) })
  local controller_replacement = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(controller_replacement.complete
    and (reward_fixture.scans.processors_elements or 0) > processor_elements_before_controller
    and reward_fixture.scans.type_defs == type_defs_before_controller + 4
    and reward_fixture.scans.graph == overlay_graph_before,
    "quest controller identity change rebuilds processor structure without rebuilding event graph")
  local original_controller_list = reward_fixture.processor_list
  local processor_elements_before_count = reward_fixture.scans.processors_elements or 0
  local type_defs_before_count = reward_fixture.scans.type_defs
  local extra_action = reward_fixture.managed({ __address = 0x7794 }, { get_CurrentPhase = 2, get_DoneAction = false,
    get_CanceledAction = false, get_ActionResultNo = 0 })
  extra_action.fields.__type = "app.quest.action.Trigger"
  local extra_process = reward_fixture.managed({ QuestAction = extra_action }, {
    get_CurrentPhase = 1, get_Executed = false, get_Canceled = false })
  local extra_processor = reward_fixture.managed({ ProcID = 1050, Process = extra_process }, {
    get_CurrentPhase = 1 })
  reward_fixture.processor_list = reward_fixture.sequence({
    reward_fixture.reward_processor, reward_fixture.reward_processor_two,
    reward_fixture.trigger_processor, reward_fixture.trigger_processor_two,
    extra_processor }, "processors")
  reward_fixture.quest_entity.fields.Controller.fields._ProcessorFolderController.fields._ProcessorList
    = reward_fixture.processor_list
  local processor_count_change = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(processor_count_change.complete and #processor_count_change.controllers[1].processors == 5
    and (reward_fixture.scans.processors_elements or 0) > processor_elements_before_count
    and reward_fixture.scans.type_defs == type_defs_before_count + 5,
    "processor count change rebuilds the structural processor snapshot")
  reward_fixture.processor_list = original_controller_list
  reward_fixture.quest_entity.fields.Controller.fields._ProcessorFolderController.fields._ProcessorList
    = original_controller_list
  local restored_processors = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(restored_processors.complete and #restored_processors.controllers[1].processors == 4,
    "restoring processor count returns the structural snapshot to four processors")
  do (function()
  local original_reward_action = reward_fixture.reward_process.fields.QuestAction
  local swapped_reward_action = reward_fixture.managed({ __address = 0x7793,
    __type = "app.quest.action.Trigger" }, {
    get_CurrentPhase = 2, get_DoneAction = false, get_CanceledAction = false,
    get_ActionResultNo = 0 })
  local type_defs_before_action_swap = reward_fixture.scans.type_defs
  reward_fixture.reward_process.fields.QuestAction = swapped_reward_action
  local swapped_action = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  local swapped_type
  for _, processor in ipairs(swapped_action.controllers[1] and
      swapped_action.controllers[1].processors or {}) do
    if processor.processor_id == 40 then swapped_type = processor.quest_action_type end
  end
  assert(swapped_action.complete and swapped_type == "app.quest.action.Trigger"
      and reward_fixture.scans.type_defs > type_defs_before_action_swap,
    "same-count action replacement rebuilds the processor type structure immediately")
  reward_fixture.reward_process.fields.QuestAction = original_reward_action
  local restored_action = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  local restored_action_type
  for _, processor in ipairs(restored_action.controllers[1] and
      restored_action.controllers[1].processors or {}) do
    if processor.processor_id == 40 then restored_action_type = processor.quest_action_type end
  end
  assert(restored_action.complete and restored_action_type == "app.quest.action.QuestReward",
    "restoring the action object restores the reward processor type")
  end)() end
  reward_fixture.progressing_qids = { 20040, 20041 }
  local progressing_change = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(progressing_change.complete and #progressing_change.progressing_qids == 2
    and progressing_change.progressing_qids[2] == 20041,
    "progressing quest ID changes are observed in the structural snapshot")
  reward_fixture.progressing_qids = nil
  do (function()
    local progressing_rows = {}
    for i = 1, 65 do progressing_rows[i] = 21000 + i end
    reward_fixture.scans.progressing = 0
    reward_fixture.progressing_collection = reward_fixture.sequence(progressing_rows, "progressing")
    local progressing_bounded = ai.read_objective_reward_observation(
      { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
      owned_snapshot, own_catalog.quests)
    assert(not progressing_bounded.complete and progressing_bounded.reason == "progressing_set_truncated"
      and (reward_fixture.scans.progressing_elements or 0) == 0,
      "progressing managed IDs are capped before collection materialization: "
        .. tostring(progressing_bounded.complete) .. "/" .. tostring(progressing_bounded.reason)
        .. "/" .. tostring(reward_fixture.scans.progressing_elements))
    reward_fixture.progressing_collection = nil
  end)() end
  do (function()
    local many_rows, many_catalog = {}, {}
    for i = 1, 65 do
      local qid = 21000 + i
      many_rows[i] = reward_fixture.diagnostic(qid, 40, 77)
      many_catalog[qid] = own_catalog.quests[20040]
    end
    reward_fixture.progressing_qids = {}
    local processor_reads = reward_fixture.scans.processors
    local graph_reads = reward_fixture.scans.graph
    local bounded = ai.read_objective_reward_observation(many_rows, { [9001] = true },
      owned_snapshot, many_catalog)
    assert(bounded.complete and #bounded.progressing_qids == 0 and #bounded.tasks == 0
      and #bounded.controllers == 0 and #bounded.events == 0
      and reward_fixture.scans.processors == processor_reads
      and reward_fixture.scans.graph == graph_reads,
      "nonprogressing relevant catalog rows exceed no live-read or 64-qid budget")
    local classified = A.reward_sources.classify(many_rows, bounded, 4)
    assert(classified.complete and #classified.candidates == 0
      and #classified.source_status.rows == 65
      and classified.source_status.rows[1].reason_code == "quest_not_progressing",
      "nonprogressing reward members retain candidate-local status without live task reads")
    reward_fixture.progressing_qids = nil
  end)() end
  do (function()
  local task_target_before = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  own_catalog.quests[20040].tasks[1].destinations[1].cid = 102
  reward_fixture.destination.calls.get_CharaID = 102
  local changed_task_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  local task_target_changed = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    changed_task_snapshot, own_catalog.quests)
  assert(task_target_before.complete and task_target_changed.complete
    and task_target_changed.tasks[1].targets[1].cid == 102,
    "task target mutation is read into a fresh reward structure")
  local stale_target_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  stale_target_snapshot.quests[1].task_destinations[1].target.cid = 101
  local mixed_target = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    stale_target_snapshot, own_catalog.quests)
  assert(not mixed_target.complete and mixed_target.reason == "current_task_changed",
    "same-index task target mismatch cannot mix reward and objective snapshots")
  stale_target_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  local place_identity_changed = false
  for _, destination in ipairs(stale_target_snapshot.quests[1].task_destinations) do
    if destination.kind == "place" and type(destination.target.place) == "table" then
      destination.target.place.key = destination.target.place.key + 1
      place_identity_changed = true
    end
  end
  local mixed_place = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    stale_target_snapshot, own_catalog.quests)
  assert(place_identity_changed and not mixed_place.complete
    and mixed_place.reason == "current_task_changed",
    "same-index place key mismatch cannot mix reward and objective snapshots")
  own_catalog.quests[20040].tasks[1].destinations[1].cid = 101
  reward_fixture.destination.calls.get_CharaID = 101
  local task_target_restored = ai.read_objective_reward_observation(
    { reward_fixture.diagnostic(20040, 40, 77) }, { [9001] = true },
    owned_snapshot, own_catalog.quests)
  assert(task_target_restored.complete and task_target_restored.tasks[1].targets[1].cid == 101,
    "restoring task target returns the original reward structure")
  end)() end
  local before_wanted_change = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  reward_fixture.wanted_id = 9002
  local wanted_change = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(wanted_change.generation > before_wanted_change.generation
    and #wanted_change.candidates == 0,
    "wanted-set mutation invalidates the cached reward classification")
  reward_fixture.wanted_id = nil
  local wanted_restored = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(wanted_restored.status == "ok" and #wanted_restored.candidates == 1,
    "restoring wanted IDs restores the verified reward candidate")
  local before_catalog_change = wanted_restored
  local catalog_join = own_catalog.quests[20040].reward_diagnostics[1].unresolved_joins
  local old_join = catalog_join[1]
  catalog_join[1] = old_join .. "_changed"
  local catalog_changed = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(catalog_changed.generation > before_catalog_change.generation,
    "catalog evidence signature mutation invalidates the cached reward classification")
  catalog_join[1] = old_join
  local catalog_restored = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(catalog_restored.status == "ok" and #catalog_restored.candidates == 1,
    "restoring catalog evidence restores the verified reward candidate")
  own_catalog.quests[20041] = { reward_diagnostics = {
    reward_fixture.diagnostic(20041, 43, 99) } }
  reward_fixture.missing_mapping = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(reward_fixture.missing_mapping.status == "unknown"
    and #reward_fixture.missing_mapping.candidates == 0,
    "nonfocused reward with a missing runtime mapping fails closed")
  own_catalog.quests[20041] = nil
  reward_fixture.entries_after_first = reward_fixture.scans.entries
  reward_fixture.processors_after_first = reward_fixture.scans.processors
  reward_fixture.graph_after_first = reward_fixture.scans.graph
  reward_fixture.event_elements_after_first = reward_fixture.scans.event_nodes_elements
  reward_fixture.type_defs_after_first = reward_fixture.scans.type_defs
  end)() end
  owned_snapshot.quests[1].task_index = owned_snapshot.quests[1].task_index + 1
  reward_fixture.current_task_index = 1
  reward_fixture.changed_task = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(reward_fixture.changed_task.status == "unknown" and #reward_fixture.changed_task.candidates == 0
    and reward_fixture.changed_task.generation > reward_fixture.first_generation,
    "task change invalidates the reward endpoint before publishing a stale target")
  owned_snapshot.quests[1].task_index = owned_snapshot.quests[1].task_index - 1
  reward_fixture.current_task_index = 0
  reward_fixture.restored_task = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(reward_fixture.restored_task.status == "ok" and #reward_fixture.restored_task.candidates == 1,
    "restoring the live task restores its verified reward source")
  reward_fixture.graph_before_replacement = reward_fixture.scans.graph
  reward_fixture.event_data = reward_fixture.managed({ __address = 0x200401,
    _SegmentNodes = reward_fixture.sequence({ reward_fixture.reward_root, reward_fixture.reward_end }, "event_nodes") })
  local replaced_event = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  reward_fixture.graph_after_replacement = reward_fixture.scans.graph
  reward_fixture.same_event = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(replaced_event.status == "ok" and #replaced_event.candidates == 1
    and reward_fixture.graph_after_replacement > reward_fixture.graph_before_replacement
    and reward_fixture.scans.graph == reward_fixture.graph_after_replacement
    and reward_fixture.same_event.generation == replaced_event.generation,
    "event resource replacement triggers one graph rebuild, then reuses the new graph")
  local graph_before_overlay = reward_fixture.scans.graph
  reward_fixture.overlay.process_executed = true
  reward_fixture.overlay_changed = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(#reward_fixture.overlay_changed.candidates == 1
    and reward_fixture.overlay_changed.candidates[1].eligibility == "unknown"
    and reward_fixture.scans.graph == graph_before_overlay
    and reward_fixture.scans.entries == reward_fixture.entries_after_first,
    "processor live-state change reclassifies without a structural rescan")
  reward_fixture.overlay.process_executed = nil
  owned_snapshot.need_generation = owned_snapshot.need_generation + 1
  reward_fixture.changed_need = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(reward_fixture.changed_need.status == "ok" and #reward_fixture.changed_need.candidates == 1,
    "a fresh complete need generation is classified against the same live reward graph")
  reward_fixture.calls.get_Count = 1
  owned_snapshot.need_generation = owned_snapshot.need_generation + 1
  reward_fixture.malformed = ai.objective_item_source_snapshots(own_catalog, owned_snapshot)[4]
  assert(reward_fixture.malformed.status == "unknown" and #reward_fixture.malformed.candidates == 0
    , "inconsistent RewardDict count fails closed during the immediate structural refresh")
  reward_fixture.calls.get_Count = 2
  own_catalog.quests[20040].reward_diagnostics = {
    reward_fixture.diagnostic(20040, 40, 77),
    reward_fixture.diagnostic(20040, 42, 78, 1) }
  ai.objective_need_groups = function()
    return { status = "ok", complete = true, groups = {} }
  end
  owned_snapshot.need_generation = owned_snapshot.need_generation + 1
  iclk = iclk + 0.6
  reward_fixture.empty_reward = ai.objective_item_source_snapshots(
    own_catalog, owned_snapshot)[4]
  assert(reward_fixture.empty_reward.status == "ok" and reward_fixture.empty_reward.complete
    and #reward_fixture.empty_reward.candidates == 0
    and #reward_fixture.empty_reward.source_status.rows == 0,
    "a complete empty need set publishes no stale reward candidate")
  ai.objective_need_groups = function()
    return { status = "unknown", complete = false, groups = {} }
  end
  reward_fixture.unknown_need = ai.objective_item_source_snapshots(
    own_catalog, owned_snapshot)[4]
  assert(reward_fixture.unknown_need.reason == "reward_observation_incomplete"
    and #reward_fixture.unknown_need.diagnostic_rows == 0,
    "loss of need-set completeness invalidates cached reward classification")
  own_catalog.quests[20040].reward_diagnostics = nil
  owned_snapshot.need_generation = reward_fixture.original_need_generation
  ai.objective_need_groups = reward_fixture.previous_need_groups
  sdk.get_managed_singleton = reward_fixture.previous_singleton
  assert(#source_snapshots == 6 and source_snapshots[1].provider == "placed"
    and source_snapshots[2].provider == "chest" and source_snapshots[3].provider == "loot"
    and source_snapshots[1].status == "unknown"
    and source_snapshots[1].complete == false
    and source_snapshots[1].reason == "source_catalog_unavailable"
    and source_snapshots[2].complete == false
    and source_snapshots[2].reason == "source_catalog_unavailable"
    and source_snapshots[4].provider == "reward"
    and source_snapshots[4].status == "ok"
    and source_snapshots[4].complete == true
    and source_snapshots[4].reason == nil
    and #source_snapshots[4].candidates == 1
    and source_snapshots[4].generation > 0
    and source_snapshots[5].provider == "talk_grant"
    and source_snapshots[5].status == "unknown"
    and source_snapshots[5].complete == false
    and source_snapshots[5].reason == "talk_grant_catalog_unreadable"
    and #source_snapshots[5].candidates == 0
    and source_snapshots[5].generation > 0
    and source_snapshots[6].provider == "forgery"
    and source_snapshots[6].status == "unknown"
    and source_snapshots[6].reason == "forgery_service_catalog_unreadable"
    and #source_snapshots[6].candidates == 0
    and source_snapshots[6].generation > 0
    and source_snapshots[1].generation > 0
    and source_snapshots[1].catalog_version == 2
    and #source_snapshots[1].source_descriptors == 2
    and source_snapshots[1].source_descriptors[1].qid == nil
    and source_snapshots[1].source_descriptors[1].source.id == "global-source"
    and source_snapshots[1].source_descriptors[2].qid == 20040
    and source_snapshots[1].source_descriptors[2].source.id == "fixture-source"
    and source_snapshots[1].source_descriptors ~= source_snapshots[2].source_descriptors
    and #source_snapshots[1].signal_evidence > 0
    and #source_snapshots[1].guidance_delivery_refs > 0,
    "objective item source snapshots are generation-tagged unknown envelopes with evidence")
  owned_snapshot = ai.objective_task_snapshot({ 20040 }, own_catalog)
  local owned_repeat = ai.objective_task_snapshot({ 20040 }, own_catalog)
  assert(owned_repeat.focus_epoch == owned_snapshot.focus_epoch
    and owned_repeat.journal_generation == owned_snapshot.journal_generation
    and owned_repeat.need_generation == owned_snapshot.need_generation,
    "objective task generations are stable for identical native and need input")
  ai.item_needs()[20040][1].num = 3
  local need_changed = ai.objective_task_snapshot({ 20040 }, own_catalog)
  assert(need_changed.journal_generation == owned_repeat.journal_generation
    and need_changed.need_generation == owned_repeat.need_generation + 1,
    "need input advances only need_generation, not journal_generation")
  ai.item_needs()[20040][1].num = 1
  local fresh_before_failure = ai.objective_task_snapshot({ 20040 }, own_catalog)
  IS.dict = nil
  iclk = iclk + 10
  ai.refresh_items("needs")
  local failed_need_refresh = ai.objective_task_snapshot({ 20040 }, own_catalog)
  assert(ai.item_needs()[20040] ~= nil
    and failed_need_refresh.need_generation == fresh_before_failure.need_generation + 1,
    "objective need freshness advances on failed refresh while legacy need data is retained")
  rel_world()
  ai.refresh_items("needs")
  sdk.get_managed_singleton = saved_task_gms

  sdk.get_managed_singleton, os.clock = prev_gms, prev_clock
end

-- v9 journal readers (SPEC 16.3a, 16.6a): userdata-vector fakes (arr),
-- a counted Guid resolver, explicit overload strings.
do
  local prev_gms, prev_ftd, prev_v3 = sdk.get_managed_singleton,
    sdk.find_type_definition, Vector3f
  local TEXT = { g_base = "Determine Malcolm's location.", g_det = "A boy is missing.",
    g_chk = "Ask around", g_cap = "Slums", g_empty = "", g_s1 = "Step one",
    g_s2 = "Step two", g_rej = "#Rejected# cut", g_sum = "Catalog summary", g_name = "Brant" }
  local msg_calls, msg_sigs = 0, {}
  local function guid(id)
    return { call = function(_, m) if m == "ToString()" then return id end end }
  end
  -- The game's own journal map position per view (nothing for a view with no
  -- active destination: the real method would return the player position).
  local QPOS = { by_view = {}, missing = false, raise = false }
  sdk.find_type_definition = function(n)
    if n == "via.gui.message" then
      return { get_method = function(_, sig)
        msg_sigs[#msg_sigs + 1] = sig
        return { call = function(_, o, g)
          assert(o == nil, "message.get is static")
          msg_calls = msg_calls + 1
          return TEXT[g:call("ToString()")]
        end }
      end }
    end
    if n == "app.ui060502_2" then
      return { get_method = function(_, sig)
        if QPOS.missing or sig ~= "<moveToMap>g__getDefaultQuestPos|124_0" then return nil end
        return { call = function(_, o, view)
          assert(o == nil, "getDefaultQuestPos is static (nil this)")
          if QPOS.raise then error("getDefaultQuestPos") end
          return QPOS.by_view[view]
        end }
      end }
    end
    return prev_ftd(n)
  end
  Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z, v3 = true } end }
  -- fake managed object: fields by name; calls[m] = value or function(...)
  local function obj(fields, calls, addr)
    local o = { sets = {}, log = {} }
    function o.get_field(_, n)
      local f = fields[n]
      if f == "RAISE" then error("field " .. n) end
      return f
    end
    function o.set_field(_, n, v) o.sets[n] = v end
    function o.get_address() return addr or 0x1000 end
    function o.call(_, m, ...)
      o.log[#o.log + 1] = { m, ... }
      local c = calls and calls[m]
      if c == "RAISE" then error("call " .. m) end
      if type(c) == "function" then return c(...) end
      return c
    end
    return o
  end

  local task = obj({ _CheckList = arr({ obj({ _BaseMsg = guid("g_chk") }, { evaluate = true }),
      obj({ _BaseMsg = guid("g_empty") }, { evaluate = false }) }) },
    { get_BaseMsg = guid("g_base"), get_DetailMsg = guid("g_det"),
      getActiveDestinations = arr({
        obj({ _MsgId = guid("g_cap") }, { getDestination = { x = 1110.1, y = 9.26, z = -1976.98 } }),
        obj({ _MsgId = guid("g_s1") }, { getDestination = { x = 0, y = 0, z = 0 } }) }) })
  local task_bare = obj({ _CheckList = "RAISE" }, { get_BaseMsg = guid("g_base"),
    get_DetailMsg = guid("g_empty"), getActiveDestinations = arr({}) })
  local views = {
    [20120] = obj({ QuestName = "The Heel of History", QuestSummary = "Orphans." },
      { get_Task = task }),
    [20130] = obj({ QuestName = "Bare", QuestSummary = "" }, { get_Task = task_bare }),
    [20140] = obj({ QuestName = "Broken" }, { get_Task = "RAISE" }),
  }
  QPOS.by_view[views[20120]] = { x = 113.9, y = 156.2, z = -2128.9 }
  QPOS.by_view[views[20130]] = { x = 5, y = 5, z = 5 }   -- the player position
  local infos = { [20120] = obj({}, { get_CurrentTaskIndex = 2 }) }
  local dict = obj({}, { get_Item = function(q)
    if infos[q] == nil then error("KeyNotFound") end
    return infos[q]
  end })
  local values_calls = 0
  local function res(qid, steps)
    local ts = {}
    for i, s in ipairs(steps) do
      ts[i] = obj({}, { get_BaseMsg = guid(s), get_DetailMsg = guid("g_empty") })
    end
    return obj({}, { get_QuestId = qid, get_Summary = guid("g_sum"), get_TaskList = arr(ts) })
  end
  local cat_count = 2
  local catalog = obj({}, { getCount = function() return cat_count end,
    getValues = function()
      values_calls = values_calls + 1
      return arr({ res(20120, { "g_s1", "g_s2" }), res(10030, { "g_s1" }),
        res(20150, { "g_s1", "g_rej", "g_s2" }) })
    end })
  local qlm_addr = 0x1000
  local qlm = obj({ _QuestLogInfoDict = dict, _Catalog = catalog },
    { getQuestLog = function(q) return views[q] end })
  qlm.get_address = function() return qlm_addr end
  local tracked = 20120
  local gm = obj({}, { get_TargetQuestId = function() return tracked end,
    ["requestOpenMapMenu(via.vec3, app.AILocalAreaDefinition)"] = true })
  local cdict_calls = 0
  local contains_calls = 0
  local cd = obj({ NameID = guid("g_name") })
  local cdict = obj({}, { get_Item = function(cid)
    cdict_calls = cdict_calls + 1
    if cid ~= 189868107 then error("KeyNotFound") end
    return obj({ ["<Normal>k__BackingField"] = obj({}, { get_Item = function(i)
      return i == 0 and cd or nil end }) })
  end, ContainsKey = function(cid)
    contains_calls = contains_calls + 1
    return cid ~= 43
  end })
  local npcm = obj({}, { get_CharacterDataDict = cdict })
  local S = { ["app.QuestLogManager"] = qlm, ["app.GuiManager"] = gm, ["app.NPCManager"] = npcm }
  sdk.get_managed_singleton = function(n) return S[n] end
  a.reset_session_caches()                    -- adopt this QuestLogManager (clean journal)
  local function failed() return a.journal_stats().failed end

  -- JR1 tracked quest (<= 0 is nothing tracked; boxed enum read by value)
  assert(a.tracked_qid() == 20120, "JR1 tracked qid")
  tracked = { get_field = function(_, n) if n == "value__" then return 30100 end end }
  assert(a.tracked_qid() == 30100, "JR1 boxed enum by value")
  tracked = -1
  assert(a.tracked_qid() == nil and a.journal_stats().tracked == nil, "JR1 -1 -> nil")
  tracked = 0
  assert(a.tracked_qid() == nil, "JR1 0 -> nil")
  tracked = 20120
  a.tracked_qid()
  assert(a.journal_stats().tracked == 20120, "JR1 stats carry the last tracked read")

  -- JR2a method not found -> dest nil (not cached; resolved on the next read)
  QPOS.missing = true
  local jm = a.journal_now(20120)
  assert(jm ~= nil and jm.dest == nil and jm.name == "The Heel of History",
    "JR2a missing game method -> dest nil, rest of the row intact")
  QPOS.missing = false

  -- JR2 current step
  local j = a.journal_now(20120)
  assert(j ~= nil and j.name == "The Heel of History" and j.summary == "Orphans.", "JR2 name/summary")
  assert(j.base == "Determine Malcolm's location." and j.detail == "A boy is missing.", "JR2 step text")
  assert(j.step_index == 2, "JR2 0-based step index from _QuestLogInfoDict")
  assert(#j.checks == 1 and j.checks[1].text == "Ask around" and j.checks[1].done == true,
    "JR2 checklist; an empty-text item is skipped")
  assert(j.dest ~= nil and j.dest.x == 113.9 and j.dest.y == 156.2 and j.dest.z == -2128.9
    and j.dest.caption == "Slums", "JR2 dest = the game's map position, caption of the FIRST active destination")
  assert(msg_sigs[1] == "get(System.Guid)", "JR2 explicit message.get overload")
  local calls_before = msg_calls
  a.journal_now(20120)
  assert(msg_calls == calls_before, "JR3 resolved text served from the Guid cache")
  local f0 = failed()
  local jb = a.journal_now(20130)
  assert(jb ~= nil and jb.detail == nil and jb.summary == nil, "JR4 empty strings -> nil")
  assert(#jb.checks == 0 and jb.dest == nil and jb.step_index == nil,
    "JR4 failing checklist / no destination / missing index degrade per field")
  assert(failed() == f0 + 2, "JR4 checklist raise and index raise each count once")
  assert(a.journal_now(55555) == nil and failed() == f0 + 2, "JR5 no log entry -> nil, uncounted")
  assert(a.journal_now(20140) == nil and failed() == f0 + 3, "JR6 raising view -> nil, counted")
  local reads = a.journal_stats().read
  assert(reads == 4, "JR7 successful reads counted (20120 x3, 20130)")
  -- quest_step (SPEC 21.8.2): index + 1 under read_log; a raising read -> nil, counted
  do
    local r0, f00 = a.journal_stats().read, failed()
    assert(a.quest_step(20120) == 3, "QS1 step = 0-based index + 1")
    assert(a.journal_stats().read == r0 + 1, "QS2 counts as a journal read")
    assert(a.quest_step(20130) == nil and failed() == f00 + 1, "QS3 raising read -> nil, counted failed")
  end
  local f1 = failed()
  QPOS.raise = true
  local jr = a.journal_now(20120)
  QPOS.raise = false
  assert(jr ~= nil and jr.dest == nil and failed() == f1 + 1,
    "JR7a raising game method -> dest nil, counted once")

  -- JR8 every step (spoiler mode): catalog index rebuilt on (address, count)
  local ja = a.journal_all(20120)
  assert(ja ~= nil and ja.summary == "Catalog summary" and #ja.steps == 2
    and ja.steps[1].base == "Step one" and ja.steps[2].base == "Step two"
    and ja.steps[1].detail == nil, "JR8 steps 1-based with text")
  assert(values_calls == 1, "JR8 index built once")
  a.journal_all(10030)
  assert(values_calls == 1, "JR9 same key: no rebuild")
  assert(a.journal_all(77777) == nil, "JR9 quest absent from the catalog -> nil")
  cat_count = 3
  a.journal_all(20120)
  assert(values_calls == 2, "JR10 count change rebuilds")
  qlm_addr = 0x2000
  a.journal_all(20120)
  assert(values_calls == 3, "JR10 address change rebuilds")

  -- JR8b v14 step dump: side quests only, keys 0-based strings, a
  -- "#Rejected#" step kept at its index
  do
    local keep_ids, keep_side = a.catalog_ids, a.is_side
    a.catalog_ids = function() return { 20150, 20120, 10030 } end
    a.is_side = function(q) return q ~= 10030 end
    local d = a.quest_steps_text()
    a.catalog_ids, a.is_side = keep_ids, keep_side
    assert(d[10030] == nil, "JR8b non-side quest left out")
    local s3 = d[20150]
    assert(s3 ~= nil and s3["0"].base == "Step one" and s3["1"].base == "#Rejected# cut"
      and s3["2"].base == "Step two" and s3["3"] == nil and s3[1] == nil,
      "JR8b three steps keyed 0,1,2 as strings; rejected step kept")
    assert(d[20120]["1"].base == "Step two", "JR8b second quest")
  end

  -- JR11 giver names, cached by id; a failed lookup is counted once and
  -- cached as a miss until the session reset (SPEC 16.5: one read per new id)
  assert(a.npc_name(189868107) == "Brant", "JR11 name via NameID")
  local cc = cdict_calls
  assert(a.npc_name(189868107) == "Brant" and cdict_calls == cc, "JR11 cached by id")
  local f1 = failed()
  assert(a.npc_name(42) == nil and failed() == f1 + 1, "JR12 missing id -> nil, counted")
  assert(a.npc_name(42) == nil and cdict_calls == cc + 1 and failed() == f1 + 1,
    "JR12 a failed id is cached as a miss: no second lookup, no second count")
  assert(a.npc_name(nil) == nil, "JR12 nil id -> nil")
  -- JR12b v14: a cid the dictionary does not hold (ContainsKey false) is nil,
  -- uncounted, and never reaches get_Item
  do
    local c1, f2 = cdict_calls, failed()
    assert(a.npc_name(43) == nil and failed() == f2 and cdict_calls == c1,
      "JR12b ContainsKey false: nil, no failure counted, no get_Item")
    local k1 = contains_calls
    assert(a.npc_name(43) == nil and contains_calls == k1 and failed() == f2,
      "JR12b the miss is cached: no second native call")
  end
  S["app.NPCManager"] = nil
  assert(a.npc_name(77) == nil and failed() == f1 + 1, "JR12 no NPCManager -> nil, uncounted")
  S["app.NPCManager"] = npcm
  cc = cdict_calls
  a.npc_name(77)
  assert(cdict_calls == cc + 1, "JR12 a missing singleton is not cached as a miss")

  -- JR13 map open: explicit overload, Vector3f built from a plain table
  assert(a.map_open({ x = 1, y = 2, z = 3 }) == true, "JR13 map_open true")
  local last = gm.log[#gm.log]
  assert(last[1] == "requestOpenMapMenu(via.vec3, app.AILocalAreaDefinition)"
    and last[2].v3 and last[2].x == 1 and last[2].z == 3 and last[3] == 0, "JR13 call shape")
  S["app.GuiManager"] = nil
  assert(a.map_open({ x = 1, y = 2, z = 3 }) == false, "JR13 no GuiManager -> false")
  S["app.GuiManager"] = obj({}, { ["requestOpenMapMenu(via.vec3, app.AILocalAreaDefinition)"] = "RAISE" })
  assert(a.map_open({ x = 1, y = 2, z = 3 }) == false, "JR13 raising call -> false")
  S["app.GuiManager"] = gm

  -- JR14 jump apply: four fields, initMapPos overload, CursorUPos readback
  local ui = obj({ CursorUPos = { x = 1110.1, y = 0, z = -1977.0 } },
    { ["initMapPos(via.vec3)"] = true })
  local rb = a.map_jump_apply(ui, { x = 1110.1, y = 9.26, z = -1976.98 })
  assert(rb ~= nil and rb.x == 1110.1 and rb.z == -1977.0, "JR14 readback x/z")
  assert(ui.sets.WorldScale == 0.375 and ui.sets.StartByQuest == true
    and ui.sets.IsUpdateMapPos == true and ui.sets.SetForceCursorTimer == true,
    "JR14 the four fields")
  assert(ui.sets.UseCursorOffset == nil, "JR14 UseCursorOffset never set")
  assert(ui.log[1][1] == "initMapPos(via.vec3)" and ui.log[1][2].v3
    and ui.log[1][2].x == 1110.1, "JR14 initMapPos with a Vector3f")
  assert(a.map_jump_apply(nil, { x = 0, y = 0, z = 0 }) == nil, "JR14 nil ui -> nil")
  assert(a.map_jump_apply(obj({}, { ["initMapPos(via.vec3)"] = "RAISE" }),
    { x = 0, y = 0, z = 0 }) == nil, "JR14 raising apply -> nil")
  -- JR14b map_cursor: field read only, plain pcall (failures stay out of the Journal count)
  do
    local prev_live = sdk.is_managed_object
    sdk.is_managed_object = function() return true end
    local cui = obj({ CursorUPos = { x = 10.5, y = 3, z = -20.25 } })
    local c = a.map_cursor(cui)
    assert(c ~= nil and c.x == 10.5 and c.y == 3 and c.z == -20.25, "JR14b cursor x/y/z")
    assert(next(cui.sets) == nil and #cui.log == 0, "JR14b field read only")
    c = a.map_cursor(obj({ CursorUPos = { x = 1, z = 2 } }))
    assert(c ~= nil and c.y == 0 and c.x == 1 and c.z == 2, "JR14b missing y -> 0")
    c = a.map_cursor(obj({ CursorUPos = { x = 1, y = 0 / 0, z = 2 } }))
    assert(c ~= nil and c.y == 0, "JR14b NaN y -> 0")
    c = a.map_cursor(obj({ CursorUPos = { x = 1, y = math.huge, z = 2 } }))
    assert(c ~= nil and c.y == 0, "JR14b inf y -> 0")
    assert(a.map_cursor(obj({})) == nil, "JR14b no field -> nil")
    local fb = failed()
    assert(a.map_cursor(obj({ CursorUPos = "RAISE" })) == nil, "JR14b raising get_field -> nil")
    assert(failed() == fb, "JR14b raising read leaves the Journal failure count unchanged")
    assert(a.map_cursor(nil) == nil, "JR14b nil ui -> nil")
    sdk.is_managed_object = function() return false end
    assert(a.map_cursor(obj({ CursorUPos = { x = 1, y = 2, z = 3 } })) == nil,
      "JR14b non-managed ui -> nil")
    sdk.is_managed_object = prev_live
  end
  -- JR15 jump results and the stats copy
  for _, r in ipairs({ "on_target", "on_target", "off_target", "timeout", "canceled", "bogus" }) do
    a.journal_note_jump(r)
  end
  local s = a.journal_stats()
  assert(s.on_target == 2 and s.off_target == 1 and s.timeout == 1 and s.canceled == 1,
    "JR15 counted by result; unknown ignored")
  assert(s.cached > 0 and type(s.read) == "number", "JR15 cached = Guid cache size")
  s.on_target = 99
  assert(a.journal_stats().on_target == 2, "JR15 journal_stats returns a copy")

  -- JR17 no GuiManager clears the tracked readout (never a stale quest)
  tracked = 20120
  assert(a.tracked_qid() == 20120 and a.journal_stats().tracked == 20120, "JR17 setup")
  S["app.GuiManager"] = nil
  assert(a.tracked_qid() == nil and a.journal_stats().tracked == nil,
    "JR17 nil GuiManager -> tracked stat cleared")
  S["app.GuiManager"] = gm

  -- JR18 a missing via.gui.message type counts one failure per text call
  do
    local keep = sdk.find_type_definition
    sdk.find_type_definition = function(n)
      if n == "via.gui.message" then return nil end
      return keep(n)
    end
    package.loaded["adapter"] = nil
    local a2 = require("adapter").make()
    a2.reset_session_caches()
    local d1 = a2.journal_stats().failed
    a2.journal_now(20120)
    local d2 = a2.journal_stats().failed
    a2.journal_now(20120)
    local d3 = a2.journal_stats().failed
    assert(d2 - d1 >= 2 and d3 - d2 == d2 - d1,
      "JR18 missing message type: failures counted on every call, never cached")
    sdk.find_type_definition = keep
  end

  -- JR16 session reset clears caches, index and stats
  S["app.QuestLogManager"] = obj({ _QuestLogInfoDict = dict, _Catalog = catalog },
    { getQuestLog = function(q) return views[q] end })
  assert(a.reset_session_caches() == true, "JR16 new QuestLogManager resets")
  s = a.journal_stats()
  assert(s.read == 0 and s.failed == 0 and s.cached == 0 and s.on_target == 0
    and s.tracked == nil, "JR16 stats and text cache cleared")
  local vc = values_calls
  a.journal_all(20120)
  assert(values_calls == vc + 1, "JR16 catalog index rebuilt after reset")
  cc = cdict_calls
  a.npc_name(189868107)
  assert(cdict_calls == cc + 1, "JR16 name cache cleared")
  cc = cdict_calls
  a.npc_name(42)
  assert(cdict_calls == cc + 1, "JR16 miss cache cleared")

  -- QF set_focus_qids stores a set and clears on nil or empty
  a.set_focus_qids({ 10010, 10020, "x" })
  local fs = a.focus_set()
  assert(fs ~= nil and fs[10010] and fs[10020] and fs.x == nil and fs[1] == nil,
    "QF1 numbers stored as a set")
  a.set_focus_qids({})
  assert(a.focus_set() == nil, "QF2 empty list clears")
  a.set_focus_qids({ 10010 })
  a.set_focus_qids(nil)
  assert(a.focus_set() == nil, "QF3 nil clears")

  sdk.get_managed_singleton, sdk.find_type_definition, Vector3f = prev_gms, prev_ftd, prev_v3
end

-- SPEC 40.22: generic bounded door-leaf observation and source gating.
(function()
  assert(type(A.read_world_access_gates) == "function",
    "generic world-access reader is exported")
  assert(type(A.read_masquerade_door_closed) ~= "function",
    "masquerade-only reader is removed")
  local reads, outer_reads = 0, 0
  local function obj(fields, calls, tn)
    return {
      get_field = function(_, name) reads = reads + 1; return fields and fields[name] end,
      call = function(_, name, ...)
        reads = reads + 1
        local value = calls and calls[name]
        if type(value) == "function" then return value(...) end
        return value
      end,
      get_type_definition = function()
        reads = reads + 1
        return { get_full_name = function() reads = reads + 1; return tn end }
      end,
    }
  end
  local function arr(values, fail, outer)
    return { get_element = function(_, index)
      reads = reads + 1
      if outer then outer_reads = outer_reads + 1 end
      if fail then error("partial collection") end
      return values[index + 1]
    end }
  end
  local function door(bucket, x, name, closed, locked, options)
    options = options or {}
    local leaf = obj(options.leaf_fields or { IsClose = closed, IsLock = locked })
    local leaves = obj(nil, {
      get_Count = options.leaf_count or 1,
      get_Item = function(index) return index == 0 and leaf or nil end,
    })
    local pos = options.pos or { x = x, y = bucket == 74 and 19.779 or 73.5,
      z = bucket == 74 and -1014.327 or -819.250 }
    local tr = obj(nil, { get_UniversalPosition = pos })
    local go = obj(nil, { get_Name = name, get_Transform = tr })
    local native = obj({ CompDoorList = leaves },
      { get_GameObject = go }, options.type_name or "app.gm05_046")
    return native
  end
  local function manager(rows, fail_outer)
    local buckets = {}
    for _, row in ipairs(rows or {}) do
      local values = {}
      for _, native in ipairs(row.doors or {}) do
        values[#values + 1] = obj({ Value = native, next = -1 })
      end
      local free_slots = row.free_slots or 0
      for _ = 1, free_slots do values[#values + 1] = obj({ next = -2 }) end
      local expected = row.expected_count or (#values - free_slots)
      local used = row.used_count or #values
      local set = obj({ _entries = arr(values, row.fail_inner), _count = used,
        _freeCount = free_slots }, { get_Count = expected })
      buckets[#buckets + 1] = obj({ key = row.bucket, value = set, next = -1 })
    end
    local dict = obj({ _entries = arr(buckets, fail_outer, true), _count = #buckets,
      _freeCount = 0 }, { get_Count = #buckets })
    return obj({ ["<ManagedGimmicksByIDs>k__BackingField"] = dict })
  end
  local requested = { "masquerade_passage", "beggars_garb_entrance" }
  reads = 0
  local empty, complete = A.read_world_access_gates(nil, {})
  assert(complete == true and next(empty) == nil and reads == 0,
    "empty requested gate set performs zero managed reads")
  local both = manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, true) } },
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, false) } },
  })
  local observed, scan_complete = A.read_world_access_gates(both, requested)
  assert(scan_complete == true
    and observed.masquerade_passage.status == "known"
    and observed.masquerade_passage.values.closed == true
    and observed.masquerade_passage.values.locked == true
    and observed.beggars_garb_entrance.status == "known"
    and observed.beggars_garb_entrance.values.closed == true
    and observed.beggars_garb_entrance.values.locked == false,
    "both requested gates are observed in one scan with IsClose and IsLock")
  local none = A.read_world_access_gates(manager({}), requested)
  assert(none.masquerade_passage.status == "unknown"
    and none.beggars_garb_entrance.status == "unknown", "no matching leaf is unknown")
  local duplicate = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, false),
      door(85, 396.075, "gm80_026", true, false) } },
  }), { "masquerade_passage" })
  assert(duplicate.masquerade_passage.status == "unknown", "duplicate leaf is unknown")
  local malformed = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, false,
      { leaf_fields = { IsClose = true } }) } },
  }), { "masquerade_passage" })
  assert(malformed.masquerade_passage.status == "unknown", "missing lock state is unknown")
  local partial_outer = A.read_world_access_gates(manager({}, true), requested)
  assert(partial_outer.masquerade_passage.status == "unknown"
    and partial_outer.beggars_garb_entrance.status == "unknown",
    "partial outer collection atomically invalidates requested gates")
  local partial_inner = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, false) } },
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, false) },
      fail_inner = true },
  }), requested)
  assert(partial_inner.masquerade_passage.status == "unknown"
    and partial_inner.beggars_garb_entrance.status == "unknown",
    "partial inner collection atomically invalidates requested gates")
  local partial_unrequested = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, false) } },
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, false) },
      fail_inner = true },
  }), { "masquerade_passage" })
  assert(partial_unrequested.masquerade_passage.status == "unknown",
    "partial unrequested bucket atomically invalidates requested gates")
  local oversized_unrequested = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, false) } },
    { bucket = 74, doors = {}, expected_count = 4097, used_count = 4097 },
  }), { "masquerade_passage" })
  assert(oversized_unrequested.masquerade_passage.status == "unknown",
    "over-cap unrequested bucket atomically invalidates requested gates")
  local valid_native = door(85, 396.075, "gm80_026", true, false)
  local sparse_values = {
    [1] = obj({ Value = valid_native, next = -1 }),
    [3] = obj({ Value = valid_native, next = -1 }),
  }
  local sparse_set = obj({ _entries = arr(sparse_values), _count = 3, _freeCount = 1 },
    { get_Count = 2 })
  local sparse_bucket = obj({ key = 85, value = sparse_set, next = -1 })
  local sparse_dict = obj({ _entries = arr({ sparse_bucket }), _count = 1, _freeCount = 0 },
    { get_Count = 1 })
  local sparse, sparse_complete = A.read_world_access_gates(
    obj({ ["<ManagedGimmicksByIDs>k__BackingField"] = sparse_dict }),
    { "masquerade_passage" })
  assert(sparse_complete == false and sparse.masquerade_passage.status == "unknown",
    "sparse inner collection cannot hide a duplicate match")
  local raising_entry = {
    get_field = function() error("partial entry") end,
  }
  local raising_set = obj({ _entries = arr({ obj({ Value = valid_native, next = -1 }),
      raising_entry }), _count = 2, _freeCount = 0 }, { get_Count = 2 })
  local raising_bucket = obj({ key = 85, value = raising_set, next = -1 })
  local raising_dict = obj({ _entries = arr({ raising_bucket }), _count = 1, _freeCount = 0 },
    { get_Count = 1 })
  local raising, raising_complete = A.read_world_access_gates(
    obj({ ["<ManagedGimmicksByIDs>k__BackingField"] = raising_dict }),
    { "masquerade_passage" })
  assert(raising_complete == false and raising.masquerade_passage.status == "unknown",
    "unreadable occupied entry atomically fails closed")
  outer_reads = 0
  local oversized_dict = obj({ _entries = arr({}, false, true), _count = 4097,
    _freeCount = 0 }, { get_Count = 4097 })
  local oversized, oversized_complete = A.read_world_access_gates(
    obj({ ["<ManagedGimmicksByIDs>k__BackingField"] = oversized_dict }),
    { "masquerade_passage" })
  assert(oversized_complete == false and oversized.masquerade_passage.status == "unknown"
    and outer_reads == 0,
    "over-cap collection is rejected before entry materialization")
  local exact = {}
  for i = 1, 4095 do exact[#exact + 1] = door(85, 0, "other", false, false,
    { type_name = "app.OtherDoor" }) end
  exact[#exact + 1] = door(85, 396.075, "gm80_026", false, true)
  local at_cap = A.read_world_access_gates(manager({ { bucket = 85, doors = exact } }, false),
    { "masquerade_passage" })
  assert(at_cap.masquerade_passage.status == "known", "exact managed-object cap is complete")
  local at_cap_with_tombstone = A.read_world_access_gates(manager({
    { bucket = 85, doors = exact, free_slots = 1 },
  }), { "masquerade_passage" })
  assert(at_cap_with_tombstone.masquerade_passage.status == "known",
    "exact managed-object cap remains complete with a backing tombstone")
  local tombstone_overflow = A.read_world_access_gates(manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", false, true) } },
    { bucket = 74, doors = {}, free_slots = 8193 },
  }), { "masquerade_passage" })
  assert(tombstone_overflow.masquerade_passage.status == "unknown",
    "backing-slot overflow is bounded even when no live objects occupy it")
  exact[#exact + 1] = door(85, 0, "other", false, false, { type_name = "app.OtherDoor" })
  local over_cap = A.read_world_access_gates(manager({ { bucket = 85, doors = exact } }, false),
    { "masquerade_passage" })
  assert(over_cap.masquerade_passage.status == "unknown", "cap plus one fails closed")

  local hint = { target_kind = "hint_pin", quest_id = 30040, pin_index = 1 }
  local garb = { target_kind = "placed_item", type_name = "app.Gm82_000", item_id = 300,
    position = { x = 571.018, y = 19.753, z = -1012.515 } }
  local unrelated = { target_kind = "placed_item", type_name = "app.Gm82_000", item_id = 301,
    position = { x = 0, y = 0, z = 0 } }
  local old_gms, old_clock = sdk.get_managed_singleton, os.clock
  local owner, gm, now = {}, both, 100
  sdk.get_managed_singleton = function(name)
    if name == "app.QuestLogManager" then return owner end
    if name == "app.GimmickManager" then return gm end
  end
  os.clock = function() return now end
  a.reset_session_caches()
  outer_reads = 0
  local filtered, decisions = a.filter_access_targets({ hint, garb, unrelated })
  assert(outer_reads == 2 and #filtered == 3 and filtered[1] == hint
    and filtered[2] == garb and filtered[3] == unrelated and #decisions == 2,
    "target filter batches both gates in one scan and preserves unbound membership")
  local candidate = { source_id = { "source", "placed", "garb", 0 },
    provider = "placed", outputs = { { item_id = 300, count = 1 } },
    target = { kind = "placed", uid = "garb", index = 0, pos = garb.position },
    capacity_pool_id = { "capacity", "placed", "garb", 0 },
    capacity_kind = "finite", available_acquisitions = 1,
    certainty = "guaranteed", eligibility = "eligible", generation = 7 }
  local other_candidate = { source_id = { "source", "placed", "other", 0 },
    provider = "placed", outputs = { { item_id = 301, count = 1 } },
    target = { kind = "placed", uid = "other", index = 0, pos = unrelated.position },
    capacity_pool_id = { "capacity", "placed", "other", 0 },
    capacity_kind = "finite", available_acquisitions = 1,
    certainty = "guaranteed", eligibility = "eligible", generation = 7 }
  local provider = { provider = "placed", status = "ok", complete = true, generation = 7,
    candidates = { candidate, other_candidate } }
  local positive = a.filter_placed_provider_snapshot(provider)
  assert(positive ~= provider and positive.status == "ok" and positive.complete
    and positive.generation == 7 and #positive.candidates == 2
    and positive.candidates[1] == candidate and positive.candidates[2] == other_candidate,
    "closed but unlocked Garb source remains in the complete provider snapshot")
  gm = manager({
    { bucket = 85, doors = { door(85, 396.075, "gm80_026", true, true) } },
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, true) } },
  })
  now = now + 11
  filtered, decisions = a.filter_access_targets({ hint, garb, unrelated })
  local locked_provider = a.filter_placed_provider_snapshot(provider)
  assert(#filtered == 2 and filtered[1] == hint and filtered[2] == unrelated
    and #locked_provider.candidates == 1 and locked_provider.candidates[1] == other_candidate
    and locked_provider.complete and locked_provider.generation == 7,
    "locked Garb source is absent while unrelated item and provider rows pass through")
  gm = nil
  now = now + 11
  filtered, decisions = a.filter_access_targets({ hint, garb, unrelated })
  local unknown_provider = a.filter_placed_provider_snapshot(provider)
  assert(#filtered == 3 and filtered[1] == hint and filtered[2] == garb
    and filtered[3] == unrelated and decisions[1].used_last_known == true
    and decisions[2].allowed == true and decisions[2].reason == "unknown_allowed"
    and #unknown_provider.candidates == 2 and unknown_provider.candidates[1] == candidate
    and unknown_provider.candidates[2] == other_candidate
    and unknown_provider.complete and unknown_provider.generation == 7,
    "unknown production gate preserves focused Garb while hint uses last-known state")
  local fixture_gate = { id = "fixture_second_entrance", observer_family = "door_leaf",
    fingerprint = { bucket_id = 86, type_name = "app.gm05_046",
      game_object_name = "gm_fixture", position = { x = 1, y = 2, z = 3 },
      tolerance = 0.25, leaf_count = 1 } }
  local fixture_binding = { target_kind = "placed_item",
    selector = { type_name = "app.Gm82_000", item_id = 301,
      position = unrelated.position, position_tolerance = 0.25 },
    gate_id = fixture_gate.id, predicate = { field = "locked", equals = false },
    unknown_policy = "deny", may_use_last_known = false }
  A.access.registry.gates[#A.access.registry.gates + 1] = fixture_gate
  A.access.registry.bindings[#A.access.registry.bindings + 1] = fixture_binding
  owner = {}
  assert(a.reset_session_caches() == true, "fixture gate starts with empty access cache")
  gm = manager({
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, false) } },
    { bucket = 86, doors = { door(86, 1, "gm_fixture", true, false,
      { pos = fixture_gate.fingerprint.position }) } },
  })
  now = now + 11
  outer_reads = 0
  local batched_provider = a.filter_placed_provider_snapshot(provider)
  assert(#batched_provider.candidates == 2 and outer_reads == 2,
    "placed provider batches every stale bound gate into one manager scan")
  table.remove(A.access.registry.bindings)
  table.remove(A.access.registry.gates)
  gm = both
  now = now + 11
  a.filter_access_targets({ hint })
  local integration_core = require("Clairvoyance.core")
  local task_snapshot = { focus_epoch = 1, journal_generation = 1, need_generation = 9,
    objective_needs = { status = "ok", complete = true, generation = 9,
      source_generation = 9, groups = {
        { id = { "need", 20090, 1, 0, 1 }, qid = 20090, task_index = 0,
          remaining = 1, options = { { item_id = 300, accepted_count = 1 } },
          status = "eligible", complete = true, generation = 9 },
      } },
    quests = { { qid = 20090, task_index = 0, read_status = "ok",
      issued_npcs = {}, task_destinations = {}, guidance = {}, item_ownership = {
        { item_id = 300, count = 1, proof_kind = "condition", eligibility = "eligible" },
      } } } }
  local function projected(provider_snapshots)
    if provider_snapshots.provider ~= nil then provider_snapshots = { provider_snapshots } end
    local snapshot = integration_core.objective_snapshot(task_snapshot, nil,
      provider_snapshots, integration_core.target_registry_new())
    local base = {}
    if snapshot.targets[1] ~= nil then
      base[1] = { key = "garb-marker", source_key = snapshot.targets[1].key,
        cat = "quest_item", pos = garb.position,
        live = { x = 0, y = 0, z = 0 }, qids = {}, label = "Beggar's Garb" }
    end
    local markers, full = integration_core.objective_markers(base, base, snapshot,
      { objective_places = true, focus_order = { 20090 } })
    local minimap = integration_core.minimap_markers(markers, garb.position, 10, 12)
    local overhead = integration_core.overhead_points(markers, { x = 0, y = 0, z = 0 }, 10)
    local routes = integration_core.objective_routes(snapshot, { x = 0, y = 0, z = 0 },
      { objective_places = true, focus_order = { 20090 } })
    return snapshot, markers, full, minimap, overhead, routes
  end
  local ps, pm, pf, pmini, po, pr = projected(positive)
  assert(#ps.targets == 1 and #pm == 1 and #pf == 1 and #pmini == 1
    and #po == 1 and #pr.members == 1,
    "unlocked real filter output reaches map, full map, minimap, overhead and route")
  local xs, xm, xf, xmini, xo, xr = projected(unknown_provider)
  assert(#xs.targets == 1 and #xm == 1 and #xf == 1 and #xmini == 1
    and #xo == 1 and #xr.members == 1,
    "unknown production gate preserves map, full map, minimap, overhead and route")
  for label, denied in pairs({ locked = locked_provider }) do
    local ds, dm, df, dmini, doh, dr = projected(denied)
    assert(#ds.targets == 0 and #dm == 0 and #df == 0 and #dmini == 0
      and #doh == 0 and #dr.members == 0,
      label .. " real filter output cannot reappear on any presentation surface")
  end
  local source_uid = "11111111-1111-1111-1111-111111111111"
  local source_catalog = { version = 2, status = "ok", complete = true, generation = 1,
    placements = { { uid = source_uid, index = 0,
      table_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", layer = 0,
      source_id = { "source", "placed", source_uid, 0 },
      capacity_pool_id = { "capacity", "placed", source_uid, 0 },
      outputs = { { item_id = 300, count = 1 } }, pos = garb.position } },
    chests = {} }
  local source_observation = { complete = true, persisted_complete = true,
    generation_complete = true, requested_complete = true, loaded_complete = true,
    persisted = { [source_uid .. ":0"] = { family = "placed", freebit = 0 } },
    never = {}, dead = {}, disabled_tables = {}, blacklist = {},
    requested_tables = {}, loaded = {}, gate_results = {} }
  local saved_need_groups = a.objective_need_groups
  a.objective_need_groups = function()
    return { status = "ok", complete = true, generation = 9, groups = {
      { qid = 20090, task_index = 0, remaining = 1,
        options = { { item_id = 300, accepted_count = 1 } } },
    } }
  end
  gm = manager({
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, false) } },
  })
  now = now + 11
  local published_unlocked = a.objective_item_source_snapshots(nil,
    { need_generation = 9, quests = {} }, source_catalog, source_observation, {})
  gm = manager({
    { bucket = 74, doors = { door(74, 568.247, "gm05_046", true, true) } },
  })
  now = now + 11
  local published_locked = a.objective_item_source_snapshots(nil,
    { need_generation = 9, quests = {} }, source_catalog, source_observation, {})
  gm = nil
  now = now + 11
  local published_unknown = a.objective_item_source_snapshots(nil,
    { need_generation = 9, quests = {} }, source_catalog, source_observation, {})
  a.objective_need_groups = saved_need_groups
  assert(#published_unlocked[1].candidates == 1
    and #published_locked[1].candidates == 0
    and #published_unknown[1].candidates == 1,
    "objective provider publication preserves unknown, allows unlocked and blocks known locked access")
  local us, um, uf, umini, uoh, ur = projected(published_unlocked)
  assert(#us.targets == 1 and #um == 1 and #uf == 1 and #umini == 1
    and #uoh == 1 and #ur.members == 1,
    "unlocked published envelope reaches every presentation surface")
  local psu, pmu, pfu, pminiu, pou, pru = projected(published_unknown)
  assert(#psu.targets == 1 and #pmu == 1 and #pfu == 1 and #pminiu == 1
    and #pou == 1 and #pru.members == 1,
    "unknown published envelope reaches every presentation surface")
  for label, denied in pairs({ locked = published_locked }) do
    local ds, dm, df, dmini, doh, dr = projected(denied)
    assert(#ds.targets == 0 and #dm == 0 and #df == 0 and #dmini == 0
      and #doh == 0 and #dr.members == 0,
      label .. " published envelope cannot reappear on any presentation surface")
  end
  a.invalidate_items()
  now = now + 11
  filtered, decisions = a.filter_access_targets({ hint, garb })
  assert(#filtered == 2 and filtered[1] == hint and filtered[2] == garb
    and decisions[1].used_last_known == true and decisions[2].allowed == true,
    "ordinary item invalidation retains hint history and preserves unknown Garb access")
  owner = {}
  assert(a.reset_session_caches() == true, "session owner reset executes")
  filtered, decisions = a.filter_access_targets({ hint, garb })
  assert(#filtered == 2 and filtered[1] == hint and filtered[2] == garb
    and decisions[1].used_last_known == false and decisions[2].allowed == true,
    "session reset clears observations without hiding unknown focused Garb access")
  sdk.get_managed_singleton, os.clock = old_gms, old_clock
end)()

-- General objective task snapshots: native membership and concierge status
-- are authoritative; generated catalog rows only supply their exact indices.
do
  local function native(fields, calls, addr)
    local o = { _fields = fields or {}, _calls = calls or {}, _addr = addr }
    function o.get_field(_, k)
      local v = o._fields[k]
      if v == "RAISE" then error("field " .. k) end
      return v
    end
    function o.get_address() return o._addr end
    function o.call(_, method, ...)
      local v = o._calls[method]
      if v == "RAISE" then error("call " .. method) end
      if type(v) == "function" then return v(...) end
      return v
    end
    return o
  end
  local qid, cid, key = 20040, 101, 2308
  local live_dest = native({}, {
    get_DestType = 3, get_CharaID = cid, get_KeyLocation = key,
    get_Area = 19, get_LocalArea = 2, getDestination = { x = 1, y = 2, z = 3 },
    evaluateShow = false, evaluateHide = false, evaluateUpdateShow = false,
  }, 0x101)
  local stale_dest = native({}, { get_DestType = 3, get_CharaID = 999,
    get_KeyLocation = 0, get_Area = 19, get_LocalArea = 2 }, 0x102)
  local task = native({ _HasDestination = false, _Destinations = mcoll({ stale_dest, live_dest }) }, {
    getActiveDestinations = mcoll({ live_dest }),
  })
  local concierge_dest = native({
    _Conditions = mcoll({}), _DeliveryGroupID = 0,
    _DeliveryCheckStorage = false, _DeliveryIsNot = false,
  }, { evaluate = 0, evaluateRegisterCondition = true,
    get_DeliverData = mcoll({}), get_CharaID = cid, get_KeyLocation = key,
    get_LocalArea = 2, getDestination = { x = 1, y = 2, z = 3 } })
  local concierge = native({ _TaskIndex = 0, _Destinations = mcoll({ concierge_dest }) }, {
    get_TaskIndex = 0, get_Destinations = mcoll({ concierge_dest }),
    getRegisterableDestinations = mcoll({ concierge_dest }),
  })
  local info = native({}, { get_CurrentTaskIndex = 0,
    getCurrentTaskConciergeData = concierge })
  local info_dict = native({}, { get_Item = function(q) if q == qid then return info end end })
  local quest_resource = native({ _ConciergeList = mcoll({ concierge }) }, {
    get_QuestId = qid })
  local quest_catalog = native({}, { getCount = 1,
    getValues = arr({ quest_resource }) })
  local qlm = native({ _QuestLogInfoDict = info_dict, _Catalog = quest_catalog }, {
    getCurrentTask = function(q) if q == qid then return task end end,
  }, 0x201)
  local old_gms = sdk.get_managed_singleton
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestLogManager" then return qlm end
  end
  local catalog = { version = 2, quests = { [qid] = {
    tasks = { { index = 0, has_destination = false, destinations = {
      { index = 0, set_destination = false, dest_type = 3, cid = 999, key = nil,
        area = 19, local_area = 2, has_show_conditions = true, show_conditions = {},
        is_update_condition = true, has_display_conditions = true, display_conditions = {} },
      { index = 1, set_destination = false, dest_type = 3, cid = cid, key = key,
        area = 19, local_area = 2, has_show_conditions = false, show_conditions = {},
        is_update_condition = false, has_display_conditions = false, display_conditions = {} },
    } } }, guidance = { { index = 0, task_index = 0, destination_index = 0,
      destinations = { { index = 0, target = { kind = "key_location", key = key }, cid = cid,
        register_conditions = {}, conditions = {},
        delivery = { is_not = false, check_storage = false, group_id = 0, refs = {} } } } } },
    deliveries = {}, sources = {},
  } } }
  local oa = A.make()
  local snap = oa.objective_task_snapshot({ qid }, catalog)
  assert(type(snap) == "table" and #snap.quests == 1,
    "OT1 returns the focused quest task snapshot")
  local row = snap.quests[1]
  assert(row.qid == qid and row.task_index == 0 and row.read_status == "ok",
    "OT1 current task matches the live journal index")
  assert(#row.task_destinations == 2 and row.task_destinations[1].destination_index == 1
    and row.task_destinations[1].kind == "npc" and row.task_destinations[1].target.cid == cid
    and row.task_destinations[1].target.pos.x == 1
    and row.task_destinations[2].kind == "place" and row.task_destinations[2].target.pos == nil,
    "OT2 exact active object emits independent NPC and place targets")
  assert(row.live_destination == nil,
    "OT2 generated task destinations are not copied into live-only evidence")
  assert(snap.catalog_version == 2 and type(row.source_descriptors) == "table"
    and #row.source_descriptors == 0
    and type(row.task_destinations[1].evidence) == "table"
    and type(row.guidance[1].delivery_refs) == "table"
    and type(row.guidance[1].signals[1].evidence) == "table",
    "OT2b validated catalog boundary carries version, descriptors, signal evidence, and delivery refs")
  assert(#row.guidance == 1 and row.guidance[1].eligibility == "eligible"
    and row.guidance[1].signals[1].target.cid == cid,
    "OT3 concierge requires matching task and exact register/status success: "
      .. tostring(row.guidance[1] and row.guidance[1].eligibility) .. "/"
      .. tostring(row.guidance[1] and row.guidance[1].reason))
  local same = oa.objective_task_snapshot({ qid }, catalog)
  assert(same.focus_epoch == snap.focus_epoch
    and same.journal_generation == snap.journal_generation
    and same.need_generation == snap.need_generation,
    "OT4 identical snapshot does not advance its component generations")
  local original_guidance = catalog.quests[qid].guidance[1].destinations
  local second_concierge_dest = native({}, { evaluate = 1,
    evaluateRegisterCondition = true, get_CharaID = cid + 1, get_KeyLocation = key + 1,
    get_LocalArea = 2, getDestination = { x = 4, y = 5, z = 6 } })
  catalog.quests[qid].guidance[1].destinations = {
    original_guidance[1], { index = 1, cid = cid + 1,
      target = { kind = "key_location", key = key + 1 }, conditions = {},
      delivery = { refs = {} } },
  }
  concierge._calls.get_Destinations = mcoll({ concierge_dest, second_concierge_dest })
  local mixed = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance
  assert(#mixed == 2 and mixed[1].destination_index == 0
    and mixed[1].eligibility == "eligible" and #mixed[1].signals == 2
    and mixed[1].signals[1].kind == "npc" and mixed[1].signals[1].target.pos.x == 1
    and mixed[1].signals[1].target.place == nil
    and mixed[1].signals[2].kind == "place" and mixed[1].signals[2].target.cid == nil
    and mixed[1].signals[2].target.pos == nil
    and mixed[2].destination_index == 1 and mixed[2].eligibility == "ineligible"
    and #mixed[2].signals == 0,
    "OT3b guidance keeps independent eligibility and emits both positioned targets")
  catalog.quests[qid].guidance[1].destinations = original_guidance
  concierge._calls.get_Destinations = mcoll({ concierge_dest })
  local duplicate_native_zero = native({}, { evaluate = 2,
    evaluateRegisterCondition = true, get_CharaID = cid, get_KeyLocation = key,
    get_LocalArea = 2, getDestination = { x = 7, y = 8, z = 9 } })
  local duplicate_native_one = native({}, { evaluate = 0,
    evaluateRegisterCondition = true, get_CharaID = cid, get_KeyLocation = key,
    get_LocalArea = 2, getDestination = { x = 10, y = 11, z = 12 } })
  local record_zero = native({ _TaskIndex = 0, _Destinations = mcoll({ duplicate_native_zero }) },
    { get_TaskIndex = 0, get_Destinations = mcoll({ duplicate_native_zero }) })
  local record_one = native({ _TaskIndex = 0, _Destinations = mcoll({ duplicate_native_one }) },
    { get_TaskIndex = 0, get_Destinations = mcoll({ duplicate_native_one }) })
  quest_resource._fields._ConciergeList = mcoll({ record_zero, record_one })
  catalog.quests[qid].guidance = { { index = 1, task_index = 0, destination_index = 0,
    destinations = original_guidance } }
  concierge._calls.get_Destinations = mcoll({ duplicate_native_zero, duplicate_native_one })
  local indexed_native = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(indexed_native.concierge_index == 1 and indexed_native.eligibility == "eligible"
    and indexed_native.signals[1].target.pos.x == 10,
    "OT3e generated concierge record index selects its matching native record")
  qlm._fields._Catalog = nil
  local no_native_catalog = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(no_native_catalog.eligibility == "unknown"
    and no_native_catalog.reason == "concierge_catalog_resource_unavailable"
    and #no_native_catalog.signals == 0,
    "OT3e unavailable catalog cannot reuse an indexed native resource")
  assert(oa.reset_session_caches() == true, "OT3e session owner reset clears catalog index")
  local reset_native_catalog = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(reset_native_catalog.eligibility == "unknown"
    and reset_native_catalog.reason == "concierge_catalog_resource_unavailable"
    and #reset_native_catalog.signals == 0,
    "OT3e reset catalog index stays unknown without a current native resource")
  qlm._fields._Catalog = quest_catalog
  quest_resource._fields._ConciergeList = mcoll({ concierge })
  catalog.quests[qid].guidance = { { index = 0, task_index = 0, destination_index = 0,
    destinations = { original_guidance[1], { index = 1, cid = cid,
      target = { kind = "key_location", key = key }, conditions = {}, delivery = { refs = {} } } } } }
  concierge._calls.get_Destinations = mcoll({ duplicate_native_zero, duplicate_native_one })
  local indexed_destination = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance
  assert(#indexed_destination == 2 and indexed_destination[1].eligibility == "ineligible"
    and indexed_destination[2].eligibility == "eligible"
    and indexed_destination[2].destination_index == 1
    and indexed_destination[2].signals[1].target.pos.x == 10,
    "OT3f destination index selects the original native destination despite duplicate target values")
  catalog.quests[qid].guidance = { { index = 0, task_index = 0, destination_index = 0,
    destinations = original_guidance } }
  concierge._calls.get_Destinations = mcoll({ concierge_dest })
  catalog.quests[qid].guidance[2] = { index = 1, task_index = 0, destination_index = 0,
    destinations = original_guidance }
  local shared_native = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance
  assert(#shared_native == 2 and shared_native[1].eligibility == "eligible"
    and shared_native[2].eligibility == "unknown"
    and shared_native[2].reason == "concierge_record_missing",
    "OT3a one native concierge destination is not reused across same-task records")
  catalog.quests[qid].guidance[2] = nil
  local saved_guidance_target = original_guidance[1].target
  local saved_guidance_cid = original_guidance[1].cid
  local saved_concierge_cid = concierge_dest._calls.get_CharaID
  original_guidance[1].cid = nil
  concierge_dest._calls.get_CharaID = 0
  local no_cid = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(no_cid.eligibility == "eligible" and #no_cid.signals == 1
    and no_cid.signals[1].kind == "place" and no_cid.signals[1].target.cid == nil
    and no_cid.signals[1].target.pos == nil,
    "OT3c native CID zero is normalized and place-only evidence remains usable")
  original_guidance[1].cid = saved_guidance_cid
  concierge_dest._calls.get_CharaID = saved_concierge_cid
  local saved_key, saved_area = concierge_dest._calls.get_KeyLocation,
    concierge_dest._calls.get_LocalArea
  original_guidance[1].target = nil
  concierge_dest._calls.get_KeyLocation, concierge_dest._calls.get_LocalArea = nil, nil
  local npc_only = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(npc_only.eligibility == "eligible" and #npc_only.signals == 1
    and npc_only.signals[1].kind == "npc" and npc_only.signals[1].target.cid == cid,
    "OT3c NPC-only guidance matches when both catalog and live place identities are absent")
  concierge_dest._calls.get_KeyLocation, concierge_dest._calls.get_LocalArea = saved_key, saved_area
  original_guidance[1].target = { kind = "key_location", key = key + 1 }
  local wrong_key = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(wrong_key.eligibility == "unknown"
    and wrong_key.reason == "concierge_destination_mismatch",
    "OT3c a matching CID with the wrong place key is not joined")
  original_guidance[1].target = saved_guidance_target
  concierge_dest._calls.get_CharaID = "RAISE"
  local unreadable_cid = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(unreadable_cid.eligibility == "unknown"
    and unreadable_cid.reason == "concierge_destination_identity_unreadable",
    "OT3g a raised native CID read fails closed instead of becoming absent")
  concierge_dest._calls.get_CharaID = saved_concierge_cid
  concierge_dest._calls.get_KeyLocation = "RAISE"
  local unreadable_place = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(unreadable_place.eligibility == "unknown"
    and unreadable_place.reason == "concierge_destination_identity_unreadable",
    "OT3g a raised native place read fails closed instead of becoming absent")
  concierge_dest._calls.get_KeyLocation = saved_key
  local saved_delivery = original_guidance[1].delivery
  original_guidance[1].delivery = false
  local false_delivery = oa.objective_task_snapshot({ qid }, catalog).quests[1]
  assert(false_delivery.read_status == "ok"
    and #false_delivery.item_ownership == 0,
    "OT3d false delivery placeholders are type-checked")
  original_guidance[1].delivery = saved_delivery
  -- Native destination membership survives contradicting archive flags and
  -- follows object identity when source order changes. Duplicate active refs
  -- deduplicate; an adjacent non-current task never contributes.
  task._calls.getActiveDestinations = mcoll({ live_dest, stale_dest, live_dest })
  local reordered = oa.objective_task_snapshot({ qid }, catalog)
  assert(#reordered.quests[1].task_destinations == 4
    and reordered.quests[1].task_destinations[1].destination_index == 0
    and reordered.quests[1].task_destinations[2].destination_index == 0
    and reordered.quests[1].task_destinations[3].destination_index == 1
    and reordered.quests[1].task_destinations[4].destination_index == 1,
    "OT5 exact destination identity handles reorder and duplicate active refs")
  task._calls.getActiveDestinations = mcoll({ native({}, {}, 0x999) })
  local mismatch = oa.objective_task_snapshot({ qid }, catalog)
  assert(#mismatch.quests[1].task_destinations == 0
    and mismatch.quests[1].read_status == "unknown",
    "OT6 mismatched active object is unknown, never position- or flag-matched")
  task._calls.getActiveDestinations = mcoll({})
  local empty = oa.objective_task_snapshot({ qid }, catalog)
  assert(empty.quests[1].read_status == "ok" and #empty.quests[1].task_destinations == 0,
    "OT7 exact empty active destination set is known empty")
  task._calls.getActiveDestinations = nil
  local nil_active = oa.objective_task_snapshot({ qid }, catalog)
  assert(nil_active.quests[1].read_status == "ok"
    and #nil_active.quests[1].task_destinations == 0
    and #nil_active.quests[1].guidance == 1,
    "OT7b nil active destination collection is a known empty set")
  task._calls.getActiveDestinations = "RAISE"
  local unreadable = oa.objective_task_snapshot({ qid }, catalog)
  assert(unreadable.quests[1].read_status == "unknown"
    and unreadable.quests[1].reason == "destination_active_list_unreadable",
    "OT8 raised active destination read preserves a structured reason")
  local too_many = {}
  for i = 1, 257 do too_many[i] = native({}, {}, 0x1000 + i) end
  task._calls.getActiveDestinations = mcoll(too_many)
  local truncated = oa.objective_task_snapshot({ qid }, catalog)
  assert(truncated.quests[1].read_status == "unknown"
    and truncated.quests[1].reason == "destination_active_list_truncated",
    "OT8b active destination cap is explicit unknown")
  task._fields._Destinations = nil
  task._calls.getActiveDestinations = mcoll({})
  local source_unknown = oa.objective_task_snapshot({ qid }, catalog)
  assert(source_unknown.quests[1].read_status == "unknown"
    and source_unknown.quests[1].reason == "destination_source_list_unreadable",
    "OT8c missing source list is not mistaken for a known empty list")
  local source_too_many = {}
  for i = 1, 257 do source_too_many[i] = native({}, {}, 0x2000 + i) end
  task._fields._Destinations = mcoll(source_too_many)
  local source_truncated = oa.objective_task_snapshot({ qid }, catalog)
  assert(source_truncated.quests[1].read_status == "unknown"
    and source_truncated.quests[1].reason == "destination_source_list_truncated",
    "OT8d source destination cap is explicit unknown")
  task._fields._Destinations = mcoll({ live_dest, live_dest })
  task._calls.getActiveDestinations = mcoll({ live_dest })
  local source_duplicate = oa.objective_task_snapshot({ qid }, catalog)
  assert(source_duplicate.quests[1].read_status == "unknown"
    and source_duplicate.quests[1].reason == "destination_source_identity_ambiguous",
    "OT8e duplicate source identities do not choose a nondeterministic ordinal")
  task._fields._Destinations = mcoll({ stale_dest, live_dest })

  -- Concierge native truth is independent of archive flags. Status codes and
  -- evaluator failures stay visible as reasons, not guessed signals.
  task._calls.getActiveDestinations = mcoll({ live_dest })
  concierge_dest._calls.evaluate = 2
  local blocked = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(blocked.eligibility == "ineligible" and blocked.reason == "concierge_status_time",
    "OT9 nonzero status maps to its enum reason")
  concierge_dest._calls.evaluate = nil
  local status_unknown = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(status_unknown.eligibility == "unknown" and status_unknown.reason == "concierge_status_unreadable",
    "OT10 nil status remains unknown")
  concierge_dest._calls.evaluate = "RAISE"
  local status_raise = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(status_raise.eligibility == "unknown" and status_raise.reason == "concierge_status_exception",
    "OT11 raised status remains unknown")
  concierge_dest._calls.evaluate = 99
  local status_other = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(status_other.eligibility == "ineligible" and status_other.reason == "concierge_status_99",
    "OT11b unknown numeric status is retained in the reason")
  concierge_dest._calls.evaluate = 0
  concierge_dest._calls.evaluateRegisterCondition = false
  local disabled = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(disabled.eligibility == "ineligible" and disabled.reason == "concierge_register_condition_false",
    "OT12 exact false register result disables concierge signal")
  concierge_dest._calls.evaluateRegisterCondition = nil
  local register_unknown = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(register_unknown.eligibility == "unknown" and register_unknown.reason == "concierge_register_condition_unreadable",
    "OT13 nil register result remains unknown")
  concierge_dest._calls.evaluateRegisterCondition = "RAISE"
  local register_raise = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(register_raise.eligibility == "unknown"
    and register_raise.reason == "concierge_register_condition_exception",
    "OT13b raised register result remains unknown")
  concierge_dest._calls.evaluateRegisterCondition = true
  concierge._calls.get_Destinations = mcoll({})
  local concierge_empty = oa.objective_task_snapshot({ qid }, catalog).quests[1].guidance[1]
  assert(concierge_empty.eligibility == "unknown"
    and concierge_empty.reason == "concierge_no_current_destination"
    and #concierge_empty.signals == 0,
    "OT13c empty current concierge state is known empty")
  concierge._calls.get_Destinations = mcoll({ concierge_dest })

  -- A loaded target from another concierge task is never joined by ordinal.
  concierge._fields._TaskIndex = 1
  concierge._calls.get_TaskIndex = 1
  local adjacent = oa.objective_task_snapshot({ qid }, catalog).quests[1]
  assert(adjacent.guidance[1].eligibility == "ineligible"
    and adjacent.guidance[1].reason == "concierge_task_mismatch",
    "OT14 adjacent concierge task does not leak into the current task")

  concierge._calls.get_TaskIndex = 0
  info._calls.get_CurrentTaskIndex = 1
  local task_adjacent = oa.objective_task_snapshot({ qid }, catalog).quests[1]
  assert(task_adjacent.read_status == "unknown"
    and task_adjacent.reason == "current_task_catalog_mismatch",
    "OT14b adjacent journal task is not used as a fallback")
  info._calls.get_CurrentTaskIndex = 0

  local parser = dofile("reframework/autorun/Clairvoyance/npcs.lua")
  local saved_task_destinations = task._fields._Destinations
  local saved_active_destinations = task._calls.getActiveDestinations
  task._fields._Destinations = mcoll({ live_dest })
  task._calls.getActiveDestinations = mcoll({ live_dest })
  local _, parser_catalog = parser.parse_quests({ version = 2, quests = {
    [tostring(qid)] = { tasks = { { index = 0, has_destination = true, destinations = {
      { index = 0, set_destination = false, dest_type = 3, cid = cid, key = key,
        area = 19, local_area = 2, has_show_conditions = false, show_conditions = {},
        is_update_condition = false, has_display_conditions = false, display_conditions = {} },
    } } }, guidance = {}, deliveries = {}, sources = {} },
  } })
  local parser_task = oa.objective_task_snapshot({ qid }, parser_catalog)
  local no_catalog = oa.objective_task_snapshot({ qid }, nil).quests[1]
  local live_v1_catalog = oa.objective_task_snapshot({ qid }, { version = 1, quests = {} }).quests[1]
  assert(no_catalog.read_status == "ok" and no_catalog.task_index == 0
    and #no_catalog.task_destinations == 0
    and no_catalog.live_destination ~= nil and no_catalog.live_destination.target.cid == cid
    and live_v1_catalog.read_status == "ok" and live_v1_catalog.task_index == 0
    and live_v1_catalog.live_destination ~= nil
    and live_v1_catalog.live_destination.target.cid == cid,
    "OT17a missing and v1 catalogs retain independent live-native destination evidence")
  local integration_core = require("Clairvoyance.core")
  local no_catalog_snapshot = oa.objective_task_snapshot({ qid }, nil)
  local v1_catalog_snapshot = oa.objective_task_snapshot({ qid }, { version = 1, quests = {} })
  local no_catalog_core = integration_core.objective_snapshot(no_catalog_snapshot,
    { generation = 1, status = "unknown", places = {} }, {}, integration_core.target_registry_new())
  local v1_catalog_core = integration_core.objective_snapshot(v1_catalog_snapshot,
    { generation = 1, status = "unknown", places = {} }, {}, integration_core.target_registry_new())
  assert(no_catalog_snapshot.catalog_version == 0 and v1_catalog_snapshot.catalog_version == 0
    and no_catalog_core ~= nil and #no_catalog_core.targets == 1
    and no_catalog_core.targets[1].provider == "live_destination"
    and v1_catalog_core ~= nil and #v1_catalog_core.targets == 1
    and v1_catalog_core.targets[1].provider == "live_destination",
    "OT17b nil and v1 catalogs publish live targets through the core boundary")
  local invalid_boundary = oa.objective_task_snapshot({ qid }, nil)
  assert(invalid_boundary.catalog_version == 0
    and type(invalid_boundary.quests[1].source_descriptors) == "table",
    "OT17c no extension uses neutral catalog version and empty source descriptors")
  local saved_current_task_index = info._calls.get_CurrentTaskIndex
  info._calls.get_CurrentTaskIndex = nil
  local index_unknown = oa.objective_task_snapshot({ qid }, nil).quests[1]
  assert(index_unknown.read_status == "unknown" and index_unknown.task_index == nil,
    "OT17d missing native task index stays unknown and is never invented")
  info._calls.get_CurrentTaskIndex = saved_current_task_index
  local integrated = integration_core.objective_snapshot(parser_task,
    { generation = 1, status = "ok", places = { { qid = qid, task_index = 0,
      owner_kind = "task", owner_index = 0, signal_index = 0,
      target = { kind = "key_location", key = key }, pos = { x = 1, y = 2, z = 3 },
      eligibility = "eligible" } } }, {}, integration_core.target_registry_new())
  assert(parser_catalog.version == 2 and parser_task.quests[1].read_status == "ok"
    and integrated ~= nil and #integrated.targets == 2
    and integrated.targets[1].kind == "npc" and integrated.targets[2].kind == "place",
    "OT17 generated parser catalog flows through adapter into core task targets")
  task._fields._Destinations = saved_task_destinations
  task._calls.getActiveDestinations = saved_active_destinations

  -- Component generations advance independently, remain stable on repeats,
  -- and reset when the QuestLogManager owner changes.
  concierge._calls.get_TaskIndex = 0
  local g0 = oa.objective_task_snapshot({ qid }, catalog)
  local g1 = oa.objective_task_snapshot({ qid, 20050 }, catalog)
  assert(g1.focus_epoch == g0.focus_epoch + 1,
    "OT15 focus epoch advances only for a changed normalized focus set")
  local g2 = oa.objective_task_snapshot({ 20050, qid }, catalog)
  assert(g2.focus_epoch == g1.focus_epoch + 1,
    "OT15 ordered focus change advances its component")
  local owner_before = qlm
  qlm = native({}, {}, 0x202)
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestLogManager" then return qlm end
  end
  local reset = oa.objective_task_snapshot({ qid }, catalog)
  assert(reset.focus_epoch == 1 and reset.journal_generation == 1
    and reset.need_generation == 1,
    "OT16 owner reset invalidates all three generation components")
  qlm = owner_before
  sdk.get_managed_singleton = old_gms
end

print("adapter_load_test: OK")
