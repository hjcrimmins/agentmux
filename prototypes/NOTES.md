# Prototype notes

Findings per prototype. Feeds [Q-011](../OPEN_QUESTIONS.md#q-011-primary-agents-view-ui).

---

## 01: peek popup (`prototypes/01-peek-popup/`)

**Idea:** an fzf list in a side popup. Moving the cursor switches the real client to that agent's pane *underneath* the popup, so you see the actual pane live. `enter` stays there; `esc` goes back.

**Try it:** `prototypes/01-peek-popup/try.sh`, then from a terminal outside tmux run `tmux -L agentmux-test attach` and press `prefix a`.

### Verified headlessly (2026-11-14, tmux 3.7c, fzf 0.75.0)
Tested with a pty-attached client (`script`) driven by scripted keystrokes.

| Check | Result |
|---|---|
| Popup survives `switch-client` across sessions and windows | ✅ Popup process kept running through 3+ switches, no SIGHUP |
| Peek on cursor move (fzf `focus` event → `switch-client`) | ✅ The client follows the cursor: `api` → `infra` → `web` |
| `esc` restores the original pane | ✅ (after fix below) |
| `esc` restores each peeked session's current window and each window's active pane | ✅ |
| `enter` lands on the target, with `client_last_session` = where you came from (so `prefix L` goes back) | ✅ |
| `/` filter mode → `esc` returns to navigate mode → `esc` closes | ✅ (`FZF_PROMPT` tracks the mode) |
| Popup renders list, header and colours; status-bar summary updates live underneath | ✅ (seen in the pty capture) |

### Gotchas found
- **`$TMUX_PANE` inside a popup is not the pane the client was on.** It reported `%0` while the client was on `%2`. The picker now works out the origin as *client → client_session → that session's active pane*. Worth remembering for any popup-based UI.
- **Formats aren't expanded in `display-popup`'s shell command** when it's launched from the CLI. Inside the popup, `tmux display -p '#{client_name}'` does resolve to the right client, so the picker queries tmux itself.
- **Peeking has side effects on tmux state:** session current window, window active pane and client last-session. Restore handles the first two and last-session for `enter`. **Not restored:** each session's *last-window* history (`prefix l`), and on `esc`, last-session when you started with none.
- **Peeking acknowledges `done`:** the `pane-focus-in` hook (Q-003) turns `done` into `idle` as soon as you merely peek at it. Probably wrong. Peeking isn't reading. → Q-013.
- fzf ≥ 0.59 is needed for `--no-input`, `show-input` and `--gutter`.

### Iteration 2 (2026-11-14): clipping
**Feedback:** the popup was too narrow and rows were clipped.
**Changes:**
- Width adapts: 45% of the terminal, minimum 64 columns, always leaving 30 columns of the agent pane visible. Override with `tmux set -g @agentmux_peek_width 90` (columns) or `50%`. The launcher (`open.sh`) reads `#{client_width}` through `run-shell -b`.
- Compact rows: `● permit  claude   web:0      7m  Bash(npm run build)`.
- A details pane at the bottom of the popup shows the full message wrapped, plus window name, path and age.
**Verified** at 150×40: the popup is 66 columns wide and rows fit.

### Iteration 3 (2026-11-14): column names
A column header (`STATE  HARNESS  WHERE  AGE  MESSAGE`) is emitted as the first row and pinned with fzf `--header-lines 1`, so it lines up with the rows and stays put while filtering. `▾` marks the sorted column and follows `s`. (awk pads by bytes, so `▾` replaces a pad space instead of being padded.)

### Iteration 4 (2026-11-14): sort fix, `x` removed
- **Bug:** `s` didn't change the sort. `cycle_sort` did `case $(cat f) … esac > f`, and the redirect truncates `f` before `$(cat f)` runs, so it always fell back to `state`. Fixed by reading first. Verified in a pty: header goes `STATE▾ → AGE▾ → WHERE▾ → STATE▾`.
- **Removed the `x` (clear) key.** It only removed agentmux's state for the pane (it never killed anything), but it looked risky and wasn't worth it. Stale entries are already handled by the PID check (Q-005). `agentmux clear` stays as a harness verb.
- **Note:** in the tree-mode fallback (`prefix t` / `A`), `x` is tmux's built-in *kill pane* (with a confirm prompt). Tree-mode keys can't be rebound, which is one more point against it as the primary UI.

### Iteration 5 (2026-11-14): layout by terminal size
**Feedback:** the popup covered the pane being peeked at. Cause: the 64-column minimum from iteration 2 took 62% of a 102-column terminal.
**Change:** `@agentmux_peek_layout` = `auto` (default) | `side` | `top`.
- `auto`: side popup at ≥ `@agentmux_peek_side_min` columns (default 140), otherwise a **full-width strip across the top** (40% of the height, minimum 12 rows, always leaving at least 8 rows below). Agents' prompts sit at the bottom of their panes, so they stay visible under a top strip.
- Top strip: details pane moves to the right of the list (`right,38%`) to save height.
- Override sizes with `@agentmux_peek_width` (side) and `@agentmux_peek_height` (top): columns/rows, or `N%`.
**tmux gotchas found while doing this (3.7c):**
- `display-popup -y` is the popup's **bottom** edge; `-y 0` is clamped to the top row.
- `-x R` tracked the right edge of the **current pane**, not the terminal: in a split window the side popup landed in the middle of the screen. Now `x = client_width − width` is computed explicitly.
**Verified** in a pty: 102×61 → top strip rows 1–24, full width; 160×50 → side popup at columns 89–160, both in a split window and a single-pane one.

### Still needs a human (things a pty test can't judge)
- [ ] Does peeking *feel* good, or is the switching visually jarring? Any flicker?
- [ ] Is the adaptive width right? Does it hide too much of the agent's prompt? Is the 7-line details pane worth its space?
- [ ] Do navigate and filter modes feel natural? Should it open in filter mode instead?
- [ ] Is the `s` sort cycle (state → age → name) useful?
- [ ] Behaviour with your real tmux config and theme (tokyo-night) and true colour.

### Verdict
Technically feasible: the key risk (popup survives switching) is gone. Waiting on the hands-on feel test.

---

## 02: second status line
Not started.

## 03: jump to next waiting
Not started.
