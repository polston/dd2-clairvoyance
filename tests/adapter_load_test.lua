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
ValueType = permissive()
Vector3f = permissive()
-- learned-name store: stored file with good and bad entries; dumps captured
local dumped, dump_count, dump_result = nil, 0, true
json = {
  load_file = function()
    return { ["20001"] = "Alpha", ["x"] = "bad", ["20002"] = "",
      ["20003"] = 7, ["10030"] = "Learned Override" }
  end,
  dump_file = function(_, t)
    dumped = t; dump_count = dump_count + 1; return dump_result
  end,
}

local A = require("adapter")

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
  "read_masquerade_door_closed",
}
for _, name in ipairs(exports) do
  assert(A[name] ~= nil, "missing export: " .. name)
end
assert(A.PUBLIC_MAP_POSITIONS == nil, "PUBLIC_MAP_POSITIONS must be gone")

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
  "objective_cids", "objective_pos", "refresh_objectives", "objective_stats",
  "refresh_gates", "gate_qids", "gate_stats", "invalidate_gates",
  "seen_quest_name", "quest_region",
  "refresh_tree_gates", "invalidate_tree_gates", "tree_gate_qids",
  "tree_gate_table", "tree_gate_stats",
  "invalidate_items", "item_needs", "item_locations", "item_name", "item_stats",
  "refresh_items", "item_related", "reset_item_throttle", "quest_steps_text",
  "tracked_qid", "journal_now", "journal_all", "npc_name", "journal_stats",
  "map_open", "map_jump_apply", "journal_note_jump", "map_cursor",
  "quest_step", "masquerade_door_closed",
}
assert(#contract == 49)
for _, name in ipairs(contract) do
  assert(type(a[name]) == "function", "contract function missing: " .. name)
end
assert(type(a.reset_session_caches) == "function", "reset_session_caches missing")
assert(a.objective_cids(1) == nil, "no walk committed yet")
assert(type(A.argb_to_abgr(0xFF112233)) == "number")
assert(A.argb_to_abgr(0xFF112233) == 0xFF332211)
assert(type(A.debug_probe()) == "string")

assert(type(A.catalog_ids) == "function", "catalog_ids exported")
assert(type(A.quest_state) == "function", "quest_state exported")
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
  local qlm = { call = function(_, m)
    if m == "getProgressingQuestIds" and not prog_nil then
      return mcoll(prog_ids)
    end
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
  aw.refresh_objectives()
  -- (4) 3 consecutive missing QuestManager walks empty the table
  use_qm = false
  aw.refresh_objectives(); aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) ~= nil, "two failures keep last table")
  aw.refresh_objectives()
  assert(aw.objective_cids(side_qid) == nil, "3 failures empty the table")
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
    data_calls = 0, dict_reads = 0, cls_reads = 0, started_reads = 0,
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
      ConditionLists = ilist({ ilist(conds) },
        function() IS.cls_reads = IS.cls_reads + 1 end),
    })
    p.get_field = function(self, n)
      if n == "ConditionLists" and (o.cls_nil_reads or 0) > 0 then
        o.cls_nil_reads = o.cls_nil_reads - 1   -- a failed read (safe_field nil)
        return nil
      end
      if n == "<IsStarted>k__BackingField" then
        IS.started_reads = IS.started_reads + 1
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
  local function drop(id, upos, lpos, deleted)
    return gim("app.Gm82_000_01", { ItemId = id,
      MyContext = mobj({ _ItemId = id, _Num = 1 }),
      ["<IsDeleted>k__BackingField"] = deleted == true }, upos, lpos)
  end
  local function box(ids, upos, lpos)
    local items = {}
    for i, id in ipairs(ids) do items[i] = mobj({ ItemId = id, ItemNum = 1 }) end
    return gim("app.gm80_001", { ItemId = ids[1], ItemList = ilist(items) },
      upos, lpos)
  end
  local function hset(gs)        -- false = free slot
    local elems = {}
    for i, g in ipairs(gs) do
      elems[i] = (g == false) and mobj({}) or mobj({ Value = g })
    end
    return mobj({ _entries = arr(elems) })
  end
  local function managed(sets)   -- false = free outer slot
    local elems = {}
    for i, s in ipairs(sets) do
      elems[i] = (s == false) and mobj({}) or mobj({ value = s })
    end
    return mobj({ _entries = arr(elems) })
  end
  local function gmgr(o)
    return mobj({
      ["<ManagedGimmicksByIDs>k__BackingField"] = o.managed,
      ["<DropItemGimmicks>k__BackingField"] = o.drops and ilist(o.drops) or nil,
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
    IS.dict = storage({ { key = PL, value = ilist({}) } })
    IS.icons = { [300] = 2017 }
    IS.icon_fail = {}
    IS.gm = gmgr({ managed = managed({ hset({ placed(300, V, L) }) }),
      drops = {}, boxes = {} })
    IS.gets = {}
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
  iqlm = { call = iqlm.call }
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
  local s = ai.item_stats()
  assert(s.needs == 1 and s.ids == 1 and s.located == 1 and s.rounds == 1
    and s.skipped == 0 and s.ignored == 0 and s.failed_total == 0,
    "IW1 stats (rounds re-counted after the owner reset)")
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
  assert(#(needs_of(ai, 20090) or {}) == 1, "IW3 storage box (65535) not counted")
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
  IS.gm = gmgr({ managed = managed({ mobj({ _entries = arr({
    mobj({ value = placed(300, V, L) }) }) }) }), drops = {}, boxes = {} })
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

-- v14: the masquerade passage leaf is selected by the full fingerprint.
do
  local function obj(fields, calls, tn)
    return {
      get_field = function(_, n)
        local v = fields and fields[n]
        if v == "RAISE" then error("field") end
        return v
      end,
      call = function(_, n, ...)
        local f = calls and calls[n]
        if f == "RAISE" then error("call") end
        return type(f) == "function" and f(...) or f
      end,
      get_type_definition = function()
        return { get_full_name = function() return tn end }
      end,
    }
  end
  local function arr(values)
    return { get_elements = function() return values end }
  end
  local function manager(x, closed, opt)
    opt = opt or {}
    local leaf = obj({ IsClose = closed })
    local list = obj(nil, {
      get_Count = function() return opt.leaf_count or 1 end,
      get_Item = function() return leaf end,
    })
    local pos = opt.pos or { x = x, y = 73.5, z = -819.250 }
    local tr = obj(nil, { get_UniversalPosition = function() return pos end })
    local go = obj(nil, {
      get_Name = function() return opt.name or "gm80_026" end,
      get_Transform = function() return tr end,
    })
    local g = obj({ CompDoorList = list }, { get_GameObject = function() return go end },
      opt.type_name or "app.gm05_046")
    local inner = { obj({ Value = g }) }
    if opt.duplicate then inner[2] = obj({ Value = g }) end
    local hs = obj({ _entries = arr(inner) })
    local outer = { obj({ key = opt.gid or 85, value = hs }) }
    return obj({ ["<ManagedGimmicksByIDs>k__BackingField"] = obj({ _entries = arr(outer) }) })
  end

  assert(A.read_masquerade_door_closed(manager(396.075, true)) == true,
    "DR1 closed fingerprint")
  assert(A.read_masquerade_door_closed(manager(396.075, false)) == false,
    "DR2 opening/open fingerprint")
  assert(A.read_masquerade_door_closed(manager(396.325, true)) == true,
    "DR3 inclusive 0.25 boundary")
  assert(A.read_masquerade_door_closed(manager(396.3251, true)) == nil,
    "DR4 outside tolerance")
  assert(A.read_masquerade_door_closed(manager(396.075, true, { gid = 86 })) == nil,
    "DR5 gid mismatch")
  assert(A.read_masquerade_door_closed(manager(396.075, true, { name = "other" })) == nil,
    "DR6 name mismatch")
  assert(A.read_masquerade_door_closed(manager(396.075, true,
      { type_name = "app.OtherDoor" })) == nil, "DR7 type mismatch")
  assert(A.read_masquerade_door_closed(manager(396.075, true, { leaf_count = 0 })) == nil,
    "DR8 empty leaf list")
  assert(A.read_masquerade_door_closed(manager(396.075, true, { leaf_count = 2 })) == nil,
    "DR9 multiple leaves")
  assert(A.read_masquerade_door_closed(manager(396.075, true, { duplicate = true })) == nil,
    "DR10 duplicate match is unknown")
  assert(A.read_masquerade_door_closed(manager(396.075, true,
      { pos = { x = 0 / 0, y = 73.5, z = -819.250 } })) == nil, "DR11 malformed position")

  local old_gms = sdk.get_managed_singleton
  local qowner, gm = {}, manager(396.075, false)
  sdk.get_managed_singleton = function(n)
    if n == "app.QuestLogManager" then return qowner end
    if n == "app.GimmickManager" then return gm end
  end
  a.reset_session_caches()
  assert(a.masquerade_door_closed() == false, "DR12 open commits last-known")
  gm = nil
  assert(a.masquerade_door_closed() == false, "DR13 unreadable keeps last-known")
  qowner = {}
  assert(a.reset_session_caches() == true, "DR14 owner reset")
  assert(a.masquerade_door_closed() == nil, "DR15 reset returns unknown")
  gm = manager(396.075, true)
  assert(a.masquerade_door_closed() == true, "DR16 confirmed close restores")
  sdk.get_managed_singleton = old_gms
end

print("adapter_load_test: OK")
