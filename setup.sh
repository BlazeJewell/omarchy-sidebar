#!/bin/bash
# Run by the sidebar every time it starts (and by install.sh), so that
# `omarchy plugin add` gives the whole rice without running anything else.
#
# Every start: hook up the Hyprland side if it isn't (hypr-link.sh; cheap
# when it's already there).
#
# Once per install: turn off Omarchy's dock (the sidebar lists apps itself)
# and dock notifications top-left against the sidebar (notifications/, linked
# in as its own plugin, jake.notifications). "Once" is remembered by
# .setup-done in this folder: it survives `omarchy plugin update`, so turning
# the dock back on afterwards sticks, and goes away with the folder, so
# removing and re-adding the plugin sets it up again.
#   setup.sh           as above
#   setup.sh --force   redo the once-per-install part (install.sh)
set -u
here=$(cd "$(dirname "$0")" && pwd)
done_file="$here/.setup-done"

bash "$here/hypr-link.sh"

# one at a time: the sidebar may start again while this runs (enabling a
# plugin can restart the shell)
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/jake-sidebar-setup.lock"
flock 9
[[ ${1:-} == --force ]] && rm -f "$done_file"
[[ -e $done_file ]] && exit 0
date -Is > "$done_file"

omarchy plugin disable omarchy.dock >/dev/null 2>&1 || true

link="$HOME/.config/omarchy/plugins/jake.notifications"
if [[ -L $link || ! -e $link ]]; then
  ln -sfn "$here/notifications" "$link"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  for _ in $(seq 40); do
    omarchy-plugin-list --json 2>/dev/null | jq -e 'any(.[]; .id == "jake.notifications")' >/dev/null && break
    sleep 0.05
  done
  omarchy plugin enable jake.notifications >/dev/null 2>&1 || true
fi

# the audio meter (audio-meter/) is linked in so it can be added as a section;
# it isn't turned on here
meter="$HOME/.config/omarchy/plugins/jake.audio-meter"
if [[ -L $meter || ! -e $meter ]]; then
  ln -sfn "$here/audio-meter" "$meter"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi
