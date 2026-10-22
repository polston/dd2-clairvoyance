-- tests/minimap_test.lua — drives Clairvoyance/minimap.lua with
-- fake HUD + slots (SPEC §11.7a). Pure Lua; no sdk.
package.path = package.path .. ";./reframework/autorun/?.lua"
local mm = require("Clairvoyance.minimap")
local failures = 0
local function check(name, cond)
  if not cond then failures = failures + 1; print("FAIL: " .. name) end
end

local now = 0  -- injected clock
local next_addr = 100
local function fake_slot(visible)
  next_addr = next_addr + 1
  local s = { addr = next_addr, visible = visible or false, icon = 7,
    color = "native", pos = "p0", rot = 0, scale = 1.5,
    uvseq = 3, uvpat = 4, fail_restore = false, calls = {} }
  s.Sprite = {
    get_UVSequenceNo = function() return s.uvseq end,
    get_UVPatternNo = function() return s.uvpat end,
    set_UVSequenceNo = function(_, v) s.calls[#s.calls + 1] = "uvseq"; s.uvseq = v end,
    set_UVPatternNo = function(_, v) s.calls[#s.calls + 1] = "uvpat"; s.uvpat = v end,
  }
  function s:get_address() return self.addr end
  function s:get_Visible() return self.visible end
  function s:get_IconType() return self.icon end
  function s:get_Color() return self.color end
  function s:get_Position() return self.pos end
  function s:get_Rotation() return self.rot end
  function s:get_Scale() return self.scale end
  function s:set_Visible(v) self.calls[#self.calls + 1] = "vis"; self.visible = v end
  function s:set_IconType(v)
    self.calls[#self.calls + 1] = "icon"
    if self.fail_restore then error("setter fails") end
    self.icon = v
  end
  function s:set_Color(v) self.calls[#self.calls + 1] = "color"; self.color = v end
  function s:set_Position(v) self.calls[#self.calls + 1] = "pos"; self.pos = v end
  function s:set_Rotation(v) self.calls[#self.calls + 1] = "rot"; self.rot = v end
  function s:set_Scale(v) self.calls[#self.calls + 1] = "scale"; self.scale = v end
  return s
end

local function fake_hud(slots)
  return {
    IsInit = true, PlChara = {}, MapOutRange = 100,
    PlUPos = { x = 0, y = 0, z = 0 },
    MapIconList = {
      get_Count = function() return #slots end,
      get_Item = function(_, i) return slots[i + 1] end,
    },
    getIconPos = function(_, v) return { x = v.x, y = v.z } end,
  }
end

local settings = { enabled = true, show_minimap = true }
local snap = { markers = {} }
local cands = {}
local live = true
local function renderer()
  return mm.create({
    settings = settings,
    clock = function() return now end,
    vector = function(x, y, z) return { x = x, y = y, z = z } end,
    set_color = function(ref, argb) ref:set_Color("ours:" .. tostring(argb)) end,
    icon_for = function() return 2 end,
    color_for = function() return 255 end,
    snapshot = function() return snap end,
    candidates = function() return cands, (cands[1] and 5 or nil) end,
    is_live = function() return live end,
  })
end
local function marker(x) return { key = "k" .. x, pos = { x = x, y = 0, z = 0 } } end
local function new_snap() snap = { markers = {} } end

-- 1. first draw: borrow the free slot only; full restore on next PRE
local s1, s2 = fake_slot(true), fake_slot(false)
local hud = fake_hud({ s1, s2 })
local r = renderer()
cands = { marker(10) }
r:before(hud)
new_snap()  -- first HUD attach counts as a HUD change: wait wants a fresh snapshot
s2.rot = 9  -- prove draw sets rotation and restore brings it back
r:after(hud)
check("draws on the free slot", r.shown == 1 and s2.visible == true
  and s2.color == "ours:255" and s2.icon == 2 and s2.rot == 0
  and s2.scale == 1.5)
check("visible slot untouched", s1.color == "native" and #s1.calls == 0)
s2.uvseq, s2.uvpat = 99, 98  -- perturb so the UV restore is pinned too
s2.calls = {}
r:before(hud)
check("PRE restore: hide first", s2.calls[1] == "vis")
check("PRE restores every field", s2.visible == false and s2.icon == 7
  and s2.color == "native" and s2.pos == "p0" and s2.rot == 9
  and s2.scale == 1.5 and s2.uvseq == 3 and s2.uvpat == 4)
check("restored slot leaves the owned list", #r.owned == 0)

-- 2. restored slot is borrowable again
cands = { marker(10) }
r:after(hud)
check("re-borrowable after clean restore", r.shown == 1 and s2.visible == true)

-- 3. failed restore: raises (for the caller's log), stays owned, never
--    re-borrowed, retried, no corruption
s2.fail_restore = true
local okb = pcall(r.before, r, hud)
check("failed restore raises for logging", okb == false)
check("failed restore stays owned", #r.owned == 1)
check("hide-first ran before the failure", s2.visible == false)
cands = { marker(10), marker(20) }
local ok3 = pcall(r.after, r, hud)
check("failed slot not re-borrowed", ok3 and r.shown == 0 and r.dropped == 2)
s2.fail_restore = false
r:before(hud)
check("retry restores cleanly", #r.owned == 0 and s2.icon == 7
  and s2.color == "native")

-- 4. a slot reclaimed while hidden is dropped, not overwritten
cands = { marker(10) }
r:after(hud)
s2.fail_restore = true
pcall(r.before, r, hud)        -- hides, then fails: stays owned
s2.fail_restore = false
s2.visible = true s2.icon = 33 s2.pos = "gamepos"  -- game reclaimed it
r:before(hud)
check("reclaimed slot untouched",
  s2.visible == true and s2.icon == 33 and s2.pos == "gamepos"
  and #r.owned == 0)

-- 5. HUD change drops owned without touching old slots
cands = { marker(10) }
r:after(hud)
local writes_before = #s2.calls
local h2s = fake_slot(false)
local hud2 = fake_hud({ h2s })
r:before(hud2)
check("HUD change: old slot untouched", #s2.calls == writes_before)
check("HUD change: owned dropped", #r.owned == 0)

-- 6. after a HUD change, waits for a NEW snapshot object
cands = { marker(10) }
r:after(hud2)
check("waits for fresh snapshot after HUD change",
  r.shown == 0 and r.status == "waiting")
new_snap()
r:before(hud2); r:after(hud2)
check("draws once the snapshot changed", r.shown == 1)

-- 7. disabled POST draws nothing; PRE still restores
settings.show_minimap = false
r:before(hud2); r:after(hud2)
check("toggle off: nothing drawn, all restored",
  r.shown == 0 and r.status == "toggle" and #r.owned == 0)
settings.show_minimap = true

-- 8. nil snapshot: no draw, no raise, no slot calls
cands = { marker(10) }
snap = nil
r:before(hud2)
local calls8 = #h2s.calls
local okn = pcall(r.after, r, hud2)
check("nil snapshot safe", okn and r.status == "no snapshot" and r.shown == 0)
check("nil snapshot: no slot calls", #h2s.calls == calls8)
new_snap()

-- 9. clipping + exhaustion counts
local far = { key = "far", pos = { x = 500, y = 0, z = 0 } }
cands = { marker(10), far }
r:before(hud2)
new_snap()  -- (snap was replaced above; keep the object fresh after the nil)
r:after(hud2)
check("clip counted", r.clipped == 1 and r.shown == 1)

-- 10. MapOutRange nil: no draw, no error
hud2.MapOutRange = nil
r:before(hud2)
local okm = pcall(r.after, r, hud2)
check("MapOutRange nil safe", okm and r.status == "waiting")
hud2.MapOutRange = 100

-- 11. dead ref dropped without a single write
cands = { marker(10) }
r:before(hud2); r:after(hud2)
live = false
check("draw owned a slot", r.owned[1] ~= nil)
local owned_ref = r.owned[1].ref
local wb = #owned_ref.calls
r:before(hud2)
check("dead ref dropped, never written", #r.owned == 0 and #owned_ref.calls == wb)
live = true

-- 12. suspension: POST skipped, PRE still restores; cleared by
--     clear_suspension and by a HUD change; record_post trips at 30
local ss = fake_slot(false)
local hud3 = fake_hud({ ss })
cands = { marker(10) }
r:before(hud3)
new_snap()
r:after(hud3)
check("susp setup draws", r.shown == 1 and ss.visible == true)
r.suspended_until = 1e9 r.status = "paused: x"
r:before(hud3); r:after(hud3)
check("suspended: PRE restored, POST drew nothing",
  ss.visible == false and #r.owned == 0 and r.shown == 0
  and r.status == "paused: x")
r:clear_suspension()
r:before(hud3); r:after(hud3)
check("clear_suspension resumes drawing", r.shown == 1)
r.suspended_until = 1e9
r:before(fake_hud({ fake_slot(false) }))
check("HUD change clears suspension", r.suspended_until == 0.0)
for _ = 1, 29 do r:record_post(false, "boom", now) end
check("29 failures: not yet suspended", r.suspended_until == 0.0)
r:record_post(false, "boom", now)
check("30th failure suspends 5 s",
  r.suspended_until == now + 5.0 and r.status == "paused: boom"
  and r.fail_count == 0)
r:record_post(false, "boom", now)
check("failure increments the counter", r.fail_count == 1)
r:record_post(true, nil, now)
check("success resets the counter", r.fail_count == 0)

-- 13. free count: owned (failed) slots are not free; throttled by clock
local f1, f2 = fake_slot(false), fake_slot(false)
local hud4 = fake_hud({ f1, f2 })
local r2 = renderer()
cands = { marker(10) }
r2:before(hud4)
new_snap()
now = now + 2  -- pass the 1 s free-count throttle
r2:after(hud4)
check("free count sees whole list", r2.free_n == 2)
f1.fail_restore = true
pcall(r2.before, r2, hud4)
f1.fail_restore = false
cands = {}
now = now + 2
r2:after(hud4)
check("owned failed slot not counted free", r2.free_n == 1)
f2.visible = true  -- actual free is now 0, but within the throttle window
now = now + 0.5
r2:after(hud4)
check("free count throttled within 1 s", r2.free_n == 1)

-- 13b. a raising get_Visible on one hidden-owned slot fails that slot
--      only; later owned slots still restore (clear() loop continues)
local g1, g2 = fake_slot(false), fake_slot(false)
local hud4b = fake_hud({ g1, g2 })
local r2b = renderer()
cands = { marker(10), marker(20) }
r2b:before(hud4b)
new_snap()
r2b:after(hud4b)
check("13b setup draws two", r2b.shown == 2)
g1.fail_restore = true g2.fail_restore = true
pcall(r2b.before, r2b, hud4b)   -- both hidden, both stay owned
g1.fail_restore = false g2.fail_restore = false
g1.get_Visible = function() error("read fails") end
local okc = pcall(r2b.before, r2b, hud4b)
check("raising visible-read fails that slot only",
  okc == false and #r2b.owned == 1 and r2b.owned[1].ref == g1
  and g2.visible == false and g2.icon == 7)

-- 14. destroy only the matching HUD
r:destroy(hud)   -- not ours
check("destroy ignores other HUD", r.ui ~= nil)
r:destroy(r.ui)
check("destroy forgets matching HUD", r.ui == nil and #r.owned == 0)

-- 15. before(nil) is a no-op: owner and owned slots unchanged
local r3 = renderer()
local hud5 = fake_hud({ fake_slot(false) })
cands = { marker(10) }
r3:before(hud5)
new_snap()
r3:after(hud5)
local owned_n = #r3.owned
r3:before(nil)
check("before(nil) no-op", r3.ui == hud5 and #r3.owned == owned_n)

-- 16. pl_seen_without_minimap (SPEC 17.3a)
do
  local rp = renderer()
  check("fresh pl_seen_at is -inf", rp.pl_seen_at == -math.huge)
  local hudp = fake_hud({ fake_slot(false) })
  hudp.PlUPos = { x = 3, y = 4, z = 5 }
  settings.show_minimap = false
  rp:before(hudp)
  now = 42
  rp:after(hudp)
  check("pl_seen_at recorded without minimap", rp.pl_seen_at == 42)
  check("pl_pos recorded without minimap", rp.pl_pos == hudp.PlUPos)
  local rn = renderer()
  local hudn = fake_hud({ fake_slot(false) })
  hudn.PlChara = nil
  rn:before(hudn)
  rn:after(hudn)
  check("no player: pl_seen_at unchanged", rn.pl_seen_at == -math.huge)
  check("no player: pl_pos unchanged", rn.pl_pos == nil)
  settings.show_minimap = true
  settings.enabled = false
  local re = renderer()
  local hude = fake_hud({ fake_slot(false) })
  re:before(hude)
  now = 77
  re:after(hude)
  check("pl_seen_at recorded with enabled = false", re.pl_seen_at == 77)
  settings.enabled = true
end

if failures > 0 then os.exit(1) end
print("minimap_test: all OK")
