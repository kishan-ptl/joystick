# joystick — shared zsh helpers: JSON escaping + command sanitizing. Sourced by
# joystick.zsh, the `joystick` CLI, claude-hook.sh, and joystick-scrub.sh so the
# emitters can't drift in how they escape/redact.
#
# _joystick_esc <text>     -> sets REPLY to a JSON-safe string.
# _joystick_redact <text>  -> sets REPLY to the sanitized text.
#
# Design: NO secret-detection heuristics. Two kinds of deterministic,
# documentable rules only:
#
# 1. Context rules (same approach as git/CI credential masking):
#    - values of sensitive-named flags (--password x, --token=x, ...)
#    - sensitive env assignments (PGPASSWORD=..., STRIPE_SECRET_KEY=...)
#    - URL userinfo (https://user:pass@host)
#    - Authorization headers (Bearer/Basic), curl -u user:pass
#
# 2. Structural elision: any standalone token of 24+ chars that isn't a
#    flag, path, or URL displays as its first 4 chars + "…". We don't decide
#    what's secret — long opaque blobs are unreadable in a dashboard anyway,
#    and this catches tokens from every provider with no list to maintain.
#
# Documented gaps (by design): bare passwords with no flag context
# (`mysql -phunter2`), secrets embedded in tokens containing "/" (rare; the
# context rules cover the usual carriers). For sensitive work use
# JOYSTICK_NOLOG_DIRS or JOYSTICK_LOG_MODE=head.

# JSON string escaping for emitted event fields. Named escapes first, then strip
# any remaining control chars (e.g. raw ESC bytes in pasted commands). Sets REPLY.
_joystick_esc() {
  emulate -L zsh
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  s=${s//[[:cntrl:]]/}
  typeset -g REPLY=$s
}

# Replace regex matches in the dynamically-scoped variable `s`.
# $1=ERE pattern  $2=group index to redact (0 = whole match)  $3=1 for case-insensitive
_joystick_sub() {
  emulate -L zsh   # user zshrc may set bash_rematch/re_match_pcre, which
                   # would stop zsh from populating MATCH/MBEGIN/MEND below
  local pat=$1 grp=${2:-0} ci=${3:-0} iter=0 hay
  while (( iter++ < 25 )); do
    if (( ci )); then hay=${(L)s}; else hay=$s; fi
    [[ $hay =~ $pat ]] || break
    if (( grp )); then
      s="${s[1,mbegin[grp]-1]}•••${s[mend[grp]+1,-1]}"
    else
      s="${s[1,MBEGIN-1]}•••${s[MEND+1,-1]}"
    fi
  done
}

_joystick_redact() {
  emulate -L zsh
  local s=$1

  # --- 1. Context rules -----------------------------------------------------
  # URL userinfo: scheme://user:pass@host
  _joystick_sub '://([^/@[:space:]•]+:[^/@[:space:]•]+)@' 1 0
  # Sensitive flag values: --password x | --api-key=x | --auth-token x ...
  # (the sensitive word must be inside a dash-flag, so `-m "fix token parsing"`
  # is untouched). Value charclass excludes • to terminate the loop.
  _joystick_sub '(--?[a-z0-9_-]*(password|passwd|pwd|token|secret|apikey|api-key|auth|cred)[a-z0-9_-]*)(=|[[:space:]]+)([^[:space:]•]+)' 4 1
  # Sensitive env assignments: NAME=value where NAME smells secret
  _joystick_sub '(^|[[:space:]])([a-z_][a-z0-9_]*(key|token|secret|pass|pwd|cred|auth)[a-z0-9_]*)=([^[:space:]•]+)' 4 1
  # Authorization headers
  _joystick_sub '(bearer[[:space:]]+)([^[:space:]•]{8,})' 2 1
  _joystick_sub '(basic[[:space:]]+)([A-Za-z0-9+/=]{8,})' 2 1
  # curl -u user:pass / --user user:pass (colon required, avoids `top -u kishan`)
  _joystick_sub '(--user[= ]|-u[ ])([^[:space:]•]*:[^[:space:]•]+)' 2 0

  # --- 2. Structural elision ------------------------------------------------
  local w
  for w in ${(s: :)s}; do
    (( ${#w} >= 24 )) || continue
    [[ $w == -* || $w == *[/•]* ]] && continue
    s=${s//${(q)w}/${w[1,4]}…}
  done

  typeset -g REPLY=$s
}
