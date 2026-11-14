#!/usr/bin/env bash
# Opens the peek popup with a layout that suits the terminal.
# Bound as:  bind a run-shell -b "/path/open.sh '#{client_name}' '#{client_width}' '#{client_height}'"
#
# Layout (@agentmux_peek_layout = auto | side | top, default auto):
#   side  docked on the right, full height. Width: @agentmux_peek_width (cols or N%),
#         else 45% but >= 64 cols, always leaving 30 cols of the agent pane visible.
#   top   full-width strip across the top: agents' prompts sit at the bottom of their
#         panes, so they stay visible underneath. Height: @agentmux_peek_height (rows or
#         N%), else 40% but >= 12 rows.
#   auto  side if the terminal is >= @agentmux_peek_side_min columns (default 140), else top.
#
# Notes (tmux 3.7c): display-popup's -y is the popup's BOTTOM edge (-y 0 is clamped to the
# top row), and -x R tracked the current pane's right edge, not the terminal's.
DIR="$(cd "$(dirname "$0")" && pwd)"
client=$1; cw=${2:-0}; ch=${3:-0}
num() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }
num "$cw" || cw=$(tmux display -p -c "$client" '#{client_width}' 2>/dev/null || echo 160)
num "$ch" || ch=$(tmux display -p -c "$client" '#{client_height}' 2>/dev/null || echo 50)
opt() { tmux show -gv "$1" 2>/dev/null; }

# size <option-value> <total> <default-percent> <minimum>
size() {
  if [[ $1 =~ ^([0-9]+)%$ ]]; then echo $(($2 * ${BASH_REMATCH[1]} / 100))
  elif [[ $1 =~ ^[0-9]+$ ]]; then echo "$1"
  else local v=$(($2 * $3 / 100)); [ "$v" -lt "$4" ] && v=$4; echo "$v"; fi
}

layout=$(opt @agentmux_peek_layout); side_min=$(opt @agentmux_peek_side_min)
num "$side_min" || side_min=140
case $layout in
  side|top) ;;
  *) if [ "$cw" -ge "$side_min" ]; then layout=side; else layout=top; fi ;;
esac

if [ "$layout" = side ]; then
  w=$(size "$(opt @agentmux_peek_width)" "$cw" 45 64)
  max=$((cw - 30)); [ "$max" -lt 40 ] && max=$cw
  [ "$w" -gt "$max" ] && w=$max
  # explicit x: `-x R` behaved as the right edge of the current *pane* in a split window
  geom=(-x $((cw - w)) -y 0 -w "$w" -h 100%)
else
  h=$(size "$(opt @agentmux_peek_height)" "$ch" 40 12)
  max=$((ch - 8)); [ "$max" -lt 8 ] && max=$ch            # keep the prompt area visible
  [ "$h" -gt "$max" ] && h=$max
  geom=(-x 0 -y 0 -w 100% -h "$h")
fi

[ -n "${AGENTMUX_DEBUG:-}" ] && echo "$(date +%T) open: args=[$*] cw=$cw ch=$ch layout=$layout geom=${geom[*]}" >> "$AGENTMUX_DEBUG"
tmux display-popup -c "$client" -E "${geom[@]}" -b rounded -T ' agents ' \
  -e "AGENTMUX_PEEK_LAYOUT=$layout" "$DIR/peek.sh"
