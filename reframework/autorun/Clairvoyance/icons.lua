-- icons.lua: D2DX picture renderer (SPEC 21.2). Draws the game's own map
-- icon art, converted to white, tinted with the category color, on the full
-- map, the minimap and above heads. No host globals here: the D2DX table,
-- the clock and every game access arrive through opt.
local M = {}

local PATH_PREFIX = "Clairvoyance/icons/"
local TRIP_AT = 30        -- consecutive failed passes before the breaker trips
local TRIP_SECONDS = 5.0
local TRIP_LIMIT = 3      -- the third trip keeps drawing off
local MINI_STALE = 0.25   -- seconds without a minimap update before "mini" is dropped
local MAX_RECORDS = 4096  -- per-layer cap: pushes past it are dropped (a layer that never gets replaced cannot grow without bound)

local function new_layer()
  return { n = 0, pool = {} }
end

local function layer_push(layer, id, x, y, size, tint, alpha)
  local n = layer.n + 1
  if n > MAX_RECORDS then return end
  layer.n = n
  local rec = layer.pool[n]
  if rec == nil then
    rec = {}
    layer.pool[n] = rec
  end
  rec.id, rec.x, rec.y, rec.size, rec.tint, rec.alpha = id, x, y, size, tint, alpha
end

-- One layer's records, inside the pcall of the pass. Centers become top-left
-- corners (SPEC 21.2.7); "head" records are already screen pixels.
local function draw_layer(r, layer, ox, oy, k, is_head)
  local d2dx, opts, images = r.d2dx, r.opts, r.images
  local pool = layer.pool
  for i = 1, layer.n do
    local rec = pool[i]
    local entry = images[rec.id]
    if entry ~= nil and entry.state == "ready" then
      local s = rec.size * k
      local px, py
      if is_head then
        px, py = rec.x - s / 2, rec.y - s / 2
        opts.tint, opts.alpha = 0xFF000000, rec.alpha
        d2dx.image_ex(entry.img, px + 1, py + 1, s, s, opts)
      else
        px, py = ox + rec.x * k - s / 2, oy + rec.y * k - s / 2
      end
      opts.tint, opts.alpha = rec.tint, rec.alpha
      d2dx.image_ex(entry.img, px, py, s, s, opts)
    end
  end
end

local function draw_all(r, ox, oy, k, use_mini)
  draw_layer(r, r.map, ox, oy, k, false)
  if use_mini then draw_layer(r, r.mini, ox, oy, k, false) end
  draw_layer(r, r.head, ox, oy, k, true)
end

function M.create(opt)
  opt = opt or {}
  local d2dx = opt.d2dx
  local clock = opt.clock or function() return 0 end
  local r = {
    d2dx = d2dx,
    images = {},            -- id -> { img, state = "pending" | "ready" | "failed" }
    pending = {}, pending_n = 0,
    map = new_layer(), mini = new_layer(), head = new_layer(),
    mini_at = -math.huge,
    opts = {},
    map_seen = -math.huge,
    layout_k = 1,
    fail_count = 0, trips = 0, tripped_until = nil,
    failed_ids = 0,
    fill_ms = 0, draw_ms = 0,
    drawn_map = 0, drawn_mini = 0, drawn_head = 0,
  }

  local function log(msg)
    if opt.log ~= nil then opt.log(msg) end
  end
  local function rebuild()
    if opt.request_rebuild ~= nil then opt.request_rebuild() end
  end
  local function enabled_default() return true end

  local avail = type(d2dx) == "table"
    and type(d2dx.image_ex) == "function"
    and type(d2dx.begin_frame) == "function"
    and type(d2dx.end_frame) == "function"
    and type(d2dx.surface_size) == "function"
    and type(d2dx.Image) == "table"
    and type(d2dx.Image.new) == "function"

  function r:available() return avail end

  -- Trip end is noticed here, so every layer's once-per-pass question also
  -- retires an expired trip (SPEC 21.2.6).
  function r:active()
    if not avail then return false end
    if self.tripped_until ~= nil then
      if clock() < self.tripped_until then return false end
      self.tripped_until = nil
      self.fail_count = 0
      log("icons: D2DX drawing resumed")
      rebuild()
    end
    local ok, en = pcall(opt.enabled or enabled_default)
    return ok and en and true or false
  end

  local function mark_failed(id, entry, why)
    if entry.state ~= "failed" then
      entry.state = "failed"
      r.failed_ids = r.failed_ids + 1
      log("icons: image " .. tostring(id) .. " failed: " .. tostring(why))
    end
  end

  function r:preload(ids)
    if not avail then return end
    local newly_failed = false
    for i = 1, #ids do
      local id = ids[i]
      if self.images[id] == nil then
        local entry = { img = nil, state = "pending" }
        self.images[id] = entry
        local ok, img = pcall(d2dx.Image.new, PATH_PREFIX .. id .. ".png")
        local t = type(img)
        if ok and (t == "table" or t == "userdata") then
          entry.img = img
          local okr, is_ready = pcall(img.is_ready, img)
          if okr and is_ready then
            entry.state = "ready"
          else
            self.pending_n = self.pending_n + 1
            self.pending[self.pending_n] = id
          end
        else
          mark_failed(id, entry, ok and "file missing" or img)
          newly_failed = true
        end
      end
    end
    if newly_failed then rebuild() end
  end

  function r:ready(id)
    local e = self.images[id]
    if e == nil then return false end
    if e.state == "pending" and e.img ~= nil then
      local okr, is_ready = pcall(e.img.is_ready, e.img)
      if okr and is_ready then
        e.state = "ready"
        -- callers outside a build (overhead, minimap) may see the flip first
        rebuild()
      end
    end
    return e.state == "ready"
  end

  function r:drawable(id)
    return self:active() and self:ready(id)
  end

  r.drawable_fn = function(id) return r:drawable(id) end

  -- Polls images still pending; one rebuild per pass that settled any.
  local function poll()
    local changed = false
    local i = 1
    while i <= r.pending_n do
      local id = r.pending[i]
      local entry = r.images[id]
      local img = entry.img
      local settled = false
      if entry.state ~= "pending" then
        -- settled by ready() or preload since it was queued: nothing changed for the poll
        r.pending[i] = r.pending[r.pending_n]
        r.pending[r.pending_n] = nil
        r.pending_n = r.pending_n - 1
        goto continue
      end
      local okr, is_ready = pcall(img.is_ready, img)
      if okr and is_ready then
        entry.state = "ready"
        settled = true
      else
        local oks, st = pcall(img.get_state, img)
        if oks and st == "failed" then
          local _, err = pcall(img.get_error, img)
          mark_failed(id, entry, err)
          settled = true
        end
      end
      if settled then
        changed = true
        r.pending[i] = r.pending[r.pending_n]
        r.pending[r.pending_n] = nil
        r.pending_n = r.pending_n - 1
      else
        i = i + 1
      end
      ::continue::
    end
    if changed then rebuild() end
  end

  function r:push(layer, id, x, y, size, argb, fade)
    local tint = argb | 0xFF000000
    local alpha = (((argb >> 24) & 0xFF) / 255) * fade
    if layer == "mini" then
      self.mini_at = clock()
      layer_push(self.mini, id, x, y, size, tint, alpha)
    elseif layer == "map" then
      layer_push(self.map, id, x, y, size, tint, alpha)
    elseif layer == "head" then
      layer_push(self.head, id, x, y, size, tint, alpha)
    end
  end

  function r:mini_replace()
    self.mini.n = 0
    self.mini_at = clock()
  end

  -- Full-map fill (SPEC 21.4.4): a failing or nil-returning read skips the
  -- record and never feeds the breaker.
  function r:fill(records, read)
    local t0 = clock()
    for i = 1, #records do
      local rec = records[i]
      local ok, x, y = pcall(read, rec)
      if ok and type(x) == "number" and type(y) == "number" and type(rec.argb) == "number"
          and type(rec.size) == "number" and rec.id ~= nil then
        self:push("map", rec.id, x, y, rec.size, rec.argb, 1)
      end
    end
    self.fill_ms = (clock() - t0) * 1000
  end

  function r:k() return self.layout_k end

  function r:pool_size()
    return #self.map.pool + #self.mini.pool + #self.head.pool
  end

  local function clear_queues()
    r.map.n = 0
    r.head.n = 0
  end

  local function fail_pass(reason)
    r.fail_count = r.fail_count + 1
    if r.fail_count >= TRIP_AT then
      r.trips = r.trips + 1
      r.fail_count = 0
      if r.trips >= TRIP_LIMIT then
        r.tripped_until = math.huge
      else
        r.tripped_until = clock() + TRIP_SECONDS
      end
      r.map.n, r.mini.n, r.head.n = 0, 0, 0
      log("icons: D2DX drawing off (" .. tostring(reason) .. "), trip " .. r.trips)
      rebuild()
    end
  end

  function r:draw()
    if avail then poll() end
    if self.mini.n > 0 and clock() - self.mini_at > MINI_STALE then
      self.mini.n = 0
    end
    if not self:active() then
      clear_queues()
      return
    end
    local okm, mini_ok = pcall(opt.mini_ok or enabled_default)
    local use_mini = okm and mini_ok and true or false
    local nmap, nmini, nhead = self.map.n, use_mini and self.mini.n or 0, self.head.n
    if nmap + nmini + nhead == 0 then
      clear_queues()
      return
    end
    local t0 = clock()
    local oks, w, h = pcall(d2dx.surface_size)
    if not oks or type(w) ~= "number" or w <= 0 or type(h) ~= "number" or h <= 0 then
      clear_queues()
      fail_pass(oks and "surface_size 0" or ("surface_size raised: " .. tostring(w)))
      return
    end
    local k = math.min(w / 1920, h / 1080)
    self.layout_k = k
    local ox, oy = (w - 1920 * k) / 2, (h - 1080 * k) / 2
    local okb, began = pcall(d2dx.begin_frame)
    if not okb or not began then
      clear_queues()
      fail_pass(okb and "begin_frame false" or ("begin_frame raised: " .. tostring(began)))
      return
    end
    local okd, err = pcall(draw_all, self, ox, oy, k, use_mini)
    pcall(d2dx.end_frame)
    clear_queues()
    if okd then
      self.fail_count = 0
      self.drawn_map, self.drawn_mini, self.drawn_head = nmap, nmini, nhead
    else
      fail_pass("draw raised: " .. tostring(err))
    end
    self.draw_ms = (clock() - t0) * 1000
  end

  function r:stats_line()
    return string.format(
      "Draw: map %d, mini %d, head %d, fill %.2f ms, draw %.2f ms, trips %d, failed ids %d",
      self.drawn_map, self.drawn_mini, self.drawn_head,
      self.fill_ms, self.draw_ms, self.trips, self.failed_ids)
  end

  return r
end

return M
