-- settings_util.lua — pure validation; no sdk/json.
local M = {}

function M.defaults()
  return {
    enabled = true, show_minimap = true, icon_color = 0xFF960707, debug = false,
    icon_startable = 52, icon_in_progress = 0, icon_completed = 42,
    icon_unavailable = 21, icon_locked = 41, icon_quest_item = 53,
    show_startable = true, show_in_progress = true,
    show_completed = false, show_unavailable = false, show_locked = false,
    color_in_progress = 0xFFD7A500, color_completed = 0xFF2E8B57,
    color_unavailable = 0xFF787878, color_locked = 0xFF46468C,
    show_overhead = true, overhead_distance = 50.0,
    reveal_gate_names = false, journal_spoilers = false,
    show_quest_items = true, color_quest_item = 0xFF00C8FF,
    world_chests = true, world_treasure = true, world_monsters = true,
    world_sellers = true, world_shops = false, world_show_opened = false, world_undiscovered = false,
    color_chest = 0xFFC08040, color_treasure = 0xFFFFD700,
    color_monster = 0xFFE04040, color_seller = 0xFF40C0E0,
    icon_chest = 31, icon_treasure = 58, icon_monster = 29, icon_seller = 13,
    world_max_markers = 300,
    world_tokens = true, world_beetles = true, world_small_monsters = false,
    color_token = 0xFFB080FF, color_beetle = 0xFF60E060,
    icon_token = 57, icon_beetle = 73,
    search_text = "",
  }
end

-- Icon types drawn by BOTH atlases (map UVS_map_01, minimap UVS_map_03)
-- at the same index, read from the game files 2026-10-19; the picker
-- offers only these, so a category's icon matches on map and minimap.
-- Excluded although both atlases draw them (SPEC 2.2): 6, 7, 23, 55
-- (another mod scans them as warp/camp types) and 76-80 (the
-- custom-artwork range).
M.ICON_CHOICES = {
  { 0, "Quest (gold cross)" }, { 1, "Hex I" }, { 2, "Hex II" },
  { 3, "Hex III" }, { 4, "Hex IV" }, { 5, "Hex V" }, { 8, "Riftstone" }, { 9, "Inn" }, { 10, "Weapons" },
  { 11, "Armor" }, { 12, "Apothecary" }, { 13, "Scrap store" },
  { 14, "Vocation guild" }, { 15, "Ox" }, { 16, "Barber" }, { 17, "Rose" },
  { 18, "Tavern" }, { 19, "Hot spring" }, { 20, "Dragonforged" },
  { 21, "Coffin" }, { 22, "House" }, { 24, "Oracle" },
  { 25, "Lantern" }, { 26, "Exit arrow" }, { 27, "Rooster" },
  { 28, "Bench" }, { 29, "Red claw" }, { 31, "Small diamond" },
  { 32, "Rock arch" }, { 37, "Rock" }, { 38, "Shrine door" },
  { 39, "Red meat" }, { 41, "Archway" }, { 42, "Archway (check)" },
  { 43, "Red swirl" }, { 49, "Purple swirl" }, { 51, "Statue" },
  { 52, "Diamond flag" }, { 53, "Basket" }, { 54, "Anvil" },
  { 57, "Triquetra" }, { 58, "Gold diamond" },
  { 59, "Hammer" }, { 60, "Scepter" }, { 62, "Dark statue" },
  { 73, "Red glow" },
}
M.ICON_LABELS, M.ICON_INDEX = {}, {}
for i, c in ipairs(M.ICON_CHOICES) do
  M.ICON_LABELS[i] = string.format("%s (%d)", c[2], c[1])
  M.ICON_INDEX[c[1]] = i
end

-- A stored boolean is kept verbatim (a stored false on a default-on
-- toggle must survive reload); anything else takes the default.
local function bool_field(raw, k, d)
  if type(raw[k]) == "boolean" then return raw[k] end
  return d[k]
end

local function argb_field(raw, k, d)
  local v = raw[k]
  if type(v) == "number" and v == math.floor(v)
    and v >= 0 and v <= 0xFFFFFFFF then
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

-- The ten world-tracker toggles, in UI / debug-setter order.
M.WORLD_BOOLS = { "world_chests", "world_treasure", "world_tokens",
  "world_beetles", "world_monsters", "world_small_monsters",
  "world_sellers", "world_shops", "world_show_opened", "world_undiscovered" }

-- Display names: per world category (icon rows, World panel) and per toggle
-- (World markers settings node).
M.WORLD_LABEL = { chest = "Chests", treasure = "Treasure spots",
  token = "Seeker's Tokens", beetle = "Golden Trove Beetles",
  monster = "Monsters", seller = "Quest-item sellers",
  shop = "Shop stock", shops = "Shops" }
M.WORLD_BOOL_LABEL = { world_chests = M.WORLD_LABEL.chest,
  world_treasure = M.WORLD_LABEL.treasure, world_tokens = M.WORLD_LABEL.token,
  world_beetles = M.WORLD_LABEL.beetle, world_monsters = "Large monsters",
  world_small_monsters = "Small monsters", world_sellers = M.WORLD_LABEL.seller,
  world_shops = M.WORLD_LABEL.shops,
  world_show_opened = "Show opened and collected",
  world_undiscovered = "Show undiscovered areas" }

local BOOL_KEYS = { "enabled", "debug", "show_startable", "show_in_progress",
  "show_completed", "show_unavailable", "show_locked", "show_overhead", "show_minimap",
  "reveal_gate_names", "show_quest_items", "journal_spoilers" }
for _, k in ipairs(M.WORLD_BOOLS) do BOOL_KEYS[#BOOL_KEYS + 1] = k end
local COLOR_KEYS = { "icon_color", "color_in_progress", "color_completed",
  "color_unavailable", "color_locked", "color_quest_item",
  "color_chest", "color_treasure", "color_monster", "color_seller",
  "color_token", "color_beetle" }
local ICON_KEYS = { "icon_startable", "icon_in_progress", "icon_completed",
  "icon_unavailable", "icon_locked", "icon_quest_item",
  "icon_chest", "icon_treasure", "icon_monster", "icon_seller",
  "icon_token", "icon_beetle" }

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

function M.validate(raw)
  local d = M.defaults()
  if type(raw) ~= "table" then return d end
  local out = {}
  for _, k in ipairs(BOOL_KEYS) do out[k] = bool_field(raw, k, d) end
  for _, k in ipairs(COLOR_KEYS) do out[k] = argb_field(raw, k, d) end
  for _, k in ipairs(ICON_KEYS) do
    out[k] = M.ICON_INDEX[raw[k]] and raw[k] or d[k]
  end
  out.overhead_distance = range_field(raw, "overhead_distance", d, 10, 200)
  out.world_max_markers = int_field(raw, "world_max_markers", d, 0, M.WORLD_MAX_MARKERS)
  out.search_text = M.cut_search(raw.search_text)
  return out
end

-- Category -> settings key, and the one color / icon rule for a category.
M.COLOR_KEY = {
  startable = "icon_color", in_progress = "color_in_progress",
  completed = "color_completed", unavailable = "color_unavailable",
  locked = "color_locked", quest_item = "color_quest_item",
  chest = "color_chest", treasure = "color_treasure",
  monster = "color_monster", seller = "color_seller", shop = "color_seller",
  token = "color_token", beetle = "color_beetle",
}
M.ICON_KEY = {
  startable = "icon_startable", in_progress = "icon_in_progress",
  completed = "icon_completed", unavailable = "icon_unavailable",
  locked = "icon_locked", quest_item = "icon_quest_item",
  chest = "icon_chest", treasure = "icon_treasure",
  monster = "icon_monster", seller = "icon_seller", shop = "icon_seller",
  token = "icon_token", beetle = "icon_beetle",
}
function M.color_of(settings, cat)
  return settings[M.COLOR_KEY[cat]] or settings.icon_color
end
function M.icon_of(settings, cat)
  return settings[M.ICON_KEY[cat]] or settings.icon_startable
end

-- Marker color: the category color, alpha byte halved when the marker
-- is done (opened / looted).
function M.marker_color(settings, m)
  local c = M.color_of(settings, m.cat)
  if not m.done then return c end
  local a = (c >> 24) & 0xFF
  return ((a // 2) << 24) | (c & 0x00FFFFFF)
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
