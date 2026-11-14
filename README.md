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
