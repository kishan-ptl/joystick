#!/bin/zsh
# joystick redaction test suite — run after any change to joystick-redact.zsh
source ~/.config/joystick/joystick-redact.zsh
pass=0; fail=0
check() { # $1 input, $2 must-contain, $3 must-not-contain
  _joystick_redact "$1"
  local ok=1
  [[ -n $2 && $REPLY != *"$2"* ]] && ok=0
  [[ -n $3 && $REPLY == *"$3"* ]] && ok=0
  if (( ok )); then ((pass++)); else ((fail++)); print -r -- "FAIL: '$1' -> '$REPLY'"; fi
}
# Context rules (deterministic)
check 'curl -H "Authorization: Bearer abc123DEF456ghi"' 'Bearer •••' 'abc123DEF456'
check 'PGPASSWORD=hunter2 psql -h db.example.com' 'PGPASSWORD=•••' 'hunter2'
check 'export STRIPE_SECRET_KEY=shortkey99' 'STRIPE_SECRET_KEY=•••' 'shortkey99'
check 'deploy --token hunter2abc --env prod' '--token •••' 'hunter2abc'
check 'tool --api-key=supersecretvalue123 run' '--api-key=•••' 'supersecretvalue'
check 'git clone https://kishan:s3cr3t@github.com/x/y.git' 'https://•••@github.com' 's3cr3t'
check 'curl -u admin:swordfish https://api.example.com' '-u •••' 'swordfish'
# Structural elision (one rule: 24+ chars, not flag/path/URL)
check 'echo ghp_AbCdEfGhIjKlMnOpQrStUvWxYz123456' 'ghp_…' 'AbCdEfGhIjKl'
check 'verify eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.dBjftJeZ4CVPmB92K27uhb' 'eyJh…' 'dBjftJeZ'
check 'use Xy9Zw8Vu7Tt6Ss5Rr4Qq3Pp2Oo1Nn0Mm now' 'Xy9Z…' 'Zw8Vu7Tt6'
check 'git checkout 3048da2bcf8e8a1c2d3e4f5a6b7c8d9e0f1a2b3c' '3048…' 'da2bcf8e8a1c'
# Must NOT touch
check 'eas build --platform ios --profile production' 'eas build --platform ios --profile production' '…'
check 'git commit -m "fix token parsing in auth module"' 'fix token parsing in auth module' '•••'
check 'top -u kishan' 'top -u kishan' '•••'
check 'vim apps/mobile/components/popovers/popover-layout.tsx' 'apps/mobile/components/popovers/popover-layout.tsx' '…'
check 'npm install @tanstack/react-query-devtools' '@tanstack/react-query-devtools' '…'
check 'curl https://api.example.com/v1/items?limit=100&cursor=abc' 'https://api.example.com' '…'
check 'docker pull ghcr.io/fndrhouse/oasis-api:latest' 'ghcr.io/fndrhouse/oasis-api:latest' '…'
print "pass=$pass fail=$fail"
