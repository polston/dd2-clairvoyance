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
local elements_ok, elements = pcall(function() return entries:get_elements() end)
if elements_ok and type(elements) == "table" then
  for index = 1, math.min(#elements, 8192) do
    local entry = elements[index]
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
  "forgery money golden_ok=%s golden=%s talk_gold=%s talk_spend=%s prices=%d min=%s max=%s affordable_controls=%d unaffordable_controls=%d",
  tostring(golden_ok), tostring(golden), tostring(talk_gold), tostring(talk_spend),
  price_count, tostring(min_price), tostring(max_price), below, above))
return golden ~= nil and "gold_candidate_read" or "gold_candidate_unreadable"
