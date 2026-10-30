package.path = "./reframework/autorun/?.lua;" .. package.path
local access = require("Clairvoyance.access")
local failures = 0
local function check(name, ok)
  if not ok then failures = failures + 1; print("FAIL: " .. name) end
end
local production_registry = access.registry
check("registry exposes additive gates and bindings", type(production_registry) == "table"
  and type(production_registry.gates) == "table" and type(production_registry.bindings) == "table")
check("registry validates", access.validate(production_registry) == true)
check("production fingerprints are data", #production_registry.gates == 2
  and #production_registry.bindings == 2)
local registry = {
  gates = {
    { id = "fixture_door", observer_family = "door_leaf", fingerprint = {
      bucket_id = 7, type_name = "app.TestDoor", game_object_name = "test_gate",
      position = { x = 1, y = 2, z = 3 }, tolerance = 0.25, leaf_count = 1 } },
    { id = "fixture_hint_door", observer_family = "door_leaf", fingerprint = {
      bucket_id = 8, type_name = "門", game_object_name = "test_hint_gate",
      position = { x = 4, y = 5, z = 6 }, tolerance = 0.5, leaf_count = 1 } },
  },
  bindings = {
    { target_kind = "placed_item", selector = { type_name = "fixture.item", item_id = 41,
      position = { x = 10, y = 20, z = 30 }, position_tolerance = 0.25 },
      gate_id = "fixture_door", predicate = { field = "locked", equals = false },
      unknown_policy = "deny", may_use_last_known = false },
    { target_kind = "hint_pin", selector = { quest_id = 77, pin_index = 2 },
      gate_id = "fixture_hint_door", predicate = { field = "closed", equals = true },
      unknown_policy = "allow", may_use_last_known = true },
  },
}

local function clone(t)
  if type(t) ~= "table" then return t end
  local out = {}; for k, v in pairs(t) do out[k] = clone(v) end; return out
end
local function valid(r) return access.validate(r) == true end
local malformed = clone(registry)
malformed.gates[1].fingerprint.position.x = 0 / 0
check("reject malformed fingerprint position", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.position.x = math.huge
check("reject non-finite fingerprint position", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.position.x = 0
malformed.gates[1].fingerprint.tolerance = 0
check("reject zero tolerance", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.tolerance = -1
check("reject negative tolerance", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.tolerance = math.huge
check("reject non-finite tolerance", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.tolerance = 0 / 0
check("reject NaN tolerance", not valid(malformed))
malformed = clone(registry); malformed.gates[1].id = malformed.gates[2].id
check("reject duplicate gate ids", not valid(malformed))
malformed = clone(registry); malformed.gates[1].id = "gate-\195\169"
check("reject non-ASCII gate ids", not valid(malformed))
malformed = clone(registry); malformed.gates[1].observer_family = "window"
check("reject unknown observer family", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.leaf_count = 2
check("reject door observers with an undefined multi-leaf aggregation", not valid(malformed))
malformed = clone(registry); malformed.gates[2].fingerprint =
  clone(malformed.gates[1].fingerprint)
check("reject duplicate complete gate fingerprints", not valid(malformed))
malformed = clone(registry); malformed.gates[2].fingerprint =
  clone(malformed.gates[1].fingerprint)
malformed.gates[2].fingerprint.bucket_id = 7.0
malformed.gates[2].fingerprint.position.x = 1.0
check("reject numerically equal fingerprints with different representations", not valid(malformed))
malformed = clone(registry); malformed.bindings[1].predicate = { field = "is_open", equals = true }
check("reject unknown predicate", not valid(malformed))
malformed = clone(registry); malformed.bindings[1].selector = {}
check("reject unbounded selectors", not valid(malformed))
malformed = clone(registry); malformed.bindings[1].selector.item_id = "all"
check("reject non-typed item selectors", not valid(malformed))
malformed = clone(registry); malformed.bindings[1].selector.position.x = 0 / 0
check("reject non-finite selector positions", not valid(malformed))
malformed = clone(registry); malformed.bindings[1].selector.position_tolerance = 0
check("reject non-positive selector tolerances", not valid(malformed))
malformed = clone(registry); malformed.gates[1] = nil
check("reject sparse gate arrays", not valid(malformed))
malformed = clone(registry); malformed.bindings[1] = nil
check("reject sparse binding arrays", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.type_name = "門"
check("accept exact multibyte fingerprint strings", valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.game_object_name = nil
check("reject fingerprints without a game-object name", not valid(malformed))
malformed = clone(registry); malformed.gates[1].fingerprint.game_object_name = ""
check("reject empty game-object names", not valid(malformed))
check("empty registry arrays are valid",
  valid({ gates = {}, bindings = {} }))

check("empty requested ids select no gates",
  #access.requested_gate_ids(registry, {}) == 0)
check("empty request against empty registry selects no gates",
  #access.requested_gate_ids({ gates = {}, bindings = {} }, {}) == 0)
local requests = access.requested_gate_ids(registry, { registry.bindings[1].gate_id })
check("requested gate selection is deduplicated and scoped",
  #requests == 1 and requests[1] == registry.bindings[1].gate_id)

local placed = { target_kind = "placed_item", type_name = "fixture.item", item_id = 41,
  position = { x = 10, y = 20, z = 30 } }
local hint = { target_kind = "hint_pin", quest_id = 77, pin_index = 3 }
local exact, reason = access.match_binding(registry, placed)
check("exact target binding matches", exact ~= nil and reason == nil)
local near = clone(placed); near.position.x = 10.25
check("inclusive selector tolerance matches", access.match_binding(registry, near) ~= nil)
local elsewhere = clone(placed); elsewhere.position.x = 10.2501
check("same type and item elsewhere does not bind", access.match_binding(registry, elsewhere) == nil)
local ambiguous_registry = clone(registry)
ambiguous_registry.bindings[2].target_kind = "placed_item"
ambiguous_registry.bindings[2].selector = clone(ambiguous_registry.bindings[1].selector)
local ambiguous = access.match_binding(ambiguous_registry, placed)
check("ambiguous target bindings fail closed", ambiguous == nil)
check("registry validation rejects ambiguous target selectors", not valid(ambiguous_registry))
ambiguous_registry = clone(registry)
ambiguous_registry.bindings[2].target_kind = "placed_item"
ambiguous_registry.bindings[2].selector = clone(ambiguous_registry.bindings[1].selector)
ambiguous_registry.bindings[2].selector.item_id = 41.0
ambiguous_registry.bindings[2].selector.position.x = 10.0
check("registry rejects numerically equal selectors with different representations",
  not valid(ambiguous_registry))
check("non-matching typed target does not bind", access.match_binding(registry, hint) == nil)

local source_binding = registry.bindings[1]
local hint_binding = registry.bindings[2]
local function observation(values) return { status = "known", values = values } end
local unknown = { status = "unknown" }
local function eval(binding, current, last)
  return access.evaluate(binding, current, last)
end
check("door closed and unlocked passes source predicate",
  eval(source_binding, observation({ closed = true, locked = false }), unknown) == true)
check("door open and unlocked passes source predicate",
  eval(source_binding, observation({ closed = false, locked = false }), unknown) == true)
check("door closed and locked blocks source predicate",
  eval(source_binding, observation({ closed = true, locked = true }), unknown) == false)
check("unknown source gate fails closed", eval(source_binding, unknown, unknown) == false)
check("closed hint gate preserves pin", eval(hint_binding,
  observation({ closed = true }), unknown) == true)
check("open hint gate filters pin", eval(hint_binding,
  observation({ closed = false }), unknown) == false)
check("unknown hint gate uses allowed last-known state", eval(hint_binding, unknown,
  observation({ closed = true })) == true)
check("unknown hint gate uses a last-known open state to hide", eval(hint_binding, unknown,
  observation({ closed = false })) == false)
check("current hint state overrides contradictory history", eval(hint_binding,
  observation({ closed = true }), observation({ closed = false })) == true)
check("unknown hint gate preserves when no last-known state", eval(hint_binding,
  unknown, unknown) == true)
check("incomplete predicate observation is unknown", eval(source_binding,
  observation({ closed = true }), unknown) == false)
check("source gate never accepts stale unlocked history", eval(source_binding, unknown,
  observation({ locked = false })) == false)

if failures > 0 then error(tostring(failures) .. " access tests failed") end
print("access_test: all OK")
