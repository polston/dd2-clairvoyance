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
