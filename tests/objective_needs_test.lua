package.path = "reframework/autorun/Clairvoyance/?.lua;" .. package.path

local needs = require("objective_needs")
local groups, complete = needs.build({
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 2,
    current_work = true, complete = true, options = {
    { item_id = 100, required = 3, op = "more" },
    { item_id = 101, required = 3, op = "more" },
  } },
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 4,
    current_work = true, complete = true, options = {
    { item_id = 100, required = 2, op = "more" },
  } },
}, { [100] = 1, [101] = 1 }, {
  generation = 9, task_generation = 9, task_index = { [7] = 12 },
})
assert(complete and #groups == 2, "two expressions remain independent")
assert(groups[1].id[1] == "need" and groups[1].id[2] == 7
  and groups[1].id[3] == 81 and groups[1].id[4] == 0
  and groups[1].id[5] == 2 and groups[1].remaining == 1,
  "alternatives share one remaining quantity after held inventory")
assert(#groups[1].options == 2 and groups[1].options[1].item_id == 100
  and groups[1].options[2].item_id == 101, "alternative membership is preserved")
assert(groups[2].id[5] == 4 and groups[2].remaining == 1,
  "same item in a second expression remains a separate group")
local morethan, morethan_complete = needs.build({
  { qid = 7, processor_id = 82, list_index = 0, condition_index = 1,
    current_work = true, complete = true, options = {
      { item_id = 102, required = 0, op = "morethan" },
      { item_id = 103, required = 0, op = "morethan" },
    } },
}, {}, { generation = 9, task_generation = 9, task_index = { [7] = 0 } })
assert(morethan_complete and #morethan == 1 and morethan[1].remaining == 1
  and morethan[1].options[1].accepted_count == 1,
  "Morethan zero remains a positive one-item alternative requirement")
local satisfied, satisfied_complete = needs.build({
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 2,
    current_work = true, complete = true, options = {
      { item_id = 100, required = 3, op = "more" },
      { item_id = 101, required = 3, op = "more" },
    } },
}, { [100] = 3 }, { generation = 9, task_generation = 9,
  task_index = { [7] = 0 } })
assert(satisfied_complete and #satisfied == 0,
  "held inventory fully satisfying any alternative removes the group")
local invalid, valid = needs.build({
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 5,
    current_work = true, complete = false,
    options = { { item_id = 100, required = 1, op = "more" } } },
}, {}, { generation = 10, task_generation = 10, task_index = { [7] = 12 } })
assert(not valid and #invalid == 0, "incomplete expression is unknown, never eligible")
local unproved = needs.build({
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 6,
    options = { { item_id = 100, required = 1, op = "more" } } },
}, {}, { generation = 11, task_generation = 11, task_index = { [7] = 12 } })
assert(#unproved == 0, "processor without current-work proof is excluded")
local stale_task, stale_complete = needs.build({
  { qid = 7, processor_id = 81, list_index = 0, condition_index = 7,
    current_work = true, complete = true,
    options = { { item_id = 100, required = 1, op = "more" } } },
}, {}, { generation = 12, task_generation = 11, task_index = { [7] = 12 } })
assert(not stale_complete and #stale_task == 0,
  "task observation from another freshness generation invalidates groups")
print("objective_needs_test: OK")
