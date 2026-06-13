# Installing Joystick

Joystick needs two tiny hooks wired in: a zsh hook that logs shell commands, and
Claude Code hooks that log agent turns. The installer does both — idempotently,
backing up every file it edits — and copies the emitter scripts to a stable home
(`$JOYSTICK_HOME`, default `~/.config/joystick`).

## The easy way: let Claude Code do it

Joystick's audience already runs Claude Code (it's what Joystick watches), so the
first-run "onboarding" is just a prompt. In the Joystick window, click **Set up**
— it copies a prompt to your clipboard. Paste it into a Claude Code session:

> Set up Joystick on this Mac: run the installer at
> `~/Applications/Joystick.app/Contents/Resources/install.sh` — it wires up the
> zsh shell hook and Claude Code hooks, is idempotent, and backs up every file it
> edits. Then tell me in one line what it changed and how to undo it.

Claude runs one script (you approve one command), then tells you exactly what
changed. Bonus: that very session is the first thing you'll see appear in
Joystick.

## The manual way: run the script yourself

Same script, no agent required:

```sh
~/Applications/Joystick.app/Contents/Resources/install.sh
```

Then open a new terminal tab (or `source ~/.zshrc`) and run something.

Requires `jq` for the Claude-hook merge: `brew install jq`.

## What it changes

1. **Scripts** → `~/.config/joystick/` (override with `JOYSTICK_HOME`):
   `joystick.zsh`, `claude-hook.sh`, `joystick-redact.zsh`, `joystick-focus.sh`,
   and `install.sh` itself.
2. **`~/.zshrc`** → a guarded block that sources `joystick.zsh`:
   ```sh
   # >>> joystick >>>
   [ -f "$HOME/.config/joystick/joystick.zsh" ] && source "$HOME/.config/joystick/joystick.zsh"
   # <<< joystick <<<
   ```
3. **`~/.claude/settings.json`** → merges Joystick's hooks into
   `UserPromptSubmit`, `Stop`, `StopFailure`, `Notification`, `PostToolUse`,
   `PostToolUseFailure` (your other hooks are left intact).

Every edited file gets a `*.joystick-bak-<timestamp>` copy first. Re-running is
safe — each step replaces its own block rather than duplicating it.

The event log lives at `~/.local/state/joystick/events.jsonl` (`chmod 600`,
Time-Machine-excluded). Nothing leaves your machine.

## Uninstall

```sh
~/.config/joystick/install.sh uninstall
```

Removes the `.zshrc` block, strips Joystick's Claude hooks, and deletes the
copied scripts. Your event log is **not** touched (it's your data) — delete it
yourself with `rm -rf ~/.local/state/joystick` if you want.

## Notes

- Shell-command tracking is zsh-only for now (it uses zsh's `preexec`/`precmd`).
  bash/fish are on the roadmap; Claude-turn tracking works regardless of shell.
- Already-open terminal tabs keep running the old hook until you open a new tab
  or `source ~/.zshrc`.
