package.path = "./reframework/autorun/?.lua;" .. package.path

local ui = require("Clairvoyance.objective_ui")
local failures = 0
local function check(name, condition)
  if not condition then failures = failures + 1; print("FAIL: " .. name) end
end

check("public status names are stable",
  ui.status_text("available") == "Available"
    and ui.status_text("unavailable") == "Unavailable"
    and ui.status_text("unknown") == "Cannot verify")
check("technical reasons become concise public explanations",
  ui.reason_text("chest_opened") == "Already opened"
    and ui.reason_text("pickup_collected") == "Already collected"
    and ui.reason_text("reward_claimed") == "Already claimed"
    and ui.reason_text("wrong_current_task") == "Not part of the current objective"
    and ui.reason_text("processor_state_unreadable") == "Source state is unreadable"
    and ui.reason_text("source_unavailable") == "Source is unavailable"
    and ui.reason_text("monster_zero_count") == "Drop count is zero"
    and ui.reason_text("forgery_order_pending") == "Forgery is pending")
check("unknown reason codes never leak into public text",
  ui.reason_text("internal_new_reason_17") == "Source state cannot be verified")

local npc_key, source_key, unavailable_key = "target:npc", "target:source", "target:opened"
local npc_token, source_token, unavailable_token = ui.stable_token(npc_key),
  ui.stable_token(source_key), ui.stable_token(unavailable_key)
check("persisted controls use a JSON-safe reversible identity encoding",
  source_token == "k:7461726765743a736f75726365"
    and source_token:find("%z") == nil)
local snapshot = {
  generation = 8,
  need_groups = { { qid = 20090, task_index = 4, options = {
    { item_id = 501 }, { item_id = 502 },
  } } },
  targets = {
    { key = npc_key, generation = 8, ordinal = 1, eligibility = "eligible", kind = "npc",
      target = { cid = 77, pos = { x = 1, y = 2, z = 3 } }, item_ids = {},
      owners = { { qid = 20090, task_index = 4 } } },
    { key = source_key, generation = 8, ordinal = 2, eligibility = "eligible", kind = "source",
      provider = "reward", target = { pos = { x = 4, y = 5, z = 6 } }, item_ids = { 501 },
      owners = { { qid = 20090, task_index = 4 } } },
  },
  source_status = {
    { provider = "reward", generation = 8, complete = true, rows = {
      { scope = "source", generation = 8, identity = source_key, provider = "reward",
        qid = 20090, task_index = 4, state = "available", reason_code = "available",
        item_ids = { 501 } },
      { scope = "source", generation = 8, identity = unavailable_key, provider = "reward",
        qid = nil, task_index = nil, state = "unavailable", reason_code = "reward_claimed",
        item_ids = { 502 } },
    } },
    { provider = "monster", generation = 8, complete = false,
      reason_code = "monster_live_state_unavailable", rows = {
        { scope = "provider", generation = 8, identity = "provider:monster", provider = "monster",
          state = "unknown", reason_code = "monster_live_state_unavailable", item_ids = {} },
      } },
  },
}

local model = ui.build(snapshot, {
  focus_order = { 20090, 20091 },
  labels = { [npc_key] = "Trysha - Spellbound", [source_key] = "Fulminous Shield - Quest reward" },
  item_names = { [501] = "Fulminous Shield", [502] = "Nation's Death Knell" },
  marker_off = { source_token }, route_off = { npc_token },
})
local rows = model.by_qid[20090]
check("focused quest gets objective and provider-status rows", type(rows) == "table" and #rows == 4)
check("source status without explicit ownership attaches only to matching focused needs",
  type(model.by_qid[20091]) == "table" and #model.by_qid[20091] == 1
    and model.by_qid[20091][1].identity == "provider:monster")
local by_id = {}
for _, row in ipairs(rows or {}) do by_id[row.identity] = row end
check("labels name the actual NPC and item",
  by_id[npc_key].label:find("Trysha", 1, true) ~= nil
    and by_id[source_key].label:find("Fulminous Shield", 1, true) ~= nil
    and by_id[unavailable_key].label:find("Nation's Death Knell", 1, true) ~= nil)
check("marker and route choices remain independent",
  by_id[npc_key].marker_checked == true and by_id[npc_key].route_checked == false
    and by_id[source_key].marker_checked == false and by_id[source_key].route_checked == true
    and by_id[source_key].route_effective == false)
check("unavailable and unknown rows have disabled controls and public reasons",
  by_id[unavailable_key].controls_enabled == false
    and by_id[unavailable_key].status_text == "Unavailable"
    and by_id[unavailable_key].reason_text == "Already claimed"
    and by_id["provider:monster"].controls_enabled == false
    and by_id["provider:monster"].status_text == "Cannot verify")

local startable_model = ui.build({ generation = 9, targets = {
  { key = "target:startable-giver", generation = 9, ordinal = 1,
    eligibility = "eligible", kind = "npc",
    target = { cid = 88, pos = { x = 7, y = 8, z = 9 } },
    owners = { { qid = 20091 } } },
} }, { focus_order = { 20091 }, labels = {
  ["target:startable-giver"] = "Brant - Quest giver",
} })
check("focused startable quest exposes its normalized giver with controls",
  type(startable_model.by_qid[20091]) == "table"
    and #startable_model.by_qid[20091] == 1
    and startable_model.by_qid[20091][1].label == "Brant - Quest giver"
    and startable_model.by_qid[20091][1].controls_enabled == true)

local marker_keys, route_keys = ui.control_maps(model)
check("effective maps separately suppress marker and route targets",
  marker_keys[npc_key] == true and marker_keys[source_key] == nil
    and route_keys[npc_key] == nil and route_keys[source_key] == nil)

local marker_off, route_off, changed = ui.prune_overrides(
  { source_token, unavailable_token, "k:7374616c65" },
  { npc_token, "k:7374616c6532" }, model)
check("temporarily absent objectives retain valid persisted overrides",
  changed == true and #marker_off == 3 and marker_off[1] == "k:7374616c65"
    and marker_off[2] == unavailable_token and marker_off[3] == source_token
    and #route_off == 2 and route_off[1] == "k:7374616c6532"
    and route_off[2] == npc_token)
local toggled = ui.set_enabled({ source_token }, source_token, true)
check("enabling removes the stable identity from the off list", #toggled == 0)
toggled = ui.set_enabled(toggled, npc_token, false)
check("disabling stores the stable identity once", #toggled == 1 and toggled[1] == npc_token
  and #ui.set_enabled(toggled, npc_token, false) == 1)

local browser = ui.browser_step(nil, true, "shield", {
  { identity = source_key, provider = "reward", state = "available",
    reason_code = "available", item_ids = { 501 }, label = "Fulminous Shield - Quest reward" },
})
check("explicit source browser has its own generation and rows",
  browser.open == true and browser.generation == 1 and #browser.rows == 1)
local same = ui.browser_step(browser, true, "shield", browser.rows)
check("unchanged source browser input reuses its bounded generation", same.generation == 1)
local next_query = ui.browser_step(same, true, "death knell", {})
check("source browser query change advances its own generation", next_query.generation == 2)
local closed = ui.browser_step(next_query, false, "death knell", {})
check("closed source browser retains no source rows", closed.open == false and #closed.rows == 0)
check("source browser lease expires when its UI is no longer drawn",
  ui.browser_is_live(true, 100, 101) == true
    and ui.browser_is_live(true, 100, 103) == false
    and ui.browser_is_live(true, nil, 100) == false
    and ui.browser_is_live(false, 100, 100) == false)

local overflow_targets = {}
for i = 1, ui.ENTRY_MAX + 1 do
  overflow_targets[i] = { key = "target:overflow:" .. tostring(i), generation = 10,
    ordinal = i, eligibility = "eligible", kind = "source", provider = "placed",
    target = { pos = { x = i, y = 0, z = i } }, item_ids = { 501 },
    owners = { { qid = 20090, task_index = 4 } } }
end
local overflow_model = ui.build({ generation = 10, targets = overflow_targets }, {})
local overflow_markers, overflow_routes = ui.control_maps(overflow_model)
check("objective UI overflow is explicit passthrough instead of hiding every target",
  overflow_model.complete == false and overflow_model.reason_code == "objective_ui_target_overflow"
    and overflow_markers == nil and overflow_routes == nil)

local malformed_model = ui.build({ generation = 10, targets = {
  overflow_targets[1],
  { key = "target:malformed", generation = 10, ordinal = 2,
    eligibility = "eligible", kind = "source", provider = "placed",
    item_ids = { 501 }, owners = { { qid = 20090, task_index = 4 } } },
} }, {})
local malformed_markers, malformed_routes = ui.control_maps(malformed_model)
check("one malformed objective target makes the whole UI filter pass through",
  malformed_model.complete == false
    and malformed_model.reason_code == "objective_ui_target_invalid"
    and malformed_markers == nil and malformed_routes == nil)

local overflow_rows = {}
for i = 1, ui.ENTRY_MAX + 1 do
  overflow_rows[i] = { identity = "source:overflow:" .. tostring(i), provider = "placed",
    state = "available", reason_code = "available", item_ids = { 501 },
    label = "Fulminous Shield - Placed item" }
end
local overflow_browser = ui.browser_step(nil, true, "shield", {
  complete = true, rows = overflow_rows,
})
check("source browser row overflow is incomplete instead of silently empty",
  overflow_browser.open == true and overflow_browser.complete == false
    and overflow_browser.reason_code == "source_browser_status_overflow"
    and #overflow_browser.rows == 1
    and overflow_browser.rows[1].identity == "provider:source_browser")

if failures > 0 then os.exit(1) end
print("objective_ui_test: all OK")
