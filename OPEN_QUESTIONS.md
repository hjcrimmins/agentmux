# Open questions

Open questions about [SPEC.md](SPEC.md) while it's being iterated on.

**Process:** each entry has an ID, a status (`open`, `leaning`, `decided`) and, once settled, a dated decision. When a question is decided, the answer goes into `SPEC.md` and the entry stays here as a record of why. Don't renumber; new questions get the next ID.

---

## Q-001: Project name
**Status:** open
**Context:** `agentmux` is a placeholder. The name ends up in the CLI name, the repo name and the `@agentmux_*` option names.
**Options:** keep `agentmux`; something else.
**Decision:** —

## Q-002: Is the state set right?
**Status:** leaning
**Context:** Four states: `idle`, `working`, `waiting`, `done`. `waiting` has a `reason` (`permission` or `input`) because those need different urgency.
**Options:** (a) keep as is; (b) make `permission` its own state; (c) add `error`.
**Leaning:** (a). Not every harness can tell the two kinds of waiting apart, so the reason is optional.
**Decision:** —

## Q-003: When does `done` become `idle`?
**Status:** open
**Context:** `done` means "finished, and you haven't looked yet". Something has to acknowledge it.
**Options:** (a) when the pane gains focus (tmux `pane-focus-in` hook, needs `focus-events on`); (b) only when jumping via agentmux; (c) never, until the harness pushes again.
**Leaning:** (a). It's implemented that way in the prototype, but the `pane-focus-in` behaviour is unverified.
**Decision:** —

## Q-004: Who owns notifications?
**Status:** leaning
**Context:** Harnesses could notify themselves, or just report state and let agentmux apply one policy.
**Leaning:** agentmux. Adapters stay small and notification behaviour is the same across harnesses. Open sub-questions: rate-limiting, click-to-jump (needs `terminal-notifier`), Linux support.
**Decision:** —

## Q-005: Stale state when a harness crashes
**Status:** leaning
**Context:** In a push-only model, a crashed harness never sends `clear`. The pane usually stays open as your shell.
**Options:** (a) the adapter passes `--pid`, and `refresh`/`list` drop entries whose PID is dead; (b) a TTL on `@agent_ts`; (c) a manual clear in the UI only.
**Leaning:** (a) + (c). Still no polling: cleanup happens on the next event or when you open the view.
**Decision:** —

## Q-006: Pane identity
**Status:** open
**Context:** The default target is `$TMUX_PANE`. Edge cases: harnesses that open extra panes for subagents (e.g. pi tmux subagent extensions); agents started over SSH inside a pane (the remote side has no `$TMUX_PANE` for the local server); one pane with several agents.
**Options:** one agent per pane (simple); allow `--pane`; later, a `--key` for several agents per pane.
**Decision:** —

## Q-007: Escaping messages
**Status:** leaning
**Context:** `@agent_msg` is displayed through tmux formats, so a message containing `#{…}`, `#(…)` or `#[…]` would be interpreted. `#(…)` would even run a shell command.
**Options:** (a) escape `#` → `##` on write; (b) strip `#`; (c) escape when displaying.
**Leaning:** (a). Implemented in v0.
**Update 2026-11-14:** `;` is a second hazard. All writes from one `set` go to tmux as a single argv chain separated by `;` arguments, and tmux 3.7c treats *any* argument ending in `;` as a separator: `foo;` was stored as `foo`, `a\;` as `a;`, and a lone `;` broke the chain midway (state set, but no msg/pid/ts and no summary refresh). Fixed in the chain builder: an argument ending in `;` is sent with that final `;` written as `\;`, which tmux turns back into exactly the original text (`;` → `\;`, `a\;` → `a\\;`, `;;` → `;\;`). A `;` in the middle needs nothing. This applies to every chained argument, not just `--msg`. It's independent of the `#` → `##` escaping, which still runs first. Covered by `test/core.sh`.
**Decision:** —

## Q-008: Option naming
**Status:** open
**Context:** Pane options use `@agent_*` and global options use `@agentmux_*`. `@agent_*` is short, but could collide with other plugins.
**Options:** keep; use `@agentmux_*` everywhere.
**Decision:** —

## Q-009: Spec versioning
**Status:** open
**Context:** Adapters live in other repos too (e.g. `pi-config`). How does an adapter know it's compatible?
**Options:** `agentmux version` prints the spec version, and adapters check the major version; or no check (adapters are tiny).
**Decision:** —

## Q-010: Implementation language
**Status:** open
**Context:** v0 is bash + jq: hackable, no build. A Go or Rust binary would be faster, with no quoting pitfalls and easy distribution.
**Leaning:** stay in bash until the spec stabilises.
**Decision:** —

## Q-011: Primary agents view UI
**Status:** open (being prototyped)
**Context:** See `prototypes/NOTES.md`. The main candidate is the peek popup (prototype 01).
**Update 2026-11-14:** the feasibility risk is resolved. Popups survive `switch-client` on tmux 3.7c, and peek, restore and jump all work in a headless test. Waiting on a hands-on feel test.
**Decision:** —

## Q-012: Coexisting with status-bar themes
**Status:** open
**Context:** Your tmux config uses `tmux-tokyo-night` through TPM, which sets `status-right`. agentmux's summary has to slot into a theme it doesn't own.
**Options:** document "add `#{@agentmux_summary}` to your status-right"; append it automatically on load; use a second status line (prototype 02).
**Decision:** —

## Q-013: Does peeking count as "seeing" a `done` agent?
**Status:** open
**Context:** Found in prototype 01. The peek popup selects each pane it passes over, so the `pane-focus-in` hook (Q-003) turns `done` into `idle` just from scrolling past it in the list.
**Options:** (a) the peek UI sets a global flag (`@agentmux_peeking`) that the hook checks; (b) acknowledge only on `enter` in the UI, not on focus; (c) accept it.
**Leaning:** (a). Ties into Q-003.
**Decision:** —

## Q-014: Read verbs outside tmux
**Status:** open
**Context:** `agentmux list`/`refresh` run outside tmux talk to the *default* tmux server, and `refresh` *writes* the summary options there. During development this hit the real server instead of the sandbox (harmless, but surprising).
**Options:** (a) keep (normal tmux-client behaviour); (b) refuse to write when `$TMUX` is unset unless `--server`/`-L` is given; (c) add `-L/-S` passthrough.
**Decision:** —

## Q-015: Claude Code adapter details
**Status:** open
**Context:** `adapters/claude-code/hooks.json` is unverified against a real session. To check: is `$PPID` in a hook command really the Claude process? Does the Notification message reliably tell permission apart from input (currently matched on "ermission")? Does `PreToolUse` → `working` clear `waiting` at the right time after approval? Is there a better event for "answered"?
**Decision:** —
