#!/bin/bash
# Undo install.sh: back to Omarchy's bar and dock, Hyprland side unloaded.
#   ./uninstall.sh            keep the plugin folder and your layout files
#   ./uninstall.sh --purge    also delete them
set -uo pipefail
DEST="$HOME/.config/omarchy/plugins/jake.sidebar"
HYPR="$HOME/.config/hypr"
omarchy bar reset
omarchy plugin enable omarchy.dock >/dev/null 2>&1 || true
omarchy plugin disable jake.notifications >/dev/null 2>&1 || true
omarchy plugin enable omarchy.notifications >/dev/null 2>&1 || true
rm -f "$HOME/.config/omarchy/plugins/jake.notifications"
omarchy plugin disable jake.audio-meter >/dev/null 2>&1 || true
[[ -L $HOME/.config/omarchy/plugins/jake.audio-meter ]] && rm -f "$HOME/.config/omarchy/plugins/jake.audio-meter"
rm -f "$DEST/.setup-done"   # so using the sidebar again sets it up again
bash "$DEST/hypr-link.sh" --remove
if [[ ${1:-} == --purge ]]; then
  rm -f "$HOME"/.config/omarchy/sidebar-*.json
  rm -rf "$DEST"
fi
omarchy restart shell >/dev/null 2>&1 || true
echo "Sidebar removed.${1:+ (purged)}"
