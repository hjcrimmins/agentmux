#!/usr/bin/env bash
# tmux entry point. In tmux.conf:   run-shell /path/to/agentmux/agentmux.tmux
# Registers hooks and default bindings, then exits (SPEC §4). Talks to whichever
# server ran it ($TMUX), so it is safe to use against a sandbox server. Safe to re-run.

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/agentmux"

# The path ends up in hook strings, which tmux parses as a command, then run-shell expands
# as a format, then sh runs. Quote for each layer (innermost first) so spaces, ' and # work.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }   # sh: '...'
fmtq() { printf '%s' "${1//#/##}"; }                                    # format: # -> ##
tmuxq() {                                                                # tmux parser: "..."
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//\$/\\\$}
  printf '"%s"' "$s"
}
# `run-shell -b <BIN> <args>` as a tmux command string. $1 may contain formats (e.g. #{pane_id}).
run_bin() { printf 'run-shell -b %s' "$(tmuxq "$(fmtq "$(shq "$BIN")") $1")"; }

opt() { tmux show -gv "$1" 2>/dev/null; }    # prints nothing and fails if unset
optd() { local v; v=$(opt "$1") || v=$2; printf '%s' "$v"; }   # with default when unset
msg() { tmux display-message "agentmux: $*" 2>/dev/null || true; }

tmux set -g @agentmux_bin "$BIN"

# Keep the summary right when agent panes disappear without `clear`.
# Indexed hooks ([90]) so we don't clobber the user's own hooks.
for h in pane-exited after-kill-pane window-unlinked session-closed; do
  tmux set-hook -g "${h}[90]" "$(run_bin refresh)"
done

# SPEC §5.1 / Q-018: focusing an agent pane marks it seen, unless a picker is peeking.
# tmux never rewrites @agentmux_state (Q-003).
if [ "$(optd @agentmux_track_seen on)" = on ]; then
  tmux set -g focus-events on
  tmux set-hook -g 'pane-focus-in[90]' \
    "if -F '#{&&:#{@agentmux_state},#{!:#{@agentmux_peeking}}}' { $(run_bin 'seen --pane #{pane_id}') }"
else
  tmux set-hook -gu 'pane-focus-in[90]' 2>/dev/null
fi

# Fallback agents view: built-in tree mode, filtered to agent panes (live preview of the real pane).
FMT='#{?pane_format,#{?#{==:#{@agentmux_state},waiting},● waiting,#{?#{==:#{@agentmux_state},done},✓ done,#{?#{==:#{@agentmux_state},working},… working,○ idle}}}  #{@agentmux_harness}  #{E:@agentmux_msg},#{?window_format,#{window_name},#{session_name}}}'
KEY_TREE=$(optd @agentmux_key_tree a)
KEY_WAIT=$(optd @agentmux_key_waiting A)
FORCE=$(optd @agentmux_key_force off)

# Our bindings are recognised by the @agentmux_state filter in their command, so re-running
# never treats agentmux's own previous binding as a collision (Q-019).
MARK='@agentmux_state'
# (`list-keys -T prefix KEY` printed nothing on tmux 3.7c, so filter the whole table.)
binding() { tmux list-keys -T prefix 2>/dev/null | awk -v k="$1" '$4 == k'; }
ours() { binding "$1" | grep -qF -- "$MARK"; }
bound() { [ -n "$(binding "$1")" ]; }

# Drop our own bindings left on keys that are no longer configured (e.g. key option changed).
tmux list-keys -T prefix 2>/dev/null | grep -F -- "$MARK" | awk '{print $4}' | while IFS= read -r k; do
  [ "$k" = "$KEY_TREE" ] || [ "$k" = "$KEY_WAIT" ] || tmux unbind -T prefix -- "$k" 2>/dev/null
done

bind_key() {  # bind_key <key> <filter>
  local key=$1 filter=$2
  [ -n "$key" ] || return 0                                   # empty disables
  if bound "$key" && ! ours "$key" && [ "$FORCE" != on ]; then
    msg "prefix $key is already bound, not binding it (set @agentmux_key_force on to override)"
    return 0
  fi
  tmux bind -T prefix -- "$key" choose-tree -Z -f "$filter" -F "$FMT"
}
bind_key "$KEY_TREE" '#{@agentmux_state}'
bind_key "$KEY_WAIT" '#{==:#{@agentmux_state},waiting}'

"$BIN" refresh
