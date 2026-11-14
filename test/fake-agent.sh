#!/usr/bin/env bash
# A pretend agent TUI that pushes its state through agentmux, for trying UIs without
# real agents. Usage: fake-agent.sh <harness-name>
# Cycle: idle -> working -> (waiting for permission | waiting for input | nothing) -> working -> done
# Answer its prompts by typing in the pane, like a real agent. If nobody answers, it moves on
# by itself after a while, so the sandbox always has a changing mix of states.

BIN="$(cd "$(dirname "$0")/.." && pwd)/bin/agentmux"
H=${1:-claude}
am() { "$BIN" set "$@" --harness "$H" --pid $$; }
trap '"$BIN" clear; exit' EXIT INT TERM

tasks=("Refactor the auth middleware" "Fix flaky test in test_api.py" "Add pagination to /users"
       "Write a migration for the orders table" "Profile the notebook data loader" "Update the README")
files=("src/auth.py" "tests/test_api.py" "src/routes/users.ts" "db/migrations" "notebooks/load.ipynb" "README.md")
cmds=("uv run pytest -x" "npm run build" "rm -rf .cache" "alembic upgrade head" "git push --force-with-lease")

c_dim=$'\033[90m'; c_y=$'\033[33m'; c_r=$'\033[1;31m'; c_g=$'\033[32m'; c_b=$'\033[1m'; c_0=$'\033[0m'

work() {  # work <seconds>
  am working
  local i n=$1
  for ((i = 0; i < n; i++)); do
    printf '%s  ⏺ %s %s%s\n' "$c_y" "$( ((RANDOM % 2)) && echo Reading || echo Editing )" \
           "${files[RANDOM % ${#files[@]}]}" "$c_0"
    sleep 1
  done
}

sleep $((RANDOM % 6))                      # stagger agents at startup
while :; do
  clear
  task=${tasks[RANDOM % ${#tasks[@]}]}
  printf '%s╭─ %s (fake) ──────────────────────────╮%s\n' "$c_b" "$H" "$c_0"
  printf '%s  task: %s%s\n\n' "$c_dim" "$task" "$c_0"
  work $((4 + RANDOM % 12))

  case $((RANDOM % 3)) in
    0) cmd=${cmds[RANDOM % ${#cmds[@]}]}
       am waiting --reason permission --msg "Bash($cmd)"
       printf '\n%s  Do you want to run `%s`?%s\n    1. Yes\n    2. No\n  > ' "$c_r" "$cmd" "$c_0"
       read -r -n1 -t $((40 + RANDOM % 50)) ans; echo
       [ "$ans" = 2 ] && printf '%s  Skipped.%s\n' "$c_dim" "$c_0"
       work $((2 + RANDOM % 5)) ;;
    1) am waiting --reason input --msg "Which approach for: $task?"
       printf '\n%s  Two options for %s:%s\n    1. Minimal change\n    2. Full rewrite\n  > ' "$c_r" "$task" "$c_0"
       read -r -n1 -t $((40 + RANDOM % 50)) ans; echo
       work $((2 + RANDOM % 5)) ;;
    *) ;;
  esac

  am done
  printf '\n%s  ✻ Done: %s%s\n%s  press enter for a new task%s ' "$c_g" "$task" "$c_0" "$c_dim" "$c_0"
  read -r -t $((25 + RANDOM % 40))
  am idle                                  # "user" read it; idle a bit before the next task
  printf '\n%s  (idle)%s\n' "$c_dim" "$c_0"
  sleep $((5 + RANDOM % 15))
done
