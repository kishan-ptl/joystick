#!/bin/zsh
# demo-claude.sh — stage a Joystick board made entirely of Claude session rows,
# for recording the Claude-specific UI (goal chips, model badges, context-fill,
# worktree chips, live subagent / bg-shell lines, the breathing-yellow "needs
# you" light, ✓/✗ results with unseen dots).
#
# Why this is different from demo-scene.sh (the shell cast): Joystick only keeps
# a Claude row on the board while a REAL process at its pid is alive (the viewer
# gates every claude row on kill(pid,0) + a start-time check, to defeat pid
# reuse — see Joystick.swift `alive` / `opHostAlive`). So we can't just append
# "claude" lines to the log: each row is backed by a cheap, real `sleep` process
# that supplies a live, non-reused pid. Kill the sleeps (./demo-claude.sh reset)
# and the rows vanish on the next poll, exactly like a live shell cast.
#
# The events themselves are curated (example sessions, not genuine Claude runs)
# — that's the deliberate trade we made to get every recent UI feature on screen
# at once, repeatably, between takes. They're click-to-focus-less (no backing
# Ghostty tab); the recording is about the dashboard, not the jump.
#
# Usage:
#   ./demo-claude.sh app                   build + launch the DEMO viewer (own log)
#   ./demo-claude.sh stage   [--with-ci]   paint the board (6 Claude rows)
#   ./demo-claude.sh reset                 kill the backing procs (rows vanish)
#   ./demo-claude.sh restage [--with-ci]   reset, then stage — for the next take
#   ./demo-claude.sh down                  clear the board + quit the demo viewer
#   ./demo-claude.sh help
#
# The DEMO viewer is a SEPARATE Joystick.app build (bundle id …joystick.demo,
# its own UserDefaults + summon hotkey ⌃⌘D) reading its OWN log under
# ~/joystick-demo — so dummy rows NEVER mix into your real app or your real
# ~/.local/state log. Run `app` once, then `stage`/`restage` to fill it, `down`
# to tear it all down.
#
#   --with-ci   add one external `joystick log` row (✓ eas build) for variety —
#               externals need no backing process (kept until a 24h TTL), but
#               carry none of the Claude chrome, so it's off by default.
#
# The cast (every row is a real, persisting pid):
#   ⏳ needs you   refactor EventFold      opus  · goal chip · breathing yellow
#   ▶ working     migrate zsh hooks       sonnet· wt:hooks · 2 live subagents
#   ✓ done (live) redact test matrix      opus  · 92% ctx (RED, promoted) · ▷ bg shell
#   ✓ done        row eyebrow layout      opus  · wt:ui · purple "ui-polish" rename
#   ✗ failed      flaky proration test    sonnet· ⚠ bypass · unseen dot
#   ✓ done        version bump            haiku · calm low ctx
#
# It builds a throwaway app bundle and writes a throwaway log, both under
# ~/joystick-demo — the repo, the live ~/Applications/Joystick.app, and your
# real ~/.local/state log are all left untouched. Events are curated (ids
# prefixed `claude-demo-`) and backed by throwaway sleeps; reset/down kill those,
# and the whole demo log can be deleted freely since nothing real lives in it.

emulate -LR zsh
setopt no_hup            # backgrounded sleeps must survive this script exiting

REPO="${0:A:h}"
DEMO="$HOME/joystick-demo"
PIDF="$DEMO/claude-pids"
APPPIDF="$DEMO/app-pid"
# The demo gets its OWN state dir + log, kept entirely apart from the real
# system log so dummy rows never mix with real sessions. Both the demo viewer
# (launched below with XDG_STATE_HOME=$DEMO_STATE) and the events here read THIS.
DEMO_STATE="$DEMO/state"
LOG="$DEMO_STATE/joystick/events.jsonl"
DEMO_APP="$DEMO/Joystick Demo.app"
DEMO_BUNDLE_ID="dev.kishan.joystick.demo"
DEMO_HOTKEY="ctrl+cmd+d"
WITH_CI=0

say()  { print -P -- "%F{cyan}demo-claude%f $*" }
ok()   { print -P -- "  %F{green}✓%f $*" }
warn() { print -P -- "%F{yellow}demo-claude%f $*" }
die()  { print -P -- "%F{red}demo-claude%f $*" >&2; exit 1 }

emit() { print -r -- "$1" >> "$LOG" }   # one JSON object → one log line

running_pids() {
  [[ -f $PIDF ]] || return
  local p; for p in ${=$(<$PIDF)}; do kill -0 $p 2>/dev/null && print -r -- $p; done
}

app_running() { [[ -f $APPPIDF ]] && kill -0 $(<$APPPIDF) 2>/dev/null }

# ── demo viewer (a SEPARATE Joystick.app on its own log) ───────────────────────

quit_app() {
  app_running && kill $(<$APPPIDF) 2>/dev/null
  rm -f "$APPPIDF"
}

launch_app() {
  command -v swiftc >/dev/null || die "swiftc not found — need the Xcode CLT to build the demo app."
  mkdir -p "$DEMO" "${LOG:h}"; : >> "$LOG"; chmod 600 "$LOG" 2>/dev/null

  # Build a SEPARATE bundle to a throwaway path — build-app.sh honors
  # JOYSTICK_APP, so this never clobbers ~/Applications/Joystick.app.
  say "building demo viewer → ${DEMO_APP/#$HOME/~}"
  JOYSTICK_APP="$DEMO_APP" "$REPO/build-app.sh" >/dev/null || die "build failed."

  # Distinct bundle id + name → its own Dock/menubar identity AND its own
  # UserDefaults (seenAt / slotOrder / hotkey), zero overlap with the real app.
  # Editing the bundle invalidates the signature, so re-sign ad-hoc.
  local pb=/usr/libexec/PlistBuddy plist="$DEMO_APP/Contents/Info.plist"
  "$pb" -c "Set :CFBundleIdentifier $DEMO_BUNDLE_ID" "$plist"
  "$pb" -c "Set :CFBundleName Joystick Demo" "$plist"
  "$pb" -c "Add :CFBundleDisplayName string Joystick Demo" "$plist" 2>/dev/null \
    || "$pb" -c "Set :CFBundleDisplayName Joystick Demo" "$plist"
  codesign -s - --force "$DEMO_APP" >/dev/null 2>&1
  # Give the demo its own working summon hotkey; the real app keeps ⌃⌘J.
  defaults write "$DEMO_BUNDLE_ID" summonHotKey "$DEMO_HOTKEY" 2>/dev/null

  quit_app   # replace any prior demo instance

  # Launch the binary DIRECTLY (not `open`, which drops the environment) so
  # XDG_STATE_HOME reaches the app and it reads the demo log. Bundle.main still
  # resolves to the .app, so the patched Info.plist + icon load normally.
  # JOYSTICK_HOME is left unset on purpose: the app finds your existing install
  # and skips onboarding.
  XDG_STATE_HOME="$DEMO_STATE" "$DEMO_APP/Contents/MacOS/Joystick" >/dev/null 2>&1 &!
  print -r -- $! > "$APPPIDF"
  ok "demo viewer running (pid $!) — reads ONLY ${LOG/#$HOME/~}"
  ok "summon with ${DEMO_HOTKEY//+/ + } (or cmd-tab to \"Joystick Demo\" / its menubar icon)"
}

down() { reset; quit_app; ok "demo viewer quit." }

# ── stage ─────────────────────────────────────────────────────────────────────

stage() {
  [[ -n "$(running_pids)" ]] && \
    die "a claude demo board is already up — use \`restage\` to rebuild it cleanly."

  mkdir -p "$DEMO" "${LOG:h}"
  : >> "$LOG"; chmod 600 "$LOG" 2>/dev/null

  # 6 throwaway sleeps → 6 real, live, non-reused pids (one per Claude row).
  local -a P=()
  local i
  for i in 1 2 3 4 5 6; do sleep 2000000 >/dev/null 2>&1 &!; P+=$!; done
  print -r -- "${P[@]}" > "$PIDF"

  # Capture `now` AFTER launching the sleeps, so every op.start ≥ its backing
  # process's start time — otherwise the viewer's pid-reuse guard (a host must
  # predate the op it runs) would treat the row as dead and prune it.
  local now=$(( $(date +%s) ))
  local home="$HOME"

  say "painting the board…"

  # 1 — HERO: open + waiting → softly breathing yellow "needs you". Goal chip.
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-1","cmd":"refactor EventFold into an incremental left-fold","cwd":"'"$home"'/joystick","pid":'$P[1]',"tty":"","surface":"","ts":'$now'}'
  emit '{"v":1,"ev":"waiting","id":"claude-demo-1","msg":"Keep the 2000-op retention cap, or make it configurable?","ts":'$now'}'

  # 2 — WORKING: open, no end → ▶ blue. Two live subagents (the fan-out list).
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-2","cmd":"migrate the zsh hooks to the new surface-capture API","cwd":"'"$home"'/joystick-wt/hooks","pid":'$P[2]',"tty":"","surface":"","ts":'$now'}'
  emit '{"v":1,"ev":"active","id":"claude-demo-2","act":"Task: audit the preexec hooks","sub":"demo-sub-a","ts":'$now'}'
  emit '{"v":1,"ev":"active","id":"claude-demo-2","act":"Task: port the precmd emitter","sub":"demo-sub-b","ts":'$now'}'

  # 3 — LIVE BG SHELL: a turn that ended, but a run_in_background shell carries on
  #     (session-scoped ▷ line persists past the turn). Hot ctx (red, promoted).
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-3","cmd":"run the redact test matrix across every shell","cwd":"'"$home"'/joystick","pid":'$P[3]',"tty":"","surface":"","ts":'$now'}'
  emit '{"v":1,"ev":"active","id":"claude-demo-3","act":"zsh tests/redact-test.zsh --all-shells","shell":"demo-sh-a","ts":'$now'}'

  # 4, 5, 6 open here; their ends are emitted below with staggered, real
  # durations (the viewer derives dur from end.ts − start, and rejects a dur
  # that disagrees with op.start, so we can't fabricate longer ones — a freshly
  # staged board honestly reads as "just finished").
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-4","cmd":"add the worktree chip to the row eyebrow","cwd":"'"$home"'/joystick-wt/ui","pid":'$P[4]',"tty":"","surface":"","ts":'$now'}'
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-5","cmd":"fix the flaky proration test","cwd":"'"$home"'/joystick","pid":'$P[5]',"tty":"","surface":"","ts":'$now'}'
  emit '{"v":1,"kind":"claude","ev":"start","id":"claude-demo-6","cmd":"bump the version string to v1.4","cwd":"'"$home"'/joystick","pid":'$P[6]',"tty":"","surface":"","ts":'$now'}'

  # Staggered ends → varied (honest, short) durations on the finished rows.
  sleep 1; local t=$(( $(date +%s) ))
  emit '{"v":1,"ev":"end","id":"claude-demo-6","exit":0,"dur":'$((t-now))',"msg":"Bumped to v1.4 (build 6).","ts":'$t'}'
  sleep 2; t=$(( $(date +%s) ))
  emit '{"v":1,"ev":"end","id":"claude-demo-5","exit":1,"dur":'$((t-now))',"msg":"1 test still failing; needs a deterministic clock.","ts":'$t'}'
  sleep 2; t=$(( $(date +%s) ))
  emit '{"v":1,"ev":"end","id":"claude-demo-4","exit":0,"dur":'$((t-now))',"msg":"Eyebrow now shows worktree + rename + goal together.","ts":'$t'}'
  sleep 2; t=$(( $(date +%s) ))
  emit '{"v":1,"ev":"end","id":"claude-demo-3","exit":0,"dur":'$((t-now))',"msg":"All shells green; matrix still streaming in the background.","ts":'$t'}'

  # Per-session meta (title / model / mode / ctx / name / color / wt / goal).
  local m=$(( $(date +%s) ))
  emit '{"v":1,"ev":"meta","id":"claude-demo-1","title":"incremental EventFold","model":"claude-opus-4-8","mode":"default","ctx":84000,"goal":"EventFold unit tests stay green","ts":'$m'}'
  emit '{"v":1,"ev":"meta","id":"claude-demo-2","title":"migrating zsh hooks","model":"claude-sonnet-4-6","mode":"default","wt":"hooks","ctx":51000,"ts":'$m'}'
  emit '{"v":1,"ev":"meta","id":"claude-demo-3","title":"redact test matrix","model":"claude-opus-4-8","mode":"default","ctx":185000,"ts":'$m'}'
  emit '{"v":1,"ev":"meta","id":"claude-demo-4","title":"row eyebrow layout","model":"claude-opus-4-8","mode":"default","name":"ui-polish","color":"purple","wt":"ui","ctx":63000,"ts":'$m'}'
  emit '{"v":1,"ev":"meta","id":"claude-demo-5","title":"flaky proration test","model":"claude-sonnet-4-6","mode":"bypassPermissions","ctx":38000,"ts":'$m'}'
  emit '{"v":1,"ev":"meta","id":"claude-demo-6","title":"version bump","model":"claude-haiku-4-5","mode":"default","ctx":12000,"ts":'$m'}'

  ok "⏳ needs you   refactor EventFold     opus   · goal chip · breathing yellow"
  ok "▶ working     migrate zsh hooks      sonnet · wt:hooks · 2 live subagents"
  ok "✓ done (live) redact test matrix     opus   · 92% ctx (red) · ▷ bg shell"
  ok "✓ done        row eyebrow layout     opus   · wt:ui · purple \"ui-polish\""
  ok "✗ failed      flaky proration test   sonnet · ⚠ bypass · unseen dot"
  ok "✓ done        version bump           haiku  · calm low ctx"

  if (( WITH_CI )); then
    if [[ -x "$REPO/joystick" ]]; then
      XDG_STATE_HOME="$DEMO_STATE" "$REPO/joystick" log done "eas build (ios prod)" --exit 0 --took 612 >/dev/null \
        && ok "◷ external    eas build (ios prod)   ✓ (joystick CLI)"
    else
      warn "skipped --with-ci: $REPO/joystick not found/executable."
    fi
  fi

  print ""
  if app_running; then
    say "board is live in the demo viewer. Summon it (${DEMO_HOTKEY//+/ + }) and record."
  else
    say "board written to the demo log. Launch the viewer:  ./demo-claude.sh app"
  fi
  print -P "  %F{8}Next take:  ./demo-claude.sh restage%f"
  print -P "  %F{8}Tear down:  ./demo-claude.sh down   (clears rows + quits the demo viewer)%f"
}

# ── reset ───────────────────────────────────────────────────────────────────

reset() {
  local -a pids=()
  [[ -f $PIDF ]] && pids=(${=$(<$PIDF)})
  if (( ${#pids} )); then
    say "stopping ${#pids} backing process(es)…"
    local p; for p in $pids; do kill $p 2>/dev/null; done
  fi
  rm -f "$PIDF"
  ok "claude demo board cleared (rows drop on the viewer's next poll)."
}

# ── args ──────────────────────────────────────────────────────────────────────

local cmd=""
for a in "$@"; do
  case $a in
    --with-ci) WITH_CI=1 ;;
    app|stage|reset|restage|down|help|-h|--help) [[ -z $cmd ]] && cmd=$a ;;
    *) warn "ignoring unknown arg: $a" ;;
  esac
done

case ${cmd:-help} in
  app)     launch_app ;;
  stage)   stage ;;
  reset)   reset ;;
  restage) reset; print ""; stage ;;
  down)    down ;;
  *)
    print -r -- "demo-claude.sh — stage a Joystick board of Claude session rows
                in a SEPARATE demo viewer on its own log (never your real app).

  ./demo-claude.sh app                   build + launch the demo viewer
  ./demo-claude.sh stage   [--with-ci]   paint the board (6 Claude rows)
  ./demo-claude.sh reset                 kill the backing procs (rows vanish)
  ./demo-claude.sh restage [--with-ci]   reset, then stage (next take)
  ./demo-claude.sh down                  clear the board + quit the demo viewer

  Each row is backed by a real \`sleep\` (a live pid) so the viewer keeps it;
  reset kills them. Events are curated example sessions, written to a demo-only
  log under ~/joystick-demo. --with-ci adds one external \`joystick log\` row." ;;
esac
