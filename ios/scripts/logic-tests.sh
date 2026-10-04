#!/bin/bash
# Builds and runs every LogicTests/<Suite>/ on macOS (DESIGN §F.2), without a simulator:
#   xcrun swiftc -swift-version 6 -module-name LogicTests LogicTests/Harness.swift $(cat sources.txt) main.swift
# `sources.txt` lists Foundation-only app sources relative to ios/, one per line ('#' starts a comment).
# Usage: scripts/logic-tests.sh [Suite ...]   (default: every suite that has main.swift + sources.txt)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

SUITES=()
if [[ $# -gt 0 ]]; then
  SUITES=("$@")
else
  for dir in LogicTests/*/; do
    [[ -f "${dir}main.swift" && -f "${dir}sources.txt" ]] && SUITES+=("$(basename "$dir")")
  done
fi
if [[ ${#SUITES[@]} -eq 0 ]]; then
  echo "logic-tests: no suites found"
  exit 1
fi

status=0
for suite in "${SUITES[@]}"; do
  dir="LogicTests/$suite"
  SOURCES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "$line" ]] && SOURCES+=("$line")
  done < "$dir/sources.txt"
  echo "  [$suite] compiling (${#SOURCES[@]} app sources)"
  xcrun swiftc -swift-version 6 -module-name LogicTests \
    LogicTests/Harness.swift ${SOURCES[@]+"${SOURCES[@]}"} "$dir/main.swift" -o "build/logic-$suite"
  echo "  [$suite] running"
  if ! "build/logic-$suite"; then
    status=1
  fi
done
exit "$status"
