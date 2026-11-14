# AGENTS.md

Guidance for coding agents (Claude Code, pi, opencode, …) working in this repo.

## What this is

agentmux: tmux-side state and UI for coding agents running in tmux panes. Harnesses **push** their state through a small CLI; tmux stores it and displays it. Read [SPEC.md](SPEC.md) before changing behaviour.

## Ground rules

1. **The spec is the contract.** Any change to verbs, states, option names or guarantees must update `SPEC.md` in the same change. If something is undecided, add or update an entry in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) instead of quietly choosing. Never renumber questions.
2. **Push only.** Never add pane scraping, process sniffing or polling to infer agent state. UIs may read pane contents for *display* (e.g. previews), never to set state.
3. **Never break a harness.** `agentmux set`/`clear` must exit 0, print nothing on success and be a no-op outside tmux (see SPEC §3.3).
4. **Escape before storing.** Anything user- or agent-supplied that ends up in a tmux option must be escaped (`#` → `##`). See Q-007.
5. **Don't touch the user's real tmux server in tests.** Always use a separate socket: `tmux -L agentmux-test` (sandbox) or `tmux -L agentmux-ci` (automated tests). Never run bare `tmux kill-server`.
6. **Don't modify user config** (`~/.tmux.conf`, `~/dotfiles`, `~/.claude/settings.json`) from this repo's scripts. Adapters are snippets the user installs on purpose.

## Layout

| Path | What |
|---|---|
| `bin/agentmux` | Core CLI (bash + jq). `set`, `clear`, `list`, `refresh`, `version`. |
| `agentmux.tmux` | tmux entry point: `run-shell /path/agentmux.tmux`. Registers hooks and bindings. |
| `adapters/<harness>/` | Per-harness integration snippets. |
| `prototypes/NN-name/` | Throwaway UI experiments. Findings go in `prototypes/NOTES.md`. |
| `test/core.sh` | Automated tests for the core (isolated tmux server). |
| `test/sandbox.sh` | Interactive sandbox with fake agents, for trying UIs by hand. |
| `test/fake-agent.sh` | Simulated agent that pushes states. |

## Commands

```sh
test/core.sh                 # run automated tests (must pass before finishing a change)
test/sandbox.sh              # start sandbox, then attach from a terminal *outside* tmux:
tmux -L agentmux-test attach
test/sandbox.sh stop         # tear it down
```

## Style

- Bash: `set -euo pipefail` in tests and helpers. In `bin/agentmux` the user-facing verbs must never fail loudly (see rule 3).
- Requires tmux ≥ 3.3, jq, and fzf (UI prototypes only).
- Keep adapters tiny. If an adapter needs logic, it probably belongs in the core or the spec.
