#!/usr/bin/env python3
# <xbar.title>joystick</xbar.title>
# <xbar.desc>Bird's-eye view of running terminal commands across Ghostty tabs</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
#
# Reads events emitted by ~/joystick/joystick.zsh and shows:
#   - menubar: count + longest-running command with elapsed time
#   - dropdown: all running ops (click to focus that Ghostty tab),
#     plus recently finished ones with exit status.

import json
import os
import subprocess
import time
from pathlib import Path

LOG = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "joystick/events.jsonl"
FOCUS = Path.home() / "joystick/joystick-focus.sh"

MIN_RUNNING_SECS = 5      # hide commands younger than this (prompt noise)
MIN_DONE_SECS = 10        # only list finished commands that ran at least this long
DONE_WINDOW_SECS = 6 * 3600
MAX_DONE = 8
MAX_LOG_LINES = 4000

# Long-lived interactive programs that occupy a tab but aren't "operations".
IGNORE = {"claude", "claude2", "vim", "nvim", "less", "man", "top", "htop", "tmux"}


def alive(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def fmt(secs):
    secs = max(0, int(secs))
    if secs < 60:
        return f"{secs}s"
    m, s = divmod(secs, 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h{m:02d}m"


def short(cmd, n):
    cmd = " ".join(cmd.split())
    return cmd if len(cmd) <= n else cmd[: n - 1] + "…"


def tilde(path):
    home = str(Path.home())
    return "~" + path[len(home):] if path.startswith(home) else path


def first_word(cmd):
    parts = cmd.split()
    return parts[0] if parts else ""


SHELLS = {"zsh", "bash", "fish", "sh"}
STALL_SECS = 20


def live_surfaces():
    """Set of surface ids currently open in Ghostty, or None if unknown."""
    try:
        out = subprocess.run(
            ["/usr/bin/osascript", "-e", 'tell application "Ghostty" to get id of every terminal of every window'],
            capture_output=True, text=True, timeout=3)
        if out.returncode != 0:
            return None
        return {t.strip() for t in out.stdout.strip().split(",") if t.strip()}
    except Exception:
        return None


def tty_probe(tty, now):
    """What is this tty's foreground doing?
    ("service", None)  — fg process group holds a listening TCP socket
    ("waiting", idle)  — quiet STALL_SECS+, fg asleep ~0% CPU, no listener
    None               — busy, or no foreground command"""
    if not tty or tty == "claude":
        return None
    try:
        idle = now - os.stat("/dev/" + tty).st_mtime
    except OSError:
        return None
    try:
        out = subprocess.run(["/bin/ps", "-t", tty, "-o", "pid=,stat=,pcpu=,comm="],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return None
    saw_fg = busy = False
    fg_pids = []
    for ln in out.splitlines():
        parts = ln.split(None, 3)
        if len(parts) < 4 or "+" not in parts[1]:
            continue
        base = os.path.basename(parts[3]).lstrip("-")
        if base in SHELLS:
            continue
        saw_fg = True
        fg_pids.append(parts[0])
        if parts[1].startswith("R") or float(parts[2]) > 5:
            busy = True
    if not saw_fg:
        return None
    if has_listener(fg_pids):
        return ("service", None)
    if busy or idle < STALL_SECS:
        return None
    return ("waiting", idle)


def has_listener(pids):
    if not pids:
        return False
    try:
        out = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", ",".join(pids), "-iTCP", "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=3)
        return bool(out.stdout.strip())
    except Exception:
        return False


events = []
if LOG.exists():
    for line in LOG.read_text(errors="replace").splitlines()[-MAX_LOG_LINES:]:
        try:
            events.append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            pass

starts, done = {}, []
for e in events:
    if e.get("ev") == "start" and "id" in e:
        starts[e["id"]] = e
    elif e.get("ev") == "end":
        s = starts.pop(e.get("id"), None)
        if s:
            s["exit"] = e.get("exit", 0)
            s["dur"] = e.get("dur", max(0, e.get("ts", 0) - s.get("ts", 0)))
            s["end_ts"] = e.get("ts", 0)
            done.append(s)
    elif e.get("ev") == "waiting":
        s = starts.get(e.get("id"))
        if s is not None:
            s["waiting_ts"] = e.get("ts", 0)
            s["waiting_msg"] = e.get("msg", "")
    elif e.get("ev") == "active":
        s = starts.get(e.get("id"))
        if s is not None:
            s.pop("waiting_ts", None)
            s.pop("waiting_msg", None)

now = time.time()
running = [
    s for s in starts.values()
    if alive(s.get("pid"))
    and now - s.get("ts", now) >= MIN_RUNNING_SECS
    and first_word(s.get("cmd", "")) not in IGNORE
]
for s in running:
    if "waiting_ts" not in s:
        st = tty_probe(s.get("tty", ""), now)
        if st and st[0] == "service":
            s["service"] = True
        elif st and st[0] == "waiting":
            s["stall"] = st[1]

def is_waiting(s):
    return "waiting_ts" in s or "stall" in s

# Waiting ops first, then active ops, then services (ambient); oldest first.
running.sort(key=lambda s: (not is_waiting(s), bool(s.get("service")), s.get("ts", 0)))

done = [
    d for d in done
    if d.get("dur", 0) >= MIN_DONE_SECS
    and now - d.get("end_ts", 0) <= DONE_WINDOW_SECS
    and first_word(d.get("cmd", "")) not in IGNORE
]
# Closing a tab is the dismiss gesture: drop finished ops whose surface is gone.
live = live_surfaces()
if live is not None:
    done = [d for d in done if (d.get("surface") or "") in live]
# Stable grouping identity: Claude sessions by their session id (one id across
# all turns), shell commands by their terminal surface.
def group_key(s):
    return s.get("id") if s.get("tty") == "claude" else (s.get("surface") or s.get("id"))

# One entry per idle terminal/session: latest result wins, earlier ones become
# a count. Results from terminals currently busy are omitted here (the app
# shows them nested under the running row).
running_keys = {group_key(s) for s in running}
grouped, gorder = {}, []
for d in done[::-1]:  # newest first
    key = group_key(d)
    if key in running_keys:
        continue
    if key in grouped:
        grouped[key]["earlier"] += 1
    else:
        d["earlier"] = 0
        grouped[key] = d
        gorder.append(key)
done = [grouped[k] for k in gorder][:MAX_DONE]

# --- menubar title ---
# Compact glyph + count. Monochrome and quiet by default so it sits unobtrusively
# in a crowded bar; the one "spark accent" is amber on ✋ when something needs you,
# so the icon only draws the eye when you're actually being waited on. Working/
# serving stay neutral — their shape (▶/◉) carries the state (principle #5).
AMBER = "#E0A24E"
waiting_n = sum(1 for s in running if is_waiting(s))
if waiting_n:
    print(f"✋ {waiting_n} | color={AMBER}")
elif running:
    nonsvc = [s for s in running if not s.get("service")]
    if nonsvc:
        print(f"▶ {len(running)}")
    else:
        print(f"◉ {len(running)}")
else:
    print("🕹")

print("---")

# --- running section ---
if running:
    print("Running | size=11 color=gray")
    for s in running:
        cwd = s.get("cwd", "")
        safe_cwd = cwd.replace('"', "")
        surface = s.get("surface") or "-"
        icon = "✋" if is_waiting(s) else ("◉" if s.get("service") else "▶")
        line = f"{icon} {short(s['cmd'], 48)} — {fmt(now - s['ts'])}"
        params = f'font=Menlo size=12 bash="{FOCUS}" param1="{surface}" param2="{safe_cwd}" terminal=false'
        if is_waiting(s):
            params += " color=orange"
        elif s.get("service"):
            params += " color=green"
        print(f"{line} | {params}")
        detail = tilde(cwd)
        if "waiting_ts" in s:
            msg = s.get("waiting_msg") or "needs you"
            detail = f"✋ {msg} — {fmt(now - s['waiting_ts'])} · {detail}"
        elif "stall" in s:
            detail = f"✋ waiting for input? quiet {fmt(s['stall'])} · {detail}"
        elif s.get("service"):
            detail = f"◉ serving · {detail}"
        print(f"-- {detail} | font=Menlo size=11 color=gray")
else:
    print("Nothing running | color=gray")

# --- finished section ---
if done:
    print("---")
    print("Finished | size=11 color=gray")
    for d in done:
        code = d.get("exit", 0)
        surface = d.get("surface") or "-"
        cwd = d.get("cwd", "")
        mark = "✓" if code == 0 else ("✗ killed" if code == -1 else f"✗ exit {code}")
        ago = fmt(now - d.get("end_ts", now))
        line = f"{mark} {short(d['cmd'], 44)} — {fmt(d.get('dur', 0))} ({ago} ago)"
        color = "" if code == 0 else " color=red"
        params = f' bash="{FOCUS}" param1="{surface}" param2="{cwd.replace(chr(34), "")}" terminal=false'
        print(f"{line} | font=Menlo size=12{color}{params}")
        detail = tilde(cwd)
        if d.get("earlier"):
            detail += f" · +{d['earlier']} earlier"
        print(f"-- {detail} | font=Menlo size=11 color=gray")

print("---")
print(f"Open events log | bash=/usr/bin/open param1=-t param2=\"{LOG}\" terminal=false")
print("Refresh now | refresh=true")
