-- minimap.lua: slot borrow/restore renderer for the minimap (SPEC 5.14, 11).
-- Borrows invisible icon slots from the HUD's MapIconList, draws category
-- dots on them, and gives every slot back on the next PRE. Owned-set blocks
-- double-borrow of a failed-restore slot; a reclaimed slot is dropped instead
-- of overwritten on retry; liveness check on saved refs; snapshot-identity
-- wait after a HUD change; POST-only suspension via record_post. With
-- matching icons active (opt.icons_on, SPEC 21.5) candidates are pushed as
-- pictures instead and a slot is borrowed only for a picture that cannot be
-- drawn. No host globals here: every game access arrives through opt.
local M = {}

-- Capture every field of a slot before the first write (SPEC 5.14.4).
local function save_slot(ref)
  local saved = {
    ref = ref,
    addr = ref:get_address(),
    icon_type = ref:get_IconType(),
    color = ref:get_Color(),
    position = ref:get_Position(),
    rotation = ref:get_Rotation(),
    scale = ref:get_Scale(),
  }
  local sprite = ref.Sprite
  if sprite ~= nil then
    saved.sequence = sprite:get_UVSequenceNo()
    saved.pattern = sprite:get_UVPatternNo()
  end
  return saved
end

function M.create(opt)
  local self = {
    ui = nil,
    owned = {},
    owned_set = {},
    hud_changed = true,
    snap_at_hud_change = nil,
    hud_changes = 0,
    status = "waiting",
    candidates_n = 0, clipped = 0, shown = 0, dropped = 0,
    pool_n = 0, free_n = 0,
    icons_mode = false, push_failed = 0,
    free_at = -math.huge,
    pl_seen_at = -math.huge,
    pl_pos = nil,
    nearest = nil,
    fail_count = 0,
    suspended_until = 0.0,
  }

  -- SPEC 5.14.6: clears the POST suspension state.
  function self:clear_suspension()
    self.fail_count = 0
    self.suspended_until = 0.0
  end

  -- SPEC 5.14.8: POST-only suspension (SPEC 11.3). The caller reports each
  -- POST outcome; 30 consecutive failures pause POST for 5 s.
  function self:record_post(ok, err, now)
    if ok then self.fail_count = 0 return end
    self.fail_count = self.fail_count + 1
    if self.fail_count >= 30 then
      self.fail_count = 0
      self.suspended_until = now + 5.0
      self.status = "paused: " .. tostring(err)
    end
  end

  -- Restore one saved slot; returns ok, err (SPEC 5.14.4).
  local function restore_one(saved)
    local ref = saved.ref
    if not opt.is_live(ref) then return true end
    if saved.hidden then
      local okv, vis = pcall(ref.get_Visible, ref)
      if not okv then return false, vis end
      if vis then return true end  -- reallocated by the game: drop, no write
    end
    return pcall(function()
      ref:set_Visible(false)
      saved.hidden = true
      ref:set_IconType(saved.icon_type)
      if saved.sequence ~= nil and ref.Sprite ~= nil then
        ref.Sprite:set_UVSequenceNo(saved.sequence)
        ref.Sprite:set_UVPatternNo(saved.pattern)
      end
      ref:set_Color(saved.color)
      ref:set_Position(saved.position)
      ref:set_Rotation(saved.rotation)
      ref:set_Scale(saved.scale)
    end)
  end

  function self:clear()
    if #self.owned == 0 then return end
    local kept, first_err = {}, nil
    local kept_set = {}
    for _, saved in ipairs(self.owned) do
      local ok, err = restore_one(saved)
      if not ok then
        kept[#kept + 1] = saved
        kept_set[saved.addr] = true
        if first_err == nil then first_err = err end
      end
    end
    self.owned = kept
    self.owned_set = kept_set
    if first_err ~= nil then error(first_err) end
  end

  function self:before(ui)
    if ui == nil then return end
    if ui ~= self.ui then
      self.owned = {}
      self.owned_set = {}
      self.ui = ui
      self.hud_changed = true
      self.hud_changes = self.hud_changes + 1
      self.snap_at_hud_change = opt.snapshot()
      self:clear_suspension()
    end
    self:clear()
  end

  function self:destroy(ui)
    if ui ~= nil and ui == self.ui then
      self.owned = {}
      self.owned_set = {}
      self.ui = nil
      self.hud_changed = true
      self.snap_at_hud_change = nil
    end
  end

  function self:after(ui)
    self.candidates_n, self.clipped, self.shown, self.dropped = 0, 0, 0, 0
    self.push_failed = 0
    self.nearest = nil
    self.icons_mode = false
    -- SPEC 21.5.2: while pictures are on, every update starts a new "mini"
    -- set, so a disabled or toggled-off minimap empties it.
    local pictures = opt.icons_on ~= nil and opt.icons_on()
    if pictures then opt.mini_replace() end
    if ui == nil or ui ~= self.ui then return end

    -- SPEC 17.3a: player-seen clock, independent of the minimap toggles.
    if ui.IsInit and ui.PlChara ~= nil then
      self.pl_seen_at = opt.clock()
      self.pl_pos = ui.PlUPos
    end

    local settings = opt.settings
    if not settings.enabled then self.status = "disabled" return end
    if not settings.show_minimap then self.status = "toggle" return end
    if opt.clock() < self.suspended_until then return end
    if not (ui.IsInit and ui.PlChara ~= nil and ui.MapIconList ~= nil) then
      self.status = "waiting" return
    end
    local range = ui.MapOutRange
    if type(range) ~= "number" or range <= 0 then
      self.status = "waiting" return
    end
    local snap = opt.snapshot()
    if snap == nil then self.status = "no snapshot" return end
    if self.hud_changed then
      if snap == self.snap_at_hud_change then self.status = "waiting" return end
      self.hud_changed = false
    end
    self.status = "drawing"

    local pool = ui.MapIconList
    local count = pool:get_Count()
    self.pool_n = count

    local now = opt.clock()
    -- A frame_info that keeps failing (raise or nil) falls back to the v12
    -- slot path after 30 updates, never a blank minimap.
    local px, py, fade, frame_ok
    if pictures then
      local okf, a, b, c, d = pcall(opt.frame_info, ui)
      if okf and a ~= nil then
        self.frame_fails = 0
        frame_ok = d and c ~= nil and c > 0
        px, py, fade = a, b, c
      else
        self.frame_fails = (self.frame_fails or 0) + 1
        if self.frame_fails >= 30 then pictures = false end
      end
    end
    if pictures then
      self.icons_mode = true
      self.free_n = 0
    elseif now - self.free_at >= 1.0 then
      self.free_at = now
      local free = 0
      for i = 0, count - 1 do
        local ok, usable = pcall(function()
          local s = pool:get_Item(i)
          return s ~= nil and not s:get_Visible()
            and not self.owned_set[s:get_address()]
        end)
        if ok and usable then free = free + 1 end
      end
      self.free_n = free
    end

    local cands, nearest = opt.candidates(snap, ui.PlUPos)
    self.candidates_n = #cands
    self.nearest = nearest

    local cursor = 0
    local function borrow_slot()
      while cursor < count do
        local idx = cursor
        cursor = cursor + 1
        local ok, saved = pcall(function()
          local s = pool:get_Item(idx)
          if s == nil or s:get_Visible() or self.owned_set[s:get_address()] then
            return nil
          end
          local sv = save_slot(s)
          self.owned[#self.owned + 1] = sv
          self.owned_set[sv.addr] = true
          return sv
        end)
        if ok and saved ~= nil then return saved end
      end
      return nil
    end

    if pictures and not frame_ok then
      return  -- nothing queues: full map open, faded out, or no frame info
    end

    local range2 = range * range
    local out_of_slots = false
    for i, m in ipairs(cands) do
      local ok = pcall(function()
        local pos = ui:getIconPos(opt.vector(m.pos.x, m.pos.y, m.pos.z))
        if pos == nil or pos.x * pos.x + pos.y * pos.y > range2 then
          self.clipped = self.clipped + 1
          return
        end
        if pictures then
          -- Ruling 2: a picture that is not drawable falls through to the
          -- v12 slot borrow (game glyph), never a blank.
          local id = opt.picture_for(m)
          if opt.drawable(id) then
            -- A failing push is not a slot drop: counted apart from dropped.
            local okp = pcall(opt.push, id, px + pos.x, py + pos.y, 28,
              opt.color_for(m), fade)
            if okp then self.shown = self.shown + 1
            else self.push_failed = self.push_failed + 1 end
            return
          end
        end
        local saved = borrow_slot()
        if saved == nil then
          if pictures then
            -- later candidates may still be drawable pictures: no break
            self.dropped = self.dropped + 1
            return
          end
          self.dropped = #cands - i + 1
          out_of_slots = true
          return
        end
        local ref = saved.ref
        ref:set_IconType(opt.icon_for(m))
        ref:set_Position(pos)
        ref:set_Rotation(0)
        ref:set_Scale(saved.scale)
        opt.set_color(ref, opt.color_for(m))
        ref:set_Visible(true)
        self.shown = self.shown + 1
      end)
      if out_of_slots then break end
      if not ok then self.dropped = self.dropped + 1 end
    end
  end

  return self
end

return M
