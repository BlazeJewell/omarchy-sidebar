#!/bin/bash
# Keyboard & mouse settings for quick settings › Keyboard & mouse.
#   input.sh get               -> JSON of the live values (+ "touchpad": true when one is connected)
#   input.sh set KEY VALUE     -> apply now and save
#   input.sh reset             -> drop every override (back to Omarchy's defaults)
#
# What's set is kept in ~/.config/omarchy/sidebar-input.json and written as one
# marked block at the end of ~/.config/hypr/input.lua (so it wins over Omarchy's
# defaults); the rest of that file is left alone.
set -u

LUA="${INPUT_SH_LUA:-$HOME/.config/hypr/input.lua}"
JSON="${INPUT_SH_JSON:-$HOME/.config/omarchy/sidebar-input.json}"
BEGIN="-- >>> jake.sidebar input (set from quick settings › Keyboard & mouse; edits here are overwritten) >>>"
END="-- <<< jake.sidebar input <<<"
fail() { echo "input.sh: $*" >&2; exit 1; }

# key -> type min max
spec() {
  case "$1" in
    repeat_rate) echo "int 1 100" ;;
    repeat_delay) echo "int 100 2000" ;;
    numlock_by_default | natural_scroll) echo "bool" ;;
    sensitivity) echo "float -1 1" ;;
    scroll_factor) echo "float 0.1 5" ;;
    accel_profile) echo "enum flat adaptive default" ;;
    touchpad.natural_scroll | touchpad.tap_to_click | touchpad.disable_while_typing) echo "bool" ;;
    touchpad.scroll_factor) echo "float 0.1 5" ;;
    *) return 1 ;;
  esac
}

opt() {
  local k=${1//./:}; k=${k//tap_to_click/tap-to-click}   # hyprctl still names it tap-to-click
  hyprctl getoption "input:$k" -j 2>/dev/null | jq -c 'if has("int") then .int elif has("float") then .float elif has("bool") then .bool else .str end'
}

# Lua for the whole block, from the saved JSON
render() {
  jq -r --arg b "$BEGIN" --arg e "$END" '
    def lua: if type == "string" then "\"" + . + "\"" else tostring end;
    def key: if test("^[A-Za-z_][A-Za-z0-9_]*$") then . else "[\"" + . + "\"]" end;
    (to_entries | map(select(.key | contains(".") | not)) | map("    " + (.key | key) + " = " + (.value | lua) + ",")) as $top
    | (to_entries | map(select(.key | startswith("touchpad."))) | map("      " + (.key | ltrimstr("touchpad.") | key) + " = " + (.value | lua) + ",")) as $tp
    | if (($top + $tp) | length) == 0 then empty else
        [$b, "hl.config({", "  input = {"] + $top
        + (if ($tp | length) > 0 then ["    touchpad = {"] + $tp + ["    },"] else [] end)
        + ["  },", "})", $e] | join("\n")
      end' "$JSON"
}

write_block() {
  [[ -f $LUA ]] || fail "$LUA not found"
  local target tmp block
  target=$(readlink -f "$LUA")
  # refuse if a marker is missing its partner: we'd drop the rest of the file
  awk -v b="$BEGIN" -v e="$END" '$0==b{if(o)bad=1;o=1} $0==e{if(!o)bad=1;o=0} END{exit (bad||o)?1:0}' "$target" \
    || fail "$LUA has a broken jake.sidebar block; fix it by hand"
  block=$( [[ -f $JSON ]] && render )
  tmp=$(mktemp "$target.XXXXXX") || exit 1
  {
    awk -v b="$BEGIN" -v e="$END" '$0==b{s=1;next} $0==e{s=0;next} !s' "$target" | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
    [[ -n $block ]] && printf '\n%s\n' "$block"
  } >"$tmp"
  chmod --reference="$target" "$tmp"
  if cmp -s "$tmp" "$target"; then rm -f "$tmp"; else mv -f "$tmp" "$target"; fi
  sleep 0.3
  if [[ -n $(hyprctl configerrors 2>/dev/null | sed '/^[[:space:]]*$/d') ]]; then
    echo "input.sh: Hyprland reported config errors after the change:" >&2
    hyprctl configerrors >&2
  fi
}

case "${1:-get}" in
  get)
    has_tp=$(hyprctl devices -j | jq '[.mice[].name | select(test("touchpad|trackpad"; "i"))] | length > 0')
    printf '{"repeat_rate":%s,"repeat_delay":%s,"numlock_by_default":%s,"sensitivity":%s,"accel_profile":%s,"natural_scroll":%s,"scroll_factor":%s,' \
      "$(opt repeat_rate)" "$(opt repeat_delay)" "$(opt numlock_by_default)" "$(opt sensitivity)" "$(opt accel_profile)" "$(opt natural_scroll)" "$(opt scroll_factor)"
    printf '"touchpad.natural_scroll":%s,"touchpad.scroll_factor":%s,"touchpad.tap_to_click":%s,"touchpad.disable_while_typing":%s,"touchpad":%s,"saved":%s}\n' \
      "$(opt touchpad.natural_scroll)" "$(opt touchpad.scroll_factor)" "$(opt touchpad.tap_to_click)" "$(opt touchpad.disable_while_typing)" "$has_tp" \
      "$(cat "$JSON" 2>/dev/null || echo '{}')"
    ;;
  set)
    key=${2:-}; val=${3:-}
    sp=$(spec "$key") || fail "unknown setting $key"
    read -r type a b <<<"$sp"
    case $type in
      int) [[ $val =~ ^[0-9]+$ ]] && (( val >= a && val <= b )) || fail "$key must be $a-$b"; jv=$val ;;
      float) [[ $val =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && awk -v v="$val" -v a="$a" -v b="$b" 'BEGIN{exit !(v>=a && v<=b)}' || fail "$key must be $a to $b"
             jv=$(awk -v v="$val" 'BEGIN{printf "%g", v}') ;;
      bool) [[ $val == true || $val == false ]] || fail "$key must be true or false"; jv=$val ;;
      enum) [[ " $a $b default " == *" $val "* ]] || fail "$key must be one of: $a $b default"; jv="\"$val\"" ;;
    esac
    mkdir -p "${JSON%/*}"
    cur=$(cat "$JSON" 2>/dev/null || echo '{}')
    if [[ $key == accel_profile && $val == default ]]; then
      jq --arg k "$key" 'del(.[$k])' <<<"$cur" >"$JSON.tmp"
    else
      jq --arg k "$key" --argjson v "$jv" '.[$k] = $v' <<<"$cur" >"$JSON.tmp"
    fi
    mv -f "$JSON.tmp" "$JSON"
    # live first (the file write makes Hyprland reload it anyway)
    luakey=${key#touchpad.}; [[ $luakey =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || luakey="[\"$luakey\"]"
    [[ $key == accel_profile && $val == default ]] && jv='""'
    if [[ $key == touchpad.* ]]; then lua="input = { touchpad = { $luakey = $jv } }"; else lua="input = { $luakey = $jv }"; fi
    hyprctl eval "hl.config({ $lua })" >/dev/null
    write_block
    ;;
  reset)
    rm -f "$JSON"
    write_block
    ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
