-- tests/settings_test.lua
package.path = package.path .. ";./reframework/autorun/?.lua"
local su = require("Clairvoyance.settings_util")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end
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
-- plus 8 v14 keys (SPEC 22.6))
do
  local n = 0
  for _ in pairs(D) do n = n + 1 end
  check("defaults key count is 60", n == 60)
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
    "world_beetles", "world_monsters", "world_small_monsters",
    "world_sellers", "world_shops", "world_show_opened", "world_undiscovered" }
  check("WORLD_BOOLS has ten keys", #su.WORLD_BOOLS == #ORDER)
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

  -- reset_icons
  local S = {}
  for k, v in pairs(D) do S[k] = v end
  for _, k in ipairs(su.ICON_KEYS) do S[k] = 9 end
  for _, k in ipairs(su.COLOR_KEYS) do S[k] = 0xFF010203 end
  su.reset_icons(S)
  local all = true
  for _, k in ipairs(su.ICON_KEYS) do if S[k] ~= D[k] then all = false end end
  for _, k in ipairs(su.COLOR_KEYS) do if S[k] ~= D[k] then all = false end end
  check("reset_icons restores every icon and color key", all)

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
  su.reset_icons(R)
  local all = true
  for _, k in ipairs({ "icon_npc_search", "icon_route_stop", "icon_hint_pin",
    "color_npc_search", "color_route_stop", "color_hint_pin" }) do
    if R[k] ~= D[k] then all = false end
  end
  check("reset_icons restores the six v14 keys", all)
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

if failures > 0 then os.exit(1) end
print("settings_test: all OK")
