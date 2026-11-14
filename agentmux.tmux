#!/usr/bin/env bash
# tmux entry point. In tmux.conf:   run-shell /path/to/agentmux/agentmux.tmux
# Registers hooks and default bindings, then exits (SPEC §4). Talks to whichever
# server ran it ($TMUX), so it is safe to use against a sandbox server.

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin/agentmux"

tmux set -g @agentmux_bin "$BIN"
tmux set -g focus-events on

# Keep the summary right when agent panes disappear without `clear`.
# Indexed hooks ([90]) so we don't clobber the user's own hooks.
for h in pane-exited after-kill-pane window-unlinked session-closed; do
  tmux set-hook -g "${h}[90]" "run-shell -b '$BIN refresh'"
done

# Q-003 (leaning a): focusing a "done" pane acknowledges it.
tmux set-hook -g 'pane-focus-in[90]' \
  "if -F '#{==:#{@agent_state},done}' \"set -p @agent_state idle ; run-shell -b '$BIN refresh'\""

# Fallback agents view: built-in tree mode, filtered to agent panes (live preview of the real pane).
FMT='#{?pane_format,#{?#{==:#{@agent_state},waiting},● waiting,#{?#{==:#{@agent_state},done},✓ done,#{?#{==:#{@agent_state},working},… working,○ idle}}}  #{@agent_harness}  #{@agent_msg},#{?window_format,#{window_name},#{session_name}}}'
KEY_TREE=$(tmux show -gv @agentmux_key_tree 2>/dev/null); KEY_TREE=${KEY_TREE:-a}
KEY_WAIT=$(tmux show -gv @agentmux_key_waiting 2>/dev/null); KEY_WAIT=${KEY_WAIT:-A}
tmux bind "$KEY_TREE" choose-tree -Z -f '#{@agent_state}' -F "$FMT"
tmux bind "$KEY_WAIT" choose-tree -Z -f '#{==:#{@agent_state},waiting}' -F "$FMT"

"$BIN" refresh
