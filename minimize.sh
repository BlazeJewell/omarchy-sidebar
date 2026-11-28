#!/bin/bash
# Minimize windows by sliding them out to the left: each is lifted out of the
# tiling layout where it stands (same size, same place), slides straight off
# the left edge, then moves to special:minimized. It stays parked there, so
# restoring it and handing it back to the layout slides it in from the left again.
#
# usage: minimize.sh <address>...
#        minimize.sh --clear <workspace> [address to keep ...]
#            the tiled windows on that workspace, except the ones kept (solo.sh)
# SIDEBAR_THEN, if set, is more "dispatch ..." commands (;-separated) sent in the
# same batch right after the slide starts, so whatever the sidebar brings
# forward moves in the same frame as the old window starts leaving.
#
# Every hyprctl call costs tens of milliseconds, so the state is read in one
# call and everything up to the start of the slide goes to Hyprland in one
# batch; this returns as soon as the slide has started, and the hiding
# afterwards runs in the background.
set -u
here=$(dirname "$0")
. "$here/hbatch.sh"
then=${SIDEBAR_THEN:-}
state=$(hyprctl -j --batch "monitors; clients" | jq -cs '{mon: .[0], clients: .[1]}')
fsnote=()

if [[ ${1:-} == --clear ]]; then
  ws=$2; shift 2
  # any fullscreen window on this workspace comes back fullscreen later (fsmem.sh)
  read -ra fsnote < <(jq -r --argjson ws "$ws" '[.clients[] | select(.workspace.id == $ws and (.fullscreen // 0) > 0) | .address, (.fullscreen | tostring)] | join(" ")' <<<"$state")
  sel=$(jq -c --argjson ws "$ws" --arg keep " $* " '[.clients[] | .address as $x
    | select(.workspace.id == $ws and (.floating | not) and ($keep | contains(" " + $x + " ") | not))]' <<<"$state")
else
  sel=$(jq -c --arg a " $* " '[.clients[] | .address as $x | select($a | contains(" " + $x + " "))]' <<<"$state")
  # a fullscreen window comes back fullscreen when restored (fsmem.sh)
  read -ra fsnote < <(jq -r '[.[] | select((.fullscreen // 0) > 0) | .address, (.fullscreen | tostring)] | join(" ")' <<<"$sel")
fi
(( ${#fsnote[@]} )) && bash "$here/fsmem.sh" note "${fsnote[@]}"

# One line per window: address, workspace, x, y, width, height, floating
info=$(jq -r '.[] | "\(.address) \(.workspace.id) \(.at[0]) \(.at[1]) \(.size[0]) \(.size[1]) \(.floating)"' <<<"$sel")
if [[ -z $info ]]; then
  [[ -n $then ]] && hbatch "$then"
  exit 0
fi
read -r mx rl active < <(jq -r '(first(.mon[] | select(.focused == true)) | "\(.x) \(.reserved[0])")
  + " " + (first(.clients[] | select(.focusHistoryID == 0) | .address) // "-")' <<<"$state")
ws=$(awk 'NR == 1 { print $2 }' <<<"$info")

batch=() hide=() unanim=() addrs=()
gx1="" gy1="" gx2="" gy2=""   # the space the tiled ones filled (restore.sh slides the next app into it, on top)
while read -r a wsid ax ay aw ah fl; do
  if [[ $fl != true ]]; then
    [[ -z $gx1 || $ax -lt $gx1 ]] && gx1=$ax; [[ -z $gy1 || $ay -lt $gy1 ]] && gy1=$ay
    [[ -z $gx2 || $((ax + aw)) -gt $gx2 ]] && gx2=$((ax + aw)); [[ -z $gy2 || $((ay + ah)) -gt $gy2 ]] && gy2=$((ay + ah))
  fi
  w="window = \"address:$a\""
  addrs+=("$a")
  # Float a tiled window without it moving or changing size: animations off
  # while Hyprland floats it, then straight back to its tile's size and place.
  # (hypr/solo.lua does the same for windows it lifts.)
  batch+=("dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", $w })")
  if [[ $fl != true ]]; then
    batch+=("dispatch hl.dsp.window.float({ action = \"on\", $w })"
            "dispatch hl.dsp.window.resize({ x = $aw, y = $ah, $w })"
            "dispatch hl.dsp.window.move({ x = $ax, y = $ay, $w })")
  fi
  # the same tag Omarchy's minimize uses, so its dock knows where a window came from
  [[ $wsid =~ ^[0-9]+$ ]] && batch+=("dispatch hl.dsp.window.tag({ tag = \"+omarchy-minimized-from-$wsid\", $w })")
  # Park with its right edge at the middle of the sidebar: hidden behind it, and
  # never out past its far (left) side. Same height and size.
  px=$(( mx + rl / 2 - aw ))
  batch+=("dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", $w })"
          "dispatch hl.dsp.window.move({ x = $px, y = $ay, $w })")
  # Moving onto the special workspace re-places it on screen, and with
  # animations on it would visibly slide back in for a moment; so animations
  # are off for the hop, and it's parked off the left edge again so restoring
  # slides it in from there.
  hide+=("dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", $w })"
         "dispatch hl.dsp.window.move({ workspace = \"special:minimized\", follow = false, $w })"
         "dispatch hl.dsp.window.move({ x = $px, y = $ay, $w })")
  unanim+=("dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", $w })")
done <<<"$info"
# If the window in front was one of these (and nothing else is being brought
# forward), hand focus back to its workspace so it doesn't stay on a hidden
# window (and the next app opened doesn't join it).
[[ -z $then && " ${addrs[*]} " == *" $active "* && $ws =~ ^[0-9]+$ && $ws -ge 1 ]] && unanim+=("dispatch hl.dsp.focus({ workspace = \"$ws\" })")

[[ -n $gx1 ]] && printf '%s %s %s %s %s %s\n' "$ws" "$gx1" "$gy1" "$((gx2 - gx1))" "$((gy2 - gy1))" "$(date +%s%N)" \
  >"${XDG_RUNTIME_DIR:-/tmp}/jake-sidebar-tile-area"
[[ -n $then ]] && batch+=("$then")
hbatch "${batch[@]}"
# Hidden as soon as its right edge is behind the sidebar (~200 ms into the
# 379 ms ease-out move), not when the move ends: a window is far wider than the
# sidebar, so while it creeps the last pixels its body shows in the gap left of it.
IFS=";"
setsid bash -c '. "$1"; sleep 0.2; hbatch "$2"; sleep 0.05; hbatch "$3"' _ \
  "$here/hbatch.sh" "${hide[*]}" "${unanim[*]}" >/dev/null 2>&1 < /dev/null &
exit 0
