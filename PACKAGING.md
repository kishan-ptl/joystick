# Joystick v0.1 — Packaging Plan

The work that turns Joystick from "works on my machine" into "another developer
installs it in one step." Not features — distribution and consolidation.

This is deliberately broken into small, **independently mergeable chunks** so no
single worktree has to carry the whole thing. Do them in order; each is shippable
on its own.

## Definition of done (v0.1)

- A **signed, notarized `Joystick.app`** distributed via DMG (and/or `brew install --cask joystick`).
- **One app**: no SwiftBar, no python plugin — menubar + window + notifications in the single `.app`.
- **First-run onboarding** wires shell + Claude hooks with buttons (no manual editing).
- Opens with **no security warnings**; automation permission asked **once** (not per rebuild).
- `README` (with a gif) + `PRIVACY.md` published.

## The conceptual change packaging forces

Today the **repo IS the live system**: emitters live at `~/joystick/*.zsh`, the app
and shell both reference that path. That only works for the developer. A shipped
app can't assume `~/joystick` exists.

**Decision required (blocks onboarding + the app):** where do the emitter scripts
live when distributed?
- **Option A — bundle in the app, copy out on first run** to `~/.config/joystick/`
  (or `~/.local/share/joystick/`); shell + Claude hooks source from there. App
  references that stable path, not `~/joystick`.
- **Option B — keep scripts in the app bundle and source straight from
  `Joystick.app/Contents/Resources/`** (breaks if the app moves; fragile).

Recommend **A**. Everything below assumes a stable install dir, call it
`$JOYSTICK_HOME` (default `~/.config/joystick`), decided in chunk 2.

---

## Chunk 1 — Consolidate to one app (MenuBarExtra)

The big one. Fold the SwiftBar plugin into the Swift app.

- Add a `MenuBarExtra` scene to `JoystickApp` alongside the `WindowGroup`, both
  bound to the same `@StateObject Store` (one source of derived state).
- Use `.menuBarExtraStyle(.window)` so the dropdown can reuse SwiftUI content
  (a compact version of `ContentView`).
- **Menubar label**: icon + counts only (cheap to redraw on the existing 1s
  timer) — `▶ N` / `✋ K needs you` / `◉ serving` / `⌁` idle. Don't try to render
  live elapsed timers in the label.
- **Notifications**: migrate from `osascript` to `UNUserNotificationCenter` —
  request authorization on first launch; make them **actionable** (click →
  focus the tab) via a notification action that calls the existing focus logic.
- **Dock vs menubar-only**: DECIDED 2026-06-13 — **keep both** Dock and
  menubar (not `LSUIElement`). The menubar shows current activity; the Dock
  icon carries the unseen-count badge. This is already the behavior.
- **Delete** when done: `joystick.5s.py`, the `~/.config/swiftbar/` symlink,
  and SwiftBar from setup docs. (History keeps the python as reference.)
- Keep SwiftBar working in parallel until the MenuBarExtra reaches parity, then
  remove in one commit.

## Chunk 2 — Stable install location ($JOYSTICK_HOME)

- Pick `$JOYSTICK_HOME` (default `~/.config/joystick`); make every path in the
  app, `joystick.zsh`, and `claude-hook.sh` resolve it via env override →
  default, not a hardcoded `~/joystick`.
- The app bundles the emitter scripts in `Resources/` and copies them to
  `$JOYSTICK_HOME` on first run / update (only if newer).
- Event log stays at `~/.local/state/joystick/` (already correct, XDG).
- This unblocks onboarding and is a prerequisite for the DMG.

## Chunk 3 — First-run onboarding

- Detect not-installed state: scan `~/.zshrc` for the source line,
  `~/.claude/settings.json` for the 4 hooks, Ghostty config for the notify keys.
- Onboarding window, one button per step (all **idempotent**, back up before edit):
  - **Install shell integration** → append the source line to `.zshrc`.
  - **Install Claude hooks** → `jq` merge the hooks into `settings.json`.
  - **Enable Ghostty notifications** → append the 3 `notify-on-command-finish` lines.
  - **Try it** → run `sleep 8` in a new Ghostty tab via AppleScript so the user
    sees a row appear within 30 seconds.
- Re-runnable from a Settings pane; show per-item installed/❌ status.

## Chunk 4 — Xcode project + signing + notarization

- Replace `build-app.sh` with a real Xcode project (or xcodegen/Tuist spec so
  it stays diffable).
- Settings: bundle id `dev.kishan.joystick`, deploy target macOS 14, hardened
  runtime ON.
- **App sandbox: OFF.** Joystick fundamentally inspects other processes
  (`ps`, `lsof`) and drives Ghostty (AppleEvents) — sandbox would block these.
  → Developer ID distribution, **not** Mac App Store. Document this.
- Entitlements: `com.apple.security.automation.apple-events`;
  `NSAppleEventsUsageDescription` (already in the plist).
- Sign with **Developer ID Application** (Kishan's existing Apple account),
  `codesign --options runtime`, then `notarytool submit` + `stapler staple`.
- Output: `.app` → `.dmg` (create-dmg) → notarize + staple the DMG too.

## Chunk 5 — Polish

- App icon (`.icns`) — a joystick glyph.
- Empty state ("Nothing running — open a terminal and run something").
- Launch at login (`SMAppService`).
- Settings pane: thresholds (stall secs, min durations), IGNORE-list editor,
  notification rules, `JOYSTICK_NOLOG_DIRS`. (This also retires the
  edit-the-constant workflow noted in the IGNORE-list discussion.)
- Auto-updates: Sparkle appcast, or lean on `brew upgrade` for v0.1.

## Chunk 6 — Distribution & launch

- `README.md`: what it is, the state vocabulary (✋▶◉✓ + unseen dot), a 20s gif.
- `PRIVACY.md` (NOTES idea #6): what's stored, masking rules, local-only,
  ephemeral-mode note, "zsh_history already stores commands unredacted."
- Homebrew cask pointing at a GitHub Release DMG (or just Releases + DMG first).
- Launch: Ghostty Discord, then Show HN with the gif (6 tabs, 3 Claudes, the
  needs-you inbox).

---

## Open decisions (resolve before the chunk that needs them)

| Decision | Blocks | Lean |
|---|---|---|
| Emitter install location (`$JOYSTICK_HOME`) | chunks 2,3,4 | `~/.config/joystick`, copied from bundle |
| App sandbox on/off | chunk 4 | OFF → Developer ID, not App Store |
| Dock badge vs `LSUIElement` | chunk 1 | DECIDED: keep both Dock + menubar |
| Drop python/SwiftBar entirely? | chunk 1 | yes for v0.1 (Ghostty-first) |
| Final name + icon | chunk 5 | TBD |

## Notes

- Each chunk is small enough for its own worktree + merge — which is the point
  of writing this down instead of one giant branch.
- Chunk 1 (MenuBarExtra) is the highest-leverage and the riskiest refactor;
  everything else is mostly mechanical once the single-app shape exists.
- See `NOTES.md` for the design principles these must not regress and the
  broader roadmap/idea backlog.
