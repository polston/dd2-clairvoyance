-- Source-level contracts for behavior that lives inside REFramework hooks and
-- cannot be loaded in the pure-Lua unit harness.
local f = assert(io.open("reframework/autorun/Clairvoyance.lua", "rb"))
local src = f:read("*a")
f:close()

local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

check("hook identity uses plain equality",
  src:find("local function same%(a, b%)%s+return a ~= nil and b ~= nil and a == b%s+end") ~= nil)
check("hook identity has no address fallback",
  src:find("a:get_address%(%) == b:get_address%(%)", 1, false) == nil)
check("removed fallback counter is not exposed",
  src:find("same_fallback_n", 1, true) == nil)

check("catalog side count helper removed",
  src:find("local function catalog_side_count", 1, true) == nil)
local catalog_reads = {}
for block in src:gmatch('"Catalog:.-cs%.distinct%)%)') do
  catalog_reads[#catalog_reads + 1] = block
end
local snapshot_count_reads = 0
for _ in src:gmatch("snapshot%.catalog_side_count") do
  snapshot_count_reads = snapshot_count_reads + 1
end
check("catalog log and panel use the snapshot count",
  #catalog_reads == 2 and snapshot_count_reads == 2
    and catalog_reads[1]:find("(snapshot and snapshot.catalog_side_count) or 0", 1, true) ~= nil
    and catalog_reads[2]:find("(snapshot and snapshot.catalog_side_count) or 0", 1, true) ~= nil)

if failures > 0 then os.exit(1) end
print("main_source_test: all OK")
