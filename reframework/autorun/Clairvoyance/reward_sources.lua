local M = {}

local U32 = 4294967295
local MAX = 2147483647
local SAFE = 9007199254740991
local REWARD = "app.quest.action.QuestReward"
local TRIGGER = "app.quest.action.Trigger"
local function integer(v, lo, hi)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    and v % 1 == 0 and v >= lo and v <= hi
end
local function canonical_integer(v, lo, hi)
  if not integer(v, lo, hi) then return nil end
  return math.tointeger(v)
end
local function dense(a, cap)
  if type(a) ~= "table" then return false end
  local n, max = 0, 0
  for k in pairs(a) do
    if not integer(k, 1, cap) then return false end
    n = n + 1; if k > max then max = k end
  end
  return n == max
end
local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
local function copy_pos(p)
  if type(p) ~= "table" or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil end
  return { x = p.x, y = p.y, z = p.z }
end
local function target_key(tuple)
  local out = { "t", tostring(#tuple), ":" }
  for _, v in ipairs(tuple) do
    if integer(v, -SAFE, SAFE) then out[#out + 1] = "i" .. string.format("%.0f", v) .. ";"
    elseif type(v) == "string" then out[#out + 1] = "s" .. tostring(#v) .. ":" .. v
    else return nil end
  end
  return table.concat(out)
end
local function snake(s)
  return type(s) == "string" and #s > 0 and #s <= 64 and s:match("^[a-z][a-z0-9_]*$") ~= nil
end
local function provider_fallback(snapshot, reason)
  snapshot.source_status = { generation = snapshot.generation, complete = false,
    reason_code = reason, rows = { { scope = "provider", generation = snapshot.generation,
      identity = "provider:reward", provider = "reward", qid = nil, task_index = nil,
      item_ids = {}, state = "unknown", reason_code = reason } } }
end
local function status_row(snapshot, scope, identity, qid, task, items, state, reason)
  return { scope = scope, generation = snapshot.generation, identity = identity,
    provider = "reward", qid = qid, task_index = task, item_ids = items,
    state = state, reason_code = reason }
end
local function status_degrade(snapshot, rows)
  local reason
  if type(rows) ~= "table" or not dense(rows, 4096) then reason = "status_malformed" end
  if not reason then
    for _, r in ipairs(rows) do
      if type(r) ~= "table" or (r.scope ~= "provider" and r.scope ~= "source")
          or not integer(r.generation, 1, MAX) or type(r.identity) ~= "string"
          or type(r.provider) ~= "string" or not integer(r.qid, 1, MAX) and r.qid ~= nil
          or not integer(r.task_index, 0, MAX) and r.task_index ~= nil
          or type(r.item_ids) ~= "table" or not dense(r.item_ids, 257)
          or (r.state ~= "available" and r.state ~= "unavailable" and r.state ~= "unknown")
          or type(r.reason_code) ~= "string" then reason = "status_malformed"; break end
      for i, id in ipairs(r.item_ids) do
        if not integer(id, 1, MAX) or i > 1 and id <= r.item_ids[i-1] then reason = "status_malformed"; break end
      end
      if reason then break end
    end
  end
  if not reason then
    local seen = {}
    for _, r in ipairs(rows) do
      if r.generation ~= snapshot.generation then reason = "status_generation_mismatch"; break end
      local pair = r.scope .. "\0" .. r.identity
      if seen[pair] then reason = "status_duplicate_identity"; break end
      seen[pair] = true
    end
  end
  if not reason and #rows > 512 then reason = "status_row_overflow" end
  if not reason then for _, r in ipairs(rows) do if #r.identity > 1024 then reason="status_identity_overflow";break end end end
  if not reason then for _, r in ipairs(rows) do if #r.reason_code > 64 or not snake(r.reason_code) then reason="status_reason_invalid";break end end end
  if not reason then for _, r in ipairs(rows) do if #r.item_ids > 256 then reason="status_items_overflow";break end end end
  if reason then provider_fallback(snapshot, reason); return end
  table.sort(rows, function(a, b) return a.identity < b.identity end)
  snapshot.source_status = { generation = snapshot.generation, complete = true,
    reason_code = nil, rows = rows }
end

local function identity_part(v)
  if type(v) == "string" and #v > 0 then return "s" .. #v .. ":" .. v end
  if integer(v, 0, MAX) then return "n" .. string.format("%.0f", v) end
end
local function node_index(event)
  if not dense(event.nodes, 512) or #event.nodes == 0 then return nil end
  local ids, hashes = {}, {}
  for i, n in ipairs(event.nodes) do
    if type(n) ~= "table" or n.node_index ~= i - 1 or type(n.node_type) ~= "string" then return nil end
    local ik = n.node_id ~= nil and identity_part(n.node_id) or nil
    local hk = n.node_hash ~= nil and integer(n.node_hash, 0, U32) and ("h" .. n.node_hash) or nil
    if n.node_id~=nil and not ik or n.node_hash~=nil and not hk then return nil end
    if not ik and not hk then return nil end
    if ik and ids[ik] then return nil end
    if hk and hashes[hk] then return nil end
    if ik then ids[ik] = i end
    if hk then hashes[hk] = i end
    if n.node_type == "End" then
      if not integer(n.end_result, -MAX, MAX) or type(n.keep_previous_result) ~= "boolean" then return nil end
    elseif n.end_result ~= nil or n.keep_previous_result ~= nil then return nil end
    if not dense(n.ordinary_edges, 128) or not dense(n.choices, 64) then return nil end
    for j, edge in ipairs(n.ordinary_edges) do
      if type(edge) ~= "table" or edge.edge_index ~= j - 1 or not integer(edge.condition_count, 0, 128) then return nil end
    end
    for j, edge in ipairs(n.choices) do
      if type(edge) ~= "table" or edge.choice_index ~= j - 1 or not integer(edge.condition_count, 0, 128) then return nil end
    end
  end
  for _, n in ipairs(event.nodes) do
    if n.node_id ~= nil and n.node_hash ~= nil then
      local a, b = ids[identity_part(n.node_id)], hashes["h" .. tostring(n.node_hash)]
      if not a or a ~= b then return nil end
    end
  end
  local function resolve(id, hash)
    if id == nil and hash == nil then return nil end
    local id_key=id ~= nil and identity_part(id) or nil
    local hash_key=hash ~= nil and integer(hash,0,U32) and ("h"..tostring(hash)) or nil
    if id~=nil and not id_key or hash~=nil and not hash_key then return nil end
    local a = id_key and ids[id_key] or nil
    local b = hash_key and hashes[hash_key] or nil
    if id ~= nil and not a or hash ~= nil and not b or a and b and a ~= b then return nil end
    return a or b
  end
  for _, node in ipairs(event.nodes) do
    for _, edge in ipairs(node.ordinary_edges) do
      if not resolve(edge.to_node_id,edge.to_node_hash) then return nil end
    end
    for _, edge in ipairs(node.choices) do
      if not resolve(edge.to_node_id,edge.to_node_hash) then return nil end
    end
  end
  local root = resolve(event.root_node_id, event.root_node_hash)
  if not root then return nil end
  return event.nodes, resolve, root
end
local function graph_closed(event, end_no)
  local nodes, resolve, root = node_index(event)
  if not nodes then return false end
  local color, stack = {}, { { index = root, edge = 1, edges = nil } }
  color[root] = 1
  local function edges_for(node)
    local e = {}
    for _, x in ipairs(node.ordinary_edges) do e[#e + 1] = x end
    for _, x in ipairs(node.choices) do e[#e + 1] = x end
    return e
  end
  stack[1].edges = edges_for(nodes[root])
  while #stack > 0 do
    local top = stack[#stack]
    if top.edge > #top.edges then
      color[top.index] = 2
      local node = nodes[top.index]
      if node.node_type ~= "End" and #top.edges == 0 then return false end
      if node.node_type == "End" and (node.keep_previous_result ~= false or node.end_result ~= end_no
          or #top.edges > 0) then return false end
      stack[#stack] = nil
    else
      local edge = top.edges[top.edge]; top.edge = top.edge + 1
      if edge.condition_count ~= 0 then return false end
      local to = resolve(edge.to_node_id, edge.to_node_hash)
      if not to then return false end
      if color[to] == 1 then return false end
      if color[to] ~= 2 then
        color[to] = 1; stack[#stack + 1] = { index = to, edge = 1, edges = edges_for(nodes[to]) }
      end
    end
  end
  return true
end

local function sorted_by(a, field, lo, hi)
  local last
  for _, r in ipairs(a) do
    if type(r) ~= "table" or not integer(r[field], lo, hi) or last ~= nil and r[field] <= last then return false end
    last = r[field]
  end
  return true
end
local function output_map(obs)
  if not dense(obs.reward_outputs, 512) or not sorted_by(obs.reward_outputs, "name_hash", 0, U32) then return nil end
  local by_hash, seen = {}, {}
  for _, row in ipairs(obs.reward_outputs) do
    if type(row) ~= "table" or not integer(row.name_hash, 0, U32) or seen[row.name_hash]
        or not dense(row.outputs, 32) or #row.outputs == 0 then return nil end
    seen[row.name_hash] = true
    local item_seen, out = {}, {}
    local last_item=0
    for _, v in ipairs(row.outputs) do
      if type(v) ~= "table" or not integer(v.item_id, 1, MAX) or not integer(v.count, 1, MAX)
          or item_seen[v.item_id] or v.item_id<=last_item then return nil end
      item_seen[v.item_id] = true; out[#out + 1] = { item_id=v.item_id, count=v.count }
      last_item=v.item_id
    end
    by_hash[row.name_hash] = out
  end
  return by_hash
end
local function sorted_unique_positive(a, cap)
  if not dense(a, cap) then return false end
  local last = 0
  for _, v in ipairs(a) do if not integer(v, 1, MAX) or v <= last then return false end; last=v end
  return true
end
local function find_one(rows, field, value)
  local found
  for _, r in ipairs(rows) do
    if r[field] == value then if found then return nil, "duplicate" end; found=r end
  end
  return found
end
local function member_intersects_wanted(row, mappings, wanted)
  if type(row) ~= "table" or not dense(row.reward_rows, 32) or #row.reward_rows == 0 then return nil end
  for _, reward in ipairs(row.reward_rows) do
    if type(reward) ~= "table" or not integer(reward.name_hash, 0, U32) then return nil end
    local outputs = mappings[reward.name_hash]
    if outputs == nil then return nil end
    for _, output in ipairs(outputs) do
      if wanted[output.item_id] then return true end
    end
  end
  return false
end

local function normalize_catalog_member(row)
  if type(row) ~= "table" then return nil, "reward_catalog_invalid" end
  local identity = row.source_identity
  local qid = row.quest_id
  if type(identity)~="table" or row.family~="quest_reward"
      or row.action_type~="app.quest.action.QuestReward" then return nil,"reward_catalog_invalid" end
  local ordinal, processor = identity.action_ordinal, identity.processor_id
  if identity.quest_id~=qid then return nil,"reward_catalog_invalid" end
  local hashes={}
  if not dense(row.reward_rows,32) then return nil,"reward_catalog_invalid" end
  for i,v in ipairs(row.reward_rows) do
    if type(v)~="table" or v.ordinal~=i-1 then return nil,"reward_catalog_invalid" end
    hashes[i]=v.name_hash
  end
  local e=row.endpoint_evidence
  local supported=type(e)=="table"
  if supported then
    if e.kind~="single_talk_trigger" or e.reward_root_count~=1 or e.reward_operator~="or"
        or e.reward_operator_value~=1 or e.reward_relation_count~=1 or e.reward_child_count~=0
        or e.relation_result_no~=0 or e.predecessor_action_type~=TRIGGER
        or e.trigger_parameter_count~=1 or e.condition_operator~="and"
        or e.condition_operator_value~=0 or e.condition_count~=1
        or e.condition_type~="app.quest.condition.CheckTalkEventEndNoParam"
        or not integer(e.predecessor_processor_id,0,U32)
        or not integer(e.talk_event_id,1,MAX) or not integer(e.end_no,-MAX,MAX)
        or type(e.accept_minus_one)~="boolean" then return nil,"reward_endpoint_evidence_invalid" end
  end
  if not integer(qid,1,MAX) or not integer(ordinal,0,MAX) or not integer(processor,0,U32)
      or not dense(hashes,32) or #hashes==0 then return nil,"reward_catalog_invalid" end
  local out={ qid=canonical_integer(qid,1,MAX), action_ordinal=canonical_integer(ordinal,0,MAX),
    processor_id=canonical_integer(processor,0,U32),
    predecessor_processor_id=supported and canonical_integer(e.predecessor_processor_id,0,U32) or nil,
    reward_action_type=REWARD, predecessor_action_type=supported and e.predecessor_action_type or nil,
    talk_event_id=supported and canonical_integer(e.talk_event_id,1,MAX) or nil,
    end_no=supported and canonical_integer(e.end_no,-MAX,MAX) or nil,
    endpoint_supported=supported, reward_hashes=hashes }
  if supported then out.accept_minus_one=e.accept_minus_one end
  return out
end

local function classify_member(member, obs, mappings, wanted)
  local qid, ord, rp, pp = member.qid, member.action_ordinal, member.processor_id, member.predecessor_processor_id
  if not integer(qid, 1, MAX) or not integer(ord, 0, MAX) or not integer(rp, 0, U32)
      or not dense(member.reward_hashes, 32) or #member.reward_hashes == 0 then return nil, "reward_catalog_invalid" end
  if member.endpoint_supported and (not integer(pp,0,U32) or rp==pp
      or not integer(member.talk_event_id,1,MAX) or not integer(member.end_no,-MAX,MAX)) then return nil,"reward_catalog_invalid" end
  if not sorted_unique_positive(obs.wanted, 256) then return nil, "need_set_invalid" end
  if not obs.complete then return nil, "reward_observation_incomplete" end
  if not sorted_unique_positive(obs.progressing_qids, 64) then return nil, "progressing_set_invalid" end
  if not dense(obs.tasks, 64) or not sorted_by(obs.tasks,"qid",1,MAX)
      or not dense(obs.controllers, 64) or not sorted_by(obs.controllers,"qid",1,MAX)
      or not dense(obs.events, 64) or not sorted_by(obs.events,"event_id",1,MAX) then return nil, "reward_observation_incomplete" end
  local output_by_hash = mappings
  if not output_by_hash then return nil, "reward_mapping_invalid" end
  local all_outputs, matched = {}, {}
  local used_hash = {}
  for _, hash in ipairs(member.reward_hashes) do
    if not integer(hash, 0, U32) or used_hash[hash] then return nil, "reward_catalog_invalid" end
    used_hash[hash] = true
    local outputs = output_by_hash[hash]; if not outputs then return nil, "reward_mapping_missing" end
    for _, o in ipairs(outputs) do
      all_outputs[o.item_id] = (all_outputs[o.item_id] or 0) + o.count
      if all_outputs[o.item_id] > MAX then return nil, "reward_count_overflow" end
    end
  end
  local complete_outputs = {}
  for item, count in pairs(all_outputs) do
    complete_outputs[#complete_outputs+1] = { item_id=item, count=count }
    if wanted[item] then matched[#matched+1] = { item_id=item, count=count } end
  end
  table.sort(complete_outputs,function(a,b)return a.item_id<b.item_id end)
  table.sort(matched,function(a,b)return a.item_id<b.item_id end)
  local progress=false; for _, x in ipairs(obs.progressing_qids) do if x==qid then progress=true end end
  if not progress then return { state="unavailable", reason="quest_not_progressing", outputs=complete_outputs, matched=matched } end
  local task, task_dup = find_one(obs.tasks,"qid",qid)
  if task_dup or task and (not integer(task.task_index,0,MAX) or not dense(task.targets,128)) then return nil,"task_endpoint_unreadable" end
  if task then
    local previous_cid=0
    for _, target in ipairs(task.targets) do
      if type(target)~="table" or target.kind~="npc" or target.task_index~=task.task_index
          or not integer(target.cid,1,U32) or target.cid<previous_cid
          or target.eligibility~="eligible" then return nil,"task_endpoint_unreadable" end
      previous_cid=target.cid
    end
    task={qid=task.qid,task_index=canonical_integer(task.task_index,0,MAX),targets=task.targets}
  end
  if not task then return nil,"task_endpoint_unreadable" end
  if not member.endpoint_supported then return {state="unknown",reason="unsupported_reward_graph",outputs=complete_outputs,matched=matched,task=task,unnameable=true} end
  if member.accept_minus_one==true then
    return {state="unknown",reason="unsupported_reward_graph",outputs=complete_outputs,matched=matched,task=task}
  end
  local controller, ctrl_dup=find_one(obs.controllers,"qid",qid)
  if ctrl_dup or not controller or type(controller.owner_token)~="string" or controller.owner_token=="" or not dense(controller.processors,512)
      or not sorted_by(controller.processors,"processor_id",0,U32) then return nil,"reward_runtime_scan_incomplete" end
  local reward, predecessor, nr, np
  for _, p in ipairs(controller.processors) do
    if type(p)~="table" or not integer(p.processor_id,0,U32) or type(p.quest_action_type)~="string" then return nil,"reward_runtime_scan_incomplete" end
    if p.processor_id==rp then reward=reward or p; nr=(nr or 0)+1 end
    if p.processor_id==pp then predecessor=predecessor or p; np=(np or 0)+1 end
  end
  if nr~=1 or np~=1 then return nil,"reward_runtime_scan_incomplete" end
  if reward.quest_action_type~=REWARD or predecessor.quest_action_type~=TRIGGER then return nil,"reward_runtime_scan_incomplete" end
  if reward.processor_phase=="Completed" then return {state="unavailable",reason="processor_completed",outputs=complete_outputs,matched=matched,task=task} end
  if reward.processor_phase=="Canceled" then return {state="unavailable",reason="processor_canceled",outputs=complete_outputs,matched=matched,task=task} end
  if reward.processor_phase~="Standby" then return {state="unknown",reason="processor_state_unreadable",outputs=complete_outputs,matched=matched,task=task} end
  if reward.process_type~="ExecuteAction" or reward.process_phase~="ExecuteAction"
      or reward.process_completed~=false or reward.process_canceled~=false
      or reward.nested_action_type~="ExecuteAction" or reward.nested_action_phase~="ExecuteAction"
      or reward.nested_action_completed~=false or reward.nested_action_canceled~=false
      or reward.nested_action_result~=0 then
    return {state="unknown",reason="processor_state_unreadable",outputs=complete_outputs,matched=matched,task=task}
  end
  if predecessor.processor_phase~="Waiting" or predecessor.process_type~="ExecuteAction"
      or predecessor.process_phase~="ExecuteAction" or predecessor.process_completed~=false
      or predecessor.process_canceled~=false or predecessor.nested_action_type~="CheckTrigger"
      or predecessor.nested_action_phase~="CheckTrigger" or predecessor.nested_action_completed~=false
      or predecessor.nested_action_canceled~=false or predecessor.nested_action_result~=0 then
    return {state="unknown",reason="processor_state_unreadable",outputs=complete_outputs,matched=matched,task=task}
  end
  local event, event_dup=find_one(obs.events,"event_id",member.talk_event_id)
  local function unknown_event(reason)
    return {state="unknown",reason=reason,outputs=complete_outputs,matched=matched,task=task,event=event}
  end
  if event_dup or not event or type(event.owner_token)~="string" or event.owner_token=="" then return unknown_event("event_unreadable") end
  if not graph_closed(event,member.end_no) then return {state="unknown",reason="unsupported_reward_graph",outputs=complete_outputs,matched=matched,task=task,event=event} end
  if type(event.playable_readable)~="boolean" then return unknown_event("event_playability_unreadable") end
  if not event.playable_readable and event.playable~=nil then return unknown_event("observation_contradictory") end
  if event.playable_readable and type(event.playable)~="boolean" then return unknown_event("event_playability_unreadable") end
  if not event.playable_readable then return unknown_event("event_playability_unreadable") end
  if not event.playable then return {state="unavailable",reason="event_not_playable",outputs=complete_outputs,matched=matched,task=task,event=event} end
  if type(event.initial_speaker_readable)~="boolean" then return unknown_event("initial_speaker_unreadable") end
  if not event.initial_speaker_readable and event.initial_speaker_cid~=nil then return unknown_event("observation_contradictory") end
  if event.initial_speaker_readable and event.initial_speaker_cid~=nil
      and not integer(event.initial_speaker_cid,1,U32) then return unknown_event("initial_speaker_unreadable") end
  if not event.initial_speaker_readable then
    if event.initial_speaker_cid~=nil or event.speaker_present~=nil or event.speaker~=nil then return unknown_event("observation_contradictory") end
    return unknown_event("initial_speaker_unreadable")
  end
  if event.initial_speaker_cid==nil then return unknown_event("initial_speaker_unreadable") end
  if type(event.speaker_present_readable)~="boolean" then return unknown_event("speaker_presence_unreadable") end
  if not event.speaker_present_readable and (event.speaker_present~=nil or event.speaker~=nil) then return unknown_event("observation_contradictory") end
  if event.speaker_present_readable and type(event.speaker_present)~="boolean" then return unknown_event("speaker_presence_unreadable") end
  if event.speaker_present==false then
    if event.speaker~=nil then return unknown_event("observation_contradictory") end
    return unknown_event("speaker_unreadable")
  end
  local speaker=event.speaker
  if type(speaker)~="table" or speaker.cid~=event.initial_speaker_cid then return unknown_event("speaker_unreadable") end
  local matches=0
  for _, target in ipairs(task.targets) do
    if type(target)=="table" and target.kind=="npc" and target.task_index==task.task_index
        and target.eligibility=="eligible" and target.cid==speaker.cid then matches=matches+1 end
  end
  if matches==0 then return {state="unavailable",reason="wrong_current_task",outputs=complete_outputs,matched=matched,task=task,event=event} end
  if matches~=1 then return nil,"task_endpoint_ambiguous" end
  if type(speaker.position_readable)~="boolean" then return unknown_event("speaker_position_unreadable") end
  if not speaker.position_readable and speaker.pos~=nil then return unknown_event("observation_contradictory") end
  if speaker.position_readable and not copy_pos(speaker.pos) then return unknown_event("speaker_position_unreadable") end
  if not speaker.position_readable then return unknown_event("speaker_position_unreadable") end
  if type(speaker.interaction_disabled_readable)~="boolean" or type(speaker.interaction_allowed_readable)~="boolean" then return unknown_event("interaction_unreadable") end
  if not speaker.interaction_disabled_readable and speaker.interaction_disabled~=nil
      or not speaker.interaction_allowed_readable and speaker.interaction_allowed~=nil then return unknown_event("observation_contradictory") end
  if not speaker.interaction_disabled_readable or not speaker.interaction_allowed_readable then return unknown_event("interaction_unreadable") end
  if speaker.interaction_disabled_readable and type(speaker.interaction_disabled)~="boolean"
      or speaker.interaction_allowed_readable and type(speaker.interaction_allowed)~="boolean" then return unknown_event("interaction_unreadable") end
  if speaker.interaction_disabled or not speaker.interaction_allowed then return {state="unavailable",reason="interaction_unavailable",outputs=complete_outputs,matched=matched,task=task,event=event} end
  local h=event.history
  if type(h)~="table" or type(h.lookup_ok)~="boolean" then return unknown_event("history_unreadable") end
  if not h.lookup_ok then
    if h.present~=false or h.played_readable~=false or h.played~=nil or h.result_readable~=false or h.result_no~=nil then
      return unknown_event("observation_contradictory")
    end
    return unknown_event("history_unreadable")
  end
  if type(h.present)~="boolean" then return unknown_event("history_unreadable") end
  if type(h.result_readable)~="boolean" or not h.result_readable and h.result_no~=nil
      or h.result_readable and h.result_no~=nil and not integer(h.result_no,-MAX,MAX) then return unknown_event("observation_contradictory") end
  if h.present then
    if h.played_readable~=true or type(h.played)~="boolean" then return unknown_event("history_unreadable") end
    if h.played then return {state="unavailable",reason="already_claimed",outputs=complete_outputs,matched=matched,task=task,event=event} end
  elseif h.played_readable~=false or h.played~=nil or h.result_readable~=false or h.result_no~=nil then return unknown_event("observation_contradictory") end
  return {state="available",reason="available",outputs=complete_outputs,matched=matched,task=task,event=event, speaker=speaker}
end

function M.classify(catalog_rows, observation, generation)
  local snapshot={provider="reward",status="unknown",complete=false,reason="reward_observation_incomplete",
    generation=integer(generation,1,MAX) and generation or 1,candidates={},diagnostic_rows={}}
  if not integer(generation,1,MAX) then snapshot.reason="reward_generation_invalid";provider_fallback(snapshot,"status_malformed");return snapshot end
  if not dense(catalog_rows,4096) then
    snapshot.reason="reward_catalog_invalid"; provider_fallback(snapshot,"status_malformed"); return snapshot
  end
  local obs=observation
  if type(obs)~="table" or type(obs.complete)~="boolean" or type(obs.owner_token)~="string" or obs.owner_token=="" then provider_fallback(snapshot,"status_malformed"); return snapshot end
  if not dense(obs.wanted,256) then snapshot.reason="reward_observation_invalid";provider_fallback(snapshot,"status_malformed");return snapshot end
  if not obs.complete then snapshot.reason="reward_observation_incomplete"; provider_fallback(snapshot,snapshot.reason); return snapshot end
  if #obs.wanted == 0 then
    snapshot.status="ok"; snapshot.complete=true; snapshot.reason=nil
    status_degrade(snapshot,{})
    return snapshot
  end
  if not dense(obs.events,64) or not sorted_by(obs.events,"event_id",1,MAX) then
    snapshot.reason="reward_observation_incomplete"; provider_fallback(snapshot,snapshot.reason); return snapshot
  end
  for _, event in ipairs(obs.events) do
    if type(event)~="table" or not node_index(event) then
      snapshot.reason="reward_observation_incomplete"; provider_fallback(snapshot,snapshot.reason); return snapshot
    end
  end
  local mapping=output_map(obs)
  if obs.complete and not mapping then provider_fallback(snapshot,"status_malformed"); return snapshot end
  local wanted={}; for _, id in ipairs(obs.wanted) do if not integer(id,1,MAX) or wanted[id] then provider_fallback(snapshot,"status_malformed"); return snapshot end; wanted[id]=true end
  if not sorted_unique_positive(obs.progressing_qids,64) then
    snapshot.reason="progressing_set_invalid";provider_fallback(snapshot,snapshot.reason);return snapshot
  end
  local progressing={}; for _,qid in ipairs(obs.progressing_qids) do progressing[qid]=true end
  local member_seen, outcomes, statuses, endpoint_groups, unsupported_rows = {}, {}, {}, {}, {}
  local row_refs = {}
  for _, member in ipairs(catalog_rows) do
    if type(member)~="table" then provider_fallback(snapshot,"status_malformed"); return snapshot end
    local intersects=member_intersects_wanted(member,mapping,wanted)
    if intersects==nil then snapshot.reason="reward_catalog_invalid";provider_fallback(snapshot,"status_malformed");return snapshot end
    local identity, evidence = member.source_identity, member.endpoint_evidence
    local identity_key
    if type(identity)=="table" and integer(member.quest_id,1,MAX)
        and identity.quest_id==member.quest_id and integer(identity.action_ordinal,0,MAX)
        and integer(identity.processor_id,0,U32) then
      identity_key=table.concat({member.quest_id,identity.action_ordinal,identity.processor_id},":")
    end
    local ref={member=member,identity_key=identity_key}
    row_refs[#row_refs+1]=ref
    local group_key
    if integer(member.quest_id,1,MAX)
        and type(evidence)=="table" and integer(evidence.talk_event_id,1,MAX)
        and integer(evidence.end_no,-MAX,MAX) then
      group_key=target_key({"reward_endpoint",member.quest_id,evidence.talk_event_id,evidence.end_no})
      endpoint_groups[group_key]=endpoint_groups[group_key] or {members={},relevant=false}
      endpoint_groups[group_key].members[#endpoint_groups[group_key].members+1]=ref
      endpoint_groups[group_key].relevant=endpoint_groups[group_key].relevant or intersects
    elseif intersects then
      unsupported_rows[#unsupported_rows+1]=ref
    end
  end
  local relevant_rows, relevant_identities, included={},{},{}
  local function include(ref)
    if not included[ref] then
      included[ref]=true
      relevant_rows[#relevant_rows+1]=ref.member
    end
  end
  for _, group in pairs(endpoint_groups) do
    if group.relevant then
      for _, ref in ipairs(group.members) do
        include(ref)
        if ref.identity_key then relevant_identities[ref.identity_key]=true end
      end
    end
  end
  for _, ref in ipairs(unsupported_rows) do
    include(ref)
    if ref.identity_key then relevant_identities[ref.identity_key]=true end
  end
  for _, ref in ipairs(row_refs) do
    if ref.identity_key and relevant_identities[ref.identity_key] then include(ref) end
  end
  for _, raw_member in ipairs(relevant_rows) do
      local normalized, normalize_error=normalize_catalog_member(raw_member)
      if not normalized then snapshot.reason=normalize_error; provider_fallback(snapshot,"status_malformed"); return snapshot end
      local mk=table.concat({tostring(normalized.qid),tostring(normalized.action_ordinal),
        tostring(normalized.processor_id)},":")
      if member_seen[mk] then snapshot.reason="reward_catalog_duplicate_identity"; provider_fallback(snapshot,"status_duplicate_identity"); return snapshot end
      member_seen[mk]=true
      if normalized.endpoint_supported and progressing[normalized.qid] then
        local event, event_dup=find_one(obs.events,"event_id",normalized.talk_event_id)
        if event_dup or not event then
          snapshot.reason="event_unreadable"; provider_fallback(snapshot,snapshot.reason); return snapshot
        end
      end
      local outcome, reason=classify_member(normalized,obs,mapping,wanted)
      if not outcome then snapshot.reason=reason; provider_fallback(snapshot,"status_malformed"); return snapshot end
      outcome.member=normalized
      local task_index=outcome.task and outcome.task.task_index or "unknown"
      outcome.key=target_key({"reward_member",normalized.qid,task_index,normalized.action_ordinal,
        normalized.processor_id,normalized.predecessor_processor_id or "unknown",
        normalized.talk_event_id or "unknown",normalized.end_no or "unknown"}) or mk
      outcomes[#outcomes+1]=outcome
  end
  if not obs.complete then snapshot.reason="reward_observation_incomplete"; provider_fallback(snapshot,snapshot.reason); return snapshot end
  snapshot.status="ok"; snapshot.complete=true; snapshot.reason=nil
  local groups, candidates={},{}
  for _, outcome in ipairs(outcomes) do
    local m=outcome.member
    if m.endpoint_supported and m.talk_event_id~=nil and m.end_no~=nil then
      local gk=target_key({"reward_endpoint",m.qid,m.talk_event_id,m.end_no})
      local g=groups[gk] or {members={},outputs={},task=outcome.task,event=outcome.event,speaker=outcome.speaker}
      groups[gk]=g; g.members[#g.members+1]=outcome
      if g.task==nil then g.task=outcome.task end
      if g.event==nil then g.event=outcome.event end
      if g.speaker==nil then g.speaker=outcome.speaker end
    end
  end
  local group_list={}; for _,g in pairs(groups) do group_list[#group_list+1]=g end
  table.sort(group_list,function(a,b)
    local x,y=a.members[1].member,b.members[1].member
    if x.qid~=y.qid then return x.qid<y.qid end
    if x.talk_event_id~=y.talk_event_id then return x.talk_event_id<y.talk_event_id end
    return x.end_no<y.end_no
  end)
  local eligible_pools={}
  for _,g in ipairs(group_list) do
    local first=g.members[1].member
    for _,o in ipairs(g.members) do if o.state=="available" and #(o.matched or {})>0 then
      eligible_pools[target_key({"capacity","quest_reward_endpoint",first.qid,first.talk_event_id})]=true
      break
    end end
  end
  local capacity_claims={}
  for _,g in ipairs(group_list) do
    table.sort(g.members,function(a,b)
      local x,y=a.member,b.member
      if x.action_ordinal~=y.action_ordinal then return x.action_ordinal<y.action_ordinal end
      if x.processor_id~=y.processor_id then return x.processor_id<y.processor_id end
      return x.predecessor_processor_id<y.predecessor_processor_id
    end)
    if #g.members>8 then snapshot.status="unknown";snapshot.complete=false
      snapshot.reason="reward_member_overflow";snapshot.candidates={};provider_fallback(snapshot,snapshot.reason);return snapshot end
    local active_members, excluded_members, matching_members, active_matching={}, {}, {}, {}
    for _,o in ipairs(g.members) do
      if o.state=="available" then active_members[#active_members+1]=o else excluded_members[#excluded_members+1]=o end
      if #(o.matched or {})>0 then matching_members[#matching_members+1]=o end
      if o.state=="available" and #(o.matched or {})>0 then active_matching[#active_matching+1]=o end
    end
    local members=#active_matching>0 and active_members or g.members
    local gstate,greason="available","available"
    if #active_matching==0 then
      gstate="unavailable"
      for _,o in ipairs(matching_members) do
        if o.state=="unknown" then gstate="unknown";greason=o.reason;break end
        greason=o.reason
      end
    end
    local first=members[1].member
    local tuple=g.task and {"source","quest_reward_endpoint",first.qid,g.task.task_index,first.talk_event_id,first.end_no,#members} or nil
    local status_tuple={"reward_status_endpoint",first.qid,first.talk_event_id,first.end_no,#members}
    for _,o in ipairs(members) do
      local m=o.member
      if tuple then tuple[#tuple+1]=m.action_ordinal;tuple[#tuple+1]=m.processor_id;tuple[#tuple+1]=m.predecessor_processor_id end
      status_tuple[#status_tuple+1]=m.action_ordinal;status_tuple[#status_tuple+1]=m.processor_id
      status_tuple[#status_tuple+1]=m.predecessor_processor_id
      for _,out in ipairs(o.outputs or {}) do
        g.outputs[out.item_id]=(g.outputs[out.item_id] or 0)+out.count
        if g.outputs[out.item_id]>MAX then snapshot.status="unknown";snapshot.complete=false
          snapshot.reason="reward_count_overflow";snapshot.candidates={};provider_fallback(snapshot,snapshot.reason);return snapshot end
      end
    end
    local pool={"capacity","quest_reward_endpoint",first.qid,first.talk_event_id}
    local pk=target_key(pool)
    if gstate=="available" then capacity_claims[pk]=(capacity_claims[pk] or 0)+1 end
    local source_key=tuple and target_key(tuple) or nil
    if source_key then
      local ids={};for item in pairs(g.outputs) do ids[#ids+1]=item end;table.sort(ids)
      local outputs={};for _,item in ipairs(ids) do outputs[#outputs+1]={item_id=item,count=g.outputs[item]} end
      local eligibility=gstate=="available" and "eligible" or gstate=="unavailable" and "ineligible" or "unknown"
      local ids_status={};for _,out in ipairs(outputs) do if wanted[out.item_id] then ids_status[#ids_status+1]=out.item_id end end
      statuses[#statuses+1]=status_row(snapshot,"source",source_key,first.qid,g.task and g.task.task_index or nil,
        ids_status,gstate,greason)
      if gstate=="available" or not eligible_pools[pk] then
        local candidate={provider="reward",generation=snapshot.generation,eligibility=eligibility,reason=greason,
          source_id=tuple,capacity_pool_id=pool,outputs=outputs,target={cid=g.speaker and g.speaker.cid or nil},
          pos=g.speaker and copy_pos(g.speaker.pos) or nil,capacity_kind="finite",available_acquisitions=1,certainty="guaranteed"}
        candidates[#candidates+1]=candidate
      end
    elseif greason=="quest_not_progressing" then
      local item_set={}; for _,o in ipairs(matching_members) do
        for _,out in ipairs(o.matched or {}) do item_set[out.item_id]=true end
      end
      local item_ids={}; for item in pairs(item_set) do item_ids[#item_ids+1]=item end; table.sort(item_ids)
      local status_identity=target_key(status_tuple)
      statuses[#statuses+1]=status_row(snapshot,"source",status_identity,first.qid,nil,item_ids,gstate,greason)
    end
    if #active_matching>0 then
      for _,o in ipairs(excluded_members) do
        local m=o.member
        local excluded_tuple={"source","quest_reward_endpoint",m.qid,g.task.task_index,m.talk_event_id,m.end_no,1,
          m.action_ordinal,m.processor_id,m.predecessor_processor_id}
        local excluded_key=target_key(excluded_tuple)
        if excluded_key then
          local ids={};for _,out in ipairs(o.matched or {}) do ids[#ids+1]=out.item_id end
          statuses[#statuses+1]=status_row(snapshot,"source",excluded_key,m.qid,g.task.task_index,ids,o.state,o.reason)
        end
      end
    end
  end
  for _,count in pairs(capacity_claims) do if count>1 then snapshot.status="unknown";snapshot.complete=false;snapshot.reason="reward_capacity_conflict";snapshot.candidates={};snapshot.diagnostic_rows={};provider_fallback(snapshot,snapshot.reason);return snapshot end end
  snapshot.candidates=candidates
  for _,o in ipairs(outcomes) do
    if o.state~="available" then
      local diagnostic_status=o.state=="unavailable" and "ineligible" or "unknown"
      snapshot.diagnostic_rows[#snapshot.diagnostic_rows+1]={member_id=o.key,gate=o.reason,status=diagnostic_status}
    end
  end
  table.sort(statuses,function(a,b)return a.identity<b.identity end)
  status_degrade(snapshot,statuses)
  return snapshot
end

return M
