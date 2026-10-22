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
local ICON_DEF = { icon_startable = 52, icon_in_progress = 0, icon_completed = 42,
  icon_unavailable = 21, icon_locked = 41, icon_quest_item = 53 }
for k, want in pairs(ICON_DEF) do
  check(k .. " default", D[k] == want)
  check(k .. " default is a choice", su.ICON_INDEX[D[k]] ~= nil)
  check(k .. " kept when a choice", su.validate({ [k] = 9 })[k] == 9)
  check(k .. " blank-on-minimap type rejected", su.validate({ [k] = 46 })[k] == want)
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
check("icon_color default red", d.icon_color == 0xFF960707)
check("show defaults", d.show_startable == true and d.show_in_progress == true
  and d.show_completed == false and d.show_unavailable == false
  and d.show_locked == false)
check("color defaults", d.color_in_progress == 0xFFD7A500
  and d.color_completed == 0xFF2E8B57 and d.color_unavailable == 0xFF787878
  and d.color_locked == 0xFF46468C)

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
check("color_quest_item default cyan", D.color_quest_item == 0xFF00C8FF)
check("color_quest_item absent -> default", su.validate({}).color_quest_item == 0xFF00C8FF)
check("color_quest_item above range -> default",
  su.validate({ color_quest_item = 2^33 }).color_quest_item == 0xFF00C8FF)
check("color_quest_item negative -> default",
  su.validate({ color_quest_item = -1 }).color_quest_item == 0xFF00C8FF)
check("color_quest_item fractional -> default",
  su.validate({ color_quest_item = 1.5 }).color_quest_item == 0xFF00C8FF)
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
-- journal_spoilers, plus 23 world-tracker keys (SPEC 17.5, 17.10.13))
do
  local n = 0
  for _ in pairs(D) do n = n + 1 end
  check("defaults key count is 49", n == 49)
end

-- world tracker settings
do
  local W = { world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_show_opened = false, world_undiscovered = false,
    color_chest = 0xFFC08040, color_treasure = 0xFFFFD700,
    color_monster = 0xFFE04040, color_seller = 0xFF40C0E0,
    icon_chest = 31, icon_treasure = 58, icon_monster = 29, icon_seller = 13,
    world_max_markers = 300,
    world_tokens = true, world_beetles = true, world_small_monsters = false,
    color_token = 0xFFB080FF, color_beetle = 0xFF60E060,
    icon_token = 57, icon_beetle = 73 }
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
  check("color_token -1 rejected", su.validate({ color_token = -1 }).color_token == 0xFFB080FF)
  check("color_beetle -1 rejected", su.validate({ color_beetle = -1 }).color_beetle == 0xFF60E060)
  check("color_of token", su.color_of(D, "token") == 0xFFB080FF)
  check("color_of beetle", su.color_of(D, "beetle") == 0xFF60E060)
  check("icon_of token", su.icon_of(D, "token") == 57)
  check("icon_of beetle", su.icon_of(D, "beetle") == 73)
  check("marker_color token", su.marker_color(D, { cat = "token" }) == 0xFFB080FF)
  check("marker_color beetle", su.marker_color(D, { cat = "beetle" }) == 0xFF60E060)
  check("color_chest -1 rejected", su.validate({ color_chest = -1 }).color_chest == 0xFFC08040)
  check("max_markers clamps high", su.validate({ world_max_markers = 950 }).world_max_markers == 900)
  check("max_markers clamps low", su.validate({ world_max_markers = -5 }).world_max_markers == 0)
  check("max_markers floors", su.validate({ world_max_markers = 12.7 }).world_max_markers == 12)
  check("max_markers non-number", su.validate({ world_max_markers = "x" }).world_max_markers == 300)
  check("icon_chest 6 rejected", su.validate({ icon_chest = 6 }).icon_chest == 31)
  check("color_of seller", su.color_of(D, "seller") == 0xFF40C0E0)
  check("icon_of treasure", su.icon_of(D, "treasure") == 58)
  check("marker_color done halves alpha",
    su.marker_color(D, { cat = "chest", done = true }) == 0x7FC08040)
  check("marker_color not done",
    su.marker_color(D, { cat = "chest" }) == 0xFFC08040)
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
