#!/bin/bash
# Bring minimized windows back onto a workspace and focus the last one.
# usage: restore.sh <workspace> <address>...
# On a tiled workspace a window goes back into the layout, sliding in from where
# minimize.sh parked it off the left edge. On an Omarchy floating workspace it
# stays floating and is centred. A window that was fullscreen goes back to
# fullscreen (fsmem.sh). Everything goes to Hyprland in one batch.
set -u
ws=$1; shift
(( $# )) || exit 0
here=$(dirname "$0")
. "$here/hbatch.sh"
layout=$(omarchy-hyprland-workspace-layout-current "$ws" 2>/dev/null || echo dwindle)
# the tags Omarchy's own minimize leaves (minimize.sh adds them too), per window
tags=$(hyprctl clients -j | jq -r --arg a " $* " '.[] | .address as $x | select($a | contains(" " + $x + " "))
  | .address + " " + ([(.tags // [])[] | select(test("^omarchy-minimized-from-"))] | join(" "))')
# Windows sliding out right now (minimize.sh, a moment ago) are floating, and
# floating windows draw above tiled ones: a window tiled straight away would
# slide in underneath them. So a single window coming back into a tiled
# workspace slides in floating, on top, into the space they left, and joins the
# layout once the slide is over (same size and place, so nothing moves).
area=() ontop=""
af="${XDG_RUNTIME_DIR:-/tmp}/jake-sidebar-tile-area"
if [[ $layout != floating && $# -eq 1 && -f $af ]]; then
  read -ra area <"$af"
  rm -f "$af"
  now=$(date +%s%N)
  [[ ${#area[@]} -eq 6 && ${area[0]} == "$ws" && $(( (now - area[5]) / 1000000 )) -lt 1500 ]] && ontop=$1
  # one going back to fullscreen (fsmem.sh) isn't sliding in at all
  grep -q "^$1 " "${XDG_RUNTIME_DIR:-/tmp}/jake-sidebar-fullscreen" 2>/dev/null && ontop=""
fi
batch=()
for a in "$@"; do
  w="window = \"address:$a\""
  batch+=("dispatch hl.dsp.window.move({ workspace = \"$ws\", follow = false, $w })")
  if [[ $layout == floating ]]; then
    batch+=("dispatch hl.dsp.window.center({ $w })")
  elif [[ $a == "$ontop" ]]; then
    # it's still floating, parked off the left edge: this slides it in from there
    batch+=("dispatch hl.dsp.window.resize({ x = ${area[3]}, y = ${area[4]}, $w })"
            "dispatch hl.dsp.window.move({ x = ${area[1]}, y = ${area[2]}, $w })"
            "dispatch hl.dsp.window.alter_zorder({ mode = \"top\", $w })")
  else
    batch+=("dispatch hl.dsp.window.float({ action = \"off\", $w })")
  fi
  for t in $(awk -v a="$a" '$1 == a { $1 = ""; print }' <<<"$tags"); do
    batch+=("dispatch hl.dsp.window.tag({ tag = \"-$t\", $w })")
  done
done
batch+=("dispatch hl.dsp.focus({ window = \"address:${*: -1}\" })")
hbatch "${batch[@]}"
if [[ -n $ontop ]]; then
  w="window = \"address:$ontop\""
  setsid bash -c '. "$1"; sleep 0.45; hbatch "$2" "$3"; sleep 0.05; hbatch "$4"' _ "$here/hbatch.sh" \
    "dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"1\", $w })" \
    "dispatch hl.dsp.window.float({ action = \"off\", $w })" \
    "dispatch hl.dsp.window.set_prop({ prop = \"no_anim\", value = \"unset\", $w })" >/dev/null 2>&1 </dev/null &
fi
bash "$here/fsmem.sh" restore "$@"
