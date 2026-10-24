-- tests/settings_test.lua
package.path = "./reframework/autorun/?.lua;" .. package.path
local su = require("Clairvoyance.settings_util")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
check("path: real modules first", package.path:sub(1, 28) == "./reframework/autorun/?.lua;")
local D = su.defaults()
check("defaults sane", D.enabled == true and type(D.icon_startable) == "number")

local v = su.validate(nil)
check("nil -> defaults", v.enabled == D.enabled and v.icon_startable == D.icon_startable)
v = su.validate({ enabled = "yes", icon_startable = 61, icon_color = -5, debug = 1 })
check("bad types/ranges -> per-field defaults",
  v.enabled == D.enabled and v.icon_startable == D.icon_startable
  and v.icon_color == D.icon_color and v.debug == D.debug)
v = su.validate({ enabled = false, icon_startable = 12, icon_color = 0xFF00FF00, debug = true })
check("valid kept", v.enabled == false and v.icon_startable == 12
  and v.icon_color == 0xFF00FF00 and v.debug == true)

-- per-category icons: defaults, choice-set membership, legacy keys dropped
local ICON_DEF = { icon_startable = 52, icon_in_progress = 52, icon_completed = 42,
  icon_unavailable = 30, icon_locked = 41, icon_quest_item = 35 }
for k, want in pairs(ICON_DEF) do
  check(k .. " default", D[k] == want)
  check(k .. " default is a choice", su.ICON_INDEX[D[k]] ~= nil)
  check(k .. " kept when a choice", su.validate({ [k] = 9 })[k] == 9)
  check(k .. " 46 accepted", su.validate({ [k] = 46 })[k] == 46)
  check(k .. " None rejected", su.validate({ [k] = 61 })[k] == want)
  check(k .. " float rejected", su.validate({ [k] = 9.5 })[k] == want)
  check(k .. " string rejected", su.validate({ [k] = "9" })[k] == want)
end
for _, t in ipairs({ 6, 7, 23, 55, 76, 77, 78, 79, 80 }) do
  check("other-mod icon type " .. t .. " not a choice", su.ICON_INDEX[t] == nil)
end
check("legacy icon_type dropped", su.validate({ icon_type = 2 }).icon_type == nil)
check("legacy minimap_icon_type dropped",
  su.validate({ minimap_icon_type = 30 }).minimap_icon_type == nil)
local seen, ok_lab = {}, #su.ICON_LABELS == #su.ICON_CHOICES
for i, c in ipairs(su.ICON_CHOICES) do
  if seen[c[1]] or su.ICON_INDEX[c[1]] ~= i then ok_lab = false end
  seen[c[1]] = true
end
check("icon choices unique, index and labels aligned", ok_lab)

-- v2 defaults
local d = su.validate(nil)
check("icon_color default gold", d.icon_color == 0xFFFFD34D)
check("show defaults", d.show_startable == true and d.show_in_progress == true
  and d.show_completed == false and d.show_unavailable == false
  and d.show_locked == false)
check("color defaults", d.color_in_progress == 0xFFFF9A3C
  and d.color_completed == 0xFF7FA88A and d.color_unavailable == 0xFF9A9A9A
  and d.color_locked == 0xFF7A88B0)

-- every toggle: wrong type -> default; stored true and false kept verbatim
for _, k in ipairs({ "show_startable", "show_in_progress", "show_completed",
  "show_unavailable", "show_locked" }) do
  check(k .. " wrong type -> default", su.validate({ [k] = "yes" })[k] == D[k])
  check(k .. " stored true kept", su.validate({ [k] = true })[k] == true)
  check(k .. " stored false kept", su.validate({ [k] = false })[k] == false)
end

-- every color: wrong type, negative, fractional, above range, valid kept
for _, k in ipairs({ "icon_color", "color_in_progress", "color_completed",
  "color_unavailable", "color_locked" }) do
  check(k .. " wrong type", su.validate({ [k] = "red" })[k] == D[k])
  check(k .. " negative", su.validate({ [k] = -5 })[k] == D[k])
  check(k .. " fractional", su.validate({ [k] = 1.5 })[k] == D[k])
  check(k .. " above range", su.validate({ [k] = 2^33 })[k] == D[k])
  check(k .. " valid kept", su.validate({ [k] = 0xFF010203 })[k] == 0xFF010203)
end
-- v3 overhead fields
check("show_overhead default", D.show_overhead == true)
check("show_overhead absent -> default", su.validate({}).show_overhead == true)
check("overhead_distance default", D.overhead_distance == 50.0)
check("show_overhead wrong type", su.validate({ show_overhead = "yes" }).show_overhead == true)
check("show_overhead stored false survives", su.validate({ show_overhead = false }).show_overhead == false)
check("overhead_distance string", su.validate({ overhead_distance = "far" }).overhead_distance == 50.0)
check("overhead_distance below range", su.validate({ overhead_distance = 9.9 }).overhead_distance == 50.0)
check("overhead_distance above range", su.validate({ overhead_distance = 200.1 }).overhead_distance == 50.0)
check("overhead_distance boundary 10 kept", su.validate({ overhead_distance = 10 }).overhead_distance == 10)
check("overhead_distance boundary 200 kept", su.validate({ overhead_distance = 200 }).overhead_distance == 200)
check("overhead_distance NaN", su.validate({ overhead_distance = 0/0 }).overhead_distance == 50.0)
check("overhead_distance inf", su.validate({ overhead_distance = math.huge }).overhead_distance == 50.0)
check("overhead_distance float kept", su.validate({ overhead_distance = 57.5 }).overhead_distance == 57.5)
check("overhead_distance absent -> default", su.validate({}).overhead_distance == 50.0)
-- v4 minimap field
check("show_minimap default", D.show_minimap == true)
check("show_minimap absent -> default", su.validate({}).show_minimap == true)
check("show_minimap wrong type", su.validate({ show_minimap = 1 }).show_minimap == true)
check("show_minimap stored false survives", su.validate({ show_minimap = false }).show_minimap == false)

-- reveal_gate_names (v6): default off; non-boolean coerces to false
check("reveal_gate_names default false", D.reveal_gate_names == false)
check("reveal_gate_names absent -> false", su.validate({}).reveal_gate_names == false)
check("reveal_gate_names string -> false", su.validate({ reveal_gate_names = "yes" }).reveal_gate_names == false)
check("reveal_gate_names number -> false", su.validate({ reveal_gate_names = 1 }).reveal_gate_names == false)
check("reveal_gate_names true kept", su.validate({ reveal_gate_names = true }).reveal_gate_names == true)

-- v8 quest-item fields (SPEC 15.5c)
check("show_quest_items default true", D.show_quest_items == true)
check("show_quest_items absent -> default", su.validate({}).show_quest_items == true)
check("show_quest_items stored false survives",
  su.validate({ show_quest_items = false }).show_quest_items == false)
check("show_quest_items wrong type -> default",
  su.validate({ show_quest_items = "no" }).show_quest_items == true)
check("color_quest_item default blue", D.color_quest_item == 0xFF4FC3F7)
check("color_quest_item absent -> default", su.validate({}).color_quest_item == 0xFF4FC3F7)
check("color_quest_item above range -> default",
  su.validate({ color_quest_item = 2^33 }).color_quest_item == 0xFF4FC3F7)
check("color_quest_item negative -> default",
  su.validate({ color_quest_item = -1 }).color_quest_item == 0xFF4FC3F7)
check("color_quest_item fractional -> default",
  su.validate({ color_quest_item = 1.5 }).color_quest_item == 0xFF4FC3F7)
check("color_quest_item valid kept",
  su.validate({ color_quest_item = 0xFF010203 }).color_quest_item == 0xFF010203)
for _, k in ipairs({ "icon_color", "color_in_progress", "color_completed",
  "color_unavailable", "color_locked" }) do
  check("color_quest_item differs from " .. k, D.color_quest_item ~= D[k])
end

-- v9 journal_spoilers (SPEC 16.4): default off; only a boolean is kept
check("journal_spoilers default false", D.journal_spoilers == false)
check("journal_spoilers absent -> false", su.validate({}).journal_spoilers == false)
check("journal_spoilers string -> false",
  su.validate({ journal_spoilers = "yes" }).journal_spoilers == false)
check("journal_spoilers number -> false",
  su.validate({ journal_spoilers = 1 }).journal_spoilers == false)
check("journal_spoilers true kept",
  su.validate({ journal_spoilers = true }).journal_spoilers == true)
check("journal_spoilers stored false kept",
  su.validate({ journal_spoilers = false }).journal_spoilers == false)

-- exact defaults key count (24 after the per-category icon keys, plus
-- journal_spoilers, plus 23 world-tracker keys (SPEC 17.5, 17.10.13),
-- plus 8 v14 keys (SPEC 22.6), plus 83 style and route keys (SPEC 23.4),
-- plus 2 coordinate readout keys, plus 5 chest kind keys, plus
-- world_first_token (SPEC 28.9.4))
do
  local n = 0
  for _ in pairs(D) do n = n + 1 end
  check("defaults key count is 152", n == 152)
  check("first token default on", D.world_first_token == true)
end

-- world tracker settings
do
  local W = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_show_opened = false, world_undiscovered = false,
    color_chest = 0xFFC8A27A, color_treasure = 0xFFFFFFFF,
    color_monster = 0xFFFF5A5A, color_seller = 0xFF4DD0C8,
    icon_chest = 33, icon_treasure = 36, icon_monster = 10, icon_seller = 45,
    world_max_markers = 300,
    world_tokens = true, world_beetles = true, world_small_monsters = false,
    color_token = 0xFFC792EA, color_beetle = 0xFFB5E550,
    icon_token = 57, icon_beetle = 46 }
  local V = su.validate({})
  for k, want in pairs(W) do
    check(k .. " default", D[k] == want)
    check(k .. " validate({}) default", V[k] == want)
  end
  for _, k in ipairs(su.WORLD_BOOLS) do
    check(k .. " stored false kept", su.validate({ [k] = false })[k] == false)
    check(k .. " stored true kept", su.validate({ [k] = true })[k] == true)
  end
  local ORDER = { "world_chests", "world_treasure", "world_tokens",
    "world_first_token", "world_beetles", "world_monsters", "world_small_monsters",
    "world_sellers", "world_shops", "world_show_opened", "world_undiscovered" }
  check("WORLD_BOOLS has eleven keys", #su.WORLD_BOOLS == #ORDER)
  check("first token label",
    su.WORLD_BOOL_LABEL.world_first_token == "Finder's Token spot (first token found)")
  check("tokens label", su.WORLD_BOOL_LABEL.world_tokens == "All Seeker's Tokens")
  check("monsters label", su.WORLD_BOOL_LABEL.world_monsters == "Large monsters")
  for i, k in ipairs(ORDER) do
    check("WORLD_BOOLS[" .. i .. "] is " .. k, su.WORLD_BOOLS[i] == k)
  end
  for _, k in ipairs({ "icon_chest", "icon_treasure", "icon_monster", "icon_seller",
    "icon_token", "icon_beetle" }) do
    check(k .. " default is a choice", su.ICON_INDEX[D[k]] ~= nil)
  end
  check("world_shops default false", su.defaults().world_shops == false)
  check("world_shops true kept", su.validate({ world_shops = true }).world_shops == true)
  check("world_shops yes replaced", su.validate({ world_shops = "yes" }).world_shops == false)
  check("world_shops missing filled", su.validate({}).world_shops == false)
  check("Shops label", su.WORLD_LABEL.shops == "Shops")
  check("world_shops bool label", su.WORLD_BOOL_LABEL.world_shops == su.WORLD_LABEL.shops)
  check("color_seller kept", su.validate({ color_seller = 0x12345678 }).color_seller == 0x12345678)
  check("color_token round-trips", su.validate({ color_token = 0x11223344 }).color_token == 0x11223344)
  check("color_beetle round-trips", su.validate({ color_beetle = 0x55667788 }).color_beetle == 0x55667788)
  check("color_token -1 rejected", su.validate({ color_token = -1 }).color_token == 0xFFC792EA)
  check("color_beetle -1 rejected", su.validate({ color_beetle = -1 }).color_beetle == 0xFFB5E550)
  check("color_of token", su.color_of(D, "token") == 0xFFC792EA)
  check("color_of beetle", su.color_of(D, "beetle") == 0xFFB5E550)
  check("icon_of token", su.icon_of(D, "token") == 57)
  check("icon_of beetle", su.icon_of(D, "beetle") == 46)
  check("marker_color token", su.marker_color(D, { cat = "token" }) == 0xFFC792EA)
  check("marker_color beetle", su.marker_color(D, { cat = "beetle" }) == 0xFFB5E550)
  check("color_chest -1 rejected", su.validate({ color_chest = -1 }).color_chest == 0xFFC8A27A)
  check("max_markers clamps high", su.validate({ world_max_markers = 950 }).world_max_markers == 900)
  check("max_markers clamps low", su.validate({ world_max_markers = -5 }).world_max_markers == 0)
  check("max_markers floors", su.validate({ world_max_markers = 12.7 }).world_max_markers == 12)
  check("max_markers non-number", su.validate({ world_max_markers = "x" }).world_max_markers == 300)
  check("icon_chest 6 rejected", su.validate({ icon_chest = 6 }).icon_chest == 33)
  check("color_of seller", su.color_of(D, "seller") == 0xFF4DD0C8)
  check("icon_of treasure", su.icon_of(D, "treasure") == 36)
  check("marker_color done halves alpha",
    su.marker_color(D, { cat = "chest", done = true }) == 0x7FC8A27A)
  check("marker_color not done",
    su.marker_color(D, { cat = "chest" }) == 0xFFC8A27A)
end

-- world toggles: every one has a label, validates as a boolean, and the cap
-- clamp is shared
do
  local all_ok = true
  for _, k in ipairs(su.WORLD_BOOLS) do
    if type(su.WORLD_BOOL_LABEL[k]) ~= "string" then all_ok = false end
    local flipped = su.validate({ [k] = not D[k] })
    if flipped[k] ~= (not D[k]) then all_ok = false end
  end
  check("world toggles: label and validation for every key", all_ok)
  check("clamp_int floors and clamps", su.clamp_int(3.9, 0, 900) == 3
    and su.clamp_int(-4, 0, 900) == 0 and su.clamp_int(1e9, 0, 900) == 900)
  check("clamp_int maps NaN to the low bound", su.clamp_int(0/0, 0, 900) == 0)
  check("world_max_markers bound", su.validate({ world_max_markers = 5000 }).world_max_markers
    == su.WORLD_MAX_MARKERS)
end

-- map search (SPEC 19)
check("search default", su.defaults().search_text == "")
check("search non-string", su.validate({ search_text = 5 }).search_text == "")
check("search cut 64", #su.cut_search(string.rep("a", 70)) == 64)
check("search cut utf8", su.cut_search(string.rep("a", 63) .. "\195\169") == string.rep("a", 63))
check("shop keys", su.COLOR_KEY.shop == "color_seller" and su.ICON_KEY.shop == "icon_seller" and su.WORLD_LABEL.shop == "Shop stock")
check("shop color is seller", su.color_of(su.defaults(), "shop") == su.color_of(su.defaults(), "seller"))
check("search kept", su.validate({ search_text = "goblin" }).search_text == "goblin")
check("search validate cuts", #su.validate({ search_text = string.rep("a", 70) }).search_text == 64)

-- v13 (SPEC 21.7): new bools, icon_for, reset_icons, palette migration
do
  local never = function() return false end
  local always = function() return true end
  for _, k in ipairs({ "matching_icons", "step_icons" }) do
    check(k .. " wrong type -> default", su.validate({ [k] = "yes" })[k] == D[k])
    check(k .. " stored true kept", su.validate({ [k] = true })[k] == true)
    check(k .. " stored false kept", su.validate({ [k] = false })[k] == false)
  end
  check("matching_icons default true", D.matching_icons == true)
  check("step_icons default false", D.step_icons == false)
  check("palette default 13", D.palette == 13)

  check("icon_for beetle mini never", su.icon_for(D, { cat = "beetle" }, "mini", nil, never) == 73)
  check("icon_for chest map never", su.icon_for(D, { cat = "chest" }, "map", nil, never) == 31)
  check("icon_for chest map always", su.icon_for(D, { cat = "chest" }, "map", nil, always) == 33)
  check("icon_for chest head never", su.icon_for(D, { cat = "chest" }, "head", nil, never) == 33)
  check("icon_for step map always", su.icon_for(D, { cat = "in_progress" }, "map", 3, always) == 3)
  check("icon_for shop map never", su.icon_for(D, { cat = "shop" }, "map", nil, never) == 13)
  local only_v12 = function(id)
    for _, v in pairs(su.V12_ICON) do if v == id then return true end end
    return false
  end
  check("icon_for chest mini v12 drawable", su.icon_for(D, { cat = "chest" }, "mini", nil, only_v12) == 31)
  for cat in pairs(su.ICON_KEY) do
    check("icon_for " .. cat .. " map in HAS_FULLMAP",
      su.HAS_FULLMAP[su.icon_for(D, { cat = cat }, "map", nil, never)] == true)
    check("icon_for " .. cat .. " mini in HAS_MINIMAP",
      su.HAS_MINIMAP[su.icon_for(D, { cat = cat }, "mini", nil, never)] == true)
  end
  for key, id in pairs(su.V12_ICON) do
    check("V12_ICON " .. key .. " in both sets", su.HAS_MINIMAP[id] and su.HAS_FULLMAP[id])
  end
  local ni, nc = 0, 0
  for _, k in ipairs(su.ICON_KEYS) do if su.V12_ICON[k] then ni = ni + 1 end end
  for _, k in ipairs(su.COLOR_KEYS) do if su.V12_COLOR[k] then nc = nc + 1 end end
  check("V12_ICON keys are ICON_KEYS", ni == 15 and #su.ICON_KEYS == 15)
  check("V12_COLOR keys are COLOR_KEYS", nc == 12 and #su.COLOR_KEYS == 15)

  -- reset_appearance
  local S = {}
  for k, v in pairs(D) do S[k] = v end
  for _, k in ipairs(su.ICON_KEYS) do S[k] = 9 end
  for _, k in ipairs(su.COLOR_KEYS) do S[k] = 0xFF010203 end
  su.reset_appearance(S)
  local all = true
  for _, k in ipairs(su.ICON_KEYS) do if S[k] ~= D[k] then all = false end end
  for _, k in ipairs(su.COLOR_KEYS) do if S[k] ~= D[k] then all = false end end
  check("reset_appearance restores every icon and color key", all)

  -- migration
  local raw = {}
  for k, v in pairs(su.V12_ICON) do raw[k] = v end
  for k, v in pairs(su.V12_COLOR) do raw[k] = v end
  local m = su.validate(raw)
  local ok = m.palette == 13
  for _, k in ipairs(su.ICON_KEYS) do if m[k] ~= D[k] then ok = false end end
  for _, k in ipairs(su.COLOR_KEYS) do if m[k] ~= D[k] then ok = false end end
  check("migration: all v12 values -> v13 palette", ok)
  raw.color_chest = 0xFF112233
  m = su.validate(raw)
  check("migration: changed color kept", m.color_chest == 0xFF112233 and m.color_monster == D.color_monster)
  raw.color_chest = su.V12_COLOR.color_chest
  raw.palette = 13
  m = su.validate(raw)
  local kept = m.palette == 13
  for _, k in ipairs(su.ICON_KEYS) do if m[k] ~= su.V12_ICON[k] then kept = false end end
  for _, k in ipairs(su.COLOR_KEYS) do
    if su.V12_COLOR[k] then
      if m[k] ~= su.V12_COLOR[k] then kept = false end
    elseif m[k] ~= D[k] then kept = false end
  end
  check("migration: palette 13 keeps v12 values", kept)
  raw.palette = "x"
  local okc, mm = pcall(su.validate, raw)
  check("migration: palette string does not raise and migrates",
    okc and mm.palette == 13 and mm.icon_chest == D.icon_chest)
  check("validate always carries palette 13", su.validate({}).palette == 13 and su.validate(nil).palette == 13)
end

-- v14 (SPEC 22.6): NPC search, names, marks and hints settings
do
  local never = function() return false end
  check("overhead_names default 0", D.overhead_names == 0)
  check("inventory_quest_marks default true", D.inventory_quest_marks == true)
  check("color_npc_search default", D.color_npc_search == 0xFFF06292)
  check("color_route_stop default", D.color_route_stop == 0xFFF8BBD0)
  check("color_hint_pin default", D.color_hint_pin == 0xFF00E676)
  check("icon_npc_search default", D.icon_npc_search == 31)
  check("icon_route_stop default", D.icon_route_stop == 25)
  check("icon_hint_pin default", D.icon_hint_pin == 58)
  for _, c in ipairs({ { 0, 0 }, { 1, 1 }, { 2, 2 }, { -1, 0 }, { 3, 2 },
    { 1.5, 1 }, { "x", 0 } }) do
    check("overhead_names " .. tostring(c[1]),
      su.validate({ overhead_names = c[1] }).overhead_names == c[2])
  end
  check("overhead_names absent", su.validate({}).overhead_names == 0)
  check("inventory_quest_marks false kept",
    su.validate({ inventory_quest_marks = false }).inventory_quest_marks == false)
  check("inventory_quest_marks true kept",
    su.validate({ inventory_quest_marks = true }).inventory_quest_marks == true)
  check("inventory_quest_marks non-bool -> true",
    su.validate({ inventory_quest_marks = "no" }).inventory_quest_marks == true)
  for _, k in ipairs({ "color_npc_search", "color_route_stop", "color_hint_pin" }) do
    check(k .. " kept", su.validate({ [k] = 0xFF112233 })[k] == 0xFF112233)
    check(k .. " negative rejected", su.validate({ [k] = -1 })[k] == D[k])
    check(k .. " float rejected", su.validate({ [k] = 1.5 })[k] == D[k])
    check(k .. " string rejected", su.validate({ [k] = "x" })[k] == D[k])
    check(k .. " not in V12_COLOR", su.V12_COLOR[k] == nil)
  end
  for _, k in ipairs({ "icon_npc_search", "icon_route_stop", "icon_hint_pin" }) do
    check(k .. " kept", su.validate({ [k] = 9 })[k] == 9)
    check(k .. " None rejected", su.validate({ [k] = 61 })[k] == D[k])
    check(k .. " float rejected", su.validate({ [k] = 9.5 })[k] == D[k])
    check(k .. " string rejected", su.validate({ [k] = "9" })[k] == D[k])
    check(k .. " V12_ICON equals default", su.V12_ICON[k] == D[k])
  end
  local want = { npc_search = 31, route_stop = 25, hint_pin = 58 }
  for cat, id in pairs(want) do
    for _, sheet in ipairs({ "map", "mini", "head" }) do
      check("icon_for " .. cat .. " " .. sheet,
        su.icon_for(D, { cat = cat }, sheet, nil, never) == id)
    end
  end
  local S = {}
  for k, v in pairs(D) do S[k] = v end
  S.icon_npc_search = 40
  check("icon_for npc_search 40 mini -> v12", su.icon_for(S, { cat = "npc_search" }, "mini", nil, never) == 31)
  check("icon_for npc_search 40 map kept", su.icon_for(S, { cat = "npc_search" }, "map", nil, never) == 40)
  check("WORLD_LABEL npc_search", su.WORLD_LABEL.npc_search == "NPCs")
  check("WORLD_LABEL route_stop", su.WORLD_LABEL.route_stop == "Route stops")
  check("WORLD_LABEL hint_pin", su.WORLD_LABEL.hint_pin == "Hint pins")
  check("COLOR_KEY npc_search", su.COLOR_KEY.npc_search == "color_npc_search")
  check("COLOR_KEY route_stop", su.COLOR_KEY.route_stop == "color_route_stop")
  check("COLOR_KEY hint_pin", su.COLOR_KEY.hint_pin == "color_hint_pin")
  check("ICON_KEY npc_search", su.ICON_KEY.npc_search == "icon_npc_search")
  check("ICON_KEY route_stop", su.ICON_KEY.route_stop == "icon_route_stop")
  check("ICON_KEY hint_pin", su.ICON_KEY.hint_pin == "icon_hint_pin")
  local R = {}
  for k, v in pairs(D) do R[k] = v end
  for _, k in ipairs({ "icon_npc_search", "icon_route_stop", "icon_hint_pin" }) do R[k] = 9 end
  for _, k in ipairs({ "color_npc_search", "color_route_stop", "color_hint_pin" }) do R[k] = 0xFF010203 end
  su.reset_appearance(R)
  local all = true
  for _, k in ipairs({ "icon_npc_search", "icon_route_stop", "icon_hint_pin",
    "color_npc_search", "color_route_stop", "color_hint_pin" }) do
    if R[k] ~= D[k] then all = false end
  end
  check("reset_appearance restores the six v14 keys", all)
end

-- one-time migration: a renamed data file falls back to its old-named file
do
  local files, reads = {}, {}
  local function load(path) reads[#reads + 1] = path; return files[path] end
  files = { ["new.json"] = { a = 1 }, ["old.json"] = { a = 2 } }
  check("legacy: new file wins", su.load_with_legacy(load, "new.json", "old.json").a == 1)
  files = { ["old.json"] = { a = 2 } }
  check("legacy: old file used when new is missing", su.load_with_legacy(load, "new.json", "old.json").a == 2)
  files = {}
  check("legacy: neither file -> nil", su.load_with_legacy(load, "new.json", "old.json") == nil)
  local function boom(path) if path == "new.json" then error("bad") end return { a = 3 } end
  check("legacy: erroring load falls back", su.load_with_legacy(boom, "new.json", "old.json").a == 3)
  check("legacy: nil legacy path -> nil", su.load_with_legacy(load, "new.json", nil) == nil)
end

-- v14 style settings (SPEC 23.4, 23.7)
do
  local style = require("Clairvoyance.style")
  local d = su.defaults()
  check("v14 outline defaults", d.outline_on == true and d.outline_color == 0xFF000000 and d.outline_width == 1)
  local want = { route_line_color = 0xFFE91E63, route_line_width = 3, route_stop_size = 100,
    route_number_color = 0xFFFFFFFF, route_number_size = 0, route_path = 1,
    route_world_path = false, names_color = 0xFFFFFFFF }
  for k, w in pairs(want) do check("default " .. k, d[k] == w) end
  check("18 groups", #style.GROUPS == 18)
  for _, g in ipairs(style.GROUPS) do
    check("style_" .. g .. "_override", d["style_" .. g .. "_override"] == false)
    check("style_" .. g .. "_outline_on", d["style_" .. g .. "_outline_on"] == true)
    check("style_" .. g .. "_outline_color", d["style_" .. g .. "_outline_color"] == 0xFF000000)
    check("style_" .. g .. "_outline_width", d["style_" .. g .. "_outline_width"] == 1)
  end
  local function val(t) return su.validate(t) end
  check("outline_width 9 -> 4", val({ outline_width = 9 }).outline_width == 4)
  check("outline_width 0 -> 1", val({ outline_width = 0 }).outline_width == 1)
  check("group width clamps", val({ style_chest_outline_width = 9 }).style_chest_outline_width == 4)
  check("route_line_width 20 -> 8", val({ route_line_width = 20 }).route_line_width == 8)
  check("route_stop_size 10 -> 50", val({ route_stop_size = 10 }).route_stop_size == 50)
  local nsz = { { 0, 0 }, { -3, 0 }, { 5, 12 }, { 50, 40 }, { 17.6, 17 }, { "x", 0 }, { 12, 12 }, { 40, 40 } }
  for _, c in ipairs(nsz) do
    check("route_number_size " .. tostring(c[1]), val({ route_number_size = c[1] }).route_number_size == c[2])
  end
  check("route_path 3 -> 1", val({ route_path = 3 }).route_path == 1)
  check("route_path 0 kept", val({ route_path = 0 }).route_path == 0)
  check("route_world_path bool kept", val({ route_world_path = true }).route_world_path == true)
  check("string color -> default", val({ outline_color = "red" }).outline_color == 0xFF000000)
  check("string group color -> default", val({ style_seller_outline_color = "x" }).style_seller_outline_color == 0xFF000000)
  check("string names_color -> default", val({ names_color = "x" }).names_color == 0xFFFFFFFF)

  -- v13-shaped table: old values kept, new defaults filled
  local old = { enabled = false, palette = 13, icon_chest = 9, color_chest = 0xFF112233,
    overhead_distance = 77, world_max_markers = 120, search_text = "abc", show_completed = true,
    overhead_names = 2 }
  local o = val(old)
  check("v13 old values kept", o.enabled == false and o.icon_chest == 9 and o.color_chest == 0xFF112233
    and o.overhead_distance == 77 and o.world_max_markers == 120 and o.search_text == "abc"
    and o.show_completed == true and o.overhead_names == 2)
  local allnew = true
  for k, w in pairs(d) do
    if old[k] == nil then
      if k == "world_monster_off" then
        if type(o[k]) ~= "table" or next(o[k].large or { 1 }) ~= nil
          or next(o[k].small or { 1 }) ~= nil then allnew = false; print("missing default " .. k) end
      elseif o[k] ~= w then allnew = false; print("missing default " .. k) end
    end
  end
  check("v13 table gets every new default", allnew)
  check("COLOR_KEYS still 15", #su.COLOR_KEYS == 15)

  -- set_key
  local S = su.defaults()
  check("set_key color no migration", su.set_key(S, "color_chest", 0xFFC08040) == true and S.color_chest == 0xFFC08040)
  check("set_key clamps", su.set_key(S, "route_line_width", 20) == true and S.route_line_width == 8)
  local before = S.outline_color
  check("set_key bad color", su.set_key(S, "outline_color", "red") == false and S.outline_color == before)
  check("set_key unknown", su.set_key(S, "nope", 1) == false and S.nope == nil)
  check("set_key bool", su.set_key(S, "outline_on", false) == true and S.outline_on == false)
  check("set_key bool wrong type", su.set_key(S, "outline_on", 1) == false and S.outline_on == false)
  check("set_key number size", su.set_key(S, "route_number_size", 5) == true and S.route_number_size == 12)
  check("set_key number size bad type", su.set_key(S, "route_number_size", "x") == false and S.route_number_size == 12)
  check("set_key icon", su.set_key(S, "icon_chest", 9) == true and S.icon_chest == 9)
  check("set_key icon bad", su.set_key(S, "icon_chest", 61) == false and S.icon_chest == 9)
  check("set_key route_path", su.set_key(S, "route_path", 0) == true and S.route_path == 0)
  check("set_key route_world_path", su.set_key(S, "route_world_path", true) == true and S.route_world_path == true)
  check("set_key NaN", su.set_key(S, "route_line_width", 0/0) == false)

  -- reset_appearance
  local R = su.defaults()
  for _, k in ipairs(su.ICON_KEYS) do R[k] = 9 end
  for _, k in ipairs(su.COLOR_KEYS) do R[k] = 0xFF010203 end
  for _, k in ipairs(su.STYLE_BOOL_KEYS) do R[k] = not d[k] end
  for _, k in ipairs(su.STYLE_COLOR_KEYS) do R[k] = 0xFF010203 end
  for k in pairs(su.STYLE_INT_RANGE) do R[k] = 4 end
  R.route_number_size = 20; R.route_path = 0; R.route_world_path = true; R.show_overhead = false
  su.reset_appearance(R)
  local ok = true
  local function same(k) if R[k] ~= d[k] then ok = false; print("not reset " .. k) end end
  for _, k in ipairs(su.ICON_KEYS) do same(k) end
  for _, k in ipairs(su.COLOR_KEYS) do same(k) end
  for _, k in ipairs(su.STYLE_BOOL_KEYS) do same(k) end
  for _, k in ipairs(su.STYLE_COLOR_KEYS) do same(k) end
  for k in pairs(su.STYLE_INT_RANGE) do same(k) end
  same("route_number_size")
  check("reset_appearance resets appearance keys", ok)
  check("reset_appearance leaves the rest", R.route_path == 0 and R.route_world_path == true and R.show_overhead == false)
  check("reset_icons alias is gone", su.reset_icons == nil)

  -- key lists cover every 23.4 key except route_path / route_world_path
  local listed = {}
  for _, t in ipairs({ su.STYLE_BOOL_KEYS, su.STYLE_COLOR_KEYS }) do for _, k in ipairs(t) do listed[k] = true end end
  for k in pairs(su.STYLE_INT_RANGE) do listed[k] = true end
  listed.route_number_size = true
  check("route_number_size not in STYLE_INT_RANGE", su.STYLE_INT_RANGE.route_number_size == nil)
  check("outline_width range", su.STYLE_INT_RANGE.outline_width[1] == 1 and su.STYLE_INT_RANGE.outline_width[2] == 4)
  local cover = true
  for k in pairs(d) do
    local isnew = k:match("^outline_") or k:match("^style_") or k:match("^route_") or k == "names_color"
    if isnew and k ~= "route_path" and k ~= "route_world_path" and not listed[k] then cover = false; print("unlisted " .. k) end
  end
  check("lists cover every 23.4 key", cover)

  -- PANEL_ORDER
  local ids = {}
  for i, p in ipairs(su.PANEL_ORDER) do ids[i] = p.id end
  check("panel order ids", table.concat(ids, ",") ==
    "enabled,search,quests,world_markers,npcs,items,map,appearance,quest_tree,world,status")
  local seen, dup = {}, false
  for _, p in ipairs(su.PANEL_ORDER) do
    for _, k in ipairs(p.keys) do
      if seen[k] then dup = true; print("dup " .. k) end
      seen[k] = true
    end
  end
  check("panel keys unique", not dup)
  local skip = {}
  for _, k in ipairs(su.NO_CONTROL_KEYS) do skip[k] = true end
  local eq = true
  for k in pairs(d) do if not skip[k] and not seen[k] then eq = false; print("not in panel " .. k) end end
  for k in pairs(seen) do if d[k] == nil or skip[k] then eq = false; print("extra in panel " .. k) end end
  check("panel keys == defaults minus NO_CONTROL_KEYS", eq)
  check("NO_CONTROL_KEYS", #su.NO_CONTROL_KEYS == 1 and su.NO_CONTROL_KEYS[1] == "palette")
end

-- v14 chest kind filters (SPEC 27.6)
do
  local KINDS = { "world_kind_ng_shard", "world_kind_kept", "world_kind_quest",
    "world_kind_trap", "world_kind_pawn" }
  check("WORLD_KIND_BOOLS has five keys", #su.WORLD_KIND_BOOLS == 5)
  local inbool = {}
  local old = su.validate({})
  for i, k in ipairs(KINDS) do
    check("WORLD_KIND_BOOLS[" .. i .. "] is " .. k, su.WORLD_KIND_BOOLS[i] == k)
    check(k .. " default true", D[k] == true)
    check(k .. " absent loads true", old[k] == true)
    check(k .. " stored false kept", su.validate({ [k] = false })[k] == false)
    check(k .. " string replaced by true", su.validate({ [k] = "no" })[k] == true)
    check(k .. " has a label", type(su.WORLD_BOOL_LABEL[k]) == "string")
  end
  check("kind labels", su.WORLD_BOOL_LABEL.world_kind_ng_shard == "New shard each cycle"
    and su.WORLD_BOOL_LABEL.world_kind_kept == "Stays opened in NG+"
    and su.WORLD_BOOL_LABEL.world_kind_quest == "Quest-gated"
    and su.WORLD_BOOL_LABEL.world_kind_trap == "Trap"
    and su.WORLD_BOOL_LABEL.world_kind_pawn == "Pawns can't open")
  check("WORLD_BOOLS still eleven", #su.WORLD_BOOLS == 11)
  local c0 = su.color_of(D, "chest")
  local half = (((c0 >> 24) & 0xFF) // 2 << 24) | (c0 & 0x00FFFFFF)
  local faded = su.marker_color(D, { cat = "chest", faded = true })
  check("marker_color faded halves alpha", faded == half)
  check("marker_color faded and done halves once",
    su.marker_color(D, { cat = "chest", faded = true, done = true }) == half)
end
-- world_toggled (SPEC 28.7.3)
do
  local prev = {}
  check("toggled: first call true", su.world_toggled(prev, { world_chests = true }) == true)
  check("toggled: same again false", su.world_toggled(prev, { world_chests = true }) == false)
  check("toggled: on to off true", su.world_toggled(prev, { world_chests = false }) == true)
  check("toggled: off to on true", su.world_toggled(prev, { world_chests = true }) == true)
  check("toggled: prev copied", prev.world_chests == true)
  local p2 = {}
  su.world_toggled(p2, { world_chests = true })
  check("toggled: another key true",
    su.world_toggled(p2, { world_chests = true, world_first_token = true }) == true)
  check("toggled: no settings false", su.world_toggled({}, {}) == false)
end
-- world tables shared by the search line and the settings UI
do
  local inb = {}
  for _, k in ipairs(su.WORLD_BOOLS) do inb[k] = true end
  local n = 0
  for k in pairs(su.WORLD_NO_SEARCH) do
    n = n + 1
    check("WORLD_NO_SEARCH key " .. k .. " is a world toggle", inb[k] == true)
  end
  check("WORLD_NO_SEARCH has the four unsearched toggles", n == 4
    and su.WORLD_NO_SEARCH.world_show_opened and su.WORLD_NO_SEARCH.world_undiscovered
    and su.WORLD_NO_SEARCH.world_shops and su.WORLD_NO_SEARCH.world_first_token)
  check("WORLD_TREES tokens pair", su.WORLD_TREES.world_tokens[2] == "world_first_token")
  check("WORLD_TREES monsters pair", su.WORLD_TREES.world_monsters[2] == "world_small_monsters")
  for first, tr in pairs(su.WORLD_TREES) do
    check("WORLD_TREES " .. first .. " keys are toggles with labels",
      inb[first] and inb[tr[2]] and su.WORLD_BOOL_LABEL[first] ~= nil
      and su.WORLD_BOOL_LABEL[tr[2]] ~= nil and type(tr[1]) == "string")
    check("WORLD_TREE_SECOND holds " .. tr[2], su.WORLD_TREE_SECOND[tr[2]] == true)
    check("WORLD_TREE_SECOND omits first " .. first, su.WORLD_TREE_SECOND[first] == nil)
  end
end
-- median (SPEC 28.11.2)
do
  check("median empty", su.median({}) == nil)
  local l3 = { 3, 1, 2 }
  check("median odd", su.median(l3) == 2)
  check("median input unchanged", l3[1] == 3 and l3[2] == 1 and l3[3] == 2)
  local l4 = { 4, 1, 3, 2 }
  check("median even is the lower middle", su.median(l4) == 2)
  check("median even input unchanged", l4[1] == 4 and l4[4] == 2)
  check("median one", su.median({ 7 }) == 7)
end
-- world_monster_off and the kind helpers (SPEC 29.2.1, 29.6)
do
  local function empty(t) return type(t) == "table" and next(t) == nil end
  local function wmo(raw) return su.validate(raw).world_monster_off or {} end
  local d0 = su.defaults().world_monster_off
  check("monster_off default shape", type(d0) == "table" and empty(d0.large) and empty(d0.small))
  for _, v in ipairs({ "x", 5 }) do
    local o = wmo({ world_monster_off = v })
    check("monster_off " .. tostring(v) .. " -> default", type(o) == "table" and empty(o.large) and empty(o.small))
  end
  check("monster_off nil -> default",
    empty(wmo({}).large) and empty(wmo({}).small))
  local p = wmo({ world_monster_off = { large = "x", small = { Goblin = true } } })
  check("monster_off partial keeps good class", empty(p.large) and (p.small or {}).Goblin == true)
  local junk0 = wmo({ world_monster_off = { large = { [1] = true, A = false, B = "yes", C = 1,
    [""] = true, [string.rep("k", 65)] = true, [string.rep("k", 64)] = true, K = true, ["z"] = true } } })
  local junk = junk0.large or {}
  check("monster_off drops bad keys and values", type(junk0.large) == "table"
    and next(junk0.large) ~= nil and junk[1] == nil and junk.A == nil and junk.B == nil
    and junk.C == nil and junk[""] == nil and junk[string.rep("k", 65)] == nil)
  check("monster_off keeps 1 and 64 byte keys", junk.K == true and junk[string.rep("k", 64)] == true
    and junk.z == true)
  local big = {}
  for i = 1, 250 do big[string.format("k%03d", i)] = true end
  local kept = wmo({ world_monster_off = { large = big } }).large or {}
  local cnt, first200 = 0, true
  for k in pairs(kept) do cnt = cnt + 1 end
  for i = 1, 200 do if not kept[string.format("k%03d", i)] then first200 = false end end
  check("monster_off caps at 200 by byte order", cnt == 200 and first200 and kept.k201 == nil)
  check("monster_off has no RULE", su.set_key({}, "world_monster_off", {}) == false)

  local l = su.monster_kind_list({ B = true, A = true }, { C = true, A = true })
  check("monster_kind_list merges sorted", type(l) == "table" and #l == 3
    and l[1] == "A" and l[2] == "B" and l[3] == "C")
  local l0 = su.monster_kind_list(nil, nil)
  check("monster_kind_list nil -> empty", type(l0) == "table" and #l0 == 0)

  check("monster_off_count counts both classes",
    su.monster_off_count({ large = { A = true, B = true }, small = { A = true } }) == 3)
  check("monster_off_count nil and string", su.monster_off_count(nil) == 0
    and su.monster_off_count("x") == 0)

  check("monster_class_off_count",
    su.monster_class_off_count({ A = true, B = false, C = true }) == 2
    and su.monster_class_off_count("x") == 0)

  check("kind_box class off -> disabled", su.kind_box("A", false, 0, false) == "disabled")
  check("kind_box long name -> disabled", su.kind_box(string.rep("k", 65), true, 0, false) == "disabled")
  check("kind_box 199 off, on -> on", su.kind_box("A", true, 199, false) == "on")
  check("kind_box 200 off, on -> disabled", su.kind_box("A", true, 200, false) == "disabled")
  check("kind_box 200 off, off kind -> off", su.kind_box("A", true, 200, true) == "off")
  check("kind_box plain on", su.kind_box("A", true, 0, false) == "on")

  check("kind_empty_text", su.kind_empty_text(false) == "Turn on to list kinds"
    and su.kind_empty_text(true) == "No kinds seen yet")

  local st = {}
  check("set_kind_off creates tables and sets", su.set_kind_off(st, "large", "A", true)
    and st.world_monster_off.large.A == true)
  check("set_kind_off clears", su.set_kind_off(st, "large", "A", false)
    and st.world_monster_off.large.A == nil)
  check("set_kind_off bad class and kind", not su.set_kind_off(st, "x", "A", true)
    and not su.set_kind_off(st, "large", "", true)
    and not su.set_kind_off(st, "large", string.rep("k", 65), true))
  check("set_kind_off refuses a family entry of the wrong length",
    not su.set_kind_off(st, "small", "fam:ab", true)
    and su.set_kind_off(st, "small", "fam:ch220", true)
    and su.set_kind_off(st, "small", "fam:ch220", false))
  for i = 1, 200 do su.set_kind_off(st, "small", string.format("k%03d", i), true) end
  check("set_kind_off refuses past the cap", not su.set_kind_off(st, "small", "extra", true)
    and su.set_kind_off(st, "small", "k001", true))

  local prev = {}
  su.world_toggled(prev, { world_chests = true })
  check("world_toggled ignores world_monster_off",
    su.world_toggled(prev, { world_chests = true, world_monster_off = { large = { A = true }, small = {} } }) == false)

  -- family entries (SPEC 30.6)
  local fo = wmo({ world_monster_off = { small = { ["fam:ch220"] = true, ["fam:"] = true,
    ["fam:?"] = true, ["fam:not-a-family-id"] = true } } }).small or {}
  check("validate keeps fam:ch220", fo["fam:ch220"] == true)
  check("validate drops bad fam keys", fo["fam:"] == nil and fo["fam:?"] == nil
    and fo["fam:not-a-family-id"] == nil)
  local kk = { ["fam:ch220"] = true }
  for i = 1, 200 do kk[string.format("K%03d", i)] = true end
  local kc = wmo({ world_monster_off = { large = kk } }).large or {}
  local kcnt, kok = 0, true
  for _ in pairs(kc) do kcnt = kcnt + 1 end
  for i = 1, 199 do if not kc[string.format("K%03d", i)] then kok = false end end
  check("cap keeps fam:ch220 and K001..K199, drops K200",
    kcnt == 200 and kok and kc["fam:ch220"] == true and kc.K200 == nil)
  local ff = { Goblin = true }
  for i = 1, 201 do ff[string.format("fam:c%04d", i)] = true end
  local fc = wmo({ world_monster_off = { small = ff } }).small or {}
  local fcnt, fok = 0, true
  for _ in pairs(fc) do fcnt = fcnt + 1 end
  for i = 1, 200 do if not fc[string.format("fam:c%04d", i)] then fok = false end end
  check("cap keeps 200 family keys before kinds", fcnt == 200 and fok
    and fc["fam:c0201"] == nil and fc.Goblin == nil)

  local mk = su.monster_kind_list(nil, { Cyclops = true, ["fam:ch220"] = true })
  check("monster_kind_list skips fam keys", type(mk) == "table" and #mk == 1 and mk[1] == "Cyclops")

  local kn, fn = su.monster_off_count({ large = { A = true, ["fam:ch250"] = true },
    small = { ["fam:ch220"] = true } })
  check("monster_off_count kinds then families", kn == 1 and fn == 2)
  local kn0, fn0 = su.monster_off_count(nil)
  check("monster_off_count nil -> 0, 0", kn0 == 0 and fn0 == 0)

  local fl = type(su.monster_kind_list) == "function" and su.monster_kind_list({ Hobgoblin = true, Goblin = true })
  check("monster_kind_list (family seen set) sorted", type(fl) == "table" and #fl == 2 and fl[1] == "Goblin" and fl[2] == "Hobgoblin")
  local fl0 = type(su.monster_kind_list) == "function" and su.monster_kind_list(nil)
  check("monster_kind_list (family seen set) nil -> empty", type(fl0) == "table" and #fl0 == 0)

  check("kind_box family off -> disabled", su.kind_box("Goblin", true, 0, false, true) == "disabled")
  check("kind_box fam_off false/nil as before", su.kind_box("A", true, 0, false, false) == "on"
    and su.kind_box("A", true, 0, true, nil) == "off")

  check("family_box class off -> disabled",
    type(su.family_box) == "function" and su.family_box(false, 0, false) == "disabled")
  check("family_box on at cap -> disabled",
    type(su.family_box) == "function" and su.family_box(true, 200, false) == "disabled")
  check("family_box off at cap -> off",
    type(su.family_box) == "function" and su.family_box(true, 200, true) == "off")
  check("family_box plain on",
    type(su.family_box) == "function" and su.family_box(true, 0, false) == "on")

  -- monster_tree (SPEC 30.3.1, 30.6.2)
  local function tree(seen, names, offs, class_on)
    if type(su.monster_tree) ~= "function" then return nil end
    return su.monster_tree(seen, names, offs, class_on)
  end
  local t1 = tree({ ch220 = { Goblin = true, Hobgoblin = true } }, { ch220 = "Goblin" }, {}, true)
  check("tree: two-kind family is a node with kinds in name order",
    type(t1) == "table" and #t1 == 1 and t1[1].fam == "ch220" and t1[1].name == "Goblin"
    and t1[1].node == true and t1[1].family_box == "on" and #t1[1].kinds == 2
    and t1[1].kinds[1].kind == "Goblin" and t1[1].kinds[1].box == "on"
    and t1[1].kinds[2].kind == "Hobgoblin")
  local t2 = tree({ ch255 = { Medusa = true } }, { ch255 = "Medusa" }, {}, true)
  check("tree: one-kind family is not a node",
    type(t2) == "table" and #t2 == 1 and t2[1].node == false and #t2[1].kinds == 1
    and t2[1].kinds[1].box == "on")
  local t3 = tree({ ch255 = { Medusa = true } }, { ch255 = "Medusa" }, { ["fam:ch255"] = true }, true)
  check("tree: one-kind family with its entry off is a node, kind disabled",
    type(t3) == "table" and #t3 == 1 and t3[1].node == true and t3[1].family_box == "off"
    and t3[1].kinds[1].box == "disabled")
  local t4 = tree({ ["?"] = { Monster = true } }, {}, { Cyclops = true }, true)
  check("tree: ? kinds and off-unseen kinds are one plain entry",
    type(t4) == "table" and #t4 == 1 and t4[1].plain == true and #t4[1].kinds == 2
    and t4[1].kinds[1].kind == "Cyclops" and t4[1].kinds[1].box == "off"
    and t4[1].kinds[2].kind == "Monster" and t4[1].kinds[2].box == "on")
  local t5 = tree({}, {}, { ["fam:ch299"] = true }, true)
  check("tree: off family not seen gives an unseen entry",
    type(t5) == "table" and #t5 == 1 and t5[1].fam == "ch299" and t5[1].unseen == true
    and t5[1].family_box == "off")
  local t6 = tree({ ch220 = { Goblin = true, Hobgoblin = true } }, { ch220 = "Goblin" },
    { Cyclops = true, ["fam:ch299"] = true }, false)
  local ok6 = type(t6) == "table" and #t6 == 3 and t6[1].family_box == "disabled"
  if ok6 then
    for _, k in ipairs(t6[1].kinds) do if k.box ~= "disabled" then ok6 = false end end
    ok6 = ok6 and t6[2].plain == true and t6[2].kinds[1].box == "disabled"
      and t6[3].unseen == true and t6[3].family_box == "disabled"
  end
  check("tree: class off disables every box", ok6)
  local t7 = tree({ ch300 = { Zed = true }, ch100 = { Zed2 = true, Zed3 = true } },
    { ch300 = "Alpha", ch100 = "Alpha" }, {}, true)
  check("tree: families sort by name then fam",
    type(t7) == "table" and #t7 == 2 and t7[1].fam == "ch100" and t7[2].fam == "ch300")

  local t8 = tree({ ch220 = { Goblin = true, Monster = true }, ["?"] = { Monster = true } },
    { ch220 = "Goblin" }, {}, true)
  check("tree: a ? kind also seen in a family stays in the plain entry",
    type(t8) == "table" and #t8 == 2 and t8[2].plain == true and #t8[2].kinds == 1
    and t8[2].kinds[1].kind == "Monster")
  local t9 = tree({ ch255 = { Medusa = true } }, { ch255 = "Medusa" },
    { ["fam:ch255"] = true, Medusa = true }, true)
  check("tree: kind entry carries its own saved state under an off family",
    type(t9) == "table" and t9[1].kinds[1].box == "disabled" and t9[1].kinds[1].off == true
    and t3[1].kinds[1].off == false)
  local t10 = tree({ ["?"] = { Odd = true } }, {}, { Cyclops = true }, true)
  check("tree: plain kind entries carry off",
    type(t10) == "table" and t10[1].kinds[1].kind == "Cyclops" and t10[1].kinds[1].off == true
    and t10[1].kinds[2].off == false)

  -- not_searched (SPEC 30.6.8)
  local all_on = {}
  for _, k in ipairs(su.WORLD_BOOLS) do all_on[k] = true end
  local ns_in = {}
  for k, v in pairs(all_on) do ns_in[k] = v end
  ns_in.world_monster_off = { large = {}, small = { Goblin = true, ["fam:ch220"] = true } }
  local ns1 = type(su.not_searched) == "function" and su.not_searched(ns_in)
  check("not_searched counts kinds and families", type(ns1) == "table" and #ns1 == 2
    and ns1[1] == "1 monster kinds" and ns1[2] == "1 monster families")
  local one_off = {}
  for k, v in pairs(all_on) do one_off[k] = v end
  one_off.world_chests = false
  one_off.world_shops = false   -- in WORLD_NO_SEARCH: never listed
  one_off.world_monster_off = { large = {}, small = {} }
  local ns2 = type(su.not_searched) == "function" and su.not_searched(one_off)
  check("not_searched lists a searchable toggle off", type(ns2) == "table" and #ns2 == 1
    and ns2[1] == string.lower(su.WORLD_BOOL_LABEL.world_chests))
end
if failures > 0 then os.exit(1) end
print("settings_test: all OK")
