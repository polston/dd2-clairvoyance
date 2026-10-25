-- Developer-only in-game probe harness (never in the release zip). Copy it to
-- the game's reframework/autorun/ and press Reset Scripts. See the
-- clairvoyance-workflow skill, Part 1.
-- Every 5 s logs QNML_DEBUG.state() as CHK lines; every 30 frames runs any
-- Lua chunk written to reframework/data/qnml_cmd.txt with D = QNML_DEBUG.
local function L(s) log.info("CHK " .. s) end
local f, last_dump = 0, 0
local announced = false
local boot_done = false
local function dump()
  local D = _G.QNML_DEBUG
  if D == nil then L("QNML_DEBUG nil true"); return end
  local ok, st = pcall(D.state)
  if not ok then L("state error " .. tostring(st)); return end
  L(string.format("setup_icon_n %s map_ctor_n %s tracked %s",
    tostring(st.setup_icon_n), tostring(st.map_ctor_n), tostring(st.tracked_qid)))
  for _, l in ipairs(st.lines or {}) do L("| " .. l) end
  for _, j in ipairs(st.jumps or {}) do L("jump " .. j) end
end
re.on_frame(function()
  f = f + 1
  if not announced and _G.QNML_DEBUG ~= nil then announced = true; L("ready") end
  if f % 30 == 0 then
    local name = boot_done and "qnml_cmd.txt" or "qnml_boot.txt"
    if f < 120 then return end
    boot_done = true
    local ok, v = pcall(fs.read, name)
    if ok and v ~= nil and v ~= "" then
      pcall(fs.write, name, "")
      local env = setmetatable({ D = _G.QNML_DEBUG, L = L, dump = dump }, { __index = _G })
      local fn, err = load(v, "qnml_cmd", "t", env)
      local ok2, e2 = false, err
      if fn ~= nil then ok2, e2 = pcall(fn) end
      L("cmd ok=" .. tostring(ok2) .. " " .. tostring(e2))
    end
  end
  if os.clock() - last_dump >= 5.0 then last_dump = os.clock(); dump() end
end)
