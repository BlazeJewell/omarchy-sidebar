-- jake.sidebar: the Hyprland side of the sidebar rice.
-- Loaded from ~/.config/hypr/hyprland.lua (after Omarchy's defaults and your own
-- files) by one line that hypr-link.sh adds; the sidebar runs that whenever it
-- starts, so `omarchy plugin add` is all it takes.
local home = os.getenv("HOME") or ""
local dir = home .. "/.config/omarchy/plugins/jake.sidebar/hypr/"

-- Only while the sidebar is the bar in use (Omarchy keeps that in shell.json as
-- bar.id): disabled, Super+Space and the rest stay Omarchy's own.
local function sidebar_active()
  local f = io.open(home .. "/.config/omarchy/shell.json", "r")
  if not f then return false end
  local text = f:read("*a") or ""
  f:close()
  return text:find('"id"%s*:%s*"jake%.sidebar"') ~= nil
end
if not sidebar_active() then return end

for _, name in ipairs({ "look", "binds", "solo", "rules", "installs" }) do
  dofile(dir .. name .. ".lua")
end
