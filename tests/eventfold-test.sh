#!/bin/zsh
# Compile + run the EventFold unit tests against the real model code (EventLog.swift).
# Foundation-only, so no app/SwiftUI build is needed. Run after editing EventLog.swift.
set -e
DIR=${0:A:h}/..          # repo root (this test lives in tests/), worktree-aware
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
swiftc -swift-version 5 -parse-as-library \
  "$DIR/EventLog.swift" "$DIR/tests/eventfold-test.swift" -o "$TMP/eventfold-test"
"$TMP/eventfold-test"
