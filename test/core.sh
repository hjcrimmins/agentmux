#!/usr/bin/env bash
# Automated tests for bin/agentmux against an isolated tmux server (-L agentmux-ci).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/agentmux"
SOCK=agentmux-ci
T() { tmux -L "$SOCK" "$@"; }
unset TMUX_PANE   # never inherit the pane of whatever tmux this was started from

pass=0; fail=0
HANGS=$(mktemp -t agentmux-ci-hangs.XXXXXX)
WORK=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/agentmux-ci.XXXXXX")" && pwd)
CLIENT_PID=""
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1"; echo "     expected: $(printf %q "$2")"; echo "     actual:   $(printf %q "$3")"; fi
}
skip() { echo "skip $1"; }

T kill-server 2>/dev/null || true
T -f /dev/null new-session -d -s api -x 200 -y 50 'sleep 600'
T new-window -t api 'sleep 600'
T new-session -d -s ml 'sleep 600'
cleanup() {
  T kill-server 2>/dev/null || true
  [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true
  rm -rf "$HANGS" "$WORK"
}
trap cleanup EXIT

# Run agentmux with a time limit (macOS has no timeout(1)), so a hang becomes a FAIL
# instead of a frozen run. SIGALRM kills it with rc 142; record it for the final count.
AM() {
  local rc=0
  perl -e 'alarm shift; exec @ARGV' 5 "$BIN" "$@" || rc=$?
  if [ $rc -eq 142 ]; then echo "agentmux $*" >>"$HANGS"; echo "FAIL timeout: agentmux $*" >&2; fi
  return $rc
}
now_f() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { print (a < b) ? "yes" : "no" }'; }
wait_for() {  # wait_for <expected> <cmd...>: poll up to ~2s until cmd prints expected
  local want=$1 i; shift
  for i in 1 2 3 4 5 6 7 8 9 10; do [ "$("$@")" = "$want" ] && return 0; sleep 0.2; done
  return 0
}

# Make the CLI talk to the CI server as if running inside one of its panes.
export TMUX="$(T display -p '#{socket_path}'),0,0"
T set -g @agentmux_notify off

# --- install from a path with spaces, ' , # and $ (SPEC §4): every hook below runs this copy
INST="$WORK/dir with space 'q' #h \$x"
mkdir -p "$INST/bin"
cp "$ROOT/agentmux.tmux" "$INST/"; cp "$ROOT/bin/agentmux" "$INST/bin/"
install() { "$INST/agentmux.tmux"; }   # same as run-shell from the CI server ($TMUX points there)
install
check "@agentmux_bin is the odd path" "$INST/bin/agentmux" "$(T show -gv @agentmux_bin)"

P1=$(T display -p -t api:0 '#{pane_id}')
P2=$(T display -p -t api:1 '#{pane_id}')
P3=$(T display -p -t ml:0  '#{pane_id}')
opt() { T show -pv -t "$1" "$2" 2>/dev/null || true; }
lcol() { AM list | awk -F'\t' -v p="$1" -v c="$2" '$1==p{print $c}'; }   # lcol <pane> <column>
peeking() { T show -gv @agentmux_peeking 2>/dev/null || true; }
reset_agents() { local p; for p in $(T list-panes -a -F '#{pane_id}'); do AM clear --pane "$p"; done; }

# --- outside tmux: silent no-op, decided before argument validation (SPEC §3.3)
out=$(env -u TMUX -u TMUX_PANE perl -e 'alarm shift; exec @ARGV' 5 "$BIN" set waiting 2>&1; echo "rc=$?")
check "no-op outside tmux" "rc=0" "$out"
for args in "set bogus" "set" "set waiting --bogus" "set waiting --pane" "set waiting --pid abc" "clear --bogus" "clear --pane"; do
  # shellcheck disable=SC2086
  out=$(env -u TMUX -u TMUX_PANE AGENTMUX_STRICT=1 perl -e 'alarm shift; exec @ARGV' 5 "$BIN" $args 2>&1; echo "rc=$?")
  check "outside tmux, malformed [$args] silent even with STRICT" "rc=0" "$out"
done

# --- version / refresh / unknown verbs
check "version" "0.2.0-draft" "$(AM version)"
check "version extra arg: rc 2" "2" "$(AM version x >/dev/null 2>&1; echo $?)"
check "refresh extra arg: rc 2" "2" "$(AM refresh --bogus >/dev/null 2>&1; echo $?)"
check "refresh no args: rc 0" "0" "$(AM refresh >/dev/null 2>&1; echo $?)"

# --- basic set
TMUX_PANE=$P1 AM set working --harness claude --pid $$
check "state set"     "working" "$(opt "$P1" @agentmux_state)"
check "harness set"   "claude"  "$(opt "$P1" @agentmux_harness)"
check "reason empty unless waiting" "" "$(opt "$P1" @agentmux_reason)"

TMUX_PANE=$P2 AM set waiting --reason permission --msg 'Run `rm -rf build`?' --harness pi --pid $$
check "waiting reason" "permission" "$(opt "$P2" @agentmux_reason)"
AM set done --pane "$P3" --harness opencode
check "--pane works"   "done" "$(opt "$P3" @agentmux_state)"
check "default reason" "input" "$( AM set waiting --pane "$P3"; opt "$P3" @agentmux_reason )"
AM set done --pane "$P3" --harness opencode

# --- summary + counts
check "counts" "1 1 1 0" "$(T show -gv @agentmux_counts)"
check "summary has waiting" "yes" "$(T show -gv @agentmux_summary | grep -q '● 1 waiting' && echo yes || echo no)"
check "summary default waiting style" "yes" "$(T show -gv @agentmux_summary | grep -qF '#[fg=red,bold]● 1 waiting' && echo yes || echo no)"

# --- escaping (Q-007): a #() in a message must not execute or expand
TMUX_PANE=$P1 AM set waiting --msg 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' --pid $$
check "msg stored escaped" 'evil ##(touch /tmp/agentmux-pwned) ##{pane_id}' "$(opt "$P1" @agentmux_msg)"
check "msg displays literally via #{E:}" 'evil #(touch /tmp/agentmux-pwned) #{pane_id}' "$(T display -p -t "$P1" '#{E:@agentmux_msg}')"
check "no command executed" "absent" "$([ -e /tmp/agentmux-pwned ] && echo present || echo absent)"
check "choose-tree format uses #{E:@agentmux_msg}" "yes" "$(T list-keys -T prefix | awk '$4=="a"' | grep -qF '#{E:@agentmux_msg}' && echo yes || echo no)"

# --- msg from stdin, newlines flattened, truncation
printf 'line1\nline2' | TMUX_PANE=$P1 AM set waiting --msg - --pid $$
check "msg stdin + newline" "line1 line2" "$(opt "$P1" @agentmux_msg)"
long=$(printf 'x%.0s' $(seq 1 300))
TMUX_PANE=$P1 AM set waiting --msg "$long" --pid $$
check "msg truncated to 200" "200" "$(opt "$P1" @agentmux_msg | tr -d '\n' | wc -c | tr -d ' ')"

# --- ';' in messages: tmux treats an argv ending in ';' as a command separator, which
# used to truncate/alter the msg or break the chain midway (state set, no msg/pid/ts).
# Every message must round-trip exactly through `list`, with the whole chain applied.
for m in 'foo;' 'a\;' ';;' ';' 'a;b' 'a ; b' '\;' 'x\;' '#{pane_id};' 'end ;'; do
  T set -pu -t "$P1" @agentmux_ts
  err=$(TMUX_PANE=$P1 AM set waiting --msg "$m" --harness claude --pid $$ 2>&1; echo "rc=$?")
  check "semicolon msg [$m] rc, no stderr" "rc=0" "$err"
  check "semicolon msg [$m] round-trips" "$m" "$(lcol "$P1" 6)"
  check "semicolon msg [$m] chain complete" "waiting claude $$ yes" \
    "$(opt "$P1" @agentmux_state) $(opt "$P1" @agentmux_harness) $(opt "$P1" @agentmux_pid) $([ -n "$(opt "$P1" @agentmux_ts)" ] && echo yes || echo no)"
done
check "semicolon msg # still escaped" '##{pane_id};' "$(TMUX_PANE=$P1 AM set waiting --msg '#{pane_id};' --pid $$; opt "$P1" @agentmux_msg)"
printf 'from stdin;' | TMUX_PANE=$P1 AM set waiting --msg - --pid $$
check "semicolon msg via stdin" "from stdin;" "$(lcol "$P1" 6)"
check "summary refreshed after ';' msg" "2 0 1 0" "$(T show -gv @agentmux_counts)"

# --- invalid input never fails the caller (exit 0), but STRICT surfaces it
check "invalid state rc 0" "0" "$(TMUX_PANE=$P1 AM set bogus 2>/dev/null; echo $?)"
check "invalid state strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM set bogus 2>/dev/null; echo $?)"
check "missing state strict (in tmux)" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM set 2>/dev/null; echo $?)"
check "state unchanged after invalid" "waiting" "$(opt "$P1" @agentmux_state)"

# --- a value-taking flag given as the last argument must not hang (it used to spin
# forever on a failed `shift 2`). set/clear: error on stderr, rc 0 (2 with STRICT); list: rc 2.
for f in --reason --msg --harness --pid --pane; do
  out=$(TMUX_PANE=$P1 AM set waiting $f 2>&1; echo "rc=$?")
  check "set $f without value: rc 0" "yes rc=0" "$(echo "$out" | grep -q "needs a value" && echo yes || echo no) ${out##*$'\n'}"
  check "set $f without value: strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM set waiting $f 2>/dev/null; echo $?)"
done
check "state unchanged after missing value" "waiting" "$(TMUX_PANE=$P1 AM set done --msg 2>/dev/null; opt "$P1" @agentmux_state)"
out=$(env -u TMUX -u TMUX_PANE perl -e 'alarm shift; exec @ARGV' 5 "$BIN" set working --msg 2>/dev/null; echo "rc=$?")
check "set --msg without value outside tmux" "rc=0" "$out"
check "clear --pane without value: rc 0" "0" "$(TMUX_PANE=$P1 AM clear --pane 2>/dev/null; echo $?)"
check "clear --pane without value: strict" "2" "$(TMUX_PANE=$P1 AGENTMUX_STRICT=1 AM clear --pane 2>/dev/null; echo $?)"
check "state unchanged after clear --pane" "waiting" "$(opt "$P1" @agentmux_state)"
check "list --sort without value: rc 2" "2" "$(AM list --sort >/dev/null 2>&1; echo $?)"
check "list bad arg: rc 2" "2" "$(AM list --bogus >/dev/null 2>&1; echo $?)"

# --- list ordering: waiting first, then done, then working
TMUX_PANE=$P1 AM set working --harness claude --pid $$
check "list order by state" "$P2 $P3 $P1" "$(AM list | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
check "list unescapes msg" 'Run `rm -rf build`?' "$(lcol "$P2" 6)"
check "list has 9 columns" "9" "$(AM list | awk -F'\t' '{print NF}' | sort -u)"

# --- set replaces every field (Q-016); --reason only for waiting (Q-017)
TMUX_PANE=$P2 AM set waiting --reason permission --msg 'Bash(rm x)' --harness pi --pid $$
T set -p -t "$P2" @agentmux_seen_ts 12345
TMUX_PANE=$P2 AM set working
check "replace: state"   "working" "$(opt "$P2" @agentmux_state)"
check "replace: reason unset"  "" "$(opt "$P2" @agentmux_reason)"
check "replace: msg unset"     "" "$(opt "$P2" @agentmux_msg)"
check "replace: harness unset" "" "$(opt "$P2" @agentmux_harness)"
check "replace: pid unset"     "" "$(opt "$P2" @agentmux_pid)"
check "replace: ts set" "yes" "$([ -n "$(opt "$P2" @agentmux_ts)" ] && echo yes || echo no)"
check "set leaves seen_ts alone" "12345" "$(opt "$P2" @agentmux_seen_ts)"
TMUX_PANE=$P2 AM set done --reason permission --harness pi --pid $$
check "reason dropped for done" "" "$(opt "$P2" @agentmux_reason)"
check "invalid reason ignored outside waiting" "done" "$(TMUX_PANE=$P2 AGENTMUX_STRICT=1 AM set done --reason bogus; opt "$P2" @agentmux_state)"

# --- stale pid is dropped on refresh (Q-005)
sleep 0 & deadpid=$!; wait $deadpid
TMUX_PANE=$P1 AM set working --pid "$deadpid"
check "stale entry dropped" "" "$(opt "$P1" @agentmux_state)"

# --- clear
TMUX_PANE=$P2 AM clear
check "clear unsets"   "" "$(opt "$P2" @agentmux_state)"
check "clear unsets seen_ts" "" "$(opt "$P2" @agentmux_seen_ts)"
check "counts after clear" "0 0 1 0" "$(T show -gv @agentmux_counts)"

# --- seen (SPEC §5.1)
reset_agents
AM set done --pane "$P3" --harness opencode --pid $$
check "done is unseen at first" "0 0 1 0" "$(T show -gv @agentmux_counts)"
check "list seen column 0" "0" "$(lcol "$P3" 9)"
check "summary shows unseen done" "yes" "$(T show -gv @agentmux_summary | grep -qF '#[fg=green]✓ 1 done' && echo yes || echo no)"
AM seen --pane "$P3"
check "seen sets seen_ts" "yes" "$([ -n "$(opt "$P3" @agentmux_seen_ts)" ] && echo yes || echo no)"
check "seen done counts as idle" "0 0 0 1" "$(T show -gv @agentmux_counts)"
check "list seen column 1" "1" "$(lcol "$P3" 9)"
check "summary empty with only seen done" "" "$(T show -gv @agentmux_summary)"
check "seen leaves state alone" "done" "$(opt "$P3" @agentmux_state)"
ts=$(opt "$P3" @agentmux_ts)
T set -p -t "$P3" @agentmux_seen_ts "$((ts - 1))"; AM refresh
check "seen_ts older than ts: unseen" "0 0 1 0 0" "$(T show -gv @agentmux_counts) $(lcol "$P3" 9)"
T set -p -t "$P3" @agentmux_seen_ts "$ts"; AM refresh
check "seen_ts equal to ts: seen" "0 0 0 1 1" "$(T show -gv @agentmux_counts) $(lcol "$P3" 9)"
AM set waiting --pane "$P3" --pid $$
T set -p -t "$P3" @agentmux_seen_ts "$(( $(opt "$P3" @agentmux_ts) - 5 ))"
check "waiting unseen: still counted waiting" "1 0 0 0 0" "$(T show -gv @agentmux_counts) $(lcol "$P3" 9)"
AM seen --pane "$P3"
check "waiting seen: still counted waiting" "1 0 0 0 1" "$(T show -gv @agentmux_counts) $(lcol "$P3" 9)"
check "seen via TMUX_PANE" "0" "$(T set -pu -t "$P3" @agentmux_seen_ts; TMUX_PANE=$P3 AM seen; echo $?)"
check "seen via TMUX_PANE sets seen_ts" "yes" "$([ -n "$(opt "$P3" @agentmux_seen_ts)" ] && echo yes || echo no)"
check "seen bad arg: rc 2"         "2" "$(AM seen --bogus >/dev/null 2>&1; echo $?)"
check "seen --pane no value: rc 2" "2" "$(AM seen --pane >/dev/null 2>&1; echo $?)"
check "seen invalid pane: rc 2"    "2" "$(AM seen --pane xyz >/dev/null 2>&1; echo $?)"
check "seen missing pane: rc 2"    "2" "$(AM seen --pane %99999 >/dev/null 2>&1; echo $?)"
check "seen without any pane: rc 2" "2" "$(AM seen >/dev/null 2>&1; echo $?)"
AM clear --pane "$P3"

# --- list sort: waiting > unseen done > working > idle & seen done, oldest first in each rank
T new-session -d -s srt 'sleep 600'
for _ in 1 2 3 4 5; do T split-window -t srt 'sleep 600'; T select-layout -t srt tiled >/dev/null; done
S=($(T list-panes -t srt -F '#{pane_id}'))
now=$(date +%s)
AM set working --pane "${S[0]}" --pid $$                  # working, newer
AM set waiting --pane "${S[1]}" --pid $$                  # waiting
AM set done    --pane "${S[2]}" --pid $$                  # unseen done
AM set done    --pane "${S[3]}" --pid $$                  # seen done, oldest of rank 3
AM set idle    --pane "${S[4]}" --pid $$                  # idle, newer
AM set working --pane "${S[5]}" --pid $$                  # working, older
T set -p -t "${S[0]}" @agentmux_ts $((now - 10)) \; set -p -t "${S[5]}" @agentmux_ts $((now - 200)) \; \
  set -p -t "${S[3]}" @agentmux_ts $((now - 100)) \; set -p -t "${S[3]}" @agentmux_seen_ts $((now - 90)) \; \
  set -p -t "${S[4]}" @agentmux_ts $((now - 50))
check "list sort state with seen" "${S[1]} ${S[2]} ${S[5]} ${S[0]} ${S[3]} ${S[4]}" \
  "$(AM list | awk -F'\t' '$5 ~ /^srt:/ {print $1}' | tr '\n' ' ' | sed 's/ $//')"
check "counts with seen done as idle" "1 2 1 2" "$(T show -gv @agentmux_counts)"

# --- configuration: styles and show_idle (SPEC §5.2)
T set -g @agentmux_style_waiting 'fg=blue' \; set -g @agentmux_style_working 'fg=cyan,italics' \; set -g @agentmux_style_done 'fg=#00ff00'
AM refresh
sum=$(T show -gv @agentmux_summary)
check "style_waiting applied" "yes" "$(printf '%s' "$sum" | grep -qF '#[fg=blue]● 1 waiting#[default]' && echo yes || echo no)"
check "style_working applied" "yes" "$(printf '%s' "$sum" | grep -qF '#[fg=cyan,italics]… 2 working#[default]' && echo yes || echo no)"
check "style_done applied" "yes" "$(printf '%s' "$sum" | grep -qF '#[fg=#00ff00]✓ 1 done#[default]' && echo yes || echo no)"
check "idle hidden by default" "no" "$(printf '%s' "$sum" | grep -qF 'idle' && echo yes || echo no)"
T set -gu @agentmux_style_waiting \; set -gu @agentmux_style_working \; set -gu @agentmux_style_done
for p in "${S[@]}"; do [ "$p" = "${S[4]}" ] || AM clear --pane "$p"; done
check "only idle: summary empty" "" "$(T show -gv @agentmux_summary)"
T set -g @agentmux_show_idle on; AM refresh
check "show_idle on" '#[fg=colour244]○ 1 idle#[default]  ' "$(T show -gv @agentmux_summary)"
T set -g @agentmux_style_idle 'fg=white,dim'; AM refresh
check "style_idle applied" '#[fg=white,dim]○ 1 idle#[default]  ' "$(T show -gv @agentmux_summary)"
T set -gu @agentmux_show_idle \; set -gu @agentmux_style_idle
AM clear --pane "${S[4]}"

# --- refresh lock (Q-022): a holder that died must not hang the next call
reset_agents
T wait-for -L agentmux        # this client exits at once, leaving the lock held: stale
t0=$(now_f); AM set working --pane "$P1" --pid $$; t1=$(now_f)
check "stale lock: set completes in < 2s" "yes" "$(lt "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" 2)"
check "stale lock: set applied" "working 0 1 0 0" "$(opt "$P1" @agentmux_state) $(T show -gv @agentmux_counts)"
t0=$(now_f); AM refresh; t1=$(now_f)
check "lock released after stale recovery (fast refresh)" "yes" "$(lt "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" 0.7)"
check "lock free afterwards" "0" "$(perl -e 'alarm 2; exec @ARGV' tmux -L "$SOCK" wait-for -L agentmux; rc=$?; T wait-for -U agentmux; echo $rc)"
# concurrent sets: summary ends consistent, lock left free
for p in "$P1" "$P2" "$P3" "${S[0]}" "${S[1]}" "${S[2]}"; do AM set done --pane "$p" --pid $$ & done
wait
AM refresh
check "concurrent sets: counts consistent" "0 0 6 0" "$(T show -gv @agentmux_counts)"
check "concurrent sets: lock free" "0" "$(perl -e 'alarm 2; exec @ARGV' tmux -L "$SOCK" wait-for -L agentmux; rc=$?; T wait-for -U agentmux; echo $rc)"
reset_agents

# --- key bindings (Q-019)
keycmd() { T list-keys -T prefix 2>/dev/null | awk -v k="$1" '$4 == k { $1=$2=$3=$4=""; sub(/^ +/, ""); print }'; }
check "prefix a = tree" "yes" "$(keycmd a | grep -q '^choose-tree' && echo yes || echo no)"
check "prefix A = waiting tree" "yes" "$(keycmd A | grep -qF 'waiting' && echo yes || echo no)"
install
check "re-run keeps own binding" "yes" "$(keycmd a | grep -q '^choose-tree' && echo yes || echo no)"
T bind a display-message mine
install
check "collision: user binding kept" "display-message mine" "$(keycmd a)"
T set -g @agentmux_key_force on; install; T set -gu @agentmux_key_force
check "key_force replaces it" "yes" "$(keycmd a | grep -q '^choose-tree' && echo yes || echo no)"
T set -g @agentmux_key_tree t; install
check "key_tree t: default clock-mode left alone" "clock-mode" "$(keycmd t)"
check "key_tree t: old own binding on a dropped" "" "$(keycmd a)"
T unbind t; install
check "key_tree t once free" "yes" "$(keycmd t | grep -q '^choose-tree' && echo yes || echo no)"
T set -g @agentmux_key_waiting ''; install
check "empty key_waiting disables (own binding dropped)" "" "$(keycmd A)"
T set -gu @agentmux_key_tree \; set -gu @agentmux_key_waiting; install
check "defaults restored: a" "yes" "$(keycmd a | grep -q '^choose-tree' && echo yes || echo no)"
check "defaults restored: A" "yes" "$(keycmd A | grep -qF 'waiting' && echo yes || echo no)"
check "own t binding dropped when moved back" "" "$(keycmd t)"

# --- seen via focus (SPEC §5.1, Q-013, Q-018)
check "focus-events on" "on" "$(T show -gv focus-events)"
check "focus hook calls seen" "yes" "$(T show-hooks -g pane-focus-in 2>/dev/null | grep -qF 'seen --pane #{pane_id}' && echo yes || echo no)"
T new-session -d -s focus -x 120 -y 40 'sleep 600'
T split-window -t focus 'sleep 600'; T split-window -t focus 'sleep 600'
F=($(T list-panes -t focus -F '#{pane_id}'))
T select-pane -t "${F[2]}"                                 # plain pane active when the client attaches
# pane-focus-in only fires for a pane an attached client is looking at, so attach one on a pty.
if command -v script >/dev/null 2>&1; then
  if [ "$(uname)" = Darwin ]; then
    env -u TMUX script -q /dev/null tmux -L "$SOCK" attach -t focus </dev/null >/dev/null 2>&1 &
  else
    env -u TMUX script -qc "tmux -L $SOCK attach -t focus" /dev/null </dev/null >/dev/null 2>&1 &
  fi
  CLIENT_PID=$!; disown "$CLIENT_PID" 2>/dev/null || true
  wait_for 1 sh -c "tmux -L $SOCK list-clients | wc -l | tr -d ' '"
fi
if [ "$(T list-clients | wc -l | tr -d ' ')" -ge 1 ]; then
  CLIENT=$(T list-clients -F '#{client_name}' | head -n1)
  AM set done --pane "${F[0]}" --pid $$; AM set done --pane "${F[1]}" --pid $$
  seen_of() { opt "$1" @agentmux_seen_ts | sed 's/./x/;s/^x.*/set/'; }
  T select-pane -t "${F[0]}"
  wait_for set seen_of "${F[0]}"
  check "focus marks agent seen" "set" "$(seen_of "${F[0]}")"
  wait_for "0 0 1 1" T show -gv @agentmux_counts
  check "focus: counts updated" "0 0 1 1" "$(T show -gv @agentmux_counts)"
  check "focus: state untouched" "done" "$(opt "${F[0]}" @agentmux_state)"
  T set -g @agentmux_peeking "$CLIENT"
  T select-pane -t "${F[1]}"; sleep 0.6
  check "focus while peeking: not seen" "" "$(seen_of "${F[1]}")"
  T set -gu @agentmux_peeking
  T select-pane -t "${F[2]}"; sleep 0.6
  check "focus on plain pane: no seen_ts" "" "$(seen_of "${F[2]}")"
  T select-pane -t "${F[1]}"
  wait_for set seen_of "${F[1]}"
  check "focus after peeking ends: seen" "set" "$(seen_of "${F[1]}")"
  # track_seen off: no hook, focus doesn't mark seen
  T set -g @agentmux_track_seen off; install
  check "track_seen off: hook removed" "no" "$(T show-hooks -g pane-focus-in 2>/dev/null | grep -qF 'seen --pane' && echo yes || echo no)"
  T set -pu -t "${F[0]}" @agentmux_seen_ts
  T select-pane -t "${F[2]}"; T select-pane -t "${F[0]}"; sleep 0.6
  check "track_seen off: focus doesn't mark seen" "" "$(seen_of "${F[0]}")"
  T set -gu @agentmux_track_seen; install

  # --- peek picker (prototype 01): @agentmux_peeking while open, unset on exit; enter marks seen
  if command -v fzf >/dev/null 2>&1; then
    PEEK="$ROOT/prototypes/01-peek-popup/peek.sh"
    T set -pu -t "${F[0]}" @agentmux_seen_ts \; set -pu -t "${F[1]}" @agentmux_seen_ts
    AM set waiting --pane "${F[1]}" --pid $$              # top row of the picker
    T new-window -t focus -n peek "bash '$PEEK'"
    PP=$(T display -p -t focus:peek '#{pane_id}')
    wait_for "$CLIENT" peeking
    check "picker sets @agentmux_peeking" "$CLIENT" "$(peeking)"
    sleep 1
    check "peeking past an agent doesn't mark it seen" "" "$(seen_of "${F[1]}")"
    T send-keys -t "$PP" Enter
    wait_for "" peeking
    check "enter: @agentmux_peeking unset" "" "$(peeking)"
    wait_for set seen_of "${F[1]}"
    check "enter: landed agent marked seen" "set" "$(seen_of "${F[1]}")"
    T new-window -t focus -n peek2 "bash '$PEEK'"
    PP=$(T display -p -t focus:peek2 '#{pane_id}')
    wait_for "$CLIENT" peeking
    sleep 0.5
    T send-keys -t "$PP" Escape
    wait_for "" peeking
    check "esc: @agentmux_peeking unset" "" "$(peeking)"
    T new-window -t focus -n peek3 "bash '$PEEK'"
    PP=$(T display -p -t focus:peek3 '#{pane_id}')
    wait_for "$CLIENT" peeking
    T kill-pane -t "$PP"
    wait_for "" peeking
    check "killed picker: @agentmux_peeking unset (trap)" "" "$(peeking)"
  else
    skip "peek picker tests (fzf not found)"
  fi
else
  skip "focus tests (could not attach a client on a pty); checking the hook's condition directly"
  AM set done --pane "${F[0]}" --pid $$
  COND='#{&&:#{@agentmux_state},#{!:#{@agentmux_peeking}}}'
  check "hook condition: agent pane, not peeking" "1" "$(T display -p -t "${F[0]}" "$COND")"
  check "hook condition: plain pane" "0" "$(T display -p -t "${F[2]}" "$COND")"
  T set -g @agentmux_peeking c; check "hook condition: peeking" "0" "$(T display -p -t "${F[0]}" "$COND")"; T set -gu @agentmux_peeking
fi
reset_agents

# --- Claude Code adapter: Notification hook, run as Claude does (sh -c, JSON on stdin)
STUB="$WORK/stub"; mkdir -p "$STUB"
cat >"$STUB/agentmux" <<'EOF'
#!/bin/sh
printf '%s ' "$@" >"$REC.args"
cat >"$REC.stdin"
EOF
chmod +x "$STUB/agentmux"
NCMD=$(jq -r '.hooks.Notification[0].hooks[0].command' "$ROOT/adapters/claude-code/hooks.json")
notif() {  # notif <json>: prints "<args> | <stdin>" or "not called"
  export REC="$WORK/rec"; rm -f "$REC.args" "$REC.stdin"
  printf '%s' "$1" | PATH="$STUB:$PATH" "$ASH" -c "$NCMD" >/dev/null 2>&1 || true
  if [ -e "$REC.args" ]; then printf '%s| %s' "$(sed "s/--pid [0-9]* //" "$REC.args")" "$(tr '\n' '/' <"$REC.stdin")"
  else echo "not called"; fi
}
W='set waiting --reason'
for ASH in /bin/sh $(command -v dash || true); do
check "adapter [$ASH]: permission_prompt" "$W permission --msg - --harness claude | Claude needs your permission to use Bash/" \
  "$(notif '{"message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}')"
check "adapter [$ASH]: elicitation_dialog" "$W input --msg - --harness claude | Pick one/" \
  "$(notif '{"message":"Pick one","notification_type":"elicitation_dialog"}')"
check "adapter [$ASH]: elicitation_url_dialog" "$W input --msg - --harness claude | Open URL/" \
  "$(notif '{"message":"Open URL","notification_type":"elicitation_url_dialog"}')"
check "adapter [$ASH]: agent_needs_input" "$W input --msg - --harness claude | Waiting for input/" \
  "$(notif '{"message":"Waiting for input","notification_type":"agent_needs_input"}')"
for t in idle_prompt auth_success agent_completed quota_auto_resume_fired plugin_notification elicitation_complete; do
  check "adapter [$ASH]: $t ignored" "not called" "$(notif "{\"message\":\"Claude needs your permission\",\"notification_type\":\"$t\"}")"
done
check "adapter [$ASH]: no type, permission message" "$W permission --msg - --harness claude | Claude needs your permission to use Bash/" \
  "$(notif '{"message":"Claude needs your permission to use Bash"}')"
check "adapter [$ASH]: empty type, other message" "$W input --msg - --harness claude | Claude is waiting for your input/" \
  "$(notif '{"message":"Claude is waiting for your input","notification_type":""}')"
check "adapter [$ASH]: multi-line message, shell chars literal" "$W permission --msg - --harness claude | a \$(touch x) \"q\" 'y'/line2;/" \
  "$(notif '{"message":"a $(touch x) \"q\" '"'"'y'"'"'\nline2;","notification_type":"permission_prompt"}')"
check "adapter [$ASH]: no message" "$W input --msg - --harness claude | " "$(notif '{"notification_type":"agent_needs_input"}')"
check "adapter [$ASH]: invalid JSON ignored" "not called" "$(notif 'not json')"
done
# end to end with the real CLI (on PATH as `agentmux`), multi-line message flattened
mkdir -p "$WORK/realbin"; ln -sf "$BIN" "$WORK/realbin/agentmux"
printf '%s' '{"message":"Claude needs\nyour permission","notification_type":"permission_prompt"}' \
  | TMUX_PANE=$P1 PATH="$WORK/realbin:$PATH" perl -e 'alarm 5; exec @ARGV' /bin/sh -c "$NCMD"
check "adapter end to end" "waiting permission claude|Claude needs your permission" \
  "$(opt "$P1" @agentmux_state) $(opt "$P1" @agentmux_reason) $(opt "$P1" @agentmux_harness)|$(opt "$P1" @agentmux_msg)"
AM clear --pane "$P1"

# --- pane exit triggers refresh via hook (runs the copy installed at the odd path)
AM set done --pane "$P3" --harness opencode --pid $$
check "counts before kill" "0 0 1 0" "$(T show -gv @agentmux_counts)"
T kill-pane -t "$P3"
wait_for "0 0 0 0" T show -gv @agentmux_counts
check "kill-pane hook refreshes" "0 0 0 0" "$(T show -gv @agentmux_counts)"
check "summary empty" "" "$(T show -gv @agentmux_summary)"

# --- live UI reload: refresh POSTs @agentmux_ui_reload to @agentmux_ui_sock, only on change
reset_agents
UIDIR=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-ui.XXXXXX"); UISOCK="$UIDIR/ui.sock"; UILOG="$UIDIR/log"
python3 -c '
import socket, sys, os
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
while True:
    c, _ = s.accept(); d = b""
    while b"\r\n\r\n" not in d: d += c.recv(4096)
    h, b = d.split(b"\r\n\r\n", 1)
    n = int([l.split(b":")[1] for l in h.split(b"\r\n") if l.lower().startswith(b"content-length")][0])
    while len(b) < n: b += c.recv(4096)
    open(sys.argv[2], "ab").write(b + b"\n"); c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"); c.close()
' "$UISOCK" "$UILOG" & UIPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$UISOCK" ] && break; sleep 0.1; done
: > "$UILOG"
T set -g @agentmux_ui_sock "$UISOCK" \; set -g @agentmux_ui_reload 'reload(x)'
uicount() { grep -c . "$UILOG" 2>/dev/null || true; }
AM set working --pane "$P1" --harness claude
wait_for 1 uicount
check "ui: state change POSTs reload" "1" "$(uicount)"
check "ui: body is the registered action" "reload(x)" "$(head -1 "$UILOG")"
AM list >/dev/null; AM refresh; sleep 0.3
check "ui: list/refresh without change don't POST (no reload loop)" "1" "$(uicount)"
AM seen --pane "$P1"; wait_for 2 uicount
check "ui: seen (new seen_ts) POSTs reload" "2" "$(uicount)"
T set -gu @agentmux_ui_sock \; set -gu @agentmux_ui_reload
AM set done --pane "$P1" --harness claude; sleep 0.3
check "ui: no POST once unregistered" "2" "$(uicount)"
kill "$UIPID" 2>/dev/null || true; wait "$UIPID" 2>/dev/null || true; rm -rf "$UIDIR"
reset_agents

hangs=$(wc -l <"$HANGS" | tr -d ' ')
if [ "$hangs" -gt 0 ]; then fail=$((fail+hangs)); echo "FAIL $hangs agentmux call(s) timed out:"; sed 's/^/     /' "$HANGS"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
