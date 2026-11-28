#!/bin/bash
# What's installing, for the sidebar's install pill (beside the quick settings gear).
#   installs.sh status          -> one JSON line: {"active":false,"parked":"0x…|","parkedInput":…} or
#       {"active":true,"address":"0x…","tool":"pacman|yay|paru","pkgs":[…],
#        "phase":"…","input":true|false,"hidden":true|false,"log":[…]}
#   installs.sh hide ADDRESS    -> tuck the installer window away (special:jake-install)
#   installs.sh show ADDRESS    -> bring it back onto the current workspace, focused
#   installs.sh close ADDRESS   -> close it (when it's finished)
#   installs.sh check PKG...    -> "ok" if every package is installed, else "fail"
#
# Omarchy runs installs in a floating terminal (app id org.omarchy.terminal). It
# counts as an install once pacman / yay / paru runs in it (so Omarchy's package
# picker stays on screen until you've picked). "input" means one of its processes
# is waiting to read from the terminal: a sudo password or a [Y/n] question.
set -u
here=$(dirname "$0")
. "$here/hbatch.sh"
SPECIAL="special:jake-install"
safe_addr() { [[ $1 =~ ^0x[0-9a-fA-F]+$ ]] || { echo "bad address" >&2; exit 1; }; }

case "${1:-status}" in
  status)
    terms=$(hyprctl clients -j | jq -r '.[] | select(.class == "org.omarchy.terminal") | "\(.address) \(.pid) \(.workspace.name)"')
    [[ -z $terms ]] && { echo '{"active":false}'; exit 0; }
    # pid ppid stat wchan start(epoch-ish via etimes) args
    procs=$(ps -eo pid=,ppid=,stat=,wchan:32=,etimes=,args= 2>/dev/null)
    parked="" parked_input=false
    while read -r addr tpid wsname; do
      # every process under this terminal
      kids=$(awk -v root="$tpid" '
        { pid[NR] = $1; ppid[NR] = $2; line[NR] = $0 }
        END {
          keep[root] = 1; changed = 1
          while (changed) { changed = 0; for (i = 1; i <= NR; i++) if (keep[ppid[i]] && !keep[pid[i]]) { keep[pid[i]] = 1; changed = 1 } }
          for (i = 1; i <= NR; i++) if (keep[pid[i]] && pid[i] != root) print line[i]
        }' <<<"$procs")
      # the install tool: yay/paru first (they run pacman underneath), else pacman
      tool_line=$(awk '{ for (i = 6; i <= NF; i++) if ($i ~ /(^|\/)(yay|paru)$/) { print; exit } }' <<<"$kids")
      [[ -z $tool_line ]] && tool_line=$(awk '{ for (i = 6; i <= NF; i++) if ($i ~ /(^|\/)pacman$/) { print; exit } }' <<<"$kids")
      if [[ -z $tool_line ]]; then
        if [[ $wsname == "$SPECIAL" && -z $parked ]]; then
          parked=$addr
          awk '$3 ~ /\+/ && $4 ~ /tty|wait_woken|ep_poll|futex/' <<<"$kids" | grep -q . && parked_input=true
        fi
        continue
      fi
      tool=$(awk '{ for (i = 6; i <= NF; i++) if ($i ~ /(^|\/)(yay|paru|pacman)$/) { n = $i; sub(/.*\//, "", n); print n; exit } }' <<<"$tool_line")
      # packages: the words after the tool that aren't flags
      pkgs=$(awk '{ s = 0; for (i = 6; i <= NF; i++) { if (s && $i !~ /^-/) print $i; if ($i ~ /(^|\/)(yay|paru|pacman)$/) s = 1 } }' <<<"$tool_line" | jq -Rsc 'split("\n") | map(select(length > 0))')
      # waiting on the terminal: a foreground process asleep in a tty read
      input=false
      awk '$3 ~ /\+/ && $4 ~ /tty|wait_woken/' <<<"$kids" | grep -q . && input=true
      # sudo runs as root, so its wait can't be seen: a sudo with nothing running
      # under it yet is still asking for the password
      if ! $input; then
        while read -r spid; do
          [[ -z $spid ]] && continue
          awk -v p="$spid" '$2 == p' <<<"$kids" | grep -q . || input=true
        done < <(awk '{ for (i = 6; i <= NF; i++) if ($i ~ /(^|\/)sudo$/) { print $1; break } }' <<<"$kids")
      fi
      # yay / paru (Go) wait for an answer in the runtime's poller: count it when
      # the tool is in the foreground, asleep there, with nothing running under it
      if [[ $tool != pacman ]] && ! $input; then
        tpid_tool=$(awk '{ print $1 }' <<<"$tool_line")
        busy=$(awk -v p="$tpid_tool" '$2 == p' <<<"$kids")
        [[ -z $busy ]] && awk '$3 ~ /\+/ && $4 ~ /ep_poll|futex/' <<<"$tool_line" | grep -q . && input=true
      fi
      # pacman's log since the tool started (its timestamps are local ISO times)
      age=$(awk '{ print $5 }' <<<"$tool_line")
      since=$(date -d "@$(( $(date +%s) - age - 2 ))" +%Y-%m-%dT%H:%M:%S)
      log=$(tail -n 80 /var/log/pacman.log 2>/dev/null | awk -v since="$since" 'match($0, /^\[[0-9T:-]+/) { if (substr($0, 2, 19) >= since) print }')
      phase="downloading"
      grep -q 'transaction started' <<<"$log" && phase="installing"
      grep -q 'running post-transaction hooks\|ALPM-SCRIPTLET' <<<"$log" && phase="finishing"
      awk '{ for (i = 6; i <= NF; i++) if ($i ~ /(^|\/)makepkg$/) f = 1 } END { exit !f }' <<<"$kids" && phase="building"
      $input && phase="needs you"
      lines=$(sed -E 's/^\[[^]]*\] \[[^]]*\] //' <<<"$log" | tail -n 6 | jq -Rsc 'split("\n") | map(select(length > 0))')
      hidden=false; [[ $wsname == "$SPECIAL" ]] && hidden=true
      jq -nc --arg a "$addr" --arg t "$tool" --argjson p "$pkgs" --arg ph "$phase" --argjson in "$input" --argjson h "$hidden" --argjson l "$lines" \
        '{active: true, address: $a, tool: $t, pkgs: $p, phase: $ph, input: $in, hidden: $h, log: $l}'
      exit 0
    done <<<"$terms"
    # a window tucked away when it opened, with no install (yet) running in it
    jq -nc --arg p "$parked" --argjson pi "$parked_input" '{active: false, parked: $p, parkedInput: $pi}'
    ;;
  hide)
    safe_addr "${2:-}"
    hbatch "dispatch hl.dsp.window.move({ workspace = \"$SPECIAL\", follow = false, window = \"address:$2\" })"
    ;;
  show)
    safe_addr "${2:-}"
    ws=$(hyprctl activeworkspace -j | jq -r .id)
    [[ $ws =~ ^-?[0-9]+$ ]] || exit 1
    hbatch "dispatch hl.dsp.window.move({ workspace = \"$ws\", follow = false, window = \"address:$2\" })" \
           "dispatch hl.dsp.window.center({ window = \"address:$2\" })" \
           "dispatch hl.dsp.focus({ window = \"address:$2\" })"
    ;;
  close)
    safe_addr "${2:-}"
    hyprctl dispatch "hl.dsp.window.close({ window = \"address:$2\" })" >/dev/null
    ;;
  check)
    shift
    (( $# )) || { echo ok; exit 0; }
    for p in "$@"; do
      [[ $p =~ ^[A-Za-z0-9@._+-]+$ ]] || continue
      pacman -Qq -- "$p" &>/dev/null || { echo fail; exit 0; }
    done
    echo ok
    ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
