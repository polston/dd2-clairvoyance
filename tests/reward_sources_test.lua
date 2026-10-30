package.path = "./reframework/autorun/?.lua;" .. package.path
local sources = require("Clairvoyance.reward_sources")
local function clone(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = clone(x) end
  return out
end
local function eq(a, b, label)
  assert(a == b, (label or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end
local function row(overrides)
  local f = { qid=10, action_ordinal=2, processor_id=100, predecessor_processor_id=90,
    talk_event_id=20, end_no=7, accept_minus_one=false, reward_hashes={30}, endpoint=true }
  for k, v in pairs(overrides or {}) do f[k] = v end
  local e
  if f.endpoint then e={kind="single_talk_trigger",reward_root_count=1,reward_operator="or",
    reward_operator_value=1,reward_relation_count=1,reward_child_count=0,relation_result_no=0,
    predecessor_processor_id=f.predecessor_processor_id,predecessor_action_type="app.quest.action.Trigger",
    trigger_parameter_count=1,condition_operator="and",condition_operator_value=0,condition_count=1,
    condition_type="app.quest.condition.CheckTalkEventEndNoParam",talk_event_id=f.talk_event_id,
    end_no=f.end_no,accept_minus_one=f.accept_minus_one} end
  local hashes={}; for i,h in ipairs(f.reward_hashes) do hashes[i]={ordinal=i-1,name_hash=h} end
  return {family="quest_reward",quest_id=f.qid,action_type="app.quest.action.QuestReward",
    source_identity={quest_id=f.qid,action_ordinal=f.action_ordinal,processor_id=f.processor_id},
    reward_rows=hashes,endpoint_evidence=e}
end
local function observation(overrides)
  local o = { complete = true, owner_token = "a1", wanted = { 500 },
    progressing_qids = { 10 },
    reward_outputs = { { name_hash = 30, outputs = { { item_id = 500, count = 1 } } } },
    tasks = { { qid = 10, task_index = 3, targets = {
      { kind = "npc", task_index = 3, cid = 40, eligibility = "eligible" } } } },
    controllers = { { qid = 10, owner_token = "b2", processors = {
      { processor_id = 100, quest_action_type = "app.quest.action.QuestReward", processor_phase = "Standby" },
      { processor_id = 90, quest_action_type = "app.quest.action.Trigger", processor_phase = "Waiting",
        process_type = "ExecuteAction", process_phase = "ExecuteAction", process_completed = false,
        process_canceled = false, nested_action_type = "CheckTrigger", nested_action_phase = "CheckTrigger",
        nested_action_completed = false, nested_action_canceled = false, nested_action_result = 0 }
    } } },
    events = { { event_id = 20, owner_token = "c3", playable_readable = true, playable = true,
      initial_speaker_readable = true, initial_speaker_cid = 40,
      speaker_present_readable = true, speaker_present = true,
      speaker = { cid = 40, position_readable = true, pos = { x = 1, y = 2, z = 3 },
        interaction_disabled_readable = true, interaction_disabled = false,
        interaction_allowed_readable = true, interaction_allowed = true },
      history = { lookup_ok = true, present = false, played_readable = false,
        played = nil, result_readable = false, result_no = nil },
      root_node_id = "root", nodes = {
        { node_index = 0, node_id = "root", node_type = "Talk", ordinary_edges = {
          { edge_index = 0, to_node_id = "end", condition_count = 0 } }, choices = {} },
        { node_index = 1, node_id = "end", node_type = "End", end_result = 7,
          keep_previous_result = false, ordinary_edges = {}, choices = {} }
      } } }
  }
  for k, v in pairs(overrides or {}) do o[k] = v end
  return o
end
local function classify(rows, obs, generation)
  obs = obs or observation()
  for _, controller in ipairs(obs.controllers or {}) do
    table.sort(controller.processors or {}, function(a,b) return a.processor_id < b.processor_id end)
  end
  return sources.classify(rows or { row() }, obs or observation(), generation or 4)
end
local function fallback(s, reason)
  eq(s.source_status.complete, false, "status must be degraded")
  eq(s.source_status.reason_code, reason, "fallback reason")
  eq(#s.source_status.rows, 1, "one fallback row")
  local r = s.source_status.rows[1]
  eq(r.scope, "provider"); eq(r.identity, "provider:reward"); eq(r.provider, "reward")
  eq(r.state, "unknown"); eq(r.reason_code, reason); eq(r.generation, s.generation)
  eq(r.qid, nil); eq(r.task_index, nil); eq(#r.item_ids, 0)
end
local function canonical_key(tuple)
  local out={"t",tostring(#tuple),":"}
  for _,v in ipairs(tuple) do
    if type(v)=="number" then out[#out+1]="i"..string.format("%.0f",v)..";"
    else out[#out+1]="s"..#v..":"..v end
  end
  return table.concat(out)
end

do
  local s = classify()
  eq(s.provider, "reward"); eq(s.status, "ok"); eq(s.complete, true); eq(s.generation, 4)
  eq(#s.candidates, 1); eq(s.candidates[1].eligibility, "eligible")
  eq(#s.diagnostic_rows,0,"eligible members do not emit diagnostics")
  local c = s.candidates[1]
  eq(c.provider, "reward"); eq(c.generation, 4); eq(c.source_id[1], "source")
  eq(c.source_id[2], "quest_reward_endpoint"); eq(c.source_id[3], 10); eq(c.source_id[4], 3)
  eq(c.source_id[5], 20); eq(c.source_id[6], 7); eq(c.source_id[7], 1)
  eq(c.source_id[8],2); eq(c.source_id[9],100); eq(c.source_id[10],90)
  eq(s.source_status.rows[1].identity,canonical_key(c.source_id))
  eq(c.capacity_pool_id[1], "capacity"); eq(c.capacity_pool_id[2], "quest_reward_endpoint")
  eq(c.capacity_pool_id[3], 10); eq(c.capacity_pool_id[4], 20)
  eq(c.outputs[1].item_id, 500); eq(c.outputs[1].count, 1)
  eq(c.target.cid, 40); eq(c.pos.x, 1); eq(c.available_acquisitions, 1)
  eq(c.capacity_kind, "finite"); eq(c.certainty, "guaranteed")
  eq(s.source_status.generation, 4); eq(s.source_status.complete, true)
  eq(s.source_status.reason_code, nil); eq(#s.source_status.rows, 1)
  eq(s.source_status.rows[1].scope, "source"); eq(s.source_status.rows[1].state, "available")
  eq(s.source_status.rows[1].reason_code, "available"); eq(s.source_status.rows[1].qid, 10)
  eq(s.source_status.rows[1].task_index, 3); eq(s.source_status.rows[1].item_ids[1], 500)
end

do
  -- Complete negative versus incomplete global observations.
  local obs = observation({ progressing_qids = {} })
  local s = classify({ row() }, obs)
  eq(#s.candidates, 1); eq(s.candidates[1].eligibility, "ineligible")
  eq(s.source_status.rows[1].state, "unavailable"); eq(s.source_status.rows[1].reason_code, "quest_not_progressing")
  obs = observation({ complete = false })
  s = classify({ row() }, obs); eq(s.complete, false); eq(#s.candidates, 0)
  eq(s.reason, "reward_observation_incomplete")
  local good = row({ action_ordinal = 3, processor_id = 101, predecessor_processor_id = 91,
    reward_hashes = { 31 }, talk_event_id = 21 })
  local bad = row({ action_ordinal = 4, processor_id = 102, accept_minus_one = true })
  obs = observation({ reward_outputs = {
    { name_hash = 30, outputs = { { item_id = 500, count = 1 } } },
    { name_hash = 31, outputs = { { item_id = 500, count = 1 } } } } })
  obs.controllers[1].processors[#obs.controllers[1].processors + 1] = {
    processor_id = 101, quest_action_type = "app.quest.action.QuestReward", processor_phase = "Standby" }
  obs.controllers[1].processors[#obs.controllers[1].processors + 1] = {
    processor_id = 91, quest_action_type = "app.quest.action.Trigger", processor_phase = "Waiting",
    process_type = "ExecuteAction", process_phase = "ExecuteAction", process_completed = false,
    process_canceled = false, nested_action_type = "CheckTrigger", nested_action_phase = "CheckTrigger",
    nested_action_completed = false, nested_action_canceled = false, nested_action_result = 0 }
  local second_event = clone(obs.events[1]); second_event.event_id = 21
  obs.events[2] = second_event
  local mixed = classify({ row(), good, bad }, obs)
  eq(mixed.complete, true, mixed.reason); eq(#mixed.candidates, 2)
  local unknown_count, eligible_count = 0, 0
  for _, c in ipairs(mixed.candidates) do
    if c.eligibility == "unknown" then unknown_count = unknown_count + 1 end
    if c.eligibility == "eligible" then eligible_count = eligible_count + 1 end
  end
  eq(unknown_count, 0); eq(eligible_count, 2)
  local legacy=row({action_ordinal=5,processor_id=105,predecessor_processor_id=95,endpoint=false})
  local legacy_mix=classify({row(),legacy},observation())
  eq(legacy_mix.complete,true); eq(#legacy_mix.candidates,1)
  eq(legacy_mix.candidates[1].eligibility,"eligible")
  eq(#legacy_mix.diagnostic_rows,1); eq(legacy_mix.diagnostic_rows[1].status,"unknown")
end

do
  -- Catalog rows outside the current wanted-output intersection are not inspected.
  local irrelevant=row({qid=0,reward_hashes={31}})
  local irrelevant_obs=observation({reward_outputs={
    {name_hash=30,outputs={{item_id=500,count=1}}},
    {name_hash=31,outputs={{item_id=600,count=1}}}}})
  local s=classify({irrelevant},irrelevant_obs)
  eq(s.complete,true,"nonmatching catalog member does not degrade provider")
  eq(#s.candidates,0,"nonmatching catalog member is filtered")
  local missing_map=observation({reward_outputs={}})
  s=classify({row()},missing_map)
  eq(s.complete,false,"missing runtime mapping is not treated as non-intersecting")
  eq(#s.candidates,0,"missing runtime mapping publishes no candidate")
  local empty=observation({wanted={}})
  s=classify({row()},empty)
  eq(s.complete,true,"empty wanted set is a complete empty reward snapshot")
  eq(#s.candidates,0,"empty wanted set publishes no candidates")
  eq(#s.source_status.rows,0,"empty wanted set publishes no source rows")
  empty=observation({wanted={},reward_outputs={}})
  s=classify({row()},empty)
  eq(s.complete,true,"empty wanted set bypasses missing reward mappings")
  s=classify({false},empty)
  eq(s.complete,true,"empty wanted set bypasses uninspectable catalog rows")
  eq(#s.candidates,0,"empty wanted set remains candidate-free with malformed catalog entries")
  eq(#s.source_status.rows,0,"empty wanted set remains status-free with malformed catalog entries")
end

do
  local tests = {
    { "duplicate reward processor", function(o) o.controllers[1].processors[3] = clone(o.controllers[1].processors[1]) end },
    { "duplicate predecessor processor", function(o) o.controllers[1].processors[3] = clone(o.controllers[1].processors[2]) end },
    { "missing reward processor", function(o) table.remove(o.controllers[1].processors, 1) end },
    { "missing predecessor processor", function(o) table.remove(o.controllers[1].processors, 2) end },
    { "action mismatch", function(o) o.controllers[1].processors[1].quest_action_type = "wrong" end },
    { "partial controller", function(o) o.controllers[1].processors = nil end },
  }
  for _, t in ipairs(tests) do
    local o = observation(); t[2](o)
    local s = classify({ row() }, o)
    eq(s.complete, false, t[1]); eq(#s.candidates, 0, t[1]); eq(s.reason, "reward_runtime_scan_incomplete", t[1])
  end
end

do
  local task_cases = {
    { "task index mismatch", function(o) o.tasks[1].targets = {} end, "unavailable", "wrong_current_task" },
    { "speaker mismatch", function(o) o.tasks[1].targets[1].cid = 41 end, "unavailable", "wrong_current_task" },
  }
  for _, t in ipairs(task_cases) do
    local o = observation(); t[2](o); local s = classify({ row() }, o)
    eq(s.candidates[1].eligibility, t[3]=="unavailable" and "ineligible" or t[3], t[1]); eq(s.source_status.rows[1].reason_code, t[4], t[1])
  end
  local incomplete=observation(); incomplete.tasks[1].targets=nil
  local incomplete_result=classify({row()},incomplete); eq(incomplete_result.complete,false)
  eq(incomplete_result.reason,"task_endpoint_unreadable")
  local ambiguous=observation(); ambiguous.tasks[1].targets[2]={kind="npc",task_index=3,cid=40,eligibility="eligible"}
  local blocked=classify({row()},ambiguous); eq(blocked.complete,false); eq(blocked.reason,"task_endpoint_ambiguous")
end

do
  local phases = {
    { "reward Standby", function(o) o.controllers[1].processors[1].processor_phase="Standby" end },
    { "predecessor Waiting", function(o) o.controllers[1].processors[2].processor_phase="Waiting" end },
    { "process ExecuteAction", function(o) o.controllers[1].processors[2].process_phase="ExecuteAction" end },
    { "action CheckTrigger", function(o) o.controllers[1].processors[2].nested_action_phase="CheckTrigger" end },
  }
  for _, phase in ipairs(phases) do local o=observation(); phase[2](o); local s=classify({row()},o)
    eq(s.candidates[1].eligibility,"eligible",phase[1]) end
  local negative = {
    { "reward uninitialized", function(o) o.controllers[1].processors[1].processor_phase="Uninitialized" end, "unknown", "processor_state_unreadable" },
    { "predecessor standby", function(o) o.controllers[1].processors[2].processor_phase="Standby" end, "unknown", "processor_state_unreadable" },
    { "reward unsupported phase", function(o) o.controllers[1].processors[1].processor_phase="Setup" end, "unknown", "processor_state_unreadable" },
    { "reward completed", function(o) o.controllers[1].processors[1].processor_phase="Completed" end, "unavailable", "processor_completed" },
    { "predecessor completed flag", function(o) o.controllers[1].processors[2].process_completed=true end, "unknown", "processor_state_unreadable" },
    { "predecessor completed phase", function(o) o.controllers[1].processors[2].processor_phase="Completed" end, "unknown", "processor_state_unreadable" },
    { "reward canceled", function(o) o.controllers[1].processors[1].processor_phase="Canceled" end, "unavailable", "processor_canceled" },
    { "predecessor canceled", function(o) o.controllers[1].processors[2].nested_action_canceled=true end, "unknown", "processor_state_unreadable" },
  }
  for _, t in ipairs(negative) do local o=observation(); t[2](o); local s=classify({row()},o)
    eq(s.candidates[1].eligibility,t[3]=="unavailable" and "ineligible" or t[3],t[1]); eq(s.source_status.rows[1].reason_code,t[4],t[1]) end
end

do
  local graph = {
    { "ordinary condition", function(e) e.nodes[1].ordinary_edges[1].condition_count=1 end },
    { "choice condition", function(e) e.nodes[1].ordinary_edges={}; e.nodes[1].choices={{choice_index=0,to_node_id="end",condition_count=1}} end },
    { "reachable cycle", function(e) e.nodes[2].ordinary_edges={{edge_index=0,to_node_id="root",condition_count=0}} end },
    { "non-End leaf", function(e) e.nodes[1].ordinary_edges={}; e.nodes[1].choices={} end },
    { "wrong End", function(e) e.nodes[2].end_result=8 end },
    { "kept End", function(e) e.nodes[2].keep_previous_result=true end },
    { "wrong edge index", function(e) e.nodes[1].ordinary_edges[1].edge_index=1 end, true },
    { "node id hash conflict", function(e) e.nodes[1].node_hash=1; e.root_node_hash=2 end, true },
  }
  for _, t in ipairs(graph) do local o=observation(); t[2](o.events[1]); local s=classify({row()},o)
    if t[3] then eq(s.complete,false,t[1]); eq(#s.candidates,0,t[1])
    else eq(s.candidates[1].eligibility,"unknown",t[1]); eq(s.source_status.rows[1].reason_code,"unsupported_reward_graph",t[1]) end end
  local o=observation(); local s=classify({row({accept_minus_one=true})},o)
  eq(s.candidates[1].eligibility,"unknown"); eq(s.source_status.rows[1].reason_code,"unsupported_reward_graph")
  o=observation(); o.events[1].nodes[1].ordinary_edges[1].to_node_id="missing"
  s=classify({row()},o); eq(s.complete,false,"unresolved graph edge invalidates provider"); eq(#s.candidates,0)
  o=observation(); local e=o.events[1]
  e.root_node_hash=1; e.nodes[1].node_hash=1; e.nodes[2].node_hash=2
  e.nodes[1].ordinary_edges[1].to_node_id=nil; e.nodes[1].ordinary_edges[1].to_node_hash=2
  s=classify({row()},o); eq(s.candidates[1].eligibility,"eligible","hash-keyed graph")
  o=observation(); e=o.events[1]; e.nodes[1].ordinary_edges={}; e.nodes[1].choices={{choice_index=0,to_node_id="end",condition_count=0}}
  s=classify({row()},o); eq(s.candidates[1].eligibility,"eligible","choice edge")
  o=observation(); e=o.events[1]; e.nodes[2].node_id=1; e.nodes[1].node_id="1"
  e.root_node_id="1"; e.nodes[1].ordinary_edges[1].to_node_id=1
  s=classify({row()},o); eq(s.candidates[1].eligibility,"eligible","typed node identity")
  o=observation(); e=o.events[1]; e.nodes[3]={node_index=2,node_id="orphan",node_type="Talk",
    ordinary_edges={{edge_index=0,to_node_id="unresolved",condition_count=0}},choices={}}
  s=classify({row()},o); eq(s.complete,false,"unreachable unresolved edge invalidates provider"); eq(#s.candidates,0)
  o=observation(); e=o.events[1]; e.nodes[1].node_id={}
  local safe, malformed_graph=pcall(classify,{row()},o)
  eq(safe,true,"malformed node identity must not throw"); eq(malformed_graph.complete,false)
end

do
  local cases = {
    { "not playable", function(o) o.events[1].playable=false end, "unavailable", "event_not_playable" },
    { "speaker absent", function(o) o.events[1].speaker_present=false; o.events[1].speaker=nil end, "unknown", "speaker_unreadable" },
    { "interaction disabled", function(o) o.events[1].speaker.interaction_disabled=true end, "unavailable", "interaction_unavailable" },
    { "interaction denied", function(o) o.events[1].speaker.interaction_allowed=false end, "unavailable", "interaction_unavailable" },
    { "claimed", function(o) o.events[1].history.present=true; o.events[1].history.played_readable=true; o.events[1].history.played=true end, "unavailable", "already_claimed" },
    { "history absent", function(o) o.events[1].history.lookup_ok=true; o.events[1].history.present=false end, "eligible", "available" },
    { "history false", function(o) o.events[1].history.present=true; o.events[1].history.played_readable=true; o.events[1].history.played=false end, "eligible", "available" },
    { "history lookup failed", function(o) o.events[1].history.lookup_ok=false end, "unknown", "history_unreadable" },
    { "history played unreadable", function(o) o.events[1].history.present=true; o.events[1].history.played_readable=false; o.events[1].history.played=nil end, "unknown", "history_unreadable" },
    { "unreadable stale playable", function(o) o.events[1].playable_readable=false end, "unknown", "observation_contradictory" },
    { "position absent", function(o) o.events[1].speaker.position_readable=false; o.events[1].speaker.pos=nil end, "unknown", "speaker_position_unreadable" },
    { "stale absent speaker", function(o) o.events[1].speaker_present_readable=false end, "unknown", "observation_contradictory" },
  }
  for _, t in ipairs(cases) do local o=observation(); t[2](o); local s=classify({row()},o)
    eq(s.candidates[1].eligibility,t[3]=="unavailable" and "ineligible" or t[3],t[1]); eq(s.source_status.rows[1].state,t[3]=="eligible" and "available" or t[3],t[1]); eq(s.source_status.rows[1].reason_code,t[4],t[1]) end
end

do
  -- Residual fix-round cases: provider atomicity, status vocabulary and canonical tuples.
  local failures={}
  local function expect(label, ok)
    if not ok then failures[#failures+1]=label end
  end
  local unreadable=observation(); unreadable.events[1].playable_readable=false; unreadable.events[1].playable=nil
  local play=classify({row()},unreadable)
  expect("unreadable absent playability stays unknown",play.candidates[1]
    and play.candidates[1].eligibility=="unknown")

  local history=observation(); history.events[1].history.result_readable=true
  local absent_history=classify({row()},history)
  expect("absent history requires unreadable result flag",absent_history.candidates[1]
    and absent_history.candidates[1].eligibility=="unknown")
  history=observation(); history.events[1].history.played_readable=true
  history.events[1].history.played=false
  absent_history=classify({row()},history)
  expect("absent history has no played payload",absent_history.candidates[1]
    and absent_history.candidates[1].eligibility=="unknown")

  local missing=observation(); missing.events={}
  local absent=classify({row()},missing)
  expect("required event missing is provider-atomic",absent.complete==false and #absent.candidates==0
    and #absent.source_status.rows==1 and absent.source_status.rows[1].scope=="provider")
  local duplicated=observation(); duplicated.events[2]=clone(duplicated.events[1])
  local repeated=classify({row()},duplicated)
  expect("required event duplicate is provider-atomic",repeated.complete==false and #repeated.candidates==0
    and #repeated.source_status.rows==1 and repeated.source_status.rows[1].scope=="provider")

  local negative=classify({row()},observation({progressing_qids={}}))
  expect("diagnostic uses ineligible status",negative.diagnostic_rows[1].status=="ineligible")
  local unknown=classify({row({accept_minus_one=true})},observation())
  expect("unknown member uses unknown diagnostic status",#unknown.diagnostic_rows==1
    and unknown.diagnostic_rows[1].status=="unknown")
  for _,d in ipairs(negative.diagnostic_rows) do
    expect("negative diagnostic status is frozen",d.status=="ineligible" or d.status=="unknown")
  end

  local float_row=row()
  float_row.quest_id=10.0; float_row.source_identity.quest_id=10.0
  float_row.source_identity.action_ordinal=2.0; float_row.source_identity.processor_id=100.0
  float_row.endpoint_evidence.predecessor_processor_id=90.0
  float_row.endpoint_evidence.talk_event_id=20.0; float_row.endpoint_evidence.end_no=7.0
  local float_obs=observation(); float_obs.tasks[1].task_index=3.0
  float_obs.tasks[1].targets[1].task_index=3.0
  local canonical=classify({float_row},float_obs)
  local core=require("Clairvoyance.core")
  local tuple=canonical.candidates[1] and canonical.candidates[1].source_id or {}
  local all_integer=true
  for _,v in ipairs(tuple) do if type(v)=="number" and math.type(v)~="integer" then all_integer=false end end
  expect("integral floats normalized before tuple publication",all_integer and core.target_key(tuple)~=nil)

  assert(#failures==0,"residual RED cases: "..table.concat(failures,"; "))
end

do
  -- Adversarial review regressions.
  local o=observation(); o.controllers[1].processors[2].nested_action_result=0
  local s=classify({row()},o)
  eq(s.candidates[1].eligibility,"eligible","relation result is distinct from End result")

  o=observation(); o.events[1].speaker.interaction_disabled_readable=false
  o.events[1].speaker.interaction_disabled=nil
  s=classify({row()},o)
  eq(s.candidates[1].eligibility,"unknown","unreadable interaction state")

  o=observation(); o.events[1].history.result_readable=true; o.events[1].history.result_no=7
  s=classify({row()},o)
  eq(s.candidates[1].eligibility,"unknown","result without history row")

  o=observation(); local sibling=clone(o.events[1]); sibling.event_id=21; sibling.nodes=nil; o.events[2]=sibling
  s=classify({row()},o)
  eq(s.complete,false,"incomplete sibling event invalidates provider"); eq(#s.candidates,0)

  local unsupported=row({action_ordinal=1,processor_id=101,predecessor_processor_id=91,accept_minus_one=true})
  o=observation(); o.controllers[1].processors[#o.controllers[1].processors+1]={
    processor_id=101,quest_action_type="app.quest.action.QuestReward",processor_phase="Standby"}
  o.controllers[1].processors[#o.controllers[1].processors+1]={
    processor_id=91,quest_action_type="app.quest.action.Trigger",processor_phase="Waiting",
    process_type="ExecuteAction",process_phase="ExecuteAction",process_completed=false,process_canceled=false,
    nested_action_type="CheckTrigger",nested_action_phase="CheckTrigger",nested_action_completed=false,
    nested_action_canceled=false,nested_action_result=0}
  s=classify({row(),unsupported},o)
  eq(s.complete,true); eq(#s.candidates,1,"unsupported sibling does not claim eligible capacity")
  eq(s.candidates[1].eligibility,"eligible")
  local core=require("Clairvoyance.core")
  local need={id={"need",10,700,3,1},qid=10,task_index=3,remaining=1,
    options={{item_id=500,accepted_count=1}},status="eligible",complete=true,generation=4}
  local task={focus_epoch=1,journal_generation=2,need_generation=1,
    objective_needs={status="ok",complete=true,generation=1,source_generation=4,groups={need}},
    quests={{qid=10,task_index=3,read_status="ok",issued_npcs={},task_destinations={},guidance={},item_ownership={}}}}
  local objective=core.objective_snapshot(task,nil,{s},core.target_registry_new())
  local published=0
  for _,target in ipairs(objective and objective.targets or {}) do if target.kind=="source" then published=published+1 end end
  eq(published,1,"real core snapshot preserves valid sibling source")

  local completed=row({action_ordinal=1,processor_id=101,predecessor_processor_id=91,reward_hashes={31}})
  o=observation({reward_outputs={
    {name_hash=30,outputs={{item_id=500,count=1}}},
    {name_hash=31,outputs={{item_id=501,count=1}}}}})
  o.wanted={500,501}
  o.controllers[1].processors[#o.controllers[1].processors+1]={
    processor_id=101,quest_action_type="app.quest.action.QuestReward",processor_phase="Completed"}
  o.controllers[1].processors[#o.controllers[1].processors+1]={
    processor_id=91,quest_action_type="app.quest.action.Trigger",processor_phase="Waiting",
    process_type="ExecuteAction",process_phase="ExecuteAction",process_completed=false,process_canceled=false,
    nested_action_type="CheckTrigger",nested_action_phase="CheckTrigger",nested_action_completed=false,
    nested_action_canceled=false,nested_action_result=0}
  s=classify({row(),completed},o)
  eq(s.complete,true); eq(#s.candidates,1,"completed sibling excluded from eligible aggregate")
  eq(s.candidates[1].eligibility,"eligible"); eq(s.candidates[1].source_id[7],1)
  eq(s.candidates[1].outputs[1].item_id,500)
  local excluded=false
  for _,d in ipairs(s.diagnostic_rows) do if d.member_id and d.status=="ineligible" then excluded=true end end
  eq(excluded,true,"excluded sibling retains diagnostics")

  o=observation({reward_outputs={{name_hash=30,outputs={{item_id=500,count=1},{item_id=501,count=4}}}}})
  s=classify({row()},o)
  eq(#s.candidates[1].outputs,2,"candidate keeps every reward output")
  eq(#s.source_status.rows[1].item_ids,1,"status lists matched output ids only")
  eq(s.source_status.rows[1].item_ids[1],500)

  local one=classify({row()},observation())
  o=observation(); o.tasks[1].task_index=4; o.tasks[1].targets[1].task_index=4
  local two=classify({row()},o)
  eq(one.candidates[1].source_id[4],3); eq(two.candidates[1].source_id[4],4)
  eq(canonical_key(one.candidates[1].source_id)~=canonical_key(two.candidates[1].source_id),true)
  eq(#one.diagnostic_rows,0); eq(#two.diagnostic_rows,0)
  local unknown_one=classify({row({accept_minus_one=true})},observation())
  local unknown_obs=observation(); unknown_obs.tasks[1].task_index=4; unknown_obs.tasks[1].targets[1].task_index=4
  local unknown_two=classify({row({accept_minus_one=true})},unknown_obs)
  eq(unknown_one.diagnostic_rows[1].member_id~=unknown_two.diagnostic_rows[1].member_id,true,
    "diagnostic identity includes task index")
  eq(core.target_key(one.candidates[1].source_id)~=nil,true,"published source tuple accepted by core")
  eq(core.target_key(two.candidates[1].source_id)~=nil,true,"changed task tuple accepted by core")
  local canonical_need={id={"need",10,700,4,1},qid=10,task_index=4,remaining=1,
    options={{item_id=500,accepted_count=1}},status="eligible",complete=true,generation=4}
  local canonical_task={focus_epoch=1,journal_generation=2,need_generation=1,
    objective_needs={status="ok",complete=true,generation=1,source_generation=4,groups={canonical_need}},
    quests={{qid=10,task_index=4,read_status="ok",issued_npcs={},task_destinations={},guidance={},item_ownership={}}}}
  local canonical_snapshot=core.objective_snapshot(canonical_task,nil,{two},core.target_registry_new())
  local canonical_sources=0
  for _,target in ipairs(canonical_snapshot and canonical_snapshot.targets or {}) do
    if target.kind=="source" then canonical_sources=canonical_sources+1 end
  end
  eq(canonical_sources,1,"real core accepts canonical task/member tuple")
  for _,d in ipairs(unknown_two.diagnostic_rows) do
    eq(type(d.member_id),"string"); eq(type(d.gate),"string"); eq(type(d.status),"string")
    eq(d.status=="ineligible" or d.status=="unknown",true,"diagnostic uses frozen eligibility vocabulary")
    local fields=0;for _ in pairs(d) do fields=fields+1 end
    eq(fields,3,"diagnostic row has exact member_id/gate/status shape")
  end
end

do
  local r1=row(); local r2=row({ action_ordinal=1, processor_id=101, predecessor_processor_id=91,
    reward_hashes={31} })
  local o=observation({ reward_outputs={
    {name_hash=30,outputs={{item_id=500,count=2},{item_id=501,count=3}}},
    {name_hash=31,outputs={{item_id=500,count=4},{item_id=502,count=1}}} } })
  o.wanted={500,501,502}
  for _, id in ipairs({101,91}) do
    local p = id==101 and {processor_id=101,quest_action_type="app.quest.action.QuestReward",processor_phase="Standby"}
      or {processor_id=91,quest_action_type="app.quest.action.Trigger",processor_phase="Waiting",process_type="ExecuteAction",process_phase="ExecuteAction",process_completed=false,process_canceled=false,nested_action_type="CheckTrigger",nested_action_phase="CheckTrigger",nested_action_completed=false,nested_action_canceled=false,nested_action_result=0}
    o.controllers[1].processors[#o.controllers[1].processors+1]=p
  end
  local s=classify({r1,r2},o); eq(#s.candidates,1); eq(s.candidates[1].source_id[8],1)
  eq(s.candidates[1].outputs[1].item_id,500); eq(s.candidates[1].outputs[1].count,6)
  eq(s.candidates[1].outputs[2].item_id,501); eq(s.candidates[1].outputs[2].count,3)
  eq(s.candidates[1].outputs[3].item_id,502); eq(s.candidates[1].outputs[3].count,1)
  eq(#s.source_status.rows,1); eq(#s.source_status.rows[1].item_ids,3)
end

do
  -- The maximum source tuple remains flat, within 32 parts, and status carries all 256 outputs.
  local rows, obs, processors, outputs, wanted = {}, observation(), {}, {}, {}
  for i=1,8 do
    rows[i]=row({action_ordinal=i-1,processor_id=100+i,predecessor_processor_id=200+i,
      reward_hashes={29+i}})
    local base=(i-1)*32
    outputs[i]={name_hash=29+i,outputs={}}
    for j=1,32 do
      local id=base+j; wanted[#wanted+1]=id
      outputs[i].outputs[j]={item_id=id,count=1}
    end
    processors[#processors+1]={processor_id=100+i,quest_action_type="app.quest.action.QuestReward",processor_phase="Standby"}
    processors[#processors+1]={processor_id=200+i,quest_action_type="app.quest.action.Trigger",processor_phase="Waiting",
      process_type="ExecuteAction",process_phase="ExecuteAction",process_completed=false,process_canceled=false,
      nested_action_type="CheckTrigger",nested_action_phase="CheckTrigger",nested_action_completed=false,
      nested_action_canceled=false,nested_action_result=0}
  end
  obs.wanted=wanted; obs.reward_outputs=outputs; obs.controllers[1].processors=processors
  local s=classify(rows,obs); eq(s.complete,true); eq(#s.candidates,1)
  eq(#s.candidates[1].source_id,31); eq(#s.source_status.rows[1].item_ids,256)
  eq(s.candidates[1].source_id[8],0); eq(s.candidates[1].source_id[29],7)
  eq(s.candidates[1].source_id[30],108); eq(s.candidates[1].source_id[31],208)
end

do
  local function provider_unknown(rows, obs)
    local s=classify(rows,obs); eq(s.complete,false); eq(#s.candidates,0); eq(s.status,"unknown"); return s
  end
  local cases={
    {"ninth member", function()
      local a,o,ps,outs={},observation(),{},{}
      for i=1,9 do
        a[i]=row({action_ordinal=i-1,processor_id=100+i,predecessor_processor_id=200+i,reward_hashes={29+i}})
        outs[i]={name_hash=29+i,outputs={{item_id=500,count=1}}}
        ps[#ps+1]={processor_id=100+i,quest_action_type="app.quest.action.QuestReward",processor_phase="Standby"}
        ps[#ps+1]={processor_id=200+i,quest_action_type="app.quest.action.Trigger",processor_phase="Waiting",
          process_type="ExecuteAction",process_phase="ExecuteAction",process_completed=false,process_canceled=false,
          nested_action_type="CheckTrigger",nested_action_phase="CheckTrigger",nested_action_completed=false,
          nested_action_canceled=false,nested_action_result=0}
      end
      o.reward_outputs=outs;o.controllers[1].processors=ps;return a,o
    end},
    {"different end pool", function() local a=row(); local b=row({action_ordinal=3,processor_id=103,predecessor_processor_id=203,end_no=8}); return {a,b},observation() end},
    {"duplicate member", function() return {row(),row()},observation() end},
    {"duplicate hash", function() return {row({reward_hashes={30,30}})},observation() end},
    {"duplicate reward row", function() local o=observation(); o.reward_outputs[2]=clone(o.reward_outputs[1]); return {row()},o end},
    {"sum overflow", function() local o=observation({reward_outputs={{name_hash=30,outputs={{item_id=500,count=2147483647}}}}}); local b=row({action_ordinal=3,processor_id=103,predecessor_processor_id=203,reward_hashes={31}}); o.reward_outputs[2]={name_hash=31,outputs={{item_id=500,count=1}}}; return {row(),b},o end},
    {"reward row 513", function() local o=observation(); for i=2,513 do o.reward_outputs[i]={name_hash=i,outputs={{item_id=600,count=1}}} end; return {row()},o end},
    {"reward item 33", function() local o=observation(); for i=2,33 do o.reward_outputs[1].outputs[i]={item_id=600+i,count=1} end; return {row()},o end},
    {"zero item", function() local o=observation(); o.reward_outputs[1].outputs[1].item_id=0; return {row()},o end},
    {"negative count", function() local o=observation(); o.reward_outputs[1].outputs[1].count=-1; return {row()},o end},
    {"sparse array", function() local o=observation(); o.progressing_qids[3]=10; return {row()},o end},
    {"multibyte identity component", function() return {row({qid="é"})},observation() end},
  }
  for _, t in ipairs(cases) do local rows,obs=t[2](); provider_unknown(rows,obs) end
end

do
  -- Source status is sorted, generation-atomic, and observational only.
  local status_obs=observation({progressing_qids={}})
  status_obs.tasks={{qid=11,task_index=1,targets={}},{qid=12,task_index=2,targets={}}}
  local s=classify({row({qid=11,action_ordinal=3,processor_id=103,predecessor_processor_id=93}),
    row({qid=12,action_ordinal=2,processor_id=102,predecessor_processor_id=92})},status_obs)
  eq(s.source_status.complete,true); eq(s.source_status.generation,s.generation)
  for _,r in ipairs(s.source_status.rows) do eq(r.generation,s.generation); eq(r.provider,"reward") end
  eq(s.source_status.rows[1].identity < s.source_status.rows[2].identity,true)
  local before=#s.candidates; s.source_status=nil; eq(#s.candidates,before,"status deletion cannot alter candidates")
  local malformed=classify({row()},observation({wanted={500,500}}))
  eq(malformed.complete,false); fallback(malformed,"status_malformed")
  local non_table=sources.classify({row()},3,4)
  eq(non_table.complete,false); fallback(non_table,"status_malformed")
  local malformed_endpoint=row(); malformed_endpoint.endpoint_evidence.predecessor_processor_id="bad"
  local invalid_endpoint=classify({malformed_endpoint},observation())
  eq(invalid_endpoint.complete,false); fallback(invalid_endpoint,"status_malformed")
  local invalid_generation=classify({row()},observation(),0)
  eq(invalid_generation.complete,false); fallback(invalid_generation,"status_malformed")
  local provider_failure=classify({row()},observation({complete=false}))
  fallback(provider_failure,"reward_observation_incomplete")
  local duplicate=classify({row(),row()},observation())
  fallback(duplicate,"status_duplicate_identity")
  local many={}
  for i=1,513 do many[i]=row({action_ordinal=i,processor_id=100+i,
    predecessor_processor_id=1000+i,accept_minus_one=true}) end
  local overflow=classify(many,observation())
  eq(overflow.complete,true); eq(#overflow.candidates,513)
  fallback(overflow,"status_row_overflow")
  -- Degrading the envelope cannot change the candidate publication.
  local count=#overflow.candidates; overflow.source_status.rows[1].state="available"
  eq(#overflow.candidates,count)
end

print("reward_sources_test: all OK")
