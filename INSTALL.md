# Installing Joystick

Joystick needs two tiny hooks wired in: a zsh hook that logs shell commands, and
Claude Code hooks that log agent turns. The installer does both — idempotently,
backing up every file it edits — and copies the emitter scripts to a stable home
(`$JOYSTICK_HOME`, default `~/.config/joystick`).

## The easy way: one click in the app

On first launch, Joystick shows a **Connect Joystick** panel. Click **Enable** —
it runs the bundled installer for you (idempotent, backs up every file it edits),
shows you which steps wired up, and nudges you to open a new terminal. No terminal,
no pasting.

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
   `UserPromptSubmit`, `PreToolUse`, `Stop`, `StopFailure`, `Notification`,
   `PostToolUse`, `PostToolUseFailure` (your other hooks are left intact).

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
