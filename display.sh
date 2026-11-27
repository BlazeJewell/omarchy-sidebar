#!/bin/bash
# Per-display settings for quick settings › Display. Every change applies live
# (hyprctl eval) and is saved as that monitor's own one-line rule in
# ~/.config/hypr/monitors.lua, so it survives reloads and reboots.
#
#   display.sh state                  -> JSON array, one object per connected monitor
#   display.sh brightness MON         -> percent, or nothing when MON has no control
#   display.sh mode MON WxH HZ|best   -> resolution / refresh rate
#   display.sh scale MON S            -> scale (rounded up to one Hyprland accepts)
#   display.sh transform MON 0-3      -> rotation (0, 90, 180, 270 degrees)
#   display.sh enable MON on|off      -> turn a monitor on or off (never the last one)
#   display.sh layout '[{"name":"DP-2","x":0,"y":0},...]'  -> positions
#   display.sh apply '[{name,disabled,res,rate,scale,transform,x,y},...]' [--confirm]
#                                     -> all of it at once; --confirm reverts it after
#                                        KEEP_SECS unless `display.sh keep` runs first
#   display.sh keep | revert          -> confirm, or undo, the last --confirm apply
#
# Arrangement / layout ideas from avb7/oma-display and marashiai/omarchy-display (MIT).
set -u

LUA="${DISPLAY_SH_LUA:-$HOME/.config/hypr/monitors.lua}"
fail() { echo "display.sh: $*" >&2; exit 1; }
safe_name() { [[ $1 =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "bad monitor name"; }
internal() { [[ $1 =~ ^(eDP|LVDS|DSI)- ]]; }
all() { hyprctl monitors all -j; }
mon_json() { all | jq -c --arg n "$1" '.[] | select(.name == $n)'; }
enabled_count() { all | jq '[.[] | select(.disabled != true)] | length'; }

clean_scale() {   # scale w h -> nearest clean scale at or above
  awk -v s="$1" -v w="$2" -v h="$3" 'function g(a,b,t){while(b){t=a%b;a=b;b=t}return a}
    BEGIN{d=g(w*120,h*120);k=int(s*120+0.5);if(k<1)k=1;if(k>d)k=d;while(d%k)k++;printf "%g\n",k/120}'
}

# The live rule for MON, as Lua (also what gets saved).
rule_for() {
  local m="$1" name pos mode w h hz first
  name=$(jq -r .name <<<"$m")
  if [[ $(jq -r .disabled <<<"$m") == true ]]; then
    printf 'hl.monitor({ output = "%s", disabled = true })' "$name"; return
  fi
  w=$(jq -r .width <<<"$m"); h=$(jq -r .height <<<"$m"); hz=$(jq -r '.refreshRate | . * 100 | round / 100' <<<"$m")
  # transform 1/3 swaps width and height in hyprctl's output: hyprctl reports
  # the mode itself, so no swap is needed here.
  mode="${w}x${h}@${hz}"
  first=$(jq -r '.availableModes[0] // ""' <<<"$m" | sed 's/Hz$//')
  [[ $first =~ ^${w}x${h}@ ]] && awk -v a="${first#*@}" -v b="$hz" 'BEGIN{exit !((a-b)^2 < 0.0001)}' && mode="preferred"
  if (( $(enabled_count) >= 2 )); then pos="$(jq -r .x <<<"$m")x$(jq -r .y <<<"$m")"; else pos="auto"; fi
  local t; t=$(jq -r '.transform // 0' <<<"$m")
  printf 'hl.monitor({ output = "%s", mode = "%s", position = "%s", scale = %s%s })' \
    "$name" "$mode" "$pos" "$(jq -r .scale <<<"$m" | awk '{printf "%g", $1}')" "$([[ $t != 0 ]] && echo ", transform = $t")"
}

# Save MON's rule: replace its one-line rule, or add one after Omarchy's catch-all.
# A rule written any other way (multi-line, expressions) is left alone.
persist() {
  local name="$1" line="${2:-}" target tmp gdk
  [[ -f $LUA ]] || return 0
  [[ -n $line ]] || line=$(rule_for "$(mon_json "$name")")
  target=$(readlink -f "$LUA"); tmp=$(mktemp "$target.XXXXXX") || return 0
  if ! awk -v pre="hl.monitor({ output = \"$name\"," -v line="$line" '
      index($0, pre) == 1 { if (done || $0 !~ /\}\)[[:space:]]*(--.*)?$/) { bad = 1; exit } ; print line; done = 1; next }
      { print; if (!done && !anchor && index($0, "hl.monitor({ output = \"\",") == 1) anchor = NR }
      END { if (bad) exit 1 }' "$target" >"$tmp"; then
    rm -f "$tmp"; return 0
  fi
  if ! grep -qF "hl.monitor({ output = \"$name\"," "$tmp"; then
    # no rule yet: insert after the catch-all, else append
    awk -v line="$line" '{ print } !put && index($0, "hl.monitor({ output = \"\",") == 1 { print line; put = 1 }
      END { if (!put) print line }' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
  fi
  # GDK_SCALE is one session-wide integer: the lowest enabled monitor scale, rounded.
  gdk=$(all | jq '[.[] | select(.disabled != true) | .scale] | (min // 1) + 0.5 | floor | if . < 1 then 1 else . end')
  sed -i -E -e "s|^local omarchy_gdk_scale = .*|local omarchy_gdk_scale = ${gdk}|" "$tmp"
  chmod --reference="$target" "$tmp"
  cmp -s "$tmp" "$target" && { rm -f "$tmp"; return 0; }
  mv "$tmp" "$target"
}

apply() {   # name mode pos scale transform
  hyprctl eval "hl.monitor({ output = \"$1\", mode = \"$2\", position = \"$3\", scale = $4, transform = $5 })" >/dev/null
}
live_pos() { if (( $(enabled_count) >= 2 )); then echo "$(jq -r .x <<<"$1")x$(jq -r .y <<<"$1")"; else echo auto; fi; }

# Keep / Revert: the settings before an apply, and the watchdog that puts them back.
RUN="${XDG_RUNTIME_DIR:-/tmp}/jake-display"
KEEP_SECS=15
snapshot() {   # live state as an apply payload, plus monitors.lua as it is now
  mkdir -p "$RUN"
  all | jq -c '[.[] | if .disabled == true then {name, disabled: true}
      else {name, disabled: false, res: "\(.width)x\(.height)", rate: (.refreshRate * 100 | round / 100 | tostring
              | if test("\\.") then (if test("\\.[0-9]$") then . + "0" else . end) else . + ".00" end),
            scale, transform: (.transform // 0), x, y} end]' >"$RUN/prev.json"
  if [[ -f $LUA ]]; then cp -f "$(readlink -f "$LUA")" "$RUN/prev.lua"; else rm -f "$RUN/prev.lua"; fi
}
forget() { rm -f "$RUN/token" "$RUN/prev.json" "$RUN/prev.lua"; }
revert() {
  [[ -f $RUN/prev.json ]] || return 0
  local prev; prev=$(cat "$RUN/prev.json")
  rm -f "$RUN/token"
  bash "$0" apply "$prev" >/dev/null 2>&1
  # then the exact file from before (apply only rewrites the monitors' own lines)
  if [[ -f $RUN/prev.lua && -f $LUA ]]; then
    local target; target=$(readlink -f "$LUA")
    cmp -s "$RUN/prev.lua" "$target" || { cp -f "$RUN/prev.lua" "$target.revert" && mv -f "$target.revert" "$target"; }
  fi
  forget
}

cmd="${1:-state}"
case "$cmd" in
  state)
    all | jq -c '[.[] | {
        name, description,
        label: ((((.make // "") + " " + (.model // "")) | gsub("^ +| +$"; "")) as $l | if $l == "" then .name else $l end),
        internal: (.name | test("^(eDP|LVDS|DSI)-")),
        w: .width, h: .height, hz: .refreshRate,
        mode: "\(.width)x\(.height)@\(.refreshRate)",
        x, y, scale, transform: (.transform // 0),
        disabled: (.disabled == true), focused: (.focused == true), mirrorOf: (.mirrorOf // "none"),
        resolutions: ([.availableModes[] | sub("@.*"; "")] | unique
                      | sort_by(split("x") | (.[0] | tonumber) * (.[1] | tonumber)) | reverse),
        ratesByRes: (reduce (.availableModes[] | sub("Hz$"; "") | split("@")) as $m ({}; .[$m[0]] += [$m[1]])
                     | map_values(unique | sort_by(tonumber) | reverse)),
        rates: (("\(.width)x\(.height)@") as $p | [.availableModes[] | select(startswith($p)) | sub(".*@"; "") | sub("Hz"; "")]
                | unique | sort_by(tonumber) | reverse)
      }] | sort_by(.x, .y)'
    ;;
  brightness)
    safe_name "${2:-}"
    timeout 4 omarchy-brightness-display --monitor "$2" 2>/dev/null | head -n1 | tr -dc '0-9'; echo
    ;;
  mode)
    name=${2:-}; res=${3:-}; rate=${4:-}; safe_name "$name"
    [[ $res =~ ^[0-9]+x[0-9]+$ ]] || fail "bad resolution"
    m=$(mon_json "$name"); [[ -n $m ]] || fail "no such monitor"
    if [[ $rate == best ]]; then
      rate=$(jq -r --arg p "${res}@" '[.availableModes[] | select(startswith($p)) | sub(".*@"; "") | sub("Hz"; "")] | sort_by(tonumber) | last // empty' <<<"$m")
    fi
    [[ $rate =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "bad rate"
    jq -e --arg m "${res}@${rate}Hz" '.availableModes | index($m)' <<<"$m" >/dev/null || fail "unsupported mode"
    sc=$(clean_scale "$(jq -r .scale <<<"$m")" "${res%x*}" "${res#*x}")
    apply "$name" "${res}@${rate}" "$(live_pos "$m")" "$sc" "$(jq -r '.transform // 0' <<<"$m")"
    persist "$name"
    ;;
  scale)
    name=${2:-}; s=${3:-}; safe_name "$name"
    [[ $s =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "bad scale"
    m=$(mon_json "$name"); [[ -n $m ]] || fail "no such monitor"
    w=$(jq -r .width <<<"$m"); h=$(jq -r .height <<<"$m")
    sc=$(clean_scale "$s" "$w" "$h")
    apply "$name" "${w}x${h}@$(jq -r .refreshRate <<<"$m")" "$(live_pos "$m")" "$sc" "$(jq -r '.transform // 0' <<<"$m")"
    persist "$name"
    ;;
  transform)
    name=${2:-}; t=${3:-}; safe_name "$name"
    [[ $t =~ ^[0-3]$ ]] || fail "bad rotation"
    m=$(mon_json "$name"); [[ -n $m ]] || fail "no such monitor"
    apply "$name" "$(jq -r '"\(.width)x\(.height)@\(.refreshRate)"' <<<"$m")" "$(live_pos "$m")" "$(jq -r .scale <<<"$m")" "$t"
    persist "$name"
    ;;
  enable)
    name=${2:-}; on=${3:-}; safe_name "$name"
    m=$(mon_json "$name"); [[ -n $m ]] || fail "no such monitor"
    if [[ $on == off ]]; then
      [[ $(jq -r .disabled <<<"$m") == true ]] && exit 0
      (( $(enabled_count) >= 2 )) || fail "refusing to turn off the last display"
      if internal "$name" && command -v omarchy-hyprland-monitor-internal >/dev/null; then
        # Omarchy's clamshell watcher would turn a plain disabled rule back on.
        omarchy-hyprland-monitor-internal off >/dev/null 2>&1; exit 0
      fi
      hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })" >/dev/null
      persist "$name" "hl.monitor({ output = \"$name\", disabled = true })"
    elif [[ $on == on ]]; then
      if internal "$name" && command -v omarchy-hyprland-monitor-internal >/dev/null; then
        omarchy-hyprland-monitor-internal on >/dev/null 2>&1; exit 0
      fi
      line="hl.monitor({ output = \"$name\", mode = \"preferred\", position = \"auto\", scale = \"auto\" })"
      hyprctl eval "$line" >/dev/null
      persist "$name" "$line"
      sleep 0.5; persist "$name"   # then save what it actually came up as
    else fail "on or off"; fi
    ;;
  layout)
    json=${2:-}
    jq -e 'type == "array" and length > 0 and all(.[]; (.name | type == "string") and (.x | type == "number") and (.y | type == "number"))' <<<"$json" >/dev/null 2>&1 || fail "bad layout"
    mons=$(all)
    while read -r name x y; do
      safe_name "$name"
      m=$(jq -c --arg n "$name" '.[] | select(.name == $n and .disabled != true)' <<<"$mons"); [[ -n $m ]] || continue
      apply "$name" "$(jq -r '"\(.width)x\(.height)@\(.refreshRate)"' <<<"$m")" "${x}x${y}" "$(jq -r .scale <<<"$m")" "$(jq -r '.transform // 0' <<<"$m")"
    done < <(jq -r '.[] | "\(.name) \(.x | round) \(.y | round)"' <<<"$json")
    sleep 0.3
    for name in $(jq -r '.[].name' <<<"$json"); do safe_name "$name"; persist "$name"; done
    ;;
  keep) forget; echo ok ;;
  revert) revert; echo ok ;;
  _watch)
    sleep "$KEEP_SECS"
    if [[ -f $RUN/token && $(cat "$RUN/token") == "${2:-}" ]]; then
      revert
      notify-send -a "Display" "Display settings reverted" "The new settings weren't kept, so the previous ones are back." 2>/dev/null || true
    fi
    ;;
  apply)
    # Everything at once, from quick settings' Apply button:
    #   [{"name":"DP-2","disabled":false,"res":"3840x2160","rate":"160.00","scale":1.25,"transform":0,"x":0,"y":0}, ...]
    json=${2:-}
    jq -e 'type == "array" and length > 0 and any(.[]; .disabled != true)' <<<"$json" >/dev/null 2>&1 || fail "bad payload (or every display off)"
    if [[ ${3:-} == --confirm ]]; then
      # a newer apply replaces an unconfirmed one, but keeps the original "before"
      [[ -f $RUN/token && -f $RUN/prev.json ]] || snapshot
    fi
    mons=$(all)
    on=$(jq '[.[] | select(.disabled != true)] | length' <<<"$json")
    # turn displays on first, so the others can be placed against them
    while IFS=$'\t' read -r name dis res rate s t x y; do
      safe_name "$name"
      m=$(jq -c --arg n "$name" '.[] | select(.name == $n)' <<<"$mons"); [[ -n $m ]] || continue
      was_off=$(jq -r .disabled <<<"$m")
      if [[ $dis == true ]]; then
        [[ $was_off == true ]] && continue
        if internal "$name" && command -v omarchy-hyprland-monitor-internal >/dev/null; then
          omarchy-hyprland-monitor-internal off >/dev/null 2>&1
        else
          hyprctl eval "hl.monitor({ output = \"$name\", disabled = true })" >/dev/null
        fi
        continue
      fi
      if [[ $was_off == true ]] && internal "$name" && command -v omarchy-hyprland-monitor-internal >/dev/null; then
        omarchy-hyprland-monitor-internal on >/dev/null 2>&1; sleep 0.5
      fi
      [[ $res =~ ^[0-9]+x[0-9]+$ ]] || fail "bad resolution for $name"
      if [[ $rate == best || -z $rate ]]; then
        rate=$(jq -r --arg p "${res}@" '[.availableModes[] | select(startswith($p)) | sub(".*@"; "") | sub("Hz"; "")] | sort_by(tonumber) | last // empty' <<<"$m")
      fi
      [[ $rate =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "bad rate for $name"
      jq -e --arg m "${res}@${rate}Hz" '.availableModes | index($m)' <<<"$m" >/dev/null || fail "$name doesn't support ${res}@${rate}"
      [[ $s =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "bad scale for $name"
      [[ $t =~ ^[0-3]$ ]] || fail "bad rotation for $name"
      [[ $x =~ ^-?[0-9]+$ && $y =~ ^-?[0-9]+$ ]] || fail "bad position for $name"
      if (( on >= 2 )); then pos="${x}x${y}"; else pos=auto; fi
      apply "$name" "${res}@${rate}" "$pos" "$(clean_scale "$s" "${res%x*}" "${res#*x}")" "$t"
    done < <(jq -r '.[] | [.name, (.disabled == true), (.res // ""), (.rate // "best" | tostring), (.scale // 1 | tostring), (.transform // 0 | tostring), (.x // 0 | round | tostring), (.y // 0 | round | tostring)] | @tsv' <<<"$json")
    sleep 0.5
    for name in $(jq -r '.[].name' <<<"$json"); do
      safe_name "$name"
      internal "$name" && [[ $(jq -r --arg n "$name" '.[] | select(.name == $n) | .disabled == true' <<<"$json") == true ]] && continue
      if [[ $(jq -r --arg n "$name" '.[] | select(.name == $n) | .disabled == true' <<<"$json") == true ]]; then
        persist "$name" "hl.monitor({ output = \"$name\", disabled = true })"
      else
        persist "$name"
      fi
    done
    if [[ ${3:-} == --confirm ]]; then
      token="$$-$(date +%s%N)"; printf '%s' "$token" >"$RUN/token"
      setsid -f bash "$0" _watch "$token" >/dev/null 2>&1 </dev/null
    fi
    echo ok
    ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
