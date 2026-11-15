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

## Install (your own tmux)

```tmux
# ~/.tmux.conf
run-shell '/path/to/agentmux/agentmux.tmux'
set -g status-right '#{@agentmux_summary}%H:%M'   # put the summary where you want it
```

agentmux doesn't touch your `status-right`: add `#{@agentmux_summary}` to it yourself (or to your theme's equivalent). For a harness, install its adapter, e.g. merge `adapters/claude-code/hooks.json` into `~/.claude/settings.json`, with `bin/agentmux` on your `PATH`.

**`focus-events`:** seen-tracking uses a `pane-focus-in` hook, which needs `focus-events on`. `agentmux.tmux` turns it on while `@agentmux_track_seen` is `on` (the default). Set it to `off` before `agentmux.tmux` runs to leave `focus-events` alone; then only `enter` in the picker marks agents seen.

### Options

Set these before the `run-shell` line (`set -g @agentmux_… value`). Most are read on every refresh; the key options when `agentmux.tmux` runs.

| Option | Default | |
|---|---|---|
| `@agentmux_notify` | `on` | `off` disables desktop notifications |
| `@agentmux_sound` | `Glass` | macOS notification sound; empty (`''`) for silent |
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

## Layout

See [AGENTS.md](AGENTS.md#layout).
