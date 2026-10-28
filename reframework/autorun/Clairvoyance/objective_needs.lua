-- Pure conversion of complete processor expressions into objective need groups.
local M = {}

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end
local function nonnegative_integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

-- Each record is one native item expression. Alternatives remain options in
-- one group; inventory already held across accepted alternatives reduces its
-- shared remaining count. Incomplete or malformed expressions fail closed.
function M.build(records, held, meta)
  held, meta = held or {}, meta or {}
  local out, complete = {}, true
  for _, record in ipairs(records or {}) do
    local options, seen, required, held_total = {}, {}, nil, 0
    local valid = type(record) == "table" and record.complete == true
      and record.current_work == true
      and positive_integer(record.qid) and positive_integer(record.processor_id)
      and nonnegative_integer(record.list_index) and nonnegative_integer(record.condition_index)
      and type(meta.task_index) == "table"
      and nonnegative_integer(meta.task_index[record.qid])
      and meta.task_generation == meta.generation
      and type(record.options) == "table" and #record.options > 0
    if valid then
      for _, option in ipairs(record.options) do
        local id = option.item_id
        local count = option.required
        if not positive_integer(id)
          or (option.op == "more" and not positive_integer(count))
          or (option.op == "morethan" and not nonnegative_integer(count))
          or (option.op ~= "more" and option.op ~= "morethan") or seen[id] then
          valid = false
          break
        end
        if option.op == "morethan" then count = count + 1 end
        if required ~= nil and count ~= required then
          valid = false
          break
        end
        required, seen[id] = count, true
        local held_count = held[id] or 0
        if not nonnegative_integer(held_count) then
          valid = false
          break
        end
        held_total = held_total + held_count
        options[#options + 1] = { item_id = id, accepted_count = count }
      end
    end
    if valid and positive_integer(required) then
      table.sort(options, function(a, b) return a.item_id < b.item_id end)
      local remaining = math.max(0, required - held_total)
      if remaining > 0 then
        out[#out + 1] = {
          id = { "need", record.qid, record.processor_id,
            record.list_index, record.condition_index },
          qid = record.qid, task_index = meta.task_index[record.qid],
          processor_id = record.processor_id, remaining = remaining,
          options = options, complete = true, generation = meta.generation,
          status = "eligible",
        }
      end
    else
      complete = false
    end
  end
  table.sort(out, function(a, b)
    if a.qid ~= b.qid then return a.qid < b.qid end
    if a.processor_id ~= b.processor_id then return a.processor_id < b.processor_id end
    if a.id[4] ~= b.id[4] then return a.id[4] < b.id[4] end
    return a.id[5] < b.id[5]
  end)
  return out, complete
end

return M
