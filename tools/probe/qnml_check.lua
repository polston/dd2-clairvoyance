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
local safe_sdk_methods = {
  find_type_definition = true,
  get_managed_singleton = true,
}
local secondary_loaders = { load = true, loadfile = true, dofile = true }
local allowed_require = { ["Clairvoyance.world"] = true }
-- TalkEventManager signatures verified in the local il2cpp dump:
-- initial speaker, playable and history take TalkEventDefine.ID; interaction
-- takes app.Character. These names remain exact read-only capabilities.
local reviewed_methods
local reviewed_capabilities = {
  reviewed_call = 2,
  reviewed_try_call = 2,
  reviewed_invoke = 3,
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
local function call_arguments(tokens, opening)
  local closing = matching_close(tokens, opening, "(", ")")
  if closing == nil then return nil end
  local args, start = {}, opening + 1
  local round, square, brace = 0, 0, 0
  for i = start, closing - 1 do
    local token = tokens[i]
    if token == "(" then round = round + 1
    elseif token == ")" then round = round - 1
    elseif token == "[" then square = square + 1
    elseif token == "]" then square = square - 1
    elseif token == "{" then brace = brace + 1
    elseif token == "}" then brace = brace - 1
    elseif token == "," and round == 0 and square == 0 and brace == 0 then
      local arg = {}
      for j = start, i - 1 do arg[#arg + 1] = tokens[j] end
      args[#args + 1], start = arg, i + 1
    end
  end
  if start < closing then
    local arg = {}
    for i = start, closing - 1 do arg[#arg + 1] = tokens[i] end
    args[#args + 1] = arg
  end
  return args
end
local function managed_method_argument(tokens, opening, colon)
  local args = call_arguments(tokens, opening)
  local index = colon and 1 or 2
  if args == nil or args[index] == nil then return false, nil end
  local arg = args[index]
  if #arg == 1 and type(arg[1]) == "table" and arg[1].kind == "string" then
    return true, arg[1].value
  end
  return false, nil
end
local function unsafe_probe_call(source)
  local tokens = lua_tokens(source)
  -- Preserve the specific diagnostics for direct unsafe calls.
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
      local literal, method = managed_method_argument(tokens, i + 2, token == ":")
      if not literal then return "dynamic managed method" end
      if unsafe_methods[method] or method:match("^set_") then return method end
      local setter = setter_argument(tokens, i + 2)
      if setter ~= nil then return setter end
      return "raw managed call"
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
        local literal, method = managed_method_argument(tokens, i + 3, false)
        if not literal then return "dynamic managed method" end
        if unsafe_methods[method] or method:match("^set_") then return method end
        local setter = setter_argument(tokens, i + 3)
        if setter ~= nil then return setter end
        return "raw managed call"
      end
    end
  end

  -- Fail closed around syntax that can hide a later engine call. Read-only
  -- probes use direct, reviewed SDK members; aliases, computed member calls
  -- and secondary code loading are rejected before load().
  local member_aliases = {}
  for i, token in ipairs(tokens) do
    local lhs = tokens[i - 1]
    if token == "=" and type(lhs) == "string" and lhs:match("^[%a_][%w_]*$")
        and receiver_token(tokens[i + 1]) and tokens[i + 2] == "[" then
      local close = matching_close(tokens, i + 2, "[", "]")
      if close ~= nil then member_aliases[lhs] = true end
    end
  end
  for i, token in ipairs(tokens) do
    if member_aliases[token] and tokens[i + 1] == "(" then
      return "indirect managed call"
    end
    local method_index = reviewed_capabilities[token]
    if method_index ~= nil then
      if tokens[i - 1] == "." or tokens[i - 1] == ":" or tokens[i + 1] ~= "(" then
        return "indirect reviewed call"
      end
      local args = call_arguments(tokens, i + 1)
      local method = args and args[method_index] or nil
      local literal = method ~= nil and #method == 1 and type(method[1]) == "table"
        and method[1].kind == "string"
      if not literal or reviewed_methods[method[1].value] ~= true then
        return "unreviewed managed method"
      end
    end
    if secondary_loaders[token] then return token end
    if token == "require" then
      local arg = tokens[i + 2]
      local direct = tokens[i + 1] == "(" and type(arg) == "table" and
        arg.kind == "string" and allowed_require[arg.value] and tokens[i + 3] == ")"
      local protected = i > 2 and tokens[i - 2] == "pcall" and tokens[i - 1] == "(" and
        tokens[i + 1] == "," and type(arg) == "table" and arg.kind == "string" and
        allowed_require[arg.value]
      if not direct and not protected then return "require" end
    end
    if token == "_G" or token == "_ENV" then
      local reviewed_debug = token == "_G" and tokens[i + 1] == "." and
        tokens[i + 2] == "QNML_DEBUG"
      if not reviewed_debug then return "indirect global access" end
    end
    if token == "sdk" then
      local direct = tokens[i + 1] == "." and safe_sdk_methods[tokens[i + 2]] == true
      if not direct then
        if tokens[i + 1] == "[" then return "dynamic sdk access" end
        return "indirect sdk access"
      end
    end
    if (token == "." or token == ":") and tokens[i + 1] == "call" and
        tokens[i + 2] ~= "(" then
      return "indirect managed call"
    end
    if token == "[" then
      local close = matching_close(tokens, i, "[", "]")
      if close == nil then return "dynamic member call" end
      local member = tokens[i + 1]
      local literal = close == i + 2 and type(member) == "table" and member.kind == "string"
      if tokens[close + 1] == "(" and not literal then return "dynamic member call" end
      if literal and member.value == "call" and tokens[close + 1] ~= "(" then
        return "indirect managed call"
      end
    end
  end
  return nil
end
reviewed_methods = {
  ["IsRelease"] = true,
  ["ToString()"] = true,
  ["evaluate"] = true,
  ["evaluateHide"] = true,
  ["evaluateRegisterCondition"] = true,
  ["evaluateShow"] = true,
  ["evaluateUpdateShow"] = true,
  ["getActiveDestinations"] = true,
  ["getCurrentTask"] = true,
  ["getCurrentTaskConciergeData"] = true,
  ["getItemNumber"] = true,
  ["getItemShopTotalPay"] = true,
  ["getItemStockNum"] = true,
  ["getNPCCharacterData"] = true,
  ["getProgressingQuestIds"] = true,
  ["getRegisterableDestinations"] = true,
  ["getStorageDict"] = true,
  ["get_AIBlackBoardController"] = true,
  ["get_Area"] = true,
  ["get_Canceled"] = true,
  ["get_CanceledAction"] = true,
  ["get_CharaID"] = true,
  ["get_CompContext"] = true,
  ["get_Count"] = true,
  ["get_CurrentTaskIndex"] = true,
  ["getHistory"] = true,
  ["get_Data"] = true,
  ["get_DataList"] = true,
  ["get_DeliverData"] = true,
  ["get_DeliveryCheckStorage"] = true,
  ["get_DeliveryGroupID"] = true,
  ["get_DeliveryIsNot"] = true,
  ["get_Destinations"] = true,
  ["get_DestType"] = true,
  ["get_DoneAction"] = true,
  ["get_ErrorStatus"] = true,
  ["get_Executed"] = true,
  ["get_FakeShopCompleteTime"] = true,
  ["get_FakeShopKeepedItem"] = true,
  ["get_GimmickID"] = true,
  ["get_GmContext"] = true,
  ["get_IsAllItem"] = true,
  ["get_IsFinish"] = true,
  ["get_IsDead"] = true,
  ["get_IsOpenedFreeBit"] = true,
  ["get_IsRemove"] = true,
  ["get_IsStock"] = true,
  ["get_IsUnlockFreeBit"] = true,
  ["get_Item"] = true,
  ["getContext"] = true,
  ["get_ItemList"] = true,
  ["get_Key"] = true,
  ["get_KeyLocation"] = true,
  ["get_LocalArea"] = true,
  ["get_Operator"] = true,
  ["get_Process"] = true,
  ["get_QuestID"] = true,
  ["get_SetNpc"] = true,
  ["get_Stock"] = true,
  ["get_TaskIndex"] = true,
  ["get_Transform"] = true,
  ["get_UniqId"] = true,
  ["get_UniversalPosition"] = true,
  ["get_Value"] = true,
  ["getTalkEventInitialSpeaker"] = true,
  ["hasDeliver"] = true,
  ["isFakeShopCompleted"] = true,
  ["isFakeShopKeeped"] = true,
  ["isFakeShopRemainingMinute"] = true,
  ["isEventPlayable"] = true,
  ["isFinish"] = true,
  ["canTalkEventInteract"] = true,
  ["isShopTalkEventAvailableForChara"] = true,
  ["isTalkEventInteractDisabled"] = true,
}
local function reviewed_call_result(o, name, ...)
  if reviewed_methods[name] ~= true then
    error("unreviewed managed method: " .. tostring(name))
  end
  if o == nil then return false, nil end
  local args = { ... }
  local ok, a, b, c = pcall(function()
    return o:call(name, table.unpack(args))
  end)
  if ok then return true, a, b, c end
  return false, nil
end
local function reviewed_call(o, name, ...)
  local ok, a, b, c = reviewed_call_result(o, name, ...)
  if ok then return a, b, c end
  return nil
end
local function reviewed_try_call(o, name, ...)
  return reviewed_call_result(o, name, ...)
end
local function reviewed_invoke(method, receiver, name)
  if method == nil or reviewed_methods[name] ~= true then
    error("unreviewed managed method: " .. tostring(name))
  end
  local ok, actual = pcall(function() return method:get_name() end)
  if not ok or actual ~= name then
    error("reviewed method mismatch: " .. tostring(actual))
  end
  return method:call(receiver)
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
        local env = setmetatable({ D = _G.QNML_DEBUG, L = L,
          dump = function() dump("") end, reviewed_call = reviewed_call,
          reviewed_try_call = reviewed_try_call, reviewed_invoke = reviewed_invoke },
          { __index = _G })
        local fn, err = load(v, "qnml_cmd", "t", env)
        local ok2, e2 = false, err
        if fn ~= nil then ok2, e2 = pcall(fn) end
        L("cmd ok=" .. tostring(ok2) .. " " .. tostring(e2))
      end
    end
  end
  if os.clock() - last_dump >= 5.0 then last_dump = os.clock(); dump("~ ") end
end)
