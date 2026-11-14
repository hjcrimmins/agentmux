#!/usr/bin/env bash
# Prototype 01: peek popup.
# An fzf list in a side popup. Moving the cursor switches the *real* client to that
# agent's pane underneath the popup, so you see it live. enter = stay, esc = go back.
#
# Runs inside `display-popup`. There, $TMUX_PANE is the pane you opened it from and
# `tmux display -p` resolves to your client (verified on tmux 3.7, see NOTES.md).
#
#   peek.sh                 launch the picker (what the key binding runs)
#   peek.sh _rows           print fzf rows       (internal, called by fzf)
#   peek.sh _detail %ID     details pane         (internal)
#   peek.sh _peek  %ID      switch underneath    (internal)
#   peek.sh _sort           cycle sort order     (internal)
#   peek.sh _header         print header         (internal)
#   peek.sh _esc            esc handling         (internal)

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BIN=$(tmux show -gv @agentmux_bin 2>/dev/null)
[ -x "$BIN" ] || BIN="$(cd "$(dirname "$0")/../.." && pwd)/bin/agentmux"
TAB=$'\t'
dbg() { [ -n "${AGENTMUX_DEBUG:-}" ] && echo "$(date +%T) $*" >> "$AGENTMUX_DEBUG"; return 0; }

# ---------------------------------------------------------------- internal verbs
# Compact rows; the full message is in the details pane (_detail).
rows() {
  local sort; sort=$(cat "$PEEK_DIR/sort")
  "$BIN" list --sort "$sort" | awk -F "$TAB" -v sort="$sort" '
    BEGIN {   # column header (fzf --header-lines=1); ▾ marks the sorted column
      # pad first, then put ▾ in place of a space (awk pads by bytes; ▾ is 3 bytes)
      st = "STATE  "; wh = "WHERE    "; ag = " AGE"
      if (sort == "state") st = "STATE▾ "; else if (sort == "name") wh = "WHERE▾   "; else ag = "AGE▾"
      printf "-\t\033[1;90m  %s %-8s %s%s  %s\033[0m\n", st, "HARNESS", wh, ag, "MESSAGE"
    }
    function ago(s) { return s < 60 ? s "s" : s < 3600 ? int(s/60) "m" : int(s/3600) "h" }
    {
      st = $2
      if      (st == "waiting") { c = "\033[1;31m"; i = "●" }
      else if (st == "done")    { c = "\033[32m";   i = "✓" }
      else if (st == "working") { c = "\033[33m";   i = "…" }
      else                      { c = "\033[90m";   i = "○" }
      label = (st == "waiting" && $3 == "permission") ? "permit" : st
      loc = $5; sub(/\.0$/, "", loc)                       # api:0.0 -> api:0
      printf "%s\t%s%s %-7s\033[0m %-8s \033[36m%-9s\033[0m\033[90m%4s\033[0m  %s\n", \
             $1, c, i, label, substr($4, 1, 8), substr(loc, 1, 9), ago($7), $6
    }'
}

# Details for the selected agent: shown wrapped in the bottom pane of the popup.
detail() {
  local p=$1 row
  [[ $p =~ ^%[0-9]+$ ]] || return 0
  # \037 separator: with IFS=TAB, bash would collapse empty fields (e.g. no reason)
  row=$("$BIN" list | awk -F "$TAB" -v OFS=$'\037' -v p="$p" '$1==p { $1=$1; print }')
  [ -z "$row" ] && { echo "(agent gone, ctrl-r to refresh)"; return; }
  IFS=$'\037' read -r _ st reason harness loc msg age path <<<"$row"
  local where; where=$(tmux display -p -t "$p" '#{session_name} › #{window_name}' 2>/dev/null)
  printf '\033[1m%s\033[0m%s · %s · %s ago\n' "$st" "${reason:+ ($reason)}" "${harness:-?}" \
         "$( [ "$age" -lt 60 ] && echo "${age}s" || { [ "$age" -lt 3600 ] && echo "$((age/60))m" || echo "$((age/3600))h"; } )"
  printf '\033[36m%s\033[0m  \033[90m%s\033[0m\n' "$where" "${path/#$HOME/~}"
  [ -n "$msg" ] && printf '\n%s\n' "$msg"
  return 0
}

header() {
  printf '⏎ go  j/k  / find  s sort:%s  esc' "$(cat "$PEEK_DIR/sort")"
}

cycle_sort() {
  # read first: `case $(cat f) ... esac > f` truncates f before it is read
  local cur; cur=$(cat "$PEEK_DIR/sort")
  case $cur in state) cur=age ;; age) cur=name ;; *) cur=state ;; esac
  echo "$cur" > "$PEEK_DIR/sort"
  dbg "sort -> $cur"
}

# Switch the client to pane $1 (underneath the popup) and remember what we touched.
peek() {
  local p=$1
  [[ $p =~ ^%[0-9]+$ ]] || return 0
  echo "$p" >> "$PEEK_DIR/touched"
  dbg "peek $p"
  tmux switch-client -c "$PEEK_CLIENT" -t "$p" \; select-window -t "$p" \; select-pane -t "$p" 2>/dev/null
}

# esc: in filter mode go back to navigate mode, in navigate mode quit.
esc_action() {
  dbg "esc: FZF_PROMPT='${FZF_PROMPT:-<unset>}'"
  if [ "${FZF_PROMPT:-}" = "/ " ]; then
    echo "hide-input+disable-search+clear-query+change-prompt(  )+rebind(j,k,g,G,s,/,q)"
  else
    echo "abort"
  fi
}

# Put back every session's current window and every window's active pane that peeking
# changed, plus the client's session history, then land on pane $1.
restore_and_land() {
  local target=$1 cmds=() p win sess
  add() { [ ${#cmds[@]} -gt 0 ] && cmds+=(";"); cmds+=("$@"); }

  # 1. active pane of every touched window, current window of every touched session
  sort -u "$PEEK_DIR/touched" 2>/dev/null | while IFS= read -r p; do
    tmux display -p -t "$p" '#{window_id} #{session_id}' 2>/dev/null
  done | sort -u > "$PEEK_DIR/touched_ws"
  while read -r win sess; do
    p=$(awk -v w="$win" '$1==w{print $2}' "$PEEK_DIR/snap_panes")
    [ -n "$p" ] && add select-pane -t "$p"
  done < "$PEEK_DIR/touched_ws"
  while read -r win sess; do
    win=$(awk -v s="$sess" '$1==s{print $2}' "$PEEK_DIR/snap_sessions")
    [ -n "$win" ] && add select-window -t "$win"
  done < "$PEEK_DIR/touched_ws"

  # 2. client history: last-session = where you started, unless you stayed in that session
  local o_sess o_win t_sess
  o_sess=$(cat "$PEEK_DIR/origin_session"); o_win=$(cat "$PEEK_DIR/origin_window")
  t_sess=$(tmux display -p -t "$target" '#{session_id}' 2>/dev/null)
  local o_last; o_last=$(cat "$PEEK_DIR/origin_last")
  if [ "$t_sess" = "$o_sess" ] && [ -n "$o_last" ]; then add switch-client -c "$PEEK_CLIENT" -t "$o_last"; fi
  add switch-client -c "$PEEK_CLIENT" -t "$o_sess"
  add select-window -t "$o_win"

  # 3. land on the target
  if [ "$target" != "$(cat "$PEEK_DIR/origin_pane")" ]; then
    add switch-client -c "$PEEK_CLIENT" -t "$target"
    add select-window -t "$target"
  fi
  add select-pane -t "$target"
  dbg "restore -> $target: ${cmds[*]}"
  tmux "${cmds[@]}" 2>>"${AGENTMUX_DEBUG:-/dev/null}"
}

case ${1:-} in
  _rows)   rows; exit ;;
  _detail) detail "${2:-}"; exit ;;
  _peek)   peek "${2:-}"; exit ;;
  _sort)   cycle_sort; exit ;;
  _header) header; exit ;;
  _esc)    esc_action; exit ;;
esac

# ---------------------------------------------------------------- launcher
command -v fzf >/dev/null || { echo "fzf not found"; read -r -n1; exit 1; }

PEEK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-peek.XXXXXX")
trap 'rm -rf "$PEEK_DIR"' EXIT
export PEEK_DIR
PEEK_CLIENT=$(tmux display -p '#{client_name}'); export PEEK_CLIENT
# Don't trust $TMUX_PANE inside a popup: on tmux 3.7 it was not the pane the client was on
# (see NOTES.md). Ask for the client's session, then that session's active pane.
ORIG_SESSION_NAME=$(tmux list-clients -F '#{client_name}	#{client_session}' | awk -F '\t' -v c="$PEEK_CLIENT" '$1==c{print $2}')
ORIGIN=$(tmux display -p -t "=${ORIG_SESSION_NAME}:" '#{pane_id}' 2>/dev/null)
[ -n "$ORIGIN" ] || ORIGIN=${TMUX_PANE:-}
echo state > "$PEEK_DIR/sort"
echo "$ORIGIN" > "$PEEK_DIR/origin_pane"
dbg "launch: client=$PEEK_CLIENT origin=$ORIGIN TMUX_PANE=${TMUX_PANE:-unset}"
tmux display -p -t "$ORIGIN" '#{session_id}' > "$PEEK_DIR/origin_session"
tmux display -p -t "$ORIGIN" '#{window_id}'  > "$PEEK_DIR/origin_window"
tmux display -p '#{client_last_session}' | xargs -I{} tmux display -p -t '{}' '#{session_id}' > "$PEEK_DIR/origin_last" 2>/dev/null
tmux list-sessions -F '#{session_id} #{window_id}'                       > "$PEEK_DIR/snap_sessions"
tmux list-windows -a -F '#{window_id} #{pane_id}' > "$PEEK_DIR/snap_panes"
# list-windows' #{pane_id} is the window's active pane
: > "$PEEK_DIR/touched"

# side popup: details below the list; top strip (short and wide): details to the right
if [ "${AGENTMUX_PEEK_LAYOUT:-side}" = top ]; then PREVIEW_WIN='right,38%,wrap,border-left'
else PREVIEW_WIN='down,7,wrap,border-top'; fi

sel=$("$SELF" _rows | fzf --ansi --delimiter "$TAB" --with-nth 2.. --no-sort --header-lines 1 \
  --layout reverse --no-input --disabled --prompt '  ' --pointer '▶' --gutter ' ' \
  --info hidden --no-scrollbar --border none --header-first \
  --header "$("$SELF" _header)" \
  --preview "$SELF _detail {1}" --preview-window "$PREVIEW_WIN" \
  --bind "focus:execute-silent($SELF _peek {1})" \
  --bind "j:down,k:up,g:first,G:last,q:abort" \
  --bind "/:show-input+enable-search+change-prompt(/ )+unbind(j,k,g,G,s,/,q)" \
  --bind "esc:transform($SELF _esc)" \
  --bind "s:execute-silent($SELF _sort)+reload($SELF _rows)+transform-header($SELF _header)" \
  --bind "ctrl-r:reload($SELF _rows)" \
  | cut -f1)

if [ -n "$sel" ]; then
  restore_and_land "$sel"                 # enter: stay on the selected pane
else
  restore_and_land "$ORIGIN"              # esc/q: back to where you were
fi
