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
**Status:** decided
**Context:** Four states: `idle`, `working`, `waiting`, `done`. `waiting` has a `reason` (`permission` or `input`) because those need different urgency.
**Options:** (a) keep as is; (b) make `permission` its own state; (c) add `error`.
**Decision (2026-11-16):** (a). Not every harness can tell the two kinds of waiting apart, so the reason is optional and defaults to `input`. `error` can be added later without breaking adapters.

## Q-003: When does `done` become `idle`?
**Status:** decided
**Context:** `done` means "finished, and you haven't looked yet". Something has to acknowledge it. The prototype used a `pane-focus-in` hook that rewrote `done` → `idle`. Peer review pointed out this breaks push-only (tmux was writing the harness's state), misfires while peeking (Q-013), and left `@agent_ts` stale.
**Options:** (a) when the pane gains focus (tmux rewrites the state); (b) only when jumping via agentmux; (c) never, until the harness pushes again; (d) keep state harness-owned and track "seen" separately.
**Decision (2026-11-16):** (d). `@agentmux_state` is written only by the harness, so `done` stays `done` until the harness pushes again. The UI owns a separate `@agentmux_seen_ts`; "unseen done" = `done` and `seen_ts` older than `@agentmux_ts`. Seen is marked by `enter` in the picker, or by normal focus while not peeking. The summary counts only unseen done. See SPEC §5.1.

## Q-004: Who owns notifications?
**Status:** decided
**Context:** Harnesses could notify themselves, or just report state and let agentmux apply one policy. v0 sent macOS desktop notifications (`osascript`) on transitions into `waiting`/`done`, skipped for visible panes, with `@agentmux_notify` and `@agentmux_sound` options.
**Leaning (until 2026-11-16):** agentmux.
**Decision (2026-11-16):** no notifications in agentmux at all; the feature and its options were removed. The user doesn't want desktop notifications, and the status bar plus the agents view are the whole attention surface. This also drops the per-`set` visibility lookup and the open sub-questions (rate-limiting, click-to-jump, Linux). Adapters must not notify either.

## Q-005: Stale state when a harness crashes
**Status:** decided
**Context:** In a push-only model, a crashed harness never sends `clear`. The pane usually stays open as your shell.
**Options:** (a) the adapter passes `--pid`, and `refresh`/`list` drop entries whose PID is dead; (b) a TTL on `@agent_ts`; (c) a manual clear in the UI only.
**Decision (2026-11-16):** (a) only. Cleanup happens on the next event or when you open the view, with no polling. (c) was prototyped and dropped: a "clear" key next to the pane list was easy to confuse with killing the pane.

## Q-006: Pane identity
**Status:** open
**Context:** The default target is `$TMUX_PANE`. Edge cases: harnesses that open extra panes for subagents (e.g. pi tmux subagent extensions); agents started over SSH inside a pane (the remote side has no `$TMUX_PANE` for the local server); one pane with several agents.
**Options:** one agent per pane (simple); allow `--pane`; later, a `--key` for several agents per pane.
**Decision:** —

## Q-007: Escaping messages
**Status:** decided
**Context:** `@agent_msg` is displayed through tmux formats, so a message containing `#{…}`, `#(…)` or `#[…]` would be interpreted. `#(…)` would even run a shell command.
**Options:** (a) escape `#` → `##` on write; (b) strip `#`; (c) escape when displaying.
**Update 2026-11-14:** `;` is a second hazard. All writes from one `set` go to tmux as a single argv chain separated by `;` arguments, and tmux 3.7c treats *any* argument ending in `;` as a separator: `foo;` was stored as `foo`, `a\;` as `a;`, and a lone `;` broke the chain midway (state set, but no msg/pid/ts and no summary refresh). Fixed in the chain builder: an argument ending in `;` is sent with that final `;` written as `\;`, which tmux turns back into exactly the original text (`;` → `\;`, `a\;` → `a\\;`, `;;` → `;\;`). A `;` in the middle needs nothing. This applies to every chained argument, not just `--msg`. It's independent of the `#` → `##` escaping, which still runs first. Covered by `test/core.sh`.
**Decision (2026-11-16):** (a), plus the `;` handling above. The stored value is always escaped, so anything showing it in a tmux format must use `#{E:@agentmux_msg}` (plain `#{@agentmux_msg}` shows `##`). `list` unescapes for scripts.

## Q-008: Option naming
**Status:** decided
**Context:** Pane options used `@agent_*` and global options `@agentmux_*`. `@agent_*` is short, but could collide with other plugins.
**Options:** keep; use `@agentmux_*` everywhere.
**Decision (2026-11-16):** `@agentmux_*` everywhere, renamed now while there are no users. No compatibility aliases.

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
**Status:** open
**Context:** See `prototypes/NOTES.md`. The main candidate is the peek popup (prototype 01).
**Update 2026-11-14:** the feasibility risk is resolved. Popups survive `switch-client` on tmux 3.7c, and peek, restore and jump all work in a headless test. Waiting on a hands-on feel test.
**Decision:** —

## Q-012: Coexisting with status-bar themes
**Status:** open
**Context:** Your tmux config uses `tmux-tokyo-night` through TPM, which sets `status-right`. agentmux's summary has to slot into a theme it doesn't own.
**Options:** document "add `#{@agentmux_summary}` to your status-right"; append it automatically on load; use a second status line (prototype 02).
**Decision:** —

## Q-013: Does peeking count as "seeing" a `done` agent?
**Status:** decided
**Context:** Found in prototype 01. The peek popup selects each pane it passes over, so the `pane-focus-in` hook (Q-003) turned `done` into `idle` just from scrolling past it in the list.
**Options:** (a) the peek UI sets a global flag (`@agentmux_peeking`) that the hook checks; (b) acknowledge only on `enter` in the UI, not on focus; (c) accept it.
**Decision (2026-11-16):** (a) and (b) together, under the Q-003 model. While the picker is open it sets `@agentmux_peeking`, and the focus hook does nothing. `enter` in the picker marks the landed-on agent seen. The picker must unset the flag on every exit path, or normal focus tracking would stay off.

## Q-014: Read verbs outside tmux
**Status:** decided
**Context:** `agentmux list`/`refresh` run outside tmux talk to the *default* tmux server, and `refresh` *writes* the summary options there. During development this hit the real server instead of the sandbox (harmless, but surprising).
**Options:** (a) keep (normal tmux-client behaviour); (b) refuse to write when `$TMUX` is unset unless `--server`/`-L` is given; (c) add `-L/-S` passthrough.
**Decision (2026-11-16):** (a), documented in SPEC §7. Tests and the sandbox must set `TMUX`/use their own socket (AGENTS.md rule 5). (c) can be added later if needed.

## Q-015: Claude Code adapter details
**Status:** leaning
**Context:** `adapters/claude-code/hooks.json` is unverified against a real session. To check: is `$PPID` in a hook command really the Claude process? Does the Notification message reliably tell permission apart from input (currently matched on "ermission")? Does `PreToolUse` → `working` clear `waiting` at the right time after approval? Is there a better event for "answered"?
**Update (2026-11-14, from https://code.claude.com/docs/en/hooks; not yet checked against a real session):**
- *Confirmed in docs:* the Notification hook input has `message`, optional `title`, and `notification_type`. Documented types: `permission_prompt`, `idle_prompt`, `auth_success`, `auth_storage_failure`, `elicitation_dialog`, `elicitation_url_dialog`, `elicitation_complete`, `elicitation_response`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_fired`, `quota_auto_resume_stale`, `quota_auto_resume_disabled`, `plugin_notification`. The Notification matcher filters on this type, so separate `permission_prompt` / `idle_prompt` entries are possible. Docs example: `{"message":"Claude needs your permission","title":"Permission needed","notification_type":"permission_prompt"}`. The adapter still matches `message` on "ermission"; switching to `notification_type` is pending a check against a real session. Note that today every type (e.g. `auth_success`, `agent_completed`) sets `waiting`/`input`, and `idle_prompt` fires after `Stop`, so it overwrites `done` with `waiting`/`input`.
- *Confirmed in docs:* `PostToolUse` ("after a tool call succeeds") and `PostToolUseFailure` ("after a tool call fails") take a tool-name matcher; `"*"` or omitted matches all. The adapter now sets `working` on both, so `waiting` is cleared once an approved tool finishes even if no further `PreToolUse` follows.
- *Gap (docs):* no documented event fires when the user *answers* a permission prompt. `PermissionRequest` fires *before* the dialog. `PermissionDenied` fires only for auto-mode denials, not manual ones. So while an approved tool is running, the pane still shows `waiting` until `PostToolUse`/`PostToolUseFailure`. After a manual denial, nothing fires until the next `PreToolUse`/`Stop`.
- *Confirmed in docs:* command hooks run via `sh -c` on macOS/Linux with Claude Code's environment, in their own session without a controlling terminal.
- *Unconfirmed:* `$PPID`. The docs say nothing about the parent process. `$PPID` in `sh -c` is the process that spawned `sh`; it is the Claude Code process only if Claude spawns `sh` directly (no wrapper). Verify in a real session, e.g. compare `@agentmux_pid` with `pgrep -f claude`.
**Leaning (2026-11-16):** map on `notification_type`: `permission_prompt` → `waiting`/`permission`; `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` → `waiting`/`input`; everything else (`idle_prompt`, `auth_*`, `quota_*`, `plugin_notification`, `agent_completed`, `elicitation_complete`/`_response`) is ignored. `idle_prompt` is a reminder, not a state change, so ignoring it keeps `done` as `done` and stops a second alert. If `notification_type` is missing (older Claude Code), fall back to the message match. To mark decided: confirm the types and `$PPID` in a real session.
**Decision:** —

## Q-016: Does `set` replace or merge fields?
**Status:** decided
**Context:** Found in peer review. `set working` after `set waiting --msg "Bash(rm …)"` could keep the old message.
**Options:** (a) replace: unpassed fields are cleared; (b) merge: unpassed fields are kept.
**Decision (2026-11-16):** (a). A `set` describes the whole current state; a leftover message would describe something that's no longer happening. Adapters pass `--harness`/`--pid` on every call anyway.

## Q-017: `--reason` outside `waiting`
**Status:** decided
**Context:** Found in peer review: what happens to `set done --reason permission`?
**Decision (2026-11-16):** ignored and stored as unset. The reason only qualifies `waiting`.

## Q-018: `focus-events` and seen tracking
**Status:** decided
**Context:** The `pane-focus-in` hook needs `focus-events on`, a global setting agentmux would be changing for the user.
**Decision (2026-11-16):** turn it on only while `@agentmux_track_seen` is `on` (default), and document it. With `off`, no focus hook; `enter` in the picker is the only way to mark seen.

## Q-019: Key binding collisions
**Status:** decided
**Context:** `agentmux.tmux` binds `prefix a` and `prefix A` unconditionally, replacing anything the user had there.
**Decision (2026-11-16):** if a key is already bound, leave it, show a message, and skip. `@agentmux_key_force on` overrides. Keys are set with `@agentmux_key_tree` / `@agentmux_key_waiting`; empty disables.

## Q-020: Colours and sound
**Status:** decided
**Context:** Summary colours and the "Glass" notification sound were hard-coded.
**Decision (2026-11-16):** options `@agentmux_style_{waiting,working,done,idle}` and `@agentmux_sound`, with the current values as defaults.
**Update 2026-11-16:** `@agentmux_sound` removed along with notifications (Q-004).

## Q-021: Showing idle agents in the summary
**Status:** decided
**Context:** With only idle agents the summary is empty, so you can't tell agentmux is running.
**Decision (2026-11-16):** stay empty by default (quiet is the point); `@agentmux_show_idle on` adds `○ N idle`.

## Q-022: Concurrent refreshes
**Status:** decided
**Context:** Found in peer review. Two `set`s at once can each read panes, then write the summary in the wrong order, leaving it stale until the next event.
**Options:** (a) tmux's own lock, `wait-for -L` / `-U`; (b) a lock file; (c) accept it.
**Decision (2026-11-16):** (a): built in, no files. `wait-for -L` waits forever, and a holder that dies leaves the lock held, which would hang every later hook (breaking AGENTS.md rule 3). So the wait is bounded (~1 s); on timeout the lock is treated as stale, released, and the refresh goes ahead. Release on every exit path (trap).
