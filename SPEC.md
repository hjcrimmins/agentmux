# agentmux spec

**Version:** 0.2.0-draft
**Status:** DRAFT. Expect breaking changes. Unresolved points are tracked in [OPEN_QUESTIONS.md](OPEN_QUESTIONS.md) and referenced inline as `[Q-NNN]`.

**Changes from 0.1.0:** per-pane options renamed `@agent_*` → `@agentmux_*` [Q-008]; "seen" is now a separate, UI-owned fact and tmux never rewrites the harness's state [Q-003, Q-013]; `set` replaces every field [Q-016]; new `seen` verb; `list` gained a `seen` column; refresh is serialised [Q-022]; colours, sound, keys and idle display are configurable [Q-019–Q-021].

## 1. Purpose

agentmux gives tmux a single, harness-independent view of the coding agents running in its panes: which are working, which need you, which are done. You can jump to any of them from one place.

## 2. Responsibilities

There are two parts with one boundary between them.

| Side | Owns | Does not do |
|---|---|---|
| **Harness adapter** (Claude Code hook, pi extension, opencode plugin, …) | Deciding *when* the agent's state changes and **pushing** it via `agentmux set` / `agentmux clear` | Any tmux knowledge, UI or notification policy |
| **agentmux (tmux side)** | Storing state, recording what the user has seen, the status-bar summary, notifications, the agents view, jumping | Detecting, guessing or rewriting state. It never scrapes panes or watches processes to infer state, and never writes `@agentmux_state`. |

**Push only.** If a harness doesn't push, its pane isn't an agent as far as agentmux is concerned.

**Two kinds of fact, two owners.** The agent's *state* belongs to the harness. Whether *you have seen* the latest state belongs to the UI (§5, `@agentmux_seen_ts`). Neither side writes the other's options.

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
| `done` | Agent finished a turn. It stays `done` until the harness pushes another state. Whether you've looked at it yet is tracked separately (§5). [Q-003] |

`clear` means the pane is no longer an agent (the session ended).

### 3.2 Arguments

- Each `set` describes the agent's **whole** current state: any field not passed (`--reason`, `--msg`, `--harness`, `--pid`) is cleared, not kept from the previous call. [Q-016]
- `--reason`: only stored for `waiting`; ignored for other states. [Q-017]
- `--msg TEXT`: short human-readable detail (e.g. the permission request). `--msg -` reads it from stdin. agentmux normalises it: newlines become spaces, it's truncated to 200 characters, and `#` is escaped to `##`. A `;` anywhere in it (including at the end) is stored literally. [Q-007]
- `--harness NAME`: a short lowercase identifier: `claude`, `pi`, `opencode`, `codex`, …
- `--pid PID`: PID of the long-lived harness process. agentmux uses it only to drop stale entries if the harness dies without calling `clear`. [Q-005] Adapters **should** pass it.
- `--pane PANE_ID`: target pane. Defaults to `$TMUX_PANE`. [Q-006]

### 3.3 Guarantees to adapters

- Calls always exit `0` and print nothing on success. Errors go to stderr, and the exit code is still `0` unless `AGENTMUX_STRICT=1` (then `2`), so a hook can never break or block a harness.
- If not inside tmux (no `--pane` and no `$TMUX_PANE`), calls are silent no-ops. This check comes **before** argument validation, so even malformed calls are silent outside tmux.
- Calls are fast (a few tmux calls, no daemon) and never wait indefinitely: any lock wait is bounded (§4).

## 4. Runtime model

- **No daemon.** `agentmux` is a short-lived CLI. The tmux server is the only long-running process.
- `agentmux.tmux` runs once when tmux loads its config. It registers key bindings and tmux hooks, then exits. Paths it embeds in hooks and bindings are quoted so that spaces, `'` and `#` in the install path work.
- A harness event runs `agentmux set|clear`. That writes the pane options, recomputes the summary, refreshes status lines and possibly sends a notification.
- When a pane exits or is killed, tmux hooks run `agentmux refresh`.
- When a pane gains focus, a tmux hook runs `agentmux seen` for it, unless a picker is peeking or seen-tracking is off (§5.1).
- **Refresh is serialised.** Recomputing the summary (read every pane, write the global options) runs under the tmux lock `wait-for -L agentmux` / `-U`, so two concurrent `set`s can't leave a stale summary. The wait is bounded (about 1 s). On timeout the lock is assumed stale (a holder died), it is released, and the refresh proceeds. [Q-022]
- UIs read state and write only `@agentmux_seen_ts` (via `agentmux seen`) and `@agentmux_peeking`.

## 5. State storage

All state lives in the tmux server's memory as user options. There are no files. All options use the `@agentmux_` prefix. [Q-008]

**Per pane, written by the harness** (via `set`/`clear`; removed automatically when the pane closes):

| Option | Value |
|---|---|
| `@agentmux_state` | `idle` \| `working` \| `waiting` \| `done` |
| `@agentmux_reason` | `permission` \| `input`, only for `waiting`; otherwise unset |
| `@agentmux_harness` | harness name, or unset |
| `@agentmux_msg` | normalised, escaped message, or unset. Display it in tmux formats with `#{E:@agentmux_msg}` so `##` shows as `#`. |
| `@agentmux_pid` | harness PID, or unset |
| `@agentmux_ts` | Unix time of the last `set` |

**Per pane, written by the UI:**

| Option | Value |
|---|---|
| `@agentmux_seen_ts` | Unix time the user last saw this pane (§5.1). Unset = never seen. `set` doesn't touch it; `clear` removes it. |

**Global:**

| Option | Written by | Value |
|---|---|---|
| `@agentmux_summary` | refresh | Ready-to-display status-bar text (with tmux style directives). Empty when there is nothing to show (§5.2). |
| `@agentmux_counts` | refresh | `waiting working done idle` as four space-separated integers. `done` counts **unseen** done; seen done counts as `idle`. |
| `@agentmux_peeking` | picker | Set (to the client name) while a peek UI is open; unset otherwise. The picker must unset it on every exit path. |
| `@agentmux_bin` | `agentmux.tmux` | Absolute path to the `agentmux` executable |

Writes from a single `set` are sent as one chained tmux command, so they are applied atomically.

### 5.1 Seen

An agent is **unseen** when its state is `done` or `waiting` and `@agentmux_seen_ts` is unset or older than `@agentmux_ts`. Only "unseen done" changes how things are shown (`waiting` always demands attention).

`agentmux seen [--pane PANE_ID]` sets `@agentmux_seen_ts` to now and refreshes. It's a UI verb, not part of the harness interface, and follows the read-verb exit rules (§7). It's called:
- by the picker when you press `enter` on an agent (landing on it), and
- by the `pane-focus-in` hook when you focus an agent pane normally, while `@agentmux_peeking` is unset. Scrolling past an agent in the picker therefore doesn't count as seeing it. [Q-013]

Focus tracking needs `focus-events on`, which `agentmux.tmux` turns on while `@agentmux_track_seen` is `on` (the default). With `off`, no focus hook is installed and only `enter` in the picker marks an agent seen. [Q-018]

### 5.2 Configuration

| Option | Default | Meaning |
|---|---|---|
| `@agentmux_notify` | `on` | `off` disables desktop notifications |
| `@agentmux_sound` | `Glass` | Notification sound name; empty for silent |
| `@agentmux_track_seen` | `on` | See §5.1 |
| `@agentmux_show_idle` | `off` | `on` adds `○ N idle` to the summary. Otherwise a summary with only idle (and seen-done) agents is empty. [Q-021] |
| `@agentmux_style_waiting` | `fg=red,bold` | tmux style for each summary segment [Q-020] |
| `@agentmux_style_working` | `fg=yellow` | |
| `@agentmux_style_done` | `fg=green` | |
| `@agentmux_style_idle` | `fg=colour244` | |
| `@agentmux_key_tree` | `a` | Prefix key for the agents view; empty disables [Q-019] |
| `@agentmux_key_waiting` | `A` | Prefix key for the waiting-only view; empty disables |
| `@agentmux_key_force` | `off` | `on` lets agentmux replace an existing binding on those keys. Otherwise an already-bound key is left alone and a message says so. |

Options are read when used, so most take effect on the next refresh; key options take effect when `agentmux.tmux` is re-run.

## 6. Notifications [Q-004]

On a transition into `waiting` or `done`, agentmux sends a desktop notification, unless:
- `@agentmux_notify` is `off`, or
- the pane is currently visible: it's the active pane of the active window of a session with an attached client.

On macOS this uses `osascript`, with `@agentmux_sound`.

## 7. Read and UI interface (for UIs and scripts)

```
agentmux list [--sort state|name|age]
agentmux seen [--pane PANE_ID]
agentmux refresh
agentmux version
```

Unlike `set`/`clear`, these exit `2` on bad arguments. Outside tmux they talk to the default tmux server, like any tmux client; `refresh` and `seen` write there too. [Q-014]

- `list` first runs a refresh (so stale entries are dropped), then prints one agent pane per line, with messages unescaped for display. TSV columns: `pane_id state reason harness location msg age_seconds path seen`, where `location` is `session:window_index.pane_index` and `seen` is `1` or `0` (§5.1). Default sort is `state`: waiting > unseen done > working > idle and seen done, then oldest first.
- `refresh` drops stale entries (dead `@agentmux_pid`) and recomputes the summary.
- `version` prints the spec version.

## 8. User interface

Still being prototyped (see `prototypes/` and [Q-011]). Candidates:
1. A peek popup: an fzf popup that switches the real pane underneath as you move.
2. A second status line listing agents, with numbered jumps.
3. Jump to the next waiting agent.
4. `choose-tree` filtered to agent panes (no-dependency fallback). Shows messages with `#{E:@agentmux_msg}`.
