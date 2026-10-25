-- Clairvoyance.lua — hooks, settings UI, snapshot tick, overhead draw layer, minimap layer.
-- Map icons + hover labels for side quests by lifecycle state (docs/SPEC.md).
local core = require("Clairvoyance.core")
local A = require("Clairvoyance.adapter")
local jump = require("Clairvoyance.jump")
local su = require("Clairvoyance.settings_util")
-- v10 world tracker: a missing or broken module must never stop the mod loading.
local world = (function() local ok, m = pcall(require, "Clairvoyance.world"); return ok and m or nil end)()

local MOD_NAME = "Clairvoyance"
local SETTINGS_PATH = "Clairvoyance.json"
local REFRESH_INTERVAL = 2.0

local raw_settings = su.load_with_legacy(json.load_file, SETTINGS_PATH, "QuestNPCMapLabels.json")
local settings = su.validate(raw_settings)
local function save_settings()
  pcall(json.dump_file, SETTINGS_PATH, settings)
  pcall(A.save_learned_names)
end
re.on_config_save(save_settings)

local adapter = A.make()
A.set_debug(settings.debug)

-- v10 world tracker instance (SPEC 17). Everything world-related lives in
-- fields of wt (world_origin, q, line), so the main file gains no other
-- chunk-level local. When the module is missing or world.new fails, wt is a
-- stub whose methods do nothing.
local wt
do
  local ok_w, inst = false, nil
  if world ~= nil then
    ok_w, inst = pcall(function()
      local wio = world.default_io()
      wio.log = function(s) log.info("[Clairvoyance] " .. tostring(s)) end
      return world.new(adapter, world.game_reads(), wio)
    end)
    if not ok_w then
      log.error("[Clairvoyance] world tracker unavailable: " .. tostring(inst))
    end
  end
  if not ok_w or type(inst) ~= "table" then
    inst = {
      refresh = function() return false end,
      input = function() return nil end,
      givers = function() return {} end,
      places_state = function() return { state = "bad", stale = false } end,
      reset = function() end,
      save = function() return false end,
      stats = function() return nil end,
    }
  end
  wt = inst
  -- v14 (SPEC 23.5): one outline style table per group, refilled in place
  -- each frame; no table is built per frame.
  wt.style = require("Clairvoyance.style")
  wt.styles = {}
  for _, g in ipairs(wt.style.GROUPS) do
    wt.styles[g] = { on = true, color = 0xFF000000, width = 1 }
  end
  wt.styles.none = { on = false, color = 0xFF000000, width = 1 }
  wt.dk, wt.dw, wt.dh = 1, 1920, 1080   -- display scale (height / 1080) and size
  wt.outline_acc = 0                    -- ms spent in outline draws outside icons, this frame
  wt.outline_ms_shown = 0               -- last whole frame's total (icons + outside)
  wt.any_on = true                      -- some group has its outline on
  wt.path_draw_ms = 0
  wt.path_scr = {}                      -- reused screen buffer for the in-world path
  wt.a = function(argb) return ((argb >> 24) & 0xFF) / 255 end
  wt.refresh_styles = function()
    local gs, styles = wt.style.GROUPS, wt.styles
    local any = false
    for i = 1, #gs do
      local st = styles[gs[i]]
      st.on, st.color, st.width = wt.style.resolve(settings, gs[i])
      if st.on then any = true end
    end
    wt.any_on = any
    local ok, sz = pcall(imgui.get_display_size)
    if ok and sz ~= nil and sz.y > 0 then
      wt.dk, wt.dw, wt.dh = sz.y / 1080, sz.x, sz.y
    end
  end
  pcall(wt.refresh_styles)
  wt.world_origin = nil   -- committed origin: a plain { x, y, z } copy, or nil
  wt.map_retakes, wt.rebuild_ms, wt.rebuild_max = 0, 0, 0   -- SPEC 20.12.8-9
  wt.ps_dflt = { state = "bad", stale = false }   -- places_state default, shared
  -- Guarded method call: wt:name(...) under pcall, dflt on a raise or nil.
  wt.q = function(name, dflt, ...)
    local okc, r = pcall(wt[name], wt, ...)
    if okc and r ~= nil then return r end
    return dflt
  end
  -- The World: readout line (debug panel, Status node, 5 s dump).
  -- Rebuilt at most once a second: it formats a long string.
  wt.line = function()
    local now = os.clock()
    if wt.line_txt ~= nil and now - wt.line_at < 1 then return wt.line_txt end
    local st = wt.q("stats", nil)
    if st == nil then return "World: unavailable" end
    local mk = {}
    for k in pairs(st.ms or {}) do mk[#mk + 1] = k end
    table.sort(mk)
    local parts = {}
    for _, k in ipairs(mk) do parts[#parts + 1] = string.format("%s %.1f", k, st.ms[k]) end
    local kn = st.known or {}
    wt.line_txt = string.format(
      "World: atlas %d file/%d learned, places %s %d rows %.0f ms, unlisted %d, index %d hits/%d misses, known chests %d treasure %d tokens %d beetles %d monsters %d sellers %d, ms [%s], save %.1f ms",
      st.atlas.file, st.atlas.learned, tostring(st.places.state), st.places.rows,
      st.places.load_ms, st.unlisted, st.index.hits, st.index.misses,
      kn.chests or 0, kn.treasure or 0, kn.tokens or 0, kn.beetles or 0,
      kn.monsters or 0, kn.sellers or 0, table.concat(parts, ", "), st.save_ms)
    wt.line_at = now
    return wt.line_txt
  end
end
re.on_config_save(function() pcall(wt.save, wt, "config") end)

-- Snapshot: only re.on_frame writes it; map hooks only read it.
local snapshot = nil      -- { markers, unresolved, unnamed, counts, resolved_count, sig }
-- Last frame's world toggles (su.world_toggled) and the debug tick ring.
wt.prev_tg, wt.tick_ring = {}, {}
-- Monster kinds seen this save, per class, for the World markers tree
-- (SPEC 29.6.3, 30.6.3): { [fam] = { [kind] = true } } per class; filled once
-- per tick from the published kind counts. fam_names holds the last published
-- family name per class and fam.
wt.kinds_seen = { large = {}, small = {} }
wt.fam_names = { large = {}, small = {} }
-- The World panel rows of one category, cached on the snapshot (the debug
-- dump reads the same rows). Each row carries its "Show on map" button id.
wt.rows = function(cat, class, kind, fam)
  -- SPEC 29.6.6, 30.6.6: with class ("large" or "small"), kind and fam, the
  -- nearest rows of that one monster kind in that family, filtered before
  -- the row limit; with one argument "monster" is still every monster row
  -- (the debug dump)
  local p = snapshot ~= nil and snapshot.world ~= nil and snapshot.world[cat] or nil
  if p == nil then return {} end
  local cache = snapshot.world_rows
  if cache == nil then cache = {}; snapshot.world_rows = cache end
  local slot, key = cache, cat   -- a kind list has its own three-level slot
  if cat == "monster" and kind ~= nil then
    fam = fam or "?"
    slot = cache.kind_rows
    if slot == nil then slot = { large = {}, small = {} }; cache.kind_rows = slot end
    slot = slot[class]
    if slot[fam] == nil then slot[fam] = {} end
    slot, key = slot[fam], kind
  end
  local rows = slot[key]
  if rows == nil then
    local ents = p.entries
    if cat == "monster" and kind ~= nil then
      -- partition the entries by class, family and kind once per snapshot
      local by = snapshot.world_kind_ents
      if by == nil then
        by = { large = {}, small = {} }
        for _, e in ipairs(p.entries or {}) do
          local cls = by[e.small == true and "small" or "large"]
          local f = core.fam_of(e)
          local fl = cls[f]
          if fl == nil then fl = {}; cls[f] = fl end
          local k = core.kind_of(e)
          local l = fl[k]
          if l == nil then l = {}; fl[k] = l end
          l[#l + 1] = e
        end
        snapshot.world_kind_ents = by
      end
      ents = (by[class][fam] or {})[kind] or {}
    end
    rows = core.world_rows(ents, (wt.q("input", nil) or {}).settlements,
      wt.world_origin, cat == "shop" and math.huge or nil)
    for _, r in ipairs(rows) do
      r.jump_id = "Show on map##wj_" .. cat .. "_" .. tostring(r.key)
      r.tree_id = r.text .. "###ws_" .. tostring(r.key)
    end
    -- SPEC 28.9.4: the Finder's Token spot is listed first
    if cat == "token" and p.first ~= nil then
      table.insert(rows, 1, { text = "Finder's Token spot", pos = p.first.pos,
        key = p.first.key, first = true, jump_id = "Show on map##wj_token_first" })
    end
    slot[key] = rows
  end
  return rows
end
-- v14 (SPEC 22.11.3): the opened Hints nodes' qids, and the pins of those
-- whose step is the active one now (pins bypass the search and the cap).
wt.hints, wt.hints_open = {}, {}   -- hints by qid (npcs.parse_hints); qid -> step idx
wt.quest_rel, wt.quest_pak, wt.focus_tracked_qid = nil, nil, nil   -- quest focus (SPEC 32)
wt.hint_inputs = function()
  local qids, pins = {}, {}
  local rb = snapshot ~= nil and snapshot.rec_by or nil
  for qid in pairs(wt.hints_open) do
    local rec = rb ~= nil and rb[qid] or nil
    if rec == nil or rec.cat == "in_progress" then qids[#qids + 1] = qid end
  end
  table.sort(qids)
  local hs = snapshot ~= nil and snapshot.hint_steps or nil
  if hs ~= nil then
    local npcs = require("Clairvoyance.npcs")
    for _, qid in ipairs(qids) do
      local n = hs[qid]
      local st = type(n) == "number" and n - 1 == wt.hints_open[qid]
        and npcs.hint_step(wt.hints, qid, n) or nil
      if st ~= nil then
        for i, p in ipairs(st.pins) do
          pins[#pins + 1] = { qid = qid, i = i, label = p.label,
            pos = { x = p.x, y = p.y, z = p.z } }
        end
      end
    end
  end
  return qids, pins
end
-- Quest focus to the world round (SPEC 32.7, Contract 3): the previous
-- snapshot's focus table as is, and the sorted unique dest keys of the
-- active quests.
wt.focus_world = function(snap)
  local f = snap ~= nil and snap.focus or nil
  if f == nil or f.active == nil or #f.active == 0 then return nil, nil end
  local keys, have = {}, {}
  for _, qid in ipairs(f.active) do
    local rel = wt.quest_rel ~= nil and wt.quest_rel[qid] or nil
    for _, d in ipairs(rel ~= nil and rel.dest or {}) do
      if type(d.key) == "number" and d.key > 0 and not have[d.key] then
        have[d.key] = true; keys[#keys + 1] = d.key
      end
    end
  end
  table.sort(keys)
  if #keys == 0 then keys = nil end
  return f, keys
end
-- Route members (SPEC 32.7.1, Contract 4): the focus NPCs the world walks
-- schedules for, capped so the search target and members total at most 8.
wt.route_members = function(snap, input)
  local list, seen, inlist = {}, {}, {}
  local total = wt.route_cid ~= nil and 1 or 0
  local f = snap ~= nil and snap.focus or nil
  local opt = settings.focus_routes
  if opt ~= nil and opt > 0 and f ~= nil and f.active ~= nil and #f.active > 0 then
    local names
    for _, qid in ipairs(f.active) do
      local q = f.quests ~= nil and f.quests[qid] or nil
      local src = q ~= nil and (opt == 1 and q.step_npcs or q.npcs) or nil
      for _, cid in ipairs(src or {}) do
        if not seen[cid] then
          seen[cid] = true
          if cid ~= wt.route_cid then total = total + 1 end
          local extra = (wt.route_cid ~= nil and not inlist[wt.route_cid]) and 1 or 0
          if cid == wt.route_cid or #list + extra < 8 then
            if names == nil then
              names = {}
              for _, n in ipairs(input ~= nil and input.npcs or {}) do names[n.cid] = n.name end
            end
            local nm = names[cid]
            if nm == nil then
              local okn, v = pcall(adapter.npc_name, cid)
              nm = okn and type(v) == "string" and v ~= "" and v or ("NPC " .. cid)
            end
            list[#list + 1] = { cid = cid, name = nm }
            inlist[cid] = true
          end
        end
      end
    end
  end
  local extra = (wt.route_cid ~= nil and not inlist[wt.route_cid]) and 1 or 0
  wt.routes_n, wt.routes_total = #list + extra, total
  return list, total
end
-- v14 (SPEC 10.3b): one failure guard per new frame layer, state in a table
-- of its own. Log each distinct message once (16 cap); 30 failing frames in
-- a row suspend the layer for 5 s.
wt.layer = function() return { fails = 0, suspend = 0.0, logged = {}, n = 0 } end
wt.layer_run = function(L, name, fn)
  if os.clock() < L.suspend then return end
  local ok, err = pcall(fn)
  if ok then L.fails = 0; return end
  L.fails = L.fails + 1
  local msg = tostring(err)
  if not L.logged[msg] and L.n < 16 then
    L.logged[msg] = true; L.n = L.n + 1
    log.error("[Clairvoyance] " .. name .. " error: " .. msg)
  end
  if L.fails >= 30 then L.fails = 0; L.suspend = os.clock() + 5.0 end
end
wt.route_layer, wt.names_layer, wt.lines_layer = wt.layer(), wt.layer(), wt.layer()
wt.path_layer = wt.layer()
wt.names_labels = { "Off", "Quest NPCs", "All named NPCs" }
wt.names_stats = { drawn = 0, skipped = 0, spawned = 0 }
-- The player's Transform (the manual player), or nil.
wt.player_tr = function()
  local cm = sdk.get_managed_singleton("app.CharacterManager")
  local pl = cm ~= nil and cm:call("get_ManualPlayer") or nil
  local go = pl ~= nil and pl:call("get_GameObject") or nil
  local tr = go ~= nil and go:call("get_Transform") or nil
  if tr ~= nil and sdk.is_managed_object(tr) then return tr end
  return nil
end
-- Map space minus camera space (SPEC 22.4.5): the player's UniversalPosition
-- minus Position. nil when unreadable; the caller draws nothing then.
wt.read_offset = function()
  local ok, tr = pcall(wt.player_tr)
  if not ok or tr == nil then return nil end
  local okp, u, p = pcall(function()
    return tr:call("get_UniversalPosition"), tr:call("get_Position")
  end)
  if not okp or u == nil or p == nil then return nil end
  return u.x - p.x, u.y - p.y, u.z - p.z
end
local committed = {}
local want_update = false
-- Last player map-space position the minimap hook saw (ui.PlUPos); fed to
-- compute as show.origin for the item-marker cap order (SPEC 15.7i). nil
-- until the minimap has drawn once (or when that layer is unavailable).
local player_origin = nil
local player_origin_t = nil   -- v9: os.clock() of the last origin write (SPEC 16.3e)
local tree_expanded = {}      -- v9: qid -> true, rows open in the last drawn frame
local debug_expanded = {}     -- v9: qids added through QNML_DEBUG.expand
local jump_pending = nil      -- v9: { x, y, z } queued by a button (SPEC 16.3g)
local map_ctor_n = 0          -- v9: ui040205 .ctor count only (never setupMapIcon)
local setup_icon_n = 0        -- v9: setupMapIcon fires (6b: counted after each jump)
local jump_frame = 0
local jump_log = {}           -- v9: last 8 jump results
local jump_last_err = nil
local last_add_sig = nil  -- see the setupMapIcon hook below
local last_tick = 0.0
-- The one writer of the map origin: seeds/clears it and forces the next tick.
wt.set_map_origin = function(pos, at)
  wt.map_origin = pos ~= nil and { x = pos.x, y = pos.y or 0, z = pos.z } or nil
  wt.map_origin_at = at
  last_tick = 0.0
end
local last_tick_ms = 0.0
local last_walk_ms = 0.0   -- objective-walk share of the tick (v5 cost)
local walk_ms_max = 0.0    -- max walk since the last 5 s log dump (catches
                           -- the 60 s index-rebuild tick between dumps)

-- Map state
local ui_map = nil        -- captured ui040205

local function logmsg(s) log.info("[" .. MOD_NAME .. "] " .. tostring(s)) end
local function logerr(s) log.error("[" .. MOD_NAME .. "] " .. tostring(s)) end

-- v13 matching icons (SPEC 21). The picture renderer is this file's one new
-- chunk-level local; everything else is a field of it or lives in a do-block.
local icons = require("Clairvoyance.icons").create{
  d2dx = d2dx,
  clock = os.clock,
  log = logmsg,
  enabled = function() return settings.enabled and settings.matching_icons end,
  request_rebuild = function() want_update = true end,
  mini_ok = function() return ui_map == nil end,
  style_of = function(cat) return wt.styles[wt.style.group_of(cat)] end,
  scale_of = function(cat)
    return cat == "route_stop" and settings.route_stop_size / 100 or 1
  end,
}
do
  -- Hoisted pieces, built once: no closure is created per frame (SPEC 21.2.5).
  icons.never = function() return false end
  icons.recs = {}      -- full-map records of the last rebuild (SPEC 21.4.2)
  icons.ids = {}

  -- Every picture the settings can draw (SPEC 21.2.4); a no-op when matching
  -- icons are off, so off costs no image load.
  function icons:preload_all()
    if not settings.matching_icons then return end
    local ids, n = self.ids, 0
    for _, k in ipairs(su.ICON_KEYS) do
      local a, b = settings[k], su.V12_ICON[k]
      if a ~= nil then n = n + 1; ids[n] = a end
      if b ~= nil then n = n + 1; ids[n] = b end
    end
    if settings.step_icons then
      for i = 1, 5 do n = n + 1; ids[n] = i end
    end
    for i = #ids, n + 1, -1 do ids[i] = nil end
    self:preload(ids)
  end

  -- Game methods, resolved once at load from the type that declares each
  -- (verified in game): the full-map wrapper (MapIconSpriteRef), its child
  -- sprite (via.gui.Sprite), the minimap Root and the icon-root panel.
  local function find_method(tname, name)
    local td = sdk.find_type_definition(tname)
    return td ~= nil and td:get_method(name) or nil
  end
  local w_visible = find_method("app.GUIBase.MapIconSpriteRef", "get_Visible")
  local s_visible = find_method("via.gui.Sprite", "get_Visible")
  local s_position = find_method("via.gui.Sprite", "get_Position")
  local s_size = find_method("via.gui.Sprite", "get_Size")
  local m_gpos = find_method("via.gui.TransformObject", "get_GlobalPosition")
  local m_cscale = find_method("via.gui.Control", "get_ColorScale")
  local m_avisible = find_method("via.gui.PlayObject", "get_ActualVisible")
  -- False when any method the full-map reader needs failed to resolve: no
  -- picture is queued then, so the game glyph stays visible.
  icons.read_ok = w_visible ~= nil and s_visible ~= nil
    and s_position ~= nil and s_size ~= nil
  -- False when a minimap frame method failed to resolve: the minimap then
  -- keeps the v12 slot borrow instead of going blank.
  icons.mini_read_ok = m_gpos ~= nil and m_cscale ~= nil and m_avisible ~= nil
  local function call_m(m, obj)
    return m:call(obj)   -- a nil method raises; every caller is under pcall
  end

  -- Sprite side in 1920x1080 units; 32 when the read fails or is <= 0.
  local function size_read(sprite)
    local sz = call_m(s_size, sprite)
    local w = sz ~= nil and sz.w or nil
    if type(w) == "number" and w > 0 then return w end
    return 32
  end
  function icons.map_size(sprite)
    local ok, w = pcall(size_read, sprite)
    return ok and w or 32
  end

  -- Re-reads each record's size; run after apply_styles sets the icon scale.
  function icons.resize()
    local recs = icons.recs
    for i = 1, #recs do
      local rec = recs[i]
      if sdk.is_managed_object(rec.sprite) then rec.size = icons.map_size(rec.sprite) end
    end
  end

  -- The fill's reader (SPEC 21.4.4): nil skips the record, a raise is
  -- caught by the fill's own pcall and also skips it.
  function icons.read(rec)
    local sprite, ref = rec.sprite, rec.ref
    if not sdk.is_managed_object(sprite) or not sdk.is_managed_object(ref) then return nil end
    if call_m(w_visible, ref) ~= true then return nil end
    if call_m(s_visible, sprite) ~= true then return nil end
    local p = call_m(s_position, sprite)
    if p == nil then return nil end
    return p.x, p.y
  end

  -- Minimap frame info (SPEC 21.5.1): the panel's global position, the
  -- fade and the visible flag. Only PnlMapIconSpriteRoot is asked for a
  -- position, never the texture node under it.
  local function frame_read(ui)
    local pnl, root = ui.PnlMapIconSpriteRoot, ui.Root
    if not sdk.is_managed_object(pnl) or not sdk.is_managed_object(root) then return nil end
    local gp = call_m(m_gpos, pnl)
    local cs = call_m(m_cscale, root)
    local vis = call_m(m_avisible, root)
    if gp == nil or cs == nil then return nil end
    return gp.x, gp.y, cs.w, vis == true and ui_map == nil
  end
  function icons.frame_info(ui)
    local ok, px, py, fade, vis = pcall(frame_read, ui)
    if ok then return px, py, fade, vis end
    return nil
  end
  icons.mini_push = function(id, x, y, size, argb, fade, m)
    local st = m ~= nil and wt.styles[wt.style.group_of(m.cat)] or nil
    icons:push("mini", id, x, y, size, argb, fade, st)
  end
  icons.mini_clear = function() icons:mini_replace() end
  icons.picture_for = function(m)
    return su.icon_for(settings, m, "head", m.step, icons.never)
  end

  -- v14 (SPEC 22.8.4a): lines join the route stops in stop order, the stop
  -- number beside each; screen positions come from the icon records. Hoisted
  -- pieces, so no closure is built per frame.
  icons.route_recs, icons.nums = {}, {}
  icons.npcs = require("Clairvoyance.npcs")
  icons.fit_pts, icons.fit, icons.fit_opt = {}, {}, { similarity = false }
  icons.end_rows, icons.ends, icons.ends_n = {}, {}, 0
  icons.route_pts, icons.scr, icons.fonts = {}, {}, {}
  -- Route numbers beside the stop records read this frame. Hoisted; the font
  -- is pushed around the loop and popped even when a draw raises.
  icons.number_loop = function(nrr, px)
    local rr = icons.route_recs
    local st = wt.styles.route_stop
    local o = wt.style.offset(st.width, wt.dk)
    local col = settings.route_number_color
    local abgr, a = A.argb_to_abgr(col), wt.a(col)
    local scale = settings.route_stop_size / 100
    local k = icons:k()
    local dy = px > 0 and px / 2 or 6
    local t1 = st.on and os.clock() or nil
    for i = 1, nrr do
      local rec = rr[i]
      local sx, sy = icons:to_screen(rec.lx, rec.ly)
      local num = icons.nums[rec.marker.stop]
      if num == nil then
        num = tostring(rec.marker.stop)
        icons.nums[rec.marker.stop] = num
      end
      local off = rec.size * scale * k / 2 + 2
      wt.style.text(draw, num, sx + off, sy - dy, abgr, st.on, st.color, o, a)
    end
    if t1 ~= nil then wt.outline_acc = wt.outline_acc + (os.clock() - t1) * 1000 end
  end
  icons.draw_numbers = function(nrr)
    local rns = settings.route_number_size
    local px, font = 0, nil
    if rns > 0 then
      px = math.floor(rns * wt.dk + 0.5)
      font = icons.fonts[px]
      if font == nil then
        local okf, f = pcall(imgui.load_font, nil, px)
        font = (okf and f) or false
        icons.fonts[px] = font
      end
    end
    local pushed = font and pcall(imgui.push_font, font)
    local ok, err = pcall(icons.number_loop, nrr, px)
    if pushed then pcall(imgui.pop_font) end
    if not ok then error(err, 0) end
  end
  -- Full-map layout points of every pair -> screen points (x, y pairs; a
  -- false, false pair is a break). Two consecutive off-screen points get a
  -- break between them; a point is never replaced.
  icons.to_screen_pts = function(pts, n)
    local scr, sn = icons.scr, 0
    local W, H = wt.dw, wt.dh
    local prev_off = nil
    local i = 1
    while i <= n do
      local x = pts[i]
      if x == false then
        scr[sn + 1], scr[sn + 2] = false, false
        sn = sn + 2
        prev_off = nil
        i = i + 1
      else
        local sx, sy = icons:to_screen(x, pts[i + 1])
        local off = sx < 0 or sx > W or sy < 0 or sy > H
        if prev_off and off then
          scr[sn + 1], scr[sn + 2] = false, false
          sn = sn + 2
        end
        scr[sn + 1], scr[sn + 2] = sx, sy
        sn = sn + 2
        prev_off = off
        i = i + 2
      end
    end
    for j = #scr, sn + 1, -1 do scr[j] = nil end
    return sn
  end
  icons.route_lines = function()
    local recs, fp, nf = icons.recs, icons.fit_pts, 0
    local rr, nrr = icons.route_recs, 0
    local fill_at = icons.fill_at
    local rows, ends = icons.end_rows, icons.ends
    for i = 1, icons.ends_n do ends[i] = nil end
    local input = wt.q("input", nil)
    local route = input ~= nil and input.route or nil
    local stops = route ~= nil and route.stops or nil
    local nstops = stops ~= nil and #stops or 0
    for i = 1, #recs do
      local rec = recs[i]
      local m = rec.marker
      if rec.read_at == fill_at and m.pos ~= nil then
        nf = nf + 1
        local row = fp[nf]
        if row == nil then row = {}; fp[nf] = row end
        row[1], row[2], row[3], row[4] = m.pos.x, m.pos.z, rec.lx, rec.ly
        if m.cat == "route_stop" and type(m.stop) == "number" then
          nrr = nrr + 1
          rr[nrr] = rec
          local e = rows[m.stop]
          if e == nil then e = {}; rows[m.stop] = e end
          e.lx, e.ly, e.mx, e.mz = rec.lx, rec.ly, nil, nil
          ends[m.stop] = e
          if m.stop > icons.ends_n then icons.ends_n = m.stop end
        end
      end
    end
    for i = #rr, nrr + 1, -1 do rr[i] = nil end
    if nrr > 0 then icons.draw_numbers(nrr) end
    local pairs_ = wt.q("route_paths", nil, settings.world_undiscovered)
    if pairs_ == nil or #pairs_ == 0 then wt.path_draw_ms = 0; return end
    local fit = icons.npcs.fit(fp, nf, icons.fit_opt, icons.fit)
    for i = 1, nstops do
      if ends[i] == nil then
        local p = stops[i].pos
        if type(p) == "table" then
          local e = rows[i]
          if e == nil then e = {}; rows[i] = e end
          e.lx, e.ly, e.mx, e.mz = nil, nil, p.x, p.z
          ends[i] = e
          if i > icons.ends_n then icons.ends_n = i end
        end
      end
    end
    local t0 = os.clock()
    local n = icons.npcs.route_polyline(pairs_, ends, fit, settings.route_path,
      icons.route_pts)
    local sn = icons.to_screen_pts(icons.route_pts, n)
    if sn > 0 then
      local st = wt.styles.route_line
      local k = icons:k()
      local col = settings.route_line_color
      local t1 = st.on and os.clock() or nil
      wt.style.polyline(draw, icons.scr, settings.route_line_width * k,
        A.argb_to_abgr(col), st.on, st.color, wt.style.offset(st.width, k), wt.a(col))
      if t1 ~= nil then wt.outline_acc = wt.outline_acc + (os.clock() - t1) * 1000 end
    end
    wt.path_draw_ms = (os.clock() - t0) * 1000
  end
  -- One debug line for the walking-path costs (SPEC 23.6.10).
  wt.path_line = function()
    return string.format(
      "Paths: copy max %.2f ms, search max %.2f ms, last expanded %s (pair %s), draw %.2f ms, outline draw %.2f ms",
      wt.copy_ms_max or 0, wt.search_ms_max or 0, tostring(wt.last_expanded),
      tostring(wt.last_pair), wt.path_draw_ms, wt.outline_ms_shown)
  end

  -- The per-frame pass: fill the full-map layer from the records while the
  -- map is up, then draw everything queued (SPEC 21.2.7, 21.4.4).
  function icons.frame()
    pcall(wt.refresh_styles)
    if ui_map ~= nil and os.clock() - icons.map_seen < 0.25 and icons:active() then
      icons:fill(icons.recs, icons.read)
      if wt.route_on then wt.layer_run(wt.lines_layer, "route lines", icons.route_lines) end
    end
    icons:draw()
    -- the whole frame's outline time: the other callbacks ran before this one
    wt.outline_ms_shown = icons.outline_ms + wt.outline_acc
    wt.outline_acc = 0
  end
  icons:preload_all()
  -- v14 (SPEC 22.10): item-menu quest marks. A missing or broken module
  -- must never stop the mod loading.
  local okm, im = pcall(function()
    return require("Clairvoyance.itemmenu").create{
      sdk = sdk, draw = draw,
      enabled = function() return settings.enabled and settings.inventory_quest_marks end,
      related = function() return adapter.item_related(settings.reveal_gate_names) end,
      quest_flag = function(d) return d ~= nil and d:get_field("_SubCategory") == 4 end,
      color_abgr = function() return A.argb_to_abgr(settings.color_quest_item) end,
      screen_h = function() local sz = imgui.get_display_size(); return sz and sz.y or 1080 end,
      clock = os.clock, log = logmsg,
      on_open = adapter.reset_item_throttle,
      imgui = imgui,
      style = function() local st = wt.styles.items; return st.on, st.color, st.width end,
      label_color = function() return A.argb_to_abgr(settings.color_quest_item) end,
      -- the label font, one per pixel size (a failure is cached as false)
      font = (function()
        local cache = {}
        return function()
          local sz = imgui.get_display_size()
          local k = (sz and sz.y or 1080) / 1080
          local px = math.floor(22 * k + 0.5)
          local cached = cache[px]
          if cached == nil then
            local okf, f = pcall(imgui.load_font, nil, px)
            cached = (okf and f) or false
            cache[px] = cached
          end
          return cached or nil
        end
      end)(),
    }
  end)
  if okm and im ~= nil then
    icons.itemmenu = im
    local oki, erri = pcall(im.install, im)
    if not oki then logmsg("item menu install failed: " .. tostring(erri)) end
  else
    logmsg("item menu unavailable: " .. tostring(im))
  end
end
local hover_labels = {}   -- icon address -> label
local hover_stats = { fires = 0, hits = 0, misses = 0, sel_nil = 0,
  same_fallback_n = 0 }
local hover_last_miss = nil
local saved_styles = {}   -- { {ref, scale, prio, color_ptr_value} }
local dropped_count = 0
local added_count = 0
local pool_label = ""
-- The game message "Seeker's Token" (resolved in game via via.gui.message.get).
local hover_name_guid = A.guid_parse("e26516a9-39b1-4e5d-a814-34aba7c7e023")
-- v4 minimap layer (SPEC §11)
local MINIMAP_RADIUS = 200.0
local MINIMAP_MAX = 12
local minimap_renderer = nil
local minimap_unavailable = nil  -- "unavailable: <piece>" or nil
local minimap_logged_errs, minimap_logged_count = {}, 0
local minimap_post_ms, minimap_post_ms_shown, minimap_ms_reset = 0.0, 0.0, 0.0
local last_debug_dump = 0.0   -- readout lines to the REFramework log, 5 s
-- v3 overhead layer (SPEC §10)
local OVERHEAD_POS_INTERVAL = 0.5
local OVERHEAD_Y_OFFSET = 2.1
local OVERHEAD_NAME_DISTANCE = 12.0
local overhead_anchors = {}   -- cid -> { marker, transform, pos }
local overhead_points = {}    -- v8 item points: array of { marker, pos } (SPEC 15.3l)
local overhead_last_pass = 0.0
local overhead_snap = nil
local overhead_gate = "disabled"
local overhead_pass_ms, overhead_draw_ms = 0.0, 0.0
local overhead_pass_ms_shown, overhead_draw_ms_shown = 0.0, 0.0
local overhead_ms_reset = 0.0
local overhead_logged_errs = {}      -- msg -> true, capped
local overhead_logged_count = 0
local overhead_fail_frames = 0
local overhead_suspend_until = 0.0
local overhead_live_hits, overhead_drawn = 0, 0
local overhead_force_estimate = false  -- debug: force label-width fallback
local tree_open_at = nil       -- os.clock() the Quest tree node last drew open
local tree_live_last = false   -- previous tick's tree_live (read by the 5 s dump)
local last_treedge_table = nil  -- dump: last committed tree table audited (by identity)

local function tree_gates_line(ts)
  return string.format(
    "Tree gates: %d gated of %d tracked (%d refs, %d skipped, %d failed walks), walk %.1f ms",
    ts.gated, ts.tracked, ts.refs, ts.skipped, ts.failed_total, ts.last_ms)
end
-- v8 (SPEC 15.3p): item readout lines (debug panel + 5 s dump)
local function items_line(s)
  return string.format("Items: %d needs (%d ids), %d located, walk %.1f ms, %d rounds",
    s.needs, s.ids, s.located, s.last_ms, s.rounds)
end
local function items_detail_line(s, over_cap)
  return string.format(
    "Items detail: %d skipped, %d ignored rows, %d capped, %d failed rounds, logic %s, %d over marker cap",
    s.skipped, s.ignored, s.capped, s.failed_total,
    s.logic_ok and "ok" or "unresolved", over_cap)
end
local settings_dirty = false
local label_widths = {}
local proj_vec = Vector3f.new(0, 0, 0)
-- SPEC §10.3c: reuse one Vector3f only if field writes stick.
local proj_vec_reuse = (function()
  local ok = pcall(function() proj_vec.x = 1.5 end)
  return ok and proj_vec.x == 1.5
end)()

-- Boxed scratch objects (SPEC 5.12.6), created at load and kept for the
-- script's life; payload offsets come from the adapter (SPEC 5.12.1).
local int_t = sdk.find_type_definition("System.Int32")
local uint_t = sdk.find_type_definition("System.UInt32")
local idx_obj = int_t:create_instance():add_ref()
local color_obj = uint_t:create_instance():add_ref()
local INT_OFF, UINT_OFF = A.int_value_offset, A.uint_value_offset

local function catalog_side_count()
  local side = 0
  for _, q in ipairs(A.catalog_ids() or {}) do
    if adapter.is_side(q) then side = side + 1 end
  end
  return side
end

-- One-shot giver audit (debug): every catalog side quest with no curated
-- giver hint is logged with its cast candidates and CharacterID enum labels,
-- so hints can be curated against the game's own character names.
local giver_audit_done = false
local function giver_audit()
  if giver_audit_done then return end
  local labels = nil
  local function label_of(cid)
    if labels == nil then
      labels = {}
      pcall(function()
        local td = sdk.find_type_definition("app.CharacterID")
        for _, f in ipairs(td:get_fields()) do
          if f:is_static() then
            local ok, v = pcall(function() return f:get_data(nil) end)
            if ok and type(v) == "number" then
              labels[v % 4294967296] = f:get_name()
            end
          end
        end
      end)
    end
    return labels[cid]
  end
  local done, audited = A.giver_audit_step(A.catalog_ids(), A.GIVER_HINTS,
    adapter.is_side, A.get_runtime_cast_charaids, label_of, logmsg)
  if not done then return end
  giver_audit_done = true
  logmsg(string.format("GiverAudit: done, %d hintless quests audited", audited))
end

-- v9 (SPEC 16.10): every expanded row (panel set + debug set); the tick, the
-- 5 s dump and QNML_DEBUG.state all read this one rule.
local function expanded_union()
  local exp = {}
  for q in pairs(tree_expanded) do exp[q] = true end
  for q in pairs(debug_expanded) do exp[q] = true end
  return exp
end
local function jump_line(r)
  return string.format(
    "Jump: %s via %s, target %.1f, %.1f, readback %s, setupMapIcon fires in 2 s %s",
    r.result, r.branch or "none", r.target.x, r.target.z,
    r.readback and string.format("%.1f, %.1f", r.readback.x, r.readback.z) or "none",
    r.setup_2s ~= nil and tostring(r.setup_2s) or "pending")
end

re.on_frame(function()
  local now = os.clock()
  if now - last_tick < REFRESH_INTERVAL then return end
  last_tick = now
  if settings_dirty then settings_dirty = false; save_settings() end
  if not settings.enabled then return end
  if settings.debug and now - last_debug_dump >= 5.0 then
    last_debug_dump = now
    -- Full debug-readout parity with the settings panel, so a test run can
    -- be read back from the REFramework log instead of screenshots. Own
    -- pcall: a format error here must never abort the tick below.
    local okd, errd = pcall(function()
      if snapshot ~= nil then
        local c = snapshot.counts
        logmsg(string.format(
          "Quests: startable %d, in progress %d, completed %d, failed %d, canceled %d, giver dead %d, locked %d, resolved %d",
          c.startable, c.in_progress, c.completed, c.failed, c.canceled,
          c.giver_dead, c.locked, snapshot.resolved_count))
        local ulines = {}
        for qid, u in pairs(snapshot.unresolved) do
          ulines[#ulines + 1] = string.format("[%d] %s: %s",
            qid, u.name or "?", u.reason)
        end
        table.sort(ulines)
        for _, line in ipairs(ulines) do logmsg("Unresolved: " .. line) end
      end
      local acount = 0
      for _ in pairs(overhead_anchors) do acount = acount + 1 end
      logmsg(string.format(
        "Overhead: anchors %d, points %d, live hits %d, drawn %d, pass %.2f ms, draw %.2f ms, gate %s, vec reuse %s",
        acount, #overhead_points, overhead_live_hits, overhead_drawn,
        math.max(overhead_pass_ms_shown, overhead_pass_ms),
        math.max(overhead_draw_ms_shown, overhead_draw_ms),
        overhead_gate, tostring(proj_vec_reuse)))
      if minimap_unavailable ~= nil then
        logmsg("Minimap: " .. minimap_unavailable)
      else
        local mr = minimap_renderer
        logmsg(string.format(
          "Minimap: candidates %d, clipped %d, shown %d, dropped %d, pool %s, free %s, post %.2f ms, nearest %s, owned %d, hud changes %d, status %s",
          mr.candidates_n, mr.clipped, mr.shown, mr.dropped,
          mr.icons_mode and "-" or tostring(mr.pool_n),
          mr.icons_mode and "-" or tostring(mr.free_n),
          math.max(minimap_post_ms_shown, minimap_post_ms),
          mr.nearest ~= nil and string.format("%.0f m", mr.nearest) or "-",
          #mr.owned, mr.hud_changes, mr.status))
      end
      logmsg(icons:stats_line())
      logmsg(wt.path_line())
      local cs = A.catalog_stats()
      logmsg(string.format(
        "Catalog: %d entries, %d skipped (%d cast), %d distinct side IDs (%d total)",
        cs.entries, cs.skipped, cs.cast_skipped, catalog_side_count(), cs.distinct))
      local os_ = adapter.objective_stats ~= nil and adapter.objective_stats() or nil
      if os_ ~= nil then
        logmsg(string.format(
          "Objectives: %d quests from %d processors (%d kept, %d skipped, %d failed walks, %d builds), walk max %.1f ms",
          os_.quests, os_.entries, os_.kept, os_.skipped, os_.failed_total,
          os_.index_builds or 0, walk_ms_max))
      end
      local gs = adapter.gate_stats ~= nil and adapter.gate_stats() or nil
      if gs ~= nil then
        logmsg(string.format(
          "Gates: %d gated of %d acceptable (%d refs, %d skipped, %d failed walks), walk %.1f ms",
          gs.gated, gs.acceptable, gs.refs, gs.skipped, gs.failed_total,
          gs.last_ms))
      end
      local is_ = adapter.item_stats ~= nil and adapter.item_stats() or nil
      if is_ ~= nil then
        logmsg(items_line(is_))
        logmsg(items_detail_line(is_,
          snapshot ~= nil and snapshot.item_capped or 0))
      end
      if tree_live_last and adapter.tree_gate_stats ~= nil then
        local ts = adapter.tree_gate_stats()
        logmsg(tree_gates_line(ts))
        -- every commit installs a NEW table, so identity survives the
        -- stats resets (collapse, owner change) that zero `commits`
        local tt = adapter.tree_gate_table()
        if tt ~= nil and tt ~= last_treedge_table then
          last_treedge_table = tt
          local tqids = {}
          for qid in pairs(tt) do
            tqids[#tqids + 1] = qid
          end
          table.sort(tqids)
          for _, qid in ipairs(tqids) do
            logmsg("TreeEdge: [" .. qid .. "] -> " .. table.concat(tt[qid], ", "))
          end
        end
      end
      logmsg(string.format("Tick: %.1f ms (median %.1f)", last_tick_ms,
        su.median(wt.tick_ring or {}) or 0.0))
      logmsg(string.format("Rebuild: ms=%.1f max=%.1f", wt.rebuild_ms, wt.rebuild_max))
      logmsg(wt.line())
      if snapshot ~= nil and adapter.journal_stats ~= nil then
        logmsg(core.journal_line(adapter.journal_stats()))
      end
      if snapshot ~= nil then   -- no snapshot before the first compute / after a reset
        for _, l in ipairs(core.state_lines(snapshot, expanded_union(),
            settings.journal_spoilers)) do logmsg("Detail: " .. l) end
      end
      for _, r in ipairs(jump_log) do logmsg(jump_line(r)) end
      giver_audit()
    end)
    walk_ms_max = 0.0
    wt.rebuild_max = 0
    if not okd then logerr("debug dump: " .. tostring(errd)) end
  end
  local ok, err = pcall(function()
    if adapter.reset_session_caches() then
      -- Save/session changed: old save's markers must not survive while the
      -- new save's quest lists are still unavailable.
      snapshot = nil
      committed = {}
      want_update = true
      pcall(wt.reset, wt)
      wt.world_origin = nil
      wt.kinds_seen = { large = {}, small = {} }
      wt.fam_names = { large = {}, small = {} }
      wt.map_origin, wt.map_origin_at = nil, nil
      if wt.route_cid ~= nil then logmsg("route cleared: save or session changed") end
      wt.hints_open, wt.route_cid = {}, nil   -- SPEC 22.6.6
    end
    -- v9: a debug-expanded qid keeps the tree live (QNML_DEBUG, SPEC 16.10)
    local tree_live = core.tree_wanted(now, tree_open_at)
      or (settings.debug and next(debug_expanded) ~= nil)
    local expanded = tree_live and expanded_union() or nil
    tree_live_last = tree_live
    local show = {
      tree_open = tree_live,
      startable = settings.show_startable,
      in_progress = settings.show_in_progress,
      quest_items = settings.show_quest_items,
      completed = settings.show_completed,
      unavailable = settings.show_unavailable,
      locked = settings.show_locked,
      reveal_gate_names = settings.reveal_gate_names,
      origin = player_origin,
      -- v9 (SPEC 16.3b, 16.3e): tree detail inputs
      tree_origin = core.tree_origin(player_origin, player_origin_t, now),
      expanded = expanded,
      journal_spoilers = settings.journal_spoilers,
      prev_journal = snapshot and snapshot.journal,
      prev_journal_all = snapshot and snapshot.journal_all,
      step_icons = settings.step_icons,
      prev_quest_steps = snapshot and snapshot.quest_steps,
      now = now,
      search = core.parse_query(settings.search_text),   -- SPEC 19.5; nil = no search
      -- v14 (SPEC 22.10, 22.11)
      inventory_quest_marks = settings.inventory_quest_marks,
      item_menu_open = icons.itemmenu ~= nil and icons.itemmenu:open(),
    }
    show.hint_qids, show.hint_pins = wt.hint_inputs()
    -- SPEC 32.4.2: the tracked read runs every tick, tree open or not
    if settings.focus_tracked then
      local okt, tq = pcall(adapter.tracked_qid)
      wt.focus_tracked_qid = okt and type(tq) == "number" and tq or nil
    else
      wt.focus_tracked_qid = nil
    end
    show.focus_qids = settings.focus_qids
    show.focus_tracked_qid = wt.focus_tracked_qid
    show.quest_rel = wt.quest_rel
    show.focus_unrelated = settings.focus_unrelated
    show.focus_on = snapshot ~= nil and snapshot.focus ~= nil
    -- SPEC 22.8.4: the route NPC lasts while the search shows it
    if wt.route_cid ~= nil then
      local keep = false
      if show.search ~= nil then
        -- a snapshot built without world input matched nothing: not a "no"
        if snapshot == nil or snapshot.world == nil then
          keep = true
        else
          for _, c in ipairs(snapshot.npc_match_cids or {}) do
            if c == wt.route_cid then keep = true; break end
          end
        end
      end
      if not keep then
        logmsg(string.format("route cleared: search %s, world %s, %d matched",
          tostring(show.search ~= nil), tostring(snapshot ~= nil and snapshot.world ~= nil),
          snapshot ~= nil and #(snapshot.npc_match_cids or {}) or -1))
        wt.route_cid = nil; wt.q("clear_route", nil)
      end
    end
    -- SPEC 19.4c: the first tick of a search asks the world for a round now
    if show.search ~= nil and not wt.search_on then wt.q("poke", nil) end
    wt.search_on = show.search ~= nil
    -- SPEC 20.1.4, 28.7.3: any world toggle turning on pokes the round the same way
    if su.world_toggled(wt.prev_tg, settings) then wt.q("poke", nil) end
    local t0 = os.clock()
    -- v10 (SPEC 17.3a): world round, own pcall so a raise never skips compute;
    -- inside the timed window. The gate (evaluated here) is: a snapshot from
    -- before this tick exists and the player was seen: by the minimap under
    -- 3 s ago, or (HUD hidden) read directly from its transform.
    local ok_w, err_w = pcall(function()
      if world == nil then return end   -- the stub tracker has no round to run
      local mr = minimap_renderer
      local seen = mr ~= nil and now - mr.pl_seen_at < world.K.PLAYER_SEEN_S
      local p = seen and mr.pl_pos or nil
      if p == nil then
        -- a hidden HUD hides the minimap: read the player directly (v14)
        local okt, tr = pcall(wt.player_tr)
        local u = okt and tr ~= nil and tr:call("get_UniversalPosition") or nil
        if u ~= nil then p = { x = u.x, y = u.y, z = u.z }; seen = true end
      end
      if p ~= nil then
        local o = wt.world_origin
        if o == nil or core.dist(p, o) >= world.K.REORIGIN then
          wt.world_origin = { x = p.x, y = p.y, z = p.z }
        end
      end
      local gate = snapshot ~= nil and seen
      -- the round's toggle names are the setting names without "world_"
      local tg = {}
      for _, k in ipairs(su.WORLD_BOOLS) do tg[k:sub(7)] = settings[k] end
      tg.reveal_gate_names = settings.reveal_gate_names   -- chest quest names (SPEC 27.4.2)
      tg.search = show.search ~= nil
      tg.npc_cids = snapshot ~= nil and snapshot.npc_match_cids or nil   -- Ruling 10
      -- quest focus (SPEC 32.7): previous snapshot's focus, route members, poke on a set change
      tg.focus, tg.focus_keys = wt.focus_world(snapshot)
      wt.q("set_routes", nil, (wt.route_members(snapshot, wt.q("input", nil))))
      local fa = snapshot ~= nil and snapshot.focus ~= nil and snapshot.focus.active or nil
      local fs = table.concat(fa or {}, ",") .. "|" .. tostring(settings.focus_unrelated)
      if fs ~= wt.focus_sig then
        wt.focus_sig = fs
        wt.focus_pokes = (wt.focus_pokes or 0) + 1
        wt.q("poke", nil)
      end
      -- SPEC 28.8.2: the full map's UI object or the game's paused-GUI read holds throttled rounds
      local hold = ui_map ~= nil or adapter.map_menu_open() == true
      if wt:refresh(now, gate, tg, hold) then wt.line_txt = nil end
    end)
    if not ok_w then logerr("world round: " .. tostring(err_w)) end
    for _, k in ipairs(su.WORLD_BOOLS) do show[k] = settings[k] end
    for _, k in ipairs(su.WORLD_KIND_BOOLS) do show[k] = settings[k] end
    show.world_max_markers = settings.world_max_markers
    show.world_monster_off = settings.world_monster_off
    show.world_origin = wt.world_origin
    show.map_origin = wt.map_origin
    show.world_givers = wt.q("givers", {})
    show.world = wt.q("input", nil)
    show.route = (show.world or {}).route   -- SPEC 22.8.4
    -- the frame layers do no work while there is no route and no pin
    wt.route_on = type(show.route) == "table" and type(show.route.stops) == "table"
      and #show.route.stops > 0
    wt.has_pts = wt.route_on or #show.hint_pins > 0
    -- v5 (SPEC 12.3a): own pcall so a raised walk never skips compute;
    -- inside the timed window so Tick ms includes it; skipped when the
    -- category is hidden (SPEC 9.9).
    if (show.in_progress or show.focus_on) and adapter.refresh_objectives ~= nil then
      wt.obj_walks = (wt.obj_walks or 0) + 1
      local tw = os.clock()
      local ok_o, err_o = pcall(adapter.refresh_objectives)
      last_walk_ms = (os.clock() - tw) * 1000.0
      if last_walk_ms > walk_ms_max then walk_ms_max = last_walk_ms end
      if not ok_o then logerr("objective walk: " .. tostring(err_o)) end
    else
      last_walk_ms = 0.0
    end
    -- v6 (SPEC 13.3a.2): gate walk is self-throttled; while the startable
    -- category is hidden every tick invalidates (stateless, no edge tracking).
    if show.startable and adapter.refresh_gates ~= nil then
      local ok_g, err_g = pcall(adapter.refresh_gates)
      if not ok_g then logerr("gate walk: " .. tostring(err_g)) end
    elseif adapter.invalidate_gates ~= nil then
      pcall(adapter.invalidate_gates)
    end
    -- v8 (SPEC 15.3a): item round self-throttled (10 s) + per-call drop
    -- scan; with either toggle off every tick invalidates (stateless, no
    -- edge tracking) and no managed call runs.
    if adapter.refresh_items ~= nil then
      if core.item_walk_wanted(show) then
        -- Ruling 9: a round widening from the menu's need read to the full
        -- round runs at once
        local mode = core.item_walk_mode(show)
        if wt.item_mode == "needs" and mode == "full" and adapter.reset_item_throttle ~= nil then
          pcall(adapter.reset_item_throttle)
        end
        wt.item_mode = mode
        local ok_i, err_i = pcall(adapter.refresh_items, mode)
        if not ok_i then logerr("item walk: " .. tostring(err_i)) end
      else
        wt.item_mode = nil
        pcall(adapter.invalidate_items)
      end
    end
    local result = core.compute(adapter, show)
    -- v7 (SPEC 14.3e): tree walk only while the Quest tree node is open;
    -- after compute so a reset tick's state cache is warm before the walk.
    if tree_live and adapter.refresh_tree_gates ~= nil then
      local ok_t, err_t = pcall(adapter.refresh_tree_gates)
      if not ok_t then logerr("tree walk: " .. tostring(err_t)) end
    elseif adapter.invalidate_tree_gates ~= nil then
      pcall(adapter.invalidate_tree_gates)
    end
    last_tick_ms = (os.clock() - t0) * 1000.0
    if settings.debug then   -- SPEC 28.11.2: the last 20 ticks, for the median
      wt.tick_n = ((wt.tick_n or 0) % 20) + 1
      wt.tick_ring[wt.tick_n] = last_tick_ms
    end
    if result == nil then return end   -- game state unavailable: keep last snapshot
    -- SPEC 20.12.2: one signature over the markers then the full-map world
    -- markers, so committed positions are kept for both
    local all = result.markers
    local fw = result.fullmap_world
    if fw ~= nil and #fw > 0 then
      all = {}
      for _, m in ipairs(result.markers) do all[#all + 1] = m end
      for _, m in ipairs(fw) do all[#all + 1] = m end
    end
    local sig, new_committed = core.signature(all, committed)
    committed = new_committed
    local changed = snapshot == nil or sig ~= snapshot.sig
    result.sig = sig
    snapshot = result   -- always replace: counts/unresolved stay fresh
    local wm = result.world and result.world.monster or nil
    for _, k in ipairs((wm and wm.kinds) or {}) do
      local seen = wt.kinds_seen[k.small and "small" or "large"]
      local fam = core.fam_of(k)
      local set = seen[fam]
      if set == nil then set = {}; seen[fam] = set end
      set[k.kind] = true
    end
    for _, f in ipairs((wm and wm.families) or {}) do
      if type(f.fam) == "string" and type(f.name) == "string" then
        wt.fam_names[f.small and "small" or "large"][f.fam] = f.name
      end
    end
    if changed and ui_map ~= nil then want_update = true end
  end)
  if not ok then logerr("tick error: " .. tostring(err)) end
  -- Learn names of quests regardless of visibility (budgeted), then save.
  -- Save is a no-op unless a new name was learned.
  pcall(A.learn_names, 32)
  pcall(A.save_learned_names)
end)

local function restore_styles()
  for _, rec in ipairs(saved_styles) do
    pcall(function()
      rec.ref:set_Scale(rec.scale)
      rec.ref:set_Prio(rec.prio)
      if rec.color ~= nil then rec.ref:set_Color(rec.color) end
    end)
  end
  saved_styles = {}
end

local native_max_prio = 0   -- highest Prio among NATIVE icons, set per rebuild
local pool_used, pool_limit = 0, 0

local add_markers
do
  -- Kept (project-owned) pieces of add_markers: the resets and guards, the
  -- readout fields, the counts, the icon and color per category, the unique
  -- id per marker, the hover label and the debug line.
  local function begin_rebuild()
    hover_labels = {}
    icons.recs = {}
    added_count, dropped_count = 0, 0
    return settings.enabled and snapshot ~= nil
  end
  local function note_pool(pool, used, limit)
    pool_label = pool and pool.label or "none"
    if pool ~= nil then pool_used, pool_limit = used, limit end
  end
  local function note_dropped() dropped_count = dropped_count + 1 end
  -- SPEC 21.4.2, Ruling 3: the game icon type written is always the id
  -- that has full-map art, so the hidden glyph keeps its hover area.
  local function marker_icon_type(m)
    return su.icon_for(settings, m, "map", m.step, icons.never)
  end
  local function marker_unique_id(m)
    -- v8 (SPEC 15.3j): the prefix per marker is chosen in the adapter
    return A.new_unique_id(A.map_marker_guid(m))
  end
  local function note_added(icon, m)
    added_count = added_count + 1
    hover_labels[icon:get_address()] = m.hover or m.label
  end
  local function marker_argb(m)
    return su.marker_color(settings, m)
  end
  -- Queues the marker's picture for the draw pass when it can be drawn;
  -- true means the game glyph is hidden (alpha byte 0).
  local function note_picture(pool, ref, m)
    if pool.label ~= "sprite" or not icons.read_ok then return false end
    local pid = su.icon_for(settings, m, "head", m.step, icons.never)
    if not icons:drawable(pid) then return false end
    local sprite = ref.Sprite
    if sprite == nil then return false end
    local recs = icons.recs
    recs[#recs + 1] = { marker = m, id = pid, ref = ref, sprite = sprite,
      cat = m.cat, size = icons.map_size(sprite), argb = marker_argb(m) }
    return true
  end
  local function log_rebuild()
    if settings.debug then
      local sample = next(hover_labels)
      logmsg(string.format(
        "rebuild: added=%d dropped=%d pool=%s native_used=%d limit=%d sample_icon=%s ms=%.1f",
        added_count, dropped_count, pool_label, pool_used, pool_limit,
        tostring(sample), wt.rebuild_ms))
    end
  end

  -- SPEC 5.13.1
  local function build(this)
    if not begin_rebuild() then return end
    local pool, used, limit, native_refs = A.get_icon_pool(this)
    note_pool(pool, used, limit)
    if pool == nil then return end
    local top = 0
    for _, r in ipairs(native_refs) do
      local p = r:get_Prio()
      if p > top then top = p end
    end
    native_max_prio = top
    local cursor = used
    idx_obj:write_dword(INT_OFF, cursor)
    for _, m in ipairs(core.fullmap_order(snapshot.markers,
      wt.map_origin or wt.world_origin, snapshot.fullmap_world)) do
      local pos = Vector3f.new(m.pos.x, m.pos.y, m.pos.z)
      if this:isInDispRange(pos) then
        if cursor >= limit then
          note_dropped()
        else
          local info = A.new_map_icon_info()
          info.IconType = marker_icon_type(m)
          info.Pos = pos
          info.UniqId = marker_unique_id(m)
          local icon = pool.add(this, info, 0, idx_obj:get_address() + INT_OFF,
            -1, hover_name_guid, false)
          if icon == nil then break end
          cursor = idx_obj:read_dword(INT_OFF)
          note_added(icon, m)
          local ref = icon[pool.ref]
          if ref ~= nil then
            local okc, col = pcall(function() return ref:get_Color() end)
            saved_styles[#saved_styles + 1] = {
              ref = ref, scale = ref:get_Scale(), prio = ref:get_Prio(),
              color = okc and col or nil }
            local argb = marker_argb(m)
            local okn, hidden = pcall(note_picture, pool, ref, m)
            if okn and hidden then argb = argb & 0x00FFFFFF end
            color_obj:write_dword(UINT_OFF, A.argb_to_abgr(argb))
            ref:set_Color(color_obj:get_address() + UINT_OFF)
          end
        end
      end
    end
    return true
  end

  -- SPEC 20.12.8: timed around every call, early returns included;
  -- the debug line only for a rebuild that ran, as before
  add_markers = function(this)
    local t0 = os.clock()
    local ok, ran = pcall(build, this)
    wt.rebuild_ms = (os.clock() - t0) * 1000
    wt.rebuild_max = math.max(wt.rebuild_max, wt.rebuild_ms)
    if ok and ran then log_rebuild() end
    if not ok then error(ran, 0) end
  end
end

local hooked_this = nil
do
  -- Kept (project-owned) pieces of the .ctor pre hook.
  -- v9: .ctor only; the setupMapIcon re-capture never counts
  local function note_ctor() map_ctor_n = map_ctor_n + 1 end

  -- SPEC 5.13.4.1 (.ctor pre) and 5.13.4.2 (onDestroy pre)
  A.hook_method("app.ui040205", ".ctor", function(args)
    ui_map = sdk.to_managed_object(args[2])
    note_ctor()
    hover_labels = {}
    saved_styles = {}
    icons.recs = {}
    -- deliberate rebuilds get exactly one updateMapIcon; the refire stops on the unchanged sig
    last_add_sig = nil
  end)
  A.hook_method("app.ui040205", "onDestroy", function(args)
    hover_labels = {}
    saved_styles = {}
    icons.recs = {}
    ui_map = nil
    wt.set_map_origin(nil, nil)   -- SPEC 20.12.7
  end)
end

-- v9 (SPEC 16.3g): the jump machine; every decision lives in jump.lua.
local jump_machine = jump.new({
  open = adapter.map_open,
  apply = adapter.map_jump_apply,
  ui = function() return ui_map end,
  is_live = sdk.is_managed_object,
  ctor_count = function() return map_ctor_n end,
  menu_open = adapter.map_menu_open,
  close_menu = adapter.map_close_menu,
})

-- SPEC 20.12.5: while the full map is open, follow the map cursor. The
-- cursor only moves when the jump applies, so the driver waits for the machine.
-- Defined once, so no closure is built per frame.
do
  local function map_follow()
    if ui_map == nil or jump_machine:busy() then return end
    local now = os.clock()
    local o, at = core.map_origin_step(wt.map_origin, adapter.map_cursor(ui_map),
      wt.world_origin and wt.world_origin.y, now, wt.map_origin_at or 0)
    if at ~= (wt.map_origin_at or 0) then
      wt.set_map_origin(o, at)
      wt.map_retakes = wt.map_retakes + 1
    end
  end
  re.on_frame(function()
    local ok, err = pcall(map_follow)
    if not ok and tostring(err) ~= wt.map_last_err then
      wt.map_last_err = tostring(err)
      logerr("map cursor: " .. wt.map_last_err)
    end
  end)
end

local function apply_styles(this)
  local scale = this.IconScale
  for _, rec in ipairs(saved_styles) do
    rec.ref:set_Scale(scale)
    rec.ref:set_Prio(native_max_prio + 1)
  end
  pcall(icons.resize)
end

-- ===== v4 minimap layer (SPEC §11) =====
do
local minimap_color_obj = uint_t:create_instance():add_ref()  -- SPEC 5.14.1
minimap_renderer = require("Clairvoyance.minimap").create({
  settings = settings,
  clock = os.clock,
  vector = function(x, y, z) return Vector3f.new(x, y, z) end,
  set_color = function(ref, argb)
    minimap_color_obj:write_dword(UINT_OFF, A.argb_to_abgr(argb))
    ref:set_Color(minimap_color_obj:get_address() + UINT_OFF)
  end,
  icon_for = function(m)
    return su.icon_for(settings, m, "mini", m.step, icons.drawable_fn)
  end,
  icons_on = function() return icons.mini_read_ok and icons:active() end,
  frame_info = function(ui)
    local px, py, fade, vis = icons.frame_info(ui)
    -- kept for the coordinates readout under the minimap
    wt.mini_x, wt.mini_y, wt.mini_vis, wt.mini_t = px, py, vis, os.clock()
    wt.mini_fade = fade
    return px, py, fade, vis
  end,
  push = icons.mini_push,
  mini_replace = icons.mini_clear,
  picture_for = icons.picture_for,
  drawable = icons.drawable_fn,
  color_for = function(m)
    return su.marker_color(settings, m)
  end,
  snapshot = function() return snapshot end,
  candidates = function(snap, origin)
    if origin ~= nil then
      local po = player_origin
      if po == nil then po = {}; player_origin = po end
      po.x, po.y, po.z = origin.x, origin.y, origin.z
      player_origin_t = os.clock()
    end
    return core.minimap_markers(snap.markers, origin, MINIMAP_RADIUS, MINIMAP_MAX)
  end,
  is_live = function(ref) return sdk.is_managed_object(ref) end,
})
end

local function minimap_log(err)
  local msg = tostring(err)
  if not minimap_logged_errs[msg] and minimap_logged_count < 16 then
    minimap_logged_errs[msg] = true
    minimap_logged_count = minimap_logged_count + 1
    logerr("minimap error: " .. msg)
  end
end

-- Install gate (SPEC §11.2.0).
local ui020301_t = sdk.find_type_definition("app.ui020301")
local mm_update = ui020301_t and ui020301_t:get_method("updateIcon") or nil
if ui020301_t == nil then
  minimap_unavailable = "unavailable: app.ui020301"
elseif mm_update == nil then
  minimap_unavailable = "unavailable: updateIcon"
elseif thread == nil or thread.get_hook_storage == nil then
  minimap_unavailable = "unavailable: thread.get_hook_storage"
end
if minimap_unavailable ~= nil then
  logmsg("minimap layer " .. minimap_unavailable)
else
  do
    -- Kept (project-owned) pieces of the updateIcon post hook: the POST
    -- timing and the report to the renderer's suspension counter.
    local function post_start() return os.clock() end
    local function post_stop(t0)
      local nowc = os.clock()
      local ms = (nowc - t0) * 1000.0
      if ms > minimap_post_ms then minimap_post_ms = ms end
      if nowc - minimap_ms_reset >= 2.0 then
        minimap_ms_reset = nowc
        minimap_post_ms_shown = minimap_post_ms
        minimap_post_ms = 0.0
      end
      return nowc
    end
    local function post_report(ok, err, nowc)
      minimap_renderer:record_post(ok, err, nowc)
    end

    -- PRE: never gated, never suspended; failures log but never
    -- count toward suspension (SPEC §11.3).
    -- SPEC 5.14.2
    sdk.hook(mm_update, function(args)
      local this = sdk.to_managed_object(args[2])
      if this == nil then return end
      thread.get_hook_storage().qnml_minimap = this
      local ok, err = pcall(minimap_renderer.before, minimap_renderer, this)
      if not ok then minimap_log(err) end
    end, function(retval)
      local store = thread.get_hook_storage()
      local this = store.qnml_minimap
      if this ~= nil then
        store.qnml_minimap = nil
        local t0 = post_start()
        local ok, err = pcall(minimap_renderer.after, minimap_renderer, this)
        local nowc = post_stop(t0)
        if not ok then minimap_log(err) end
        post_report(ok, err, nowc)
      end
      return retval
    end)
    local mm_destroy = ui020301_t:get_method("onDestroy")
    if mm_destroy ~= nil then
      sdk.hook(mm_destroy, function(args)
        local ok, err = pcall(minimap_renderer.destroy, minimap_renderer,
          sdk.to_managed_object(args[2]))
        if not ok then minimap_log(err) end
      end)
    end
  end
end

-- ===== v3 overhead layer (SPEC §10) =====
local function camera_pos()
  local cam = sdk.get_primary_camera()
  if cam == nil then return nil end
  local go = cam:call("get_GameObject")
  if go == nil then return nil end
  local tr = go:call("get_Transform")
  if tr == nil or not sdk.is_managed_object(tr) then return nil end
  local p = tr:call("get_Position")
  if p == nil then return nil end
  return p.x, p.y, p.z
end

-- Hoisted so the per-anchor pcall allocates no closure (SPEC §10.5).
local function read_tr_pos(tr)
  local p = tr:call("get_Position")
  return p.x, p.y, p.z
end

local function overhead_pass(cx, cy, cz)
  local prev = {}
  for cid, a in pairs(overhead_anchors) do prev[cid] = a.pos end
  local cam = { x = cx, y = cy, z = cz }
  local radius = settings.overhead_distance + 20
  local cands = core.overhead_anchors(snapshot.markers, prev, cam, radius)
  local new_anchors, hits = {}, 0
  for _, cand in ipairs(cands) do
    local live = A.npc_live_pos(cand.cid)
    if live ~= nil then
      hits = hits + 1
      new_anchors[cand.cid] = { marker = cand.marker,
        transform = live.transform,
        pos = { x = live.x, y = live.y, z = live.z } }
    end
  end
  overhead_anchors = new_anchors
  -- v8 (SPEC 15.3l.2): item points rebuilt from scratch each pass, stored
  -- as core returns them (pos = a plain copy of the transform-space live)
  overhead_points = core.overhead_points(snapshot.markers, cam, radius)
  overhead_live_hits = hits
  overhead_snap = snapshot
  overhead_last_pass = os.clock()
end

local function label_width(label)
  local w = label_widths[label]
  if w ~= nil then return w end
  if not overhead_force_estimate then
    local ok, size = pcall(imgui.calc_text_size, label)
    if ok and size ~= nil and size.x ~= nil then w = size.x end
  end
  w = w or (#label * 7)
  label_widths[label] = w
  return w
end

-- Records why this frame drew nothing (shown in the debug line).
local function overhead_idle(gate)
  overhead_gate = gate
  overhead_drawn = 0
end

-- One overhead dot (+ the name inside 12 m) at a transform-space point.
-- Shared by the c-keyed anchors and the v8 item points; hoisted, so the
-- per-frame loops allocate no closure. Returns 1 when drawn, else 0.
local function overhead_draw_one(marker, px, py, pz, d2, name_d2)
  local sp
  if proj_vec_reuse then
    proj_vec.x, proj_vec.y, proj_vec.z = px, py + OVERHEAD_Y_OFFSET, pz
    sp = draw.world_to_screen(proj_vec)
  else
    sp = draw.world_to_screen(
      Vector3f.new(px, py + OVERHEAD_Y_OFFSET, pz))
  end
  if sp == nil then return 0 end
  local argb = su.color_of(settings, marker.cat)
  -- SPEC 21.6: the category picture when it can be drawn, else the v12 dots.
  local pid = su.icon_for(settings, marker, "head", marker.step, icons.drawable_fn)
  local pic = icons:drawable(pid)
  local st = wt.styles[wt.style.group_of(marker.cat)] or wt.styles.none
  local o = wt.style.offset(st.width, wt.dk)
  local label_dy = 10
  if pic then
    local size = 24
    if marker.cat == "route_stop" then size = 24 * settings.route_stop_size / 100 end
    icons:push("head", pid, sp.x, sp.y, size, argb, 1, st)
    label_dy = 12 * size / 24 * icons:k() + 2
  else
    wt.style.circle(draw, sp.x, sp.y, 6, A.argb_to_abgr(argb), st.on, st.color,
      o, 24, wt.a(argb))
  end
  if d2 <= name_d2 then
    local label = marker.label or ""
    local w = label_width(label)
    local tx, ty = sp.x - w / 2, sp.y + label_dy
    wt.style.text(draw, label, tx, ty, 0xFFFFFFFF, st.on, st.color, o)
  end
  return 1
end

local function overhead_frame()
  if not settings.enabled then return overhead_idle("disabled") end
  if not settings.show_overhead then return overhead_idle("toggle") end
  if snapshot == nil then
    overhead_anchors = {}
    overhead_points = {}
    overhead_snap = nil
    return overhead_idle("no snapshot")
  end
  if ui_map ~= nil then return overhead_idle("map open") end
  local cx, cy, cz = camera_pos()
  if cx == nil then return overhead_idle("no camera") end
  overhead_gate = "drawing"

  local now = os.clock()
  if snapshot ~= overhead_snap
    or now - overhead_last_pass >= OVERHEAD_POS_INTERVAL then
    if snapshot ~= overhead_snap then label_widths = {} end
    local t0 = os.clock()
    overhead_pass(cx, cy, cz)
    local ms = (os.clock() - t0) * 1000.0
    if ms > overhead_pass_ms then overhead_pass_ms = ms end
  end

  local t0 = os.clock()
  local max_d2 = settings.overhead_distance * settings.overhead_distance
  local name_d2 = OVERHEAD_NAME_DISTANCE * OVERHEAD_NAME_DISTANCE
  local drawn = 0
  for cid, a in pairs(overhead_anchors) do
    local alive = sdk.is_managed_object(a.transform)
    local ok_pos, px, py, pz = false, nil, nil, nil
    if alive then
      ok_pos, px, py, pz = pcall(read_tr_pos, a.transform)
    end
    if not ok_pos or px == nil then
      -- Freed/despawned/invalid: drop until the next pass re-resolves.
      overhead_anchors[cid] = nil
    else
      a.pos.x, a.pos.y, a.pos.z = px, py, pz
      local dx, dy, dz = px - cx, py - cy, pz - cz
      local d2 = dx * dx + dy * dy + dz * dz
      if d2 <= max_d2 then
        drawn = drawn + overhead_draw_one(a.marker, px, py, pz, d2, name_d2)
      end
    end
  end
  -- v8 (SPEC 15.3l.3): item points - plain numbers from the last scan:
  -- no managed call, no is_managed_object, no pcall'd read per point.
  for _, pt in ipairs(overhead_points) do
    local p = pt.pos
    local dx, dy, dz = p.x - cx, p.y - cy, p.z - cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 <= max_d2 then
      drawn = drawn + overhead_draw_one(pt.marker, p.x, p.y, p.z, d2, name_d2)
    end
  end
  overhead_drawn = drawn
  local dms = (os.clock() - t0) * 1000.0
  if wt.any_on then wt.outline_acc = wt.outline_acc + dms end
  if dms > overhead_draw_ms then overhead_draw_ms = dms end
  if now - overhead_ms_reset >= 2.0 then
    overhead_ms_reset = now
    overhead_pass_ms_shown = overhead_pass_ms
    overhead_draw_ms_shown = overhead_draw_ms
    overhead_pass_ms, overhead_draw_ms = 0.0, 0.0
  end
end

local updating_this = nil
local hover_this = nil
do
  -- Kept (project-owned) pieces of the setupMapIcon, update and
  -- setupIconName hooks.
  local function note_setup() setup_icon_n = setup_icon_n + 1 end
  -- Feedback guard: our updateMapIcon call after an add re-triggers the native
  -- setupMapIcon, which re-fires this hook — at 62 markers that loop ran ~50
  -- rebuilds/s and crashed the game's icon code. Every native setup wipes our
  -- icons, so the re-add must ALWAYS run (skipping it leaves the map bare —
  -- that was the zoom-disappearance bug). The loop driver is the update call,
  -- so only that is gated: it fires once per snapshot change, and the refire
  -- it causes re-adds with an unchanged sig and goes quiet.
  local function note_sig()
    local sig = snapshot ~= nil and snapshot.sig or ""
    local sig_changed = sig ~= last_add_sig
    last_add_sig = sig
    return sig_changed
  end
  local function refire_due(sig_changed)
    return sig_changed and added_count > 0
  end
  local function hover_selected(this)
    hover_stats.fires = hover_stats.fires + 1
    local sel = this.SelectedIcon
    if sel == nil then hover_stats.sel_nil = hover_stats.sel_nil + 1 end
    return sel
  end
  local function hover_hit() hover_stats.hits = hover_stats.hits + 1 end
  local function hover_miss(sel, addr)
    hover_stats.misses = hover_stats.misses + 1
    if settings.debug and hover_last_miss ~= addr then
      hover_last_miss = addr
      local n = 0
      for _ in pairs(hover_labels) do n = n + 1 end
      logmsg(string.format(
        "hover miss: sel=0x%x type=%s ours=%d",
        addr, tostring(sel:get_type_definition():get_full_name()), n))
    end
  end

  -- SPEC 5.13.4.3 to 5.13.4.6
  local function same(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local ok, eq = pcall(function() return a:get_address() == b:get_address() end)
    -- debug-only: calls where == was false but the addresses matched
    if ok and eq and settings.debug then
      hover_stats.same_fallback_n = hover_stats.same_fallback_n + 1
    end
    return ok and eq
  end
  A.hook_method("app.ui040205", "setupMapIcon", function(args)
    hooked_this = sdk.to_managed_object(args[2])
    note_setup()
    ui_map = hooked_this
    restore_styles()
  end, function(retval)
    local this = hooked_this
    if this ~= nil and same(this, ui_map) then
      local sig_changed = note_sig()
      local ok, err = pcall(add_markers, this)
      if not ok then logerr("add_markers error: " .. tostring(err)) end
      if refire_due(sig_changed) then
        pcall(function() this:call("updateMapIcon") end)
      end
      pcall(apply_styles, this)
    end
    return retval
  end)
  A.hook_method("app.ui040205", "updateMapIcon", function(args)
    updating_this = sdk.to_managed_object(args[2])
  end, function(retval)
    if same(updating_this, ui_map) and #saved_styles > 0 then
      pcall(apply_styles, updating_this)
    end
    return retval
  end)
  A.hook_method("app.ui040205", "update", function(args)
    icons.map_seen = os.clock()   -- SPEC 21.4.4, Ruling 6
    if want_update and ui_map ~= nil then
      want_update = false
      -- deliberate rebuilds get exactly one updateMapIcon; the refire stops on the unchanged sig
      last_add_sig = nil
      local this = sdk.to_managed_object(args[2])
      if same(this, ui_map) then
        pcall(function() this:call("setMapScale", this.NowScale, true) end)
      end
    end
  end)
  A.hook_method("app.ui040205", "setupIconName", function(args)
    hover_this = sdk.to_managed_object(args[2])
  end, function(retval)
    local this = hover_this
    if this ~= nil then
      pcall(function()
        local sel = hover_selected(this)
        if sel == nil then return end
        local addr = sel:get_address()
        local label = hover_labels[addr]
        if label ~= nil then
          hover_hit()
          if this.TxtName ~= nil then this.TxtName:set_Message(label) end
        else
          hover_miss(sel, addr)
        end
      end)
    end
    return retval
  end)
end

if re.on_script_reset then
  re.on_script_reset(function()
    pcall(wt.save, wt, "reset")
    if minimap_renderer ~= nil then
      pcall(minimap_renderer.clear, minimap_renderer)
    end
    pcall(restore_styles)
  end)
end

-- v9 (SPEC 16.10): debug-only entry point; nil whenever debug is off.
local function install_debug()
  if settings.debug then
    _G.QNML_DEBUG = {
      jump = function(x, y, z) jump_pending = { x = x, y = y, z = z } end,
      expand = function(qid) debug_expanded[qid] = true; last_tick = 0.0 end,
      -- same effect as ticking the matching checkbox (keys: enabled,
      -- journal_spoilers, debug), so the in-game checks need no clicks
      set = function(key, v)
        if key == "enabled" then
          settings.enabled = v; want_update = true; last_tick = 0.0; save_settings()
          minimap_renderer:clear_suspension()
        elseif key == "journal_spoilers" then
          settings.journal_spoilers = v; last_tick = 0.0; save_settings()
        elseif key == "debug" then
          settings.debug = v; A.set_debug(v); save_settings(); install_debug()
        elseif key == "search_text" then
          -- the typing path: no last_tick reset, the 2 s save throttle applies
          settings.search_text = su.cut_search(v)
          settings_dirty = true; want_update = true
        elseif key == "matching_icons" then
          settings.matching_icons = v == true
          want_update = true; save_settings(); icons:preload_all()
        elseif key == "step_icons" then
          settings.step_icons = v == true
          want_update = true; last_tick = 0.0; save_settings(); icons:preload_all()
        elseif key == "overhead_names" then
          if type(v) == "number" then
            settings.overhead_names = su.clamp_int(v, 0, 2); save_settings()
          end
        elseif key == "inventory_quest_marks" then
          settings.inventory_quest_marks = v == true
          last_tick = 0.0; save_settings()
        elseif key == "world_max_markers" then
          if type(v) == "number" then
            settings.world_max_markers = su.clamp_int(v, 0, su.WORLD_MAX_MARKERS)
            want_update = true; last_tick = 0.0; save_settings()
          end
        else
          local hit = false
          for _, k in ipairs(su.WORLD_BOOLS) do
            if key == k then
              settings[k] = v == true
              want_update = true; last_tick = 0.0; save_settings()
              hit = true
              break
            end
          end
          if not hit then
            for _, k in ipairs(su.WORLD_KIND_BOOLS) do
              if key == k then
                settings[k] = v == true
                want_update = true; last_tick = 0.0; save_settings()
                hit = true
                break
              end
            end
          end
          -- v14 (SPEC 23.4.8): every style and route key, validated
          -- v14: every remaining key (style, outline, route, names, colors,
          -- icons, coordinates), validated; a non-string key is ignored
          if not hit and type(key) == "string" and su.set_key(settings, key, v) then
            want_update = true; last_tick = 0.0; save_settings()
          end
        end
      end,
      -- v14 (SPEC 22.11.4): every side quest's step text, qids as string keys
      dump_steps = function()
        local out = {}
        for qid, steps in pairs(adapter.quest_steps_text()) do out[tostring(qid)] = steps end
        json.dump_file("Clairvoyance_steps.json", out)
        logmsg("dump_steps: wrote Clairvoyance_steps.json")
      end,
      -- v14: the panel's Route toggle for one NPC search row (cid nil clears)
      route = function(cid, name)
        if cid == nil then wt.route_cid = nil; wt.q("clear_route", nil); return end
        wt.route_cid = cid
        wt.q("set_route", nil, cid, name)
      end,
      -- v14 (SPEC 22.11.5): append the player's map-space position as a pin
      pin = function(qid, idx, label)
        local ok_t, tr = pcall(wt.player_tr)
        local u = ok_t and tr ~= nil and tr:call("get_UniversalPosition") or nil
        if u == nil then logmsg("pin: no player position"); return nil end
        local list = json.load_file("Clairvoyance_pins.json")
        if type(list) ~= "table" then list = {} end
        list[#list + 1] = { qid = qid, idx = idx, label = label,
          x = u.x, y = u.y, z = u.z }
        json.dump_file("Clairvoyance_pins.json", list)
        logmsg(string.format("pin: %s step %s %s (%d pins)",
          tostring(qid), tostring(idx), tostring(label), #list))
        return #list
      end,
      -- same effect as ticking one kind checkbox (SPEC 29.6.4); false and no
      -- change for a bad class, a bad kind, or a class already at the cap
      monster_kind = function(kind, class, off)
        if not su.set_kind_off(settings, class, kind, off) then return false end
        save_settings(); want_update = true; last_tick = 0.0
        return true
      end,
      -- same effect as ticking one family checkbox (SPEC 30.6.7); false and no
      -- change unless class is "large" or "small" and fam is a 5-byte string
      monster_family = function(fam, class, off)
        if type(fam) ~= "string" then return false end
        if not su.set_kind_off(settings, class, su.fam_key(fam), off) then return false end
        save_settings(); want_update = true; last_tick = 0.0
        return true
      end,
      -- SPEC 32.9: the focus set's per-quest list sizes, NPC positions and markers
      focus = function()
        local fs = snapshot ~= nil and snapshot.focus or nil
        local out = { active = {}, quests = {}, counts = snapshot ~= nil and snapshot.focus_counts or nil,
          walks = wt.obj_walks or 0, focus_pokes = wt.focus_pokes or 0, routes = {},
          routes_total = wt.routes_total }
        for _, r in ipairs((wt.q("input", nil) or {}).routes or {}) do
          out.routes[#out.routes + 1] = { cid = r.cid, name = r.name, stops = #(r.stops or {}) }
        end
        local nq = 0
        for _ in pairs(wt.quest_rel or {}) do nq = nq + 1 end
        out.file = { quests = nq, pak = wt.quest_pak }
        if fs == nil then return out end
        local marked_ids = {}
        local function note(m)
          local k = type(m) == "table" and m.key or nil
          local id = type(k) == "string" and k:match("^[cn]:(%-?%d+)$") or nil
          if id ~= nil then marked_ids[tonumber(id)] = true end
          if type(m) == "table" and m.cid ~= nil
            and (m.cat == "npc_search" or m.cat == "shop" or m.cat == "seller") then
            marked_ids[m.cid] = true
          end
        end
        for _, m in ipairs(snapshot.markers or {}) do note(m) end
        for _, m in ipairs(snapshot.fullmap_world or {}) do note(m) end
        for i, qid in ipairs(fs.active or {}) do
          out.active[i] = qid
          local q = (fs.quests or {})[qid] or {}
          local e = { npcs = #(q.npcs or {}), step_npcs = #(q.step_npcs or {}),
            items = #(q.items or {}), places = #(q.places or {}),
            no_pos = {}, positioned = 0, marked = 0 }
          for _, cid in ipairs(q.npcs or {}) do
            local okp, pos = pcall(adapter.npc_pos, cid)
            if not okp or pos == nil then
              e.no_pos[#e.no_pos + 1] = cid
            else
              local oka, alive = pcall(adapter.npc_alive, cid)
              if not (oka and alive == false) then
                e.positioned = e.positioned + 1
                if marked_ids[cid] then e.marked = e.marked + 1 end
              end
            end
          end
          out.quests[qid] = e
        end
        return out
      end,
      -- stats plus at most 20 rows (counts and labels); positions go to the log only
      world = function()
        local st = wt.q("stats", {})
        local rows = {}
        local sn = snapshot ~= nil and snapshot.world or nil
        local max_rows = world ~= nil and world.K.DEBUG_ROWS or 0
        if sn ~= nil then
          for _, cat in ipairs(core.WORLD_CATS) do
            if cat ~= "npc_search" and sn[cat] ~= nil and #rows < max_rows
              and (cat ~= "shop" or wt.search_on or settings.world_shops) then
              for _, r in ipairs(wt.rows(cat)) do
                if #rows >= max_rows then break end
                if not r.first then
                  rows[#rows + 1] = { cat = cat, text = r.text }
                  logmsg(string.format("World row: %s %s at %.1f, %.1f, %.1f",
                    cat, r.text, r.pos.x, r.pos.y, r.pos.z))
                end
              end
            end
          end
        end
        st.rows = rows
        st.monster_kinds = sn ~= nil and type(sn.monster) == "table" and sn.monster.kinds or nil
        st.monster_families = sn ~= nil and type(sn.monster) == "table" and sn.monster.families or nil
        st.kinds_seen = wt.kinds_seen
        local wmo = settings.world_monster_off
        st.monster_tree = {
          large = su.monster_tree(wt.kinds_seen.large, wt.fam_names.large, wmo.large,
            settings.world_monsters == true),
          small = su.monster_tree(wt.kinds_seen.small, wt.fam_names.small, wmo.small,
            settings.world_small_monsters == true) }
        st.first_token = sn ~= nil and sn.token ~= nil and sn.token.first or nil
        st.cursor = ui_map ~= nil and adapter.map_cursor ~= nil
          and adapter.map_cursor(ui_map) or nil
        st.map_origin, st.map_retakes = wt.map_origin, wt.map_retakes
        st.rebuild_ms, st.rebuild_max = wt.rebuild_ms, wt.rebuild_max
        -- SPEC 20.5.6: shop counts and cids that own two or more shop entries
        local sp = sn ~= nil and sn.shop or nil
        local per, two = {}, 0
        for _, e in ipairs((wt.q("input", nil) or {}).shops or {}) do
          if e.cid ~= nil then
            per[e.cid] = (per[e.cid] or 0) + 1
            if per[e.cid] == 2 then two = two + 1 end
          end
        end
        st.shop = { shown = sp ~= nil and sp.shown or 0,
          known = sp ~= nil and sp.known or 0, two_shop_npcs = two }
        -- v14: NPC search rows and the shown route (names and counts only)
        local nr = {}
        for i, r in ipairs(snapshot ~= nil and snapshot.npc_rows or {}) do
          nr[i] = string.format("%s pos=%s alive=%s marker=%s", tostring(r.name),
            tostring(r.pos ~= nil), tostring(r.alive), tostring(r.marker_key))
        end
        st.npc_rows = nr
        st.npc_names = #((wt.q("input", nil) or {}).npcs or {})
        st.route = (wt.q("input", nil) or {}).route
        return st
      end,
      state = function()
        local jumps = {}
        for i, r in ipairs(jump_log) do jumps[i] = jump_line(r) end
        return { lines = snapshot ~= nil and core.state_lines(snapshot,
            expanded_union(), settings.journal_spoilers) or {}, jumps = jumps,
          tracked_qid = snapshot and snapshot.tracked_qid or nil,
          map_ctor_n = map_ctor_n, setup_icon_n = setup_icon_n,
          same_fallback_n = hover_stats.same_fallback_n,
          tick_median = su.median(wt.tick_ring or {}),
          draw = icons:stats_line(),
          item_menu = icons.itemmenu ~= nil and icons.itemmenu:stats_line() or nil,
          names = string.format("Names: spawned %d, drawn %d, skipped %d",
            wt.names_stats.spawned, wt.names_stats.drawn, wt.names_stats.skipped) }
      end,
    }
  else
    _G.QNML_DEBUG = nil
    debug_expanded = {}
  end
end
install_debug()

-- v9 (SPEC 16.3d): one expanded row (or summary node) from core's model.
local JUMP_TIP = "Opens the map here"
-- Opens the node itself; returns whether it was open. The detail model is
-- built once per snapshot (its inputs only change when the snapshot does).
local function draw_detail(label, rec, qid, j, ja, spoilers)
  if not imgui.tree_node(label) then return false end
  local ok, err = pcall(function()
    local cache = snapshot.detail
    if cache == nil then cache = {}; snapshot.detail = cache end
    local key = tostring(qid) .. (spoilers and "s" or "")
    local d = cache[key]
    if d == nil then
      d = core.row_detail(rec, j[qid], ja[qid], spoilers)
      d.steps_id, d.jump_id = "All steps###qa_" .. qid, "Show on map##qj_" .. qid
      cache[key] = d
    end
    for _, l in ipairs(d.lines) do imgui.text(l) end
    if d.steps ~= nil and imgui.tree_node(d.steps_id) then
      for _, s in ipairs(d.steps) do imgui.text(s) end
      imgui.tree_pop()
    end
    if d.jump ~= nil then
      if imgui.button(d.jump_id) then jump_pending = d.jump end
      if imgui.is_item_hovered() then imgui.set_tooltip(JUMP_TIP) end
    end
    -- v14 (SPEC 22.11.2): the Hints node. Opening it is the spoiler gate;
    -- the step in its id starts a new step's node closed.
    local hq = wt.hints[qid]
    if hq ~= nil and require("Clairvoyance.npcs").has_text(hq)
        and rec ~= nil and rec.cat ~= "locked" and adapter.is_side(qid) then
      local jr = j[qid]
      local idx = rec.cat == "in_progress" and jr ~= nil
        and type(jr.step_index) == "number" and jr.step_index or nil
      if imgui.tree_node("Hints###qh_" .. qid .. "_" .. (idx ~= nil and idx or "q")) then
        local tw = imgui.text_wrapped or imgui.text
        if hq.quest ~= nil then tw(hq.quest) end
        if idx ~= nil then
          if wt.hints_open[qid] ~= idx then
            wt.hints_open[qid] = idx
            last_tick = 0.0   -- the pins show within a frame or two
          end
          local st = require("Clairvoyance.npcs").hint_step(wt.hints, qid, idx + 1)
          if st ~= nil then tw(st.text) end
        end
        imgui.tree_pop()
      end
    end
  end)
  if not ok then logerr("tree detail: " .. tostring(err)) end
  imgui.tree_pop()
  return true
end

-- The settings panel (SPEC 23.7). Section functions are keyed by the ids in
-- su.PANEL_ORDER; draw_body walks that list. One do-block, so the helpers and
-- the section table add no chunk-level local.
local draw_body
do
  local sec = {}
  local groups = wt.style.GROUPS
  local route_labels = { "Straight lines", "Walking path" }
  local cat_rows = {
    { "startable", "Startable" }, { "in_progress", "In progress" },
    { "completed", "Completed" }, { "unavailable", "Unavailable" },
    { "locked", "Locked" }, { "quest_item", "Quest items" },
    { "chest", su.WORLD_LABEL.chest }, { "treasure", su.WORLD_LABEL.treasure },
    { "token", su.WORLD_LABEL.token }, { "beetle", su.WORLD_LABEL.beetle },
    { "monster", su.WORLD_LABEL.monster }, { "seller", su.WORLD_LABEL.seller },
    { "npc_search", su.WORLD_LABEL.npc_search },
    { "route_stop", su.WORLD_LABEL.route_stop },
    { "hint_pin", su.WORLD_LABEL.hint_pin },
  }
  -- the override sub-tree names: the category's name, then the three extras
  local gname = { route_line = "Route line", names = "Names", items = "Item menu" }
  for _, r in ipairs(cat_rows) do gname[r[1]] = r[2] end

  -- Appearance controls: validate through su.set_key, then save. A checkbox
  -- saves at once (the number size alone defers to the slider release).
  local function ck(label, key)
    local c, v = imgui.checkbox(label .. "##" .. key, settings[key])
    if c and su.set_key(settings, key, v) then want_update = true; save_settings() end
  end
  local function cc(label, key)
    local c, v = imgui.color_picker_argb(label .. "##" .. key, settings[key])
    if c and su.set_key(settings, key, v) then want_update = true; save_settings() end
  end
  local function cs(label, key, lo, hi)
    local c, v = imgui.slider_int(label .. "##" .. key, settings[key], lo, hi)
    if c and su.set_key(settings, key, v) then want_update = true; save_settings() end
  end
  -- Number size (SPEC 23.4.3): the slider edits a draft on icons; the setting
  -- is written on the frame the slider stops being active (1-11 snap to 12).
  local function number_size()
    local shown = icons.draft_active and icons.draft_number_size
      or settings.route_number_size
    local c, v = imgui.slider_int("Number size##route_number_size", shown, 0, 40)
    -- read before any other item: is_item_active reads the last item drawn
    local active = imgui.is_item_active()
    imgui.same_line()
    imgui.text("0 = default font")
    if c then icons.draft_number_size = v; icons.draft_active = true end
    if icons.draft_active and not active then
      icons.draft_active = false
      if su.set_key(settings, "route_number_size", icons.draft_number_size) then
        want_update = true; settings_dirty = true
      end
    end
  end

  sec.enabled = function()
    local changed
    changed, settings.enabled = imgui.checkbox("Enabled", settings.enabled)
    if changed then
      want_update = true; last_tick = 0.0; save_settings()
      minimap_renderer:clear_suspension()
    end
  end

  sec.search = function()
    local changed
    -- SPEC 19.4: map search. Typing never touches last_tick (one tick, one save per 2 s).
    local sch, sval = imgui.input_text("Map search", settings.search_text)
    if sch then
      settings.search_text = su.cut_search(sval)
      settings_dirty = true; want_update = true
    end
    imgui.same_line()
    if imgui.button("Clear") then
      settings.search_text = ""
      settings_dirty = true; want_update = true; last_tick = 0.0
    end
    if wt.search_on then
      local off = su.not_searched(settings)
      if #off > 0 then imgui.text("Not searched (off): " .. table.concat(off, ", ")) end
      if snapshot == nil then
        imgui.text("No results yet")
      else
        -- N counts the markers except route stops and hint pins (SPEC 19.4.4)
        local srows = snapshot.search_rows
        if srows == nil then
          srows = core.world_rows(snapshot.markers,
            (wt.q("input", nil) or {}).settlements, wt.world_origin)
          for _, r in ipairs(srows) do
            r.jump_id = "Show on map##sj_" .. tostring(r.key)
          end
          snapshot.search_rows = srows
          local nres = 0
          for _, m in ipairs(snapshot.markers) do
            if core.is_result ~= nil then
              if core.is_result(m) then nres = nres + 1 end
            elseif m.cat ~= "route_stop" and m.cat ~= "hint_pin" and not m.first_seeker then
              nres = nres + 1
            end
          end
          snapshot.search_n = nres
        end
        if imgui.tree_node(string.format("Search results (%d)###qnml_sr", snapshot.search_n)) then
          -- map space, the same space as every marker position
          local pp = player_origin
          for _, r in ipairs(srows) do
            if r.pos ~= nil and pp ~= nil then
              imgui.text(string.format("%s - X %.0f  Z %.0f - %.0f m", r.text,
                r.pos.x, r.pos.z, math.sqrt((r.pos.x - pp.x) ^ 2 + (r.pos.z - pp.z) ^ 2)))
            else
              imgui.text(r.text)
            end
            if imgui.button(r.jump_id) then jump_pending = r.pos end
            if imgui.is_item_hovered() then imgui.set_tooltip(JUMP_TIP) end
          end
          -- v14 (SPEC 22.7.6): the name matches, a route toggle each
          local nrows = snapshot.npc_rows or {}
          if #nrows > 0 and imgui.tree_node(
              string.format("NPCs (%d)###qnml_nr", #nrows)) then
            local rt = (wt.q("input", nil) or {}).route
            for _, r in ipairs(nrows) do
              if r.text == nil then
                local tx = tostring(r.name)
                if not r.alive then
                  tx = tx .. " - dead"
                elseif r.pos ~= nil then
                  local best = core.nearest_settlement(r.pos,
                    (wt.q("input", nil) or {}).settlements)
                  if best ~= nil then tx = tx .. " - near " .. tostring(best.name) end
                else
                  tx = tx .. " - position unknown"
                end
                r.text = tx
                r.jump_id = "Show on map##nj_" .. tostring(r.cid)
                r.route_id = "Route##nr_" .. tostring(r.cid)
              end
              imgui.text(r.text)
              if r.pos ~= nil then
                if imgui.button(r.jump_id) then jump_pending = r.pos end
                if imgui.is_item_hovered() then imgui.set_tooltip(JUMP_TIP) end
                imgui.same_line()
              end
              local rc, rv = imgui.checkbox(r.route_id, wt.route_cid == r.cid)
              if rc then
                if rv then
                  wt.route_cid = r.cid
                  wt.q("set_route", nil, r.cid, r.name)
                else
                  wt.route_cid = nil
                  wt.q("clear_route", nil)
                end
                want_update = true; last_tick = 0.0
              end
              if wt.route_cid == r.cid and rt ~= nil and rt.cid == r.cid then
                if rt.err ~= nil then
                  imgui.text("route unavailable")
                elseif (rt.unplaced or 0) > 0 then
                  imgui.text(string.format("%d stops unplaced", rt.unplaced))
                end
                if rt.err == nil and rt.off_schedule then
                  imgui.text("not at a scheduled place right now")
                end
                local ps = wt.q("path_status", nil, settings.route_path)
                if ps ~= nil then imgui.text(ps) end
              end
            end
            imgui.tree_pop()
          end
          imgui.tree_pop()
        end
      end
    end
  end

  sec.quests = function()
    local changed
    if not imgui.tree_node("Quests") then return end
    local toggles = {
      { "show_startable", "Startable" },
      { "show_in_progress", "In progress" },
      { "show_quest_items", "Quest items (for in-progress quests)" },
      { "show_completed", "Completed" },
      { "show_unavailable", "Unavailable (failed/canceled/giver dead)" },
      { "show_locked", "Locked (not yet reachable - spoilers)" },
    }
    for _, t in ipairs(toggles) do
      changed, settings[t[1]] = imgui.checkbox(t[2], settings[t[1]])
      -- last_tick = 0 forces the next frame's tick to recompute, so a
      -- toggle takes effect immediately instead of after the 2 s interval.
      if changed then want_update = true; last_tick = 0.0; save_settings() end
    end
    changed, settings.reveal_gate_names =
      imgui.checkbox("Reveal gating quest names", settings.reveal_gate_names)
    if changed then want_update = true; last_tick = 0.0; save_settings() end
    -- v9 (SPEC 16.4): text only, so no map icon rebuild (no want_update)
    changed, settings.journal_spoilers = imgui.checkbox(
      "Show every journal step (spoilers)", settings.journal_spoilers)
    if changed then last_tick = 0.0; save_settings() end
    -- v13 (SPEC 21.4): moved here from Icons and colors
    changed, settings.step_icons =
      imgui.checkbox("Numbered icons for in-progress quests", settings.step_icons)
    if changed then
      want_update = true; last_tick = 0.0; save_settings(); icons:preload_all()
    end
    imgui.tree_pop()
  end

  -- A world checkbox: toggling it refreshes the markers and saves.
  wt.wbox = function(key)
    local changed
    changed, settings[key] = imgui.checkbox(su.WORLD_BOOL_LABEL[key], settings[key])
    if changed then want_update = true; last_tick = 0.0; save_settings() end
  end

  -- SPEC 29.2, 30.3.1: one monster class node: its class checkbox, then the
  -- draw list su.monster_tree returns (family nodes with their kinds, plain
  -- kind checkboxes, off families not seen yet).
  wt.kind_tree = function(title, class, key)
    if not imgui.tree_node(title) then return end
    wt.wbox(key)
    local class_on = settings[key] == true
    local offs = settings.world_monster_off[class]
    local tree = su.monster_tree(wt.kinds_seen[class], wt.fam_names[class], offs, class_on)
    if #tree == 0 then imgui.text(su.kind_empty_text(class_on)) end
    -- one checkbox for the entry `name` (a kind, or "fam:" .. fam); ticked = shown
    local function box(label, st, name)
      local is_off = offs[name] == true
      imgui.begin_disabled(st == "disabled")
      local changed, v = imgui.checkbox(label, not is_off)
      imgui.end_disabled()
      if changed and st ~= "disabled" then
        su.set_kind_off(settings, class, name, not v)
        save_settings(); want_update = true; last_tick = 0.0
      end
    end
    for _, e in ipairs(tree) do
      if e.unseen then
        box("Family " .. e.fam .. " (none seen yet)##wfu_" .. class .. "_" .. e.fam,
          e.family_box, su.fam_key(e.fam))
      elseif e.node then
        if imgui.tree_node(e.name .. "###wf_" .. class .. "_" .. e.fam) then
          box("All " .. e.name .. "###wfa_" .. class .. "_" .. e.fam,
            e.family_box, su.fam_key(e.fam))
          for _, k in ipairs(e.kinds) do
            box(k.kind .. "##wk_" .. class .. "_" .. e.fam .. "_" .. k.kind, k.box, k.kind)
          end
          imgui.tree_pop()
        end
      else
        local idp = e.plain and ("##wku_" .. class .. "_") or ("##wk_" .. class .. "_" .. e.fam .. "_")
        for _, k in ipairs(e.kinds) do
          box(k.kind .. idp .. k.kind, k.box, k.kind)
        end
      end
    end
    imgui.tree_pop()
  end

  sec.world_markers = function()
    if imgui.tree_node("World markers##wcfg") then
      -- SPEC 28.9.4, 28.12.1: Tokens and Monsters each pair two keys in one
      -- tree node, drawn where the first of the pair sits (Monsters as class
      -- nodes with kind checkboxes, 29.2)
      for _, k in ipairs(su.WORLD_BOOLS) do
        local tr = su.WORLD_TREES[k]
        -- the second box of a tree is drawn with its first
        local open = not su.WORLD_TREE_SECOND[k] and (tr == nil or imgui.tree_node(tr[1]))
        if open and k == "world_monsters" then
          -- SPEC 29.2: Monsters is a tree of Large and Small, each down to its kinds
          wt.kind_tree("Large monsters##wmonL", "large", "world_monsters")
          wt.kind_tree("Small monsters##wmonS", "small", "world_small_monsters")
          imgui.tree_pop()
        elseif open then
          wt.wbox(k)
          if tr ~= nil then
            wt.wbox(tr[2])
            imgui.tree_pop()
          end
        end
        if open and k == "world_chests" then   -- the kind filters sit indented under Chests
          imgui.indent(20)
          for _, kk in ipairs(su.WORLD_KIND_BOOLS) do wt.wbox(kk) end
          imgui.unindent(20)
        end
      end
      local wc, wv = imgui.slider_int("Max world markers",
        settings.world_max_markers, 0, su.WORLD_MAX_MARKERS)
      if wc then
        settings.world_max_markers = su.clamp_int(wv, 0, su.WORLD_MAX_MARKERS)
        settings_dirty = true; want_update = true
      end
      imgui.tree_pop()
    end
  end

  sec.npcs = function()
    local changed
    if not imgui.tree_node("NPCs") then return end
    changed, settings.show_overhead =
      imgui.checkbox("Overhead NPC indicators", settings.show_overhead)
    if changed then save_settings() end
    local sc, sv = imgui.slider_float("Overhead distance",
      settings.overhead_distance, 10, 200)
    if sc then
      settings.overhead_distance = math.min(200, math.max(10, sv))
      settings_dirty = true
    end
    -- v14 (SPEC 22.9.1): independent of the overhead indicators above
    local nc, ni = imgui.combo("NPC names above heads",
      settings.overhead_names + 1, wt.names_labels)
    if nc and wt.names_labels[ni] ~= nil then
      settings.overhead_names = ni - 1
      save_settings()
    end
    -- v14 (SPEC 23.6): how a route is drawn
    local rc, ri = imgui.combo("Route path", settings.route_path + 1, route_labels)
    if rc and su.set_key(settings, "route_path", ri - 1) then
      want_update = true; last_tick = 0.0; save_settings()
    end
    local straight = settings.route_path == 0
    imgui.begin_disabled(straight)
    local wc, wv = imgui.checkbox("Show route path in the world",
      settings.route_world_path)
    imgui.end_disabled()
    if wc and su.set_key(settings, "route_world_path", wv) then
      want_update = true; save_settings()
    end
    if straight then imgui.same_line(); imgui.text("needs Walking path") end
    imgui.tree_pop()
  end

  sec.items = function()
    local changed
    if not imgui.tree_node("Items") then return end
    -- v14 (SPEC 22.10.5)
    changed, settings.inventory_quest_marks = imgui.checkbox(
      "Mark quest items in the item menu", settings.inventory_quest_marks)
    if changed then last_tick = 0.0; save_settings() end
    imgui.tree_pop()
  end

  sec.map = function()
    local changed
    if not imgui.tree_node("Map and minimap") then return end
    changed, settings.show_minimap =
      imgui.checkbox("Minimap indicators", settings.show_minimap)
    if changed then
      save_settings()
      minimap_renderer:clear_suspension()
    end
    if not icons:available() then
      imgui.text("Matching icons need the D2DX plugin (Dragon's Dogma 2 mod 1261)."
        .. " Route lines need it too.")
    end
    changed, settings.matching_icons =
      imgui.checkbox("Matching icons (D2DX)", settings.matching_icons)
    if changed then
      want_update = true; save_settings(); icons:preload_all()
    end
    changed, settings.coords_map_cursor = imgui.checkbox(
      "Coordinates beside the map cursor", settings.coords_map_cursor)
    if changed then save_settings() end
    changed, settings.coords_minimap = imgui.checkbox(
      "Coordinates under the minimap", settings.coords_minimap)
    if changed then save_settings() end
    imgui.tree_pop()
  end

  sec.appearance = function()
    if not imgui.tree_node("Appearance") then return end
    if imgui.tree_node("Outlines##ap_out") then
      ck("Outlines", "outline_on")
      cc("Outline color", "outline_color")
      cs("Outline width", "outline_width", 1, 4)
      imgui.tree_pop()
    end
    if imgui.tree_node("Route##ap_route") then
      cc("Line color", "route_line_color")
      cs("Line width", "route_line_width", 1, 8)
      cs("Stop size (%)", "route_stop_size", 50, 200)
      cc("Number color", "route_number_color")
      number_size()
      imgui.tree_pop()
    end
    cc("Names color", "names_color")
    if imgui.tree_node("Overrides##ap_ov") then
      for _, g in ipairs(groups) do
        if imgui.tree_node(gname[g] .. "##ov_" .. g) then
          local p = "style_" .. g .. "_"
          ck("Override", p .. "override")
          if settings[p .. "override"] then
            ck("Outline", p .. "outline_on")
            cc("Outline color", p .. "outline_color")
            cs("Outline width", p .. "outline_width", 1, 4)
          end
          imgui.tree_pop()
        end
      end
      imgui.tree_pop()
    end
    if imgui.tree_node("Icons and colors") then
      -- One icon per category, the same on every surface (choices are every
      -- picture in the icon folder except the reserved type numbers and
      -- None, SPEC 21.7.3). Uses color_picker_argb:
      -- plain color_picker takes/returns ABGR.
      for _, r in ipairs(cat_rows) do
        if imgui.tree_node(r[2] .. "##ic_" .. r[1]) then
          local ik, ck_ = su.ICON_KEY[r[1]], su.COLOR_KEY[r[1]]
          local ic, ni = imgui.combo("Icon##" .. r[1],
            su.ICON_INDEX[settings[ik]] or 1, su.ICON_LABELS)
          if ic and su.ICON_CHOICES[ni] then
            settings[ik] = su.ICON_CHOICES[ni][1]; want_update = true; save_settings()
            icons:preload_all()
          end
          local pc, nv = imgui.color_picker_argb("Color##" .. r[1], settings[ck_])
          if pc then settings[ck_] = nv; want_update = true; save_settings() end
          imgui.tree_pop()
        end
      end
      imgui.tree_pop()
    end
    if imgui.button("Reset appearance to defaults") then
      su.reset_appearance(settings)
      save_settings(); icons:preload_all(); want_update = true
    end
    imgui.tree_pop()
  end

  sec.quest_tree = function()
    if snapshot ~= nil and A.QUEST_REGION ~= nil then
      local exp = {}   -- v9 (SPEC 16.3c): rows open this frame
      if imgui.tree_node("Quest tree") then
        tree_open_at = os.clock()
        if snapshot.quests == nil then
          imgui.text("Building (next refresh)...")
        else
          local spoilers = settings.journal_spoilers
          local jt, jat = snapshot.journal or {}, snapshot.journal_all or {}
          snapshot.summary = snapshot.summary or core.summary_nodes(snapshot)
          for _, s in ipairs(snapshot.summary) do
            draw_detail(s.label, s.rec, s.qid, jt, jat, spoilers)
          end
          local order = { "Melve", "Vernworth", "Checkpoint Rest Town",
            "Harve", "Bakbattahl", "Sacred Arbor", "Volcanic Island",
            "Unmoored", "Elsewhere" }
          local by = {}
          for _, r in ipairs(snapshot.quests) do
            if r.cat ~= "locked" or settings.show_locked then
              local t = by[r.region]
              if t == nil then t = {} by[r.region] = t end
              t[#t + 1] = r
            end
          end
          for _, reg in ipairs(order) do
            local list = by[reg]
            if list ~= nil and #list > 0 then
              local done = 0
              for _, r in ipairs(list) do
                if r.cat == "completed" or r.cat == "failed"
                  or r.cat == "canceled" then done = done + 1 end
              end
              if imgui.tree_node(string.format("%s (%d/%d)###qt_%s",
                  reg, done, #list, reg)) then
                for _, r in ipairs(list) do
                  imgui.text_colored("*", A.argb_to_abgr(
                    su.color_of(settings, r.grp)))
                  imgui.same_line()
                  r.row_label = r.row_label or core.row_label(r, snapshot.nearest_qid)
                  if draw_detail(r.row_label, r, r.qid, jt, jat, spoilers) then
                    exp[r.qid] = true
                  end
                end
                imgui.tree_pop()
              end
            end
          end
          local ts = adapter.tree_gate_stats ~= nil
            and adapter.tree_gate_stats() or nil
          if ts ~= nil then
            imgui.text(tree_gates_line(ts))
          end
        end
        imgui.tree_pop()
      end
      for q in pairs(exp) do
        if not tree_expanded[q] then last_tick = 0.0; break end   -- detail within a frame or two
      end
      tree_expanded = exp
    end
  end

  sec.world = function()
    if snapshot ~= nil and A.QUEST_REGION ~= nil then
      if imgui.tree_node("World") then
        local okp, errp = pcall(function()
          -- read every frame: shown even before the first committed round
          local ps = wt.q("places_state", wt.ps_dflt)
          if ps.state ~= "ok" then
            imgui.text("World data file missing: reinstall the mod")
          end
          if ps.stale then imgui.text("World data may be out of date") end
          local sw = snapshot.world
          if sw == nil then
            imgui.text("No world data yet")
            return
          end
          -- one category's row list: text (or a shop's stock node) and its jump button
          local function draw_rows(cat, rows)
            for _, r in ipairs(rows) do
              local open = true
              if cat == "shop" then
                open = imgui.tree_node(r.tree_id)
                if open then
                  for _, l in ipairs(r.sells_for or {}) do imgui.text(l) end
                  if r.stock == nil or #r.stock == 0 then
                    imgui.text("No stock listed")
                  else
                    for _, it in ipairs(r.stock) do
                      imgui.text(tostring(it.name) .. (it.locked and " (may be locked)" or ""))
                    end
                  end
                end
              else
                imgui.text(r.text)
              end
              if open then
                if imgui.button(r.jump_id) then
                  jump_pending = r.pos
                end
                if imgui.is_item_hovered() then imgui.set_tooltip(JUMP_TIP) end
                if cat == "shop" then imgui.tree_pop() end
              end
            end
          end
          for _, cat in ipairs(core.WORLD_CATS) do
            local p = cat ~= "npc_search" and sw[cat] or nil   -- NPCs live in the search panel
            local title = su.WORLD_LABEL[cat] or cat
            if cat == "shop" and not wt.search_on then title = su.WORLD_LABEL.shops end
            if p ~= nil and (cat ~= "shop" or wt.search_on or settings.world_shops)
              and imgui.tree_node(string.format("%s (%d/%d)###wcat_%s",
                title, p.shown, p.known, cat)) then
              if cat ~= "monster" then
                local rows = wt.rows(cat)
                if #rows == 0 then imgui.text("Nothing shown") end
                draw_rows(cat, rows)
              else
                -- SPEC 29.6.6, 30.3.3: Monsters holds a Large and a Small node,
                -- each holding one node per family with two or more kinds
                -- (that family's kind nodes inside) and the other kinds directly
                if p.shown == 0 then imgui.text("Nothing shown") end
                local ss, sk = p.small_shown or 0, p.small_known or 0
                local sub = { { "large", string.format("Large monsters (%d/%d)###wmonl",
                    p.shown - ss, p.known - sk), p.shown - ss },
                  { "small", string.format("Small monsters (%d/%d)###wmons", ss, sk), ss } }
                -- per snapshot: family node titles, and each family's kind rows in
                -- published order (kept on the snapshot, never in the published rows)
                local flbls, fkinds = snapshot.world_fam_lbls, snapshot.world_fam_kinds
                if flbls == nil then
                  flbls, fkinds = {}, { large = {}, small = {} }
                  for _, k in ipairs(p.kinds or {}) do
                    local f = core.fam_of(k)
                    local byfam = fkinds[k.small == true and "small" or "large"]
                    if byfam[f] == nil then byfam[f] = {} end
                    byfam[f][#byfam[f] + 1] = k
                  end
                  for _, row in ipairs(p.families or {}) do
                    local c = row.small == true and "small" or "large"
                    flbls[row] = string.format("%s (%d/%d)###wfp_%s_%s", tostring(row.name),
                      row.shown or 0, row.known or 0, c, tostring(row.fam))
                  end
                  snapshot.world_fam_lbls, snapshot.world_fam_kinds = flbls, fkinds
                end
                local function draw_kind(g, f, k)
                  -- the label is built once per snapshot, not per frame
                  -- (kept on the snapshot, never written into the published kinds)
                  local lbls = snapshot.world_kind_lbls
                  if lbls == nil then lbls = {}; snapshot.world_kind_lbls = lbls end
                  local lbl = lbls[k]
                  if lbl == nil then
                    lbl = string.format("%s (%d/%d)###wkp_%s_%s_%s",
                      k.kind, k.shown or 0, k.known or 0, g, f, k.kind)
                    lbls[k] = lbl
                  end
                  if imgui.tree_node(lbl) then
                    local rows = wt.rows("monster", g, k.kind, f)
                    if #rows == 0 then imgui.text("Nothing shown") end
                    draw_rows(cat, rows)
                    imgui.tree_pop()
                  end
                end
                for _, g in ipairs(sub) do
                  if imgui.tree_node(g[2]) then
                    for _, row in ipairs(p.families or {}) do
                      if (row.small == true) == (g[1] == "small") then
                        local f = core.fam_of(row)
                        local ks = fkinds[g[1]][f] or {}
                        if (row.n_kinds or #ks) >= 2 then
                          if imgui.tree_node(flbls[row]) then
                            for _, k in ipairs(ks) do draw_kind(g[1], f, k) end
                            imgui.tree_pop()
                          end
                        else
                          for _, k in ipairs(ks) do draw_kind(g[1], f, k) end
                        end
                      end
                    end
                    if g[3] <= 0 then imgui.text("Nothing shown") end
                    imgui.tree_pop()
                  end
                end
              end
              imgui.tree_pop()
            end
          end
        end)
        if not okp then logerr("world panel: " .. tostring(errp)) end
        imgui.tree_pop()
      end
    end
  end

  sec.status = function()
    local changed
    if not imgui.tree_node("Status and debug") then return end
    if snapshot ~= nil then
      local c = snapshot.counts
      imgui.text(string.format(
        "Quests - startable %d  in progress %d  completed %d",
        c.startable, c.in_progress, c.completed))
      imgui.text(string.format(
        "  failed %d  canceled %d  giver dead %d  locked %d",
        c.failed, c.canceled, c.giver_dead, c.locked))
      if imgui.tree_node("Status") then
        if player_origin ~= nil then
          imgui.text(string.format("Player (map): %.0f, %.0f  height %.0f",
            player_origin.x, player_origin.z, player_origin.y))
        end
        imgui.text(string.format("Resolved positions: %d", snapshot.resolved_count))
        imgui.text(string.format("Markers added: %d  dropped (pool full): %d",
          added_count, dropped_count))
        imgui.text(string.format("Pool: %s  used %d / limit %d",
          pool_label, pool_used, pool_limit))
        local lines = {}
        for qid, u in pairs(snapshot.unresolved) do
          lines[#lines + 1] = string.format("[%d] %s: %s",
            qid, u.name or "?", u.reason)
        end
        table.sort(lines)
        if #lines > 0 and imgui.tree_node("Unresolved quests") then
          for _, line in ipairs(lines) do imgui.text(line) end
          imgui.tree_pop()
        end
        local unnamed_ids = {}
        for qid in pairs(snapshot.unnamed) do unnamed_ids[#unnamed_ids + 1] = qid end
        table.sort(unnamed_ids)
        if #unnamed_ids > 0 then
          imgui.text("Unnamed quest IDs: " .. table.concat(unnamed_ids, ", "))
        end
        if adapter.journal_stats ~= nil then
          imgui.text(core.journal_line(adapter.journal_stats()))
        end
        imgui.text(wt.line())
        imgui.tree_pop()
      end
    else
      imgui.text("Waiting for game / save data")
    end
    changed, settings.debug = imgui.checkbox("Debug logging", settings.debug)
    if changed then A.set_debug(settings.debug); install_debug(); save_settings() end

    if imgui.button("Force refresh") then
      committed = {}
      snapshot = nil
      want_update = true
      last_tick = 0.0
    end

    if settings.debug then
      imgui.text("Collection path: " .. A.debug_probe())
      imgui.text(string.format("Hover: fires %d  hits %d  misses %d  sel_nil %d",
        hover_stats.fires, hover_stats.hits, hover_stats.misses,
        hover_stats.sel_nil))
      if imgui.button("Probe NPC scan") then pcall(A.rebuild_npc_pos_cache) end
      local acount = 0
      for _ in pairs(overhead_anchors) do acount = acount + 1 end
      imgui.text(string.format(
        "Overhead: anchors %d, points %d, live hits %d, drawn %d, pass %.2f ms, draw %.2f ms, gate %s, vec reuse %s",
        acount, #overhead_points, overhead_live_hits, overhead_drawn,
        math.max(overhead_pass_ms_shown, overhead_pass_ms),
        math.max(overhead_draw_ms_shown, overhead_draw_ms),
        overhead_gate, tostring(proj_vec_reuse)))
      if minimap_unavailable ~= nil then
        imgui.text("Minimap: " .. minimap_unavailable)
      else
        local mr = minimap_renderer
        imgui.text(string.format(
          "Minimap: candidates %d, clipped %d, shown %d, dropped %d, pool %s, free %s, post %.2f ms, nearest %s, owned %d, hud changes %d, status %s",
          mr.candidates_n, mr.clipped, mr.shown, mr.dropped,
          mr.icons_mode and "-" or tostring(mr.pool_n),
          mr.icons_mode and "-" or tostring(mr.free_n),
          math.max(minimap_post_ms_shown, minimap_post_ms),
          mr.nearest ~= nil and string.format("%.0f m", mr.nearest) or "-",
          #mr.owned, mr.hud_changes, mr.status))
      end
      imgui.text(wt.path_line())
      changed, overhead_force_estimate =
        imgui.checkbox("Overhead: force width estimate", overhead_force_estimate)
      if changed then label_widths = {} end
      if imgui.button("Probe overhead lookup") then
        local markers = snapshot ~= nil and snapshot.markers or {}
        local coord_logged = false
        for _, m in ipairs(markers) do
          local cid = core.marker_cid(m)
          if cid ~= nil then
            local m_pos, m_live, live, hstate = A.probe_lookup(cid)
            if live ~= nil then
              logmsg(string.format(
                "overhead probe cid=%d method(extract)=%s method(transform)=%s pos=%.1f,%.1f,%.1f",
                cid, tostring(m_pos), tostring(m_live), live.x, live.y, live.z))
              if not coord_logged then
                coord_logged = true
                local nx, ny, nz = adapter.npc_pos(cid)
                logmsg(string.format(
                  "overhead coord check cid=%d npc_pos=%s,%s,%s live=%.1f,%.1f,%.1f",
                  cid, tostring(nx), tostring(ny), tostring(nz),
                  live.x, live.y, live.z))
              end
            else
              logmsg(string.format(
                "overhead probe cid=%d live MISS (extract method=%s, holder=%s)",
                cid, tostring(m_pos), tostring(hstate)))
            end
          end
        end
        -- Reflection dump: what this build actually offers for a live
        -- character lookup (the four guessed method names all miss).
        pcall(function()
          local cm_td = sdk.find_type_definition("app.CharacterManager")
          if cm_td ~= nil then
            for _, meth in ipairs(cm_td:get_methods()) do
              local nm = meth:get_name()
              local l = nm:lower()
              if l:find("chara", 1, true) or l:find("find", 1, true) then
                logmsg(string.format("cm method: %s/%d -> %s", nm,
                  meth:get_num_params(),
                  tostring(meth:get_return_type():get_full_name())))
              end
            end
            for _, f in ipairs(cm_td:get_fields()) do
              logmsg(string.format("cm field: %s : %s", f:get_name(),
                f:get_type():get_full_name()))
            end
          end
        end)
        local dumped = 0
        for _, m in ipairs(markers) do
          local cid = core.marker_cid(m)
          if cid ~= nil and dumped < 2 then
            dumped = dumped + 1
            pcall(A.debug_probe_holder, cid, logmsg)
          end
        end
        logmsg(string.format("probe2 done: %d c-keyed markers dumped (of %d markers)",
          dumped, #markers))
      end
      local cs = A.catalog_stats()
      imgui.text(string.format(
        "Catalog: %d entries, %d skipped (%d cast), %d distinct side IDs (%d total)",
        cs.entries, cs.skipped, cs.cast_skipped, catalog_side_count(), cs.distinct))
      local os_ = adapter.objective_stats ~= nil and adapter.objective_stats() or nil
      if os_ ~= nil then
        imgui.text(string.format(
          "Objectives: %d quests from %d processors (%d kept, %d skipped, %d failed walks, %d builds), walk %.1f ms",
          os_.quests, os_.entries, os_.kept, os_.skipped, os_.failed_total,
          os_.index_builds or 0, last_walk_ms))
      end
      local gs = adapter.gate_stats ~= nil and adapter.gate_stats() or nil
      if gs ~= nil then
        imgui.text(string.format(
          "Gates: %d gated of %d acceptable (%d refs, %d skipped, %d failed walks), walk %.1f ms",
          gs.gated, gs.acceptable, gs.refs, gs.skipped, gs.failed_total,
          gs.last_ms))
      end
      if adapter.item_stats ~= nil then
        local ok_is, is_ = pcall(adapter.item_stats)
        if ok_is and is_ ~= nil then imgui.text(items_line(is_)) end
      end
      imgui.text(string.format("Tick: %.1f ms", last_tick_ms))
      if imgui.button("Probe quest states") then
        local qm = sdk.get_managed_singleton("app.QuestManager")
        local ids = A.catalog_ids() or {}
        -- Every failed/canceled quest logs (those are the rare ones the gate
        -- needs); completed quests cap at 20. All five predicates per line.
        local logged, completed_logged, tally = 0, 0, {}
        for _, qid in ipairs(ids) do
          local st = adapter.quest_state(qid)
          if st ~= nil then
            tally[st] = (tally[st] or 0) + 1
            if st ~= "completed" or completed_logged < 20 then
              if st == "completed" then
                completed_logged = completed_logged + 1
              end
              local raw = {}
              for _, mname in ipairs({ "isFailedQuest", "isCanceledQuest",
                "isClearedQuest", "isEndedQuest" }) do
                local ok, res = false, nil
                if qm ~= nil then
                  ok, res = pcall(function() return qm:call(mname, qid) end)
                end
                -- "err" distinguishes a failed call from a genuine false.
                raw[#raw + 1] = mname .. "="
                  .. (ok and tostring(res) or "err")
              end
              raw[#raw + 1] = "isQuestLogEnd="
                .. tostring(A.quest_log_is_end(qid))
              logmsg(string.format("state probe qid=%d state=%s %s",
                qid, st, table.concat(raw, " ")))
              logged = logged + 1
            end
          end
        end
        logmsg(string.format(
          "state probe: %d logged; failed %d canceled %d completed %d",
          logged, tally.failed or 0, tally.canceled or 0,
          tally.completed or 0))
      end
    end
    imgui.tree_pop()
  end

  draw_body = function()
    for _, s in ipairs(su.PANEL_ORDER) do sec[s.id]() end
  end

  re.on_draw_ui(function()
    if imgui.tree_node(MOD_NAME) then
      local ok, e = pcall(draw_body)
      imgui.tree_pop()
      if not ok then logerr(tostring(e)) end
    end
  end)
end

-- v9 (SPEC 16.3g): feeds the jump machine every frame; not the 2 s tick,
-- not gated by `enabled`. Defined once, so no closure is built per frame.
local function jump_feed()
  -- Idle: nothing pending or running, and the newest logged jump (entries
  -- resolve oldest first) already has its icon-rebuild count.
  if jump_pending == nil and not jump_machine:busy()
    and (jump_log[#jump_log] == nil or jump_log[#jump_log].setup_2s ~= nil) then
    return
  end
  if jump_pending ~= nil then
    -- SPEC 20.12.6: the target is the map origin from the first rebuild on
    local p = jump_pending
    wt.set_map_origin(p, os.clock())
    jump_machine:request(jump_pending)
    jump_pending = nil
  end
  local now = os.clock()
  local res = jump_machine:step(jump_frame, now)
  if res ~= nil then
    local tg = res.target
    if (res.result == "on_target" or res.result == "off_target") and tg ~= nil then
      wt.set_map_origin(tg, now)
    elseif ui_map == nil then
      wt.set_map_origin(nil, nil)
    end
    if adapter.journal_note_jump ~= nil then pcall(adapter.journal_note_jump, res.result) end
    res.t, res.setup_at = now, setup_icon_n
    jump_log[#jump_log + 1] = res
    if #jump_log > 8 then table.remove(jump_log, 1) end
  end
  for _, r in ipairs(jump_log) do
    if r.setup_2s == nil and now - r.t >= 2.0 then
      r.setup_2s = setup_icon_n - r.setup_at
      if settings.debug then logmsg(jump_line(r)) end
    end
  end
end
re.on_frame(function()
  jump_frame = jump_frame + 1
  local ok, err = pcall(jump_feed)
  if not ok and tostring(err) ~= jump_last_err then
    jump_last_err = tostring(err)
    logerr("jump: " .. jump_last_err)
  end
end)

re.on_frame(function()
  if os.clock() < overhead_suspend_until then return end
  local ok, err = pcall(overhead_frame)
  if ok then
    overhead_fail_frames = 0
  else
    overhead_fail_frames = overhead_fail_frames + 1
    local msg = tostring(err)
    if not overhead_logged_errs[msg] and overhead_logged_count < 16 then
      overhead_logged_errs[msg] = true
      overhead_logged_count = overhead_logged_count + 1
      logerr("overhead error: " .. msg)
    end
    if overhead_fail_frames >= 30 then
      overhead_fail_frames = 0
      overhead_suspend_until = os.clock() + 5.0
    end
  end
end)

-- v14 (SPEC 22.8.4c, 22.11.3): route stops and hint pins as overhead points.
-- Camera space = map space minus the player's offset, read each frame; no
-- offset means nothing this frame. Own failure counters (10.3b).
-- v14 (SPEC 23.6.8): the ready walking paths in the world, nodes raised 0.3 m.
-- A node out of range or off screen is a break; one polyline call draws all.
wt.world_path = function(cx, cy, cz, ox, oy, oz, max_d2)
  local pairs_ = wt.q("route_paths", nil, settings.world_undiscovered)
  if pairs_ == nil then return end
  local buf, n = wt.path_scr, 0
  for k = 1, #pairs_ do
    local pts = pairs_[k].pts
    if pts ~= nil then
      if n > 0 then buf[n + 1], buf[n + 2] = false, false; n = n + 2 end
      for q = 1, #pts - 2, 3 do
        local px, py, pz = pts[q] - ox, pts[q + 1] - oy + 0.3, pts[q + 2] - oz
        local dx, dy, dz = px - cx, py - cy, pz - cz
        local sx, sy = false, false
        if dx * dx + dy * dy + dz * dz <= max_d2 then
          local sp
          if proj_vec_reuse then
            proj_vec.x, proj_vec.y, proj_vec.z = px, py, pz
            sp = draw.world_to_screen(proj_vec)
          else
            sp = draw.world_to_screen(Vector3f.new(px, py, pz))
          end
          if sp ~= nil then sx, sy = sp.x, sp.y end
        end
        buf[n + 1], buf[n + 2] = sx, sy
        n = n + 2
      end
    end
  end
  for j = #buf, n + 1, -1 do buf[j] = nil end
  if n == 0 then return end
  local st = wt.styles.route_line
  local col = settings.route_line_color
  local t1 = st.on and os.clock() or nil
  wt.style.polyline(draw, buf, settings.route_line_width * wt.dk,
    A.argb_to_abgr(col), st.on, st.color, wt.style.offset(st.width, wt.dk), wt.a(col))
  if t1 ~= nil then wt.outline_acc = wt.outline_acc + (os.clock() - t1) * 1000 end
end
wt.route_frame = function()
  if not settings.enabled or not settings.show_overhead or not wt.has_pts
    or snapshot == nil or ui_map ~= nil then return end
  local pts = snapshot.route_pts
  if pts == nil then
    pts = {}
    for _, m in ipairs(snapshot.markers) do
      if m.cat == "route_stop" or m.cat == "hint_pin" then pts[#pts + 1] = m end
    end
    snapshot.route_pts = pts
  end
  local cx, cy, cz = camera_pos()
  if cx == nil then return end
  local ox, oy, oz = wt.read_offset()
  if ox == nil then return end
  local max_d2 = settings.overhead_distance * settings.overhead_distance
  if settings.route_world_path and settings.route_path == 1 then
    wt.world_path(cx, cy, cz, ox, oy, oz, max_d2)
  end
  local t1 = wt.any_on and os.clock() or nil
  for i = 1, #pts do
    local m = pts[i]
    local px, py, pz = m.pos.x - ox, m.pos.y - oy, m.pos.z - oz
    local dx, dy, dz = px - cx, py - cy, pz - cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 <= max_d2 then overhead_draw_one(m, px, py, pz, d2, max_d2) end
  end
  if t1 ~= nil then wt.outline_acc = wt.outline_acc + (os.clock() - t1) * 1000 end
end
re.on_frame(function() wt.layer_run(wt.route_layer, "route points", wt.route_frame) end)

-- v14 (SPEC 23.6.3): walking-path copy and search, 2 ms a frame, only while a
-- path route is shown or a copy is still running.
wt.path_frame = function()
  if (wt.route_on and settings.route_path == 1) or wt.q("path_busy", false) then
    wt.q("path_step", nil, 2, settings.route_path, settings.world_undiscovered)
  end
end
re.on_frame(function() wt.layer_run(wt.path_layer, "route path", wt.path_frame) end)

-- v14 (SPEC 22.9): names above heads. The quest set is built once per
-- snapshot: the c: marker cids and the cast of in-progress quest markers.
wt.names_quest_set = function()
  if wt.names_set_snap == snapshot and wt.names_set ~= nil then return wt.names_set end
  local set = {}
  for _, m in ipairs(snapshot.markers) do
    local c = core.marker_cid(m)
    if c ~= nil then set[c] = true end
    if m.cat == "in_progress" then
      for _, qid in ipairs(m.qids or {}) do
        local okc, cast = pcall(adapter.cast_ids, qid)
        if okc and type(cast) == "table" then
          for _, id in ipairs(cast) do set[id] = true end
        end
      end
    end
  end
  wt.names_set, wt.names_set_snap = set, snapshot
  return set
end
wt.names_frame = function()
  local mode = settings.overhead_names
  if not settings.enabled or mode == 0 or ui_map ~= nil
    or (mode == 1 and snapshot == nil) then return end
  local cx, cy, cz = camera_pos()
  if cx == nil then return end
  wt.q("spawned_step", nil, 200)
  local list = wt.spawned or {}
  local set = mode == 1 and wt.names_quest_set() or nil
  local max_d2 = settings.overhead_distance * settings.overhead_distance
  local st = wt.names_stats
  st.spawned, st.drawn, st.skipped = #list, 0, 0
  local nst = wt.styles.names
  local no = wt.style.offset(nst.width, wt.dk)
  local ncol = settings.names_color
  local nabgr, na = A.argb_to_abgr(ncol), wt.a(ncol)
  local t1 = nst.on and os.clock() or nil
  for i = 1, #list do
    local e = list[i]
    if set == nil or set[e.cid] then
      local tr = e.transform
      -- a freed NPC faults natively (10.5): the guard comes before every read
      if tr == nil or not sdk.is_managed_object(tr) then
        st.skipped = st.skipped + 1
      else
        local okp, px, py, pz = pcall(read_tr_pos, tr)
        if not okp or px == nil then
          st.skipped = st.skipped + 1
        else
          local dx, dy, dz = px - cx, py - cy, pz - cz
          if dx * dx + dy * dy + dz * dz <= max_d2 then
            local sp
            if proj_vec_reuse then
              proj_vec.x, proj_vec.y, proj_vec.z = px, py + OVERHEAD_Y_OFFSET, pz
              sp = draw.world_to_screen(proj_vec)
            else
              sp = draw.world_to_screen(Vector3f.new(px, py + OVERHEAD_Y_OFFSET, pz))
            end
            if sp ~= nil then
              if e.txt == nil or e.txt_dbg ~= settings.debug then
                local t = tostring(e.name)
                if e.tier ~= nil then t = t .. " - " .. e.tier end
                if settings.debug and e.value ~= nil then
                  t = t .. " (" .. tostring(e.value) .. ")"
                end
                e.txt, e.txt_dbg = t, settings.debug
              end
              local w = label_width(e.txt)
              local tx, ty = sp.x - w / 2, sp.y - 30   -- above the dot
              wt.style.text(draw, e.txt, tx, ty, nabgr, nst.on, nst.color, no, na)
              st.drawn = st.drawn + 1
            end
          end
        end
      end
    end
  end
  if t1 ~= nil then wt.outline_acc = wt.outline_acc + (os.clock() - t1) * 1000 end
end
re.on_frame(function() wt.layer_run(wt.names_layer, "names", wt.names_frame) end)
-- Coordinates in map space (the space of every marker and search result):
-- beside the full map's cursor, and under the minimap.
wt.coords_layer = wt.layer()
wt.coords_frame = function()
  if not settings.enabled then return end
  local now = os.clock()
  if settings.coords_map_cursor and ui_map ~= nil and sdk.is_managed_object(ui_map) then
    local c = adapter.map_cursor ~= nil and adapter.map_cursor(ui_map) or nil
    local pc = ui_map:get_field("PnlCursor")
    local gp = pc ~= nil and pc:call("get_GlobalPosition") or nil
    if c ~= nil and gp ~= nil then
      -- up and to the right of the cursor, clear of the hover label above it
      local sx, sy = wt.style.layout_to_screen(gp.x + wt.CURSOR_DX, gp.y + wt.CURSOR_DY,
        wt.dw, wt.dh)
      wt.coord_text(string.format("X %.0f  Z %.0f", c.x, c.z), sx, sy)
    end
  elseif settings.coords_minimap and settings.show_minimap and ui_map == nil
      and wt.mini_vis and wt.mini_t ~= nil and now - wt.mini_t < 0.2
      and (wt.mini_fade or 0) > 0.02 and player_origin ~= nil then
    -- below and to the left of the minimap circle, clear of its rim;
    -- fades out with the minimap
    local sx, sy = wt.style.layout_to_screen(wt.mini_x + wt.MINI_DX, wt.mini_y + wt.MINI_DY,
      wt.dw, wt.dh)
    wt.coord_text(string.format("X %.0f  Z %.0f  H %.0f",
      player_origin.x, player_origin.z, player_origin.y), sx, sy, wt.mini_fade)
  end
end
-- Outlined text, its top-left corner at x, y; a (0..1, default 1)
-- scales its alpha.
wt.coord_text = function(s, x, y, a)
  a = math.min(1, math.max(0, a or 1))
  local alpha = math.floor(0xFF * a + 0.5) << 24
  wt.style.text(draw, s, x, y, alpha | 0x00E8E0D0, true, 0xFF000000,
    wt.style.offset(1, wt.dk), a)
end
wt.CURSOR_DX, wt.CURSOR_DY = 18, -34
wt.MINI_DX, wt.MINI_DY = -245, 118
re.on_frame(function() wt.layer_run(wt.coords_layer, "coordinates", wt.coords_frame) end)

-- v14 (SPEC 22.10): item-menu quest dots, its own failure counters inside.
re.on_frame(function()
  if icons.itemmenu ~= nil then pcall(icons.itemmenu.frame, icons.itemmenu) end
end)

-- v13 (SPEC 21.2.7): after the overhead callback, so this frame's "head"
-- records are queued before the draw pass. Defined once; no closure per frame.
do
  local icons_err
  re.on_frame(function()
    local ok, err = pcall(icons.frame)
    if not ok and tostring(err) ~= icons_err then
      icons_err = tostring(err)
      logerr("icons: " .. icons_err)
    end
  end)
end

-- v14 (SPEC 22.11.1): the hints file, validated once; a missing or bad file
-- means no Hints nodes and one log line.
do
  local okh, why = pcall(function()
    local t = json.load_file("Clairvoyance_hints.json")
    if t == nil then error("hints file missing or unreadable", 0) end
    local hints, errs = require("Clairvoyance.npcs").parse_hints(t)
    wt.hints = hints
    adapter.set_item_quests(require("Clairvoyance.npcs").hint_items(hints))
    if #errs > 0 then error(#errs .. " hint entries dropped, first: " .. errs[1], 0) end
  end)
  if not okh then logmsg("hints: " .. tostring(why)) end
end

-- quest focus (SPEC 32.3): the quests file; a missing or bad file leaves
-- wt.quest_rel nil and logs one line. The pak stamp never rejects the file.
do
  local okq, why = pcall(function()
    local t = json.load_file("Clairvoyance_quests.json")
    if t == nil then error("quests file missing or unreadable", 0) end
    local quests, info = require("Clairvoyance.npcs").parse_quests(t)
    wt.quest_rel = quests
    wt.quest_pak = info.pak
    local line = string.format("quests: %d quests, pak %s, places pak %s", info.kept,
      tostring(wt.quest_pak), tostring(((wt.q("stats", {}) or {}).places or {}).pak))
    if info.dropped > 0 then
      line = line .. string.format(", %d dropped, first: %s", info.dropped, tostring(info.first))
    end
    logmsg(line)
  end)
  if not okq then logmsg("quests: " .. tostring(why)) end
end

logmsg("loaded")
