-- Map-jump state machine (SPEC 16.3g). Pure: no host global is read; every
-- game access arrives through the callback table given to J.new:
--   open(pos)       -> bool        ask the game to open the map at pos {x,y,z}
--   apply(ui, pos)  -> {x,z}|nil   write the cursor position, return the readback
--   ui()            -> ui|nil      the currently captured map UI
--   is_live(ui)     -> bool        the UI object is still alive
--   ctor_count()    -> int         how many map UIs have been constructed
--   menu_open()     -> bool        a pause menu is open (optional)
--   close_menu()                   ask the game to close it (optional)
-- An open pause menu is closed first and the map opened fresh once it is
-- gone: a map opened over a pause page other than the map page ignores the
-- request.
-- The caller feeds one frame at a time through m:step(frame, t).
local M = {}

M.APPLY_DELAY = 45   -- frames after a new construction before the apply
M.EXISTING_WAIT = 30 -- frames before using an already-open UI
M.TIMEOUT_S = 10.0   -- seconds before the request gives up
M.ON_TARGET = 1.0    -- readback within this x/z distance counts as on target

function M.new(cb)
  local m = { pending = nil, run = nil }

  local function live(ui)
    if ui == nil then return false end
    local ok, v = pcall(cb.is_live, ui)
    return ok and v == true
  end

  local function finish(self, result, branch, readback)
    local r = self.run
    self.run = nil
    return { result = result, branch = branch, readback = readback,
      target = r.pos, opened = r.opened == true }
  end

  local function apply(self, ui, branch)
    local r = self.run
    local ok, rb = pcall(cb.apply, ui, r.pos)
    if not ok or type(rb) ~= "table" or type(rb.x) ~= "number" or type(rb.z) ~= "number" then
      return finish(self, "off_target", branch, nil)
    end
    local dx, dz = rb.x - r.pos.x, rb.z - r.pos.z
    local hit = math.sqrt(dx * dx + dz * dz) <= M.ON_TARGET
    return finish(self, hit and "on_target" or "off_target", branch,
      { x = rb.x, z = rb.z })
  end

  -- Queue a target; replaces any pending or running request (no result).
  function m:request(pos)
    self.pending = { x = pos.x, y = pos.y, z = pos.z }
    self.run = nil
  end

  local function menu_open()
    if cb.menu_open == nil then return false end
    local ok, v = pcall(cb.menu_open)
    return ok and v == true
  end

  local function open(self, frame)
    local r = self.run
    r.closing, r.f0, r.c0 = false, frame, cb.ctor_count()
    local ok, opened = pcall(cb.open, r.pos)
    r.opened = ok and opened == true
  end

  function m:busy()
    return self.pending ~= nil or self.run ~= nil
  end

  -- One frame. frame: monotonically increasing frame counter; t: seconds.
  -- Returns nil, or once per request a result table
  -- { result, branch = "new" | "existing" | nil, readback, target, opened }.
  function m:step(frame, t)
    if self.pending ~= nil then
      local pos = self.pending
      self.pending = nil
      self.run = { pos = pos, t0 = t }
      if menu_open() then
        self.run.closing = true
        pcall(cb.close_menu)
      else
        local u0 = cb.ui()
        self.run.u0 = live(u0) and u0 or nil
        open(self, frame)
      end
      return nil
    end
    local r = self.run
    if r == nil then return nil end
    if r.closing then
      if not menu_open() then open(self, frame); return nil end
      if t - r.t0 >= M.TIMEOUT_S then return finish(self, "timeout", nil, nil) end
      return nil
    end
    local c = cb.ctor_count()
    if c > r.c0 then                     -- a new instance was constructed
      r.c0, r.new_at, r.new_ui = c, frame, cb.ui()
    end
    local cur = cb.ui()
    if r.new_at ~= nil then
      if cur ~= r.new_ui or not live(cur) then return finish(self, "canceled", "new", nil) end
      if frame - r.new_at >= M.APPLY_DELAY then return apply(self, cur, "new") end
    else
      if r.u0 ~= nil and (cur ~= r.u0 or not live(cur)) then
        return finish(self, "canceled", "existing", nil)
      end
      if frame - r.f0 >= M.EXISTING_WAIT and live(cur) then
        return apply(self, cur, "existing")
      end
    end
    if t - r.t0 >= M.TIMEOUT_S then
      return finish(self, "timeout", r.new_at ~= nil and "new" or nil, nil)
    end
    return nil
  end

  return m
end

return M
