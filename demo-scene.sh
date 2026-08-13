#!/bin/zsh
# demo-scene.sh — stage a believable, REAL Joystick board for a demo recording.
#
# Joystick is a live mirror, so the only honest way to film it is with real
# terminals in real states. This opens a supporting cast of genuine Ghostty
# tabs — each a real interactive zsh running a real command — so the dashboard
# lights up with every state at once, repeatably, between takes:
#
#     ◉ serving (green)  — two local servers (real listening sockets)
#     ▶ working (blue)   — a build that streams output, then parks
#     ✗ result (red)     — a failing test run  (+ blue "unseen" dot)
#     ✓ result (green)   — a passing deploy    (+ blue "unseen" dot)
#
# You drive the STAR yourself: a real Claude Code session that's waiting on you
# (the softly breathing yellow light). That's the one the video is about — this
# just fills the board around it.
#
# Usage:
#   ./demo-scene.sh stage [roles…]   open the cast (default: all 5 roles)
#   ./demo-scene.sh reset            kill demo procs + close demo tabs (clean slate)
#   ./demo-scene.sh restage [roles…] reset, then stage — for the next take
#   ./demo-scene.sh help
#
#   roles: web api build tests deploy   (e.g. `stage web build tests` for a leaner board)
#
# How it works (so you can tweak it):
#   • Each tab is opened via Ghostty's AppleScript `initial input`, which feeds
#     the command to a normal interactive shell — so the standard joystick.zsh
#     hooks fire and every row is 100% genuine (real pid, cwd, surface; jumpable).
#   • A tiny `sleep 0.6` warm-up runs first in each tab. That's deliberate: the
#     surface-id lookup is async, so the FIRST command in a tab logs with no
#     surface. Warming it means the real command captures the surface — which is
#     what makes exact click-to-focus, the "you are here" highlight, and the
#     blue-dot-clears-when-you-visit beat all work on camera. It shows as one
#     dimmed `sleep 0.6` history line under each row; harmless, and honestly it
#     makes the tabs look lived-in. Pass --no-warm to skip it (cleaner single-
#     line rows, but those three surface-keyed beats won't track the demo tabs).
#
# Nothing here touches the repo or the live app build — it only writes scratch
# files under ~/joystick-demo and appends real events to the shared log, exactly
# like any other terminal would.

emulate -L zsh
set -o pipefail

DEMO="$HOME/joystick-demo"
WARM=1
ALL_ROLES=(web api build tests deploy)

# ── helpers ──────────────────────────────────────────────────────────────────

c() { print -n -- "%F{$1}"; }   # not used directly; print -P below does color

say()  { print -P -- "%F{cyan}demo-scene%f $*" }
ok()   { print -P -- "  %F{green}✓%f $*" }
warn() { print -P -- "%F{yellow}demo-scene%f $*" }
die()  { print -P -- "%F{red}demo-scene%f $*" >&2; exit 1 }

# First free TCP port at or above $1.
free_port() {
  local p=$1
  while lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; do (( p++ )); done
  print -r -- $p
}

# Any process whose cwd is under the demo tree → these PIDs back the demo tabs.
demo_pids() {
  lsof -nP -a -d cwd +D "$DEMO" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u
}

# Open a real Ghostty tab in $1, feeding $2 to its interactive shell as input.
open_tab() {
  local dir=$1 input=$2
  osascript - "$dir" "$input" >/dev/null <<'OSA'
on run argv
  set d to item 1 of argv
  set inp to item 2 of argv
  tell application "Ghostty"
    activate
    set cfg to new surface configuration
    set initial working directory of cfg to d
    set initial input of cfg to inp
    try
      new tab in front window with configuration cfg
    on error
      new window with configuration cfg
    end try
  end tell
end run
OSA
}

# Build the initial-input string into $REPLY: optional warm-up line + the role
# command, each newline-terminated. Returned via REPLY, NOT printed for $(…)
# capture — command substitution strips trailing newlines, which would drop the
# Enter that submits the real command (it'd sit unexecuted at the prompt while
# only the warm-up ran). The literal $'\n' in a plain assignment is preserved.
mkfeed() {
  if (( WARM )); then
    REPLY="sleep 0.6"$'\n'"$1"$'\n'
  else
    REPLY="$1"$'\n'
  fi
}

# Write the little scripts each scene runs, so rows get clean labels
# (`./build.sh`, `./run-tests`, `./deploy.sh`) instead of long one-liners, and
# so the tab shows believable output when you jump into it.
write_scripts() {
  mkdir -p "$DEMO"/{web,api,build,tests,deploy}

  cat > "$DEMO/build/build.sh" <<'SH'
#!/bin/zsh
# A real build — streams plausible output, then parks in watch mode so the row
# stays ▶ working for the whole shoot. Ctrl-C (or `demo-scene reset`) stops it.
mods=(auth session router cache models views api billing telemetry ui)
print -P "%F{8}vite v5.4  building for production…%f"
for m in $mods; do
  printf '  \033[2mtransforming\033[0m apps/%s …\n' "$m"
  sleep 0.8
done
printf '  \033[2mlinking\033[0m   dist/bundle.js\n'
print -P "%F{green}✓%f built in 9.41s — %F{8}watching for changes (⌃C to stop)%f"
sleep 100000
SH

  cat > "$DEMO/tests/run-tests" <<'SH'
#!/bin/zsh
# A real test run that fails — leaves a ✗ result (and a blue "unseen" dot until
# you focus this tab). Exits non-zero from THIS script, so the tab's shell stays.
print -P "%F{8}collected 128 items%f"
printf 'tests/test_auth.py ........\n'
sleep 0.5
printf 'tests/test_cache.py .....\n'
sleep 0.5
printf 'tests/test_billing.py ...\033[31mF\033[0m\n'
sleep 0.4
print ""
print -P "%F{red}FAILED%f tests/test_billing.py::test_proration"
print -P "  %F{8}assert charge.cents == 2000%f"
print -P "  %F{8}  +  where 1999 = charge.cents%f"
print ""
print -P "%F{red}1 failed%f, 127 passed in 3.2s"
exit 1
SH

  cat > "$DEMO/deploy/deploy.sh" <<'SH'
#!/bin/zsh
# A real deploy that succeeds — leaves a ✓ result (and a blue "unseen" dot).
steps=("building image" "pushing layers" "provisioning" "rolling out" "health check")
for s in $steps; do printf '  \033[2m→\033[0m %s …\n' "$s"; sleep 0.9; done
print ""
print -P "%F{green}✓ deployed%f web → production  %F{8}(build 4127, 41s)%f"
print -P "  %F{8}https://app.example.com is live%f"
exit 0
SH

  chmod +x "$DEMO/build/build.sh" "$DEMO/tests/run-tests" "$DEMO/deploy/deploy.sh"
}

# role → (dir, command, human description)
role_dir() { case $1 in
  web) print -r -- "$DEMO/web" ;; api) print -r -- "$DEMO/api" ;;
  build) print -r -- "$DEMO/build" ;; tests) print -r -- "$DEMO/tests" ;;
  deploy) print -r -- "$DEMO/deploy" ;; esac }

# ── commands ─────────────────────────────────────────────────────────────────

stage() {
  local -a roles=("$@"); (( $#roles )) || roles=("${ALL_ROLES[@]}")

  # Refuse to pile new tabs on top of an existing scene.
  if [[ -n "$(demo_pids)" ]]; then
    die "a demo scene is already running — use \`restage\` to rebuild it cleanly."
  fi

  command -v python3 >/dev/null || die "python3 not found (needed for the server rows)."

  write_scripts
  say "staging: ${roles[*]}"

  local r dir
  for r in $roles; do
    dir=$(role_dir $r) || { warn "unknown role: $r (skipping)"; continue }
    case $r in
      web)
        local p=$(free_port 8731)
        mkfeed "python3 -m http.server $p"; open_tab "$dir" "$REPLY"
        ok "web    ◉ serving on :$p" ;;
      api)
        local p=$(free_port 8732)
        mkfeed "python3 -m http.server $p"; open_tab "$dir" "$REPLY"
        ok "api    ◉ serving on :$p" ;;
      build)
        mkfeed "./build.sh"; open_tab "$dir" "$REPLY"
        ok "build  ▶ working (streams, then watches)" ;;
      tests)
        mkfeed "./run-tests"; open_tab "$dir" "$REPLY"
        ok "tests  ✗ failing result (+ unseen dot)" ;;
      deploy)
        mkfeed "./deploy.sh"; open_tab "$dir" "$REPLY"
        ok "deploy ✓ passing result (+ unseen dot)" ;;
    esac
    sleep 0.35   # let each tab's surface lookup settle before opening the next
  done

  print ""
  say "board is live. Now the star of the shot:"
  print -P "  %F{yellow}→%f start a real Claude Code session in another tab and let it stop"
  print -P "    on a question — that's your %F{yellow}breathing-yellow 'needs you'%f hero row."
  print -P "  %F{8}Summon Joystick with your hotkey, then film glance → ⏎ jump.%f"
  print -P "  %F{8}Re-take with:  ./demo-scene.sh restage%f"
}

reset() {
  local pids=("${(@f)$(demo_pids)}")
  if (( ${#pids} )) && [[ -n "$pids[1]" ]]; then
    say "stopping ${#pids} demo process(es) (this closes their tabs)…"
    # SIGKILL, not SIGTERM: an interactive zsh sitting at its prompt IGNORES
    # SIGTERM, so plain `kill` leaves idle demo shells (and their tabs) alive.
    # -9 can't be trapped — the pty closes and Ghostty drops the tab. Rows then
    # vanish via the viewer's pid-liveness prune (no zshexit end event needed).
    kill -9 $pids 2>/dev/null
    sleep 0.5
  fi
  # Sweep any tab that didn't close (now process-free, so no confirm dialog).
  local closed
  closed=$(osascript - "joystick-demo" <<'OSA'
on run argv
  set needle to item 1 of argv
  tell application "Ghostty"
    set n to 0
    repeat with t in (every terminal whose working directory contains needle)
      try
        perform action "close_surface" on t
        set n to n + 1
      end try
    end repeat
    return n
  end tell
end run
OSA
)
  ok "demo board cleared (${closed:-0} stray tab(s) swept)."
}

usage() {
  print -r -- "demo-scene.sh — stage a real Joystick board for a demo recording

  ./demo-scene.sh stage   [roles…] [--no-warm]   open the cast (default: all)
  ./demo-scene.sh reset                          kill demo procs + close tabs
  ./demo-scene.sh restage [roles…] [--no-warm]   reset, then stage (next take)

  roles: ${ALL_ROLES[*]}
         web/api → ◉ serving · build → ▶ working · tests → ✗ · deploy → ✓

  You provide the ★ yourself: a real Claude session that's waiting on you
  (the breathing-yellow row the video is about).

  --no-warm   skip the per-tab surface warm-up: cleaner single-line rows, but
              exact-jump / you-are-here / unseen-dot won't track the demo tabs.

  Scratch files live in ~/joystick-demo; nothing else is touched."
}

# ── arg parsing ──────────────────────────────────────────────────────────────

local -a positional=()
local cmd=""
for a in "$@"; do
  case $a in
    --no-warm) WARM=0 ;;
    stage|reset|restage|help|-h|--help) [[ -z $cmd ]] && cmd=$a || positional+=$a ;;
    *) positional+=$a ;;
  esac
done

case ${cmd:-help} in
  stage)   stage "${positional[@]}" ;;
  reset)   reset ;;
  restage) reset; print ""; stage "${positional[@]}" ;;
  help|-h|--help|*) usage ;;
esac
