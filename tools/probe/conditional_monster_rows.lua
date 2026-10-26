-- Counts-only current-save check for the conditional monster row gates.
-- Run through tools/probe/run.py after Reset Scripts; never prints positions.
local D = _G.QNML_DEBUG
assert(type(D) == "table" and type(D.state) == "function", "QNML_DEBUG.state unavailable")
local wt
for i = 1, 64 do
  local name, value = debug.getupvalue(D.state, i)
  if name == nil then break end
  if name == "wt" then wt = value; break end
end
assert(type(wt) == "table" and type(wt.q) == "function", "world tracker upvalue unavailable")

-- Pass temporary toggles directly; no setting is changed or saved.
wt.q("poke", false)
local ok = wt.q("refresh", false, os.clock(), true,
  { monsters = true, small_monsters = true }, false)
assert(ok == true, "world round did not run")
local stats = wt.q("stats", nil)
local gates = stats ~= nil and stats.gates or nil
assert(type(gates) == "table", "conditional gate stats unavailable")
local failures = gates.read_failures or {}
local normal, quest = gates.normal_source or {}, gates.quest_source or {}
local line = string.format(
  "Conditional rows: GameSeason4=%s normal=%d/%d quest=%d/%d read_failures=%d/%d/%d conditional_learned=%d",
  tostring(gates.season4), normal.eligible or 0, normal.total or 0,
  quest.eligible or 0, quest.total or 0, failures.season4 or 0,
  failures.quest or 0, failures.variable or 0, gates.conditional_learned or 0)
assert(not line:find("World row:", 1, true), "unexpected row dump")
assert(not line:match("%-?%d+%.?%d*[, ]+%-?%d+%.?%d*[, ]+%-?%d+%.?%d*"),
  "unexpected coordinate output")
if type(L) == "function" then L(line) end
return line
