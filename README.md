# agentmux

See every coding agent running in tmux (Claude Code, pi, opencode, …) in one place: which are **working**, which are **waiting for you**, which are **done**. Jump to them from one view.

> **Status:** early prototype. The spec is a draft ([SPEC.md](SPEC.md)), and open design points are in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md).

## How it works

```
harness hook ──▶ agentmux set waiting ──▶ tmux pane options (in the tmux server's memory)
                                           │
              status bar ◀── @agentmux_summary
              prefix a   ──▶ agents view (reads the same options)
```

- **Push only:** each harness reports its own state through a tiny adapter. agentmux never scrapes panes.
- **No daemon:** `agentmux` is a short-lived CLI. State lives in tmux and disappears with its pane.
- **The harness owns the state, you own "seen":** a `done` agent stays `done` until its harness pushes something else. Separately, agentmux remembers whether you've *seen* it (`@agentmux_seen_ts`): focusing the pane, or pressing `enter` on it in the picker, marks it seen. The status bar counts only **unseen** `done` agents; ones you've already looked at count as idle. Scrolling past an agent in the peek picker doesn't count as seeing it.

## Install

> Prefer to let your agent do it? The repo ships an **`install-agentmux`** skill ([`.agents/skills/install-agentmux/SKILL.md`](.agents/skills/install-agentmux/SKILL.md)) that walks through the steps below, asking before each config change. Claude Code, pi, opencode and Codex all pick it up when started in this repo (see [Skills](#skills)).

**Requirements:** tmux (only tested on 3.7c; needs popups, so ≥ 3.2), bash, `jq`. For the peek popup: a recent `fzf` (tested on 0.75) and `curl`. Developed on macOS; Linux should work but is untested.

### 1. Get it and put `agentmux` on your PATH

```sh
git clone https://github.com/hjcrimmins/agentmux.git ~/git_repos/agentmux
ln -s ~/git_repos/agentmux/bin/agentmux ~/.local/bin/agentmux   # any directory on your PATH
agentmux version                                                 # 0.2.0-draft
```

Harness hooks call `agentmux` by name, so it must be on the PATH that the harness sees.

### 2. Load it in tmux

Add to `~/.tmux.conf`, **after** your theme / TPM `run` line, so a theme that sets `status-right` doesn't overwrite the summary:

```tmux
# agentmux: options first (see Options below), then load
run-shell '~/git_repos/agentmux/agentmux.tmux'
set -ga status-right '#{@agentmux_summary}'     # or put #{@agentmux_summary} anywhere in your own status-right
```

Reload with `tmux source ~/.tmux.conf`. `prefix a` now opens the agents view (tmux's tree mode filtered to agent panes) and `prefix A` shows waiting agents only. The summary is empty until an agent needs you (`@agentmux_show_idle on` to always show something).

**Optional: the peek popup (prototype).** A live fzf list that shows each agent's pane underneath as you move. To use it on `prefix a` instead of the tree view:

```tmux
set -g @agentmux_key_tree ''                    # before run-shell: leave prefix a free
run-shell '~/git_repos/agentmux/agentmux.tmux'
bind a run-shell -b "~/git_repos/agentmux/prototypes/01-peek-popup/open.sh '#{client_name}' '#{client_width}' '#{client_height}'"
```

### 3. Connect a harness

Each harness needs a small adapter that pushes its state. Adapters so far:

| Harness | Adapter | Status |
|---|---|---|
| Claude Code | [`adapters/claude-code/`](adapters/claude-code/) | Working; verified in real sessions (Q-015) |
| pi, opencode, codex | — | Not written yet. Any harness with hooks can call `agentmux set` (see [SPEC.md §3](SPEC.md#3-harness-interface)) |

**Claude Code:** merge the adapter's hooks into `~/.claude/settings.json`. This keeps your other settings and hooks, and is safe to re-run (it replaces earlier agentmux hooks):

```sh
cd ~/git_repos/agentmux
f=~/.claude/settings.json; [ -f "$f" ] || echo '{}' > "$f"
cp "$f" "$f.bak.$(date +%s)"
jq --slurpfile a adapters/claude-code/hooks.json -f adapters/claude-code/install.jq "$f" > "$f.new" && mv "$f.new" "$f"
```

Restart running Claude sessions to pick it up. To try it without touching your settings: `claude --settings ~/git_repos/agentmux/adapters/claude-code/hooks.json`.

### 4. Check it works

In a tmux pane, start the harness and send it a prompt. In another pane:

```sh
agentmux list        # TSV: pane, state, reason, harness, location, message, age, path, seen
```

You should see the pane go `working` → `done`, and the status bar show `… 1 working`, then `✓ 1 done`. If nothing shows: is `agentmux` on the harness's PATH (`command -v agentmux` in that pane)? Was `agentmux.tmux` loaded (`tmux show -gv @agentmux_bin`)?

### Uninstall

```sh
jq -f ~/git_repos/agentmux/adapters/claude-code/uninstall.jq ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
rm ~/.local/bin/agentmux
```

Then remove the agentmux lines from `~/.tmux.conf` and restart tmux (or `tmux set-hook -gu 'pane-focus-in[90]'` etc. for the hooks listed in `agentmux.tmux`). agentmux keeps no files: all state is in tmux's memory.

**`focus-events`:** seen-tracking uses a `pane-focus-in` hook, which needs `focus-events on`. `agentmux.tmux` turns it on while `@agentmux_track_seen` is `on` (the default). Set it to `off` before `agentmux.tmux` runs to leave `focus-events` alone; then only `enter` in the picker marks agents seen.

### Options

Set these before the `run-shell` line (`set -g @agentmux_… value`). Most are read on every refresh; the key options when `agentmux.tmux` runs.

| Option | Default | |
|---|---|---|
| `@agentmux_track_seen` | `on` | Mark agents seen on pane focus (turns on `focus-events`) |
| `@agentmux_show_idle` | `off` | `on` adds `○ N idle` to the summary (otherwise it's empty when nothing needs you) |
| `@agentmux_style_waiting` | `fg=red,bold` | tmux style of each summary segment |
| `@agentmux_style_working` | `fg=yellow` | |
| `@agentmux_style_done` | `fg=green` | |
| `@agentmux_style_idle` | `fg=colour244` | |
| `@agentmux_key_tree` | `a` | `prefix` key for the agents tree view; empty disables |
| `@agentmux_key_waiting` | `A` | `prefix` key for the waiting-only view; empty disables |
| `@agentmux_key_force` | `off` | agentmux won't replace a key you've already bound (it shows a message and skips it) unless this is `on` |

Messages are stored escaped (`#` → `##`); show them in your own formats with `#{E:@agentmux_msg}`. `agentmux list` prints a TSV of agents (its last column, `seen`, is `1`/`0`). See [SPEC.md](SPEC.md) for the full interface.

## Try it (sandbox, doesn't touch your real tmux)

```sh
prototypes/01-peek-popup/try.sh     # isolated server with fake agents
tmux -L agentmux-test attach        # from a terminal outside tmux
```

| Key | Action |
|---|---|
| `prefix a` | Peek popup (prototype 01): `j`/`k` move and show the pane underneath, `/` filter, `s` sort, `enter` jump, `esc` back |
| `prefix t` | Built-in tree view of agent panes (fallback). Careful: tmux's own `x` key there kills the pane (after a confirm prompt) |
| `prefix A` | Tree view, waiting agents only |

The fake agents ask questions. Answer them by typing `1`/`2` in their pane.
Popup layout: side panel on wide terminals (≥ 140 columns), a strip across the top on narrower ones. Force it with `tmux -L agentmux-test set -g @agentmux_peek_layout side` (or `top`, `auto`); size with `@agentmux_peek_width` / `@agentmux_peek_height` (columns/rows or `N%`).
Stop it with `test/sandbox.sh stop`.

## Tests

```sh
test/core.sh
```

## Skills

Agent skills for working with this repo live in [`.agents/skills/`](.agents/skills/), in the [Agent Skills](https://agentskills.io) `SKILL.md` format, so one copy works across harnesses:

| Harness | Reads |
|---|---|
| pi | `.agents/skills/` (and `.pi/skills/`), once you trust the project (pi asks on first start here; `/trust` saves it) |
| opencode | `.agents/skills/` (and `.opencode/skills/`, `.claude/skills/`) |
| Codex | `.agents/skills/` |
| Claude Code | `.claude/skills/`; `.claude/skills/install-agentmux` is a symlink to the `.agents/skills/` copy |

Start your agent in the repo and ask it to install agentmux (or `/install-agentmux` in Claude Code, `/skill:install-agentmux` in pi). Verified to be discovered by Claude Code 2.1.325 and pi; opencode and Codex are by their docs, untested here.

To add a skill: create `.agents/skills/<name>/SKILL.md` (frontmatter `name` matching the folder, and `description`), then `ln -s ../../.agents/skills/<name> .claude/skills/<name>`.

## Layout

See [AGENTS.md](AGENTS.md#layout).
