# agentmux spec

**Version:** 0.1.0-draft
**Status:** DRAFT. Expect breaking changes. Unresolved points are tracked in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) and referenced inline as `[Q-NNN]`.

## 1. Purpose

agentmux gives tmux a single, harness-independent view of the coding agents running in its panes: which are working, which need you, which are done. You can jump to any of them from one place.

## 2. Responsibilities

There are two parts with one boundary between them.

| Side | Owns | Does not do |
|---|---|---|
| **Harness adapter** (Claude Code hook, pi extension, opencode plugin, …) | Deciding *when* the agent's state changes and **pushing** it via `agentmux set` / `agentmux clear` | Any tmux knowledge, UI or notification policy |
| **agentmux (tmux side)** | Storing state, the status-bar summary, notifications, the agents view, jumping | Detecting or guessing state. It never scrapes panes or watches processes to infer state. |

**Push only.** If a harness doesn't push, its pane isn't an agent as far as agentmux is concerned.

## 3. Harness interface

Adapters use exactly two verbs:

```
agentmux set <state> [--reason REASON] [--msg TEXT | --msg -] [--harness NAME] [--pid PID] [--pane PANE_ID]
agentmux clear [--pane PANE_ID]
```

### 3.1 States

| State | Meaning |
|---|---|
| `idle` | Agent is running and waiting for a new task. Nothing is pending. |
| `working` | Agent is busy (thinking, running tools). |
| `waiting` | Agent is blocked on the user. `--reason` is `permission` or `input` (default `input`). [Q-002] |
| `done` | Agent finished a turn the user hasn't looked at yet. [Q-003] |

`clear` means the pane is no longer an agent (the session ended).

### 3.2 Arguments

- `--msg TEXT`: short human-readable detail (e.g. the permission request). `--msg -` reads it from stdin. agentmux normalises it: newlines become spaces, it's truncated to 200 characters, and tmux format characters are escaped. [Q-007]
- `--harness NAME`: a short lowercase identifier: `claude`, `pi`, `opencode`, `codex`, …
- `--pid PID`: PID of the long-lived harness process. agentmux uses it only to drop stale entries if the harness dies without calling `clear`. [Q-005] Adapters **should** pass it.
- `--pane PANE_ID`: target pane. Defaults to `$TMUX_PANE`. [Q-006]

### 3.3 Guarantees to adapters

- Calls always exit `0` and print nothing on success. Errors go to stderr, and the exit code is still `0` unless `AGENTMUX_STRICT=1`, so a hook can never break or block a harness.
- If not inside tmux (no `--pane` and no `$TMUX_PANE`), calls are silent no-ops.
- Calls are fast (a single tmux round trip plus summary recompute) and need no daemon.

## 4. Runtime model

- **No daemon.** `agentmux` is a short-lived CLI. The tmux server is the only long-running process.
- `agentmux.tmux` runs once when tmux loads its config. It registers key bindings and tmux hooks, then exits.
- A harness event runs `agentmux set|clear`. That writes the pane options, recomputes the summary, refreshes status lines and possibly sends a notification.
- When a pane exits or is killed, tmux hooks run `agentmux refresh`.
- UIs only read state.

## 5. State storage

All state lives in the tmux server's memory as user options. There are no files. [Q-008]

**Per pane** (removed automatically when the pane closes):

| Option | Value |
|---|---|
| `@agent_state` | `idle` \| `working` \| `waiting` \| `done` |
| `@agent_reason` | `permission` \| `input` (only meaningful for `waiting`) |
| `@agent_harness` | harness name |
| `@agent_msg` | normalised, escaped message |
| `@agent_pid` | harness PID, or empty |
| `@agent_ts` | Unix time of the last state change |

**Global:**

| Option | Value |
|---|---|
| `@agentmux_summary` | Ready-to-display status-bar text (with tmux style directives). Empty when there are no agents. |
| `@agentmux_counts` | `waiting working done idle` as four space-separated integers, for custom status formats |
| `@agentmux_notify` | `on` (default) \| `off` |
| `@agentmux_bin` | Absolute path to the `agentmux` executable (set by `agentmux.tmux`) |

Writes from a single `set` are sent as one chained tmux command, so they are applied atomically.

## 6. Notifications [Q-004]

On a transition into `waiting` or `done`, agentmux sends a desktop notification, unless:
- `@agentmux_notify` is `off`, or
- the pane is currently visible: it's the active pane of the active window of a session with an attached client.

On macOS this uses `osascript`.

## 7. Read interface (for UIs and scripts)

```
agentmux list [--sort state|name|age]
agentmux refresh
agentmux version
```

Unlike `set`/`clear`, these exit non-zero on bad arguments. Outside tmux they talk to the default tmux server, like any tmux client. [Q-014]

- `list` prints one agent pane per line, with messages unescaped for display. TSV columns: `pane_id state reason harness location msg age_seconds path`, where `location` is `session:window_index.pane_index`. Default sort is `state` (waiting > done > working > idle, then oldest first).
- `refresh` drops stale entries (dead `@agent_pid`) and recomputes the summary.

## 8. User interface

Still being prototyped (see `prototypes/` and [Q-011]). Candidates:
1. A peek popup: an fzf side popup that switches the real pane underneath as you move.
2. A second status line listing agents, with numbered jumps.
3. Jump to the next waiting agent.
4. `choose-tree` filtered to agent panes (no-dependency fallback).
