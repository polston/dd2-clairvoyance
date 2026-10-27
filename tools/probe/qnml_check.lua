-- Developer-only in-game probe harness (never in the release zip). Copy it to
-- the game's reframework/autorun/ and press Reset Scripts. See the
-- clairvoyance-workflow skill, Part 1.
-- Every 5 s logs QNML_DEBUG.state() as CHK lines, each prefixed "~ " so run.py
-- can tell them from a chunk's own output (a chunk's dump() has no prefix); every 30 frames runs any
-- Lua chunk written to reframework/data/qnml_cmd.txt with D = QNML_DEBUG.
local function L(s) log.info("CHK " .. s) end
local function long_bracket(s, i)
  if s:sub(i, i) ~= "[" then return nil end
  local j = i + 1
  while s:sub(j, j) == "=" do j = j + 1 end
  if s:sub(j, j) ~= "[" then return nil end
  return j + 1, "]" .. s:sub(i + 1, j - 1) .. "]"
end
local function short_string(s, i)
  local quote, out, n = s:sub(i, i), {}, #s
  local simple = {
    a = "\a", b = "\b", f = "\f", n = "\n", r = "\r",
    t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
  }
  i = i + 1
  while i <= n do
    local ch = s:sub(i, i)
    if ch == "\\" and i < n then
      local escaped = s:sub(i + 1, i + 1)
      if escaped:match("%d") then
        local j = i + 1
        while j <= n and j < i + 4 and s:sub(j, j):match("%d") do j = j + 1 end
        local code = tonumber(s:sub(i + 1, j - 1), 10)
        out[#out + 1] = code <= 255 and string.char(code) or ""
        i = j
      elseif escaped == "x" and s:sub(i + 2, i + 3):match("^%x%x$") then
        out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16))
        i = i + 4
      elseif escaped == "z" then
        i = i + 2
        while i <= n and s:sub(i, i):match("%s") do i = i + 1 end
      else
        out[#out + 1] = simple[escaped] or escaped
        i = i + 2
      end
    elseif ch == quote then
      return table.concat(out), i + 1
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out), i
end
local function lua_tokens(s)
  local tokens, i, n = {}, 1, #s
  while i <= n do
    if s:sub(i, i + 1) == "--" then
      local start, close = long_bracket(s, i + 2)
      if start ~= nil then
        local _, e = s:find(close, start, true)
        i = e == nil and n + 1 or e + 1
      else
        local e = s:find("\n", i + 2, true)
        i = e == nil and n + 1 or e + 1
      end
    else
      local ch = s:sub(i, i)
      if ch:match("%s") then
        i = i + 1
      elseif ch == "'" or ch == '"' then
        local value
        value, i = short_string(s, i)
        tokens[#tokens + 1] = { kind = "string", value = value }
      else
        local start, close = long_bracket(s, i)
        if start ~= nil then
          local _, e = s:find(close, start, true)
          local value = e == nil and s:sub(start) or s:sub(start, e - #close)
          if value:sub(1, 2) == "\r\n" or value:sub(1, 2) == "\n\r" then
            value = value:sub(3)
          elseif value:sub(1, 1) == "\r" or value:sub(1, 1) == "\n" then
            value = value:sub(2)
          end
          tokens[#tokens + 1] = { kind = "string", value = value }
          i = e == nil and n + 1 or e + 1
        elseif ch:match("[%a_]") then
          local j = i + 1
          while j <= n and s:sub(j, j):match("[%w_]") do j = j + 1 end
          tokens[#tokens + 1] = s:sub(i, j - 1)
          i = j
        else
          tokens[#tokens + 1] = ch
          i = i + 1
        end
      end
    end
  end
  return tokens
end
local unsafe_methods = {
  create_instance = true,
  set_field = true,
  add_ref = true,
  release = true,
}
local function receiver_token(token)
  return token == ")" or token == "]" or
    (type(token) == "string" and token:match("^[%a_][%w_]*$") ~= nil)
end
local function matching_close(tokens, start, opening, closing)
  local depth = 0
  for i = start, #tokens do
    if tokens[i] == opening then depth = depth + 1
    elseif tokens[i] == closing then
      depth = depth - 1
      if depth == 0 then return i end
    end
  end
  return nil
end
local function sdk_expression(tokens, start, finish)
  if start > finish then return false end
  if start == finish then return tokens[start] == "sdk" end
  if tokens[start] == "(" and matching_close(tokens, start, "(", ")") == finish then
    return sdk_expression(tokens, start + 1, finish - 1)
  end
  return false
end
local function sdk_receiver(tokens, finish)
  if finish < 1 then return false end
  if tokens[finish] == "sdk" then return true end
  if tokens[finish] ~= ")" then return false end
  local depth = 1
  for i = finish - 1, 1, -1 do
    if tokens[i] == ")" then depth = depth + 1
    elseif tokens[i] == "(" then
      depth = depth - 1
      if depth == 0 then return sdk_expression(tokens, i, finish) end
    end
  end
  return false
end
local function setter_argument(tokens, opening)
  local closing = matching_close(tokens, opening, "(", ")")
  if closing == nil then return nil end
  for i = opening + 1, closing - 1 do
    local token = tokens[i]
    if type(token) == "table" and token.kind == "string" and
        token.value:match("^set_") then
      return token.value
    end
  end
  return nil
end
local function unsafe_probe_call(source)
  local tokens = lua_tokens(source)
  for i, token in ipairs(tokens) do
    if token == "." and tokens[i + 1] == "create_resource" and
        sdk_receiver(tokens, i - 1) then
      return "sdk.create_resource"
    end
    if (token == "." or token == ":") and unsafe_methods[tokens[i + 1]] then
      return tokens[i + 1]
    end
    if (token == "." or token == ":") and tokens[i + 1] == "call" and
        tokens[i + 2] == "(" then
      local setter = setter_argument(tokens, i + 2)
      if setter ~= nil then return setter end
    end
    local member = tokens[i + 1]
    if token == "[" and i > 1 and type(member) == "table" and
        member.kind == "string" and tokens[i + 2] == "]" and
        receiver_token(tokens[i - 1]) then
      if sdk_receiver(tokens, i - 1) and member.value == "create_resource" then
        return "sdk.create_resource"
      end
      if unsafe_methods[member.value] then return member.value end
      if member.value == "call" and tokens[i + 3] == "(" then
        local setter = setter_argument(tokens, i + 3)
        if setter ~= nil then return setter end
      end
    end
  end
  return nil
end
local f, last_dump = 0, 0
local announced = false
local boot_done = false
local function dump(pre)
  pre = pre or ""
  local D = _G.QNML_DEBUG
  if D == nil then L("QNML_DEBUG nil true"); return end
  local ok, st = pcall(D.state)
  if not ok then L("state error " .. tostring(st)); return end
  L(string.format(pre .. "setup_icon_n %s map_ctor_n %s tracked %s",
    tostring(st.setup_icon_n), tostring(st.map_ctor_n), tostring(st.tracked_qid)))
  for _, l in ipairs(st.lines or {}) do L(pre .. "| " .. l) end
  for _, j in ipairs(st.jumps or {}) do L(pre .. "jump " .. j) end
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
      local unsafe = unsafe_probe_call(v)
      if unsafe ~= nil then
        L("cmd ok=false unsafe probe call: " .. unsafe)
      else
        local env = setmetatable({ D = _G.QNML_DEBUG, L = L, dump = function() dump("") end }, { __index = _G })
        local fn, err = load(v, "qnml_cmd", "t", env)
        local ok2, e2 = false, err
        if fn ~= nil then ok2, e2 = pcall(fn) end
        L("cmd ok=" .. tostring(ok2) .. " " .. tostring(e2))
      end
    end
  end
  if os.clock() - last_dump >= 5.0 then last_dump = os.clock(); dump("~ ") end
end)
