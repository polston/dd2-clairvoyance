-- Bounded read-only current-gold evidence for ROADMAP 95. Run only through
-- tools/probe/run.py. It does not place orders, alter inventory, or write state.
local function F(object, name)
  if object == nil then return nil end
  local ok, value = pcall(function() return object:get_field(name) end)
  return ok and value or nil
end

local function integer(value)
  if type(value) == "number" then return math.tointeger(value) end
  local nested = F(value, "value__")
  return type(nested) == "number" and math.tointeger(nested) or nil
end

local function bounded_vector(ok, elements, cap)
  if not ok or elements == nil then return {}, nil, false, false end
  local rows, count = {}, nil
  if type(elements) == "table" then
    local keys = {}
    for key, row in pairs(elements) do
      if type(key) == "number" and row ~= nil then keys[#keys + 1] = key end
    end
    table.sort(keys)
    count = #keys
    for index = 1, math.min(count, cap) do
      rows[#rows + 1] = elements[keys[index]]
    end
  else
    local count_ok
    count_ok, count = pcall(function() return #elements end)
    count = count_ok and integer(count) or nil
    if count == nil or count < 0 then return {}, nil, false, false end
    for index = 1, math.min(count, cap) do
      local item_ok, row = pcall(function() return elements[index] end)
      if not item_ok then return {}, count, count > cap, false end
      rows[#rows + 1] = row
    end
  end
  local capped = count > cap
  return rows, count, capped, not capped
end

local item_manager = sdk.get_managed_singleton("app.ItemManager")
assert(item_manager ~= nil, "ItemManager unavailable")
local golden_ok, golden = reviewed_try_call(item_manager, "get__Golden")
golden = golden_ok and integer(golden) or nil

local talk_player = sdk.get_managed_singleton("app.TalkEventPlayer")
local talk_gold = integer(F(talk_player, "_CurrentGold"))
local talk_spend = integer(F(talk_player, "_BoughtItemMoney"))

local prices, price_count, min_price, max_price = {}, 0, nil, nil
local dictionary = F(item_manager, "_ItemDataDict")
local entries = F(dictionary, "_entries")
local elements_ok, elements = reviewed_array_elements(entries)
local price_rows, price_array_count, price_array_capped, price_array_ok =
  bounded_vector(elements_ok, elements, 8192)
if price_array_ok then
  for index = 1, #price_rows do
    local entry = price_rows[index]
    local next_index = integer(F(entry, "next"))
    if next_index == nil then next_index = integer(F(entry, "Next")) end
    if next_index ~= nil and next_index >= -1 then
      local value = F(entry, "value")
      if value == nil then value = F(entry, "Value") end
      local fake_id, price = integer(F(value, "_FakeItemId")), integer(F(value, "_FakePrice"))
      if fake_id ~= nil and fake_id > 0 and price ~= nil and price > 0 then
        price_count = price_count + 1
        min_price = min_price == nil and price or math.min(min_price, price)
        max_price = max_price == nil and price or math.max(max_price, price)
        prices[price] = true
      end
    end
  end
end

local below, above = 0, 0
if golden ~= nil then
  for price in pairs(prices) do
    if price <= golden then below = below + 1 else above = above + 1 end
  end
end
L(string.format(
  "forgery money golden_ok=%s golden_readable=%s talk_gold_readable=%s talk_spend_readable=%s price_array_ok=%s price_array_count=%s price_array_capped=%s prices=%d min=%s max=%s affordable_price_points=%d unaffordable_price_points=%d",
  tostring(golden_ok), tostring(golden ~= nil), tostring(talk_gold ~= nil),
  tostring(talk_spend ~= nil), tostring(price_array_ok),
  tostring(price_array_count), tostring(price_array_capped), price_count,
  tostring(min_price), tostring(max_price), below, above))
return golden ~= nil and "gold_candidate_read" or "gold_candidate_unreadable"
