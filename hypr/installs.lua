-- Installs out of sight, for the jake.sidebar plugin.
--
-- Omarchy runs installs in a floating terminal in the middle of the screen
-- (app id org.omarchy.terminal). When the command it was started with is an
-- install, the window goes straight to special:jake-install as it opens, before
-- it's drawn, and the sidebar's install pill (beside the gear) shows how it's
-- going. Omarchy's package pickers (omarchy-pkg-install / -aur-install) stay on
-- screen: you choose in them; the sidebar tucks them away once pacman starts.
-- If a tucked-away window asks for something (a password, a [Y/n]) or no install
-- starts in it, the sidebar brings it back (installs.sh / Sidebar.qml).

local SPECIAL = "special:jake-install"

local function cmdline(pid)
  if not pid or pid <= 0 then return "" end
  local f = io.open("/proc/" .. pid .. "/cmdline", "rb")
  if not f then return "" end
  local s = (f:read("*a") or ""):gsub("%z", " ")
  f:close()
  return s
end

local function is_install(cmd)
  -- pickers: you need to see them
  if cmd:find("omarchy%-pkg%-install") or cmd:find("omarchy%-pkg%-aur%-install") or cmd:find("omarchy%-pkg%-remove") then
    return false
  end
  return cmd:find("omarchy%-pkg%-add") ~= nil
      or cmd:find("omarchy%-pkg%-aur%-add") ~= nil
      or cmd:find("omarchy%-install%-") ~= nil
      or cmd:find("pacman %-S") ~= nil
      or cmd:find("yay %-S") ~= nil
      or cmd:find("paru %-S") ~= nil
end

hl.on("window.open", function(window)
  if not window or window.class ~= "org.omarchy.terminal" then return end
  if not is_install(cmdline(window.pid)) then return end
  local w = "address:" .. window.address
  hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "1", window = w }))
  hl.dispatch(hl.dsp.window.move({ workspace = SPECIAL, follow = false, window = w }))
  hl.timer(function()
    hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = "unset", window = w }))
  end, { timeout = 100, type = "oneshot" })
end)
