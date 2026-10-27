-- Bounded, read-only evidence probe for ROADMAP 93 Phase 0.
-- Run only through tools/probe/run.py. It calls native readers/evaluators on
-- engine-owned objects, retains nothing after the chunk, changes no settings,
-- and logs ids/counts/statuses but never coordinates.
local D = _G.QNML_DEBUG
assert(type(D) == "table" and type(D.focus) == "function",
  "QNML_DEBUG.focus unavailable")

local CAP = {
  quests = 8, destinations = 16, conditions = 32, dictionary = 512,
  dictionary_slots = 8192,
  storage_owners = 32, storage_items = 512, shops = 128, shop_rows = 256,
  holders = 512, pickups = 512, chests = 64, chest_items = 32,
  loot = 64, processors = 512, deliveries = 32,
}

local evidence = {}
local unresolved = {}
local delivery_refs = {}
local delivery_ref_total = 0
local delivery_refs_truncated = 0

local function note(name, value)
  evidence[name] = value
end

local function unknown(reason)
  unresolved[reason] = (unresolved[reason] or 0) + 1
end

local function F(o, name)
  if o == nil then return nil end
  local ok, value = pcall(function() return o:get_field(name) end)
  if ok then return value end
  return nil
end

local function field_result(o, name)
  if o == nil then return false, nil end
  local ok, value = pcall(function() return o:get_field(name) end)
  if ok then return true, value end
  return false, nil
end

local function call_result(o, name, ...)
  if o == nil then return false, nil end
  local args = { ... }
  local ok, a, b, c = pcall(function()
    return o:call(name, table.unpack(args))
  end)
  if ok then return true, a, b, c end
  return false, nil
end

local function C(o, name, ...)
  local ok, a, b, c = call_result(o, name, ...)
  if ok then return a, b, c end
  return nil
end

local function singleton(name)
  local ok, value = pcall(sdk.get_managed_singleton, name)
  if ok then return value end
  return nil
end

local function int_value(value)
  if type(value) == "number" then return math.tointeger(value) end
  local inner = F(value, "value__")
  if type(inner) == "number" then return math.tointeger(inner) end
  return nil
end

local function typename(value)
  if value == nil then return nil end
  local ok, name = pcall(function()
    return value:get_type_definition():get_full_name()
  end)
  if ok and type(name) == "string" then return name end
  return nil
end

local function object_id(value)
  if value == nil then return nil end
  local ok, address = pcall(function() return value:get_address() end)
  if ok and type(address) == "number" then return math.tointeger(address) end
  return nil
end

local function same_object(a, b)
  if a == nil or b == nil then return false end
  local aid, bid = object_id(a), object_id(b)
  if aid ~= nil and bid ~= nil then return aid == bid end
  local ok, equal = pcall(function() return a == b end)
  return ok and equal == true
end

local function valid_count(value)
  return type(value) == "number" and math.tointeger(value) == value and value >= 0
end

local function seq(value, cap)
  if value == nil then return {}, 0, false, false end

  local size_ok, size = pcall(function() return value:get_size() end)
  if size_ok and valid_count(size) then
    local out, complete = {}, true
    for i = 0, math.min(size, cap) - 1 do
      local item_ok, row = pcall(function() return value:get_element(i) end)
      if not item_ok or row == nil then complete = false break end
      out[#out + 1] = row
    end
    if complete then return out, size, size > cap, true end
  end

  local elements_ok, rows = pcall(function() return value:get_elements() end)
  local rows_type = type(rows)
  if elements_ok and rows_type == "table" then
    -- REFramework has returned both 0-based and 1-based Lua tables here.
    -- Numeric-key sorting handles both without trusting Lua's undefined #
    -- result for a table whose first key is zero.
    local keys = {}
    for key, row in pairs(rows) do
      if type(key) == "number" and row ~= nil then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local out, n = {}, #keys
    for i = 1, math.min(n, cap) do out[#out + 1] = rows[keys[i]] end
    return out, n, n > cap, true
  elseif elements_ok and rows ~= nil then
    -- In-game managed arrays return a sol vector userdata: # and one-based
    -- indexing work even though pairs() and type(...) == "table" do not.
    local count_ok, n = pcall(function() return #rows end)
    if count_ok and valid_count(n) then
      local out, complete = {}, true
      for i = 1, math.min(n, cap) do
        local item_ok, row = pcall(function() return rows[i] end)
        if not item_ok or row == nil then complete = false break end
        out[#out + 1] = row
      end
      if complete then return out, n, n > cap, true end
    end
  end

  local n = C(value, "get_Count")
  if not valid_count(n) then return {}, 0, false, false end
  local out, complete = {}, true
  for i = 0, math.min(n, cap) - 1 do
    local direct_ok, row = pcall(function() return value:get_element(i) end)
    if not direct_ok or row == nil then row = C(value, "get_Item", i) end
    if row == nil then complete = false break end
    out[#out + 1] = row
  end
  if not complete then return {}, 0, false, false end
  return out, n, n > cap, true
end

local function entry_value(entry)
  local value = F(entry, "value")
  if value == nil then value = F(entry, "Value") end
  return value
end

local function dict_entries(value, cap)
  if value == nil then return {}, 0, false, false end
  local slots, _, slot_capped, slots_readable =
    seq(F(value, "_entries"), CAP.dictionary_slots)
  if not slots_readable then return {}, 0, false, false end
  local out, total = {}, 0
  for _, entry in ipairs(slots) do
    if entry_value(entry) ~= nil then
      total = total + 1
      if #out < cap then out[#out + 1] = entry end
    end
  end
  local logical = int_value(C(value, "get_Count"))
  local readable = not slot_capped and (logical == nil or logical == total)
  return out, logical or total, slot_capped or total > cap, readable
end

local function bool_text(value)
  if type(value) == "boolean" then return tostring(value) end
  return "unknown"
end

local function value_text(value)
  local n = int_value(value)
  if n ~= nil then return tostring(n) end
  if type(value) == "boolean" then return tostring(value) end
  return "unknown"
end

local CONCIERGE_STATUS = {
  [0] = "Invalid", [1] = "NoDestination", [2] = "Time", [3] = "NoNavi",
  [4] = "ItemDelivery", [5] = "ItemDeliveryKeyInJunk",
  [6] = "CharacterUnavailable", [7] = "NoKnowledge",
  [8] = "NRDWhiteOutBreakGuide", [9] = "NRDWhiteOutCantGuide",
  [10] = "NRDWhiteOutChangeCamp", [11] = "FieldGuideNoNavi",
}

local function concierge_status_text(value)
  local n = int_value(value)
  if n == nil then return "unknown" end
  return (CONCIERGE_STATUS[n] or "UnknownStatus") .. "(" .. tostring(n) .. ")"
end

local function section(name, fn)
  local ok, result = pcall(fn)
  if ok then
    L("phase0 " .. name .. " " .. tostring(result or "ok"))
    return true
  end
  unknown(name .. "_error")
  L("phase0 " .. name .. " unknown")
  return false
end

local focus = D.focus()
local qlm = singleton("app.QuestLogManager")
local qm = singleton("app.QuestManager")
local im = singleton("app.ItemManager")
local gm = singleton("app.GimmickManager")
local qids, qset = {}, {}
local focus_active = type(focus) == "table" and focus.active or {}
if type(focus_active) ~= "table" then
  focus_active = {}
  unknown("focus_quests_unreadable")
elseif #focus_active > CAP.quests then
  unknown("focus_quests_truncated")
end
for _, qid in ipairs(focus_active) do
  qid = int_value(qid)
  if qid ~= nil and not qset[qid] and #qids < CAP.quests then
    qset[qid], qids[#qids + 1] = true, qid
  end
end
if #qids == 0 then
  local progressing = C(qlm, "getProgressingQuestIds")
  local rows, _, capped, readable = seq(progressing, CAP.quests)
  if not readable then unknown("progressing_quests_unreadable") end
  if capped then unknown("focus_quests_truncated") end
  for _, qid in ipairs(rows) do
    qid = int_value(qid)
    if qid ~= nil and not qset[qid] then
      qset[qid], qids[#qids + 1] = true, qid
    end
  end
end
if #qids == 0 then unknown("no_current_quest") end

local function quest_info(qid)
  local ok, info = pcall(function()
    return qlm:get_field("_QuestLogInfoDict"):call("get_Item", qid)
  end)
  if ok and info ~= nil then return info end
  return nil
end

section("destination", function()
  assert(qlm ~= nil, "manager")
  local found, active_total, source_total_all = 0, 0, 0
  for _, qid in ipairs(qids) do
    local info = quest_info(qid)
    local task = C(qlm, "getCurrentTask", qid)
    local task_index = int_value(C(info, "get_CurrentTaskIndex"))
      or int_value(F(info, "<CurrentTaskIndex>k__BackingField"))
    local focus_quest = type(focus) == "table" and type(focus.quests) == "table"
      and focus.quests[qid] or nil
    if task_index == nil and type(focus_quest) == "table"
      and type(focus_quest.objective) == "table" then
      task_index = int_value(focus_quest.objective.step)
    end
    local active_ok, active = call_result(task, "getActiveDestinations")
    local active_rows, active_total_one, active_capped, active_readable
    if active_ok and active == nil then
      -- This API returns nil for a valid empty active set (observed on a task
      -- whose parent destination gate is false).
      active_rows, active_total_one, active_capped, active_readable =
        {}, 0, false, true
    else
      active_rows, active_total_one, active_capped, active_readable =
        seq(active, CAP.destinations)
      active_readable = active_ok and active_readable
    end
    local source_rows, source_total, source_capped, source_readable =
      seq(F(task, "_Destinations"), CAP.destinations)
    local parent_gate = F(task, "_HasDestination")
    active_total = active_total + active_total_one
    source_total_all = source_total_all + source_total
    found = found + #active_rows
    if not active_readable then unknown("destination_active_list_unreadable") end
    if active_capped then unknown("destination_active_list_truncated") end
    if not source_readable then unknown("destination_source_list_unreadable") end
    if source_capped then unknown("destination_source_list_truncated") end
    if type(parent_gate) ~= "boolean" then
      unknown("destination_parent_gate_unreadable")
    end
    L(string.format(
      "phase0 destination quest=%d task=%s parent=%s active=%d/%s source=%d/%s",
      qid, tostring(task_index), bool_text(parent_gate), active_total_one,
      tostring(active_capped), source_total, tostring(source_capped)))
    local matched_active = {}
    for source_ordinal, dest in ipairs(source_rows) do
      local active_ordinal = nil
      for candidate_ordinal, candidate in ipairs(active_rows) do
        if same_object(dest, candidate) then
          active_ordinal = candidate_ordinal - 1
          matched_active[candidate_ordinal] = true
          break
        end
      end
      local show_ok, show = call_result(dest, "evaluateShow")
      local hide_ok, hide = call_result(dest, "evaluateHide")
      local update_ok, update = call_result(dest, "evaluateUpdateShow")
      local has_show = F(dest, "_HasShowConditions")
      local has_display = F(dest, "_HasDisplayConditions")
      local is_update = F(dest, "_IsUpdateCondition")
      local _, show_count, show_capped, show_readable =
        seq(F(dest, "_ShowConditions"), CAP.conditions)
      local _, display_count, display_capped, display_readable =
        seq(F(dest, "_Conditions"), CAP.conditions)
      if not show_ok or not hide_ok or not update_ok then
        unknown("destination_evaluator_exception")
      elseif type(show) ~= "boolean" or type(hide) ~= "boolean"
        or type(update) ~= "boolean" then
        unknown("destination_evaluator_unreadable")
      end
      if type(has_show) ~= "boolean" or type(has_display) ~= "boolean"
        or type(is_update) ~= "boolean" or not show_readable
        or not display_readable or show_capped or display_capped then
        unknown("destination_condition_state_unreadable")
      end
      local child_gate = F(dest, "_SetDestination")
      if type(child_gate) ~= "boolean" then
        unknown("destination_child_gate_unreadable")
      end
      L(string.format(
        "phase0 destination row quest=%d task=%s source_index=%d object=%s parent=%s child=%s active=%s active_index=%s type=%s cid=%s key=%s area=%s local=%s has_show=%s show_conditions=%d has_display=%s display_conditions=%d is_update=%s show=%s show_call=%s hide=%s hide_call=%s update=%s update_call=%s",
        qid, tostring(task_index), source_ordinal - 1,
        tostring(object_id(dest)), bool_text(parent_gate), bool_text(child_gate),
        tostring(active_ordinal ~= nil), tostring(active_ordinal),
        value_text(C(dest, "get_DestType")), value_text(C(dest, "get_CharaID")),
        value_text(C(dest, "get_KeyLocation")), value_text(C(dest, "get_Area")),
        value_text(C(dest, "get_LocalArea")), bool_text(has_show), show_count,
        bool_text(has_display), display_count, bool_text(is_update),
        bool_text(show), tostring(show_ok),
        bool_text(hide), tostring(hide_ok), bool_text(update), tostring(update_ok)))
    end
    for active_ordinal, dest in ipairs(active_rows) do
      if not matched_active[active_ordinal] then
        unknown("destination_object_mismatch")
        L(string.format(
          "phase0 destination unmatched quest=%d task=%s active_index=%d object=%s",
          qid, tostring(task_index), active_ordinal - 1, tostring(object_id(dest))))
      end
    end
  end
  if found == 0 then unknown("no_active_destination") end
  note("destination", found)
  return string.format("quests=%d active=%d source=%d rows=%d",
    #qids, active_total, source_total_all, found)
end)

local function storage_counts(item_id)
  if item_id == nil then return nil, nil, 1 end
  local party, box, skipped = 0, 0, 0
  local dict = C(im, "getStorageDict")
  local owners, _, capped, readable = dict_entries(dict, CAP.storage_owners)
  if capped or not readable then skipped = skipped + 1 end
  if #owners == 0 then return nil, nil, skipped + 1 end
  for _, owner in ipairs(owners) do
    local list = entry_value(owner)
    local key = int_value(F(owner, "key"))
    if list ~= nil and key ~= nil then
      local rows, _, over, list_readable = seq(list, CAP.storage_items)
      if over or not list_readable then skipped = skipped + 1 end
      for _, row in ipairs(rows) do
        if int_value(F(row, "_ItemId")) == item_id then
          local num = int_value(F(row, "_Num"))
          if num == nil then skipped = skipped + 1
          elseif key == 65535 then box = box + num
          else party = party + num end
        end
      end
    else skipped = skipped + 1 end
  end
  if skipped > 0 then return nil, nil, skipped end
  return party, box, skipped
end

section("concierge", function()
  assert(qlm ~= nil, "manager")
  local destinations, item_rows, threshold = 0, 0, 0
  for _, qid in ipairs(qids) do
    local info = quest_info(qid)
    local data = C(info, "getCurrentTaskConciergeData")
    local task_index = int_value(C(data, "get_TaskIndex"))
      or int_value(F(data, "_TaskIndex"))
    local focus_quest = type(focus) == "table" and type(focus.quests) == "table"
      and focus.quests[qid] or nil
    if task_index == nil and type(focus_quest) == "table"
      and type(focus_quest.objective) == "table" then
      task_index = int_value(focus_quest.objective.step)
    end
    local rows, total, capped, readable =
      seq(C(data, "get_Destinations"), CAP.destinations)
    local registerable, _, registerable_capped, registerable_readable =
      seq(C(data, "getRegisterableDestinations", qid), CAP.destinations)
    if not readable then unknown("concierge_list_unreadable") end
    if capped then unknown("concierge_destinations_truncated") end
    if not registerable_readable then
      unknown("concierge_registerable_list_unreadable")
    end
    if registerable_capped then unknown("concierge_registerable_list_truncated") end
    L(string.format(
      "phase0 concierge quest=%d task=%s destinations=%d registerable=%d capped=%s",
      qid, tostring(task_index), total, #registerable, tostring(capped)))
    for ordinal, dest in ipairs(rows) do
      destinations = destinations + 1
      local conds, cond_total, cond_cap, cond_readable =
        seq(F(dest, "_Conditions"), CAP.conditions)
      local dels, del_total, del_cap, del_readable =
        seq(C(dest, "get_DeliverData"), CAP.deliveries)
      local group = int_value(C(dest, "get_DeliveryGroupID"))
      local storage = C(dest, "get_DeliveryCheckStorage")
      local is_not = C(dest, "get_DeliveryIsNot")
      local status_ok, status = call_result(dest, "evaluate", qid)
      local register_ok, register =
        call_result(dest, "evaluateRegisterCondition", qid)
      if not status_ok or not register_ok then
        unknown("concierge_evaluator_exception")
      elseif int_value(status) == nil or type(register) ~= "boolean" then
        unknown("concierge_evaluator_unreadable")
      end
      if not cond_readable then unknown("concierge_conditions_unreadable") end
      if cond_cap then unknown("concierge_conditions_truncated") end
      if not del_readable then unknown("delivery_refs_unreadable") end
      delivery_ref_total = delivery_ref_total + del_total
      if del_cap then
        delivery_refs_truncated = delivery_refs_truncated + (del_total - #dels)
      end
      L(string.format(
        "phase0 concierge row quest=%d task=%s ordinal=%d status=%s status_call=%s register=%s register_call=%s npc=%s cid=%s gimmick=%s conditions=%d/%s delivery=%d/%s group=%s storage=%s is_not=%s",
        qid, tostring(task_index), ordinal, concierge_status_text(status),
        tostring(status_ok), bool_text(register), tostring(register_ok),
        bool_text(C(dest, "get_SetNpc")), value_text(C(dest, "get_CharaID")),
        value_text(C(dest, "get_GimmickID")), cond_total, tostring(cond_cap),
        del_total, tostring(del_cap), tostring(group), bool_text(storage), bool_text(is_not)))
      for cond_ordinal, selector in ipairs(conds) do
        local cond = C(selector, "get_Process")
        local tn = typename(cond) or "unknown"
        if tn == "app.ConciergeConditionItem" then
          item_rows = item_rows + 1
          local item_id = int_value(F(cond, "_ItemID"))
          local num = int_value(F(cond, "_Num"))
          local set_num = F(cond, "_SetNum")
          local is_not = F(cond, "_IsNot")
          local party, box, skipped, native_count = storage_counts(item_id)
          if item_id == nil then
            unknown("concierge_item_id_unreadable")
          else
            native_count = C(im, "getItemNumber", item_id)
          end
          local eval_ok, eval = call_result(cond, "evaluate", qid)
          if not eval_ok then unknown("concierge_item_evaluator_exception")
          elseif type(eval) ~= "boolean" then
            unknown("concierge_item_evaluator_unreadable")
          end
          if type(party) == "number" and party >= 2 then threshold = threshold + 1 end
          L(string.format(
            "phase0 concierge item quest=%d destination=%d condition=%d item=%s num=%s set_num=%s is_not=%s evaluate=%s evaluate_call=%s error=%s party=%s storage=%s native_count=%s skipped=%d",
            qid, ordinal, cond_ordinal, tostring(item_id), tostring(num),
            bool_text(set_num), bool_text(is_not), bool_text(eval), tostring(eval_ok),
            concierge_status_text(C(cond, "get_ErrorStatus")),
            tostring(party), tostring(box), tostring(native_count), skipped))
        end
      end
      for _, ref in ipairs(dels) do
        local ref_qid = int_value(C(ref, "get_QuestID"))
        local key = int_value(C(ref, "get_Key"))
        if ref_qid == nil or key == nil then
          unknown("delivery_ref_unreadable")
        elseif #delivery_refs >= CAP.deliveries then
          delivery_refs_truncated = delivery_refs_truncated + 1
        else
            delivery_refs[#delivery_refs + 1] = {
              qid = ref_qid, key = key, owner = qid, group = group,
              storage = storage, is_not = is_not,
            }
        end
      end
    end
  end
  if destinations == 0 then unknown("no_current_concierge") end
  if item_rows == 0 then unknown("no_current_concierge_item") end
  if threshold == 0 then unknown("no_item_threshold_control") end
  note("concierge", destinations)
  note("concierge_item", item_rows)
  if delivery_refs_truncated > 0 then unknown("delivery_refs_truncated") end
  return string.format(
    "destinations=%d item_rows=%d party_ge_2=%d refs=%d queued=%d truncated=%d",
    destinations, item_rows, threshold, delivery_ref_total, #delivery_refs,
    delivery_refs_truncated)
end)

section("shop", function()
  assert(im ~= nil, "manager")
  local reads = require("Clairvoyance.world").game_reads()
  local loaded = nil
  local holder_count = reads.holder_count()
  if not valid_count(holder_count) then
    unknown("shop_holders_unreadable")
    holder_count = 0
  elseif holder_count > CAP.holders then
    unknown("shop_holders_truncated")
  end
  for i = 0, math.min(holder_count, CAP.holders) - 1 do
    local holder = reads.holder_at(i)
    if holder ~= nil then
      local shop_id = reads.shop_of(holder.cid)
      if type(shop_id) == "number" and shop_id > 0 then
        local rank = reads.sentiment(holder.holder)
        loaded = { cid = holder.cid, shop = shop_id, rank = rank,
          position = reads.schedule_pos(holder.cid) ~= nil, holder = holder.holder }
        break
      end
    end
  end
  local available, disabled = nil, nil
  if loaded ~= nil then
    local nm = singleton("app.NPCManager")
    local tem = singleton("app.TalkEventManager")
    local chara = F(loaded.holder, "_chara")
    local data = C(nm, "getNPCCharacterData", loaded.cid)
    local board = C(chara, "get_AIBlackBoardController")
    available = C(tem, "isShopTalkEventAvailableForChara", data, board)
    disabled = C(tem, "isTalkEventInteractDisabled", loaded.cid)
  end

  local catalog_finite, catalog_unlimited = nil, nil
  local shop_joined_finite, shop_joined_unlimited, shop_joined_unavailable =
    nil, nil, nil
  local shops, shop_total, shop_cap, shops_readable =
    dict_entries(F(im, "ShopParamTable"), CAP.shops)
  if not shops_readable then unknown("shop_catalog_unreadable") end
  if shop_cap then unknown("shop_catalog_truncated") end
  local scanned_rows = 0
  for _, entry in ipairs(shops) do
    local shop_id = int_value(F(entry, "key"))
    local param = entry_value(entry)
    if shop_id ~= nil and param ~= nil then
      local rows, _, rows_capped, rows_readable =
        seq(F(param, "_BuyParams"), CAP.shop_rows)
      if not rows_readable then unknown("shop_rows_unreadable") end
      if rows_capped then unknown("shop_rows_truncated") end
      local pay = C(im, "getItemShopTotalPay", shop_id)
      for _, buy in ipairs(rows) do
        scanned_rows = scanned_rows + 1
        local stock = C(buy, "get_IsStock")
        local row = {
          shop = shop_id, item = int_value(F(buy, "_ItemId")), stock = stock,
          maximum = int_value(C(buy, "get_Stock")),
          remaining = int_value(C(im, "getItemStockNum", shop_id, buy)),
          loaded = loaded ~= nil and loaded.shop == shop_id,
        }
        if row.loaded then
          row.released = C(buy, "IsRelease", pay, loaded.rank)
        end
        if stock == true and catalog_finite == nil then catalog_finite = row end
        if stock == false and catalog_unlimited == nil then catalog_unlimited = row end
        local complete = row.loaded and type(row.item) == "number"
          and type(row.maximum) == "number" and type(row.remaining) == "number"
          and type(row.released) == "boolean"
        if complete and stock == true and shop_joined_finite == nil then
          shop_joined_finite = row
        end
        if complete and stock == false and shop_joined_unlimited == nil then
          shop_joined_unlimited = row
        end
        if complete and row.released == false and shop_joined_unavailable == nil then
          shop_joined_unavailable = row
        end
      end
    end
  end
  local function log_row(kind, row)
    if row == nil then unknown("shop_" .. kind); return end
    L(string.format(
      "phase0 shop %s shop=%s item=%s stock=%s maximum=%s remaining=%s release=%s loaded=%s",
      kind, tostring(row.shop), tostring(row.item), bool_text(row.stock),
      tostring(row.maximum), tostring(row.remaining), bool_text(row.released),
      tostring(row.loaded == true)))
  end
  if catalog_finite ~= nil then log_row("catalog_finite", catalog_finite) end
  if catalog_unlimited ~= nil then log_row("catalog_unlimited", catalog_unlimited) end
  log_row("joined_finite", shop_joined_finite)
  log_row("joined_unlimited", shop_joined_unlimited)
  if shop_joined_unavailable ~= nil then
    log_row("joined_unavailable", shop_joined_unavailable)
  else unknown("shop_unavailable_control") end
  local seller_usable = loaded ~= nil and loaded.position == true
    and available == true and disabled == false
  L(string.format(
    "phase0 shop seller loaded=%s cid=%s shop=%s position=%s available=%s disabled=%s usable=%s",
    tostring(loaded ~= nil), tostring(loaded and loaded.cid),
    tostring(loaded and loaded.shop), tostring(loaded and loaded.position),
    bool_text(available), bool_text(disabled), tostring(seller_usable)))
  if loaded == nil then unknown("no_loaded_shop_seller") end
  if loaded ~= nil and not seller_usable then unknown("shop_seller_unusable") end
  local joined = (shop_joined_finite and 1 or 0)
    + (shop_joined_unlimited and 1 or 0)
  note("shop", joined)
  return string.format("shops=%d/%s rows=%d seller=%s joined=%d", shop_total,
    tostring(shop_cap), scanned_rows, tostring(loaded ~= nil), joined)
end)

local gm_item_context_method, holder_item_context_method = nil, nil
local function find_item_context_method(type_name)
  local td = sdk.find_type_definition(type_name)
  for _, method in ipairs(td:get_methods()) do
    if method:get_name() == "getContext" and method:get_num_params() == 0
      and method:get_return_type():get_full_name() == "app.GmItemContext" then
      return method
    end
  end
end
pcall(function()
  gm_item_context_method = find_item_context_method("app.GimmickBase")
  holder_item_context_method = find_item_context_method("app.ContextHolder")
end)

local function named_upvalue(fn, wanted)
  if type(fn) ~= "function" then return nil end
  for i = 1, 64 do
    local name, value = debug.getupvalue(fn, i)
    if name == nil then break end
    if name == wanted then return value end
  end
  return nil
end

local function current_world_output()
  local adapter = named_upvalue(D.dump_steps, "adapter")
  local wt = named_upvalue(D.state, "wt")
  local out = { item_locations = {}, chests = {}, items_ok = false, chests_ok = false }
  if type(adapter) == "table" and type(adapter.item_locations) == "function" then
    local ok, rows = pcall(adapter.item_locations)
    if ok and type(rows) == "table" then
      out.item_locations, out.items_ok = rows, true
    end
  end
  if type(wt) == "table" and type(wt.q) == "function" then
    local ok, input = pcall(wt.q, "input", nil)
    if ok and type(input) == "table" and type(input.chests) == "table" then
      out.chests, out.chests_ok = input.chests, true
    end
  end
  return out
end

local function item_context_like(value)
  if value == nil then return false end
  local unlock_ok, unlock = field_result(value, "_IsUnlock")
  local pick_ok, pick = field_result(value, "_IsPick")
  local keep_ok, keep = field_result(value, "_IsKeep")
  return unlock_ok and pick_ok and keep_ok and type(unlock) == "boolean"
    and type(pick) == "boolean" and type(keep) == "boolean"
end

local function save_item_contexts()
  local loaded, world = pcall(require, "Clairvoyance.world")
  if not loaded or type(world) ~= "table" or type(world.game_reads) ~= "function" then
    return {}, "world_reads_unavailable"
  end
  local reads_ok, reads = pcall(world.game_reads)
  if not reads_ok or type(reads) ~= "table"
    or type(reads.save_records) ~= "function" then
    return {}, "save_records_unavailable"
  end
  local relevant_records = nil
  for i = 1, 64 do
    local name, value = debug.getupvalue(reads.save_records, i)
    if name == nil then break end
    if name == "relevant_records" and type(value) == "function" then
      relevant_records = value
      break
    end
  end
  if relevant_records == nil then return {}, "record_reader_unavailable" end
  local records_ok, records = pcall(relevant_records)
  if not records_ok or type(records) ~= "table" then
    return {}, "save_records_unreadable"
  end
  local out, count, complete, sample = {}, 0, 0, nil
  for _, record in ipairs(records) do
    local key = type(record.key) == "string" and record.key:lower() or nil
    local context = type(record.ctx) == "table" and record.ctx.GmItemContext or nil
    if key ~= nil and context ~= nil then
      if sample == nil then sample = key end
      out[key], count = context, count + 1
      if item_context_like(context) then complete = complete + 1 end
    end
  end
  return out, "save_records=" .. tostring(count) .. ",complete="
    .. tostring(complete) .. ",sample=" .. tostring(sample)
end

local function pickup_context(gimmick, saved)
  if gimmick == nil then return nil, "gimmick=nil", false, false end
  local trace = {}
  local guid_joined, live_context_present = false, false
  local function trace_value(label, value)
    trace[#trace + 1] = label .. "=" .. tostring(typename(value))
  end
  local guid = C(C(gimmick, "get_UniqId"), "ToString()")
  if type(guid) == "string" then
    local context = saved[guid:lower()]
    guid_joined = context ~= nil
    if item_context_like(context) then
      return context, "save_record_guid", guid_joined, live_context_present
    end
    trace[#trace + 1] = "save_record_guid=missing:" .. guid:lower()
  else
    trace[#trace + 1] = "uniq_id=unreadable"
  end
  local direct = C(gimmick, "get_GmContext")
  live_context_present = live_context_present or typename(direct) == "app.GmItemContext"
  if item_context_like(direct) then
    return direct, "gm_method", guid_joined, live_context_present
  end
  trace_value("gm_method", direct)
  direct = F(gimmick, "<GmContext>k__BackingField")
  live_context_present = live_context_present or typename(direct) == "app.GmItemContext"
  if item_context_like(direct) then
    return direct, "gm_field", guid_joined, live_context_present
  end
  trace_value("gm_field", direct)
  if gm_item_context_method ~= nil then
    local ok, value = pcall(function() return gm_item_context_method:call(gimmick) end)
    live_context_present = live_context_present or typename(value) == "app.GmItemContext"
    if ok and item_context_like(value) then
      return value, "gm_reflect", guid_joined, live_context_present
    end
    trace_value("gm_reflect", value)
  end
  local holder = C(gimmick, "get_CompContext")
  trace_value("holder", holder)
  if holder_item_context_method ~= nil and holder ~= nil then
    local ok, value = pcall(function() return holder_item_context_method:call(holder) end)
    live_context_present = live_context_present or typename(value) == "app.GmItemContext"
    if ok and item_context_like(value) then
      return value, "holder_reflect", guid_joined, live_context_present
    end
    trace_value("holder_reflect", value)
  end
  for _, dict_name in ipairs({ "RestoredContexts", "Contexts" }) do
    local rows, total, capped, readable =
      dict_entries(F(holder, dict_name), CAP.conditions)
    trace[#trace + 1] = string.format("%s=%d/%s/%s",
      dict_name, total, tostring(capped), tostring(readable))
    for _, entry in ipairs(rows) do
      local value = entry_value(entry)
      if dict_name == "Contexts" then
        value = F(value, "<CurrentContext>k__BackingField")
      end
      if typename(value) == "app.UniqueIDContext" then
        local holder_guid = C(F(value, "UniqueID"), "ToString()")
        if type(holder_guid) == "string" then
          local saved_context = saved[holder_guid:lower()]
          guid_joined = guid_joined or saved_context ~= nil
          if item_context_like(saved_context) then
            return saved_context, "holder_unique_id", guid_joined,
              live_context_present
          end
          trace[#trace + 1] = "holder_unique_id=missing:" .. holder_guid:lower()
        end
      end
      live_context_present = live_context_present
        or typename(value) == "app.GmItemContext"
      if item_context_like(value) then
        return value, dict_name, guid_joined, live_context_present
      end
      if #trace < 20 then trace_value(dict_name .. "_value", value) end
    end
  end
  return nil, table.concat(trace, ","), guid_joined, live_context_present
end

section("pickup", function()
  assert(gm ~= nil, "manager")
  local saved, saved_diagnostic = save_item_contexts()
  local world_output = current_world_output()
  local outer, total, capped, outer_readable = dict_entries(
    F(gm, "<ManagedGimmicksByIDs>k__BackingField"), CAP.dictionary)
  local matched, scanned, unreadable, guid_joined, live_contexts = 0, 0, 0, 0, 0
  local example, first_diagnostic, scan_truncated = nil, nil, false
  if not outer_readable then unknown("pickup_dictionary_unreadable") end
  if capped then scan_truncated = true end
  for _, outer_entry in ipairs(outer) do
    local inner, inner_total, inner_capped, inner_readable =
      dict_entries(entry_value(outer_entry), CAP.pickups)
    if not inner_readable then unknown("pickup_dictionary_unreadable") end
    if inner_capped then scan_truncated = true end
    for _, inner_entry in ipairs(inner) do
      if scanned < CAP.pickups then
        scanned = scanned + 1
        local gimmick = entry_value(inner_entry)
        if typename(gimmick) == "app.Gm82_000" then
          matched = matched + 1
          local context, context_path, joined, live_context =
            pickup_context(gimmick, saved)
          if joined then guid_joined = guid_joined + 1 end
          if live_context then live_contexts = live_contexts + 1 end
          local candidate = {
            item = int_value(F(gimmick, "ItemId")),
            num = int_value(F(gimmick, "ItemNum")),
            unlock = F(context, "_IsUnlock"), pick = F(context, "_IsPick"),
            keep = F(context, "_IsKeep"),
          }
          if type(candidate.item) == "number" and candidate.item > 0
            and type(candidate.num) == "number" and candidate.num > 0
            and type(candidate.unlock) == "boolean"
            and type(candidate.pick) == "boolean"
            and type(candidate.keep) == "boolean" then
            if example == nil then
              example = candidate
              example.context_path = context_path
            end
          else
            unreadable = unreadable + 1
            if first_diagnostic == nil then first_diagnostic = context_path end
          end
        end
      elseif inner_total > 0 then
        scan_truncated = true
      end
    end
  end
  if scan_truncated then unknown("pickup_scan_truncated") end
  if not world_output.items_ok then unknown("pickup_world_output_unreadable") end
  local world_placed = 0
  for _, row in ipairs(world_output.item_locations) do
    if type(row) == "table" and row.src == "placed" then world_placed = world_placed + 1 end
  end
  if example == nil and matched == 0 then unknown("no_loaded_pickup")
  elseif example == nil then
    unknown("pickup_context_unreadable")
    L("phase0 pickup diagnostic " .. tostring(saved_diagnostic)
      .. "," .. tostring(first_diagnostic))
  else
    L(string.format(
      "phase0 pickup example item=%s num=%s unlock=%s pick=%s keep=%s context=%s",
      tostring(example.item), tostring(example.num), bool_text(example.unlock),
      bool_text(example.pick), bool_text(example.keep), tostring(example.context_path)))
  end
  note("pickup", example and 1 or 0)
  return string.format(
    "loaded=%d scanned=%d unreadable=%d guid_joined=%d live_contexts=%d world_placed=%d outer=%d capped=%s",
    matched, scanned, unreadable, guid_joined, live_contexts, world_placed,
    total, tostring(scan_truncated))
end)

local function chest_evidence_readable(candidate)
  return candidate ~= nil and type(candidate.item) == "number"
    and candidate.item > 0 and type(candidate.num) == "number"
    and candidate.num > 0 and type(candidate.item_total) == "number"
    and candidate.item_total > 0 and type(candidate.opened) == "boolean"
    and type(candidate.unlocked) == "boolean"
    and type(candidate.pick) == "boolean" and type(candidate.keep) == "boolean"
end

section("chest", function()
  assert(gm ~= nil, "manager")
  local world_output = current_world_output()
  local rows, total, capped, rows_readable =
    seq(F(gm, "<TreasureBoxGimmicks>k__BackingField"), CAP.chests)
  if not rows_readable then unknown("chest_rows_unreadable") end
  if capped then unknown("chest_rows_truncated") end
  if not world_output.chests_ok then unknown("chest_world_output_unreadable") end
  local example, unreadable = nil, 0
  for _, chest in ipairs(rows) do
    if chest ~= nil and example == nil then
      local item_rows, item_total, items_capped, items_readable =
        seq(F(chest, "ItemList"), CAP.chest_items)
      local item = item_rows[1]
      local context = F(chest, "ItemContext")
      local uid = C(C(chest, "get_UniqId"), "ToString()")
      local candidate = {
        item = int_value(F(item, "ItemId")), num = int_value(F(item, "ItemNum")),
        item_total = item_total, opened = C(chest, "get_IsOpenedFreeBit"),
        unlocked = C(chest, "get_IsUnlockFreeBit"),
        pick = F(context, "_IsPick"), keep = F(context, "_IsKeep"),
        uid = type(uid) == "string" and uid:lower() or nil,
      }
      if items_readable and not items_capped and chest_evidence_readable(candidate) then
        example = candidate
      else
        unreadable = unreadable + 1
      end
    end
  end
  if example == nil and #rows == 0 then unknown("no_loaded_chest")
  elseif example == nil then unknown("chest_evidence_unreadable")
  else
    local world_match = nil
    for _, row in ipairs(world_output.chests) do
      if type(row) == "table" and type(row.uid) == "string"
        and example.uid ~= nil and row.uid:lower() == example.uid then
        world_match = row
        break
      end
    end
    if world_match == nil then unknown("chest_world_output_unmatched") end
    L(string.format(
      "phase0 chest example item=%s num=%s items=%d opened=%s unlocked=%s pick=%s keep=%s world_match=%s world_state=%s world_item=%s",
      tostring(example.item), tostring(example.num), example.item_total,
      bool_text(example.opened), bool_text(example.unlocked),
      bool_text(example.pick), bool_text(example.keep), tostring(world_match ~= nil),
      tostring(world_match and world_match.state),
      tostring(world_match and world_match.item)))
  end
  note("chest", example and 1 or 0)
  return string.format("loaded=%d readable=%d unreadable=%d total=%d capped=%s",
    #rows, example and 1 or 0, unreadable, total, tostring(capped))
end)

section("loot", function()
  assert(gm ~= nil, "manager")
  local rows, total, capped, rows_readable =
    seq(F(gm, "<DropItemGimmicks>k__BackingField"), CAP.loot)
  if not rows_readable then unknown("loot_rows_unreadable") end
  if capped then unknown("loot_rows_truncated") end
  local positive, deleted, unreadable, example = 0, 0, 0, nil
  for _, drop in ipairs(rows) do
    local is_deleted = F(drop, "<IsDeleted>k__BackingField")
    local context = F(drop, "MyContext")
    local item = int_value(F(F(drop, "MyContext"), "_ItemId"))
    local num = int_value(F(context, "_Num"))
    if is_deleted == true then deleted = deleted + 1 end
    if type(is_deleted) ~= "boolean" or item == nil or num == nil then
      unreadable = unreadable + 1
    elseif is_deleted == false and num > 0 and item > 0 then
      positive = positive + 1
      if example == nil then
        example = { item = item, num = num, deleted = is_deleted }
      end
    end
  end
  if unreadable > 0 then unknown("loot_state_unreadable") end
  if example == nil then unknown("no_positive_loaded_loot")
  else
    L(string.format("phase0 loot example item=%s num=%d deleted=%s",
      tostring(example.item), example.num, bool_text(example.deleted)))
  end
  note("loot", positive)
  return string.format("positive=%d deleted=%d unreadable=%d total=%d capped=%s",
    positive, deleted, unreadable, total, tostring(capped))
end)

section("grant", function()
  assert(qm ~= nil, "manager")
  local processors, total, capped, processors_readable =
    seq(F(qm, "DistributedQuestProcessors"), CAP.processors)
  if not processors_readable then unknown("grant_processors_unreadable") end
  if capped then unknown("grant_processors_truncated") end
  local current, descriptors, relevant, payload_add_rows = 0, 0, 0, 0
  for _, processor in ipairs(processors) do
    local process = F(processor, "Process")
    local qid = int_value(C(process, "get_QuestID"))
    if qset[qid] then
      current = current + 1
      local action = F(process, "QuestAction")
      local tn = typename(action) or "unknown"
      if tn:find("QuestReward", 1, true) or tn:find("ItemControl", 1, true)
        or tn:lower():find("gift", 1, true) then
        descriptors = descriptors + 1
        -- DistributedQuestProcessors proves quest ownership but exposes no
        -- task index. Until the generated task graph supplies an exact join,
        -- this action is a descriptor, never a current objective candidate.
        local task_owned = nil
        unknown("grant_task_ownership_unknown")
        local executed, canceled = C(process, "get_Executed"), C(process, "get_Canceled")
        local done, action_canceled = C(action, "get_DoneAction"), C(action, "get_CanceledAction")
        if type(executed) ~= "boolean" or type(canceled) ~= "boolean"
          or type(done) ~= "boolean" or type(action_canceled) ~= "boolean" then
          unknown("grant_state_unreadable")
        end
        local payload = 0
        if tn == "app.quest.action.ItemControl" then
          local data = F(action, "Data")
          local setting = F(data, "_ItemGet")
          local rows, _, rows_capped, rows_readable =
            seq(C(setting, "get_ItemList"), CAP.conditions)
          if rows_capped or not rows_readable then unknown("grant_payload_unreadable") end
          for _, row in ipairs(rows) do
            if C(row, "get_IsRemove") == false then
              payload = payload + 1
              payload_add_rows = payload_add_rows + 1
            end
          end
        elseif tn == "app.quest.action.QuestReward" then
          local param = C(action, "get_Data")
          local rows, _, rows_capped, rows_readable =
            seq(C(param, "get_DataList"), CAP.conditions)
          if rows_capped or not rows_readable then unknown("grant_payload_unreadable") end
          payload = #rows
        end
        L(string.format(
          "phase0 grant quest=%d type=%s task_owned=%s executed=%s canceled=%s done=%s action_canceled=%s payload=%d",
          qid, tn, bool_text(task_owned), bool_text(executed), bool_text(canceled),
          bool_text(done), bool_text(action_canceled), payload))
      end
    end
  end
  if descriptors == 0 then unknown("no_current_grant_action") end
  note("grant", relevant)
  return string.format(
    "current_processors=%d descriptors=%d task_owned=%d payload_add_rows=%d total=%d capped=%s",
    current, descriptors, relevant, payload_add_rows, total, tostring(capped))
end)

section("transform", function()
  assert(im ~= nil, "manager")
  local mix_rows, mix_total, mix_capped, mix_readable =
    dict_entries(F(im, "ItemMixParamTable"), CAP.dictionary)
  if not mix_readable then unknown("transform_crafting_catalog_unreadable") end
  if mix_capped then unknown("transform_crafting_catalog_truncated") end

  local fake_item_ok, fake_item = call_result(im, "get_FakeShopKeepedItem")
  local fake_time_ok, fake_time = call_result(im, "get_FakeShopCompleteTime")
  local fake_done_ok, fake_done = call_result(im, "isFakeShopCompleted")
  if not fake_item_ok or not fake_time_ok or not fake_done_ok then
    unknown("transform_forgery_state_unreadable")
  end

  local decay_interval_ok, decay_interval = field_result(im, "DecayInterval")
  local decay_elapsed_ok, decay_elapsed = field_result(im, "DecayElapsedTime")
  local decay_check_ok, decay_check = field_result(im, "DecayCheckTime")
  if not decay_interval_ok or not decay_elapsed_ok or not decay_check_ok then
    unknown("transform_ageing_state_unreadable")
  end

  -- The manager exposes recipe/input/completion/timing seams, but this save
  -- exposes no exact service identity/location/access join for these families.
  -- They are descriptors only and must not become eligible objectives.
  unknown("transform_crafting_service_unknown")
  unknown("transform_forgery_service_unknown")
  unknown("transform_ageing_service_unknown")
  note("transform", 0)
  return string.format(
    "mix=%d/%s fake_item=%s fake_time=%s fake_done=%s decay_interval=%s decay_elapsed=%s decay_check=%s eligible=0",
    #mix_rows, tostring(mix_total), value_text(fake_item), value_text(fake_time),
    bool_text(fake_done), value_text(decay_interval), value_text(decay_elapsed),
    value_text(decay_check))
end)

section("delivery", function()
  local manager = singleton("app.QuestDeliverManager")
  assert(manager ~= nil, "manager")
  local resolved = 0
  for ordinal, ref in ipairs(delivery_refs) do
    local has_ok, has = call_result(manager, "hasDeliver", ref.qid, ref.key)
    local finish_ok, finish = call_result(manager, "isFinish", ref.qid, ref.key)
    local dict_ok, contexts = field_result(manager, "_ContextDict")
    local inner_ok, inner = call_result(contexts, "get_Item", ref.qid)
    local context_ok, context = call_result(inner, "get_Item", ref.key)
    local data_ok, data = field_result(context, "Data")
    local item_ok, item_data = call_result(data, "get_Item")
    local values_ok, value_collection = call_result(item_data, "get_Value")
    local values, alternatives, alternatives_capped, alternatives_readable =
      seq(value_collection, CAP.conditions)
    local operator_ok, operator_value = call_result(item_data, "get_Operator")
    local operator = int_value(operator_value)
    local incomplete = F(item_data, "_IncompletePossible")
    local context_finish_ok, context_finish = call_result(context, "get_IsFinish")
    local complete = has_ok and type(has) == "boolean"
      and finish_ok and type(finish) == "boolean"
      and dict_ok and contexts ~= nil and inner_ok and inner ~= nil
      and context_ok and context ~= nil and data_ok and data ~= nil
      and item_ok and item_data ~= nil and values_ok and alternatives_readable
      and not alternatives_capped and alternatives > 0
      and operator_ok and operator ~= nil
      and type(incomplete) == "boolean"
      and context_finish_ok and type(context_finish) == "boolean"
      and int_value(ref.group) ~= nil and type(ref.storage) == "boolean"
      and type(ref.is_not) == "boolean"
    local value_rows, required_total, ignored, infinite, all_item = 0, 0, 0, 0, 0
    for _, value in ipairs(values) do
      local ids_ok, id_collection = field_result(value, "_ItemID")
      local ids, count, ids_capped, ids_readable =
        seq(id_collection, CAP.conditions)
      value_rows = value_rows + count
      local infinite_value = F(value, "_IsInfinite")
      local count_value = int_value(F(value, "_Count"))
      local ignored_ids, ignored_count, ignored_capped, ignored_readable =
        seq(F(value, "_IgnoreRestrictionItem"), CAP.conditions)
      local all_ok, all_value = call_result(value, "get_IsAllItem")
      if infinite_value == true then infinite = infinite + 1 end
      if all_value == true then all_item = all_item + 1 end
      if count_value ~= nil then required_total = required_total + count_value end
      ignored = ignored + ignored_count
      if not ids_ok or not ids_readable or ids_capped or #ids == 0
        or type(infinite_value) ~= "boolean" or not all_ok
        or type(all_value) ~= "boolean" or count_value == nil
        or not ignored_readable or ignored_capped then
        complete = false
      end
      for _, item_id in ipairs(ids) do
        if int_value(item_id) == nil then complete = false end
      end
      for _, item_id in ipairs(ignored_ids) do
        if int_value(item_id) == nil then complete = false end
      end
    end
    if not complete then unknown("delivery_ref_unresolved")
    else resolved = resolved + 1 end
    L(string.format(
      "phase0 delivery ordinal=%d owner=%d quest=%d key=%d group=%s storage=%s is_not=%s has=%s finish=%s context_finish=%s incomplete=%s operator=%s alternatives=%d ids=%d required=%d ignored=%d all_item=%d infinite=%d resolved=%s",
      ordinal, ref.owner, ref.qid, ref.key, tostring(ref.group),
      bool_text(ref.storage), bool_text(ref.is_not), bool_text(has), bool_text(finish),
      bool_text(context_finish), bool_text(incomplete), tostring(operator), alternatives,
      value_rows, required_total, ignored, all_item, infinite, tostring(complete)))
  end
  if delivery_ref_total == 0 then unknown("no_current_delivery") end
  note("delivery", resolved)
  return string.format("refs=%d queued=%d resolved=%d truncated=%d",
    delivery_ref_total, #delivery_refs, resolved, delivery_refs_truncated)
end)

section("unresolved", function()
  local keys = {}
  for key in pairs(unresolved) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    L(string.format("phase0 unresolved reason=%s count=%d", key, unresolved[key]))
  end
  local parts = {}
  for _, key in ipairs({ "destination", "concierge", "concierge_item", "shop",
    "pickup", "chest", "loot", "grant", "transform", "delivery" }) do
    parts[#parts + 1] = key .. "=" .. tostring(evidence[key] or 0)
  end
  return table.concat(parts, " ") .. " unresolved=" .. tostring(#keys)
end)

return string.format("phase0 complete quests=%d unresolved=%d", #qids,
  (function() local n = 0; for _ in pairs(unresolved) do n = n + 1 end; return n end)())
