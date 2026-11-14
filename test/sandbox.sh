#!/usr/bin/env bash
# Interactive sandbox: an isolated tmux server (-L agentmux-test) with fake agents in
# several sessions, mixed with plain shells (like your editor / jupyter panes).
#
#   test/sandbox.sh [start]   start (restarts if already running)
#   test/sandbox.sh stop
#
# Then attach from a terminal that is NOT inside tmux:   tmux -L agentmux-test attach
# (Nested inside your real tmux, prefix keys go to the outer one.)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCK=agentmux-test
T() { tmux -L "$SOCK" "$@"; }
FAKE="$ROOT/test/fake-agent.sh"
SH=${SHELL:-/bin/zsh}

if [ "${1:-start}" = stop ]; then T kill-server 2>/dev/null || true; echo "sandbox stopped"; exit 0; fi

T kill-server 2>/dev/null || true
CONF=$(mktemp "${TMPDIR:-/tmp}/agentmux-sandbox.XXXXXX")
cat > "$CONF" <<EOF
set -g mode-keys vi
set -g mouse on
set -g base-index 0
set -g status-interval 5
set -g status-style 'bg=#1a1b26,fg=#a9b1d6'
set -g status-left '#[bold] #S #[default] '
set -g status-left-length 30
set -g status-right '#{@agentmux_summary}#[fg=#565f89]sandbox %H:%M '
set -g status-right-length 120
set -g @agentmux_notify on
bind -r h select-pane -L
bind -r j select-pane -D
bind -r k select-pane -U
bind -r l select-pane -R
run-shell '$ROOT/agentmux.tmux'
EOF

T -f "$CONF" new-session -d -s api -n claude -x 220 -y 55 "$FAKE claude"
T split-window -t api:claude -h -l 40% "$SH"                       # a plain shell beside it
T new-window   -t api -n tests "$SH"
T new-window   -t api -n pi    "$FAKE pi"
T new-session  -d -s ml -n notebook "$SH"                           # stands in for jupyter
T new-window   -t ml -n agent "$FAKE pi"
T new-session  -d -s web -n claude "$FAKE claude"
T new-session  -d -s infra -n opencode "$FAKE opencode"
T new-window   -t infra -n codex "$FAKE codex"
T select-window -t api:claude; T select-pane -t api:claude.0
rm -f "$CONF"

echo "sandbox running: 4 sessions, 6 fake agents, 3 plain shells"
echo "attach (from a terminal outside tmux):  tmux -L $SOCK attach"
