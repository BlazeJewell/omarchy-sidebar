-- One app at a time, for the jake.sidebar plugin.
--
-- A tiled window that opens takes its workspace to itself: the other tiled
-- windows there slide out to the left and are minimized (to special:minimized,
-- where the sidebar lists them). Doing it here, as the window opens, means it is placed full
-- size straight away and slides in from the left like every other window,
-- instead of opening in a tile and then growing.
--
-- Left alone:
--   * floating windows (dialogs, pickers)
--   * a window whose app already has one showing there (Steam's chat or news
--     next to Steam, a second Firefox window): it tiles with it
--   * the next window after Shift+click or drag-and-drop in the sidebar, which
--     leaves a short-lived note in $XDG_RUNTIME_DIR/jake-sidebar-tile-next

local tile_next_file = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/jake-sidebar-tile-next"

local function take_tile_next()
  local f = io.open(tile_next_file, "r")
  if not f then return false end
  local until_s = tonumber(f:read("*l") or "") or 0
  f:close()
  os.remove(tile_next_file)
  return os.time() <= until_s
end

-- Which windows are fullscreen (and how), and the last one to leave it.
local fullscreen_mode = {}
local last_unfullscreen = nil
hl.on("window.fullscreen", function(window)
  if not window then return end
  if (window.fullscreen or 0) > 0 then
    fullscreen_mode[window.address] = window.fullscreen
  elseif fullscreen_mode[window.address] then
    last_unfullscreen = { address = window.address, mode = fullscreen_mode[window.address], at = os.time() }
    fullscreen_mode[window.address] = nil
  end
end)

hl.on("window.open", function(window)
  if not window or window.floating then return end
  local ws = window.workspace
  if not ws or not ws.id or ws.id < 1 then return end

  local others = {}
  for _, other in ipairs(hl.get_workspace_windows(ws.id) or {}) do
    if other.address ~= window.address and not other.floating then
      if other.class == window.class then return end
      table.insert(others, other)
    end
  end
  if #others == 0 then return end
  if take_tile_next() then return end

  -- Lift them out of the layout right away so the new window is placed full
  -- size, then slide them off to the left and hide them (minimize.sh).
  -- A fullscreen one comes back fullscreen when restored from the sidebar
  -- (fsmem.sh). Hyprland has already taken it out of fullscreen by now, just
  -- before this window opened, so go by that.
  if last_unfullscreen and os.time() - last_unfullscreen.at <= 1 then
    for _, other in ipairs(others) do
      if other.address == last_unfullscreen.address then
        local mem = io.open((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/jake-sidebar-fullscreen", "a")
        if mem then mem:write(other.address .. " " .. last_unfullscreen.mode .. "\n"); mem:close() end
      end
    end
  end

  -- The same slide as minimize.sh, done right here so it starts in the same
  -- frame the new window opens (no script to start first). Each window is
  -- lifted where it stands (animations off while Hyprland floats it, then
  -- straight back to its tile's size and place), slides off the left edge as
  -- it is, and once it's gone hops to special:minimized, unseen.
  local function xy(v)
    if type(v) ~= "table" then return nil end
    return v.x or v[1], v.y or v[2]
  end
  local mon = window.monitor
  local mx = mon and (mon.x or xy(mon.position))
  local rl = mon and type(mon.reserved) == "table" and (mon.reserved.left or mon.reserved[1]) or 0
  local parked, fallback = {}, {}
  local area = nil   -- the space the leaving windows filled: the new window's tile
  for _, other in ipairs(others) do
    local w = "address:" .. other.address
    local ax, ay = xy(other.at)
    local aw, ah = xy(other.size)
    if ax and ay and aw and ah then
      if not area then area = { x1 = ax, y1 = ay, x2 = ax + aw, y2 = ay + ah }
      else
        area.x1 = math.min(area.x1, ax); area.y1 = math.min(area.y1, ay)
        area.x2 = math.max(area.x2, ax + aw); area.y2 = math.max(area.y2, ay + ah)
      end
    end
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = w }))
    hl.dispatch(hl.dsp.window.float({ action = "on", window = w }))
    if aw and ah and ax and ay and mx then
      hl.dispatch(hl.dsp.window.resize({ x = aw, y = ah, window = w }))
      hl.dispatch(hl.dsp.window.move({ x = ax, y = ay, window = w }))
      -- the same tag Omarchy's minimize uses, so its dock knows where a window came from
      hl.dispatch(hl.dsp.window.tag({ tag = "+omarchy-minimized-from-" .. ws.id, window = w }))
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", window = w }))
      -- park with its right edge at the middle of the sidebar: hidden behind it, and
      -- never out past its far (left) side; same height and size
      local px = math.floor(mx + rl / 2 - aw)
      hl.dispatch(hl.dsp.window.move({ x = px, y = ay, window = w }))
      table.insert(parked, { w = w, x = px, y = ay })
    else
      table.insert(fallback, other.address)
    end
  end
  -- The leaving windows are floating now, and floating windows draw above tiled
  -- ones, so the new window would slide in underneath them. Float it too, at the
  -- very tile it's getting, on top; once the slide is over it goes back into the
  -- layout (same size and place, so nothing moves).
  if #parked > 0 and area and (window.fullscreen or 0) == 0 then
    local nw = "address:" .. window.address
    hl.dispatch(hl.dsp.window.float({ action = "on", window = nw }))
    hl.dispatch(hl.dsp.window.resize({ x = area.x2 - area.x1, y = area.y2 - area.y1, window = nw }))
    hl.dispatch(hl.dsp.window.move({ x = area.x1, y = area.y1, window = nw }))
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = nw }))
    hl.timer(function()
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = nw }))
      hl.dispatch(hl.dsp.window.float({ action = "off", window = nw }))
      hl.timer(function()
        hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", window = nw }))
      end, { timeout = 50, type = "oneshot" })
    end, { timeout = 450, type = "oneshot" })
  end
  if #parked > 0 then
    hl.timer(function()
      -- moving a focused window away refocuses another; don't let that move the pointer
      local warps_off = hl.get_config("cursor.no_warps")
      hl.config({ cursor = { no_warps = true } })
      for _, p in ipairs(parked) do
        -- Moving onto the special workspace re-places it on screen; animations
        -- off so it doesn't visibly slide back, then parked off the left edge
        -- again so restoring slides it in from there.
        hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = p.w }))
        hl.dispatch(hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = p.w }))
        hl.dispatch(hl.dsp.window.move({ x = p.x, y = p.y, window = p.w }))
      end
      hl.config({ cursor = { no_warps = warps_off == true } })
      hl.timer(function()
        for _, p in ipairs(parked) do
          hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", window = p.w }))
        end
      end, { timeout = 50, type = "oneshot" })
    -- hidden as soon as its right edge is behind the sidebar (~200 ms into the
    -- 379 ms ease-out move), not when the move ends: a window is far wider than
    -- the sidebar, so while it creeps the last pixels its body shows in the gap
    -- left of the sidebar
    end, { timeout = 200, type = "oneshot" })
  end
  -- couldn't read a window's geometry here: let minimize.sh do it
  if #fallback > 0 then
    hl.exec_cmd("bash " .. os.getenv("HOME") .. "/.config/omarchy/plugins/jake.sidebar/minimize.sh " .. table.concat(fallback, " "))
  end
end)
