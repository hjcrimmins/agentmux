---
name: install-agentmux
description: Install agentmux (tmux status/agents view for coding agents) for the current user - put the CLI on PATH, load it in tmux.conf, and connect a harness adapter such as Claude Code's hooks. Use when the user asks to install, set up, update, check or uninstall agentmux.
---

# Install agentmux

agentmux shows coding agents running in tmux panes (working / waiting / done) in the status bar and an agents view. Install = three changes to the user's own config, plus a check. The README's **Install** section is the source of truth for the exact commands; this skill is the procedure and the guardrails.

## Ground rules

- **Ask before each change** to a file outside this repo (`~/.local/bin`, `~/.tmux.conf` or the file it really lives in, `~/.claude/settings.json`). Show the exact lines or command first. These are the user's files; one approval doesn't cover the next step.
- **Back up** every file before editing it (`cp f f.bak.$(date +%s)`), and say where the backup is.
- **Follow symlinks.** `~/.tmux.conf` is often a symlink into a dotfiles repo (e.g. GNU Stow). Edit the real file (`readlink`/`realpath`) and mention that it's in a git repo the user may want to commit.
- **Be idempotent.** Check what's already installed before adding anything; never add a second `run-shell` line or duplicate hooks.
- **Don't touch the user's tmux server state beyond `tmux source`**, and only reload after asking. Never `kill-server`.
- **No notifications.** agentmux deliberately has none; don't add any.

## Steps

### 0. Find the repo and check requirements

- Repo root: the directory containing `bin/agentmux` and `agentmux.tmux` (usually where this skill is). Use its absolute path below as `$REPO`.
- Check: `tmux -V`, `jq --version`, and for the popup `fzf --version`, `curl --version`. Report anything missing; `jq` and tmux are required.
- Check what's already there:
  - `command -v agentmux` and `readlink "$(command -v agentmux)"`
  - `grep -n agentmux` in the real tmux.conf
  - `jq '[.hooks // {} | .[][] | .hooks[]?.command | select(test("agentmux"))] | length' ~/.claude/settings.json`
  - Tell the user what's installed and what isn't, then do only the missing steps (or all of them for an update).

### 1. CLI on PATH

Pick a directory that's on PATH (prefer `~/.local/bin`; check with `echo "$PATH" | tr : '\n'`). After approval:

```sh
ln -sfn "$REPO/bin/agentmux" ~/.local/bin/agentmux && agentmux version
```

### 2. tmux

Find where the theme / TPM is loaded (`run '~/.tmux/plugins/tpm/tpm'` or a theme `run-shell`). Propose adding **after** that line:

```tmux
# agentmux
run-shell '$REPO/agentmux.tmux'
set -ga status-right '#{@agentmux_summary}'
```

- Write the real absolute path for `$REPO`.
- If the user's own `status-right` is set later in the file, suggest placing `#{@agentmux_summary}` inside it instead of `-ga`.
- `prefix a` / `prefix A` are agentmux's default keys. If either is already bound in the config, ask which key to use and set `@agentmux_key_tree` / `@agentmux_key_waiting` before `run-shell` (agentmux skips already-bound keys rather than overriding them).
- Offer the optional peek popup (README "Optional: the peek popup"). It's a prototype; only add it if the user wants it.
- After approval and editing, offer to reload: `tmux source <real tmux.conf>`. Then check `tmux show -gv @agentmux_bin` prints `$REPO/bin/agentmux`.

### 3. Harness adapters

Ask which harnesses the user runs. Only Claude Code has an adapter so far (`$REPO/adapters/`); for others, say so and point at `SPEC.md` §3 (an adapter is a few hook commands calling `agentmux set`).

**Claude Code**, after approval:

```sh
f=~/.claude/settings.json; [ -f "$f" ] || echo '{}' > "$f"
cp "$f" "$f.bak.$(date +%s)"
jq --slurpfile a "$REPO/adapters/claude-code/hooks.json" -f "$REPO/adapters/claude-code/install.jq" "$f" > "$f.new" && mv "$f.new" "$f"
```

- `install.jq` keeps all other settings and hooks and replaces any earlier agentmux hooks, so re-running is safe.
- Before writing, show the diff (`jq -S . "$f"` vs `jq -S . "$f.new"`), and validate the result is JSON.
- If the user runs Claude Code from this session, tell them the hooks apply to sessions started from now on, and that existing sessions need restarting.

### 4. Check

- `agentmux list` should run without error (prints nothing when no agents are running).
- Ask the user to start a harness in a tmux pane and send a prompt: `agentmux list` should show it `working`, then `done`, and the status bar should show `… 1 working` → `✓ 1 done`.
- If nothing appears: `command -v agentmux` **inside that pane** (the harness must see it on PATH); `tmux show -gv @agentmux_bin`; for Claude Code, `jq '.hooks | keys' ~/.claude/settings.json`.

## Uninstall

Ask first, back up, then:

```sh
f=~/.claude/settings.json; cp "$f" "$f.bak.$(date +%s)"
jq -f "$REPO/adapters/claude-code/uninstall.jq" "$f" > "$f.new" && mv "$f.new" "$f"
rm ~/.local/bin/agentmux          # only if it's the symlink to $REPO/bin/agentmux
```

Remove the agentmux lines from the real tmux.conf and reload, or tell the user a tmux restart clears the remaining hooks (agentmux keeps no files; its state lives in tmux's memory).

## Finish

Summarise: what changed in which files, backup paths, the keys (`prefix a`, `prefix A`), and anything skipped. Remind the user if the tmux.conf is in a dotfiles repo with uncommitted changes.
