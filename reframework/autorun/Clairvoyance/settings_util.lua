-- settings_util.lua — pure validation; no sdk/json.
local M = {}
local style = require("Clairvoyance.style")

-- The eight route colours, slot 1 first (SPEC 32.14.2); a new table each call.
local ROUTE_COLORS = { 0xFFE91E63, 0xFF00E5FF, 0xFFFFEB3B, 0xFF76FF03,
  0xFFD500F9, 0xFF2979FF, 0xFF1DE9B6, 0xFFB388FF }
local DIM_ALPHA_DEFAULT = 25
M.DIM_ALPHA_DEFAULT = DIM_ALPHA_DEFAULT
M.ROUTE_SLOTS = 8 -- the colour slots (one per published route)
function M.default_route_colors()
  local t = {}
  for i = 1, #ROUTE_COLORS do t[i] = ROUTE_COLORS[i] end
  return t
end

function M.defaults()
  local t = {
    enabled = true, show_minimap = true, icon_color = 0xFFFFD34D, debug = false,
    matching_icons = true, step_icons = false, palette = 13,
    icon_startable = 52, icon_in_progress = 52, icon_completed = 42,
    icon_unavailable = 30, icon_locked = 41, icon_quest_item = 35,
    show_startable = true, show_in_progress = true,
    show_completed = false, show_unavailable = false, show_locked = false,
    color_in_progress = 0xFFFF9A3C, color_completed = 0xFF7FA88A,
    color_unavailable = 0xFF9A9A9A, color_locked = 0xFF7A88B0,
    show_overhead = true, hide_overhead_in_cutscenes_and_menus = true,
    overhead_distance = 50.0,
    reveal_gate_names = false, journal_spoilers = false,
    show_quest_items = true, color_quest_item = 0xFF4FC3F7,
    world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_shops = false, world_show_opened = false, world_undiscovered = false,
    color_chest = 0xFFC8A27A, color_treasure = 0xFFFFFFFF,
    color_monster = 0xFFFF5A5A, color_seller = 0xFF4DD0C8,
    icon_chest = 33, icon_treasure = 36, icon_monster = 10, icon_seller = 45,
    world_max_markers = 300,
    world_tokens = true, world_beetles = true, world_small_monsters = false,
    world_first_token = true,
    color_token = 0xFFC792EA, color_beetle = 0xFFB5E550,
    icon_token = 57, icon_beetle = 46,
    search_text = "",
    overhead_names = 0, inventory_quest_marks = true,
    coords_map_cursor = true, coords_minimap = true,
    world_kind_ng_shard = true, world_kind_kept = true, world_kind_quest = true,
    world_kind_trap = true, world_kind_pawn = true,
    color_npc_search = 0xFFF06292,
    color_hint_pin = 0xFF00E676,
    icon_npc_search = 31, icon_route_stop = 25, icon_hint_pin = 58,
    -- v14 styling and routes (SPEC 23.4)
    outline_on = true, outline_color = 0xFF000000, outline_width = 1,
    route_colors = M.default_route_colors(), route_line_width = 3, route_stop_size = 100,
    route_gradient = true, route_gradient_end = 0xFF101010,
    route_gradient_amount = 80, route_gradient_alpha = 15,
    route_legend = true, focus_place_routes = true, focus_dim_alpha = DIM_ALPHA_DEFAULT,
    route_number_color = 0xFFFFFFFF, route_number_size = 0,
    route_path = 1, route_world_path = false, names_color = 0xFFFFFFFF,
    -- monster kinds switched off, per class (SPEC 29.2.1)
    world_monster_off = { large = {}, small = {} },
    -- quest focus (SPEC 32)
    focus_qids = {}, focus_tracked = false, focus_unrelated = 0, focus_routes = 1,
    color_focus_place = 0xFFFFAB40, icon_focus_place = 26,
  }
  for _, g in ipairs(style.GROUPS) do
    t["style_" .. g .. "_override"] = false
    t["style_" .. g .. "_outline_on"] = true
    t["style_" .. g .. "_outline_color"] = 0xFF000000
    t["style_" .. g .. "_outline_width"] = 1
  end
  return t
end

-- Picker choices: every icon type that has a picture on at least one
-- atlas (full map UVS_map_01, minimap UVS_map_03; 21.3), read from the
-- game files. A choice that is blank on one atlas is drawn there through
-- the v12 fallback (icon_for). Excluded: 6, 7, 23, 55 (another mod reads
-- them as warp and camp markers; SPEC 3.2 and 7.3), 61 (None) and 76-80
-- (reserved, SPEC 3.2); 64 has no picture on either atlas.
M.ICON_CHOICES = {
  { 0, "Gold cross" }, { 1, "Hex I" }, { 2, "Hex II" }, { 3, "Hex III" },
  { 4, "Hex IV" }, { 5, "Hex V" }, { 8, "Riftstone" }, { 9, "Inn" },
  { 10, "Weapons" }, { 11, "Armor" }, { 12, "Apothecary" },
  { 13, "Scrap store" }, { 14, "Vocation guild" }, { 15, "Ox" },
  { 16, "Barber" }, { 17, "Rose" }, { 18, "Tavern" }, { 19, "Hot spring" },
  { 20, "Dragonforged" }, { 21, "Coffin" }, { 22, "House" },
  { 24, "Oracle" }, { 25, "Lantern" }, { 26, "Exit arrow" },
  { 27, "Rooster" }, { 28, "Bench" }, { 29, "Red claw" },
  { 30, "Hollow diamond" }, { 31, "Small diamond" }, { 32, "Rock arch" },
  { 33, "Treasure chest" }, { 34, "Exclamation" }, { 35, "Open hand" },
  { 36, "Crystal cluster" }, { 37, "Rock" }, { 38, "Shrine door" },
  { 39, "Red meat" }, { 40, "Glowing helm" }, { 41, "Archway" },
  { 42, "Archway (check)" }, { 43, "Red swirl" }, { 44, "Wagon" },
  { 45, "Cart" }, { 46, "Gold spark" }, { 47, "Red eye diamond" },
  { 48, "Blue wisp" }, { 49, "Purple swirl" }, { 50, "Purple eye diamond" },
  { 51, "Statue" }, { 52, "Diamond flag" }, { 53, "Basket" },
  { 54, "Anvil" }, { 56, "Gold star diamond" }, { 57, "Triquetra" },
  { 58, "Gold diamond" }, { 59, "Hammer" }, { 60, "Scepter" },
  { 62, "Dark statue" }, { 63, "Cross mark" }, { 65, "Castle town" },
  { 66, "Spires" }, { 67, "Town" }, { 68, "Village" }, { 69, "Camp" },
  { 70, "Plank" }, { 71, "Slash" }, { 72, "Zigzag" }, { 73, "Red glow" },
  { 74, "Ship" }, { 75, "Brown claw" },
}
M.ICON_LABELS, M.ICON_INDEX = {}, {}
for i, c in ipairs(M.ICON_CHOICES) do
  M.ICON_LABELS[i] = string.format("%s (%d)", c[2], c[1])
  M.ICON_INDEX[c[1]] = i
end

M.HAS_MINIMAP = {
  [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
  [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true,
  [12] = true, [13] = true, [14] = true, [15] = true, [16] = true,
  [17] = true, [18] = true, [19] = true, [20] = true, [21] = true,
  [22] = true, [23] = true, [24] = true, [25] = true, [26] = true,
  [27] = true, [28] = true, [29] = true, [30] = true, [31] = true,
  [32] = true, [33] = true, [34] = true, [35] = true, [36] = true,
  [37] = true, [38] = true, [39] = true, [41] = true, [42] = true,
  [43] = true, [45] = true, [49] = true, [51] = true, [52] = true,
  [53] = true, [54] = true, [55] = true, [57] = true, [58] = true,
  [59] = true, [60] = true, [62] = true, [63] = true, [70] = true,
  [71] = true, [72] = true, [73] = true, [76] = true, [77] = true,
  [78] = true, [79] = true, [80] = true,
}
M.HAS_FULLMAP = {
  [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
  [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [11] = true,
  [12] = true, [13] = true, [14] = true, [15] = true, [16] = true,
  [17] = true, [18] = true, [19] = true, [20] = true, [21] = true,
  [22] = true, [23] = true, [24] = true, [25] = true, [26] = true,
  [27] = true, [28] = true, [29] = true, [31] = true, [32] = true,
  [37] = true, [38] = true, [39] = true, [40] = true, [41] = true,
  [42] = true, [43] = true, [44] = true, [46] = true, [47] = true,
  [48] = true, [49] = true, [50] = true, [51] = true, [52] = true,
  [53] = true, [54] = true, [55] = true, [56] = true, [57] = true,
  [58] = true, [59] = true, [60] = true, [62] = true, [65] = true,
  [66] = true, [67] = true, [68] = true, [69] = true, [70] = true,
  [71] = true, [73] = true, [74] = true, [75] = true, [76] = true,
  [77] = true, [78] = true, [79] = true, [80] = true,
}

-- The v12 defaults, by settings key; the migration and the fallback use them.
M.V12_ICON = { icon_startable = 52, icon_in_progress = 0, icon_completed = 42,
  icon_unavailable = 21, icon_locked = 41, icon_quest_item = 53,
  icon_chest = 31, icon_treasure = 58, icon_monster = 29, icon_seller = 13,
  icon_token = 57, icon_beetle = 73,
  icon_npc_search = 31, icon_route_stop = 25, icon_hint_pin = 58,
  icon_focus_place = 26 }
M.V12_COLOR = { icon_color = 0xFF960707, color_in_progress = 0xFFD7A500,
  color_completed = 0xFF2E8B57, color_unavailable = 0xFF787878,
  color_locked = 0xFF46468C, color_quest_item = 0xFF00C8FF,
  color_chest = 0xFFC08040, color_treasure = 0xFFFFD700,
  color_monster = 0xFFE04040, color_seller = 0xFF40C0E0,
  color_token = 0xFFB080FF, color_beetle = 0xFF60E060 }

-- A stored boolean is kept verbatim (a stored false on a default-on
-- toggle must survive reload); anything else takes the default.
local function bool_field(raw, k, d)
  if type(raw[k]) == "boolean" then return raw[k] end
  return d[k]
end

local function is_argb(v)
  return type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 0xFFFFFFFF
end
local function argb_field(raw, k, d)
  local v = raw[k]
  if is_argb(v) then
    return v
  end
  return d[k]
end

-- Keeps a stored number iff it is a real number (rejects NaN) within
-- [lo, hi] inclusive (rejects ±inf); anything else takes the default.
local function range_field(raw, k, d, lo, hi)
  local v = raw[k]
  if type(v) == "number" and v == v and v >= lo and v <= hi then return v end
  return d[k]
end

-- Floors a number and clamps it to [lo, hi].
function M.clamp_int(v, lo, hi)
  if v ~= v then return lo end   -- NaN
  v = math.floor(v)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- The most world markers the cap setting allows.
M.WORLD_MAX_MARKERS = 900

-- Floors a stored number and clamps it to [lo, hi]; non-numbers (and
-- NaN) take the default.
local function int_field(raw, k, d, lo, hi)
  local v = raw[k]
  if type(v) ~= "number" or v ~= v then return d[k] end
  return M.clamp_int(v, lo, hi)
end

-- The eleven world-tracker toggles, in UI / debug-setter order.
M.WORLD_BOOLS = { "world_chests", "world_treasure", "world_tokens",
  "world_first_token", "world_beetles", "world_monsters", "world_small_monsters",
  "world_sellers", "world_shops", "world_show_opened", "world_undiscovered" }

-- Toggles the "Not searched (off)" line never lists.
M.WORLD_NO_SEARCH = { world_show_opened = true, world_undiscovered = true,
  world_shops = true, world_first_token = true }

-- Tokens and Monsters each pair two keys in one tree node (SPEC 28.9.4,
-- 28.12.1; Monsters draws them as class nodes with kinds, 29.2): first box key -> { tree id, second box key }. WORLD_TREE_SECOND
-- is the set of second-box keys (drawn with their first, not on their own).
M.WORLD_TREES = { world_tokens = { "Seeker's Tokens##wtok", "world_first_token" },
  world_monsters = { "Monsters##wmon", "world_small_monsters" } }
M.WORLD_TREE_SECOND = {}
for _, tr in pairs(M.WORLD_TREES) do M.WORLD_TREE_SECOND[tr[2]] = true end

-- Median of a list of numbers (SPEC 28.11.2): the lower middle element for
-- an even count, nil for an empty list. Sorts a copy.
function M.median(list)
  local n = #list
  if n == 0 then return nil end
  local s = table.move(list, 1, n, 1, {})
  table.sort(s)
  return s[(n + 1) // 2]
end

-- True when any world toggle changed either way (off-to-on or on-to-off)
-- between `prev` and `settings`; then records every toggle's current value
-- into `prev`.
function M.world_toggled(prev, settings)
  local turned = false
  for _, k in ipairs(M.WORLD_BOOLS) do
    local on = settings[k] == true
    if on ~= (prev[k] == true) then turned = true end
    prev[k] = on
  end
  return turned
end

-- The five chest kind filters (SPEC 27.6), in the order of the kinds.
M.WORLD_KIND_BOOLS = { "world_kind_ng_shard", "world_kind_kept",
  "world_kind_quest", "world_kind_trap", "world_kind_pawn" }

-- Display names: per world category (icon rows, World panel) and per toggle
-- (World markers settings node).
M.WORLD_LABEL = { chest = "Chests", treasure = "Treasure spots",
  token = "Seeker's Tokens", beetle = "Golden Trove Beetles",
  monster = "Monsters", seller = "Quest-item sellers",
  shop = "Shop stock", shops = "Shops",
  npc_search = "NPCs", route_stop = "Route stops", hint_pin = "Hint pins" }
M.WORLD_BOOL_LABEL = { world_chests = M.WORLD_LABEL.chest,
  world_treasure = M.WORLD_LABEL.treasure, world_tokens = "All Seeker's Tokens",
  world_first_token = "Finder's Token spot (first token found)",
  world_beetles = M.WORLD_LABEL.beetle, world_monsters = "Large monsters",
  world_small_monsters = "Small monsters", world_sellers = M.WORLD_LABEL.seller,
  world_shops = M.WORLD_LABEL.shops,
  world_show_opened = "Show opened and collected",
  world_undiscovered = "Show undiscovered areas",
  world_kind_ng_shard = "New shard each cycle",
  world_kind_kept = "Stays opened in NG+", world_kind_quest = "Quest-gated",
  world_kind_trap = "Trap", world_kind_pawn = "Pawns can't open" }

local BOOL_KEYS = { "enabled", "debug", "show_startable", "show_in_progress",
  "show_completed", "show_unavailable", "show_locked", "show_overhead",
  "hide_overhead_in_cutscenes_and_menus", "show_minimap",
  "reveal_gate_names", "show_quest_items", "journal_spoilers",
  "matching_icons", "step_icons", "inventory_quest_marks", "route_world_path",
  "coords_map_cursor", "coords_minimap", "focus_tracked", "route_legend",
  "focus_place_routes" }
for _, k in ipairs(M.WORLD_BOOLS) do BOOL_KEYS[#BOOL_KEYS + 1] = k end
for _, k in ipairs(M.WORLD_KIND_BOOLS) do BOOL_KEYS[#BOOL_KEYS + 1] = k end
local COLOR_KEYS = { "icon_color", "color_in_progress", "color_completed",
  "color_unavailable", "color_locked", "color_quest_item",
  "color_chest", "color_treasure", "color_monster", "color_seller",
  "color_token", "color_beetle",
  "color_npc_search", "color_hint_pin", "color_focus_place" }
local ICON_KEYS = { "icon_startable", "icon_in_progress", "icon_completed",
  "icon_unavailable", "icon_locked", "icon_quest_item",
  "icon_chest", "icon_treasure", "icon_monster", "icon_seller",
  "icon_token", "icon_beetle",
  "icon_npc_search", "icon_route_stop", "icon_hint_pin", "icon_focus_place" }
M.ICON_KEYS, M.COLOR_KEYS = ICON_KEYS, COLOR_KEYS

-- The v14 style keys by field rule (SPEC 23.4). route_number_size and
-- route_path have their own rules and are not in these lists.
local STYLE_BOOL_KEYS = { "outline_on", "route_gradient" }
local STYLE_COLOR_KEYS = { "outline_color", "route_gradient_end",
  "route_number_color", "names_color" }
local STYLE_INT_RANGE = { outline_width = { 1, 4 }, route_line_width = { 1, 8 },
  route_stop_size = { 50, 200 }, route_gradient_amount = { 0, 100 },
  route_gradient_alpha = { 0, 100 } }
for _, g in ipairs(style.GROUPS) do
  local p = "style_" .. g .. "_"
  STYLE_BOOL_KEYS[#STYLE_BOOL_KEYS + 1] = p .. "override"
  STYLE_BOOL_KEYS[#STYLE_BOOL_KEYS + 1] = p .. "outline_on"
  STYLE_COLOR_KEYS[#STYLE_COLOR_KEYS + 1] = p .. "outline_color"
  STYLE_INT_RANGE[p .. "outline_width"] = { 1, 4 }
end
M.STYLE_BOOL_KEYS, M.STYLE_COLOR_KEYS, M.STYLE_INT_RANGE =
  STYLE_BOOL_KEYS, STYLE_COLOR_KEYS, STYLE_INT_RANGE

-- Number size: non-number or below 1 -> 0 (auto); 1-11 -> 12; above 40 -> 40;
-- else floored.
local function number_size_field(raw, k)
  local v = raw[k]
  if type(v) ~= "number" or v ~= v or v < 1 then return 0 end
  if v < 12 then return 12 end
  if v > 40 then return 40 end
  return math.floor(v)
end

-- Panel order (SPEC 23.7): every settings key the panel shows, once.
local panel_world = {}
for _, k in ipairs(M.WORLD_BOOLS) do panel_world[#panel_world + 1] = k end
for _, k in ipairs(M.WORLD_KIND_BOOLS) do panel_world[#panel_world + 1] = k end
panel_world[#panel_world + 1] = "world_max_markers"
panel_world[#panel_world + 1] = "world_monster_off"
local panel_appearance = {}
do
  local a = panel_appearance
  for _, t in ipairs({ STYLE_BOOL_KEYS, STYLE_COLOR_KEYS }) do
    for _, k in ipairs(t) do a[#a + 1] = k end
  end
  local ks = {}
  for k in pairs(STYLE_INT_RANGE) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do a[#a + 1] = k end
  a[#a + 1] = "route_number_size"
  a[#a + 1] = "route_colors"
  for _, k in ipairs(ICON_KEYS) do a[#a + 1] = k end
  for _, k in ipairs(COLOR_KEYS) do a[#a + 1] = k end
end
M.PANEL_ORDER = {
  { id = "enabled", keys = { "enabled" } },
  { id = "search", keys = { "search_text" } },
  { id = "quests", keys = { "show_startable", "show_in_progress",
    "show_completed", "show_unavailable", "show_locked", "show_quest_items",
    "reveal_gate_names", "journal_spoilers", "step_icons" } },
  { id = "world_markers", keys = panel_world },
  { id = "npcs", keys = { "show_overhead", "hide_overhead_in_cutscenes_and_menus", "overhead_distance",
    "overhead_names", "route_path", "route_world_path", "route_legend" } },
  { id = "items", keys = { "inventory_quest_marks" } },
  { id = "map", keys = { "show_minimap", "matching_icons",
    "coords_map_cursor", "coords_minimap" } },
  { id = "appearance", keys = panel_appearance },
  { id = "quest_tree", keys = { "focus_qids", "focus_tracked", "focus_unrelated",
    "focus_dim_alpha", "focus_routes", "focus_place_routes" } },
  { id = "world", keys = {} },
  { id = "status", keys = { "debug" } },
}
-- Settings keys that have no panel control.
M.NO_CONTROL_KEYS = { "palette" }

-- Search text: non-string -> ""; at most 64 bytes, cut back to the last
-- complete UTF-8 character.
function M.cut_search(s)
  if type(s) ~= "string" then return "" end
  if #s <= 64 then return s end
  local n = 64
  -- a continuation byte (10xxxxxx) at n+1 means the char straddles the cut
  while n > 0 do
    local b = s:byte(n + 1)
    if b and b >= 0x80 and b < 0xC0 then n = n - 1 else break end
  end
  return s:sub(1, n)
end

-- The one rule per key, read by validate and set_key. kind: "bool", "color",
-- "icon", "int" (floored, clamped to lo..hi), "float" (kept iff within lo..hi,
-- else default), "size" (number_size_field), "text" (cut_search).
local RULE = {}
for _, k in ipairs(BOOL_KEYS) do RULE[k] = { "bool" } end
for _, k in ipairs(STYLE_BOOL_KEYS) do RULE[k] = { "bool" } end
for _, k in ipairs(COLOR_KEYS) do RULE[k] = { "color" } end
for _, k in ipairs(STYLE_COLOR_KEYS) do RULE[k] = { "color" } end
for _, k in ipairs(ICON_KEYS) do RULE[k] = { "icon" } end
for k, r in pairs(STYLE_INT_RANGE) do RULE[k] = { "int", r[1], r[2] } end
RULE.overhead_distance = { "float", 10, 200 }
RULE.world_max_markers = { "int", 0, M.WORLD_MAX_MARKERS }
RULE.overhead_names = { "int", 0, 2 }
RULE.route_path = { "int", 0, 1 }
RULE.route_number_size = { "size" }
RULE.search_text = { "text" }
RULE.focus_unrelated = { "int", 0, 1 }
RULE.focus_routes = { "int", 0, 2 }
RULE.focus_qids = { "qid_list" }
RULE.focus_dim_alpha = { "int", 5, 100 }
RULE.route_colors = { "color_list", M.ROUTE_SLOTS }

local QID_MAX = 16
M.QID_MAX = QID_MAX
-- Whole numbers above 0, repeats dropped, first 16; a non-table gives an empty list.
local function qid_list_field(v)
  local out = {}
  if type(v) ~= "table" then return out end
  local seen = {}
  for _, x in ipairs(v) do
    if type(x) == "number" then
      local n = math.tointeger(x)
      if n and n > 0 and not seen[n] then
        seen[n] = true
        out[#out + 1] = n
        if #out >= QID_MAX then break end
      end
    end
  end
  return out
end

-- Exactly n colours: each entry through the color rule, default i when it
-- fails; a non-table gives the defaults. Always a new table.
local function color_list_field(v, n)
  local out = {}
  local dl = M.default_route_colors()
  for i = 1, n do
    local e = type(v) == "table" and v[i] or nil
    if is_argb(e) then
      out[i] = e
    else
      out[i] = dl[i]
    end
  end
  return out
end

-- The validated value of raw[k] under its rule (the default when invalid).
local function field(raw, k, d)
  local r = RULE[k]
  local kind = r[1]
  if kind == "bool" then return bool_field(raw, k, d)
  elseif kind == "color" then return argb_field(raw, k, d)
  elseif kind == "icon" then return M.ICON_INDEX[raw[k]] and raw[k] or d[k]
  elseif kind == "int" then return int_field(raw, k, d, r[2], r[3])
  elseif kind == "float" then return range_field(raw, k, d, r[2], r[3])
  elseif kind == "size" then return number_size_field(raw, k)
  elseif kind == "qid_list" then return qid_list_field(raw[k])
  elseif kind == "color_list" then return color_list_field(raw[k], r[2])
  end
  return M.cut_search(raw[k])
end

-- The off sets of one class: string keys of 1 to 64 bytes with the value
-- true, holding kind names and family entries ("fam:" plus the 5-byte family
-- id, SPEC 30.6.1). At most MONSTER_OFF_MAX kept: family entries first, then
-- kinds, each group in byte order.
M.MONSTER_OFF_MAX = 200
M.MONSTER_KIND_MAX = 64
local FAM_PREFIX = "fam:"
function M.fam_key(fam) return FAM_PREFIX .. fam end
local function is_fam_key(k)
  return type(k) == "string" and k:sub(1, #FAM_PREFIX) == FAM_PREFIX
end
local function off_class(t)
  local out = {}
  if type(t) ~= "table" then return out end
  local keys = {}
  for k, v in pairs(t) do
    if type(k) == "string" and v == true and #k >= 1 and #k <= M.MONSTER_KIND_MAX
        and (not is_fam_key(k) or #k == #FAM_PREFIX + 5) then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys, function(a, b)
    local fa, fb = is_fam_key(a), is_fam_key(b)
    if fa ~= fb then return fa end
    return a < b
  end)
  for i = 1, math.min(#keys, M.MONSTER_OFF_MAX) do out[keys[i]] = true end
  return out
end

-- Sorted union of the kinds seen and the kinds switched off in one class
-- (nil inputs read as empty); family entries are not kinds and are skipped.
function M.monster_kind_list(seen, off)
  local set, list = {}, {}
  for _, t in ipairs({ seen or {}, off or {} }) do
    for k in pairs(t) do
      if type(k) == "string" and not is_fam_key(k) and not set[k] then
        set[k] = true; list[#list + 1] = k
      end
    end
  end
  table.sort(list)
  return list
end

-- Number of true entries in one class's off set (0 for a non-table); kind
-- and family entries both count toward the cap.
function M.monster_class_off_count(t)
  if type(t) ~= "table" then return 0 end
  local n = 0
  for _, v in pairs(t) do if v == true then n = n + 1 end end
  return n
end

-- Off entries over both classes: kind entries, then family entries (0, 0 for
-- anything but a table).
function M.monster_off_count(off)
  if type(off) ~= "table" then return 0, 0 end
  local kinds, fams = 0, 0
  for _, c in ipairs({ "large", "small" }) do
    if type(off[c]) == "table" then
      for k, v in pairs(off[c]) do
        if v == true then
          if is_fam_key(k) then fams = fams + 1 else kinds = kinds + 1 end
        end
      end
    end
  end
  return kinds, fams
end

-- State of one kind checkbox: "disabled" when its class is off, its family
-- is off, the name is too long to store, or the class is at the off cap and
-- the kind is still on; else "off" or "on". off_count counts this class only.
function M.kind_box(name, class_on, off_count, is_off, fam_off)
  if fam_off or #name > M.MONSTER_KIND_MAX then return "disabled" end
  return M.family_box(class_on, off_count, is_off)
end

-- State of one family checkbox: "disabled" when the class is off, or the
-- family is on and the class is at the off cap; else "off" or "on".
function M.family_box(class_on, off_count, is_off)
  if not class_on then return "disabled" end
  if not is_off and off_count >= M.MONSTER_OFF_MAX then return "disabled" end
  return is_off and "off" or "on"
end

-- The draw list of one class's kind tree (SPEC 30.3.1). seen_class is
-- { [fam] = { [kind] = true } }, fam_names_class { [fam] = name }, offs the
-- class's off set. In order: one entry per family except "?" (display name,
-- then fam), then one plain entry for the "?" kinds and the off kinds seen
-- in no family, then one entry per off family entry not seen.
function M.monster_tree(seen_class, fam_names_class, offs, class_on)
  seen_class = seen_class or {}
  fam_names_class = fam_names_class or {}
  offs = offs or {}
  local n_off = M.monster_class_off_count(offs)
  local function name_of(fam) return fam_names_class[fam] or fam end
  local fams = {}
  for fam in pairs(seen_class) do
    if fam ~= "?" then fams[#fams + 1] = fam end
  end
  table.sort(fams, function(a, b)
    local na, nb = name_of(a), name_of(b)
    if na ~= nb then return na < nb end
    return a < b
  end)
  local out, in_fam = {}, {}
  for _, fam in ipairs(fams) do
    local fam_off = offs[FAM_PREFIX .. fam] == true
    local kinds = {}
    for _, kind in ipairs(M.monster_kind_list(seen_class[fam])) do
      in_fam[kind] = true
      kinds[#kinds + 1] = { kind = kind, off = offs[kind] == true,
        box = M.kind_box(kind, class_on, n_off, offs[kind] == true, fam_off) }
    end
    out[#out + 1] = { fam = fam, name = name_of(fam), node = #kinds >= 2 or fam_off,
      family_box = M.family_box(class_on, n_off, fam_off), kinds = kinds }
  end
  local plain = {}
  for _, kind in ipairs(M.monster_kind_list(seen_class["?"], offs)) do
    if (seen_class["?"] and seen_class["?"][kind]) or not in_fam[kind] then
      plain[#plain + 1] = { kind = kind, off = offs[kind] == true,
        box = M.kind_box(kind, class_on, n_off, offs[kind] == true, false) }
    end
  end
  if #plain > 0 then out[#out + 1] = { plain = true, kinds = plain } end
  local unseen = {}
  for k, v in pairs(offs) do
    if v == true and is_fam_key(k) and seen_class[k:sub(#FAM_PREFIX + 1)] == nil then
      unseen[#unseen + 1] = k:sub(#FAM_PREFIX + 1)
    end
  end
  table.sort(unseen)
  for _, fam in ipairs(unseen) do
    out[#out + 1] = { fam = fam, unseen = true,
      family_box = M.family_box(class_on, n_off, true) }
  end
  return out
end

-- The parts of the "Not searched (off)" line (SPEC 30.6.8): each searchable
-- world toggle that is off, then the off monster kind and family counts.
function M.not_searched(settings)
  local off = {}
  for _, k in ipairs(M.WORLD_BOOLS) do
    if not M.WORLD_NO_SEARCH[k] and not settings[k] then
      off[#off + 1] = string.lower(M.WORLD_BOOL_LABEL[k])
    end
  end
  local kn, fn = M.monster_off_count(settings.world_monster_off)
  if kn > 0 then off[#off + 1] = kn .. " monster kinds" end
  if fn > 0 then off[#off + 1] = fn .. " monster families" end
  return off
end

-- Switch one kind off (off == true) or on in settings.world_monster_off
-- (SPEC 29.6.4). False and no change for a bad class, a bad kind, or a
-- class already at the cap; the tables are created when missing.
function M.set_kind_off(settings, class, kind, off)
  if class ~= "large" and class ~= "small" then return false end
  if type(kind) ~= "string" or #kind < 1 or #kind > M.MONSTER_KIND_MAX then return false end
  if is_fam_key(kind) and #kind ~= #FAM_PREFIX + 5 then return false end
  local o = settings.world_monster_off
  if type(o) ~= "table" then o = { large = {}, small = {} }; settings.world_monster_off = o end
  if type(o[class]) ~= "table" then o[class] = {} end
  if off == true then
    if o[class][kind] ~= true and M.monster_class_off_count(o[class]) >= M.MONSTER_OFF_MAX then
      return false
    end
    o[class][kind] = true
  else
    o[class][kind] = nil
  end
  return true
end

function M.kind_empty_text(class_on)
  return class_on and "No kinds seen yet" or "Turn on to list kinds"
end

function M.validate(raw)
  local d = M.defaults()
  if type(raw) ~= "table" then return d end
  local out = {}
  -- One-time palette migration (21.7.6): below palette 13 a stored value
  -- equal to its v12 default takes the v13 default; a changed one stays.
  local mig = type(raw.palette) ~= "number" or raw.palette < 13
  for _, k in ipairs(BOOL_KEYS) do out[k] = field(raw, k, d) end
  for _, p in ipairs({ { COLOR_KEYS, M.V12_COLOR }, { ICON_KEYS, M.V12_ICON } }) do
    for _, k in ipairs(p[1]) do
      if mig and raw[k] == p[2][k] then out[k] = d[k]
      else out[k] = field(raw, k, d) end
    end
  end
  out.palette = 13
  for _, k in ipairs(STYLE_BOOL_KEYS) do out[k] = field(raw, k, d) end
  for _, k in ipairs(STYLE_COLOR_KEYS) do out[k] = field(raw, k, d) end
  for _, k in ipairs({ "overhead_distance", "world_max_markers", "search_text",
    "overhead_names", "route_number_size", "route_path", "focus_qids",
    "focus_unrelated", "focus_routes", "focus_dim_alpha" }) do
    out[k] = field(raw, k, d)
  end
  -- route_colors; the retired route_line_color seeds entry 1 when no list
  -- is stored (SPEC 32.14.2.2). route_line_color is never written back.
  if type(raw.route_colors) ~= "table" and type(raw.route_line_color) == "number"
      and raw.route_line_color ~= ROUTE_COLORS[1] then
    out.route_colors = field({ route_colors = { raw.route_line_color } }, "route_colors", d)
  else
    out.route_colors = field(raw, "route_colors", d)
  end
  for k in pairs(STYLE_INT_RANGE) do out[k] = field(raw, k, d) end
  local mo = type(raw.world_monster_off) == "table" and raw.world_monster_off or {}
  out.world_monster_off = { large = off_class(mo.large), small = off_class(mo.small) }
  return out
end

-- Validates one key through its field rule and writes it (no palette
-- migration). False, with no write, for an unknown key or a value of the
-- wrong type. Int keys clamp; float keys (overhead_distance) reject a value
-- outside the range.
local DEFAULTS
function M.set_key(settings, key, v)
  local r = RULE[key]
  if not r then return false end
  DEFAULTS = DEFAULTS or M.defaults()
  local kind = r[1]
  local want = (kind == "bool" and "boolean")
    or ((kind == "int" or kind == "float" or kind == "size") and "number")
    or (kind == "text" and "string") or (kind == "qid_list" and "table")
    or (kind == "color_list" and "table") or nil
  if want and (type(v) ~= want or v ~= v) then return false end
  if kind == "color_list" then
    if #v ~= r[2] then return false end
    for i = 1, r[2] do
      if not is_argb(v[i]) then return false end
    end
  end
  local out = field({ [key] = v }, key, DEFAULTS)
  if (kind == "color" or kind == "icon" or kind == "float") and out ~= v then
    return false
  end
  settings[key] = out
  return true
end

-- Category -> settings key, and the one color / icon rule for a category.
M.COLOR_KEY = {
  startable = "icon_color", in_progress = "color_in_progress",
  completed = "color_completed", unavailable = "color_unavailable",
  locked = "color_locked", quest_item = "color_quest_item",
  chest = "color_chest", treasure = "color_treasure",
  monster = "color_monster", seller = "color_seller", shop = "color_seller",
  token = "color_token", beetle = "color_beetle",
  npc_search = "color_npc_search", hint_pin = "color_hint_pin",
  focus_npc = "color_npc_search", focus_place = "color_focus_place",
}
M.ICON_KEY = {
  startable = "icon_startable", in_progress = "icon_in_progress",
  completed = "icon_completed", unavailable = "icon_unavailable",
  locked = "icon_locked", quest_item = "icon_quest_item",
  chest = "icon_chest", treasure = "icon_treasure",
  monster = "icon_monster", seller = "icon_seller", shop = "icon_seller",
  token = "icon_token", beetle = "icon_beetle",
  npc_search = "icon_npc_search", route_stop = "icon_route_stop",
  hint_pin = "icon_hint_pin",
  focus_npc = "icon_npc_search", focus_place = "icon_focus_place",
}
function M.color_of(settings, cat)
  return settings[M.COLOR_KEY[cat]] or settings.icon_color
end
function M.icon_of(settings, cat)
  return settings[M.ICON_KEY[cat]] or settings.icon_startable
end

-- The icon id a surface draws. sheet: "map", "mini" or "head". A step
-- number (21.8) wins over the category icon. When the id cannot be drawn
-- (drawable(id) false) and has no art on the sheet, or on "mini" when the
-- v12 icon is drawable instead, the v12 icon replaces it; "head" never
-- substitutes (no game glyph there).
function M.icon_for(settings, m, sheet, step, drawable)
  local id = step or M.icon_of(settings, m.cat)
  if sheet == "head" or drawable(id) then return id end
  local v12 = M.V12_ICON[M.ICON_KEY[m.cat]]
  if not v12 then return id end
  local has = (sheet == "map") and M.HAS_FULLMAP or M.HAS_MINIMAP
  if not has[id] then return v12 end
  if sheet == "mini" and drawable(v12) then return v12 end
  return id
end

-- Every icon, color and style key back to its default; route_path,
-- route_world_path and everything else stay.
function M.reset_appearance(settings)
  local d = M.defaults()
  for _, list in ipairs({ ICON_KEYS, COLOR_KEYS, STYLE_BOOL_KEYS, STYLE_COLOR_KEYS }) do
    for _, k in ipairs(list) do settings[k] = d[k] end
  end
  for k in pairs(STYLE_INT_RANGE) do settings[k] = d[k] end
  settings.route_number_size = d.route_number_size
  settings.route_colors = d.route_colors
end

-- Marker color: the category color (the route colour for a route stop), alpha
-- byte halved when the marker is done (opened / looted) or faded (SPEC 27.6),
-- scaled by focus_dim_alpha when dim (SPEC 32.14.6); the lowest when several apply.
function M.marker_color(settings, m)
  local c
  if m.cat == "route_stop" then
    local rc = settings.route_colors
    c = rc and (rc[m.slot] or rc[1]) or ROUTE_COLORS[1]
  else
    c = M.color_of(settings, m.cat)
  end
  if not (m.done or m.faded or m.dim) then return c end
  local a0 = (c >> 24) & 0xFF
  local a = a0
  if m.done or m.faded then a = a0 // 2 end
  if m.dim then
    local da = a0 * (settings.focus_dim_alpha or DIM_ALPHA_DEFAULT) // 100
    if da < a then a = da end
  end
  return (a << 24) | (c & 0x00FFFFFF)
end

-- One-time migration from the pre-rename data file names: load the new
-- name; when it is missing (or unreadable) load the old name instead. The old
-- file is never touched; callers always save under the new name.
function M.load_with_legacy(load, path, legacy_path)
  local ok, v = pcall(load, path)
  if ok and v ~= nil then return v end
  if legacy_path == nil then return nil end
  local ok2, v2 = pcall(load, legacy_path)
  if ok2 then return v2 end
  return nil
end

return M
