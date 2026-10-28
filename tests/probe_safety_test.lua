-- The installed probe harness must reject unsafe source before load(), for
-- both the one-shot boot file and later command file.
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

local function run_case(boot, command, frames)
  local lines, callback = {}, nil
  re = { on_frame = function(fn) callback = fn end }
  log = { info = function(line) lines[#lines + 1] = line end }
  QNML_DEBUG = nil
  fs = {
    read = function(name)
      if name == "qnml_boot.txt" then return boot end
      if name == "qnml_cmd.txt" then return command end
      return ""
    end,
    write = function() end,
  }
  dofile("tools/probe/qnml_check.lua")
  for _ = 1, frames do callback() end
  return table.concat(lines, "\n")
end

local unsafe_boot = run_case('return sdk["create_resource"]("x")', "", 120)
check("unsafe bracket boot rejected",
  unsafe_boot:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unsafe_long_string = run_case('return sdk[ [=[create_resource]=] ]("x")', "", 120)
check("unsafe long-string member rejected",
  unsafe_long_string:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unsafe_long_newline = run_case([==[return sdk[ [=[
create_resource]=] ]("x")]==], "", 120)
check("unsafe long-string initial newline rejected",
  unsafe_long_newline:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unsafe_parenthesized_bracket = run_case('return (sdk)["create_resource"]("x")', "", 120)
check("unsafe parenthesized sdk bracket rejected",
  unsafe_parenthesized_bracket:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unsafe_parenthesized = run_case('return (sdk).create_resource("x")', "", 120)
check("unsafe parenthesized sdk rejected",
  unsafe_parenthesized:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unsafe_command = run_case("", 'local o = {}; return o["release"](o)', 150)
check("unsafe bracket command rejected",
  unsafe_command:find("cmd ok=false unsafe probe call: release", 1, true) ~= nil)

local unsafe_escaped = run_case("", 'local o = {}; return o["re\\108ease"](o)', 150)
check("unsafe escaped member rejected",
  unsafe_escaped:find("cmd ok=false unsafe probe call: release", 1, true) ~= nil)

local unsafe_setter_call = run_case("", 'local o = {}; return o:call("set_Enabled", false)', 150)
check("managed setter call rejected",
  unsafe_setter_call:find("cmd ok=false unsafe probe call: set_Enabled", 1, true) ~= nil)

local unsafe_bracket_setter_call = run_case("", 'local o = {}; return o["call"](o, "set_Value", 1)', 150)
check("bracket managed setter call rejected",
  unsafe_bracket_setter_call:find("cmd ok=false unsafe probe call: set_Value", 1, true) ~= nil)

local unsafe_dynamic_sdk = run_case('', 'return sdk["create_" .. "resource"]("x")', 150)
check("dynamic sdk member rejected",
  unsafe_dynamic_sdk:find("cmd ok=false unsafe probe call: dynamic sdk access", 1, true) ~= nil)

local unsafe_sdk_alias = run_case('', 'local s = sdk; return s.create_resource("x")', 150)
check("sdk alias rejected",
  unsafe_sdk_alias:find("cmd ok=false unsafe probe call: indirect sdk access", 1, true) ~= nil)

local unsafe_call_alias = run_case('', 'local f = o.call; return f(o, "set_Enabled", false)', 150)
check("managed call alias rejected",
  unsafe_call_alias:find("cmd ok=false unsafe probe call: indirect managed call", 1, true) ~= nil)

local unsafe_dynamic_method = run_case('',
  'local method = "set_Enabled"; return o:call(method, false)', 150)
check("dynamic managed method rejected",
  unsafe_dynamic_method:find("cmd ok=false unsafe probe call: dynamic managed method", 1, true) ~= nil)

local unsafe_bracket_dynamic_method = run_case('',
  'local method = "set_Enabled"; return o["call"](o, method, false)', 150)
check("bracket dynamic managed method rejected",
  unsafe_bracket_dynamic_method:find("cmd ok=false unsafe probe call: dynamic managed method", 1, true) ~= nil)

local unsafe_raw_managed_call = run_case('',
  'return o:call("Dispose")', 150)
check("unreviewed direct managed call rejected",
  unsafe_raw_managed_call:find("cmd ok=false unsafe probe call: raw managed call", 1, true) ~= nil)

local unsafe_raw_reviewed_call = run_case('',
  'return o:call("get_Count")', 150)
check("reviewed method still requires the reviewed capability",
  unsafe_raw_reviewed_call:find("cmd ok=false unsafe probe call: raw managed call", 1, true) ~= nil)

local unsafe_computed_call_alias = run_case('', [[
local f = o["ca" .. "ll"]
return f(o, "set_Enabled", false)
]], 150)
check("computed managed call alias rejected",
  unsafe_computed_call_alias:find("cmd ok=false unsafe probe call: indirect managed call", 1, true) ~= nil)

local unsafe_dynamic_call = run_case('', 'return o[method](o)', 150)
check("dynamic member call rejected",
  unsafe_dynamic_call:find("cmd ok=false unsafe probe call: dynamic member call", 1, true) ~= nil)

local unsafe_nested_load = run_case('', 'return load("return sdk.create_resource(\\"x\\")")()', 150)
check("secondary load rejected before execution",
  unsafe_nested_load:find("cmd ok=false unsafe probe call: load", 1, true) ~= nil)

local unsafe_global_lookup = run_case('', 'return rawget(_G, "sdk").create_resource("x")', 150)
check("indirect global sdk lookup rejected",
  unsafe_global_lookup:find("cmd ok=false unsafe probe call: indirect global access", 1, true) ~= nil)

sdk = {
  get_managed_singleton = function() return nil end,
  find_type_definition = function() return nil end,
}
local reviewed_reads = run_case([[
local D = _G.QNML_DEBUG
local qlm = sdk.get_managed_singleton("app.QuestLogManager")
local td = sdk.find_type_definition("app.QuestLogManager")
local ok = pcall(require, "Clairvoyance.world")
return "safe"
]], "", 120)
sdk = nil
check("reviewed read-only globals allowed",
  reviewed_reads:find("cmd ok=true safe", 1, true) ~= nil)

local reviewed_call_ok = run_case('', [[
local o = { call = function(_, name) return name end }
return reviewed_call(o, "get_Count")
]], 150)
check("reviewed managed call capability allows its fixed read set",
  reviewed_call_ok:find("cmd ok=true get_Count", 1, true) ~= nil)

local reviewed_try_ok = run_case('', [[
local o = { call = function(_, name) return name end }
local ok, value = reviewed_try_call(o, "get_Count")
return tostring(ok) .. ":" .. tostring(value)
]], 150)
check("reviewed managed try-call capability allows its fixed read set",
  reviewed_try_ok:find("cmd ok=true true:get_Count", 1, true) ~= nil)

local reviewed_call_nil = run_case('', [[
return tostring(reviewed_call(nil, "get_Count"))
]], 150)
check("reviewed managed call preserves nil receiver tolerance",
  reviewed_call_nil:find("cmd ok=true nil", 1, true) ~= nil)

local reviewed_call_error = run_case('', [[
local o = { call = function() error("boom") end }
return tostring(reviewed_call(o, "get_Count"))
]], 150)
check("reviewed managed call preserves managed exception tolerance",
  reviewed_call_error:find("cmd ok=true nil", 1, true) ~= nil)

local reviewed_try_nil = run_case('', [[
local ok, value = reviewed_try_call(nil, "get_Count")
return tostring(ok) .. ":" .. tostring(value)
]], 150)
check("reviewed managed try-call reports nil receiver failure",
  reviewed_try_nil:find("cmd ok=true false:nil", 1, true) ~= nil)

local reviewed_try_error = run_case('', [[
local o = { call = function() error("boom") end }
local ok, value = reviewed_try_call(o, "get_Count")
return tostring(ok) .. ":" .. tostring(value)
]], 150)
check("reviewed managed try-call reports managed exception failure",
  reviewed_try_error:find("cmd ok=true false:nil", 1, true) ~= nil)

local reviewed_call_bad = run_case('', [[
local o = { call = function() return "mutated" end }
return reviewed_call(o, "set_Enabled", false)
]], 150)
check("reviewed managed call capability rejects setters before load",
  reviewed_call_bad:find("cmd ok=false unsafe probe call: unreviewed managed method", 1, true) ~= nil)

local reviewed_call_dynamic = run_case('', [[
local method = "get_Count"
return reviewed_call({}, method)
]], 150)
check("reviewed managed call capability rejects dynamic names before load",
  reviewed_call_dynamic:find("cmd ok=false unsafe probe call: unreviewed managed method", 1, true) ~= nil)

local reviewed_call_alias = run_case('', [[
local f = reviewed_call
return f({}, "get_Count")
]], 150)
check("reviewed managed call capability rejects aliases before load",
  reviewed_call_alias:find("cmd ok=false unsafe probe call: indirect reviewed call", 1, true) ~= nil)

local reviewed_invoke_ok = run_case('', [[
local method = {
  get_name = function() return "getContext" end,
  call = function(_, receiver) return receiver.value end,
}
return reviewed_invoke(method, { value = "safe" }, "getContext")
]], 150)
check("reviewed method-definition capability validates the reflected name",
  reviewed_invoke_ok:find("cmd ok=true safe", 1, true) ~= nil)

local reviewed_invoke_bad = run_case('', [[
local method = {
  get_name = function() return "set_Enabled" end,
  call = function() return "mutated" end,
}
return reviewed_invoke(method, {}, "getContext")
]], 150)
check("reviewed method-definition capability rejects a mismatched method",
  reviewed_invoke_bad:find("cmd ok=false", 1, true) ~= nil
    and reviewed_invoke_bad:find("reviewed method mismatch", 1, true) ~= nil)

local phase0_file = assert(io.open("tools/probe/objective_phase0.lua", "r"))
local phase0_source = phase0_file:read("*a")
phase0_file:close()
local phase0_guard = run_case(phase0_source, "", 120)
check("reviewed phase0 source passes the installed guard",
  phase0_guard:find("unsafe probe call:", 1, true) == nil)

local comment_gap = run_case('return--[[ gap ]]sdk.create_resource("x")', "", 120)
check("comment boundary preserved",
  comment_gap:find("cmd ok=false unsafe probe call: sdk.create_resource", 1, true) ~= nil)

local unrelated = run_case([[
local fake_sdk = { create_resource = function() return "safe" end }
return fake_sdk.create_resource()
]], "", 120)
check("unrelated identifier allowed", unrelated:find("cmd ok=true safe", 1, true) ~= nil)

local harmless = run_case("-- o:release()\nreturn 'safe'", "", 120)
check("comment ignored", harmless:find("cmd ok=true safe", 1, true) ~= nil)

if failures > 0 then os.exit(1) end
print("probe_safety_test: all OK")
