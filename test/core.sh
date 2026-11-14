#!/usr/bin/env bash
# Automated tests for bin/agentmux against an isolated tmux server (-L agentmux-ci).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agentmux"
SOCK=agentmux-ci
T() { tmux -L "$SOCK" "$@"; }

pass=0; fail=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1"; echo "     expected: $(printf %q "$2")"; echo "     actual:   $(printf %q "$3")"; fi
}

T kill-server 2>/dev/null || true
T -f /dev/null new-session -d -s api -x 200 -y 50 'sleep 600'
T new-window -t api 'sleep 600'
T new-session -d -s ml 'sleep 600'
trap 'T kill-server 2>/dev/null || true' EXIT

# Make the CLI talk to the CI server as if running inside one of its panes.
export TMUX="$(T display -p '#{socket_path}'),0,0"
T set -g @agentmux_notify off
T run-shell "$ROOT/agentmux.tmux"   # hooks + bindings registered on CI server
P1=$(T display -p -t api:0 '#{pane_id}')
P2=$(T display -p -t api:1 '#{pane_id}')
P3=$(T display -p -t ml:0  '#{pane_id}')
opt() { T show -pv -t "$1" "$2" 2>/dev/null || true; }

# --- outside tmux: silent no-op
out=$(env -u TMUX -u TMUX_PANE "$BIN" set waiting 2>&1; echo "rc=$?")
check "no-op outside tmux" "rc=0" "$out"

# --- basic set
TMUX_PANE=$P1 "$BIN" set working --harness claude --pid $$
check "state set"     "working" "$(opt "$P1" @agent_state)"
check "harness set"   "claude"  "$(opt "$P1" @agent_harness)"
check "reason empty unless waiting" "" "$(opt "$P1" @agent_reason)"

TMUX_PANE=$P2 "$BIN" set waiting --reason permission --msg 'Run `rm -rf build`?' --harness pi --pid $$
check "waiting reason" "permission" "$(opt "$P2" @agent_reason)"
"$BIN" set done --pane "$P3" --harness opencode
check "--pane works"   "done" "$(opt "$P3" @agent_state)"
check "default reason" "input" "$( "$BIN" set waiting --pane "$P3"; opt "$P3" @agent_reason )"
"$BIN" set done --pane "$P3" --harness opencode

# --- summary + counts
check "counts" "1 1 1 0" "$(T show -gv @agentmux_counts)"
check "summary has waiting" "yes" "$(T show -gv @agentmux_summary | grep -q '● 1 waiting' && echo yes || echo no)"

# --- escaping (Q-007): a #() in a message must not execute or expand
TMUX_PANE=$P1 "$BIN" set waiting --msg 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' --pid $$
check "msg stored escaped" 'evil ##(touch /tmp/agentmux-pwned) ##{pane_id}' "$(opt "$P1" @agent_msg)"
check "msg displays literally" 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' "$(T display -p -t "$P1" '#{@agent_msg}' | sed 's/##/#/g')"
check "no command executed" "absent" "$([ -e /tmp/agentmux-pwned ] && echo present || echo absent)"

# --- msg from stdin, newlines flattened, truncation
printf 'line1\nline2' | TMUX_PANE=$P1 "$BIN" set waiting --msg - --pid $$
check "msg stdin + newline" "line1 line2" "$(opt "$P1" @agent_msg)"
long=$(printf 'x%.0s' $(seq 1 300))
TMUX_PANE=$P1 "$BIN" set waiting --msg "$long" --pid $$
check "msg truncated to 200" "200" "$(opt "$P1" @agent_msg | tr -d '\n' | wc -c | tr -d ' ')"

# --- invalid input never fails the caller (exit 0), but STRICT surfaces it
check "invalid state rc 0" "0" "$(TMUX_PANE=$P1 "$BIN" set bogus 2>/dev/null; echo $?)"
check "invalid state strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 "$BIN" set bogus 2>/dev/null; echo $?)"
check "state unchanged after invalid" "waiting" "$(opt "$P1" @agent_state)"

# --- list ordering: waiting first, then done, then working
TMUX_PANE=$P1 "$BIN" set working --harness claude --pid $$
check "list order by state" "$P2 $P3 $P1" "$("$BIN" list | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check "list unescapes msg" 'Run `rm -rf build`?' "$("$BIN" list | awk -F'\t' -v p="$P2" '$1==p{print $6}')"

# --- stale pid is dropped on refresh (Q-005)
sleep 0 & deadpid=$!; wait $deadpid
TMUX_PANE=$P1 "$BIN" set working --pid "$deadpid"
check "stale entry dropped" "" "$(opt "$P1" @agent_state)"

# --- clear
TMUX_PANE=$P2 "$BIN" clear
check "clear unsets"   "" "$(opt "$P2" @agent_state)"
check "counts after clear" "0 0 1 0" "$(T show -gv @agentmux_counts)"

# --- pane exit triggers refresh via hook
T kill-pane -t "$P3"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(T show -gv @agentmux_counts)" = "0 0 0 0" ] && break; sleep 0.2; done
check "kill-pane hook refreshes" "0 0 0 0" "$(T show -gv @agentmux_counts)"
check "summary empty" "" "$(T show -gv @agentmux_summary)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
