#!/usr/bin/env bash
# Automated tests for bin/agentmux against an isolated tmux server (-L agentmux-ci).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agentmux"
SOCK=agentmux-ci
T() { tmux -L "$SOCK" "$@"; }

pass=0; fail=0
HANGS=$(mktemp -t agentmux-ci-hangs.XXXXXX)
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1"; echo "     expected: $(printf %q "$2")"; echo "     actual:   $(printf %q "$3")"; fi
}

T kill-server 2>/dev/null || true
T -f /dev/null new-session -d -s api -x 200 -y 50 'sleep 600'
T new-window -t api 'sleep 600'
T new-session -d -s ml 'sleep 600'
trap 'T kill-server 2>/dev/null || true; rm -f "$HANGS"' EXIT

# Run agentmux with a time limit (macOS has no timeout(1)), so a hang becomes a FAIL
# instead of a frozen run. SIGALRM kills it with rc 142; record it for the final count.
AM() {
  local rc=0
  perl -e 'alarm shift; exec @ARGV' 5 "$BIN" "$@" || rc=$?
  if [ $rc -eq 142 ]; then echo "agentmux $*" >>"$HANGS"; echo "FAIL timeout: agentmux $*" >&2; fi
  return $rc
}

# Make the CLI talk to the CI server as if running inside one of its panes.
export TMUX="$(T display -p '#{socket_path}'),0,0"
T set -g @agentmux_notify off
T run-shell "$ROOT/agentmux.tmux"   # hooks + bindings registered on CI server
P1=$(T display -p -t api:0 '#{pane_id}')
P2=$(T display -p -t api:1 '#{pane_id}')
P3=$(T display -p -t ml:0  '#{pane_id}')
opt() { T show -pv -t "$1" "$2" 2>/dev/null || true; }

# --- outside tmux: silent no-op
out=$(env -u TMUX -u TMUX_PANE perl -e 'alarm shift; exec @ARGV' 5 "$BIN" set waiting 2>&1; echo "rc=$?")
check "no-op outside tmux" "rc=0" "$out"

# --- basic set
TMUX_PANE=$P1 AM set working --harness claude --pid $$
check "state set"     "working" "$(opt "$P1" @agent_state)"
check "harness set"   "claude"  "$(opt "$P1" @agent_harness)"
check "reason empty unless waiting" "" "$(opt "$P1" @agent_reason)"

TMUX_PANE=$P2 AM set waiting --reason permission --msg 'Run `rm -rf build`?' --harness pi --pid $$
check "waiting reason" "permission" "$(opt "$P2" @agent_reason)"
AM set done --pane "$P3" --harness opencode
check "--pane works"   "done" "$(opt "$P3" @agent_state)"
check "default reason" "input" "$( AM set waiting --pane "$P3"; opt "$P3" @agent_reason )"
AM set done --pane "$P3" --harness opencode

# --- summary + counts
check "counts" "1 1 1 0" "$(T show -gv @agentmux_counts)"
check "summary has waiting" "yes" "$(T show -gv @agentmux_summary | grep -q '● 1 waiting' && echo yes || echo no)"

# --- escaping (Q-007): a #() in a message must not execute or expand
TMUX_PANE=$P1 AM set waiting --msg 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' --pid $$
check "msg stored escaped" 'evil ##(touch /tmp/agentmux-pwned) ##{pane_id}' "$(opt "$P1" @agent_msg)"
check "msg displays literally" 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' "$(T display -p -t "$P1" '#{@agent_msg}' | sed 's/##/#/g')"
check "no command executed" "absent" "$([ -e /tmp/agentmux-pwned ] && echo present || echo absent)"

# --- msg from stdin, newlines flattened, truncation
printf 'line1\nline2' | TMUX_PANE=$P1 AM set waiting --msg - --pid $$
check "msg stdin + newline" "line1 line2" "$(opt "$P1" @agent_msg)"
long=$(printf 'x%.0s' $(seq 1 300))
TMUX_PANE=$P1 AM set waiting --msg "$long" --pid $$
check "msg truncated to 200" "200" "$(opt "$P1" @agent_msg | tr -d '\n' | wc -c | tr -d ' ')"

# --- ';' in messages: tmux treats an argv ending in ';' as a command separator, which
# used to truncate/alter the msg or break the chain midway (state set, no msg/pid/ts).
# Every message must round-trip exactly through `list`, with the whole chain applied.
for m in 'foo;' 'a\;' ';;' ';' 'a;b' 'a ; b' '\;' 'x\;' '#{pane_id};' 'end ;'; do
  T set -pu -t "$P1" @agent_ts
  err=$(TMUX_PANE=$P1 AM set waiting --msg "$m" --harness claude --pid $$ 2>&1; echo "rc=$?")
  check "semicolon msg [$m] rc, no stderr" "rc=0" "$err"
  check "semicolon msg [$m] round-trips" "$m" "$(AM list | awk -F'\t' -v p="$P1" '$1==p{print $6}')"
  check "semicolon msg [$m] chain complete" "waiting claude $$ yes" \
    "$(opt "$P1" @agent_state) $(opt "$P1" @agent_harness) $(opt "$P1" @agent_pid) $([ -n "$(opt "$P1" @agent_ts)" ] && echo yes || echo no)"
done
check "semicolon msg # still escaped" '##{pane_id};' "$(TMUX_PANE=$P1 AM set waiting --msg '#{pane_id};' --pid $$; opt "$P1" @agent_msg)"
printf 'from stdin;' | TMUX_PANE=$P1 AM set waiting --msg - --pid $$
check "semicolon msg via stdin" "from stdin;" "$(AM list | awk -F'\t' -v p="$P1" '$1==p{print $6}')"
check "summary refreshed after ';' msg" "2 0 1 0" "$(T show -gv @agentmux_counts)"

# --- invalid input never fails the caller (exit 0), but STRICT surfaces it
check "invalid state rc 0" "0" "$(TMUX_PANE=$P1 AM set bogus 2>/dev/null; echo $?)"
check "invalid state strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM set bogus 2>/dev/null; echo $?)"
check "state unchanged after invalid" "waiting" "$(opt "$P1" @agent_state)"

# --- a value-taking flag given as the last argument must not hang (it used to spin
# forever on a failed `shift 2`). set/clear: error on stderr, rc 0 (2 with STRICT); list: rc 2.
for f in --reason --msg --harness --pid --pane; do
  out=$(TMUX_PANE=$P1 AM set waiting $f 2>&1; echo "rc=$?")
  check "set $f without value: rc 0" "yes rc=0" "$(echo "$out" | grep -q "needs a value" && echo yes || echo no) ${out##*$'\n'}"
  check "set $f without value: strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM set waiting $f 2>/dev/null; echo $?)"
done
check "state unchanged after missing value" "waiting" "$(TMUX_PANE=$P1 AM set done --msg 2>/dev/null; opt "$P1" @agent_state)"
out=$(env -u TMUX -u TMUX_PANE perl -e 'alarm shift; exec @ARGV' 5 "$BIN" set working --msg 2>/dev/null; echo "rc=$?")
check "set --msg without value outside tmux" "rc=0" "$out"
check "clear --pane without value: rc 0" "0" "$(AM clear --pane 2>/dev/null; echo $?)"
check "clear --pane without value: strict" "2" "$(AGENTMUX_STRICT=1 AM clear --pane 2>/dev/null; echo $?)"
check "state unchanged after clear --pane" "waiting" "$(opt "$P1" @agent_state)"
check "list --sort without value: rc 2" "2" "$(AM list --sort >/dev/null 2>&1; echo $?)"

# --- list ordering: waiting first, then done, then working
TMUX_PANE=$P1 AM set working --harness claude --pid $$
check "list order by state" "$P2 $P3 $P1" "$(AM list | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check "list unescapes msg" 'Run `rm -rf build`?' "$(AM list | awk -F'\t' -v p="$P2" '$1==p{print $6}')"

# --- stale pid is dropped on refresh (Q-005)
sleep 0 & deadpid=$!; wait $deadpid
TMUX_PANE=$P1 AM set working --pid "$deadpid"
check "stale entry dropped" "" "$(opt "$P1" @agent_state)"

# --- clear
TMUX_PANE=$P2 AM clear
check "clear unsets"   "" "$(opt "$P2" @agent_state)"
check "counts after clear" "0 0 1 0" "$(T show -gv @agentmux_counts)"

# --- pane exit triggers refresh via hook
T kill-pane -t "$P3"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(T show -gv @agentmux_counts)" = "0 0 0 0" ] && break; sleep 0.2; done
check "kill-pane hook refreshes" "0 0 0 0" "$(T show -gv @agentmux_counts)"
check "summary empty" "" "$(T show -gv @agentmux_summary)"

hangs=$(wc -l <"$HANGS" | tr -d ' ')
if [ "$hangs" -gt 0 ]; then fail=$((fail+hangs)); echo "FAIL $hangs agentmux call(s) timed out:"; sed 's/^/     /' "$HANGS"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
