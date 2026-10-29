-- Bounded, read-only join probe for quest reward providers.
-- It reads the current focus/task need projection plus RewardDict and active
-- distributed processors. It publishes no source and changes no state.
local D = _G.QNML_DEBUG
assert(type(D) == "table" and type(D.focus) == "function", "QNML_DEBUG.focus unavailable")

local CAP = { rewards = 512, processors = 512, params = 32, rows = 32, tree = 64 }
local function L(s) log.info("CHK reward " .. s) end
local function F(o, name)
  if o == nil then return nil end
  local ok, value = pcall(function() return o:get_field(name) end)
  if ok then return value end
end
local function I(value)
  if type(value) ~= "number" then value = F(value, "value__") end
  return type(value) == "number" and math.tointeger(value) or nil
end
local function type_name(value)
  if value == nil then return nil end
  local ok, name = pcall(function() return value:get_type_definition():get_full_name() end)
  return ok and type(name) == "string" and name or nil
end
local function seq(value, cap)
  if value == nil then return {}, 0, false, false end
  local elements_ok, elements = pcall(function() return value:get_elements() end)
  if elements_ok and elements ~= nil and type(elements) == "table" then
    local keys = {}
    for key, row in pairs(elements) do
      if type(key) == "number" and row ~= nil then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local out, count = {}, #keys
    for i = 1, math.min(count, cap) do out[#out + 1] = elements[keys[i]] end
    return out, count, count > cap, count <= cap
  elseif elements_ok and elements ~= nil then
    local size_ok, size = pcall(function() return #elements end)
    if size_ok and type(size) == "number" and size >= 0 and math.tointeger(size) == size then
      local out, readable = {}, size <= cap
      for index = 1, math.min(size, cap) do
        local ok, row = pcall(function() return elements[index] end)
        if not ok or row == nil then readable = false else out[#out + 1] = row end
      end
      return out, size, size > cap, readable
    end
  end
  local count = I(reviewed_call(value, "get_Count"))
  if count == nil or count < 0 then return {}, 0, false, false end
  local out, readable, direct_index = {}, count <= cap, true
  for index = 0, math.min(count, cap) - 1 do
    local row = reviewed_call(value, "get_Item", index)
    if row == nil then direct_index = false; break end
    out[#out + 1] = row
  end
  if not direct_index then
    out, readable = {}, count <= cap
    local size_ok, size = pcall(function() return #value end)
    if not size_ok or type(size) ~= "number" or size ~= count then
      return {}, count, count > cap, false
    end
    for index = 1, math.min(count, cap) do
      local ok, row = pcall(function() return value[index] end)
      if not ok or row == nil then readable = false else out[#out + 1] = row end
    end
  end
  return out, count, count > cap, readable
end
local function bool_text(value)
  if type(value) == "boolean" then return tostring(value) end
  return "unknown"
end
local function collect_hashes(action)
  local rows, hashes = {}, {}
  local params, _, capped, readable = seq(F(action, "_Param"), CAP.params)
  if capped or not readable then return hashes, false end
  for _, param in ipairs(params) do
    local data, _, data_capped, data_readable = seq(F(param, "_DataList"), CAP.rows)
    if data_capped or not data_readable then return hashes, false end
    for _, row in ipairs(data) do
      local hash = I(F(row, "_NameHash"))
      if hash == nil or hash < 0 or hash > 4294967295 then return hashes, false end
      hashes[#hashes + 1] = hash
    end
  end
  return hashes, true
end

local focus = D.focus()
assert(type(focus) == "table", "focus snapshot unavailable")
local focused, wanted, needs_complete = {}, {}, type(focus.objective_snapshot) == "table"
for _, qid in ipairs(focus.active or {}) do
  if type(qid) == "number" and math.tointeger(qid) == qid and qid > 0 then focused[qid] = true end
end
for _, group in ipairs(focus.objective_snapshot and focus.objective_snapshot.need_groups or {}) do
  if type(group) ~= "table" or group.complete ~= true or group.status ~= "ok"
      or type(group.remaining) ~= "number" or group.remaining <= 0
      or type(group.options) ~= "table" then
    needs_complete = false
  else
    for _, option in ipairs(group.options) do
      local item_id = type(option) == "table" and option.item_id or nil
      if type(item_id) ~= "number" or math.tointeger(item_id) ~= item_id or item_id <= 0 then
        needs_complete = false
      else
        wanted[item_id] = true
      end
    end
  end
end
for qid in pairs(focused) do
  local quest = type(focus.quests) == "table" and focus.quests[qid] or nil
  local objective = type(quest) == "table" and quest.objective or nil
  local ids = {}
  for _, item_id in ipairs(type(objective) == "table" and objective.items or {}) do
    if type(item_id) == "number" and math.tointeger(item_id) == item_id and item_id > 0 then
      wanted[item_id], ids[#ids + 1] = true, item_id
    else
      needs_complete = false
    end
  end
  table.sort(ids)
  L(string.format("focused_quest qid=%d task=%s known=%s objective_items=%d",
    qid, tostring(type(objective) == "table" and objective.step or nil),
    tostring(type(objective) == "table" and objective.known == true), #ids))
end
local needed_n = 0
for _ in pairs(wanted) do needed_n = needed_n + 1 end
L(string.format("focus quests=%d complete_needs=%s needed_items=%d",
  (function() local n = 0; for _ in pairs(focused) do n = n + 1 end; return n end)(),
  tostring(needs_complete), needed_n))

local qm = sdk.get_managed_singleton("app.QuestManager")
assert(qm ~= nil, "QuestManager unavailable")
local reward_dict = F(qm, "RewardDict")
local entries, reward_total, reward_capped, reward_readable =
  seq(F(reward_dict, "_entries"), CAP.rewards)
local outputs_by_hash, reward_count, item_rows, matched_hashes = {}, 0, 0, 0
for _, entry in ipairs(entries) do
  local reward = F(entry, "value") or F(entry, "Value")
  if reward ~= nil then
    local hash = I(F(entry, "key"))
    if hash == nil or hash < 0 or hash > 4294967295 then
      reward_readable = false
    else
      reward_count = reward_count + 1
      local values, _, values_capped, values_readable = seq(F(reward, "_ItemList"), CAP.rows)
      if values_capped or not values_readable then
        reward_readable = false
      else
        local outputs = {}
        for _, row in ipairs(values) do
          local item_id, count = I(F(row, "_ItemId")), I(F(row, "_Num"))
          item_rows = item_rows + 1
          if item_id == nil or item_id <= 0 or count == nil or count <= 0 then
            reward_readable = false
          else
            outputs[#outputs + 1] = { item_id = item_id, count = count }
            if wanted[item_id] then matched_hashes = matched_hashes + 1 end
          end
        end
        outputs_by_hash[hash] = outputs
      end
    end
  end
end
L(string.format("catalog entries=%d/%d capped=%s readable=%s item_rows=%d matching_hashes=%d",
  reward_count, reward_total, tostring(reward_capped), tostring(reward_readable),
  item_rows, matched_hashes))

local processors, processor_total, processor_capped, processor_readable =
  seq(F(qm, "DistributedQuestProcessors"), CAP.processors)
local by_id, rows, focused_processors, focused_reward_actions = {}, {}, 0, 0
for _, processor in ipairs(processors) do
  local proc_id = I(F(processor, "ProcID"))
  local process = F(processor, "Process")
  local qid = I(reviewed_call(process, "get_QuestID"))
  local action = F(process, "QuestAction")
  local action_type = type_name(action)
  if focused[qid] then
    focused_processors = focused_processors + 1
    if action_type == "app.quest.action.QuestReward" then focused_reward_actions = focused_reward_actions + 1 end
  end
  if proc_id ~= nil then by_id[proc_id] = { processor = processor,
    process = process, action = action, qid = qid } end
  if qid ~= nil and action ~= nil and action_type == "app.quest.action.QuestReward" then
    local hashes, payload_readable = collect_hashes(action)
    for _, hash in ipairs(hashes) do
      local outputs = outputs_by_hash[hash]
      local relevant = focused[qid] == true
      for _, output in ipairs(outputs or {}) do
        if wanted[output.item_id] then relevant = true end
      end
      if relevant then
        local executed, canceled = reviewed_call(process, "get_Executed"), reviewed_call(process, "get_Canceled")
        local done, action_canceled = reviewed_call(action, "get_DoneAction"),
          reviewed_call(action, "get_CanceledAction")
        rows[#rows + 1] = { processor = processor, process = process, action = action,
          qid = qid, proc_id = proc_id, hash = hash, outputs = outputs or {},
          payload_readable = payload_readable, executed = executed, canceled = canceled,
          done = done, action_canceled = action_canceled }
      end
    end
  end
end
L(string.format("processors=%d/%d capped=%s readable=%s focused_processors=%d focused_reward_actions=%d relevant_reward_rows=%d",
  #processors, processor_total, tostring(processor_capped), tostring(processor_readable),
  focused_processors, focused_reward_actions, #rows))

local function walk_condition(condition, active, edge_rows)
  if condition == nil then return false end
  local elements, _, capped, readable = seq(F(condition, "_ElementArray"), CAP.tree)
  if capped or not readable then return false end
  local function walk(element, depth)
    if depth > CAP.tree then return false end
    local params, _, pc, pr = seq(F(element, "_ParamArray"), CAP.tree)
    local children, _, cc, cr = seq(F(element, "_ElementArray"), CAP.tree)
    if pc or cc or not pr or not cr then return false end
    local operator = I(F(element, "_Operator"))
    for _, param in ipairs(params) do
      local pred_id, result_no = I(F(param, "_ProcID")), I(F(param, "_ResultNo"))
      local pred = pred_id ~= nil and by_id[pred_id] or nil
      local pred_type = pred ~= nil and type_name(pred.action) or "missing"
      edge_rows[#edge_rows + 1] = { proc_id = pred_id, result_no = result_no,
        operator = operator, action_type = pred_type,
        executed = pred and reviewed_call(pred.process, "get_Executed") or nil,
        canceled = pred and reviewed_call(pred.process, "get_Canceled") or nil }
    end
    for _, child in ipairs(children) do if not walk(child, depth + 1) then return false end end
    return true
  end
  for _, root in ipairs(elements) do if not walk(root, 1) then return false end end
  return true
end
for _, row in ipairs(rows) do
  local edges = {}
  local branch_readable = walk_condition(F(row.processor, "PrevProcCondition"), {}, edges)
  L(string.format("row quest=%d processor=%s hash=%u focused=%s outputs_match_need=%s executed=%s canceled=%s done=%s action_canceled=%s payload_readable=%s outputs=%d branch_readable=%s edges=%d",
    row.qid, tostring(row.proc_id), row.hash, tostring(focused[row.qid] == true),
    tostring((function() for _, output in ipairs(row.outputs) do if wanted[output.item_id] then return true end end; return false end)()),
    bool_text(row.executed), bool_text(row.canceled), bool_text(row.done),
    bool_text(row.action_canceled), tostring(row.payload_readable), #row.outputs,
    tostring(branch_readable), #edges))
  for _, edge in ipairs(edges) do
    L(string.format("edge quest=%d reward_processor=%s predecessor=%s result=%s operator=%s type=%s executed=%s canceled=%s",
      row.qid, tostring(row.proc_id), tostring(edge.proc_id), tostring(edge.result_no),
      tostring(edge.operator), tostring(edge.action_type), bool_text(edge.executed),
      bool_text(edge.canceled)))
  end
end
return string.format("reward complete needs=%s catalog_readable=%s processors_readable=%s relevant=%d",
  tostring(needs_complete), tostring(reward_readable and not reward_capped),
  tostring(processor_readable and not processor_capped), #rows)
