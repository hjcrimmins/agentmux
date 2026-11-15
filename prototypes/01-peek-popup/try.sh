#!/usr/bin/env bash
# Start the sandbox with prototype 01 bound to `prefix a`.
#   prefix a   peek popup (this prototype)
#   prefix t   built-in tree-mode fallback, for comparison
#   prefix A   tree mode, waiting agents only
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
"$ROOT/test/sandbox.sh"
T() { tmux -L agentmux-test "$@"; }

# Move the tree fallback to `t` (tmux's clock-mode by default, so free it first; agentmux
# leaves already-bound keys alone, Q-019), then take over `a`. Re-running agentmux.tmux
# drops its own old binding on `a`.
T set -g @agentmux_key_tree t
T unbind t
T run-shell "$ROOT/agentmux.tmux"
T bind a run-shell -b "$DIR/open.sh '#{client_name}' '#{client_width}' '#{client_height}'"

echo
echo "prototype 01 bound: prefix a = peek popup, prefix t = tree fallback, prefix A = waiting only"
