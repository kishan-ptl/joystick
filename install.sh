#!/bin/zsh
# install.sh — wire Joystick into your shell and Claude Code, idempotently.
#
# Two front doors, one script:
#   • Paste the "Setup" prompt from Joystick into Claude Code — it runs this.
#   • Or run it yourself:
#       ~/Applications/Joystick.app/Contents/Resources/install.sh
#
# What it does — every step is idempotent and backs up what it edits:
#   1. Copies the emitter scripts to $JOYSTICK_HOME (default ~/.config/joystick).
#   2. Adds a guarded `source …/joystick.zsh` block to your ~/.zshrc.
#   3. Merges Joystick's Claude Code hooks into ~/.claude/settings.json.
#
# Undo it all:           install.sh uninstall
# The event log (~/.local/state/joystick) is YOUR data — uninstall never
# touches it; the summary tells you how to delete it if you want.
#
# Testable without touching real files via env overrides:
#   JOYSTICK_HOME, JOYSTICK_ZSHRC, JOYSTICK_CLAUDE_SETTINGS
set -u
emulate -L zsh
setopt no_nomatch

SELF=${0:A:h}
JOYSTICK_HOME=${JOYSTICK_HOME:-$HOME/.config/joystick}
ZSHRC=${JOYSTICK_ZSHRC:-${ZDOTDIR:-$HOME}/.zshrc}
CLAUDE_SETTINGS=${JOYSTICK_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}

# The scripts that get installed. WIRED = the emitters/helpers placed in
# $JOYSTICK_HOME (the zsh + Claude hooks reference some; the app invokes
# joystick-focus.sh / joystick-send.sh). ALL also includes this installer so
# `uninstall` lives next to them.
WIRED=(joystick.zsh claude-hook.sh joystick-redact.zsh joystick-focus.sh joystick-send.sh)
ALL=($WIRED install.sh)

MARK_BEGIN='# >>> joystick >>>'
MARK_END='# <<< joystick <<<'

bold() { print -P -- "%B$*%b" }
ok()   { print -r -- "  ✓ $*" }
warn() { print -r -- "  ! $*" >&2 }
die()  { print -r -- "✗ $*" >&2; exit 1 }

backup() {  # $1 = file; copy aside if it exists
  [[ -f $1 ]] || return 0
  local b="$1.joystick-bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$1" "$b" && ok "backed up ${1/#$HOME/~} → ${b:t}"
}

# Strip any existing marker block from stdin → stdout (idempotent re-runs).
strip_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0==b {skip=1; next} skip && $0==e {skip=0; next} !skip {print}'
}

install_scripts() {
  bold "Scripts → $JOYSTICK_HOME"
  mkdir -p "$JOYSTICK_HOME" || die "can't create $JOYSTICK_HOME"
  if [[ ${SELF:A} == ${JOYSTICK_HOME:A} ]]; then
    ok "already running from $JOYSTICK_HOME (no copy needed)"
  else
    local s missing=()
    for s in $ALL; do [[ -r $SELF/$s ]] || missing+=$s; done
    (( ${#missing} == 0 )) || die "missing next to installer: ${missing[*]} (looked in $SELF)"
    for s in $ALL; do cp -p "$SELF/$s" "$JOYSTICK_HOME/$s"; done
    chmod +x "$JOYSTICK_HOME"/*.sh 2>/dev/null
    ok "copied ${#ALL} scripts"
  fi
}

install_zshrc() {
  bold "Shell hook → ${ZSHRC/#$HOME/~}"
  [[ $SHELL == *zsh* ]] || warn "your login shell isn't zsh — shell-command tracking needs zsh (Claude hooks still work)"
  if [[ -f $ZSHRC ]] && grep -q 'joystick\.zsh' "$ZSHRC" && ! grep -qF "$MARK_BEGIN" "$ZSHRC"; then
    warn "found a joystick.zsh line in ${ZSHRC:t} outside the managed block — leaving it; delete it by hand if it double-sources"
  fi
  backup "$ZSHRC"
  local tmp; tmp=$(mktemp)
  {
    [[ -f $ZSHRC ]] && strip_block < "$ZSHRC"
    print -r -- "$MARK_BEGIN"
    print -r -- "[ -f \"$JOYSTICK_HOME/joystick.zsh\" ] && source \"$JOYSTICK_HOME/joystick.zsh\""
    print -r -- "$MARK_END"
  } > "$tmp"
  mv "$tmp" "$ZSHRC"
  ok "source line installed"
}

install_hooks() {
  command -v jq >/dev/null 2>&1 || die "jq is required for Claude hooks (brew install jq)"
  bold "Claude hooks → ${CLAUDE_SETTINGS/#$HOME/~}"
  mkdir -p "${CLAUDE_SETTINGS:h}"
  [[ -s $CLAUDE_SETTINGS ]] || print -r -- '{}' > "$CLAUDE_SETTINGS"
  jq empty "$CLAUDE_SETTINGS" 2>/dev/null || die "${CLAUDE_SETTINGS} isn't valid JSON — fix or move it, then re-run"
  backup "$CLAUDE_SETTINGS"
  local cmd="$JOYSTICK_HOME/claude-hook.sh" tmp; tmp=$(mktemp)
  # UserPromptSubmit is synchronous (it must log the turn's start before the
  # prompt runs); the rest are async so they never delay Claude. `strip` makes
  # re-runs idempotent and rewrites the command path if $JOYSTICK_HOME changed.
  jq --arg cmd "$cmd" '
    def isjoy: ((.command // "") | endswith("claude-hook.sh"));
    def strip: map(select((any(.hooks[]?; isjoy)) | not));
    def sync:  {hooks:[{type:"command",command:$cmd,timeout:10}]};
    def async: {hooks:[{type:"command",command:$cmd,timeout:10,async:true}]};
    .hooks //= {}
    | .hooks.UserPromptSubmit   = (((.hooks.UserPromptSubmit   // []) | strip) + [sync])
    | .hooks.PreToolUse         = (((.hooks.PreToolUse         // []) | strip) + [async])
    | .hooks.Stop               = (((.hooks.Stop               // []) | strip) + [async])
    | .hooks.StopFailure        = (((.hooks.StopFailure        // []) | strip) + [async])
    | .hooks.Notification       = (((.hooks.Notification       // []) | strip) + [async])
    | .hooks.PostToolUse        = (((.hooks.PostToolUse        // []) | strip) + [async])
    | .hooks.PostToolUseFailure = (((.hooks.PostToolUseFailure // []) | strip) + [async])
  ' "$CLAUDE_SETTINGS" > "$tmp" || die "jq merge failed"
  mv "$tmp" "$CLAUDE_SETTINGS"
  ok "7 hooks wired to $cmd"
}

summary() {
  print
  bold "Joystick is wired up."
  print -r -- "  • Open a new terminal tab — or run:  source ${ZSHRC/#$HOME/~}"
  print -r -- "  • Run any command, or start a Claude Code session — it'll show up in Joystick."
  print -r -- "  Undo everything:  $JOYSTICK_HOME/install.sh uninstall"
}

uninstall() {
  bold "Removing Joystick wiring"
  local tmp s
  if [[ -f $ZSHRC ]] && grep -qF "$MARK_BEGIN" "$ZSHRC"; then
    backup "$ZSHRC"
    tmp=$(mktemp); strip_block < "$ZSHRC" > "$tmp"; mv "$tmp" "$ZSHRC"
    ok "removed shell hook from ${ZSHRC:t}"
  else
    ok "no managed shell hook block in ${ZSHRC:t}"
  fi
  if command -v jq >/dev/null 2>&1 && [[ -f $CLAUDE_SETTINGS ]] && jq empty "$CLAUDE_SETTINGS" 2>/dev/null; then
    backup "$CLAUDE_SETTINGS"
    tmp=$(mktemp)
    jq '
      def isjoy: ((.command // "") | endswith("claude-hook.sh"));
      def strip: map(select((any(.hooks[]?; isjoy)) | not));
      if (.hooks|type)=="object" then
        .hooks |= (with_entries(.value |= strip) | with_entries(select((.value|length) > 0)))
      else . end
    ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    ok "removed Claude hooks from ${CLAUDE_SETTINGS:t}"
  fi
  if [[ -d $JOYSTICK_HOME ]]; then
    for s in $ALL; do rm -f "$JOYSTICK_HOME/$s"; done
    rmdir "$JOYSTICK_HOME" 2>/dev/null
    ok "removed scripts from $JOYSTICK_HOME"
  fi
  print
  ok "Done. Your event log is untouched: ~/.local/state/joystick"
  print -r -- "    Delete it too with:  rm -rf ~/.local/state/joystick"
}

case ${1:-install} in
  install)   bold "Joystick installer"; print; install_scripts; install_zshrc; install_hooks; summary ;;
  uninstall) uninstall ;;
  -h|--help) print -r -- "usage: install.sh [install|uninstall]" ;;
  *)         die "usage: install.sh [install|uninstall]" ;;
esac
